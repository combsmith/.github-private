# `evals/spec-drift/` — frozen offline eval for the spec-drift detector

This is the frozen, offline evaluation for the Story-2 spec-drift detector
(`scripts/spec-drift.sh`, #1144, epic #1142). Its job is to prove the detector is
**honest** before it is wired into the pipeline: it runs entirely offline (no live
PR, no LLM, no network), is tuned only on a proposer-visible `dev` split, and
proves **0 false positives** on an immutable `holdout` split.

It mirrors `evals/deep-review/` (a `dev` split you tune on, a `holdout` split you
never train against) and follows the split-hygiene conventions in
[`evals/README.md`](../README.md) / [`evals/validate-cases.py`](../validate-cases.py).

## What the detector actually decides

`scripts/spec-drift.sh` compares a merged PR's diff against the closed story's
acceptance criteria (the spec) and emits `DRIFT` / `ALIGNED` / `INDETERMINATE`.
Its **deterministic, pure** surface is `classify_drift(analysis)`: it maps the
cheap-tier analysis text into a verdict (the live model/`gh` I/O lives only in
`main()`). This eval drives that pure classifier directly — that is the whole
"runnable offline" guarantee.

## The case shape

Each line of `dev/cases.jsonl` and `holdout/cases.jsonl` is one JSON object
conforming to [`case.schema.json`](./case.schema.json). It is a labeled
**(diff, acceptance-criteria, expected-verdict)** triple, plus the frozen
cheap-tier `analysis` fixture the classifier consumes:

| field | meaning |
|-------|---------|
| `id` | unique kebab-case id (unique per split, disjoint across splits) |
| `description` | what the case exercises and why the verdict is grounded |
| `tags` | optional coverage labels (`fp-trap`, `true-positive`, `timeout`, `token-variant`, …) |
| `acceptance_criteria` | the story's ACs — the spec the diff is judged against |
| `diff` | the merged PR's unified diff (de-identified/synthetic) |
| `analysis` | the **frozen cheap-tier detector output** for this (diff, ACs); normally ends in a `DRIFT_VERDICT:` line, or is empty to model a timeout |
| `expected.verdict` | the fixed verdict `classify_drift` must produce: `DRIFT` \| `ALIGNED` \| `INDETERMINATE` |

**Why a frozen `analysis` fixture?** Offline scoring can't call the model, so each
case records what the cheap tier produced — exactly the pattern
`evals/deep-review/` uses (it embeds a fixed `Triage result:` in its inputs). The
diff and acceptance criteria ground the scenario the analysis is about; the pure
classifier is scored against the recorded `analysis`, deterministically.

All cases in **both** splits are synthetic/de-identified (decision A3 in
[`evals/README.md`](../README.md)) — no real customer data, secrets, or PII.

## The 0-false-positives gate (AC5)

A **false positive** is the costly detector error: it emits `DRIFT` for a PR whose
expected verdict is **not** drift — i.e. it alarms a spec-compliant change. A
*missed* drift (verdict `INDETERMINATE`/`ALIGNED` when the truth is `DRIFT`) is a
false *negative*, not a false positive.

The harness exits non-zero if **any** split it scores contains a false positive.
The holdout split must always score **0 false positives**. Its FP-trap cases
(`fp-trap` tag) are exactly the ones a sloppy detector would trip on: prose that
mentions "drift" or "no drift detected" but concludes `ALIGNED`, and empty/timeout
analyses that must stay `INDETERMINATE` rather than fabricate a `DRIFT`.

## Running it offline

```bash
# Score both committed splits (per-case results + SUMMARY line):
bash evals/spec-drift/run-eval.sh

# Tune against the dev split ONLY (never reads holdout/):
bash evals/spec-drift/run-eval.sh dev

# Gate: prove the frozen holdout still has 0 false positives:
bash evals/spec-drift/run-eval.sh holdout

# Validate the documented case shape and split hygiene:
python3 evals/validate-cases.py evals/spec-drift/dev/cases.jsonl     evals/spec-drift/case.schema.json
python3 evals/validate-cases.py evals/spec-drift/holdout/cases.jsonl evals/spec-drift/case.schema.json
python3 evals/validate-cases.py            # dev/holdout hygiene across evals/
```

`run-eval.sh` prints a machine-readable summary per split, e.g.:

```
SUMMARY split=holdout total=8 correct=8 false_positives=0 false_negatives=0 mismatches=0
```

The harness is unit-tested by [`tests/test_spec_drift_eval.bats`](../../tests/test_spec_drift_eval.bats)
(wired into the `bats` job in `.github/workflows/lint.yml`), and is `shellcheck`-clean.

## The reward-hacking guard (AC3) — tune on `dev` only

Tuning the detector means adjusting it against **`dev` only**. The harness
**physically reads only the split(s) named on the command line**:
`run-eval.sh dev` never opens `holdout/cases.jsonl`. The holdout is the
never-tuned baseline the gate scores against; a detector change is only
promotable if `run-eval.sh holdout` still reports `false_positives=0`.

> **Result of tuning to date:** the Story-2 classifier already scores
> `false_positives=0` on **both** splits with no change to `scripts/spec-drift.sh`.
> This eval adds only the eval directory + harness; it changes no production
> behavior.

## The artifact-immutability guard (AC4) — the holdout is frozen

The `holdout/` cases and their `expected.verdict` baseline are committed as
**frozen fixtures**. Changing any holdout expectation is a deliberate, reviewed
fixture change — **never** a tuning-loop side effect. Two independent controls
enforce this, both already in place for everything under `evals/`:

1. **CODEOWNERS** owner-locks `/evals/**/holdout/` to `@petry-projects/org-leads`
   ([`.github/CODEOWNERS`](../../.github/CODEOWNERS)).
2. **CI immutability gate** — [`holdout-guard.yml`](../../.github/workflows/holdout-guard.yml)
   / [`scripts/lib/holdout-guard.sh`](../../scripts/lib/holdout-guard.sh) hard-fails
   any proposer-authored PR that changes a held-out path (the `evals/` prefix
   already covers `evals/spec-drift/holdout/`).

So a proposer can neither rewrite the holdout to make a weak detector look good nor
quietly move the 0-false-positives baseline: it can only be moved by a maintainer's
explicit, reviewed change.
