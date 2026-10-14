#!/usr/bin/env bats
# Unit tests for engine.sh — Gemini model tier assignments, chains, and fallback.
#
# Verifies that gemini-3.8-flash (the preferred flash model, #1777) is wired into
# the speed-first tiers and gemini-3.1-pro-preview is the quality-first tier for the
# gemini engine:
#   triage  → gemini-3.8-flash  (was gemini-3.5-flash)
#   action  → gemini-3.8-flash  (was gemini-3.5-flash)
#   deep    → gemini-3.1-pro-preview (gemini-2.5-pro withdrawn, #1960)
#   audit   → gemini-3.1-pro-preview (gemini-2.5-pro withdrawn, #1960)
#   single  → gemini-3.1-pro-preview (gemini-2.5-pro withdrawn, #1960)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  : > "$GITHUB_ENV"
  : > "$GITHUB_OUTPUT"
  # Sidecars go to this test's directory, not the /tmp every session shares (#2271).
  export DEV_LEAD_SIDECAR_DIR="$BATS_TEST_TMPDIR"

  unset GEMINI_FLASH_MODEL GEMINI_PRO_MODEL
  unset GEMINI_FLASH_MODEL_CHAIN GEMINI_PRO_MODEL_CHAIN
  unset AI_MODELS_GEMINI

  STUB_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN_DIR"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/gemini"
  export PATH="$STUB_BIN_DIR:$PATH"
  export STUB_BIN_DIR

  TEST_PROMPT="$BATS_TEST_TMPDIR/test_prompt"
  echo "test prompt content" > "$TEST_PROMPT"
  export TEST_PROMPT

  MODEL_RECORD="$BATS_TEST_TMPDIR/model_record"
  export STUB_ENGINE_RECORD_MODELS="$MODEL_RECORD"

  export DEV_LEAD_DRY_RUN="false"
}

teardown() {
  unset GEMINI_FLASH_MODEL GEMINI_PRO_MODEL
  unset GEMINI_FLASH_MODEL_CHAIN GEMINI_PRO_MODEL_CHAIN
  unset AI_MODELS_GEMINI
  unset STUB_ENGINE_EXIT_BY_MODEL STUB_ENGINE_RESPONSE_BY_MODEL
  unset STUB_ENGINE_RECORD_MODELS STUB_ENGINE_EXIT STUB_ENGINE_RESPONSE
}

_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT" 2>/dev/null || true
}

# ── Tier default model assignments ───────────────────────────────────────────

@test "gemini-3.8: ENGINE_TRIAGE_MODEL is gemini-3.8-flash by default" {
  _source_engine "gemini"
  [ "$ENGINE_TRIAGE_MODEL" = "gemini-3.8-flash" ]
}

@test "gemini-3.8: ENGINE_ACTION_MODEL is gemini-3.8-flash by default" {
  _source_engine "gemini"
  [ "$ENGINE_ACTION_MODEL" = "gemini-3.8-flash" ]
}

@test "gemini-3.8: ENGINE_DEEP_MODEL is gemini-3.1-pro-preview" {
  _source_engine "gemini"
  [ "$ENGINE_DEEP_MODEL" = "gemini-3.1-pro-preview" ]
}

@test "gemini-3.8: ENGINE_AUDIT_MODEL is gemini-3.1-pro-preview" {
  _source_engine "gemini"
  [ "$ENGINE_AUDIT_MODEL" = "gemini-3.1-pro-preview" ]
}

@test "gemini-3.8: ENGINE_SINGLE_MODEL is gemini-3.1-pro-preview" {
  _source_engine "gemini"
  [ "$ENGINE_SINGLE_MODEL" = "gemini-3.1-pro-preview" ]
}

# ── Fallback chain configuration ──────────────────────────────────────────────

@test "gemini-3.8: the triage chain starts with gemini-3.8-flash" {
  _source_engine "gemini"
  local first
  first="$(ai_models_gemini_chain triage)"
  first="${first%%,*}"
  [ "$first" = "gemini-3.8-flash" ]
}

@test "gemini-3.8: the triage and action chains fall back to gemini-3.1-pro-preview" {
  _source_engine "gemini"
  [[ "$(ai_models_gemini_chain triage)" == *"gemini-3.1-pro-preview"* ]]
  [[ "$(ai_models_gemini_chain action)" == *"gemini-3.1-pro-preview"* ]]
}

@test "gemini-3.8: the deep chain starts with gemini-3.1-pro-preview" {
  _source_engine "gemini"
  local first
  first="$(ai_models_gemini_chain deep)"
  first="${first%%,*}"
  [ "$first" = "gemini-3.1-pro-preview" ]
}

@test "gemini-3.8: the deep, audit and single chains fall back to gemini-3.8-flash" {
  _source_engine "gemini"
  [[ "$(ai_models_gemini_chain deep)" == *"gemini-3.8-flash"* ]]
  [[ "$(ai_models_gemini_chain audit)" == *"gemini-3.8-flash"* ]]
  [[ "$(ai_models_gemini_chain single)" == *"gemini-3.8-flash"* ]]
}

# ── Env var overrides ─────────────────────────────────────────────────────────

@test "gemini-3.8: GEMINI_FLASH_MODEL env var overrides triage model" {
  export GEMINI_FLASH_MODEL="gemini-2.0-flash"
  _source_engine "gemini"
  [ "$ENGINE_TRIAGE_MODEL" = "gemini-2.0-flash" ]
  [ "$ENGINE_ACTION_MODEL" = "gemini-2.0-flash" ]
}

@test "gemini-3.8: GEMINI_PRO_MODEL env var overrides deep model" {
  export GEMINI_PRO_MODEL="gemini-2.0-flash"
  _source_engine "gemini"
  [ "$ENGINE_DEEP_MODEL" = "gemini-2.0-flash" ]
  [ "$ENGINE_AUDIT_MODEL" = "gemini-2.0-flash" ]
}

@test "gemini-3.8: GEMINI_FLASH_MODEL_CHAIN env var override honored" {
  export GEMINI_FLASH_MODEL_CHAIN="gemini-2.0-flash,gemini-2.5-pro"
  _source_engine "gemini"
  [ "$(ai_models_gemini_chain triage)" = "gemini-2.0-flash,gemini-2.5-pro" ]
  [ "$(ai_models_gemini_chain action)" = "gemini-2.0-flash,gemini-2.5-pro" ]
  [ "$ENGINE_TRIAGE_MODEL" = "gemini-2.0-flash" ]
}

# ── Intent dispatch returns correct tier models ───────────────────────────────

@test "gemini-3.8: model_for_intent(human-pr) returns gemini-3.8-flash (triage)" {
  _source_engine "gemini"
  local result
  result="$(model_for_intent "human-pr")"
  [ "$result" = "gemini-3.8-flash" ]
}

@test "gemini-3.8: model_for_intent(fix-reviews) returns gemini-3.8-flash (action)" {
  _source_engine "gemini"
  local result
  result="$(model_for_intent "fix-reviews")"
  [ "$result" = "gemini-3.8-flash" ]
}

@test "gemini-3.8: model_for_intent(fix-issue) returns gemini-3.1-pro-preview (deep)" {
  _source_engine "gemini"
  local result
  result="$(model_for_intent "fix-issue")"
  [ "$result" = "gemini-3.1-pro-preview" ]
}

# ── ENGINE_LABEL reflects new models ─────────────────────────────────────────

@test "gemini-3.8: ENGINE_LABEL contains gemini-3.8-flash" {
  _source_engine "gemini"
  [[ "$ENGINE_LABEL" == *"gemini-3.8-flash"* ]]
}

# ── Copilot engine duck uses gemini-3.8-flash ────────────────────────────────

@test "gemini-3.8: copilot engine duck model is gemini-3.8-flash" {
  _source_engine "copilot"
  [ "$DUCK_ENGINE" = "gemini" ]
  [ "$DUCK_MODEL" = "gemini-3.8-flash" ]
}

# ── _gemini_chain_invoke unit tests ───────────────────────────────────────────

@test "gemini-3.8 chain: first model succeeds → no fallback attempted" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT=0

  run _gemini_chain_invoke "gemini-3.8-flash,gemini-2.5-pro" \
    "$TEST_PROMPT" 30 --approval-mode auto_edit

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MODEL_RECORD")" -eq 1 ]
  grep -q "gemini-3.8-flash" "$MODEL_RECORD"
  ! grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

@test "gemini-3.8 chain: first model rate-limited → falls through to second" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.8-flash=1|gemini-2.5-pro=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.8-flash=429 too many requests|gemini-2.5-pro=pro response"

  run _gemini_chain_invoke "gemini-3.8-flash,gemini-2.5-pro" \
    "$TEST_PROMPT" 30 --approval-mode auto_edit

  [ "$status" -eq 0 ]
  grep -q "gemini-3.8-flash" "$MODEL_RECORD"
  grep -q "gemini-2.5-pro" "$MODEL_RECORD"
  [[ "$output" == *"pro response"* ]]
  [[ "$output" != *"too many requests"* ]]
}

@test "gemini-3.8 chain: all models rate-limited → returns exit 2" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.8-flash=1|gemini-2.5-pro=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.8-flash=quota exceeded|gemini-2.5-pro=quota exceeded"

  run _gemini_chain_invoke "gemini-3.8-flash,gemini-2.5-pro" \
    "$TEST_PROMPT" 30 --approval-mode auto_edit

  [ "$status" -eq 2 ]
  grep -q "gemini-3.8-flash" "$MODEL_RECORD"
  grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

@test "gemini-3.8 chain: non-rate-limit failure propagates immediately without trying next" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.8-flash=1|gemini-2.5-pro=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.8-flash=unexpected internal error|gemini-2.5-pro=should not run"

  run _gemini_chain_invoke "gemini-3.8-flash,gemini-2.5-pro" \
    "$TEST_PROMPT" 30 --approval-mode auto_edit

  [ "$status" -eq 1 ]
  grep -q "gemini-3.8-flash" "$MODEL_RECORD"
  ! grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

@test "gemini-3.8 chain: empty chain → config error (rc=1)" {
  _source_engine "gemini"
  run _gemini_chain_invoke "  ,  ,  " "$TEST_PROMPT" 30 --approval-mode auto_edit
  [ "$status" -eq 1 ]
}

@test "gemini-3.8 chain: throttled warning phrase does NOT match is_rate_limited" {
  _source_engine "gemini"
  run is_rate_limited \
    "::warning::[gemini] model gemini-3.8-flash throttled (rc=1) — trying next in chain"
  [ "$status" -ne 0 ]
}

# ── End-to-end: run_writer uses flash chain on rate-limit ────────────────────

@test "gemini-3.8 writer: gemini-3.8-flash rate-limited → gemini-3.1-pro-preview tried via GEMINI_FLASH_MODEL_CHAIN" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.8-flash=1|gemini-3.1-pro-preview=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.8-flash=too many requests (429)|gemini-3.1-pro-preview=pro result"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  grep -q "gemini-3.8-flash" "$MODEL_RECORD"
  grep -q "gemini-3.1-pro-preview" "$MODEL_RECORD"
}

@test "gemini-3.8 writer: custom GEMINI_FLASH_MODEL_CHAIN env override is honored" {
  _source_engine "gemini"
  export GEMINI_FLASH_MODEL_CHAIN="gemini-2.0-flash,gemini-3.8-flash"
  export STUB_ENGINE_EXIT=0

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  head -1 "$MODEL_RECORD" | grep -q "gemini-2.0-flash"
}

@test "gemini-3.8 writer: both models rate-limited → exit 2 (cross-provider fallback signal)" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.8-flash=1|gemini-3.1-pro-preview=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.8-flash=quota exceeded|gemini-3.1-pro-preview=quota exceeded"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

# ── Non-gemini engines unaffected ────────────────────────────────────────────

@test "gemini-3.8: claude engine unchanged — no gemini model in any tier" {
  _source_engine "claude"
  [[ "$ENGINE_TRIAGE_MODEL" != *"gemini"* ]]
  [[ "$ENGINE_DEEP_MODEL" != *"gemini"* ]]
  [[ "$ENGINE_AUDIT_MODEL" != *"gemini"* ]]
}

@test "gemini-3.8: copilot engine unchanged — all tiers still o4-mini" {
  _source_engine "copilot"
  [ "$ENGINE_AUDIT_MODEL" = "o4-mini" ]
  [ "$ENGINE_TRIAGE_MODEL" = "o4-mini" ]
  [ "$ENGINE_DEEP_MODEL" = "o4-mini" ]
}
