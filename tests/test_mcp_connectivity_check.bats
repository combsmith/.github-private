#!/usr/bin/env bats
# Tests for scripts/mcp_connectivity_check.sh — the durable, affirmative
# MCP/Context7 connectivity assertion for the daily PR-review health check
# (#903, part of #676).
#
# Pure helpers (classify / failure decision / allowlist derivation / report)
# are unit-tested directly. main()'s claude invocation is exercised with a
# mocked `claude` on PATH so no network/model call is made.
#
# Run with: bats tests/test_mcp_connectivity_check.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/mcp_connectivity_check.sh"

setup() {
  # shellcheck source=scripts/mcp_connectivity_check.sh
  source "$SCRIPT"
  # Hermetic: never fall back to the repo's real .github/review-mcp.json.
  export REVIEW_MCP_CONFIG_DEFAULT_PATH="$(mktemp -u)"
  unset REVIEW_MCP_CONFIG REVIEW_MCP_ALLOWED_TOOLS REVIEW_MCP_DEBUG 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# classify_mcp_output <output>
# ---------------------------------------------------------------------------

@test "classify_mcp_output: the affirmative handshake is CONNECTED" {
  run classify_mcp_output 'MCP server "context7": Successfully connected (transport: http) in 333ms'
  [ "$status" -eq 0 ]
  [ "$output" = "CONNECTED" ]
}

@test "classify_mcp_output: handshake match is case-insensitive" {
  run classify_mcp_output 'mcp server "context7": successfully connected'
  [ "$output" = "CONNECTED" ]
}

@test "classify_mcp_output: an explicit failure marker is FAILED" {
  run classify_mcp_output 'MCP server "context7" failed to connect after 3 attempts'
  [ "$output" = "FAILED" ]
}

@test "classify_mcp_output: a generic connection failure is FAILED" {
  run classify_mcp_output 'Failed to connect to MCP server'
  [ "$output" = "FAILED" ]
}

@test "classify_mcp_output: output with neither signal is NO_HANDSHAKE" {
  run classify_mcp_output 'some unrelated CLI chatter with no mcp signal'
  [ "$output" = "NO_HANDSHAKE" ]
}

@test "classify_mcp_output: empty output (e.g. a timeout kill) is NO_HANDSHAKE" {
  run classify_mcp_output ""
  [ "$output" = "NO_HANDSHAKE" ]
}

@test "classify_mcp_output: a present handshake wins even alongside later noise" {
  run classify_mcp_output $'MCP server "context7": Successfully connected\nFailed to connect to MCP server other'
  [ "$output" = "CONNECTED" ]
}

# ---------------------------------------------------------------------------
# mcp_check_is_failure <status>
# ---------------------------------------------------------------------------

@test "mcp_check_is_failure: CONNECTED is not a failure" {
  run mcp_check_is_failure "CONNECTED"
  [ "$status" -ne 0 ]
}

@test "mcp_check_is_failure: FAILED is a failure" {
  run mcp_check_is_failure "FAILED"
  [ "$status" -eq 0 ]
}

@test "mcp_check_is_failure: NO_HANDSHAKE is a failure (cannot prove connectivity)" {
  run mcp_check_is_failure "NO_HANDSHAKE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# derive_allowed_tools <config>
# ---------------------------------------------------------------------------

@test "derive_allowed_tools: a single context7 server yields its wildcard allowlist" {
  cfg="$(mktemp)"
  echo '{"mcpServers":{"context7":{"type":"http","url":"https://mcp.context7.com/mcp"}}}' > "$cfg"
  run derive_allowed_tools "$cfg"
  rm -f "$cfg"
  [ "$status" -eq 0 ]
  [ "$output" = "mcp__context7__*" ]
}

@test "derive_allowed_tools: multiple servers are comma-joined" {
  cfg="$(mktemp)"
  echo '{"mcpServers":{"context7":{},"github":{}}}' > "$cfg"
  run derive_allowed_tools "$cfg"
  rm -f "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mcp__context7__*"* ]]
  [[ "$output" == *"mcp__github__*"* ]]
}

@test "derive_allowed_tools: a config with no servers yields empty output" {
  cfg="$(mktemp)"
  echo '{"mcpServers":{}}' > "$cfg"
  run derive_allowed_tools "$cfg"
  rm -f "$cfg"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# mcp_check_report <status> <config> <servers> [today]
# ---------------------------------------------------------------------------

@test "mcp_check_report: CONNECTED renders a passing report naming the server" {
  run mcp_check_report "CONNECTED" ".github/review-mcp.json" "context7" "2026-06-22"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONNECTED"* ]]
  [[ "$output" == *"context7"* ]]
}

@test "mcp_check_report: FAILED renders an alert report" {
  run mcp_check_report "FAILED" ".github/review-mcp.json" "context7" "2026-06-22"
  [[ "$output" == *"FAILED"* ]]
  [[ "$output" == *"unreachable"* ]]
}

# ---------------------------------------------------------------------------
# main() — mocked claude on PATH (no network)
# ---------------------------------------------------------------------------

_install_claude_mock() {
  # $1 = combined stdout/stderr the mock should emit (handshake or failure)
  MOCK_BIN="$(mktemp -d)"
  CLAUDE_LOG="$(mktemp)"
  export MOCK_BIN CLAUDE_LOG
  export PATH="$MOCK_BIN:$PATH"
  export MOCK_CLAUDE_OUT="$1"
  cat > "$MOCK_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAUDE_LOG"
printf '%s\n' "$MOCK_CLAUDE_OUT"
EOF
  chmod +x "$MOCK_BIN/claude"
}

_make_config() {
  CFG="$(mktemp)"
  echo '{"mcpServers":{"context7":{"type":"http","url":"https://mcp.context7.com/mcp"}}}' > "$CFG"
  export CFG REVIEW_MCP_CONFIG="$CFG"
}

teardown() {
  rm -rf "${MOCK_BIN:-}"
  rm -f "${CLAUDE_LOG:-}" "${CFG:-}"
}

@test "main: healthy handshake → exit 0, ::notice::[mcp], engine.sh flags passed" {
  _install_claude_mock 'MCP server "context7": Successfully connected (transport: http) in 333ms'
  _make_config
  GITHUB_ENV="$(mktemp)"; export GITHUB_ENV

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::[mcp]"* ]]
  [[ "$output" == *"Successfully connected"* ]]

  # The probe must use the same flags engine.sh threads.
  grep -qF -- "--mcp-config $CFG" "$CLAUDE_LOG"
  grep -qF -- "--strict-mcp-config" "$CLAUDE_LOG"
  grep -qF -- "--debug mcp" "$CLAUDE_LOG"
  grep -qF -- "mcp__context7__*" "$CLAUDE_LOG"

  grep -qF "MCP_STATUS=CONNECTED" "$GITHUB_ENV"
  ! grep -qF "MCP_FAILED=true" "$GITHUB_ENV" || false
  rm -f "$GITHUB_ENV"
}

@test "main: connection failure → exit 1, ::error::, MCP_FAILED set" {
  _install_claude_mock 'MCP server "context7" failed to connect after 3 attempts'
  _make_config
  GITHUB_ENV="$(mktemp)"; export GITHUB_ENV

  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  grep -qF "MCP_STATUS=FAILED" "$GITHUB_ENV"
  grep -qF "MCP_FAILED=true" "$GITHUB_ENV"
  rm -f "$GITHUB_ENV"
}

@test "main: no handshake at all → exit 1 (silent outage is a failure, not a pass)" {
  _install_claude_mock 'just some output, no handshake line whatsoever'
  _make_config
  GITHUB_ENV="$(mktemp)"; export GITHUB_ENV

  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  grep -qF "MCP_STATUS=NO_HANDSHAKE" "$GITHUB_ENV"
  rm -f "$GITHUB_ENV"
}

@test "main: MCP not configured (config file absent) → skip/no-op, exit 0" {
  _install_claude_mock 'should not be called'
  export REVIEW_MCP_CONFIG="$(mktemp -u)"  # explicit path that does not exist
  GITHUB_ENV="$(mktemp)"; export GITHUB_ENV

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]] || [[ "$output" == *"no MCP config"* ]]
  # The probe must NOT have been invoked when MCP is not configured.
  [ ! -s "$CLAUDE_LOG" ]
  rm -f "$GITHUB_ENV"
}

@test "main: jq missing → exit 1, ::error:: (no silent skip of the assertion)" {
  _install_claude_mock 'MCP server "context7": Successfully connected'
  _make_config
  GITHUB_ENV="$(mktemp)"; export GITHUB_ENV

  # Restrict PATH so jq is unresolvable while keeping bash + the claude mock,
  # which is all main() needs before the jq guard runs.
  local restricted; restricted="$(mktemp -d)"
  ln -s "$(command -v bash)" "$restricted/bash"
  ln -s "$MOCK_BIN/claude" "$restricted/claude"

  PATH="$restricted" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"jq"* ]]

  rm -rf "$restricted"
  rm -f "$GITHUB_ENV"
}

@test "main: REVIEW_MCP_ALLOWED_TOOLS overrides the derived allowlist" {
  _install_claude_mock 'MCP server "context7": Successfully connected'
  _make_config
  export REVIEW_MCP_ALLOWED_TOOLS="mcp__context7__resolve-library-id"
  GITHUB_ENV="$(mktemp)"; export GITHUB_ENV

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "mcp__context7__resolve-library-id" "$CLAUDE_LOG"
  rm -f "$GITHUB_ENV"
}
