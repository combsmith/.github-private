# initiative-planner tooling

Backs `.github/workflows/initiative-planner.yml` — the BMAD Scrum Master ("Bob")
that turns one approved idea (an Ideas Discussion) into a GitHub epic + sub-issue
DAG, ready for `initiative-driver` → `dev-lead`. See the full pipeline in
[`docs/initiatives/idea-to-initiative-pipeline.md`](../../docs/initiatives/idea-to-initiative-pipeline.md).

Bob follows the **real BMAD Method skills, vendored agent-agnostically under
`frameworks/`** (v6.8.0 + Test Architect v1.19.0; see
[`prompts/bmad/`](../../prompts/bmad/README.md)) — `bmad-sprint-planning` +
`bmad-create-story`, read by path. Stories are emitted in the canonical BMAD
create-story template, which `plan.schema.json` mirrors field-for-field.

| File | Role |
|------|------|
| `redispatch.sh` | Bridge the `discussion [labeled]` trigger to `workflow_dispatch` (claude-code-action rejects `discussion` event contexts). Fired with a PAT so the dispatch actually starts a run. Forwards `force_replan=true` when the firing label is `initiative:replan`, or `reconcile=true` when it is `initiative:reconcile` (vs the default `idea:approved` plan path). |
| `gather-context.sh` | Fetch the approved Discussion + repo context → `$CONTEXT_PATH`; export `DISCUSSION_NODE_ID`. Under `RECONCILE=1` also harvests the bound epic's sub-issues (state, labels, comments) into a `reconcile` block so Bob can pick up comment-surfaced follow-ups (#708). |
| `plan.schema.json` | The plan contract Bob must emit (epic + stories + `blocked_by`). |
| `validate-plan.py` | Schema + semantic checks: unique ids, acyclic DAG, an entry point, no dangling edges. |
| `lib/mutations.sh` | DRY_RUN-aware GitHub helpers (create issue, link sub-issue, add `blocked_by`, comment on Discussion, find/close issues for the idempotency guard, list existing reconcile-keys for the reconcile diff). |
| `apply-plan.sh` | Materialize a validated plan. Creates issues labelled `initiative` only — **never** `initiative:auto`. Idempotent: no-ops if the discussion is already planned, supersedes the old epic when `FORCE_REPLAN=1`, or reconciles it in place (adds only new accepted work) when `RECONCILE=1`. |
| `apply-reviewed-plan.sh` | The plan/apply-split handoff (#604): apply a maintainer-**reviewed** plan.json WITHOUT re-planning — re-validates the reviewed artifact, then runs `apply-plan.sh`. The BMAD Scrum Master never runs on this path. |

Tests: `tests/test_initiative_planner.bats`, `tests/test_initiative_planner_redispatch.bats`, `tests/test_plan_materialize.bats`, `tests/test_initiative_reconcile.bats` (run via `lint.yml`).

## Plan → review → apply split (#604)

By default `initiative-planner.yml` plans **and** applies in a single run (Bob
emits `plan.json`, then `apply-plan.sh` materializes it). But because the preview
should bind the result — *what a maintainer reviewed is what materializes* — the
workflow also supports a two-step split:

1. **Plan (dry-run).** Dispatch with `dry_run: true` (the default). Bob plans and
   the run uploads the authoritative `plan.json` as the `initiative-plan-dry-run`
   artifact. **No issues are created.**
2. **Review.** A maintainer downloads `plan.json` from that run and reviews it.
   *This is the human review gate for the plan contents* — distinct from the later
   `initiative:auto` gate that activates auto-implementation.
3. **Apply (no re-plan).** Re-dispatch with `plan_artifact_run_id` set to the
   dry-run's run ID. The workflow downloads that run's reviewed `plan.json`,
   **skips the LLM planning step entirely**, then re-validates and applies it via
   `apply-reviewed-plan.sh`. The reviewed artifact is what materializes.

The handoff is **artifact download by run ID** (`gh run download`), not a
committed plan file — it keeps reviewed plans out of git and ties each apply to a
specific, auditable dry-run. Artifact retention is the default 90 days, so apply
within that window. With `plan_artifact_run_id` empty, behavior is unchanged
(plan-then-apply in one run). Even a human-reviewed plan still materializes
**inert** (no `initiative:auto`); `apply-plan.sh` enforces that regardless of
path.

## Local dry run

```bash
# 1. Author or fetch a plan.json (see the schema), then:
python3 scripts/initiative-planner/validate-plan.py plan.json

# 2. Dry-run apply — logs intended mutations, touches nothing:
DRY_RUN=1 DRY_RUN_LOG=/tmp/plan.jsonl \
REPO=petry-projects/.github-private \
DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID=D_xxx \
PLAN_PATH=plan.json \
bash scripts/initiative-planner/apply-plan.sh
cat /tmp/plan.jsonl | jq .
```

## Invariants (enforced by tests)

- `apply-plan.sh` can never apply `initiative:auto` — activation is a human step.
- `hands_off` stories also get `dev-lead:hands-off` + `initiative:hold`.
- A dependency cycle, a missing entry point, or a dangling `blocked_by` fails
  validation before any issue is created.
- **Blocking open-questions gate (#682).** If the plan's `open_questions`
  contains any item flagged `blocking:true`, `apply-plan.sh` creates **zero**
  issues. Instead it posts the questions back to the source discussion with
  "not yet planned — answer these to proceed" framing and exits cleanly
  (DRY_RUN honored). This stops Bob from shipping an inert epic + sub-issue DAG
  that a human would have to close and re-plan once scope is settled (incidents
  #650→#659, #666→#667). Re-running after the questions are answered then
  materializes the real plan. Plain-string `open_questions` stay advisory and do
  **not** gate — only objects shaped `{"question": "...", "blocking": true}` do.
- **Materialize accepted critic findings (#706).** An `open_questions` object may
  carry a `proposed_story` (a whole story the plan is missing — `title` +
  `acceptance_criteria` scaffold) and a `proposed_blocked_by` (the existing issue
  that story gates), surfaced by a plan-critic finding whose resolution is "add
  story X". Until a maintainer sets **`accepted:true`** it gates exactly like a
  blocking open-question (creates nothing). On acceptance, `apply-plan.sh`
  materializes it: it creates the `proposed_story` as a **sub-issue of the epic**
  and wires a **native** `blocked_by` edge (`<proposed_blocked_by> blocked_by
  <new sub-issue>`, so the new story must land first) via `lib/mutations.sh`
  `add_blocked_by` — instead of leaving it as advisory prose a human must wire by
  hand (the #581 → #691/#692 gap). Acceptance is the human gate: materialization
  never happens automatically, and the epic still lands **inert** (no
  `initiative:auto`). A plan with no accepted `proposed_story` findings creates
  zero extra issues/edges. An accepted finding with no `proposed_story` is
  rejected by `validate-plan.py` (acceptance must have something to materialize).
- **Idempotency + supersede (default-safe re-planning).** Every epic carries a
  deterministic back-reference (`Planned from idea discussion #<src>`).
  `apply-plan.sh` uses it to detect its own prior output, so re-approving /
  re-dispatching / re-toggling the label never silently mints a duplicate epic +
  DAG. **Default:** if an open `initiative` epic already exists for the
  discussion, it creates **nothing** and points the discussion back at the
  existing epic. **`FORCE_REPLAN=1`** (the `force_replan` workflow input, or the
  **`initiative:replan`** discussion label) instead
  *supersedes*: it builds the fresh epic/DAG, then **closes (never deletes)** the
  old epic and its sub-issues with a "superseded by #NEW" note, keeping history
  and inbound references resolvable. The agent must always run `apply-plan.sh`
  and let the script make this decision — it must not pre-judge "already planned"
  and skip (the failure mode that left discussion #653's re-runs as silent
  no-ops).
- **Re-plan from the discussion (`initiative:replan`).** Adding the
  `initiative:replan` label to an Ideas Discussion fires the same redispatch
  bridge as `idea:approved`, but threads `force_replan=true` through to
  `apply-plan.sh` — so a maintainer can supersede an already-planned epic straight
  from the discussion, with no manual `workflow_dispatch`. The label must exist in
  the repo's label set (one-time config, like `idea:approved`).
- **Reconcile in place (#708, `RECONCILE=1` / `initiative:reconcile`).** Where
  `FORCE_REPLAN` *supersedes* the epic (closes it, builds a fresh DAG), reconcile
  turns the idempotent "already planned" SKIP into an **additive** pass: it binds
  to the existing epic (via the same back-reference as the idempotency guard),
  skips epic/base-story/base-DAG creation, and materializes **only** the accepted
  `proposed_story` findings that are not already in the epic's DAG — reusing #706's
  materialization path verbatim (not a second copy). This is how newly-surfaced
  work (a follow-up flagged in a sub-issue/review comment, harvested by
  `gather-context.sh` under `RECONCILE=1`, accepted by a maintainer) lands on an
  in-flight epic without a full re-plan. Guarantees, all proven offline via the
  DRY_RUN mutation log:
  - **Never rewrites in-flight work.** Writes are limited to NEW sub-issues + their
    edges; base/in-flight stories (a sub-issue carrying a `dev-lead` label) are
    never recreated, edited, or closed.
  - **Idempotent + bounded.** Each materialized sub-issue is stamped with a
    `reconcile-key` (`sha256(<src>::<title>)`); a re-run diffs proposed additions
    against the epic's existing keys (`existing_reconcile_keys`) and skips anything
    already present. A re-run with no new signal is a clean no-op (zero
    create/edge ops).
  - **Human gate preserved.** Un-accepted findings still gate (create nothing, post
    "not yet planned"); the epic stays **inert** (never `initiative:auto`).
  - **No existing epic ⇒ clean no-op.** If nothing is bound to the discussion yet,
    reconcile creates nothing and exits 0 (plan the idea with `idea:approved`
    first).
  - **Mutually exclusive with `force_replan`.** `apply-plan.sh` hard-errors if both
    `RECONCILE=1` and `FORCE_REPLAN=1` are set — additive-in-place and supersede
    are opposite intents. The `initiative:reconcile` label must exist in the repo's
    label set (one-time config, like `initiative:replan`).
