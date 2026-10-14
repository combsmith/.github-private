#!/usr/bin/env bash
# shadow-run.sh — shadow-mode dual-run comparison + signal emitter (#605).
#
# Consumes the results of the two agent lanes that ran on the SAME PR — the
# production `stable` lane (whose output is posted to the PR) and the silent
# `next` shadow lane (whose output is NOT posted) — classifies a
# quality-regression signal (scripts/lib/shadow-compare.sh) and emits it for the
# health-gated promotion gate (#501). This script posts NOTHING to the PR: the
# shadow lane stays silent by construction.
#
# It does not itself dispatch the two lanes. Dispatching `next` in parallel with
# `stable` and suppressing the shadow's PR output requires a shadow-mode input on
# the org-canonical dev-lead-reusable.yml / pr-review reusable; that dispatch
# wiring is the integration step documented in docs/release/shadow-mode.md. This
# wrapper is the comparison + signal half, testable in isolation.
#
# Env inputs:
#   REUSABLE            reusable under canary (default dev-lead)
#   SHADOW_CHANNEL      candidate channel being shadowed (default next)
#   STABLE_CONCLUSION   stable lane run conclusion (success/failure/cancelled/…)
#   SHADOW_CONCLUSION   shadow lane run conclusion (empty => no shadow run)
#   STABLE_OUTPUT_FILE  path to stable lane output (optional)
#   SHADOW_OUTPUT_FILE  path to shadow lane output (optional)
#   STABLE_RUN_ID       stable lane workflow run id (optional)
#   SHADOW_RUN_ID       shadow lane workflow run id (optional)
#   SHADOW_SIGNAL_OUT   path to write the JSON signal artifact (optional)
#   REPO                owner/repo, for run URLs (default petry-projects/.github-private)
#
# Outputs:
#   - JSON signal to SHADOW_SIGNAL_OUT (if set) — read by the #501 gate.
#   - Markdown report to stdout and $GITHUB_STEP_SUMMARY (if set).
#   - GITHUB_ENV: SHADOW_STATUS, SHADOW_REGRESSION, SHADOW_BLOCK_PROMOTION.
#
# Exit status is always 0 for a completed comparison: the shadow lane must never
# disrupt the PR. A regression surfaces as a `::warning::` + env flags + the
# signal artifact, which the promotion gate consumes — not as a failed check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/shadow-compare.sh
source "$SCRIPT_DIR/lib/shadow-compare.sh"

REPO="${REPO:-petry-projects/.github-private}"
REUSABLE="${REUSABLE:-dev-lead}"
SHADOW_CHANNEL="${SHADOW_CHANNEL:-next}"

read_output_file() {
  local path="${1:-}"
  [ -n "$path" ] && [ -f "$path" ] || { printf '%s' ""; return 0; }
  cat "$path"
}

run_url() {
  local run_id="${1:-}"
  [ -n "$run_id" ] || { printf '%s' ""; return 0; }
  printf '%s/%s/actions/runs/%s' "${GITHUB_SERVER_URL:-https://github.com}" "$REPO" "$run_id"
}

main() {
  local stable_out shadow_out status
  stable_out="$(read_output_file "${STABLE_OUTPUT_FILE:-}")"
  shadow_out="$(read_output_file "${SHADOW_OUTPUT_FILE:-}")"

  status="$(sc_classify \
    "${STABLE_CONCLUSION:-}" "${SHADOW_CONCLUSION:-}" \
    "$stable_out" "$shadow_out")"

  local signal
  signal="$(sc_signal_json "$status" "$REUSABLE" "$SHADOW_CHANNEL" \
    "${STABLE_RUN_ID:-}" "${SHADOW_RUN_ID:-}")"

  if [ -n "${SHADOW_SIGNAL_OUT:-}" ]; then
    printf '%s\n' "$signal" > "$SHADOW_SIGNAL_OUT"
  fi

  local report
  report="$(sc_report "$status" "$REUSABLE" "$SHADOW_CHANNEL" \
    "$(run_url "${STABLE_RUN_ID:-}")" "$(run_url "${SHADOW_RUN_ID:-}")")"
  printf '%s\n' "$report"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$report" >> "$GITHUB_STEP_SUMMARY"
  fi

  if [ -n "${GITHUB_ENV:-}" ]; then
    {
      printf 'SHADOW_STATUS=%s\n' "$status"
      if sc_is_blocking "$status"; then
        printf 'SHADOW_REGRESSION=true\n'
        printf 'SHADOW_BLOCK_PROMOTION=true\n'
      else
        printf 'SHADOW_REGRESSION=false\n'
        printf 'SHADOW_BLOCK_PROMOTION=false\n'
      fi
    } >> "$GITHUB_ENV"
  fi

  if sc_is_blocking "$status"; then
    echo "::warning::Shadow-mode dual-run detected a quality regression (${status}) — promotion of ${REUSABLE}/${SHADOW_CHANNEL} is blocked. The shadow lane did NOT post to the PR." >&2
  else
    echo "::notice::Shadow-mode dual-run result: ${status} (non-blocking) for ${REUSABLE}/${SHADOW_CHANNEL}." >&2
  fi
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
