#!/usr/bin/env bash
set -euo pipefail
# Engine abstraction layer for LLM invocations.
# Supports: claude, gemini, copilot
#
# Sourced by review-one-pr.sh — provides:
#   run_triage <prompt_file>       — no-tool tier (stdout capture)
#   run_agentic <prompt_file> <model> [tier]  — full-tool tier (stdout)
#   run_duck <prompt_file> <model>     — cross-engine adversarial (stdout)
#   ENGINE_* env vars for model names and labels
#   DUCK_ENGINE / DUCK_MODEL for rubber-duck cross-engine review
#
# Rate-limit fallback (two layers, applied in order):
#   1. In-Claude model fallback — per-tier CLAUDE_*_MODEL_CHAIN walks alternate
#      Claude models (e.g. sonnet → opus) before declaring the provider
#      rate-limited. Each Claude model has its own TPM/RPM bucket, so swapping
#      models often recovers without leaving the provider. Does NOT help when
#      the daily subscription cap is exhausted (cap is shared across all Claude
#      models — see issue #206 for the proactive headroom guard).
#   2. Cross-provider fallback — run_writer_with_fallback / review-batch.sh
#      walk the configured engine chain (AI_ENGINES, default claude → gemini →
#      copilot; see scripts/lib/engine-chain.sh) only after the in-engine chain
#      is fully rate-limited (exit code 2 from the engine-layer call).
# Sonnet 5 rate-limit equalization (#1099): equalization makes each model's
# RPM/TPM bucket the same SIZE across tiers, but does NOT merge them into one
# shared bucket — layer-1 recovery above depends on the buckets being SEPARATE,
# not on differing sizes, so the sonnet → opus hop stays useful and is retained.
# It changes only per-model rate LIMITS, so it has no bearing on the shared
# daily subscription cap (#206), which layer-2 alone covers via the exit-2 path.
#
# Token logging (opt-in):
#   Set TOKEN_LOG_FILE=<path> to capture per-call JSONL token records.
#   TOKEN_WORKFLOW — workflow label for records (default: "unknown").
#   Records are written via scripts/lib/token-metrics.sh (estimate-based).
#   Unset → zero overhead, zero behaviour change.

# Configured engine chain (AI_ENGINES): which engines are enabled and in what
# order. The primary is REVIEW_ENGINE when that is set AND enabled, otherwise
# the first engine in AI_ENGINES — so a disabled engine is never used, even when
# a legacy REVIEW_ENGINE / DEV_LEAD_ENGINE variable still names it.
_ENGINE_CHAIN_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/engine-chain.sh"
# shellcheck source=lib/engine-chain.sh
[ -f "$_ENGINE_CHAIN_LIB" ] && source "$_ENGINE_CHAIN_LIB"
unset _ENGINE_CHAIN_LIB
if declare -F ai_engine_primary >/dev/null 2>&1; then
  _requested_engine="${REVIEW_ENGINE:-}"
  REVIEW_ENGINE="$(ai_engine_primary "$_requested_engine")"
  if [ -n "$_requested_engine" ] && [ "$_requested_engine" != "$REVIEW_ENGINE" ]; then
    echo "::warning::REVIEW_ENGINE=$_requested_engine is not enabled in AI_ENGINES ($(ai_engine_chain)) — using $REVIEW_ENGINE" >&2
  fi
  unset _requested_engine
  # Report an unusable AI_ENGINES here too: dev-lead sources engine.sh without
  # running validate_engines. The exported flag keeps it to one warning per run.
  if [ -z "${AI_ENGINES_PROBLEM_REPORTED:-}" ]; then
    _chain_problem="$(ai_engine_chain_problem)"
    if [ -n "$_chain_problem" ]; then
      echo "::warning::$_chain_problem" >&2
      export AI_ENGINES_PROBLEM_REPORTED=1
    fi
    unset _chain_problem
  fi
else
  REVIEW_ENGINE="${REVIEW_ENGINE:-claude}"
fi
export REVIEW_ENGINE

# Each provider's model list (AI_MODELS_CLAUDE / AI_MODELS_GEMINI /
# AI_MODELS_COPILOT) and its defaults live in lib/engine-models.sh, so a retired
# or renamed model is an Actions-variable edit, not a code change.
_ENGINE_MODELS_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/engine-models.sh"
if [ ! -f "$_ENGINE_MODELS_LIB" ]; then
  echo "::error::engine.sh: missing $_ENGINE_MODELS_LIB (model lists and defaults)" >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck source=lib/engine-models.sh
source "$_ENGINE_MODELS_LIB"
unset _ENGINE_MODELS_LIB
if [ -z "${AI_MODELS_PROBLEM_REPORTED:-}" ]; then
  _models_problems="$(ai_models_problems)"
  if [ -n "$_models_problems" ]; then
    while IFS= read -r _models_line; do
      echo "::warning::$_models_line" >&2
    done <<< "$_models_problems"
    export AI_MODELS_PROBLEM_REPORTED=1
  fi
  unset _models_problems _models_line
fi
# Fable 5 is deprecated (#1901): warn once per run when a configured chain still
# names a claude-fable-* model, but still honour it (a stop-gap, not a rejection).
if [ -z "${AI_MODELS_FABLE_WARNED:-}" ]; then
  _fable_warn="$(ai_models_fable_deprecation)"
  if [ -n "$_fable_warn" ]; then
    echo "::warning::$_fable_warn" >&2
    export AI_MODELS_FABLE_WARNED=1
  fi
  unset _fable_warn
fi

# Cross-engine rubber-duck model (issue #773). The duck deliberately routes to
# Copilot/o4-mini even when the primary engine is NOT copilot (e.g. the default
# claude engine sets DUCK_ENGINE=copilot for adversarial diversity), so
# copilot_chat() may dereference COPILOT_API_MODEL regardless of REVIEW_ENGINE.
# Default it here — engine-agnostic — so the duck always has a model under
# `set -u`. The `copilot)` arm in set_engine_config re-applies the same default
# (idempotent) for the primary-engine path. Each Copilot call then sets the
# model of its own tier (ai_models_copilot_model); COPILOT_API_MODEL_DEFAULTED
# records that this value is our default, not the caller's override.
DEFAULT_COPILOT_API_MODEL="$(ai_models_copilot_model triage)"
if [ -z "${COPILOT_API_MODEL:-}" ] || [ "$COPILOT_API_MODEL" = "${COPILOT_API_MODEL_DEFAULTED:-}" ]; then
  COPILOT_API_MODEL="$DEFAULT_COPILOT_API_MODEL"
  COPILOT_API_MODEL_DEFAULTED="$DEFAULT_COPILOT_API_MODEL"
  export COPILOT_API_MODEL_DEFAULTED
fi
export COPILOT_API_MODEL

# Per-tier timeouts (seconds). The job-level cap (120min in dev-lead-reusable.yml)
# is a hang/stuck-run backstop — without per-tier timeouts a single hung model
# invocation burns the whole job and blocks every subsequent PR in the session.
# These are sized to MAXIMIZE legitimate runtime per stage (#1017, epic #901),
# NOT to bound token/runner cost. DEEP (deep agentic analysis) and ACTION (the
# writer tier) get the largest viable share; TRIAGE/DUCK stay small (lightweight
# read/classify + cross-engine review); AUDIT stays modest.
#
# Guardrail invariant (scripts/dev-lead-timeout-guardrail.sh + its bats test):
#   Σ(these defaults) + overhead_margin(900s) ≤ job timeout-minutes × 60
#   300 + 2400 + 1200 + 2100 + 300 = 6300s; 6300 + 900 = 7200s = 120min ✓
# so the tiers can never silently exceed the job backstop. Raising a tier here
# requires lowering another or raising the job cap, or the guardrail fails CI.
#
# Fleet note: petry-projects/.github leaves `vars.DEEP_TIMEOUT_SEC` (and
# ACTION_TIMEOUT_SEC) UNSET, so the workflow passes an empty value through and
# these engine defaults take effect. The raised DEEP default (was 600, now 2400)
# therefore applies fleet-wide unless a repo overrides it via its own `vars`.
TRIAGE_TIMEOUT_SEC="${TRIAGE_TIMEOUT_SEC:-300}"
DEEP_TIMEOUT_SEC="${DEEP_TIMEOUT_SEC:-2400}"
AUDIT_TIMEOUT_SEC="${AUDIT_TIMEOUT_SEC:-1200}"
ACTION_TIMEOUT_SEC="${ACTION_TIMEOUT_SEC:-2100}"
DUCK_TIMEOUT_SEC="${DUCK_TIMEOUT_SEC:-300}"

# Grace period after the per-call SIGTERM before `timeout` escalates to SIGKILL.
# Plain `timeout <sec>` only sends SIGTERM; GNU `timeout` then waits INDEFINITELY
# for a child that ignores it, so a wedged CLI can outlive its stage budget and
# blow through the job's timeout-minutes backstop (e.g. starving the model-ab
# matrix mid-A/B, #1952 cubic P2). `--kill-after` sends SIGKILL this long after
# the initial SIGTERM so no external-CLI call can outlive timeout_sec + grace,
# mirroring the probe step in model-ab.yml. Override via ENGINE_KILL_AFTER.
ENGINE_KILL_AFTER="${ENGINE_KILL_AFTER:-30s}"

# Retry config for transient errors. We treat exit codes that look like
# network/process flakiness (137/143=signal kills) as retryable. A per-tier
# stage timeout (124=GNU timeout) is NOT retried (#1028): re-running at the same
# budget just times out again, so it propagates and escalates instead. Rate-limit
# (engine-level) is NOT retryable here either — the workflow's engine-fallback
# handles that.
RETRY_MAX_ATTEMPTS="${RETRY_MAX_ATTEMPTS:-2}"   # total attempts including first
RETRY_BASE_DELAY_SEC="${RETRY_BASE_DELAY_SEC:-5}"

# Opt-in MCP (Model Context Protocol) config for the agentic review tiers.
# REVIEW_MCP_CONFIG — path to an MCP-servers JSON config file. When unset/empty
#   or not readable, the claude invocations gain NO new flags and behavior is
#   byte-for-byte unchanged for every existing adopter.
# REVIEW_MCP_ALLOWED_TOOLS — comma-separated MCP tool names (e.g.
#   "mcp__context7__*") merged into the per-tier --allowed-tools list so the
#   configured MCP tools are actually permitted. Default empty.
# REVIEW_MCP_DEBUG — when set to a non-empty value, the MCP-enabled claude tiers
#   add `--debug mcp` so the server handshake is logged to stderr, and a healthy
#   connection is surfaced as a ::notice:: (the failure path already emits a
#   ::warning::). Off by default — diagnostics only; never changes the verdict.
# Only the deep (run_agentic) and rubber-duck (run_duck) claude tiers receive
# this — the triage tier stays fast/restricted (--disallowed-tools only).
#
# Convention (issue #679): a repo enables MCP review by committing a config at
# the conventional path REVIEW_MCP_CONFIG_DEFAULT_PATH (default
# `.github/review-mcp.json`) — no edit to the org-template-synced workflow.
# An explicit REVIEW_MCP_CONFIG env value is honored as-is and takes precedence;
# otherwise we fall back to the conventional path ONLY when that file exists.
# When neither is present, REVIEW_MCP_CONFIG stays empty and MCP is off, so
# repos that don't opt in see no behavior change.
REVIEW_MCP_CONFIG_DEFAULT_PATH="${REVIEW_MCP_CONFIG_DEFAULT_PATH:-.github/review-mcp.json}"
if [ -z "${REVIEW_MCP_CONFIG+x}" ] && [ -f "$REVIEW_MCP_CONFIG_DEFAULT_PATH" ]; then
  REVIEW_MCP_CONFIG="$REVIEW_MCP_CONFIG_DEFAULT_PATH"
fi
REVIEW_MCP_CONFIG="${REVIEW_MCP_CONFIG:-}"
REVIEW_MCP_ALLOWED_TOOLS="${REVIEW_MCP_ALLOWED_TOOLS:-}"
REVIEW_MCP_DEBUG="${REVIEW_MCP_DEBUG:-}"
# Export so the resolved knob survives into any review subprocess. review-one-pr.sh
# and review-batch.sh source this file, so run_agentic/run_duck see it in-process;
# the export also covers any future invocation via a separate child shell.
export REVIEW_MCP_CONFIG REVIEW_MCP_ALLOWED_TOOLS REVIEW_MCP_DEBUG

# _ai_duck_engines — AI_DUCK_ENGINE as a list: its entries lower-cased, in
# order, space-separated. Commas and any whitespace separate entries, as in
# AI_ENGINES ("gemini,claude" = a Gemini duck, then a Claude one).
_ai_duck_engines() {
  printf '%s' "${AI_DUCK_ENGINE:-}" | tr ',\n\r\t' '    ' | tr '[:upper:]' '[:lower:]' \
    | tr -s ' ' | sed 's/^ //; s/ $//'
}

# _ai_duck_first — the first entry of AI_DUCK_ENGINE (empty when unset).
_ai_duck_first() {
  local list
  list="$(_ai_duck_engines)"
  printf '%s' "${list%% *}"
}

# _duck_model_for <engine> — the rubber-duck model for <engine>. AI_DUCK_MODEL
# applies only when <engine> is the first engine AI_DUCK_ENGINE lists (a model
# id is engine-specific, so it must never follow the duck onto another engine).
_duck_model_for() {
  local engine="$1" wanted
  wanted="$(_ai_duck_first)"
  if [ -n "${AI_DUCK_MODEL:-}" ] && [ "$engine" = "$wanted" ]; then
    printf '%s' "$AI_DUCK_MODEL"
    return 0
  fi
  local m
  case "$engine" in
    claude)
      m="$(ai_models_chain claude duck)" ;;
    gemini)
      # AI_MODELS_GEMINI duck=…, else the triage chain's primary model.
      m="$(ai_models_gemini_chain duck)" ;;
    copilot)
      # The id without its vendor prefix, as ENGINE_*_MODEL (token records).
      m="$(ai_models_copilot_model duck)"
      m="${m#*/}" ;;
  esac
  _engine_chain_first "${m:-}"
}

# _engine_chain_first <chain> — the first model of a comma-separated chain,
# whitespace trimmed (a chain from an env var may carry spaces).
_engine_chain_first() {
  local first="${1%%,*}"
  printf '%s' "${first//[[:space:]]/}"
}

# duck_engine_candidates — prints one "<engine> <model>" line per rubber-duck
# engine to try, in order; prints nothing when no usable engine is left.
#   1. The engines AI_DUCK_ENGINE lists (e.g. "gemini,claude"), in order. An
#      entry "none" (or off/disabled/false) ends the list: nothing after it,
#      and nothing chosen automatically, is tried. AI_DUCK_ENGINE=none alone
#      turns the duck off.
#   2. set_engine_config's cross-engine default (DUCK_ENGINE / DUCK_MODEL).
#   3. The other engines in AI_ENGINES order, except the primary REVIEW_ENGINE.
# Only enabled, available engines are listed. "Available" is the
# validate_engines pre-flight flag (unset counts as available) and
# AI_ENGINES_RATE_LIMITED, so a disabled or dead engine (e.g. Copilot on a
# classic PAT) is skipped instead of failing on every review. A listed engine
# that is skipped, or an unknown entry, logs one ::warning::.
duck_engine_candidates() {
  local t e m out="" stop=0
  for t in $(_ai_duck_engines); do
    case "$t" in
      none|off|disabled|false)
        stop=1
        break ;;
      claude|gemini|copilot)
        [[ " $out " == *" $t "* ]] && continue
        if ai_engine_available "$t"; then
          out="$out $t"
        else
          echo "::warning::AI_DUCK_ENGINE lists $t, which is disabled or unavailable — skipping it" >&2
        fi ;;
      *)
        echo "::warning::AI_DUCK_ENGINE='${AI_DUCK_ENGINE}': '$t' is not a known engine (claude, gemini, copilot, none) — skipping it" >&2 ;;
    esac
  done
  if [ "$stop" -eq 0 ]; then
    for e in ${DUCK_ENGINE:-} $(ai_engine_chain); do
      [[ " $out " == *" $e "* ]] && continue
      # The primary is a duck only when AI_DUCK_ENGINE lists it (same vendor,
      # other model); the cross-engine default never names the primary.
      [ "$e" = "${REVIEW_ENGINE:-}" ] && continue
      ai_engine_available "$e" && out="$out $e"
    done
  fi
  for e in $out; do
    if [ "$e" = "${DUCK_ENGINE:-}" ] && [ -n "${DUCK_MODEL:-}" ]; then
      m="$DUCK_MODEL"
    else
      m="$(_duck_model_for "$e")"
    fi
    printf '%s %s\n' "$e" "$m"
  done
}

# select_duck_engine — prints "<engine> <model>" for the first rubber-duck
# engine (duck_engine_candidates), or "none" when no usable engine is left.
select_duck_engine() {
  local first
  first="$(duck_engine_candidates)"
  first="${first%%$'\n'*}"
  printf '%s' "${first:-none}"
}

# _duck_label — the rubber duck's models for ENGINE_LABEL, in the order the duck
# tries them: the first model, then its fallbacks in brackets (e.g.
# "gemini-3.8-flash [sonnet 5.5]"), or "off" when no engine is left. It reads
# duck_engine_candidates, so the label names what the duck will actually try
# (AI_DUCK_ENGINE, the cross-engine default, then AI_ENGINES) instead of only
# the cross-engine default. It lists a Gemini duck only when the pre-flight
# probe passed (GEMINI_AVAILABLE=true), the same test review-one-pr.sh applies
# before it runs the duck, so an unset flag leaves Gemini out of both. The
# candidates' warnings are dropped here: the duck logs them itself when it runs.
_duck_label() {
  local e m chain=""
  if ! declare -F ai_engine_available >/dev/null 2>&1; then
    ai_model_label "${DUCK_MODEL:-}"
    return 0
  fi
  while read -r e m; do
    [ -n "$e" ] || continue
    [ "$e" = gemini ] && [ "${GEMINI_AVAILABLE:-}" != true ] && continue
    chain="${chain:+$chain,}${m:-$e}"
  done <<< "$(duck_engine_candidates 2>/dev/null)"
  if [ -n "$chain" ]; then
    ai_models_label_chain "$chain"
  else
    printf 'off'
  fi
}

set_engine_config() {
  case "$REVIEW_ENGINE" in
    claude)
      # Per-tier in-Claude model fallback chains (comma-separated). On a rate
      # limit a chain is walked left to right before the cross-provider fallback
      # (AI_ENGINES) kicks in; per-model TPM/RPM buckets are independent, so
      # swapping models within Claude often recovers without leaving the provider
      # (the subscription cap is shared — #206). Source, highest first: the
      # per-tier CLAUDE_<TIER>_MODEL_CHAIN env, then AI_MODELS_CLAUDE, then the
      # defaults in lib/engine-models.sh (where the model notes live: Sonnet 5 id
      # #1957, opus-5-5 deep #1898, opus-5-5 audit/single + Fable 5 deprecation
      # #1901, the effort-pin rule).
      CLAUDE_TRIAGE_MODEL_CHAIN="${CLAUDE_TRIAGE_MODEL_CHAIN:-$(ai_models_chain claude triage)}"
      CLAUDE_DEEP_MODEL_CHAIN="${CLAUDE_DEEP_MODEL_CHAIN:-$(ai_models_chain claude deep)}"
      CLAUDE_AUDIT_MODEL_CHAIN="${CLAUDE_AUDIT_MODEL_CHAIN:-$(ai_models_chain claude audit)}"
      CLAUDE_ACTION_MODEL_CHAIN="${CLAUDE_ACTION_MODEL_CHAIN:-$(ai_models_chain claude action)}"
      CLAUDE_SINGLE_MODEL_CHAIN="${CLAUDE_SINGLE_MODEL_CHAIN:-$(ai_models_chain claude single)}"
      # Each tier's primary model is the first entry of its chain.
      ENGINE_TRIAGE_MODEL="$(_engine_chain_first "$CLAUDE_TRIAGE_MODEL_CHAIN")"
      ENGINE_DEEP_MODEL="$(_engine_chain_first "$CLAUDE_DEEP_MODEL_CHAIN")"
      ENGINE_AUDIT_MODEL="$(_engine_chain_first "$CLAUDE_AUDIT_MODEL_CHAIN")"
      ENGINE_ACTION_MODEL="$(_engine_chain_first "$CLAUDE_ACTION_MODEL_CHAIN")"
      ENGINE_SINGLE_MODEL="$(_engine_chain_first "$CLAUDE_SINGLE_MODEL_CHAIN")"
      # Cross-engine rubber duck: use Copilot when Claude is primary
      DUCK_ENGINE="copilot"
      DUCK_MODEL="$(_duck_model_for copilot)"
      ENGINE_LABEL="triage: $(ai_models_label_chain "$CLAUDE_TRIAGE_MODEL_CHAIN") → deep: $(ai_models_label_chain "$CLAUDE_DEEP_MODEL_CHAIN") + duck: $(_duck_label) → audit: $(ai_models_label_chain "$CLAUDE_AUDIT_MODEL_CHAIN")"
      ENGINE_SINGLE_LABEL="single-reviewer mode: $(ai_models_label_chain "$CLAUDE_SINGLE_MODEL_CHAIN")"
      ;;
    gemini)
      # In-Gemini model chains (comma-separated, walked left to right on a rate
      # limit), one per tier: ai_models_gemini_chain <tier> (lib/engine-models.sh)
      # — GEMINI_FLASH_MODEL_CHAIN / GEMINI_PRO_MODEL_CHAIN, then AI_MODELS_GEMINI
      # (or the defaults) with GEMINI_FLASH_MODEL / GEMINI_PRO_MODEL, when set,
      # replacing just the first model. The call sites resolve the chain again, so
      # nothing computed here is exported.
      local _gtriage _gdeep _gaudit _gsingle
      _gtriage="$(ai_models_gemini_chain triage)"
      _gdeep="$(ai_models_gemini_chain deep)"
      _gaudit="$(ai_models_gemini_chain audit)"
      _gsingle="$(ai_models_gemini_chain single)"
      ENGINE_TRIAGE_MODEL="$(_engine_chain_first "$_gtriage")"
      ENGINE_DEEP_MODEL="$(_engine_chain_first "$_gdeep")"
      ENGINE_AUDIT_MODEL="$(_engine_chain_first "$_gaudit")"
      ENGINE_ACTION_MODEL="$(_engine_chain_first "$(ai_models_gemini_chain action)")"
      ENGINE_SINGLE_MODEL="$(_engine_chain_first "$_gsingle")"
      # Cross-engine rubber duck: use Claude for diversity
      DUCK_ENGINE="claude"
      DUCK_MODEL="$(_duck_model_for claude)"
      ENGINE_LABEL="triage: $(ai_models_label_chain "$_gtriage") → deep: $(ai_models_label_chain "$_gdeep") + duck: $(_duck_label) → audit: $(ai_models_label_chain "$_gaudit")"
      ENGINE_SINGLE_LABEL="single-reviewer mode: $(ai_models_label_chain "$_gsingle")"
      # Clear the Claude-only chain vars so callers that check them unconditionally
      # do not accidentally apply a stale Claude chain to the Gemini engine.
      CLAUDE_TRIAGE_MODEL_CHAIN=""
      CLAUDE_DEEP_MODEL_CHAIN=""
      CLAUDE_AUDIT_MODEL_CHAIN=""
      CLAUDE_ACTION_MODEL_CHAIN=""
      CLAUDE_SINGLE_MODEL_CHAIN=""
      ;;
    copilot)
      # One GitHub Models id per tier: ai_models_copilot_model <tier>
      # (lib/engine-models.sh) — COPILOT_API_MODEL when the caller set it (every
      # tier), else AI_MODELS_COPILOT, else openai/o4-mini. Each Copilot call
      # sets COPILOT_API_MODEL to its tier's model.
      COPILOT_API_MODEL="${COPILOT_API_MODEL:-$DEFAULT_COPILOT_API_MODEL}"
      # ENGINE_*_MODEL keep the id without its vendor prefix (openai/o4-mini →
      # o4-mini): token records and the pricing table key on it, so it must not
      # be the display label.
      local _cm
      _cm="$(ai_models_copilot_model triage)"; ENGINE_TRIAGE_MODEL="${_cm#*/}"
      _cm="$(ai_models_copilot_model deep)";   ENGINE_DEEP_MODEL="${_cm#*/}"
      _cm="$(ai_models_copilot_model audit)";  ENGINE_AUDIT_MODEL="${_cm#*/}"
      _cm="$(ai_models_copilot_model action)"; ENGINE_ACTION_MODEL="${_cm#*/}"
      _cm="$(ai_models_copilot_model single)"; ENGINE_SINGLE_MODEL="${_cm#*/}"
      # Cross-engine rubber duck: use Gemini when Copilot is primary
      DUCK_ENGINE="gemini"
      DUCK_MODEL="$(_duck_model_for gemini)"
      ENGINE_LABEL="triage: $(ai_model_label "$ENGINE_TRIAGE_MODEL") → deep: $(ai_model_label "$ENGINE_DEEP_MODEL") + duck: $(_duck_label) → audit: $(ai_model_label "$ENGINE_AUDIT_MODEL") (GitHub Models API)"
      ENGINE_SINGLE_LABEL="single-reviewer mode: $(ai_model_label "$ENGINE_SINGLE_MODEL") (GitHub Models API)"
      # No in-engine chain for Copilot — single GitHub Models endpoint.
      CLAUDE_TRIAGE_MODEL_CHAIN=""
      CLAUDE_DEEP_MODEL_CHAIN=""
      CLAUDE_AUDIT_MODEL_CHAIN=""
      CLAUDE_ACTION_MODEL_CHAIN=""
      CLAUDE_SINGLE_MODEL_CHAIN=""
      ;;
    *)
      echo "::error::Unknown REVIEW_ENGINE='$REVIEW_ENGINE' (expected: claude, gemini, or copilot)"
      exit 1
      ;;
  esac

  # GitHub Models API model identifier for the copilot engine — must match a
  # model available at https://models.github.ai (see GitHub Models marketplace).
  # Override via COPILOT_API_MODEL env var if the default is unavailable.
  # openai/o4-mini is the April-2025 o4-generation reasoning model; it is not a
  # typo for o1-mini or gpt-4o-mini.
  #
  # Defaulted UNCONDITIONALLY (not just in the copilot branch) because the
  # cross-engine rubber-duck uses copilot even when it is not primary — e.g. the
  # claude) branch sets DUCK_ENGINE=copilot — and copilot_chat references a bare
  # $COPILOT_API_MODEL under `set -u`. Leaving it unset on a non-copilot primary
  # silently aborts the duck subprocess and skips tier-2 (#881).
  COPILOT_API_MODEL="${COPILOT_API_MODEL:-$DEFAULT_COPILOT_API_MODEL}"

  export ENGINE_TRIAGE_MODEL ENGINE_DEEP_MODEL ENGINE_AUDIT_MODEL
  export ENGINE_ACTION_MODEL ENGINE_SINGLE_MODEL
  export ENGINE_LABEL ENGINE_SINGLE_LABEL
  export DUCK_ENGINE DUCK_MODEL COPILOT_API_MODEL
  export CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN
  export CLAUDE_AUDIT_MODEL_CHAIN CLAUDE_ACTION_MODEL_CHAIN
  export CLAUDE_SINGLE_MODEL_CHAIN
}

# Initial config
set_engine_config
echo "    engine: $REVIEW_ENGINE ($ENGINE_LABEL)"

# model_for_intent <intent_type>
# Returns the engine model appropriate for the given dev-lead intent type.
# Called after set_engine_config so the returned value reflects the active engine.
# Tier mapping (engine-neutral — each engine maps its own model variables):
#   human-pr, fix-bot-comment  → ENGINE_TRIAGE_MODEL (lightweight read/classify)
#   fix-reviews, fix-ci, rebase → ENGINE_ACTION_MODEL (write operations)
#   fix-issue, human            → ENGINE_DEEP_MODEL   (full agentic work)
#   * (unknown/empty)           → ENGINE_ACTION_MODEL (safe default)
model_for_intent() {
  case "$(tier_for_intent "${1:-}")" in
    triage) echo "$ENGINE_TRIAGE_MODEL" ;;
    deep)   echo "$ENGINE_DEEP_MODEL"   ;;
    *)      echo "$ENGINE_ACTION_MODEL" ;;
  esac
}

# tier_for_intent <intent_type> — the tier name model_for_intent picks from
# (triage | action | deep). run_writer_with_fallback passes it to run_writer so
# the writer walks that tier's chain even when two tiers share a primary model.
tier_for_intent() {
  case "${1:-}" in
    human-pr|fix-bot-comment)   echo triage ;;
    fix-reviews|fix-ci|rebase)  echo action ;;
    fix-issue|human)            echo deep   ;;
    *)                          echo action ;;
  esac
}

# _usage_threshold — DEV_LEAD_USAGE_THRESHOLD (default: 75%), the usage percent at
# or above which an engine (or a Gemini key) counts as out of headroom.
_usage_threshold() {
  local t="${DEV_LEAD_USAGE_THRESHOLD:-75}"
  [[ "$t" =~ ^[0-9]+$ ]] || t=75
  printf '%s' "$t"
}

# check_provider_headroom <engine>
# Returns 0 (ok to proceed), 1 (at/above threshold — skip to next engine), or —
# gemini only — 2 (constrained: limits unknown or ledger unreadable, see below).
# claude/copilot fall back to 0 (proceed) on any query failure so a missing API or
# network error never blocks work (fail-open by design).
# Threshold is DEV_LEAD_USAGE_THRESHOLD (default: 75%).
# Logs a one-line headroom status to stderr for the step summary.
check_provider_headroom() {
  local engine="$1"
  local used_pct=0
  local threshold; threshold="$(_usage_threshold)"

  case "$engine" in
    claude)
      # Probe the Anthropic API for rate-limit headers. Uses a minimal
      # 1-token request so the probe itself barely consumes quota.
      # The probe model is the configured triage primary (AI_MODELS_CLAUDE /
      # CLAUDE_TRIAGE_MODEL_CHAIN), so a retired default can't blind it.
      local _resp remaining_tokens limit_tokens _hmodel
      _hmodel="$(_engine_chain_first "${CLAUDE_TRIAGE_MODEL_CHAIN:-$(ai_models_chain claude triage)}")"
      # Last-resort probe id when the configured triage chain is malformed — a known-good literal.
      [[ "$_hmodel" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || _hmodel="claude-haiku-4-5-20251001" # model-pin-ok: last-resort fallback
      _resp=$(curl -s -D - -o /dev/null -X POST https://api.anthropic.com/v1/messages \
        -H "x-api-key: ${ANTHROPIC_API_KEY:-}" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        --data-raw "{\"model\":\"${_hmodel}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\".\"}]}" \
        2>/dev/null || true)
      remaining_tokens=$(printf '%s' "$_resp" | grep -i 'x-ratelimit-remaining-tokens:' \
        | cut -d: -f2 | tr -d '[:space:]' || true)
      limit_tokens=$(printf '%s' "$_resp" | grep -i 'x-ratelimit-limit-tokens:' \
        | cut -d: -f2 | tr -d '[:space:]' || true)
      if [[ "$remaining_tokens" =~ ^[0-9]+$ ]] && [[ "$limit_tokens" =~ ^[0-9]+$ ]] && [ "$limit_tokens" -gt 0 ]; then
        used_pct=$(( 100 - (remaining_tokens * 100 / limit_tokens) ))
      elif [ -n "${ANTHROPIC_API_KEY:-}" ] && [ -z "${_HEADROOM_PROBE_WARNED:-}" ]; then
        # With an API key the probe should return rate-limit headers; none means
        # usage is unknown (e.g. the probe model is retired), not 0%.
        echo "::warning::[headroom] claude — no rate-limit headers from ${_hmodel}; usage unknown, proceeding" >&2
        _HEADROOM_PROBE_WARNED=1
      fi
      ;;
    gemini)
      # Self-metered from the token ledger against scripts/lib/gemini-quota-caps.tsv
      # (#2030) — no probe, no network call, no key value. Unknown limits or an
      # unreadable ledger are CONSTRAINED (2), deliberately not fail-open: Gemini is
      # the fallback of last resort. 2 is not a skip — refusing to degrade onto a
      # constrained Gemini is the actuation follow-up (#2029); the caller proceeds
      # and rotation tries those keys last.
      if ! declare -F gq_engine_headroom >/dev/null 2>&1; then
        echo "::warning::[headroom] gemini — quota library not loaded; limits unknown, treating as constrained" >&2
        return 2
      fi
      local _gname _gidx _gstate _gpct _gwhy
      local -a _gidxs=()
      while IFS= read -r _gname; do
        _gidx="$(gq_key_index "$_gname")" || continue
        case " ${_gidxs[*]} " in *" $_gidx "*) continue ;; esac
        _gidxs+=("$_gidx")
      done < <(_gemini_api_key_names)
      if [ "${#_gidxs[@]}" -eq 0 ]; then
        echo "::warning::[headroom] gemini — no API key configured, nothing to meter; limits unknown — treating as constrained" >&2
        return 2
      fi
      IFS='|' read -r _gstate _gpct _gwhy <<< "$(gq_engine_headroom "$threshold" "${_gidxs[@]}")"
      case "$_gstate" in
        ok|over)
          used_pct="$_gpct" ;;   # the shared threshold check below logs ok / skipping
        *)
          if [ -n "$_gwhy" ]; then
            echo "::warning::[headroom] gemini — ledger unreadable ($_gwhy); usage unknown — treating every key as constrained" >&2
          fi
          if [ -n "$_gpct" ] || [ -z "$_gwhy" ]; then
            echo "::warning::[headroom] gemini — limits unknown for key index ${_gpct:-?} in $(basename "$GEMINI_QUOTA_CAPS"); treating as constrained until the caps are filled" >&2
          fi
          return 2 ;;
      esac
      ;;
    copilot)
      # Skip probe when no real GitHub token is present — avoids unnecessary
      # external calls in unit tests and CI environments where the token is
      # unset or set to a placeholder value.
      local _tok="${COPILOT_GITHUB_TOKEN:-}"
      # A classic PAT (ghp_) counts as no valid token: Copilot rejects it at call
      # time ("Classic Personal Access Tokens (ghp_) are not supported"), the same
      # rule run_writer_with_fallback and validate-engines.sh apply (#1495, #1960).
      if [[ -z "$_tok" ]] || [[ ! "$_tok" =~ ^(github_pat_|ghs_) ]]; then
        # No valid Copilot token → skip the engine (#1546). Proceeding fail-open
        # here let a dead Copilot tier (subscription ended) convert a transient
        # Claude 429 into a hard job failure; skipping lets the chain reach the
        # next engine (e.g. gemini) instead.
        echo "  [headroom] copilot — no valid token, skipping engine" >&2
        return 1
      fi
      # Probe GitHub Models API rate-limit headers via a lightweight HEAD.
      local _resp _remaining _limit
      _resp=$(curl -sI --max-time 5 https://models.github.ai/inference/chat/completions \
        -H "Authorization: Bearer ${_tok}" \
        -H "X-GitHub-Api-Version: 2022-11-28" 2>/dev/null || true)
      _remaining=$(printf '%s' "$_resp" | grep -i 'x-ratelimit-remaining-requests:' \
        | cut -d: -f2 | tr -d '[:space:]' || true)
      _limit=$(printf '%s' "$_resp" | grep -i 'x-ratelimit-limit-requests:' \
        | cut -d: -f2 | tr -d '[:space:]' || true)
      if [[ "$_remaining" =~ ^[0-9]+$ ]] && [[ "$_limit" =~ ^[0-9]+$ ]] && [ "$_limit" -gt 0 ]; then
        used_pct=$(( 100 - (_remaining * 100 / _limit) ))
      fi
      ;;
  esac

  if [ "$used_pct" -ge "$threshold" ] 2>/dev/null; then
    echo "  [headroom] $engine usage ${used_pct}% >= threshold ${threshold}% — skipping" >&2
    return 1
  fi

  echo "  [headroom] $engine usage ${used_pct}% — ok" >&2
  return 0
}

# Load token metrics library unconditionally (non-fatal).
# emit_token_record and friends are no-ops when TOKEN_LOG_FILE is unset.
_TOKEN_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/token-metrics.sh"
# shellcheck source=lib/token-metrics.sh
[ -f "$_TOKEN_LIB" ] && source "$_TOKEN_LIB" 2>/dev/null || true
unset _TOKEN_LIB

# Gemini quota self-metering + per-key cooldown memory (#2030). Non-fatal: when
# missing, the gemini headroom branch reports "limits unknown" (constrained) and
# rotation falls back to the plain configured key order.
_GQ_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/gemini-quota.sh"
# shellcheck source=lib/gemini-quota.sh
[ -f "$_GQ_LIB" ] && source "$_GQ_LIB" 2>/dev/null || true
unset _GQ_LIB

# Credential redaction (redact_secrets) for the Claude chain hop log. Non-fatal:
# when the helper is missing, _claude_log_hop records only its header line.
_REDACT_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/redact.sh"
# shellcheck source=lib/redact.sh
[ -f "$_REDACT_LIB" ] && source "$_REDACT_LIB" 2>/dev/null || true
unset _REDACT_LIB

# _rate_limit_pattern
# Single source of truth for the rate-limit regex used by both is_rate_limited
# (text) and is_rate_limited_files (paths). Patterns intentionally excluded to
# prevent false positives:
#   - bare "exhausted" (too broad: matches "retry attempts exhausted", OS errors, etc.)
#     Retained as "token.*exhaust" / "out of.*token" for the specific token-depletion case.
#   - CLI syntax errors ("Invalid command format", "unknown flag", etc.) — see is_cli_error.
#   - the old Claude-specific "claude.*usage|usage.*claude": every
#     `claude --output-format json` envelope carries the model name and a "usage"
#     object, so it matched ANY failed call — a 404 unknown model or a 400 bad
#     request was reported as throttling and silently skipped (#1957). Real
#     Claude caps still match "usage limit" / "hit your limit" / 429 below.
_rate_limit_pattern() {
  local _pat
  _pat="hit your limit|rate[ -]?limit|resets [0-9]+(am|pm)|reached.*limit" # soft cap / throttle
  _pat="$_pat|usage limit|quota exceeded|too many requests|exceeded.*quota"
  _pat="$_pat|([^0-9]|^)429([^0-9]|$)"                               # HTTP 429
  _pat="$_pat|out of.*token|token.*exhaust"                            # token depletion
  _pat="$_pat|overloaded_error|service.*overload|overload.*error"      # service overload
  _pat="$_pat|([^0-9]|^)529([^0-9]|$)"                               # HTTP 529
  _pat="$_pat|plan.*limit|subscription.*limit|billing.*limit|daily.*limit|monthly.*limit|weekly.*limit"
  _pat="$_pat|([^0-9]|^)402([^0-9]|$)"                               # HTTP 402 (payment)
  _pat="$_pat|tokens_limit_reached|body too large|([^0-9]|^)413([^0-9]|$)" # Context / Request size
  _pat="$_pat|RESOURCE_EXHAUSTED"                                      # Google billing-exhausted status
  _pat="$_pat|credits.*depleted"         # Gemini billing depletion
  printf '%s' "($_pat)"
}

# is_rate_limited <text>
# Returns 0 (true) if the text looks like a provider usage/rate-limit block —
# API-level (429), subscription/billing caps (plan limit, out of tokens, HTTP 402),
# or service overload acting as a hard block (529).
# review-one-pr.sh exits with code 2 when this fires so the caller can switch engines.
#
# Prefer is_rate_limited_files for large LLM-output captures — it scans files
# directly with grep instead of materializing the contents in a shell variable,
# which avoids OOM and shell-substitution length limits on big payloads.
is_rate_limited() {
  local text="$1"
  printf '%s\n' "$text" | grep -qiE "$(_rate_limit_pattern)"
}

# is_rate_limited_files <file>...
# File-aware variant of is_rate_limited. Returns 0 if any of the given files
# matches the rate-limit pattern. Empty paths are skipped silently so callers
# can pass optional tmp files without pre-checks.
is_rate_limited_files() {
  local files=()
  local f
  for f in "$@"; do
    [ -n "$f" ] && [ -f "$f" ] && files+=("$f")
  done
  [ "${#files[@]}" -eq 0 ] && return 1
  grep -qiE "$(_rate_limit_pattern)" "${files[@]}"
}

# is_cli_error <text>
# Returns 0 (true) if the text looks like a CLI invocation error —
# bad flags, wrong syntax, or a missing command.
# These are NOT rate limits: callers must exit with code 1 (per-PR failure),
# NOT code 2 (rate-limit / engine fallback), so the session can continue
# processing the remaining PR queue rather than aborting entirely.
is_cli_error() {
  local text="$1"
  printf '%s\n' "$text" | grep -qiE \
    "(invalid command format|invalid (flag|argument|option|command)|unknown (flag|command|option|argument)|command not found|no such command|did you mean:|unrecognized (command|flag|argument|option)|bad (flag|argument|option))"
}

# is_diff_too_large <text>
# Returns 0 (true) if the text indicates that the PR diff exceeded GitHub's
# hard 300-file unified-diff cap (HTTP 406). Distinct from rate-limit (429/529)
# and CLI invocation errors — callers should fall back to the per-file REST API
# rather than exiting 1 (per-PR failure) or 2 (engine rate-limit).
is_diff_too_large() {
  local text="$1"
  printf '%s\n' "$text" | grep -qiE "(HTTP 406|exceeded the maximum number of files|diff exceeded the maximum)"
}

# _license_denied_pattern
# Single source of truth for the licensing/policy-denial regex used by both
# is_license_denied (text) and is_license_denied_files (paths). A `gh copilot`
# invocation on an org with no Copilot subscription fails deterministically with
# "Access denied by policy settings" (or "not supported by Copilot"). This is a
# dead-tier condition, NOT a transient rate-limit, so it is kept out of
# _rate_limit_pattern's vocabulary — but the fallback chain must treat it the
# same way (warn + continue to the next engine, never engine-error), so callers
# map a match to exit 2. See #1546 (sibling of the #1495 classic-PAT skip).
_license_denied_pattern() {
  printf '%s' "(access denied by policy settings|not supported by copilot)"
}

# is_license_denied <text>
# Returns 0 (true) if the text looks like a Copilot licensing/policy denial.
is_license_denied() {
  local text="$1"
  printf '%s\n' "$text" | grep -qiE "$(_license_denied_pattern)"
}

# is_license_denied_files <file>...
# File-aware variant of is_license_denied. Returns 0 if any of the given files
# matches the license-denial pattern. Empty/absent paths are skipped silently so
# callers can pass optional tmp files without pre-checks.
is_license_denied_files() {
  local files=()
  local f
  for f in "$@"; do
    [ -n "$f" ] && [ -f "$f" ] && files+=("$f")
  done
  [ "${#files[@]}" -eq 0 ] && return 1
  grep -qiE "$(_license_denied_pattern)" "${files[@]}"
}

# _mcp_failure_pattern
# Single source of truth for the MCP connection/init-failure regex. The claude
# CLI surfaces an unreachable/failed MCP server in its stdout/stderr but still
# exits 0 and produces a verdict, so this is a *warn-and-continue* signal, not a
# fatal one. Tokens are intentionally kept clear of _rate_limit_pattern's
# vocabulary (no "limit"/"quota"/"429"/"overload"/"exhaust") so a degraded MCP
# server is never misclassified as a provider rate-limit and routed into the
# cross-engine fallback — mirrors the caution at the chain-throttle warning.
_mcp_failure_pattern() {
  local _pat
  _pat='mcp server [^[:space:]]*[[:space:]]*("[^"]*"[[:space:]]*)?(failed|error)'   # `MCP server "x" failed`
  _pat="$_pat"'|failed to (connect|initialize|reconnect|start)[^.]*mcp'             # `failed to connect ... MCP`
  _pat="$_pat"'|mcp[^.]*(connection|initializ)[^.]*(fail|error)'                    # `MCP connection failed`
  _pat="$_pat"'|could not (connect to|start) mcp server'
  printf '%s' "($_pat)"
}

# _emit_mcp_failure_warning <file>...
# Graceful degradation (Fail Loud, Never Fake): when MCP is configured and any
# captured CLI output file shows an MCP server connection/init failure, emit a
# single ::warning:: naming the affected server(s) so the failure degrades
# visibly in the Actions log / step summary. NEVER alters control flow — the
# caller's exit code and the model's verdict are left untouched, so the review
# completes on the model's base capabilities instead of aborting or faking an
# "all clear". Inert (no scan, no output) when REVIEW_MCP_CONFIG is unset, so no
# MCP warnings appear for runs that never configured MCP.
_emit_mcp_failure_warning() {
  # Guard: only meaningful when MCP was actually configured for this run.
  [ -n "${REVIEW_MCP_CONFIG:-}" ] || return 0
  local files=() f
  for f in "$@"; do
    [ -n "$f" ] && [ -f "$f" ] && files+=("$f")
  done
  [ "${#files[@]}" -eq 0 ] && return 0
  # Opt-in affirmative diagnostics (REVIEW_MCP_DEBUG): surface the successful
  # handshake so a healthy MCP run is provable, not merely inferred from the
  # absence of the failure ::warning:: below. `--debug mcp` (added in
  # _mcp_review_flags) writes these "Successfully connected" lines to the
  # captured stderr. Never alters control flow.
  if [ -n "${REVIEW_MCP_DEBUG:-}" ]; then
    grep -hoiE 'mcp server "[^"]+": successfully connected.*' "${files[@]}" 2>/dev/null \
      | sort -u | while IFS= read -r _ln; do
        # printf (not echo): _ln is an arbitrary captured log line, so avoid
        # echo's inconsistent handling of leading hyphens / backslashes.
        printf '::notice::[mcp] %s\n' "${_ln}" >&2
      done
  fi
  grep -qiE "$(_mcp_failure_pattern)" "${files[@]}" || return 0
  # Best-effort: name the server(s) from a quoted token near "MCP server".
  local servers
  servers="$(grep -hoiE 'mcp server "[^"]+"' "${files[@]}" 2>/dev/null \
    | sed -E 's/.*"([^"]+)".*/\1/' | sort -u | paste -sd, - || true)"
  if [ -n "$servers" ]; then
    echo "::warning::[mcp] server(s) unavailable: ${servers} — review continues on the model's base capabilities (no MCP tool context)" >&2
  else
    echo "::warning::[mcp] an MCP server was unavailable — review continues on the model's base capabilities (no MCP tool context)" >&2
  fi
}


# is_transient_failure <exit_code>
# Returns 0 (true) for exit codes suggesting a flaky network/process state:
# 137/143 (signal kills). JSON parse failures and generic exit-1s are NOT
# retried — those are deterministic problems. Exit 124 (GNU `timeout`) is
# likewise NOT retried (#1028): a per-tier stage timeout means the model used
# its whole budget, so a same-budget in-run retry would just time out again —
# wasted runner-minutes + tokens. A 124 propagates immediately; the writer path
# then classifies it as reason=timeout and escalates (see run_writer_with_fallback).
is_transient_failure() {
  local rc="$1"
  case "$rc" in
    137|143) return 0 ;;
    *)       return 1 ;;
  esac
}

# copilot_chat <prompt_file> [timeout_sec] [extra_flags...]
# Calls the GitHub Copilot CLI for completions and agentic actions.
#
# Supports tool usage via the --yolo flag (passed in extra_flags).
# Uses COPILOT_API_MODEL (default: openai/gpt-4o).
#
# Rate-limit responses from the CLI are echoed to stdout/stderr so the caller's
# is_rate_limited() check can detect them and exit 2 for engine fallback.
copilot_chat() {
  local prompt_file="$1"
  local timeout_sec="${2:-300}"
  shift 2 || true

  # Ensure GH_TOKEN is set for gh copilot. It falls back to COPILOT_GITHUB_TOKEN.
  export GH_TOKEN="${COPILOT_GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [ -z "$GH_TOKEN" ]; then
    echo "copilot_chat: GH_TOKEN or COPILOT_GITHUB_TOKEN is required for copilot engine" >&2
    return 1
  fi

  # Avoid ARG_MAX by using -p with the file content. On Linux, ARG_MAX is
  # typically ~2MB, which is enough for most PR diffs and metadata.
  local prompt_text
  prompt_text=$(cat "$prompt_file")
  
  echo "    [copilot] calling gh copilot (model=$COPILOT_API_MODEL, timeout=${timeout_sec}s, flags=$*)" >&2

  # We use -p for the prompt. Redirect /dev/null to stdin to ensure
  # non-interactive mode.
  timeout --kill-after="$ENGINE_KILL_AFTER" "$timeout_sec" gh copilot \
    --model "$COPILOT_API_MODEL" \
    -p "$prompt_text" \
    -s "$@" < /dev/null
}

# _gemini_api_keys
# Prints the ordered, de-duplicated list of configured Gemini API keys, one per
# line: the primary (GEMINI_API_KEY, then GOOGLE_API_KEY) followed by the extra
# resilience keys GOOGLE_API_KEY_2, GOOGLE_API_KEY_3 and GOOGLE_API_KEY_4 (#1777). Empty vars are
# skipped; duplicate values (the common case where GEMINI_API_KEY == GOOGLE_API_KEY,
# both wired to the same secret) collapse to one entry. Emits nothing when no key
# is configured, so callers can distinguish "no keys" from "one or more keys".
# Keys the pre-flight billing probe found depleted (GEMINI_DEPLETED_KEYS, a
# comma-separated list of variable NAMES from validate-engines.sh) are moved to
# the end rather than dropped: the healthy keys are tried first, so a depleted
# first key no longer costs a full billing-retry cycle on every call, and the
# depleted ones stay as a last resort in case credits were topped up mid-run.
_gemini_api_keys() {
  local _name
  while IFS= read -r _name; do
    printf '%s\n' "${!_name}"
  done < <(_gemini_api_key_names)
}

# _gemini_api_key_names
# Same order and de-duplication as _gemini_api_keys, but prints the variable NAMES
# (never values). Rotation works from names so a key is only ever identified by its
# index (gq_key_index, #2030) in logs, ledger records, and cooldown state.
_gemini_api_key_names() {
  local _name k seen="" _depleted="" _skip=", ${GEMINI_DEPLETED_KEYS:-}, "
  for _name in GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_API_KEY_2 GOOGLE_API_KEY_3 GOOGLE_API_KEY_4; do
    k="${!_name:-}"
    [ -z "$k" ] && continue
    case "$seen" in
      *"|${k}|"*) continue ;;
    esac
    seen="${seen}|${k}|"
    case "$_skip" in
      *", ${_name}, "*) _depleted="${_depleted}${_name}"$'\n'; continue ;;
    esac
    printf '%s\n' "$_name"
  done
  [ -z "$_depleted" ] || printf '%s' "$_depleted"
}

# _gemini_note_key_index <index>
# Records which key index served the successful Gemini call next to the per-call
# usage sidecar, so _record_engine_tokens can attribute the token record to the key
# (the call may run in a `| tee` subshell, hence a file). No-op without a ledger.
_gemini_note_key_index() {
  [ -n "${1:-}" ] || return 0
  declare -F _engine_usage_sidecar >/dev/null 2>&1 || return 0
  # Strictly call-unique: only the per-call _ENGINE_USAGE_OUT path qualifies. The
  # shared $$ fallback could be overwritten by a concurrent call and charge usage
  # to the wrong key, so without a unique path the record is left UNATTRIBUTED
  # (no key_index) — the metering never charges an unattributed record to any key.
  [ -n "${TOKEN_LOG_FILE:-}" ] || return 0
  if [ -z "${_ENGINE_USAGE_OUT:-}" ]; then
    echo "[gemini] no call-unique usage sidecar — token record carries no key_index (unattributed)" >&2
    return 0
  fi
  printf '%s\n' "$1" > "${_ENGINE_USAGE_OUT}.key" 2>/dev/null || true
}

# _gemini_invoke <prompt_file> <timeout_sec> <model> [extra_args...]
# Runs the gemini CLI and emits the model's text to stdout (stderr passes through
# so callers that merge it for rate-limit detection still work). When token
# logging is on (and ENGINE_USAGE_JSON != 0) it runs with --output-format json,
# captures real usage into the LAST_* globals, and emits the extracted text;
# otherwise it uses --output-format text (estimate path). Robust fallback: if the
# JSON result text is empty or the call fails, the raw payload is emitted.
_gemini_invoke() {
  local prompt_file="$1" timeout_sec="$2" model="$3"
  shift 3
  local extra_args=("$@")

  declare -f reset_engine_usage >/dev/null 2>&1 && reset_engine_usage

  local _usage_json=0
  if [ -n "${TOKEN_LOG_FILE:-}" ] && [ "${ENGINE_USAGE_JSON:-1}" != "0" ] \
     && declare -f parse_engine_usage >/dev/null 2>&1; then
    _usage_json=1
  fi

  if [ "$_usage_json" -eq 1 ]; then
    local _json_tmp; _json_tmp="$(mktemp 2>/dev/null || true)"
    if [ -n "$_json_tmp" ]; then
      local rc=0
      # stderr intentionally NOT redirected — flows to caller for rate-limit checks.
      timeout --kill-after="$ENGINE_KILL_AFTER" "$timeout_sec" gemini --prompt "" --model "$model" "${extra_args[@]}" \
        --output-format json < "$prompt_file" > "$_json_tmp" || rc=$?
      if [ "$rc" -eq 0 ]; then
        parse_engine_usage gemini "$_json_tmp" || true
        local _txt; _txt="$(extract_engine_text gemini "$_json_tmp")"
        if [ -n "$_txt" ]; then printf '%s\n' "$_txt"; else cat "$_json_tmp"; fi
      else
        cat "$_json_tmp"   # emit raw payload so downstream/rate-limit logic sees it
      fi
      rm -f "$_json_tmp"
      return "$rc"
    fi
  fi

  # Estimate path (logging off, or mktemp failed): plain text output.
  timeout --kill-after="$ENGINE_KILL_AFTER" "$timeout_sec" gemini --prompt "" --model "$model" "${extra_args[@]}" \
    --output-format text < "$prompt_file"
}

# _gemini_chain_invoke <chain_csv> <prompt_file> <timeout_sec> [extra_args...]
# Walks a comma-separated list of Gemini models, invoking _gemini_invoke with
# each model in sequence. Semantics mirror _claude_chain_invoke:
#   - First model that succeeds (exit 0) wins; its stdout is emitted, exit 0 returned.
#   - Rate-limited models (is_rate_limited_files) are logged and skipped; next tried.
#   - Non-rate-limit failures stop the chain immediately; exit code propagated.
#   - If every model rate-limits, returns 2 and writes the parsed reset time.
#   - Empty/whitespace-only chain → config error exit 1.
#
# Sets _GEMINI_CHAIN_MODEL_USED to the model that produced the final output.
# Note: when called inside a pipeline (e.g. `... | tee ...`), the variable is
# set in a subshell and will not propagate to the parent — same limitation as
# _CLAUDE_CHAIN_MODEL_USED in _claude_chain_invoke.
_gemini_chain_invoke() {
  local chain_csv="$1" prompt_file="$2" timeout_sec="$3"
  shift 3
  local extra_args=("$@")

  if [ -z "$chain_csv" ]; then
    echo "::error::_gemini_chain_invoke called with empty chain" >&2
    return 1
  fi

  local -a models
  local saved_ifs="$IFS"
  IFS=',' read -ra models <<< "$chain_csv"
  IFS="$saved_ifs"

  local stdout_tmp="" stderr_tmp=""
  local final_stdout="" final_stderr="" final_model="" final_rc=0
  local rc=0 attempted=0 all_rl=1
  local model

  for model in "${models[@]}"; do
    # Trim whitespace
    model="${model#"${model%%[![:space:]]*}"}"
    model="${model%"${model##*[![:space:]]}"}"
    [ -z "$model" ] && continue

    attempted=$((attempted + 1))
    stdout_tmp="$(mktemp 2>/dev/null)" || stdout_tmp=""
    stderr_tmp="$(mktemp 2>/dev/null)" || stderr_tmp=""
    rc=0

    if [ -n "$stdout_tmp" ] && [ -n "$stderr_tmp" ]; then
      # Per-key rotation (#1777): try each configured API key in turn for THIS
      # model. A rate-limited key rotates to the next key before the model is
      # downgraded, so a per-key quota exhaustion no longer forces an immediate
      # model/provider hop while another key still has headroom. A non-rate-limit
      # failure stops rotation and propagates (a bad prompt fails on every key).
      # stderr intentionally passed through from _gemini_invoke (rate-limit msgs live there).
      #
      # Cooldown memory (#2030): a key that rate-limited on this model within its
      # cooldown (ledger record, gq_rotation_plan) is skipped, not re-hit; keys with
      # measured headroom go first and constrained ones (limits unknown / at the
      # threshold) last. A key that cannot run this model today — cap 0 or daily cap
      # used up — is dropped and never called (#2041). Keys are named by index only.
      local -a _key_names=() _key_idxs=() _all_names=()
      local _pk _pn _pi _pu
      while IFS= read -r _pn; do _all_names+=("$_pn"); done < <(_gemini_api_key_names)
      if [ "${#_all_names[@]}" -gt 0 ] && declare -F gq_rotation_plan >/dev/null 2>&1; then
        while IFS=$'\t' read -r _pk _pn _pi _pu; do
          case "$_pk" in
            cool)
              echo "::notice::[gemini] model $model: key index $_pi cooling down until $(date -u -d "@$_pu" +%H:%M:%SZ 2>/dev/null || echo "$_pu") — skipped" >&2 ;;
            skip)
              echo "::notice::[gemini] model $model: key index $_pi $_pu — skipped, not called" >&2 ;;
            use)
              _key_names+=("$_pn"); _key_idxs+=("$_pi") ;;
          esac
        done < <(gq_rotation_plan "$model" "$(_usage_threshold)" "${_all_names[@]}")
      else
        for _pn in "${_all_names[@]}"; do
          _key_names+=("$_pn"); _key_idxs+=("")
        done
      fi
      if [ "${#_all_names[@]}" -eq 0 ]; then
        # No key configured (e.g. env-inherited auth in tests) — single call.
        _gemini_invoke "$prompt_file" "$timeout_sec" "$model" "${extra_args[@]}" \
          > "$stdout_tmp" 2> "$stderr_tmp" || rc=$?
      elif [ "${#_key_names[@]}" -eq 0 ]; then
        # Every key is cooling down, or capped / exhausted (#2041), on this model: no
        # call. Classified as a rate limit (captured stderr only) so the chain moves to
        # the next model and, past the last one, signals the cross-provider fallback
        # (exit 2).
        printf '[gemini] every API key is cooling down after a rate limit (or capped) on model %s — not called\n' \
          "$model" > "$stderr_tmp"
        rc=2
      else
        local _had_gk="${GOOGLE_API_KEY+x}" _had_gmk="${GEMINI_API_KEY+x}"
        local _saved_gk="${GOOGLE_API_KEY:-}" _saved_gmk="${GEMINI_API_KEY:-}"
        local _key _key_name _key_i _key_n=0 _cd _cd_src _cd_scope
        for _key_i in "${!_key_names[@]}"; do
          _key_n=$((_key_n + 1))
          _key_name="${_key_names[$_key_i]}"
          # Resolve the two primary names from the saved originals: the exports below
          # overwrite both, so a distinct GOOGLE_API_KEY would otherwise read the
          # first attempt's value and never rotate.
          case "$_key_name" in
            GEMINI_API_KEY) _key="$_saved_gmk" ;;
            GOOGLE_API_KEY) _key="$_saved_gk" ;;
            *)              _key="${!_key_name}" ;;
          esac
          export GOOGLE_API_KEY="$_key" GEMINI_API_KEY="$_key"
          rc=0
          _gemini_invoke "$prompt_file" "$timeout_sec" "$model" "${extra_args[@]}" \
            > "$stdout_tmp" 2> "$stderr_tmp" || rc=$?
          if [ "$rc" -eq 0 ]; then
            _gemini_note_key_index "${_key_idxs[$_key_i]}"
            break
          fi
          # Only a rate-limit rotates to the next key; a hard failure stops here.
          is_rate_limited_files "$stdout_tmp" "$stderr_tmp" || break
          # Remember the throttle so later calls/jobs skip this key on this model
          # until the provider's retry hint (else the configured default) elapses —
          # doubled per consecutive rejection, capped at the next daily reset, and
          # straight to the reset at a daily cap (#2041). Record only genuine quota/rate-limit
          # rejections as attempts (Google counts those), plus a redacted sample.
          if [ -n "${_key_idxs[$_key_i]}" ] && [ -n "$(gq_ledger_file)" ]; then
            _cd="$(gq_retry_hint_sec "$stdout_tmp" "$stderr_tmp")"; _cd_src="retry hint"
            [ -n "$_cd" ] || { _cd="$(gq_default_cooldown_sec)"; _cd_src="default"; }
            _cd_scope="$(gq_rejection_scope "$stdout_tmp" "$stderr_tmp")"
            IFS=$'\t' read -r _cd _cd_src <<< "$(gq_escalated_cooldown "${_key_idxs[$_key_i]}" "$model" \
              "$_cd" "$_cd_src" "$_cd_scope")"
            if gq_is_quota_rejection "$stdout_tmp" "$stderr_tmp"; then
              gq_record_attempt "${_key_idxs[$_key_i]}" "$model"
              gq_record_rejection_sample "${_key_idxs[$_key_i]}" "$model" "$_cd_scope" "$stdout_tmp" "$stderr_tmp"
            fi
            gq_record_cooldown "${_key_idxs[$_key_i]}" "$model" "$_cd" "$_cd_src"
            echo "::notice::[gemini] model $model: key index ${_key_idxs[$_key_i]} cooling down for ${_cd}s ($_cd_src)" >&2
          fi
          # By position, never the key: the log shows how far rotation got.
          if [ "$_key_n" -lt "${#_key_names[@]}" ]; then
            echo "::notice::[gemini] model $model: API key $_key_n of ${#_key_names[@]} throttled — trying the next key" >&2
          fi
        done
        # Restore the caller's original key env for subsequent models/engines.
        if [ -n "$_had_gk" ]; then export GOOGLE_API_KEY="$_saved_gk"; else unset GOOGLE_API_KEY; fi
        if [ -n "$_had_gmk" ]; then export GEMINI_API_KEY="$_saved_gmk"; else unset GEMINI_API_KEY; fi
      fi
    else
      # mktemp failure — clean up partial allocations and fall through without capture.
      [ -n "$stdout_tmp" ] && rm -f "$stdout_tmp"
      [ -n "$stderr_tmp" ] && rm -f "$stderr_tmp"
      [ -n "$final_stdout" ] && rm -f "$final_stdout"
      [ -n "$final_stderr" ] && rm -f "$final_stderr"
      _gemini_invoke "$prompt_file" "$timeout_sec" "$model" "${extra_args[@]}" || rc=$?
      _GEMINI_CHAIN_MODEL_USED="$model"
      export _GEMINI_CHAIN_MODEL_USED
      return "$rc"
    fi

    # Keep only the latest attempt's buffers
    [ -n "$final_stdout" ] && rm -f "$final_stdout"
    [ -n "$final_stderr" ] && rm -f "$final_stderr"
    final_stdout="$stdout_tmp"
    final_stderr="$stderr_tmp"
    final_model="$model"

    if [ "$rc" -eq 0 ]; then
      final_rc=0
      all_rl=0
      break
    fi
    if ! is_rate_limited_files "$stdout_tmp" "$stderr_tmp"; then
      # Non-rate-limit failure — propagate immediately without trying next model.
      final_rc="$rc"
      all_rl=0
      break
    fi
    # Rate-limited; log and try next model.
    # Phrasing avoids tokens that match _rate_limit_pattern so downstream callers
    # that scan stderr do not misclassify a successful chain fallback as a rate-limit.
    echo "::warning::[gemini] model $model throttled (rc=$rc) — trying next in chain" >&2
  done

  if [ "$attempted" -eq 0 ]; then
    echo "::error::_gemini_chain_invoke: chain '$chain_csv' had no valid model entries" >&2
    return 1
  fi

  if [ "$all_rl" -eq 1 ]; then
    parse_reset_time_files "$final_stdout" "$final_stderr"
    final_rc=2
  fi

  if [ -n "$final_stdout" ]; then
    cat "$final_stdout"
    rm -f "$final_stdout"
  fi
  if [ -n "$final_stderr" ]; then
    cat "$final_stderr" >&2
    rm -f "$final_stderr"
  fi

  _GEMINI_CHAIN_MODEL_USED="$final_model"
  export _GEMINI_CHAIN_MODEL_USED
  return "$final_rc"
}

# _claude_hop_failure_class <stdout_file> <stderr_file>
# Classifies one failed (rc != 0) `claude --print` hop for _claude_chain_invoke.
# Prints exactly one of:
#   rate_limit        throttle / cap / overload (HTTP 429, 529, 402, 413, or
#                     _rate_limit_pattern text) — the next model may have headroom
#   model_unavailable HTTP 404 — the model id is unknown or not provisioned
#   invalid_request   HTTP 400 — this model rejected the request shape
#   server_error      other HTTP 5xx — transient API failure
#   error             anything else — not worth retrying on another model
# With --output-format json a failed call prints a result envelope carrying
# is_error / api_error_status next to the model name and a "usage" object. The
# status code is authoritative when present, and only the envelope's .result text
# is regex-scanned otherwise — never its metadata, which is what made every
# Claude error look like throttling (#1957). Plain-text output is scanned as-is.
_claude_hop_failure_class() {
  local out="$1" err="$2" status="" result_tmp="" is_json=0 cls="error"
  if [ -n "$out" ] && [ -s "$out" ] && command -v jq >/dev/null 2>&1 \
     && jq -es 'any(.[]; type == "object" and has("type"))' "$out" >/dev/null 2>&1; then
    is_json=1
    status="$(jq -rs '[.[] | select(type == "object" and .is_error == true)] | last
                      | (.api_error_status // empty) | tostring' "$out" 2>/dev/null || true)"
  fi
  case "$status" in
    429|529|402|413) printf 'rate_limit'; return 0 ;;
    404) printf 'model_unavailable'; return 0 ;;
    400) printf 'invalid_request'; return 0 ;;
    5[0-9][0-9]) printf 'server_error'; return 0 ;;
    [0-9]*) printf 'error'; return 0 ;;
  esac
  if [ "$is_json" -eq 1 ]; then
    result_tmp="$(mktemp 2>/dev/null)" || result_tmp=""
    if [ -n "$result_tmp" ]; then
      jq -rs '[.[] | select(type == "object")] | last | (.result // empty) | tostring' \
        "$out" > "$result_tmp" 2>/dev/null || true
      is_rate_limited_files "$result_tmp" "$err" && cls="rate_limit"
      rm -f "$result_tmp"
    else
      is_rate_limited_files "$err" && cls="rate_limit"
    fi
  else
    is_rate_limited_files "$out" "$err" && cls="rate_limit"
  fi
  printf '%s' "$cls"
}

# _claude_log_hop <model> <rc> <class> <stdout_file> <stderr_file>
# Appends a failed hop's error to the hop log so an earlier hop's real error
# survives — only the final hop's output reaches the caller (#1957). The log is
# CLAUDE_CHAIN_HOP_LOG, defaulting under $RUNNER_TEMP/cascade/ (uploaded with the
# pr-review debug artifact); outside Actions with no override it is off.
# Kept deliberately narrow because it lands in an artifact: for a JSON envelope
# only its error fields (is_error, api_error_status, subtype, .result) — non-JSON
# stdout is omitted, since it may be a raw agent transcript — plus the head of
# stderr, each capped at 1000 bytes and passed through redact_secrets. Without redact_secrets only the header line is
# written. Written to a file, never stderr: callers scan our stderr with
# is_rate_limited, and replaying a throttled hop's text there would make a
# successful fallback look like a provider rate-limit. Best-effort; never fails
# the caller.
_claude_log_hop() {
  local log="${CLAUDE_CHAIN_HOP_LOG:-}" out="${4:-}" err="${5:-}"
  if [ -z "$log" ] && [ -n "${RUNNER_TEMP:-}" ]; then
    log="$RUNNER_TEMP/cascade/claude-chain-hops.log"
  fi
  [ -n "$log" ] || return 0
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
  {
    printf '=== %s model=%s rc=%s class=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$1" "$2" "$3"
    if declare -F redact_secrets >/dev/null 2>&1; then
      if [ -f "$out" ]; then
        printf -- '--- error\n'
        { jq -cs '[.[] | select(type == "object")] | last
                  | {is_error, api_error_status, subtype, result}' "$out" 2>/dev/null \
            || printf '(non-JSON stdout omitted)'; } \
          | head -c 1000 | redact_secrets
        printf '\n'
      fi
      if [ -f "$err" ] && [ -s "$err" ]; then
        printf -- '--- stderr\n'
        head -c 1000 "$err" 2>/dev/null | redact_secrets
        printf '\n'
      fi
    fi
  } >> "$log" 2>/dev/null || true
}

# _claude_chain_invoke <chain_csv> <prompt_file> <timeout_sec> [extra_args...]
# Walks a comma-separated list of Claude models, invoking `claude --print --model X`
# with the given extra arguments. A failed hop is classified by
# _claude_hop_failure_class: throttling, an unavailable model (404), a rejected
# request (400) or a 5xx is logged (a ::warning:: naming the reason, plus the
# hop's output in the hop log) and the next model is tried; any other failure
# propagates immediately. The final attempt's stdout is written to fd1, stderr to
# fd2. If the chain runs out and its LAST hop was throttled, returns 2 and writes
# the parsed reset time to /tmp/dev-lead-rate-limit-reset (the caller's
# cross-provider fallback signal); otherwise returns that hop's own exit code.
#
# Empty chain → no-op return 0 (callers should fall back to the single-model
# legacy path; this is only used when CLAUDE_*_MODEL_CHAIN is set).
#
# Sets _CLAUDE_CHAIN_MODEL_USED to the model that produced the final output
# (success or last attempt) so callers can log which model actually ran.
_claude_chain_invoke() {
  local chain_csv="$1" prompt_file="$2" timeout_sec="$3"
  shift 3
  local extra_args=("$@")

  if [ -z "$chain_csv" ]; then
    echo "::error::_claude_chain_invoke called with empty chain" >&2
    return 1
  fi

  # When token logging is on, capture real usage by running claude with
  # --output-format json and emitting the extracted .result text to the caller.
  # Gated by ENGINE_USAGE_JSON (default on) so it can be disabled without a code
  # change. Falls back to raw output if extraction yields nothing.
  declare -f reset_engine_usage >/dev/null 2>&1 && reset_engine_usage
  local _usage_json=0 fmt_args=()
  if [ -n "${TOKEN_LOG_FILE:-}" ] && [ "${ENGINE_USAGE_JSON:-1}" != "0" ] \
     && declare -f parse_engine_usage >/dev/null 2>&1; then
    _usage_json=1
    fmt_args=(--output-format json)
  fi

  local saved_ifs="$IFS"
  IFS=',' read -ra models <<< "$chain_csv"
  IFS="$saved_ifs"

  local stdout_tmp="" stderr_tmp=""
  local final_stdout="" final_stderr="" final_model="" final_rc=0
  local rc=0 attempted=0 succeeded=0 last_cls=""
  local model

  for model in "${models[@]}"; do
    # Trim whitespace
    model="${model#"${model%%[![:space:]]*}"}"
    model="${model%"${model##*[![:space:]]}"}"
    [ -z "$model" ] && continue

    attempted=$((attempted + 1))
    stdout_tmp="$(mktemp 2>/dev/null)" || stdout_tmp=""
    stderr_tmp="$(mktemp 2>/dev/null)" || stderr_tmp=""
    rc=0

    if [ -n "$stdout_tmp" ] && [ -n "$stderr_tmp" ]; then
      timeout --kill-after="$ENGINE_KILL_AFTER" "$timeout_sec" claude --print --model "$model" "${fmt_args[@]}" "${extra_args[@]}" \
        < "$prompt_file" > "$stdout_tmp" 2> "$stderr_tmp" || rc=$?
    else
      # mktemp failure (one or both) — clean up the partial tmp before degrading
      # to direct stdout/stderr passthrough so we don't leak a half-allocated fd.
      [ -n "$stdout_tmp" ] && rm -f "$stdout_tmp"
      [ -n "$stderr_tmp" ] && rm -f "$stderr_tmp"
      [ -n "$final_stdout" ] && rm -f "$final_stdout"
      [ -n "$final_stderr" ] && rm -f "$final_stderr"
      timeout --kill-after="$ENGINE_KILL_AFTER" "$timeout_sec" claude --print --model "$model" "${extra_args[@]}" \
        < "$prompt_file" || rc=$?
      _CLAUDE_CHAIN_MODEL_USED="$model"
      export _CLAUDE_CHAIN_MODEL_USED
      return "$rc"
    fi

    # Drop any previous final-attempt buffers (we keep only the latest)
    [ -n "$final_stdout" ] && rm -f "$final_stdout"
    [ -n "$final_stderr" ] && rm -f "$final_stderr"
    final_stdout="$stdout_tmp"
    final_stderr="$stderr_tmp"
    final_model="$model"

    if [ "$rc" -eq 0 ]; then
      final_rc=0
      succeeded=1
      break
    fi
    final_rc="$rc"
    # File-based classification — avoids loading large agent output into a
    # shell variable via $(cat ...) (OOM risk on big captures).
    last_cls="$(_claude_hop_failure_class "$stdout_tmp" "$stderr_tmp")"
    _claude_log_hop "$model" "$rc" "$last_cls" "$stdout_tmp" "$stderr_tmp"
    # Warning phrasing intentionally avoids "rate-limit"/"429"/"quota" etc. —
    # those tokens match is_rate_limited()/_rate_limit_pattern, and downstream
    # callers (e.g. review-one-pr.sh) that scan our stderr would then
    # misclassify a successful chain fallback as a provider rate-limit.
    case "$last_cls" in
      rate_limit)
        echo "::warning::[claude] model $model throttled (rc=$rc) — trying next in chain" >&2 ;;
      model_unavailable)
        echo "::warning::[claude] model $model unavailable (HTTP 404: unknown or not provisioned) — trying next in chain" >&2 ;;
      invalid_request)
        echo "::warning::[claude] model $model rejected the request (HTTP 400) — trying next in chain" >&2 ;;
      server_error)
        echo "::warning::[claude] model $model hit an API server error (HTTP 5xx) — trying next in chain" >&2 ;;
      *)
        # Any other failure — propagate immediately, do not try the next model.
        break ;;
    esac
  done

  # Empty/whitespace-only chain → configuration error, not a rate-limit. Returning
  # 2 here would trigger the cross-provider fallback as if quotas were exhausted.
  if [ "$attempted" -eq 0 ]; then
    echo "::error::_claude_chain_invoke: chain '$chain_csv' had no valid model entries" >&2
    return 1
  fi

  # Chain exhausted with the last hop throttled → parse its reset time and
  # return 2. Keyed on the LAST hop because callers such as review-one-pr.sh
  # decide on the cross-provider fallback by scanning the final hop's output,
  # which only carries a rate-limit signal when that hop was throttled. A chain
  # ending on a 404/400/5xx returns that hop's own code: an honest failure.
  if [ "$succeeded" -eq 0 ] && [ "$last_cls" = "rate_limit" ]; then
    parse_reset_time_files "$final_stdout" "$final_stderr"
    final_rc=2
  fi

  # Graceful degradation (issue #678): if MCP was configured and the CLI reported
  # an MCP server connection/init failure, surface a ::warning:: but do NOT touch
  # final_rc — the review proceeds to its normal verdict on the model's base
  # capabilities rather than fatal-exiting or faking an "all clear". Inert when
  # the MCP knob is unset. Scans the captured files while they still exist.
  _emit_mcp_failure_warning "$final_stdout" "$final_stderr"

  # Emit the final attempt's captured output to the caller. In JSON-usage mode,
  # parse the usage block and emit the extracted .result text (so consumers still
  # receive plain text); fall back to the raw payload if extraction is empty or
  # the call failed (preserves error/rate-limit text for downstream detection).
  if [ -n "$final_stdout" ]; then
    if [ "$_usage_json" -eq 1 ] && [ "$final_rc" -eq 0 ]; then
      parse_engine_usage claude "$final_stdout" || true
      local _txt
      _txt="$(extract_engine_text claude "$final_stdout")"
      if [ -n "$_txt" ]; then
        printf '%s\n' "$_txt"
      else
        cat "$final_stdout"
      fi
    else
      cat "$final_stdout"
    fi
    rm -f "$final_stdout"
  fi
  if [ -n "$final_stderr" ]; then
    cat "$final_stderr" >&2
    rm -f "$final_stderr"
  fi

  _CLAUDE_CHAIN_MODEL_USED="$final_model"
  export _CLAUDE_CHAIN_MODEL_USED
  return "$final_rc"
}

# _now_ms
# Prints wall-clock time in milliseconds, or nothing when no clock is readable.
# Prefers bash 5's $EPOCHREALTIME (no subshell or `date` fork per call; the
# fraction separator may be `.` or `,` depending on locale). Otherwise falls back
# to `date +%s%3N` (GNU), then `date +%s` × 1000 where %3N is unsupported (macOS/
# BSD). If even that fails it prints nothing, so _elapsed_ms records null rather
# than a fake 0 ms. Never aborts the caller.
_now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local _sec="${EPOCHREALTIME%[.,]*}" _frac="${EPOCHREALTIME#*[.,]}000"
    printf '%s%s' "$_sec" "${_frac:0:3}"
    return 0
  fi
  local t
  t="$(date +%s%3N 2>/dev/null || true)"
  case "$t" in
    ''|*[!0-9]*)
      t="$(date +%s 2>/dev/null || true)"
      case "$t" in
        ''|*[!0-9]*) t="" ;;
        *) t="$(( t * 1000 ))" ;;
      esac
      ;;
  esac
  printf '%s' "$t"
}

# _elapsed_ms <start_ms> <end_ms>
# Prints end - start, or nothing when either stamp is missing/non-numeric or the
# clock went backwards, so the token record carries null instead of a bogus value.
_elapsed_ms() {
  case "${1:-}" in ''|*[!0-9]*) return 0 ;; esac
  case "${2:-}" in ''|*[!0-9]*) return 0 ;; esac
  [ "$2" -ge "$1" ] || return 0
  printf '%s' "$(( $2 - $1 ))"
}

# _record_engine_tokens <tier> <engine> <model> <prompt_file> [output_file] [duration_ms]
# Writes one token record to TOKEN_LOG_FILE using estimate_tokens_from_file.
# No-op when TOKEN_LOG_FILE is unset or the token-metrics library is not loaded.
# Always succeeds (non-fatal): token logging must never abort a real workflow.
# duration_ms (#1949) is the caller-measured wall-clock latency of the engine
# call; when empty it is forwarded as such so emit_token_record writes null.
_record_engine_tokens() {
  [ -n "${TOKEN_LOG_FILE:-}" ] || return 0
  declare -f emit_token_record >/dev/null 2>&1 || return 0

  local tier="$1" engine="$2" model="$3" prompt_file="$4" output_file="${5:-}" duration_ms="${6:-}"
  local workflow="${TOKEN_WORKFLOW:-unknown}" context="${PR_URL:-}"
  local input_tokens cache_read_tokens cache_write_tokens output_tokens
  local _have_usage=0

  # Prefer real usage captured by the engine. It is read from the sidecar file
  # (written even when the engine ran inside a `cmd | tee` subshell); the LAST_*
  # globals are a secondary source for non-piped callers.
  local _uf=""
  declare -f _engine_usage_sidecar >/dev/null 2>&1 && _uf="$(_engine_usage_sidecar)"
  if [ -n "$_uf" ] && [ -s "$_uf" ]; then
    IFS=$'\t' read -r input_tokens cache_read_tokens cache_write_tokens output_tokens < "$_uf"
    rm -f "$_uf" 2>/dev/null || true
    case "${input_tokens}${cache_read_tokens}${cache_write_tokens}${output_tokens}" in
      ''|*[!0-9]*) _have_usage=0 ;;
      *)           _have_usage=1 ;;
    esac
  elif [ "${LAST_USAGE_OK:-0}" = "1" ]; then
    input_tokens="${LAST_INPUT_TOKENS:-0}"
    cache_read_tokens="${LAST_CACHE_READ_TOKENS:-0}"
    cache_write_tokens="${LAST_CACHE_WRITE_TOKENS:-0}"
    output_tokens="${LAST_OUTPUT_TOKENS:-0}"
    _have_usage=1
  fi

  if [ "$_have_usage" -ne 1 ]; then
    # Fallback: estimate from byte counts (engine reported no usage, e.g. copilot
    # or text-mode). Cache figures are unknown → 0.
    input_tokens=$(estimate_tokens_from_file "$prompt_file")
    output_tokens=$(estimate_tokens_from_file "$output_file")
    cache_read_tokens=0
    cache_write_tokens=0
  fi

  # Gemini key attribution (#2030): the key INDEX that served the call, noted by
  # _gemini_note_key_index, so the quota gate can meter each key from the ledger.
  local key_index=""
  if [ -n "$_uf" ] && [ -f "${_uf}.key" ]; then
    [ "$engine" = "gemini" ] && IFS= read -r key_index < "${_uf}.key"
    rm -f "${_uf}.key" 2>/dev/null || true
  fi

  emit_token_record "$workflow" "$tier" "$engine" "$model" \
    "$input_tokens" "$cache_read_tokens" "$output_tokens" "$context" "$cache_write_tokens" "$duration_ms" \
    "$key_index" || true
}

# _record_model_used <model>
# Records the model that ACTUALLY produced the final output to ENGINE_MODEL_USED_FILE
# when that path is set (no-op otherwise, so live review paths pay nothing). A caller
# that runs the engine inside a command substitution — the eval scorer,
# scripts/evals/run-eval.sh — cannot read an exported var back across the `$(...)`
# subshell boundary, but it CAN read a file. So a rate-limit fallback down the chain
# (e.g. opus -> sonnet) surfaces as the observed model in the eval report instead of
# being silently attributed to the tier's declared model (#1686 AC #1).
_record_model_used() {
  [ -n "${ENGINE_MODEL_USED_FILE:-}" ] || return 0
  printf '%s\n' "$1" >"$ENGINE_MODEL_USED_FILE" 2>/dev/null || true
}

# _mcp_review_flags <base_allowed_tools>
# Threads the opt-in MCP config into the claude agentic/duck tiers. Populates two
# globals for the caller to splice into the claude --print invocation:
#   _MCP_ALLOWED_TOOLS — base_allowed_tools with REVIEW_MCP_ALLOWED_TOOLS merged
#                        in (comma-separated). Equals base when no MCP tools set.
#   _MCP_FLAGS         — array: (--mcp-config <file> --strict-mcp-config) when
#                        REVIEW_MCP_CONFIG points to a readable file; empty array
#                        otherwise.
# Verified against @anthropic-ai/claude-code 2.1.138 (claude --help):
#   --mcp-config <configs...>  Load MCP servers from JSON files or strings
#   --strict-mcp-config        Only use MCP servers from --mcp-config, ignoring
#                              all other MCP configurations
# When REVIEW_MCP_CONFIG is unset/empty/unreadable, _MCP_FLAGS stays empty and
# _MCP_ALLOWED_TOOLS == base_allowed_tools → no new flags, behavior unchanged.
_mcp_review_flags() {
  local base="$1"
  _MCP_FLAGS=()
  _MCP_ALLOWED_TOOLS="$base"
  if [ -n "${REVIEW_MCP_CONFIG:-}" ] && [ -f "${REVIEW_MCP_CONFIG}" ] && [ -r "${REVIEW_MCP_CONFIG}" ]; then
    _MCP_FLAGS=(--mcp-config "$REVIEW_MCP_CONFIG" --strict-mcp-config)
    if [ -n "${REVIEW_MCP_DEBUG:-}" ]; then
      # Surface the MCP server handshake in the CLI's stderr (captured + scanned
      # by _emit_mcp_failure_warning). `--debug mcp` scopes debug to the MCP
      # subsystem only, so the log stays readable. Diagnostics-only opt-in.
      _MCP_FLAGS+=(--debug mcp)
    fi
    if [ -n "${REVIEW_MCP_ALLOWED_TOOLS:-}" ]; then
      _MCP_ALLOWED_TOOLS="${base},${REVIEW_MCP_ALLOWED_TOOLS}"
    fi
  elif [ -n "${REVIEW_MCP_CONFIG:-}" ]; then
    echo "  [mcp] REVIEW_MCP_CONFIG='$REVIEW_MCP_CONFIG' is not a readable file — skipping MCP flags" >&2
  fi
}

# run_triage <prompt_file>
# Used by: review-one-pr.sh only (not the dev-lead writer pipeline).
# No-tool mode. The prompt file already has all PR context inlined by the
# caller (review-one-pr.sh builds it). Every tool is denied so the model
# can't wander into the working directory and discover prs.txt or other
# state.
#
# Wrapped in a transient-retry loop because the caller captures stdout via
# $(...), so re-running on a timeout/kill is safe — the variable receives only
# the last attempt's output. Per-tier timeout from TRIAGE_TIMEOUT_SEC.
run_triage() {
  local prompt_file="$1"
  local attempt=1 rc=0
  local _t_start _t_end _dur=""
  # Capture output for token estimation when logging is enabled (tee is a no-op otherwise).
  local _tok_tmp=""
  if [ -n "${TOKEN_LOG_FILE:-}" ]; then
    unset _ENGINE_USAGE_OUT
    _tok_tmp="$(mktemp 2>/dev/null || true)"
    # Per-call usage-sidecar key: a unique mktemp path, exported so the engine's
    # pipeline subshell and _record_engine_tokens agree on it. Unique per call →
    # concurrent run_agentic/run_duck (review-one-pr.sh) never collide.
    [[ -n "$_tok_tmp" ]] && local -x _ENGINE_USAGE_OUT="${_tok_tmp}.usage"
  fi
  while [ "$attempt" -le "$RETRY_MAX_ATTEMPTS" ]; do
    rc=0
    # Whether the claude redirect path still owes its buffered stdout to the caller
    # (reset per attempt). The gemini/copilot branches tee during the call, so they
    # leave this at 0 — only the claude redirect defers its emit (see below).
    local _tok_emit_pending=0
    [ -n "$_tok_tmp" ] && : > "$_tok_tmp"
    _t_start="$(_now_ms)"
    case "$REVIEW_ENGINE" in
      claude)
        local _triage_chain="${CLAUDE_TRIAGE_MODEL_CHAIN:-$ENGINE_TRIAGE_MODEL}"
        if [ -n "$_tok_tmp" ]; then
          # Redirect to the token sidecar and re-emit with `cat`, rather than piping
          # through `| tee`: a pipe runs _claude_chain_invoke in a SUBSHELL, so the
          # _CLAUDE_CHAIN_MODEL_USED it exports (the model that ACTUALLY produced the
          # output, after any rate-limit fallback) never reaches this shell — the
          # token record was then mis-attributed to the chain head (#1952, cubic P2).
          # Running it in THIS shell preserves the final model for the record below.
          _CLAUDE_CHAIN_MODEL_USED=""
          _claude_chain_invoke "$_triage_chain" "$prompt_file" "$TRIAGE_TIMEOUT_SEC" \
            --disallowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch,WebSearch,Task,TodoWrite,NotebookEdit" \
            >"$_tok_tmp" || rc=$?
          # Defer the emit instead of `cat`-ing unconditionally: a failed attempt
          # that will be RETRIED must not leak its partial bytes ahead of the
          # retry's clean verdict into the caller's $(...) capture (the retry would
          # be CONCATENATED behind this attempt, contaminating rate-limit detection
          # and verdict parsing). Emitted below only on success or a final,
          # un-retried failure (#1952, cubic P2).
          _tok_emit_pending=1
        else
          _claude_chain_invoke "$_triage_chain" "$prompt_file" "$TRIAGE_TIMEOUT_SEC" \
            --disallowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch,WebSearch,Task,TodoWrite,NotebookEdit" \
            || rc=$?
        fi
        ;;
      gemini)
        local _triage_gemini_chain
        _triage_gemini_chain="$(ai_models_gemini_chain triage)"
        _triage_gemini_chain="${_triage_gemini_chain:-$ENGINE_TRIAGE_MODEL}"
        if [ -n "$_tok_tmp" ]; then
          _GEMINI_CHAIN_MODEL_USED=""
          _gemini_chain_invoke "$_triage_gemini_chain" "$prompt_file" "$TRIAGE_TIMEOUT_SEC" \
            --approval-mode auto_edit > >(tee "$_tok_tmp") || rc=$?
        else
          _gemini_chain_invoke "$_triage_gemini_chain" "$prompt_file" "$TRIAGE_TIMEOUT_SEC" \
            --approval-mode auto_edit || rc=$?
        fi
        ;;
      copilot)
        # In triage mode, deny the mutating tools to keep it fast and restricted.
        # The rule format is a tool kind (`shell`, `write`, `shell(cmd)`); a bare
        # `*` is rejected ("Invalid rule format: *"), which broke this fallback
        # outright (#1957). Tools not explicitly allowed are not auto-approved
        # in non-interactive -p mode either.
        local _copilot_tier_model
        _copilot_tier_model="$(ai_models_copilot_model triage)"
        local -x COPILOT_API_MODEL="$_copilot_tier_model"
        if [ -n "$_tok_tmp" ]; then
          copilot_chat "$prompt_file" "$TRIAGE_TIMEOUT_SEC" --deny-tool shell --deny-tool write | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
        else
          copilot_chat "$prompt_file" "$TRIAGE_TIMEOUT_SEC" --deny-tool shell --deny-tool write || rc=$?
        fi
        ;;
    esac
    _t_end="$(_now_ms)"
    _dur="$(_elapsed_ms "$_t_start" "$_t_end")"
    if [ "$rc" -eq 0 ]; then
      # Success: hand the buffered output to the caller now (claude redirect path).
      [ "$_tok_emit_pending" -eq 1 ] && cat "$_tok_tmp"
      local _triage_used
      if [ "$REVIEW_ENGINE" = "claude" ] && [ -n "${_CLAUDE_CHAIN_MODEL_USED:-}" ]; then
        _triage_used="$_CLAUDE_CHAIN_MODEL_USED"
      elif [ "$REVIEW_ENGINE" = "gemini" ] && [ -n "${_GEMINI_CHAIN_MODEL_USED:-}" ]; then
        _triage_used="$_GEMINI_CHAIN_MODEL_USED"
      else
        # No chain published the final model (copilot, or an engine that does not set
        # _*_CHAIN_MODEL_USED): fall back to the tier default. The claude and gemini
        # invokes above now run in THIS shell (redirect/process-substitution, not a
        # `| tee` subshell), so a PINNED or fallen-back model is captured by the two
        # branches above rather than mis-recorded as the chain head here (#1952).
        _triage_used="$ENGINE_TRIAGE_MODEL"
      fi
      _record_engine_tokens "triage" "$REVIEW_ENGINE" "$_triage_used" "$prompt_file" "$_tok_tmp" "$_dur"
      _record_model_used "$_triage_used"
      [ -n "$_tok_tmp" ] && rm -f "$_tok_tmp"
      return 0
    fi
    # Distinguish a `timeout --kill-after` budget-exhaustion SIGKILL from a genuine
    # transient signal kill — both surface as 137 (128+9), but only the former is
    # non-retryable. Every triage engine call above is wrapped by `timeout
    # --kill-after`, so when a call exits 137 AFTER consuming its full
    # TRIAGE_TIMEOUT_SEC budget, `timeout` force-killed a process that ignored the
    # initial SIGTERM — the same budget-exhausted condition as a plain 124 stage
    # timeout, which re-running at the same budget would only repeat (#1028). An
    # early 137 (e.g. an OOM kill well under budget) keeps is_transient_failure's
    # retry. Collapse only the at-budget case to 124 so it takes the NON-retryable
    # timeout path, using the latency run_triage already measured (#1952 cubic P1).
    if [ "$rc" -eq 137 ] && [ -n "$_dur" ] && [ "$_dur" -ge "$(( TRIAGE_TIMEOUT_SEC * 1000 ))" ]; then
      rc=124
    fi
    if [ "$attempt" -lt "$RETRY_MAX_ATTEMPTS" ] && is_transient_failure "$rc"; then
      # Retrying: the deferred stdout of this failed attempt is intentionally
      # DROPPED (the loop top truncates $_tok_tmp) so only the retry's output
      # reaches the caller's capture (#1952, cubic P2).
      local delay=$(( RETRY_BASE_DELAY_SEC * (2 ** (attempt - 1)) ))
      echo "    [triage] transient failure (exit $rc), retrying in ${delay}s (attempt $((attempt + 1))/$RETRY_MAX_ATTEMPTS)" >&2
      sleep "$delay"
      attempt=$((attempt + 1))
      continue
    fi
    # Final (un-retried) failure: emit the last attempt's bytes so the caller's
    # rate-limit detection still sees them (#1952, cubic P2).
    [ "$_tok_emit_pending" -eq 1 ] && cat "$_tok_tmp"
    [ -n "$_tok_tmp" ] && rm -f "$_tok_tmp"
    return "$rc"
  done
  [ -n "$_tok_tmp" ] && rm -f "$_tok_tmp"
  return "$rc"
}

# run_agentic <prompt_file> <model> [tier] [allowed_tools] [skip_mcp]
# Used by: review-one-pr.sh (full tool access) and run_persona (Bash-only, to
# match the live persona runtime — see run_persona).
# allowed_tools defaults to the full review posture "Bash,Read,Grep,Glob"; callers
# that must mirror a narrower runtime pass their own comma-separated set.
# skip_mcp (non-empty) bypasses MCP merging so allowed_tools is passed through
# verbatim — used by run_persona, whose live runtime grants no MCP tools, so the
# opt-in MCP knobs must never widen its Bash-only allowlist (#1696).
#
# No retry here: callers redirect stdout to a file, so a retry inside this
# function would append the second attempt's output to a partial first-attempt
# file. Transient failures here become session-fatal via the workflow circuit
# breaker — that's the intended trade-off for the long, expensive tier.
# Per-tier timeout from DEEP_TIMEOUT_SEC (also applies to action/audit calls;
# they're all the same agentic shape and similarly priced).
run_agentic() {
  local prompt_file="$1"
  local model="$2"
  local tier="${3:-deep}"
  local _allowed_tools="${4:-Bash,Read,Grep,Glob}"
  local _skip_mcp="${5:-}"
  local _tok_tmp="" rc=0
  local _t_start _t_end _dur=""
  if [ -n "${TOKEN_LOG_FILE:-}" ]; then
    unset _ENGINE_USAGE_OUT
    _tok_tmp="$(mktemp 2>/dev/null || true)"
    # Per-call usage-sidecar key: a unique mktemp path, exported so the engine's
    # pipeline subshell and _record_engine_tokens agree on it. Unique per call →
    # concurrent run_agentic/run_duck (review-one-pr.sh) never collide.
    [[ -n "$_tok_tmp" ]] && local -x _ENGINE_USAGE_OUT="${_tok_tmp}.usage"
  fi
  _t_start="$(_now_ms)"
  case "$REVIEW_ENGINE" in
    claude)
      # Resolve the in-Claude model chain for this tier. The chain is the
      # cascade tried on rate-limit (e.g. sonnet → opus). If the caller
      # passed a model that does NOT match the tier's default ENGINE_*_MODEL,
      # treat it as an explicit pin: honor it as a single-element chain so
      # callers can still force a specific model when they need to (the
      # documented `[model]` parameter on this function). The chain is only
      # applied when the caller used the default model for the tier.
      local _agentic_chain _tier_default=""
      case "$tier" in
        deep)   _tier_default="${ENGINE_DEEP_MODEL:-}"
                _agentic_chain="${CLAUDE_DEEP_MODEL_CHAIN:-$model}"   ;;
        audit)  _tier_default="${ENGINE_AUDIT_MODEL:-}"
                _agentic_chain="${CLAUDE_AUDIT_MODEL_CHAIN:-$model}"  ;;
        action) _tier_default="${ENGINE_ACTION_MODEL:-}"
                _agentic_chain="${CLAUDE_ACTION_MODEL_CHAIN:-$model}" ;;
        single) _tier_default="${ENGINE_SINGLE_MODEL:-}"
                _agentic_chain="${CLAUDE_SINGLE_MODEL_CHAIN:-$model}" ;;
        *)      _agentic_chain="$model" ;;
      esac
      if [ -n "$_tier_default" ] && [ "$model" != "$_tier_default" ]; then
        _agentic_chain="$model"
      fi
      # Thread the opt-in MCP config (no-op when REVIEW_MCP_CONFIG is unset).
      # The persona parity path (skip_mcp) bypasses merging entirely so the
      # allowlist stays exactly the Bash-only posture the live persona runtime
      # ships — MCP knobs must never widen it to Bash,<MCP tools> (#1696).
      if [ -n "$_skip_mcp" ]; then
        _MCP_FLAGS=()
        _MCP_ALLOWED_TOOLS="$_allowed_tools"
      else
        _mcp_review_flags "$_allowed_tools"
      fi
      # Reasoning-effort pin (#1898 AC-3; #1901 AC-2; Story-2/#1897 AC-4 finding):
      # the deep tier model's CLI/API default reasoning effort is `medium` (levels
      # low/medium/high/xhigh/max) — below `high`. The deep, audit and single
      # tiers all run opus-5-5 (audit/single moved off Fable in #1901), so each
      # explicitly pins `--effort high` — otherwise dropping Fable would silently
      # lower audit/single reasoning effort. triage/action keep the CLI default
      # (they run cheaper models where the extra thinking spend is not warranted).
      local _effort_args=()
      case "$tier" in deep|audit|single) _effort_args=(--effort high) ;; esac
      if [ -n "$_tok_tmp" ]; then
        _claude_chain_invoke "$_agentic_chain" "$prompt_file" "$DEEP_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "$_MCP_ALLOWED_TOOLS" \
          ${_effort_args[@]+"${_effort_args[@]}"} \
          ${_MCP_FLAGS[@]+"${_MCP_FLAGS[@]}"} \
          | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
      else
        _claude_chain_invoke "$_agentic_chain" "$prompt_file" "$DEEP_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "$_MCP_ALLOWED_TOOLS" \
          ${_effort_args[@]+"${_effort_args[@]}"} \
          ${_MCP_FLAGS[@]+"${_MCP_FLAGS[@]}"} \
          || rc=$?
      fi
      ;;
    gemini)
      # The tier's own chain (AI_MODELS_GEMINI deep/audit/single/action). Honor
      # explicit model pin when it differs from the tier default.
      local _agentic_gemini_chain _gemini_tier_default="" _gemini_tier
      case "$tier" in
        deep)   _gemini_tier_default="${ENGINE_DEEP_MODEL:-}" ;;
        audit)  _gemini_tier_default="${ENGINE_AUDIT_MODEL:-}" ;;
        single) _gemini_tier_default="${ENGINE_SINGLE_MODEL:-}" ;;
        *)      _gemini_tier_default="${ENGINE_ACTION_MODEL:-}" ;;
      esac
      case "$tier" in deep|audit|single) _gemini_tier="$tier" ;; *) _gemini_tier=action ;; esac
      _agentic_gemini_chain="$(ai_models_gemini_chain "$_gemini_tier")"
      _agentic_gemini_chain="${_agentic_gemini_chain:-$model}"
      if [ -n "$_gemini_tier_default" ] && [ "$model" != "$_gemini_tier_default" ]; then
        _agentic_gemini_chain="$model"
      fi
      if [ -n "$_tok_tmp" ]; then
        _GEMINI_CHAIN_MODEL_USED=""
        _gemini_chain_invoke "$_agentic_gemini_chain" "$prompt_file" "$DEEP_TIMEOUT_SEC" \
          --approval-mode auto_edit > >(tee "$_tok_tmp") || rc=$?
      else
        _gemini_chain_invoke "$_agentic_gemini_chain" "$prompt_file" "$DEEP_TIMEOUT_SEC" \
          --approval-mode auto_edit || rc=$?
      fi
      ;;
    copilot)
      # Full tool support via GitHub Copilot CLI agentic mode (--yolo).
      # Do NOT tee stdout to OUTPUT_FILE: the prompt instructs the model to
      # write the verdict JSON directly to $OUTPUT_FILE via the Bash tool.
      # Teeing stdout (which includes assistant text and tool transcripts)
      # would overwrite that file and corrupt the JSON.
      local _copilot_tier_model
      case "$tier" in
        deep|audit|single) _copilot_tier_model="$(ai_models_copilot_model "$tier")" ;;
        *)                 _copilot_tier_model="$(ai_models_copilot_model action)" ;;
      esac
      local -x COPILOT_API_MODEL="$_copilot_tier_model"
      if [ -n "$_tok_tmp" ]; then
        copilot_chat "$prompt_file" "$DEEP_TIMEOUT_SEC" --yolo | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
      else
        copilot_chat "$prompt_file" "$DEEP_TIMEOUT_SEC" --yolo || rc=$?
      fi
      ;;
  esac
  _t_end="$(_now_ms)"
  _dur="$(_elapsed_ms "$_t_start" "$_t_end")"
  if [ "$rc" -eq 0 ]; then
    local _agentic_used="$model"
    if [ "$REVIEW_ENGINE" = "claude" ] && [ -n "${_CLAUDE_CHAIN_MODEL_USED:-}" ]; then
      _agentic_used="$_CLAUDE_CHAIN_MODEL_USED"
    elif [ "$REVIEW_ENGINE" = "gemini" ] && [ -n "${_GEMINI_CHAIN_MODEL_USED:-}" ]; then
      _agentic_used="$_GEMINI_CHAIN_MODEL_USED"
    fi
    _record_engine_tokens "$tier" "$REVIEW_ENGINE" "$_agentic_used" "$prompt_file" "$_tok_tmp" "$_dur"
    _record_model_used "$_agentic_used"
  fi
  [ -n "$_tok_tmp" ] && rm -f "$_tok_tmp"
  return "$rc"
}

# run_persona <prompt_file>
# Eval-harness parity tier for persona advisory skills (#1686). Bridges the
# eval scorer's one-argument calling convention (`<cmd> <prompt_file>`, see
# scripts/evals/run-eval.sh) to run_agentic's `<prompt_file> <model> [tier]
# [allowed_tools]` shape WITHOUT changing that convention for every existing skill.
# It scores the skill on the SAME tier + tool posture the live persona runtime uses
# (.github/workflows/persona-runner-reusable.yml: `--fallback-model opus` +
# `--allowedTools Bash`): the deep (Opus) model chain, allowed ONLY the Bash tool.
# It must NOT use run_agentic's default review posture (Bash,Read,Grep,Glob), which
# would score a more tool-capable artifact than the one that ships (#1686). A persona
# eval that scored the Haiku-tier run_triage would likewise gate the wrong artifact —
# a weaker model — so a scorer.json declaring `"engine": "persona"` routes here
# instead. Not used by any non-persona skill.
run_persona() {
  # The live persona runtime is Claude Opus with `--allowedTools Bash` only
  # (persona-runner-reusable.yml). Only the claude engine honors that Bash-only
  # allowlist: gemini uses gemini-2.5-pro and ignores --allowed-tools, copilot
  # runs o4-mini with --yolo — either would score a differently-modelled, more
  # tool-capable artifact than production ships. A persona parity score under a
  # non-claude engine is meaningless, so fail fast rather than silently gate the
  # wrong artifact (#1696).
  if [ "$REVIEW_ENGINE" != "claude" ]; then
    echo "::error::run_persona requires REVIEW_ENGINE=claude (persona parity is Claude Opus + Bash-only); got '$REVIEW_ENGINE'" >&2
    return 1
  fi
  # Environment boundary (#1696): the eval feeds an UNTRUSTED held-out case into
  # the prompt and the parity posture grants the Bash tool, so a prompt-injected
  # shell command could try to read a token, push to the repo, or hit the GitHub
  # API. The in-prompt untrusted-data directive (prompts/qa-lead/advisory.md) is
  # only defence-in-depth — a boundary that lives solely in the model prompt is
  # not a boundary. Enforce it OUTSIDE the prompt here: run the invocation in a
  # subshell with every GitHub credential scrubbed from the environment, so even
  # if the model obeys an injection there is no token to exfiltrate and no
  # authenticated path to write a repo or call the GitHub API. This is faithful
  # to parity, not a departure from it: parity is the MODEL + TOOL posture (Opus
  # + Bash-only), and the live persona runtime is deliberately read-only with no
  # write token (advisory.md) — so denying credentials makes the eval MORE like
  # production, never less. (The model API call needs network and its own
  # CLAUDE_CODE_OAUTH_TOKEN, and the skill must read the checked-out BMAD data,
  # so network egress to the model and repo READ access are intentionally
  # retained — they are required for the eval to run at all.)
  (
    unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN \
          GITHUB_API_TOKEN GH_HOST
    # skip_mcp: the persona workflow grants no MCP tools, so parity must never widen
    # the allowlist beyond Bash even when REVIEW_MCP_CONFIG is set (#1696).
    run_agentic "$1" "$ENGINE_DEEP_MODEL" deep "Bash" skip-mcp
  )
}

# run_writer <prompt_file> [model]
# Full write-access mode for applying code fixes.
# When DEV_LEAD_DRY_RUN=true: builds prompt but does NOT call engine; exits 0.
# Exit codes: 0=success, 1=non-retriable failure, 2=rate-limited
# On exit 2, writes parsed reset timestamp to /tmp/dev-lead-rate-limit-reset.
run_writer() {
  local prompt_file="$1"
  local model="${2:-$ENGINE_ACTION_MODEL}"
  # [tier] (tier_for_intent) names the tier whose whole chain the writer walks.
  # Without it, <model> is mapped back to the tier whose ENGINE_*_MODEL it is
  # (action first); empty means an explicit pin that runs alone.
  local _writer_tier="${3:-}"
  [ -n "$_writer_tier" ] || case "$model" in
    "${ENGINE_ACTION_MODEL:-}") _writer_tier=action ;;
    "${ENGINE_DEEP_MODEL:-}")   _writer_tier=deep ;;
    "${ENGINE_TRIAGE_MODEL:-}") _writer_tier=triage ;;
    "${ENGINE_AUDIT_MODEL:-}")  _writer_tier=audit ;;
    "${ENGINE_SINGLE_MODEL:-}") _writer_tier=single ;;
  esac

  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "  [dry-run] run_writer: would invoke $REVIEW_ENGINE with prompt $(wc -l < "$prompt_file") lines"
    return 0
  fi

  # Capture stdout to a temp file so is_rate_limited can inspect it, while
  # still streaming output to the caller. The old approach read from
  # /tmp/dev-lead-writer-stderr which was never written (claude --print outputs
  # to stdout, not stderr), so is_rate_limited never fired and fallback engines
  # were never tried.
  local _tmp rc=0
  local _t_start _t_end _dur=""
  unset _ENGINE_USAGE_OUT
  _tmp="$(mktemp 2>/dev/null || true)"
  # Per-call usage-sidecar key (see run_triage); unique mktemp path shared with
  # the engine subshell via export.
  [[ -n "$_tmp" ]] && local -x _ENGINE_USAGE_OUT="${_tmp}.usage"

  _t_start="$(_now_ms)"
  case "$REVIEW_ENGINE" in
    claude)
      # The selected tier's chain (CLAUDE_<TIER>_MODEL_CHAIN); an explicit
      # model pin that matches no tier runs alone.
      local _writer_chain="$model" _writer_chain_var
      if [ -n "$_writer_tier" ]; then
        _writer_chain_var="CLAUDE_$(printf '%s' "$_writer_tier" | tr '[:lower:]' '[:upper:]')_MODEL_CHAIN"
        _writer_chain="${!_writer_chain_var:-$model}"
      fi
      if [ -n "$_tmp" ]; then
        _claude_chain_invoke "$_writer_chain" "$prompt_file" "$ACTION_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch" \
          2>&1 | tee "$_tmp" || rc=${PIPESTATUS[0]}
      else
        _claude_chain_invoke "$_writer_chain" "$prompt_file" "$ACTION_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch" \
          || rc=$?
      fi
      ;;
    gemini)
      # The selected tier's chain; an explicit model pin runs alone.
      local _writer_gemini_chain="$model"
      if [ -n "$_writer_tier" ]; then
        _writer_gemini_chain="$(ai_models_gemini_chain "$_writer_tier")"
        _writer_gemini_chain="${_writer_gemini_chain:-$model}"
      fi
      if [ -n "$_tmp" ]; then
        _GEMINI_CHAIN_MODEL_USED=""
        _gemini_chain_invoke "$_writer_gemini_chain" "$prompt_file" "$ACTION_TIMEOUT_SEC" \
          --approval-mode auto_edit > >(tee "$_tmp") 2>&1 || rc=$?
      else
        _gemini_chain_invoke "$_writer_gemini_chain" "$prompt_file" "$ACTION_TIMEOUT_SEC" \
          --approval-mode auto_edit || rc=$?
      fi
      ;;
    copilot)
      # Self-sufficient write support via gh copilot --yolo: the selected
      # tier's Copilot id; a full vendor/model pin is used as is; anything
      # else falls back to the action tier.
      local _copilot_tier_model
      case "$_writer_tier:$model" in
        :*/*) _copilot_tier_model="$model" ;;
        :*)   _copilot_tier_model="$(ai_models_copilot_model action)" ;;
        *)    _copilot_tier_model="$(ai_models_copilot_model "$_writer_tier")" ;;
      esac
      local -x COPILOT_API_MODEL="$_copilot_tier_model"
      if [ -n "$_tmp" ]; then
        copilot_chat "$prompt_file" "$ACTION_TIMEOUT_SEC" --yolo 2>&1 | tee "$_tmp" || rc=${PIPESTATUS[0]}
      else
        copilot_chat "$prompt_file" "$ACTION_TIMEOUT_SEC" --yolo || rc=$?
      fi
      ;;
  esac

  _t_end="$(_now_ms)"
  _dur="$(_elapsed_ms "$_t_start" "$_t_end")"
  if [ "$rc" -eq 0 ]; then
    local _writer_used="$model"
    if [ "$REVIEW_ENGINE" = "claude" ] && [ -n "${_CLAUDE_CHAIN_MODEL_USED:-}" ]; then
      _writer_used="$_CLAUDE_CHAIN_MODEL_USED"
    elif [ "$REVIEW_ENGINE" = "gemini" ] && [ -n "${_GEMINI_CHAIN_MODEL_USED:-}" ]; then
      _writer_used="$_GEMINI_CHAIN_MODEL_USED"
    fi
    _record_engine_tokens "writer" "$REVIEW_ENGINE" "$_writer_used" "$prompt_file" "$_tmp" "$_dur"
  fi
  if [ -n "$_tmp" ]; then
    # Redact once: write secret-scrubbed content to the persisted path, then
    # use that redacted file as the source for the step summary so credentials
    # cannot leak via /tmp persistence or the public run summary. Patterns
    # kept in sync with scripts/dev-lead-fix-reviews.sh:redact_secrets.
    #
    # This runs for ALL terminal paths — success, generic failure, AND the
    # rate-limit early return below — so the session output (where the real
    # failure cause appears) reaches the run summary and the persisted sidecar
    # regardless of exit code. The rate-limit check further down reads the raw
    # capture ($_tmp), which redaction leaves intact (separate file), so
    # persisting first is safe.
    rm -f /tmp/dev-lead-session-output.txt
    if ! sed -E \
      -e 's/(gh[opsu]|ghr)_[A-Za-z0-9_]{20,}/***REDACTED-GH-TOKEN***/g' \
      -e 's/github_pat_[A-Za-z0-9_]{20,}/***REDACTED-GH-PAT***/g' \
      -e 's/sk-(ant-)?[A-Za-z0-9_-]{20,}/***REDACTED-API-KEY***/g' \
      -e 's/AKIA[A-Z0-9]{16}/***REDACTED-AWS-KEY***/g' \
      -e 's/AIza[A-Za-z0-9_-]{35}/***REDACTED-GOOGLE-KEY***/g' \
      -e 's|ya29\.[A-Za-z0-9_-]+|***REDACTED-GOOGLE-OAUTH***|g' \
      -e 's/[Bb]earer [A-Za-z0-9._-]{20,}/Bearer ***REDACTED***/g' \
      -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\
***REDACTED-PRIVATE-KEY***' \
      "$_tmp" > /tmp/dev-lead-session-output.txt; then
      : > /tmp/dev-lead-session-output.txt 2>/dev/null || true
      echo "::warning::Failed to redact/persist /tmp/dev-lead-session-output.txt" >&2
    fi
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      # HTML-escape the redacted log so literal </details> or </summary> in
      # the agent output cannot break the wrapping <details> block on the run
      # summary page.
      {
        echo "## Dev-Lead session output"
        echo "<details><summary>Click to expand session logs</summary>"
        echo ""
        echo "<pre>"
        sed 's|&|\&amp;|g; s|<|\&lt;|g; s|>|\&gt;|g' /tmp/dev-lead-session-output.txt
        echo "</pre>"
        echo ""
        echo "</details>"
      } >> "$GITHUB_STEP_SUMMARY" || \
        echo "::warning::Failed to append session output to GITHUB_STEP_SUMMARY" >&2
    fi
  fi

  # Map rate-limit to exit code 2 for caller to detect; parse reset time for
  # marker embedding. Use the file-based helpers to avoid OOM on large captures.
  # Runs AFTER the persist/summary block above so a rate-limited session is also
  # captured to the run summary; reads the raw capture ($_tmp) left intact above.
  if [ "$rc" -ne 0 ] && [ -n "$_tmp" ] && is_rate_limited_files "$_tmp"; then
    parse_reset_time_files "$_tmp"
    rm -f "$_tmp"
    return 2
  fi
  # Copilot licensing/policy denial (#1546): the org's Copilot subscription
  # ended, so `gh copilot` fails deterministically with "Access denied by policy
  # settings". That is not a rate-limit phrase, so without this the raw exit
  # would be classified as engine-error and abort the chain before gemini. Map it
  # to exit 2 so run_writer_with_fallback warns and continues to the next engine.
  if [ "$rc" -ne 0 ] && [ -n "$_tmp" ] && is_license_denied_files "$_tmp"; then
    echo "::warning::$REVIEW_ENGINE licensing/policy denial — treating as unavailable, trying next engine" >&2
    rm -f "$_tmp"
    return 2
  fi
  [ -n "$_tmp" ] && rm -f "$_tmp"
  return "$rc"
}

# ── Run-scoped engine-exhaustion registry (issue #947) ────────────────────────
# Once an engine is found rate-limited / unavailable during this run (process),
# it is recorded here so later run_writer_with_fallback calls in the SAME run do
# NOT re-invoke it. The #860 runaway re-walked claude → gemini → copilot on every
# dev-lead-fix-ci cycle, re-burning quota on an already-exhausted engine and
# re-posting the same usage-limit notice. Keyed by engine name → reason
# (rate-limited | missing-binary). Guarded so a re-source of engine.sh in the
# same process (e.g. review-batch's copilot pre-flight) does not wipe live state.
if ! declare -p _ENGINE_EXHAUSTED_REASON >/dev/null 2>&1; then
  declare -gA _ENGINE_EXHAUSTED_REASON
fi

# reset_engine_exhaustion — clear the registry. Exhaustion is intentionally
# run-scoped, so production code never calls this; it exists for test isolation.
reset_engine_exhaustion() {
  _ENGINE_EXHAUSTED_REASON=()
}

# _engine_is_exhausted <engine> — 0 if already marked exhausted this run.
_engine_is_exhausted() {
  [ -n "${1:-}" ] && [ -n "${_ENGINE_EXHAUSTED_REASON["$1"]:-}" ]
}

# _mark_engine_exhausted <engine> <reason>
# Record the engine as exhausted for the rest of the run and emit EXACTLY ONE
# notice (at most one notice per engine per run). No-op on repeat marks so a
# multi-cycle caller cannot produce a notice storm.
_mark_engine_exhausted() {
  local engine="${1:-}" reason="${2:-rate-limited}"
  [ -z "$engine" ] && return 0
  [ -n "${_ENGINE_EXHAUSTED_REASON["$engine"]:-}" ] && return 0
  _ENGINE_EXHAUSTED_REASON["$engine"]="$reason"
  echo "::warning::[engine-exhaustion] ${engine} marked exhausted for this run (${reason}) — it will not be re-invoked" >&2
}

# run_writer_with_fallback <prompt_file> [intent_type]
# Tries primary engine, falls back through claude → gemini → copilot on rate-limit.
# intent_type is passed to model_for_intent() so each engine uses the appropriate
# tier model for the given task complexity (e.g. haiku for triage, sonnet for writes).
# Only rate-limit (exit 2) and missing-binary (exit 127) trigger fallback;
# other failures propagate immediately.
# An engine found rate-limited/unavailable in an earlier call this run is skipped
# (not re-invoked) — see the exhaustion registry above (#947).
run_writer_with_fallback() {
  local prompt_file="$1"
  local intent="${2:-}"

  # Clear any stale failure-reason sidecar from a prior invocation in the same
  # process. Before each terminal failure return below we write a one-line
  # cause class (rate-limited | missing-binary | engine-error) to this path,
  # mirroring the existing /tmp/dev-lead-rate-limit-reset sidecar. Downstream
  # handlers (dev-lead-fix-issue.sh) read it to classify the failure and pick
  # the right retry behavior. This is purely additive — no control-flow change.
  # The timeout-* sidecars (tier/budget/elapsed) are written only on a per-tier
  # timeout (#1018); clear any stale copies here so a later non-timeout failure
  # never surfaces a previous run's timeout context.
  rm -f /tmp/dev-lead-failure-reason \
        /tmp/dev-lead-timeout-tier \
        /tmp/dev-lead-timeout-budget \
        /tmp/dev-lead-timeout-elapsed

  # Engine chain: AI_ENGINES (org/repo variable; DEV_LEAD_ENGINES is the legacy
  # #1546 name) enables engines and orders the fallbacks, so an engine can be
  # dropped or re-ordered without a code change. Parsed by
  # scripts/lib/engine-chain.sh: an unknown token (typo) invalidates the WHOLE
  # value and the full default chain is used, so "claude,cluade" never becomes
  # claude-only. The primary REVIEW_ENGINE is tried first when it is enabled;
  # the remaining enabled engines follow in the configured order.
  local _enabled=()
  local e
  if declare -F ai_engine_chain >/dev/null 2>&1; then
    local -a _chain_engines=()
    IFS=' ' read -r -a _chain_engines <<< "$(ai_engine_chain)"
    _enabled=("${_chain_engines[@]}")
  else
    _enabled=(claude gemini copilot)
  fi

  local engines=()
  # Primary first when it is an enabled engine.
  for e in "${_enabled[@]}"; do
    [ "$e" = "$REVIEW_ENGINE" ] && engines+=("$e")
  done
  for e in "${_enabled[@]}"; do
    [ "$e" != "$REVIEW_ENGINE" ] && engines+=("$e")
  done

  local any_rate_limited=0
  local any_missing=0
  # A deterministic credential config-gap (missing/placeholder/unsupported engine
  # token) is tracked separately from quota exhaustion (#1591). It must NOT feed
  # any_rate_limited — retrying cannot conjure a secret, so classifying it as a
  # retryable rate-limit sends the retry cron back at an unchangeable state and
  # burns cycles. When it is the SOLE terminal cause, the aggregate reason is a
  # distinct `unconfigured` so the caller escalates to a human instead of retrying.
  local any_unconfigured=0
  for engine in "${engines[@]}"; do
    if [ "$engine" = "copilot" ] && [[ "${COPILOT_GITHUB_TOKEN:-}" == ghp_* ]]; then
      echo "::warning::Skipping copilot fallback: classic PAT in COPILOT_GITHUB_TOKEN is unsupported (configuration gap, not a rate limit)" >&2
      any_unconfigured=1
      continue
    fi
    # A missing/placeholder Copilot token is a deterministic configuration gap, not
    # a rate limit. Skip it here (plain continue) so it never reaches the headroom
    # probe, whose return-1 skip would otherwise be classified as any_rate_limited
    # below — making callers retry a config error as though a later attempt could
    # succeed (#1546). Record it as a config-gap so the aggregate reason is the
    # distinct `unconfigured`, not the retryable `engine-error` (#1591).
    if [ "$engine" = "copilot" ] && { [ -z "${COPILOT_GITHUB_TOKEN:-}" ] || [[ ! "${COPILOT_GITHUB_TOKEN:-}" =~ ^(github_pat_|ghp_|ghs_) ]]; }; then
      echo "::warning::Skipping copilot fallback: COPILOT_GITHUB_TOKEN missing or unsupported (configuration gap, not a rate limit)" >&2
      any_unconfigured=1
      continue
    fi
    # A missing Gemini API key is the same deterministic credential config-gap as a
    # missing/placeholder Copilot token (#1591): record it so a Gemini-only run
    # with no key yields the distinct non-retryable `unconfigured` reason rather
    # than the retryable `engine-error`. Retrying cannot conjure an API key. The
    # extra resilience keys (GOOGLE_API_KEY_2/_3/_4, #1777) also count as configured,
    # so a run authenticated only by a secondary key is NOT treated as a config-gap.
    if [ "$engine" = "gemini" ] && [ -z "$(_gemini_api_keys)" ]; then
      echo "::warning::Skipping gemini fallback: no Gemini API key configured (GEMINI_API_KEY / GOOGLE_API_KEY / GOOGLE_API_KEY_2 / GOOGLE_API_KEY_3 / GOOGLE_API_KEY_4) — configuration gap, not a rate limit" >&2
      any_unconfigured=1
      continue
    fi

    # Run-scoped exhaustion (#947): an engine already found rate-limited/
    # unavailable earlier in this run is not re-invoked. Reflect its recorded
    # reason into the aggregate so the final return code is unchanged, and emit
    # no repeat notice (the one-time notice fired when it was first marked).
    if _engine_is_exhausted "$engine"; then
      case "${_ENGINE_EXHAUSTED_REASON["$engine"]}" in
        missing-binary) any_missing=1 ;;
        *)              any_rate_limited=1 ;;
      esac
      echo "  [engine] $engine already exhausted this run — skipping (not re-invoked)" >&2
      continue
    fi

    # Headroom 2 = constrained (Gemini limits unknown / ledger unreadable, #2030): it
    # is already logged as a warning and the engine still runs — refusing to degrade
    # onto a constrained Gemini is the actuation follow-up (#2029), not this gate.
    local _headroom_rc=0
    check_provider_headroom "$engine" || _headroom_rc=$?
    if [ "$_headroom_rc" -ne 0 ] && [ "$_headroom_rc" -ne 2 ]; then
      echo "::warning::$engine at/above usage threshold — trying next engine" >&2
      any_rate_limited=1
      _mark_engine_exhausted "$engine" "rate-limited"
      continue
    fi

    local saved="$REVIEW_ENGINE"
    export REVIEW_ENGINE="$engine"
    # Re-evaluate model names for the new engine so model_for_intent returns
    # the correct engine-specific model for the requested tier.
    set_engine_config
    local model tier
    model="$(model_for_intent "$intent")"
    tier="$(tier_for_intent "$intent")"
    local rc=0 _t_start _t_end
    _t_start=$(date +%s)
    run_writer "$prompt_file" "$model" "$tier" || rc=$?
    _t_end=$(date +%s)
    export REVIEW_ENGINE="$saved"
    # Restore original config for subsequent PRs in the same session
    set_engine_config
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -eq 2 ] || [ "$rc" -eq 127 ]; then
      # exit 2: rate-limited or text-only engine unavailable for writes
      # exit 127: engine binary not installed in this environment (also returned by
      #           GNU timeout when the command is not found — treated as a missing
      #           binary rather than a retryable quota error so that infra failures
      #           surface loudly instead of being masked as rate-limit retries).
      echo "::warning::$engine unavailable (exit $rc), trying next engine" >&2
      if [ "$rc" -eq 2 ]; then
        any_rate_limited=1
        _mark_engine_exhausted "$engine" "rate-limited"
      else
        any_missing=1
        _mark_engine_exhausted "$engine" "missing-binary"
      fi
      continue
    fi
    # A non-fallback engine error (137/143=signal, generic non-zero) — propagate
    # immediately, classifying it as engine-error.
    #
    # A per-tier stage timeout (exit 124 from GNU `timeout`) is treated
    # separately (#1018): it is a first-class, NON-retryable condition, so a
    # same-budget retry — on this engine or a fallback engine — is deliberately
    # avoided (we already `return` here rather than `continue`). Classify it as a
    # distinct `timeout` reason and record the tier/budget/elapsed sidecars the
    # escalation comment surfaces, so the caller escalates to a human on the
    # FIRST occurrence instead of burning a same-budget model call.
    if [ "$rc" -eq 124 ]; then
      printf 'timeout\n' > /tmp/dev-lead-failure-reason
      printf 'action\n' > /tmp/dev-lead-timeout-tier
      printf '%s\n' "${ACTION_TIMEOUT_SEC}" > /tmp/dev-lead-timeout-budget
      printf '%s\n' "$(( _t_end - _t_start ))" > /tmp/dev-lead-timeout-elapsed
    else
      printf 'engine-error\n' > /tmp/dev-lead-failure-reason
    fi
    return "$rc"
  done

  echo "::error::All engines rate-limited or unavailable" >&2
  # If any engine binary was missing (exit 127), return 1 (hard infra failure) so
  # downstream handlers do not post rate-limit retry markers for what is really a
  # configuration/environment problem.  Only return 2 when every failure was a
  # genuine quota/rate-limit so callers know a later retry may succeed.
  if [ "$any_missing" -eq 1 ]; then
    printf 'missing-binary\n' > /tmp/dev-lead-failure-reason
    return 1
  fi
  # A genuine quota/rate-limit anywhere in the chain wins over a config-gap: a
  # later retry could succeed once the limit resets, so keep the retryable
  # rate-limited classification (exit 2).
  if [ "$any_rate_limited" -eq 1 ]; then
    printf 'rate-limited\n' > /tmp/dev-lead-failure-reason
    return 2
  fi
  # Deterministic credential config-gap as the SOLE cause (#1591): a distinct
  # non-retryable `unconfigured` reason (exit 1). Downstream handlers escalate to
  # a human rather than posting a retryable marker — retrying cannot set a secret.
  if [ "$any_unconfigured" -eq 1 ]; then
    printf 'unconfigured\n' > /tmp/dev-lead-failure-reason
    return 1
  fi
  printf 'engine-error\n' > /tmp/dev-lead-failure-reason
  return 1
}

# extract_verdict_json <raw_file> <dest_file>
# Resolves the verdict JSON from an agentic run, handling two output styles:
#   1. Agent wrote JSON to $dest via Bash tool (dest already valid — use it as-is).
#   2. Agent printed JSON to stdout captured in raw_file (scan for first valid
#      JSON object containing a 'decision' field, ignoring preamble text).
extract_verdict_json() {
  local raw="$1" dest="$2"
  # Style 1: agent wrote to $dest via Bash tool (our stdout redirect didn't clobber it).
  if jq empty "$dest" 2>/dev/null; then
    return 0
  fi
  # Style 2: agent printed JSON to stdout.
  if jq empty "$raw" 2>/dev/null; then
    cp "$raw" "$dest"
    return 0
  fi
  python3 -c "
import sys, json
text = open(sys.argv[1]).read()
decoder = json.JSONDecoder()
pos = text.find('{')
while pos >= 0:
    try:
        obj, _ = decoder.raw_decode(text, pos)
        if isinstance(obj, dict) and 'decision' in obj:
            print(json.dumps(obj))
            sys.exit(0)
    except Exception:
        pass
    pos = text.find('{', pos + 1)
sys.exit(1)
" "$raw" > "$dest" 2>/dev/null
}

# duck_verdict_valid <file> — 0 when <file> holds a rubber-duck verdict: JSON
# whose .decision is one prompts/rubber-duck.md allows (approve or escalate,
# any case). Valid JSON without one (e.g. {} or an error object) is not a
# verdict, so the duck chain moves on instead of synthesizing null values.
duck_verdict_valid() {
  [ -s "${1:-}" ] || return 1
  jq -e '(.decision | type == "string") and
         ((.decision | ascii_downcase) as $d | ["approve", "escalate"] | index($d) != null)' \
    "$1" >/dev/null 2>&1
}

# run_duck_chain <prompt_file> [candidates]
# Runs the rubber duck on each "<engine> <model>" line of <candidates>
# (default: duck_engine_candidates) until one writes a valid verdict to
# $OUTPUT_FILE (duck_verdict_valid). An engine that ends without a verdict
# (throttled on every model and key, an auth or policy failure, no JSON, or
# JSON without a decision) hands over to the next,
# the way a throttled Gemini key hands over to the next key. A timeout (exit
# 124 or 137) stops the chain, so a slow duck cannot add a second timeout to
# the review. Each attempt runs in a subshell, because run_duck drops the other
# engines' credentials and the next candidate needs its own. No fallback starts
# once DUCK_TIMEOUT_SEC has passed since the first attempt began, so the whole
# chain stays under two duck timeouts. Writes
# "<engine> <model>" of the verdict's engine to ${OUTPUT_FILE}.engine, and
# returns 0 when a verdict was written, otherwise the last attempt's exit code
# (1 when there was nothing to try).
run_duck_chain() {
  local prompt_file="$1" candidates e m rc=1 n=0 total tried="" out_tmp err_tmp
  local _started="$SECONDS"
  if [ "$#" -ge 2 ]; then
    candidates="$2"
  else
    candidates="$(duck_engine_candidates)"
  fi
  rm -f "${OUTPUT_FILE}.engine"
  total="$(printf '%s\n' "$candidates" | grep -c '[^[:space:]]' || true)"
  while read -r e m; do
    [ -n "$e" ] && [ "$e" != none ] || continue
    n=$((n + 1))
    if [ -n "$tried" ]; then
      if [ $((SECONDS - _started)) -ge "${DUCK_TIMEOUT_SEC:-300}" ]; then
        echo "::notice::[duck] not trying $e ($m): the duck's ${DUCK_TIMEOUT_SEC:-300}s budget is spent" >&2
        break
      fi
      echo "::notice::[duck] trying $e ($m), duck engine $n of $total" >&2
    fi
    tried="${tried:+$tried, }$e"
    rm -f "$OUTPUT_FILE"
    out_tmp="$(mktemp)"
    err_tmp="$(mktemp)"
    rc=0
    ( DUCK_ENGINE="$e"; DUCK_MODEL="$m"; run_duck "$prompt_file" "$m" ) \
      < /dev/null > "$out_tmp" 2> "$err_tmp" || rc=$?
    cat "$out_tmp"
    cat "$err_tmp" >&2
    if duck_verdict_valid "$OUTPUT_FILE"; then
      rm -f "$out_tmp" "$err_tmp"
      printf '%s %s\n' "$e" "$m" > "${OUTPUT_FILE}.engine"
      return 0
    fi
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
      rm -f "$out_tmp" "$err_tmp"
      echo "::warning::[duck] $e ($m) timed out — not trying another duck engine" >&2
      return "$rc"
    fi
    # Phrasing avoids _rate_limit_pattern tokens, as in the chain walkers.
    if is_rate_limited_files "$out_tmp" "$err_tmp"; then
      echo "::warning::[duck] $e ($m) throttled (exit $rc) and wrote no verdict" >&2
    else
      echo "::warning::[duck] $e ($m) wrote no verdict (exit $rc)" >&2
    fi
    rm -f "$out_tmp" "$err_tmp"
    [ "$rc" -ne 0 ] || rc=1
  done <<< "$candidates"
  if [ -n "$tried" ]; then
    echo "::notice::[duck] no duck engine produced a verdict (tried: $tried) — continuing with the deep review only" >&2
  fi
  return "$rc"
}

# run_duck <prompt_file> <model>
# Cross-engine adversarial "rubber duck" review on DUCK_ENGINE (one engine;
# run_duck_chain walks the fallbacks). The engine.sh init default is
# claude→copilot, gemini→claude, copilot→gemini, and all three branches are
# reachable. Output to stdout. Strips non-selected engine credentials to
# prevent cross-engine leakage.
run_duck() {
  local prompt_file="$1"
  local model="$2"
  local _tok_tmp="" rc=0
  local _t_start _t_end _dur=""
  if [ -n "${TOKEN_LOG_FILE:-}" ]; then
    unset _ENGINE_USAGE_OUT
    _tok_tmp="$(mktemp 2>/dev/null || true)"
    # Per-call usage-sidecar key: a unique mktemp path, exported so the engine's
    # pipeline subshell and _record_engine_tokens agree on it. Unique per call →
    # concurrent run_agentic/run_duck (review-one-pr.sh) never collide.
    [[ -n "$_tok_tmp" ]] && local -x _ENGINE_USAGE_OUT="${_tok_tmp}.usage"
  fi
  _t_start="$(_now_ms)"
  case "$DUCK_ENGINE" in
    claude)
      unset COPILOT_GITHUB_TOKEN 2>/dev/null || true
      # Every Gemini key, rotation keys included: the duck has shell tools.
      unset GOOGLE_API_KEY GOOGLE_API_KEY_2 GOOGLE_API_KEY_3 GOOGLE_API_KEY_4 2>/dev/null || true
      unset GEMINI_API_KEY 2>/dev/null || true
      # Thread the opt-in MCP config (no-op when REVIEW_MCP_CONFIG is unset).
      _mcp_review_flags "Bash,Read,Grep,Glob"
      # Route through the chain helper so real token usage (incl. cache) is captured
      # when logging is on; a single-model "chain" preserves prior behaviour.
      if [ -n "$_tok_tmp" ]; then
        _claude_chain_invoke "$model" "$prompt_file" "$DUCK_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "$_MCP_ALLOWED_TOOLS" \
          --max-turns 25 \
          ${_MCP_FLAGS[@]+"${_MCP_FLAGS[@]}"} \
          | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
      else
        _claude_chain_invoke "$model" "$prompt_file" "$DUCK_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "$_MCP_ALLOWED_TOOLS" \
          --max-turns 25 \
          ${_MCP_FLAGS[@]+"${_MCP_FLAGS[@]}"} \
          || rc=$?
      fi
      ;;
    gemini)
      unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
      unset ANTHROPIC_API_KEY 2>/dev/null || true
      unset COPILOT_GITHUB_TOKEN 2>/dev/null || true
      # A single-model chain, so the duck gets the same per-key rotation (and
      # probe-depleted keys last) as the other Gemini tiers.
      if [ -n "$_tok_tmp" ]; then
        _gemini_chain_invoke "$model" "$prompt_file" "$DUCK_TIMEOUT_SEC" \
          --approval-mode auto_edit | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
      else
        _gemini_chain_invoke "$model" "$prompt_file" "$DUCK_TIMEOUT_SEC" \
          --approval-mode auto_edit || rc=$?
      fi
      ;;
    copilot)
      unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
      unset ANTHROPIC_API_KEY 2>/dev/null || true
      # Every Gemini key, rotation keys included: the duck has shell tools.
      unset GOOGLE_API_KEY GOOGLE_API_KEY_2 GOOGLE_API_KEY_3 GOOGLE_API_KEY_4 2>/dev/null || true
      unset GEMINI_API_KEY 2>/dev/null || true
      # An explicit AI_DUCK_MODEL for a Copilot duck (AI_DUCK_ENGINE lists
      # copilot first; see _duck_model_for) is the model for this call;
      # otherwise <model> is only a label and the duck key decides
      # (ai_models_copilot_model duck).
      local _copilot_duck_model _copilot_duck_wanted
      _copilot_duck_wanted="$(_ai_duck_first)"
      if [ "$_copilot_duck_wanted" = copilot ] && [ -n "${AI_DUCK_MODEL:-}" ] && [ "$model" = "$AI_DUCK_MODEL" ]; then
        _copilot_duck_model="$model"
      else
        _copilot_duck_model="$(ai_models_copilot_model duck)"
      fi
      local -x COPILOT_API_MODEL="$_copilot_duck_model"
      # Do NOT tee stdout to OUTPUT_FILE — same rationale as run_agentic copilot
      # branch: the prompt writes verdict JSON directly via the Bash tool.
      if [ -n "$_tok_tmp" ]; then
        copilot_chat "$prompt_file" "$DUCK_TIMEOUT_SEC" --yolo | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
      else
        copilot_chat "$prompt_file" "$DUCK_TIMEOUT_SEC" --yolo || rc=$?
      fi
      ;;
    *)
      echo "::error::Unknown DUCK_ENGINE='$DUCK_ENGINE'" >&2
      [ -n "$_tok_tmp" ] && rm -f "$_tok_tmp"
      return 1
      ;;
  esac
  _t_end="$(_now_ms)"
  _dur="$(_elapsed_ms "$_t_start" "$_t_end")"
  if [ "$rc" -eq 0 ]; then
    _record_engine_tokens "duck" "$DUCK_ENGINE" "$model" "$prompt_file" "$_tok_tmp" "$_dur"
  fi
  [ -n "$_tok_tmp" ] && rm -f "$_tok_tmp"
  return "$rc"
}

# _emit_reset_iso <hhmm_with_meridiem>
# Shared helper: converts e.g. "11:20pm" into an ISO-8601 UTC timestamp
# (writing to /tmp/dev-lead-rate-limit-reset), advancing to tomorrow if the
# computed time is already in the past for today.
_emit_reset_iso() {
  local hhmm="$1"
  if [ -z "$hhmm" ]; then
    printf '' > /tmp/dev-lead-rate-limit-reset
    return 0
  fi
  local today iso
  today=$(date -u +%Y-%m-%d)
  iso=$(date -u -d "${today} ${hhmm} UTC" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  if [ -n "$iso" ] && [ "$(date -u +%s)" -gt "$(date -u -d "$iso" +%s 2>/dev/null || echo 0)" ]; then
    local tomorrow
    tomorrow=$(date -u -d "tomorrow" +%Y-%m-%d)
    iso=$(date -u -d "${tomorrow} ${hhmm} UTC" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  fi
  printf '%s' "${iso:-}" > /tmp/dev-lead-rate-limit-reset
}

# RATE_LIMIT_SAMPLE_MAX_BYTES — cap on one recorded unparsed rate-limit sample.
RATE_LIMIT_SAMPLE_MAX_BYTES="${RATE_LIMIT_SAMPLE_MAX_BYTES:-500}"

# _record_unparsed_rate_limit  (stdin: the engine output that failed to parse)
# Called only when the reset parser found no reset time (#2140). Records one
# sample of the rate-limit line(s) to the token ledger via
# emit_rate_limit_sample_record so a future parser (e.g. the weekly cap, #1863)
# is built from a real message, not a guess. Redacts the whole stream with
# redact_secrets first (so multi-line secrets such as PEM blocks are masked before
# any line filtering), then keeps only the first 3 lines that match
# _rate_limit_pattern, then truncates to RATE_LIMIT_SAMPLE_MAX_BYTES (truncating first could cut a token below its
# redaction pattern's minimum length and leak the fragment), and fingerprints the
# shape with digits normalised so retries of the same message de-duplicate.
# Records nothing without a ledger or without redact_secrets. Never changes what
# the parser accepts or its sidecar; never fails the caller.
_record_unparsed_rate_limit() {
  if [ -z "${TOKEN_LOG_FILE:-}" ] \
    || ! declare -F emit_rate_limit_sample_record >/dev/null 2>&1 \
    || ! declare -F redact_secrets >/dev/null 2>&1; then
    return 0
  fi
  local sample shape
  sample=$(redact_secrets \
    | jq -Rr '. as $l | (try fromjson catch null)
      | if type == "object" and (.result | type) == "string" then .result else $l end' 2>/dev/null \
    | grep -iE "$(_rate_limit_pattern)" 2>/dev/null | head -n 3 \
    | head -c "$RATE_LIMIT_SAMPLE_MAX_BYTES" || true)
  [ -n "$sample" ] || return 0
  shape=$(printf '%s' "$sample" | sed -E 's/[0-9]+/N/g' | cksum)
  shape=${shape%% *}
  emit_rate_limit_sample_record "${REVIEW_ENGINE:-}" "$shape" "$sample" || true
}

# parse_reset_time <text>
# Extracts the rate-limit reset time from engine output and writes an ISO-8601
# UTC timestamp to /tmp/dev-lead-rate-limit-reset for callers to embed in
# status=rate-limited markers. Pattern: "resets H:MMam/pm (UTC)" or
# "resets H:MM(am|pm) UTC".
# Writes empty string if no reset time is found (caller treats as unknown).
#
# Prefer parse_reset_time_files for large captures — same OOM rationale as
# is_rate_limited / is_rate_limited_files above.
parse_reset_time() {
  local text="$1"
  # Match "resets 11:20pm (UTC)" or "resets 11:20pm UTC"
  local time_str
  time_str=$(printf '%s\n' "$text" | grep -oiE 'resets [0-9]{1,2}:[0-9]{2}(am|pm)' | head -1 || true)
  if [ -z "$time_str" ]; then
    printf '' > /tmp/dev-lead-rate-limit-reset
    printf '%s\n' "$text" | _record_unparsed_rate_limit || true
    return 0
  fi
  # Extract H:MM(am|pm) part
  local hhmm
  hhmm=$(printf '%s' "$time_str" | grep -oiE '[0-9]{1,2}:[0-9]{2}(am|pm)$' || true)
  _emit_reset_iso "$hhmm"
}

# parse_reset_time_files <file>...
# File-aware variant of parse_reset_time. Scans each non-empty existing file
# for the first "resets H:MMam/pm" match and writes the ISO timestamp via
# _emit_reset_iso. Uses grep directly on files to avoid loading large LLM
# outputs into a shell variable.
parse_reset_time_files() {
  local files=()
  local f
  for f in "$@"; do
    [ -n "$f" ] && [ -f "$f" ] && files+=("$f")
  done
  if [ "${#files[@]}" -eq 0 ]; then
    printf '' > /tmp/dev-lead-rate-limit-reset
    return 0
  fi
  local time_str
  time_str=$(grep -hoiE 'resets [0-9]{1,2}:[0-9]{2}(am|pm)' "${files[@]}" 2>/dev/null | head -1 || true)
  if [ -z "$time_str" ]; then
    printf '' > /tmp/dev-lead-rate-limit-reset
    cat "${files[@]}" 2>/dev/null | _record_unparsed_rate_limit || true
    return 0
  fi
  local hhmm
  hhmm=$(printf '%s' "$time_str" | grep -oiE '[0-9]{1,2}:[0-9]{2}(am|pm)$' || true)
  _emit_reset_iso "$hhmm"
}
