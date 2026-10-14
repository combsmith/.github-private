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
#   • NOT already resolved at the current head by a STANDING verdict — either a
#                                          standing approval (a non-dismissed
#                                          state==APPROVED review carrying the
#                                          approval marker, #1665) or a terminal
#                                          escalated/fix-requested verdict — so
#                                          genuine no-ops aren't re-fired. A bare
#                                          `decision=approved` MARKER in a dismissed
#                                          review or an issue comment does NOT count.
# A marker present at head but WITHOUT a verdict is an orphan (issue #1548): the
# review crashed after stamping the head and before posting any decision. That PR
# is re-dispatched WITH force_review to bypass review-one-pr.sh's idempotency
# no-op on the orphan marker — otherwise it strands silently forever. The
# force_review input is the NARROW idempotency bypass (FORCE_RE_REVIEW), not the
# human @mention break-glass (FORCE_REVIEW): it clears ONLY the same-SHA marker and
# leaves the CI/advisory/maintainer gates armed, so a rescue can never bypass a
# quality gate and a CI status that went red since this sweep's snapshot is
# re-validated when review-one-pr.sh runs (issue #1590).
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
#   AGENT_REPO        owner/repo hosting the trigger workflow (default: petry-projects/.github-private)
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
# Standing-approval primitive (#1665): pr_standing_approval_count — the
# authoritative "does an approving review STAND at head?" check. A `decision=
# approved` marker in a DISMISSED review or an issue comment is NOT a standing
# approval, so it must never satisfy the stop condition.
# shellcheck source=lib/standing-approval.sh
source "$SCRIPT_DIR/lib/standing-approval.sh"

AGENT_REPO="${AGENT_REPO:-petry-projects/.github-private}"
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

# Scheduled (cron) backstop mode (#1408). On the schedule event the sweep is the
# GUARANTEED backstop for genuinely UN-eventable cases only — GitHub-App /
# cross-repo checks (e.g. SonarCloud) that emit no workflow_run this repo can key
# on. A stuck-green PR whose green state is fully determined by EVENTABLE GitHub
# Actions checks is already owned by the workflow_run fast path, so the cron must
# not re-review it. The narrowing is scheduled-only: the workflow_run fast path,
# workflow_dispatch, and explicit SWEEP_PRS_FILE runs keep the original selection.
if [[ "${GITHUB_EVENT_NAME:-}" == "schedule" ]]; then
  SCHEDULED_SWEEP=true
else
  SCHEDULED_SWEEP=false
fi

# Deterministic delayed-retry arming (#1994). When the sweep DEFERS a rate-limited
# PR whose reset is still in the future but within DELAYED_RETRY_HORIZON_SEC, it
# arms pr-review-delayed-retry.yml to fire close to <reset> instead of relying on
# the best-effort schedule cron (which GitHub drops under load — observed 3-7 h
# instead of 15 min, #1952). A reset BEYOND the horizon is left to the cron
# backstop. ARM_DELAYED_RETRY=false disables arming — the mode the delayed retry
# itself uses when it delegates back to this sweep, so a retry can never re-arm.
ARM_DELAYED_RETRY="${ARM_DELAYED_RETRY:-true}"
DELAYED_RETRY_WORKFLOW="${DELAYED_RETRY_WORKFLOW:-pr-review-delayed-retry.yml}"
DELAYED_RETRY_HORIZON_SEC="${DELAYED_RETRY_HORIZON_SEC:-3600}"
case "$DELAYED_RETRY_HORIZON_SEC" in
  ''|*[!0-9]*) DELAYED_RETRY_HORIZON_SEC=3600 ;;
esac

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
  # completing workflow re-fires. The scheduled sweep remains the backstop, so
  # this fast path can never strand a PR if it matches nothing — but the cron is
  # best-effort (GitHub delays or drops scheduled runs under load, #1952); the
  # time-bound rate-limit case is covered by the armed delayed retry (#1994).
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
armed=0

# dispatch_review <pr_url> <label> [force]
# Re-dispatch a review through the normal trigger. Honours DRY_RUN and updates
# the counters. A 3rd arg of "force" appends `-f force_review=true`, used ONLY
# for the orphaned-marker rescue (#1548): an unforced re-dispatch would hit
# review-one-pr.sh's idempotency no-op on the orphan marker. The force_review
# input is the NARROW idempotency bypass (FORCE_RE_REVIEW in pr-review.yml, #1590),
# so the CI/advisory/maintainer gates stay armed for the rescue too — force here
# defeats only the same-SHA no-op, never a quality gate.
dispatch_review() {
  local _url="$1" _label="$2" _force="${3:-}"
  stuck=$((stuck + 1))
  echo "  $_label: $_url — needs re-review"
  if [ "$DRY_RUN_BOOL" = "true" ]; then
    echo "    dry-run: would dispatch $TRIGGER_WORKFLOW for $_url"
    return 0
  fi
  local force_flags=()
  if [ "$_force" = "force" ]; then
    force_flags=(-f force_review=true)
  fi
  if gh workflow run "$TRIGGER_WORKFLOW" --repo "$AGENT_REPO" "${REF_FLAGS[@]}" \
       -f pr_url="$_url" "${force_flags[@]}"; then
    dispatched=$((dispatched + 1))
    echo "    dispatched review for $_url"
  else
    echo "::warning::sweep: failed to dispatch review for $_url"
  fi
}

# arm_delayed_retry <pr_url> <head_sha> <reset_iso> <reset_epoch> <now_epoch>
# Deterministic near-reset retry (#1994). Called from the rate-limit DEFER branch:
# when a PR is withheld on an un-elapsed reset that is within
# DELAYED_RETRY_HORIZON_SEC, dispatch pr-review-delayed-retry.yml, which sleeps
# until <reset>, re-checks the marker still applies at the same head, then
# re-dispatches the review through THIS sweep (scoped to the one PR). This gives a
# retry bounded to minutes after reset without depending on the best-effort cron.
# Resets beyond the horizon are left to the cron backstop. Idempotency and
# cross-PR isolation live in the retry workflow's per-(PR, head) concurrency group;
# a newer push changes the head so the stale armed retry no-ops. Honours DRY_RUN
# and shares the single MAX_DISPATCH budget with normal dispatches (dispatched +
# armed), so one sweep never issues more than MAX_DISPATCH requests total. No-op
# when ARM_DELAYED_RETRY=false — the mode the
# retry uses when it delegates back here, so it can never re-arm itself.
arm_delayed_retry() {
  local _url="$1" _sha="$2" _reset="$3" _reset_epoch="$4" _now_epoch="$5"
  [ "$ARM_DELAYED_RETRY" = "true" ] || return 0
  [ -n "$_reset_epoch" ] || return 0
  local _delta=$(( _reset_epoch - _now_epoch ))
  { [ "$_delta" -gt 0 ] && [ "$_delta" -le "$DELAYED_RETRY_HORIZON_SEC" ]; } || return 0
  if [ "$(( dispatched + armed ))" -ge "$MAX_DISPATCH" ]; then
    echo "    arm skipped $_url — reached MAX_DISPATCH=$MAX_DISPATCH (dispatches + armed retries) this sweep"
    return 0
  fi
  if [ "$DRY_RUN_BOOL" = "true" ]; then
    echo "    dry-run: would arm delayed retry for $_url (not_before=$_reset, head ${_sha:0:8})"
    armed=$((armed + 1))
    return 0
  fi
  # Dedup across sweep invocations (#1994). The retry workflow's per-(PR, head)
  # concurrency group only COLLAPSES concurrent runs — it does not stop this
  # sweep from re-dispatching on every defer tick (the 15-min cron, and the
  # workflow_run fast path that fires on each CI completion org-wide), and each
  # re-dispatch's cancel-in-progress would kill and restart the already-sleeping
  # runner. So skip arming when a queued/in-progress retry already exists for
  # this exact (PR, head): the run-name carries "<pr_url> @ <head_sha>", which
  # gh exposes as displayTitle. Fail OPEN — a query error falls through to arm so
  # a transient gh failure can never strand the retry.
  if delayed_retry_in_flight "$_url" "$_sha"; then
    echo "    arm skipped $_url — a delayed retry is already in flight for head ${_sha:0:8}"
    return 0
  fi
  if gh workflow run "$DELAYED_RETRY_WORKFLOW" --repo "$AGENT_REPO" "${REF_FLAGS[@]}" \
       -f pr_url="$_url" -f head_sha="$_sha" -f not_before="$_reset"; then
    armed=$((armed + 1))
    echo "    armed delayed retry for $_url (not_before=$_reset, head ${_sha:0:8})"
  else
    # A failed attempt still spends a MAX_DISPATCH slot, so a transient dispatch
    # error cannot turn one sweep into a retry storm across every candidate.
    armed=$((armed + 1))
    echo "::warning::sweep: failed to arm delayed retry for $_url (attempt counted against MAX_DISPATCH)"
  fi
}

# delayed_retry_in_flight <pr_url> <head_sha>
# True when a queued or in-progress pr-review-delayed-retry run already exists for
# this exact (PR, head). Matches on the run-name the retry workflow sets
# ("pr-review-delayed-retry <pr_url> @ <head_sha>"), surfaced by gh as
# displayTitle. Fails OPEN (returns false) on any query error so a transient gh
# failure never suppresses a needed arm.
delayed_retry_in_flight() {
  local _url="$1" _sha="$2" _runs
  _runs=$(gh run list --repo "$AGENT_REPO" --workflow "$DELAYED_RETRY_WORKFLOW" \
            --event workflow_dispatch --limit 50 \
            --json status,displayTitle 2>/dev/null) || return 1
  [ -n "$_runs" ] || return 1
  jq -e --arg title "$_url @ $_sha" '
    any(.[]?; (.status == "queued" or .status == "in_progress")
             and ((.displayTitle // "") | endswith($title)))' \
    <<< "$_runs" >/dev/null 2>&1
}

while IFS= read -r pr_url; do
  [ -z "$pr_url" ] && continue
  if [ "$(( dispatched + armed ))" -ge "$MAX_DISPATCH" ]; then
    echo "::notice::sweep: reached MAX_DISPATCH=$MAX_DISPATCH (dispatches + armed retries) — deferring remaining PRs to the next sweep"
    break
  fi
  inspected=$((inspected + 1))

  if ! snapshot=$(gh pr view "$pr_url" \
        --json headRefOid,baseRefName,statusCheckRollup,reviewDecision,reviews,comments,labels 2>/dev/null); then
    echo "  skip $pr_url — could not fetch PR (deleted, no access, or rate-limited)"
    continue
  fi

  head_sha=$(jq -r '.headRefOid // ""' <<< "$snapshot")
  if [ -z "$head_sha" ]; then
    echo "  skip $pr_url — head SHA is empty"
    continue
  fi

  # Skip PRs held for a human (#946). When the per-PR automation budget (#928) or
  # the cycle cap escalates a PR, it adds needs-human-review and the cascade
  # pauses; re-reviewing it here would re-ignite the runaway the breaker stops
  # (the #860 "amplifier" failure mode). Gate on the label — the human-controlled
  # resume signal — so removing it re-enables the sweep.
  #
  # EXCEPTION — a rate-limit-ONLY hold (#1550). The rate-limited withhold marker
  # PROMISES "pr-review-sweep will re-review this PR after <reset>", but a
  # concurrent hold label (from a budget/cycle-cap escalation OR a manual
  # escalation) would pause the very sweep that makes the promise good, stranding
  # the PR until a human removes the label. So when the ONLY hold is the
  # rate-limit marker at the current head (no genuine-escalation marker present),
  # exempt it from the pause and fall through to the rate-limit retry below — the
  # reset gate there still governs WHEN it re-dispatches. A GENUINE escalation
  # (budget exhaustion / churn-breaker cap) keeps pausing everything, even with a
  # co-present rate-limit marker (#1550 AC#3): the exemption keys on the marker
  # set, it does not weaken the hold semantics. For EVERY held PR skipped, log
  # WHICH hold was honored so a stranded PR is diagnosable from one run (#1550 AC#5).
  labels_json=$(jq -c '[.labels[]?.name]' <<< "$snapshot" 2>/dev/null || echo '[]')
  if pr_has_escalation_label "$labels_json"; then
    hold_items=$(jq -c '((.reviews? // []) + (.comments? // [])) | map({body: (.body? // "" | tostring)})' \
      <<< "$snapshot" 2>/dev/null || echo '[]')
    hold_kind=$(pr_hold_kind "$hold_items" "$head_sha")
    if [ "$hold_kind" = "rate-limit-only" ]; then
      echo "  exempt $pr_url — held by $NEEDS_HUMAN_REVIEW_LABEL but hold is rate-limit-only (no escalation marker) — recovery not disabled, continuing to rate-limit retry (#1550)"
    else
      echo "  skip $pr_url — held ($hold_kind; $NEEDS_HUMAN_REVIEW_LABEL present); not re-reviewing (#946/#1550)"
      continue
    fi
  fi

  review_decision=$(jq -r '.reviewDecision // ""' <<< "$snapshot")
  if [ "$review_decision" != "REVIEW_REQUIRED" ]; then
    echo "  skip $pr_url — reviewDecision='$review_decision' (not REVIEW_REQUIRED)"
    continue
  fi
  # Marker vs. STANDING verdict at this exact head (#1548, #1665). The cascade
  # stamps each review with `<!-- pr-review-agent v1 sha=<HEAD> -->`, but a review
  # can CRASH (Claude 429 usage-limit, or a 429 between the escalation review and
  # its follow-through) after stamping that marker and before posting any VERDICT.
  # A genuine verdict additionally carries a `decision=` token in the same body
  # (see scripts/lib/review-cycle.sh):
  #   approval:    <!-- pr-review-agent v1 sha=<SHA> decision=approved  risk=... -->
  #   escalated:   <!-- pr-review-agent v1 sha=<SHA> decision=escalated risk=... -->
  #   fix-request: <!-- pr-review-agent v1 sha=<SHA> --> <!-- decision=fix-requested risk=... -->
  # Match the sha followed by a space so one sha is never a prefix of another.
  # marker_at_head           — any v1 marker at head (crashed or complete).
  # standing_verdict_at_head — a verdict that ACTUALLY STANDS at head, i.e. one of:
  #   • a STANDING APPROVAL — a non-dismissed state==APPROVED REVIEW carrying the
  #     approval marker (pr_standing_approval_count, #1665). A `decision=approved`
  #     MARKER in a DISMISSED review or an issue COMMENT is NOT a standing approval
  #     — GitHub still wants a review — so it must never satisfy the stop
  #     condition. This is the #1665 fix: the old code counted the marker string,
  #     stranding a green auto-merge-armed PR when its approval was dismissed or
  #     the marker was posted as a comment.
  #   • a terminal escalated / fix-requested verdict — a genuine dead-end that
  #     legitimately suppresses re-review (the PR needs a human / fixes, not a
  #     re-run). These stay MARKER-based: they are not "approvals" and the marker
  #     is their canonical record. Bound to the CANONICAL marker relationship the
  #     writers emit (not a `decision=…` string anywhere in the body) so quoted/
  #     unrelated prose can't masquerade as a verdict and suppress an orphan's
  #     rescue. Two canonical shapes:
  #       escalated     — the token sits INSIDE the head marker: `sha=<SHA> decision=escalated`
  #       fix-requested — the bare head marker plus its companion `<!-- decision=fix-requested … -->`
  # An orphan (marker present, no STANDING verdict) is the silent strand this fixes.
  marker_at_head=$(jq -r --arg sha "$head_sha" '
    [ ((.reviews // []) + (.comments // []))[]
      | (.body // "")
      | select(test("<!-- pr-review-agent v1 sha=" + $sha + " ")) ]
    | length' <<< "$snapshot" 2>/dev/null || echo 0)
  standing_approval_at_head=$(pr_standing_approval_count "$snapshot" "$head_sha")
  other_verdict_at_head=$(jq -r --arg sha "$head_sha" '
    def is_terminal_verdict($sha):
      (.body // "") as $b
      | ($b | test("<!-- pr-review-agent v1 sha=" + $sha + "\\s+decision=escalated\\b"))
        or (($b | test("<!-- pr-review-agent v1 sha=" + $sha + " -->"))
            and ($b | test("<!-- decision=fix-requested\\b")));
    [ ((.reviews // []) + (.comments // []))[] | select(is_terminal_verdict($sha)) ]
    | length' <<< "$snapshot" 2>/dev/null || echo 0)
  standing_verdict_at_head=$(( ${standing_approval_at_head:-0} + ${other_verdict_at_head:-0} ))

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
    if [ "${standing_verdict_at_head:-0}" -gt 0 ]; then
      # A verdict that STANDS at head resolves the rate-limit state — a standing
      # approval (non-dismissed APPROVED review) or a terminal escalated/fix-
      # requested verdict. A bare orphan marker, a DISMISSED approval, or an
      # approval marker posted as a comment (#1665) do NOT resolve it: the retry
      # still needs to fire.
      echo "  skip $pr_url — rate-limited marker present but standing verdict at head ${head_sha:0:8}"
      continue
    fi
    reset_epoch=$(date -u -d "$rl_reset" +%s 2>/dev/null \
      || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$rl_reset" +%s 2>/dev/null \
      || echo "")
    now_epoch=$(date -u +%s)
    # Dispatch once the reset has elapsed; an unparseable reset fails open to a
    # retry so a malformed marker can never strand the PR indefinitely.
    if [ -z "$reset_epoch" ] || [ "$now_epoch" -ge "$reset_epoch" ]; then
      if [ "$SCHEDULED_SWEEP" = "true" ]; then
        eventability=$(classify_rollup_eventability "$(jq '.statusCheckRollup' <<< "$snapshot")")
        if [ "$eventability" = "eventable-only" ]; then
          echo "  skip $pr_url — rate-limited marker elapsed but all checks eventable; scheduled sweep is un-eventable-only (#1408)"
          continue
        fi
      fi
      dispatch_review "$pr_url" "rate-limited (reset $rl_reset elapsed, head ${head_sha:0:8})"
    else
      echo "  defer $pr_url — rate-limited until $rl_reset (head ${head_sha:0:8})"
      arm_delayed_retry "$pr_url" "$head_sha" "$rl_reset" "$reset_epoch" "$now_epoch"
    fi
    continue
  fi

  # Gate on the branch ruleset's REQUIRED checks (#1795) — same authoritative set
  # review-one-pr.sh uses. Without it this sweep reverts to blocking on every red
  # external check, so a non-required `template-drift` failure would keep a green PR
  # stuck and never re-dispatched (the deadlock #1795 fixes, on the sweep path too).
  # Fail closed: an unreadable set leaves it empty and compute_ci_status gates on all
  # failing checks.
  base_ref=$(jq -r '.baseRefName // ""' <<< "$snapshot")
  owner_repo=""
  if [[ "$pr_url" =~ ^https?://[^/]+/([^/]+/[^/]+)/pull/[0-9]+ ]]; then
    owner_repo="${BASH_REMATCH[1]}"
  fi
  required_checks=$(ruleset_required_checks "$owner_repo" "$base_ref" || true)
  ci_status=$(compute_ci_status "$(jq '.statusCheckRollup' <<< "$snapshot")" "$required_checks")
  if [ "$ci_status" != "passing" ]; then
    echo "  skip $pr_url — CI '$ci_status' (not green yet)"
    continue
  fi

  if [ "${standing_verdict_at_head:-0}" -gt 0 ]; then
    echo "  skip $pr_url — already reviewed at head ${head_sha:0:8} (standing approval or terminal verdict)"
    continue
  fi

  # Orphaned marker (#1548): the head was stamped but the review crashed before
  # posting a verdict. Re-dispatch WITH force_review — an unforced re-dispatch
  # would hit review-one-pr.sh's idempotency no-op on this very marker. This runs
  # BEFORE the scheduled-narrowing gate below so a genuine strand is rescued even
  # in the cron's un-eventable-only mode; the strand is not the redundant re-review
  # the narrowing removes. force_review here is the NARROW idempotency bypass
  # (FORCE_RE_REVIEW, #1590): it clears ONLY the same-SHA marker no-op. The CI,
  # advisory, and maintainer gates stay armed (so a CI status that went red since
  # this sweep's snapshot re-blocks at execution time), as do the per-PR automation
  # budget (#926) and the needs-human-review escalation gate (handled above) — so
  # the rescue can neither bypass a quality gate nor re-ignite a runaway.
  if [ "${marker_at_head:-0}" -gt 0 ]; then
    dispatch_review "$pr_url" "orphaned-marker (head ${head_sha:0:8}, no verdict)" force
    continue
  fi

  # Scheduled-backstop narrowing (#1408): on the cron event, only re-review the
  # un-eventable residue. A PR whose external checks are all eventable GitHub
  # Actions runs is owned by the workflow_run fast path, so re-dispatching it here
  # would be the redundant re-review this story removes.
  if [ "$SCHEDULED_SWEEP" = "true" ]; then
    eventability=$(classify_rollup_eventability "$(jq '.statusCheckRollup? // []' <<< "$snapshot" 2>/dev/null || echo '[]')")
    if [ "$eventability" = "eventable-only" ]; then
      echo "  skip $pr_url — all checks eventable (workflow_run fast path owns it); scheduled sweep is un-eventable-only (#1408)"
      continue
    fi
  fi

  dispatch_review "$pr_url" "stuck-green (head ${head_sha:0:8})"
done < "$candidates_file"

echo ""
echo "Sweep summary: inspected $inspected candidate(s), $stuck stuck-green, $dispatched review(s) dispatched, $armed delayed retr$([ "$armed" -eq 1 ] && echo y || echo ies) armed."
