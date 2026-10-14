#!/usr/bin/env bash
# pr_review_canary.sh — post-merge canary for the ring-0 pr-review-trigger stub.
#
# Implements #1256 (epic #1052 Part D). pr-review-trigger.yml is a self-host
# (ring-0) caller stub: it pins the reusable at a canary channel tag
# (`pr-review.yml@pr-review/next`) and forwards `with:` inputs to it. GitHub
# validates a reusable's inputs only at startup, against the PINNED ref — so a
# `with:`-forwarding change that forwards an input the pinned channel does not
# yet declare (the #1034 channel-skew defect) is exercised by NOTHING in PR CI
# and only breaks post-merge, where the dispatched run ends in `startup_failure`.
#
# What it does: fires a DRY-RUN dispatch of pr-review-trigger.yml (dry_run=true
# — the reusable submits no reviews/comments), waits for the resulting
# workflow_dispatch run, and fails LOUD if it concludes `startup_failure` (or any
# non-success), turning silent post-merge breakage into a gating signal. This is
# the manual dry-run that verified #1048's recovery, made continuous.
#
# Layout mirrors scripts/initiative_canary.sh:
#   * classify_canary_run / canary_is_failure / canary_report are PURE — they
#     take scalars and write stdout. Unit-tested in tests/pr_review_canary.bats.
#   * main() does the network I/O: dispatch, poll.
#
# Env vars consumed:
#   REPO                 owner/repo hosting the trigger (default petry-projects/.github-private)
#   WORKFLOW_FILE        trigger workflow to dispatch (default pr-review-trigger.yml)
#   GH_TOKEN             a PAT with workflow scope (a workflow_dispatch fired with
#                        GITHUB_TOKEN is accepted but never starts a run)
#   CANARY_POLL_TIMEOUT  seconds to wait for the run to complete (default 600)
#   CANARY_POLL_INTERVAL seconds between polls (default 15)
#   CANARY_OUT           optional path; the report is written there in addition to stdout
#   GITHUB_ENV           written by the Actions runner (CANARY_STATUS / CANARY_FAILED)

set -euo pipefail

REPO="${REPO:-petry-projects/.github-private}"
WORKFLOW_FILE="${WORKFLOW_FILE:-pr-review-trigger.yml}"

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested; no network)
# ---------------------------------------------------------------------------

# classify_canary_run <conclusion>
# Maps a completed run's conclusion to a canary status:
#   STARTUP_FAILURE — conclusion == startup_failure (the #1034 channel-skew
#                     fingerprint: the reusable call failed at startup because
#                     the caller forwarded an input the pinned channel lacks)
#   OK              — conclusion == success
#   NO_RUN          — empty/null conclusion (no completed run was found)
#   FAILED          — any other conclusion (failure/timed_out/cancelled/…)
classify_canary_run() {
  local conclusion="${1:-}"
  case "$conclusion" in
    startup_failure) echo "STARTUP_FAILURE" ;;
    success)         echo "OK" ;;
    ""|null)         echo "NO_RUN" ;;
    *)               echo "FAILED" ;;
  esac
}

# canary_is_failure <status>
# The canary exists to catch the #1034 channel-skew defect, whose ONLY
# fingerprint is a `startup_failure` conclusion. So it fails loud (exit 0)
# solely on STARTUP_FAILURE. Once the dispatched run gets past startup, channel
# skew is ruled out — a downstream FAILED (the dry-run review cascade failed
# against a real fleet PR for an unrelated reason) or NO_RUN (no completed run
# observed) is NOT this canary's signal and must not turn it red, or unrelated
# flakes raise false Fleet Monitor trackers (#1612). Exit 1 (no alert) otherwise.
canary_is_failure() {
  [ "${1:-}" = "STARTUP_FAILURE" ]
}

# canary_report <status> <repo> <run_url> [today]
# Writes a Markdown alert/health body to stdout. Pure: no network.
canary_report() {
  local st="${1:-}" repo="${2:-}" run_url="${3:-}" today="${4:-}"
  [ -n "$today" ] || today="$(date -u +%Y-%m-%d)"

  local icon headline
  case "$st" in
    OK)              icon='✅'; headline='canary passed' ;;
    STARTUP_FAILURE) icon='🔴'; headline='STARTUP FAILURE — the reusable call failed at startup (channel skew)' ;;
    NO_RUN)          icon='🟠'; headline='no pr-review-trigger run observed within the poll window' ;;
    FAILED)          icon='🟡'; headline='run concluded FAILED — not the startup_failure channel-skew fingerprint' ;;
    *)               icon='🟡'; headline='run concluded non-success — not the startup_failure channel-skew fingerprint' ;;
  esac

  printf '# %s PR-review-trigger canary — %s\n\n' "$icon" "$today"
  printf '_Repo `%s` · ring-0 self-host stub `pr-review-trigger.yml` → `pr-review.yml@pr-review/next`_\n\n' "$repo"
  printf -- '- **Result:** %s — %s\n' "$st" "$headline"
  printf -- '- **Mode:** dry-run dispatch (`dry_run=true`) — submits no reviews/comments\n'
  [ -n "$run_url" ] && printf -- '- **Run:** %s\n' "$run_url"
  printf '\n'

  if [ "$st" = "STARTUP_FAILURE" ]; then
    printf '> The dispatched run ended in `startup_failure`. This is the #1034 channel-skew defect: '
    printf 'the `pr-review-trigger.yml` caller stub forwards a `with:` input that its pinned channel '
    printf '(`pr-review/next`) does not declare, so GitHub rejects the reusable call at startup. '
    printf 'Nothing in PR CI exercises this — sequence the input per AGENTS.md '
    printf '("Caller-stub input forwarding across channel pins"): land it in the reusable, promote the '
    printf 'channel, then teach the stub to forward it.\n'
  elif [ "$st" = "NO_RUN" ]; then
    printf '> No `workflow_dispatch` pr-review-trigger run completed within the poll window. '
    printf 'The dispatch may have been rejected (PAT missing/expired) or the run is still queued. '
    printf 'This is not the channel-skew signal (no `startup_failure` observed), so it does not fail the canary.\n'
  elif [ "$st" != "OK" ]; then
    printf '> The dry-run pr-review-trigger dispatch concluded non-success, but NOT with `startup_failure` — '
    printf 'the sole fingerprint of the #1034 channel-skew defect. Because a `cancelled` or `timed_out` run '
    printf 'can end BEFORE the reusable call reaches startup, this result does not by itself confirm the '
    printf 'reusable call was accepted (channel skew is neither confirmed nor definitively ruled out). It is '
    printf 'simply not the signal this canary gates on, so it does not turn red; inspect the run log if the '
    printf 'downstream failure itself is unexpected.\n'
  fi
}

# ---------------------------------------------------------------------------
# Network I/O (main)
# ---------------------------------------------------------------------------

main() {
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "::error::GH_TOKEN is required — a workflow_dispatch fired with GITHUB_TOKEN will not start a run." >&2
    exit 1
  fi

  local timeout="${CANARY_POLL_TIMEOUT:-600}"
  local interval="${CANARY_POLL_INTERVAL:-15}"
  local today dispatch_ts dispatch_epoch
  today="$(date -u +%Y-%m-%d)"
  # Subtract a 60-second buffer to account for potential clock drift between the runner and GitHub's servers.
  dispatch_epoch=$(( $(date +%s) - 60 ))
  dispatch_ts="$(date -u -d "@${dispatch_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "${dispatch_epoch}" +%Y-%m-%dT%H:%M:%SZ)"

  echo "=== PR-review-trigger canary ===" >&2
  echo "  Repo:       $REPO" >&2
  echo "  Workflow:   $WORKFLOW_FILE (dry-run)" >&2

  # Fire the DRY-RUN dispatch. dry_run=true makes the reusable submit nothing.
  local ref_flags=()
  if [[ -n "${GITHUB_REF:-}" && ( "$GITHUB_REF" == refs/heads/* || "$GITHUB_REF" == refs/tags/* ) ]]; then
    ref_flags=(--ref "$GITHUB_REF")
  fi
  gh workflow run "$WORKFLOW_FILE" --repo "$REPO" "${ref_flags[@]}" \
    -f dry_run=true

  # Poll for the workflow_dispatch run created after our dispatch timestamp.
  local deadline run_id="" conclusion="" run_status=""
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local row
    row="$(gh run list --repo "$REPO" --workflow "$WORKFLOW_FILE" \
      --event workflow_dispatch --created ">=${dispatch_ts}" --limit 20 \
      --json databaseId,status,conclusion,createdAt \
      --jq 'sort_by(.createdAt) | reverse | .[0] // {} |
            [(.databaseId // "" | tostring), (.status // ""), (.conclusion // "")] | @tsv' \
      2>/dev/null || true)"
    IFS=$'\t' read -r run_id run_status conclusion <<< "$row"
    [ "$run_status" = "completed" ] && break
    sleep "$interval"
  done

  local result
  result="$(classify_canary_run "$conclusion")"

  local run_url=""
  [ -n "$run_id" ] && run_url="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${run_id}"

  local report
  report="$(canary_report "$result" "$REPO" "$run_url" "$today")"
  printf '%s\n' "$report"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$report" >> "$GITHUB_STEP_SUMMARY"
  fi
  if [ -n "${CANARY_OUT:-}" ]; then
    printf '%s\n' "$report" > "$CANARY_OUT"
  fi

  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "CANARY_STATUS=${result}" >> "$GITHUB_ENV"
  fi

  if canary_is_failure "$result"; then
    [ -n "${GITHUB_ENV:-}" ] && echo "CANARY_FAILED=true" >> "$GITHUB_ENV"
    echo "::error::PR-review-trigger canary result: ${result}" >&2
    exit 1
  fi
  # Keep the green exit for OK/FAILED/NO_RUN (only startup_failure gates this
  # canary, per #1612), but do not announce non-OK results as a successful
  # dispatch — that would report a downstream failure or missing run as healthy.
  if [ "$result" = "OK" ]; then
    echo "::notice::PR-review-trigger canary passed (dry-run dispatch concluded success)." >&2
  fi
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
