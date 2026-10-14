# How to add an agentic role

**Status:** runbook (repo-local) · **Scope:** `combsmith/.github-private`
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
list will fail CI) is planned for Story 4 / `validate-interaction-model` (#1406) and is not
yet enforced; keep the table in sync by convention until that check lands. If the role is CI
infrastructure or a thin caller stub rather than an agentic role, add it to the §4
**exclusion list** instead, with a one-line reason.

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

## Enforcement

The per-role contracts are **CI-validated today** by `validate-interaction-contracts` (the
`Lint` workflow). It checks: schema compliance, workflow file existence, timer structure
(`role`, `justification`, `stop_condition`, `event_fast_path`), unguarded self-trigger violations
([§7](./agentic-interaction-model.md#7-the-860-normative-rules)), and
budget/stop-marker consistency ([§9](./agentic-interaction-model.md#9-the-cost--run-count-bound)).
A contract that fails these checks blocks the PR.

The **full cross-check** — verifying that a workflow's `on:` block, its §4 classification
row, and its contract all agree — is **planned** for Story 4 /
[#1406](https://github.com/combsmith/.github-private/issues/1406)
([`validate-interaction-model`](./agentic-interaction-model.md#10-how-this-document-is-enforced)).
Until that check lands, keep the three artefacts in sync by convention; a mismatch will not
block merge today but will fail CI once Story 4 ships.
