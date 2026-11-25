#!/usr/bin/env bash
# budget_poller.sh — DRY-RUN Claude budget poller (#2029, slice 2 of #1565).
#
# One poll per run:
#   1. read the usage envelope via scripts/lib/usage-telemetry.sh (the merged
#      adapter, #1888) and publish it on the EXISTING seam
#      (AGENT_TOKEN_BUDGET_TELEMETRY_FILE) — no new seam, no re-parse;
#   2. evaluate the SHIPPED public gates against that seam:
#        arl_token_budget_gate session   (real public config)
#        arl_token_weekly_glide_gate     (temp ARMED copy of the public config, so
#                                         the record says what the glide breaker
#                                         WOULD do; production ships it inert)
#   3. append one JSONL record (status, percents, resets_at, decisions, burn rate
#      vs the previous OK record, liveness line) to $BUDGET_POLLER_LOG and the job
#      summary.
#
# DRY-RUN ONLY. This script writes no Actions variable, org or repo, under any
# input — there is deliberately no write path, not even behind a flag.
#
# Fail-open and visible (AC #7): every failure (no token, transport error,
# non-200, malformed body, public library unavailable) is logged as a DEGRADED
# record + `::warning::` and the script still exits 0, so a poll failure never
# pages and never reads as a healthy OK record.
#
# Env (all optional):
#   CLAUDE_CODE_OAUTH_TOKEN    — the existing secret (read by the adapter only)
#   BUDGET_POLLER_PUBLIC_LIB   — path to the public agent-rate-limit.sh
#                                (default: public/scripts/lib/agent-rate-limit.sh)
#   AGENT_RATE_LIMITS_CONFIG   — path to the public agent-rate-limits.json
#                                (default: public/standards/agent-rate-limits.json)
#   BUDGET_POLLER_LOG          — JSONL log path (default: budget-poller-log.jsonl)
#   BUDGET_POLLER_MAX_RECORDS  — log bound (default: 720 ≈ 15 days at two slots an hour)
#   BUDGET_POLLER_NOW          — epoch override (testability)
#   GITHUB_EVENT_NAME          — the trigger, recorded as trigger_event (#2160)
#   BUDGET_POLLER_CRON         — the cron that fired (github.event.schedule),
#                                recorded with the slot it was meant for (#2160)
#   GITHUB_STEP_SUMMARY        — job summary (written when set)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/usage-telemetry.sh
source "${SCRIPT_DIR}/lib/usage-telemetry.sh"
# shellcheck source=scripts/lib/budget-poller.sh
source "${SCRIPT_DIR}/lib/budget-poller.sh"

PUBLIC_LIB="${BUDGET_POLLER_PUBLIC_LIB:-public/scripts/lib/agent-rate-limit.sh}"
export AGENT_RATE_LIMITS_CONFIG="${AGENT_RATE_LIMITS_CONFIG:-public/standards/agent-rate-limits.json}"
LOG_FILE="${BUDGET_POLLER_LOG:-budget-poller-log.jsonl}"

workdir="$(mktemp -d)" || { bp_log "failed to create temporary directory"; exit 1; }
trap 'rm -rf "$workdir"' EXIT

# One clock for the adapter (observed_at), the public gates (SOURCE_NOW), and
# the record, so a 429's retry window and the glide days-until-reset agree.
NOW="$(bp_now)"
if ! [[ "$NOW" =~ ^[0-9]+$ ]]; then
  bp_log "invalid BUDGET_POLLER_NOW '${NOW}' — using the system clock"
  NOW="$(date +%s)"
fi
export USAGE_TELEMETRY_NOW="$NOW"
export SOURCE_NOW="$NOW"

# 1. Read + publish on the existing seam.
envelope="$(usage_telemetry_fetch)"
publish_failed="false"
if ! usage_telemetry_publish_file "$envelope" "$workdir/telemetry.json" >/dev/null; then
  bp_log "could not publish the telemetry file — degraded record"
  : > "$workdir/telemetry.json" 2>/dev/null || true
  publish_failed="true"
fi
export AGENT_TOKEN_BUDGET_TELEMETRY_FILE="$workdir/telemetry.json"

http_status="$(jq -r '.status // 0' <<<"$envelope" 2>/dev/null || printf '0')"
retry_after="$(jq -r '.retry_after // empty' <<<"$envelope" 2>/dev/null || printf '')"
# The upstream body, read ONLY by bp_error_fields (#2179) for a refused read's
# error type/detail — never logged, echoed, or stored itself.
upstream_body="$(jq -c '.body // empty' <<<"$envelope" 2>/dev/null || printf '')"

# 2. Evaluate the shipped public gates (or degrade when they are unavailable).
s_pct="" w_pct="" s_reset="" w_reset="" reason_override=""
s_dec="unavailable" g_dec="unavailable" g_enabled="false"
[[ "$publish_failed" = "true" ]] && reason_override="telemetry-publish-failed"
if [[ -r "$PUBLIC_LIB" ]] && [[ -r "$AGENT_RATE_LIMITS_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$PUBLIC_LIB"

  g_enabled="$(arl_token_glide_enabled)"

  # Extraction uses the public library's OWN helpers (single parser).
  body="$(jq -c '.body? // {}' <<<"$envelope" 2>/dev/null || printf '{}')"
  s_pct="$(arl_token_extract_percent "$body" session)"
  w_pct="$(arl_token_extract_percent "$body" weekly_all)"
  s_reset="$(arl_token_extract_resets_at "$body" session)"
  w_reset="$(arl_token_extract_resets_at "$body" weekly_all)"

  s_dec="$(bp_gate arl_token_budget_gate session)"

  # Arm a PRIVATE temp copy of the config so the record reflects what the glide
  # breaker would do once armed. The real config file is never modified.
  armed_cfg="$workdir/agent-rate-limits.armed.json"
  if jq '.org_wide.token_budget.limits.weekly_all.enabled = true' \
      "$AGENT_RATE_LIMITS_CONFIG" > "$armed_cfg" 2>/dev/null; then
    g_dec="$(AGENT_RATE_LIMITS_CONFIG="$armed_cfg" bp_gate arl_token_weekly_glide_gate)"
  else
    bp_log "could not arm a temp copy of the public config — degraded record"
    g_dec="unavailable"
    reason_override="${reason_override:-weekly-glide-arm-failed}"
  fi
else
  bp_log "public library or config unavailable (${PUBLIC_LIB}, ${AGENT_RATE_LIMITS_CONFIG}) — degraded record"
  reason_override="${reason_override:-public-library-unavailable}"
fi

# 3. Build + append the record against the previous OK record (burn rate).
prev_ok="$(bp_last_ok "$LOG_FILE")"
record="$(bp_build_record "$NOW" "$http_status" "$retry_after" "$s_pct" "$w_pct" \
  "$s_reset" "$w_reset" "$s_dec" "$g_dec" "$g_enabled" "$reason_override" "$prev_ok" \
  "${GITHUB_EVENT_NAME:-}" "${BUDGET_POLLER_CRON:-}" \
  "$upstream_body")"
bp_append_record "$LOG_FILE" "$record" "${BUDGET_POLLER_MAX_RECORDS:-720}"

line="$(jq -r '.line' <<<"$record")"
decision="$(bp_decision_text "$record")"
if [[ "$(jq -r '.poll' <<<"$record")" = "ok" ]]; then
  printf '%s\n' "$line"
else
  printf '::warning::budget-poller: %s\n' "$line"
fi
printf 'budget-poller dry-run decision: %s\n' "$decision"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '## Budget poller (dry-run)\n\n'
    printf '> **Dry-run only (#2029).** Logs what the token-budget breaker would do; no variable is set or cleared.\n\n'
    printf '**%s**\n\n' "$line"
    printf -- '- **Dry-run decision:** %s\n\n' "$decision"
    printf '| Field | Value |\n|---|---|\n'
    jq -r '
      # Escape `|` so an upstream error_detail cannot break the table row.
      def v($x): if $x == null then "n/a" else ($x | tostring | gsub("\\|"; "\\|")) end;
      [ ["Timestamp", .ts], ["HTTP status", .http_status], ["Retry-After (s)", .retry_after],
        ["session %", .session_pct], ["session resets_at", .session_resets_at],
        ["weekly_all %", .weekly_all_pct], ["weekly_all resets_at", .weekly_all_resets_at],
        ["session gate", .session_decision],
        ["weekly glide gate (armed copy)", .weekly_glide_decision],
        ["weekly glide armed in public config", .weekly_glide_config_enabled],
        ["burn session (pp/h)", .burn_session_pph],
        ["burn weekly_all (pp/h)", .burn_weekly_all_pph],
        ["burn basis", .burn_basis],
        ["Trigger", .trigger_event], ["Cron that fired", .trigger_cron],
        ["Scheduled for", .scheduled_for], ["Start delay (s)", .start_delay_s],
        ["upstream error type", .error_type],
        ["upstream error detail", .error_detail] ]
      | .[] | "| \(.[0]) | \(v(.[1])) |"' <<<"$record"
    printf '\nDurable log: artifact `%s` (`%s`, one JSON record per poll).\n' \
      "$BUDGET_POLLER_ARTIFACT" "$(basename "$LOG_FILE")"
  } >> "$GITHUB_STEP_SUMMARY"
fi

exit 0
