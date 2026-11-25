#!/usr/bin/env bash
# tests/dev-lead/e2e/scenarios/01-skip-bot-pr.sh
#
# Scenario: A PR opened by dependabot[bot] emits "skip" intent — no handler runs.
#
# Approach: Use the fixture-based approach (faster, fully local, no network).
# We invoke dev-lead-intent.sh directly with the dependabot PR fixture and
# assert that INTENT_TYPE=skip and INTENT_REASON=bot-pr.
#
# This avoids needing to actually open a dependabot PR (which requires bot
# credentials) while still validating the correct routing decision.
set -euo pipefail

SCENARIO_NAME="01-skip-bot-pr"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../lib/helpers.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
INTENT_SCRIPT="${REPO_ROOT}/scripts/dev-lead-intent.sh"
FIXTURE_DIR="${REPO_ROOT}/tests/dev-lead/fixtures/events"

GITHUB_ENV_FILE=""
GITHUB_OUTPUT_FILE=""

cleanup() {
  rm -f "$GITHUB_ENV_FILE" "$GITHUB_OUTPUT_FILE" 2>/dev/null || true
}

trap cleanup EXIT

_get_env_var() {
  local key="$1"
  grep "^${key}=" "$GITHUB_ENV_FILE" | cut -d= -f2- | head -1
}

main() {
  log "=== Scenario: ${SCENARIO_NAME} ==="
  log "Test: dependabot[bot] PR open → intent=skip (reason=bot-pr)"

  # ── Setup ──────────────────────────────────────────────────────────────────
  GITHUB_ENV_FILE=$(mktemp)
  GITHUB_OUTPUT_FILE=$(mktemp)

  if [[ ! -f "${INTENT_SCRIPT}" ]]; then
    err "dev-lead-intent.sh not found at: ${INTENT_SCRIPT}"
    record_result "${SCENARIO_NAME}" "FAIL" "intent script not found"
    exit 1
  fi

  local fixture="${FIXTURE_DIR}/pr_opened_dependabot.json"
  if [[ ! -f "${fixture}" ]]; then
    err "Fixture not found: ${fixture}"
    record_result "${SCENARIO_NAME}" "FAIL" "fixture missing"
    exit 1
  fi

  log "Using fixture: pr_opened_dependabot.json"
  log "sender.login in fixture: $(jq -r '.sender.login' "${fixture}")"

  # ── Run intent classifier ─────────────────────────────────────────────────
  local intent_output
  intent_output=$(
    GITHUB_ENV="${GITHUB_ENV_FILE}" \
    GITHUB_OUTPUT="${GITHUB_OUTPUT_FILE}" \
    GITHUB_EVENT_NAME="pull_request" \
    GITHUB_EVENT_PATH="${fixture}" \
    GITHUB_REPOSITORY="${E2E_TARGET_REPO}" \
    BOT_USER="donpetry-bot" \
    bash "${INTENT_SCRIPT}" 2>&1
  )

  local exit_code=$?
  log "Intent script exit code: ${exit_code}"
  log "Intent script output:"
  echo "${intent_output}" | sed 's/^/  /'

  # ── Assertions ─────────────────────────────────────────────────────────────
  local intent_type intent_reason
  intent_type=$(_get_env_var "INTENT_TYPE")
  intent_reason=$(_get_env_var "INTENT_REASON")

  log "INTENT_TYPE=${intent_type}  INTENT_REASON=${intent_reason}"

  local all_pass=true

  if ! assert_eq "${exit_code}" "0" "${SCENARIO_NAME}: script exits 0"; then
    all_pass=false
  fi

  if ! assert_eq "${intent_type}" "skip" "${SCENARIO_NAME}: INTENT_TYPE=skip"; then
    all_pass=false
  fi

  if ! assert_eq "${intent_reason}" "bot-pr" "${SCENARIO_NAME}: INTENT_REASON=bot-pr"; then
    all_pass=false
  fi

  # ── Result ─────────────────────────────────────────────────────────────────
  if [[ "${all_pass}" = "true" ]]; then
    log "[PASS] ${SCENARIO_NAME}: dependabot PR correctly routed to skip(bot-pr)"
    record_result "${SCENARIO_NAME}" "PASS" "intent=skip reason=bot-pr"
    exit 0
  else
    err "[FAIL] ${SCENARIO_NAME}: one or more assertions failed"
    record_result "${SCENARIO_NAME}" "FAIL" "intent=${intent_type} reason=${intent_reason}"
    exit 1
  fi
}

main "$@"
