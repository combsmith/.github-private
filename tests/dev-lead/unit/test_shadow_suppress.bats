#!/usr/bin/env bats
# Unit tests for scripts/lib/shadow-suppress.sh (#1713 split 1/2).
#
# shadow_mode_active() is the fail-closed predicate that decides whether the
# lane must suppress all PR output. shadow_apply_suppression() turns an active
# shadow run into the already-proven "post nothing" state by forcing
# DEV_LEAD_DRY_RUN=true and recording output to a file instead of the PR.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/shadow-suppress.sh"

setup() {
  # Sourced fresh per test so exports don't leak across cases.
  unset DEV_LEAD_SHADOW_MODE DEV_LEAD_DRY_RUN
  # $BATS_TEST_TMPDIR is unique per test and auto-cleaned on exit/failure, so the
  # path starts absent (absence-before, presence-after = was written) with no
  # manual mktemp/rm bookkeeping.
  SHADOW_OUTPUT_FILE="$BATS_TEST_TMPDIR/shadow-output.txt"; export SHADOW_OUTPUT_FILE
  # shellcheck source=/dev/null
  source "$LIB"
}

# ── shadow_mode_active() truth table ─────────────────────────────────────────
# Recognized-falsy ⇒ inactive (rc 1 ⇒ post, today's behaviour). AC#2.

@test "shadow: absent env → inactive (post as today)" {
  unset DEV_LEAD_SHADOW_MODE
  run shadow_mode_active
  [ "$status" -eq 1 ]
}

@test "shadow: false → inactive (post as today)" {
  export DEV_LEAD_SHADOW_MODE="false"
  run shadow_mode_active
  [ "$status" -eq 1 ]
}

@test "shadow: 0/no/off/empty → inactive (post as today)" {
  for v in "0" "no" "off" ""; do
    export DEV_LEAD_SHADOW_MODE="$v"
    run shadow_mode_active
    [ "$status" -eq 1 ]
  done
}

@test "shadow: FALSE/False (any case) → inactive" {
  for v in "FALSE" "False" "OFF" "No"; do
    export DEV_LEAD_SHADOW_MODE="$v"
    run shadow_mode_active
    [ "$status" -eq 1 ]
  done
}

# Anything else ⇒ active (rc 0 ⇒ suppress). AC#3 + fail-closed AC#4.

@test "shadow: true → active (suppress)" {
  export DEV_LEAD_SHADOW_MODE="true"
  run shadow_mode_active
  [ "$status" -eq 0 ]
}

@test "shadow: TRUE/True (any case) → active (suppress)" {
  for v in "TRUE" "True" "1" "yes" "on"; do
    export DEV_LEAD_SHADOW_MODE="$v"
    run shadow_mode_active
    [ "$status" -eq 0 ]
  done
}

@test "shadow: undetermined garbage value → active (fail-closed suppress)" {
  # AC#4: if the run cannot determine shadow mode, it suppresses.
  for v in "maybe" "yes-please" "tru3" "??" "unknown"; do
    export DEV_LEAD_SHADOW_MODE="$v"
    run shadow_mode_active
    [ "$status" -eq 0 ]
  done
}

# ── shadow_apply_suppression() ───────────────────────────────────────────────

@test "shadow: apply when inactive → does NOT force dry-run, no output file" {
  export DEV_LEAD_SHADOW_MODE="false"
  export DEV_LEAD_DRY_RUN="false"
  shadow_apply_suppression
  [ "$DEV_LEAD_DRY_RUN" = "false" ]
  [ ! -f "$SHADOW_OUTPUT_FILE" ]
}

@test "shadow: apply when active → forces DEV_LEAD_DRY_RUN=true" {
  export DEV_LEAD_SHADOW_MODE="true"
  export DEV_LEAD_DRY_RUN="false"
  shadow_apply_suppression
  [ "$DEV_LEAD_DRY_RUN" = "true" ]
}

@test "shadow: apply when active → normalizes DEV_LEAD_SHADOW_MODE to canonical true" {
  export DEV_LEAD_SHADOW_MODE="YES"
  shadow_apply_suppression
  [ "$DEV_LEAD_SHADOW_MODE" = "true" ]
}

@test "shadow: apply when active → records to SHADOW_OUTPUT_FILE (routed off the PR)" {
  export DEV_LEAD_SHADOW_MODE="true"
  shadow_apply_suppression
  [ -f "$SHADOW_OUTPUT_FILE" ]
  [ -s "$SHADOW_OUTPUT_FILE" ]
}

@test "shadow: apply when active → emits a ::notice:: (visible in run log)" {
  export DEV_LEAD_SHADOW_MODE="true"
  run shadow_apply_suppression
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"* ]]
  [[ "$output" == *"shadow"* ]]
}

@test "shadow: apply is idempotent (second call keeps dry-run true, no error)" {
  export DEV_LEAD_SHADOW_MODE="true"
  shadow_apply_suppression
  shadow_apply_suppression
  [ "$DEV_LEAD_DRY_RUN" = "true" ]
  [ "$DEV_LEAD_SHADOW_MODE" = "true" ]
}
