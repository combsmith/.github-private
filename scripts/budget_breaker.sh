#!/usr/bin/env bash
# budget_breaker.sh — the reactive budget breaker's WRITER (#2153, slice 3b of
# #1565). One run:
#
#   1. read the fleet pause state (AGENTS_PAUSED, AGENTS_PAUSE_SOURCE,
#      AGENTS_PAUSE_UNTIL);
#   2. collect the fleet's quota markers (bb_collect) unless the fleet is paused,
#      in which case the decision does not consult them. A run woken by
#      `workflow_run` may exit here instead, before the scan, when an earlier
#      run already scanned moments ago (see "THE EARLY EXIT" below);
#   3. decide (bb_decide, scripts/lib/budget-breaker.sh: the decision is slice 3a
#      and is not re-implemented here);
#   4. apply:  trip    AGENTS_PAUSE_SOURCE, AGENTS_PAUSE_UNTIL, AGENTS_PAUSED=true
#              resume  AGENTS_PAUSED=false, then delete source and until
#              hold / none   nothing
#      and post one notice on the tracking issue for a trip and one for a resume.
#      A run that HOLDS a pause whose trip notice is not on the tracking issue
#      posts that notice, once (#2251): it writes no variable.
#
# DEFAULT OFF, TWICE. Nothing is written unless BUDGET_BREAKER_ARMED is exactly
# `true` AND the write credential is present. In every other case the run still
# reads, decides and logs the write it WOULD have made. Unset, empty and the
# exact string `false` are the ordinary ways to be disarmed. Any other value
# that is not exactly `true` (`TRUE`, ` true`, `1`, `yes`, `False`) is one
# `::error::` line and a disarmed run.
#
# FAIL OPEN. A collector that could not read, an unreadable state, a decision
# that does not fit the state, or a state that changed under the run all mean
# NO WRITE. Missing data never pauses the fleet and never keeps it paused.
#
# A HUMAN PAUSE IS NEVER TOUCHED. A pause with no source, or with a source that
# is not the breaker's own, is left exactly as it is: bb_decide returns `none`
# for it, and bbw_plan refuses to plan a write against it whatever the decision.
# A trip reads the state twice more: just before its first write (changed: no
# write at all), and again after the source and until are written, before the
# pause is set (paused by someone else, or changed: the pause is not set and the
# run deletes the source and until it wrote; scripts/lib/budget-breaker-writer.sh,
# "The pause guard"). That roll-back is the only write a run makes that is not
# a step of its plan, and it only removes what the same run wrote.
#
# LEFTOVER OWNERSHIP MARKERS ARE REMOVED. The breaker's own source on a fleet
# that is NOT paused (left by a trip that failed before the pause, or by a pause
# ended by hand) would make the next pause set by hand read as the breaker's
# own. An armed run that finds one deletes the source, then the until, warns,
# and does nothing else: that is its one state change, and the next run decides
# normally. This is the one further exception to "none writes nothing". It
# removes only the breaker's own value, never another source.
#
# Anti-flap: one decision and at most one state change per run; a step whose
# target already holds the wanted value is skipped; a resume waits until the
# pause switch has stood for BUDGET_BREAKER_MIN_HOLD_MIN. When the time the
# switch was set cannot be read from the API, the hold is measured from the
# pause's end time instead (the pause was set no later than that), so a bad
# timestamp delays a resume by at most the minimum hold and never blocks it.
#
# A failed write or a refused credential is ONE `::error::` naming the
# permission needed, a red run, and no retry.
#
# THE WAKE-UP IS NOT AN INPUT (#2259). The workflow runs on `schedule` and on
# `workflow_run` (an agent workflow run completed in this repository). Anyone
# who can make such a run complete chooses when this script runs and what the
# event payload says, so the script reads the event's NAME (GITHUB_EVENT_NAME)
# and nothing else about it: never the payload file, never a ref, a SHA or a
# branch of the triggering run. A static test holds the script and its
# libraries to that. Every run logs, and puts in its summary, which event woke
# it and how long ago the workflow last ran to a conclusion, so poor delivery
# of either trigger shows.
#
# THE EARLY EXIT (#2259; rule and reasons in scripts/lib/budget-breaker-writer.sh).
# A run woken by `workflow_run` on a fleet that is NOT paused exits 0 before the
# organisation scan when an earlier run that succeeded was created in the same
# clock slot of BUDGET_BREAKER_MIN_INTERVAL_MIN minutes AND this repository shows no quota
# marker created in that slot. It never applies to a scheduled run, never while
# the fleet is paused (by anyone: a resume is never delayed by it), and never
# when anything it needs could not be read (then the run decides).
#
# Env (set by .github/workflows/budget-breaker.yml; all optional here):
#   BUDGET_BREAKER_ARMED          `true` (exactly) arms the write path
#   BUDGET_BREAKER_TOKEN          write credential: organisation Variables read
#                                 and write. The workflow passes it only when armed.
#   BUDGET_BREAKER_SECRET_NAME    the NAME of the secret that credential comes
#                                 from, for messages and the age check. The name
#                                 lives in the workflow, not in this script.
#   BUDGET_BREAKER_READ_TOKEN     read-only scan credential for the collector.
#                                 A marker counts only when its author reads as
#                                 owner, member or collaborator TO THIS
#                                 credential, so it must be an organisation
#                                 member's (the one the retry cron and the fleet
#                                 monitor scan with).
#   BUDGET_BREAKER_NOTIFY_TOKEN   this repository's workflow token (issues: write)
#   BUDGET_BREAKER_ORG            organisation to scan and to pause (default
#                                 combsmith)
#   BUDGET_BREAKER_NOTIFY_REPO    repository of the tracking issue (default
#                                 $GITHUB_REPOSITORY)
#   BUDGET_BREAKER_VARS_PAUSED / _SOURCE / _UNTIL
#                                 the three variables as the workflow's `vars`
#                                 context shows them. Used for the would-write
#                                 log when the run is not writing; a writing run
#                                 reads the organisation through the API instead.
#   BUDGET_BREAKER_MIN_HOLD_MIN   minimum minutes a pause stands before a resume
#                                 (default 30)
#   BUDGET_BREAKER_VISIBILITY_REF organisation variable(s) whose visibility a
#                                 newly created variable copies (default AI_ENGINES)
#   BUDGET_BREAKER_ROTATE_DAYS    rotation policy for the write secret (default 90)
#   BUDGET_BREAKER_MIN_ITEMS / _WINDOW_MIN / _PROBE_HOURS / _NOW
#                                 the decision's settings (scripts/lib/budget-breaker.sh)
#   BUDGET_BREAKER_MIN_INTERVAL_MIN
#                                 length of the early exit's clock slot, minutes
#                                 (default 10; 0 switches the early exit off)
#   GITHUB_EVENT_NAME             what woke the run (set by the runner; the name
#                                 only, see "THE WAKE-UP IS NOT AN INPUT")
#   GITHUB_WORKFLOW_REF / GITHUB_RUN_ID
#                                 this workflow's file and this run, to list the
#                                 workflow's earlier runs (set by the runner)
#   GITHUB_STEP_SUMMARY           job summary (written when set)
#
# BUDGET_BREAKER_MARKER_KINDS is deliberately NOT honoured: pr-review's
# rate-limited marker means an advisory reviewer bot is out of quota, not the
# model provider, and must never count (#2221).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/budget-breaker.sh
source "${SCRIPT_DIR}/lib/budget-breaker.sh"
# shellcheck source=scripts/lib/budget-breaker-writer.sh
source "${SCRIPT_DIR}/lib/budget-breaker-writer.sh"

# The marker kinds stay at the library default, whatever the environment says.
unset BUDGET_BREAKER_MARKER_KINDS

bbw_take_credentials

ORG="${BUDGET_BREAKER_ORG:-combsmith}"
NOTIFY_REPO="${BUDGET_BREAKER_NOTIFY_REPO:-${GITHUB_REPOSITORY:-}}"
SECRET_NAME="${BUDGET_BREAKER_SECRET_NAME:-}"
SECRET_LABEL="${SECRET_NAME:-the write secret}"

WORKDIR="$(mktemp -d)" || { echo "::error::budget-breaker: cannot create a temporary directory"; exit 1; }
trap 'rm -rf "$WORKDIR"' EXIT

MODE="disarmed"
MODE_NOTE=""
EVENT="unknown"
PREV_OK="false"
PREV_TEXT="not looked up"
STATE_ORIGIN=""
STATE_TEXT="not read"
MARKERS_TEXT="not collected"
DECISION_TEXT="not decided"
PLAN_TEXT="nothing"
RESULT_TEXT=""

# write_summary — the run as a job-summary table (best effort).
write_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    printf '## Budget breaker\n\n'
    printf '| Field | Value |\n|---|---|\n'
    printf '| Mode | %s%s |\n' "$MODE" "$MODE_NOTE"
    printf '| Triggered by | %s |\n' "$EVENT"
    printf '| Previous run | %s |\n' "$PREV_TEXT"
    printf '| Pause state (%s) | `%s` |\n' "${STATE_ORIGIN:-n/a}" "$STATE_TEXT"
    printf '| Quota markers | %s |\n' "$MARKERS_TEXT"
    printf '| Decision | %s |\n' "$DECISION_TEXT"
    printf '| Write plan | %s |\n' "$PLAN_TEXT"
    printf '| Result | %s |\n' "$RESULT_TEXT"
  } | while IFS= read -r line; do
    printf '%s\n' "$(bbw_redact "$line")"
  done >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
}

# finish <exit code> <result text> — the single way out after the mode is known.
finish() {
  RESULT_TEXT="${2:-}"
  write_summary
  exit "${1:-0}"
}

# permission_error <what failed> <state note> — the ONE actionable error.
permission_error() {
  bbw_error "${1} failed (HTTP ${BBW_HTTP:-none}; gh said: ${BBW_ERR:-nothing}). The token in ${SECRET_LABEL} must be a fine-grained personal access token whose resource owner is the organisation ${ORG}, with the organisation permission \"Variables: read and write\"; it is missing that permission, expired, revoked, or not the token this workflow expects. ${2} Nothing is retried in this run. Fix the secret (AGENTS.md, \"Budget breaker\"), or disarm by setting the repository variable BUDGET_BREAKER_ARMED to false."
}

# state_read_failed <rc> — a writing run could not read the organisation.
state_read_failed() {
  case "${BBW_HTTP:-}" in
    401|403|404)
      permission_error "Reading the organisation's Actions variables" "No variable was written."
      finish 1 "FAILED: the write credential was refused on read (HTTP ${BBW_HTTP})" ;;
    *)
      bbw_warn "could not read the organisation's Actions variables (HTTP ${BBW_HTTP:-none}; ${BBW_ERR:-no detail}); failing open: nothing is written this run"
      finish 0 "no write: the pause state could not be read" ;;
  esac
}

# report_secret_age — best effort: how old the write secret is, against the
# rotation policy. The token itself has no expiry, so rotation is manual.
report_secret_age() {
  local at days rotate="${BUDGET_BREAKER_ROTATE_DAYS:-90}"
  [ -n "$SECRET_NAME" ] && [ -n "$NOTIFY_REPO" ] || return 0
  bbw_has_read_credential || return 0
  [[ "$rotate" =~ ^[0-9]{1,5}$ ]] || rotate=90
  if ! at=$(bbw_secret_updated_at "$NOTIFY_REPO" "$SECRET_NAME"); then
    bbw_log "age of ${SECRET_LABEL}: not available (the secret is not set, or the read credential may not see secret metadata)"
    return 0
  fi
  days=$(jq -nr --arg at "$at" --argjson now "$NOW" \
    '(($now - ($at | fromdateiso8601)) / 86400) | floor' 2>/dev/null) || return 0
  [[ "$days" =~ ^-?[0-9]+$ ]] || return 0
  if [ "$days" -gt "$((10#$rotate))" ]; then
    bbw_warn "${SECRET_LABEL} was last updated ${days} day(s) ago (${at}); the rotation policy is every ${rotate} days. Rotate it (AGENTS.md, \"Budget breaker\")."
  else
    bbw_log "age of ${SECRET_LABEL}: last updated ${days} day(s) ago (${at}); rotation policy: every ${rotate} days"
  fi
}

# report_previous_run — how long ago this workflow last ran to a conclusion
# (#2259), for the log and the summary, and for the early exit. Best effort,
# read credential, one listing call. Sets PREV_TEXT, and PREV_OK to `true` only
# when the earlier runs were read (BBW_PREV_RUNS).
report_previous_run() {
  local file="${GITHUB_WORKFLOW_REF:-}"
  file="${file%%@*}"
  file="${file##*/}"
  if ! bbw_read_previous_runs "$NOTIFY_REPO" "$file" "${GITHUB_RUN_ID:-}"; then
    PREV_TEXT="not available (HTTP ${BBW_HTTP:-none})"
    bbw_log "previous run: not available (HTTP ${BBW_HTTP:-none}; ${BBW_ERR:-no detail})"
    return 0
  fi
  PREV_OK="true"
  PREV_TEXT="$(bbw_previous_run_text "$BBW_PREV_RUNS" "$NOW")"
  bbw_log "previous run: ${PREV_TEXT}"
}

# exit_early_if_covered — the early exit (#2259): finishes the run before the
# organisation scan when an earlier run already covered this clock slot and
# this repository shows nothing new in it; returns, so that the run decides, in
# every other case. Called only on a fleet that is not paused. Whatever cannot
# be read means "decide": the lookup of the earlier runs, the slot, the listing
# of this repository's markers.
exit_early_if_covered() {
  local interval="${BUDGET_BREAKER_MIN_INTERVAL_MIN:-10}" slot earlier recent fresh
  # A scheduled run is the backstop and always decides.
  [ "$EVENT" = "workflow_run" ] || return 0
  if ! [[ "$interval" =~ ^[0-9]{1,4}$ ]]; then
    bbw_warn "BUDGET_BREAKER_MIN_INTERVAL_MIN is not a whole number of minutes; using 10"
    interval=10
  fi
  interval="$((10#$interval))"
  [ "$interval" -gt 0 ] || return 0
  [ "$PREV_OK" = "true" ] || return 0
  slot="$(bbw_slot_start "$NOW" "$interval")" || return 0
  earlier="$(bbw_runs_since "$BBW_PREV_RUNS" "$slot")"
  [[ "$earlier" =~ ^[0-9]+$ ]] && [ "$earlier" -gt 0 ] || return 0
  if ! recent="$(bbw_collect_recent "$NOTIFY_REPO" "$interval" 2>/dev/null)" \
      || ! fresh="$(bbw_markers_since "$recent" "$slot")"; then
    bbw_log "no early exit: the quota markers of ${NOTIFY_REPO} since ${slot} could not be read, so this run decides"
    return 0
  fi
  if [ "$fresh" != "0" ]; then
    bbw_log "no early exit: ${fresh} quota marker(s) appeared in ${NOTIFY_REPO} since ${slot}, so this run decides"
    return 0
  fi
  MARKERS_TEXT="not collected (early exit)"
  DECISION_TEXT="not taken this run (early exit)"
  bbw_log "early exit: an earlier run was created in this ${interval} min slot (since ${slot}) and ${NOTIFY_REPO} shows no quota marker since; no scan, no decision"
  finish 0 "no scan: an earlier run covered this ${interval} min slot (since ${slot}) and ${NOTIFY_REPO} shows no quota marker since"
}

# collect — run the collector with the read credential. Sets OBS, COLLECT_OK,
# TRUSTED and UNTRUSTED. The collector's own warnings are replayed, redacted.
OBS="[]"
COLLECT_OK="true"
TRUSTED=0
UNTRUSTED=0
collect() {
  local errf="$WORKDIR/collect.err" out="" rc=0 line
  if ! bbw_has_read_credential; then
    bbw_warn "no read credential is configured, so the collector cannot run; failing open: no evidence, no write"
    COLLECT_OK="false"
    return 0
  fi
  out=$(bbw_collect "$ORG" 2>"$errf") || rc=$?
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$(bbw_redact "$line")"
  done < "$errf"
  UNTRUSTED=$(bbw_untrusted_count "$errf")
  if [ "$rc" -ne 0 ] || ! jq -e 'type == "array"' <<< "$out" >/dev/null 2>&1; then
    bbw_warn "the collector could not read the fleet's quota markers; failing open: no evidence, no write"
    COLLECT_OK="false"
    return 0
  fi
  OBS="$out"
  TRUSTED=$(jq -r 'length' <<< "$OBS")
}

# run_url — this run's page, "" outside Actions.
run_url() {
  if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    printf '%s' "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  fi
}

# pause_notice_body <until> <headline> <why> <items> — the text of a notice that
# announces a pause. Its first line is the pause's marker, which is how a later
# run finds it (bbw_pause_notice_posted).
pause_notice_body() {
  printf '%s\n**%s**\n\n- **Why:** %s\n- **Until:** `%s` (the breaker lifts its own pause at the first run after that time)\n- **Set:** `%s=true`, `%s=%s`, `%s=%s` on the organisation `%s`\n\nItems that reported a quota refusal (up to 20):\n%s\n\nTo keep the fleet paused by hand, follow "Setting a pause by hand" in AGENTS.md (set `%s=true` and delete `%s` in the order given there, then check): the breaker never touches a pause without its own source, but it can lift this one between your calls. To end this pause early, set `%s=false` and delete `%s`.' \
    "$(bbw_pause_marker "$1")" "$2" "$3" "$1" \
    "$BBW_VAR_PAUSED" "$BBW_VAR_SOURCE" "$BUDGET_BREAKER_PAUSE_SOURCE" "$BBW_VAR_UNTIL" "$1" "$ORG" \
    "${4:-- none listed}" "$BBW_VAR_PAUSED" "$BBW_VAR_SOURCE" "$BBW_VAR_PAUSED" "$BBW_VAR_SOURCE"
}

# announce_held_pause — a run that HOLDS an own pause makes sure that pause was
# announced (#2251). The run that set it posts the notice after its writes; if
# that post failed, the pause stands with nothing on the tracking issue. So,
# while the pause is young (bbw_notice_lookup_due), a holding run looks for a
# notice carrying this pause's end time and posts one when there is none. The
# marker it posts is the same one it looks for, so the notice is posted once.
# It writes no variable. A look-up or a post that fails is ONE error and a red
# run, like the failed notice it stands in for. Calls finish when it posted or
# failed; returns when there was nothing to do.
announce_held_pause() {
  local at rc=0 body url
  [ "$ACTION" = "hold" ] && [ "${PAUSED,,}" = "true" ] && [ "$SOURCE" = "$BUDGET_BREAKER_PAUSE_SOURCE" ] || return 0
  [[ "$UNTIL" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 0
  at="$(jq -r --arg n "$BBW_VAR_PAUSED" '.[$n].updated_at // ""' <<< "$BBW_VARS" 2>/dev/null || printf '')"
  bbw_notice_lookup_due "$at" "$NOW" || return 0

  bbw_pause_notice_posted "$NOTIFY_REPO" "$UNTIL" || rc=$?
  case "$rc" in
    0)
      bbw_log "the notice of this pause (until ${UNTIL}) is on tracking issue #${BBW_TRACKING_NUMBER}"
      return 0 ;;
    1) ;;
    *)
      bbw_error "the fleet is paused by the breaker until ${UNTIL}, and whether that pause was announced on the tracking issue in ${NOTIFY_REPO} could not be checked (HTTP ${BBW_HTTP:-none}; ${BBW_ERR:-no detail}). No variable was touched; this run is failed so an unannounced pause does not go unseen."
      finish 1 "no write: hold; the pause notice could NOT be checked" ;;
  esac

  bbw_log "no notice of this pause (until ${UNTIL}) is on the tracking issue: the run that set it could not post one; posting it now"
  body="$(pause_notice_body "$UNTIL" "Fleet paused by the budget breaker (late notice)." \
    "the fleet is paused with the breaker's own source, and no notice of this pause was on this issue: the run that set it could not post one. The reason for the pause is in that run's log" \
    "- not listed in a late notice: see the log of the run that set the pause")"
  url="$(run_url)"
  if [ -n "$url" ]; then
    body="${body}"$'\n\n'"Run: ${url}"
  fi
  if ! bbw_notify "$NOTIFY_REPO" "$(bbw_redact "$body")"; then
    bbw_error "the fleet is paused by the breaker until ${UNTIL} and no notice of it is on the tracking issue in ${NOTIFY_REPO}; posting the missing notice failed again (HTTP ${BBW_HTTP:-none}; ${BBW_ERR:-no detail}). No variable was touched; this run is failed so the pause does not go unannounced."
    finish 1 "no write: hold; the missing pause notice could NOT be posted"
  fi
  bbw_notice "posted the missing notice of the pause until ${UNTIL} on tracking issue #${BBW_OUT}"
  finish 0 "no write: hold; posted the missing pause notice on #${BBW_OUT}"
}

# guard_stopped_trip — bbw_apply's pause guard did not set the pause. Says what
# it found, what the roll-back removed and what, if anything, is left; then
# finishes. Green with a warning when the state is clean again; red with ONE
# error when something of the breaker's is left on the state, or when the
# credential was refused.
guard_stopped_trip() {
  local cause removed="nothing" kept="" state_note
  if [ "${#BBW_ROLLED_BACK[@]}" -gt 0 ]; then
    removed="$(printf '%s; ' "${BBW_ROLLED_BACK[@]}")"
    removed="${removed%; }"
  fi
  if [ "${#BBW_ROLLBACK_KEPT[@]}" -gt 0 ]; then
    kept="$(printf '%s; ' "${BBW_ROLLBACK_KEPT[@]}")"
    kept=" Left as found: ${kept%; }."
  fi
  case "$BBW_GUARD" in
    paused)
      cause="the fleet was paused by someone else while this run was tripping (state now ${BBW_GUARD_STATE}); that pause is not the breaker's and the breaker does not claim it" ;;
    changed)
      cause="the pause state changed while this run was tripping (state now ${BBW_GUARD_STATE})" ;;
    *)
      cause="the state could not be read again before the pause was set (HTTP ${BBW_GUARD_HTTP:-none}; ${BBW_GUARD_ERR:-no detail})" ;;
  esac

  if [ -n "$BBW_ROLLBACK_FAILED" ]; then
    if [ "$BBW_ROLLBACK_OWN_SOURCE" = "true" ]; then
      state_note="${BBW_VAR_SOURCE}=${BUDGET_BREAKER_PAUSE_SOURCE} is STILL SET, and ${BBW_VAR_UNTIL}=${DECISION_UNTIL} was left with it on purpose: if the fleet is paused, the breaker will take that pause for its own and lift it after ${DECISION_UNTIL}. Delete ${BBW_VAR_SOURCE} by hand now to keep a pause set by hand, then delete ${BBW_VAR_UNTIL}."
    else
      state_note="${BBW_VAR_SOURCE} was removed, so a pause set by hand stays a human pause; ${BBW_VAR_UNTIL} is left over and has no effect without the source. Delete ${BBW_VAR_UNTIL} by hand."
    fi
    permission_error "Taking back a trip that was stopped before the pause was set (step: ${BBW_ROLLBACK_FAILED})" "The trip was stopped because ${cause}. ${BBW_VAR_PAUSED} was NOT set by this run. Removed before the failure: ${removed}.${kept} ${state_note}"
    finish 1 "FAILED: trip stopped (${BBW_GUARD}); roll-back failed at: ${BBW_ROLLBACK_FAILED}; removed: ${removed}"
  fi

  # Defence in depth: this run removes a leftover source before it ever plans a
  # trip (section 1b), so a trip here always writes the source itself and this
  # is not expected to be reached. If it ever is, it must be loud, not green.
  if [ "$BBW_GUARD" = "paused" ] && [ "$BBW_ROLLBACK_OWN_SOURCE" = "true" ]; then
    bbw_error "${cause}. But ${BBW_VAR_SOURCE}=${BUDGET_BREAKER_PAUSE_SOURCE} was already set before this run (an earlier run left it; this run did not write it, so it does not remove it), and that makes the pause look like the breaker's own: the breaker will lift it after ${DECISION_UNTIL}. To keep the pause, delete ${BBW_VAR_SOURCE} from the organisation's Actions variables by hand. ${BBW_VAR_PAUSED} was not set by this run. Removed: ${removed}.${kept}"
    finish 1 "FAILED: trip stopped (paused by someone else); an earlier run's ${BBW_VAR_SOURCE} is still set"
  fi

  if [ "$BBW_GUARD" = "unreadable" ]; then
    case "$BBW_GUARD_HTTP" in
      401|403|404)
        BBW_HTTP="$BBW_GUARD_HTTP" BBW_ERR="$BBW_GUARD_ERR"
        permission_error "Reading the organisation's Actions variables again before setting the pause" "${BBW_VAR_PAUSED} was NOT set, and what this run had written was taken back: ${removed}.${kept}"
        finish 1 "FAILED: the write credential was refused on the read before the pause (HTTP ${BBW_GUARD_HTTP}); removed: ${removed}" ;;
    esac
  fi

  bbw_warn "${cause}. ${BBW_VAR_PAUSED} was not set, nothing else was set, and no notice is posted. Removed what this run had written: ${removed}.${kept} The next run decides on the state as it now is."
  finish 0 "no pause set: trip stopped (${BBW_GUARD}); removed: ${removed}"
}

# --- 0. mode ----------------------------------------------------------------

# Only the exact string `true` arms. Unset, empty and the exact string `false`
# are the ordinary ways to be disarmed and are not remarked on. Any other value
# is a mistake and is said out loud, once per run: the workflow's own test of
# the variable cannot be exact (an Actions expression compares strings without
# regard to case), so a value like `TRUE` reaches this step WITH the write
# credential, which is dropped here, unused.
ARMED_VALUE="${BUDGET_BREAKER_ARMED:-}"
if [ "$ARMED_VALUE" != "true" ]; then
  MODE="disarmed"
  HANDED_NOTE=""
  if bbw_has_write_credential; then
    HANDED_NOTE=" The workflow handed the write credential to this step all the same, because its own test of the variable ignores case; the script has dropped it and uses it for nothing."
  fi
  bbw_drop_write_credentials
  if [ -n "$ARMED_VALUE" ] && [ "$ARMED_VALUE" != "false" ]; then
    bbw_error "BUDGET_BREAKER_ARMED is set to \"$(bbw_show "$ARMED_VALUE")\", which is neither the exact lowercase string true nor the exact lowercase string false, so the breaker is DISARMED and writes nothing. Only true arms it: TRUE, True, 1, yes, on and a value with a space before or after it do not.${HANDED_NOTE} Set the repository variable to true to arm, or to false (or delete it) to disarm (AGENTS.md, \"Budget breaker\")."
    MODE_NOTE=" (BUDGET_BREAKER_ARMED is set but is neither true nor false)"
  fi
elif ! bbw_has_write_credential; then
  MODE="armed, no credential"
  bbw_drop_write_credentials
  bbw_warn "breaker armed but ${SECRET_LABEL} is not configured; nothing will be written"
else
  MODE="armed"
fi

NOW="$(bb_now)"
if ! [[ "$NOW" =~ ^[0-9]{1,12}$ ]]; then
  bbw_warn "the clock override is not epoch seconds; using the system clock"
  NOW="$(date -u +%s)"
fi
export BUDGET_BREAKER_NOW="$NOW"

if ! bbw_valid_org "$ORG"; then
  bbw_error "the organisation name is not a valid login; nothing is read or written"
  finish 1 "FAILED: invalid organisation name"
fi

report_secret_age

# What woke this run: the event's name, from the runner, and nothing else of
# the event (see "THE WAKE-UP IS NOT AN INPUT"). An unexpected name is not
# echoed.
case "${GITHUB_EVENT_NAME:-}" in
  schedule|workflow_run) EVENT="$GITHUB_EVENT_NAME" ;;
  "") EVENT="unknown" ;;
  *) EVENT="other" ;;
esac
bbw_log "triggered by: ${EVENT}"
report_previous_run

# --- 1. the pause state -----------------------------------------------------

if [ "$MODE" = "armed" ]; then
  STATE_ORIGIN="organisation API"
  rc=0
  bbw_read_org_vars "$ORG" || rc=$?
  if [ "$rc" -ne 0 ]; then
    state_read_failed "$rc"
  fi
else
  STATE_ORIGIN="this repository's vars context"
  BBW_VARS="$(bbw_vars_from_context "${BUDGET_BREAKER_VARS_PAUSED:-}" \
    "${BUDGET_BREAKER_VARS_SOURCE:-}" "${BUDGET_BREAKER_VARS_UNTIL:-}")"
fi

PAUSED="$(bbw_var_value "$BBW_VARS" "$BBW_VAR_PAUSED")"
SOURCE="$(bbw_var_value "$BBW_VARS" "$BBW_VAR_SOURCE")"
UNTIL="$(bbw_var_value "$BBW_VARS" "$BBW_VAR_UNTIL")"
STATE_TEXT="$(bbw_state_key "$BBW_VARS")"
bbw_log "mode: ${MODE}"
bbw_log "pause state from ${STATE_ORIGIN}: [${BBW_VAR_PAUSED}, ${BBW_VAR_SOURCE}, ${BBW_VAR_UNTIL}] = ${STATE_TEXT}"

# --- 1b. leftover ownership markers ------------------------------------------

# The breaker's own source on a fleet that is not paused is left over (a trip
# that failed before it set the pause, or a pause someone ended by hand). A
# pause set by hand while it is there would read as the breaker's own and be
# lifted by it, so it is removed before anything else is considered: the
# source, then the until. This is the one further exception to "none writes
# nothing" (the other is the roll-back of a stopped trip), and it is this run's
# ONE state change: nothing is collected or decided here, and the next run
# decides on the clean state. It is applied straight after the read above, so
# the only window for a pause set by hand to slip in is that one call. A source
# with any other value is not the breaker's and is never touched.
LEFTOVER="$(bbw_leftover_plan "$BBW_VARS")"
if [ -n "$LEFTOVER" ] && [ "$LEFTOVER" != "[]" ]; then
  PLAN_TEXT="$(bbw_plan_text "$LEFTOVER")"
  MARKERS_TEXT="not collected (leftover ownership markers are dealt with first)"
  DECISION_TEXT="not taken this run: ${BBW_VAR_SOURCE}=${BUDGET_BREAKER_PAUSE_SOURCE} is set while the fleet is not paused, and removing it is this run's one state change"
  bbw_log "decision: ${DECISION_TEXT}"
  if [ "$MODE" != "armed" ]; then
    bbw_warn "${BBW_VAR_SOURCE}=${BUDGET_BREAKER_PAUSE_SOURCE} is set while the fleet is not paused. A pause set by hand now would look like the breaker's own. An armed run removes these leftover ownership markers; this run is not armed, so delete ${BBW_VAR_SOURCE} (and ${BBW_VAR_UNTIL}) from the organisation's Actions variables by hand."
    bbw_log "NOT WRITING (${MODE}). Would have written: ${PLAN_TEXT}"
    finish 0 "no write (${MODE}); would have written: ${PLAN_TEXT}"
  fi
  bbw_log "writing: ${PLAN_TEXT}"
  if ! bbw_apply "$ORG" "$LEFTOVER"; then
    DONE_TEXT="nothing"
    if [ "${#BBW_DONE[@]}" -gt 0 ]; then
      DONE_TEXT="$(printf '%s; ' "${BBW_DONE[@]}")"
    fi
    if [ "${#BBW_DONE[@]}" -eq 0 ]; then
      LEFT_NOTE="${BBW_VAR_SOURCE}=${BUDGET_BREAKER_PAUSE_SOURCE} is still set, so a pause set by hand now would read as the breaker's own and be lifted by it: delete ${BBW_VAR_SOURCE} (and ${BBW_VAR_UNTIL}) by hand."
    else
      LEFT_NOTE="${BBW_VAR_SOURCE} is gone, so a pause set by hand is a human pause; ${BBW_VAR_UNTIL} is left over and has no effect without the source: delete it by hand."
    fi
    permission_error "Removing the breaker's leftover ownership markers (step: ${BBW_FAILED_STEP})" "Planned: ${PLAN_TEXT}. Completed before the failure: ${DONE_TEXT%; }. ${LEFT_NOTE}"
    finish 1 "FAILED removing leftover ownership markers at step: ${BBW_FAILED_STEP}; completed: ${DONE_TEXT%; }"
  fi
  for step in "${BBW_DONE[@]}"; do
    bbw_log "wrote: ${step}"
  done
  bbw_warn "leftover ownership markers from an earlier run were removed (${PLAN_TEXT}): ${BBW_VAR_SOURCE}=${BUDGET_BREAKER_PAUSE_SOURCE} was set while the fleet was not paused, so a pause set by hand would have read as the breaker's own and been lifted by it. That was this run's one state change; nothing else is written and the next run decides normally."
  finish 0 "wrote: ${PLAN_TEXT} (leftover ownership markers removed; no decision this run)"
fi

# --- 2. the evidence --------------------------------------------------------

if [ "${PAUSED,,}" = "true" ]; then
  MARKERS_TEXT="not collected (the fleet is paused; the decision does not consult them)"
  bbw_log "the fleet is paused: quota markers are not consulted while paused, so none are collected"
else
  # Not paused, so a resume cannot be waiting on this run: the early exit may
  # apply. It is never reached on a paused fleet.
  exit_early_if_covered
  collect
  if [ "$COLLECT_OK" = "true" ]; then
    MARKERS_TEXT="${TRUSTED} trusted, ${UNTRUSTED} dropped as untrusted"
    bbw_log "quota markers read: ${TRUSTED} trusted, ${UNTRUSTED} dropped as untrusted (author not an owner, member or collaborator as the read credential sees it)"
    if [ "$UNTRUSTED" -gt 0 ] && [ "$TRUSTED" -eq 0 ]; then
      bbw_warn "every quota marker seen (${UNTRUSTED}) was dropped as untrusted: the read credential does not see the agents' accounts as owner, member or collaborator, so with this credential the breaker can never trip. Check which secret the workflow reads with."
    fi
  else
    MARKERS_TEXT="collector failed (${UNTRUSTED} marker(s) dropped as untrusted before it did)"
  fi
fi

# --- 3. the decision --------------------------------------------------------

if [ "$COLLECT_OK" = "true" ]; then
  DECISION="$(bb_decide "$OBS" "$PAUSED" "$SOURCE" "$UNTIL" "$NOW")"
else
  DECISION='{"action":"none","until":null,"reason":"the collector could not read the fleet; failing open","evidence_count":0}'
fi
ACTION="$(jq -r '.action // ""' <<< "$DECISION" 2>/dev/null || printf '')"
case "$ACTION" in
  trip|hold|resume|none) ;;
  *)
    bbw_warn "the decision could not be read; failing open with action=none"
    DECISION='{"action":"none","until":null,"reason":"the decision could not be read; failing open","evidence_count":0}'
    ACTION="none" ;;
esac
REASON="$(jq -r '.reason // ""' <<< "$DECISION")"
EVIDENCE="$(jq -r '.evidence_count // 0' <<< "$DECISION")"
DECISION_UNTIL="$(jq -r '.until // ""' <<< "$DECISION")"
DECISION_TEXT="${ACTION} (evidence_count=${EVIDENCE}): ${REASON}"
bbw_log "decision: ${DECISION_TEXT}"

# Minimum hold: a resume waits until the pause switch has stood long enough.
HOLD_DEFERRED="false"
if [ "$ACTION" = "resume" ]; then
  MIN_HOLD="${BUDGET_BREAKER_MIN_HOLD_MIN:-30}"
  if ! [[ "$MIN_HOLD" =~ ^[0-9]{1,6}$ ]]; then
    bbw_warn "BUDGET_BREAKER_MIN_HOLD_MIN is not a whole number of minutes; using 30"
    MIN_HOLD=30
  fi
  PAUSED_AT="$(jq -r --arg n "$BBW_VAR_PAUSED" '.[$n].updated_at // ""' <<< "$BBW_VARS" 2>/dev/null || printf '')"
  HOLD_FROM="$PAUSED_AT"
  HOLD_FROM_TEXT="${BBW_VAR_PAUSED} was last set at ${PAUSED_AT}"
  # The API gives the time the switch was set. When a writing run cannot use it
  # (missing, malformed, or later than now) the hold is not waved through: it
  # is measured from the pause's own end time, which an own pause always has and
  # which is the latest moment the pause can have been set (a trip only ever
  # sets an end time ahead of itself). The pause has then stood for at least the
  # minimum hold when the resume is written, and the wait ends by itself: at
  # most the minimum hold after the end time, with nothing kept between runs.
  # A run that is not writing has no such time at all (the vars context does not
  # carry one), so it only logs the resume it would make, as before.
  if [ "$MODE" = "armed" ] && ! bbw_time_not_after "$PAUSED_AT" "$NOW"; then
    if bbw_time_not_after "$UNTIL" "$NOW"; then
      HOLD_FROM="$UNTIL"
      HOLD_FROM_TEXT="measured from the pause's end time ${UNTIL}"
      bbw_warn "the time ${BBW_VAR_PAUSED} was last set cannot be used (updated_at from the organisation API: \"$(bbw_show "$PAUSED_AT")\"), so the minimum hold is measured from the pause's end time (${UNTIL}) instead: this can delay the resume by up to ${MIN_HOLD} min after that time, and never longer"
    else
      HOLD_FROM=""
      bbw_warn "minimum hold not evaluated: neither the time ${BBW_VAR_PAUSED} was last set nor the pause's end time can be used, so there is nothing to measure it from; the resume goes ahead (bad data never keeps the fleet paused)"
    fi
  fi
  REMAINING="$(bbw_hold_remaining "$HOLD_FROM" "$NOW" "$MIN_HOLD")"
  if [[ "$REMAINING" =~ ^[0-9]+$ ]] && [ "$REMAINING" -gt 0 ]; then
    bbw_log "resume deferred by the minimum hold: ${HOLD_FROM_TEXT}, ${REMAINING}s of the ${MIN_HOLD} min hold remain"
    DECISION_TEXT="${DECISION_TEXT} [deferred: ${REMAINING}s of the ${MIN_HOLD} min minimum hold remain]"
    HOLD_DEFERRED="true"
  elif [ -z "$PAUSED_AT" ] && [ "$MODE" != "armed" ]; then
    bbw_log "minimum hold not evaluated: the time ${BBW_VAR_PAUSED} was set is not known from ${STATE_ORIGIN}"
  fi
fi

# --- 4. the plan ------------------------------------------------------------

if [ "$HOLD_DEFERRED" = "true" ]; then
  PLAN="[]"
elif ! PLAN="$(bbw_plan "$DECISION" "$BBW_VARS")" || [ -z "$PLAN" ]; then
  bbw_warn "the decision (${ACTION}) does not fit the pause state that was read; failing open: nothing is written"
  PLAN="[]"
fi
PLAN_TEXT="$(bbw_plan_text "$PLAN")"

if [ "$MODE" != "armed" ]; then
  bbw_log "NOT WRITING (${MODE}). Would have written: ${PLAN_TEXT}"
  finish 0 "no write (${MODE}); would have written: ${PLAN_TEXT}"
fi

if [ "$PLAN" = "[]" ]; then
  bbw_log "nothing to write (${ACTION})"
  announce_held_pause
  finish 0 "no write: ${ACTION}"
fi

# --- 5. apply ---------------------------------------------------------------

# The state is read once more immediately before the first write: if anyone (a
# human pausing by hand, another run) changed it while this run was collecting,
# this run writes nothing and the next one decides on the new state.
BEFORE="$(bbw_state_key "$BBW_VARS")"
rc=0
bbw_read_org_vars "$ORG" || rc=$?
if [ "$rc" -ne 0 ]; then
  state_read_failed "$rc"
fi
AFTER="$(bbw_state_key "$BBW_VARS")"
if [ "$BEFORE" != "$AFTER" ]; then
  bbw_warn "the pause state changed while this run was deciding (was ${BEFORE}, now ${AFTER}); nothing is written, the next run decides on the new state"
  finish 0 "no write: the pause state changed during the run"
fi

bbw_log "writing: ${PLAN_TEXT}"
if ! bbw_apply "$ORG" "$PLAN"; then
  if [ "$BBW_FAILED_KIND" = "guard" ]; then
    for step in "${BBW_DONE[@]}"; do
      bbw_log "wrote: ${step}"
    done
    guard_stopped_trip
  fi
  if [ "$BBW_FAILED_KIND" = "setup" ]; then
    # Not a credential problem: a step could not be worked out, so no call was
    # made. In practice: a variable has to be created and its visibility
    # cannot be read from the organisation.
    bbw_error "cannot ${BBW_FAILED_STEP}: ${BBW_ERR:-no detail}. The breaker never guesses a new variable's visibility and does not copy a repository selection: it needs a reference that is visible to all (or to private) repositories. If ${BBW_VAR_PAUSED} does not exist, create it (value false) as an Actions variable of the organisation ${ORG} by hand with that visibility; the breaker then creates its other two variables to match and updates all three in place. Nothing was written (planned: ${PLAN_TEXT}). Nothing is retried in this run."
    finish 1 "FAILED before any write: cannot ${BBW_FAILED_STEP}"
  fi
  DONE_TEXT="nothing"
  if [ "${#BBW_DONE[@]}" -gt 0 ]; then
    DONE_TEXT="$(printf '%s; ' "${BBW_DONE[@]}")"
  fi
  permission_error "Writing the fleet pause (step: ${BBW_FAILED_STEP})" "Planned: ${PLAN_TEXT}. Completed before the failure: ${DONE_TEXT%; }. The steps after the failed one were not attempted, so check the three variables by hand."
  finish 1 "FAILED at step: ${BBW_FAILED_STEP}; completed: ${DONE_TEXT%; }"
fi
for step in "${BBW_DONE[@]}"; do
  bbw_log "wrote: ${step}"
done

RUN_URL="$(run_url)"

if [ "$ACTION" = "trip" ]; then
  bbw_notice "fleet PAUSED until ${DECISION_UNTIL} (${REASON})"
  ITEMS="$(jq -r '[.[] | "\(.repo)#\(.item)"] | unique | .[:20] | map("- `\(.)`") | join("\n")' <<< "$OBS" 2>/dev/null || printf '')"
  BODY="$(pause_notice_body "$DECISION_UNTIL" "Fleet paused by the budget breaker." "$REASON" "$ITEMS")"
else
  bbw_notice "fleet RESUMED (${REASON})"
  BODY="$(printf '**Fleet resumed by the budget breaker.**\n\n- **Why:** %s\n- **Set:** `%s=false`, and `%s` and `%s` removed, on the organisation `%s`\n\nIf the provider is still refusing work, the next refusals pause the fleet again.' \
    "$REASON" "$BBW_VAR_PAUSED" "$BBW_VAR_SOURCE" "$BBW_VAR_UNTIL" "$ORG")"
fi
if [ -n "$RUN_URL" ]; then
  BODY="${BODY}"$'\n\n'"Run: ${RUN_URL}"
fi

if ! bbw_notify "$NOTIFY_REPO" "$(bbw_redact "$BODY")"; then
  LATE_NOTE=""
  if [ "$ACTION" = "trip" ]; then
    LATE_NOTE=" A later run that holds this pause posts the missing notice, once, while the pause is less than ${BBW_NOTICE_CATCHUP_MIN} min old."
  fi
  bbw_error "the fleet pause state was changed (${PLAN_TEXT}) but the notice could not be posted on the tracking issue in ${NOTIFY_REPO} (HTTP ${BBW_HTTP:-none}; ${BBW_ERR:-no detail}). The variables are correct; this run is failed so the change does not go unannounced.${LATE_NOTE}"
  finish 1 "state changed (${PLAN_TEXT}) but the notice FAILED"
fi
bbw_log "notice posted on tracking issue #${BBW_OUT} in ${NOTIFY_REPO}"
finish 0 "wrote: ${PLAN_TEXT}; notice posted on #${BBW_OUT}"
