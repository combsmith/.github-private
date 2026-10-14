# CI Failure Analyst — Scenario Spec

Scenario spec for the `ci-failure-analyst` agentic workflow.
Written before the workflow per the TDD cycle in issue #233.

## Scenario 1: Test check fails on a PR

**Input event:**

```json
{
  "action": "completed",
  "check_run": {
    "id": 12345,
    "name": "test",
    "conclusion": "failure",
    "head_sha": "abc123def456",
    "details_url": "https://github.com/petry-projects/example/actions/runs/999",
    "pull_requests": [{ "number": 42 }]
  }
}
```

**Expected output:**

- A comment is posted to PR #42.
- Comment begins with `<!-- ci-analyst sha=abc123def456 -->`.
- Comment includes the failed step name extracted from logs.
- Comment includes a root cause category (one of: Test failure, Env issue, Flaky test, Config error, Lint/style, Build error).
- Comment includes one concrete suggested fix.
- Comment includes a link to `https://github.com/petry-projects/example/actions/runs/999`.

---

## Scenario 2: Lint check fails on a PR

**Input event:**

```json
{
  "action": "completed",
  "check_run": {
    "id": 67890,
    "name": "lint",
    "conclusion": "failure",
    "head_sha": "def789ghi012",
    "details_url": "https://github.com/petry-projects/example/actions/runs/1000",
    "pull_requests": [{ "number": 17 }]
  }
}
```

**Expected output:**

- A comment is posted to PR #17.
- Comment begins with `<!-- ci-analyst sha=def789ghi012 -->`.
- Root cause category is **Lint/style** (not Test failure) — the comment must note
  this is a lint failure, not a test failure.
- Comment includes the specific lint error extracted from logs.
- Comment includes one concrete suggested fix (e.g., run the linter locally or fix the style rule).
- Comment includes a link to the run logs.

---

## Edge case: Duplicate comment for the same SHA

**Setup:** PR #42 already has a comment beginning with `<!-- ci-analyst sha=abc123def456 -->`.

**Input event:** Same `check_run` event as Scenario 1 (same SHA, same PR).

**Expected output:**

- The workflow is a **no-op** — the existing comment is left as-is.
- No new comment is created and the existing comment is not modified.
- PR comment count does not increase.

> **Note:** The analyst intentionally skips (rather than updates) when a comment for
> the same SHA already exists. This keeps the first diagnostic intact and avoids
> overwriting it when multiple check runs fail for the same SHA. If a Lint failure
> is followed by a Test failure on the same SHA, only the first failure processed
> will produce a diagnostic comment.

---

## Edge case: check_run conclusion is not `failure`

**Input events (any of the following):**

```json
{ "check_run": { "conclusion": "cancelled", "pull_requests": [{ "number": 5 }] } }
{ "check_run": { "conclusion": "skipped",   "pull_requests": [{ "number": 5 }] } }
{ "check_run": { "conclusion": "success",   "pull_requests": [{ "number": 5 }] } }
```

**Expected output:**

- Workflow is a **no-op** — no comment is posted, no comment is updated.

---

## Edge case: check_run not associated with any PR

**Input event:**

```json
{
  "action": "completed",
  "check_run": {
    "id": 55555,
    "name": "test",
    "conclusion": "failure",
    "head_sha": "zzz000",
    "details_url": "https://github.com/petry-projects/example/actions/runs/2000",
    "pull_requests": []
  }
}
```

**Expected output:**

- Workflow is a **no-op** — no comment is posted anywhere.
- The analyst must not comment on issues or any other thread.
