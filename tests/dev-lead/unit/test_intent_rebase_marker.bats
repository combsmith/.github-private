#!/usr/bin/env bats
# Unit tests for dev-lead-intent.sh — routing of the auto-rebase sentinel comment.
# The sentinel routes to `rebase` only from dev-lead's own identity or a trusted
# author association, and only when the PR's head is confirmed to be in this
# repository.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
INTENT_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-intent.sh"
FIXTURE="$SCRIPT_DIR/tests/dev-lead/fixtures/events/issue_comment_rebase_marker_member.json"

setup() {
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  export GITHUB_EVENT_NAME="issue_comment"
  export GITHUB_REPOSITORY="combsmith/.github-private"
  export BOT_USER="don-petry"
  export TRUSTED_BOTS="coderabbitai[bot]"
  export TRIGGER_PHRASES="@dev-lead"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : > "$GH_LOG"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  "pr view 65 --repo combsmith/.github-private --json isCrossRepository --jq .isCrossRepository")
    [ "${GH_STUB_FAIL:-0}" = "1" ] && exit 1
    echo "${GH_STUB_CROSS-false}" ;;
  *) exit 1 ;;
esac
GHEOF
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

_get_env() {
  grep "^$1=" "$GITHUB_ENV" | cut -d= -f2- | head -n 1 || true
}

# _event <login> <association> [body]: the member fixture with this comment author.
_event() {
  export GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/event.json"
  jq --arg l "$1" --arg a "$2" --arg b "${3:-}" '
    .comment.user.login = $l | .comment.author_association = $a | .sender.login = $l
    | if $b != "" then .comment.body = $b else . end' "$FIXTURE" > "$GITHUB_EVENT_PATH"
}

@test "rebase marker: dev-lead's own identity routes to rebase" {
  _event "don-petry" "NONE"
  run bash "$INTENT_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "rebase" ]
  [ "$(_get_env INTENT_REASON)" = "rebase-conflict-sentinel" ]
}

@test "rebase marker: each trusted association routes to rebase" {
  local assoc
  for assoc in OWNER MEMBER COLLABORATOR; do
    : > "$GITHUB_ENV"
    _event "human-maintainer" "$assoc"
    run bash "$INTENT_SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(_get_env INTENT_TYPE)" = "rebase" ]
  done
}

@test "rebase marker: any other association is not routed to rebase and reads no PR state" {
  local assoc
  for assoc in NONE FIRST_TIMER FIRST_TIME_CONTRIBUTOR CONTRIBUTOR MANNEQUIN ""; do
    : > "$GITHUB_ENV"
    _event "someone-else" "$assoc"
    run bash "$INTENT_SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(_get_env INTENT_TYPE)" = "skip" ]
    [ "$(_get_env INTENT_REASON)" = "no-trigger-or-untrusted" ]
  done
  [ ! -s "$GH_LOG" ]
}

@test "rebase marker: a missing author association is not routed to rebase" {
  export GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/event.json"
  jq 'del(.comment.author_association)' "$FIXTURE" > "$GITHUB_EVENT_PATH"
  run bash "$INTENT_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
}

@test "rebase marker: a login that only resembles dev-lead's identity is not routed to rebase" {
  _event "don-petry-2" "NONE"
  run bash "$INTENT_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
}

@test "rebase marker: a trusted review bot quoting the marker gets ordinary bot routing" {
  _event "coderabbitai[bot]" "NONE"
  run bash "$INTENT_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" != "rebase" ]
}

@test "rebase marker: an authorized commenter on a cross-repository PR → skip fork-pr" {
  _event "human-maintainer" "MEMBER"
  export GH_STUB_CROSS=true
  run bash "$INTENT_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "fork-pr" ]
}

@test "rebase marker: dev-lead's own identity on a cross-repository PR → skip fork-pr" {
  _event "don-petry" "MEMBER"
  export GH_STUB_CROSS=true
  run bash "$INTENT_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_REASON)" = "fork-pr" ]
}

@test "rebase marker: a failed head lookup fails closed" {
  _event "human-maintainer" "MEMBER"
  export GH_STUB_FAIL=1
  run bash "$INTENT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not confirm"* ]]
  [ "$(_get_env INTENT_TYPE)" = "" ]
}

@test "rebase marker: an empty head answer fails closed" {
  _event "human-maintainer" "MEMBER"
  export GH_STUB_CROSS=""
  run bash "$INTENT_SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(_get_env INTENT_TYPE)" = "" ]
}

@test "review comment on a cross-repository PR → skip fork-pr, even on a dev-lead branch name" {
  export GITHUB_EVENT_NAME="pull_request_review_comment"
  export GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/event.json"
  jq -n '{action:"created",
    comment:{user:{login:"coderabbitai[bot]"},body:"finding",author_association:"NONE"},
    pull_request:{number:65,user:{login:"someone-else"},
      head:{sha:"abc",ref:"dev-lead/issue-1",repo:{full_name:"someone-else/.github-private"}}},
    repository:{full_name:"combsmith/.github-private"}}' > "$GITHUB_EVENT_PATH"
  run bash "$INTENT_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "fork-pr" ]
}
