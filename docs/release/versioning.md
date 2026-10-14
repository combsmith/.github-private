# Agent versioning & release channels

Status: **active** (Phase 1 of the [Safe Release Strategy](../initiatives/agentic-release-strategy.md)
initiative, epic #495). Implements issue #496.

This defines how **first-party reusables** are versioned and how callers select a version. It began
with the **dev-lead** and **pr-review** agents and now covers every first-party reusable this repo (or
`combsmith/.github`) owns — including `ci-failure-analyst`. **One convention applies to all of
them:** an immutable release `<name>/vMAJOR.MINOR.PATCH` plus major-scoped moving channel tags
`<name>/v<MAJOR>-<tier>` (`stable`, and where live `next`/`ring0`/`ring1`). It is the foundation the
rest of the initiative (rings, promotion, rollback) builds on.

## What is versioned

A "release" of a reusable is the reusable workflow **plus the scripts it executes** — they move
together, so a version is a single repo commit that contains a known-good combination:

| Agent | Reusable workflow | Key scripts (non-exhaustive) |
|---|---|---|
| `pr-review` | `.github/workflows/pr-review.yml` | `scripts/review-one-pr.sh`, `scripts/review-batch.sh`, `scripts/post-pr-review.sh`, `scripts/engine.sh`, `scripts/lib/*` |
| `dev-lead` | `.github/workflows/dev-lead-reusable.yml` | `scripts/dev-lead-*.sh`, `scripts/engine.sh`, `scripts/lib/*` |
| `ci-failure-analyst` | `.github/workflows/ci-failure-analyst-reusable.yml` | reusable-owned (inline `gh api` orchestration + the Claude Code action; no separate `scripts/`) |
| `feature-ideation` | `combsmith/.github` → `.github/workflows/feature-ideation-reusable.yml` (**cross-repo**) | reusable-owned (lives in the public repo; this repo holds only the thin caller `.github/workflows/feature-ideation.yml`) |
| `agent-shield`, `auto-rebase`, `dependency-audit`, `dependabot-automerge`, `dependabot-rebase`, `pr-review-mention` (the six #482 reusables) | `combsmith/.github` → `.github/workflows/<name>-reusable.yml` (**cross-repo**) | reusable-owned (live in the public repo; this repo holds only the thin caller stubs) |

`pr-review`, `dev-lead`, and `ci-failure-analyst` all live in this repo, so a release tag points at a
whole-repo commit; the tag *name* scopes it to one reusable so each can be released and promoted
independently.

The rest are the exception: their reusables live in **`combsmith/.github`** (this repo holds only
the thin caller stubs), so a "release" is a commit on that public repo, and their release/channel tags
must be cut **against `combsmith/.github`, not this repo's `origin`**. This is `feature-ideation`
plus the six reusables #482 migrated to channel tags — see [Cross-repo reusables](#cross-repo-reusables)
below.

## Tag scheme

Two kinds of tag, per agent:

| Kind | Format | Mutable? | Purpose |
|---|---|---|---|
| **Immutable release** | `<agent>/vMAJOR.MINOR.PATCH` | No (annotated, never moved) | Audit trail + rollback target |
| **Channel** | `<agent>/v<MAJOR>-<tier>` | Yes (moved on promotion) | What callers pin to |

Channels (Phase 1 defines `stable`; Phase 2 adds `next` and per-ring channels):

- `<agent>/v<MAJOR>-stable` — the production channel (blue). Callers in production pin here.
- `<agent>/v<MAJOR>-next` — the candidate channel (green). **Live for `dev-lead`** (#499).
- `<agent>/v<MAJOR>-ring0`, `<agent>/v<MAJOR>-ring1`, … — per-ring channels for staged promotion. **Live for `dev-lead`** (#499/#500).

Examples: `pr-review/v1.0.0`, `pr-review/v1-stable`, `dev-lead/v1.0.0`, `dev-lead/v1-stable`,
`dev-lead/v1-next`, `dev-lead/v1-ring0`, `dev-lead/v1-ring1`.

### Ring channels (live for `dev-lead`)

The candidate (`next`) and ring channels are real moving tags, created alongside `stable`. A caller
pins **once** to its ring channel and is never edited again; a release flows outward ring-by-ring as
each ring's tag is advanced.

Ring membership (canonical model — see [#500](https://github.com/combsmith/.github-private/issues/500)).
`next` is **host-relative**: it always resolves to the repo that *hosts* the reusable, and `ring0`
covers the other org-infra repo, so `next` + `ring0` always span `.github` + `.github-private`,
partitioned by which one is the host:

| Ring | Channel | Members (general) | Role |
|---|---|---|---|
| **next** | `<agent>/v<MAJOR>-next` | the repo that **hosts** the reusable | canary / dogfood at the source |
| **ring0** | `<agent>/v<MAJOR>-ring0` | `.github` **and** `.github-private` (host already in `next`) | org-infra self-host |
| **ring1** | `<agent>/v<MAJOR>-ring1` | `TalkTerm`, `bmad-bgreat-suite` | named low-traffic consumers |
| **stable** | `<agent>/v<MAJOR>-stable` | everything else | full-fleet production |

Concretely for **`dev-lead`** (hosted in `.github-private`): `next` = `.github-private`,
`ring0` = `.github`, `ring1` = `{TalkTerm, bmad-bgreat-suite}`, `stable` = the rest.
**Production self-review/dev duty stays pinned to `stable` even within ring 0** — the agent validating
fixes is never the unvalidated candidate (the circular-dependency fix #500 targets). The intended
machine-readable source of truth is `standards/canary-rings.json`, now hosted in
`combsmith/.github` and consumed by the promotion automation (#501, relocated there under #613).

A staged rollout advances the channels in order — `next` → `ring0` → `ring1` → `stable` — validating
at each step (see [`runbook.md` §2c](./runbook.md#2c-staged-canary--ring-rollout)). All four channels
may sit at the same commit between releases; they diverge while a candidate is being staged. The
`check_dev_lead_stub` compliance audit accepts any `dev-lead/v<M>-{stable,next,ring<N>}` channel pin (it
rejects `@main` and frozen `@vX.Y.Z`/`@<sha>` — callers must pin a *moving* channel). pr-review still
uses `stable` only; its ring channels are pending under #499.

`feature-ideation` uses the full per-ring channel set — `{next, ring0, ring1, stable}` — so it can be
promoted through the same canary → ring → stable model. Its tags follow the identical name scheme
(`feature-ideation/vX.Y.Z`, `feature-ideation/v<MAJOR>-next`, `feature-ideation/v<MAJOR>-ring0`,
`feature-ideation/v<MAJOR>-ring1`, `feature-ideation/v<MAJOR>-stable`) but are cut against `combsmith/.github`
(see [Cross-repo reusables](#cross-repo-reusables)).

The six **#482 reusables** — `agent-shield`, `auto-rebase`, `dependency-audit`, `dependabot-automerge`,
`dependabot-rebase`, `pr-review-mention` — use the same `{next, ring0, ring1, stable}` set (#870),
replacing the single-hop `<name>/stable`-only migration #482 cut by hand. They are `.github`-hosted, so
like `feature-ideation` their tags are cut against `combsmith/.github`. Their ring membership is an
**explicit org-owner assignment** (#870, matching #866), and it does **not** follow the host-relative
`$host`/`$org_infra` default above — `next` is `.github-private` (the dogfood lab) even though the
reusables are hosted in `.github`, which sits in `ring0`:

| Channel | Member repo(s) |
|---|---|
| `next` | `.github-private` |
| `ring0` | `.github` (the host) |
| `ring1` | `TalkTerm`, `bmad-bgreat-suite` |
| `stable` | `markets`, `broodly`, `ContentTwin`, `google-app-scripts` (full-fleet production) |

### Semantic versioning

- **MAJOR** — breaking change to the caller contract (workflow inputs/secrets, required permissions,
  the merge-gate behavior a consumer relies on).
- **MINOR** — backward-compatible capability (new safety check, new optional input).
- **PATCH** — backward-compatible fix (bug fix, prompt tweak, resilience hardening).

## How callers select a version (no per-caller churn)

GitHub does **not** allow an expression in a `uses:` ref, so version selection is **a moving channel
tag**, not a variable. Each caller pins **once** to a channel and is never edited again; promotion is a
central move of the channel tag (see the initiative doc §5.1):

```yaml
# A consumer / self-host caller pins once to the per-agent channel:
uses: combsmith/.github-private/.github/workflows/pr-review.yml@pr-review/v1-stable
uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-stable
```

> Shorthand: the initiative doc writes `@stable`; the concrete tag is the **per-agent** major-scoped channel
> (`pr-review/v1-stable`, `dev-lead/v1-stable`) so the agents promote independently.

## The v1.0.0 baseline

The first release was cut from the production `main` at the time of issue #496:

- `pr-review/v1.0.0`, `dev-lead/v1.0.0` — immutable baselines.
- `pr-review/v1-stable`, `dev-lead/v1-stable` — channels pointing at v1.0.0.

`v1.0.0` is **"what is in production today,"** the current rollback floor — *not* a certified-perfect
version. The health-gated promotion added in Phase 2 (#501) is what makes *future* promotions to
`stable` genuinely validated before they become production.

## Cross-repo reusables

Everything above assumes the agent's reusable workflow lives **in this repo**, so a release tag is a
whole-repo commit here and tags are cut against this repo's `origin`. That holds for `pr-review` and
`dev-lead`. It does **not** hold for the cross-repo reusables — `feature-ideation` and the six #482
reusables (`agent-shield`, `auto-rebase`, `dependency-audit`, `dependabot-automerge`,
`dependabot-rebase`, `pr-review-mention`):

- Their reusables live in **`combsmith/.github`** (`.github/workflows/<name>-reusable.yml`); this
  repo carries only the thin caller stubs `.github/workflows/<name>.yml`.
- Therefore a release is a commit on **`combsmith/.github`**, and the `<name>/vX.Y.Z` immutable +
  `<name>/v<MAJOR>-<tier>` channel tags must be cut **against that repo**, not this repo's `origin`.
- `scripts/cut-release.sh` recognizes each of these agents (`valid_agent`) and, for a cross-repo agent,
  **resolves the ref and creates/moves the tags against `combsmith/.github` via `gh api`** (#872,
  wired). `--dry-run` previews the immutable + channel tag names; a live `--push` creates the annotated
  `<name>/vX.Y.Z` release object and force-moves the `<name>/v<MAJOR>-<tier>` channel tag on `.github`, and needs
  `GH_TOKEN` with `contents:write` on that repo. (`origin/main` in `--ref` means `.github`'s `main` — the
  `origin/` prefix is stripped for the cross-repo API lookup.)
- Because these channel tags live on `combsmith/.github`, the protective ruleset that bounds them
  (the mutable-ref exception) is created **there**, not on this repo — see
  [`AGENTS.md`](../../AGENTS.md) "Release channel tags & the mutable-ref exception".

> **Now registered in `standards/canary-rings.json`.** The promotion automation (`canary-rollout.sh`,
> #501) — relocated to `combsmith/.github` under #613 — moves channel tags **cross-repo** via `gh api`
> ref updates on each agent's host repo (#1054), so the six reusables above are registered under the full
> `{next, ring0, ring1, stable}` model (#870). `feature-ideation` remains **absent** for now: its host + ring
> assignment aren't settled. (Manual/scripted cuts via `cut-release.sh` work today.)

### The six #482 reusables (ring assignment)

PR #482 migrated these six to moving channel tags **single-hop** — it cut only `<name>/stable` (+ a manual
off-convention `<name>/v2.0.0`) and put all consumers on `stable`, with no `next`/`ring*`. #870 brings
them under the full `{next, ring0, ring1, stable}` model with the explicit, org-owner ring assignment in
[Ring channels](#ring-channels-live-for-dev-lead) above. Note this assignment is **explicit, not
host-relative**: `next` is `.github-private` even though the reusables are hosted in `.github` (which
sits in `ring0`). Re-cutting their releases on a sane incremental-semver basis (reconciling the manual
`<name>/v2.0.0` tags) and cutting the `next`/`ring0`/`ring1` channels is an operational step done via
`cut-release.sh`, whose cross-repo publish path is now wired (#872).

## Cutting / moving tags

Use `scripts/cut-release.sh` (tested in `tests/test_cut_release.bats`) rather than ad-hoc `git tag`:

```bash
# Cut an immutable release for an agent at a ref (default ref: origin/main):
scripts/cut-release.sh pr-review 1.1.0 --push

# Cut a release AND advance that agent's stable channel to it (a promotion):
scripts/cut-release.sh pr-review 1.1.0 --channel stable --push

# Preview without touching anything:
scripts/cut-release.sh pr-review 1.1.0 --channel stable --dry-run

# Cross-repo agent (reusable in combsmith/.github): cut against that repo via
# gh api (#872). --dry-run previews; --push publishes (needs contents:write on .github):
scripts/cut-release.sh feature-ideation 1.4.0 --channel ring0 --dry-run
scripts/cut-release.sh feature-ideation 1.4.0 --channel ring0 --push
```

The promote/rollback **runbook** (when to move `stable`, how to roll back, verify, gotchas) lives in
[`runbook.md`](./runbook.md). The automated, health-gated promotion workflow is issue #501; tag-protection
so only the promotion workflow may move a channel tag is issue #505.
