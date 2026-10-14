# PR-review bug-hunter audit — benchmark, prioritized gap list, frozen baseline

Phase 1 of epic **#1088** (*"Enhance the PR-review pipeline into a world-class bug
hunter"*), planned from Discussion **#906**. This is the grounding document: it
audits the current review cascade against top-tier commercial reviewer
architectures, produces a **prioritized gap list** in which every gap maps to a
downstream story in this epic, reconciles scope with the four in-flight epics the
initiative must not fork (#839, #676, #610, #581), and points at the **frozen
immutable baseline** every downstream "no regression" claim is measured against.

- **Baseline artifact:** [`tests/fixtures/deep-review-baseline/frozen-baseline-2026-07.json`](../../tests/fixtures/deep-review-baseline/frozen-baseline-2026-07.json)
  · provenance: [`PROVENANCE.md`](../../tests/fixtures/deep-review-baseline/PROVENANCE.md)
- **Related initiative:** [`mcp-powered-review.md`](./mcp-powered-review.md) (#676),
  [`skill-self-improvement.md`](./skill-self-improvement.md) (#581)

---

## 1. What we review today (the current cascade)

The PR-review automation is a cascading, multi-tier reviewer defined in
[`scripts/engine.sh`](../../scripts/engine.sh) and orchestrated by
[`scripts/review-one-pr.sh`](../../scripts/review-one-pr.sh). Each tier fires only
if the previous one escalated; the rubric (which prompts, in what order) is
resolved from the versioned registry manifest
[`scripts/lib/review-registry.tsv`](../../scripts/lib/review-registry.tsv) via
[`scripts/lib/review-registry.sh`](../../scripts/lib/review-registry.sh) — the
`pr_diff` artifact_type resolves to `triage → deep-review → synthesize`.

| Tier | Prompt | Default model (claude engine) | Job |
|------|--------|-------------------------------|-----|
| 1 — Triage | `prompts/triage.md` | haiku-4.5 | Cheap classify: escalate or approve; emit risk + signals. |
| 2 — Deep review | `prompts/deep-review.md` (`run_agentic`) | opus-4-8 | Thorough security + correctness + maintainability review; approve or escalate. |
| 2 — Rubber duck | `prompts/rubber-duck.md` (`run_duck`, **cross-engine**) | o4-mini via Copilot | Independent second opinion, run in parallel with deep for diversity. |
| 2b — Synthesize | `prompts/synthesize-duck.md` | sonnet-4-6 | Merge deep + duck verdicts. |
| 3 — Security audit | (escalation) | fable-5 | Final adjudication of HIGH-risk escalations. |
| 4 — Action | — | sonnet-4-6 | Deliver the verdict (inline comments) via `post-pr-review.sh`. |

Deterministic pre-computation already feeds the deep tier: mechanical safety
checks (`SAFETY_CHECKS_FILE`: CI-weakening, prompt-injection, large-PR,
dependency parsing), downstream-impact annotation (`DOWNSTREAM_IMPACT_FILE`),
advisory-bot feedback aggregation, and (when entitled) an MCP secret scan. The
deep prompt also already asks for **critical-path tracing**, **duplication
search**, and a **dependency-risk narrative** (`prompts/deep-review.md` steps
9–11).

**Strengths worth preserving.** Cost-tiered escalation; cross-engine duck for
model diversity; a deterministic safety layer that the LLM only narrates;
held-out eval infrastructure with an llm-judge scorer; a rubric registry that
already decouples "what is reviewed" from "how". These are patterns the
commercial reviewers below also rely on — the cascade is not starting from zero.

---

## 2. Benchmark against top-tier reviewer architectures

Four learning sources from Discussion #906 (this audit cites all four; the AC
requires ≥2). Each row is a *bug-finding* pattern and whether our cascade has it.

### 2.1 CodeRabbit — agentic validation ([blog](https://www.coderabbit.ai/blog/how-coderabbits-agentic-code-validation-helps-with-code-reviews), [how-it-works](https://medium.com/data-science-collective/how-coderabbit-actually-works-331aeab55ec8))

CodeRabbit's differentiator is **agentic validation**: a suspected issue is not
reported until an agent *acts* on it — runs the linter, executes a script, greps
the codebase — to confirm it reproduces. This is what keeps their false-positive
rate low: the review loop has a verify step, not just a generate step. They also
route by **path-scoped instructions** (per-directory review rubrics).

- **Us:** the deep tier reasons about suspected bugs but **never executes** lint
  or tests to confirm them before reporting. It has a `search` tool
  (duplication) but no run-and-verify loop. → **Gap A** (agentic validation) and
  partially **Gap B** (path/type routing).

### 2.2 Greptile — full-codebase semantic context ([what-is-ai-code-review](https://www.greptile.com/what-is-ai-code-review))

Greptile's core claim is that a diff-only reviewer misses the bugs that live in
the *interaction* between the change and the rest of the codebase. They index the
repo into a graph and feed the reviewer the **callers, callees, and type
definitions** of every touched symbol, so it can reason about breakage across
call sites, not just within the hunk.

- **Us:** the deep tier reviews **diff hunks in isolation** (`gh pr diff`). It has
  no callers/callees/type-def context for touched symbols; cross-call-site
  breakage is invisible unless it happens to fall inside the diff. → **Gap C**
  (semantic symbol context) — the single biggest bug-finding-depth gap.

### 2.3 baz.co — engineering intuition from history ([architecture-of-agentic-code-review](https://baz.co/resources/engineering-intuition-at-scale-the-architecture-of-agentic-code-review))

baz.co frames great review as **learned intuition at scale**: the reviewer is
primed with this codebase's own past review→merge outcomes, so it flags the
classes of issue humans historically flagged here and stays quiet on what humans
historically accepted. Few-shot grounded in *merged* history, not generic rules.

- **Us:** the cascade learns nothing from this repo's merged-PR history — no
  few-shot examples, prompts are static and repo-agnostic. → **Gap D** (merged-PR
  few-shot).

### 2.4 Qt — issue-type specialist skills ([qt-code-review-skills](https://www.qt.io/blog/introducing-the-qt-code-review-skills-for-agentic-development))

Qt ships **per-concern review skills** (a security skill, a performance skill,
etc.) and dispatches the relevant specialist rather than running one monolithic
reviewer. A specialist prompt out-performs a generalist on its own axis.

- **Us:** one monolithic `prompts/deep-review.md` handles security, logic,
  performance, and style together. No issue-type classifier, no specialist
  dispatch — even though the rubric registry (#610) is exactly the mechanism that
  could route to a specialist rubric. → **Gap B** (issue-type specialist routing).

### 2.5 Cross-cutting: false-positive measurement

All four sources treat **false-positive rate** as the primary quality axis (a
noisy reviewer gets muted). The epic's success metric wants FP-rate tracked from
`kind:"finding_verification"` records. **That signal is not emitted today** — see
Gap E below. You cannot regression-test an FP-rate you do not measure, so standing
up the emitter is a prerequisite, not a nice-to-have.

---

## 3. Prioritized gap list (each gap → the story that closes it)

Priority = bug-finding-depth impact per unit of cost/complexity, informed by the
epic's own ordering. Every gap maps to exactly one downstream sub-issue of #1088.

| # | Gap | Source(s) | Impact | Closing story |
|---|-----|-----------|--------|---------------|
| **C** | **Semantic symbol context** — deep tier reviews hunks without callers/callees/type-defs of touched symbols; cross-call-site breakage is invisible. | Greptile | **Highest** — the deepest class of missed bug. | **#1090** [Phase 2] Feed semantic symbol context into the deep + duck tiers. |
| **B** | **Issue-type specialist routing** — one monolithic deep prompt vs. a classifier dispatching a specialist rubric per type. | Qt, CodeRabbit | High — specialist beats generalist per axis; low mechanism cost (rubric registry already exists). | **#1091** [Phase 2] Issue-type classifier + specialist deep-review prompts via the rubric registry. |
| **A** | **Agentic validation** — suspected bugs reported without running lint/tests to confirm; inflates false positives. | CodeRabbit | High — directly moves the FP-rate the initiative is graded on. | **#1092** [Phase 3] Agentic iterative validation: confirm suspected bugs before reporting. |
| **D** | **Merged-PR few-shot** — no learning from this repo's past review→merge histories. | baz.co | Medium — improves precision/recall, must draw from the **dev split only** (never holdout) to avoid teaching to the test. | **#1093** [Phase 2] Inject merged-PR few-shot examples into the deep tier (dev-split only). |
| **E** | **FP-rate is unmeasured** — `emit_verification_record()` / `kind:"finding_verification"` do not exist in `scripts/lib/token-metrics.sh`; only a documented schema (#843, `tests/token_report.bats`). No baseline FP-rate can be captured. | all four (FP-rate is the shared quality axis) | Gating — the epic's "no regression on FP-rate" AC is unenforceable until this lands. | Emitter belongs with **#1092** (agentic validation is what produces `severity_before/after` + `outcome`); the **#1094** gate consumes it. |
| — | **Convergence measurement** — prove the whole thing against the frozen baseline on a real dry-run before any `LIVE_MODE` flip. | — | Gating (release safety). | **#1094** [Phase 4] Held-out eval regression gate + 5-PR dry-run + human go/no-go. |

### Sequencing note

Gaps B and D are pure prompt/registry changes (cheapest, land first, PR-sized).
Gap C adds context (watch the ET cost cap — see §5). Gap A + emitter E are the
heaviest (an execution loop) and produce the FP signal, so they gate the Phase-4
convergence check. Every quality change is scored **only** against the held-out
split and few-shot is drawn **only** from the dev split (§4 of `evals/README.md`),
so the eval stays honest.

---

## 4. Scope reconciliation with in-flight epics

For each, this initiative states **extend vs. defer** and the **exact touch-point**
so we build on the existing surface rather than forking it.

### #839 — LSP pilot (language-server code intelligence) · **CLOSED**
- **Decision: EXTEND (consume its go/no-go), do not re-pilot.** #839 already ran
  the LSP go/no-go for the pr-review Shell path.
- **Touch-point:** Gap C (#1090) is the natural consumer of LSP nav tools —
  callers/callees/type-defs of a touched symbol are exactly `textDocument/
  references`, `callHierarchy`, `definition`. #1090 should reuse #839's LSP
  navigation surface (or its MCP nav tools) to source symbol context rather than
  re-deriving it. If #839's go/no-go was *no-go* for live LSP, #1090 falls back to
  a lighter static-index/grep source but keeps the same "symbol context into the
  deep tier" contract. **Defer** the LSP transport decision to #839's outcome;
  **extend** it with a review-time consumer.

### #676 — MCP-powered review enrichment for `engine.sh` · **CLOSED**
- **Decision: EXTEND, do not duplicate.** MCP is already wired into the engine
  (`REVIEW_MCP_CONFIG`, `run_secret_scanning`, `search`) — see
  [`mcp-powered-review.md`](./mcp-powered-review.md).
- **Touch-point:** Gaps C and A should deliver new capabilities as **MCP tools on
  the existing config surface** (e.g. a symbol-context tool for #1090, a
  lint/test-runner tool for #1092), not as a new bespoke integration. Reuse
  `REVIEW_MCP_ALLOWED_TOOLS` gating and the graceful-degradation contract ("never
  fail a review because MCP was unavailable").

### #610 — context-adaptive review agent (artifact contract + rubric registry) · **OPEN**
- **Decision: EXTEND — the registry is the delivery mechanism for Gap B.**
- **Touch-point:** #1091 (issue-type specialist routing) must register specialist
  rubrics as **new rows / a richer `rubric` cascade in
  `scripts/lib/review-registry.tsv`**, resolved through
  `review-registry.sh` — it must **not** hardcode prompt paths or fork the
  reviewer (the registry's explicit invariant, AGENTS.md "Review artifact contract
  & rubric registry"). The classifier selects the rubric; the registry stays the
  source of truth. **Defer** any artifact-contract schema change to #610; this
  initiative only *adds rows*.

### #581 — eval-gated, human-reviewed self-improving skills · **OPEN**
- **Decision: EXTEND — reuse its eval infra as the quality gate; add no parallel scorer.**
- **Touch-point:** Every prompt/quality change (#1090–#1093) is scored through the
  **existing** `scripts/evals/run-eval.sh deep-review` (llm-judge, `evals/judge.md`,
  `pass_threshold` 0.7) and the strict-improvement gate
  (`scripts/evals/gate.sh`, `skill-self-improvement.md`). The held-out
  immutability discipline (`holdout-guard.yml` #692, CODEOWNERS over `evals/`) is
  reused verbatim — few-shot (#1093) draws from `dev/` only; scoring reads
  `holdout/` only. **Defer** the automated-proposer (#587) decision to #581; this
  initiative uses the manual propose→validate→PR runbook.

---

## 5. Frozen baseline (AC #3 / #4 — artifact established; two metrics deferred to downstream stories)

The immutable before-numbers live in
[`tests/fixtures/deep-review-baseline/frozen-baseline-2026-07.json`](../../tests/fixtures/deep-review-baseline/frozen-baseline-2026-07.json),
pinned by [`tests/test_deep_review_baseline.bats`](../../tests/test_deep_review_baseline.bats)
and owner-locked (see §6). Full provenance:
[`PROVENANCE.md`](../../tests/fixtures/deep-review-baseline/PROVENANCE.md).

| Metric | Value | Status | How the goalpost is fixed |
|--------|-------|--------|---------------------------|
| Median escalated-review (deep-tier) ET | **343,068.25** | **frozen — real telemetry** | Median of 10 real `deep`-tier records in the et-baseline fixture; recomputed and pinned by the guard. Epic cost cap: ≤ 1.5× = **514,602.375**. |
| Deep-review held-out eval score (llm-judge, thr 0.7) | `null` | pending — credentialed capture | `scripts/evals/run-eval.sh deep-review` needs engine credentials (the sandbox is *Not logged in* → exit 2, un-scored). Frozen by a CODEOWNER-reviewed credentialed CI run; a proposer-identity run must never freeze its own goalpost. |
| False-positive rate | `null` | unavailable — no emitter | `kind:"finding_verification"` is a documented schema only (Gap E); zero records exist → rate undefined. Frozen by the story that first emits them (#1092). |

**Why two metrics are honestly `null`, not fabricated.** The immutability
discipline this repo already uses for the ET baseline (#1102) is *"real, not
synthesized."* A credentialed eval score and an FP-rate from a non-existent
emitter cannot be captured in this Phase-1 context, so the artifact records the
**exact reproducible capture protocol** and a pending/unavailable status rather
than a made-up number. The regression guard asserts those statuses stay honest —
a silent flip to a real value fails CI and forces the first genuine capture through
a reviewed diff. Downstream "no regression" ACs reference this artifact; for the
still-pending metrics, the Phase-4 gate (#1094) captures a **same-run** baseline at
gate time (same engine, judge, window), which is strictly sound.

---

## 6. Immutability controls (mirrors the `evals/` holdout pattern)

The baseline is protected the same way the held-out eval set and the ET baseline
are, so later prompt-tuning stories cannot move the goalposts:

- **CODEOWNERS review-lock** — `/tests/fixtures/deep-review-baseline/` is owned by
  `@petry-projects/org-leads` in [`.github/CODEOWNERS`](../../.github/CODEOWNERS),
  so any edit requires an org-lead review (the control that actually gates the
  dev-lead-authored tuning PRs #1090–#1093).
- **Silent-deletion guard** — `test-deletion-guard.yml` (#823) fails any PR that
  deletes a file under `tests/` without the `ack-test-deletion` label.
- **Regression pin** — `tests/test_deep_review_baseline.bats` (registered in
  `lint.yml`) pins the exact frozen numbers and recomputes the median from source,
  so any change is an explicit, reviewable fixture diff.

**Path rationale.** `tests/fixtures/deep-review-baseline/` mirrors the blessed
`tests/fixtures/et-baseline/` precedent (#1102). It is chosen over an `evals/`
location because the named threat — *later prompt-tuning stories moving the
goalpost* — is dev-lead PRs (authored by `donpetry-bot`), which are gated by
CODEOWNERS + the regression pin. `holdout-guard.yml` only blocks the automated
skill-proposer identity (`github-actions[bot]`), so it would **not** stop a
dev-lead tuning PR; CODEOWNERS + the pin is the stronger control for this threat.

---

## 7. References

- Epic [#1088](https://github.com/petry-projects/.github-private/issues/1088) ·
  Story [#1089](https://github.com/petry-projects/.github-private/issues/1089) ·
  Idea Discussion #906
- Downstream: #1090 (symbol context) · #1091 (specialist routing) · #1092
  (agentic validation) · #1093 (merged-PR few-shot) · #1094 (convergence gate)
- Reconciled epics: #839 (LSP) · #676 (MCP) · #610 (rubric registry) · #581 (eval-gated skills)
- Cascade: [`scripts/engine.sh`](../../scripts/engine.sh) ·
  [`scripts/review-one-pr.sh`](../../scripts/review-one-pr.sh) ·
  [`prompts/deep-review.md`](../../prompts/deep-review.md) ·
  [`scripts/lib/review-registry.tsv`](../../scripts/lib/review-registry.tsv)
- Eval + cost: [`scripts/evals/run-eval.sh`](../../scripts/evals/run-eval.sh) ·
  [`evals/deep-review/scorer.json`](../../evals/deep-review/scorer.json) ·
  [`scripts/token_report.sh`](../../scripts/token_report.sh) ·
  [`scripts/lib/token-metrics.sh`](../../scripts/lib/token-metrics.sh)
- Immutability precedent: [`tests/fixtures/et-baseline/PROVENANCE.md`](../../tests/fixtures/et-baseline/PROVENANCE.md)
