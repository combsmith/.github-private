#!/usr/bin/env bats
# Tests for scripts/initiative_canary.sh — the post-merge canary for the
# idea:approved → initiative-planner dispatch path (#822, closes #655 item 3).
#
# Pure helpers (classify / alert decision / report) are unit-tested directly.
# main()'s dry-run dispatch + poll is exercised with a mocked gh CLI so no
# network call is made and the canary creates nothing.
#
# Run with: bats tests/test_initiative_canary.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/initiative_canary.sh"

setup() {
  # shellcheck source=scripts/initiative_canary.sh
  source "$SCRIPT"
}

# ---------------------------------------------------------------------------
# classify_canary_run <conclusion> <logs>
# ---------------------------------------------------------------------------

@test "classify_canary_run: success with clean logs is OK" {
  run classify_canary_run "success" "Plan complete (dry-run): no issues created."
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "classify_canary_run: the unsupported-event error is flagged even on success" {
  # A silent revert of the redispatch bridge resurfaces this exact string.
  run classify_canary_run "success" "Action failed with error: Unsupported event type: discussion"
  [ "$status" -eq 0 ]
  [ "$output" = "UNSUPPORTED_EVENT" ]
}

@test "classify_canary_run: a failing conclusion is FAILED" {
  run classify_canary_run "failure" "boom"
  [ "$output" = "FAILED" ]
}

@test "classify_canary_run: timed_out / cancelled are FAILED" {
  run classify_canary_run "timed_out" ""
  [ "$output" = "FAILED" ]
  run classify_canary_run "cancelled" ""
  [ "$output" = "FAILED" ]
}

@test "classify_canary_run: an empty conclusion (no run found) is NO_RUN" {
  run classify_canary_run "" ""
  [ "$output" = "NO_RUN" ]
}

@test "classify_canary_run: a null conclusion (still running) is NO_RUN" {
  run classify_canary_run "null" ""
  [ "$output" = "NO_RUN" ]
}

@test "classify_canary_run: unsupported-event wins over a FAILED conclusion" {
  run classify_canary_run "failure" "...Unsupported event type: discussion..."
  [ "$output" = "UNSUPPORTED_EVENT" ]
}

# ---------------------------------------------------------------------------
# canary_is_failure <status> — alert decision
# ---------------------------------------------------------------------------

@test "canary_is_failure: OK does not alert" {
  run canary_is_failure "OK"
  [ "$status" -ne 0 ]
}

@test "canary_is_failure: every non-OK status alerts" {
  for s in UNSUPPORTED_EVENT FAILED NO_RUN; do
    run canary_is_failure "$s"
    [ "$status" -eq 0 ]
  done
}

# ---------------------------------------------------------------------------
# canary_report <status> <repo> <discussion> <run_url> [today]
# ---------------------------------------------------------------------------

@test "canary_report: OK report names the path and the discussion" {
  run canary_report "OK" "petry-projects/.github-private" "42" "https://x/run/1" "2026-06-20"
  [ "$status" -eq 0 ]
  [[ "$output" == *"idea:approved"* ]]
  [[ "$output" == *"#42"* ]]
  [[ "$output" == *"2026-06-20"* ]]
}

@test "canary_report: the unsupported-event status surfaces the regression hint" {
  run canary_report "UNSUPPORTED_EVENT" "petry-projects/.github-private" "42" "https://x/run/1"
  [[ "$output" == *"Unsupported event type: discussion"* ]]
  [[ "$output" == *"https://x/run/1"* ]]
}

# ---------------------------------------------------------------------------
# main() — mocked gh, asserts the DRY-RUN dispatch and a clean exit
# ---------------------------------------------------------------------------

_install_gh_mock() {
  MOCK_BIN="$(mktemp -d)"
  GH_LOG="$(mktemp)"
  export GH_LOG MOCK_BIN
  export PATH="$MOCK_BIN:$PATH"
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
# Apply the real --jq filter (as gh would) so main()'s jq is exercised.
jqf=""; args=("$@")
for ((i=0;i<${#args[@]};i++)); do [ "${args[i]}" = "--jq" ] && jqf="${args[i+1]}"; done
emit() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
case "$1 $2" in
  "workflow run") exit 0 ;;
  "run list")
    # One completed, successful workflow_dispatch run.
    echo '[{"databaseId":555,"status":"completed","conclusion":"success","createdAt":"2026-06-20T06:00:00Z","event":"workflow_dispatch"}]' | emit
    ;;
  "run view")
    echo "Plan complete (dry-run): no issues created."
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"
}

teardown() {
  rm -rf "${MOCK_BIN:-}"
  rm -f "${GH_LOG:-}"
}

@test "main: dispatches the planner in DRY-RUN and exits OK on a clean run" {
  _install_gh_mock
  export REPO="petry-projects/.github-private"
  export CANARY_DISCUSSION="42"
  export GH_TOKEN="pat"
  export CANARY_POLL_TIMEOUT="5"
  export CANARY_POLL_INTERVAL="1"
  CANARY_OUT="$(mktemp)"
  export CANARY_OUT
  GITHUB_ENV="$(mktemp)"
  export GITHUB_ENV

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  # The dispatch must be a dry-run so the canary creates nothing.
  grep -qF "workflow run initiative-planner.yml" "$GH_LOG"
  grep -qF -- "-f dry_run=true" "$GH_LOG"
  grep -qF -- "-f discussion=42" "$GH_LOG"

  # Status surfaced for the workflow alert step.
  grep -qF "CANARY_STATUS=OK" "$GITHUB_ENV"
  ! grep -qF "CANARY_FAILED=true" "$GITHUB_ENV"

  rm -f "$CANARY_OUT" "$GITHUB_ENV"
}

@test "main: a non-numeric CANARY_DISCUSSION is rejected before any dispatch" {
  _install_gh_mock
  export REPO="petry-projects/.github-private"
  export CANARY_DISCUSSION="42; rm -rf /"
  export GH_TOKEN="pat"

  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "main: INITIATIVE_CANARY_DISCUSSION is used when CANARY_DISCUSSION is unset" {
  _install_gh_mock
  export REPO="petry-projects/.github-private"
  unset CANARY_DISCUSSION
  export INITIATIVE_CANARY_DISCUSSION="99"
  export GH_TOKEN="pat"
  export CANARY_POLL_TIMEOUT="5"
  export CANARY_POLL_INTERVAL="1"
  CANARY_OUT="$(mktemp)"
  export CANARY_OUT
  GITHUB_ENV="$(mktemp)"
  export GITHUB_ENV

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f discussion=99" "$GH_LOG"

  rm -f "$CANARY_OUT" "$GITHUB_ENV"
  unset INITIATIVE_CANARY_DISCUSSION
}

@test "main: exits with error when neither CANARY_DISCUSSION nor INITIATIVE_CANARY_DISCUSSION is set" {
  _install_gh_mock
  export REPO="petry-projects/.github-private"
  unset CANARY_DISCUSSION
  unset INITIATIVE_CANARY_DISCUSSION
  export GH_TOKEN="pat"

  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"INITIATIVE_CANARY_DISCUSSION"* ]]
  [ ! -s "$GH_LOG" ]
}

@test "main: a failing planner run sets CANARY_FAILED and exits non-zero" {
  MOCK_BIN="$(mktemp -d)"
  GH_LOG="$(mktemp)"
  export GH_LOG MOCK_BIN
  export PATH="$MOCK_BIN:$PATH"
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
jqf=""; args=("$@")
for ((i=0;i<${#args[@]};i++)); do [ "${args[i]}" = "--jq" ] && jqf="${args[i+1]}"; done
emit() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
case "$1 $2" in
  "run list")
    echo '[{"databaseId":556,"status":"completed","conclusion":"failure","createdAt":"2026-06-20T06:00:00Z","event":"workflow_dispatch"}]' | emit
    ;;
  "run view") echo "Action failed with error: Unsupported event type: discussion" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"

  export REPO="petry-projects/.github-private"
  export CANARY_DISCUSSION="42"
  export GH_TOKEN="pat"
  export CANARY_POLL_TIMEOUT="5"
  export CANARY_POLL_INTERVAL="1"
  CANARY_OUT="$(mktemp)"; export CANARY_OUT
  GITHUB_ENV="$(mktemp)"; export GITHUB_ENV

  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  grep -qF "CANARY_STATUS=UNSUPPORTED_EVENT" "$GITHUB_ENV"
  grep -qF "CANARY_FAILED=true" "$GITHUB_ENV"

  rm -f "$CANARY_OUT" "$GITHUB_ENV"
}
