#!/usr/bin/env bash
# invalidate-standing-approval.sh — dismiss a pr-review approval that a trusted
# advisory bot has since proven premature (issue #1596, AC6).
#
# When pr-review APPROVES a PR and a trusted third-party advisory bot then opens a
# finding that is ACCEPTED (a fix lands / it is explicitly accepted) at the SAME
# head, the standing approval is no longer evidence of defect-freedom — it is a
# known false negative. This wrapper detects that situation with the deterministic,
# no-LLM detector pr_review_invalidatable_approvals (scripts/lib/pr-review-miss-rate.sh,
# unit-tested) and DISMISSES the stale approving review so branch protection re-opens
# the PR for a fresh review.
#
# SAFETY: DRY_RUN defaults to true. The script only reports what it WOULD dismiss
# unless DRY_RUN=false is set explicitly — dismissing an approval is a shared-state,
# hard-to-reverse action, so it is opt-in.
#
# Usage:
#   scripts/invalidate-standing-approval.sh <pr_url>
#   DRY_RUN=false scripts/invalidate-standing-approval.sh <pr_url>   # actually dismiss
#
# Env:
#   DRY_RUN            — "true" (default) reports only; "false" performs dismissals.
#   PR_REVIEW_APPROVER — approving bot login (default: donpetry-bot).
#   GH_TOKEN           — PAT with repo write (needed only when DRY_RUN=false).
#   PR_NODE_JSON       — (testing) inject the PR GraphQL node instead of fetching.
#   REST_REVIEWS_JSON  — (testing) inject the REST reviews array instead of fetching.

set -euo pipefail

DRY_RUN="${DRY_RUN:-true}"

_isa_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Detector + defaults. The gate (sourced by the metric lib's caller) supplies the
# trusted-bot registry; fall back to the metric lib's built-in default set.
# shellcheck source=scripts/lib/advisory-review-gate.sh
[[ -f "$_isa_here/lib/advisory-review-gate.sh" ]] && source "$_isa_here/lib/advisory-review-gate.sh"
# shellcheck source=scripts/lib/pr-review-miss-rate.sh
source "$_isa_here/lib/pr-review-miss-rate.sh"
# shellcheck source=scripts/lib/merge-queue-dequeue.sh
source "$_isa_here/lib/merge-queue-dequeue.sh"

# isa_bots_json — the trusted advisory-bot set as a JSON array (registry or default).
isa_bots_json() {
  if declare -p RATE_LIMIT_NOTICE_BOTS >/dev/null 2>&1 && [[ "${#RATE_LIMIT_NOTICE_BOTS[@]}" -gt 0 ]]; then
    jq -n '$ARGS.positional' --args "${RATE_LIMIT_NOTICE_BOTS[@]}"
  else
    printf '%s' "$PR_REVIEW_DEFAULT_BOTS"
  fi
}

# isa_fetch_pr_node <owner> <name> <number> — GraphQL PR node in the shape the
# detector expects (reviews + reviewThreads + comments). Honors PR_NODE_JSON.
isa_fetch_pr_node() {
  local owner="$1" name="$2" number="$3"
  if [[ -n "${PR_NODE_JSON:-}" ]]; then printf '%s' "$PR_NODE_JSON"; return 0; fi
  gh api graphql -F owner="$owner" -F name="$name" -F number="$number" -f query='
    query($owner:String!, $name:String!, $number:Int!) {
      repository(owner:$owner, name:$name) {
        pullRequest(number:$number) {
          url
          reviews(first: 100) { nodes { author { login } state submittedAt bodyText } }
          reviewThreads(first: 100) {
            nodes { isResolved comments(first: 50) { nodes { author { login } createdAt bodyText } } }
          }
          comments(first: 100) { nodes { author { login } createdAt bodyText } }
        }
      }
    }' --jq '.data.repository.pullRequest'
}

# isa_rest_reviews <owner> <name> <number> — the PR's REST reviews array (needs
# numeric ids + commit_id for dismissal). Honors REST_REVIEWS_JSON.
isa_rest_reviews() {
  local owner="$1" name="$2" number="$3"
  if [[ -n "${REST_REVIEWS_JSON:-}" ]]; then printf '%s' "$REST_REVIEWS_JSON"; return 0; fi
  gh api --paginate "repos/${owner}/${name}/pulls/${number}/reviews" 2>/dev/null | jq -sc 'add // .'
}

# invalidate_standing_approval <pr_url> — detect and dismiss (or, in DRY_RUN, report)
# the stale approving review(s). Returns 0 whether or not anything was invalidated.
invalidate_standing_approval() {
  local pr_url="${1:-}"
  [[ -n "$pr_url" ]] || { echo "usage: invalidate_standing_approval <pr_url>" >&2; return 2; }

  # Match-or-fail: a `sed s///` that does not match returns the input UNCHANGED, so
  # a malformed URL would yield three nonempty copies of the whole string that pass
  # the emptiness check and produce garbage API paths. A single anchored regex match
  # errors out cleanly instead.
  local owner name number
  if [[ "$pr_url" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    owner="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    number="${BASH_REMATCH[3]}"
  else
    echo "ERROR: could not parse owner/name/number from '$pr_url'" >&2
    return 2
  fi

  local bots node shas
  bots="$(isa_bots_json)"
  node="$(isa_fetch_pr_node "$owner" "$name" "$number")" || { echo "ERROR: failed to fetch PR node" >&2; return 1; }
  shas="$(pr_review_invalidatable_approvals "$node" "$bots" "${PR_REVIEW_APPROVER:-donpetry-bot}")"

  if [[ -z "$shas" ]]; then
    echo "[invalidate] ${pr_url}: standing approval stands — no accepted post-approval advisory finding."
    return 0
  fi

  local reviews
  reviews="$(isa_rest_reviews "$owner" "$name" "$number")"

  local sha ids id dismissed=0
  while IFS= read -r sha; do
    [[ -n "$sha" ]] || continue
    # Approving reviews stamped with this exact head SHA in their pr-review marker.
    # Authenticate: only dismiss reviews by the pr-review bot itself.
    ids="$(jq -r --arg sha "$sha" --arg approver_login "$PR_REVIEW_APPROVER" '
      (. // []) | .[]
      | select((.state // "") == "APPROVED")
      | select((.user.login // "" | ascii_downcase) == ($approver_login | ascii_downcase))
      | select((.body // "") | contains("<!-- pr-review-agent v1 sha=" + $sha))
      | .id' <<<"$reviews" 2>/dev/null || true)"
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      if [[ "$DRY_RUN" = "false" ]]; then
        # Count the attempt, not the success: a call can fail after GitHub applied it.
        dismissed=$((dismissed + 1))
        echo "[invalidate] ${pr_url}: DISMISSING approval review ${id} (head ${sha:0:8}) — accepted advisory finding after approval (#1596)."
        if gh api -X PUT "repos/${owner}/${name}/pulls/${number}/reviews/${id}/dismissals" \
          -f message="Auto-dismissed: a trusted advisory reviewer found an accepted defect after this approval at ${sha:0:8} (pr-review miss, #1596). Re-review required." \
          >/dev/null 2>&1; then
          echo "[invalidate]   dismissed ${id}."
        else
          echo "::warning::[invalidate] failed to dismiss review ${id} on ${pr_url}"
        fi
      else
        echo "[invalidate] ${pr_url}: WOULD dismiss approval review ${id} (head ${sha:0:8}) — set DRY_RUN=false to apply (#1596)."
      fi
    done <<<"$ids"
  done <<<"$shas"

  # GitHub checks reviews only when a PR joins the merge queue. If a dismissal
  # above withdrew the last approval of a queued PR, remove it from the queue
  # (#2174). Never fails the run.
  if [ "$dismissed" -gt 0 ]; then
    mq_dequeue_if_unapproved "$pr_url" || true
  fi
}

# Run when executed directly (not when sourced by tests).
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  invalidate_standing_approval "${1:-}"
fi
