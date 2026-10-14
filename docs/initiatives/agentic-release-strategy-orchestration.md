# Delivering the Release-Strategy initiative agentically

Companion to `agentic-release-strategy.md` (not yet published). This doc explains how the
10 child issues of epic #495 are delivered by the existing **per-item dev-lead agent** in dependency
order — without changing the agent itself.

## The problem this solves

Dev-lead is purely reactive and **per-item**: it works one issue only when the `dev-lead` label is
applied (`issues: [labeled]`), opens a PR that `Closes #N`, and drives that PR to merge. It has **no
ordering or dependency awareness** — labelling all 10 issues at once runs them in parallel and produces
PRs racing to merge with no regard for "#496 must land before #497".

**Reframe:** coordinating an initiative = deciding *when* the `dev-lead` label is applied to each
ready issue. That decision is what `scripts/initiative-driver.sh` + `.github/workflows/initiative-driver.yml`
automate.

## How the driver works

```
dev-lead merges a PR ──► "Closes #N" closes issue #N
        │
        ▼
initiative-driver  (on: issues:[closed] / issues:[labeled initiative:auto]
                       +  safety-net cron  +  workflow_dispatch)
        │   sweep: for each OPEN epic carrying `initiative:auto`
        │   (workflow_dispatch may target a single epic instead)
        │   gate: epic carries `initiative:auto`?  ── no ─► no-op (human-driven)
        │   for each OPEN sub-issue of the epic:
        │     • all `blocked_by` deps CLOSED?
        │     • not `dev-lead:hands-off` / `initiative:hold`?
        │     • in-flight < MAX_IN_FLIGHT?
        ▼
   apply `dev-lead` label ──► dev-lead picks up the next ready issue
```

- **Native dependencies.** Edges are GitHub "blocked by" relationships (set on #496–#506), visible in
  the issue UI and queried via `…/issues/{n}/dependencies/blocked_by`.
- **Event-driven, self-propelling.** A merge closes an issue, which fires the driver, which releases
  the now-unblocked successors. The cron (`23 */6 * * *`) is only a backstop for missed events.
- **Arming starts it.** Adding `initiative:auto` to an epic fires the driver via `issues:[labeled]`,
  so the first ready wave is released immediately — no waiting for the next cron tick.
- **Epic-agnostic.** The automatic triggers run in *sweep* mode: the driver discovers **every** open
  epic carrying `initiative:auto` and drives each, so it is not pinned to one hard-coded epic. A
  `workflow_dispatch` with an `epic` input targets a single epic (blank = sweep).
- **Bounded.** `MAX_IN_FLIGHT` (default 2) caps how many sub-issues run at once — controlling parallel
  token cost and blast radius. Per-issue concurrency lanes in dev-lead keep concurrent items isolated.
- **Repo-parameterized (`target_repo`).** The same driver sweeps + releases stories *for another repo*:
  `REPO` resolves to the `workflow_dispatch` `target_repo` input (empty ⇒ this repo, the dogfood/self
  path). The gate / `blocked_by` / cap logic above is identical regardless of which repo it targets —
  only the label-write destination changes. See **Fleet enablement** below.

### The PAT requirement (important)

A label applied with the default `GITHUB_TOKEN` does **not** start a new workflow run (GitHub
loop-prevention — the same mechanism behind pr-review #463). The driver therefore applies the
`dev-lead` label using **`GH_PAT_WORKFLOWS`**, so the resulting `issues:[labeled]` event actually
triggers dev-lead. The workflow fails fast if that PAT is absent.

### Safety gates

| Gate | Effect |
|---|---|
| `initiative:auto` on the **epic** | Master switch. Absent ⇒ driver no-ops. Phase 1 stays human-driven until you add it. |
| `dev-lead:hands-off` on an **issue** | Never released (needs a human — e.g. PRs that modify dev-lead/pr-review themselves). |
| `initiative:hold` on an **issue** | Never released (temporary human hold). |
| `MAX_IN_FLIGHT` | Upper bound on concurrently-released sub-issues. |

## The dependency DAG (epic #495)

```
#496 ──┬─► #497 ──┬─► #498
       │          ├─► #499 ──► #500 ──┐
       └─► #505   └─► #506 ──────────►#501 ──► #502 ──► #503
                        #505 ───────────┘
```

| Wave | Issues | Gated on |
|---|---|---|
| 1 | #496 cut `vX.Y.Z` + create `stable` | — |
| 2 | #497 pin callers · #505 tag protection | #496 |
| 3 | #498 runbook · #499 next/ring tags · #506 caller-ref integrity | #497 |
| 4 | #500 rings | #499 |
| 5 | #501 promotion workflow | #500, #505, #506 |
| 6 | #502 rollback + observability | #501 |
| 7 | #503 SC2 game-day | #502 |

## Bootstrap order: human-driven → agent-driven

This initiative modifies dev-lead/pr-review themselves, so the rollout order is also a **safety
bootstrap**, not just a technical dependency:

- **Phase 1 (#496, #497, #505, #498) — human-in-the-loop.** Until `@stable` exists and production duty
  is pinned to it (#497), there is no known-good fallback; letting the agent autonomously merge changes
  that could brick itself is exactly the failure mode we're removing. Leave `initiative:auto` **off**;
  apply the `dev-lead` label by hand, wave by wave (or merge by hand). Issues that edit
  `dev-lead.yml`/`pr-review.yml` carry `dev-lead:hands-off` and require human merge regardless.
- **Phase 2 (#499 onward) — agent-driven.** Once #497 lands, production review/dev duty runs `@stable`,
  so a broken `main`/`next` can no longer block its own fix. **Now** add `initiative:auto` to the epic
  and let the driver run the rest.

## Operating the driver (runbook)

- **Dry-run / preview** what would be released:
  `gh workflow run initiative-driver.yml -f dry_run=true` (or run the script with `DRY_RUN=true`).
- **Arm an initiative:** `gh issue edit <epic> --add-label initiative:auto` — this fires the driver
  immediately (labeled event) and the epic is picked up by every later sweep.
- **Pause one issue:** add `initiative:hold`; **hand back to a human:** add `dev-lead:hands-off`.
- **Throttle:** `gh workflow run initiative-driver.yml -f max_in_flight=1`.
- **Disarm:** remove `initiative:auto` from the epic — in-flight items finish; nothing new is released.

## Fleet enablement: cross-repo enrollment (`target_repo`)

The driver is not pinned to this repo. The gate/DAG tooling
(`scripts/initiative-driver.sh`) lives **once** here; any BMAD-enabled org repo
enrolls by shipping a thin **caller stub** and lets the central driver release
its stories cross-repo. This mirrors the planner half — see the symmetric
diagram in [`idea-to-initiative-pipeline.md` → Fleet enablement](./idea-to-initiative-pipeline.md#fleet-enablement-any-org-repo).

```
fleet repo: ★ human adds initiative:auto to the epic   (or a sub-issue closes)
   │
   ▼
initiative-driver.yml (stub) ──> initiative-driver-reusable.yml (@stable)
   │   the stub forwards the fleet repo's issues:[labeled initiative:auto] /
   │   issues:[closed] event to the central driver instead of running the
   │   gate/DAG logic inline (that logic lives only here)
   ▼
petry-projects/.github-private  initiative-driver.yml  -f target_repo=<fleet repo>
   │   sweeps the fleet repo's initiative:auto epics, resolves each ready story's
   │   blocked_by DAG, applies the `dev-lead` label THERE
   │   (cross-repo writes use GH_PAT_WORKFLOWS; self path uses GITHUB_TOKEN)
   ▼
dev-lead.yml (fleet repo) ──> PR ──> pr-review ──> merge ──> closing a story re-fires the stub
```

- **`target_repo`** is the only knob that differs from the self path: empty ⇒ this
  repo drives its own epics (dogfood), non-empty ⇒ the central driver sweeps and
  labels the named fleet repo. The concurrency lane is keyed per target repo, so
  one repo's sweep never queues behind another's.
- **Enroll a fleet repo:** copy the `initiative-driver.yml` caller stub into the
  repo's `.github/workflows/` and provision the cross-repo PAT — the same
  enrollment step that adopts the planner/triage/enhancer stubs. The authoritative,
  step-by-step enrollment runbook is **`petry-projects/.github` →
  `standards/ci-standards.md` §10 (Idea → Initiative pipeline)**; it is not
  duplicated here.
- **Arm an epic cross-repo:** identical to the self path — a human adds
  `initiative:auto` to the epic *in the fleet repo*. That `labeled` event fires the
  local stub, which dispatches the central driver with `target_repo=<fleet repo>`,
  releasing the first ready wave immediately.

### Safety & cost are unchanged by fleet enablement

Cross-repo enablement adds **no new gate and no new LLM cost** — it only changes
*which* repo the unchanged driver labels:

- **`initiative:auto` on the epic** is still the master switch; absent ⇒ the driver
  no-ops for that repo (a fleet repo's epics stay human-driven until armed).
- **`dev-lead:hands-off` / `initiative:hold`** on a story still block release.
- **`MAX_IN_FLIGHT`** still caps concurrent releases per epic, per target repo.
- **The PAT requirement still holds**, and is in fact load-bearing for the
  cross-repo write: the `dev-lead` label is applied with `GH_PAT_WORKFLOWS`, both so
  the resulting `issues:[labeled]` event triggers dev-lead *and* so the central
  driver can write to another repo at all.
- **No new LLM spend.** The driver is a pure `gh`-API + jq label dispatcher; it runs
  no model. The only LLM cost downstream is the dev-lead/pr-review run that a release
  was always going to trigger — the same cost on the self path. Fleet enablement
  fans the *destination* out across repos, still bounded by `MAX_IN_FLIGHT` per epic.

## Follow-ups (not in this scaffold)

- ~~A bats test that mocks `gh` to assert the gate / blocker / cap logic.~~ Done — `tests/test_initiative_driver.bats`.
- ~~Generalize `EPIC` beyond the hard-coded `495` default if a second initiative adopts the driver.~~
  Done — automatic triggers now sweep every `initiative:auto` epic; `workflow_dispatch` can still target one.
