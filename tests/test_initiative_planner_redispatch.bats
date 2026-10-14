#!/usr/bin/env bats
# Unit tests for scripts/initiative-planner/redispatch.sh
#
# The planner's primary trigger is a `discussion [labeled]` event, but
# claude-code-action aborts on `discussion` event contexts. redispatch.sh bridges
# that gap by re-invoking the workflow via workflow_dispatch. These tests mock the
# gh CLI to avoid network calls and assert on the dispatched command.
#
# Run with: bats tests/test_initiative_planner_redispatch.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/initiative-planner/redispatch.sh"

setup() {
  MOCK_BIN="$(mktemp -d)"
  GH_LOG="$(mktemp)"
  export GH_LOG
  export PATH="$MOCK_BIN:$PATH"
  export REPO="petry-projects/.github-private"
  export DISCUSSION_NUMBER="572"
  export GH_TOKEN="pat"

  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
exit 0
EOF
  chmod +x "$MOCK_BIN/gh"
}

teardown() {
  rm -rf "${MOCK_BIN:-}"
  rm -f "${GH_LOG:-}"
}

@test "re-dispatches the planner workflow via workflow_dispatch" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF "workflow run initiative-planner.yml" "$GH_LOG"
}

@test "threads the discussion number and forces dry_run=false" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f discussion=572" "$GH_LOG"
  grep -qF -- "-f dry_run=false" "$GH_LOG"
}

@test "targets the correct repo" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "--repo petry-projects/.github-private" "$GH_LOG"
}

@test "fails when DISCUSSION_NUMBER is unset" {
  unset DISCUSSION_NUMBER
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "rejects a non-numeric DISCUSSION_NUMBER without dispatching" {
  export DISCUSSION_NUMBER="572; rm -rf /"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"positive integer"* ]]
  [ ! -s "$GH_LOG" ]
}

@test "fails when REPO is unset" {
  unset REPO
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "honors a WORKFLOW_FILE override" {
  export WORKFLOW_FILE="other-planner.yml"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF "workflow run other-planner.yml" "$GH_LOG"
}

@test "honors DRY_RUN=1 or DRY_RUN=true" {
  export DRY_RUN="1"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f dry_run=true" "$GH_LOG"

  export DRY_RUN="true"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f dry_run=true" "$GH_LOG"
}

@test "passes target_repo defaulting to the dispatch repo (dogfood self path)" {
  unset TARGET_REPO
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f target_repo=petry-projects/.github-private" "$GH_LOG"
}

@test "honors a TARGET_REPO override (fleet host repo)" {
  export TARGET_REPO="acme/widgets"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f target_repo=acme/widgets" "$GH_LOG"
}

@test "forwards force_replan=false by default" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f force_replan=false" "$GH_LOG"
}

@test "honors FORCE_REPLAN=1 (initiative:replan path)" {
  export FORCE_REPLAN="1"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f force_replan=true" "$GH_LOG"
}

@test "honors FORCE_REPLAN=true (initiative:replan path)" {
  export FORCE_REPLAN="true"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f force_replan=true" "$GH_LOG"
}

@test "forwards reconcile=false by default" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f reconcile=false" "$GH_LOG"
}

@test "honors RECONCILE=1 (initiative:reconcile path)" {
  export RECONCILE="1"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f reconcile=true" "$GH_LOG"
}

@test "honors RECONCILE=true (initiative:reconcile path)" {
  export RECONCILE="true"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f reconcile=true" "$GH_LOG"
}

@test "passes GITHUB_REF if it is a branch or tag" {
  export GITHUB_REF="refs/heads/feature-branch"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "--ref refs/heads/feature-branch" "$GH_LOG"
}

@test "ignores GITHUB_REF if it is a pull request ref" {
  export GITHUB_REF="refs/pull/123/merge"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -qF -- "--ref" "$GH_LOG"
}
