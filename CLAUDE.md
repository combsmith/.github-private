# CLAUDE.md — .github-private

This file provides project-specific instructions for Claude Code when working in this repository.

## Development Standards

Read [AGENTS.md](./AGENTS.md) before making any changes. It defines the org-wide standards for CI,
workflows, agent configuration, and more.

## Repository Purpose

This is the **private org-level `.github-private` repository** for `petry-projects`. It contains:

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
