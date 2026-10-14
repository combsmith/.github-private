# Scenarios: content-twin-audit

## Overview

The `content-twin-audit` workflow runs daily and monitors the health of the
ContentTwin content pipeline. It opens a GitHub issue if content is stale,
the queue is empty, or publishing errors are detected in recent workflow runs.

**Trigger:** `schedule` (daily at 07:00 UTC)
**Repo scope:** `combsmith/ContentTwin` only
**Outputs:** GitHub issue in `combsmith/ContentTwin` when problems are detected

---

## Scenario 1: Stale content detected

**Given** the ContentTwin repo has content files with no commits in the past 7 days
**When** the daily schedule fires
**Then**
- the workflow identifies stale content items
- Claude produces an audit report with staleness details
- a GitHub issue is opened titled `ContentTwin Audit — stale content YYYY-MM-DD`
- the issue lists stale file paths and days-since-last-update

**Assertions:**
- `HAS_CONTENT_ISSUES=true` is set in `GITHUB_ENV`
- A GitHub issue is created in the `ContentTwin` repo
- The issue is labelled `content-audit` and `automated-report`

---

## Scenario 2: Publishing workflow failures detected

**Given** recent runs of the ContentTwin publishing workflow have `conclusion=failure`
**When** the daily schedule fires
**Then**
- the workflow fetches recent workflow run history from the ContentTwin repo
- failed runs are included in the audit report
- the issue flags publishing errors with links to the failed runs

**Assertions:**
- Issue body contains links to failed workflow runs
- Error reason is extracted and summarised (not just run URL)

---

## Scenario 3: Content queue is empty

**Given** the ContentTwin content queue directory or feed contains no pending items
**When** the daily schedule fires
**Then**
- the workflow detects the empty queue condition
- the audit report flags "empty queue" as a potential issue
- an issue is opened if this state persists for more than 1 day

**Assertions:**
- Issue mentions the queue-empty condition
- The empty-queue check does not fire if queue was recently emptied intentionally

---

## Scenario 4: All healthy

**Given** ContentTwin has recent commits, no publishing failures, and a non-empty queue
**When** the daily schedule fires
**Then**
- no issue is opened
- the workflow annotates a clean-run notice

**Assertions:**
- `HAS_CONTENT_ISSUES` is absent or `false`
- No GitHub issue is created
- Workflow conclusion is `success`

---

## Scenario 5: ContentTwin repo inaccessible

**Given** the `GH_TOKEN` does not have access to the ContentTwin repo
**When** the daily schedule fires
**Then**
- the workflow emits a `::error::` annotation
- the workflow fails so on-call is alerted

**Assertions:**
- Workflow conclusion is `failure`
- The error message mentions "cannot access ContentTwin repo" or similar

---

## Scenario 6: Duplicate issue suppression

**Given** an open content-audit issue already exists in the ContentTwin repo
**When** the daily schedule fires and finds the same problems
**Then**
- no duplicate issue is opened
- the workflow updates the existing issue with a new timestamp comment, or skips

**Assertions:**
- The count of open `content-audit` issues does not increase on repeat runs with the same findings
