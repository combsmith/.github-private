#!/usr/bin/env bash
# hold-notice.sh — PURE logic for the dev-lead "held item" notice (#1767).
#
# When dev-lead skips a work item because of a hold label (see
# scripts/lib/hold-gate.sh + dev-lead-intent.sh emit_hold_skip), the skip is only
# visible in a workflow-run log nobody reads — so the agent looks stalled
# (indistinguishable from the #1741 cancellation and #1592 silent-no-op defects).
# PR #1742 sat four days with 15 unresolved threads and no visible dev-lead
# activity while it was in fact behaving correctly: deliberately withholding
# action on a `needs-human-review` hold. This library builds the one-time comment
# that makes the withhold visible, and decides idempotently whether to post it.
#
# These functions are PURE (no network, no LLM, no global state) so they are
# unit-tested offline per ADR-0004; scripts/dev-lead-hold-notice.sh is the thin
# I/O wrapper that lists comments, calls these, and posts/edits via `gh`.
#
# Idempotency + re-arm model (AC2/AC4/AC6):
#   * A live notice carries the ACTIVE marker `<!-- dev-lead-hold-notice
#     label=<label> -->`. hold_notice_should_post refuses to re-post while that
#     exact marker is present → exactly one comment per hold, not one per skip.
#   * Collapsing (on re-arm/pickup) rewrites the comment: it drops the ACTIVE
#     marker and stamps the SUPERSEDED marker `<!-- dev-lead-hold-notice
#     superseded label=<label> -->`. Because the superseded marker does NOT
#     contain the active marker as a substring, a collapsed notice no longer
#     suppresses a fresh notice — so if the item is held again later, a new
#     notice is posted. The collapse itself is idempotent.
#
# This file is meant to be SOURCED, not executed.

# hold_notice_active_marker <label>
#   The idempotency marker stamped into a live hold notice. Substring-unique.
hold_notice_active_marker() {
  printf '<!-- dev-lead-hold-notice label=%s -->' "${1:-}"
}

# hold_notice_superseded_marker <label>
#   The marker a collapsed (re-armed) notice carries instead of the active one.
hold_notice_superseded_marker() {
  printf '<!-- dev-lead-hold-notice superseded label=%s -->' "${1:-}"
}

# _hold_notice_label_clause <label>
#   A short, label-specific sentence so `dev-lead:hands-off` and
#   `needs-human-review` are never collapsed into identical generic wording
#   (AC3) — they mean different things to a maintainer.
_hold_notice_label_clause() {
  case "${1:-}" in
    needs-human-review)
      printf 'flagged for human review — this label is applied by automation as well as by people, so an item can become held without anyone noticing' ;;
    dev-lead:needs-human)
      printf 'escalated for a human to take over' ;;
    dev-lead:hands-off)
      printf 'deliberately kept off-limits to dev-lead (e.g. changes to the dev-lead automation itself)' ;;
    *)
      printf 'a hold label that excludes it from automated pickup' ;;
  esac
}

# hold_notice_body <label>
#   The full comment body. The first line is the active idempotency marker; the
#   prose names the SPECIFIC blocking label (AC1/AC3) and how to re-enable pickup.
hold_notice_body() {
  local label="${1:-}"
  printf '%s\n' "$(hold_notice_active_marker "$label")"
  printf '\n'
  printf '**dev-lead is withholding action on this item.**\n\n'
  printf 'It is labeled `%s` (%s), so dev-lead will not pick it up while that label is present. This notice is posted once so the withhold is visible rather than looking like a stalled run.\n\n' \
    "$label" "$(_hold_notice_label_clause "$label")"
  printf '**To re-enable automated pickup:** remove the `%s` label.\n' "$label"
}

# hold_notice_should_post <label> <existing-comment-text>
#   Exit 0 (post) when no LIVE notice for <label> is present in the concatenated
#   existing comment text; exit 1 (silent no-op) when one already is. A collapsed
#   notice does not match the active marker, so it never suppresses a re-hold.
hold_notice_should_post() {
  local label="${1:-}" existing="${2:-}" active
  active="$(hold_notice_active_marker "$label")"
  case "$existing" in
    *"$active"*) return 1 ;;
    *) return 0 ;;
  esac
}

# hold_notice_label_from_body <comment-body>
#   Print the label carried by a notice's active marker; return 1 if the body
#   carries no active hold-notice marker.
hold_notice_label_from_body() {
  local body="${1:-}" rest
  rest="${body#*<!-- dev-lead-hold-notice label=}"
  [[ "$rest" = "$body" ]] && return 1
  printf '%s' "${rest%% -->*}"
}

# body_has_active_hold_notice <comment-body>
#   Exit 0 when the body carries a LIVE hold-notice marker (and is not already
#   collapsed) — i.e. it is a notice a pickup should collapse.
body_has_active_hold_notice() {
  local body="${1:-}"
  case "$body" in
    *"<!-- dev-lead-hold-notice superseded"*) return 1 ;;
  esac
  case "$body" in
    *"<!-- dev-lead-hold-notice label="*) return 0 ;;
    *) return 1 ;;
  esac
}

# hold_notice_supersede_body <comment-body> [replacing-label]
#   Rewrite a live notice IN PLACE to collapse it (AC4): drop the active marker,
#   stamp the superseded marker, and wrap the remaining prose in a collapsed
#   <details> block — reusing the supersede convention in post-pr-review.sh
#   (mark_prior_agent_items_obsolete). Idempotent: an already-collapsed body is
#   returned unchanged, so re-running never nests wrappers.
#
#   With no [replacing-label] the hold was lifted (dev-lead picked the item up).
#   With one, a notice for a DIFFERENT hold label is replacing this one — the old
#   label may well still be on the item, so the summary must not claim it was
#   lifted (#2089: a `dev-lead:hands-off` notice read "lifted" on a PR that still
#   carried the label, because `needs-human-review` sorts first in the hold set).
hold_notice_supersede_body() {
  local body="${1:-}" replacing="${2:-}"
  case "$body" in
    *"<!-- dev-lead-hold-notice superseded"*) printf '%s' "$body"; return 0 ;;
  esac
  local label active stripped
  label="$(hold_notice_label_from_body "$body")" || label=""
  active="$(hold_notice_active_marker "$label")"
  # Literal (non-regex) removal of the active marker so the collapsed comment no
  # longer reads as still-held and no longer suppresses a future notice.
  stripped="${body//"$active"/}"
  printf '%s\n' "$(hold_notice_superseded_marker "$label")"
  if [[ -n "$replacing" ]] && [[ "$replacing" != "$label" ]]; then
    printf '<details><summary><em>Superseded — dev-lead is now withholding action under the `%s` label. Click to expand the prior `%s` hold notice.</em></summary>\n\n' "$replacing" "$label"
  else
    printf '<details><summary><em>Resolved — the `%s` hold was lifted; dev-lead has picked this item up. Click to expand the prior hold notice.</em></summary>\n\n' "$label"
  fi
  printf '%s\n\n' "$stripped"
  printf '</details>'
}
