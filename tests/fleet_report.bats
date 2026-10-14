#!/usr/bin/env bats
# Tests for scripts/fleet_report.sh — visualization and report generation.
# Run locally: bats tests/fleet_report.bats
# Fields in metrics TSV (12):
#   1:sort_key  2:repo  3:wf_file  4:total  5:success  6:failed
#   7:cancelled  8:rate_display  9:p50  10:p95  11:label  12:rate_int

FIXTURES="${BATS_TEST_DIRNAME}/fixtures"
METRICS="${FIXTURES}/metrics_sample.tsv"

setup() {
  # shellcheck source=scripts/fleet_report.sh
  source "${BATS_TEST_DIRNAME}/../scripts/fleet_report.sh"
}

# ---------------------------------------------------------------------------
# generate_scorecard
# ---------------------------------------------------------------------------

@test "scorecard: correct CRITICAL count" {
  run generate_scorecard "$METRICS"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "CRITICAL: 8" ]]
}

@test "scorecard: correct DEGRADED count" {
  run generate_scorecard "$METRICS"
  [[ "$output" =~ "DEGRADED: 2" ]]
}

@test "scorecard: correct WARNING count" {
  run generate_scorecard "$METRICS"
  [[ "$output" =~ "WARNING: 2" ]]
}

@test "scorecard: correct HEALTHY count" {
  run generate_scorecard "$METRICS"
  [[ "$output" =~ "HEALTHY: 3" ]]
}

@test "scorecard: contains all four status emoji" {
  run generate_scorecard "$METRICS"
  [[ "$output" =~ "🔴" ]]
  [[ "$output" =~ "🟠" ]]
  [[ "$output" =~ "🟡" ]]
  [[ "$output" =~ "✅" ]]
}

# ---------------------------------------------------------------------------
# apply_confidence_filter
# ---------------------------------------------------------------------------

@test "confidence filter: CRITICAL with fewer than 5 runs → LOW-CONF" {
  local row="0	combsmith/x	wf.yml	2	0	2	0	100%	5	6	CRITICAL	100"
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/fleet_report.sh' && printf '%s\n' '$row' | apply_confidence_filter"
  [[ "$output" =~ "LOW-CONF" ]]
}

@test "confidence filter: CRITICAL with 5 or more runs is unchanged" {
  local row="0	combsmith/x	ci.yml	23	3	20	0	87%	67	206	CRITICAL	87"
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/fleet_report.sh' && printf '%s\n' '$row' | apply_confidence_filter"
  [[ "$output" =~ "CRITICAL" ]]
  [[ ! "$output" =~ "LOW-CONF" ]]
}

@test "confidence filter: non-CRITICAL statuses are never changed" {
  local row="2	combsmith/x	wf.yml	2	2	0	0	0%	5	6	WARNING	0"
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/fleet_report.sh' && printf '%s\n' '$row' | apply_confidence_filter"
  [[ "$output" =~ "WARNING" ]]
  [[ ! "$output" =~ "LOW-CONF" ]]
}

@test "confidence filter: LOW-CONF rows get sort_key 5 (sorted last)" {
  local row="0	combsmith/x	wf.yml	2	0	2	0	100%	5	6	CRITICAL	100"
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/fleet_report.sh' && printf '%s\n' '$row' | apply_confidence_filter"
  [[ "${output:0:1}" == "5" ]]
}

# ---------------------------------------------------------------------------
# detect_systemic_failures
# ---------------------------------------------------------------------------

@test "systemic failures: detects workflow failing in 3 or more repos" {
  run detect_systemic_failures "$METRICS"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "pr-review-mention.yml" ]]
}

@test "systemic failures: does not flag workflow failing in only 2 repos" {
  run detect_systemic_failures "$METRICS"
  # ci.yml fails in .github-private + .github = 2 repos only
  [[ ! "$output" =~ "ci.yml" ]]
}

@test "systemic failures: returns empty when nothing meets threshold" {
  local tmpfile
  tmpfile=$(mktemp)
  printf '%s\n' \
    "0	combsmith/a	wf.yml	10	0	10	0	100%	1	2	CRITICAL	100" \
    "0	combsmith/b	wf.yml	10	0	10	0	100%	1	2	CRITICAL	100" \
    > "$tmpfile"
  run detect_systemic_failures "$tmpfile"
  [ -z "$output" ]
  rm -f "$tmpfile"
}

@test "systemic failures: only counts repos where workflow has failures" {
  run detect_systemic_failures "$METRICS"
  # dependency-audit.yml has failures in broodly only (google-app-scripts not in fixture)
  [[ ! "$output" =~ "dependency-audit.yml" ]]
}

# ---------------------------------------------------------------------------
# flag_duration_variance
# ---------------------------------------------------------------------------

@test "duration variance: flags when p95 > 5x p50 and p50 >= 30s" {
  run flag_duration_variance 100 600
  [[ "$output" =~ "⚠️" ]]
}

@test "duration variance: flags the extreme compliance-audit case (84x)" {
  run flag_duration_variance 957 80534
  [[ "$output" =~ "⚠️" ]]
}

@test "duration variance: no flag when p95 is within 5x p50" {
  run flag_duration_variance 100 400
  [ -z "$output" ]
}

@test "duration variance: no flag when p50 is zero" {
  run flag_duration_variance 0 0
  [ -z "$output" ]
}

@test "duration variance: no flag when p50 < 30s even if ratio is high" {
  run flag_duration_variance 5 100
  [ -z "$output" ]
}

@test "duration variance: no flag when p50 equals p95" {
  run flag_duration_variance 60 60
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# generate_ascii_bar
# ---------------------------------------------------------------------------

@test "ascii bar: 100 percent is all filled blocks" {
  run generate_ascii_bar 100
  [ "$output" = "██████████" ]
}

@test "ascii bar: 0 percent is all empty blocks" {
  run generate_ascii_bar 0
  [ "$output" = "░░░░░░░░░░" ]
}

@test "ascii bar: 80 percent has 8 filled and 2 empty" {
  run generate_ascii_bar 80
  [ "$output" = "████████░░" ]
}

@test "ascii bar: 50 percent has 5 filled and 5 empty" {
  run generate_ascii_bar 50
  [ "$output" = "█████░░░░░" ]
}

@test "ascii bar: output is always exactly 10 characters" {
  run generate_ascii_bar 33
  [ "${#output}" -eq 10 ]
}

@test "ascii bar: 10 percent has 1 filled and 9 empty" {
  run generate_ascii_bar 10
  [ "$output" = "█░░░░░░░░░" ]
}

# ---------------------------------------------------------------------------
# generate_repo_rollup
# ---------------------------------------------------------------------------

@test "repo rollup: contains a header row" {
  run generate_repo_rollup "$METRICS"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Repo" ]]
  [[ "$output" =~ "Failures" ]]
}

@test "repo rollup: produces one data row per distinct repo" {
  run generate_repo_rollup "$METRICS"
  local count
  count=$(echo "$output" | grep -c "^| \`" || true)
  [ "$count" -eq 6 ]
}

@test "repo rollup: sums failures across workflows for broodly (233 total)" {
  run generate_repo_rollup "$METRICS"
  [[ "$output" =~ "233" ]]
}

@test "repo rollup: shows CRITICAL as worst status for .github-private" {
  run generate_repo_rollup "$METRICS"
  local row
  row=$(echo "$output" | grep "github-private")
  [[ "$row" =~ "CRITICAL" ]]
}

# ---------------------------------------------------------------------------
# generate_mermaid_pie
# ---------------------------------------------------------------------------

@test "mermaid pie: opens with mermaid fence and pie keyword" {
  run generate_mermaid_pie "$METRICS"
  [ "${lines[0]}" = '```mermaid' ]
  [[ "${lines[1]}" =~ ^pie ]]
}

@test "mermaid pie: closes with a fenced code block" {
  run generate_mermaid_pie "$METRICS"
  [ "${lines[-1]}" = '```' ]
}

@test "mermaid pie: CRITICAL count matches fixture (8)" {
  run generate_mermaid_pie "$METRICS"
  [[ "$output" =~ '"CRITICAL" : 8' ]]
}

@test "mermaid pie: HEALTHY count matches fixture (3)" {
  run generate_mermaid_pie "$METRICS"
  [[ "$output" =~ '"HEALTHY" : 3' ]]
}

@test "mermaid pie: omits statuses with zero count" {
  local tmpfile
  tmpfile=$(mktemp)
  # Only CRITICAL entries
  grep "CRITICAL" "$METRICS" > "$tmpfile"
  run generate_mermaid_pie "$tmpfile"
  [[ ! "$output" =~ '"HEALTHY"' ]]
  [[ ! "$output" =~ '"WARNING"' ]]
  rm -f "$tmpfile"
}

# ---------------------------------------------------------------------------
# generate_mermaid_bar
# ---------------------------------------------------------------------------

@test "mermaid bar: opens with mermaid fence" {
  run generate_mermaid_bar "$METRICS"
  [ "${lines[0]}" = '```mermaid' ]
}

@test "mermaid bar: contains xychart-beta declaration" {
  run generate_mermaid_bar "$METRICS"
  [[ "$output" =~ "xychart-beta" ]]
}

@test "mermaid bar: closes with fenced code block" {
  run generate_mermaid_bar "$METRICS"
  [ "${lines[-1]}" = '```' ]
}

@test "mermaid bar: excludes entries with fewer than 5 runs" {
  run generate_mermaid_bar "$METRICS"
  # dependabot-updates has 1 run — must be excluded
  [[ ! "$output" =~ "dependabot-updates" ]]
  # lint.yml has 2 runs — must be excluded
  [[ ! "$output" =~ "lint.yml" ]]
}

@test "mermaid bar: includes high-volume high-failure entries" {
  run generate_mermaid_bar "$METRICS"
  # broodly/dependency-audit: 46 runs, 97.8% — must be included
  [[ "$output" =~ "dependency-audit" ]] || [[ "$output" =~ "pr-review-mention" ]]
}

@test "mermaid bar: includes bar data values" {
  run generate_mermaid_bar "$METRICS"
  [[ "$output" =~ "bar [" ]]
}

# ---------------------------------------------------------------------------
# filter_high_failure — high-failure JSON export + gate-workflow exclusion (#941)
# ---------------------------------------------------------------------------

# Writes a metrics TSV to a temp file and echoes its path.
_mk_metrics() {
  local f
  f="$(mktemp "$BATS_TEST_TMPDIR/fr.XXXXXX")" || { echo "Failed to create temp file" >&2; exit 1; }
  printf '%s\n' "$@" > "$f"
  echo "$f"
}

@test "filter_high_failure: gate workflow over 10% is excluded from tracking" {
  local m
  m="$(_mk_metrics \
    $'2\tcombsmith/.github-private\t.github/workflows/test-deletion-guard.yml\t18\t16\t2\t0\t11.1%\t11\t82\tWARNING\t11')"
  run filter_high_failure "$m"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
  rm -f "$m"
}

@test "filter_high_failure: gate matched by bare basename is excluded" {
  local m
  m="$(_mk_metrics \
    $'2\tcombsmith/.github-private\ttest-deletion-guard.yml\t18\t16\t2\t0\t11.1%\t11\t82\tWARNING\t11')"
  run filter_high_failure "$m"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
  rm -f "$m"
}

@test "filter_high_failure: non-gate workflow over 10% is still tracked" {
  local m
  m="$(_mk_metrics \
    $'0\tcombsmith/.github-private\tci.yml\t23\t3\t20\t0\t87.0%\t67\t206\tCRITICAL\t87')"
  run filter_high_failure "$m"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.[0].workflow')" = "ci.yml" ]
  rm -f "$m"
}

@test "filter_high_failure: ERROR row for a gate workflow is still surfaced" {
  local m
  m="$(_mk_metrics \
    $'6\tcombsmith/.github-private\t.github/workflows/test-deletion-guard.yml\t?\t\t\t\terror\t0\t0\tERROR\t0')"
  run filter_high_failure "$m"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.[0].label')" = "ERROR" ]
  rm -f "$m"
}

@test "filter_high_failure: CRITICAL with under 5 runs is dropped as LOW-CONF" {
  local m
  m="$(_mk_metrics \
    $'0\tcombsmith/.github-private\tflaky.yml\t3\t0\t3\t0\t100%\t5\t5\tCRITICAL\t100')"
  run filter_high_failure "$m"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
  rm -f "$m"
}

@test "filter_high_failure: mixed rows keep only the tracked non-gate workflow" {
  local m
  m="$(_mk_metrics \
    $'0\tcombsmith/.github-private\tci.yml\t23\t3\t20\t0\t87.0%\t67\t206\tCRITICAL\t87' \
    $'2\tcombsmith/.github-private\t.github/workflows/test-deletion-guard.yml\t18\t16\t2\t0\t11.1%\t11\t82\tWARNING\t11' \
    $'3\tcombsmith/.github-private\thealthy.yml\t50\t50\t0\t0\t0%\t10\t20\tHEALTHY\t0')"
  run filter_high_failure "$m"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.[0].workflow')" = "ci.yml" ]
  rm -f "$m"
}

# ---------------------------------------------------------------------------
# summarize_dev_lead_timeouts — dev-lead timeout observability (#1019, story C)
# Tallies dev-lead status markers by failure reason. Emits TSV:
#   timeout <TAB> engine_error <TAB> total
# ---------------------------------------------------------------------------

@test "dev-lead timeouts: counts timeout, engine-error, and total across mixed markers" {
  local json='[
    {"body":"<!-- dev-lead-issue 5 status=needs-human attempt=1 reason=timeout run=1 -->\nx"},
    {"body":"<!-- dev-lead-issue 6 status=failed attempt=1 reason=engine-error run=2 -->\ny"},
    {"body":"<!-- dev-lead-issue 9 status=needs-human attempt=3 reason=timeout run=3 -->"}
  ]'
  run summarize_dev_lead_timeouts "$json"
  [ "$status" -eq 0 ]
  [ "$output" = $'2\t1\t3' ]
}

@test "dev-lead timeouts: ignores comments that merely mention reason= but lack the marker" {
  local json='[
    {"body":"<!-- dev-lead-issue 5 status=needs-human attempt=1 reason=timeout run=1 -->"},
    {"body":"a normal comment mentioning reason=timeout but not a marker"}
  ]'
  run summarize_dev_lead_timeouts "$json"
  [ "$output" = $'1\t0\t1' ]
}

@test "dev-lead timeouts: empty array yields zero counts" {
  run summarize_dev_lead_timeouts '[]'
  [ "$output" = $'0\t0\t0' ]
}

@test "dev-lead timeouts: absent argument yields zero counts" {
  run summarize_dev_lead_timeouts
  [ "$output" = $'0\t0\t0' ]
}

@test "dev-lead timeouts: rate-limited counts toward total but not timeout/engine-error" {
  local json='[
    {"body":"<!-- dev-lead-issue 7 status=rate-limited attempt=1 reason=rate-limited run=1 reset=2026-01-01T00:00:00Z -->"},
    {"body":"<!-- dev-lead-issue 8 status=needs-human attempt=1 reason=timeout run=2 -->"}
  ]'
  run summarize_dev_lead_timeouts "$json"
  [ "$output" = $'1\t0\t2' ]
}

# ---------------------------------------------------------------------------
# generate_dev_lead_timeout_report — renders the per-repo section (#1019/#1030)
# Input: TSV file rows
#   `repo <TAB> timeout <TAB> engine_error <TAB> markers <TAB> total_runs`.
# The timeout rate is prevalence: timeout / total_runs (over ALL dev-lead runs,
# not just failure markers).
# ---------------------------------------------------------------------------

@test "dev-lead timeout report: renders per-repo rows, fleet total, and prevalence rate" {
  local f
  f="$(mktemp "$BATS_TEST_TMPDIR/fr.XXXXXX")"
  # timeouts 2+1=3; total runs 60+40=100 → prevalence 3/100 = 3%
  printf '%s\n' \
    $'combsmith/a\t2\t1\t4\t60' \
    $'combsmith/b\t1\t1\t3\t40' \
    > "$f"
  run generate_dev_lead_timeout_report "$f" 100
  [ "$status" -eq 0 ]
  [[ "$output" =~ "combsmith/a" ]]
  [[ "$output" =~ "combsmith/b" ]]
  # Fleet totals: timeout 3, engine-error 2, markers 7 (composition breakdown retained)
  [[ "$output" =~ "Fleet total" ]]
  [[ "$output" =~ "reason=timeout" ]]
  # Prevalence rate = K/N = 3 / 100 = 3% (over total runs, not failures)
  [[ "$output" =~ "3%" ]]
  [[ "$output" =~ "3 / 100" ]]
  # Not the old composition rate (3 / 7 = 42.9%)
  [[ ! "$output" =~ "42.9%" ]]
  rm -f "$f"
}

@test "dev-lead timeout report: denominator is ALL fleet runs, not just marker repos (#1030)" {
  local f
  f="$(mktemp "$BATS_TEST_TMPDIR/fr.XXXXXX")"
  # Only repo a has markers (2 timeouts over its 10 runs). But the fleet ran 100
  # dev-lead runs total — repo b had 90 all-success runs (no markers, absent from
  # the file). Prevalence MUST be 2/100 = 2%, not 2/10 = 20% (the marker-repo-only
  # denominator bug). The passed-in fleet total is the denominator.
  printf '%s\n' $'combsmith/a\t2\t0\t2\t10' > "$f"
  run generate_dev_lead_timeout_report "$f" 100
  [ "$status" -eq 0 ]
  [[ "$output" =~ "2 / 100" ]]
  [[ ! "$output" =~ "20%" ]]
  rm -f "$f"
}

@test "dev-lead timeout report: prevalence rate K/N renders a decimal when needed" {
  local f
  f="$(mktemp "$BATS_TEST_TMPDIR/fr.XXXXXX")"
  # K=3 timeouts over N=8 total runs → 37.5%
  printf '%s\n' $'combsmith/a	3	0	3	8' > "$f"
  run generate_dev_lead_timeout_report "$f" 8
  [ "$status" -eq 0 ]
  [[ "$output" =~ "37.5%" ]]
  [[ "$output" =~ "3 / 8" ]]
  rm -f "$f"
}

@test "dev-lead timeout report: whole-number rate renders without a decimal" {
  local f
  f="$(mktemp "$BATS_TEST_TMPDIR/fr.XXXXXX")"
  # 1 timeout over 2 total runs → 50%
  printf '%s\n' $'combsmith/a	1	1	2	2' > "$f"
  run generate_dev_lead_timeout_report "$f" 2
  [[ "$output" =~ "50%" ]]
  [[ ! "$output" =~ "50.0%" ]]
  rm -f "$f"
}

@test "dev-lead timeout report: zero total runs yields n/a (no divide-by-zero)" {
  local f
  f="$(mktemp "$BATS_TEST_TMPDIR/fr.XXXXXX")"
  printf '%s\n' $'combsmith/a	1	0	1	0' > "$f"
  run generate_dev_lead_timeout_report "$f" 0
  [ "$status" -eq 0 ]
  [[ "$output" =~ "n/a" ]]
  rm -f "$f"
}

@test "dev-lead timeout report: unavailable (non-numeric) total runs is treated as n/a" {
  local f
  f="$(mktemp "$BATS_TEST_TMPDIR/fr.XXXXXX")"
  # 5th column is the ERROR sentinel '?' — must not crash or divide-by-zero
  printf '%s\n' $'combsmith/a	1	0	1	?' > "$f"
  run generate_dev_lead_timeout_report "$f" '?'
  [ "$status" -eq 0 ]
  [[ "$output" =~ "n/a" ]]
  rm -f "$f"
}

@test "dev-lead timeout report: empty file produces no output" {
  local f
  f="$(mktemp "$BATS_TEST_TMPDIR/fr.XXXXXX")"
  : > "$f"
  run generate_dev_lead_timeout_report "$f" 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm -f "$f"
}
