#!/usr/bin/env bats
# Unit tests for engine.sh — opt-in MCP config threading (issue #677).
#
# Verifies that REVIEW_MCP_CONFIG / REVIEW_MCP_ALLOWED_TOOLS thread the MCP
# flags (--mcp-config <file> --strict-mcp-config) and merged --allowed-tools
# into ONLY the claude branch of the agentic (run_agentic) and rubber-duck
# (run_duck) tiers — never the triage tier — and that the default (knob unset)
# behavior is byte-for-byte unchanged.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"

  unset CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN CLAUDE_AUDIT_MODEL_CHAIN
  unset CLAUDE_ACTION_MODEL_CHAIN CLAUDE_SINGLE_MODEL_CHAIN
  unset REVIEW_MCP_CONFIG REVIEW_MCP_ALLOWED_TOOLS REVIEW_MCP_CONFIG_DEFAULT_PATH REVIEW_MCP_DEBUG
  # TOKEN_LOG_FILE enables JSON-mode capture (--output-format json) in _claude_chain_invoke.
  # In JSON mode the stub wraps its response in a JSON envelope, which breaks the plain-text
  # grep inside _emit_mcp_failure_warning (the "Successfully connected" text ends up
  # backslash-escaped inside the .result field and the pattern doesn't match).  In
  # production the MCP handshake lines come from claude's stderr — never JSON-wrapped —
  # so unsetting here reproduces the correct signal path without disabling any real
  # production behaviour.
  unset TOKEN_LOG_FILE ENGINE_USAGE_JSON

  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini"
  export PATH="$STUB_BIN_DIR:$PATH"
  export STUB_BIN_DIR

  TEST_PROMPT="$(mktemp)"
  echo "test prompt content" > "$TEST_PROMPT"
  export TEST_PROMPT

  ARGS_RECORD="$(mktemp)"
  export STUB_ENGINE_RECORD_ARGS="$ARGS_RECORD"

  # A readable MCP config file the helper can point at.
  MCP_CONFIG_FILE="$(mktemp)"
  echo '{"mcpServers":{}}' > "$MCP_CONFIG_FILE"
  export MCP_CONFIG_FILE

  export DEV_LEAD_DRY_RUN="false"
  export STUB_ENGINE_EXIT=0
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$TEST_PROMPT" "$ARGS_RECORD" "$MCP_CONFIG_FILE"
  rm -rf "$STUB_BIN_DIR"
  unset STUB_ENGINE_RECORD_ARGS STUB_ENGINE_EXIT
  unset REVIEW_MCP_CONFIG REVIEW_MCP_ALLOWED_TOOLS REVIEW_MCP_CONFIG_DEFAULT_PATH REVIEW_MCP_DEBUG
}

_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT"
}

# ── Default (knob unset): behavior unchanged ──────────────────────────────────

@test "agentic: no MCP knob → no MCP flags, default allowed-tools unchanged" {
  # The repo ships .github/review-mcp.json, the conventional default, so "no knob"
  # means MCP on unless the default path is pointed away from it (#2263).
  export REVIEW_MCP_CONFIG_DEFAULT_PATH="$(mktemp -u)"  # no conventional file
  _source_engine "claude"
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  [ "$status" -eq 0 ]
  ! grep -q -- "--mcp-config" "$ARGS_RECORD" || false
  ! grep -q -- "--strict-mcp-config" "$ARGS_RECORD" || false
  grep -q -- "--allowed-tools Bash,Read,Grep,Glob" "$ARGS_RECORD"
}

@test "agentic: empty REVIEW_MCP_CONFIG → no MCP flags" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG=""
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  [ "$status" -eq 0 ]
  ! grep -q -- "--mcp-config" "$ARGS_RECORD"
}

@test "agentic: REVIEW_MCP_CONFIG pointing to unreadable file → no MCP flags" {
  _source_engine "claude"
  local unreadable_file
  unreadable_file="$(mktemp)"
  chmod 000 "$unreadable_file"
  export REVIEW_MCP_CONFIG="$unreadable_file"
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  chmod 600 "$unreadable_file"
  rm -f "$unreadable_file"
  [ "$status" -eq 0 ]
  ! grep -q -- "--mcp-config" "$ARGS_RECORD" || false
  grep -q -- "--allowed-tools Bash,Read,Grep,Glob" "$ARGS_RECORD"
}

@test "agentic: REVIEW_MCP_CONFIG pointing to a directory → no MCP flags" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$(mktemp -d)"
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  rmdir "$REVIEW_MCP_CONFIG"
  [ "$status" -eq 0 ]
  ! grep -q -- "--mcp-config" "$ARGS_RECORD" || false
  grep -q -- "--allowed-tools Bash,Read,Grep,Glob" "$ARGS_RECORD"
}

# ── run_persona: tool posture must mirror the live persona runtime ─────────────
# persona-runner-reusable.yml grants `--allowedTools Bash` only. The eval-parity
# tier (#1686) must score that SAME tool posture, not run_agentic's default
# review set (Bash,Read,Grep,Glob), or the promotion gate measures a more
# tool-capable artifact than the one that ships.

@test "persona: run_persona restricts tools to Bash (matches --allowedTools Bash)" {
  _source_engine "claude"
  run run_persona "$TEST_PROMPT"
  [ "$status" -eq 0 ]
  grep -q -- "--allowed-tools Bash" "$ARGS_RECORD"
  # Must NOT widen to the full review posture.
  ! grep -q -- "--allowed-tools Bash,Read,Grep,Glob" "$ARGS_RECORD"
}

@test "agentic: explicit allowed_tools arg overrides the default review posture" {
  _source_engine "claude"
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep" "Bash"
  [ "$status" -eq 0 ]
  grep -q -- "--allowed-tools Bash" "$ARGS_RECORD"
  ! grep -q -- "--allowed-tools Bash,Read,Grep,Glob" "$ARGS_RECORD"
}

@test "persona: MCP knobs set → run_persona still passes EXACTLY --allowed-tools Bash (#1696)" {
  # The live persona workflow grants no MCP tools. Even with the opt-in MCP knobs
  # set, the parity tier must not widen the allowlist to Bash,<MCP tools> — else
  # the gate scores a more tool-capable artifact than production runs.
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export REVIEW_MCP_ALLOWED_TOOLS="mcp__context7__*"
  run run_persona "$TEST_PROMPT"
  [ "$status" -eq 0 ]
  # Exactly Bash: present, and NOT followed by a comma-appended MCP tool.
  grep -q -- "--allowed-tools Bash" "$ARGS_RECORD"
  ! grep -q -- "--allowed-tools Bash," "$ARGS_RECORD" || false
  # And the MCP config flags themselves must not be threaded for persona parity.
  ! grep -q -- "--mcp-config" "$ARGS_RECORD" || false
  ! grep -q -- "--strict-mcp-config" "$ARGS_RECORD"
}

# ── run_persona: environment boundary is enforced outside the model prompt ─────
# The eval feeds an UNTRUSTED held-out case into the prompt and the parity
# posture grants the Bash tool. A prompt-injected shell command must not be able
# to read a GitHub token or use it to write the repo / hit the API. run_persona
# enforces this OUTSIDE the prompt by scrubbing every GitHub credential from the
# environment the engine (and therefore any Bash command it runs) inherits. This
# is the integration test that proves the boundary holds at the environment level,
# not merely as an in-prompt instruction the model could ignore (#1696).

@test "persona: GitHub credentials are scrubbed from the engine environment (#1696)" {
  _source_engine "claude"
  # Replace the recording claude stub with one that captures the GitHub-credential
  # env vars it was actually invoked with — this is what an injected Bash command
  # spawned by the model would see.
  local envrec
  envrec="$(mktemp)"
  cat >"$STUB_BIN_DIR/claude" <<SH
#!/usr/bin/env bash
{
  printf 'GH_TOKEN=[%s]\n' "\${GH_TOKEN:-}"
  printf 'GITHUB_TOKEN=[%s]\n' "\${GITHUB_TOKEN:-}"
  printf 'GH_ENTERPRISE_TOKEN=[%s]\n' "\${GH_ENTERPRISE_TOKEN:-}"
  printf 'GITHUB_ENTERPRISE_TOKEN=[%s]\n' "\${GITHUB_ENTERPRISE_TOKEN:-}"
} >"$envrec"
printf '%s\n' "stub engine response"
SH
  chmod +x "$STUB_BIN_DIR/claude"

  # A hostile environment: real-looking GitHub credentials are present in the
  # parent shell, exactly as they would be on a CI runner.
  export GH_TOKEN="ghp_shouldnotleak"
  export GITHUB_TOKEN="ghs_shouldnotleak"
  export GH_ENTERPRISE_TOKEN="ght_shouldnotleak"
  export GITHUB_ENTERPRISE_TOKEN="ghe_shouldnotleak"

  run run_persona "$TEST_PROMPT"
  [ "$status" -eq 0 ]

  # The engine (and any Bash command it spawns) saw NONE of the credentials.
  grep -q '^GH_TOKEN=\[\]$' "$envrec"
  grep -q '^GITHUB_TOKEN=\[\]$' "$envrec"
  grep -q '^GH_ENTERPRISE_TOKEN=\[\]$' "$envrec"
  grep -q '^GITHUB_ENTERPRISE_TOKEN=\[\]$' "$envrec"
  ! grep -q 'shouldnotleak' "$envrec" || false

  # The scrub is scoped to the subshell: the parent environment is untouched.
  [ "$GH_TOKEN" = "ghp_shouldnotleak" ]
  [ "$GITHUB_TOKEN" = "ghs_shouldnotleak" ]

  unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
}

@test "persona: non-claude engine → run_persona fails fast, no engine call (#1696)" {
  # Gemini ignores --allowed-tools and copilot runs --yolo, so neither reproduces
  # the Claude Opus + Bash-only persona posture. run_persona must refuse rather
  # than gate a differently-modelled, more tool-capable artifact.
  _source_engine "gemini"
  run run_persona "$TEST_PROMPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"REVIEW_ENGINE=claude"* ]]
  # It bailed before invoking any engine.
  [ ! -s "$ARGS_RECORD" ]
}

# ── Knob set: MCP flags threaded into agentic ────────────────────────────────

@test "agentic: REVIEW_MCP_CONFIG set → MCP flags appended to claude call" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  [ "$status" -eq 0 ]
  grep -q -- "--mcp-config $MCP_CONFIG_FILE" "$ARGS_RECORD"
  grep -q -- "--strict-mcp-config" "$ARGS_RECORD"
}

@test "agentic: REVIEW_MCP_ALLOWED_TOOLS merged into --allowed-tools" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export REVIEW_MCP_ALLOWED_TOOLS="mcp__context7__*"
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  [ "$status" -eq 0 ]
  grep -q -- "--allowed-tools Bash,Read,Grep,Glob,mcp__context7__\*" "$ARGS_RECORD"
}

@test "agentic: MCP config set but no allowed-tools knob → base allowed-tools kept" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  [ "$status" -eq 0 ]
  grep -q -- "--allowed-tools Bash,Read,Grep,Glob" "$ARGS_RECORD"
  ! grep -q -- "--allowed-tools Bash,Read,Grep,Glob," "$ARGS_RECORD"
}

# ── Knob set: MCP flags threaded into duck ───────────────────────────────────

@test "duck: REVIEW_MCP_CONFIG set → MCP flags appended to claude duck call" {
  _source_engine "claude"
  export DUCK_ENGINE="claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export REVIEW_MCP_ALLOWED_TOOLS="mcp__context7__*"
  run run_duck "$TEST_PROMPT" "claude-sonnet-4-6"
  [ "$status" -eq 0 ]
  grep -q -- "--mcp-config $MCP_CONFIG_FILE" "$ARGS_RECORD"
  grep -q -- "--strict-mcp-config" "$ARGS_RECORD"
  grep -q -- "--allowed-tools Bash,Read,Grep,Glob,mcp__context7__\*" "$ARGS_RECORD"
  # The duck tier's existing --max-turns flag must still be present.
  grep -q -- "--max-turns 25" "$ARGS_RECORD"
}

@test "duck: no MCP knob → no MCP flags on claude duck call" {
  export REVIEW_MCP_CONFIG_DEFAULT_PATH="$(mktemp -u)"  # no conventional file (#2263)
  _source_engine "claude"
  export DUCK_ENGINE="claude"
  run run_duck "$TEST_PROMPT" "claude-sonnet-4-6"
  [ "$status" -eq 0 ]
  ! grep -q -- "--mcp-config" "$ARGS_RECORD" || false
  grep -q -- "--allowed-tools Bash,Read,Grep,Glob" "$ARGS_RECORD"
}

# ── Conventional committed path fallback (issue #679) ────────────────────────

@test "default path: no env + conventional file present → MCP flags use conventional path" {
  local conv_file
  conv_file="$(mktemp)"
  echo '{"mcpServers":{}}' > "$conv_file"
  export REVIEW_MCP_CONFIG_DEFAULT_PATH="$conv_file"
  _source_engine "claude"
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  rm -f "$conv_file"
  [ "$status" -eq 0 ]
  grep -q -- "--mcp-config $conv_file" "$ARGS_RECORD"
  grep -q -- "--strict-mcp-config" "$ARGS_RECORD"
}

@test "default path: no env + conventional file absent → no MCP flags (default unchanged)" {
  export REVIEW_MCP_CONFIG_DEFAULT_PATH="$(mktemp -u)"  # path that does not exist
  _source_engine "claude"
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  [ "$status" -eq 0 ]
  ! grep -q -- "--mcp-config" "$ARGS_RECORD" || false
  grep -q -- "--allowed-tools Bash,Read,Grep,Glob" "$ARGS_RECORD"
}

@test "default path: explicit REVIEW_MCP_CONFIG takes precedence over conventional path" {
  local conv_file
  conv_file="$(mktemp)"
  echo '{"mcpServers":{"conv":{}}}' > "$conv_file"
  export REVIEW_MCP_CONFIG_DEFAULT_PATH="$conv_file"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  _source_engine "claude"
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  rm -f "$conv_file"
  [ "$status" -eq 0 ]
  grep -q -- "--mcp-config $MCP_CONFIG_FILE" "$ARGS_RECORD"
  ! grep -q -- "--mcp-config $conv_file" "$ARGS_RECORD"
}

@test "default path: explicit empty REVIEW_MCP_CONFIG disables conventional path fallback" {
  local conv_file
  conv_file="$(mktemp)"
  echo '{"mcpServers":{"conv":{}}}' > "$conv_file"
  export REVIEW_MCP_CONFIG_DEFAULT_PATH="$conv_file"
  export REVIEW_MCP_CONFIG=""
  _source_engine "claude"
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  rm -f "$conv_file"
  [ "$status" -eq 0 ]
  ! grep -q -- "--mcp-config" "$ARGS_RECORD"
}

# ── Committed sample is inert documentation-only (issue #679, AC #4) ──────────

@test "sample: committed Context7 sample is valid JSON" {
  run jq empty "$SCRIPT_DIR/.github/review-mcp.json.sample"
  [ "$status" -eq 0 ]
}

@test "sample: committed review-mcp.json is valid JSON (MCP active in this repo)" {
  run jq empty "$SCRIPT_DIR/.github/review-mcp.json"
  [ "$status" -eq 0 ]
}

# ── Active config is the zero-auth Context7 server (issue #816) ───────────────
# The pilot starter is Context7 over its zero-auth HTTP endpoint — NOT the
# plan-blocked GitHub secret-scanning server (advanced_security unavailable on
# this repo's plan). Pin the committed review-mcp.json to that shape.

@test "active config: review-mcp.json configures the zero-auth context7 server" {
  local cfg="$SCRIPT_DIR/.github/review-mcp.json"
  run jq -e '.mcpServers.context7.type == "http"' "$cfg"
  [ "$status" -eq 0 ]
  run jq -r '.mcpServers.context7.url' "$cfg"
  [ "$status" -eq 0 ]
  [ "$output" = "https://mcp.context7.com/mcp" ]
}

@test "active config: context7 server carries no auth (zero-auth, no headers/secret)" {
  local cfg="$SCRIPT_DIR/.github/review-mcp.json"
  # context7 must exist AND carry no headers object → no Authorization/API-key
  # smuggled in. Guarding on existence keeps this from passing when context7 is
  # missing entirely (which test "configures the zero-auth context7 server"
  # already catches, but this assertion should stand on its own).
  run jq -e '.mcpServers.context7 != null and (.mcpServers.context7 | has("headers") | not)' "$cfg"
  [ "$status" -eq 0 ]
}

@test "active config: plan-blocked github secret-scanning server is gone" {
  local cfg="$SCRIPT_DIR/.github/review-mcp.json"
  run jq -e '.mcpServers | has("github")' "$cfg"
  [ "$status" -ne 0 ]
}

# ── Triage tier: never gets MCP flags ────────────────────────────────────────

@test "triage: MCP knob set → triage still uses --disallowed-tools only, no MCP" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export REVIEW_MCP_ALLOWED_TOOLS="mcp__context7__*"
  run run_triage "$TEST_PROMPT"
  [ "$status" -eq 0 ]
  ! grep -q -- "--mcp-config" "$ARGS_RECORD" || false
  ! grep -q -- "--strict-mcp-config" "$ARGS_RECORD" || false
  ! grep -q -- "--allowed-tools" "$ARGS_RECORD" || false
  grep -q -- "--disallowed-tools" "$ARGS_RECORD"
}

# ── Graceful degradation: warn (never fake) on MCP server failure (issue #678) ─
# The claude CLI surfaces an MCP connection/init failure in its captured output
# but still exits 0 and produces a verdict. engine.sh must warn (naming the
# server) and let the review complete — no fatal exit, no fabricated "all clear".

@test "agentic: MCP failure marker + knob set → ::warning:: names server, verdict still emitted" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export STUB_ENGINE_RESPONSE=$'MCP server "context7" failed to connect after 3 attempts\n{"decision":"approve","summary":"looks good"}'
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  # AC #2: never a fatal exit on MCP failure.
  [ "$status" -eq 0 ]
  # AC #1: a warning is emitted naming the affected server.
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"mcp"* ]]
  [[ "$output" == *"context7"* ]]
  # AC #1/#2: the review still returns its normal, non-empty verdict.
  [[ "$output" == *'"decision":"approve"'* ]]
}

@test "agentic: MCP failure marker but knob UNSET → no MCP warning (AC #3)" {
  _source_engine "claude"
  unset REVIEW_MCP_CONFIG
  export STUB_ENGINE_RESPONSE=$'MCP server "context7" failed to connect after 3 attempts\n{"decision":"approve","summary":"looks good"}'
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  [ "$status" -eq 0 ]
  # No MCP-related warning when MCP was never configured.
  ! [[ "$output" == *"::warning::[mcp]"* ]] || false
  # Verdict still flows through untouched.
  [[ "$output" == *'"decision":"approve"'* ]]
}

@test "agentic: knob set but no MCP failure in output → no false-positive warning" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export STUB_ENGINE_RESPONSE='{"decision":"approve","summary":"clean run, MCP healthy"}'
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"::warning::[mcp]"* ]] || false
  [[ "$output" == *'"decision":"approve"'* ]]
}

@test "agentic: MCP failure without quoted server name + knob set → generic warning, review continues" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export STUB_ENGINE_RESPONSE=$'Failed to connect to MCP server\n{"decision":"comment","summary":"degraded"}'
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::[mcp]"* ]]
  [[ "$output" == *'"decision":"comment"'* ]]
}

@test "duck: MCP failure marker + knob set → ::warning:: emitted, duck verdict continues" {
  _source_engine "claude"
  export DUCK_ENGINE="claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export STUB_ENGINE_RESPONSE=$'MCP server "context7" failed to connect\n{"decision":"approve","summary":"duck ok"}'
  run run_duck "$TEST_PROMPT" "claude-sonnet-4-6"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::[mcp]"* ]]
  [[ "$output" == *"context7"* ]]
  [[ "$output" == *'"decision":"approve"'* ]]
}

# ── Affirmative debug diagnostics (REVIEW_MCP_DEBUG) ──────────────────────────
# The failure path is "fail loud, never fake" — but a HEALTHY MCP run only logs
# nothing, so connectivity could only be inferred from the absence of a warning.
# REVIEW_MCP_DEBUG opt-in: thread `--debug mcp` into the MCP claude tiers and
# surface the handshake as a ::notice::. Off by default; never alters the verdict.

@test "debug: REVIEW_MCP_DEBUG set + MCP config → --debug mcp threaded into claude call" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export REVIEW_MCP_DEBUG=1
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  [ "$status" -eq 0 ]
  grep -q -- "--debug mcp" "$ARGS_RECORD"
  grep -q -- "--mcp-config $MCP_CONFIG_FILE" "$ARGS_RECORD"
}

@test "debug: REVIEW_MCP_DEBUG set but MCP off → no --debug flag (debug rides MCP flags only)" {
  export REVIEW_MCP_CONFIG_DEFAULT_PATH="$(mktemp -u)"  # no conventional file
  _source_engine "claude"
  export REVIEW_MCP_DEBUG=1
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  [ "$status" -eq 0 ]
  ! grep -q -- "--debug mcp" "$ARGS_RECORD" || false
  ! grep -q -- "--mcp-config" "$ARGS_RECORD"
}

@test "debug: MCP knob set but REVIEW_MCP_DEBUG unset → no --debug flag (default unchanged)" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  [ "$status" -eq 0 ]
  ! grep -q -- "--debug mcp" "$ARGS_RECORD"
}

@test "debug: REVIEW_MCP_DEBUG set + healthy handshake in output → ::notice:: surfaced, no warning" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export REVIEW_MCP_DEBUG=1
  export STUB_ENGINE_RESPONSE=$'MCP server "context7": Successfully connected (transport: http) in 333ms\n{"decision":"approve","summary":"mcp healthy"}'
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::[mcp]"* ]]
  [[ "$output" == *"context7"* ]]
  [[ "$output" == *"Successfully connected"* ]]
  ! [[ "$output" == *"::warning::[mcp]"* ]] || false
  [[ "$output" == *'"decision":"approve"'* ]]
}

@test "debug: healthy handshake but REVIEW_MCP_DEBUG unset → no ::notice:: (opt-in only)" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export STUB_ENGINE_RESPONSE=$'MCP server "context7": Successfully connected (transport: http) in 333ms\n{"decision":"approve","summary":"mcp healthy"}'
  run run_agentic "$TEST_PROMPT" "claude-opus-5-5" "deep"
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"::notice::[mcp]"* ]] || false
  [[ "$output" == *'"decision":"approve"'* ]]
}
