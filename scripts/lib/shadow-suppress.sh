#!/usr/bin/env bash
# shadow-suppress.sh — shadow-mode total PR-output suppression (#1713 split 1/2).
#
# When a dev-lead lane runs in shadow mode it must post NOTHING to the PR/issue:
# no review, comment, thread reply, label, or auto-merge enable. Its output goes
# to the run log and a file instead. This split is deliberately INERT — it adds
# the input + suppression only; it dispatches no second lane and emits no
# shadow_dual_run signal (that is split 2/2: scripts/shadow-run.sh).
#
# Rather than re-gate the ~35 posting sites across the handlers by hand, an active
# shadow run forces DEV_LEAD_DRY_RUN=true and thereby reuses the already-tested
# "post nothing" machinery every handler already honours. The one posting site
# that fires BEFORE fix-issue's dry-run early-exit (the dedup comment) is gated
# explicitly on shadow_mode_active in that handler.
#
# Env inputs:
#   DEV_LEAD_SHADOW_MODE  shadow flag, forwarded from the reusable's shadow_mode
#                         input (default "false"). Recognized-falsy => post as
#                         today; anything else (incl. unrecognized) => suppress.
#   SHADOW_OUTPUT_FILE    where suppressed output is recorded (optional).

# shadow_mode_active — fail-closed predicate for shadow-mode status.
# Returns 0 (active/suppress) for unrecognized values, 1 (inactive/post) only
# for recognized-falsy: "" | false | 0 | no | off (case-insensitive). If
# shadow mode status cannot be positively determined as OFF, suppression is
# enabled (fail-closed safety AC#4).
#
# Returns:
#   0 if shadow mode is active (suppress output)
#   1 if shadow mode is inactive (post as normal)
shadow_mode_active() {
  local v="${DEV_LEAD_SHADOW_MODE:-}"
  v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    ""|false|0|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

# shadow_apply_suppression — enable shadow-mode output suppression.
# Forces DEV_LEAD_DRY_RUN=true, which disables all PR/issue posting sites.
# Records a suppression notice to the run log and an optional output file.
# Idempotent: no-op if shadow mode is inactive (DEV_LEAD_SHADOW_MODE is
# recognized-falsy).
#
# Environment variables (read):
#   DEV_LEAD_SHADOW_MODE - shadow mode flag (recognized-falsy = inactive)
#   SHADOW_OUTPUT_FILE   - optional path to record suppressed output (default: /tmp/dev-lead-shadow-output.txt)
#
# Environment variables (written):
#   DEV_LEAD_SHADOW_MODE - normalized to "true" if suppression activated
#   DEV_LEAD_DRY_RUN     - set to "true" to disable all posting sites
#
# Returns:
#   Always 0 (success)
shadow_apply_suppression() {
  shadow_mode_active || return 0

  export DEV_LEAD_SHADOW_MODE="true"
  export DEV_LEAD_DRY_RUN="true"

  export SHADOW_OUTPUT_FILE="${SHADOW_OUTPUT_FILE:-/tmp/dev-lead-shadow-output.txt}"
  printf '[shadow] PR-output suppression active for this run (%s)\n' \
    "$(date -u +%FT%TZ 2>/dev/null || echo now)" >> "$SHADOW_OUTPUT_FILE" 2>/dev/null || true

  echo "::notice::shadow_mode active — all PR output suppressed for this run; output routed to the run log and ${SHADOW_OUTPUT_FILE}."
}
