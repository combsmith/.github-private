#!/usr/bin/env bash
# route-findings.sh — fold UNRESOLVED plan-critic findings into a plan.json's
# open_questions (issue #603, epic #597 Phase 2).
#
# The bounded critic pass (prompts/plan-review.md, scoring the fixed rubric from
# prompts/bmad/scrum-master.md) emits structured findings. Bob folds the findings
# he can resolve back into plan.json directly. The findings he CANNOT resolve are
# passed to this helper, which appends one open_questions object per finding so
# they gate per the open-questions-as-gate mechanism (#682) and name which stories
# they concern (affected_story_ids).
#
# This is a pure, deterministic transform — no LLM, no network. Resolvability is
# Bob's judgement (which findings he passes here); the mapping below is fixed:
#   - question            <- "[<check>] <finding>"
#   - affected_story_ids  <- [story_id] (or [] when story_id is null / epic-level)
#   - blocking            <- true for major|critical findings, false otherwise
#                            (major/critical => the idea is not yet plannable; it
#                            halts materialization until a human answers — #682)
#
# Pre-existing open_questions on the plan are preserved; routed questions are
# appended after them.
#
# Usage:   route-findings.sh <plan.json> <unresolved-findings.json>
# Output:  the updated plan JSON on stdout (caller redirects, then re-validates
#          with validate-plan.py).
#
# The findings JSON is the critic's output shape (see prompts/plan-review.md):
#   { "findings": [ { "check", "story_id", "severity", "finding" }, ... ] }

set -euo pipefail

PLAN_PATH="${1:?usage: route-findings.sh <plan.json> <unresolved-findings.json>}"
FINDINGS_PATH="${2:?usage: route-findings.sh <plan.json> <unresolved-findings.json>}"

[[ -s "$PLAN_PATH" ]] || { echo "::error::plan file '$PLAN_PATH' missing or empty" >&2; exit 1; }
[[ -s "$FINDINGS_PATH" ]] || { echo "::error::findings file '$FINDINGS_PATH' missing or empty" >&2; exit 1; }
jq empty "$PLAN_PATH" 2>/dev/null || { echo "::error::plan '$PLAN_PATH' is not valid JSON" >&2; exit 1; }
jq empty "$FINDINGS_PATH" 2>/dev/null || { echo "::error::findings '$FINDINGS_PATH' is not valid JSON" >&2; exit 1; }

# Build the open_questions objects from the findings, then append them to any
# pre-existing open_questions on the plan. story_id may be a number or null; a
# null (epic/plan-level) finding routes to an empty affected_story_ids.
jq \
  --slurpfile findings "$FINDINGS_PATH" \
  '
  ($findings[0].findings // []) as $f
  | (.open_questions // []) as $existing
  | ($f | map({
      question: ("[" + (.check // "finding") + "] " + (.finding // "")),
      affected_story_ids: (if (.story_id == null) then [] else [.story_id] end),
      blocking: ((.severity // "") | (. == "major" or . == "critical"))
    })) as $routed
  | .open_questions = ($existing + $routed)
  ' "$PLAN_PATH"
