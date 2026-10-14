# Dev-Lead Agent — Architecture Specification

**Status:** Draft  
**Version:** 0.1.0  
**Repo:** `petry-projects/.github-private`  
**Primary workflow:** `.github/workflows/dev-lead.yml` _(planned)_  
**Related:** [`docs/pr-review-agent/`](../pr-review-agent/), [`scripts/engine.sh`](../../scripts/engine.sh)

---

## 1. Purpose

The **dev-lead agent** is an event-driven, engine-agnostic automation that keeps pull requests in a clean, approvable, and mergeable state without human intervention for routine work.

When a CI check fails, a trusted bot leaves a review, or a human mentions `@claude` on a PR, the agent:

1. Classifies the incoming event as a structured **intent**
2. Selects the appropriate **engine** (Claude, Gemini, or Copilot) and **model tier**
3. Builds a context-rich **prompt** specific to that intent
4. Runs the agent with write access to diagnose, fix, commit, push, and comment
5. Waits for CI to settle and repeats if new failures appear

The agent is the reactive counterpart to the [PR Review Agent](../pr-review-agent/pr-review-agent.md) (which is proactive and read-only). The dev-lead agent is reactive and write-enabled.

### Interaction contract

dev-lead pairs a **Class 1 event-driven role** with a **Class 2 self-heal backstop timer** (dev-lead-retry.yml) under the
[agentic interaction model](../agentic-interaction-model.md) (the normative standard). Its
trigger/emit/idempotency pattern is declared as machine-readable, CI-verified contracts, not
prose in this spec:

- **Runtime lens** — [`interaction-contracts/dev-lead.yml`](../../interaction-contracts/dev-lead.yml)
  (the deployed workflow's `on:` events, emits, idempotency key, concurrency lane, and budget).
- **Role lens** — [`personas/dev-lead/interaction.yml`](../../personas/dev-lead/interaction.yml)
  (the persona-manifest view of the same pattern).

When this spec's event taxonomy (§4) or the workflow triggers (§7.1) change, update those
contracts and the standard's §4 classification table in the same change.

---

## 2. Design Principles

| Principle | Detail |
|---|---|
| **Engine-agnostic** | All LLM calls go through `engine.sh`. Swapping `DEV_LEAD_ENGINE=gemini` changes every invocation without touching prompts or scripts. |
| **Intent-first routing** | Events are classified into named intents before any LLM is invoked. Trust gates, deduplication, and skip logic live in the classification layer, not scattered across job conditions. |
| **Primary workflow in `.github-private`** | All logic lives in this repo. No dependency on the central org reusable (`petry-projects/.github/claude-code-reusable.yml`). Changes propagate immediately without cross-repo PRs. |
| **No OIDC constraint** | The agent uses `CLAUDE_CODE_OAUTH_TOKEN` / `GOOGLE_API_KEY` / `COPILOT_GITHUB_TOKEN` directly via CLI, not via `claude-code-action`. The OIDC byte-for-byte invariant does not apply; the workflow file is freely modifiable via PRs. |
| **Write-minimal** | The agent only commits and pushes when it has substantive changes. No empty commits, no force-pushes to protected branches. |
| **Idempotent** | Each intent handler checks for existing work before acting (SHA markers, open PR detection, recent fix comments). A second trigger for the same event is a no-op. |
| **Transparent** | Every agent run posts a structured comment on the PR (or issue) explaining what it found, what it changed, and what it left for humans. |

---

## 3. Architecture Overview

```
GitHub Event
     │
     ▼
dev-lead.yml ──► dispatch job
                     │
                     ▼
             dev-lead-intent.sh   ←── trust gates, skip logic
                     │
            ┌────────┴────────────────┬──────────────────┐
            ▼                         ▼                   ▼
     fix-ci intent           fix-reviews intent     issue intent
            │                         │                   │
            ▼                         ▼                   ▼
  dev-lead-fix-ci.sh    dev-lead-fix-reviews.sh   dev-lead-fix-issue.sh
            │                         │                   │
            └────────────┬────────────┘                   │
                         ▼                                ▼
                    engine.sh::run_writer()         engine.sh::run_writer()
                         │                                │
              ┌──────────┼──────────┐                    │
              ▼          ▼          ▼                    ▼
           claude      gemini    copilot*           claude (primary)
              │          │          │
              └──────────┴──────────┘
                         │
                    Writes fix to PR branch
                    Posts summary comment
                    Waits for CI
```

_\*Copilot engine falls back to Claude for write operations (GitHub Models API is text-only)._

**Separate relay job** (no LLM):

```
check_run (completed, failure)
     │
     ▼
ci-relay job in dev-lead.yml
     │  resolves PR number, fork check
     ▼
repository_dispatch: dev-lead-ci-failure
     │  (structured payload: pr, check name, SHA, details URL, annotations URL)
     ▼
dispatch job (handles as fix-ci intent)
```

---

## 4. Event Taxonomy

Every GitHub webhook event that reaches `dev-lead.yml` is classified into exactly one intent. The classification happens in `dev-lead-intent.sh` before any script or LLM is invoked.

### 4.1 Event → Intent mapping

| GitHub Event | Actor / Condition | Intent | Handler |
|---|---|---|---|
| `pull_request` opened/sync | Not fork, not dependabot | `human-pr` | `dev-lead-fix-reviews.sh` |
| `pull_request_review` submitted | Trusted bot (Copilot, Gemini) | `fix-reviews` | `dev-lead-fix-reviews.sh` |
| `pull_request_review` submitted | Human OWNER/MEMBER/COLLABORATOR | `human-pr` | `dev-lead-fix-reviews.sh` |
| `pull_request_review_comment` created | Trusted bot | `fix-reviews` | `dev-lead-fix-reviews.sh` |
| `pull_request_review_comment` created | Human OWNER/MEMBER/COLLABORATOR + `@claude`/`@dev-lead` | `human` | `dev-lead-fix-reviews.sh` |
| `issue_comment` created on PR | Trusted bot (`sonarqubecloud[bot]`, `coderabbitai[bot]`) | `fix-bot-comment` | `dev-lead-fix-reviews.sh` |
| `issue_comment` created on PR | Human OWNER/MEMBER/COLLABORATOR + trigger phrase | `human` | `dev-lead-fix-reviews.sh` |
| `issue_comment` created on PR | `<!-- auto-rebase-conflict:` marker | `rebase` | `dev-lead-fix-reviews.sh` |
| `issues` labeled `dev-lead` | Any | `issue` | `dev-lead-fix-issue.sh` |
| `check_run` completed, failure | Not a `dev-lead /` check | _relay only_ | `ci-relay` job |
| `repository_dispatch` `dev-lead-ci-failure` | Dispatched by `ci-relay` | `fix-ci` | `dev-lead-fix-ci.sh` |
| `repository_dispatch` `dev-lead-reviews-retry` | Dispatched by `dev-lead-retry` cron | _(payload `intent_type`)_ | `dev-lead-fix-reviews.sh` |
| `repository_dispatch` `dev-lead-issue-retry` | Dispatched by `dev-lead-retry` cron (#781) | `issue` | `dev-lead-fix-issue.sh` |
| All others | — | `skip` | (no-op) |

### 4.2 Intent definitions

**`fix-ci`** — A CI check has failed on an open PR. The agent diagnoses the failure by reading logs and annotations, applies the minimal code fix, commits, pushes, and monitors CI until green.

**`fix-reviews`** — One or more trusted bots have submitted a review or inline comment on an open PR. The agent works through all open (unresolved) review threads, applies fixes where possible, resolves each addressed thread, waits for CI, and posts a summary.

**`fix-bot-comment`** — A trusted external-tool bot (SonarCloud, CodeRabbit) posted a general PR comment (not an inline review) reporting issues. The agent reads the comment, diagnoses the root cause, and applies a fix.

**`human`** — A human with write access mentioned the trigger phrase (`@claude` or `@dev-lead`) in a PR comment or review comment. The agent responds conversationally and performs the requested action.

**`human-pr`** — A new PR was opened/synchronized or a human submitted a review. The agent reads the PR and all open review threads, addresses anything it can, and posts a status comment.

**`issue`** — An issue was labeled `dev-lead`. The agent implements the issue, opens a PR, self-reviews, and tags CODEOWNERS when CI is green.

**`rebase`** — An auto-rebase-conflict sentinel comment was posted on a PR. The agent performs an agentic rebase, resolving conflicts per the conflict-resolution strategy, and pushes.

**`skip`** — No action required. Reasons: fork PR, dependabot, untrusted actor, already handled at this SHA, CI still pending.

---

## 5. Trust Model

Trust gates are evaluated in `dev-lead-intent.sh` before any other logic. An event that fails a gate produces intent `skip` with a reason string; it never reaches a handler script.

### 5.1 Gate order

```
1. Fork check          — head.repo.full_name == github.repository
2. Bot origin check    — if actor is a bot, must be in TRUSTED_BOTS
3. Human auth check    — if actor is human, must have author_association ∈ {OWNER, MEMBER, COLLABORATOR}
4. Self-exclusion      — actor must not be BOT_USER (the agent itself)
5. Dedup check         — for issue intents: no existing open PR for this issue
6. SHA idempotency     — for fix-ci: no existing fix comment at this SHA
```

### 5.2 Trusted bot list

Configurable via `vars.TRUSTED_BOTS` (comma-separated). When unset, the default is
**derived from the reviewer-source registry** (`scripts/lib/reviewer-sources.tsv`) —
the single source of truth the trust check, advisory gate, and scorecard all project
from, so the list can never drift again (issue #1425). Each registry login with
`dev_lead_trusted=yes` contributes its `[bot]`-suffixed login:

```
copilot-pull-request-reviewer[bot]
gemini-code-assist[bot]
chatgpt-codex-connector[bot]
coderabbitai[bot]
sonarqubecloud[bot]
qodo-code-review[bot]
codeant-ai[bot]
graphite-app[bot]
cubic-dev-ai[bot]
```

The registry enforces the invariant _(can create a review thread) ⇒ (dev-lead may
act on it)_: any source that posts inline review comments (creating a blocking
review thread) **must** be trusted, or its thread becomes an unclearable merge block
(the 2026-08-02 graphite-app deadlock). `tests/test_reviewer_sources.bats` asserts
this in CI.

The `ci-relay` job separately gates on the check name not starting with `dev-lead /` to prevent recursive self-triggering.

### 5.3 Trigger phrases

For `human` intent: comment body must contain `@claude` or `@dev-lead` (configurable via `vars.TRIGGER_PHRASES`).

For `rebase` intent: comment body must contain the sentinel `<!-- auto-rebase-conflict:`.

Bot-triggered intents (`fix-reviews`, `fix-bot-comment`) do **not** require a trigger phrase — the bot's identity is sufficient.

---

## 6. Engine Abstraction

The dev-lead agent reuses and extends `scripts/engine.sh` from the PR Review Agent.

### 6.1 Engine selection

Controlled by `vars.DEV_LEAD_ENGINE` (default: `claude`). Valid values: `claude`, `gemini`, `copilot`.

The engine is selected once per workflow run. Handler scripts do not hardcode engine calls; they always call engine functions.

### 6.2 Existing engine functions (read-only, inherited)

| Function | Tool access | Use |
|---|---|---|
| `run_triage <prompt_file>` | No tools | Fast classification, cheap model |
| `run_agentic <prompt_file> <model> [tier]` | Bash, Read, Grep, Glob | Analysis/action/audit with file access |
| `run_duck <prompt_file> <model>` | Bash, Read, Grep, Glob | Cross-engine adversarial check |

### 6.3 New engine function: `run_writer()`

Added to `engine.sh` by this implementation. Provides full write access for code modification.

```bash
run_writer <prompt_file> [model]
```

| Engine | Implementation | Tool access |
|---|---|---|
| `claude` | `claude --print --permission-mode acceptEdits` | Bash, Read, Write, Edit, Grep, Glob |
| `gemini` | `gemini --approval-mode auto_edit` | Native file edit |
| `copilot` | Falls back to Claude (GitHub Models API is text-only) | Same as Claude |

**Fallback behavior:** If `run_writer()` exits with a rate-limit code (exit 2), the engine abstraction retries with the next available engine per the fallback chain: `claude → gemini → copilot`. This mirrors the existing `review-batch.sh` fallback logic.

### 6.4 Model tier selection per intent

| Intent | Triage model | Action model |
|---|---|---|
| `fix-ci` | `ENGINE_TRIAGE_MODEL` (Haiku/Flash) | `ENGINE_ACTION_MODEL` (Sonnet) |
| `fix-reviews` | — | `ENGINE_ACTION_MODEL` (Sonnet) |
| `fix-bot-comment` | `ENGINE_TRIAGE_MODEL` (Haiku/Flash) | `ENGINE_ACTION_MODEL` (Sonnet) |
| `human` | — | `ENGINE_DEEP_MODEL` (Sonnet) |
| `human-pr` | — | `ENGINE_ACTION_MODEL` (Sonnet) |
| `issue` | — | `ENGINE_SINGLE_MODEL` (Opus) |
| `rebase` | — | `ENGINE_ACTION_MODEL` (Sonnet) |

For the `claude` engine: Haiku 4.5 → triage, Sonnet 4.6 → action, Opus 4.7 → issue implementation.

---

## 7. Component Specification

### 7.1 `dev-lead.yml` — Primary workflow

**Location:** `.github/workflows/dev-lead.yml`

**Triggers:**

```yaml
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
```

**Jobs:**

| Job | Trigger condition | Purpose |
|---|---|---|
| `dispatch` | All events except `check_run` + `repository_dispatch` from ci-relay | Classify intent, run handler |
| `ci-relay` | `check_run` completed, failure, not `dev-lead / *` | Resolve PR, emit `repository_dispatch` |

**Concurrency:**

```yaml
# dispatch job
concurrency:
  group: dev-lead-${{ github.event.pull_request.number || github.event.issue.number || github.event.check_run.head_sha || github.run_id }}
  cancel-in-progress: false   # queue, do not cancel; idempotency handles duplicates

# ci-relay job
concurrency:
  group: dev-lead-ci-relay-${{ github.event.check_run.head_sha }}-${{ github.event.check_run.id }}
  cancel-in-progress: false   # each check_run gets its own relay slot
```

**Permissions (job-level):**

```yaml
permissions:
  contents: write
  pull-requests: write
  issues: write
  actions: read
  checks: read
  id-token: write   # reserved for future OIDC expansion
```

**Environment:**

```yaml
env:
  DEV_LEAD_ENGINE: ${{ vars.DEV_LEAD_ENGINE || 'claude' }}
  CLAUDE_CODE_VERSION: ${{ vars.CLAUDE_CODE_VERSION || 'latest' }}
  CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
  GOOGLE_API_KEY: ${{ secrets.GOOGLE_API_KEY }}
  GEMINI_API_KEY: ${{ secrets.GOOGLE_API_KEY }}
  COPILOT_GITHUB_TOKEN: ${{ secrets.GH_PAT_DON_PETRY }}
  GH_TOKEN: ${{ secrets.GH_PAT_DON_PETRY || secrets.GH_PAT_WORKFLOWS || github.token }}
  # Hardcoded fail-safe default only; the real value is resolved from
  # personas/dev-lead/persona.yml (runtime.identity.account = don-petry) by the
  # "Resolve persona identity" step. vars.BOT_USER is NOT consulted — that
  # shared variable caused the donpetry-bot regression (#1316). See persona-standards.md §5.1.
  BOT_USER: 'don-petry'
  TRUSTED_BOTS: ${{ vars.TRUSTED_BOTS || 'copilot-pull-request-reviewer[bot],gemini-code-assist[bot],coderabbitai[bot],sonarqubecloud[bot]' }}
  TRIGGER_PHRASES: ${{ vars.TRIGGER_PHRASES || '@claude,@dev-lead' }}
```

---

### 7.2 `dev-lead-intent.sh` — Intent classifier

**Location:** `scripts/dev-lead-intent.sh`

**Interface:** Reads GitHub event JSON from `$GITHUB_EVENT_PATH`. Writes intent vars to `$GITHUB_ENV`.

**Output variables (set in `$GITHUB_ENV`):**

| Variable | Values | Description |
|---|---|---|
| `INTENT_TYPE` | `fix-ci`, `fix-reviews`, `fix-bot-comment`, `human`, `human-pr`, `issue`, `rebase`, `skip` | Classified intent |
| `INTENT_PR` | integer or empty | PR number (empty for issue intent) |
| `INTENT_ISSUE` | integer or empty | Issue number (for issue intent) |
| `INTENT_ACTOR` | string | Login of triggering actor |
| `INTENT_ACTOR_TYPE` | `human`, `trusted-bot`, `untrusted-bot` | Classified actor type |
| `INTENT_SKIP_REASON` | string or empty | Human-readable skip explanation |
| `INTENT_CONTEXT_FILE` | path | JSON file with full event context for handler |

**`INTENT_CONTEXT_FILE` schema:**

```json
{
  "intent": "fix-ci",
  "pr_number": 175,
  "head_sha": "abc123",
  "check_name": "SonarCloud Code Analysis",
  "check_id": "76073706541",
  "details_url": "https://sonarcloud.io/...",
  "annotations_url": "https://api.github.com/repos/.../check-runs/76073706541/annotations",
  "actor": "sonarqubecloud[bot]",
  "actor_type": "trusted-bot",
  "pr_url": "https://github.com/petry-projects/.github-private/pull/175",
  "base_ref": "main",
  "head_ref": "fix/health-check",
  "review_body": null,
  "comment_body": "Quality Gate Failed ...",
  "open_thread_ids": []
}
```

**Classification algorithm:**

```
parse_event()
  → event_name, actor, actor_type, pr_number, ...

trust_gate(actor, actor_type, pr_is_fork)
  → trusted | untrusted | skip

if untrusted → emit skip, exit 0

classify_intent(event_name, actor_type, comment_body, review_state, label_name)
  → intent_type

build_context(intent_type, event_payload)
  → INTENT_CONTEXT_FILE

emit_env_vars()
```

---

### 7.3 `dev-lead-fix-ci.sh` — CI failure handler

**Location:** `scripts/dev-lead-fix-ci.sh`

**Input:** Reads `$INTENT_CONTEXT_FILE`.

**Behavior:**

1. **Idempotency check** — scan PR comments for `<!-- dev-lead-fix sha=<HEAD_SHA> -->`. If present, exit 0.
2. **Checkout PR branch** — `gh pr checkout $INTENT_PR`
3. **Triage (cheap model)** — classify failure type: `lint`, `test`, `build`, `type-check`, `security`, `config`, `external`
4. **Collect artifacts** — read logs via `gh run view --log-failed`, annotations via `gh api .../annotations`
5. **Build prompt** — include failure type, raw logs, annotations, relevant source files
6. **Run `run_writer()`** — apply fix
7. **Commit and push** — `git commit -m "fix(ci): ..."`, `git push`
8. **Wait for CI** — `gh pr checks $INTENT_PR --watch --interval 30`
9. **Loop (max 3 iterations)** — if new failures, restart from step 3 with the new check context
10. **Post summary comment** — include what was diagnosed, what was changed, CI status

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Success or idempotent skip |
| 1 | Fix attempted but CI still failing after MAX_CI_CYCLES |
| 2 | Rate limit / engine unavailable (triggers engine fallback in caller) |

---

### 7.4 `dev-lead-fix-reviews.sh` — Review and comment handler

**Location:** `scripts/dev-lead-fix-reviews.sh`

**Handles intents:** `fix-reviews`, `fix-bot-comment`, `human`, `human-pr`, `rebase`

**Behavior (common cycle):**

1. **Checkout PR branch** and rebase onto `origin/base_ref`
2. **Fetch open review threads** via GraphQL — collect thread node IDs
3. **For each unresolved thread:**
   - Classify as: `apply-suggestion`, `fix-code`, `discuss`, `skip-human`
   - For `apply-suggestion`: apply the suggestion block exactly
   - For `fix-code`: build targeted prompt, run `run_writer()`
   - For `discuss`: reply to thread explaining what human input is needed; leave unresolved
   - For `skip-human`: leave unresolved
4. **Commit and push** — single commit per cycle: `fix: address review comments`
5. **Resolve addressed threads** via GraphQL mutation
6. **Wait for CI** — `gh pr checks --watch --interval 30`
7. **Loop** — check for newly opened threads (bot responses to the push)
8. **Post summary comment**

**Additional behavior for `rebase` intent:**

Follows the existing `claude-rebase` logic: `git fetch origin`, `git rebase origin/<base>`, conflict resolution strategy (workflow YAML SHA version comparison; abort on application code conflicts), `git push --force-with-lease`.

**Additional behavior for `human` intent:**

Reads the specific comment body as the user's instruction. Executes it as an agentic task using `run_writer()` with the full PR context prepended to the instruction prompt.

#### Marker status vocabulary (`dev-lead-fix-reviews`)

Every `dev-lead-fix-reviews.sh` run records its outcome in a machine-readable HTML-comment
marker on the PR:

```
<!-- dev-lead-fix-reviews pr=<N> sha=<HEAD_SHA> intent=<intent> status=<status> [reason=<reason>] [reset=<ISO>] -->
```

This table is the **single source of truth** for the `status=` token — pick an existing
accurate token for any new hold rather than reusing a convenient one (issue #1568).

| `status=` | Meaning | Terminal? | Retriable by `dev-lead-retry.sh`? |
|---|---|---|---|
| `applied` | Fix(es) committed and pushed this cycle. | yes | no |
| `no-changes` | Ran cleanly; nothing needed changing. | yes | no |
| `failed` | Handler failed for a non-hold reason. | yes | no |
| `rate-limited` | **Genuine provider quota / rate-limit hold** — all AI engines returned a rate-limit signal (engine exit 2). `reason=rate-limit`. Carries the provider `reset=` when parseable. | no (hold) | yes |
| `blocked` | **Non-quota hold** — the engine ran fine but the PR still has hard blockers (failing/cancelled checks or `CHANGES_REQUESTED` reviews). `reason=blocked`. Carries a fixed +30-minute `reset=` backoff. | no (hold) | yes |

- **`rate-limited` is emitted only for genuine quota** (issue #1568). A non-quota hold uses
  `status=blocked`, so quota dashboards/reports/breakers that count rate-limit markers are not
  polluted by holds that have nothing to do with provider quota, and a maintainer seeing the
  marker is pointed at the real cause (PR blockers) instead of investigating quota.
- Prior to #1568 the blocked path reused `status=rate-limited reason=blocked` (a deliberate
  #461 deferral); the honest `reason=` field was already present, only the token was wrong.
- **Back-compat / transition.** `dev-lead-retry.sh` matches both hold tokens
  (`status=(rate-limited|blocked)`), so re-dispatch behaviour is unchanged and any pre-#1568
  `status=rate-limited reason=blocked` markers still in the wild remain retriable. The
  in-script dedup/expire helpers likewise match both tokens for the same reason.

---

### 7.5 `dev-lead-fix-issue.sh` — Issue implementation handler

**Location:** `scripts/dev-lead-fix-issue.sh`

**Input:** Reads `$INTENT_CONTEXT_FILE` (issue number, title, body).

**Behavior:**

1. **Dedup check** — scan for open PRs with `claude/issue-$ISSUE-` branch prefix or `Closes #$ISSUE` in body. If found, comment and exit 0.
2. **Checkout main** — `git checkout main && git pull`
3. **Build implementation prompt** — include issue title, body, org standards, CODEOWNERS
4. **Run `run_writer()` (Opus model)** — implement and open PR
5. **Self-review** — re-read PR diff, look for issues; push fixes if found
6. **Wait for CI** — fix any failures (calls `dev-lead-fix-ci.sh` logic inline)
7. **Tag CODEOWNERS** — post comment tagging relevant owners when CI is green

**Engine-failure handling (`handle_engine_failure`, #781).** When `run_writer_with_fallback`
fails (before a PR exists), the handler never exits silently. It classifies the cause from the
`/tmp/dev-lead-failure-reason` sidecar written by `engine.sh` (`rate-limited` | `missing-binary`
| `engine-error`), computes the attempt number from prior `<!-- dev-lead-issue <N> ... -->`
markers, and posts a comment with the cause, a run deep-link, and a redacted ~40-line tail of the
session output. Decision matrix (`MAX_ATTEMPTS=3`):

| Cause | `attempt < MAX` | `attempt ≥ MAX` |
|---|---|---|
| `missing-binary` | `dev-lead:needs-human` label + comment (deterministic infra — no retry) | _(same)_ |
| `rate-limited` / `engine-error` | retryable marker `<!-- dev-lead-issue <N> status=<failed\|rate-limited> attempt=<K> reason=<r> run=<id> [reset=ISO] -->` + comment | `dev-lead:needs-human` label + "retries exhausted" comment |

Exit codes are unchanged (`2` rate-limit, `1` otherwise). The retryable marker is what the
`dev-lead-retry` cron scans for to re-dispatch a `dev-lead-issue-retry`; an issue carrying the
`dev-lead:needs-human` label is skipped by the cron.

**Standards injection (always prepended to prompt):**

The prompt includes instructions to:
- Read `petry-projects/.github/standards/workflows/` templates before writing any workflow files
- Never fabricate action SHAs — always look them up via `gh api`
- Match org label colors/names exactly
- Follow `ci-standards.md` Action Pinning Policy

---

### 7.6 `ci-relay` job (inline in `dev-lead.yml`)

No external script. Runs entirely as a `run:` shell block within the job.

**Steps:**

```yaml
- name: Resolve PR number
  id: pr
  env:
    GH_TOKEN: ${{ env.GH_TOKEN }}
  run: |
    PR="${{ github.event.check_run.pull_requests[0].number }}"
    if [ -z "$PR" ]; then
      PR=$(gh api "repos/${{ github.repository }}/commits/${{ github.event.check_run.head_sha }}/pulls" \
        --jq '[.[] | select(.state == "open")] | first | .number // empty')
    fi
    # Fork guard
    if [ -n "$PR" ]; then
      HEAD_REPO=$(gh api "repos/${{ github.repository }}/pulls/$PR" --jq '.head.repo.full_name')
      [ "$HEAD_REPO" != "${{ github.repository }}" ] && PR=""
    fi
    echo "number=$PR" >> "$GITHUB_OUTPUT"

- name: Dispatch CI failure event
  if: steps.pr.outputs.number != ''
  env:
    GH_TOKEN: ${{ env.GH_TOKEN }}
  run: |
    gh api "repos/${{ github.repository }}/dispatches" \
      --method POST \
      --field event_type="dev-lead-ci-failure" \
      --raw-field client_payload='{
        "pr_number":       "${{ steps.pr.outputs.number }}",
        "check_name":      "${{ github.event.check_run.name }}",
        "check_id":        "${{ github.event.check_run.id }}",
        "conclusion":      "${{ github.event.check_run.conclusion }}",
        "head_sha":        "${{ github.event.check_run.head_sha }}",
        "details_url":     "${{ github.event.check_run.details_url }}",
        "app_slug":        "${{ github.event.check_run.app.slug }}"
      }'
```

---

## 8. Data Flows

### 8.1 CI failure (SonarCloud App → fix → green)

```
1. SonarCloud App posts check_run (conclusion=failure)
2. dev-lead.yml ci-relay job fires
3. ci-relay resolves PR #175, fork-guards, emits repository_dispatch:dev-lead-ci-failure
4. dev-lead.yml dispatch job fires (event: repository_dispatch)
5. dev-lead-intent.sh classifies → INTENT_TYPE=fix-ci, INTENT_PR=175
6. dev-lead-fix-ci.sh:
   a. Idempotency check (no prior fix at this SHA) → proceed
   b. gh pr checkout 175
   c. run_triage() → failure type: "security/quality"
   d. gh api .../check-runs/76073706541/annotations → fetch issues
   e. Build prompt with annotations + relevant source files
   f. run_writer(prompt, ENGINE_ACTION_MODEL) → applies fixes
   g. git commit -m "fix(ci): address SonarCloud quality gate" && git push
   h. gh pr checks 175 --watch → CI green
   i. Post summary comment with <!-- dev-lead-fix sha=<NEW_SHA> -->
```

### 8.2 Copilot review → address threads → CI green

```
1. Copilot submits pull_request_review (state=COMMENTED)
2. dev-lead.yml dispatch job fires (event: pull_request_review)
3. dev-lead-intent.sh:
   - actor=copilot-pull-request-reviewer[bot] → trusted-bot
   - review.state=COMMENTED, not APPROVED → fix-reviews
4. dev-lead-fix-reviews.sh:
   a. gh pr checkout 175 && git rebase origin/main
   b. GraphQL: fetch open review threads (2 threads, node IDs collected)
   c. Thread 1: suggestion block → apply exactly → git add
   d. Thread 2: code fix → run_writer() → applies fix
   e. git commit -m "fix: address review comments" && git push
   f. GraphQL: resolve thread 1 and thread 2
   g. gh pr checks --watch → CI green
   h. GraphQL: check for new threads → none
   i. Post summary comment
```

### 8.3 Human `@dev-lead` mention

```
1. Human posts: "@dev-lead please update the error message in line 47 to be more descriptive"
2. dev-lead.yml dispatch job fires (event: issue_comment)
3. dev-lead-intent.sh:
   - actor=don-petry, author_association=OWNER → human
   - comment contains "@dev-lead" trigger phrase → human intent
4. dev-lead-fix-reviews.sh (human mode):
   a. gh pr checkout 175
   b. Build prompt: [PR context] + [user instruction]
   c. run_writer(prompt, ENGINE_DEEP_MODEL) → updates error message
   d. git commit && git push
   e. Reply to comment: "Done — updated the error message..."
```

---

## 9. Configuration Reference

### 9.1 Repository variables (`vars.*`)

| Variable | Default | Description |
|---|---|---|
| `DEV_LEAD_ENGINE` | `claude` | Primary engine: `claude`, `gemini`, `copilot` |
| `CLAUDE_CODE_VERSION` | `latest` | Claude CLI version to install and cache |
| `TRUSTED_BOTS` | See §5.2 | Comma-separated list of trusted bot logins |
| `TRIGGER_PHRASES` | `@claude,@dev-lead` | Phrases that trigger human intent in comments |
| `BOT_USER` | `don-petry` (resolved from `personas/dev-lead/persona.yml` `runtime.identity.account`) | The account dev-lead acts as — commits/pushes and self-exclusion. Manifest-driven since #1316; the env value is only a fail-safe default. |
| `MAX_CI_CYCLES` | `3` | Max fix-CI loops before giving up |
| `MAX_REVIEW_CYCLES` | `3` | Max review-fix loops before giving up |
| `DEV_LEAD_LIVE_MODE` | `false` | If `true`, run live on all events; if `false`, dry-run for scheduled (N/A for event-driven) |

### 9.2 Secrets

| Secret | Required | Description |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Yes | Claude Code auth token |
| `GH_PAT_WORKFLOWS` | Recommended | PAT with `workflow` scope for pushing to `.github/workflows/` |
| `GOOGLE_API_KEY` | No | Enables Gemini engine and fallback |
| `GH_PAT` | No | PAT with Copilot subscription for Copilot engine |

### 9.3 Inherited from `engine.sh`

Per-engine model names are controlled by the same env vars used by the PR Review Agent. Each default
is the first model of that provider's tier chain in `scripts/lib/engine-models.sh` (the single source
of truth), so this table names the chain, not a concrete id:

| Variable | Claude default | Gemini default | Copilot default |
|---|---|---|---|
| `ENGINE_TRIAGE_MODEL` | `triage` chain primary (haiku family) | `triage` chain primary (Flash) | `o4-mini` |
| `ENGINE_ACTION_MODEL` | `action` chain primary (sonnet family) | `action` chain primary (Flash) | `o4-mini` |
| `ENGINE_DEEP_MODEL` | `deep` chain primary (opus family) | `deep` chain primary (Pro) | `o4-mini` |
| `ENGINE_SINGLE_MODEL` | `single` chain primary (opus family) | `single` chain primary (Pro) | `o4-mini` |

---

## 10. Error Handling and Fallback

### 10.1 Engine rate limiting

Handler scripts exit with code 2 on rate limit. The caller (job step) detects this and retries with the next available engine per the fallback chain:

```
claude → gemini → copilot → abort (post "rate limited" comment on PR)
```

This mirrors the `review-batch.sh` `session_engine_fallback()` pattern.

When **all** engines are exhausted, `run_writer_with_fallback` records the cause class to
`/tmp/dev-lead-failure-reason` (`rate-limited` | `missing-binary` | `engine-error`), and
`run_writer` persists the redacted session output to the run step summary on every exit path
(including the rate-limit early return). Downstream handlers read the sidecar to classify the
failure rather than collapsing everything into a generic exit code.

### 10.1a Failed initial issue implementations (#781)

A first issue implementation that fails at the engine step has no PR to attach a retry marker to,
so before #781 it stalled silently. Now `dev-lead-fix-issue.sh` posts a cause-bearing
`<!-- dev-lead-issue <N> status=<failed|rate-limited> attempt=<K> ... -->` marker (see §7.5), and
the `dev-lead-retry` cron's `scan_repo_issues` enumerates open `dev-lead`-labeled issues, finds
the newest such marker, and re-dispatches a `dev-lead-issue-retry` (honouring the rate-limit
`reset=` window and the `attempt < MAX_ATTEMPTS` ceiling, skipping issues that already have an open
PR or the `dev-lead:needs-human` label). After `MAX_ATTEMPTS` (3) the issue is labeled
`dev-lead:needs-human` and left for a human — the same terminal escalation used for deterministic
`missing-binary` infra failures.

### 10.2 CI still failing after MAX_CI_CYCLES

The handler posts a comment on the PR:

```
<!-- dev-lead-ci-exhausted sha=<SHA> -->
@don-petry: CI is still failing after 3 fix attempts. Manual intervention required.

Last failure: [check name] — [summary of last error]
```

The `<!-- dev-lead-ci-exhausted -->` marker prevents future `fix-ci` intents for the same SHA.

### 10.3 Rebase conflicts in application code

`dev-lead-fix-reviews.sh` (rebase mode) aborts immediately on non-workflow conflicts and posts:

```
Auto-rebase failed: conflict in src/foo.ts — application logic conflicts require human resolution.
Manual steps: git fetch origin && git rebase origin/main ...
```

### 10.4 Dispatch token requirements

The `ci-relay` job uses `GH_PAT_WORKFLOWS || github.token` to emit `repository_dispatch`. If `github.token` is used (no PAT configured), the `contents: write` permission must be granted at the job level. If the dispatch fails (401/403), the job logs an error and exits 0 — it does not fail the check_run status.

---

## 11. Relation to Existing Workflows

| Workflow | Relation |
|---|---|
| `pr-review.yml` | Complementary. PR Review Agent is proactive (schedule, read-only, approval decisions). Dev-lead is reactive (events, write-enabled, fixing). They do not duplicate. |
| `auto-rebase.yml` | Dev-lead absorbs the rebase intent. `auto-rebase.yml` can continue to post the sentinel comment; dev-lead handles it instead of the current `claude-rebase` job. |
| `claude.yml` (current) | **Superseded.** Once dev-lead is stable, `claude.yml` is retired. The thin-caller pattern and the central `claude-code-reusable.yml` are no longer used by `.github-private`. |
| `agent-shield.yml` | Unaffected. Continues to run as a security gate on all workflows. Dev-lead is not exempt from AgentShield checks. |
| `dependabot-automerge.yml` | Dev-lead does not touch dependabot PRs. The `dispatch` job's trust gate skips any PR where `actor == 'dependabot[bot]'`. |

---

## 12. Migration Plan

### Phase 1 — Scaffold (no behavior change)
- [ ] Create `docs/dev-lead/` directory with this spec
- [ ] Create `scripts/dev-lead-intent.sh` (stub — outputs `skip` for all events)
- [ ] Create `dev-lead.yml` with all triggers, both jobs, calling the stub
- [ ] Verify all triggers fire correctly without any agent running

### Phase 2 — CI fix path
- [ ] Implement `ci-relay` job (no LLM)
- [ ] Implement `dev-lead-fix-ci.sh` (Claude engine only)
- [ ] Extend `engine.sh` with `run_writer()`
- [ ] End-to-end test: trigger a SonarCloud failure, verify fix is applied

### Phase 3 — Review fix path
- [ ] Implement `dev-lead-fix-reviews.sh` (fix-reviews + fix-bot-comment intents)
- [ ] End-to-end test: Copilot review → threads addressed → CI green

### Phase 4 — Human interaction
- [ ] Add `human` and `human-pr` intent handling to `dev-lead-fix-reviews.sh`
- [ ] Add `rebase` intent
- [ ] Retire `claude-rebase` job from `claude.yml`

### Phase 5 — Issue implementation
- [ ] Implement `dev-lead-fix-issue.sh`
- [ ] Retire `claude-issue` job from `claude.yml`

### Phase 6 — Engine generalization
- [ ] Add Gemini path to `run_writer()` in `engine.sh`
- [ ] Add engine fallback logic to handler scripts
- [ ] End-to-end test with `DEV_LEAD_ENGINE=gemini`

### Phase 7 — Retirement
- [ ] Remove `claude.yml` from `.github-private`
- [ ] Update `AGENTS.md` — remove `claude.yml` exemption
- [ ] Update org standards to document `.github-private` as the primary implementation

---

## 13. Acceptance Criteria

| Scenario | Expected behaviour |
|---|---|
| SonarCloud quality gate fails on open PR | Claude diagnoses, fixes, pushes within 5 min |
| Copilot submits COMMENTED review | All addressable threads resolved, CI green, summary posted |
| Human posts `@dev-lead fix the linting errors` | Linting errors fixed, pushed, confirmed with reply |
| Issue labeled `dev-lead` | PR opened, self-reviewed, CODEOWNERS tagged when green |
| Fork PR triggers any event | No-op, skip logged |
| `claude-code-action` rate limit | Engine falls back to Gemini, then Copilot |
| CI still failing after 3 cycles | Exhaustion comment posted, no further retries at same SHA |
| Same check_run fires twice | Second relay is a no-op (SHA idempotency) |
| dev-lead check itself fails | `!startsWith(check_name, 'dev-lead / ')` gate prevents self-loop |

---

## 14. Open Questions

1. **Trigger phrase migration** — Should existing `@claude` mentions continue working? Proposal: keep `@claude` in `TRIGGER_PHRASES` default so there is no breaking change for humans.

2. **`claude.yml` retirement timing** — Should the old caller stub remain as a no-op redirect (forwarding to `dev-lead.yml`) during the transition, or be deleted immediately in Phase 7?

3. **Cross-repo scope** — The dev-lead agent currently only handles events in `.github-private`. Should it eventually handle events across all `petry-projects` repos (similar to how `pr-review.yml` enumerates org-wide PRs)?

4. **Prompt library** — Should prompts be extracted to `prompts/dev-lead/` (matching the PR Review Agent pattern) for easier review and tuning, or kept inline in handler scripts?

5. **Audit log** — Should every agent run append a structured record to a persistent log (e.g., `logs/dev-lead-runs.jsonl`) for debugging and cost tracking?

---

_See also: [PR Review Agent spec](../pr-review-agent/pr-review-agent.md) · [Engine implementation](../../scripts/engine.sh) · [CI standards](https://github.com/petry-projects/.github/blob/main/standards/ci-standards.md)_
