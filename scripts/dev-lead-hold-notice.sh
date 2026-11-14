#!/usr/bin/env bash
set -euo pipefail
# dev-lead-hold-notice.sh — the I/O wrapper for the #1767 "held item" notice.
#
# dev-lead skips a work item carrying a hold label (needs-human-review /
# dev-lead:needs-human / dev-lead:hands-off) but says nothing on the item, so the
# skip is invisible outside the run log and the agent looks stalled (PR #1742 sat
# four days looking dead while it was correctly withholding action). This wrapper
# makes the withhold visible with exactly ONE comment, and re-arms cleanly.
#
# All decision logic is PURE and unit-tested in scripts/lib/hold-notice.sh
# (ADR-0004); this file does only I/O — list comments, post, edit — and never
# aborts the calling job on an API failure (best-effort, ::warning:: on trouble).
#
# Modes:
#   MODE=notice     (default) a hold-label skip: post the one-time notice for
#                   HOLD_LABEL if absent (idempotent), first collapsing any stale
#                   notice for a DIFFERENT label (the hold changed).
#   MODE=supersede  a pickup (dev-lead is acting): the item is no longer held, so
#                   collapse any live hold notice on it (re-arm, AC4).
#
# Env:
#   REPO            owner/repo (defaults to GITHUB_REPOSITORY)
#   SUBJECT_NUMBER  issue or PR number (issues + PRs share the issues comments API)
#   HOLD_LABEL      the blocking label (required for MODE=notice)
#   MODE            notice | supersede (default: notice)
#   NOTICE_AUTHOR   dev-lead's own account login (BOT_USER). Only comments
#                   authored by this account are treated as hold notices, so a
#                   user-authored comment that copies a notice marker can neither
#                   suppress a real notice nor be collapsed as if it were one. If
#                   empty, no comment is trusted as a notice (fail-closed: we may
#                   re-post but never act on a forged marker).
#   DEV_LEAD_DRY_RUN / DRY_RUN   "true" → log intent, make no write calls

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/hold-notice.sh
source "$SCRIPT_DIR/lib/hold-notice.sh"
# shellcheck source=lib/shadow-suppress.sh
source "$SCRIPT_DIR/lib/shadow-suppress.sh"

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
SUBJECT_NUMBER="${SUBJECT_NUMBER:-}"
HOLD_LABEL="${HOLD_LABEL:-}"
MODE="${MODE:-notice}"
NOTICE_AUTHOR="${NOTICE_AUTHOR:-${BOT_USER:-}}"
DRY_RUN="${DEV_LEAD_DRY_RUN:-${DRY_RUN:-false}}"
# Shadow mode (#1713) posts nothing: treat it as dry-run so no write call fires.
if shadow_mode_active; then DRY_RUN="true"; fi

if [ -z "$REPO" ]; then
  echo "::warning::dev-lead-hold-notice: REPO/GITHUB_REPOSITORY not set — skipping"
  exit 0
fi
if [ -z "$SUBJECT_NUMBER" ]; then
  echo "::warning::dev-lead-hold-notice: SUBJECT_NUMBER not set — skipping"
  exit 0
fi

COMMENTS_FILE="$(mktemp)"
trap 'rm -f "$COMMENTS_FILE"' EXIT

# List the item's comments once. Failure here is non-fatal — the notice is a
# visibility aid, never a gate; degrade with a warning rather than failing the job.
if ! gh api --paginate "repos/$REPO/issues/$SUBJECT_NUMBER/comments" > "$COMMENTS_FILE" 2>/dev/null; then
  echo "::warning::dev-lead-hold-notice: failed to list comments for $REPO#$SUBJECT_NUMBER — skipping (best-effort)"
  exit 0
fi

# collapse_stale_notices <keep-label>
#   Rewrite every comment carrying a LIVE hold-notice marker into its collapsed
#   form, EXCEPT the notice for <keep-label> (pass an empty string to collapse
#   all). Best-effort per comment. Bodies are re-fetched individually so raw
#   control chars in a comment never break the shell pipeline (same guard as
#   post-pr-review.sh mark_prior_agent_items_obsolete). Only comments authored by
#   NOTICE_AUTHOR (dev-lead itself) are considered, so a user comment that copies
#   a notice marker is never rewritten as though it were our own notice.
collapse_stale_notices() {
  local keep_label="$1"
  local ids cid old_body cur_label new_body
  ids=$(jq -r --arg author "$NOTICE_AUTHOR" '
    .[]
    | select(.body != null
        and ($author != "" and (.user.login // "") == $author)
        and (.body | contains("<!-- dev-lead-hold-notice label="))
        and (.body | contains("<!-- dev-lead-hold-notice superseded") | not))
    | .id
  ' "$COMMENTS_FILE" 2>/dev/null || true)

  while IFS= read -r cid; do
    [ -z "$cid" ] && continue
    old_body=$(gh api "repos/$REPO/issues/comments/$cid" --jq '.body' 2>/dev/null) || {
      echo "::warning::dev-lead-hold-notice: failed to fetch comment $cid on $REPO#$SUBJECT_NUMBER — skipping collapse"
      continue
    }
    cur_label=$(hold_notice_label_from_body "$old_body") || continue
    if [ -n "$keep_label" ] && [ "$cur_label" = "$keep_label" ]; then
      continue
    fi
    new_body=$(hold_notice_supersede_body "$old_body" "$keep_label")
    if [ "$DRY_RUN" = "true" ]; then
      echo "[dry-run] would collapse stale hold notice $cid (label=$cur_label) on $REPO#$SUBJECT_NUMBER"
      continue
    fi
    if jq -n --arg b "$new_body" '{body:$b}' \
        | gh api -X PATCH "repos/$REPO/issues/comments/$cid" --input - >/dev/null 2>&1; then
      echo "collapsed stale hold notice $cid (label=$cur_label) on $REPO#$SUBJECT_NUMBER"
    else
      echo "::warning::dev-lead-hold-notice: failed to collapse comment $cid on $REPO#$SUBJECT_NUMBER"
    fi
  done <<< "$ids"
  return 0
}

case "$MODE" in
  supersede)
    collapse_stale_notices ""
    ;;

  notice)
    if [ -z "$HOLD_LABEL" ]; then
      echo "::warning::dev-lead-hold-notice: HOLD_LABEL not set in notice mode — skipping"
      exit 0
    fi
    # Only our own comments can suppress a re-post — a user comment that copies
    # the marker must not silence a real notice (fail-closed: empty author → no
    # existing notice is trusted, so we post rather than stay silent).
    existing=$(jq -r --arg author "$NOTICE_AUTHOR" \
      '.[] | select($author != "" and (.user.login // "") == $author) | .body // empty' \
      "$COMMENTS_FILE" 2>/dev/null || true)
    if ! hold_notice_should_post "$HOLD_LABEL" "$existing"; then
      echo "hold notice for '$HOLD_LABEL' already present on $REPO#$SUBJECT_NUMBER — no-op (idempotent)"
      exit 0
    fi
    # The hold changed (a different label was noticed before): collapse the stale
    # one so the item does not read as held under two labels at once.
    collapse_stale_notices "$HOLD_LABEL"

    body=$(hold_notice_body "$HOLD_LABEL")
    if [ "$DRY_RUN" = "true" ]; then
      echo "[dry-run] would post hold notice on $REPO#$SUBJECT_NUMBER for label '$HOLD_LABEL':"
      printf '%s\n' "$body"
      exit 0
    fi
    if printf '%s' "$body" | gh issue comment "$SUBJECT_NUMBER" --repo "$REPO" --body-file - >/dev/null 2>&1; then
      echo "posted hold notice on $REPO#$SUBJECT_NUMBER for label '$HOLD_LABEL'"
    else
      echo "::warning::dev-lead-hold-notice: failed to post hold notice on $REPO#$SUBJECT_NUMBER"
    fi
    ;;

  *)
    echo "::warning::dev-lead-hold-notice: unknown MODE '$MODE' — skipping"
    exit 0
    ;;
esac

exit 0
