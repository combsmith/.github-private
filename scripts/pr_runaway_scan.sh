#!/usr/bin/env bash
# pr_runaway_scan.sh — daily runaway-PR detection net (issue #948, #860 follow-up).
#
# Scans every OPEN PR in the target repo and flags any that has crossed a soft
# runaway threshold (commits / comments / automated cycles / age-with-churn) as a
# runaway CANDIDATE, with a direct link and the triggering metric. This is the
# push signal #860 lacked — it ran for four days unnoticed. Detection ONLY: this
# script never comments on, labels, or otherwise mutates a PR; it just writes a
# markdown report and sets HAS_RUNAWAY for the health-check workflow to surface
# through the existing health-check / automated-report issue mechanism.
#
# Thresholds are env-overridable (see scripts/lib/pr-runaway-detect.sh).
#
# Env vars consumed:
#   GH_TOKEN        — must have repo read on REPO (PR list/detail, comments)
#   GH_PAT_FALLBACK — optional secondary token if the primary can't read REPO
#   REPO / AGENT_REPO — target repo (default: petry-projects/.github-private)
#   GITHUB_ENV      — written by the Actions runner (HAS_RUNAWAY / RUNAWAY_COUNT)
#   GITHUB_STEP_SUMMARY — written by the Actions runner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/pr-automation-budget.sh
source "${SCRIPT_DIR}/lib/pr-automation-budget.sh"
# shellcheck source=scripts/lib/pr-runaway-detect.sh
source "${SCRIPT_DIR}/lib/pr-runaway-detect.sh"

REPO="${REPO:-${AGENT_REPO:-petry-projects/.github-private}}"
REPORT_FILE="${REPORT_FILE:-pr_runaway_report.md}"
TODAY=$(date -u +%Y-%m-%d)

echo "=== Runaway-PR Detection — Daily Scan ==="
echo "  Repo:   $REPO"
echo "  Date:   $TODAY"
echo "  Thresholds: commits>${RUNAWAY_MAX_COMMITS} comments>${RUNAWAY_MAX_COMMENTS} cycles>${RUNAWAY_MAX_CYCLES} age>${RUNAWAY_MIN_AGE_HOURS}h(+churn) merge-stacked(>${REBASE_SMELL_MIN_COMMITS} commits,<${REBASE_SMELL_MAX_FILES} files)"
echo ""

# ---------------------------------------------------------------------------
# 0. Token selection — fall back to GH_PAT_FALLBACK if REPO is unreachable
# ---------------------------------------------------------------------------
if ! gh api "repos/${REPO}" >/dev/null 2>&1; then
  if [ -n "${GH_PAT_FALLBACK:-}" ]; then
    echo "::warning::GH_TOKEN cannot access ${REPO} — using GH_PAT_FALLBACK"
    export GH_TOKEN="$GH_PAT_FALLBACK"
    if ! gh api "repos/${REPO}" >/dev/null 2>&1; then
      echo "::error::GH_PAT_FALLBACK also cannot access ${REPO}."
      exit 1
    fi
  else
    echo "::error::GH_TOKEN cannot access ${REPO} and GH_PAT_FALLBACK is not set."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Enumerate open PRs
# ---------------------------------------------------------------------------
open_prs=$(gh api --paginate "repos/${REPO}/pulls?state=open&per_page=100" \
  --jq '.[].number' 2>/dev/null) || {
  echo "::error::Failed to fetch open PRs from GitHub API." >&2
  exit 1
}

if [ -z "$open_prs" ]; then
  echo "No open PRs in ${REPO}."
fi

# ---------------------------------------------------------------------------
# 2. Per-PR metrics -> detection (detection only, no mutation)
# ---------------------------------------------------------------------------
candidates_file=$(mktemp) || {
  echo "Failed to create temp file" >&2
  exit 1
}
trap 'rm -f "$candidates_file"' EXIT
now_epoch=$(date -u +%s)
scanned=0

while IFS= read -r pr; do
  [ -n "$pr" ] || continue
  scanned=$(( scanned + 1 ))

  # Single detail call gives commit/comment/file counts + created_at + link + title.
  detail=$(gh api "repos/${REPO}/pulls/${pr}" \
    --jq '{commits, comments, changed_files, created_at, html_url, title}' 2>/dev/null || echo '{}')
  IFS=$'\t' read -r commits comments changed_files created_at html_url title <<< "$(jq -r '[.commits // 0, .comments // 0, .changed_files // 0, .created_at // "", .html_url // "", (.title // "" | tostring)] | @tsv' <<< "$detail")"

  # Automated cycles since the last human — reuse the #926 budget computation so
  # the two guards agree on what "an automated cycle" means.
  events=$(gather_pr_automation_events "$pr" "$REPO")
  cycles=$(compute_pr_automation_cycles "$events")

  age_hours=$(pr_age_hours "$created_at" "$now_epoch")

  # Combine the runaway thresholds (#948) with the merge-stacked rebase/squash
  # smell (#949) in pure bash — avoids a per-PR subshell + sed fork.
  reasons_runaway=$(pr_runaway_reasons "$commits" "$comments" "$cycles" "$age_hours")
  reasons_smell=$(pr_rebase_smell "$commits" "$changed_files")
  if [ -n "$reasons_runaway" ] && [ -n "$reasons_smell" ]; then
    reasons="${reasons_runaway}
${reasons_smell}"
  else
    reasons="${reasons_runaway:-$reasons_smell}"
  fi
  if [ -n "$reasons" ]; then
    # Sanitize the title for a single markdown table cell: strip newlines/tabs
    # (the TSV delimiter) and pipes (the markdown column delimiter).
    safe_title=$(printf '%s' "$title" | tr '\n\t|' '   ')
    joined=$(printf '%s' "$reasons" | paste -sd';' - | sed 's/;/; /g')
    printf '%s\t%s\t%s\t%s\n' "$pr" "$html_url" "$safe_title" "$joined" \
      >> "$candidates_file"
    echo "::warning::Runaway candidate PR #${pr} — ${joined}"
  fi
done <<< "$open_prs"

# grep -c prints the count to stdout even at zero matches (exiting 1), so `|| true`
# swallows that exit without appending a second "0".
runaway_count=$(grep -c . "$candidates_file" 2>/dev/null || true)
runaway_count=${runaway_count:-0}
echo "Scanned ${scanned} open PR(s); ${runaway_count} runaway candidate(s)."

# ---------------------------------------------------------------------------
# 3. Render report + export env flags
# ---------------------------------------------------------------------------
{
  printf '# Runaway PR Detection — %s\n\n' "$TODAY"
  printf '**Repo:** `%s` | **Open PRs scanned:** %s | **Candidates:** %s\n\n' \
    "$REPO" "$scanned" "$runaway_count"
  generate_runaway_report "$candidates_file"
} > "$REPORT_FILE"

[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "RUNAWAY_COUNT=${runaway_count}" >> "$GITHUB_ENV"
  if [ "$runaway_count" -gt 0 ]; then
    echo "HAS_RUNAWAY=true" >> "$GITHUB_ENV"
  else
    echo "HAS_RUNAWAY=false" >> "$GITHUB_ENV"
  fi
fi

echo ""
echo "Report written to ${REPORT_FILE} ($(wc -c < "$REPORT_FILE") bytes)"
echo "=== Runaway-PR scan complete ==="
