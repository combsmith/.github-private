#!/usr/bin/env bash
# tests/dev-lead/e2e/scenarios/03-ci-failure-relay.sh
#
# Scenario: A failing check on a PR triggers ci-relay → repository_dispatch
# → fix-ci intent.
#
# Approach:
#   1. Create a branch with a deliberate bash syntax error in a test script.
#   2. Create a PR — this triggers the test-dev-lead CI workflow, which runs
#      shellcheck / bash -n and will fail.
#   3. The check_run completed failure fires the ci-relay job in dev-lead.yml,
#      which emits a repository_dispatch dev-lead-ci-failure event.
#   4. The dispatch job then runs with intent=fix-ci.
#
# Requires: GH_TOKEN, real GitHub API access.
set -euo pipefail

SCENARIO_NAME="03-ci-failure-relay"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../lib/helpers.sh"

BRANCH=""
PR_NUMBER=""

cleanup() {
  log "Cleanup: ${SCENARIO_NAME}"
  [[ -n "$PR_NUMBER" ]] && cleanup_pr "${PR_NUMBER}" || true
  [[ -n "$BRANCH" ]] && cleanup_branch "${BRANCH}" || true
}

trap cleanup EXIT

main() {
  log "=== Scenario: ${SCENARIO_NAME} ==="
  log "Test: CI failure → ci-relay → repository_dispatch → fix-ci intent"

  # ── Check for required token ───────────────────────────────────────────────
  if [[ -z "${GH_TOKEN:-}" ]]; then
    err "GH_TOKEN not set — skipping live scenario ${SCENARIO_NAME}"
    record_result "${SCENARIO_NAME}" "SKIP" "GH_TOKEN not set"
    exit 0
  fi

  local start_time
  start_time=$(now_iso)

  # ── Create branch with a deliberate syntax error ───────────────────────────
  BRANCH=$(create_test_branch "e2e/03-ci-failure")
  log "Branch: ${BRANCH}"

  # The failing file: a shell script with a syntax error (missing 'fi')
  # shellcheck will catch this, or bash -n will reject it.
  local bad_script
  bad_script='#!/usr/bin/env bash
# E2E test: intentional syntax error for CI failure scenario
# This file is part of the automated E2E test suite — safe to delete.
if [ "x" = "y" ]; then
  echo "syntax error below — missing fi"
  # deliberately omitting fi to trigger shellcheck/bash -n failure
'
  local content_b64
  content_b64=$(printf '%s' "${bad_script}" | base64 -w0)

  log "Pushing syntactically invalid shell script to branch..."
  local head_sha
  head_sha=$(push_file_to_branch \
    "${BRANCH}" \
    "tests/dev-lead/e2e/.tmp-bad-script-03.sh" \
    "${content_b64}" \
    "test(e2e): scenario 03 — intentional CI failure file")

  log "HEAD SHA: ${head_sha}"

  # ── Open a PR ──────────────────────────────────────────────────────────────
  PR_NUMBER=$(create_test_pr \
    "${BRANCH}" \
    "[E2E] Scenario 03: CI failure relay test" \
    "Automated E2E test PR for scenario 03. Contains an intentional syntax error. Safe to close.")

  log "PR number: ${PR_NUMBER}"

  # ── Wait for a check_run failure to appear ─────────────────────────────────
  log "Waiting for a failing check on PR #${PR_NUMBER} / SHA ${head_sha:0:8}..."
  local check_status="pending"
  local deadline=$(( $(date +%s) + 300 ))

  while [ "$(date +%s)" -lt "$deadline" ]; do
    local check_data
    check_data=$(gh api \
      "repos/${E2E_TARGET_REPO}/commits/${head_sha}/check-runs" \
      --jq '[.check_runs[] | select(.conclusion == "failure")] | length' \
      2>/dev/null || echo "0")

    if [ "${check_data}" -gt 0 ]; then
      log "Found ${check_data} failing check(s) on ${head_sha:0:8}"
      check_status="failed"
      break
    fi
    log "  no failures yet, waiting 15s..."
    sleep 15
  done

  if [[ "${check_status}" != "failed" ]]; then
    warn "No check failures appeared within timeout — CI may not run shellcheck on this branch"
    warn "Attempting to verify ci-relay via repository_dispatch directly..."
    # Fall through to check for the dispatch workflow
  fi

  # ── Wait for ci-relay to fire and dispatch repository_dispatch ──────────────
  log "Waiting for Dev-Lead Agent ci-relay + dispatch (fix-ci) workflows..."

  # First wait for ci-relay job to complete (it handles check_run events)
  local relay_conclusion
  relay_conclusion=$(wait_for_workflow \
    "${E2E_TARGET_REPO}" \
    "Dev-Lead Agent" \
    "${head_sha}" \
    360) || relay_conclusion="timeout"

  log "Dev-Lead Agent workflow conclusion (relay phase): ${relay_conclusion}"

  # After ci-relay fires a repository_dispatch, a new dispatch job runs
  # with the fix-ci intent. We wait for it by event type.
  log "Waiting for fix-ci dispatch workflow (triggered by repository_dispatch)..."
  local dispatch_conclusion
  dispatch_conclusion=$(wait_for_workflow_by_event \
    "${E2E_TARGET_REPO}" \
    "Dev-Lead Agent" \
    "repository_dispatch" \
    300 \
    "${start_time}") || dispatch_conclusion="timeout"

  log "Fix-ci dispatch conclusion: ${dispatch_conclusion}"

  # ── Assertions ─────────────────────────────────────────────────────────────
  local all_pass=true

  # The relay itself should succeed (ci-relay job exits 0 after dispatching)
  if ! assert_conclusion "${relay_conclusion}" "success" "${SCENARIO_NAME}: ci-relay workflow success"; then
    all_pass=false
  fi

  # The fix-ci dispatch should also succeed (or neutral for dry-run)
  if [[ "${dispatch_conclusion}" != "success" ]] && [[ "${dispatch_conclusion}" != "neutral" ]]; then
    echo "[FAIL] ${SCENARIO_NAME}: fix-ci dispatch conclusion=${dispatch_conclusion} (expected success or neutral)"
    all_pass=false
  else
    echo "[PASS] ${SCENARIO_NAME}: fix-ci dispatch ran with conclusion=${dispatch_conclusion}"
  fi

  # Check for a fix-ci comment on the PR
  local fix_comment
  fix_comment=$(gh api "repos/${E2E_TARGET_REPO}/issues/${PR_NUMBER}/comments" \
    --jq '[.[] | select(.body | contains("dev-lead-fix-ci"))] | length' \
    2>/dev/null || echo "0")
  log "fix-ci comment count on PR: ${fix_comment}"

  # ── Result ─────────────────────────────────────────────────────────────────
  if [[ "${all_pass}" = "true" ]]; then
    log "[PASS] ${SCENARIO_NAME}: CI failure → relay → fix-ci dispatch succeeded"
    record_result "${SCENARIO_NAME}" "PASS" "relay=${relay_conclusion} dispatch=${dispatch_conclusion}"
    exit 0
  else
    err "[FAIL] ${SCENARIO_NAME}: relay=${relay_conclusion} dispatch=${dispatch_conclusion}"
    record_result "${SCENARIO_NAME}" "FAIL" "relay=${relay_conclusion} dispatch=${dispatch_conclusion}"
    exit 1
  fi
}

main "$@"
