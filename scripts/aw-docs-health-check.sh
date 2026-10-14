#!/usr/bin/env bash
# Docs Health Check — scans all org repos for docs files not updated in
# STALE_DAYS (default: 90) days and opens a GitHub issue with the findings.
#
# Env vars consumed:
#   GH_TOKEN                  — PAT with repo scope (passed via gh CLI)
#   CLAUDE_CODE_OAUTH_TOKEN   — Claude auth token
#   ORG                       — GitHub org to scan (default: petry-projects)
#   STALE_DAYS                — staleness threshold in days (default: 90)
#   DOCS_STALENESS_IGNORE     — comma-separated path patterns to skip
#   REPORT_REPO               — repo to open the issue on (default: ORG/.github-private)
#   GITHUB_ENV                — set by Actions runner

set -euo pipefail

# Model family → current id resolver (#1979): name a family, never pin a version.
# shellcheck source=scripts/lib/engine-models.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/engine-models.sh"

ORG="${ORG:-petry-projects}"
STALE_DAYS="${STALE_DAYS:-90}"
REPORT_REPO="${REPORT_REPO:-${ORG}/.github-private}"
TODAY=$(date -u +%Y-%m-%d)

# Portable date arithmetic (GNU date / macOS date)
CUTOFF=$(date -u -d "${STALE_DAYS} days ago" +%Y-%m-%d 2>/dev/null \
  || date -u -v-"${STALE_DAYS}"d +%Y-%m-%d)

echo "=== Docs Health Check ==="
echo "  Org:          ${ORG}"
echo "  Stale after:  ${STALE_DAYS} days (cutoff: ${CUTOFF})"
echo "  Report repo:  ${REPORT_REPO}"
echo "  Date:         ${TODAY}"
echo ""

# ---------------------------------------------------------------------------
# 1. Build ignore list
# ---------------------------------------------------------------------------
IFS=',' read -ra _IGNORE_RAW <<< "${DOCS_STALENESS_IGNORE:-}"
IGNORE_PATTERNS=()
for _p in "${_IGNORE_RAW[@]}"; do
  _p="${_p#"${_p%%[![:space:]]*}"}"  # ltrim
  _p="${_p%"${_p##*[![:space:]]}"}"  # rtrim
  [ -n "$_p" ] && IGNORE_PATTERNS+=("$_p")
done

_is_ignored() {
  local path="$1"
  for pattern in "${IGNORE_PATTERNS[@]+"${IGNORE_PATTERNS[@]}"}"; do
    case "$path" in
      *"$pattern"*) return 0 ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# 2. Enumerate repos
# ---------------------------------------------------------------------------
echo "Enumerating repos in ${ORG}..."
repos=$(gh api "orgs/${ORG}/repos?per_page=100&type=all" \
  --jq '[.[] | select(.archived == false)] | .[].full_name' 2>/dev/null || true)

if [ -z "$repos" ]; then
  echo "::error::Could not enumerate repos for org ${ORG} — check GH_TOKEN scope."
  exit 1
fi

repo_count=$(echo "$repos" | wc -l | tr -d ' ')
echo "  Found ${repo_count} active repos."
echo ""

# ---------------------------------------------------------------------------
# 3. Scan docs files per repo
# ---------------------------------------------------------------------------
stale_entries=""
_api_tmpfile=$(mktemp)
trap 'rm -f "$_api_tmpfile"' EXIT

while IFS= read -r repo; do
  # Fetch docs/ directory listing; 404 means no docs dir (skip), any other error is fatal
  if ! docs_listing=$(gh api "repos/${repo}/contents/docs" \
      --jq '.[].name' 2>"$_api_tmpfile"); then
    if grep -qi "404\|not found" "$_api_tmpfile" 2>/dev/null; then
      continue
    fi
    echo "::error::API failure listing docs/ for ${repo}: $(cat "$_api_tmpfile")"
    exit 1
  fi

  [ -z "$docs_listing" ] && continue

  while IFS= read -r doc_name; do
    full_path="${repo}/docs/${doc_name}"

    _is_ignored "$full_path" && continue

    # Get last commit date for this file; API failures are fatal (not silently skipped)
    if ! last_commit=$(gh api \
        "repos/${repo}/commits?path=docs/${doc_name}&per_page=1" \
        --jq '.[0].commit.author.date // ""' 2>"$_api_tmpfile"); then
      echo "::error::API failure fetching commits for ${repo}/docs/${doc_name}: $(cat "$_api_tmpfile")"
      exit 1
    fi

    [ -z "$last_commit" ] && continue

    commit_date="${last_commit:0:10}"  # YYYY-MM-DD

    if [[ "$commit_date" < "$CUTOFF" ]]; then
      days_stale=$(( ($(date -u -d "$TODAY" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d' "$TODAY" +%s) \
                    - $(date -u -d "$commit_date" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d' "$commit_date" +%s)) \
                    / 86400 ))
      stale_entries="${stale_entries}${full_path}\t${commit_date}\t${days_stale}\n"
    fi
  done <<< "$docs_listing"
done <<< "$repos"

# ---------------------------------------------------------------------------
# 4. Early exit when no stale docs
# ---------------------------------------------------------------------------
if [ -z "$stale_entries" ]; then
  echo "No stale docs found. Health check passed."
  [ -n "${GITHUB_ENV:-}" ] && echo "HAS_STALE_DOCS=false" >> "$GITHUB_ENV"
  exit 0
fi

stale_count=$(printf '%b' "$stale_entries" | wc -l | tr -d ' ')
echo "Found ${stale_count} stale doc file(s)."
[ -n "${GITHUB_ENV:-}" ] && echo "HAS_STALE_DOCS=true" >> "$GITHUB_ENV"

# ---------------------------------------------------------------------------
# 5. Build stale-files table for Claude
# ---------------------------------------------------------------------------
stale_table="| File | Last Updated | Days Stale |\n|------|-------------|------------|\n"
while IFS=$'\t' read -r path date days; do
  stale_table="${stale_table}| \`${path}\` | ${date} | ${days} |\n"
done < <(printf '%b' "$stale_entries" | sort -t$'\t' -k3 -rn)

# ---------------------------------------------------------------------------
# 6. Invoke Claude for prioritised report
# ---------------------------------------------------------------------------
REPORT_FILE="${REPORT_FILE:-docs_health_report.md}"

echo "Invoking Claude for stale-docs analysis..."
if ! claude --print --model "$(ai_model_for_family sonnet)" --no-session-persistence \
     > "$REPORT_FILE" <<PROMPT
You are the Docs Health Check for the GitHub org \`${ORG}\`.

## Context
- Analysis date: ${TODAY}
- Staleness threshold: ${STALE_DAYS} days (no commit since ${CUTOFF})
- Total active repos scanned: ${repo_count}
- Stale doc files found: ${stale_count}

## Stale Files
$(printf '%b' "$stale_table")

---

Produce a concise markdown health report with the following sections:

### Executive Summary
**Status:** STALE_DOCS_FOUND
**Stale files:** ${stale_count}

Key findings:
- <most-stale file and owner if determinable>
- <any cluster of staleness (same repo, same team)>

Action required: <one imperative sentence>

### Stale Files by Repo
Group the stale files by repo. For each repo, list files sorted by days-stale descending.

### Recommendations
Numbered list. For each significant cluster of staleness: what team owns it, suggested
action (refresh, archive, redirect), and urgency: [HIGH | MEDIUM | LOW] based on
days stale (>365=HIGH, 180-365=MEDIUM, 90-180=LOW).

Output ONLY the markdown report — no preamble or commentary outside the sections.
PROMPT
then
  echo "::error::Claude invocation failed. CLI output:"
  cat "$REPORT_FILE" >&2
  exit 1
fi

echo "Report written to ${REPORT_FILE} ($(wc -c < "$REPORT_FILE") bytes)."
echo "=== Docs health check complete ==="
