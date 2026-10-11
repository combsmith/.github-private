#!/usr/bin/env bats
# Unit tests for engine.sh — a model CLI child never sees the token ledger (#2304).
#
# The dev-lead and pr-review jobs export TOKEN_LOG_FILE for the whole job. The
# shell that sources engine.sh records each call around the CLI; the CLI itself
# is an agent session that runs arbitrary commands — this repository's bats
# suites among them — so it must start without the variable, or whatever it runs
# appends fixture records to the run's real ledger.

# The claude cases go through run_agentic, not run_writer: both start the CLI in
# _claude_chain_invoke, and run_writer still keeps its session log at a fixed
# path every suite shares.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  : > "$GITHUB_ENV"
  : > "$GITHUB_OUTPUT"
  export DEV_LEAD_SIDECAR_DIR="$BATS_TEST_TMPDIR"
  export DEV_LEAD_DRY_RUN=false
  unset AI_ENGINES DEV_LEAD_ENGINES AI_MODELS_CLAUDE AI_MODELS_GEMINI AI_MODELS_COPILOT
  unset GOOGLE_API_KEY GOOGLE_API_KEY_2 GOOGLE_API_KEY_3 GOOGLE_API_KEY_4 ENGINE_USAGE_JSON
  export GEMINI_API_KEY="dummy-test-key"
  export COPILOT_GITHUB_TOKEN="dummy-copilot-token"

  # Every stub CLI writes the environment it was started with to CHILD_ENV, then
  # behaves as the shared fixture stub (gh: prints one line).
  STUB_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  CHILD_ENV="$BATS_TEST_TMPDIR/child-env"
  mkdir -p "$STUB_BIN_DIR"
  local cli
  for cli in claude gemini; do
    cp "$STUB_ENGINES_DIR/stub-$cli" "$STUB_BIN_DIR/$cli.fixture"
    printf '#!/usr/bin/env bash\nenv > "$CHILD_ENV"\nexec "$0.fixture" "$@"\n' > "$STUB_BIN_DIR/$cli"
  done
  printf '#!/usr/bin/env bash\nenv > "$CHILD_ENV"\necho "stub copilot response"\n' > "$STUB_BIN_DIR/gh"
  chmod +x "$STUB_BIN_DIR"/*
  export PATH="$STUB_BIN_DIR:$PATH" CHILD_ENV

  TEST_PROMPT="$BATS_TEST_TMPDIR/prompt"
  echo "test prompt content" > "$TEST_PROMPT"

  # The job-level ledger, as dev-lead-reusable.yml and pr-review.yml export it.
  LEDGER="$BATS_TEST_TMPDIR/ledger.jsonl"
  export TOKEN_LOG_FILE="$LEDGER" TOKEN_WORKFLOW="dev-lead"
}

_source_engine() {
  export REVIEW_ENGINE="$1"
  source "$ENGINE_SCRIPT" 2>/dev/null || true
}

# The child ran, kept the rest of its environment, and has no ledger variable.
_assert_child_has_no_ledger() {
  [ -s "$CHILD_ENV" ]
  grep -q '^TOKEN_WORKFLOW=dev-lead$' "$CHILD_ENV"
  run grep -E '^(TOKEN_LOG_FILE|GEMINI_LEDGER_FILE|_ENGINE_USAGE_OUT)=' "$CHILD_ENV"
  [ "$status" -eq 1 ]
}

# The parent wrote exactly one record, for <engine> on <tier>.
_assert_parent_recorded() {
  [ -s "$LEDGER" ]
  [ "$(jq -s 'length' < "$LEDGER")" -eq 1 ]
  [ "$(jq -r '.engine + "/" + .tier + "/" + .workflow' < "$LEDGER")" = "$1/$2/dev-lead" ]
}

@test "child-env: claude (run_agentic) starts without the ledger; the parent records the call" {
  _source_engine claude
  run run_agentic "$TEST_PROMPT" "$ENGINE_DEEP_MODEL" deep
  [ "$status" -eq 0 ]
  _assert_child_has_no_ledger
  _assert_parent_recorded claude deep
  # Real usage from the CLI's JSON envelope: the parent still runs in usage mode.
  [ "$(jq -r '.input_tokens' < "$LEDGER")" -eq 100 ]
}

@test "child-env: claude without capture files (mktemp failure path) starts without the ledger" {
  _source_engine claude
  mktemp() { return 1; }
  run _claude_chain_invoke "$ENGINE_ACTION_MODEL" "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  _assert_child_has_no_ledger
}

@test "child-env: gemini (run_triage) starts without the ledger; the parent records the call" {
  _source_engine gemini
  export GEMINI_LEDGER_FILE="$LEDGER"
  run run_triage "$TEST_PROMPT"
  [ "$status" -eq 0 ]
  _assert_child_has_no_ledger
  _assert_parent_recorded gemini triage
  [ "$(jq -r '.input_tokens' < "$LEDGER")" -eq 100 ]
}

@test "child-env: gemini on the text path (ENGINE_USAGE_JSON=0) starts without the ledger" {
  _source_engine gemini
  export ENGINE_USAGE_JSON=0
  run run_triage "$TEST_PROMPT"
  [ "$status" -eq 0 ]
  _assert_child_has_no_ledger
  _assert_parent_recorded gemini triage
}

@test "child-env: copilot (run_triage) starts without the ledger; the parent records the call" {
  _source_engine copilot
  run run_triage "$TEST_PROMPT"
  [ "$status" -eq 0 ]
  _assert_child_has_no_ledger
  _assert_parent_recorded copilot triage
}

@test "child-env: an agent that runs engine code adds nothing to the run's ledger" {
  # What issue 2304 saw: the session ran this repository's tests, and their
  # fixture calls, rejections and cooldowns reached the real ledger.
  cat > "$STUB_BIN_DIR/claude" <<STUB
#!/usr/bin/env bash
source "$SCRIPT_DIR/scripts/lib/token-metrics.sh"
source "$SCRIPT_DIR/scripts/lib/gemini-quota.sh"
emit_token_record fixture triage gemini gemini-fixture-model 1 0 1 fixture
gq_record_attempt 1 gemini-fixture-model
gq_record_cooldown 1 gemini-fixture-model 60 fixture
exec "\$0.fixture" "\$@"
STUB
  _source_engine claude
  run run_agentic "$TEST_PROMPT" "$ENGINE_DEEP_MODEL" deep
  [ "$status" -eq 0 ]
  _assert_parent_recorded claude deep
  run grep -c fixture "$LEDGER"
  [ "$output" = "0" ]
}
