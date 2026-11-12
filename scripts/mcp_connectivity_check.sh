#!/usr/bin/env bash
# mcp_connectivity_check.sh — durable, affirmative MCP connectivity assertion
# for the daily PR-review health check (#903, part of #676 MCP enrichment).
#
# Why: MCP health is otherwise only observable as a fail-loud `::warning::[mcp]`
# on *real* PR reviews (`_emit_mcp_failure_warning` in scripts/engine.sh — it
# never logs success). There is no durable monitor that Context7 (the configured
# `.github/review-mcp.json` server) is actually reachable, so a silent outage
# only surfaces when a review happens to run. This script provides that monitor:
# it runs the configured server(s) through the SAME flags engine.sh threads
# (`--mcp-config <file> --strict-mcp-config --debug mcp`) and asserts the
# affirmative handshake (`MCP server "…": Successfully connected`).
#
#   * Fails (exit 1) when MCP is configured but unreachable.
#   * Skips / no-ops (exit 0) when MCP isn't configured — no behavior change for
#     non-MCP repos.
#   * Reuses the REVIEW_MCP_DEBUG knob (merged in #892): the affirmative
#     `::notice::[mcp]` is the success signal, mirroring engine.sh's format.
#
# Layout mirrors scripts/initiative_canary.sh:
#   * classify_mcp_output / mcp_check_is_failure / derive_allowed_tools /
#     mcp_check_report are PURE (no network) and unit-tested in
#     tests/test_mcp_connectivity_check.bats.
#   * main() does the I/O: resolve config, invoke claude, classify, report.
#
# Env vars consumed:
#   REVIEW_MCP_CONFIG                explicit MCP config path (override). When set
#                                    (even to a missing path) it is honored as-is.
#   REVIEW_MCP_CONFIG_DEFAULT_PATH   conventional path used when REVIEW_MCP_CONFIG
#                                    is unset/empty (default .github/review-mcp.json)
#   REVIEW_MCP_ALLOWED_TOOLS         override the derived `mcp__<server>__*` allowlist
#   REVIEW_MCP_DEBUG                 honored knob; --debug mcp is always passed here
#                                    since the handshake IS the assertion
#   MCP_CHECK_MODEL                  claude model for the probe (default haiku)
#   MCP_CHECK_TIMEOUT                seconds to allow the probe (default 120)
#   MCP_CHECK_OUT                    optional path; report is written there too
#   GITHUB_STEP_SUMMARY / GITHUB_ENV written by the Actions runner

set -euo pipefail

# Model family → current id resolver (#1979): name a family, never pin a version.
# Resolve the lib dir with parameter expansion (no external `dirname`) so this
# source never needs a PATH command — main()'s jq/claude guards must be the first
# thing to fail when the environment is stripped bare.
# shellcheck source=scripts/lib/engine-models.sh
# ${BASH_SOURCE[0]%/*} leaves a slash-less invocation (e.g. `bash
# mcp_connectivity_check.sh` from the scripts dir) as the filename itself, so
# guard the strip and default to the current directory when there is no slash.
_mcp_lib_dir="."
[[ "${BASH_SOURCE[0]}" == */* ]] && _mcp_lib_dir="${BASH_SOURCE[0]%/*}"
source "$_mcp_lib_dir/lib/engine-models.sh"

REVIEW_MCP_CONFIG_DEFAULT_PATH="${REVIEW_MCP_CONFIG_DEFAULT_PATH:-.github/review-mcp.json}"

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested; no network)
# ---------------------------------------------------------------------------

# classify_mcp_output <output>
# Maps the captured claude `--debug mcp` output to a connectivity status:
#   CONNECTED    — the affirmative handshake is present (the success signal
#                  REVIEW_MCP_DEBUG surfaces; identical string to the one
#                  _emit_mcp_failure_warning greps for in engine.sh)
#   FAILED       — an explicit MCP connection/init failure marker is present
#   NO_HANDSHAKE — neither: connectivity cannot be proven (timeout kill, empty
#                  output, …). For an ASSERTION this is a failure, not a pass.
classify_mcp_output() {
  local out="${1:-}"
  if printf '%s' "$out" | grep -qiE 'mcp server "[^"]+": successfully connected'; then
    echo "CONNECTED"
    return 0
  fi
  if printf '%s' "$out" | grep -qiE 'mcp server "[^"]+" (failed|could not)|failed to (connect to|start|reach) mcp|could not (connect to|start) mcp|mcp[^.]*(connection|initiali)[^.]*(fail|error)'; then
    echo "FAILED"
    return 0
  fi
  echo "NO_HANDSHAKE"
}

# mcp_check_is_failure <status>
# Exit 0 (alert/fail) for any status other than CONNECTED; exit 1 for CONNECTED.
mcp_check_is_failure() {
  [[ "${1:-}" != "CONNECTED" ]]
}

# derive_allowed_tools <config>
# Emits a comma-joined `mcp__<server>__*` allowlist from the config's
# mcpServers keys (empty when there are no servers). Pure: reads only the file.
derive_allowed_tools() {
  local cfg="${1:-}"
  [[ -n "$cfg" ]] && [[ -f "$cfg" ]] || return 0
  jq -r '(.mcpServers // {}) | keys[] | "mcp__\(.)__*"' "$cfg" 2>/dev/null \
    | paste -sd, - || true
}

# mcp_check_report <status> <config> <servers> [today]
# Writes a Markdown alert/health body to stdout. Pure: no network.
mcp_check_report() {
  local st="${1:-}" cfg="${2:-}" servers="${3:-}" today="${4:-}"
  [[ -n "$today" ]] || today="$(date -u +%Y-%m-%d)"

  local icon headline
  case "$st" in
    CONNECTED)    icon='✅'; headline='MCP server(s) reachable — handshake confirmed' ;;
    FAILED)       icon='🔴'; headline='MCP server(s) unreachable — connection failed' ;;
    NO_HANDSHAKE) icon='🔴'; headline='MCP server(s) unreachable — no handshake observed' ;;
    *)            icon='🔴'; headline='MCP connectivity could not be confirmed' ;;
  esac

  printf '# %s MCP connectivity assertion — %s\n\n' "$icon" "$today"
  printf '_Config `%s` · server(s): `%s` · flags: `--mcp-config … --strict-mcp-config --debug mcp`_\n\n' \
    "$cfg" "${servers:-none}"
  printf -- '- **Result:** %s — %s\n' "$st" "$headline"
  printf '\n'

  if [[ "$st" = "FAILED" ]]; then
    printf '> The configured MCP server(s) returned a connection/init failure. '
    printf 'Context7 (or the configured server) is unreachable — PR reviews will '
    printf 'silently fall back to the model'"'"'s base capabilities until restored.\n'
  elif [[ "$st" = "NO_HANDSHAKE" ]]; then
    printf '> The probe produced no `Successfully connected` handshake within the '
    printf 'timeout. Treated as unreachable: a durable monitor must not pass on the '
    printf 'mere absence of an error.\n'
  fi
}

# ---------------------------------------------------------------------------
# I/O (main)
# ---------------------------------------------------------------------------

main() {
  local cfg
  if [[ -n "${REVIEW_MCP_CONFIG:-}" ]]; then
    cfg="$REVIEW_MCP_CONFIG"
  else
    cfg="$REVIEW_MCP_CONFIG_DEFAULT_PATH"
  fi

  # No-op when MCP isn't configured (no behavior change for non-MCP repos).
  if [[ ! -f "$cfg" ]]; then
    echo "::notice::[mcp] no MCP config at '${cfg}' — connectivity assertion skipped (no-op for non-MCP repos)"
    return 0
  fi

  if ! command -v claude >/dev/null 2>&1; then
    echo "::error::[mcp] claude CLI not found — cannot assert MCP connectivity" >&2
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "::error::[mcp] jq CLI not found — cannot assert MCP connectivity" >&2
    return 1
  fi

  local allowed
  allowed="${REVIEW_MCP_ALLOWED_TOOLS:-$(derive_allowed_tools "$cfg")}"
  if [[ -z "$allowed" ]]; then
    echo "::notice::[mcp] config '${cfg}' declares no servers — nothing to assert, skipping"
    return 0
  fi

  local model timeout servers today
  model="${MCP_CHECK_MODEL:-$(ai_model_for_family haiku)}"
  timeout="${MCP_CHECK_TIMEOUT:-120}"
  servers="$(jq -r '(.mcpServers // {}) | keys | join(", ")' "$cfg" 2>/dev/null || true)"
  today="$(date -u +%Y-%m-%d)"

  echo "=== MCP connectivity assertion ===" >&2
  echo "  Config:  $cfg" >&2
  echo "  Servers: ${servers:-none}" >&2
  echo "  Model:   $model" >&2

  # Probe: --debug mcp logs the server handshake to stderr at session start
  # (servers are initialized to enumerate their tools), so a trivial prompt is
  # enough to force the connection. Combine stdout+stderr for classification.
  # A timeout/non-zero exit leaves no handshake → classified NO_HANDSHAKE/FAILED.
  local out
  out="$(timeout "$timeout" claude --print --model "$model" --debug mcp \
    --mcp-config "$cfg" --strict-mcp-config \
    --allowed-tools "$allowed" \
    -p "Reply with the single word: OK" 2>&1 || true)"

  local status
  status="$(classify_mcp_output "$out")"

  local report
  report="$(mcp_check_report "$status" "$cfg" "$servers" "$today")"
  printf '%s\n' "$report"
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && printf '%s\n' "$report" >> "$GITHUB_STEP_SUMMARY"
  [[ -n "${MCP_CHECK_OUT:-}" ]] && printf '%s\n' "$report" > "$MCP_CHECK_OUT"

  [[ -n "${GITHUB_ENV:-}" ]] && echo "MCP_STATUS=${status}" >> "$GITHUB_ENV"

  if mcp_check_is_failure "$status"; then
    [[ -n "${GITHUB_ENV:-}" ]] && echo "MCP_FAILED=true" >> "$GITHUB_ENV"
    # Surface the captured probe output so the outage is diagnosable in the log.
    echo "----- probe output -----" >&2
    printf '%s\n' "$out" >&2
    echo "------------------------" >&2
    echo "::error::[mcp] connectivity assertion FAILED (${status}) — configured MCP server(s) unreachable: ${servers:-unknown}" >&2
    return 1
  fi

  # Success signal: mirror engine.sh's affirmative ::notice::[mcp] format,
  # one per confirmed handshake line.
  printf '%s' "$out" | grep -hoiE 'mcp server "[^"]+": successfully connected.*' \
    | sort -u | while IFS= read -r _ln; do
        printf '::notice::[mcp] %s\n' "${_ln}"
      done || true
  echo "::notice::[mcp] connectivity assertion passed — ${servers} reachable"
}

# Only run main when executed directly (not when sourced by tests).
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  main "$@"
fi
