# Issue Triage — Agentic Workflow

Part of the GitHub Agentic Workflows rollout (internal discussion: [petry-projects/.github-private#228](https://github.com/petry-projects/.github-private/discussions/228) — requires repo access).

## What it does

When a new issue is opened or reopened, this workflow:

1. Checks the existing label count. If the issue already has **2 or more labels** it exits silently (no-op).
2. Calls Claude with the issue title and body to classify the issue. The spec names the `sonnet` model family (`models:`), which `aw.sh` resolves to the current Sonnet id at run time via `ai_model_for_family`.
3. Selects up to 3 labels from the allowed set and writes a single welcoming comment that asks the most relevant clarifying question.

All of this happens within 60 seconds of the issue being opened.

## Allowed labels

`bug`, `enhancement`, `documentation`, `question`, `good-first-issue`, `security`

## Files

| File | Purpose |
|------|---------|
| `.github/workflows/issue-triage.md` | Workflow definition (frontmatter + Claude prompt template) |
| `.github/workflows/issue-triage-runner.yml` | GitHub Actions runner (two-job: triage → apply) |
| `scripts/aw.sh` | `gh aw` CLI — compile, run, safe-output |
| `tests/aw/issue-triage/scenarios.md` | Scenario spec used to validate behaviour |

## Architecture

```
issues: opened/reopened
        │
        ▼
   triage job  (permissions: issues: read)
        │  bash scripts/aw.sh run issue-triage --staged
        │  → Claude classifies, returns JSON
        ▼
   apply job   (permissions: issues: write)
        │  bash scripts/aw.sh safe-output apply issue-triage result.json
        │  → validates labels, posts comment, adds labels
        ▼
   issue updated
```

The two-job split is deliberate: Claude runs with the minimum permission it
needs (read), and writes are applied by a separate job after the output has
been validated by `safe-output`.

## Validation

`gh aw compile` validates every `.md` workflow definition file. It checks:

- Required frontmatter fields: `name`, `trigger`, `engine`, `permissions`
- Engine is a model family (`opus`, `sonnet`, `haiku`) or a Claude runner/model id
- `output` is `staged` or `live` (if present)
- Trigger is a non-empty event mapping
- Workflow body (instructions) is not empty

Run locally:

```bash
bash scripts/aw.sh compile .github/workflows/issue-triage.md
```

## Staged vs live mode

The `output` frontmatter field controls how results are applied:

| Value | Behaviour |
|-------|-----------|
| `staged` | `aw run` emits JSON to stdout; a separate `safe-output apply` step writes to GitHub |
| `live` (default when omitted) | `aw run` applies labels and posts the comment inline |

The runner workflow always uses the two-job pattern regardless of this setting,
so `safe-output` always validates before writing.

## Skip condition

If the issue already has **2 or more labels** when the workflow fires, `aw run`
returns `{"skip": true}` immediately and the apply job is skipped. No API
writes occur.

## Smoke-test procedure

To validate against the scenario spec before going live:

```bash
# Create a test issue in a non-critical repo and capture the number
ISSUE_NUMBER=<n> \
ISSUE_TITLE="Login button is broken" \
ISSUE_BODY="When I click nothing happens." \
ISSUE_LABELS="" \
ISSUE_URL="https://github.com/petry-projects/.github-private/issues/<n>" \
GITHUB_REPOSITORY="petry-projects/.github-private" \
bash scripts/aw.sh run issue-triage --staged
```

Compare the JSON output against the expected labels and comment style in
`tests/aw/issue-triage/scenarios.md`.
