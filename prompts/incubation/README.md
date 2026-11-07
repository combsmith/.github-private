# Incubation personas — headless producer & validator overlays

These overlays turn the vendored **BMAD analysis/planning skills** into
**headless, CI-invocable producers and validators** for the incubation package
(`combsmith/incubator`, `ideas/<slug>/`). They are the automation layer
that wraps the skills — the skills themselves stay vendored and untouched under
`frameworks/bmad-method/` (see each `VENDOR.md`; do not hand-edit them).

This mirrors [`../bmad/scrum-master.md`](../bmad/README.md): an overlay that runs
vendored BMAD skills **non-interactively** against our input and emits a
machine-checkable artifact instead of the skills' default interactive output.

## What each artifact is, who owns it, where it lands

The **authoritative contract** is `ideas/package-spec.json` in the incubator repo
(enforced by `scripts/incubation-gate.sh`). Every producer MUST satisfy it:

| Artifact | File | Owner | Overlay | Vendored skill wrapped |
|---|---|---|---|---|
| Brainstorm | `brainstorm.md` | Mary (Analyst) | `producer-brainstorm.md` | `core-skills/bmad-brainstorming` |
| Market research | `market-research.md` | Mary (Analyst) | `producer-market-research.md` | `bmm-skills/1-analysis/research/bmad-market-research` |
| Decision brief | `brief.md` | Mary (Analyst) | `producer-brief.md` | `bmm-skills/1-analysis/bmad-product-brief` (already headless — preserve) |
| Opportunity–solution tree | `ost.md` (supporting, not gate-required) | Mary (Analyst) | `producer-ost.md` | — (Teresa Torres OST; grounded in the brief) |
| PRD | `prd.md` | John (PM) | `producer-prd.md` | `bmm-skills/2-plan-workflows/bmad-prd` (already headless — preserve) |

Each artifact also has a `validate-<artifact>.md` overlay (Ask 2) that emits a
machine-readable status the incubation gate's content-quality tier consumes.

The **Analyst→PM handoff is preserved**: Mary fronts brainstorm / market-research /
brief; the PRD is John's.

## The two entrypoints

- **`intent: create` / `update`** → a `producer-<artifact>.md` overlay. Reads the
  inputs (below), runs the wrapped skill headlessly, writes
  `ideas/<slug>/<file>.md`, ends with a `create` JSON status.
- **`intent: validate`** → a `validate-<artifact>.md` overlay. Critiques an
  existing `ideas/<slug>/<file>.md` against its checklist, writes a report, ends
  with a `validate` JSON status `{ status, blockers[], report_path }`.

Both are governed by [`shared.md`](shared.md) — the headless contract (inputs,
output frontmatter, no-fabrication rule, JSON schemas). Read it first.

## How these are invoked (Ask 3 — the decision-brief stage)

`.github/workflows/decision-brief.yml` (the central run; Mary) and
`decision-brief-reusable.yml` (the fleet dispatch bridge a thin caller stub
pins) wire the brief-stage producers end to end: a `needs-brief` label on an
Ideas Discussion — or an idea ranked **Ripe** by idea-triage — bridges through
`workflow_dispatch` (claude-code-action aborts on `discussion` contexts), runs
[`decision-brief-stage.md`](decision-brief-stage.md) → `producer-market-research.md`
→ `producer-ost.md` → `producer-brief.md`, enforces the provenance guard with
`scripts/decision-brief/validate-package.sh`, and opens the package as a PR on
`incubate/<slug>` in the target repo (combsmith/incubator#3). The brainstorm and
PRD producers are not wired by that stage: brainstorm stays human-facilitated,
and the PRD is John's, after `idea:approved`.
