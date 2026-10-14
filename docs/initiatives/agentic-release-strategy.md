# Initiative: Safe Release Strategy for Agentic Workflows

**Status:** Proposed — for review
**Author:** dev-lead / Claude Code
**Date:** 2026-06-08
**Scope (confirmed):** Core agentic workflows + their delivery path — `dev-lead`, `pr-review`,
and the deploy/release mechanism that pushes them to consumer repos. Utility workflows
(fleet-monitor, compliance, token-report, ci-failure-analyst, etc.) are out of scope for now
and adopt the pattern later.
**Constraints (confirmed):** GitHub-native only (tags/releases, `@ref` pinning, Environments,
matrix-staged deploys) — no new repos, no external infrastructure. Canary / ring-0 = `.github-private`
itself (dogfood-first).
**GitHub Project:** [Initiatives](https://github.com/orgs/petry-projects/projects/1) →
Initiative field **“Release Strategy”**.

---

## 1. Executive summary

Our two most critical pieces of agentic infrastructure — the **dev-lead** agent (plans, implements,
and merges changes) and the **pr-review** agent (reviews and approves them) — are **self-hosting**:
they are the tools that build, review, and ship changes *to themselves*. Today there is **no version
boundary** between “the agent doing the work” and “the agent being changed”:

- **`.github/workflows/pr-review-reusable.yml`** calls `pr-review.yml@main`, meaning all callers
  of the reusable inherit a floating ref. There are **0 git tags and 0 releases** in the repo.
- A merge to `main` is therefore **instantly live** across the agents' own self-review duty *and*
  every consumer repo, with **no canary, no health gate, and no rollback**.
- Deployment to consumers is a blunt `PUT /contents` **overwrite of `main`** across all four
  consumer repos at once (`.github/workflows/deploy-pr-review.yml`).

The result is a **circular dependency that fails closed**: when a change breaks `pr-review.yml`, the
very agent that must approve the fix PR is the broken one, so clean fix-PRs stall at `REVIEW_REQUIRED`
indefinitely (issue #463). When a change breaks `dev-lead`, it can no longer reliably fix itself
(#466). The “known-good” version is destroyed the instant the new one lands, and there is no version
to roll back *to*.

This initiative proposes a **GitHub-native versioned-release model with concentric rings and
health-gated promotion**. The core move: production duty (the agents' own self-review and all consumer
repos) runs a **pinned per-agent `stable` channel** (e.g., `@pr-review/stable`,
`@dev-lead/stable`), while new versions are exercised on a **`next` channel in ring 0
(`.github-private` self-host)** and promoted ring-by-ring only after they prove
healthy. This breaks the circular dependency (a broken in-development version can no longer gate its
own fix), shrinks blast radius from “whole fleet, instantly” to “one ring at a time,” and makes
rollback a single pointer flip.

**Version selection uses moving channel tags, not per-caller edits.** GitHub does **not** allow an
expression in a `uses:` ref (`uses: …@${{ vars.X }}` is rejected — refs resolve at workflow-parse
time, before any context exists). So instead of re-pinning every caller on each release, **each caller
pins *once* to a per-agent floating channel tag** (`@pr-review/stable`, `@dev-lead/stable`,
`@pr-review/next`, etc.); promotion is a single *central* tag move in `.github-private`, and callers
are never edited again — exactly how `actions/checkout@v4` works. Per-agent channel names ensure that
promoting a `pr-review` release does not inadvertently advance `dev-lead/stable` to the same SHA.
Immutable per-agent release tags (`pr-review/vX.Y.Z`, `dev-lead/vX.Y.Z`) are still cut as
audit/rollback targets, and **tag-protection rules with a dedicated actor/token + protected
Environment** restrict who can move a channel tag (see §5.1).

**Recommendation:** Option C — *Versioned releases + concentric rings with health-gated promotion*,
delivered in two phases (Phase 1 = versioning + pin-once to `@stable`; Phase 2 = rings + automated
promotion/rollback).

---

## 2. Problem statement

### 2.1 Two compounding root causes

**Root cause A — Self-hosting circular dependency.**
`dev-lead` and `pr-review` gate changes to themselves. The agent under change is also the agent
enforcing the merge gate on the change. When the in-flight version is broken, it blocks the fix for
its own breakage. There is no independent “known-good” instance holding production duty while the new
version is validated.

**Root cause B — No version boundary (`@main` everywhere).**
Consumers and the agents' own callers all reference `…/pr-review.yml@main` and the dev-lead reusable
at floating refs. With **0 tags / 0 releases**, there is no immutable artifact to pin to, promote, or
roll back. “Latest commit on main” *is* production, everywhere, simultaneously.

These compound. A bad change is (A) able to block its own fix **and** (B) already live across the
entire fleet before anyone notices — the worst of both failure modes at once.

### 2.2 How a bad change plays out today

```
 merge to main ──► @main resolves to the new (broken) commit
        │
        ├──► .github-private's own pr-review/dev-lead duty now broken
        │        └──► fix PR can't be reviewed/approved  ──► stuck at REVIEW_REQUIRED (#463)
        │        └──► dev-lead retry loop spins every 30 min forever (#466)
        │
        └──► all consumer repos (bmad-bgreat-suite, google-app-scripts, markets, ContentTwin)
                 pick up the broken version on their next PR — no gate, no canary
```

There is no point in this flow where a known-good version is preserved and serving traffic.

### 2.3 Delivery mechanism is fragile

`.github/workflows/deploy-pr-review.yml` / `.github/workflows/force-deploy-pr-review.yml`:

- `base64` + `PUT /repos/<repo>/contents/<path>` — a **direct overwrite of the file on `main`** of
  each consumer.
- Fans out to **all four consumer repos in one matrix run**, no staggering, no health check between
  repos, no verification that the new version actually works before the next repo gets it.
- No record of *what version* each consumer is on, and no mechanism to revert other than manually
  pushing the old file back.

---

## 3. Evidence & metrics

All figures pulled from the live repo / GitHub API on 2026-06-08.

| Metric | Value | Source |
|---|---|---|
| Immutable release artifacts (tags/releases) | **0 tags, 0 releases** | `git tag`, `gh release list` |
| Consumer reference model | **`@main`** (floating) — `.github/workflows/pr-review-reusable.yml` calls `pr-review.yml@main`, coupling all callers of the reusable to the floating ref | `.github/workflows/pr-review-reusable.yml` |
| Automated “failure detected” issues filed | **48** since 2026-05-06 (~daily) | `gh issue list --label automated-report` |
| …currently still OPEN (unresolved backlog) | **20**, oldest 2026-05-28 → **11 consecutive unresolved days** | same |
| PR Review Agent — last 20 runs | **0 successes** (all `cancelled`) | `gh run list --workflow=pr-review.yml` |
| Recent run cancellation rate | **34%** (68 of last 200 runs `cancelled`) | `gh run list --limit 200` |
| Deploy blast radius | **4 consumer repos overwritten on `main` simultaneously** | `.github/workflows/deploy-pr-review.yml` |
| Self-repair churn (peak) | **123 commits / week (W19)**, 25 PRs merged on 2026-05-20 alone | `git log` |
| Open issue mix | 82 health-check · 70 dev-lead · 14 bug | `gh issue list` label counts |

**Named stuck-state incidents** (the circular dependency in production):

- **#463** — Clean PRs (green CI, 0 unresolved threads) stuck at `REVIEW_REQUIRED` forever because the
  pr-review agent never reaches its approve path; the only eligible approver is the agent itself, which
  is broken/skipping. *The fix for pr-review is blocked by pr-review.*
- **#466** — dev-lead's blocked-retry cron re-dispatches every 30 minutes **indefinitely** on a lone
  cancelled check; the retry machinery retries the *agent*, but the blocker is the *check* — nothing
  in the loop can resolve it without a human.
- **#305** — PR #131 (7 pr-review safety checks) accumulated 28 merge-conflict sentinels and was
  **closed unfixable** because the agent's own scripts were being restructured underneath it on `main`.

**Interpretation.** The daily failure-report cadence (48 issues, 20 still open) and the 0/20 PR-review
success streak are not independent bugs — they are the *expected steady-state* of a self-hosting system
with no version boundary. Each fix ships to `@main`, instantly becomes production for the agent that
must validate the *next* fix, and any regression strands the queue. We are paying for the absence of a
release strategy in continuous operational toil.

---

## 4. Success criteria

The initiative is successful when **all** of the following hold (measurable acceptance criteria):

| # | Success criterion | Measure / target |
|---|---|---|
| SC1 | A known-good version is **always referenceable** and serving production duty | A `stable` pointer (tag/release) always resolves to a version that passed health gates; production callers never reference `@main` |
| SC2 | **Circular dependency eliminated** | A deliberately-broken in-development version of pr-review/dev-lead **cannot** block its own fix PR (validated by a regression test / game-day) |
| SC3 | **Blast radius is staged**, never fleet-wide-instant | No deploy path overwrites >1 ring at a time; ring N+1 only updates after ring N is healthy |
| SC4 | **Fast, one-action rollback** | Reverting to the previous known-good version is a single action (pointer flip / revert PR) completing in **< 5 minutes**, no manual file surgery |
| SC5 | **New versions validated before production** | Every promotion to `stable` is preceded by ring-0 (`.github-private`) health validation over a defined soak window |
| SC6 | **Operational toil falls** | Automated failure-report issue rate and the open backlog trend **down** (target: open `automated-report` backlog < 5, from 20; cancellation rate < 10%, from 34%) over the 60 days after rollout |
| SC7 | **Innovation velocity preserved or improved** | Time-to-merge for an agent change does not regress; developers can ship to `next` continuously without waiting on a full fleet rollout |
| SC8 | **Every consumer's version is known** | A single command/report shows which version each consumer + each ring is pinned to |

SC2 and SC4 are the **must-haves** (they directly neutralize the two root causes). SC6/SC7 are the
outcome metrics we track post-launch.

---

## 5. Industry patterns, mapped to GitHub-native primitives

Because the constraint is **GitHub-native only**, each classic pattern is translated to the primitives
we actually have (tags/releases, `@ref` pinning in `uses:`, Environments + required reviewers, matrix
staging, branch protection).

| Pattern | What it gives us | GitHub-native realization | Fit here |
|---|---|---|---|
| **Versioning** (semver / immutable refs) | A thing to pin, promote, roll back to | Immutable release tags (`pr-review/vX.Y.Z`) as audit/rollback targets, **plus moving channel tags** (`stable`/`next`) that callers pin to | **Foundational — required by all others** |
| **Blue/Green** | Two complete environments; flip traffic; instant rollback | Two **moving channel tags** — `stable` (blue) and `next` (green); “flip” = move the `stable` tag centrally (callers stay pinned to `@stable`, never edited) | **Strong** — tag move = the rollback story, zero caller churn |
| **Canary** | Small % exposure before full rollout | Ring 0 = `.github-private` self-host runs `next`; if healthy, promote | **Strong** — self-host is a natural canary |
| **Concentric rings** | Progressive exposure by blast radius | Ring 0 self-host → Ring 1 low-traffic consumer → Ring 2 remaining consumers; each ring pins its own ref, promoted in order | **Strong — the core of the recommendation** |
| **Progressive delivery / health-gated promotion** | Automated “advance only if healthy” | A health-gate job reads ring-N run success/cancellation metrics; promotes the pinned ref for ring N+1 via PR/pointer move only on green | **Strong** |
| **A/B testing** | Compare two variants on live traffic for quality | Possible (route some PRs to `next`, some to `stable`, compare review quality), but adds routing complexity | **Weak/optional** — defer; review “quality” is hard to measure objectively |
| **Feature flags** | Decouple deploy from release; kill-switch | Env-var/labels already used (`dev-lead:hands-off`, model flags); complements rings for sub-version toggles | **Complementary** — keep using, not a substitute |

**Key insight:** in a self-hosting setup, *versioning + rings + a stable pointer* together produce the
blue/green rollback story **and** break the circular dependency — because production review/dev duty
runs the pinned `stable` version, fully independent of whatever broken thing is sitting on `main`/`next`.

> **SC2 in this repo, enforced continuously (#1624).** `.github-private` sits in ring `next`, but its own
> dev/merge duty stub `dev-lead.yml` pins `@dev-lead/v1-stable` — the deliberate SC2 exception, so a broken
> `next` cannot block its own fix. `pinned-version-report` flags this as a ⚠️ ring mismatch; that flag and
> the stable pin are reconciled (correct from the ring view and the SC2 view respectively) — see
> [`docs/release/versioning.md`](../release/versioning.md) "Production self-review/dev duty stays pinned to
> `stable`". The property is guarded by `tests/test_sc2_self_review_channel.bats`, which parses the stub's
> channel tier and fails on any non-`stable` pin, so this SC2 half is asserted continuously rather than only
> demonstrated in the #503 game-day.

### 5.1 How version selection works without per-caller churn (moving channel tags)

A natural instinct is to point each caller at an org/repo **Variable** (`uses: …@${{ vars.PR_REVIEW_VERSION }}`)
so a single setting controls everyone. **GitHub does not support this:** `uses:` refs must be static
literals — they resolve when the workflow graph is parsed, before `vars`/`env`/`inputs` contexts
exist. (Confirmed: there are zero expression-based `uses:` refs in the repo, because it is not
permitted.)

The GitHub-native way to get the same "one knob, no caller edits" outcome is a **moving channel tag**:

- Every caller pins **once** to a per-agent floating channel tag and is then never touched again:
  ```yaml
  # pr-review caller — pins to pr-review's own channel tag
  uses: petry-projects/.github-private/.github/workflows/pr-review-reusable.yml@pr-review/stable
  # dev-lead caller — pins to dev-lead's own channel tag
  uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/stable
  ```
- Promotion / rollback is a single **central** operation in `.github-private`, performed only by the
  gated promotion workflow. Using per-agent channel names means each agent advances independently:
  ```bash
  # pr-review: promote / roll back (does NOT move dev-lead/stable)
  git tag -f pr-review/stable pr-review/v1.4.0 && git push -f origin pr-review/stable   # promote
  git tag -f pr-review/stable pr-review/v1.3.0 && git push -f origin pr-review/stable   # roll back (<5 min)
  # dev-lead: promote / roll back (independent of pr-review)
  git tag -f dev-lead/stable dev-lead/v1.4.0 && git push -f origin dev-lead/stable      # promote
  ```
- Rings use per-agent channel tags (`@pr-review/stable`, `@pr-review/next`, `@pr-review/ring1`;
  `@dev-lead/stable`, `@dev-lead/next`, etc.); a ring advances when the promotion workflow moves
  *its* tag — callers are unaffected.

**This is the same model as `actions/checkout@v4`** (a major tag GitHub moves across patch releases).

**Trade-off — mutable refs vs. the SHA-pin standard.** A moving `@stable` tag is intentionally
*mutable*, which is in tension with `AGENTS.md`'s "SHA-pin actions" rule. That rule targets
**third-party** actions (supply-chain risk you don't control); these are **first-party** workflows in
a repo you own. We accept the mutability as a **scoped, documented exception**, mitigated by:
(a) cutting immutable per-agent release tags (`pr-review/vX.Y.Z`, `dev-lead/vX.Y.Z`) as the real
audit/rollback targets a channel tag points *at* — these must be **separately protected against
deletion and force-push** (e.g., via a ruleset pattern `*/v*`) so that SC1/SC4 hold even if channel
moves are permitted: if `pr-review/v1.3.0` can be force-pushed, `pr-review/stable` pointing at it
no longer guarantees a known-good SHA;
(b) **tag-protection rules with a dedicated service actor and required-reviewer Environment** —
GitHub rulesets grant bypass to *actors* (roles, teams, users, deploy keys, or GitHub Apps), not to
a specific workflow file; without a narrowly permitted, dedicated identity (e.g., a GitHub App
installation token used exclusively by the promotion workflow) combined with a required-reviewer
Environment, any other `contents: write` workflow in this repo could also move a channel tag; and
(c) every move being a reviewed, logged promotion run.

> **Optional extension — a true Variable knob.** Where a consumer must *self-select* a ring without a
> central tag move, a caller can instead be a thin dispatcher that `actions/checkout`s the engine at
> `ref: ${{ vars.PR_REVIEW_REF || 'stable' }}` and runs the scripts directly (repo Variable overrides
> org Variable). This trades away the native `workflow_call` model and is **not** part of the
> recommended baseline — listed only as a fallback for per-repo self-service overrides.

### 5.2 Major-scoped channels: breaking changes are opt-in (epic #657)

The channel model in [§5.1](#51-how-version-selection-works-without-per-caller-churn-moving-channel-tags)
gives one moving tag per tier (`<agent>/{next,ring0,ring1,stable}`). That is correct for
backward-compatible releases, but it has a sharp edge for **breaking** changes: because a promotion is a
central tag move and callers never re-pin, advancing a major to `stable` would silently reach every
`stable` consumer — the exact "instant fleet-wide" exposure this initiative exists to prevent. A breaking
change is precisely the case where the consumer, not the release automation, must decide when to adopt.

**Decision (Option 1 of #657, 2026-07-13): scope each channel by major.** A breaking (major) agent change
gets its own channel line; a consumer opts in by re-pinning to the new major. It cannot silently reach a
`stable` consumer that has not opted in.

**Channel tag scheme.** Channel tags become `<agent>/v<MAJOR>-<tier>` where `tier ∈ {next, ring0, ring1,
stable}` for agents that support the full four-tier progression — currently `dev-lead` only. Some agents
support a subset: `pr-review` is stable-only and does not have `next`, `ring0`, or `ring1` channels.
The immutable `<agent>/vX.Y.Z` release tags are **unchanged**: they remain the per-release audit trail
and rollback anchors a channel points *at*. Only the moving channel tags gain the `v<MAJOR>-` prefix.

**The major a consumer pins is its opt-in.** A consumer pins `@<agent>/v<M>-<tier>`, where the available
tiers depend on the agent's support matrix:
- `dev-lead` supports: `v<M>-{next, ring0, ring1, stable}` (e.g. `@dev-lead/v1-stable`, `@dev-lead/v1-next`).
- `pr-review` supports: `v<M>-stable` only (e.g. `@pr-review/v1-stable`); consumers cannot select higher tiers
  and should pin to the major's stable channel. For `pr-review`, all consumers receive the same `stable` release.

A new v2 line for `dev-lead` soaks **independently** through `v2-{next → ring0 → ring1 → stable}` via the
same staged canary/ring rollout used for any release (see the ring model in
[`docs/release/versioning.md`](../release/versioning.md#ring-channels-live-for-dev-lead) and the staged
rollout runbook [`§2c`](../release/runbook.md#2c-staged-canary--ring-rollout)). Reaching `v2-stable`
**never touches a `v1-stable` consumer** — that consumer keeps receiving v1 patches on `v1-stable` until
it deliberately re-pins its caller to `@dev-lead/v2-stable`. The major bump is thus a consumer-controlled
adoption, not a push.

**Drift semantics.** For a given consumer, the expected ref is
`<agent>/v<consumer's-current-major>-<tier-for-that-repo>` (the tier is determined by the repo's ring
membership; the major is determined by what the consumer has opted into):

- **Wrong tier within your major is drift.** A `ring1` consumer pinned to `@<agent>/v1-stable` (or
  `@<agent>/v1-next`) instead of its assigned `@<agent>/v1-ring1` is misconfigured — flag it.
- **Still on an older major is NOT drift.** A consumer on `@<agent>/v1-stable` while `@<agent>/v2` exists
  is in a legitimate *not-yet-opted-in* state, not a misconfiguration. A drift audit must treat "older
  major, but the correct tier for that major" as compliant, or every not-yet-migrated consumer would
  false-positive the moment a major is cut.

**Migration to the new scheme (forward-ref to F5).** The live bare-tier channels remain valid during the
transition, but do **not** automatically track new majors. Each agent's existing `<agent>/<tier>` channel
maps **once** to `<agent>/v<currentMajor>-<tier>`, where `currentMajor` is the major version of the
release that the specific channel currently points to at migration time (e.g. if `dev-lead/stable` points
to `dev-lead/v1.7.2` on migration day, then `dev-lead/stable` is mapped to track `dev-lead/v1-stable`
exclusively — it remains pinned to the v1 line and will not follow a later v2 release). Each bare channel
thus **remains pinned to its pre-migration major** until consumers explicitly re-pin to the new major's
channel. The bare-tier channels are **retired only after** all consumers have moved to the `v<major>-<tier>`
pins. The audit/drift + live-tag migration + consumer re-pins are delivered later in the epic (phase F5);
this section records the target model that F5 realizes.

---

## 6. Options analysis

Five options, from “do nothing” to “full blue/green + A/B,” scored against the success criteria.

### Option A — Status quo / harden in place (baseline)
Keep `@main` everywhere; continue fixing individual stuck-state bugs (#463, #466) as they occur.

- **Pros:** No new machinery; each fix is small.
- **Cons:** Does **not** address either root cause. The circular dependency and instant-fleet-wide
  exposure remain; we keep paying the daily-failure toil. This is the trajectory the metrics already
  measure.
- **Verdict:** Rejected — it's the current failing baseline.

### Option B — Versioned releases + pin-once to a `stable` channel tag (minimal)
Introduce immutable release tags (`vX.Y.Z`) for the reusable workflows **and** a moving `stable`
channel tag pointing at the current known-good release. Pin every consumer caller **and**
`.github-private`'s own production callers **once** to `@stable` (off `@main`). Development happens on
`main`; releases are cut deliberately and promoted by moving the `stable` tag — **callers are never
re-edited** (see §5.1).

- **Pros:** Establishes the missing version boundary (Root cause B). A bad `main` no longer auto-ships.
  Rollback = move `stable` back to the prior tag (one central op, <5 min). **No per-caller churn.**
  Low effort, pure GitHub-native.
- **Cons:** Manual promotion (no rings/automation yet). Doesn't *by itself* guarantee ring-0 validation
  before production, but it makes SC1/SC4 achievable. Partial fix for the circular dependency
  (production runs `@stable` while `main`/`next` is broken — *as long as* self-review duty is pinned to
  `@stable` too).
- **Verdict:** **Necessary foundation.** Adopt as **Phase 1**.

### Option C — Versioned releases + concentric rings + health-gated promotion *(RECOMMENDED)*
Build on B. Add a `next` channel tag (green) alongside `stable` (blue), plus per-ring channel tags.
Ring 0 = `.github-private` self-host tracks `next`; Ring 1 = one low-traffic consumer; Ring 2 =
remaining consumers — each caller pinned **once** to its ring's channel tag, which the promotion
workflow moves forward in order, gated by an automated health check that reads the prior ring's
run-success metrics. Rollback = move the channel tag back (one central action, no caller edits).

- **Pros:** Addresses **both** root causes. Production duty always on pinned `stable` ⇒ circular
  dependency broken (SC2). Blast radius staged ring-by-ring (SC3). One-action rollback via pointer
  flip (SC4). Ring-0 soak before any consumer sees a version (SC5). Innovation continues on `next`
  without risking production (SC7). All GitHub-native; no new repos.
- **Cons:** More moving parts than B (promotion workflow, health gate, pointer convention). Requires a
  defined health metric and soak window. Ring-0-as-canary means self-host *does* see new versions first
  — acceptable per the confirmed dogfood-first decision, mitigated by the `stable` pointer protecting
  the *production* self-review duty even while `next` is exercised.
- **Verdict:** **Recommended.** Phase 2 on top of B.

### Option D — Full blue/green with parallel live stacks + A/B quality routing
Run two complete parallel agent stacks; route a fraction of real PRs to each; compare review quality
(A/B) before promoting.

- **Pros:** Maximum safety and data on quality regressions.
- **Cons:** Heavy: needs traffic routing, dual secrets/identities, and an objective review-quality
  metric we don't have. Over-engineered for a solo-maintained org; high ongoing overhead (SC against
  it). Most of the safety benefit is already delivered by C.
- **Verdict:** Rejected for now; revisit A/B only if review-quality regressions become a measured
  problem.

### Option E — Adopt GitHub Merge Queue + environments as the gate (adjacent)
Lean on Merge Queue / Environments rather than versioned rings.

- **Pros:** Native, reduces some concurrency thrash (the 34% cancellation rate is partly concurrency).
- **Cons:** Solves *integration* ordering, not the **version boundary** or the self-hosting circular
  dependency — a merged-via-queue change is still instantly `@main`-live. Complementary, not a
  substitute. (Note: already under separate discussion, project item #358.)
- **Verdict:** Complementary — fold concurrency hardening in as a supporting task, not the strategy.

### 6.1 Scoring matrix

Scale: ✅ strong · 🟡 partial · ❌ none. (Effort/overhead: lower = better.)

| Criterion | A: Status quo | B: Versioning | **C: Rings (rec.)** | D: Blue/green + A/B |
|---|:--:|:--:|:--:|:--:|
| SC1 Known-good always referenceable | ❌ | ✅ | ✅ | ✅ |
| SC2 Circular dependency eliminated | ❌ | 🟡 | ✅ | ✅ |
| SC3 Staged blast radius | ❌ | 🟡 | ✅ | ✅ |
| SC4 One-action rollback (<5 min) | ❌ | ✅ | ✅ | ✅ |
| SC5 Validate before production | ❌ | 🟡 | ✅ | ✅ |
| SC6 Operational toil falls | ❌ | 🟡 | ✅ | 🟡 |
| SC7 Innovation velocity | 🟡 | 🟡 | ✅ | 🟡 |
| SC8 Every consumer's version is known | ❌ | 🟡 | ✅ | ✅ |
| Implementation effort | — | Low | **Medium** | High |
| Ongoing overhead | High (toil) | Low | **Low–Med** | High |
| Fits GitHub-native + solo maintainer | ✅ | ✅ | ✅ | ❌ |
| **Overall** | **Reject** | **Phase 1** | **✅ Recommend** | **Reject (defer A/B)** |

---

## 7. Recommended approach (Option C, phased)

### Phase 1 — Establish the version boundary *(unblocks SC1, SC4; partial SC2)*
1. Define a versioning scheme for the reusable workflows (per-agent semver tags, e.g.
   `pr-review/vMAJOR.MINOR.PATCH`, `dev-lead/vX.Y.Z`, plus the scripts they depend on).
2. **Identify known-green SHAs before cutting any channel tag.** §3 records 0 successes in the last
   20 `pr-review.yml` runs; tagging the current broken tip as `stable` would preserve the broken
   production agent rather than create a rollback boundary. For each agent run:
   ```bash
   gh run list --workflow=pr-review.yml --status=success --limit=1 --json headSha
   gh run list --workflow=dev-lead.yml   --status=success --limit=1 --json headSha
   ```
   If the most recent green SHA is on an older commit, cut the first **per-agent** immutable release
   tags (`pr-review/v1.0.0`, `dev-lead/v1.0.0`) from *those* commits (not from `main`), then create
   per-agent moving channel tags (`pr-review/stable`, `dev-lead/stable`) pointing at them. Per-agent
   channel names are required so that promoting a `pr-review` release does not inadvertently advance
   `dev-lead/stable`, and each agent retains its own independent health gate and promotion history.
3. **Create default-branch thin-caller dispatcher files** and repoint all callers to per-agent
   channel tags. GitHub evaluates event-triggered workflows (`pull_request`, `check_suite`, etc.)
   **only from the default branch**; a `@pr-review/stable` tag on the reusable has no effect on
   which code runs when events fire unless the default-branch file itself delegates to the reusable.
   Currently `.github/workflows/pr-review.yml` and `.github/workflows/dev-lead.yml` own their event
   triggers inline — they must be replaced with thin callers on `main`:
   ```yaml
   # .github/workflows/pr-review.yml (thin caller, checked in on default branch)
   on: [pull_request, ...]
   jobs:
     pr-review:
       uses: petry-projects/.github-private/.github/workflows/pr-review-reusable.yml@pr-review/stable
   ```
   Without this step, a merge to `main` still changes the self-review/dev-duty workflow logic
   immediately, and SC2 is not achieved. Consumer repos that already use the reusable need only
   their `@main` ref updated to `@pr-review/stable`. After this step, callers are never re-pinned
   again — promotion is a central tag move.
4. Close the **script/prompt checkout boundary** for **both** reusable workflows:
   - **`dev-lead-reusable.yml`**: change the explicit `ref: main` on the `.github-private` checkout
     step (currently lines 94–103) to a required workflow input that callers pass alongside their
     `@dev-lead/stable` pin.
   - **`pr-review-reusable.yml`**: add an equivalent versioned `actions/checkout` step that checks
     out `.github-private` at the caller-supplied `ref` input, so `verify-auth-scopes.sh`,
     `list-prs.sh`, and `review-batch.sh` are sourced from the tagged release. For reusable
     workflows the `github` context is the *caller's* context; without this fix, an
     `@pr-review/stable` called workflow still executes scripts from the caller/default-branch
     checkout rather than from the tagged `.github-private` release.
   Without both fixes, the version boundary covers the workflow files but not the scripts they
   execute.
5. Add **tag-protection with a dedicated actor, protected Environment, and release-tag
   immutability**:
   - Create a dedicated GitHub App (or narrowly-scoped PAT) used exclusively by the promotion
     workflow; grant ruleset bypass to *this identity only* — not to the GitHub Actions app or any
     shared PAT that other `contents: write` workflows already use.
   - Add a required-reviewer **Environment** (e.g., `promote-stable`) that the promotion workflow
     runs in, so the approval gate is enforced before any tag move executes.
   - Add a **separate ruleset pattern** covering the immutable release tags (e.g., `*/v*`,
     `pr-review/v*`, `dev-lead/v*`) to prevent deletion or force-push — required for SC1/SC4
     guarantees (see §5.1).
   - Document the release-cut + promote + rollback runbook, including the per-agent channel naming
     convention.

After Phase 1: a broken `main` no longer auto-ships; both the workflow file *and* its scripts are
versioned together; promotion/rollback = move the per-agent channel tag centrally (no caller edits);
each agent has an independent promotion path and health gate.

### Phase 2 — Concentric rings + health-gated promotion *(completes SC2, SC3, SC5, SC8)*
6. Add per-agent **`next`** channel tags (green, candidate) alongside `stable` (e.g.,
   `pr-review/next`, `dev-lead/next`), plus per-agent per-ring channel tags
   (`@pr-review/ring1`, `@dev-lead/ring1`, …) so each agent/ring combination advances
   independently by a central tag move.
7. Define the rings:
   - **Ring 0** — `.github-private` self-host tracks `next` (dogfood/canary).
   - **Ring 1** — one low-traffic consumer.
   - **Ring 2** — remaining consumers.
   - **Production self-review/dev duty stays pinned to `stable`** even in ring 0 — this is what breaks
     the circular dependency: the agent validating fixes is never the broken candidate.
8. Replace the `PUT /contents` clobber deploy with a **versioned, ring-staged promotion** workflow.
   Promotion mechanism per ring:
   - **Ring 0** tracks the `next` moving tag directly — when `next` is advanced (moved to a new
     SHA/tag), ring 0 picks it up automatically via the moving pointer.
   - **Ring 1 and Ring 2** also use **per-agent moving ring channel tags**
     (`@pr-review/ring1`, `@pr-review/ring2`, `@dev-lead/ring1`, etc.) — the same model as the
     per-agent `stable`/`next` tags. Each ring's callers pin *once* to their agent's ring tag; the
     health-gate workflow advances a ring by moving its channel tag forward. This is required to
     honour SC4: if rings instead used explicit SHA/tag pins updated by individual bump PRs, rolling
     back after a promotion PR merged would require a separate revert PR per consumer — not one action.
   Ring N+1 advances only when an automated **health gate** confirms ring N is healthy
   (run-success rate, cancellation rate, no new failure-report issues over a soak window).
9. Implement **one-action rollback**: move the relevant per-agent channel tag
   (`pr-review/stable`, `pr-review/ring1`, etc.) back to the prior release tag — the same central
   pointer-flip for every ring, completing in < 5 min with no per-consumer edits required.
10. Add **per-version observability**: a report showing each ring's/consumer's pinned version and the
    health metrics gating promotion (SC8).
11. **Game-day / regression test for SC2:** deliberately ship a broken `pr-review/next`, prove the
    fix PR still merges (because production duty is on `pr-review/stable`, independently).

### What we explicitly defer
- A/B quality routing (Option D) — until review-quality regressions are a measured problem.
- Extending the model to utility workflows — after the agentic pattern is proven.

---

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Ring-0 = self-host means the source repo sees new versions first | Production self-review/dev duty stays pinned to `stable`; only the `next` lane runs the candidate. Confirmed dogfood-first trade-off. |
| Pinning to versions adds friction / staleness (consumers lag) | Callers pin **once** to `@stable`; promotion is a central tag move, so consumers never lag behind a manual re-pin and `next` keeps innovation continuous (§5.1). |
| Moving channel tags are mutable (vs. the SHA-pin standard) | Scoped, documented exception for **first-party** workflows: immutable per-agent release tags (`pr-review/vX.Y.Z`, `dev-lead/vX.Y.Z`) are the real targets, protected separately against deletion/force-push; **tag-protection with a dedicated actor/token + required-reviewer Environment** limits channel-tag moves (tag-name rules alone are insufficient — bypass is granted to actors, not workflow files); every move is reviewed + logged (§5.1). |
| Health gate gives false-green and promotes a bad version | Define a soak window + multiple signals (success rate, cancellation rate, failure-report issue creation); keep one-action rollback as the backstop. |
| “Two systems” increases maintenance | Phase 1 is intentionally minimal; Phase 2 automation pays for itself by eliminating daily toil (SC6). |
| Tag/release proliferation | Per-agent semver + a documented retention/runbook; floating per-agent channel tags (`pr-review/stable`, `dev-lead/stable`, `pr-review/next`, etc.) hide the churn from consumers. |
| Reusable scripts (`dev-lead-*.sh`, `verify-auth-scopes.sh`, `list-prs.sh`, `review-batch.sh`) are executed from the caller/default-branch checkout; a pinned workflow file still runs whatever scripts `main` holds | Pass the release ref as a required workflow input for **both** `dev-lead-reusable.yml` and `pr-review-reusable.yml` so script checkouts use the versioned ref (Phase 1, step 4); evaluate migrating to composite actions (which expose `github.action_ref`) as a Phase 2 follow-on. |

---

## 9. Appendix

### 9.1 Glossary
- **Channel pointer (`pr-review/stable`, `dev-lead/stable`, `pr-review/next`, etc.)** — a per-agent moving tag that consumers/rings reference; promotion = moving it. Per-agent naming ensures each agent advances independently.
- **Ring** — a cohort of consumers grouped by blast radius; updated in sequence.
- **Health gate** — an automated check that must pass before a ring advances.
- **Soak window** — the observation period a version must run healthy in a ring before promotion.

### 9.2 Key source references
- `.github/workflows/pr-review-reusable.yml` — `uses: …/pr-review.yml@main` (the `@main` coupling). **Retired (#536)** — consumers now call `pr-review.yml@pr-review/stable` directly, no wrapper.
- `.github/workflows/deploy-pr-review.yml`, `.github/workflows/force-deploy-pr-review.yml` — `PUT /contents` clobber deploy. **Retired (#536)** once all consumers migrated to the `@pr-review/stable` reusable workflow; channel-tag promotion replaces the clobber.
- Issues #463, #466, #305 — the circular dependency in production.
- `gh run list --workflow=pr-review.yml` — 0/20 success streak.

### 9.3 Decisions confirmed for this initiative
- Scope: core agentic + delivery.
- Infra: GitHub-native only (no new repos, no external infra).
- Canary / Ring 0: `.github-private` self-host.
- Version selection: **per-agent moving channel tags** (`@pr-review/stable`, `@dev-lead/stable`,
  `@pr-review/next`, etc.) — each agent has independent promotion paths so advancing `pr-review`
  does not move `dev-lead/stable`. Callers pin once; promotion is a central tag move. (A
  `vars.`-driven dispatcher is an optional fallback only, not the baseline — see §5.1.) Mutable
  channel tags are an accepted exception (dedicated actor + protected Environment + separate
  `*/v*` ruleset for release tags) to the SHA-pin standard for these first-party workflows.

### 9.4 Decision log

Design decisions taken *after* the initial proposal, in date order. Each is load-bearing for the
implementation phases that follow it.

- **2026-07-13 — Breaking (major) agent changes use major-scoped channels (Option 1 of #657).** A major
  bump requires a deliberate consumer re-pin to opt in; it cannot silently reach `stable` consumers. See
  [§5.2](#52-major-scoped-channels-breaking-changes-are-opt-in-epic-657).
