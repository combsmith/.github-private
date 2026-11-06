#!/usr/bin/env bash
# review-plan.sh — adversarially review one initiative plan.json against the
# fixed plan rubric, emitting machine-readable findings (issue #614, epic #610
# Phase 2).
#
# This is the content_ref adapter for artifact_type=plan_json. Like
# review-one-pr.sh is the pr_diff handler, this is the plan_json handler of the
# rubric registry: it resolves {rubric, output_channel} for plan_json from the
# versioned manifest, presents the plan.json (the content_ref) to the rubric,
# and reuses engine.sh's existing deep-tier model routing (run_agentic) — it
# introduces NO separate model selector. The verdict is delivered as structured
# findings by the resolved output channel (scripts/post-plan-findings.sh), which
# is NOT a GitHub PR review and never calls post-pr-review.sh.
#
# Usage: review-plan.sh <plan.json>
#
# Env:
#   REVIEW_ENGINE   — "claude" | "gemini" | "copilot" (default: claude), via engine.sh
#   DRY_RUN         — "true"/"false", forwarded to the output channel (default: false)
#   PLAN_FINDINGS_OUTPUT — optional destination path for the findings JSON
#                          (consumed by the output channel; defaults to a temp file)

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

PLAN_PATH="${1:?usage: review-plan.sh <plan.json>}"
[[ -s "$PLAN_PATH" ]] || { echo "::error::plan file '$PLAN_PATH' missing or empty" >&2; exit 1; }
# Resolve to an absolute path so the rubric prompt can read it regardless of the
# engine's working directory.
PLAN_PATH="$(cd "$(dirname "$PLAN_PATH")" && pwd)/$(basename "$PLAN_PATH")"
export PLAN_PATH
DRY_RUN="${DRY_RUN:-false}"

# ── artifact-contract dispatch ────────────────────────────────────────────────
ARTIFACT_TYPE="plan_json"
CONTENT_REF="$PLAN_PATH"

REVIEW_RUBRIC=$(review_registry_lookup "$ARTIFACT_TYPE" rubric | tr -d '\r') || {
  echo "::error::no rubric registered for artifact_type=$ARTIFACT_TYPE"
  exit 1
}
REVIEW_OUTPUT_CHANNEL=$(review_registry_lookup "$ARTIFACT_TYPE" output_channel | tr -d '\r') || {
  echo "::error::no output_channel registered for artifact_type=$ARTIFACT_TYPE"
  exit 1
}

# The plan rubric is a single prompt file (the fixed critic checklist). Take the
# first cascade entry; the registry stores it as a one-element comma list so the
# field is uniform with pr_diff's multi-tier cascade.
IFS=',' read -ra REVIEW_RUBRIC_CASCADE <<< "$REVIEW_RUBRIC"
RUBRIC_PROMPT="${REVIEW_RUBRIC_CASCADE[0]}"

echo "==> reviewing plan: $PLAN_PATH"
echo "    artifact_type=$ARTIFACT_TYPE content_ref=$CONTENT_REF"
echo "    rubric=$REVIEW_RUBRIC"
echo "    output_channel=$REVIEW_OUTPUT_CHANNEL"

# ── run the rubric via engine.sh deep tier ────────────────────────────────────
# The prompt writes its findings JSON to $OUTPUT_FILE. run_agentic also tees the
# agent's stdout; capture it as a fallback in case the model printed the JSON to
# stdout instead of writing the file.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
OUTPUT_FILE="$WORK_DIR/findings.json"
export OUTPUT_FILE
: > "$OUTPUT_FILE"

run_agentic "$REPO_ROOT/$RUBRIC_PROMPT" "$ENGINE_DEEP_MODEL" "deep" > "$WORK_DIR/raw.out" 2>"$WORK_DIR/raw.err" || {
  echo "::error::plan rubric run exited non-zero. Error log:" >&2
  cat "$WORK_DIR/raw.err" >&2
  exit 1
}

# Resolve the findings JSON: prefer the file the prompt wrote; fall back to
# stdout if the model printed the JSON there instead.
if ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
  if jq empty "$WORK_DIR/raw.out" 2>/dev/null; then
    cp "$WORK_DIR/raw.out" "$OUTPUT_FILE"
  else
    echo "::error::plan rubric did not produce valid findings JSON. Output log:" >&2
    cat "$WORK_DIR/raw.out" >&2
    echo "Error log:" >&2
    cat "$WORK_DIR/raw.err" >&2
    exit 1
  fi
fi

# ── deliver via the resolved structured-findings channel ──────────────────────
# Default the planner-consumption path to a stable temp file OUTSIDE WORK_DIR
# when the caller didn't pin one — WORK_DIR is removed by the EXIT trap, so any
# path within it would be deleted before the caller can consume the findings.
if [[ -z "${PLAN_FINDINGS_OUTPUT:-}" ]]; then
  PLAN_FINDINGS_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/plan-findings.XXXXXX.json")"
fi
export PLAN_FINDINGS_OUTPUT
bash "$REPO_ROOT/$REVIEW_OUTPUT_CHANNEL" "$CONTENT_REF" "$OUTPUT_FILE" "$DRY_RUN"
