# 0008. Personas post advisory comments as the owner account

## Status

accepted

## Context

Personas post advisory comments through the shared persona runner
(`persona-runner-reusable.yml`), which resolves *which account* a persona posts
as from that persona's `personas/<id>/persona.yml` `runtime.identity` —
following the manifest-read identity pattern of #1316/#1317, never a shared
default.

Three facts, all verifiable on `main`, decide this record:

1. **ADR-0005 already sanctions posting as a real account.** Its § on
   write-identity says: *"'Write runtime identity' here means code/branch write
   capability (commit, push, label, close), **not** the account a persona posts
   advisory comments as: an advisory-only persona may still run under a real
   account — `security-lead`, for instance, posts as the owner account
   `don-petry`."* Posting advisory comments as `don-petry` is therefore the
   accepted position, not a new direction.

2. **#1650 (PR #1694) contradicted that accepted record without superseding it.**
   #1650 switched eight persona manifests to `account: donpetry-bot` /
   `credential: DON_PETRY_BOT_GH_PAT` on the rationale that an advisory should be
   identifiably a bot and that a bot byline preserved both axes of the router's
   recursion guard. ADR-0000 makes an accepted ADR immutable — a change of
   direction is a NEW ADR, never an in-place edit — but #1650 changed the code
   without writing one, so since 2026-09-08 the accepted record (ADR-0005) and
   the manifests have disagreed. `dev-lead` was never switched and still posts as
   `don-petry`, so the fleet was also internally inconsistent.

3. **The #1650 identity is a live regression (#1734).** `DON_PETRY_BOT_GH_PAT`
   authenticates as `donpetry-bot`, which lacks permission to write issue
   comments in this repo: the runner's post step 403s and the advisory is
   **discarded** — persisted nowhere. A real qa-lead invocation on epic #1723
   was lost this way, twelve minutes after #1694 merged. `GH_PAT_DON_PETRY` is
   known-good: `dev-lead` posts advisories with it continuously, so restoring it
   resolves #1734 immediately, with no new secret to provision.

This ADR **aligns with** ADR-0005 rather than reversing it; it reverses #1650,
which was code that never had an ADR. No accepted ADR is being superseded, so no
`superseded-by` link is warranted — ADR-0005 remains `accepted` and unedited,
and this note exists so a future reader does not assume an unrecorded conflict
between the two records.

`pr-review` is deliberately out of scope. Its manifest identity governs the
account it **approves** pull requests as (`pr-review.yml` resolves `BOT_USER`
from it), not an advisory comment. It must remain the review-only machine user
`donpetry-bot`: `dev-lead` authors PRs as `don-petry`, and an approval from
`don-petry` on `don-petry`'s own PR is rejected by GitHub and would fail the
last-push-approval / CODEOWNERS gate. ADR-0005's carve-out is about *advisory
comments*, which is exactly the boundary that keeps `pr-review` untouched here.

## Decision

We will make advisory personas post their advisory comments as the **owner
account `don-petry`**, using the credential `GH_PAT_DON_PETRY`, restoring the
ADR-0005 position across the fleet:

- The eight advisory personas (`business-analyst`, `devops-lead`, `qa-lead`,
  `scrum-master`, `security-lead`, `solution-architect`, `sre-lead`, and
  `dev-lead` — already correct) declare `runtime.identity.account: don-petry`
  and `runtime.identity.credential: GH_PAT_DON_PETRY`.
- `pr-review` is **not** an advisory-comment poster in this sense and keeps
  `donpetry-bot` / `DON_PETRY_BOT_GH_PAT` — it is the PR-review approver and must
  be a distinct account from the code author.
- Identity is still read from the manifest, never a shared default (#1317
  preserved). The runner continues to accept both `GH_PAT_DON_PETRY` and the
  grandfathered `DON_PETRY_BOT_GH_PAT`; the change is one line of manifest per
  persona, not a workflow behaviour change.

## Consequences

- **#1734 is fixed:** advisories post with a known-good credential and land
  instead of 403ing into the void. Intent (ADR-0005) and code agree again, and
  the fleet is internally consistent (every advisory persona posts as
  `don-petry`).

- **The recursion guard drops to a single axis — this is the real cost, stated
  plainly.** The router's pre-filter
  (`persona-mention-reusable.yml`) carries two independent recursion axes: an
  **actor axis** (`comment.user.login != 'donpetry-bot' && != 'github-actions[bot]'`)
  and a **marker axis** (`!contains(body, '<!-- persona:')`). With personas
  posting as `don-petry`, the actor axis no longer covers persona output — and
  `don-petry` **cannot** be added to that exclusion list, because it is the human
  maintainer who invokes the personas most; excluding it would make them
  un-invocable. So the **marker axis becomes the sole mechanical guard** for
  persona output.

- **Why that single axis is acceptable:**
  1. The marker is **workflow-enforced, not prompt-enforced.**
     `persona-runner-reusable.yml` applies `pr_ensure_marker` in the *post* step
     — the only writer — so an agent that forgets the marker cannot post an
     unmarked comment because it cannot post at all. Prompt-only marker
     enforcement is precisely how #860 produced 1,481 acks in 4.5h
     (`docs/postmortems/2026-06-pr-860-runaway.md`); this design does not rely on
     it.
  2. It has been **proven live:** the #1300 soak posted a marked advisory, a
     router run picked it up and returned `skipped` — the guard caught its own
     marker.
  3. A **third, weaker protection remains:** `prompts/<id>/advisory.md` forbids
     writing a literal `@petry-projects/<role>` in the body, so an advisory
     should carry no routable handle at all.

- **Residual risk (do not bury it):** the guard is now single-axis. If the marker
  enforcement in the post step is ever weakened or bypassed, nothing else stops a
  persona comment from re-routing into an unbounded loop. That makes
  `pr_ensure_marker` and its bats coverage (`tests/persona_runner.bats`,
  the *forgot-the-marker* path) **load-bearing** in a way they were not before —
  a change to the post step must treat them as such.

- **`donpetry-bot` is still used elsewhere** — as `pr-review`'s approver identity
  and `dev-lead`'s review identity — so it stays in the router's actor-exclusion
  list; this decision does not touch that list.

## References

- ADR-0005 (`docs/architecture/adr/0005-advisory-by-default-personas.md`) — the
  accepted record this aligns with; already permits posting as a real account.
  Not superseded.
- ADR-0000 (`docs/architecture/adr/0000-adr-process.md`) — ADR process,
  immutability, and the supersede-not-edit rule this record follows.
- #1650 / PR #1694 — the (ADR-less) code change this reverses; its unperformed
  AC #6 (live verification) is repeated here as the acceptance bar.
- #1734 — the live regression this fixes.
- #1317 — identity resolved from the manifest, never a shared default
  (preserved).
- `docs/postmortems/2026-06-pr-860-runaway.md` — why marker enforcement lives in
  the workflow, not the prompt.
