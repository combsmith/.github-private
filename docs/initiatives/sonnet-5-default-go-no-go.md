# Sonnet 5 default swap — human go/no-go record

Part of epic **#1095** (Sonnet 5 model swap). This is **Phase 3 / issue #1100**: promote
the Story-3 `engine.sh` chain change through the dev-lead canary rings, measure the
realized cost + quality in production, and **record the human go/no-go** on making
`claude-sonnet-5-0` the default `claude-sonnet-4-6` replacement before the intro-pricing
deadline of **2026-08-31**.

This document is the **template** that becomes the recorded recommendation + decision
once the human owner fills the evidence sections and signs the decision block. Until
those sections are complete this record does not close #1100 — the issue stays open
until a real verdict is signed. It mirrors the #845 precedent ("Record the human go/no-go
decision and fleet-wide recommendation" for the Opus 4.8 initiative). **No automation is
built here.** The go/no-go and the stable/default promotion are **human** actions
(see [Guardrail](#guardrail-human-only-promotion)).

## What is — and is not — being decided

The Story-3 change (#1098) appends `claude-sonnet-5-0` as a **non-default fallback**
*after* the `sonnet-4-6` slot in the triage and deep chains
([`scripts/engine.sh`](../../scripts/engine.sh) — `CLAUDE_TRIAGE_MODEL_CHAIN`,
`CLAUDE_DEEP_MODEL_CHAIN`). It is reachable only when the layer-1 primaries
(haiku triage / opus deep) **and** the `sonnet-4-6` fallback have both exhausted their
rate-limit buckets. It is **not** the fleet default.

So there are two distinct steps, and this record separates them:

1. **Canary-promote the fallback addition** (rides the dev-lead rings). Validates that
   adding Sonnet 5 as a tail fallback introduces no candidate-introduced regression.
2. **The default swap** — moving `claude-sonnet-5-0` ahead of `claude-sonnet-4-6` in the
   chains so it becomes the primary Sonnet tier. This is the decision this record
   authorizes (or declines), and it is a **human** action.

## Evidence

### 1. Held-out quality — non-regression gate (Story 2)

Before Sonnet 5 replaces Sonnet 4.6 in any default slot it must **match or beat**
`claude-sonnet-4-6` on the frozen held-out eval sets. The procedure and the `>=`
non-regression bar are defined in
[`docs/evals/model-ab-regression.md`](../evals/model-ab-regression.md), driven by
[`scripts/evals/model-ab.sh`](../../scripts/evals/model-ab.sh) over the
`triage` + `deep-review` holdout sets (generator pinned per arm, judge held fixed).

A regression on **either** set is a **blocking** result (comparator exit `1`), never
silently accepted; an `infra` outcome (exit `2`) means re-run, not a result. Record the
per-set candidate/incumbent scores and the verdict here:

| Holdout set | `sonnet-4-6` (incumbent) | `sonnet-5` (candidate) | `>=` non-regression | Outcome |
|-------------|--------------------------|------------------------|---------------------|---------|
| `triage`      | *fill from model-ab run* | *fill* | *pass / regression / infra* | *fill* |
| `deep-review` | *fill*                   | *fill* | *pass / regression / infra* | *fill* |

> Attach the `model-ab.sh` evidence JSON and a clean `git status --porcelain -- evals/`
> (held-out immutability) alongside this row when the decision is signed.

### 2. Realized cost delta (Story 1)

> **Update (2026-09-30, #1978 / PR #1982):** the scheduled 2026-09-01 increase to
> `$3/$15` was cancelled, so Sonnet 5's `$2/$10` launch rate is now its standard price
> (Anthropic pricing page, footnote 3). `scripts/lib/model-pricing.tsv` was corrected
> to match. The `$3/$15` standard-window figures below reflect what was announced when
> this record was written; they never took effect.

Prices are data, priced through the single source of truth
[`scripts/lib/model-pricing.tsv`](../../scripts/lib/model-pricing.tsv) via
[`scripts/lib/model-pricing.sh`](../../scripts/lib/model-pricing.sh) (`cost_usd`). The
per-MTok rates in effect:

| Rate window | Model | input | cache-read | cache-write | output |
|-------------|-------|------:|-----------:|------------:|-------:|
| incumbent          | `claude-sonnet-4-*` @ 2025-01-01 | 3.00 | 0.30 | 3.75 | 15.00 |
| **intro** (→ 2026-08-31) | `claude-sonnet-5-*` @ 2026-06-30 | **2.00** | 0.20 | 2.50 | **10.00** |
| standard (2026-09-01 →)  | `claude-sonnet-5-*` @ 2026-09-01 | 3.00 | 0.30 | 3.75 | 15.00 |

**List-priced delta under intro pricing: 33.3% lower input ($3.00 → $2.00) and 33.3%
lower output ($15.00 → $10.00)** — clears the `>=30%` target. Worked example on a
deep-tier record (10M input / 2M cache-read / 1M output): `$45.60 → $30.40`, a 33.3%
total reduction (reproduce with `cost_usd` at an intro-window date).

**After 2026-08-31 the discount lapses:** `claude-sonnet-5` reverts to `$3/$15`,
**identical** to `claude-sonnet-4-6` — a **0% cost delta**. Past the intro window the
swap is cost-neutral, so the case for switching rests entirely on quality
(the §1 non-regression evidence), not price.

**Production-realized delta.** The list-priced number above is the expected win; the
*realized* delta is measured from the fleet's existing token cost report over the
affected tier, before vs. after the candidate rides the rings. Record it here:

| Tier | Window | records | realized input cost before | after | realized reduction |
|------|--------|--------:|-----------------------------|-------|--------------------|
| deep / triage | *canary dwell window* | *fill* | *fill* | *fill* | *fill (target ≥30%)* |

> **Measurement scope — re-price, do not read tail-fallback spend.** During the canary
> dwell window `claude-sonnet-5-0` is the tail fallback (reached only after the
> layer-1 primaries **and** `claude-sonnet-4-6` exhaust their rate-limit buckets), so
> the fleet's before/after token-cost report will mostly reflect unchanged
> haiku/opus/sonnet-4-6 traffic plus rare double-throttle Sonnet 5 calls. That number
> is **not** the default-swap cost signal. Compute the realized reduction by re-pricing
> the affected `claude-sonnet-4-6` records using `cost_usd` in `model-pricing.sh` with
> the model overridden to `claude-sonnet-5-0` and an intro-window date, or by measuring
> a separate canary where `claude-sonnet-5-0` is in the primary Sonnet slot rather than
> the tail position. This is a human-owner input to the decision, not an agent output.

### 3. Canary gate status (dev-lead rings)

The Story-3 `engine.sh` change ships inside the dev-lead reusable, so promoting dev-lead
through its rings is how the change reaches production incrementally. The gate walks
`next → ring0 → ring1` under the dev-lead gate config. Authoritative knobs are in
[`release/registry.yml`](../../release/registry.yml) (this repo, source of truth for
the Release_Manager loop; `gate: { soak_window_days: 7 }`); ring-level dwell knobs in
[`standards/canary-rings.json`](https://github.com/petry-projects/.github/blob/main/standards/canary-rings.json)
in `petry-projects/.github`:

- gate soak window: **7 days** (`soak_window_days` in `release/registry.yml`)
- baseline window: **14 days**; spike cap: **3×**
- `next → ring0`: dwell **4h**, sample **min 3 / 25% / ≤15** (or documented waive)
- `ring0 → ring1`: dwell **8h**, **waive_sample**
- `ring1 → stable`: dwell **12h**, sample **min 1** (per `standards/canary-rings.json` `sample_min: 1`; not waivable without an explicit documented waiver approved by the Release_Manager)

> **Ring1 repin blocker.** The ring1 health signal is not yet active — TalkTerm and
> bmad-bgreat-suite currently pin `@dev-lead/stable`, not `@dev-lead/ring1` (see
> COORDINATION NOTE in [`release/registry.yml`](../../release/registry.yml)). The
> Release_Manager gate cannot soak `ring1 → stable` until staged repin PRs land in
> those repos. The `ring0 → ring1` row below can be filled once `petry-projects/.github`
> is on ring0 and healthy; the `ring1` row must remain *hold* until the external repin
> is complete. Do not record a ring1 pass against the 4h/8h rows above — the rollout
> machinery cannot observe ring1 until those repos switch channels.

Regression detection is **byte-identity-aware**: the benign-failure allowlist applies
**only** when the reusable blob is byte-unchanged, so a candidate-introduced regression
cannot be masked by the allowlist when the blob changes. However, the Story-3 change
targets `scripts/engine.sh`, not `.github/workflows/dev-lead-reusable.yml`; a
script-only candidate can therefore leave the reusable blob byte-identical, in which
case the allowlist **remains active** and pre-existing failures could mask
candidate-introduced regressions. Before recording the gate result, the owner must
confirm whether the reusable workflow blob changed in this candidate
(`git diff <base>..HEAD -- .github/workflows/dev-lead-reusable.yml`). If the blob is
byte-identical, perform a manual script diff check (`scripts/engine.sh` diff against
the previous ring's content) to confirm no candidate-introduced regression is hidden
behind the allowlist. Do not treat this row as proof the allowlist is inactive without
first verifying the blob changed. Record the gate result per transition:

| Transition | dwell met | sample | candidate-introduced regression? | gate |
|------------|-----------|-------:|----------------------------------|------|
| `next → ring0`  | *fill* | *fill* | *none / detail* | *pass / hold* |
| `ring0 → ring1` | *fill* | waived | *none / detail* | *pass / hold* |
| `ring1 → stable` | *fill* | *fill (≥ 1 ring1 run required — `sample_min: 1` in `canary-rings.json`; or attach explicit Release_Manager waiver)* | *none / detail* | **hold** — do not fill until (a) the ring1 repin blocker is resolved (TalkTerm + bmad-bgreat-suite switched to `@dev-lead/ring1`), (b) ring1 health evidence has been collected from a full dwell window, **and** (c) at least one ring1 sample run is recorded |

> `ring1 → stable` requires the ring1 repin blocker above to be resolved before the
> row can be filled. Promotion to `stable` is the human action gated by this record
> (see [Guardrail](#guardrail-human-only-promotion)) — do not sign GO while this row
> is still **hold**.

## Recommendation

*To be written by the initiative owner from the three evidence sections above.*

- **If** §1 shows non-regression on both holdout sets **and** §2 realized-cost
  measurement is complete and shows a measured intro-pricing input-cost reduction of
  **at least 30%** **and** §3 shows no candidate-introduced regression through `ring1`,
  **and** the decision is made while intro pricing is live: **GO** — the ≥30% intro cost
  win ships with no quality regression. Proceed to the default swap as a human action,
  with the requirement that the default-order `engine.sh` change (moving
  `claude-sonnet-5-0` to the primary Sonnet slot ahead of `claude-sonnet-4-6`) is a
  **separate** release that must itself ride the dev-lead canary rings
  (`next → ring0 → ring1 → stable`) and pass the same gate before `stable` consumers
  see it. This GO decision authorizes a human to initiate that canary; it does not
  authorize skipping the ring walk for the default-order change.
- **If** §1 shows a regression on either set, or §2 realized-cost measurement is missing
  or shows less than 30% input-cost reduction under intro pricing, or §3 holds at any
  ring: **NO-GO** — do not swap the default; keep `sonnet-4-6` primary and Sonnet 5 as
  the tail fallback. If §2 evidence is not yet available, route to the documented
  deadline contingency (see [Deadline contingency](#deadline-contingency-2026-08-31)).

## Decision (human owner signs)

> **Issue #1100 stays open until this block is signed.** A filled Decision table with a
> real verdict, the owner's GitHub login, a date, and cited evidence is required to close
> issue #1100. Do not close it programmatically or via this PR's merge — the human owner
> must fill and sign this block, then close #1100 manually.

| Field | Value |
|-------|-------|
| Decision | **GO / NO-GO / DEFER** *(circle one)* |
| Decided by | *human owner* |
| Decided on | *YYYY-MM-DD* (for a GO during intro pricing, must be **on or before 2026-08-31**; contingency decisions — "Proceed at standard pricing" or "Hold" — may be dated **after** 2026-08-31 and are still valid per [Deadline contingency](#deadline-contingency-2026-08-31)) |
| Evidence cited | §1 eval verdict · §2 cost delta · §3 canary gate |
| Rationale | *one paragraph* |

## Deadline contingency (2026-08-31)

> **Update (2026-09-30, #1978 / PR #1982):** the scheduled 2026-09-01 increase to
> `$3/$15` was cancelled, so Sonnet 5's `$2/$10` launch rate is now its standard price
> (Anthropic pricing page, footnote 3). `scripts/lib/model-pricing.tsv` was corrected
> to match. The `$3/$15` standard-window plan below reflects what was announced when
> this record was written; that rate never took effect.

The intro-pricing deadline is real: `$2/$10` closes 2026-08-31, after which the standard
`$3/$15` applies. If the canary/eval evidence is **not conclusive by 2026-08-31**, the
recommendation must explicitly state which of the following the owner chose:

- **Proceed at standard pricing** — Sonnet 5 becomes default at `$3/$15`. There is **no
  cost win** (it is cost-identical to `sonnet-4-6`) but also **no cost penalty**; justify
  the swap purely on the quality evidence, or hold.
- **Hold** — keep `sonnet-4-6` primary; the intro discount is forfeited and the swap, if
  ever made, is a later quality-driven decision at standard pricing.

Record the contingency choice in the [Decision](#decision-human-owner-signs) block if the
deadline is reached without conclusive canary evidence.

## Guardrail: human-only promotion

- **No `initiative:auto`.** This story must not carry the auto-release label; nothing here
  promotes automatically.
- **No unattended promotion to `stable` / default.** Moving the `dev-lead/stable` channel
  tag and swapping the chain default are **human** actions, performed only via the
  human-gated release-channel move — never auto-released to dev-lead. This mirrors the
  `hands_off` intent of the epic and the release-channel-tag ruleset (see
  [AGENTS.md → Release channel tags](../../AGENTS.md) and
  [`docs/release/versioning.md`](../release/versioning.md)).
