# Copilot Instructions — .github-private

> **Note:** This file applies to the `petry-projects/.github-private` repository only. Org-wide rules are in [`petry-projects/.github/copilot-instructions.md`](https://github.com/petry-projects/.github/blob/main/.github/copilot-instructions.md). This file covers only what is specific to .github-private.

## About

.github-private is the org's private CI infrastructure repository — it hosts Copilot custom agent profiles (org-wide), sophisticated agentic GitHub Actions workflows (PR review, standards-sync, CI failure analysis, stale management, etc.), and agentic framework subtrees (bmad-method, spec-kit, gsd).

## Tech Stack

- **Runtime:** Bash (scripts) · GitHub-hosted runners (Actions)
- **Framework:** GitHub Actions (YAML) · BMad Method (via `frameworks/` git subtrees)
- **Testing:** ShellCheck (scripts) · `gh aw compile` (agentic workflow YAML linting — CI-gated in `lint.yml`)
- **Linting:** ShellCheck (zero warnings) · markdownlint (agent profiles + docs) · `gh aw compile` (`.github/workflows/*.md` / `*.lock.yml`)
- **Key tools:** `gh` CLI · `gh aw` (agentic workflow compiler)

## Project Structure

```text
agents/                 # Copilot custom agent profiles (org-wide effect)
  agentic-workflows.md
  compliance-auditor.md
  feature-ideator.md
  pr-reviewer.md
.github/
  workflows/
    dev-lead.yml            # Primary AI automation for this repo (inline steps)
    dev-lead-reusable.yml   # Cross-org reusable workflow (edit to affect all repos)
    pr-review.yml           # Automated PR review
    lint.yml                # ShellCheck + markdownlint + gh-aw-compile (repo-specific gate)
    standards-sync.yml      # Standards propagation across org repos
    ci-failure-analyst.*    # CI failure triage automation
    stale-manager.*         # Stale PR/issue management
    ...
  aw/                   # Compiler metadata only (actions-lock.json); workflow sources are in workflows/*.md
  rulesets/             # Branch protection ruleset JSON
scripts/                # Shell orchestration for GitHub Actions
docs/                   # Workflow documentation
prompts/                # Agent prompt library
```

## Local Dev Commands

- Lint scripts:         `find scripts -name "*.sh" -exec shellcheck --severity=warning -x {} +`
- Lint agentic flows:   `gh aw compile --no-emit`
- Run tests:            `bats tests/fleet_report.bats`

## Required Environment Variables

- `GH_TOKEN`: Secret used varies by workflow — `pr-review.yml`, `release-notes.yml`, and `stale-manager.yml` use `DON_PETRY_BOT_GH_PAT` (no fallback); orchestration workflows (`dev-lead-reusable.yml`, `actions-fleet-monitor.yml`) use `GH_PAT_WORKFLOWS`; CI jobs use `GITHUB_TOKEN`
- `GH_PAT`: Used as `COPILOT_GITHUB_TOKEN` in Copilot-invoking workflows (`dev-lead.yml`, `dev-lead-reusable.yml`, `pr-review.yml`, `gh-aw-cross-org.yml`) — no fallback; required for `gh copilot` commands
- `CLAUDE_CODE_OAUTH_TOKEN`: Used by dev-lead and pr-review workflows (stored as Actions secret)

## Testing Framework

- Runner: `gh aw compile` (agentic workflow YAML compilation — required CI gate in `lint.yml`)
- Shell: ShellCheck (required CI gate)
- Coverage: N/A
- Mutation testing: N/A

## Repo-Specific Overrides

**`agent-shield.yml` must not be modified** — this workflow is protected per `AGENTS.md` and is exempt from agent modification. If a policy change is needed, raise it with a human maintainer.

**`dev-lead.yml` vs `dev-lead-reusable.yml`:** To change AI automation behavior for this repo only, edit `dev-lead.yml`. To change behavior across all org repos, edit `dev-lead-reusable.yml` (the cross-org reusable).

**`lint.yml` `gh-aw-compile` job** is a documented repo-specific addition — do not remove it when syncing org CI templates; if the org template gains an equivalent, remove this note and defer to the template.

**Agent profiles** in `agents/*.md` must have YAML frontmatter with `name`, `description`, and `tools`. Agent names must be kebab-case matching the filename. Changes are org-wide.

## Org Standards

See [petry-projects/.github — AGENTS.md](https://github.com/petry-projects/.github/blob/main/AGENTS.md) for org-wide development standards.

**Language-specific instructions** (applied automatically by Copilot when you open matching file types):

- [Shell](.github/instructions/shell.instructions.md) — safety flags, ShellCheck, quoting, error handling, Makefile standards
