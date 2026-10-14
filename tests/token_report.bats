#!/usr/bin/env bats
# Tests for scripts/token_report.sh — pure annotation + Markdown rendering with USD cost.
# Network I/O (collect_org_jsonl / main) is not exercised here.
# Run locally: bats tests/token_report.bats

FIXTURES="${BATS_TEST_DIRNAME}/fixtures/token_jsonl"

setup() {
  # shellcheck source=scripts/token_report.sh
  source "${BATS_TEST_DIRNAME}/../scripts/token_report.sh"
}

# ---------------------------------------------------------------------------
# _fmt_int / _fmt_usd
# ---------------------------------------------------------------------------

@test "_fmt_int: adds thousands separators" {
  run _fmt_int 1234567
  [ "$output" = "1,234,567" ]
}

@test "_fmt_int: handles zero" {
  run _fmt_int 0
  [ "$output" = "0" ]
}

@test "_fmt_usd: renders dollars rounded to 2 decimals (cents)" {
  run _fmt_usd 1.0548
  [ "$output" = "\$1.05" ]
}

@test "_fmt_usd: sub-cent amounts render as \$0.00" {
  run _fmt_usd 0.0042
  [ "$output" = "\$0.00" ]
}

# ---------------------------------------------------------------------------
# annotate_records — date-accurate cost + table-derived ET
# ---------------------------------------------------------------------------

@test "annotate_records: one enriched row per call" {
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/token_report.sh'; annotate_records '$FIXTURES' | wc -l"
  [ "$output" -eq 4 ]
}

@test "annotate_records: prices opus at \$5 input / \$25 output (cost & known flag)" {
  # opus-4-7 1000/500/200 → (1000*5 + 500*0.5 + 200*25)/1e6 = 0.010250
  result="$(annotate_records "$FIXTURES" | awk -F'\t' '$4=="claude-opus-4-7"{print $8, $10}')"
  [ "$result" = "0.010250 1" ]
}

@test "annotate_records: recomputes ET from table (opus m=5, ignores stored et=80250)" {
  # ET = 5 * (1000 + 0.1*500 + 4*200) = 5*1850 = 9250
  result="$(annotate_records "$FIXTURES" | awk -F'\t' '$4=="claude-opus-4-7"{print $9}')"
  [ "$result" = "9250.0000" ]
}

@test "annotate_records: excludes finding_verification records (story #843, no cost pollution)" {
  # The LSP finding-verification step shares the Token Observatory JSONL channel
  # (kind:"finding_verification"). Those audit records must NOT be priced as
  # token-usage calls or they would inflate the cost report with phantom rows.
  tmp="$(mktemp -d)"
  printf '%s\n' \
    '{"ts":"2026-06-01T00:00:00Z","workflow":"pr-review","tier":"deep","model":"claude-opus-4-7","input_tokens":100,"output_tokens":50,"repo":"r","context":""}' \
    '{"kind":"finding_verification","ts":"2026-06-01T00:00:01Z","workflow":"pr-review","tier":"deep","outcome":"unverifiable","severity_before":"critical","severity_after":"major","finding_index":0,"context":"pr"}' \
    > "$tmp/mixed.jsonl"
  result="$(annotate_records "$tmp" | wc -l)"
  rm -rf "$tmp"
  [ "$result" -eq 1 ]
}

@test "annotate_records: unknown model → cost sentinel -1 and known=0" {
  tmp="$(mktemp -d)"
  printf '%s\n' '{"ts":"2026-06-01T00:00:00Z","workflow":"x","tier":"y","model":"mystery-model-v9","input_tokens":100,"output_tokens":50,"repo":"r","context":""}' > "$tmp/u.jsonl"
  result="$(annotate_records "$tmp" | awk -F'\t' '{print $8, $10}')"
  rm -rf "$tmp"
  [ "$result" = "-1.000000 0" ]
}

@test "annotate_records: excludes empty model-less all-zero records (#1009)" {
  # The dev-lead path emitted model-less, zero-usage junk records that surfaced as a
  # `- / -` row and inflated the "no price" count. They are not priced calls at all,
  # so annotate_records drops them entirely, keeping only the genuine real-model row.
  tmp="$(mktemp -d)"
  printf '%s\n' \
    '{"ts":"2026-06-01T00:00:00Z","workflow":"dev-lead","tier":"","model":"","input_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0,"output_tokens":0,"repo":"r","context":""}' \
    '{"ts":"2026-06-01T00:00:01Z","workflow":"dev-lead","tier":"","model":"-","input_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0,"output_tokens":0,"repo":"r","context":""}' \
    '{"ts":"2026-06-01T00:00:02Z","workflow":"pr-review","tier":"deep","model":"claude-opus-4-7","input_tokens":100,"output_tokens":50,"repo":"r","context":""}' \
    > "$tmp/mixed.jsonl"
  result="$(annotate_records "$tmp" | wc -l)"
  rm -rf "$tmp"
  [ "$result" -eq 1 ]
}

@test "render_token_report: empty model-less junk does not add to the 'no price' count" {
  # Only a genuine unknown-but-real model should warn. A model-less all-zero record
  # must not appear as an unpriced call, and its `- / -` row must not render.
  tmp="$(mktemp -d)"
  printf '%s\n' \
    '{"ts":"2026-06-01T00:00:00Z","workflow":"dev-lead","tier":"","model":"","input_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0,"output_tokens":0,"repo":"r","context":""}' \
    '{"ts":"2026-06-01T00:00:02Z","workflow":"pr-review","tier":"deep","model":"claude-opus-4-7","input_tokens":100,"output_tokens":50,"repo":"r","context":""}' \
    > "$tmp/mixed.jsonl"
  run render_token_report "$tmp" 7 1 1 2026-06-07
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  # No unpriced warning (the only non-priced record was junk, now excluded).
  [[ "$output" != *"had no price"* ]]
  # No junk `- / -` cost-driver row.
  [[ "$output" != *"| \`dev-lead\` |  | \`-\` |"* ]]
}

@test "render_token_report: a real unknown-model call still warns (#1009 regression guard)" {
  # Fix B must NOT silence genuine unpriced-but-real calls.
  tmp="$(mktemp -d)"
  printf '%s\n' \
    '{"ts":"2026-06-01T00:00:00Z","workflow":"dev-lead","tier":"","model":"","input_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0,"output_tokens":0,"repo":"r","context":""}' \
    '{"ts":"2026-06-01T00:00:02Z","workflow":"x","tier":"y","model":"mystery-model-v9","input_tokens":100,"output_tokens":50,"repo":"r","context":""}' \
    > "$tmp/mixed.jsonl"
  run render_token_report "$tmp" 7 1 1 2026-06-07
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"had no price"* ]]
}

# ---------------------------------------------------------------------------
# render_token_report
# ---------------------------------------------------------------------------

@test "render_token_report: total cost sums priced calls (rounded to cents)" {
  # 0.010250 + 0.010500 + 0.004500 + 0.000850 = 0.026100 → $0.03 at 2 decimals
  run render_token_report "$FIXTURES" 7 2 2 2026-06-07
  [ "$status" -eq 0 ]
  [[ "$output" == *"Total cost:** \$0.03"* ]]
}

@test "render_token_report: has cost columns and a cost-per-PR section" {
  run render_token_report "$FIXTURES" 7 2 2 2026-06-07
  [[ "$output" == *"| Cost | % of \$ | ET |"* ]]
  [[ "$output" == *"Most expensive PRs"* ]]
}

@test "render_token_report: by-repo sorted by cost (markets first)" {
  run render_token_report "$FIXTURES" 7 2 2 2026-06-07
  repos="$(printf '%s\n' "$output" | grep -oE 'petry-projects/(markets|broodly)' | head -2 | tr '\n' ' ')"
  [ "$repos" = "petry-projects/markets petry-projects/broodly " ]
}

@test "render_token_report: flags unpriced calls" {
  tmp="$(mktemp -d)"
  printf '%s\n' '{"ts":"2026-06-01T00:00:00Z","workflow":"x","tier":"y","model":"mystery-model-v9","input_tokens":100,"output_tokens":50,"repo":"r","context":""}' > "$tmp/u.jsonl"
  run render_token_report "$tmp" 7 1 1 2026-06-07
  rm -rf "$tmp"
  [[ "$output" == *"had no price"* ]]
}

@test "render_token_report: empty dir yields a no-data message" {
  empty="$(mktemp -d)"
  run render_token_report "$empty" 7 0 0 2026-06-07
  rmdir "$empty"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No token-usage records found"* ]]
}

@test "render_token_report: caps PR list at 10 without aborting on many PRs (SIGPIPE guard)" {
  # >10 distinct PR contexts — the top-10 limit must not abort under pipefail.
  tmp="$(mktemp -d)"
  for i in $(seq 1 25); do
    printf '{"ts":"2026-06-01T00:00:00Z","workflow":"pr-review","tier":"single","model":"claude-haiku-4-5-20251001","input_tokens":%d,"cache_read_tokens":0,"output_tokens":10,"repo":"petry-projects/r","context":"https://github.com/petry-projects/r/pull/%d"}\n' "$((i * 100))" "$i" >> "$tmp/many.jsonl"
  done
  run render_token_report "$tmp" 7 1 1 2026-06-07
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Most expensive PRs"* ]]
  # Exactly 10 PR rows rendered (lines containing a /pull/ link in the table).
  local pr_lines
  pr_lines="$(printf '%s\n' "$output" | grep -c '/pull/')"
  [ "$pr_lines" -eq 10 ]
  # Highest-cost PR (#25, most input tokens) must be first in the list.
  [[ "$output" == *"/pull/25 |"* ]]
}

# ---------------------------------------------------------------------------
# duration_ms latency columns (#1949)
# ---------------------------------------------------------------------------

@test "annotate_records: carries duration_ms as a trailing column (empty when null)" {
  tmp="$(mktemp -d)"
  printf '%s\n' \
    '{"ts":"2026-06-01T00:00:00Z","workflow":"pr-review","tier":"deep","model":"claude-opus-4-7","input_tokens":100,"output_tokens":50,"duration_ms":1500,"repo":"r","context":""}' \
    '{"ts":"2026-06-01T00:00:01Z","workflow":"pr-review","tier":"deep","model":"claude-opus-4-7","input_tokens":100,"output_tokens":50,"duration_ms":null,"repo":"r","context":""}' \
    > "$tmp/d.jsonl"
  # Column 14 is duration_ms: "1500" on the first row, empty on the null row.
  result="$(annotate_records "$tmp" | awk -F'\t' '{print ($14 == "" ? "-" : $14)}' | tr '\n' ' ')"
  rm -rf "$tmp"
  [ "$result" = "1500 - " ]
}

@test "render_token_report: top cost drivers table has Mean ms and p50 ms columns" {
  run render_token_report "$FIXTURES" 7 2 2 2026-06-07
  [ "$status" -eq 0 ]
  [[ "$output" == *"| Mean ms | p50 ms |"* ]]
}

@test "render_token_report: mean duration_ms is averaged over records that carry a duration" {
  tmp="$(mktemp -d)"
  printf '%s\n' \
    '{"ts":"2026-06-01T00:00:00Z","workflow":"pr-review","tier":"deep","model":"claude-opus-4-7","input_tokens":100,"output_tokens":50,"duration_ms":100,"repo":"r","context":""}' \
    '{"ts":"2026-06-01T00:00:01Z","workflow":"pr-review","tier":"deep","model":"claude-opus-4-7","input_tokens":100,"output_tokens":50,"duration_ms":300,"repo":"r","context":""}' \
    > "$tmp/d.jsonl"
  run render_token_report "$tmp" 7 1 1 2026-06-07
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  # Two deep opus calls at 100ms and 300ms → mean 200. p50 (nearest-rank, n=2) → 100.
  [[ "$output" == *"| 200 | 100 |"* ]]
}

@test "render_token_report: null-duration records are excluded from the mean (not counted as 0)" {
  # One 200ms call + one null-duration call for the same wf/tier/model. The mean
  # must be 200 (average over the single measured record), NOT 100 (which would be
  # the result of treating the null as 0).
  tmp="$(mktemp -d)"
  printf '%s\n' \
    '{"ts":"2026-06-01T00:00:00Z","workflow":"pr-review","tier":"deep","model":"claude-opus-4-7","input_tokens":100,"output_tokens":50,"duration_ms":200,"repo":"r","context":""}' \
    '{"ts":"2026-06-01T00:00:01Z","workflow":"pr-review","tier":"deep","model":"claude-opus-4-7","input_tokens":100,"output_tokens":50,"duration_ms":null,"repo":"r","context":""}' \
    > "$tmp/d.jsonl"
  run render_token_report "$tmp" 7 1 1 2026-06-07
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"| 200 | 200 |"* ]]
}

@test "render_token_report: non-integer numeric durations (12.5, 1e3) are counted, not dropped" {
  # emit_token_record accepts any JSON number; the report must normalise them to
  # whole ms instead of excluding them. floor(12.5)=12 and 1e3=1000 → mean 506.
  tmp="$(mktemp -d)"
  printf '%s\n' \
    '{"ts":"2026-06-01T00:00:00Z","workflow":"pr-review","tier":"deep","model":"claude-opus-4-7","input_tokens":100,"output_tokens":50,"duration_ms":12.5,"repo":"r","context":""}' \
    '{"ts":"2026-06-01T00:00:01Z","workflow":"pr-review","tier":"deep","model":"claude-opus-4-7","input_tokens":100,"output_tokens":50,"duration_ms":1e3,"repo":"r","context":""}' \
    > "$tmp/d.jsonl"
  run render_token_report "$tmp" 7 1 1 2026-06-07
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"| 506 | 12 |"* ]]
}

@test "render_token_report: a workflow/tier/model with no durations shows '-' for latency" {
  # The fixtures carry no duration_ms field, so every latency cell must be "-".
  run render_token_report "$FIXTURES" 7 2 2 2026-06-07
  [ "$status" -eq 0 ]
  [[ "$output" == *"| - | - |"* ]]
}

# ---------------------------------------------------------------------------
# cost-per-day stacked chart
# ---------------------------------------------------------------------------

@test "render_token_report: includes a cost-per-day stacked-by-repo chart" {
  run render_token_report "$FIXTURES" 7 2 2 2026-06-07
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cost per day (stacked by repo)"* ]]
  [[ "$output" == *"Legend:"* ]]
  # One dated bar row per day present in the fixtures (2026-06-01 and 2026-06-02).
  [[ "$output" == *"2026-06-01"* ]]
  [[ "$output" == *"2026-06-02"* ]]
}

@test "render_cost_per_day: bar length scales with the daily total" {
  # Day with the higher total gets the longer (50-char max) bar; the lighter day shorter.
  run render_cost_per_day <(annotate_records "$FIXTURES")
  [ "$status" -eq 0 ]
  d1="$(printf '%s\n' "$output" | awk '/^2026-06-01/ { n=gsub(/[A-H.]/,""); print n }')"
  d2="$(printf '%s\n' "$output" | awk '/^2026-06-02/ { n=gsub(/[A-H.]/,""); print n }')"
  [ "$d1" -gt "$d2" ]
}

# ---------------------------------------------------------------------------
# cost-per-PR — PR title column (PR_TITLE_FILE)
# ---------------------------------------------------------------------------

@test "render_token_report: shows first 35 chars of PR title from PR_TITLE_FILE" {
  local tf; tf="$(mktemp)"
  printf 'https://github.com/petry-projects/markets/pull/1\tFix the widget alignment bug in the dashboard header\n' > "$tf"
  export PR_TITLE_FILE="$tf"
  run render_token_report "$FIXTURES" 7 2 2 2026-06-07
  unset PR_TITLE_FILE; rm -f "$tf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"| Title |"* ]]
  # First 35 chars + ellipsis.
  [[ "$output" == *"Fix the widget alignment bug in the…"* ]]
}

@test "render_token_report: PR title pipes are sanitized so the table doesn't break" {
  local tf; tf="$(mktemp)"
  printf 'https://github.com/petry-projects/markets/pull/1\tfix a|b parser\n' > "$tf"
  export PR_TITLE_FILE="$tf"
  run render_token_report "$FIXTURES" 7 2 2 2026-06-07
  unset PR_TITLE_FILE; rm -f "$tf"
  [[ "$output" == *"fix a/b parser"* ]]
}

@test "render_token_report: Title column is blank when no PR_TITLE_FILE" {
  unset PR_TITLE_FILE
  run render_token_report "$FIXTURES" 7 2 2 2026-06-07
  [[ "$output" == *"| Title |"* ]]
  # No stray title text leaks in — the PR rows still render (URL + empty title cell).
  [[ "$output" == *"/pull/1 |"* ]]
}

# ---------------------------------------------------------------------------
# collect_org_jsonl — error-handling (gh is stubbed; no network)
# ---------------------------------------------------------------------------

@test "annotate_records: empty directory returns 0 with no output (glob-expansion guard)" {
  # Regression test for bug where annotate_records passed an unexpanded glob
  # (e.g. /tmp/.../jsonl/*.jsonl) to jq when no JSONL files existed, causing
  # jq to exit 2 and fail the fleet-monitor job (observed 2026-05-19 to 2026-05-21).
  # Fixed by: [ -e "${files[0]}" ] || return 0
  local d; d="$(mktemp -d)"
  run annotate_records "$d"
  rmdir "$d"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "collect_org_jsonl: emits ERROR and returns non-zero when org repo listing fails" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  run bash -c "
    gh() { return 1; }
    export -f gh
    source '${BATS_TEST_DIRNAME}/../scripts/token_report.sh'
    export ORG=petry-projects LOOKBACK_DAYS=7
    collect_org_jsonl '${tmpdir}' 2>&1
  "
  rm -rf "$tmpdir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "collect_org_jsonl: emits WARN and continues when per-repo artifact listing fails" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  run bash -c "
    gh() {
      case \"\$2\" in
        orgs/*/repos*) echo 'petry-projects/test-repo'; return 0;;
        repos/*/actions/artifacts*) return 1;;
        *) return 1;;
      esac
    }
    export -f gh
    source '${BATS_TEST_DIRNAME}/../scripts/token_report.sh'
    export ORG=petry-projects LOOKBACK_DAYS=7
    collect_org_jsonl '${tmpdir}' 2>&1
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
}

@test "collect_org_jsonl: removes malformed dest JSONL when jq conversion fails" {
  local tmpdir jsonl_dir
  tmpdir="$(mktemp -d)"
  jsonl_dir="$(mktemp -d)"
  run bash -c "
    set -euo pipefail
    source '${BATS_TEST_DIRNAME}/../scripts/token_report.sh'
    # Simulate the inner conversion loop for a corrupted source file. Use truncated
    # JSON, which jq rejects deterministically across versions (jq 1.7 exits 0 on
    # NUL bytes, so binary input made this test flaky).
    f='$tmpdir/bad.jsonl'
    printf '{\"a\":' > \"\$f\"
    dest='$jsonl_dir/999-bad.jsonl'
    if jq -c --arg repo 'r' 'select(type==\"object\") | . + {repo: \$repo}' \
        \"\$f\" > \"\$dest\" 2>/dev/null; then
      true
    else
      rm -f \"\$dest\" 2>/dev/null || true
    fi
    # No lingering dest file should remain.
    [ -z \"\$(ls '$jsonl_dir')\" ] && echo 'clean' || echo 'dirty'
  "
  rm -rf "$tmpdir" "$jsonl_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "clean" ]
}

@test "collect_org_jsonl: emits WARN and continues when artifact zip download fails" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  run bash -c "
    gh() {
      case \"\$2\" in
        orgs/*/repos*) echo 'petry-projects/test-repo'; return 0;;
        repos/*/actions/artifacts/*/zip) return 1;;
        repos/*/actions/artifacts*)
          printf '{\"artifacts\":[{\"name\":\"token-usage-x\",\"id\":999,\"expired\":false,\"created_at\":\"2099-01-01T00:00:00Z\"}]}'
          return 0;;
        *) return 0;;
      esac
    }
    export -f gh
    source '${BATS_TEST_DIRNAME}/../scripts/token_report.sh'
    export ORG=petry-projects LOOKBACK_DAYS=7
    collect_org_jsonl '${tmpdir}' 2>&1
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"download failed"* ]]
}

# ---------------------------------------------------------------------------
# _gh_timeout — per-call timeout wrapper (#954: one hung gh call must not
# consume the whole job)
# ---------------------------------------------------------------------------

@test "_gh_timeout: bounds a hung gh call (returns 124, well under the sleep)" {
  command -v timeout >/dev/null 2>&1 || skip "timeout command not available"
  run bash -c "
    gh() { sleep 20; }
    export -f gh
    source '${BATS_TEST_DIRNAME}/../scripts/token_report.sh'
    export ARTIFACT_OP_TIMEOUT=1
    start=\$(date +%s)
    if _gh_timeout api anything; then rc=0; else rc=\$?; fi
    end=\$(date +%s)
    echo \"rc=\$rc elapsed=\$((end - start))\"
  "
  [[ "$output" == *"rc=124"* ]]
  elapsed="$(printf '%s\n' "$output" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"
  [ "$elapsed" -lt 10 ]
}

@test "_gh_timeout: ARTIFACT_OP_TIMEOUT=0 runs gh directly (no timeout wrapper)" {
  run bash -c "
    gh() { echo \"called:\$1:\$2\"; return 0; }
    export -f gh
    source '${BATS_TEST_DIRNAME}/../scripts/token_report.sh'
    export ARTIFACT_OP_TIMEOUT=0
    _gh_timeout api repos/x/y
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"called:api:repos/x/y"* ]]
}

@test "collect_org_jsonl: a hung artifact download times out without stalling; healthy artifact still collected" {
  command -v timeout >/dev/null 2>&1 || skip "timeout command not available"
  local jsonl_dir fixdir fixzip
  jsonl_dir="$(mktemp -d)"
  fixdir="$(mktemp -d)"
  fixzip="$fixdir/good.zip"
  python3 - "$fixzip" <<'PY'
import sys, zipfile
rec = '{"ts":"2099-01-01T00:00:00Z","workflow":"pr-review","tier":"deep","model":"claude-opus-4-7","input_tokens":10,"output_tokens":5,"context":""}\n'
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("token-usage.jsonl", rec)
PY
  run bash -c "
    export FIXZIP='$fixzip'
    gh() {
      case \"\$2\" in
        orgs/*/repos*) echo 'petry-projects/test-repo'; return 0;;
        repos/*/actions/artifacts/111/zip) cat \"\$FIXZIP\"; return 0;;
        repos/*/actions/artifacts/999/zip) sleep 20; return 0;;
        repos/*/actions/artifacts*)
          printf '{\"artifacts\":[{\"name\":\"token-usage-a\",\"id\":111,\"expired\":false,\"created_at\":\"2099-01-01T00:00:00Z\"},{\"name\":\"token-usage-b\",\"id\":999,\"expired\":false,\"created_at\":\"2099-01-01T00:00:00Z\"}]}'
          return 0;;
        *) return 0;;
      esac
    }
    export -f gh
    source '${BATS_TEST_DIRNAME}/../scripts/token_report.sh'
    export ORG=petry-projects LOOKBACK_DAYS=3650 COLLECT_CONCURRENCY=4
    # Deliberately NOT exported: collect_org_jsonl must propagate it to the workers
    # itself, or the per-download timeout silently disables in the parallel fan-out.
    ARTIFACT_OP_TIMEOUT=1
    start=\$(date +%s)
    collect_org_jsonl '$jsonl_dir'; rc=\$?
    end=\$(date +%s)
    echo \"rc=\$rc elapsed=\$((end - start))\"
  " 2>&1
  local recs; recs="$(cat "$jsonl_dir"/111-*.jsonl 2>/dev/null | wc -l | tr -d ' ')"
  rm -rf "$jsonl_dir" "$fixdir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  # The healthy artifact (111) was downloaded, extracted and repo-tagged.
  [ "$recs" -ge 1 ]
  # The hung download (999) was bounded, not waited out for its full 20s.
  [[ "$output" == *"WARN"* ]]
  elapsed="$(printf '%s\n' "$output" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"
  [ "$elapsed" -lt 15 ]
}

# ---------------------------------------------------------------------------
# render_gemini_quota — per-key Gemini usage against the caps file (#2030)
# ---------------------------------------------------------------------------

_gq_dir() {
  local d; d="$(mktemp -d)"
  cat > "$d/run.jsonl" <<'JSONL'
{"ts":"2026-06-01T10:00:05Z","engine":"gemini","model":"gemini-3.8-flash","input_tokens":100,"cache_read_tokens":0,"output_tokens":20,"key_index":1,"repo":"r"}
{"ts":"2026-06-01T10:00:40Z","engine":"gemini","model":"gemini-3.8-flash","input_tokens":300,"cache_read_tokens":0,"output_tokens":30,"key_index":1,"repo":"r"}
{"ts":"2026-06-01T10:05:00Z","engine":"gemini","model":"gemini-3.8-flash","input_tokens":50,"cache_read_tokens":0,"output_tokens":5,"key_index":1,"repo":"r"}
{"ts":"2026-06-01T11:00:00Z","engine":"gemini","model":"gemini-3.8-flash","input_tokens":10,"cache_read_tokens":0,"output_tokens":1,"key_index":2,"repo":"r"}
{"kind":"gemini_key_cooldown","ts":"2026-06-01T10:01:00Z","engine":"gemini","model":"gemini-3.8-flash","key_index":1,"until":1,"repo":"r"}
{"ts":"2026-06-01T12:00:00Z","engine":"claude","model":"claude-opus-4-7","input_tokens":10,"output_tokens":1,"repo":"r"}
JSONL
  printf '%s' "$d"
}

@test "render_gemini_quota: per key index, peak per window against the caps file" {
  local d caps; d="$(_gq_dir)"; caps="$(mktemp)"
  printf '1\tgemini-3.8-flash\tfree\t10\t1000\tnone\n' > "$caps"
  GEMINI_QUOTA_CAPS="$caps" run render_gemini_quota "$d"
  rm -rf "$d" "$caps"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Gemini quota (per key index)"* ]]
  # key 1: 3 calls; peak minute = 2 req / 450 tok; peak day = 3 req (no cap); 1 cooldown
  [[ "$output" == *'| 1 | `gemini-3.8-flash` | free | 3 | 2 / 10 (20%) | 450 / 1,000 (45%) | 3 (no cap) | 1 |'* ]]
  # key 2 has no caps row → every window shows the cap as unknown, never hidden.
  [[ "$output" == *'| 2 | `gemini-3.8-flash` | unknown | 1 | 1 / unknown | 11 / unknown | 1 / unknown | 0 |'* ]]
}

@test "render_gemini_quota: no-op when no record carries a gemini key index" {
  local d; d="$(mktemp -d)"
  printf '%s\n' '{"ts":"2026-06-01T10:00:00Z","engine":"gemini","model":"gemini-3.8-flash","input_tokens":1,"output_tokens":1,"repo":"r"}' > "$d/run.jsonl"
  run render_gemini_quota "$d"
  rm -rf "$d"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "render_token_report: Gemini quota section sits beside the per-model usage" {
  local d; d="$(_gq_dir)"
  run render_token_report "$d" 7 1 1
  rm -rf "$d"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Top cost drivers"*"## Gemini quota (per key index)"*"## By repository"* ]]
  # The cooldown record is not a priced call.
  [[ "$output" == *"5 LLM calls"* ]]
}

@test "render_gemini_quota: daily window buckets by configured reset tz (Pacific midnight, not UTC)" {
  local d caps; d="$(mktemp -d)"; caps="$(mktemp)"
  # 2026-06-01T06:59:00Z = 23:59 PDT May 31; 07:01Z = 00:01 PDT Jun 1 (same UTC date, different Pacific days).
  # 2026-01-15T07:30Z = 23:30 PST Jan 14; 08:30Z = 00:30 PST Jan 15 (DST offset differs).
  cat > "$d/run.jsonl" <<'JSONL'
{"ts":"2026-06-01T06:59:00Z","engine":"gemini","model":"m","input_tokens":1,"output_tokens":1,"key_index":1,"repo":"r"}
{"ts":"2026-06-01T07:01:00Z","engine":"gemini","model":"m","input_tokens":1,"output_tokens":1,"key_index":1,"repo":"r"}
{"ts":"2026-01-15T07:30:00Z","engine":"gemini","model":"m","input_tokens":1,"output_tokens":1,"key_index":2,"repo":"r"}
{"ts":"2026-01-15T08:30:00Z","engine":"gemini","model":"m","input_tokens":1,"output_tokens":1,"key_index":2,"repo":"r"}
JSONL
  printf 'setting\tdaily_reset_time\t00:00\nsetting\tdaily_reset_tz\tAmerica/Los_Angeles\n' > "$caps"
  GEMINI_QUOTA_CAPS="$caps" run render_gemini_quota "$d"
  rm -rf "$d" "$caps"
  [ "$status" -eq 0 ]
  [[ "$output" == *"00:00 America/Los_Angeles reset"* ]]
  # Each call is the only one in its Pacific day → peak req/day 1 (UTC day buckets would give 2 for key 1).
  [[ "$output" == *'| 1 | `m` | unknown | 2 | 1 / unknown | 2 / unknown | 1 / unknown | 0 |'* ]]
  [[ "$output" == *'| 2 | `m` | unknown | 2 | 1 / unknown | 2 / unknown | 1 / unknown | 0 |'* ]]
}
