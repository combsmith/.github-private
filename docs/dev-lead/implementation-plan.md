# Dev-Lead Agent — Implementation Plan (v2)

**Status:** Planning  
**Version:** 0.2.0 — rubber-duck reviewed and enhanced  
**Spec:** [`docs/dev-lead/spec.md`](./spec.md)  
**Tracking:** GitHub Issues with label `dev-lead`

---

## Rubber-Duck Review: Critical Gaps Addressed

This version corrects the following issues identified in adversarial review of v0.1.0:

| Gap | Fix in this version |
|---|---|
| No dry-run mode — Phase 2 went straight to real commits | `DEV_LEAD_DRY_RUN` from Phase 0; all handlers gate on it |
| Prompt extraction deferred to "follow-on" | Phase 0.3 — prompt library defined BEFORE any handler is written |
| No secrets pre-flight | Phase 0.4 — `dev-lead-preflight.sh` validates secrets + engine availability |
| `ci-relay` storm: 5 failures → 5 dispatch events → 5 concurrent fix jobs | Relay deduplicates per SHA+PR; dispatch payload includes all failing checks |
| No anti-loop guard — agent commits trigger further bot reviews | Intent classifier detects dev-lead commit messages, emits `skip` |
| No rollback strategy | Every fix is a single atomic commit; agent detects self-caused failures and aborts |
| Handler scripts too monolithic — 5 intents in one file | Split: `fix-ci`, `fix-reviews`, `fix-issue`, `rebase` each in own script |
| No prompt rendering tests — `envsubst` can silently leave gaps | Phase 0.3 tests every prompt template for variable completeness |
| Cross-repo reusable not in plan | Phase 1.5 — `dev-lead-reusable.yml` + `.github` standard |
| No observability plan | Phase 0.4 adds job summaries; every handler posts a structured summary |
| No full pipeline integration test | Phase 2.8 adds end-to-end dry-run pipeline test |
| Token scope for GraphQL thread resolution | Documented in Phase 3 — requires `GH_PAT_WORKFLOWS` with PR scope |
| Phase 7 has no transition period | Phase 7 includes a 2-week shadow period before `claude.yml` deletion |

---

## Phase 0 — Test Infrastructure, Dry-Run, and Pre-flight

**Goal:** Complete test harness, dry-run capability, and secrets validation before any production code.

### 0.1 Directory structure

```
tests/dev-lead/
├── unit/                          # bats unit tests (one file per component)
├── integration/                   # shell integration tests (no real API calls)
├── fixtures/
│   ├── events/                    # GitHub webhook JSON payloads
│   ├── engines/                   # stub claude, gemini, gh binaries
│   ├── logs/                      # sample CI failure logs for prompt tests
│   └── stubs/                     # mock gh binary + response config
└── helpers/
    ├── stub-engine.bash           # bats helper: install/remove engine stubs
    ├── mock-gh.bash               # bats helper: configure mock gh responses
    ├── assert-env.bash            # bats helper: assert GITHUB_ENV contents
    └── prompt-vars.bash           # bats helper: verify template variable coverage
```

### 0.2 Event fixture files

Captured from real or schema-valid GitHub webhook payloads. Validated with `jq empty` in CI.

```
tests/dev-lead/fixtures/events/
├── check_run_failure.json               # check_run, non-fork, has PR → relay
├── check_run_failure_no_pr.json         # check_run, no associated PR → skip relay
├── check_run_failure_fork.json          # check_run, fork PR → skip relay
├── check_run_success.json               # check_run, success → skip relay
├── check_run_dev_lead_self.json         # check_run name="dev-lead / dispatch" → skip
├── pr_opened_human.json                 # pull_request opened, human non-fork
├── pr_opened_dependabot.json            # pull_request, dependabot → skip
├── pr_opened_fork.json                  # pull_request, fork → skip
├── pr_sync_dev_lead_commit.json         # pull_request sync, commit by dev-lead → skip (anti-loop)
├── pr_review_copilot_commented.json     # pull_request_review, copilot, COMMENTED
├── pr_review_copilot_approved.json      # pull_request_review, copilot, APPROVED → skip
├── pr_review_gemini_changes.json        # pull_request_review, gemini, CHANGES_REQUESTED
├── pr_review_human_owner.json           # pull_request_review, OWNER
├── pr_review_comment_copilot.json       # pull_request_review_comment, copilot
├── pr_review_comment_human_trigger.json # pull_request_review_comment, human + @dev-lead
├── pr_review_comment_human_no_trigger.json # human, no trigger phrase → skip
├── issue_comment_sonarqube.json         # issue_comment on PR, sonarqubecloud[bot]
├── issue_comment_coderabbit.json        # issue_comment on PR, coderabbitai[bot]
├── issue_comment_human_trigger.json     # issue_comment, human, @dev-lead
├── issue_comment_human_no_trigger.json  # human, no phrase → skip
├── issue_comment_rebase_sentinel.json   # contains <!-- auto-rebase-conflict: -->
├── issue_comment_dev_lead_bot.json      # actor=donpetry-bot → skip (self)
├── issues_labeled_dev_lead.json         # issues labeled dev-lead
├── issues_labeled_claude.json           # issues labeled claude (backward compat)
├── issues_labeled_other.json            # issues labeled bug → skip
└── repository_dispatch_ci_failure.json  # repository_dispatch, dev-lead-ci-failure
```

Each fixture includes a `// TEST_EXPECTED_INTENT` comment at the top documenting the expected classification.

### 0.3 Stub engine binaries

**`tests/dev-lead/fixtures/engines/stub-claude`**

```bash
#!/usr/bin/env bash
# Configurable via env:
#   STUB_ENGINE_RESPONSE  — stdout content (default: "stub response")
#   STUB_ENGINE_EXIT      — exit code (default: 0)
#   STUB_ENGINE_DELAY     — sleep seconds before responding (default: 0)
# Parses --print, --model, --permission-mode flags (ignores all).
while [[ $# -gt 0 ]]; do
  case "$1" in --print|--model|--permission-mode|--allowed-tools|--disallowed-tools) shift; shift ;; *) shift ;; esac
done
sleep "${STUB_ENGINE_DELAY:-0}"
cat <<< "${STUB_ENGINE_RESPONSE:-stub engine response}"
exit "${STUB_ENGINE_EXIT:-0}"
```

Same stub for `stub-gemini` with appropriate flag parsing.

**`tests/dev-lead/fixtures/stubs/gh`** — mock `gh` binary

```bash
#!/usr/bin/env bash
# Configurable via env:
#   GH_STUB_PR_NUMBER      — PR number to return for commit→PR lookup
#   GH_STUB_PR_HEAD_REPO   — head repo full_name
#   GH_STUB_COMMENT_BODY   — PR comment body for idempotency checks
#   GH_STUB_CI_STATUS      — "success"|"failure" for pr checks
#   GH_STUB_DISPATCH_CALLED — set to "true" after dispatches call
# Intercepts: gh api, gh pr checkout, gh pr checks, gh pr comment
case "$*" in
  *dispatches*) export GH_STUB_DISPATCH_CALLED="true"; exit 0 ;;
  *"commits/"*"/pulls"*) echo "[{\"number\":${GH_STUB_PR_NUMBER:-0},\"state\":\"open\"}]" ;;
  *"pulls/${GH_STUB_PR_NUMBER:-0}"*) echo "{\"head\":{\"repo\":{\"full_name\":\"${GH_STUB_PR_HEAD_REPO:-petry-projects/.github-private}\"}}}" ;;
  *"comments"*) echo "[{\"body\":\"${GH_STUB_COMMENT_BODY:-}\"}]" ;;
  *"pr checks"*|*"pr check"*) echo "${GH_STUB_CI_STATUS:-success}"; exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr checkout"*) exit 0 ;;
  *) command gh "$@" 2>/dev/null || exit 0 ;;
esac
```

### 0.4 Dry-run mode and pre-flight

**`DEV_LEAD_DRY_RUN`** env var — present in all workflow jobs. When `true`:
- Intent classification runs normally (full output)
- Engine CLIs are installed (to validate availability)
- Handler scripts build prompts but do NOT call `run_writer()`
- No commits, no pushes, no API writes
- Outputs what WOULD happen to the job step summary

**`scripts/dev-lead-preflight.sh`** — runs before every handler:

```bash
#!/usr/bin/env bash
# Validates required secrets and engine availability.
# Emits ::error:: and exits 1 if CLAUDE_CODE_OAUTH_TOKEN is absent.
# Emits ::warning:: for optional secrets (GOOGLE_API_KEY, GH_PAT).
# Appends an availability table to GITHUB_STEP_SUMMARY.

check_required() {
  local name="$1" value="$2"
  if [ -z "$value" ]; then
    echo "::error::$name is required but not set. Dev-lead cannot run without it."
    exit 1
  fi
}

check_optional() {
  local name="$1" value="$2" purpose="$3"
  if [ -z "$value" ]; then
    echo "::warning::$name not set — $purpose unavailable."
  fi
}

check_required "CLAUDE_CODE_OAUTH_TOKEN" "${CLAUDE_CODE_OAUTH_TOKEN:-}"
check_optional "GH_PAT_WORKFLOWS" "${GH_PAT_WORKFLOWS:-}" "workflow file pushes and repository_dispatch"
check_optional "GOOGLE_API_KEY" "${GOOGLE_API_KEY:-}" "Gemini engine fallback"
check_optional "GH_PAT" "${GH_PAT:-}" "Copilot engine"
```

### 0.5 `test-dev-lead.yml` CI workflow

```yaml
name: Test Dev-Lead Agent
on:
  pull_request:
    paths: ['scripts/dev-lead*', 'scripts/engine.sh', '.github/workflows/dev-lead*.yml', 'tests/dev-lead/**', 'prompts/dev-lead/**']
  push:
    branches: [main]
    paths: ['scripts/dev-lead*', 'scripts/engine.sh', 'tests/dev-lead/**', 'prompts/dev-lead/**']

jobs:
  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@...
      - name: Install bats + helpers
        run: |
          npm install -g bats bats-support bats-assert
      - name: Validate event fixtures
        run: find tests/dev-lead/fixtures/events -name '*.json' -exec jq empty {} \;
      - name: Run unit tests
        run: bats tests/dev-lead/unit/ --formatter tap

  integration:
    runs-on: ubuntu-latest
    needs: unit
    steps:
      - uses: actions/checkout@...
      - name: Run integration tests
        run: bash tests/dev-lead/integration/run-all.sh

  prompt-coverage:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@...
      - name: Verify all prompt templates have no missing variables
        run: bash tests/dev-lead/integration/test_prompt_coverage.sh

  dry-run-pipeline:
    runs-on: ubuntu-latest
    needs: [unit, integration]
    env:
      DEV_LEAD_DRY_RUN: "true"
      REVIEW_ENGINE: "claude"
    steps:
      - uses: actions/checkout@...
      - name: Install stub engine
        run: |
          mkdir -p ~/.local/bin
          cp tests/dev-lead/fixtures/engines/stub-claude ~/.local/bin/claude
          chmod +x ~/.local/bin/claude
          echo "$HOME/.local/bin" >> "$GITHUB_PATH"
      - name: Run full pipeline dry-run (fix-ci intent)
        env:
          GITHUB_EVENT_NAME: repository_dispatch
          GITHUB_EVENT_PATH: tests/dev-lead/fixtures/events/repository_dispatch_ci_failure.json
          GITHUB_ENV: /tmp/test-github-env
          GITHUB_OUTPUT: /tmp/test-github-output
          BOT_USER: donpetry-bot
          TRUSTED_BOTS: copilot-pull-request-reviewer[bot]
          TRIGGER_PHRASES: "@claude,@dev-lead"
          INTENT_CONTEXT_FILE: /tmp/test-intent-context.json
        run: |
          touch /tmp/test-github-env /tmp/test-github-output
          bash scripts/dev-lead-intent.sh
          INTENT_TYPE=$(grep "^INTENT_TYPE=" /tmp/test-github-env | cut -d= -f2)
          echo "Classified intent: $INTENT_TYPE"
          [ "$INTENT_TYPE" = "fix-ci" ]
```

### 0.6 Phase 0 definition of done

- [ ] All 24 fixture JSON files pass `jq empty`
- [ ] `stub-claude` and `stub-gemini` pass smoke tests
- [ ] Mock `gh` binary intercepts all required commands
- [ ] `test-dev-lead.yml` workflow is green (zero tests, but harness works)
- [ ] `DEV_LEAD_DRY_RUN=true` env var is documented in workflow
- [ ] `dev-lead-preflight.sh` validates secrets and exits clearly

---

## Phase 0.3 — Prompt Library (BEFORE handler scripts)

**Goal:** Define all prompt templates with clear variable contracts. No handler script can be written until its prompt is reviewed and merged.

### Prompt architecture

Handler scripts render prompts via `envsubst` with a strict variable whitelist:

```bash
# In handler scripts:
build_prompt() {
  local template="prompts/dev-lead/${INTENT_TYPE}.md"
  # Export only the variables the template declares — no accidental leakage
  local required_vars
  required_vars=$(grep -oP '\$\{[A-Z_]+\}' "$template" | sort -u | tr -d '${}\n' | tr '\n' ',')
  envsubst "$(printf '${%s},' $required_vars)" < "$template"
}
```

### Prompt files

```
prompts/dev-lead/
├── fix-ci.md          # Variables: PR_NUMBER, PR_URL, CHECK_NAME, APP_SLUG, HEAD_SHA, DETAILS_URL, FAILURE_LOGS, ANNOTATIONS, REPO
├── fix-reviews.md     # Variables: PR_NUMBER, PR_URL, REPO, OPEN_THREADS_JSON, BASE_REF
├── fix-bot-comment.md # Variables: PR_NUMBER, PR_URL, REPO, ACTOR, COMMENT_BODY, HEAD_SHA
├── human.md           # Variables: PR_NUMBER, PR_URL, REPO, ACTOR, USER_INSTRUCTION, PR_DESCRIPTION
├── human-pr.md        # Variables: PR_NUMBER, PR_URL, REPO, PR_TITLE, PR_DESCRIPTION, OPEN_THREADS_JSON
├── fix-issue.md       # Variables: ISSUE_NUMBER, ISSUE_URL, REPO, ISSUE_TITLE, ISSUE_BODY, ORG_STANDARDS_HINT
└── rebase.md          # Variables: PR_NUMBER, PR_URL, REPO, BASE_REF, HEAD_REF, CONFLICTING_FILES
```

Each template must:
1. State the agent's role and constraints in the first 3 lines
2. Clearly section: **Context** → **Failure/Feedback** → **Task** → **Constraints** → **Output format**
3. Include a `<!-- VARIABLES: VAR1, VAR2, ... -->` HTML comment listing all variables (used by tests)

### Prompt tests: `tests/dev-lead/integration/test_prompt_coverage.sh`

```bash
#!/usr/bin/env bash
# Verifies: every variable referenced in a template is (a) listed in its
# <!-- VARIABLES: --> comment, and (b) present when envsubst is called.
set -euo pipefail

PROMPTS_DIR="prompts/dev-lead"
FAILURES=0

for template in "$PROMPTS_DIR"/*.md; do
  name=$(basename "$template")
  # Extract declared variables from the <!-- VARIABLES: --> comment
  declared=$(grep -oP '(?<=<!-- VARIABLES: )[^>]+(?= -->)' "$template" 2>/dev/null || echo "")
  if [ -z "$declared" ]; then
    echo "FAIL: $name has no <!-- VARIABLES: --> declaration"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  # Extract referenced variables from the template body
  referenced=$(grep -oP '\$\{[A-Z_]+\}' "$template" | grep -oP '[A-Z_]+' | sort -u)

  for var in $referenced; do
    if ! echo "$declared" | grep -qw "$var"; then
      echo "FAIL: $name references \${$var} but it is not in <!-- VARIABLES: -->"
      FAILURES=$((FAILURES + 1))
    fi
  done

  # Test envsubst with all declared vars set to "TEST_VALUE"
  eval_env=""
  for var in $(echo "$declared" | tr ',' ' '); do
    eval_env="export $var=TEST_VALUE; $eval_env"
  done
  rendered=$(eval "$eval_env" envsubst < "$template" 2>&1)
  if echo "$rendered" | grep -qP '\$\{[A-Z_]+\}'; then
    echo "FAIL: $name has unrendered variables after envsubst"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: $name"
  fi
done

[ "$FAILURES" -eq 0 ] || { echo "$FAILURES prompt tests failed"; exit 1; }
```

### Unit tests: `tests/dev-lead/unit/test_prompt_rendering.bats`

```bash
@test "fix-ci prompt: renders with all required variables" {
  export PR_NUMBER="175" PR_URL="https://github.com/..." CHECK_NAME="SonarCloud"
  export APP_SLUG="sonarqubecloud" HEAD_SHA="abc123" DETAILS_URL="https://sonarcloud.io"
  export FAILURE_LOGS="error: unused variable" ANNOTATIONS="line 42: issue" REPO="petry-projects/.github-private"
  run bash -c 'envsubst < prompts/dev-lead/fix-ci.md'
  [ "$status" -eq 0 ]
  [[ "$output" != *'${'* ]]   # no unrendered variables
  [[ "$output" == *"175"* ]]  # PR number is present
}

@test "fix-reviews prompt: renders with all required variables" {
  export PR_NUMBER="175" PR_URL="https://github.com/..." REPO="petry-projects/.github-private"
  export OPEN_THREADS_JSON='[]' BASE_REF="main"
  run bash -c 'envsubst < prompts/dev-lead/fix-reviews.md'
  [ "$status" -eq 0 ]
  [[ "$output" != *'${'* ]]
}

@test "prompt build_prompt() uses variable whitelist" {
  source scripts/dev-lead-fix-ci.sh
  export INTENT_TYPE="fix-ci"
  export PR_NUMBER="99" PR_URL="url" CHECK_NAME="test" APP_SLUG="app"
  export HEAD_SHA="sha" DETAILS_URL="url" FAILURE_LOGS="logs" ANNOTATIONS="ann" REPO="repo"
  export UNRELATED_SECRET="this-should-not-appear"
  result=$(build_prompt)
  [[ "$result" != *"this-should-not-appear"* ]]
}
```

### Phase 0.3 definition of done

- [ ] All 7 prompt templates exist with `<!-- VARIABLES: -->` declarations
- [ ] `test_prompt_coverage.sh` passes for all templates
- [ ] All `test_prompt_rendering.bats` tests pass
- [ ] No handler script is merged until its prompt template is reviewed

---

## Phase 1 — Scaffold: Triggers and Intent Stub

**Goal:** `dev-lead.yml` live on main with all triggers; `dispatch` always skips; `ci-relay` works but emits no dispatch (relay target doesn't exist yet).

### 1.1 Files

| File | Change |
|---|---|
| `.github/workflows/dev-lead.yml` | CREATE — all 7 triggers, both jobs, stub intent |
| `scripts/dev-lead-intent.sh` | CREATE — stub: always `skip` with reason `not-implemented` |
| `scripts/dev-lead-preflight.sh` | CREATE — from Phase 0.4 spec |

### 1.2 Anti-loop guard (in intent classifier, from day 1)

The intent classifier must detect commits made by the dev-lead agent itself and emit `skip` to prevent feedback loops. A dev-lead fix commit is identified by its commit message prefix `fix(dev-lead):` or `fix(ci):` when the pusher is `BOT_USER`.

```bash
# In dev-lead-intent.sh, pull_request synchronize case:
if [ "$GITHUB_EVENT_NAME" = "pull_request" ] && [ "$ACTION" = "synchronize" ]; then
  PUSHER=$(jq -r '.sender.login' "$GITHUB_EVENT_PATH")
  HEAD_COMMIT_MSG=$(jq -r '.pull_request.head.commit.message // ""' "$GITHUB_EVENT_PATH" 2>/dev/null || \
    gh api "repos/${GITHUB_REPOSITORY}/git/commits/$(jq -r '.pull_request.head.sha' "$GITHUB_EVENT_PATH")" \
      --jq '.message' 2>/dev/null || echo "")
  if [ "$PUSHER" = "$BOT_USER" ] || echo "$HEAD_COMMIT_MSG" | grep -qE "^fix\((dev-lead|ci|reviews)\):"; then
    emit_skip "dev-lead-own-commit"
    exit 0
  fi
fi
```

### 1.3 Unit tests: `tests/dev-lead/unit/test_intent_stub.bats`

```bash
@test "stub: all events emit skip" { ... }
@test "anti-loop: pull_request sync from BOT_USER → skip" { ... }
@test "anti-loop: commit message 'fix(ci):...' → skip" { ... }
@test "pre-flight: missing CLAUDE_CODE_OAUTH_TOKEN → exits 1" { ... }
@test "dry-run: DEV_LEAD_DRY_RUN=true logged in step summary" { ... }
```

### 1.4 Phase 1 definition of done

- [ ] `dev-lead.yml` on main, all 7 triggers confirmed in Actions UI
- [ ] `dispatch` job always shows `INTENT_TYPE=skip` cleanly
- [ ] `ci-relay` job fires on a test `check_run` failure, logs "no dispatch target yet"
- [ ] Anti-loop guard unit tests pass
- [ ] Pre-flight unit tests pass

---

## Phase 1.5 — Cross-repo Standard

**Goal:** Other org repos can adopt the dev-lead agent by copying a thin caller stub. The reusable workflow in `.github-private` contains all logic.

### 1.5.1 Files

| File | Repo | Change |
|---|---|---|
| `.github/workflows/dev-lead-reusable.yml` | `.github-private` | CREATE — reusable wrapper |
| `standards/workflows/dev-lead.yml` | `.github` | CREATE — thin caller stub standard |
| `standards/ci-standards.md` | `.github` | UPDATE — add §5 Dev-Lead Agent |

### 1.5.2 `dev-lead-reusable.yml` design

The reusable workflow receives the caller's event context automatically (GitHub passes `github.event_name`, `github.event`, `github.repository`, etc. through to reusable workflows called via `workflow_call`).

To access dev-lead scripts, the reusable checks out `.github-private` into a subdirectory:

```yaml
name: Dev-Lead Agent (Reusable)
on:
  workflow_call:
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: { required: true }
      GH_PAT_WORKFLOWS:        { required: false }
      GOOGLE_API_KEY:           { required: false }
      GH_PAT:                   { required: false }

jobs:
  dispatch:
    if: github.event_name != 'check_run'
    runs-on: ubuntu-latest
    timeout-minutes: 60
    permissions:
      contents: write
      pull-requests: write
      issues: write
      actions: read
      checks: read
    steps:
      - name: Checkout caller repo
        uses: actions/checkout@...    # checks out the CALLING repo

      - name: Checkout dev-lead scripts
        uses: actions/checkout@...
        with:
          repository: petry-projects/.github-private
          path: .dev-lead
          token: ${{ secrets.GH_PAT_DON_PETRY || secrets.GH_PAT_WORKFLOWS || github.token }}
          sparse-checkout: |
            scripts/
            prompts/dev-lead/

      - name: Classify intent
        id: intent
        env:
          # ... all env vars ...
        run: bash .dev-lead/scripts/dev-lead-intent.sh

      - name: Install engine CLIs
        if: steps.intent.outputs.intent_type != 'skip'
        run: bash .dev-lead/scripts/dev-lead-install-engines.sh

      - name: Run handler
        if: steps.intent.outputs.intent_type != 'skip'
        env:
          DEV_LEAD_SCRIPTS: .dev-lead/scripts
          DEV_LEAD_PROMPTS: .dev-lead/prompts/dev-lead
        run: |
          case "${{ steps.intent.outputs.intent_type }}" in
            fix-ci)   bash .dev-lead/scripts/dev-lead-fix-ci.sh ;;
            fix-reviews|fix-bot-comment|human|human-pr|rebase)
                      bash .dev-lead/scripts/dev-lead-fix-reviews.sh ;;
            issue)    bash .dev-lead/scripts/dev-lead-fix-issue.sh ;;
          esac

  ci-relay:
    if: >-
      github.event_name == 'check_run' &&
      github.event.check_run.conclusion == 'failure' &&
      !startsWith(github.event.check_run.name, 'dev-lead / ') &&
      !startsWith(github.event.check_run.name, 'claude-code / ')
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
      pull-requests: read
    steps:
      - name: Resolve PR and dispatch
        env:
          GH_TOKEN: ${{ secrets.GH_PAT_DON_PETRY || secrets.GH_PAT_WORKFLOWS || github.token }}
        run: |
          # ... same relay logic as dev-lead.yml ...
```

**Key design point:** Handler scripts use `$DEV_LEAD_PROMPTS` env var to locate prompt templates, so they work identically whether run from `.github-private` (where prompts are at `prompts/dev-lead/`) or from a caller repo (where they're at `.dev-lead/prompts/dev-lead/`).

### 1.5.3 Caller stub standard (`petry-projects/.github/standards/workflows/dev-lead.yml`)

```yaml
# ─────────────────────────────────────────────────────────────────────────────
# Dev-Lead Agent — thin caller stub
# Standard: petry-projects/.github/standards/ci-standards.md#5-dev-lead-agent
# Reusable: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml
#
# ADOPTING THIS WORKFLOW:
#   1. Copy this file verbatim to .github/workflows/dev-lead.yml in your repo.
#   2. Ensure CLAUDE_CODE_OAUTH_TOKEN org/repo secret is set.
#   3. Optionally set GH_PAT_WORKFLOWS (required for Claude to push workflow files).
#   4. Optionally set vars.DEV_LEAD_ENGINE = "claude" | "gemini" | "copilot".
#
# UNLIKE claude.yml, this file has NO OIDC byte-for-byte constraint. It may be
# modified on PR branches to adjust triggers for repo-specific needs.
#
# REQUIRED org/repo secrets: CLAUDE_CODE_OAUTH_TOKEN
# OPTIONAL org/repo secrets: GH_PAT_WORKFLOWS, GOOGLE_API_KEY, GH_PAT
# ─────────────────────────────────────────────────────────────────────────────

name: Dev-Lead Agent

on:
  pull_request:
    branches: [main]
    types: [opened, reopened, synchronize]
  pull_request_review:
    types: [submitted]
  pull_request_review_comment:
    types: [created]
  issue_comment:
    types: [created]
  issues:
    types: [labeled]
  check_run:
    types: [completed]
  repository_dispatch:
    types: [dev-lead-ci-failure]

permissions: {}

jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@main
    secrets: inherit
    permissions:
      contents: write
      pull-requests: write
      issues: write
      actions: read
      checks: read
```

### 1.5.4 Access configuration

The private `.github-private` reusable must be accessible to calling repos. In GitHub org settings:
- **Settings → Actions → General → "Allow workflows from private repositories"** — must be enabled
- OR configure per-repo in `.github-private` → **Settings → Actions → General → "Allow access from repositories in the organization"**

Document this in `standards/ci-standards.md` §5.

### 1.5.5 Phase 1.5 definition of done

- [ ] `dev-lead-reusable.yml` created in `.github-private`
- [ ] `standards/workflows/dev-lead.yml` created in `.github` (caller stub)
- [ ] `ci-standards.md` updated with §5 Dev-Lead Agent
- [ ] A test repo in `petry-projects` adopts the stub and workflow fires correctly
- [ ] Script path resolution (`$DEV_LEAD_SCRIPTS`, `$DEV_LEAD_PROMPTS`) works in both `.github-private` and caller repos

---

## Phase 2 — CI Fix Path

**Goal:** `check_run` failure → relay → Claude diagnoses and fixes. Dry-run mode tested first, then live.

### 2.1 Files

| File | Change |
|---|---|
| `scripts/dev-lead-intent.sh` | EXTEND — `repository_dispatch:dev-lead-ci-failure` → `fix-ci` |
| `scripts/dev-lead-fix-ci.sh` | CREATE |
| `scripts/dev-lead-install-engines.sh` | CREATE — with caching (mirrors pr-review pattern) |
| `scripts/engine.sh` | EXTEND — `run_writer()`, `run_writer_with_fallback()` |
| `tests/dev-lead/unit/test_intent_ci.bats` | CREATE |
| `tests/dev-lead/unit/test_engine_writer.bats` | CREATE |
| `tests/dev-lead/unit/test_fix_ci.bats` | CREATE |
| `tests/dev-lead/integration/test_ci_relay.sh` | CREATE |
| `tests/dev-lead/integration/test_full_pipeline_dryrun.sh` | CREATE |

### 2.2 CI relay deduplication

The relay can receive multiple `check_run` failures for the same commit (e.g., SonarCloud, CodeQL, and linting all fail). Instead of dispatching one event per failure (causing 3 concurrent fix jobs), the relay:

1. Waits 10 seconds after the first failure (accumulation window)
2. Fetches ALL failed check runs for the commit
3. Dispatches ONE `repository_dispatch` with `client_payload.checks = [...]` (array)
4. Uses a concurrency group keyed on `head_sha` only (not `check_id`)

```bash
# In ci-relay job:
- name: Accumulate and dispatch (deduplicated)
  run: |
    sleep 10  # accumulation window
    FAILED_CHECKS=$(gh api \
      "repos/${{ github.repository }}/commits/${{ github.event.check_run.head_sha }}/check-runs" \
      --jq '[.check_runs[] | select(.conclusion == "failure" and
             (.name | startswith("dev-lead / ") | not) and
             (.name | startswith("claude-code / ") | not)) |
             {name, id, details_url, app_slug: .app.slug}]')
    [ "$(echo "$FAILED_CHECKS" | jq 'length')" -eq 0 ] && exit 0
    gh api "repos/${{ github.repository }}/dispatches" \
      --method POST \
      --field event_type="dev-lead-ci-failure" \
      --raw-field client_payload="$(jq -n \
        --arg pr "$PR" \
        --arg sha "${{ github.event.check_run.head_sha }}" \
        --argjson checks "$FAILED_CHECKS" \
        '{pr_number:$pr,head_sha:$sha,checks:$checks}')"
```

### 2.3 Log truncation strategy

GitHub Actions logs can be megabytes. The fix-ci handler truncates to the last 200 lines of each failed step:

```bash
collect_artifacts() {
  local run_id="$1" max_lines="${LOG_MAX_LINES:-200}"
  gh run view "$run_id" --log-failed 2>&1 | tail -n "$max_lines" > /tmp/failure-logs.txt
  # Annotations are usually compact — no truncation needed
  gh api "repos/${GITHUB_REPOSITORY}/check-runs/${CHECK_ID}/annotations?per_page=100" \
    > /tmp/annotations.json
}
```

The prompt template (`prompts/dev-lead/fix-ci.md`) instructs Claude to request more context via `gh run view` if the truncated logs are insufficient.

### 2.4 Rollback guard

After the fix commit is pushed, if a NEW check failure appears with a name that matches `dev-lead-caused-failure` (detected by comparing which checks were passing before vs. after), the handler:

1. Posts a comment: `fix(ci): agent-caused regression — reverting`
2. Runs `git revert HEAD --no-edit` and pushes
3. Posts a summary with the revert SHA and the detected regression

### 2.5 Unit tests

**`test_intent_ci.bats`** (8 cases):
- `fix-ci`: `repository_dispatch dev-lead-ci-failure` → `fix-ci` ✓
- `fix-ci`: context has `pr_number` from payload ✓
- `fix-ci`: context has `checks` array (not single check) ✓
- `fix-ci`: unknown `repository_dispatch` type → `skip` ✓
- `fix-ci`: `repository_dispatch` with no PR → `skip` ✓
- `relay`: non-fork emits dispatch ✓
- `relay`: fork suppresses dispatch ✓
- `relay`: self-check (`dev-lead / *`) suppresses dispatch ✓

**`test_engine_writer.bats`** (7 cases):
- `claude` exits 0 on success ✓
- `claude` exits 2 on rate limit ✓
- `claude` exits 1 on transient failure; retries once; second attempt succeeds ✓
- `claude` exits 1 on two transient failures; gives up ✓
- `copilot` falls back to claude (with warning) ✓
- `gemini` exits 0 on success ✓
- dry-run: `run_writer()` with `DEV_LEAD_DRY_RUN=true` exits 0 without calling engine ✓

**`test_fix_ci.bats`** (8 cases):
- Idempotency: marker found → exits 0 ✓
- Idempotency: no marker → proceeds ✓
- Log truncation: input > 200 lines → output ≤ 200 lines ✓
- Dry-run: `DEV_LEAD_DRY_RUN=true` builds prompt but does not commit ✓
- Prompt build: all template variables rendered ✓
- Exhaustion: MAX_CI_CYCLES=1, CI always failing → exhaustion comment posted ✓
- Rollback: agent-caused regression detected → git revert triggered ✓
- Multi-check: `checks` array with 2 entries → both included in prompt ✓

### 2.6 Integration: `test_ci_relay.sh` (6 cases)

1. Non-fork PR → dispatch emitted with `checks` array ✓
2. Fork PR → no dispatch ✓
3. Self-check → no dispatch ✓
4. Multiple simultaneous failures → single dispatch (dedup) ✓
5. No open PR for commit → no dispatch ✓
6. `GH_PAT_WORKFLOWS` absent, `github.token` used → dispatch still succeeds ✓

### 2.7 Integration: `test_full_pipeline_dryrun.sh`

End-to-end pipeline test with dry-run mode. Uses stub engine and mock `gh`. Verifies:
1. Intent classification produces `fix-ci`
2. Engine CLI is invoked (stub returns success)
3. Prompt is rendered with all variables
4. No commit/push occurs (`DEV_LEAD_DRY_RUN=true`)
5. Step summary contains expected "would apply fix" message

### 2.8 Phase 2 definition of done

- [ ] All Phase 2 unit tests pass (23 cases)
- [ ] Integration tests pass (12 cases)
- [ ] Dry-run pipeline test passes in `test-dev-lead.yml`
- [ ] Manual E2E dry-run: push deliberate lint error, verify prompt is built correctly without committing
- [ ] Manual E2E live: same error, `DEV_LEAD_DRY_RUN=false`, verify fix committed and CI green

---

## Phase 3 — Review Fix Path

**Goal:** Bot reviews and bot PR comments trigger Claude to address all open threads.

### 3.1 Files

| File | Change |
|---|---|
| `scripts/dev-lead-intent.sh` | EXTEND — `pull_request_review`, `pull_request_review_comment`, `issue_comment` (bot) |
| `scripts/dev-lead-fix-reviews.sh` | CREATE — handles `fix-reviews` and `fix-bot-comment` |
| `tests/dev-lead/unit/test_intent_reviews.bats` | CREATE |
| `tests/dev-lead/unit/test_fix_reviews.bats` | CREATE |
| `tests/dev-lead/integration/test_review_intent.sh` | CREATE |

### 3.2 Thread resolution token requirement

Resolving GitHub review threads via GraphQL (`resolveReviewThread`) requires the token used to authenticate the request to be from a user who either:
- Submitted the review being resolved, OR
- Has admin/maintain permissions on the repository

`GH_PAT_WORKFLOWS` (as the PAT owner, who is an `OWNER`) satisfies this. `github.token` does NOT. The `dev-lead-fix-reviews.sh` script must use `GH_PAT_WORKFLOWS` for all GraphQL mutations. If `GH_PAT_WORKFLOWS` is absent, the handler skips thread resolution and posts a warning comment.

### 3.3 Idempotency for fix-reviews

Marker format: `<!-- dev-lead-reviews sha=<HEAD_SHA> resolved=<count> -->`

Scanned on every `fix-reviews` trigger before acting.

### 3.4 Unit tests: `test_intent_reviews.bats` (15 cases)

- `pull_request_review`: copilot `COMMENTED` → `fix-reviews` ✓
- `pull_request_review`: copilot `APPROVED` → `skip` ✓
- `pull_request_review`: gemini `CHANGES_REQUESTED` → `fix-reviews` ✓
- `pull_request_review`: human `OWNER` → `human-pr` ✓
- `pull_request_review`: human `NONE` (external) → `skip` ✓
- `pull_request_review`: fork PR → `skip` ✓
- `pull_request_review`: self-actor → `skip` ✓
- `pull_request_review_comment`: copilot inline → `fix-reviews` ✓
- `pull_request_review_comment`: human + `@dev-lead` → `human` ✓
- `pull_request_review_comment`: human, no trigger → `skip` ✓
- `issue_comment`: sonarqube on PR → `fix-bot-comment` ✓
- `issue_comment`: coderabbit on PR → `fix-bot-comment` ✓
- `issue_comment`: human + `@dev-lead` → `human` ✓
- `issue_comment`: human, no trigger → `skip` ✓
- `issue_comment`: rebase sentinel → `rebase` ✓

### 3.5 Unit tests: `test_fix_reviews.bats` (9 cases)

- Thread classification: suggestion block → `apply-suggestion` ✓
- Thread classification: code feedback → `fix-code` ✓
- Thread classification: architectural question → `discuss` ✓
- Apply suggestion: suggestion block applied correctly ✓
- Idempotency: existing `<!-- dev-lead-reviews sha=... -->` → skip ✓
- Dry-run: no commits pushed ✓
- Missing `GH_PAT_WORKFLOWS`: thread resolution skipped, warning posted ✓
- Rebase before fix: branch is up to date before touching files ✓
- Multi-cycle: new threads after push re-triggers inner loop ✓

### 3.6 Phase 3 definition of done

- [ ] All unit tests pass (24 cases)
- [ ] Integration: `test_review_intent.sh` runs all 24 fixture events and verifies classification
- [ ] Manual E2E: Copilot review on test PR → all threads resolved, summary posted, CI green

---

## Phase 4 — Human Interaction and Rebase

**Goal:** `@dev-lead` mentions and rebase sentinel work end-to-end.

### 4.1 Files

| File | Change |
|---|---|
| `scripts/dev-lead-fix-reviews.sh` | EXTEND — `human`, `human-pr`, `rebase` intents |
| `tests/dev-lead/unit/test_fix_reviews_human.bats` | CREATE |
| `tests/dev-lead/unit/test_fix_rebase.bats` | CREATE |

### 4.2 Unit tests: `test_fix_reviews_human.bats` (5 cases)

- Human instruction executed via `run_writer()` ✓
- User instruction included in prompt ✓
- Dry-run: no commit ✓
- Anti-loop: agent's own reply to comment doesn't re-trigger ✓
- Empty instruction (just `@dev-lead` with no text) → asks for clarification ✓

### 4.3 Unit tests: `test_fix_rebase.bats` (6 cases)

- YAML SHA conflict: newer semver wins ✓
- YAML SHA conflict: both sides same version → keeps base ✓
- YAML SHA conflict: version cannot be determined → abort ✓
- Non-YAML conflict → abort immediately ✓
- Successful rebase → push with `--force-with-lease` ✓
- Abort → failure comment includes manual instructions ✓

### 4.4 Phase 4 definition of done

- [ ] All unit tests pass (11 cases)
- [ ] Human `@dev-lead rename foo to bar` on test PR → rename applied and pushed
- [ ] Rebase sentinel on test PR with YAML conflict → conflict resolved correctly

---

## Phase 5 — Issue Implementation

**Goal:** Issues labeled `dev-lead` trigger full implementation → PR → self-review.

### 5.1 Files

| File | Change |
|---|---|
| `scripts/dev-lead-intent.sh` | EXTEND — `issues` labeled classification |
| `scripts/dev-lead-fix-issue.sh` | CREATE |
| `tests/dev-lead/unit/test_intent_issue.bats` | CREATE |
| `tests/dev-lead/unit/test_fix_issue.bats` | CREATE |

### 5.2 Unit tests: `test_intent_issue.bats` (4 cases)

- `labeled dev-lead` → `issue` ✓
- `labeled claude` → `issue` (backward compat) ✓
- `labeled bug` → `skip` ✓
- `labeled dev-lead` without issue body → `issue` with empty context ✓

### 5.3 Unit tests: `test_fix_issue.bats` (6 cases)

- Dedup: existing open PR found → skip with comment ✓
- Dedup: no existing PR → proceed ✓
- Org standards hint included in prompt ✓
- SHA lookup failure → PR opened without pin, blocker noted in body ✓
- CI failure on opened PR → inline fix attempt (calls fix-ci logic) ✓
- CODEOWNERS tagged in final comment ✓

### 5.4 Phase 5 definition of done

- [ ] All unit tests pass (10 cases)
- [ ] Label test issue → PR opened, self-reviewed, CI green, CODEOWNERS tagged

---

## Phase 6 — Engine Generalization

**Goal:** All handlers work identically with Gemini as primary engine. Fallback chain tested.

### 6.1 Files

| File | Change |
|---|---|
| `scripts/engine.sh` | EXTEND — `run_writer_with_fallback()` function |
| `tests/dev-lead/unit/test_engine_fallback.bats` | CREATE |

### 6.2 `run_writer_with_fallback()`

```bash
run_writer_with_fallback() {
  local prompt_file="$1"
  local model="${2:-$ENGINE_ACTION_MODEL}"
  local engines=("$REVIEW_ENGINE")

  # Build fallback chain from available engines
  for e in claude gemini copilot; do
    [ "$e" != "$REVIEW_ENGINE" ] && engines+=("$e")
  done

  for engine in "${engines[@]}"; do
    local saved="$REVIEW_ENGINE"
    REVIEW_ENGINE="$engine" run_writer "$prompt_file" "$model"
    rc=$?
    REVIEW_ENGINE="$saved"
    [ "$rc" -eq 0 ] && return 0
    [ "$rc" -eq 2 ] && { echo "::warning::$engine rate-limited, trying next engine"; continue; }
    return "$rc"  # non-rate-limit failure: don't fallback
  done

  echo "::error::All engines rate-limited or unavailable"
  return 2
}
```

### 6.3 Unit tests: `test_engine_fallback.bats` (5 cases)

- Claude rate-limit → Gemini invoked ✓
- Claude + Gemini rate-limit → Copilot (Claude fallback internally) ✓
- All rate-limited → exit 2, exhaustion path triggered ✓
- Claude non-rate-limit exit 1 → no fallback (deterministic failure) ✓
- Available engine order respected (primary first) ✓

### 6.4 Phase 6 definition of done

- [ ] All unit tests pass (5 cases)
- [ ] `DEV_LEAD_ENGINE=gemini` passes Phase 2 E2E

---

## Phase 7 — Retirement (claude.yml — Option A: Delete)

**Goal:** Remove `claude.yml` from `.github-private` after a 2-week shadow period.

### 7.1 Shadow period (2 weeks before deletion)

Both `claude.yml` and `dev-lead.yml` run in parallel. Each run is tagged in the step summary. Monitor for:
- Events handled by `dev-lead.yml` that were previously handled by `claude.yml`
- Any regressions (events that should trigger but don't)
- Duplicate runs for the same event

### 7.2 Deletion checklist

- [ ] 14 days of parallel operation with no regressions
- [ ] All intent types covered by `dev-lead.yml` (confirmed via Actions run history)
- [ ] Delete `.github/workflows/claude.yml` from `.github-private`
- [ ] Update `AGENTS.md` — replace `claude.yml` exemption with `dev-lead.yml`
- [ ] Update `petry-projects/.github` — mark `claude.yml` as deprecated in `ci-standards.md`
- [ ] Update `standards/workflows/` — `claude.yml` deprecation notice, pointer to `dev-lead.yml`
- [ ] File issue to notify other repos using `claude.yml` to migrate to `dev-lead.yml`

---

## Phase 8 — Cross-repo Rollout

**Goal:** Propagate the `dev-lead.yml` standard to other `petry-projects` repos.

### 8.1 Rollout order

1. `petry-projects/.github-private` ← already on dev-lead (this repo)
2. `petry-projects/.github` ← adopts caller stub; becomes a user of the standard it defines
3. High-activity repos (3–5 PRs/week) — validate in real-world conditions
4. All other repos — batch rollout via an issue labeled `dev-lead` in each repo

### 8.2 Migration from `claude.yml` to `dev-lead.yml`

For each repo:
1. Add `dev-lead.yml` (copy standard from `petry-projects/.github/standards/workflows/dev-lead.yml`)
2. Run both in parallel for 1 week
3. Delete `claude.yml` when no regressions observed

### 8.3 Phase 8 definition of done

- [ ] `dev-lead-reusable.yml` works correctly from at least 2 different repos
- [ ] Private repo access settings configured org-wide
- [ ] Migration guide documented in `standards/ci-standards.md` §5

---

## Testing Summary

### Unit test suite

| File | Phase | Cases |
|---|---|---|
| `test_prompt_rendering.bats` | 0.3 | 3 |
| `test_intent_stub.bats` | 1 | 5 |
| `test_intent_ci.bats` | 2 | 8 |
| `test_engine_writer.bats` | 2 | 7 |
| `test_fix_ci.bats` | 2 | 8 |
| `test_intent_reviews.bats` | 3 | 15 |
| `test_fix_reviews.bats` | 3 | 9 |
| `test_fix_reviews_human.bats` | 4 | 5 |
| `test_fix_rebase.bats` | 4 | 6 |
| `test_intent_issue.bats` | 5 | 4 |
| `test_fix_issue.bats` | 5 | 6 |
| `test_engine_fallback.bats` | 6 | 5 |
| **Total** | | **81 cases** |

### Integration test suite

| File | Phase | Cases |
|---|---|---|
| `test_prompt_coverage.sh` | 0.3 | 7 prompts × N vars |
| `test_ci_relay.sh` | 2 | 6 |
| `test_full_pipeline_dryrun.sh` | 2 | 5 |
| `test_review_intent.sh` | 3 | 24 fixture events |
| `test_issue_dedup.sh` | 5 | 3 |

### E2E test scenarios (manual)

| Phase | Scenario | Pass criteria |
|---|---|---|
| 1 | Open PR → `dispatch` logs `skip` | No LLM tokens consumed |
| 2 | Dry-run: push lint error → verify prompt | No commit made |
| 2 | Live: push lint error → CI green | Fix committed within 5 min |
| 1.5 | Caller repo adopts stub → events fire | Reusable is invoked |
| 3 | Copilot review → threads resolved | Summary posted, CI green |
| 4 | `@dev-lead rename x to y` | Rename applied and pushed |
| 5 | Issue labeled → PR → CI green | CODEOWNERS tagged |
| 6 | `DEV_LEAD_ENGINE=gemini` + lint error | Gemini fixes it |
| 7 | `claude.yml` deleted | `test-dev-lead.yml` still green |

---

## Open Items (Resolved)

| # | Item | Resolution |
|---|---|---|
| 1 | Trigger phrase migration | `@claude` kept in `TRIGGER_PHRASES` default — no breaking change |
| 2 | `claude.yml` retirement | **Option A: delete** (Phase 7, after 2-week shadow period) |
| 3 | Cross-repo adoption | **Phase 1.5** — `dev-lead-reusable.yml` + `.github` caller stub standard |
| 4 | Prompt extraction | **Phase 0.3** — prompt library defined before any handler is written |
| 5 | Audit log | PR comment markers (`<!-- dev-lead-fix sha=... -->`) serve as lightweight audit trail; structured log file deferred |

---

_See also: [Dev-Lead Spec](./spec.md) · [Engine Script](../../scripts/engine.sh) · [PR Review Agent](../pr-review-agent/implementation.md)_
