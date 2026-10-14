# Docs Health Check

**Workflow:** `docs-health-check.yml`
**Priority:** P2
**Trigger:** `schedule` — weekly, Sunday 00:21 UTC
**Scenario spec:** [`tests/aw/docs-health-check/scenarios.md`](../../tests/aw/docs-health-check/scenarios.md)

---

## Purpose

Audit documentation freshness across all repos in the `petry-projects` org. Open a
GitHub issue on `.github-private` listing every documentation file that has not been
updated in 90 or more days, so that doc owners can review and refresh stale content.

---

## Trigger

```yaml
on:
  schedule:
    - cron: '21 0 * * 0'   # weekly, Sunday at 00:21 UTC
  workflow_dispatch:
    inputs:
      stale_days:
        description: "Days without an update before a doc is considered stale"
        required: false
        default: "90"
```

---

## Architecture

```
schedule (weekly)
  └── health-check job
        ├── enumerate org repos via gh api
        ├── for each repo: list docs/ contents
        ├── for each doc file: fetch last commit date
        ├── filter: last_commit_date < (today - STALE_DAYS)
        ├── claude --print: analyse stale list, produce prioritised report
        └── if stale docs found:
              └── create GitHub issue in .github-private
```

---

## Configuration

| Variable | Source | Default | Description |
|----------|--------|---------|-------------|
| `STALE_DAYS` | `vars.DOCS_STALE_DAYS` or `inputs.stale_days` | `90` | Days without update threshold |
| `ORG` | `vars.ORG` | `petry-projects` | GitHub org to scan |
| `GH_TOKEN` | `secrets.DON_PETRY_BOT_GH_PAT` | — | PAT with `repo` scope |
| `CLAUDE_CODE_OAUTH_TOKEN` | `secrets.CLAUDE_CODE_OAUTH_TOKEN` | — | Claude auth token |

---

## Outputs

### When stale docs are found

A GitHub issue is opened in `petry-projects/.github-private`:

- **Title:** `Docs Health Check — stale files detected YYYY-MM-DD`
- **Labels:** `health-check`, `automated-report`
- **Body:** Claude-generated markdown report with:
  - Executive summary (how many files, across how many repos)
  - Prioritised list of stale files (oldest first)
  - Per-file: path, last-updated date, days stale, suggested action

### When no stale docs are found

- No issue is opened
- Workflow annotates: `::notice::Docs health check passed — no stale files found`

---

## Script

See [`scripts/aw-docs-health-check.sh`](../../scripts/aw-docs-health-check.sh).

---

## Permissions

```yaml
permissions:
  contents: read
  issues: write
```

The `GH_TOKEN` PAT (used via `gh` CLI) additionally requires `repo` scope to enumerate
repos and read file metadata in other org repos.

---

## Runbook

**Issue opened but files are intentionally stale:**
Close the issue and add the file path to the `DOCS_STALENESS_IGNORE` repo variable
(comma-separated list). The script skips paths that match any entry in this list.

**Workflow fails with API rate-limit error:**
The `GH_TOKEN` PAT is rate-limited. Run manually during off-peak hours or request a
higher rate limit via GitHub Support.

**Claude invocation fails:**
Check `CLAUDE_CODE_OAUTH_TOKEN` is valid. Re-run the workflow after rotating the token.
