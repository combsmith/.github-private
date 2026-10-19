# decision-brief tooling

Backs `.github/workflows/decision-brief.yml` — the BMAD Analyst ("Mary") that
turns one ripe idea (an Ideas Discussion) into the decision brief a human
approves `idea:approved` on: `ideas/<slug>/{brief,market-research,ost}.md`,
opened as a PR in the target repo. Closes the gap named in
[combsmith/incubator#3](https://github.com/combsmith/incubator/issues/3); the
full pipeline is in
[`docs/initiatives/idea-to-initiative-pipeline.md`](../../docs/initiatives/idea-to-initiative-pipeline.md).

Mary follows the **vendored BMAD analysis skills by path** (`frameworks/bmad-method/…/1-analysis/`)
through the headless overlays in [`prompts/incubation/`](../../prompts/incubation/README.md)
(`decision-brief-stage.md` orchestrates `producer-market-research.md`,
`producer-ost.md`, `producer-brief.md` under the `shared.md` contract).

| File | Role |
|------|------|
| `redispatch.sh` | Bridge the `discussion [labeled needs-brief]` trigger to `workflow_dispatch` (claude-code-action rejects `discussion` event contexts). Fired with a PAT so the dispatch actually starts a run. |
| `gather-context.sh` | Fetch the Discussion + comments, the feature-ideation enhancement comment, the idea-triage queue verdict, the TARGET repo's `ideas/_TEMPLATE/*` and `package-spec.json`, anything already under `ideas/<slug>/`, and referenced issues → `$CONTEXT_PATH`; export `DISCUSSION_NODE_ID`, `SLUG`, `IDEA_TITLE`. |
| `lib/slug.sh` | Pure, deterministic slug from the Discussion title (`💡 DemandRadar — …` → `demand-radar`), so a re-brief lands in the same folder and branch. |
| `validate-package.sh` | The **provenance + structure gate** (#1160): frontmatter, required sections (gate-compatible prefix match, plus `package-spec.json`), no placeholders, a RICE/ICE line with Confidence, a filled riskiest-assumption + cheapest-test row, a go/no-go that names `idea:approved`, and — the hard rule — every quantified market claim cited (URL / `[^n]`), tagged `[ASSUMPTION]`, or "unknown — needs discovery"; `market-research.md` ends with `## Sources`. Mary runs it; the workflow runs it again as its own step. |
| `open-pr.sh` | Land the package on `incubate/<slug>` in the target via the Git Data API (one commit, author = the business-analyst persona's runtime account), open or refresh the PR (label `decision-brief`), link it from the Discussion. Idempotent; `DRY_RUN=1` logs instead. **Never applies `idea:approved`.** |
| `ripe-from-queue.sh` | The sweep: read the target's "🧭 Idea Promotion Queue" Ripe table and dispatch one central brief run per idea that has no brief / open brief PR yet (skips `idea:approved`; capped by `MAX_BRIEFS`). |

Tests: `tests/test_decision_brief.bats` (tooling, gh mocked) and
`tests/test_decision_brief_workflow.bats` (workflow, reusable and stub
invariants), both run via `lint.yml`. Fixtures: `tests/fixtures/decision-brief/`
(a passing package, the untouched incubator template, a queue body).

## Fleet wiring

```
fleet repo: ★ needs-brief on an Ideas Discussion   ·   weekly post-triage schedule
   │
   ▼
decision-brief.yml (stub, standards/workflows/) ──> decision-brief-reusable.yml (@decision-brief/v1-stable, hosted here)
   │   trusted-actor guard; re-DISPATCHES the central workflow (PAT) with target_repo=<fleet repo>
   ▼
combsmith/.github-private  decision-brief.yml  -f discussion=N  -f target_repo=<fleet repo>  [-f from_queue=true]
   │   gather → Mary (claude-code-action) → validate-package.sh → open-pr.sh
   ▼
PR in the fleet repo: incubate/<slug> with ideas/<slug>/{brief,market-research,ost}.md
   │
   ▼
fleet repo: ★ human reads the brief, adds idea:approved to the Discussion → initiative-planner
```
