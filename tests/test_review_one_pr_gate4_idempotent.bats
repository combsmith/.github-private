#!/usr/bin/env bats
# Issue #1766 (second symptom): one review per head SHA. A SHA that already
# carries a POSTED VERDICT must not be re-reviewed — that is the defect that let
# a later, more optimistic APPROVED verdict supersede an earlier stricter one on
# identical code (PR #1742: three SHAs each reviewed twice). Re-review at the
# same SHA is a no-op unless explicitly forced (FORCE_REVIEW).
#
# These tests drive scripts/review-one-pr.sh end-to-end. The gh stub clears the
# advisory-bot and maintainer gates (empty review-thread set + old head commit)
# so execution reaches the same-SHA idempotency block.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"

  export SHA="402a42a3402a42a3402a42a3402a42a3402a42a3"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/1742"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  # Run from the repo root: the review registry resolves output_channel to the
  # relative path scripts/post-pr-review.sh, so the forced cascade must execute
  # with the repo as CWD to find it (fixture artifacts use absolute paths).
  cd "$REPO_ROOT"

  export SNAPSHOT="$TEST_DIR/snapshot.json"
  export GH_LOG="$TEST_DIR/gh_calls.log"
  : > "$GH_LOG"

  cat > "$TEST_DIR/bin/gh" <<'GHEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  jqf=""; prev=""
  for a in "$@"; do
    [ "$prev" = "--jq" ] && jqf="$a"
    prev="$a"
  done
  if [ -n "$jqf" ]; then jq -r "$jqf" "$SNAPSHOT"; else cat "$SNAPSHOT"; fi
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  # Honor --jq like real gh: the advisory-gate head-age check calls
  # `gh api graphql ... --jq '.data...committer.date'`, so a stub that ignored
  # --jq handed back the whole JSON blob, `date -d` failed to parse it, head age
  # read as undeterminable, and the gate stayed in "waiting" — the fixture's old
  # head commit never triggered the timeout that lets execution reach the
  # same-SHA idempotency block.
  jqf=""; prev=""
  for a in "$@"; do
    [ "$prev" = "--jq" ] && jqf="$a"
    prev="$a"
  done
  case "$*" in
    *reviewThreads*) resp='{"data":{"resource":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' ;;
    *pushedDate*)    resp='{"data":{"resource":{"commits":{"nodes":[{"commit":{"pushedDate":"2020-01-01T00:00:00Z","committer":{"date":"2020-01-01T00:00:00Z"}}}]}}}}' ;;
    *committer*)     resp='{"data":{"resource":{"commits":{"nodes":[{"commit":{"committer":{"date":"2020-01-01T00:00:00Z"}}}]}}}}' ;;
    *)               resp='{"data":{}}' ;;
  esac
  if [ -n "$jqf" ]; then printf '%s' "$resp" | jq -r "$jqf"; else printf '%s' "$resp"; fi
  exit 0
fi
exit 0
GHEOF
  chmod +x "$TEST_DIR/bin/gh"

  # copilot/gemini are never invoked here but must exist so engine discovery
  # doesn't abort; only the claude stub needs to emit a real verdict.
  for e in copilot gemini; do
    printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/$e"
    chmod +x "$TEST_DIR/bin/$e"
  done

  # A forced re-review runs the full cascade, which needs a valid verdict from
  # the engine. The claude tiers are invoked as `claude --print ... < prompt` and
  # their stdout is captured, so the stub emits a combined triage+review JSON
  # (both .escalate and .decision present) so both tiers parse it and the run
  # reaches the [done] marker.
  cat > "$TEST_DIR/bin/claude" <<'CLAUDEEOF'
#!/bin/bash
printf '%s\n' '{"escalate":false,"risk":"LOW","signals":[],"decision":"approve","summary":"ok","findings":[],"body":"<!-- pr-review-agent v1 sha=x decision=approved risk=LOW -->\n\n## Automated review — APPROVED"}'
exit 0
CLAUDEEOF
  chmod +x "$TEST_DIR/bin/claude"

  export PATH="$TEST_DIR/bin:$PATH"
  export REVIEW_ENGINE="claude" GH_TOKEN="fake" DRY_RUN="true"
  # Pin the bot identity so marker/author matching is hermetic regardless of the
  # caller's environment (matches tests/test_review_one_pr_carry_forward.bats).
  export BOT_USER="donpetry-bot"
  unset FORCE_REVIEW FORCE_RE_REVIEW
}

# write_snapshot <marker-body>
write_snapshot() {
  local marker_body="$1"
  local comments
  comments=$(jq -n --arg b "$marker_body" '[{author:{login:"donpetry-bot"},createdAt:"2026-09-10T19:46:37Z",body:$b}]')
  jq -n --arg sha "$SHA" --argjson comments "$comments" '{
    headRefOid: $sha,
    statusCheckRollup: [{"name":"CI / build","status":"COMPLETED","conclusion":"SUCCESS"}],
    reviewDecision: "APPROVED",
    reviews: [],
    labels: [],
    closingIssuesReferences: [],
    body: "PR body",
    comments: $comments
  }' > "$SNAPSHOT"
}

@test "#1766: posted APPROVED verdict at head + no force → no-op (not a second review)" {
  write_snapshot '<!-- pr-review-agent v1 sha='"$SHA"' decision=approved risk=MEDIUM -->'
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"already-reviewed-at-head"'* ]]
  [[ "$output" != *"re-running cascade"* ]]
}

@test "#1766: FORCE_REVIEW=true overrides the same-SHA no-op (human break-glass)" {
  export FORCE_REVIEW="true"
  write_snapshot '<!-- pr-review-agent v1 sha='"$SHA"' decision=approved risk=MEDIUM -->'
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [[ "$output" != *'"reason":"already-reviewed-at-head"'* ]]
  [[ "$output" == *"re-running cascade"* ]]
  # Break-glass must actually re-run the cascade to a clean completion: require a
  # successful exit and the [done] marker. A bare `!= 100` would accept any other
  # nonzero (crash/timeout) as "not the no-op", which is not the same as success.
  [ "$status" -eq 0 ]
  [[ "$output" == *"[done]"* ]]
}
