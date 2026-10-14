#!/usr/bin/env bats
# Unit tests for dev-lead-intent.sh — the `dev-lead:hands-off` label guard.
# A PR or issue carrying the label is excluded from the agent regardless of the
# event that would otherwise route it (so the agent doesn't pile commits onto
# PRs that modify the dev-lead workflow itself).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
INTENT_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-intent.sh"
FIXTURES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/events"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  export BOT_USER="donpetry-bot"
  export TRUSTED_BOTS="copilot-pull-request-reviewer[bot],gemini-code-assist[bot],sonarqubecloud[bot],coderabbitai[bot],chatgpt-codex-connector[bot]"
  export TRIGGER_PHRASES="@dev-lead"
  export GITHUB_REPOSITORY="petry-projects/.github-private"
  MOCK_BIN="$(mktemp -d)"
  export PATH="$MOCK_BIN:$PATH"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT"
  rm -rf "$MOCK_BIN"
}

_get_env() {
  local key="$1"
  grep "^${key}=" "$GITHUB_ENV" | cut -d= -f2- | head -1
}

@test "hands-off: bot review comment on a labeled PR → skip (not fix-reviews)" {
  export GITHUB_EVENT_NAME="pull_request_review_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_comment_copilot_hands_off.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "hands-off-label" ]
}

@test "hands-off: control — same bot review comment without the label → fix-reviews" {
  export GITHUB_EVENT_NAME="pull_request_review_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_comment_copilot.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "fix-reviews" ]
}

@test "hands-off: issue labeled dev-lead but also hands-off → skip (no pickup)" {
  export GITHUB_EVENT_NAME="issues"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issues_labeled_dev_lead_hands_off.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "hands-off-label" ]
}

@test "hands-off: bot sync on labeled PR → skip with hands-off-label (not dev-lead-own-commit)" {
  export GITHUB_EVENT_NAME="pull_request"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_sync_bot_hands_off.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "hands-off-label" ]
}

@test "hands-off: repository_dispatch ci-failure for labeled PR → skip" {
  # Mock gh to return the hands-off label for the dispatch PR
  cat > "$MOCK_BIN/gh" << 'GHEOF'
#!/usr/bin/env bash
echo "dev-lead:hands-off"
GHEOF
  chmod +x "$MOCK_BIN/gh"

  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/repository_dispatch_ci_failure.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "hands-off-label" ]
}

@test "hands-off: repository_dispatch ci-failure for unlabeled PR → fix-ci (control)" {
  # Mock gh to return no labels
  cat > "$MOCK_BIN/gh" << 'GHEOF'
#!/usr/bin/env bash
exit 0
GHEOF
  chmod +x "$MOCK_BIN/gh"

  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/repository_dispatch_ci_failure.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "fix-ci" ]
}

@test "hands-off: repository_dispatch ci-failure with API error → skip (fail closed)" {
  # Mock gh to simulate a failure (e.g. token lacks issue read access)
  cat > "$MOCK_BIN/gh" << 'GHEOF'
#!/usr/bin/env bash
echo "gh: request failed: HTTP 403" >&2
exit 1
GHEOF
  chmod +x "$MOCK_BIN/gh"

  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/repository_dispatch_ci_failure.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "label-lookup-error" ]
}
