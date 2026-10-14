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
  export PR_URL="https://github.com/petry-projects/.github-private/pull/892"

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

# ---------------------------------------------------------------------------
# Bounded ci-pending deferral (issue #1427, AC #3/#4). A pending check with no
# usable timestamp is fail-safe (never timed out), so the incident snapshot above
# still skips as ci-pending — verified by the two tests above. When the pending
# check is genuinely STUCK (started long ago), the review proceeds on the completed
# checks instead of deferring forever, and escalates once via a visible comment.
# The merge gate is unaffected (it is enforced by the ruleset, not by this script).
# ---------------------------------------------------------------------------

@test "review-one-pr: a stuck pending check proceeds past the ci-pending gate (#1427)" {
  # Same external check, but started ~2h ago → older than the 30-min default,
  # so ci_pending_age_exceeded is true and the ci-pending skip is bounded out.
  local old
  old=$(date -u -d "2 hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  cat > "$TEST_DIR/snapshot.json" <<EOF
{
  "headRefOid": "$FIXED_SHA",
  "statusCheckRollup": [
    { "name": "build", "status": "IN_PROGRESS", "conclusion": null, "startedAt": "$old" }
  ],
  "reviewDecision": "",
  "reviews": [],
  "labels": [],
  "comments": []
}
EOF

  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "status=$status" >&2
  echo "$output" >&2
  echo "--- gh calls ---" >&2
  cat "$GH_LOG" >&2

  # It must NOT record a ci-pending skip — the whole point of the bound.
  [[ "$output" != *'"reason":"ci-pending"'* ]]
  # It escalates once with the timeout marker.
  grep -q 'ci-pending-timeout' "$GH_LOG"
}

@test "review-one-pr: stuck-pending escalation comment does not recommend a re-mention" {
  local old
  old=$(date -u -d "2 hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  cat > "$TEST_DIR/snapshot.json" <<EOF
{
  "headRefOid": "$FIXED_SHA",
  "statusCheckRollup": [
    { "name": "build", "status": "IN_PROGRESS", "conclusion": null, "startedAt": "$old" }
  ],
  "reviewDecision": "",
  "reviews": [],
  "labels": [],
  "comments": []
}
EOF

  run bash "$REVIEW_SCRIPT" "$PR_URL"
  cat "$GH_LOG" >&2
  # AC #5: no re-mention advice that would re-arm dev-lead.
  run grep -qi 're-mention' "$GH_LOG"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# ci-pending-ack copy (issue #1427, AC #5). When FORCE_REVIEW polling exhausts on
# a still-pending (no-timestamp) PR, the ack comment must NOT recommend a
# re-mention — a re-mention fires dev-lead, whose own check re-arms the deferral.
# ---------------------------------------------------------------------------

@test "review-one-pr: FORCE_REVIEW ci-pending-ack copy contains no re-mention advice" {
  export FORCE_REVIEW=true
  export FORCE_REVIEW_POLL_ATTEMPTS=1
  export FORCE_REVIEW_POLL_INTERVAL_SEC=1

  run bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2
  echo "--- gh calls ---" >&2
  cat "$GH_LOG" >&2

  # The ack marker is posted…
  grep -q 'ci-pending-ack' "$GH_LOG"
  # …but it must not tell anyone to re-mention the bot (the self-inflicted loop).
  run grep -qi 're-mention' "$GH_LOG"
  [ "$status" -eq 1 ]
  run grep -q 'trigger a fresh review' "$GH_LOG"
  [ "$status" -eq 1 ]
}
