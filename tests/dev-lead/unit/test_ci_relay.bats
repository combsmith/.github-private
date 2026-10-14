#!/usr/bin/env bats
# Unit tests for scripts/dev-lead-ci-relay.sh
# Covers: non-empty pull_requests (GHA path), empty pull_requests (App fallback),
# fork rejection, open-PR filtering, and no-PR-found skip.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
CI_RELAY_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-ci-relay.sh"
GH_STUBS_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/stubs"

setup() {
  export GITHUB_OUTPUT
  GITHUB_OUTPUT="$(mktemp)"
  STUB_BIN_DIR="$(mktemp -d)"
  cp "$GH_STUBS_DIR/gh" "$STUB_BIN_DIR/gh"
  chmod +x "$STUB_BIN_DIR/gh"
  export PATH="$STUB_BIN_DIR:$PATH"
  export STUB_BIN_DIR
  export REPO_FULL_NAME="petry-projects/.github-private"
  export CHECK_RUN_HEAD_SHA="abc123def456"
  export GH_STUB_PR_NUMBER="42"
  export GH_STUB_PR_HEAD_REPO="petry-projects/.github-private"
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
  rm -rf "$STUB_BIN_DIR"
}

_out() { grep "^${1}=" "$GITHUB_OUTPUT" | cut -d= -f2- | head -1; }

# ── non-empty pull_requests (GitHub Actions check_run) ────────────────────────

@test "ci-relay: non-empty pull_requests, same repo → should_relay=true" {
  export CHECK_RUN_PRS='[{"number":42,"head":{"repo":{"url":"https://api.github.com/repos/petry-projects/.github-private"}}}]'

  run bash "$CI_RELAY_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_out should_relay)" = "true" ]
  [ "$(_out pr_number)" = "42" ]
}

@test "ci-relay: non-empty pull_requests, fork repo URL → should_relay=false" {
  export CHECK_RUN_PRS='[{"number":7,"head":{"repo":{"url":"https://api.github.com/repos/forker/other-repo"}}}]'

  run bash "$CI_RELAY_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_out should_relay)" = "false" ]
}

# ── empty pull_requests (GitHub App check_run — commits-to-pulls fallback) ────

@test "ci-relay: empty pull_requests, API returns open PR → should_relay=true" {
  export CHECK_RUN_PRS='[]'
  export GH_STUB_PR_NUMBER="99"
  export GH_STUB_PR_HEAD_REPO="petry-projects/.github-private"

  run bash "$CI_RELAY_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_out should_relay)" = "true" ]
  [ "$(_out pr_number)" = "99" ]
}

@test "ci-relay: empty pull_requests, API returns no PRs → should_relay=false" {
  export CHECK_RUN_PRS='[]'
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"commits/"*"/pulls"*) echo "[]" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$CI_RELAY_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_out should_relay)" = "false" ]
}

@test "ci-relay: empty pull_requests, API returns fork PR → should_relay=false" {
  export CHECK_RUN_PRS='[]'
  export GH_STUB_PR_NUMBER="55"
  export GH_STUB_PR_HEAD_REPO="forker/.github-private"

  run bash "$CI_RELAY_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_out should_relay)" = "false" ]
}

@test "ci-relay: empty pull_requests, API returns only merged PR → should_relay=false" {
  export CHECK_RUN_PRS='[]'
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"commits/"*"/pulls"*) echo '[{"number":33,"state":"closed","head":{"repo":{"full_name":"petry-projects/.github-private"}}}]' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$CI_RELAY_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_out should_relay)" = "false" ]
}

@test "ci-relay: empty pull_requests, API failure → should_relay=false" {
  export CHECK_RUN_PRS='[]'
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"commits/"*"/pulls"*) exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$CI_RELAY_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_out should_relay)" = "false" ]
}
