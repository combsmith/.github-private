#!/usr/bin/env bats
# Unit tests for dev-lead-intent.sh — CI / repository_dispatch routing (Phase 2)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
INTENT_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-intent.sh"
FIXTURES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/events"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  export BOT_USER="donpetry-bot"
  export TRUSTED_BOTS="copilot-pull-request-reviewer[bot],gemini-code-assist[bot],sonarqubecloud[bot],coderabbitai[bot]"
  export TRIGGER_PHRASES="@dev-lead"
  export GITHUB_REPOSITORY="petry-projects/.github-private"
  MOCK_BIN="$(mktemp -d)"
  export PATH="$MOCK_BIN:$PATH"
  # Stub gh so dispatch tests don't require an authenticated GitHub CLI.
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

_get_env() {
  local key="$1"
  # Handle multiline heredoc format: KEY<<DELIM\nvalue\nDELIM
  local delim_line delimiter
  delim_line=$(grep "^${key}<<" "$GITHUB_ENV" 2>/dev/null | head -1)
  if [ -n "$delim_line" ]; then
    delimiter="${delim_line#*<<}"
    awk -v start="${key}<<${delimiter}" -v end="${delimiter}" \
      'found && $0==end{exit} found{print} $0==start{found=1}' "$GITHUB_ENV"
    return
  fi
  grep "^${key}=" "$GITHUB_ENV" | cut -d= -f2- | head -1
}

_get_context_field() {
  local field="$1"
  local ctx
  ctx=$(_get_env INTENT_CONTEXT)
  echo "$ctx" | jq -r ".${field} // empty" 2>/dev/null || true
}

# ── repository_dispatch tests ────────────────────────────────────────────────

@test "ci: repository_dispatch dev-lead-ci-failure → fix-ci" {
  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/repository_dispatch_ci_failure.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "fix-ci" ]
}

@test "ci: context has pr_number from payload" {
  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/repository_dispatch_ci_failure.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_context_field pr_number)" = "42" ]
}

@test "ci: context has checks array" {
  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/repository_dispatch_ci_failure.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  local ctx
  ctx=$(_get_env INTENT_CONTEXT)
  # checks should be a non-empty JSON array
  result=$(echo "$ctx" | jq -r '.checks | length' 2>/dev/null || echo "0")
  [ "$result" -gt 0 ]
}

@test "ci: unknown repository_dispatch type → skip" {
  local tmp_event
  tmp_event=$(mktemp --suffix=.json)
  cat > "$tmp_event" <<'EOF'
{
  "action": "some-other-type",
  "client_payload": { "foo": "bar" }
}
EOF
  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$tmp_event"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  rm -f "$tmp_event"
}

@test "ci: repository_dispatch with no pr_number → skip" {
  local tmp_event
  tmp_event=$(mktemp --suffix=.json)
  cat > "$tmp_event" <<'EOF'
{
  "action": "dev-lead-ci-failure",
  "client_payload": {
    "head_sha": "abc123",
    "checks": []
  }
}
EOF
  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$tmp_event"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  rm -f "$tmp_event"
}

# ── pull_request_review tests ────────────────────────────────────────────────

@test "ci: pull_request review from copilot COMMENTED → fix-reviews" {
  export GITHUB_EVENT_NAME="pull_request_review"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_copilot_commented.json"
  export TRUSTED_BOTS="copilot-pull-request-reviewer[bot],gemini-code-assist[bot],sonarqubecloud[bot],coderabbitai[bot]"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "fix-reviews" ]
}

@test "ci: pull_request review from copilot APPROVED → enable-auto-merge" {
  export GITHUB_EVENT_NAME="pull_request_review"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_copilot_approved.json"
  export TRUSTED_BOTS="copilot-pull-request-reviewer[bot],gemini-code-assist[bot],sonarqubecloud[bot],coderabbitai[bot]"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "enable-auto-merge" ]
}

@test "ci: issues labeled dev-lead → issue" {
  export GITHUB_EVENT_NAME="issues"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issues_labeled_dev_lead.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "issue" ]
}

# ── dev-lead-reviews-retry dispatch tests ────────────────────────────────────

@test "ci: repository_dispatch dev-lead-reviews-retry fix-reviews → fix-reviews" {
  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/repository_dispatch_reviews_retry_fix_reviews.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "fix-reviews" ]
}

@test "ci: repository_dispatch dev-lead-reviews-retry on-mention → on-mention" {
  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/repository_dispatch_reviews_retry_human.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "on-mention" ]
}

@test "ci: repository_dispatch dev-lead-reviews-retry unknown intent → skip" {
  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/repository_dispatch_reviews_retry_unknown_intent.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
}

@test "ci: repository_dispatch dev-lead-reviews-retry: context has pr_number and head_sha" {
  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/repository_dispatch_reviews_retry_fix_reviews.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_context_field pr_number)" = "42" ]
  [ "$(_get_context_field head_sha)" = "abc123def456" ]
}

# ── repository_dispatch dev-lead-issue-retry (#781) ───────────────────────────

@test "ci: repository_dispatch dev-lead-issue-retry → issue (issue-only payload not dropped)" {
  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/repository_dispatch_issue_retry.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "issue" ]
  [ "$(_get_env INTENT_REASON)" = "issue-retry-dispatch" ]
  [ "$(_get_context_field issue_number)" = "478" ]
}

@test "ci: dev-lead-issue-retry with no issue_number → skip" {
  local tmp_event
  tmp_event=$(mktemp --suffix=.json)
  cat > "$tmp_event" <<'EOF'
{
  "action": "dev-lead-issue-retry",
  "client_payload": { "repo": "petry-projects/.github-private" }
}
EOF
  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$tmp_event"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  rm -f "$tmp_event"
}

@test "ci: dev-lead-issue-retry respects hands-off label on the issue" {
  # gh stub returns the hands-off label → must skip even for a valid payload.
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
# hands-off label lookup: repos/.../issues/<n>/labels
case "$*" in
  *labels*) echo "dev-lead:hands-off" ;;
  *) exit 0 ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"
  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/repository_dispatch_issue_retry.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "hands-off-label" ]
}
