#!/usr/bin/env bats
# Unit tests for scripts/lib/push-protection.sh
#
# Run with: bats tests/test_push_protection.bats
# Install bats: https://github.com/bats-core/bats-core

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/push-protection.sh"
  # Capture API calls via a temp file so cross-subshell checks work.
  GH_LOG="$(mktemp)"
  gh() { echo "$*" >> "$GH_LOG"; }
  export -f gh
  export GH_LOG
  unset REPO
  unset DEV_LEAD_DRY_RUN
}

teardown() {
  rm -f "${GH_LOG:-}"
}

# ---------------------------------------------------------------------------
# PP_REQUIRED_SA_SETTINGS — the array must include every required key
# ---------------------------------------------------------------------------

@test "PP_REQUIRED_SA_SETTINGS includes secret_scanning" {
  [[ " ${PP_REQUIRED_SA_SETTINGS[*]} " == *" secret_scanning "* ]]
}

@test "PP_REQUIRED_SA_SETTINGS includes secret_scanning_push_protection" {
  [[ " ${PP_REQUIRED_SA_SETTINGS[*]} " == *" secret_scanning_push_protection "* ]]
}

@test "PP_REQUIRED_SA_SETTINGS includes secret_scanning_ai_detection" {
  [[ " ${PP_REQUIRED_SA_SETTINGS[*]} " == *" secret_scanning_ai_detection "* ]]
}

@test "PP_REQUIRED_SA_SETTINGS includes secret_scanning_non_provider_patterns" {
  [[ " ${PP_REQUIRED_SA_SETTINGS[*]} " == *" secret_scanning_non_provider_patterns "* ]]
}

@test "PP_REQUIRED_SA_SETTINGS includes dependabot_security_updates" {
  [[ " ${PP_REQUIRED_SA_SETTINGS[*]} " == *" dependabot_security_updates "* ]]
}

# ---------------------------------------------------------------------------
# Drift guard (#1133): the enforced key set must stay in lock-step with the org
# standard — petry-projects/.github → standards/push-protection.md (the
# security_and_analysis table). This repo's lean key list and .github's larger
# structured apply/audit list are purpose-built variants of the SAME standard
# (kept separate on purpose, epic #613), so an "includes" test per key is not
# enough: adding or dropping a key here without updating the standard would let a
# repo sync clean while missing (or over-asserting) a required security setting.
# This asserts the EXACT set, catching both additions and removals.
# ---------------------------------------------------------------------------
@test "PP_REQUIRED_SA_SETTINGS matches the canonical standard set exactly (no drift)" {
  # Canonical keys per standards/push-protection.md. Update BOTH together.
  local expected="dependabot_security_updates secret_scanning secret_scanning_ai_detection secret_scanning_non_provider_patterns secret_scanning_push_protection"
  local actual
  actual="$(printf '%s\n' "${PP_REQUIRED_SA_SETTINGS[@]}" | sort | tr '\n' ' ' | sed 's/ $//')"
  [ "$actual" = "$expected" ]
}

# ---------------------------------------------------------------------------
# pp_apply_security_and_analysis — dry-run mode
# ---------------------------------------------------------------------------

@test "dry-run skips gh api call" {
  export DEV_LEAD_DRY_RUN=true
  export REPO="owner/repo"
  run pp_apply_security_and_analysis
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "dry-run prints what it would do" {
  export DEV_LEAD_DRY_RUN=true
  export REPO="owner/repo"
  run pp_apply_security_and_analysis
  [[ "$output" == *"dry-run"* ]]
}

# ---------------------------------------------------------------------------
# pp_apply_security_and_analysis — live mode
# ---------------------------------------------------------------------------

@test "live mode calls gh api PATCH for the repo" {
  export DEV_LEAD_DRY_RUN=false
  export REPO="owner/repo"
  run pp_apply_security_and_analysis
  [ "$status" -eq 0 ]
  [ -s "$GH_LOG" ]
  grep -q "api" "$GH_LOG"
  grep -q "PATCH" "$GH_LOG"
  grep -q "owner/repo" "$GH_LOG"
}

@test "live mode PUTs vulnerability-alerts as prerequisite before PATCH loop" {
  export DEV_LEAD_DRY_RUN=false
  export REPO="owner/repo"
  run pp_apply_security_and_analysis
  [ "$status" -eq 0 ]
  grep -q "vulnerability-alerts" "$GH_LOG"
}

@test "live mode errors when REPO is unset" {
  export DEV_LEAD_DRY_RUN=false
  unset REPO
  run pp_apply_security_and_analysis
  [ "$status" -ne 0 ]
}

@test "live mode makes one PATCH call per required setting" {
  export DEV_LEAD_DRY_RUN=false
  export REPO="owner/repo"
  gh() {
    local stdin_body=""
    [ ! -t 0 ] && stdin_body=$(cat)
    printf '%s BODY=%s\n' "$*" "$stdin_body" >> "$GH_LOG"
  }
  export -f gh
  run pp_apply_security_and_analysis
  [ "$status" -eq 0 ]
  local patch_count
  patch_count=$(grep -c "PATCH" "$GH_LOG")
  [ "$patch_count" -eq "${#PP_REQUIRED_SA_SETTINGS[@]}" ]
}

@test "live mode continues applying remaining settings after one PATCH failure" {
  export DEV_LEAD_DRY_RUN=false
  export REPO="owner/repo"
  export FAIL_KEY="${PP_REQUIRED_SA_SETTINGS[0]}"
  gh() {
    local stdin_body=""
    [ ! -t 0 ] && stdin_body=$(cat)
    printf '%s BODY=%s\n' "$*" "$stdin_body" >> "$GH_LOG"
    echo "$stdin_body" | grep -q "\"${FAIL_KEY}\"" && return 1
    return 0
  }
  export -f gh
  run pp_apply_security_and_analysis
  # All settings should be attempted even though the first one fails
  local patch_count
  patch_count=$(grep -c "PATCH" "$GH_LOG")
  [ "$patch_count" -eq "${#PP_REQUIRED_SA_SETTINGS[@]}" ]
}

@test "live mode returns 0 when some PATCH calls fail (partial failure is non-fatal)" {
  export DEV_LEAD_DRY_RUN=false
  export REPO="owner/repo"
  export FAIL_KEY="${PP_REQUIRED_SA_SETTINGS[0]}"
  gh() {
    local stdin_body=""
    [ ! -t 0 ] && stdin_body=$(cat)
    printf '%s BODY=%s\n' "$*" "$stdin_body" >> "$GH_LOG"
    echo "$stdin_body" | grep -q "\"${FAIL_KEY}\"" && return 1
    return 0
  }
  export -f gh
  run pp_apply_security_and_analysis
  # A 422 for one unavailable setting (e.g. secret_scanning_ai_detection without GHAS)
  # must not abort callers running under set -euo pipefail; exit code must be 0.
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# secret_scan_ci_job_present — ci.yml must use gitleaks/gitleaks-action
# (mirrors the org compliance check in petry-projects/.github/standards/
# push-protection.md#compliance-audit-checks)
# ---------------------------------------------------------------------------

@test "ci.yml secret-scan job uses gitleaks/gitleaks-action" {
  local ci_yaml
  ci_yaml="$(dirname "$BATS_TEST_FILENAME")/../.github/workflows/ci.yml"
  grep -qE "uses:[[:space:]]*['\"]?gitleaks/gitleaks-action" "$ci_yaml"
}

@test "ci.yml secret-scan job has security-events write permission" {
  local ci_yaml
  ci_yaml="$(dirname "$BATS_TEST_FILENAME")/../.github/workflows/ci.yml"
  grep -qE "security-events:[[:space:]]*['\"]?write['\"]?" "$ci_yaml"
}
