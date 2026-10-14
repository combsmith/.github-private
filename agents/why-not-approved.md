---
name: why-not-approved
description: >
  Explains why pr-review has not approved a petry-projects pull request, and what
  would change that, by running the real pr-review gate chain read-only. Invoke on
  "why isn't PR N approved?", "what is blocking this PR?", or a PR stuck at
  REVIEW_REQUIRED with green CI.
tools: ["read", "search", "execute"]
---

# Why isn't this PR approved?

pr-review approves a PR only after a chain of gates passes, in this order: CI,
advisory-bot reviews, maintainer comments, maintainer review threads, standing
change requests, the already-reviewed-at-head check, the human-escalation hold and
cycle cap, and the per-PR automation budget. Then the model review runs and its verdict decides.
This skill finds the first gate holding the PR by running that real chain, not by
reading the PR and guessing.

## Run the diagnostic

The script lives in `petry-projects/.github-private`. If it is not in your checkout,
make a shallow clone of that repo first, through `gh` so the private repo is
authenticated: `gh repo clone petry-projects/.github-private -- --depth 1`. You need
`gh` authenticated with repo read on the PR's repository.

```bash
bash scripts/pr-approval-diagnostic.sh https://github.com/<owner>/<repo>/pull/<n>
```

It runs `scripts/review-one-pr.sh` in diagnose mode (`PR_REVIEW_DIAGNOSE=true`).
That mode is read-only and never forced, and it stops before any model runs. The
output is a Markdown report:
- what pr-review would do now (`decision` and `reason`);
- what changes that;
- dev-lead hold labels (pr-review itself gates only on `needs-human-review`);
- approvals at the head;
- the gate log.

Add `--json` for a machine-readable object.

## Explain the result

Lead with the blocking gate and the one action that clears it. The report's
"What changes that" line is the authoritative condition; restate it plainly. Only
the first holding gate is reported: say so when the user asks about others.

Common reasons:

| `reason` | What it means | What clears it |
|---|---|---|
| `ci-failing` / `ci-pending` | A required check is red or still running | Fix the check or wait for it; the sweep re-reviews |
| `waiting-for-advisory-bots` | Advisory reviewers have not all reported | Their review event re-triggers pr-review; a head-age timeout eventually proceeds without them |
| `changes-requested` | A reviewer requested changes and that review still stands | The author pushes a new commit (making that review stale), or @mentions the bot for a re-review |
| `undispositioned-pr-comment` | A PR comment has no verified disposition | dev-lead replies with a disposition and the comment is minimized RESOLVED |
| `unaddressed-maintainer-review-thread` | A maintainer review thread is open since the last push | Resolve the thread |
| `already-reviewed-at-head` | pr-review already gave a verdict at this commit | Push a commit, or change the PR metadata if the verdict was metadata-only |
| `human-escalated` | pr-review escalated to a human and `needs-human-review` is on | A human reviews and removes the label, or @mentions the bot |
| `max-cycles-reached` | Three review cycles without converging | A human removes `needs-human-review` for a fresh budget |
| `automation-budget-exhausted` | Too much automated activity since a human last acted | Any human comment or approval resets it |
| `automation-budget-unreadable` | The PR's activity could not be read (a GitHub API error) | Re-run the diagnostic |
| `gates-clear` (`proceed`) | Nothing holds the PR | The next pr-review run reviews it; its verdict decides |

If the PR is already approved but not merging, the report's merge state says why
(for example `BLOCKED` by a required check, or `BEHIND`).

## When the script cannot run

Without a checkout or `gh` credentials, look at the PR's latest pr-review run. A
run that a gate stopped records `decision / reason / would_change` in its log and
step summary (#1552, #1894). A run that reached the model review answers with the
review it posted on the PR instead: read that review. If no review appears, read
that run's log for a model or posting failure. Do not reconstruct the
gates by hand: that copy drifts from the real ones, which is why #1902's first
version was replaced.
