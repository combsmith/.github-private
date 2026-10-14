#!/usr/bin/env bash
# initiative_driver_canary.sh — post-merge canary for the cross-repo release path.
#
# Implements #885 (epic #882): the central initiative-driver dispatches stories
# FOR a target repo by resolving an epic's cross-repo gate + blocked_by graph.
# A silent break of that path (gate logic, blocked_by resolution, dispatch
# plumbing) is only noticed when someone realizes nothing got released. This
# canary periodically dry-run-dispatches the driver against a fixture target
# repo + epic and alerts the moment the path stops resolving.
#
# What it does: fires a DRY-RUN dispatch of initiative-driver.yml with
# target_repo=<fixture> and epic=<fixture>, waits for the resulting
# workflow_dispatch run, and treats it as FAILED if (a) the run's conclusion is
# not success, or (b) — the HOLLOW-GREEN guard — the run was green but its log
# contains NO "READY (dry-run, not labeling)" decision, meaning the cross-repo
# gate/blocked_by resolved to nothing. Dry-run applies no `dev-lead` label, so no
# dev-lead/LLM run is triggered and the canary creates/labels nothing.
#
# Layout mirrors scripts/initiative_canary.sh:
#   * classify_canary_run / canary_is_failure / canary_report are PURE — they
#     take scalars and write stdout. Unit-tested in
#     tests/test_initiative_driver_canary.bats.
#   * main() does the network I/O: dispatch, poll, log fetch.
#
# Env vars consumed:
#   REPO                 owner/repo hosting the driver (default petry-projects/.github-private)
#   CANARY_TARGET        fixture target repo owner/repo to dry-run drive (required)
#   CANARY_EPIC          fixture epic number in the target repo (required; positive int)
#   WORKFLOW_FILE        driver workflow to dispatch (default initiative-driver.yml)
#   GH_TOKEN             a PAT with workflow scope (a workflow_dispatch fired with
#                        GITHUB_TOKEN is accepted but never starts a run)
#   CANARY_POLL_TIMEOUT  seconds to wait for the run to complete (default 600)
#   CANARY_POLL_INTERVAL seconds between polls (default 15)
#   CANARY_OUT           optional path; the report is written there in addition to stdout
#   GITHUB_ENV           written by the Actions runner (CANARY_STATUS / CANARY_FAILED)

set -euo pipefail

REPO="${REPO:-petry-projects/.github-private}"
WORKFLOW_FILE="${WORKFLOW_FILE:-initiative-driver.yml}"
# Emitted by scripts/initiative-driver.sh in its DRY_RUN branch for each ready
# sub-issue. Its absence in a configured run means the path resolved to nothing.
READY_MARKER="READY (dry-run, not labeling)"

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested; no network)
# ---------------------------------------------------------------------------

# classify_canary_run <conclusion> <logs>
# Maps a completed run's conclusion + logs to a canary status:
#   OK           — conclusion == success AND the logs carry a READY decision
#   HOLLOW_GREEN — conclusion == success but NO READY decision (the cross-repo
#                  gate/blocked_by resolved to nothing — a silent break)
#   NO_RUN       — empty/null conclusion (no completed run was found)
#   FAILED       — any other conclusion (failure/timed_out/cancelled/…)
classify_canary_run() {
  local conclusion="${1:-}" logs="${2:-}"
  case "$conclusion" in
    success)
      if [[ "$logs" == *"$READY_MARKER"* ]]; then
        echo "OK"
      else
        echo "HOLLOW_GREEN"
      fi
      ;;
    ""|null)    echo "NO_RUN" ;;
    *)          echo "FAILED" ;;
  esac
}

# canary_is_failure <status>
# Exit 0 (alert) for any status other than OK; exit 1 for OK.
canary_is_failure() {
  [ "${1:-}" != "OK" ]
}

# canary_report <status> <repo> <target> <epic> <run_url> [today]
# Writes a Markdown alert/health body to stdout. Pure: no network.
canary_report() {
  local st="${1:-}" repo="${2:-}" target="${3:-}" epic="${4:-}" run_url="${5:-}" today="${6:-}"
  [ -n "$today" ] || today="$(date -u +%Y-%m-%d)"

  local icon headline
  case "$st" in
    OK)           icon='✅'; headline='canary passed' ;;
    HOLLOW_GREEN) icon='🔴'; headline='HOLLOW GREEN — run succeeded but the cross-repo path resolved nothing' ;;
    NO_RUN)       icon='🟠'; headline='no driver run observed within the poll window' ;;
    *)            icon='🔴'; headline='driver dispatch run failed' ;;
  esac

  printf '# %s Initiative-driver canary — %s\n\n' "$icon" "$today"
  printf '_Host `%s` · fixture target `%s` epic #%s · path: cross-repo gate → blocked_by → release_\n\n' \
    "$repo" "$target" "$epic"
  printf -- '- **Result:** %s — %s\n' "$st" "$headline"
  printf -- '- **Mode:** dry-run dispatch (`dry_run=true`) — applies no `dev-lead` label, releases nothing\n'
  [ -n "$run_url" ] && printf -- '- **Run:** %s\n' "$run_url"
  printf '\n'

  if [ "$st" = "HOLLOW_GREEN" ]; then
    printf '> The driver run concluded `success` but its log carried no '
    printf '`%s` decision for the fixture target. ' "$READY_MARKER"
    printf 'The cross-repo gate (`initiative:auto`) or `blocked_by` resolution produced no ready '
    printf 'sub-issue — the release path is silently broken even though CI is green. '
    printf 'Verify the fixture epic is still armed with a ready sub-issue, then inspect the driver logic.\n'
  elif [ "$st" = "NO_RUN" ]; then
    printf '> No `workflow_dispatch` driver run completed within the poll window. '
    printf 'The dispatch may have been rejected (PAT missing/expired) or the run is still queued.\n'
  elif [ "$st" != "OK" ]; then
    printf '> The dry-run driver dispatch did not conclude successfully — inspect the run log.\n'
  fi
}

# ---------------------------------------------------------------------------
# Network I/O (main)
# ---------------------------------------------------------------------------

main() {
  local target="${CANARY_TARGET:-${INITIATIVE_DRIVER_CANARY_TARGET:-}}"
  local epic="${CANARY_EPIC:-${INITIATIVE_DRIVER_CANARY_EPIC:-}}"
  if [ -z "$target" ] || [ -z "$epic" ]; then
    echo "::error::INITIATIVE_DRIVER_CANARY_TARGET and INITIATIVE_DRIVER_CANARY_EPIC (or CANARY_TARGET/CANARY_EPIC) are required (fixture target repo + epic)." >&2
    exit 1
  fi
  # Validate before the values reach the gh command line.
  if [[ ! "$target" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "::error::CANARY_TARGET must be owner/repo, got: '$target'" >&2
    exit 1
  fi
  if [[ ! "$epic" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::CANARY_EPIC must be a positive integer, got: '$epic'" >&2
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

  echo "=== Initiative-driver canary ===" >&2
  echo "  Host repo:  $REPO" >&2
  echo "  Workflow:   $WORKFLOW_FILE" >&2
  echo "  Target:     $target (dry-run)" >&2
  echo "  Epic:       #$epic" >&2

  # Fire the DRY-RUN dispatch against the FIXTURE target + epic.
  local ref_flags=()
  if [[ -n "${GITHUB_REF:-}" && ( "$GITHUB_REF" == refs/heads/* || "$GITHUB_REF" == refs/tags/* ) ]]; then
    ref_flags=(--ref "$GITHUB_REF")
  fi
  gh workflow run "$WORKFLOW_FILE" --repo "$REPO" "${ref_flags[@]}" \
    -f target_repo="$target" \
    -f epic="$epic" \
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

  # Fetch logs of the completed run (best-effort) to scan for the READY decision.
  # A missing/unreadable log is treated as empty (→ HOLLOW_GREEN on a green run).
  local logs=""
  if [ -n "$run_id" ]; then
    logs="$(gh run view "$run_id" --repo "$REPO" --log 2>/dev/null || true)"
  fi

  local result
  result="$(classify_canary_run "$conclusion" "$logs")"

  local run_url=""
  [ -n "$run_id" ] && run_url="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${run_id}"

  local report
  report="$(canary_report "$result" "$REPO" "$target" "$epic" "$run_url" "$today")"
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
    echo "::error::Initiative-driver canary result: ${result}" >&2
    exit 1
  fi
  echo "::notice::Initiative-driver canary passed (dry-run dispatch resolved a READY decision)." >&2
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
