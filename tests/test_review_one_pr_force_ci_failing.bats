#!/usr/bin/env bats
# SC2 regression guard (Safe Release epic #495 · game-day story #503, see
# docs/release/sc2-game-day.md): a broken in-dev gate must not block its own fix.
# Guards the #619 break-glass in scripts/review-one-pr.sh:
# a manual FORCE_REVIEW=true run overrides the ci-failing gate (so a fix to the
# CI gate itself can be reviewed through ring-0 self-host), while a normal run
# still skips on failing CI. FORCE_REVIEW is manual-only (repository_dispatch /
# explicit input); the scheduled sweep dispatches with force_review=false.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"
  export SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/999"
  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"; cd "$TEST_DIR"
  # A single external check FAILED -> compute_ci_status classifies "failing".
  # Uses a genuine external check name: a first-party agent's own check (e.g.
  # "dev-lead / dispatch") is now filtered from the CI gate (#1427), so it would
  # read green — the break-glass path under test only triggers on real failing CI.
  cat > "$TEST_DIR/snapshot.json" <<EOF
{
  "headRefOid": "$SHA",
  "statusCheckRollup": [
    { "name": "CI / build", "status": "COMPLETED", "conclusion": "FAILURE" }
  ],
  "reviewDecision": "",
  "reviews": [],
  "labels": [],
  "comments": []
}
EOF
  cat > "$TEST_DIR/bin/gh" <<EOF
#!/bin/bash
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then cat "$TEST_DIR/snapshot.json"; exit 0; fi
exit 0
EOF
  chmod +x "$TEST_DIR/bin/gh"
  # Stub engines so a bypassed run can't block on a real CLI.
  for e in claude copilot gemini; do printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/$e"; chmod +x "$TEST_DIR/bin/$e"; done
  export PATH="$TEST_DIR/bin:$PATH"
  export REVIEW_ENGINE="claude" GH_TOKEN="fake" DRY_RUN="true"
}
teardown() { rm -rf "$TEST_DIR"; }

@test "normal run (no FORCE_REVIEW): failing CI → skip reason=ci-failing, exit 100" {
  unset FORCE_REVIEW
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"ci-failing"'* ]]
  [[ "$output" != *"bypassing the ci-failing gate"* ]]
}

@test "FORCE_REVIEW=true: failing CI → ci-failing gate bypassed (break-glass #619)" {
  export FORCE_REVIEW="true"
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  # Must NOT emit the ci-failing skip; must announce the break-glass bypass.
  [[ "$output" != *'"reason":"ci-failing"'* ]]
  [[ "$output" == *"bypassing the ci-failing gate"* ]]
  [ "$status" -ne 100 ]
}
