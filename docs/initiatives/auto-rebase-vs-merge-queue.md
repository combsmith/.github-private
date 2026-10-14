# Initiative: Auto-rebase Fan-out Reduction — Decision Record & Merge Queue Go/No-Go Gate

**Status:** Decision record — free mitigation validated (≥50% metric met) **and deployed org-wide &
verified live 2026-06-26** (see §2 update); Merge Queue go/no-go **deferred to a human** (epic
[#736](https://github.com/petry-projects/.github-private/issues/736) open question).

**2026-07-03 update:** the developer-facing *delay* was measured directly (not just fan-out volume) — approval→merge
latency is **~7 min median**, per-cycle CI is **~50 s**, and serialization uses **<0.5%** of capacity, so
the current state adds negligible delay and the gate reading now leans **strongly no-go**. See §5.
**Author:** dev-lead / Claude Code
**Date:** 2026-06-21
**Scope (confirmed):** Records the measured before/after impact of the **review-ready auto-rebase
fan-out restriction** (the free, plan-independent mitigation from epic [#736](https://github.com/petry-projects/.github-private/issues/736),
Story [#738](https://github.com/petry-projects/.github-private/issues/738)) and the now-measurable
agentic-conflict-resolution rate (Story [#737](https://github.com/petry-projects/.github-private/issues/737)).
Defines the GitHub **Merge Queue** go/no-go as explicit, checkable gate conditions. Does **not** decide
the go/no-go — that remains a human call (see §4).
**Constraints (confirmed):** Docs-only. The before/after numbers are sourced from the Story 1 (#737)
observability report and the discussion [#735](https://github.com/petry-projects/.github-private/discussions/735)
manual baseline — not re-estimated here. Fan-out volume is an **estimate** (per-run behind-PR counts
live in the central reusable, not this repo); it is labelled as such throughout, consistent with the
Story 1 report's method note.

---

## 1. What was changed, and why

Branch protection's "Require branches to be up to date" serializes merges: every merge to `main` leaves
all other open PRs behind. The `Auto-rebase non-Dependabot PRs` workflow papered over that by calling
`update-branch` on **every** behind non-Dependabot PR on every push to `main` — fanning a fresh CI run
onto each. At the repo's measured throughput (~12.3 merges/day, ~14–18 concurrently-open PRs) that was
an estimated **~170–220 redundant branch-update CI runs/day** (discussion #735), the bulk of which were
re-staled by the next merge before any human looked at them.

Epic #736 split the response into two tiers:

1. **Free, plan-independent mitigation (Story #738):** stop fanning out to PRs nobody will review —
   restrict the update to a **review-ready eligibility predicate**. Landed **2026-06-15** in the central
   reusable via PR [petry-projects/.github#468](https://github.com/petry-projects/.github/pull/468)
   (issue #465). Predicate: **non-draft AND (current `APPROVED` review OR `auto-rebase:ready` label)**,
   tunable via an `eligibility` workflow input. The merge-method update (approval-safe) and the
   `<!-- auto-rebase-conflict:` sentinel → dev-lead agentic-rebase path are both preserved.
2. **Plan-gated follow-on (this record's gate, §4):** GitHub Merge Queue — evaluated **from data**, not
   speculation, and explicitly **not decided here**.

Before the plan-gated trade could even be weighed, the agentic-conflict-resolution frequency had to be
counted — and the owner could not, because the trigger is an un-indexed HTML-comment sentinel
(discussion #735). Story #737 instrumented exactly that (`scripts/auto_rebase_health.sh` +
`auto-rebase-health.yml`).

---

## 2. Measured fan-out reduction (AC #1)

The directly comparable measure is the **behind-PR multiplier** — the count of PRs the fan-out updates
per push to `main`. The auto-rebase **run count** (driven by pushes to `main`) is unchanged by the
restriction, so reducing the multiplier reduces the branch-update CI volume proportionally.

| Metric | Before (all behind non-Dependabot PRs) | After (review-ready only) | Source |
|---|---|---|---|
| Behind-PR multiplier (PRs updated per push) | 13 of 13 open non-Dependabot PRs | **3 of 7** eligible | #737 report (14-day smoke) → #738 post-change (6-day) |
| Multiplier reduction | — | **~57%** | 7 → 3 |
| Est. branch-update CI runs/day | ~170–220 (manual) · ~116 (instrumented) | proportionally **~57% lower** | #735 baseline · #737 report |
| Merge throughput | ~12.3 merges/day (peaks 16–21) | unchanged (not a target) | #735 |
| Time-to-merge | median 5h · mean 31h · p90 71h · max 629h | not re-measured in this record | #735 |

> **Fan-out is an estimate.** Per-run behind-PR counts are not logged in this repo (the `update-branch`
> calls live in the central reusable), so re-runs = auto-rebase runs × eligible-PR count. The reduction
> is reported as the **eligible-PR multiplier** drop (7 → 3 = ~57%), which the restriction controls
> directly; the absolute CI-runs/day figures carry the #735/#737 estimate caveat.

### Success-metric verdict

Epic #736's success metric: **auto-rebase-triggered branch-update CI runs drop by ≥ 50%** from the
~170–220/day baseline.

**✅ MET.** The review-ready restriction cut the behind-PR multiplier by **~57%** (7 eligible → 3),
clearing the ≥50% bar, with **no plan upgrade** and **without losing** the agentic conflict-resolution
fallback (the sentinel path is preserved — see §3).

> **Update (2026-06-26) — the gate is now actually deployed in production.** The ~57% figure above was
> computed from the eligible-PR *multiplier* (a predicate snapshot), and at the time this record was
> written the restriction was **not yet filtering anything in production**: the central reusable
> defaulted `tooling_ref` to `v1`, a tag that predates `lib/eligibility.sh` (added in #468), so every
> auto-rebase run failed to source the predicate — `petry-projects/.github`'s own runs errored outright
> while consumer repos still ran the **original unrestricted fan-out**. That latent regression was fixed
> in [petry-projects/.github#528](https://github.com/petry-projects/.github/pull/528) (2026-06-24), which
> sources the predicate from the reusable's own commit (`github.job_workflow_sha`); the
> `auto-rebase/stable` channel was then promoted org-wide. The gate is now **verified live** — e.g.
> `.github-private` PR #744 (no approval, no `auto-rebase:ready` label) went from auto-updated-every-push
> to **skipped**. Net effect on this record: the free mitigation behind the "defer Merge Queue" decision
> is now genuinely in effect, so the §4 deferral holds on **stronger** footing, not weaker.

---

## 3. Measured agentic-conflict-resolution rate (AC #2)

This is the number the owner could not previously count. It is now published by the Story #737 report
(`scripts/auto_rebase_health.sh`), which scans the un-indexed HTML-comment markers directly: conflict
sentinels (`<!-- auto-rebase-conflict:`) vs. dev-lead `rebase` terminal markers
(`intent=rebase status=…`, with the `status=applied` subset = sentinels dev-lead actually resolved &
force-pushed).

| Window | Sentinels fired | Dev-lead `rebase` responses (resolution rate) | `status=applied` (applied rate) |
|---|---|---|---|
| **Before** — #737 14-day smoke (~2026-06-01 → 06-15) | 161 (**~80 / week**) | 74 — **46%** (**~37 / week**) | 0 — **0%** |
| **After** — #738 6-day post-change (~2026-06-15 → 06-21) | ~13 (**~15 / week**) | 7 — **54%** | 2 — **15%** |

**Reading the rate.** The agentic resolver *responds* to roughly half of conflict sentinels, but the
**applied** rate is low (0% then 15%): in the 14-day window every resolved rebase terminated
`no-changes` — i.e. the agentic rebase produced no commit to force-push. That is genuine telemetry, not
a bug, and it is **load-bearing for the §4 gate**: a low real-resolution (applied) rate means relatively
little unique work would be lost by dropping the agentic path for Merge Queue. The numbers are still
small-sample (single-digit applied counts); the gate below treats the threshold as something to agree
on against a longer window, not to read off one 6-day sample.

---

## 4. Merge Queue go/no-go gate (AC #3) — conditions only, **decision deferred**

GitHub Merge Queue is the plan-gated follow-on. This record defines **when** it would be worth adopting
as explicit, checkable conditions. It does **not** make the call: the actual go/no-go is a human
billing + product decision, surfaced as the **epic #736 open question** ("is leadership willing to make
that trade?"), and is **not asserted resolved here**.

### Gate conditions (all must hold for a "go")

| # | Condition | Checkable signal | Current reading |
|---|---|---|---|
| G1 | **Plan eligibility** — Merge Queue is available on this repo's plan | Repo plan / settings expose Merge Queue | **Satisfied** — per the epic #736 owner resolution (open question #1), Merge Queue **is** available on this plan (private repo); the discussion #735 "private repo → Team/Enterprise required" concern does **not** apply here. Eligibility uncertainty is removed; the *adoption* decision stays open. |
| G2 | **Throughput sustained above the "consider Merge Queue" threshold** (≥10 merges/day) | #735 / #737 throughput | **Satisfied** — ~12.3 merges/day, peaks 16–21. |
| G3 | **Agentic-conflict-resolution value below an agreed threshold** — because Merge Queue **drops** the sentinel → dev-lead rebase path and proactive background branch updates | #737 report `status=applied` rate over a ≥4-week window vs. an agreed ceiling (e.g. applied-rebases/week the team is willing to convert to manual resolution) | **Threshold not yet agreed.** Current signal is *favourable* to a switch (applied rate 0%→15%, most rebases `no-changes`), but it is small-sample; needs a longer window and a human-set ceiling before it counts as met. |
| G4 | **The documented trade-offs are accepted by a human** | Sign-off referencing the #735 comparison table | **Open — but the case for a switch has weakened.** The §5 delay measurement (2026-07-03) shows Merge Queue would relieve a serialization bottleneck that **does not exist** (approval→merge ~7 min median, serialization <0.5% of capacity), while still costing the agentic conflict path + background updates and leaving the real latency driver (review cadence) untouched. Accepting the trade-offs remains an explicit human decision, but the data now points **no-go**. |

**Net.** G1 and G2 are satisfied; G3 is *trending* toward met but needs an agreed threshold over a
longer window; G4 is an explicit human sign-off. **No go/no-go is recorded here.** When the team is
ready, resolve the epic #736 open question against these conditions — the data to check G2 and G3 is now
produced continuously by the #737 report. **The §5 delay measurement (2026-07-03) adds a fourth piece of
evidence that the gate did not originally weigh: Merge Queue's core benefit (relieving merge-time
serialization) has no measurable value here, which pushes the human G4 call toward no-go.**

### What a "go" would mean operationally (for reference, not a decision)

- **Add** a `merge_group` CI trigger and make the merge-queue check required (the only CI change).
- **Retire or scope down** the auto-rebase fan-out (Merge Queue tests the synthetic `merge_group`, so
  per-PR branch-updates become redundant for queued PRs) — note auto-rebase and Merge Queue solve
  *adjacent* phases (keeping open PRs current vs. serializing the merge), so the team may keep a
  narrowed auto-rebase running alongside.
- **Accept** manual conflict resolution in place of the agentic sentinel path (the §3 applied rate is
  the cost estimate for this).

---

## 5. Measured developer-facing delay (2026-07-03)

§2 and §3 quantified **fan-out volume** and the **conflict-resolution rate** — how much *CI work* the
system does. Neither answered the question of whether the current state adds much delay — the metric a developer
actually feels when actively developing. This section measures that directly from live data (pulled 2026-07-03
via the GitHub API), and the answer is **no**.

Delay a developer can feel has three sources; each was measured:

| Source of potential delay | Metric | Baseline (#735, pre-mitigation) | **Now (current regime, since 2026-06-24)** |
|---|---|---|---|
| Getting re-tested **while developing** | Fan-out reach per push to `main` | 13–18 PRs updated/push | **~1 PR** (1 review-ready of 9 open non-Dependabot) |
| — | Est. branch-update CI runs/day | ~170–220 | **~6** (1 PR × ~6.4 pushes/day) |
| Waiting to merge **once ready** | Approval → merge latency (median) | not measured | **~0.12 h (~7 min)** (mean 1.6 h, p90 4.8 h) |
| — | CI cost per forced re-test (median) | not measured | **~50 s** (p90 ~1.5 min) |
| The merge being **serialized** | Serial-merge capacity used | not measured | **<0.5%** of the ~1,700 merges/day ceiling |
| Overall | Time-to-merge — median · mean · p90 · max | 5 h · 31 h · 71 h · 629 h | **2.0 h · 7.9 h · 29.8 h · 75 h** |

**Reading the numbers.**

- **Active development is no longer churned.** With the review-ready restriction live, an in-progress
  (unapproved) PR is not auto-updated on every push — the fan-out touches ~1 PR/push, not 9. "Behind"
  status does not block editing, only merging, so the rebase+retest is paid **once, at the end, after
  approval.** A typical PR sees ~2–3 head changes total before landing (sample: median 2.5, range 1–8).
- **Post-approval serialization is effectively free.** Once approved, a PR merges in **~7 min median**,
  and each forced re-test is **~50 s** of CI (this is a shell-lint repo). That is the entire "require
  branches up to date" tax.
- **Serialization is not a bottleneck.** At ~50 s CI the theoretical serial ceiling is ~1,700
  merges/day; observed throughput (6.4–7.4 merges/day) uses **under 0.5%** of it. There is vast headroom.
- **The remaining tail is review cadence, not the merge machinery.** Time-to-merge still has a tail
  (p90 ~30 h; a few PRs at 48–75 h), but since approval→merge is ~7 min, that tail is **time spent
  waiting for the first review / for the author to pick the PR back up**, not serialization or rebase
  churn. Merge Queue does nothing for review cadence.

**Bearing on the §4 gate.** Merge Queue's headline benefit is relieving merge-time serialization
pressure. The measurements show that pressure is **negligible** here, while the costs (dropping the
agentic conflict path and proactive background updates — §3, §4) are unchanged. So the delay data
strengthens the **no-go** lean on G4: the free mitigation already removed the churn that motivated the
whole question (the "~170–220 redundant CI runs/day" is now ~6), and the residual latency is a
human-review-cadence problem a merge queue cannot address.

**Method & caveats.** Live API pull on 2026-07-03. Samples: time-to-merge over the 100 most-recent
merged PRs (54 in the current regime, 46 before the 2026-06-24 cut); approval→merge latency over the 20
most-recent non-Dependabot merges (18 had an explicit `APPROVED` review, 2 were bot/auto-merged); CI
duration over 30 recent `ci.yml` runs; fan-out reach over all 10 currently-open PRs. All sampled merges
were human (`don-petry`); **0 Dependabot** PRs appeared in the window. Because the restriction had a
~10-day no-op window from the `tooling_ref: v1` tag bug (§2 update, fixed 2026-06-24), the honest
"before" comparator is the **#735 baseline column**, and both time-to-merge cohorts are effectively
"after." Fan-out and serialization figures carry the same estimate caveat as §2 (per-run behind-PR
counts are not logged in this repo).

---

## 6. References

- Epic [#736](https://github.com/petry-projects/.github-private/issues/736) — fan-out reduction +
  conflict-rate instrumentation; success metric (≥50% fan-out reduction) and the Merge Queue open
  question.
- Story [#737](https://github.com/petry-projects/.github-private/issues/737) — auto-rebase
  instrumentation (`scripts/auto_rebase_health.sh`, `.github/workflows/auto-rebase-health.yml`); source
  of the before-numbers and the conflict-resolution rate.
- Story [#738](https://github.com/petry-projects/.github-private/issues/738) — review-ready fan-out
  restriction; delivered as central PR
  [petry-projects/.github#468](https://github.com/petry-projects/.github/pull/468) (issue #465); source
  of the after-numbers.
- Discussion [#735](https://github.com/petry-projects/.github-private/discussions/735) — manual baseline
  (~170–220 redundant CI runs/day, ~12.3 merges/day, TTM mean 31h / p90 71h) and the auto-rebase vs.
  Merge Queue comparison table.
- `docs/initiatives/agentic-release-strategy.md`, `docs/initiatives/mcp-powered-review.md` —
  initiative-doc header shape.
