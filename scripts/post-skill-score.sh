#!/usr/bin/env bash
# post-skill-score.sh — pass/score output channel for the skill_candidate
# artifact type (issue #615, epic #610 Phase 2).
#
# This is the skill_candidate half of the review artifact contract's
# output_channel: the rubric registry (scripts/lib/review-registry.tsv) maps
# artifact_type skill_candidate -> {rubric: prompts/skill-review.md,
# output_channel: THIS script}.
#
# Unlike the pr_diff channel (scripts/post-pr-review.sh, which posts a GitHub PR
# review), a candidate skill edit is consumed by Epic #581's strict-improvement
# GATE, not a human on a PR. So this channel delivers the review brain's verdict
# as a MACHINE-READABLE pass/fail + numeric score the gate can consume. It NEVER
# posts a GitHub review and NEVER calls post-pr-review.sh.
#
# Inputs:
#   $1 — content_ref: the candidate skill edit (diff or file) path that was
#        reviewed (for the log line).
#   $2 — score JSON path: the rubric's output (see prompts/skill-review.md).
#   $3 — DRY_RUN (true/false). The score is a local artifact, so delivery is the
#        same either way; the flag is accepted for output-channel contract
#        symmetry with post-pr-review.sh / post-plan-findings.sh and surfaced in
#        the log.
#
# Env:
#   SKILL_SCORE_OUTPUT — optional destination path. When set, the validated score
#        JSON is written there for the strict-improvement gate to consume. When
#        unset, the verdict/score are summarized to stdout only.
#
# Score JSON shape (emitted by prompts/skill-review.md):
#   {
#     "artifact_type": "skill_candidate",
#     "verdict": "pass|fail",
#     "score": 0.0-1.0,
#     "summary": "...",
#     "findings": [ { "severity","category","message","location" } ]
#   }
#
# Exit codes: 0 on a well-formed pass/fail verdict with an in-range score;
# non-zero when the score file is missing, unparseable, carries an unknown
# verdict, or a non-numeric / out-of-range score.

set -euo pipefail

CONTENT_REF="${1:?usage: post-skill-score.sh <candidate-path> <score-json> <dry-run>}"
SCORE_JSON="${2:?usage: post-skill-score.sh <candidate-path> <score-json> <dry-run>}"
DRY_RUN="${3:-false}"

if [[ ! -s "$SCORE_JSON" ]]; then
  echo "ERROR: skill score JSON not found or empty at $SCORE_JSON" >&2
  exit 1
fi

if ! jq empty "$SCORE_JSON" 2>/dev/null; then
  echo "ERROR: skill score JSON at $SCORE_JSON is not valid JSON" >&2
  exit 1
fi

VERDICT="$(jq -r '.verdict // ""' "$SCORE_JSON")"
case "$VERDICT" in
  pass|fail) ;;
  *)
    echo "ERROR: invalid skill verdict '$VERDICT' (expected: pass|fail)" >&2
    exit 1
    ;;
esac

# The score gates strict improvement, so it must be a number in [0,1]. Reject a
# missing, non-numeric, or out-of-range score rather than passing a garbage
# signal to the gate.
if ! jq -e '(.score | type) == "number"' "$SCORE_JSON" >/dev/null 2>&1; then
  echo "ERROR: skill score is missing or non-numeric (expected a number in [0,1])" >&2
  exit 1
fi
if ! jq -e '.score >= 0 and .score <= 1' "$SCORE_JSON" >/dev/null 2>&1; then
  echo "ERROR: skill score $(jq -r '.score' "$SCORE_JSON") is out of range (expected [0,1])" >&2
  exit 1
fi

SCORE="$(jq -r '.score' "$SCORE_JSON")"
FINDING_COUNT="$(jq '(.findings // []) | length' "$SCORE_JSON")"
SUMMARY="$(jq -r '.summary // ""' "$SCORE_JSON")"

# Deliver the machine-readable pass/score to the gate's consumption path. This is
# a local artifact write (never an external mutation), so DRY_RUN does not gate it
# — a gate evaluating in dry-run still needs the score to decide.
if [[ -n "${SKILL_SCORE_OUTPUT:-}" ]]; then
  mkdir -p "$(dirname "$SKILL_SCORE_OUTPUT")"
  if [[ "$SCORE_JSON" -ef "$SKILL_SCORE_OUTPUT" ]]; then
    echo "skill score already at $SKILL_SCORE_OUTPUT"
  else
    jq '.' "$SCORE_JSON" > "$SKILL_SCORE_OUTPUT"
    echo "skill score written to $SKILL_SCORE_OUTPUT"
  fi
fi

echo "=== skill candidate review${DRY_RUN:+ (dry_run=$DRY_RUN)} ==="
echo "content_ref: $CONTENT_REF"
echo "verdict: $VERDICT"
echo "score: $SCORE"
echo "findings: $FINDING_COUNT"
[[ -n "$SUMMARY" ]] && echo "summary: $SUMMARY"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Skill candidate review — verdict: ${VERDICT} (score: ${SCORE})"
    echo "- Reviewed: \`${CONTENT_REF}\`"
    echo "- Findings: ${FINDING_COUNT}"
    [[ -n "$SUMMARY" ]] && echo "- ${SUMMARY}"
  } >>"$GITHUB_STEP_SUMMARY"
fi

exit 0
