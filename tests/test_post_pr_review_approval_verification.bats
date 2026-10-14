#!/usr/bin/env bats
# Issue #1874: pr-review announced an approval it never created. The approval
# WRITE (`gh pr review --approve`) can fail — or worse, return success while no
# review object is created (a fine-grained PAT can comment but cannot
# addPullRequestReview) — leaving the PR stranded at REVIEW_REQUIRED behind a
# comment that claims it was approved. scripts/post-pr-review.sh must:
#   AC2/AC5 — verify the review object landed and FAIL LOUD (non-zero, never
#             success) when the write errored OR returned success-with-no-object;
#   AC3     — never post the partial-evidence announcement unless the review exists.

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

  # gh stub controlled by env vars:
  #   REVIEW_APPROVE_RC     — exit code of `gh pr review --approve` (default 0)
  #   REVIEW_APPROVE_STDERR — stderr text emitted by the approve call
  #   READBACK_REVIEWS      — JSON array returned by the reviews read-back API
  #   READBACK_RC           — exit code of the reviews read-back API (default 0)
  cat > "$TEST_DIR/bin/gh" <<'GHEOF'
#!/bin/bash
args="$*"
if [ "$1" = "pr" ] && [ "$2" = "review" ]; then
  [ -n "${REVIEW_APPROVE_STDERR:-}" ] && printf '%s\n' "$REVIEW_APPROVE_STDERR" >&2
  exit "${REVIEW_APPROVE_RC:-0}"
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
