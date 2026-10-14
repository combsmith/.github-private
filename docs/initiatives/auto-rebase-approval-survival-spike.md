# Spike: Auto-rebase approval-survival — does merge-method `update-branch` strip an approval?

**Status:** Blocked on a human decision. The **architectural half** is resolved (decisive, live-verified);
the **empirical half** requires a human-operated live test PR this automated run cannot perform. Both roads
lead to the same handoff — see [§4](#4-decision-tree-resolution). **No ruleset or workflow was changed.**
**Author:** dev-lead / Claude Code
**Date:** 2026-08-02
**Tracks:** [#1437](https://github.com/petry-projects/.github-private/issues/1437) (AC2 of epic
[#1416](https://github.com/petry-projects/.github-private/issues/1416))

---

## 1. The question

Epic #1416 (AC1) flips the auto-rebase reusable's default `eligibility` from `review-ready` to `all`, so
non-draft PRs are kept current on `main` **before** review, not after. That change makes a mechanism
observable that is inert today: a PR can be `APPROVED` while still behind `main`, and auto-rebase's own
`update-branch` (merge method) then pushes a merge commit to the PR head.

This repo's `pr-quality` ruleset carries both `dismiss_stale_reviews_on_push: true` and
`require_last_push_approval: true` (9 of 11 active fleet repos share this combination — #1416 §3). AC2 asks:
**does auto-rebase's own merge-method `update-branch` push dismiss the human approval under that ruleset?**

The issue is explicit that this is a *verification* spike, not an assumed defect — the #1416 §3 revision
withdrew the first draft's claim that `dismiss_stale_reviews_on_push` fires "regardless of merge vs. rebase
method" as an unverified overreach. So the empirical answer must come from an observed timeline, not from
documentation or from this repo's existing "merge-method update (approval-safe)" wording in
`auto-rebase-vs-merge-queue.md` §1 (which the epic explicitly walked back).

## 2. Empirical half — protocol for a human operator

An automated dev-lead run cannot execute this half: it requires creating a PR (this agent is barred from
opening PRs), a *second* approving identity, and a live `Auto-rebase non-Dependabot PRs` run against a real
behind PR — a live, multi-actor, side-effectful experiment. The protocol, for whoever runs it:

1. On this repo (or any repo pinned to `auto-rebase/v2-next`), branch from a commit that is **behind** `main`
   and open a non-draft PR. Keep it conflict-free so `update-branch` succeeds cleanly.
2. Have an approver (a human, or the review identity) post an **`APPROVED`** review. Confirm
   `gh pr view <n> --json reviewDecision` reads `APPROVED`.
3. Trigger the auto-rebase update — push a commit to `main` (or `workflow_dispatch` the
   `Auto-rebase non-Dependabot PRs` workflow). Because AC1 has not shipped, temporarily add the
   `auto-rebase:ready` label (or the `APPROVED` review already satisfies the `review-ready` predicate) so the
   PR is eligible and gets `update-branch (update_method=merge)`.
4. Read the PR timeline for a `review_dismissed` event and re-check `reviewDecision`:
   - `gh api repos/<owner>/<repo>/issues/<n>/timeline --jq '.[] | select(.event=="review_dismissed")'`
   - `gh pr view <n> --json reviewDecision,latestReviews`
5. **Survives** (no `review_dismissed`, `reviewDecision` stays `APPROVED`) → close #1437 with the timeline as
   evidence; no ruleset change. **Stripped** → the finding in §3 already dictates the outcome; go to §4.

## 3. Architectural half — decisive, verified live (2026-08-02)

Even if the empirical half confirms stripping, the fix the issue names — "an actor-scoped bypass for the
auto-rebase automation's identity … scoping bypass to just this rule" (`dismiss_stale_reviews_on_push` /
`require_last_push_approval`) — **is not expressible in GitHub's ruleset model.** Verified against the live
ruleset (`gh api repos/petry-projects/.github-private/rulesets/16142042`):

- Those two settings are **not separate rules.** They are **parameters of a single `pull_request` rule**,
  bundled with the other review gates:

  ```jsonc
  "rules": [
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "require_last_push_approval": true,
        "required_review_thread_resolution": true,
        ...
    }}
  ]
  ```

- **`bypass_actors` is a ruleset-level array**, with no per-rule and no per-parameter bypass field — the same
  shape as this repo's committed `.github/rulesets/release-channel-tags.json`. A bypass actor is exempted from
  the **entire** ruleset.

Consequence: adding the auto-rebase identity to `pr-quality`'s `bypass_actors` would exempt it not just from
the two stale-approval settings but from `required_approving_review_count`, `require_code_owner_review`, and
`required_review_thread_resolution` as well — i.e. the automation could push straight past **every** PR-quality
gate. That is precisely the fleet-wide review-integrity relaxation #1416's decision forbids, not the narrow
"stop erasing approvals" fix requested. GitHub's ruleset model does **not** support scoping a bypass to just
that rule for one actor. This confirms the caveat #1416 flagged ("bypass is normally ruleset-level, not
per-rule — verify before assuming").

## 4. Decision-tree resolution

Per #1437 / #1416 AC2, verbatim: *"If per-rule actor scoping isn't supported, do not silently fall back to the
fleet-wide relax — stop and flag `dev-lead:needs-human` so a human picks the fallback explicitly, since that
was the non-chosen option for a real review-integrity tradeoff."*

The architectural half above resolves that antecedent to **not supported**, so the mandated action is
`dev-lead:needs-human` — independent of the empirical outcome, which this automated run also cannot obtain.
**No ruleset or workflow was changed by this spike.** The human owner now chooses among:

- **A — Run the §2 spike first.** If the approval **survives** a merge-method `update-branch`, there is nothing
  to fix: close #1437 with the timeline evidence. (This is the outcome the pre-existing "approval-safe" wording
  in `auto-rebase-vs-merge-queue.md` §1 predicts, but which #1416 §3 explicitly declines to assume.)
- **B — Split the ruleset (if the spike confirms stripping).** Move `dismiss_stale_reviews_on_push` /
  `require_last_push_approval` into their *own* `pr-quality`-adjacent ruleset and grant the auto-rebase identity
  bypass on **only that** ruleset, leaving `required_approving_review_count` / `require_code_owner_review` /
  `required_review_thread_resolution` in a ruleset the automation still obeys. This is the only way to get
  actor-scoped, rule-narrow behavior out of GitHub's model — but it is a review-integrity architecture change
  (and a fleet-wide one, across the 9 affected repos), so it is a human call, not an automated one. It also
  presumes the auto-rebase automation runs under a *stable, nameable* actor identity; today it runs as
  `GITHUB_TOKEN` (the generic GitHub Actions app), which cannot be distinguished from any other
  `contents: write` workflow — so this option may first require giving auto-rebase a dedicated app/PAT identity
  (cf. `agentic-release-strategy.md` §5.1–5.2 on scoping bypass to a dedicated identity).
- **C — Accept the fleet-wide relax.** The explicitly *non-chosen* option in #1416's decision. Recorded here
  only so the human is choosing from the full set; it should not be taken without re-opening that decision.

Do **not** proceed to B or C automatically. This spike stops at the `dev-lead:needs-human` handoff.

## 5. References

- #1437 — this spike (AC2 sub-issue). #1416 — parent epic; §3 (the empirical open question) and the
  "Decisions (2026-08-02)" AC2 contingency + caveat.
- `.github/rulesets/release-channel-tags.json` — in-repo precedent for the ruleset-level `bypass_actors` shape.
- `docs/initiatives/auto-rebase-vs-merge-queue.md` §1 — the "merge-method update (approval-safe)" wording that
  #1416 §3 walks back to an unverified claim.
- `docs/initiatives/agentic-release-strategy.md` §5.1–5.2 — scoping a ruleset bypass to a dedicated automation
  identity (relevant to option B).
