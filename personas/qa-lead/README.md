# QA Lead — Master Test Architect & Quality Advisor

Worked example for the [Agentic Persona Standard](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md).
`qa-lead` is the reference for the **wrap-a-vendored-framework-agent,
advisory-everywhere** path.

## What qa-lead is

`qa-lead` wraps the vendored [BMAD Test Architecture](../../frameworks/bmad-test-architecture/VENDOR.md)
agent (`bmad-tea`, pinned `v1.19.0`), consumed **by path** as plain markdown.
It advises on risk-based test strategy, fixture architecture, ATDD, API/UI
automation, CI/CD quality gates, and test review. It is **advisory on every
surface and writes nowhere** — the safe default for a new persona.

It is already consulted during planning by the Scrum Master overlay (see
[`prompts/bmad/scrum-master.md`](../../prompts/bmad/scrum-master.md), Step 4).
This manifest makes it a first-class, addressable persona.

## Why `qa-lead` and not the upstream agent's name

The vendored agent has a person-name upstream. We do not use it. A persona is
named for its **role** ([§1.6](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md)):
`@petry-projects/qa-lead` tells a reader in a PR comment who is being addressed
and why; the upstream cast list does not. It also means swapping the agent
underneath — or replacing it with a first-party layer — never changes how this
persona is addressed. Upstream is referenced only by its technical skill id
(`framework.skill: bmad-tea`).

## How it is addressed

```text
@petry-projects/qa-lead please assess test risk on this PR
```

The handle is the org **team** `petry-projects/qa-lead`, not a user account —
`@qa-lead` is a real GitHub account owned by an unrelated person, so a bare
role mention would notify a stranger on every use. The team is `privacy: closed`
with `notification_setting: notifications_disabled`: it exists to route a
webhook, not to page anyone. See
[§4.1](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md).

## Served surface: pull_request advisory (event-driven)

As of #1646 ([qa-lead S3]), qa-lead is served **without being summoned** on the
PR surface. [`qa-lead-pr-advisory.yml`](../../.github/workflows/qa-lead-pr-advisory.yml)
is a Class 1 (event-driven) caller that fires on
`pull_request: [opened, ready_for_review]` — `synchronize` is deliberately not
wired, so a PR gets one advisory as it enters review, not one per push.

That local workflow is self-contained (it `source`s a repo-local gate script and
calls the local persona runtime), **not** a fleet-deployable thin caller stub,
so it cannot ship to another repo by the standards sweep. [ADR-0009](../../docs/architecture/adr/0009-qa-lead-pull-request-surface-routes-through-the-shared-router.md)
records the decision (#1869) to route the `pull_request` event through the
shared `persona-mention` router instead of publishing a second runtime, so the
surface reaches beyond this repo. That router path is live on the
`persona-mention/v1-next` channel, and this repo's
[`persona-mention.yml`](../../.github/workflows/persona-mention.yml) stub
subscribes `pull_request` (#2187).

So the `pull_request` surface is currently served by **both** paths: the local
`qa-lead-pr-advisory.yml` and the router. Both call the shared runtime with
`surface: pull_request`, so they share **one** per-(persona, repo, PR)
concurrency group and the same already-advised marker check. A PR gets one
advisory, not two. The local workflow is retired in a separate issue, only
**after** the router path is verified on real PRs, including the #1745
stop-marker semantics on a `pull_request`-sourced dispatch.

The local workflow reuses the **one** persona runtime
([`persona-runner-reusable.yml`](../../.github/workflows/persona-runner-reusable.yml)) —
there is no qa-lead-specific runner. Before invoking it, a pure gate
([`scripts/qa-lead-advisory-gate.sh`](../../scripts/qa-lead-advisory-gate.sh),
unit-tested by `tests/test_qa_lead_advisory_gate.bats` +
`tests/test_qa_lead_test_surface.bats`) decides whether qa-lead has anything to
say. It stays silent unless the PR carries **real test surface** and no
suppressor applies:

- **Test surface** (`scripts/lib/qa-lead-test-surface.sh`): a PR that touches
  tests, or changes source with no accompanying test, fires; a docs-only or a
  verbatim stub-sync (workflow/config yaml) PR does not.
- **Opt-out**: the `qa-lead:hands-off` label suppresses the advisory.
- **One per PR**: the gate scans for an existing `<!-- persona:qa-lead -->`
  marker and the caller concurrency lane serializes `opened` + `ready_for_review`
  so the two events never stack a second comment.
- **Human / budget gates**: `needs-human-review` (the canonical
  `pr_has_escalation_label` check), `dev-lead:needs-human`, or an exhausted
  per-PR automation budget (#926) all suppress it.

### Soak window & noise metrics

This surface is on a **two-week soak** from first deploy. It is advisory-only and
detect-shaped — the recursion guard is the workflow's read/write split, not the
prompt (the #860 lesson). Watch for and report:

- **advisories posted vs. PRs seen** (the fire rate),
- **skip-reason histogram** — the gate logs `skip:<reason>`
  (`no-test-surface` / `opt-out` / `human-gated` / `budget-exhausted` /
  `already-advised`),
- **duplicate or self-triggered comments** — expected to be **0**; any non-zero
  is a soak failure.

## How a mention becomes an advisory

Nothing about serving `qa-lead` is persona-specific — it rides the **one shared
router → one shared runner** path §4.1 mandates, and its only persona-owned
runtime surface is a prompt:

1. A human `@petry-projects/qa-lead …` comment is parsed by the **one shared
   mention router** — `persona-mention-reusable.yml` in `petry-projects/.github`,
   pinned here through the thin caller stub
   [`.github/workflows/persona-mention.yml`](../../.github/workflows/persona-mention.yml).
   There is deliberately **no qa-lead workflow**: one stub per persona is the
   drift the manifest exists to prevent (§4.1).
2. The router fires a `repository_dispatch: persona-mention` at this repo,
   carrying `{persona, source_repo, item_number, comment_url, requested_by}`.
3. The **one shared runner** —
   [`.github/workflows/persona-runner-reusable.yml`](../../.github/workflows/persona-runner-reusable.yml),
   received via the [`.github/workflows/persona-runner.yml`](../../.github/workflows/persona-runner.yml) caller — resolves the addressed
   persona's advisory prompt **by convention** and runs it.
4. For `qa-lead` that prompt is
   [`prompts/qa-lead/advisory.md`](../../prompts/qa-lead/advisory.md) — the
   actual behaviour surface, where the test-risk advisory is defined. The
   manifest only points the router at it.

What is *actually wired* today (a subset of the surfaces the manifest declares)
is recorded in [`interaction.yml`](./interaction.yml); the full declared surface
set lives in [`persona.yml`](./persona.yml). This README does not restate either
— per §4.1 the manifest is the index of record and the docs restate none of it.

## Read/write split — the security property the framework rests on

The whole framework is safe because **the agent cannot post**:

- The **agent** runs with `github.token`. On the router-served path that token
  reads **public** source repos and this repo only (it is scoped to *this* repo).
  For other private source repos it has no read access, so the pull_request
  pre-gate fails closed (`skip:signal-unavailable`, which the runner reports as a
  retryable workflow failure). **Private source repositories other than
  `.github-private`** are out of scope for the router-served pull_request surface
  today. The agent only *prints* its advisory between sentinels; it never posts.
- The **workflow** is the only writer. It extracts the advisory, mechanically
  guarantees the `<!-- persona:qa-lead -->` recursion marker, and posts with the
  persona's PAT (declared as `runtime.identity` in the manifest).

So an agent that forgets the marker cannot post an unmarked comment — because it
cannot post at all. This split is the fix for
[#860](../../docs/postmortems/2026-06-pr-860-runaway.md): **prompt-only** marker
enforcement is exactly what failed there, when a self-mention ack looped to
**1,481 identical comments in ~4.5h**. Marker enforcement now lives in the
workflow, not in the prompt.

## Status: pre-release (served on the `next` ring)

The runtime **shipped** (#1293) and the mention → dispatch → runner chain has
fired in production (soak on #1300, 2026-07-18; again on #1402, 2026-08-02).
`qa-lead` is not `draft` in the "nothing runs yet" sense — it is addressable and
answering today. What is still `draft` is the **release**: it has not been cut as
a versioned reusable rollout.

Genuinely still outstanding before it can be cut as a release:

- **Not in the canary rings.** There is no `agents.qa-lead` entry in the central
  `canary-rings.json`, so there is nothing to roll ring-to-ring yet.
- **`next`-ring only.** This repo pins the router at the `persona-mention/v1-next`
  channel — the smallest-blast-radius soak. The `persona-mention/v1-ring0`,
  `v1-ring1`, and `v1-stable` channels do not exist yet.

The eval set is now **scorable**: #1645 added the llm-judge scorer
([`evals/qa-lead/scorer.json`](../../evals/qa-lead/scorer.json)) over the held-out cases
([`evals/qa-lead/holdout/cases.jsonl`](../../evals/qa-lead/holdout/cases.jsonl)),
so the `required_before: stable` gate the manifest declares can actually run.

To promote `qa-lead` toward `stable`:

1. **Do not add a workflow.** A new persona ships a **manifest** ([`persona.yml`](./persona.yml))
   and an **advisory prompt** (`prompts/<id>/advisory.md`); the shared router and
   runner already serve it by convention. Adding a per-persona caller stub is the
   drift §4.1 exists to prevent, and it is not what shipped.
2. Grow the held-out eval set with real (de-identified) cases and keep it above
   the judge gate.
3. Register the `agents.qa-lead` entry in `canary-rings.json` and cut
   `qa-lead/v0.1.0`.
4. Soak `next → ring0 → ring1 → stable`, eval gate green before `stable`.

The full gate is the Definition of Done in `persona-standards.md` §7.

## Contributing upstream

This persona's behavior lives upstream in
`bmad-code-org/bmad-method-test-architecture-enterprise`. Do not hand-edit
`frameworks/`. Org-specific behavior is layered via
`definition.layers[].local_overrides`; anything general enough to help other
BMAD users should be raised upstream (`upstream_candidate: true`) rather than
kept as private drift.
