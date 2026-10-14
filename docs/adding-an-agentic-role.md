# How to add an agentic role

**Status:** runbook (repo-local) · **Scope:** `petry-projects/.github-private`
· **Companion to:** [`docs/agentic-interaction-model.md`](./agentic-interaction-model.md) (the normative standard)

This is the step-by-step for introducing a new agentic role — a workflow that reacts to
events or runs on a cadence and takes automated action. The [interaction-model
standard](./agentic-interaction-model.md) says *what* a conforming role looks like; this
runbook says *how* to declare one so it passes CI on the first try. Every step cites the
standard section that governs it — read that section for the rules, and follow this page
for the sequence.

Do not treat any step as optional: the contract is CI-validated today (schema, timers,
self-trigger violations), and the full `on:`-block / §4-row / contract cross-check will be
enforced once Story 4 / #1406 lands (see [Enforcement](#enforcement) below).

---

## Step 1 — Classify the role: pick the trigger class

Decide, from the **origin of the work**, which of the three trigger classes the role is
(standard [§2](./agentic-interaction-model.md#2-the-three-trigger-classes),
[§3](./agentic-interaction-model.md#3-class-discriminator-the-parse-contract)):

- **Class 1 — event-driven reaction.** A GitHub webhook already represents the work (a PR
  opens, a review is submitted, a check run completes). Subscribe to the narrowest event(s)
  that carry the signal. **No `schedule`** — the event-first principle
  ([§1](./agentic-interaction-model.md#1-the-event-first-principle)) means a cron here is
  either a disguised Class 2 or a leak.
- **Class 2 — backstop / reconciliation timer.** The work is fundamentally event-driven,
  but the event path can *miss* (dropped webhook, race, a state that became actionable
  without a fresh event). Pair the event fast-path with a **low-frequency reconciliation
  timer** that declares a `timer_role`.
- **Class 3 — scheduled-origin work.** The cadence itself *is* the requirement (a weekly
  report, a daily health scan, a periodic canary). There is no upstream webhook that
  represents "produce this week's report."

If you are reaching for a `schedule` on Class 1 work, stop: prefer the event
([§1](./agentic-interaction-model.md#1-the-event-first-principle)). A timer is legitimate
only as a Class 2 backstop under an event path, or as a Class 3 scheduled origin.

**Then add a classification row.** Add exactly one row for the new workflow to the §4 table
in the standard
([Classification of current agentic workflows](./agentic-interaction-model.md#4-classification-of-current-agentic-workflows)),
in the fixed column order `Workflow (path) | Class | timer_role | Justification`. The
bidirectional completeness check (a workflow absent from both this table and the exclusion
list will fail CI) is **enforced** by Story 4 / `validate-interaction-model` (#1406): keep the
table in sync or CI fails. If the role is CI infrastructure or a thin caller stub rather than
an agentic role, add it to the §4 **exclusion list** instead, with a one-line reason.

## Step 2 — Author the interaction contract (the Story-1 shape)

Declare the role's interaction pattern as a **machine-readable contract** in the shape fixed
by standard [§8.1](./agentic-interaction-model.md#81-fields) — do not restate the pattern in
prose scattered across workflow comments. Create the file(s) for the lens(es) your role
requires (the [§8.2](./agentic-interaction-model.md#82-file-location---decision-standalone-repo-local-contract-not-personayml-yet)
decision — option (b), so there is **no** cross-repo `persona.schema.json` dependency).
These are independent requirements, not alternatives — a role that qualifies for both
needs both:

- **Role lens** → `personas/<id>/interaction.yml` — required when the role is backed by a
  persona manifest. Copy the shape from
  [`personas/dev-lead/interaction.yml`](../personas/dev-lead/interaction.yml).
- **Runtime lens** → `interaction-contracts/<name>.yml` — required for any deployed runtime
  (a role whose triggers live in a workflow file), whether or not a persona manifest also
  exists (e.g. `pr-review`, `ci-failure-analyst`). Copy the shape from
  [`interaction-contracts/dev-lead.yml`](../interaction-contracts/dev-lead.yml).

For example, `dev-lead` has both a persona manifest and a deployed workflow, so it carries
both `personas/dev-lead/interaction.yml` (role lens) and
`interaction-contracts/dev-lead.yml` (runtime lens). Fill in every required field in
whichever file(s) you create:

- `interaction.triggers.events` — mirror the workflow's `on:` webhook subscriptions verbatim.
- `interaction.triggers.timers` — empty for a pure Class 1 role; one entry per `schedule.cron`
  otherwise (see Step 4).
- `emits` — the events / markers this role produces. An emit that names an event class the
  role also subscribes to is allowed **only** when accompanied by a matching
  `self_trigger_guards` entry — without it, the validator rejects the contract (#860 rule 1,
  [§7](./agentic-interaction-model.md#7-the-860-normative-rules)). Each `self_trigger_guards`
  entry carries three required fields:
  - `emit` — the colliding event name.
  - `guard` — one sentence describing the in-code stop-condition-gated mechanism that
    prevents the loop.
  - `location` — the file (and optional line range) where the guard lives.

  `interaction-contracts/dev-lead.yml` provides four worked examples: three
  `dispatch:dev-lead-*-retry` guards (the retry timer fires only when its stop-condition
  holds — PR still rate-limited and limit now cleared) and a `commit` guard (the intent
  script drops `pull_request:synchronize` events from the bot's own commits).
- `idempotency_key`, `concurrency_lane`, `stop_markers`, and `budget` — the role obeys the
  existing `pr-automation-budget` ceiling ([§9](./agentic-interaction-model.md#9-the-cost--run-count-bound));
  do **not** invent a new numeric cap.

## Step 3 — Choose the event path vs. a sanctioned bridge

A workflow step running as the default `GITHUB_TOKEN` **cannot emit most webhooks that
trigger other workflows** — GitHub suppresses recursive triggering for push, label, comment,
and similar events, so an event a Class 1 role is waiting for will silently never arrive if
its upstream producer runs as `GITHUB_TOKEN`
(standard [§5](./agentic-interaction-model.md#5-the-github_token-event-boundary-rule-and-sanctioned-bridges)).
`repository_dispatch` and `workflow_dispatch` are permitted exceptions — GitHub allows
`GITHUB_TOKEN` to fire these as explicit, intentional dispatch calls.

- **Prefer the direct event.** If the work is represented by a real webhook that a real
  actor produces, subscribe to it directly — no bridge needed.
- If you must wake a downstream role, cross the boundary via one of the two sanctioned bridges:
  - **Bridge A — `repository_dispatch` with the role's declared credential** (event-preserving).
    Fire the dispatch (or apply the triggering label) with the role's declared
    `runtime.identity.credential` PAT — never a shared token. This repo's identity policy
    (AGENTS.md "Agent identity & credential secrets") requires using the named credential even
    though `GITHUB_TOKEN` is technically permitted to fire `repository_dispatch`. The downstream
    Class 1 role wakes on its normal event path, scoped to the payload.
  - **Bridge B — a stop-condition-gated backstop timer.** Where a dispatch bridge is not
    warranted, a Class 2 backstop timer may reconcile the missed event on a cadence — but
    it must satisfy the full timer contract in Step 4.

Never try to produce a suppressed event (push, label, comment) as `GITHUB_TOKEN` and expect
it to trigger a downstream workflow — the failure is silent.

## Step 4 — Declare the timer contract (only if the role uses a timer)

Skip this step for a pure Class 1 role. If the role has any `schedule.cron` (Class 2 or
Class 3), each timer is bound by the timer contract
([§6](./agentic-interaction-model.md#6-the-timer-contract)) and must be declared in the
contract's `interaction.triggers.timers`:

- **`role`** — one of `backstop`, `safety-net`, `self-heal`
  ([§6.1](./agentic-interaction-model.md#61-the-timer_role-taxonomy)). A **Class 3**
  report/canary carries **no** `timer_role` (its cadence is the origin); a **Class 2** timer
  **must** declare one.
- **`justification`** — why this is a timer and not an event.
- **`stop_condition`** — the timer checks it *before* acting and re-dispatches only work that
  is still open and not human-gated
  ([§6.2](./agentic-interaction-model.md#62-requirements-every-timer-must-meet)).
- **`event_fast_path`** — **Class 2 only:** the Class 1 event this timer backstops; `null`
  marks the [§6.3](./agentic-interaction-model.md#63-the-correct-example-vs-the-leak) leak
  (a schedule as the *only* path to fundamentally event-driven work). For **Class 3**, omit
  or set `null` — no fast path exists and that is not a leak.
- The timer must be **idempotent** (extra ticks harmless, missed ticks self-heal), must
  **skip human-gate markers** (`needs-human-review`, `dev-lead:needs-human`, …), and must
  **never re-arm a runaway** — its reset path is human-gated. Also obey the off-peak
  scheduling standard (non-zero, staggered minute; AGENTS.md "Scheduled workflows").

## Step 5 — Wire the role's ingress (Class 1: the shared `agent-ingress.yml`)

Once the role is classified and its contract is authored, decide **how the role is woken in a
consumer repo**. Under [ADR-0007](./architecture/adr/0007-one-agent-ingress-stub-per-repo.md)
a repo's per-role Class 1 caller stubs **collapse into a single
`.github/workflows/agent-ingress.yml`** instead of one stub per role. The canonical shape is
authored as a non-executing reference at
[`docs/architecture/reference/agent-ingress.yml`](./architecture/reference/agent-ingress.yml)
and is emittable as a machine artifact:

```
bash scripts/seed-repo-template.sh --emit-workflow agent-ingress.yml
```

### The ingress shape

- **One ingress per repo.** `on:` is the **union** of the collapsed roles' triggers. The file
  declares **exactly one job per role**, and each **job key carries the role token** so runs
  stay attributable by role (run attribution coarsens to job level under ADR-0007 — a monitor
  that keyed on workflow name must be retargeted to job name in the same change).
- **Per-job everything.** Each job keeps **its own `permissions:` block**, **its own pinned
  first-party channel `uses:` ref**, its **matching `agent_ref`** (where the reusable declares
  one), and **its own `secrets:`**. Top-level `permissions:` is `{}`. A single dispatching job
  is **forbidden** — it would have to be granted the union of every role's permissions.
- **Still a thin caller.** No `steps:`, no `run:`, no logic outside the `if:` guard (ADR-0001,
  unchanged). Each `with:` forwards only inputs the pinned channel's `workflow_call.inputs`
  declares.

### The `if:`-as-event-filter boundary

A job-level `if:` **may act as an event filter, and only as an event filter** — this is the one
place ADR-0007 loosens ADR-0001. It may reference **only** `github.event_name`,
`github.event.action`, and event-payload fields read as a **pure predicate**. It must **never
reach repo state**: the frozen ALLOW/FORBID rulings for every contested construct live as
machine-readable fixtures at
[`tests/fixtures/agent-ingress/if-filter-rulings.tsv`](../tests/fixtures/agent-ingress/if-filter-rulings.tsv)
(the frozen source of truth, exercised by the `tests/agent_ingress_if_filter.bats`
suite, not restated in prose). In summary:

- **ALLOWED** (the delivered event): `github.event_name`, `github.event.action`, a payload
  predicate such as `github.event.pull_request.base.ref` (the branch the event is about), and
  `github.event.label.name` (the single label whose change triggered the event).
- **FORBIDDEN** (repo state, belongs in the reusable as a permissioned step): org/repo
  configuration variables, secrets, another job's computed outputs, a repo-tree hash, repo
  identity, the payload's standing default-branch field, and a scan of the standing labels
  array. An `if:` that reaches for any of these — or any expression that is a script in
  disguise — is logic, not a filter.

A role's on-level `branches:`/`paths:` filter is **per-file** and cannot be expressed per-job at
the `on:` level. Move a branch filter into the job's `if:` as a payload predicate (e.g.
`github.event.pull_request.base.ref == 'main'`); move a `paths:` filter **into the reusable** as
an explicit diff step (it cannot live in the `if:`, which the Actions service evaluates before a
runner exists).

### The pin migration: per-file channel tag → per-job pin

The ADR-0002 ring pin **moves one tier down, it does not disappear**. Where each per-role stub
formerly carried the channel tag on its own file (`dev-lead.yml` pinned `@dev-lead/v139-stable`),
the ingress carries that **same** tag as a **per-job pin** on each job's `uses:` (and matching
`agent_ref`). **No new tag namespace is introduced** — the existing per-role channel tags are
reused verbatim; only their location moves from a per-file pin to a per-job pin. Promotion stays
a central tag move, never a per-repo caller edit.

### Carve-outs — roles that keep their own per-role stub

Not every role folds into the ingress. Keep a **separate per-role stub** for:

- **`pull_request_target` roles** — mixing a privileged-context trigger into the shared ingress
  would make the whole file's privileged surface the union of every role in it. Non-negotiable.
- **Class 2 backstop timers and Class 3 scheduled roles** — a clock has no webhook; §5 Bridge B
  backstops remain required regardless.
- **Documented repo-local trigger stubs** — a repo needing genuinely repo-local trigger
  behavior keeps its stub on the same documented-exception terms ADR-0001 already allows.

**Non-agentic CI and gate workflows** (`ci.yml`, `lint.yml`, `holdout-guard.yml`, …) are **out
of scope** — they are required checks, not agentic roles, and never belong in the ingress.

## Enforcement

The per-role contracts are **CI-validated today** by `validate-interaction-contracts` (the
`Lint` workflow). It checks: schema compliance, workflow file existence, timer structure
(`role`, `justification`, `stop_condition`, `event_fast_path`), unguarded self-trigger violations
([§7](./agentic-interaction-model.md#7-the-860-normative-rules)), and
budget/stop-marker consistency ([§9](./agentic-interaction-model.md#9-the-cost--run-count-bound)).
A contract that fails these checks blocks the PR.

The **full cross-check** — verifying that a workflow's `on:` block, its §4 classification
row, and its contract all agree — is **enforced** by Story 4 /
[#1406](https://github.com/petry-projects/.github-private/issues/1406)
([`validate-interaction-model`](./agentic-interaction-model.md#10-how-this-document-is-enforced)).
Keep the three artefacts in sync; a mismatch fails CI and blocks merge.
