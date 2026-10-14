#!/usr/bin/env bats
# Unit tests for dev-lead-intent.sh — the shared "human hold" guard (#1595).
#
# A PR or issue carrying a fleet hold label (needs-human-review, dev-lead:needs-
# human, dev-lead:hands-off) is excluded from the agent regardless of the event
# that would otherwise route it. This is the label-triggered half of the fix:
# even if the initiative driver is bypassed and `dev-lead` is applied to a held
# issue, the agent must not pick it up. The hands-off case keeps its existing
# `hands-off-label` skip reason (see test_intent_hands_off.bats); the other hold
# labels skip with a `hold-label:<label>` reason.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
INTENT_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-intent.sh"
FIXTURES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/events"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  export BOT_USER="donpetry-bot"
  export TRUSTED_BOTS="copilot-pull-request-reviewer[bot],gemini-code-assist[bot]"
  export TRIGGER_PHRASES="@dev-lead"
  export GITHUB_REPOSITORY="petry-projects/.github-private"
  # $BATS_TEST_TMPDIR is per-test and auto-removed on teardown/failure — no
  # manual mktemp -d / rm -rf, which is safer under parallel execution.
  MOCK_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT"
}

_get_env() {
  local key="$1"
  local val
  # No `head -1`: under set -o pipefail a closed pipe would SIGPIPE (141). Grab
  # the value (grep guarded with `|| true` for the no-match case) and take the
  # first line via parameter expansion instead.
  val="$(grep "^${key}=" "$GITHUB_ENV" | cut -d= -f2- || true)"
  printf '%s\n' "${val%%$'\n'*}"
}

@test "hold: issue labeled dev-lead while needs-human-review present → skip (the #1532 case)" {
  export GITHUB_EVENT_NAME="issues"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issues_labeled_dev_lead_needs_human_review.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "hold-label:needs-human-review" ]
}

@test "hold: repository_dispatch ci-failure for a needs-human-review PR → skip" {
  cat > "$MOCK_BIN/gh" << 'GHEOF'
#!/usr/bin/env bash
echo "needs-human-review"
GHEOF
  chmod +x "$MOCK_BIN/gh"

  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/repository_dispatch_ci_failure.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "hold-label:needs-human-review" ]
}

# ── #1767: the hold skip must carry enough context for the workflow to post the
# one-time "held" notice — the specific blocking label and the subject number.

_get_ctx_field() {
  # Extract a field from the INTENT_CONTEXT heredoc block in $GITHUB_OUTPUT.
  local field="$1"
  local ctx
  ctx="$(grep -A2 '^intent_context<<' "$GITHUB_OUTPUT" | sed -n '2p' || true)"
  printf '%s' "$ctx" | jq -r --arg f "$field" '.[$f] // ""'
}

@test "hold: labeled-issue skip carries hold_label + subject_number in context (#1767)" {
  export GITHUB_EVENT_NAME="issues"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issues_labeled_dev_lead_needs_human_review.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_ctx_field hold_label)" = "needs-human-review" ]
  [ "$(_get_ctx_field subject_number)" = "1532" ]
}

@test "hold: repository_dispatch skip carries hold_label + subject_number in context (#1767)" {
  cat > "$MOCK_BIN/gh" << 'GHEOF'
#!/usr/bin/env bash
echo "needs-human-review"
GHEOF
  chmod +x "$MOCK_BIN/gh"

  export GITHUB_EVENT_NAME="repository_dispatch"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/repository_dispatch_ci_failure.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_ctx_field hold_label)" = "needs-human-review" ]
  [ "$(_get_ctx_field subject_number)" = "42" ]
}
