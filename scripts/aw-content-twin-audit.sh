#!/usr/bin/env bash
# ContentTwin Content Audit — checks the ContentTwin content pipeline for
# stale content, empty queue, and publishing workflow failures.
# Opens or updates a GitHub issue in the ContentTwin repo when problems are found.
#
# Env vars consumed:
#   GH_TOKEN                  — PAT with repo + actions:read on ContentTwin
#   CLAUDE_CODE_OAUTH_TOKEN   — Claude auth token
#   CONTENT_TWIN_REPO         — target repo (default: combsmith/ContentTwin)
#   STALE_DAYS                — days without commit threshold (default: 7)
#   PUBLISH_WORKFLOW          — workflow file to check for failures (default: publish.yml)
#   REPORT_FILE               — output markdown file (default: content_twin_audit_report.md)
#   GITHUB_ENV                — set by Actions runner

set -euo pipefail

CONTENT_TWIN_REPO="${CONTENT_TWIN_REPO:-combsmith/ContentTwin}"
STALE_DAYS="${STALE_DAYS:-7}"
PUBLISH_WORKFLOW="${PUBLISH_WORKFLOW:-publish.yml}"
REPORT_FILE="${REPORT_FILE:-content_twin_audit_report.md}"
AUDIT_LABEL="content-audit"
TODAY=$(date -u +%Y-%m-%d)

CUTOFF=$(date -u -d "${STALE_DAYS} days ago" +%Y-%m-%d 2>/dev/null \
  || date -u -v-"${STALE_DAYS}"d +%Y-%m-%d)

echo "=== ContentTwin Content Audit ==="
echo "  Repo:             ${CONTENT_TWIN_REPO}"
echo "  Stale threshold:  ${STALE_DAYS} days (since ${CUTOFF})"
echo "  Publish workflow: ${PUBLISH_WORKFLOW}"
echo "  Date:             ${TODAY}"
echo ""

# ---------------------------------------------------------------------------
# 0. Verify repo access
# ---------------------------------------------------------------------------
if ! gh api "repos/${CONTENT_TWIN_REPO}" --silent 2>/dev/null; then
  echo "::error::Cannot access repo ${CONTENT_TWIN_REPO} — check GH_TOKEN scope."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Check content freshness
# ---------------------------------------------------------------------------
echo "Checking content freshness..."
recent_commit=$(gh api "repos/${CONTENT_TWIN_REPO}/commits?per_page=1" \
  --jq '.[0].commit.author.date // ""' 2>/dev/null || true)

stale_content=false
days_since_commit="unknown"

if [ -n "$recent_commit" ]; then
  last_commit_date="${recent_commit:0:10}"
  if [[ "$last_commit_date" < "$CUTOFF" ]]; then
    stale_content=true
    # Calculate days since last commit
    today_epoch=$(date -u -d "$TODAY" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d' "$TODAY" +%s)
    commit_epoch=$(date -u -d "$last_commit_date" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d' "$last_commit_date" +%s)
    days_since_commit=$(( (today_epoch - commit_epoch) / 86400 ))
    echo "  Stale: last commit was ${days_since_commit} days ago (${last_commit_date})"
  else
    echo "  Fresh: last commit on ${last_commit_date}"
  fi
else
  echo "  ::warning::Could not determine last commit date."
fi

# ---------------------------------------------------------------------------
# 2. Check content queue
# ---------------------------------------------------------------------------
echo "Checking content queue..."
queue_empty=false

_queue_err=$(mktemp)
if ! queue_files=$(gh api "repos/${CONTENT_TWIN_REPO}/contents/queue" \
    --jq 'length' 2>"$_queue_err"); then
  if grep -qiE 'HTTP 404|Not Found' "$_queue_err" 2>/dev/null; then
    queue_files="0"
  else
    echo "::error::Content queue API error: $(cat "$_queue_err")"
    rm -f "$_queue_err"
    exit 1
  fi
fi
rm -f "$_queue_err"

if [ "$queue_files" = "0" ] || [ -z "$queue_files" ]; then
  echo "  Queue appears empty; checking persistence before alerting..."
  queue_last_commit=$(gh api "repos/${CONTENT_TWIN_REPO}/commits?path=queue&per_page=1" \
    --jq '.[0].commit.author.date // ""' 2>/dev/null || true)
  if [ -n "$queue_last_commit" ]; then
    queue_commit_epoch=$(date -u -d "${queue_last_commit}" +%s 2>/dev/null \
      || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${queue_last_commit}" +%s)
    now_epoch=$(date -u +%s)
    queue_empty_hours=$(( (now_epoch - queue_commit_epoch) / 3600 ))
    if [ "$queue_empty_hours" -ge 24 ]; then
      queue_empty=true
      echo "  Queue is empty and has been since ${queue_last_commit:0:10} (${queue_empty_hours}h ago)"
    else
      echo "  Queue is empty but last activity was ${queue_empty_hours}h ago — treating as transient"
    fi
  else
    queue_empty=true
    echo "  Queue is empty (0 items in queue/)"
  fi
else
  echo "  Queue has ${queue_files} item(s)"
fi

# ---------------------------------------------------------------------------
# 3. Check publishing workflow failures
# ---------------------------------------------------------------------------
echo "Checking publishing workflow failures..."
LOOKBACK_CUTOFF=$(date -u -d "7 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ)

publish_runs=$(gh api \
  "repos/${CONTENT_TWIN_REPO}/actions/workflows/${PUBLISH_WORKFLOW}/runs?per_page=20&created=>=${LOOKBACK_CUTOFF}" \
  --jq '.workflow_runs | map({id: .id, conclusion: .conclusion, created_at: .created_at, html_url: .html_url, run_number: .run_number})' \
  2>/dev/null || echo '[]')

failed_runs=$(echo "$publish_runs" | jq -r '[.[] | select(.conclusion == "failure")] | length')
total_runs=$(echo "$publish_runs" | jq -r 'length')
failed_run_urls=$(echo "$publish_runs" | jq -r \
  '[.[] | select(.conclusion == "failure") | "- [Run #\(.run_number)](\(.html_url)) — failed at \(.created_at[:10])"] | .[]' \
  2>/dev/null || true)

has_publish_failures=false
if [ "$failed_runs" -gt 0 ]; then
  has_publish_failures=true
  echo "  Publish failures: ${failed_runs} of ${total_runs} recent runs failed"
else
  echo "  Publish runs: ${total_runs} recent runs — no failures"
fi

# ---------------------------------------------------------------------------
# 4. Determine if action is needed
# ---------------------------------------------------------------------------
has_issues=false
[ "$stale_content" = "true" ] && has_issues=true
[ "$queue_empty" = "true" ] && has_issues=true
[ "$has_publish_failures" = "true" ] && has_issues=true

if [ "$has_issues" = "false" ]; then
  echo ""
  echo "::notice::ContentTwin audit passed — all signals healthy."
  [ -n "${GITHUB_ENV:-}" ] && echo "HAS_CONTENT_ISSUES=false" >> "$GITHUB_ENV"
  exit 0
fi

[ -n "${GITHUB_ENV:-}" ] && echo "HAS_CONTENT_ISSUES=true" >> "$GITHUB_ENV"

# ---------------------------------------------------------------------------
# 5. Invoke Claude for audit report
# ---------------------------------------------------------------------------
echo ""
echo "Issues detected. Invoking Claude for audit report..."

if ! claude --print --model claude-sonnet-4-6 --no-session-persistence \
     > "$REPORT_FILE" <<PROMPT
You are the ContentTwin Content Audit for the \`${CONTENT_TWIN_REPO}\` repo.

## Audit Date
${TODAY}

## Health Signals
- **Content freshness:** $([ "$stale_content" = "true" ] && echo "STALE — ${days_since_commit} days since last commit (threshold: ${STALE_DAYS} days)" || echo "OK")
- **Content queue:** $([ "$queue_empty" = "true" ] && echo "EMPTY — 0 items in queue/" || echo "OK — ${queue_files} items")
- **Publishing workflow:** $([ "$has_publish_failures" = "true" ] && echo "FAILURES — ${failed_runs} of ${total_runs} recent runs failed" || echo "OK — all recent runs passed")

## Failed Publish Runs
${failed_run_urls:-None}

---

Produce a concise markdown audit report:

### Status
**Status:** ISSUES_DETECTED
**Date:** ${TODAY}

| Signal | Status | Detail |
|--------|--------|--------|
$([ "$stale_content" = "true" ] && echo "| Content freshness | ❌ STALE | ${days_since_commit} days since last commit |" || echo "| Content freshness | ✅ OK | Recent commits found |")
$([ "$queue_empty" = "true" ] && echo "| Content queue | ❌ EMPTY | No pending items in queue/ |" || echo "| Content queue | ✅ OK | ${queue_files} items pending |")
$([ "$has_publish_failures" = "true" ] && echo "| Publishing workflow | ❌ FAILURES | ${failed_runs} of ${total_runs} recent runs failed |" || echo "| Publishing workflow | ✅ OK | All recent runs passed |")

### Analysis
<For each failing signal: explain the likely cause and business impact in 1-2 sentences.>

### Failed Runs (if any)
<List the failed run links from the Failed Publish Runs section above, or "None".>

### Recommended Actions
<Numbered list of specific actions to resolve each issue, with urgency: [CRITICAL | HIGH | MEDIUM].>

Output ONLY the markdown report — no preamble outside the sections.
PROMPT
then
  echo "::error::Claude invocation failed. CLI output:"
  cat "$REPORT_FILE" >&2
  exit 1
fi

echo "Report written to ${REPORT_FILE} ($(wc -c < "$REPORT_FILE") bytes)."

# ---------------------------------------------------------------------------
# 6. Check for existing open issue (dedup)
# ---------------------------------------------------------------------------
existing_issue=$(gh api "repos/${CONTENT_TWIN_REPO}/issues?labels=${AUDIT_LABEL}&state=open&per_page=1" \
  --jq '[.[] | select(.pull_request == null)] | .[0].number // ""' 2>/dev/null || true)

# Truncate report before publication to avoid GitHub API payload limits
_max_bytes=60000
if [ "$(wc -c < "$REPORT_FILE")" -gt "$_max_bytes" ]; then
  head -c "$_max_bytes" "$REPORT_FILE" > "${REPORT_FILE}.tmp"
  printf '\n\n---\n_Report truncated at %d bytes._\n' "$_max_bytes" >> "${REPORT_FILE}.tmp"
  mv "${REPORT_FILE}.tmp" "$REPORT_FILE"
fi

report_body=$(cat "$REPORT_FILE")

if [ -n "$existing_issue" ]; then
  echo "Updating existing issue #${existing_issue} with new audit findings..."
  gh api "repos/${CONTENT_TWIN_REPO}/issues/${existing_issue}/comments" \
    --method POST \
    --field "body=**Audit update — ${TODAY}**

${report_body}" \
    --silent
  echo "  Comment added to issue #${existing_issue}."
else
  echo "Opening new content audit issue in ${CONTENT_TWIN_REPO}..."
  gh api "repos/${CONTENT_TWIN_REPO}/issues" \
    --method POST \
    --field "title=ContentTwin Audit — content pipeline issues ${TODAY}" \
    --field "body=${report_body}" \
    --field "labels[]=${AUDIT_LABEL}" \
    --field "labels[]=automated-report" \
    --silent
  echo "  Issue created."
fi

echo ""
echo "=== ContentTwin audit complete ==="
