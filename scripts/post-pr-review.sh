#!/usr/bin/env bash
# Post a PR review based on a verdict JSON.
#
# Inputs:
#   $1 — PR URL
#   $2 — path to verdict JSON (contains decision, risk, summary, findings, body)
#   $3 — DRY_RUN (true/false)
#
# Verdict JSON format:
#   {
#     "decision": "approve|escalate",
#     "risk": "LOW|MEDIUM|HIGH",
#     "summary": "...",
#     "findings": [...],
#     "body": "full markdown review body",
#     "escalate_to_ai": false
#   }

set -euo pipefail

PR_URL="${1:?usage: post-pr-review.sh <pr-url> <verdict-json> <dry-run>}"
VERDICT_JSON="${2:?}"
DRY_RUN="${3:-false}"
PR_HEAD_SHA="${PR_HEAD_SHA:?PR_HEAD_SHA must be set}"

if [ ! -f "$VERDICT_JSON" ]; then
  echo "ERROR: verdict JSON not found at $VERDICT_JSON"
  exit 1
fi

# PR-metadata digest helper (issue #1551) — used to stamp `meta=<digest>` into a
# metadata-only fix-request marker so a later body/label/linked-issue edit can
# re-arm the review without a new commit.
POST_PR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pr-metadata-digest.sh
source "$POST_PR_SCRIPT_DIR/lib/pr-metadata-digest.sh"
# shellcheck source=lib/verify-approval-review.sh
source "$POST_PR_SCRIPT_DIR/lib/verify-approval-review.sh"
# shellcheck source=lib/merge-queue-dequeue.sh
source "$POST_PR_SCRIPT_DIR/lib/merge-queue-dequeue.sh"

# The account this run acts as and the secret holding its PAT — named in the
# #1874 loud-failure diagnostic so a stranded approval points straight at the
# credential. BOT_USER is set by the workflow; POSTING_CREDENTIAL defaults to the
# pr-review posting secret and encodes the known classic-vs-fine-grained hazard.
BOT_USER="${BOT_USER:-donpetry-bot}"
POSTING_CREDENTIAL="${POSTING_CREDENTIAL:-DON_PETRY_BOT_GH_PAT_CLASSIC (classic PAT required for addPullRequestReview; the fine-grained DON_PETRY_BOT_GH_PAT fallback cannot create reviews)}"

# verify_approval_landed <pr_url>
#   Read back GET /pulls/<n>/reviews and decide whether the approval WRITE we just
#   issued actually produced a review object (issue #1874). Echoes one verdict:
#     PRESENT       — an APPROVED review by BOT_USER at PR_HEAD_SHA exists.
#     ABSENT        — the reviews list was read AND no such review exists: a
#                     DEFINITE negative (the write silently failed). Fail loud.
#     INDETERMINATE — the reviews API could not be read: fail OPEN (a transient
#                     blip must not turn a genuine approval into a red run — the
#                     same posture as the #1776 authorization preflight).
#   A short retry absorbs read-your-writes eventual consistency before concluding
#   ABSENT.
verify_approval_landed() {
  local pr_url="$1" owner_repo pr_num reviews rc
  owner_repo=$(echo "$pr_url" | sed -E 's|.*/([^/]+)/([^/]+)/pull/.*|\1/\2|')
  pr_num=$(echo "$pr_url" | sed -E 's|.*/([0-9]+)$|\1|')

  local attempt
  for attempt in 1 2 3; do
    rc=0
    # `gh api --paginate` streams one JSON array per page (`[...][...]`); `--slurp`
    # wraps the pages into a single array and `jq 'add'` concatenates them into one
    # flat reviews array, so an approval that landed on a later page is not missed
    # (#1875).
    reviews=$(
      gh api --paginate --slurp "repos/$owner_repo/pulls/$pr_num/reviews" 2>/dev/null |
        jq 'add'
    ) || rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$reviews" ]; then
      if approval_review_present "$reviews" "$BOT_USER" "$PR_HEAD_SHA"; then
        echo "PRESENT"; return 0
      fi
      # Read succeeded but the review is not there yet — retry briefly for
      # eventual consistency, then conclude ABSENT.
      [ "$attempt" -lt 3 ] && sleep 2 && continue
      echo "ABSENT"; return 0
    fi
    [ "$attempt" -lt 3 ] && sleep 2
  done
  echo "INDETERMINATE"
}

# maybe_post_deferred_partial_evidence <pr_url>
#   Post the partial-evidence announcement (#1596) that the advisory gate DEFERRED
#   into PARTIAL_EVIDENCE_STATE_FILE — but only now, AFTER the approval has been
#   verified to exist (issue #1874 AC3). If the gate did not defer anything, this
#   is a no-op. The gate no longer posts this comment itself precisely so a
#   never-landed approval can never be announced.
maybe_post_deferred_partial_evidence() {
  local pr_url="$1"
  local statefile="${PARTIAL_EVIDENCE_STATE_FILE:-}"
  [ -n "$statefile" ] && [ -s "$statefile" ] || return 0

  local submitted required reason
  read -r submitted required reason < "$statefile" || return 0
  [ -n "$submitted" ] || return 0

  # Compose the marker + gate log helpers, then dedup against existing comments.
  # shellcheck source=lib/advisory-review-gate.sh
  source "$POST_PR_SCRIPT_DIR/lib/advisory-review-gate.sh" 2>/dev/null || true
  # shellcheck source=lib/partial-evidence-marker.sh
  source "$POST_PR_SCRIPT_DIR/lib/partial-evidence-marker.sh"
  local comments_json
  comments_json=$(gh pr view "$pr_url" --json comments 2>/dev/null || echo '{}')
  # Only discard the deferred facts once the marker has actually landed. If the
  # post fails, keep the state file so a later sweep can retry — deleting it here
  # would permanently lose the partial-evidence facts (#1875).
  if maybe_post_partial_evidence_marker "$pr_url" "$PR_HEAD_SHA" "$submitted" "$required" "$reason" "$comments_json"; then
    rm -f "$statefile"
  else
    echo "::warning::partial-evidence marker post failed on ${pr_url} — approval may be uncounted by the miss-rate metric (#1596); retaining $statefile for a later sweep"
  fi
}

# Extract fields from verdict
DECISION=$(jq -r '.decision' "$VERDICT_JSON")
RISK=$(jq -r '.risk' "$VERDICT_JSON")
BODY=$(jq -r '.body // ""' "$VERDICT_JSON")
# metadata_only (#1551): the reviewer sets this true when EVERY blocking finding
# is fixable by editing PR metadata alone (body / labels / linked issues) with no
# code change. Absent/false ⇒ current behavior (no digest stamp, commit-only
# re-arm), so an un-flagged or code-change fix-request cannot be re-armed by a
# body edit (AC3).
METADATA_ONLY=$(jq -r '.metadata_only // false' "$VERDICT_JSON")

# Derive the approval marker word from the verdict, not from model-written text
# (issue #2169). The verdict vocabulary is `approve`, but every marker consumer
# (the #1754 guard below, review-one-pr.sh, carry-forward, the miss-rate metric)
# expects the past tense `decision=approved`. cascade-action.md substituted the
# raw verdict word, so a valid approve verdict failed the guard on formatting
# alone and nothing was posted. Normalize only the present-tense word inside the
# head-SHA v1 marker; a missing or contradictory decision still fails closed.
if [ "$DECISION" = "approve" ]; then
  # -z treats the body as one record so a marker wrapped across lines still
  # matches. Detect changes without command substitution stripping newlines: write
  # to temp files and compare via cmp, so a trailing-newline-only difference
  # doesn't falsely trigger a substitution when sed made no actual change (#2169).
  BODY_FILE="$(mktemp)"
  NORMALIZED_FILE="$(mktemp)"
  printf '%s' "$BODY" > "$BODY_FILE"
  sed -E -z \
    "s/(<!-- pr-review-agent v1 sha=${PR_HEAD_SHA}[[:space:]][^>]*decision=)approve([[:space:]]|-->)/\1approved\2/" \
    "$BODY_FILE" > "$NORMALIZED_FILE"
  if ! cmp -s "$BODY_FILE" "$NORMALIZED_FILE"; then
    echo "  approval marker said decision=approve — normalized to decision=approved from the verdict (#2169)"
    BODY="$(cat "$NORMALIZED_FILE")"
  fi
  rm -f "$BODY_FILE" "$NORMALIZED_FILE"
fi

# Marker keying the single human-escalation artifact (issue #1754 AC2). An
# escalation must leave a visible, updatable comment on the PR — not just a
# label. The comment is upserted (created once, then patched in place) so a
# repeated escalation at an unchanged head does not append a fresh copy.
ESCALATION_COMMENT_MARKER='<!-- pr-review-agent human-escalation v1 -->'

# upsert_escalation_comment <pr_url> <body>
# Post the escalation artifact if the marker is not yet present, otherwise edit
# the existing marker-keyed comment in place. Best-effort: an API failure emits a
# ::warning:: (so a silently-dropped artifact is visible) but never aborts the
# escalation — the label + CODEOWNERS request still stand. Returns 0 only when
# the artifact is confirmed written (comment created or patched), 1 otherwise, so
# the caller never reports an escalation that left nothing visible (#1754).
upsert_escalation_comment() {
  local pr_url="$1" body="$2"
  local owner_repo pr_num comments_file existing_id bot_user
  owner_repo=$(echo "$pr_url" | sed -E 's|.*/([^/]+)/([^/]+)/pull/.*|\1/\2|')
  pr_num=$(echo "$pr_url" | sed -E 's|.*/([0-9]+)$|\1|')
  # The escalation artifact is authored by BOT_USER (gh posts as the
  # authenticated account). Selecting the comment to patch requires BOTH the
  # marker AND a matching author: a human (or another bot) who happens to quote
  # the marker must never be selected and PATCHed over (#1754).
  bot_user="${BOT_USER:-donpetry-bot}"

  comments_file=$(mktemp)
  existing_id=""
  if gh api --paginate "repos/$owner_repo/issues/$pr_num/comments" >"$comments_file" 2>/dev/null; then
    existing_id=$(jq -s -r --arg m "$ESCALATION_COMMENT_MARKER" --arg bot "$bot_user" '
      flatten
      | map(select(.body != null and (.body | contains($m)) and ((.user.login // "") == $bot)))
      | (.[0].id // "")
    ' "$comments_file" 2>/dev/null || true)
  else
    echo "::warning::escalation: could not list comments on $pr_url — posting a fresh escalation note"
  fi
  rm -f "$comments_file"

  if [ -n "${existing_id:-}" ]; then
    echo "  updating human-escalation comment $existing_id in place"
    if ! jq -n --arg b "$body" '{body: $b}' \
         | gh api -X PATCH "repos/$owner_repo/issues/comments/$existing_id" --input - >/dev/null 2>&1; then
      # The in-place update failed — fall back to posting a fresh agent comment
      # so the escalation still leaves a visible artifact rather than only a
      # ::warning:: and a bare label (#1754 AC2).
      echo "::warning::escalation: failed to update human-escalation comment $existing_id on $pr_url — posting a fresh escalation note instead"
      if ! gh pr comment "$pr_url" --body "$body" >/dev/null 2>&1; then
        echo "::warning::escalation: also failed to post a fresh human-escalation comment on $pr_url — the PR carries only the label"
        return 1
      fi
    fi
  else
    echo "  posting human-escalation comment"
    if ! gh pr comment "$pr_url" --body "$body" >/dev/null 2>&1; then
      echo "::warning::escalation: failed to post human-escalation comment on $pr_url — the PR carries only the label"
      return 1
    fi
  fi
  return 0
}

# mark_prior_agent_items_obsolete <pr_url>
# After successfully posting a new review/comment, dismiss prior agent reviews
# (state != DISMISSED) and collapse prior agent comments. Identifies agent
# items by the body marker `<!-- pr-review-agent v1 sha=<HEX> -->`. The newest
# agent item by timestamp (which is the just-posted one) is preserved.
# Idempotent: prior comments already wrapped in a `<!-- pr-review-agent
# superseded -->` sentinel are skipped to avoid recursive nesting.
#
# API failures here do NOT abort the workflow — the new post has already
# landed. They DO emit ::warning:: annotations so silent stack-up of
# duplicates becomes visible in the Actions UI rather than degrading
# unnoticed (e.g., a permissions change on the dismissal endpoint).
mark_prior_agent_items_obsolete() {
  local pr_url="$1"
  local owner_repo pr_num
  owner_repo=$(echo "$pr_url" | sed -E 's|.*/([^/]+)/([^/]+)/pull/.*|\1/\2|')
  pr_num=$(echo "$pr_url" | sed -E 's|.*/([0-9]+)$|\1|')

  # Stage the API responses to disk. Routing the JSON through shell vars
  # (or --argjson) breaks on rare unescaped control chars in user-authored
  # comment bodies — jq sees raw control characters and refuses to parse.
  # Reading from a file with `jq ... <file>` sidesteps this entirely.
  local reviews_file comments_file fetch_err
  reviews_file=$(mktemp)
  comments_file=$(mktemp)
  if ! gh api --paginate "repos/$owner_repo/pulls/$pr_num/reviews" >"$reviews_file" 2>/tmp/agent-cleanup-err.$$; then
    fetch_err=$(cat /tmp/agent-cleanup-err.$$ 2>/dev/null || true)
    rm -f /tmp/agent-cleanup-err.$$ "$reviews_file" "$comments_file"
    echo "::warning::cleanup: failed to list reviews for $pr_url — duplicates may stack until resolved. API said: $fetch_err"
    return 0
  fi
  rm -f /tmp/agent-cleanup-err.$$
  if ! gh api --paginate "repos/$owner_repo/issues/$pr_num/comments" >"$comments_file" 2>/tmp/agent-cleanup-err.$$; then
    fetch_err=$(cat /tmp/agent-cleanup-err.$$ 2>/dev/null || true)
    echo "::warning::cleanup: failed to list comments for $pr_url — stale comments may persist until resolved. API said: $fetch_err"
    echo '[]' > "$comments_file"
  fi
  rm -f /tmp/agent-cleanup-err.$$

  # Compute the timestamp of the just-posted item: the globally-latest agent
  # item across BOTH reviews and comments (whichever category we just posted
  # to). Items at this timestamp are preserved; everything else is stale.
  # An earlier version preserved "newest of each category" separately, which
  # incorrectly left a stale comment in place when the new post was a review
  # (or vice versa).
  local newest_when
  newest_when=$(jq -rn --slurpfile r "$reviews_file" --slurpfile c "$comments_file" '
    (($r[0] // []) | map(select(.body != null and (.body | test("<!-- pr-review-agent v1 sha=[a-f0-9]+"))) | .submitted_at)) +
    (($c[0] // []) | map(select(.body != null and (.body | test("<!-- pr-review-agent v1 sha=[a-f0-9]+"))) | .created_at))
    | max // ""
  ' 2>/dev/null || true)

  # Reviews: dismiss every prior agent review except the just-posted one.
  # State must be APPROVED, COMMENTED, or CHANGES_REQUESTED to be dismissable;
  # DISMISSED ones are already handled, and PENDING ones aren't ours.
  local stale_review_ids
  stale_review_ids=$(jq -r --arg keep "$newest_when" '
    map(select(.body != null and (.body | test("<!-- pr-review-agent v1 sha=[a-f0-9]+"))))
    | map(select(.submitted_at != $keep))
    | .[]
    | select(.state == "APPROVED" or .state == "COMMENTED" or .state == "CHANGES_REQUESTED")
    | .id
  ' "$reviews_file" 2>/dev/null || true)

  local dismiss_err current_state
  if [ -n "$stale_review_ids" ]; then
    while IFS= read -r review_id; do
      [ -z "$review_id" ] && continue
      # Re-check the review's current state to avoid 422s from race conditions
      # (state may have changed between enumeration and dismissal).
      current_state=$(gh api "repos/$owner_repo/pulls/$pr_num/reviews/$review_id" \
        --jq '.state' 2>/dev/null || echo "UNKNOWN")
      case "$current_state" in
        APPROVED|COMMENTED|CHANGES_REQUESTED)
          echo "  dismissing prior agent review $review_id (superseded by $PR_HEAD_SHA)"
          dismiss_err=$(gh api -X PUT "repos/$owner_repo/pulls/$pr_num/reviews/$review_id/dismissals" \
            -f message="Superseded by automated re-review at $PR_HEAD_SHA." \
            2>&1 >/dev/null) || {
            echo "::warning::cleanup: failed to dismiss prior agent review $review_id on $pr_url — duplicates will stack until resolved. API said: $(echo "$dismiss_err" | head -3 | tr '\n' ' ')"
          }
          ;;
        *)
          echo "  skipping review $review_id (state: $current_state — already dismissed or not dismissable)"
          ;;
      esac
    done <<< "$stale_review_ids"
  fi

  # Comments: edit each prior agent comment to wrap its body in a collapsed
  # <details> block. The sentinel `<!-- pr-review-agent superseded -->`
  # prevents re-wrapping on subsequent runs. Pull just the IDs here and
  # re-fetch each body individually — keeping the body off the shell pipeline
  # avoids the same control-char issue noted on the file-staging block above.
  local stale_comment_ids
  stale_comment_ids=$(jq -r --arg keep "$newest_when" '
    map(select(.body != null and (.body | test("<!-- pr-review-agent v1 sha=[a-f0-9]+"))))
    | map(select(.created_at != $keep))
    | .[]
    | select(.body | test("<!-- pr-review-agent superseded -->") | not)
    | .id
  ' "$comments_file" 2>/dev/null || true)

  local edit_err old_body new_body
  if [ -n "$stale_comment_ids" ]; then
    while IFS= read -r cid; do
      [ -z "$cid" ] && continue
      echo "  collapsing prior agent comment $cid (superseded by $PR_HEAD_SHA)"
      old_body=$(gh api "repos/$owner_repo/issues/comments/$cid" --jq '.body' 2>/dev/null) || {
        echo "::warning::cleanup: failed to fetch prior agent comment $cid on $pr_url — skipping collapse"
        continue
      }
      new_body=$(printf '<!-- pr-review-agent superseded -->\n<details><summary><em>Superseded by automated re-review at <code>%s</code> — click to expand prior review.</em></summary>\n\n%s\n\n</details>' \
        "$PR_HEAD_SHA" "$old_body")
      edit_err=$(jq -n --arg b "$new_body" '{body: $b}' \
        | gh api -X PATCH "repos/$owner_repo/issues/comments/$cid" --input - 2>&1 >/dev/null) || {
        echo "::warning::cleanup: failed to collapse prior agent comment $cid on $pr_url — stale comment will persist. API said: $(echo "$edit_err" | head -3 | tr '\n' ' ')"
      }
    done <<< "$stale_comment_ids"
  fi

  rm -f "$reviews_file" "$comments_file"
}

# ── needs-human-review label state helpers (#1754) ──────────────────────────
# A dropped label mutation is a correctness bug, not a cosmetic one: a stale
# needs-human-review left after a fix-request keeps review-one-pr.sh on hold
# while this script reports success; a missing label after an escalation lets
# review-one-pr.sh re-engage the cascade even though this branch returned 101.
# So label reads and mutations are retried, and the required state is CONFIRMED
# by a follow-up read before the caller reports success.
LABEL_MAX_ATTEMPTS="${LABEL_MAX_ATTEMPTS:-3}"
LABEL_RETRY_DELAY="${LABEL_RETRY_DELAY:-2}"

# read_hold_label <pr_url> — prints "true"/"false"; returns non-zero if the read
# itself failed (so a failed read is distinguishable from a confirmed absence).
read_hold_label() {
  local pr_url="$1" out
  out=$(gh pr view "$pr_url" --json labels \
    --jq '[.labels[].name] | any(. == "needs-human-review")' 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# ensure_hold_label_present <pr_url> — add needs-human-review and CONFIRM it is
# present, retrying read+mutation. Idempotent: an already-present label short-
# circuits with no redundant add (#1754 AC3 — no unlabel/relabel churn). Returns
# 0 once presence is confirmed, non-zero if it cannot be established.
ensure_hold_label_present() {
  local pr_url="$1" attempt present
  for attempt in $(seq 1 "$LABEL_MAX_ATTEMPTS"); do
    present=$(read_hold_label "$pr_url") || present="unknown"
    if [ "$present" = "true" ]; then
      [ "$attempt" -eq 1 ] && echo "  needs-human-review already present — leaving label unchanged (idempotent, #1754 AC3)"
      return 0
    fi
    gh pr edit "$pr_url" --add-label needs-human-review >/dev/null 2>&1 || true
    present=$(read_hold_label "$pr_url") || present="unknown"
    [ "$present" = "true" ] && return 0
    [ "$attempt" -lt "$LABEL_MAX_ATTEMPTS" ] && sleep "$LABEL_RETRY_DELAY"
  done
  return 1
}

# ensure_hold_label_absent <pr_url> — remove needs-human-review and CONFIRM it is
# gone, retrying read+mutation. A label already absent short-circuits with no
# mutation. Returns 0 once absence is confirmed, non-zero if it cannot be
# established.
ensure_hold_label_absent() {
  local pr_url="$1" attempt present
  for attempt in $(seq 1 "$LABEL_MAX_ATTEMPTS"); do
    present=$(read_hold_label "$pr_url") || present="unknown"
    if [ "$present" = "false" ]; then
      return 0
    fi
    gh pr edit "$pr_url" --remove-label needs-human-review >/dev/null 2>&1 || true
    present=$(read_hold_label "$pr_url") || present="unknown"
    [ "$present" = "false" ] && return 0
    [ "$attempt" -lt "$LABEL_MAX_ATTEMPTS" ] && sleep "$LABEL_RETRY_DELAY"
  done
  return 1
}

# hold_label_is_automated <pr_url> — exit 0 only when the LATEST `labeled` event
# for needs-human-review was made by automation (a `[bot]` App, BOT_USER, or an
# AUTOMATION_BOT_LOGINS account). A human-set hold is deliberate and re-engagement
# is human-gated (#926/#1754), so anything else — a human actor, no event found,
# or an unreadable timeline — is treated as NOT automated (fail closed: the hold
# is left alone).
hold_label_is_automated() {
  local pr_url="$1" owner_repo pr_num actor bot_logins
  owner_repo=$(echo "$pr_url" | sed -E 's|.*/([^/]+)/([^/]+)/pull/.*|\1/\2|')
  pr_num=$(echo "$pr_url" | sed -E 's|.*/([0-9]+)$|\1|')
  actor=$(gh api --paginate "repos/$owner_repo/issues/$pr_num/events?per_page=100" 2>/dev/null \
    | jq -s -r 'flatten
        | map(select(.event == "labeled" and .label.name == "needs-human-review"))
        | (last.actor.login // "")' 2>/dev/null) || return 1
  [ -n "$actor" ] || return 1
  bot_logins="${AUTOMATION_BOT_LOGINS:-donpetry-bot github-actions[bot] repair-pr-approvals} ${BOT_USER:-donpetry-bot}"
  case "$actor" in *"[bot]") return 0 ;; esac
  case " $bot_logins " in *" $actor "*) return 0 ;; esac
  return 1
}

# clear_automated_hold_label <pr_url> — remove needs-human-review (confirmed) only
# when it is absent already or was set by automation; a human-set hold is left in
# place. Returns non-zero only if an automated hold could not be confirmed removed.
clear_automated_hold_label() {
  local pr_url="$1" present
  present=$(read_hold_label "$pr_url") || present="unknown"
  if [ "$present" = "false" ]; then
    return 0
  fi
  if ! hold_label_is_automated "$pr_url"; then
    echo "  needs-human-review not provably automation-set (human actor or undeterminable provenance) — leaving the hold in place (#926/#1754)"
    return 0
  fi
  ensure_hold_label_absent "$pr_url"
}

if [ "$DRY_RUN" = "true" ]; then
  echo "=== DRY RUN: Would post review ==="
  echo "Decision: $DECISION"
  echo "Risk: $RISK"
  echo "Body:"
  echo "$BODY"
  exit 0
fi

if [ "$DECISION" = "skip" ]; then
  REASON=$(jq -r '.reason // "unspecified"' "$VERDICT_JSON")
  echo "    reviewer returned skip ($REASON) — treating as no-op"
  exit 100
fi
if [ "$DECISION" != "approve" ] && [ "$DECISION" != "escalate" ]; then
  echo "ERROR: invalid decision '$DECISION'"
  exit 1
fi

# Post the review/comment based on decision
if [ "$DECISION" = "approve" ]; then
  # Fail closed on an empty or marker-less body (issue #1754 AC4). A review with
  # `body=0chars`, or one lacking the `<!-- pr-review-agent v1 sha=… -->` marker,
  # is discarded on the next cycle ("prior review body missing valid marker") —
  # the PR looks unreviewed while the run claims success. Either the review
  # carries its marker AND a body, or it is not submitted.
  if [ -z "${BODY//[[:space:]]/}" ] || [[ "$BODY" != *"pr-review-agent v1 sha="* ]]; then
    echo "::error::approve verdict has an empty or marker-less body — refusing to submit a bodyless review (fail closed, #1754 AC4)"
    exit 1
  fi

  # Verify the SHA in the approval marker matches the current PR_HEAD_SHA
  if [[ "$BODY" =~ pr-review-agent\ v1\ sha=([a-f0-9]+) ]]; then
    MARKER_SHA="${BASH_REMATCH[1]}"
  else
    MARKER_SHA=""
  fi
  if [ -z "$MARKER_SHA" ] || [ "$MARKER_SHA" != "$PR_HEAD_SHA" ]; then
    echo "::error::approve verdict marker SHA ($MARKER_SHA) does not match PR_HEAD_SHA ($PR_HEAD_SHA) — refusing to submit (fail closed)"
    exit 1
  fi

  # Require one COMPLETE approval marker for PR_HEAD_SHA — sha= and
  # decision=approved in the SAME marker comment (issue #1754). An approval
  # marker is `<!-- pr-review-agent v1 sha=<SHA> decision=approved risk=... -->`
  # (sha and decision together), whereas a fix-request keeps them in SEPARATE
  # markers (`… sha=<SHA> --> <!-- decision=fix-requested …>`). Matching sha and
  # decision within one marker (no `>` between them) therefore accepts only a
  # genuine approval and rejects a current-SHA fix-request or a decision-less
  # body from reaching `gh pr review --approve`.
  approval_pattern="<!-- pr-review-agent v1 sha=${PR_HEAD_SHA}[[:space:]][^>]*decision=approved[^>]*-->"
  if ! [[ "$BODY" =~ $approval_pattern ]]; then
    echo "::error::approve verdict body lacks a complete approval marker (sha=$PR_HEAD_SHA with decision=approved in one marker) — refusing to submit (fail closed, #1754)"
    exit 1
  fi

  # Post an APPROVED review
  BODY_FILE="/tmp/pr-review-body-$$.txt"
  echo "$BODY" > "$BODY_FILE"

  echo "Posting APPROVED review..."
  REVIEW_ERR_FILE="/tmp/pr-review-err-$$.txt"
  review_err=""
  body_content=$(cat "$BODY_FILE")
  # Use an explicit else branch (no `!`) so `rc=$?` captures the REAL exit code of
  # `gh pr review`. With `if ! gh …; then rc=$?` the `!` inverts the status, so the
  # failure branch always saw rc=0 and the #1874 diagnostic misreported a success.
  if gh pr review "$PR_URL" --approve --body "$body_content" 2>"$REVIEW_ERR_FILE"; then
    rm -f "$BODY_FILE" "$REVIEW_ERR_FILE"
  else
    rc=$?
    review_err=$(cat "$REVIEW_ERR_FILE" 2>/dev/null || true)
    cat "$REVIEW_ERR_FILE" >&2 2>/dev/null || true
    rm -f "$BODY_FILE" "$REVIEW_ERR_FILE"
    # Self-approval is a permanent, PR-specific constraint — never the runner's
    # fault and never recoverable on retry. Exit 100 (no-op sentinel) so the
    # workflow loop skips this PR without aborting the rest of the session.
    # See issue #96: a single self-authored PR at the top of the queue
    # previously starved every batch.
    if [[ "$review_err" =~ [Cc]an\ not\ approve\ your\ own\ pull\ request ]]; then
      echo "::warning::Cannot self-approve $PR_URL — skipping (exit 100)"
      exit 100
    fi
    # The approval write FAILED (issue #1874). Fail loud and name every fact a
    # human needs — the PR, the account we acted as, the credential secret, and
    # the raw API error — then exit non-zero. Never treat a failed write as
    # success: doing so is exactly how a PR stranded behind an approval that
    # existed only in a comment (PRs #1788/#1858/#1860).
    echo "::error::pr-review approval WRITE FAILED on $PR_URL as '$BOT_USER' (credential $POSTING_CREDENTIAL): gh pr review --approve exited $rc and created NO review object. API said: $(echo "$review_err" | head -3 | tr '\n' ' '). The PR is stranded at REVIEW_REQUIRED — do NOT announce an approval that did not land (#1874)."
    exit 1
  fi

  # #1874: `gh pr review --approve` can exit 0 while NO review object is created
  # (a fine-grained PAT authenticates and returns success but cannot
  # addPullRequestReview). Trusting the exit code is what let the strand go
  # unreported. Verify the post-condition by reading the reviews back.
  APPROVAL_STATE=$(verify_approval_landed "$PR_URL")
  APPROVAL_VERIFIED=false
  case "$APPROVAL_STATE" in
    PRESENT)
      APPROVAL_VERIFIED=true # verified — the review object exists at head
      ;;
    ABSENT)
      echo "::error::pr-review approval WRITE reported success but NO review object exists on $PR_URL for '$BOT_USER' (credential $POSTING_CREDENTIAL). GET /pulls/.../reviews contains no APPROVED review by that account at $PR_HEAD_SHA — the write silently failed (a fine-grained PAT can comment but cannot addPullRequestReview). The PR is stranded at REVIEW_REQUIRED; failing the run rather than announcing a phantom approval (#1874)."
      exit 1
      ;;
    *)
      # INDETERMINATE — the reviews API could not be read. Fail OPEN: a transient
      # blip must not turn a genuine approval into a red run (#1776 posture).
      echo "::warning::could not read back reviews on $PR_URL to confirm the approval landed (transient API error) — proceeding without gating; a later sweep re-verifies (#1874)"
      ;;
  esac

  # Dismiss prior agent reviews / collapse prior agent comments now that the
  # newest review has landed. Best-effort: failures here don't break the run.
  mark_prior_agent_items_obsolete "$PR_URL"

  # The cleanup above dismissed the prior approval. The new one normally stands,
  # so this is a no-op; it dequeues only if no approval stands for the head on the
  # live PR (#2174). Never fails the run.
  mq_dequeue_if_unapproved "$PR_URL" || true

  # Only a VERIFIED-present approval may trigger the deferred partial-evidence
  # announcement (#1874 AC3). On INDETERMINATE we could not confirm the review
  # object exists, so announcing would claim approval evidence that was never
  # verified — leave the deferred state intact for a later sweep to re-verify (#1875).
  if [ "$APPROVAL_VERIFIED" = "true" ]; then
    maybe_post_deferred_partial_evidence "$PR_URL"
  else
    echo "::warning::approval unverified on $PR_URL — NOT posting the deferred partial-evidence announcement; the state file is retained for a later sweep to re-verify (#1874 AC3 / #1875)"
  fi

  # Check merge state and rebase if needed.
  # This entire section is best-effort — the review is already posted, so a
  # rebase failure (403 permission, 504 timeout, etc.) must never abort the
  # batch session. Every command uses || to suppress set -e.
  MERGE_STATE=$(gh pr view "$PR_URL" --json mergeStateStatus --jq '.mergeStateStatus' 2>/dev/null || echo "UNKNOWN")
  if [ "$MERGE_STATE" = "BEHIND" ]; then
    OWNER_REPO=$(echo "$PR_URL" | sed -E 's|.*/([^/]+)/([^/]+)/pull/.*|\1/\2|')
    PR_NUM=$(echo "$PR_URL" | sed -E 's|.*/([0-9]+)$|\1|')

    echo "Branch is BEHIND, requesting rebase..."
    REBASE_OK=false
    for attempt in 1 2 3; do
      rebase_output=$(gh api -X PUT "repos/$OWNER_REPO/pulls/$PR_NUM/update-branch" \
        -f expected_head_sha="$PR_HEAD_SHA" 2>&1) && { REBASE_OK=true; break; }
      rebase_rc=$?
      if echo "$rebase_output" | grep -qE '"status":\s*"4[0-9][0-9]"'; then
        echo "::warning::rebase request rejected (client error) — $rebase_output"
        break
      fi
      if [ "$attempt" -lt 3 ]; then
        delay=$(( 5 * attempt ))
        echo "  rebase attempt $attempt failed (exit $rebase_rc), retrying in ${delay}s..."
        sleep "$delay"
      else
        echo "::warning::rebase request failed after $attempt attempts — $rebase_output"
      fi
    done

    if [ "$REBASE_OK" = "true" ]; then
      # Poll for rebase completion (up to 30s)
      for _i in 1 2 3 4 5 6; do
        MERGE_STATE=$(gh pr view "$PR_URL" --json mergeStateStatus --jq '.mergeStateStatus' 2>/dev/null || echo "UNKNOWN")
        [ "$MERGE_STATE" != "BEHIND" ] && break
        sleep 5
      done
    fi

    if [ "$MERGE_STATE" = "BEHIND" ]; then
      echo "::warning::still BEHIND after rebase — skipping auto-merge for $PR_URL"
    fi
  fi

  # Clean up an automation-set hold label, confirming the removal (a stale label
  # would keep review-one-pr.sh on hold while this run reports success, #1754).
  if ! clear_automated_hold_label "$PR_URL"; then
    echo "::error::approve: could not confirm needs-human-review removed from $PR_URL after $LABEL_MAX_ATTEMPTS attempts — failing rather than reporting a false success (#1754)"
    exit 1
  fi

  echo "Review posted"

elif [ "$DECISION" = "escalate" ]; then
  # Check if AI delegation should be used
  if [ "${AI_DELEGATION_ENABLED:-false}" = "true" ] && [ "${REVIEW_CYCLE:-0}" -lt "${MAX_REVIEW_CYCLES:-3}" ] && [ "$RISK" != "HIGH" ]; then
    # Post fix-request comment
    COMMENT_FILE="/tmp/pr-comment-$$.txt"
    NEXT_CYCLE=$((REVIEW_CYCLE + 1))
    # Strip any embedded marker from BODY before inserting — the cascade-action body
    # already carries its own marker, and a second copy would cause review-one-pr.sh
    # to count this cycle as 2 (grep -c counts matching lines), prematurely hitting
    # the max-cycle escalation cap.
    BODY_FOR_COMMENT=$(printf '%s' "$BODY" | sed 's/<!-- pr-review-agent v1 sha=[a-f0-9][^>]*-->//g')
    # For a metadata-only fix-request, stamp a metadata digest into the marker so a
    # PR body/label/linked-issue edit (which mints no new commit) re-arms the review
    # (#1551). The re-arm condition stated in the footer must match the marker: a
    # metadata-only marker re-arms on a metadata change too; every other marker
    # re-arms only on a new commit (AC3/AC4).
    META_ATTR=""
    REARM_FOOTER="_The review cascade will automatically re-review after new commits are pushed._"
    if [ "$METADATA_ONLY" = "true" ]; then
      # Only stamp `meta=` when the metadata snapshot fetch actually succeeds. A
      # transient `gh pr view` failure that fell back to `{}` would record the
      # digest of EMPTY metadata; the next re-review would compare real metadata
      # against it, spuriously conclude "metadata changed", and launch an
      # unnecessary same-SHA cascade. On fetch failure, omit `meta=` and keep the
      # commit-only footer — the metadata-only deadlock persists (safe, prior
      # behavior) rather than manufacturing false re-arm churn.
      META_SNAPSHOT=$(gh pr view "$PR_URL" --json body,closingIssuesReferences,labels 2>/dev/null || true)
      if [ -n "$META_SNAPSHOT" ] && printf '%s' "$META_SNAPSHOT" | jq -e . >/dev/null 2>&1; then
        META_DIGEST=$(compute_pr_metadata_digest "$META_SNAPSHOT")
        META_ATTR=" meta=$META_DIGEST"
        REARM_FOOTER="_The review cascade will automatically re-review after new commits are pushed, or after a change to the PR body, labels, or linked issues._"
      else
        echo "::warning::metadata snapshot fetch failed for $PR_URL — stamping a commit-only marker (no meta=)"
      fi
    fi
    cat > "$COMMENT_FILE" <<COMMENT_END
<!-- pr-review-agent v1 sha=$PR_HEAD_SHA --> <!-- decision=fix-requested risk=$RISK$META_ATTR -->

## Review — fix requested (cycle $NEXT_CYCLE/$MAX_REVIEW_CYCLES)

The automated review identified the following issues. Please address each one:

### Findings to fix
$BODY_FOR_COMMENT

### Additional tasks
1. Resolve all unresolved review thread comments from other reviewers
2. Ensure all CI checks pass after your changes
3. Rebase on the target branch if behind
4. Do NOT modify files unrelated to the findings above

$REARM_FOOTER
COMMENT_END

    echo "Posting fix-request comment..."
    # The hold is cleared only after the fix request is CONFIRMED posted: a failed
    # comment must not re-enable a held PR with no fix request on it.
    if ! gh pr comment "$PR_URL" --body "$(cat "$COMMENT_FILE")"; then
      rm -f "$COMMENT_FILE"
      echo "::error::fix-request: failed to post the fix-request comment on $PR_URL — leaving needs-human-review untouched and failing so the run is retried (#1754)"
      exit 1
    fi
    rm -f "$COMMENT_FILE"

    # Supersede prior agent reviews/comments now that the newest fix-request
    # has landed. A new fix-request also invalidates any prior approval.
    mark_prior_agent_items_obsolete "$PR_URL"

    # GitHub checks reviews only when a PR joins the merge queue. If the dismissal
    # above withdrew the last approval of a queued PR, remove it from the queue
    # (#2174). Never fails the run.
    mq_dequeue_if_unapproved "$PR_URL" || true

    # A fix-request re-engages the cascade, so clear a prior AUTOMATION-set hold —
    # a PR left carrying needs-human-review while the author works is a stale hold
    # that also exempts it from the stuck-review sweep. A hold a human set
    # deliberately is left alone (provenance check). CONFIRM the removal
    # (retrying reads+mutations): a stale label left behind would keep
    # review-one-pr.sh on hold while this branch reports success (#1754). Fail
    # rather than report a false success so the run is retried.
    if ! clear_automated_hold_label "$PR_URL"; then
      echo "::error::fix-request: could not confirm needs-human-review removed from $PR_URL after $LABEL_MAX_ATTEMPTS attempts — failing rather than reporting a false success (#1754)"
      exit 1
    fi
  else
    # Escalate to human via CODEOWNERS — avoid hard-coding a single reviewer.
    echo "Escalating to human review..."

    # AC3 (#1754): add the hold label only when it is absent, and CONFIRM it is
    # present before returning 101. Re-escalating an already-held PR must not
    # unlabel-then-relabel (four toggles in one day on an unchanged PR was the
    # reported symptom) — ensure_hold_label_present short-circuits on an
    # already-present label with no mutation. A failed add must not be reported
    # as an escalation: without the label, review-one-pr.sh re-engages the
    # cascade on the next sweep even though this branch returned 101.
    if ! ensure_hold_label_present "$PR_URL"; then
      echo "::error::escalation: could not confirm needs-human-review present on $PR_URL after $LABEL_MAX_ATTEMPTS attempts — failing so the escalation is retried rather than under-reported (#1754)"
      exit 1
    fi

    # AC2 (#1754): leave a visible artifact, not just a label. Upsert a single
    # marker-keyed comment stating the escalation, the cycle it happened at, and
    # why. Updated in place on re-escalation so it never becomes sweep noise.
    ESC_SUMMARY=$(jq -r '.summary // ""' "$VERDICT_JSON")
    # Stamp a fresh reset timestamp on every (re-)escalation. The comment is
    # PATCHed in place, so its createdAt is frozen at the FIRST escalation; a
    # later in-place re-escalation would otherwise keep the original reset time
    # and let fix requests from before the re-escalation count toward the next
    # cycle cap (#1754). compute_review_cycle prefers this embedded `reset=<ts>`
    # over the comment's createdAt, so re-escalation resets the budget. Regenerated
    # here (not derived from the API) because gh's issue-comment view exposes no
    # updatedAt field.
    ESC_RESET_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    ESC_BODY=$(cat <<ESC_END
$ESCALATION_COMMENT_MARKER
<!-- pr-review-agent human-escalation reset=$ESC_RESET_TS -->
## Automated review — escalated to human

The automated review cascade escalated this PR to a human reviewer at review cycle ${REVIEW_CYCLE:-0}/${MAX_REVIEW_CYCLES:-3} (risk: $RISK, reviewed commit \`$PR_HEAD_SHA\`).

Why: the cascade could neither approve the PR nor auto-request fixes, so it requested human review via CODEOWNERS and set the \`needs-human-review\` label. A human should review the PR, or remove the \`needs-human-review\` label to re-engage the automated cascade.${ESC_SUMMARY:+

**Reviewer summary:** $ESC_SUMMARY}

_This note is updated in place on re-escalation; it is not re-posted._
ESC_END
)
    ESC_ARTIFACT_OK=true
    upsert_escalation_comment "$PR_URL" "$ESC_BODY" || ESC_ARTIFACT_OK=false

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "$SCRIPT_DIR/request-codeowners-review.sh" "$PR_URL" || true

    # Only report an escalation when its visible artifact is confirmed. A bare
    # label with no comment leaves nothing for compute_review_cycle to reset on,
    # so downgrade to the no-op 100 rather than overstate the escalated count.
    if [ "$ESC_ARTIFACT_OK" != "true" ]; then
      echo "::error::escalation: no human-escalation comment could be confirmed on $PR_URL (label + CODEOWNERS request only) — exiting 100 (no-op) so the escalated count is not overstated (#1754)"
      exit 100
    fi

    # Escalation has its own exit status (issue #1754 AC1): distinct from 0
    # (review posted) and 100 (no-op). review-one-pr.sh propagates it and
    # review-batch.sh counts it as `escalated`, never as a posted review.
    echo "Escalated to human review"
    exit 101
  fi
fi

echo "Review action completed"

