#!/usr/bin/env bats
# Unit tests for dev-lead-intent.sh — issue routing (Phase 5)

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
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT"
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

# ── issue tests ───────────────────────────────────────────────────────────────

@test "issue: issues labeled dev-lead → issue" {
  export GITHUB_EVENT_NAME="issues"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issues_labeled_dev_lead.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "issue" ]
}

@test "issue: issues labeled claude → skip (legacy label retired)" {
  # The `claude` label was retired in favour of `dev-lead`; it no longer
  # triggers the issue intent.
  export GITHUB_EVENT_NAME="issues"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issues_labeled_claude.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
}

@test "issue: issues labeled bug → skip" {
  export GITHUB_EVENT_NAME="issues"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issues_labeled_other.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
}

@test "issue: issues labeled dev-lead without body → issue with empty context" {
  local tmp_event
  tmp_event=$(mktemp --suffix=.json)
  cat > "$tmp_event" <<'EOF'
{
  "action": "labeled",
  "issue": {
    "number": 200,
    "title": "New feature request",
    "body": null,
    "state": "open",
    "author_association": "OWNER",
    "labels": [{ "name": "dev-lead" }]
  },
  "label": { "name": "dev-lead" },
  "repository": { "full_name": "petry-projects/.github-private" },
  "sender": { "login": "donpetry", "type": "User" }
}
EOF
  export GITHUB_EVENT_NAME="issues"
  export GITHUB_EVENT_PATH="$tmp_event"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "issue" ]
  # issue_number should be set in context
  [ "$(_get_context_field issue_number)" = "200" ]
  rm -f "$tmp_event"
}
