#!/usr/bin/env bash
# post-plan-findings.sh — structured-findings output channel for the plan_json
# artifact type (issue #614, epic #610 Phase 2).
#
# This is the plan_json half of the review artifact contract's output_channel:
# the rubric registry (scripts/lib/review-registry.tsv) maps artifact_type
# plan_json -> {rubric: prompts/plan-review.md, output_channel: THIS script}.
#
# Unlike the pr_diff channel (scripts/post-pr-review.sh, which posts a GitHub PR
# review), a plan is consumed by the *planner*, not a human on a PR. So this
# channel delivers the critic's verdict as MACHINE-READABLE findings JSON the
# planner can read before apply-plan.sh materializes the epic/DAG. It NEVER
# posts a GitHub review and NEVER calls post-pr-review.sh.
#
# Inputs:
#   $1 — content_ref: the plan.json path that was reviewed (for the log line).
#   $2 — findings JSON path: the rubric's output (see prompts/plan-review.md).
#   $3 — DRY_RUN (true/false). Findings are local artifacts, so delivery is the
#        same either way; the flag is accepted for output-channel contract
#        symmetry with post-pr-review.sh and surfaced in the log.
#
# Env:
#   PLAN_FINDINGS_OUTPUT — optional destination path. When set, the validated
#        findings JSON is written there for the planner to consume. When unset,
#        the findings are summarized to stdout only.
#
# Findings JSON shape (emitted by prompts/plan-review.md):
#   {
#     "artifact_type": "plan_json",
#     "verdict": "pass|revise",
#     "summary": "...",
#     "findings": [ { "check","story_id","severity","finding" } ]
#   }
# This channel only reads .verdict/.summary/.findings|length, so it is agnostic
# to the per-finding field names.
#
# Exit codes: 0 on a well-formed verdict (pass or revise); non-zero when the
# findings file is missing, unparseable, or carries an unknown verdict.

set -euo pipefail

CONTENT_REF="${1:?usage: post-plan-findings.sh <plan-path> <findings-json> <dry-run>}"
FINDINGS_JSON="${2:?usage: post-plan-findings.sh <plan-path> <findings-json> <dry-run>}"
DRY_RUN="${3:-false}"

if [[ ! -s "$FINDINGS_JSON" ]]; then
  echo "ERROR: plan findings JSON not found or empty at $FINDINGS_JSON" >&2
  exit 1
fi

if ! jq empty "$FINDINGS_JSON" 2>/dev/null; then
  echo "ERROR: plan findings JSON at $FINDINGS_JSON is not valid JSON" >&2
  exit 1
fi

VERDICT="$(jq -r '.verdict // ""' "$FINDINGS_JSON")"
case "$VERDICT" in
  pass|revise) ;;
  *)
    echo "ERROR: invalid plan verdict '$VERDICT' (expected: pass|revise)" >&2
    exit 1
    ;;
esac

FINDING_COUNT="$(jq '(.findings // []) | length' "$FINDINGS_JSON")"
SUMMARY="$(jq -r '.summary // ""' "$FINDINGS_JSON")"

# Deliver the machine-readable findings to the planner's consumption path. This
# is a local artifact write (never an external mutation), so DRY_RUN does not
# gate it — a planner reviewing in dry-run still needs the findings to decide.
if [[ -n "${PLAN_FINDINGS_OUTPUT:-}" ]]; then
  mkdir -p "$(dirname "$PLAN_FINDINGS_OUTPUT")"
  if [[ "$FINDINGS_JSON" -ef "$PLAN_FINDINGS_OUTPUT" ]]; then
    echo "plan findings already at $PLAN_FINDINGS_OUTPUT"
  else
    jq '.' "$FINDINGS_JSON" > "$PLAN_FINDINGS_OUTPUT"
    echo "plan findings written to $PLAN_FINDINGS_OUTPUT"
  fi
fi

echo "=== plan review findings${DRY_RUN:+ (dry_run=$DRY_RUN)} ==="
echo "content_ref: $CONTENT_REF"
echo "verdict: $VERDICT"
echo "findings: $FINDING_COUNT"
[[ -n "$SUMMARY" ]] && echo "summary: $SUMMARY"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Plan review — verdict: ${VERDICT}"
    echo "- Reviewed: \`${CONTENT_REF}\`"
    echo "- Findings: ${FINDING_COUNT}"
    [[ -n "$SUMMARY" ]] && echo "- ${SUMMARY}"
  } >>"$GITHUB_STEP_SUMMARY"
fi

exit 0
