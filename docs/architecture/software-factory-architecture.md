---
stepsCompleted: [1, 2]
inputDocuments:
  - docs/prd/agentic-software-factory.md
  - docs/architecture/adr/0013-factory-mvp-reference-architecture.md
  - docs/architecture/factory-mvp-architecture-review.md
  - docs/research/market-agentic-software-factories-research-2026-10-10.md
  - "petry-projects/.github-private#2226 (discussion), analyst comment of 2026-10-10"
companionDocuments:
  - docs/architecture/software-factory-design.md
workflowType: 'architecture'
project_name: 'software-factory'
user_name: 'Don'
date: '2026-10-10'
---

# Architecture Decision Document

_This document builds collaboratively through step-by-step discovery. Sections are appended as we work through each architectural decision together._

## Project Context Analysis

### Requirements Overview

**Functional Requirements:**
73 requirements in 12 groups (PRD §6). Architecturally they reduce to six capabilities:

- A declared Lifecycle with one State per Work item, visible on the item (FR-1 to FR-7).
- One run contract in which a Role requests Effects and a separate job applies them (FR-8 to FR-14).
- One Admission point that decides from GitHub's own state, so a lost event delays work and never
  deletes it (FR-15 to FR-21, FR-35 to FR-39).
- Human control that binds every Role the same way, with agents on their own identity
  (FR-22 to FR-28, FR-60 to FR-63).
- A merge decision bound to content and decided from structured Findings reported by a Council
  of Lenses (FR-29 to FR-34, FR-64 to FR-71).
- One Release on one gated path, with a Ledger behind every number (FR-40 to FR-59, FR-72, FR-73).

ADR-0013's twelve decisions and the Maintainer's decisions of 2026-10-10 are fixed inputs to this
design. ADR-0000 to ADR-0012 describe the POC and are not treated as constraints. Four mechanisms
ADR-0013 takes from them are restated as this design's own rules: the thin caller, channel tags,
the optional Consumer file, and the per-item concurrency key (design document, §2.4).

**Non-Functional Requirements:**
The ones that shape structure:

- NFR-12, NFR-13: a Kernel free of I/O, with a size budget, running on macOS and Linux.
- NFR-14 and review §14.1: about 3 GraphQL points per evaluation, to stay under 60% of one App
  installation's 5,000 requests an hour.
- NFR-1 and C-9: at most 10 Runs per merged pull request; noticing work takes at most 10% of
  job-minutes from a pool of 20 runner slots shared with all CI.
- NFR-5: no Work item without a next evaluation for more than 24 hours.
- NFR-8: merge to stable within 48 hours at p90 with batched, cached evals; rollback in 15 minutes.
- NFR-4: every merge carries a standing independent approval or an Override record.

**Scale & Complexity:**

- Primary domain: a control plane and automation harness on GitHub Actions. No interface of its own
  to operate: text on the Work item, a label vocabulary, and a read-only dashboard.
- Complexity level: high. Low data volume and no regulatory load, but very high integration
  complexity, untrusted public input, self-hosting, and three scarce shared resources.
- Scale: 12 public repos, one Maintainer, about 30 to 36 merges a week in the busiest repo.
- Estimated architectural components: 15. Kernel, facts port, records port, view port, effects
  port, engine port, identity port, Harness, pre-flight bundle, Controller, the brakes outside the
  Kernel, release tooling, the workflow set, the simulator, and the control room. A comparator
  against the POC is a later, non-gating component.

### Technical Constraints & Dependencies

- GitHub Free plan, every repo public, no always-on infrastructure (C-2, C-4).
- GitHub Actions starts work from events and schedules, and loses both (C-5).
- Scheduled and dispatched workflows always run the default branch, and a `uses:` reference
  cannot be computed. Hence one frozen entry shim.
- Reusable-workflow references are not redirected. Cutover is pause, then repoint.
- A code owner must be a user, so the approving reviewer stays a machine user with a long-lived
  token (C-6).
- LLM capacity is a subscription window of the Factory's own, with no supported usage signal
  (C-3, C-11).
  The credential is an environment secret in the Factory repo. The Harness calls the vendor's CLI.
- Python 3, standard library only, in the Kernel.
- Built in `petry-projects/software-factory`, which reads nothing from `.github-private` at run
  time.

Decided on 2026-10-10 and carried into the design:

- A Finding is decided by the Role that owns its domain, under an authority table held as data.
  Domain Roles start in shadow and are promoted on evidence. Only required Lenses gate.
- One GitHub App per Role, sharing the name prefix `combsmith-sf-`.
- The review Intent is built first and serves the Factory's own repo. The Maintainer approves
  until the first Release on `next` serves it.
- The comparison with the POC is a measure and not a gate. Stopping is the Maintainer's decision,
  if the Factory is not adopted and used.
- Each Lens declares the paths it watches. A Consumer repo's setup and test commands are part of
  its onboarding entry.
- The design is modelled before it is built: schemas with golden examples, the Lifecycle as data,
  a list of invariants, and a simulator that injects faults (design document, §3 to §5).

- State is derived from GitHub at every evaluation and never stored. The record of a Run is its
  Actions run record and its artifact. History is 90 days (design document, §3.9, §3.10, §7).
- Work is noticed by a poller. An event may only ask for a pass, and an optional external timer
  may start one.
- Decisions read GitHub only. The control room is written and never read back.
- Every `run` job reads through one shared reader App. A Role gets its own App when it first
  writes.
- `petry-projects/software-factory-control-room` is a public, rebuildable view with a dashboard,
  shaped by the situation-room analysis in `petry-projects/.github-private#2242 — Situation-room
  view for the agent fleet: build it from native Claude Code parts, not a command-center product`
  (design document, §8).

### Cross-Cutting Concerns Identified

- **Credential boundaries.** No job holds both an LLM credential and a write credential; only
  `verify` runs Work-item code, with no secret and no cache.
- **Schema versioning.** Every message is versioned, and a reader rejects a version it does not
  know.
- **One definition of State.** The Kernel computes it, and the status on the item and the row in
  the control room are the same answer.
- **One facts snapshot, three uses.** The Kernel's input is also the replay fixture and the
  contract-test fixture.
- **Fail to a Hold.** An unreadable fact, a missing capacity reading or a failed validation never
  yields an action.
- **Idempotent Effects.** GitHub writes carry no idempotency key, so every Effect type declares a
  recovery key that is not text in a body.
- **Finding authority.** Each category of Finding has exactly one owning Role. No Role decides on
  its own work. A security Finding is never declined without an Override.
- **Typing third-party prose.** Thread reviewers carry category and severity as text. They are
  typed only when the in-house reviewer adopts a Finding and raises its own.
- **Brakes outside the Kernel.** The pause variable, the Run ceiling, the actor-based loop count
  and, on a metered credential, a monthly cap read from the provider live where a Kernel defect cannot reach them.
- **Bootstrap.** Until a Release on `next` serves the Factory's repo, the Maintainer's attention is the line's
  capacity. The first slice is cut to one event, the Factory approving one of its own pull
  requests, and the approvals it takes are counted.
- **Trust classes for text.** Text from the Maintainer, a Role, an Advisory reviewer or an Outside
  contributor reaches a Task as labelled data.
