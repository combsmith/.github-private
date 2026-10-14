#!/usr/bin/env bash
# pr_mergeready_scan.sh — daily merge-ready-and-idle PR detection net (issue #1469,
# epic #1402).
#
# Scans every OPEN PR in the target repo and flags any that is MERGE-READY yet
# STRANDED: reviewDecision APPROVED, mergeable MERGEABLE, all required checks green,
# but idle past a configurable threshold (default 12h) with NO agent acting — the
# "nothing is wrong, but nothing is happening either" failure mode #1451 sat in for
# 77h before a human noticed it. It classifies this DISTINCTLY (AC#2) from the two
# adjacent shapes so triage doesn't re-diagnose:
#   • #1425 — agent-blocked by an unresolved untrusted-bot review thread.
#   • #1427 — reviewer deferring on a pending / zombie check (ci_status pending).
# Neither is double-counted as merge-ready (AC#4).
#
# Detection ONLY (AC#3): this script never comments on, labels, merges, or triggers
# anything on a PR — a well-meaning nudge comment can itself re-arm the dev-lead /
# pr-review churn this epic is trying to eliminate (see #1427 Case A). It writes a
# markdown report and sets HAS_MERGEREADY / MERGEREADY_COUNT for the daily
# health-check workflow to surface through the existing health-check /
# automated-report issue mechanism — NO new scheduled workload.
#
# Thresholds are env-overridable (see scripts/lib/pr-mergeready-detect.sh).
#
# Env vars consumed:
#   GH_TOKEN        — must have repo read on REPO (PR list/detail, comments, threads)
#   GH_PAT_FALLBACK — optional secondary token if the primary can't read REPO
#   REPO / AGENT_REPO — target repo (default: petry-projects/.github-private)
#   TRUSTED_BOTS    — comma-separated trusted-bot logins (the #1425 trust set);
#                     derived from the reviewer-source registry when unset
#   GITHUB_ENV      — written by the Actions runner (HAS_MERGEREADY / MERGEREADY_COUNT)
#   GITHUB_STEP_SUMMARY — written by the Actions runner

set -euo pipefail

# Use a uniquely-named dir variable: the sourced libraries (pr-mergeready-detect.sh)
# reassign a plain `SCRIPT_DIR`, which would otherwise clobber ours mid-file and
# break subsequent relative `source`s.
MR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ci-status.sh: compute_ci_status filters the cascade's own + other agents'
# orchestration checks before classifying (#469 / #1427), so a green PR is not
# misread as pending on an agent's own check-run.
# shellcheck source=scripts/lib/ci-status.sh
source "${MR_SCRIPT_DIR}/lib/ci-status.sh"
# pr-mergeready-detect.sh sources pr-automation-budget.sh, giving us the canonical
# human-gate check (pr_has_escalation_label) and gather_pr_automation_events for
# the last-activity (idle) computation.
# shellcheck source=scripts/lib/pr-mergeready-detect.sh
source "${MR_SCRIPT_DIR}/lib/pr-mergeready-detect.sh"
# reviewer-sources.sh: the single #1425 trust registry, so TRUSTED_BOTS here can
# never drift from dev-lead's own trust set.
# shellcheck source=scripts/lib/reviewer-sources.sh
source "${MR_SCRIPT_DIR}/lib/reviewer-sources.sh"

REPO="${REPO:-${AGENT_REPO:-petry-projects/.github-private}}"
REPORT_FILE="${REPORT_FILE:-pr_mergeready_report.md}"
TODAY=$(date -u +%Y-%m-%d)

# TRUSTED_BOTS — the #1425 trust set. Prefer an explicit override, else derive from
# the reviewer-source registry (identical to dev-lead-intent.sh), else the pinned
# default. A thread from a bot OUTSIDE this set is the #1425 agent-blocked shape.
if [ -z "${TRUSTED_BOTS:-}" ]; then
  TRUSTED_BOTS="$(reviewer_sources_trusted_bots_csv 2>/dev/null || true)"
fi
TRUSTED_BOTS="${TRUSTED_BOTS:-copilot-pull-request-reviewer[bot],gemini-code-assist[bot],sonarqubecloud[bot],coderabbitai[bot],chatgpt-codex-connector[bot],qodo-code-review[bot],codeant-ai[bot],graphite-app[bot],cubic-dev-ai[bot]}"

echo "=== Merge-Ready-and-Idle PR Detection — Daily Scan ==="
echo "  Repo:   $REPO"
echo "  Date:   $TODAY"
echo "  Threshold: APPROVED + MERGEABLE + green, idle > ${MERGEREADY_MIN_AGE_HOURS}h (not human-gated)"
echo ""

# ---------------------------------------------------------------------------
# mergeready_fetch_review_threads <pr_number> — echo {"reviewThreads":[nodes]} with
#   each node carrying isResolved and the first comment's author {login,__typename}.
#   Includes __typename so pr_mergeready_thread_agent_blocked can tell a bot thread
#   (the #1425 shape) from a human maintainer thread. Echoes empty on any API
#   failure; the caller treats empty/malformed as NOT agent-blocked (fail-quiet).
# ---------------------------------------------------------------------------
mergeready_fetch_review_threads() {
  local pr="${1:-}"
  [ -n "$pr" ] || return 0
  local pr_url="https://github.com/${REPO}/pull/${pr}"
  # Two query shapes: first page (no cursor) and subsequent pages (with cursor).
  # shellcheck disable=SC2016  # $url/$cursor are GraphQL variable placeholders, not shell
  local _gql_first='query($url:URI!){resource(url:$url){...on PullRequest{reviewThreads(first:100){nodes{isResolved comments(first:1){nodes{author{login __typename}}}}pageInfo{hasNextPage endCursor}}}}}'
  # shellcheck disable=SC2016
  local _gql_next='query($url:URI!,$cursor:String!){resource(url:$url){...on PullRequest{reviewThreads(first:100,after:$cursor){nodes{isResolved comments(first:1){nodes{author{login __typename}}}}pageInfo{hasNextPage endCursor}}}}}'
  local all_nodes='[]' cursor="" has_next="true" _raw _page_nodes

  while [ "$has_next" = "true" ]; do
    if [ -z "$cursor" ]; then
      _raw=$(gh api graphql -f query="$_gql_first" -f url="$pr_url" 2>/dev/null) || return 1
    else
      _raw=$(gh api graphql -f query="$_gql_next" -f url="$pr_url" -f cursor="$cursor" 2>/dev/null) || return 1
    fi
    [ -n "$_raw" ] || return 1
    _page_nodes=$(printf '%s' "$_raw" | jq '.data?.resource?.reviewThreads?.nodes // empty' 2>/dev/null) || return 1
    [ -n "$_page_nodes" ] || return 1
    all_nodes=$(jq -n --argjson a "$all_nodes" --argjson b "$_page_nodes" '$a + $b') || return 1
    has_next=$(printf '%s' "$_raw" | jq -r '.data?.resource?.reviewThreads?.pageInfo?.hasNextPage // false' 2>/dev/null) || return 1
    cursor=$(printf '%s' "$_raw" | jq -r '.data?.resource?.reviewThreads?.pageInfo?.endCursor // ""' 2>/dev/null) || return 1
  done

  printf '%s' "$all_nodes" | jq '{reviewThreads: .}'
}

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
# 2. Per-PR state -> detection (detection only, no mutation)
# ---------------------------------------------------------------------------
candidates_file=$(mktemp) || {
  echo "Failed to create temp file" >&2
  exit 1
}
trap 'rm -f "$candidates_file"' EXIT
now_epoch=$(date -u +%s)
scanned=0
scan_incomplete=false

while IFS= read -r pr; do
  [ -n "$pr" ] || continue
  scanned=$(( scanned + 1 ))

  # One snapshot gives review decision, mergeability, CI rollup (with check-run
  # timestamps), labels, title, url, and updatedAt.
  if ! snapshot=$(gh pr view "$pr" --repo "$REPO" \
        --json mergeable,reviewDecision,statusCheckRollup,baseRefName,labels,title,url,updatedAt 2>/dev/null); then
    echo "  skip PR #${pr} — could not fetch (deleted, no access, or rate-limited)"
    scan_incomplete=true
    continue
  fi

  review_decision=$(jq -r '.reviewDecision // ""' <<< "$snapshot")
  mergeable=$(jq -r '.mergeable // ""' <<< "$snapshot")
  title=$(jq -r '.title // ""' <<< "$snapshot")
  html_url=$(jq -r '.url // ""' <<< "$snapshot")
  updated_at=$(jq -r '.updatedAt // ""' <<< "$snapshot")

  # Pass the COMPLETE rollup PLUS the branch ruleset's REQUIRED-check set (#1795):
  # this repo protects `main` with a ruleset, so the rollup's `.isRequired` field is
  # frequently absent and gating on the rollup alone reverts to blocking on every red
  # external check — a non-required `template-drift` failure would then hide an
  # otherwise merge-ready PR from this scan. The ruleset set is the authoritative
  # required signal (union'd with `.isRequired` inside compute_ci_status). Fail closed:
  # an unreadable set leaves it empty and compute_ci_status gates on all failing
  # checks (never misreading a genuinely-failing PR as green).
  base_ref=$(jq -r '.baseRefName // ""' <<< "$snapshot")
  required_checks=$(ruleset_required_checks "$REPO" "$base_ref" || true)
  ci_status=$(compute_ci_status "$(jq '.statusCheckRollup // []' <<< "$snapshot")" "$required_checks")

  # Human-gate exclusions (AC#2). Only the current label state is consulted.
  labels_json=$(jq -c '[.labels[]?.name]' <<< "$snapshot" 2>/dev/null || echo '[]')
  gated=false
  if pr_mergeready_is_gated "$labels_json"; then
    gated=true
  fi

  # Idle hours = time since the last activity of ANY kind — commit / comment /
  # review (via the #926 event gather, so "activity" means what the budget breaker
  # counts) AND check-run completion (statusCheckRollup timestamps), per the issue's
  # "commit, comment, or check run". gather_pr_automation_events returns [] on API
  # failure; a PR always has ≥1 commit, so [] is a reliable signal the event API is
  # unavailable — skip rather than emit a false stranded signal.
  events=$(gather_pr_automation_events "$pr" "$REPO") || events=""
  if [ "$events" = "[]" ] || [ -z "$events" ]; then
    echo "  skip PR #${pr} — event API returned no data (possible rate-limit or error); skipping to avoid false merge-ready signal"
    scan_incomplete=true
    continue
  fi
  last_event=$(jq -r '[ .[] | .when | select(. != null and . != "") ] | max // ""' <<< "$events" 2>/dev/null || echo "")
  last_check=$(jq -r '
    [ (.statusCheckRollup // [])[]
      | (.completedAt // .startedAt // .completed_at // .started_at // "")
      | select(. != null and . != "") ] | max // ""' <<< "$snapshot" 2>/dev/null || echo "")
  # Most recent of event / check-run / updatedAt (ISO-8601 sorts lexicographically).
  last_activity="$updated_at"
  if [[ "$last_event" > "$last_activity" ]]; then
    last_activity="$last_event"
  fi
  if [[ "$last_check" > "$last_activity" ]]; then
    last_activity="$last_check"
  fi
  hours_idle=$(pr_mergeready_hours_since "$last_activity" "$now_epoch")

  # Compute the #1425 discriminator only when the PR is otherwise a merge-ready
  # candidate (approved + mergeable + green + idle + not gated) — this bounds the
  # extra GraphQL call to the handful of PRs that could actually be flagged.
  agent_blocked=false
  if [ "$gated" != "true" ] \
     && [ "$review_decision" = "APPROVED" ] \
     && [ "$mergeable" = "MERGEABLE" ] \
     && [ "$ci_status" = "passing" ] \
     && [ "$hours_idle" -gt "$(_mergeready_threshold "${MERGEREADY_MIN_AGE_HOURS}" 12)" ]; then
    if ! threads_json=$(mergeready_fetch_review_threads "$pr"); then
      echo "  skip PR #${pr} — review-thread query failed (API error or parse failure); skipping to avoid false merge-ready signal"
      scan_incomplete=true
      continue
    fi
    if [ -n "$threads_json" ] && pr_mergeready_thread_agent_blocked "$threads_json" "$TRUSTED_BOTS"; then
      agent_blocked=true
    fi
  fi

  shape=$(pr_mergeready_shape "$review_decision" "$mergeable" "$ci_status" "$agent_blocked" "$hours_idle" "$gated")

  case "$shape" in
    agent-blocked)
      echo "  note PR #${pr} — agent-blocked (#1425 shape: unresolved untrusted-bot thread); not counted as merge-ready"
      ;;
    reviewer-defer)
      echo "  note PR #${pr} — reviewer-defer (#1427 shape: pending/zombie check); not counted as merge-ready"
      ;;
  esac

  reason=$(pr_mergeready_reasons "$review_decision" "$mergeable" "$ci_status" "$agent_blocked" "$hours_idle" "$gated")
  if [ -n "$reason" ]; then
    # Sanitize the title for a single markdown table cell: strip newlines/tabs (the
    # TSV delimiter) and pipes (the markdown column delimiter).
    safe_title=$(printf '%s' "$title" | tr '\n\t|' '   ')
    printf '%s\t%s\t%s\t%s\n' "$pr" "$html_url" "$safe_title" "$reason" \
      >> "$candidates_file"
    echo "::warning::Merge-ready but idle PR #${pr} — ${reason}"
  fi
done <<< "$open_prs"

# grep -c prints the count even at zero matches (exiting 1), so `|| true` swallows
# that exit without appending a second "0".
mergeready_count=$(grep -c . "$candidates_file" 2>/dev/null || true)
mergeready_count=${mergeready_count:-0}
echo "Scanned ${scanned} open PR(s); ${mergeready_count} merge-ready-idle candidate(s)."

# ---------------------------------------------------------------------------
# 3. Render report + export env flags
# ---------------------------------------------------------------------------
{
  printf '# Merge-Ready-and-Idle PR Detection — %s\n\n' "$TODAY"
  printf '**Repo:** `%s` | **Open PRs scanned:** %s | **Candidates:** %s\n\n' \
    "$REPO" "$scanned" "$mergeready_count"
  if [ "$scan_incomplete" = "true" ]; then
    printf '> ⚠️ **Scan incomplete**: one or more PRs were skipped due to API errors or rate limits. The candidate count above may understate actual stranded PRs.\n\n'
  fi
  generate_mergeready_report "$candidates_file"
} > "$REPORT_FILE"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"
fi

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "MERGEREADY_COUNT=${mergeready_count}" >> "$GITHUB_ENV"
  if [ "$mergeready_count" -gt 0 ]; then
    echo "HAS_MERGEREADY=true" >> "$GITHUB_ENV"
  elif [ "$scan_incomplete" = "true" ]; then
    echo "::warning::Merge-ready scan incomplete (PRs skipped due to API errors) — not emitting HAS_MERGEREADY=false to avoid a false all-clear"
  else
    echo "HAS_MERGEREADY=false" >> "$GITHUB_ENV"
  fi
fi

echo ""
echo "Report written to ${REPORT_FILE} ($(wc -c < "$REPORT_FILE") bytes)"
echo "=== Merge-ready-and-idle scan complete ==="
