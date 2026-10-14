#!/usr/bin/env bats
# Unit tests for the triage-prompt inlining of the SAFETY_CHECKS block
# (issue #305): safety_checks_triage_section [file].
#
# Triage has NO tools, so the pre-computed deterministic safety-check verdicts
# must be inlined into the triage prompt (mirroring ADVISORY_BOT_FEEDBACK and
# DOWNSTREAM_IMPACT). Unlike downstream-impact, safety checks are safety-critical
# and default ON — so the section is emitted unless SAFETY_CHECKS_ENABLED is
# explicitly "false", in which case it emits NOTHING (the triage prompt is
# byte-identical to pre-feature behavior, protecting holdout evals).
#
# Run with: bats tests/test_safety_checks_triage_inline.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/safety-checks.sh"
  STUB_DIR="$(mktemp -d)"
  SC_FILE="$STUB_DIR/safety-checks.txt"

  SC_BLOCK='CI_WEAKENING_DETECTED: true
PROMPT_INJECTION_DETECTED: false
LARGE_PR: false
DESCRIPTION_MISSING: 1
DEPENDENCY_RISK: 0 unpinned

Findings:
  - [blocking] ci-weakening: test skip marker added (tests/foo.test.js:12)'
}

teardown() {
  rm -rf "$STUB_DIR"
}

# ---------------------------------------------------------------------------
# Flag off -> zero output (byte-identical triage prompt)
# ---------------------------------------------------------------------------

@test "emits nothing when the feature flag is explicitly false" {
  printf '%s' "$SC_BLOCK" > "$SC_FILE"
  export SAFETY_CHECKS_ENABLED=false
  run safety_checks_triage_section "$SC_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Default ON -> the block is inlined even when the flag is unset
# ---------------------------------------------------------------------------

@test "inlines the block by default when the flag is unset (default ON)" {
  printf '%s' "$SC_BLOCK" > "$SC_FILE"
  unset SAFETY_CHECKS_ENABLED
  run safety_checks_triage_section "$SC_FILE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "SAFETY_CHECKS"
  echo "$output" | grep -q "CI_WEAKENING_DETECTED: true"
}

@test "inlines the block when the flag is explicitly true" {
  printf '%s' "$SC_BLOCK" > "$SC_FILE"
  export SAFETY_CHECKS_ENABLED=true
  run safety_checks_triage_section "$SC_FILE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PROMPT_INJECTION_DETECTED: false"
  echo "$output" | grep -q "ci-weakening"
}

@test "the inlined section frames the two hard-stops as forced-escalate, never-approve" {
  printf '%s' "$SC_BLOCK" > "$SC_FILE"
  export SAFETY_CHECKS_ENABLED=true
  run safety_checks_triage_section "$SC_FILE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "escalate"
  echo "$output" | grep -qi "never"
}

# ---------------------------------------------------------------------------
# Missing / empty file -> a safe marker, no failure
# ---------------------------------------------------------------------------

@test "treats a missing safety-checks file as absent without failing" {
  export SAFETY_CHECKS_ENABLED=true
  run safety_checks_triage_section "$STUB_DIR/does-not-exist.txt"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "SAFETY_CHECKS"
}

# ---------------------------------------------------------------------------
# Defaults to SAFETY_CHECKS_FILE when no path argument is given
# ---------------------------------------------------------------------------

@test "reads SAFETY_CHECKS_FILE when no path argument is passed" {
  printf '%s' "$SC_BLOCK" > "$SC_FILE"
  export SAFETY_CHECKS_ENABLED=true
  export SAFETY_CHECKS_FILE="$SC_FILE"
  run safety_checks_triage_section
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CI_WEAKENING_DETECTED: true"
}

# ---------------------------------------------------------------------------
# assemble_safety_checks writes the block to a file and exports the path
# ---------------------------------------------------------------------------

@test "assemble writes the block to the out file and exports SAFETY_CHECKS_FILE" {
  local meta='{"changedFiles":1,"additions":1,"deletions":1,"body":""}'
  local diff='diff --git a/a.test.js b/a.test.js
--- a/a.test.js
+++ b/a.test.js
@@ -1,1 +1,1 @@
+it.skip("x", () => {});'
  local out="$STUB_DIR/out.txt"
  run assemble_safety_checks "$meta" "$diff" "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  grep -q "CI_WEAKENING_DETECTED: true" "$out"
}

# ---------------------------------------------------------------------------
# Integration-style: appended to a prompt file, the block is present / absent
# ---------------------------------------------------------------------------

@test "appended to a triage prompt file, the block is present when on and absent when off" {
  printf '%s' "$SC_BLOCK" > "$SC_FILE"
  local prompt_on="$STUB_DIR/triage-on.md"
  local prompt_off="$STUB_DIR/triage-off.md"

  export SAFETY_CHECKS_ENABLED=true
  { printf '# triage\n'; safety_checks_triage_section "$SC_FILE"; } > "$prompt_on"
  grep -q "SAFETY_CHECKS" "$prompt_on"

  export SAFETY_CHECKS_ENABLED=false
  { printf '# triage\n'; safety_checks_triage_section "$SC_FILE"; } > "$prompt_off"
  ! grep -q "SAFETY_CHECKS" "$prompt_off" || false
  # With the flag off the prompt is exactly the pre-feature content.
  [ "$(cat "$prompt_off")" = "$(printf '# triage\n')" ]
}
