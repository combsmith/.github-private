# shellcheck shell=bash
# scripts/lib/gemini-quota.sh — Gemini quota self-metering + per-key cooldown memory (#2030).
#
# Gemini reports no remaining quota we can rely on, so this library meters it from
# the fleet's OWN token ledger (TOKEN_LOG_FILE, written by emit_token_record) against
# the maintainer-supplied caps in gemini-quota-caps.tsv. Nothing here makes a
# network call, reads a key value, or hard-codes a provider limit.
#
# Keys are identified by INDEX only: 1 = the primary slot (GEMINI_API_KEY /
# GOOGLE_API_KEY), N = GOOGLE_API_KEY_N. A key value never reaches a log, a record,
# or stdout.
#
# Fail direction (deliberately the opposite of the Claude probe's fail-open):
# unknown limits, a missing caps row, or an unreadable/corrupt ledger make a key
# "unknown" — the caller treats it as CONSTRAINED, never as healthy.
#
# Cooldown memory rides the SAME Token Observatory JSONL channel as the usage it
# meters: a kind:"gemini_key_cooldown" record {key_index, model, until} in the
# ledger. Cost reports keep only kind "token_usage", so these records never price.
#
# Sourced (no side effects at source time). Environment (all optional):
#   GEMINI_QUOTA_CAPS   — caps file (default: gemini-quota-caps.tsv alongside this lib)
#   GEMINI_LEDGER_FILE  — ledger to meter (default: TOKEN_LOG_FILE)
#   GEMINI_QUOTA_NOW    — epoch override for the clock (tests)
#   GEMINI_HISTORY_DAYS — previous days the per-day history shows (default: caps
#                         setting history_days, else 7)
#
# Slice 2 (#2041) adds, on the same ledger: forward-looking remaining capacity per
# (key index, model) (gq_remaining), the per-task-tier view built on
# ai_models_gemini_chain (gq_tier_view / gq_tier_snapshot), the per-reset-day history
# (gq_day_history), kind:"gemini_attempt" records for rejected calls (they count as
# requests), redacted kind:"gemini_rejection_sample" records, and the escalating
# cooldown (gq_escalated_cooldown).

_GQ_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${GEMINI_QUOTA_CAPS:-}" ]; then
  GEMINI_QUOTA_CAPS="$_GQ_LIB_DIR/gemini-quota-caps.tsv"
fi

# Window lengths are definitions of "per minute" / "per day", not provider limits.
_GQ_MINUTE=60
_GQ_DAY=86400

# gq_now — current epoch seconds, honouring GEMINI_QUOTA_NOW.
gq_now() {
  if [[ "${GEMINI_QUOTA_NOW:-}" =~ ^[0-9]+$ ]]; then
    printf '%s' "$GEMINI_QUOTA_NOW"
  else
    date +%s
  fi
}

# gq_ledger_file — the ledger path being metered (empty when none is configured).
gq_ledger_file() {
  printf '%s' "${GEMINI_LEDGER_FILE:-${TOKEN_LOG_FILE:-}}"
}

# gq_setting <name> — value of a `setting` row in the caps file (empty when absent).
gq_setting() {
  [ -f "$GEMINI_QUOTA_CAPS" ] || return 0
  awk -F'\t' -v n="$1" '$1 == "setting" && $2 == n { print $3; exit }' "$GEMINI_QUOTA_CAPS"
}

# gq_key_index <VAR_NAME> — the key index for a Gemini key variable name.
gq_key_index() {
  case "${1:-}" in
    GEMINI_API_KEY) printf '1' ;;
    # A GOOGLE_API_KEY holding a different credential than GEMINI_API_KEY is its own
    # key: it gets its own index so cooldowns and ledger usage are not merged.
    GOOGLE_API_KEY)
      if [ -n "${GEMINI_API_KEY:-}" ] && [ "${GOOGLE_API_KEY:-}" != "$GEMINI_API_KEY" ]; then
        printf '1b'
      else
        printf '1'
      fi ;;
    GOOGLE_API_KEY_[0-9]*)         printf '%s' "${1#GOOGLE_API_KEY_}" ;;
    *)                             return 1 ;;
  esac
}

# gq_caps_row_for <key_index> <model> — "glob\ttier\trpm\ttpm\trpd" of the most
# specific caps row whose glob matches <model> (most literal characters), or nothing.
gq_caps_row_for() {
  [ -f "$GEMINI_QUOTA_CAPS" ] || return 0
  awk -F'\t' -v idx="$1" -v model="$2" '
    function glob2re(g,   re) {
      re = g
      gsub(/[.[\]()^$+{}|\\]/, "\\\\&", re)
      gsub(/\*/, ".*", re)
      gsub(/\?/, ".", re)
      return "^" re "$"
    }
    /^[[:space:]]*#/ || NF < 6 || $1 != idx { next }
    model ~ glob2re($2) {
      lit = $2; gsub(/[*?]/, "", lit)
      if (!found || length(lit) > best) { best = length(lit); out = $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6; found = 1 }
    }
    END { if (found) print out }' "$GEMINI_QUOTA_CAPS"
}

# gq_caps_for <key_index> <model> — "tier\trpm\ttpm\trpd" of the most specific caps
# row whose glob matches <model> (most literal characters), or nothing.
gq_caps_for() {
  local row
  row="$(gq_caps_row_for "$1" "$2")"
  [ -z "$row" ] || printf '%s\n' "${row#*$'\t'}"
}

# gq_cap_key_indexes — the key indexes that have caps rows, in file order (the tier
# view's default key set: the fleet monitor holds no key, so it meters by index).
gq_cap_key_indexes() {
  [ -f "$GEMINI_QUOTA_CAPS" ] || return 0
  awk -F'\t' '/^[[:space:]]*#/ || NF < 6 || $1 == "setting" { next }
    !seen[$1]++ { print $1 }' "$GEMINI_QUOTA_CAPS"
}

# gq_default_cooldown_sec — the configured default cooldown. The last-resort value
# when the setting is missing/invalid is one requests-per-minute window.
gq_default_cooldown_sec() {
  local v; v="$(gq_setting default_cooldown_sec)"
  if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ]; then
    printf '%s' "$v"
  else
    printf '%s' "$_GQ_MINUTE"
  fi
}

# gq_day_window — "<start>\t<end>\t<rolling>" of the current requests/day window.
# With a configured reset (daily_reset_time / daily_reset_tz) the window runs from the
# most recent reset to the next one, by local calendar day (so a DST change day is
# 23h or 25h, never a fixed 86400s) and rolling is 0. With the reset unknown it is a
# rolling 24h ending now — which counts at least as many calls as any real reset
# window, so it errs constrained — and end is "none", rolling 1.
gq_day_window() {
  local now t tz d r n
  now="$(gq_now)"
  t="$(gq_setting daily_reset_time)"
  tz="$(gq_setting daily_reset_tz)"
  if [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && [ -n "$tz" ] && [ "$tz" != "unknown" ]; then
    if d="$(TZ="$tz" date -d "@$now" +%Y-%m-%d 2>/dev/null)" \
       && r="$(TZ="$tz" date -d "$d $t" +%s 2>/dev/null)" && [[ "$r" =~ ^[0-9]+$ ]]; then
      if [ "$r" -gt "$now" ]; then
        # Previous local calendar day (not now-86400: DST days are 23/25h).
        n="$r"
        d="$(TZ="$tz" date -d "$d -1 day" +%Y-%m-%d 2>/dev/null)" \
          && r="$(TZ="$tz" date -d "$d $t" +%s 2>/dev/null)" && [[ "$r" =~ ^[0-9]+$ ]] \
          || r=""
      else
        n="$(TZ="$tz" date -d "$(TZ="$tz" date -d "$d +1 day" +%Y-%m-%d 2>/dev/null) $t" +%s 2>/dev/null)" \
          && [[ "$n" =~ ^[0-9]+$ ]] || n=""
      fi
      if [ -n "$r" ] && [ -n "$n" ]; then
        printf '%s\t%s\t0\n' "$r" "$n"
        return 0
      fi
    fi
  fi
  printf '%s\tnone\t1\n' $(( now - _GQ_DAY ))
}

# gq_day_start — epoch where the current requests/day window began (gq_day_window).
gq_day_start() {
  local w; w="$(gq_day_window)"
  printf '%s' "${w%%$'\t'*}"
}

# gq_next_reset — epoch of the next daily reset; with the reset unknown, one rolling
# day from now (the longest a per-day rejection can still apply).
gq_next_reset() {
  local s e r
  IFS=$'\t' read -r s e r <<< "$(gq_day_window)"
  if [ "$r" = "0" ]; then printf '%s' "$e"; else printf '%s' $(( $(gq_now) + _GQ_DAY )); fi
}

# _gq_day_label <epoch> — the reset-timezone calendar date of <epoch> (UTC when the
# reset is not configured).
_gq_day_label() {
  local tz; tz="$(gq_setting daily_reset_tz)"
  { [ -n "$tz" ] && [ "$tz" != "unknown" ] && TZ="$tz" date -d "@$1" +%Y-%m-%d 2>/dev/null; } \
    || date -u -d "@$1" +%Y-%m-%d
}

# gq_day_bounds <n> — "<label>\t<start>\t<end>" for the current reset window and the
# <n> previous ones, newest first (labels are the reset-timezone date the window
# starts on). Rolling 24h windows are labelled rolling-0, rolling-1, …
gq_day_bounds() {
  local n="${1:-7}" s e r t tz d d0 k st en prev
  [[ "$n" =~ ^[0-9]+$ ]] || n=7
  IFS=$'\t' read -r s e r <<< "$(gq_day_window)"
  if [ "$r" != "0" ]; then
    e="$(gq_now)"
    for (( k = 0; k <= n; k++ )); do
      printf 'rolling-%s\t%s\t%s\n' "$k" $(( e - (k + 1) * _GQ_DAY )) $(( e - k * _GQ_DAY ))
    done
    return 0
  fi
  t="$(gq_setting daily_reset_time)"; tz="$(gq_setting daily_reset_tz)"
  d0="$(TZ="$tz" date -d "@$s" +%Y-%m-%d)"
  printf '%s\t%s\t%s\n' "$d0" "$s" "$e"
  prev="$s"
  for (( k = 1; k <= n; k++ )); do
    d="$(TZ="$tz" date -d "$d0 -$k day" +%Y-%m-%d 2>/dev/null)" || break
    st="$(TZ="$tz" date -d "$d $t" +%s 2>/dev/null)" || break
    en="$prev"
    printf '%s\t%s\t%s\n' "$d" "$st" "$en"
    prev="$st"
  done
}

# gq_ledger_rows <key_index> <since_epoch>
# Prints "<epoch>\t<model>\t<tokens>" for every gemini token_usage record of the key
# at/after since_epoch (tokens = input + cache-read + output), and for every
# kind:"gemini_attempt" record (a call Google rejected — it still counts against the
# request limits, #2041) with tokens 0. Returns 1 and prints a
# one-line reason (and nothing else) when the ledger cannot be trusted: none
# configured, not readable, or any malformed line. A configured ledger file that does
# not exist yet is an EMPTY ledger (a run's ledger is created by its first record).
gq_ledger_rows() {
  local idx="$1" since="$2" f out
  f="$(gq_ledger_file)"
  if [ -z "$f" ]; then
    printf 'no ledger configured — TOKEN_LOG_FILE unset'
    return 1
  fi
  [ -e "$f" ] || return 0
  if [ ! -r "$f" ] || [ -d "$f" ]; then
    printf 'ledger file is not readable'
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { printf 'jq unavailable'; return 1; }
  out="$(jq -R -s -r --arg k "$idx" --argjson since "$since" '
      [ split("\n")[] | select(test("\\S")) | (try fromjson catch "__bad__") ] as $recs
      | ($recs | map(select(. == "__bad__")) | length) as $badjson
      | ($recs | map(select(type == "object"
            and ((.kind // "token_usage") | IN("token_usage", "gemini_attempt")) and .engine == "gemini"
            and ((.key_index // "" | tostring) == $k)
            and ( ((.ts // "") | try fromdateiso8601 catch null) == null
                  or ((.kind // "token_usage") == "token_usage"
                      and ([.input_tokens, .cache_read_tokens, .output_tokens]
                           | any(. != null and type != "number"))) )))
          | length) as $badrec
      | ($badjson + $badrec) as $bad
      | if $bad > 0 then "BAD\t\($bad)"
        else
          $recs[] | select(type == "object")
          | (.kind // "token_usage") as $kind
          | select(($kind == "token_usage" or $kind == "gemini_attempt") and .engine == "gemini")
          | select((.key_index // "" | tostring) == $k)
          | ((.ts // "") | try fromdateiso8601 catch null) as $e
          | select($e != null and $e >= $since)
          | [ $e, (.model // ""),
              (if $kind == "gemini_attempt" then 0
               else ((.input_tokens // 0) + (.cache_read_tokens // 0) + (.output_tokens // 0)) end) ]
          | @tsv
        end' "$f" 2>/dev/null)" || { printf 'ledger could not be parsed'; return 1; }
  if [[ "$out" == BAD$'\t'* ]]; then
    printf 'ledger has %s malformed line(s)' "${out#BAD$'\t'}"
    return 1
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

# gq_key_pct <key_index> [model]
# Prints the key's usage as an integer percent of its tightest cap — the max over
# its caps rows (all rows, or only rows whose glob matches <model>) and over the
# rpm / tpm / rpd windows. Prints "unknown<TAB><reason>" instead when there is no
# matching row or any matching row has an `unknown` (or invalid) limit (reason
# "limits"), or the ledger is unreadable (reason "ledger: <why>").
gq_key_pct() {
  local idx="$1" model="${2:-}" now day since rows
  now="$(gq_now)"
  day="$(gq_day_start)"
  since=$(( now - _GQ_MINUTE ))
  [ "$day" -lt "$since" ] && since="$day"
  if ! rows="$(gq_ledger_rows "$idx" "$since")"; then
    printf 'unknown\tledger: %s' "$rows"
    return 0
  fi
  local result
  # The "#ledger" sentinel keeps the first input non-empty so FNR == NR is exact.
  result="$(printf '#ledger\n%s\n' "$rows" | awk -F'\t' -v idx="$idx" -v model="$model" \
      -v minute_start=$(( now - _GQ_MINUTE )) -v day="$day" '
    function glob2re(g,   re) {
      re = g
      gsub(/[.[\]()^$+{}|\\]/, "\\\\&", re)
      gsub(/\*/, ".*", re)
      gsub(/\?/, ".", re)
      return "^" re "$"
    }
    # pct_of <cap> <used> — -1 = unknown/invalid, -2 = no cap on this window.
    function pct_of(cap, used) {
      if (cap == "none") return -2
      if (cap !~ /^[0-9]+$/) return -1
      if (cap + 0 == 0) return 100
      return int(used * 100 / cap)
    }
    FNR == NR { if (NF >= 3) { n++; ce[n] = $1; cm[n] = $2; ct[n] = $3 }; next }
    /^[[:space:]]*#/ || NF < 6 || $1 != idx { next }
    {
      re = glob2re($2)
      if (model != "" && model !~ re) next
      rows++
      r1 = 0; t1 = 0; rd = 0
      for (i = 1; i <= n; i++) if (cm[i] ~ re) {
        if (ce[i] >= minute_start) { r1++; t1 += ct[i] }
        if (ce[i] >= day) rd++
      }
      split(pct_of($4, r1) " " pct_of($5, t1) " " pct_of($6, rd), p, " ")
      for (j = 1; j <= 3; j++) {
        if (p[j] == -1) unknown = 1
        else if (p[j] > best) best = p[j]
      }
    }
    END { if (rows == 0 || unknown) print "unknown"; else print best + 0 }
  ' - "$GEMINI_QUOTA_CAPS" 2>/dev/null)"
  if [ -z "$result" ] || [ "$result" = "unknown" ]; then
    printf 'unknown\tlimits'
    return 0
  fi
  printf '%s' "$result"
}

# gq_engine_headroom <threshold> <key_index>...
# Engine-level verdict over the configured keys. Prints one '|'-separated line ('|',
# not TAB: `read` would collapse an empty middle field between two tabs):
#   ok|<pct>                           — some key has measured headroom (pct = best key)
#   over|<pct>                         — every key is metered and at/above threshold
#   unknown|<limits_keys>|<ledger_why> — no key with measured headroom and at least
#                                        one key is unknown (comma-separated indexes
#                                        with unknown limits; ledger reason, if any)
gq_engine_headroom() {
  local threshold="$1"; shift
  local idx pct best="" unknown_keys="" ledger_why=""
  for idx in "$@"; do
    pct="$(gq_key_pct "$idx")"
    if [[ "$pct" == unknown* ]]; then
      case "${pct#unknown$'\t'}" in
        "ledger: "*) ledger_why="${pct#unknown$'\t'ledger: }" ;;
        *)           unknown_keys="${unknown_keys:+$unknown_keys,}$idx" ;;
      esac
      continue
    fi
    if [ -z "$best" ] || [ "$pct" -lt "$best" ]; then best="$pct"; fi
  done
  if [ -n "$best" ] && [ "$best" -lt "$threshold" ]; then
    printf 'ok|%s\n' "$best"
  elif [ -z "$unknown_keys" ] && [ -z "$ledger_why" ] && [ -n "$best" ]; then
    printf 'over|%s\n' "$best"
  else
    printf 'unknown|%s|%s\n' "$unknown_keys" "$ledger_why"
  fi
}

# gq_record_cooldown <key_index> <model> <seconds> <reason>
# Appends a kind:"gemini_key_cooldown" record (deadline = now + seconds) to the
# ledger. No-op when no ledger is configured; never fails the caller.
gq_record_cooldown() {
  local idx="$1" model="$2" secs="$3" reason="${4:-}" f now
  f="$(gq_ledger_file)"
  [ -n "$f" ] || return 0
  [[ "$secs" =~ ^[0-9]+$ ]] || secs="$(gq_default_cooldown_sec)"
  now="$(gq_now)"
  jq -cn --arg ts "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" \
    --arg workflow "${TOKEN_WORKFLOW:-unknown}" --arg run_id "${GITHUB_RUN_ID:-}" \
    --arg k "$idx" --arg model "$model" --argjson until $(( now + 10#$secs )) --arg reason "$reason" \
    '{ kind: "gemini_key_cooldown", ts: $ts, workflow: $workflow, engine: "gemini",
       key_index: ($k | tonumber? // $k), model: $model, until: $until,
       reason: $reason, run_id: $run_id }' 2>/dev/null >> "$f" || true
}

# gq_cooldown_until <key_index> <model>
# Prints the latest still-active cooldown deadline (epoch) for the key on <model>,
# or nothing. An unreadable ledger reads as "no cooldown" — the headroom gate already
# treats every key as constrained in that case.
gq_cooldown_until() {
  local idx="$1" model="$2" f now
  f="$(gq_ledger_file)"
  [ -n "$f" ] && [ -r "$f" ] && [ -f "$f" ] || return 0
  now="$(gq_now)"
  jq -R -r --arg k "$idx" --arg m "$model" --argjson now "$now" '
      try fromjson catch empty
      | select(type == "object" and .kind == "gemini_key_cooldown")
      | select((.key_index | tostring) == $k and .model == $m)
      | .until | numbers | select(. > $now)' "$f" 2>/dev/null \
    | sort -n | tail -1
}

# gq_retry_hint_sec <file>... — seconds the provider asked us to wait (rounded up),
# from a google.rpc.RetryInfo `retryDelay` or "retry in/after Ns" text. Prints
# nothing when no hint is present.
gq_retry_hint_sec() {
  local files=() f hint
  for f in "$@"; do [ -n "$f" ] && [ -f "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -gt 0 ] || return 0
  hint="$(grep -ohiE 'retryDelay"?[[:space:]]*:[[:space:]]*"?[0-9]+(\.[0-9]+)?s|retry[ -](in|after):?[[:space:]]*[0-9]+(\.[0-9]+)?' \
    "${files[@]}" 2>/dev/null | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)" || true
  [ -n "$hint" ] || return 0
  awk -v h="$hint" 'BEGIN { s = int(h); if (h > s) s++; print s }'
}

# gq_rotation_plan <model> <threshold> <VAR_NAME>...
# Orders the configured keys for one model. Prints, one per line:
#   cool\t<VAR_NAME>\t<index>\t<until_epoch>  — skip: cooling down on this model
#   skip\t<VAR_NAME>\t<index>\t<reason>       — dropped, NOT called (#2041): the key
#                                              cannot run this model today — cap 0
#                                              (`unavailable`) or the daily cap is
#                                              used up (`exhausted`, until the reset)
#                                              or the rolling minute is full (`cooling`)
#   use\t<VAR_NAME>\t<index>                  — try, in this order: keys with measured
#                                              headroom first, then constrained ones
#                                              (unknown limits / at-or-above threshold)
# `unknown` keys are never dropped: an unfilled caps file must not become a hard block.
gq_rotation_plan() {
  local model="$1" threshold="$2"; shift 2
  local name idx until pct now st sut first="" mid="" last="" _dep=", ${GEMINI_DEPLETED_KEYS:-}, "
  now="$(gq_now)"
  for name in "$@"; do
    idx="$(gq_key_index "$name")" || continue
    until="$(gq_cooldown_until "$idx" "$model")"
    if [ -n "$until" ] && [ "$until" -gt "$now" ]; then
      printf 'cool\t%s\t%s\t%s\n' "$name" "$idx" "$until"
      continue
    fi
    IFS=$'\t' read -r st sut <<< "$(gq_remaining "$idx" "$model" \
      | jq -r '[.state, (.until // "" | tostring)] | @tsv' 2>/dev/null)"
    case "$st" in
      unavailable)
        printf 'skip\t%s\t%s\t%s\n' "$name" "$idx" "unavailable (cap 0 for this model)"
        continue ;;
      exhausted)
        if [[ "$sut" =~ ^[0-9]+$ ]]; then
          sut="resets $(date -u -d "@$sut" +%Y-%m-%dT%H:%MZ 2>/dev/null || printf '%s' "$sut")"
        else
          sut="rolling 24h window"
        fi
        printf 'skip\t%s\t%s\t%s\n' "$name" "$idx" "exhausted (daily cap reached; $sut)"
        continue ;;
      cooling)
        if [[ "$sut" =~ ^[0-9]+$ ]]; then
          sut="resets $(date -u -d "@$sut" +%Y-%m-%dT%H:%MZ 2>/dev/null || printf '%s' "$sut")"
        else
          sut="until next window"
        fi
        printf 'skip\t%s\t%s\t%s\n' "$name" "$idx" "cooling down (${sut})"
        continue ;;
    esac
    pct="$(gq_key_pct "$idx" "$model")"
    if [[ "$_dep" == *", ${name}, "* ]]; then
      # Billing-depleted keys stay last resort whatever their measured headroom (#1777).
      last="${last}use"$'\t'"${name}"$'\t'"${idx}"$'\n'
    elif [[ "$pct" =~ ^[0-9]+$ ]] && [ "$pct" -lt "$threshold" ]; then
      first="${first}use"$'\t'"${name}"$'\t'"${idx}"$'\n'
    else
      mid="${mid}use"$'\t'"${name}"$'\t'"${idx}"$'\n'
    fi
  done
  printf '%s%s%s' "$first" "$mid" "$last"
}

# ── Slice 2 (#2041): remaining capacity, attempts, escalation ─────────────────

# _gq_num_or_null <value> — the value when it is a non-negative integer, else null.
_gq_num_or_null() {
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then printf '%s' $(( 10#$1 )); else printf 'null'; fi
}

# gq_remaining <key_index> <model>
# Forward-looking capacity of one (key index, model) for the CURRENT windows: the
# day window from the last reset to the next (gq_day_window), and the rolling
# minute. Pure: reads the caps file, the ledger and the clock; no network. Prints
# one compact JSON object:
#   {key_index, model, state, reason, remaining_calls, remaining:{rpd,rpm,tpm},
#    used:{rpd,rpm,tpm}, caps:{tier,rpm,tpm,rpd}, until, day_start, day_end}
# state, first match wins:
#   unavailable — some cap of the matching row is 0 (the model never runs on the key)
#   unknown     — no caps row, a limit not filled, or the ledger unreadable
#   exhausted   — requests today (successes + rejected attempts) at or above the
#                 daily cap; until = the next reset
#   cooling     — an active cooldown record, or the rolling minute is full (rpm/tpm);
#                 until = when it ends
#   available   — remaining_calls = requests left today (null: no daily cap)
# Remaining values are never negative; null means no cap on that window (or unknown).
gq_remaining() {
  local idx="$1" model="$2" now ds de rolling row="" glob="" tier="unknown"
  local rpm="unknown" tpm="unknown" rpd="unknown" state="" reason="" until="null"
  local rows r1=0 t1=0 rd=0 oldest="" since cd c
  now="$(gq_now)"
  IFS=$'\t' read -r ds de rolling <<< "$(gq_day_window)"
  row="$(gq_caps_row_for "$idx" "$model")"
  [ -z "$row" ] || IFS=$'\t' read -r glob tier rpm tpm rpd <<< "$row"
  since=$(( now - _GQ_MINUTE )); [ "$ds" -lt "$since" ] && since="$ds"
  if rows="$(gq_ledger_rows "$idx" "$since")"; then
    read -r r1 t1 rd oldest <<< "$(printf '#ledger\n%s\n' "$rows" | awk -F'\t' \
        -v glob="${glob:-$model}" -v minute_start=$(( now - _GQ_MINUTE )) -v day="$ds" '
      function glob2re(g,   re) {
        re = g
        gsub(/[.[\]()^$+{}|\\]/, "\\\\&", re)
        gsub(/\*/, ".*", re)
        gsub(/\?/, ".", re)
        return "^" re "$"
      }
      BEGIN { re = glob2re(glob); oldest = "" }
      NR == 1 || NF < 3 || $2 !~ re { next }
      {
        if ($1 >= minute_start) { r1++; t1 += $3; if (oldest == "" || $1 < oldest) oldest = $1 }
        if ($1 >= day) rd++
      }
      END { printf "%d %d %d %s\n", r1, t1, rd, (oldest == "" ? "-" : oldest) }')"
  else
    state="unknown"; reason="ledger: $rows"
  fi
  if [ -z "$row" ]; then
    state="unknown"; reason="no caps row for this key and model"
  else
    for c in "$rpm" "$tpm" "$rpd"; do
      if [[ "$c" =~ ^[0-9]+$ ]] && [ $(( 10#$c )) -eq 0 ]; then
        state="unavailable"; reason="cap 0"
      fi
    done
    if [ "$state" != "unavailable" ]; then
      for c in "$rpm" "$tpm" "$rpd"; do
        if [ "$c" != "none" ] && ! [[ "$c" =~ ^[0-9]+$ ]]; then
          state="unknown"; reason="limits not filled"
        fi
      done
    fi
  fi
  if [ -z "$state" ]; then
    if [[ "$rpd" =~ ^[0-9]+$ ]] && [ "$rd" -ge $(( 10#$rpd )) ]; then
      state="exhausted"; reason="daily cap reached"
      [ "$rolling" = "0" ] && until="$de"
    else
      cd="$(gq_cooldown_until "$idx" "$model")"
      if [ -n "$cd" ]; then
        state="cooling"; reason="cooldown after a rejection"; until="$cd"
      elif { [[ "$rpm" =~ ^[0-9]+$ ]] && [ "$r1" -ge $(( 10#$rpm )) ]; } \
           || { [[ "$tpm" =~ ^[0-9]+$ ]] && [ "$t1" -ge $(( 10#$tpm )) ]; }; then
        state="cooling"; reason="per-minute cap reached"
        [ "$oldest" != "-" ] && until=$(( oldest + _GQ_MINUTE ))
      else
        state="available"
      fi
    fi
  fi
  jq -cn --arg k "$idx" --arg m "$model" --arg state "$state" --arg reason "$reason" \
    --arg tier "${tier:-unknown}" --arg crpm "${rpm:-unknown}" --arg ctpm "${tpm:-unknown}" --arg crpd "${rpd:-unknown}" \
    --argjson rpm "$(_gq_num_or_null "$rpm")" --argjson tpm "$(_gq_num_or_null "$tpm")" \
    --argjson rpd "$(_gq_num_or_null "$rpd")" \
    --argjson ur "$r1" --argjson ut "$t1" --argjson ud "$rd" --argjson until "$until" \
    --argjson ds "$ds" --argjson de "$( [ "$rolling" = "0" ] && printf '%s' "$de" || printf 'null')" '
    def left($cap; $used): if $cap == null then null elif $cap > $used then $cap - $used else 0 end;
    { key_index: $k, model: $m, state: $state, reason: $reason,
      remaining: (if $state == "unknown" then { rpd: null, rpm: null, tpm: null }
                  else { rpd: left($rpd; $ud), rpm: left($rpm; $ur), tpm: left($tpm; $ut) } end),
      used: { rpd: $ud, rpm: $ur, tpm: $ut },
      caps: { tier: $tier, rpm: $crpm, tpm: $ctpm, rpd: $crpd },
      until: $until, day_start: $ds, day_end: $de }
    | .remaining_calls = (if $state == "unknown" then null
                          elif $state == "unavailable" or $state == "exhausted" then 0
                          else .remaining.rpd end)'
}

# gq_record_attempt <key_index> <model>
# Appends a kind:"gemini_attempt" record (rejected:true) for a call Google rejected
# as rate-limited / quota-exceeded, so the per-window counts include the attempts
# Google counts. Index only: no key value, no response body. No-op without a ledger.
gq_record_attempt() {
  local idx="$1" model="$2" f now
  f="$(gq_ledger_file)"
  [ -n "$f" ] || return 0
  now="$(gq_now)"
  jq -cn --arg ts "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" \
    --arg workflow "${TOKEN_WORKFLOW:-unknown}" --arg run_id "${GITHUB_RUN_ID:-}" \
    --arg k "$idx" --arg model "$model" \
    '{ kind: "gemini_attempt", ts: $ts, workflow: $workflow, engine: "gemini",
       key_index: ($k | tonumber? // $k), model: $model, rejected: true,
       run_id: $run_id }' 2>/dev/null >> "$f" || true
}

# _gq_redact_line <text> — one line, safe to publish: every configured Gemini key
# value replaced, common credential formats scrubbed (redact_secrets), control
# characters dropped, cut to 300 characters.
_gq_redact_line() {
  local s="$1" n v
  for n in GEMINI_API_KEY GOOGLE_API_KEY $(compgen -v GOOGLE_API_KEY_ 2>/dev/null); do
    v="${!n:-}"
    [ "${#v}" -ge 4 ] && s="${s//"$v"/[REDACTED-KEY]}"
  done
  if ! declare -F redact_secrets >/dev/null 2>&1 && [ -f "$_GQ_LIB_DIR/redact.sh" ]; then
    # shellcheck source=scripts/lib/redact.sh
    source "$_GQ_LIB_DIR/redact.sh"
  fi
  if declare -F redact_secrets >/dev/null 2>&1; then
    s="$(printf '%s\n' "$s" | redact_secrets | head -1)"
  else
    s="$(printf '%s\n' "$s" | sed -E 's/AIza[A-Za-z0-9_-]{35}/***REDACTED-GOOGLE-KEY***/g' | head -1)"
  fi
  s="$(printf '%s' "$s" | tr -d '\000-\010\013-\037\177')"
  printf '%s' "${s:0:300}"
}

# gq_rejection_scope <file>... — "daily" when the rejection text carries Google's
# documented daily-quota wording (`quota_exceeded`, "daily quota"), else "minute".
# No error-body format is relied on: anything else is treated as per-minute and left
# to the escalation (gq_escalated_cooldown) and the ledger-derived daily-cap rule.
gq_rejection_scope() {
  local files=() f
  for f in "$@"; do [ -n "$f" ] && [ -f "$f" ] && files+=("$f"); done
  if [ "${#files[@]}" -gt 0 ] && grep -qiE 'quota_exceeded|daily quota' "${files[@]}" 2>/dev/null; then
    printf 'daily'
  else
    printf 'minute'
  fi
}

# gq_is_quota_rejection <file>... — 0 (true) when the rejection is a genuine quota/rate-limit
# from Google (429, RESOURCE_EXHAUSTED, quota_exceeded, too many requests, rate limit),
# excluding payment (402) or request-size errors (413). Returns 1 if the error is something else.
gq_is_quota_rejection() {
  local files=() f
  for f in "$@"; do [ -n "$f" ] && [ -f "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -gt 0 ] || return 1
  grep -qiE '([^0-9]|^)429([^0-9]|$)|resource.?exhausted|quota_exceeded|too many requests|rate.?limit|quotaexceeded|resets [0-9]+(am|pm)' "${files[@]}" 2>/dev/null
}

# gq_record_rejection_sample <key_index> <model> <scope> <file>...
# Appends one kind:"gemini_rejection_sample" record — the first rejection line of the
# captured output, redacted (_gq_redact_line) — unless the ledger already holds a
# sample with the same normalised text (digits folded), so the report shows each
# DISTINCT message Google sent once. No-op without a ledger or a matching line.
gq_record_rejection_sample() {
  local idx="$1" model="$2" scope="$3"; shift 3
  local f files=() line norm now
  f="$(gq_ledger_file)"
  [ -n "$f" ] || return 0
  for line in "$@"; do [ -n "$line" ] && [ -f "$line" ] && files+=("$line"); done
  [ "${#files[@]}" -gt 0 ] || return 0
  line="$(grep -hiE '429|resource.?exhausted|quota|rate.?limit|too many requests' "${files[@]}" 2>/dev/null \
    | head -1)" || true
  [ -n "$line" ] || return 0
  line="$(_gq_redact_line "$line")"
  norm="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]' | sed -E 's/[0-9]+(\.[0-9]+)?/#/g; s/[[:space:]]+/ /g')"
  if [ -f "$f" ] && jq -R -e --arg n "$norm" 'try fromjson catch empty
       | select(type == "object" and .kind == "gemini_rejection_sample" and .norm == $n)' \
       "$f" >/dev/null 2>&1; then
    return 0
  fi
  now="$(gq_now)"
  jq -cn --arg ts "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" \
    --arg workflow "${TOKEN_WORKFLOW:-unknown}" --arg run_id "${GITHUB_RUN_ID:-}" \
    --arg k "$idx" --arg model "$model" --arg scope "$scope" --arg sample "$line" --arg norm "$norm" \
    '{ kind: "gemini_rejection_sample", ts: $ts, workflow: $workflow, engine: "gemini",
       key_index: ($k | tonumber? // $k), model: $model, scope: $scope,
       sample: $sample, norm: $norm, run_id: $run_id }' 2>/dev/null >> "$f" || true
}

# gq_escalated_cooldown <key_index> <model> <base_sec> <base_source> [scope]
# The cooldown for a rejection about to be recorded, as "<seconds>\t<source>":
#   - scope "daily" (gq_rejection_scope), or the ledger ALREADY shows today's
#     requests at/above the daily cap → straight to the next reset;
#   - otherwise <base_sec> (retry hint, else default) doubled for every earlier
#     consecutive rejection of the same key and model — rejected attempts since the
#     last success of that key/model within the current day window (a success, or
#     the daily reset, restarts the streak) — capped at the next daily reset.
# Call it BEFORE gq_record_attempt for the rejection it prices.
gq_escalated_cooldown() {
  local idx="$1" model="$2" base="$3" src="${4:-default}" scope="${5:-minute}"
  local now next cap ds de rolling streak=0 secs i f rem used crpd
  now="$(gq_now)"
  next="$(gq_next_reset)"
  cap=$(( next - now )); [ "$cap" -ge 1 ] || cap=1
  [[ "$base" =~ ^[0-9]+$ ]] && [ "$base" -gt 0 ] || base="$(gq_default_cooldown_sec)"
  if [ "$scope" = "daily" ]; then
    printf '%s\t%s\n' "$cap" "daily quota wording → next reset"
    return 0
  fi
  rem="$(gq_remaining "$idx" "$model")"
  IFS=$'\t' read -r used crpd <<< "$(jq -r '[.used.rpd, .caps.rpd] | @tsv' <<< "$rem" 2>/dev/null)"
  if [[ "$crpd" =~ ^[0-9]+$ ]] && [[ "$used" =~ ^[0-9]+$ ]] && [ "$used" -ge $(( 10#$crpd )) ]; then
    printf '%s\t%s\n' "$cap" "daily cap reached in the ledger → next reset"
    return 0
  fi
  IFS=$'\t' read -r ds de rolling <<< "$(gq_day_window)"
  f="$(gq_ledger_file)"
  if [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ]; then
    streak="$(jq -R -s -r --arg k "$idx" --arg m "$model" --argjson ds "$ds" '
        [ split("\n")[] | select(test("\\S")) | (try fromjson catch empty)
          | select(type == "object" and .engine == "gemini" and .model == $m
                   and ((.key_index // "" | tostring) == $k))
          | ((.ts // "") | try fromdateiso8601 catch null) as $e | select($e != null)
          | { e: $e, k: (.kind // "token_usage") } ] as $r
        | ([ $r[] | select(.k == "token_usage") | .e ] | max // 0) as $last
        | [ $r[] | select(.k == "gemini_attempt" and .e > $last and .e >= $ds) ] | length' \
        "$f" 2>/dev/null)" || streak=0
    [[ "$streak" =~ ^[0-9]+$ ]] || streak=0
  fi
  secs="$base"
  for (( i = 0; i < streak && secs < cap; i++ )); do secs=$(( secs * 2 )); done
  [ "$secs" -le "$cap" ] || secs="$cap"
  if [ "$streak" -gt 0 ]; then
    printf '%s\t%s\n' "$secs" "$src, doubled ×$streak (consecutive rejections)"
  else
    printf '%s\t%s\n' "$secs" "$src"
  fi
}

# ── Slice 2 (#2041): per-task-tier view, snapshot, notices, history ───────────

# _gq_ensure_models — make ai_models_gemini_chain available (engine-models.sh is the
# single source of every tier's Gemini chain; nothing here repeats a chain).
_gq_ensure_models() {
  declare -F ai_models_gemini_chain >/dev/null 2>&1 && return 0
  # shellcheck source=scripts/lib/engine-models.sh
  [ -f "$_GQ_LIB_DIR/engine-models.sh" ] && source "$_GQ_LIB_DIR/engine-models.sh"
  declare -F ai_models_gemini_chain >/dev/null 2>&1
}

# gq_tier_list — the task tiers, space-separated (the keys engine-models.sh defines).
gq_tier_list() {
  _gq_ensure_models || return 0
  if declare -F _ai_models_keys >/dev/null 2>&1; then
    _ai_models_keys gemini
  fi
}

# _gq_pairs_jsonl <models_csv> <key_index>... — one gq_remaining object per line for
# every (model, key index) pair, models in the given order.
_gq_pairs_jsonl() {
  local mcsv="$1" m idx; shift
  local -a ms=()
  IFS=',' read -r -a ms <<< "$mcsv"
  for m in ${ms[@]+"${ms[@]}"}; do
    [ -n "$m" ] || continue
    for idx in "$@"; do gq_remaining "$idx" "$m"; done
  done
}

# _gq_tier_from_pairs <tier> <chain_csv> <pairs_file> — the tier object from
# precomputed pairs (see gq_tier_view for the fields).
_gq_tier_from_pairs() {
  jq -c -s --arg tier "$1" --arg chain "$2" '
    ($chain | split(",") | map(select(length > 0))) as $c
    | [ .[] | select(.model as $m | any($c[]; . == $m)) ] as $p
    | def states($m): [ $p[] | select(.model == $m) | .state ];
      ( [ range(0; $c | length) as $i | $c[$i] as $m | states($m) as $s
          | if any($s[]; . == "available") then { i: $i, k: "ok", m: $m }
            elif ($s | length) == 0 or any($s[]; . == "unknown") then { i: $i, k: "unknown", m: $m }
            else empty end ] | first // { k: "none" } ) as $r
    | [ $p[] | select(.state == "available") ] as $u
    | ( if ($c | length) == 0 or $r.k == "unknown" then "unknown"
        elif $r.k == "ok" then (if $r.i == 0 then "available" else "degraded" end)
        else "unavailable" end ) as $status
    | { tier: $tier, status: $status, chain: $c, first_choice: ($c[0] // null),
        serving_model: (if $r.k == "ok" then $r.m else null end),
        degraded_to: (if $status == "degraded" then $r.m else null end),
        usable: [ $u[] | { model, key_index, remaining_calls } ],
        remaining_calls: (if $status == "unknown" then null
                          elif ($u | length) == 0 then 0
                          elif any($u[]; .remaining_calls == null) then null
                          else ($u | map(.remaining_calls) | add) end),
        recovers_at: (if $status == "unavailable"
                      then ([ $p[] | .until | numbers ] | min) else null end),
        pairs: $p }' "$3"
}

# gq_tier_view <tier> [key_index...]
# Whether <tier>'s Gemini work can run now. The chain is ai_models_gemini_chain
# <tier>; keys default to every index in the caps file. Prints one JSON object:
#   {tier, status, chain, first_choice, serving_model, degraded_to, usable:[{model,
#    key_index, remaining_calls}], remaining_calls, recovers_at, pairs:[gq_remaining…]}
# status — walking the chain in order, the first model that has an `available` key
# decides: the first model → available, a later one → degraded (degraded_to names it:
# a quality change). A model with an `unknown` key (or no keys) before that → unknown.
# No model with a usable key → unavailable (recovers_at = earliest cooldown / reset).
# remaining_calls sums the usable pairs (null: unknown, or a usable pair has no
# daily cap).
gq_tier_view() {
  local tier="$1"; shift
  local chain pf out
  _gq_ensure_models || { printf '{"tier":"%s","status":"unknown","chain":[]}\n' "$tier"; return 0; }
  chain="$(ai_models_gemini_chain "$tier")"
  if [ "$#" -eq 0 ]; then
    local -a _ks=()
    mapfile -t _ks < <(gq_cap_key_indexes)
    set -- ${_ks[@]+"${_ks[@]}"}
  fi
  pf="$(mktemp)" || return 1
  _gq_pairs_jsonl "$chain" "$@" > "$pf"
  out="$(_gq_tier_from_pairs "$tier" "$chain" "$pf")"
  rm -f "$pf"
  printf '%s\n' "$out"
}

# gq_tier_snapshot [key_index...]
# The machine-readable snapshot (schema: gemini-tier-snapshot.schema.json): one
# gq_tier_view object per tier, plus the timestamp and the window boundaries used.
# Each (model, key) pair is metered once and shared across tiers. Indexes only —
# never a key value.
gq_tier_snapshot() {
  local now ds de rolling t tiers=() chains=() all="" pf tf i c label
  now="$(gq_now)"
  IFS=$'\t' read -r ds de rolling <<< "$(gq_day_window)"
  if [ "$#" -eq 0 ]; then
    local -a _ks=()
    mapfile -t _ks < <(gq_cap_key_indexes)
    set -- ${_ks[@]+"${_ks[@]}"}
  fi
  _gq_ensure_models || true
  for t in $(gq_tier_list); do
    c="$(ai_models_gemini_chain "$t" 2>/dev/null)" || c=""
    tiers+=("$t"); chains+=("$c")
    all="${all:+$all,}$c"
  done
  all="$(printf '%s' "$all" | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -)"
  pf="$(mktemp)" || return 1
  tf="$(mktemp)" || { rm -f "$pf"; return 1; }
  _gq_pairs_jsonl "$all" "$@" > "$pf"
  for i in "${!tiers[@]}"; do
    _gq_tier_from_pairs "${tiers[$i]}" "${chains[$i]}" "$pf" >> "$tf"
  done
  label="$(_gq_day_label "$ds")"
  jq -s -c --argjson now "$now" --argjson ds "$ds" \
    --argjson de "$( [ "$rolling" = "0" ] && printf '%s' "$de" || printf 'null')" \
    --arg label "$label" --arg rtime "$(gq_setting daily_reset_time)" --arg rtz "$(gq_setting daily_reset_tz)" \
    --argjson rolling "$( [ "$rolling" = "0" ] && printf false || printf true)" \
    --argjson minute "$_GQ_MINUTE" \
    --argjson keys "$(printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length > 0))')" '
    { schema_version: 1,
      generated_at: ($now | todateiso8601), generated_epoch: $now,
      source: "ledger",
      ledger_note: "Metered from the fleet ledger only: usage of the same Google project by anything else (manual use, AI Studio, other tools) is not seen, so the AI Studio viewer can show more usage than this.",
      window: { day_label: $label, day_start: $ds, day_end: $de,
                day_start_iso: ($ds | todateiso8601),
                day_end_iso: (if $de == null then null else ($de | todateiso8601) end),
                rolling: $rolling, minute_window_sec: $minute,
                daily_reset_time: $rtime, daily_reset_tz: $rtz },
      key_indexes: $keys,
      tiers: . }' "$tf"
  rm -f "$pf" "$tf"
}

# gq_tier_can_run <snapshot_file> <tier> — the question a later actuation change asks
# ("can tier T run on Gemini now?"), answered from a snapshot. Prints the status
# (degraded: "degraded <model>") and returns 0 available/degraded, 1 unavailable,
# 2 unknown or no readable snapshot. Reads only; gates nothing.
gq_tier_can_run() {
  local snap="$1" tier="$2" line st m
  line="$(jq -r --arg t "$tier" '.tiers[] | select(.tier == $t)
      | [.status, (.degraded_to // "")] | @tsv' "$snap" 2>/dev/null | head -1)" || line=""
  IFS=$'\t' read -r st m <<< "$line"
  case "$st" in
    available)   printf 'available\n'; return 0 ;;
    degraded)    printf 'degraded %s\n' "$m"; return 0 ;;
    unavailable) printf 'unavailable\n'; return 1 ;;
    *)           printf 'unknown\n'; return 2 ;;
  esac
}

# gq_tier_notices <snapshot_file> <state_file>
# Prints one ::warning:: per tier whose snapshot status is degraded or unavailable,
# at most ONCE per tier per reset day: each notice appends a kind:"gemini_tier_notice"
# record {tier, status, day} to <state_file>, and a tier already noticed for the
# snapshot's day is skipped. Index-free (tiers and models only).
gq_tier_notices() {
  local snap="$1" state="$2" day now t st fc dm ch
  day="$(jq -r '.window.day_label // empty' "$snap" 2>/dev/null)"
  [ -n "$day" ] || return 0
  now="$(gq_now)"
  while IFS=$'\t' read -r t st fc dm ch; do
    [ -n "$t" ] || continue
    if [ -f "$state" ] && jq -R -e --arg t "$t" --arg d "$day" 'try fromjson catch empty
         | select(type == "object" and .kind == "gemini_tier_notice" and .tier == $t and .day == $d)' \
         "$state" >/dev/null 2>&1; then
      continue
    fi
    if [ "$st" = "degraded" ]; then
      printf '::warning::[gemini-tier] tier %s is degraded on Gemini (%s): its first choice %s has no usable key today, only %s can run — a quality change\n' \
        "$t" "$day" "$fc" "$dm"
    else
      printf '::warning::[gemini-tier] tier %s is unavailable on Gemini (%s): no model in its chain (%s) has a usable key today\n' \
        "$t" "$day" "$ch"
    fi
    jq -cn --arg ts "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" --arg t "$t" --arg st "$st" --arg d "$day" \
      '{ kind: "gemini_tier_notice", ts: $ts, tier: $t, status: $st, day: $d }' >> "$state" 2>/dev/null || true
  done < <(jq -r '.tiers[] | select(.status == "degraded" or .status == "unavailable")
      | [.tier, .status, (.first_choice // "-"), (.degraded_to // "-"), (.chain | join(" → "))] | @tsv' \
      "$snap" 2>/dev/null)
}

# gq_history_days — previous days the per-day history covers: GEMINI_HISTORY_DAYS,
# else the caps setting history_days, else 7.
gq_history_days() {
  local v="${GEMINI_HISTORY_DAYS:-}"
  [[ "$v" =~ ^[0-9]+$ ]] || v="$(gq_setting history_days)"
  [[ "$v" =~ ^[0-9]+$ ]] || v=7
  printf '%s' $(( 10#$v ))
}

# gq_day_history [n] — the per-reset-day matrix of key index × model for the current
# day and the <n> previous ones (default gq_history_days), newest first, as a JSON
# array of {day, start, end, rows:[{key_index, model, calls, rejected, peak_per_min,
# rate_limit_events, cap_hit}]}. calls = successful calls; rejected = rejected
# attempts; peak_per_min = most requests (both) in one UTC minute; rate_limit_events
# = cooldown records; cap_hit = requests reached the daily cap, or a minute reached
# the per-minute cap (any use of a cap-0 limit counts). Reads every key in the ledger.
gq_day_history() {
  local n="${1:-$(gq_history_days)}" f bf rf af key idx model calls rej peak tpeak ev req row crpm crtpm crpd hit k
  local -A capcache=()
  bf="$(mktemp)" || return 1
  rf="$(mktemp)" || { rm -f "$bf"; return 1; }
  af="$(mktemp)" || { rm -f "$bf" "$rf"; return 1; }
  gq_day_bounds "$n" > "$bf"
  f="$(gq_ledger_file)"
  if [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ]; then
    jq -R -r 'try fromjson catch empty
        | select(type == "object" and .engine == "gemini" and .key_index != null)
        | ((.ts // "") | try fromdateiso8601 catch null) as $e | select($e != null)
        | [ (.kind // "token_usage"), (.key_index | tostring), (.model // "-"), $e,
            (if (.kind // "token_usage") == "token_usage" then (.input_tokens // 0) + (.cache_read_tokens // 0) + (.output_tokens // 0) else 0 end) ] | @tsv' \
        "$f" 2>/dev/null \
    | awk -F'\t' -v bounds="$bf" '
        BEGIN { while ((getline l < bounds) > 0) { split(l, b, "\t"); nb++; bs[nb] = b[2]; be[nb] = b[3] } }
        {
          kd = -1
          for (i = 1; i <= nb; i++) if ($4 >= bs[i] && $4 < be[i]) { kd = i - 1; break }
          if (kd < 0) next
          k = kd "\t" $2 "\t" $3; seen[k] = 1
          min = int($4 / 60)
          if ($1 == "token_usage")          { calls[k]++; req[k]++; mm[k SUBSEP min]++; tt[k SUBSEP min] += $5 }
          else if ($1 == "gemini_attempt")  { rej[k]++;   req[k]++; mm[k SUBSEP min]++ }
          else if ($1 == "gemini_key_cooldown") ev[k]++
        }
        END {
          for (m in mm) { split(m, p, SUBSEP); if (mm[m] > peak[p[1]]) peak[p[1]] = mm[m] }
          for (m in tt) { split(m, p, SUBSEP); if (tt[m] > tpeak[p[1]]) tpeak[p[1]] = tt[m] }
          for (k in seen) printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\n", k, calls[k], rej[k], peak[k], (tpeak[k] ? tpeak[k] : 0), ev[k], req[k]
        }' | sort -t$'\t' -k1,1n -k2,2 -k3,3 > "$af"
  fi
  while IFS=$'\t' read -r key idx model calls rej peak tpeak ev req; do
    [ -n "$key" ] || continue
    k="$idx"$'\t'"$model"
    if [ -z "${capcache[$k]+x}" ]; then
      row="$(gq_caps_row_for "$idx" "$model")"
      capcache[$k]="$(printf '%s' "$row" | awk -F'\t' '{ print $3 "\t" $4 "\t" $5 }')"
    fi
    IFS=$'\t' read -r crpm crtpm crpd <<< "${capcache[$k]}"
    hit=0
    if [[ "$crpd" =~ ^[0-9]+$ ]]; then
      { [ $(( 10#$crpd )) -eq 0 ] && [ "$req" -gt 0 ]; } && hit=1
      { [ $(( 10#$crpd )) -gt 0 ] && [ "$req" -ge $(( 10#$crpd )) ]; } && hit=1
    fi
    if [[ "$crpm" =~ ^[0-9]+$ ]]; then
      { [ $(( 10#$crpm )) -eq 0 ] && [ "$req" -gt 0 ]; } && hit=1
      { [ $(( 10#$crpm )) -gt 0 ] && [ "$peak" -ge $(( 10#$crpm )) ]; } && hit=1
    fi
    if [[ "$crtpm" =~ ^[0-9]+$ ]]; then
      { [ $(( 10#$crtpm )) -eq 0 ] && [ "$tpeak" -gt 0 ]; } && hit=1
      { [ $(( 10#$crtpm )) -gt 0 ] && [ "$tpeak" -ge $(( 10#$crtpm )) ]; } && hit=1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$idx" "$model" "$calls" "$rej" "$peak" "$ev" "$hit" >> "$rf"
  done < "$af"
  jq -n -c --rawfile b "$bf" --rawfile r "$rf" '
    ($r | split("\n") | map(select(length > 0) | split("\t"))) as $rows
    | $b | split("\n") | map(select(length > 0) | split("\t")) | to_entries
    | map(.key as $k | .value as $v
        | { day: $v[0], start: ($v[1] | tonumber), end: ($v[2] | tonumber),
            rows: [ $rows[] | select(.[0] == ($k | tostring))
                    | { key_index: .[1], model: .[2], calls: (.[3] | tonumber),
                        rejected: (.[4] | tonumber), peak_per_min: (.[5] | tonumber),
                        rate_limit_events: (.[6] | tonumber), cap_hit: (.[7] == "1") } ] })'
  rm -f "$bf" "$rf" "$af"
}
