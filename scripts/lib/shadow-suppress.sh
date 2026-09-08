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

# shadow_mode_active — fail-closed predicate.
#   rc 1 (inactive => post, today's behaviour) only for the recognized-falsy set:
#        "" | false | 0 | no | off  (any case).
#   rc 0 (active => suppress) for everything else, including "true" AND any
#        unexpected/garbage value: if the run cannot positively determine that
#        shadow is OFF, it suppresses (AC#4).
shadow_mode_active() {
  local v="${DEV_LEAD_SHADOW_MODE:-}"
  v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    ""|false|0|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

# shadow_apply_suppression — turn an active shadow run into the "post nothing"
# state. Idempotent; a no-op when shadow is inactive.
shadow_apply_suppression() {
  shadow_mode_active || return 0

  export DEV_LEAD_SHADOW_MODE="true"
  export DEV_LEAD_DRY_RUN="true"

  local out="${SHADOW_OUTPUT_FILE:-/tmp/dev-lead-shadow-output.txt}"
  printf '[shadow] PR-output suppression active for this run (%s)\n' \
    "$(date -u +%FT%TZ 2>/dev/null || echo now)" >> "$out" 2>/dev/null || true

  echo "::notice::shadow_mode active — all PR output suppressed for this run; output routed to the run log and ${out}."
}
