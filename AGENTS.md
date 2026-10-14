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

## Project-Specific Standards

### Workflow Files

- Do **not** modify `.github/workflows/agent-shield.yml` — this is exempted from agent modification per
  [`standards/agent-standards.md`](https://github.com/combsmith/.github/blob/main/standards/agent-standards.md).
- `.github/workflows/dev-lead.yml` is a thin caller stub that delegates to
  `dev-lead-reusable.yml` (the canonical org standard). To change behavior for
  all org repos, edit `dev-lead-reusable.yml`. Repo-specific trigger adjustments
  may be made to `dev-lead.yml` per the stub's header comment.
- All other workflow changes must use templates from
  [`standards/workflows/`](https://github.com/combsmith/.github/tree/main/standards/workflows) verbatim.
- **Note:** `.github/workflows/auto-rebase.yml` pins the reusable workflow at the `@auto-rebase/stable`
  moving channel tag, matching the canonical org stub in `standards/workflows/auto-rebase.yml`. Do not
  repoint it to a frozen `@vX` tag, `@main`, or a SHA — `tests/dev-lead/integration/test_auto_rebase_stub.py`
  (#139) enforces this. The repo-specific `auto-rebase-retry.yml` and `auto-rebase-health.yml` workflows
  depend on the sentinel-trigger behavior provided by the current channel; downgrading to a pre-sentinel
  frozen tag is a behavioral regression.
- **Exception:** The `gh-aw-compile` job in `lint.yml` is a documented repo-specific addition that gates
  agentic workflow compilation. It is not covered by the org template and must not be removed by template
  syncs. If the org template gains a `gh-aw-compile` equivalent, remove this exception and defer to the
  template instead.
- **Exception:** `token-report.yml` (weekly Token Cost Observatory report) is a documented repo-specific
  workflow with no corresponding org template in `standards/workflows/`. It must not be removed by template
  syncs. If the org template gains a token-report equivalent, remove this exception and defer to the
  template instead.
- **Exception:** `test-deletion-guard.yml` (#823) is a documented repo-specific workflow with no org template.
  It is one half of the #655 **stale-base / semantic-revert** guard: it fails a PR that deletes any file under
  `tests/` unless a maintainer adds the `ack-test-deletion` label, so a silent test removal becomes a deliberate,
  reviewable decision. The other half is the **"require branches up to date before merging"** ruleset on `main`
  (already enabled). Together they close the gap behind #655, where a PR merged from a stale base reverted a
  shipped fix and deleted its regression test in the same green-CI diff. Do not remove either guard.
  Because this is a **gate** workflow whose `failure` conclusion is intentional enforcement (it blocks a
  bad PR), it is exempt from the Fleet Monitor's high-failure issue tracking via `FLEET_GATE_WORKFLOWS`
  in `scripts/fleet_report.sh` (#941) — otherwise a guard doing its job produces false-positive trackers.
  `holdout-guard.yml` is exempt for the same reason. Add new gate workflows of this class to that list.
- **Exception:** `pr-review-sweep.yml` (stuck-review sweep, #573/#898) is a documented repo-specific
  workflow with no corresponding org template in `standards/workflows/`. It re-dispatches reviews for PRs
  that went green after a ci-pending/ci-failing skip, via two triggers: a scheduled cron (the guaranteed
  ≤15-min backstop) and a `workflow_run: completed` fast path (#898) that scopes the sweep to the
  completing CI run's PR(s) for near-instant re-review. It must not be removed by template syncs. If the org
  template gains an equivalent re-trigger sweep, remove this exception and defer to the template instead.
- **Exception:** `readme-refresh.yml` (weekly org README refresh) is a documented repo-specific workflow
  with no corresponding org template in `standards/workflows/`. It regenerates the four org "meta-repo"
  READMEs (public + member-only org profiles, and the `.github` / `.github-private` repo landing pages)
  from live org state via `scripts/aw-readme-refresh.sh` + `prompts/aw/readme-refresh.md`, then opens or
  updates one rolling PR (`chore/readme-refresh`, label `readme-refresh`) per repo for human review. It
  never direct-pushes. It must not be removed by template syncs. If the org template gains an equivalent,
  remove this exception and defer to the template instead.
- **Exception:** The `bats` test list in `lint.yml` is extended with repo-specific test files (e.g.
  `tests/test_push_protection.bats`) beyond the org template baseline. When adding new test files to this
  repo, add them to this list. Template syncs must not reset it to the base template list. This includes
  `tests/test_downstream_impact_regression.bats` (#753, epic #748) — the golden-fixture regression guard
  that pins the pure downstream-impact mapper (`scripts/lib/downstream-impact.sh`) against a frozen manifest
  and expected outputs under `tests/fixtures/downstream-impact/golden/`. The golden manifest is intentionally
  independent of the live `scripts/lib/consumer-manifest.json` so a legitimate manifest refresh does not break
  the guard — only a change to the mapper's output does, which then requires an explicit fixture update visible
  in the diff. It runs in the always-run `bats` job (no `paths:` filter) so it stays a stable check.
- **Exception:** `holdout-guard.yml` (#692, epic #581) is a documented repo-specific workflow with no
  corresponding org template in `standards/workflows/`. It is the hard CI enforcement behind the advisory
  `.github/CODEOWNERS` rule over `evals/`: it fails any PR authored by the automated skill-proposer identity
  that changes a held-out path, keyed on PR author + changed paths. It runs on every PR (no `paths:` filter)
  so it stays a stable required status check. The author/path decision lives in
  `scripts/lib/holdout-guard.sh` (tests: `tests/test_holdout_guard.bats`). It must not be removed by template
  syncs. If the org template gains a held-out immutability equivalent, remove this exception and defer to the
  template instead.
- **Exception:** `auto-rebase-retry.yml` is a documented repo-specific workflow with no corresponding org
  template in `standards/workflows/`. It is a `workflow_run` handler that self-heals a *failed* Auto-rebase
  run by re-running its failed jobs (bounded by `run_attempt`) — the gap left by the conflict-only sentinel
  path, which the thin-caller `auto-rebase.yml` and central reusable cannot cover. It must not be removed by
  template syncs. If the org template gains a retry equivalent, remove this exception and defer to the
  template instead.
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

- **Allowlist exception — `ci.yml`:** `.github/workflows/ci.yml` is the **one** shipped stub that
  intentionally carries real per-stack build/test steps and is customized per consumer (see the template's
  `BOOTSTRAP.md` "Customize `ci.yml` for your stack" step). A byte-identity guard would false-positive on the
  template's richer `ci.yml` default, so it is **excluded** from the drift check via the documented allowlist
  in `scripts/template_stub_drift.sh` (`TEMPLATE_DRIFT_ALLOWLIST`). Add a path to that allowlist **only** with
  a recorded rationale, the same way the exceptions above are documented.

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

The agents (`pr-review`, `dev-lead`) are versioned via tags — see
[`docs/release/versioning.md`](./docs/release/versioning.md). Two kinds of tag exist per agent:

- **Immutable releases** `<agent>/vX.Y.Z` — never moved or deleted; the audit trail and rollback targets.
- **Moving channel tags** `<agent>/stable` (later `/next`, `/ring*`) — what callers pin to; advanced on
  promotion by **moving** the tag.

**Scoped exception to the SHA-pin standard.** The org standard requires SHA-pinning actions to avoid
mutable-ref supply-chain risk. That rule targets **third-party** actions. The channel tags above are
intentionally **mutable** and are an accepted, documented exception because they reference
**first-party** reusable workflows in this repo that we own. The exception is bounded by:

- The `release-channel-tags` repository **ruleset** (target: tags `pr-review/**`, `dev-lead/**`)
  restricts `update` and `deletion`, with bypass limited to **OrganizationAdmin** and the automation
  **Integration** app. Net effect: the dev-lead/pr-review agents (running as `GITHUB_TOKEN`) **cannot**
  move or delete release tags; only an admin or the promotion automation can.
- Immutable `vX.Y.Z` tags are the real rollback targets; `scripts/cut-release.sh` refuses to overwrite
  an existing release tag.
- Channel-tag moves happen only via the (forthcoming) health-gated promotion workflow (#501); the
  ruleset bypass will be tightened to that workflow's identity when it lands.

Compliance audits must therefore **not** flag `@pr-review/stable` / `@dev-lead/stable` (or other channel
tags) on first-party callers as "unpinned actions" — they are the sanctioned version-selection mechanism
(see the initiative analysis §5.1: `docs/initiatives/agentic-release-strategy.md`).

**feature-ideation (cross-repo).** The `feature-ideation` agent is released through the same model with
the channel set `{next, ring0, ring1, stable}`, so its `feature-ideation/<channel>` pins are the **same
sanctioned mutable-ref exception** and must not be flagged as unpinned. Unlike `pr-review`/`dev-lead`
whose reusables live in this repo, `feature-ideation`'s reusable lives in **`combsmith/.github`**
(this repo holds only the thin caller stub), so its release/channel tags are cut against that public
repo — and the protective ruleset bounding `feature-ideation/**` channel tags is therefore created
**there**, not on this repo (an untracked prerequisite in the public repo). See
[`docs/release/versioning.md`](./docs/release/versioning.md) "Cross-repo reusables".
