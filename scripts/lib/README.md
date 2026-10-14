# Review artifact contract & rubric registry

This directory holds the **artifact contract** and **rubric registry** for the
org's review automation (issue #611, epic #610).

The goal: review *logic* (engine routing, cascade orchestration, verdict
posting) should be reusable across different *things to review* — PR diffs
today, plans and skills later — without forking the reviewer three ways. The
contract names the small, stable interface between "what is being reviewed" and
"how it gets reviewed"; the registry is the lookup table that binds them.

The registry is an input-adapter layer **above** `engine.sh`. It does **not**
change engine/model routing — it only decides which rubric and output channel
apply to a given artifact. Phase 1 registers `pr_diff`, which resolves to today's
PR-review behavior with no change. Phase 2 (#614) adds `plan_json` additively: an
initiative `plan.json` scored against a fixed adversarial/semantic plan rubric,
with the verdict delivered as **machine-readable findings** the planner consumes
before `apply-plan.sh` materializes the epic/DAG — not a GitHub PR review.
Phase 2 (#615) adds `skill_candidate` additively: a candidate edit to a
prompt-skill (a diff or file) scored by the same review brain against the skill
rubric (Epic #581's strict-improvement eval criteria), with the verdict delivered
as a **machine-readable pass/fail + numeric score** the strict-improvement gate
consumes — also not a GitHub PR review.

## The artifact contract

Every reviewable thing is described by four fields:

| Field | Meaning | Allowed values |
| --- | --- | --- |
| `artifact_type` | What kind of thing is being reviewed. The registry key. | A type registered in the manifest: `pr_diff`, `plan_json`, `skill_candidate`. |
| `content_ref` | A pointer to the concrete content to review (not the content itself). | Opaque to the registry; interpreted by the output channel / caller. For `pr_diff` it is a PR URL (as passed to `review-one-pr.sh`); for `plan_json` it is a `plan.json` path (as passed to `initiative-planner/review-plan.sh`); for `skill_candidate` it is a candidate skill-edit path — a diff or file (as passed to `evals/review-skill.sh`). |
| `rubric` | The standard the content is scored against — an ordered cascade of prompt files, applied in sequence. | Resolved from the manifest. For `pr_diff`: `prompts/triage.md` → `prompts/deep-review.md` → `prompts/synthesize.md`. For `plan_json`: `prompts/plan-review.md` (the fixed plan critic). For `skill_candidate`: `prompts/skill-review.md` (the fixed strict-improvement skill reviewer). |
| `output_channel` | How the verdict is delivered. | Resolved from the manifest. For `pr_diff`: `scripts/post-pr-review.sh` (GitHub inline review comments + an approve/escalate review). For `plan_json`: `scripts/post-plan-findings.sh` (machine-readable findings JSON for the planner — never a GitHub review). For `skill_candidate`: `scripts/post-skill-score.sh` (machine-readable pass/fail + numeric score for the strict-improvement gate — never a GitHub review). |

`artifact_type` and `content_ref` are supplied by the caller (the input). The
registry resolves `rubric` and `output_channel` from the `artifact_type`.

## The registry manifest

[`review-registry.tsv`](./review-registry.tsv) is the versioned source of truth.
Data, not code — register a new artifact_type by adding a row; never fork the
reviewer.

### Deep-tier specialist routing (`deep_specialist:<type>`)

Issue #1091 (epic #1088) adds the issue-type classifier: the Tier-1 triage
prompt emits a `type` label in `{security, logic, performance, style}`, and the
`pr_diff` cascade routes its **deep tier** to a specialist prompt per class. That
routing is registry data, not a switch in `review-one-pr.sh` — the manifest
carries one `deep_specialist:<type>` row per class whose `rubric` column is the
single specialist prompt:

```bash
review_registry_lookup deep_specialist:security    rubric  # -> prompts/deep-review-security.md
review_registry_lookup deep_specialist:logic       rubric  # -> prompts/deep-review-logic.md
review_registry_lookup deep_specialist:performance rubric  # -> prompts/deep-review-performance.md
review_registry_lookup deep_specialist:style       rubric  # -> prompts/deep-review-style.md
```

These rows extend the `pr_diff` cascade's deep entry, so their `output_channel`
stays `scripts/post-pr-review.sh` (they route a PR review's deep tier, not a new
artifact type). [`deep-specialist.sh`](./deep-specialist.sh) resolves the label →
specialist prompt and **falls back to `prompts/deep-review.md`** whenever the
label is absent/ambiguous, has no row, or points at a missing file — so the deep
tier never dead-ends.

- A `# schema_version: N` comment carries the manifest version.
- Each data row is tab-separated: `artifact_type<TAB>rubric<TAB>output_channel`.
  - `rubric` is an ordered, comma-separated list of repo-root-relative prompt files.
  - `output_channel` is a repo-root-relative script.
- Lines beginning with `#` (after optional whitespace) and blank lines are ignored.

## The lookup helper

[`review-registry.sh`](./review-registry.sh) is sourced (`#!/usr/bin/env bash`,
`set -euo pipefail`) and exposes:

```bash
source scripts/lib/review-registry.sh

review_registry_version                                # -> 3
review_registry_types                                  # -> pr_diff\nplan_json\nskill_candidate
review_registry_lookup pr_diff rubric                  # -> prompts/triage.md,prompts/deep-review.md,prompts/synthesize.md
review_registry_lookup pr_diff output_channel          # -> scripts/post-pr-review.sh
review_registry_lookup plan_json rubric                # -> prompts/plan-review.md
review_registry_lookup plan_json output_channel        # -> scripts/post-plan-findings.sh
review_registry_lookup skill_candidate rubric          # -> prompts/skill-review.md
review_registry_lookup skill_candidate output_channel  # -> scripts/post-skill-score.sh
```

`review_registry_lookup` returns `1` for an unknown `artifact_type` and `2` for
a missing or unknown field.

Override `REVIEW_REGISTRY_MANIFEST` to point the helper at a different manifest
(used by tests).

## Ownership & tests

The registry and helper are covered by the repo's global CODEOWNERS rule
(`* @petry-projects/org-leads` in `.github/CODEOWNERS`), so changes here are
gated by default. Unit tests live in
[`tests/test_review_registry.bats`](../../tests/test_review_registry.bats).

---

## pr-review miss rate — the deterministic false-negative metric (#1596)

We already measure pr-review's operational health (`pr_review_health.sh`) and its
false **positives** (`evals/deep-review`). The missing signal was the one that was
free and perfectly labelled but evaporating: a trusted third-party advisory bot
(CodeRabbit, Copilot, Gemini, Codex, SonarCloud, Qodo, CodeAnt, Graphite) found a
**real** defect on a PR that pr-review had already **approved**. That is a false
**negative** — a *miss*. [`pr-review-miss-rate.sh`](./pr-review-miss-rate.sh)
computes it deterministically: no LLM is involved, every figure is `jq` over the
same GitHub review data the [reviewer scorecard](../reviewer_report.sh) already
fetches (one GraphQL round-trip per repo).

### The metric

| Field | Meaning |
| --- | --- |
| `missed_findings` | Threads a trusted advisory bot opened **after** pr-review's approving review, resolved as **accepted** (a fix landed / it was explicitly accepted). The core miss count. |
| `caught_findings` | Findings pr-review raised itself that were accepted — the denominator partner. |
| `partial_evidence_approvals` | Approvals issued via the advisory-gate **timeout fallback**, i.e. before all registered bots reported (see below). |
| `miss_rate_pct` | `missed / (missed + caught)`, integer percent (floor). |
| `per_bot` | Which reviewer found the miss **first** — a class of defect one bot repeatedly catches first is a directly actionable prompt gap for pr-review. |

The scorecard renders all of this in a **"pr-review miss rate"** section, overall
and per third-party reviewer (AC3). The per-PR record kind is `miss_pr`, emitted
by an **additive** collection pass in `reviewer_report.sh` (mirroring the #1411
`agent_comment` pass) so it never perturbs the existing bot scorecard.

### The crux: accepted vs refuted vs ambiguous (AC2)

Roughly 3 of 4 advisory-bot findings are false positives that are correctly
refuted. A naive "a bot opened a thread → pr-review missed it" counter would be
dominated by that noise and would push the agent toward *more* false positives. So
each finding is classified by the disposition recorded in its **resolving reply**,
and only **accepted** findings count. The rule (`pr_review_classify_disposition`):

1. An explicit machine marker wins: `<!-- disposition: accepted|refuted -->`
   (the last one on the thread takes effect).
2. Otherwise keyword heuristics over the **non-bot** reply comments:
   - accepted: "good catch", "fixed", "addressed", "accepted", "valid point/concern", …
   - refuted: "false positive", "not applicable", "by design", "won't fix", …
3. If neither (or both) fire → **ambiguous**.

A finding is a miss **only** when the disposition is `accepted` **and** the thread
is resolved. **Ambiguous counts as NOT a miss** — we deliberately under-count
rather than manufacture misses from noise. Both the real-miss and the
refuted-false-positive cases are unit-tested in
[`tests/test_pr_review_miss_rate.bats`](../../tests/test_pr_review_miss_rate.bats).

### Partial-evidence approvals (AC5)

The advisory-review gate proceeds via a **timeout fallback** (head-age or
quiescence) when some registered bots never report, so a slow/absent bot cannot
strand a PR forever. But that silently turns "all reviewers agreed" into "the ones
that answered agreed". [`partial-evidence-marker.sh`](./partial-evidence-marker.sh)
stamps a machine-detectable marker on the PR
(`<!-- pr-review-agent partial-evidence v1 sha=… submitted=… required=… reason=… -->`)
whenever this happens, so the metric can count `partial_evidence_approvals` and a
standing approval is never read as stronger evidence than it is. The marker is
posted from inside the gate (which sees the PR head SHA + snapshot); the gate
degrades to a silent no-op if the helper is not composed alongside it.

### Invalidating a standing approval (AC6)

When an accepted advisory finding lands **after** an approval at the same head, the
approval is a known false negative. `pr_review_invalidatable_approvals` (pure,
unit-tested) reports the approving-review SHA(s) that should be dismissed, and
[`scripts/invalidate-standing-approval.sh`](../invalidate-standing-approval.sh)
acts on it. **`DRY_RUN` defaults to `true`** — dismissing an approval is a
shared-state, hard-to-reverse action, so applying it is opt-in
(`DRY_RUN=false scripts/invalidate-standing-approval.sh <pr_url>`).

### Harvesting misses into regression cases (AC4)

An accepted miss is a free, perfectly-labelled regression case.
[`miss-harvest.sh`](./miss-harvest.sh) turns one into a de-identified JSONL case
for `evals/deep-review/dev/cases.jsonl`.

**HARD INVARIANT — dev/ ONLY, never holdout/.** The dev split is proposer-visible;
`holdout/` is CODEOWNER-gated and is the one control that keeps the eval's success
metric meaningful (#1088). Auto-harvesting into `holdout/` would silently destroy
it, so `mh_assert_dev_path` refuses any `holdout/` target and `mh_harvest` writes
**nothing** on refusal. Cases are also de-identified (URLs, @mentions,
tokens/secrets, emails → placeholders) before they are ever written
(`evals/README.md` decision A3). Both invariants are tested in
[`tests/test_miss_harvest.bats`](../../tests/test_miss_harvest.bats).

### Baselining the 30-day miss rate (AC7)

The metric is a rolling window; `reviewer_report.sh` honors `LOOKBACK_DAYS`
(default 7). To capture the **30-day baseline** the acceptance criterion asks for,
run the scorecard over a 30-day window and read the "pr-review miss rate" section:

```bash
ORG=petry-projects LOOKBACK_DAYS=30 GH_TOKEN=<pat> \
  bash scripts/reviewer_report.sh > /tmp/reviewer-30d.md
```

The `miss_rate_pct`, `partial_evidence_approvals`, and per-reviewer table in that
report are the baseline the weekly (7-day) reports are then tracked against.
