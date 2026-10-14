#!/usr/bin/env bats
# Tests for scripts/pr_review_canary.sh — the post-merge canary for the ring-0
# pr-review-trigger caller stub (#1256, epic #1052 Part D).
#
# It fires a DRY-RUN dispatch of pr-review-trigger.yml and fails LOUD if the
# resulting run ends in `startup_failure` — the exact conclusion produced when a
# channel-pinned caller stub forwards an input its pinned channel does not yet
# declare (the #1034 channel-skew defect), which nothing in PR CI exercises.
#
# Pure helpers (classify / alert decision / report) are unit-tested directly.
# main()'s dry-run dispatch + poll is exercised with a mocked gh CLI so no
# network call is made and the canary submits nothing.
#
# Run with: bats tests/pr_review_canary.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/pr_review_canary.sh"

setup() {
  # shellcheck source=scripts/pr_review_canary.sh
  source "$SCRIPT"
}

# ---------------------------------------------------------------------------
# classify_canary_run <conclusion>
# ---------------------------------------------------------------------------

@test "classify_canary_run: a startup_failure conclusion is STARTUP_FAILURE" {
  # This is the #1034 channel-skew fingerprint the canary exists to catch.
  run classify_canary_run "startup_failure"
  [ "$status" -eq 0 ]
  [ "$output" = "STARTUP_FAILURE" ]
}

@test "classify_canary_run: success is OK" {
  run classify_canary_run "success"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "classify_canary_run: a plain failure conclusion is FAILED" {
  run classify_canary_run "failure"
  [ "$output" = "FAILED" ]
}

@test "classify_canary_run: timed_out / cancelled are FAILED" {
  run classify_canary_run "timed_out"
  [ "$output" = "FAILED" ]
  run classify_canary_run "cancelled"
  [ "$output" = "FAILED" ]
}

@test "classify_canary_run: an empty conclusion (no run found) is NO_RUN" {
  run classify_canary_run ""
  [ "$output" = "NO_RUN" ]
}

@test "classify_canary_run: a null conclusion (still running) is NO_RUN" {
  run classify_canary_run "null"
  [ "$output" = "NO_RUN" ]
}

# ---------------------------------------------------------------------------
# canary_is_failure <status> — alert decision
#
# The canary exists to catch the #1034 channel-skew defect, whose sole
# fingerprint is `startup_failure`. Only STARTUP_FAILURE fails the canary loud.
# Once the dispatched run gets PAST startup, channel skew is ruled out — so a
# downstream FAILED (the dry-run review cascade failed against a real fleet PR
# for an unrelated reason) and NO_RUN (no completed run observed) must NOT trip
# the canary, or unrelated flakes produce false Fleet Monitor trackers (#1612).
# ---------------------------------------------------------------------------

@test "canary_is_failure: OK does not alert" {
  run canary_is_failure "OK"
  [ "$status" -ne 0 ]
}

@test "canary_is_failure: STARTUP_FAILURE is the only status that alerts" {
  run canary_is_failure "STARTUP_FAILURE"
  [ "$status" -eq 0 ]
}

@test "canary_is_failure: a downstream FAILED does not alert (channel skew ruled out)" {
  # The dispatched run got past startup — a non-startup failure in the review
  # cascade is unrelated to the channel-skew defect this canary guards.
  run canary_is_failure "FAILED"
  [ "$status" -ne 0 ]
}

@test "canary_is_failure: NO_RUN does not alert (cannot confirm channel skew)" {
  run canary_is_failure "NO_RUN"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# canary_report <status> <repo> <run_url> [today]
# ---------------------------------------------------------------------------

@test "canary_report: OK report names the pr-review-trigger path" {
  run canary_report "OK" "petry-projects/.github-private" "https://x/run/1" "2026-07-15"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pr-review-trigger"* ]]
  [[ "$output" == *"2026-07-15"* ]]
}

@test "canary_report: the startup_failure status surfaces the channel-skew hint" {
  run canary_report "STARTUP_FAILURE" "petry-projects/.github-private" "https://x/run/1" "2026-07-15"
  [[ "$output" == *"startup_failure"* ]]
  [[ "$output" == *"https://x/run/1"* ]]
}

@test "canary_report: a FAILED report does not overclaim channel skew is ruled out (non-fatal)" {
  # A cancelled/timed_out run (both classified FAILED) can end before the
  # reusable call reaches startup, so the report must not assert skew is ruled
  # out — only that FAILED is not the startup_failure fingerprint this canary gates on.
  run canary_report "FAILED" "petry-projects/.github-private" "https://x/run/1" "2026-07-15"
  [ "$status" -eq 0 ]
  [[ "$output" == *"startup_failure"* ]]
  [[ "$output" != *"**ruled out**"* ]]
}

# ---------------------------------------------------------------------------
# main() — mocked gh, asserts the DRY-RUN dispatch and a clean exit
# ---------------------------------------------------------------------------

_install_gh_mock() {
  # $1 — conclusion the mocked `run list` reports for the dispatched run.
  local conclusion="${1:-success}"
  MOCK_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/mock_bin.XXXXXX")"
  GH_LOG="$(mktemp "$BATS_TEST_TMPDIR/gh_log.XXXXXX")"
  export GH_LOG MOCK_BIN
  export PATH="$MOCK_BIN:$PATH"
  cat > "$MOCK_BIN/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
# Apply the real --jq filter (as gh would) so main()'s jq is exercised.
jqf=""; args=("\$@")
for ((i=0;i<\${#args[@]};i++)); do [ "\${args[i]}" = "--jq" ] && jqf="\${args[i+1]}"; done
emit() { if [ -n "\$jqf" ]; then jq -r "\$jqf"; else cat; fi; }
case "\$1 \$2" in
  "workflow run") exit 0 ;;
  "run list")
    echo '[{"databaseId":777,"status":"completed","conclusion":"${conclusion}","createdAt":"2026-07-15T06:00:00Z","event":"workflow_dispatch"}]' | emit
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

@test "main: dispatches pr-review-trigger in DRY-RUN and exits OK on a clean run" {
  _install_gh_mock "success"
  export REPO="petry-projects/.github-private"
  export GH_TOKEN="pat"
  export CANARY_POLL_TIMEOUT="5"
  export CANARY_POLL_INTERVAL="1"
  CANARY_OUT="$(mktemp "$BATS_TEST_TMPDIR/canary_out.XXXXXX")"; export CANARY_OUT
  GITHUB_ENV="$(mktemp "$BATS_TEST_TMPDIR/github_env.XXXXXX")"; export GITHUB_ENV

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  # The dispatch must be a dry-run so the canary submits nothing.
  grep -qF "workflow run pr-review-trigger.yml" "$GH_LOG"
  grep -qF -- "-f dry_run=true" "$GH_LOG"

  grep -qF "CANARY_STATUS=OK" "$GITHUB_ENV"
  run grep -qF "CANARY_FAILED=true" "$GITHUB_ENV"
  [ "$status" -eq 1 ]

  rm -f "$CANARY_OUT" "$GITHUB_ENV"
}

@test "main: a startup_failure run sets CANARY_FAILED and exits non-zero" {
  _install_gh_mock "startup_failure"
  export REPO="petry-projects/.github-private"
  export GH_TOKEN="pat"
  export CANARY_POLL_TIMEOUT="5"
  export CANARY_POLL_INTERVAL="1"
  CANARY_OUT="$(mktemp "$BATS_TEST_TMPDIR/canary_out.XXXXXX")"; export CANARY_OUT
  GITHUB_ENV="$(mktemp "$BATS_TEST_TMPDIR/github_env.XXXXXX")"; export GITHUB_ENV

  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  grep -qF "CANARY_STATUS=STARTUP_FAILURE" "$GITHUB_ENV"
  grep -qF "CANARY_FAILED=true" "$GITHUB_ENV"

  rm -f "$CANARY_OUT" "$GITHUB_ENV"
}

@test "main: a plain downstream failing run does NOT fail the canary (channel skew ruled out)" {
  # The dry-run dispatch got past startup, so the channel-skew defect is ruled
  # out even though the review cascade concluded `failure` against a real fleet
  # PR. The canary must stay green so it does not raise a false Fleet Monitor
  # tracker (#1612) — only startup_failure fails it loud.
  _install_gh_mock "failure"
  export REPO="petry-projects/.github-private"
  export GH_TOKEN="pat"
  export CANARY_POLL_TIMEOUT="5"
  export CANARY_POLL_INTERVAL="1"
  CANARY_OUT="$(mktemp "$BATS_TEST_TMPDIR/canary_out.XXXXXX")"; export CANARY_OUT
  GITHUB_ENV="$(mktemp "$BATS_TEST_TMPDIR/github_env.XXXXXX")"; export GITHUB_ENV

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF "CANARY_STATUS=FAILED" "$GITHUB_ENV"
  run grep -qF "CANARY_FAILED=true" "$GITHUB_ENV"
  [ "$status" -eq 1 ]

  rm -f "$CANARY_OUT" "$GITHUB_ENV"
}

@test "main: exits with error when GH_TOKEN is unset (dispatch would never start a run)" {
  _install_gh_mock "success"
  export REPO="petry-projects/.github-private"
  unset GH_TOKEN
  export CANARY_POLL_TIMEOUT="5"
  export CANARY_POLL_INTERVAL="1"

  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GH_TOKEN"* ]]
  # No dispatch may be attempted without a token.
  [ ! -s "$GH_LOG" ]
}
