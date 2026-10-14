#!/usr/bin/env bats
# Tests for scripts/canary_report.sh — pure canary go/no-go rendering.
# Network I/O (collect_repo_jsonl / main) is not exercised here.
# Run locally: bats tests/canary_report.bats

setup() {
  # shellcheck source=scripts/canary_report.sh
  source "${BATS_TEST_DIRNAME}/../scripts/canary_report.sh"

  DIR="$(mktemp -d)"
  FILE="$DIR/records.jsonl"

  # Neutralise the maintainer-default time windows so the fixtures below are
  # scored purely on their model split (window filtering is a main()-level concern
  # exercised via its own knobs). Each test may override these.
  CAND="model-new"
  INC="model-old"
  # Synthetic, dated fixture price table so no real model ID is needed.
  PRICING_TABLE="$DIR/fixture-pricing.tsv"
  printf 'model-old\t2025-11-01\t15\t1.5\t18.75\t75\nmodel-new\t2026-09-10\t5\t0.5\t6.25\t25\n' > "$PRICING_TABLE"
  export PRICING_TABLE
  export CANARY_CANDIDATE="$CAND"
  export CANARY_INCUMBENT="$INC"
  export CANARY_WORKFLOW="pr-review"
  export CANARY_TIER="deep"
  export CANARY_SINCE=""
  export CANARY_UNTIL=""
  export CANARY_BASELINE_SINCE=""
  export CANARY_BASELINE_UNTIL=""
}

teardown() {
  rm -rf "$DIR"
}

# mkrec <file> <ts> <workflow> <tier> <model> <in> <cr> <cw> <out> <context> <duration_ms|"">
mkrec() {
  local file="$1" ts="$2" wf="$3" tier="$4" model="$5" inp="$6" cr="$7" cw="$8" out="$9" ctx="${10}" dur="${11}"
  local durfield="null"
  [ -n "$dur" ] && durfield="$dur"
  printf '{"ts":"%s","workflow":"%s","tier":"%s","model":"%s","input_tokens":%d,"cache_read_tokens":%d,"cache_creation_tokens":%d,"output_tokens":%d,"context":"%s","duration_ms":%s}\n' \
    "$ts" "$wf" "$tier" "$model" "$inp" "$cr" "$cw" "$out" "$ctx" "$durfield" >> "$file"
}

# Five candidate PRs (model-new) that clear every bar vs five incumbent
# invocations (model-old). Token usage identical per call so the deltas are the
# pure price difference; candidate durations are 30% faster.
seed_pass() {
  local i
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep model-new \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/${i}" 700
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep model-old \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" 1000
  done
}

# ---------------------------------------------------------------------------
# Overall PASS
# ---------------------------------------------------------------------------

@test "render_canary_report: all three bars clear → PASS, exit 0" {
  seed_pass
  run render_canary_report "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"- cost: PASS"* ]]
  [[ "$output" == *"- cache_read: PASS"* ]]
  [[ "$output" == *"- latency: PASS"* ]]
  [[ "$output" == *"**Overall verdict:** PASS"* ]]
}

@test "render_canary_report: reports per-arm invocation and distinct-PR counts" {
  seed_pass
  run render_canary_report "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"- candidate invocations: 5"* ]]
  [[ "$output" == *"- candidate distinct PRs: 5"* ]]
  [[ "$output" == *"- incumbent invocations: 5"* ]]
}

# ---------------------------------------------------------------------------
# FAIL per metric
# ---------------------------------------------------------------------------

@test "render_canary_report: candidate not 20% cheaper per invocation → cost FAIL, exit 1" {
  local i
  for i in 1 2 3 4 5; do
    # Higher candidate output makes per-invocation cost exceed the incumbent.
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep model-new \
      1000 1000 0 1000 "https://github.com/petry-projects/.github-private/pull/${i}" 700
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep model-old \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" 1000
  done
  run render_canary_report "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"- cost: FAIL"* ]]
  [[ "$output" == *"**Overall verdict:** FAIL"* ]]
}

@test "render_canary_report: cache-read cost not 50% lower → cache_read FAIL, exit 1" {
  local i
  for i in 1 2 3 4 5; do
    # Candidate reads a lot more cache: cache-read cost reduction falls below 50%
    # while per-invocation cost still clears its 20% bar.
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep model-new \
      900 2000 0 100 "https://github.com/petry-projects/.github-private/pull/${i}" 700
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep model-old \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" 1000
  done
  run render_canary_report "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"- cache_read: FAIL"* ]]
  [[ "$output" == *"- cost: PASS"* ]]
  [[ "$output" == *"**Overall verdict:** FAIL"* ]]
}

@test "render_canary_report: candidate not 20% faster → latency FAIL, exit 1" {
  local i
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep model-new \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/${i}" 1000
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep model-old \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" 1000
  done
  run render_canary_report "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"- latency: FAIL"* ]]
  [[ "$output" == *"- cost: PASS"* ]]
  [[ "$output" == *"**Overall verdict:** FAIL"* ]]
}

# ---------------------------------------------------------------------------
# INSUFFICIENT
# ---------------------------------------------------------------------------

@test "render_canary_report: fewer than 5 distinct candidate PRs → INSUFFICIENT, exit 2" {
  local i
  for i in 1 2 3 4; do
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep model-new \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/${i}" 700
  done
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep model-old \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" 1000
  done
  run render_canary_report "$DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"- cost: INSUFFICIENT"* ]]
  [[ "$output" == *"**Overall verdict:** INSUFFICIENT"* ]]
}

@test "render_canary_report: fewer than 5 durations per arm → latency INSUFFICIENT (never a one-pair PASS), exit 2" {
  # Five candidate PRs and five incumbent invocations clear cost/cache, but only
  # ONE call per arm carries a duration_ms. A single fast pair must not score a
  # latency PASS — the sample floor (min invocations) applies to durations too.
  local i
  for i in 1 2 3 4 5; do
    local cdur="" idur=""
    [ "$i" -eq 1 ] && { cdur=700; idur=1000; }
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep model-new \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/${i}" "$cdur"
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep model-old \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" "$idur"
  done
  run render_canary_report "$DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"- latency: INSUFFICIENT"* ]]
  [[ "$output" == *"- cost: PASS"* ]]
  [[ "$output" == *"**Overall verdict:** INSUFFICIENT"* ]]
}

@test "_fmt_pct: preserves the sign of a negative fraction (regression, not reduction)" {
  run _fmt_pct 0.2;  [ "$output" = "20%" ]
  run _fmt_pct -0.2; [ "$output" = "-20%" ]
  run _fmt_pct 0.5;  [ "$output" = "50%" ]
}

@test "_combine_verdict: an operational error (>2) dominates every verdict" {
  # A section that failed to render (exit 3) must never be collapsed into a verdict:
  # it dominates PASS/FAIL/INSUFFICIENT so main() surfaces the failed run.
  run _combine_verdict 0 3; [ "$output" = "3" ]
  run _combine_verdict 3 0; [ "$output" = "3" ]
  run _combine_verdict 1 3; [ "$output" = "3" ]
  run _combine_verdict 3 2; [ "$output" = "3" ]
  # Without an operational error the FAIL > INSUFFICIENT > PASS ordering still holds.
  run _combine_verdict 0 1; [ "$output" = "1" ]
  run _combine_verdict 0 2; [ "$output" = "2" ]
  run _combine_verdict 0 0; [ "$output" = "0" ]
}

@test "render_canary_report: an incumbent call in the candidate window is a fallback, not hidden" {
  # A deep-tier incumbent call AFTER the canary cut (rollout still partly on the old
  # channel) is excluded from the candidate arm by model and from the incumbent arm
  # by the baseline window — so it must surface in the fallback table rather than
  # vanish, or candidate records could PASS while hiding a non-candidate rollout.
  seed_pass
  # An incumbent (model-old) call inside the candidate window (at/after 2026-09-25).
  export CANARY_SINCE="2026-09-25T00:00:00Z"
  export CANARY_BASELINE_SINCE="2026-09-19T00:00:00Z"
  export CANARY_BASELINE_UNTIL="2026-09-25T00:00:00Z"
  mkrec "$FILE" "2026-09-26T12:00:00Z" pr-review deep model-old \
    1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/777" 900
  run render_canary_report "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deep-tier fallback calls (excluded from both arms)"* ]]
  [[ "$output" == *"| \`model-old\` | 1 |"* ]]
}

@test "render_canary_report: no non-null duration on either arm → latency INSUFFICIENT (never PASS), exit 2" {
  local i
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep model-new \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/${i}" ""
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep model-old \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" ""
  done
  run render_canary_report "$DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"- latency: INSUFFICIENT"* ]]
  # Cost/cache are computable and clear their bars, but a missing latency signal
  # must block an overall PASS.
  [[ "$output" == *"- cost: PASS"* ]]
  [[ "$output" == *"**Overall verdict:** INSUFFICIENT"* ]]
}

# ---------------------------------------------------------------------------
# Unpriced-model accounting
# ---------------------------------------------------------------------------

@test "render_canary_report: unpriced candidate records are counted and reported, never dropped" {
  local i
  for i in 1 2 3 4 5; do
    # A model with no row in model-pricing.tsv → unpriced, but still a real call.
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep model-new \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/${i}" 700
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep model-old \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" 1000
  done
  # Add two unpriced candidate calls on new PRs (dated before model-new pricing began).
  mkrec "$FILE" "2026-09-01T10:00:00Z" pr-review deep model-new \
    1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/91" 700
  mkrec "$FILE" "2026-09-01T10:01:00Z" pr-review deep model-new \
    1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/92" 700
  run render_canary_report "$DIR"
  # 7 candidate invocations total; 2 of them unpriced but still counted.
  [[ "$output" == *"- candidate invocations: 7"* ]]
  [[ "$output" == *"- candidate unpriced records: 2"* ]]
}

@test "render_canary_report: a record dated exactly on the pricing effective date is priced" {
  seed_pass
  # model-new pricing is effective 2026-09-10; the boundary day itself must be priced.
  mkrec "$FILE" "2026-09-10T00:00:00Z" pr-review deep model-new \
    1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/93" 700
  run render_canary_report "$DIR"
  [[ "$output" == *"- candidate invocations: 6"* ]]
  [[ "$output" == *"- candidate unpriced records: 0"* ]]
}

@test "render_canary_report: negative sample floors are rejected (exit 3)" {
  seed_pass
  CANARY_MIN_PRS=-1 run render_canary_report "$DIR"
  [ "$status" -eq 3 ]
  CANARY_MIN_INVOCATIONS=-1 run render_canary_report "$DIR"
  [ "$status" -eq 3 ]
}

@test "render_canary_report: a partially unpriced INCUMBENT arm blocks a cost/cache PASS" {
  # Both arms clear the bars on their priced records, but one incumbent call is
  # unpriced (dated before model-old pricing took effect). An unpriced incumbent must
  # make cost/cache INSUFFICIENT — never a PASS against only the priced subset.
  local i
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep model-new \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/${i}" 700
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep model-old \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" 1000
  done
  # One unpriced incumbent call (model-old predates its 2025-11-01 pricing row).
  mkrec "$FILE" "2025-10-01T10:00:00Z" pr-review deep model-old \
    1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/199" 1000
  run render_canary_report "$DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"- incumbent unpriced records: 1"* ]]
  [[ "$output" == *"- cost: INSUFFICIENT"* ]]
  [[ "$output" == *"- cache_read: INSUFFICIENT"* ]]
  [[ "$output" == *"**Overall verdict:** INSUFFICIENT"* ]]
}

# ---------------------------------------------------------------------------
# Controlled (model-ab) mode — records carry the producer's own labels
# ---------------------------------------------------------------------------

@test "render_canary_report: controlled mode selects arms by model, ignoring workflow/tier labels" {
  # The model-ab producer drives both arms through run_triage without setting
  # TOKEN_WORKFLOW, so its records are labeled workflow=unknown / tier=triage, NOT
  # the real-PR pr-review/deep labels. Controlled mode must still find both arms by
  # model alone — otherwise --model-ab-dir is permanently INSUFFICIENT.
  local i
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" unknown triage model-new \
      1000 1000 0 100 "" 700
    mkrec "$FILE" "2026-09-26T11:0${i}:00Z" unknown triage model-old \
      1000 1000 0 100 "" 1000
  done
  CANARY_MODE=controlled run render_canary_report "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"- candidate invocations: 5"* ]]
  [[ "$output" == *"- incumbent invocations: 5"* ]]
  [[ "$output" == *"- cost: PASS"* ]]
  [[ "$output" == *"- cache_read: PASS"* ]]
  [[ "$output" == *"- latency: PASS"* ]]
  [[ "$output" == *"**Overall verdict:** PASS"* ]]
}

@test "render_canary_report: real mode still filters out non-pr-review/deep records" {
  # The same producer-labeled records must NOT enter the real-PR arms — real mode
  # keeps the pr-review/deep predicates, so both arms are empty → INSUFFICIENT.
  local i
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" unknown triage model-new \
      1000 1000 0 100 "" 700
    mkrec "$FILE" "2026-09-26T11:0${i}:00Z" unknown triage model-old \
      1000 1000 0 100 "" 1000
  done
  run render_canary_report "$DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"- candidate invocations: 0"* ]]
  [[ "$output" == *"**Overall verdict:** INSUFFICIENT"* ]]
}

# ---------------------------------------------------------------------------
# Corrupt evidence must never score
# ---------------------------------------------------------------------------

@test "render_canary_report: a malformed JSONL file aborts before scoring (never a bogus PASS)" {
  seed_pass
  # A second file with invalid JSON: annotation (jq) fails; scoring must abort with
  # the OPERATIONAL code (>2, distinct from any verdict) rather than PASS on whatever
  # partial rows were emitted — a failed run must not read as a valid INSUFFICIENT.
  printf '{not valid json\n' > "$DIR/corrupt.jsonl"
  run render_canary_report "$DIR"
  [ "$status" -eq 3 ]
  [[ "$output" != *"**Overall verdict:** PASS"* ]]
}

@test "render_canary_report: a structurally invalid record aborts scoring (operational error, exit 3)" {
  # Valid-JSON but structurally wrong evidence must not be silently discarded or
  # coerced to placeholders/zeros: an incomplete token_usage object (missing
  # output_tokens) makes the sample partial, so scoring aborts with the operational
  # code rather than scoring only the surviving rows into a bogus verdict (#1953).
  seed_pass
  printf '{"ts":"2026-09-26T10:09:00Z","workflow":"pr-review","tier":"deep","model":"model-new","input_tokens":1000,"cache_read_tokens":1000,"cache_creation_tokens":0,"context":"https://github.com/petry-projects/.github-private/pull/9"}\n' > "$DIR/partial.jsonl"
  run render_canary_report "$DIR"
  [ "$status" -eq 3 ]
  [[ "$output" != *"**Overall verdict:** PASS"* ]]
}

@test "render_canary_report: a non-object record aborts scoring (operational error, exit 3)" {
  seed_pass
  printf '[1,2,3]\n' > "$DIR/array.jsonl"
  run render_canary_report "$DIR"
  [ "$status" -eq 3 ]
}

@test "render_canary_report: recognized non-token audit kinds are skipped, not scored" {
  # finding_verification / lsp_cold_start records share the token JSONL channel but
  # are not token_usage — they must be skipped (never abort, never counted), so a
  # clean PASS sample still scores PASS when audit records are interleaved.
  seed_pass
  printf '{"kind":"finding_verification","ts":"2026-09-26T10:00:00Z","workflow":"pr-review","tier":"deep","outcome":"confirmed"}\n' >> "$FILE"
  printf '{"kind":"lsp_cold_start","ts":"2026-09-26T10:00:00Z","workflow":"pr-review"}\n' >> "$FILE"
  run render_canary_report "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"- candidate invocations: 5"* ]]
  [[ "$output" == *"**Overall verdict:** PASS"* ]]
}

# ---------------------------------------------------------------------------
# ISO-8601 bound canonicalization
# ---------------------------------------------------------------------------

@test "_norm_iso: canonicalizes UTC bounds to seconds precision" {
  run _norm_iso "2026-09-25T14:07Z";    [ "$status" -eq 0 ]; [ "$output" = "2026-09-25T14:07:00Z" ]
  run _norm_iso "2026-09-25T14:07:30Z"; [ "$status" -eq 0 ]; [ "$output" = "2026-09-25T14:07:30Z" ]
  run _norm_iso "2026-09-25T14:07";     [ "$status" -eq 0 ]; [ "$output" = "2026-09-25T14:07:00Z" ]
  run _norm_iso "2026-09-25T14:07:30";  [ "$status" -eq 0 ]; [ "$output" = "2026-09-25T14:07:30Z" ]
  run _norm_iso "";                     [ "$status" -eq 0 ]; [ "$output" = "" ]
}

@test "_norm_iso: rejects bounds not lexically comparable with UTC timestamps" {
  # A numeric offset is the same instant as a different UTC string — rejecting it
  # fails closed instead of silently scoring the wrong window.
  run _norm_iso "2026-09-25T15:07:00+01:00"; [ "$status" -ne 0 ]
  run _norm_iso "2026-09-25T14:07:00.123Z";  [ "$status" -ne 0 ]
  run _norm_iso "garbage";                   [ "$status" -ne 0 ]
}

@test "_norm_iso: rejects impossible calendar and clock values" {
  run _norm_iso "2026-02-30T00:00Z"; [ "$status" -ne 0 ]
  run _norm_iso "2026-13-01T00:00Z"; [ "$status" -ne 0 ]
  run _norm_iso "2026-09-25T25:00Z"; [ "$status" -ne 0 ]
  run _norm_iso "2026-09-25T14:60Z"; [ "$status" -ne 0 ]
}

@test "render_canary_report: a negative token count aborts scoring (exit 3)" {
  seed_pass
  mkrec "$FILE" "2026-09-26T10:09:00Z" pr-review deep model-new \
    1000 1000 -1000 100 "https://github.com/petry-projects/.github-private/pull/9" 700
  run render_canary_report "$DIR"
  [ "$status" -eq 3 ]
}

@test "render_canary_report: a malformed record timestamp aborts scoring (exit 3)" {
  seed_pass
  mkrec "$FILE" "2026-09-26garbage" pr-review deep model-new \
    1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/9" 700
  run render_canary_report "$DIR"
  [ "$status" -eq 3 ]
}

@test "render_canary_report: identical candidate and incumbent is an operational error (exit 3)" {
  seed_pass
  CANARY_INCUMBENT="$CAND" run render_canary_report "$DIR"
  [ "$status" -eq 3 ]
}

@test "render_canary_report: a non-numeric price rate is unpriced, never a zero rate" {
  seed_pass
  local tbl="$DIR/pricing.tsv"
  printf 'model-old\t2025-01-01\t15\t1.5\t18.75\t75\nmodel-new\t2025-01-01\tbad\t0\t0\t0\n' > "$tbl"
  PRICING_TABLE="$tbl" run render_canary_report "$DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"- candidate unpriced records: 5"* ]]
}

@test "render_canary_report: latency needs durations across distinct candidate PRs" {
  # Five PRs exist, but only one carries durations (five retries) → latency INSUFFICIENT.
  local i
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep model-new \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/${i}" ""
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep model-old \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" 1000
  done
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-26T11:0${i}:00Z" pr-review deep model-new \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/1" 700
  done
  run render_canary_report "$DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"- latency: INSUFFICIENT"* ]]
}

@test "render_canary_report: candidate records with no context are dropped once the cap applies" {
  seed_pass
  mkrec "$FILE" "2026-09-26T12:00:00Z" pr-review deep model-new 1000 1000 0 100 "" 700
  run render_canary_report "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"- candidate invocations: 5"* ]]
}

# ---------------------------------------------------------------------------
# Genericity (#1951 AC7-AC11), threshold validation, and review hardening
# ---------------------------------------------------------------------------

@test "render_canary_report: missing candidate or incumbent is an operational error (exit 3)" {
  seed_pass
  CANARY_CANDIDATE="" run render_canary_report "$DIR"
  [ "$status" -eq 3 ]
  CANARY_INCUMBENT="" run render_canary_report "$DIR"
  [ "$status" -eq 3 ]
}

@test "main: missing --candidate/--incumbent exits 3 with a usage message" {
  unset CANARY_CANDIDATE CANARY_INCUMBENT
  run main --dir "$DIR"
  [ "$status" -eq 3 ]
  [[ "$output" == *"--candidate"* ]]
  run main --dir "$DIR" --candidate model-new
  [ "$status" -eq 3 ]
}

@test "main: non-Anthropic model names are scored like any other" {
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep gpt-x 1000 1000 0 100 "https://github.com/o/r/pull/${i}" 700
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep gem-y 1000 1000 0 100 "https://github.com/o/r/pull/10${i}" 1000
  done
  printf 'gem-y\t2025-01-01\t15\t1.5\t18.75\t75\ngpt-x\t2025-01-01\t5\t0.5\t6.25\t25\n' > "$DIR/p2.tsv"
  PRICING_TABLE="$DIR/p2.tsv" run main --dir "$DIR" --candidate gpt-x --incumbent gem-y --since 2026-09-25T00:00Z
  [ "$status" -eq 0 ]
  [[ "$output" == *"gpt-x"* ]]
}

@test "main: baseline window is derived from --baseline-days ending at --since" {
  seed_pass
  # Incumbent records are 2026-09-20; with --since 2026-09-25 a 3-day baseline
  # (09-22..09-25) excludes them, a 7-day baseline (09-18..09-25) includes them.
  run main --dir "$DIR" --candidate model-new --incumbent model-old --since 2026-09-25T00:00Z --baseline-days 3
  [ "$status" -eq 2 ]
  [[ "$output" == *"- incumbent invocations: 0"* ]]
  run main --dir "$DIR" --candidate model-new --incumbent model-old --since 2026-09-25T00:00Z --baseline-days 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"- incumbent invocations: 5"* ]]
}

@test "main: explicit --baseline-since/--baseline-until override the derived window" {
  seed_pass
  run main --dir "$DIR" --candidate model-new --incumbent model-old --since 2026-09-25T00:00Z \
    --baseline-since 2026-09-19T00:00Z --baseline-until 2026-09-21T00:00Z
  [ "$status" -eq 0 ]
  [[ "$output" == *"- incumbent invocations: 5"* ]]
}

@test "main: a threshold flag wins over its CANARY_* env var" {
  seed_pass
  # Env bar of 0.99 would FAIL cost; the flag lowers it back to 0.20 → PASS.
  CANARY_COST_BAR=0.99 run main --dir "$DIR" --candidate model-new --incumbent model-old --cost-bar 0.20
  [ "$status" -eq 0 ]
  CANARY_COST_BAR=0.99 run main --dir "$DIR" --candidate model-new --incumbent model-old
  [ "$status" -eq 1 ]
  run main --dir "$DIR" --candidate model-new --incumbent model-old --min-prs 6
  [ "$status" -eq 2 ]
}

@test "render_canary_report: malformed or out-of-range thresholds are an operational error (exit 3)" {
  seed_pass
  CANARY_MIN_PRS=oops CANARY_COST_BAR=oops run render_canary_report "$DIR"
  [ "$status" -eq 3 ]
  CANARY_COST_BAR=1.5 run render_canary_report "$DIR"
  [ "$status" -eq 3 ]
  CANARY_MIN_INVOCATIONS=x run render_canary_report "$DIR"
  [ "$status" -eq 3 ]
}

@test "render_canary_report: latency INSUFFICIENT names the arm lacking duration_ms" {
  local i
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep model-new \
      1000 1000 0 100 "https://github.com/o/r/pull/${i}" 700
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep model-old \
      1000 1000 0 100 "https://github.com/o/r/pull/10${i}" ""
  done
  run render_canary_report "$DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"too few duration_ms values on the incumbent"* ]]
  [[ "$output" != *"the candidate"* ]]
}

@test "render_canary_report: an unknown CANARY_MODE is an operational error (exit 3)" {
  seed_pass
  CANARY_MODE=rela run render_canary_report "$DIR"
  [ "$status" -eq 3 ]
}

@test "render_canary_report: non-PR candidate contexts are not counted as distinct PRs" {
  local i
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep model-new 1000 1000 0 100 "job-${i}" 700
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep model-old 1000 1000 0 100 "https://github.com/o/r/pull/10${i}" 1000
  done
  run render_canary_report "$DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"- candidate distinct PRs: 0"* ]]
}

@test "render_canary_report: a token record with an empty model aborts scoring (exit 3)" {
  seed_pass
  mkrec "$FILE" "2026-09-26T10:09:00Z" pr-review deep "" 1000 1000 0 100 "https://github.com/o/r/pull/9" 700
  run render_canary_report "$DIR"
  [ "$status" -eq 3 ]
}

@test "render_canary_report: gemini_key_cooldown audit records are skipped, not invalid" {
  seed_pass
  printf '{"kind":"gemini_key_cooldown","ts":"2026-09-26T10:00:00Z","key":"k1"}\n' >> "$FILE"
  run render_canary_report "$DIR"
  [ "$status" -eq 0 ]
}

@test "render_canary_report: an incumbent record exactly at the baseline end is excluded" {
  seed_pass
  mkrec "$FILE" "2026-09-25T00:00:00Z" pr-review deep model-old 1000 1000 0 100 "https://github.com/o/r/pull/500" 1000
  CANARY_BASELINE_SINCE="2026-09-19T00:00:00Z" CANARY_BASELINE_UNTIL="2026-09-25T00:00:00Z" run render_canary_report "$DIR"
  [[ "$output" == *"- incumbent invocations: 5"* ]]
}

@test "main: --model-ab-dir alone scores the controlled section without live collection" {
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" unknown triage model-new 1000 1000 0 100 "" 700
    mkrec "$FILE" "2026-09-26T11:0${i}:00Z" unknown triage model-old 1000 1000 0 100 "" 1000
  done
  unset GH_TOKEN
  run main --candidate model-new --incumbent model-old --model-ab-dir "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Controlled comparison"* ]]
}

@test "main: an unreadable --dir is an operational error (exit 66)" {
  [ "$(id -u)" -ne 0 ] || skip "root can read any directory"
  chmod 000 "$DIR"
  run main --dir "$DIR" --candidate model-new --incumbent model-old
  chmod 755 "$DIR"
  [ "$status" -eq 66 ]
}
