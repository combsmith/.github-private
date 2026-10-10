#!/usr/bin/env bats
# Unit tests for Gemini quota metering (#2030):
#   - scripts/lib/gemini-quota-caps.tsv  — per-key / per-model caps (data; filled with the
#                                          self-imposed Free Tier caps by #2146)
#   - scripts/lib/gemini-quota.sh        — ledger-based metering + per-key cooldown memory
#   - engine.sh check_provider_headroom gemini branch and the cooldown-aware rotation
#
# Gemini usage is self-metered from the token ledger (TOKEN_LOG_FILE) — no probe,
# no rate-limit headers, no Gemini API call. Unknown limits or an unreadable ledger
# are CONSTRAINED (return 2, never the "ok" line), the opposite of Claude's fail-open.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
QUOTA_LIB="$SCRIPT_DIR/scripts/lib/gemini-quota.sh"
SHIPPED_CAPS="$SCRIPT_DIR/scripts/lib/gemini-quota-caps.tsv"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

# Fixed clock so every window is deterministic.
NOW=1790000000

setup() {
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  : > "$GITHUB_ENV"
  : > "$GITHUB_OUTPUT"

  unset GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_API_KEY_2 GOOGLE_API_KEY_3 GOOGLE_API_KEY_4
  unset GEMINI_FLASH_MODEL GEMINI_PRO_MODEL GEMINI_FLASH_MODEL_CHAIN GEMINI_PRO_MODEL_CHAIN
  unset DEV_LEAD_USAGE_THRESHOLD GEMINI_LEDGER_FILE GEMINI_DEPLETED_KEYS ENGINE_USAGE_JSON

  STUB_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN_DIR"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/gemini"
  # Any curl call is a test failure: the gemini path must never touch the network.
  CURL_RECORD="$BATS_TEST_TMPDIR/curl_record"
  cat > "$STUB_BIN_DIR/curl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CURL_RECORD"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/curl"
  export PATH="$STUB_BIN_DIR:$PATH"

  TEST_PROMPT="$BATS_TEST_TMPDIR/prompt"
  echo "test prompt" > "$TEST_PROMPT"
  KEY_RECORD="$BATS_TEST_TMPDIR/key_record"
  export STUB_ENGINE_RECORD_KEYS="$KEY_RECORD"

  export TOKEN_LOG_FILE="$BATS_TEST_TMPDIR/ledger.jsonl"
  export GEMINI_QUOTA_NOW="$NOW"
  export GEMINI_QUOTA_CAPS="$BATS_TEST_TMPDIR/caps.tsv"
  export DEV_LEAD_DRY_RUN=false
}

teardown() {
  rm -f /tmp/dev-lead-failure-reason
  unset STUB_ENGINE_EXIT_BY_KEY STUB_ENGINE_RESPONSE_BY_KEY STUB_ENGINE_RECORD_KEYS
}

_source_engine() {
  export REVIEW_ENGINE="${1:-gemini}"
  source "$ENGINE_SCRIPT" 2>/dev/null || true
}

# _caps <rows...> — write a caps file; each row is "idx model tier rpm tpm rpd".
_caps() {
  {
    printf '# test caps\n'
    local r
    set -f   # rows are word-split on purpose; a '*' model glob must not expand
    for r in "$@"; do
      # shellcheck disable=SC2086
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' $r
    done
    set +f
    printf 'setting\tdefault_cooldown_sec\t60\n'
  } > "$GEMINI_QUOTA_CAPS"
}

# _shipped_caps_unknown [key_index [model]] — the test's caps file becomes a copy of the
# SHIPPED one with cap rows edited back to `unknown`: every row, one key's rows, or one
# row. The shipped file is filled (#2146), so the limits-unknown path needs this fixture.
_shipped_caps_unknown() {
  awk -F'\t' -v OFS='\t' -v k="${1:-}" -v m="${2:-}" '
    /^[[:space:]]*#/ || NF < 6 || $1 == "setting" { print; next }
    (k == "" || $1 == k) && (m == "" || $2 == m) { $3 = $4 = $5 = $6 = "unknown" }
    { print }' "$SHIPPED_CAPS" > "$GEMINI_QUOTA_CAPS"
}

# _ledger_call <key_index> <model> <age_sec> [tokens]
# Appends one gemini token_usage record <age_sec> seconds before NOW.
_ledger_call() {
  local idx="$1" model="$2" age="$3" tok="${4:-100}" ts
  ts="$(date -u -d "@$(( NOW - age ))" +%Y-%m-%dT%H:%M:%SZ)"
  jq -cn --arg ts "$ts" --arg m "$model" --argjson k "$idx" --argjson t "$tok" \
    '{ts:$ts, workflow:"dev-lead", tier:"action", engine:"gemini", model:$m,
      input_tokens:$t, cache_read_tokens:0, cache_creation_tokens:0, output_tokens:0,
      et:0, run_id:"1", context:"", duration_ms:null, key_index:$k}' >> "$TOKEN_LOG_FILE"
}

# ── the shipped caps file ─────────────────────────────────────────────────────

@test "caps file: ships next to model-pricing.tsv with rows for key indexes 1-4" {
  [ -f "$SHIPPED_CAPS" ]
  [ -f "$(dirname "$SHIPPED_CAPS")/model-pricing.tsv" ]
  # Rows for key indexes 1-4.
  for idx in 1 2 3 4; do
    awk -F'\t' -v k="$idx" '$1 == k { f = 1 } END { exit !f }' "$SHIPPED_CAPS"
  done
  # The values themselves are pinned by "#2146 AC1" below. Until #2146 this test
  # asserted every limit was `unknown` (the file shipped unfilled).
}

@test "caps file: has a row for every model the default gemini chains use" {
  source "$SCRIPT_DIR/scripts/lib/engine-models.sh"
  local m
  for tier in triage action deep audit single; do
    for m in $(ai_models_default gemini "$tier" | tr ',' ' '); do
      awk -F'\t' -v m="$m" '$1 ~ /^[1-4]$/ && $2 == m { f = 1 } END { exit !f }' "$SHIPPED_CAPS" \
        || { echo "missing caps row for $m"; return 1; }
    done
  done
}

@test "AC4: all-unknown caps (the shipped file as #2030 shipped it) → conservative result 2, log names 'limits unknown', never ok" {
  _shipped_caps_unknown
  export GOOGLE_API_KEY="fake-secret-a" GOOGLE_API_KEY_2="fake-secret-b"
  _ledger_call 1 gemini-3.8-flash 5
  _source_engine gemini

  run check_provider_headroom gemini
  [ "$status" -eq 2 ]
  [[ "$output" == *"limits unknown"* ]]
  [[ "$output" == *"[headroom] gemini"* ]]
  [[ "$output" != *"— ok"* ]]
  [[ "$output" != *"fake-secret"* ]]
}

# ── AC1: headroom from the ledger ─────────────────────────────────────────────

@test "AC1: ledger at/above threshold → 1 and logs the percent" {
  _caps "1 gemini-3.8-flash free 10 none none"
  export GOOGLE_API_KEY="fake-secret-a"
  local i; for i in 1 2 3 4 5 6 7 8; do _ledger_call 1 gemini-3.8-flash 10; done
  _source_engine gemini

  run check_provider_headroom gemini
  [ "$status" -eq 1 ]
  [[ "$output" == *"[headroom] gemini usage 80% >= threshold 75% — skipping"* ]]
}

@test "AC1: ledger below threshold → 0 with the ok line" {
  _caps "1 gemini-3.8-flash free 10 none none"
  export GOOGLE_API_KEY="fake-secret-a"
  _ledger_call 1 gemini-3.8-flash 10
  _ledger_call 1 gemini-3.8-flash 10
  _source_engine gemini

  run check_provider_headroom gemini
  [ "$status" -eq 0 ]
  [[ "$output" == *"[headroom] gemini usage 20% — ok"* ]]
}

@test "AC1: calls outside the minute window do not count toward rpm" {
  _caps "1 gemini-3.8-flash free 10 none none"
  export GOOGLE_API_KEY="fake-secret-a"
  local i; for i in 1 2 3 4 5 6 7 8 9; do _ledger_call 1 gemini-3.8-flash 120; done
  _source_engine gemini

  run check_provider_headroom gemini
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage 0% — ok"* ]]
}

@test "AC1: tokens/minute and requests/day windows are metered too" {
  export GOOGLE_API_KEY="fake-secret-a"
  # tpm: 900 of 1000 tokens in the last minute → 90%.
  _caps "1 gemini-3.8-flash paid none 1000 none"
  _ledger_call 1 gemini-3.8-flash 5 900
  _source_engine gemini
  run check_provider_headroom gemini
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage 90%"* ]]

  # rpd: 3 of 4 requests in the rolling day (reset unknown) → 75% = threshold.
  : > "$TOKEN_LOG_FILE"
  _caps "1 gemini-3.8-flash paid none none 4"
  _ledger_call 1 gemini-3.8-flash 3600
  _ledger_call 1 gemini-3.8-flash 7200
  _ledger_call 1 gemini-3.8-flash 80000
  _ledger_call 1 gemini-3.8-flash 90000   # older than 24h → outside the window
  run check_provider_headroom gemini
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage 75% >= threshold 75%"* ]]
}

@test "AC1: one key with headroom keeps the engine available (best key reported)" {
  _caps "1 gemini-3.8-flash free 10 none none" "2 gemini-3.8-flash free 10 none none"
  export GOOGLE_API_KEY="fake-secret-a" GOOGLE_API_KEY_2="fake-secret-b"
  local i; for i in 1 2 3 4 5 6 7 8 9; do _ledger_call 1 gemini-3.8-flash 10; done
  _ledger_call 2 gemini-3.8-flash 10
  _source_engine gemini

  run check_provider_headroom gemini
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage 10% — ok"* ]]
}

@test "AC1: unreadable ledger → conservative 2 and logs why" {
  _caps "1 gemini-3.8-flash free 10 none none"
  export GOOGLE_API_KEY="fake-secret-a"
  printf 'garbage' > "$TOKEN_LOG_FILE"
  chmod 000 "$TOKEN_LOG_FILE"
  _source_engine gemini

  run check_provider_headroom gemini
  chmod 600 "$TOKEN_LOG_FILE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ledger unreadable"* ]]
  [[ "$output" != *"— ok"* ]]
}

@test "AC1: no ledger configured (TOKEN_LOG_FILE unset) → conservative 2 and logs why" {
  _caps "1 gemini-3.8-flash free 10 none none"
  export GOOGLE_API_KEY="fake-secret-a"
  unset TOKEN_LOG_FILE
  _source_engine gemini

  run check_provider_headroom gemini
  [ "$status" -eq 2 ]
  [[ "$output" == *"ledger unreadable"* ]]
  [[ "$output" == *"no ledger configured"* ]]
}

@test "AC1: a not-yet-created ledger file is an empty ledger (0%), not unreadable" {
  _caps "1 gemini-3.8-flash free 10 none none"
  export GOOGLE_API_KEY="fake-secret-a"
  rm -f "$TOKEN_LOG_FILE"
  _source_engine gemini

  run check_provider_headroom gemini
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage 0% — ok"* ]]
}

@test "AC1: a key with no caps row is limits-unknown (conservative)" {
  _caps "1 gemini-3.8-flash free 10 none none"
  export GOOGLE_API_KEY_3="fake-secret-c"
  _source_engine gemini

  run check_provider_headroom gemini
  [ "$status" -eq 2 ]
  [[ "$output" == *"limits unknown"* ]]
  [[ "$output" == *"key index 3"* ]]
}

@test "headroom: missing caps file → conservative 2 naming limits unknown" {
  export GEMINI_QUOTA_CAPS="$BATS_TEST_TMPDIR/does-not-exist.tsv"
  export GOOGLE_API_KEY="fake-secret-a"
  _source_engine gemini

  run check_provider_headroom gemini
  [ "$status" -eq 2 ]
  [[ "$output" == *"limits unknown"* ]]
}

@test "headroom: DEV_LEAD_USAGE_THRESHOLD applies to gemini" {
  _caps "1 gemini-3.8-flash free 10 none none"
  export GOOGLE_API_KEY="fake-secret-a"
  local i; for i in 1 2 3 4 5 6; do _ledger_call 1 gemini-3.8-flash 10; done
  export DEV_LEAD_USAGE_THRESHOLD=50
  _source_engine gemini

  run check_provider_headroom gemini
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage 60% >= threshold 50%"* ]]
}

@test "headroom: run_writer_with_fallback skips gemini when every key is over threshold" {
  _caps "1 * free 10 none none"
  export GOOGLE_API_KEY="fake-secret-a"
  export DEV_LEAD_ENGINES="gemini"
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do _ledger_call 1 gemini-3.8-flash 10; done
  export STUB_ENGINE_EXIT=0
  _source_engine gemini

  run run_writer_with_fallback "$TEST_PROMPT"
  [ "$status" -eq 2 ]
  [ ! -s "$KEY_RECORD" ]   # gemini was never invoked
}

@test "headroom: run_writer_with_fallback still proceeds on the constrained result (no actuation)" {
  _shipped_caps_unknown
  export GOOGLE_API_KEY="fake-secret-a"
  export DEV_LEAD_ENGINES="gemini"
  export STUB_ENGINE_EXIT=0
  _source_engine gemini

  run run_writer_with_fallback "$TEST_PROMPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"limits unknown"* ]]
  [[ "$output" != *"fake-secret"* ]]
}

# ── AC3: caps come from the data file, not engine.sh ──────────────────────────

@test "AC3: the same ledger flips result when only the caps file changes" {
  export GOOGLE_API_KEY="fake-secret-a"
  local i; for i in 1 2 3 4 5 6 7 8; do _ledger_call 1 gemini-3.8-flash 10; done
  _source_engine gemini

  _caps "1 gemini-3.8-flash free 10 none none"
  run check_provider_headroom gemini
  [ "$status" -eq 1 ]

  _caps "1 gemini-3.8-flash paid 100 none none"
  run check_provider_headroom gemini
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage 8% — ok"* ]]
}

@test "AC3: engine.sh hard-codes no numeric Gemini limit" {
  # The gemini headroom branch carries no multi-digit literal in code (comments,
  # which cite issue numbers, are excluded) …
  run awk '/^check_provider_headroom\(\)/ { inf = 1 } inf && /^    gemini\)/ { g = 1 }
    g && /^      ;;/ { exit } g && !/^[[:space:]]*#/' "$ENGINE_SCRIPT"
  [ -n "$output" ]
  [[ ! "$output" =~ [0-9][0-9] ]]
  # … and no rpm/tpm/rpd/quota-cap assignment anywhere in engine.sh.
  run grep -nE '(rpm|tpm|rpd|RPM|TPM|RPD|_CAP|_cap|quota_limit|QUOTA_LIMIT)[A-Za-z_]*=["'"'"']?[0-9]' "$ENGINE_SCRIPT"
  [ "$status" -eq 1 ]
}

# ── AC5: no network call ──────────────────────────────────────────────────────

@test "AC5: the gemini headroom path makes no network call" {
  _caps "1 gemini-3.8-flash free 10 none none"
  export GOOGLE_API_KEY="fake-secret-a"
  _source_engine gemini
  run check_provider_headroom gemini
  [ ! -e "$CURL_RECORD" ]
}

@test "AC5: the quota library contains no network client or Gemini endpoint" {
  run grep -nEi 'curl|wget|https?://|generativelanguage|/dev/tcp' "$QUOTA_LIB"
  [ "$status" -eq 1 ]
}

# ── AC2: per-key cooldown memory ──────────────────────────────────────────────

@test "AC2: a cooling key is skipped by rotation until its deadline, then used again" {
  export GOOGLE_API_KEY="fake-secret-a" GOOGLE_API_KEY_2="fake-secret-b"
  export STUB_ENGINE_EXIT=0
  _source_engine gemini
  gq_record_cooldown 1 gemini-3.8-flash 100 "test"

  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  [ "$(cat "$KEY_RECORD")" = "fake-secret-b" ]
  [[ "$output" == *"key index 1"*"cooling down"* ]]
  [[ "$output" != *"fake-secret"* ]]

  # Past the deadline the key is back at the front of the rotation.
  : > "$KEY_RECORD"
  export GEMINI_QUOTA_NOW=$(( NOW + 101 ))
  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  [ "$(head -1 "$KEY_RECORD")" = "fake-secret-a" ]
  [[ "$output" != *"fake-secret"* ]]
}

@test "AC2: cooldown is per model — the key is still tried on another model" {
  export GOOGLE_API_KEY="fake-secret-a"
  export STUB_ENGINE_EXIT=0
  _source_engine gemini
  gq_record_cooldown 1 gemini-3.8-flash 100 "test"

  run _gemini_chain_invoke "gemini-3.1-pro-preview" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  [ "$(cat "$KEY_RECORD")" = "fake-secret-a" ]
}

@test "AC2: every key cooling → no call, model treated as throttled, chain moves on" {
  export GOOGLE_API_KEY="fake-secret-a"
  export STUB_ENGINE_EXIT=0
  _source_engine gemini
  gq_record_cooldown 1 gemini-3.8-flash 100 "test"

  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 2 ]
  [ ! -s "$KEY_RECORD" ]

  : > "$KEY_RECORD"
  run _gemini_chain_invoke "gemini-3.8-flash,gemini-3.1-pro-preview" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  [ "$(cat "$KEY_RECORD")" = "fake-secret-a" ]
}

@test "AC2: a throttled key is recorded by index with the error's retry hint" {
  export GOOGLE_API_KEY="fake-secret-a" GOOGLE_API_KEY_2="fake-secret-b"
  export STUB_ENGINE_EXIT_BY_KEY="fake-secret-a=1|fake-secret-b=0"
  export STUB_ENGINE_RESPONSE_BY_KEY="fake-secret-a=429 RESOURCE_EXHAUSTED: Please retry in 37.2s.|fake-secret-b=ok"
  _source_engine gemini

  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  run jq -r 'select(.kind == "gemini_key_cooldown") | "\(.key_index) \(.model) \(.until)"' "$TOKEN_LOG_FILE"
  [ "$output" = "1 gemini-3.8-flash $(( NOW + 38 ))" ]
  # Never the key value — not in the ledger, not in the log.
  ! grep -q "fake-secret" "$TOKEN_LOG_FILE"
}

@test "AC2: without a retry hint the configured default cooldown applies" {
  _caps "1 gemini-3.8-flash free 10 none none"
  sed -i "s/^setting\tdefault_cooldown_sec\t60$/setting\tdefault_cooldown_sec\t90/" "$GEMINI_QUOTA_CAPS"
  export GOOGLE_API_KEY="fake-secret-a" GOOGLE_API_KEY_2="fake-secret-b"
  export STUB_ENGINE_EXIT_BY_KEY="fake-secret-a=1|fake-secret-b=0"
  export STUB_ENGINE_RESPONSE_BY_KEY="fake-secret-a=quota exceeded|fake-secret-b=ok"
  _source_engine gemini

  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  run jq -r 'select(.kind == "gemini_key_cooldown") | .until' "$TOKEN_LOG_FILE"
  [ "$output" = "$(( NOW + 90 ))" ]
}

@test "AC2: the cooldown survives into a fresh shell reading the same ledger" {
  export GOOGLE_API_KEY="fake-secret-a" GOOGLE_API_KEY_2="fake-secret-b"
  export STUB_ENGINE_EXIT_BY_KEY="fake-secret-a=1|fake-secret-b=0"
  export STUB_ENGINE_RESPONSE_BY_KEY="fake-secret-a=429 too many requests|fake-secret-b=ok"
  _source_engine gemini
  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]

  # A later job (new process) starts from key 2, not from the throttled key 1.
  : > "$KEY_RECORD"
  run bash -c "source '$ENGINE_SCRIPT' >/dev/null 2>&1; _gemini_chain_invoke gemini-3.8-flash '$TEST_PROMPT' 30"
  [ "$status" -eq 0 ]
  [ "$(cat "$KEY_RECORD")" = "fake-secret-b" ]
  [[ "$output" != *"fake-secret"* ]]
}

@test "rotation: keys with measured headroom go before limits-unknown keys" {
  _caps "2 gemini-3.8-flash paid 100 none none"
  export GOOGLE_API_KEY="fake-secret-a" GOOGLE_API_KEY_2="fake-secret-b"
  export STUB_ENGINE_EXIT=0
  _source_engine gemini

  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  [ "$(cat "$KEY_RECORD")" = "fake-secret-b" ]
  [[ "$output" != *"fake-secret"* ]]
}

# ── ledger attribution ────────────────────────────────────────────────────────

@test "ledger: a gemini call's token record carries the key index, not the key" {
  export GOOGLE_API_KEY="fake-secret-a" GOOGLE_API_KEY_2="fake-secret-b"
  export STUB_ENGINE_EXIT_BY_KEY="fake-secret-a=1|fake-secret-b=0"
  export STUB_ENGINE_RESPONSE_BY_KEY="fake-secret-a=429 too many requests|fake-secret-b=ok"
  export DEV_LEAD_ENGINES="gemini"
  _source_engine gemini

  run run_writer_with_fallback "$TEST_PROMPT"
  [ "$status" -eq 0 ]
  run jq -r 'select((.kind // "token_usage") == "token_usage" and .engine == "gemini") | .key_index' "$TOKEN_LOG_FILE"
  [ "$output" = "2" ]
  ! grep -q "fake-secret" "$TOKEN_LOG_FILE"
}

@test "ledger: concurrent calls on different keys each record their own key index" {
  export DEV_LEAD_ENGINES="gemini"
  _source_engine gemini
  local pf="$BATS_TEST_TMPDIR/p.txt" of="$BATS_TEST_TMPDIR/o.txt"
  echo prompt > "$pf"; echo out > "$of"
  local i
  for i in 1 2 3 4; do
    (
      export _ENGINE_USAGE_OUT="$BATS_TEST_TMPDIR/call$i.usage"
      _gemini_note_key_index "$i"
      sleep 0.2   # all four notes land before any record is written
      _record_engine_tokens deep gemini "m$i" "$pf" "$of"
    ) &
  done
  wait
  for i in 1 2 3 4; do
    [ "$(jq -r --arg m "m$i" 'select(.model == $m) | .key_index' "$TOKEN_LOG_FILE")" = "$i" ]
  done
}

@test "ledger: without a call-unique sidecar the record is unattributed, never a shared key file" {
  export DEV_LEAD_ENGINES="gemini"
  _source_engine gemini
  unset _ENGINE_USAGE_OUT
  local pf="$BATS_TEST_TMPDIR/p.txt"; echo prompt > "$pf"
  run _gemini_note_key_index 2
  [[ "$output" == *"unattributed"* ]]
  [ -z "$(ls "$BATS_TEST_TMPDIR" | grep -F '.key' || true)" ]
  _record_engine_tokens deep gemini mx "$pf" "$pf"
  [ "$(jq -r 'select(.model == "mx") | has("key_index")' "$TOKEN_LOG_FILE")" = "false" ]
}

@test "key index: primary slot is 1, GOOGLE_API_KEY_N is N" {
  source "$QUOTA_LIB"
  [ "$(gq_key_index GEMINI_API_KEY)" = "1" ]
  [ "$(gq_key_index GOOGLE_API_KEY)" = "1" ]
  [ "$(gq_key_index GOOGLE_API_KEY_2)" = "2" ]
  [ "$(gq_key_index GOOGLE_API_KEY_4)" = "4" ]
}

@test "retry hint: parses retryDelay and 'retry in Ns', rounding up" {
  source "$QUOTA_LIB"
  local f="$BATS_TEST_TMPDIR/err"
  printf '{"error":{"details":[{"retryDelay": "12s"}]}}\n' > "$f"
  [ "$(gq_retry_hint_sec "$f")" = "12" ]
  printf 'Please retry in 4.01s.\n' > "$f"
  [ "$(gq_retry_hint_sec "$f")" = "5" ]
  printf 'no hint here\n' > "$f"
  [ -z "$(gq_retry_hint_sec "$f")" ]
}

@test "daily reset: a configured reset time bounds the requests/day window" {
  export GOOGLE_API_KEY="fake-secret-a"
  # Reset at 00:00 UTC; NOW is 2026-09-21T14:13:20Z, so calls before midnight drop out.
  _caps "1 gemini-3.8-flash paid none none 4"
  printf 'setting\tdaily_reset_time\t00:00\nsetting\tdaily_reset_tz\tUTC\n' >> "$GEMINI_QUOTA_CAPS"
  _ledger_call 1 gemini-3.8-flash 3600
  _ledger_call 1 gemini-3.8-flash 60000   # ~16.6h ago → before today's 00:00 UTC reset
  _ledger_call 1 gemini-3.8-flash 70000
  _source_engine gemini

  run check_provider_headroom gemini
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage 25% — ok"* ]]
}

# ── #2146: the shipped caps are the self-imposed Free Tier caps ───────────────
# These tests read the SHIPPED file, so a changed number fails here first.

# _all_four_keys — configure the four key slots the shipped caps file has rows for.
_all_four_keys() {
  export GOOGLE_API_KEY="fake-secret-a" GOOGLE_API_KEY_2="fake-secret-b"
  export GOOGLE_API_KEY_3="fake-secret-c" GOOGLE_API_KEY_4="fake-secret-d"
}

@test "#2146 AC1: the shipped caps are exactly the self-imposed Free Tier caps for key indexes 1-4, no unknown left" {
  local expected="" k
  for k in 1 2 3 4; do
    expected+="$(printf '%s\tgemini-3.8-flash\tpaid\t5\t250000\t20' "$k")"$'\n'
    expected+="$(printf '%s\tgemini-3.1-pro-preview\tpaid\t0\t0\t0' "$k")"$'\n'
  done
  # Every data row, byte for byte: both models for each key index, nothing else.
  run awk -F'\t' '/^[[:space:]]*#/ || !NF || $1 == "setting" { next } { print }' "$SHIPPED_CAPS"
  [ "$output" = "${expected%$'\n'}" ]
  # No `unknown` outside the comments: not in a cap row, not in a setting.
  run grep -vE '^[[:space:]]*#' "$SHIPPED_CAPS"
  [[ "$output" != *unknown* ]]
  # The settings rows are the ones #2030 / #2041 shipped.
  run awk -F'\t' '$1 == "setting" { print $2 "=" $3 }' "$SHIPPED_CAPS"
  [ "$output" = "daily_reset_time=00:00"$'\n'"daily_reset_tz=America/Los_Angeles"$'\n'"default_cooldown_sec=60"$'\n'"history_days=7" ]
}

@test "#2146 AC1: the library reads the shipped caps as Flash 5/250000/20 and Pro excluded on every key" {
  export GEMINI_QUOTA_CAPS="$SHIPPED_CAPS"
  _source_engine gemini
  local k
  for k in 1 2 3 4; do
    [ "$(gq_caps_for "$k" gemini-3.8-flash)" = "paid"$'\t'"5"$'\t'"250000"$'\t'"20" ]
    [ "$(gq_caps_for "$k" gemini-3.1-pro-preview)" = "paid"$'\t'"0"$'\t'"0"$'\t'"0" ]
    run gq_remaining "$k" gemini-3.8-flash
    [ "$(jq -r .state <<< "$output")" = "available" ]
    [ "$(jq -r .remaining_calls <<< "$output")" = "20" ]
    run gq_remaining "$k" gemini-3.1-pro-preview
    [ "$(jq -r .state <<< "$output")" = "unavailable" ]
    [ "$(jq -r .remaining_calls <<< "$output")" = "0" ]
  done
  # The expected effect: 20 Flash requests per key per day, 80 across the four keys.
  run gq_tier_view triage 1 2 3 4
  [ "$(jq -r .status <<< "$output")" = "available" ]
  [ "$(jq -r .remaining_calls <<< "$output")" = "80" ]
}

@test "#2146 AC3: Pro is never called on any key; deep, audit and single move to the Flash fallback" {
  export GEMINI_QUOTA_CAPS="$SHIPPED_CAPS"
  _all_four_keys
  local model_log="$BATS_TEST_TMPDIR/model_record" tier chain k
  export STUB_ENGINE_EXIT=0 STUB_ENGINE_RECORD_MODELS="$model_log"
  _source_engine gemini

  for tier in deep audit single; do
    chain="$(ai_models_gemini_chain "$tier")"
    [ "${chain%%,*}" = "gemini-3.1-pro-preview" ]   # Pro is still the tier's first choice
    : > "$model_log"; : > "$KEY_RECORD"
    run _gemini_chain_invoke "$chain" "$TEST_PROMPT" 30
    [ "$status" -eq 0 ]
    [ "$(cat "$model_log")" = "gemini-3.8-flash" ]     # one call, and it is Flash
    for k in 1 2 3 4; do [[ "$output" == *"key index $k"*"unavailable"* ]]; done
    [[ "$output" != *"fake-secret"* ]]
    # The tier view says the same thing before any work runs.
    run gq_tier_view "$tier" 1 2 3 4
    [ "$(jq -r .status <<< "$output")" = "degraded" ]
    [ "$(jq -r .degraded_to <<< "$output")" = "gemini-3.8-flash" ]
  done

  # Asked for Pro alone: no key is called at all.
  : > "$model_log"; : > "$KEY_RECORD"
  run _gemini_chain_invoke "gemini-3.1-pro-preview" "$TEST_PROMPT" 30
  [ "$status" -eq 2 ]
  [ ! -s "$KEY_RECORD" ]
  [ ! -s "$model_log" ]
}

@test "#2146 AC3: with Flash throttled on every key, Pro is still not called (no tier falls back to it)" {
  export GEMINI_QUOTA_CAPS="$SHIPPED_CAPS"
  _all_four_keys
  local model_log="$BATS_TEST_TMPDIR/model_record" tier
  export STUB_ENGINE_RECORD_MODELS="$model_log"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.8-flash=1|gemini-3.1-pro-preview=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.8-flash=429 too many requests|gemini-3.1-pro-preview=ok"
  _source_engine gemini

  for tier in triage action deep audit single; do
    : > "$model_log"; : > "$KEY_RECORD"; : > "$TOKEN_LOG_FILE"   # drop the previous tier's cooldowns
    run _gemini_chain_invoke "$(ai_models_gemini_chain "$tier")" "$TEST_PROMPT" 30
    [ "$status" -eq 2 ]
    [ -s "$model_log" ]                                # Flash was tried …
    ! grep -q "pro" "$model_log" || false              # … Pro never was, on any key
  done
}

@test "#2146 AC4: a shipped row edited back to unknown takes the conservative limits-unknown path" {
  _shipped_caps_unknown 1 gemini-3.8-flash
  # The fixture is the shipped file with exactly that one row changed.
  [ "$(grep -c "unknown"$'\t'"unknown"$'\t'"unknown"$'\t'"unknown" "$GEMINI_QUOTA_CAPS")" = "1" ]
  [ "$(diff "$SHIPPED_CAPS" "$GEMINI_QUOTA_CAPS" | grep -c '^>')" = "1" ]
  export GOOGLE_API_KEY="fake-secret-a"
  export STUB_ENGINE_EXIT=0
  _source_engine gemini

  run check_provider_headroom gemini
  [ "$status" -eq 2 ]
  [[ "$output" == *"limits unknown for key index 1"* ]]
  [[ "$output" != *"— ok"* ]]
  [[ "$output" != *"fake-secret"* ]]

  run gq_remaining 1 gemini-3.8-flash
  [ "$(jq -r .state <<< "$output")" = "unknown" ]
  [ "$(jq -r .remaining_calls <<< "$output")" = "null" ]

  # Not a hard block: the unknown key is still tried.
  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  [ "$(cat "$KEY_RECORD")" = "fake-secret-a" ]
}
