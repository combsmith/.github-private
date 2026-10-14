# Compliance verification — `pr-quality` / `require_last_push_approval` (#1479)

**Check:** `ruleset-drift-pr-quality-require_last_push_approval` (category `rulesets`, severity `error`)
**Issue:** [#1479](https://github.com/petry-projects/.github-private/issues/1479)
**Author:** dev-lead / Claude Code
**Date:** 2026-08-18
**Outcome:** Already compliant — no in-repo change applies. Recommend closing #1479 as already remediated.

---

## 1. The finding

The weekly compliance audit reported that ruleset `pr-quality` parameter `require_last_push_approval`
had drifted from the codified standard: **expected `true`, actual `false`**. The codified source of
truth is `standards/rulesets/pr-quality.json` in the public `petry-projects/.github` repo (#575/#580),
and the audit's remediation is to run `scripts/apply-rulesets.sh --repo petry-projects/.github-private`
to converge the **live** GitHub ruleset.

## 2. Why this is not an in-repo code change

`pr-quality` is an **org-wide** ruleset applied to every repo from the **public** `petry-projects/.github`
repo. Both its codified JSON (`standards/rulesets/pr-quality.json`) and the tool that applies it
(`scripts/apply-rulesets.sh`) live **there**, not in this repo. This repo (`.github-private`) is the
*target* of the audit, not the home of the standard.

This repo intentionally commits only **repo-specific** rulesets — currently just
[`.github/rulesets/release-channel-tags.json`](../../.github/rulesets/release-channel-tags.json), which
protects this repo's own first-party release-channel tag namespaces. It deliberately does **not** carry a
local copy of the org-wide `pr-quality` ruleset; duplicating it here would create a second, divergent
source of truth against the single-source-of-truth model the standard establishes.

Consequently the reported drift is a **live GitHub settings** value, not a value stored in any committed
file. No edit to a file in this repo converges it; the sanctioned convergence path is the public
`apply-rulesets.sh` run (admin / automation-integration credentials), which is outside `<id>`'s
code-change and git scope.

## 3. Live-state verification (2026-08-18)

Authenticated read of the live `pr-quality` ruleset on this repo shows the parameter is **already at the
codified value** — the reported `true`→`false` drift is no longer present:

```console
$ gh api repos/petry-projects/.github-private/rulesets/16142042 \
    --jq '{name, enforcement, rule:(.rules[]|select(.type=="pull_request").parameters)}'
{
  "name": "pr-quality",
  "enforcement": "active",
  "rule": {
    "allowed_merge_methods": ["squash"],
    "dismiss_stale_reviews_on_push": true,
    "require_code_owner_review": true,
    "require_last_push_approval": true,
    "required_approving_review_count": 1,
    "required_review_thread_resolution": true
  }
}
```

`require_last_push_approval: true` matches the standard; the ruleset is `active`. The audit finding is
therefore **stale / already remediated** (the live value was corrected after the audit snapshot, or the
snapshot was stale). Per the "trust current observed state over a prior snapshot" principle, the live
value governs.

## 4. Review-integrity note

Relaxing `require_last_push_approval` (and its sibling `dismiss_stale_reviews_on_push`) was explicitly
deferred to a human decision in the auto-rebase approval-survival spike
([`docs/initiatives/auto-rebase-approval-survival-spike.md`](../initiatives/auto-rebase-approval-survival-spike.md)
§4, tracking #1437 / epic #1416): the fleet-wide relax was the *non-chosen* option. A transient drift of
this parameter to `false` would be an **unsanctioned relaxation** of a PR-quality gate, so restoring/keeping
it `true` is the correct posture. The current live state already reflects that.

## 5. Recommendation

- **Close #1479 as already remediated** — the live `pr-quality` ruleset matches the codified standard on
  the flagged parameter.
- For belt-and-braces convergence, a maintainer may run
  `scripts/apply-rulesets.sh --repo petry-projects/.github-private` from the public `petry-projects/.github`
  tooling. Given the current live value it is an **idempotent no-op** for this parameter.

## 6. References

- [#1479](https://github.com/petry-projects/.github-private/issues/1479) — this compliance finding.
- `standards/rulesets/pr-quality.json`, `scripts/apply-rulesets.sh` — codified standard + apply tool, in
  the public `petry-projects/.github` repo (#575/#580).
- [`.github/rulesets/release-channel-tags.json`](../../.github/rulesets/release-channel-tags.json) — the
  in-repo precedent for a *repo-specific* committed ruleset (vs. the org-wide, centrally-applied `pr-quality`).
- [`docs/initiatives/auto-rebase-approval-survival-spike.md`](../initiatives/auto-rebase-approval-survival-spike.md)
  §3–4 — confirms this repo's `pr-quality` ruleset (id `16142042`) carries `require_last_push_approval`, and
  that relaxing it was deferred to a human.
