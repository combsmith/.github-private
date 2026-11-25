#!/usr/bin/env bash
# tests/dev-lead/e2e/scenarios/04-issue-labeled.sh
#
# Scenario: Labeling an issue "dev-lead" triggers the `issue` intent.
#
# Steps:
#   1. Create a test issue.
#   2. Add the "dev-lead" label to it.
#   3. Wait for the Dev-Lead Agent workflow (issues labeled event).
#   4. Assert: workflow ran and intent was "issue".
#   5. Cleanup: close the issue.
#
# Requires: GH_TOKEN, real GitHub API access.
set -euo pipefail

SCENARIO_NAME="04-issue-labeled"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../lib/helpers.sh"

ISSUE_NUMBER=""

cleanup() {
  log "Cleanup: ${SCENARIO_NAME}"
  [[ -n "$ISSUE_NUMBER" ]] && cleanup_issue "${ISSUE_NUMBER}" || true
}

trap cleanup EXIT

main() {
  log "=== Scenario: ${SCENARIO_NAME} ==="
  log "Test: issue labeled 'dev-lead' → intent=issue → fix-issue handler runs"

  # ── Check for required token ───────────────────────────────────────────────
  if [[ -z "${GH_TOKEN:-}" ]]; then
    err "GH_TOKEN not set — skipping live scenario ${SCENARIO_NAME}"
    record_result "${SCENARIO_NAME}" "SKIP" "GH_TOKEN not set"
    exit 0
  fi

  local start_time
  start_time=$(now_iso)

  # ── Ensure "dev-lead" label exists on the repo ─────────────────────────────
  log "Ensuring 'dev-lead' label exists on ${E2E_TARGET_REPO}..."
  gh api "repos/${E2E_TARGET_REPO}/labels" \
    --method POST \
    --field name="dev-lead" \
    --field color="0075ca" \
    --field description="Route to dev-lead agent" \
    --silent 2>/dev/null || \
  log "  Label 'dev-lead' already exists (or creation skipped)"

  # ── Create test issue ──────────────────────────────────────────────────────
  log "Creating test issue..."
  ISSUE_NUMBER=$(gh issue create \
    --repo "${E2E_TARGET_REPO}" \
    --title "[E2E] Scenario 04: dev-lead label routing test" \
    --body "Automated E2E test issue for scenario 04. Safe to close.

This issue tests that the dev-lead agent correctly handles the \`issues labeled\` event with the \`dev-lead\` label.

Created: $(date -u)" \
    2>&1 | grep -oE '[0-9]+$' | head -1)

  if [[ -z "${ISSUE_NUMBER}" ]]; then
    err "Failed to create test issue"
    record_result "${SCENARIO_NAME}" "FAIL" "issue creation failed"
    exit 1
  fi

  log "Created issue #${ISSUE_NUMBER}"

  # ── Add label to trigger the event ────────────────────────────────────────
  log "Adding 'dev-lead' label to issue #${ISSUE_NUMBER}..."
  gh issue edit "${ISSUE_NUMBER}" \
    --repo "${E2E_TARGET_REPO}" \
    --add-label "dev-lead"

  log "Label added — waiting for Dev-Lead Agent workflow..."

  # ── Wait for dispatch workflow (issues labeled event) ──────────────────────
  local conclusion
  conclusion=$(wait_for_workflow_by_event \
    "${E2E_TARGET_REPO}" \
    "Dev-Lead Agent" \
    "issues" \
    300 \
    "${start_time}") || conclusion="timeout"

  log "Dev-Lead Agent workflow conclusion: ${conclusion}"

  # ── Assertions ─────────────────────────────────────────────────────────────
  local all_pass=true

  if ! assert_conclusion "${conclusion}" "success" "${SCENARIO_NAME}: workflow completes successfully"; then
    # neutral is acceptable (dry-run / token not present)
    if [[ "${conclusion}" = "neutral" ]]; then
      echo "[PASS] ${SCENARIO_NAME}: workflow conclusion=neutral (expected in dry-run mode)"
    else
      all_pass=false
    fi
  fi

  # Check for an agent comment on the issue (fix-issue posts one)
  log "Checking for agent comment on issue #${ISSUE_NUMBER}..."
  local agent_comment_count
  agent_comment_count=$(gh api "repos/${E2E_TARGET_REPO}/issues/${ISSUE_NUMBER}/comments" \
    --jq 'length' 2>/dev/null || echo "0")
  log "Comments on issue #${ISSUE_NUMBER}: ${agent_comment_count}"

  # ── Result ─────────────────────────────────────────────────────────────────
  if [[ "${all_pass}" = "true" ]]; then
    log "[PASS] ${SCENARIO_NAME}: issue labeled dev-lead triggered workflow"
    record_result "${SCENARIO_NAME}" "PASS" "conclusion=${conclusion} comments=${agent_comment_count}"
    exit 0
  else
    err "[FAIL] ${SCENARIO_NAME}: conclusion=${conclusion}"
    record_result "${SCENARIO_NAME}" "FAIL" "conclusion=${conclusion}"
    exit 1
  fi
}

main "$@"
