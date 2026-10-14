#!/usr/bin/env bats
# Tests for the unparsed rate-limit sample capture (#2140, split 2 of #1863):
# when the reset parser cannot read a rate-limit message, one redacted, truncated
# sample per message shape is recorded to the token ledger (kind
# "rate_limit_sample") and rendered by fleet_report.sh's
# generate_rate_limit_samples_report.
#
# Run with: bats tests/test_rate_limit_samples.bats

setup() {
  export REVIEW_ENGINE="claude"
  # Sidecars go to this test's directory, not the /tmp every session shares (#2271).
  export DEV_LEAD_SIDECAR_DIR="$BATS_TEST_TMPDIR"
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/engine.sh" >/dev/null 2>&1 || true
  # shellcheck source=scripts/fleet_report.sh
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/fleet_report.sh"
  TOKEN_LOG_FILE="$BATS_TEST_TMPDIR/ledger.jsonl"
  export TOKEN_LOG_FILE
  export GITHUB_RUN_ID="4242"
  export TOKEN_WORKFLOW="dev-lead"
  : > "$TOKEN_LOG_FILE"
  CAPTURE="$BATS_TEST_TMPDIR/capture.txt"
}

_samples() {
  jq -c 'select(.kind == "rate_limit_sample")' "$TOKEN_LOG_FILE"
}

# ---------------------------------------------------------------------------
# Capture (AC #1, #2)
# ---------------------------------------------------------------------------

@test "unparsed rate-limit message is recorded once with the matching line only" {
  printf '%s\n' "starting review" \
    "You've hit your weekly limit · resets Mon 9am" \
    "trailing noise" > "$CAPTURE"
  parse_reset_time_files "$CAPTURE"
  [ "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-rate-limit-reset")" = "" ]
  [ "$(_samples | wc -l)" -eq 1 ]
  sample="$(_samples | jq -r '.sample')"
  [[ "$sample" == *"hit your weekly limit"* ]]
  [[ "$sample" != *"starting review"* ]]
  [[ "$sample" != *"trailing noise"* ]]
  [ "$(_samples | jq -r '.run_id')" = "4242" ]
  [ "$(_samples | jq -r '.workflow')" = "dev-lead" ]
  [ -n "$(_samples | jq -r '.shape')" ]
}

@test "the same message shape is recorded once per run, not once per attempt" {
  printf '%s\n' "You've hit your weekly limit · resets Mon 9am" > "$CAPTURE"
  parse_reset_time_files "$CAPTURE"
  parse_reset_time_files "$CAPTURE"
  # Same shape, different numbers → still one record.
  printf '%s\n' "You've hit your weekly limit · resets Mon 10am" > "$CAPTURE"
  parse_reset_time_files "$CAPTURE"
  parse_reset_time "You've hit your weekly limit · resets Mon 9am"
  [ "$(_samples | wc -l)" -eq 1 ]
}

@test "a single-line JSON envelope is unwrapped to its .result text" {
  printf '%s\n' '{"type":"result","is_error":true,"result":"You'"'"'ve hit your weekly limit · resets Mon 9am"}' > "$CAPTURE"
  parse_reset_time_files "$CAPTURE"
  [ "$(_samples | wc -l)" -eq 1 ]
  sample="$(_samples | jq -r '.sample')"
  [[ "$sample" == *"hit your weekly limit"* ]]
  [[ "$sample" != *'"type"'* ]]
}

@test "JSON stdout followed by a plain-text stderr line is still recorded" {
  printf '%s\n' '{"type":"result","result":"working"}' \
    "You've hit your weekly limit · resets Mon 9am" > "$CAPTURE"
  parse_reset_time_files "$CAPTURE"
  [ "$(_samples | wc -l)" -eq 1 ]
  [[ "$(_samples | jq -r '.sample')" == *"hit your weekly limit"* ]]
}

@test "distinct message shapes are each recorded" {
  printf '%s\n' "You've hit your weekly limit · resets Mon 9am" > "$CAPTURE"
  parse_reset_time_files "$CAPTURE"
  parse_reset_time "429 Too Many Requests: quota exceeded"
  [ "$(_samples | wc -l)" -eq 2 ]
}

@test "a message the parser reads is not recorded" {
  printf '%s\n' "You've hit your limit · resets 11:20pm (UTC)" > "$CAPTURE"
  parse_reset_time_files "$CAPTURE"
  [ -n "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-rate-limit-reset")" ]
  parse_reset_time "You've hit your limit · resets 3:05am (UTC)"
  [ -n "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-rate-limit-reset")" ]
  [ "$(_samples | wc -l)" -eq 0 ]
}

@test "output with no rate-limit line is not recorded" {
  printf '%s\n' "segfault in worker" > "$CAPTURE"
  parse_reset_time_files "$CAPTURE"
  [ "$(_samples | wc -l)" -eq 0 ]
}

@test "the recorded sample is truncated to a safe length" {
  long="$(printf 'x%.0s' $(seq 1 3000))"
  printf '%s\n' "usage limit reached ${long}" > "$CAPTURE"
  parse_reset_time_files "$CAPTURE"
  [ "$(_samples | wc -l)" -eq 1 ]
  len="$(_samples | jq -r '.sample | length')"
  [ "$len" -le "$RATE_LIMIT_SAMPLE_MAX_BYTES" ]
  [ "$len" -gt 0 ]
}

@test "secrets in the message never appear in the recorded sample" {
  fake_gh="ghp_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE1234"
  fake_ant="sk-ant-FAKEFAKEFAKEFAKEFAKEFAKE-0000"
  printf '%s\n' "rate limit exceeded for token ${fake_gh} key ${fake_ant}" > "$CAPTURE"
  parse_reset_time_files "$CAPTURE"
  [ "$(_samples | wc -l)" -eq 1 ]
  run grep -qF "$fake_gh" "$TOKEN_LOG_FILE"
  [ "$status" -eq 1 ]
  run grep -qF "$fake_ant" "$TOKEN_LOG_FILE"
  [ "$status" -eq 1 ]
  run grep -qF "FAKEFAKEFAKE" "$TOKEN_LOG_FILE"
  [ "$status" -eq 1 ]
  _samples | jq -r '.sample' | grep -qF "REDACTED"
}

@test "a secret straddling the truncation point is redacted, not cut into a fragment" {
  pad="$(printf 'y%.0s' $(seq 1 $((RATE_LIMIT_SAMPLE_MAX_BYTES - 31))))"
  fake_gh="ghp_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE1234"
  printf '%s\n' "rate limit ${pad} ${fake_gh}" > "$CAPTURE"
  parse_reset_time_files "$CAPTURE"
  run grep -qF "FAKEFAKE" "$TOKEN_LOG_FILE"
  [ "$status" -eq 1 ]
}

@test "no ledger configured → capture is a no-op" {
  unset TOKEN_LOG_FILE
  printf '%s\n' "You've hit your weekly limit · resets Mon 9am" > "$CAPTURE"
  run parse_reset_time_files "$CAPTURE"
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/ledger.jsonl" ]
}

# ---------------------------------------------------------------------------
# Fleet monitor section (AC #3)
# ---------------------------------------------------------------------------

@test "fleet section renders without samples" {
  printf '%s\n' '{"workflow":"dev-lead","model":"m","et":1}' > "$BATS_TEST_TMPDIR/a.jsonl"
  run generate_rate_limit_samples_report "$BATS_TEST_TMPDIR/a.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unparsed rate-limit messages"* ]]
  [[ "$output" == *"No unparsed rate-limit samples"* ]]
}

@test "fleet section renders with no files at all" {
  run generate_rate_limit_samples_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unparsed rate-limit messages"* ]]
  [[ "$output" == *"No ledger data available"* ]]
}

@test "fleet section renders samples with count, first-seen time and escaped text" {
  cat > "$BATS_TEST_TMPDIR/a.jsonl" << 'EOF'
{"kind":"rate_limit_sample","ts":"2026-10-08T12:00:00Z","shape":"111","sample":"weekly limit <b>| resets Mon","run_id":"1"}
{"workflow":"dev-lead","model":"m","et":1}
EOF
  cat > "$BATS_TEST_TMPDIR/b.jsonl" << 'EOF'
{"kind":"rate_limit_sample","ts":"2026-10-07T09:30:00Z","shape":"111","sample":"weekly limit <b>| resets Sun","run_id":"2"}
{"kind":"rate_limit_sample","ts":"2026-10-08T01:00:00Z","shape":"222","sample":"quota exceeded","run_id":"2"}
EOF
  run generate_rate_limit_samples_report "$BATS_TEST_TMPDIR/a.jsonl" "$BATS_TEST_TMPDIR/b.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unparsed rate-limit messages"* ]]
  [[ "$output" != *"No unparsed rate-limit samples"* ]]
  [[ "$output" == *"2 distinct"* ]]
  # Shape 111: seen twice, first seen at the earlier ts, earliest sample shown.
  [[ "$output" == *"2 occurrence(s), first seen 2026-10-07T09:30:00Z"* ]]
  [[ "$output" == *"resets Sun"* ]]
  [[ "$output" != *"resets Mon"* ]]
  [[ "$output" == *"1 occurrence(s), first seen 2026-10-08T01:00:00Z"* ]]
  # HTML-escaped so a sample cannot break the rendered page.
  [[ "$output" == *"&lt;b&gt;"* ]]
  [[ "$output" != *"<b>"* ]]
}
