#!/usr/bin/env bash
set -euo pipefail
# gate.sh — strict-improvement comparator for prompt-skills (#586, epic #581).
#
# Usage:
#   gate.sh <skill> <incumbent_file> <candidate_file>
#
# Scores an incumbent skill file and a candidate skill file against the SAME
# held-out set (evals/<skill>/holdout/cases.jsonl) by invoking run-eval.sh once
# per file with its SKILL_PROMPT_FILE override, then compares the two aggregate
# scores. The gate accepts the candidate (exit 0) ONLY when it STRICTLY beats the
# incumbent:
#
#     candidate_score > incumbent_score      (strict '>', never '>=')
#
# Ties AND regressions are rejected (exit 1). This is the core held-out-validation
# discipline of the idea: promoting a tie buys risk with no proven gain, so a
# proposed skill edit must demonstrably move the held-out score up, not merely
# hold it. The comparator is deterministic plumbing around run-eval.sh — it adds
# no scoring logic of its own and reads the held-out cases only through the
# scorer, which never writes them.
#
# Reward-hacking invariant (AC #4): the proposer may edit only the skill markdown
# being scored. It must never touch the held-out cases.jsonl or the judge prompt.
# This gate enforces the *score* side; tamper protection over evals/ is enforced
# separately by CODEOWNERS + holdout-guard.yml (#692). See
# docs/initiatives/skill-self-improvement.md.
#
# Env overrides (passed through to run-eval.sh so offline tests stay network-free):
#   EVAL_ENGINE_CMD   skill-under-test command (default: run_triage)
#   EVAL_JUDGE_CMD    llm-judge command        (default: run_triage)
#   EVALS_DIR         held-out cases root      (default: <repo>/evals); read-only
#
# Output: a single JSON verdict object on stdout, e.g.
#   {"skill":"triage","incumbent_score":0.5,"candidate_score":1,
#    "accepted":true,"verdict":"accept"}
#
# Exit codes:
#   0  candidate STRICTLY beats incumbent (accept)
#   1  tie or regression (reject)
#   2  hard error (bad usage / missing file / scorer hard-failed)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCORER="$SCRIPT_DIR/run-eval.sh"

die() {
  # stdout (not stderr) so the reason is visible in workflow logs and capturable
  # by tests; the ::error:: prefix still renders as a GitHub annotation.
  echo "::error::strict-improvement gate: $1"
  exit 2
}

command -v jq >/dev/null 2>&1 || die "jq is required but not installed"
[[ -f "$SCORER" ]] || die "scorer not found (expected $SCORER)"

skill="${1:-}"
incumbent="${2:-}"
candidate="${3:-}"
if [[ -z "$skill" ]] || [[ -z "$incumbent" ]] || [[ -z "$candidate" ]]; then
  die "usage: gate.sh <skill> <incumbent_file> <candidate_file>"
fi
[[ -f "$incumbent" ]] || die "incumbent skill file not found: $incumbent"
[[ -f "$candidate" ]] || die "candidate skill file not found: $candidate"

# run_scorer <skill_file> — run the held-out scorer over one skill file and echo
# its full JSON report. run-eval.sh exits 1 when some cases fail (a legitimate
# score < 1) and 2 on a hard error; the function returns success for the former
# and failure for the latter, so the caller can `|| die` at top level (keeping the
# ::error:: annotation on real stdout rather than swallowed in a substitution).
run_scorer() {
  local skill_file="$1" rc
  local out
  if out="$(SKILL_PROMPT_FILE="$skill_file" bash "$SCORER" "$skill")"; then
    rc=0
  else
    rc=$?
  fi
  printf '%s' "$out"
  [ "$rc" -le 1 ]
}

incumbent_report="$(run_scorer "$incumbent")" || die "scorer hard-failed scoring incumbent $incumbent"
candidate_report="$(run_scorer "$candidate")" || die "scorer hard-failed scoring candidate $candidate"

# Validate the numeric score at top level (not inside a substitution) so a die
# here keeps its ::error:: annotation on real stdout.
jq -e 'has("score") and (.score|type=="number")' <<<"$incumbent_report" >/dev/null 2>&1 \
  || die "scorer produced no numeric score for the incumbent"
jq -e 'has("score") and (.score|type=="number")' <<<"$candidate_report" >/dev/null 2>&1 \
  || die "scorer produced no numeric score for the candidate"
incumbent_score="$(jq -r '.score' <<<"$incumbent_report")"
candidate_score="$(jq -r '.score' <<<"$candidate_report")"

# Strict beat: '>' rejects ties and regressions alike.
accepted="$(jq -n --argjson c "$candidate_score" --argjson i "$incumbent_score" '$c > $i')"
if [[ "$accepted" = true ]]; then
  verdict="accept"
else
  verdict="reject"
fi

jq -cn \
  --arg skill "$skill" \
  --argjson incumbent_score "$incumbent_score" \
  --argjson candidate_score "$candidate_score" \
  --argjson accepted "$accepted" \
  --arg verdict "$verdict" \
  '{skill:$skill, incumbent_score:$incumbent_score, candidate_score:$candidate_score, accepted:$accepted, verdict:$verdict}'

if [[ "$accepted" = true ]]; then
  echo "::notice::strict-improvement gate: ACCEPT — candidate $candidate_score > incumbent $incumbent_score" >&2
  exit 0
fi
echo "::error::strict-improvement gate: REJECT — candidate $candidate_score is not strictly greater than incumbent $incumbent_score (ties and regressions are rejected)" >&2
exit 1
