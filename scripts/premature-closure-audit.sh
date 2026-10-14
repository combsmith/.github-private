#!/usr/bin/env bash
# premature-closure-audit.sh — premature-closure backstop audit (issue #1077).
#
# #1077: the dev-lead agent closed tracking issues as `completed` without the fix
# actually landing on `main` — the issue closed on task-attempt, but the problem
# it described was still present and no merged PR resolved it. This audit is the
# machine-checkable post-condition (recommended action #3): it scans recently
# closed issues and flags any closed as `completed` shortly after opening with
# NO merged closing PR.
#
# Staged like stale-manager: DRY_RUN (default) writes a report only. In live mode
# (DRY_RUN=false) it RE-OPENS each flagged issue, applies the `dev-lead:needs-human`
# label, and posts one idempotent comment — turning a silently-"done" issue back
# into a visibly-open, human-routed one (recommended action #2). Fail-SAFE: if
# whether a merged closing PR exists cannot be determined, the issue is NOT
# flagged, so the audit never re-opens on an undeterminable lookup.
#
# The detection thresholds live in scripts/lib/premature-closure-detect.sh.
#
# Env vars consumed:
#   GH_TOKEN            — repo read (issues + timeline); issues:write in live mode
#   GH_PAT_FALLBACK     — optional secondary token if the primary can't read REPO
#   REPO / AGENT_REPO   — target repo (default: combsmith/.github-private)
#   DRY_RUN             — "true" (default) reports only; "false" applies actions
#   PC_LOOKBACK_DAYS    — how far back to scan closed issues (default: 7)
#   PC_MAX_OPEN_MINUTES — the "closed within N minutes of open" window (default: 30)
#   NEEDS_HUMAN_LABEL   — escalation label (default: dev-lead:needs-human)
#   GITHUB_ENV / GITHUB_STEP_SUMMARY — written by the Actions runner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/premature-closure-detect.sh
source "${SCRIPT_DIR}/lib/premature-closure-detect.sh"

REPO="${REPO:-${AGENT_REPO:-combsmith/.github-private}}"
DRY_RUN="${DRY_RUN:-true}"
PC_LOOKBACK_DAYS=$(_pc_threshold "${PC_LOOKBACK_DAYS:-}" 7)
NEEDS_HUMAN_LABEL="${NEEDS_HUMAN_LABEL:-dev-lead:needs-human}"
REPORT_FILE="${REPORT_FILE:-premature_closure_report.md}"
COMMENT_MARKER="<!-- premature-closure-audit -->"
TODAY=$(date -u +%Y-%m-%d)

echo "=== Premature-Closure Audit — #1077 backstop ==="
echo "  Repo:      $REPO"
echo "  Date:      $TODAY"
echo "  Dry run:   $DRY_RUN"
echo "  Window:    closed <${PC_MAX_OPEN_MINUTES:-30}m after open, lookback ${PC_LOOKBACK_DAYS}d"
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

# has_merged_closing_pr <issue_number> — echo "true" when the issue was closed by
# a merged PR (a `closed` timeline event carrying a merge commit, OR any linked
# PR that is merged), "false" when we can confirm none, and "unknown" when the
# timeline could not be read. Callers treat "unknown" as fail-safe (do not flag).
has_merged_closing_pr() {
  local number="$1" timeline
  timeline=$(gh api --paginate "repos/${REPO}/issues/${number}/timeline" \
    -H "Accept: application/vnd.github+json" 2>/dev/null) || { echo "unknown"; return 0; }
  [ -n "$timeline" ] || { echo "unknown"; return 0; }

  # A `closed` event with a non-null commit_id means the close came from a commit
  # (a merged "Closes #N" PR). A `cross-referenced`/`connected` event whose source
  # PR reports merged=true means a linked fix PR actually landed.
  local merged
  merged=$(jq -s -r '
    [ .[] | .[]? |
      ( (.event == "closed") and (.commit_id != null) )
      or
      ( (.source?.issue?.pull_request?.merged_at // null) != null )
    ] | any' <<< "$timeline" 2>/dev/null) || { echo "unknown"; return 0; }

  case "$merged" in
    true)  echo "true" ;;
    false) echo "false" ;;
    *)     echo "unknown" ;;
  esac
}

# ensure_needs_human_label — idempotently ensure the escalation label exists.
ensure_needs_human_label() {
  gh label create "$NEEDS_HUMAN_LABEL" --repo "$REPO" \
    --color B60205 --description "dev-lead could not complete this issue; needs human attention" \
    2>/dev/null || true
}

# already_flagged <issue_number> — 0 when this audit has already commented on the
# issue (idempotency: never re-open/spam an issue we have already flagged).
already_flagged() {
  local body
  body=$(gh api --paginate "repos/${REPO}/issues/${1}/comments" \
    --jq '.[].body' 2>/dev/null) || return 1
  grep -qF "$COMMENT_MARKER" <<< "$body"
}

# apply_action <issue_number> <reason> — re-open + label + comment (live only).
apply_action() {
  local number="$1" reason="$2"
  if already_flagged "$number"; then
    echo "::notice::Issue #${number} already flagged by a prior audit run — skipping"
    return 0
  fi
  ensure_needs_human_label
  gh issue reopen "$number" --repo "$REPO" 2>/dev/null || true
  gh issue edit "$number" --repo "$REPO" --add-label "$NEEDS_HUMAN_LABEL" 2>/dev/null || true
  gh issue comment "$number" --repo "$REPO" --body "${COMMENT_MARKER}
## Dev-Lead: re-opened — closed as completed without a landed fix (#1077)

This issue was closed as \`completed\`, but **no merged PR** landed the fix and it
closed within the fast task-attempt window (${reason}). Per #1077, an attempted-
but-unresolved issue must stay **open** and labeled \`${NEEDS_HUMAN_LABEL}\`, not
be marked done.

Re-opened automatically. Please verify the underlying problem and land a merged,
verifying change (or re-triage) before closing again." 2>/dev/null || true
  echo "::warning::Re-opened prematurely-closed issue #${number} — ${reason}"
}

# ---------------------------------------------------------------------------
# 1. Enumerate recently closed issues (state_reason=completed, not PRs)
# ---------------------------------------------------------------------------
cutoff_epoch=$(( $(date -u +%s) - PC_LOOKBACK_DAYS * 86400 ))
since_iso=$(date -u -d "@${cutoff_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r "${cutoff_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

closed_issues=$(gh api --paginate \
  "repos/${REPO}/issues?state=closed&since=${since_iso}&per_page=100" \
  --jq '.[] | select(.pull_request == null)
        | select(.state_reason == "completed")
        | [.number, .created_at, (.closed_at // ""), .html_url, (.title // "" | tostring)]
        | @tsv' 2>/dev/null) || {
  echo "::error::Failed to fetch closed issues from GitHub API." >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 2. Per-issue detection (+ staged action)
# ---------------------------------------------------------------------------
candidates_file=$(mktemp) || { echo "Failed to create temp file" >&2; exit 1; }
trap 'rm -f "$candidates_file"' EXIT
scanned=0

while IFS=$'\t' read -r number created_at closed_at html_url title; do
  [ -n "$number" ] || continue
  # Only audit issues actually closed within the lookback window.
  [ -n "$closed_at" ] || continue
  closed_epoch=$(date -u -d "$closed_at" +%s 2>/dev/null \
    || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$closed_at" +%s 2>/dev/null \
    || echo 0)
  [ "$closed_epoch" -ge "$cutoff_epoch" ] || continue
  scanned=$(( scanned + 1 ))

  minutes_open=$(minutes_between "$created_at" "$closed_at")

  # Fail-safe: an undeterminable PR state counts as "has merged PR" so we never
  # re-open on a lookup we could not resolve.
  merged_state=$(has_merged_closing_pr "$number")
  has_pr=true
  [ "$merged_state" = "false" ] && has_pr=false

  reason=$(premature_closure_reasons "completed" "$minutes_open" "$has_pr")
  if [ -n "$reason" ]; then
    safe_title="${title//[$'\n'$'\t'|]/ }"
    printf '%s\t%s\t%s\t%s\n' "$number" "$html_url" "$safe_title" "$reason" >> "$candidates_file"
    if [ "$DRY_RUN" != "true" ]; then
      apply_action "$number" "$reason"
    else
      echo "::notice::[dry-run] would re-open issue #${number} — ${reason}"
    fi
  fi
done <<< "$closed_issues"

flagged_count=$(grep -c . "$candidates_file" 2>/dev/null || true)
flagged_count=${flagged_count:-0}
echo "Scanned ${scanned} closed 'completed' issue(s); ${flagged_count} premature-closure candidate(s)."

# ---------------------------------------------------------------------------
# 3. Render report + export env flags
# ---------------------------------------------------------------------------
mode="live"
if [ "$DRY_RUN" = "true" ]; then
  mode="dry-run"
fi
{
  printf '# Premature-Closure Audit — %s\n\n' "$TODAY"
  printf '**Repo:** `%s` | **Closed-completed scanned:** %s | **Candidates:** %s | **Mode:** %s\n\n' \
    "$REPO" "$scanned" "$flagged_count" "$mode"
  generate_premature_closure_report "$candidates_file"
} > "$REPORT_FILE"

[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "PREMATURE_CLOSURE_COUNT=${flagged_count}" >> "$GITHUB_ENV"
  if [ "$flagged_count" -gt 0 ]; then
    echo "HAS_PREMATURE_CLOSURE=true" >> "$GITHUB_ENV"
  else
    echo "HAS_PREMATURE_CLOSURE=false" >> "$GITHUB_ENV"
  fi
fi

echo ""
echo "Report written to ${REPORT_FILE} ($(wc -c < "$REPORT_FILE") bytes)"
echo "=== Premature-closure audit complete ==="
