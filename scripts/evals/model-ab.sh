#!/usr/bin/env bash
set -euo pipefail
# model-ab.sh — held-out MODEL non-regression comparator (#1097, epic #1095).
#
# Usage:
#   model-ab.sh <candidate_model> <incumbent_model> [skill ...]
#
# Scores a CANDIDATE model (e.g. a next-gen sonnet id) against an INCUMBENT
# model (the current sonnet) on one or more held-out sets (default: triage and
# deep-review) by driving scripts/evals/run-eval.sh once per (model, set) arm.
# It reads the two aggregate scores directly and applies a `>=` NON-REGRESSION
# bar per set — deliberately NOT gate.sh's strict `>` (that is the skill-edit
# improvement gate; here the bar is model-replacement non-regression).
#
# This is a MODEL A/B, not a skill A/B: the skill markdown under test is held at
# its incumbent file (SKILL_PROMPT_FILE is left at run-eval.sh's default). Only
# the GENERATOR model varies between arms.
#
# Generator pinning (AC #1): the generator model is pinned per arm by exporting
# CLAUDE_TRIAGE_MODEL_CHAIN=<arm_model> (a single-id chain) into the run-eval.sh
# subprocess. run-eval.sh's default EVAL_ENGINE_CMD (run_triage) reads that chain
# (set_engine_config preserves a pre-set chain), so it routes to exactly the arm's
# model. This holds for BOTH sets: deep-review's generator is also driven through
# run_triage, so pinning the triage chain pins the deep-review generator too.
#
# Judge held FIXED (confound control): deep-review is llm-judge mode, so its score
# depends on BOTH the generator AND the judge model. If pinning the generator also
# moved the judge, a judge-model change would confound the comparison. This script
# therefore wraps EVAL_JUDGE_CMD in a shim that re-pins the chain to a FIXED judge
# model (AB_JUDGE_MODEL, a fixed sonnet id) before delegating — so only the
# generator varies across the two arms. (triage is deterministic and never invokes
# the judge, so the shim is inert there.)
#
# Infra vs. quality (AC #4, run-eval.sh #920 semantics): each arm's run-eval.sh
# exit is classified — 0/1 = SCORED (the aggregate score is meaningful; 0 = all
# pass, 1 = a quality miss within that arm), 2 = INFRA/un-scored (every model in
# the fallback chain throttled, or a hard error — the model never answered). An
# un-scored arm marks its set `infra`: it is re-run, NEVER recorded as a candidate
# regression. A throttle must not open a false quality-regression verdict.
#
# Held-out immutability (AC #2): the read-only artifacts — each set's
# holdout/cases.jsonl, its scorer.json, and the judge prompt (evals/judge.md) —
# are checksummed before and after the run. Any mutation is a hard error (exit 2).
# run-eval.sh never writes cases; this guard is defense-in-depth confirming the
# reward-hacking / held-out-immutability invariant byte-for-byte.
#
# Env overrides (mirroring gate.sh, so offline tests stay network-free):
#   AB_JUDGE_MODEL   fixed judge model held across both arms (default: a fixed sonnet id)
#   EVAL_ENGINE_CMD  base generator command (default: run_triage)
#   EVAL_JUDGE_CMD   base judge command      (default: run_triage)
#   EVALS_DIR        held-out cases root      (default: <repo>/evals); read-only
#
# Output: a single JSON evidence object on stdout (per-(model,set) scores + the
# non-regression verdict) — the go/no-go evidence input for Phase 3 (AC #5).
#
# Exit codes:
#   0  accept — candidate scored >= incumbent on EVERY set (no regression)
#   1  regression — candidate scored below incumbent on >=1 fully-scored set (BLOCKING)
#   2  infra/un-scored on >=1 set (re-run; NOT a regression) OR a hard error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCORER="$SCRIPT_DIR/run-eval.sh"

EVALS_DIR="${EVALS_DIR:-$REPO_ROOT/evals}"
AB_JUDGE_MODEL="${AB_JUDGE_MODEL:-claude-sonnet-4-6}" # model-pin-ok: eval judge held FIXED across arms for confound control (must not float with a family)
EVAL_ENGINE_CMD="${EVAL_ENGINE_CMD:-run_triage}"
EVAL_JUDGE_CMD="${EVAL_JUDGE_CMD:-run_triage}"

die() {
  # stdout (not stderr) so the reason is visible in workflow logs and capturable
  # by tests; the ::error:: prefix still renders as a GitHub annotation.
  echo "::error::model-ab: $1"
  exit 2
}

command -v jq        >/dev/null 2>&1 || die "jq is required but not installed"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required but not installed"
[ -f "$SCORER" ] || die "scorer not found (expected $SCORER)"

CANDIDATE="${1:-}"
INCUMBENT="${2:-}"
if [ -z "$CANDIDATE" ] || [ -z "$INCUMBENT" ]; then
  die "usage: model-ab.sh <candidate_model> <incumbent_model> [skill ...]"
fi
shift 2 || true

# Default matrix: both held-out sets named in the story.
if [ "$#" -gt 0 ]; then
  SKILLS=("$@")
else
  SKILLS=(triage deep-review)
fi

# _snapshot — emit a stable checksum manifest of the read-only held-out artifacts
# (each set's holdout cases + scorer.json, plus the shared judge prompt). Compared
# before/after the run to confirm byte-immutability (AC #2).
_snapshot() {
  local skill f
  for skill in "${SKILLS[@]}"; do
    f="$EVALS_DIR/$skill/holdout/cases.jsonl"; [ -f "$f" ] && sha256sum "$f"
    f="$EVALS_DIR/$skill/scorer.json";         [ -f "$f" ] && sha256sum "$f"
  done
  [ -f "$EVALS_DIR/judge.md" ] && sha256sum "$EVALS_DIR/judge.md"
  return 0
}

# Judge shim: re-pins the model chain to the FIXED judge model before delegating
# to the base judge command, so the deep-review judge model never varies with the
# generator arm. When the base command is an external stub/script it is exec'd
# directly; when it is a sourced engine function (run_triage) the shim sources
# engine.sh to define it.
JUDGE_SHIM="$(mktemp)"
cat >"$JUDGE_SHIM" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export REVIEW_ENGINE=claude
export CLAUDE_TRIAGE_MODEL_CHAIN="$AB_JUDGE_MODEL"
base="$EVAL_JUDGE_CMD"
if command -v "\$base" >/dev/null 2>&1; then
  exec "\$base" "\$@"
fi
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/engine.sh" >&2
"\$base" "\$@"
EOF
chmod +x "$JUDGE_SHIM"
trap 'rm -f "$JUDGE_SHIM"' EXIT

# _is_scored <rc> — run-eval.sh exited with a MEANINGFUL aggregate score (0 = all
# pass, 1 = a quality miss). Exit 2 is infra/un-scored (throttle or hard error).
_is_scored() { [ "$1" -eq 0 ] || [ "$1" -eq 1 ]; }

# run_arm <skill> <model> — score one (skill, model) arm through run-eval.sh with
# the GENERATOR pinned to <model> and the judge held on the fixed model. Sets the
# globals ARM_OUT (report JSON or ::error:: text) and ARM_RC (run-eval exit code).
run_arm() {
  local skill="$1" model="$2" out rc=0
  if out="$(
        REVIEW_ENGINE=claude \
        CLAUDE_TRIAGE_MODEL_CHAIN="$model" \
        EVAL_ENGINE_CMD="$EVAL_ENGINE_CMD" \
        EVAL_JUDGE_CMD="$JUDGE_SHIM" \
        EVALS_DIR="$EVALS_DIR" \
        bash "$SCORER" "$skill"
      )"; then
    rc=0
  else
    rc=$?
  fi
  ARM_OUT="$out"
  ARM_RC="$rc"
}

before="$(_snapshot)"

set_objs=()
saw_regression=false
saw_infra=false

for skill in "${SKILLS[@]}"; do
  run_arm "$skill" "$CANDIDATE"; c_out="$ARM_OUT"; c_rc="$ARM_RC"
  run_arm "$skill" "$INCUMBENT"; i_out="$ARM_OUT"; i_rc="$ARM_RC"

  c_scored=false; if _is_scored "$c_rc"; then c_scored=true; fi
  i_scored=false; if _is_scored "$i_rc"; then i_scored=true; fi

  c_score=null; i_score=null
  if [ "$c_scored" = true ]; then
    c_score="$(jq -r '.score // empty' <<<"$c_out" 2>/dev/null || true)"; c_score="${c_score:-null}"
  fi
  if [ "$i_scored" = true ]; then
    i_score="$(jq -r '.score // empty' <<<"$i_out" 2>/dev/null || true)"; i_score="${i_score:-null}"
  fi

  non_regression=null
  if [ "$c_scored" = true ] && [ "$i_scored" = true ] \
     && [ "$c_score" != null ] && [ "$i_score" != null ]; then
    # Non-regression bar: candidate must MATCH OR BEAT the incumbent ('>=').
    non_regression="$(jq -n --argjson c "$c_score" --argjson i "$i_score" '$c >= $i')"
    if [ "$non_regression" = true ]; then
      outcome="pass"
    else
      outcome="regression"
      saw_regression=true
    fi
  else
    # At least one arm was never scored — un-scored set: re-run, not a regression.
    outcome="infra"
    saw_infra=true
  fi

  set_objs+=("$(jq -n \
    --arg skill "$skill" \
    --argjson cs "$c_score" --argjson crc "$c_rc" --argjson csc "$c_scored" \
    --argjson is "$i_score" --argjson irc "$i_rc" --argjson isc "$i_scored" \
    --argjson nr "$non_regression" \
    --arg outcome "$outcome" \
    '{skill:$skill,
      candidate_score:$cs, candidate_rc:$crc, candidate_scored:$csc,
      incumbent_score:$is, incumbent_rc:$irc, incumbent_scored:$isc,
      non_regression:$nr, outcome:$outcome}')")
done

# Held-out immutability guard (AC #2): the read-only artifacts must be byte-for-
# byte unchanged. run-eval.sh never writes cases; a diff here means something
# tampered with the held-out set mid-run — a hard error, never a silent pass.
after="$(_snapshot)"
if [ "$before" != "$after" ]; then
  die "held-out artifacts changed during the run (immutability violation)"
fi

# Verdict precedence: a definite regression on a fully-scored set is BLOCKING and
# outranks an un-scored (infra) set; an infra-only run is re-run (never accept).
if [ "$saw_regression" = true ]; then
  verdict="regression"
elif [ "$saw_infra" = true ]; then
  verdict="infra"
else
  verdict="accept"
fi
accepted=false; [ "$verdict" = accept ] && accepted=true

jq -n \
  --arg candidate_model "$CANDIDATE" \
  --arg incumbent_model "$INCUMBENT" \
  --arg judge_model "$AB_JUDGE_MODEL" \
  --arg verdict "$verdict" \
  --argjson accepted "$accepted" \
  --argjson sets "$(printf '%s\n' "${set_objs[@]}" | jq -s '.')" \
  '{candidate_model:$candidate_model, incumbent_model:$incumbent_model,
    judge_model:$judge_model, verdict:$verdict, accepted:$accepted, sets:$sets}'

case "$verdict" in
  accept)     exit 0 ;;
  regression) exit 1 ;;
  infra)      exit 2 ;;
esac
