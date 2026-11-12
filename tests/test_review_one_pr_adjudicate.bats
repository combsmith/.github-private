#!/usr/bin/env bats
# Issue #2495 — tier 4 "adjudicate" on the review-cycle cap path of
# scripts/review-one-pr.sh, driven end to end with a stub `claude` CLI that writes
# the adjudication JSON to $OUTPUT_FILE (the only place it is read from).
#
#   - PR_REVIEW_ADJUDICATE unset: the cap escalates to a human exactly as before.
#   - Fable approve: the approval is posted (exit 0), no human escalation.
#   - Fable escalate: today's human escalation, with the tier-4 note (exit 101).
#   - Fable invalid JSON / rate limit / error: human escalation, never an approval.
#   - Tier 4 already ran since the last reset: straight to a human, no model call.
#   - DRY_RUN (and so diagnose mode): no model call.
#
# Run with: bats tests/test_review_one_pr_adjudicate.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"
  export FIXED_SHA="d53a7fc6b0718dd3d672fed4eec8394e5d372900"
  export PR_URL="https://github.com/combsmith/.github-private/pull/1703"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  cd "$REPO_ROOT"
  export SNAPSHOT="$TEST_DIR/snapshot.json"
  export GH_LOG="$TEST_DIR/gh_calls.log"; : > "$GH_LOG"
  export POSTED_REVIEW="$TEST_DIR/posted_review.json"; : > "$POSTED_REVIEW"
  export POSTED_COMMENTS="$TEST_DIR/posted_comments.txt"; : > "$POSTED_COMMENTS"
  export CLAUDE_CALLS="$TEST_DIR/claude_calls.log"; : > "$CLAUDE_CALLS"
  write_snapshot '[]'

  # gh stub: clears every approval gate, serves the snapshot, records writes, and
  # answers the approval read-back so post-pr-review.sh can confirm the review.
  cat > "$TEST_DIR/bin/gh" <<'GHEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  case "$*" in
    *reviewThreads*) printf '%s' '{"data":{"resource":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' ;;
    *pushedDate*)    printf '%s' '{"data":{"resource":{"commits":{"nodes":[{"commit":{"pushedDate":"2020-01-01T00:00:00Z","committer":{"date":"2020-01-01T00:00:00Z"}}}]}}}}' ;;
    *)               printf '%s\n' '2020-01-01T00:00:00Z' ;;
  esac
  exit 0
fi
if [ "$1" = "api" ]; then
  method=GET; path=""; prev=""
  for a in "$@"; do
    [ "$prev" = "-X" ] && method="$a"
    case "$a" in repos/*) path="$a" ;; esac
    prev="$a"
  done
  case "$path" in
    */pulls/*/reviews)
      if [ "$method" = "POST" ]; then
        cat > "$POSTED_REVIEW"
        printf '{"id":1,"state":"APPROVED","commit_id":"%s"}' "$FIXED_SHA"
      else
        printf '[[{"id":1,"state":"APPROVED","user":{"login":"%s"},"commit_id":"%s","submitted_at":"2026-11-12T00:00:00Z","body":""}]]' "${BOT_USER:-donpetry-bot}" "$FIXED_SHA"
      fi
      exit 0 ;;
    */pulls/[0-9]*/*) printf '[]'; exit 0 ;;
    */pulls/[0-9]*) printf '%s\n' "$FIXED_SHA"; exit 0 ;;
    */issues/*) printf '[]'; exit 0 ;;
  esac
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
  printf 'diff --git a/x b/x\n+changed line\n'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  prev=""
  for a in "$@"; do
    case "$prev" in
      --body) printf '%s\n----\n' "$a" >> "$POSTED_COMMENTS" ;;
      --body-file) cat "$a" >> "$POSTED_COMMENTS"; printf '\n----\n' >> "$POSTED_COMMENTS" ;;
    esac
    prev="$a"
  done
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  jqf=""; prev=""
  for a in "$@"; do
    [ "$prev" = "--jq" ] && jqf="$a"
    prev="$a"
  done
  if [ -n "$jqf" ]; then jq -r "$jqf" "$SNAPSHOT"; else cat "$SNAPSHOT"; fi
  exit 0
fi
exit 0
GHEOF
  chmod +x "$TEST_DIR/bin/gh"

  # claude stub: records the call and acts on $CLAUDE_MODE. The verdict goes ONLY
  # to $OUTPUT_FILE; stdout carries a decoy "approve" that must never be parsed.
  cat > "$TEST_DIR/bin/claude" <<'CEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CLAUDE_CALLS"
case "${CLAUDE_MODE:-approve}" in
  approve|escalate|request_changes)
    printf '{"decision":"%s","risk":"LOW","summary":"fable says %s","findings":[]}' "$CLAUDE_MODE" "$CLAUDE_MODE" > "$OUTPUT_FILE" ;;
  badjson) printf 'decision: approve' > "$OUTPUT_FILE" ;;
  ratelimit) echo "Claude AI usage limit reached|1767225600"; exit 1 ;;
  error) echo "internal failure" >&2; exit 1 ;;
esac
echo '{"type":"result","subtype":"success","is_error":false,"result":"decision approve","usage":{"input_tokens":1,"output_tokens":1}}'
CEOF
  chmod +x "$TEST_DIR/bin/claude"
  export PATH="$TEST_DIR/bin:$PATH"

  export REVIEW_ENGINE="claude"
  export GH_TOKEN="fake-token"
  export BOT_USER="donpetry-bot"
  export DRY_RUN="false"
  export LABEL_RETRY_DELAY=0 MQ_READ_ATTEMPTS=1 MQ_READ_RETRY_DELAY_SEC=0
  # A cap of 0 makes the cycle cap fire on the first pass (REVIEW_CYCLE 0 >= 0).
  export MAX_REVIEW_CYCLES=0
  unset FORCE_REVIEW PR_REVIEW_ADJUDICATE CLAUDE_MODE
}

write_snapshot() { # <comments-json>
  cat > "$SNAPSHOT" <<EOF
{
  "headRefOid": "$FIXED_SHA",
  "baseRefName": "main",
  "statusCheckRollup": [
    { "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS" }
  ],
  "reviewDecision": "",
  "reviews": [],
  "labels": [],
  "comments": $1
}
EOF
}

@test "flag off: the cap escalates to a human with no tier-4 call (unchanged)" {
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2
  [ "$status" -eq 101 ]
  [[ "$output" == *"max-cycles-reached"* ]]
  [ ! -s "$CLAUDE_CALLS" ]
  grep -q 'needs-human-review' "$GH_LOG"
}

@test "Fable approve at the cap posts the approval and does not escalate" {
  export PR_REVIEW_ADJUDICATE=true CLAUDE_MODE=approve
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2; cat "$POSTED_REVIEW" >&2
  [ "$status" -eq 0 ]
  [ -s "$CLAUDE_CALLS" ]
  grep -q 'claude-fable-5-2' "$CLAUDE_CALLS"
  [[ "$output" == *"[tier4] adjudicate"* ]]
  [[ "$output" == *"decision=approve"* ]]
  [[ "$output" == *"overrode=true"* ]]
  jq -r .body "$POSTED_REVIEW" | grep -q "decision=approved"
  jq -r .body "$POSTED_REVIEW" | grep -q "pr-review-agent adjudicate v1 sha=$FIXED_SHA trigger=max-cycles outcome=ok decision=approve overrode=true"
  ! grep -q -- '--add-label needs-human-review' "$GH_LOG" || false
}

@test "Fable request_changes at the cap posts a fix-request, not an escalation" {
  export PR_REVIEW_ADJUDICATE=true CLAUDE_MODE=request_changes
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2; cat "$POSTED_COMMENTS" >&2
  [ "$status" -eq 0 ]
  grep -q 'decision=fix-requested' "$POSTED_COMMENTS"
  grep -q 'decision=request_changes overrode=true' "$POSTED_COMMENTS"
  ! grep -q -- '--add-label needs-human-review' "$GH_LOG" || false
}

@test "Fable escalate at the cap goes to a human with the tier-4 note" {
  export PR_REVIEW_ADJUDICATE=true CLAUDE_MODE=escalate
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2; cat "$POSTED_COMMENTS" >&2
  [ "$status" -eq 101 ]
  grep -q '<!-- pr-review-agent escalation -->' "$POSTED_COMMENTS"
  grep -q 'Tier 4 (adjudicate)' "$POSTED_COMMENTS"
  grep -q 'decision=escalate overrode=false' "$POSTED_COMMENTS"
  grep -q 'needs-human-review' "$GH_LOG"
  [ ! -s "$POSTED_REVIEW" ]
}

@test "invalid JSON from Fable falls back to human escalation, never an approval" {
  export PR_REVIEW_ADJUDICATE=true CLAUDE_MODE=badjson
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2
  [ "$status" -eq 101 ]
  grep -q 'outcome=invalid-json' "$POSTED_COMMENTS"
  [ ! -s "$POSTED_REVIEW" ]
}

@test "a Fable rate limit falls back to human escalation (not engine fallback exit 2)" {
  export PR_REVIEW_ADJUDICATE=true CLAUDE_MODE=ratelimit
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2
  [ "$status" -eq 101 ]
  grep -q 'outcome=rate-limited' "$POSTED_COMMENTS"
  [ ! -s "$POSTED_REVIEW" ]
}

@test "a Fable error falls back to human escalation" {
  export PR_REVIEW_ADJUDICATE=true CLAUDE_MODE=error
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2
  [ "$status" -eq 101 ]
  grep -q 'outcome=error' "$POSTED_COMMENTS"
  [ ! -s "$POSTED_REVIEW" ]
}

@test "tier 4 never re-runs itself: an adjudication since the last reset goes straight to a human" {
  export PR_REVIEW_ADJUDICATE=true CLAUDE_MODE=approve
  write_snapshot '[{"author":{"login":"donpetry-bot"},"createdAt":"2026-11-10T00:00:00Z","body":"<!-- pr-review-agent v1 sha=1111111111111111111111111111111111111111 --> <!-- decision=fix-requested risk=LOW --> <!-- pr-review-agent adjudicate v1 sha=1111111111111111111111111111111111111111 trigger=max-cycles outcome=ok decision=request_changes overrode=true -->"}]'
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2
  [ "$status" -eq 101 ]
  [ ! -s "$CLAUDE_CALLS" ]
  [[ "$output" == *"already ran"* ]]
}

@test "DRY_RUN never runs tier 4 at the cap (diagnose stays model-free)" {
  export PR_REVIEW_ADJUDICATE=true CLAUDE_MODE=approve DRY_RUN=true
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2
  [ "$status" -eq 100 ]
  [ ! -s "$CLAUDE_CALLS" ]
}
