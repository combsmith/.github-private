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
  local row="0	petry-projects/x	wf.yml	2	0	2	0	100%	5	6	CRITICAL	100"
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/fleet_report.sh' && printf '%s\n' '$row' | apply_confidence_filter"
  [[ "$output" =~ "LOW-CONF" ]]
}

@test "confidence filter: CRITICAL with 5 or more runs is unchanged" {
  local row="0	petry-projects/x	ci.yml	23	3	20	0	87%	67	206	CRITICAL	87"
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/fleet_report.sh' && printf '%s\n' '$row' | apply_confidence_filter"
  [[ "$output" =~ "CRITICAL" ]]
  [[ ! "$output" =~ "LOW-CONF" ]]
}

@test "confidence filter: non-CRITICAL statuses are never changed" {
  local row="2	petry-projects/x	wf.yml	2	2	0	0	0%	5	6	WARNING	0"
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/fleet_report.sh' && printf '%s\n' '$row' | apply_confidence_filter"
  [[ "$output" =~ "WARNING" ]]
  [[ ! "$output" =~ "LOW-CONF" ]]
}

@test "confidence filter: LOW-CONF rows get sort_key 5 (sorted last)" {
  local row="0	petry-projects/x	wf.yml	2	0	2	0	100%	5	6	CRITICAL	100"
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
    "0	petry-projects/a	wf.yml	10	0	10	0	100%	1	2	CRITICAL	100" \
    "0	petry-projects/b	wf.yml	10	0	10	0	100%	1	2	CRITICAL	100" \
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
    $'2\tpetry-projects/.github-private\t.github/workflows/test-deletion-guard.yml\t18\t16\t2\t0\t11.1%\t11\t82\tWARNING\t11')"
  run filter_high_failure "$m"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
  rm -f "$m"
}

@test "filter_high_failure: gate matched by bare basename is excluded" {
  local m
  m="$(_mk_metrics \
    $'2\tpetry-projects/.github-private\ttest-deletion-guard.yml\t18\t16\t2\t0\t11.1%\t11\t82\tWARNING\t11')"
  run filter_high_failure "$m"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
  rm -f "$m"
}

@test "filter_high_failure: non-gate workflow over 10% is still tracked" {
  local m
  m="$(_mk_metrics \
    $'0\tpetry-projects/.github-private\tci.yml\t23\t3\t20\t0\t87.0%\t67\t206\tCRITICAL\t87')"
  run filter_high_failure "$m"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.[0].workflow')" = "ci.yml" ]
  rm -f "$m"
}

@test "filter_high_failure: ERROR row for a gate workflow is still surfaced" {
  local m
  m="$(_mk_metrics \
    $'6\tpetry-projects/.github-private\t.github/workflows/test-deletion-guard.yml\t?\t\t\t\terror\t0\t0\tERROR\t0')"
  run filter_high_failure "$m"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.[0].label')" = "ERROR" ]
  rm -f "$m"
}

@test "filter_high_failure: CRITICAL with under 5 runs is dropped as LOW-CONF" {
  local m
  m="$(_mk_metrics \
    $'0\tpetry-projects/.github-private\tflaky.yml\t3\t0\t3\t0\t100%\t5\t5\tCRITICAL\t100')"
  run filter_high_failure "$m"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
  rm -f "$m"
}

@test "filter_high_failure: mixed rows keep only the tracked non-gate workflow" {
  local m
  m="$(_mk_metrics \
    $'0\tpetry-projects/.github-private\tci.yml\t23\t3\t20\t0\t87.0%\t67\t206\tCRITICAL\t87' \
    $'2\tpetry-projects/.github-private\t.github/workflows/test-deletion-guard.yml\t18\t16\t2\t0\t11.1%\t11\t82\tWARNING\t11' \
    $'3\tpetry-projects/.github-private\thealthy.yml\t50\t50\t0\t0\t0%\t10\t20\tHEALTHY\t0')"
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
    $'petry-projects/a\t2\t1\t4\t60' \
    $'petry-projects/b\t1\t1\t3\t40' \
    > "$f"
  run generate_dev_lead_timeout_report "$f" 100
  [ "$status" -eq 0 ]
  [[ "$output" =~ "petry-projects/a" ]]
  [[ "$output" =~ "petry-projects/b" ]]
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
  printf '%s\n' $'petry-projects/a\t2\t0\t2\t10' > "$f"
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
  printf '%s\n' $'petry-projects/a	3	0	3	8' > "$f"
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
  printf '%s\n' $'petry-projects/a	1	1	2	2' > "$f"
  run generate_dev_lead_timeout_report "$f" 2
  [[ "$output" =~ "50%" ]]
  [[ ! "$output" =~ "50.0%" ]]
  rm -f "$f"
}

@test "dev-lead timeout report: zero total runs yields n/a (no divide-by-zero)" {
  local f
  f="$(mktemp "$BATS_TEST_TMPDIR/fr.XXXXXX")"
  printf '%s\n' $'petry-projects/a	1	0	1	0' > "$f"
  run generate_dev_lead_timeout_report "$f" 0
  [ "$status" -eq 0 ]
  [[ "$output" =~ "n/a" ]]
  rm -f "$f"
}

@test "dev-lead timeout report: unavailable (non-numeric) total runs is treated as n/a" {
  local f
  f="$(mktemp "$BATS_TEST_TMPDIR/fr.XXXXXX")"
  # 5th column is the ERROR sentinel '?' — must not crash or divide-by-zero
  printf '%s\n' $'petry-projects/a	1	0	1	?' > "$f"
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

# ---------------------------------------------------------------------------
# count_cron_ticks — cron-to-expected-ticks expansion (#725, epic #722)
# Counts how many times a single 5-field cron fires in the half-open window
# [start_epoch, end_epoch). Windows are chosen on minute boundaries so counts
# are exact.
# ---------------------------------------------------------------------------

@test "cron ticks: daily 6am fires once over a 24h window" {
  local s e
  s=$(date -u -d '2026-06-01T00:00:00Z' +%s)
  e=$(date -u -d '2026-06-02T00:00:00Z' +%s)
  run count_cron_ticks '0 6 * * *' "$s" "$e"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "cron ticks: hourly fires 24 times over a 24h window" {
  local s e
  s=$(date -u -d '2026-06-01T00:00:00Z' +%s)
  e=$(date -u -d '2026-06-02T00:00:00Z' +%s)
  run count_cron_ticks '0 * * * *' "$s" "$e"
  [ "$output" = "24" ]
}

@test "cron ticks: */15 fires 4 times over a 1h window" {
  local s e
  s=$(date -u -d '2026-06-01T00:00:00Z' +%s)
  e=$(date -u -d '2026-06-01T01:00:00Z' +%s)
  run count_cron_ticks '*/15 * * * *' "$s" "$e"
  [ "$output" = "4" ]
}

@test "cron ticks: comma+range minute list fires the expected count" {
  local s e
  s=$(date -u -d '2026-06-01T00:00:00Z' +%s)
  e=$(date -u -d '2026-06-01T01:00:00Z' +%s)
  # minutes 0,30 plus 45-47 → 5 ticks in one hour
  run count_cron_ticks '0,30,45-47 * * * *' "$s" "$e"
  [ "$output" = "5" ]
}

@test "cron ticks: day-of-week Monday fires once over a week" {
  local s e
  # 2026-06-01 is a Monday
  s=$(date -u -d '2026-06-01T00:00:00Z' +%s)
  e=$(date -u -d '2026-06-08T00:00:00Z' +%s)
  run count_cron_ticks '0 0 * * 1' "$s" "$e"
  [ "$output" = "1" ]
}

@test "cron ticks: a cron that never matches in the window yields 0" {
  local s e
  s=$(date -u -d '2026-06-01T00:00:00Z' +%s)
  e=$(date -u -d '2026-06-01T05:00:00Z' +%s)
  # fires at 06:00 which is after the window end
  run count_cron_ticks '0 6 * * *' "$s" "$e"
  [ "$output" = "0" ]
}

@test "cron ticks: half-open window does not double-count the end boundary" {
  local s e
  # midnight daily over exactly 24h [00:00, next-00:00) → 1, not 2
  s=$(date -u -d '2026-06-01T00:00:00Z' +%s)
  e=$(date -u -d '2026-06-02T00:00:00Z' +%s)
  run count_cron_ticks '0 0 * * *' "$s" "$e"
  [ "$output" = "1" ]
}

@test "cron ticks: empty cron expression yields 0" {
  run count_cron_ticks '' 0 60
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# extract_crons — parse schedule.cron entries from workflow YAML (#725)
# The actions/workflows API does not expose cron, so it is parsed from the file.
# ---------------------------------------------------------------------------

@test "extract crons: single cron entry is printed" {
  local yaml=$'name: X\non:\n  schedule:\n    - cron: "0 6 * * *"\n'
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/fleet_report.sh' && printf '%s' '$yaml' | extract_crons"
  [ "$status" -eq 0 ]
  [ "$output" = "0 6 * * *" ]
}

@test "extract crons: multiple cron entries are each printed" {
  local yaml=$'on:\n  schedule:\n    - cron: "0 6 * * *"\n    - cron: "30 18 * * *"\n'
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/fleet_report.sh' && printf '%s' '$yaml' | extract_crons"
  [[ "$output" =~ "0 6 * * *" ]]
  [[ "$output" =~ "30 18 * * *" ]]
  [ "$(printf '%s\n' "$output" | grep -cv 'cron')" -eq 2 ]
}

@test "extract crons: workflow with no schedule prints nothing" {
  local yaml=$'on:\n  push:\n    branches: [main]\n'
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/fleet_report.sh' && printf '%s' '$yaml' | extract_crons"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "extract crons: handles YAML 'on:' parsed as boolean true key" {
  # PyYAML parses the bare key 'on' as boolean True — the parser must still find
  # the schedule under that key.
  local yaml=$'on:\n  schedule:\n    - cron: "15 3 * * *"\n'
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/fleet_report.sh' && printf '%s' '$yaml' | extract_crons"
  [ "$output" = "15 3 * * *" ]
}

# ---------------------------------------------------------------------------
# workflow_expected_ticks — extract + count + sum across all crons (#725)
# ---------------------------------------------------------------------------

@test "expected ticks: multi-cron workflow sums ticks across entries" {
  local s e yaml
  s=$(date -u -d '2026-06-01T00:00:00Z' +%s)
  e=$(date -u -d '2026-06-02T00:00:00Z' +%s)
  # two daily crons → 1 + 1 = 2 expected ticks over 24h
  yaml=$'on:\n  schedule:\n    - cron: "0 6 * * *"\n    - cron: "0 18 * * *"\n'
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/fleet_report.sh' && printf '%s' '$yaml' | workflow_expected_ticks $s $e"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "expected ticks: workflow with no schedule yields 0" {
  local s e yaml
  s=$(date -u -d '2026-06-01T00:00:00Z' +%s)
  e=$(date -u -d '2026-06-02T00:00:00Z' +%s)
  yaml=$'on:\n  push:\n    branches: [main]\n'
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/fleet_report.sh' && printf '%s' '$yaml' | workflow_expected_ticks $s $e"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# classify_schedule_reliability — reliability classification (#725)
# Prints: <label> <TAB> <hit_rate_display> <TAB> <missed>
# ---------------------------------------------------------------------------

@test "reliability: expected==actual is STABLE at 100%" {
  run classify_schedule_reliability 1 1 1 50
  [ "$status" -eq 0 ]
  [ "$output" = $'STABLE\t100%\t0' ]
}

@test "reliability: zero actual against many expected is STALLED" {
  run classify_schedule_reliability 24 0 1 50
  [[ "$output" =~ "STALLED" ]]
}

@test "reliability: actual materially below threshold is DEGRADED" {
  # 10/24 = 41.7% < 50% threshold
  run classify_schedule_reliability 24 10 1 50
  [[ "$output" =~ "DEGRADED" ]]
  [[ "$output" =~ "41.7%" ]]
}

@test "reliability: a single missed tick within tolerance stays STABLE" {
  # 23/24, missed 1 == tolerance → not surfaced
  run classify_schedule_reliability 24 23 1 50
  [[ "$output" =~ "STABLE" ]]
}

@test "reliability: hit rate is capped at 100% when actual exceeds expected" {
  run classify_schedule_reliability 1 5 1 50
  [[ "$output" =~ "100%" ]]
  [[ "$output" =~ "STABLE" ]]
}

@test "reliability: whole-number rate renders without a decimal" {
  # 12/24 = 50% (== threshold, so STABLE), whole number
  run classify_schedule_reliability 24 12 0 50
  [[ "$output" =~ "50%" ]]
  [[ ! "$output" =~ "50.0%" ]]
}

# ---------------------------------------------------------------------------
# generate_schedule_reliability_report — renders the section (#725)
# Input TSV rows: repo <TAB> wf <TAB> expected <TAB> actual <TAB> hit_rate
#                 <TAB> missed <TAB> label
# ---------------------------------------------------------------------------

@test "schedule report: renders a STALLED workflow and the caveat note" {
  local f
  f="$(mktemp "$BATS_TEST_TMPDIR/sr.XXXXXX")"
  printf '%s\n' \
    $'petry-projects/broodly\tnightly.yml\t24\t0\t0%\t24\tSTALLED' \
    $'petry-projects/.github\tdaily.yml\t1\t1\t100%\t0\tSTABLE' \
    > "$f"
  run generate_schedule_reliability_report "$f"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Schedule Reliability" ]]
  [[ "$output" =~ "nightly.yml" ]]
  [[ "$output" =~ "STALLED" ]]
  # best-effort / default-branch / tolerance / 1000-cap caveats are documented
  [[ "$output" =~ "best-effort" ]]
  [[ "$output" =~ "default branch" ]]
  [[ "$output" =~ "1000" ]]
  rm -f "$f"
}

@test "schedule report: STALLED sorts above STABLE" {
  local f
  f="$(mktemp "$BATS_TEST_TMPDIR/sr.XXXXXX")"
  printf '%s\n' \
    $'petry-projects/a\tstable.yml\t1\t1\t100%\t0\tSTABLE' \
    $'petry-projects/b\tstalled.yml\t24\t0\t0%\t24\tSTALLED' \
    > "$f"
  run generate_schedule_reliability_report "$f"
  local stalled_line stable_line
  stalled_line=$(printf '%s\n' "$output" | grep -n 'stalled.yml' | cut -d: -f1)
  stable_line=$(printf '%s\n' "$output" | grep -n 'stable.yml' | cut -d: -f1)
  [ "$stalled_line" -lt "$stable_line" ]
  rm -f "$f"
}

@test "schedule report: empty file produces no output" {
  local f
  f="$(mktemp "$BATS_TEST_TMPDIR/sr.XXXXXX")"
  : > "$f"
  run generate_schedule_reliability_report "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm -f "$f"
}

# ---------------------------------------------------------------------------
# Persona opt-out label coverage / drift (#1644)
#   Drift TSV format (5 fields):
#     1:repo  2:status  3:present_count  4:total  5:missing_csv
#   status ∈ { COMPLETE, INCOMPLETE }
# ---------------------------------------------------------------------------

# Build a throwaway personas/ tree with the given ids, each carrying an
# `opt_out_label: <id>:hands-off` under a triggers: block (mirrors the real
# personas/<id>/persona.yml shape).
_make_personas_dir() {
  local dir="$1"; shift
  local id
  for id in "$@"; do
    mkdir -p "${dir}/${id}"
    cat > "${dir}/${id}/persona.yml" <<YAML
id: ${id}
triggers:
  default_mode: advisory
  opt_out_label: ${id}:hands-off
YAML
  done
}

@test "derive_persona_optout_labels: derives the family from persona manifests, sorted" {
  local d="${BATS_TEST_TMPDIR}/p"
  _make_personas_dir "$d" qa-lead dev-lead sre-lead
  run derive_persona_optout_labels "$d"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 3 ]
  [ "${output%%$'\n'*}" = "dev-lead:hands-off" ]
  [[ "$output" =~ "qa-lead:hands-off" ]]
}

@test "derive_persona_optout_labels: real personas/ include qa-lead and dev-lead (derived, not enumerated)" {
  run derive_persona_optout_labels "${BATS_TEST_DIRNAME}/../personas"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "qa-lead:hands-off" ]]
  [[ "$output" =~ "dev-lead:hands-off" ]]
  # A newly added persona directory joins automatically; do not assert an exact
  # count that would break every time a persona is added — assert the floor.
  [ "$(printf '%s\n' "$output" | grep -c ':hands-off$')" -ge 8 ]
}

@test "derive_persona_optout_labels: missing dir yields no output, no crash" {
  run derive_persona_optout_labels "${BATS_TEST_TMPDIR}/does-not-exist"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "persona_optout_row: repo with the full family is COMPLETE (no missing)" {
  local exp; exp="$(printf 'a:hands-off\nb:hands-off\nc:hands-off')"
  run persona_optout_row "petry-projects/x" "$exp" "$exp"
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r repo status present total missing <<< "$output"
  [ "$status" = "COMPLETE" ]
  [ "$present" = "3" ]
  [ "$total" = "3" ]
  [ -z "$missing" ]
}

@test "persona_optout_row: repo with a subset is INCOMPLETE and names the missing labels" {
  local exp act
  exp="$(printf 'a:hands-off\nb:hands-off\nc:hands-off')"
  act="$(printf 'a:hands-off')"
  run persona_optout_row "petry-projects/x" "$exp" "$act"
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r repo st present total missing <<< "$output"
  [ "$st" = "INCOMPLETE" ]
  [ "$present" = "1" ]
  [ "$total" = "3" ]
  [[ "$missing" =~ "b:hands-off" ]]
  [[ "$missing" =~ "c:hands-off" ]]
}

@test "persona_optout_row: repo carrying none of the family is INCOMPLETE (missing all)" {
  local exp; exp="$(printf 'a:hands-off\nb:hands-off')"
  run persona_optout_row "petry-projects/x" "$exp" ""
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r repo st present total missing <<< "$output"
  [ "$st" = "INCOMPLETE" ]
  [ "$present" = "0" ]
}

@test "persona_optout_row: extra non-persona labels on the repo are ignored" {
  local exp act
  exp="$(printf 'a:hands-off\nb:hands-off')"
  act="$(printf 'a:hands-off\nb:hands-off\nbug\nenhancement')"
  run persona_optout_row "petry-projects/x" "$exp" "$act"
  IFS=$'\t' read -r repo st present total missing <<< "$output"
  [ "$st" = "COMPLETE" ]
  [ -z "$missing" ]
}

@test "generate_persona_optout_report: lists INCOMPLETE repos with the missing label named" {
  local f; f="$(mktemp "$BATS_TEST_TMPDIR/po.XXXXXX")"
  printf '%s\n' \
    $'petry-projects/.github-private\tCOMPLETE\t9\t9\t' \
    $'petry-projects/TalkTerm\tINCOMPLETE\t1\t9\tqa-lead:hands-off,sre-lead:hands-off' \
    > "$f"
  run generate_persona_optout_report "$f" 9
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Persona opt-out label coverage" ]]
  # The INCOMPLETE repo and its missing label are surfaced by name.
  [[ "$output" =~ "TalkTerm" ]]
  [[ "$output" =~ "qa-lead:hands-off" ]]
  # A COMPLETE repo is not in the drift table.
  ! [[ "$output" =~ "\`petry-projects/.github-private\`" ]]
}

@test "generate_persona_optout_report: all-COMPLETE reports a clean state" {
  local f; f="$(mktemp "$BATS_TEST_TMPDIR/po.XXXXXX")"
  printf '%s\n' \
    $'petry-projects/.github-private\tCOMPLETE\t9\t9\t' \
    > "$f"
  run generate_persona_optout_report "$f" 9
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Persona opt-out label coverage" ]]
  # Clean state: the drift table / fan-out call-to-action is absent.
  [[ "$output" =~ "No persona opt-out drift" ]]
  ! [[ "$output" =~ "Fan out the derived family" ]]
}

@test "generate_persona_optout_report: empty/missing file produces no output" {
  local f; f="$(mktemp "$BATS_TEST_TMPDIR/po.XXXXXX")"
  : > "$f"
  run generate_persona_optout_report "$f" 9
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "persona_optout_alert_json: emits only INCOMPLETE repos with their missing labels" {
  local f; f="$(mktemp "$BATS_TEST_TMPDIR/po.XXXXXX")"
  printf '%s\n' \
    $'petry-projects/.github-private\tCOMPLETE\t9\t9\t' \
    $'petry-projects/TalkTerm\tINCOMPLETE\t1\t9\tqa-lead:hands-off,sre-lead:hands-off' \
    > "$f"
  run persona_optout_alert_json "$f"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].repo')" = "petry-projects/TalkTerm" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].missing | length')" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].missing[0]')" = "qa-lead:hands-off" ]
}

@test "persona_optout_alert_json: empty file yields []" {
  local f; f="$(mktemp "$BATS_TEST_TMPDIR/po.XXXXXX")"
  : > "$f"
  run persona_optout_alert_json "$f"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" -eq 0 ]
}
