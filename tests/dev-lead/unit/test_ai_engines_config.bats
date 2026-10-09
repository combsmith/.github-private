#!/usr/bin/env bats
# config/ai-engines.json (#1973): the versioned source of truth for providers,
# the model catalog and each task's chain. engine-models.sh reads its defaults
# from the file (jq); AI_MODELS_* and AI_ENGINES are break-glass overrides on
# top of it. test_engine_models.bats proves the defaults did not change; this
# file covers the file itself: a missing or malformed file, precedence,
# provider enablement and the override report.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/engine-models.sh"
CHAIN_LIB="$SCRIPT_DIR/scripts/lib/engine-chain.sh"
CONFIG="$SCRIPT_DIR/config/ai-engines.json"

setup() {
  unset AI_MODELS_CLAUDE AI_MODELS_GEMINI AI_MODELS_COPILOT AI_MODELS_PROBLEM_REPORTED
  unset CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN CLAUDE_AUDIT_MODEL_CHAIN
  unset CLAUDE_ACTION_MODEL_CHAIN CLAUDE_SINGLE_MODEL_CHAIN
  unset GEMINI_FLASH_MODEL GEMINI_PRO_MODEL GEMINI_FLASH_MODEL_CHAIN GEMINI_PRO_MODEL_CHAIN
  unset COPILOT_API_MODEL COPILOT_API_MODEL_DEFAULTED AI_ENGINES DEV_LEAD_ENGINES
  unset AI_DUCK_ENGINE AI_DUCK_MODEL GEMINI_AVAILABLE AI_ENGINES_CONFIG REVIEW_ENGINE
  # shellcheck source=../../../scripts/lib/engine-models.sh
  source "$LIB"
}

# Writes a copy of the repo config with <jq-filter> applied and points
# AI_ENGINES_CONFIG at it.
_config_with() {
  local f="$BATS_TEST_TMPDIR/ai-engines.json"
  jq "$1" "$CONFIG" > "$f"
  export AI_ENGINES_CONFIG="$f"
}

# ── The file is the default ──────────────────────────────────────────────────

@test "file: every default chain is the file's task chain" {
  local task provider want
  for task in triage deep audit action single duck; do
    for provider in claude gemini copilot; do
      want="$(jq -r --arg t "$task" --arg p "$provider" '.tasks[$t][$p] // [] | join(",")' "$CONFIG")"
      [ "$(ai_models_default "$provider" "$task")" = "$want" ]
    done
  done
}

@test "file: a changed file changes the default (no built-in table left)" {
  _config_with '.tasks.deep.claude = ["claude-opus-4-8"]'
  [ "$(ai_models_default claude deep)" = "claude-opus-4-8" ]
  [ "$(ai_models_chain claude deep)" = "claude-opus-4-8" ]
}

@test "file: resolved relative to the lib, whatever the caller's working directory" {
  cd "$BATS_TEST_TMPDIR"
  [ "$(ai_engines_config_path)" = "$CONFIG" ]
  [ -n "$(ai_models_default claude deep)" ]
}

# ── A missing or malformed file fails loudly ─────────────────────────────────

@test "missing file: ::error:: and non-zero, no built-in fallback" {
  export AI_ENGINES_CONFIG="$BATS_TEST_TMPDIR/nope.json"
  run ai_models_default claude deep
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"nope.json"* ]]
  [[ "$output" != *"claude-opus"* ]]
  run ai_models_chain claude deep
  [ "$status" -ne 0 ]
  run ai_engines_config_load
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "malformed file: invalid JSON or a file without tasks fails loudly" {
  printf '{"tasks": {' > "$BATS_TEST_TMPDIR/bad.json"
  export AI_ENGINES_CONFIG="$BATS_TEST_TMPDIR/bad.json"
  run ai_models_default claude deep
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  printf '{"models": {}}' > "$BATS_TEST_TMPDIR/bad.json"
  run ai_models_default claude deep
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "missing file: sourcing engine.sh fails the step" {
  run bash -c "set -e; export REVIEW_ENGINE=claude AI_ENGINES_CONFIG='$BATS_TEST_TMPDIR/nope.json'
    source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null; echo sourced"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" != *"sourced"* ]]
}

@test "family: a missing file returns non-zero instead of an empty id" {
  export AI_ENGINES_CONFIG="$BATS_TEST_TMPDIR/nope.json"
  run ai_model_for_family opus
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "load: a loaded table is reused, and reloaded when the path changes" {
  ai_engines_config_load
  [ "$(ai_models_default claude deep)" = "$(jq -r '.tasks.deep.claude | join(",")' "$CONFIG")" ]
  _config_with '.tasks.deep.claude = ["claude-opus-4-7"]'
  [ "$(ai_models_default claude deep)" = "claude-opus-4-7" ]
}

# ── Precedence: specific env var > AI_MODELS_* > file ────────────────────────

@test "precedence: AI_MODELS_* beats the file; a per-tier env var beats both" {
  _config_with '.tasks.deep.claude = ["claude-opus-4-7"]'
  [ "$(ai_models_chain claude deep)" = "claude-opus-4-7" ]
  export AI_MODELS_CLAUDE="deep=claude-opus-4-8"
  [ "$(ai_models_chain claude deep)" = "claude-opus-4-8" ]
  export CLAUDE_DEEP_MODEL_CHAIN="claude-sonnet-5"
  [ "$(ai_model_for_family opus)" = "claude-sonnet-5" ]
  run bash -c "export REVIEW_ENGINE=claude; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1; echo \"deep=\$ENGINE_DEEP_MODEL\""
  [[ "$output" == *"deep=claude-sonnet-5"* ]]
}

@test "precedence: Gemini and Copilot specific vars still beat AI_MODELS_* and the file" {
  export AI_MODELS_GEMINI="deep=gemini-d1" GEMINI_PRO_MODEL_CHAIN="gemini-c1"
  [ "$(ai_models_gemini_chain deep)" = "gemini-c1" ]
  export AI_MODELS_COPILOT="deep=openai/d1" COPILOT_API_MODEL="openai/pinned"
  [ "$(ai_models_copilot_model deep)" = "openai/pinned" ]
}

# ── Providers: the file enables, AI_ENGINES can only narrow ──────────────────

@test "providers: the default chain is the file's fallback order of enabled providers" {
  source "$CHAIN_LIB"
  [ "$(ai_engine_chain)" = "$(jq -r '.providers.fallback_order | join(" ")' "$CONFIG")" ]
  _config_with '.providers.fallback_order = ["gemini","claude","copilot"]'
  [ "$(ai_engine_chain)" = "gemini claude copilot" ]
}

@test "providers: AI_ENGINES can disable a provider the file enables" {
  source "$CHAIN_LIB"
  export AI_ENGINES="claude,gemini"
  [ "$(ai_engine_chain)" = "claude gemini" ]
  ! ai_engine_enabled copilot
}

@test "providers: AI_ENGINES cannot enable a provider the file disables" {
  source "$CHAIN_LIB"
  _config_with '.providers.copilot.enabled = false'
  [ "$(ai_engine_chain)" = "claude gemini" ]
  export AI_ENGINES="copilot,claude"
  [ "$(ai_engine_chain)" = "claude" ]
  ! ai_engine_enabled copilot
  [ "$(ai_engine_primary copilot)" = "claude" ]
  [[ "$(ai_engine_chain_problem)" == *"copilot"*"disabled"* ]]
}

# ── Override visibility ──────────────────────────────────────────────────────

@test "overrides: nothing set, or set to the file's value, reports nothing" {
  [ -z "$(ai_engines_overrides)" ]
  export AI_MODELS_CLAUDE="deep=$(jq -r '.tasks.deep.claude | join(",")' "$CONFIG")"
  export AI_ENGINES="$(jq -r '.providers.fallback_order | join(",")' "$CONFIG")"
  [ -z "$(ai_engines_overrides)" ]
}

@test "overrides: an AI_MODELS_* key or AI_ENGINES that differs from the file is listed" {
  export AI_MODELS_GEMINI="deep=gemini-x; triage=$(jq -r '.tasks.triage.gemini | join(",")' "$CONFIG")"
  export AI_ENGINES="claude,gemini"
  run ai_engines_overrides
  [ "$status" -eq 0 ]
  [[ "$output" == *"AI_MODELS_GEMINI deep=gemini-x"*"file: "* ]]
  [[ "$output" != *"triage"* ]]
  [[ "$output" == *"AI_ENGINES"*"claude gemini"*"file: claude gemini copilot"* ]]
}

@test "overrides: the health check prints the override section" {
  grep -q 'ai_engines_overrides' "$SCRIPT_DIR/scripts/pr_review_health.sh"
  local wf="$SCRIPT_DIR/.github/workflows/daily-pr-review-health.yml"
  grep -q 'AI_MODELS_GEMINI: ${{ vars.AI_MODELS_GEMINI }}' "$wf"
  grep -q 'AI_MODELS_COPILOT: ${{ vars.AI_MODELS_COPILOT }}' "$wf"
  grep -q 'AI_ENGINES: ${{ vars.AI_ENGINES }}' "$wf"
}

# ── Shipping the file ────────────────────────────────────────────────────────

@test "ship: dev-lead's sparse checkouts include config/ next to scripts/" {
  local wf="$SCRIPT_DIR/.github/workflows/dev-lead-reusable.yml"
  local scripts_n config_n
  scripts_n="$(grep -cE '^ {12}scripts$' "$wf")"
  config_n="$(grep -cE '^ {12}config$' "$wf")"
  [ "$scripts_n" -ge 1 ]
  [ "$config_n" = "$scripts_n" ]
}

@test "ship: the consumer manifest lists the file for pr-review and dev-lead" {
  local m="$SCRIPT_DIR/scripts/lib/consumer-manifest.json"
  jq -e '.surface_sources[".github/workflows/pr-review.yml"] | index("config/ai-engines.json")' "$m"
  jq -e '.surface_sources[".github/workflows/dev-lead-reusable.yml"] | index("config/ai-engines.json")' "$m"
}
