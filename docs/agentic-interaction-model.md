# Agentic interaction model

**Status:** normative (repo-local standard) · **Scope:** `petry-projects/.github-private`
· **Anchors:** the per-role interaction contracts (Story 2 / #1404), the CI validator
`validate-interaction-model` (Story 4 / #1406), the documentation wiring (Story 7).

This document codifies **how agentic roles are triggered and how they interact** so the
pattern is explicit, reviewable, and enforceable rather than tribal knowledge. It is the
normative source later phases reference — a contract, a validator, or a leak fix cites a
rule here rather than re-deriving it.

> **Adding a new role?** Follow the step-by-step runbook
> [How to add an agentic role](./adding-an-agentic-role.md) — it walks the trigger-class
> choice, the contract shape, the event-vs-bridge decision, and the timer contract, each
> pointing back to the governing section here.

It is written **repo-local first** but shaped for promotion into an org-wide
`standards/agent-standards.md` in [`petry-projects/.github`](https://github.com/petry-projects/.github):
the principles and rules are org-general; only the classification table (§4) is
repo-specific inventory. When promoting, lift §§1–3 and §§6–10 verbatim and regenerate §4
per consuming repo. This mirrors the promotion pattern already used for the off-peak
scheduling standard (AGENTS.md → `standards/ci-standards.md`, epic #722).

---

## 1. The event-first principle

**An agentic role reacts to the event that represents the work; it does not poll for work
on a clock when an event already carries the signal.**

GitHub is an event system: a PR opens, a review is submitted, a check run completes, an
issue is labeled. Each is a webhook that can wake exactly the role that should act, at the
moment there is something to act on, scoped to the thing that changed. A timer, by
contrast, wakes on a fixed cadence whether or not there is work, re-derives "what changed"
by scanning, and adds latency equal to its period.

Therefore:

- **Prefer the event.** If a webhook exists that represents the work, subscribe to it. Do
  not add a cron that re-discovers what the webhook already told you.
- **Timers are backstops, not primaries.** A timer is legitimate only as a reconciliation
  net under an event path that can miss (§3 Class 2), or when the *origin* of the work is
  itself a schedule (§3 Class 3) — never as the main way event-shaped work is picked up.
- **A timer that has become the primary path for event-shaped work is a leak** (see
  `dev-lead-retry` in §6). It re-introduces exactly the latency and the runaway-amplifier
  risk the event path was meant to avoid.

The event-first principle is the reason the trigger taxonomy in §2 exists: it forces every
trigger to declare *why* it is a timer rather than an event, and to prove it is not a
disguised polling loop.

---

## 2. The three trigger classes

Every agentic workflow's `on:` block falls into exactly one of three classes. The class is
determined by the **origin of the work**, not by the count of triggers.

### Class 1 — event-driven reactions

The work originates from a GitHub webhook that represents it. The workflow subscribes to
that event and acts, scoped to the event's payload.

- **Rule.** Subscribe to the narrowest event(s) that carry the signal. Do **not** add a
  `schedule` — a Class 1 role with a cron is either a disguised Class 2 (declare it and
  give the timer a `timer_role` + stop condition, §6) or a leak.
- Permitted non-webhook triggers: `workflow_dispatch` (human/manual escape hatch) — not a
  clock. `repository_dispatch` is included in `E` (§3) when it delivers scoped work to a
  receiver role (e.g. `persona-runner.yml`, `gh-aw-cross-org.yml`); it is the PAT-backed
  bridge that carries real work, not a manual escape hatch. A `workflow_dispatch`-only
  workflow with no clock is Class 1 by declaration (validator verifies `not S and not R`);
  it acts as a human-explicit bridge for non-subscribable events (e.g. `discussion:[labeled]`).
- **Self-trigger is forbidden** (§7 rule 1): a Class 1 role must never subscribe to an
  event class its own output emits (e.g. a role that posts an `issue_comment` must not act
  on `issue_comment: created` without filtering out its own actor/marker).

### Class 2 — backstop / reconciliation timers

The work is fundamentally event-driven (Class 1), but the event path can *miss* (a dropped
webhook, a race, a state that became actionable without a fresh event). A Class 2 workflow
pairs the event fast-path with a **low-frequency reconciliation timer** that guarantees a
worst-case latency bound.

- **Rule.** A Class 2 timer must:
  1. carry a `timer_role` of `backstop`, `safety-net`, or `self-heal` (§6.1);
  2. **check a stop condition before acting** (§6.2, §7 rule 6) — it re-dispatches only work
     that is still open and not human-gated;
  3. be **idempotent** — an extra tick is harmless, a missed tick self-heals next tick;
  4. **should** exist alongside an event fast-path, not instead of one. A Class 2 timer with
     a null `event_fast_path` (a schedule as the *only* path to fundamentally event-driven
     work) is a **leak** — a de-facto convergence clock — and is flagged, not forbidden (see
     `dev-lead-retry`, §6.3).
- The timer's cadence buys a latency bound, nothing else; correctness comes from the event
  path. This is why idempotent sweeps may run more often on odd offsets (AGENTS.md
  "Scheduled workflows", Option 2) — precise timing does not matter to a converging sweep.

What separates a Class 2 timer from a Class 3 schedule is **not** the shape of the `on:`
block (both carry a `schedule`) but the *role* of the cadence: a Class 2 cadence reconciles
work that is fundamentally event-driven (so it declares a `timer_role`); a Class 3 cadence
*is* the origin of the work (so it declares none). The validator keys on that declared
`timer_role` — see §3.

### Class 3 — scheduled-origin work

The work's origin *is* a schedule: a weekly report, a daily health scan, a periodic canary.
There is no upstream webhook that represents "produce this week's cost report" — the
cadence is the requirement.

- **Rule.** A Class 3 workflow's `schedule` is legitimate and primary. It must still obey
  the off-peak scheduling standard (non-zero, staggered minute; AGENTS.md "Scheduled
  workflows"). A `workflow_dispatch` (and, for a post-merge canary, a narrow `push` gate)
  may accompany it; these do not change the class.
- A Class 3 workflow must be **idempotent / self-healing** in the same sense as Class 2:
  extra or missed ticks must not corrupt state. Reports overwrite or dedupe; canaries are
  dry-run.

---

## 3. Class discriminator (the parse contract)

`validate-interaction-model` (#1406) checks each §4 row against reality using this
discriminator. Class 1 vs {2,3} is derivable from the `on:` block alone; Class 2 vs 3 turns
on the row's declared `timer_role` (a timer's *role* is not visible in `on:` — that is why
the contract declares it, §6.1). The validator therefore verifies **consistency invariants**,
not a single derived label:

```text
Let S  = the workflow has a schedule.cron trigger.
Let E  = the workflow has >=1 GitHub webhook event trigger that represents work
         (pull_request, pull_request_review, pull_request_review_comment,
          issue_comment, issues, check_run, check_suite, workflow_run,
          discussion_comment, push, repository_dispatch, ...), EXCLUDING only
          workflow_dispatch (a manual/human escape-hatch trigger, not a clock
          and not a primary-work event). A workflow whose only trigger is
          workflow_dispatch (no E, no S) is Class 1 by declaration — the
          validator verifies not S and not R but cannot derive E from the on: block.
Let R  = the row's timer_role column carries a role value
         (backstop | safety-net | self-heal); a cell containing only `—` or
         `N/A` is treated as empty (R = false).

Class 1  ⇒  E and not S and not R     (pure event reaction; a schedule here is drift)
Class 2  ⇒  S and R                   (a cadence whose role reconciles event-driven work)
Class 3  ⇒  S and not R               (a cadence that IS the origin: report / canary)
```

Consequences the validator enforces: a **Class 1** row must have no `schedule` and no
`timer_role`; a **Class 2** row must have a `schedule` **and** a declared `timer_role`; a
**Class 3** row must have a `schedule` and **no** `timer_role`. A `push`/`workflow_dispatch`
gate on a Class 3 workflow (e.g. a post-merge canary) is allowed and does not change the
class. `event_fast_path` is a *quality attribute* of a Class 2 timer — a null value marks the
leak in §6.3 — not part of the class discriminator.

---

## 4. Classification of current agentic workflows

**This table is machine-checkable, not prose.** Each row carries the workflow's path, its
asserted trigger class, its `timer_role` (if any), and a one-line justification. The shape
is a **fixed-column markdown table** with exactly these columns, in this order:

`Workflow (path) | Class | timer_role | Justification (cite the on: triggers)`

`validate-interaction-model` (#1406) parses this table and verifies each row's asserted
`Class` against that workflow's actual `on:` block via the §3 discriminator. **The table is
CI-verified, not review-verified** (§10) — treat it as load-bearing. When a workflow's
triggers change, its row here must change in the same PR or the validator fails.

**Escaping convention:** justification cells must be `|`-free (rephrase rather than escape);
backtick spans (e.g. `` `path/to/file.yml` ``) are allowed; the separator row uses
`---|---|---|---` with no padding.

**Multi-role ingress convention (ADR-0007).** Normally one workflow file is one classified
role and contributes **exactly one** row. The one exception is a collapsed
`agent-ingress.yml`: it holds **one job per collapsed role**, all sharing a single `on:`
union (ADR-0007), so it contributes **one row per role-job** instead of one row for the file.
Each such row's first cell names the shared path **and** its job, shaped `` `path` (job-name) ``
— e.g. `` `.github/workflows/agent-ingress.yml` (dev-lead) ``. The set of role-qualifiers for
the ingress path must equal the file's set of `jobs:` names (an under-documented job, or a row
naming a job that does not exist, fails — see §10). Every per-role row is classified against
the **same** shared `on:` union via the §3 discriminator: since the collapsed roles are Class 1
(the ingress carries no `schedule`), each row must be Class 1 with no `timer_role`. A legacy
single-role stub (pre-collapse, or a `pull_request_target` / Class-2 / Class-3 carve-out that
keeps its own file) carries **no** job qualifier and remains exactly one row.

| Workflow (path) | Class | timer_role | Justification (cite the `on:` triggers) |
|---|---|---|---|
| `.github/workflows/dev-lead.yml` | 1 | — | `pull_request`, `pull_request_review`, `pull_request_review_comment`, `issue_comment`, `issues:labeled`, `check_run`, `repository_dispatch` — pure webhook reactions; no `schedule`. |
| `.github/workflows/pr-review-trigger.yml` | 1 | — | `check_suite`, `pull_request_review`, `pull_request`, `repository_dispatch:[pr-review-mention]`, `workflow_dispatch` — webhook reactions; no `schedule`. |
| `.github/workflows/ci-failure-analyst.lock.yml` | 1 | — | `check_run:[completed]` only — reacts to a completing check. |
| `.github/workflows/dismiss-stale-bot-reviews.yml` | 1 | — | `pull_request:[synchronize]`, `pull_request_review:[submitted]` — reacts to a push/re-review. |
| `.github/workflows/issue-triage-runner.yml` | 1 | — | `issues:[opened, reopened]` — reacts to a new/reopened issue. |
| `.github/workflows/pr-review-mention.yml` | 1 | — | Mention router: `issue_comment`, `pull_request_review_comment`, `pull_request:[review_requested]`; parses + dispatches, no clock. |
| `.github/workflows/persona-mention.yml` | 1 | — | Mention router: `issue_comment`, `pull_request_review_comment`, `discussion_comment` — dispatches to the persona runner, no clock. |
| `.github/workflows/auto-rebase-retry.yml` | 1 | — | `workflow_run:[completed]` on `Auto-rebase non-Dependabot PRs` — event-driven retry handler; re-runs failed jobs bounded by attempt counter. No `timer_role`: event-driven retry handlers are Class 1 regardless of semantic role (see §6.1). |
| `.github/workflows/dependency-advisory.yml` | 1 | — | `pull_request:[opened, synchronize, reopened]` (paths-filtered to manifest files) — reacts to dependency changes in a PR; posts an advisory comment. |
| `.github/workflows/qa-lead-pr-advisory.yml` | 1 | — | `pull_request:[opened, ready_for_review]` — reacts to a PR entering review; a test-surface gate decides whether qa-lead posts one advisory. No `schedule`; `synchronize` deliberately not wired (#1646). |
| `.github/workflows/spec-drift.yml` | 1 | — | `pull_request:[closed]` — reacts to a merged initiative PR; runs the drift detector once and posts at most one advisory comment on the closed story. |
| `.github/workflows/release-notes.yml` | 1 | — | `push:[main]` — reacts to a merge to main; drafts a Keep-a-Changelog entry and opens a CHANGELOG PR. `workflow_dispatch` for ad-hoc runs. |
| `.github/workflows/gh-aw-cross-org.yml` | 1 | — | `repository_dispatch:[gh-aw-issue-triage, gh-aw-ci-failure]` — PAT-backed cross-org dispatch receiver; no schedule. |
| `.github/workflows/persona-runner.yml` | 1 | — | `repository_dispatch:[persona-mention]` — PAT-backed dispatch receiver for persona invocations; no schedule. |
| `.github/workflows/initiative-planner.yml` | 1 | — | `workflow_dispatch` only — human-explicit bridge for the `discussion:[labeled]` signal that cannot be subscribed to inline; §2 Class 1 by declaration (no schedule, no `timer_role`). |
| `.github/workflows/pr-auto-review.yml` | 1 | — | `workflow_run:[completed]`, `check_suite:[completed]`, `pull_request_review:[submitted, dismissed]`, `pull_request:[opened, reopened, synchronize, ready_for_review]` — multi-event readiness gate; no schedule. |
| `.github/workflows/pr-review-delayed-retry.yml` | 1 | — | `workflow_dispatch` only — armed on demand by `pr-review-sweep.yml` to retry a rate-limited PR review near its `reset` without depending on the best-effort cron (#1994). §2 Class 1 by declaration (no schedule, no `timer_role`); the in-run sleep is a deterministic armed delay anchored to `not_before`, not a scheduled trigger — the fix for the convergence-clock pattern, not an instance of it. |
| `.github/workflows/pr-review-sweep.yml` | 2 | backstop | `schedule: '2,17,32,47 * * * *'` backstop **plus** `workflow_run:[completed]` fast path (#898) scoped to the completing CI run's PR(s); idempotent, per-branch `cancel-in-progress`. |
| `.github/workflows/initiative-driver.yml` | 2 | safety-net | `issues:[closed, labeled]` fast path **plus** `schedule: '23 */6 * * *'` explicitly "safety net for missed close events"; sweeps every open `initiative:auto` epic idempotently. |
| `.github/workflows/dev-lead-retry.yml` | 2 | self-heal | `schedule: '15 */2 * * *'` + `workflow_dispatch`; re-dispatches `status=rate-limited` PRs once the limit clears. **Leak flagged in §6** — no event fast-path, so it behaves as a de-facto convergence clock rather than a true backstop. |
| `.github/workflows/token-report.yml` | 3 | — | `schedule: '34 8 * * 1'` weekly cost rollup; origin is the cadence. |
| `.github/workflows/reviewer-report.yml` | 3 | — | `schedule: '53 9 * * 1'` weekly review-activity report. |
| `.github/workflows/daily-pr-review-health.yml` | 3 | — | `schedule: '13 6 * * *'` daily health scan of run history. |
| `.github/workflows/feature-ideation.yml` | 3 | — | `schedule: '7 7 * * 5'` weekly ideation run; `workflow_dispatch` bridges the `discussion` event it cannot run inline. |
| `.github/workflows/readme-refresh.yml` | 3 | — | `schedule: '41 9 * * 1'` weekly org-README regeneration. |
| `.github/workflows/standards-sync.yml` | 3 | — | `schedule: '11 9 * * 1'` (guard enforces first-Monday-only) standards sync. |
| `.github/workflows/idea-triage.yml` | 3 | — | `schedule: '37 13 * * 1'` weekly Idea Promotion Queue refresh. |
| `.github/workflows/initiative-planner-canary.yml` | 3 | — | `schedule: '30 6 * * *'` daily dry-run canary of `initiative-planner.yml`. |
| `.github/workflows/initiative-driver-canary.yml` | 3 | — | `schedule: '40 6 * * *'` daily dry-run canary of `initiative-driver.yml`. |
| `.github/workflows/pr-review-canary.yml` | 3 | — | `schedule: '50 6 * * *'` daily canary; the `push:[main]` (paths-gated) trigger is a post-merge gate, not an event fast-path — origin is the cadence. |
| `.github/workflows/actions-fleet-monitor.yml` | 3 | — | `schedule: '27 6 * * *'` daily org-wide fleet scan; cadence is the origin. Cited in §5 as the canonical PAT-bridge example. |
| `.github/workflows/stale-manager.yml` | 3 | — | `schedule: '29 9 * * 1'` weekly stale scan across issues/PRs; cadence is the origin. |
| `.github/workflows/docs-health-check.yml` | 3 | — | `schedule: '21 0 * * 0'` weekly docs health scan; cadence is the origin. |
| `.github/workflows/skill-eval-report.yml` | 3 | — | `schedule: '51 7 * * *'` daily skill eval scoring (self-improving-skills pipeline); cadence is the origin. |
| `.github/workflows/premature-closure-audit.yml` | 3 | — | `schedule: '49 8 * * 1'` weekly premature-closure audit; cadence is the origin. |
| `.github/workflows/auto-rebase-health.yml` | 3 | — | `schedule: '43 7 * * *'` daily auto-rebase health report; cadence is the origin. |
| `.github/workflows/engine-token-liveness.yml` | 3 | — | `schedule: '23 7 * * *'` daily engine-token preflight liveness monitor (#1587); cadence is the origin. `workflow_dispatch` for ad-hoc runs. |
| `.github/workflows/budget-poller.yml` | 3 | — | `schedule: '17 * * * *'` + `'47 * * * *'` twice-hourly dry-run Claude budget poller (#2029; second slot because ~60% of scheduled ticks are dropped here, #2160); reads usage and logs what the breaker would do, writes no variable; cadence is the origin. |

> **Out-of-scope workflows (exclusion list).** The completeness check (§10) ignores the paths
> below. A workflow absent from both this table and this list is a completeness failure.
>
> | Path | Reason |
> |---|---|
> | `.github/workflows/ci.yml` | CI infrastructure — build and test, not an agentic role |
> | `.github/workflows/lint.yml` | CI infrastructure — linter, not an agentic role |
> | `.github/workflows/dependency-audit.yml` | CI infrastructure — dependency audit, not an agentic role |
> | `.github/workflows/sonarcloud.yml` | CI infrastructure — code-quality scan, not an agentic role |
> | `.github/workflows/codeql.yml` | CI infrastructure — code-scanning (CodeQL advanced setup), not an agentic role |
> | `.github/workflows/copilot-setup-steps.yml` | CI infrastructure — runner setup, not an agentic role |
> | `.github/workflows/test.yml` | CI test workflow, not an agentic role |
> | `.github/workflows/test-dev-lead.yml` | CI test workflow, not an agentic role |
> | `.github/workflows/test-aw.yml` | CI test workflow, not an agentic role |
> | `.github/workflows/duplicate-decl-gate.yml` | CI gate guard — enforces duplicate declaration check, not an agentic role |
> | `.github/workflows/holdout-guard.yml` | Gate guard — enforces merge conditions, not an agentic role |
> | `.github/workflows/test-deletion-guard.yml` | Gate guard — enforces test retention, not an agentic role |
> | `.github/workflows/sync-scope-guard.yml` | Gate guard — enforces sync-PR scope, not an agentic role |
> | `.github/workflows/dependabot-automerge.yml` | Dependabot plumbing — thin caller stub |
> | `.github/workflows/dependabot-rebase.yml` | Dependabot plumbing — thin caller stub |
> | `.github/workflows/auto-rebase.yml` | Thin caller stub — all logic in org-level reusable |
> | `.github/workflows/agent-shield.yml` | Thin caller stub — all logic in org-level reusable |
> | `.github/workflows/add-to-project.yml` | Thin caller stub — all logic in org-level reusable |
> | `.github/workflows/dev-lead-reusable.yml` | Reusable workflow — invoked via `workflow_call`, not a direct entrypoint |
> | `.github/workflows/ci-failure-analyst-reusable.yml` | Reusable workflow — invoked via `workflow_call`, not a direct entrypoint |
> | `.github/workflows/persona-runner-reusable.yml` | Reusable workflow — invoked via `workflow_call`, not a direct entrypoint |
> | `.github/workflows/pr-review.yml` | Reusable workflow — invoked via `workflow_call`, not a direct entrypoint |
> | `.github/workflows/repair-pr-approvals.yml` | Manual admin tool — `workflow_dispatch` only, no automated agentic trigger |
> | `.github/workflows/model-ab.yml` | Manual maintainer eval tool — `workflow_dispatch` only, no schedule/automated trigger, no agent→agent interaction (#1950) |

---

## 5. The GITHUB_TOKEN event-boundary rule and sanctioned bridges

**The rule.** A workflow step running as the default `GITHUB_TOKEN` **cannot emit webhooks
that trigger other workflows.** GitHub deliberately suppresses recursive workflow triggering
for events created by `GITHUB_TOKEN` (a push, a label, a comment, a `workflow_dispatch`, a
`repository_dispatch` made with `GITHUB_TOKEN` starts no downstream run). This is a
loop-prevention guard — but it also means **an event a Class 1 role is waiting for will
silently never arrive** if the upstream producer runs as `GITHUB_TOKEN`.

This boundary is real and already load-bearing in this repo. `actions-fleet-monitor.yml`
documents it inline where it wakes dev-lead:

> `# github.token events do not trigger issues:labeled workflows; use the`
> `# PAT to fire repository_dispatch so Dev-Lead Agent is explicitly woken.`

Crossing the boundary is allowed **only** via one of two sanctioned bridges:

### Bridge A — PAT-backed `repository_dispatch` (event-preserving)

Fire a `repository_dispatch` (or apply the triggering label) using a **PAT**, not
`GITHUB_TOKEN`. Because the event is authored by a real account, GitHub delivers it and the
downstream Class 1 role wakes. This **preserves the event** — the downstream role still runs
its normal event-driven path, scoped to the payload.

- **Canonical example:** the `check_run` → fix-ci bridge. `scripts/dev-lead-ci-relay.sh`
  resolves the PR from a `check_run` event (falling back to the commits-to-pulls API when
  `check_run.pull_requests` is empty, and skipping forks), and the workflow relays it via a
  **PAT `repository_dispatch`** (`dev-lead-ci-failure`) so dev-lead is explicitly woken. The
  fleet monitor uses the same bridge (`repos/…/dispatches` with `GH_PAT_*`) to wake dev-lead
  on high-failure signal.
- **Requirement:** the PAT is the identity boundary — it must be the role's declared
  `runtime.identity.credential` (AGENTS.md "Agent identity & credential secrets"), never a
  shared token borrowed to punch through the boundary. Note that fine-grained PATs are
  restricted to a single resource owner (one user or organization); if the workflow must span
  multiple organizations, classic PATs or GitHub App installation tokens should be used instead.

### Bridge B — a stop-condition-gated backstop timer

Where a PAT bridge is not available or not warranted, a **Class 2 backstop timer** (§2) may
reconcile the missed event on a cadence. The timer does not preserve the event — it
re-discovers the actionable state by scanning — so it **must** satisfy the full timer
contract in §6 (stop condition, idempotency, human-gated markers). `pr-review-sweep.yml`'s
scheduled backstop is exactly this: the net under its `workflow_run` fast path, nominally
≤15 min but best-effort — GitHub delays or drops scheduled runs under load (observed 3–7 h
in #1952), so a time-bound retry must not rely on it (the rate-limit case is armed explicitly by
`pr-review-delayed-retry.yml`, #1994).

**Never** attempt to cross the boundary by having `GITHUB_TOKEN` emit the triggering event
and hoping it fires — it will not, and the failure is silent.

---

## 6. The timer contract

Every `schedule.cron` on an agentic workflow (Class 2 or Class 3) is bound by this contract.
It mirrors the language already in AGENTS.md "Scheduled workflows" (off-peak, idempotent /
self-healing sweeps) — the two standards are consistent, not competing: AGENTS.md governs
*when* a timer may fire (off-peak, staggered minute, higher cadence only if idempotent);
this contract governs *how a timer must behave* once it fires.

### 6.1 The `timer_role` taxonomy

A timer must declare its role. There are three:

| `timer_role` | Meaning | Reset / stop |
|---|---|---|
| `backstop` | Reconciliation net under a Class 1 event fast-path; bounds worst-case latency when the event misses. | Stops when the work item is closed or human-gated; never re-arms a runaway. |
| `safety-net` | Catches work whose triggering event may be dropped entirely (not just delayed). | Same: acts only on still-open, non-human-gated work. |
| `self-heal` | Recovers a *failed* prior run (retry after a transient failure such as a rate limit). | Bounded by an attempt/state check; a success or a human marker ends it. |

A Class 3 report/canary carries **no** `timer_role` — its cadence is the origin of the
work, not a net under an event.

A Class 1 event-driven workflow also carries **no** `timer_role` even when it is
semantically self-healing. `auto-rebase-retry.yml`, for example, re-runs a failed job via
`workflow_run` — but it is Class 1 (a `workflow_run` reaction), and `timer_role` is
exclusively a property of Class 2/3 **scheduled** workflows. An event-driven retry handler
has no schedule and therefore needs no `timer_role` declaration.

### 6.2 Requirements every timer must meet

1. **Stop-condition-before-acting.** The timer checks a stop condition *before* any write
   or dispatch, and re-dispatches only work that is still open and actionable (§7 rule 6).
2. **Idempotency.** Extra ticks are harmless; a missed tick self-heals on the next tick.
   State is converged, not accumulated (dedupe by marker/SHA/key, never re-append).
3. **Skip human-gated markers.** The timer must **skip** any work carrying a human-gate
   marker (`needs-human-review`, `dev-lead:needs-human`, the `<!-- pr-automation-budget
   exhausted -->` marker, `initiative:hold`, `dev-lead:hands-off`). A timer that re-ignites
   human-paused work is a runaway amplifier (§7 rules 2, 6). **One narrow exception —
   the rate-limit-only hold (§6.4):** a `needs-human-review` hold whose ONLY basis is the
   rate-limit withhold marker (no genuine-escalation marker present) is exempt from this skip,
   because that marker's whole purpose is to promise the timer's OWN recovery.
4. **Never re-arm a runaway.** A timer must never reset a safety cap or re-dispatch work
   that a breaker has already stopped. Its reset path must be **human-gated** (§7 rule 2).

### 6.3 The correct example vs. the leak

- **Correct — `initiative-driver.yml` (Class 2, `safety-net`).** Its `schedule: '23 */6 * *
  *'` is explicitly annotated "safety net for missed close events." The primary path is the
  `issues:[closed, labeled]` event; the 6-hour timer only reconciles a dropped close, sweeps
  every open `initiative:auto` epic idempotently, and never releases `initiative:hold` /
  `dev-lead:hands-off` items. A textbook backstop under an event fast-path.

- **Leak — `dev-lead-retry.yml` (Class 2, `self-heal`).** Its `schedule: '15 */2 * * *'` has
  **no event fast-path** — nothing wakes it the moment a rate limit clears; the 2-hour cron
  is the *only* path. That makes it a de-facto convergence clock rather than a true backstop,
  and the #860 postmortem names it an **amplifier** ("re-ignites stalled loops"). It is
  contract-compliant only because it must still honor §6.2.3 (skip exhausted /
  `needs-human-review` PRs before re-dispatching, per the #860 P1 follow-up) and §7 rule 6.
  The standing remediation is to give it an event fast-path (so the timer reverts to a rare
  backstop) or to fold its retry into the state that already carries the rate-limit signal —
  not to shorten the cron.

### 6.4 The rate-limit-only exemption to §6.2.3 (#1550)

The rate-limit withhold path (`scripts/lib/advisory-review-gate.sh` →
`maybe_post_rate_limited_marker`, called from `scripts/review-one-pr.sh`) stamps a
machine-detectable marker —
`<!-- pr-review-agent rate-limited v1 sha=<HEAD> status=rate-limited reset=<ISO> -->` —
whose body **promises** "pr-review-sweep will re-review this PR after `<reset>`". That marker
is `pr-review-sweep.yml`'s (§4, `backstop`) *own* recovery signal: the sweep's rate-limit
retry branch reads it, waits for the reset, and re-dispatches a review.

**The defect (observed on PR #1531, 2026-08-19).** The rate-limit path never applies
`needs-human-review` — it only posts the marker. But a *concurrent* hold label (from a
budget/cycle-cap escalation, or a manual escalation) made the sweep's blanket §6.2.3 skip fire
**before** its rate-limit retry branch, so the label paused the very sweep the marker promised
would recover the PR. The hold disabled its own advertised recovery, and the PR stranded at
`REVIEW_REQUIRED` for >2h past the reset until a human removed the label — the same
self-blocking shape as the #1427 ci-pending deferral and the #1494 slot deadlock.

**The decision (of the two options in #1550 AC#2, we take the second).** The sweep **exempts a
rate-limit-only hold** from the §6.2.3 `needs-human-review` skip, rather than having the
rate-limit path strip the label. A hold is **rate-limit-only** iff a rate-limit marker sits at
the current head **and** no genuine-escalation marker is present. The classifier is the pure
`pr_hold_kind` (`scripts/lib/pr-automation-budget.sh`), which the sweep consults at its label
gate; it returns exactly one of:

- `budget-exhaustion` — `<!-- pr-automation-budget exhausted -->` present → **still paused**
- `cycle-cap` — `<!-- pr-review-agent escalation -->` present → **still paused**
- `rate-limit-only` — rate-limit marker at head, none of the above → **exempt** (fall through
  to the rate-limit retry; the embedded `reset` gate still governs *when* it re-dispatches)
- `manual` — `needs-human-review` with none of those markers → **still paused**

A genuine escalation takes **precedence** over a co-present rate-limit marker, so
budget-exhaustion / churn-breaker-cap holds keep pausing everything exactly as before (#1550
AC#3): the exemption keys on the marker set, it does **not** weaken the hold semantics
generally (§7 rules 2, 6 are preserved for every genuine escalation). For every held PR it
skips, the sweep **logs which hold it honored**, so a stranded PR is diagnosable from a single
sweep run (#1550 AC#5). Regression coverage:
`tests/test_sweep_stuck_reviews.bats` (rate-limit-only recovers; budget / cycle-cap holds do
not) and `tests/test_pr_automation_budget.bats` (`pr_hold_kind` classification).

---

## 7. The #860 normative rules

The PR #860 runaway (378 commits / 1,582 comments over four days, entirely agent-on-agent,
no human in the thread) is the empirical basis for this standard. Its learnings are lifted
**verbatim** from `docs/postmortems/2026-06-pr-860-runaway.md` "Learnings" and are
**normative rules** of this model — a design that violates one is non-compliant:

1. **An agent must never be triggered by its own output.**
2. **A safety cap whose reset is reachable by the runaway is not a cap** — resets must be
   human-gated.
3. **Bound the work item (the PR), not just each worker script.**
4. **Count actions, not just failures** — success can loop too.
5. **A new SHA is not new intent** — SHA-keyed idempotency can't break a fixup loop.
6. **Re-trigger crons amplify runaways** — they must check a stop condition before
   re-dispatching.
7. **No human noticed for four days** — detection must be pushed, not pulled.

Mapping to the rest of this model: rule 1 is the Class 1 self-trigger prohibition (§2);
rule 6 is the timer stop-condition (§6.2.1); rules 2–4 are why the cost bound in §9 is a
per-PR, since-last-human, action-counting budget rather than a failure counter; rule 7 is
why runaway detection must be a pushed signal (§9).

---

## 8. The per-role interaction-contract schema (decision for Story 2)

Story 2 (#1404) makes each role's interaction pattern a **declared, machine-readable
contract** instead of prose spread across workflow comments. This section fixes the schema
(fields + file location) that Story 2 implements; Story 4's validator (#1406) enforces it.

### 8.1 Fields

A per-role interaction contract declares:

```yaml
interaction:
  triggers:
    events:            # Class 1 webhook subscriptions this role reacts to
      - pull_request_review        # each an on: event this role's workflow subscribes to
    timers:            # Class 2/3 schedules; empty for a pure Class 1 role
      - cron: "23 */6 * * *"
        role: safety-net           # timer_role: backstop | safety-net | self-heal
        justification: "reconciles a dropped issues:closed event"
        stop_condition: "epic still open and not initiative:hold"
        event_fast_path: "issues:[closed, labeled]"   # the Class 1 path this backstops; null ⇒ Class 3
  emits:               # events/markers this role produces — used to prove it never
                       # subscribes to its own output (#860 rule 1)
    - "label:dev-lead"
    - "comment-marker:<!-- pr-automation-budget exhausted -->"
  idempotency_key: "pr_number + head_sha"   # what makes a re-run a no-op
  concurrency_lane: "dev-lead-${{ pr }}"    # the serialization lane
  stop_markers:        # human-gate markers this role MUST skip (§6.2.3)
    - needs-human-review
    - dev-lead:needs-human
  budget: pr-automation-budget              # the ceiling this role obeys (§9); no per-role number
```

The validator cross-checks `interaction.triggers.events` and `interaction.triggers.timers`
against the workflow's real `on:` block (the §3 discriminator), and cross-checks `emits`
against `triggers.events` to prove **no role subscribes to an event class it emits** (§7
rule 1). It also cross-checks `stop_markers` against what the serving side actually honours
(§8.1.1).

#### 8.1.1 `stop_markers` — the human brake must bind on every surface (#1745)

`stop_markers` is the human-gate contract (§6.2.3): the markers a role MUST skip when a
human has applied them. It is **CI-verified, not trusted** — `validate-interaction-model`
(§10) fails a persona contract that over- or under-claims what its serving surfaces honour:

- **Canonical human brakes must be declared.** Every `kind: persona` contract must list the
  universal brake `needs-human-review` — the label `pr_has_escalation_label`
  (`scripts/lib/pr-automation-budget.sh`) checks on the event-driven surface. The mention
  router now reads a persona's `stop_markers` straight from this contract
  (petry-projects/.github#1133), so a persona that omits the brake is **routed on a mention
  even after a human applies it** — the fail-open asymmetry #1745 fixes. The validator
  derives the marker from the serving script, never re-listing it as a literal (#1745 AC #2).
- **A declared marker must be honoured somewhere.** The honoured set for a persona is its own
  `opt_out_label` (from `persona.yml`, checked by the router's opt-out path) plus the
  canonical escalation markers (`needs-human-review`, `dev-lead:needs-human`). A `stop_markers`
  entry outside that set is a contract over-declaring a brake no serving workflow checks — the
  mirror of the over-declared *surfaces* tracked in #1647 — and fails the check.

**Per-surface truth.** `stop_markers` is a persona-wide list, so a label marker must be true for
**every label-capable serving surface that can perform write-mode actions** — the surfaces that can
actually read a label and gate a write on it. If a marker is ever only honoured on some of those
surfaces, it must not sit in the persona-wide list unqualified — a persona-wide list that is only
true for some surfaces is exactly the defect #1745 records. Add a per-surface note (a YAML comment
naming the surface and the reason) rather than leaving the asymmetry implicit. Surfaces that cannot
evaluate labels at all (see discussions below) are out of scope for this rule and are handled
separately by the router's fail-closed refusal.

**Discussions have no labels API (#1318, petry-projects/.github#755 residual).** The
discussion surface exposes no labels, so label-based `stop_markers` **cannot be evaluated
there** at all. The deployed router states this behaviour deliberately rather than leaving it
implicit: on a discussion it **routes in read/advisory mode** (where there is no write to gate)
and **refuses a write-mode action** because the human brake cannot be verified — fail-closed on
the surface where the gate is unknowable. This is consistent with #1647's record that
discussions currently produce no advisory at all. `stop_markers` therefore needs no
discussion-specific entry: the surface is handled by the router's refusal, not by a label.

### 8.2 File location — decision: **standalone repo-local contract, not `persona.yml` (yet)**

Two options were considered:

- **(a) Extend `persona.yml`** with an `interaction:` block. Attractive (one manifest per
  role) but **blocked cross-repo**: `personas/validate-personas.py` validates every
  `persona.yml` against `persona.schema.json` fetched from **`petry-projects/.github`**
  (`standards/personas/persona.schema.json`). Adding an `interaction` block to `persona.yml`
  requires that **external schema to permit the fields first** — otherwise validation fails
  the moment the field appears. That is a cross-repo change on another repo's release
  cadence (the same "land the schema/producer first" sequencing as the #860 org-first fix
  and the caller-stub input-forwarding rule).

- **(b) A standalone repo-local contract file** co-located with the role (e.g.
  `personas/<id>/interaction.yml`, or an `interaction-contract.yml` keyed by workflow path).
  No dependency on the external schema; Story 2 can land and Story 4 can enforce entirely
  within this repo.

**Decision:** Story 2 implements **option (b)** — a standalone repo-local contract file.
Rationale: it unblocks Stories 2 and 4 immediately with no cross-repo prerequisite, keeps
the validator hermetic, and matches this document's "repo-local first" posture.

**Cross-repo implication to sequence (Story 2 / epic `untracked_prerequisites`):** promoting
the contract into `persona.yml` later is the eventual home, but it is **gated on**
`petry-projects/.github` extending `persona.schema.json` to allow the `interaction` block.
Sequence, in order: (1) land the `interaction` object in the org `persona.schema.json`; (2)
release it on the schema's consumed ref; (3) only then move the contract into `persona.yml`
and delete the standalone file. Doing (3) first breaks `validate-personas.py` for every
persona — the mirror of the caller-stub skew rule.

---

## 9. The cost / run-count bound

**This standard introduces no new count-based circuit breakers.** The #860 learnings (§7
rules 2–4) show that adding numeric caps mostly adds *defeatable* guards: a cap whose reset
is reachable by the runaway is not a cap, and a failure counter never sees a success loop.
More numbers would be more false comfort.

The ceiling is therefore the **existing** two controls, and they remain authoritative:

1. **The per-PR automation budget** — `MAX_PR_AUTOMATION_CYCLES=10` in
   `scripts/lib/pr-automation-budget.sh`. It counts agent-authored commits + review cycles +
   acks **since the last human interaction** (action-counting, not failure-counting; per-PR,
   not per-worker — §7 rules 3, 4). On exhaustion it stops all automated writes, adds
   `needs-human-review`, disables auto-merge, and posts one deduped escalation. Re-engagement
   is **human-gated** (§7 rule 2); `FORCE_REVIEW` does not bypass it.
2. **The runaway detector** — the pushed detection signal in
   `daily-pr-review-health` / `scripts/fleet_monitor.sh` that flags open PRs over soft
   thresholds (commit/comment/cycle counts, or open >48h with active agent churn), so a
   runaway is surfaced rather than waited-on (§7 rule 7).

**Rule.** A new agentic role or timer must obey these two ceilings and declare which via its
contract's `budget` field (§8.1). It must **not** invent its own numeric cap as a substitute
— correctness comes from event-first design, stop conditions, and human-gated resets, not
from a bigger pile of counters.

---

## 10. How this document is enforced

This document is **CI-verified, not review-verified.** The enforcing check is
`validate-interaction-model` (Story 4 / #1406). It is what makes the §4 classification table
load-bearing rather than decorative — a contributor who changes a workflow's triggers must
update the table (and the role's §8 contract) in the same PR, or CI fails.

`validate-interaction-model` verifies:

- **Classification rows vs. real `on:` blocks.** Every row of the §4 table is parsed (fixed
  columns: `Workflow (path) | Class | timer_role | Justification`) and its asserted `Class`
  is checked against that workflow's actual `on:` triggers via the §3 discriminator. A row
  whose class no longer matches the workflow fails.
- **Completeness (bidirectional).** Every `.github/workflows/*.yml` file not in the §4
  exclusion list must be classified. A regular single-role workflow must have **exactly one**
  row; a collapsed `agent-ingress.yml` must have **one row per role-job** — the set of its rows'
  job qualifiers must equal the file's set of `jobs:` names, so an ingress with N role-jobs but
  fewer than N rows (an under-documented job) fails, and a row naming a job the file no longer
  defines fails as a stale row. A workflow absent from both the §4 table and the §4 exclusion
  list fails the check. This prevents a new agentic role — or a newly collapsed ingress
  role-job — from being added with no classification row; the enforcement is bidirectional, not
  row-to-reality only. The matching AC for #1406: *every in-scope role is classified by exactly
  one row (per file, or per role-job for an ingress); any in-scope role with no row fails CI*.
- **Per-role contracts vs. workflows** (once Story 2 lands): each contract's
  `triggers.events` / `triggers.timers` match the workflow's `on:` block, `emits` does not
  intersect subscribed `events` (§7 rule 1), and every Class 2 timer declares a
  `timer_role` + `stop_condition` (§6).
- **`stop_markers` vs. the serving side** (§8.1.1, #1745). Every `kind: persona` contract
  must declare the canonical human brake `needs-human-review`, and every declared marker must
  be one a serving surface honours (the persona's `opt_out_label` plus the canonical
  escalation markers). A persona that omits the brake, or over-declares a marker no workflow
  checks, fails — so a human hold binds on every surface and the contract cannot drift from
  what is deployed.

The table's exact shape is fixed **here** (this document is the normative source); #1406
consumes it. If the shape must change, it changes here first and #1406's fixtures change with
it — never the reverse.

---

## 11. Narrowing the Class-2 backstop timers — stall detector, rollback trigger, monitoring window

The Class-2 backstop timers that reconcile un-eventable transitions — `pr-review-sweep.yml`
(§4, `backstop`) and `dev-lead-retry.yml` (§4, `self-heal`, the §6.3 leak) — are slated to be
**narrowed** (#1407 / #1408) to cut the redundant fan-out they produce. Narrowing a safety net
is exactly the pattern the #860 post-mortem warns against: it can trade a *known, noisy* failure
mode (over-firing) for an *unknown, silent* one (a genuinely un-eventable transition that no fast
path re-fires and, once the cron is narrowed, nothing sweeps). #1410 therefore builds the
instrument **before** the net is narrowed, and defines the rollback path here so the decision is
explicit, not tribal.

### 11.1 The stall detector (the instrument)

`scripts/lib/pr-stall-detect.sh` is a **detect-only** pure lib (mirroring
`scripts/lib/pr-runaway-detect.sh`, §9 rule 2) — it never labels, comments, or halts. It flags an
open PR that is **CI-green + `REVIEW_REQUIRED`, not reviewed at head, with no agent activity and no
pending triggering event, idle longer than `STALL_MIN_AGE_MINUTES` (default 30 min — double the
sweep's nominal ≤15-min backstop cadence, which GitHub does not guarantee; **#1408 must re-derive this default when the sweep cadence
is narrowed** so it remains ≥ 2× the new backstop interval)**. It is **fail-quiet on intentional stops**: a PR carrying
`needs-human-review` (checked via `pr_has_escalation_label`, §6.2.3), `dev-lead:hands-off`, or
`initiative:hold` (checked via a `STALL_HOLD_LABELS` loop) is never reported. The
`<!-- pr-automation-budget exhausted -->` marker is **not inspected directly** — it is excluded
only because budget exhaustion simultaneously applies `needs-human-review`; the marker alone does
not gate stall detection, preserving re-engagement for PRs that have the marker but no hold label. `scripts/pr_stall_scan.sh` runs it over every open PR as an
**additive step on the existing `daily-pr-review-health.yml`** and surfaces any candidate through
the same health-check / automated-report issue channel — **no new scheduled workload** (§1: this
adds a pushed signal and a documented human decision, not another automated brake). This is the
push detection §7 rule 7 requires: the un-eventable green transition the narrowed cron would drop
is caught here and **still resolves** (surfaced → human/backstop acts) instead of stalling unseen.

### 11.2 The rollback trigger (the condition)

**Trigger condition.** Roll back the narrowing if the stall detector reports **≥ 2 distinct
stalled PRs within any rolling 24-hour window**, *or* **any single PR stalled for ≥ 4 hours** (≈8×
the default threshold), during the monitoring window (§11.4). Either signal means the narrowed
timer let a genuinely un-eventable transition sit unresolved — the silent failure mode the
narrowing risked. A stall that is later explained by a human-gate marker does **not** count (it is
excluded by design and never reported). One transient single-PR stall under the 4-hour bar is a
watch item, not a revert.

Both thresholds are deliberately low: the cost of a false rollback is a return to the *known* noisy
state (fully recoverable), while the cost of tolerating a silent stall is the #860 blindness. When
in doubt, revert.

### 11.3 The revert procedure (the exact steps)

The narrowing lands as one or more PRs that edit the `schedule.cron` (and/or the `workflow_run`
scoping) of `pr-review-sweep.yml` / `dev-lead-retry.yml`. To revert:

1. **Identify** the merged narrowing PR(s) for #1407 / #1408 (labelled against those issues).
2. **Revert** them — `git revert <merge-sha>` for each, in reverse merge order — restoring
   `pr-review-sweep.yml`'s backstop cadence (`schedule: '2,17,32,47 * * * *'`, nominally ≤15 min)
   and `dev-lead-retry.yml`'s `schedule: '15 */2 * * *'`. Do **not** hand-edit the cron to a
   guessed value; restore the exact pre-narrowing lines from history so the backstop returns to its
   proven state.
3. **Open the revert PR** referencing the triggering stall issue(s), and confirm CI green +
   `validate-workflow-schedules` passing (the restored crons are non-minute-0, AGENTS.md
   "Scheduled workflows").
4. **Verify recovery**: after merge, confirm the previously-stalled PR(s) get re-reviewed on the
   next backstop tick and the daily stall scan returns to all-clear.
5. **Record** the rollback as a comment on the epic (#1402) and this story (#1410) — the go/no-go
   audit trail this repo uses for every safety-net change (mirrors the fleet-remediation
   human-gate record in AGENTS.md). Reverting is the *expected*, low-cost response to the trigger,
   not an incident.

### 11.4 The monitoring window (how long, who checks)

**Window.** The narrowed timers run under observation for **14 days** after the narrowing merges
(≥14 daily stall-scan runs — a full two weeks covers weekday *and* weekend PR cadence, since some
un-eventable transitions only appear under low-traffic conditions). The change is considered
**settled** only after 14 consecutive days with **zero** rollback-trigger hits (§11.2).

**Who/what checks.** The **daily `daily-pr-review-health.yml` stall scan** is the automated watcher
— it is the pushed signal, so no human has to remember to look (the #860 anti-pattern). A stall
candidate opens a `health-check` / `automated-report` issue labelled for **dev-lead** attention,
which is the human checkpoint. During the 14-day window, treat any stall-candidate issue as a
rollback decision per §11.2 rather than a routine triage item. After the window settles, the stall
scan remains as a **permanent** detector (it is cheap and detect-only) — settling ends the
*heightened* watch, not the instrument.

---

## 12. §7 rule 2 applies to review and merge gates, not just automation budgets (#1415)

**Normative rule.** §7 rule 2 — *"a safety cap whose reset is reachable by the runaway is not a
cap; resets must be human-gated"* — is **not limited to numeric budgets and circuit breakers.** It
governs **every gate an agent's merge must pass**, including **review gates** and the **merge gate
itself**. Restated for this class:

> **A review or merge gate whose reset is reachable by the agent is not a gate.** If an agent can
> clear the very signal that is supposed to block its own PR — by resolving the blocking review
> thread, dismissing the blocking review, or otherwise satisfying the check itself — the gate holds
> only by the agent's goodwill, not by control. The reset must be reachable **only by a human**.

This is the review-path counterpart of two existing applications of the same rule: the per-PR
automation budget (§9), whose re-engagement is human-gated; and the timer stop-condition (§6.2.4),
which forbids a timer from re-arming a runaway. The maintainer **issue-comment** gate (#1290) and
the maintainer **review-thread** gate (#1415) are the same rule applied to the two ways a
maintainer finding reaches a PR.

### 12.1 Why the shared-identity case makes this acute

On a **dev-lead-authored PR**, dev-lead commits, reviews, and resolves as the owner account
`don-petry` (AGENTS.md "Agent identity & credential secrets"; #1316 set this deliberately — dev-lead
acts as the owner, `pr-review` as the machine user `donpetry-bot`). That shared identity removes
**both** of the owner's mechanically-blocking review paths:

1. GitHub refuses `CHANGES_REQUESTED` on your own PR ("Can not request changes on your own pull
   request"), so the ergonomic blocking review is unavailable to the owner.
2. The inline-review-thread fallback (`required_review_thread_resolution`) is defeated because the
   agent, running as `don-petry`, can **resolve the maintainer's own threads** — observed on PR
   #1413, where four maintainer threads ended `resolvedBy: don-petry` and auto-merge proceeded.

Because **login cannot separate the agent from the maintainer** in this case, the discriminator is
the **automation marker** in a thread's originating comment (`<!-- pr-review-agent … -->`,
`<!-- persona:… -->`, `<!-- dev-lead … -->`, `<!-- dependency-advisory -->`), exactly as the
issue-comment gate discriminates. The rule is enforced by two **coupled** halves — a resolve-guard
that stops the agent clearing a marker-less (maintainer) thread, and an approval gate that withholds
pr-review's approval while an unresolved maintainer thread postdates the last push. The gate can
safely treat *resolution* as a human clear **only because** the guard makes resolution unreachable by
the agent. See `docs/pr-review-agent/maintainer-comment-gate.md` ("The review-thread sibling") and
`scripts/lib/maintainer-review-thread-gate.sh`.

### 12.2 Decision: keep the shared identity + add the gate — the distinct-identity alternative is rejected (AC #7)

Two ways to close the #1413 gap were evaluated:

- **(a) Give dev-lead a distinct commit/PR identity** (e.g. its own `dev-lead-bot` account) so a PR
  it authors is authored by a *different* account than the owner. GitHub would then permit the owner
  to `CHANGES_REQUESTED` it, and login alone would separate the agent's thread resolutions from the
  maintainer's — no marker discriminator needed.
- **(b) Keep the shared `don-petry` identity and add the marker-keyed gate + resolve-guard** (this
  implementation).

**Decision: option (b).** Option (a) **reverses the deliberate #1316 choice** (dev-lead acts as the
owner `don-petry`; `pr-review` acts as `donpetry-bot`) and carries consequences that are out of scope
for a gate-integrity fix and are not clearly net-positive:

- **CODEOWNERS.** dev-lead PRs are authored-as-owner today; a distinct bot identity would need to be
  added to CODEOWNERS / review-requirement rulesets to retain the same approval semantics, and would
  change who is requested for review across the fleet.
- **PAT / credential surface.** A new account means a new PAT secret
  (`GH_PAT_<ACCOUNT>` per AGENTS.md), new `runtime.identity` manifest wiring, and a new machine user
  to provision, secure, and rotate — widening the credential surface the #1316 model deliberately
  kept to two accounts.
- **Persona-manifest / identity-resolution.** `runtime.identity.account`, `resolve-persona-identity.sh`,
  and the `verify-persona-identity` lint job all encode the current account mapping; a re-identity is a
  cross-cutting change to that machinery, not a localized fix.
- **It does not generalize.** Even with distinct identities, the *dependency-advisory* pass and other
  automation still post **as `don-petry`**, so login-based discrimination would remain insufficient on
  the issue-comment path (#1290) — the marker discriminator is needed regardless. Option (b) reuses one
  mechanism for both paths; option (a) would still need the marker for #1290 while adding an identity
  migration for #1415.

The marker-keyed gate closes the gap **without** touching the identity model, reuses the proven #1290
shape, and keeps a single discriminator across both the comment and review paths. If a distinct
dev-lead identity is later adopted for *other* reasons, this gate remains correct (a marker-less
maintainer thread is still a maintainer finding) and the login signal simply becomes a redundant
confirmation — so option (b) does not foreclose option (a).

---

## 13. The check-vs-intent failure mode — "the agent optimizes the check, not the intent" (#1468)

**Definition.** A red check exists to protect something — an invariant, a contract, a behavior. The
**check-vs-intent failure mode** is when an agent drives that check green *by changing what the check
measures* (or by satisfying the check's literal assertion) rather than by making the thing the check
protects actually true. CI (or a purpose-built guard) goes green, but only because what the check
*measures* was changed, or the diff optimized for "check passes" instead of "the thing the check
protects is true." It is the review-time sibling of §7 rule 5 (*"a new SHA is not new intent"*): there,
a fixup loop satisfies SHA-keyed idempotency without new intent; here, a diff satisfies a check's
assertion without serving the check's intent.

Give it a name so future incidents get **filed against it** instead of being independently
re-discovered each time a purpose-built guard happens to catch one.

### 13.1 Worked instances (the empirical basis)

Across epic #1402's session the same shape surfaced five times — four caught only by a
purpose-built guard rather than by review, and one (instance 5) caught only by a manual diff
review after the check itself had passed:

1. **Vendored a tool that was already installed (#1449, 2026-08-06).** `bats` failed on
   `node_modules/ is not tracked by git` (#1451's guard). dev-lead vendored `node_modules/bats/` (the
   33-file npm package) in response to bot feedback — even though `lint.yml` already installs bats via
   `apt-get install -y bats` (the documented convention since #1455). The fix satisfied "bats needs to
   be available" without noticing it already was. (This is the instance whose mechanical guard is
   delivered separately in #1541.)
2. **Edited a distribution artifact to silence a symptom (#1435).** `repo-template` stubs were edited
   directly to satisfy a Fleet Monitor check that was actually about a *different* file. `repo-template`
   is a **byte-identity distribution artifact** of `standards/`; editing it treats the symptom (a red
   Fleet Monitor check) instead of the cause (the source-of-truth file in `standards/`). The check the
   diff optimized for was "Fleet Monitor is green," not "the canonical source is correct."
3. **Posted a completion claim as the "check" (#1407, #1445).** An "Implementation Complete" claim was
   published before the work was durable and never retracted on timeout. The check being satisfied was
   "did I post a completion comment," not "did the work land on `main`." (This is why Phase 6 of the
   dev-lead prompts is now explicitly *provisional / pre-push* — the durable record is the automation's
   post-push comment referencing a PR number + head SHA.)
4. **Rewrote a guardrail to satisfy the wrong reader — the positive counter-example (#1450/#1451).** A
   guardrail was rewritten to satisfy a linter that should never have been reading the content it
   flagged (the markdownlint-vs-`node_modules` incident). This one is the **counter-example**: the
   eventual fix (#1451) correctly **generalized the ignore list** rather than silencing the single
   flagged file — it served the check's intent (markdownlint should not lint vendored content at all)
   instead of optimizing the one assertion. Serving the intent, not the assertion, is the target
   behavior.
5. **A "deleted" guardrail that was actually rewritten.** A guard reported as deleted was, on
   inspection, a *rewritten* one. The check ("does the guard still exist") passed, but a **diff review**
   was needed to confirm it still *meant* the same thing. Existence is not equivalence.

### 13.2 The tell, and how to resist it

The tell is the same in every instance: the diff makes the check green by touching **what the check
measures** — its threshold, its fixture, its expected output, the assertion itself, or the artifact the
check reads — rather than the root cause the check protects. When the only way you can make a check
green is to change what it asserts, **stop**: fix the root cause, or leave the check red and say why.

### 13.3 Advisory, not a merge gate (AC #4)

**This is a review-quality signal, not a CI-enforceable invariant in the general case.** The five
instances are heterogeneous — no single mechanical rule catches "diff satisfies the check's assertion
but not its intent," and building a general detector is out of scope (and not mechanically decidable).
Do **not** add a merge gate that purports to enforce this in general. The enforcement here is two narrow
**slivers**, and the rest is carried by this named definition and by review:

- **The `review-changes` fix-comment requirement** — when dev-lead fixes a failing check, its posted
  fix comment must state **what the failing check verifies** and **why the diff makes that true** (not
  just "check now passes"), giving a reviewer or `pr-review` a concrete claim to spot-check. See
  `prompts/dev-lead/review-changes.md` ("Reporting a failing-check fix").
- **The vendored-tool guard (#1541)** — the one mechanically-checkable instance (bats vendored despite
  the apt-install convention) gets a bats guard, tracked and delivered under #1541.

Everything else is advisory: a named shape reviewers (human or `pr-review`) look for, filed against this
section rather than re-discovered.
