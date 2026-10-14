# AGENTS.md — .github-private

This repository follows the organization-wide development standards defined in
[`combsmith/.github/AGENTS.md`](https://github.com/combsmith/.github/blob/main/AGENTS.md).
Read that file before making changes that touch CI, agent configuration, repo settings, or labels.

---

## Repository Context

This is the `.github-private` org infrastructure repo for `combsmith`. It contains:

- **`agents/`** — Copilot custom agent profiles (org-wide, invocable from GitHub.com, VS Code, JetBrains)
- **`frameworks/`** — Agentic frameworks installed via `git subtree` (bmad-method, spec-kit, gsd)
- **`scripts/`** — Shell orchestration for GitHub Actions
- **`.github/workflows/`** — Scheduled automation (PR review, health checks)

## Operating the fleet — delivery rules learned from epic #1643

These are hard-won rules for **driving delivery** in this repo, recorded so each session stops
re-deriving them by hitting the same walls. Every one cost real time or a stranded PR during the
qa-lead epic (#1643, 2026-09-13 → 2026-09-21). They complement — and cross-link, rather than
duplicate — the deeper standards in the sections below and in `docs/`.

### Merging to `main` does not activate agent code — say when it will reach each channel

**This is the single most expensive omission on this list — do not skip it.** Agents run their
scripts from a **channel tag**, not from `main`. `pr-review-trigger.yml` pins
`@pr-review/v1-next`; `persona-mention.yml` pins `@persona-mention/v1-next`; each caller stub pins
its reusable at a moving channel tag, never at `main`. A fix merged to `main` is **inert** until a
channel tag moves onto the commit. This bit twice in one week: #1795's CI-gate fix (merged, yet
still deadlocking every PR until `pr-review/v1.10.0` was cut) and #1875's approval read-back
(merged, yet still announcing phantom approvals until the channel caught up to the new commit).

**You normally do not cut that release yourself.** The Release Manager automation (see
["Release automation — who cuts and moves tags"](#release-automation--who-cuts-and-moves-tags))
**auto-cuts** a new `<agent>/vX.Y.Z` and moves `<agent>/v<MAJOR>-next` on its next 4-hourly sweep
once the change is on `main`. **Every ring beyond `next` moves only by gated promotion.** So the
lag is real but bounded: usually a few hours to reach `next`, and longer to reach `stable`.

**Rule: after merging any change under `scripts/`, `prompts/`, `personas/` or a `*-reusable.yml`,
state which channel(s) must carry it and when.** The normal answer is "rides the next autocut to
`<agent>/v<M>-next`; reaches `stable` via ring promotion". Hand-run `scripts/cut-release.sh` only
for the exceptions listed in that section. See
["Release channel tags & the mutable-ref exception"](#release-channel-tags--the-mutable-ref-exception)
for the tag model and `docs/release/versioning.md` for the scheme.

### Verify by execution, never by run status or diff

Agents report success for work they did not do. dev-lead once reported `completed/success` on a
rebase while pushing **zero commits** (it had silently deferred at the automation-PR cap below);
pr-review posted "approved on PARTIAL advisory evidence" on #1788 / #1858 / #1860 where the reviews
API held **no review object at all**. **Rule: confirm the artifact — a new head SHA, a review
object, a changed file — not the run conclusion.** Check out the branch and run the suite; run the
counterfactual to prove a new validator actually fails when it should. This is the delivery-time
face of the check-vs-intent failure mode ([`docs/agentic-interaction-model.md` §13](./docs/agentic-interaction-model.md#13-the-check-vs-intent-failure-mode--the-agent-optimizes-the-check-not-the-intent-1468))
and is why dev-lead's own completion record is **post-push only** (Phase 6 of the dev-lead prompts
is deliberately provisional, keyed to a pushed PR number + head SHA).

### Required vs non-required checks

This repo gates `main` with a **ruleset**, not classic branch protection — so
`GET /repos/<owner>/<repo>/branches/<branch>/protection` **404s**; read the required contexts from
`GET /repos/<owner>/<repo>/rules/branches/<branch>` instead. The required set is exactly:
**SonarCloud, CodeQL, `agent-shield / AgentShield`, `dependency-audit / Detect ecosystems`,
`duplicate-decl-gate`**. `template-drift` and superseded `dev-lead / *` jobs fail routinely and
**do not block merge**. `compute_ci_status` (`scripts/lib/ci-status.sh`, #1795) already gates only
on the ruleset's required contexts (unioned with any rollup entry whose `.isRequired == true`), so
a red **non-required** check must never be read as `ci-failing`.

### `needs-human-review` means different things to different agents

The pr-review sweep and dev-lead's hold-gate read the same label differently: the sweep classifies a
rate-limit-only hold as exempt and keeps retrying (#1550), while dev-lead's hold-gate stops
**unconditionally** and posts a hold notice. So a transient bot-applied hold silently disables
dev-lead on a PR indefinitely while pr-review keeps working. **Rule: check provenance before
clearing.** `github-actions[bot]` or `donpetry-bot` shortly after creation is automated (an
artifact — safe to clear); a human account within seconds is deliberate and must be left alone.
`pr_hold_kind` (in `scripts/lib/pr-automation-budget.sh`) is the pure classifier, and it returns
exactly four kinds: **budget-exhaustion** (a real limiter — leave it), **cycle-cap** (a genuine
review-cycle escalation — leave it), **rate-limit-only** (the *only* auto-clearable artifact — safe
to clear), and **manual** (held with none of those markers). Only **rate-limit-only** is
auto-clearable; **budget-exhaustion** and **cycle-cap** remain blocked.
A failed-review hold carries no automation marker, so it classifies as **manual** — the same bucket
as a deliberate human `/hold`, and an undeterminable hold degrades to it fail-closed — so **leave it
alone**. Never treat "failed review" as auto-clearable: only `rate-limit-only` is. The hold-kind
taxonomy and the rate-limit-only exemption are specified in
[`docs/agentic-interaction-model.md` §6.2.3 / §6.4](./docs/agentic-interaction-model.md#64-the-rate-limit-only-exemption-to-623-1550).

### Steering dev-lead

dev-lead reads **only the issue title and body** — comments never reach the prompt (`ISSUE_TITLE` /
`ISSUE_BODY` are its only issue inputs; see `prompts/dev-lead/fix-issue.md`). An issue steered by
comment sits idle. To re-steer: **amend the body**, then re-dispatch with
`gh api -X POST repos/<owner>/<repo>/dispatches -f event_type=dev-lead-issue-retry -F 'client_payload[issue_number]=<issue_number>'`
(the `dev-lead` label is the first dispatch). **Always include a budget guard** in a multi-part
body: sequence the commits, say which one matters most, and give explicit permission to stop and
file a follow-up. #1734 timed out attempting two ACs and lost the work; #1647, #1651 and #1795
succeeded with a guard.

### Satisfying the maintainer-comment gate without dev-lead (#1910)

`maintainer-comment-gate.sh` withholds pr-review's approval while any non-agent PR issue comment
lacks a verified disposition — surfaced server-side as the comment being **minimized with classifier
`RESOLVED`**. Normally the *only* actor that performs that minimize is dev-lead, so a comment on a PR
where dev-lead is **suppressed, rate-limited, cancelled, or never dispatched** stays a permanent
blocker and no approval can stand. To unblock it yourself, once you have verified your own finding is
addressed, run `scripts/maintainer-resolve-comment.sh <comment-url-or-node-id>` (see its `--help`). It
minimizes **your own** comment `RESOLVED` — the exact signal the gate already honours, so the
`RESOLVED`-minimized requirement is preserved, not weakened. It acts only on a comment you authored
(a finding you did not author still requires dev-lead's verified-fix flow or the other person's own
action), is idempotent, and fails closed if it cannot confirm the comment's author or the invoking
viewer. An `@mention` (FORCE_REVIEW) is the alternative human-in-the-loop bypass.

### Bot status comments never deadlock approval, and the maintainer escape hatch for them (#1918)

The comments that actually strand the #1894 queue are posted by **bots** — chiefly SonarCloud's
`Quality Gate passed` status comment, which SonarCloud **re-posts on every push**, so dispositioning
the old one never helps. #1910's self-scope (above) meant a maintainer could not clear a bot's comment
at all (this was the deadlock reported in #1911). Two changes close this:

- **A clean bot status comment is auto-cleared, deterministically, with no LLM and no dev-lead.**
  `maintainer-comment-gate.sh` reads a data-driven classifier keyed off the reviewer-source registry
  (`scripts/lib/reviewer-sources.tsv`, new `info_status_pattern` column). A comment authored by a
  registered source whose body matches that source's pattern is treated as **addressed** and never
  blocks. For `sonarqubecloud` the pattern pins the `**Quality Gate passed**` headline **and** the
  `[0 New issues]` and `[0 Security Hotspots]` lines. A gate can pass while still reporting new issues
  or hotspots, and those are findings, so the headline alone never clears a comment. The patterns live in **data,
  not hard-coded logins** in the gate (`reviewer_sources_info_status_patterns`). It stays **fail
  closed**: a `Quality Gate failed` comment does not match and still blocks, as does any bot comment
  carrying findings, any comment from a bot with no pattern, and every human comment. An unreadable
  registry degrades to `{}` — i.e. **nothing is auto-cleared** — never to clearing something it cannot
  classify.
- **Maintainers can clear a *registered info-status bot's* comment when needed.**
  `scripts/maintainer-resolve-comment.sh` accepts a comment authored by a bot that declares an
  `info_status_pattern` in `reviewer-sources.tsv` — a clean-status re-poster like `sonarqubecloud`,
  **not** a finding-producing reviewer such as `codeant-ai` or `graphite-app` (whose findings still
  require dev-lead's verified-fix flow, so this path cannot `--reason` them away) — in addition to
  your own. The author must be a GitHub App actor (`__typename == Bot`), so a *person* whose login
  matches a registered bot's is refused like any other human. This path **requires `--reason`**, which
  is posted as a reply carrying a `<!-- maintainer-resolve … -->` marker (pinned to the original
  comment's node id, so the reply is not itself a new blocker and a retry does not post a duplicate)
  **before** the original is minimized `RESOLVED`. It **still refuses another *human's* comment** —
  that restriction is exactly why #1910 was self-scoped — and fails closed if it cannot read the
  registry, the comment's author, or the invoking viewer.
- **A notice never clears findings, and edits re-open a bot's comment (#2008).** CodeRabbit puts
  outputs that are throttled independently into ONE summary comment and edits it in place. A
  rate-limit block can sit beside a Security Architecture Review that reports real findings.
  - No `info_status_pattern`, maintainer-resolve bot path, or `informational` disposition clears a body
    with a finding-bearing section (`reviewer_sources_finding_section_pattern`).
  - A `RESOLVED` registered-bot comment edited after its latest covering disposition blocks again.
    Its `lastEditedAt` is compared with the disposition's `createdAt`, and an unreadable edit time
    fails closed. The comment stays blocked until a fresh disposition covers the current body. See
    `docs/pr-review-agent/maintainer-comment-gate.md`.

### The org automation-PR cap is real and near-silent

There is a hard ceiling of **50 concurrent open non-Dependabot automation PRs org-wide**
(`combsmith/.github` `standards/pr-limits.json`). At the cap dev-lead posts a
`dev-lead-issue-deferred` marker and opens **nothing** — yet the run still reports success (the same
"success while doing nothing" trap as the verify-by-execution rule above). Freeing slots and
re-dispatching works immediately.

### The recurring defect class: a failure read as "nothing to do"

Four separate instances in one week: a non-required red check became `ci-failing`; an empty brake
derivation **skipped** the brake check; a failed approval write announced success; an unreadable
managed file was overwritten (#1812 / PR #1868). **Rule: when an input cannot be resolved, fail
loudly and name which derivation failed — never let "cannot check" silently become "nothing to
check."** Fail **closed** on gates; fail **open** (with a `::warning::`) only on genuinely
indeterminate liveness probes (#1776, e.g. `scripts/persona-authz-preflight.sh`). This is the mirror
of the check-vs-intent failure mode ([`docs/agentic-interaction-model.md` §13](./docs/agentic-interaction-model.md#13-the-check-vs-intent-failure-mode--the-agent-optimizes-the-check-not-the-intent-1468)).

### Local environment caveats

macOS ships **bash 3.2**: `mapfile`, `readarray` and `declare -A` all fail there, so scripts that
use them (e.g. `scripts/fleet_monitor.sh`) and several bats suites cannot run locally
(`tests/dev-lead/unit/test_fix_reviews.bats` fails ~103 tests on `main` for this reason alone).
System `python3` is 3.9 and too old for the eval scripts — use `python3.12` or a venv. In zsh,
`read -r path` clobbers `$PATH`. **Rule: when a local suite fails, diff it against `main` before
calling it a regression, and treat CI as authoritative.**

## Project-Specific Standards

### Workflow Files

- Do **not** modify `.github/workflows/agent-shield.yml` — this is exempted from agent modification per
  [`standards/agent-standards.md`](https://github.com/combsmith/.github/blob/main/standards/agent-standards.md).
- `.github/workflows/dev-lead.yml` is a thin caller stub that delegates to
  `dev-lead-reusable.yml` (the canonical org standard). To change behavior for
  all org repos, edit `dev-lead-reusable.yml`. Repo-specific trigger adjustments
  may be made to `dev-lead.yml` per the stub's header comment. When adding a `with:`
  forward to this (or any) channel-pinned caller stub, follow the input-change
  sequencing in "Release channel tags & the mutable-ref exception" →
  ["Caller-stub input forwarding across channel pins"](#caller-stub-input-forwarding-across-channel-pins):
  never forward an input the pinned channel does not yet declare.
- **dev-lead ingests the issue's human comments, not just its title/body (#1566).**
  `dev-lead-fix-issue.sh` fetches `issues/<n>/comments` and renders them into the
  `ISSUE_COMMENTS` prompt variable via the pure renderer `scripts/lib/issue-comments.sh`
  (tests: `tests/dev-lead/unit/test_issue_comments.bats`). The prompt template treats
  comments as **refinements that may supersede the body**, read in chronological order,
  with later **human** comments outranking the body and earlier comments. This is how a
  maintainer steers an in-flight issue: post a comment answering an open question or
  correcting a wrong assumption, and it reaches the engine. **Only comments from users with
  repository write access are surfaced** — the renderer keeps `author_association` of
  `OWNER`, `MEMBER`, or `COLLABORATOR` and drops everyone else (`CONTRIBUTOR`, `NONE`, …),
  so a drive-by outside commenter cannot redirect an implementation. **Also deliberately
  excluded from the rendered block:** `Bot`-type authors (CI bots, third-party reviewers)
  and dev-lead's own automation comments — any comment whose body *begins* with an
  `<!-- dev-lead…` HTML marker or a `## Dev-Lead …` plan/progress/completion heading is
  treated as automation and dropped (the match is anchored to the start of the body,
  regardless of author), so automation chatter never crowds out human steering. The block is
  **size-bounded** (`ISSUE_COMMENTS_MAX`, `ISSUE_COMMENTS_CHAR_BUDGET`) applied newest-first
  so the freshest steering always survives; the character budget is a **hard bound** — if
  the single newest comment alone exceeds it, that comment is **truncated** to the budget
  rather than emitted in full. Any comments dropped, and any truncation, are **counted and
  stated** in the block, never silently discarded.
- All other workflow changes must use templates from
  [`standards/workflows/`](https://github.com/combsmith/.github/tree/main/standards/workflows) verbatim.
- **Note:** `.github/workflows/auto-rebase.yml` pins the reusable workflow at the `@auto-rebase/v2-next`
  moving channel tag — the major-scoped dogfood channel this repo rides ahead of the canonical
  `@auto-rebase/v2-stable` org stub in `standards/workflows/auto-rebase.yml`. Do not
  repoint it to a frozen `@vX` tag, `@main`, or a SHA — `tests/dev-lead/integration/test_auto_rebase_stub.py`
  (#139) enforces this. The repo-specific `auto-rebase-retry.yml` and `auto-rebase-health.yml` workflows
  depend on the sentinel-trigger behavior provided by the current channel; downgrading to a pre-sentinel
  frozen tag is a behavioral regression. As a channel-pinned caller stub it is also subject to
  ["Caller-stub input forwarding across channel pins"](#caller-stub-input-forwarding-across-channel-pins):
  do not add a `with:` forward for an input the pinned channel does not yet declare.
- **Exception:** The `gh-aw-compile` job in `lint.yml` is a documented repo-specific addition that gates
  agentic workflow compilation. It is not covered by the org template and must not be removed by template
  syncs. If the org template gains a `gh-aw-compile` equivalent, remove this exception and defer to the
  template instead.
- **Exception:** the `lint.yml` `paths:` filters (pull_request and push) carry the repo-specific entry
  `docs/initiatives/agent-ingress-collapse-markets.md`, which is read by
  `tests/agent_ingress_markets_package.bats` (#2038). It must not be removed as template drift on a sync;
  without it, documentation-only edits to the package skip the suite that validates it.
- **Exception:** `token-report.yml` (weekly Token Cost Observatory report) is a documented repo-specific
  workflow with no corresponding org template in `standards/workflows/`. It must not be removed by template
  syncs. If the org template gains a token-report equivalent, remove this exception and defer to the
  template instead.
- **Exception:** `test-deletion-guard.yml` (#823) is a documented repo-specific workflow with no org template.
  It is one half of the #655 **stale-base / semantic-revert** guard: it fails a PR that deletes any file under
  `tests/` unless a maintainer adds the `ack-test-deletion` label, so a silent test removal becomes a deliberate,
  reviewable decision. Deletions are measured from the merge base of the PR, so a test file `main` gained after
  the branch point is not read as deleted by a PR that is behind (#2254; logic in `scripts/test-deletion-guard.sh`).
  The other half is the **"require branches up to date before merging"** ruleset on `main`
  (already enabled). Together they close the gap behind #655, where a PR merged from a stale base reverted a
  shipped fix and deleted its regression test in the same green-CI diff. Do not remove either guard.
  Because this is a **gate** workflow whose `failure` conclusion is intentional enforcement (it blocks a
  bad PR), it is exempt from the Fleet Monitor's high-failure issue tracking via `FLEET_GATE_WORKFLOWS`
  in `scripts/fleet_report.sh` (#941) — otherwise a guard doing its job produces false-positive trackers.
  `holdout-guard.yml` is exempt for the same reason. Add new gate workflows of this class to that list.
- **Exception:** `pr-review-sweep.yml` (stuck-review sweep, #573/#898) is a documented repo-specific
  workflow with no corresponding org template in `standards/workflows/`. It re-dispatches reviews for PRs
  that went green after a ci-pending/ci-failing skip, via two triggers: a scheduled cron (the EVENTUAL
  backstop — best-effort only, since GitHub drops crons under load, #1952) and a `workflow_run: completed`
  fast path (#898) that scopes the sweep to the completing CI run's PR(s) for near-instant re-review. It must
  not be removed by template syncs. If the org template gains an equivalent re-trigger sweep, remove this
  exception and defer to the template instead.
- **Exception:** `pr-review-delayed-retry.yml` (deterministic rate-limit retry, #1994) is a documented
  repo-specific workflow with no corresponding org template in `standards/workflows/`. It is a Class-1
  (`workflow_dispatch`-only) companion to `pr-review-sweep.yml`: when the sweep defers a PR on an un-elapsed
  rate-limit marker whose `reset` is within a bounded horizon, it arms this workflow, which sleeps until the
  reset, re-checks the marker still applies at the same head, then re-dispatches through the sweep — so a
  rate-limited review retries within minutes of its reset instead of waiting for the best-effort cron. Its
  in-run sleep is an armed delay, not an `on: schedule` timer, so it is Class 1 by declaration. It must not be
  removed by template syncs. If the org template gains an equivalent, remove this exception and defer to it.
- **Exception:** `readme-refresh.yml` (weekly org README refresh) is a documented repo-specific workflow
  with no corresponding org template in `standards/workflows/`. It regenerates the four org "meta-repo"
  READMEs (public + member-only org profiles, and the `.github` / `.github-private` repo landing pages)
  from live org state via `scripts/aw-readme-refresh.sh` + `prompts/aw/readme-refresh.md`, then opens or
  updates one rolling PR (`chore/readme-refresh`, label `readme-refresh`) per repo for human review. It
  never direct-pushes. It must not be removed by template syncs. If the org template gains an equivalent,
  remove this exception and defer to the template instead.
- **Exception:** The `pull_request`/`push` `paths:` filters in `lint.yml` are extended with `prompts/**`
  beyond the org template baseline (#1919). The dev-lead prompt files under `prompts/dev-lead/` are now
  guarded by bats tests in the lint suite (e.g. `tests/dev-lead/unit/test_agent_marker_convention.bats`),
  so a prompt-only change must trigger this workflow or the guard never runs and the CI gap it closes
  silently reopens. Template syncs must not drop `prompts/**` from these path filters. If the org template
  adds `prompts/**` to its baseline, remove this exception and defer to the template instead.
- **Exception:** The `bats` test list in `lint.yml` is extended with repo-specific test files (e.g.
  `tests/test_push_protection.bats`) beyond the org template baseline. When adding new test files to this
  repo, add them to this list. Template syncs must not reset it to the base template list. This includes
  `tests/test_downstream_impact_regression.bats` (#753, epic #748) — the golden-fixture regression guard
  that pins the pure downstream-impact mapper (`scripts/lib/downstream-impact.sh`) against a frozen manifest
  and expected outputs under `tests/fixtures/downstream-impact/golden/`. The golden manifest is intentionally
  independent of the live `scripts/lib/consumer-manifest.json` so a legitimate manifest refresh does not break
  the guard — only a change to the mapper's output does, which then requires an explicit fixture update visible
  in the diff. It runs in the always-run `bats` job (no `paths:` filter) so it stays a stable check.
- **Exception:** The `bats-negation` job in `lint.yml` (#2263) is a repo-specific lint with no org template
  equivalent. It runs `scripts/check-bats-negation.sh` (tests: `tests/test_check_bats_negation.bats`), which
  fails on a negated command in a `.bats` file that can never fail its test. Template syncs must not remove
  it. If the org template gains an equivalent, remove this exception and defer to the template instead.
- **Exception:** `holdout-guard.yml` (#692, epic #581) is a documented repo-specific workflow with no
  corresponding org template in `standards/workflows/`. It is the hard CI enforcement behind the advisory
  `.github/CODEOWNERS` rule over `evals/`: it fails any PR authored by the automated skill-proposer identity
  that changes a held-out path, keyed on PR author + changed paths. It runs on every PR (no `paths:` filter)
  so it stays a stable required status check. The author/path decision lives in
  `scripts/lib/holdout-guard.sh` (tests: `tests/test_holdout_guard.bats`). It must not be removed by template
  syncs. If the org template gains a held-out immutability equivalent, remove this exception and defer to the
  template instead.
- **Exception:** `model-ab.yml` (#1950, epic #1895) is a documented repo-specific workflow with no
  corresponding org template in `standards/workflows/`. It is a `workflow_dispatch`-ONLY (no schedule, no
  `pull_request`) maintainer action that runs the Opus 5.5-vs-4.8 held-out non-regression A/B
  (`scripts/evals/model-ab.sh` via the testable wrapper `scripts/evals/model-ab-dispatch.sh`, tests in
  `tests/test_model_ab_dispatch.bats`) plus a candidate liveness/effort probe. It is in the same
  org-private-automation class as `skill-eval-report.yml` (runs eval scripts against a frozen held-out
  corpus with a fixed judge), not a thin caller stub. It is dispatched only from `main` (a ref guard fails
  any other ref) so the A/B always scores the merged tree, and its inputs are validated offline before any
  paid model call. It must not be removed by template syncs. If the org template gains a model A/B
  equivalent, remove this exception and defer to the template instead.
- **Exception:** `auto-rebase-retry.yml` is a documented repo-specific workflow with no corresponding org
  template in `standards/workflows/`. It covers two recovery paths: (1) a `workflow_run` handler that
  self-heals a *failed* Auto-rebase run by re-running its failed jobs (bounded by `run_attempt`) — the gap
  left by the conflict-only sentinel path, which the thin-caller `auto-rebase.yml` and central reusable
  cannot cover; and (2) a `workflow_dispatch` trigger (#1890 AC #4/#5) taking a `pr_number`, the
  manually-invocable surface for conflict recovery the conflict-only sentinel never had — it routes a PR
  stuck in CONFLICTING/DIRTY straight into dev-lead's `rebase` intent via a `dev-lead-reviews-retry`
  `repository_dispatch` (rather than widening the `workflow_run` scope to conflict sentinels). It must not
  be removed by template syncs. If the org template gains a retry equivalent, remove this exception and
  defer to the template instead.
- **Exception:** `auto-rebase-health.yml` (#737, epic #736) is a documented repo-specific workflow with no
  corresponding org template in `standards/workflows/`. It is a daily (≤1/day) + `workflow_dispatch` report
  that quantifies the agentic-conflict-resolution rate (conflict-sentinel fires vs. dev-lead `rebase`
  responses, both HTML-comment markers GitHub search cannot index) and estimates auto-rebase fan-out CI
  volume from `auto-rebase.yml` run telemetry. It is a no-LLM gh-API + jq report (logic in
  `scripts/auto_rebase_health.sh`, tests in `tests/auto_rebase_health.bats`) and runs on `github.token`
  only — no cross-org PAT. It must not be removed by template syncs. If the org template gains an
  auto-rebase instrumentation equivalent, remove this exception and defer to the template instead.
- **Exception:** `initiative-planner-canary.yml` (#822, closes #655 item 3) is a documented repo-specific
  workflow with no corresponding org template in `standards/workflows/`. It is a daily (≤1/day) +
  `workflow_dispatch` post-merge canary that fires a **dry-run** dispatch of `initiative-planner.yml`
  against a fixture Ideas Discussion and alerts if the run fails or surfaces the `Unsupported event type:
  discussion` regression fingerprint — the silent-revert class of failure from #655 on the live
  `idea:approved` trigger. Logic lives in `scripts/initiative_canary.sh` (tests:
  `tests/test_initiative_canary.bats`); the fixture Discussion is configured via the repo variable
  `INITIATIVE_CANARY_DISCUSSION`. It must not be removed by template syncs. If the org template gains a
  live-trigger canary equivalent, remove this exception and defer to the template instead.
- **Exception:** `premature-closure-audit.yml` (#1077) is a documented repo-specific workflow with no
  corresponding org template in `standards/workflows/`. It is a weekly (≤1/week) + `workflow_dispatch`
  backstop for the dev-lead premature-closure defect: dev-lead closed tracking issues as `completed`
  without the fix landing on `main` (no merged closing PR). It flags issues closed as `completed` within
  `PC_MAX_OPEN_MINUTES` of opening with **no merged closing PR** and, in live mode, re-opens them +
  applies `dev-lead:needs-human` so an attempted-but-unresolved issue stays visibly open. It is a no-LLM
  gh-API + jq audit (pure logic in `scripts/lib/premature-closure-detect.sh`, tests in
  `tests/test_premature_closure_detect.bats`; wrapper in `scripts/premature-closure-audit.sh`). It is
  **staged**: read-only permissions with a `LIVE_MODE` repo-variable gate (mirrors `stale-manager.yml`) —
  writes require setting `LIVE_MODE=true` and adding `issues: write`. It must not be removed by template
  syncs. If the org template gains a closure-audit equivalent, remove this exception and defer to the
  template instead.
- **Exception:** `engine-token-liveness.yml` (#1587) is a documented repo-specific workflow with no
  corresponding org template in `standards/workflows/`. It is a daily off-peak (`23 7 * * *`) +
  `workflow_dispatch` monitor for the fleet-wide engine-token outage class: dev-lead failed 100% of runs
  across 8 repos for seven days — every run died at the **"Engine token preflight"** step
  (`CLAUDE_CODE_OAUTH_TOKEN is not provided`) — and nothing escalated to a human, while pr-review (which had
  no preflight) failed **open**, reviewing nothing yet reporting success. For every repo hosting a dev-lead
  or pr-review caller stub it inspects the most-recent run(s) of that stub and asserts they did **not** fail
  at the preflight step, escalating on breadth: `AGENTS_PAUSED=true` → silent (a deliberate pause is never a
  false alarm); **≥2 consecutive preflight failures in ≥2 repos → a distinct `engine-outage` fleet-alert
  issue** (find-or-refresh a single standing issue, not a per-day digest); an isolated single-repo failure →
  routine run-summary reporting only. The failure signal is **recency-bounded** (#1600): runs older than
  `ENGINE_LIVENESS_LOOKBACK_DAYS` (default **3**) are ignored when computing the streak, a stub whose newest
  run predates that window is reported as a distinct **STALE** (unverified) state that does **not** fail the
  run, and the run is failed red only on a within-window OUTAGE — so a low-traffic repo's resolved
  pre-incident failure streak is no longer reported as a live outage that holds every scheduled run red. It
  also audits the `GH_PAT_DON_PETRY` classic-PAT scope/expiry — a
  silent single point of failure whose rotation surfaces only as an opaque 401/403 on the next run. It is a
  no-LLM gh-API + jq monitor (pure logic in `scripts/lib/engine_liveness_detect.sh`, tests in
  `tests/test_engine_liveness_detect.bats`; network wrapper in `scripts/engine_liveness.sh`). It must not be
  removed by template syncs. If the org template gains an engine-token liveness equivalent, remove this
  exception and defer to the template instead.
- **Exception:** `initiative-driver-canary.yml` (#885, epic #882) is a documented repo-specific workflow
  with no corresponding org template in `standards/workflows/`. It is a daily (≤1/day) +
  `workflow_dispatch` post-merge canary that fires a **dry-run** dispatch of `initiative-driver.yml`
  against a fixture target repo + epic and alerts if the run fails OR — for a configured fixture — if the
  run surfaces no `READY (dry-run, not labeling)` decision (a HOLLOW GREEN: the cross-repo
  gate/`blocked_by` resolved to nothing, so the release path is silently broken even though CI is green).
  Logic lives in `scripts/initiative_driver_canary.sh` (tests:
  `tests/test_initiative_driver_canary.bats`); the fixture is configured via the repo variables
  `INITIATIVE_DRIVER_CANARY_TARGET` / `INITIATIVE_DRIVER_CANARY_EPIC` (the fixture epic must carry
  `initiative:auto` with ≥1 ready open sub-issue). It must not be removed by template syncs. If the org
  template gains a cross-repo release-path canary equivalent, remove this exception and defer to the
  template instead.
- **Exception:** `pr-review-canary.yml` (#1256, epic #1052 Part D) is a documented repo-specific workflow
  with no corresponding org template in `standards/workflows/`. It is a post-merge (`push` to `main` on the
  pr-review stub/reusable paths) + daily off-peak cron + `workflow_dispatch` canary that fires a **dry-run**
  dispatch of `pr-review-trigger.yml` (the ring-0 self-host caller stub) and **fails loud if the run ends in
  `startup_failure`** — the exact conclusion of the #1034 channel-skew defect (a `with:` forward the pinned
  then-current `pr-review/next` channel — now `pr-review/v1-next` — did not declare), which nothing in PR CI exercises. It complements the
  `validate-caller-inputs` (#1253) and `caller-stub-freeze` (#1255) static guards with a live post-merge
  signal. Logic lives in `scripts/pr_review_canary.sh` (tests: `tests/pr_review_canary.bats`); the dispatch
  requires `GH_PAT_WORKFLOWS` (a `workflow_dispatch` fired with `GITHUB_TOKEN` never starts a run). It must
  not be removed by template syncs. If the org template gains a self-host caller-stub canary equivalent,
  remove this exception and defer to the template instead.

- **Exception:** `dismiss-stale-bot-reviews.yml` (#617, blocker 3) is a documented repo-specific
  workflow with no corresponding org template in `standards/workflows/`. It fires on
  `pull_request: synchronize` and auto-dismisses allow-listed bot `CHANGES_REQUESTED` reviews
  that are attached to a superseded (non-head) commit — GitHub's built-in
  `dismiss_stale_reviews_on_push` only clears stale *approvals*, so bot CHANGES_REQUESTED
  reviews blocked merges after a re-review was already approved. The allow-list is a
  space-delimited `BOTS` env var in the workflow (currently `coderabbitai`); only same-repo PRs
  are processed (fork PRs receive a read-only token). It must not be removed by template syncs.
  If the org template gains an equivalent stale-bot-review dismissal, remove this exception and
  defer to the template instead.

### Required-check workflows must trigger on `merge_group`

Every workflow that provides a **required status check** on `main` must include `merge_group` in its
`on:` triggers (#1871). A merge queue only merges a PR once its required checks report on the queue's
temporary `gh-readonly-queue/*` ref, and a check reports there only if its providing workflow triggers
on `merge_group`. A required check that never runs on the queue ref leaves every queued PR permanently
`BLOCKED` — strictly worse than no queue at all — which is why the queue approved in #1864 was gated on
this. Adding `merge_group` is trigger-only: **never rename the job whose name is the required-check
context**, because the ruleset matches by context string and a rename silently un-requires the check,
leaving the old context name unsatisfied and the merge queue permanently blocked.

- The locally-owned required checks are `SonarCloud` (`sonarcloud.yml`), `duplicate-decl-gate`
  (`duplicate-decl-gate.yml`), and `CodeQL` (`codeql.yml`, advanced setup). CodeQL must use **advanced
  setup**, not GitHub default setup — default setup analyzes `push`/`pull_request` only and cannot post
  to the `merge_group` ref (github/codeql-action#1537).
- CI enforcement: `tests/test_merge_group_required_checks.bats` pins the `merge_group` trigger and
  asserts that required-check context names are unchanged on the three locally-owned workflows above
  (`SonarCloud`, `duplicate-decl-gate`, `CodeQL`). For `SonarCloud` and `duplicate-decl-gate`, the
  assertions pin the explicit job name; for `CodeQL`, the guard pins the aggregation job ID (which
  resolves to the job name `CodeQL` if set) to catch any rename. This coverage is **not automatic** —
  the guard only knows about workflows it explicitly names. When you add a new locally-owned required
  check, you **must** extend this test with its workflow, or a required check missing the `merge_group`
  trigger will slip through and reintroduce the merge-queue wall.
- The two thin caller stubs `agent-shield.yml` and `dependency-audit.yml` also front required checks but
  carry "You MUST NOT change: trigger events"; their `merge_group` wiring is owned upstream and tracked in
  `combsmith/.github#1157`, not here.

**Cutover + verification before the queue is enabled (#1864 gate).** Enabling the merge queue is out of
scope of #1871 and must not be switched on until this is confirmed:

1. **Manual cutover (repository setting, not a file change):** disable code-scanning **default setup** in
   Settings → Code security → Code scanning at the moment `codeql.yml` merges, so default and advanced
   setup do not both run.
2. **Verify all five required contexts report on a `merge_group` run** — `SonarCloud`,
   `duplicate-decl-gate`, `CodeQL`, `agent-shield / AgentShield`, and
   `dependency-audit / Detect ecosystems` — by inspecting an actual `gh-readonly-queue/*` run (e.g. a
   throwaway PR routed through a test queue). Do **not** enable the queue on the assumption that it works;
   a required check missing from the queue ref wedges every merge.

### The merge queue checks reviews only at enqueue — the fleet dequeues on a withdrawn approval (#2174)

GitHub evaluates the `code-quality` ruleset's review requirement when a PR **joins** the merge queue
and does **not** re-evaluate it when the queue merges. A dismissal after enqueue therefore no longer
stops the merge: PR 2084 was approved, enqueued, had that approval dismissed, and merged while showing
`REVIEW_REQUIRED`. So the disposition gate's withdrawn approval could be outrun by the queue.

- **The fleet dequeues when it withdraws the last approval.** `mq_dequeue_if_unapproved`
  (`scripts/lib/merge-queue-dequeue.sh`) runs after every dismissal in the run **and** after the run's
  new verdict is posted, in `scripts/post-pr-review.sh` (approve and fix-request paths) and in
  `scripts/invalidate-standing-approval.sh` (live mode, when it dismissed something), and in
  `scripts/review-one-pr.sh` after its comment-gate and maintainer-thread-gate dismissals. It reads the
  **live** PR: if the PR is open, has a `mergeQueueEntry`, and no writer's latest review is `APPROVED`
  on the current head commit (bot **or** human), it calls the GraphQL `dequeuePullRequest` mutation and
  posts one comment carrying `<!-- pr-review-agent dequeued sha=<head> -->` (a failed dequeue uses
  `<!-- pr-review-agent dequeue-failed sha=<head> -->`, so a success notice never masks it). A re-review that dismisses
  the old approval and posts a new one leaves an approval standing, so the PR stays queued.
- **It never fails the run.** A PR that is not queued, already merged, or left the queue before the
  call is a no-op. A failed dequeue logs a `::warning::` and posts one comment asking a maintainer to
  remove the PR from the queue by hand. An unreadable live state logs a `::warning::` and takes no
  action. The marker is posted at most once per head SHA.
- **A failed state read is retried, then surfaced.** The live read is tried `MQ_READ_ATTEMPTS` times
  (default 3, `MQ_READ_RETRY_DELAY_SEC` apart, default 2). If every attempt fails the helper cannot tell
  whether a queued PR lost its last approval: it logs a `::warning::`, writes the unknown state to the job
  step summary so a maintainer can check the queue, makes no dequeue call and posts no PR comment (most PRs
  that reach this path are not queued), and never fails the run (#2186).
- **Auto-merge after a dequeue.** A dequeue consumes the PR's auto-merge request. dev-lead's idempotent
  `try_enable_auto_merge` re-enables it on its next pass; once an approval stands again, the PR
  rejoins the queue. This is intended.
- **Out of scope:** `.github/workflows/dismiss-stale-bot-reviews.yml` only dismisses stale
  `CHANGES_REQUESTED` reviews, which helps a merge, so it must not dequeue (pinned by
  `tests/test_merge_queue_dequeue.bats`).
- **Rollout channel.** `post-pr-review.sh` runs from the pr-review channel, not `main`
  (`pr-review-trigger.yml` pins `pr-review.yml@pr-review/v1-next`). The change rides the next Release
  Manager autocut to `pr-review/v1-next` and reaches `pr-review/v1-stable` through ring promotion. Until
  `next` carries it, a queued PR whose approval is withdrawn can still merge.
  `invalidate-standing-approval.sh` has no workflow caller; an operator runs it from a checkout, so it
  dequeues as soon as the checkout includes this change.

### Template drift guard (`repo-template`)

`combsmith/repo-template` is a **distribution artifact** of the canonical `standards/` in the public
`combsmith/.github` repo: `scripts/seed-repo-template.sh` fetches each canonical workflow stub /
baseline file and ships it (caller stubs repinned to the published `@<name>/stable` channel, inline stubs +
baseline files verbatim). The `template-drift` job in `lint.yml` (#969, epic #964) guards that the files
**committed** in the template have not diverged from that standards-derived baseline — it re-derives the
expected content via `seed-repo-template.sh --emit-*`, compares its git blob SHA against the template repo's
committed blob SHA, and fails on any **DRIFTED** file, reusing the ALIGNED/DRIFTED/MISSING byte-identity
model from `scripts/fleet_stub_drift.sh` (pure logic + bats: `tests/template_stub_drift.bats`). It is a
PR-triggered check on the existing Lint workflow — **no new cron/scheduled workload**.

- **AHEAD is not DRIFTED — promote standards, do not re-seed (#1926).** The baseline is derived at the
  published `standards/v1-stable` channel, which lags standards `main` until someone promotes it. A
  template that already carries newer standards content therefore differs from the channel while being
  exactly what standards says it should be. A file matching neither N nor N-1 is compared once more,
  against the seed emission at the standards default-branch HEAD. A match is **AHEAD**, and its
  `::warning::` says to promote standards (`scripts/cut-standards-release.sh` in `combsmith/.github`)
  instead of re-seeding. Re-seeding from the channel would regress the template: on 2026-09-24 it would
  have stripped the `merge_group` trigger from `agent-shield.yml` and `dependency-audit.yml`.
  - **AHEAD warns; it does not fail the check.** This is deliberate. The committed bytes are
    byte-identical to a standards emission, so nothing here needs repair. The fix is a channel promotion
    in another repo, which no PR in this repo can make, so failing would only turn unrelated PRs red. It
    mirrors the N-1 rule (the same lag in the other direction), which is also accepted and flagged.
  - **Only a file that matches no standards emission is DRIFTED**, and that still fails.
  - **HEAD is compared only when it is newer (#2237).** A SHA that differs from HEAD does not prove HEAD
    is newer: an explicit `STANDARDS_REF` can name a standards branch that is not in `main`'s history. So
    the AHEAD comparison runs only when the baseline commit is an ancestor of the standards HEAD. This is
    read once per run from the compare API. A baseline that is ahead of HEAD or diverged from it never
    yields AHEAD; a `::notice::` says why.
  - **A comparison that cannot be made is said so.** If the standards HEAD commit, its relation to the
    baseline, or its emission cannot be read, the file stays DRIFTED and fails. The row is tagged
    `ahead-unchecked`, and the message tells you to re-run with `STANDARDS_REF=<standards main commit>`
    before re-seeding.
  - **A file may also match a commit between the channel and HEAD (#2237).** The comparison checks only
    the channel and HEAD, so a template synced from a standards commit between them is still DRIFTED.
    When HEAD is newer than the channel, the DRIFTED message does not give the bare "Re-seed it" remedy.
    It says an intermediate-commit sync is possible and how to check it: re-run with
    `STANDARDS_REF=<commit>` for the commits in that range that touched the file's source. If one reports
    ALIGNED, re-seed at standards HEAD and promote standards. Never re-seed from the channel.
    - **Decision: a message, not detection.** To match intermediate commits, the guard would need each
      file's standards source paths, which only `seed-repo-template.sh` knows. It would also need one
      commits-list call per DRIFTED file and one emission per commit in the range. That adds network
      cost to every PR's lint run. The message removes the wrong advice without that cost.

- **A red `template-drift` is never fixed from a PR here (#2220).** The check reads `repo-template`, never
  this repo's own stubs, so nothing in a PR here can clear it. It is not a fix-ci trigger: the reusable's
  `ci-relay` job does not relay it, and `dev-lead-fix-ci.sh` drops it (`FIX_CI_IGNORED_CHECKS`). Its
  annotations still carry a `file=` anchor, so GitHub pins them to the PR's own same-named file (dropping
  the anchor is tracked in #2215). That is how two passes (#2157, #1796) "fixed" the drift by repinning
  this repo's `dev-lead.yml` from `dev-lead/v139-ring0` to the stale `dev-lead/v1-stable`. As a backstop, `scripts/lib/channel-pin-guard.sh`
  refuses any dev-lead pass (fix-ci and every fix-reviews intent) that changes a first-party channel pin
  (`uses: combsmith/…@<channel>` or `agent_ref`) on a workflow file, and escalates the PR. Ending on the
  base branch's pin (a rebase, or restoring `main`'s pin) is allowed.

- **`seed-repo-template.sh` has one home: this repo (#1927).** `combsmith/.github` once carried a
  different, smaller script under the same name, and the two were mistaken for diverged copies. That
  script only prints one standard file from a local checkout and is now `scripts/emit-standard-file.sh`
  there; a CI guard in that repo fails if a `seed-repo-template.sh` reappears. Change the seeder here.

- **Seeding is an operator procedure with recorded provenance (#1925).** No workflow runs
  `seed-repo-template.sh`. An operator follows
  [`docs/release/seeding-repo-template.md`](./docs/release/seeding-repo-template.md): dry run first, leave
  `STANDARDS_REF` unset so the published channel is used. If the channel cannot be resolved the script
  falls back to standards HEAD and reports `source head-fallback`; the operator stops there.
  - **Provenance.** Every seed PR body states the resolved standards ref, how it was chosen (channel,
    explicit, HEAD fallback or local) and the commit. Files are fetched at that commit, not through the
    ref name. A local `STANDARDS_DIR` has no commit, so the body records `unknown`. A reused PR's body is
    rewritten on each run.
  - **One seed PR.** An open `seed-scaffold/*` PR is updated in place (#2233). If several are open, the
    newest is kept and each older one is closed with a comment linking it. A PR that cannot be closed
    fails the run. If the open PRs cannot be listed, the run stops before it writes anything.
  - **No downgrades.** A file that differs from the run's emission but matches the emission at standards
    HEAD is **refused**, with "standards channel is behind the template — promote standards". This is the
    seed-side twin of the drift guard's AHEAD status and reuses its HEAD and ancestry reads. If every
    differing file is refused, no PR is opened. A local `STANDARDS_DIR` has no ref, so this check does
    not run there; do not use it for a real seed.
  - **Cannot check means stop.** If the HEAD commit, its relation to the resolved ref, or the HEAD emission
    cannot be read, the seed aborts instead of overwriting the file.

- **Reference rows — `agent-ingress.yml` (#1729, AC #12):** `.github/workflows/agent-ingress.yml` is
  enrolled in the drift manifest for **post-collapse byte-identity coverage**, but
  `seed-repo-template.sh` deliberately never seeds it (it lives in the `--emit-workflow`-only
  `REFERENCE_MANIFEST`, reachable for hashing but never written into the seeded set). Until the ADR-0007
  pilot repo collapse lands, the template has no such file, so it reports MISSING every run. A MISSING
  **reference row** therefore prints a distinct **non-actionable `::notice::`** — never the generic
  "re-seed via `seed-repo-template.sh`" remedy, which can never clear it and, if followed, would hand-copy
  a live executing ingress into every new repo ahead of the pilot. The reference set lives in
  `TEMPLATE_DRIFT_REFERENCE` in `scripts/template_stub_drift.sh`; when the pilot collapse lands, the
  template is seeded in the **same change** that retires the per-role stubs it replaces and the row stops
  being a reference row.

- **Allowlist exception — `ci.yml`:** `.github/workflows/ci.yml` is the **one** shipped stub that
  intentionally carries real per-stack build/test steps and is customized per consumer (see the template's
  `BOOTSTRAP.md` "Customize `ci.yml` for your stack" step). A byte-identity guard would false-positive on the
  template's richer `ci.yml` default, so it is **excluded** from the drift check via the documented allowlist
  in `scripts/template_stub_drift.sh` (`TEMPLATE_DRIFT_ALLOWLIST`). Add a path to that allowlist **only** with
  a recorded rationale, the same way the exceptions above are documented.

- **Dependabot must not bump the shipped artifacts (#1435).** Dependabot runs in `repo-template` off the
  seeded `.github/dependabot.yml`. If that config enables the `github-actions` ecosystem, Dependabot bumps
  action versions **inside the shipped workflow stubs** — each bump rewrites a committed blob, so the file no
  longer matches the standards-derived baseline and `template-drift` fails **in this repo for a change made in
  another repo**. Since #1549 `compute_ci_status` (`scripts/lib/ci-status.sh`) gates only on checks the
  rollup marks **required** (their `.isRequired` field), a non-required `template-drift` failure no longer
  halts pr-review here — but a Dependabot bump still rewrites the shipped blob and turns the check red for no
  useful reason (and the gate degrades to the old all-checks behavior whenever nothing is flagged required),
  so it must still be prevented at the source. **Mechanism:**
  `scripts/seed-repo-template.sh` scopes the `github-actions` package-ecosystem **out** of the shipped
  `.github/dependabot.yml` (`_dependabot_scope_out_actions`; tests in `tests/test_seed_repo_template.bats`).
  The template's workflows are a distribution artifact of `standards/` and their action versions stay current
  by **re-seeding** (`bump standards/` → re-run `seed-repo-template.sh`), not by Dependabot — the same
  edit-standards-not-the-copy contract as the drift guard itself. This also correctly stops Dependabot from
  bumping the first-party channel-tag pins in the caller stubs, which are the sanctioned mutable-ref exception
  (see "Release channel tags & the mutable-ref exception"). Other ecosystems (npm/gomod/pip/…) pass through
  unchanged, and a consumer that wants Dependabot-managed action updates for its **own** (non-artifact)
  workflows adds the `github-actions` ecosystem back when it customizes its stack per `BOOTSTRAP.md`.
  - **Why not the alternatives.** *Option 2 — keep Dependabot, automate a re-seed after each bump* — was
    rejected: it leaves a permanent drift window between the bump and the re-seed during which
    `template-drift` is red and review here is halted. *Option 3 — point Dependabot at
    `combsmith/.github` and let bumps flow to the template by re-seeding* — reaches the same
    end state but additionally requires a change in the public standards repo; the scope-out above is
    implementable entirely from this repo (which owns `seed-repo-template.sh`) and is a prerequisite for
    Option 3 anyway (the template still must not run its own `github-actions` Dependabot). If the standards
    repo later grows its own `github-actions` Dependabot + re-seed automation, this scope-out remains the
    correct template-side behavior.

### Reusable caller-input contract (`validate-caller-inputs`)

The `validate-caller-inputs` job in `lint.yml` (#1253, epic #1052; regression guard for #1034)
enforces that every reusable-workflow caller stub — `uses: <owner>/<repo>/.github/workflows/<wf>.yml@<ref>`
with a `with:` block — forwards only inputs that are **declared as `workflow_call` inputs at the
pinned `<ref>`**, and forwards every `required: true` input. `pull_request` CI runs the *base-branch*
stub, and GitHub validates a reusable's inputs only at startup against the **pinned** ref — so an
input-forwarding change to a channel-pinned caller stub is exercised by nothing in PR CI and only
breaks post-merge (the #1034 defect). This guard closes that gap.

- Logic lives in `scripts/validate-caller-inputs.sh` (pure parse/validate helpers + git resolution;
  tests: `tests/dev-lead/unit/test_validate_caller_inputs.bats`, fixtures under
  `tests/dev-lead/fixtures/caller-inputs/`, including a #1034 regression fixture).
- Same-repo channel tags (`dev-lead/*`, `pr-review/*`, `ci-failure-analyst/*`, …) are resolved by
  `git fetch`-ing the tag and reading the reusable at that ref. A ref that genuinely can't be resolved
  **soft-passes with a logged `::warning::` — never silently.** Cross-repo reusables (hosted in another
  repo, e.g. `combsmith/.github`) are treated as unresolved here unless `VCI_RESOLVE_CROSS_REPO=1`
  opts in; the warning keeps the skip visible. Extending resolution to cross-repo channel tags is the
  scope of the later #1052 parts.
- PR-triggered on the existing Lint workflow — **no new cron/scheduled workload.** It must not be
  removed by template syncs. If the org template gains an equivalent, remove this exception and defer.

### Ring-0 caller-stub freeze (`caller-stub-freeze`)

The `caller-stub-freeze` job in `lint.yml` (#1255, epic #1052 Part B) is the byte-identity **backstop** to
`validate-caller-inputs` for the specific **ring-0 / self-host** caller stubs — the ones whose reusable lives
in **this** repo and is pinned to a canary channel tag (`docs/initiatives/agentic-release-strategy.md` §5):
`dev-lead.yml` (`@dev-lead/v139-ring0`), `pr-review-trigger.yml` (`@pr-review/v1-next`), and
`ci-failure-analyst.lock.yml` (`@ci-failure-analyst/v1-stable`). A trigger/`with:` forwarding change to a
channel-pinned self-host stub is exercised by nothing in PR CI and only breaks post-merge (the #1034 defect
class), so each stub's `on:` trigger + `uses:`/`with:` forwarding block is frozen byte-for-byte against a
committed baseline (`tests/fixtures/caller-stub-freeze/*.block`).

- Any edit to a frozen block fails CI **unless** the baseline is intentionally regenerated in the same
  reviewed diff — an explicit, visible channel change rather than a silent post-merge break. Regenerate via
  `bash scripts/caller_stub_freeze.sh --update` and commit the changed `*.block` file(s).
- Logic lives in `scripts/caller_stub_freeze.sh`, reusing the ALIGNED/DRIFTED byte-identity model from
  `scripts/fleet_stub_drift.sh` (tests: `tests/caller_stub_freeze.bats`). To freeze another self-host caller
  stub, add a row to `CALLER_FREEZE_STUBS` and commit its baseline.
- PR-triggered on the existing Lint workflow — **no new cron/scheduled workload.** It must not be removed by
  template syncs. If the org template gains an equivalent, remove this exception and defer.

### Agentic interaction model

How agentic roles are triggered and how they interact is a **normative repo-local standard**,
[`docs/agentic-interaction-model.md`](./docs/agentic-interaction-model.md). It codifies the
event-first principle, the three trigger classes (event-driven / backstop-timer /
scheduled-origin), the `GITHUB_TOKEN` event-boundary rule and its two sanctioned bridges, the
timer contract, and the #860 runaway rules. Read it before adding or changing an agentic
workflow's `on:` block, a `schedule.cron`, or a cross-workflow dispatch — a new role must add a
row to its §4 classification table and declare a machine-readable per-role interaction contract
(`interaction-contracts/<name>.yml` and/or `personas/<id>/interaction.yml`), both CI-verified.

- **Adding a role?** Follow the step-by-step runbook
  [`docs/adding-an-agentic-role.md`](./docs/adding-an-agentic-role.md); each step cites the
  governing section of the standard.
- This section is consistent with, not competing with, "Scheduled workflows" below (which now
  defers to the org-wide off-peak timing standard governing *when* a timer may fire) and the
  "Ring-0 caller-stub freeze" above (which byte-freezes the self-host caller stubs the standard
  classifies as Class 1). This section is still **repo-local first**, shaped for promotion into an
  org-wide `standards/agent-standards.md` in
  [`combsmith/.github`](https://github.com/combsmith/.github) — the same repo-local → org
  path the off-peak scheduling standard has already completed.

### Scheduled workflows

> **Promoted — defer to the org standard.** The off-peak scheduling rule (never
> schedule at minute 0; pick a staggered, non-round minute; idempotent sweeps may
> run more often but still off the top of the hour) is now the **canonical,
> org-wide standard**. Read it in
> [standards/ci-standards.md in combsmith/.github](https://github.com/combsmith/.github/blob/main/standards/ci-standards.md)
> → **Scheduled Workflow Timing**, which was
> promoted out of this repo-local section under epic #722 / story #726 and now
> names this repo as its origin. That section is the single source of truth for
> the rule and its rationale; this repo defers to it — there is no separate
> repo-local copy to keep in sync. (Same repo-local → org promotion path the
> Cost-reporting section documents.)

- **CI enforcement (repo-local).** This repo enforces the org rule above with its
  own check: the `validate-workflow-schedules` job in `lint.yml` (backed by
  `scripts/validate-workflow-schedules.sh`, tests in
  `tests/test_validate_workflow_schedules.bats`) fails any PR that introduces a
  minute-0 `schedule.cron` in `.github/workflows/*.yml`, `.github/workflows/*.md`,
  or `docs/aw/*.md`. The `frameworks/` subtrees are upstream-owned knowledge docs,
  not our schedules, and are intentionally out of scope. This is a distinct
  implementation from the org standard's own reference check
  (`scripts/check-cron-timing.sh`), so it is retained here rather than deferred.

### Fleet stub-drift remediation loop

The Actions Fleet Monitor (`.github/workflows/actions-fleet-monitor.yml`) detects per-repo
thin-caller stub drift and writes `fleet_stub_drift.json` every run. Epic #1148 adds an **opt-in,
DRY_RUN-default remediation loop** that consumes that artifact on the *same cadence* — it proposes
(never direct-pushes) the canonical stub bytes back to a drifted consumer repo as one PR per repo.
The loop is deliberately hard to fire by accident; it is bounded by four controls:

- **DRY_RUN default (`scripts/fleet_stub_remediate.sh`).** `DRY_RUN` defaults to `true`. Every
  scheduled and `workflow_call` run logs the remediation *intent* and makes zero write API calls.
  Live remediation is only ever reached on an explicit `workflow_dispatch` with the `remediate=live`
  input — the human go decision. The gate is `scripts/fleet_remediate_gate.sh`
  (tests: `tests/fleet_remediate_gate.bats`): live requires `workflow_dispatch` + `remediate=live`
  **and** the cross-repo write credential (`GH_PAT_WORKFLOWS`) **and** a configured pilot repo;
  any missing precondition degrades to dry-run with a `::warning::` and never fails the monitor
  (mirroring `fleet_monitor.sh`'s token-degradation posture). The remediation step is also
  `continue-on-error: true`, so it is strictly non-blocking for the daily monitor.
- **Pilot gate (`REMEDIATE_PILOT_REPO` / `vars.FLEET_REMEDIATE_PILOT_REPO`).** Live remediation is
  fail-closed to an explicitly named pilot repo: with none set, the driver refuses to write and stays
  dry-run. Every DRIFTED repo outside the pilot scope is logged `would remediate (out of pilot scope)`
  and skipped without writes. This is the pilot-first blast-radius bound before widening fleet-wide.
- **Per-run cap (`REMEDIATE_MAX_REPOS` / `vars.FLEET_REMEDIATE_MAX_REPOS`, default `1`).** The maximum
  number of repos remediated live in a single run. Repos beyond the cap are logged as *deferred*
  (never silently truncated) and picked up on a later run.
- **Never-overwrite allowlist (`REMEDIATION_ALLOWLIST` in `scripts/fleet_stub_remediate.sh`).** Files a
  consumer repo has intentionally customized are never re-synced — an allowlisted `owner/repo` or
  `owner/repo|stub_file` never appears in the remediation plan. It is intentionally empty (every tracked
  fleet stub is a verbatim deployment and *is* remediable) until a first deliberate customization is
  recorded. Add an entry **only** with a recorded rationale, the same recorded-rationale rule the
  template `ci.yml` drift exception follows.

Each live remediation is verified byte-for-byte (pushed blob SHA == canonical blob SHA) before its PR
is opened, and the per-repo drift-closed verdicts are surfaced in the run log (and an optional summary
artifact). **The human go/no-go to enable live pilot remediation — and, later, to widen fleet-wide — is
recorded as a comment on the tracking issue/PR**, consistent with the repo's go/no-go pattern and the
initiative-planner inert-epic model: the loop stays inert (dry-run) until a human explicitly flips a
run to `remediate=live` for the configured pilot.

### Bats tests — a negated command must be able to fail

Bash exempts a `!`-negated command from `errexit`, and bats fails a test through `errexit`. So a
line like `! grep -q "pr comment" "$GH_LOG"` in the **middle** of a test runs, has its result thrown
away, and the test passes either way. It only counts as the **last** command of the test. By the time
this was caught (#2263), 113 such lines across 41 files were asserting nothing, and two of them were
hiding a test whose setup was wrong.

**Rule: write a negative assertion so it can fail.**

```bash
! grep -q "pr comment" "$GH_LOG" || false   # fails the test when grep matches
run ! grep -q "pr comment" "$GH_LOG"        # bats >= 1.5; overwrites $status and $output
```

`scripts/check-bats-negation.sh` enforces this in the `bats-negation` lint job. When a new negative
assertion is added for a fix, prove it: run the test against the unfixed code and watch it fail.

### Agent Profiles (`agents/*.md`)

- Every agent profile must have YAML frontmatter with `name`, `description`, and `tools`.
- Agent names must be kebab-case and match the filename.
- Profiles are org-wide — changes affect all `combsmith` repos.

### Framework Subtrees (`frameworks/`)

- The `frameworks/` directories are managed via `git subtree`. Do not edit them directly unless
  applying local overrides that cannot be upstreamed.
- To update a framework, use `git subtree pull` against the upstream remote.

### Scripts (`scripts/`)

- Scripts must be POSIX-compatible shell (`#!/usr/bin/env bash` with `set -euo pipefail`).
- No hardcoded tokens or secrets — use `$GITHUB_TOKEN` from the environment.
- **"Why isn't this PR approved?"** Run `bash scripts/pr-approval-diagnostic.sh <pr-url>`
  (profile: [`agents/why-not-approved.md`](./agents/why-not-approved.md)). It runs the real
  pr-review gate chain read-only (`PR_REVIEW_DIAGNOSE=true`) and reports the first gate holding
  the PR and what clears it. Do not reconstruct the gates by hand (#1894).

### Model selection — name a family, never pin a version

Name a model **family** — `opus`, `sonnet`, or `haiku` — and resolve it to the
current concrete id at run time; do **not** hard-pin `claude-<family>-<version>`
ids across the tree (#1979, companion
[`combsmith/.github#1199`](https://github.com/combsmith/.github/issues/1199)).
A model swap should be one edit to the chains in
[`scripts/lib/engine-models.sh`](./scripts/lib/engine-models.sh), not a hunt for
scattered ids.

- **Resolve with `ai_model_for_family <family>`** (`scripts/lib/engine-models.sh`):
  it returns the current id for the family, honouring `CLAUDE_<TIER>_MODEL_CHAIN`
  then `AI_MODELS_CLAUDE` then the built-in default. A shell caller sources the lib
  and calls the function; a workflow adds a resolve step that writes the id to a
  step output. In gh-aw front-matter, `engine:` names the runner engine (e.g.
  `claude`) and the model family is named in `models:` (e.g.
  `models: { claude: [sonnet] }`) — the family does not go in `engine:`.
- **An operator-supplied concrete `claude-*` id is still honoured** — workflow
  `model` inputs default to a family but pass a full id through unchanged.
- **Token records keep the resolved id**: families resolve before the engine runs,
  so `TOKEN_LOG_FILE` records the concrete model, not the family name.
- **`scripts/check-model-pins.sh`** (the `check-model-pins` job in `lint.yml`) fails
  when a concrete id appears under `.github/`, `scripts/`, `prompts/`, `agents/`, or
  `personas/`. When a concrete id is genuinely required (eval judge held fixed, ET
  baseline anchor, last-resort fallback), mark that line `# model-pin-ok: <reason>`;
  the resolver and `model-pricing.tsv` are allow-listed.

See [`docs/engine-configuration.md`](./docs/engine-configuration.md) §"Model
selection" for the family→tier→id table.

### Agent identity & credential secrets

Every persona/agent declares the GitHub account it **acts as** — the login it
commits, pushes, reviews, or comments as — in its manifest under
`runtime.identity` (`personas/<id>/persona.yml`): an `account` and the `credential`
secret holding that account's PAT. The runtime resolves `BOT_USER` from
`account` via `scripts/lib/resolve-persona-identity.sh`; **never** derive a
write persona's identity from a shared `vars.BOT_USER` — that coupling let
dev-lead regress to committing as the review-only machine user `donpetry-bot`
([#1316](https://github.com/combsmith/.github-private/issues/1316)).

- **dev-lead** acts as `don-petry` (the owner); **pr-review** acts as the
  review-only machine user `donpetry-bot`. They are deliberately different accounts.
- PAT secrets follow **`GH_PAT_<ACCOUNT>[_<QUALIFIER>]`** (login upper-snake-cased),
  e.g. `GH_PAT_DON_PETRY`. Pre-existing account-named secrets (`DON_PETRY_BOT_GH_PAT`)
  are grandfathered.
- `lint.yml`'s `verify-persona-identity` job enforces the manifest↔workflow
  wiring; `validate-personas.py` makes `runtime.identity` mandatory. See
  `standards/persona-standards.md` §5.1 and
  `docs/pr-review-agent/machine-user-setup.md`.

### Pausing the agent fleet (`AGENTS_PAUSED`)

To take the agents offline deliberately (quota conservation, incident response),
set the Actions **variable** `AGENTS_PAUSED=true` (repo- or org-level) — do
**not** delete or withhold `CLAUDE_CODE_OAUTH_TOKEN`. With the variable set,
every model-calling workflow in this repository skips its model-calling jobs
cleanly (neutral, not red), **except** the ones the registry lists as not paused
because their model call lives in another repository. Today that is one:
`feature-ideation.yml`, which keeps running through a pause until
[combsmith/.github#1295](https://github.com/combsmith/.github/issues/1295)
lands. The full list is in
["Which workflows honour the pause"](#which-workflows-honour-the-pause-2249) below. Withholding the
secret instead presents as a fleet-wide outage of failing dispatch runs that
took real diagnosis time when it happened (2026-08-16, #1525). Resume by
deleting the variable or setting it to anything other than `true`. If the
secret is genuinely missing while unpaused, the reusable's "Engine token
preflight" step fails with a single actionable error naming the secret.

`AGENTS_PAUSED` is read as `vars.AGENTS_PAUSED` in the **calling** repository's context, so
only an **organisation** variable pauses every repository, and a repository variable of the
same name overrides the organisation's for that repository. GitHub compares the value without
regard to case, so `TRUE` pauses too.

#### Which workflows honour the pause (#2249)

Until #2249 only dev-lead read the variable, so a pause stopped one agent while pr-review, the
persona runner and every other model-calling workflow kept starting runs. Now each of them is
gated (with the one upstream exception above), and a test keeps it that way.

- **How a workflow is paused.** The model-calling job carries `vars.AGENTS_PAUSED != 'true'` as
  the **first term** of its job-level `if:`, followed only by `&&` terms (the job's existing event
  filter, unchanged), so nothing after it can bypass the pause and the condition is the old one
  whenever the variable is unset or `false`. A job skipped by `if:` cannot log, so most gated
  workflows also have a small `fleet-paused` job on the complementary condition
  (`vars.AGENTS_PAUSED == 'true'` and the same event filter). It prints one `::notice` line naming
  the workflow, the pause source (`vars.AGENTS_PAUSE_SOURCE`) and the until time
  (`vars.AGENTS_PAUSE_UNTIL`), each shown as "not set" when absent. A paused run of such a
  workflow ends **green** with the model job skipped; read the notice, not the conclusion.
- **Four gated workflows have no notice job**, so a paused run of them ends **skipped**:
  `dev-lead-reusable.yml`, `pr-review.yml`, `ci-failure-analyst-reusable.yml` and `spec-drift.yml`
  (reasons in the table). For the three reusables this is deliberate and load-bearing: the canary
  promotion gate (`scripts/canary-rollout.sh` in `combsmith/.github`) counts every run of an
  agent that ends `success` or `failure` as a health sample, so a run whose only work was the
  notice would count as a healthy sample of a release that did nothing. Do not add a
  `fleet-paused` job to a reusable the gate samples; the test fails a `job-gate-silent` workflow
  that has one.
- **How the monitors read a paused run (#2266).** The variable's value when a run started is not
  in the Actions API afterwards, so a monitor reads what the run recorded: the `fleet-paused` job
  concluded `success` (`scripts/lib/fleet-pause.sh`). The Fleet Monitor takes such runs out of
  every total, success count, failure rate and duration and lists them under "Fleet-paused
  runs"; it asks only about green runs of workflows that carry the notice job, 100 runs per
  request. The initiative-planner canary reports `PAUSED` instead of a pass. A run that ended
  `skipped` is **not** read as paused on that evidence alone, because an event filter ends a run
  the same way: the Fleet Monitor leaves the four workflows above as they were, and the pr-review
  canary reports `PAUSED` only when its dispatched run ended `skipped` **and** its own
  `vars.AGENTS_PAUSED` is `true`. `PAUSED` never raises a canary alert and is never announced as
  a pass.
- **The notice can never reach a model.** It runs while the fleet is paused, so the test requires
  every `fleet-paused` job and pause-notice step to hold no model credential, no AI CLI or
  action, no `secrets:` and no `secrets.*` or `github.token` reference, and to blank (`NAME: ''`)
  any credential it would inherit from a workflow-level or job-level `env:`. `permissions: {}`
  does not remove an inherited env value.
- **One registry.** `scripts/lib/fleet-pause-registry.tsv` records the decision for each workflow:
  gated (which jobs or steps), a thin caller of a gated reusable, exempt (with the reason),
  exempt although it holds a credential (with the reason it makes no model call), or
  not paused because the model call lives in another repository. The table below is generated
  from it: `python3 tests/dev-lead/integration/test_fleet_pause_coverage.py --markdown`.
- **The check.** `tests/dev-lead/integration/test_fleet_pause_coverage.py` (CI: the
  `agents-paused-preflight` job in `test-dev-lead.yml`) treats a workflow as **model-calling**
  when, outside comments, a job (1) names a model credential (`CLAUDE_CODE_OAUTH_TOKEN`,
  `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY*`, `GEMINI_API_KEY`, `COPILOT_GITHUB_TOKEN`,
  `OPENAI_API_KEY`); (2) names an AI CLI or action (`@anthropic-ai/claude-code`,
  `@google/gemini-cli`, `anthropics/claude-code-action`), a model CLI call (`claude -p`,
  `gemini -p`, `gh copilot`, `gh models`) or a model API host; (3) runs a script under `scripts/`
  whose own text holds such a call or host; or (4) calls a reusable workflow and hands it any
  secret, by `secrets: inherit` or a `secrets:` mapping, whatever the secrets are called. It fails
  when such a workflow has no registry row; when a registered job or step has lost its
  condition; when a gated workflow gains a second model-calling job, or a step-gated job gains
  an ungated model-calling step; when the notice job is missing, runs on different events, or
  could reach a credential; and when a workflow listed as plain `exempt` starts to match the
  rule. `tests/test_fleet_pause_coverage.bats` holds the mutation cases and fails when this table
  and the registry differ.
- **Known limits of the check.** It reads workflow YAML and, one level deep, the scripts a `run:`
  step invokes. It does **not** see: a model call in a library that a script sources (the engine
  wrapper is reached this way; its callers are caught because the wrapper needs a credential
  only a workflow can hand over); a call that needs no listed credential and is made outside
  rules 2 and 3, such as GitHub Models reached with an ordinary GitHub token from a sourced
  library, a script fetched at run time, or a third-party action; and what a reusable in another
  repository does with the secrets it is given (rule 4 flags the call, and the row records what
  was checked there by hand, with the ref and date). When a new way to reach a model appears,
  add it to `SIGNALS` in the test in the same change.
- **Adding a model-calling workflow.** Copy the `if:` line and the `fleet-paused` job from any
  gated workflow, add a `job-gate` row to the registry, and regenerate this table. Use an `exempt`
  row only for a workflow that must run through a pause, and say why in the row; if the rule
  flags it, the row must be `exempt-credential`, name the flagged jobs, and say why they make no
  model call.

| Workflow | How it is paused | Jobs, steps or reusable | Note |
|---|---|---|---|
| `dev-lead-reusable.yml` | Job condition, no notice | `dispatch,ci-relay,resume` | The original gate (#1525). No notice job: a contract test requires every job of this reusable to carry the condition, and a notice job would start a runner for every event in every consumer repository during a pause. |
| `pr-review.yml` | Job condition, no notice | `review` | Reusable. A job condition, because the AGENTS_PAUSED branch of validate-engines.sh is not enough: with Claude as the primary engine, review-batch.sh carries on. No notice job: the canary promotion gate counts a green run as a health sample, so a paused run must end skipped. |
| `persona-runner-reusable.yml` | Job condition | `run` | Runs every persona advisory (qa-lead, the architects and the rest). |
| `ci-failure-analyst-reusable.yml` | Job condition, no notice | `analyze` | Reusable. No notice job, for the same reason as pr-review.yml: the canary promotion gate samples its runs. |
| `gh-aw-cross-org.yml` | Job condition | `dispatch` |  |
| `issue-triage-runner.yml` | Job condition | `triage` | The apply job needs triage, so it is skipped with it. |
| `initiative-planner.yml` | Job condition | `plan` | The redispatch bridge makes no model call and still runs; the run it starts is the one that reports the pause. |
| `idea-triage.yml` | Job condition | `triage` |  |
| `spec-drift.yml` | Job condition, no notice | `spec-drift` | Opt-in and off by default. No notice job: its contract test requires every job to hold issues: write and the workflow to cost nothing when it does not run. |
| `dependency-advisory.yml` | Job condition | `advisory` |  |
| `docs-health-check.yml` | Job condition | `health-check` |  |
| `readme-refresh.yml` | Job condition | `refresh` |  |
| `release-notes.yml` | Job condition | `release-notes` |  |
| `stale-manager.yml` | Job condition | `stale` |  |
| `skill-eval-report.yml` | Job condition | `eval-report` | The discover job makes no model call and still runs. |
| `model-ab.yml` | Job condition | `model-ab` | Manual dispatch only; paused like the rest, so resume the fleet to run an A/B. |
| `daily-pr-review-health.yml` | Step condition | `health-check:Run health check\|Assert MCP connectivity` | A monitor: the runaway, stall and merge-ready scans make no model call and keep running. The three CLI setup steps are skipped too. |
| `dev-lead-retry.yml` | Job condition | `retry` | No model call. Gated because a sweep records a retry attempt before it dispatches, and a paused dev-lead skips the run, so attempts would be spent on nothing. |
| `pr-review-sweep.yml` | Job condition | `sweep` | No model call. Gated because it would re-dispatch up to 20 reviews every 15 minutes into a paused pr-review. |
| `dev-lead.yml` | Through its reusable | `dev-lead-reusable.yml` |  |
| `pr-review-trigger.yml` | Through its reusable | `pr-review.yml` |  |
| `persona-runner.yml` | Through its reusable | `persona-runner-reusable.yml` |  |
| `ci-failure-analyst.lock.yml` | Through its reusable | `ci-failure-analyst-reusable.yml` |  |
| `feature-ideation.yml` | **Not paused** | `combsmith/.github/.github/workflows/feature-ideation-reusable.yml` | That reusable does not read AGENTS_PAUSED, and this file is a frozen caller stub, so the fix belongs there: combsmith/.github#1295. |
| `budget-breaker.yml` | Exempt |  | Control plane: it sets and lifts the pause, so it has to run while paused. No model call. |
| `budget-poller.yml` | Exempt, holds a credential | `poll` | Control plane. Holds the Claude credential only to read the usage windows (a dry run), and names the CLI package only to look up its version. No model call. |
| `actions-fleet-monitor.yml` | Exempt |  | Monitor. No model call. |
| `engine-token-liveness.yml` | Exempt |  | Monitor. No model call; it reads AGENTS_PAUSED itself to stay silent during a pause. |
| `persona-mention.yml` | Exempt, holds a credential | `persona-mention` | Mention router: hands its secrets to a reusable in combsmith/.github that makes no model call (checked at persona-mention/v1-next, 2026-10-10). It dispatches persona-runner.yml, which is gated. |
| `auto-rebase.yml` | Exempt, holds a credential | `auto-rebase` | Hands its secrets to a reusable in combsmith/.github that makes no model call (checked at auto-rebase/v2-next, 2026-10-10); a conflict goes to dev-lead, which is gated. |
| `dependabot-automerge.yml` | Exempt, holds a credential | `dependabot-automerge` | Hands its secrets to a reusable in combsmith/.github that makes no model call (checked at dependabot-automerge/v2-next, 2026-10-10). |
| `pr-review-mention.yml` | Exempt, holds a credential | `pr-review-mention` | Passes two GitHub tokens to a reusable in combsmith/.github that makes no model call (checked at pr-review-mention/v2-next, 2026-10-10); it dispatches pr-review, which is gated. |
| `pr-auto-review.yml` | Exempt, holds a credential | `pr-auto-review` | Passes a GitHub token to a reusable in combsmith/.github that makes no model call (checked at pr-auto-review/v1-next, 2026-10-10); it dispatches pr-review, which is gated. |
| `dependabot-rebase.yml` | Exempt, holds a credential | `dependabot-rebase` | Passes a GitHub App identity to a reusable in combsmith/.github that makes no model call (checked at dependabot-rebase/v2-next, 2026-10-10). |
| `add-to-project.yml` | Exempt, holds a credential | `add-to-project` | Passes a GitHub App identity to a reusable in combsmith/.github that makes no model call (checked at add-to-project/v1-stable, 2026-10-10). |
| `pr-review-delayed-retry.yml` | Exempt |  | No model call: it re-dispatches through pr-review-sweep.yml, which is gated. |
| `auto-rebase-retry.yml` | Exempt |  | No model call: it re-runs failed Auto-rebase jobs or dispatches dev-lead's rebase intent, which is gated. |
| `initiative-driver.yml` | Exempt |  | No model call: it releases issues to dev-lead by label. Known gap: an issue it labels during a pause is not picked up, because dev-lead skips that event. |

Every workflow not listed makes no model call (the rule above finds nothing in it) and is not
affected by the pause: linters, tests, CodeQL, SonarCloud, reports and the canaries.

**What a pause does not do.**

- **It does not queue work.** An event that arrives during a pause is skipped, not replayed on
  resume. The two timers that re-dispatch work (`dev-lead-retry.yml`, `pr-review-sweep.yml`) are
  gated so they do not spend retry attempts or runner time on skipped runs, and they pick up
  again on their first tick after the pause lifts. An issue labelled `dev-lead` during a pause
  (by a person or by `initiative-driver.yml`) is not picked up afterwards: re-dispatch it as in
  ["Steering dev-lead"](#steering-dev-lead).
- **It does not pause `feature-ideation.yml`.** Its model call is in
  `combsmith/.github/.github/workflows/feature-ideation-reusable.yml`, which does not read
  the variable, and the file here is a frozen caller stub. The fix is tracked in
  [combsmith/.github#1295](https://github.com/combsmith/.github/issues/1295).
- **It is not live in a consumer repository until the channel tag it pins has moved** (see
  ["Merging to `main` does not activate agent code"](#merging-to-main-does-not-activate-agent-code--say-when-it-will-reach-each-channel)):

  | Reusable | Live in consumer repositories when |
  |---|---|
  | `pr-review.yml` | `pr-review/v1-next` moves (this repository's `pr-review-trigger.yml`), then `pr-review/v1-stable` by ring promotion (the standards stub). Repositories still pinning the legacy bare `pr-review/stable` tag need that tag moved too, or a repin |
  | `ci-failure-analyst-reusable.yml` | `ci-failure-analyst/v1-stable` moves (this repository's stub and `templates/ci-failure-analyst.yml` both pin it) |
  | `persona-runner-reusable.yml` | on merge: `persona-runner.yml` calls it by local path, and every persona advisory runs in this repository |
  | `dev-lead-reusable.yml` | unchanged by #2249 |

  Every other gated workflow runs from this repository's default branch and is live on merge.

#### Budget breaker (`budget-breaker.yml`, #2153, slice 3b of #1565)

The same switch is flipped automatically by `.github/workflows/budget-breaker.yml`, which
**ships default off**. It is **reactive**: it pauses the fleet when the fleet itself reports
that the model provider is refusing work for quota, and lifts that pause at the reset time
those refusals report. It does not read the usage endpoint (the fleet's credential cannot,
see #2029), so the dry-run poller below is a separate, read-only report and is not its input.
It is not channel-pinned: it runs the default branch's code, so the disarmed runs start
as soon as the workflow is on `main`.

- **What a run does.** On every wake-up (see "When it runs"), `scripts/budget_breaker.sh` reads
  the pause state, collects the fleet's quota markers (`bb_collect`), decides (`bb_decide`,
  both in `scripts/lib/budget-breaker.sh`, #2221) and applies the decision through
  `scripts/lib/budget-breaker-writer.sh`, the only file that writes the variables:
  - **trip** (at least `BUDGET_BREAKER_MIN_ITEMS` distinct items, default 3, refused for
    quota in the last `BUDGET_BREAKER_WINDOW_MIN` minutes, default 30): sets
    `AGENTS_PAUSE_SOURCE=rate-limit-observed`, then `AGENTS_PAUSE_UNTIL=<ISO time>`, reads
    the state once more (see "A human pause is never touched"), then sets
    `AGENTS_PAUSED=true`.
  - **resume** (its own pause, `AGENTS_PAUSE_UNTIL` passed): sets `AGENTS_PAUSED=false`,
    then deletes `AGENTS_PAUSE_SOURCE` and `AGENTS_PAUSE_UNTIL`.
  - **hold** and **none**: writes nothing. There are two exceptions, both removals of the
    breaker's own values only: the roll-back of a stopped trip, and the removal of leftover
    ownership markers (both described below).

  The order means a failure between two writes never leaves a pause without its source. Only
  dev-lead's three quota markers count; pr-review's `rate-limited` marker (an advisory
  reviewer bot out of quota) never does, and the workflow cannot opt it in.
- **When it runs (#2259).** The workflow has exactly two triggers, and a test rejects any
  other:
  - `workflow_run`, type `completed`, for three workflows of **this repository**, matched by
    their `name:`: "Dev-Lead Agent" and "GitHub Agentic Workflows — Cross-Org Dispatcher"
    (the two that run the scripts that post a dev-lead quota marker), and "Dev-Lead Retry
    (rate-limited)" (it posts no quota marker; it is one more wake-up, every few hours,
    that does not depend on agent traffic). A rename would silently unhook the trigger, so
    a test requires every listed name to be the `name:` of a workflow file here.
    pr-review's workflows are not listed: its marker is not quota evidence.
  - `schedule`, every 10 minutes, as the backstop. GitHub delivers few of these ticks in
    this repository: after the workflow merged on 2026-10-11 at 01:55 UTC, two arrived in
    the first 13 hours (08:35 and 15:03 UTC, of about 79 slots).

  **Why `workflow_run` still runs only default-branch code.** GitHub's documentation
  ("Events that trigger workflows", read 2026-10-11) says of it: "This event will only
  trigger a workflow run if the workflow file exists on the default branch.", and lists
  `GITHUB_SHA` as "Last commit on default branch" and `GITHUB_REF` as "Default branch". The
  checkout has no `ref:`, so that commit is what it checks out. The same page says: "The
  workflow started by the `workflow_run` event is able to access secrets and write tokens,
  even if the previous workflow was not." So the property holds **only while the job never
  uses anything from the run that triggered it**. Anyone who can make a listed workflow's
  run complete here (a comment on an issue, a pull request from a fork, a pull request that
  adds a workflow carrying a listed name) chooses when the breaker runs and what the event
  payload says. They choose nothing else: the workflow file does not reference the event
  context anywhere, the checkout has no `ref:` and no `repository:`, no artifact is
  downloaded, and the script reads the event's name and nothing else of it. More runs
  cannot cause a pause (a trip needs quota markers from trusted authors) and cannot run in
  parallel (one concurrency group).

  **`workflow_run` sees this repository only.** An agent run in another repository of the
  organisation does not wake the breaker. Its quota markers are read by the next run,
  whatever woke it; if none comes within the 30 minute window they have aged out and are
  never acted on.

  **No filter on the triggering run's conclusion.** About half of the Dev-Lead Agent runs
  here end `cancelled` in their lane within seconds, and the breaker runs for those too.
  Skipping them with a job-level `if:` would need the event context, and it is not known
  to be safe: the concurrency group keeps one pending run and the newest arrival replaces
  it, and GitHub does not document whether a run whose only job is skipped still takes
  that place. If it does, a run that only skips replaces a waiting one that carries news.
  The cost is bounded instead by the group (one run at a time and at most one waiting; a
  replaced run loses nothing, because the run that replaced it starts later and reads the
  same state) and by the early exit below. Measured on 2026-10-11: 988 Dev-Lead Agent runs
  completed in 13.4 hours; replayed against the group that is about 630 breaker runs (47
  an hour), each a job of 8 to 10 seconds.

  **The early exit.** A run woken by `workflow_run` on a fleet that is **not paused** exits
  before the organisation scan when both hold: an earlier run of this workflow that
  succeeded was created in the same clock slot of `BUDGET_BREAKER_MIN_INTERVAL_MIN` minutes
  (default 10; `0` switches the early exit off; a failed run covers nothing, because it may
  have ended before its scan), and this repository shows no quota marker created in that
  slot (one listing instead of one per repository). It is slots, not "the previous run
  finished less than N minutes ago", because a run that exits early is itself a previous
  run: under a steady stream of wake-ups that rule would exit early for ever, while the
  first run to look in a slot always decides. The earlier runs are listed with the read
  credential (the repository is public, so the workflow's `permissions:` are unchanged).
  The default was two minutes when the trigger was added and was raised to ten after the
  first 84 minutes of real runs (2026-10-11): 309 runs were created, 115 executed, and a slot
  of two minutes meant up to 30 organisation scans an hour on the maintainer login's shared
  API quota. With ten, event wake-ups cause at most 6. A scheduled run always scans, so each
  scheduled tick that is delivered adds one (up to 6 more an hour; two were delivered in the
  first 13 hours). A quota marker posted in this repository still
  makes the next run decide at once; one posted only in another repository is read by the
  first run of the next slot, so up to ten minutes later.
  The early exit never applies to a scheduled run, never while the fleet is paused by
  anyone (so it cannot delay a resume), and never when the earlier runs, the slot or this
  repository's markers could not be read: then the run decides. Its one cost: a marker
  posted in **another** repository in a slot that already had a run is read by the first
  run of a later slot.

  Every run logs `triggered by: schedule|workflow_run` and
  `previous run: finished <time> (<conclusion>), N min before this one`, and shows both in
  its summary, so poor delivery of either trigger is visible.
- **How fast it reacts, and how late it can resume (#2259).** All figures are from this
  repository on 2026-10-11 unless dated otherwise; none is a guarantee by GitHub.
  - **Trip, marker posted in this repository.** The run that posts the deciding marker
    ends seconds after posting it, with the conclusion `success` (run 37472943876 on
    2026-10-06: marker at 13:44:15 UTC, run completed at 13:44:24), and its completion wakes
    the breaker. From that completion:
    delivery of the event (1 to 3 seconds: the 8 `workflow_run` deliveries to "Auto-rebase
    retry" checked, 2026-09-19 to 2026-10-10), plus at most one breaker run already under
    way (a job of 8 to 10 seconds), plus the wait for a runner (3 seconds for run
    38125345031, 144 seconds for run 38149673170), plus the job itself. That is under a
    minute when a runner is free and a few minutes when the job cap is full. The early exit
    does not hide such a marker. The quota bursts this has to catch are short: on
    2026-10-06, nine pull requests were refused within 96 seconds (13:44 UTC) and fourteen
    within 98 seconds (15:18 UTC).
  - **Trip, markers only in other repositories, or no agent run completing here.** The next
    wake-up of any kind. With agent traffic here that is seconds to minutes (the gap
    between Dev-Lead Agent completions: median 8 seconds, 95th percentile 71 seconds), but
    the same 13.4 hours contain a gap of 2 hours 54 minutes. With no traffic it is the next
    delivered scheduled tick: the two delivered so far were 6.5 hours apart. **There is no
    upper bound**, and evidence older than the window is not acted on.
  - **Resume.** The breaker lifts its pause at its first run after `AGENTS_PAUSE_UNTIL`
    (and after the minimum hold). During a pause three things wake it. (1) Any event that
    starts Dev-Lead Agent here: the paused run ends `skipped` within seconds, and GitHub
    documents that "A workflow run is triggered regardless of the conclusion of the
    previous workflow." This has been seen here for `cancelled` runs, not yet for
    `skipped` ones (arming precondition 6). How often such events arrive during a pause
    is not measured: most of today's traffic is the fleet's own, which a pause stops.
    (2) A delivered tick of the retry sweep, whose run completes whether paused or not:
    over its last 100 scheduled runs the gap was 5.8 hours at the median and 8.9 hours at
    the longest. (3) A delivered tick of the breaker's own schedule (above). So the resume
    follows the end time by seconds to minutes while people or other tools are active in
    this repository, and **by hours when it is quiet: up to about 9 hours on these
    measurements, with no guaranteed bound.** To end a pause sooner, lift it by hand
    ("Overriding a breaker pause by hand").
- **Default off, twice.** Nothing is written unless the repository variable
  `BUDGET_BREAKER_ARMED` is **exactly** `true` (absent, `TRUE`, `1`, `yes` all mean off)
  **and** the secret `BUDGET_BREAKER_PAT` is set. Disarmed, every run still decides and logs
  `NOT WRITING (disarmed). Would have written: ...`, which is the dry-run evidence to review
  before arming. Armed without the secret, it logs
  `breaker armed but BUDGET_BREAKER_PAT is not configured` and exits green.
- **Only lowercase `true` arms (#2251).** The script compares the variable with the exact
  string `true`. `TRUE`, `True`, `true` with a space before or after it, `1`, `yes` and `on`
  do **not** arm it. The ordinary ways to be disarmed are the exact string `false`, an empty
  value, or no variable at all: none of them logs anything about the value. Any **other**
  value that is not exactly `true` (`TRUE`, `1`, `yes`, `False`, a padded `true` or `false`)
  keeps the breaker disarmed **and** logs one `::error::` line on every run
  (`BUDGET_BREAKER_ARMED is set to "...", which is neither the exact lowercase string true
  nor the exact lowercase string false`), in a run that still exits green. The reason this
  is an error and not a silent off: the workflow hands the write credential to the step
  with an Actions expression, and an expression compares strings without regard to case, so
  `TRUE` or `True` delivers the credential to a run that will not use it. That cannot be
  fixed in the expression. The script drops the credential unused and says so in the error;
  fix the variable (set it to `true` or to `false`) rather than leave the error standing.
- **A human pause is never touched.** The breaker sets and lifts only a pause that carries
  `AGENTS_PAUSE_SOURCE=rate-limit-observed`. `AGENTS_PAUSED=true` with no source, or with any
  other source, is left exactly as it is, by trip and by resume. A writing run also re-reads
  the state immediately before its first write and writes nothing if it changed.
- **A pause set by hand during a trip is not claimed (#2251).** A trip writes the source and
  the until, then reads the state a **second** time before it sets `AGENTS_PAUSED`. If the
  fleet is by then paused by anyone, or the state is in any other way not what the run left
  (for example someone deleted the source), the run does **not** set the pause, posts no
  notice, deletes the `AGENTS_PAUSE_SOURCE` and `AGENTS_PAUSE_UNTIL` it wrote (the source
  first), sets nothing else, and raises a `::warning::` in a green run. This roll-back is the
  only write a run makes outside its plan, and it removes only what the same run wrote and
  that still holds the value it wrote. Two limits to know:
  - The window is narrowed, not closed: a pause set by hand in the one API call between that
    second read and the write of `AGENTS_PAUSED` is still claimed. To be sure a pause set by
    hand stays, check afterwards that `AGENTS_PAUSE_SOURCE` is absent, and delete it if not.
  - If the roll-back itself fails, the run is red with one `::error::` that says what is
    left. A failed delete of the source leaves `AGENTS_PAUSE_SOURCE=rate-limit-observed`
    **and** `AGENTS_PAUSE_UNTIL` in place on purpose (a pause carrying the breaker's source
    with no end time would be lifted by the very next run; with its end time it stands at
    least until then): delete `AGENTS_PAUSE_SOURCE` by hand to keep the pause. A failed
    delete of the until leaves a human pause plus a leftover until, which has no effect.
- **Leftover ownership markers are removed (#2251).** `AGENTS_PAUSE_SOURCE=rate-limit-observed`
  on a fleet that is **not** paused is left over: from a trip that failed before it set the
  pause, or from a pause someone ended by hand without deleting the source. While it is
  there, a pause set by hand reads as the breaker's own and the breaker would lift it. An
  armed run that finds one deletes `AGENTS_PAUSE_SOURCE`, then `AGENTS_PAUSE_UNTIL` if there
  is one, straight after reading the state, raises one `::warning::` (`leftover ownership
  markers from an earlier run were removed`) and does nothing else: that is the run's one
  state change, so the same run neither scans the fleet nor trips, and the next run decides
  normally. Next to the roll-back above, this is the one further exception to "none writes
  nothing". It removes only the breaker's own value: a source with any other value, and an
  until with no source of the breaker's, are left alone, and so is everything on a fleet
  that is paused. A delete that fails is one `::error::` and a red run with no retry. A run
  that is not armed logs `Would have written: delete AGENTS_PAUSE_SOURCE; ...` and a
  `::warning::` asking for the markers to be deleted by hand. One window remains: a pause
  set by hand **while** the leftover source is still there, before the next armed run, is
  indistinguishable from the breaker's own; the removal shortens that to at most the gap
  between two runs.
- **The secret.** `BUDGET_BREAKER_PAT` is a **fine-grained personal access token** whose
  resource owner is the `combsmith` organisation, with the **organisation permission
  "Variables: read and write"** and nothing else (no repository permissions). It is an
  Actions secret of **this repository only**. It is referenced in `budget-breaker.yml` and
  nowhere else (a static test enforces that), is handed to the step only when armed, and is
  used only for the organisation-variable calls. Never add it to another workflow, and never
  widen `GH_PAT_DON_PETRY` to do this job.
- **Arming preconditions (#2251). Do not arm until every one of these holds.**
  1. "Budget breaker: close the gaps found in review before it is armed" (#2251) is closed.
  2. "AGENTS_PAUSED stops only dev-lead" (#2249) has landed: until then a pause set by the
     breaker stops dev-lead's dispatch, relay and resume jobs and nothing else.
  3. The five live checks below are recorded on "Auto-pause companion" (#1565), each with
     the date and what was observed. They are mocked in the tests and must be confirmed
     against the real API by the maintainer, with a **throwaway organisation variable**
     (for example `BUDGET_BREAKER_PROBE`), **never** with `AGENTS_PAUSED`,
     `AGENTS_PAUSE_SOURCE` or `AGENTS_PAUSE_UNTIL`:
     - a value-only `PATCH` of an organisation variable keeps its visibility;
     - a `PATCH` updates the variable's `updated_at` (the minimum hold is measured from it);
     - the variable list paginates as the code expects: `gh api --paginate` on
       `orgs/combsmith/actions/variables?per_page=30` with a `--jq` filter returns every
       variable when there are more than 30 (the filter runs once per page);
     - the dedicated write credential can read, create, update and delete an organisation
       variable, and nothing else;
     - with the read credential the workflow uses, dev-lead's quota markers read as trusted:
       the run log and summary report `quota markers read: N trusted, M dropped as
       untrusted`; confirm a real marker is counted as trusted.
  4. A full weekly window of disarmed runs has been reviewed (#1565 criterion 9): the
     `Would have written` lines and the job summaries, with no `::error::` about the arming
     value.
  5. The secret `BUDGET_BREAKER_PAT` is set.
  6. The event trigger (#2259) has been seen working in disarmed runs, recorded on #1565
     with the run ids: a run with `triggered by: workflow_run` whose `previous run:` line
     shows a time (the read credential can list the workflow's runs); and a Budget Breaker
     run that starts within seconds of a Dev-Lead Agent run that ended `skipped`, which is
     what a resume relies on. The second is visible without a pause: Dev-Lead Agent runs
     end `skipped` every day (61 in 13.4 hours on 2026-10-11).
- **Arming.** With the preconditions met, set the repository variable
  `BUDGET_BREAKER_ARMED` to `true`, lowercase, with no space around it, and check that the
  next run logs `mode: armed` and no `::error::`. The first trip creates the three
  organisation variables with the visibility of `AI_ENGINES`, read from the API (an existing
  `AGENTS_PAUSED` is the reference instead, and is updated in place without touching its
  visibility). The breaker supports the visibilities `all` and `private` only: it does not
  copy a repository selection. If the reference is visible to selected repositories only, or
  none exists, the run fails with one error before writing anything; create `AGENTS_PAUSED`
  (value `false`) by hand, visible to all repositories.
- **Disarming.** Set the repository variable `BUDGET_BREAKER_ARMED` to `false`, or delete
  it. (Any other value that is not exactly `true` also disarms, but logs the `::error::`
  described above on every run.) This stops further writes; it does not lift a pause that
  is already set (see the next point).
- **Overriding a breaker pause by hand.** To **keep** the fleet paused past the breaker's
  time, delete `AGENTS_PAUSE_SOURCE` (leave `AGENTS_PAUSED=true`): the pause is then a human
  one and automation never lifts it. To **end** a breaker pause early, set
  `AGENTS_PAUSED=false` **and delete `AGENTS_PAUSE_SOURCE`**; if the provider is still
  refusing work the next refusals trip it again, so disarm first if you want it to stay up.
  To hold the fleet paused regardless of the breaker, set `AGENTS_PAUSED=true` **without**
  `AGENTS_PAUSE_SOURCE` (the manual path). Ownership is the source and nothing else: a
  `AGENTS_PAUSE_SOURCE=rate-limit-observed` left behind on an unpaused fleet makes the next
  pause set by hand look like the breaker's, so the next armed run removes it (see "Leftover
  ownership markers are removed"); a run that is not armed raises a `::warning::` asking for
  it to be deleted by hand.
- **Anti-flap.** One decision and at most one state change per run; a variable that already
  holds the wanted value is not written again; a resume waits until the pause has stood for
  `BUDGET_BREAKER_MIN_HOLD_MIN` minutes (default 30). The hold is measured from the
  `updated_at` the API reports for `AGENTS_PAUSED`. If an armed run cannot use that time
  (missing, malformed, or later than now), it does not skip the hold: it raises a
  `::warning::` and measures the hold from the pause's own end time (`AGENTS_PAUSE_UNTIL`)
  instead, which is the latest moment the pause can have been set. A bad timestamp therefore
  delays a resume by at most the minimum hold after the end time (three scheduled ticks at
  the defaults) and can never block it; nothing is remembered between runs. If the end time
  cannot be read either, the resume goes ahead.
- **Fail open.** A collector that could not read, an unreadable state, or a decision that
  does not fit the state all mean no write. Missing data never pauses the fleet.
- **Failure is loud once.** A refused credential (401, 403 or 404 on the state read) or any
  failed write is **one** `::error::` naming the token and the permission, a red run, and no
  retry. The message lists what was written before the failure. After such a run, check the
  three variables: an `AGENTS_PAUSE_SOURCE=rate-limit-observed` left behind while the fleet
  is not paused is removed by the next armed run, but until that run a pause set by hand
  would look like the breaker's own and be lifted, so delete it by hand if you are about to
  pause by hand. A trip that failed part-way is therefore completed two runs later, not one:
  the next run removes the markers and the one after decides again.
- **Notification.** One comment when the breaker trips and one when it clears, on a single
  tracking issue in this repository ("Budget breaker: automatic fleet pauses (tracking)",
  created on first use, labelled `budget-breaker` and `dev-lead:hands-off`). If the comment
  cannot be posted the run fails, so a pause is never silent.
- **A pause notice that failed is posted late, once (#2251).** Every pause notice starts
  with a hidden marker carrying the pause's end time. A run that **holds** the breaker's own
  pause, while `AGENTS_PAUSED` was set less than 60 minutes ago (or when that time cannot be
  read), looks for a comment with that marker on the tracking issue and, if there is none,
  posts a "late notice" with the same marker. The next run finds it, so it is posted once.
  This writes no variable. If the look-up or the late notice fails, that run is red with one
  `::error::` too. After the first hour the breaker stops looking, so a pause whose notice
  never got through in that hour is announced only by those red runs. A failed **resume**
  notice is not posted late: the fleet is already running and the red run is the signal.
- **Which credential reads.** The collector trusts a marker only when its author reads as
  OWNER, MEMBER or COLLABORATOR, and GitHub reports that relative to the token doing the
  read. The scan therefore uses the fleet's read credential
  (`GH_PAT_DON_PETRY || GH_PAT_WORKFLOWS`, the same one the retry cron and the fleet monitor
  scan with), never the write secret and never this repository's workflow token. Each run
  logs `quota markers read: N trusted, M dropped as untrusted`; when every marker was
  dropped it raises a `::warning::`, because with that credential the breaker can never trip.
- **Token rotation.** The token has no expiry, so rotation is a manual policy: **every 90
  days**, and at once if it may have leaked. Steps: (1) create a new fine-grained token with
  the same resource owner and the same single permission; (2) update the `BUDGET_BREAKER_PAT`
  secret of this repository; (3) verify a read: `GET /orgs/combsmith/actions/variables`
  answers 200 with the new token (an armed run does exactly this, and logs
  `pause state from organisation API` with no `::error::`); (4) revoke the old token. Each
  run logs the secret's age (`age of BUDGET_BREAKER_PAT: last updated N day(s) ago`) and
  raises a `::warning::` once it is older than 90 days.
- **Tuning** (repository variables, all optional): `BUDGET_BREAKER_MIN_ITEMS`,
  `BUDGET_BREAKER_WINDOW_MIN`, `BUDGET_BREAKER_PROBE_HOURS` (the pause length when no reset
  time is known, default 2), `BUDGET_BREAKER_MIN_HOLD_MIN` and
  `BUDGET_BREAKER_MIN_INTERVAL_MIN` (the early exit's slot, default 10, `0` for off). Keep
  the minimum hold at or above the window: otherwise the markers that caused a pause can
  still be inside the window when it lifts.
- **Guard rails for editors.** The workflow's triggers are `schedule` and `workflow_run`
  and nothing else, on purpose: do not add `workflow_dispatch`, `pull_request`, `push` or
  any other trigger (a manual or event run can execute branch code, and the job holds a
  credential that can pause every repository). Do not make it read the run that triggered
  it: no reference to the event context anywhere in the file, no `ref:` or `repository:`
  on the checkout, no artifact download, no `actions/github-script` (see "When it runs").
  Do not widen its `permissions:` (`contents: read`, plus `issues: write` for the notice).
  Tests: `tests/dev-lead/unit/test_budget_breaker_writer.bats`.

The telemetry adapter (`scripts/lib/usage-telemetry.sh`) and the dry-run poller described
below still ship; the poller writes nothing and has no access to the breaker's secret.

### Gemini quota metering & per-key cooldown (#2030)

Gemini is the fallback the fleet degrades to when the Claude budget trips. Its quota
is checked from the fleet's **own token ledger**, not by a provider probe. The goal
is to keep degrading from moving the outage onto an unmetered provider.

- **Caps are data.** `scripts/lib/gemini-quota-caps.tsv` (next to `model-pricing.tsv`)
  holds one row per key index × model: `tier`, `rpm`, `tpm`, `rpd`. It also holds the
  `daily_reset_time` / `daily_reset_tz` and `default_cooldown_sec` settings.
  Never hard-code a Gemini limit in a script.
- **The shipped caps are self-imposed (#2146).** They are not Google's limits for
  these keys. They equal Google's Free Tier limits and are the same for key indexes
  1 to 4:
  - `gemini-3.8-flash`: 5 requests/minute, 250000 tokens/minute, 20 requests/day;
  - `gemini-3.1-pro-preview`: 0 on every window, so Pro is never called. A tier whose
    first choice is Pro (deep, audit, single) runs on its Flash fallback.

  Each key holds $1 of prepaid credit, paid once. Google's real Tier 1 limits are far
  higher, so metering against them would make the keys look healthy until the money
  is gone. The numbers are a maintainer decision and change only by a reviewed PR;
  nobody measures them by calling the Gemini API. A row set back to `unknown` is
  treated as constrained again.
- **Keys are named by index only:** `1` is the primary slot
  (`GEMINI_API_KEY` / `GOOGLE_API_KEY`; a `GOOGLE_API_KEY` holding a different
  credential is `1b`) and `N` is `GOOGLE_API_KEY_N`. A key value
  never appears in a log, a ledger record, or cooldown state.
- **Metering.** Gemini token records from calls that go through configured API-key rotation carry the
  `key_index` that served them; calls with no configured API key bypass rotation and do not record `key_index`.
  `check_provider_headroom gemini` (`scripts/lib/gemini-quota.sh`) sums the ledger (`GEMINI_LEDGER_FILE`, default
  `TOKEN_LOG_FILE`) per key over three windows: the last minute (requests and
  tokens) and the current day (requests, counted since the configured reset, or a
  rolling 24h while the reset is unknown). Each sum is compared with its cap. The
  call makes no network request.
- **Result.** `0` means some key is below `DEV_LEAD_USAGE_THRESHOLD`.
  `1` (skip) means every key is metered and at or above the threshold.
  `2` (**constrained**) means the limits are unknown, a key has no caps row, or the
  ledger is unreadable or corrupt.
  A caps row with a cap of 0 excludes that model on the key (#2041), so the gate leaves
  the row out of the key's percent (#2146): with Pro at 0, a key is judged on Flash
  alone. A key whose every row has a cap of 0 has nothing left to run and reads 100%.
  `2` is deliberately **not** fail-open, unlike Claude's probe. It logs a
  `::warning::` naming `limits unknown` or `ledger unreadable` and never prints
  the `ok` line. The engine still runs on `2`, because refusing to degrade onto a
  constrained Gemini is the actuation follow-up (after #2029). Rotation tries
  constrained keys after keys with measured headroom.
- **Cooldown memory.** When a key rate-limits or returns `RESOURCE_EXHAUSTED`, the
  rotation appends a `kind:"gemini_key_cooldown"` record (`key_index`, `model`,
  `until`) to the same ledger. The deadline comes from the error's retry hint
  (`retryDelay` / "retry in Ns"), or from `default_cooldown_sec` if the error gives
  none. Later calls in the same job, which read that ledger, skip the key on that model
  until the deadline. **Scope:** the ledger defaults to the per-job `TOKEN_LOG_FILE`
  (`/tmp/token-usage-${run_id}.jsonl`), so cooldown and metering state does **not**
  yet persist across jobs; a new job starts metering from zero. Cross-job persistence
  (#2030 scope item 3) needs the fleet-state mechanism and is a follow-up. If every
  key on a model is cooling down, no call is made, and the
  chain moves to the next model and then to the cross-provider fallback. These
  records share the Token Observatory channel, and cost reports count only
  `token_usage` records.
- **Visibility.** `scripts/token_report.sh` (fleet monitor and the weekly digest)
  renders a **Gemini quota (per key index)** section next to the per-model usage.
  It shows the peak requests/min, tokens/min, and requests/day against each cap,
  plus the cooldowns recorded.

**Dry-run budget poller (shipped, #2029: slice 2 of #1565). It is dry-run only and has no
write path.** `.github/workflows/budget-poller.yml` runs on two hourly cron slots (`:17` and `:47`) with read-only `permissions:` (`contents: read`, `actions: read`).
It is schedule-only (no `workflow_dispatch`). The second slot exists because GitHub delivers only about 40% of
scheduled ticks in this repo (#2160); the `budget-poller` concurrency group keeps the slots from overlapping.
It authenticates with the existing `CLAUDE_CODE_OAUTH_TOKEN` secret. It does **not**
set, clear, or write any Actions variable (org or repo) under any input, and there
is no flag to make it do so. `tests/dev-lead/unit/test_budget_poller.bats` asserts
that statically. Arming (the write, auto-resume, the trip notification) stays under #1565
pending the pause-vs-degrade decision.
- **What it does** (`scripts/budget_poller.sh` + `scripts/lib/budget-poller.sh`):
  reads the envelope via `scripts/lib/usage-telemetry.sh`, publishes it on the
  existing `AGENT_TOKEN_BUDGET_TELEMETRY_FILE` seam, and evaluates the shipped public
  `arl_token_budget_gate session` and `arl_token_weekly_glide_gate`. It checks the
  public library and config out of `combsmith/.github@main`. The public config
  ships the glide breaker inert (`weekly_all.enabled=false`), so the glide gate is
  evaluated against a **temp armed copy** of that config. The decision therefore
  says what the breaker *would* do. The real arm state is recorded as
  `weekly_glide_config_enabled`.
- **Where the log lives:** each run appends one JSON line to `budget-poller-log.jsonl`
  and uploads it as the **`budget-poller-log`** artifact (14-day retention). Each run
  downloads the previous artifact first, so the newest artifact holds the rolling
  history (bounded to 720 records ≈ 15 days at two slots an hour). The run's **job summary** shows the same
  record as a table.
- **How to read it:** each record carries `ts`, `http_status`, `retry_after`,
  `session_pct`, `weekly_all_pct`, both windows' `*_resets_at`, `session_decision`,
  `weekly_glide_decision` (`allow`/`defer`/`unavailable`), `would_pause`,
  `decision_window` (`session` / `weekly_all` / `session,weekly_all` / `transport-429` / `none`),
  `decision_pct`, and `burn_session_pph` / `burn_weekly_all_pph`. The burn fields
  are percentage points per hour against the previous OK record and are logged only.
  They are `null` on the first-ever poll or when the window reset in between, and
  no gate uses them. Liveness is greppable:
  `telemetry read OK, session=N% weekly_all=M%` on success, and
  `telemetry read DEGRADED, status=S reason=R` on any failure (`transport-error`,
  `http-<status>`, `malformed-body`, `public-library-unavailable`). A degraded
  poll is a `::warning::`, never a red run (fail-open), and never reads as OK.
  Example: `jq -c 'select(.poll=="ok") | [.ts,.session_pct,.weekly_all_pct,.decision_window]' budget-poller-log.jsonl`.
- **Measured delivery (#2160):** each record also carries `trigger_event` (`GITHUB_EVENT_NAME`),
  `trigger_cron` (the cron that fired, from `github.event.schedule`), `scheduled_for` /
  `scheduled_epoch` (the `:17` or `:47` slot the run was meant for), and `start_delay_s`
  (poll time `ts` minus that slot). A delay over an hour aliases onto a later slot, so it is a
  lower bound. Records written before #2160 lack these fields and still parse. Example:
  `jq -c '[.scheduled_for,.ts,.start_delay_s,.trigger_cron]' budget-poller-log.jsonl`.
- **Fleet monitor:** `scripts/fleet_monitor.sh` reads the newest `budget-poller-log`
  artifact and adds a **Budget poller (dry-run)** section to its report. The section shows
  the age of the last OK record, the latest record, the dry-run decision (window and
  percent), and the burn rate. It also shows the runs received in the last 24 hours against
  the 48 expected, with the median start delay. When the last OK record is older than
  `BUDGET_POLLER_STALE_HOURS` (default **6**), or there is none, it raises a
  `::warning::`. **Why 6 hours:** at about 40% tick delivery, a gap of more than 3 hours is
  routine, so a 3-hour window would raise false alarms much of the time. The weekly window
  moves slowly, so a 6-hour-old reading is still meaningful. A stale record still fails open:
  a consumer that finds no fresh record proceeds as if there were no reading.

### Gemini availability per task tier (#2041)

Slice 2 of the metering. It shows what Gemini capacity is **left**, so you can see that a
capped model blocks a tier **before** that tier's work runs and fails. It uses the same
ledger and caps file (`scripts/lib/gemini-quota.sh`). It gates and defers nothing: acting
on it is the follow-up actuation work.

- **Remaining capacity** (`gq_remaining <key> <model>`) is computed for the current
  windows. The day window runs from the configured reset (Pacific midnight) to the next
  reset, counted by local calendar day, so a DST change day lasts 23h or 25h. The minute
  window is rolling. The states are checked in this order:
  - `unavailable`: a cap is 0;
  - `unknown`: no caps row, a limit is not filled, or the ledger is unreadable;
  - `exhausted`: requests today are at or above the daily cap, until the reset;
  - `cooling`: there is an active cooldown, or the minute window is full, until it ends;
  - `available`: N requests are left today.

  Remaining values are never negative.
- **Tier view** (`gq_tier_view`). Each tier (triage, action, deep, audit, single, duck)
  takes its chain from `ai_models_gemini_chain`; the tier code names no model. The view
  walks the chain in order and stops at the first model that decides the status:
  - first model has a usable key: `available`;
  - a later model has a usable key: `degraded`, and `degraded_to` names that model,
    because it is a quality change;
  - a model with an `unknown` key comes before any usable model: `unknown`;
  - no model is usable and none is unknown: `unavailable`.

  The view also lists the usable (model, key index) pairs and the total remaining calls.
- **Snapshot and history.** On every fleet-monitor run, `scripts/gemini_tier_report.sh`
  does the following:
  - It merges the Gemini records that `token_report.sh` collected (`GEMINI_RECORDS_OUT`)
    into a history store. The store persists across runs through `actions/cache`, has
    duplicates removed, and keeps today plus `history_days` previous days
    (`GEMINI_HISTORY_DAYS`, default 7).
  - It writes `snapshot.json`, which follows `scripts/lib/gemini-tier-snapshot.schema.json`
    and holds key indexes only. The snapshot is uploaded as the `gemini-tier-snapshot`
    artifact. The dry-run poller (#2029) asks "can tier T run on Gemini now?" by calling
    `gq_tier_can_run <snapshot> <tier>`.
  - It renders the report. The report has the tier table, remaining capacity per key and
    model with the ledger count, and a per-Pacific-day matrix. The matrix columns are
    calls, rejected attempts, peak per minute, rate-limit events and whether the cap was
    hit. The report ends with the redacted rejection messages.
  - It emits one `::warning::` per tier that is `degraded` or `unavailable`, at most once
    per tier per Pacific day. A `gemini_tier_notice` record in the store prevents repeats.
- **Only records from trusted runs (#2147).** A token-usage artifact is untrusted input: a
  pull request from a fork runs the fork's copy of a workflow and can upload an artifact of
  any name and content, and a record says nothing about its origin but a run id it wrote
  itself. `scripts/token_report.sh` decides trust from the Actions API, never from the
  artifact:
  - **trusted:** the uploading run's head repository is the repository itself, and either
    the run was on the default branch (read from the artifact listing's `workflow_run`, no
    extra call), or the run, looked up, confirms the head repository and was not started by
    Dependabot. These are the runs GitHub gives the repository's secrets to.
  - **not trusted:** a fork run, a Dependabot run, an artifact with no `workflow_run`, and a
    run that cannot be looked up or does not match. A look-up that *failed* (timeout, 403,
    rate limit) is also counted as a failed read (`run_lookups_failed`), because that run
    may have been a trusted one.

  Every collected record is stamped `provenance: {run_id, trusted, basis}`, replacing
  anything the artifact wrote under that name. Only trusted records are handed to the tier
  report. The ignored ones are counted in the log, in a `::warning::` and in the job summary
  ("Gemini ledger provenance"). The cost report is not filtered. The history cache was
  renamed (`gemini-tier-history-v2-`), so nothing collected before the filter is restored.
- **The snapshot is not yet a basis for a dispatch decision (#2147).** A forged record can
  only make a tier look less available. Usage that is missing, or records that are not real
  calls, are the other half, and the snapshot records both in `collection`:
  - **Missing usage** makes a tier look *more* available: a repository listing, an
    artifact, a run look-up or a record file that could not be read (each is counted, and
    any of them makes `collection.complete` false), or simply the time since the snapshot
    (it is written once a day, at 06:27 UTC, shortly before the Pacific reset).
  - **Test fixtures are in the real ledger.** An agent session that runs this repository's
    engine tests passes them the job's `TOKEN_LOG_FILE`, so the tests append their fixture
    calls, rejections and cooldowns to the ledger the job then uploads. They arrive from a
    trusted run and some look exactly like real calls. The collector counts the visible
    part (`gemini_records_unlisted`: records for a key index and model the caps file does
    not list) and raises a `::warning::`. The fix belongs at the source (tests must not
    inherit the ledger path); until then the tier view over-counts Gemini usage.

  A dispatch decision must read the snapshot with
  `gq_tier_decision <snapshot> <tier> [max_age_sec]`, not `gq_tier_can_run`. It answers
  `unknown` (return 2: do not start the work) when the snapshot is unreadable, older than
  the limit (default 3600 s, `GEMINI_DECISION_MAX_AGE_SEC`), for a quota day that is over,
  not marked `trusted-runs-only`, or built from a collection that was incomplete or held
  unlisted records. Nothing calls it yet. Tests: `tests/token_report_trust.bats`.
- **Rejected attempts count.** Google counts rejected calls against the limits. So a call
  rejected as rate-limited or quota-exceeded appends a `kind:"gemini_attempt"`
  (`rejected:true`) record, which holds the key index, model and timestamp only. Metering
  counts these as requests. Each distinct rejection message is also kept once, redacted,
  as `kind:"gemini_rejection_sample"`, so the report shows what Google actually sent.
- **Escalating cooldown** (`gq_escalated_cooldown`). The first rejection waits for the
  retry hint, or `default_cooldown_sec` if there is no hint. The cooldown then doubles for
  each consecutive rejection of the same key and model, up to the next Pacific reset. A
  success, or the daily reset, restarts the streak. If the ledger already shows the daily
  cap reached, the cooldown runs straight to the reset. If the error text has Google's
  documented daily wording (`quota_exceeded`, "daily quota"), it is also treated as daily
  and cools to the reset. Any other text is treated as per-minute. No error-body format is
  relied on.
- **Rotation drops keys that cannot run.** For the model being called,
  `gq_rotation_plan` reports a key that is `unavailable` (cap 0), `exhausted`, or
  `cooling` (its rolling minute is full, until a stated time) as `skip`, with the
  reason, and does not call it. The same key is still used for another
  model it has capacity for. Keys that are only over the threshold, and `unknown` keys,
  are still tried last; an unfilled caps file never becomes a hard block. If every key is
  dropped, the rule for "all keys cooling down" applies and the chain moves to the next
  model.
- **Known limitation.** All of this comes from the fleet's own ledger. The ledger cannot
  see other use of the same Google project, such as manual use, AI Studio or other tools.
  It also misses any rejected attempt that was not recorded. So the AI Studio viewer can
  show more usage than the ledger count. The report says so and shows the ledger count for
  comparison. **No probe or reconciliation call** to the Gemini API is ever made:
  - Google documents no API that reports usage or remaining quota.
  - A probe would spend a request out of a daily cap that can be as small as 20.

  Calibrating against the AI Studio viewer is a manual maintainer step.

### Initiative Planner — blocking open-questions gate

`scripts/initiative-planner/apply-plan.sh` will **not** materialize an epic + sub-issue
DAG while the plan still has plan-blocking open questions (#682). If `open_questions`
contains any item shaped `{"question": "...", "blocking": true}`, the script creates
**zero** issues, posts the questions back to the source discussion with "not yet planned"
framing, and exits cleanly (DRY_RUN unchanged). Plain-string `open_questions` remain
advisory and do not gate. This is a hard, script-level gate (like the `initiative:auto`
invariant) and must not be worked around with direct `gh` calls. See
`scripts/initiative-planner/README.md`.

### Oversized PRs (> 300 changed files)

GitHub's unified-diff endpoint (`gh pr diff`) is hard-capped at 300 changed files and returns
HTTP 406 above that limit.

- **PR-size guideline:** PRs should stay under 300 changed files to receive a full automated review.
  PRs exceeding 300 files are reviewed with a truncated diff and should be split where practical.
  This guideline is advisory — no CI gate enforces it.
- **Agent behavior on 406:** When `gh pr diff` returns the 406 "diff exceeded the maximum number of
  files" error, the cascade falls back to the per-file REST API (`/pulls/{n}/files`), assembles a
  truncated diff up to the configured line limit, and continues the review with a note that the diff
  is partial. The agent **never** exits with a fatal error (code 1) on the 406 — it always produces
  an actionable review or comment.

### Review artifact contract & rubric registry

- The review automation binds "what is being reviewed" to "how it is reviewed" via an
  artifact contract `{artifact_type, content_ref, rubric, output_channel}` and a versioned
  rubric-registry manifest. See [`scripts/lib/README.md`](./scripts/lib/README.md) for the
  contract, the manifest format (`scripts/lib/review-registry.tsv`), and the sourced lookup
  helper (`scripts/lib/review-registry.sh`).
- The registry is an input-adapter layer **above** `engine.sh` — it selects the rubric and
  output channel for an `artifact_type` and must not change engine/model routing. Register a
  new artifact_type by adding a manifest row; do not fork the reviewer.

### Cost reporting

- **All surfaced USD amounts are rounded to 2 decimals (cents).** Render every
  dollar figure through a single formatter (`_fmt_usd` in `scripts/token_report.sh`,
  `printf "$%.2f"`) so reports, issue comments, and step summaries stay consistent.
  Sub-cent values round to `$0.00`; use Effective Tokens (ET, `_fmt_int`) as the
  fine-grained comparator when cent precision is too coarse.
- Prices are data, not code: keep per-model rates in `scripts/lib/model-pricing.tsv`
  (effective-dated) — never hardcode dollar rates in scripts.
- **Promotion:** this is currently a repo-local standard. To make it org-wide,
  lift it into [`combsmith/.github`](https://github.com/combsmith/.github/blob/main/AGENTS.md)
  (the org AGENTS.md / `standards/`) and have repos defer to it.

### Release channel tags & the mutable-ref exception

First-party reusables are versioned via tags — see
[`docs/release/versioning.md`](./docs/release/versioning.md). This began with the `pr-review` and
`dev-lead` agents and now covers every first-party reusable we own — the reusables in this repo
(`pr-review`, `dev-lead`, `ci-failure-analyst`) and the cross-repo reusables hosted in
`combsmith/.github` (`feature-ideation` and the six #482 reusables). **One convention applies to
all of them.** Two kinds of tag exist per reusable:

- **Immutable releases** `<name>/vX.Y.Z` — never moved or deleted; the audit trail and rollback targets.
- **Moving channel tags** `<name>/v<MAJOR>-<tier>` (major-scoped, #1184; tiers `stable`, and where live
  `next`/`ring0`/`ring1`) — the **canonical** form callers pin to; advanced on promotion by **moving** the tag.
  Examples: `@dev-lead/v1-stable`, `@pr-review/v1-next`, `@ci-failure-analyst/v1-stable`.
- **Legacy bare-tier channel** `<name>/<tier>` (e.g. `@pr-review/next`) — the pre-#1184 form, **DEPRECATED**.
  It is still the sanctioned mutable-ref exception (never flagged as an "unpinned action"), but it is being
  migrated to the major-scoped canonical form. The `reusable-pin-compliance` check
  (`tests/dev-lead/integration/test_reusable_pin_compliance.py`) reports a bare-tier pin as DEPRECATED with the
  major-scoped ref it should become. The migration window is closed: with every first-party pin repinned
  (#1493 AC #11), a bare-tier pin is now a **failure**, not a warning (#1493 AC #12).

**Scoped exception to the SHA-pin standard.** The org standard requires SHA-pinning actions to avoid
mutable-ref supply-chain risk. That rule targets **third-party** actions. The channel tags above are
intentionally **mutable** and are an accepted, documented exception because they reference
**first-party** reusable workflows we own. The exception is bounded by:

- The `release-channel-tags` repository **ruleset** restricts `update` and `deletion` on the
  first-party channel-tag namespaces (e.g. `pr-review/**`, `dev-lead/**`, `ci-failure-analyst/**`),
  with bypass limited to **OrganizationAdmin** and the automation **Integration** app. Net effect: the
  reusables' workflows (running as `GITHUB_TOKEN`) **cannot** move or delete release tags; only an admin
  or the promotion automation can. Extending the ruleset's target list to a newly-versioned reusable is
  an admin step that may lag the tooling/docs — the sanctioned-exception guidance below applies to a
  first-party channel tag regardless of whether its namespace has been added to the ruleset yet.
- Immutable `vX.Y.Z` tags are the real rollback targets; `scripts/cut-release.sh` refuses to overwrite
  an existing release tag.
- Routine channel-tag moves are made by the health-gated Release Manager automation (#501/#993,
  below), which is a ruleset bypass actor through the `combsmith-release-manager` GitHub App.
  The only other sanctioned path is a maintainer running `cut-release.sh` as an org admin or with
  that App's token.

#### Release automation — who cuts and moves tags

Release tags on this repo's agents (`pr-review`, `dev-lead`, `ci-failure-analyst`) and on the
`combsmith/.github`-hosted reusables are cut and moved by the **Release Manager**. That is the
`Canary Rollout` workflow in **`combsmith/.github`**
(`.github/workflows/canary-rollout.yml` + `scripts/canary-rollout.sh`, relocated there from this
repo under #613), acting as the **`combsmith-release-manager[bot]`** GitHub App. Its registry
(each agent's host, reusable path, rings and gate knobs) is **`standards/canary-rings.json` in
`combsmith/.github`**, not in this repo. Each sweep (cron `33 */4 * * *`, every 4 hours;
GitHub may delay scheduled runs) runs `autocut` → `promote-all` → `sync-issues`:

| Step | What it does | Armed by | Human control |
|---|---|---|---|
| **autocut** (#1069, #1019) | Cuts the immutable `<agent>/vX.Y.Z` at host `main` HEAD and moves `<agent>/v<MAJOR>-next` onto it. It fires when the reusable file **or** a watched path (`scripts/`, `prompts/`, `personas/` by default; overridable per agent via `agent_ref_paths`) differs from the current `next` candidate. The bump is detected from the change: breaking (`!`, `BREAKING CHANGE`, or a `workflow_call` interface break) → major, which seeds a new `v<M+1>-next`; `feat` → minor; anything else → patch. | org variable `CANARY_AUTO_CUT` | `autocut.bump` in `canary-rings.json` forces a level. Clearing the variable stops all auto-cuts. |
| **promote-all** (#1045; gate: `.github#548`) | Advances each agent **one ring per sweep** (`next` → `ring0` → `ring1` → `stable`) when its graduated gate returns PROMOTE (per-transition dwell and sample floors, e.g. 4h / 8h / 12h). BLOCKED or REGRESSION agents are left in place. | org variable `CANARY_AUTO_PROMOTE` (unset = read-only `evaluate-all`) | `require_confirmation: true` on a transition holds it in AWAITING_CONFIRMATION until someone dispatches `promote <agent> --confirm`. **Today only `dev-lead`'s `ring1 → stable` sets it**; every other agent reaches `stable` with no human step once armed. |
| **sync-issues** | Opens or updates one issue per blocked agent (`needs-human` on REGRESSION, `canary-confirm:<agent>` when awaiting confirmation) and auto-closes it once cleared. | runs every sweep | Read the issue; act with a dispatch. |

**What this means when you work here:**

- **Do not hand-cut after a routine merge.** Autocut will do it. A manual
  `cut-release.sh <agent> <ver> --channel next --push` that races the sweep fails with
  `release tag '<agent>/vX.Y.Z' already exists`. That is harmless, but a release tag existing does
  **not** prove `next` moved, because autocut creates the release first and moves the channel
  second. Check that `<agent>/v<M>-next` resolves to the release's commit:
  `git ls-remote --tags origin '<agent>/v<M>-next' '<agent>/vX.Y.Z^{}'`. If it doesn't, move it
  with `cut-release.sh <agent> <X.Y.Z> --promote --channel next --push` rather than cutting a
  new version. Always check the current tags before cutting by hand.
- **Hand-run `cut-release.sh` (as an org admin or with the release-manager App token) only when:** the fix cannot wait
  for the next sweep; the change sits outside autocut's watched paths; autocut is disarmed; or you
  are promoting or rolling back deliberately. Use `--promote --channel <tier>` to move a channel to
  an **existing** release, and never cut a new version just to move a channel.
- **Rollback** is a channel move back to an earlier immutable tag. Either dispatch the `Canary
  Rollout` workflow in `combsmith/.github` with `command=rollback agent=<agent> ring=<tier> to=vX.Y.Z`, or run
  `cut-release.sh <agent> <X.Y.Z> --promote --channel <tier> --push`.
- **A release that needs a human go/no-go must be configured *before* its candidate reaches the
  ring.** Examples are a model swap such as epic #1895 / #1899, or a behaviour change that needs
  canary metrics. Add `require_confirmation: true` to that agent's transition in
  `combsmith/.github` `standards/canary-rings.json`, or disarm `CANARY_AUTO_PROMOTE`, which is
  fleet-wide. An issue label such as `dev-lead:hands-off` stops dev-lead from acting on the issue,
  but **it does not stop the promotion gate**.
- **Who did what:** releases tagged by `combsmith-release-manager[bot]` came from the
  automation, and releases tagged by a person were cut by hand. The `Canary Rollout` run's job
  summary and the promotion Deployments record the gate evidence for every move.

Compliance audits must therefore **not** flag any first-party reusable channel tag (e.g.
`@pr-review/v1-stable`, `@dev-lead/v1-stable`, `@ci-failure-analyst/v0-stable`, or other `<name>/v<M>-<tier>`
channel tags) on first-party callers as "unpinned actions" — they are the sanctioned version-selection
mechanism (see the initiative analysis §5.1: `docs/initiatives/agentic-release-strategy.md`).

**feature-ideation (cross-repo).** The `feature-ideation` agent is released through the same model with
the channel set `{next, ring0, ring1, stable}`, so its `feature-ideation/v<MAJOR>-<tier>` pins (e.g., `feature-ideation/v1-stable`) are the **same
sanctioned mutable-ref exception** and must not be flagged as unpinned. Unlike `pr-review`/`dev-lead`
whose reusables live in this repo, `feature-ideation`'s reusable lives in **`combsmith/.github`**
(this repo holds only the thin caller stub), so its release/channel tags are cut against that public
repo — and the protective ruleset bounding `feature-ideation/**` channel tags is therefore created
**there**, not on this repo (an untracked prerequisite in the public repo). See
[`docs/release/versioning.md`](./docs/release/versioning.md) "Cross-repo reusables".

#### Caller-stub input forwarding across channel pins

A thin caller stub pins its first-party reusable at a **moving channel tag** (e.g.
`…/dev-lead-reusable.yml@dev-lead/v1-stable`). That channel resolves to a *specific commit*, and the
stub may only forward (`with:`) inputs that the reusable **at that commit** declares under
`workflow_call.inputs`. Forwarding an input the pinned channel's commit does not yet declare is a
**channel-skew defect** (#1052): the reusable call fails at runtime with an "unexpected input" error
even though every ref looks valid, because the stub is ahead of the channel it pins.

- **Rule.** Never add or modify a `with:` forward on a channel-pinned caller stub to pass an input the
  pinned channel does not yet declare. This is the mirror image of the mutable-ref exception above: the
  channel tag is *deliberately* allowed to lag the reusable's `main`, so the stub must forward against
  what the channel currently resolves to, not against what `main` will eventually ship.
- **Sequencing for a new `workflow_call` input (in order):**
  1. **Land it in the reusable** — add the input to `workflow_call.inputs` on `main` and merge.
  2. **Promote the pinned channel** to a commit that declares it. For `next` this happens on the
     next autocut sweep; later rings follow by gated promotion. Wait until
     `git ls-remote --tags origin '<agent>/v<M>-<name>'` resolves to a commit that declares the
     input. To force it as an org admin or with the release-manager App token, run
     `cut-release.sh <agent> <X.Y.Z> --promote --channel <name> --push` to move the channel to an
     **existing** release that declares the input. Only when no such release exists yet, run
     `cut-release.sh <agent> <new-version> --channel <name> --push`; without `--promote` it
     always cuts a new tag and fails if that version exists (see
     ["Release automation — who cuts and moves tags"](#release-automation--who-cuts-and-moves-tags)).
  3. **Only then teach the stub to forward it** — add the `with:` line to the caller stub, now that the
     pinned channel resolves to a commit that declares the input.

  Doing these out of order (forwarding first) is exactly the skew this rule prevents.
- **Same order for a new `client_payload` field from a dispatching sweep (#2050).** A sweep
  such as `scripts/dev-lead-retry.sh` sends `repository_dispatch` payloads to the harness at
  the pinned channel. A new field the sweep sends follows the same order: **(1)** the harness
  change that reads the field (e.g. `scripts/dev-lead-intent.sh`) merges and **reaches the
  pinned channel first**; **(2)** only then does the sweep change that sends it merge. Before
  the backstop below, the sweep ran from `main`, so a sweep change that merged ahead of the
  channel broke every dispatched run until the channel caught up (#2017: every
  fix-bot-comment retry failed against `v139-stable`), and the canary gate charged those
  failures to the next candidate. As a structural backstop, `dev-lead-retry.yml` now checks
  out `scripts/` at the channel `dev-lead.yml` pins (`agent_ref`), not `main`, so the sweep
  and the harness it dispatches to in this repo are the same release
  (`tests/dev-lead/unit/test_dev_lead_retry_channel.bats`). The order still matters for
  target repos that pin an older channel than this one (#2086).
  [`scripts/check-retry-payload-fields.sh`](./scripts/check-retry-payload-fields.sh) (the
  `retry-payload-fields` job in `lint.yml`, #2081) enforces step (1) for every channel of the
  pinned major. It fails a PR whose sweep sends a top-level field that the intent parser at any
  `dev-lead/v<N>-{next,ring0,ring1,stable}` tag does not read.
- **Enforcement.** The dev-lead prompt guardrail (part C, #1254) stops the agent from introducing the
  skew at the source; the **Part A CI guard (#1253)** is the belt-and-braces check that fails a PR whose
  caller-stub `with:` forwards an input the pinned channel does not declare.
- **Promotion.** The canonical org-wide version of this rule is tracked for
  [`combsmith/.github`](https://github.com/combsmith/.github/blob/main/standards/ci-standards.md)
  (`standards/ci-standards.md`, "Reusable workflow versioning — the `stable` channel") in
  combsmith/.github#736; consumer repos defer to it once it lands.
