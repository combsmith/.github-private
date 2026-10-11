#!/usr/bin/env bats
# AI_MODELS_CLAUDE / AI_MODELS_GEMINI / AI_MODELS_COPILOT: each provider's model
# list as one Actions variable (scripts/lib/engine-models.sh), wired through
# engine.sh's set_engine_config.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/engine-models.sh"

setup() {
  unset AI_MODELS_CLAUDE AI_MODELS_GEMINI AI_MODELS_COPILOT AI_MODELS_PROBLEM_REPORTED
  unset CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN CLAUDE_AUDIT_MODEL_CHAIN
  unset CLAUDE_ACTION_MODEL_CHAIN CLAUDE_SINGLE_MODEL_CHAIN
  unset GEMINI_FLASH_MODEL GEMINI_PRO_MODEL GEMINI_FLASH_MODEL_CHAIN GEMINI_PRO_MODEL_CHAIN
  unset COPILOT_API_MODEL COPILOT_API_MODEL_DEFAULTED AI_ENGINES AI_DUCK_ENGINE AI_DUCK_MODEL GEMINI_AVAILABLE
  # shellcheck source=../../../scripts/lib/engine-models.sh
  source "$LIB"
}

# Sources engine.sh for <engine> in a subshell and prints the requested vars.
_engine() {
  local engine="$1"; shift
  local vars="" v
  for v in "$@"; do vars="$vars $v=\${$v:-}"; done
  bash -c "export REVIEW_ENGINE=$engine; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1; echo \"$vars\""
}

# ── Parsing ───────────────────────────────────────────────────────────────────

@test "parse: unset → defaults (Claude deep chain, Gemini deep is 3.1-pro-preview)" {
  [ "$(ai_models_chain claude deep)" = "claude-opus-5-5,claude-opus-4-8,claude-sonnet-5-5" ]
  [ "$(ai_models_chain gemini triage)" = "gemini-3.8-flash,gemini-3.1-pro-preview" ]
  [ "$(ai_models_chain gemini action)" = "gemini-3.8-flash,gemini-3.1-pro-preview" ]
  [ "$(ai_models_chain gemini deep)" = "gemini-3.1-pro-preview,gemini-3.8-flash" ]
  [ "$(ai_models_chain gemini audit)" = "gemini-3.1-pro-preview,gemini-3.8-flash" ]
  [ "$(ai_models_chain gemini single)" = "gemini-3.1-pro-preview,gemini-3.8-flash" ]
  [ "$(ai_models_chain copilot deep)" = "openai/o4-mini" ]
  [ -z "$(ai_models_problems)" ]
}

@test "keys: every provider takes triage, deep, audit, action, single and duck" {
  local p
  for p in claude gemini copilot; do
    [ "$(_ai_models_keys "$p")" = "triage deep audit action single duck" ]
  done
  export AI_MODELS_GEMINI="flash=gemini-f1; pro=gemini-p1" AI_MODELS_COPILOT="model=openai/gpt-5-mini"
  [ "$(ai_models_chain gemini triage)" = "gemini-3.8-flash,gemini-3.1-pro-preview" ]
  [ "$(ai_models_chain copilot triage)" = "openai/o4-mini" ]
  run ai_models_problems
  [[ "$output" == *"AI_MODELS_GEMINI: unknown key 'flash'"* ]]
  [[ "$output" == *"AI_MODELS_GEMINI: unknown key 'pro'"* ]]
  [[ "$output" == *"AI_MODELS_COPILOT: unknown key 'model'"* ]]
}

@test "parse: '; ' and newlines separate entries; keys are case-insensitive; spaces ignored" {
  export AI_MODELS_CLAUDE=$'DEEP = claude-opus-4-8 , claude-sonnet-5\ntriage=claude-sonnet-5;  audit=claude-fable-5'
  [ "$(ai_models_chain claude deep)" = "claude-opus-4-8,claude-sonnet-5" ]
  [ "$(ai_models_chain claude triage)" = "claude-sonnet-5" ]
  [ "$(ai_models_chain claude audit)" = "claude-fable-5" ]
  # an omitted key keeps its default
  [ "$(ai_models_chain claude action)" = "claude-sonnet-5-5,claude-sonnet-5,claude-opus-5-5" ]
}

@test "parse: duplicate models collapse; the last entry for a key wins" {
  export AI_MODELS_GEMINI="deep=gemini-a,gemini-a,gemini-b; deep=gemini-c"
  [ "$(ai_models_chain gemini deep)" = "gemini-c" ]
  export AI_MODELS_GEMINI="deep=gemini-a,gemini-a,gemini-b"
  [ "$(ai_models_chain gemini deep)" = "gemini-a,gemini-b" ]
}

@test "problems: unknown key, missing '=', invalid id and empty list are reported and ignored" {
  export AI_MODELS_CLAUDE="deeep=claude-opus-4-8; claude-sonnet-5; deep=claude opus; triage=,"
  [ "$(ai_models_chain claude deep)" = "claude-opus-5-5,claude-opus-4-8,claude-sonnet-5-5" ]
  [ "$(ai_models_chain claude triage)" = "claude-haiku-4-5-20251001,claude-sonnet-5-5,claude-sonnet-5" ]
  run ai_models_problems
  [[ "$output" == *"unknown key 'deeep'"* ]]
  [[ "$output" == *"'claude-sonnet-5' is not <key>=<models>"* ]]
  [[ "$output" == *"'triage' lists no model"* ]]
  [[ "$output" == *"invalid model id 'claude opus'"* ]]
}

@test "parse: an unusable last entry for a key drops an earlier one (the default applies)" {
  export AI_MODELS_CLAUDE="deep=claude-sonnet-5; deep=not valid"
  [ "$(ai_models_chain claude deep)" = "claude-opus-5-5,claude-opus-4-8,claude-sonnet-5-5" ]
  export AI_MODELS_CLAUDE="deep=claude-sonnet-5; deep=,"
  [ "$(ai_models_chain claude deep)" = "claude-opus-5-5,claude-opus-4-8,claude-sonnet-5-5" ]
}

@test "problems: an invalid model id drops the whole entry (no half-parsed chain)" {
  export AI_MODELS_GEMINI='deep=gemini-3.1-pro-preview,gem!ni'
  [ "$(ai_models_chain gemini deep)" = "gemini-3.1-pro-preview,gemini-3.8-flash" ]
  [[ "$(ai_models_problems)" == *"invalid model id 'gem!ni'"* ]]
}

@test "labels: short names for log lines" {
  [ "$(ai_model_label claude-haiku-4-5-20251001)" = "haiku 4.5" ]
  [ "$(ai_model_label claude-opus-5-5)" = "opus 5.5" ]
  [ "$(ai_model_label claude-sonnet-5)" = "sonnet 5" ]
  [ "$(ai_model_label claude-sonnet-5-5)" = "sonnet 5.5" ]
  [ "$(ai_model_label openai/o4-mini)" = "o4-mini" ]
  [ "$(ai_models_label_chain claude-opus-5-5,claude-opus-4-8,claude-sonnet-5)" = "opus 5.5 [opus 4.8, sonnet 5]" ]
}

# ── Claude via engine.sh ──────────────────────────────────────────────────────

@test "claude: defaults (chains, per-tier primaries) — audit/single on opus-5-5 (#1901), sonnet 5.5 default (#1978)" {
  run _engine claude CLAUDE_DEEP_MODEL_CHAIN CLAUDE_AUDIT_MODEL_CHAIN CLAUDE_SINGLE_MODEL_CHAIN ENGINE_TRIAGE_MODEL ENGINE_DEEP_MODEL ENGINE_AUDIT_MODEL ENGINE_ACTION_MODEL ENGINE_SINGLE_MODEL
  [[ "$output" == *"CLAUDE_DEEP_MODEL_CHAIN=claude-opus-5-5,claude-opus-4-8,claude-sonnet-5-5"* ]]
  [[ "$output" == *"CLAUDE_AUDIT_MODEL_CHAIN=claude-opus-5-5,claude-opus-4-8,claude-opus-4-7"* ]]
  [[ "$output" == *"CLAUDE_SINGLE_MODEL_CHAIN=claude-opus-5-5,claude-opus-4-8,claude-opus-4-7"* ]]
  [[ "$output" == *"ENGINE_TRIAGE_MODEL=claude-haiku-4-5-20251001"* ]]
  [[ "$output" == *"ENGINE_DEEP_MODEL=claude-opus-5-5"* ]]
  [[ "$output" == *"ENGINE_AUDIT_MODEL=claude-opus-5-5"* ]]
  [[ "$output" == *"ENGINE_ACTION_MODEL=claude-sonnet-5-5"* ]]
  [[ "$output" == *"ENGINE_SINGLE_MODEL=claude-opus-5-5"* ]]
  [[ "$output" != *"claude-fable-5"* ]]
}

@test "claude: default log label reads 'audit: opus 5.5 [opus 4.8, opus 4.7]' (#1901)" {
  run _engine claude ENGINE_LABEL ENGINE_SINGLE_LABEL
  [[ "$output" == *"audit: opus 5.5 [opus 4.8, opus 4.7]"* ]]
  [[ "$output" == *"single-reviewer mode: opus 5.5 [opus 4.8, opus 4.7]"* ]]
}

@test "claude: AI_MODELS_CLAUDE sets the tier chain, its primary and the log label" {
  export AI_MODELS_CLAUDE="deep=claude-opus-4-8,claude-sonnet-5"
  run _engine claude CLAUDE_DEEP_MODEL_CHAIN ENGINE_DEEP_MODEL ENGINE_LABEL
  [[ "$output" == *"CLAUDE_DEEP_MODEL_CHAIN=claude-opus-4-8,claude-sonnet-5"* ]]
  [[ "$output" == *"ENGINE_DEEP_MODEL=claude-opus-4-8"* ]]
  [[ "$output" == *"deep: opus 4.8 [sonnet 5]"* ]]
}

@test "claude: a per-tier CLAUDE_<TIER>_MODEL_CHAIN still wins over AI_MODELS_CLAUDE" {
  export AI_MODELS_CLAUDE="deep=claude-opus-4-8" CLAUDE_DEEP_MODEL_CHAIN="claude-sonnet-5"
  run _engine claude ENGINE_DEEP_MODEL
  [[ "$output" == *"ENGINE_DEEP_MODEL=claude-sonnet-5"* ]]
}

# ── Gemini via engine.sh ──────────────────────────────────────────────────────

@test "gemini: AI_MODELS_GEMINI sets each tier's chain on its own" {
  export AI_MODELS_GEMINI="triage=gemini-t1,gemini-t2; action=gemini-a1; deep=gemini-d1; audit=gemini-u1; single=gemini-s1"
  run _engine gemini ENGINE_TRIAGE_MODEL ENGINE_ACTION_MODEL ENGINE_DEEP_MODEL ENGINE_AUDIT_MODEL ENGINE_SINGLE_MODEL ENGINE_LABEL
  [[ "$output" == *"ENGINE_TRIAGE_MODEL=gemini-t1 "* ]]
  [[ "$output" == *"ENGINE_ACTION_MODEL=gemini-a1 "* ]]
  [[ "$output" == *"ENGINE_DEEP_MODEL=gemini-d1 "* ]]
  [[ "$output" == *"ENGINE_AUDIT_MODEL=gemini-u1 "* ]]
  [[ "$output" == *"ENGINE_SINGLE_MODEL=gemini-s1 "* ]]
  [[ "$output" == *"triage: gemini-t1 [gemini-t2]"* ]]
  [ "$(ai_models_gemini_chain triage)" = "gemini-t1,gemini-t2" ]
  [ "$(ai_models_gemini_chain audit)" = "gemini-u1" ]
}

@test "gemini: each call uses its own tier's chain (writer → action, audit → audit)" {
  local p; p="$BATS_TEST_TMPDIR/prompt"; echo "prompt" > "$p"
  export AI_MODELS_GEMINI="triage=gemini-t1; action=gemini-a1; deep=gemini-d1; audit=gemini-u1"
  run bash -c "export REVIEW_ENGINE=gemini; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1
    _gemini_chain_invoke() { echo \"chain=\$1\"; }
    run_writer '$p' 2>/dev/null | grep '^chain='
    run_agentic '$p' \"\$ENGINE_AUDIT_MODEL\" audit 2>/dev/null | grep '^chain='"
  [[ "$output" == *"chain=gemini-a1"* ]]
  [[ "$output" == *"chain=gemini-u1"* ]]
}

@test "gemini: GEMINI_FLASH_MODEL / GEMINI_PRO_MODEL replace only the first model of each tier in their group" {
  export AI_MODELS_GEMINI="deep=gemini-d1,gemini-d2; audit=gemini-u1,gemini-u2" GEMINI_PRO_MODEL="gemini-x"
  run _engine gemini ENGINE_DEEP_MODEL ENGINE_AUDIT_MODEL
  [[ "$output" == *"ENGINE_DEEP_MODEL=gemini-x "* ]]
  [[ "$output" == *"ENGINE_AUDIT_MODEL=gemini-x"* ]]
  [ "$(ai_models_gemini_chain deep)" = "gemini-x,gemini-d2" ]
  [ "$(ai_models_gemini_chain audit)" = "gemini-x,gemini-u2" ]
  [ "$(ai_models_gemini_chain triage)" = "gemini-3.8-flash,gemini-3.1-pro-preview" ]
}

@test "gemini: GEMINI_PRO_MODEL_CHAIN wins over both for deep, audit and single" {
  export AI_MODELS_GEMINI="deep=gemini-d1; single=gemini-s1" GEMINI_PRO_MODEL="gemini-x" GEMINI_PRO_MODEL_CHAIN="gemini-c1, gemini-c2"
  run _engine gemini ENGINE_DEEP_MODEL ENGINE_SINGLE_MODEL
  [[ "$output" == *"ENGINE_DEEP_MODEL=gemini-c1 "* ]]
  [[ "$output" == *"ENGINE_SINGLE_MODEL=gemini-c1"* ]]
  [ "$(ai_models_gemini_chain single)" = "gemini-c1,gemini-c2" ]
}

@test "gemini: the Claude duck model comes from AI_MODELS_CLAUDE duck=" {
  export AI_MODELS_CLAUDE="duck=claude-haiku-4-5-20251001"
  run _engine gemini DUCK_ENGINE DUCK_MODEL
  [[ "$output" == *"DUCK_ENGINE=claude"* ]]
  [[ "$output" == *"DUCK_MODEL=claude-haiku-4-5-20251001"* ]]
}

# ── Copilot via engine.sh ─────────────────────────────────────────────────────

@test "copilot: AI_MODELS_COPILOT sets each tier's model; a key left out keeps the default" {
  export AI_MODELS_COPILOT="triage=openai/gpt-5-mini; deep=openai/gpt-5"
  run _engine copilot COPILOT_API_MODEL ENGINE_TRIAGE_MODEL ENGINE_DEEP_MODEL ENGINE_ACTION_MODEL
  [[ "$output" == *"COPILOT_API_MODEL=openai/gpt-5-mini "* ]]
  [[ "$output" == *"ENGINE_TRIAGE_MODEL=gpt-5-mini "* ]]
  [[ "$output" == *"ENGINE_DEEP_MODEL=gpt-5 "* ]]
  [[ "$output" == *"ENGINE_ACTION_MODEL=o4-mini"* ]]
}

@test "copilot: ENGINE_*_MODEL keep the id (vendor prefix dropped), not the display label" {
  export AI_MODELS_COPILOT="deep=anthropic/claude-sonnet-5; duck=openai/gpt-5-mini"
  run _engine copilot ENGINE_DEEP_MODEL ENGINE_TRIAGE_MODEL ENGINE_LABEL
  [[ "$output" == *"ENGINE_DEEP_MODEL=claude-sonnet-5 "* ]]
  [[ "$output" == *"ENGINE_TRIAGE_MODEL=o4-mini "* ]]
  [[ "$output" == *"deep: sonnet 5 "* ]]
  run _engine claude DUCK_MODEL
  [[ "$output" == *"DUCK_MODEL=gpt-5-mini"* ]]
}

@test "copilot: each call sends its own tier's model (deep, action, duck)" {
  local p; p="$BATS_TEST_TMPDIR/prompt"; echo "prompt" > "$p"
  export AI_MODELS_COPILOT="triage=openai/t1; deep=openai/d1; action=openai/a1; duck=openai/k1"
  run bash -c "export REVIEW_ENGINE=copilot; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1
    copilot_chat() { echo \"model=\$COPILOT_API_MODEL\"; }
    run_agentic '$p' \"\$ENGINE_DEEP_MODEL\" deep 2>/dev/null | grep '^model='
    run_writer '$p' 2>/dev/null | grep '^model='
    DUCK_ENGINE=copilot run_duck '$p' k1 2>/dev/null | grep '^model='
    echo \"after=\$COPILOT_API_MODEL\""
  [[ "$output" == *"model=openai/d1"* ]]
  [[ "$output" == *"model=openai/a1"* ]]
  [[ "$output" == *"model=openai/k1"* ]]
  [[ "$output" == *"after=openai/t1"* ]]
}

@test "copilot: the writer uses the tier model_for_intent picked (fix-issue → deep)" {
  local p; p="$BATS_TEST_TMPDIR/prompt"; echo "prompt" > "$p"
  export AI_MODELS_COPILOT="triage=openai/t1; deep=openai/d1; action=openai/a1"
  run bash -c "export REVIEW_ENGINE=copilot; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1
    copilot_chat() { echo \"model=\$COPILOT_API_MODEL\"; }
    run_writer '$p' \"\$(model_for_intent fix-issue)\" 2>/dev/null | grep '^model='
    run_writer '$p' \"\$(model_for_intent fix-ci)\" 2>/dev/null | grep '^model='
    run_writer '$p' openai/pinned 2>/dev/null | grep '^model='"
  [ "${lines[0]}" = "model=openai/d1" ]
  [ "${lines[1]}" = "model=openai/a1" ]
  [ "${lines[2]}" = "model=openai/pinned" ]
}

@test "writer: fix-issue walks the deep tier's whole chain on Gemini and Claude" {
  local p; p="$BATS_TEST_TMPDIR/prompt"; echo "prompt" > "$p"
  export AI_MODELS_GEMINI="deep=gemini-d1,gemini-d2; action=gemini-a1"
  run bash -c "export REVIEW_ENGINE=gemini; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1
    _gemini_chain_invoke() { echo \"chain=\$1\"; }
    run_writer '$p' \"\$(model_for_intent fix-issue)\" 2>/dev/null | grep '^chain='
    run_writer '$p' gemini-pinned 2>/dev/null | grep '^chain='"
  [ "${lines[0]}" = "chain=gemini-d1,gemini-d2" ]
  [ "${lines[1]}" = "chain=gemini-pinned" ]
  export AI_MODELS_CLAUDE="deep=claude-opus-5-5,claude-opus-4-8; action=claude-sonnet-5"
  run bash -c "export REVIEW_ENGINE=claude; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1
    _claude_chain_invoke() { echo \"chain=\$1\"; }
    run_writer '$p' \"\$(model_for_intent fix-issue)\" 2>/dev/null | grep '^chain='
    run_writer '$p' \"\$(model_for_intent fix-ci)\" 2>/dev/null | grep '^chain='"
  [ "${lines[0]}" = "chain=claude-opus-5-5,claude-opus-4-8" ]
  [ "${lines[1]}" = "chain=claude-sonnet-5" ]
}

@test "writer: tiers sharing a primary keep their own chains (the tier is passed, not inferred)" {
  local p; p="$BATS_TEST_TMPDIR/prompt"; echo "prompt" > "$p"
  export AI_MODELS_GEMINI="deep=gemini-same,gemini-deep-fb; action=gemini-same,gemini-action-fb"
  run bash -c "export REVIEW_ENGINE=gemini DEV_LEAD_ENGINES=gemini GOOGLE_API_KEY=k1; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1
    _gemini_chain_invoke() { echo \"chain=\$1\"; }
    run_writer_with_fallback '$p' fix-issue 2>/dev/null | grep '^chain='
    run_writer_with_fallback '$p' fix-ci 2>/dev/null | grep '^chain='"
  [ "${lines[0]}" = "chain=gemini-same,gemini-deep-fb" ]
  [ "${lines[1]}" = "chain=gemini-same,gemini-action-fb" ]
}

@test "copilot: an explicit COPILOT_API_MODEL still wins for every tier" {
  export AI_MODELS_COPILOT="triage=openai/gpt-5-mini; deep=openai/gpt-5" COPILOT_API_MODEL="openai/o4-mini"
  run _engine copilot COPILOT_API_MODEL ENGINE_DEEP_MODEL
  [[ "$output" == *"COPILOT_API_MODEL=openai/o4-mini "* ]]
  [[ "$output" == *"ENGINE_DEEP_MODEL=o4-mini"* ]]
}

@test "copilot: a child shell that re-sources engine.sh keeps the per-tier models" {
  export AI_MODELS_COPILOT="triage=openai/t1; deep=openai/d1"
  run bash -c "export REVIEW_ENGINE=copilot; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1
    bash -c \"source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1; echo deep=\\\$ENGINE_DEEP_MODEL api=\\\$COPILOT_API_MODEL\""
  [[ "$output" == *"deep=d1 api=openai/t1"* ]]
}

@test "claude: the Copilot duck model comes from AI_MODELS_COPILOT duck=, else triage" {
  export AI_MODELS_COPILOT="triage=openai/t1"
  run _engine claude DUCK_ENGINE DUCK_MODEL
  [[ "$output" == *"DUCK_ENGINE=copilot "* ]]
  [[ "$output" == *"DUCK_MODEL=t1"* ]]
  export AI_MODELS_COPILOT="triage=openai/t1; duck=openai/k1"
  run _engine claude DUCK_MODEL
  [[ "$output" == *"DUCK_MODEL=k1"* ]]
}

@test "copilot: the Gemini duck model comes from AI_MODELS_GEMINI duck=, else triage" {
  run _engine copilot DUCK_MODEL
  [[ "$output" == *"DUCK_MODEL=gemini-3.8-flash"* ]]
  export AI_MODELS_GEMINI="triage=gemini-t1"
  run _engine copilot DUCK_MODEL
  [[ "$output" == *"DUCK_MODEL=gemini-t1"* ]]
  export AI_MODELS_GEMINI="triage=gemini-t1; duck=gemini-d1"
  run _engine copilot DUCK_MODEL
  [[ "$output" == *"DUCK_MODEL=gemini-d1"* ]]
}

@test "copilot: the Gemini duck model follows GEMINI_FLASH_MODEL_CHAIN, then GEMINI_FLASH_MODEL" {
  export GEMINI_FLASH_MODEL_CHAIN="gemini-c1,gemini-c2" GEMINI_FLASH_MODEL="gemini-x"
  run _engine copilot DUCK_MODEL
  [[ "$output" == *"DUCK_MODEL=gemini-c1"* ]]
  unset GEMINI_FLASH_MODEL_CHAIN
  run _engine copilot DUCK_MODEL
  [[ "$output" == *"DUCK_MODEL=gemini-x"* ]]
}

@test "problems: a duck key, or any Copilot key, given several models warns and keeps the first" {
  export AI_MODELS_COPILOT="deep=openai/gpt-5-mini,openai/o4-mini" AI_MODELS_CLAUDE="duck=claude-sonnet-5,claude-opus-4-8"
  [ "$(ai_models_chain copilot deep)" = "openai/gpt-5-mini" ]
  [ "$(ai_models_chain claude duck)" = "claude-sonnet-5" ]
  run ai_models_problems
  [[ "$output" == *"AI_MODELS_COPILOT: 'deep' takes one model — only 'openai/gpt-5-mini' is used"* ]]
  [[ "$output" == *"AI_MODELS_CLAUDE: 'duck' takes one model — only 'claude-sonnet-5' is used"* ]]
}

@test "copilot: the log label shows the duck's short name" {
  export GEMINI_AVAILABLE=true
  run _engine copilot ENGINE_LABEL
  [[ "$output" == *"duck: gemini-3.8-flash"* ]]
}

# The duck part of ENGINE_LABEL names what the duck actually tries, in order
# (duck_engine_candidates), not only set_engine_config's cross-engine default:
# a Claude primary with AI_DUCK_ENGINE=gemini,claude used to read "duck: o4-mini".
# A Gemini duck is listed only after the pre-flight probe passed
# (GEMINI_AVAILABLE=true), as review-one-pr.sh requires before it runs one.
@test "duck label: lists the AI_DUCK_ENGINE chain in order, fallbacks in brackets" {
  export AI_ENGINES="claude,gemini" AI_DUCK_ENGINE="gemini,claude" GEMINI_AVAILABLE=true
  export AI_MODELS_GEMINI="duck=gemini-duck-a" AI_MODELS_CLAUDE="duck=claude-sonnet-5"
  run _engine claude ENGINE_LABEL
  [[ "$output" == *"+ duck: gemini-duck-a [sonnet 5] → audit:"* ]]
  [[ "$output" != *"o4-mini"* ]]
}

@test "duck label: AI_DUCK_MODEL shows on the first listed engine only" {
  export AI_ENGINES="claude,gemini" AI_DUCK_ENGINE="gemini,claude" AI_DUCK_MODEL="gemini-duck-b" GEMINI_AVAILABLE=true
  export AI_MODELS_CLAUDE="duck=claude-sonnet-5"
  run _engine claude ENGINE_LABEL
  [[ "$output" == *"+ duck: gemini-duck-b [sonnet 5] → audit:"* ]]
}

@test "duck label: leaves out a Gemini duck unless the pre-flight probe passed" {
  export AI_ENGINES="claude,gemini" AI_DUCK_ENGINE="gemini,claude"
  export AI_MODELS_GEMINI="duck=gemini-duck-a" AI_MODELS_CLAUDE="duck=claude-sonnet-5"
  local flag
  for flag in false unset; do
    if [ "$flag" = unset ]; then unset GEMINI_AVAILABLE; else export GEMINI_AVAILABLE="$flag"; fi
    run _engine claude ENGINE_LABEL
    [[ "$output" == *"+ duck: sonnet 5 → audit:"* ]]
    [[ "$output" != *"gemini-duck-a"* ]]
  done
}

@test "duck label: AI_DUCK_ENGINE=none reads 'duck: off'" {
  export AI_DUCK_ENGINE="none"
  run _engine claude ENGINE_LABEL
  [[ "$output" == *"+ duck: off → audit:"* ]]
}

@test "duck label: matches the duck_engine_candidates order" {
  export AI_ENGINES="claude,gemini,copilot" AI_DUCK_ENGINE="gemini" GEMINI_AVAILABLE=true
  export AI_MODELS_GEMINI="duck=gemini-duck-a" AI_MODELS_COPILOT="duck=openai/gpt-duck"
  run bash -c "export REVIEW_ENGINE=claude; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1; duck_engine_candidates 2>/dev/null | awk '{print \$2}' | paste -sd, -; echo \"\$ENGINE_LABEL\""
  [ "${lines[0]}" = "gemini-duck-a,gpt-duck" ]
  [[ "${lines[1]}" == *"+ duck: gemini-duck-a [gpt-duck] → audit:"* ]]
}

@test "persona parity: the live persona runner and run-eval's persona tier resolve the same deep model" {
  local wf="$SCRIPT_DIR/.github/workflows/persona-runner-reusable.yml"
  grep -q 'source scripts/lib/engine-models.sh' "$wf"
  grep -q 'persona_chain="$(ai_models_chain claude deep)"' "$wf"
  grep -q -- 'persona_model_args=(--model "$persona_model")' "$wf"
  grep -q -- '[ -z "$persona_fallback" ] || persona_model_args+=(--fallback-model "$persona_fallback")' "$wf"
  grep -q -- '"${persona_model_args\[@\]}"' "$wf"
  grep -q 'ai_models_problems' "$wf"
  ! grep -q -- '--model claude-' "$wf"
  ! grep -q -- '--fallback-model opus' "$wf"
  export AI_MODELS_CLAUDE="deep=claude-opus-4-8,claude-sonnet-5"
  local live
  live="$(ai_models_chain claude deep)"; live="${live%%,*}"
  run _engine claude ENGINE_DEEP_MODEL
  [[ "$output" == *"ENGINE_DEEP_MODEL=$live"* ]]
}

# ── Gemini billing probe (validate-engines.sh) ───────────────────────────────

# Puts a curl stub on PATH that records its URL and answers with <body> / <code>.
_probe_curl() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/body"
  printf '%s\n' "$2" > "$BATS_TEST_TMPDIR/code"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do case "$a" in https://*) echo "$a" >> "$BATS_TEST_TMPDIR/urls" ;; esac; done
cat "$BATS_TEST_TMPDIR/body" "$BATS_TEST_TMPDIR/code"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" BATS_TEST_TMPDIR
}

@test "probe: the Gemini billing probe calls the configured triage model" {
  _probe_curl '{"candidates":[]}' 200
  export AI_MODELS_GEMINI="triage=gemini-f1,gemini-f2"
  source "$SCRIPT_DIR/scripts/validate-engines.sh"
  _gemini_probe_key fake
  grep -q "/models/gemini-f1:generateContent" "$BATS_TEST_TMPDIR/urls"
  export GEMINI_FLASH_MODEL_CHAIN="gemini-c1"
  _gemini_probe_key fake
  grep -q "/models/gemini-c1:generateContent" "$BATS_TEST_TMPDIR/urls"
}

@test "probe: Google's models/ prefix is stripped; an unprobe-able id warns and skips" {
  _probe_curl '{"candidates":[]}' 200
  export AI_MODELS_GEMINI="triage=models/gemini-f1"
  source "$SCRIPT_DIR/scripts/validate-engines.sh"
  _gemini_probe_key fake
  grep -q "/models/gemini-f1:generateContent" "$BATS_TEST_TMPDIR/urls"
  rm -f "$BATS_TEST_TMPDIR/urls"
  export AI_MODELS_GEMINI="triage=vendor/gemini-x"
  run bash -c "source '$SCRIPT_DIR/scripts/validate-engines.sh'; _gemini_probe_key a; echo rc=\$?"
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"Gemini billing probe skipped"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/urls" ]
}

@test "headroom: the Claude probe uses the configured triage model and warns without headers" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/args"
printf 'HTTP/2 200\r\ncontent-type: application/json\r\n\r\n'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" BATS_TEST_TMPDIR
  export AI_MODELS_CLAUDE="triage=claude-sonnet-5" ANTHROPIC_API_KEY="fake"
  run bash -c "export REVIEW_ENGINE=claude; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1; check_provider_headroom claude; echo rc=\$?; check_provider_headroom claude"
  [[ "$output" == *"rc=0"* ]]
  grep -q '"model":"claude-sonnet-5"' "$BATS_TEST_TMPDIR/args"
  [ "$(grep -c "no rate-limit headers from claude-sonnet-5" <<< "$output")" = "1" ]
}

@test "probe: a not-found probe model warns once and stays fail-open" {
  _probe_curl '{"error":{"code":404,"message":"models/gemini-gone is not found","status":"NOT_FOUND"}}' 404
  export AI_MODELS_GEMINI="triage=gemini-gone"
  run bash -c "source '$SCRIPT_DIR/scripts/validate-engines.sh'; _gemini_probe_key a; echo rc=\$?; _gemini_probe_key b"
  [[ "$output" == *"rc=0"* ]]
  [ "$(grep -c "model 'gemini-gone' was not found" <<< "$output")" = "1" ]
}

# ── Warnings ──────────────────────────────────────────────────────────────────

@test "engine.sh: a bad AI_MODELS_* entry warns once per run" {
  run bash -c "export REVIEW_ENGINE=claude AI_MODELS_GEMINI='typo=x'; source '$SCRIPT_DIR/scripts/engine.sh' 2>&1 >/dev/null | grep -c \"AI_MODELS_GEMINI: unknown key 'typo'\""
  [ "$output" = "1" ]
  run bash -c "export REVIEW_ENGINE=claude AI_MODELS_GEMINI='typo=x' AI_MODELS_PROBLEM_REPORTED=1; source '$SCRIPT_DIR/scripts/engine.sh' 2>&1 >/dev/null | grep -c 'AI_MODELS_GEMINI'"
  [ "$output" = "0" ]
}

# ── Fable 5 deprecation warning (#1901) ─────────────────────────────────────────
# Fable 5 is deprecated: audit/single now default to claude-opus-5-5. A chain that
# still NAMES a claude-fable-* model (via AI_MODELS_CLAUDE or a per-tier
# CLAUDE_<TIER>_MODEL_CHAIN) is still HONOURED as a stop-gap, but warns once.

@test "fable-deprecation: detector fires for a configured fable chain, silent by default" {
  source "$LIB"
  [ -z "$(ai_models_fable_deprecation)" ]
  export AI_MODELS_CLAUDE="audit=claude-fable-5,claude-opus-4-8"
  [[ "$(ai_models_fable_deprecation)" == *"claude-fable"* ]]
  [[ "$(ai_models_fable_deprecation)" == *"claude-opus-5-5"* ]]
  unset AI_MODELS_CLAUDE
  export CLAUDE_SINGLE_MODEL_CHAIN="claude-fable-5"
  [[ "$(ai_models_fable_deprecation)" == *"claude-fable"* ]]
}

@test "fable-deprecation: engine.sh warns once via AI_MODELS_CLAUDE and still honours the model" {
  run bash -c "export REVIEW_ENGINE=claude AI_MODELS_CLAUDE='audit=claude-fable-5,claude-opus-4-8'
    _w=\"\$(mktemp)\"
    source '$SCRIPT_DIR/scripts/engine.sh' 2>\"\$_w\" >/dev/null
    echo \"AUDIT=\$ENGINE_AUDIT_MODEL\"
    echo \"WARN=\$(grep -c 'deprecated' \"\$_w\")\"
    rm -f \"\$_w\""
  # The configured Fable model is honoured (not rejected).
  [[ "$output" == *"AUDIT=claude-fable-5"* ]]
  # Exactly one deprecation warning line.
  [[ "$output" == *"WARN=1"* ]]
}

@test "fable-deprecation: warns once per run (CLAUDE_AUDIT_MODEL_CHAIN), suppressed by the flag" {
  run bash -c "export REVIEW_ENGINE=claude CLAUDE_AUDIT_MODEL_CHAIN='claude-fable-5,claude-opus-4-8'
    source '$SCRIPT_DIR/scripts/engine.sh' 2>&1 >/dev/null | grep -c 'claude-fable-\* .*deprecated'"
  [ "$output" = "1" ]
  run bash -c "export REVIEW_ENGINE=claude CLAUDE_AUDIT_MODEL_CHAIN='claude-fable-5,claude-opus-4-8' AI_MODELS_FABLE_WARNED=1
    source '$SCRIPT_DIR/scripts/engine.sh' 2>&1 >/dev/null | grep -c 'deprecated'"
  [ "$output" = "0" ]
}

@test "fable-deprecation: no warning when no fable model is configured (defaults)" {
  run bash -c "export REVIEW_ENGINE=claude; source '$SCRIPT_DIR/scripts/engine.sh' 2>&1 >/dev/null | grep -c 'fable'"
  [ "$output" = "0" ]
}

# ── ai_model_for_family (#1979) ────────────────────────────────────────────────

# The expected ids come from the default chains, not literals, so a model
# upgrade (e.g. #1978's Sonnet 5.5) never needs this test edited: that is the
# point of the family standard (#1979).
@test "family: each family resolves to its tier's current primary" {
  local deep action triage
  deep="$(ai_models_chain claude deep)";     deep="${deep%%,*}"
  action="$(ai_models_chain claude action)"; action="${action%%,*}"
  triage="$(ai_models_chain claude triage)"; triage="${triage%%,*}"
  [ "$(ai_model_for_family opus)" = "$deep" ]
  [ "$(ai_model_for_family sonnet)" = "$action" ]
  [ "$(ai_model_for_family haiku)" = "$triage" ]
  [[ "$deep" == claude-opus-* ]]
  [[ "$action" == claude-sonnet-* ]]
  [[ "$triage" == claude-haiku-* ]]
}

@test "family: AI_MODELS_CLAUDE override wins (single source of truth)" {
  export AI_MODELS_CLAUDE="deep=claude-opus-4-8,claude-sonnet-5"
  [ "$(ai_model_for_family opus)" = "claude-opus-4-8" ]
}

@test "family: per-tier CLAUDE_<TIER>_MODEL_CHAIN override wins" {
  export CLAUDE_ACTION_MODEL_CHAIN="claude-sonnet-4-6,claude-opus-4-8"
  [ "$(ai_model_for_family sonnet)" = "claude-sonnet-4-6" ]
  export CLAUDE_DEEP_MODEL_CHAIN="claude-opus-4-7"
  [ "$(ai_model_for_family opus)" = "claude-opus-4-7" ]
  export CLAUDE_TRIAGE_MODEL_CHAIN="claude-haiku-4-5-20251001,claude-sonnet-5"
  [ "$(ai_model_for_family haiku)" = "claude-haiku-4-5-20251001" ]
}

@test "family: per-tier env takes precedence over AI_MODELS_CLAUDE" {
  export AI_MODELS_CLAUDE="deep=claude-opus-4-8"
  export CLAUDE_DEEP_MODEL_CHAIN="claude-opus-4-7,claude-opus-4-8"
  [ "$(ai_model_for_family opus)" = "claude-opus-4-7" ]
}

@test "family: a set-but-malformed per-tier var does not hand precedence to AI_MODELS_CLAUDE" {
  export AI_MODELS_CLAUDE="deep=claude-opus-4-8"
  export CLAUDE_DEEP_MODEL_CHAIN=","
  local default_chain model
  default_chain="$(ai_models_default claude deep)"
  model="$(ai_model_for_family opus 2>/dev/null)"
  [ "$model" = "${default_chain%%,*}" ]
  run ai_model_for_family opus
  [ "$status" -eq 0 ]
  [[ "$output" == *"invalid model id"* ]]
}

@test "family: unknown family warns and fails" {
  run ai_model_for_family gpt
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown family"* ]]
  run ai_model_for_family ""
  [ "$status" -eq 1 ]
}

@test "family: an invalid per-tier override id falls back to the default" {
  export CLAUDE_DEEP_MODEL_CHAIN="bad id"
  local default_chain
  default_chain="$(ai_models_default claude deep)"
  run ai_model_for_family opus
  [ "$status" -eq 0 ]
  [[ "$output" == *"${default_chain%%,*}"* ]]
  [[ "$output" == *"invalid model id"* ]]
}
