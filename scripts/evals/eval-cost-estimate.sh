#!/usr/bin/env bash
set -euo pipefail
# eval-cost-estimate.sh — price the engine-parity decision for a persona eval.
#
# Usage:
#   eval-cost-estimate.sh <skill>
#
# Enabling engine parity (#1686) scores a persona's held-out set on the Opus tier
# the persona runtime uses instead of the Haiku-tier run_triage default. Opus is
# materially more expensive per token, so turning parity on for a recurring
# scheduled eval (skill-eval-report.yml) is a PRICED decision, not a free one. This
# script states that price BEFORE it is incurred: per-run USD at the declared tier,
# the Haiku baseline, and the delta between them — for the held-out case count.
#
# Rates are DATA, never code (AGENTS.md "Cost reporting"): every USD figure is
# derived from scripts/lib/model-pricing.tsv via scripts/lib/model-pricing.sh's
# cost_usd. Remove/blank that table and this script fails loudly rather than
# inventing a rate. Model identities (Haiku triage / Opus deep) come from
# scripts/engine.sh so they can never drift from the tiers the harness actually
# runs. Only the per-call TOKEN counts are assumptions — rough by nature, and
# overridable via env so the estimate can be re-priced without editing the script.
#
# Env overrides:
#   EVALS_DIR                 held-out cases root (default: <repo>/evals)
#   EVAL_COST_INPUT_TOKENS    assumed input tokens per skill (engine) call  (default 12000)
#   EVAL_COST_OUTPUT_TOKENS   assumed output tokens per skill (engine) call (default 1200)
#   EVAL_COST_JUDGE_INPUT_TOKENS   assumed input tokens per judge call   (default 3000)
#   EVAL_COST_JUDGE_OUTPUT_TOKENS  assumed output tokens per judge call  (default 300)
#   PRICING_TABLE             price table path (honored by model-pricing.sh)
#
# Emits one machine-readable JSON object to stdout; a human summary to stderr.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EVALS_DIR="${EVALS_DIR:-$REPO_ROOT/evals}"

die() { echo "::error::eval-cost-estimate: $1" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq is required but not installed"

skill="${1:-}"
[[ -n "$skill" ]] || die "usage: eval-cost-estimate.sh <skill>"

cases_file="$EVALS_DIR/$skill/holdout/cases.jsonl"
[[ -f "$cases_file" ]] || die "no held-out cases for '$skill' (expected $cases_file)"

# Declared tier (default triage) — same field run-eval.sh reads.
scorer_config="$EVALS_DIR/$skill/scorer.json"
declared_tier="triage"
if [[ -f "$scorer_config" ]]; then
  declared_tier="$(jq -r '.engine // "triage"' "$scorer_config")"
fi
case "$declared_tier" in
  triage|persona) ;;
  *) die "unknown engine tier '$declared_tier' for '$skill' (expected: triage, persona)" ;;
esac

# Held-out case count (non-blank JSONL lines).
n_cases="$(awk 'NF { c++ } END { print c + 0 }' "$cases_file")"

# Model identities from the same source the harness runs (engine.sh init line -> stderr
# so stdout stays clean JSON). Under the default claude engine these are the Haiku
# triage model and the Opus deep model — exactly the parity comparison.
# shellcheck source=../engine.sh
source "$REPO_ROOT/scripts/engine.sh" >&2
# shellcheck source=../lib/model-pricing.sh
source "$REPO_ROOT/scripts/lib/model-pricing.sh"

triage_model="$ENGINE_TRIAGE_MODEL"
case "$declared_tier" in
  persona) tier_model="$ENGINE_DEEP_MODEL" ;;
  triage)  tier_model="$ENGINE_TRIAGE_MODEL" ;;
esac

in_tok="${EVAL_COST_INPUT_TOKENS:-12000}"
out_tok="${EVAL_COST_OUTPUT_TOKENS:-1200}"
judge_in="${EVAL_COST_JUDGE_INPUT_TOKENS:-3000}"
judge_out="${EVAL_COST_JUDGE_OUTPUT_TOKENS:-300}"

# Per-call USD from the price table. An empty result means the model has no priced
# row (e.g. the table was removed) — surface it, never treat as $0.
price_call() {
  local model="$1" i="$2" o="$3" usd
  usd="$(cost_usd "$model" "$i" 0 "$o")"
  [[ -n "$usd" ]] || die "no price row for model '$model' — cannot estimate cost (is $PRICING_TABLE present?)"
  printf '%s' "$usd"
}

engine_parity_pc="$(price_call "$tier_model"   "$in_tok" "$out_tok")"
engine_triage_pc="$(price_call "$triage_model" "$in_tok" "$out_tok")"
judge_pc="$(price_call "$triage_model" "$judge_in" "$judge_out")"

# Aggregate over the held-out set: each case is one engine call + one judge call.
# The judge runs at the Haiku tier in BOTH scenarios, so it cancels out of the
# delta — but it is included in the absolute per-run figures for an honest total.
read -r parity_run triage_run delta_run <<<"$(awk -v n="$n_cases" -v ep="$engine_parity_pc" -v et="$engine_triage_pc" -v j="$judge_pc" \
    'BEGIN {
       parity = n * (ep + j);
       triage = n * (et + j);
       printf "%.2f %.2f %.2f", parity, triage, parity - triage
     }')"

jq -cn \
  --arg skill "$skill" \
  --argjson cases "$n_cases" \
  --arg declared_tier "$declared_tier" \
  --arg tier_model "$tier_model" \
  --arg triage_model "$triage_model" \
  --arg parity_run "$parity_run" \
  --arg triage_run "$triage_run" \
  --arg delta "$delta_run" \
  --argjson in_tok "$in_tok" --argjson out_tok "$out_tok" \
  --argjson judge_in "$judge_in" --argjson judge_out "$judge_out" \
  '{
     skill: $skill,
     cases: $cases,
     declared_tier: $declared_tier,
     tier_model: $tier_model,
     baseline_model: $triage_model,
     parity_run_usd: $parity_run,
     triage_run_usd: $triage_run,
     delta_usd: $delta,
     assumptions: {
       input_tokens_per_call: $in_tok,
       output_tokens_per_call: $out_tok,
       judge_input_tokens_per_call: $judge_in,
       judge_output_tokens_per_call: $judge_out
     }
   }'

{
  echo ""
  echo "Eval cost estimate — $skill ($n_cases held-out cases, tier: $declared_tier)"
  echo "  parity run ($tier_model):  \$$parity_run"
  echo "  triage run ($triage_model): \$$triage_run"
  echo "  delta (Haiku -> parity):   \$$delta_run per run"
  echo "  (token counts are assumptions; rates from $PRICING_TABLE)"
} >&2
