#!/usr/bin/env bats
# Unit tests for engine.sh — run_writer and run_writer_with_fallback (Phase 2)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  # Sidecars go to this test's directory, not the /tmp every session shares (#2271).
  export DEV_LEAD_SIDECAR_DIR="$BATS_TEST_TMPDIR"
  # Create a temp bin dir with stub engines
  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini"
  export PATH="$STUB_BIN_DIR:$PATH"
  # Create a test prompt file
  TEST_PROMPT="$(mktemp)"
  echo "test prompt content" > "$TEST_PROMPT"
  export TEST_PROMPT
  export STUB_BIN_DIR
  export GEMINI_API_KEY="dummy-test-key"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$TEST_PROMPT"
  rm -rf "$STUB_BIN_DIR"
  if [ -n "${TEST_OWNED_TOKEN_LOG:-}" ] && [ "${TOKEN_LOG_FILE:-}" = "$TEST_OWNED_TOKEN_LOG" ]; then
    rm -f "$TEST_OWNED_TOKEN_LOG"
  fi
  unset TOKEN_LOG_FILE TEST_OWNED_TOKEN_LOG
}

# Helper: source engine with a given engine type (suppresses info line)
_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT"
}

# ── run_writer tests ──────────────────────────────────────────────────────────

@test "writer: run_writer with stub claude exits 0 on success" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export DEV_LEAD_DRY_RUN=false

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

@test "writer: run_writer dry-run exits 0 without calling engine" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=true
  # Remove the claude stub to verify it's not called
  rm -f "$STUB_BIN_DIR/claude"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "writer: run_writer dry-run: no engine binary needed" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=true
  # Even without claude in PATH, dry-run should succeed
  local saved_path="$PATH"
  export PATH="/usr/bin:/bin"

  run run_writer "$TEST_PROMPT"

  export PATH="$saved_path"
  [ "$status" -eq 0 ]
}

@test "writer: run_writer exits non-zero on engine failure" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=1
  export DEV_LEAD_DRY_RUN=false

  run run_writer "$TEST_PROMPT"

  [ "$status" -ne 0 ]
}

@test "writer: gemini engine exits 0 on success" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT=0
  export DEV_LEAD_DRY_RUN=false

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

@test "writer: copilot falls back to claude in run_writer (internal)" {
  # When REVIEW_ENGINE=copilot, run_writer calls copilot_chat → gh copilot
  _source_engine "copilot"
  export DEV_LEAD_DRY_RUN=false
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"copilot"*) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

@test "writer: run_writer dry-run logs prompt line count" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=true
  printf 'line1\nline2\nline3\n' > "$TEST_PROMPT"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"3 lines"* ]]
}

# ── rate-limit detection tests ────────────────────────────────────────────────

@test "writer: run_writer returns exit 2 when claude outputs rate-limit text" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  # Stub claude: exits 1 and outputs a rate-limit message to stdout
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "You've hit your limit · resets 11:20pm (UTC)"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "writer: run_writer returns exit 2 when gemini outputs rate-limit text" {
  _source_engine "gemini"
  export DEV_LEAD_DRY_RUN=false
  cat > "$STUB_BIN_DIR/gemini" << 'STUB'
#!/usr/bin/env bash
echo "quota exceeded for today"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/gemini"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "writer: run_writer returns exit 2 when gemini writes rate-limit text to stderr" {
  _source_engine "gemini"
  export DEV_LEAD_DRY_RUN=false
  cat > "$STUB_BIN_DIR/gemini" << 'STUB'
#!/usr/bin/env bash
echo "quota exceeded for today" >&2
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/gemini"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "writer: run_writer returns exit 1 (not 2) for non-rate-limit failure" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  export STUB_ENGINE_EXIT=1
  # Deliberately avoid any rate-limit vocabulary so is_rate_limited returns false
  export STUB_ENGINE_RESPONSE="compilation failed: syntax error on line 42"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 1 ]
}

@test "writer: run_writer writes reset time to /tmp/dev-lead-rate-limit-reset on rate-limit" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  rm -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-rate-limit-reset"
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "You've hit your limit · resets 11:20pm (UTC)"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
  [ -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-rate-limit-reset" ]
}

@test "writer: run_writer_with_fallback retries all engines and returns 2 when all rate-limited" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  # All engines output rate-limit text and exit 1 → run_writer returns 2 for each
  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "rate limit exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done
  # copilot uses `gh copilot`; provide token + gh stub returning rate-limit text
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"copilot"*) echo "rate limit exceeded"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "writer: run_writer_with_fallback skips copilot when token is classic PAT" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  export COPILOT_GITHUB_TOKEN="ghp_classic_token"

  # Claude and Gemini both rate-limit.
  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "quota exceeded" >&2
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  # If copilot is invoked, this stub would fail the test via status 1 path.
  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
echo "copilot should have been skipped" >&2
exit 1
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "writer: run_writer_with_fallback succeeds on second engine if first rate-limited" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  # claude is rate-limited; gemini succeeds. Copilot (now the 1st fallback)
  # is forced to skip via a classic-PAT token so gemini remains the tested fallback.
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "hit your limit"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/claude"
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="gemini response ok"
  export COPILOT_GITHUB_TOKEN="ghp_stub"  # ghp_* → copilot fallback is skipped

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

# ── parse_reset_time tests ─────────────────────────────────────────────────────

@test "parse_reset_time: extracts H:MMpm from 'resets 11:20pm (UTC)'" {
  _source_engine "claude"
  rm -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-rate-limit-reset"

  parse_reset_time "You've hit your limit · resets 11:20pm (UTC)"

  [ -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-rate-limit-reset" ]
  # Should contain a non-empty ISO timestamp
  local result
  result=$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-rate-limit-reset")
  [ -n "$result" ]
  [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "parse_reset_time: writes empty string when no reset time found" {
  _source_engine "claude"
  rm -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-rate-limit-reset"

  parse_reset_time "some error without a reset time"

  [ -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-rate-limit-reset" ]
  local result
  result=$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-rate-limit-reset")
  [ -z "$result" ]
}

# ── token logging tests ───────────────────────────────────────────────────────

@test "token: run_writer writes a record to TOKEN_LOG_FILE when set" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="fixed the bug"
  export DEV_LEAD_DRY_RUN=false
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  [ -s "$log" ]
  jq empty < "$log"
}

@test "token: run_writer record contains tier=writer" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export DEV_LEAD_DRY_RUN=false
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  run_writer "$TEST_PROMPT"

  local tier; tier=$(jq -r '.tier' < "$log")
  [ "$tier" = "writer" ]
}

@test "token: run_writer record contains correct engine and model" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export DEV_LEAD_DRY_RUN=false
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  run_writer "$TEST_PROMPT"

  local engine model
  engine=$(jq -r '.engine' < "$log")
  model=$(jq -r '.model' < "$log")
  [ "$engine" = "claude" ]
  [ "$model" = "$ENGINE_ACTION_MODEL" ]
}

@test "token: run_writer is a no-op for token logging when TOKEN_LOG_FILE unset" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export DEV_LEAD_DRY_RUN=false
  unset TOKEN_LOG_FILE

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

@test "token: dry-run does not write a token record" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=true
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # Log should remain empty (dry-run produces no engine call)
  [ ! -s "$log" ]
}

@test "token: run_writer token capture is non-fatal on unwritable log path" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export DEV_LEAD_DRY_RUN=false
  export TOKEN_LOG_FILE="/proc/nonexistent-readonly-path/token.jsonl"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

@test "token: run_triage writes a record to TOKEN_LOG_FILE when set" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="LOW risk verdict"
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  run run_triage "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  [ -s "$log" ]
  jq empty < "$log"
  local tier; tier=$(jq -r '.tier' < "$log")
  [ "$tier" = "triage" ]
}

@test "token: run_triage is a no-op for token logging when TOKEN_LOG_FILE unset" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  unset TOKEN_LOG_FILE

  run run_triage "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

# ── per-call latency (duration_ms) tests (#1949) ──────────────────────────────

@test "duration: _elapsed_ms prints end-start, and nothing for missing, non-numeric or backwards stamps" {
  _source_engine "claude"
  [ "$(_elapsed_ms 1000 1250)" = "250" ]
  [ "$(_elapsed_ms 1000 1000)" = "0" ]
  [ -z "$(_elapsed_ms "" 1250)" ]
  [ -z "$(_elapsed_ms 1000 "")" ]
  [ -z "$(_elapsed_ms 1000 12x)" ]
  [ -z "$(_elapsed_ms 2000 1000)" ]
}

@test "duration: _now_ms returns 13-digit epoch ms via EPOCHREALTIME and via the date fallback" {
  _source_engine "claude"
  run _now_ms
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{13}$ ]]
  # Without EPOCHREALTIME the date fallback must still yield epoch ms.
  run bash -c "$(declare -f _now_ms); unset EPOCHREALTIME; _now_ms"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{13}$ ]]
}

@test "duration: _now_ms prints nothing (so duration_ms is null, not 0) when no clock is readable" {
  _source_engine "claude"
  # No EPOCHREALTIME and no `date` on PATH: must print nothing rather than 0.
  run bash -c "$(declare -f _now_ms); unset EPOCHREALTIME; PATH=/nonexistent; _now_ms"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "duration: run_agentic deep tier emits a positive duration_ms through a stubbed engine" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="deep verdict"
  # A small forced delay guarantees the measured wall-clock is > 0 ms.
  export STUB_ENGINE_DELAY=1
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  run run_agentic "$TEST_PROMPT" "$ENGINE_DEEP_MODEL" deep

  [ "$status" -eq 0 ]
  [ -s "$log" ]
  jq empty < "$log"
  local tier dur
  tier=$(jq -r '.tier' < "$log")
  dur=$(jq -r '.duration_ms' < "$log")
  [ "$tier" = "deep" ]
  [ "$dur" != "null" ]
  [ "$dur" -gt 0 ]
}

@test "duration: run_writer records a numeric duration_ms" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export DEV_LEAD_DRY_RUN=false
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  run_writer "$TEST_PROMPT"

  local dur
  dur=$(jq -r '.duration_ms' < "$log")
  [ "$dur" != "null" ]
  [ "$dur" -ge 0 ]
}

# ── real-usage capture (cache) tests ──────────────────────────────────────────

@test "usage: claude run captures real cache-read and cache-write from JSON" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="verdict text"
  export STUB_CLAUDE_USAGE="2000 800 600 150"   # input cache_read cache_write output
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  run run_triage "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.input_tokens'          < "$log")" = "2000" ]
  [ "$(jq -r '.cache_read_tokens'     < "$log")" = "800" ]
  [ "$(jq -r '.cache_creation_tokens' < "$log")" = "600" ]
  [ "$(jq -r '.output_tokens'         < "$log")" = "150" ]
}

@test "usage: claude JSON mode still returns plain text to the caller (not JSON)" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="just the verdict"
  export STUB_CLAUDE_USAGE="10 0 0 5"
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  run run_triage "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  [ "$output" = "just the verdict" ]   # extracted .result, not the JSON envelope
}

@test "usage: ENGINE_USAGE_JSON=0 disables JSON capture (falls back to estimate)" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="verdict"
  export STUB_CLAUDE_USAGE="2000 800 600 150"
  export ENGINE_USAGE_JSON=0
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  run run_triage "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # Estimate path → cache figures unknown → 0 (not the stub's 800/600).
  [ "$(jq -r '.cache_read_tokens'     < "$log")" = "0" ]
  [ "$(jq -r '.cache_creation_tokens' < "$log")" = "0" ]
}

@test "usage: gemini run captures usage (input = prompt - cached)" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="gem verdict"
  export STUB_GEMINI_USAGE="500 100 60"   # prompt cached candidates
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  run run_triage "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.engine'            < "$log")" = "gemini" ]
  [ "$(jq -r '.input_tokens'      < "$log")" = "400" ]
  [ "$(jq -r '.cache_read_tokens' < "$log")" = "100" ]
  [ "$(jq -r '.output_tokens'     < "$log")" = "60" ]
}

@test "usage: failed mktemp + stale _ENGINE_USAGE_OUT does NOT reuse the stale sidecar" {
  # Regression for the per-call-key fix: run_* clears _ENGINE_USAGE_OUT before
  # mktemp, so a failed mktemp falls back to estimation instead of reading a prior
  # call's sidecar. Without it, the planted 999/9/9/9 below would be logged.
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="verdict"
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  # A leftover per-call key + sidecar content from a "previous" call.
  local stale; stale="$(mktemp)"
  printf '999\t9\t9\t9\n' > "$stale"
  export _ENGINE_USAGE_OUT="$stale"

  # Force mktemp to fail inside the engine via a PATH shim.
  local shim; shim="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$shim/mktemp"
  chmod +x "$shim/mktemp"

  PATH="$shim:$PATH" run run_triage "$TEST_PROMPT"

  rm -rf "$shim"; rm -f "$stale"; unset _ENGINE_USAGE_OUT
  [ "$status" -eq 0 ]
  # The stale cache figures must NOT appear in the record.
  [ "$(jq -r '.cache_read_tokens'     < "$log")" != "9" ]
  [ "$(jq -r '.cache_creation_tokens' < "$log")" != "9" ]
  [ "$(jq -r '.input_tokens'          < "$log")" != "999" ]
}

@test "token: run_writer_with_fallback logs the fallback engine (not rate-limited primary)" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  # Make claude output rate-limit text (exit 1 → is_rate_limited → returns 2)
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "hit your limit"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  # Gemini stub succeeds. Copilot (now the 1st fallback) is forced to skip
  # via a classic-PAT token so gemini remains the tested fallback.
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="gemini fixed it"
  export COPILOT_GITHUB_TOKEN="ghp_stub"  # ghp_* → copilot fallback is skipped

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # Token record must exist and belong to the gemini fallback, not claude
  [ -s "$log" ]
  jq empty < "$log"
  local engine tier
  # The rate-limited claude attempt may also leave a kind:"rate_limit_sample"
  # diagnostic record (#2140); only token records are under test here.
  engine=$(jq -r 'select(.kind != "rate_limit_sample") | .engine' < "$log")
  tier=$(jq -r 'select(.kind != "rate_limit_sample") | .tier' < "$log")
  [ "$engine" = "gemini" ]
  [ "$tier" = "writer" ]
}

@test "token: rate-limited primary engine writes NO token record" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  # Claude outputs rate-limit text → run_writer returns 2 and must not log tokens
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "hit your limit"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
  # Rate-limited → no successful completion → no token record. A
  # kind:"rate_limit_sample" diagnostic (#2140) is not a token record.
  [ -z "$(jq -c 'select(.kind != "rate_limit_sample")' < "$log")" ]
}

@test "writer: run_writer persists session output to the session-output sidecar" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "session output line one"
echo "session output line two"
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  rm -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt"
  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  [ -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt" ]
  grep -q "session output line" "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt"
  rm -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt"
}

@test "writer: GITHUB_STEP_SUMMARY appends HTML-escaped session output" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  # Stub writes literal </details> which must be escaped in the summary so it
  # cannot close the wrapping <details> block on the run summary page.
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "danger zone </details> here"
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  local summary; summary="$(mktemp)"
  export GITHUB_STEP_SUMMARY="$summary"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # Literal </details> must be HTML-escaped → only the wrapping closer remains
  ! grep -F "danger zone </details>" "$summary" || false
  grep -F "danger zone &lt;/details&gt;" "$summary"
  rm -f "$summary" "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt"
}

@test "writer: run_writer overwrites a stale session-output sidecar from a prior run" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  # Pre-populate with content from a hypothetical previous run
  echo "STALE_CONTENT_FROM_PRIOR_RUN" > "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt"

  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "fresh session output"
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  [ -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt" ]
  # Stale content from prior run must not leak into this run's session output
  ! grep -q "STALE_CONTENT_FROM_PRIOR_RUN" "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt" || false
  grep -q "fresh session output" "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt"
  rm -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt"
}

@test "writer: persisted /tmp file has GitHub tokens redacted" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "Authorization: token ghp_abcdefghijklmnopqrstuvwxyz1234567890ABCD"
echo "ok"
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  rm -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt"
  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # Raw token must not survive to /tmp; only the redacted marker remains
  # The fake token is written as two adjacent strings so this line holds no literal
  # token pattern (gitleaks flags a changed line that does, #2263).
  ! grep -F "ghp_abcdefgh""ijklmnopqrstuvwxyz1234567890ABCD" "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt" || false
  grep -F "***REDACTED-GH-TOKEN***" "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt"
  rm -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt"
}

@test "writer: GITHUB_STEP_SUMMARY has secrets redacted before HTML escape" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "Authorization: Bearer sk-ant-secretkey1234567890abcdefghij"
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  local summary; summary="$(mktemp)"
  export GITHUB_STEP_SUMMARY="$summary"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  ! grep -F "sk-ant-secretkey1234567890abcdefghij" "$summary" || false
  grep -F "***REDACTED-API-KEY***" "$summary"
  rm -f "$summary" "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt"
}

@test "writer: PEM private key block fully redacted in /tmp persistence" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  # Build PEM markers at runtime so the literal "-----BEGIN/END RSA PRIVATE
  # KEY-----" never appears in this source file (avoids tripping gitleaks on
  # a test fixture). Same pattern as the post_no_changes PEM tests in
  # test_fix_reviews.bats.
  local dashes="-----"
  local begin="${dashes}BEGIN RSA PRIVATE KEY${dashes}"
  local end="${dashes}END RSA PRIVATE KEY${dashes}"
  cat > "$STUB_BIN_DIR/claude" << STUB
#!/usr/bin/env bash
echo "$begin"
echo "MIIEowIBAAKCAQEAuVERYSENSITIVEKEYBODYWITHTONSOFCHARSANDMOREDATAHERE"
echo "ENDOFBODYDATAGOESHEREMOREMOREMOREMOREMOREMORE"
echo "$end"
echo "after-key"
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  rm -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt"
  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # Neither header, body, nor footer of the PEM block may survive. Substring
  # match (without the surrounding dashes) so a partial leak that trims the
  # delimiters still fails the assertion. Safe vs. gitleaks: the substring
  # alone does not satisfy the private-key rule's `-----BEGIN ... -----`
  # regex.
  ! grep -F "BEGIN RSA PRIVATE KEY" "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt" || false
  ! grep -F "uVERYSENSITIVEKEYBODY" "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt" || false
  ! grep -F "END RSA PRIVATE KEY" "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt" || false
  grep -F "***REDACTED-PRIVATE-KEY***" "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt"
  # Content outside the PEM block survives
  grep -F "after-key" "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt"
  rm -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt"
}
