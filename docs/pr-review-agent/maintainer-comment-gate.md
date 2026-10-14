# Maintainer issue-comment gate (issues #1290, #1813, #1918, #2008)

> **Redesigned in [#1813](https://github.com/petry-projects/.github-private/issues/1813)
> and [#1918](https://github.com/petry-projects/.github-private/issues/1918).** The
> original gate (#1290) judged a comment *addressed* by comparing timestamps — a push
> at/after the comment cleared it. GitHub now always returns the head push timestamp as
> `null`, so that model failed closed on every open PR (the #1813 outage), and a push
> was only ever a proxy for whether the finding was actually read and acted on. The
> gate no longer reads push time at all: "addressed" now means a **verified
> disposition** (the comment minimized with classifier `RESOLVED`), and **every** issue
> comment — human *and* bot — must carry one, except for the narrow exemption set
> described below (ADR-0012). The push-timing paragraphs that follow describe the **superseded** model and
> are retained only for the review-thread sibling gate, which still uses push time.

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
[#1290](https://github.com/petry-projects/.github-private/issues/1290)): a maintainer
posted a "fails open" finding as a PR comment, dev-lead never saw it, pr-review
approved, and the PR auto-merged eight minutes later with the defect intact.

## What the gate does

The gate lives in [`scripts/lib/maintainer-comment-gate.sh`](../../scripts/lib/maintainer-comment-gate.sh)
and is invoked by [`scripts/review-one-pr.sh`](../../scripts/review-one-pr.sh)
right after the advisory-bot gate, before pr-review posts its approval. It is
deliberately modeled on the advisory-bot gate
([`advisory-review-gate.sh`](../../scripts/lib/advisory-review-gate.sh), #457/#458),
which likewise defers approval until a signal is incorporated.

> pr-review withholds its **automated approval** while **any non-agent PR issue
> comment lacks a verified disposition** (is not minimized with classifier `RESOLVED`).

Because pr-review is the code-owner approver, withholding its approval means the PR
does not satisfy the code-owner review requirement and therefore **does not
auto-merge** — closing the "does not block" half at the approval boundary.

### What counts as a comment that must be dispositioned

Since #1813 the scope is PR issue comments from human maintainers **and** bots alike
(`codeant-ai`, `qodo-code-review`, and so on). No author is exempt for being a bot: a
trial-ended notice has an operational consequence. A comment blocks approval until it
is minimized `RESOLVED`, **unless** it is in the exemption set recorded in
[ADR-0012](../architecture/adr/0012-comment-gate-exemption-set.md) (#2209):

- **Our own automation's replies, and the conflict sentinel.** Comments carrying one
  of our registered markers — `<!-- pr-review-agent … -->`, `<!-- pr-review-claim … -->`,
  `<!-- persona:… -->`, `<!-- dev-lead … -->` (including the
  `<!-- dev-lead:comment-disposition … -->` reply), `<!-- dependency-advisory -->`,
  `<!-- maintainer-resolve … -->`, and the `<!-- auto-rebase-conflict: … -->` sentinel —
  are never a finding, so the agent never has to answer itself. (The sentinel is
  exempt because the conflict already blocks the merge. This marker-based exclusion
  matters because several of these workflows post as the human owner `don-petry`, the
  *same account* a human maintainer uses, so login alone cannot separate the two.)
  Comments from the agent's own login (`BOT_USER`, default `donpetry-bot`) are likewise
  excluded.
- **A review request.** From an `OWNER`, `MEMBER` or `COLLABORATOR` only, a comment
  whose whole trimmed body is `@<bot user>`, optionally followed by `please review`
  (case-insensitive, optional final `.` or `!`), optionally followed by the Claude
  Code footer (`---` and `_Generated by [Claude Code](<url>)_`). Any other text keeps
  the comment in scope.
- **The maintainer opt-out.** From an `OWNER`, `MEMBER` or `COLLABORATOR` only, a
  comment carrying `<!-- maintainer:not-a-finding -->`. Use it on a steering comment:
  the gate cannot tell steering from a finding, so without the marker it blocks. From
  any other author the marker does nothing.
- **A registered clean *info-status* bot comment (#1918).** A comment authored by a
  reviewer source that declares an `info_status_pattern` in the reviewer-source
  registry (`scripts/lib/reviewer-sources.tsv`), and whose body matches that pattern,
  is a clean status report carrying no finding and is treated as **addressed**. The
  canonical case is SonarCloud's `Quality Gate passed` comment, which it **re-posts on
  every push**; its pattern pins the `**Quality Gate passed**` headline **and** the
  `[0 New issues]` and `[0 Security Hotspots]` lines, so a `Quality Gate failed`
  comment, or one still reporting new issues or hotspots, does **not** match and still
  blocks. An unreadable registry degrades to "clear nothing", never to clearing
  something it cannot classify. **A pattern never clears a body with a
  finding-bearing section (#2008).** Such sections include a Security Architecture
  Review with retained concerns, a non-zero `Actionable comments posted`, and
  Outside-diff or Nitpick comments (`reviewer_sources_finding_section_pattern`). A
  notice covers only itself, never the findings beside it.

Everything else — a bot comment with a finding, a bot with no registered pattern, an
*unknown* author, or any human comment — blocks. This is the fail-closed default: an
author or body the gate cannot positively clear blocks rather than slips through.

### When the block clears

A comment is considered **addressed** — and the gate stops blocking — when it is
minimized with classifier `RESOLVED`. In practice:

- **dev-lead dispositions it.** dev-lead researches each undispositioned comment,
  posts exactly one evidence-backed reply carrying
  `<!-- dev-lead:comment-disposition id=<id> disposition=<…> -->`, and the harness
  verifies that disposition and then minimizes the **original** comment `RESOLVED`
  (GraphQL `minimizeComment`). A push alone no longer clears anything.
  A `fixed` disposition is verified by the cited commit's **diff content** (#2004).
  The commit must be on the PR's pushed head and not on the base branch, and not
  dated before the finding. Its diff must remove at least one token the finding names (a
  backticked span, quoted identifier or `--flag`) and must not re-add it. A finding
  with no distinctive token (generic spans like `local` or `true` do not count) fails closed unless the cited commit was produced by this pass (`tokenless-not-this-pass`). A failure logs
  `::warning::… fixed-unverified:<reason>`. The harness then re-answers with the
  branch commit whose diff removes the token, when one exists. Otherwise the next
  pass re-answers the disposition, which is not settled.
- **A maintainer clears it without dev-lead (#1910/#1918).** When dev-lead is
  suppressed, rate-limited, cancelled, or never dispatched, a maintainer can run
  [`scripts/maintainer-resolve-comment.sh`](../../scripts/maintainer-resolve-comment.sh)
  (see its `--help`). It minimizes **their own** comment `RESOLVED`, or — for a
  *registered info-status bot* whose finding-free status stranded the queue (chiefly
  SonarCloud, which re-posts `Quality Gate passed` on every push) — that bot's
  comment, requiring a `--reason` posted as a `<!-- maintainer-resolve … -->` reply
  before the minimize. It refuses another human's comment and a finding-producing bot
  such as `codeant-ai` or `graphite-app` (whose findings still require dev-lead's
  verified-fix flow), and fails closed if it cannot confirm the comment's author, its
  actor type (`__typename == Bot`), or the invoking viewer.
- **A registered clean info-status bot comment auto-clears (#1918)** — see the scope
  section above; no disposition action is needed for it.
- **Edits re-open a bot's comment (#2008).** CodeRabbit edits ONE summary comment
  in place, and it holds independently throttled outputs. Its code review can show
  a rate-limit block while its Security Architecture Review still reports findings
  (PR #2000). The edit that appended that finding came after the comment had been
  dispositioned `informational` and minimized, and nothing ever addressed it. So a
  `RESOLVED` comment by a registered reviewer bot stays cleared only while its
  latest covering disposition still holds. The covering disposition is the latest
  non-minimized `dev-lead:comment-disposition id=<node>` or
  `maintainer-resolve … id=<node>` reply from our account or a repo
  OWNER/MEMBER/COLLABORATOR. The comment re-blocks when either:
  - its `lastEditedAt` is later than that disposition's `createdAt`, or it was
    edited with no covering disposition at all; or
  - the covering disposition is `informational` but the body carries a
    finding-bearing section. Dispositioning only the notice never clears findings.

  `gh pr view` carries no edit time, so `review-one-pr.sh` merges each comment's
  `lastEditedAt` in (`maintainer_gate_merge_edit_times`). `updatedAt` is never
  used, because non-edit mutations such as minimizing move it. On the dev-lead
  side:
  - the harness unminimizes such a comment, so it is visibly open;
  - it refuses an `informational` disposition on a finding-bearing body;
  - it re-verifies a fresh disposition posted after an edit;
  - the `dev-lead-retry.sh` sweep re-dispatches a fix-reviews pass only for edits
    newer than a covering disposition (including a `maintainer-resolve` reply),
    when no successful pass has followed the edit and no other retry was
    dispatched in the same sweep. Deduplication batches CodeRabbit's progress
    edits between successful passes. dev-lead only fires on created comments,
    and the caller stub's `on:` is standards-owned.
- If you only want to *chat* (e.g. "LGTM") without requesting a change, leave an
  **approving review** rather than a plain comment — a review is not an issue comment,
  and it also positively signals "no changes needed".

### Fails closed

The [#1290](https://github.com/petry-projects/.github-private/issues/1290) /
[#1813](https://github.com/petry-projects/.github-private/issues/1813) acceptance
criterion is that an inability to determine whether a finding was addressed must
**not** read as "no findings" — that is exactly the bug that shipped the regression.
So:

- Any non-agent comment **without** a verified `RESOLVED` disposition → **blocks**
  (return 1).
- A **malformed / unparseable** PR snapshot → **fails the PR** (return 2 → exit 1),
  reported with a distinct verdict reason so an undeterminable gate state can never
  recur disguised as a legitimate hold (#1813 AC8), so a scheduled run retries rather
  than approving blind. The verdict itself makes **no** `gh`/network calls — it reuses the
  snapshot the caller already fetched — so there is no push-time lookup left to fail.
  The one best-effort network call is the edit-time lookup
  (`maintainer_gate_merge_edit_times`); its failure fails closed (below).
- A `RESOLVED` registered-bot comment whose **edit time cannot be read** (#2008)
  also fails closed (return 2). Examples: an edited comment whose `lastEditedAt`
  lookup failed, or a malformed timestamp. The gate cannot tell whether it
  changed after its disposition.

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

This is [#860](https://github.com/petry-projects/.github-private/issues/860)
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
