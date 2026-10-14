#!/usr/bin/env bash
# tests/dev-lead/e2e/run-all.sh — Master orchestrator for dev-lead E2E tests.
#
# Usage:
#   bash tests/dev-lead/e2e/run-all.sh [--dry-run] [--scenario <name>]
#
# Options:
#   --dry-run              Print what would run but do not execute any scenario.
#   --scenario <name>      Run only the named scenario (e.g. 01-skip-bot-pr).
#
# Environment variables:
#   GH_TOKEN or GH_PAT     GitHub PAT for API calls (required for live scenarios).
#   E2E_TARGET_REPO        Repository to test against (default: petry-projects/.github-private).
#   E2E_CLEANUP            Set to "false" to keep test PRs/branches/issues (default: true).
#   CLAUDE_CODE_OAUTH_TOKEN  Required for scenarios that exercise Claude-based handlers.
#                           Scenarios needing it will be skipped if absent.
#
# Exit codes:
#   0  All executed scenarios passed (or were skipped).
#   1  At least one scenario failed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIOS_DIR="${SCRIPT_DIR}/scenarios"
RESULTS_DIR="${SCRIPT_DIR}/results"
HELPERS="${SCRIPT_DIR}/lib/helpers.sh"

# ── Parse arguments ───────────────────────────────────────────────────────────

DRY_RUN=false
SINGLE_SCENARIO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --scenario)
      SINGLE_SCENARIO="${2:?--scenario requires an argument}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ── Setup ─────────────────────────────────────────────────────────────────────

mkdir -p "${RESULTS_DIR}"
export E2E_RESULTS_DIR="${RESULTS_DIR}"

RESULTS_FILE="${RESULTS_DIR}/results.txt"
SUMMARY_FILE="${RESULTS_DIR}/summary-$(date -u +%Y%m%d-%H%M%S).txt"

# Clear previous run results
> "${RESULTS_FILE}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

log "============================================================"
log "Dev-Lead Agent E2E Test Suite"
log "Target repo : ${E2E_TARGET_REPO:-petry-projects/.github-private}"
log "Dry run     : ${DRY_RUN}"
log "Scenario    : ${SINGLE_SCENARIO:-all}"
log "Cleanup     : ${E2E_CLEANUP:-true}"
log "============================================================"
echo ""

# ── Token / capability checks ─────────────────────────────────────────────────

HAS_GH_TOKEN=false
HAS_CLAUDE_TOKEN=false

if [ -n "${GH_TOKEN:-}" ] || [ -n "${GH_PAT:-}" ]; then
  HAS_GH_TOKEN=true
fi

if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  HAS_CLAUDE_TOKEN=true
fi

log "Capability check:"
log "  GH_TOKEN / GH_PAT : $( ${HAS_GH_TOKEN} && echo 'set' || echo 'NOT SET — live scenarios will be skipped')"
log "  CLAUDE_CODE_OAUTH_TOKEN : $( ${HAS_CLAUDE_TOKEN} && echo 'set' || echo 'NOT SET — scenarios requiring Claude will skip agent response assertions')"
echo ""

# Scenarios that require CLAUDE_CODE_OAUTH_TOKEN for full validation
# (without it, they still run but skip response-content assertions)
NEEDS_CLAUDE=(
  "02-human-at-mention"
  "03-ci-failure-relay"
  "04-issue-labeled"
)

# ── Discover scenarios ────────────────────────────────────────────────────────

mapfile -t ALL_SCENARIOS < <(find "${SCENARIOS_DIR}" -name "*.sh" | sort)

if [ "${#ALL_SCENARIOS[@]}" -eq 0 ]; then
  log "ERROR: No scenario scripts found in ${SCENARIOS_DIR}"
  exit 1
fi

# Filter to single scenario if requested
if [ -n "${SINGLE_SCENARIO}" ]; then
  FILTERED=()
  for s in "${ALL_SCENARIOS[@]}"; do
    if [[ "$(basename "$s" .sh)" == *"${SINGLE_SCENARIO}"* ]]; then
      FILTERED+=("$s")
    fi
  done
  if [ "${#FILTERED[@]}" -eq 0 ]; then
    log "ERROR: No scenario found matching '${SINGLE_SCENARIO}'"
    log "Available scenarios:"
    for s in "${ALL_SCENARIOS[@]}"; do
      log "  $(basename "$s" .sh)"
    done
    exit 1
  fi
  ALL_SCENARIOS=("${FILTERED[@]}")
fi

# ── Run scenarios ─────────────────────────────────────────────────────────────

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

for scenario_script in "${ALL_SCENARIOS[@]}"; do
  scenario_name="$(basename "${scenario_script}" .sh)"
  echo ""
  log "────────────────────────────────────────────────"
  log "Running: ${scenario_name}"
  log "────────────────────────────────────────────────"

  # ── Dry-run mode ────────────────────────────────────────────────────────────
  if [ "${DRY_RUN}" = "true" ]; then
    log "[DRY-RUN] Would execute: bash ${scenario_script}"
    echo "${scenario_name}: dry-run (not executed)"
    SKIP_COUNT=$(( SKIP_COUNT + 1 ))
    continue
  fi

  # ── Note which scenarios need CLAUDE_CODE_OAUTH_TOKEN ──────────────────────
  for needs_claude_scenario in "${NEEDS_CLAUDE[@]}"; do
    if [[ "${scenario_name}" == *"${needs_claude_scenario}"* ]] && [ "${HAS_CLAUDE_TOKEN}" = "false" ]; then
      log "  NOTE: ${scenario_name} will skip Claude response assertions (CLAUDE_CODE_OAUTH_TOKEN not set)"
    fi
  done

  # ── Execute scenario ────────────────────────────────────────────────────────
  set +e
  bash "${scenario_script}"
  scenario_exit=$?
  set -e

  if [ "${scenario_exit}" -eq 0 ]; then
    log "[PASS] ${scenario_name}"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
  else
    log "[FAIL] ${scenario_name} (exit code: ${scenario_exit})"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
log "============================================================"
log "E2E Test Summary"
log "============================================================"
log "  Passed : ${PASS_COUNT}"
log "  Failed : ${FAIL_COUNT}"
log "  Skipped: ${SKIP_COUNT}"
log "  Total  : $(( PASS_COUNT + FAIL_COUNT + SKIP_COUNT ))"
log "============================================================"

# Write summary report
{
  echo "Dev-Lead E2E Test Run — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Repo: ${E2E_TARGET_REPO:-petry-projects/.github-private}"
  echo "Passed: ${PASS_COUNT}  Failed: ${FAIL_COUNT}  Skipped: ${SKIP_COUNT}"
  echo ""
  echo "Per-scenario results:"
  cat "${RESULTS_FILE}" 2>/dev/null || echo "(no results recorded)"
} > "${SUMMARY_FILE}"

log "Summary written to: ${SUMMARY_FILE}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  log "RESULT: FAIL (${FAIL_COUNT} scenario(s) failed)"
  exit 1
fi

log "RESULT: PASS"
exit 0
