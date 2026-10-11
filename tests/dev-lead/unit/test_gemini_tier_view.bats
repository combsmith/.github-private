#!/usr/bin/env bats
# Unit tests for Gemini availability per task tier (#2041, slice 2 of #2030):
#   - gq_remaining         forward-looking remaining capacity per (key index, model)
#   - gq_tier_view         per-tier status from ai_models_gemini_chain
#   - gq_day_history       per-reset-day key × model matrix
#   - gq_tier_snapshot     machine-readable snapshot (gemini-tier-snapshot.schema.json)
#   - gq_tier_notices      one notice per tier per Pacific day
#   - rejected attempts, escalating cooldown, rotation dropping cap-0 / exhausted keys
#   - scripts/gemini_tier_report.sh  history store that survives fleet-monitor runs
#
# Everything is metered from the fleet's own ledger: no network, no Gemini API call.
# No test invents a Gemini rejection message: the rate-limited stub responses reuse
# the strings the slice-1 suite (test_gemini_quota.bats) already drives, and nothing
# here asserts the daily-wording classification (no real captured sample exists).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
QUOTA_LIB="$SCRIPT_DIR/scripts/lib/gemini-quota.sh"
MODELS_LIB="$SCRIPT_DIR/scripts/lib/engine-models.sh"
TIER_REPORT="$SCRIPT_DIR/scripts/gemini_tier_report.sh"
SCHEMA="$SCRIPT_DIR/scripts/lib/gemini-tier-snapshot.schema.json"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

# 2026-10-09T19:00:00Z = 12:00 PDT. Today's Pacific window is
# 2026-10-09T07:00:00Z .. 2026-10-10T07:00:00Z.
NOW=1791572400
DAY_START=1791529200
DAY_END=1791615600

setup() {
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  : > "$GITHUB_ENV"
  : > "$GITHUB_OUTPUT"

  unset GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_API_KEY_2 GOOGLE_API_KEY_3 GOOGLE_API_KEY_4
  unset GEMINI_FLASH_MODEL GEMINI_PRO_MODEL GEMINI_FLASH_MODEL_CHAIN GEMINI_PRO_MODEL_CHAIN
  unset AI_MODELS_GEMINI DEV_LEAD_USAGE_THRESHOLD GEMINI_LEDGER_FILE GEMINI_DEPLETED_KEYS
  unset ENGINE_USAGE_JSON GEMINI_HISTORY_DAYS

  STUB_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN_DIR"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/gemini"
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
  MODEL_RECORD="$BATS_TEST_TMPDIR/model_record"
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

_source_lib() {
  source "$MODELS_LIB"
  source "$QUOTA_LIB"
}

# _caps <rows...> — caps file with a Pacific midnight reset; each row is
# "idx model tier rpm tpm rpd".
_caps() {
  {
    printf '# test caps\n'
    local r
    set -f
    for r in "$@"; do
      # shellcheck disable=SC2086
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' $r
    done
    set +f
    printf 'setting\tdaily_reset_time\t00:00\n'
    printf 'setting\tdaily_reset_tz\tAmerica/Los_Angeles\n'
    printf 'setting\tdefault_cooldown_sec\t60\n'
  } > "$GEMINI_QUOTA_CAPS"
}

_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# _call_at <key_index> <model> <epoch> [tokens] — one successful gemini call.
_call_at() {
  jq -cn --arg ts "$(_iso "$3")" --arg m "$2" --argjson k "$1" --argjson t "${4:-100}" \
    '{ts:$ts, workflow:"dev-lead", tier:"action", engine:"gemini", model:$m,
      input_tokens:$t, cache_read_tokens:0, cache_creation_tokens:0, output_tokens:0,
      et:0, run_id:"1", context:"", duration_ms:null, key_index:$k}' >> "$TOKEN_LOG_FILE"
}

# _calls <n> <key_index> <model> <epoch> — n calls, one second apart, ending at epoch.
_calls() {
  local i
  for (( i = 0; i < $1; i++ )); do _call_at "$2" "$3" $(( $4 - i )); done
}

# _attempt_at <key_index> <model> <epoch> — one rejected attempt.
_attempt_at() {
  jq -cn --arg ts "$(_iso "$3")" --arg m "$2" --argjson k "$1" \
    '{kind:"gemini_attempt", ts:$ts, workflow:"dev-lead", engine:"gemini", model:$m,
      key_index:$k, rejected:true, run_id:"1"}' >> "$TOKEN_LOG_FILE"
}

# ── scope 1: remaining capacity ───────────────────────────────────────────────

@test "window: today's Pacific window runs from midnight PT to the next midnight PT" {
  _caps "1 m-a free 10 none 20"
  _source_lib
  run gq_day_window
  [ "$output" = "$DAY_START"$'\t'"$DAY_END"$'\t'"0" ]
}

@test "remaining: available with n remaining requests, never touching the network" {
  _caps "1 m-a free 10 1000 20"
  _calls 5 1 m-a $(( NOW - 3600 ))
  _source_lib
  run gq_remaining 1 m-a
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<< "$output")" = "available" ]
  [ "$(jq -r .remaining_calls <<< "$output")" = "15" ]
  [ "$(jq -r .remaining.rpd <<< "$output")" = "15" ]
  [ "$(jq -r .remaining.rpm <<< "$output")" = "10" ]
  [ "$(jq -r .remaining.tpm <<< "$output")" = "1000" ]
  [ "$(jq -r .used.rpd <<< "$output")" = "5" ]
  [ "$(jq -r .day_end <<< "$output")" = "$DAY_END" ]
  [ ! -e "$CURL_RECORD" ]
}

@test "remaining: a window that straddles Pacific midnight counts only calls since the reset" {
  _caps "1 m-a free none none 20"
  # 06:59Z (23:59 PDT yesterday) is before the reset; 07:01Z is after it.
  _calls 7 1 m-a $(( DAY_START - 60 ))
  _calls 3 1 m-a $(( DAY_START + 60 ))
  _source_lib
  run gq_remaining 1 m-a
  [ "$(jq -r .used.rpd <<< "$output")" = "3" ]
  [ "$(jq -r .remaining_calls <<< "$output")" = "17" ]

  # One minute before the next reset the same calls are still today's …
  export GEMINI_QUOTA_NOW=$(( DAY_END - 60 ))
  run gq_remaining 1 m-a
  [ "$(jq -r .used.rpd <<< "$output")" = "3" ]
  # … one minute after it the window has rolled over and nothing is used yet.
  export GEMINI_QUOTA_NOW=$(( DAY_END + 60 ))
  run gq_remaining 1 m-a
  [ "$(jq -r .used.rpd <<< "$output")" = "0" ]
  [ "$(jq -r .remaining_calls <<< "$output")" = "20" ]
  [ "$(jq -r .day_start <<< "$output")" = "$DAY_END" ]
}

@test "remaining: a DST change day is a 23h / 25h window, not a fixed 86400s" {
  _caps "1 m-a free none none 20"
  _source_lib
  # 2026-03-08 (spring forward): 08:00Z .. 2026-03-09 07:00Z.
  export GEMINI_QUOTA_NOW=1773000000
  run gq_day_window
  [ "$output" = "1772956800"$'\t'"1773039600"$'\t'"0" ]
  # A call at 07:30Z on the 8th is still 2026-03-07 PST (23:30) — not today.
  _call_at 1 m-a 1772955000
  _call_at 1 m-a 1772958600
  run gq_remaining 1 m-a
  [ "$(jq -r .used.rpd <<< "$output")" = "1" ]
  # 2026-11-01 (fall back): 07:00Z .. 2026-11-02 08:00Z.
  export GEMINI_QUOTA_NOW=$(( 1793516400 + 3600 * 24 + 1800 ))
  run gq_day_window
  [ "$output" = "1793516400"$'\t'"1793606400"$'\t'"0" ]
}

@test "remaining: cap 0 is unavailable, whatever the ledger says" {
  _caps "1 m-a free 5 none 0"
  _source_lib
  run gq_remaining 1 m-a
  [ "$(jq -r .state <<< "$output")" = "unavailable" ]
  [ "$(jq -r .remaining_calls <<< "$output")" = "0" ]
  # cap 0 dominates a sibling `unknown` limit.
  _caps "1 m-a free unknown unknown 0"
  run gq_remaining 1 m-a
  [ "$(jq -r .state <<< "$output")" = "unavailable" ]
}

@test "remaining: usage above the daily cap is exhausted until the reset, never negative" {
  _caps "1 m-a free none none 20"
  _calls 23 1 m-a $(( NOW - 3600 ))
  _source_lib
  run gq_remaining 1 m-a
  [ "$(jq -r .state <<< "$output")" = "exhausted" ]
  [ "$(jq -r .remaining_calls <<< "$output")" = "0" ]
  [ "$(jq -r .remaining.rpd <<< "$output")" = "0" ]
  [ "$(jq -r .used.rpd <<< "$output")" = "23" ]
  [ "$(jq -r .until <<< "$output")" = "$DAY_END" ]
}

@test "remaining: an active cooldown is cooling(until T)" {
  _caps "1 m-a free 10 none 20"
  _source_lib
  gq_record_cooldown 1 m-a 300 test
  run gq_remaining 1 m-a
  [ "$(jq -r .state <<< "$output")" = "cooling" ]
  [ "$(jq -r .until <<< "$output")" = "$(( NOW + 300 ))" ]
}

@test "remaining: a full rolling minute is cooling until the oldest call leaves it" {
  _caps "1 m-a free 3 none 20"
  _call_at 1 m-a $(( NOW - 40 ))
  _call_at 1 m-a $(( NOW - 20 ))
  _call_at 1 m-a $(( NOW - 10 ))
  _source_lib
  run gq_remaining 1 m-a
  [ "$(jq -r .state <<< "$output")" = "cooling" ]
  [ "$(jq -r .until <<< "$output")" = "$(( NOW + 20 ))" ]
  [ "$(jq -r .remaining.rpm <<< "$output")" = "0" ]
}

@test "remaining: unfilled limits or a missing caps row are unknown" {
  _caps "1 m-a unknown unknown unknown unknown"
  _source_lib
  run gq_remaining 1 m-a
  [ "$(jq -r .state <<< "$output")" = "unknown" ]
  [ "$(jq -r .remaining_calls <<< "$output")" = "null" ]
  run gq_remaining 2 m-a
  [ "$(jq -r .state <<< "$output")" = "unknown" ]
}

# ── scope 6: rejected attempts count ──────────────────────────────────────────

@test "attempts: a rejected attempt is recorded by index and counted as a request" {
  _caps "1 m-a free 10 none 20"
  export GOOGLE_API_KEY="fake-secret-a"
  _source_lib
  gq_record_attempt 1 m-a
  run jq -c 'select(.kind == "gemini_attempt")' "$TOKEN_LOG_FILE"
  [ "$(jq -r '.key_index' <<< "$output")" = "1" ]
  [ "$(jq -r '.rejected' <<< "$output")" = "true" ]
  [ "$(jq -r '.model' <<< "$output")" = "m-a" ]
  [ "$(jq -r 'has("body") or has("response")' <<< "$output")" = "false" ]
  ! grep -q fake-secret "$TOKEN_LOG_FILE" || false
  run gq_remaining 1 m-a
  [ "$(jq -r .used.rpd <<< "$output")" = "1" ]
  [ "$(jq -r .used.rpm <<< "$output")" = "1" ]
  [ "$(jq -r .remaining_calls <<< "$output")" = "19" ]
  # The slice-1 headroom percent counts it too.
  run gq_key_pct 1 m-a
  [ "$output" = "10" ]
}

@test "attempts: the engine records a rejection as an attempt and a redacted sample, never the key" {
  export GOOGLE_API_KEY="fake-secret-a" GOOGLE_API_KEY_2="fake-secret-b"
  export STUB_ENGINE_EXIT_BY_KEY="fake-secret-a=1|fake-secret-b=0"
  export STUB_ENGINE_RESPONSE_BY_KEY="fake-secret-a=429 too many requests|fake-secret-b=ok"
  _source_engine gemini

  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  run jq -r 'select(.kind == "gemini_attempt") | "\(.key_index) \(.model) \(.rejected)"' "$TOKEN_LOG_FILE"
  [ "$output" = "1 gemini-3.8-flash true" ]
  run jq -r 'select(.kind == "gemini_rejection_sample") | .sample' "$TOKEN_LOG_FILE"
  [[ "$output" == *"429 too many requests"* ]]
  ! grep -q "fake-secret" "$TOKEN_LOG_FILE" || false

  # A second identical rejection adds an attempt but no second sample.
  : > "$KEY_RECORD"
  export GEMINI_QUOTA_NOW=$(( NOW + 7200 ))
  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$(jq -r 'select(.kind == "gemini_attempt")' "$TOKEN_LOG_FILE" | jq -s length)" = "2" ]
  [ "$(jq -r 'select(.kind == "gemini_rejection_sample")' "$TOKEN_LOG_FILE" | jq -s length)" = "1" ]
}

@test "attempts: a sample line has configured key values and token formats redacted" {
  export GOOGLE_API_KEY_3="fake-secret-c"
  _source_lib
  local aiza_key
  aiza_key="AI""za0123456789$(printf '%025d' 0)"
  run _gq_redact_line "error for fake-secret-c and ${aiza_key} end"
  [[ "$output" != *"fake-secret-c"* ]]
  [[ "$output" != *"AIza0123456789"* ]]
  [[ "$output" == *"end"* ]]
}

# ── scope 7: escalating cooldown ──────────────────────────────────────────────

@test "escalation: consecutive rejections double the cooldown, capped at the next Pacific reset" {
  _caps "1 m-a free 10 none 1000"
  _source_lib
  run gq_escalated_cooldown 1 m-a 60 default minute
  [ "${output%%$'\t'*}" = "60" ]
  _attempt_at 1 m-a $(( NOW - 100 ))
  run gq_escalated_cooldown 1 m-a 60 default minute
  [ "${output%%$'\t'*}" = "120" ]
  _attempt_at 1 m-a $(( NOW - 50 ))
  run gq_escalated_cooldown 1 m-a 60 default minute
  [ "${output%%$'\t'*}" = "240" ]
  # Many consecutive rejections: capped at the next reset (12:00 PDT → 00:00 PDT = 12h).
  local i; for i in $(seq 1 20); do _attempt_at 1 m-a $(( NOW - 40 + i )); done
  run gq_escalated_cooldown 1 m-a 60 default minute
  [ "${output%%$'\t'*}" = "$(( DAY_END - NOW ))" ]
}

@test "escalation: a success resets the streak" {
  _caps "1 m-a free 10 none 1000"
  _attempt_at 1 m-a $(( NOW - 300 ))
  _attempt_at 1 m-a $(( NOW - 200 ))
  _call_at 1 m-a $(( NOW - 100 ))
  _source_lib
  run gq_escalated_cooldown 1 m-a 60 default minute
  [ "${output%%$'\t'*}" = "60" ]
  _attempt_at 1 m-a $(( NOW - 50 ))
  run gq_escalated_cooldown 1 m-a 60 default minute
  [ "${output%%$'\t'*}" = "120" ]
}

@test "escalation: the streak is per key and per model, and restarts at the daily reset" {
  _caps "1 * free 10 none 1000" "2 * free 10 none 1000"
  _attempt_at 1 m-b $(( NOW - 100 ))
  _attempt_at 2 m-a $(( NOW - 100 ))
  _attempt_at 1 m-a $(( DAY_START - 100 ))   # yesterday (Pacific)
  _source_lib
  run gq_escalated_cooldown 1 m-a 60 default minute
  [ "${output%%$'\t'*}" = "60" ]
}

@test "escalation: a rejection at an already-reached daily cap jumps to the reset" {
  _caps "1 m-a free none none 20"
  _calls 20 1 m-a $(( NOW - 3600 ))
  _source_lib
  run gq_escalated_cooldown 1 m-a 60 default minute
  [ "${output%%$'\t'*}" = "$(( DAY_END - NOW ))" ]
  [[ "$output" == *"daily cap"* ]]
}

@test "escalation: the engine records the doubled cooldown on the second rejection" {
  export GOOGLE_API_KEY="fake-secret-a" GOOGLE_API_KEY_2="fake-secret-b"
  export STUB_ENGINE_EXIT_BY_KEY="fake-secret-a=1|fake-secret-b=0"
  export STUB_ENGINE_RESPONSE_BY_KEY="fake-secret-a=429 too many requests|fake-secret-b=ok"
  _caps "1 gemini-3.8-flash free 10 none 1000" "2 gemini-3.8-flash free 10 none 1000"
  _source_engine gemini

  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  export GEMINI_QUOTA_NOW=$(( NOW + 61 ))   # first cooldown (60s default) has elapsed
  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  run jq -r 'select(.kind == "gemini_key_cooldown") | .until' "$TOKEN_LOG_FILE"
  [ "$output" = "$(( NOW + 60 ))"$'\n'"$(( NOW + 61 + 120 ))" ]
}

# ── scope 9: rotation never calls a key/model that cannot run ─────────────────

@test "rotation: a cap-0 key is not called for that model but is used for another it has capacity for" {
  _caps "1 gemini-3.1-pro-preview free 5 none 0" "1 gemini-3.8-flash free 10 none 20"
  export GOOGLE_API_KEY="fake-secret-a"
  export STUB_ENGINE_EXIT=0 STUB_ENGINE_RECORD_MODELS="$MODEL_RECORD"
  _source_engine gemini

  run _gemini_chain_invoke "gemini-3.1-pro-preview,gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  [ "$(cat "$MODEL_RECORD")" = "gemini-3.8-flash" ]
  [ "$(cat "$KEY_RECORD")" = "fake-secret-a" ]
  [[ "$output" == *"key index 1"*"unavailable"* ]]
  [[ "$output" != *"fake-secret"* ]]
}

@test "rotation: gq_rotation_plan reports a dropped key as skip with the reason" {
  _caps "1 m-a free 5 none 0" "2 m-a free 5 none 20"
  export GOOGLE_API_KEY="fake-secret-a" GOOGLE_API_KEY_2="fake-secret-b"
  _source_lib
  run gq_rotation_plan m-a 75 GOOGLE_API_KEY GOOGLE_API_KEY_2
  [[ "$output" == *$'skip\tGOOGLE_API_KEY\t1\t'*"unavailable"* ]]
  [[ "$output" == *$'use\tGOOGLE_API_KEY_2\t2'* ]]
  [[ "$output" != *$'use\tGOOGLE_API_KEY\t'* ]]
}

@test "rotation: an exhausted key is not called until the Pacific reset" {
  _caps "1 gemini-3.8-flash free none none 20" "2 gemini-3.8-flash free none none 20"
  _calls 20 1 gemini-3.8-flash $(( NOW - 3600 ))
  export GOOGLE_API_KEY="fake-secret-a" GOOGLE_API_KEY_2="fake-secret-b"
  export STUB_ENGINE_EXIT=0
  _source_engine gemini

  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  [ "$(cat "$KEY_RECORD")" = "fake-secret-b" ]
  [[ "$output" == *"key index 1"*"exhausted"* ]]

  # Just before the reset it is still dropped …
  : > "$KEY_RECORD"
  export GEMINI_QUOTA_NOW=$(( DAY_END - 1 ))
  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$(head -1 "$KEY_RECORD")" = "fake-secret-b" ]
  # … and after it, key 1 is back at the front.
  : > "$KEY_RECORD"
  export GEMINI_QUOTA_NOW=$(( DAY_END + 1 ))
  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  [ "$(head -1 "$KEY_RECORD")" = "fake-secret-a" ]
}

@test "rotation: an unknown key is still tried (no new hard block)" {
  # The shipped caps are filled (#2146), so edit every row of a copy back to `unknown`.
  awk -F'\t' -v OFS='\t' '!/^[[:space:]]*#/ && NF >= 6 && $1 != "setting" { $3 = $4 = $5 = $6 = "unknown" }
    { print }' "$SCRIPT_DIR/scripts/lib/gemini-quota-caps.tsv" > "$GEMINI_QUOTA_CAPS"
  grep -q "unknown" "$GEMINI_QUOTA_CAPS"
  export GOOGLE_API_KEY="fake-secret-a"
  export STUB_ENGINE_EXIT=0
  _source_engine gemini

  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  [ "$(cat "$KEY_RECORD")" = "fake-secret-a" ]
}

@test "rotation: a key merely over the threshold is still tried last, not dropped" {
  _caps "1 gemini-3.8-flash free 10 none none" "2 gemini-3.8-flash free 10 none none"
  _calls 8 1 gemini-3.8-flash $(( NOW - 5 ))
  export GOOGLE_API_KEY="fake-secret-a" GOOGLE_API_KEY_2="fake-secret-b"
  export STUB_ENGINE_EXIT_BY_KEY="fake-secret-a=0|fake-secret-b=1"
  export STUB_ENGINE_RESPONSE_BY_KEY="fake-secret-a=ok|fake-secret-b=429 too many requests"
  _source_engine gemini

  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  [ "$(cat "$KEY_RECORD")" = "fake-secret-b"$'\n'"fake-secret-a" ]
}

@test "rotation: every key dropped for a model → no call, the chain moves to the next model" {
  _caps "1 gemini-3.1-pro-preview free 5 none 0" "1 gemini-3.8-flash free 10 none 20"
  export GOOGLE_API_KEY="fake-secret-a"
  export STUB_ENGINE_EXIT=0 STUB_ENGINE_RECORD_MODELS="$MODEL_RECORD"
  _source_engine gemini

  run _gemini_chain_invoke "gemini-3.1-pro-preview" "$TEST_PROMPT" 30
  [ "$status" -eq 2 ]
  [ ! -s "$KEY_RECORD" ]

  run _gemini_chain_invoke "gemini-3.1-pro-preview,gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  [ "$(cat "$MODEL_RECORD")" = "gemini-3.8-flash" ]
}

# ── scope 2: tier view ────────────────────────────────────────────────────────

# A mocked chain: tier logic must read ai_models_gemini_chain, so fake model ids
# that appear nowhere in the code drive every status below.
_mock_chain() {
  ai_models_gemini_chain() {
    case "$1" in
      deep|audit|single) printf 'zz-pro-x,zz-flash-y' ;;
      triage|action)     printf 'zz-flash-y,zz-pro-x' ;;
      duck)              printf 'zz-flash-y' ;;
    esac
  }
}

@test "tier: first-choice model usable → available, with usable pairs and total remaining" {
  _caps "1 zz-pro-x free 5 none 10" "2 zz-pro-x free 5 none 10" \
        "1 zz-flash-y free 10 none 20" "2 zz-flash-y free 10 none 20"
  _calls 4 2 zz-pro-x $(( NOW - 3600 ))
  _source_lib; _mock_chain
  run gq_tier_view deep 1 2
  [ "$status" -eq 0 ]
  [ "$(jq -r .status <<< "$output")" = "available" ]
  [ "$(jq -r .first_choice <<< "$output")" = "zz-pro-x" ]
  [ "$(jq -r .serving_model <<< "$output")" = "zz-pro-x" ]
  [ "$(jq -r .degraded_to <<< "$output")" = "null" ]
  [ "$(jq -c .chain <<< "$output")" = '["zz-pro-x","zz-flash-y"]' ]
  # Usable: pro on keys 1 (10) and 2 (6), flash on keys 1 and 2 (20 each).
  [ "$(jq -r '.usable | length' <<< "$output")" = "4" ]
  [ "$(jq -r .remaining_calls <<< "$output")" = "56" ]
}

@test "tier: first model capped but a later one free → degraded, naming the model" {
  _caps "1 zz-pro-x free 5 none 0" "2 zz-pro-x free 5 none 0" \
        "1 zz-flash-y free 10 none 20" "2 zz-flash-y free 10 none 20"
  _calls 20 1 zz-flash-y $(( NOW - 3600 ))
  _source_lib; _mock_chain
  run gq_tier_view deep 1 2
  [ "$(jq -r .status <<< "$output")" = "degraded" ]
  [ "$(jq -r .degraded_to <<< "$output")" = "zz-flash-y" ]
  [ "$(jq -r .serving_model <<< "$output")" = "zz-flash-y" ]
  [ "$(jq -c '[.usable[] | "\(.model):\(.key_index)"]' <<< "$output")" = '["zz-flash-y:2"]' ]
  [ "$(jq -r .remaining_calls <<< "$output")" = "20" ]
  # The same caps leave a flash-first tier fully available.
  run gq_tier_view triage 1 2
  [ "$(jq -r .status <<< "$output")" = "available" ]
}

@test "tier: every model in the chain capped or exhausted → unavailable with zero remaining" {
  _caps "1 zz-pro-x free 5 none 0" "1 zz-flash-y free 10 none 3"
  _calls 3 1 zz-flash-y $(( NOW - 3600 ))
  _source_lib; _mock_chain
  run gq_tier_view audit 1
  [ "$(jq -r .status <<< "$output")" = "unavailable" ]
  [ "$(jq -r .remaining_calls <<< "$output")" = "0" ]
  [ "$(jq -r '.usable | length' <<< "$output")" = "0" ]
  [ "$(jq -r .serving_model <<< "$output")" = "null" ]
  [ "$(jq -r .recovers_at <<< "$output")" = "$DAY_END" ]
}

@test "tier: caps not filled → unknown" {
  _caps "1 zz-pro-x unknown unknown unknown unknown" "1 zz-flash-y unknown unknown unknown unknown"
  _source_lib; _mock_chain
  run gq_tier_view single 1
  [ "$(jq -r .status <<< "$output")" = "unknown" ]
  [ "$(jq -r .remaining_calls <<< "$output")" = "null" ]
}

@test "tier: the chain comes from ai_models_gemini_chain (a configured chain changes the view)" {
  _caps "1 gemini-3.8-flash free 10 none 20" "1 gemini-3.1-pro-preview free 5 none 0"
  _source_lib
  run gq_tier_view deep 1
  [ "$(jq -r .status <<< "$output")" = "degraded" ]
  export GEMINI_PRO_MODEL_CHAIN="gemini-3.8-flash"
  run gq_tier_view deep 1
  [ "$(jq -r .status <<< "$output")" = "available" ]
  [ "$(jq -c .chain <<< "$output")" = '["gemini-3.8-flash"]' ]
}

@test "tier: the tier logic hard-codes no model id" {
  # Body of every tier/snapshot function in the library: no gemini model literal.
  run awk '/^(gq_tier_view|_gq_tier_from_pairs|gq_tier_snapshot|gq_tier_list|gq_tier_notices)\(\)/ { f = 1 }
    f && !/^[[:space:]]*#/ { print } f && /^}/ { f = 0 }' "$QUOTA_LIB"
  [ -n "$output" ]
  [[ "$output" == *"ai_models_gemini_chain"* ]]
  [[ ! "$output" =~ gemini-[0-9] ]]
  [[ ! "$output" =~ (flash|pro-preview) ]]
}

@test "tier: the tier list covers triage, action, deep, audit, single and duck" {
  _source_lib
  run gq_tier_list
  for t in triage action deep audit single duck; do [[ " $output " == *" $t "* ]]; done
}

# ── scope 4: snapshot ─────────────────────────────────────────────────────────

@test "snapshot: validates against the documented schema and carries indexes only" {
  _caps "1 gemini-3.8-flash free 10 none 20" "1 gemini-3.1-pro-preview free 5 none 0" \
        "2 gemini-3.8-flash unknown unknown unknown unknown" "2 gemini-3.1-pro-preview free 5 none 10"
  export GOOGLE_API_KEY="fake-secret-a" GOOGLE_API_KEY_2="fake-secret-b" GEMINI_API_KEY="fake-secret-g"
  _calls 2 1 gemini-3.8-flash $(( NOW - 60 ))
  _source_lib
  local snap="$BATS_TEST_TMPDIR/snap.json"
  gq_tier_snapshot > "$snap"
  [ -f "$SCHEMA" ]
  run python3 -c '
import json, sys, jsonschema
jsonschema.validate(json.load(open(sys.argv[1])), json.load(open(sys.argv[2])))
print("valid")' "$snap" "$SCHEMA"
  [ "$status" -eq 0 ]
  [ "$output" = "valid" ]
  [ "$(jq -r '.tiers | length' "$snap")" = "6" ]
  [ "$(jq -r '.window.day_start' "$snap")" = "$DAY_START" ]
  [ "$(jq -r '.window.day_end' "$snap")" = "$DAY_END" ]
  [ "$(jq -r '.generated_epoch' "$snap")" = "$NOW" ]
  # No key value anywhere — only indexes.
  ! grep -q "fake-secret" "$snap" || false
  [ "$(jq -r '[.tiers[].pairs[].key_index] | unique | join(",")' "$snap")" = "1,2" ]
}

@test "snapshot: the schema rejects a snapshot carrying a key value field" {
  _caps "1 gemini-3.8-flash free 10 none 20"
  _source_lib
  local snap="$BATS_TEST_TMPDIR/snap.json"
  gq_tier_snapshot | jq '.tiers[0].pairs[0].key = "AIzaXXXX"' > "$snap"
  run python3 -c '
import json, sys, jsonschema
jsonschema.validate(json.load(open(sys.argv[1])), json.load(open(sys.argv[2])))' "$snap" "$SCHEMA"
  [ "$status" -ne 0 ]
}

@test "snapshot: gq_tier_can_run reads a snapshot (the dry-run poller's question)" {
  _caps "1 gemini-3.8-flash free 10 none 20" "1 gemini-3.1-pro-preview free 5 none 0"
  _source_lib
  local snap="$BATS_TEST_TMPDIR/snap.json"
  gq_tier_snapshot > "$snap"
  run gq_tier_can_run "$snap" triage
  [ "$status" -eq 0 ]
  [ "$output" = "available" ]
  run gq_tier_can_run "$snap" deep
  [ "$status" -eq 0 ]
  [[ "$output" == "degraded"* ]]
  jq '.tiers |= map(.status = "unavailable")' "$snap" > "$snap.2"
  run gq_tier_can_run "$snap.2" deep
  [ "$status" -eq 1 ]
  run gq_tier_can_run "$BATS_TEST_TMPDIR/missing.json" deep
  [ "$status" -eq 2 ]
}

# ── scope 5: once-per-tier-per-day notice ─────────────────────────────────────

@test "notice: degraded/unavailable tiers notify once per tier per Pacific day" {
  _caps "1 gemini-3.8-flash free 10 none 20" "1 gemini-3.1-pro-preview free 5 none 0"
  _source_lib
  local snap="$BATS_TEST_TMPDIR/snap.json" state="$BATS_TEST_TMPDIR/state.jsonl"
  gq_tier_snapshot > "$snap"
  run gq_tier_notices "$snap" "$state"
  [ "$(grep -c '::warning::' <<< "$output")" = "3" ]   # deep, audit, single
  [[ "$output" == *"deep"*"degraded"*"gemini-3.8-flash"* ]]
  [[ "$output" != *"triage"* ]]

  # A second run the same Pacific day repeats nothing.
  export GEMINI_QUOTA_NOW=$(( NOW + 3600 * 6 ))
  gq_tier_snapshot > "$snap"
  run gq_tier_notices "$snap" "$state"
  [ -z "$output" ]

  # The next Pacific day notifies again.
  export GEMINI_QUOTA_NOW=$(( DAY_END + 3600 ))
  gq_tier_snapshot > "$snap"
  run gq_tier_notices "$snap" "$state"
  [ "$(grep -c '::warning::' <<< "$output")" = "3" ]
}

# ── scope 3: per-day history ──────────────────────────────────────────────────

@test "history: per-day key × model matrix with calls, peak/min, rate-limit events, cap hit" {
  _caps "1 m-a free 10 none 3" "2 m-a free 10 none 100"
  _calls 3 1 m-a $(( NOW - 3570 ))                  # today, one minute bucket: hits rpd 3
  _attempt_at 1 m-a $(( NOW - 1800 ))
  _source_lib
  gq_record_cooldown 1 m-a 60 test
  _calls 2 2 m-a $(( DAY_START - 3600 ))            # yesterday
  run gq_day_history 7
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" = "8" ]
  [ "$(jq -r '.[0].day' <<< "$output")" = "2026-10-09" ]
  [ "$(jq -r '.[1].day' <<< "$output")" = "2026-10-08" ]
  local t; t="$(jq -c '.[0].rows[] | select(.key_index == "1" and .model == "m-a")' <<< "$output")"
  [ "$(jq -r .calls <<< "$t")" = "3" ]
  [ "$(jq -r .rejected <<< "$t")" = "1" ]
  [ "$(jq -r .peak_per_min <<< "$t")" = "3" ]
  [ "$(jq -r .rate_limit_events <<< "$t")" = "1" ]
  [ "$(jq -r .cap_hit <<< "$t")" = "true" ]
  local y; y="$(jq -c '.[1].rows[] | select(.key_index == "2")' <<< "$output")"
  [ "$(jq -r .calls <<< "$y")" = "2" ]
  [ "$(jq -r .cap_hit <<< "$y")" = "false" ]
}

@test "history: a tokens-per-minute cap reached in one minute counts as a cap hit" {
  _caps "1 m-a free 100 500 1000"
  _call_at 1 m-a $(( NOW - 3570 )) 600
  _source_lib
  run gq_day_history 7
  [ "$status" -eq 0 ]
  local t; t="$(jq -c '.[0].rows[] | select(.key_index == "1" and .model == "m-a")' <<< "$output")"
  [ "$(jq -r .calls <<< "$t")" = "1" ]
  [ "$(jq -r .cap_hit <<< "$t")" = "true" ]
}

@test "history store: survives across runs and is bounded by the retention setting" {
  _caps "1 m-a free 10 none 100"
  source "$TIER_REPORT"
  local dir="$BATS_TEST_TMPDIR/state" in1="$BATS_TEST_TMPDIR/in1.jsonl" in2="$BATS_TEST_TMPDIR/in2.jsonl"
  mkdir -p "$dir"
  # Run 1 sees a call 10 days ago, one yesterday and one today.
  TOKEN_LOG_FILE="$in1" _call_at 1 m-a $(( NOW - 86400 * 10 ))
  TOKEN_LOG_FILE="$in1" _call_at 1 m-a $(( NOW - 86400 ))
  TOKEN_LOG_FILE="$in1" _call_at 1 m-a $(( NOW - 60 ))
  export GEMINI_HISTORY_DAYS=7
  gtr_merge_store "$dir/history.jsonl" "$in1"
  # The 10-day-old record is past retention (today + 7 previous days).
  [ "$(jq -s length "$dir/history.jsonl")" = "2" ]
  # Run 2 (a later run, same store) re-collects one record it already had plus a new one.
  TOKEN_LOG_FILE="$in2" _call_at 1 m-a $(( NOW - 60 ))
  TOKEN_LOG_FILE="$in2" _call_at 1 m-a $(( NOW - 30 ))
  gtr_merge_store "$dir/history.jsonl" "$in2"
  [ "$(jq -s length "$dir/history.jsonl")" = "3" ]
  export GEMINI_LEDGER_FILE="$dir/history.jsonl"
  run gq_day_history 7
  [ "$(jq -r '.[0].rows[0].calls' <<< "$output")" = "2" ]
  [ "$(jq -r '.[1].rows[0].calls' <<< "$output")" = "1" ]
  # A shorter retention prunes the store on the next merge.
  export GEMINI_HISTORY_DAYS=0
  gtr_merge_store "$dir/history.jsonl" /dev/null
  [ "$(jq -s length "$dir/history.jsonl")" = "2" ]
}

@test "report: renders the tier view, history, samples and the ledger-only limitation" {
  _caps "1 gemini-3.8-flash free 10 none 20" "1 gemini-3.1-pro-preview free 5 none 0"
  local dir="$BATS_TEST_TMPDIR/state" in="$BATS_TEST_TMPDIR/in.jsonl"
  TOKEN_LOG_FILE="$in" _calls 4 1 gemini-3.8-flash $(( NOW - 600 ))
  printf '%s\n' "$(jq -cn --arg ts "$(_iso $(( NOW - 300 )))" '{kind:"gemini_rejection_sample", ts:$ts, engine:"gemini",
    key_index:1, model:"gemini-3.8-flash", scope:"minute", sample:"sample text one", norm:"sample text one"}')" >> "$in"
  export GEMINI_TIER_STATE_DIR="$dir" GEMINI_RECORDS_IN="$in"
  run bash "$TIER_REPORT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Gemini availability per task tier"* ]]
  [[ "$output" == *"| deep | degraded"* ]]
  [[ "$output" == *'`gemini-3.1-pro-preview` | unavailable (cap 0) | 0 |'* ]]
  [[ "$output" == *"gemini-3.8-flash"* ]]
  [[ "$output" == *"AI Studio"* ]]
  [[ "$output" == *"ledger"* ]]
  [[ "$output" == *"sample text one"* ]]
  [[ "$output" == *"2026-10-09"* ]]
  [ -f "$dir/snapshot.json" ]
  [ -f "$dir/history.jsonl" ]
  [ ! -e "$CURL_RECORD" ]
  # A second run the same day re-renders but does not repeat the notices.
  run bash "$TIER_REPORT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::warning::"* ]]
}

@test "report: the tier report script makes no network or Gemini API call" {
  run grep -nEi 'curl|wget|https?://|generativelanguage|/dev/tcp' "$TIER_REPORT"
  [ "$status" -eq 1 ]
}

# ── review follow-ups (#2150) ─────────────────────────────────────────────────

@test "rotation: a key at its per-minute cap is skipped as cooling; an unknown key is still used" {
  _caps "1 m-a free 3 none 20"
  _call_at 1 m-a $(( NOW - 40 ))
  _call_at 1 m-a $(( NOW - 20 ))
  _call_at 1 m-a $(( NOW - 10 ))
  export GOOGLE_API_KEY="fake-secret-a" GOOGLE_API_KEY_2="fake-secret-b"
  _source_lib
  run gq_rotation_plan m-a 75 GOOGLE_API_KEY GOOGLE_API_KEY_2
  [[ "$output" == *$'skip\tGOOGLE_API_KEY\t1\t'* ]]
  [[ "$output" != *$'use\tGOOGLE_API_KEY\t'* ]]
  # key 2 has no caps row → unknown → still tried.
  [[ "$output" == *$'use\tGOOGLE_API_KEY_2\t2'* ]]
}

@test "attempts: 413 and 402 rejections record no attempt and no sample; a 429 records exactly one" {
  export GOOGLE_API_KEY="fake-secret-a"
  export STUB_ENGINE_EXIT_BY_KEY="fake-secret-a=1"
  _source_engine gemini
  local resp
  for resp in "413 request body too large" "402 payment required"; do
    : > "$TOKEN_LOG_FILE"
    export STUB_ENGINE_RESPONSE_BY_KEY="fake-secret-a=$resp"
    run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
    [ "$(grep -c '"gemini_attempt"' "$TOKEN_LOG_FILE" || true)" = "0" ]
    [ "$(grep -c '"gemini_rejection_sample"' "$TOKEN_LOG_FILE" || true)" = "0" ]
  done
  : > "$TOKEN_LOG_FILE"
  export STUB_ENGINE_RESPONSE_BY_KEY="fake-secret-a=429 too many requests"
  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30
  [ "$(grep -c '"gemini_attempt"' "$TOKEN_LOG_FILE")" = "1" ]
}

@test "attempts: a number merely containing 429 is not a quota rejection" {
  _source_lib
  local f="$BATS_TEST_TMPDIR/err"
  echo "request id 14293 failed" > "$f"
  ! gq_is_quota_rejection "$f" || false
  echo "HTTP 429" > "$f"
  gq_is_quota_rejection "$f"
}

@test "ledger: a gemini_attempt with a bad timestamp makes the ledger untrusted" {
  _caps "1 m-a free 10 none 20"
  printf '{"kind":"gemini_attempt","engine":"gemini","key_index":1,"model":"m-a"}\n' >> "$TOKEN_LOG_FILE"
  _source_lib
  run gq_remaining 1 m-a
  [ "$(jq -r .state <<< "$output")" = "unknown" ]
}

@test "history: a pipe in a model name is escaped in the table; a plain name is unchanged" {
  _caps "1 weird|name free 10 none 20" "1 gemini-3.8-flash free 10 none 20"
  local dir="$BATS_TEST_TMPDIR/state" in="$BATS_TEST_TMPDIR/in.jsonl"
  TOKEN_LOG_FILE="$in" _call_at 1 "weird|name" $(( NOW - 60 ))
  TOKEN_LOG_FILE="$in" _call_at 1 gemini-3.8-flash $(( NOW - 30 ))
  export GEMINI_TIER_STATE_DIR="$dir" GEMINI_RECORDS_IN="$in"
  run bash "$TIER_REPORT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'| `weird\|name` | 1 |'* ]]
  [[ "$output" == *'| `gemini-3.8-flash` | 1 |'* ]]
}

@test "report: a forged rejection sample is redacted, capped and shape-checked at render time" {
  _caps "1 m-a free 10 none 20"
  local dir="$BATS_TEST_TMPDIR/state" in="$BATS_TEST_TMPDIR/in.jsonl" key
  key="AI""za0123456789$(printf '%025d' 0)"
  jq -cn --arg ts "$(_iso $(( NOW - 300 )))" --arg s "boom $key end" \
    '{kind:"gemini_rejection_sample", ts:$ts, engine:"gemini", key_index:1, model:"m-a", scope:"minute", sample:$s}' >> "$in"
  jq -cn --arg ts "$(_iso $(( NOW - 200 )))" \
    '{kind:"gemini_rejection_sample", ts:$ts, engine:"gemini", key_index:"x", model:"m-a", scope:"minute", sample:"bad-shape-row"}' >> "$in"
  export GEMINI_TIER_STATE_DIR="$dir" GEMINI_RECORDS_IN="$in"
  run bash "$TIER_REPORT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$key"* ]]
  [[ "$output" == *"end"* ]]
  [[ "$output" != *"bad-shape-row"* ]]
}

@test "store: a record with a malformed key index is dropped at merge and never reaches the summary" {
  _caps "1 m-a free 10 none 20"
  local dir="$BATS_TEST_TMPDIR/state" in="$BATS_TEST_TMPDIR/in.jsonl"
  TOKEN_LOG_FILE="$in" _call_at 1 m-a $(( NOW - 60 ))
  # Forged records from an untrusted artifact: a string key index carrying a table
  # break and a link, an object, and a legitimate digits-plus-suffix index.
  jq -cn --arg ts "$(_iso $(( NOW - 50 )))" \
    '{kind:"token_usage", ts:$ts, engine:"gemini", key_index:"1 | [click](https://evil.example)", model:"m-a", total_tokens:5}' >> "$in"
  jq -cn --arg ts "$(_iso $(( NOW - 40 )))" \
    '{kind:"gemini_attempt", ts:$ts, engine:"gemini", key_index:{"a":1}, model:"m-a", rejected:true}' >> "$in"
  jq -cn --arg ts "$(_iso $(( NOW - 30 )))" \
    '{kind:"token_usage", ts:$ts, engine:"gemini", key_index:"2b", model:"m-a", total_tokens:5}' >> "$in"
  export GEMINI_TIER_STATE_DIR="$dir" GEMINI_RECORDS_IN="$in"
  run bash "$TIER_REPORT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"evil.example"* ]]
  [[ "$output" != *"click"* ]]
  ! grep -q 'evil.example' "$dir/history.jsonl"
  ! grep -q '"key_index":{' "$dir/history.jsonl"
  # The well-formed records survive.
  grep -q '"key_index":1' "$dir/history.jsonl"
  grep -q '"key_index":"2b"' "$dir/history.jsonl"
}

@test "store: a failing merge leaves the retained store untouched" {
  source "$TIER_REPORT"
  local dir="$BATS_TEST_TMPDIR/state" in="$BATS_TEST_TMPDIR/in.jsonl"
  mkdir -p "$dir"
  TOKEN_LOG_FILE="$in" _call_at 1 m-a $(( NOW - 60 ))
  gtr_merge_store "$dir/history.jsonl" "$in"
  local before; before="$(cat "$dir/history.jsonl")"
  [ -n "$before" ]
  jq() { return 5; }
  run gtr_merge_store "$dir/history.jsonl" "$in"
  unset -f jq
  [ "$status" -ne 0 ]
  [ "$(cat "$dir/history.jsonl")" = "$before" ]
}

@test "report: backticks and pipes in a forged model or scope cannot break out of the table cell" {
  _caps "1 m-a free 10 none 20"
  local dir="$BATS_TEST_TMPDIR/state" in="$BATS_TEST_TMPDIR/in.jsonl"
  jq -cn --arg ts "$(_iso $(( NOW - 300 )))" \
    '{kind:"gemini_rejection_sample", ts:$ts, engine:"gemini", key_index:1, model:"m`x|y", scope:"mi`n|z", sample:"s"}' >> "$in"
  TOKEN_LOG_FILE="$in" _call_at 1 'h`m' $(( NOW - 60 ))
  export GEMINI_TIER_STATE_DIR="$dir" GEMINI_RECORDS_IN="$in"
  run bash "$TIER_REPORT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"| \`m'x\\|y\` | mi'n\\|z |"* ]]
  [[ "$output" == *"\`h'm\`"* ]]
}

@test "history: a backslash before a pipe in a model name cannot unescape the pipe" {
  _caps 'x\|y free 10 none 20'
  local dir="$BATS_TEST_TMPDIR/state" in="$BATS_TEST_TMPDIR/in.jsonl"
  TOKEN_LOG_FILE="$in" _call_at 1 'x\|y' $(( NOW - 60 ))
  export GEMINI_TIER_STATE_DIR="$dir" GEMINI_RECORDS_IN="$in"
  run bash "$TIER_REPORT"
  [ "$status" -eq 0 ]
  # an odd run of backslashes before the pipe: the pipe stays escaped in the cell
  local re='\| 2026-[0-9-]+ \| 1 \| `x(\\\\)*\\\|y` \| 1 \|'
  [[ "$output" =~ $re ]]
}
