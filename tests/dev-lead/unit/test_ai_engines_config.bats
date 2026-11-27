#!/usr/bin/env bats
# config/ai-engines.json as the engines' source of defaults (#2630, part 2 of
# #1973). scripts/lib/engine-models.sh reads the file with jq (ai_models_default),
# scripts/lib/engine-chain.sh takes the default provider order from it, and:
#   - a missing, unreadable or malformed file is an ::error:: and a non-zero
#     return, and engine.sh fails the step; there is no built-in fallback;
#   - precedence is the specific env var > AI_MODELS_* > the file;
#   - AI_ENGINES narrows and reorders the file's providers, but cannot turn on
#     one the file disables;
#   - ai_engines_overrides lists each AI_MODELS_* / AI_ENGINES value that differs
#     from the file (the daily health check prints it).
#
# Each case points AI_ENGINES_CONFIG (the lib's test seam) at a copy of the
# committed file changed in one place, so a pass proves the value came from the
# file. tests/dev-lead/unit/test_engine_models.bats, unchanged, proves the
# committed file gives the same defaults the old built-in table did.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
MODELS_LIB="$SCRIPT_DIR/scripts/lib/engine-models.sh"
CHAIN_LIB="$SCRIPT_DIR/scripts/lib/engine-chain.sh"
CONFIG="$SCRIPT_DIR/config/ai-engines.json"

setup() {
  unset AI_MODELS_CLAUDE AI_MODELS_GEMINI AI_MODELS_COPILOT AI_MODELS_PROBLEM_REPORTED
  unset CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN CLAUDE_AUDIT_MODEL_CHAIN
  unset CLAUDE_ACTION_MODEL_CHAIN CLAUDE_SINGLE_MODEL_CHAIN CLAUDE_FABLE_MODEL_CHAIN
  unset GEMINI_FLASH_MODEL GEMINI_PRO_MODEL GEMINI_FLASH_MODEL_CHAIN GEMINI_PRO_MODEL_CHAIN
  unset COPILOT_API_MODEL COPILOT_API_MODEL_DEFAULTED AI_ENGINES DEV_LEAD_ENGINES
  unset AI_DUCK_ENGINE AI_DUCK_MODEL AI_ENGINES_CONFIG AI_ENGINES_PROBLEM_REPORTED
  unset REVIEW_ENGINE DEV_LEAD_ENGINE
  FIXTURE="$BATS_TEST_TMPDIR/ai-engines.json"
  export DEV_LEAD_SIDECAR_DIR="$BATS_TEST_TMPDIR"
  # shellcheck source=../../../scripts/lib/engine-models.sh
  source "$MODELS_LIB"
  # shellcheck source=../../../scripts/lib/engine-chain.sh
  source "$CHAIN_LIB"
}

# _fixture <jq filter> — the committed file changed by <filter>, used as the config.
_fixture() {
  jq "$1" "$CONFIG" > "$FIXTURE"
  export AI_ENGINES_CONFIG="$FIXTURE"
}

# _engine <engine> <var>… — sources engine.sh for <engine> in a child shell and
# prints VAR=value per requested var; stderr is kept so a case can assert on it.
_engine() {
  local engine="$1"; shift
  local vars="" v
  for v in "$@"; do vars="$vars $v=\${$v:-}"; done
  bash -c "export REVIEW_ENGINE=$engine; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null; echo \"$vars\""
}

# ── The file is the source of defaults ────────────────────────────────────────

@test "file: the path resolves next to the lib, not the working directory" {
  cd "$BATS_TEST_TMPDIR"
  [ "$(ai_engines_config_path)" = "$CONFIG" ]
  [ "$(ai_models_default claude deep)" = "claude-opus-5-5,claude-opus-4-8,claude-sonnet-5-5" ]
}

@test "file: ai_models_default reads each chain from the file" {
  _fixture '.tasks.deep.claude = ["claude-opus-4-8", "claude-sonnet-5"]
            | .tasks.audit.gemini = ["gemini-3.8-flash"]
            | .tasks.single.copilot = ["openai/o4-mini-x"]
            | .tasks.fable.claude = ["claude-fable-5-1"]'
  [ "$(ai_models_default claude deep)" = "claude-opus-4-8,claude-sonnet-5" ]
  [ "$(ai_models_chain claude deep)" = "claude-opus-4-8,claude-sonnet-5" ]
  [ "$(ai_models_chain gemini audit)" = "gemini-3.8-flash" ]
  [ "$(ai_models_gemini_chain audit)" = "gemini-3.8-flash" ]
  [ "$(ai_models_copilot_model single)" = "openai/o4-mini-x" ]
  [ "$(ai_model_for_family opus)" = "claude-opus-4-8" ]
  [ "$(ai_model_for_family fable)" = "claude-fable-5-1" ]
}

@test "file: a chain the file leaves out has no default (Gemini and Copilot duck)" {
  [ -z "$(ai_models_default gemini duck)" ]
  [ -z "$(ai_models_default copilot duck)" ]
  [ -z "$(ai_models_default gemini fable)" ]
  [ -z "$(ai_models_default openai deep)" ]
  # The duck still follows the triage model.
  _fixture '.tasks.triage.gemini = ["gemini-3.8-flash-x", "gemini-3.1-pro-preview"]'
  [ "$(ai_models_gemini_chain duck)" = "gemini-3.8-flash-x" ]
}

@test "file: engine.sh takes its chains from the file" {
  _fixture '.tasks.deep.claude = ["claude-opus-4-8", "claude-sonnet-5"]
            | .tasks.triage.gemini = ["gemini-3.8-flash-x"]'
  run _engine claude CLAUDE_DEEP_MODEL_CHAIN
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLAUDE_DEEP_MODEL_CHAIN=claude-opus-4-8,claude-sonnet-5"* ]]
  run _engine gemini ENGINE_TRIAGE_MODEL
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENGINE_TRIAGE_MODEL=gemini-3.8-flash-x"* ]]
}

@test "file: the built-in table is gone from the lib" {
  run grep -nE 'claude:(triage|deep|audit|action|single|duck|fable)\)' "$MODELS_LIB"
  [ "$status" -eq 1 ]
}

# ── A missing or malformed file fails loudly ──────────────────────────────────

@test "missing file: ::error:: and non-zero from every resolver" {
  export AI_ENGINES_CONFIG="$BATS_TEST_TMPDIR/nope.json"
  run ai_models_default claude deep
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"nope.json"* ]]
  [[ "$output" == *"missing or unreadable"* ]]
  run ai_models_chain claude deep
  [ "$status" -ne 0 ]
  run ai_models_gemini_chain deep
  [ "$status" -ne 0 ]
  run ai_models_copilot_model triage
  [ "$status" -ne 0 ]
  run ai_model_for_family sonnet
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  run ai_engines_config_load
  [ "$status" -ne 0 ]
}

@test "missing file: an AI_MODELS_* entry still answers its own key" {
  # The break-glass override does not need the file: an operator can route
  # around a bad file for the keys they set.
  export AI_ENGINES_CONFIG="$BATS_TEST_TMPDIR/nope.json"
  export AI_MODELS_CLAUDE="deep=claude-opus-4-8"
  [ "$(ai_models_chain claude deep)" = "claude-opus-4-8" ]
  run ai_models_chain claude audit
  [ "$status" -ne 0 ]
}

@test "unreadable file: ::error:: and non-zero" {
  [ "$(id -u)" -ne 0 ] || skip "root reads any file"
  cp "$CONFIG" "$FIXTURE"
  chmod 000 "$FIXTURE"
  export AI_ENGINES_CONFIG="$FIXTURE"
  run ai_models_default claude deep
  chmod 600 "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "malformed file: invalid JSON is an ::error::, not a fallback" {
  printf '{"tasks": ' > "$FIXTURE"
  export AI_ENGINES_CONFIG="$FIXTURE"
  run ai_models_default claude deep
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"malformed"* ]]
  [[ "$output" != *"claude-opus"* ]]
}

@test "malformed file: valid JSON without the tasks/providers sections is an ::error::" {
  _fixture 'del(.providers)'
  run ai_models_default claude deep
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed"* ]]
  _fixture '.tasks = []'
  run ai_models_default claude deep
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed"* ]]
  printf 'null' > "$FIXTURE"
  run ai_models_default claude deep
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed"* ]]
}

@test "malformed file: a chain that is not a list of ids is an ::error::" {
  _fixture '.tasks.deep.claude = "claude-opus-5-5"'
  run ai_models_default claude deep
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed"* ]]
}

@test "missing file: engine.sh fails the step with ::error::" {
  export AI_ENGINES_CONFIG="$BATS_TEST_TMPDIR/nope.json"
  run bash -c "export REVIEW_ENGINE=claude; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null; echo sourced"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" != *"sourced"* ]]
}

@test "malformed file: engine.sh fails the step with ::error::" {
  printf 'not json' > "$FIXTURE"
  export AI_ENGINES_CONFIG="$FIXTURE"
  run bash -c "export REVIEW_ENGINE=gemini; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null; echo sourced"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" != *"sourced"* ]]
}

@test "load: ai_engines_config_load caches the file for later lookups in this shell" {
  cp "$CONFIG" "$FIXTURE"
  export AI_ENGINES_CONFIG="$FIXTURE"
  ai_engines_config_load
  rm -f "$FIXTURE"
  # Served from the cache: the file is gone.
  [ "$(ai_models_default claude deep)" = "claude-opus-5-5,claude-opus-4-8,claude-sonnet-5-5" ]
  # Pointing at another path rereads (and so fails here).
  export AI_ENGINES_CONFIG="$BATS_TEST_TMPDIR/other.json"
  run ai_models_default claude deep
  [ "$status" -ne 0 ]
}

# ── Precedence: env var > AI_MODELS_* > file ──────────────────────────────────

@test "precedence claude: CLAUDE_<TIER>_MODEL_CHAIN > AI_MODELS_CLAUDE > file" {
  _fixture '.tasks.deep.claude = ["claude-opus-4-7"]'
  run _engine claude CLAUDE_DEEP_MODEL_CHAIN
  [[ "$output" == *"CLAUDE_DEEP_MODEL_CHAIN=claude-opus-4-7"* ]]
  export AI_MODELS_CLAUDE="deep=claude-opus-4-8"
  run _engine claude CLAUDE_DEEP_MODEL_CHAIN
  [[ "$output" == *"CLAUDE_DEEP_MODEL_CHAIN=claude-opus-4-8"* ]]
  export CLAUDE_DEEP_MODEL_CHAIN="claude-sonnet-5"
  run _engine claude CLAUDE_DEEP_MODEL_CHAIN
  [[ "$output" == *"CLAUDE_DEEP_MODEL_CHAIN=claude-sonnet-5"* ]]
}

@test "precedence family: CLAUDE_<TIER>_MODEL_CHAIN > AI_MODELS_CLAUDE > file" {
  _fixture '.tasks.action.claude = ["claude-sonnet-5"]'
  [ "$(ai_model_for_family sonnet)" = "claude-sonnet-5" ]
  export AI_MODELS_CLAUDE="action=claude-opus-4-8"
  [ "$(ai_model_for_family sonnet)" = "claude-opus-4-8" ]
  export CLAUDE_ACTION_MODEL_CHAIN="claude-haiku-4-5-20251001"
  [ "$(ai_model_for_family sonnet)" = "claude-haiku-4-5-20251001" ]
}

@test "precedence gemini: GEMINI_PRO_MODEL_CHAIN > GEMINI_PRO_MODEL > AI_MODELS_GEMINI > file" {
  _fixture '.tasks.deep.gemini = ["gemini-file", "gemini-3.8-flash"]'
  [ "$(ai_models_gemini_chain deep)" = "gemini-file,gemini-3.8-flash" ]
  export AI_MODELS_GEMINI="deep=gemini-var"
  [ "$(ai_models_gemini_chain deep)" = "gemini-var" ]
  export GEMINI_PRO_MODEL="gemini-first"
  [ "$(ai_models_gemini_chain deep)" = "gemini-first" ]
  unset AI_MODELS_GEMINI
  [ "$(ai_models_gemini_chain deep)" = "gemini-first,gemini-3.8-flash" ]
  export GEMINI_PRO_MODEL_CHAIN="gemini-env,gemini-env-2"
  [ "$(ai_models_gemini_chain deep)" = "gemini-env,gemini-env-2" ]
}

@test "precedence copilot: COPILOT_API_MODEL > AI_MODELS_COPILOT > file" {
  _fixture '.tasks.deep.copilot = ["openai/file-model"]'
  [ "$(ai_models_copilot_model deep)" = "openai/file-model" ]
  export AI_MODELS_COPILOT="deep=openai/var-model"
  [ "$(ai_models_copilot_model deep)" = "openai/var-model" ]
  export COPILOT_API_MODEL="openai/env-model"
  [ "$(ai_models_copilot_model deep)" = "openai/env-model" ]
}

@test "precedence: an unusable AI_MODELS_* entry falls back to the file, not a built-in" {
  _fixture '.tasks.audit.claude = ["claude-opus-4-7"]'
  export AI_MODELS_CLAUDE="audit=bad id"
  [ "$(ai_models_chain claude audit)" = "claude-opus-4-7" ]
}

# ── Providers: AI_ENGINES narrows the file ────────────────────────────────────

@test "providers: the default chain is the file's enabled providers in fallback_order" {
  _fixture '.providers.fallback_order = ["gemini", "copilot", "claude"]'
  [ "$(ai_engines_file_providers)" = "gemini copilot claude" ]
  [ "$(ai_engine_chain)" = "gemini copilot claude" ]
  [ "$(ai_engine_primary "")" = "gemini" ]
  _fixture '.providers.copilot.enabled = false'
  [ "$(ai_engine_chain)" = "claude gemini" ]
  [ "$(ai_engines_file_disabled)" = "copilot" ]
  ! ai_engine_enabled copilot || false
}

@test "providers: AI_ENGINES can disable and reorder what the file enables" {
  export AI_ENGINES="gemini,claude"
  [ "$(ai_engine_chain)" = "gemini claude" ]
  [ -z "$(ai_engine_chain_problem)" ]
}

@test "providers: AI_ENGINES cannot enable a provider the file disables" {
  _fixture '.providers.copilot.enabled = false'
  export AI_ENGINES="copilot,claude"
  [ "$(ai_engine_chain)" = "claude" ]
  ! ai_engine_enabled copilot || false
  [ "$(ai_engine_primary copilot)" = "claude" ]
  run ai_engine_chain_problem
  [[ "$output" == *"copilot"* ]]
  [[ "$output" == *"disables"* ]]
}

@test "providers: AI_ENGINES naming only disabled providers falls back to the file's chain" {
  _fixture '.providers.copilot.enabled = false'
  export AI_ENGINES="copilot"
  [ "$(ai_engine_chain)" = "claude gemini" ]
  [ "$(ai_engine_primary copilot)" = "claude" ]
  run ai_engine_chain_problem
  [[ "$output" == *"disables"* ]]
  [[ "$output" == *"claude gemini"* ]]
}

@test "providers: an invalid AI_ENGINES falls back to the file's chain, not a built-in" {
  _fixture '.providers.fallback_order = ["gemini", "claude", "copilot"] | .providers.copilot.enabled = false'
  export AI_ENGINES="claude,cluade"
  [ "$(ai_engine_chain)" = "gemini claude" ]
  [[ "$(ai_engine_chain_problem)" == *"'gemini claude'"* ]]
}

@test "providers: engine.sh does not run a provider the file disables" {
  _fixture '.providers.gemini.enabled = false'
  export AI_ENGINES="gemini,claude"
  run _engine gemini REVIEW_ENGINE
  [ "$status" -eq 0 ]
  [[ "$output" == *"REVIEW_ENGINE=claude"* ]]
}

# ── Override report (daily health check) ──────────────────────────────────────

@test "overrides: nothing set → nothing listed" {
  run ai_engines_overrides
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "overrides: an AI_MODELS_* key that differs from the file is listed with the file's chain" {
  export AI_MODELS_CLAUDE="deep=claude-opus-4-8; triage=claude-haiku-4-5-20251001,claude-sonnet-5-5,claude-sonnet-5"
  export AI_MODELS_GEMINI="audit=gemini-3.8-flash"
  run ai_engines_overrides
  [ "$status" -eq 0 ]
  [[ "$output" == *"AI_MODELS_CLAUDE deep=claude-opus-4-8 (file: claude-opus-5-5,claude-opus-4-8,claude-sonnet-5-5)"* ]]
  [[ "$output" == *"AI_MODELS_GEMINI audit=gemini-3.8-flash (file: gemini-3.1-pro-preview,gemini-3.8-flash)"* ]]
  # A key equal to the file is not an override worth folding back.
  [[ "$output" != *"triage"* ]]
}

@test "overrides: a Gemini/Copilot duck is compared with the triage model it follows" {
  export AI_MODELS_COPILOT="duck=openai/o4-mini"
  export AI_MODELS_GEMINI="duck=gemini-3.1-pro-preview"
  run ai_engines_overrides
  [[ "$output" != *"AI_MODELS_COPILOT"* ]]
  [[ "$output" == *"AI_MODELS_GEMINI duck=gemini-3.1-pro-preview (file: gemini-3.8-flash)"* ]]
}

@test "overrides: AI_ENGINES that differs from the file is listed; one that matches is not" {
  export AI_ENGINES="claude,gemini,copilot"
  run ai_engines_overrides
  [ -z "$output" ]
  export AI_ENGINES="gemini,claude"
  run ai_engines_overrides
  [[ "$output" == *"AI_ENGINES=gemini,claude → gemini claude (file: claude gemini copilot)"* ]]
}

@test "overrides: an AI_ENGINES that tries to enable a disabled provider is listed with the reason" {
  _fixture '.providers.copilot.enabled = false'
  export AI_ENGINES="claude,gemini,copilot"
  run ai_engines_overrides
  [[ "$output" == *"AI_ENGINES=claude,gemini,copilot → claude gemini (file: claude gemini)"* ]]
  [[ "$output" == *"disables"* ]]
}

@test "overrides: an unreadable file is an error, even with no override set" {
  export AI_ENGINES_CONFIG="$BATS_TEST_TMPDIR/nope.json"
  run ai_engines_overrides
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "providers: a file that enables no provider does not fall back to the built-in order" {
  _fixture '.providers.claude.enabled = false | .providers.gemini.enabled = false | .providers.copilot.enabled = false'
  [ -z "$(ai_engine_chain)" ]
  export AI_ENGINES="claude"
  [ -z "$(ai_engine_chain)" ]
}
