#!/usr/bin/env bats
# Issue #1874: pr-review announced an approval it never created. The approval
# WRITE (`gh pr review --approve`) can fail — or worse, return success while no
# review object is created (a fine-grained PAT can comment but cannot
# addPullRequestReview) — leaving the PR stranded at REVIEW_REQUIRED behind a
# comment that claims it was approved. scripts/post-pr-review.sh must:
#   AC2/AC5 — verify the review object landed and FAIL LOUD (non-zero, never
#             success) when the write errored OR returned success-with-no-object;
#   AC3     — never post the partial-evidence announcement unless the review exists.
# The approval is also bound to the reviewed commit: it is submitted with commit_id,
# the head is re-read before and after, and an approval that read-back finds off the
# live head is dismissed.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export POST_SCRIPT="$REPO_ROOT/scripts/post-pr-review.sh"

  export SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/1874"
  export PR_HEAD_SHA="$SHA"
  export BOT_USER="donpetry-bot"
  export DRY_RUN="false"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  export COMMENT_OUT="$TEST_DIR/posted_comment.txt"
  : > "$COMMENT_OUT"
  export POST_INPUT="$TEST_DIR/post_input.json"
  export DISMISS_OUT="$TEST_DIR/dismissals.log"
  : > "$DISMISS_OUT"
  export HEAD_READS="$TEST_DIR/head_reads"
  echo 0 > "$HEAD_READS"

  # gh stub controlled by env vars:
  #   REVIEW_APPROVE_RC     — exit code of the POST to the reviews API (default 0)
  #   REVIEW_APPROVE_STDERR — stderr text emitted by that call
  #   REVIEW_APPROVE_STDOUT — stdout override (gh api prints the error body here)
  #   POSTED_COMMIT_ID      — commit_id in the POST response (default: as requested)
  #   READBACK_REVIEWS      — JSON array returned by the reviews read-back API
  #   READBACK_RC           — exit code of the reviews read-back API (default 0)
  #   LIVE_HEADS            — space-separated head SHAs for successive PR reads; the
  #                           last repeats (default $SHA). "fail" makes a read fail.
  #   DISMISS_RC            — exit code of the dismissal call (default 0)
  cat > "$TEST_DIR/bin/gh" <<'GHEOF'
#!/bin/bash
args="$*"
if [ "$1" = "pr" ] && [ "$2" = "review" ]; then
  echo "unexpected call: an approval must go through the reviews API" >&2
  exit 99
fi
if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  prev=""
  for a in "$@"; do
    [ "$prev" = "--body" ] && printf '%s\n' "$a" >> "$COMMENT_OUT"
    prev="$a"
  done
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  if [[ "$args" == *"mergeStateStatus"* ]]; then echo "CLEAN"; exit 0; fi
  if [[ "$args" == *"comments"* ]]; then echo '{"comments":[]}'; exit 0; fi
  echo '{}'; exit 0
fi
if [ "$1" = "api" ]; then
  # The real CLI refuses this combination.
  if [[ "$args" == *"--slurp"* && "$args" == *"--jq"* ]]; then
    echo "the \`--slurp\` option is not supported with \`--jq\` or \`--template\`" >&2
    exit 1
  fi
  if [[ "$args" == *"-X POST"*"/reviews"* ]]; then
    cat > "$POST_INPUT"
    [ -n "${REVIEW_APPROVE_STDERR:-}" ] && printf '%s\n' "$REVIEW_APPROVE_STDERR" >&2
    if [ -n "${REVIEW_APPROVE_STDOUT:-}" ]; then
      printf '%s' "$REVIEW_APPROVE_STDOUT"
    else
      jq -c --arg c "${POSTED_COMMIT_ID:-}" \
        '{id: 4242, state: "APPROVED", commit_id: (if $c == "" then .commit_id else $c end)}' "$POST_INPUT"
    fi
    exit "${REVIEW_APPROVE_RC:-0}"
  fi
  if [[ "$args" == *"-X PUT"*"/dismissals"* ]]; then
    printf '%s\n' "$args" >> "$DISMISS_OUT"
    exit "${DISMISS_RC:-0}"
  fi
  if [[ "$args" =~ repos/[^/]+/[^/]+/pulls/[0-9]+\ --jq ]]; then
    read -r -a heads <<< "${LIVE_HEADS:-$SHA}"
    n=$(cat "$HEAD_READS"); echo $((n + 1)) > "$HEAD_READS"
    [ "$n" -ge "${#heads[@]}" ] && n=$((${#heads[@]} - 1))
    [ "${heads[$n]}" = "fail" ] && exit 1
    printf '%s\n' "${heads[$n]}"
    exit 0
  fi
  if [[ "$args" == *"/reviews"* ]]; then
    printf '%s' "${READBACK_REVIEWS:-[]}"
    exit "${READBACK_RC:-0}"
  fi
  if [[ "$args" == *"/comments"* ]]; then echo '[]'; exit 0; fi
  echo '{}'; exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "edit" ]; then exit 0; fi
exit 0
GHEOF
  chmod +x "$TEST_DIR/bin/gh"
  export PATH="$TEST_DIR/bin:$PATH"
}

teardown() { rm -rf "$TEST_DIR"; }

approve_verdict() {
  # The body must carry a complete approval marker for PR_HEAD_SHA ($SHA) or the
  # #1754 AC4 fail-closed guard rejects it before the #1874 read-back logic under
  # test can run (sha= and decision=approved together in one marker).
  local f="$TEST_DIR/verdict.json"
  jq -n --arg sha "$SHA" \
    '{decision:"approve", risk:"LOW", summary:"clean",
      body:("LGTM\n\n<!-- pr-review-agent v1 sha=" + $sha + " decision=approved risk=LOW -->")}' > "$f"
  echo "$f"
}

# ── AC2/AC5: a failed write is loud ─────────────────────────────────────────

@test "approve write errors (Resource not accessible) → run fails, names PR/account/credential" {
  export REVIEW_APPROVE_RC=1
  export REVIEW_APPROVE_STDERR="Resource not accessible by personal access token"
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  [[ "$output" == *"$PR_URL"* ]]
  [[ "$output" == *"donpetry-bot"* ]]
  [[ "$output" == *"Resource not accessible"* ]]
}

@test "approve write returns success but NO review object → run fails loudly (#1874 core)" {
  export REVIEW_APPROVE_RC=0
  export READBACK_REVIEWS='[{"user":{"login":"coderabbitai"},"state":"COMMENTED","commit_id":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}]'
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  [[ "$output" == *"$PR_URL"* ]]
  [[ "$output" == *"donpetry-bot"* ]]
}

@test "approve write succeeds AND review object present → exit 0" {
  export REVIEW_APPROVE_RC=0
  export READBACK_REVIEWS='[{"user":{"login":"donpetry-bot"},"state":"APPROVED","commit_id":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}]'
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
}

@test "self-approval error still exits 100 (unchanged, not a #1874 failure)" {
  export REVIEW_APPROVE_RC=1
  export REVIEW_APPROVE_STDERR="GraphQL: Can not approve your own pull request (addPullRequestReview)"
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 100 ]
}

@test "read-back API unreachable (indeterminate) → warn and proceed, fail OPEN (#1776 spirit)" {
  export REVIEW_APPROVE_RC=0
  export READBACK_RC=1
  export READBACK_REVIEWS=""
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
}

# ── AC3: announcement never posted unless the review exists ──────────────────

@test "partial-evidence marker is posted AFTER a verified approval" {
  export REVIEW_APPROVE_RC=0
  export READBACK_REVIEWS='[{"user":{"login":"donpetry-bot"},"state":"APPROVED","commit_id":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}]'
  export PARTIAL_EVIDENCE_STATE_FILE="$TEST_DIR/partial-evidence.state"
  printf '%s %s %s\n' 4 6 "head-age-timeout" > "$PARTIAL_EVIDENCE_STATE_FILE"
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  cat "$COMMENT_OUT" >&2
  [ "$status" -eq 0 ]
  grep -q "pr-review-agent partial-evidence v1 sha=$SHA" "$COMMENT_OUT"
  grep -q "submitted=4 required=6 reason=head-age-timeout" "$COMMENT_OUT"
}

@test "partial-evidence marker is NOT posted when the approval write fails to land" {
  export REVIEW_APPROVE_RC=0
  export READBACK_REVIEWS='[{"user":{"login":"coderabbitai"},"state":"COMMENTED","commit_id":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}]'
  export PARTIAL_EVIDENCE_STATE_FILE="$TEST_DIR/partial-evidence.state"
  printf '%s %s %s\n' 4 6 "head-age-timeout" > "$PARTIAL_EVIDENCE_STATE_FILE"
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  run grep -q "partial-evidence" "$COMMENT_OUT"
  [ "$status" -eq 1 ]
}

# ── #1875: an INDETERMINATE read-back must NOT announce partial-evidence ──────

@test "indeterminate read-back does NOT post deferred partial-evidence and retains state" {
  export REVIEW_APPROVE_RC=0
  export READBACK_RC=1
  export READBACK_REVIEWS=""
  export PARTIAL_EVIDENCE_STATE_FILE="$TEST_DIR/partial-evidence.state"
  printf '%s %s %s\n' 4 6 "head-age-timeout" > "$PARTIAL_EVIDENCE_STATE_FILE"
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  # No announcement was posted, and the deferred state survives for a later sweep.
  run grep -q "partial-evidence" "$COMMENT_OUT"
  [ "$status" -eq 1 ]
  [ -s "$PARTIAL_EVIDENCE_STATE_FILE" ]
}

# ── Approval bound to the reviewed commit ─────────────────────────────────────

export_landed_review() {
  export READBACK_REVIEWS='[{"user":{"login":"donpetry-bot"},"state":"APPROVED","commit_id":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}]'
}
OTHER_SHA="1111111111111111111111111111111111111111"

@test "approval is submitted through the reviews API with commit_id set to the reviewed commit" {
  export_landed_review
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [ "$(jq -r '.event' "$POST_INPUT")" = "APPROVE" ]
  [ "$(jq -r '.commit_id' "$POST_INPUT")" = "$SHA" ]
  [ "$(jq -r '.body' "$POST_INPUT")" = "$(jq -r '.body' "$vf")" ]
  [ ! -s "$DISMISS_OUT" ]
}

@test "a body starting with @ reaches the API verbatim and is not read as a file" {
  export_landed_review
  local vf="$TEST_DIR/verdict.json"
  jq -n --arg sha "$SHA" \
    '{decision:"approve", risk:"LOW", body:("@/etc/passwd\n\n<!-- pr-review-agent v1 sha=" + $sha + " decision=approved risk=LOW -->")}' > "$vf"
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.body' "$POST_INPUT")" == "@/etc/passwd"* ]]
}

@test "head already moved before posting → no approval submitted, exit 100" {
  export LIVE_HEADS="$OTHER_SHA"
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 100 ]
  [ ! -e "$POST_INPUT" ]
  [[ "$output" == *"$OTHER_SHA"* ]]
}

@test "head unreadable before posting → no approval submitted, fails closed" {
  export LIVE_HEADS="fail"
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  [ ! -e "$POST_INPUT" ]
}

@test "head moves as the approval lands → the approval is dismissed by id, exit 100" {
  export LIVE_HEADS="$SHA $OTHER_SHA"
  export_landed_review
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 100 ]
  grep -q "reviews/4242/dismissals" "$DISMISS_OUT"
  [[ "$output" != *"Review posted"* ]]
}

@test "partial-evidence marker is NOT posted when the head moved as the approval landed" {
  export LIVE_HEADS="$SHA $OTHER_SHA"
  export_landed_review
  export PARTIAL_EVIDENCE_STATE_FILE="$TEST_DIR/partial-evidence.state"
  printf '%s %s %s\n' 4 6 "head-age-timeout" > "$PARTIAL_EVIDENCE_STATE_FILE"
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  [ "$status" -eq 100 ]
  run grep -q "partial-evidence" "$COMMENT_OUT"
  [ "$status" -eq 1 ]
}

@test "API attaches the approval to another commit → dismissed, run fails" {
  export POSTED_COMMIT_ID="$OTHER_SHA"
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  grep -q "reviews/4242/dismissals" "$DISMISS_OUT"
}

@test "read-back finds no approval at the head → the posted review is dismissed, run fails" {
  export READBACK_REVIEWS='[{"user":{"login":"donpetry-bot"},"state":"APPROVED","commit_id":"1111111111111111111111111111111111111111"}]'
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  grep -q "reviews/4242/dismissals" "$DISMISS_OUT"
}

@test "a dismissal that fails is loud: non-zero, names the review" {
  export LIVE_HEADS="$SHA $OTHER_SHA"
  export DISMISS_RC=1
  export_landed_review
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  [[ "$output" == *"4242"* ]]
}

@test "write refused because the head moved → exit 100, not a stranded-approval error" {
  export LIVE_HEADS="$SHA $OTHER_SHA"
  export REVIEW_APPROVE_RC=1
  export REVIEW_APPROVE_STDERR="gh: Validation Failed (HTTP 422)"
  export REVIEW_APPROVE_STDOUT='{"message":"Validation Failed"}'
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 100 ]
  [[ "$output" != *"WRITE FAILED"* ]]
}

@test "self-approval reason found in the error body on stdout → exit 100" {
  export REVIEW_APPROVE_RC=1
  export REVIEW_APPROVE_STDERR="gh: Unprocessable Entity (HTTP 422)"
  export REVIEW_APPROVE_STDOUT='{"message":"Unprocessable Entity","errors":["Can not approve your own pull request"]}'
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 100 ]
}
