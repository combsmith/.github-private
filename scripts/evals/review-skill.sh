#!/usr/bin/env bash
# review-skill.sh — review one candidate skill edit (a prompt-skill diff or file)
# against the skill rubric, emitting a machine-readable pass/fail + numeric score
# the strict-improvement gate consumes (issue #615, epic #610 Phase 2 / epic #581).
#
# This is the content_ref adapter for artifact_type=skill_candidate. Like
# review-one-pr.sh is the pr_diff handler and review-plan.sh is the plan_json
# handler, this is the skill_candidate handler of the rubric registry: it resolves
# {rubric, output_channel} for skill_candidate from the versioned manifest,
# presents the candidate skill edit (the content_ref) to the rubric, and reuses
# engine.sh's existing deep-tier model routing (run_agentic) — it introduces NO
# separate model selector. The verdict is delivered as a pass/score signal by the
# resolved output channel (scripts/post-skill-score.sh), which is NOT a GitHub PR
# review and never calls post-pr-review.sh.
#
# Usage: review-skill.sh <candidate-skill-edit>
#   <candidate-skill-edit> is a unified diff of a prompts/*.md skill, or a full
#   skill file. It is opaque to the registry; the rubric prompt reads it.
#
# Env:
#   REVIEW_ENGINE       — "claude" | "gemini" | "copilot" (default: claude), via engine.sh
#   DRY_RUN             — "true"/"false", forwarded to the output channel (default: false)
#   SKILL_SCORE_OUTPUT  — optional destination path for the score JSON
#                         (consumed by the output channel; defaults to a temp file)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Engine abstraction: ENGINE_* model vars + run_agentic (deep tier). Reused as-is
# — the registry is an input-adapter layer ABOVE engine.sh and must not change
# model routing.
# shellcheck source=../engine.sh
source "$REPO_ROOT/scripts/engine.sh"
# Rubric registry: review_registry_lookup resolves {rubric, output_channel}.
# shellcheck source=../lib/review-registry.sh
source "$REPO_ROOT/scripts/lib/review-registry.sh"

CANDIDATE_PATH="${1:?usage: review-skill.sh <candidate-skill-edit>}"
[[ -s "$CANDIDATE_PATH" ]] || { echo "::error::candidate skill edit '$CANDIDATE_PATH' missing or empty" >&2; exit 1; }
# Resolve to an absolute path so the rubric prompt can read it regardless of the
# engine's working directory.
CANDIDATE_PATH="$(cd "$(dirname "$CANDIDATE_PATH")" && pwd)/$(basename "$CANDIDATE_PATH")"
export CANDIDATE_PATH
DRY_RUN="${DRY_RUN:-false}"

# ── artifact-contract dispatch ────────────────────────────────────────────────
ARTIFACT_TYPE="skill_candidate"
CONTENT_REF="$CANDIDATE_PATH"

REVIEW_RUBRIC=$(review_registry_lookup "$ARTIFACT_TYPE" rubric | tr -d '\r') || {
  echo "::error::no rubric registered for artifact_type=$ARTIFACT_TYPE"
  exit 1
}
REVIEW_OUTPUT_CHANNEL=$(review_registry_lookup "$ARTIFACT_TYPE" output_channel | tr -d '\r') || {
  echo "::error::no output_channel registered for artifact_type=$ARTIFACT_TYPE"
  exit 1
}

# The skill rubric is a single prompt file (the fixed reviewer checklist). Take
# the first cascade entry; the registry stores it as a one-element comma list so
# the field is uniform with pr_diff's multi-tier cascade.
IFS=',' read -ra REVIEW_RUBRIC_CASCADE <<< "$REVIEW_RUBRIC"
RUBRIC_PROMPT="${REVIEW_RUBRIC_CASCADE[0]}"

echo "==> reviewing skill candidate: $CANDIDATE_PATH"
echo "    artifact_type=$ARTIFACT_TYPE content_ref=$CONTENT_REF"
echo "    rubric=$REVIEW_RUBRIC"
echo "    output_channel=$REVIEW_OUTPUT_CHANNEL"

# ── run the rubric via engine.sh deep tier ────────────────────────────────────
# The prompt writes its score JSON to $OUTPUT_FILE. run_agentic also tees the
# agent's stdout; capture it as a fallback in case the model printed the JSON to
# stdout instead of writing the file.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
OUTPUT_FILE="$WORK_DIR/score.json"
export OUTPUT_FILE
: > "$OUTPUT_FILE"

run_agentic "$REPO_ROOT/$RUBRIC_PROMPT" "$ENGINE_DEEP_MODEL" "deep" > "$WORK_DIR/raw.out" 2>"$WORK_DIR/raw.err" || {
  echo "::error::skill rubric run exited non-zero. Error log:" >&2
  cat "$WORK_DIR/raw.err" >&2
  exit 1
}

# Resolve the score JSON: prefer the file the prompt wrote; fall back to stdout
# if the model printed the JSON there instead.
if ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
  if jq empty "$WORK_DIR/raw.out" 2>/dev/null; then
    cp "$WORK_DIR/raw.out" "$OUTPUT_FILE"
  elif python3 -c "
import sys, json
text = open(sys.argv[1]).read()
decoder = json.JSONDecoder()
pos = text.find('{')
while pos >= 0:
    try:
        obj, _ = decoder.raw_decode(text, pos)
        if isinstance(obj, dict) and obj.get('artifact_type') == 'skill_candidate':
            print(json.dumps(obj))
            sys.exit(0)
    except Exception:
        pass
    pos = text.find('{', pos + 1)
sys.exit(1)
" "$WORK_DIR/raw.out" > "$OUTPUT_FILE" 2>/dev/null; then
    echo "skill score extracted from raw output"
  else
    echo "::error::skill rubric did not produce valid score JSON. Output log:" >&2
    cat "$WORK_DIR/raw.out" >&2
    echo "Error log:" >&2
    cat "$WORK_DIR/raw.err" >&2
    exit 1
  fi
fi

# ── deliver via the resolved pass/score channel ───────────────────────────────
# Default the gate-consumption path to a stable temp file OUTSIDE WORK_DIR when
# the caller didn't pin one — WORK_DIR is removed by the EXIT trap, so any path
# within it would be deleted before the gate can consume the score.
if [[ -z "${SKILL_SCORE_OUTPUT:-}" ]]; then
  SKILL_SCORE_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/skill-score.json.XXXXXX")"
fi
export SKILL_SCORE_OUTPUT
bash "$REPO_ROOT/$REVIEW_OUTPUT_CHANNEL" "$CONTENT_REF" "$OUTPUT_FILE" "$DRY_RUN"
