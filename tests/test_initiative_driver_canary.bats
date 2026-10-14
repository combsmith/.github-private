#!/usr/bin/env bats
# Tests for scripts/initiative_driver_canary.sh — the post-merge canary for the
# cross-repo release path (#885, epic #882). It dry-run-dispatches
# initiative-driver.yml against a fixture target repo + epic and alerts if the
# run fails OR — for a configured fixture — if the run produces no
# "READY (dry-run, not labeling)" decision (a hollow-green cross-repo break).
#
# Pure helpers (classify / alert decision / report) are unit-tested directly.
# main()'s dry-run dispatch + poll is exercised with a mocked gh CLI so no
# network call is made and the canary creates/labels nothing.
#
# Run with: bats tests/test_initiative_driver_canary.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/initiative_driver_canary.sh"

setup() {
  # shellcheck source=scripts/initiative_driver_canary.sh
  source "$SCRIPT"
}

# ---------------------------------------------------------------------------
# classify_canary_run <conclusion> <logs>
# ---------------------------------------------------------------------------

@test "classify_canary_run: success with a READY decision is OK" {
  run classify_canary_run "success" "  #5 — READY (dry-run, not labeling)."
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "classify_canary_run: success WITHOUT a READY decision is HOLLOW_GREEN" {
  # The run was green but the cross-repo gate/blocked_by resolved to nothing.
  run classify_canary_run "success" "Epic #42: 0 open sub-issue(s); in-flight=0; cap=2."
  [ "$status" -eq 0 ]
  [ "$output" = "HOLLOW_GREEN" ]
}

@test "classify_canary_run: a failing conclusion is FAILED (even with a READY line)" {
  run classify_canary_run "failure" "  #5 — READY (dry-run, not labeling)."
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

# ---------------------------------------------------------------------------
# canary_is_failure <status> — alert decision
# ---------------------------------------------------------------------------

@test "canary_is_failure: OK does not alert" {
  run canary_is_failure "OK"
  [ "$status" -ne 0 ]
}

@test "canary_is_failure: every non-OK status alerts" {
  for s in HOLLOW_GREEN FAILED NO_RUN; do
    run canary_is_failure "$s"
    [ "$status" -eq 0 ]
  done
}

# ---------------------------------------------------------------------------
# canary_report <status> <repo> <target> <epic> <run_url> [today]
# ---------------------------------------------------------------------------

@test "canary_report: OK report names the path, target and epic" {
  run canary_report "OK" "petry-projects/.github-private" "petry-projects/fixture" "42" "https://x/run/1" "2026-06-21"
  [ "$status" -eq 0 ]
  [[ "$output" == *"petry-projects/fixture"* ]]
  [[ "$output" == *"#42"* ]]
  [[ "$output" == *"2026-06-21"* ]]
}

@test "canary_report: the hollow-green status surfaces the no-READY hint" {
  run canary_report "HOLLOW_GREEN" "petry-projects/.github-private" "petry-projects/fixture" "42" "https://x/run/1"
  [[ "$output" == *"READY (dry-run, not labeling)"* ]]
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
    echo '[{"databaseId":555,"status":"completed","conclusion":"success","createdAt":"2026-06-21T07:00:00Z","event":"workflow_dispatch"}]' | emit
    ;;
  "run view")
    # The driver's dry-run READY decision for the fixture target.
    echo "Epic #42: 1 open sub-issue(s); in-flight=0; cap=2."
    echo "  #5 — READY (dry-run, not labeling)."
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

@test "main: dispatches the driver in DRY-RUN against the fixture and exits OK" {
  _install_gh_mock
  export REPO="petry-projects/.github-private"
  export CANARY_TARGET="petry-projects/fixture"
  export CANARY_EPIC="42"
  export GH_TOKEN="pat"
  export CANARY_POLL_TIMEOUT="5"
  export CANARY_POLL_INTERVAL="1"
  CANARY_OUT="$(mktemp)"; export CANARY_OUT
  GITHUB_ENV="$(mktemp)"; export GITHUB_ENV

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  # The dispatch must be a dry-run targeting the fixture so it creates/labels nothing.
  grep -qF "workflow run initiative-driver.yml" "$GH_LOG"
  grep -qF -- "-f dry_run=true" "$GH_LOG"
  grep -qF -- "-f target_repo=petry-projects/fixture" "$GH_LOG"
  grep -qF -- "-f epic=42" "$GH_LOG"

  # Status surfaced for the workflow alert step.
  grep -qF "CANARY_STATUS=OK" "$GITHUB_ENV"
  ! grep -qF "CANARY_FAILED=true" "$GITHUB_ENV"

  rm -f "$CANARY_OUT" "$GITHUB_ENV"
}

@test "main: a configured run with no READY decision is a HOLLOW_GREEN failure" {
  MOCK_BIN="$(mktemp -d)"; GH_LOG="$(mktemp)"
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
    echo '[{"databaseId":777,"status":"completed","conclusion":"success","createdAt":"2026-06-21T07:00:00Z","event":"workflow_dispatch"}]' | emit
    ;;
  "run view") echo "Epic #42: 0 open sub-issue(s); in-flight=0; cap=2." ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"

  export REPO="petry-projects/.github-private"
  export CANARY_TARGET="petry-projects/fixture"
  export CANARY_EPIC="42"
  export GH_TOKEN="pat"
  export CANARY_POLL_TIMEOUT="5"
  export CANARY_POLL_INTERVAL="1"
  CANARY_OUT="$(mktemp)"; export CANARY_OUT
  GITHUB_ENV="$(mktemp)"; export GITHUB_ENV

  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  grep -qF "CANARY_STATUS=HOLLOW_GREEN" "$GITHUB_ENV"
  grep -qF "CANARY_FAILED=true" "$GITHUB_ENV"

  rm -f "$CANARY_OUT" "$GITHUB_ENV"
}

@test "main: a failing driver run sets CANARY_FAILED and exits non-zero" {
  MOCK_BIN="$(mktemp -d)"; GH_LOG="$(mktemp)"
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
    echo '[{"databaseId":556,"status":"completed","conclusion":"failure","createdAt":"2026-06-21T07:00:00Z","event":"workflow_dispatch"}]' | emit
    ;;
  "run view") echo "boom" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"

  export REPO="petry-projects/.github-private"
  export CANARY_TARGET="petry-projects/fixture"
  export CANARY_EPIC="42"
  export GH_TOKEN="pat"
  export CANARY_POLL_TIMEOUT="5"
  export CANARY_POLL_INTERVAL="1"
  CANARY_OUT="$(mktemp)"; export CANARY_OUT
  GITHUB_ENV="$(mktemp)"; export GITHUB_ENV

  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  grep -qF "CANARY_STATUS=FAILED" "$GITHUB_ENV"
  grep -qF "CANARY_FAILED=true" "$GITHUB_ENV"

  rm -f "$CANARY_OUT" "$GITHUB_ENV"
}

@test "main: a non-numeric CANARY_EPIC is rejected before any dispatch" {
  _install_gh_mock
  export REPO="petry-projects/.github-private"
  export CANARY_TARGET="petry-projects/fixture"
  export CANARY_EPIC="42; rm -rf /"
  export GH_TOKEN="pat"

  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "main: a malformed CANARY_TARGET is rejected before any dispatch" {
  _install_gh_mock
  export REPO="petry-projects/.github-private"
  export CANARY_TARGET="not a repo; rm -rf /"
  export CANARY_EPIC="42"
  export GH_TOKEN="pat"

  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "main: INITIATIVE_DRIVER_CANARY_* are used when CANARY_* are unset" {
  _install_gh_mock
  export REPO="petry-projects/.github-private"
  unset CANARY_TARGET CANARY_EPIC
  export INITIATIVE_DRIVER_CANARY_TARGET="petry-projects/fixture"
  export INITIATIVE_DRIVER_CANARY_EPIC="99"
  export GH_TOKEN="pat"
  export CANARY_POLL_TIMEOUT="5"
  export CANARY_POLL_INTERVAL="1"
  CANARY_OUT="$(mktemp)"; export CANARY_OUT
  GITHUB_ENV="$(mktemp)"; export GITHUB_ENV

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f target_repo=petry-projects/fixture" "$GH_LOG"
  grep -qF -- "-f epic=99" "$GH_LOG"

  rm -f "$CANARY_OUT" "$GITHUB_ENV"
  unset INITIATIVE_DRIVER_CANARY_TARGET INITIATIVE_DRIVER_CANARY_EPIC
}

@test "main: exits with error when the fixture target/epic are unset" {
  _install_gh_mock
  export REPO="petry-projects/.github-private"
  unset CANARY_TARGET CANARY_EPIC
  unset INITIATIVE_DRIVER_CANARY_TARGET INITIATIVE_DRIVER_CANARY_EPIC
  export GH_TOKEN="pat"

  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"INITIATIVE_DRIVER_CANARY_TARGET"* ]]
  [ ! -s "$GH_LOG" ]
}
