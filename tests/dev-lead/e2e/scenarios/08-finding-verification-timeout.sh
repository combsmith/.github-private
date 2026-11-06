#!/usr/bin/env bash
# tests/dev-lead/e2e/scenarios/08-finding-verification-timeout.sh
#
# Scenario: The agentic iterative-validation step (issue #1092) must never hang
# the review. The repro that confirms/refutes a logic finding runs inside the deep
# tier's existing `run_agentic` invocation, which is wrapped by `timeout
# $DEEP_TIMEOUT_SEC` (engine.sh). This scenario proves that bound holds: a deep
# tier whose engine hangs far longer than the per-tier budget is killed at the
# budget, so validation is time-bounded and privilege-flat by construction.
#
# Approach: Script-based (no GitHub API). We stub `claude` to sleep well past a
# deliberately tiny DEEP_TIMEOUT_SEC, source engine.sh, call run_agentic on the
# deep tier, and assert it returns non-zero within a small margin of the budget
# (not after the full stub sleep).
set -euo pipefail

SCENARIO_NAME="08-finding-verification-timeout"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../lib/helpers.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
ENGINE_SCRIPT="${REPO_ROOT}/scripts/engine.sh"
STUB_ENGINES_DIR="${REPO_ROOT}/tests/dev-lead/fixtures/engines"

STUB_BIN_DIR=""
TMP_PROMPT=""
TMP_ENV=""

cleanup() {
  rm -rf "$STUB_BIN_DIR" 2>/dev/null || true
  rm -f "$TMP_PROMPT" "$TMP_ENV" 2>/dev/null || true
}
trap cleanup EXIT

main() {
  log "=== Scenario: ${SCENARIO_NAME} ==="
  log "Test: deep-tier validation repro is bounded by DEEP_TIMEOUT_SEC (cannot hang)"

  if [[ ! -f "${ENGINE_SCRIPT}" ]]; then
    err "engine.sh not found at: ${ENGINE_SCRIPT}"
    record_result "${SCENARIO_NAME}" "FAIL" "engine.sh not found"
    exit 1
  fi

  # ── Stub bin: a claude that hangs far past the per-tier budget ──────────────
  STUB_BIN_DIR="$(mktemp -d)"
  cp "${STUB_ENGINES_DIR}/stub-claude" "${STUB_BIN_DIR}/claude"
  chmod +x "${STUB_BIN_DIR}/claude"

  TMP_PROMPT="$(mktemp)"
  echo "validate this finding" > "${TMP_PROMPT}"
  TMP_ENV="$(mktemp)"

  local budget=2          # DEEP_TIMEOUT_SEC — the per-tier bound under test
  local stub_delay=30     # engine hangs 15x past the budget
  local margin=15         # generous upper bound: budget + retry/overhead

  log "Running run_agentic (deep tier) with DEEP_TIMEOUT_SEC=${budget}s, stub sleep=${stub_delay}s..."

  local rc=0 start end elapsed
  start="$(date +%s)"
  set +e
  (
    export PATH="${STUB_BIN_DIR}:${PATH}"
    export REVIEW_ENGINE="claude"
    export DEV_LEAD_DRY_RUN="false"
    export GITHUB_ENV="${TMP_ENV}"
    export GITHUB_OUTPUT="/dev/null"
    export DEEP_TIMEOUT_SEC="${budget}"
    export STUB_ENGINE_DELAY="${stub_delay}"
    # Ensure token logging is off so the stub path stays simple and no usage
    # sidecar work happens.
    unset TOKEN_LOG_FILE
    # shellcheck source=../../../../scripts/engine.sh
    source "${ENGINE_SCRIPT}"
    # Pass an explicit model (≠ the tier default) so the in-Claude fallback chain
    # is a single element — the timeout fires once, no chain re-attempts.
    run_agentic "${TMP_PROMPT}" "e2e-timeout-model" "deep" >/dev/null 2>&1
  )
  rc=$?
  set -e
  end="$(date +%s)"
  elapsed=$(( end - start ))

  log "run_agentic exit code: ${rc}"
  log "elapsed: ${elapsed}s (budget=${budget}s, stub sleep=${stub_delay}s)"

  # ── Assertions ──────────────────────────────────────────────────────────────
  local all_pass=true

  # It must NOT succeed — a hung engine cannot silently return a verdict.
  if [[ "${rc}" -ne 0 ]]; then
    echo "[PASS] ${SCENARIO_NAME}: run_agentic returned non-zero on hang (rc=${rc})"
  else
    echo "[FAIL] ${SCENARIO_NAME}: run_agentic returned 0 despite the hung engine"
    all_pass=false
  fi

  # It must return well before the stub's full sleep — proof the timeout fired.
  if [[ "${elapsed}" -lt "${margin}" ]]; then
    echo "[PASS] ${SCENARIO_NAME}: bounded — returned in ${elapsed}s (< ${margin}s), not ${stub_delay}s"
  else
    echo "[FAIL] ${SCENARIO_NAME}: took ${elapsed}s — the per-tier timeout did not bound it"
    all_pass=false
  fi

  if [[ "${all_pass}" = "true" ]]; then
    log "[PASS] ${SCENARIO_NAME}: deep-tier validation cannot hang the review"
    record_result "${SCENARIO_NAME}" "PASS" "rc=${rc} elapsed=${elapsed}s budget=${budget}s"
    exit 0
  else
    err "[FAIL] ${SCENARIO_NAME}: timeout bound not enforced"
    record_result "${SCENARIO_NAME}" "FAIL" "rc=${rc} elapsed=${elapsed}s budget=${budget}s"
    exit 1
  fi
}

main "$@"
