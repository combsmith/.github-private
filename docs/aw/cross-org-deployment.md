# GitHub Agentic Workflows — Cross-Org Deployment

**Issue:** [#235](https://github.com/petry-projects/.github-private/issues/235)
**Phase:** 4 — Cross-org deployment of gh-aw workflows

---

## Decision Gate Evaluation

The issue requires evaluating Phase 1–3 stability before choosing a deployment path:

> **If all three workflows have been live for 5+ days with no incidents** → use `gh aw package` (shared workflow path).
> **If any workflow is still being iterated** → extend the existing org dispatch pattern.

**Decision: Org dispatch path.**

Rationale:
- Phase 3 (#234 — Stale Manager + Release Notes) is a declared dependency that must be stable before this phase. At the time of this implementation those workflows are still being iterated.
- The `gh aw package` command is not yet available as a stable CLI artifact in this org's toolchain.
- The org dispatch pattern already exists and is proven (pr-review mention trigger). Extending it reuses the same trust-gate + PAT architecture with no new secrets required.

---

## Architecture Overview

Cross-org deployment uses a **two-tier dispatch pattern**, identical in structure to the existing `pr-review-mention` flow:

```
Org repo (e.g. ContentTwin)
  ├── .github/workflows/gh-aw-listener.yml   ← thin caller stub (template-deployed)
  │     • Listens for: issues[labeled], check_run[completed/failure]
  │     • Trust gate: org-member check for issue events
  │     • Dispatches: repository_dispatch → .github-private
  │
  └── gh api POST /repos/petry-projects/.github-private/dispatches
        event_type: gh-aw-issue-triage | gh-aw-ci-failure
        client_payload: { source_repo, issue_number | pr_number + head_sha + checks }

petry-projects/.github-private
  └── .github/workflows/gh-aw-cross-org.yml  ← dispatcher (lives here)
        • Listens for: repository_dispatch[gh-aw-issue-triage, gh-aw-ci-failure]
        • Validates source_repo is within petry-projects org
        • Checks out .github-private (scripts + prompts) at dotgithub-private/
        • Checks out target repo at target-repo/
        • Runs dev-lead-fix-issue.sh or dev-lead-fix-ci.sh
          with working-directory: target-repo
          and PROMPTS_DIR pointing into dotgithub-private/
```

### Why this works

- **Logic stays in `.github-private`** — org repos carry only a thin YAML stub. All handler scripts, prompts, and engine invocations live here and iterate independently.
- **No new secrets required** — `GH_PAT_WORKFLOWS` (already an org secret) handles both the cross-repo dispatch and the checkout/push of branches in target repos.
- **Anti-loop** — the listener excludes check runs whose name starts with `gh-aw /` to prevent self-triggering.
- **Security** — the dispatcher validates that `source_repo` is within `petry-projects/` before any checkout or engine invocation.

---

## Gh-aw Workflow Capabilities

The following capabilities are available cross-org via this pattern:

| Capability | Trigger | Handler script |
|---|---|---|
| **Issue Triage** | `issues[labeled]` (org-member labeler) | `dev-lead-fix-issue.sh` |
| **CI Failure Analyst** | `check_run[completed, conclusion=failure]` | `dev-lead-fix-ci.sh` |

---

## Dispatch Payload Schemas

### `gh-aw-issue-triage`

```json
{
  "event_type": "gh-aw-issue-triage",
  "client_payload": {
    "source_repo": "petry-projects/ContentTwin",
    "issue_number": 42,
    "label": "bug"
  }
}
```

### `gh-aw-ci-failure`

```json
{
  "event_type": "gh-aw-ci-failure",
  "client_payload": {
    "source_repo": "petry-projects/ContentTwin",
    "pr_number": 7,
    "head_sha": "abc123def456",
    "checks": [
      {
        "id": 12345678,
        "name": "test / unit",
        "conclusion": "failure",
        "details_url": "https://github.com/petry-projects/ContentTwin/actions/runs/12345",
        "app_slug": "github-actions"
      }
    ]
  }
}
```

---

## Deploying to a New Org Repo

1. Copy `templates/gh-aw-org-listener.yml` to the target repo as `.github/workflows/gh-aw-listener.yml`.
2. Ensure the repo has access to the `GH_PAT_WORKFLOWS` org secret (it is org-level, but repos must be explicitly granted access in org secret settings — it is not automatic for all repos).
3. Open a PR in the target repo with the new workflow file. Merge it.
4. Verify:
   - Label an issue in the target repo with any label as an org member. The `gh-aw-listener.yml` workflow should run and a `gh-aw-cross-org` run should appear in `.github-private`.
   - Trigger a CI failure on a PR in the target repo. The listener should dispatch and a fix attempt should appear in `.github-private`.

---

## Concurrency Strategy

| Event | Concurrency group |
|---|---|
| `gh-aw-issue-triage` | `gh-aw-issue-{source_repo}-{issue_number}` |
| `gh-aw-ci-failure` | `gh-aw-ci-{source_repo}-{pr_number}` |

Both groups use `cancel-in-progress: false` to queue rather than cancel, matching the behavior of `dev-lead.yml`.

---

## Verified Repos

| Repo | Issue Triage | CI Failure Analyst | Notes |
|---|---|---|---|
| `petry-projects/ContentTwin` | deployment target | deployment target | Primary test repo per issue #235 |

Deploy `gh-aw-listener.yml` to each repo listed above using the template.

---

## Future: Shared Workflow Path

Once all three gh-aw workflows (Issue Triage, CI Failure Analyst, Stale Manager, Release Notes) have been live for 5+ days with no incidents, revisit the `gh aw package` / shared workflow approach. This would replace the per-repo listener stubs with a single reusable workflow reference from `petry-projects/.github`, eliminating the per-repo deployment step entirely.
