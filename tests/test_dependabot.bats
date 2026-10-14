#!/usr/bin/env bats
# Regression tests for .github/dependabot.yml compliance.
#
# Guards the invariants checked by the weekly org compliance audit
# to prevent re-filing of missing-*-label findings.
#
# Run with: bats tests/test_dependabot.bats

DEPENDABOT_YML=".github/dependabot.yml"
AUTOMERGE_YML=".github/workflows/dependabot-automerge.yml"
# This repo (.github-private) is the `next` ring tier (epic #495), so its stub
# pins the dependabot-automerge/next channel rather than the former @v1 SHA
# (#870). The org compliance audit is ring-aware (combsmith/.github#529).
AUTOMERGE_CHANNEL="dependabot-automerge/next"

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

@test "dependabot-automerge.yml pins the reusable to the next ring channel (compliance-audit check)" {
  grep -qE "^[[:space:]]*uses:[[:space:]]*combsmith/\.github/\.github/workflows/dependabot-automerge-reusable\.yml@${AUTOMERGE_CHANNEL}[[:space:]]*\$" "$AUTOMERGE_YML"
}

@test "dependabot-automerge.yml does not reference an off-channel pin" {
  # Reject the pre-ring @vN pins, raw SHAs, and any non-next ring channel
  # (stable/ring0/ring1); only dependabot-automerge/next is acceptable here.
  ! grep -qE 'dependabot-automerge-reusable\.yml@(v[0-9]|[0-9a-f]{7,}|[a-z-]+/(stable|ring[0-9]))' "$AUTOMERGE_YML"
}

@test "dependabot-automerge.yml triggers on pull_request_target" {
  grep -qE '^\s*pull_request_target:' "$AUTOMERGE_YML"
}
