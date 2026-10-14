#!/usr/bin/env bats
# Unit tests for dev-lead-intent.sh — review-related routing (Phase 3)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
INTENT_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-intent.sh"
FIXTURES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/events"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  export BOT_USER="donpetry-bot"
  export TRUSTED_BOTS="copilot-pull-request-reviewer[bot],gemini-code-assist[bot],sonarqubecloud[bot],coderabbitai[bot],chatgpt-codex-connector[bot]"
  export TRIGGER_PHRASES="@dev-lead"
  export GITHUB_REPOSITORY="combsmith/.github-private"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT"
}

_get_env() {
  local key="$1"
  grep "^${key}=" "$GITHUB_ENV" | cut -d= -f2- | head -1
}

# ── pull_request_review tests ────────────────────────────────────────────────

@test "reviews: pull_request_review copilot COMMENTED → fix-reviews" {
  export GITHUB_EVENT_NAME="pull_request_review"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_copilot_commented.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "fix-reviews" ]
}

@test "reviews: pull_request_review copilot APPROVED → enable-auto-merge" {
  export GITHUB_EVENT_NAME="pull_request_review"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_copilot_approved.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "enable-auto-merge" ]
}

@test "reviews: pull_request_review coderabbit APPROVED → enable-auto-merge" {
  export GITHUB_EVENT_NAME="pull_request_review"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_coderabbit_approved.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "enable-auto-merge" ]
}

@test "reviews: pull_request_review gemini CHANGES_REQUESTED → fix-reviews" {
  export GITHUB_EVENT_NAME="pull_request_review"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_gemini_changes.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "fix-reviews" ]
}

@test "reviews: pull_request_review human OWNER → review-changes" {
  export GITHUB_EVENT_NAME="pull_request_review"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_human_owner.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "review-changes" ]
}

@test "reviews: pull_request_review human NONE → skip" {
  local tmp_event
  tmp_event=$(mktemp --suffix=.json)
  cat > "$tmp_event" <<'EOF'
{
  "action": "submitted",
  "review": {
    "id": 999,
    "state": "CHANGES_REQUESTED",
    "body": "Please fix this.",
    "user": { "login": "external-user", "type": "User" }
  },
  "pull_request": {
    "number": 10,
    "author_association": "NONE",
    "head": { "sha": "abc", "repo": { "full_name": "combsmith/.github-private" } }
  },
  "repository": { "full_name": "combsmith/.github-private" },
  "sender": { "login": "external-user", "type": "User" }
}
EOF
  export GITHUB_EVENT_NAME="pull_request_review"
  export GITHUB_EVENT_PATH="$tmp_event"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  rm -f "$tmp_event"
}

@test "reviews: pull_request_review fork PR → skip" {
  export GITHUB_EVENT_NAME="pull_request_review"
  # Create a review event for a fork PR
  local tmp_event
  tmp_event=$(mktemp --suffix=.json)
  cat > "$tmp_event" <<'EOF'
{
  "action": "submitted",
  "review": {
    "id": 998,
    "state": "COMMENTED",
    "body": "Looks good.",
    "user": { "login": "copilot-pull-request-reviewer[bot]", "type": "Bot" }
  },
  "pull_request": {
    "number": 11,
    "author_association": "OWNER",
    "head": { "sha": "def", "repo": { "full_name": "fork-user/.github-private" } },
    "base": { "repo": { "full_name": "combsmith/.github-private" } }
  },
  "repository": { "full_name": "combsmith/.github-private" },
  "sender": { "login": "copilot-pull-request-reviewer[bot]", "type": "Bot" }
}
EOF
  export GITHUB_EVENT_PATH="$tmp_event"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  rm -f "$tmp_event"
}

@test "reviews: pull_request_review self-actor → skip" {
  local tmp_event
  tmp_event=$(mktemp --suffix=.json)
  cat > "$tmp_event" <<'EOF'
{
  "action": "submitted",
  "review": {
    "id": 997,
    "state": "APPROVED",
    "body": "Self-approval",
    "user": { "login": "donpetry-bot", "type": "Bot" }
  },
  "pull_request": {
    "number": 12,
    "author_association": "OWNER",
    "head": { "sha": "ghi", "repo": { "full_name": "combsmith/.github-private" } }
  },
  "repository": { "full_name": "combsmith/.github-private" },
  "sender": { "login": "donpetry-bot", "type": "Bot" }
}
EOF
  export GITHUB_EVENT_NAME="pull_request_review"
  export GITHUB_EVENT_PATH="$tmp_event"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  rm -f "$tmp_event"
}

@test "reviews: pull_request_review codex COMMENTED → fix-reviews" {
  export GITHUB_EVENT_NAME="pull_request_review"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_codex_commented.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "fix-reviews" ]
}

# ── pull_request_review_comment tests ────────────────────────────────────────

@test "reviews: pull_request_review_comment codex → fix-reviews" {
  export GITHUB_EVENT_NAME="pull_request_review_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_comment_codex.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "fix-reviews" ]
}

@test "reviews: pull_request_review_comment copilot → fix-reviews" {
  export GITHUB_EVENT_NAME="pull_request_review_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_comment_copilot.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "fix-reviews" ]
}

@test "reviews: pull_request_review_comment human + @dev-lead → on-mention" {
  export GITHUB_EVENT_NAME="pull_request_review_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_comment_human_trigger.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "on-mention" ]
}

@test "reviews: pull_request_review_comment human no trigger → skip" {
  export GITHUB_EVENT_NAME="pull_request_review_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_comment_human_no_trigger.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
}

# ── issue_comment tests ───────────────────────────────────────────────────────

@test "reviews: issue_comment sonarqube on PR → fix-bot-comment" {
  export GITHUB_EVENT_NAME="issue_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issue_comment_sonarqube.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "fix-bot-comment" ]
}

@test "reviews: issue_comment coderabbit on PR → fix-bot-comment" {
  export GITHUB_EVENT_NAME="issue_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issue_comment_coderabbit.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "fix-bot-comment" ]
}

@test "reviews: issue_comment human + @dev-lead → on-mention" {
  export GITHUB_EVENT_NAME="issue_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issue_comment_human_trigger.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "on-mention" ]
}

@test "reviews: issue_comment human no trigger → skip" {
  export GITHUB_EVENT_NAME="issue_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issue_comment_human_no_trigger.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
}

@test "reviews: issue_comment rebase sentinel → rebase" {
  export GITHUB_EVENT_NAME="issue_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issue_comment_rebase_sentinel.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "rebase" ]
}

@test "reviews: issue_comment trusted-bot on already-closed PR → skip pr-already-closed" {
  # Regression guard for issue #405: a SonarQube comment on a merged PR used to
  # trigger fix-bot-comment, which then crashed at checkout_pr_in_worktree because
  # the branch was deleted. The classifier must emit skip before that point.
  export GITHUB_EVENT_NAME="issue_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issue_comment_sonarqube_closed_pr.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "pr-already-closed" ]
}
