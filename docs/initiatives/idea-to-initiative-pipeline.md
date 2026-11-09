# Idea → Initiative pipeline

How a raw idea becomes auto-implementable work, and where the human gates are.

```
feature-ideation.yml        (weekly, automated)   ──>  Ideas DISCUSSIONS
  BMAD Analyst "Mary"                                   (proposals)
        │
        ▼
idea-triage.yml             (weekly, automated)    ──>  "🧭 Idea Promotion Queue"
  ranks ripeness; never approves                        tracking issue (shortlist)
        │
        ▼
decision-brief.yml          (Ripe in the queue, or `needs-brief`; automated)
  BMAD Analyst "Mary"       ──>  PR: ideas/<slug>/{brief,market-research,ost}.md
                                 (RICE/ICE, riskiest assumption + cheapest test,
                                  go/no-go; every market claim cited or
                                  "unknown — needs discovery")
        │
   ★ HUMAN — read the brief, then add `idea:approved` to the Discussion
        │
        ▼
initiative-planner.yml      (on approval / dispatch, automated)
  BMAD Scrum Master "Bob"   sprint-planning + create-story
        │                   DRY-RUN: emits an authoritative plan.json artifact
        │                   (the `initiative-plan-dry-run` upload) — creates NOTHING
        │
   ★ HUMAN (optional plan-review gate) — download plan.json and review it
        │
        ▼
initiative-planner.yml      (apply: re-dispatch with `plan_artifact_run_id`)
  loads the reviewed plan.json — NO re-plan — validates + applies it
        │                   creates an EPIC + sub-issue DAG (blocked_by),
        │                   labelled `initiative` — INERT (no `initiative:auto`)
        │                   posts the plan back to the Discussion
        ▼
   ★ HUMAN — review the epic/DAG, then add `initiative:auto` to the epic
        │
        ▼
initiative-driver.yml       (on issues:closed + cron, automated)
  releases each ready story (blockers closed) by labelling it `dev-lead`
        ▼
dev-lead.yml  ──>  PR  ──>  pr-review  ──>  merge  ──>  "Closes #N"
        └──────────── closing a story unblocks its successors ───────────┘
```

Two automated stages were added to close the gap between "idea" and
"in-flight": **idea-triage** (shortlist) and **initiative-planner** (the BMAD
Scrum Master). Each is bounded by a human gate, so judgement stays with a
maintainer:

| Gate | Signal | Who |
|------|--------|-----|
| Idea is worth planning | add `idea:approved` to the Discussion | human |
| Initiative is ready to build | add `initiative:auto` to the epic | human |

## The two new workflows

Both are **org-private automation** (like `initiative-driver.yml`), not thin
caller stubs. Tooling and the vendored BMAD personas live in this repo and are
unit-tested.

### Idea enhancement — `feature-ideation`'s enhancement mode (the single enhancer)

There is exactly **one** Discussion-triggered enhancer. The standalone
`idea-enhancer.yml` (with its `scripts/idea-enhancer/` tooling) has been
**removed** (#876) now that its capability is fully folded into the
`feature-ideation` reusable workflow (epic #872) — so a human-authored idea is
enhanced **once**, never twice.

For each open, human-authored, not-yet-enhanced **Ideas** Discussion the folded
enhancer posts **one** comment (sharpened problem/goal, repo + market context,
impact/effort, suggested acceptance criteria). Bot-authored ideas are skipped —
they are already AI-generated. It never approves, labels, or promotes — that
stays with triage and the human gates.

The enhancement logic lives in the **central** reusable `combsmith/.github`
(`feature-ideation-reusable.yml`); `.github-private` ships only the thin
`feature-ideation.yml` caller stub (pinned to the `@feature-ideation/next`
dogfood ring), which exposes the enhancement modes as `workflow_dispatch`
inputs.

- **Backfill sweep** — dispatch `feature-ideation` with `enhance_backlog: true`.
  It sweeps the target repo's open, human-authored, not-yet-enhanced **Ideas**
  Discussions and posts **exactly one** structured enhancement comment each.
  Bot-authored and already-enhanced ideas are skipped. This is the safety-net
  backfill that catches human ideas added before the folded enhancer went live.
- **Dry-run** — dispatch with `dry_run: true` **and** `enhance_backlog: true`.
  Every intended per-Discussion enhancement comment is logged to the JSONL
  artifact and **nothing** is posted (one artifact entry per candidate
  Discussion). The dry-run is free of model spend beyond candidate gathering.
- **Marker continuity (cutover-safe).** The idempotency check honors **both**
  the legacy `<!-- idea-enhancer:enhanced -->` marker and the canonical
  `<!-- feature-ideation:enhanced -->` marker; new enhancement comments emit the
  single canonical marker. So **no** idea enhanced by the old `idea-enhancer` is
  re-enhanced after the cutover, and a repeated backfill is a no-op.
- **Cost.** Operator-triggered (`workflow_dispatch`), **no new cron** — the
  backfill reuses `feature-ideation`'s existing model budget and 20-minute
  timeout, so it is cost-neutral-to-reducing.

#### Operator runbook — backfilling the `.github-private` backlog

1. **Dry-run first.** Run the **Feature Research & Ideation** workflow via
   *Run workflow* with `enhance_backlog: true` **and** `dry_run: true`. Download
   the dry-run JSONL artifact and confirm its entry count equals an independent
   count of open, human-authored, not-yet-enhanced Ideas (the candidate set).
   Nothing is posted.
2. **Go live.** Re-dispatch with `enhance_backlog: true` and `dry_run: false`.
   After one live run, every open, human-authored, not-yet-enhanced Idea carries
   exactly one structured enhancement comment — the un-enhanced backlog drops to
   **0**.
3. **Verify idempotency.** A second live backfill run posts **0** new comments
   (no idea is double-enhanced, including ideas already carrying the legacy
   marker) — the idempotency guarantee that let the standalone `idea-enhancer`
   be retired (#876).

There is exactly **one** Discussion-triggered enhancer. The standalone
`idea-enhancer.yml` (with its `scripts/idea-enhancer/` tooling) has been
**removed** (#876) now that its capability is fully folded into the
`feature-ideation` reusable workflow (epic #872) — so a human-authored idea is
enhanced **once**, never twice.

For each open, human-authored, not-yet-enhanced **Ideas** Discussion the folded
enhancer posts **one** comment (sharpened problem/goal, repo + market context,
impact/effort, suggested acceptance criteria). Bot-authored ideas are skipped —
they are already AI-generated. It never approves, labels, or promotes — that
stays with triage and the human gates.

The enhancement logic lives in the **central** reusable `combsmith/.github`
(`feature-ideation-reusable.yml`); `.github-private` ships only the thin
`feature-ideation.yml` caller stub (pinned to the `@feature-ideation/next`
dogfood ring), which exposes the enhancement modes as `workflow_dispatch`
inputs.

- **Backfill sweep** — dispatch `feature-ideation` with `enhance_backlog: true`.
  It sweeps the target repo's open, human-authored, not-yet-enhanced **Ideas**
  Discussions and posts **exactly one** structured enhancement comment each.
  Bot-authored and already-enhanced ideas are skipped. This is the safety-net
  backfill that catches human ideas added before the folded enhancer went live.
- **Dry-run** — dispatch with `dry_run: true` **and** `enhance_backlog: true`.
  Every intended per-Discussion enhancement comment is logged to the JSONL
  artifact and **nothing** is posted (one artifact entry per candidate
  Discussion). The dry-run is free of model spend beyond candidate gathering.
- **Marker continuity (cutover-safe).** The idempotency check honors **both**
  the legacy `<!-- idea-enhancer:enhanced -->` marker and the canonical
  `<!-- feature-ideation:enhanced -->` marker; new enhancement comments emit the
  single canonical marker. So **no** idea enhanced by the old `idea-enhancer` is
  re-enhanced after the cutover, and a repeated backfill is a no-op.
- **Cost.** Operator-triggered (`workflow_dispatch`), **no new cron** — the
  backfill reuses `feature-ideation`'s existing model budget and 20-minute
  timeout, so it is cost-neutral-to-reducing.

### `idea-triage.yml` — weekly ripeness shortlist
- Scans every open **Ideas** Discussion, scores each **Ripe / Soon / Not yet**
  on evidence, prerequisites, alignment, coverage, and freshness.
- Rewrites a single **Idea Promotion Queue** tracking issue (label
  `idea-triage`) with the ranked list and a pre-drafted promotion note per ripe
  idea. It **never** applies `idea:approved` — that's the human's pick.
- Tooling: `scripts/idea-triage/{gather-ideas,upsert-queue}.sh`.

### `decision-brief.yml` — BMAD Analyst "Mary" (the go/no-go brief)
- Closes the gap named in [combsmith/incubator#3](https://github.com/combsmith/incubator/issues/3):
  before it, a human applied `idea:approved` on one enhancement comment and a
  triage score. Now a **decision brief** is the artifact they approve on.
- Trigger: an Ideas Discussion gets the `needs-brief` label (bridged to
  `workflow_dispatch` by the `redispatch` job — claude-code-action aborts on
  `discussion` events), or a `from_queue=true` dispatch that briefs every idea
  idea-triage ranked **Ripe** in the target's Idea Promotion Queue and that has
  no brief yet (capped per sweep). Manual dispatch defaults `dry_run: true`.
- Mary fills the **target repo's own** `ideas/_TEMPLATE/{brief,market-research,ost}.md`
  (`prompts/incubation/decision-brief-stage.md` + the per-artifact producers,
  wrapping the vendored BMAD analysis skills by path): problem + JTBD with the
  evidence, cited market context, OST, **ICE by default** (RICE only when a Reach
  figure is cited; Confidence tied to the evidence rung), a **riskiest-assumption
  and cheapest-test** table, and a **go / no-go / park** recommendation that says
  what a POC must prove and what would make the decider say no.
- **Provenance guard (#1160).** `scripts/decision-brief/validate-package.sh`
  runs in a separate `land` job from a clean checkout after the model job: any quantified market claim without a
  URL / `[^n]` footnote / `[ASSUMPTION]` tag / "unknown — needs discovery", a
  missing score or Confidence, an empty assumptions table, a recommendation that
  takes no position, or a leftover template placeholder fails the run — the
  package stays an artifact and never becomes a PR.
- `open-pr.sh` (same isolated `land` job, the only one holding the org PAT)
  lands the package on `incubate/<slug>` in the target (one commit via the Git
  Data API, author = the business-analyst persona's runtime account),
  opens or refreshes the PR, and links it from the Discussion. **It never applies
  `idea:approved`.**
- Tooling: `scripts/decision-brief/` (tests: `tests/test_decision_brief.bats`,
  `tests/test_decision_brief_workflow.bats`).

### `initiative-planner.yml` — BMAD Scrum Master "Bob"
- Trigger: a Discussion gets labelled `idea:approved`, or manual
  `workflow_dispatch` with a discussion number (`dry_run` defaults to **true**).
- **Follows the real BMAD Method skills, vendored agent-agnostically under
  `frameworks/`** (BMM v6.8.0 at `frameworks/bmad-method/` + **Test Architect**
  v1.19.0 at `frameworks/bmad-test-architecture/`; `src/` skill trees only, see
  `prompts/bmad/README.md`). The planner reads the skills **by path** (not via any
  vendor-specific `.<tool>/skills` dir), following `bmad-sprint-planning` +
  `bmad-create-story` (and the Test Architect `bmad-tea`/`testarch`, the agent
  behind the `qa-lead` persona, where useful) —
  not a paraphrase. Stories are emitted in the canonical BMAD **create-story
  template** (Story / Acceptance Criteria / Tasks-Subtasks / Dev Notes / Project
  Structure Notes / References) and self-checked against the create-story
  **checklist**.
- Reads the approved idea + repo context, runs sprint-planning + create-story,
  and emits a schema-validated **initiative plan** (`plan.schema.json`, which
  mirrors the BMAD template field-for-field): an epic + 3–8 PR-sized stories
  with testable acceptance criteria, AC-referencing tasks, grounded Dev Notes,
  sizes, and a `blocked_by` DAG. Prerequisites already tracked as issues become
  `blocked_by_existing_issues` edges, not new stories.
- Materializes the epic + native sub-issue DAG via `apply-plan.sh`, labelled
  `initiative` only. **It never applies `initiative:auto`** — the epic is created
  inert and a human activates it after review. `hands_off` stories also get
  `dev-lead:hands-off` + `initiative:hold` so the driver never auto-releases them.
- **Plan → review → apply split (#604).** A dry-run uploads the authoritative
  `plan.json` (the `initiative-plan-dry-run` artifact) and creates nothing. A
  maintainer can download and review it, then re-dispatch with
  `plan_artifact_run_id` set to the dry-run's run ID: the workflow re-downloads
  that artifact, **skips Bob entirely (no re-plan)**, and validates + applies
  it via `apply-reviewed-plan.sh` — so *what a maintainer reviewed is what
  materializes*. With `plan_artifact_run_id` empty, the default plan-then-apply
  flow is unchanged. The handoff is artifact-download-by-run-ID; the artifact
  is re-fetched from GitHub Actions and not taken from a local file. This plan-review gate is **distinct** from the `initiative:auto` gate: the
  former binds the plan *contents*, the latter activates auto-*implementation*.
- **Planning inputs.** `gather-context.sh` also reads the target repo's
  `_bmad-output/planning-artifacts/` (the planning source of truth named in org
  `AGENTS.md`) into `planning_artifacts`: `prd.md` in full, every other
  top-level `.md` truncated (12,000 chars by default). When a PRD is present Bob
  plans from its functional requirements and success metrics and treats the
  Discussion as context; with no folder (404) or no markdown in it,
  `planning_artifacts` is `null` and Bob plans from the Discussion as before.
- **`discussion_repo`** (optional) names the repo the Discussion lives in when it
  differs from `target_repo` — see [Graduation](#graduation-incubator-idea--product-repo).
- Tooling: `scripts/initiative-planner/` (persona: `prompts/bmad/scrum-master.md`).

## Graduation: incubator idea → product repo

An idea is approved in `combsmith/incubator`, but its epic belongs in the product
repo it graduates into. The planner reads the Discussion from one repo and plans
into another:

```
combsmith/incubator: ★ Ideas Discussion #N approved (decision brief merged)
   │
   ▼
product repo (e.g. combsmith/worldchest): seed _bmad-output/planning-artifacts/
   │   prd.md (+ brief.md, architecture.md, ...) committed on the default branch
   ▼
combsmith/.github-private  initiative-planner.yml
   -f discussion=N -f discussion_repo=combsmith/incubator -f target_repo=<product repo>
   │   reads Discussion #N from the incubator, the PRD + open epics from the
   │   product repo; Bob plans from the PRD's FRs and success metrics
   ▼
inert epic + story DAG in the product repo; the plan reply is posted on the
incubator Discussion, with links qualified as <product repo>#n
```

1. **Approve in the incubator.** The decision brief for Discussion #N is merged and
   the owner decides to build. The incubator has no planner stub, so this does not
   dispatch anything by itself.
2. **Seed the artifacts in the product repo.** Copy the PRD and its companions
   into `_bmad-output/planning-artifacts/` on the product repo's default branch
   (the planner reads it through the contents API, so it must be merged, not on
   a branch).
3. **Dry-run the planner** with both repos set:

   ```bash
   gh workflow run initiative-planner.yml --repo combsmith/.github-private \
     -f discussion=N -f discussion_repo=combsmith/incubator \
     -f target_repo=combsmith/<product> -f dry_run=true
   ```

4. **Review and apply.** Download the `initiative-plan-dry-run` artifact, review
   `plan.json`, then re-dispatch the same command with
   `-f plan_artifact_run_id=<dry-run run id> -f dry_run=false`.
5. **Arm it.** Add `initiative:auto` to the new epic in the product repo.

The epic's back-reference is `Planned from idea discussion combsmith/incubator#N`,
which is also the idempotency key, so re-dispatching (or `force_replan` /
`reconcile`) binds to the same epic. Same-repo runs keep the bare `#N` key, so
epics planned before this change still bind. A cross-repo run uses the PAT for
both repos (`GITHUB_TOKEN` only covers `.github-private`). No mirror Discussion in
the product repo is needed.

## Labels the pipeline relies on

| Label | On | Meaning |
|-------|----|---------|
| `idea:approved` | Discussion | Human blessed this idea for planning → fires the planner |
| `idea-triage` | Issue | Marks the Idea Promotion Queue tracking issue |
| `needs-brief` | Discussion | Human asks Mary for a decision brief → fires decision-brief |
| `decision-brief` | PR | The brief package PR Mary opened in the target repo |
| `initiative` | Epic + stories | Part of a tracked initiative |
| `initiative:auto` | Epic | Human activated auto-implementation (driver may release) |
| `initiative:hold` / `dev-lead:hands-off` | Story | Never auto-released; needs a human |

## Safety properties

- **Two human gates**, both opt-in labels. Nothing reaches `dev-lead` without a
  maintainer adding `idea:approved` then `initiative:auto`.
- **Dry-run first.** The planner defaults `dry_run: true` on manual dispatch and
  logs every intended mutation to an artifact; triage supports the same.
- **Auto is never self-applied.** `apply-plan.sh` cannot emit `initiative:auto`
  (enforced by `tests/test_initiative_planner.bats`).
- **DAG is validated** (acyclic, has an entry point, no dangling edges) before
  any issue is created.

## Fleet enablement (any org repo)

The pipeline runs for any BMAD-enabled org repo, not just this one. The BMAD
frameworks, the planner, and the triage/enhancer tooling stay vendored **once**
here; each fleet repo ships only thin **caller stubs** (copied from combsmith/.github/standards/workflows/{initiative-planner,idea-triage,feature-ideation}.yml into their local .github/workflows/ directory).

```
fleet repo: ★ human adds idea:approved to an Ideas Discussion
   │
   ▼
initiative-planner.yml (stub) ──> initiative-planner-reusable.yml (@initiative-planner/stable)
   │   (claude-code-action can't run on `discussion` events, so the reusable
   │    re-DISPATCHES the central planner instead of planning inline)
   ▼
combsmith/.github-private  initiative-planner.yml  -f target_repo=<fleet repo> -f dry_run=false
   │   reads the fleet repo's Discussion, writes the epic + DAG THERE
   │   (cross-repo writes use GH_PAT_WORKFLOWS; self path uses GITHUB_TOKEN)
   ▼
inert epic + story DAG in the fleet repo
   │
   ▼
fleet repo: ★ human adds initiative:auto to the epic   (+ a sub-issue closes later)
   │
   ▼
initiative-driver.yml (stub) ──> initiative-driver-reusable.yml (@stable)
   │   (the driver's gate/DAG tooling lives ONCE here, so the stub forwards the
   │    fleet repo's issues:[labeled initiative:auto] / issues:[closed] event to
   │    the central driver instead of running the release logic inline)
   ▼
combsmith/.github-private  initiative-driver.yml  -f target_repo=<fleet repo>
   │   sweeps the fleet repo's initiative:auto epics, resolves each ready story's
   │   blocked_by DAG, and applies the `dev-lead` label THERE
   │   (cross-repo writes use GH_PAT_WORKFLOWS; self path uses GITHUB_TOKEN)
   ▼
dev-lead.yml (fleet repo) ──> PR ──> pr-review ──> merge ──> closing a story re-fires the stub
```

The two legs are symmetric: the **planner** leg turns an approved idea into an
inert epic + DAG in the fleet repo; the **driver** leg releases that epic's
ready stories to `dev-lead` cross-repo once a human arms it. Both ship only a
thin per-repo stub and dispatch the central workflow with `target_repo`.

- **decision-brief leg (hosted here).** `standards/workflows/decision-brief.yml`
  (staging copy; to be promoted to `combsmith/.github/standards/workflows/`) is the
  thin caller a fleet repo adds. It pins
  `combsmith/.github-private/.github/workflows/decision-brief-reusable.yml@decision-brief/v1-stable`,
  which forwards `needs-brief` label events and the weekly post-triage sweep to the
  central `decision-brief.yml` with `target_repo=<fleet repo>`; the brief PR lands
  THERE. The fleet repo needs `ideas/_TEMPLATE/`, the `needs-brief` and
  `idea:approved` labels, and the org PAT.
- **`target_repo`** parameterizes the central planner/triage/enhancer **and the
  driver**; empty ⇒ the dogfood/self path (`.github-private` plans + drives its
  own issues), non-empty ⇒ the named fleet repo.
- **Project-board funnel (hybrid):** epics in **consumer (fleet) repos** land on
  that repo's own project; epics in **`combsmith/.github` and
  `combsmith/.github-private`** land on the org-level "Initiatives" project
  (`orgs/combsmith/projects/1`).
- **Regression detection:** `initiative-planner-canary.yml` smoke-tests the live
  `idea:approved` → dispatch path and `initiative-driver-canary.yml` smoke-tests the
  symmetric cross-repo release path (a dry-run `target_repo` dispatch of the driver),
  while Fleet Monitor watches each adopted stub for drift — so a silent revert of
  either trigger (the [#655](https://github.com/combsmith/.github-private/issues/655)
  class) surfaces immediately rather than on a maintainer noticing nothing planned or released.
- **Adoption + the full enrollment runbook:** see
  `combsmith/.github` → `standards/ci-standards.md` §10 (Idea → Initiative pipeline).
