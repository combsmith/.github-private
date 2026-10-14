#!/usr/bin/env bats
# Unit tests for dev-lead-intent.sh — PR-authorship gate (#1311).
#
# dev-lead's fix/push/merge intents (review-changes, fix-reviews,
# fix-bot-comment, enable-auto-merge) must only fire on PRs dev-lead AUTHORED —
# a `dev-lead/issue-*` head branch OR a PR/issue author == BOT_USER. A review or
# bot comment on a human-authored PR must emit `skip not-dev-lead-authored` and
# leave the PR to the human (the #1303 incident: dev-lead drove a human PR to
# merge and dropped a commit). Authorship that cannot be determined FAILS CLOSED
# (skip), never acts.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
INTENT_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-intent.sh"
FIXTURES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/events"

setup() {
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  export BOT_USER="donpetry-bot"
  export TRUSTED_BOTS="copilot-pull-request-reviewer[bot],gemini-code-assist[bot],sonarqubecloud[bot],coderabbitai[bot],chatgpt-codex-connector[bot]"
  export TRIGGER_PHRASES="@dev-lead"
  export GITHUB_REPOSITORY="petry-projects/.github-private"
}

_get_env() {
  local key="$1"
  grep "^${key}=" "$GITHUB_ENV" | cut -d= -f2- | head -n 1 || true
}

# ── human-authored PRs must be left untouched ────────────────────────────────

@test "authorship: bot review on human-authored PR → skip not-dev-lead-authored" {
  export GITHUB_EVENT_NAME="pull_request_review"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_bot_human_authored.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "not-dev-lead-authored" ]
}

@test "authorship: bot review comment on human-authored PR → skip not-dev-lead-authored" {
  export GITHUB_EVENT_NAME="pull_request_review_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_comment_bot_human_authored.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "not-dev-lead-authored" ]
}

@test "authorship: bot issue comment on human-authored PR → skip not-dev-lead-authored" {
  export GITHUB_EVENT_NAME="issue_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issue_comment_bot_human_authored.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "not-dev-lead-authored" ]
}

@test "authorship: pull_request opened by human → skip not-dev-lead-authored" {
  export GITHUB_EVENT_NAME="pull_request"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_opened_human.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "not-dev-lead-authored" ]
}

# ── fail closed: indeterminate authorship must skip ──────────────────────────

@test "authorship: indeterminate author (no branch, no author) → skip not-dev-lead-authored" {
  export GITHUB_EVENT_NAME="pull_request_review"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_indeterminate_author.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "not-dev-lead-authored" ]
}

# ── dev-lead-authored PRs still route to the fix/push paths ──────────────────

@test "authorship: bot review on dev-lead-authored PR (dev-lead/issue-* branch) → fix-reviews" {
  export GITHUB_EVENT_NAME="pull_request_review"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_bot_dev_lead_authored.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "fix-reviews" ]
}

@test "authorship: pull_request opened by dev-lead (dev-lead/issue-* branch) → review-changes" {
  export GITHUB_EVENT_NAME="pull_request"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_opened_dev_lead.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "review-changes" ]
}

# ── on-mention (explicit human @dev-lead) stays advisory-exempt on any PR ─────

@test "authorship: human @dev-lead comment on human PR still routes on-mention" {
  # The authorship gate must not swallow an explicit human request. issue_comment
  # human_trigger fixture is a human-authored PR; @dev-lead is direct authorization.
  export GITHUB_EVENT_NAME="issue_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issue_comment_human_trigger.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "on-mention" ]
}
