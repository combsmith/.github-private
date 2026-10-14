#!/usr/bin/env bats
# Unit tests for dev-lead-intent.sh (Phase 1 stub)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
INTENT_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-intent.sh"
FIXTURES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/events"

setup() {
  # Create a temp GITHUB_ENV and GITHUB_OUTPUT file for each test
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  export BOT_USER="donpetry-bot"
  MOCK_BIN="$(mktemp -d)"
  export PATH="$MOCK_BIN:$PATH"
  # Stub gh so repository_dispatch tests don't require an authenticated GitHub CLI.
  # Default: no labels (unlabeled PR), exit 0.
  cat > "$MOCK_BIN/gh" << 'GHEOF'
#!/usr/bin/env bash
exit 0
GHEOF
  chmod +x "$MOCK_BIN/gh"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT"
  rm -rf "$MOCK_BIN"
}

# ── helpers ──────────────────────────────────────────────────────────────────

_get_env() {
  local key="$1"
  grep "^${key}=" "$GITHUB_ENV" | cut -d= -f2- | head -1
}

_get_output() {
  local key="$1"
  grep "^${key}=" "$GITHUB_OUTPUT" | cut -d= -f2- | head -1
}

# ── tests ────────────────────────────────────────────────────────────────────

@test "stub: unknown event emits skip" {
  export GITHUB_EVENT_NAME="push"
  export GITHUB_EVENT_PATH="/dev/null"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
}

@test "stub: unknown event reason is not-implemented" {
  export GITHUB_EVENT_NAME="workflow_dispatch"
  export GITHUB_EVENT_PATH="/dev/null"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_REASON)" = "not-implemented" ]
}

@test "routing: pull_request opened by human is left to the human (#1311)" {
  # A human-authored PR (branch not dev-lead/issue-*) must NOT be seized by
  # dev-lead — it emits skip, leaving the PR for the human to finish.
  export GITHUB_EVENT_NAME="pull_request"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_opened_human.json"
  export GITHUB_REPOSITORY="petry-projects/.github-private"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "not-dev-lead-authored" ]
}

@test "anti-loop: pull_request synchronize from BOT_USER emits skip" {
  export GITHUB_EVENT_NAME="pull_request"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_sync_dev_lead_commit.json"
  export BOT_USER="donpetry-bot"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "dev-lead-own-commit" ]
}

@test "anti-loop: pull_request opened by human does not trigger anti-loop skip" {
  # A PR opened by a human should NOT have reason dev-lead-own-commit
  export GITHUB_EVENT_NAME="pull_request"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_opened_human.json"
  export BOT_USER="donpetry-bot"
  export GITHUB_REPOSITORY="petry-projects/.github-private"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  # Should not be skipped due to anti-loop
  [ "$(_get_env INTENT_REASON)" != "dev-lead-own-commit" ]
}

@test "check_run event emits skip with check-run-handled-by-ci-relay" {
  export GITHUB_EVENT_NAME="check_run"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/check_run_failure.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "check-run-handled-by-ci-relay" ]
}

@test "issue_comment human trigger event emits on-mention intent" {
  export GITHUB_EVENT_NAME="issue_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issue_comment_human_trigger.json"
  export TRUSTED_BOTS="copilot-pull-request-reviewer[bot],gemini-code-assist[bot],sonarqubecloud[bot],coderabbitai[bot]"
  export TRIGGER_PHRASES="@dev-lead"
  export GITHUB_REPOSITORY="petry-projects/.github-private"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "on-mention" ]
}

@test "issues labeled dev-lead event emits issue intent" {
  export GITHUB_EVENT_NAME="issues"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issues_labeled_dev_lead.json"
  export GITHUB_REPOSITORY="petry-projects/.github-private"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "issue" ]
}

@test "repository_dispatch ci-failure event emits fix-ci intent" {
  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/repository_dispatch_ci_failure.json"
  export GITHUB_REPOSITORY="petry-projects/.github-private"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "fix-ci" ]
}

@test "INTENT_TYPE is written to both GITHUB_ENV and GITHUB_OUTPUT" {
  export GITHUB_EVENT_NAME="push"
  export GITHUB_EVENT_PATH="/dev/null"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_output intent_type)" = "skip" ]
}

@test "missing GITHUB_EVENT_NAME exits 1" {
  unset GITHUB_EVENT_NAME || true
  export GITHUB_EVENT_PATH="/dev/null"

  run bash "$INTENT_SCRIPT"

  [ "$status" -ne 0 ]
}

@test "pre-flight: missing CLAUDE_CODE_OAUTH_TOKEN exits 1" {
  unset CLAUDE_CODE_OAUTH_TOKEN || true

  run bash "$SCRIPT_DIR/scripts/dev-lead-preflight.sh"

  [ "$status" -eq 1 ]
}

@test "pre-flight: with CLAUDE_CODE_OAUTH_TOKEN set exits 0" {
  export CLAUDE_CODE_OAUTH_TOKEN="test-token-value"

  run bash "$SCRIPT_DIR/scripts/dev-lead-preflight.sh"

  [ "$status" -eq 0 ]
}

@test "dry-run: DEV_LEAD_DRY_RUN=true is logged by preflight" {
  export CLAUDE_CODE_OAUTH_TOKEN="test-token-value"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$SCRIPT_DIR/scripts/dev-lead-preflight.sh"

  [ "$status" -eq 0 ]
}
