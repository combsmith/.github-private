# CLAUDE.md — .github-private

This file provides project-specific instructions for Claude Code when working in this repository.

## Development Standards

Read [AGENTS.md](./AGENTS.md) before making any changes. It defines the org-wide standards for CI,
workflows, agent configuration, and more.

## Repository Purpose

This is the **org-level `.github-private` repository** for `petry-projects`. Despite the name, the
repository is **public**, on purpose: an organization on the free plan only gets rulesets and the merge
queue on public repositories. Everything committed here, and every issue, pull request and comment, is
world-readable. Do not write credentials, key values, customer data or internal-only detail here. Secrets
belong in Actions secrets and are referred to by name only.

It contains:

- **`agents/`** — Copilot custom agent profiles (org-wide, invocable from GitHub.com, VS Code, JetBrains)
- **`prompts/`** — Prompt libraries used by workflows
- **`scripts/`** — Shell orchestration for GitHub Actions (PR review, health checks)
- **`frameworks/`** — Installed agentic frameworks (git subtree)
- **`.github/workflows/`** — Scheduled automation (PR review, health checks, dependency audit)

## Key Guidelines

- This repo contains shell scripts executed by GitHub Actions — test changes locally with `shellcheck`
- Some workflows are thin caller stubs (e.g., `claude.yml`, `agent-shield.yml`, `auto-rebase.yml`, `dependabot-automerge.yml`) — do not modify these beyond the allowed inputs noted in their headers and AGENTS.md; others contain org-private automation logic and are not thin callers
- SHAs for action pinning must be looked up via the GitHub API — never guessed

## Commands

- Lint shell scripts: `shellcheck scripts/*.sh`
