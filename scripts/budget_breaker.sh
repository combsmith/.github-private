#!/usr/bin/env bash
# budget_breaker.sh — the reactive budget breaker's WRITER (#2153, slice 3b of
# #1565). One run:
#
#   1. read the fleet pause state (AGENTS_PAUSED, AGENTS_PAUSE_SOURCE,
#      AGENTS_PAUSE_UNTIL);
#   2. collect the fleet's quota markers (bb_collect) unless the fleet is paused,
#      in which case the decision does not consult them;
#   3. decide (bb_decide, scripts/lib/budget-breaker.sh: the decision is slice 3a
#      and is not re-implemented here);
#   4. apply:  trip    AGENTS_PAUSE_SOURCE, AGENTS_PAUSE_UNTIL, AGENTS_PAUSED=true
#              resume  AGENTS_PAUSED=false, then delete source and until
#              hold / none   nothing
#      and post one notice on the tracking issue for a trip and one for a resume.
#
# DEFAULT OFF, TWICE. Nothing is written unless BUDGET_BREAKER_ARMED is exactly
# `true` AND the write credential is present. In every other case the run still
# reads, decides and logs the write it WOULD have made.
#
# FAIL OPEN. A collector that could not read, an unreadable state, a decision
# that does not fit the state, or a state that changed under the run all mean
# NO WRITE. Missing data never pauses the fleet and never keeps it paused.
#
# A HUMAN PAUSE IS NEVER TOUCHED. A pause with no source, or with a source that
# is not the breaker's own, is left exactly as it is: bb_decide returns `none`
# for it, and bbw_plan refuses to plan a write against it whatever the decision.
#
# Anti-flap: one decision and at most one state change per run; a step whose
# target already holds the wanted value is skipped; a resume waits until the
# pause switch has stood for BUDGET_BREAKER_MIN_HOLD_MIN.
#
# A failed write or a refused credential is ONE `::error::` naming the
# permission needed, a red run, and no retry.
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
    printf '| Mode | %s |\n' "$MODE"
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
  bbw_error "${1} failed (HTTP ${BBW_HTTP:-none}; gh said: ${BBW_ERR:-nothing}). The token in ${SECRET_LABEL} must be a fine-grained personal access token whose resource owner is the organisation ${ORG}, with the organisation permission \"Variables: read and write\"; it is missing that permission, expired, revoked, or not the token this workflow expects. ${2} Nothing is retried in this run. Fix the secret (AGENTS.md, \"Budget breaker\"), or disarm by setting the repository variable BUDGET_BREAKER_ARMED to anything but true."
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

# --- 0. mode ----------------------------------------------------------------

if [ "${BUDGET_BREAKER_ARMED:-}" != "true" ]; then
  MODE="disarmed"
  bbw_drop_write_credentials
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

# --- 2. the evidence --------------------------------------------------------

if [ "${PAUSED,,}" = "true" ]; then
  MARKERS_TEXT="not collected (the fleet is paused; the decision does not consult them)"
  bbw_log "the fleet is paused: quota markers are not consulted while paused, so none are collected"
else
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

# A source of ours on a fleet that is not paused is left over from a run that
# failed between two writes, or from a pause someone ended by hand. It is not
# written away here (hold and none write nothing), but it must not go unseen:
# a pause set by hand while it is there would carry the breaker's source.
if [ "${PAUSED,,}" != "true" ] && [ "$SOURCE" = "$BUDGET_BREAKER_PAUSE_SOURCE" ] && [ "$ACTION" = "none" ]; then
  bbw_warn "${BBW_VAR_SOURCE}=${BUDGET_BREAKER_PAUSE_SOURCE} is set while the fleet is not paused. A pause set by hand now would look like the breaker's own and be lifted by it. Delete ${BBW_VAR_SOURCE} (and ${BBW_VAR_UNTIL}) from the organisation's Actions variables."
fi

# Minimum hold: a resume waits until the pause switch has stood long enough.
HOLD_DEFERRED="false"
if [ "$ACTION" = "resume" ]; then
  MIN_HOLD="${BUDGET_BREAKER_MIN_HOLD_MIN:-30}"
  if ! [[ "$MIN_HOLD" =~ ^[0-9]{1,6}$ ]]; then
    bbw_warn "BUDGET_BREAKER_MIN_HOLD_MIN is not a whole number of minutes; using 30"
    MIN_HOLD=30
  fi
  PAUSED_AT="$(jq -r --arg n "$BBW_VAR_PAUSED" '.[$n].updated_at // ""' <<< "$BBW_VARS" 2>/dev/null || printf '')"
  REMAINING="$(bbw_hold_remaining "$PAUSED_AT" "$NOW" "$MIN_HOLD")"
  if [[ "$REMAINING" =~ ^[0-9]+$ ]] && [ "$REMAINING" -gt 0 ]; then
    bbw_log "resume deferred by the minimum hold: ${BBW_VAR_PAUSED} was last set at ${PAUSED_AT}, ${REMAINING}s of the ${MIN_HOLD} min hold remain"
    DECISION_TEXT="${DECISION_TEXT} [deferred: ${REMAINING}s of the ${MIN_HOLD} min minimum hold remain]"
    HOLD_DEFERRED="true"
  elif [ -z "$PAUSED_AT" ]; then
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

RUN_URL=""
if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
  RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

if [ "$ACTION" = "trip" ]; then
  bbw_notice "fleet PAUSED until ${DECISION_UNTIL} (${REASON})"
  ITEMS="$(jq -r '[.[] | "\(.repo)#\(.item)"] | unique | .[:20] | map("- `\(.)`") | join("\n")' <<< "$OBS" 2>/dev/null || printf '')"
  BODY="$(printf '**Fleet paused by the budget breaker.**\n\n- **Why:** %s\n- **Until:** `%s` (the breaker lifts its own pause at the first run after that time)\n- **Set:** `%s=true`, `%s=%s`, `%s=%s` on the organisation `%s`\n\nItems that reported a quota refusal (up to 20):\n%s\n\nTo keep the fleet paused by hand, set `%s=true` and delete `%s`: the breaker never touches a pause without its own source. To end this pause early, set `%s=false` and delete `%s`.' \
    "$REASON" "$DECISION_UNTIL" \
    "$BBW_VAR_PAUSED" "$BBW_VAR_SOURCE" "$BUDGET_BREAKER_PAUSE_SOURCE" "$BBW_VAR_UNTIL" "$DECISION_UNTIL" "$ORG" \
    "${ITEMS:-- none listed}" "$BBW_VAR_PAUSED" "$BBW_VAR_SOURCE" "$BBW_VAR_PAUSED" "$BBW_VAR_SOURCE")"
else
  bbw_notice "fleet RESUMED (${REASON})"
  BODY="$(printf '**Fleet resumed by the budget breaker.**\n\n- **Why:** %s\n- **Set:** `%s=false`, and `%s` and `%s` removed, on the organisation `%s`\n\nIf the provider is still refusing work, the next refusals pause the fleet again.' \
    "$REASON" "$BBW_VAR_PAUSED" "$BBW_VAR_SOURCE" "$BBW_VAR_UNTIL" "$ORG")"
fi
if [ -n "$RUN_URL" ]; then
  BODY="${BODY}"$'\n\n'"Run: ${RUN_URL}"
fi

if ! bbw_notify "$NOTIFY_REPO" "$(bbw_redact "$BODY")"; then
  bbw_error "the fleet pause state was changed (${PLAN_TEXT}) but the notice could not be posted on the tracking issue in ${NOTIFY_REPO} (HTTP ${BBW_HTTP:-none}; ${BBW_ERR:-no detail}). The variables are correct; this run is failed so the change does not go unannounced."
  finish 1 "state changed (${PLAN_TEXT}) but the notice FAILED"
fi
bbw_log "notice posted on tracking issue #${BBW_OUT} in ${NOTIFY_REPO}"
finish 0 "wrote: ${PLAN_TEXT}; notice posted on #${BBW_OUT}"
