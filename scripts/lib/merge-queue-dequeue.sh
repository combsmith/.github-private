#!/usr/bin/env bash
# merge-queue-dequeue.sh — remove a PR from the merge queue when the fleet has
# withdrawn its last approval (issue #2174).
#
# GitHub evaluates a ruleset's review requirement when a PR JOINS the merge queue
# and does not re-evaluate it when the queue merges. So an approval dismissed
# after the PR was enqueued no longer stops the merge (PR 2084, 2026-10-10:
# approved, enqueued, approval dismissed, merged while REVIEW_REQUIRED).
#
# Call mq_dequeue_if_unapproved AFTER every dismissal in the run AND after the
# run's new verdict has been posted. It reads the LIVE state, never what the
# caller just did: a re-review that dismissed the old approval and posted a new
# one leaves an approval standing, so the PR stays queued.
#
# Sourced by scripts/post-pr-review.sh, scripts/invalidate-standing-approval.sh and
# scripts/review-one-pr.sh (its comment gate and maintainer-thread gate dismissals).
# Every failure path logs and returns 0 — this must never fail the caller's run.

# Marker on the single notice posted per head SHA and outcome. The failure notice
# has its own marker so an earlier success notice at the same head never masks it.
# The `pr-review-agent` prefix
# keeps it out of maintainer-comment-gate.sh's blocker set; the absence of `v1`
# keeps it out of the review-marker regexes (cleanup, cycle counting).
MQ_DEQUEUE_MARKER_PREFIX='<!-- pr-review-agent dequeued sha='
MQ_DEQUEUE_FAILED_MARKER_PREFIX='<!-- pr-review-agent dequeue-failed sha='

# _mq_read_state <owner> <name> <number>
#   Print one compact JSON object {id, state, head, queued, approved} from the
#   live PR. `approved` is true when any writer's latest opinionated review is
#   APPROVED on the current head commit (bot or human). Non-zero when the state
#   cannot be read or parsed.
_mq_read_state() {
  local owner="$1" name="$2" number="$3" raw
  raw=$(gh api graphql -F owner="$owner" -F name="$name" -F number="$number" -f query='
    query($owner:String!, $name:String!, $number:Int!) {
      repository(owner:$owner, name:$name) {
        pullRequest(number:$number) {
          id
          state
          headRefOid
          mergeQueueEntry { id }
          latestOpinionatedReviews(first: 100, writersOnly: true) {
            nodes { state commit { oid } author { login } }
          }
        }
      }
    }' 2>/dev/null) || return 1
  printf '%s' "$raw" | jq -ce '
    .data.repository.pullRequest
    | select(. != null and (.id // "") != "" and (.headRefOid // "") != "" and (.state // "") != "")
    | .headRefOid as $h
    | {id, state, head: $h,
       queued: (.mergeQueueEntry != null),
       approved: ([(.latestOpinionatedReviews.nodes // [])[]?
                   | select(.state == "APPROVED" and (.commit.oid // "") == $h)] | length > 0)}
  ' 2>/dev/null
}

# _mq_read_state_retry <owner> <name> <number>
#   _mq_read_state with a bounded retry (#2186). The helper runs right after an
#   approval was dismissed, and the window that matters is seconds long, so one
#   transient GraphQL error must not end the check. Tunables (also for tests):
#   MQ_READ_ATTEMPTS (default 3) and MQ_READ_RETRY_DELAY_SEC (default 2).
#   Non-zero when every attempt failed.
_mq_read_state_retry() {
  local owner="$1" name="$2" number="$3" st i
  local attempts="${MQ_READ_ATTEMPTS:-3}" delay="${MQ_READ_RETRY_DELAY_SEC:-2}"
  [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=3
  [[ "$delay" =~ ^[0-9]+$ ]] || delay=2
  for ((i = 1; i <= attempts; i++)); do
    if st=$(_mq_read_state "$owner" "$name" "$number"); then
      printf '%s' "$st"
      return 0
    fi
    if [ "$i" -lt "$attempts" ]; then
      echo "  merge-queue: live-state read failed (attempt $i of $attempts) — retrying" >&2
      [ "$delay" -gt 0 ] && sleep "$delay"
    fi
  done
  return 1
}

# _mq_post_notice <owner> <name> <number> <pr_url> <head> <body> [marker_prefix]
#   Post <body> unless a comment carrying this head's marker already exists, so
#   repeat runs at one head post one notice. If the comments cannot be listed,
#   post anyway: a missing notice is worse than a duplicate.
_mq_post_notice() {
  local owner="$1" name="$2" number="$3" pr_url="$4" head="$5" body="$6"
  local marker_prefix="${7:-$MQ_DEQUEUE_MARKER_PREFIX}"
  local marker="${marker_prefix}${head} -->" found status_found=0
  found=$(gh api --paginate "repos/$owner/$name/issues/$number/comments" 2>/dev/null \
      | jq -s -r --arg m "$marker" 'flatten | map(select((.body // "") | contains($m))) | length' 2>/dev/null) || status_found=$?
  if [ "$status_found" -eq 0 ] && [ -n "$found" ]; then
    if [ "$found" -gt 0 ]; then
      echo "  merge-queue: notice for ${head:0:8} already posted on $pr_url — not posting again"
      return 0
    fi
  else
    echo "::warning::merge-queue: could not list comments on $pr_url — posting the dequeue notice without a duplicate check"
  fi
  if ! gh pr comment "$pr_url" --body "$body" >/dev/null 2>&1; then
    echo "::warning::merge-queue: failed to post the dequeue notice on $pr_url"
  fi
  return 0
}

# mq_dequeue_if_unapproved <pr_url>
#   If the PR is open, in the merge queue, and no approval stands for its current
#   head, dequeue it (GraphQL dequeuePullRequest) and post one marker notice.
#   Otherwise do nothing. A PR that merged or left the queue before the call is a
#   no-op. A failed dequeue posts one notice asking a maintainer to remove the PR
#   by hand. Always returns 0.
mq_dequeue_if_unapproved() {
  local pr_url="${1:-}" owner name number
  if [[ "$pr_url" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    owner="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    number="${BASH_REMATCH[3]}"
  else
    echo "::warning::merge-queue: could not parse owner/name/number from '$pr_url' — skipping the dequeue check"
    return 0
  fi

  local st status_st=0
  st=$(_mq_read_state_retry "$owner" "$name" "$number") || status_st=$?
  if [ "$status_st" -ne 0 ]; then
    echo "::warning::merge-queue: could not read the merge-queue and review state of $pr_url — cannot tell whether a queued PR lost its last approval; check the queue by hand (#2174)"
    # Surface it where a maintainer looks, not only in the run log (#2186). No PR
    # comment on this path: most PRs that reach it are not in the queue at all.
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      {
        printf '### Merge queue: state unknown after an approval was withdrawn\n\n'
        printf 'The live merge-queue and review state of %s could not be read after every retry. ' "$pr_url"
        printf 'If that pull request is in the merge queue it may merge without an approval: check the queue and remove it by hand if needed.\n\n'
      } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
    fi
    return 0
  fi

  local pr_id pr_state head queued approved
  pr_id=$(jq -r '.id' <<<"$st")
  pr_state=$(jq -r '.state' <<<"$st")
  head=$(jq -r '.head' <<<"$st")
  queued=$(jq -r '.queued' <<<"$st")
  approved=$(jq -r '.approved' <<<"$st")

  if [ "$pr_state" != "OPEN" ]; then
    echo "  merge-queue: $pr_url is $pr_state — nothing to dequeue"
    return 0
  fi
  if [ "$queued" != "true" ]; then
    echo "  merge-queue: $pr_url is not in the merge queue — nothing to do"
    return 0
  fi
  if [ "$approved" = "true" ]; then
    echo "  merge-queue: an approval stands for head ${head:0:8} — $pr_url stays queued"
    return 0
  fi

  echo "  merge-queue: $pr_url is queued with no approval standing for head ${head:0:8} — dequeuing (#2174)"
  local err_file err rc=0
  err_file=$(mktemp -t "mq.XXXXXX") || {
    echo "::warning::merge-queue: failed to create temporary file for error logging"
    return 0
  }
  gh api graphql -f id="$pr_id" -f query='
    mutation($id: ID!) {
      dequeuePullRequest(input: {id: $id}) { mergeQueueEntry { id } }
    }' >/dev/null 2>"$err_file" || rc=$?
  err=$(head -3 "$err_file" 2>/dev/null | tr '\n' ' ')
  rm -f "$err_file"

  local body
  if [ "$rc" -eq 0 ]; then
    body=$(cat <<EOF
${MQ_DEQUEUE_MARKER_PREFIX}${head} -->
## Removed from the merge queue: approval withdrawn

The automated review withdrew its approval while this PR was in the merge queue, and no other approval stands for the current head commit \`${head}\`. GitHub checks reviews only when a PR joins the queue, not when the queue merges it, so the PR was removed from the queue to stop it merging without an approval.

**What happens next:** the PR needs an approval for its head commit again. Address the review findings, or a maintainer approves it. Once an approval stands, dev-lead re-enables auto-merge on its next pass and the PR rejoins the queue; a maintainer can also re-add it by hand.
EOF
)
    _mq_post_notice "$owner" "$name" "$number" "$pr_url" "$head" "$body"
    return 0
  fi

  # The call failed. If the PR merged or left the queue in the meantime, the
  # dequeue is moot: a no-op, never an error.
  local st2 status2=0
  st2=$(_mq_read_state "$owner" "$name" "$number") || status2=$?
  if [ "$status2" -eq 0 ]; then
    local st2_state st2_queued
    st2_state=$(jq -r '.state' <<<"$st2")
    st2_queued=$(jq -r '.queued' <<<"$st2")
    if [ "$st2_state" != "OPEN" ] || [ "$st2_queued" != "true" ]; then
      echo "  merge-queue: $pr_url merged or left the queue before the dequeue call — nothing to do"
      return 0
    fi
  fi

  echo "::warning::merge-queue: dequeuePullRequest failed for $pr_url (head ${head:0:8}) — a maintainer must remove it from the merge queue by hand. API said: ${err}"
  body=$(cat <<EOF
${MQ_DEQUEUE_FAILED_MARKER_PREFIX}${head} -->
## Action needed: remove this PR from the merge queue manually

The automated review withdrew its approval while this PR was in the merge queue, and no other approval stands for the current head commit \`${head}\`. GitHub checks reviews only when a PR joins the queue, so the queue can still merge this PR. The automatic removal failed.

**A maintainer must remove this PR from the merge queue by hand** (the merge box on the PR page, "Remove from queue"). After that, the PR needs an approval for its head commit before it can rejoin the queue.
EOF
)
  _mq_post_notice "$owner" "$name" "$number" "$pr_url" "$head" "$body" "$MQ_DEQUEUE_FAILED_MARKER_PREFIX"
  return 0
}
