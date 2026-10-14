# Success Metrics — Definitions & Pre-Rollout Baseline

This document is the falsifiability contract for epic
[#1402](https://github.com/petry-projects/.github-private/issues/1402). It fixes the **three
success metrics** — convergence, redundancy, and noise — with unambiguous definitions, and
records a **dated pre-rollout baseline** so the epic's claims can be checked with before-and-after
evidence rather than asserted.

It gates the timer/behaviour changes in
[#1407](https://github.com/petry-projects/.github-private/issues/1407) and
[#1408](https://github.com/petry-projects/.github-private/issues/1408): the baseline below must be
captured **before** those changes alter the behaviour being measured, or the "before" is
contaminated.

## The substantive vs. trivial-stub-sync split

The PR population is **bimodal** and averaging across it hides the effect this initiative targets:

- **Substantive PRs** — a PR that changes non-generated source: any file **outside** the verbatim
  stub/baseline set (`.github/workflows/*.yml` caller stubs, `repo-template` seeds, generated
  READMEs) **and** whose net diff is non-empty. These are the PRs the convergence/redundancy claims
  are about.
- **Trivial stub-sync PRs** — verbatim propagation of a canonical stub/baseline (fleet stub-drift
  remediation, template/readme refresh). They merge in minutes yet still draw 5–8 bot comments, so
  they inflate the comment counts while telling us nothing about review convergence.

**Every metric below is reported for the substantive population.** Where a figure is stated for all
PRs it is labelled *(all PRs)*.

---

## 1. Convergence — cycles-to-merge and time-to-converge

| Field | Definition |
|---|---|
| **What is counted** | Two numbers per merged PR: **cycles-to-merge** = the number of automated review/fix cycles (commits that triggered a re-review) between open and merge; **time-to-converge** = wall-clock from PR creation to merge. |
| **Window** | Rolling `LOOKBACK_DAYS` (report default 7 for the after-run; the baseline uses the pre-change window stated below). |
| **PR scope** | Merged **substantive** PRs. Trivial stub-sync PRs are reported separately and never averaged in. |
| **Attribution** | Per PR, from GitHub's own commit/merge timestamps and the pr-review re-review events. Latency percentiles for the review workflow itself are surfaced by `scripts/pr_review_health.sh` ("Convergence latency" — p50/p95 of run duration). |

## 2. Redundancy — workflow runs per hour and runs per PR

| Field | Definition |
|---|---|
| **What is counted** | **Runs per hour** = review-related workflow runs ÷ hours in the window; **runs per PR** = review-related workflow runs ÷ distinct PRs touched in the window. |
| **Window** | Same rolling window. Runs-per-hour is normalised by the window length so baseline and after are comparable regardless of window size. |
| **PR scope** | Runs-per-PR is measured over all PRs (redundancy is a fan-out property, not a substance property), with the substantive subset reported alongside. |
| **Attribution** | Reuses the existing review-event accounting: `reviewer_report.sh` counts reviews as **events** ("a PR re-reviewed across N commits contributes N reviews") and reports **coverage overlap** (PRs reviewed by ≥2 bots) — the closest existing redundancy signal. Cost fan-out reuses `scripts/token_report.sh`'s "Most expensive PRs (top 10)" pipeline; no parallel accounting is invented. |

## 3. Noise — no-action agent comments per PR

| Field | Definition |
|---|---|
| **What is counted** | **No-action agent comments** as a count, as a **share** of all agent comments, and **per PR**. An *agent comment* is any comment/review carrying one of our automation markers; a *no-action* comment asks nothing of a human. Full definition and the marker/body list live in [`docs/reviewer-report.md` → Agent comment noise](./reviewer-report.md#agent-comment-noise-our-own-automation). |
| **Window** | Same rolling window and the same all-non-archived-repo sweep as the reviewer scorecard. |
| **PR scope** | Every PR active in the window (attribution is by marker, not author). |
| **Implementation** | Net-new — it did **not** exist before #1411. Pure classifier `scripts/lib/comment-noise.sh`, unit-tested in `tests/comment_noise.bats`, applied inside `reviewer_report.sh`'s existing collection pass so baseline and after share one code path. |

---

## Pre-rollout baseline snapshot

- **Captured (dated):** 2026-08-02
- **Pre-change window:** 2026-07-26T00:00:00Z – 2026-08-02T00:00:00Z (7-day rolling window, over all non-archived `petry-projects` repos)
- **Repository scope:** all non-archived repos in the `petry-projects` org (count logged by `reviewer_report.sh` at each run start)
- **PR cohorts:** substantive PRs = non-generated source changed, non-draft, merged in window; trivial stub-sync PRs = verbatim canonical-stub propagation (reported separately, never averaged into substantive figures)
- **Sample:** the known-working figures below are the measured pre-change references cited on epic
  #1402; they are reproduced (or corrected, with the discrepancy explained) by the same code path
  that produces every after-run — `scripts/reviewer_report.sh` (noise, redundancy overlap),
  `scripts/pr_review_health.sh` (convergence latency), and `scripts/token_report.sh` (cost fan-out).

| Metric | Baseline (substantive) | Baseline (all PRs) | Source of the after-measurement |
|---|---|---:|---|
| Convergence — time-to-converge | **~20–48 h** (p50 / p95 range) | — | `pr_review_health.sh` "Convergence latency" (p50/p95) |
| Convergence — cycles-to-merge | **~7–13 commits** per merged substantive PR | trivial stub-sync merges in minutes | pr-review re-review events |
| Redundancy — workflow runs/hr | — | **~52 runs/hr** (7-day window, all-PRs scope) | `pr_review_health.sh` run telemetry / `reviewer_report.sh` |
| Redundancy — coverage overlap | — | PRs reviewed by ≥2 bots (see scorecard) | `reviewer_report.sh` "Coverage overlap" |
| Noise — no-action comment share | — | **~12%** (all-comments historical estimate — phrase-scan over all bots, **not** a first-party marker count; see denominator reconciliation note and Correction 2026-08-02) | `reviewer_report.sh` "Agent comment noise" |
| Noise — pr-review cancelled-run share | — | **~49%** cancelled (2026-08-02 3-hour observation; see below) | `pr_review_health.sh` "Run-outcome mix by triggering event" |

### pr-review run-outcome mix — 2026-08-02 starting observation (#1422)

The starting observation recorded by issue #1422, over a **3-hour window on 2026-08-02** (the
epic #1402 PR traffic on `pr-review-trigger.yml`). This is the dated "before" the SHA-keyed
concurrency change (#1422) and the trigger-narrowing coupled to #1408 are measured against. The
after-run source is the `scripts/pr_review_health.sh` **"Run-outcome mix by triggering event"**
table (pure aggregation in `scripts/lib/pr-review-outcomes.sh`), which makes this a tracked number
on the existing daily report — no new cron.

| Conclusion | Count |
|---|---:|
| cancelled | **49** |
| success | 34 |
| skipped | 17 |

Cancellation rate ≈ **49%** (49 / 100), roughly the magnitude of the ~34% in-flight cancel rate
that issue #534 addressed. Cancellations by triggering event in the same window:

| Event | Cancelled |
|---|---:|
| `pull_request_review` | 21 |
| `repository_dispatch` | 17 |
| `pull_request` | 5 |
| `check_suite` | 5 |
| `workflow_dispatch` | 1 |

Mechanism and the coverage guarantee behind the fix:
[`docs/pr-review-agent/concurrency-and-coverage.md`](./pr-review-agent/concurrency-and-coverage.md).

### Noise metric — raw measurement details

Because the classifier is net-new (#1411), no deterministic pre-change count existed before this
baseline was captured. The ~12% figure is an **all-comments historical estimate** (phrase-scan over
all bots, third-party included) — it is **not** a first-party marker count and is not the
first-party baseline. The first scheduled `reviewer-report.yml` run **establishes** the first-party
baseline via `cn_render_noise_section`:

| Field | Value | Note |
|---|---|---|
| Agent comments (total) | *established on first run* | all marker-bearing comments/reviews in the 7-day window (first-party only — see denominator note below) |
| No-action comments | *established on first run* | share of first-party agent comments (the all-comments historical estimate was ~12%; first-party value is expected to differ — see denominator note) |
| Active PRs (window) | *established on first run* | distinct `kind:"pr"` records in the JSONL collection |
| Affected PRs (≥1 no-action) | *established on first run* | distinct PRs with at least one no-action agent comment |
| No-action comments per PR | *established on first run* | no-action count ÷ PRs with any agent comment |

Any divergence between the first-party value and the ~12% all-comments estimate is the **expected
population difference** (narrower denominator) — not a measurement correction. A genuine
measurement correction is one the population difference cannot explain (e.g., the first-party
classifier disagreeing with a hand-count of first-party markers on the same PRs). Record only those
as dated appends here; never treat the first-party-vs-all-comments gap itself as a change in noise.

### Reconciliation notes

- **Convergence** and **redundancy** baselines are quoted as ranges because the pre-change data is
  bimodal (see the split above); the substantive band (~20–48 h, ~7–13 commits) is the target of the
  initiative, while trivial stub-sync PRs sit far below it and are reported, not averaged in.
- **Noise ~12%** is an all-comments historical estimate (phrase-scanned over all bots, third-party
  included) — **not** a first-party marker count. The first scheduled `reviewer-report.yml` run
  **establishes** the first-party baseline via `cn_render_noise_section`. Divergence from ~12% on
  that first run is the expected consequence of the narrower denominator — not a measurement
  correction. Only within-denominator anomalies (e.g., classifier disagreeing with a hand-count of
  the same PRs at a fixed first-party denominator) should be recorded as dated appends here.
- **Denominator scope (first-party only):** The `cn_render_noise_section` metric counts only
  first-party agent comments — bodies that carry one of our automation markers (`<!-- pr-review-agent
  …-->`, `<!-- dev-lead …-->`, etc.). Third-party reviewer bots (Codex, Qodo, SonarCloud, etc.) do
  not emit these markers and are classified as `non-agent`; they are already measured separately via
  the reviewer scorecard. **[Corrected 2026-08-02 — the following sentence is factually wrong and is
  retained here, not silently deleted, per this doc's dated-correction convention; see the
  *Correction (2026-08-02)* section at the end of this document, which supersedes it.]** ~~The AC #4
  ~12% figure cited in issue #1411 was also measured over first-party markers only (it pre-dates the
  classifier and was an estimate, not a live all-comments count), so the denominators are
  consistent.~~ Any future comparison against an all-comments denominator should be labelled
  explicitly to avoid confusion.
- **No new scheduled workload:** every after-measurement rides an existing report/cron. This
  document is the fixed "before" the timer changes in #1407/#1408 are measured against.

---

### Correction (2026-08-02) — denominator scope of the ~12% noise estimate

An earlier version of the denominator-scope note above (landed in #1414) concluded that the AC #4
~12% figure "was also measured over first-party markers only … so the denominators are consistent."
**That claim is wrong.** The original sentence is struck in place above rather than silently rewritten;
this dated section corrects it (raised as finding F3 on PR #1414, tracked in #1419).

- **Actual basis of the ~12% figure (AC #1).** The ~12% figure was derived over **all** PR comments in
  a sampled window — third-party reviewer bots included — and classified by a phrase scan
  ("no action", "no issues", "LGTM", "no blocking", "advisory") across every comment, **not** over a
  marker-bearing subset. Provenance: a 10-PR sample (#1355, #1366, #1372, #1359, #1351, #1357, #1356,
  #1347, #1346, #1345) with **180 comment bodies (issue + inline review comments; the
  phrase-scan denominator)** and **est. no-action/advisory = 21** → 21/180 ≈ 12%. In that same
  sample **all 254 distinct review activities (comment bodies + review-submission events) were
  machine-authored and 0 were human** — a figure only meaningful because third-party bots
  (`codeant-ai`, `coderabbitai`, `qodo-code-review`, `sonarqubecloud`, `chatgpt-codex-connector`,
  `gemini-code-assist`) were in scope.

- **The two populations genuinely differ (AC #2).** `cn_render_noise_section` counts only first-party,
  marker-bearing comments — a **narrower** population than the all-comments basis of the ~12% estimate.
  The denominators are therefore **not** consistent. The first measured first-party value is
  **expected to differ** from ~12%, and a difference of that kind is a **population change — not a
  regression and not an improvement** in reviewer noise.

- **Interpreting the first scheduled run (AC #3).** Read a first-party number below ~12% as the
  *expected* consequence of the narrower denominator, **not** as a noise reduction to claim. A genuine
  measurement correction is one that the population difference cannot explain — for example, the
  first-party classifier disagreeing with a hand-count of first-party markers on the same PRs, or the
  first-party share moving materially across runs at a *fixed* first-party denominator. Record only the
  latter as a dated append; never treat the first-party-vs-all-comments gap itself as a change in noise.

- **All-comments series (AC #4).** No all-comments noise series is maintained. The first-party
  no-action share is the **only** noise time-series in this document; the **reviewer scorecard**
  (`scripts/reviewer_report.sh`) is the only view that accounts for third-party reviewer bots. A reader
  must not mistake the first-party series for total reviewer noise — for that, consult the scorecard.
