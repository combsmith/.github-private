#!/usr/bin/env bash
# tests/dev-lead/e2e/scenarios/05-skip-anti-loop.sh
#
# Scenario: A push from "donpetry-bot" (BOT_USER) triggers the anti-loop
# guard → intent = skip (reason = dev-lead-own-commit).
#
# Approach: Fixture-based (fully local, no network required).
# We invoke dev-lead-intent.sh with the pr_sync_dev_lead_commit.json fixture
# which has sender.login = "donpetry-bot" and action = "synchronize".
#
# The anti-loop guard in dev-lead-intent.sh checks:
#   event = pull_request, action = synchronize, sender = BOT_USER
# and emits skip(dev-lead-own-commit).
#
# This is fast and deterministic — no GitHub API calls needed.
set -euo pipefail

SCENARIO_NAME="05-skip-anti-loop"
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
  log "Test: pull_request synchronize from BOT_USER → intent=skip(dev-lead-own-commit)"

  # ── Setup ──────────────────────────────────────────────────────────────────
  GITHUB_ENV_FILE=$(mktemp)
  GITHUB_OUTPUT_FILE=$(mktemp)

  if [ ! -f "${INTENT_SCRIPT}" ]; then
    err "dev-lead-intent.sh not found at: ${INTENT_SCRIPT}"
    record_result "${SCENARIO_NAME}" "FAIL" "intent script not found"
    exit 1
  fi

  local fixture="${FIXTURE_DIR}/pr_sync_dev_lead_commit.json"
  if [ ! -f "${fixture}" ]; then
    err "Fixture not found: ${fixture}"
    record_result "${SCENARIO_NAME}" "FAIL" "fixture missing"
    exit 1
  fi

  log "Using fixture: pr_sync_dev_lead_commit.json"
  log "Fixture sender.login: $(jq -r '.sender.login' "${fixture}")"
  log "Fixture action:       $(jq -r '.action' "${fixture}")"

  # ── Part A: BOT_USER synchronize → must emit skip ─────────────────────────
  log ""
  log "Part A: synchronize from BOT_USER='donpetry-bot'"

  local intent_output_a
  intent_output_a=$(
    GITHUB_ENV="${GITHUB_ENV_FILE}" \
    GITHUB_OUTPUT="${GITHUB_OUTPUT_FILE}" \
    GITHUB_EVENT_NAME="pull_request" \
    GITHUB_EVENT_PATH="${fixture}" \
    GITHUB_REPOSITORY="${E2E_TARGET_REPO}" \
    BOT_USER="donpetry-bot" \
    bash "${INTENT_SCRIPT}" 2>&1
  )

  local exit_code_a=$?
  log "Script exit code: ${exit_code_a}"
  echo "${intent_output_a}" | sed 's/^/  /'

  local intent_type_a intent_reason_a
  intent_type_a=$(_get_env_var "INTENT_TYPE")
  intent_reason_a=$(_get_env_var "INTENT_REASON")
  log "INTENT_TYPE=${intent_type_a}  INTENT_REASON=${intent_reason_a}"

  # Reset for part B
  > "$GITHUB_ENV_FILE"
  > "$GITHUB_OUTPUT_FILE"

  # ── Part B: human synchronize → must NOT emit anti-loop skip ──────────────
  log ""
  log "Part B: synchronize from human user (not BOT_USER) — using pr_opened_human.json"

  local human_fixture="${FIXTURE_DIR}/pr_opened_human.json"
  # pr_opened_human.json has action=opened, but we just need a sender that's not the bot
  # We also verify the human synchronize path doesn't accidentally hit anti-loop.
  # For a pure synchronize test from a human, we'd need a separate fixture.
  # The existing pr_opened_human.json has action=opened which goes through different routing.
  # We create an inline fixture for a human synchronize:
  local human_sync_fixture
  human_sync_fixture=$(mktemp --suffix=.json)
  jq -n '{
    action: "synchronize",
    number: 99,
    pull_request: {
      number: 99,
      title: "Human sync test",
      body: "",
      state: "open",
      author_association: "OWNER",
      head: {
        sha: "human999sha",
        ref: "feat/human-branch",
        repo: { full_name: "petry-projects/.github-private" }
      },
      base: {
        ref: "main",
        repo: { full_name: "petry-projects/.github-private" }
      }
    },
    repository: { full_name: "petry-projects/.github-private" },
    sender: { login: "donpetry", type: "User" }
  }' > "${human_sync_fixture}"

  local intent_output_b
  intent_output_b=$(
    GITHUB_ENV="${GITHUB_ENV_FILE}" \
    GITHUB_OUTPUT="${GITHUB_OUTPUT_FILE}" \
    GITHUB_EVENT_NAME="pull_request" \
    GITHUB_EVENT_PATH="${human_sync_fixture}" \
    GITHUB_REPOSITORY="${E2E_TARGET_REPO}" \
    BOT_USER="donpetry-bot" \
    bash "${INTENT_SCRIPT}" 2>&1
  )

  local exit_code_b=$?
  log "Script exit code (human sync): ${exit_code_b}"
  echo "${intent_output_b}" | sed 's/^/  /'

  local intent_type_b intent_reason_b
  intent_type_b=$(_get_env_var "INTENT_TYPE")
  intent_reason_b=$(_get_env_var "INTENT_REASON")
  log "INTENT_TYPE=${intent_type_b}  INTENT_REASON=${intent_reason_b}"

  rm -f "${human_sync_fixture}"

  # ── Assertions ─────────────────────────────────────────────────────────────
  local all_pass=true

  # Part A: BOT_USER must trigger skip
  if ! assert_eq "${exit_code_a}" "0" "${SCENARIO_NAME}(A): script exits 0"; then
    all_pass=false
  fi
  if ! assert_eq "${intent_type_a}" "skip" "${SCENARIO_NAME}(A): INTENT_TYPE=skip"; then
    all_pass=false
  fi
  if ! assert_eq "${intent_reason_a}" "dev-lead-own-commit" "${SCENARIO_NAME}(A): INTENT_REASON=dev-lead-own-commit"; then
    all_pass=false
  fi

  # Part B: human must NOT trigger anti-loop skip
  if ! assert_eq "${exit_code_b}" "0" "${SCENARIO_NAME}(B): script exits 0"; then
    all_pass=false
  fi
  # Negative assertion: human reason must NOT be dev-lead-own-commit
  if [ "${intent_reason_b}" = "dev-lead-own-commit" ]; then
    echo "[FAIL] ${SCENARIO_NAME}(B): human sync incorrectly got reason=dev-lead-own-commit"
    all_pass=false
  else
    echo "[PASS] ${SCENARIO_NAME}(B): human sync correctly NOT skipped with anti-loop reason (got: ${intent_reason_b})"
  fi
  # A human sync on a human-authored branch (not dev-lead/issue-*) must be left
  # to the human: skip not-dev-lead-authored (#1311), not seized by dev-lead.
  if ! assert_eq "${intent_type_b}" "skip" "${SCENARIO_NAME}(B): INTENT_TYPE=skip for human sync"; then
    all_pass=false
  fi
  if ! assert_eq "${intent_reason_b}" "not-dev-lead-authored" "${SCENARIO_NAME}(B): INTENT_REASON=not-dev-lead-authored for human sync"; then
    all_pass=false
  fi

  # ── Result ─────────────────────────────────────────────────────────────────
  if [ "${all_pass}" = "true" ]; then
    log "[PASS] ${SCENARIO_NAME}: anti-loop guard fires for BOT_USER, human PR left untouched"
    record_result "${SCENARIO_NAME}" "PASS" "bot→skip(dev-lead-own-commit) human→skip(not-dev-lead-authored)"
    exit 0
  else
    err "[FAIL] ${SCENARIO_NAME}: one or more assertions failed"
    record_result "${SCENARIO_NAME}" "FAIL" \
      "botIntent=${intent_type_a} botReason=${intent_reason_a} humanIntent=${intent_type_b}"
    exit 1
  fi
}

main "$@"
