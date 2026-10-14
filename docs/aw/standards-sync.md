# Standards Sync

**Workflow:** `standards-sync.yml`
**Priority:** P3
**Trigger:** `schedule` — monthly, first Monday at 09:11 UTC
**Scenario spec:** [`tests/aw/standards-sync/scenarios.md`](../../tests/aw/standards-sync/scenarios.md)

---

## Purpose

Check all repos in the `petry-projects` org against the org standards defined in
`AGENTS.md` and `CODEOWNERS`. For any repo that is out of sync, open a PR with the
required additions. Produce a monthly compliance summary issue in `.github-private`.

---

## Trigger

```yaml
on:
  schedule:
    # Every Monday at 09:11 UTC; the guard step below enforces first-Monday-only
    - cron: '11 9 * * 1'
  workflow_dispatch: {}
```

---

## Required files (per repo)

| File | Description |
|------|-------------|
| `AGENTS.md` | Org-standard agent configuration (references `.github/AGENTS.md`) |
| `.github/CODEOWNERS` | Code ownership definitions |

---

## Architecture

```
schedule (first Monday)
  └── sync job
        ├── enumerate all non-archived org repos via gh api
        ├── for each repo:
        │     ├── check presence of required files via gh api contents
        │     ├── if missing files: build patch (org-standard template content)
        │     ├── check for existing open standards-sync PR (idempotency)
        │     └── if no open PR: open PR with missing files
        ├── collect compliance results
        └── open summary issue in .github-private
```

---

## Configuration

| Variable | Source | Default | Description |
|----------|--------|---------|-------------|
| `ORG` | `vars.ORG` | `petry-projects` | GitHub org to scan |
| `GH_TOKEN` | `secrets.DON_PETRY_BOT_GH_PAT` | — | PAT with `repo` and `workflow` scopes |
| `STANDARDS_REPO` | `vars.STANDARDS_REPO` | `petry-projects/.github` | Repo containing org standards templates |
| `SYNC_LABEL` | `vars.STANDARDS_SYNC_LABEL` | `standards-sync` | Label applied to opened PRs and issues |
| `SKIP_REPOS` | `vars.STANDARDS_SYNC_SKIP_REPOS` | `` | Comma-separated list of repos to skip |

---

## Outputs

### PRs (per non-compliant repo)

- **Title:** `chore: add AGENTS.md (standards-sync)` / `chore: add CODEOWNERS (standards-sync)`
- **Branch:** `standards-sync/YYYY-MM-DD`
- **Labels:** `standards-sync`
- **Body:** explains which file is missing and why it is required

### Summary issue (in `.github-private`)

- **Title:** `Standards Sync — YYYY-MM-DD`
- **Labels:** `standards-sync`, `automated-report`
- **Body:**

```markdown
## Compliance Summary — YYYY-MM-DD

| Repo | AGENTS.md | CODEOWNERS | Action |
|------|-----------|------------|--------|
| foo/bar | ✅ | ❌ | PR #42 opened |
| foo/baz | ✅ | ✅ | Compliant |

**Total:** 12 repos scanned · 10 compliant · 2 PRs opened
```

---

## Script

See [`scripts/aw-standards-sync.sh`](../../scripts/aw-standards-sync.sh).

---

## Permissions

```yaml
permissions:
  contents: read
  issues: write
```

The `GH_TOKEN` PAT additionally requires `repo` scope to create branches and PRs on
other org repos.

---

## Idempotency

Before opening a PR on a repo, the script calls:
```bash
gh pr list --repo "${target_repo}" --label standards-sync --state open
```
If any open PR exists with the `standards-sync` label, no new PR is created.

---

## Runbook

**PR opened but repo intentionally deviates from org standard:**
Close the PR and add the repo to `STANDARDS_SYNC_SKIP_REPOS`. Document the exception
in the repo's own `AGENTS.md`.

**Workflow fails with 403 on a repo:**
The PAT may lack `repo` scope on a private repo. Check the PAT scopes or add the repo
to `SKIP_REPOS`.

**Summary issue not created:**
Ensure the workflow has `issues: write` permission on `.github-private` and that the
`GH_TOKEN` PAT has access to that repo.
