#!/usr/bin/env bats
# Unit tests for scripts/auto-rebase-retry.sh
# Covers the workflow_run failure handler that self-heals a failed Auto-rebase
# run by re-running its failed jobs, bounded by run_attempt, and surfacing a
# warning to humans once retries are exhausted.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
RETRY_SCRIPT="$SCRIPT_DIR/scripts/auto-rebase-retry.sh"

setup() {
  STUB_BIN_DIR="$(mktemp -d)"
  RERUN_MARKER="$(mktemp -u)"
  DISPATCH_MARKER="$(mktemp -u)"
  export RERUN_MARKER DISPATCH_MARKER
  # Mock gh: record `run rerun` to RERUN_MARKER and repository_dispatch to
  # DISPATCH_MARKER so tests can assert which recovery path the script took.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"run rerun"*)
    echo "$*" > "$RERUN_MARKER"
    [ "${GH_STUB_RERUN_FAILS:-0}" = "1" ] && exit 1
    echo "Requested rerun of run"
    ;;
  *dispatches*)
    echo "$*" > "$DISPATCH_MARKER"
    [ "${GH_STUB_DISPATCH_FAILS:-0}" = "1" ] && exit 1
    ;;
  *)
    echo "{}"
    ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export PATH="$STUB_BIN_DIR:$PATH"
  unset GITHUB_EVENT_NAME PR_NUMBER

  export GITHUB_STEP_SUMMARY
  GITHUB_STEP_SUMMARY="$(mktemp)"

  # Sensible defaults for a failing run on its first attempt.
  export REPO="petry-projects/.github-private"
  export RUN_ID="123456"
  export RUN_ATTEMPT="1"
  export CONCLUSION="failure"
  export WORKFLOW_NAME="Auto-rebase non-Dependabot PRs"
  export HTML_URL="https://github.com/petry-projects/.github-private/actions/runs/123456"
  export MAX_ATTEMPTS="3"
  unset GH_STUB_RERUN_FAILS DRY_RUN
}

teardown() {
  rm -rf "$STUB_BIN_DIR"
  rm -f "$RERUN_MARKER" "$DISPATCH_MARKER" "$GITHUB_STEP_SUMMARY"
}

_reran() { [ -f "$RERUN_MARKER" ]; }
_dispatched() { [ -f "$DISPATCH_MARKER" ]; }

@test "auto-rebase-retry: failure on first attempt → reruns failed jobs" {
  run bash "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  _reran
  grep -q "rerun" "$RERUN_MARKER"
  grep -q "$RUN_ID" "$RERUN_MARKER"
}

@test "auto-rebase-retry: success conclusion → noop, no rerun" {
  export CONCLUSION="success"
  run bash "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  ! _reran
}

@test "auto-rebase-retry: cancelled conclusion → noop, no rerun" {
  export CONCLUSION="cancelled"
  run bash "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  ! _reran
}

@test "auto-rebase-retry: attempt at cap → no rerun, gives up with warning" {
  export RUN_ATTEMPT="3"
  run bash "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  ! _reran
  [[ "$output" == *"::warning::"* ]]
  grep -qi "exhaust\|gave up\|giving up\|manual" "$GITHUB_STEP_SUMMARY"
}

@test "auto-rebase-retry: attempt past cap → no rerun" {
  export RUN_ATTEMPT="9"
  run bash "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  ! _reran
}

@test "auto-rebase-retry: last allowed attempt (cap-1) → reruns" {
  export RUN_ATTEMPT="2"
  export MAX_ATTEMPTS="3"
  run bash "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  _reran
}

@test "auto-rebase-retry: missing RUN_ID → noop, no rerun" {
  export RUN_ID=""
  run bash "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  ! _reran
}

@test "auto-rebase-retry: non-numeric RUN_ATTEMPT defaults to 1 → reruns" {
  export RUN_ATTEMPT="notanumber"
  run bash "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  _reran
}

@test "auto-rebase-retry: DRY_RUN → logs intent, does not rerun" {
  export DRY_RUN="true"
  run bash "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  ! _reran
  [[ "$output" == *"dry-run"* ]]
}

@test "auto-rebase-retry: rerun API failure → warns but exits 0" {
  export GH_STUB_RERUN_FAILS="1"
  run bash "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  _reran
  [[ "$output" == *"::warning::"* ]]
}

@test "auto-rebase-retry: empty REPO → reruns without --repo flag" {
  export REPO=""
  unset GITHUB_REPOSITORY
  run bash "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  _reran
  ! grep -q -- "--repo" "$RERUN_MARKER"
}

# ── manual workflow_dispatch: route a DIRTY PR into the rebase intent (#1890) ──

@test "auto-rebase-retry: manual dispatch with a PR number → routes to rebase intent, no rerun" {
  export GITHUB_EVENT_NAME="workflow_dispatch"
  export PR_NUMBER="1799"
  run bash "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  ! _reran
  _dispatched
  grep -q "dev-lead-reviews-retry" "$DISPATCH_MARKER"
  grep -q "1799" "$DISPATCH_MARKER"
  grep -q "rebase" "$DISPATCH_MARKER"
}

@test "auto-rebase-retry: manual dispatch without a PR number → warns, no dispatch, no rerun" {
  export GITHUB_EVENT_NAME="workflow_dispatch"
  export PR_NUMBER=""
  run bash "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  ! _reran
  ! _dispatched
  [[ "$output" == *"::warning::"* ]]
}

@test "auto-rebase-retry: manual dispatch DRY_RUN → logs intent, no dispatch" {
  export GITHUB_EVENT_NAME="workflow_dispatch"
  export PR_NUMBER="1800"
  export DRY_RUN="true"
  run bash "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  ! _dispatched
  [[ "$output" == *"dry-run"* ]]
}

@test "auto-rebase-retry: manual dispatch dispatch-API failure → warns but exits 0" {
  export GITHUB_EVENT_NAME="workflow_dispatch"
  export PR_NUMBER="1799"
  export GH_STUB_DISPATCH_FAILS="1"
  run bash "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  _dispatched
  [[ "$output" == *"::warning::"* ]]
}
