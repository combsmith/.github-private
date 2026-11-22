#!/usr/bin/env bats
# Issue #2545: a draft PR must be skipped by a gate before any model call.
#
# The reviewer prompts skip a draft unconditionally, so a draft that cleared every
# earlier gate used to spend a triage call and a confirmation call only to be
# skipped. review-one-pr.sh now skips it right after the PR snapshot — before the
# CI gate and tier 1 — with a `skip` verdict line naming `draft`, exit 100. The
# gate also applies under FORCE_REVIEW (a forced run would only spend the calls).
# An absent `isDraft` counts as not a draft.
#
# Run with: bats tests/test_review_one_pr_draft_gate.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"
  export SHA="2319231923192319231923192319231923192319"
  export PR_URL="https://github.com/combsmith/.github-private/pull/2319"
  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"; cd "$TEST_DIR"

  export GH_LOG="$TEST_DIR/gh_calls.log"; : > "$GH_LOG"
  export ENGINE_LOG="$TEST_DIR/engine_calls.log"; : > "$ENGINE_LOG"

  cat > "$TEST_DIR/bin/gh" <<EOF2
#!/bin/bash
printf '%s\n' "\$*" >> "$GH_LOG"
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then cat "$TEST_DIR/snapshot.json"; exit 0; fi
exit 0
EOF2
  chmod +x "$TEST_DIR/bin/gh"
  # Engine stubs record any invocation: a draft must never reach a model.
  for e in claude copilot gemini; do
    printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit 0\n' "$e" "$ENGINE_LOG" > "$TEST_DIR/bin/$e"
    chmod +x "$TEST_DIR/bin/$e"
  done
  export PATH="$TEST_DIR/bin:$PATH"
  export REVIEW_ENGINE="claude" GH_TOKEN="fake" DRY_RUN="true"
  unset FORCE_REVIEW
}
teardown() { rm -rf "$TEST_DIR"; }

# _snapshot <isDraft-json-fragment> — CI is pending, so a non-draft stops at the
# ci-pending gate (no model call) and the test stays fast and hermetic.
_snapshot() {
  cat > "$TEST_DIR/snapshot.json" <<EOF2
{
  "headRefOid": "$SHA",
  $1
  "statusCheckRollup": [
    { "name": "CI / build", "status": "IN_PROGRESS", "conclusion": null }
  ],
  "reviewDecision": "",
  "reviews": [],
  "labels": [],
  "comments": []
}
EOF2
}

@test "draft PR: skip reason=draft, exit 100, no engine call" {
  _snapshot '"isDraft": true,'
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2

  [ "$status" -eq 100 ]
  [[ "$output" == *'"decision":"skip"'* ]]
  [[ "$output" == *'"reason":"draft"'* ]]
  [[ "$output" == *"$SHA"* ]]
  # Skipped before the CI gate and before any model tier.
  [[ "$output" != *"CI status:"* ]]
  [ ! -s "$ENGINE_LOG" ]
  # The snapshot fetch asks GitHub for isDraft.
  grep -q -- '--json .*isDraft' "$GH_LOG"
  # A draft skip writes nothing to the PR.
  ! grep -qE 'pr (comment|review)' "$GH_LOG"
}

@test "draft PR under FORCE_REVIEW=true: still skipped as draft" {
  _snapshot '"isDraft": true,'
  export FORCE_REVIEW="true"
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2

  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"draft"'* ]]
  [ ! -s "$ENGINE_LOG" ]
}

@test "non-draft PR (isDraft=false): proceeds past the draft gate" {
  _snapshot '"isDraft": false,'
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2

  [[ "$output" != *'"reason":"draft"'* ]]
  [[ "$output" == *"CI status:"* ]]
  [[ "$output" == *'"reason":"ci-pending"'* ]]
}

@test "absent isDraft counts as not a draft" {
  _snapshot ''
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2

  [[ "$output" != *'"reason":"draft"'* ]]
  [[ "$output" == *'"reason":"ci-pending"'* ]]
}
