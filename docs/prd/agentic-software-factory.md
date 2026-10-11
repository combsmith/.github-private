# PRD: Agentic Software Factory — Production MVP

**Status:** Draft — for maintainer review
**Date:** 2026-10-10
**Evidence pinned at:** commit `aef61164`

## 0. Document purpose

This document states what the `petry-projects` agentic software factory must do to be called
production-grade. It is written for the maintainer, who decides scope and targets, and for whoever
designs and builds against it, human or agent.

It is one of four documents produced by the October 2026 architecture review:

- **This PRD** — the requirements. It says *what* and *how well*, not *how*.
- [`docs/architecture/factory-mvp-architecture-review.md`](../architecture/factory-mvp-architecture-review.md)
  — the review of the current system and the analysis of architectural options against these
  requirements.
- [`docs/architecture/adr/0013-factory-mvp-reference-architecture.md`](../architecture/adr/0013-factory-mvp-reference-architecture.md)
  — the proposed decision.
- [`docs/research/market-agentic-software-factories-research-2026-10-10.md`](../research/market-agentic-software-factories-research-2026-10-10.md)
  — market research: what the market offers, who the customer is, and where this Factory sits.
  This PRD was revised against it; §7 of that document lists what changed.

The current system is treated as a proof of concept (the **POC**). It established which functions
are possible and where the hard problems are. This PRD defines the **MVP**: the first version
suitable for production use, meaning it can run unattended across the org's repos without a human
keeping the line moving.

Conventions:

- Terms in §4 (Glossary) are used exactly. A synonym anywhere in this document is a defect.
- Requirements are numbered globally (`FR-n`, `NFR-n`) and are written to be testable.
- Inferences that the maintainer has not confirmed are tagged `[ASSUMPTION]` and indexed in §12.
- Measurements are dated 2026-10-10 unless stated, against commit `aef61164`. Their sources and
  limits are in the review document, §2.
- Issues are cited as `repo#number — title`. `.github-private` is public; nothing here is secret.

## 1. Vision

A single maintainer states intent as an issue, or approves an idea, and receives a reviewed, tested,
merged change. Between those two points a set of agent roles plans, implements, reviews and ships,
across every repo in the org, including the repo that hosts the factory itself.

The POC proved each of those functions works in isolation. What it did not deliver is the *line*:
predictable flow, bounded cost, and outcomes that can be trusted without re-reading the diff. The
MVP keeps the functions and adds six properties:

1. **Every work item has one visible state and a known next actor.** Nobody has to read three
   scripts to learn why a pull request is not approved.
2. **Nothing is lost.** A dropped event, an evicted run or a timeout delays work; it never deletes it.
3. **No claim is trusted without evidence.** "Fixed", "approved" and "done" are facts read from the
   repository, not statements made by an agent.
4. **Cost is bounded before it is spent.** The factory knows what it can afford before it starts a
   run, and one merge cannot trigger work proportional to the number of open pull requests.
5. **A human decision binds everywhere.** A hold stops every role; a release resumes them; the
   maintainer's account is never mistaken for an agent's.
6. **A change to the factory reaches production by one gated path**, and the maintainer can say when
   it will be live and roll it back in one action.

**What is distinctive.** By late 2026 the market had made the workers a commodity: turning an
issue into a pull request, repairing CI on that pull request and giving it a first review are each
offered by eight or more products, several free on public repos ([market research](../research/market-agentic-software-factories-research-2026-10-10.md), §4.3).
What no product offers a solo operator is what surrounds the workers:

- a merge decision taken unattended on the operator's own policy, by an approver that is not the
  writer. Four vendors refuse in writing to merge to a default branch;
- a view across a portfolio of repos of why each Work item is waiting;
- one versioned definition of the automation, rolled out in stages across a dozen repos;
- work admitted against the capacity actually left, with a hard cap on spend;
- verification by Lenses from different vendors and of different kinds.

That is the Factory's scope. It builds the line. It adopts the workers.

**The working hypothesis is convergence.** A change is better when a council of independent Lenses
(models, tools and perspectives, each looking for something different) has examined it and their
Findings have been resolved, than when one agent has done its best alone. That holds across the
whole lifecycle: research, analysis, architecture, design, implementation, validation, release and
operation. The research supports this conditionally (review document, §15): independent evaluation
beats self-evaluation, and Lenses that differ in what they can see find different defects; but a
council that converses does worse than one that reports, and a council that co-writes does worse
than one author. The requirements in §6.11 are written to those conditions. The POC ran a large
council through free-text discussion and could not tell which Lens earned its place; the MVP runs
it through a contract and measures each one.

## 2. Why now

The POC grew by emergent design: each problem was met where it surfaced. That was the right way to
discover the problem space. The telemetry now shows the approach has stopped converging.

| Signal | Measured | Source |
|---|---|---|
| Work per outcome | At least 44,968 workflow runs in 7 days in the hosting repo for 30 merged pull requests: about 1,500 runs per merge. 24% of runs were cancelled and 31% skipped. | Actions runs API, 2026-10-03 → 10-09 |
| Flow | Merges per week flat at 14–36 since late August. Median open-to-merge rose from about 1 h to 12–22 h. Commits per merged pull request rose from 2–4 to 7–10. | Pull-request history, 400 PRs |
| Review gate | 0 of 52 open pull requests org-wide hold an approval. 34% of the last 150 merged pull requests had no standing approval at merge; 20 of 29 agent-authored merges in the latest week. | GraphQL search and timeline |
| Defect inflow | Bug-labelled issues rose from 2–9 a week (July, August) to 21–36 a week (since 2026-09-07). | Issue history, 600 issues |
| Lost work | pr-review runs 37% cancelled (1,000 runs in a day for 14 open pull requests); dev-lead 42% cancelled before doing any work. GitHub drops about 60% of scheduled ticks. | `petry-projects/.github-private#2193 — PR Review Agent — failures detected 2026-10-10`; `#1741 — [bug] 42% of dev-lead runs are cancelled before doing any work`; `#2160 — GitHub drops about 60% of scheduled ticks here` |
| Capacity | The GitHub API quota shared by the fleet and the maintainer ran out on 2026-10-10. The LLM budget breaker has never fired. | `petry-projects/.github-private#2197 — The fleet and every session share one GitHub API quota`; `#1565 — Auto-pause companion` |
| Compensation | 15 workflows exist to retry, sweep, repair or audit, against 28 that do primary work. In the dev-lead and pr-review loop the ratio is 12 to 7. | Review §3.2 |
| Assurance | No eval result blocks a merge, a release or a promotion. The ~4,900-case test suite is not a required check. | Review §3.5; live ruleset |

The clearest sign is that fixes relocate failures instead of removing them. Channel tags fixed
unversioned consumers and produced merged fixes that do not run. The maintainer-comment gate fixed
unanswered comments merging and produced at least fourteen deadlock issues in four weeks. Claim
verification fixed phantom "Fixed" replies and produced guards that retract real fixes. Each repair
was sound locally. The pattern says the problems are structural, and structural problems need a
decided structure. That is what the accompanying ADR proposes; this PRD states what the structure
must achieve.

The pattern is not peculiar to this org. Across about 22,000 developers, periods of high agent
adoption showed median review time five times longer, incidents per pull request up 243% and
deployments per week down 11.7%, while task throughput rose 34%. In a sample of merged agent pull
requests in significant public repos, 56% had no human reviewer ([market research](../research/market-agentic-software-factories-research-2026-10-10.md), §2.3).
Output is up across the industry and delivery is not. Verification is the bottleneck everywhere.

Some things did improve and must be kept: hard failures are 0.9% of runs, against 100% failure
streaks in April; the self-mention loop that produced the PR 860 runaway has not recurred; trunk
corruption stopped once its guard became a required check.

## 3. Users and journeys

### 3.1 Users

- **Maintainer.** The one human in the org: a technical solo builder running a portfolio of
  products. States intent, makes the decisions the factory may not make, and is the operator of
  last resort. Has no on-call rotation and no second reviewer. Can read code, owns the repos and
  the deployments, and pays for model access from a personal budget.
- **Repo owner.** Adopts the factory in a repo and expects it to work without learning its
  internals. Today this is the Maintainer in a different seat.
- **Factory developer.** Changes the factory itself. Usually an agent role working an issue;
  sometimes the Maintainer in an interactive session.
- **Outside contributor.** Anyone on the internet, since every repo is public. Opens issues and pull
  requests. Is not trusted.

Roles (the agents) are actors in the system, not users of it.

**Non-users.** Founders who cannot read code and ship from prompt-to-app builders are the largest
group of solo builders and cannot operate a Factory built on GitHub and CI; they are out of scope by
construction. So are teams looking for a hosted product with a vendor behind it ([market
research](../research/market-agentic-software-factories-research-2026-10-10.md), §3.1).

**What the wider segment says it needs** matches this Maintainer's jobs below: a stopping rule that
can be trusted when nobody is watching, a hard cap on spend, review that scales past one person, and
guardrails that do not need a platform team. One person supervises two to five agents, with a
ceiling near eight, and the limit they name is their own attention (§3.1 to §3.3 of the research).

### 3.2 Jobs to be done

- When I have an idea, I want to approve it once and see it delivered, so that my time goes to
  deciding what to build.
- When something is stuck, I want the item itself to tell me why and what would move it, so that I
  do not have to investigate.
- When I say stop, I want everything to stop, so that I can trust the factory unattended.
- When I change the factory, I want to know when the change is live and to undo it quickly, so that
  improving the factory is not riskier than leaving it alone.
- When I look at the bill, I want to see cost per delivered change, so that I can decide what is
  worth automating.

### 3.3 Key user journeys

- **UJ-1. The Maintainer turns an approved idea into merged changes with two decisions.**
  The Maintainer approves an idea and later arms the resulting epic. Stories are implemented,
  reviewed and merged in dependency order. The Maintainer is asked nothing further unless a story
  needs a decision. Climax: the epic closes with every story merged and each merge carrying an
  independent approval. Edge: a story exceeds its cost ceiling; it is held with the amount spent,
  the reason, and the choice required.
- **UJ-2. The Maintainer asks why a pull request has not merged.**
  The Maintainer opens the pull request. One status block states the current state, the gate holding
  it, the evidence, the next actor and the next evaluation time. Climax: the answer takes under a
  minute and requires no script, log or API call.
- **UJ-3. The Maintainer stops the factory.**
  The Maintainer sets one switch. No new agent run starts anywhere in the org; runs in flight finish
  or checkpoint. Every affected item shows that it is paused and by whom. Releasing the switch
  resumes work with no re-triggering. Edge: the factory pauses itself on budget; that pause is
  labelled as automatic and clears itself, while a human pause never does.
- **UJ-4. The Maintainer steers work in flight.**
  The Maintainer comments on an issue or requests changes on an agent's pull request, as they would
  with a human colleague. The next run includes that input, and the input receives a recorded
  disposition. Climax: the Maintainer can block an agent's pull request with an ordinary review.
- **UJ-5. A Factory developer ships a change to a role.**
  The change merges. The pull request states which release carries it and when each ring will run
  it. Promotion happens without the Maintainer when evals and ring evidence pass. Edge: a ring shows
  a regression; promotion stops, the previous release keeps serving, and one action restores it
  everywhere.
- **UJ-6. A Repo owner adopts the factory.**
  The Repo owner adds one file and one registry entry. Within an hour every role serves the repo. No
  later change to the factory requires an edit in that repo.
- **UJ-7. A Factory developer adds a role or gives a role a new trigger.**
  One pull request in one repo adds a manifest, a prompt and eval cases. It reaches consumers by the
  normal release path. No workflow file changes.
- **UJ-8. Capacity runs short.**
  Budget for the week is 80% spent with three days left. The factory moves low-priority work to a
  cheaper tier, defers the rest with a visible reason and re-evaluation time, keeps merge-unblocking
  work running, and tells the Maintainer once.
- **UJ-9. The Maintainer reads the weekly scorecard.**
  One page: changes delivered, lead time, share delivered without intervention, cost per change,
  share of cost that was rework, items held and why, eval scores, release lag. Every number links to
  the runs behind it.

## 4. Glossary

- **Factory** — the whole system: Roles, Controller, Harness, Kernel, Ledger, release tooling.
- **Work item** — an idea, epic, issue or pull request the Factory acts on. Exactly one Lifecycle
  applies to each Work item.
- **Lifecycle** — the declared set of States and Transitions for a type of Work item.
- **State** — the single current position of a Work item in its Lifecycle.
- **State record** — the machine-readable account of a Work item's State, the reason for it, and the
  facts the Factory owns about the item (attempts, spend, dispositions). It is computed at each
  evaluation and published in the control room; it is a view, not a store (ADR-0013, decision 2).
- **Role** — a named agent responsibility (for example dev-lead, pr-review, qa-lead) defined by a
  Role manifest.
- **Role manifest** — the data that defines a Role: the Intents it handles, its inputs, tools,
  Engine tier, permitted Effects, budget class and evals.
- **Intent** — one kind of task a Role performs on a Work item (for example implement-issue,
  fix-review-findings, review-pull-request).
- **Run** — one execution of one Intent by one Role on one Work item.
- **Task** — the typed input a Run receives.
- **Result** — the typed output a Run returns.
- **Effect** — a change to the outside world requested by a Result: a pushed commit, a comment, a
  review, a label, a resolved thread, a dispatched Run.
- **Engine** — an LLM runtime and model that executes a Run.
- **Harness** — the component that prepares a Task, runs the Engine in a sandbox, validates the
  Result and applies its Effects.
- **Controller** — the component that decides, for a Work item, which Run to admit next.
- **Admission** — the Controller's decision to start, defer or refuse a Run.
- **Kernel** — the Factory's deterministic decision logic, independent of GitHub and of any Engine.
- **Gate** — a condition a Work item must satisfy to make a Transition.
- **Hold** — a human or automatic stop on one Work item.
- **Pause** — a stop on all Runs in a scope (org, repo or Role).
- **Override** — a logged human action that bypasses a Gate.
- **Disposition** — the recorded outcome for one review finding or human comment: fixed, declined,
  deferred or not applicable, with evidence.
- **Ledger** — the durable, append-only record of Admissions, Runs and Effects: the Factory's run
  records and artifacts in GitHub Actions, indexed in the control room.
- **Release** — one immutable version of everything that determines Factory behaviour.
- **Channel** — a named pointer to a Release that consumers follow.
- **Ring** — a set of Consumer repos that receive a Release at the same stage.
- **Consumer repo** — a repo the Factory serves.
- **Hosting repo** — the repo that contains the Factory. It is also a Consumer repo. The POC is
  hosted in `petry-projects/.github-private`, and every measurement in this document that says
  "hosting repo" was taken there. The MVP is built in a new repo, which becomes the Hosting repo;
  `.github-private` then becomes a Consumer repo.
- **Advisory reviewer** — a third-party review bot whose output the Factory consumes but does not
  control. An Advisory reviewer is a Lens.
- **Lens** — any source of judgement on a Work item: a Role, an Advisory reviewer, a tool such as a
  static analyser or a test suite, or a human.
- **Finding** — one structured record of something a Lens observed: its source, a stable identity,
  a location, a severity, the content version it applies to and its status.
- **Council** — the set of Lenses required for a class of Work item at a stage of its Lifecycle.
- **Convergence** — the condition in which every Lens in the Council has reported on the current
  content version and no blocking Finding is open.

## 5. Constraints

These are facts of the environment. A design that ignores one is not viable.

- **C-1. One Maintainer, no on-call.** The Factory must be safe unattended and must fail to a Hold,
  not to an action.
- **C-2. GitHub Free plan, all repos public.** There are no org-level rulesets. Rulesets and the
  merge queue work only because repos are public. Everything the Factory writes is world-readable.
  Actions minutes are free.
- **C-3. LLM capacity is a subscription window, not a metered API.** The binding limit is a 5-hour
  and a weekly window. The only usage signal is an unsupported endpoint that refuses the credential
  CI holds. This basis is not secure: the provider announced in May 2026 that programmatic use
  would move off subscription limits to API rates, and paused the change on the day it was due
  (C-11).
- **C-4. GitHub-native operation.** The June 2026 release initiative fixed "no new repos, no
  external infrastructure". The Maintainer lifted the first half on 2026-10-10: the Factory is
  built in a new repo (§11, OQ-5). `[ASSUMPTION]` The second half, no always-on infrastructure,
  still holds (OQ-1).
- **C-5. The platform loses events.** Scheduled ticks are dropped about 60% of the time and always
  run the default branch. A concurrency group holds one running Run and, by default, one pending
  Run; a third arrival evicts the pending one. GitHub now documents `concurrency.queue: max`, which
  holds up to 100 pending Runs; no workflow here uses it. Events authored with the default workflow
  token start no downstream workflow, except `workflow_dispatch` and `repository_dispatch`, and
  those only within the same repo.
- **C-6. Identity rules.** A code owner must be a user or team, so a GitHub App cannot satisfy a
  code-owner review. GitHub rejects an approval or a change request by a pull request's own author.
  An approval by the last pusher is discarded under the last-push rule. `[ASSUMPTION]` GitHub's
  terms permit one machine-user account per person, and the org already has one.
- **C-7. Self-hosting.** The Factory reviews and merges changes to itself.
- **C-8. Advisory reviewers are unreliable.** Most run on free or trial tiers and refuse work when
  out of quota: 553 refusals in one week across six bots.
- **C-9. Twenty runner slots.** The free plan allows 20 concurrent hosted-runner jobs.
  `[ASSUMPTION]` The limit is shared by every repo in the org. One push to a pull request in the
  Hosting repo starts about 56 jobs.
- **C-11. Capacity terms can change on short notice.** In 2026 one platform moved its coding
  product from flat to token-metered billing, one model provider announced and then paused the same
  for automated use of its subscriptions, and another withdrew its command-line tool from
  subscribers with about thirty days' notice. Limits on flat plans are unpublished and changeable.
  The Factory's cost per change at API rates is several times its cost on a subscription
  ([market research](../research/market-agentic-software-factories-research-2026-10-10.md), §2.5).
- **C-10. One Maintainer's attention is the first limit on output.** Each change that needs a human
  audit, a cleared Hold or an Override costs Maintainer time, estimated at 10–12 hours a week at
  the POC's 30–36 merges. `[ASSUMPTION]` The estimate is the Maintainer's rough figure. No requirement below can be met by spending more of it.

## 6. Functional requirements

### 6.1 Work-item lifecycle

**Description.** Today a Work item's state is a tuple recomputed on every run from labels, about
eighty kinds of HTML-comment marker, review objects, check results and the head commit. No file
declares the states or the transitions. This feature makes the Lifecycle a declared, single thing.
Realizes UJ-1, UJ-2.

- **FR-1. Declared Lifecycle.** The Factory defines one Lifecycle per Work-item type as versioned
  data: its States, its Transitions, the Gate on each Transition and the actor allowed to make it.
  - Every Transition the Factory performs in production is a declared one. An undeclared Transition
    is detected automatically and reported as a defect.
  - The Lifecycle definition is the source for documentation and tests; it is not restated by hand
    elsewhere.
- **FR-2. One visible State.** Every Work item under Factory control shows, on the item, its current
  State, the reason, the Gate it is waiting on with evidence, the next actor, and the next
  evaluation time.
  - "Why is this pull request not approved?" is answerable from the item alone.
  - A disagreement between the visible State and the State record is detected and repaired at the
    next evaluation, and counted.
- **FR-3. Liveness.** No Work item remains in a State that is neither terminal nor held without a
  scheduled next evaluation.
  - An item with no evaluation for longer than its State's limit is escalated automatically.
- **FR-4. Terminal truth.** "Done" is derived from repository state: a merged change with a
  non-empty diff that closes the item.
  - A pull request with an empty net diff cannot close an issue.
  - A completion statement appears only after the fact it reports is true.
- **FR-5. No lost work.** A request for work survives a dropped event, an evicted or cancelled Run,
  a timeout and a failed Run.
  - After any of these the item is re-evaluated without human action within the liveness limit.
  - A cancelled Run is never read as "nothing to do".
- **FR-6. Resumable Runs.** A Run interrupted before completion preserves its progress, and the next
  Run for that Intent resumes from it or records why it could not.
- **FR-7. Idempotent by content.** Repeating a request for unchanged content causes no new agent
  work. Content identity, not the commit hash, decides "unchanged".
  - Updating a pull request's base without changing its own diff triggers no re-review and
    invalidates no verdict.

### 6.2 Roles and the run contract

**Description.** The POC has five different ways of invoking a model, four ways of building a
prompt and seven ways of returning output. In the two busiest Roles the model process holds a write
credential, and roughly four thousand lines of harness exist to police what it then claims. This
feature gives every Role one contract. Realizes UJ-7.

- **FR-8. Role as data.** A Role is defined entirely by its Role manifest, prompts and eval cases.
  - Adding an advisory Role, or giving a Role a new Intent or trigger, changes no workflow file and
    no Kernel code.
  - The manifest is the only place a Role's triggers, identity, permissions and budget class are
    written.
- **FR-9. One run contract.** Every Run receives a Task and returns a Result. Both are typed and
  schema-versioned.
  - A Result that fails validation fails the Run. No Effect from it is applied.
  - A Task contains everything the Run needs; the model does not discover its inputs by exploring
    the environment.
- **FR-10. The Harness applies every Effect.** The model process holds no credential that can write
  to GitHub or push to a repository.
  - This holds for every Role, including those that write code.
  - No rule about what a Role may write is enforced by prompt text alone.
- **FR-11. Evidence before publication.** A statement by a Role about its own work is published only
  after the Harness has verified it against repository state.
  - "Fixed in commit X" is published only if X was produced by that Run and is on the remote branch.
  - An unverifiable statement is not published and the Run is recorded as incomplete.
- **FR-12. Untrusted content is data.** Text written by an Outside contributor, an Advisory reviewer
  or any other Role cannot change a Run's Task, permissions or Result schema.
  - An injection test suite covers every Role and runs before a Release is promoted.
- **FR-13. Engine independence.** A Role manifest names a capability tier, not a vendor or model.
  - Changing the Engine behind a tier is a configuration change gated by that tier's evals.
  - A Run records the Engine and model that actually served it, including after a fallback.
- **FR-14. Shared-branch safety.** A Role that pushes to a branch other actors push to never
  discards a commit it did not make, never alters an existing test without a cited justification,
  and never pushes a change that turns a passing test red.

### 6.3 Orchestration

**Description.** Runs are started today by thirty-odd workflows reacting to events, each with its own
conditions. One comment starts three workflows; one review starts four. Concurrency groups act as
the work queue and hold one item. Fifteen further workflows find and restart what fell through.
Realizes UJ-1, UJ-3, UJ-8.

- **FR-15. One Admission point.** Every Run is admitted by the Controller. Admission evaluates Pause,
  Hold, budget, duplication and concurrency in one place.
  - There is no way to start a Run that bypasses Admission.
  - Every Admission decision that differs from the previous one for that Work item, including a
    refusal, is recorded in the Ledger with its reason. Repeats are counted, not recorded.
- **FR-16. One writer per Work item.** At most one Run that can produce Effects is active per Work
  item. Requests that arrive during a Run are coalesced and evaluated when it ends.
- **FR-17. Bounded automation per Work item.** The number of automated actions on a Work item since
  the last human decision has a ceiling.
  - No agent action resets the count. The count does not depend on which account an agent uses.
  - Reaching the ceiling places a Hold and notifies the Maintainer once.
- **FR-18. No self-trigger.** No Role's output can cause that Role, or a cycle of Roles, to run
  again without passing Admission. The Lifecycle definition is checked for this before merge.
- **FR-19. Tolerance of event loss.** Correctness does not depend on the delivery of any single
  event or timer tick. Losing one delays a Work item by at most the liveness limit.
- **FR-20. Bounded fan-out.** An event on one Work item causes agent work on other Work items only
  where their content is affected.
  - One merge to a protected branch causes no agent Runs on pull requests it does not conflict with.
- **FR-21. Priority under constraint.** When capacity is short, the Controller admits Runs in a
  declared priority order: work that unblocks a merge first, then security, then the rest.

### 6.4 Human control

**Description.** The Maintainer's controls differ by Role. One label has four meanings. There are
three mention grammars. The switch documented as pausing the fleet pauses one Role. Removing a hold
resumes nothing until another event happens. And because the Maintainer's account is also the
account two agent families act as, the Maintainer cannot review their pull requests and the
Factory's loop bound cannot tell them apart. Realizes UJ-2, UJ-3, UJ-4.

- **FR-22. One control vocabulary.** Start, steer, hold, release, hands-off, re-evaluate and
  override work the same way for every Role and every Work-item type, and are documented in one
  place.
- **FR-23. A Hold binds everywhere.** A Hold on a Work item stops every Role's Effects on it from
  the next Admission onward.
  - Removing a Hold resumes work without any further action.
  - Each Hold records who placed it and whether it needs a decision or will clear itself.
- **FR-24. Pause.** One switch stops Admission of all Runs in a scope: org, repo or Role.
  - Paused items show that they are paused, by whom and since when.
  - A Pause set by automation is distinguishable from one set by a human, and only the former is
    cleared by automation.
- **FR-25. Steering reaches the Role.** Human input on a Work item, whether a body edit, a comment
  or a review, is part of the next Run's Task.
  - Every human comment on a Work item under Factory control receives a Disposition.
- **FR-26. A human is never mistaken for an agent.** Every agent action is attributable to an agent
  identity by actor alone. The Role that acted is recorded in the Ledger and shown in the output;
  it need not be a separate actor.
  - The Maintainer can approve, or request changes on, any agent-authored pull request.
  - No Gate distinguishes human from agent by parsing comment text.
- **FR-27. Escalation states the decision.** When the Factory needs the Maintainer it says, on the
  item, what decision is required and shows the evidence, and it notifies through a pushed channel.
- **FR-28. Override is a first-class action.** Forcing a review, merging without an approval and
  promoting past a failed Gate are explicit actions that record who, when and why.
  - None requires a hand-written API call.
  - Every merge without a standing independent approval has an Override record.

### 6.5 Review and merge integrity

**Description.** The largest failure class in the issue history is the approval that never issues
or issues and is withdrawn: 63 issues, 45 of them in the last four weeks. Five independent gates can
each withhold or dismiss the single approval the ruleset needs. Realizes UJ-1, UJ-2.

- **FR-29. Independent review.** No change merges on the say-so of its author's identity. The
  reviewer identity differs from the author identity for every agent-authored change.
- **FR-30. Gate integrity.** A Gate cannot be cleared by the Role whose work it gates.
- **FR-31. Durable approval.** An approval is bound to the content it reviewed.
  - It survives events that do not change that content.
  - It is withdrawn only by new content or a new unresolved finding, and a withdrawal removes the
    pull request from the merge queue.
  - A Role never dismisses its own approval and then declines to re-review.
- **FR-32. Advisory reviewers are integrated through a contract, not a discussion.** Each Advisory
  reviewer's registry entry names the structured surface its Findings are read from: a check run
  and its annotations, code-scanning alerts, or review threads.
  - A comment body is presentation for people. Nothing parses one to make a decision, waits for
    one, or is blocked by one.
  - An Advisory reviewer with no structured surface gates nothing and is not awaited.
  - An Advisory reviewer has a deadline. Its absence, a quota notice or a trial expiry never blocks
    a Work item beyond a declared wait.
  - The set of Advisory reviewers a repo waits for is derived from those active on that repo.
- **FR-33. One Disposition per Finding per content version.** Every Finding from any Lens is
  dispositioned exactly once for a given content version, as a record the Gates read.
  - A Finding's identity is a structured key from its surface (a thread, an alert, an annotation),
    never text matched in a body. An edited summary comment is therefore not a new Finding.
  - A human comment or review thread is a Finding from a human Lens and always gates.
- **FR-34. Serialized merges.** Merges to a protected branch are serialized and tested against the
  actual merge result.

### 6.6 Resource governance

**Description.** Capacity is discovered by failing. The proactive headroom check reads zero on every
run because it probes with a key that is never supplied. The budget breaker was built, closed as
done, and cannot fire. The fleet alone uses more GitHub API requests per hour than the shared limit
allows. Realizes UJ-8, UJ-9.

- **FR-35. Capacity is checked at Admission.** Before starting a Run the Controller checks remaining
  LLM budget, GitHub API quota and concurrency.
  - A Run that cannot be afforded is deferred with a visible reason and a re-evaluation time.
  - The capacity signal is exact where the platform provides one and a stated estimate where it
    does not (C-3). A missing or failed reading defers the Run and raises an alert; it is never read
    as "plenty".
- **FR-36. Graceful degradation.** Declared thresholds move the Factory through stages: full
  service, cheaper tier for low-priority work, priority work only, Pause. Each change of stage
  notifies the Maintainer once.
- **FR-37. Quota isolation.** The Factory's GitHub API usage and the Maintainer's interactive usage
  do not draw on the same limit. The Factory's LLM usage is accounted separately from interactive
  use; where both draw on one subscription window, the estimate in FR-35 says so.
- **FR-38. Complete cost attribution.** Every Run records tokens, cost, duration and outcome,
  including Runs that failed, timed out or were cancelled, attributed to Work item, Role, Intent,
  repo and Release, and marked as first-pass or rework.
- **FR-39. Cost ceiling per Work item.** Each class of Work item has a declared ceiling.
  Reaching it places a Hold that states the amount spent. The ceiling that gates is a number of
  Runs, because decisions read GitHub only and what a Run cost is known only to the control room
  (ADR-0013, decision 2).

### 6.7 Observability

**Description.** State is not observable today: diagnosing one stuck pull request meant correlating
timeline events by hand. The cost report omits the Hosting repo and nearly all pr-review calls. The
daily fleet failure report stopped three weeks ago and nothing noticed. 45% of all issues in the
Hosting repo are machine-filed reports. Realizes UJ-2, UJ-9.

- **FR-40. Ledger.** Every Admission, Run and Effect is appended to a durable Ledger retained for at
  least 90 days and queryable by Work item, Role, repo, Release and time. The Maintainer set 90
  days on 2026-10-10, in place of 180: it is how long GitHub keeps run records in a public repo.
- **FR-41. Work-item timeline.** The full history of a Work item can be reconstructed from the
  Ledger alone.
- **FR-42. Scorecard.** A weekly and on-demand scorecard reports the success metrics in §9 from the
  Ledger.
- **FR-43. Pushed alerts, watched watchers.** A breach of a liveness, capacity or integrity limit
  notifies the Maintainer. Every monitor has a dead-man check: a monitor that stops reporting is
  itself reported.
- **FR-44. Bounded report noise.** A recurring report updates one tracking item. It does not open a
  new issue per run.

### 6.8 Release and distribution

**Description.** Two opposite regimes coexist: changes to dev-lead and pr-review are inert until a
tag moves, while persona prompts and manifests are live for every repo the moment they merge. The
version name is per agent but points at a whole-repo commit. Promotion reads run conclusions, which
the operating rules call unreliable. "Which agents exist" is written in eight places; a persona's
trigger surface in up to eight. Realizes UJ-5, UJ-6, UJ-7.

- **FR-45. One Release unit.** A Release is one immutable version of every artifact that determines
  behaviour: workflows, Kernel, Harness, prompts, Role manifests and configuration.
  - Every Run records the Release it ran.
  - No behaviour-determining artifact is fetched from a moving reference at run time.
- **FR-46. One path to production.** Every artifact type reaches Consumer repos through the same
  staged path. The only artifacts live at merge are entry points that contain no logic, because the
  platform always runs dispatched and scheduled workflows from the default branch.
- **FR-47. Promotion on evidence.** A Release advances a Ring only when eval scores for the
  production Intents pass and the previous Ring shows verified outcomes: artifacts confirmed, not
  run conclusions.
  - A Ring with no Runs of the candidate does not count as evidence.
- **FR-48. Known time-to-live.** After a merge the Factory states which Release carries the change
  and when each Ring will run it. A merged change not in production after the declared bound raises
  an alert.
- **FR-49. Rollback.** One action restores the previous Release for all Consumer repos within 15
  minutes.
- **FR-50. Self-hosting safety.** The Release that reviews and merges changes to the Factory is a
  promoted Release, never the candidate under review.
- **FR-51. Onboarding.** A Consumer repo adopts the Factory with one file and one registry entry and
  is served by every Role within an hour. A later Release, new Role or new trigger requires no edit
  in the Consumer repo. Installing Advisory reviewers in vendor consoles is outside this bound.
- **FR-52. Version-skew safety.** Messages between components running different Releases carry a
  schema version. A sender does not emit a message its receiver cannot read.
- **FR-53. One fact, one place.** The set of Roles, the set of Consumer repos, each repo's Ring and
  each Role's triggers are each written once. Everything else is derived.

### 6.9 Assurance of the Factory itself

**Description.** The test suite is large (about 4,900 cases, 1.46 lines of test per line of script)
and is not a required check. Evals for dev-lead and pr-review score their mention-advisory prompts,
not the flows that write code and approve pull requests. Many tests run against a `gh` stub that
accepts any flags. The suite cannot run on the Maintainer's machine. Realizes UJ-5.

- **FR-54. Verification blocks merge.** The Factory's test, contract and validation suites are
  required checks on the Hosting repo.
- **FR-55. Evals cover production Intents.** Every Intent that writes code or decides a Gate has a
  held-out, scored eval set that exercises the production prompt and Harness path.
  - "Held-out" names its mechanism. In a public repo it is either stored where the Role under test
    cannot read it, or declared a convention guarded by code ownership.
- **FR-56. Real-interface tests.** Every interaction with GitHub and with an Engine is tested
  against recorded real responses or a sandbox, so that a call the real interface rejects fails a
  test.
- **FR-57. Lifecycle verification.** The declared Lifecycle is checked mechanically for
  termination, absence of undeclared cycles, and Hold and Pause semantics.
- **FR-58. Local reproducibility.** A Factory developer can run the full suite, and replay a
  recorded Work item through the Kernel, on macOS and on Linux with documented prerequisites.
- **FR-59. Acceptance the author cannot edit.** Every code-writing Intent is checked against at
  least one acceptance signal that the authoring Role can neither read in advance nor change. The
  Consumer repo's own tests do not qualify, because the author can edit them.

### 6.10 Security

**Description.** One owner credential serves code-writing, cross-repo dispatch, labelling, persona
comments and fallback authentication. Reusable workflows inherit every org secret. One gate fetches
and executes a script from another repo's default branch at run time. Realizes UJ-3, UJ-6.

- **FR-60. Least privilege per Role.** Each Role's Effects are applied with a credential scoped to
  that Role's permitted Effects and short-lived. No Role uses the Maintainer's credential.
  - Where the platform requires a user account (C-6), that one long-lived credential is confined to
    a job that runs no model and no code from the Work item.
- **FR-61. No unpinned execution.** The Factory executes no code and reads no policy from a mutable
  reference outside its own Release.
- **FR-62. Public by default.** Every Effect is written as world-readable. Secret values never
  appear in logs, comments or the Ledger.
- **FR-63. Outside contributions.** A pull request from an Outside contributor never receives a Run
  that holds secrets or can produce write Effects without a Maintainer decision.

### 6.11 Convergence: the council of Lenses

**Description.** The POC already runs a council: a review cascade with four specialist prompts and
a second-opinion model from another vendor, nine advisory personas, and nine Advisory reviewers.
They interact by posting comments at each other and at the author. The result was 343 review
dismissals on 150 merged pull requests, commits per merged pull request rising from 2–4 to 7–10,
and a scorecard that cannot say which Lens caught anything. This feature keeps the council and
replaces the discussion with a contract. Realizes UJ-1, UJ-2, UJ-9.

- **FR-64. One Finding contract for every Lens.** Roles, Advisory reviewers, tools and humans all
  contribute Findings in one schema. What a person reads on the Work item is rendered from those
  records by the Harness.
- **FR-65. Lenses report; they do not converse.** No Lens's output triggers another Lens or is
  addressed to one. Each reports to the Controller.
  - A Lens that judges a change gives its Findings without seeing another Lens's verdict on that
    content version.
- **FR-66. One author per change.** Lenses judge a change. They do not co-write it. A Finding is
  acted on by the Role that authored the change.
- **FR-67. Convergence is decided.** The Kernel decides Convergence from Findings and their
  Dispositions. It is not inferred from a conversation going quiet.
  - A Work item that has not converged within its declared bound of rounds or cost is placed on
    Hold with the open Findings listed.
- **FR-68. A Council is declared per class of Work item and stage.** Which Lenses are required for
  an idea, a plan, a design, a code change and a Release is data, and is not the same set for each.
  - Work that divides into independent parts (research, analysis, review) may use Lenses in
    parallel. Work that is one interdependent piece (implementation) has one author.
- **FR-69. A Lens earns its place.** The Ledger records, per Lens, the Findings it raised, the share
  that were acted on, the share no other Lens raised, and its cost.
  - A Lens joins a required Council only with a measured marginal contribution, and leaves it when
    that contribution falls below a declared level.
  - Independence is measured, not assumed: two Lenses that raise the same Findings count as one.
- **FR-70. Lenses differ in what they can see, not only in which model they are.** A Council for a
  code change includes at least one Lens grounded in execution (tests, static analysis, a running
  system) and at least one acceptance signal the author cannot edit (FR-59).

- **FR-71. Feedback moves left; the verdict does not.** Every Lens that can run before a push runs
  inside the Run, and its Findings go back to the author for a bounded number of repair turns
  before anything is pushed.
  - The same Lens runs again where the author controls nothing, and only that run counts toward a
    Gate.
  - Both runs use the same pinned tools and configuration, defined once.
  - A Run whose work still fails after its repair turns keeps the work and reports what failed. It
    is not discarded.
  - An acceptance signal the author must not see (FR-59) is never fed back.

### 6.12 Sourcing and capacity basis

**Description.** Two requirements from the market research. The workers the POC built by hand are
now offered by ten or more vendors, and the subscription the POC runs on is the usage its provider
tried to move to metered rates in 2026. Realizes UJ-7, UJ-8.

- **FR-72. Workers and reviewers are adopted, not rebuilt.** Where a maintained product or toolkit
  performs an Intent or acts as a Lens, the Factory uses it through the run contract or the Finding
  contract. The Factory builds a worker of its own only where none meets the contract.
  - Replacing one worker or reviewer with another changes configuration, not the Kernel.
  - No part of the Factory depends on a product that has no declared replacement.
- **FR-73. The Factory can run on metered capacity under a hard cap.** Every Role can be served from
  a metered API credential as well as a subscription, and the choice is configuration.
  - A hard monthly cap in currency stops Admission when it is reached. It is a brake outside the
    Kernel.
  - The scorecard reports what each period would have cost at API rates, whichever basis paid for
    it.

## 7. Non-functional requirements

Targets marked `[ASSUMPTION]` are proposals for the Maintainer to calibrate. Baselines are from §2
and the review document.

| ID | Quality | Target | POC baseline |
|---|---|---|---|
| NFR-1 | Flow efficiency | At most 10 Runs per merged pull request; at most 2% of admitted Runs lost or started later than the liveness limit. Wake-ups that admit nothing are reported separately and are not capped `[ASSUMPTION]` | About 1,500 workflow runs per merge including CI; 24% cancelled |
| NFR-2 | Lead time | Issue to merge p50 ≤ 8 h and p90 ≤ 48 h for items needing no human decision `[ASSUMPTION]` | p50 24.5 h, p90 296.5 h |
| NFR-3 | Autonomy | At least 85% of agent-authored pull requests merge with a standing independent approval and no human action outside declared decision points `[ASSUMPTION]` | At most 40% |
| NFR-4 | Gate integrity | 100% of merges carry either a standing independent approval or an Override record | 66% approved; no Override record exists |
| NFR-5 | Liveness | No Work item is without a next evaluation for more than 24 h | 22 open pull requests older than 7 days; three flagged as runaway daily |
| NFR-6 | Cost visibility | 100% of Runs attributed; rework share reported | Hosting repo and pr-review absent from the cost report |
| NFR-7 | Cost efficiency | Rework at most 20% of spend; trivial sync pull requests at most 5% of spend `[ASSUMPTION]` | Rework unmeasured; sync pull requests were 30% of one week |
| NFR-8 | Release lag | Merge to stable ≤ 48 h at p90 with no manual promotion, with candidates batched because every eval case spends the capacity in C-3; rollback ≤ 15 min | Manual override promotions on four dates in ten days |
| NFR-9 | Operator load | At most 30 minutes a week of Maintainer time on actions that are not decisions `[ASSUMPTION]` | Not measurable today; routine per the operating notes |
| NFR-10 | Defect inflow | Factory-defect issues at most 5 a week and falling `[ASSUMPTION]` | 21–36 a week |
| NFR-11 | Changeability | New advisory Role: one pull request and one App registration. New trigger for an existing Role: one pull request, live within NFR-8 | New trigger took 32 days and at least six pull requests across two repos |
| NFR-12 | Maintainability | Kernel decision logic is free of I/O; a size and complexity budget per module is enforced in CI | 17 functions over 150 lines; one script with 1,025 top-level lines |
| NFR-13 | Portability | The suite runs on macOS and Linux | Fails on stock macOS |
| NFR-14 | Quota headroom | Factory GitHub API usage stays under 60% of its own limit at p95 `[ASSUMPTION]` | 115–140% of a shared limit |

NFR-3 and NFR-10 are a pair. On the POC's first-pass correctness they cannot both be met: at 85%
autonomy the share of merges that carry a defect must roughly halve to keep defects at five a week
(review document, §14.4). Autonomy is raised only as SM-C1 allows.

NFR-1 counts Runs. The runner pool of C-9 also needs a budget: wake handling takes at most 10% of
the org's job-minutes `[ASSUMPTION]`.

## 8. Non-goals

- The Factory is not a product for other organisations. It serves `petry-projects`.
- The Factory does not replace GitHub as the system of record for code, reviews and merges.
- The Factory does not remove the Maintainer from the decisions in §6.4: approving ideas, arming
  epics, resolving escalations, overriding Gates.
- The MVP does not improve review depth. Better bug-finding (symbol context, specialist routing,
  few-shot from merged pull requests) waits until the line is stable, because its benefit cannot be
  measured on a line that loses a third of its work. This non-goal sets the MVP's ceiling: once
  approvals issue reliably, how often they are right is what limits autonomy (FR-59, and the note
  under §7).
- The MVP adds no new Roles and no new Advisory reviewers. It gives the existing council a contract
  and a measure (§6.11). Enlarging the council comes after the measure exists.
- The MVP does not provide 24-hour operations or a paging rota.
- The MVP does not target private repos or a paid GitHub plan.

## 9. Success metrics

### 9.1 Primary

- **SM-1. Autonomy rate.** Share of agent-authored pull requests merged with a standing independent
  approval and no human action outside declared decision points. Target per NFR-3. Validates FR-5,
  FR-15, FR-29 to FR-33.
- **SM-2. Lead time.** Issue-to-merge p50 and p90. Target per NFR-2. Validates FR-3, FR-5, FR-7,
  FR-19.
- **SM-3. Cost per merged change**, with rework share. Targets per NFR-6 and NFR-7. Validates FR-7,
  FR-20, FR-35 to FR-39.

### 9.2 Secondary

- **SM-4. Runs per merged pull request and lost-Run share.** NFR-1. Validates FR-15, FR-16, FR-20.
- **SM-5. Unapproved merges without an Override record.** Target zero. Validates FR-28, FR-29.
- **SM-6. Items past the liveness limit.** Target zero. Validates FR-3.
- **SM-7. Release lag and manual promotions per week.** NFR-8. Validates FR-46 to FR-49.
- **SM-8. Factory-defect issues per week.** NFR-10.
- **SM-9. Maintainer non-decision time per week.** NFR-9. Validates FR-22 to FR-28.
- **SM-10. Eval coverage.** Share of code-writing and Gate-deciding Intents with a passing held-out
  eval set. Target 100%. Validates FR-55.
- **SM-11. Rounds to Convergence.** Commits and review rounds per merged pull request. POC baseline:
  7–10 commits at the median. Validates FR-65 to FR-67.
- **SM-12. Lens contribution.** Per Lens: Findings acted on, Findings unique to it, and cost.
  Validates FR-69.
- **SM-13. Factory against one agent.** Cost, lead time and escaped defects per merged change for
  work run through the Factory, against the same class of work done by one agent with the same
  pre-flight checks and one human approval. The market's strongest objection is that orchestration
  does not beat a single well-run agent; this is the measure that answers it. Validates the
  premise, not a requirement.

### 9.3 Counter-metrics (do not optimise)

- **SM-C1. Escaped defects.** Reverts and post-merge fixes per hundred merges. Counterbalances SM-1
  and SM-2: autonomy and speed must not be bought by weakening review.
- **SM-C2. Holds cleared by automation.** Counterbalances SM-1 and SM-6: liveness must not be bought
  by auto-clearing human Holds.
- **SM-C3. Review skipped or carried forward incorrectly.** Share of merges whose final content was
  never reviewed. Counterbalances SM-3 and SM-4: cost must not be bought by not reviewing.
- **SM-C4. Override count.** Counterbalances SM-5: an Override record must not become the routine
  path.

## 10. MVP scope

### 10.1 In scope

- The Roles that form the delivery line: dev-lead (implement issue, fix CI, fix review findings,
  resolve conflicts), pr-review, and the initiative driver.
- The advisory personas as they exist, moved onto the common run contract and release path.
- The Hosting repo and at least two Consumer repos, served from one Release.
- Every requirement in §6 for those Roles and repos.
- The identity requirement (FR-26, FR-60) for every agent, including the planning Roles that
  §10.2 otherwise leaves as they are. Exit criterion 5 depends on it.
- Migration of in-flight Work items without loss.
- `[ASSUMPTION]` Two Consumer repos are enough to prove multi-repo operation for the MVP.

### 10.2 Out of scope for the MVP

- Multi-repo initiatives. Deferred: they multiply every coordination problem above.
- MCP-powered review, review-depth work, self-improving skills, automated model onboarding.
  Deferred: each needs the measurement the MVP provides.
- Feature ideation, idea triage and the initiative planner. They keep running as they are and move
  to the common contract after the delivery line.
- Fleet-wide compliance automation and the spam guard. Owned by the standards repo.
- Report and health workflows that become redundant once the Ledger exists are retired, not ported.
- `[ASSUMPTION]` The planning Roles can stay on their current implementation during the MVP without
  blocking it.

### 10.3 Exit criteria: POC to production

The MVP is in production when, for four consecutive weeks on the Hosting repo and two Consumer
repos:

1. SM-1, SM-2, SM-5 and SM-6 meet their targets.
2. SM-3 is reported for 100% of Runs.
3. No Release was promoted manually and at least one rollback was exercised.
4. Every compensating workflow listed in the review document, §3.2, is retired or has a recorded
   reason to remain.
5. The Maintainer's account authored no agent commit, comment or review.

### 10.4 Build versus adopt

From the competitive analysis ([market research](../research/market-agentic-software-factories-research-2026-10-10.md), §4.3).

| Capability | Position | Why |
|---|---|---|
| The Lifecycle, Admission, the State record and Ledger | **Build** | No product offers a cross-repo account of why each Work item is waiting |
| The merge decision and its policy | **Build** | Every vendor hands it back; four refuse in writing |
| The Finding contract and Convergence | **Build** | No product draws reviewers from different vendors and kinds |
| Staged release of the Factory across a portfolio | **Build** | Not documented by anyone |
| Capacity admission and the hard cap | **Build** | Vendors meter spend; none admits work against what is left |
| Turning an issue into a pull request | **Adopt** | Offered by more than ten products |
| CI repair and review follow-up on an agent's own pull request | **Adopt** | Offered by more than eight |
| First-pass review | **Adopt** | Free on public repos from several vendors |
| Deterministic analysis | **Adopt** | Open tools reporting through code scanning |
| Requested effects with a separate applier | **Adopt if it fits** | GitHub's Agentic Workflows ships this pattern under an open licence (OQ-14) |

## 11. Open questions

1. **OQ-1. Is "no always-on infrastructure" still a hard constraint?** It decides whether an
   off-GitHub control plane is a candidate for the MVP or a later option. One exception was allowed
   by the Maintainer on 2026-10-10: an optional external timer that only starts the poller, keeps
   no state and decides nothing.
2. **OQ-2. Will the Maintainer move the code-writing Role off the owner account?** FR-26 and FR-17
   need it. It reverses the choice made in `petry-projects/.github-private#1316 — dev-lead regressed
   to committing as donpetry-bot (review-only machine user) instead of don-petry` and recorded in
   the interaction model, §12.2. Decided by the Maintainer on 2026-10-10: yes. No agent runs as the
   owner account. The Maintainer may still author changes to the Factory's repo under that account,
   as a person. Each Role has its own GitHub App, so that its permissions are a ceiling the platform
   enforces. The review document, §6.4, had recommended one App.
3. **OQ-3. What supplies the LLM capacity signal, and does the Factory get its own LLM credential?**
   FR-35 has no feed today. An estimate from the Factory's own usage is sound only if interactive
   sessions do not spend from the same window unobserved. The analyst's comment on the idea
   (`petry-projects/.github-private#2226 — Factory MVP: rebuild the agentic factory around a
   declared control plane, one run contract and a council of Lenses`) sets out four credential
   options and suggests moving the eval lane to metered access first. Decided by the Maintainer on
   2026-10-10: the Factory starts on the existing subscription credential, stored as an environment
   secret in the Factory's repo and restricted to its default branch. The capacity signal therefore
   stays an estimate, shared with interactive use and with the POC while both run.
4. **OQ-4. Should code-owner review stay required with one human in the org?** It is the reason the
   reviewer must be a machine user and not an App.
5. **OQ-5. Should the Factory have its own repo?** Decided by the Maintainer on 2026-10-10: yes. It
   is built greenfield in a new repo and cut over through the channel tags `.github-private`
   already has, one Intent and one Ring at a time (review document, §18). The repo is
   `petry-projects/software-factory`. Open: what `.github-private` keeps once every caller is
   re-pinned.
6. **OQ-6. Which Advisory reviewers are worth waiting for?** Four of seven gated reviewers never
   participate. The rule was decided on 2026-10-10 (OQ-13): a reviewer is awaited only if it has a
   structured surface the contract can read.
7. **OQ-7. Are the `[ASSUMPTION]` targets in §7 the right ones?**
8. **OQ-8. Where does the Ledger live and who may read it?** Everything in a public repo is public.
   Decided by the Maintainer on 2026-10-10: the Ledger is the Factory's own run records and
   artifacts, and `petry-projects/software-factory-control-room` is a public, rebuildable view of
   them with a dashboard. Every panel is public. Open: where held-out eval sets live.
9. **OQ-9. What is the budget for the migration itself**, in weeks and in LLM spend, given that the
   POC must keep delivering while it is replaced? The three conditions ADR-0013 required were set
   by the Maintainer on 2026-10-10 (ADR-0013, decision 10). POC defects are fixed as needed, with no
   weekly cap. There is no dated limit and no automatic stopping rule: if the Factory is not adopted
   and used, the Maintainer decides to stop, informed by the control room. Still open: the LLM
   spend.
10. **OQ-10. Should third-party reviewer comments keep gating approvals?** Decided by the Maintainer
    on 2026-10-10: reviewers are integrated through a contract, and structured Findings gate where
    comment bodies do not (FR-32, FR-33). The nine current reviewers' surfaces are established in the
    review document, §16.2: one has a full contract, one a findings API, one a structured verdict,
    and the rest review threads only or nothing.
11. **OQ-11. Is it worth trying the three cheapest changes first and re-measuring?** Stopping the
    rebase fan-out, moving agents to their own identity, and narrowing what gates an approval cost
    weeks. Four weeks of data after them would show how much of the rest is needed.
12. **OQ-12. What is the Council for each stage?** §6.11 requires it to be declared and measured. It
    does not say which Lenses belong in it. The research gives a starting shape (review document,
    §15.4), and §16.6 proposes a starting council for code changes: six deterministic and
    execution-grounded Lenses on one contract, the in-house reviewer, and three or four of the
    nine outside reviewers kept for measurement.
13. **OQ-13. Which outside reviewers are removed now?** §16.6 recommended removing four from the
    required set (CodeAnt, Graphite, Copilot, Qodo) and funding or dropping a fifth (Codex). Each
    is a subscription or an installation the Maintainer controls. Decided by the Maintainer on
    2026-10-10: compatibility with the structured contract decides, not volume. Copilot and Qodo
    come off now, because neither is reviewing and neither shows a structured surface here. Codex
    stays installed, unfunded and not required, so its refusals gate nothing. CodeAnt and Graphite
    stay as review-thread Lenses and are measured with the rest. Graphite is a paid subscription.
    Copilot may be re-enabled, and would then enter as a review-thread Lens under the same
    measure.
14. **OQ-14. Is GitHub's Agentic Workflows adopted as the worker half of the run contract?** It is
    the nearest substitute for what ADR-0013 proposes to build there. Its documentation does not
    list a subscription credential for the Claude engine, which conflicts with C-3 until C-11
    forces the question anyway.
15. **OQ-15. What is the metered fallback budget?** FR-73 needs a monthly figure in currency at
    which the Factory stops, and a decision on whether to hold a funded API credential in reserve.
16. **OQ-16. Is release and operation the next scope after the MVP?** It is the widest gap in the
    market at a solo builder's price and is outside §10.1.
17. **OQ-17. Should the first non-goal be restated?** The research supports keeping the Factory out
    of the business of selling orchestration: attention there is large and willingness to pay is
    low. "Not a commercial product; open for others to read and reuse" would say that more exactly
    than "not a product for other organisations".

## 12. Assumptions index

This PRD was revised once after the architecture analysis tested it against the constraints. The
twelve changes and their reasons are recorded in the review document, §10.

- §5 C-4 — "no always-on infrastructure" still holds.
- §5 C-6 — GitHub's terms allow one machine-user account per person.
- §7 NFR-1, NFR-2, NFR-3, NFR-7, NFR-9, NFR-10, NFR-14 — numeric targets are proposals.
- §5 C-9 — the 20-job limit is org-wide. §5 C-10 — the Maintainer-time estimate.
- §7 — wake handling within 10% of job-minutes.
- §10.1 — two Consumer repos are enough to prove multi-repo operation for the MVP.
- §10.2 — the planning Roles can stay on their current implementation during the MVP without
  blocking it.

## Appendix A. Failure classes to requirements

Classes and counts are from the review document, §2.3.

| Failure class | Issues (hosting repo / standards repo) | Requirements |
|---|---|---|
| A. Approval never issues, or issues and is withdrawn | 63 / 6 | FR-2, FR-29 to FR-33 |
| D. Work dropped between event and agent | 47 / 17 | FR-3, FR-5, FR-15, FR-16, FR-19 |
| B. Status reported but not real | 37 / 14 | FR-4, FR-10, FR-11, FR-47 |
| E. Quota and budget exhaustion | 33 / 6 | FR-35 to FR-39 |
| C. Merged fix is not what runs | 25 / 72 | FR-45 to FR-53 |
| F. Identity, credential, permission | 21 / 3 | FR-26, FR-29, FR-60 |
| G. Re-review churn, rebase treadmill, runaway | 17 / 4 | FR-7, FR-17, FR-20, FR-34 |
| I. Human steering does not reach the agent | 14 / 12 | FR-22 to FR-25 |
| J. Tests and evals not measuring the real thing | 14 / 16 | FR-54 to FR-58 |
| K. Automation that corrupts or destroys | 13 / 8 | FR-10, FR-14, FR-61 |
| H. Timeout loses the work | 9 / 3 | FR-6 |
