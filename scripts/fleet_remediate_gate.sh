#!/usr/bin/env bash
# NOTE: strict mode is set in the execute-directly guard at the bottom, not at the
# top level — so sourcing this file (the bats tests do) does not leak `set -euo
# pipefail` into the caller's shell (repo standard, AGENTS.md / #1257).
# fleet_remediate_gate.sh — pure go/no-go gate for the Actions Fleet Monitor's
# opt-in stub-drift remediation (#1152, epic #1148, Phase 4). Sourced by bats to
# exercise the pure decision, and invoked as a CLI by actions-fleet-monitor.yml
# to compute the DRY_RUN value for the remediation step.
#
# The Fleet Monitor detects stub drift and writes fleet_stub_drift.json every run;
# the remediation step consumes it on the SAME cadence. This gate keeps that step
# inert (dry-run) unless a human has explicitly opted a run into going live for
# the pilot. Live remediation requires ALL of, together:
#   1. an explicit workflow_dispatch with remediate=live — scheduled and
#      workflow_call runs are ALWAYS dry-run, so the loop never goes live by
#      accident;
#   2. the cross-repo write credential present (GH_PAT_WORKFLOWS) — the epic's
#      untracked prerequisite confirmed it carries cross-repo contents:write +
#      pull_requests:write;
#   3. a configured pilot repo — the Phase-3 pilot scope bounds the blast radius.
# Any missing precondition on a live request degrades to dry-run with a
# ::warning:: and NEVER fails the monitor (mirroring fleet_monitor.sh's
# token-degradation posture: warn instead of fail).

# remediate_dry_run <event_name> <remediate_mode> <token_present> <pilot_present>
# Echoes the DRY_RUN value ("true" or "false") on stdout. When a live run is
# requested but a precondition is missing, emits a ::warning:: to stderr and
# echoes "true" (degrade to dry-run). Always returns 0 — the gate never fails.
remediate_dry_run() {
  local event="${1:-}" mode="${2:-}" token_present="${3:-}" pilot_present="${4:-}"

  # Live is only ever considered on an explicit workflow_dispatch remediate=live.
  # Every other trigger (schedule, workflow_call) stays dry-run unconditionally.
  if [[ "$event" != "workflow_dispatch" ]] || [[ "$mode" != "live" ]]; then
    echo "true"
    return 0
  fi

  # Cross-repo write credential required to open remediation PRs on target repos.
  if [[ "$token_present" != "true" ]]; then
    echo "::warning::Fleet remediation requested live but the cross-repo write credential (GH_PAT_WORKFLOWS) is absent — degrading to dry-run." >&2
    echo "true"
    return 0
  fi

  # Phase-3 pilot scope required: live remediation is bounded to a named pilot.
  if [[ "$pilot_present" != "true" ]]; then
    echo "::warning::Fleet remediation requested live but no pilot repo is configured (FLEET_REMEDIATE_PILOT_REPO) — degrading to dry-run." >&2
    echo "true"
    return 0
  fi

  echo "false"
  return 0
}

# Source-guard: tests source this to exercise the pure gate; a direct run prints
# the DRY_RUN decision so the workflow step can capture it from stdout.
if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
  set -euo pipefail
  remediate_dry_run "$@"
fi
