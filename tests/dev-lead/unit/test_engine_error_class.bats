#!/usr/bin/env bats
# Unit tests for engine.sh — honest classification of failed Claude chain hops (#1957).
#
# A failed `claude --print --output-format json` call prints an envelope that
# names the model and carries a "usage" object. The old "claude.*usage" clause
# in _rate_limit_pattern matched every such envelope, so a 404 unknown model or
# a 400 bad request was reported as throttling and silently skipped. These tests
# pin the replacement: api_error_status decides, the hop's reason is logged, and
# the chain only signals the cross-provider fallback (exit 2) when its last hop
# was genuinely throttled.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  unset CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN CLAUDE_AUDIT_MODEL_CHAIN
  unset CLAUDE_ACTION_MODEL_CHAIN CLAUDE_SINGLE_MODEL_CHAIN

  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  chmod +x "$STUB_BIN_DIR/claude"
  export PATH="$STUB_BIN_DIR:$PATH"

  TEST_PROMPT="$(mktemp)"
  echo "test prompt content" > "$TEST_PROMPT"

  MODEL_RECORD="$(mktemp)"
  export STUB_ENGINE_RECORD_MODELS="$MODEL_RECORD"

  # JSON-usage mode (what pr-review runs in production): the chain asks for
  # --output-format json whenever TOKEN_LOG_FILE is set.
  export TOKEN_LOG_FILE="$(mktemp)"
  export CLAUDE_CHAIN_HOP_LOG="$(mktemp -d)/hops.log"
  export DEV_LEAD_DRY_RUN="false"

  export REVIEW_ENGINE="claude"
  source "$ENGINE_SCRIPT"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$TEST_PROMPT" "$MODEL_RECORD" "${TOKEN_LOG_FILE:-}"
  rm -rf "$STUB_BIN_DIR"
  if [ -n "${CLAUDE_CHAIN_HOP_LOG:-}" ]; then
    rm -rf "$(dirname "$CLAUDE_CHAIN_HOP_LOG")"
  fi
  unset STUB_ENGINE_EXIT_BY_MODEL STUB_ENGINE_RESPONSE_BY_MODEL STUB_CLAUDE_ERROR_STATUS_BY_MODEL
  unset STUB_ENGINE_RECORD_MODELS TOKEN_LOG_FILE CLAUDE_CHAIN_HOP_LOG
}

# ── _rate_limit_pattern no longer matches every JSON envelope ─────────────────

@test "pattern: a failed-call JSON envelope (model name + usage) is NOT a rate limit" {
  run is_rate_limited '{"type":"result","is_error":true,"api_error_status":404,"model":"claude-sonnet-5-0","result":"There'"'"'s an issue with the selected model","usage":{"input_tokens":0,"output_tokens":0}}'
  [ "$status" -eq 1 ]
}

@test "pattern: genuine Claude caps are still rate limits" {
  run is_rate_limited "Claude AI usage limit reached|1759000000"
  [ "$status" -eq 0 ]
  run is_rate_limited "You've hit your limit · resets 5pm (UTC)"
  [ "$status" -eq 0 ]
}

# ── Chain behavior per api_error_status ───────────────────────────────────────

@test "chain: 404 unknown model → labelled unavailable, next hop tried, not throttled" {
  export STUB_ENGINE_EXIT_BY_MODEL="claude-sonnet-5-0=1|claude-opus-4-8=0"
  export STUB_CLAUDE_ERROR_STATUS_BY_MODEL="claude-sonnet-5-0=404"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-sonnet-5-0=There's an issue with the selected model (claude-sonnet-5-0). It may not exist or you may not have access to it.|claude-opus-4-8=opus answered"

  run _claude_chain_invoke "claude-sonnet-5-0,claude-opus-4-8" "$TEST_PROMPT" 30

  [ "$status" -eq 0 ]
  [[ "$output" == *"opus answered"* ]]
  [[ "$output" == *"claude-sonnet-5-0 unavailable (HTTP 404"* ]]
  [[ "$output" != *"throttled"* ]]
  grep -q "claude-opus-4-8" "$MODEL_RECORD"
}

@test "chain: 400 invalid request → labelled rejected, next hop tried" {
  export STUB_ENGINE_EXIT_BY_MODEL="claude-opus-5-5=1|claude-opus-4-8=0"
  export STUB_CLAUDE_ERROR_STATUS_BY_MODEL="claude-opus-5-5=400"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-opus-5-5=thinking.type.disabled is not supported for this model|claude-opus-4-8=deep ok"

  run _claude_chain_invoke "claude-opus-5-5,claude-opus-4-8" "$TEST_PROMPT" 30

  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-opus-5-5 rejected the request (HTTP 400)"* ]]
  [[ "$output" != *"throttled"* ]]
  [[ "$output" == *"deep ok"* ]]
}

@test "chain: 5xx server error → next hop tried" {
  export STUB_ENGINE_EXIT_BY_MODEL="claude-opus-5-5=1|claude-opus-4-8=0"
  export STUB_CLAUDE_ERROR_STATUS_BY_MODEL="claude-opus-5-5=500"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-opus-5-5=Internal server error|claude-opus-4-8=deep ok"

  run _claude_chain_invoke "claude-opus-5-5,claude-opus-4-8" "$TEST_PROMPT" 30

  [ "$status" -eq 0 ]
  [[ "$output" == *"API server error (HTTP 5xx)"* ]]
  [[ "$output" == *"deep ok"* ]]
}

@test "chain: real 429 on every hop → throttled and exit 2 (cross-provider signal)" {
  export STUB_ENGINE_EXIT_BY_MODEL="claude-opus-5-5=1|claude-opus-4-8=1"
  export STUB_CLAUDE_ERROR_STATUS_BY_MODEL="claude-opus-5-5=429|claude-opus-4-8=429"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-opus-5-5=Request rejected|claude-opus-4-8=Request rejected"

  run _claude_chain_invoke "claude-opus-5-5,claude-opus-4-8" "$TEST_PROMPT" 30

  [ "$status" -eq 2 ]
  [[ "$output" == *"claude-opus-5-5 throttled"* ]]
}

@test "chain: every hop 404 → honest failure (exit 1), not the rate-limit exit 2" {
  export STUB_ENGINE_EXIT_BY_MODEL="claude-a=1|claude-b=1"
  export STUB_CLAUDE_ERROR_STATUS_BY_MODEL="claude-a=404|claude-b=404"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-a=no such model|claude-b=no such model"

  run _claude_chain_invoke "claude-a,claude-b" "$TEST_PROMPT" 30

  [ "$status" -eq 1 ]
  grep -q "claude-b" "$MODEL_RECORD"
}

@test "chain: throttled hop then a 404 last hop → exit 1 (the last hop decides)" {
  export STUB_ENGINE_EXIT_BY_MODEL="claude-a=1|claude-b=1"
  export STUB_CLAUDE_ERROR_STATUS_BY_MODEL="claude-a=429|claude-b=404"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-a=Request rejected|claude-b=no such model"

  run _claude_chain_invoke "claude-a,claude-b" "$TEST_PROMPT" 30

  [ "$status" -eq 1 ]
}

@test "chain: 401 auth error → propagates immediately without trying the next hop" {
  export STUB_ENGINE_EXIT_BY_MODEL="claude-a=1|claude-b=0"
  export STUB_CLAUDE_ERROR_STATUS_BY_MODEL="claude-a=401"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-a=invalid x-api-key|claude-b=should not run"

  run _claude_chain_invoke "claude-a,claude-b" "$TEST_PROMPT" 30

  [ "$status" -eq 1 ]
  ! grep -q "claude-b" "$MODEL_RECORD"
}

@test "chain: is_error envelope without a status falls back to scanning .result only" {
  export STUB_ENGINE_EXIT_BY_MODEL="claude-a=1|claude-b=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-a=You've hit your limit · resets 5pm (UTC)|claude-b=ok"
  # No STUB_CLAUDE_ERROR_STATUS_BY_MODEL: the stub prints a plain success-shaped
  # envelope whose .result carries the cap message, with a nonzero exit.

  run _claude_chain_invoke "claude-a,claude-b" "$TEST_PROMPT" 30

  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-a throttled"* ]]
}

# ── Hop log keeps each failed hop's real error ────────────────────────────────

@test "hop log: a skipped hop's API message is kept, keyed by model and class" {
  export STUB_ENGINE_EXIT_BY_MODEL="claude-opus-5-5=1|claude-opus-4-8=0"
  export STUB_CLAUDE_ERROR_STATUS_BY_MODEL="claude-opus-5-5=400"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-opus-5-5=budget_tokens is not supported on this model|claude-opus-4-8=ok"

  run _claude_chain_invoke "claude-opus-5-5,claude-opus-4-8" "$TEST_PROMPT" 30

  [ "$status" -eq 0 ]
  grep -q "model=claude-opus-5-5 rc=1 class=invalid_request" "$CLAUDE_CHAIN_HOP_LOG"
  grep -q "budget_tokens is not supported on this model" "$CLAUDE_CHAIN_HOP_LOG"
  # The winning hop is not logged as a failure.
  ! grep -q "model=claude-opus-4-8" "$CLAUDE_CHAIN_HOP_LOG"
}

@test "hop log: only the envelope's error fields are kept, with secrets redacted" {
  # Dummy token assembled at runtime so no token-shaped literal is committed
  # (the gitleaks secret scan would flag one).
  local _tok="ghp_""abcdefghijklmnopqrstuvwxyz0123456789"
  export STUB_ENGINE_EXIT_BY_MODEL="claude-a=1|claude-b=0"
  export STUB_CLAUDE_ERROR_STATUS_BY_MODEL="claude-a=400"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-a=bad request; echoed ${_tok}|claude-b=ok"

  run _claude_chain_invoke "claude-a,claude-b" "$TEST_PROMPT" 30

  [ "$status" -eq 0 ]
  grep -q '"api_error_status":400' "$CLAUDE_CHAIN_HOP_LOG"
  grep -q "REDACTED-GH-TOKEN" "$CLAUDE_CHAIN_HOP_LOG"
  ! grep -qF "$_tok" "$CLAUDE_CHAIN_HOP_LOG" || false
  # Envelope metadata beyond the error fields (model, usage) is not copied.
  ! grep -q '"usage"' "$CLAUDE_CHAIN_HOP_LOG"
}

@test "hop log: non-JSON stdout is omitted, never copied raw" {
  # Text mode (no TOKEN_LOG_FILE): stdout is a plain transcript, not an envelope.
  unset TOKEN_LOG_FILE
  export STUB_ENGINE_EXIT_BY_MODEL="claude-a=1|claude-b=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-a=429 too many requests; transcript line|claude-b=ok"

  run _claude_chain_invoke "claude-a,claude-b" "$TEST_PROMPT" 30

  [ "$status" -eq 0 ]
  grep -q "model=claude-a rc=1 class=rate_limit" "$CLAUDE_CHAIN_HOP_LOG"
  grep -q "(non-JSON stdout omitted)" "$CLAUDE_CHAIN_HOP_LOG"
  ! grep -q "transcript line" "$CLAUDE_CHAIN_HOP_LOG"
}

@test "hop log: without redact_secrets only the header line is written" {
  unset -f redact_secrets
  export STUB_ENGINE_EXIT_BY_MODEL="claude-a=1|claude-b=0"
  export STUB_CLAUDE_ERROR_STATUS_BY_MODEL="claude-a=400"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-a=some error text|claude-b=ok"

  run _claude_chain_invoke "claude-a,claude-b" "$TEST_PROMPT" 30

  [ "$status" -eq 0 ]
  grep -q "model=claude-a rc=1 class=invalid_request" "$CLAUDE_CHAIN_HOP_LOG"
  ! grep -q "some error text" "$CLAUDE_CHAIN_HOP_LOG"
}

@test "hop log: off when neither CLAUDE_CHAIN_HOP_LOG nor RUNNER_TEMP is set" {
  local _dir
  _dir="$(dirname "$CLAUDE_CHAIN_HOP_LOG")"
  unset CLAUDE_CHAIN_HOP_LOG RUNNER_TEMP
  export STUB_ENGINE_EXIT_BY_MODEL="claude-a=1|claude-b=0"
  export STUB_CLAUDE_ERROR_STATUS_BY_MODEL="claude-a=404"

  run _claude_chain_invoke "claude-a,claude-b" "$TEST_PROMPT" 30

  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$_dir")" ]
  export CLAUDE_CHAIN_HOP_LOG="$_dir/hops.log"
}
