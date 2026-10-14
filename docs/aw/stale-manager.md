# Stale Manager

A scheduled GitHub Action that automatically manages stale issues and PRs
across the `petry-projects` org. Runs every Monday at 09:00 UTC.

Part of the [GitHub Agentic Workflows rollout](https://github.com/petry-projects/.github-private/discussions/228).

## How it works

1. **Cron** — `.github/workflows/stale-manager.yml` runs every Monday at 09:00 UTC
   (and on `workflow_dispatch`).
2. **Scan** — `scripts/stale-manager.sh` lists all non-archived repos in `TARGET_ORG`
   and fetches their open issues and PRs.
3. **Evaluate** — for each item, the script checks:
   - Exempt labels (`pinned`, `no-stale`) → skip
   - Has `stale` label but was recently updated → remove `stale`
   - Past staleness threshold, no `stale` label → warn (add label + comment)
   - Has `stale` label, grace period elapsed → close
4. **Comment** — Claude (the `sonnet` model family, resolved to the current id at run time) generates a contextual warning or
   closing comment based on the item's title and body.
5. **Act** — in live mode, labels are applied, comments are posted, and eligible
   items are closed via the GitHub API.

## Thresholds

| Item type | Staleness threshold | Grace period before close |
|---|---|---|
| Issue | 60 days without activity | 7 days after `stale` label |
| PR | 30 days without activity | 7 days after `stale` label |

## Exempt labels

Items with either of these labels are never touched by the stale manager:

- `pinned` — permanently active item
- `no-stale` — opted out of automatic stale management

## Idempotency

Before posting a warning comment, the script checks for an existing
`<!-- stale-manager: warned -->` marker in the item's comments. If found, no
second comment is posted. This means re-running the workflow (or running it
twice in the same week) is safe.

## Setup

### Required secrets

| Secret | Purpose |
|---|---|
| `DON_PETRY_BOT_GH_PAT` | Classic PAT with `repo` + `read:org` scope for org-wide scanning |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code OAuth token for comment generation |

### Configuration variables

| Variable | Default | Description |
|---|---|---|
| `TARGET_ORG` | `petry-projects` | GitHub org to scan |
| `STALE_DAYS_ISSUE` | `60` | Days before issue is stale |
| `STALE_DAYS_PR` | `30` | Days before PR is stale |
| `GRACE_DAYS` | `7` | Days with `stale` label before closure |
| `LIVE_MODE` | `false` | Set to `true` to enable writes |
| `REVIEW_ENGINE` | `claude` | LLM engine for comment generation |

## Staged → live

The workflow is deployed in **staged (dry-run) mode** by default. In this mode,
it evaluates all items and writes a detailed step summary of intended actions,
but makes no GitHub API write calls.

To go live:

1. Review staged step summaries across several Monday runs.
2. Set `LIVE_MODE=true` as a repo variable in `.github-private`.
3. Update `.github/workflows/stale-manager.yml` permissions:
   ```yaml
   permissions:
     issues: write
     pull-requests: write
   ```
4. Trigger a manual `workflow_dispatch` with `dry_run=false` to validate the
   first live run before the next scheduled Monday.

## Files

| File | Purpose |
|---|---|
| `.github/workflows/stale-manager.yml` | Workflow definition |
| `.github/workflows/stale-manager.md` | Design spec |
| `scripts/stale-manager.sh` | Main script |
| `prompts/aw/stale-manager.md` | Claude prompt template for comments |
| `tests/aw/stale-manager/scenarios.md` | Test scenario specs |
