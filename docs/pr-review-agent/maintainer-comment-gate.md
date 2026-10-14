# Maintainer issue-comment gate (issue #1290)

This document explains why a maintainer finding posted two different ways can have
opposite mechanical force, and how the pr-review **maintainer issue-comment gate**
closes that gap. It exists so the difference between the two comment types is not
tribal knowledge.

## The two review tiers look identical but aren't

GitHub exposes two ways to leave a comment on a PR, and they are mechanically
different:

| You do this | GitHub creates | `required_review_thread_resolution` | dev-lead `fix-reviews.md` reads it? |
|---|---|---|---|
| **Inline review comment** (comment anchored to a line, or a review with `CHANGES_REQUESTED`) | a **review thread** | ✅ blocks merge until resolved | ✅ yes — it walks `reviewThreads` |
| **Issue comment** (`gh pr comment`, or the GitHub main comment box at the bottom of the PR) | **no thread at all** | ❌ does not apply — no thread to resolve | ❌ no — the prompt only enumerates `reviewThreads` |

The same words, posted two ways, have opposite force. One is a blocking, actionable
signal; the other was — before this gate — a diary entry. Worse, `gh pr comment` is
the *ergonomic default*: the obvious verb an agent or human reaches for first. **The
easy path was the silent one.** This shipped a regression to `main` (the incident in
[#1290](https://github.com/combsmith/.github-private/issues/1290)): a maintainer
posted a "fails open" finding as a PR comment, dev-lead never saw it, pr-review
approved, and the PR auto-merged eight minutes later with the defect intact.

## What the gate does

The gate lives in [`scripts/lib/maintainer-comment-gate.sh`](../../scripts/lib/maintainer-comment-gate.sh)
and is invoked by [`scripts/review-one-pr.sh`](../../scripts/review-one-pr.sh)
right after the advisory-bot gate, before pr-review posts its approval. It is
deliberately modeled on the advisory-bot gate
([`advisory-review-gate.sh`](../../scripts/lib/advisory-review-gate.sh), #457/#458),
which likewise defers approval until a signal is incorporated.

> pr-review withholds its **automated approval** while the **latest maintainer
> issue comment postdates the last push**.

Because pr-review is the code-owner approver, withholding its approval means the PR
does not satisfy the code-owner review requirement and therefore **does not
auto-merge** — closing the "does not block" half at the approval boundary.

### What counts as a "maintainer issue comment"

An issue comment is treated as a maintainer finding **unless** it is clearly one of
ours or an already-gated bot:

- Comments carrying one of our automation markers — `<!-- pr-review-agent … -->`,
  `<!-- persona:… -->`, `<!-- dev-lead … -->`, `<!-- dependency-advisory -->` — are
  ours, never a finding. (This marker-based exclusion matters because several of
  these workflows — dev-lead and the dependency-advisory pass — post as the human
  owner `don-petry`, the *same account* a human maintainer uses, so login alone
  cannot separate the two. dev-lead's own rate-limit acknowledgments and its
  `@coderabbitai resolve` nudge carry a `<!-- dev-lead … -->` marker for exactly
  this reason.)
- Comments from the agent's own login (`BOT_USER`, default `donpetry-bot`) are
  excluded.
- Comments from advisory/review bots and generic automation (Gemini, Copilot,
  SonarCloud, Codex, CodeRabbit, `github-actions`, `dependabot`) are excluded —
  advisory bots are handled by the advisory-bot gate.

Everything else is treated as a human maintainer finding. This is the fail-closed
default: an *unknown* author blocks rather than slips through.

### When the block clears

A maintainer issue comment is considered **addressed** — and the gate stops
blocking — when a commit has been pushed at or after it. In practice:

- **dev-lead (or the author) pushes a fix.** The head commit's `committer.date`
  advances past the comment, so the latest maintainer comment no longer postdates
  the last push → the gate clears on the next review.
- If you only want to *chat* (e.g. "LGTM") without requesting a change, leave an
  **approving review** rather than a plain comment — a review is not a maintainer
  finding, and it also positively signals "no changes needed".

### Fails closed

The [#1290](https://github.com/combsmith/.github-private/issues/1290)
acceptance criterion is that an inability to determine whether a finding was
addressed must **not** read as "no findings" — that is exactly the bug that shipped
the regression. So:

- A maintainer comment with an **undeterminable push time** (GraphQL unreachable) →
  **blocks** (return 1).
- A **malformed / unparseable** PR snapshot → **fails the PR** (return 2 → exit 1)
  so a scheduled run retries, rather than approving blind.

### Bypass

`FORCE_REVIEW` (a human `@mention` of the reviewer, or an explicit `force_review`
dispatch) bypasses the gate — a human `@mention` *is* the human-in-the-loop the gate
exists to obtain, and the same comment that triggers a re-review would otherwise
deadlock the gate. Required-check enforcement at the ruleset still applies.

## The review-thread sibling (issue #1415)

The issue-comment gate above closes the *comment* path. Its sibling — the
**maintainer review-thread gate**
([`scripts/lib/maintainer-review-thread-gate.sh`](../../scripts/lib/maintainer-review-thread-gate.sh))
— closes the *review* path, for the specific case that makes a dev-lead-authored
PR different from any other PR: **dev-lead acts as the owner `don-petry`**
(AGENTS.md "Agent identity & credential secrets"; #1316 set this on purpose). That
shared identity removes *both* of the owner's mechanically-blocking review paths:

1. **`CHANGES_REQUESTED` is unavailable** — GitHub refuses "Can not request changes
   on your own pull request" when the owner reviews a PR authored by the owner
   account.
2. **The inline-thread fallback is defeated** — inline review threads normally block
   via `required_review_thread_resolution`, but the agent (running as `don-petry`)
   can *resolve the maintainer's own threads*. Observed on PR #1413: four maintainer
   threads, all `resolvedBy: don-petry`, gate cleared, auto-merge enabled.

This is [#860](https://github.com/combsmith/.github-private/issues/860)
normative rule 2 applied to review gates: **a gate whose reset is reachable by the
agent is not a gate** (`docs/agentic-interaction-model.md` §7 rule 2, extended in
§12 to review/merge gates).

### Two coupled halves

Because login cannot separate the agent from the maintainer here (both are
`don-petry`), the fix keys on the **automation marker** in a thread's originating
comment — the *same* discriminator this issue-comment gate uses — and has two
coupled halves:

- **The resolve-guard (dev-lead side).** `review_thread_is_agent_authored` classifies
  a thread by its originating comment's marker. dev-lead's resolve call-site
  (`resolve_actor_outdated_threads` in
  [`scripts/dev-lead-fix-reviews.sh`](../../scripts/dev-lead-fix-reviews.sh)) and its
  prompt ([`prompts/dev-lead/fix-reviews.md`](../../prompts/dev-lead/fix-reviews.md))
  **skip** any marker-less thread — a maintainer finding — logging a visible
  `::warning::` rather than silently resolving it. The agent may only resolve threads
  carrying one of our markers (`<!-- pr-review-agent … -->`, `<!-- persona:… -->`,
  `<!-- dev-lead … -->`, `<!-- dependency-advisory -->`).
- **The approval gate (pr-review side).** `check_maintainer_review_threads` withholds
  pr-review's automated approval while an **unresolved maintainer review thread
  postdates the last push**, wired into
  [`scripts/review-one-pr.sh`](../../scripts/review-one-pr.sh) right after the
  issue-comment gate. Withholding the code-owner approval means the PR does not
  auto-merge — the same approval-boundary lever the issue-comment gate pulls.

The two halves are **coupled by design**: the gate treats a *resolved* maintainer
thread as cleared (AC #4: "a human resolving the thread also clears it"), and that is
safe **only because** the resolve-guard prevents the agent from resolving marker-less
threads. Resolution therefore becomes a human-only signal — a reset the runaway
cannot reach.

### Clears the #1290 way, fails closed the #1290 way

- **Addressed by a push.** A commit pushed at/after the finding (head commit
  `pushedDate` ≥ the thread's originating `createdAt`) marks it addressed, so the
  normal fix-then-continue flow is not deadlocked. `pushedDate` is a server-recorded
  timestamp written by GitHub on receipt of the push — unlike `committer.date` (which
  is commit metadata the author controls), it cannot be set to an arbitrary past or
  future value. When `pushedDate` is unavailable, the gate fails closed (finding
  treated as unresolved).
- **Addressed by a human resolving the thread** (safe per the coupling above).
- **Fails closed.** Undeterminable authorship, `createdAt`, or push-time → **block**
  (return 1); a malformed threads snapshot → **fail the PR** (return 2 → exit 1). An
  inability to confirm a finding was addressed must never read as "no findings".
- **`FORCE_REVIEW` bypasses** — a human `@mention` *is* the human-in-the-loop the gate
  exists to obtain, and the same comment that triggers a re-review would otherwise
  deadlock the gate.

Tests:
[`tests/dev-lead/unit/test_maintainer_review_thread_gate.bats`](../../tests/dev-lead/unit/test_maintainer_review_thread_gate.bats),
including a #1413 regression fixture
([`tests/dev-lead/fixtures/review-threads/pr-1413-maintainer-threads.json`](../../tests/dev-lead/fixtures/review-threads/pr-1413-maintainer-threads.json))
that reproduces the four marker-less `don-petry` threads and asserts the gate blocks
and the classifier refuses to resolve each one.

## Interim workaround (still valid)

Posting findings as **reviews with `CHANGES_REQUESTED`** (or inline review comments)
rather than issue comments remains the most direct way to make a finding both
blocking *and* actionable by dev-lead — that path creates a review thread, which
trips `required_review_thread_resolution` and is enumerated by `fix-reviews.md`.
This gate ensures the *comment* path is no longer silent even when the review path
is not used.

## Tests

- [`tests/dev-lead/unit/test_maintainer_comment_gate.bats`](../../tests/dev-lead/unit/test_maintainer_comment_gate.bats)
  covers the gate logic (block / addressed / fail-closed / exclusions) and the
  review-one-pr wiring, including the regression: a PR carrying an unaddressed
  maintainer issue comment does not get approved (and therefore does not
  auto-merge).
