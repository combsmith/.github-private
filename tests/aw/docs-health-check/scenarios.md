# Scenarios: docs-health-check

## Overview

The `docs-health-check` workflow runs on a weekly schedule and audits documentation
freshness across all org repos. It opens a GitHub issue listing any documentation
files that have not been updated in 90 or more days.

**Trigger:** `schedule` (weekly, Sunday 00:00 UTC)
**Outputs:** GitHub issue in `.github-private` when stale docs are found

---

## Scenario 1: Stale docs found

**Given** one or more org repos contain doc files last committed more than 90 days ago
**When** the weekly schedule fires
**Then**
- the script identifies all stale doc files with their last-commit dates
- Claude produces a prioritized markdown report
- a GitHub issue is opened titled `Docs Health Check — stale files detected YYYY-MM-DD`
- the issue body lists each stale file as `repo/path` with the last-updated date
- the issue is labelled `health-check` and `automated-report`

**Assertions:**
- `HAS_STALE_DOCS=true` is set in `GITHUB_ENV`
- The issue is created (workflow step `create-issue` exits 0)
- The report file (`docs_health_report.md`) is non-empty

---

## Scenario 2: No stale docs

**Given** all org repos have doc files committed within the last 90 days
**When** the weekly schedule fires
**Then**
- the script finds zero stale files
- no GitHub issue is opened
- the workflow annotates a clean-run notice

**Assertions:**
- `HAS_STALE_DOCS` is absent or `false`
- the `create-issue` step is skipped
- workflow concludes `success`

---

## Scenario 3: Repo with no docs/ directory

**Given** an org repo has no `docs/` directory
**When** the weekly schedule fires
**Then**
- the script skips that repo without error
- the repo does not appear in the stale-docs list

**Assertions:**
- Script exits 0 even when `gh api repos/{repo}/contents/docs` returns 404

---

## Scenario 4: GitHub API rate limit

**Given** the GitHub API returns a rate-limit error during repo enumeration
**When** the weekly schedule fires
**Then**
- the script emits a `::warning::` annotation
- the workflow exits non-zero so the run is marked as failed (alerting on-call)

**Assertions:**
- Workflow conclusion is `failure`
- A `::warning::` or `::error::` annotation is visible in the run log

---

## Scenario 5: Stale docs in this repo (`.github-private`)

**Given** `.github-private/docs/` contains files not updated in 90+ days
**When** the weekly schedule fires
**Then**
- the issue references the stale file path relative to the repo root
- the issue is opened on the `.github-private` repo itself

**Assertions:**
- At least one entry in the report matches the pattern `petry-projects/.github-private/docs/*`
