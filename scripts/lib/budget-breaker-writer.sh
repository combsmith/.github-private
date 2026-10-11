# shellcheck shell=bash
# shellcheck disable=SC2034  # the BBW_* result variables are read by scripts/budget_breaker.sh
# scripts/lib/budget-breaker-writer.sh — the WRITE half of the reactive budget
# breaker (#2153, slice 3b of #1565).
#
# scripts/lib/budget-breaker.sh DECIDES and reads (slice 3a, #2221) and is held
# by a static test to writing nothing. This file is the only code that writes the
# fleet pause switch, and scripts/budget_breaker.sh is its only caller.
#
# ----------------------------------------------------------------------------
# The three organisation Actions variables
#
#   AGENTS_PAUSED         the switch every agent workflow gates on (`vars.` in the
#                         CALLING repository's context, so only an organisation
#                         variable pauses every repository; a repository variable
#                         of the same name overrides it for that repository).
#   AGENTS_PAUSE_SOURCE   who set the pause. The breaker's own value is
#                         BUDGET_BREAKER_PAUSE_SOURCE (`rate-limit-observed`).
#                         Absent, or any other value, means "not ours": a human.
#   AGENTS_PAUSE_UNTIL    when the breaker's own pause ends (ISO-8601 UTC). It is
#                         how the hold survives between runs.
#
# REST calls (organisation Actions variables; the write credential is a
# fine-grained token with the organisation permission "Variables: read and
# write" and nothing else):
#   read    GET    /orgs/{org}/actions/variables?per_page=30        (paginated)
#   update  PATCH  /orgs/{org}/actions/variables/{name}   value only, so the
#                                                         variable's visibility
#                                                         is left as it is
#   create  POST   /orgs/{org}/actions/variables          name, value, visibility
#   delete  DELETE /orgs/{org}/actions/variables/{name}
# A value is always sent as a raw string field (`-f`): `-F` would turn `true`
# into a JSON boolean, which the API rejects.
#
# Write order (so a failure between two writes never leaves a pause that looks
# like a human's, i.e. paused with no source):
#   trip    AGENTS_PAUSE_SOURCE, AGENTS_PAUSE_UNTIL, then AGENTS_PAUSED=true
#   resume  AGENTS_PAUSED=false, then delete AGENTS_PAUSE_SOURCE and
#           AGENTS_PAUSE_UNTIL
# A step whose target already holds the wanted state is skipped.
#
# The pause guard (#2251). A trip that has written a source or an until reads
# the state ONCE MORE before it sets the pause. If the fleet is by then paused
# by anyone, or the state is in any other way not "what was read before, plus
# what this run wrote", the pause is not set and the run takes back what it
# wrote: it deletes AGENTS_PAUSE_SOURCE first (the source is what makes a pause
# the breaker's), then AGENTS_PAUSE_UNTIL. It deletes only a variable THIS run
# wrote and that still holds the value this run wrote; it never sets anything.
# That narrows the window in which a pause set by hand can be claimed to the
# one call between this read and the write of the pause. It does not close it.
#
# Leftover ownership markers (#2251). The breaker's own source on a fleet that
# is NOT paused is left over: from a trip that failed before it set the pause,
# or from a pause someone ended by hand without deleting the source. While it
# is there, a pause set by hand reads as the breaker's own and would be lifted
# by it. bbw_leftover_plan plans its removal (the source, then the until), and
# an armed run applies that INSTEAD of deciding: it is that run's one state
# change. Only the breaker's own value is ever removed; a source with any other
# value is somebody else's and is left alone, as is an until with no own source.
#
# ----------------------------------------------------------------------------
# Credentials
#
# Three separate credentials, each used only for its own calls and never
# exported: bbw_take_credentials moves them out of the environment, so no child
# process inherits one unless a call here hands it over for that call alone.
#   write   organisation Variables read and write   state read + variable writes
#   read    the fleet's read-only scan credential   the collector, secret age
#   notify  this repository's workflow token        the tracking-issue notice,
#                                                   and the look-up of an
#                                                   earlier one
# Everything this file prints goes through bbw_redact.
#
# Sourced (`# shellcheck source=scripts/lib/budget-breaker-writer.sh`) AFTER
# scripts/lib/budget-breaker.sh, whose BUDGET_BREAKER_PAUSE_SOURCE it uses.
# Sourcing it runs nothing.

BBW_VAR_PAUSED="AGENTS_PAUSED"
BBW_VAR_SOURCE="AGENTS_PAUSE_SOURCE"
BBW_VAR_UNTIL="AGENTS_PAUSE_UNTIL"

# The single tracking issue the trip and clear notices are comments on.
BBW_TRACKING_TITLE="Budget breaker: automatic fleet pauses (tracking)"
BBW_TRACKING_LABEL="budget-breaker"
# dev-lead skips any issue carrying this label (scripts/dev-lead-intent.sh).
BBW_HANDS_OFF_LABEL="dev-lead:hands-off"

_BBW_WRITE_CRED=""
_BBW_READ_CRED=""
_BBW_NOTIFY_CRED=""
_BBW_REDACT=()

# Results of the last _bbw_gh call.
BBW_OUT=""
BBW_ERR=""
BBW_HTTP=""
# The organisation's variables as last read: {"<NAME>": {name, value, visibility, updated_at}}.
BBW_VARS="{}"
# What bbw_apply did and where it stopped.
BBW_DONE=()
BBW_FAILED_STEP=""
# "setup": a step could not be resolved, so no call was made and nothing was
# written. "call": an API call failed (BBW_HTTP / BBW_ERR are that call's).
BBW_FAILED_KIND=""
# The visibility bbw_create_visibility resolved.
BBW_CREATE_VIS=""
# The pause guard of the last bbw_apply (BBW_FAILED_KIND is then "guard"):
#   BBW_GUARD            why the pause was not set: "paused" (the fleet is paused
#                        by someone else), "changed" (the state is otherwise not
#                        what this run left) or "unreadable" (the read failed;
#                        BBW_GUARD_HTTP / BBW_GUARD_ERR are that read's)
#   BBW_GUARD_STATE      the three values as that read saw them ("" if unreadable)
#   BBW_ROLLED_BACK      what the roll-back removed
#   BBW_ROLLBACK_KEPT    what this run wrote and the roll-back left, with why
#   BBW_ROLLBACK_FAILED  the roll-back step that failed ("" when none did;
#                        BBW_HTTP / BBW_ERR are then that call's)
#   BBW_ROLLBACK_OWN_SOURCE  "true" when the breaker's source is still set after
#                        the roll-back: an earlier run left it, or its delete failed
BBW_GUARD=""
BBW_GUARD_HTTP=""
BBW_GUARD_ERR=""
BBW_GUARD_STATE=""
BBW_ROLLED_BACK=()
BBW_ROLLBACK_KEPT=()
BBW_ROLLBACK_FAILED=""
BBW_ROLLBACK_OWN_SOURCE=""
# The values the current bbw_apply call has written ("" = not written by it).
_BBW_WROTE_SOURCE=""
_BBW_WROTE_UNTIL=""
# The number of the open tracking issue, as bbw_find_tracking_issue last saw it.
BBW_TRACKING_NUMBER=""
# A hold run looks for a pause's missing notice only while the pause switch was
# set less than this many minutes ago (see bbw_notice_lookup_due).
BBW_NOTICE_CATCHUP_MIN=60

# ---------------------------------------------------------------------------
# bbw_take_credentials — move the three credentials out of the environment into
# unexported shell variables, and drop every ambient GitHub credential, so a gh
# call can only ever run with the credential it is explicitly given.
# ---------------------------------------------------------------------------
bbw_take_credentials() {
  _BBW_WRITE_CRED="${BUDGET_BREAKER_TOKEN:-}"
  _BBW_READ_CRED="${BUDGET_BREAKER_READ_TOKEN:-}"
  _BBW_NOTIFY_CRED="${BUDGET_BREAKER_NOTIFY_TOKEN:-}"
  unset BUDGET_BREAKER_TOKEN BUDGET_BREAKER_READ_TOKEN BUDGET_BREAKER_NOTIFY_TOKEN
  unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
  _BBW_REDACT=()
  local c
  for c in "$_BBW_WRITE_CRED" "$_BBW_READ_CRED" "$_BBW_NOTIFY_CRED"; do
    if [ -n "$c" ]; then
      _BBW_REDACT+=("$c")
    fi
  done
}

# bbw_drop_write_credentials — a run that must not write holds nothing to write
# with. The values stay on the redaction list.
bbw_drop_write_credentials() {
  _BBW_WRITE_CRED=""
  _BBW_NOTIFY_CRED=""
}

bbw_has_write_credential() { [ -n "$_BBW_WRITE_CRED" ]; }
bbw_has_read_credential() { [ -n "$_BBW_READ_CRED" ]; }

# ---------------------------------------------------------------------------
# bbw_redact <text> — the text with every credential value replaced by `***`.
# ---------------------------------------------------------------------------
bbw_redact() {
  local text="${1:-}" c
  for c in "${_BBW_REDACT[@]}"; do
    text="${text//"$c"/***}"
  done
  printf '%s' "$text"
}

# ---------------------------------------------------------------------------
# bbw_show <text> — PURE. A value that is not the script's own (a variable as a
# maintainer typed it, a field of an API answer), made safe to put in ONE log
# line: every character that is not printable becomes `?`, so it cannot start a
# new line or a workflow command, and it is cut to 40 characters.
# ---------------------------------------------------------------------------
bbw_show() {
  local text="${1:-}"
  text="${text//[^[:print:]]/?}"
  printf '%s' "${text:0:40}"
}

bbw_log()    { printf 'budget-breaker: %s\n' "$(bbw_redact "$*")"; }
bbw_notice() { printf '::notice::budget-breaker: %s\n' "$(bbw_redact "$*")"; }
bbw_warn()   { printf '::warning::budget-breaker: %s\n' "$(bbw_redact "$*")"; }
bbw_error()  { printf '::error::budget-breaker: %s\n' "$(bbw_redact "$*")"; }

# ---------------------------------------------------------------------------
# _bbw_gh <credential> <gh args>... — run gh with exactly this credential.
# Sets BBW_OUT (stdout), BBW_ERR (stderr, one line, redacted, cut to 300
# characters) and BBW_HTTP (the status gh reported for a failed call, else "").
# Returns gh's exit status; 1 without calling gh when the credential is empty,
# so gh can never fall back to a credential it found by itself.
# Sets globals: call it directly, never inside `$(...)`.
# ---------------------------------------------------------------------------
_bbw_gh() {
  local cred="${1:-}" errf rc=0
  shift
  BBW_OUT="" BBW_ERR="" BBW_HTTP=""
  if [ -z "$cred" ]; then
    BBW_ERR="no credential for this call"
    return 1
  fi
  errf="$(mktemp)" || { BBW_ERR="cannot create a temporary file"; return 1; }
  BBW_OUT="$(GH_TOKEN="$cred" gh "$@" 2>"$errf")" || rc=$?
  BBW_ERR="$(bbw_redact "$(tr '\n' ' ' < "$errf" | cut -c1-300)")"
  rm -f "$errf"
  if [[ "$BBW_ERR" =~ HTTP\ ([0-9]{3}) ]]; then
    BBW_HTTP="${BASH_REMATCH[1]}"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# bbw_collect <org>... — bb_collect (scripts/lib/budget-breaker.sh) with the
# READ credential and nothing else: the subshell keeps the credential out of
# this shell's environment, and the write credential is never exported at all.
# Prints the observation array; returns bb_collect's status.
# ---------------------------------------------------------------------------
bbw_collect() {
  ( export GH_TOKEN="$_BBW_READ_CRED"; bb_collect "$@" )
}

# ---------------------------------------------------------------------------
# bbw_untrusted_count <collector_stderr_file> — PURE. How many quota markers
# the collector dropped because their author did not read as an owner, member
# or collaborator: the sum over bb_observations_from_comments' per-repository
# warnings ("ignored <n> quota marker(s) ..."). A test runs the real collector
# through this, so a reworded warning fails a test instead of reading as 0.
# ---------------------------------------------------------------------------
bbw_untrusted_count() {
  local file="${1:-}" n total=0
  if [ -r "$file" ]; then
    while IFS= read -r n; do
      total=$(( total + 10#$n ))
    done < <(sed -nE 's/.*ignored ([0-9]{1,9}) quota marker\(s\).*/\1/p' "$file")
  fi
  printf '%s' "$total"
}

# ---------------------------------------------------------------------------
# bbw_valid_org <org> — an organisation login, safe to put in an API path.
# ---------------------------------------------------------------------------
bbw_valid_org() {
  [[ "${1:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]]
}

# ---------------------------------------------------------------------------
# bbw_read_org_vars <org> — read every organisation Actions variable with the
# write credential into BBW_VARS. One listing, so "absent" is certain (a single
# GET cannot tell a missing variable from a credential that may not see it).
# Returns 1 when the call failed (see BBW_HTTP / BBW_ERR), 2 when the answer
# could not be parsed. BBW_VARS is left untouched on failure.
# ---------------------------------------------------------------------------
bbw_read_org_vars() {
  local org="${1:-}" parsed
  _bbw_gh "$_BBW_WRITE_CRED" api --paginate \
    "orgs/${org}/actions/variables?per_page=30" \
    --jq '.variables[] | {name, value, visibility, updated_at}' || return 1
  parsed=$(jq -cs '
    if all(.[]; type == "object" and (.name | type == "string") and (.value | type == "string"))
    then map({key: .name, value: .}) | from_entries
    else error("not a list of variables") end' <<< "$BBW_OUT" 2>/dev/null) || {
    BBW_ERR="the variable listing could not be parsed"
    return 2
  }
  BBW_VARS="$parsed"
}

# ---------------------------------------------------------------------------
# bbw_vars_from_context <paused> <source> <until> — PURE. The same shape as
# BBW_VARS, built from the values the workflow's `vars` context shows (this
# repository's view of the switch). Used when the run may not or cannot read
# the organisation, so it can still say what it would have written. An empty
# value means the variable is not set.
# ---------------------------------------------------------------------------
bbw_vars_from_context() {
  jq -cn --arg p "${1:-}" --arg s "${2:-}" --arg u "${3:-}" \
    --arg np "$BBW_VAR_PAUSED" --arg ns "$BBW_VAR_SOURCE" --arg nu "$BBW_VAR_UNTIL" '
    [ [$np, $p], [$ns, $s], [$nu, $u] ]
    | map(select(.[1] != "") | {key: .[0], value: {name: .[0], value: .[1]}})
    | from_entries'
}

# bbw_var_value <vars_json> <name> — the variable's value, "" when absent.
bbw_var_value() {
  jq -r --arg n "${2:-}" '.[$n].value // ""' <<< "${1:-}" 2>/dev/null || printf ''
}

# bbw_state_key <vars_json> — the three values as one comparable JSON array.
bbw_state_key() {
  jq -c --arg np "$BBW_VAR_PAUSED" --arg ns "$BBW_VAR_SOURCE" --arg nu "$BBW_VAR_UNTIL" \
    '[.[$np].value // null, .[$ns].value // null, .[$nu].value // null]' <<< "${1:-}" 2>/dev/null \
    || printf 'unreadable'
}

# ---------------------------------------------------------------------------
# bbw_hold_remaining <pause_updated_at> <now_epoch> <min_hold_min> — PURE.
# Seconds a resume must still wait: the pause switch has to have stood for the
# minimum hold before the breaker lifts it, so a reset that is minutes away, or
# a reading on the edge, cannot toggle the fleet. Prints 0 when the hold has
# passed OR when any input is unreadable (bad data never keeps the fleet
# paused).
# ---------------------------------------------------------------------------
bbw_hold_remaining() {
  jq -nr --arg at "${1:-}" --arg now "${2:-}" --arg hold "${3:-}" '
    (if ($at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
     then (try ($at | fromdateiso8601) catch null) else null end) as $a
    | (if ($now | test("^[0-9]{1,12}$")) then ($now | tonumber) else null end) as $t
    | (if ($hold | test("^[0-9]{1,6}$")) then ($hold | tonumber) else null end) as $h
    | if $a == null or $t == null or $h == null then 0
      else ([($a + $h * 60 - $t), 0] | max) end' 2>/dev/null || printf '0'
}

# ---------------------------------------------------------------------------
# bbw_time_not_after <iso_time> <now_epoch> — PURE. Returns 0 when the time is a
# well-formed ISO-8601 UTC second that is not later than now, so it can be the
# start of the minimum hold. A missing, malformed or FUTURE time returns 1: a
# hold measured from a time that has not come yet would last until it came,
# however far off, and bad data must never keep the fleet paused.
# ---------------------------------------------------------------------------
bbw_time_not_after() {
  jq -ne --arg at "${1:-}" --arg now "${2:-}" '
    ($at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and ($now | test("^[0-9]{1,12}$"))
    and ((try ($at | fromdateiso8601) catch null) as $a
         | $a != null and $a <= ($now | tonumber))' >/dev/null 2>&1
}

# The plan, as one jq program. The writer re-checks ownership itself rather
# than trusting the decision it is handed: a trip is planned only for a fleet
# that is not paused, and a resume only for a pause carrying the breaker's own
# source. A decision that disagrees with the state yields an error, never a
# write.
# shellcheck disable=SC2016  # jq program: $names are jq variables, not shell
_BBW_PLAN_JQ='
  def iso: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
  def cur($n): $vars[$n].value // null;
  (((cur($np) // "") | ascii_downcase) == "true") as $is_paused
  | (cur($ns) // "") as $src
  | if $d.action == "trip" then
      if $is_paused then error("a trip was decided for a fleet that is already paused")
      elif ($d.until | iso | not) then error("a trip was decided without a readable end time")
      else
        [ {op: "set", name: $ns, value: $own},
          {op: "set", name: $nu, value: $d.until},
          {op: "set", name: $np, value: "true"} ]
        | map(select(cur(.name) != .value))
      end
    elif $d.action == "resume" then
      if ($is_paused | not) then error("a resume was decided for a fleet that is not paused")
      elif $src != $own then error("a resume was decided for a pause this breaker did not set")
      else
        [ {op: "set", name: $np, value: "false"},
          {op: "delete", name: $ns},
          {op: "delete", name: $nu} ]
        | map(select(if .op == "delete" then $vars[.name] != null else cur(.name) != .value end))
      end
    else [] end
'

# ---------------------------------------------------------------------------
# bbw_plan <decision_json> <vars_json> — PURE. Prints the ordered write steps
# as a JSON array of {op: "set", name, value} / {op: "delete", name}; `[]` for
# hold and none, and for a step whose target already holds the wanted state.
# Returns 1 and prints nothing when the decision does not fit the state (see
# above) or cannot be read: the caller must then write nothing.
# ---------------------------------------------------------------------------
bbw_plan() {
  jq -cn --argjson d "${1:-null}" --argjson vars "${2:-null}" \
    --arg own "$BUDGET_BREAKER_PAUSE_SOURCE" \
    --arg np "$BBW_VAR_PAUSED" --arg ns "$BBW_VAR_SOURCE" --arg nu "$BBW_VAR_UNTIL" \
    "$_BBW_PLAN_JQ" 2>/dev/null
}

# ---------------------------------------------------------------------------
# bbw_leftover_plan <vars_json> — PURE. The steps that remove the breaker's
# leftover ownership markers (see the header): `[]` unless the fleet is NOT
# paused AND AGENTS_PAUSE_SOURCE holds exactly the breaker's own value; then
# delete the source, and delete the until when there is one. `[]` too when the
# state cannot be read: unreadable data never causes a write.
# ---------------------------------------------------------------------------
bbw_leftover_plan() {
  local plan
  plan=$(jq -c --arg own "$BUDGET_BREAKER_PAUSE_SOURCE" \
    --arg np "$BBW_VAR_PAUSED" --arg ns "$BBW_VAR_SOURCE" --arg nu "$BBW_VAR_UNTIL" '
    if (((.[$np].value // "") | ascii_downcase) != "true") and ((.[$ns].value // "") == $own)
    then [ {op: "delete", name: $ns} ]
         + (if .[$nu] != null then [ {op: "delete", name: $nu} ] else [] end)
    else [] end' <<< "${1:-}" 2>/dev/null) || plan=""
  printf '%s' "${plan:-[]}"
}

# bbw_plan_text <plan_json> — the plan as one line for a log.
bbw_plan_text() {
  jq -r 'if length == 0 then "nothing"
         else map(if .op == "set" then "\(.name)=\(.value)" else "delete \(.name)" end) | join("; ")
         end' <<< "${1:-[]}" 2>/dev/null || printf 'unreadable plan'
}

# ---------------------------------------------------------------------------
# bbw_create_visibility — the visibility a variable the breaker has to CREATE
# gets: the one the fleet's variables already have, read from the API and never
# guessed. The reference is the first that exists of the pause switch itself,
# then each name in BUDGET_BREAKER_VISIBILITY_REF (default AI_ENGINES, the
# variable every agent repository reads its engine chain from).
# Sets BBW_CREATE_VIS to `all` or `private`. Returns 1 (BBW_ERR says why) when
# no reference exists or it is `selected`: copying a repository selection is a
# choice the maintainer makes once, by creating the variable by hand.
# Sets globals: call it directly, never inside `$(...)`.
# ---------------------------------------------------------------------------
bbw_create_visibility() {
  local name vis ref_names
  BBW_CREATE_VIS=""
  ref_names="${BBW_VAR_PAUSED} ${BUDGET_BREAKER_VISIBILITY_REF:-AI_ENGINES}"
  for name in $ref_names; do
    vis=$(jq -r --arg n "$name" '.[$n].visibility // ""' <<< "$BBW_VARS" 2>/dev/null) || vis=""
    case "$vis" in
      all|private)
        BBW_CREATE_VIS="$vis"
        return 0 ;;
      selected)
        BBW_ERR="the reference variable ${name} is visible to selected repositories only"
        return 1 ;;
    esac
  done
  BBW_ERR="none of the reference variables (${ref_names}) exists in the organisation"
  return 1
}

# ---------------------------------------------------------------------------
# _bbw_delete_var <org> <name> — the one delete call, with the write credential.
# ---------------------------------------------------------------------------
_bbw_delete_var() {
  _bbw_gh "$_BBW_WRITE_CRED" api -X DELETE "orgs/${1:-}/actions/variables/${2:-}"
}

# ---------------------------------------------------------------------------
# _bbw_rollback <org> <vars_json> — take back what the current bbw_apply call
# wrote, after the pause guard refused to set the pause. <vars_json> is the
# state the guard just read, or "" when that read failed.
#
# It only ever DELETES, and only a variable this call wrote that still holds the
# value this call wrote (with no state to compare against, it deletes what this
# call wrote). The source goes first, because the source is what makes a pause
# the breaker's own. Two things are deliberately NOT done:
#   - if deleting the source fails, the until is left alone. A pause that still
#     carries the breaker's source and has no end time is released by the very
#     next run (bb_decide fails open on a missing until); with its end time it
#     stands at least until then, which is the time a maintainer has to act on
#     the error.
#   - if the source was set by an EARLIER run (this call did not write it, so
#     it may not remove it) and is still there, the until this call wrote is
#     left too, for the same reason. BBW_ROLLBACK_OWN_SOURCE reports it.
# Never retries. Returns 1 when a delete failed (BBW_ROLLBACK_FAILED names it).
# ---------------------------------------------------------------------------
_bbw_rollback() {
  local org="${1:-}" vars="${2:-}" cur
  BBW_ROLLED_BACK=()
  BBW_ROLLBACK_KEPT=()
  BBW_ROLLBACK_FAILED=""
  BBW_ROLLBACK_OWN_SOURCE="false"

  if [ -n "$_BBW_WROTE_SOURCE" ]; then
    cur="$_BBW_WROTE_SOURCE"
    if [ -n "$vars" ]; then
      cur="$(bbw_var_value "$vars" "$BBW_VAR_SOURCE")"
    fi
    if [ "$cur" = "$_BBW_WROTE_SOURCE" ]; then
      if ! _bbw_delete_var "$org" "$BBW_VAR_SOURCE"; then
        BBW_ROLLBACK_FAILED="delete ${BBW_VAR_SOURCE}"
        BBW_ROLLBACK_OWN_SOURCE="true"
        return 1
      fi
      BBW_ROLLED_BACK+=("deleted ${BBW_VAR_SOURCE}")
    else
      BBW_ROLLBACK_KEPT+=("${BBW_VAR_SOURCE} (it no longer holds the value this run wrote)")
    fi
  elif [ -z "$vars" ] || [ "$(bbw_var_value "$vars" "$BBW_VAR_SOURCE")" = "$BUDGET_BREAKER_PAUSE_SOURCE" ]; then
    # Not written by this call: a trip skips the source only when it already
    # held the breaker's value, so an earlier run left it.
    BBW_ROLLBACK_OWN_SOURCE="true"
  fi

  if [ -n "$_BBW_WROTE_UNTIL" ]; then
    cur="$_BBW_WROTE_UNTIL"
    if [ -n "$vars" ]; then
      cur="$(bbw_var_value "$vars" "$BBW_VAR_UNTIL")"
    fi
    if [ "$cur" != "$_BBW_WROTE_UNTIL" ]; then
      BBW_ROLLBACK_KEPT+=("${BBW_VAR_UNTIL} (it no longer holds the value this run wrote)")
    elif [ "$BBW_ROLLBACK_OWN_SOURCE" = "true" ]; then
      BBW_ROLLBACK_KEPT+=("${BBW_VAR_UNTIL}=${_BBW_WROTE_UNTIL} (${BBW_VAR_SOURCE}=${BUDGET_BREAKER_PAUSE_SOURCE} from an earlier run is still set, and a pause carrying that source with no end time would be lifted at once)")
    else
      if ! _bbw_delete_var "$org" "$BBW_VAR_UNTIL"; then
        BBW_ROLLBACK_FAILED="delete ${BBW_VAR_UNTIL}"
        return 1
      fi
      BBW_ROLLED_BACK+=("deleted ${BBW_VAR_UNTIL}")
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _bbw_pause_guard <org> <state_key_before_the_writes> — the last look before
# the pause is set (see "The pause guard" in the header). Reads the state again
# into BBW_VARS. Returns 0 only when it is exactly the state bbw_apply started
# from plus what this call wrote: not paused, and the source and until this call
# wrote still in place. Otherwise sets BBW_GUARD, rolls back and returns 1.
# Sets globals: call it directly, never inside `$(...)`.
# ---------------------------------------------------------------------------
_bbw_pause_guard() {
  local org="${1:-}" before="${2:-}" expected="" now_key paused_now rc=0
  BBW_GUARD="" BBW_GUARD_HTTP="" BBW_GUARD_ERR="" BBW_GUARD_STATE=""
  bbw_read_org_vars "$org" || rc=$?
  if [ "$rc" -ne 0 ]; then
    BBW_GUARD="unreadable"
    BBW_GUARD_HTTP="$BBW_HTTP"
    BBW_GUARD_ERR="$BBW_ERR"
    _bbw_rollback "$org" "" || true
    return 1
  fi
  expected=$(jq -c --arg s "$_BBW_WROTE_SOURCE" --arg u "$_BBW_WROTE_UNTIL" '
    if type == "array" and length == 3
    then [.[0], (if $s != "" then $s else .[1] end), (if $u != "" then $u else .[2] end)]
    else error("no state to compare against") end' <<< "$before" 2>/dev/null) || expected=""
  now_key="$(bbw_state_key "$BBW_VARS")"
  BBW_GUARD_STATE="$now_key"
  if [ -n "$expected" ] && [ "$now_key" = "$expected" ]; then
    return 0
  fi
  paused_now="$(bbw_var_value "$BBW_VARS" "$BBW_VAR_PAUSED")"
  if [ "${paused_now,,}" = "true" ]; then
    BBW_GUARD="paused"
  else
    BBW_GUARD="changed"
  fi
  _bbw_rollback "$org" "$BBW_VARS" || true
  return 1
}

# ---------------------------------------------------------------------------
# bbw_apply <org> <plan_json> — carry out the plan in order with the write
# credential, against the state in BBW_VARS. Stops at the FIRST failure and
# never retries. Every step is resolved to its exact call before the first
# write, so a step that cannot be resolved means nothing is written at all.
# Before the step that sets the pause, when this call has written a source or
# an until, the pause guard reads the state again (and leaves it in BBW_VARS).
# Sets BBW_DONE (the steps completed) and, on failure, BBW_FAILED_STEP,
# BBW_FAILED_KIND and BBW_HTTP / BBW_ERR; BBW_FAILED_KIND "guard" means the
# guard stopped the trip and rolled it back (see BBW_GUARD and BBW_ROLLED_BACK).
# Returns 0 only when every step ran.
# ---------------------------------------------------------------------------
bbw_apply() {
  local org="${1:-}" plan="${2:-[]}" n i op name value exists vis="" before
  local -a kinds=() names=() values=()
  BBW_DONE=()
  BBW_FAILED_STEP=""
  BBW_FAILED_KIND="setup"
  BBW_GUARD="" BBW_GUARD_HTTP="" BBW_GUARD_ERR="" BBW_GUARD_STATE=""
  BBW_ROLLED_BACK=()
  BBW_ROLLBACK_KEPT=()
  BBW_ROLLBACK_FAILED=""
  BBW_ROLLBACK_OWN_SOURCE=""
  _BBW_WROTE_SOURCE=""
  _BBW_WROTE_UNTIL=""
  before="$(bbw_state_key "$BBW_VARS")"
  n=$(jq -r 'length' <<< "$plan" 2>/dev/null) || n=""
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    BBW_FAILED_STEP="read the plan"
    BBW_HTTP="" BBW_ERR="the plan is not a JSON array"
    return 1
  fi

  for (( i = 0; i < n; i++ )); do
    op=$(jq -r --argjson i "$i" '.[$i].op' <<< "$plan")
    name=$(jq -r --argjson i "$i" '.[$i].name' <<< "$plan")
    value=$(jq -r --argjson i "$i" '.[$i].value // ""' <<< "$plan")
    case "$name" in
      "$BBW_VAR_PAUSED"|"$BBW_VAR_SOURCE"|"$BBW_VAR_UNTIL") ;;
      *)
        BBW_FAILED_STEP="resolve ${op} ${name}"
        BBW_HTTP="" BBW_ERR="not one of the breaker's three variables"
        return 1 ;;
    esac
    exists=$(jq -r --arg n "$name" 'has($n)' <<< "$BBW_VARS" 2>/dev/null) || exists="false"
    case "$op" in
      set)
        if [ "$exists" = "true" ]; then
          kinds+=("update")
        else
          if [ -z "$vis" ]; then
            BBW_HTTP=""
            if ! bbw_create_visibility; then
              BBW_FAILED_STEP="create ${name}"
              return 1
            fi
            vis="$BBW_CREATE_VIS"
          fi
          kinds+=("create")
        fi ;;
      delete)
        kinds+=("delete") ;;
      *)
        BBW_FAILED_STEP="resolve ${op} ${name}"
        BBW_HTTP="" BBW_ERR="unknown step"
        return 1 ;;
    esac
    names+=("$name")
    values+=("$value")
  done

  BBW_FAILED_KIND="call"
  for (( i = 0; i < n; i++ )); do
    name="${names[$i]}"
    value="${values[$i]}"
    if [ "${kinds[$i]}" != "delete" ] && [ "$name" = "$BBW_VAR_PAUSED" ] && [ "$value" = "true" ] \
        && [ -n "${_BBW_WROTE_SOURCE}${_BBW_WROTE_UNTIL}" ]; then
      if ! _bbw_pause_guard "$org" "$before"; then
        BBW_FAILED_KIND="guard"
        BBW_FAILED_STEP="set ${name}=${value}"
        return 1
      fi
    fi
    case "${kinds[$i]}" in
      update)
        if ! _bbw_gh "$_BBW_WRITE_CRED" api -X PATCH \
            "orgs/${org}/actions/variables/${name}" -f "value=${value}"; then
          BBW_FAILED_STEP="set ${name}=${value}"
          return 1
        fi
        BBW_DONE+=("${name}=${value}") ;;
      create)
        if ! _bbw_gh "$_BBW_WRITE_CRED" api -X POST \
            "orgs/${org}/actions/variables" \
            -f "name=${name}" -f "value=${value}" -f "visibility=${vis}"; then
          BBW_FAILED_STEP="create ${name}=${value}"
          return 1
        fi
        BBW_DONE+=("${name}=${value} (created, visibility ${vis})") ;;
      delete)
        if ! _bbw_delete_var "$org" "$name"; then
          BBW_FAILED_STEP="delete ${name}"
          return 1
        fi
        BBW_DONE+=("deleted ${name}") ;;
    esac
    if [ "${kinds[$i]}" != "delete" ]; then
      case "$name" in
        "$BBW_VAR_SOURCE") _BBW_WROTE_SOURCE="$value" ;;
        "$BBW_VAR_UNTIL")  _BBW_WROTE_UNTIL="$value" ;;
      esac
    fi
  done
  BBW_FAILED_KIND=""
  return 0
}

# ---------------------------------------------------------------------------
# bbw_secret_updated_at <repo> <secret_name> — best effort, READ credential.
# Prints the ISO time the named Actions secret was last updated (the API
# exposes metadata only, never a value). Returns 1 when it cannot be read.
# ---------------------------------------------------------------------------
bbw_secret_updated_at() {
  local repo="${1:-}" name="${2:-}"
  [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$name" =~ ^[A-Za-z0-9_]+$ ]] || return 1
  _bbw_gh "$_BBW_READ_CRED" api "repos/${repo}/actions/secrets/${name}" \
    --jq '.updated_at // empty' || return 1
  [[ "$BBW_OUT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  printf '%s' "$BBW_OUT"
}

# ---------------------------------------------------------------------------
# bbw_find_tracking_issue <repo> — look for the single tracking issue, with the
# notify credential: by label and exact title among the open issues. Sets
# BBW_TRACKING_NUMBER to its number, or to "" when there is none yet. Returns 1
# (BBW_HTTP / BBW_ERR say why) when the issues could not be listed.
# Sets globals: call it directly, never inside `$(...)`.
# ---------------------------------------------------------------------------
bbw_find_tracking_issue() {
  local repo="${1:-}" number=""
  BBW_TRACKING_NUMBER=""
  if ! _bbw_gh "$_BBW_NOTIFY_CRED" issue list --repo "$repo" --state open \
      --label "$BBW_TRACKING_LABEL" --limit 100 --json number,title; then
    return 1
  fi
  number=$(jq -r --arg t "$BBW_TRACKING_TITLE" \
    '[.[] | select(.title == $t) | .number] | min // empty' <<< "$BBW_OUT" 2>/dev/null) || number=""
  if [[ "$number" =~ ^[0-9]+$ ]]; then
    BBW_TRACKING_NUMBER="$number"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# bbw_pause_marker <until> — PURE. The hidden first line of every notice that
# announces a pause. It carries the pause's end time, which identifies the pause
# (the script keeps nothing between runs), so a later run can tell from the
# tracking issue alone whether this pause was announced.
# ---------------------------------------------------------------------------
bbw_pause_marker() {
  printf '<!-- budget-breaker-notice kind=pause until=%s -->' "${1:-}"
}

# ---------------------------------------------------------------------------
# bbw_notice_lookup_due <pause_updated_at> <now_epoch> — PURE. Whether a run
# that holds an own pause should look for that pause's notice. Returns 0 while
# the pause switch was set less than BBW_NOTICE_CATCHUP_MIN minutes ago, and
# also when that time cannot be read (looking costs two read calls; not looking
# could leave a pause unannounced). Returns 1 for an older pause: the look-up is
# for the runs right after a trip whose notice failed, not for every tick of a
# pause that can last hours.
# ---------------------------------------------------------------------------
bbw_notice_lookup_due() {
  local at="${1:-}" now="${2:-}"
  bbw_time_not_after "$at" "$now" || return 0
  jq -ne --arg at "$at" --arg now "$now" --arg win "$BBW_NOTICE_CATCHUP_MIN" \
    '(($now | tonumber) - ($at | fromdateiso8601)) < (($win | tonumber) * 60)' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# bbw_pause_notice_posted <repo> <until> — READ ONLY, notify credential. Is
# there a comment on the tracking issue carrying the marker of the pause that
# ends at <until>? Returns 0 when there is, 1 when there is not (no tracking
# issue yet counts as not), 2 when it cannot be told (BBW_HTTP / BBW_ERR).
# Any comment carrying the marker counts, whoever wrote it: a forged marker can
# only stop a late notice from being posted, it can never cause a write.
# Sets globals: call it directly, never inside `$(...)`.
# ---------------------------------------------------------------------------
bbw_pause_notice_posted() {
  local repo="${1:-}" until="${2:-}" marker count
  if ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ \
      && "$until" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    BBW_HTTP="" BBW_ERR="the repository or the pause's end time is not readable"
    return 2
  fi
  bbw_find_tracking_issue "$repo" || return 2
  [ -n "$BBW_TRACKING_NUMBER" ] || return 1
  # The marker is digits, letters, `-`, `:`, `=`, `<`, `!` and `>` only (the end
  # time was just checked), so it is safe inside the filter's string literal.
  # With --paginate the filter runs once per page: one count per page.
  marker="$(bbw_pause_marker "$until")"
  _bbw_gh "$_BBW_NOTIFY_CRED" api --paginate \
    "repos/${repo}/issues/${BBW_TRACKING_NUMBER}/comments?per_page=100" \
    --jq "[.[] | select((.body // \"\") | contains(\"${marker}\"))] | length" || return 2
  count=$(jq -rs 'if all(.[]; type == "number") then add // 0 else error("not counts") end' \
    <<< "$BBW_OUT" 2>/dev/null) || count=""
  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    BBW_HTTP="" BBW_ERR="the tracking issue's comments could not be parsed"
    return 2
  fi
  [ "$count" -gt 0 ]
}

# ---------------------------------------------------------------------------
# bbw_notify <repo> <body> — post ONE comment on the single tracking issue,
# with the notify credential. The issue is found by label and exact title among
# the open issues and created on first use, labelled so dev-lead ignores it.
# Returns 1 (BBW_ERR says why) when the notice could not be posted.
# ---------------------------------------------------------------------------
bbw_notify() {
  local repo="${1:-}" body="${2:-}" number=""
  bbw_find_tracking_issue "$repo" || return 1
  number="$BBW_TRACKING_NUMBER"

  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    # First use. The labels may already exist; creating them again fails
    # harmlessly, and a label that is truly missing fails the create below.
    _bbw_gh "$_BBW_NOTIFY_CRED" label create "$BBW_TRACKING_LABEL" --repo "$repo" \
      --color "5319e7" --description "Budget breaker notices (#2153)" || true
    _bbw_gh "$_BBW_NOTIFY_CRED" label create "$BBW_HANDS_OFF_LABEL" --repo "$repo" \
      --color "d4c5f9" --description "dev-lead must not act on this item" || true
    if ! _bbw_gh "$_BBW_NOTIFY_CRED" issue create --repo "$repo" \
        --title "$BBW_TRACKING_TITLE" \
        --label "$BBW_TRACKING_LABEL" --label "$BBW_HANDS_OFF_LABEL" \
        --body "$(bbw_tracking_issue_body)"; then
      return 1
    fi
    number="${BBW_OUT##*/}"
    if ! [[ "$number" =~ ^[0-9]+$ ]]; then
      BBW_ERR="the tracking issue was created but its number could not be read"
      return 1
    fi
  fi

  _bbw_gh "$_BBW_NOTIFY_CRED" issue comment "$number" --repo "$repo" --body "$body" || return 1
  BBW_OUT="$number"
}

# bbw_tracking_issue_body — the standing text of the tracking issue.
bbw_tracking_issue_body() {
  cat << 'BODY'
The budget breaker (`.github/workflows/budget-breaker.yml`, #2153) posts one comment here each time it pauses the agent fleet and one each time it lifts that pause.

It pauses the fleet when the fleet itself reports that the model provider is refusing work for quota, by setting the organisation Actions variables `AGENTS_PAUSED=true`, `AGENTS_PAUSE_SOURCE=rate-limit-observed` and `AGENTS_PAUSE_UNTIL`. It only ever lifts a pause that carries its own source.

- To keep the fleet paused by hand: set `AGENTS_PAUSED=true` and delete `AGENTS_PAUSE_SOURCE`. The breaker never touches a pause without its own source.
- To end a breaker pause early: set `AGENTS_PAUSED=false` and delete `AGENTS_PAUSE_SOURCE`.
- To switch the breaker off: set the repository variable `BUDGET_BREAKER_ARMED` to `false`, or delete it. Only the exact lowercase value `true` arms it.

See AGENTS.md, "Pausing the agent fleet". Keep this issue open; it is labelled so that dev-lead ignores it.
BODY
}
