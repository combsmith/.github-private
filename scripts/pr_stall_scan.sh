#!/usr/bin/env bash
# pr_stall_scan.sh — daily stall-PR detection net (issue #1410, epic #1402).
#
# Scans every OPEN PR in the target repo and flags any that is STALLED: stuck
# CI-green + REVIEW_REQUIRED, not yet reviewed at head, with no agent activity and
# no pending triggering event past a configurable threshold — and NOT human-gated.
# That is the exact silent failure mode the narrowed Class-2 timers (#1407/#1408)
# could introduce; this is the pushed signal that catches it (the #860 lesson:
# detection must be pushed, not pulled). Detection ONLY: this script never
# comments on, labels, or otherwise mutates a PR. It writes a markdown report and
# sets HAS_STALL / STALL_COUNT for the daily health-check workflow to surface
# through the existing health-check / automated-report issue mechanism — NO new
# scheduled workload (AC#4).
#
# Thresholds are env-overridable (see scripts/lib/pr-stall-detect.sh).
#
# Env vars consumed:
#   GH_TOKEN        — must have repo read on REPO (PR list/detail, comments)
#   GH_PAT_FALLBACK — optional secondary token if the primary can't read REPO
#   REPO / AGENT_REPO — target repo (default: petry-projects/.github-private)
#   GITHUB_ENV      — written by the Actions runner (HAS_STALL / STALL_COUNT)
#   GITHUB_STEP_SUMMARY — written by the Actions runner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ci-status.sh: compute_ci_status filters the cascade's own checks before
# classifying, exactly as review-one-pr.sh / sweep-stuck-reviews.sh do (#469).
# shellcheck source=scripts/lib/ci-status.sh
source "${SCRIPT_DIR}/lib/ci-status.sh"
# standing-approval.sh (#1665): pr_standing_approval_count — the authoritative
# "does an approving review STAND at head?" primitive for the stranded-approval
# backstop section (AC8). Shared with sweep-stuck-reviews.sh. Sourced BEFORE
# pr-stall-detect.sh, which reassigns SCRIPT_DIR to its own lib dir.
# shellcheck source=scripts/lib/standing-approval.sh
source "${SCRIPT_DIR}/lib/standing-approval.sh"
# pr-stall-detect.sh sources pr-automation-budget.sh, giving us the canonical
# human-gate check (pr_has_escalation_label), the exhaustion marker constant, and
# gather_pr_automation_events for the last-activity (idle) computation.
# shellcheck source=scripts/lib/pr-stall-detect.sh
source "${SCRIPT_DIR}/lib/pr-stall-detect.sh"

REPO="${REPO:-${AGENT_REPO:-petry-projects/.github-private}}"
REPORT_FILE="${REPORT_FILE:-pr_stall_report.md}"
TODAY=$(date -u +%Y-%m-%d)

echo "=== Stall-PR Detection — Daily Scan ==="
echo "  Repo:   $REPO"
echo "  Date:   $TODAY"
echo "  Threshold: green + REVIEW_REQUIRED idle > ${STALL_MIN_AGE_MINUTES}m (not human-gated)"
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
# 2. Per-PR state -> detection (detection only, no mutation)
# ---------------------------------------------------------------------------
# Accumulate candidate TSV rows in plain variables (no temp files, so nothing can
# be orphaned on an early exit). candidates_rows is the stall net; stranded_rows is
# the independent #1665 stranded-approval backstop (AC8): green + auto-merge armed +
# no standing approval + idle > threshold. Each row: pr <TAB> url <TAB> title <TAB>
# reason, newline-separated.
candidates_rows=""
stranded_rows=""
now_epoch=$(date -u +%s)
scanned=0
scan_incomplete=false

while IFS= read -r pr; do
  [ -n "$pr" ] || continue
  scanned=$(( scanned + 1 ))

  # One snapshot gives CI rollup, review decision, head, review/comment bodies,
  # labels, title, and url — the same shape sweep-stuck-reviews.sh consumes.
  if ! snapshot=$(gh pr view "$pr" --repo "$REPO" \
        --json headRefOid,baseRefName,statusCheckRollup,reviewDecision,reviews,comments,labels,title,url,updatedAt,autoMergeRequest 2>/dev/null); then
    echo "  skip PR #${pr} — could not fetch (deleted, no access, or rate-limited)"
    scan_incomplete=true
    continue
  fi

  review_decision=$(jq -r '.reviewDecision // ""' <<< "$snapshot")
  head_sha=$(jq -r '.headRefOid // ""' <<< "$snapshot")
  title=$(jq -r '.title // ""' <<< "$snapshot")
  html_url=$(jq -r '.url // ""' <<< "$snapshot")
  updated_at=$(jq -r '.updatedAt // ""' <<< "$snapshot")

  # Gate on the branch ruleset's REQUIRED checks (#1795) so a red non-required check
  # (e.g. template-drift) is not mistaken for a genuine stall signal. Fail closed:
  # an unreadable set gates on all failing checks.
  base_ref=$(jq -r '.baseRefName // ""' <<< "$snapshot")
  required_checks=$(ruleset_required_checks "$REPO" "$base_ref" || true)
  ci_status=$(compute_ci_status "$(jq '.statusCheckRollup' <<< "$snapshot")" "$required_checks")

  # Already reviewed at this exact head? The cascade stamps each review with
  # `<!-- pr-review-agent v1 sha=<HEAD> -->`; a marker at the current head means
  # the automated step ran, so the PR is not stalled. Match the sha followed by a
  # space so one sha is never treated as a prefix of another (same as the sweep).
  reviewed_at_head=$(jq -r --arg sha "$head_sha" '
    [ ((.reviews // []) + (.comments // []))[]
      | (.body // "")
      | select(test("<!-- pr-review-agent v1 sha=" + $sha + " ")) ]
    | length' <<< "$snapshot" 2>/dev/null || echo 0)

  # Human-gate exclusions (AC#2). Only the current label state is consulted:
  # the exhaustion marker is an immutable audit comment that can never be cleared,
  # so gating on it would permanently suppress detection for re-engaged PRs —
  # unlike needs-human-review, which a human can remove to resume detection.
  labels_json=$(jq -c '[.labels[]?.name]' <<< "$snapshot" 2>/dev/null || echo '[]')
  gated=false
  if pr_stall_is_gated "$labels_json"; then
    gated=true
  fi

  # Idle minutes = time since the last activity of ANY kind (commit / comment /
  # review) — reuse the #926 event gather so "activity" means the same thing the
  # budget breaker counts. gather_pr_automation_events silently returns [] on API
  # failures (rate limits, errors), making it impossible to distinguish genuine
  # "no activity" from unavailable data. A PR always has at least one commit, so
  # an empty result is a reliable signal that the event API is unavailable — skip
  # the PR rather than falling back to potentially misleading updatedAt data.
  events=$(gather_pr_automation_events "$pr" "$REPO")
  if [ "$events" = "[]" ] || [ -z "$events" ]; then
    echo "  skip PR #${pr} — event API returned no data (possible rate-limit or error); skipping to avoid false stall signal"
    scan_incomplete=true
    continue
  fi
  last_activity=$(jq -r '[ .[] | .when | select(. != null and . != "") ] | max // ""' <<< "$events" 2>/dev/null || echo "")
  [ -n "$last_activity" ] || last_activity="$updated_at"
  mins_idle=$(pr_minutes_since "$last_activity" "$now_epoch")

  # Sanitize the title once for a single markdown table cell: strip newlines/tabs
  # (the TSV delimiter) and pipes (the markdown column delimiter).
  safe_title=$(printf '%s' "$title" | tr '\n\t|' '   ')

  reason=$(pr_stall_reasons "$ci_status" "$review_decision" "$reviewed_at_head" "$mins_idle" "$gated")
  if [ -n "$reason" ]; then
    candidates_rows+=$(printf '%s\t%s\t%s\t%s' "$pr" "$html_url" "$safe_title" "$reason")$'\n'
    echo "::warning::Stalled PR #${pr} — ${reason}"
  fi

  # Stranded-approval backstop (#1665 AC8). A standing approval is a non-dismissed
  # state==APPROVED review carrying the approval marker at head — NOT a bare
  # `decision=approved` marker in a dismissed review or an issue comment. When the
  # PR is green with auto-merge armed but no approval STANDS, and it has been idle
  # (no sweep re-dispatch) past the hours threshold, surface it.
  standing_approval=$(pr_standing_approval_count "$snapshot" "$head_sha")
  auto_merge_armed=false
  if jq -e '.autoMergeRequest != null' <<< "$snapshot" >/dev/null 2>&1; then
    auto_merge_armed=true
  fi
  # Round UP to whole hours: floor division would truncate a PR idle 4h30m to 4,
  # which (with the strict > threshold) delays reporting until 5h. Ceiling keeps
  # "idle past N hours" honest — any idle strictly beyond the whole-hour boundary
  # fires on time.
  hours_idle=$(( (mins_idle + 59) / 60 ))
  stranded_reason=$(pr_stranded_approval_reasons "$ci_status" "$auto_merge_armed" "$standing_approval" "$hours_idle" "$gated")
  if [ -n "$stranded_reason" ]; then
    stranded_rows+=$(printf '%s\t%s\t%s\t%s' "$pr" "$html_url" "$safe_title" "$stranded_reason")$'\n'
    echo "::warning::Stranded-approval PR #${pr} — ${stranded_reason}"
  fi
done <<< "$open_prs"

# grep -c prints the count even at zero matches (exiting 1), so `|| true` swallows
# that exit without appending a second "0". `grep .` on empty input counts 0 rows.
stall_count=$(grep -c . <<< "$candidates_rows" 2>/dev/null || true)
stall_count=${stall_count:-0}
stranded_count=$(grep -c . <<< "$stranded_rows" 2>/dev/null || true)
stranded_count=${stranded_count:-0}
echo "Scanned ${scanned} open PR(s); ${stall_count} stall candidate(s), ${stranded_count} stranded-approval candidate(s)."

# ---------------------------------------------------------------------------
# 3. Render report + export env flags
# ---------------------------------------------------------------------------
{
  printf '# Stalled PR Detection — %s\n\n' "$TODAY"
  printf '**Repo:** `%s` | **Open PRs scanned:** %s | **Stall candidates:** %s | **Stranded-approval candidates:** %s\n\n' \
    "$REPO" "$scanned" "$stall_count" "$stranded_count"
  if [ "$scan_incomplete" = "true" ]; then
    printf '> ⚠️ **Scan incomplete**: one or more PRs were skipped due to API errors or rate limits. The candidate count above may understate actual stalls.\n\n'
  fi
  generate_stall_report "$candidates_rows"
  printf '\n'
  generate_stranded_approval_report "$stranded_rows"
} > "$REPORT_FILE"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"
fi

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "STALL_COUNT=${stall_count}" >> "$GITHUB_ENV"
  echo "STRANDED_APPROVAL_COUNT=${stranded_count}" >> "$GITHUB_ENV"
  # Fold both nets into the single HAS_STALL flag the daily health-check workflow
  # already gates the report post on — no new workflow wiring (#1665 AC8).
  if [ "$stall_count" -gt 0 ] || [ "$stranded_count" -gt 0 ]; then
    echo "HAS_STALL=true" >> "$GITHUB_ENV"
  elif [ "$scan_incomplete" = "true" ]; then
    echo "::warning::Stall scan incomplete (PRs skipped due to API errors) — not emitting HAS_STALL=false to avoid a false all-clear"
  else
    echo "HAS_STALL=false" >> "$GITHUB_ENV"
  fi
fi

echo ""
echo "Report written to ${REPORT_FILE} ($(wc -c < "$REPORT_FILE") bytes)"
echo "=== Stall-PR scan complete ==="
