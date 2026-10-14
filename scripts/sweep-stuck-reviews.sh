#!/usr/bin/env bash
# sweep-stuck-reviews.sh — re-trigger reviews for PRs that went green after a skip.
#
# The pr-review cascade legitimately SKIPS a PR whose CI is pending or failing
# (decision: skip, reason: ci-pending | ci-failing) and relies on a later
# `check_suite:completed` event to re-evaluate it. But when CI settles green
# AFTER the last review trigger fired — common while dev-lead is actively
# pushing fixes / re-running CI — no event re-fires, and the PR sits at
# REVIEW_REQUIRED with green CI, never re-reviewed (issue #573).
#
# This sweep closes that gap. It enumerates open PRs and re-dispatches a review
# for each one that is:
#   • reviewDecision == REVIEW_REQUIRED   (GitHub still wants a review), AND
#   • CI status == passing                (own pr-review checks filtered out via
#                                          lib/ci-status.sh, same as the cascade), AND
#   • NOT already reviewed at the current head
#                                         (no `<!-- pr-review-agent v1 sha=<head> -->`
#                                          marker), so genuine no-ops aren't re-fired.
# Each selected PR is re-dispatched through the normal trigger
# (pr-review-trigger.yml -f pr_url=<url>); review-one-pr.sh remains the
# authoritative gate, so the sweep only decides WHAT to re-trigger.
#
# IMPORTANT — the re-dispatch requires a PAT, not GITHUB_TOKEN:
#   GitHub does not start new workflow runs from a workflow_dispatch fired with
#   the default GITHUB_TOKEN (loop prevention). The caller MUST provide a PAT
#   with workflow scope as GH_TOKEN. Same constraint as
#   scripts/initiative-planner/redispatch.sh.
#
# Env:
#   AGENT_REPO        owner/repo hosting the trigger workflow (default: combsmith/.github-private)
#   TRIGGER_WORKFLOW  workflow file to dispatch (default: pr-review-trigger.yml)
#   SWEEP_PRS_FILE    optional file of candidate PR URLs (one per line); when
#                     unset, candidates are enumerated via list-prs.sh
#   MAX_DISPATCH      cap on review dispatches per sweep (default: 20)
#   DRY_RUN           "true"/"1" → log selections but never dispatch
#   GITHUB_REF        passed through as --ref when it is a branch/tag (feature testing)
#   GH_TOKEN          a PAT with workflow scope (required at the call site)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CI gate: compute_ci_status filters the cascade's own check runs before
# classifying, exactly as review-one-pr.sh does (issue #469).
# shellcheck source=lib/ci-status.sh
source "$SCRIPT_DIR/lib/ci-status.sh"
# Escalation gate (#946): pr_has_escalation_label / NEEDS_HUMAN_REVIEW_LABEL.
# shellcheck source=lib/pr-automation-budget.sh
source "$SCRIPT_DIR/lib/pr-automation-budget.sh"

AGENT_REPO="${AGENT_REPO:-combsmith/.github-private}"
TRIGGER_WORKFLOW="${TRIGGER_WORKFLOW:-pr-review-trigger.yml}"
MAX_DISPATCH="${MAX_DISPATCH:-20}"

# Validate MAX_DISPATCH is a positive integer; fall back to the default otherwise.
case "$MAX_DISPATCH" in
  ''|*[!0-9]*) MAX_DISPATCH=20 ;;
esac
[ "$MAX_DISPATCH" -gt 0 ] || MAX_DISPATCH=20

if [[ "${DRY_RUN:-}" == "1" || "${DRY_RUN:-}" == "true" ]]; then
  DRY_RUN_BOOL=true
else
  DRY_RUN_BOOL=false
fi

# Use GITHUB_REF as --ref only when it is a branch or tag (supports testing on
# feature branches); a pull-request merge ref is not dispatchable.
REF_FLAGS=()
if [[ -n "${GITHUB_REF:-}" && ( "$GITHUB_REF" =~ ^refs/heads/ || "$GITHUB_REF" =~ ^refs/tags/ ) ]]; then
  REF_FLAGS=(--ref "$GITHUB_REF")
fi

# ---------------------------------------------------------------------------
# 1. Gather candidate PR URLs
# ---------------------------------------------------------------------------
candidates_file="$(mktemp)"
trap 'rm -f "$candidates_file"' EXIT

# prs_from_workflow_run_event <event_json_path>
# Event-driven fast path: when the sweep is kicked by a `workflow_run: completed`
# event (a CI workflow just finished), scope the candidate set to the PR(s)
# attached to that run instead of enumerating the whole fleet. Emits one PR
# html_url per line from `.workflow_run.pull_requests[]`. Pure (reads a JSON file,
# no network), so it is unit-testable.
#
# GitHub populates `pull_requests` only for SAME-repo head branches; fork-PR runs
# and plain pushes to a branch carry an empty array and yield nothing — those are
# covered by the scheduled (cron) sweep, and this repo never self-reviews forks.
prs_from_workflow_run_event() {
  local event_path="${1:-}"
  [ -n "$event_path" ] && [ -r "$event_path" ] || return 0
  # Single jq pass: bind the repo, drop out (empty stream) when it is absent, and
  # format the PR urls in one go — one process, one read of the payload.
  jq -r '
    (.repository.full_name // "") as $repo
    | select($repo != "")
    | (.workflow_run.pull_requests // [])
    | map(select(.number != null) | .number)
    | unique
    | .[]
    | "https://github.com/\($repo)/pull/\(.)"
  ' "$event_path" 2>/dev/null || true
}

if [[ -n "${SWEEP_PRS_FILE:-}" && -r "${SWEEP_PRS_FILE}" ]]; then
  grep -v '^[[:space:]]*$' "$SWEEP_PRS_FILE" > "$candidates_file" || true
elif [[ "${GITHUB_EVENT_NAME:-}" == "workflow_run" && -n "${GITHUB_EVENT_PATH:-}" ]]; then
  # CI-completion kick (#898): inspect only the completing run's PR(s). The
  # REVIEW_REQUIRED + CI-green + not-reviewed-at-head gate below still decides, so
  # a too-early fire (some checks still pending) simply skips and the next
  # completing workflow re-fires. The scheduled sweep remains the guaranteed
  # backstop, so this fast path can never strand a PR if it matches nothing.
  prs_from_workflow_run_event "$GITHUB_EVENT_PATH" > "$candidates_file" || true
else
  bash "$SCRIPT_DIR/list-prs.sh" > "$candidates_file" || true
fi

candidate_count=$(grep -c . "$candidates_file" || true)
echo "=== PR Review Sweep — re-trigger stuck-green reviews ==="
echo "  Trigger:    $TRIGGER_WORKFLOW @ $AGENT_REPO"
echo "  Candidates: $candidate_count"
echo "  Dry run:    $DRY_RUN_BOOL"
echo ""

# ---------------------------------------------------------------------------
# 2. Select stuck-green PRs and re-dispatch
# ---------------------------------------------------------------------------
inspected=0
stuck=0
dispatched=0

# dispatch_review <pr_url> <label>
# Re-dispatch a review through the normal trigger (never force_review — the
# advisory gate must stay armed). Honours DRY_RUN and updates the counters.
dispatch_review() {
  local _url="$1" _label="$2"
  stuck=$((stuck + 1))
  echo "  $_label: $_url — needs re-review"
  if [ "$DRY_RUN_BOOL" = "true" ]; then
    echo "    dry-run: would dispatch $TRIGGER_WORKFLOW for $_url"
    return 0
  fi
  if gh workflow run "$TRIGGER_WORKFLOW" --repo "$AGENT_REPO" "${REF_FLAGS[@]}" \
       -f pr_url="$_url"; then
    dispatched=$((dispatched + 1))
    echo "    dispatched review for $_url"
  else
    echo "::warning::sweep: failed to dispatch review for $_url"
  fi
}

while IFS= read -r pr_url; do
  [ -z "$pr_url" ] && continue
  if [ "$dispatched" -ge "$MAX_DISPATCH" ]; then
    echo "::notice::sweep: reached MAX_DISPATCH=$MAX_DISPATCH — deferring remaining PRs to the next sweep"
    break
  fi
  inspected=$((inspected + 1))

  if ! snapshot=$(gh pr view "$pr_url" \
        --json headRefOid,statusCheckRollup,reviewDecision,reviews,comments,labels 2>/dev/null); then
    echo "  skip $pr_url — could not fetch PR (deleted, no access, or rate-limited)"
    continue
  fi

  # Skip PRs already escalated to a human (#946). When the per-PR automation
  # budget (#928) or the cycle cap escalates a PR, it adds needs-human-review and
  # the cascade pauses; re-reviewing it here would re-ignite the runaway the
  # breaker stops (the #860 "amplifier" failure mode). Gate on the label — the
  # human-controlled resume signal — so removing it re-enables the sweep.
  labels_json=$(jq -c '[.labels[]?.name]' <<< "$snapshot" 2>/dev/null || echo '[]')
  if pr_has_escalation_label "$labels_json"; then
    echo "  skip $pr_url — escalated to a human ($NEEDS_HUMAN_REVIEW_LABEL present); not re-reviewing (#946)"
    continue
  fi

  review_decision=$(jq -r '.reviewDecision // ""' <<< "$snapshot")
  if [ "$review_decision" != "REVIEW_REQUIRED" ]; then
    echo "  skip $pr_url — reviewDecision='$review_decision' (not REVIEW_REQUIRED)"
    continue
  fi

  head_sha=$(jq -r '.headRefOid // ""' <<< "$snapshot")
  if [ -z "$head_sha" ]; then
    echo "  skip $pr_url — head SHA is empty"
    continue
  fi
  # Already reviewed at this exact head? The cascade stamps each review with
  # `<!-- pr-review-agent v1 sha=<HEAD> -->`; a marker at the current head means
  # there is nothing to re-trigger. Match the sha followed by a space so one
  # sha is never treated as a prefix of another.
  reviewed_at_head=$(jq -r --arg sha "$head_sha" '
    [ ((.reviews // []) + (.comments // []))[]
      | (.body // "")
      | select(test("<!-- pr-review-agent v1 sha=" + $sha + " ")) ]
    | length' <<< "$snapshot" 2>/dev/null || echo 0)

  # Rate-limited withhold retry (issue #711). A pr-review run that withheld
  # approval because advisory bots were rate-limited stamps a distinct marker:
  #   <!-- pr-review-agent rate-limited v1 sha=<HEAD> status=rate-limited reset=<ISO> -->
  # Handle it BEFORE the CI gate so unrelated cancelled/failed sibling checks
  # cannot suppress the retry (AC3). Extract the reset for a marker at the
  # current head (sha followed by a space, never a prefix match).
  rl_reset=$(jq -r --arg sha "$head_sha" '
    [ ((.reviews // []) + (.comments // []))[]
      | (.body // "")
      | select(test("<!-- pr-review-agent rate-limited v1 sha=" + $sha + " ") and test("reset=[^ ]+"))
      | capture("reset=(?<r>[^ ]+)") | .r ]
    | last // ""' <<< "$snapshot" 2>/dev/null || echo "")
  if [ -n "$rl_reset" ]; then
    if [ "${reviewed_at_head:-0}" -gt 0 ]; then
      # A real review already landed at this head — rate-limit state is resolved.
      echo "  skip $pr_url — rate-limited marker present but already reviewed at head ${head_sha:0:8}"
      continue
    fi
    reset_epoch=$(date -u -d "$rl_reset" +%s 2>/dev/null \
      || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$rl_reset" +%s 2>/dev/null \
      || echo "")
    now_epoch=$(date -u +%s)
    # Dispatch once the reset has elapsed; an unparseable reset fails open to a
    # retry so a malformed marker can never strand the PR indefinitely.
    if [ -z "$reset_epoch" ] || [ "$now_epoch" -ge "$reset_epoch" ]; then
      dispatch_review "$pr_url" "rate-limited (reset $rl_reset elapsed, head ${head_sha:0:8})"
    else
      echo "  defer $pr_url — rate-limited until $rl_reset (head ${head_sha:0:8})"
    fi
    continue
  fi

  ci_status=$(compute_ci_status "$(jq '.statusCheckRollup' <<< "$snapshot")")
  if [ "$ci_status" != "passing" ]; then
    echo "  skip $pr_url — CI '$ci_status' (not green yet)"
    continue
  fi

  if [ "${reviewed_at_head:-0}" -gt 0 ]; then
    echo "  skip $pr_url — already reviewed at head ${head_sha:0:8}"
    continue
  fi

  dispatch_review "$pr_url" "stuck-green (head ${head_sha:0:8})"
done < "$candidates_file"

echo ""
echo "Sweep summary: inspected $inspected candidate(s), $stuck stuck-green, $dispatched review(s) dispatched."
