#!/usr/bin/env bash
# dev-lead-timeout-guardrail.sh — #1017 (epic #901, story A/3)
#
# Static guardrail: assert that the sum of the per-tier engine timeouts plus a
# fixed overhead margin can never exceed the dev-lead job's `timeout-minutes`
# backstop. The job cap is a hang/stuck-run backstop (GitHub hard cap 360/job);
# per-tier timeouts stop a single hung model invocation from burning it. If the
# tiers could sum past the job cap, a legitimate multi-tier run could be killed
# mid-write by the job backstop instead of by its own tier timeout. This check
# fails CI loudly if that invariant is ever violated by a config edit.
#
# Invariant:  Σ(per-tier default budgets) + OVERHEAD_MARGIN_SEC  ≤  job_cap_sec
#
# Overhead margin accounts for the fixed, non-tier work in the job (repo
# checkout, CLI install, git/PR operations) — empirically ~10–15 min.
#
# Sources of truth (parsed, never hardcoded here):
#   - per-tier defaults:  scripts/engine.sh  (`VAR="${VAR:-N}"`)
#   - job cap:            .github/workflows/dev-lead-reusable.yml (dispatch job
#                         `timeout-minutes:`)
#
# Overridable via env for testing: ENGINE_SH, WORKFLOW_YML, OVERHEAD_MARGIN_SEC.
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "$_here/.." && pwd)"

ENGINE_SH="${ENGINE_SH:-$_repo_root/scripts/engine.sh}"
WORKFLOW_YML="${WORKFLOW_YML:-$_repo_root/.github/workflows/dev-lead-reusable.yml}"
# Fixed overhead margin (seconds): checkout + CLI install + git/PR ops.
OVERHEAD_MARGIN_SEC="${OVERHEAD_MARGIN_SEC:-900}"

_die() { echo "guardrail: $*" >&2; exit 2; }

[[ -r "$ENGINE_SH" ]]    || _die "cannot read engine.sh at $ENGINE_SH"
[[ -r "$WORKFLOW_YML" ]] || _die "cannot read workflow at $WORKFLOW_YML"

# Extract a `VAR="${VAR:-N}"` default from engine.sh. Skips commented-out lines
# and tolerates leading whitespace so a stray comment can't be mis-parsed.
_tier_default() {
  local var="$1" val
  val="$(sed -n "/^[[:space:]]*#/d; s/^[[:space:]]*$var=\"\${$var:-\([0-9][0-9]*\)}\".*/\1/p" "$ENGINE_SH")"
  [[ -n "$val" ]] || _die "could not parse default for $var in $ENGINE_SH"
  printf '%s' "$val"
}

# Extract the dispatch job's `timeout-minutes:` (minutes). The dispatch job is
# the one the engine tiers run under; the ci-relay job's own timeout is
# irrelevant to tier budgeting.
_job_timeout_min() {
  local val
  val="$(awk '
    /^[[:space:]]*#/ {next}
    /^  dispatch:[[:space:]]*$/ {inblk=1; next}
    inblk==1 && /^  [A-Za-z]/  {inblk=0}
    inblk==1 && /^[[:space:]]*timeout-minutes:/ {print $2; exit}
  ' "$WORKFLOW_YML")"
  [[ -n "$val" ]] || _die "could not parse dispatch timeout-minutes in $WORKFLOW_YML"
  printf '%s' "$val"
}

TRIAGE="$(_tier_default TRIAGE_TIMEOUT_SEC)"
DEEP="$(_tier_default DEEP_TIMEOUT_SEC)"
AUDIT="$(_tier_default AUDIT_TIMEOUT_SEC)"
ACTION="$(_tier_default ACTION_TIMEOUT_SEC)"
DUCK="$(_tier_default DUCK_TIMEOUT_SEC)"

job_min="$(_job_timeout_min)"

# Fail with a clear guardrail message (not a generic bash arithmetic error) if
# any budget/timeout failed to parse as a positive integer — e.g. a tier default
# is missing or timeout-minutes became a non-numeric expression.
for _v in "$TRIAGE" "$DEEP" "$AUDIT" "$ACTION" "$DUCK" "$job_min"; do
  [[ "$_v" =~ ^[0-9]+$ ]] || _die "failed to parse a numeric budget/timeout (got: '${_v}') — check $ENGINE_SH and $WORKFLOW_YML"
done

job_sec=$(( job_min * 60 ))

sigma=$(( TRIAGE + DEEP + AUDIT + ACTION + DUCK ))
required=$(( sigma + OVERHEAD_MARGIN_SEC ))

echo "dev-lead timeout guardrail (#1017)"
echo "  per-tier budgets (sec): TRIAGE=$TRIAGE DEEP=$DEEP AUDIT=$AUDIT ACTION=$ACTION DUCK=$DUCK"
echo "  Σ tiers            = ${sigma}s"
echo "  overhead margin    = ${OVERHEAD_MARGIN_SEC}s"
echo "  Σ + overhead       = ${required}s"
echo "  job timeout        = ${job_min}m = ${job_sec}s"

if [[ "$required" -le "$job_sec" ]]; then
  echo "  RESULT: PASS (Σ+overhead ${required}s ≤ job ${job_sec}s)"
  exit 0
fi

echo "  RESULT: FAIL — per-tier budgets exceed the job backstop" >&2
echo "  Σ+overhead ${required}s > job ${job_sec}s (over by $(( required - job_sec ))s)" >&2
echo "  Fix: lower a per-tier *_TIMEOUT_SEC default in engine.sh or raise the" >&2
echo "       dispatch job timeout-minutes in dev-lead-reusable.yml (cap 360)." >&2
exit 1
