# shellcheck shell=bash
# scripts/lib/budget-poller.sh — Helpers for the DRY-RUN budget poller (#2029,
# slice 2 of #1565).
#
# The poller (scripts/budget_poller.sh) reads the Claude usage windows through
# scripts/lib/usage-telemetry.sh, evaluates the SHIPPED public gates
# (`arl_token_budget_gate`, `arl_token_weekly_glide_gate`), and appends one JSONL
# record per run to a durable log. This library owns the record shape, the burn
# rate, the liveness line, and the fleet-monitor view of that log.
#
# DRY-RUN ONLY: nothing here (or in the poller) writes, sets, or clears any
# Actions variable. The record says what the breaker WOULD do; acting on it is
# out of scope until the maintainer signs off on arming (#1565).
#
# ----------------------------------------------------------------------------
# Record (one JSON object per line in the log):
#   ts, epoch                  — poll time (UTC ISO-8601, epoch seconds)
#   poll                       — "ok" | "degraded"
#   reason                     — degraded cause (transport-error | http-<s> |
#                                malformed-body | public-library-unavailable |
#                                telemetry-publish-failed | weekly-glide-arm-failed),
#                                else null
#   http_status, retry_after   — from the envelope (never the token)
#   session_pct, weekly_all_pct, session_resets_at, weekly_all_resets_at
#                              — via the public library's own extractors
#   session_decision           — arl_token_budget_gate session (allow|defer|unavailable)
#   weekly_glide_decision      — arl_token_weekly_glide_gate against an ARMED temp
#                                copy of the public config (allow|defer|unavailable)
#   weekly_glide_config_enabled — the real public config arm (production: false)
#   would_pause, decision_window, decision_pct — the legible dry-run outcome
#   burn_session_pph, burn_weekly_all_pph, burn_basis — percentage points per hour
#                                vs the previous OK record (logged only, no gate)
#   trigger_event, trigger_cron — what started the run ($GITHUB_EVENT_NAME and
#                                the cron that fired, github.event.schedule), else null
#   scheduled_for, scheduled_epoch, start_delay_s
#                              — the slot an hourly `M * * * *` cron was meant to run
#                                for (the latest :M at or before the poll) and the
#                                poll's delay past it; null for any other cron (#2160)
#   error_type, error_detail   — on a non-200 only (#2179): the upstream
#                                `.error.type` (allow-listed) and its redacted,
#                                control-stripped, 200-char `.error.message`;
#                                else null. Never the whole body.
#   dry_run                    — always true
#   line                       — the greppable liveness / degraded line
#
# Liveness lines (greppable, mutually exclusive prefixes):
#   telemetry read OK, session=N% weekly_all=M%
#   telemetry read DEGRADED, status=S reason=R
#
# Sourced (`# shellcheck source=scripts/lib/budget-poller.sh`); at source time it
# only sources scripts/lib/redact.sh (definitions only) and calls `set` on nothing.

# Resolved at source time: a caller may run by a relative path and cd later (#2152).
# shellcheck source=scripts/lib/redact.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)/redact.sh" 2>/dev/null || true

# Hours after the last OK record before the fleet monitor warns (AC #4). 6, not
# 3: GitHub delivers only ~40% of scheduled ticks in this repo, so a 3h gap is
# routine (#2160). The weekly window moves slowly, and a stale record fails open.
BUDGET_POLLER_STALE_HOURS_DEFAULT=6

# Scheduled runs a day the workflow asks for: two hourly cron slots (:17, :47).
BUDGET_POLLER_EXPECTED_RUNS_PER_DAY=48

# Artifact name the workflow uploads and the fleet monitor reads.
BUDGET_POLLER_ARTIFACT="${BUDGET_POLLER_ARTIFACT:-budget-poller-log}"

bp_log() { printf 'budget-poller: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# bp_now — epoch seconds, honoring $BUDGET_POLLER_NOW (testability).
# ---------------------------------------------------------------------------
bp_now() {
  if [[ -n "${BUDGET_POLLER_NOW:-}" ]]; then
    printf '%s' "$BUDGET_POLLER_NOW"
    return 0
  fi
  date +%s
}

# ---------------------------------------------------------------------------
# bp_stale_hours — the configured staleness window ($BUDGET_POLLER_STALE_HOURS),
# falling back to the default on an unset / non-positive-integer value.
# ---------------------------------------------------------------------------
bp_stale_hours() {
  local v="${BUDGET_POLLER_STALE_HOURS:-}"
  if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ]; then
    printf '%s' "$((10#$v))"
  else
    printf '%s' "$BUDGET_POLLER_STALE_HOURS_DEFAULT"
  fi
}

# ---------------------------------------------------------------------------
# bp_gate <fn> [args...] — run a public gate and echo just its decision token
# (allow|defer). A gate returns 1 on defer; neutralized so a `set -e` caller is
# never aborted. Anything unrecognized degrades to "allow" (the library's own
# fail-safe direction).
# ---------------------------------------------------------------------------
bp_gate() {
  local out
  out="$("$@" 2>/dev/null)" || true
  case "$out" in
    *decision=defer*) printf 'defer' ;;
    *) printf 'allow' ;;
  esac
}

# ---------------------------------------------------------------------------
# bp_last_ok <log_file> — echo the most recent record with poll=="ok", or empty.
# Tolerates a missing file and malformed lines.
# ---------------------------------------------------------------------------
bp_last_ok() {
  local log="${1:-}"
  [[ -n "$log" ]] && [[ -s "$log" ]] || return 0
  jq -cR 'fromjson? | select(type == "object" and .poll == "ok")' "$log" 2>/dev/null | tail -n 1 || true
}

# ---------------------------------------------------------------------------
# bp_last_record <log_file> — echo the most recent parseable record, or empty.
# ---------------------------------------------------------------------------
bp_last_record() {
  local log="${1:-}"
  [[ -n "$log" ]] && [[ -s "$log" ]] || return 0
  jq -cR 'fromjson? | select(type == "object")' "$log" 2>/dev/null | tail -n 1 || true
}

# ---------------------------------------------------------------------------
# bp_error_fields <http_status> <upstream_body> — echo
# {"error_type":…,"error_detail":…} for a refused read (#2179), from the body
# the adapter already carries. Both null on a 200, a missing / non-JSON body, no
# `.error` object, or an `.error.type` outside ^[a-z_]{1,48}$. error_detail is
# `.error.message` with control characters stripped, passed through
# redact_secrets (before AND after the newlines go, so neither a multi-line PEM
# block nor a token split across lines survives), and cut to 200 characters;
# null when redaction is unavailable. Never fails and never prints the body.
# ---------------------------------------------------------------------------
bp_error_fields() {
  local http="${1:-}" body="${2:-}" etype="" msg="" out
  local nulls='{"error_type":null,"error_detail":null}'
  if [[ "$http" = "200" ]] || [[ -z "$body" ]]; then
    printf '%s' "$nulls"
    return 0
  fi
  etype="$(jq -r 'if type == "object" and (.error | type) == "object"
      and (.error.type | type) == "string" and (.error.type | test("^[a-z_]{1,48}$"))
    then .error.type else empty end' <<<"$body" 2>/dev/null)" || etype=""
  if ! [[ "$etype" =~ ^[a-z_]{1,48}$ ]]; then
    printf '%s' "$nulls"
    return 0
  fi
  if declare -F redact_secrets >/dev/null; then
    # Keep only \n for the first pass (redact_secrets' PEM range is line-based).
    msg="$(jq -r '.error?.message | if type == "string"
        then gsub("[\u0000-\u0009\u000b-\u001f\u007f-\u009f]"; "") else empty end' \
        <<<"$body" 2>/dev/null | redact_secrets 2>/dev/null | { tr -d '\n'; echo; } | redact_secrets 2>/dev/null)" || msg=""
  fi
  out="$(jq -cn --arg t "$etype" --arg m "$msg" '
    ($m | gsub("[\u0000-\u001f\u007f-\u009f]"; "") | .[0:200]) as $d
    | {error_type: $t, error_detail: (if $d == "" then null else $d end)}' 2>/dev/null)" || out=""
  if [[ -n "$out" ]] && jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then
    printf '%s' "$out"
  else
    printf '%s' "$nulls"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# bp_build_record — PURE. Assemble the JSON record. Named args via env-free
# positional order:
#   1 now_epoch  2 http_status  3 retry_after  4 session_pct  5 weekly_pct
#   6 session_resets_at  7 weekly_resets_at  8 session_decision
#   9 glide_decision  10 glide_config_enabled  11 reason_override  12 prev_ok_record
#   13 trigger_event  14 trigger_cron  (optional, #2160)
#   15 upstream_body (the envelope's `.body`, read only by bp_error_fields)
# Empty strings mean "absent" (null in the record).
# ---------------------------------------------------------------------------
bp_build_record() {
  local now="$1" http="$2" retry="$3" s_pct="$4" w_pct="$5" s_reset="$6" w_reset="$7"
  local s_dec="$8" g_dec="$9" g_enabled="${10}" reason_override="${11}" prev="${12:-}"
  local t_event="${13:-}" t_cron="${14:-}"
  local err
  err="$(bp_error_fields "$http" "${15:-}")"
  [[ -n "$prev" ]] && jq -e 'type == "object"' <<<"$prev" >/dev/null 2>&1 || prev='null'
  # A malformed clock must not abort the record (`--argjson` would fail under set -e).
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"

  jq -cn \
    --argjson now "$now" \
    --arg http "$http" --arg retry "$retry" \
    --arg s_pct "$s_pct" --arg w_pct "$w_pct" \
    --arg s_reset "$s_reset" --arg w_reset "$w_reset" \
    --arg s_dec "$s_dec" --arg g_dec "$g_dec" \
    --arg g_enabled "$g_enabled" --arg reason_override "$reason_override" \
    --arg t_event "$t_event" --arg t_cron "$t_cron" \
    --argjson prev "$prev" --argjson err "$err" '
    def num($s): if ($s | test("^[0-9]+$")) then ($s | tonumber) else null end;
    def str($s): if $s == "" then null else $s end;
    # Burn rate (pp/h) for one window vs the previous OK record. Null on the
    # first poll, a missing side, a window that reset in between (resets_at
    # moved or percent fell), or a non-positive interval.
    def burn($cur; $cur_reset; $pk; $rk):
      if $prev == null or $cur == null or ($prev[$pk] | type) != "number" then null
      elif ($prev.epoch | type) != "number" or $now <= $prev.epoch then null
      elif ($prev[$rk] != null and $cur_reset != null and $prev[$rk] != $cur_reset) then null
      elif $cur < $prev[$pk] then null
      else ((($cur - $prev[$pk]) / (($now - $prev.epoch) / 3600)) * 100 | round) / 100
      end;
    # The slot an hourly "M * * * *" cron was meant to run for: the latest :M at
    # or before $now. A delay over an hour aliases onto a later slot, so it is
    # a lower bound. Empty (null at the call site) for any other cron shape.
    def scheduled($cron):
      ($cron | capture("^(?<m>[0-9]{1,2}) \\* \\* \\* \\*$")? | .m | tonumber) as $m
      | select($m <= 59)
      | ($now - ($now % 3600) + $m * 60) as $s
      | if $s > $now then $s - 3600 else $s end;

    (num($http) // 0) as $status
    | num($s_pct) as $sp | num($w_pct) as $wp
    | str($s_reset) as $sr | str($w_reset) as $wr
    | ( if $reason_override != "" then $reason_override
        elif $status == 0 then "transport-error"
        elif $status != 200 then "http-\($status)"
        elif $sp == null or $wp == null or $wr == null then "malformed-body"
        else null end ) as $reason
    | (if $reason == null then "ok" else "degraded" end) as $poll
    | ( [ (if $s_dec == "defer" then "session" else empty end),
          (if $g_dec == "defer" then "weekly_all" else empty end) ] ) as $tripped
    | ( if ($tripped | length) == 0 then "none"
        elif $status == 429 then "transport-429"
        else ($tripped | join(",")) end ) as $window
    | ( if $window == "session" then $sp
        elif $window == "weekly_all" then $wp
        elif $window == "session,weekly_all" then ([$sp, $wp] | max)
        else null end ) as $dpct
    | burn($sp; $sr; "session_pct"; "session_resets_at") as $bs
    | burn($wp; $wr; "weekly_all_pct"; "weekly_all_resets_at") as $bw
    | (scheduled($t_cron) // null) as $sched
    | {
        ts: ($now | todate),
        epoch: $now,
        poll: $poll,
        reason: $reason,
        http_status: $status,
        retry_after: num($retry),
        session_pct: $sp,
        weekly_all_pct: $wp,
        session_resets_at: $sr,
        weekly_all_resets_at: $wr,
        session_decision: $s_dec,
        weekly_glide_decision: $g_dec,
        weekly_glide_config_enabled: ($g_enabled == "true"),
        would_pause: (($tripped | length) > 0),
        indeterminate: (($tripped | length) == 0 and ($s_dec == "unavailable" or $g_dec == "unavailable")),
        decision_window: $window,
        decision_pct: $dpct,
        burn_session_pph: $bs,
        burn_weekly_all_pph: $bw,
        burn_basis: (if $prev == null then "first-poll" else "previous-record" end),
        trigger_event: str($t_event),
        trigger_cron: str($t_cron),
        scheduled_for: (if $sched == null then null else ($sched | todate) end),
        scheduled_epoch: $sched,
        start_delay_s: (if $sched == null then null else $now - $sched end),
        error_type: $err.error_type,
        error_detail: $err.error_detail,
        dry_run: true,
        line: ( if $poll == "ok"
                then "telemetry read OK, session=\($sp)% weekly_all=\($wp)%"
                else "telemetry read DEGRADED, status=\($status) reason=\($reason)"
                  + (if num($retry) != null then " retry_after=\($retry)" else "" end)
                end )
      }'
}

# ---------------------------------------------------------------------------
# bp_decision_text <record> — echo the human-legible dry-run outcome, e.g.
#   "would pause on `weekly_all` at 90% (dry-run — nothing was set)"
#   "would allow (session=33%, weekly_all=50%)"
# ---------------------------------------------------------------------------
bp_decision_text() {
  jq -r '
    def pct($v): if $v == null then "n/a" else "\($v)%" end;
    if .would_pause == true then
      "would pause on `\(.decision_window)`"
      + (if .decision_pct != null then " at \(.decision_pct)%" else "" end)
      + " (dry-run — nothing was set)"
    elif .indeterminate == true then
      "indeterminate — a gate was unavailable (session=\(.session_decision // "n/a"), weekly_glide=\(.weekly_glide_decision // "n/a")); nothing was set"
    else
      "would allow (session=\(pct(.session_pct)), weekly_all=\(pct(.weekly_all_pct)))"
    end' <<<"$1" 2>/dev/null || printf 'unknown'
}

# ---------------------------------------------------------------------------
# bp_append_record <log_file> <record> [max_records] — append and keep only the
# newest <max_records> lines (default 720 ≈ 15 days at two slots an hour).
# ---------------------------------------------------------------------------
bp_append_record() {
  local log="$1" record="$2" max="${3:-720}" tmp
  [[ "$max" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ] || max=720
  # Fail-open: a write failure warns and returns 0 rather than aborting a `set -e` caller.
  printf '%s\n' "$record" >> "$log" || { bp_log "warning: failed to append the poll record to ${log}"; return 0; }
  tmp="$(mktemp "${log}.XXXXXX")" || { bp_log "warning: failed to create temp file for log pruning"; return 0; }
  if tail -n "$max" "$log" > "$tmp"; then
    mv -f "$tmp" "$log" || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# ---------------------------------------------------------------------------
# bp_age_text <seconds> — "Xh Ym".
# ---------------------------------------------------------------------------
bp_age_text() {
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  printf '%dh %dm' "$((s / 3600))" "$(((s % 3600) / 60))"
}

# ---------------------------------------------------------------------------
# bp_staleness <log_file> <now_epoch> — echo "never" | "fresh <age_s>" |
# "stale <age_s>" for the last OK record against the staleness window.
# ---------------------------------------------------------------------------
bp_staleness() {
  local log="$1" now="$2" last epoch age
  last="$(bp_last_ok "$log")"
  epoch="$(jq -r '.epoch // empty' <<<"${last:-null}" 2>/dev/null || printf '')"
  if ! [[ "$epoch" =~ ^[0-9]+$ ]]; then
    printf 'never'
    return 0
  fi
  age=$((now - epoch))
  [ "$age" -lt 0 ] && age=0
  if [ "$age" -gt "$(( $(bp_stale_hours) * 3600 ))" ]; then
    printf 'stale %s' "$age"
  else
    printf 'fresh %s' "$age"
  fi
}

# ---------------------------------------------------------------------------
# bp_staleness_warning <log_file> <now_epoch> — echo a `::warning::` annotation
# when there is no OK record or it is older than the staleness window; echo
# nothing when fresh. Never fails.
# ---------------------------------------------------------------------------
bp_staleness_warning() {
  local log="$1" now="$2" state hours
  state="$(bp_staleness "$log" "$now")"
  hours="$(bp_stale_hours)"
  case "$state" in
    never)
      printf '::warning::budget-poller: no OK telemetry record found — the dry-run budget poller has not proven it is alive (staleness window %sh)\n' "$hours"
      ;;
    stale\ *)
      printf '::warning::budget-poller: last OK telemetry read is %s old — stale (> %sh staleness window)\n' \
        "$(bp_age_text "${state#stale }")" "$hours"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# bp_fleet_section <log_file> <now_epoch> — markdown block for the fleet-monitor
# report: last OK age (STALE flag past the window), scheduled delivery over the
# last 24h, the latest record's line and HTTP status, the dry-run decision
# (window + percent), and the burn rate.
# ---------------------------------------------------------------------------
bp_fleet_section() {
  local log="$1" now="$2" state hours latest
  state="$(bp_staleness "$log" "$now")"
  hours="$(bp_stale_hours)"
  latest="$(bp_last_record "$log")"

  printf '## Budget poller (dry-run)\n\n'
  printf '_Dry-run only (#2029): logs what the token-budget breaker would do; never sets or clears any variable._\n\n'
  case "$state" in
    never)
      printf -- '- **Last OK telemetry read:** ⚠️ no OK record found (staleness window %sh)\n' "$hours"
      ;;
    stale\ *)
      printf -- '- **Last OK telemetry read:** ⚠️ STALE — %s ago (> %sh window)\n' \
        "$(bp_age_text "${state#stale }")" "$hours"
      ;;
    fresh\ *)
      printf -- '- **Last OK telemetry read:** %s ago (within %sh window)\n' \
        "$(bp_age_text "${state#fresh }")" "$hours"
      ;;
  esac
  bp_delivery_line "$log" "$now"
  if [[ -n "$latest" ]]; then
    jq -r '"- **Latest record:** `\(.line // "n/a")` (HTTP status \(.http_status // "n/a"), \(.ts // "n/a"))"' \
      <<<"$latest" 2>/dev/null || true
    printf -- '- **Dry-run decision:** %s\n' "$(bp_decision_text "$latest")"
    jq -r '
      def r($v): if $v == null then "n/a" else "\($v) pp/h" end;
      "- **Burn rate:** session \(r(.burn_session_pph)), weekly_all \(r(.burn_weekly_all_pph))"' \
      <<<"$latest" 2>/dev/null || true
  fi
  return 0
}

# ---------------------------------------------------------------------------
# bp_delivery_line <log_file> <now_epoch> — markdown bullet: runs received in
# the 24h before <now_epoch> (every record, OK or degraded, is one run) against
# $BUDGET_POLLER_EXPECTED_RUNS_PER_DAY, plus the median start delay of those
# records that carry one (#2160). Older records without the field still count.
# ---------------------------------------------------------------------------
bp_delivery_line() {
  local log="$1" now="$2"
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  { [[ -n "$log" ]] && [[ -s "$log" ]] && cat "$log"; } 2>/dev/null \
    | jq -rRs --argjson now "$now" --argjson exp "$BUDGET_POLLER_EXPECTED_RUNS_PER_DAY" '
      [ split("\n")[] | fromjson? | select(type == "object" and (.epoch | type) == "number"
          and .epoch > ($now - 86400) and .epoch <= $now) ] as $r
      | ($r | length) as $n
      | ([ $r[].start_delay_s | select(type == "number") ] | sort) as $d
      | "- **Scheduled delivery (last 24h):** \($n) of \($exp) expected runs received"
        + " (\(($n * 100 / $exp) | floor)%)"
        + (if ($d | length) > 0
           then "; median start delay \(((if ($d | length) % 2 == 0 then ($d[(($d | length) / 2 | floor) - 1] + $d[($d | length) / 2 | floor]) / 2 else $d[($d | length) / 2 | floor] end) / 60) | floor)m"
           else "" end)' 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# bp_download_latest_log <repo> <dest_file> — fetch the newest unexpired
# `$BUDGET_POLLER_ARTIFACT` artifact from <repo> (read-only `gh api`) and write
# its JSONL log to <dest_file>. Only artifacts produced by runs on the repo's
# default branch are trusted (any other run could otherwise plant a same-named
# artifact). Returns 0 on success, 1 when none is available (first-ever poll or
# expired), 2 on an API error — callers treat 1 as "no previous log" and must NOT
# overwrite the durable log on 2 (the history still exists, it just was not read).
# ---------------------------------------------------------------------------
bp_download_latest_log() {
  local repo="$1" dest="$2" ids id workdir found branch
  branch="$(gh api "repos/${repo}" --jq '.default_branch' 2>/dev/null || printf '')"
  # `gh --jq` takes no --arg, so the branch is interpolated: allow-list its charset.
  [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || branch="main"
  # --paginate: other branches' runs can fill a single page and hide an older
  # trusted log. The API lists newest first, so per-page filtering keeps that order.
  ids="$(gh api --paginate "repos/${repo}/actions/artifacts?name=${BUDGET_POLLER_ARTIFACT}&per_page=100" \
    --jq "[.artifacts[] | select(.expired == false and .workflow_run.head_branch == \"${branch}\")] | sort_by(.created_at) | reverse | .[].id" \
    2>/dev/null)" || return 2
  # Newest first; fall through to older artifacts when one is unreadable/malformed.
  for id in $ids; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    workdir="$(mktemp -d)" || return 1
    found=""
    if gh api "repos/${repo}/actions/artifacts/${id}/zip" > "$workdir/log.zip" 2>/dev/null \
      && unzip -q -o "$workdir/log.zip" -d "$workdir/out" >/dev/null 2>&1; then
      found="$(find "$workdir/out" -type f -name '*.jsonl' -print | head -n 1)"
    fi
    if [[ -n "$found" ]] && [[ -s "$found" ]] && jq -e . "$found" >/dev/null 2>&1; then
      cp "$found" "$dest"
      rm -rf "$workdir"
      return 0
    fi
    rm -rf "$workdir"
  done
  return 1
}
