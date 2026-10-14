# Release runbook — cut, promote, roll back

Operational procedures for the per-agent channel-tag release model (initiative
\#495, targets SC4). For the *what* and *why* of the scheme, see
[`versioning.md`](./versioning.md) and the
[initiative analysis](../initiatives/agentic-release-strategy.md) §5.1, §7.

**Agents covered:** `pr-review`, `dev-lead`, `feature-ideation`, and the six #482
reusables (`agent-shield`, `auto-rebase`, `dependency-audit`,
`dependabot-automerge`, `dependabot-rebase`, `pr-review-mention`). `pr-review` and
`dev-lead` live in this repo; callers (consumers + this repo's own self-host
caller) pin the moving channel tag `@<agent>/stable` and thread
`agent_ref: <agent>/stable`. The cross-repo reusables (`feature-ideation` + the
six above) live in `petry-projects/.github`, so their release/channel tags are cut
against **that** repo, not this repo's `origin` (see "Cross-repo reusables" in
[`versioning.md`](./versioning.md)). `cut-release.sh` resolves and publishes their
tags against **`petry-projects/.github`** via `gh api` (#872, wired); a live
`--push` for a cross-repo agent needs `GH_TOKEN` with `contents:write` on that repo.

**Two tag kinds per agent:**

| Tag | Mutable? | Role |
|---|---|---|
| `<agent>/vX.Y.Z` | No — never moved or deleted | Immutable audit trail + rollback target |
| `<agent>/stable` | Yes — advanced on promotion | What every caller pins to |

The goal: cut, promote, and **roll back in < 5 minutes with no per-caller edits
and no manual file surgery** — every rollout/rollback is a single central tag
move.

> **Current state — most of this is automated.** Routine releases no longer need
> the manual steps below. The Release Manager (the `Canary Rollout` workflow in
> `petry-projects/.github`, acting as the `petry-projects-release-manager[bot]`
> App) auto-cuts `<agent>/vX.Y.Z` and moves `<agent>/v<MAJOR>-next` every 4-hour
> sweep, and promotes through the rings by its health gate when armed. See
> [`AGENTS.md` "Release automation — who cuts and moves tags"](../../AGENTS.md#release-automation--who-cuts-and-moves-tags).
> The procedures here are the **manual and override path**, for urgent cuts,
> deliberate promotions and rollbacks. Two differences from the older text
> below: channels are major-scoped `<agent>/v<MAJOR>-<tier>` (#1184), so a bare
> `<agent>/stable` in an example is the legacy form; and channel moves must go
> through `cut-release.sh`, because a local `git push --force` of a protected
> channel tag is rejected (GH013).

---

## Roles & gating

- **Cutting an immutable `vX.Y.Z` tag** is harmless (it rolls out nothing until
  `stable` moves) and may be done as part of normal release prep.
- **Promotion (moving a ring channel, ultimately `<agent>/v<MAJOR>-stable`)** is
  a production rollout to every caller in that ring. The Release Manager's gated
  `promote-all` does it when `CANARY_AUTO_PROMOTE` is armed. It moves one ring per
  sweep, and a `require_confirmation` transition waits for a human `--confirm`
  dispatch. A maintainer can also do it by hand as an override. The agents
  themselves (dev-lead, pr-review, …) must never move a channel tag.
- **Who *can* move a channel tag:** the `release-channel-tags` ruleset (targets
  tags `pr-review/**`, `dev-lead/**`) restricts `update`/`deletion` with bypass
  limited to **OrganizationAdmin** and the automation **Integration** app. The
  agents themselves (running as `GITHUB_TOKEN`) cannot. See
  [`AGENTS.md`](../../AGENTS.md) "Release channel tags & the mutable-ref exception".

---

## 1. Cut a release

Cut an immutable `<agent>/vX.Y.Z` at a reviewed, merged commit (default ref
`origin/main`).

```bash
# Preview (touches nothing):
scripts/cut-release.sh pr-review 1.6.0 --ref origin/main --dry-run

# Cut the immutable tag only (no promotion):
scripts/cut-release.sh pr-review 1.6.0 --ref origin/main --push

# Cross-repo agents (feature-ideation + the six #482 reusables, reusables in
# petry-projects/.github): tags are cut against that repo via gh api (#872).
# Preview with --dry-run; publish with --push (needs contents:write on .github):
scripts/cut-release.sh agent-shield 2.1.0 --channel next --dry-run
scripts/cut-release.sh agent-shield 2.1.0 --channel next --push
```

- Pick the version per semver (see `versioning.md#semantic-versioning`): bugfix →
  PATCH, backward-compatible behavior → MINOR, breaking input/contract → MAJOR.
- `cut-release.sh` **refuses to overwrite an existing immutable tag** — release
  tags are forever.
- Cut at a commit that is actually on `main` and has passed CI. Do **not** cut at
  a SHA you only believe merged — confirm with `git log origin/main`.

---

## 2. Promote (roll forward)

Promotion advances `<agent>/stable` to a cut release. **Requires human
authorization** (see Roles & gating).

### 2a. New release — cut + promote in one step

When the `vX.Y.Z` tag does **not** yet exist, `cut-release.sh` can create it and
move the channel together:

```bash
scripts/cut-release.sh dev-lead 1.2.0 --ref origin/main --channel stable --push
```

### 2b. Already-cut release — move the channel only

`cut-release.sh --channel` creates the immutable tag first, so it **errors if
`vX.Y.Z` already exists** (`immutable tags are never overwritten`). This is also
what you see if autocut already cut that version. To move a channel to an
already-cut release, use `--promote` (#992), which moves the channel through the
API path without cutting anything:

```bash
# Advance pr-review/v1-stable to the already-cut pr-review/v1.5.3:
scripts/cut-release.sh pr-review 1.5.3 --promote --channel stable --push
```

> Channel tags are lightweight (they point straight at the commit); the immutable
> `vX.Y.Z` tags are annotated. Do not `git tag -f` + `git push --force` a channel:
> the `release-channel-tags` ruleset rejects that update (GH013).
>
> **Cross-repo agents.** `feature-ideation` and the six #482 reusables
> (`agent-shield`, `auto-rebase`, `dependency-audit`, `dependabot-automerge`,
> `dependabot-rebase`, `pr-review-mention`) have `<agent>/<channel>` tags that live
> on `petry-projects/.github`, so a promotion is a tag move on **that** repo
> (`git push <petry-projects/.github remote> <agent>/<channel> --force`), not this
> repo's `origin`. `cut-release.sh` resolves and moves them against
> `petry-projects/.github` via `gh api` (#872); a live `--push` needs `GH_TOKEN` with
> `contents:write` there.

Then **verify** (§4).

---

## 2c. Staged canary / ring rollout

For a higher-risk release, stage it through the ring channels instead of promoting
`stable` in one move. Each ring's callers pin **once** to their channel (see
[`versioning.md` → Ring channels](./versioning.md#ring-channels-live-for-dev-lead));
a rollout is a sequence of single tag moves, validating at each step. `dev-lead`
has live `next`/`ring0`/`ring1` channels; `pr-review` is `stable`-only for now (#499).

```bash
git fetch origin --tags
# Cut the immutable release once (ungated):
scripts/cut-release.sh dev-lead 1.5.0 --ref origin/main --push
TARGET=$(git rev-parse 'dev-lead/v1.5.0^{commit}')

# Stage it outward, one ring at a time. After EACH move, verify (§4) and let the
# ring soak — confirm its callers' runs are healthy before advancing the next.

# Promote to 'next' (canary/self-host)
git tag -f dev-lead/next "$TARGET"
git push --force origin dev-lead/next
# → verify (§4) + soak on 'next' before continuing

# Promote to 'ring0'
git tag -f dev-lead/ring0 "$TARGET"
git push --force origin dev-lead/ring0
# → verify (§4) + soak on 'ring0' before continuing

# Promote to 'ring1'
git tag -f dev-lead/ring1 "$TARGET"
git push --force origin dev-lead/ring1
# → verify (§4) + soak on 'ring1' before continuing

# Promote to 'stable' (production)
git tag -f dev-lead/stable "$TARGET"
git push --force origin dev-lead/stable
# → verify (§4) + soak on 'stable'
```

- **Promotion is gated at every ring.** The Release Manager's health gate decides
  when each channel advances (Roles & gating). Advance a ring by hand only as a
  deliberate override, and only after the previous ring is healthy.
- **Validate the candidate, don't trust it.** Treat a ring's failures as the
  release until proven otherwise — classify them (regression vs. pre-existing
  class) before advancing. A clean canary across rings is the gate for `stable`.
- **Rollback at any stage** is the same single move in reverse against the prior
  immutable `vX.Y.Z` (§3) — for that ring's channel, or for `stable` if already
  promoted.
- The fully automated, health-gated version of this loop (#501/#993) is live in
  `petry-projects/.github` (relocated under #613); the moves above are the manual
  override path. A required input to that gate is
  the **shadow-mode dual-run** signal (#605) — run the `next` candidate silently
  alongside `stable` on a PR and compare, blocking promotion on a regression. See
  [`shadow-mode.md`](./shadow-mode.md).

Then **verify** (§4).

---

## 3. Roll back (< 5 minutes)

Rollback is promotion in reverse: move `<agent>/stable` **back** to the previous
known-good immutable tag. No caller edits, no file surgery.

```bash
git fetch origin --tags
# Roll pr-review/stable back from v1.5.3 to the prior good release v1.5.2:
PREV=$(git rev-parse 'pr-review/v1.5.2^{commit}')
git tag -f pr-review/stable "$PREV"
git push origin pr-review/stable --force
```

- The immutable `vX.Y.Z` tags are the rollback targets — pick the last release
  known healthy (`git tag -l 'pr-review/v*' | sort -V`).
- For the cross-repo agents (`feature-ideation` + the six #482 reusables), the
  same reverse-tag-move applies but against `petry-projects/.github` (where their
  `<agent>/v*` and channel tags live), not this repo — see the cross-repo note in §2b.
- Every caller picks up the rolled-back version on its **next** run with no
  change on their side. In-flight runs already started on the bad version finish;
  new runs use the restored one.
- Then **verify** (§4) and, if the bad version was already cut, leave its
  immutable tag in place (audit trail) — never delete it.

---

## 4. Verify a caller picked up the change

A promotion/rollback is confirmed when a fresh run resolves the channel to the
expected commit. Trigger or wait for an agent run on any caller, then check the
reusable-resolution line in its log:

```bash
# In the run log, the reusable line shows the resolved tag + SHA:
#   Uses: …/dev-lead-reusable.yml@refs/tags/dev-lead/stable (d827464…)
gh run view <run-id> --repo <caller-repo> --log | grep -m1 '@refs/tags/'
```

Confirm the trailing SHA matches the commit you promoted/rolled back to. For
`pr-review`, also confirm a fresh `donpetry-bot` review carries the expected
behavior. To force a run without waiting for an event:

```bash
gh workflow run pr-review-trigger.yml --repo <caller-repo> \
  -f pr_url="<pr-url>" -f dry_run=true -f force_review=true
```

---

## Gotchas (learned in the #495 rollout)

- **Promotion is gated, cutting is not.** Autonomous tooling can cut `vX.Y.Z`
  but must stop and get authorization before moving `stable`.
- **`cut-release.sh --channel` ≠ channel-only.** It creates the immutable tag;
  for an already-cut release use the direct `git tag -f` move (§2b).
- **Don't pin a caller to a stale channel.** Before pinning a new caller to
  `@<agent>/stable`, confirm `stable` is at or ahead of `main` for that agent —
  a stale channel silently regresses the caller. (e.g., `dev-lead/stable` was advanced
  from `v1.1.0` to `v1.2.0` before pinning consumers, to avoid reverting #488's fixes.)
- **CodeQL on freshly-enabled default setup.** If a repo's required `CodeQL`
  check has no producer, enabling default setup
  (`PATCH /repos/{repo}/code-scanning/default-setup`) won't retroactively run on
  an open PR — fire a `synchronize` (e.g. an empty commit) so it analyzes the PR
  head.
- **Channel tags are an accepted exception to the SHA-pin policy** — first-party
  reusables we own, bounded by the `release-channel-tags` ruleset. Compliance
  audits must not flag `@pr-review/stable` / `@dev-lead/stable` as unpinned.

---

## Validation of this runbook

The cut → promote → verify path was exercised live during the #495 rollout:
`pr-review/v1.5.3` cut + `pr-review/stable` promoted (the #534 fix), and
`dev-lead/v1.2.0` cut + `dev-lead/stable` promoted, each verified by a caller run
resolving `@refs/tags/<agent>/stable (<sha>)`. Rollback is the same single
tag-move in reverse against the immutable `vX.Y.Z` targets.
