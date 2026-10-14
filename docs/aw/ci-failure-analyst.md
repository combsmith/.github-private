# CI Failure Analyst

Agentic workflow that diagnoses CI failures and posts a root-cause comment on the associated pull request within 2 minutes.

## What it does

When a check run completes with `conclusion: failure` on a non-fork PR, the workflow:

1. Resolves the PR number from the check run payload (with a commits-to-pulls API fallback)
2. Checks idempotency — skips if a `<!-- ci-analyst sha=<HEAD_SHA> -->` comment already exists for this SHA
3. Fetches the failed run logs from the GitHub Actions API
4. Identifies the specific step that failed and its error message
5. Classifies the root cause into one of six categories
6. Posts a structured diagnostic comment on the PR

If the check run is not associated with a non-fork PR, or if a comment for this SHA already exists, the workflow is a no-op.

## Architecture

The workflow uses the **reusable workflow** (`workflow_call`) pattern — the same approach as `dev-lead-reusable.yml`.

```
repo-x (check_run: failure)
  └─ .github/workflows/ci-failure-analyst.yml   ← ~20-line stub (no logic)
      └─ uses: petry-projects/.github-private/.github/workflows/ci-failure-analyst-reusable.yml@ci-failure-analyst/v1-stable
          ├─ resolves PR (non-fork only)
          ├─ idempotency check (<!-- ci-analyst sha=... -->)
          ├─ installs Claude Code
          └─ runs analysis → posts comment
```

**Why reusable workflow (not dispatch)?** CI Failure Analyst is read-only — it only posts a comment using the caller's own `GITHUB_TOKEN`. No `GH_PAT_WORKFLOWS` is needed. The reusable pattern is simpler: one file, `secrets: inherit`, and GitHub automatically scopes the token to the caller's repo.

### Interaction contract

CI Failure Analyst is a **Class 1 event-driven role** (a single reaction to
`check_run:[completed]`, no schedule) under the
[agentic interaction model](../agentic-interaction-model.md) (the normative standard). It has
no persona manifest — its trigger lives entirely in the byte-frozen thin caller
`.github/workflows/ci-failure-analyst.lock.yml` — so its pattern is declared in one
machine-readable, CI-verified contract:

- **Runtime lens** — [`interaction-contracts/ci-failure-analyst.yml`](../../interaction-contracts/ci-failure-analyst.yml)
  (the `check_run` trigger, the `<!-- ci-analyst sha=... -->` emit, the per-SHA idempotency key
  and concurrency lane, and why it is not bound by `pr-automation-budget`).

It structurally cannot loop — one comment per failing head SHA, deduped by the `ci-analyst`
marker and serialized by the per-head-SHA concurrency lane — so it carries no `stop_markers` and
`budget: none`. When the caller stub's `on:` block changes, update that contract and the
standard's §4 classification table in the same change.

### Files

| File | Role |
|---|---|
| `.github/workflows/ci-failure-analyst-reusable.yml` | Single source of truth — all logic |
| `.github/workflows/ci-failure-analyst.lock.yml` | Thin stub for this repo (`.github-private`) |
| `templates/ci-failure-analyst.yml` | Copy-paste stub for any other org repo |

## Deploying to a new repo

1. Copy `templates/ci-failure-analyst.yml` to `.github/workflows/ci-failure-analyst.yml` in the target repo.
2. Commit and push — no other changes needed.

`CLAUDE_CODE_OAUTH_TOKEN` is already an org secret available to all repos. No PAT or additional secrets required.

## Requirements

| Requirement | Details |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Org secret — must be granted to target repo in Settings → Secrets → Actions |

No `GH_PAT_WORKFLOWS` or `ANTHROPIC_API_KEY` needed.

## Trigger

```yaml
on:
  check_run:
    types: [completed]
```

The caller stub guards on `conclusion == 'failure'` and includes an anti-loop guard so the analyst does not re-trigger itself:

```yaml
if: >-
  github.event.check_run.conclusion == 'failure' &&
  !startsWith(github.event.check_run.name, 'CI Failure Analyst')
```

## Root cause categories

| Category | Indicators |
|---|---|
| **Test failure** | Assertion failed, `FAIL`, `AssertionError`, `Expected ... got ...` |
| **Env issue** | Missing secret/env var, `command not found`, `permission denied`, auth error |
| **Flaky test** | Timeout, `ECONNREFUSED`, connection reset, intermittent HTTP error |
| **Config error** | Malformed YAML, missing required field, wrong runner, `invalid syntax` |
| **Lint/style** | `eslint`, `shellcheck`, `markdownlint`, `yamllint`, `ruff`, `golangci-lint` errors |
| **Build error** | Compilation error, `npm ERR!`, `cargo build failed`, dependency resolution failure |

## Comment format

```markdown
<!-- ci-analyst sha=<HEAD_SHA> -->
## CI Failure: <check name>

**Step:** <failing step name>
**Root cause:** <category>

<2–3 sentence explanation>

**Suggested fix:** <one concrete action>

[View run logs](<details_url>)
```

The `<!-- ci-analyst sha=... -->` marker enables idempotency: if the workflow triggers again for the same SHA, it detects the existing comment and skips.

## Permissions

The caller stub declares these permissions (inherited by the reusable):

| Permission | Reason |
|---|---|
| `pull-requests: write` | Read PR metadata |
| `issues: write` | Post and read PR comments (GitHub uses the Issues comments API for PR comments) |
| `actions: read` | Fetch workflow run logs |
| `checks: read` | Read check run details |
| `contents: read` | Checkout access required by the reusable runner environment |

The reusable workflow uses `github.token` (the caller's `GITHUB_TOKEN`) for all GitHub API calls. No additional tokens are needed.

## Relationship to dev-lead

Both workflows can run in the same repo without conflict:

| Workflow | Timing | Writes | Idempotency marker |
|---|---|---|---|
| **CI Failure Analyst** | < 2 min | Comment only | `<!-- ci-analyst sha=... -->` |
| **dev-lead fix-ci** | 5–10 min | Comment + fix commit | `<!-- dev-lead sha=... -->` |

Having both gives developers a fast diagnosis while the automated fix is being prepared.

## Verifying deployment

After deploying the stub to a target repo:

1. Trigger a deliberate CI failure on a PR branch.
2. Within 2 minutes, a `<!-- ci-analyst sha=... -->` comment should appear on the PR.
3. Confirm no duplicate comments appear if the same check re-runs for the same SHA.
4. Confirm the analyst does not trigger itself (anti-loop guard).
