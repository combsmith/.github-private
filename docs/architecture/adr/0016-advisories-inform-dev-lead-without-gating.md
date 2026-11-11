# 0016. A QA Lead advisory informs dev-lead's pass without gating it

## Status

proposed

## Context

This ADR extends ADR-0005. It does not replace it. ADR-0005 makes personas
advisory by default: a persona with no write opt-in can only comment. It says
nothing about whether another agent should *act* on that comment.

Nothing did. On a dev-lead-authored PR the QA Lead posts one test-risk
advisory as the PR opens (its `pull_request` surface fires on `opened` and
`ready_for_review` only). dev-lead read none of it
([#2487](https://github.com/combsmith/.github-private/issues/2487)). On
combsmith/empower-personal-dashboard#180 the advisory named four concrete test
gaps. dev-lead's review-changes pass had run 37 seconds earlier, and no later
pass looked at the advisory. A gap the QA Lead named stayed open unless a
person picked it up.

Switching the persona's identity would not help. `dev-lead-intent.sh` acts on a
comment only from a trusted GitHub App or a trusted human's `@dev-lead`
mention. The maintainer gate puts a trusted author's `<!-- persona:` comment out
of scope (ADR-0012). The move to `donpetry-bot` was tried and discarded advisories
(#1734), which is why ADR-0008 has personas post as the owner account.

Two designs were weighed on #2487. In Option A, dev-lead pulls the advisory
through its retry cron. In Option B, the QA Lead writes the tests itself
behind a gated write mode. The Maintainer chose A. B would give the QA Lead a
write mode and a second writer on dev-lead's branch, which is the open question
ADR-0011 leaves. If B is ever proposed it needs its own ADR, and only a human
should be able to add its gate label.

## Decision

We will let a QA Lead advisory **inform** dev-lead's pass without **gating**
anything:

1. **dev-lead pulls; the persona does not push.** dev-lead's retry cron
   (`scripts/dev-lead-retry.sh`, `scan_pr_for_qa_advisories`) runs a pure
   classifier (`scripts/lib/qa-advisory-retry.sh`, ADR-0004) over the PR's
   comments. It acts on an open PR that dev-lead authored, from a
   same-repository head, with no hold label. It flags a QA Lead advisory that
   has items and no dev-lead disposition, and sends the existing
   `dev-lead-reviews-retry` event with `intent_type: review-changes`. The
   persona runner, the QA Lead's manifest and ADR-0008 are unchanged: the
   persona gains no capability and no cross-repo action.
2. **What counts as an advisory.** A comment whose body starts with
   `<!-- persona:qa-lead -->`, from a trusted author association
   (OWNER/MEMBER/COLLABORATOR, the #1921 association rule), with at least
   one bullet under "What I'd shore up". An out-of-scope note has no items and is
   not acted on. Only `qa-lead` is in scope. Other personas stay purely advisory
   until this path proves out. An untrusted author's `<!-- persona:` marker stays
   out of gate scope per ADR-0012.
3. **Disposition.** The review-changes pass posts one PR comment per advisory.
   The comment gives each item an outcome: *applied*, committed first and backed
   by one `dev-lead:claim` that the ADR-0011 claim checks verify, or *declined*,
   with a reason. It ends with a complete
   `<!-- dev-lead:advisory-disposition id=<advisory node id> outcome=handled -->` marker.
   The marker matches the maintainer gate's `dev-lead` agent marker (ADR-0012),
   so the reply is not a gate candidate. It carries no `persona:` marker and no
   persona handle, so the router's recursion guard is unchanged. A reply that
   the harness retracts, because its claimed commit did not land, does not count
   as a disposition.
4. **The bound.** A disposition from our automation, with a trusted association,
   ends the advisory: it never dispatches again. Short of a disposition, an
   advisory gets at most `QA_ADVISORY_RETRY_MAX_ATTEMPTS` (default 2)
   dispatches, each recorded by a retry marker posted before the dispatch, and
   no new one while the last is inside its pending window. The QA Lead does not
   subscribe to `synchronize`, so dev-lead's push does not produce a new
   advisory. The loop is therefore bounded at one advisory per PR open, each
   with a bounded number of passes. Bats tests pin the bound.
5. **Escalation follows `Escalate?`, not the risk tier.** On
   `**Escalate?** yes` dev-lead applies nothing and records an
   `outcome=escalated` disposition. A change to an existing test always goes to a
   human (ADR-0011 rule 4). The pass declines that item and says so. The
   escalation is recorded but never blocks merge.
6. **Never blocking.** The advisory stays out of the maintainer gate by its
   `persona:` marker (ADR-0012). A missing, failed or exhausted pass holds
   nothing: the PR's merge does not wait on an advisory.

## Consequences

- A test gap the QA Lead names on a dev-lead PR gets a recorded decision when
  one of the bounded retries produces a disposition. The decision sits on the PR,
  so it is easy to audit. An exhausted advisory (no disposition after MAX_ATTEMPTS
  retries) is dropped with only a `::warning::` in the cron log, as the advisory
  never blocks merge.
- dev-lead writes both the code and the tests the QA Lead suggests. Separation
  of duties is weaker than under Option B, where the test architect would write
  the test. A decline is only as good as dev-lead's reason, and nothing checks
  that reason mechanically. ADR-0004 keeps that judgment out of the classifiers.
- Each advisory can cost up to two extra review-changes passes, each a model
  run, plus a retry marker comment per dispatch. An advisory that two passes
  leave without a disposition is then dropped with only a `::warning::` in the
  cron log. That is deliberate, because an advisory must never hold a PR, but a
  person reading the PR sees no notice.
- The pull path waits for the 2-hourly cron, so an advisory is acted on within
  about two hours, not at once. A push from the persona runner would be faster.
  It was rejected because it would give an advisory persona a cross-repo action,
  which ADR-0005 says needs its own gate.
- The disposition marker is not signed. Any OWNER/MEMBER/COLLABORATOR posting as
  an automation login can end an advisory by hand. The same trust holds for
  every marker under ADR-0012.
- On `Escalate? yes` the advisory is recorded as escalated but never blocks merge,
  leaving the decision visible on the PR for a human to act on if they choose.
