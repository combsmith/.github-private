#!/usr/bin/env bats
# Regression tests for .github/dependabot.yml compliance.
#
# Guards the invariants checked by the weekly org compliance audit
# to prevent re-filing of missing-*-label findings.
#
# Run with: bats tests/test_dependabot.bats

DEPENDABOT_YML=".github/dependabot.yml"
AUTOMERGE_YML=".github/workflows/dependabot-automerge.yml"

setup() {
  # Run tests from repo root so relative paths resolve correctly.
  cd "$(dirname "$BATS_TEST_FILENAME")/.."
}

@test "dependabot.yml exists" {
  [ -f "$DEPENDABOT_YML" ]
}

@test "dependabot.yml has github-actions ecosystem" {
  grep -qE 'package-ecosystem:[[:space:]]*(\"github-actions\"|'"'"'github-actions'"'"'|github-actions)' "$DEPENDABOT_YML"
}

@test "dependabot.yml has security label (compliance-audit check)" {
  [[ "$(yq '.updates[] | select(.["package-ecosystem"] == "github-actions") | .labels[] | select(. == "security")' "$DEPENDABOT_YML")" == "security" ]]
}

@test "dependabot.yml has dependencies label (compliance-audit check)" {
  [[ "$(yq '.updates[] | select(.["package-ecosystem"] == "github-actions") | .labels[] | select(. == "dependencies")' "$DEPENDABOT_YML")" == "dependencies" ]]
}

@test "dependabot.yml github-actions entry has open-pull-requests-limit: 10" {
  [[ "$(yq '.updates[] | select(.["package-ecosystem"] == "github-actions") | .["open-pull-requests-limit"]' "$DEPENDABOT_YML")" == "10" ]]
}

@test "dependabot.yml schedule is weekly" {
  grep -qE 'interval:[[:space:]]*("weekly"|'"'"'weekly'"'"'|weekly)' "$DEPENDABOT_YML"
}

@test "dependabot-automerge.yml exists" {
  [ -f "$AUTOMERGE_YML" ]
}

@test "dependabot-automerge.yml pins the reusable at @v1 (compliance-audit check)" {
  grep -qE '^\s*uses:[[:space:]]*combsmith/\.github/\.github/workflows/dependabot-automerge-reusable\.yml@v1[[:space:]]*$' "$AUTOMERGE_YML"
}

@test "dependabot-automerge.yml does not reference a non-v1 pin" {
  ! grep -qE 'dependabot-automerge-reusable\.yml@(v1[a-zA-Z0-9._/-]+|[^v]|v[^1])' "$AUTOMERGE_YML"
}

@test "dependabot-automerge.yml triggers on pull_request_target" {
  grep -qE '^\s*pull_request_target:' "$AUTOMERGE_YML"
}
