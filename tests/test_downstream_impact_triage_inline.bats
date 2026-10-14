#!/usr/bin/env bats
# Unit tests for the triage-prompt inlining of the DOWNSTREAM_IMPACT block
# (issue #752, epic #748): downstream_impact_triage_section [impact_file].
#
# Triage has NO tools, so every enrichment field must be inlined into the
# triage prompt (mirroring ADVISORY_BOT_FEEDBACK). This helper emits the
# DOWNSTREAM_IMPACT section that scripts/review-one-pr.sh appends to
# TRIAGE_PROMPT_FILE. It must:
#   - emit NOTHING when the Story 5 flag (DOWNSTREAM_IMPACT_ENABLED) is off, so
#     the triage prompt is byte-identical to pre-feature behavior;
#   - inline the assembled block when impact is present (flag on);
#   - emit a "(none)" marker (and no consumer list) when the block is "(none)".
#
# Run with: bats tests/test_downstream_impact_triage_inline.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/downstream-impact.sh"
  STUB_DIR="$(mktemp -d)"
  IMPACT_FILE="$STUB_DIR/downstream-impact.txt"

  # A representative non-empty block, shaped like assemble_downstream_impact's output.
  IMPACT_BLOCK='Impacted shared surfaces:
  - .github/workflows/pr-review.yml
Impacted consumers (2, fetching up to 10):
  - petry-projects/alpha (pins .github/workflows/pr-review.yml)
      .github/workflows/caller.yml
  - petry-projects/bravo (pins .github/workflows/pr-review.yml)
      .github/workflows/caller.yml'
}

teardown() {
  rm -rf "$STUB_DIR"
}

# ---------------------------------------------------------------------------
# Flag off -> zero output (byte-identical triage prompt, Story 5 cost cap)
# ---------------------------------------------------------------------------

@test "emits nothing when the feature flag is off" {
  printf '%s' "$IMPACT_BLOCK" > "$IMPACT_FILE"
  unset DOWNSTREAM_IMPACT_ENABLED
  run downstream_impact_triage_section "$IMPACT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emits nothing when the feature flag is explicitly false" {
  printf '%s' "$IMPACT_BLOCK" > "$IMPACT_FILE"
  export DOWNSTREAM_IMPACT_ENABLED=false
  run downstream_impact_triage_section "$IMPACT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Flag on + impact present -> the block is inlined
# ---------------------------------------------------------------------------

@test "inlines the block when impact is present and the flag is on" {
  printf '%s' "$IMPACT_BLOCK" > "$IMPACT_FILE"
  export DOWNSTREAM_IMPACT_ENABLED=true
  run downstream_impact_triage_section "$IMPACT_FILE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "DOWNSTREAM_IMPACT"
  echo "$output" | grep -q ".github/workflows/pr-review.yml"
  echo "$output" | grep -q "petry-projects/alpha"
  echo "$output" | grep -q "petry-projects/bravo"
}

@test "the inlined section labels downstream impact as informational, not auto-escalation" {
  printf '%s' "$IMPACT_BLOCK" > "$IMPACT_FILE"
  export DOWNSTREAM_IMPACT_ENABLED=true
  run downstream_impact_triage_section "$IMPACT_FILE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "informational"
}

# ---------------------------------------------------------------------------
# Flag on + "(none)" -> no consumer list inlined
# ---------------------------------------------------------------------------

@test "shows (none) and omits any consumer list when the block is (none)" {
  printf '%s' "(none)" > "$IMPACT_FILE"
  export DOWNSTREAM_IMPACT_ENABLED=true
  run downstream_impact_triage_section "$IMPACT_FILE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "DOWNSTREAM_IMPACT"
  echo "$output" | grep -q "(none)"
  # No consumer repos or impacted surfaces leaked into the "(none)" case.
  ! echo "$output" | grep -q "petry-projects/"
  ! echo "$output" | grep -q "Impacted shared surfaces"
}

@test "treats a missing impact file as (none) without failing" {
  export DOWNSTREAM_IMPACT_ENABLED=true
  run downstream_impact_triage_section "$STUB_DIR/does-not-exist.txt"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "(none)"
  ! echo "$output" | grep -q "petry-projects/"
}

# ---------------------------------------------------------------------------
# Defaults to DOWNSTREAM_IMPACT_FILE when no path argument is given
# ---------------------------------------------------------------------------

@test "reads DOWNSTREAM_IMPACT_FILE when no path argument is passed" {
  printf '%s' "$IMPACT_BLOCK" > "$IMPACT_FILE"
  export DOWNSTREAM_IMPACT_ENABLED=true
  export DOWNSTREAM_IMPACT_FILE="$IMPACT_FILE"
  run downstream_impact_triage_section
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "petry-projects/alpha"
}

# ---------------------------------------------------------------------------
# Integration-style: the section, appended to a prompt file, contains the block
# ---------------------------------------------------------------------------

@test "appended to a triage prompt file, the block is present for impact and absent for (none)" {
  export DOWNSTREAM_IMPACT_ENABLED=true
  local prompt_present="$STUB_DIR/triage-present.md"
  local prompt_none="$STUB_DIR/triage-none.md"

  printf '%s' "$IMPACT_BLOCK" > "$IMPACT_FILE"
  { printf '# triage\n'; downstream_impact_triage_section "$IMPACT_FILE"; } > "$prompt_present"
  grep -q "petry-projects/alpha" "$prompt_present"

  printf '%s' "(none)" > "$IMPACT_FILE"
  { printf '# triage\n'; downstream_impact_triage_section "$IMPACT_FILE"; } > "$prompt_none"
  ! grep -q "petry-projects/" "$prompt_none"
  grep -q "(none)" "$prompt_none"
}
