#!/usr/bin/env bats
# The engine-CLI install steps of pr-review.yml and dev-lead-reusable.yml must
# never receive an empty primary engine (#1973 review): with the live
# AI_ENGINES=claude,gemini and no REVIEW_ENGINE / DEV_LEAD_ENGINE variable the
# env value is empty, and the step has to resolve the primary from the config.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"

setup() {
  unset AI_ENGINES_CONFIG DEV_LEAD_ENGINES REVIEW_ENGINE DEV_LEAD_ENGINE
  export HOME="$BATS_TEST_TMPDIR/home" GITHUB_PATH="$BATS_TEST_TMPDIR/github_path"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
  : > "$GITHUB_PATH"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  for tool in npm gh claude gemini; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\nexit 0\n' "$tool" \
      > "$BATS_TEST_TMPDIR/bin/$tool"
    chmod +x "$BATS_TEST_TMPDIR/bin/$tool"
  done
  # `gh copilot --version` fails, so the step has to install the extension.
  printf '#!/usr/bin/env bash\necho "gh $*" >> "$CALLS"\n[ "${1:-}" = copilot ] && exit 1\nexit 0\n' \
    > "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# _step <workflow> <step name> — writes the step's run script to a file.
_step() {
  yq -r ".jobs[].steps[] | select(.name == \"$2\") | .run" \
    "$SCRIPT_DIR/.github/workflows/$1" > "$BATS_TEST_TMPDIR/step.sh"
  [ -s "$BATS_TEST_TMPDIR/step.sh" ]
}

@test "pr-review install step handles an empty REVIEW_ENGINE under AI_ENGINES=claude,gemini" {
  _step pr-review.yml "Install review engine CLIs"
  cd "$SCRIPT_DIR"
  AI_ENGINES="claude,gemini" REVIEW_ENGINE="" CLAUDE_CODE_VERSION=latest \
    COPILOT_GITHUB_TOKEN=x run bash "$BATS_TEST_TMPDIR/step.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Unknown REVIEW_ENGINE"* ]]
  [[ "$output" == *"claude-code cache hit"* ]]
  grep -q "npm install -g @google/gemini-cli" "$CALLS"
}

@test "pr-review install step resolves the enabled primary when REVIEW_ENGINE names a disabled engine" {
  _step pr-review.yml "Install review engine CLIs"
  cd "$SCRIPT_DIR"
  AI_ENGINES="claude,gemini" REVIEW_ENGINE="copilot" CLAUDE_CODE_VERSION=latest \
    COPILOT_GITHUB_TOKEN=x run bash "$BATS_TEST_TMPDIR/step.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-code cache hit"* ]]
  ! grep -q "gh extension install github/gh-copilot" "$CALLS"
}

@test "pr-review install step falls back to claude when the config is unreadable" {
  _step pr-review.yml "Install review engine CLIs"
  cd "$SCRIPT_DIR"
  AI_ENGINES_CONFIG="$BATS_TEST_TMPDIR/missing.json" REVIEW_ENGINE="" \
    CLAUDE_CODE_VERSION=latest COPILOT_GITHUB_TOKEN=x run bash "$BATS_TEST_TMPDIR/step.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-code cache hit"* ]]
}

@test "dev-lead install step installs fallback CLIs for an empty DEV_LEAD_ENGINE under AI_ENGINES=claude,gemini" {
  _step dev-lead-reusable.yml "Install engine CLIs"
  mkdir -p "$BATS_TEST_TMPDIR/work"
  ln -s "$SCRIPT_DIR" "$BATS_TEST_TMPDIR/work/.dev-lead"
  cd "$BATS_TEST_TMPDIR/work"
  AI_ENGINES="claude,gemini" DEV_LEAD_ENGINE="" CLAUDE_CODE_VERSION=latest \
    run bash "$BATS_TEST_TMPDIR/step.sh"
  [ "$status" -eq 0 ]
  grep -q "npm install -g @google/gemini-cli" "$CALLS"
  grep -q "gh extension install github/gh-copilot" "$CALLS"
}
