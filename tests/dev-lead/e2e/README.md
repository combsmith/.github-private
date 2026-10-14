# Dev-Lead Agent — E2E Test Suite

End-to-end tests for the dev-lead agent. These tests exercise the full routing
and intent-classification pipeline, from GitHub event → intent → handler.

## Quick start

```bash
# Run all scenarios (fixture-based ones run locally; live ones require GH_TOKEN)
bash tests/dev-lead/e2e/run-all.sh

# Dry run: see what would execute without doing anything
bash tests/dev-lead/e2e/run-all.sh --dry-run

# Run a single scenario by name fragment
bash tests/dev-lead/e2e/run-all.sh --scenario 05-skip-anti-loop
```

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `GH_TOKEN` or `GH_PAT` | For live scenarios (02–04) | GitHub PAT with `repo` scope |
| `CLAUDE_CODE_OAUTH_TOKEN` | Optional | Claude token; omit to skip response-content assertions |
| `E2E_TARGET_REPO` | No | Override target repo (default: `petry-projects/.github-private`) |
| `E2E_CLEANUP` | No | Set `false` to keep test PRs/branches/issues after run (default: `true`) |

## Scenarios

### 01 — skip-bot-pr (fixture-based, no network)

**What it tests:** A PR opened by `dependabot[bot]` is classified as `skip` with reason `bot-pr`.

**How it works:** Runs `dev-lead-intent.sh` locally against the fixture
`tests/dev-lead/fixtures/events/pr_opened_dependabot.json` and asserts
`INTENT_TYPE=skip` and `INTENT_REASON=bot-pr`.

**Requires:** Nothing (fully local).

---

### 02 — human-at-mention (live)

**What it tests:** A human comment `@dev-lead what does this PR change?` on a
PR triggers the `human` intent and the Dev-Lead Agent workflow runs.

**How it works:**
1. Creates a test branch and PR.
2. Posts an `@dev-lead` comment via `gh pr comment`.
3. Waits for the `Dev-Lead Agent` workflow to complete on the PR's head SHA.
4. Asserts the workflow conclusion is `success` (or `neutral` in dry-run mode).

**Requires:** `GH_TOKEN`. `CLAUDE_CODE_OAUTH_TOKEN` for agent response (otherwise
skips response-content assertion).

---

### 03 — ci-failure-relay (live)

**What it tests:** A failing check_run on a PR triggers the ci-relay job →
`repository_dispatch` event → fix-ci intent → `Run fix-ci` step executes.

**How it works:**
1. Pushes a shell script with a deliberate syntax error to a new branch.
2. Creates a PR — this triggers CI (shellcheck / bash -n will fail).
3. Waits for a `check_run` failure on the PR head SHA.
4. Waits for the `Dev-Lead Agent` workflow triggered by the `check_run` event
   (ci-relay job) to complete.
5. Waits for the subsequent `Dev-Lead Agent` workflow triggered by
   `repository_dispatch` (fix-ci dispatch) to complete.
6. Asserts both workflows conclude `success`.

**Requires:** `GH_TOKEN`. CI must run on the target repo.

---

### 04 — issue-labeled (live)

**What it tests:** Adding the `dev-lead` label to an issue triggers the `issue`
intent and the `Run issue` step executes.

**How it works:**
1. Creates a test issue.
2. Adds the `dev-lead` label via `gh issue edit`.
3. Waits for the `Dev-Lead Agent` workflow triggered by the `issues` event.
4. Asserts workflow conclusion is `success` or `neutral`.

**Requires:** `GH_TOKEN`. `dev-lead` label must exist on the repo (the test
attempts to create it if missing).

---

### 05 — skip-anti-loop (fixture-based, no network)

**What it tests:**
- Part A: A `pull_request synchronize` event from `donpetry-bot` (BOT_USER)
  emits `skip` with reason `dev-lead-own-commit`.
- Part B: The same event from a human user correctly emits `human-pr` (not
  skipped by the anti-loop guard).

**How it works:** Runs `dev-lead-intent.sh` twice:
1. Against `tests/dev-lead/fixtures/events/pr_sync_dev_lead_commit.json`
   (sender = `donpetry-bot`).
2. Against an inline fixture with sender = `donpetry` (human).

**Requires:** Nothing (fully local). This is the fastest scenario.

---

### 06 — exhaustion-guard (script-based, stub network)

**What it tests:**
- Part A: After `MAX_FAIL_ATTEMPTS` consecutive engine failures, the fix-ci
  script posts a PR-level exhaustion marker and the output contains
  `status=exhausted`.
- Part B: A pre-existing PR-level exhaustion marker causes the script to exit 0
  immediately (blocked, not failed).

**How it works:** Runs `dev-lead-fix-ci.sh` directly with a stub `gh` binary
that returns pre-seeded failure comments, and a stub `claude` binary that exits
with code 1 (simulating an engine failure).

**Requires:** Nothing (fully local).

---

### 07 — rate-limit-retry (script-based, stub network)

**What it tests:** Rate-limit handling and retry infrastructure across fix-ci, fix-reviews, and the retry scanner.

**Parts:**
- **A:** `dev-lead-fix-ci.sh` exits 2 (not 1) and posts `status=rate-limited` when all engines are rate-limited.
- **B:** Rate-limited markers do **not** count toward the exhaustion threshold (`MAX_FAIL_ATTEMPTS`).
- **C:** A pre-existing `status=rate-limited` marker is retriable — idempotency check does not block a second attempt.
- **D:** `dev-lead-fix-reviews.sh` exits 2 and posts a rate-limited marker for the `fix-reviews` intent.
- **E:** `fix-reviews` on-mention intent exits 2 and emits user-visible rate-limit/re-trigger acknowledgment.
- **F:** `dev-lead-retry.sh` dry-run scan identifies PRs with rate-limited markers and reports would-dispatch.
- **G:** Retry skips a PR whose `human-pr` rate-limited marker has a corresponding `review-changes` terminal marker.
- **H:** Retry normalizes `human-pr` → `review-changes` intent when dispatching a retry.

**How it works:** Runs fix-ci, fix-reviews, and retry scripts directly using stub `claude`/`gemini`/`copilot` and `gh` binaries — no real GitHub API calls.

**Requires:** Nothing (fully local).

---

## Results

Each run writes results to `tests/dev-lead/e2e/results/`:

- `results.txt` — one line per scenario: `<timestamp> [PASS|FAIL|SKIP] <scenario>: <details>`
- `summary-<timestamp>.txt` — human-readable summary of the complete run

## Directory layout

```
tests/dev-lead/e2e/
├── run-all.sh              Master orchestrator
├── lib/
│   └── helpers.sh          Shared helpers (create_test_branch, wait_for_workflow, etc.)
├── scenarios/
│   ├── 01-skip-bot-pr.sh
│   ├── 02-human-at-mention.sh
│   ├── 03-ci-failure-relay.sh
│   ├── 04-issue-labeled.sh
│   ├── 05-skip-anti-loop.sh
│   ├── 06-exhaustion-guard.sh
│   └── 07-rate-limit-retry.sh
├── results/                Created at runtime — gitignored
└── README.md
```

## Running in CI

The E2E suite is designed to be runnable by the dev-lead agent itself via a
`workflow_dispatch` or as a scheduled job. Local (fixture/stub-based) scenarios (01, 05, 06, 07)
are safe to run in any environment without credentials. Live scenarios (02–04)
require a `GH_TOKEN` secret with `repo` scope.

```yaml
- name: Run E2E local scenarios
  run: |
    bash tests/dev-lead/e2e/run-all.sh --scenario 01-skip-bot-pr
    bash tests/dev-lead/e2e/run-all.sh --scenario 05-skip-anti-loop
    bash tests/dev-lead/e2e/run-all.sh --scenario 06-exhaustion-guard
    bash tests/dev-lead/e2e/run-all.sh --scenario 07-rate-limit-retry
```
