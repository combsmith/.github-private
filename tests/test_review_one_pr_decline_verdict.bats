#!/usr/bin/env bats
# Structured decline-reason logging for pr-review no-ops (issue #1552, AC#2).
#
# Incident (#1552): PR #1531 sat clean-but-unreviewed for 100 min while every
# pr-review run reported "success". Each declining run DID emit an internal JSON
# verdict, but it carried only {pr, sha, decision, reason} — not WHAT WOULD CHANGE
# the decision — so from any single run log the stall was invisible and required
# log archaeology + manual re-runs to converge.
#
# This guard pins the property that makes a no-op diagnosable from ONE log line:
# every run that evaluates a PR and declines to review it emits a single
# structured verdict line carrying pr, sha, decision, reason AND a non-empty
# `would_change` clause (the mirror of #1494 AC#3's slot-math line). The line
# stays valid JSON so review-batch.sh's reason parser keeps working.
#
# Run with: bats tests/test_review_one_pr_decline_verdict.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"

  export SHA="e655425fabcdef0123456789abcdef0123456789"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/1531"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  export GH_LOG="$TEST_DIR/gh_calls.log"
  : > "$GH_LOG"

  export REVIEW_ENGINE="claude"
  export GH_TOKEN="fake-token"
  export DRY_RUN="false"
  unset FORCE_REVIEW
}

# No manual teardown needed: $BATS_TEST_TMPDIR is per-test isolated and auto-cleaned by BATS.

# write_snapshot <rollup-json>
# Installs a gh stub whose `pr view` returns a snapshot with the given rollup.
write_snapshot() {
  local rollup="$1"
  cat > "$TEST_DIR/snapshot.json" <<EOF
{
  "headRefOid": "$SHA",
  "statusCheckRollup": $rollup,
  "reviewDecision": "",
  "reviews": [],
  "labels": [],
  "comments": []
}
EOF
  cat > "$TEST_DIR/bin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$GH_LOG"
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  cat "$TEST_DIR/snapshot.json"
  exit 0
fi
exit 0
EOF
  chmod +x "$TEST_DIR/bin/gh"
  export PATH="$TEST_DIR/bin:$PATH"
}

# verdict_line <output>
# Echo the last line of the run output that is the structured JSON verdict.
verdict_line() {
  printf '%s\n' "$1" | grep -E '"decision":' | tail -n1
}

@test "ci-failing decline emits one verdict line with pr, sha, decision, reason AND would_change" {
  write_snapshot '[{ "name": "build", "status": "COMPLETED", "conclusion": "FAILURE" }]'
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "status=$status" >&2
  echo "$output" >&2

  [ "$status" -eq 100 ]
  local line
  line=$(verdict_line "$output")
  # The verdict is valid JSON carrying every required field.
  echo "$line" | jq -e '.pr and .sha and .decision and .reason and .would_change' >/dev/null
  [ "$(echo "$line" | jq -r '.decision')" = "skip" ]
  [ "$(echo "$line" | jq -r '.reason')" = "ci-failing" ]
  [ "$(echo "$line" | jq -r '.sha')" = "$SHA" ]
  [ "$(echo "$line" | jq -r '.pr')" = "$PR_URL" ]
  # would_change must be a non-empty, human-actionable clause — not a bare slug.
  [ -n "$(echo "$line" | jq -r '.would_change')" ]
  [ "$(echo "$line" | jq -r '.would_change')" != "null" ]
}

@test "ci-pending decline emits a would_change clause too" {
  write_snapshot '[{ "name": "build", "status": "IN_PROGRESS", "conclusion": null }]'
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "status=$status" >&2
  echo "$output" >&2

  [ "$status" -eq 100 ]
  local line
  line=$(verdict_line "$output")
  [ "$(echo "$line" | jq -r '.reason')" = "ci-pending" ]
  [ -n "$(echo "$line" | jq -r '.would_change')" ]
  [ "$(echo "$line" | jq -r '.would_change')" != "null" ]
}

@test "the decline verdict stays a single line (one structured log line, AC#2)" {
  write_snapshot '[{ "name": "build", "status": "COMPLETED", "conclusion": "FAILURE" }]'
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 100 ]
  # Exactly one JSON verdict line is emitted for the decline.
  local count
  count=$(printf '%s\n' "$output" | grep -cE '"decision":')
  [ "$count" -eq 1 ]
}

@test "review-batch reason parsing still resolves the reason from the extended line" {
  # Guards backward-compat: review-batch.sh greps the trailing "reason":"…" value.
  write_snapshot '[{ "name": "build", "status": "COMPLETED", "conclusion": "FAILURE" }]'
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 100 ]
  local line reason
  line=$(verdict_line "$output")
  reason=$(printf '%s\n' "$line" \
    | grep -oE '"reason"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | tail -n1 \
    | sed -E 's/.*"reason"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
  [ "$reason" = "ci-failing" ]
}
