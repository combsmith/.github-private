#!/usr/bin/env bats
# Issue #2545: post-pr-review.sh's `decision=skip` branch must print a verdict JSON
# line (decision + reason) before its exit 100, so review-batch.sh reports the
# real skip reason instead of finding no "reason" field at all.
#
# Run with: bats tests/test_post_pr_review_skip_verdict.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export POST_SCRIPT="$REPO_ROOT/scripts/post-pr-review.sh"
  export PR_HEAD_SHA="2319231923192319231923192319231923192319"
  export PR_URL="https://github.com/combsmith/.github-private/pull/2319"
  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin" && cd "$TEST_DIR" || exit 1
  export GH_LOG="$TEST_DIR/gh_calls.log"; : > "$GH_LOG"
  cat > "$TEST_DIR/bin/gh" <<EOF2
#!/bin/bash
printf '%s\n' "\$*" >> "$GH_LOG"
exit 0
EOF2
  chmod +x "$TEST_DIR/bin/gh"
  export PATH="$TEST_DIR/bin:$PATH"
}
teardown() { rm -rf "$TEST_DIR"; }

@test "skip verdict: prints a decision=skip JSON line with the reason, exits 100" {
  printf '%s' '{"decision":"skip","reason":"draft","risk":"LOW","body":""}' > verdict.json
  run bash "$POST_SCRIPT" "$PR_URL" verdict.json false
  echo "$output" >&2

  [ "$status" -eq 100 ]
  [[ "$output" == *"reviewer returned skip (draft)"* ]]
  line=$(grep -E '^\{.*"decision":"skip"' <<< "$output" | tail -n1)
  [ -n "$line" ]
  [ "$(jq -r '.reason' <<< "$line")" = "draft" ]
  [ "$(jq -r '.pr' <<< "$line")" = "$PR_URL" ]
  [ "$(jq -r '.sha' <<< "$line")" = "$PR_HEAD_SHA" ]
  # A skip posts nothing.
  ! grep -qE 'pr (comment|review)|/reviews' "$GH_LOG"
}

@test "skip verdict without a reason: reason is reported as unspecified" {
  printf '%s' '{"decision":"skip","risk":"LOW","body":""}' > verdict.json
  run bash "$POST_SCRIPT" "$PR_URL" verdict.json false
  echo "$output" >&2

  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"unspecified"'* ]]
}
