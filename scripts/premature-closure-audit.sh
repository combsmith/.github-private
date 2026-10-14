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
#   REPO / AGENT_REPO   — target repo (default: petry-projects/.github-private)
#   DRY_RUN             — "true" (default) reports only; "false" applies actions
#   PC_LOOKBACK_DAYS    — how far back to scan closed issues (default: 7)
#   PC_MAX_OPEN_MINUTES — the "closed within N minutes of open" window (default: 30)
#   NEEDS_HUMAN_LABEL   — escalation label (default: dev-lead:needs-human)
#   GITHUB_ENV / GITHUB_STEP_SUMMARY — written by the Actions runner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/premature-closure-detect.sh
source "${SCRIPT_DIR}/lib/premature-closure-detect.sh"

REPO="${REPO:-${AGENT_REPO:-petry-projects/.github-private}}"
DRY_RUN="${DRY_RUN:-true}"
PC_LOOKBACK_DAYS=$(_pc_threshold "${PC_LOOKBACK_DAYS:-}" 7)
NEEDS_HUMAN_LABEL="${NEEDS_HUMAN_LABEL:-dev-lead:needs-human}"
REPORT_FILE="${REPORT_FILE:-premature_closure_report.md}"
COMMENT_MARKER="<!-- premature-closure-audit -->"
# Distinct marker for the OPEN-issue unbacked-claim path (#1445) so its
# idempotency check never collides with the closed-issue re-open marker.
OPEN_COMMENT_MARKER="<!-- premature-closure-audit-open -->"
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

# has_linked_pr <issue_number> — echo "true" when the issue has a durable
# closing/fixed-by PR link or was closed by a commit, "false" when we can confirm
# none, "unknown" when the timeline could not be read. For the OPEN-issue unbacked-
# claim scan (#1445) we require a `connected` timeline event (the specific signal
# GitHub emits when a PR carries "Closes/Fixes #N" keywords and is linked to close
# the issue) rather than any `cross-referenced` event, which fires for any incidental
# mention. Generic cross-references are not a durable backing signal; a `connected`
# event is. Callers treat "unknown" as fail-safe.
has_linked_pr() {
  local number="$1" timeline linked
  timeline=$(gh api --paginate "repos/${REPO}/issues/${number}/timeline" \
    -H "Accept: application/vnd.github+json" 2>/dev/null) || { echo "unknown"; return 0; }
  [ -n "$timeline" ] || { echo "unknown"; return 0; }

  linked=$(jq -s -r '
    [ .[] | .[]? |
      ( (.event == "closed") and (.commit_id != null) )
      or
      ( .event == "connected" )
    ] | any' <<< "$timeline" 2>/dev/null) || { echo "unknown"; return 0; }

  case "$linked" in
    true)  echo "true" ;;
    false) echo "false" ;;
    *)     echo "unknown" ;;
  esac
}

# issue_has_unretracted_completion_claim <issue_number> — echo "claim" when the
# issue carries at least one NON-retracted completion-claim comment, "none" when
# comments are readable but none qualify, "unknown" when comments can't be read.
# Uses the pure body predicates from premature-closure-detect.sh; base64 per
# comment preserves multi-line bodies through the read loop.
issue_has_unretracted_completion_claim() {
  local number="$1" raw enc body
  raw=$(gh api --paginate "repos/${REPO}/issues/${number}/comments?per_page=100" \
    --jq '.[] | (.body // "") | @base64' 2>/dev/null) || { echo "unknown"; return 0; }
  local state="none"
  while IFS= read -r enc; do
    [ -n "$enc" ] || continue
    body=$(printf '%s' "$enc" | base64 -d 2>/dev/null) || continue
    # Process every comment in API order so a later retraction overrides an
    # earlier claim. A retracted body clears any prior claim state; a
    # non-retracted completion-claim body sets it. The last relevant comment wins.
    if claim_is_retracted "$body"; then state="none"; continue; fi
    if body_has_completion_claim "$body"; then state="claim"; fi
  done <<< "$raw"
  echo "$state"
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

# already_flagged_open <issue_number> — 0 when the OPEN-issue audit already
# commented on the issue (idempotency; distinct from the closed-issue marker).
already_flagged_open() {
  local body
  body=$(gh api --paginate "repos/${REPO}/issues/${1}/comments" \
    --jq '.[].body' 2>/dev/null) || return 1
  grep -qF "$OPEN_COMMENT_MARKER" <<< "$body"
}

# apply_open_action <issue_number> <reason> — label + comment (live only) for an
# OPEN issue carrying an unbacked completion claim. Unlike the closed path there
# is nothing to re-open; the action makes the false-"done" state visibly open for
# a human by applying the escalation label and posting one idempotent comment.
apply_open_action() {
  local number="$1" reason="$2"
  if already_flagged_open "$number"; then
    echo "::notice::Open issue #${number} already flagged by a prior audit run — skipping"
    return 0
  fi
  ensure_needs_human_label
  gh issue edit "$number" --repo "$REPO" --add-label "$NEEDS_HUMAN_LABEL" 2>/dev/null || true
  local body_file
  body_file=$(mktemp) || { echo "::warning::Failed to create temp comment body for issue #${number} — skipping comment"; return 0; }
  {
    printf '%s\n' "$OPEN_COMMENT_MARKER"
    printf '## Dev-Lead: open issue carries an unbacked completion claim (#1445)\n\n'
    printf 'This issue carries a **completion claim** but **no linked pull request** backs it\n'
    printf '(%s) — so it reads as delivered while nothing became durable on `main`.\n' "$reason"
    printf 'This is the #1445 shape: a "Completed" record published before the work was\n'
    printf 'durable, then lost (e.g. a timeout discarded the workspace).\n\n'
    printf 'Labeled `%s` and left **open**. Please verify whether the work\n' "$NEEDS_HUMAN_LABEL"
    printf 'exists; if not, re-run implementation (its terminal-failure path now retracts the\n'
    printf 'stale claim) or retract the claim before treating this issue as done.\n'
  } > "$body_file"
  gh issue comment "$number" --repo "$REPO" --body-file "$body_file" 2>/dev/null || true
  rm -f "$body_file"
  echo "::warning::Flagged open issue #${number} with an unbacked completion claim — ${reason}"
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
# 2b. OPEN-issue scan (#1445): flag OPEN issues carrying an UNBACKED completion
# claim — a "Completed" record with no linked PR. This is the standing case the
# closed-only audit above never fires on: the issue stays open (so no close event
# to inspect) yet reads as delivered while nothing landed.
# ---------------------------------------------------------------------------
open_candidates_file=$(mktemp) || { echo "Failed to create temp file" >&2; exit 1; }
trap 'rm -f "$candidates_file" "$open_candidates_file"' EXIT
open_scanned=0

# Open-issue unbacked claims may linger far longer than the closed-issue
# lookback window (default 7 days). Use a separate, longer lookback so stale
# claims that have sat open for weeks are not silently skipped.
# PC_OPEN_LOOKBACK_DAYS defaults to 90; env-overridable.
_pc_open_lookback=$(_pc_threshold "${PC_OPEN_LOOKBACK_DAYS:-}" 90)
_pc_open_cutoff=$(( $(date -u +%s) - _pc_open_lookback * 86400 ))
_pc_open_since=$(date -u -d "@${_pc_open_cutoff}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r "${_pc_open_cutoff}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

open_issues=$(gh api --paginate \
  "repos/${REPO}/issues?state=open&since=${_pc_open_since}&per_page=100" \
  --jq '.[] | select(.pull_request == null)
        | [.number, .html_url, (.title // "" | tostring)]
        | @tsv' 2>/dev/null) || {
  echo "::warning::Failed to fetch open issues — skipping unbacked-claim scan" >&2
  open_issues=""
}

while IFS=$'\t' read -r number html_url title; do
  [ -n "$number" ] || continue
  # Only issues that actually carry a (non-retracted) completion claim are in
  # scope. "unknown"/"none" are skipped — fail-safe, never flag on a bad read.
  claim_state=$(issue_has_unretracted_completion_claim "$number")
  [ "$claim_state" = "claim" ] || continue
  open_scanned=$(( open_scanned + 1 ))

  # Fail-safe: an undeterminable link state counts as "has backing PR" so an
  # unreadable timeline never flags a healthy issue.
  linked_state=$(has_linked_pr "$number")
  has_backing_pr=true
  [ "$linked_state" = "false" ] && has_backing_pr=false

  reason=$(unbacked_completion_claim_reasons "true" "$has_backing_pr")
  if [ -n "$reason" ]; then
    safe_title="${title//[$'\n'$'\t'|]/ }"
    printf '%s\t%s\t%s\t%s\n' "$number" "$html_url" "$safe_title" "$reason" >> "$open_candidates_file"
    if [ "$DRY_RUN" != "true" ]; then
      apply_open_action "$number" "$reason"
    else
      echo "::notice::[dry-run] would flag open issue #${number} — ${reason}"
    fi
  fi
done <<< "$open_issues"

open_flagged_count=$(grep -c . "$open_candidates_file" 2>/dev/null || true)
open_flagged_count=${open_flagged_count:-0}
echo "Scanned ${open_scanned} open claim-carrying issue(s); ${open_flagged_count} unbacked-claim candidate(s)."

# ---------------------------------------------------------------------------
# 3. Render report + export env flags
# ---------------------------------------------------------------------------
mode="live"
if [ "$DRY_RUN" = "true" ]; then
  mode="dry-run"
fi
{
  printf '# Premature-Closure Audit — %s\n\n' "$TODAY"
  printf '**Repo:** `%s` | **Closed-completed scanned:** %s | **Candidates:** %s | **Open claim-carrying scanned:** %s | **Unbacked-claim candidates:** %s | **Mode:** %s\n\n' \
    "$REPO" "$scanned" "$flagged_count" "$open_scanned" "$open_flagged_count" "$mode"
  generate_premature_closure_report "$candidates_file"
  printf '\n'
  generate_unbacked_claim_report "$open_candidates_file"
} > "$REPORT_FILE"

[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "PREMATURE_CLOSURE_COUNT=${flagged_count}" >> "$GITHUB_ENV"
  if [ "$flagged_count" -gt 0 ]; then
    echo "HAS_PREMATURE_CLOSURE=true" >> "$GITHUB_ENV"
  else
    echo "HAS_PREMATURE_CLOSURE=false" >> "$GITHUB_ENV"
  fi
  echo "UNBACKED_CLAIM_COUNT=${open_flagged_count}" >> "$GITHUB_ENV"
  if [ "$open_flagged_count" -gt 0 ]; then
    echo "HAS_UNBACKED_CLAIM=true" >> "$GITHUB_ENV"
  else
    echo "HAS_UNBACKED_CLAIM=false" >> "$GITHUB_ENV"
  fi
fi

echo ""
echo "Report written to ${REPORT_FILE} ($(wc -c < "$REPORT_FILE") bytes)"
echo "=== Premature-closure audit complete ==="
