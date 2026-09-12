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
  cd "$TEST_DIR"

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
  case "$*" in
    *reviewThreads*) printf '%s' '{"data":{"resource":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' ;;
    *pushedDate*)    printf '%s' '{"data":{"resource":{"commits":{"nodes":[{"commit":{"pushedDate":"2020-01-01T00:00:00Z","committer":{"date":"2020-01-01T00:00:00Z"}}}]}}}}' ;;
    *)               printf '%s\n' '2020-01-01T00:00:00Z' ;;
  esac
  exit 0
fi
exit 0
GHEOF
  chmod +x "$TEST_DIR/bin/gh"

  for e in claude copilot gemini; do
    printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/$e"
    chmod +x "$TEST_DIR/bin/$e"
  done

  export PATH="$TEST_DIR/bin:$PATH"
  export REVIEW_ENGINE="claude" GH_TOKEN="fake" DRY_RUN="true"
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
  [ "$status" -ne 100 ]
}
