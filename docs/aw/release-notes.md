# Release Notes Generator

A GitHub Action that auto-generates CHANGELOG entries on every push to `main`.
Finds merged PRs labeled `feat` or `fix`, uses Claude to write structured
Keep-a-Changelog entries, and opens a PR updating `CHANGELOG.md`.

Part of the [GitHub Agentic Workflows rollout](https://github.com/petry-projects/.github-private/discussions/228).

## How it works

1. **Trigger** — `.github/workflows/release-notes.yml` runs on every push to `main`.
2. **Dedup** — checks for an existing open PR with `<!-- release-notes: sha=<HEAD_SHA> -->`
   in its body. If found, the run is a no-op.
3. **Find PRs** — `scripts/release-notes.sh` resolves the push range (`before..HEAD`)
   and lists merged PRs associated with those commits via the GitHub API.
4. **Filter** — keeps only PRs labeled `feat` or `fix` (configurable via `CHANGELOG_LABELS`).
   If none remain, the workflow exits without opening a PR.
5. **Generate** — Claude (the `sonnet` model family, resolved to the current id at run time) produces Keep-a-Changelog entries
   grouped by `### Added` / `### Fixed` / `### Changed`.
6. **Apply** — if `CHANGELOG.md` does not exist, it is created with the standard header.
   The new entries are prepended under `## [Unreleased]`.
7. **PR** — a branch `chore/changelog-<short-sha>` is created and a PR is opened
   against `main` for review before merge.

## CHANGELOG format

The generator follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/):

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased] — YYYY-MM-DD

### Added
- Description of new feature (#42)

### Fixed
- Description of bug fix (#43)
```

## Label mapping

| PR label | CHANGELOG section |
|---|---|
| `feat` | `### Added` |
| `fix` | `### Fixed` |
| Other user-facing labels | `### Changed` |
| `chore`, `ci`, `docs`, `test` | Excluded |

## Idempotency

The workflow embeds `<!-- release-notes: sha=<HEAD_SHA> -->` in every CHANGELOG PR body.
On re-run (e.g., workflow retry), the script searches for open PRs containing this marker
and exits without creating a duplicate if one is found.

## Setup

### Required secrets

| Secret | Purpose |
|---|---|
| `DON_PETRY_BOT_GH_PAT` | Classic PAT with `repo` scope to create branches and PRs |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code OAuth token for changelog generation |

### Configuration variables

| Variable | Default | Description |
|---|---|---|
| `CHANGELOG_FILE` | `CHANGELOG.md` | Path to the changelog file |
| `CHANGELOG_LABELS` | `feat,fix` | Comma-separated labels that trigger a changelog entry |
| `LIVE_MODE` | `false` | Set to `true` to enable branch/PR creation |
| `REVIEW_ENGINE` | `claude` | LLM engine for content generation |

## Staged → live

The workflow is deployed in **staged (dry-run) mode** by default. In this mode,
it generates the CHANGELOG content and writes it to the step summary, but does not
create a branch or open a PR.

To go live:

1. Review staged step summaries across several pushes to validate output quality.
2. Set `LIVE_MODE=true` as a repo variable in `.github-private`.
3. Update `.github/workflows/release-notes.yml` permissions:
   ```yaml
   permissions:
     contents: write
     pull-requests: write
   ```
4. The next push to `main` will trigger a live run and open the first CHANGELOG PR.

## Files

| File | Purpose |
|---|---|
| `.github/workflows/release-notes.yml` | Workflow definition |
| `.github/workflows/release-notes.md` | Design spec |
| `scripts/release-notes.sh` | Main script |
| `prompts/aw/release-notes.md` | Claude prompt template for changelog generation |
| `tests/aw/release-notes/scenarios.md` | Test scenario specs |
