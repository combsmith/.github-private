#!/usr/bin/env bash
# initiative_canary.sh — post-merge canary for the idea:approved → planner path.
#
# Closes #655 prevention item 3 ("smoke-monitor the live trigger"): the
# discussion[labeled] → redispatch → central-planner path has no post-merge
# canary today, so a silent revert like #655 (the redispatch bridge disappears
# and the planner is invoked directly on a `discussion` event again) is only
# noticed when a human realizes nothing was ever planned.
#
# What it does: fires a DRY-RUN dispatch of initiative-planner.yml against a
# fixture Ideas Discussion, waits for the resulting workflow_dispatch run, and
# alerts if it fails OR if its logs contain the regression fingerprint
# "Unsupported event type: discussion". A dry-run plan creates nothing
# (apply-plan only logs intended mutations to an artifact), per #822 Dev Notes.
#
# Layout mirrors scripts/auto_rebase_health.sh:
#   * classify_canary_run / canary_is_failure / canary_report are PURE — they
#     take scalars and write stdout. Unit-tested in tests/test_initiative_canary.bats.
#   * main() does the network I/O: dispatch, poll, log fetch.
#
# Env vars consumed:
#   REPO                 owner/repo hosting the planner (default petry-projects/.github-private)
#   CANARY_DISCUSSION    Ideas Discussion number to dry-run plan (required; positive int)
#   WORKFLOW_FILE        planner workflow to dispatch (default initiative-planner.yml)
#   GH_TOKEN             a PAT with workflow scope (a workflow_dispatch fired with
#                        GITHUB_TOKEN is accepted but never starts a run)
#   CANARY_POLL_TIMEOUT  seconds to wait for the run to complete (default 600)
#   CANARY_POLL_INTERVAL seconds between polls (default 15)
#   CANARY_OUT           optional path; the report is written there in addition to stdout
#   GITHUB_ENV           written by the Actions runner (CANARY_STATUS / CANARY_FAILED)

set -euo pipefail

REPO="${REPO:-petry-projects/.github-private}"
WORKFLOW_FILE="${WORKFLOW_FILE:-initiative-planner.yml}"
UNSUPPORTED_EVENT_MARKER="Unsupported event type: discussion"

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested; no network)
# ---------------------------------------------------------------------------

# classify_canary_run <conclusion> <logs>
# Maps a completed run's conclusion + logs to a canary status:
#   UNSUPPORTED_EVENT — logs contain the redispatch-regression fingerprint
#                       (checked first: it is the signal #822 exists to catch,
#                        even if the run somehow concluded "success")
#   OK                — conclusion == success and no fingerprint
#   NO_RUN            — empty/null conclusion (no completed run was found)
#   FAILED            — any other conclusion (failure/timed_out/cancelled/…)
classify_canary_run() {
  local conclusion="${1:-}" logs="${2:-}"
  if [[ "$logs" == *"$UNSUPPORTED_EVENT_MARKER"* ]]; then
    echo "UNSUPPORTED_EVENT"
    return 0
  fi
  case "$conclusion" in
    success)    echo "OK" ;;
    ""|null)    echo "NO_RUN" ;;
    *)          echo "FAILED" ;;
  esac
}

# canary_is_failure <status>
# Exit 0 (alert) for any status other than OK; exit 1 for OK.
canary_is_failure() {
  [ "${1:-}" != "OK" ]
}

# canary_report <status> <repo> <discussion> <run_url> [today]
# Writes a Markdown alert/health body to stdout. Pure: no network.
canary_report() {
  local st="${1:-}" repo="${2:-}" disc="${3:-}" run_url="${4:-}" today="${5:-}"
  [ -n "$today" ] || today="$(date -u +%Y-%m-%d)"

  local icon headline
  case "$st" in
    OK)               icon='✅'; headline='canary passed' ;;
    UNSUPPORTED_EVENT) icon='🔴'; headline='REGRESSION — planner rejected the dispatch event' ;;
    NO_RUN)           icon='🟠'; headline='no planner run observed within the poll window' ;;
    *)                icon='🔴'; headline='planner dispatch run failed' ;;
  esac

  printf '# %s Initiative-planner canary — %s\n\n' "$icon" "$today"
  printf '_Repo `%s` · fixture Discussion #%s · path: `idea:approved` → redispatch → central planner_\n\n' \
    "$repo" "$disc"
  printf -- '- **Result:** %s — %s\n' "$st" "$headline"
  printf -- '- **Mode:** dry-run dispatch (`dry_run=true`) — creates no epic/issues\n'
  [ -n "$run_url" ] && printf -- '- **Run:** %s\n' "$run_url"
  printf '\n'

  if [ "$st" = "UNSUPPORTED_EVENT" ]; then
    printf '> The planner run surfaced `%s`. This is the exact failure from #655: ' "$UNSUPPORTED_EVENT_MARKER"
    printf 'the `discussion [labeled]` → `workflow_dispatch` redispatch bridge '
    printf '(`scripts/initiative-planner/redispatch.sh`) is missing or broken. Restore it.\n'
  elif [ "$st" = "NO_RUN" ]; then
    printf '> No `workflow_dispatch` planner run completed within the poll window. '
    printf 'The dispatch may have been rejected (PAT missing/expired) or the run is still queued.\n'
  elif [ "$st" != "OK" ]; then
    printf '> The dry-run planner dispatch did not conclude successfully — inspect the run log.\n'
  fi
}

# ---------------------------------------------------------------------------
# Network I/O (main)
# ---------------------------------------------------------------------------

main() {
  local disc="${CANARY_DISCUSSION:-${INITIATIVE_CANARY_DISCUSSION:-}}"
  if [ -z "$disc" ]; then
    echo "::error::CANARY_DISCUSSION (or INITIATIVE_CANARY_DISCUSSION) required (fixture Ideas Discussion number)" >&2
    exit 1
  fi
  # Validate before the value reaches the gh command line.
  if [[ ! "$disc" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::CANARY_DISCUSSION must be a positive integer, got: '$disc'" >&2
    exit 1
  fi
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

  echo "=== Initiative-planner canary ===" >&2
  echo "  Repo:       $REPO" >&2
  echo "  Workflow:   $WORKFLOW_FILE" >&2
  echo "  Discussion: #$disc (dry-run)" >&2

  # Fire the DRY-RUN dispatch. target_repo == REPO keeps the canary self-hosted
  # so a fleet repo's discussion number can never be planned by accident.
  local ref_flags=()
  if [[ -n "${GITHUB_REF:-}" && ( "$GITHUB_REF" == refs/heads/* || "$GITHUB_REF" == refs/tags/* ) ]]; then
    ref_flags=(--ref "$GITHUB_REF")
  fi
  gh workflow run "$WORKFLOW_FILE" --repo "$REPO" "${ref_flags[@]}" \
    -f discussion="$disc" \
    -f target_repo="$REPO" \
    -f dry_run=true \
    -f force_replan=false

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

  # Fetch logs of the completed run (best-effort) to scan for the regression
  # fingerprint. A missing/unreadable log is treated as empty.
  local logs=""
  if [ -n "$run_id" ]; then
    logs="$(gh run view "$run_id" --repo "$REPO" --log 2>/dev/null || true)"
  fi

  local result
  result="$(classify_canary_run "$conclusion" "$logs")"

  local run_url=""
  [ -n "$run_id" ] && run_url="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${run_id}"

  local report
  report="$(canary_report "$result" "$REPO" "$disc" "$run_url" "$today")"
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
    echo "::error::Initiative-planner canary result: ${result}" >&2
    exit 1
  fi
  echo "::notice::Initiative-planner canary passed (dry-run dispatch concluded success)." >&2
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
