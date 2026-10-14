#!/usr/bin/env bats
# Regression tests for .github/workflows/feature-ideation.yml compliance.
#
# Guards the invariants checked by the weekly org compliance audit
# (check: non-stub-feature-ideation.yml) to prevent re-filing of the
# "reusable not pinned to @v1" finding (#629).
#
# Run with: bats tests/test_feature_ideation.bats

FEATURE_IDEATION_YML=".github/workflows/feature-ideation.yml"

# Canonical reusable + v1 pin from
# combsmith/.github/standards/workflows/feature-ideation.yml
REUSABLE="combsmith/.github/.github/workflows/feature-ideation-reusable.yml"
V1_SHA="897e4dede3518cdd7273b9dc63e607d0d05cbdda"
# The superseded pin the audit flagged (#629).
V2_SHA="376a4fcb1117444595e3e702fa450873d0e54310"

setup() {
  # Run tests from repo root so relative paths resolve correctly.
  cd "$(dirname "$BATS_TEST_FILENAME")/.."
}

@test "feature-ideation.yml exists" {
  [ -f "$FEATURE_IDEATION_YML" ]
}

@test "feature-ideation.yml calls the org reusable workflow" {
  grep -qF "uses: ${REUSABLE}@" "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml pins the reusable to the v1 SHA (compliance-audit check)" {
  grep -qF "uses: ${REUSABLE}@${V1_SHA}" "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml uses: line is annotated # v1" {
  grep -qE "uses: ${REUSABLE}@${V1_SHA}[[:space:]]+# v1" "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml is not pinned to the superseded v2 SHA" {
  [ -f "$FEATURE_IDEATION_YML" ] && ! grep -qF "$V2_SHA" "$FEATURE_IDEATION_YML"
}
