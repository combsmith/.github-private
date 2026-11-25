#!/usr/bin/env bats
# Issue #2614: pr-review now posts its fix request as a COMMENT review (the
# fix-requested marker pair is the review body), not a PR conversation comment.
# review-one-pr.sh must keep its cycle cap and its head-SHA idempotency working
# when the markers live in pr-review's reviews:
#   - a fix-request review at the head is an idempotent no-op;
#   - a fix-request review at an older head is re-reviewed at the new head;
#   - every fix-request review counts once toward the cycle, superseded and
#     dismissed ones included.
# The gh stub and engine stubs are the #1551 harness
# (tests/test_review_one_pr_metadata_rearm.bats).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"
  # shellcheck source=../scripts/lib/pr-metadata-digest.sh
  source "$REPO_ROOT/scripts/lib/pr-metadata-digest.sh"

  export SHA="8203876e5b0718dd3d672fed4eec8394e5d3729d"
  export PR_URL="https://github.com/combsmith/.github-private/pull/1531"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  export SNAPSHOT="$TEST_DIR/snapshot.json"
  export GH_LOG="$TEST_DIR/gh_calls.log"
  : > "$GH_LOG"

  # gh stub: honors `pr view --jq <filter>` (so the idempotency block's own
  # marker query works), returns the snapshot for a plain `pr view`, and answers
  # the three GraphQL shapes the gates use:
  #   • reviewThreads → empty node set (review-thread gate clears)
  #   • pushedDate    → an old push time (maintainer gate head date)
  #   • committer date (advisory gate, called with --jq) → old date ⇒ head-age
  #     timeout elapsed ⇒ advisory gate proceeds with no bot output.
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

  # Stub engines so the re-arm (proceed) path can't block on a real CLI.
  for e in claude copilot gemini; do
    printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/$e"
    chmod +x "$TEST_DIR/bin/$e"
  done

  export PATH="$TEST_DIR/bin:$PATH"
  export REVIEW_ENGINE="claude" GH_TOKEN="fake" DRY_RUN="true"
  unset FORCE_REVIEW
  # pr-review's acting login: its markers are trusted only from this author. Pin
  # it so a BOT_USER inherited from the runner (dev-lead's login) cannot leak in.
  export BOT_USER="donpetry-bot"
}

teardown() { rm -rf "$TEST_DIR"; }

# fr_review <sha> <submittedAt> [state] [superseded] — a fix-request review by
# pr-review's login, as post-pr-review.sh posts it (#2614).
fr_review() {
  local body
  body="<!-- pr-review-agent v1 sha=$1 --> <!-- decision=fix-requested risk=LOW -->

## Review — fix requested"
  if [ "${4:-}" = "superseded" ]; then
    body="<!-- pr-review-agent superseded -->
<details><summary><em>Superseded</em></summary>

$body

</details>"
  fi
  jq -nc --arg b "$body" --arg w "$2" --arg st "${3:-COMMENTED}" \
    '{author: {login: "donpetry-bot"}, state: $st, submittedAt: $w, body: $b}'
}

# write_snapshot <reviews-json> — the head is $SHA, CI green, no comments.
write_snapshot() {
  jq -n --arg sha "$SHA" --argjson reviews "$1" '{
    headRefOid: $sha,
    statusCheckRollup: [ { name: "CI / build", status: "COMPLETED", conclusion: "SUCCESS" } ],
    reviewDecision: "",
    reviews: $reviews,
    labels: [],
    closingIssuesReferences: [],
    body: "Refs #2614",
    comments: []
  }' > "$SNAPSHOT"
}

OLD1="1111111111111111111111111111111111111111"
OLD2="2222222222222222222222222222222222222222"

@test "#2614: a fix-request review at the head is an idempotent no-op" {
  write_snapshot "[$(fr_review "$SHA" 2026-11-25T10:00:00Z)]"
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2
  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"already-reviewed-at-head"'* ]]
}

@test "#2614: a fix-request review at an older head is re-reviewed at the new head" {
  write_snapshot "[$(fr_review "$OLD1" 2026-11-25T10:00:00Z)]"
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2
  [[ "$output" != *'"reason":"already-reviewed-at-head"'* ]]
  [[ "$output" == *"review cycle: 1 "* ]]
  [ "$status" -ne 100 ]
}

@test "#2614: the cycle counts every fix-request review, superseded and dismissed ones included" {
  write_snapshot "[$(fr_review "$OLD1" 2026-11-23T10:00:00Z DISMISSED superseded),$(fr_review "$OLD2" 2026-11-24T10:00:00Z COMMENTED superseded)]"
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2
  [[ "$output" == *"review cycle: 2 "* ]]
}

@test "#2614: a fix-request review by another login is not pr-review's verdict at the head" {
  local forged
  forged=$(fr_review "$SHA" 2026-11-25T10:00:00Z | jq -c '.author.login = "someone-else"')
  write_snapshot "[$forged]"
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2
  [[ "$output" != *'"reason":"already-reviewed-at-head"'* ]]
}
