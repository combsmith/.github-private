#!/usr/bin/env bash
# gemini_tier_report.sh — Gemini availability per task tier (#2041, slice 2 of #2030).
#
# Run by the fleet monitor after the org-wide token report. It:
#   1. merges the Gemini ledger records the token report collected (GEMINI_RECORDS_IN)
#      into a history store that persists across fleet-monitor runs (the workflow
#      restores/saves GEMINI_TIER_STATE_DIR with actions/cache), de-duplicated and
#      pruned to the retention window (today + gq_history_days previous days);
#   2. writes the per-tier snapshot (snapshot.json, schema:
#      scripts/lib/gemini-tier-snapshot.schema.json) — uploaded as the
#      gemini-tier-snapshot artifact so the dry-run poller (#2029) can ask "can tier T
#      run on Gemini now?" (gq_tier_can_run). Nothing gates or defers dispatch on it;
#   3. emits one ::warning:: per degraded/unavailable tier per reset day (stderr, so
#      it is an annotation, not summary text);
#   4. prints the Markdown report (stdout → the job summary).
#
# Metered from the fleet's own ledger only — no network call, no Gemini API call,
# no key value (indexes only).
#
# Environment (all optional):
#   GEMINI_TIER_STATE_DIR  history store + snapshot directory (default .gemini-tier-state)
#   GEMINI_RECORDS_IN      JSONL of newly collected records (token_report.sh
#                          GEMINI_RECORDS_OUT); absent → nothing new to merge
#   GEMINI_HISTORY_DAYS    previous days shown and retained (default: caps setting
#                          history_days, else 7)
#   GEMINI_QUOTA_CAPS / GEMINI_QUOTA_NOW / AI_MODELS_GEMINI / GEMINI_*_MODEL[_CHAIN]
#                          as for scripts/lib/gemini-quota.sh and engine-models.sh

_GTR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/engine-models.sh
source "$_GTR_DIR/lib/engine-models.sh"
# shellcheck source=scripts/lib/gemini-quota.sh
source "$_GTR_DIR/lib/gemini-quota.sh"

# gtr_merge_store <store> <new_records_file>
# Merges <new_records_file> into <store>: keeps Gemini records that carry a well-formed key index
# (token_usage, gemini_attempt, gemini_key_cooldown, gemini_rejection_sample) and
# gemini_tier_notice state, drops anything older than the start of the oldest
# retained day, and de-duplicates (a run re-collecting an artifact it already merged
# adds nothing). Unparseable lines are dropped.
gtr_merge_store() {
  local store="$1" new="${2:-}" cutoff tmp
  cutoff="$(gq_day_bounds "$(gq_history_days)" | tail -1 | cut -f2)"
  [[ "$cutoff" =~ ^[0-9]+$ ]] || cutoff=0
  tmp="$(mktemp)" || return 1
  local inputs=()
  [ -f "$store" ] && inputs+=("$store")
  [ -n "$new" ] && [ -r "$new" ] && inputs+=("$new")
  if [ "${#inputs[@]}" -eq 0 ]; then
    mv "$tmp" "$store"
    return 0
  fi
  cat "${inputs[@]}" \
    | jq -R -c -S --argjson cutoff "$cutoff" '
        # The collected artifacts are untrusted (a fork PR run in a public repo can
        # upload one) and the key index is printed in the job summary, so keep only
        # the two shapes emit_token_record writes: a number, or digits plus a short
        # lowercase suffix. Anything else is dropped here, before it can be retained
        # in the cross-run store.
        def key_index_ok:
          (type == "number") or (type == "string" and test("^[0-9]{1,6}[a-z]{0,8}$"));
        try fromjson catch empty
        | select(type == "object")
        | select(.kind == "gemini_tier_notice"
                 or (.engine == "gemini" and (.key_index | key_index_ok)
                     and ((.kind // "token_usage") | IN("token_usage", "gemini_attempt",
                          "gemini_key_cooldown", "gemini_rejection_sample"))))
        | ((.ts // "") | try fromdateiso8601 catch null) as $e
        | select($e != null and $e >= $cutoff)' 2>/dev/null \
    | sort -u > "$tmp"
  local rc=("${PIPESTATUS[@]}")
  if [ "${rc[1]}" -ne 0 ] || [ "${rc[2]}" -ne 0 ]; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$store"
}

# _gtr_md <text> — text safe inside a Markdown table cell.
_gtr_md() {
  local s="${1//\\/\\\\}"
  s="${s//|/\\|}"
  s="${s//\`/\'}"
  printf '%s' "$s"
}

# _gtr_time <epoch|null> — "YYYY-MM-DD HH:MM UTC", or "-".
_gtr_time() {
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then date -u -d "@$1" '+%Y-%m-%d %H:%M UTC'; else printf -- '-'; fi
}

# gtr_render <snapshot_file> <history_json_file> <store>
# The Markdown report. Pure: reads the three files, writes stdout.
gtr_render() {
  local snap="$1" hist="$2" store="$3" n
  n="$(gq_history_days)"
  printf '## Gemini availability per task tier\n\n'
  jq -r '"_Snapshot \(.generated_at) · today'"'"'s window \(.window.day_start_iso) → \(.window.day_end_iso // "rolling 24h")"
      + (if .window.rolling then " (daily reset not configured: rolling 24h)"
         else " (\(.window.daily_reset_time) \(.window.daily_reset_tz) reset)" end)
      + " · key indexes: \(.key_indexes | join(", ") | if . == "" then "none" else . end)_\n"' "$snap"
  printf '> **Ledger only — compare with the AI Studio viewer.** Everything here is metered from the fleet'"'"'s own ledger '
  printf '(successful calls plus the rejected attempts the engine recorded). It cannot see usage of the same Google project '
  printf 'by anything else (manual use, AI Studio, other tools), and a rejection the ledger missed is not counted, so Google'"'"'s '
  printf 'AI Studio viewer can show more usage than the ledger count below. No call to the Gemini API is made to measure or '
  printf 'reconcile quota: calibration against the viewer is a manual maintainer step.\n\n'

  printf '| Tier | Status | Chain | Runs on | Usable (model : key index) | Remaining calls today |\n'
  printf '|---|---|---|---|---|---:|\n'
  jq -r '.tiers[] | [ .tier,
      (.status + (if .status == "degraded" then " → `\(.degraded_to)`" else "" end)),
      (.chain | map("`\(.)`") | join(" → ") | if . == "" then "-" else . end),
      (if .serving_model then "`\(.serving_model)`" else "-" end),
      (.usable | map("`\(.model)` : \(.key_index)") | join(", ") | if . == "" then "-" else . end),
      (if .remaining_calls == null then (if .status == "unknown" then "unknown" else "no daily cap" end)
       else (.remaining_calls | tostring) end) ] | "| " + join(" | ") + " |"' "$snap"
  printf '\n`available`: the first-choice model has a usable key · `degraded`: only a later model in the chain '
  printf 'can run (a quality change) · `unavailable`: no model in the chain has a usable key now · `unknown`: caps not '
  printf 'filled in `scripts/lib/gemini-quota-caps.tsv`.\n\n'

  printf '### Remaining capacity per key and model (current window)\n\n'
  printf '| Key | Model | State | Ledger requests today | Remaining req/day | Remaining req/min | Remaining tok/min | Until |\n'
  printf '|---:|---|---|---:|---:|---:|---:|---|\n'
  local k m st used rd rm rt until why
  while IFS=$'\t' read -r k m st used rd rm rt until why; do
    [ -n "$k" ] || continue
    printf '| %s | `%s` | %s | %s | %s | %s | %s | %s |\n' "$k" "$m" \
      "$st$( [ "$why" = "-" ] || printf ' (%s)' "$(_gtr_md "$why")")" "$used" "$rd" "$rm" "$rt" "$(_gtr_time "$until")"
  done < <(jq -r '[.tiers[].pairs[]] | unique_by([.key_index, .model]) | sort_by(.key_index, .model)[]
      | def c($v; $cap): if $v == null then (if $cap == "none" then "no cap" else "unknown" end) else ($v | tostring) end;
        [ .key_index, .model, .state, (.used.rpd | tostring),
          c(.remaining.rpd; .caps.rpd), c(.remaining.rpm; .caps.rpm), c(.remaining.tpm; .caps.tpm),
          (.until // "-" | tostring), (if .state == "available" then "-" else .reason end) ] | @tsv' "$snap")
  printf '\n'

  printf '### Per-day history (today and the previous %s days)\n\n' "$n"
  printf '| Day | Key | Model | Calls | Rejected | Peak req/min | Rate-limit events | Hit cap |\n'
  printf '|---|---:|---|---:|---:|---:|---:|---|\n'
  jq -r '.[] | . as $d
      | if (.rows | length) == 0 then "| \($d.day) | - | _no Gemini activity in the ledger_ | | | | | |"
        else .rows[] | "| \($d.day) | \(.key_index | tostring | gsub("[^0-9a-z]"; "")) | `\(.model | gsub("[\\\\]"; "\\\\") | gsub("[|]"; "\\|") | gsub("`"; "'"'"'"))` | \(.calls) | \(.rejected) | \(.peak_per_min) | \(.rate_limit_events) | \(if .cap_hit then "**yes**" else "no" end) |"
        end' "$hist"
  printf '\n'

  printf '### Rejection messages seen (redacted, one per distinct message)\n\n'
  local samples
  samples="$(jq -R -r 'try fromjson catch empty
      | select(type == "object" and .kind == "gemini_rejection_sample"
               and ((.key_index | type) == "number")
               and ((.ts // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$")))
      | [ .ts, (.key_index | tostring), ((.model // "-") | tostring | .[0:80]), ((.scope // "-") | tostring | .[0:20]),
          ((.sample // "") | tostring | .[0:300]) ] | @tsv' \
      "$store" 2>/dev/null | sort | awk -F'\t' '!seen[$5]++')"
  if [ -z "$samples" ]; then
    printf '_None recorded in the retained window._\n\n'
  else
    printf '| First seen | Key | Model | Treated as | Message |\n|---|---:|---|---|---|\n'
    local ts sk sm sc sx
    while IFS=$'\t' read -r ts sk sm sc sx; do
      sx="$(_gq_redact_line "$sx")"
      printf '| %s | %s | `%s` | %s | %s |\n' "$ts" "$sk" "$(_gtr_md "$sm")" "$(_gtr_md "$sc")" "$(_gtr_md "$sx")"
    done <<< "$samples"
    printf '\n'
  fi
}

main() {
  set -euo pipefail
  local dir="${GEMINI_TIER_STATE_DIR:-.gemini-tier-state}" store snap hist
  mkdir -p "$dir"
  store="$dir/history.jsonl"
  snap="$dir/snapshot.json"
  hist="$dir/history-days.json"
  # A failed report must not leave the previous run's restored output to be uploaded.
  rm -f "$snap" "$hist"
  [ -f "$store" ] || : > "$store"
  gtr_merge_store "$store" "${GEMINI_RECORDS_IN:-}"
  export GEMINI_LEDGER_FILE="$store"
  gq_tier_snapshot > "$snap"
  gq_tier_notices "$snap" "$store" >&2
  gq_day_history "$(gq_history_days)" > "$hist"
  gtr_render "$snap" "$hist" "$store"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
