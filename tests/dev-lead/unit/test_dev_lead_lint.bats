#!/usr/bin/env bats
# Unit tests for scripts/dev-lead-lint.sh

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LINT_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-lint.sh"

setup() {
  WORK_DIR="$(mktemp -d)"
  export WORK_DIR

  # Minimal git repo so git commands work
  cd "$WORK_DIR"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  git commit --allow-empty -q -m "init"

  # Create minimal scripts/ and agents/ structure
  mkdir -p scripts agents
}

teardown() {
  cd /
  rm -rf "$WORK_DIR"
}

# ── shellcheck tests ──────────────────────────────────────────────────────────

@test "lint: passes when no shell scripts exist" {
  run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "lint: passes on a valid shell script" {
  cat > "$WORK_DIR/scripts/good.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "hello"
SH
  run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "lint: fails on a shellcheck-warning-level script" {
  # SC2034: variable appears unused (warning level — caught by --severity=warning)
  cat > "$WORK_DIR/scripts/bad.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
my_unused_var="never referenced"
echo "done"
SH
  run bash "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
}

@test "lint: reports shellcheck errors to stderr" {
  # SC2034: variable appears unused (warning level)
  cat > "$WORK_DIR/scripts/bad.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
my_unused_var="never referenced"
echo "done"
SH
  run bash "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  # shellcheck output goes to stdout or stderr; both are captured by bats in $output
  [[ "$output" =~ "bad.sh" ]]
}

# ── agent-profile validation tests ───────────────────────────────────────────

@test "lint: passes when no agent profiles exist" {
  run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "lint: passes on a valid agent profile" {
  cat > "$WORK_DIR/agents/my-agent.md" <<'MD'
---
name: my-agent
description: A test agent
tools:
  - read
---

# My Agent
MD
  run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "lint: fails when agent profile is missing frontmatter" {
  cat > "$WORK_DIR/agents/bad-agent.md" <<'MD'
# Bad Agent — no frontmatter
MD
  run bash "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
}

@test "lint: fails when agent profile name does not match filename" {
  cat > "$WORK_DIR/agents/my-agent.md" <<'MD'
---
name: wrong-name
description: A test agent
tools:
  - read
---

# Agent
MD
  run bash "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
}

@test "lint: fails when agent profile is missing required fields" {
  cat > "$WORK_DIR/agents/my-agent.md" <<'MD'
---
name: my-agent
---

# Agent with no description or tools
MD
  run bash "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
}

@test "lint: fails when agent name is not kebab-case" {
  cat > "$WORK_DIR/agents/MyAgent.md" <<'MD'
---
name: MyAgent
description: Test
tools:
  - read
---
MD
  run bash "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
}

@test "lint: skips agent validation with clear message when PyYAML is unavailable" {
  cat > "$WORK_DIR/agents/test-agent.md" <<'MD'
---
name: test-agent
description: Test agent
tools:
  - read
---
MD

  mkdir -p "$WORK_DIR/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK_DIR/bin/python3"
  chmod +x "$WORK_DIR/bin/python3"

  local saved_path="$PATH"
  export PATH="$WORK_DIR/bin:$PATH"
  run bash "$LINT_SCRIPT"
  export PATH="$saved_path"

  [ "$status" -eq 0 ]
  [[ "$output" == *"PyYAML"* ]]
}

# ── combined tests ────────────────────────────────────────────────────────────

@test "lint: fails when both shellcheck and agent-profile fail" {
  # SC2034: unused variable (warning level)
  cat > "$WORK_DIR/scripts/bad.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
my_unused_var="never referenced"
echo "done"
SH
  cat > "$WORK_DIR/agents/bad-agent.md" <<'MD'
# no frontmatter
MD
  run bash "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
}

@test "lint: exits 0 when all checks pass (shell + agent)" {
  cat > "$WORK_DIR/scripts/good.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "ok"
SH
  cat > "$WORK_DIR/agents/my-agent.md" <<'MD'
---
name: my-agent
description: Test agent
tools:
  - read
---
MD
  run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

# ── CODEOWNERS validation tests ───────────────────────────────────────────────

@test "lint: passes when no CODEOWNERS file exists" {
  run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "lint: passes when .github/CODEOWNERS lists org-leads first" {
  mkdir -p "$WORK_DIR/.github"
  cat > "$WORK_DIR/.github/CODEOWNERS" <<'CO'
# Default owner
* @petry-projects/org-leads
CO
  run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "lint: passes when CODEOWNERS lists org-leads first with additional owners" {
  mkdir -p "$WORK_DIR/.github"
  cat > "$WORK_DIR/.github/CODEOWNERS" <<'CO'
* @petry-projects/org-leads @petry-projects/backend
docs/ @petry-projects/org-leads @petry-projects/docs
CO
  run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "lint: fails when CODEOWNERS owner line does not list org-leads first" {
  mkdir -p "$WORK_DIR/.github"
  cat > "$WORK_DIR/.github/CODEOWNERS" <<'CO'
* @petry-projects/backend @petry-projects/org-leads
CO
  run bash "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "org-leads" ]]
}

@test "lint: fails when CODEOWNERS owner line omits org-leads entirely" {
  mkdir -p "$WORK_DIR/.github"
  cat > "$WORK_DIR/.github/CODEOWNERS" <<'CO'
* @petry-projects/backend
CO
  run bash "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "org-leads" ]]
}

@test "lint: ignores comment lines and blank lines in CODEOWNERS" {
  mkdir -p "$WORK_DIR/.github"
  cat > "$WORK_DIR/.github/CODEOWNERS" <<'CO'
# This is a comment

* @petry-projects/org-leads
CO
  run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "lint: handles CRLF line endings in CODEOWNERS" {
  mkdir -p "$WORK_DIR/.github"
  printf '* @petry-projects/org-leads\r\ndocs/ @petry-projects/org-leads @petry-projects/docs\r\n' \
    > "$WORK_DIR/.github/CODEOWNERS"
  run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "lint: handles escaped spaces in CODEOWNERS paths" {
  mkdir -p "$WORK_DIR/.github"
  printf 'path\\ with\\ spaces/ @petry-projects/org-leads @petry-projects/backend\n' \
    > "$WORK_DIR/.github/CODEOWNERS"
  run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "lint: fails with CRLF when org-leads is not first" {
  mkdir -p "$WORK_DIR/.github"
  printf '* @petry-projects/backend @petry-projects/org-leads\r\n' \
    > "$WORK_DIR/.github/CODEOWNERS"
  run bash "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "org-leads" ]]
}
