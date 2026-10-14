#!/usr/bin/env bash
# tests/dev-lead/e2e/scenarios/06-exhaustion-guard.sh
#
# Scenario: After MAX_FAIL_ATTEMPTS failures, the exhaustion marker blocks
# further retries on fix-ci.
#
# Approach: Script-based (no real GitHub API needed — uses a stub gh binary).
# We run dev-lead-fix-ci.sh directly with:
#   - DEV_LEAD_DRY_RUN=false
#   - A mock gh that returns existing status=failed markers
#   - STUB_ENGINE_EXIT=1 to simulate another engine failure
#   - MAX_FAIL_ATTEMPTS=2 (threshold)
#
# Expected:
#   - Script exits 1 (engine failure, not blocked by exhaustion marker itself)
#   - Script posts exhaustion comment (because fail count hits threshold)
#   - Output contains "exhaustion" / "threshold" language
#
# This mirrors the exhaustion bats test but as a self-contained bash E2E scenario
# that also validates the comment-posting path explicitly.
set -euo pipefail

SCENARIO_NAME="06-exhaustion-guard"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../lib/helpers.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
FIX_CI_SCRIPT="${REPO_ROOT}/scripts/dev-lead-fix-ci.sh"
STUB_ENGINE_DIR=""
GITHUB_ENV_FILE=""

cleanup() {
  rm -f "$GITHUB_ENV_FILE" 2>/dev/null || true
  rm -rf "$STUB_ENGINE_DIR" 2>/dev/null || true
}

trap cleanup EXIT

main() {
  log "=== Scenario: ${SCENARIO_NAME} ==="
  log "Test: exhaustion guard posts PR-level block after MAX_FAIL_ATTEMPTS"

  if [ ! -f "${FIX_CI_SCRIPT}" ]; then
    err "dev-lead-fix-ci.sh not found at: ${FIX_CI_SCRIPT}"
    record_result "${SCENARIO_NAME}" "FAIL" "fix-ci script not found"
    exit 1
  fi

  # ── Set up stub bin directory ──────────────────────────────────────────────
  STUB_ENGINE_DIR=$(mktemp -d)
  GITHUB_ENV_FILE=$(mktemp)

  # ── Stub: claude (simulate engine failure) ─────────────────────────────────
  cat > "${STUB_ENGINE_DIR}/claude" << 'CLAUDE_STUB'
#!/usr/bin/env bash
# Stub claude: exits with configured exit code
exit "${STUB_ENGINE_EXIT:-1}"
CLAUDE_STUB

  # ── Stub: gh (returns 2 pre-existing status=failed markers) ──────────────
  cat > "${STUB_ENGINE_DIR}/gh" << 'GH_STUB'
#!/usr/bin/env bash
# Stub gh for exhaustion guard test
ARGS="$*"
case "$ARGS" in
  *"issues/42/comments"*)
    # Return 2 failed markers — triggers exhaustion threshold (MAX_FAIL_ATTEMPTS=2)
    echo '[
      {"body":"<!-- dev-lead-fix-ci sha=aaa111 status=failed -->\nfailed attempt 1"},
      {"body":"<!-- dev-lead-fix-ci sha=bbb222 status=failed -->\nfailed attempt 2"}
    ]'
    ;;
  *"pr checkout"*)
    # Succeed silently (needed before engine runs)
    exit 0
    ;;
  *"pr comment"*)
    # Print what would be posted so we can verify it
    echo "STUB_GH_COMMENT_POSTED=true"
    echo "comment-args: $ARGS"
    exit 0
    ;;
  *"run view"*)
    echo "fake log output line 1"
    echo "fake log output line 2"
    ;;
  *)
    echo "{}"
    ;;
esac
GH_STUB

  chmod +x "${STUB_ENGINE_DIR}/claude" "${STUB_ENGINE_DIR}/gh"

  # ── Run fix-ci with exhaustion scenario ────────────────────────────────────
  log "Running dev-lead-fix-ci.sh with 2 existing failures (threshold=2)..."

  local output exit_code
  set +e
  output=$(
    PATH="${STUB_ENGINE_DIR}:${PATH}" \
    GITHUB_ENV="${GITHUB_ENV_FILE}" \
    GITHUB_OUTPUT="/dev/null" \
    PR_NUMBER="42" \
    HEAD_SHA="ccc333new-sha-not-in-markers" \
    CHECKS_JSON='[{"name":"test-check","conclusion":"failure","details_url":"https://github.com/fake/runs/99999","app_slug":"github-actions"}]' \
    REPO="petry-projects/.github-private" \
    REVIEW_ENGINE="claude" \
    DEV_LEAD_DRY_RUN="false" \
    MAX_FAIL_ATTEMPTS="2" \
    STUB_ENGINE_EXIT="1" \
    PROMPTS_DIR="${REPO_ROOT}/prompts/dev-lead" \
    bash "${FIX_CI_SCRIPT}" 2>&1
  )
  exit_code=$?
  set -e

  log "fix-ci exit code: ${exit_code}"
  log "fix-ci output:"
  echo "${output}" | sed 's/^/  /'

  # ── Part B: existing PR-level exhaustion marker blocks immediately ─────────
  log ""
  log "Part B: pre-existing exhaustion marker on PR blocks new SHA"

  cat > "${STUB_ENGINE_DIR}/gh" << 'GH_STUB2'
#!/usr/bin/env bash
case "$*" in
  *"issues/42/comments"*)
    echo '[
      {"body":"<!-- dev-lead-fix-ci pr=42 status=exhausted -->\nPR is exhausted"},
      {"body":"<!-- dev-lead-fix-ci sha=old111 status=failed -->\nold failure"}
    ]'
    ;;
  *) echo "{}" ;;
esac
GH_STUB2
  chmod +x "${STUB_ENGINE_DIR}/gh"

  local output_b exit_code_b
  set +e
  output_b=$(
    PATH="${STUB_ENGINE_DIR}:${PATH}" \
    GITHUB_ENV="${GITHUB_ENV_FILE}" \
    GITHUB_OUTPUT="/dev/null" \
    PR_NUMBER="42" \
    HEAD_SHA="brand-new-sha-xyz" \
    CHECKS_JSON='[{"name":"test-check","conclusion":"failure","details_url":"","app_slug":"github-actions"}]' \
    REPO="petry-projects/.github-private" \
    REVIEW_ENGINE="claude" \
    DEV_LEAD_DRY_RUN="false" \
    MAX_FAIL_ATTEMPTS="2" \
    PROMPTS_DIR="${REPO_ROOT}/prompts/dev-lead" \
    bash "${FIX_CI_SCRIPT}" 2>&1
  )
  exit_code_b=$?
  set -e

  log "fix-ci exit code (exhausted PR): ${exit_code_b}"
  log "fix-ci output (exhausted PR):"
  echo "${output_b}" | sed 's/^/  /'

  # ── Assertions ─────────────────────────────────────────────────────────────
  local all_pass=true

  # Part A: engine failure with threshold hit
  # Script should exit 1 (engine failed)
  if ! assert_eq "${exit_code}" "1" "${SCENARIO_NAME}(A): script exits 1 on engine failure"; then
    all_pass=false
  fi

  # Output should mention exhaustion threshold being reached
  if echo "${output}" | grep -qiE "exhaustion|threshold|exhausted"; then
    echo "[PASS] ${SCENARIO_NAME}(A): output mentions exhaustion threshold"
  else
    echo "[FAIL] ${SCENARIO_NAME}(A): output does not mention exhaustion threshold"
    all_pass=false
  fi

  # Output should contain the exhaustion comment body (posted via stub gh)
  if echo "${output}" | grep -qF "status=exhausted"; then
    echo "[PASS] ${SCENARIO_NAME}(A): exhaustion marker written to comment"
  else
    echo "[FAIL] ${SCENARIO_NAME}(A): exhaustion marker not found in output"
    all_pass=false
  fi

  # Part B: pre-existing exhaustion marker blocks run with exit 0
  if ! assert_eq "${exit_code_b}" "0" "${SCENARIO_NAME}(B): pre-exhausted PR exits 0 (blocked not failed)"; then
    all_pass=false
  fi

  if echo "${output_b}" | grep -qiE "exhausted|exhaustion|skipping"; then
    echo "[PASS] ${SCENARIO_NAME}(B): output confirms PR is blocked by exhaustion marker"
  else
    echo "[FAIL] ${SCENARIO_NAME}(B): exhaustion block message not found in output"
    all_pass=false
  fi

  # ── Result ─────────────────────────────────────────────────────────────────
  if [ "${all_pass}" = "true" ]; then
    log "[PASS] ${SCENARIO_NAME}: exhaustion guard blocks repeated CI fix attempts"
    record_result "${SCENARIO_NAME}" "PASS" \
      "threshold-hit-exits-1 pre-exhausted-exits-0"
    exit 0
  else
    err "[FAIL] ${SCENARIO_NAME}: one or more assertions failed"
    record_result "${SCENARIO_NAME}" "FAIL" \
      "exitA=${exit_code} exitB=${exit_code_b}"
    exit 1
  fi
}

main "$@"
