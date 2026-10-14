# ContentTwin Content Audit

**Workflow:** `content-twin-audit.yml`
**Priority:** P3
**Trigger:** `schedule` — daily at 07:00 UTC
**Repo scope:** `combsmith/ContentTwin` only
**Scenario spec:** [`tests/aw/content-twin-audit/scenarios.md`](../../tests/aw/content-twin-audit/scenarios.md)

---

## Purpose

Review the ContentTwin content pipeline health daily. Open a GitHub issue in the
`ContentTwin` repo if:

- content files are stale (no commits in the past 7 days)
- the content queue is empty
- publishing workflow runs have failed recently

---

## Trigger

```yaml
on:
  schedule:
    - cron: '0 7 * * *'   # daily at 07:00 UTC
  workflow_dispatch:
    inputs:
      stale_days:
        description: "Days without a content commit before flagging as stale"
        required: false
        default: "7"
```

---

## Architecture

```
schedule (daily)
  └── audit job
        ├── check content directory for last-commit dates
        ├── check content queue size (files in queue/ or equivalent)
        ├── fetch recent publishing workflow run history
        ├── claude --print: analyse all signals, produce audit report
        └── if issues detected:
              ├── check for existing open content-audit issue (dedup)
              └── open (or update) issue in ContentTwin repo
```

---

## Configuration

| Variable | Source | Default | Description |
|----------|--------|---------|-------------|
| `CONTENT_TWIN_REPO` | `vars.CONTENT_TWIN_REPO` | `combsmith/ContentTwin` | Target repo |
| `STALE_DAYS` | `vars.CONTENT_STALE_DAYS` or `inputs.stale_days` | `7` | Days without commit threshold |
| `PUBLISH_WORKFLOW` | `vars.CONTENT_TWIN_PUBLISH_WORKFLOW` | `publish.yml` | Workflow file to check for failures |
| `GH_TOKEN` | `secrets.DON_PETRY_BOT_GH_PAT` | — | PAT with `repo` and `actions:read` scopes |
| `CLAUDE_CODE_OAUTH_TOKEN` | `secrets.CLAUDE_CODE_OAUTH_TOKEN` | — | Claude auth token |

---

## Health signals

| Signal | Healthy | Unhealthy |
|--------|---------|-----------|
| Content freshness | Commits in last `STALE_DAYS` days | No commits in `STALE_DAYS`+ days |
| Queue state | At least 1 pending item | Queue directory empty |
| Publishing runs | All recent runs succeeded | Any failure in the last 7 days |

---

## Outputs

### When issues are detected

A GitHub issue is opened in `combsmith/ContentTwin`:

- **Title:** `ContentTwin Audit — content pipeline issues YYYY-MM-DD`
- **Labels:** `content-audit`, `automated-report`
- **Body:** Claude-generated report covering:
  - Which health signals are failing
  - Stale file paths (if any)
  - Links to failed publish runs (if any)
  - Recommended actions

### Deduplication

Before opening a new issue, the script checks for existing open issues with the
`content-audit` label. If one exists, a comment is added instead of opening a duplicate.

### When all signals are healthy

- No issue is opened
- Annotation: `::notice::ContentTwin audit passed — all signals healthy`

---

## Script

See [`scripts/aw-content-twin-audit.sh`](../../scripts/aw-content-twin-audit.sh).

---

## Permissions

```yaml
permissions:
  contents: read
  issues: write
```

The `GH_TOKEN` PAT additionally requires `repo` and `actions:read` scopes on the
`ContentTwin` repo to read workflow run history and content file metadata.

---

## Runbook

**False-positive stale alert over a holiday/break:**
Close the issue and set `CONTENT_STALE_DAYS` to a higher value temporarily, or add
the content directory to `CONTENT_STALENESS_IGNORE`.

**Workflow fails with 404 on ContentTwin:**
Verify the repo name is correct in `CONTENT_TWIN_REPO` and that the PAT has access.

**Issue created but queue is intentionally empty (no pending content):**
This is expected operational state — close the issue and note this in the repo README
so future audits can be contextualised.
