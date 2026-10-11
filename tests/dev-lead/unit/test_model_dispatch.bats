#!/usr/bin/env bats
# Unit tests for engine.sh — model_for_intent() intent-based model dispatch

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  # Sidecars go to this test's directory, not the /tmp every session shares (#2271).
  export DEV_LEAD_SIDECAR_DIR="$BATS_TEST_TMPDIR"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT"
}

_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT"
}

# ── triage-tier intents (haiku / lightest model) ──────────────────────────────

@test "dispatch: human-pr intent returns ENGINE_TRIAGE_MODEL" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "human-pr")"
  [ "$result" = "$ENGINE_TRIAGE_MODEL" ]
}

@test "dispatch: fix-bot-comment intent returns ENGINE_TRIAGE_MODEL" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "fix-bot-comment")"
  [ "$result" = "$ENGINE_TRIAGE_MODEL" ]
}

# ── action-tier intents (sonnet / write operations) ───────────────────────────

@test "dispatch: fix-reviews intent returns ENGINE_ACTION_MODEL" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "fix-reviews")"
  [ "$result" = "$ENGINE_ACTION_MODEL" ]
}

@test "dispatch: fix-ci intent returns ENGINE_ACTION_MODEL" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "fix-ci")"
  [ "$result" = "$ENGINE_ACTION_MODEL" ]
}

@test "dispatch: rebase intent returns ENGINE_ACTION_MODEL" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "rebase")"
  [ "$result" = "$ENGINE_ACTION_MODEL" ]
}

# ── deep-tier intents (sonnet/opus / full agentic work) ───────────────────────

@test "dispatch: fix-issue intent returns ENGINE_DEEP_MODEL" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "fix-issue")"
  [ "$result" = "$ENGINE_DEEP_MODEL" ]
}

@test "dispatch: human intent returns ENGINE_DEEP_MODEL" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "human")"
  [ "$result" = "$ENGINE_DEEP_MODEL" ]
}

# ── default/unknown intents fall back to ENGINE_ACTION_MODEL ──────────────────

@test "dispatch: unknown intent returns ENGINE_ACTION_MODEL" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "some-unknown-intent")"
  [ "$result" = "$ENGINE_ACTION_MODEL" ]
}

@test "dispatch: empty intent returns ENGINE_ACTION_MODEL" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "")"
  [ "$result" = "$ENGINE_ACTION_MODEL" ]
}

@test "dispatch: no-arg call returns ENGINE_ACTION_MODEL" {
  _source_engine "claude"
  local result
  result="$(model_for_intent)"
  [ "$result" = "$ENGINE_ACTION_MODEL" ]
}

# ── triage model differs from action model on claude engine ───────────────────

@test "dispatch: triage model is different from action model on claude engine" {
  _source_engine "claude"
  [ "$ENGINE_TRIAGE_MODEL" != "$ENGINE_ACTION_MODEL" ]
}

@test "dispatch: human-pr gets haiku (claude-haiku-4-5) not sonnet" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "human-pr")"
  # Must be haiku, not sonnet
  [[ "$result" == *"haiku"* ]]
  [[ "$result" != *"sonnet"* ]]
}

@test "dispatch: fix-reviews gets sonnet (claude-sonnet-5)" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "fix-reviews")"
  [[ "$result" == *"sonnet"* ]]
}

# ── engine-specific models are respected ──────────────────────────────────────

@test "dispatch: gemini engine — human-pr returns gemini triage model" {
  _source_engine "gemini"
  local result
  result="$(model_for_intent "human-pr")"
  [ "$result" = "$ENGINE_TRIAGE_MODEL" ]
  [[ "$result" == *"gemini"* ]]
}

@test "dispatch: gemini engine — fix-issue returns gemini deep model" {
  _source_engine "gemini"
  local result
  result="$(model_for_intent "fix-issue")"
  [ "$result" = "$ENGINE_DEEP_MODEL" ]
  [[ "$result" == *"gemini"* ]]
}

@test "dispatch: copilot engine — all intents return copilot model" {
  _source_engine "copilot"
  # For copilot, all tier models are the same (o4-mini)
  local triage action deep
  triage="$(model_for_intent "human-pr")"
  action="$(model_for_intent "fix-reviews")"
  deep="$(model_for_intent "fix-issue")"
  [ "$triage" = "$ENGINE_TRIAGE_MODEL" ]
  [ "$action" = "$ENGINE_ACTION_MODEL" ]
  [ "$deep" = "$ENGINE_DEEP_MODEL" ]
}

# ── run_writer_with_fallback passes intent through to model selection ─────────

@test "dispatch: run_writer_with_fallback uses triage model for human-pr intent" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  # Capture which model was used by recording STUB_ENGINE_RECORD_MODELS
  local record_file
  record_file="$(mktemp)"
  export STUB_ENGINE_RECORD_MODELS="$record_file"

  # Install a stub claude that records the --model arg
  local stub_bin
  stub_bin="$(mktemp -d)"
  cp "$SCRIPT_DIR/tests/dev-lead/fixtures/engines/stub-claude" "$stub_bin/claude"
  chmod +x "$stub_bin/claude"
  export PATH="$stub_bin:$PATH"

  local prompt
  prompt="$(mktemp)"
  echo "test" > "$prompt"

  STUB_ENGINE_EXIT=0 run_writer_with_fallback "$prompt" "human-pr"

  # The model recorded by the stub must be the triage model (haiku)
  local used_model
  used_model="$(head -1 "$record_file")"
  [[ "$used_model" == *"haiku"* ]]

  rm -f "$record_file" "$prompt"
  rm -rf "$stub_bin"
  unset STUB_ENGINE_RECORD_MODELS
}

@test "dispatch: run_writer_with_fallback uses action model for fix-reviews intent" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  local record_file
  record_file="$(mktemp)"
  export STUB_ENGINE_RECORD_MODELS="$record_file"

  local stub_bin
  stub_bin="$(mktemp -d)"
  cp "$SCRIPT_DIR/tests/dev-lead/fixtures/engines/stub-claude" "$stub_bin/claude"
  chmod +x "$stub_bin/claude"
  export PATH="$stub_bin:$PATH"

  local prompt
  prompt="$(mktemp)"
  echo "test" > "$prompt"

  STUB_ENGINE_EXIT=0 run_writer_with_fallback "$prompt" "fix-reviews"

  local used_model
  used_model="$(head -1 "$record_file")"
  [[ "$used_model" == *"sonnet"* ]]

  rm -f "$record_file" "$prompt"
  rm -rf "$stub_bin"
  unset STUB_ENGINE_RECORD_MODELS
}
