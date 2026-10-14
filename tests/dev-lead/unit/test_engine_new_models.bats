#!/usr/bin/env bats
# Unit tests for engine.sh — Claude model tier assignments and chains.
#
# Verifies that Opus 5.5 (claude-opus-5-5) and Opus 4.8 (claude-opus-4-8) are
# wired into the correct tiers and fallback chains for the claude engine:
#   triage  → haiku-4-5    (unchanged)
#   action  → sonnet-5-5    (#1978, was sonnet-5)
#   deep    → opus-5-5     (#1898, was opus-4-8)
#   audit   → opus-5-5     (#1901, was fable-5, deprecating Fable)
#   single  → opus-5-5     (#1901, was fable-5, deprecating Fable)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  # Sidecars go to this test's directory, not the /tmp every session shares (#2271).
  export DEV_LEAD_SIDECAR_DIR="$BATS_TEST_TMPDIR"

  # Clear any pre-set chain vars from the runner environment so engine.sh
  # defaults are evaluated fresh for every test.
  unset CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN CLAUDE_AUDIT_MODEL_CHAIN
  unset CLAUDE_ACTION_MODEL_CHAIN CLAUDE_SINGLE_MODEL_CHAIN

  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini"
  export PATH="$STUB_BIN_DIR:$PATH"
  export STUB_BIN_DIR

  TEST_PROMPT="$(mktemp)"
  echo "test prompt content" > "$TEST_PROMPT"
  export TEST_PROMPT

  MODEL_RECORD="$(mktemp)"
  export STUB_ENGINE_RECORD_MODELS="$MODEL_RECORD"

  export DEV_LEAD_DRY_RUN="false"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$TEST_PROMPT" "$MODEL_RECORD"
  rm -rf "$STUB_BIN_DIR"
  unset STUB_ENGINE_EXIT_BY_MODEL STUB_ENGINE_RESPONSE_BY_MODEL
  unset STUB_ENGINE_RECORD_MODELS STUB_ENGINE_EXIT STUB_ENGINE_RESPONSE
  unset CLAUDE_ACTION_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN
  unset CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_AUDIT_MODEL_CHAIN CLAUDE_SINGLE_MODEL_CHAIN
}

_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT"
}

# ── Tier default model assignments ───────────────────────────────────────────

@test "new-models: ENGINE_AUDIT_MODEL is claude-opus-5-5 for claude engine (#1901)" {
  _source_engine "claude"
  [ "$ENGINE_AUDIT_MODEL" = "claude-opus-5-5" ]
}

@test "new-models: ENGINE_SINGLE_MODEL is claude-opus-5-5 for claude engine (#1901)" {
  _source_engine "claude"
  [ "$ENGINE_SINGLE_MODEL" = "claude-opus-5-5" ]
}

@test "new-models: ENGINE_DEEP_MODEL is claude-opus-5-5 for claude engine (#1898)" {
  _source_engine "claude"
  [ "$ENGINE_DEEP_MODEL" = "claude-opus-5-5" ]
}

@test "new-models: ENGINE_ACTION_MODEL is claude-sonnet-5-5 (#1978)" {
  _source_engine "claude"
  [ "$ENGINE_ACTION_MODEL" = "claude-sonnet-5-5" ]
}

@test "new-models: ENGINE_TRIAGE_MODEL still claude-haiku-4-5-20251001 (unchanged)" {
  _source_engine "claude"
  [ "$ENGINE_TRIAGE_MODEL" = "claude-haiku-4-5-20251001" ]
}

# ── Fallback chain configuration ──────────────────────────────────────────────

@test "new-models: CLAUDE_AUDIT_MODEL_CHAIN starts with claude-opus-5-5 (#1901)" {
  _source_engine "claude"
  local first
  first="${CLAUDE_AUDIT_MODEL_CHAIN%%,*}"
  first="${first// /}"
  [ "$first" = "claude-opus-5-5" ]
  [[ "$CLAUDE_AUDIT_MODEL_CHAIN" != *"claude-fable-5"* ]]
}

@test "new-models: CLAUDE_AUDIT_MODEL_CHAIN includes claude-opus-4-8 as second element" {
  _source_engine "claude"
  local second
  second="${CLAUDE_AUDIT_MODEL_CHAIN#*,}"
  second="${second%%,*}"
  second="${second// /}"
  [ "$second" = "claude-opus-4-8" ]
}

@test "new-models: CLAUDE_AUDIT_MODEL_CHAIN includes claude-opus-4-7 as final fallback" {
  _source_engine "claude"
  [[ "$CLAUDE_AUDIT_MODEL_CHAIN" == *"claude-opus-4-7"* ]]
}

@test "new-models: CLAUDE_SINGLE_MODEL_CHAIN starts with claude-opus-5-5 (#1901)" {
  _source_engine "claude"
  local first
  first="${CLAUDE_SINGLE_MODEL_CHAIN%%,*}"
  first="${first// /}"
  [ "$first" = "claude-opus-5-5" ]
  [[ "$CLAUDE_SINGLE_MODEL_CHAIN" != *"claude-fable-5"* ]]
}

@test "new-models: CLAUDE_SINGLE_MODEL_CHAIN includes claude-opus-4-8 as second element" {
  _source_engine "claude"
  local second
  second="${CLAUDE_SINGLE_MODEL_CHAIN#*,}"
  second="${second%%,*}"
  second="${second// /}"
  [ "$second" = "claude-opus-4-8" ]
}

@test "new-models: CLAUDE_DEEP_MODEL_CHAIN starts with claude-opus-5-5 (#1898)" {
  _source_engine "claude"
  local first
  first="${CLAUDE_DEEP_MODEL_CHAIN%%,*}"
  first="${first// /}"
  [ "$first" = "claude-opus-5-5" ]
}

@test "new-models: CLAUDE_ACTION_MODEL_CHAIN leads with sonnet-5-5 and falls back to opus-5-5 (not opus-4-8/4-7) — #1978, #1900" {
  _source_engine "claude"
  local first
  first="${CLAUDE_ACTION_MODEL_CHAIN%%,*}"
  first="${first// /}"
  [ "$first" = "claude-sonnet-5-5" ]
  # sonnet-5 is the in-family safety hop between sonnet-5-5 and opus-5-5.
  [[ ",${CLAUDE_ACTION_MODEL_CHAIN// /}," == *",claude-sonnet-5-5,claude-sonnet-5,claude-opus-5-5,"* ]]
  # opus-5-5 is the cross-family safety hop (#1900); opus-4-8 and opus-4-7 must not appear.
  [[ "$CLAUDE_ACTION_MODEL_CHAIN" == *"claude-opus-5-5"* ]]
  [[ "$CLAUDE_ACTION_MODEL_CHAIN" != *"claude-opus-4-8"* ]]
  [[ "$CLAUDE_ACTION_MODEL_CHAIN" != *"claude-opus-4-7"* ]]
}

# ── Intent dispatch returns new tier defaults ─────────────────────────────────

@test "new-models: model_for_intent(fix-issue) returns claude-opus-5-5 (#1898)" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "fix-issue")"
  [ "$result" = "claude-opus-5-5" ]
}

@test "new-models: model_for_intent(human) returns claude-opus-5-5 (#1898)" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "human")"
  [ "$result" = "claude-opus-5-5" ]
}

@test "new-models: model_for_intent(fix-reviews) returns claude-sonnet-5-5 (#1978)" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "fix-reviews")"
  [ "$result" = "claude-sonnet-5-5" ]
}

# ── Chain fallback behaviour with new models ──────────────────────────────────

@test "new-models: audit opus-5-5 rate-limited → opus-4-8 tried (#1901)" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT_BY_MODEL="claude-opus-5-5=1|claude-opus-4-8=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-opus-5-5=hit your limit|claude-opus-4-8=audit ok"

  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "audit"

  [ "$status" -eq 0 ]
  grep -q "claude-opus-5-5" "$MODEL_RECORD"
  grep -q "claude-opus-4-8" "$MODEL_RECORD"
  [[ "$output" == *"audit ok"* ]]
  [[ "$output" != *"hit your limit"* ]]
}

@test "new-models: audit chain fully exhausted → exit 2 (#1901)" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT_BY_MODEL="claude-opus-5-5=1|claude-opus-4-8=1|claude-opus-4-7=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-opus-5-5=429 too many|claude-opus-4-8=429 too many|claude-opus-4-7=429 too many"

  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "audit"

  [ "$status" -eq 2 ]
  grep -q "claude-opus-5-5" "$MODEL_RECORD"
  grep -q "claude-opus-4-8" "$MODEL_RECORD"
  grep -q "claude-opus-4-7" "$MODEL_RECORD"
}

@test "new-models: deep opus-5-5 rate-limited → opus-4-8 safety hop tried (#1957)" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT_BY_MODEL="claude-opus-5-5=1|claude-opus-4-8=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-opus-5-5=quota exceeded|claude-opus-4-8=deep result ok"

  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"

  [ "$status" -eq 0 ]
  grep -q "claude-opus-5-5" "$MODEL_RECORD"
  grep -q "claude-opus-4-8" "$MODEL_RECORD"
}

@test "new-models: action chain sonnet rate-limited → opus-5-5 tried (not opus-4-8/4-7)" {
  _source_engine "claude"
  # Both sonnet hops (sonnet-5-5 primary, sonnet-5 safety) throttle so the walk
  # reaches the opus-5-5 cross-family hop (#1978, #1900).
  export STUB_ENGINE_EXIT_BY_MODEL="claude-sonnet-5-5=1|claude-sonnet-5=1|claude-opus-5-5=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-sonnet-5-5=too many requests|claude-sonnet-5=too many requests|claude-opus-5-5=action done"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  grep -q "claude-opus-5-5" "$MODEL_RECORD"
  ! grep -q "claude-opus-4-8" "$MODEL_RECORD" || false
  ! grep -q "claude-opus-4-7" "$MODEL_RECORD"
}

@test "new-models: passing tier default opus-5-5 expands to full deep chain on rate-limit (#1898)" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT_BY_MODEL="claude-opus-5-5=1|claude-opus-4-8=1|claude-sonnet-5-5=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-opus-5-5=429 too many|claude-opus-4-8=429 too many|claude-sonnet-5-5=ok"

  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"

  [ "$status" -eq 0 ]
  grep -q "claude-opus-5-5" "$MODEL_RECORD"
  grep -q "claude-opus-4-8" "$MODEL_RECORD"
  grep -q "claude-sonnet-5-5" "$MODEL_RECORD"
}

# ── Non-claude engines unaffected ─────────────────────────────────────────────

@test "new-models: gemini engine unchanged — no claude model in any tier" {
  _source_engine "gemini"
  [[ "$ENGINE_AUDIT_MODEL" != *"claude"* ]]
  [[ "$ENGINE_DEEP_MODEL" != *"claude"* ]]
  [[ "$ENGINE_SINGLE_MODEL" != *"claude"* ]]
}

@test "new-models: copilot engine unchanged — all tiers still o4-mini" {
  _source_engine "copilot"
  [ "$ENGINE_AUDIT_MODEL" = "o4-mini" ]
  [ "$ENGINE_SINGLE_MODEL" = "o4-mini" ]
  [ "$ENGINE_DEEP_MODEL" = "o4-mini" ]
}
