# Architecture review: the agentic factory, POC to MVP

**Status:** Draft — for maintainer review
**Date:** 2026-10-10
**Reviewed at:** commit `aef61164` (`main`)
**Lens:** Solution Architect persona (`personas/solution-architect/`), run locally for a whole-system review
**Companions:** [PRD](../prd/agentic-software-factory.md) ·
[ADR-0012 (proposed)](./adr/0012-factory-mvp-reference-architecture.md)

## 1. Summary

**The POC proved every function of the factory and has stopped converging.** In the last measured
week the hosting repo ran at least 44,968 workflows to merge 30 pull requests. Merges per week have
been flat since August while median time to merge rose from about one hour to between twelve and
twenty-two. No open pull request in the org holds an approval, and a third of recent merges had no standing
approval when they merged. Bug-labelled issues have risen from under ten a week to between twenty and thirty-six.
Eight fixes moved a failure somewhere else instead of removing it (§2.4).

**Seven structural causes explain the eleven recurring failure classes** (§4). Each is a decision the
POC never made once, so it was made many times, locally:

1. Work-item state is implicit: labels and about eighty kinds of comment marker, with no declared
   lifecycle.
2. Work is carried by events and concurrency slots on a platform that drops both, and nothing admits
   runs in one place.
3. The model holds the write credential and reports on its own work.
4. Agents act as the maintainer: one account, one credential, one API quota.
5. There is no single unit of release, and one fact is written in up to eight places across two
   repos.
6. An approval is bound to a commit hash, can be withdrawn by five independent gates, and one merge
   touches every open pull request.
7. Verification does not bind: the test suite, the validators and the evals block nothing.

**Recommendation: restructure on GitHub Actions around a declared control plane, one run contract
and one release** (§7), recorded as ADR-0012. A level-triggered Controller reconciles each work item
from recorded state, so a lost event delays work instead of deleting it. Every role in scope for the MVP
runs under one contract in which the model requests effects and a separate job applies them. Agents write through
a GitHub App and the owner account becomes the human's alone. Everything ships as one release on one
gated path. No always-on infrastructure is added, and the decision logic is written so that it could
later run behind a hosted control plane unchanged.

**The strongest argument against it** is that it keeps GitHub Actions as the queue and the timer,
which is the substrate behind the second-largest failure class, and bets that reconciling from
recorded state makes loss harmless. It is also a rewrite of the core in a second language, built
largely by the agents it replaces, on a line that is already overloaded (§7.5).

**What should be kept** is listed in §3.7. The release-tag mechanism, self-hosting safety, personas
as data, the read/write split in the persona runner, the push guards and the ADR practice all carry
over.

**The first two steps deliver value alone** (§8). Step 0 is configuration only: stop updating
branches that do not conflict, try the deeper concurrency queue GitHub now offers, pin the model
CLI, and make verification a required check. Step 1 runs the new decision logic read-only on every
repo, puts one status block on every work item, and produces the measurements the PRD's targets
need.

**An adversarial pass then attacked the recommendation** (§14), and a comparison with seven other
systems tested it from outside (§13). Three findings changed the proposal:

- **The architecture does not raise the ceiling.** Output is bounded first by how many changes the
  maintainer can audit and merge by hand, about 30–36 a week in the hosting repo, and then by how
  often a change is right the first time. The proposal removes waste under the machine limits. The
  PRD's 85% autonomy target and its defect target cannot both be met on current correctness.
- **The largest failure class is mostly policy.** Approvals fail to issue chiefly because every
  comment from nine third-party reviewers needs a verified disposition. Narrowing what gates an
  approval would likely do more for that class than the rewrite, and can be tried in weeks.
- **Two mechanisms were a bet.** Every comparable orchestrator polls from one standing process and
  keeps state it can rebuild. Files in git as a work ledger is a design another project abandoned.
  Both are now provisional in the ADR, with thresholds, and step 1 runs the same logic under a
  poller for comparison.

The same pass found that the migration is the likeliest thing to fail: holding the POC still needs
more fix pull requests a week than the line delivers. The ADR now requires a dated limit, a defect
policy and a kill criterion before it is in force.

**The maintainer's core hypothesis is convergence**: that a council of models, tools and
perspectives produces a better outcome than one agent alone. The first draft did not evaluate it.
§15 does. The evidence supports it under conditions: an independent evaluator beats
self-evaluation, and Lenses that can see different things find different defects; but a council
that converses does worse than one that reports, a council that co-writes does worse than one
author, and a weaker reviewer makes a stronger author's work worse. The POC has run a large council
for months through free-text discussion and cannot say what any member contributed. ADR-0012 now
gives every Lens, third-party reviewers included, one structured contract, decides convergence in
the Kernel, and measures each Lens before any is added.

**Decisions this asks of the maintainer** are in the PRD, §11. The three that shape everything else:
whether agents move off the owner account, whether the POC is frozen for features while it is
replaced, and what the migration may cost. A fourth was decided on 2026-10-10: third-party
reviewers are integrated through a contract, and comment bodies gate nothing.

**It will be built in a new repo and cut over through the existing channel tags** (§18). Building in
place would put every factory change through the POC's own line, which is the thing that is
failing. A literal swap is not available, because GitHub does not redirect reusable-workflow
references. The hybrid builds greenfield, runs read-only against real traffic from its first weeks,
and switches one intent and one ring at a time by moving a tag.

**Which reviewers have a contract** is answered in §16. Of the nine installed, SonarQube Cloud has a
full one, and the POC reads its comment instead; cubic has a findings API; CodeRabbit has a
structured verdict; the rest offer review threads or nothing. No LLM reviewer's severity is
readable without parsing a comment body. §16.6 proposes a council to start measuring from: six
deterministic and execution-grounded Lenses on one contract, the in-house reviewer, and three or
four of the nine outside reviewers.

Fifteen defects found in passing are listed in §12. They are worth fixing whatever is decided.

## 2. Evidence base

### 2.1 Sources and method

Four read-only passes were made over the repo and its telemetry, each producing claims tagged
*verified* (the code or data was read) or *inferred*:

1. **Execution harness** — everything between "a job decided an agent should run" and "its output
   was applied": `scripts/engine.sh`, `scripts/lib/`, the dev-lead, pr-review and persona runners.
2. **Interaction model and control plane** — `docs/agentic-interaction-model.md`, the interaction
   contracts, the ingress and repair workflows, the gates.
3. **Distribution and assurance** — release tooling, the standards repo `petry-projects/.github`,
   evals, tests, validators.
4. **Telemetry and issue history** — in-repo reports, 600 issues and 400 pull requests from the
   hosting repo, 300 issues from the standards repo, seven days of workflow runs, the org-wide open
   pull-request backlog.

The ADR corpus (ADR-0000 to ADR-0011), the interaction-model standard and the operating rules in
`AGENTS.md` were read in full. The highest-consequence claims were re-checked against the code and,
for the branch ruleset, against the live API.

Citations are `path:line` at the reviewed commit. A `DG:` prefix marks a path in the standards repo,
`petry-projects/.github`, at commit `3cd1511f`. Issues are cited as `repo#number — title`.

### 2.2 Limits

- **Shared identity hides the human.** dev-lead, the advisory personas, interactive sessions and the
  maintainer all act as `don-petry`. Every non-Dependabot pull request in the sample is authored and
  merged by that account. "Agent-authored" is inferred from the branch prefix. No measurement of
  human intervention is exact; the figures given are bounds.
- **Run counts are floors.** The runs API caps a count at 2,500 per query. Per-workflow rates come
  from a 2,730-run sample that under-represents bursts.
- **Issue classification is by title pattern.** Classes overlap. Counts show relative frequency.
- **Consumer repos were not inspected live.** Local checkouts are twelve weeks old. Statements about
  what consumers pin come from in-repo documents dated 2026-09-29 or later.
- **Channel-tag facts are from local tags** fetched 2026-10-10, not from the remote at query time.
- **Not measured:** runner minutes; cost per merged change; review quality (the scorecard's miss
  rate reads 0 of 0); the cause of 410 failed runs.

### 2.3 Failure classes

Classification of 203 defect and process-gap issues in the hosting repo and 117 in the standards
repo. "Last 4 / prior 4 / 4 before" are four-week windows ending 2026-10-11.

| Class | Hosting repo (open) | Last 4 / prior 4 / 4 before | Standards repo (open) | How it has been handled |
|---|---:|---|---:|---|
| A. Approval never issues, or issues and is withdrawn | 63 (20) | 45 / 17 / 1 | 6 (2) | Patched gate by gate; the next gate then failed |
| D. Work dropped between event and agent | 47 (19) | 31 / 16 / 0 | 17 (5) | Sweeps and retries, which suffer the same loss |
| B. Status reported but not real | 37 (15) | 18 / 16 / 3 | 14 (8) | Verifiers on agent output, which produced their own deadlocks |
| E. Quota and budget exhaustion | 33 (17) | 24 / 8 / 1 | 6 (3) | Control built, closed as done, cannot fire |
| C. Merged fix is not what runs | 25 (12) | 13 / 9 / 3 | 72 (33) | Manual override promotions |
| F. Identity, credential, permission | 21 (8) | 9 / 6 / 4 | 3 (0) | Relocated three times |
| G. Re-review churn, rebase treadmill, runaway | 17 (5) | 11 / 6 / 0 | 4 (2) | Per-pull-request caps; cross-pull-request cost unbounded |
| I. Human steering does not reach the agent | 14 (5) | 8 / 6 / 0 | 12 (4) | Partly fixed; the working recipe is procedural |
| J. Tests and evals not measuring the real thing | 14 (7) | 7 / 5 / 2 | 16 (6) | Case by case |
| K. Automation that corrupts or destroys | 13 (6) | 7 / 5 / 1 | 8 (4) | One required-check guard; variants recur outside its scope |
| H. Timeout loses the work | 9 (7) | 2 / 7 / 0 | 3 (3) | Checkpoint push exists; resume does not |

Every class except H grew in the most recent four weeks. Representative issues per class:

- **A.** `petry-projects/.github-private#1894 — 10 of 11 open PRs have never received an approving
  review`; `#1933 — pr-review never re-approves after dismissing its own approval`; `#2166 —
  Edited-after-disposition deadlock`.
- **D.** `petry-projects/.github-private#1741 — [bug] 42% of dev-lead runs are cancelled before
  doing any work`; `#2017 — A lost fix-bot-comment run is never retried`; `#2170 — Retry and sweep
  crons run every 4–8 hours instead of every 2 h / 15 min`.
- **B.** `petry-projects/.github-private#1620 — dev-lead merges zero-diff PRs that close their
  issues`; `#1874 — pr-review announces an approval it never created`; `#2013 — dev-lead
  fix-reviews: posts "Fixed" replies for changes that were never pushed, and edits tests to match
  its own code`.
- **E.** `petry-projects/.github-private#1565 — Auto-pause companion: usage-telemetry adapter +
  scheduled poller`; `#1862 — check_provider_headroom has never worked`; `#2197 — The fleet and
  every session share one GitHub API quota`.
- **C.** `petry-projects/.github-private#1592 — Script-only changes never reach the fleet`;
  `petry-projects/.github#1125 — Fleet pr-review callers pin legacy bare pr-review/stable and are
  unmanaged`; `petry-projects/.github#1086 — Gate soak is vacuous`.
- **F.** `petry-projects/.github-private#1415 — [Phase 4] Close the maintainer review-gate gap`;
  `#1734 — persona-runner: qa-lead advisory lost`; `#2027 — dev-lead silently ignores @dev-lead
  mentions from the maintainer, because the maintainer's account is dev-lead's own identity`.
- **G.** `petry-projects/.github-private#1864 — Merge protections are unsatisfiable at N>1 open
  PRs`; `#1881 — auto-rebase still merges main into every open PR on every push`.

### 2.4 Fixes that relocated the failure

| Fix | What it resolved | Where the failure moved |
|---|---|---|
| Channel tags and rings (June–July) | Unversioned consumers; an agent could break its own merge gate | Merged fixes do not run; rings with no members; manual overrides |
| Restrict auto-rebase to review-ready pull requests (June) | Fan-out from 170–220 runs a day to about 6 | Reversed in August to fix approval currency; fan-out back by September |
| SHA-keyed concurrency (August) | 49% pr-review cancel rate | 37% on pr-review and 42% on dev-lead |
| Maintainer-comment disposition gate (September) | Unanswered maintainer comments merging | Gate blocks on bot notices, the agent's own acknowledgements, edited summaries |
| Claim verification guards (September–October) | False "applied" and phantom "Fixed" | Guards refuse legitimate pushes, loop, or retract real fixes |
| Persona posting identity (September) | Advisories under the owner credential | HTTP 403 on the bot credential; reverted to the owner account |
| Drop the strict up-to-date rule (2026-09-21) | Pull requests stuck behind `main` | Auto-rebase kept merging `main` into every open pull request (`petry-projects/.github-private#1881 — auto-rebase still merges main into every open PR on every push`); the compliance audit now reports the change as drift (`petry-projects/.github#1265 — Compliance audit — 2026-10-09`) |
| Budget breaker epic (closed 2026-09-07) | Nothing | Breaker unreachable; poller credential refused |

Genuine reductions: hard failures are 0.9% of runs against 100% failure streaks in April
(`docs/pr-review-agent/failure-report.md`); the self-mention loop behind the PR 860 runaway has not
recurred (`docs/postmortems/2026-06-pr-860-runaway.md`); no trunk corruption since
`duplicate-decl-gate` became a required check.

## 3. Current-state findings

### 3.1 What the system is

A set of LLM agent roles hosted on GitHub Actions and delivered to consumer repos through caller
stubs that pin reusable workflows by channel tag.

| Fact | Value |
|---|---|
| Repos served | 12, all public |
| Shell in `scripts/` | 182 files, about 53,400 lines, 1,107 functions |
| Workflow YAML | 62 files, about 10,200 lines, of which about 1,960 are inline shell |
| Tests | 229 bats files, about 69,600 lines, about 4,940 cases |
| Scheduled workflows | 22, with 24 cron expressions |
| Roles | 9 persona manifests, all `status: draft`, including the two that run fleet-wide |
| Secrets referenced | 18 names; `GH_PAT_DON_PETRY` 70 times |
| Third-party review bots tracked | 9 |

The system spans two repos. The hosting repo holds the runtimes, scripts, prompts, personas and
evals. The standards repo holds the mention routers, the ring registry and the release manager that
govern them (`AGENTS.md:955-961`). A persona behaviour change can need a pull request in each: the
router in the standards repo reads persona manifests from the hosting repo's `main` and dispatches
back to it.

### 3.2 Control plane: no declared lifecycle, and the machinery that compensates

**No file states the lifecycle of a work item.** What is declared is narrower: trigger classes per
workflow (`docs/agentic-interaction-model.md:185-224`), dev-lead intents
(`scripts/dev-lead-intent.sh:9-19`), and pr-review verdict reasons as free strings
(`scripts/review-one-pr.sh:333` and eleven further sites). The actual state of a pull request is a
tuple of labels, HTML-comment markers, review objects, review decision, check rollup, head commit,
minimized-comment state and merge-queue membership, recomputed from the API by each script on each
run. Transitions are spread across workflow `if:` expressions, the intent classifier and about
twelve sequential gates in `review-one-pr.sh`.

Consequences that follow directly:

- **Markers are the state store, with no schema.** About 58 to 80 distinct marker prefixes exist.
  The only registry is one prefix regex (`scripts/lib/maintainer-comment-gate.sh:74`). A marker can
  outlive the object it describes, which is why `scripts/lib/standing-approval.sh:2-15` exists.
- **Approval is a conjunction, not a state.** It is a non-dismissed review by the bot at the head
  commit *and* a marker. Five gates can each withhold or dismiss it.
- **Releasing a hold is not an event.** dev-lead's stub has no `unlabeled` trigger and pr-review
  subscribes to no label events (`.github/workflows/pr-review-trigger.yml:27-53`). A released hold
  takes effect on the next unrelated event.
- **One label has four meanings.** dev-lead stops on `needs-human-review` unconditionally
  (`scripts/lib/hold-gate.sh:32`). The pr-review cascade stops only if an escalation marker is also
  present (`scripts/review-one-pr.sh:927-941`). The sweep stops unless the hold is rate-limit-only.
  The initiative driver never releases. `AGENTS.md:71-88` documents this as a rule for operators.
- **The pause switch pauses one role.** `AGENTS_PAUSED` appears in three `if:` lines, all in
  `dev-lead-reusable.yml` (`:116`, `:642`, `:748`). `pr-review.yml:344` tells operators to use it
  and does not read it.

**Concurrency groups are the work queue, and the queue holds one item.** GitHub keeps one running
and one pending run per group; a third arrival evicts the pending one. Both main agents document
this (`.github/workflows/dev-lead-reusable.yml:76-85`; `.github/workflows/pr-review.yml:138-144`).
Fan-in makes it routine: one `issue_comment` starts three agentic workflows; one submitted review
starts four. A dev-lead run killed before posting its marker is never retried, because the retry
scan reads the absence of a failure marker as "nothing failed"
(`scripts/dev-lead-retry.sh:1307-1311`).

**Fifteen workflows exist to retry, sweep, repair, audit or detect**, against twenty-eight that do
primary work. In the dev-lead and pr-review loop the ratio is twelve to seven. Each stands in for an
invariant the primary flow does not hold:

| Compensating workflow | Missing invariant |
|---|---|
| `pr-review-sweep.yml` | A skipped review is not re-armed when the reason for the skip clears |
| `pr-review-delayed-retry.yml` | There is no durable timer; a runner sleeps until the rate-limit reset |
| `dev-lead-retry.yml` (four scans) | Work is not queued; a failed, rate-limited or evicted run is gone |
| `dismiss-stale-bot-reviews.yml` | A blocking review is not bound to the commit it reviewed |
| `repair-pr-approvals.yml` | Announcing an approval and creating it are not atomic |
| `auto-rebase-retry.yml` | A failed run leaves no signal for anything to retry |
| `auto-rebase-health.yml` | The trigger is an unindexed comment sentinel |
| `daily-pr-review-health.yml` (runaway, stall, merge-ready scans) | Loop bounds are not trusted; no liveness guarantee; approved does not imply merged |
| `premature-closure-audit.yml` | "Done" is asserted by a comment, not derived from a merge |
| `actions-fleet-monitor.yml` and the stub-drift tools | Control-plane configuration is distributed by copy |
| `engine-token-liveness.yml` | A run without a token can exit successfully having done nothing |
| `pr-review-canary.yml`, `initiative-driver-canary.yml`, `initiative-planner-canary.yml` | Merged code is inert until a tag moves; breakage is found on real work |
| `budget-poller.yml` | Capacity is not checked before a run starts |

A further twenty-five or so scripts and libraries do the same inside primary workflows:
`carry-forward.sh`, `self-dismissed-approval.sh`, `verify-approval-review.sh`,
`merge-queue-dequeue.sh`, `claim-landing.sh`, `addressed-claim-verify.sh`, `rebase-exhaustion.sh`
and others.

**The authoritative loop bound cannot see the main writer.** The per-pull-request automation budget
counts bot events since the last human event. A login is a bot if it ends in `[bot]` or is one of
`donpetry-bot`, `github-actions[bot]`, `repair-pr-approvals`
(`scripts/lib/pr-automation-budget.sh:32`). dev-lead commits and comments as `don-petry`
(`personas/dev-lead/persona.yml:107-109`). Its activity therefore classifies as human and resets the
count. No workflow overrides the list. The interaction model calls this budget authoritative and
states the rule it implements: a cap whose reset is reachable by the runaway is not a cap
(`docs/agentic-interaction-model.md:421-422`). The consequence is inferred from the code and was not
observed in a run.

**The validators check event names, not behaviour.** They cannot see `if:` logic, the intent
classifier, payloads, or whether a stop marker is read. `pr-review:hands-off` is a declared stop
marker (`interaction-contracts/pr-review.yml:65`) that no code in this repo reads. Eighteen
declared-versus-deployed divergences were found, including: ADR-0007 is accepted and this repo has
no `agent-ingress.yml`, so `scripts/validate-ingress-if.sh:34-37` passes vacuously; the interaction
model's row for `initiative-planner.yml` says it cannot subscribe to `discussion: labeled` while the
workflow does (`.github/workflows/initiative-planner.yml:61-62`); dev-lead's `pull_request` surface
is declared advisory (`personas/dev-lead/persona.yml:64-68`) while those events route to an intent
that can commit and push (`scripts/dev-lead-intent.sh:432`, `:450`).

### 3.3 Execution harness: five runtimes and a credential in the model

**There are five ways an LLM is invoked.** `scripts/engine.sh` serves dev-lead, pr-review,
spec-drift and the evals. Personas call `claude --print` directly from workflow YAML
(`.github/workflows/persona-runner-reusable.yml:374`), as does the CI failure analyst
(`.github/workflows/ci-failure-analyst-reusable.yml:162`). Eight scripts call it directly from bash
(for example `scripts/aw.sh:365`). The initiative planner and idea triage use
`anthropics/claude-code-action` (`.github/workflows/initiative-planner.yml:246`). The pinned `gh-aw`
is used only to compile-check; `scripts/aw.sh` is a 586-line local reimplementation that serves one
workflow.

Duplication follows from that: the cross-provider fallback loop exists twice
(`scripts/engine.sh:2082-2267`; `scripts/review-batch.sh:379-404`); the rate-limit pattern has five
independent definitions; the Claude Code install block appears fourteen times; prompts are assembled
by four different mechanisms. One of them is demonstrably wrong: the analyst's template passes
through unscoped `envsubst`, which blanks the shell variable the prompt tells the model to use, so
the model is told to run `gh run view ""`
(`.github/workflows/ci-failure-analyst-reusable.yml:115-117`, `:159`).

**In the two busiest roles the model holds a write credential.** dev-lead's job sets the owner
credential for the whole job (`.github/workflows/dev-lead-reusable.yml:173`) and the checkout
persists it for `git push`. pr-review's tool-using tiers run with a classic `repo`-scoped token
(`.github/workflows/pr-review.yml:174-178`). "Never push" and "never resolve a thread" are prompt
text (`prompts/dev-lead/fix-reviews.md:58`, `:115-117`). The repo's own comments say what that is
worth: "a boundary that lives solely in the model prompt is not a boundary"
(`scripts/engine.sh:1843-1845`).

The cost of that choice is visible in the code. The function that invokes the model in
`scripts/dev-lead-fix-reviews.sh` is 54 lines (`:152-205`) of a 3,989-line script. Most of the rest
verifies, attributes and retracts what the model did with its own write access:
`resolve_dispositioned_comments` alone is 473 lines (`:1533`).

The persona runner is the exception and the model for the rest. The model gets a read-only token and
prints between sentinels; the wrapper is the only writer, enforces the marker and keeps the paid
output as an artifact if posting fails (`.github/workflows/persona-runner-reusable.yml:14-21`,
`:128-140`). Issue triage does the same with a separate job holding the write permission.

**Resource governance is mostly inert.** The proactive Claude headroom probe needs
`ANTHROPIC_API_KEY`, which no workflow supplies, so it logs "usage 0% — ok" on every call
(`scripts/engine.sh:500-517`, `:591`). Every Gemini cap ships as `unknown`
(`scripts/lib/gemini-quota-caps.tsv`). The budget poller is dry-run by construction
(`.github/workflows/budget-poller.yml:8-10`) and its credential is refused. Nothing checks capacity
at the point a run is admitted. Token metering records only calls that succeeded
(`scripts/engine.sh:1801`, `:1962`), in three workflows, and attributes the wrong model after an
in-chain fallback (`:1740-1745`).

**Complexity.** Seventeen functions exceed 150 lines. `scripts/review-one-pr.sh` has 1,025 lines of
top-level code that cannot be called as a unit. Control flow rides on overloaded exit codes (2, 3,
4, 55, 100, 101, 124). GNU-only constructs are on the hot path (`date -d` at 49 sites), and the
suite cannot run on stock macOS (`AGENTS.md:174-181`). The design rationale lives in code comments:
`scripts/dev-lead-fix-reviews.sh` cites 48 distinct issue numbers.

### 3.4 Identity: one account, three kinds of actor

The owner account is the maintainer, dev-lead, and all eight advisory personas (ADR-0008). pr-review
is the machine user `donpetry-bot`. No agent uses a GitHub App installation token; the two Apps in
use serve Dependabot rebasing and project boards.

What this costs, each verified in code or in an issue:

1. The maintainer cannot review dev-lead's pull requests. GitHub rejects an approval or a change
   request on one's own pull request (`docs/agentic-interaction-model.md:719`).
2. The router cannot exclude agent output by actor, so an HTML marker is the sole mechanical
   recursion guard for personas (ADR-0008, Consequences).
3. dev-lead cannot tell its own replies from the maintainer's by login and needs a `PATH`-shimmed
   `gh` to attribute them (`scripts/lib/claim-landing.sh:115-170`).
4. The automation budget cannot count dev-lead (§3.2).
5. dev-lead ignores the maintainer's mentions as self-comments (`petry-projects/.github-private#2027
   — dev-lead silently ignores @dev-lead mentions from the maintainer`).
6. The fleet and the maintainer's own sessions draw on one API limit, which ran out on 2026-10-10
   (`petry-projects/.github-private#2197 — The fleet and every session share one GitHub API quota`).
7. No measurement can separate what a human did from what an agent did (§2.2).

The interaction model, §12.2, weighed giving dev-lead a distinct identity and rejected it in August
on four grounds: code-owner and ruleset changes, a wider credential surface, churn in identity
resolution, and that a marker would still be needed for other automation posting as the owner. Items
2, 4, 5, 6 and 7 above were found after that analysis.

### 3.5 Release, distribution and assurance

**Two opposite release regimes coexist.** A change to dev-lead or pr-review is inert until a channel
tag moves (`AGENTS.md:25-33`). A change to a persona prompt or manifest is live for every repo that
reaches the router the moment it merges, with no ring, soak or gate:
`.github/workflows/persona-runner.yml:39` calls the runtime by local path and the checkout takes no
ref. `AGENTS.md:41-43` tells authors that a change under `prompts/` or `personas/` rides the next
autocut, which is not true for the shared persona runtime.

**The version name is per agent; the version is the whole repo.** A release tag points at a
whole-repo commit (`docs/release/versioning.md:26-28`), and autocut cuts an agent whenever any file
under `scripts/`, `prompts/` or `personas/` changes. In thirty days, 116 commits to `main` produced
46 dev-lead, 32 pr-review and 40 ci-failure-analyst releases. ADR-0006 drew the conclusion for
personas: per-persona tags "never delivered isolated rollback either — they only appeared to." The
same holds for per-agent tags. dev-lead majors 2 to 138 have exactly one release each, so "pin once"
does not survive a major. Workflow and scripts version together only because each stub writes the
tag twice, as `uses:` and as `agent_ref:`; `agent_ref` defaults to `main` when omitted
(`.github/workflows/dev-lead-reusable.yml:11-17`).

**Promotion reads the signal the operating rules call unreliable.** The gate samples workflow run
conclusions. `AGENTS.md:48-55` says agents report success for work they did not do and instructs
operators to confirm the artifact. At the snapshot all four dev-lead channels pointed at one commit
and all four pr-review channels at another, and the gate had been overridden by hand on four dates
in ten days. `ci-failure-analyst/v1-stable` is 322 commits behind `main` while this repo's own stub
pins it.

**One fact is written in many places.** "Which agents exist" appears in at least eight places across
two repos, and they already disagree: `scripts/cut-release.sh:70-89` lacks three registered agents.
A persona's trigger surface is written in up to eight places; the commit that subscribed one stub to
one event changed eight files. Thirty-odd validators exist largely to keep such copies in agreement.
Giving qa-lead a `pull_request` surface took 32 days and at least six pull requests across two
repos, and the surface is still served twice (ADR-0009).

**Nothing in the assurance chain blocks.**

- The live ruleset on `main` requires five checks: SonarCloud, CodeQL, AgentShield,
  dependency-audit and `duplicate-decl-gate`. `Lint`, which runs the bats suite and every validator,
  is not among them. The interaction model describes itself as "CI-verified, not review-verified"
  (`docs/agentic-interaction-model.md:574-577`); CI does verify it, and a failure blocks nothing.
- `scripts/evals/score-gate.sh` runs only under `continue-on-error`
  (`.github/workflows/skill-eval-report.yml:204`). The comment says the hard bar is enforced at
  release-cut time; `scripts/cut-release.sh` does not reference it.
- The eval sets for dev-lead and pr-review score their mention-advisory prompts
  (`scripts/evals/run-eval.sh:126-147`). The flows that write code and approve pull requests have no
  eval.
- Four bats files run in no workflow. The bats list in `lint.yml` is maintained by hand, and
  `scripts/run-bats.sh:5-11` warns and skips a listed file that does not exist.
- Many tests stub `gh` with a shim that returns post-filter output or accepts any flags, so the
  script's real flags and filters are not exercised.

### 3.6 Decision coverage

| ADR | Status | State in this repo |
|---|---|---|
| ADR-0001 thin caller and reusable | accepted | In force; several "stubs" are not thin |
| ADR-0002 channel tags and rings | accepted | In force for three agents; not for personas or hub workflows |
| ADR-0003 rubric registry | accepted | In force |
| ADR-0004 pure logic and bats | accepted | Followed at function level; not at script level (§3.3) |
| ADR-0005 advisory by default | accepted | Declared; the `gate_label` is not enforced by code |
| ADR-0006 personas not ring-registered | accepted | In force; its own validator contradiction is unresolved |
| ADR-0007 one ingress per repo | accepted | Not deployed here; one consumer pilot |
| ADR-0008 personas post as owner | accepted | In force |
| ADR-0009 qa-lead surface via router | accepted | Transitional; served twice |
| ADR-0010 ingress concurrency | accepted | Tooling for a file this repo does not have |
| ADR-0011 write-mode on a shared branch | proposed | Implemented ahead of acceptance |

Most load-bearing behaviour has no ADR. No recorded decision governs: state kept in labels and
markers; concurrency groups as the work queue; the shared owner identity (decided in a document
section, not an ADR); the automation budget; the hold taxonomy; the pause switch and its scope; the
break-glass; the maintainer-comment gate; merge-queue adoption (the decision record says deferred
and the queue is on); approval carry-forward; the org cap on automation pull requests.

### 3.7 What is solid

These are worth keeping as they are. Each is specified, tested and has held up.

- **Immutable release tags plus moving channel tags under a ruleset**, moved through one API path by
  an App identity (ADR-0002; `scripts/cut-release.sh:43-52`).
- **Self-hosting safety**: this repo's merge gate runs a promoted channel, enforced by a test that
  parses the pin (`docs/release/versioning.md:81-95`).
- **Persona as data on a shared runtime** (ADR-0006): a new advisor is about nine data files in one
  pull request.
- **The read/write split in the persona runner** and the staged, allow-listed apply in issue triage.
- **The schema-validated plan with an LLM-free applier** in the initiative planner
  (`scripts/initiative-planner/plan.schema.json`, `apply-plan.sh`).
- **Push safety**: `push_no_clobber` and the push-landed read-back
  (`scripts/lib/git-push-guard.sh`, `scripts/lib/claim-landing.sh`).
- **Small post-hoc guards on a model's diff**: net-diff, test-tamper, test-regression.
- **Engine configuration as tables**: tier-to-model chains with a lint against pinned versions
  (`scripts/lib/engine-models.sh`, `scripts/check-model-pins.sh`).
- **ADR-0004's pure-function discipline and the fail-loud rule**, with 1.46 lines of test per line
  of script.
- **The ADR practice itself**: each record names a boundary a check can assert and is honest about
  cost.
- **The seven rules from the PR 860 postmortem** (`docs/agentic-interaction-model.md` §7).

---

## 4. Root causes and the decisions they force

The eleven failure classes in §2.3 are not eleven problems. Seven structural causes explain them.
Each is a decision the POC never made, so it was made many times, locally, in different ways. Where
no ADR governs a cause, that is stated: this section does not treat preference as recorded doctrine.

### 4.1 The seven causes

| # | Root cause | Evidence | Governing ADR today |
|---|---|---|---|
| RC1 | **Work-item state is implicit.** No file declares the states or transitions. State is a tuple recomputed by each script from labels, about eighty marker shapes, review objects, checks and the head commit. | No lifecycle file (`docs/agentic-interaction-model.md:185-224` declares trigger classes only). Marker grammar is "the `printf` that writes it and the `grep` that reads it"; the only registry is one regex (`scripts/lib/maintainer-comment-gate.sh:74`). "Is this item held?" has seven implementations with different label sets (`scripts/lib/hold-gate.sh:22-34`, `scripts/review-one-pr.sh:928`, `scripts/lib/pr-automation-budget.sh:96-104`, `scripts/qa-lead-advisory-gate.sh:32,75`, `scripts/pr-stall-detect.sh:57`, `scripts/initiative-driver.sh:75-76`, and the cross-repo router). | None on record. |
| RC2 | **Work is carried by events and concurrency slots on a platform that drops both.** A request exists only as a queued run. Nothing admits runs in one place, so capacity is discovered by failing. | "A queued run superseded in its concurrency lane is dropped with zero steps" (`.github/workflows/dev-lead-reusable.yml:76-85`; `.github/workflows/pr-review.yml:138-144`). A killed issue run leaves no marker and the retry scan reads that as nothing to do (`scripts/dev-lead-retry.sh:1307-1311`). Cron fires every 3–7 h instead of 15 min (`.github/workflows/pr-review-sweep.yml:15-18`). No admission-time reader of the budget feed exists (`scripts/dev-lead-retry.sh:168-288` is the only consumer). Fifteen workflows compensate (§3.2). | None. The interaction model §§5–6 is normative but not an ADR. |
| RC3 | **The model holds the write credential and reports on its own work.** Five runtimes, four prompt-assembly mechanisms, seven return channels; in the two busiest roles the harness polices claims after the fact. | dev-lead: owner PAT in the job environment, tools `Bash,Read,Write,Edit,…` (`.github/workflows/dev-lead-reusable.yml:173`; `scripts/engine.sh:1915-1916`). pr-review: a classic PAT with `repo` visible to tool-using tiers (`.github/workflows/pr-review.yml:174-178,442`). The function that invokes the model is 54 lines of a 3,989-line script (`scripts/dev-lead-fix-reviews.sh:152-205`); claim verification alone is 627 lines (`scripts/lib/addressed-claim-verify.sh`). | ADR-0005 (write is opt-in) and ADR-0011 (proposed) govern behaviour around the write. Nothing governs where the credential sits. |
| RC4 | **Agents act as the Maintainer.** One account is the human, dev-lead and eight personas; one PAT serves seven purposes; one API quota serves the fleet and every session. | `personas/dev-lead/persona.yml:107-109`; ADR-0008. The loop ceiling classifies by login, so dev-lead's own activity counts as human and resets it (`scripts/lib/pr-automation-budget.sh:32,54-59`). Replies need a PATH-shimmed `gh` to be attributed (`scripts/lib/claim-landing.sh:116-120`). `petry-projects/.github-private#2197 — The fleet and every session share one GitHub API quota (don-petry, 5,000/hour) and the fleet alone uses about that much: it ran out on 2026-10-10 and failed a workflow`. | ADR-0008 (accepted) and interaction model §12.2 decided this deliberately. |
| RC5 | **There is no single unit of release, and one fact is written in many places across two repos.** dev-lead and pr-review changes are inert until a tag moves; persona prompts, manifests and hub workflows are live at merge. | `AGENTS.md:25-33` against `.github/workflows/persona-runner.yml:23-24,39`. The tag name is per agent but points at a whole-repo commit (`docs/release/versioning.md:26-28`). "Which agents exist" is written in at least eight places and a persona's trigger surface in up to eight (§3.5); subscribing one stub to one event changed eight files (commit `49770289`). Promotion reads run conclusions (`DG:scripts/canary-rollout.sh:31-35`). | ADR-0001, 0002, 0006, 0007. They conflict in effect: 0002 gates reusables, 0006 exempts personas. |
| RC6 | **An approval is bound to a commit hash and can be withheld or dismissed by five independent gates; one merge touches every open pull request.** | Twelve sequential gates (`scripts/review-one-pr.sh:333` through `:1024`). The reviewer dismisses its own approval and then skips as already reviewed (`scripts/lib/self-dismissed-approval.sh:2-13`). Each base merge mints a new head and forces a full re-review (`scripts/review-one-pr.sh:838-842`); auto-rebase updates every behind pull request by default (`.github/workflows/auto-rebase.yml:25-30`). The queue checks reviews only on entry (`scripts/lib/merge-queue-dequeue.sh:5-8`). | None on record. Merge-queue adoption is "deferred to a human" in its own decision document (`docs/initiatives/auto-rebase-vs-merge-queue.md:3-9,133`) while already in operation (`AGENTS.md:401-466`). |
| RC7 | **Verification does not bind, and the decision logic lives in a medium that resists it.** | The `main` ruleset requires five checks; `Lint`, the bats suite and every validator are not among them (live ruleset, read 2026-10-10). Evals never block (`.github/workflows/skill-eval-report.yml:176,204`) and score advisory prompts, not the code-writing paths (`scripts/evals/run-eval.sh:126-147`). The shared `gh` stub returns empty for unknown calls (`tests/dev-lead/fixtures/stubs/gh:28`). The suite fails on stock macOS (`AGENTS.md:174-181`). 1,025 top-level lines of `scripts/review-one-pr.sh` cannot be unit-called. | ADR-0004 prescribes pure bash functions plus bats. It does not say a test must block anything. |

### 4.2 Failure classes to causes

| Class (§2.3) | Primary cause | Contributing | PRD requirements |
|---|---|---|---|
| A. Approval never issues or is withdrawn | RC6 | RC1, RC4 | FR-2, FR-29 to FR-33 |
| D. Work dropped between event and agent | RC2 | RC1 | FR-3, FR-5, FR-15, FR-16, FR-19 |
| B. Status reported but not real | RC3 | RC1, RC7 | FR-4, FR-10, FR-11, FR-47 |
| E. Quota and budget exhaustion | RC2 | RC4 | FR-35 to FR-39 |
| C. Merged fix is not what runs | RC5 | RC7 | FR-45 to FR-53 |
| F. Identity, credential, permission | RC4 | RC3 | FR-26, FR-29, FR-60 |
| G. Re-review churn, treadmill, runaway | RC6 | RC2, RC4 | FR-7, FR-17, FR-20, FR-34 |
| I. Steering does not reach the agent | RC1 | RC4, RC5 | FR-22 to FR-25 |
| J. Tests and evals miss the real thing | RC7 | — | FR-54 to FR-58 |
| K. Automation that corrupts or destroys | RC3 | RC7 | FR-10, FR-14, FR-61 |
| H. Timeout loses the work | RC2 | RC3 | FR-6 |

### 4.3 The decisions the MVP must make

| Decision | Closes | Sub-decision |
|---|---|---|
| D-A. Where work-item state lives and who may change it | RC1 | §6.1 |
| D-B. How a run is admitted and queued | RC2 | §6.2 |
| D-C. The run contract and where write credentials sit | RC3 | §6.3 |
| D-D. Which identity an agent acts as | RC4 | §6.4 |
| D-E. The unit of release, and where the factory lives | RC5 | §6.5, §6.6 |
| D-F. What an approval is bound to and who may withdraw it | RC6 | §6.9 |
| D-G. What language holds decision logic, and what blocks a merge or a promotion | RC7 | §6.7, §6.8 |

The abstractions these decisions introduce are not speculative. Each already exists three or more
times in the POC: the read/write split in the persona runner, issue triage and the planner's
applier (§3.7); seven hold checks; nine "is this actor automation" tests; eleven numeric caps (for example `scripts/dev-lead-fix-issue.sh:35`,
`.github/workflows/pr-review.yml:252`, `scripts/lib/pr-automation-budget.sh:33`, against a standard
that says it "introduces no new count-based circuit breakers", `docs/agentic-interaction-model.md:547`). The rule of three is met
several times over. What is missing is one copy.

---

## 5. Whole-system options

### 5.1 The four families

**O1. Keep hardening the current design.** Continue issue by issue. Add the missing guards, make the
existing tests required, fix the budget feed.

**O2. Restructure on GitHub Actions.** Keep Actions as the only execution substrate. Introduce a
declared lifecycle, one admission point that reconciles state rather than relaying events, one run
contract with the write credential outside the model, one agent identity, one release. No always-on
component.

**O3. Move the control plane off Actions.** An org-level GitHub App receives webhooks at a hosted
endpoint and orchestrates. Variant O3a keeps the workers on Actions and hosts only the receiver and
queue. Variant O3b adds a durable workflow engine and runs the workers off Actions too. ADR-0007
weighed both and rejected them "at the current fleet size".

**O4. Adopt an existing agent platform.** Candidates: `gh-aw` (pinned here at v0.74.4 and only
compile-checked, `.github/workflows/ci.yml:112-118`), `anthropics/claude-code-action` (used by the
planner and idea triage), the Claude Agent SDK, and GitHub's own assignable agents.

**O4 is not a whole-system option, and is evaluated as a component choice.** Every candidate is a
worker runtime. None declares a work-item lifecycle, admits runs against a budget, binds an approval
to content or defines a release unit, so none touches RC1, RC2, RC5 or RC6. O4 is therefore folded
into decision D-C (§6.3): who builds the harness. It can combine with O2 or with O3.

### 5.2 Against the requirement groups

"Yes" means the option meets the group by construction. "Partly" means some requirements can be met
by further local work. "No" means a requirement in the group is a structural property the option
does not have.

| PRD group | O1 harden | O2 restructure on Actions | O3a receiver + Actions workers | O3b durable engine, workers off Actions |
|---|---|---|---|---|
| §6.1 Lifecycle (FR-1 to FR-7) | **No.** FR-1 to FR-3 need a declared lifecycle with one evaluator; thirty entry points each keep their own `if:`. FR-5 to FR-7 can be patched one loss mode at a time, which is the current practice. | Yes. | Yes. | Yes. |
| §6.2 Run contract (FR-8 to FR-14) | Partly. FR-10 needs the harness rewritten whichever option is chosen. | Yes. | Yes; same harness. | Yes, after rebuilding sandbox, logs, timeouts and artifacts. |
| §6.3 Orchestration (FR-15 to FR-21) | **No.** One admission point cannot be retrofitted onto workflows that each start their own agent. | Yes, with a latency floor: a wake costs a runner start, and a lost wake waits for the next event or sweep. | Yes; real queue and timers. | Yes; strongest. |
| §6.4 Human control (FR-22 to FR-28) | Partly. Identity can change; one vocabulary across thirty workflows cannot be held. | Yes. | Yes. | Yes. |
| §6.5 Review and merge (FR-29 to FR-34) | Partly. Each gate has been patched in turn and the next then failed (§2.4). | Yes. | Yes. | Yes. |
| §6.6 Resource governance (FR-35 to FR-39) | Partly. | Yes for GitHub quota and admission. The LLM signal stays an estimate (§6.2). | Same; the missing signal is constraint C-3, not the substrate. | Same. |
| §6.7 Observability (FR-40 to FR-44) | **No** ledger; reports stay reconstructions. | Yes; a git-backed ledger, queryable with simple tooling. | Yes; a database, better queries, private by default. | Yes. |
| §6.8 Release (FR-45 to FR-53) | **No.** Two regimes and per-agent names are structural. | Yes, except that an entry shim must run from the default branch (§10, item 2). | Worse on FR-46: the receiver is a second deployable with its own release path. | Worse again: three deployables. |
| §6.9 Assurance (FR-54 to FR-58) | Partly. Checks can be made required; portability and unit-callability stay as they are. | Yes. | Yes, plus the hosted service needs its own tests. | Same. |
| §6.10 Security (FR-60 to FR-63) | Partly. | Yes, with one stated exception for the reviewer credential (§6.4). | A second secret store and rotation path (ADR-0007, Context, fact 3). | Same, and the LLM credential leaves Actions. |

### 5.3 Against the non-functional requirements

| NFR | O1 | O2 | O3 |
|---|---|---|---|
| NFR-1 flow efficiency | No. Fan-in per event is the design: one comment starts three agentic workflows (`.github/workflows/dev-lead.yml:42`, `persona-mention.yml:42`, `pr-review-mention.yml:31`) and one review starts four. | Runs per merge fall by an order of magnitude once one wake replaces three or four listeners and cross-PR fan-out stops. The first draft's cap on cancelled runs was the wrong measure (§10, item 3). | Best: events that need no work start no run at all. |
| NFR-2 lead time | Flat or worse: median rose from about 1 h to 12–22 h while fixes landed (PRD §2). | Plausible. The floor is runner start plus sweep interval, minutes not hours. | Best. |
| NFR-3, NFR-4 autonomy and gate integrity | No evidence of convergence: 20 of 29 agent merges in the latest week lacked a standing approval (PRD §2). | Yes if §6.9 holds. | Same as O2; these depend on the kernel, not the substrate. |
| NFR-5 liveness | Compensators only. | Yes: every non-terminal state carries a next evaluation time and one sweep reads it. | Yes: durable timers. |
| NFR-8 release lag | No. | Yes. | Yes for the kernel; the receiver has its own lag. |
| NFR-9 operator load | Rising. | Higher during migration, then lower. | Adds a service with no on-call. |
| NFR-11 changeability | No. | Yes. | Yes. |
| NFR-12, NFR-13 | No without leaving bash for decisions. | Yes (§6.7). | Yes. |
| NFR-14 quota headroom | No while agents share the owner's quota. | Likely; depends on reads per evaluation, which is unmeasured (§11). | Likely better: webhook payloads replace reads. |

### 5.4 Against the constraints

| Constraint | O1 | O2 | O3a | O3b | O4 component (`gh-aw` as worker) |
|---|---|---|---|---|---|
| C-1 one maintainer, fail to a hold | Load rising: defect inflow 21–36 a week against flat throughput. | Migration adds load for some months. Fails to "nothing happens". | A service to run with no on-call. It also fails to "nothing happens", but silently and for every repo. | Same, plus workers. | A fast-moving dependency to track. |
| C-2 free plan, all public | Fine. | Fine. | Needs a host; free tiers exist but are a new dependency. | Same. | Fine. |
| C-3 subscription capacity, no usage API | Fine. | Fine. | Fine while workers stay on Actions. | The subscription credential must live on a host. | **Conflict as documented.** The `gh-aw` engine reference lists an API key or workload identity for the Claude engine and no subscription token, and states that cross-provider chains fail compilation. Unverified beyond the docs. |
| C-4 no always-on infrastructure | Fine. | Fine. | **Violates** unless the maintainer lifts it (OQ-1). | **Violates.** | Fine. |
| C-5 the platform loses events | Compensated, not tolerated. | Tolerated by design: no event carries work. | Mostly escaped, but GitHub does not retry a failed webhook delivery on its own, so a reconciling sweep is still required. | Same. | No effect. |
| C-6 identity rules | Independent of the option. The identity decision (§6.4) is the same in all of them. | | | | |
| C-7 self-hosting | Fine. | Fine: the hosting repo is served by the promoted release. | The receiver's deploy is outside the repo's own review path unless Actions deploys it. | Same. | Fine. |
| C-8 unreliable advisory reviewers | Patched per bot. | Deadlines in the kernel. | Same. | Same. | No effect. |

### 5.5 Migration cost, operating load, reversibility

| | O1 | O2 | O3a | O3b |
|---|---|---|---|---|
| Migration cost | None up front. Unbounded over time: 31% of defect issues already name a prior issue. | High. A kernel, a harness and a controller are built while the POC keeps delivering. Six cutovers. | O2's cost plus a receiver, a queue, deduplication and replay, a second secret store. | O3a's cost plus rebuilding logs, timeouts, artifacts and the sandbox. |
| Risk to the live line | The risk is the status quo. | Contained by running read-only first and cutting over one repo and one intent family at a time. | As O2, plus a new single point for the whole org. | Highest. |
| Maintainer load after migration | Rising. | Lowest that respects C-4: nothing new to operate. | A hosted component to monitor, patch and pay attention to. | More. |
| Reversibility | n/a | High. Each cutover is a registry entry and one consumer file; the POC path stays until retired. | Medium. The App's webhook URL is one setting, but state has moved off GitHub. | Low. |
| What it forecloses | Nothing, and it buys nothing structural. | Nothing. A kernel with no I/O (NFR-12) runs behind a webhook receiver as well as behind a workflow. **O2 is a strict prefix of O3.** | O1. | O1 and most of O2's substrate. |

### 5.6 Reading the comparison

- **O1 has earned real results and has stopped converging.** Hard failures are 0.9% of runs. But
  eight fixes moved a failure rather than removing it (§2.4), and FR-1, FR-15, FR-45 and
  FR-10 are structural properties that no further local guard produces. O1 remains the right choice
  under one condition, stated in §7.5.
- **O3 answers a question ADR-0007 did not ask.** ADR-0007 weighed the *ingress file count* and named
  three reopen triggers: stub fan-out becoming the bottleneck, events Actions cannot subscribe to,
  and cross-org routing. The first has partly fired (a new trigger took 32 days across two repos,
  PRD NFR-11); the other two have not. The new evidence is different: Actions is being used as a *queue
  and a timer*, and it is poor at both. O3 fixes that directly. But the fix that matters, treating
  events as hints and reconciling from recorded state, is needed under O3 as well, and it can be
  built without a host. So the order is settled even if the destination is not: build the
  reconciling kernel first, on Actions, and reopen the host question with measurements.
- **The identity, release, approval and assurance decisions do not depend on the substrate.** Four
  of the seven causes are closed identically under O2 and O3.

---

## 6. Sub-decisions

Each has options, a recommendation and the condition that would change it.

### 6.1 Where work-item state lives and who may change it

| Option | For | Against |
|---|---|---|
| a. Keep deriving state from labels and markers on every run | No migration | RC1 itself. A marker can outlive the object it describes (`scripts/lib/standing-approval.sh:2-15`). |
| b. One machine-written state comment per work item, authoritative | Visible on the item; no second store; FR-2 for free | Still parsed from comment text; no history, no migration path (`scripts/backfill-review-markers.sh` exists for that reason); 65,536-character limit; every read is an API call |
| c. A git-backed store: one state file per work item plus append-only ledger events, committed together; the item shows a projection | Atomic multi-record transitions; history and replay for free (FR-41, FR-58); reads move off the REST quota onto git; schema migration is a script | A push per transition; contention on one ref; the projection can lag; public if kept in a public repo |
| d. GitHub Projects fields | Visible board | Human-editable, no history, GraphQL-only; a projection at best |
| e. An external database | Best queries; private | Only with O3; violates C-4 |

**Recommendation: (c), with the item showing a projection.** The State record and the Ledger live in
one git store written only by the Controller identity. The Kernel folds ledger events into the State
record; each transition is one commit that adds the events and updates the record. The work item
carries one status block (and, on pull requests, one check run) generated from the record. Labels
remain the *human input* vocabulary (start, hold, release, hands-off); the Kernel reads them as
facts and never as stored state. HTML-comment markers stop being state: new code neither writes nor
reads one for a decision.

Who may change state: only the Kernel, through a declared transition, executed by the Controller.
A human changes state by making a declared human transition (a label, a review, an Override), which
the Kernel records with the actor.

The store's location is a follow-on decision. The cheapest start is a dedicated branch of the
hosting repo, which needs no new repo. A private data repo is possible on the free plan and answers
OQ-8 if the maintainer wants cost data private; nothing in the evidence requires it, since the
weekly cost report is already a public issue.

*Would change it:* push contention under real load (§11, A-10), or a decision for O3, which brings
option (e).

### 6.2 How runs are admitted and queued

**A platform fact changed during this review.** The evidence base, the PRD (C-5) and the repo's own
comments all describe a concurrency group as one running plus one pending run. GitHub's
documentation, read 2026-10-10, now describes an optional `concurrency.queue` property: `single`
(the default, the behaviour the repo knows) or `max`, which holds up to 100 pending runs and cannot
be combined with `cancel-in-progress: true`. No workflow in this repo uses it. This is a cheap
mitigation for the POC (§8, step 0) and it does not change the recommendation, for the reason below.

| Option | For | Against |
|---|---|---|
| a. Status quo: each event starts its own agent; lanes are the queue; crons re-find what was lost | — | RC2 |
| b. Same, with `queue: max` on the lanes | One-line change per lane; removes eviction of pending runs | Does nothing for a dropped tick, a failed dispatch, a killed run, a failure read as "nothing to do", or capacity. Queued runs each still do work. The request still exists only as a run. |
| c. **Level-triggered admission.** Events are wake-ups that carry only the work item's identity. One Controller evaluates recorded state plus current facts and decides: nothing, defer until T, hold, or admit one Run. | A lost or evicted wake loses nothing, because the next wake or the sweep reaches the same decision. The default depth-one lane becomes exactly the coalescing FR-16 asks for. One place evaluates Pause, Hold, budget, duplication and concurrency (FR-15). | A runner start per wake. Timers are only as good as the sweep. |
| d. A hosted queue and scheduler | Real queue semantics and timers | O3 |

**Recommendation: (c).** Its parts:

- **Wake.** The consumer's single ingress file (ADR-0007) forwards `{schema version, repo, item}`
  and nothing else. The Kernel's decision function takes no event payload, so the property "no
  event carries work" is checkable.
- **One lane per work item,** held for the whole of decide → run → apply. That is FR-16 by
  construction. An evicted pending wake is harmless.
- **Global limits by compare-and-swap.** Admitting a Run is a commit to the ledger that takes a
  lease. A push that loses the race is rebased and the decision is re-made against the new state.
  That gives an org-wide concurrency and budget check without an org-wide lock.
- **Timers as data.** Every non-terminal, non-held state records a next evaluation time. A sweep on
  two or more staggered cron slots wakes overdue items, and every Controller run does the same
  opportunistically, so ordinary activity drives the timers when ticks are dropped. This one sweep
  replaces the retry, sweep, delayed-retry and stall-detection workflows of §3.2.
- **Hub execution.** The Controller runs in the hosting repo, woken by `repository_dispatch`. This
  is already how personas, the mention path of pr-review, the planner and idea triage work
  (`DG:.github/workflows/persona-mention-reusable.yml:365-366`,
  `DG:.github/workflows/pr-review-mention-reusable.yml:207-208`); dev-lead is the exception. It gives one ring registry, one ledger writer and a consumer
  file that never needs editing. Its cost is in §7.5.
- **Pause and Hold.** Read at admission, in one place. A human Pause is an Actions variable; an
  automatic pause is a ledger record. They are different stores, so automation cannot clear a human
  Pause (FR-24). The ingress subscribes to `unlabeled`, so releasing a Hold is an event (FR-23).
- **Capacity signal (OQ-3).** GitHub quota: the Controller reads its own installation's remaining
  limit, which is exact. LLM budget: the evidence does not support a strong recommendation. The
  usage endpoint is unsupported and refuses the CI credential
  (`petry-projects/.github-private#2179 — Budget poller: record the upstream error type on a refused
  read, so an HTTP 403 says why (every poll so far is degraded)`). The option that needs no new
  credential is self-metering: the ledger sums the factory's own token use per window and learns the
  ceiling from observed limit hits. It is a lower bound on use, and it is only trustworthy if the
  factory's subscription credential is not shared with interactive sessions. *Experiment:* two weeks
  of ledger self-metering in observe mode, compared with every observed rate-limit event.

*Would change it:* see the O3 reopen triggers in §7.5.

### 6.3 The run contract, and where write credentials sit

| Option | For | Against |
|---|---|---|
| a. Status quo, with ADR-0011's guards | Exists | Guards relocate the failure: they "refuse legitimate pushes, loop, or retract real fixes" (§2.4) |
| b. One contract, built here: Task in, Result out, jobs as credential boundaries | Generalizes three seams that already work (§3.7); engine-neutral; keeps the subscription credential and cross-provider fallback | It must be built and maintained |
| c. `gh-aw` as the worker runtime | The closest existing implementation of FR-9, FR-10 and FR-12: a read-only agent job, typed safe outputs applied by separate jobs, and outputs that cover this factory's effects (`push-to-pull-request-branch`, `submit-pull-request-review`, `resolve-pull-request-review-thread`, comments, labels). A network firewall and threat detection that option (b) lacks. | Documented Claude auth is an API key or workload identity, not the subscription (C-3). No cross-provider fallback (FR-13; `scripts/engine.sh:2082-2267` exists because the fleet needs one). v0.74 of a fast-moving tool. The repo already declined it once: `scripts/aw.sh` is a 586-line home-grown re-implementation serving one workflow; why is not recorded (§11). |
| d. `anthropics/claude-code-action` as the worker | Already used twice | It is the same CLI in an action wrapper; as used here the model holds the write token (`.github/workflows/initiative-planner.yml:246-256`). It adds nothing to the contract. |
| e. Claude Agent SDK packages | Tool-approval callbacks; native message objects | The headless CLI *is* the Agent SDK's CLI form and already returns what the contract needs: `--output-format json` with cost, usage and session id; `--json-schema` for a validated `structured_output`; `--resume` by session id or transcript path. A package dependency buys little more. |
| f. GitHub's assignable agents | Native | Needs a paid Copilot seat (C-2). Copilot answered 2 of 174 pull requests as a reviewer in one week (`petry-projects/.github-private#1220 — Third-Party Reviewer Scorecard — Weekly Report`, comment of 2026-10-05). |

**Recommendation: (b), shaped so that (c) can replace its inner half later.**

- A **Task** is a schema-versioned document containing everything the Run needs, with every piece of
  third-party text labelled by trust class. The model does not discover its inputs.
- A **Result** is a schema-versioned document: status, a list of requested **Effects**, usage. Code
  changes are local commits handed over as a bundle. The effect vocabulary follows `gh-aw`'s safe
  outputs where they overlap, so substitution stays cheap.
- **Three jobs, three credential sets.** `run` holds the LLM credential and a read-only GitHub
  token. `verify` holds no secret and is the only job that executes code from the work item's
  branch (lint, the repo's tests, the diff guards of ADR-0011). `apply` holds the write credential,
  runs no model and no work-item code, validates the Result and applies its Effects.
- **Claims are generated, not verified.** The model never states a commit hash. `apply` writes
  "fixed in X" from the commit it pushed and read back. FR-11 then holds by construction, and the
  claim-verification, attribution-shim and retraction code (roughly four thousand lines, PRD §6.2) has
  nothing left to police.
- **Use what the CLI already returns.** Structured output replaces the brace-scanning verdict
  parser (`scripts/engine.sh:2274-2301`); the JSON envelope's cost and usage fields are recorded for
  every Run, including failed ones (FR-38); a persisted transcript makes resume possible (FR-6).
- **Residual risk, stated.** The `run` job's model can still read the LLM credential and reach the
  network. Option (c)'s firewall closes that; option (b) does not.

*Would change it, and the experiment:* port issue triage (already front-matter-shaped,
`.github/workflows/issue-triage.md`) to real `gh-aw` on one repo. If the subscription credential
works there and the lack of cross-provider fallback is acceptable for that role, adopt `gh-aw` as the
inner half of `run`/`apply` for tool-less and advisory roles first.

### 6.4 Agent identity

**What was decided before, and why.** Interaction model §12.2 kept dev-lead on the owner account and
rejected a distinct identity on four grounds. ADR-0008 then put every advisory persona on the owner
account because the machine user's token could not write comments
(`petry-projects/.github-private#1734 — persona-runner: qa-lead advisory lost — DON_PETRY_BOT_GH_PAT
gets HTTP 403 posting issue comments (regression from #1694)`). Both records are honest about cost:
ADR-0008 names the recursion guard dropping to one axis as "the real cost".

**Taking §12.2's four grounds in turn:**

1. *"A distinct identity would need to be added to CODEOWNERS to retain the same approval
   semantics."* A pull request's **author** does not need to be a code owner; its **approver** does.
   With an App as author, the machine user still satisfies the code-owner review, and the Maintainer
   gains the ability to approve or request changes, which the shared identity removes
   (`docs/agentic-interaction-model.md:725-733`). The semantics improve.
2. *"A new account means a new PAT, widening the credential surface the model deliberately kept to
   two accounts."* True of a second machine user, which is also barred: GitHub's terms allow one
   free machine account per person and the org has it. It is not true of a GitHub App. An App has
   no PAT; it mints a token per run that expires within the hour and can be narrowed per role. The
   org already operates GitHub Apps for release tagging, Dependabot and project sync
   (`AGENTS.md:939-951`; §3.4). The agent identities stay at two: one App
   that writes, one machine user that reviews.
3. *"It is a cross-cutting change to the manifest and identity-resolution machinery."* True, and it
   is the real cost. It is paid once.
4. *"It does not generalize: other automation still posts as the owner, so the marker is needed
   regardless."* True only while other automation stays on the owner account. The PRD's exit
   criterion 5 removes all of it. §12.2 itself notes that the marker gate "does not foreclose"
   a distinct identity and would become "a redundant confirmation".

**What has changed since.** The costs §12.2 and ADR-0008 did not have in front of them: the loop
ceiling cannot count dev-lead's actions (`scripts/lib/pr-automation-budget.sh:54-59` treats any
login ending in `[bot]` as automation, which an App satisfies with no code change); the Maintainer's
mentions are skipped as self-comments (`petry-projects/.github-private#2027 — dev-lead silently
ignores @dev-lead mentions from the maintainer, because the maintainer's account is dev-lead's own
identity (self-comment skip)`); the shared quota ran out; and no measurement can tell a human action from an agent's (§2.2).

| Option | FR-26 | FR-29, FR-30 | FR-37 | FR-60 | C-6 |
|---|---|---|---|---|---|
| a. Status quo (owner + one machine user) | No | Reviewer differs; owner cannot review | No | No | Fits |
| b. A second machine user for the writer | Yes | Yes | Yes, a second 5,000/h | Long-lived PAT | **Barred** by the one-free-machine-account term |
| c. **One factory App writes; the machine user reviews** | Yes at agent-versus-human grain | Yes, and enforced by the platform: with code-owner review required, the App cannot satisfy the gate it is subject to | Yes: an installation has its own limit of at least 5,000/h | Yes for the App; not for the reviewer | Fits |
| d. One App per role | Yes at role grain | Yes | Yes | Yes | Fits; N keys and installs to run |
| e. App writes and a second App reviews; drop code-owner review | Yes | Depends on an unverified platform fact (§11, A-1) and removes the platform's own enforcement | Yes | Yes | Needs OQ-4 answered "drop" |

**Recommendation: (c).** Per-role least privilege comes from narrowing the installation token at
mint time, not from more Apps. The role of each action is a field in the ledger and a line in the
visible output. The marker stays as a redundant guard.

**Answers to the open questions.** OQ-2: yes, move the writer off the owner account; this
supersedes ADR-0008 and reverses interaction model §12.2. OQ-4: keep code-owner review. It is what
makes reviewer independence a platform fact rather than a factory promise, and the price is that the
reviewer stays a user account with a long-lived token. That token moves into the `apply` job of the
review intent only, where no model runs. It is the one stated exception to FR-60.

**The cost that must not be buried.** Events authored with an App token start workflows; events
authored with the default workflow token mostly do not. ADR-0007 called the latter a free loop
brake. dev-lead does not have that brake today either, because it already acts through a PAT, but
with this decision nothing has it. Admission (§6.2) becomes the only loop bound. That is acceptable
only because the Kernel's count of automated actions since the last human decision no longer depends
on which account acted (FR-17).

**One credential the table does not show.** The consumer's ingress must send a wake to the hub, and
it runs in a repo whose branches agents write to. That credential should be able to do one thing:
start the entry workflow. It should not be the App key that writes code. A second, dispatch-only
credential, or a wake sent as a `workflow_dispatch` under an App permission limited to Actions, keeps
a compromised consumer workflow from acquiring write access to the org. The identity follow-on ADR
must decide which.

*Would change it:* a role that needs a permission the shared App should not hold, or a need to
filter by role on the actor field alone. Either reopens (d).

### 6.5 The unit of release

| Option | For | Against |
|---|---|---|
| a. Status quo: 17 per-agent names over one whole-repo commit; personas and hub workflows unversioned | Exists | Two regimes; independence is nominal ("they only appeared to", ADR-0006); 225 dev-lead tags and 137 majors with exactly one release each (local tag snapshot, 2026-10-10) |
| b. Per-agent releases made real, with per-agent watched paths | Isolated rollback | Shared code (`scripts/lib`, the engine layer) makes isolation false; multiplies the gate |
| c. **One release line for the factory**: `factory/vX.Y.Z` immutable, `factory/v<MAJOR>-next` and `-stable` moving | One fact; every artifact rides it, prompts and manifests included; no sender/receiver skew inside the factory (FR-52); the interface that could "break" is one wake schema | No per-role staging or rollback; a fix to one role waits for the whole gate |
| d. Live at merge for everything | Fast | The 2026-06 state the channel tags were introduced to end |

**Recommendation: (c), with two channels, not four.** ADR-0002's mechanism survives unchanged: an
immutable tag and a moving channel under a ruleset, moved by an App through one path. What changes
is the name granularity. `ring0` and `ring1` are dropped until there is traffic to fill them
(`petry-projects/.github#1086 — Gate soak is vacuous: dwell/sample count runs from repos that are
not executing the candidate — and dev-lead's 'next' tier is structurally unoccup…`).

How the hub follows a channel: a `repository_dispatch` or `schedule` run always executes the
default branch's workflow file, and a `uses:` reference cannot be computed. So the entry workflow is
a small frozen shim on the default branch with one static caller job per channel, chosen by a
job-level `if:` on the output of a ring-resolution job that is itself a pinned reusable. The shim
therefore stays a thin caller under ADR-0001, with one non-event predicate added to ADR-0007's
filter rule. Everything else, the Controller workflow included, is read at the release
the shim selected. Inside the release, tooling is checked out at `github.job_workflow_sha`, the
construction the standards repo already uses to remove the double pin
(`DG:.github/workflows/persona-mention-reusable.yml:54-60,129`).

Ring membership is one file in the release. The hosting repo is always in `stable`, which preserves
the self-hosting rule (`docs/release/versioning.md:81-95`). The `next` ring is one or two low-risk
consumers plus synthetic work items when organic traffic is absent.

*Would change it:* two roles needing genuinely independent cadence for a reason other than
convenience. None is in evidence.

### 6.6 Where the factory lives

Two questions are tangled here: the two-repo split, and the name.

**The split.** The router is in the standards repo and reads manifests from this repo's `main`; the
ring registry and the promotion engine (`DG:scripts/canary-rollout.sh`, 4,015 lines) are in the
standards repo and govern agents hosted here; the persona schema exists in both and has diverged
(`standards/personas/persona.schema.json`, 353 lines here against 348 there). Whatever else is decided, the
factory must be one tree with one release: Controller, Kernel, Harness, Roles, ring registry and
release tooling together. The standards repo keeps what its own boundary rule says it owns, org-wide
standards and compliance (`DG:AGENTS.md:38-55`), and distributes the one consumer file.

**The home of that tree.**

| Option | For | Against |
|---|---|---|
| a. A `factory/` tree in the hosting repo, with its own required check | No new repo (C-4 as decided in June); the seams in §3.7 are reused in place; one cutover fewer; reversible | New and legacy code share a repo and a 1,062-line `AGENTS.md` of legacy doctrine; a release tag still covers legacy files; the name stays misleading |
| b. A new repo now | A physical boundary; required checks from the first commit; a clean tag namespace; `.github-private` can return to its GitHub-defined role | A new repo to bootstrap (two scripts in two repos and three manual vendor or admin steps, `DG:scripts/bootstrap-new-repo.sh:1-45`) at the moment the line is weakest; two migrations at once; needs the "no new repos" rule lifted |
| c. Fold into the standards repo | One repo | Reverses the boundary rule; puts the largest codebase in the policy repo |

**Recommendation: (a) now, extraction as a separate later decision.** Make the tree self-contained
(nothing under `factory/` imports from outside it) and give it its own `AGENTS.md`. Extraction then
becomes a mechanical subtree split whenever the maintainer wants it. Answer to OQ-5: not yet; decide
at MVP exit, when the legacy code that makes a new repo attractive has been retired anyway. The
evidence does not make a strong case either way, and (a) keeps both open.

Two smaller points. The repo's own instructions call it private while it is public
(`.github/workflows/pr-review.yml:358`); correct the instructions now, independent of everything
else. And GitHub gives the `.github-private` name a meaning for org-level agent profiles, so the repo
persists whichever option is chosen.

### 6.7 Language and runtime for decision logic

ADR-0004 governs: pure classifiers in shell, a matching bats file, the model only where it must be.
Its principle has held up and is kept. Its language binding is what the evidence questions:

- control flow rides on overloaded exit codes (2, 55, 100, 101, 124, 3, 4;
  `scripts/review-batch.sh:317-323`), and workflows then flatten them
  (`.github/workflows/dev-lead-reusable.yml:479-481`);
- subshell semantics are "a recurring bug source … worked around case by case"
  (`scripts/engine.sh:1431-1433,1556-1561`), including a wrong model attribution fixed in one tier
  and left in two;
- structured data is handled by 1,143 `jq` call sites and 54 GraphQL strings, and many test stubs
  return the post-`jq` result, so the real call is never exercised (`tests/dev-lead/unit/test_dev_lead_retry.bats:21`);
- the suite needs bash 5 and GNU tools and fails on the maintainer's machine (`AGENTS.md:174-181`);
- 17 functions exceed 150 lines and two of the largest decision paths are not functions at all.

A lifecycle with typed states, schema-validated documents and replay of recorded work items is a
poor fit for that medium.

| Option | For | Against |
|---|---|---|
| a. Stay in bash, enforce the discipline | No rewrite; 70k lines of tests keep their value | Every item in the list above |
| b. **Python 3, standard library only for the Kernel** | Already the repo's second language (four validators, a pytest suite under `tests/dev-lead/integration`); present on runners and on macOS; no dependency stream for a factory whose pull-request pipeline is the scarce resource; dataclasses, enums and a type checker suit a state machine | A second language to hold in mind; no compile step, so type checking must be a required check |
| c. TypeScript | Typed; the Actions ecosystem's native language | A dependency tree and a build; Dependabot traffic; nothing in the repo uses it |
| d. Go | One binary; strong typing | A build-and-publish step becomes part of the release; nothing in the repo uses it |

**Recommendation: (b).** New decision logic is Python with no I/O in the Kernel. Bash is kept as
step glue of a few lines. The existing scripts are not ported wholesale: the Harness first wraps the
seams worth keeping (the engine tier primitives, push safety, the diff guards) behind ports, and
each legacy decision is re-specified in the Kernel, proven against recorded real work items, then
deleted.

The evidence separates bash from the alternatives clearly. It does not separate Python from
TypeScript; that choice rests on what is already in the repo and on avoiding a dependency stream.
*Would change it:* a harness dependency that exists only for Node.

**The cost is real.** The bats suite encodes incident history: `scripts/dev-lead-fix-reviews.sh`
cites 48 issues. Some of that knowledge will not survive translation. The mitigation is §8's observe
step: the Kernel's decisions are compared with the POC's on live traffic before anything is cut
over, and the disagreement list is the migration backlog.

### 6.8 What blocks a merge, and what gates a promotion

**Merge-blocking.** No ADR says a test must block anything, and none does.

- A new required check, `factory / verify`, from the first commit of the tree: unit tests, replay of
  recorded work items, schema validation, the lifecycle checks of FR-57, the type check and the
  import rule that keeps the Kernel free of I/O.
- A required check must be **hermetic**: it reads nothing outside the merge commit. The validators
  that fetch from the standards repo at run time once "red-lined the whole fleet 21 seconds after it
  merged" (`personas/validate-personas.py:59-63`); they stay advisory until they are hermetic.
- A required check must **always report**: no `paths:` filter on its workflow, and a `merge_group`
  trigger, which the five current required checks already have.
- The legacy bats suite becomes required once it has been green on `main` for a set period. Until
  then requiring it would block the line on known-red jobs (`.github/workflows/lint.yml:399-402`).

**Promotion.** A candidate advances from `next` to `stable` on three records in the ledger, not on
run conclusions: an eval result for every production Intent whose inputs changed; verified Effects
from the `next` ring (a Run of the candidate whose Effects were read back); and no regression in the
ring's integrity counters. A ring with no Runs of the candidate is not evidence; synthetic work
items fill the gap.

Two limits the PRD should absorb (§10): each eval case is a real model call against the same scarce
window (C-3), so candidates must be batched to about one a day and eval results cached by the hash
of the prompt and harness path; and a "held-out" set in a public repo is held out by convention only.

### 6.9 Approval durability and re-review cost, with the merge queue on

Live settings: one approval, code-owner review, last-push approval, stale approvals dismissed on
push, thread resolution, loose status checks, and a merge queue that squashes one entry at a time.
GitHub dismisses an approval when the diff changes *or the merge base changes*.

| Option | For | Against |
|---|---|---|
| a. Status quo | — | RC6 |
| b. Turn off dismiss-on-push; let the factory withdraw approvals | No platform dismissals; no re-approval step | A factory failure then merges unreviewed content. It fails to an action, not to a hold (C-1). |
| c. **Keep the platform's dismissal; bind the factory's verdict to content; re-issue cheaply when content is unchanged; stop updating branches** | Fails closed. The mechanism exists in miniature (`scripts/lib/carry-forward.sh`). | A defect in the content identity is an unreviewed merge; SM-C3 exists to watch for it. |

**Recommendation: (c).**

- **Stop the fan-out at its source.** The queue builds and tests the real merge result, so a branch
  does not need to be current. Auto-rebase should act only on a pull request that conflicts. This is
  open as `petry-projects/.github-private#1881 — auto-rebase still merges main into every open PR on
  every push, though the ruleset no longer requires up-to-date branches — the treadmill's driver
  out…` and needs no new structure.
- **A verdict is bound to a content identity:** a hash of the pull request's own diff against its
  merge base. When a push changes the head but not that identity, the Harness re-issues the approval
  with no model Run. Any doubt (a conflict resolution, an unparseable comparison) means a review.
- **One gate function.** The twelve sequential gates become one Kernel function from facts to
  approve or withhold-with-reason. Findings and their dispositions are records in the State record,
  keyed by finding and content identity, not minimized-comment state and marker text.
- **Withdrawal has two sources only:** the platform, on new content, and the Kernel, on a new
  unresolved finding, as a recorded transition that also removes the pull request from the queue.
  The review Role never dismisses its own approval.
- **Advisory reviewers have deadlines** and the awaited set is derived from the reviewers observed
  active on that repo (FR-32).
- **An Override is a record.** A merge without a standing independent approval remains possible
  through GitHub's own bypass. The Kernel detects it and requires a reason on the item; SM-5 counts
  the ones without.

---

## 7. Recommended target architecture

Sections 7 and 8 are the recommendation as first made. §14 challenged it, and §14.7 lists what
changed in ADR-0012 as a result. §18 changes where it is built: in a new repo, not as a tree in
this one, which replaces the recommendation of §6.6 and the structure shown in §7.3. Where they
differ, the ADR is current.

### 7.1 The recommendation

**O2: restructure on GitHub Actions around a declared control plane, one run contract and one
release**, with the identity decision of §6.4 and the worker built here to a contract that an
adopted runtime can later fill (§6.3).

```text
consumer repo                             hosting repo (the hub)
─────────────                             ──────────────────────
any subscribed event                      factory-entry.yml   (default branch, frozen, no logic)
        │                                   on: repository_dispatch [factory-wake], schedule
        ▼                                   resolve ring ──► one static caller job per channel
agent-ingress.yml  (ADR-0007)                          │
  one job, event filter only                           ▼
  sends {v, repo, item} ───────────────►  factory-controller.yml @ factory/v<M>-<channel>
                                            one lane per work item, held for the whole run
                                            ┌────────┐  facts + State record ─► Kernel ─► Admission
                                            │ decide │  nothing │ defer(T) │ hold │ admit(Run)
                                            └───┬────┘  one ledger commit = the decision + a lease
                                                ▼
                                            ┌────────┐  Task ─► Engine ─► Result
                                            │  run   │  LLM credential, read-only GitHub token
                                            └───┬────┘
                                                ▼
                                            ┌────────┐  the only job that executes work-item code
                                            │ verify │  no secrets
                                            └───┬────┘
                                                ▼
                                            ┌────────┐  validate Result ─► apply Effects ─► read back
                                            │ apply  │  write credential; no model, no work-item code
                                            └───┬────┘  ledger commit ─► projection on the item
                                                ▼
                              git-backed Ledger + State records (append-only, Controller-written)
```

| Decision | Recommendation |
|---|---|
| State | Declared Lifecycle as data; State record and Ledger in one git store; labels are inputs; markers are not state |
| Admission | Level-triggered Controller in the hub; wakes carry identity only; one lane per work item; leases by compare-and-swap; timers as data with one sweep |
| Run contract | Task in, Result and Effects out; `run` / `verify` / `apply` are separate credential boundaries; claims generated by the Harness |
| Identity | One factory App writes; the existing machine user reviews; the owner account is the human's alone |
| Release | One line, `factory/`, two channels, everything on it; a frozen entry shim is the only thing live at merge |
| Home | A self-contained `factory/` tree in the hosting repo; extraction decided at exit |
| Language | Python 3, standard library only in the Kernel; bash as glue |
| Assurance | `factory / verify` required and hermetic from the first commit; promotion on eval and ring records in the ledger |
| Approval | Platform dismissal kept; verdict bound to content identity; one gate function; auto-rebase only on conflict |

### 7.2 Implementation patterns

These are the rules that keep many authors, most of them agents, producing compatible code.

1. **Facts in, decision out.** A Kernel function takes plain data and returns plain data. It reads
   no environment, file, clock or network; the clock is an argument.
2. **Events are hints.** No decision reads an event payload beyond the work item's identity.
3. **Effects are data.** A Role requests; only `apply` acts. A new kind of side effect is a new
   entry in the effect schema, never a new credential in a new place.
4. **A job is a credential boundary.** No job holds both an LLM credential and a write credential.
   No job that holds a write credential executes work-item code.
5. **One writer per work item,** by the lane; one writer of the ledger identity, by construction.
6. **Every document is schema-versioned:** wake, Task, Result, Effect, State record, ledger event,
   Role manifest, Lifecycle. A reader rejects a version it does not know.
7. **Derive, never enumerate.** The set of Roles is the directory listing; the consumers and rings
   are one file; a table in a document is generated and checked for staleness.
8. **Fail to a Hold.** An unreadable fact, a missing capacity reading or a failed validation yields
   a Hold or a deferral with a reason. It never yields "nothing to do" and never an action.
9. **Content identity, not commit identity,** decides whether work is new.
10. **No marker is state.** New code does not read a comment body to decide anything. The one
    adapter that reads legacy markers during migration is on an allowlist that only shrinks.
11. **Workflow YAML carries no logic.** A step calls a module entry point; a `run:` block is a few
    lines.
12. **A required check is hermetic and always reports.**

### 7.3 Structure

```text
factory/
  AGENTS.md            rules for changing the factory; supersedes legacy doctrine for this tree
  lifecycle/           one file per work-item type: states, transitions, gates, actors   (FR-1)
  roles/<role>/        manifest, prompts/, evals/                                        (FR-8)
  schemas/             wake, task, result, effect, state-record, ledger-event, manifest
  config/              rings (consumers and ring), tiers (engine per tier), capacity, reviewers
  kernel/              pure decision logic: lifecycle, admission, gates, content identity,
                       dispositions, capacity, projection                          (NFR-12)
  adapters/            all I/O: github (facts, effects), ledger (git), engine (per provider)
  harness/             build Task, run Engine, validate Result, apply Effects
  controller/          entry point: wake → decide → record → run → verify → apply
  release/             cut, promote, roll back; ring evidence from the ledger
  tests/               unit/  replay/ (recorded work items)  contract/ (recorded GitHub and
                       engine responses)  lifecycle/ (termination, cycles, hold and pause)
.github/workflows/
  factory-entry.yml        the frozen shim
  factory-controller.yml   the only workflow that invokes an Engine
  factory-verify.yml       the required check
templates/agent-ingress.yml  the one consumer file
```

| PRD group | Lives in |
|---|---|
| §6.1 Lifecycle | `lifecycle/`, `kernel/lifecycle`, `adapters/ledger` |
| §6.2 Roles and run contract | `roles/`, `schemas/`, `harness/`, `adapters/engine` |
| §6.3 Orchestration | `kernel/admission`, `controller/`, the two factory workflows |
| §6.4 Human control | `lifecycle/` (human transitions), `kernel/admission` (Pause, Hold) |
| §6.5 Review and merge | `kernel/gates`, `kernel/content identity`, `kernel/dispositions` |
| §6.6 Resource governance | `kernel/capacity`, `config/capacity`, ledger leases |
| §6.7 Observability | `adapters/ledger`, `kernel/projection`, scorecard queries |
| §6.8 Release | `release/`, `config/rings`, `factory-entry.yml`, the consumer template |
| §6.9 Assurance | `tests/`, `factory-verify.yml`, `roles/*/evals` |
| §6.10 Security | the job boundaries in `factory-controller.yml`, token narrowing in `adapters/github` |

### 7.4 Validation against the requirements

**Coherence.** The decisions depend on one another in one direction only. Level-triggered admission
needs a State record; content-bound approval needs the single gate function; the App identity makes
the loop bound countable, and the loop bound is what makes the App identity safe. One release makes
schema skew inside the factory impossible, which is why the wake can be the only versioned
interface. Nothing in the set contradicts another member.

**Coverage.** Every requirement group has a home (§7.3). Requirements this architecture meets only
with a stated qualification: FR-2, FR-15, FR-35, FR-46, FR-51, FR-55, FR-60, NFR-1 (§10).

**Gaps that remain.**

- *Important:* the LLM capacity signal is an estimate (§6.2). The `run` job has no network
  containment (§6.3). Reads per evaluation, and so NFR-14, are unmeasured.
- *Deferred by the PRD's own scope:* the planning roles stay on their current runtime, with the
  write token in the model. Exit criterion 5 nonetheless requires them off the owner account.
- *Not addressed here:* review depth, and the reliability of advisory reviewers beyond a deadline.

**Readiness.** Ready to begin with the first two steps of §8. Not ready to be costed: OQ-9 cannot be
answered from this evidence.

### 7.5 The trade-offs, stated plainly

- **It keeps the substrate that caused the second-largest failure class.** The recommendation bets
  that reconciling from recorded state makes dropped ticks, evicted runs and slow queues harmless
  rather than absent. If the bet is wrong, O3 is still to be bought. This is the strongest argument
  against the recommendation.
- **It is a rewrite of the core, in a second language, built largely by the agents it replaces, on
  a line that is already overloaded.** Two systems coexist for months and the maintainer's load
  rises before it falls. The pattern "a fix relocates the failure" can recur at the scale of an
  architecture.
- **Hub execution concentrates risk.** A bad `stable` release or a broken entry shim stops every
  repo at once. ADR-0007 accepted that blast radius per repo; this accepts it per org.
- **A consumer's work runs somewhere else.** Runs for a consumer's work items execute and log in the
  hosting repo. The consumer's own Actions tab shows only the wake; the status block on the item is
  the link. `verify` executes the consumer's tests on a hub runner, so each consumer must declare how
  its environment is set up and how its tests are run, which the POC infers.
- **One release removes per-role staging and rollback.** ADR-0006 made the same trade for personas
  and observed that the isolation it gave up was never real.
- **A git-backed ledger is not a database.** It will be slow to query at volume and contended under
  bursts, and by default it is public.
- **Fewer rings means less staged exposure** than the configured four, though more than the four
  delivered in practice: all four channels of dev-lead pointed at one commit at the snapshot, as did
  all four of pr-review (§3.5).
- **Re-approval on unchanged content approves a commit no reviewer read.**

**Choose differently when:**

| Condition | Then |
|---|---|
| The maintainer cannot fund a migration (OQ-9) or will not pause feature work on the POC | Do step 0 and the identity cutover of §8 and stop. That is O1 with its three cheapest structural fixes. RC1, RC2, RC3 and RC5 remain. |
| OQ-1 is answered "always-on infrastructure is acceptable" **and** a reopen trigger below has fired | O3a, hosting the same Kernel. |
| `gh-aw` is shown to run on the subscription credential and reaches a stable release line | Adopt it as the inner half of `run`/`apply`, advisory roles first. |
| LLM capacity moves to a metered API (C-3 changes) | The capacity signal becomes exact, and the `gh-aw` conflict disappears. Revisit §6.2 and §6.3. |

**Reopen triggers for the rejected options.**

- *O3 (off-Actions control plane).* After the review and fix intents are under the Controller: more
  than 5% of **admitted Runs** are lost or start later than the liveness limit for four weeks; or
  the hub's run queue is the measured bottleneck on lead time; or GitHub quota cannot be held under
  NFR-14 with reconciling reads; or a requirement appears for a timer finer than the sweep can give.
  These replace ADR-0007's file-count triggers, which the single wake makes moot.
- *O4 as worker (`gh-aw`).* The experiment in §6.3 succeeds, or a prompt-injection incident occurs
  that network containment would have stopped.
- *Per-role Apps.* §6.4.
- *A new repo.* MVP exit, or the legacy tree's rules measurably misleading agents that work in
  `factory/`.
- *O1.* Never as a strategy. As a fallback, the first row of the table above.

---

## 8. Migration shape

An order, not a plan. Each step leaves the line running and can stop there.

**The rule throughout:** for any repo and intent family, exactly one line serves it, the POC or the
factory, as recorded in the ring file. Never both. ADR-0009's dual serving of one surface is the
case to avoid.

| Step | Introduces | Can be retired when it holds | Evidence that it worked |
|---|---|---|---|
| **0. Floor.** Configuration only; needs no new structure. | Auto-rebase limited to conflicting pull requests. `concurrency.queue: max` tried on the dev-lead and pr-review lanes of one repo. The factory App created and installed, unused. `factory / verify` added as a required check over an empty tree. The repo's instructions corrected to say it is public. The Claude Code CLI version pinned (§11.2, A-8). ADR-0011 accepted as the interim rule. | Nothing yet. | Agent runs on other pull requests per merge to `main` fall to about zero. Cancelled-before-start share on the trial lanes, before and after. |
| **1. Observe.** *The first structural step that delivers value alone.* | The Lifecycle files, the Kernel, the Ledger and the projection, running read-only on every repo under the App's own quota and released through the new single line. It decides nothing and applies only the status block. | After parity: `scripts/pr-approval-diagnostic.sh`; the stall, runaway and merge-ready scans; the premature-closure audit; the zombie report. | For a sample of stuck pull requests the Kernel names the same blocking gate the POC enforced. Undeclared transitions are counted. The scorecard exists, so the PRD's `[ASSUMPTION]` targets can be calibrated (OQ-7). The disagreement list between Kernel and POC is produced. Installation quota use is measured. |
| **2. Identity.** In parallel with step 1; touches POC code. | dev-lead and the personas act through the App; the reviewer is unchanged. The ADR that supersedes ADR-0008 lands with it. One canary repo first. | The marker as *sole* recursion guard; the attribution shim (`scripts/lib/claim-landing.sh:115-170`); the owner PAT on agent paths. | Seven days with no agent action under the owner login. The Maintainer requests changes on an agent pull request and it blocks. The loop ceiling counts dev-lead's actions. Fleet traffic no longer draws on the owner's quota. |
| **3. Review under the Controller.** First on a `next`-ring consumer, then the rest, the hosting repo last. | Admission, the run contract and the single gate function for the review intent; content-bound verdicts; dispositions as records. | `pr-review-sweep`, `pr-review-delayed-retry`, `repair-pr-approvals`, `dismiss-stale-bot-reviews`; the standing-approval, self-dismissed-approval, verify-approval and carry-forward libraries; the three review stubs in each cut-over repo. | No approval dismissed by its own Role. Share of agent pull requests merged with a standing approval on cut-over repos against the rest. Class A inflow. |
| **4. Fix intents under the contract.** | fix-CI, fix-review-findings and resolve-conflicts with no write credential in the model; generated claims. The ADR that supersedes ADR-0011 lands here. | `dev-lead-retry` and its four scans; the `resume` job; the dispatch-channel gate and payload-field check; claim verification, landing and retraction. | No published claim without a pushed commit. Rework share of spend, now measurable. Class B and D inflow. |
| **5. Implementation and the driver under Admission.** | implement-issue and the initiative driver admitted by the Controller; org-wide capacity, priority, ceilings and Pause. | The run-time fetch of the limit gate from another repo's default branch (`scripts/dev-lead-fix-issue.sh:415-452`); the partial pause switch; the dry-run budget poller. | A Pause stops every Role and resumes without re-triggering. A deferred Run shows its reason and time. No Run started against an exhausted window. |
| **6. Personas and one release for everything.** | Advisory Roles on the contract; promotion gated on eval and ring records; the last per-agent channels retired. The ADRs that supersede ADR-0002 and ADR-0006 land here. | The persona runner and the router in the standards repo; the standards repo's promotion engine for factory agents; the stub-drift tools; the hand-written interaction table and its validator. | No manual promotion for four weeks; one rollback exercised; one new advisory Role added in one pull request. |
| **7. Exit.** | The PRD's four-week criteria. The decision on a separate repo. | Whatever in §3.2 still lacks a recorded reason to remain. | §10.3 of the PRD. |

Notes on the order:

- **Step 1 before anything that decides.** It tests the Lifecycle against real traffic while being
  unable to harm it, and it supplies the measurements whose absence the PRD records. If the
  disagreement list is long, that is the finding, and it costs nothing in production.
- **Review before fixing.** The largest failure class is the approval that never issues; the review
  role already applies its effects from the wrapper, so its harness change is the smallest; and a
  working gate is what makes the later cutovers verifiable.
- **Do not fan out ADR-0007's per-role ingress to the remaining repos first**
  (`petry-projects/.github-private#2177 — [Decision] Fan out the ADR-0007 ingress collapse to the
  rest of the fleet: go/no-go, repo order, and runbook, using the markets pilot evidence`). Each
  repo would then be migrated twice. Let steps 3 to 6 install the one-job ingress as they cut over.
- **The POC is frozen for features from step 1.** Defect fixes only. Otherwise the target moves.

---

## 9. Relationship to ADR-0001 through ADR-0011

ADR-0000 offers three statuses and one permitted edit to an accepted record. It has no way to mark
an ADR as extended or narrowed, a gap ADR-0010 recorded and left open. The table uses four words;
only "supersede" changes a status.

| ADR | Verdict | What happens | How to record it |
|---|---|---|---|
| 0000 process | **Keep.** | ADR-0012 follows it. The missing `extended-by` link is felt again here. | Recommend, separately, an ADR that supersedes 0000 to add a forward link for extension. Not required by this decision. |
| 0001 thin caller / reusable | **Keep, and tighten.** | The consumer file and the entry shim are both thin callers. The boundary gets stricter: the shim has no logic at all. | ADR-0012 cites it; no status change. |
| 0002 channel tags and rings | **Supersede**, restating what survives. | Two tag kinds, ruleset protection and one App-moved path survive. The unit changes from per reusable to the factory; tiers reduce to two. Non-factory reusables in the standards repo keep their own names. | The release follow-on ADR supersedes it at step 6. Until then it governs the POC's tags. |
| 0003 rubric registry | **Keep, narrowed in scope.** | Binding review target to method by data is the same idea as the Role manifest. The registry stays an input adapter above the Engine port. | No status change; ADR-0012 names it as a seam. |
| 0004 pure logic plus bats | **Supersede**, restating the principle. | Purity, I/O at the edge, the model only where it must be, and fail-loud all survive and get stricter. The binding to shell and bats does not. | The language follow-on ADR supersedes it when the first Kernel module merges. Legacy scripts stay under 0004 until deleted. |
| 0005 advisory by default | **Keep, extended.** | Write stays an explicit opt-in. The opt-in is expressed as permitted Effects in the manifest and enforced by `apply`, which also closes the gap that nothing enforces `gate_label` today (§3.6). | The run-contract follow-on ADR extends it; no status change. |
| 0006 shared-runtime personas not ring-registered | **Supersede**, restating what survives. | Its insight, that a persona is data served by a runtime and the runtime is the unit of release, becomes the rule for every Role. Its boundary that the reach check is the sole promotion gate is replaced by the release gate. | The release follow-on ADR supersedes it at step 6. |
| 0007 one ingress per repo | **Keep, extended.** | One file per repo stands. One job per role is replaced by one job, because per-role permissions and pins no longer live in the caller. The rejection of a hosted receiver stands, with new reopen triggers (§7.5). | The admission follow-on ADR extends it, as 0010 did; no status change. |
| 0008 personas post as the owner | **Supersede.** | Reversed, for the reasons in §6.4. Its analysis of the recursion guard is carried forward: the actor axis returns. | The identity follow-on ADR supersedes it at step 2. This is the only reversal of a decision that was argued in full. |
| 0009 qa-lead surface through the router | **Keep until it lapses.** | "No second ingress path" becomes true by construction. Its hard precondition, that a human hold binds on every surface, is met by admission. The router it names is retired at step 6. | Superseded by the admission follow-on ADR when the router is retired; until then it governs. |
| 0010 ingress concurrency; schema is an allowlist | **Keep the principle; the key lapses.** | The allowlist rule is kept and made stricter. Job-level concurrency in the consumer file is no longer needed, because the lane is in the hub. | The admission follow-on ADR extends 0007 again and notes that 0010's key is unused; no status change. |
| 0011 write-mode personas on a shared branch (proposed) | **Accept now; supersede later.** | Its five rules are right for the POC and already implemented. Under the run contract, rules 2 and 3 hold by construction and rules 1, 4 and 5 become `verify` and `apply` steps. | Accept it as the interim record at step 0. The run-contract follow-on ADR supersedes it at step 4. |

Two normative documents that are not ADRs also change: interaction model §12.2 is reversed by the
identity decision and should say so with a pointer, and its §§5 to 9 are largely replaced by the
Lifecycle files once those exist.

**Why ADR-0012 supersedes nothing itself.** It fixes the structure and binds new code. Each
supersession is recorded by the follow-on ADR that lands with the step that makes it true in the
running system. The alternative, flipping several statuses on acceptance, would make the record claim
things the system does not yet do, which is the reverse of the defect ADR-0008 was written to repair.

---

## 10. Where the first draft of the PRD was wrong, over-specified or unachievable

The analysis tested the PRD against the constraints and found twelve problems. The PRD has been
revised for each. They are kept here because the reasons are architectural and the next requirement
written will meet the same limits. "Achievable" states what the PRD now says.

1. **FR-2, "the visible State and the State record never disagree."** Two objects on an eventually
   consistent platform will disagree for some interval. Achievable: a disagreement is detected and
   repaired at the next evaluation, and counted.
2. **FR-46, "nothing is live at merge."** Unachievable on Actions as written. A `schedule` or
   `repository_dispatch` run always executes the default branch's workflow file (GitHub
   documentation, read 2026-10-10). Achievable: the only artifacts live at merge are frozen entry
   shims that contain no logic.
3. **NFR-1.** It counts workflow runs and caps cancelled or evicted runs at 5%. Under level-triggered
   admission an evicted wake is the coalescing FR-16 asks for. Count **Runs** per merged change, cap
   lost **admitted Runs**, and report wakes separately.
4. **FR-15, "every Admission decision is recorded."** Recording every identical refusal of a held
   item is noise. Record a decision when it differs from the last one for that item; count repeats.
5. **FR-35, a "positively verified" capacity signal.** Not achievable for the LLM window under C-3:
   there is no supported usage interface. Achievable: an estimate that defers when missing. The
   first draft also lacked the LLM counterpart of FR-37: if the factory's subscription credential is
   shared with interactive use, the estimate is unsound. FR-37 and OQ-3 now say so.
6. **FR-55, "held-out."** Every repo is public (C-2), so a held-out set is readable by anyone,
   including the agent that edits the prompt it scores. Either keep it in a private data repo, which
   touches the open half of C-4, or call it a convention guarded by code ownership.
7. **FR-60, "scoped … and short-lived."** Conflicts with C-6 while code-owner review is
   required: the reviewer must be a user account. One stated exception, confined to the `apply` job.
8. **FR-51, "fully served within an hour."** Holds for Roles. Advisory reviewers need per-repo
   installs in vendor consoles that the factory does not control (`DG:scripts/bootstrap-new-repo.sh:1-45`). And "a new trigger requires
   no edit in the consumer" holds only if the one consumer file subscribes to a fixed superset of
   events from the start, which the recommendation does. That superset cannot include "any workflow
   finished": `workflow_run` must name workflows, so CI completion is heard only for repos whose CI
   carries a standard name (finding 6 below); others fall back to the sweep.
9. **FR-26, "attributable by actor alone."** Achievable at the grain of agent versus human. At the
   grain of Role it would need one App per Role, which is not recommended.
10. **C-5 was out of date in two places.** One running plus one pending is now the default, not the
    limit (`queue: max`). And events authored with the default workflow token do start
    `workflow_dispatch` and `repository_dispatch` runs; the repo's two contradictory statements of
    this rule (`docs/agentic-interaction-model.md:260-263` against `scripts/auto-rebase-retry.sh:80-81`)
    are resolved by the documentation in favour of `scripts/auto-rebase-retry.sh`.
11. **NFR-8 against C-3.** A 48-hour release lag with eval-gated promotion is feasible only if
    candidates are batched; six cuts a day, the current cadence, would spend the window on evals.
12. **Exit criterion 5 against §10.2.** "The Maintainer's account authored no agent action" pulls
    the planner and idea triage, which the scope leaves "running as they are", into the identity
    cutover. §10.1 now says so.

---

## 11. What could not be determined, and the platform facts this rests on

### 11.1 Verified against official documentation on 2026-10-10

| # | Fact | Source |
|---|---|---|
| V-1 | Events authored with the default workflow token create no run, except `workflow_dispatch` and `repository_dispatch`, which always do. An App installation token or a PAT does trigger runs. | docs.github.com, "Triggering a workflow" |
| V-2 | An App installation has its own limit of at least 5,000 requests an hour (more above 20 repos or 20 users, capped at 12,500). The default workflow token has 1,000 an hour per repo. A user has 5,000. | docs.github.com, "Rate limits for the REST API" |
| V-3 | A concurrency group has one running entry. Pending defaults to one (`queue: single`); `queue: max` allows up to 100 and cannot be combined with `cancel-in-progress: true`. Order is not guaranteed. | docs.github.com, "Control the concurrency of workflows and jobs"; "Workflow syntax" |
| V-4 | A code owner is a user or a team with explicit write access. The page does not list Apps. | docs.github.com, "About code owners" |
| V-5 | The merge queue does not require a branch to be current, needs required checks to run on `merge_group`, and removes an entry on failure, timeout, manual removal or an unresolvable protection failure. | docs.github.com, "Managing a merge queue" |
| V-6 | Stale approvals are dismissed when the diff changes or the merge base changes. The last-push rule requires approval from someone other than the last pusher. | docs.github.com, "Available rules for rulesets" |
| V-7 | `schedule` runs can be delayed and, under load, dropped; they run on the default branch. `repository_dispatch` runs the default branch's file; its payload is limited to 10 top-level properties. | docs.github.com, "Events that trigger workflows" |
| V-8 | One person may keep one free machine account besides a personal account. | GitHub Terms of Service, B.3 |
| V-9 | `gh-aw`: a read-only agent job with typed safe outputs applied by separate jobs, including push to a pull-request branch, submit a review and resolve a thread. Claude engine auth is documented as an API key or workload identity. No cross-provider fallback. | github.github.com/gh-aw, safe-outputs and engines references |
| V-10 | Claude Code headless: JSON output carries cost, usage and session id; `--json-schema` returns validated structured output; `--resume` takes a session id or a transcript path. `--bare` mode ignores OAuth credentials and is documented as the future default for `-p`. | code.claude.com/docs, "Run Claude Code programmatically" |

### 11.2 Assumptions, not verified

| # | Assumption | Matters for | Cheapest check |
|---|---|---|---|
| A-1 | Whether an App's approval counts toward the required approval count. | Only option (e) of §6.4, which is not recommended. | Not needed. |
| A-2 | An App-authored pull request needs no extra approval. The ruleset page describes one for Copilot-authored pull requests. | §6.4 | One pull request on the canary repo in step 2. |
| A-3 | An App can enable auto-merge and add a pull request to the queue. | §6.4, §6.9 | Same. |
| A-4 | The queue evaluates reviews only on entry. Observed here (`scripts/lib/merge-queue-dequeue.sh:5-8`); the documentation is silent. Whether a push to a queued pull request removes it is also unstated. | §6.9 | Already observed; keep the dequeue. |
| A-5 | An installation token can be minted with a subset of the App's permissions and repositories. Long-standing API behaviour; not re-read today. | FR-60 | Step 0. |
| A-6 | A `uses:` reference to another repo cannot be an expression. The documentation states this for the local form. | §6.5 | A lint run. |
| A-7 | `queue: max` is available to this org and accepted by its linters. | Step 0 | Try it on one lane. |
| A-8 | The subscription token keeps working for `-p` once `--bare` becomes the default. If not, every Role needs an explicit opt-out or C-3 changes. | Everything that runs a model | Watch the changelog; pin the CLI version (the POC resolves `latest` at run time, `.github/workflows/dev-lead-reusable.yml:387-411`). |
| A-9 | A fine-grained token cannot submit a review (`.github/workflows/pr-review.yml:174-178`). | The reviewer's blast radius | Try the REST endpoint with a fine-grained token. |
| A-10 | Ledger pushes do not contend badly at real volume. | §6.1 | Step 1 measures it. |
| A-11 | Reads per evaluation keep the installation under 60% of its limit. Conditional requests are not documented as free. | NFR-14 | Step 1 measures it. |
| A-12 | The free plan's concurrent-job ceiling is not the binding limit once fan-out stops. A queue of 200+ runs was observed on 2026-10-10. | The O3 reopen trigger | Measure after step 0. |

### 11.3 Not determined

- **The migration budget (OQ-9).** Nothing in the evidence prices the kernel, the harness or six
  cutovers in weeks or in LLM spend.
- **What a full eval pass costs** against the subscription window, and so how often a candidate can
  be gated.
- **Why `gh-aw` was re-implemented rather than used.** The reason would bear on §6.3.
- **The logic inside the standards repo's routers,** and what the deployed channel tags run as
  opposed to `main`. The review read the hosting repo's tree.
- **Live values of the Actions variables** that override defaults, including the automation-login
  list on which the loop-ceiling finding depends.
- **Whether the budget poller has ever produced a usable reading.**
- **Current consumer pins.** The local checkouts are twelve weeks old.
- **How much of the bats suite's incident knowledge can be recovered as recorded fixtures.** Step 1's
  disagreement list is the first measurement.

---

## 12. Defects found in passing

These are not architecture. Each is a concrete fault worth fixing whichever option is chosen. Items
marked ✓ were re-checked by hand against the code or the documentation; the others were read once.

| # | Defect | Evidence |
|---|---|---|
| 1 ✓ | The per-pull-request automation budget cannot count dev-lead. Its bot list omits the account dev-lead acts as, so dev-lead's activity resets the count. The effect is inferred from the code and was not observed in a run. | `scripts/lib/pr-automation-budget.sh:32`; `personas/dev-lead/persona.yml:107-109` |
| 2 ✓ | `AGENTS_PAUSED` pauses dev-lead only. pr-review's error message tells operators to use it, and pr-review does not read it. | `.github/workflows/dev-lead-reusable.yml:116`; `.github/workflows/pr-review.yml:344` |
| 3 ✓ | The fleet monitor's wake-up for dev-lead carries no pull-request or issue number, and the receiver skips a payload without one. The interaction model cites this as the canonical bridge. | `.github/workflows/actions-fleet-monitor.yml:489`; `scripts/dev-lead-intent.sh:682-686` |
| 4 ✓ | The CI failure analyst's prompt loses its `run_id` variable to unscoped `envsubst`, so the model is told to run `gh run view ""`. | `.github/workflows/ci-failure-analyst-reusable.yml:115-117`, `:159` |
| 5 ✓ | Four bats files run in no workflow: `test_cli_error_routing`, `test_rate_limit`, `test_review_one_pr_escalation_exit`, `test_validate_engines`. `scripts/validate-engines.sh` is wired to nothing. | `.github/workflows/lint.yml:95-258` |
| 6 ✓ | The timeout guardrail checks the sum of all tier budgets against dev-lead's 120-minute job, which runs one tier. The job that chains the tiers is pr-review's, capped at 60 minutes. | `scripts/dev-lead-timeout-guardrail.sh:29`; `.github/workflows/pr-review.yml:157` |
| 7 | Token metering records only successful calls, and names the wrong model after an in-chain fallback in the deep and writer tiers. | `scripts/engine.sh:1801`, `:1962`, `:1740-1745` |
| 8 ✓ | The proactive Claude headroom probe needs `ANTHROPIC_API_KEY`, which no workflow supplies, and logs "usage 0% — ok" on every call. | `scripts/engine.sh:500-517`, `:591` |
| 9 ✓ | `scripts/cut-release.sh` does not know three registered agents: `apply-repo-settings`, `idea-triage`, `initiative-planner`. | `scripts/cut-release.sh:70-89` |
| 10 | The standards repo still dispatches to an `idea-enhancer.yml` that was removed from this repo. | `DG:.github/workflows/idea-enhancer-reusable.yml:71` |
| 11 ✓ | The Claude Code CLI resolves to `latest` at run time unless a variable pins it. Its documentation says bare mode will become the default for `-p` and that bare mode does not read OAuth credentials, which is how every agent here authenticates. | `.github/workflows/dev-lead-reusable.yml:396-401`; code.claude.com/docs, "Run Claude Code programmatically", read 2026-10-10 |
| 12 ✓ | dev-lead fetches a gate script from another repo's default branch at run time and sources it, failing open on any error. | `scripts/dev-lead-fix-issue.sh:404-452` |
| 13 | `release/registry.yml` is a second ring registry that only a test reads, and it disagrees with the real one. | `release/registry.yml:1-41` |
| 14 | Four documents contradict the code on live behaviour: `AGENTS.md:92-93` says dev-lead reads only an issue's title and body while `scripts/dev-lead-fix-issue.sh:573` passes comments; the merge-queue decision record says deferred while the queue is on (`docs/initiatives/auto-rebase-vs-merge-queue.md:3-9`); `CLAUDE.md` calls this repo private; and the interaction model's rule on the default token and dispatch events (`docs/agentic-interaction-model.md:260-263`) contradicts both `scripts/auto-rebase-retry.sh:80-81` and GitHub's documentation. | as cited |
| 15 | The daily fleet failure report appears to have stopped after 2026-09-20, and sampled fleet-monitor runs fail. Not confirmed from run logs. | Issue history; `petry-projects/.github-private#1852 — petry-projects — workflow failures detected 2026-09-20` is the last |

---

## 13. Comparison with other systems

Added after the options analysis, to test the recommendation against systems built by other
people. Sources were read on 2026-10-10. Each is marked **P** (primary source read directly) or
**S** (secondary coverage; details may be wrong).

### 13.1 The systems

| System | Human in the loop | Orchestrator | Where work state lives | How roles interact | Who writes to the outside world | How correctness is established |
|---|---|---|---|---|---|---|
| **StrongDM Software Factory** (P for principles, S for the rest) | None by rule: "Code must not be written by humans. Code must not be reviewed by humans." | A non-interactive agent loop | Not published | Not published | The agent | Scenarios held outside the codebase, "similar to a holdout set", judged by an LLM as a satisfaction fraction; behavioural clones of third-party services |
| **OpenAI Symphony** (P: `SPEC.md`) | Work can end at a handoff state such as human review | A long-running service that ticks every 30 s; reconciliation runs before dispatch on every tick | The issue tracker. Scheduler state is in memory only; restart recovery is "tracker-driven and filesystem-driven (without a durable orchestrator DB)" | Not role-to-role: the orchestrator dispatches one agent per ready issue into an isolated workspace | The agent, through tools; "each implementation defines its own trust boundary" | Left to the workflow; secondary sources describe evidence such as CI status attached to the pull request |
| **OpenAI harness engineering** (S; the primary post could not be fetched) | Reported as optional review | Engineers prompting agents; later Symphony | The repo: a structured `docs/` tree is the system of record | Agents request reviews from other agents and iterate until they are satisfied | The agent | Mechanical architecture rules; background agents that open small cleanup pull requests |
| **Gas Town** (S) | One human talks to one coordinating agent | A local, always-on town of agents | Beads, a ledger that began as JSONL in git plus SQLite and moved to Dolt, a versioned SQL database | Named roles: Mayor decomposes and assigns, Polecats work in isolated worktrees, a Refinery runs a merge queue per project, a Witness and a Deacon watch for stuck workers | Workers; the Refinery merges | The merge queue's tests |
| **Cursor long-running agents** (P) | None during a run | A harness that runs planners, workers and a judge in cycles | A shared branch | Planners create tasks; workers "grind on their assigned task until it's done, then push"; a judge decides whether to continue | Workers push to one branch | The judge, and the project's own tests |
| **Anthropic parallel-agent C compiler** (S for mechanism) | None | None: a loop restarts each agent | Lock files in a directory of the repo | Agents claim a task by writing a lock file and sync through git | Each agent | A large test suite, and a reference compiler used as an oracle |
| **Kubernetes Prow and Tide** (P: Prow docs; not agentic) | Humans approve with commands that set labels | Always-on services; Tide syncs with GitHub every minute | Labels and GitHub's own state, read by search queries | Plugins set labels; Tide merges whatever the queries return | Tide | Required tests re-run against the latest base, in batches |

Research frameworks sit to one side of these. MetaGPT passes structured documents between roles in
a fixed order through a shared message pool; ChatDev and AutoGen have roles converse. None is
presented as a production system.

### 13.2 How roles interact, across all of them

1. **Conversation.** Roles talk in natural language (AutoGen, ChatDev). No production-leaning system
   above uses it.
2. **Structured handoff.** Roles pass typed documents in a declared order (MetaGPT, and the BMAD
   method this repo vendors). ADR-0012's Task and Result are this pattern.
3. **A shared work ledger.** Roles never address each other. They take work from a durable store and
   put results back (Beads, Symphony's tracker, the compiler's lock directory, Tide's labels). Every
   system above that runs unattended for long uses this. ADR-0012's State record and Ledger are this
   pattern.
4. **Hierarchy.** One role plans, others execute, another judges. Cursor reports that equal peers
   became risk-averse: "No agent took responsibility for hard problems or end-to-end
   implementation."
5. **Supervision as a role.** Gas Town makes its watchdogs first-class. Symphony's tick detects a
   stalled run after five minutes without an event and retries with backoff.

The POC uses a sixth pattern that none of these chose: roles signal each other by side effect, with
comments, labels and markers on a surface shared with humans and third-party bots (§3.2).

### 13.3 Where the proposal is stronger than the comparables

- **Effects are applied outside the model.** In Symphony, Cursor's harness and the compiler
  experiment the agent itself writes. Symphony's specification leaves the trust boundary to each
  implementation and its README is reported to describe it as a preview for trusted environments.
  ADR-0012's credential boundary per job is stricter than any comparable, and it is the right
  strictness for public repos that take text from strangers.
- **Review independence is enforced by the platform.** The comparables either remove review
  (StrongDM), or let agents review agents with no separation of identity (OpenAI). ADR-0012 keeps a
  gate that the author's identity cannot satisfy.
- **State survives a restart with its history.** Symphony deliberately keeps scheduler state in
  memory and re-derives it. That is simple, and it means attempts, spend and dispositions are not
  recorded anywhere. ADR-0012's Ledger makes cost per outcome and "why is this stuck" answerable.
- **It releases itself safely.** None of the comparables describes versioning, staged rollout or
  rollback of the factory. They are single-team tools. This repo serves twelve.
- **It is frugal.** StrongDM's stated benchmark is $1,000 a day in tokens per engineer. This fleet's
  measured spend is $196–280 a week (§2).

### 13.4 Where the proposal is weaker than the comparables

- **Every comparable that orchestrates has an always-on orchestrator.** Symphony ticks every 30
  seconds. Tide syncs every minute. Gas Town runs as a standing process. Each holds its claim set in
  one process, so double dispatch is avoided by a variable, and a timer is a timer. ADR-0012
  emulates that process with wake-ups, concurrency lanes and a cron that drops about 60% of its
  ticks. Symphony's own non-goals include being a "general-purpose workflow engine or distributed
  job scheduler"; ADR-0012 builds one out of Actions.
- **Files in git as the work ledger is a design another project abandoned.** Beads kept a local
  database synchronized through a JSONL file in git. Its maintainers record stale overwrites,
  resurrected deletions and split-brain failures from that period, and moved to a database with
  merge semantics. ADR-0012's store differs in one way that matters: only the Controller writes it,
  so there is no multi-writer merge. Concurrent Controller runs still race on one ref.
- **Assurance rests on review by the same model family that wrote the change.** StrongDM's answer
  to agents that "return true" or rewrite a test is validation the author cannot see. The compiler
  experiment needed a reference oracle. ADR-0012 verifies that a claimed commit exists. It adds
  nothing that tells a correct change from a plausible one, and this repo's holdout sets are public.
- **A mandatory quality gate is a bottleneck by construction.** Cursor built an integrator role for
  quality control and removed it: it "created more bottlenecks than it solved." The contexts differ,
  since Cursor was building greenfield on one branch with no protected trunk. The observation still
  applies to a single approval that five gates can withhold.
- **It is much larger.** Symphony is one specification. The compiler harness is a shell loop.
  ADR-0012 requires a kernel, a harness, a controller and eight further ADRs, for one maintainer.
- **Nobody has shown this problem solved.** A September 2026 synthesis of industrial evidence
  concludes that no company has implemented a full control plane of this kind, and cites agents
  raising commits by 180% while releases rose 30%. The comparables are single-repo, mostly
  greenfield and run inside one trusted team. This factory is multi-repo, brownfield and public.

### 13.5 Choices the proposal makes that others abandoned

| Choice in ADR-0012 | Who abandoned it | Why it may still hold here | What would show it does not |
|---|---|---|---|
| Work state as files in git | Beads | Single writer identity; no merge of concurrent edits to one record | Rejected pushes per decision, or time to clone the store, rising with load |
| Leases taken by optimistic write | Cursor moved past it | Cursor called optimistic control "simpler and more robust" than locks; its remaining problems were about who owns hard work, which hierarchy answers | Re-decisions per admitted Run above a small constant |
| A quality gate every change must pass | Cursor | The ruleset requires an approval, and the repos are public | Share of lead time spent waiting at the gate |
| Agents reviewing agents as the main assurance | StrongDM | No budget for a scenario estate, and no private place to hold one | Escaped defects per hundred merges (SM-C1) rising with the autonomy rate |
| No standing process | None of them tried it | Constraint C-4 | The reopen triggers in §7.5 |

### 13.6 Sources

- StrongDM Software Factory: <https://factory.strongdm.ai/>; Simon Willison's account,
  <https://simonwillison.net/2026/feb/7/software-factory/>
- OpenAI Symphony specification: <https://github.com/openai/symphony/blob/main/SPEC.md>; OpenAI,
  "Harness engineering", <https://openai.com/index/harness-engineering/>
- Gas Town: <https://www.heise.de/en/background/Full-Control-Gas-Town-Orchestrates-Ten-or-More-Coding-Agents-11178824.html>;
  Beads storage: <https://beads.gascity.com/architecture/dolt>
- Cursor, "Scaling long-running autonomous coding": <https://cursor.com/blog/scaling-agents>
- Anthropic, "Building a C compiler with a team of parallel Claudes":
  <https://anthropic.com/engineering/building-c-compiler>
- Prow and Tide: <https://docs.prow.k8s.io/docs/components/core/tide>
- Cemri et al., "Why Do Multi-Agent LLM Systems Fail?": <https://arxiv.org/abs/2503.13657>
- Bhati, "Beyond Code Generation": <https://arxiv.org/abs/2609.04681>
- MetaGPT: <https://arxiv.org/abs/2308.00352>; AutoGen: <https://arxiv.org/abs/2308.08155>

---

## 14. Adversarial review: the ceiling, and where it fails first

An independent pass attacked ADR-0012 after §§4–13 were written. It had no part in the design. Its
platform claims were read from GitHub's documentation on 2026-10-10 and its repo claims re-checked
here. Figures marked *est.* are estimates with the stated range.

**Verdict: approve with named changes, not as written.** Four decisions are sound and do not depend
on the substrate: the run contract and credential split, agent identity, content-bound approval,
and verification that binds. Two were a bet taken before the measurements that would justify it:
the git-backed store, and a Controller woken per event on Actions. The first draft also carried no
budget and no stopping rule. §14.7 lists what was changed in the ADR as a result.

### 14.1 The ceiling

| Rank | Constraint | Where it binds | What ADR-0012 does to it |
|---:|---|---|---|
| 1 | **The maintainer's attention** | About 30–36 hosting-repo merges a week, the observed plateau (*est.* from a time model; see below) | Nothing directly. It rises only if approvals issue *and* can be trusted |
| 2 | **First-pass correctness** | The autonomy rate at which escaped defects exceed what one person can absorb (§14.4) | Nothing. Review depth is out of scope |
| 3 | **The LLM weekly window** | About 100–150 org merges a week at POC efficiency (*est.*, ±50%); reached or approached in about two of the last eight weeks | Cuts waste under it. Adds new claims on it: the rewrite itself, and an eval pass per promotion |
| 4 | **20 hosted-runner jobs, org-wide** | Saturated at peaks today; about 55–80 hosting-repo merges a week sustained (*est.*) | 2–3× from stopping the rebase fan-out and sleeping runners, less a 10–25% tax for wake handling |
| 5 | **App API quota**, 5,000 an hour | Holds only if an evaluation costs at most about 3 GraphQL points; 3.4× over at the POC's call style at peak | A separate quota is a real gain. The margin depends on a read budget nobody has written |
| 6 | **Git as the ledger** | 8–18 pushes a minute at peak against GitHub's recommended maximum of 6 per repository | A new constraint the POC does not have |
| 7 | The merge queue | Above 1,000 merges a week | Does not bind |

**The architecture removes waste under constraints 3 to 6. It does not raise constraints 1 or 2,
and those are the ones that bind.**

The reasoning behind rank 1: merges in the hosting repo have been flat at 14–36 a week since late
August while workflow runs rose about fivefold (§2). A ceiling that does not respond to five times
more machine activity is not a machine ceiling. In the latest week 21 of 36 merges went in by hand
without a standing approval, and holds were cleared by the owner account 64 times across 150 merged
pull requests. A model of that work (an audit per bypass merge, hold triage, promotions, filing and
steering) comes to 10–12 hours a week at about 36 merges. The model is an estimate, and the shared
login means nothing measures it. One week after agents move to their own identity it can be counted.

The runner arithmetic, because it is the least obvious. The free plan allows 20 concurrent jobs.
One push to a pull request in the hosting repo starts about 56 (counted from
`.github/workflows/*.yml`; 66 across all pull-request event types). Auto-rebase updates every behind
pull request by default (`.github/workflows/auto-rebase.yml:25-30`), so with 14 open, one merge to
`main` starts 784 jobs: about 28 minutes of total saturation (*est.*, range 13–42). About a fifth of
sampled job time is a runner asleep, waiting for a rate-limit reset
(`.github/workflows/pr-review-delayed-retry.yml:16`, `:79`).

What the design adds to that: a comment that needs no work costs one runner job today and two
skipped listeners. Under ADR-0012 as first drafted it costs three runner jobs: the consumer's
ingress, ring resolution in the entry shim, and the decision. Scaled from the measured event mix,
that is at least 12,500 wakes a week from the hosting repo alone. Unfiltered, wake handling would
take about 18% of the org's runner slots on average and about 83% at the measured peak. With events
authored by the factory's own identities dropped at the ingress, 7% and 33%. The filter matters
because the fleet is its own largest event source: 85% of sampled comment, review and push events
were authored by the two agent accounts, and under ADR-0012 those become App-authored events that
start workflows.

### 14.2 Where it fails first

Ranked by how early and how surely each appears.

1. **The migration starves.** The ADR freezes the POC to defect fixes. Bug-labelled issues arrive at
   21–36 a week and 31% of defect issues name a prior one, so holding the POC still needs about
   30–52 fix pull requests a week. The line delivers 29–36. The rewrite is on the order of 100–150
   pull requests, each needing the approval that currently does not issue. The repo's record on
   finishing migrations is poor: ADR-0007 is accepted and not deployed here, ADR-0009 serves one
   surface twice, `release/registry.yml` is an orphan, the budget breaker was closed and cannot fire
   (`petry-projects/.github#1155 — The token-budget breaker is unreachable`), and five consumers
   still pin a legacy tag (`petry-projects/.github#1125 — Fleet pr-review callers pin legacy bare
   pr-review/stable and are unmanaged`). *Signal:* the weekly share of merged pull requests that
   touch `factory/`; under 30% for three weeks means the freeze is nominal. *When:* the first day
   of step 1.
2. **Step 1 is not harmless.** Observing by per-event wake competes with the line for the same 20
   slots (§14.1). A status block rewritten on every evaluation can reach GitHub's limit of about 500
   content-creating requests an hour, which would throttle every factory write. The ledger exceeds
   the recommended push rate at peak. A status block that prints a "last evaluated" time is also a
   self-wake loop if the ingress hears comment edits. *Cheapest mitigation:* run step 1 as a
   **poller**: one scheduled job that evaluates every open item in one process and writes one commit
   per pass. An observer does not care about dropped ticks.
3. **Approvals still do not issue after the review cutover.** See §14.3. *Kill criterion:* if the
   share of agent merges with a standing approval on the first cut-over repo is under 70% after two
   weeks, stop the fan-out.
4. **Effects are not idempotent, and no brake sat outside the Kernel.** GitHub writes carry no
   idempotency key. If `apply` dies after applying some Effects and before the ledger commit, the
   next evaluation either re-applies (duplicate comments and reviews) or re-admits (a second model
   Run and duplicates). The usual cure is a marker in the body, which the first draft forbade
   reading. Separately, the first draft put Pause "in the admission function and nowhere else", so a
   broken Kernel would be the thing evaluating Pause, where today the pause is a job condition the
   platform evaluates (`.github/workflows/dev-lead-reusable.yml:116`). With App-authored events
   starting workflows, a Kernel defect is an org-wide loop: one Run per five minutes on 14 items is
   168 an hour, and a week's window of about 600 Runs is gone in under four hours. The precedent ran
   four days unnoticed (`docs/postmortems/2026-06-pr-860-runaway.md`).
5. **The credential boundary stops at the hub.** `apply` pushes model-authored commits to a branch
   in the consumer. GitHub then runs that branch's own `pull_request` workflows with the repo's
   secrets. No workflow here uses an `environment:`, and nine pass `secrets: inherit`. A
   model-authored edit to a workflow, or to code a workflow runs, can read whatever that repo can.
   This is not new exposure, since today the model holds the owner credential outright. It is a
   boundary the first draft claimed and did not have. Related: the credential a consumer uses to
   send a wake needs `Contents: write` or `Actions: write` on the hub, so it is not dispatch-only;
   and `verify` runs consumer code in the hub's context, where a `repository_dispatch` run may write
   default-branch caches that every later job can restore.
6. **"CI finished" is hard for one frozen ingress file to hear.** `check_run` and `check_suite` do
   not start workflows for suites created by Actions, and `workflow_run` must name the workflows it
   watches (`.github/workflows/pr-auto-review.yml:32-34` names `"CI"`). A byte-identical consumer
   file works only if every repo's CI carries a standard name. Otherwise the commonest transition,
   checks green to review, waits for a sweep that fires every 3–8 hours in practice
   (`petry-projects/.github-private#2170 — Retry and sweep crons run every 4–8 hours instead of
   every 2 h / 15 min`).
7. **The identity cutover meets an untested rule.** The live ruleset sets
   `require_extra_approval_for_unattributed_changes: true`. GitHub documents it for agent-authored
   pull requests not attributed to a person. If it applies to a pull request authored by the factory
   App, every agent change needs two approvals and the org has one non-human approver. One test pull
   request settles it.
8. **Promotion needs the scarcest resource.** In the weeks the model window is spent, no Release can
   be promoted, so a bad `stable` cannot be fixed forward. Rollback must run nothing from the Release
   it is rolling back.
9. **The model CLI changes under every Role at once** (§12, item 11).

### 14.3 Is the largest failure class caused by architecture?

Mostly not, and this is the finding that most changes the picture.

- **The same implicit control plane once delivered.** The week of 2026-07-12 saw 79 merges at a
  median of 0.9 hours; the week of 08-02, 27 at 0.9 hours. What changed afterwards was the number of
  things an approval must survive. Class A went from 1 to 17 to 45 issues over three four-week
  windows as the maintainer-comment gate was added and then redesigned so that every pull-request
  comment, "from human maintainers and bots alike", needs a verified disposition
  (`scripts/lib/maintainer-comment-gate.sh:15-30`).
- **Those gates had reasons**: zero-diff merges, trunk corruption, a runaway. The trade is
  throughput against assurance, and it does not depend on where state lives.
- **The environment does not change.** GitHub still dismisses a stale approval and still bars the
  last pusher from approving. Nine third-party reviewers still post free text, edit it in place and
  re-post on every commit: 1,219 review events from four of them on 174 pull requests in one week.
- **"One gate function over facts" still needs something to turn free text into facts.** A finding
  from a review bot is a comment body. A notice is recognised today by a per-bot pattern
  (`scripts/lib/reviewer-sources.tsv`). The first draft of the ADR both required findings to be
  classified and forbade code from reading a comment body. The architecture gives the heuristic one
  home. It does not remove it.

What the architecture does fix in this class: a Role dismissing its own approval, five places that
can withdraw one, and re-review of unchanged content. Those are real. They are a minority of the 45.

**One policy change would likely do more for this class than the rewrite: let human comments and
review threads gate an approval, and treat third-party reviewer output as input to the one review
pass.** It can be tried in weeks.

### 14.4 The quality ceiling

Author and reviewer are the same model family. `verify` runs the consumer's own tests, which the
author can edit. A held-out eval set in a public repo is held out by convention. The design verifies
that a claimed commit exists. It does not verify that the change is right.

Evidence that it often is not: ten zero-diff pull requests merged and closed their issues
(`petry-projects/.github-private#1620 — dev-lead merges zero-diff PRs that close their issues`);
tests were edited to match the code (`petry-projects/.github-private#2013 — dev-lead fix-reviews:
posts "Fixed" replies for changes that were never pushed, and edits tests to match its own code`);
23% of merged pull requests took ten or more commits.

Let *d* be the share of merges that carry a defect, *a* the share merged without a human audit, and
*c* the share of defects an audit catches. Escaped defects per week are *M · d · (a + (1 − a)(1 −
c))*. With 36 merges, *c* = 0.7 and *d* = 0.3:

- today, with *a* about 0.4: about 6 a week;
- at the PRD's 85% autonomy: about 10 a week;
- the PRD's defect target is 5. That needs *a* ≤ 0.23, or, at 85% autonomy, *d* ≤ 0.155.

*d* is the weak number. It is inferred from bug-issue inflow, which also counts process gaps found
by audit, so 0.3 is probably high; the plausible range is 0.15–0.4. The conclusion holds across the
range: **the PRD's autonomy and defect targets are a pair, and on current first-pass correctness
they cannot both be met.** The autonomy rate consistent with the defect target is nearer 25–40% than
85% until correctness improves. StrongDM reached the same wall and moved acceptance to scenarios the
author cannot see (§13).

### 14.5 The alternatives at their strongest

**Configuration, identity and gate scope, then re-measure.** Step 0 alone removes the largest
measured waste: 784 jobs and about 28 minutes of runner saturation per merge. The App identity alone
gives a separate API quota, lets the maintainer review agent pull requests, and makes the existing
loop budget count dev-lead with no code change, because the budget already treats a login ending in
`[bot]` as automation (`scripts/lib/pr-automation-budget.sh:54-59`). The gate-scope change of §14.3
addresses the largest failure class. Together they cost weeks. Against this: lost events, the
credential in the model, two release regimes and no ledger all remain, and this repo's local fixes
have a record of moving failures. *What decides it:* four weeks after those three changes, read the
share of agent merges with a standing approval, the inflow of classes A and D, runs per merge and
median lead time. If approvals stand on 70% or more and the median is under 8 hours, the case for
the rest of the rewrite rests on classes B, C and D alone and should be re-argued on those.

**A poller in place of per-event wakes.** Symphony, Tide and Zuul all poll or hold state in one
standing process, and in all three the control state is disposable: it is rebuilt from the platform
on restart. ADR-0012's first draft chose two things none of them did: no standing process, and a
second authoritative store that cannot be rebuilt. A poller needs no inbound endpoint, no file in
any consumer, no credential in any consumer, and no wake handling. Polling twelve repos once a
minute is 60–300 GraphQL points an hour, under 6% of the App's limit. It can run in three places:

- as a scheduled workflow in the hub. Nothing new to operate. Scheduled ticks are dropped about 60%
  of the time, so a five-minute schedule gives an effective period nearer fifteen;
- as one long-lived job in the hub that ticks in a loop and restarts itself. This gives a
  thirty-second tick and an in-memory claim set for one of twenty runner slots. GitHub's terms bar
  using Actions "as part of a serverless application" and a burden "disproportionate to the
  benefits", and do not address long-running jobs. Whether this is acceptable use is an open
  question, and it should not be relied on until that is answered;
- on a small host. This is the option constraint C-4 excludes.

*What decides it:* the Kernel does no I/O, so step 1 can run it under the wake path and under a
poller at once and compare latency, runner minutes, API points per evaluation and push retries.

### 14.6 What did not bite

- **The merge queue's rate:** under 3% used.
- **Ledger size over 180 days:** 0.4–1.5 GB against a recommended 10 GB. The shape is the problem:
  one file per event passes the recommended 3,000 entries per directory within days unless sharded,
  and "append-only" conflicts with "retention" unless the store is partitioned by time.
- **Two Runs on one item after a lease expires:** the platform lane prevents it. The cost is a
  blocked org-wide slot until the lease times out.
- **Giving up the default token's loop brake:** the POC's main writer never had it. The identity
  change improves loop counting.
- **Actions trigger limits:** 1,500 events and 500 queued runs per 10 seconds per repo are orders of
  magnitude away.
- **Python with the standard library only:** no objection found.

### 14.7 What changed in ADR-0012 as a result

| # | Required change | In the ADR |
|---|---|---|
| R1 | The git-backed store and per-event wakes are provisional, with thresholds written before step 1; the same Kernel also runs under a poller | Decision 11 |
| R2 | The ingress drops factory-authored events, holds a per-item concurrency group and subscribes to nothing that runs a branch copy of itself; the status block is throttled | Decisions 3 and 6 |
| R3 | Brakes outside the Kernel: a pause variable on the entry shim, a Run ceiling from a count the Kernel does not write, the loop count from GitHub's record of actors | Decision 3 |
| R4 | Effect application is specified: recovery keys, an intent record before a non-idempotent Effect, lease release under `always()`, rollback that runs nothing from the bad Release | Decisions 4 and 6 |
| R5 | The comment-body boundary is restated so it can hold; resolving a thread is a human transition. The first response made third-party output input only; the maintainer then directed that reviewers be integrated through a contract, so structured Findings gate and comment bodies do not (§15.5) | Decisions 2, 7 and 12 |
| R6 | Environment-scoped secrets; `run` and `verify` without permissions or cache writes; `apply` refuses changes to workflows, code owners and declared test commands without a human transition | Decisions 4 and 5 |
| R7 | The migration has a dated limit, a POC defect policy and a kill criterion, set by the maintainer before step 1 | Decision 10 |
| R8 | Escaped defects are baselined before any step raises autonomy; evals exist for the approving and code-writing Intents before their cutovers | Decisions 6 and 10; PRD NFR-3 with NFR-10, FR-59 |
| R9 | Reopen triggers for the model CLI's default, a native orchestrator from the platform vendor, and plan changes; the off-Actions trigger is evaluable from step 1 | Consequences |
| R10 | Three assumptions are settled in step 0 on a canary repo | Decision 10 |

### 14.8 Assumptions the adversarial pass could not close

- That the 20-job limit is shared by all twelve repos. The documentation does not say; a queue of
  more than 200 runs on 2026-10-10 is consistent with it.
- Whether a `repository_dispatch` call counts against the content-creation limit.
- Whether a deployment-branch restriction on an environment blocks secret access from other
  branches.
- Event rates in consumer repos, which were scaled from their share of merges.
- Job-seconds per push, and the defect rate per merge.

---

## 15. The convergence hypothesis: a council of Lenses

The maintainer's core hypothesis is that it takes a team to reach an optimal outcome: a council of
models, tools and perspectives working across research, analysis, architecture, design,
implementation, validation, release and operation. This section asks two questions. Did the first
draft of ADR-0012 consider it? And what does the evidence say?

### 15.1 Did the proposal consider it?

No. ADR-0012 as first drafted is about the control plane. It made every Role data, gave every Run
one contract and put one gate function in the Kernel. It listed review depth as not addressed, and
the PRD listed it as a non-goal. The adversarial pass then named first-pass correctness as the
second ceiling the proposal does not raise (§14.1). A council is the obvious lever on that ceiling,
and nothing in the first draft evaluated one.

The POC, by contrast, already runs a large council:

- the review cascade: triage, then a deep review with four specialist prompts (`prompts/deep-review-logic.md`,
  `-performance.md`, `-security.md`, `-style.md`) in parallel with a second opinion from another
  vendor's model (`prompts/rubber-duck.md`; `docs/engine-configuration.md:15`), then synthesis and
  an audit;
- nine advisory personas (`personas/`), each a different professional perspective;
- nine third-party reviewers (`scripts/lib/reviewer-sources.tsv`);
- CI tools that are Lenses in all but name: CodeQL, SonarCloud, the test suites.

So the hypothesis has been running in production for months. It has not been tested, because the
council interacts through discussion and nothing measures what each member contributes. The
reviewer scorecard's own-automation section reads zero and its miss rate reads 0 of 0 (§2.2).
What can be measured is the cost of the protocol: 343 review dismissals on 150 merged pull
requests, commits per merged pull request up from 2–4 to 7–10, and the largest failure class in the
issue history (§2.3, class A).

ADR-0012 now carries decision 12, and the PRD carries §6.11, as a result of this section.

### 15.2 What the evidence says

Each source is marked **P** (read directly) or **S** (secondary summary). Preprints are named as
such.

#### In favour of a council

| Finding | Evidence |
|---|---|
| An independent evaluator beats self-evaluation | Models rate their own output above equal-quality output from others, and the effect grows with their ability to recognise it (Panickssery et al., NeurIPS 2024, S). In a controlled study, one model's solo pass rate of 71.6% rose to 84.5% with self-review and to 89.7% with review by a stronger model (Xiang et al., preprint, P). Anthropic's long-running harness separates a generator from an evaluator for this reason (S) |
| Different Lenses find different defects | A second model's findings overlapped a same-model reviewer's by 37–46%, against 52–62% between two runs of the same model. One same-model plus one cross-model review matched 56.7% of planted errors, against 42.7% for two same-model reviews (Song, single-author preprint, P) |
| Parallel Lenses help on work that divides | Centralised multi-agent coordination improved a parallelisable analysis task by 80.8% (Kim et al., Google and MIT, P). Anthropic reports a multi-agent research system beating a single agent by about 90% on research tasks, at roughly fifteen times the tokens (S) |
| Structured handoff beats conversation | MetaGPT's authors report roughly half the tokens per line and higher executability than a chat-based framework, and attribute it to passing documents instead of dialogue (S; the authors' own comparison) |

#### Against a naive council

| Finding | Evidence |
|---|---|
| Collaboration hurts work that is one interdependent piece | Every multi-agent variant degraded a sequential task by 39–70% (Kim et al., P). Coding agents given two features in one codebase succeeded about 30% less often cooperating than working alone; the authors call it the curse of coordination (CooperBench, ICLR 2026, S) |
| A weaker Lens makes a stronger author worse | The stronger model alone passed 91.4%. Reviewed by the weaker model it fell to 82.8%, with an 11.2% regression rate. Reviewing itself changed nothing (Xiang et al., P) |
| Returns fall as the single agent gets better | Coordination shows diminishing or negative returns once a single agent's baseline passes about 45% (Kim et al., P) |
| Mixing models is not the same as diversity that helps | Using one strong model several times beat mixing different models by 6.6% on one benchmark, because adding models lowered average quality (Li et al., "Rethinking Mixture-of-Agents", S) |
| Models share blind spots | When two models are both wrong they give the same wrong answer about 60% of the time, and stronger models correlate more, across vendors (Kim et al., ICML 2025, S) |
| Discussion adds little over independent votes | Majority voting accounts for most of the gain credited to multi-agent debate; debate alone does not improve expected correctness (Choi et al., NeurIPS 2025, S) |
| Councils fail in their protocol | A study of more than 1,600 traces attributes multi-agent failure mainly to system design and inter-agent misalignment, not to weak models (Cemri et al., S) |

Two gaps in the literature matter here. None of these studies compares a model Lens with a Lens
grounded in execution, such as a test run or a static analyser; the claim in §15.3 that such Lenses
are the most independent is an inference from the correlated-error result and from what StrongDM
and the compiler experiment had to do (§13). And almost all of it is measured on benchmark tasks,
not on a brownfield repo over months.

### 15.3 Verdict on the hypothesis

Neither proven nor disproven as stated. It is conditionally supported, and the conditions are
specific.

**Supported:** an outcome judged by independent Lenses is better than one judged by its author; a
council raises coverage when its members can see different things; and a council is the right shape
for work that divides, which is most of research, analysis and review.

**Not supported:** that more members are better; that members improve an outcome by talking to each
other; that a council should write the change together; or that a different model brand is, by
itself, an independent view.

Put together, the form the evidence supports is: **one author, surrounded by independent Lenses
that report in parallel through a contract to something that decides.** That is a council. It is
not a conversation.

Three conditions carry most of the weight:

1. **Independence has to be real.** Different information, different tools or a different stage of
   the work make a Lens independent. A second model reading the same diff with the same prompt
   mostly does not.
2. **A Lens must be at least as capable as what it judges, or grounded in something the author is
   not.** Otherwise it subtracts.
3. **The protocol decides the result.** Structured Findings and a deterministic aggregate converge.
   Free-text discussion among agents does not, and this repo's own telemetry is the evidence.

The third condition is the maintainer's first point in other words: integrate through a contract,
render for humans, interpret structured data.

This review is itself a small instance. The options analysis was written by one author (§§4–11).
An independent pass with a fresh context and an adversarial brief then judged it and required ten
changes (§14.7). A comparison against outside systems added a third view (§13). None of the three
conversed; each reported in a document and the changes were aggregated afterwards. One case proves
nothing, and it matches the pattern.

### 15.4 A starting shape for the council, by stage

This is where the evidence points, not a decision. ADR-0012 leaves composition to a follow-on record
decided from measurement.

| Stage | Shape the evidence supports | Strength of evidence |
|---|---|---|
| Research and analysis | Lenses in parallel, one synthesiser | Strong |
| Architecture and design | One author; an independent adversarial critic; a comparison against outside practice | Moderate |
| Planning | One author; a critic checking the plan against the requirements | Moderate |
| Implementation | One author, no co-writers | Strong, against collaboration |
| Validation | Several Lenses that differ in kind: the repo's tests, static analysis, an acceptance signal the author cannot edit, a model reviewer | Moderate; the grounded-Lens part is inference |
| Review | A model reviewer at least as capable as the author; a second model only if it measurably adds Findings | Mixed |
| Release and operation | Deterministic gates and monitors as Lenses; a model Lens for diagnosis | Practice, not research |

### 15.5 Third-party reviewers under a contract

The reviewer registry already points this way. It records, per reviewer, whether it creates review
threads and the name of the check run it reports through, and the advisory gate already counts a
completed check run as a response (`scripts/lib/reviewer-sources.tsv`, columns `creates_threads`
and `check_run_name`). What it also carries is a body pattern per reviewer for recognising notices,
which is the discussion channel this decision retires.

GitHub offers three structured surfaces a reviewer can report through:

| Surface | What is structured | Can it gate |
|---|---|---|
| A check run with annotations | Conclusion; per annotation a path, lines, a level and a message. Only a GitHub App can create one | Yes, by conclusion and by annotation |
| Code-scanning alerts from a SARIF upload | Rule, severity, location, a stable alert identity and state | Yes |
| A review thread | An identity, a path and line, resolved and outdated flags. The body is prose | Yes, by the thread's state. Severity is not structured |
| A summary comment | Nothing | No |

Which of the nine current reviewers expose which surface is established in §16. The rule in
ADR-0012 does not depend on the answer: a reviewer is as influential as its contract surface
allows.

### 15.6 Sources

- Kim et al., "Towards a Science of Scaling Agent Systems": <https://arxiv.org/abs/2512.08296>
- Xiang et al., "Cross-Model LLM Code Review" (preprint): <https://arxiv.org/abs/2607.21656>
- Song, "When Does a Second Model Help?" (preprint): <https://arxiv.org/abs/2610.01471>
- "CooperBench: Why Coding Agents Cannot be Your Teammates Yet" (Stanford and SAP Labs):
  <https://arxiv.org/abs/2601.13295>
- Li et al., "Rethinking Mixture-of-Agents": <https://arxiv.org/abs/2502.00674>
- Choi et al., "Debate or Vote": <https://arxiv.org/abs/2508.17536>
- Kim et al., "Correlated Errors in Large Language Models": <https://arxiv.org/abs/2506.07962>
- Panickssery et al., "LLM Evaluators Recognize and Favor Their Own Generations":
  <https://arxiv.org/abs/2404.13076>
- Cemri et al., "Why Do Multi-Agent LLM Systems Fail?": <https://arxiv.org/abs/2503.13657>
- Anthropic, "How we built our multi-agent research system":
  <https://www.anthropic.com/engineering/multi-agent-research-system>; "Harness design for
  long-running application development":
  <https://anthropic.com/engineering/harness-design-long-running-apps>
- MetaGPT: <https://arxiv.org/abs/2308.00352>
- GitHub, check runs: <https://docs.github.com/en/rest/checks/runs>; SARIF upload:
  <https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/uploading-a-sarif-file-to-github>

---

## 16. Reviewer surfaces and a starting council

§15.5 left open which reviewers expose a structured surface. This section answers it for the nine
installed reviewers from two directions, what each emits on this org's pull requests and what its
vendor documents, then evaluates a wider candidate pool, including SonarQube and Gitar, and
proposes a council to start measuring from.

### 16.1 Method and limits

- **Observed surfaces:** 16 recent pull requests across four repos (hosting repo, standards repo,
  TalkTerm, broodly), read once through GraphQL on 2026-10-10: every check run with its app,
  conclusion and annotations; every commit status; every review with its state; every review thread;
  every pull-request comment.
- **Observed contribution:** 540 review threads on 24 pull requests, with the replies, classified by
  the author agent's disposition marker. Volume and refusals come from the org's own weekly reviewer
  scorecard of 2026-10-05 (174 eligible pull requests).
- **Documented surfaces:** each vendor's own documentation, read on 2026-10-10 through a fetcher
  that returns a model-extracted rendering. Names and thresholds should be re-checked against a real
  pull request before code depends on them.
- **Limits.** The samples favour busy pull requests. "Acted on" means the author agent claimed a fix;
  §14.4 is the evidence that this is not the same as the finding being right. Thread lists were
  capped at 60 per pull request. No sample measures a reviewer's false-negative rate.

### 16.2 The nine: what each emits here, and what its vendor documents

| Reviewer | Check run or status seen here | Annotations | Review state | Threads | Severity | Findings outside GitHub | Summary comment |
|---|---|---|---|---|---|---|---|
| **SonarQube Cloud** | Check `SonarCloud Code Analysis`; conclusion follows the quality gate | **Yes**, per line, with a level | None | None of its own | In its API | **Yes**: issue key per finding; Web API and MCP. Its findings also arrive as **code-scanning alerts** here | Yes, re-posted on every push |
| **cubic** | Check `cubic · AI code reviewer`; neutral seen on two runs; meaning undocumented | None | Comment only | Yes; resolves its own when fixed | `P1`–`P3` as text, plus a confidence value in a hidden comment | **Yes**: MCP `get_pr_issues` with issue ids, `update_pr_issue_status` | Generates the description |
| **CodeRabbit** | Commit status `CodeRabbit`; documented as "review ran", not "findings exist" | None | **Approve and request-changes seen** (24 and 31 in one week) | Yes; resolves its own when fixed | Category and severity as emoji text | Partial: CLI prints thread roots as JSON; REST is Enterprise | Yes, edited in place |
| **Graphite** | Check `Graphite / AI Reviews`; not documented by the vendor | None | Comment only | Yes | None | None | None seen |
| **Gemini Code Assist** | None | None | Comment only | Yes | A priority badge image | None documented | None seen |
| **Codex** | None | None | Comment only | Yes | A `P1`/`P2` badge image | None | Usage-limit notices |
| **CodeAnt** | None seen; documented only for its scanner gates | None seen | Comment only | Yes | Severity and category as text | Scanner findings only; its review comments are re-read from GitHub | Yes, a risk summary |
| **Copilot code review** | None | None | None seen | None seen | A text label, per its docs | None | None |
| **Qodo** | None | None | None seen | None seen | Text labels, per its docs | MCP `findings`, fields undocumented | Only "trial has ended" notices |

For comparison, **CodeQL** has every surface: a check whose conclusion reflects findings,
annotations, alerts with a stable number, a state and a rule severity, and a REST API.

What this means for the contract in ADR-0012, decision 12:

1. **SonarQube Cloud has the strongest contract of the nine, and the POC reads its weakest
   surface.** The registry classifies it as "top-level quality-gate comment only" and recognises a
   clean result by a pattern over the comment body (`scripts/lib/reviewer-sources.tsv`). The same
   information is in a check conclusion, in annotations, and in code-scanning alerts that carry a
   Sonar issue key. 34 of the hosting repo's last 100 code-scanning analyses came from SonarCloud.
   The vendor documents that sync as an Enterprise feature; it is running here on a public repo.
2. **No LLM reviewer publishes findings through SARIF, and every one carries severity as text in the
   comment body.** A contract that does not parse bodies cannot read severity from a thread. For
   thread-surface reviewers the gate is therefore the thread's own state: open or resolved. Severity
   is available only from a reviewer with a findings API, which among the nine means cubic.
3. **Only one LLM reviewer emits a structured verdict.** CodeRabbit submits approving and
   change-requesting reviews. The rest submit comment reviews, which say nothing a gate can read.
4. **A green check is not evidence of a review.** CodeRabbit documents a *passing* check named
   "Review rate limited" when it is throttled, and its main status tracks progress. Graphite's and
   cubic's checks exist and their meaning is not documented.
5. **No reviewer here is configured as code.** There is no `.coderabbit.yaml`, `cubic.yaml`,
   `.codeant/` or `.pr_agent.toml` in the repo. Each runs on settings held in its vendor's console.

### 16.3 What each contributed

Scorecard columns are from the week to 2026-10-05. Thread columns are from the 540-thread sample.
"Shared" is the share of a reviewer's flagged locations that another reviewer also flagged within
about six lines.

| Reviewer | Reviews | Refused | No response (of 174) | Threads sampled | Acted on | Shared | Severity mix | Model family | Free for public repos |
|---|---:|---:|---:|---:|---:|---:|---|---|---|
| cubic | 222 | 105 | 67 | 173 | **71%** | 32% | P1 32, P2 100, P3 41 | OpenAI and Anthropic | Yes, fair-use allowance of unstated size |
| Codex | 74 | **249** | 33 | 142 | 64% | 25% | P1 64, P2 78 | OpenAI | No; needs a paid ChatGPT plan |
| CodeRabbit | 401 | 155 | **3** | 67 | 59% | 33% | Major 13, Minor 22, Trivial 3 | Not disclosed | Yes; 1–10 reviews an hour per repo |
| Gemini Code Assist | 118 | 15 | 49 | 60 | 60% | **16%** | high 12, medium 26, low 22 | Google | Free while in preview, through Google Cloud |
| CodeAnt | **453** | 21 | 64 | 53 | 50% | **43%** | Major 48, Critical 4 | Not disclosed | No free tier found |
| Graphite | 22 | 8 | 101 | 15 | 66% | 26% | none | Anthropic and OpenAI | No, for an org's repos |
| SonarQube Cloud | 116 | 0 | 59 | 8 alert threads | 0 of 8 | — | by rule | None; rule-based | Yes |
| Copilot | **2** | 0 | 172 | 0 | — | — | — | Not disclosed | No |
| Qodo | 143 notices | 0 | 31 | 0 | — | — | — | Not disclosed | No, below 200 stars |

Readings, with the caution of §16.1:

- **Volume and value diverge.** CodeAnt submitted the most reviews, had the lowest share acted on,
  the highest overlap with other reviewers, and marked 48 of 53 findings "Major", which carries no
  information. cubic had the highest share acted on and a severity mix that discriminates.
- **Gemini's findings overlap least with the others'.** It is also the only installed reviewer whose
  model family is neither the primary author's nor shared with another reviewer. It raised no thread
  on a workflow file in the sample, which matches its vendor's statement that it does not review
  them, in an org that is mostly workflows.
- **The most structured Lens is the least acted on.** Eight code-scanning alert threads, none fixed,
  three declined, four unanswered. The sample is small. It suggests the author agent treats alert
  threads differently from bot review threads, which is worth a look whatever the council.
- **Two reviewers have not been reviewing.** Copilot answered 2 of 174 pull requests. Qodo's 143
  "reviews" are trial-ended notices.
- **Refusals are a design input.** Codex refused more often than it reviewed. CodeRabbit's 155
  refusals match its documented open-source limit of 1 to 10 reviews an hour per repo, against a
  fleet that pushes far more often than that.

### 16.4 SonarQube and Gitar

**Gitar is now a Sonar product.** Sonar's product page presents it as an agent that reviews pull
requests, root-causes CI failures and commits fixes, and says it "works alongside SonarQube" with
deeper integration to come. Secondary coverage dates the acquisition to May 2026.

| | SonarQube Cloud | Gitar |
|---|---|---|
| Kind | Deterministic rules and taint analysis over the whole project, judged on new code | An LLM reviewer plus a CI-failure agent that pushes fix commits |
| What it sees that a diff reader does not | Duplication, complexity, coverage on new lines, rules for GitHub Actions, Terraform, secrets and shell | CI logs, and whether CI goes green after its own fix |
| Structured surface | Check, annotations, issue keys through the Web API and MCP, code-scanning alerts | Review state (requests changes at a configurable threshold, approves when clean) and inline threads. No check run, SARIF or GitHub findings API is documented |
| Model | None for analysis | Not named; its bring-your-own-model page lists Anthropic models |
| Cost for public repos | Free. An open-source plan adds unlimited pull-request analysis and custom quality gates | Paid plans on the product page; its docs describe a free open-source plan granted per repo on application |
| Fit with ADR-0012 | A Lens with a full contract | **It is a writer.** Pushing commits to an agent's branch conflicts with one author per change, dismisses approvals under the ruleset, and needs write access to workflows |

Recommendations:

- **SonarQube Cloud: keep, and read it through its structured surfaces.** Consider the open-source
  plan for custom quality gates. Its AI Code Assurance feature is a label and a stricter gate, and
  its AI CodeFix repairs findings it already made; neither adds a Lens.
- **Gitar: not a council seat now.** Its review half is one more LLM on the diff with a thread-only
  contract. Its CI-failure half overlaps the fleet's own failure analyst and fix-CI intent and makes
  it a second author. Try it only if the in-house CI-failure path is measured as weak, with
  automatic fixes off. Revisit when Sonar ships the integration it has announced, because a Lens
  that combines Sonar's findings with CI outcomes through one contract would be a different thing.

### 16.5 The wider candidate pool

About forty candidates were examined. Three results organise the rest:

1. **Every free, pinnable, deterministic tool publishes through SARIF or annotations.** Uploaded to
   GitHub code scanning, each finding gets a stable alert identity, a dismissal state and a tool
   name, free on public repos. This is the one surface available today that satisfies decision 12
   for many Lenses at once.
2. **The Lenses that differ in kind from an LLM reading a diff are deterministic analysis and
   execution.** A second model brand is the weakest form of independence (§15.2).
3. **Published accuracy evidence cannot rank the LLM reviewers.** The benchmarks found are run by
   vendors in the comparison, cover application code in JavaScript, TypeScript, Python or Java, and
   disagree with each other. Nothing measures any reviewer on shell, YAML, Terraform or Actions,
   which is most of what this org writes.

| Candidate | What it sees | Surface | Free for public repos | Already here |
|---|---|---|---|---|
| actionlint, shellcheck, ruff | Workflow expressions, shell semantics, Python errors | Annotations; SARIF with a converter | Yes | actionlint and shellcheck run in CI and report by job result |
| zizmor | GitHub Actions security: injection, permissions, unpinned actions | SARIF, annotations | Yes | No |
| CodeQL | Dataflow security queries | Code-scanning alerts | Yes | Yes |
| Semgrep Community Edition | **The org's own rules**: each incident becomes a permanent check | SARIF | Yes | No |
| dependency-review-action | The dependency diff against advisories and licences | Job result and JSON | Yes | A dependency audit exists; not this action |
| Mutation testing on changed lines (Cosmic Ray, StrykerJS) | Whether the tests would fail if the change were wrong | Exit code and JSON | Yes | No |
| Claude Code Review (managed) | Multi-agent review with a verification step | The best-documented LLM contract: a check with annotations and a machine-readable severity line. Always neutral | No; about $15–25 a review | No |
| Greptile | Whole-repo graph; optional routing to the vendor that did not write the change | MCP with comment ids | One developer, 50 credits a month | No |
| Sourcery | An LLM on the diff | A named check that fails only on security findings | Yes, metered | No |
| Cursor Bugbot, Devin Review, Macroscope, Baz, Bito, Ellipsis | LLM reviewers | Mostly comments or a neutral check | Paid | No |
| DeepSource, Codacy, Qodana, Snyk Code | Hosted rule engines | Checks and annotations | Varies | No; same kind as SonarQube |

No longer available as described: Korbit (acquired), Qodo Cover (unmaintained), Trunk's pull-request
checks (being retired), Amazon Q on GitHub (winding down). Google's documentation says the consumer
Gemini GitHub app was shut down in July 2026; the reviewer active here would then be the Google
Cloud version. That was not confirmed against the org's installation.

### 16.6 A council to start measuring from

ADR-0012 leaves composition to a follow-on record decided from each Lens's measured contribution.
This is a starting set for that measurement, chosen for independence per unit of cost and noise.

| Seat | Lens | What it sees that the others do not | Contract surface | Status |
|---|---|---|---|---|
| 1 | Lint lane: actionlint, shellcheck, ruff | Mechanical correctness of exactly what this org ships | Code-scanning alerts, one category per tool | In CI; report as Findings instead of a job result |
| 2 | zizmor | Workflow security, in an org that is mostly workflows | Code-scanning alerts | Add |
| 3 | CodeQL, plus Semgrep CE for org rules | Dataflow, and invariants the author is not told | Code-scanning alerts | CodeQL here; add Semgrep rules as incidents occur |
| 4 | SonarQube Cloud | Whole-project gate on new code | Check, annotations, alerts, API | Here; read it by contract |
| 5 | Dependency diff | New dependencies against advisories | Job result and JSON | Partly here |
| 6 | Tests, plus mutation testing on changed lines | Whether the change's tests can fail. The nearest free thing to an acceptance signal the author cannot edit | Job result and JSON | Tests here; mutation testing to add |
| 7 | The in-house reviewer | Intent: the issue, the plan, the ADRs | The run contract | Here |
| 8 | **One or two outside LLM reviewers** | A reading by a different model, with the reviewer's own tools | Review state and threads; an API where one exists | Choose by measurement from the installed set |

For seat 8 the installed reviewers divide like this:

- **Keep and measure: CodeRabbit, cubic, Gemini Code Assist.** CodeRabbit is the only one with a
  structured verdict, misses almost no pull requests, and runs linters in a sandbox. cubic has the
  highest share acted on and the only findings API with identities and severity. Gemini overlaps
  least and is the only distinct model family. Each should get a config file in the repo.
- **Keep only if its quota is funded: Codex.** A distinct model family and a good share acted on,
  but it refuses more often than it reviews.
- **Remove from the required set: CodeAnt, Graphite, Copilot, Qodo.** CodeAnt adds the most volume
  and the least that is unique. Graphite reviewed 22 times in a week, publishes no contract and is
  not free for an org. Copilot and Qodo are not reviewing.

That takes the outside LLM reviewers from nine to three or four, moves six deterministic and
execution Lenses onto one contract, and leaves the choice among the three to four weeks of the
Ledger's per-Lens measure. The research predicts the end state is one, at most two.

### 16.7 What is not known

- Whether any reviewer's check conclusion can be trusted to mean "reviewed, nothing found".
  Graphite's and cubic's are undocumented; CodeRabbit's is documented not to.
- Each vendor's model family where undisclosed, and so how independent CodeRabbit and CodeAnt are of
  the author.
- How App-based reviewers meter or scope pull requests authored by a bot. Several budget per human
  developer, which decides whether they run at all once agents have their own identity.
- Whether SonarQube Cloud's code-scanning sync will keep working here below the Enterprise plan.
- The noise of mutation testing on agent-authored changes, and any mutation tool for shell.
- Any accuracy figure for any reviewer on this org's languages.

### 16.8 Sources

- Org data: the weekly scorecard on `petry-projects/.github-private#1220 — 🔎 Third-Party Reviewer
  Scorecard — Weekly Report` (comment of 2026-10-05); `scripts/lib/reviewer-sources.tsv`; GraphQL
  reads of 2026-10-10.
- CodeRabbit: <https://docs.coderabbit.ai/reference/configuration.md>,
  <https://docs.coderabbit.ai/management/rate-limits.md>,
  <https://docs.coderabbit.ai/pr-reviews/request-changes-workflow.md>
- SonarQube Cloud:
  <https://docs.sonarsource.com/sonarqube-cloud/managing-your-projects/issues/in-devops-platform/github.md>,
  <https://docs.sonarsource.com/sonarqube-mcp-server/tools>,
  <https://docs.sonarsource.com/sonarqube-cloud/administering-sonarcloud/managing-subscription/subscription-plans.md>
- Gitar: <https://www.sonarsource.com/products/gitar/>, <https://docs.gitar.ai/features/code-review>,
  <https://docs.gitar.ai/account-billing/plans>
- cubic: <https://docs.cubic.dev/ide/mcp-server.md>, <https://docs.cubic.dev/configure/cubic-yaml.md>
- Qodo: <https://docs.qodo.ai/code-review/comment-anatomy>, <https://www.qodo.ai/pricing/>
- CodeAnt: <https://docs.codeant.ai/pull_request/features/code_review.md>
- Graphite: <https://graphite.com/docs/ai-review-comments.md>, <https://graphite.com/docs/billing-plans.md>
- GitHub code scanning and SARIF:
  <https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/sarif-support-for-code-scanning>,
  <https://docs.github.com/en/rest/code-scanning/code-scanning>
- Claude Code Review: <https://code.claude.com/docs/en/code-review>
- zizmor: <https://docs.zizmor.sh/integrations/>; Semgrep: <https://docs.semgrep.dev/cli-reference>;
  dependency review: <https://github.com/actions/dependency-review-action>

---

## 17. Where a Lens runs: in the session, or on the pull request

Some Lenses can be called from inside an agent's session before anything is pushed. Others exist
only once a pull request does. This section sorts them and asks how far checks should move left.

### 17.1 Which Lenses can run in the session

| Class | Lenses | In-session interface | Time |
|---|---|---|---|
| **A. Deterministic command-line tools** | actionlint, shellcheck, ruff, yamllint, markdownlint, zizmor, gitleaks, Semgrep Community Edition, the repo's own validators and tests | A local command with an exit code and JSON or SARIF output. Semgrep can report only what is new against a base commit | Seconds to a few minutes |
| **B. LLM reviewers with a local CLI** | CodeRabbit (`cr review --agent`), cubic (`cubic review --json`, `--base`), Qodo, CodeAnt, Greptile; and the fleet's own second engines, Gemini and Codex, which need no vendor | A command that reviews uncommitted or branch changes and returns findings as JSON | Minutes; CodeRabbit says to allow at least 15 |
| **C. Pull-request level only** | SonarQube Cloud's pull-request analysis, CodeQL in practice, Gemini Code Assist, Copilot code review, Graphite, Gitar, the dependency-review action, mutation testing | None usable here. SonarQube has a command-line analysis for agents that needs an entitlement this org does not have, and its snippet-analysis tool is disabled on the hosted service. CodeQL and mutation testing have command lines and take too long for a session | Minutes to hours, or server-side |

One thing stands out in class B. **A reviewer's local CLI returns a better contract than its
pull-request surface.** CodeRabbit's agent mode emits one JSON object per finding with a severity,
a file, a line range and fix instructions; cubic's emits an `issues` array and exits non-zero when
it has findings. On a pull request the same two put severity in comment prose (§16.2). The
structured data exists; it is the pull-request channel that flattens it.

Limits on class B: cubic's CLI needs a seat on an active subscription and is "unlimited during
alpha"; CodeRabbit's is rate-limited with a local wait of up to 15 minutes, and whether its
open-source plan covers CLI reviews is not stated. cubic's own documentation calls its pull-request
review the "final pass" because it uses a different model and pipeline from the CLI.

### 17.2 Should checks move left?

**Yes for feedback. No for the verdict.**

The case for moving feedback left is the cost of a round. A finding fixed inside the session costs
one more model turn. The same finding fixed after a push costs, in the hosting repo, about 56 jobs
against 20 runner slots (§14.1), the dismissal of any approval, a fresh pass by every reviewer (four
of them produced 1,219 review events in one week), and another turn of the author. Merged pull
requests now take 7 to 10 commits at the median. Each of those commits is a round that happened on
the pull request and could have happened in the session.

The POC has half of this already. The harness runs a lint script before committing
(`scripts/dev-lead-lint.sh`) and the prompt tells the model to run it. Three things limit it:

- It covers shellcheck and agent-profile validation only, and describes itself as a hand-kept mirror
  of the checks in `lint.yml` and `ci.yml`.
- It skips a check when the tool is missing and still exits clean.
- When the harness's own run of it fails after the model has finished, the run is aborted and the
  work discarded, with a comment asking for a retry (`scripts/dev-lead-fix-issue.sh:643-668`). The
  detection moved left. The repair did not.

Four cautions set the boundary.

1. **A check the author runs is the author's evidence.** An agent can make a check pass by weakening
   it: a disable comment, an edited config, an edited test (`petry-projects/.github-private#2013 —
   dev-lead fix-reviews: posts "Fixed" replies for changes that were never pushed, and edits tests
   to match its own code`). So each Lens runs twice. In the session its output is feedback. In
   `verify`, where the author controls nothing, its output is the verdict, and only that run counts
   toward a Gate. Both use the same pinned tool versions and configuration, so they agree.
2. **Whatever must stay hidden stays right.** An acceptance signal the author cannot see (PRD FR-59)
   loses its value the moment it is fed back. Mutation-test survivors are fine to feed back. Holdout
   scenarios are not.
3. **An outside reviewer in the session is one pass, not a conversation.** The evidence in §15.2 is
   that review helps and discussion does not. A single pre-push pass by an outside reviewer may
   remove several pull-request rounds; no evidence found measures it. It also spends the reviewer's
   quota and the session's time budget, and the author agent's runs already time out. It should be
   tried on one repo against a control before it is adopted.
4. **A git hook is the wrong mechanism for an agent.** A pre-commit hook lives in the repo the author
   is editing and is skipped with one flag. The model CLI's bare mode, which its vendor says will
   become the default for headless runs, does not load hooks at all. For an agent the Harness should
   run the checks and return the findings for a bounded repair turn inside the same Run. For a
   person, and for an interactive session, the same bundle can be an ordinary pre-commit or pre-push
   hook.

### 17.3 The shape this gives

- **One pre-flight bundle, defined once, used in three places:** inside a Run as feedback, in
  `verify` as the verdict, and in CI for changes that do not come from the factory.
- **Tiered by time.** Seconds: lint, workflow and secret checks, after the model's edits. A few
  minutes: the tests for what changed, before the Result. Longer: the full suite, CodeQL, SonarQube
  and mutation testing, in `verify` and CI only.
- **An inner loop with a bound.** Findings from the bundle go back to the author for at most a
  declared number of repair turns. Work that still fails is kept, not discarded, and the Result
  says what failed.
- **Everything in class A moves left now.** That is seats 1, 2, 3 and 5 of the council in §16.6, plus
  secret scanning and the repo's tests.
- **Class B moves left as an experiment**, one reviewer on one repo, measured by rounds to
  convergence and by what the pull-request pass still finds afterwards.
- **Class C stays on the pull request**, and its findings arrive through the contract of §15.5.

The expected effect is on the constraints of §14.1 that the control plane alone does not move much:
fewer pushes per change means fewer runner jobs, fewer reviewer passes and fewer rounds for the
maintainer to watch. It does nothing for the first ceiling unless the verdict that follows can be
trusted, which is why the verdict stays where the author cannot reach it.

### 17.4 Sources

- CodeRabbit CLI agent mode: <https://docs.coderabbit.ai/cli/agent-mode.md>
- cubic CLI review: <https://docs.cubic.dev/ide/cli-review.md>
- SonarQube CLI and MCP tools:
  <https://docs.sonarsource.com/agent-centric-development-cycle/developer-tools/sonarqube-cli-in-agentic-workflows.md>,
  <https://docs.sonarsource.com/sonarqube-mcp-server/reference/tools.md>
- Semgrep CLI reference: <https://docs.semgrep.dev/cli-reference>
- Claude Code headless and bare mode: <https://code.claude.com/docs/en/headless>

---

## 18. How it is built: in place, or greenfield

§6.6 recommended a self-contained tree inside this repo, with a separate repo to be decided at the
end. The adversarial pass then ranked a starved migration as the likeliest failure (§14.2). This
section weighs the two ways to build and records the choice the maintainer made on 2026-10-10.

### 18.1 The two options

| | In-place strangler | Greenfield repo, then switch |
|---|---|---|
| Cost of each factory change | The POC's: about 56 CI jobs a push (§14.1), nine reviewers, and an approval gate that issues for none of 52 open pull requests | One hermetic required check and a council chosen from the first day |
| Risk to the running line | Shared workflows, scripts and release tags; a factory change can break the POC | None until cutover |
| "The POC takes defect fixes only" | Unenforceable in one tree | Physical: a different repo |
| Agent identity | Retrofitted under the live ruleset, with an untested rule in the way (§14.2, item 7) | The App authors agent changes from the first commit, so the maintainer can review them as an ordinary reviewer |
| Legacy doctrine | Agents working on the factory read a 1,062-line `AGENTS.md` written for the POC | A short rule file written for the factory |
| Contact with real traffic | Early and continuous | Late, unless it is designed in |
| Parity | Replaced piece by piece against the same tests | At risk: about 70,000 lines of tests encode the POC's incident history |
| Stopping | Half a strangler is hard to unwind | Archive the repo |
| Cutover | Per intent, reversible | All at once, as stated |

Neither is right as stated. In place, the replacement is built through the line that is failing:
holding the POC still already needs an estimated 30 to 52 fix pull requests a week against 29 to
36 delivered (§14.2). Greenfield with a single switch meets real traffic only at the end, which is
how a second system fails.

### 18.2 Two platform facts that decide the shape

- **A literal switch is not available.** GitHub's documentation states: "GitHub Actions does not
  support redirects for actions or reusable workflows." If this repo is renamed, or its name is
  reused, every consumer's reference fails until it is re-pinned, across twelve repos at once.
- **Forwarding is available.** Reusable workflows may be nested up to ten levels, and one workflow
  may call up to fifty. A reusable workflow in this repo can therefore become a thin caller of one
  in the new repo, and permissions can only narrow down the chain.

### 18.3 The hybrid: built greenfield, cut over as a strangler

1. **In this repo, now:** the configuration fixes of §8, step 0, and the GitHub App identity. Both
   are worth having whatever happens next.
2. **A new repo that starts as it means to go on:** a required hermetic check, the App as the
   author of agent changes, environment-scoped secrets, and the starting council of §16.6, all from
   the first commit.
3. **Real traffic in the first weeks.** The Kernel runs read-only from the new repo, as a poller
   over every repo. It needs read access only and changes nothing. Its disagreements with what the
   POC actually did are the measure of parity, and the only one a greenfield build has.
4. **Cutover at the seam that already exists.** Consumers pin this repo's channel tags. A reusable
   workflow here is replaced by a forwarder to the new repo; moving a channel tag onto that commit
   switches one intent for one ring; moving it back is the rollback. No consumer file changes. The
   release mechanism that §3.7 lists as solid is the cutover mechanism.
5. **Last, the re-pin.** Once every intent is served by the factory at `stable`, the standards sweep
   points consumers at the new repo directly, and this repo keeps only what GitHub's
   `.github-private` convention gives it.

### 18.4 What this costs, and what it does not fix

- **Three repos for a while.** The split between this repo and the standards repo, which §3.1
  criticises, gets wider before it gets narrower.
- **Parity is a real risk.** The comparison in step 3 measures decisions, not every effect, and
  some of what the POC's tests know will not be carried over.
- **It makes each change cheaper, not fewer.** The size of the build is the same either way, and
  nothing in the evidence prices it (PRD OQ-9).
- **The POC must still be kept alive.** Its defect inflow does not stop because the replacement is
  being built somewhere else.
- **It does not raise either ceiling of §14.1.**

### 18.5 Conditions

- A dated limit, a defect policy with a weekly cap for the POC, and a kill criterion, written
  before the new repo is created. If the criterion is met, the configuration fixes and the identity
  change stay and the new repo is archived.
- No intent is cut over until its disagreement list is within a bound declared beforehand and an
  eval set exists for it.
- This repo is not renamed while anything references it.

ADR-0012 carries these as decisions 1 and 10.

### 18.6 Sources

- GitHub, "Reusing workflow configurations":
  <https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations>
