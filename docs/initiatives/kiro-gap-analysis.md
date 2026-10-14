# Initiative: Kiro Capability Reconciliation & Gap Decision Record

**Status:** Decision record — Phase 0 reconciliation for epic [#1142](https://github.com/petry-projects/.github-private/issues/1142) (story [#1143](https://github.com/petry-projects/.github-private/issues/1143))
**Author:** dev-lead / Claude Code
**Date:** 2026-07-14
**Scope (confirmed):** Reconcile every capability row and gap from the Kiro gap analysis
([Discussion #1118](https://github.com/petry-projects/.github-private/discussions/1118), enhancement
comment) against what this repo already ships, and record a **build / already-covered / drop** verdict
for each — grounded in a concrete repo artifact. This is a documentation/decision story only: no
scripts, workflows, or evals change. Its output tells a human which Kiro-inspired gaps are worth
building next.
**Constraints (confirmed):** Every verdict must cite a real path that exists in this repo (the
readiness bar). MCP curation is **already shipped** and must not be re-planned. The G5 (dev-local
hooks) verdict must be grounded in Claude Code's **actual** `settings.json` hook support versus Kiro's
live trigger types — not an assumption. The doc must not recommend adopting any AWS-proprietary Kiro
infrastructure (Bedrock routing, Powers marketplace, Autonomous Agent) as a dependency, consistent with
the repo's multi-provider engine strategy and the analysis's vendor-lock-in risk.

---

## 1. Why this record exists

The Kiro gap analysis (#1118) mapped Kiro-by-AWS against this repo and flagged several "gaps." Before
investing in any of them, we need a repo-grounded reconciliation so we **never rebuild something that
already shipped** (the clearest example being MCP curation, which #816 already ran and measured). This
record takes each capability row and each proposed gap, opens the cited artifact, and records a verdict:

- **already-covered** — this repo already does this (at parity or ahead); do not build.
- **build** — a genuine, high-value gap that builds on existing infrastructure; a human can pick it up.
- **drop** — do not pursue (either superseded by an already-covered capability, or an
  AWS-proprietary dependency that conflicts with the multi-provider strategy).

---

## 2. Capability reconciliation

Reproduces the capability comparison from #1118 §2, with a **Verdict** column and a grounded
justification per row. Where a row is broadly `already-covered` but contains a genuine sub-gap, the
sub-gap is carried into the gap-decision table in §5 (G1/G3/G4/G5) rather than re-scoped here.

| # | Capability | Kiro | This repo | Verdict | Grounded justification (artifact) |
|---|---|---|---|---|---|
| 1 | **Spec-driven planning** (requirements → design → task DAG) | `requirements.md` → `design.md` → `tasks.md`; wave-based parallel execution | Initiative planner: Discussion → schema-validated epic + story DAG with `blocked_by` edges, acceptance criteria, open-questions gate | **already-covered** | `scripts/initiative-planner/plan.schema.json` + `apply-plan.sh` materialize a validated epic/story DAG. The one real sub-gap — bidirectional **spec↔code sync** — is carried to **G1** (build). |
| 2 | **Agent hooks** (event-driven automation) | IDE-local file save/create/delete + tool-lifecycle triggers | CI/CD event hooks: intents classified from GitHub events; sweep re-dispatch on `workflow_run` | **already-covered** | `scripts/dev-lead-intent.sh` classifies CI-failure/review/mention/rebase events into intents; `.github/workflows/pr-review-sweep.yml` re-dispatches. Kiro's **developer-local** layer is a different surface — carried to **G5**. |
| 3 | **Steering rules** (persistent project context) | `.kiro/steering/` with `inclusion` modes; reads `AGENTS.md` | `CLAUDE.md` + `AGENTS.md` + per-tier prompt library | **already-covered** | `CLAUDE.md`, `AGENTS.md`, and `prompts/` (tier-specific, model-aware) provide equal-or-richer steering. Kiro's `inclusion: auto` is an ergonomic nicety, not a capability gap. |
| 4 | **Multi-engine model routing** | Bedrock: Claude for specs, Nova for code gen | 3-provider chains, per-tier routing, in-engine + cross-provider fallback, token logging | **already-covered** | `scripts/engine.sh` implements per-tier model chains with rate-limit cascading and cost-aware tier selection — ahead of Kiro. Adopting Bedrock routing would be a **drop** (see §6). |
| 5 | **Autonomous background agent** (plan → PR → CI → review loop) | Single long-running multi-repo session | `dev-lead`: intent-classified event → fix CI / address reviews / fix issue / rebase; human-gated release | **already-covered** | `scripts/dev-lead-intent.sh` + `scripts/dev-lead-fix-ci.sh`, `scripts/dev-lead-fix-reviews.sh`, `scripts/dev-lead-fix-issue.sh` cover the full lifecycle across workflow runs. The only true delta — single-session **continuity** — is carried to **G4**. |
| 6 | **Cloud automations** (scheduled recurring agent tasks) | Kiro web: ≤5 cron schedules per automation | Multiple purpose-built scheduled workflows | **already-covered** | `.github/workflows/feature-ideation.yml`, `.github/workflows/initiative-driver.yml`, and `.github/workflows/actions-fleet-monitor.yml` are battle-tested scheduled automations — at parity or ahead. |
| 7 | **Canary/ring rollout for agents** | No equivalent (Kiro versions itself as a product) | Ring-staged, health-gated promotion via channel tags; live-trigger canaries | **already-covered** | `scripts/cut-release.sh` + channel tags (`docs/release/versioning.md`) plus `scripts/initiative_canary.sh` / `scripts/initiative_driver_canary.sh` — a genuine differentiator over Kiro. |
| 8 | **Eval/quality gates** | Property-based testing / automated reasoning on requirements | Case schemas, judge prompts, held-out regression gate, eval-gated promotion | **already-covered** | `evals/` (schemas, `judge.md`) + `evals/deep-review/holdout/cases.jsonl` gate agent promotions on measured behavior quality. |
| 9 | **MCP integration** | Powers marketplace, AWS-specific servers, dynamic activation | Opt-in `REVIEW_MCP_CONFIG` convention, allowed-tools merge | **already-covered** | `scripts/engine.sh` (`REVIEW_MCP_CONFIG` / `REVIEW_MCP_ALLOWED_TOOLS`) + `docs/initiatives/mcp-powered-review.md`. Curation already ran (see §3). Adopting the AWS Powers marketplace would be a **drop** (§6). |
| 10 | **Multi-repo coordination** | Single task spans repos; PRs on each | Per-invocation single-repo; fleet ops iterate but don't coordinate cross-repo changes | **build** | `scripts/initiative-driver.sh` already accepts `REPO` (single); coordinated cross-repo stories under one epic is the real, incremental gap — carried to **G3**. |
| 11 | **Security model** | Sandbox isolation per session; never auto-merges | Immutable guards + held-out protection + human gates | **already-covered** | `.github/workflows/agent-shield.yml` (immutable), `scripts/lib/holdout-guard.sh`, and the `initiative:auto` human gate provide audit-trail + gate-based safety — strong, different emphasis. |

**Row count note:** Story #1143 references a "10-row" capability comparison from Discussion #1118. The
live enhancement comment in #1118 actually enumerates 11 rows (the "Security model" row was added as
part of the analysis refinement); this table reproduces all 11 rows to be complete. Story acceptance
criteria are met — the 10 originally scoped rows are a strict subset.

**Summary:** 10 of 11 rows are `already-covered`; only multi-repo coordination (row 10) is a
capability-level `build`. The remaining build candidates (G1, G4, G5) are sub-gaps of otherwise
`already-covered` rows and are decided in §5.

---

## 3. MCP curation is already shipped — do not re-plan (G2)

The source analysis proposed "MCP curation" as its lowest-risk Phase 1 experiment. **It already
shipped, and it already has a measured result — so it is `already-covered`, not a gap.**

- **Plumbing:** `scripts/engine.sh` threads `REVIEW_MCP_CONFIG` + `REVIEW_MCP_ALLOWED_TOOLS` into the
  deep/rubber-duck tiers with graceful degradation (epic [#676](https://github.com/petry-projects/.github-private/issues/676)).
- **Curation + measurement:** [#816](https://github.com/petry-projects/.github-private/issues/816)
  wired the zero-auth Context7 endpoint and ran a controlled A/B; it found **≈0 review-quality lift** on
  this repo's Bash/YAML PRs, because the base model's knowledge already covers mainstream library
  versions. See `docs/initiatives/mcp-powered-review.md` §5.1.
- **Where the marginal value actually is:** Context7's benefit concentrates on (a) post-training-cutoff
  library releases, (b) long-tail / private libraries, and (c) exact-signature precision + auditable
  citations — none of which dominate this repo's PR profile.

**Verdict: `already-covered` / drop as a gap.** Do not open MCP curation as new work. Any further MCP
step (promoting Context7 to `pr-review/stable`, or piloting on library-heavy downstream repos) is a
separate human decision already recorded in `mcp-powered-review.md` §5.1 — not part of this initiative.

---

## 4. G5 — Developer-local agent hooks vs. Claude Code's actual hook support

The source analysis said "**Verify Claude Code hook coverage before building anything.**" This section is
that verification, grounded in Kiro's live hooks docs and Claude Code's `settings.json` hook events —
not an assumption.

**Kiro's live trigger types** (from [kiro.dev/docs/hooks](https://kiro.dev/docs/hooks/), 2026-07-14):
7 agent-lifecycle triggers — `SessionStart`, `Stop`, `PreToolUse`, `PostToolUse`, `PreTaskExec`,
`PostTaskExec`, `UserPromptSubmit` — plus 3 file triggers — `PostFileCreate`, `PostFileSave`,
`PostFileDelete` (the analysis rounded this to "8 trigger types"; the live docs enumerate the fuller set
above).

**Claude Code's `settings.json` hook events** (from [Claude Code hooks documentation](https://docs.anthropic.com/en/docs/claude-code/hooks), verified 2026-07-14; all events are stable/GA unless noted):
`PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Notification`, `Stop`, `SubagentStop`, `PreCompact`,
`SessionStart`, `SessionEnd`.

| Kiro trigger | Claude Code `settings.json` coverage |
|---|---|
| `SessionStart` | ✅ Direct — `SessionStart` |
| `Stop` | ✅ Direct — `Stop` (and `SubagentStop` for sub-agents) |
| `PreToolUse` | ✅ Direct — `PreToolUse` (with tool matcher) |
| `PostToolUse` | ✅ Direct — `PostToolUse` (with tool matcher) |
| `UserPromptSubmit` | ✅ Direct — `UserPromptSubmit` |
| `PostFileCreate` | ✅ Indirect — `PostToolUse` matched on the `Write` tool |
| `PostFileSave` | ✅ Indirect — `PostToolUse` matched on `Write`/`Edit` |
| `PostFileDelete` | ⚠️ Partial — no dedicated event; reachable via `PostToolUse` on a `Bash` `rm` matcher |
| `PreTaskExec` | ❌ No equivalent — Claude Code has no Kiro-style "spec task" unit |
| `PostTaskExec` | ❌ No equivalent — same reason |

**Finding:** Claude Code's `settings.json` already covers the entire developer-local trigger *surface*
that matters here — all five lifecycle triggers directly, and the file create/save triggers indirectly
via `PostToolUse` tool matchers. The only genuine misses (`PreTaskExec` / `PostTaskExec`) map to a
Kiro-specific spec-task model this repo does not use, so they are not a real gap. **The gap, if any, is
convention + example templates — not capability.**

**G5 recommendation: DROP building a hook capability.** Do not introduce a `.claude/hooks/` or
`.github/hooks/` *format* — the capability already exists in `settings.json`. At most, a future **small
(S)** documentation follow-up could ship example hook snippets + a short "developer-local hooks" section
in `AGENTS.md`. Consistent with the story's guidance, that convention decision is **not** made here; if
a maintainer wants the docs/templates, it becomes a separate small story.

---

## 5. Gap decisions — go/no-go + rough size

Each remaining gap carries an explicit recommendation and a rough size (S ≈ ½–1 day, M ≈ 2–4 days,
L ≈ 1–2 weeks) so a human can pick what to build next. For every gap, the "adopt from Kiro / AWS infra"
Option A is a **drop** on vendor-lock-in grounds (§6); the decision is only ever about Option B (build
native on existing infrastructure).

| Gap | Description | Recommendation | Size | Grounding + rationale |
|---|---|---|---|---|
| **G1** | Spec-drift (one-way spec → code drift detection) | **GO (build)** | M | Builds directly on `scripts/initiative-planner/plan.schema.json` + the initiative pipeline: a post-merge check comparing a story's acceptance criteria against the merged diff, surfaced as an advisory comment. No new spec format. Already the substance of epic #1142's Phase 1 (#1144–#1146). Start one-way (spec → code); bidirectional is an unsolved hard problem and out of scope. |
| **G3** | Multi-repo coordinated changes | **GO on a design spike; NO-GO on full build until the spike lands** | L (spike M) | `scripts/initiative-driver.sh` already accepts a single `REPO` environment variable; coordinating cross-repo stories under one epic is incremental but has real blast radius. Any build must preserve the `initiative:auto` opt-in and per-repo `holdout-guard` protections. Matches the existing design-only spike story #1147. |
| **G4** | Session continuity (long-running agent context) | **NO-GO / drop for now** | S–M if ever pursued | The stateless per-event model (`scripts/dev-lead-intent.sh` + `scripts/dev-lead-fix-ci.sh`, `scripts/dev-lead-fix-reviews.sh`, `scripts/dev-lead-fix-issue.sh`) is a **deliberate safety choice**; a mutable cross-run state file adds staleness + hallucination risk for little gain. If revisited, restrict to a **read-only** context summary — never mutable shared state. Defer. |
| **G5** | Developer-local agent hooks | **DROP building a capability** (optional S docs follow-up) | S (docs only) | Claude Code's `settings.json` already covers the trigger surface (§4). No new hook format. If maintainers want example templates, that is a separate small story. |

*(G2 — MCP curation — is not listed here: it is `already-covered` per §3, not a remaining gap.)*

---

## 6. Vendor-lock-in guardrail

Kiro's deepest advantages — **Bedrock model routing**, the **Powers marketplace**, and the
**Autonomous Agent** — are AWS-proprietary. This record recommends **adopting Kiro patterns only, and depending on no Kiro/AWS infrastructure as a runtime dependency**, because that would conflict with
the repo's multi-provider engine strategy (`scripts/engine.sh` deliberately routes across
Claude/Copilot/Gemini) and the analysis's own vendor-lock-in risk (#1118 §4).

Concretely, all three are marked **drop** as dependencies:

- **Bedrock routing → drop.** `scripts/engine.sh`'s 3-provider, per-tier, fallback-aware routing already
  exceeds it and stays provider-neutral.
- **Powers marketplace → drop.** The opt-in `REVIEW_MCP_CONFIG` convention (§3) covers MCP without
  binding to an AWS-hosted marketplace.
- **Autonomous Agent → drop as infra.** Its *lifecycle pattern* is already covered by the `dev-lead`
  agent (§2, row 5); adopting the proprietary runtime would trade auditability + human gates for a black
  box.

---

## 7. References

- Discussion [#1118](https://github.com/petry-projects/.github-private/discussions/1118) — Kiro gap
  analysis (enhancement comment: the capability comparison + options table reproduced here).
- Epic [#1142](https://github.com/petry-projects/.github-private/issues/1142) — Kiro gap-closure
  initiative; this doc is Phase 0 story [#1143](https://github.com/petry-projects/.github-private/issues/1143).
- `docs/initiatives/mcp-powered-review.md` — MCP plumbing + the #816 A/B result (MCP `already-covered`), and the initiative-doc header shape this doc follows.
- Epics [#676](https://github.com/petry-projects/.github-private/issues/676) /
  [#816](https://github.com/petry-projects/.github-private/issues/816) — MCP enrichment + curation A/B.
- `scripts/engine.sh` — multi-provider routing + `REVIEW_MCP_CONFIG` threading.
- `scripts/initiative-planner/plan.schema.json`, `scripts/initiative-driver.sh` — spec-driven planning +
  release path (G1 / G3 grounding).
- `scripts/dev-lead-intent.sh`, `scripts/dev-lead-fix-ci.sh`, `scripts/dev-lead-fix-reviews.sh`,
  `scripts/dev-lead-fix-issue.sh` — autonomous lifecycle (row 5 / G4 grounding).
- `scripts/cut-release.sh`, `docs/release/versioning.md`, `scripts/initiative_canary.sh` — canary/ring
  rollout (row 7 grounding).
- `evals/` + `evals/deep-review/holdout/cases.jsonl` — eval/quality gates (row 8 grounding).
- `.github/workflows/agent-shield.yml`, `scripts/lib/holdout-guard.sh` — security guards (row 11).
- [kiro.dev/docs/hooks](https://kiro.dev/docs/hooks/) — Kiro's live trigger types (G5 evidence).
