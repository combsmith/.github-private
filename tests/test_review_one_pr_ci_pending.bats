#!/usr/bin/env bats
# Regression guard for the ci-pending -> ci-success transition (issue #898).
#
# Incident: on PR #892 (head SHA 8203876e5b0718dd3d672fed4eec8394e5d3729d) the
# reviewer logged a ci-pending skip while checks were still running, then never
# re-reviewed after CI went green — the PR sat un-approved until a manual
# force_review. The reporter's hypothesis was that the ci-pending skip records
# an "already reviewed" idempotency marker that short-circuits the later
# (CI-green) trigger at the same SHA.
#
# This guard locks in the property that makes the pending -> success transition
# safe: the ci-pending skip is NON-TERMINAL. review-one-pr.sh must exit with the
# skip sentinel (100) carrying reason "ci-pending" WITHOUT writing any marker
# (no `gh pr comment` / `gh pr review`). Because no marker is written at the
# pending head SHA, the idempotency check cannot find one when CI later flips to
# success at that same SHA, so the re-trigger is review-eligible rather than a
# no-op. If a future change ever made the ci-pending path post a marker, this
# test fails and flags the reintroduced deadlock.
#
# Run with: bats tests/test_review_one_pr_ci_pending.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"

  # The exact head SHA from the #892 incident.
  export FIXED_SHA="8203876e5b0718dd3d672fed4eec8394e5d3729d"
  export PR_URL="https://github.com/combsmith/.github-private/pull/892"

  export TEST_DIR="$BATS_TMPDIR/review-one-ci-pending"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  # Snapshot returned by `gh pr view`: a single external check still IN_PROGRESS
  # -> compute_ci_status classifies the gate as "pending".
  cat > "$TEST_DIR/snapshot.json" <<EOF
{
  "headRefOid": "$FIXED_SHA",
  "statusCheckRollup": [
    { "name": "build", "status": "IN_PROGRESS", "conclusion": null }
  ],
  "reviewDecision": "",
  "reviews": [],
  "labels": [],
  "comments": []
}
EOF

  export GH_LOG="$TEST_DIR/gh_calls.log"
  : > "$GH_LOG"

  # Stub gh: log every invocation, return the pending snapshot for `pr view`,
  # and no-op everything else (so a stray comment/review write is still logged).
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

  # Minimal engine env so sourcing engine.sh succeeds. The run exits at the
  # ci-pending gate well before any engine is invoked.
  export REVIEW_ENGINE="claude"
  export GH_TOKEN="fake-token"
  export DRY_RUN="false"
  unset FORCE_REVIEW
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "review-one-pr: ci-pending at the incident SHA exits 100 with reason ci-pending" {
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "status=$status" >&2
  echo "$output" >&2

  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"ci-pending"'* ]]
  [[ "$output" == *"$FIXED_SHA"* ]]
}

@test "review-one-pr: ci-pending skip writes NO marker (non-terminal)" {
  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2
  echo "--- gh calls ---" >&2
  cat "$GH_LOG" >&2

  [ "$status" -eq 100 ]
  # The reviewer must read the PR (pr view) but must NOT post anything: a
  # ci-pending skip that wrote an approval/comment marker is exactly the
  # deadlock this guard prevents.
  grep -q 'pr view' "$GH_LOG"
  ! grep -qE 'pr (comment|review)' "$GH_LOG"
}
