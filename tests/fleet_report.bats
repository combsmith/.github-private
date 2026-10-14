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
