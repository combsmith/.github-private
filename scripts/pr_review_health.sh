#!/usr/bin/env bash
# Daily telemetry check for the PR Review Agent workflow.
#
# Fetches recent pr-review.yml run data, computes health metrics, and
# writes a structured markdown report to both GITHUB_STEP_SUMMARY and
# pr_review_health_report.md. Sets HAS_FAILURES=true in GITHUB_ENV when
# failed runs are detected.
#
# Env vars consumed:
#   GH_TOKEN      — must have actions:read on WORKFLOW_REPO
#   LOOKBACK_DAYS — days of history to consider (default: 1)
#   GITHUB_ENV    — written by Actions runner
#   GITHUB_STEP_SUMMARY — written by Actions runner

set -euo pipefail

LOOKBACK_DAYS="${LOOKBACK_DAYS:-1}"
WORKFLOW_REPO="${AGENT_REPO:-combsmith/.github-private}"
WORKFLOW_FILE="pr-review-trigger.yml"
REPORT_FILE="pr_review_health_report.md"
TODAY=$(date -u +%Y-%m-%d)

echo "=== PR Review Agent — Daily Health Check ==="
echo "  Repo:         $WORKFLOW_REPO"
echo "  Workflow:     $WORKFLOW_FILE"
echo "  Lookback:     ${LOOKBACK_DAYS} day(s)"
echo "  Date:         $TODAY"
echo ""

# ---------------------------------------------------------------------------
# 0. Token selection
# ---------------------------------------------------------------------------
if ! gh api "repos/${WORKFLOW_REPO}/actions/workflows/${WORKFLOW_FILE}/runs?per_page=1" \
     >/dev/null 2>&1; then
  if [ -n "${GH_PAT_FALLBACK:-}" ]; then
    echo "::warning::GH_TOKEN cannot access ${WORKFLOW_REPO} — using GH_PAT_FALLBACK"
    export GH_TOKEN="$GH_PAT_FALLBACK"
  else
    echo "::error::GH_TOKEN cannot access ${WORKFLOW_REPO} and GH_PAT_FALLBACK is not set."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Fetch run metadata
# ---------------------------------------------------------------------------
CUTOFF=$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)

echo "Fetching runs since: $CUTOFF"

runs_json=$(gh api \
  "repos/${WORKFLOW_REPO}/actions/workflows/${WORKFLOW_FILE}/runs?per_page=100&created=>=${CUTOFF}" \
  --jq '.workflow_runs | map({
    id: .id,
    run_number: .run_number,
    status: .status,
    conclusion: .conclusion,
    created_at: .created_at,
    html_url: .html_url,
    duration_s: ((.updated_at | fromdate) - (.created_at | fromdate))
  })' 2>/dev/null || echo '[]')

# ---------------------------------------------------------------------------
# 2. Compute aggregate stats
# ---------------------------------------------------------------------------
read -r total_runs failed_runs success_runs cancelled_runs < <(echo "$runs_json" | jq -r '
  [
    length,
    ([.[] | select(.conclusion == "failure")] | length),
    ([.[] | select(.conclusion == "success")] | length),
    ([.[] | select(.conclusion == "cancelled")] | length)
  ] | @tsv')

echo "  Total:      $total_runs"
echo "  Success:    $success_runs"
echo "  Failed:     $failed_runs"
echo "  Cancelled:  $cancelled_runs"

if [ "$total_runs" -gt 0 ]; then
  failure_rate=$(echo "scale=1; $failed_runs * 100 / $total_runs" | bc)
else
  failure_rate="0.0"
fi

# Duration percentiles across all completed runs (computed but not surfaced in the
# LLM prompt — reserved for future structured-report use).
# shellcheck disable=SC2034
read -r dur_min dur_p50 dur_p95 dur_max < <(echo "$runs_json" | jq -r '
  [.[] | select(.conclusion != null and .duration_s > 0) | .duration_s] | sort |
  if length == 0 then "0 0 0 0"
  else . as $d | ($d | length) as $n |
    "\($d | min) \($d[$n * 50 / 100 | floor]) \($d[$n * 95 / 100 | floor]) \($d | max)"
  end')

# ---------------------------------------------------------------------------
# 3. Helpers
# ---------------------------------------------------------------------------
fmt_dur() {
  local s=$1
  if [ "$s" -ge 60 ]; then
    printf '%dm%ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}

conclusion_icon() {
  case "$1" in
    success)   echo "✅" ;;
    failure)   echo "❌" ;;
    cancelled) echo "⚪" ;;
    skipped)   echo "⏭️" ;;
    *)         echo "⏳" ;;
  esac
}

# overall is the pre-computed status fed as a hint to the LLM prompt below.
# shellcheck disable=SC2034
if [ "$failed_runs" -eq 0 ]; then
  overall="HEALTHY"
elif [ "$(echo "$failure_rate > 50" | bc)" -eq 1 ]; then
  overall="CRITICAL"
elif [ "$(echo "$failure_rate > 20" | bc)" -eq 1 ]; then
  overall="DEGRADED"
else
  overall="WARNING"
fi

# ---------------------------------------------------------------------------
# 4. Build report
# ---------------------------------------------------------------------------
[ -n "${GITHUB_ENV:-}" ] && {
  if [ "$failed_runs" -gt 0 ]; then
    echo "HAS_FAILURES=true" >> "$GITHUB_ENV"
  else
    echo "HAS_FAILURES=false" >> "$GITHUB_ENV"
  fi
}

RUNS_SUMMARY=$(echo "$runs_json" | jq -r '
  sort_by(.run_number) | reverse
  | map("#\(.run_number) \(.conclusion // .status) @ \(.created_at)")
  | join("\n")
')
LOG_DIR="${LOG_DIR:-}"

logs_file=$(mktemp)
# One jq pass over failed runs; append each log file in the same order
while IFS=$'\t' read -r run_id run_meta; do
  [ -n "$LOG_DIR" ] || continue
  log_file="${LOG_DIR}/run_${run_id}.txt"
  [ -f "$log_file" ] || continue
  {
    printf '=== LOG: %s ===\n' "$run_meta"
    cat "$log_file"
    printf '=== END LOG ===\n\n'
  } >> "$logs_file"
done < <(echo "$runs_json" | jq -r \
  '.[] | select(.conclusion == "failure") | [(.id | tostring), "run #\(.run_number) (\(.conclusion)) at \(.created_at)"] | @tsv')

workflow_source=$(gh api "repos/${WORKFLOW_REPO}/contents/.github/workflows/${WORKFLOW_FILE}" \
  --jq '.content' 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null \
  || echo "(workflow source unavailable)")

echo "Invoking Claude for log analysis..."
# Claude writes errors to stdout (not stderr), so they'd silently land in
# $REPORT_FILE with the stdout redirect below.  Wrap in `if !` so a non-zero
# exit surfaces the file contents to the Actions log before aborting.
if ! claude --print --model claude-sonnet-4-6 --no-session-persistence > "$REPORT_FILE" <<PROMPT
You are analyzing GitHub Actions workflow run logs for the PR Review Agent.

## Context
- Workflow: \`${WORKFLOW_FILE}\` in repo \`${WORKFLOW_REPO}\`
- Analysis window: last ${LOOKBACK_DAYS} days, up to 100 most recent runs
- Report date: ${TODAY}
- Total runs fetched: ${total_runs} | Successful: ${success_runs} | Failed: ${failed_runs} | Cancelled: ${cancelled_runs}

## Run Summary
${RUNS_SUMMARY}

## Workflow Source (.github/workflows/${WORKFLOW_FILE})
\`\`\`yaml
${workflow_source}
\`\`\`

## Failed Run Logs
$(cat "$logs_file")

---

Analyze these logs and produce a markdown health report with the following sections:

### 1. Executive Summary
Use F-style layout — lead with the most critical signal, then supporting bullets. No prose paragraphs.

Format:
**Status:** BLOCKING | DEGRADED | WARNING | HEALTHY
**Period:** <date range>
**Result:** <X of Y runs failed (Z%)>

Key findings:
- <dominant failure cause — one line>
- <secondary issue if any — one line>
- <any pattern worth noting — one line>

Action required: <one imperative sentence, or "None" if healthy>

### 2. Failure Breakdown
A table with columns: Failure Category | Affected Runs | Example Error Message.
Categories to look for (not exhaustive):
- CLI breaking change (e.g. invalid flag values)
- Permission / auth error (403, 401, insufficient scope)
- GitHub API rate limit
- Missing token scope (e.g. read:org, read:packages)
- Engine rate limit (Claude or Copilot quota)
- Timeout / infrastructure
- Other / unknown

### 3. Error Patterns
For each category found: quote the exact error message from the logs, identify which step and script it comes from, and explain the root cause.

### 4. Token Scope Analysis
From the workflow source and any gh auth status output in the logs, list:
- Scopes currently present
- Scopes that appear missing or insufficient based on the errors
- Recommendation for each missing scope

### 5. Recommendations
Numbered list. For each issue include: what to change (file, line, command), why, expected impact after fix, and urgency: [CRITICAL | HIGH | MEDIUM | LOW].
Mark CRITICAL if the issue causes 100% workflow failure.

### 6. Health Score
Single line: \`Health: X/10 — <one-sentence verdict>\`
(10 = all runs passing; 0 = complete outage)

Output ONLY the markdown report — no preamble or commentary outside the report sections.
PROMPT
then
  echo "::error::Claude invocation failed. CLI output follows:"
  cat "$REPORT_FILE" >&2
  rm -f "$logs_file"
  exit 1
fi
rm -f "$logs_file"

[ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "$REPORT_FILE" ] && cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"

echo ""
echo "Report written to $REPORT_FILE ($(wc -c < "$REPORT_FILE") bytes)"
echo "=== Health check complete ==="