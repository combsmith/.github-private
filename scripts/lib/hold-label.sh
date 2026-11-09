#!/usr/bin/env bash
# hold-label.sh — apply the human-hold label when dev-lead escalates a PR (#2142).
#
# An escalation is only a hold if the label lands: hold-gate.sh (#1595) reads the
# label, not the flag comment. Escalations used to run `gh pr edit --add-label
# needs-human-review 2>/dev/null`, which fails under the workflow token (gh pr
# edit needs scopes the token lacks), and the error was discarded. PRs were
# flagged in a comment but not held, so the next event started another pass.
#
# This library is the one path every escalation uses:
#   • the label goes through the REST endpoint
#     POST /repos/{owner}/{repo}/issues/{number}/labels;
#   • a failure logs the API's message as ::error::;
#   • a failure is loud: HOLD_LABEL_NOTE carries a "could not be held" paragraph
#     for the flag comment, and hold_label_exit_guard (on the EXIT trap) ends the
#     run as a failure.
#
# This file is meant to be SOURCED, not executed.
#
# Env:
#   NEEDS_HUMAN_REVIEW_LABEL  default hold label (needs-human-review).
#   DEV_LEAD_DRY_RUN          callers handle dry-run; this library always writes.
#
# State (globals):
#   HOLD_LABEL_FAILED  1 once any hold in this run failed (sticky).
#   HOLD_LABEL_NOTE    the not-held paragraph for the LAST apply_hold_label call
#                      ("" when it succeeded). Starts with a blank line, so it
#                      can be appended to a comment body as is.

HOLD_LABEL_FAILED="${HOLD_LABEL_FAILED:-0}"
HOLD_LABEL_NOTE=""
ADD_LABEL_ERR=""

# _hold_label_api_message <raw gh output> — reduce gh's combined output to the
# API's message on one line: prefer gh's own `gh: … (HTTP nnn)` line, then the
# JSON body's .message, then the raw text. Backticks are dropped so the message
# can sit inside inline code in a comment.
_hold_label_api_message() {
  local raw="$1" msg
  msg=$(printf '%s\n' "$raw" | sed -n 's/^gh: //p' | head -1)
  [[ -n "$msg" ]] || msg=$(printf '%s' "$raw" | jq -r '.message // empty' 2>/dev/null | head -1)
  [[ -n "$msg" ]] || msg="$raw"
  [[ -n "$msg" ]] || msg="(no error output)"
  printf '%s' "$msg" | tr '\n`' '  ' | cut -c1-300
}

# add_label_rest <repo> <number> <label>
#   Add any label to an issue or PR through the REST issues-labels endpoint
#   (`gh issue edit` / `gh pr edit --add-label` fail under the workflow token).
#   Returns 0 when applied. Otherwise logs ::error:: with the API's message,
#   leaves it in ADD_LABEL_ERR, and returns 1. Touches no hold state.
add_label_rest() {
  local repo="$1" number="$2" label="$3" out
  ADD_LABEL_ERR=""
  if out=$(gh api -X POST "repos/${repo}/issues/${number}/labels" -f "labels[]=${label}" 2>&1); then
    return 0
  fi
  ADD_LABEL_ERR="$(_hold_label_api_message "$out")"
  echo "::error::could not add ${label} label on #${number}: ${ADD_LABEL_ERR}"
  return 1
}

# _hold_label_mark_failed — record a failed hold. Also touches
# HOLD_LABEL_FAILED_FILE when set, so a failure inside a command substitution
# (a subshell whose variables are lost) still reaches the parent's exit guard.
_hold_label_mark_failed() {
  HOLD_LABEL_FAILED=1
  [[ -z "${HOLD_LABEL_FAILED_FILE:-}" ]] || : > "$HOLD_LABEL_FAILED_FILE" 2>/dev/null || true
}

# apply_hold_label <repo> <number> [label]
#   Add the hold label through add_label_rest. Returns 0 when the label is
#   applied. Otherwise sets HOLD_LABEL_FAILED=1 and HOLD_LABEL_NOTE, and
#   returns 1.
apply_hold_label() {
  local repo="$1" number="$2" label="${3:-${NEEDS_HUMAN_REVIEW_LABEL:-needs-human-review}}"
  local msg
  HOLD_LABEL_NOTE=""
  if add_label_rest "$repo" "$number" "$label"; then
    echo "::notice::applied ${label} to PR #${number} — dev-lead will hold it for a human"
    return 0
  fi
  msg="$ADD_LABEL_ERR"
  echo "::error::PR #${number} is flagged but NOT held (#2142)"
  _hold_label_mark_failed
  HOLD_LABEL_NOTE="

> [!WARNING]
> **This PR could not be held.** dev-lead could not apply the \`${label}\` label (\`${msg}\`), so the hold gate will not stop further automated passes. A human should add \`${label}\` by hand."
  return 1
}

# post_hold_failure_note <repo> <number>
#   For an escalation whose flag comment already exists (deduped): post the
#   not-held note on its own when the last apply_hold_label failed. No-op when
#   the hold succeeded. Returns non-zero if posting fails.
post_hold_failure_note() {
  local repo="$1" number="$2"
  [[ -n "$HOLD_LABEL_NOTE" ]] || return 0
  # Marker-keyed: repeated deduped escalations post the note once.
  local marker="<!-- dev-lead:hold-failed -->"
  if gh api --paginate "repos/${repo}/issues/${number}/comments?per_page=100" 2>/dev/null \
       | jq -r '.[].body // ""' 2>/dev/null | grep -qF "$marker"; then
    return 0
  fi
  if gh pr comment "$number" --repo "$repo" --body "${marker}
## Dev-Lead — hold failed${HOLD_LABEL_NOTE}"; then
    return 0
  fi
  echo "::error::could not post the not-held note on PR #${number}"
  _hold_label_mark_failed
  return 1
}

# disable_auto_merge_for_hold <repo> <number>
#   Disable auto-merge on an escalated PR. gh fails both when auto-merge was not
#   on and when the call is refused, so on failure check whether auto-merge is
#   still active: if so the PR is NOT held (HOLD_LABEL_FAILED=1, returns 1);
#   if not, it was simply off. Callers treat a non-zero return as non-fatal.
disable_auto_merge_for_hold() {
  local repo="$1" number="$2" out active
  if out=$(gh pr merge "$number" --repo "$repo" --disable-auto 2>&1); then
    return 0
  fi
  active=$(gh pr view "$number" --repo "$repo" --json autoMergeRequest \
    --jq '.autoMergeRequest != null' 2>/dev/null || echo unknown)
  if [[ "$active" = "true" ]]; then
    echo "::error::could not disable auto-merge on PR #${number}: $(_hold_label_api_message "$out") — it may merge despite escalation (#2142)"
    _hold_label_mark_failed
    return 1
  fi
  if [[ "$active" = "unknown" ]]; then
    echo "::error::could not verify auto-merge status on PR #${number}: $(_hold_label_api_message "$out") — unable to confirm hold (#2142)"
    _hold_label_mark_failed
    return 1
  fi
  echo "::notice::auto-merge not disabled on PR #${number} (not enabled, or refused): $(_hold_label_api_message "$out")"
  return 0
}

# hold_label_exit_guard — EXIT-trap hook. When any hold in this run failed, end
# the run as a failure: keep the exit code if it is already non-zero, otherwise
# exit 1. In a chained trap capture the status first and pass it in:
#   trap 'rc=$?; restore_auto_merge; hold_label_exit_guard "$rc"' EXIT
hold_label_exit_guard() {
  local rc=${1:-$?}
  if [[ "${HOLD_LABEL_FAILED:-0}" != "1" ]] && [[ -n "${HOLD_LABEL_FAILED_FILE:-}" ]] && [[ -e "$HOLD_LABEL_FAILED_FILE" ]]; then
    HOLD_LABEL_FAILED=1
  fi
  [[ "${HOLD_LABEL_FAILED:-0}" = "1" ]] || return 0
  echo "::error::a dev-lead escalation could not be held (needs-human-review not applied) — failing the run (#2142)"
  [ "$rc" -ne 0 ] || rc=1
  exit "$rc"
}
