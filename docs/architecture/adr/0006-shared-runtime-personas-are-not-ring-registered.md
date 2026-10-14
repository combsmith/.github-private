# 0006. Shared-runtime personas are not individually ring-registered

## Status

accepted

## Context

ADR-0002 versions every first-party reusable with immutable `<name>/vX.Y.Z`
releases and moving `<name>/v<MAJOR>-<tier>` channel tags, because "callers pin
once and receive promotions automatically as the channel tag advances." ADR-0001
splits the fleet into two tiers and locates the leverage in the reusable: "one
edit to a reusable changes the whole fleet."

Advisory personas do not fit that model, and the mismatch was found only when
onboarding the ninth one.

A persona has **no dedicated reusable**. It rides the shared, convention-driven
persona runtime: the `persona-mention` router parses an `@petry-projects/<role>`
mention and bridges (`repository_dispatch`) to `persona-runner`, which executes
any persona supplying a manifest plus `prompts/<role>/advisory.md`. Adding a
persona is a data change, not a workflow change — which is precisely why the
third onboarding cost one commit.

Three facts, verified on `main` 2026-09-07, decide this:

1. `persona-runner.yml` consumes the runtime by **local relative path**
   (`uses: ./.github/workflows/persona-runner-reusable.yml`) and the reusable
   declares **no `agent_ref` input**. **No caller pins a persona channel tag**,
   so there is no tag for a ring promotion to advance.
2. `agent_ref_paths` defaults fleet-wide to `["scripts/", "prompts/",
   "personas/"]`, and autocut cuts when the reusable blob **or** any watched path
   changed (#1019). 44 of 61 commits to `main` in the preceding 30 days touched
   those paths; only 2 touched one specific persona's files. `dev-lead`, which
   has this exact shape, carries 162 version tags and sits at v139.8.0.
   Registering nine personas this way would cut roughly 396 releases a month —
   all of them unconsumed, per fact 1.
3. The gate samples runs by `run_workflow`. Every persona would register
   `"Persona Runtime"`, so all nine would sample an **identical** run set: a
   failure caused by any one persona counts against all nine, and no gate can
   attribute a regression to the persona that caused it.

The structural error underneath the churn: **a persona is a caller of the shared
runtime, not a reusable.** Versioning each caller inverts ADR-0001's boundary,
which puts the reusable — the thing consumers pin — as the unit of release.

## Decision

We will **not** register an individually-served persona in `canary-rings.json`.
A persona's rollout is the rollout of the runtime that serves it: the
`persona-mention` router's rings govern which repos can reach any persona, and
the runtime is the unit that carries a channel tag if one is ever wired.

The checkable boundaries:

- **A persona manifest MUST NOT require a `canary` entry.** `canary` becomes
  optional in `persona.schema.json`, and a persona whose `definition` is served
  wholly by the shared runtime MUST omit it rather than point at an entry that
  does not exist.
- **`agents.<persona-id>` MUST NOT appear in `canary-rings.json`** while that
  persona has no dedicated reusable. A registered persona ID is a defect, not a
  promotion — it produces unconsumed tags and an unattributable gate.
- **Promotion evidence is the reach check, not a ring label.** A persona's
  `status` may advance past `draft` with no registry entry; the previously
  dangerous "status past draft, unregistered" state is the **normal** state for
  a shared-runtime persona. `scripts/persona_reach_check.sh` must invert
  accordingly: once this decision lands it will fail on an unexpected
  registration or a trigger surface beyond the shared router's deployed events,
  and on a persona claiming promotion without the wiring that would make a
  mention resolve. (Today the guard still treats registration as the safe state
  and fails on the unregistered-past-draft skew; that inversion is the
  implementation work this ADR authorizes — see the Consequences below.)
- **This ADR governs shared-runtime personas only.** A persona that ever gains
  its own reusable — a dedicated advisory workflow with its own caller stub —
  returns to ADR-0002 in full and MUST be registered like any other agent.

## Consequences

- The ring apparatus stops manufacturing releases nobody consumes: ~396
  cut-and-move operations a month at nine personas drop to zero, and the
  registry stops carrying entries that describe nothing deployable.
- Onboarding a persona stays a data change. Had we registered per persona, each
  new one would have added a tag stream, a soak, and a gate that cannot isolate
  it — paid nine times.
- **The reach check becomes the sole automated promotion gate.** This is the
  real cost of this decision. Under a ring model the check was one control among
  several; here it stands alone, so a defect in it is a defect in the only thing
  standing between `status: draft` and `status: stable`. Reaching that state
  requires removing the other current control: `personas/validate-personas.py`
  today rejects any past-`draft` persona that lacks an `agents.<id>` registry
  entry, which directly contradicts the "MUST NOT be registered" boundary above,
  so that non-`draft`→registered requirement must be relaxed for shared-runtime
  personas as part of this decision. The reach check is pure-logic and
  bats-covered per ADR-0004, and that coverage is now load-bearing rather than
  merely good practice.
- **Blast radius is coarser.** Ring membership for personas is the router's, so
  a repo that adopts the `persona-mention` stub can reach *every* enabled
  persona — there is no per-persona staging. Narrowing a single persona's reach
  requires a mechanism this ADR does not provide (the per-item
  `<id>:hands-off` opt-out is the only lever today, and it is per-item, not
  per-repo).
- **No independent per-persona rollback.** Reverting one persona's prompt is an
  ordinary revert PR, not a tag move. This loses nothing real: a channel tag
  names a whole-repo commit, so per-persona tags never delivered isolated
  rollback either — they only appeared to.
- Two standards move with this: `persona-standards.md` §6 step 2 (registration
  is no longer unconditional) and §7's Definition of Done. Until those land, the
  standard and this ADR disagree, and the standard is the one that is wrong.

## References

- ADR-0001 (thin-caller / reusable two-tier) — the boundary this restores.
- ADR-0002 (channel-tag release and rings) — unchanged for reusables; this ADR
  records that personas are not in its scope.
- ADR-0004 (pure logic + bats) — why the reach check may carry this weight.
- ADR-0005 (advisory-by-default personas) — the persona pattern this serves.
- Decision thread: petry-projects/.github-private#1688, including the
  `solution-architect` advisory that identified the ADR-0001 boundary inversion.
- Superseded implementation: petry-projects/.github#1078 / #1079, closed
  unmerged; #1078's premise that autocut ignores prompt-only changes was false.
