#!/usr/bin/env bash
# apply-reviewed-plan.sh — apply a maintainer-REVIEWED plan.json WITHOUT re-planning.
#
# The plan/apply split (#604): a dry-run uploads an authoritative plan.json
# artifact; a maintainer reviews it; then the apply run is pointed at THAT
# artifact instead of asking the LLM to plan again. This script is the
# apply-side handoff — it never invokes the BMAD Scrum Master. What the
# maintainer reviewed is what materializes.
#
# It does exactly two things, in order:
#   1. Re-validate the supplied plan with validate-plan.py
#      — we never apply an unvalidated artifact.
#   2. Hand it to apply-plan.sh, which owns all materialization (incl. the
#      blocking-open-questions gate, the idempotency/supersede guard, and the
#      `initiative:auto` invariant). DRY_RUN is honored throughout.
#
# Env (PLAN_PATH consumed here; the rest are passed straight through to
# apply-plan.sh — see its header): PLAN_PATH (required), REPO, DISCUSSION_NUMBER,
# DISCUSSION_NODE_ID, FORCE_REPLAN, DRY_RUN / DRY_RUN_LOG.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PLAN_PATH="${PLAN_PATH:?PLAN_PATH required (path to the reviewed plan.json)}"
[[ -f "$PLAN_PATH" ]] && [[ -s "$PLAN_PATH" ]] || { echo "::error::reviewed plan '$PLAN_PATH' missing, empty, or not a regular file" >&2; exit 1; }

# Guard: reviewed plans must have an explicit source_discussion. A reviewed
# artifact is applied out-of-band, potentially in a different session context;
# it must definitively reference which discussion it came from, not rely on the
# current dispatch context. Also reject artifacts that target a different
# discussion than the one the maintainer declared.
plan_src="$(jq -r '.source_discussion // empty' "$PLAN_PATH")"
if [[ -z "$plan_src" ]]; then
  echo "::error::plan.json must have a source_discussion field for reviewed-plan applies — the artifact must be self-contained about its origin." >&2
  exit 1
fi
if [[ -n "${DISCUSSION_NUMBER:-}" ]]; then
  if [[ "$plan_src" != "$DISCUSSION_NUMBER" ]]; then
    echo "::error::plan.json source_discussion (${plan_src}) does not match this run's DISCUSSION_NUMBER (${DISCUSSION_NUMBER}) — supply the correct dry-run run ID for discussion #${DISCUSSION_NUMBER}." >&2
    exit 1
  fi
fi

echo "==> applying reviewed plan (no re-plan): $PLAN_PATH"

# Re-validate before applying.
python3 "$SCRIPT_DIR/validate-plan.py" "$PLAN_PATH"

# Materialize. apply-plan.sh inherits PLAN_PATH and the rest from the environment.
exec bash "$SCRIPT_DIR/apply-plan.sh"
