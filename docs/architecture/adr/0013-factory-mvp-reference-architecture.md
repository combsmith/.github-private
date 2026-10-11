# 0013. Factory MVP reference architecture: a declared control plane, one run contract, one release

## Status

proposed

## Context

The agentic factory in this repo grew by emergent design and is now treated as a proof of concept.
`docs/prd/agentic-software-factory.md` states what a production MVP must do. The review in
`docs/architecture/factory-mvp-architecture-review.md` measured the POC against it at commit
`aef61164` (2026-10-10) and analysed the options. This record states the decision; the options are
in the review, §§4–11, and are not repeated here.

The review found seven structural causes behind eleven recurring failure classes. Each is a
decision the POC never made once, so it was made many times, locally:

1. **Work-item state is implicit.** No file declares states or transitions. State is recomputed by
   each script from labels, about eighty HTML-comment marker shapes, review objects and checks. The
   only marker registry is one regex (`scripts/lib/maintainer-comment-gate.sh:74`).
2. **Work is carried by events and concurrency slots.** A request exists only as a queued run, and
   the platform drops both runs and scheduled ticks (`.github/workflows/dev-lead-reusable.yml:76-85`;
   `.github/workflows/pr-review-sweep.yml:15-18`). Fifteen workflows exist to find and restart what
   fell through. Nothing admits runs in one place.
3. **The model holds the write credential and reports on itself.** In the two busiest roles the
   harness polices claims afterwards (`.github/workflows/dev-lead-reusable.yml:173`;
   `scripts/lib/addressed-claim-verify.sh`).
4. **Agents act as the Maintainer.** One account is the human, dev-lead and eight personas
   (ADR-0008). The loop ceiling keys on login and so cannot count them
   (`scripts/lib/pr-automation-budget.sh:54-59`), the Maintainer cannot review their pull requests,
   and the fleet and every session draw on one API quota.
5. **There is no single unit of release.** Changes to dev-lead and pr-review are inert until a tag
   moves (`AGENTS.md:25-33`); persona prompts and manifests are live at merge
   (`.github/workflows/persona-runner.yml:23-24,39`). One fact is written in up to eight places
   across two repos.
6. **An approval is bound to a commit hash**, can be withheld or dismissed by several independent
   gates, and one merge forces work on every open pull request
   (`scripts/review-one-pr.sh:838-842`; `.github/workflows/auto-rebase.yml:25-30`).
7. **Verification does not bind.** The `main` ruleset requires five checks (read live,
   2026-10-10); the test suite, the validators and the evals are not among them. Decision logic sits in shell and inline workflow
   steps that cannot run on the maintainer's machine (`AGENTS.md:174-181`).

Three things the earlier records decided bear directly on this one.

**ADR-0007** weighed and rejected an org-level GitHub App as *ingress* and a webhook-native runtime,
"at the current fleet size", because both need a hosted endpoint, a second secret store and their
own deduplication. That reasoning stands. This record uses a GitHub App as an *identity* whose
tokens are minted inside Actions. It hosts nothing and does not reopen ADR-0007.

**ADR-0008 and interaction model §12.2** put the personas and dev-lead on the owner account. The
review engages with their reasoning point by point (review §6.4). Their stated objection to a
distinct identity was a new machine user with a new long-lived token. A GitHub App has neither, and
GitHub's terms permit only one free machine account, which the org already uses for the reviewer.

**ADR-0010** recorded that ADR-0000 has no status for an ADR that extends another. That gap is felt
here and is not fixed here.

One platform fact changed during the review. A concurrency group's pending depth of one is now a
default: GitHub documents `concurrency.queue: max`, up to 100 pending runs. It is a useful
mitigation for the POC. It does not change this decision, because a deeper queue still loses a
request when a tick is dropped, a dispatch fails or a run is killed.

**This decision was attacked before it was proposed.** The review compares it with seven other
systems (§13) and records an independent adversarial pass (§14). That pass found the first draft
sound in four decisions and wrong in three ways: it committed to two mechanisms before measuring
them, it removed brakes the POC has, and it had no stopping rule. The boundaries below include the
changes it required. It also found two ceilings this decision does not raise, which are stated in
Consequences.

**Where it is built was decided on 2026-10-10.** The first draft kept the factory as a tree inside
this repo and left a separate repo to be decided at the end. The review weighed building in place
against building greenfield and switching over (§18). In place, every factory change pays the
POC's price: about 56 CI jobs a push, nine reviewers, and an approval gate that issues for no open
pull request. A literal switch-over is not available either: GitHub Actions does not redirect
reusable-workflow references, so renaming or replacing this repo would break every caller at once.
The maintainer chose the hybrid: build in a new repository, cut over through the channel tags this
repo already has. That lifts the "no new repos" half of the constraint set in June 2026. The "no
always-on infrastructure" half stands.

In this record "the factory repo" is the new repository, `petry-projects/software-factory` (named
by the maintainer on 2026-10-10), and "this repo" is `petry-projects/.github-private`, which hosts
the POC.

**A note on the number.** This record was drafted and discussed as ADR-0012. While it was in review,
ADR-0012 was assigned on `main` to the maintainer comment gate's exemption set, so this record
takes the next number. Earlier links and comments that say "ADR-0012" about the factory MVP mean
this record.

**ADR-0012 (the comment gate's exemption set, proposed)** narrows which pull-request comments the
POC's gate counts, by registered marker or one exact body form. It governs the POC. Decisions 7 and
12 below replace that gate's premise, that a comment body is what gates, and the merge-integrity
follow-on will supersede ADR-0012 when the factory's gate takes over.

**Scope and precedence.** This record fixes the structure every new factory component follows. It
supersedes no ADR by itself. An accepted ADR keeps governing the POC code path it describes until a
follow-on ADR, named below, supersedes it in the same change that makes the new behaviour true in
the running system. Flipping statuses on acceptance would make the log claim what the system does
not yet do, which is the defect ADR-0008 was written to repair, in reverse.

## Decision

We will rebuild the factory's core as **a declared control plane, one run contract and one release**,
on GitHub Actions, with no always-on component. We will build it in a repository of its own, beside
the POC, and cut over one
repo and one intent family at a time. Terms are those of the PRD glossary.

### 1. One self-contained repository, with decision logic that does no I/O

We will build the factory in a new repository of its own: Lifecycle, Role manifests, schemas,
configuration, Kernel, adapters, Harness, Controller, release tooling and their tests. The Kernel is
Python 3 using the standard library only. All I/O is in adapters. Shell is step glue.

The boundaries a check can assert:

- **No module under `kernel/` performs I/O.** It imports nothing that opens a file, a process, a
  socket or the environment, and it takes the clock as an argument.
- **The factory repo reads nothing from this repo at run time.** Code carried over from the POC is
  copied in with its tests and owned there. Nothing is sourced, fetched or checked out across the
  two.
- **No decision logic in workflow YAML.** A `run:` block in a factory workflow is at most ten lines
  and calls a module entry point.
- **The factory repo starts as it means to go on.** From its first commit it has the required check
  of decision 8, the agent identity of decision 5 as the author of agent changes, and
  environment-scoped secrets.

### 2. A declared Lifecycle, with State derived and never stored

We will define one Lifecycle per work-item type as versioned data under `lifecycle/`, and compute
each work item's State at every evaluation from what GitHub holds. We keep no second authoritative
store. The work item shows a projection of its State. Labels are the human's input vocabulary.
HTML-comment markers are not state.

The first draft kept a State record per work item and an append-only Ledger in a git store, as a
provisional choice. The maintainer replaced it on 2026-10-10: most of what that store held is
already on the work item, and a stored copy can only go stale. In this record "the Ledger" now
means the factory's run records and artifacts in GitHub Actions, as indexed in the control room.

- **State is computed, never stored.** One Kernel function derives it from facts and the factory's
  run records, both held by GitHub.
- **Every transition the factory performs for a Release is declared in that Release's Lifecycle.**
  An undeclared one fails a check and is reported.
- **No module under `kernel/` takes a comment body as input.** Text written by third
  parties becomes typed records in adapters and Roles that are enumerated in one list. The entries
  in that list that read legacy markers may only shrink.
- **What only the factory knows is written once, where GitHub keeps it.** That a Run happened and
  how it ended is its Actions run record, named for its work item. What the Run cost and what a
  model judged are in the Run's artifact, which is immutable and has a digest. Nothing is handed
  from job to job through a log.
- **Reviews, checks, labels, merges and thread resolution are read as facts at each evaluation**
  and are never trusted from a copy.
- **Facts say whether they are complete.** A list cut off at a page limit, or a truncated diff, is
  unreadable. Unreadable facts never converge and never admit.
- **Every pass records the facts it read and the decisions it made,** as an artifact, so that any
  decision can be replayed.
- **The control room is a materialized view.** `petry-projects/software-factory-control-room` holds
  an index of the run records and artifacts and every item's computed State. Only the Controller
  writes it. It is public, reaches back 90 days, and can be deleted and rebuilt from GitHub. A view
  rebuilt from GitHub equals the view updated pass by pass, and a check asserts it.
- **No decision reads the control room.** The same facts and run records give the same decision
  whatever the view holds, so the view can be wrong or missing without the factory misbehaving.
- **The projection on a work item is rewritten only when the decision changes,** and at most once
  per item per stated interval. It contains no value that changes when the decision does not.

### 3. Level-triggered Admission in one place

We will admit every Run through one Controller that evaluates current facts and the factory's own
records. The Controller is a poller: one pass evaluates every open work item in every repo. An
event carries no work. It may only ask for a pass now, and any number of such nudges during a pass
collapse into one more pass. The Controller runs in the factory repo. A Run is its own workflow
run, one lane per work item, held from `run` to applied Effects. The first draft woke the
Controller once per event; the maintainer replaced that on 2026-10-10 (decision 11).

- **A nudge carries nothing.** The Kernel's admission function takes no event payload.
- **A Run is started only from a decision a pass recorded.** Only the poller can be started from
  outside the factory, and it takes no inputs, so a credential that can start workflows cannot
  direct a Run.
- **A fault in the environment is not an attempt.** A failed Run is classed as a fault of the item,
  of capacity or of the environment, or as superseded. Only the first counts against the item. Several environment
  faults in a row pause Admission, raise one alert, and clear when a probe Run succeeds.
- **An external timer may also start a pass.** It holds one credential that can start the poller,
  keeps no state and decides nothing. Correctness never depends on it. It is optional, and it is
  the one permitted exception to "no always-on component".
- **One workflow, the one that carries a Run, is the only one that invokes an Engine or references
  an LLM credential.** The poller invokes none.
- **At most one Run that can produce Effects is active per work item,** by the lane. Org-wide
  limits are decided inside the one pass, which is the only decider, so there is no race to lose.
- **Passes do not overlap, and at most one waits.** A pass starts its successor when something is
  due before the next scheduled tick.
- **Hold, budget, duplication and concurrency are evaluated in the admission function and nowhere
  else.** A human Pause is a variable. An automatic pause is derived at each pass from recent
  faults, so automation cannot clear the human one.
- **A missing or failed capacity reading admits nothing.** It yields a deferral with a reason.

These brakes sit outside the Kernel, so that a defect in the Kernel cannot disable them:

- **A human Pause holds when factory code is broken.** The entry shim's caller jobs are conditioned
  on a pause variable that the platform evaluates before any factory code runs.
- **A ceiling on admitted Runs, per work item and per org in a rolling window, is enforced outside
  `kernel/`,** from a count the Kernel does not write, with its own tests.
- **The count of automated actions since the last human decision is computed from GitHub's record
  of actors,** not from the Ledger.
- **On a metered credential, a monthly cap in currency stops Admission.** It is read from the
  provider's own usage figure. On the subscription there is no currency cap, and the Run ceiling
  is the brake.

And a nudge is bounded in what it can cost:

- **A consumer repo may carry the nudge file, and needs none to be served.** Where it is installed,
  its one job drops events authored by a factory identity in its job-level `if:`.

### 4. One run contract; a job is a credential boundary

We will give every Role one contract: a schema-versioned Task in, a schema-versioned Result out,
with every side effect expressed as a requested Effect. Three jobs carry it: `run`, `verify`,
`apply`.

- **No job holds both an LLM credential and a credential that can write to GitHub.**
- **No job that holds a write credential executes code from the work item's branch.** Only `verify`
  does, and `verify` holds no secret.
- **A Result that fails schema validation applies no Effect.**
- **A statement that names a commit is written by `apply` from a commit it pushed and read back.**
  The model's output schema has no field for a commit hash.
- **A Role's permitted Effects are listed in its manifest and enforced by `apply`.** This is how
  ADR-0005's write opt-in is enforced.
- **`run` and `verify` declare `permissions: {}` and neither restores nor saves a cache.** `permissions: {}`
  restricts only `GITHUB_TOKEN`; the Actions cache credential is separate. So these jobs use no cache
  action, run on ephemeral runners, and run in a context that cannot write the default-branch cache
  scope later jobs restore. A lint asserts all three.
- **The checks that judge a model's diff run in a job that executes none of it,** and `apply`
  re-derives the digest of what it pushes instead of trusting an earlier job.
- **`apply` refuses, to a Hold, any change under `.github/`, to `CODEOWNERS`, or to the files that
  define a consumer's setup and test commands,** unless the Role's manifest permits that Effect and
  a human transition is recorded.
- **Every Effect type declares a recovery key that is not text in a body.** For an Effect with no
  natural idempotency key, the Result artifact is the intent record: it exists before `apply`
  starts. If it is missing or its digest does not match, nothing is applied.
- **A Run that ends with no Result is still a run record.** It counts as an attempt unless its fault is classed
  as capacity or environment, and the Lifecycle declares what follows it.
- **`apply` re-reads the work item before any Effect,** and writes nothing if the item is held,
  paused, closed or no longer the content the Run was admitted for.
- **`verify` never replaces the consumer's own required checks.** Its result counts in place of the
  author's, and the consumer's checks on what was pushed remain the verdict.
- **Feedback moves left; the verdict does not.** `run` executes the pre-flight checks and returns
  their Findings to the author for a bounded number of repair turns. `verify` executes the same
  checks, at the same pinned versions and configuration, and only its result counts toward a Gate.
  The checks are defined once and are not a git hook, which the author could edit or skip.

### 5. Agents have their own identity

We will have every agent write through a factory GitHub App of its own, one App per Role, with a
token minted per Run and narrowed to the Effects that Run requests, and have approving reviews
submitted by the existing machine user. Code-owner review stays required. The owner account is the
human's alone.

The maintainer decided on 2026-10-10 that no agent runs as the owner account, and that each Role
has its own App, so that a Role's permissions are a ceiling the platform enforces and not only a
rule in the factory's own token-minting code. The review had recommended one App (§6.4, option c);
this is its option d. The Maintainer may still author changes to the factory repo under the owner
account, as a person. "The App" in the boundaries below means the App of the Role that acts.

- **The factory's Apps share the name prefix `combsmith-sf-`,** and the consumer file drops
  factory-authored events by that prefix. Adding a Role changes no consumer file.
- **Registering an App is a manual step.** A new Role is one pull request and one registration.
- **Reading is shared; writing is not.** Every `run` job reads GitHub through one reader App that
  can write nothing. A Role is given its own App when it first needs to write, so a Role in shadow
  has none.

- **No factory workflow references the owner account's token.**
- **Every Effect in the Ledger has a factory App or the reviewer as its actor.**
- **For every agent-authored pull request, author and approver differ, and the App is not a code
  owner.**
- **The count of automated actions since the last human decision does not consult a login list.**
- **No factory secret is readable by a workflow that runs on a work-item branch.** The App key, the
  reviewer's token and the LLM credential are environment secrets restricted to the default branch.
  A test pull request proves this before any agent uses the App.

### 6. One Release, one path

We will release the factory as one line: immutable `factory/vX.Y.Z` tags and moving
`factory/v<MAJOR>-next` and `factory/v<MAJOR>-stable` channels, on ADR-0002's mechanism. Workflows,
Kernel, Harness, prompts, manifests, Lifecycle and configuration all ride it. Ring membership is one
file in the Release. The factory repo is served by `next`, and `stable` serves consumers.

- **Every Run records the Release it ran.**
- **Inside a Release, factory files are read at `github.job_workflow_sha`,** never at a branch.
- **The only factory files that run from the default branch are the entry shim in the factory repo
  and the nudge file in a consumer that carries one.** Both are byte-frozen thin callers under ADR-0001:
  every job `uses:` a pinned factory reusable and declares no `steps:` or `run:`. The shim has one
  static caller job per channel and selects between them with a job-level `if:` on the output of a
  pinned ring-resolution job and on the pause variable. Those two non-event predicates are the only
  additions to ADR-0007's filter rule.
- **A consumer repo carries at most one factory file,** byte-identical to the template in the
  Release it follows. It subscribes to no event that would run a copy of itself from a work-item
  branch.
- **Rollback executes no file from the Release being rolled back.**
- **A candidate reaches `stable` only when the Ledger holds, for that Release, an eval result for
  each production Intent whose inputs changed and verified Effects from the `next` ring.** A run
  conclusion is not evidence, and a ring with no Runs of the candidate is not evidence.
- **An Intent is cut over only after an eval set exists for it that exercises the production
  path:** the approving Intent before review moves, the code-writing Intents before they move.

### 7. An approval is bound to content

We will keep GitHub's dismissal of stale approvals, bind each verdict to a content identity (a hash
of the pull request's own diff against its merge base), and decide approval in one Kernel function.

- **A verdict is re-issued without a Run only when the content identity equals the one reviewed.**
  Any other case is a review.
- **An approval is withdrawn only by the platform on new content or by a recorded Kernel transition
  that cites a new unresolved finding,** and that transition also removes the pull request from the
  merge queue. No Role dismisses its own approval.
- **The factory updates a pull request's branch only when it conflicts with its base.**
- **A merge without a standing independent approval has an Override record.**
- **An approval is decided from Findings and human transitions** (decision 12). A human comment or
  review thread is a Finding from a human Lens and always gates. This replaces the POC's rule that
  every comment body needs a verified disposition.
- **A human resolving a review thread in GitHub's interface is a declared human transition.**
- **A Finding is decided by the Role that owns its category,** under an authority table held as
  data. The author proposes a Disposition and the owner accepts or rejects it. An owner resolving
  a thread it has accepted is a declared Role transition. No Role decides on its own work, and a
  security Finding is never declined without an Override.
- **A domain Role starts in shadow.** It decides on a sample, its decisions are recorded and bind
  nothing, and the reviewer owns the category meanwhile. It is promoted to a gate on an eval set
  and a measured record, one Role at a time.

### 8. Verification binds

We will make the factory's own verification a required check from the first commit of the tree.

- **`factory / verify` is a required check on the factory repo's protected branch.** It runs on
  every pull request and on `merge_group`, with no path filter.
- **A required check is hermetic:** it reads nothing outside the merge commit.
- **A required check is deterministic.** Randomised exploration runs on a schedule and blocks
  nothing.
- **The maintainer's own approval never depends on the factory running.** It is the way out when the
  Release that serves the factory is broken.
- **The declared Lifecycle is checked mechanically** for termination, undeclared cycles, and Hold
  and Pause semantics.

### 9. One fact, one place

- **The set of Roles is the listing of `roles/`.** The consumers, each consumer's ring and each
  Role's triggers are each written once in the factory repo.
- **Any table of these in a document is generated, and a stale one fails `factory / verify`.**

### 10. Migration: built greenfield, cut over as a strangler

- **Factory code is written in the factory repo.** This repo receives defect fixes, configuration
  fixes and the do-nothing commits that cutover needs, and nothing else.
- **Cutover is pause, then repoint.** With a poller there is nothing in the factory for a consumer's
  workflow to call. First, this repo's channel tag for an intent family moves onto a commit where
  that family does nothing. Then the factory's ring file lists the repo for that family, and takes
  effect at the factory's next Release. Between the two, nobody serves that family on that repo;
  both serving it is what never happens. The maintainer accepted the gap on 2026-10-10. Reversing
  the two switches is the rollback. No consumer file changes during cutover.
- **This repo is not renamed, and its name is not reused, while any caller references it.** GitHub
  Actions does not redirect reusable-workflow references.
- **Consumers are re-pinned to the factory repo last,** through the standards sweep, after every
  intent family is served by the factory at `stable`. This repo then keeps only what GitHub's
  `.github-private` convention gives it.
- **For any repo and intent family, exactly one line serves it,** the POC or the factory, as
  recorded in the ring file. A check derives this and fails on dual serving.
- **The first factory component is the review intent, running end to end on the factory repo
  itself,** so that the factory reviews everything built after it. Until the first Release on `next`
  serves the factory repo, the Maintainer approves factory changes. This replaces the first draft's read-only
  observer as the first component (maintainer, 2026-10-10).
- **An intent family is cut over for a consumer only after it has run at `next` on the factory
  repo, its Release has been promoted to `stable`, and its eval set exists** (decision 6). The comparison of the factory's decisions with the
  POC's on live traffic is still made and reported. It is a measure, not a gate.
- **From that point the POC takes defect fixes only.**
- **A compensating workflow is retired in the change that makes it unnecessary, or keeps a recorded
  reason to remain.** The number of compensating workflows does not rise during the migration.
- **The migration has a defect policy and a stopping rule, and no dated limit.** The first draft
  required a dated limit, a defect policy with a weekly cap and a kill criterion before this
  decision was in force. The maintainer settled all three on 2026-10-10:
  - **Limit.** None. No period is set.
  - **Defect policy.** POC defects are fixed in the POC as needed. There is no weekly cap.
  - **Stopping rule.** If the factory is not adopted and used, the maintainer decides to stop. No
    measure stops it automatically. The control room shows adoption, use and the factory's results
    against the POC's baseline so that the decision is informed. If the migration stops, the
    identity change and the configuration fixes are kept and unused factory code is deleted.
  - **Decision points.** At the first Release on `next` that serves the factory repo, and at the
    first consumer repo served, the maintainer records continue or stop. Before the first, the control room shows how many factory
    pull requests the maintainer has approved, against a starting figure of 40.
- **Escaped defects (PRD SM-C1) are baselined before any step that raises the autonomy rate.**
- **Three assumptions are settled on a canary repo before any cutover:** that a pull request
  authored by the App needs no extra approval under the live ruleset, which sets
  `require_extra_approval_for_unattributed_changes`; that the App can enable auto-merge and enter
  the merge queue; and whether sending a nudge counts against GitHub's content-creation limit.

### 11. The poller and the view are measured

The first draft adopted a git-backed store and a wake per event provisionally, because every
comparable orchestrator polls from one standing process and keeps control state it can rebuild
(review §13). The maintainer settled both on 2026-10-10: state is derived (decision 2) and the
Controller polls (decision 3). The thresholds written for the provisional choices are kept as
measures of the settled ones.

- **Over two weeks of serving the factory repo:** handling passes and nudges uses at most 10% of
  the org's job-minutes; a pass costs at most 3,000 GraphQL points an hour at peak; and the
  95th-percentile delay from a change that produces no event to a decision is at most 15 minutes.
- **If the delay threshold fails, the nudge file is installed where it fails.** If it still fails,
  a follow-on ADR decides between a longer-lived polling job and a wake per event.
- **If the view cannot be kept equal to a rebuild, a follow-on ADR replaces it.** Decisions 1 and
  4 to 10 stand either way, because the Kernel does no I/O.

### 12. Lenses report through one contract; convergence is decided, not discussed

The maintainer's working hypothesis is that a council of independent Lenses (models, tools and
perspectives) produces a better outcome than one agent alone, across the whole lifecycle. The POC
ran such a council through free-text discussion. The research supports the hypothesis under
conditions (review §15), and those conditions are the boundaries here.

We will treat every source of judgement on a work item, whether a Role, a third-party reviewer, a
tool or a human, as a Lens that reports Findings in one schema, and we will decide Convergence in
the Kernel.

- **A Finding is a structured record:** its source, an identity that is not text, a location, a
  severity and the content version it applies to. Whether it is open is read from its surface.
- **A third-party reviewer is integrated through a declared contract.** Its entry in the reviewer
  registry names the structured surface its Findings are read from: a check run and its
  annotations, code-scanning alerts, or review threads. A comment body is presentation for people.
  Nothing parses one to decide, waits for one, or is gated by one. A reviewer with no structured
  surface gates nothing.
- **A third-party Finding whose category and severity are prose is typed by adoption.** The
  in-house reviewer is given it as input and, if it agrees, raises a Finding of its own that
  carries those fields. No code parses the prose, and no separate Role exists to type it.
- **What people read is rendered from the records** by the Harness. No Role writes prose that
  another component must interpret.
- **Lenses do not address each other.** No Lens's output is another Lens's trigger. Each reports to
  the Controller, and none sees another's verdict on a content version before giving its own.
- **One author per change.** Lenses judge a change; they do not co-write it.
- **Convergence is a Kernel function:** every Lens required for the item's class and stage has
  reported on the current content version, and no blocking Finding is open. An item that has not
  converged within its declared bound is placed on Hold.
- **The required Lenses are declared per class of work item and stage, as data.** The starting set
  is the deterministic checks, the in-house reviewer and humans. A Finding from a Lens outside the
  required set gates only when a required Lens adopts it as its own.
- **A Lens earns its place.** The Ledger records each Lens's Findings, the share acted on, the share
  no other Lens raised, and its cost. A Lens joins a required set only with a measured marginal
  contribution.

This decision fixes the contract and the measure. It does not choose the council.

### Follow-on ADRs this decision requires

Numbers are assigned when each is written. Each lands with the migration step that makes it true.

| Follow-on | Must decide | Effect on the log |
|---|---|---|
| **Agent identity** | Each Role's App and its permissions (the shared name prefix is `combsmith-sf-`); how tokens are narrowed per Role; the credential that a consumer's nudge file and the external timer use; the reviewer credential's confinement; what interaction model §12.2 says afterwards. | Supersedes ADR-0008. |
| **Records and the control room** | Run naming; the artifact and view schemas; where held-out eval sets live; how legacy markers are read during migration. | New. No ADR governs this today. |
| **Admission** | The poller and its schedule; the nudge file; the external timer; the pass record; how a human Pause and a Hold are read; the LLM capacity signal and its credential (PRD OQ-3); priority order. | Extends ADR-0007, including a `pull_request_target` subscription that ADR-0007 excludes and that is safe only because the nudge file checks out nothing and sends a nudge that carries nothing. Admission trusts no event: an Outside contributor's pull request produces no Run that holds secrets or writes without a Maintainer decision (PRD FR-63). ADR-0010's job-level concurrency key stays in use for the per-item group. Supersedes ADR-0009 when the router it names is retired. |
| **Run contract** | Task, Result and Effect schemas; the sandbox; resume; whether an adopted runtime fills the inner half. | Extends ADR-0005. Supersedes ADR-0011, which should be accepted now as the interim rule. |
| **Release unit and promotion** | The eval gate and its cost budget; ring membership; rollback; retirement of per-agent names. | Supersedes ADR-0002 and ADR-0006, restating what survives of each. |
| **Kernel language and verification** | Type checking; size and complexity budgets; recorded-interface tests; when the legacy suite becomes required. | Supersedes ADR-0004, restating its principle. |
| **Merge integrity** | The content identity; the gate function's inputs; which Lenses are required; the Override record; merge-queue settings. | New. No ADR governs this today. |
| **Factory repository** | The ruleset of `petry-projects/software-factory`; how the do-nothing commits in this repo are tested; the final re-pin of consumers; what this repo keeps afterwards; where these three documents and the ADR log live once the factory repo exists. | New. Decision 1 fixes that there is one. |
| **Council composition** | Which Lenses are required for each class of work item and stage (PRD OQ-12); how their Findings are aggregated; what counts as independent; the cost each stage may spend on its council. Decided from the Ledger's measure of each Lens, not in advance; review §16.6 proposes the set to start measuring from. | New. Extends ADR-0003, whose registry binds a review target to a rubric and is the nearest existing form of a Lens declaration. |

ADR-0001 and ADR-0003 are kept without change. ADR-0012 governs the POC's comment gate until the
merge-integrity follow-on supersedes it. ADR-0000 is kept; adding a forward link for
extension remains a separate decision.

## Consequences

- **The failure classes get structural answers rather than guards.** A lost event delays a work
  item instead of deleting its request. "Fixed" is written by the component that pushed the commit.
  The Maintainer can review an agent's pull request. A change to any artifact reaches production by
  one gated path. "Why is this not approved" has one function to read.

- **It is a rewrite of the core, in a second language, while the line keeps running.** Roughly
  53,000 lines of shell and 70,000 lines of bats become legacy. Two systems coexist for months, and
  the maintainer's load rises before it falls. The builders are largely the agents being replaced.

- **Incident knowledge will be lost in translation.** The bats suite encodes years of specific
  failures; one script cites 48 issues. Recorded-fixture replay recovers some of it. The comparison with
  the POC's decisions in decision 10 is the only measure of how much.

- **GitHub Actions stays the queue and the timer.** This decision bets that reconciling from
  recorded state makes dropped ticks and evicted runs harmless. It does not make them rare. Every
  pass costs a runner start, and a change with no nudge waits for the next pass. If the bet fails,
  the off-Actions control plane ADR-0007 rejected is still to be built. The Kernel's lack of I/O is
  what keeps that move cheap.

- **Hub execution concentrates the blast radius.** A bad `stable` Release, or a broken entry shim,
  stops every repo at once. ADR-0007 accepted that per repo; this accepts it per org. The shim's
  byte freeze and the promotion gate are correspondingly load-bearing.

- **Four repos for a while.** The standards repo, this repo, the factory repo and the control room coexist until the
  last consumer is re-pinned. The split this review criticised gets wider before it gets narrower.

- **Nothing limits the build, or the period in which two systems run.** Stopping is a judgement
  the maintainer makes, the POC has no cap on fixes, and until a Release on `next` serves the factory repo
  every factory change needs the Maintainer's approval. The review ranks a starved migration as the
  likeliest failure (§14.2), and the period in which that would happen is the one these leave open.
  The signal to watch is the weekly share of merged pull requests that land in the factory repo.

- **Domain owners are model Lenses that gate.** Each owning Role's decision to accept a Disposition
  closes a Finding. The research is plain that a reviewer weaker than the author makes the result
  worse (review §15). Each owner therefore needs an eval set before it gates and is measured like
  any other Lens.

- **One App per Role means up to about ten private keys in the end,** each a high-value secret,
  and a manual registration when a Role first writes.

- **A greenfield build can fail to reach parity.** The POC's tests encode incident history that a
  new codebase does not have. The comparison in decision 10 is the only measure of how
  much was lost, and it measures decisions, not every effect.

- **Cutover leaves a gap.** An intent family is unserved on a repo from the moment the POC stops
  serving it until the factory's next Release, which the PRD bounds at 48 hours.

- **The factory's own changes are gated by a Release that has not been promoted.** The factory repo
  is served by `next`, because its own pull requests are the best evidence a Release can have. A
  bad Release reaches the factory repo at once, and only that repo. The deterministic required
  check, the brakes and the Maintainer's ability to block are what stand behind it.

- **A consumer's work runs in the hub.** Runs for a consumer's work items execute and log in the
  factory repo; the consumer's own Actions tab shows nothing of them, or only a nudge. `verify` runs the consumer's
  tests on a hub runner, so each consumer must declare its setup and test commands, which the POC
  infers.

- **One Release removes per-role staging and rollback.** A prompt fix for one Role waits for the
  whole gate, and a rollback reverts every Role. ADR-0006 made this trade for personas knowingly;
  this makes it for the fleet. Two channels are also less staged exposure than the four ADR-0002
  allows.

- **Eval-gated promotion spends the scarcest resource.** Each eval case is a real model call against
  the subscription window. Candidates must be batched and results cached, so "merged" and "live"
  stay hours apart by design.

- **The factory can trigger itself.** Events authored by an App start workflows; events authored by
  the default workflow token mostly do not, which ADR-0007 called a free brake. The POC's main
  writer never had that brake, and after this decision nothing does. The brakes outside the
  Kernel (decision 3) replace it. They are small, and they are all that stands between a Kernel
  defect and an org-wide loop that could spend a week's model budget in hours.

- **This decision does not raise the factory's ceiling.** Output today is bounded by how many
  changes the maintainer can audit and merge by hand, and beyond that by how often a change is
  right the first time. A control plane makes approvals issue reliably. It does not make them
  correct. The PRD's autonomy and defect targets cannot both be met on current first-pass
  correctness (review §14.4). An acceptance signal the author cannot edit, and review depth, are
  the next ceiling and are not decided here.

- **The largest failure class is mostly policy, not structure.** Approvals fail to issue chiefly
  because every comment from nine third-party reviewers must be dispositioned. Decision 7 narrows
  what gates an approval. Without that change the control plane would reproduce the same deadlocks
  in one place instead of five. That change can also be made without this decision, in weeks, and
  doing so first is the cheapest test of how much of the rest is needed (review §14.5).

- **The credential boundary ends at the hub.** A branch pushed by `apply` runs the consumer's own
  `pull_request` workflows with that repo's secrets. Decision 5 keeps factory secrets out of that
  path. It does not protect a consumer's own secrets from a model-authored change, which is why
  `apply` refuses workflow changes without a human transition.

- **A poller is slower than an event.** A scheduled tick cannot be finer than five minutes and is
  often dropped here, so a change with no nudge waits for the next pass. In exchange a flood of
  events costs at most back-to-back passes, one runner slot of twenty. Decision 11 measures the
  delay.

- **Each App's private key is a high-value secret,** and the reviewer remains a user account with a
  long-lived token. The second is a standing exception to least privilege, confined to one job.

- **Re-issuing an approval for unchanged content approves a commit no reviewer read.** A defect in
  the content identity is an unreviewed merge. It fails closed on any doubt, and it must be watched.

- **The factory's history is 90 days.** That is how long GitHub keeps run records and artifacts in
  a public repo. Nothing older can be replayed or audited.

- **Money does not gate.** No decision reads the control room, and what a Run cost is known only
  there. The ceiling that places a Hold is a number of Runs per work item; the Hold states the
  amount spent. On a metered credential the monthly cap of decision 3 is read from the provider.

- **A killed Run's cost is not known exactly.** The model CLI reports usage when an invocation
  ends, so a Run that dies mid-turn has only its duration.

- **The control room is public.** It aggregates on one page what is already public item by item,
  including what awaits the maintainer and how much capacity is left.

- **The `run` job has no network containment.** A model that is successfully injected can still
  read the LLM credential. An adopted runtime with a firewall would close this; building our own
  does not.

- **A council costs what it finds.** Every model Lens spends from the same scarce window, and the
  research is plain that adding one can lower quality: a weaker reviewer made a stronger author's
  work worse in a controlled study, and agents that cooperate on one piece of code succeed less
  often than agents working alone (review §15). Decision 12 therefore measures each Lens and keeps
  one author. It does not assume that more Lenses are better.

- **Some current reviewers lose their say.** A third-party reviewer that offers only a summary
  comment has no contract surface. Under decision 12 it becomes presentation for the maintainer and
  input a Role may read, and it gates nothing.

- **Nine more ADRs.** Five of them supersede accepted records. That ceremony is the price of a log
  that says what the system does.

- **Not addressed:** review depth, the reliability of third-party advisory reviewers beyond a
  deadline, and an exact LLM capacity signal, which the platform does not offer.

- **Reopen an off-Actions control plane** when a threshold in decision 11 fails; or, later, when
  more than 5% of admitted Runs are lost or start later than the liveness limit for four weeks; or
  the hub's run queue is the measured bottleneck on lead time; or API quota cannot be held under
  the PRD's headroom target; or a timer finer than a pass is required.
- **Reopen the worker runtime, the capacity model and eval-gated promotion** when the model CLI's
  headless default stops reading subscription credentials, which its documentation says will
  happen.
- **Reopen build versus adopt** when GitHub ships a generally available orchestrator that covers
  admission and identity.
- **Reopen runner budgeting** if the free plan's concurrency limit or the pricing of public-repo
  minutes changes. Each reopening means a new ADR.

## References

- `docs/prd/agentic-software-factory.md` — the requirements this decision is measured against.
- `docs/architecture/software-factory-design.md` — the interaction and contract design: structure,
  contracts with examples, the Lifecycle and its invariants, Role authority, why State is derived
  and not stored, how work is noticed, and the control room.
- `docs/architecture/factory-mvp-architecture-review.md` — evidence (§§2–3), root causes (§4),
  options and sub-decisions (§§5–6), target and trade-offs (§7), migration shape (§8), relationship
  to earlier ADRs (§9), requirements the analysis changed (§10), platform facts and assumptions
  (§11), comparison with other systems (§13), the adversarial review and the ceiling (§14), the
  evidence on councils and convergence (§15), reviewer surfaces and a starting council (§16), where
  a Lens runs (§17), building in place against building greenfield (§18).
- ADR-0000 (process) — immutability and supersede-not-edit, which the precedence rule above follows.
- ADR-0001 (thin caller / reusable) — the boundary the entry shim and the nudge file keep.
- ADR-0003 (review artifact contract and rubric registry) — the existing data contract that
  decision 12 generalizes from review targets to Lenses.
- ADR-0002 (channel tags and rings) — the mechanism decision 6 reuses with one name.
- ADR-0004 (pure logic plus bats) — the principle decision 1 keeps and the binding it will replace.
- ADR-0005 (advisory by default) — the opt-in decision 4 enforces.
- ADR-0006 (shared-runtime personas) — "a persona is a caller of the shared runtime", generalized
  to every Role.
- ADR-0007 (one ingress per repo) — the file this keeps, the hosted receiver it rejected, and the
  free loop brake this gives up knowingly.
- ADR-0008 (personas post as the owner) and `docs/agentic-interaction-model.md` §12.2 — the
  decisions the identity follow-on will supersede and reverse.
- ADR-0010 (ingress concurrency; allowlist schema) — the missing `extended-by` status.
- ADR-0011 (write-mode personas on a shared branch, proposed) — the interim rules decision 4 makes
  structural.
- `docs/postmortems/2026-06-pr-860-runaway.md` — why a loop bound must not depend on a reset the
  loop can reach.
- `scripts/lib/carry-forward.sh`, `.github/workflows/issue-triage-runner.yml`,
  `.github/workflows/persona-runner-reusable.yml`, `scripts/initiative-planner/apply-plan.sh` — the
  existing seams decisions 4 and 7 generalize.
- `petry-projects/.github-private#2197 — The fleet and every session share one GitHub API quota
  (don-petry, 5,000/hour) and the fleet alone uses about that much: it ran out on 2026-10-10 and
  failed a workflow`.
- `petry-projects/.github-private#1864 — Merge protections are unsatisfiable at N>1 open PRs: one
  merge to main forces a full re-review of every other PR — ~154 forced re-reviews in 48h, zero
  merges`.
- `petry-projects/.github-private#1741 — [bug] 42% of dev-lead runs are cancelled before doing any
  work — review findings sit unaddressed while the PR looks active`.
