#!/usr/bin/env bash
set -euo pipefail
# Pre-flight checks for the dev-lead agent workflow.
# Validates required and optional secrets/tokens before the agent runs.
#
# Usage: bash scripts/dev-lead-preflight.sh
# Outputs: status messages + GITHUB_STEP_SUMMARY table (if running in Actions)

# ── helpers ──────────────────────────────────────────────────────────────────

PASS="ok"
FAIL="missing"
WARN="optional"

# check_required <var_name> <purpose>
# Exits 1 if the variable is unset or empty.
check_required() {
  local var="$1" purpose="$2"
  if [ -z "${!var:-}" ]; then
    echo "::error::Required secret not set: $var ($purpose)"
    return 1
  fi
  echo "  [ok] $var — $purpose"
}

# check_optional <var_name> <purpose>
# Emits a warning if the variable is unset but does not exit.
check_optional() {
  local var="$1" purpose="$2"
  if [ -z "${!var:-}" ]; then
    echo "  [warn] $var not set — $purpose will be unavailable"
  else
    echo "  [ok] $var — $purpose"
  fi
}

# ── checks ────────────────────────────────────────────────────────────────────

echo "dev-lead pre-flight checks"
echo "────────────────────────────────────────"

FAILED=0

# The Claude token is required only when AI_ENGINES enables claude
# (scripts/lib/engine-chain.sh); a Gemini/Copilot-only chain runs without it.
CLAUDE_REQUIRED=required
_PREFLIGHT_CHAIN_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/engine-chain.sh"
# shellcheck source=lib/engine-chain.sh
[ -f "$_PREFLIGHT_CHAIN_LIB" ] && source "$_PREFLIGHT_CHAIN_LIB"
if declare -F ai_engine_enabled >/dev/null 2>&1; then
  if ! ai_engine_enabled claude; then
    CLAUDE_REQUIRED=optional
  fi || {
    echo "::error::Failed to read engine configuration file — config/ai-engines.json may be missing or unreadable"
    exit 1
  }
fi

if [ "$CLAUDE_REQUIRED" = required ]; then
  check_required "CLAUDE_CODE_OAUTH_TOKEN" "Claude Code CLI authentication" || FAILED=1
else
  check_optional "CLAUDE_CODE_OAUTH_TOKEN" "Claude Code CLI authentication (claude not in AI_ENGINES)"
fi

check_optional "GH_PAT_WORKFLOWS" "workflow file pushes and repository_dispatch"
check_optional "GOOGLE_API_KEY" "Gemini engine fallback"
check_optional "GH_PAT" "Copilot engine"

echo "────────────────────────────────────────"

# ── step summary ──────────────────────────────────────────────────────────────

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Dev-Lead Pre-Flight Check"
    echo ""
    echo "| Secret | Status | Purpose |"
    echo "| ------ | ------ | ------- |"

    _row() {
      local var="$1" purpose="$2" required="${3:-optional}"
      if [ -n "${!var:-}" ]; then
        echo "| \`$var\` | $PASS | $purpose |"
      elif [ "$required" = "required" ]; then
        echo "| \`$var\` | $FAIL | $purpose |"
      else
        echo "| \`$var\` | $WARN | $purpose |"
      fi
    }

    _row "CLAUDE_CODE_OAUTH_TOKEN" "Claude Code CLI authentication" "$CLAUDE_REQUIRED"
    _row "GH_PAT_WORKFLOWS" "Workflow file pushes and repository_dispatch"
    _row "GOOGLE_API_KEY" "Gemini engine fallback"
    _row "GH_PAT" "Copilot engine"

  } >> "$GITHUB_STEP_SUMMARY"
fi

# ── exit ──────────────────────────────────────────────────────────────────────

if [ "$FAILED" -ne 0 ]; then
  echo "Pre-flight FAILED — required secrets are missing"
  exit 1
fi

echo "Pre-flight OK"
