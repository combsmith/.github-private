#!/usr/bin/env bash
# Daily health check for the PR Review Agent workflow.
#
# Fetches recent pr-review.yml run logs, feeds them to Claude for pattern
# analysis, and writes a markdown report to pr_review_health_report.md.
# Sets HAS_FAILURES=true in $GITHUB_ENV when failed runs are detected.
#
# Env vars consumed:
#   GH_TOKEN              — primary (GitHub App; must have actions:read on this repo)
#   GH_PAT_FALLBACK       — fallback PAT if App token lacks access
#   CLAUDE_CODE_OAUTH_TOKEN — passed through to claude CLI
#   LOOKBACK_DAYS         — days of history to consider (default: 1, ~24 hours)
#                           Set higher to examine longer windows (e.g., LOOKBACK_DAYS=7 for weekly review)
#   GITHUB_ENV            — written by Actions runner; used to export HAS_FAILURES

set -euo pipefail

LOOKBACK_DAYS="${LOOKBACK_DAYS:-1}"
WORKFLOW_REPO="${AGENT_REPO:-combsmith/.github-private}"
WORKFLOW_FILE="pr-review-trigger.yml"
REPORT_FILE="pr_review_health_report.md"
LOG_DIR="health_run_logs"
TODAY=$(date -u +%Y-%m-%d)

echo "=== PR Review Agent — Daily Health Check ==="
echo "  Repo:         $WORKFLOW_REPO"
echo "  Workflow:     $WORKFLOW_FILE"
echo "  Lookback:     ${LOOKBACK_DAYS} day(s)"
echo "  Date:         $TODAY"
echo ""

# ---------------------------------------------------------------------------
# 0. Token selection — verify GH_TOKEN has access to workflow run logs
# ---------------------------------------------------------------------------
if ! gh api "repos/${WORKFLOW_REPO}/actions/workflows/${WORKFLOW_FILE}/runs?per_page=1" \
     >/dev/null 2>&1; then
  if [ -n "${GH_PAT_FALLBACK:-}" ]; then
    echo "::warning::App token cannot access ${WORKFLOW_REPO} run logs — using GH_PAT_FALLBACK"
    export GH_TOKEN="$GH_PAT_FALLBACK"
  else
    echo "::error::App token cannot access ${WORKFLOW_REPO} run logs and GH_PAT_FALLBACK is not set."
    echo "::error::Grant the GitHub App access to ${WORKFLOW_REPO} or set the DON_PETRY_BOT_GH_PAT secret."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Fetch recent run metadata
# ---------------------------------------------------------------------------
# GNU date: date -d "N days ago"; macOS: date -v-Nd
CUTOFF=$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)

echo "Fetching all runs since: $CUTOFF"
# Fetch with per_page=100 (GitHub API max) to capture all runs in the lookback window.
# Time-based filtering ensures we get every run created at or after CUTOFF, regardless of quantity.
runs_json=$(gh api \
  "repos/${WORKFLOW_REPO}/actions/workflows/${WORKFLOW_FILE}/runs?per_page=100&created=>=${CUTOFF}" \
  --jq '.workflow_runs | map({
    id: .id,
    status: .status,
    conclusion: .conclusion,
    created_at: .created_at,
    html_url: .html_url,
    run_number: .run_number
  })' 2>/dev/null || echo '[]')

read -r total_runs failed_runs success_runs cancelled_runs < <(echo "$runs_json" | jq -r '
  [
    length,
    ([.[] | select(.conclusion == "failure")] | length),
    ([.[] | select(.conclusion == "success")] | length),
    ([.[] | select(.conclusion == "cancelled")] | length)
  ] | @tsv')

echo "  Total runs:   $total_runs"
echo "  Successful:   $success_runs"
echo "  Failed:       $failed_runs"
echo "  Cancelled:    $cancelled_runs"
echo ""

# ---------------------------------------------------------------------------
# 2. Early exit when no failures
# ---------------------------------------------------------------------------
if [ "$failed_runs" -eq 0 ]; then
  echo "No failed runs in the last ${LOOKBACK_DAYS} days. Health check passed."
  printf '# PR Review Agent Health Check — %s\n\nAll %d run(s) inspected over the last %d days succeeded. No action required.\n' \
    "$TODAY" "$total_runs" "$LOOKBACK_DAYS" > "$REPORT_FILE"
  exit 0
fi

# Export flag for workflow step condition
[ -n "${GITHUB_ENV:-}" ] && echo "HAS_FAILURES=true" >> "$GITHUB_ENV"

# ---------------------------------------------------------------------------
# 3. Download logs for failed runs
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR"
failed_run_ids=$(echo "$runs_json" | jq -r '.[] | select(.conclusion == "failure") | .id')

for run_id in $failed_run_ids; do
  {
    gh run view "$run_id" --repo "$WORKFLOW_REPO" --log 2>/dev/null \
      | head -c 200000 \
      > "${LOG_DIR}/run_${run_id}.txt" \
      || echo "(log unavailable for run $run_id)" > "${LOG_DIR}/run_${run_id}.txt"
  } &
done
wait

# Surface log-retrieval failures so the operator knows the diagnosis may be incomplete.
missing_logs=0
for run_id in $failed_run_ids; do
  if grep -q "^(log unavailable" "${LOG_DIR}/run_${run_id}.txt" 2>/dev/null; then
    echo "::warning::Failed run $run_id: log could not be retrieved — diagnosis will be incomplete for this run"
    missing_logs=$((missing_logs + 1))
  fi
done
if [ "$missing_logs" -gt 0 ]; then
  echo "  $missing_logs of $failed_runs failed run log(s) could not be retrieved"
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Fetch workflow source for token/permission context
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
