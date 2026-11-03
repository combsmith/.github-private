#!/usr/bin/env bash
# Create the unprivileged user review models run as, give it a read-only copy of
# the CLIs and prompts, and prove the boundary before any model starts. A failed
# self-test fails the job: reviews stop rather than run outside the sandbox.
#
# Env: PR_REVIEW_MODEL_USER (required). Run after the engine CLIs are installed.

set -euo pipefail

: "${PR_REVIEW_MODEL_USER:?PR_REVIEW_MODEL_USER must be set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/model-sandbox.sh
source "$SCRIPT_DIR/lib/model-sandbox.sh"

id "$PR_REVIEW_MODEL_USER" >/dev/null 2>&1 \
  || sudo -n useradd --create-home --shell /usr/sbin/nologin "$PR_REVIEW_MODEL_USER"

sudo -n rm -rf "$MODEL_SANDBOX_ROOT"
sudo -n mkdir -p "$MODEL_SANDBOX_ROOT/cli" "$MODEL_SANDBOX_ROOT/cwd"
if [[ -d "$HOME/.npm-global" ]]; then
  sudo -n cp -a "$HOME/.npm-global/." "$MODEL_SANDBOX_ROOT/cli/"
fi
sudo -n cp -R "$SCRIPT_DIR/../prompts" "$MODEL_SANDBOX_ROOT/cwd/prompts"
sudo -n cp "$SCRIPT_DIR/../CLAUDE.md" "$SCRIPT_DIR/../AGENTS.md" "$MODEL_SANDBOX_ROOT/cwd/"
sudo -n chown -R root:root "$MODEL_SANDBOX_ROOT"
sudo -n chmod -R a+rX,go-w "$MODEL_SANDBOX_ROOT"

# Gemini has no equivalent of --tools. Its tool set comes from system settings, which
# outrank user settings and which the model user can read but not change.
sudo -n mkdir -p "$(dirname "$MODEL_SANDBOX_GEMINI_SETTINGS")"
sudo -n tee "$MODEL_SANDBOX_GEMINI_SETTINGS" >/dev/null <<JSON
{
  "tools": {
    "core": ["read_file", "read_many_files", "list_directory", "glob", "search_file_content"],
    "exclude": ["run_shell_command", "write_file", "replace", "web_fetch", "google_web_search", "save_memory"]
  },
  "context": { "includeDirectories": ["$MODEL_SANDBOX_CONTEXT_DIR"] }
}
JSON
sudo -n chown root:root "$MODEL_SANDBOX_GEMINI_SETTINGS"
sudo -n chmod 644 "$MODEL_SANDBOX_GEMINI_SETTINGS"

mkdir -p "$MODEL_SANDBOX_CONTEXT_DIR"
chmod 755 "$MODEL_SANDBOX_CONTEXT_DIR"

# Only Claude runs in the sandbox for now: Copilot authenticates with a user PAT, and
# Gemini's tool limits are not yet shown to hold on a live run. An engine left out of
# these lists is never selected, so nothing tries it and fails.
if [[ "${MODEL_SANDBOX_ALLOW_GEMINI:-false}" != "true" ]] && [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "AI_ENGINES=claude"
    echo "AI_DUCK_ENGINE=claude"
    echo "REVIEW_ENGINE=claude"
  } >> "$GITHUB_ENV"
fi

model_sandbox_selftest
echo "model sandbox ready for '$PR_REVIEW_MODEL_USER'"
