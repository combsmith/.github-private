# 0017. The stuck-review sweep dispatches each repo's own pr-review entrypoint

## Status

proposed

## Context

pr-review skips a PR and waits for a later event when CI is pending, an advisory
bot has not reviewed yet, or an advisory bot is rate-limited. When that event never
comes, the PR sits at `REVIEW_REQUIRED` with green CI. `pr-review-sweep.yml` in this
repository is the backstop. Its candidate list (`scripts/list-prs.sh`) already
covers every repo in the org, but until #2530 it dispatched every PR through this
repository's `pr-review-trigger.yml`. That trigger pins `pr-review/v1-next`, so a
consumer PR rescued by the sweep was reviewed with `next` code, not the code of the
channel the consumer pins (ADR-0002).

Two other defects stranded consumer PRs (combsmith/google-app-scripts#680, observed
2026-11-13):

- `list-prs.sh` puts `.github` and `.github-private` PRs first, and `MAX_DISPATCH`
  (20) ran out before any consumer repo was inspected.
- Most of those dispatches were wasted. They went to PRs held at the
  maintainer-comment gate, which writes no verdict, so the same PRs were
  re-dispatched on every tick.

The Solution Architect compared three placements on #2530: (a) a central sweep that
dispatches each repo, (b) a `schedule:` trigger in every caller stub, and (c) a
schedule inside the reusable. (c) cannot work, because a `workflow_call` reusable
owns no triggers. (b) is allowed for `pr-review.yml` stubs (ADR-0007 keeps timers
out of `agent-ingress.yml` only), but no pinned channel's reusable can handle a
scheduled run yet. It has no `pr_url`, and its concurrency key falls back to a
generic slot, so shipping (b) now would repeat the #1034 channel-skew defect. The
Maintainer adopted (a).

## Decision

We will keep one central sweep in this repository and have it dispatch each repo's
own pr-review entrypoint:

- **Routing:** this repository's PRs still go through `pr-review-trigger.yml`. A PR
  in another repo goes to that repo's active `.github/workflows/pr-review.yml`, or
  else to its active `agent-ingress.yml` (whose `workflow_dispatch` runs only its
  pr-review job). Both accept `pr_url` and `force_review`, and the review runs at
  the channel that repo pins. A repo with neither entrypoint, or whose workflow
  list cannot be read, keeps the old path through this repository's trigger.
- **Credential:** the dispatch uses the sweep's existing token (`GH_PAT_DON_PETRY`,
  else `GH_PAT_WORKFLOWS`), which needs `actions:write` on every consumer repo.
  This makes this repository a hub that can start workflow runs fleet-wide. That is
  the trust boundary this ADR records. The hub only ever dispatches a repo's own
  pr-review entrypoint, with `pr_url` and, for the orphaned-marker rescue only,
  the narrow `force_review` idempotency bypass.
- **Budget:** candidates are taken round-robin across repos. A PR that the
  maintainer-comment gate would hold is not dispatched. The sweep runs the same
  `check_maintainer_comments` that `review-one-pr.sh` runs first, and only a
  definite hold (rc 1) skips. An undeterminable result still dispatches, and the
  review decides.
- **Measurement:** every run reports the GraphQL and REST points it spent, and its
  dispatches per repo, in the log and the job summary.

`ROUTE_TO_REPO_ENTRYPOINT=false` and `SKIP_GATE_HELD=false` restore the old
behaviour, one switch each.

## Consequences

- A consumer PR rescued by the sweep is reviewed by the code its repo pins, so a
  ring promotion governs sweep-driven reviews too.
- The dispatch cap is spent on PRs that can progress, and no single repo's backlog
  can use all of it.
- PRs held at the comment gate are no longer re-reviewed each tick. Nudging dev-lead
  to answer their comments falls to `dev-lead-retry.yml`'s bot-comment scan alone,
  which runs every two hours. Once the gate clears, the next sweep dispatches the
  PR.
- The cron still fires only every few hours under load (#1952). Deadline-armed
  retries for the advisory-bot and rate-limit waits are #2533. A `schedule:` stub
  trigger becomes the better choice if every pinned channel's reusable gains a
  scheduled mode, or if the sweep's org-wide reads become the main quota cost.
