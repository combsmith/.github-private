#!/usr/bin/env bats
# Unit tests for scripts/lib/resolution-integrity.sh (#1609, slice 1 of 2).
#
# The #1567/#1604 fix moved the evidence bar onto the `status=applied` claim only
# — it does NOT gate thread resolution. On petry-projects/.github#1024 all 18 open
# threads (including a Critical unmatched-brace finding) went resolved between
# 14:00Z and 14:03Z with NO commit at all: head stayed at 30375c5c. `ri_may_resolve`
# is the pure predicate that makes that resolution impossible — it fails closed
# unless the head SHA actually moved (non-empty before, non-empty after, and they
# differ). Slice 2 (#1617) wires it into the resolve_* call sites; this slice is
# the exhaustively-unit-testable predicate only.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/resolution-integrity.sh"

setup() {
  # shellcheck source=scripts/lib/resolution-integrity.sh
  source "$LIB"
}

# ---------------------------------------------------------------------------
# Sourcing safety
# ---------------------------------------------------------------------------

@test "resolution-integrity.sh is safe to source under set -euo pipefail" {
  run bash -c "set -euo pipefail; source '$LIB'"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "ri_may_resolve is declared exactly once (no #1485 duplicate class)" {
  run grep -E -c '^\s*ri_may_resolve\s*\(\)' "$LIB"
  [[ "$status" -eq 0 ]]
  [[ "$output" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# ri_may_resolve truth table — fail closed
# ---------------------------------------------------------------------------

@test "ri_may_resolve: both empty -> deny" {
  run ri_may_resolve "" ""
  [[ "$status" -ne 0 ]]
  [[ -z "$output" ]]
}

@test "ri_may_resolve: before empty -> deny" {
  run ri_may_resolve "" "30375c5c"
  [[ "$status" -ne 0 ]]
  [[ -z "$output" ]]
}

@test "ri_may_resolve: after empty -> deny" {
  run ri_may_resolve "30375c5c" ""
  [[ "$status" -ne 0 ]]
  [[ -z "$output" ]]
}

@test "ri_may_resolve: equal SHAs -> deny (the #1024 no-commit vector)" {
  run ri_may_resolve "30375c5c" "30375c5c"
  [[ "$status" -ne 0 ]]
  [[ -z "$output" ]]
}

@test "ri_may_resolve: differing non-empty SHAs -> allow" {
  run ri_may_resolve "30375c5c" "9b3bc2b0"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}
