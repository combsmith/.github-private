# 0011. Write-mode personas on a shared branch: verify what landed, retract what did not

## Status

proposed

## Context

ADR-0005 makes write access an opt-in gate: dev-lead's write surfaces are armed
by the `dev-lead` label. It does not say how a write-mode persona should behave
on a branch that **other actors are pushing to at the same time**, such as a
maintainer, a Claude session, or the auto-rebase bot.

petry-projects/.github#1220 showed what goes wrong
([#2013](https://github.com/petry-projects/.github-private/issues/2013)). While
a human session was driving the same branch:

- dev-lead posted "Fixed in …" replies for changes that never reached the
  branch. Its claim named the PR's **first** commit: the head the model read
  with `git rev-parse HEAD` *before* committing anything, because the prompt
  told it to cite that SHA and also told it not to commit.
- CodeRabbit marked a thread "Confirmed as addressed" on the strength of a
  reply describing `15a919e`, which *was* pushed. A wrong fix cleared a review
  gate: it added a new test and broke an existing one without editing it, and
  the persona never ran the suite against the pre-pass baseline.
- A bot suggestion ("update the older test so the suite can pass") was applied
  literally. That rewrote an existing test and inverted deliberate behavior.

The no-clobber push (#1311/#1607) already prevented dev-lead from overwriting
another actor's commit. Everything *around* the push was still the model
describing itself. The #1692 claim check ran only when the harness resolved a
thread, and the pre-pass SHA passed it trivially. Nothing ever took a posted
claim back. That breaks ADR-0004's "Fail Loud, Never Fake".

## Decision

We will make every write-mode persona sharing a branch follow five rules, each
enforced by harness checks with bats tests (pure classifiers where applicable,
per ADR-0004), not by prompt text alone:

1. **Incorporate or stand down, never force.** Before pushing, the persona
   reconciles with the *true* remote head. It rebases a foreign commit in, or
   stops and escalates when that cannot be done cleanly. A foreign commit is
   never discarded (`push_no_clobber`, `scripts/lib/git-push-guard.sh`).
2. **"Pushed" is a verdict, not an assumption.** After the push, the harness
   compares the pre-pass head, the pushed SHA and the re-fetched remote head
   (`cl_push_landed_verdict`, `scripts/lib/claim-landing.sh`). Any result other
   than `landed` counts as a failed push.
3. **A claim must name a commit this pass produced and that landed.** The claim
   SHA must be on the reference head and **not** contained in the pre-pass
   head (`acv_claim_in_pass`, `scripts/lib/addressed-claim-verify.sh`). The
   harness checks this at thread-resolution time against the PR head. It
   checks it again after every push outcome against the **remote** head. Every
   claim reply posted during the pass that fails is **retracted**: both markers
   are stripped and a retraction notice is added, so the reply can never
   authorize resolution and other bots cannot read it as a fix. The outcomes
   covered are a rejected or unverified push, a guard abort, an engine
   failure, no commit, and a stale SHA.
4. **An existing test is not the persona's to rewrite.** A fix pass that
   changes or deletes an existing test line, or adds a skip, without an
   explicit cited `Test-Change-Justification:` trailer is refused before the
   push and escalated to a human (`scripts/lib/test-tamper-guard.sh`). A bot
   suggestion that contradicts an existing test goes to a human.
5. **A red suite blocks the push.** Before the push, the harness runs the
   repo's test command on the pass's result. A test that passed on the
   pre-pass head and fails now refuses the push and escalates like the tamper
   guard (`scripts/lib/test-regression-guard.sh`). A failure that already
   existed on the pre-pass head does not block. When no test command can be
   determined, the run summary says the suite was not run; it never implies
   green.

The boundary a check can assert: **no dev-lead claim reply survives a pass
unless the claim's commit was produced by that pass and is on the remote
head.**

## Consequences

- A rejected, aborted or failed pass leaves retracted replies, not false
  "Fixed" ones. The thread stays open and the next pass re-verifies.
- The fail-closed direction costs some true claims. When the push guard
  rebases dev-lead's commits onto a foreign commit, the SHAs the model cited
  no longer exist on the remote, so those claims are retracted even though the
  fix landed. Re-mapping rebased SHAs is a possible follow-up. A stuck thread
  is a nuisance; a wrongly cleared gate is a defect.
- The model must commit locally before it replies, so its claims can cite a
  real commit. The prompts now say so. A pass that leaves its changes
  uncommitted gets them committed by the harness, and its claims (citing the
  pre-pass head) are retracted.
- Legitimate test changes need one extra line, the justification trailer. In
  exchange, a bot-driven pass can no longer silently invert a tested behavior.
- Still open: whether a persona should *back off entirely* from a branch with
  recent non-persona pushes, or require an opt-in label to push to a branch it
  did not create. This ADR covers correctness of what is claimed. It does not
  cover whether to participate at all.
