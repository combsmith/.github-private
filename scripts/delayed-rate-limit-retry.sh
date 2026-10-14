#!/usr/bin/env bash
# delayed-rate-limit-retry.sh — deterministic near-reset retry for a PR whose
# review was withheld because an advisory reviewer was rate-limited (issue #1994).
#
# WHY this exists. When pr-review defers a PR it stamps
#   <!-- pr-review-agent rate-limited v1 sha=<HEAD> status=rate-limited reset=<ISO> -->
# and the ONLY thing that re-dispatches the review after <reset> is the scheduled
# pr-review-sweep.yml cron — which GitHub drops under load (observed 3-7 h instead
# of every 15 min, #1952). This script is ARMED by the sweep's defer branch (via a
# pr-review-delayed-retry.yml workflow_dispatch) when <reset> is near. It sleeps
# until <reset> (+ a small buffer), confirms the marker still applies at the SAME
# head, then DELEGATES to the sweep scoped to this one PR — i.e. re-dispatches the
# review through exactly the path the sweep uses, never force-reviewing.
#
# Idempotency and cross-PR isolation are the retry workflow's concern (a per-(PR,
# head) concurrency group). This script adds the two guards that must hold at
# wake time:
#   • supersession — if the current head SHA no longer equals the armed HEAD_SHA,
#     a newer push has taken over (its push event drives a fresh review), so the
#     stale retry is a clean no-op.
#   • delegation with ARM_DELAYED_RETRY=false — the sweep re-validates the marker,
#     standing verdict, CI and exclusions and decides whether to re-dispatch, and
#     cannot re-arm another retry (no loop).
#
# The sweep remains the ultimate backstop: if this retry no-ops or is cancelled,
# the next cron sweep still catches the PR. This path only makes the common
# near-reset case fast.
#
# Env / inputs:
#   PR_URL                     (required) the deferred PR's html_url
#   HEAD_SHA                   (required) the head the rate-limit marker was armed on
#   NOT_BEFORE                 ISO-8601 reset time to wait for (the marker's reset=)
#   DELAYED_RETRY_BUFFER_SEC   seconds added after NOT_BEFORE before retrying (default 120)
#   DELAYED_RETRY_HORIZON_SEC  the sweep's arming horizon (default 3600; same variable
#                              and default as sweep-stuck-reviews.sh)
#   DELAYED_RETRY_MAX_SLEEP_SEC safety ceiling on the sleep (default and floor:
#                              HORIZON + BUFFER, so an armed retry always wakes
#                              after reset+buffer)
#   AGENT_REPO                 owner/repo hosting the trigger workflow (passed to the sweep)
#   SWEEP_SCRIPT               path to sweep-stuck-reviews.sh (default: sibling script)
#   DRY_RUN                    "true"/"1" → delegate in dry-run (log, never dispatch)
#   GH_TOKEN                   a PAT with workflow scope (required for the real dispatch)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PR_URL="${PR_URL:-}"
HEAD_SHA="${HEAD_SHA:-}"
NOT_BEFORE="${NOT_BEFORE:-}"
AGENT_REPO="${AGENT_REPO:-petry-projects/.github-private}"
SWEEP_SCRIPT="${SWEEP_SCRIPT:-$SCRIPT_DIR/sweep-stuck-reviews.sh}"
DELAYED_RETRY_BUFFER_SEC="${DELAYED_RETRY_BUFFER_SEC:-120}"
DELAYED_RETRY_HORIZON_SEC="${DELAYED_RETRY_HORIZON_SEC:-3600}"
DELAYED_RETRY_MAX_SLEEP_SEC="${DELAYED_RETRY_MAX_SLEEP_SEC:-}"

case "$DELAYED_RETRY_BUFFER_SEC" in ''|*[!0-9]*) DELAYED_RETRY_BUFFER_SEC=120 ;; esac
case "$DELAYED_RETRY_HORIZON_SEC" in ''|*[!0-9]*) DELAYED_RETRY_HORIZON_SEC=3600 ;; esac
# The sleep ceiling is derived from the arming side's horizon + this buffer, the
# one place both meet. A ceiling below that would wake before reset+buffer: the
# delegated sweep would re-defer and, with ARM_DELAYED_RETRY=false, could not
# re-arm, leaving the PR to the best-effort cron (#1994). An explicit lower
# value is raised to the floor, with a warning.
# Force base 10: the digit-only checks above admit a leading zero, which bash
# arithmetic would otherwise read as octal (0600 -> 384).
DELAYED_RETRY_HORIZON_SEC=$(( 10#$DELAYED_RETRY_HORIZON_SEC ))
DELAYED_RETRY_BUFFER_SEC=$(( 10#$DELAYED_RETRY_BUFFER_SEC ))
_min_sleep=$(( DELAYED_RETRY_HORIZON_SEC + DELAYED_RETRY_BUFFER_SEC ))
case "$DELAYED_RETRY_MAX_SLEEP_SEC" in
  '') DELAYED_RETRY_MAX_SLEEP_SEC="$_min_sleep" ;;
  *[!0-9]*)
    echo "::warning::delayed-rate-limit-retry: DELAYED_RETRY_MAX_SLEEP_SEC='$DELAYED_RETRY_MAX_SLEEP_SEC' is not a number — using horizon+buffer (${_min_sleep}s)"
    DELAYED_RETRY_MAX_SLEEP_SEC="$_min_sleep" ;;
  *)
    DELAYED_RETRY_MAX_SLEEP_SEC=$(( 10#$DELAYED_RETRY_MAX_SLEEP_SEC ))
    if [ "$DELAYED_RETRY_MAX_SLEEP_SEC" -lt "$_min_sleep" ]; then
      echo "::warning::delayed-rate-limit-retry: DELAYED_RETRY_MAX_SLEEP_SEC=${DELAYED_RETRY_MAX_SLEEP_SEC}s is below horizon+buffer (${_min_sleep}s) — raising it so the retry wakes after reset"
      DELAYED_RETRY_MAX_SLEEP_SEC="$_min_sleep"
    fi ;;
esac

if [ -z "$PR_URL" ] || [ -z "$HEAD_SHA" ]; then
  echo "::error::delayed-rate-limit-retry: PR_URL and HEAD_SHA are required"
  exit 2
fi

echo "=== Delayed rate-limit retry ==="
echo "  PR:         $PR_URL"
echo "  Armed head: ${HEAD_SHA:0:8}"
echo "  Not before: ${NOT_BEFORE:-<none>}"

# still_applicable <phase>
# The armed retry must still apply: the PR open, un-merged, at the SAME head the
# marker was armed on, and that head's rate-limit marker still present. Returns
# non-zero (caller no-ops) when it does not. Without the marker check, a retry
# whose marker was removed would fall through the delegated sweep's ordinary
# REVIEW_REQUIRED + green-CI path and launch a plain review instead of no-oping.
# Run BOTH before sleeping and after waking: the pre-sleep call aborts a runner
# whose PR was already pushed/merged in the arming→start gap so it never sleeps
# the full hour just to no-op, and the post-sleep call catches a push/merge that
# landed during the sleep (#1994).
still_applicable() {
  local _phase="$1" _snapshot _current_head _state _has_marker
  if ! _snapshot=$(gh pr view "$PR_URL" --json headRefOid,state,comments,reviews 2>/dev/null); then
    echo "  no-op ($_phase): could not fetch $PR_URL (deleted, no access, or rate-limited) — leaving to the cron sweep"
    return 1
  fi
  _current_head=$(jq -r '.headRefOid? // ""' <<< "$_snapshot" || echo "")
  _state=$(jq -r '.state? // ""' <<< "$_snapshot" || echo "")
  if [ -z "$_current_head" ]; then
    echo "  no-op ($_phase): current head SHA empty for $PR_URL — leaving to the cron sweep"
    return 1
  fi
  if [ "$_state" = "MERGED" ] || [ "$_state" = "CLOSED" ]; then
    echo "  no-op ($_phase): PR is $_state — nothing to retry"
    return 1
  fi
  if [ "$_current_head" != "$HEAD_SHA" ]; then
    echo "  no-op ($_phase): head advanced ${HEAD_SHA:0:8} -> ${_current_head:0:8} — superseded by a newer push; its event drives a fresh review"
    return 1
  fi
  _has_marker=$(jq -r --arg m "<!-- pr-review-agent rate-limited v1 sha=${HEAD_SHA} " \
    '[((.reviews // []) + (.comments // []))[]? | (.body // "" | tostring) | select(contains($m))] | length > 0' <<< "$_snapshot" 2>/dev/null || echo "false")
  if [ "$_has_marker" != "true" ]; then
    echo "  no-op ($_phase): no rate-limit marker for head ${HEAD_SHA:0:8} — nothing armed to retry"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 0. Pre-sleep guard — abort early if the PR was already superseded/merged
#    before this runner even started, instead of sleeping the full hour.
# ---------------------------------------------------------------------------
still_applicable "pre-sleep" || exit 0

# ---------------------------------------------------------------------------
# 1. Sleep until NOT_BEFORE + buffer (bounded by the safety ceiling).
# ---------------------------------------------------------------------------
now_epoch=$(date -u +%s)
nb_epoch=$(date -u -d "$NOT_BEFORE" +%s 2>/dev/null \
  || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$NOT_BEFORE" +%s 2>/dev/null \
  || echo "")

if [ -n "$nb_epoch" ]; then
  target=$(( nb_epoch + DELAYED_RETRY_BUFFER_SEC ))
  sleep_secs=$(( target - now_epoch ))
  if [ "$sleep_secs" -gt "$DELAYED_RETRY_MAX_SLEEP_SEC" ]; then
    # A malformed/far reset must never sleep unbounded; cap and let the re-check
    # (and the cron backstop) govern correctness.
    echo "  sleep:      capping $sleep_secs s at ${DELAYED_RETRY_MAX_SLEEP_SEC}s ceiling"
    sleep_secs="$DELAYED_RETRY_MAX_SLEEP_SEC"
  fi
  if [ "$sleep_secs" -gt 0 ]; then
    echo "  sleep:      ${sleep_secs}s until reset+buffer"
    sleep "$sleep_secs"
  else
    echo "  sleep:      reset already elapsed — proceeding immediately"
  fi
else
  # An unparseable NOT_BEFORE fails open: proceed now and let the marker re-check
  # and the sweep's own reset gate decide, rather than stranding the PR.
  echo "  sleep:      NOT_BEFORE unparseable — proceeding immediately"
fi

# ---------------------------------------------------------------------------
# 2. Supersession guard — the armed head must still be the current head after
#    the sleep (a push/merge may have landed mid-sleep).
# ---------------------------------------------------------------------------
still_applicable "post-sleep" || exit 0

# ---------------------------------------------------------------------------
# 3. Delegate to the sweep scoped to this one PR. The sweep re-validates the
#    rate-limit marker, standing verdict, CI and exclusions and re-dispatches
#    through the normal trigger (never force). ARM_DELAYED_RETRY=false so it
#    cannot re-arm another retry, and the event name is unset so the #1408
#    scheduled-narrowing does not apply to this targeted retry.
# ---------------------------------------------------------------------------
one_pr_file="$(mktemp)" || { echo "::error::Failed to create temporary file"; exit 1; }
trap 'rm -f "$one_pr_file"' EXIT
printf '%s\n' "$PR_URL" > "$one_pr_file"

echo "  retry: delegating to the sweep for $PR_URL (head ${HEAD_SHA:0:8})"
SWEEP_PRS_FILE="$one_pr_file" \
ARM_DELAYED_RETRY=false \
AGENT_REPO="$AGENT_REPO" \
DRY_RUN="${DRY_RUN:-false}" \
GITHUB_EVENT_NAME="" \
  bash "$SWEEP_SCRIPT"
