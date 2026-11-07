#!/usr/bin/env bats
# scripts/repair-pr-approvals.sh approves through the reviews API, bound to the
# commit its approval marker names, and only while that commit is the head.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export TEST_DIR="$BATS_TEST_TMPDIR"
  export SCRIPT="$REPO_ROOT/scripts/repair-pr-approvals.sh"
  export SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  export HEAD_SHA="$SHA" POST_INPUT="$TEST_DIR/post.json" CALLS="$TEST_DIR/calls"
  : > "$CALLS"
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >> "$CALLS"
case "$args" in
  "repo list combsmith"*) echo "combsmith/example" ;;
  "repo list"*) ;;
  "pr list"*) echo '[{"url":"https://github.com/combsmith/example/pull/7","number":7,"comments":[{"body":"x"}]}]' ;;
  *"--json comments"*) printf '%s\n' "<!-- pr-review-agent v1 sha=$SHA decision=approved risk=LOW -->" ;;
  *"--json reviews"*) echo 0 ;;
  *"--json headRefOid"*) echo "$HEAD_SHA" ;;
  *"--json autoMerge"*) echo true ;;
  *"-X POST repos/combsmith/example/pulls/7/reviews"*) cat > "$POST_INPUT" ;;
  "pr review"*) echo "unexpected: approval must use the reviews API" >&2; exit 99 ;;
esac
exit 0
STUB
  chmod +x "$TEST_DIR/bin/gh"
  export PATH="$TEST_DIR/bin:$PATH" TARGET_ORG=combsmith BOT_USER=somebot
}

@test "approves with commit_id when the marker's commit is the head" {
  run bash "$SCRIPT" false
  echo "$output" >&2
  [ "$(jq -r .event "$POST_INPUT")" = "APPROVE" ]
  [ "$(jq -r .commit_id "$POST_INPUT")" = "$SHA" ]
}

@test "does not approve when the head has moved past the marker's commit" {
  export HEAD_SHA="1111111111111111111111111111111111111111"
  run bash "$SCRIPT" false
  echo "$output" >&2
  [ ! -e "$POST_INPUT" ]
  [[ "$output" == *"not for the current head"* ]]
}
