#!/usr/bin/env bats
# Issue #1754 AC1 (maintainer review gap): the review-cycle cap IS a human
# escalation, so review-one-pr.sh must exit 101 (counted `escalated` by
# review-batch.sh), not 100 (no-op). Under DRY_RUN nothing is posted, so it stays
# 100 and is not counted as a delivered escalation.
#
# Run with: bats tests/test_review_one_pr_escalation_exit.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"
  export FIXED_SHA="d53a7fc6b0718dd3d672fed4eec8394e5d372900"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/1703"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  cd "$REPO_ROOT"
  export SNAPSHOT="$TEST_DIR/snapshot.json"

  cat > "$SNAPSHOT" <<EOF
{
  "headRefOid": "$FIXED_SHA",
  "statusCheckRollup": [
    { "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS" }
  ],
  "reviewDecision": "",
  "reviews": [],
  "labels": [],
  "comments": []
}
EOF

  export SNAPSHOT="$TEST_DIR/snapshot.json"
  export GH_LOG="$TEST_DIR/gh_calls.log"
  : > "$GH_LOG"
  # gh stub: clear every approval gate (empty review-thread set, an old head
  # commit so the advisory head-age timeout has elapsed) and log all calls so a
  # delivered escalation (comment + label) is observable.
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
  export PATH="$TEST_DIR/bin:$PATH"

  export REVIEW_ENGINE="claude"
  export GH_TOKEN="fake-token"
  # A cap of 0 makes the cycle cap fire on the first pass (REVIEW_CYCLE 0 >= 0).
  export MAX_REVIEW_CYCLES=0
  unset FORCE_REVIEW
}

@test "cycle cap with a delivered escalation exits 101 (escalated)" {
  export DRY_RUN="false"
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "status=$status" >&2; echo "$output" >&2
  [[ "$output" == *"max-cycles-reached"* ]]
  [ "$status" -eq 101 ]
  grep -q 'pr comment' "$GH_LOG"
  grep -q 'needs-human-review' "$GH_LOG"
}

@test "cycle cap under DRY_RUN exits 100 (nothing posted, not escalated)" {
  export DRY_RUN="true"
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "status=$status" >&2; echo "$output" >&2
  [[ "$output" == *"max-cycles-reached"* ]]
  [ "$status" -eq 100 ]
  ! grep -q 'needs-human-review' "$GH_LOG"
  ! grep -q 'pr comment' "$GH_LOG"
}
