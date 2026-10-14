# Multi-repo initiative coordination — design-only spike

Part of epic **#1142**. This is **Phase 2 / issue #1147**: a design record that specifies how
[`scripts/initiative-driver.sh`](../../scripts/initiative-driver.sh) would be extended to release a
**single epic's stories across multiple target repos** — *without building it*. It ends in an explicit
[go/no-go](#5-gono-go-recommendation). **No driver code is changed by this story.**

This is deliberately design-only because the actual multi-repo build is the highest-blast-radius gap in
the initiative pipeline: one coordinated change would fan writes across several repos at once. The point
of this record is to make an informed go/no-go on that blast radius *before* any cross-repo automation is
written. Every claim about the driver below cites the real behavior in `scripts/initiative-driver.sh`
(line references are to the file at the time of writing).

## What is — and is not — being designed

This story specifies coordinating **one epic whose stories target several repos** — e.g. a single "roll
out X to repos A, B, C" epic with one story per repo, released in dependency order. That is a different
shape from what the driver already does.

**Already shipped — do not confuse it with this gap.** The driver already has a `target_repo` fleet
model (see [`agentic-release-strategy-orchestration.md` → Fleet enablement](./agentic-release-strategy-orchestration.md#fleet-enablement-cross-repo-enrollment-target_repo)
and [`idea-to-initiative-pipeline.md` → Fleet enablement](./idea-to-initiative-pipeline.md#fleet-enablement-any-org-repo)).
There, a **whole epic lives inside one repo**, and `target_repo` selects *which single repo* the driver
sweeps and labels per run. Each fleet repo drives its **own** epics; `REPO` is single-valued for the
duration of a run (`initiative-driver.sh:54`, `.github/workflows/initiative-driver.yml:62`). The
concurrency lane is keyed per target repo (`initiative-driver.yml:57`), so different repos' sweeps do not
queue behind each other — but no single run ever spans two repos.

| | Existing `target_repo` (shipped) | This design (`target_repos`) |
|---|---|---|
| Epic location | Entirely inside one repo | One coordinating repo |
| Stories location | Same repo as the epic | Fanned across several repos |
| `REPO` per run | One value (self or one fleet repo) | Must resolve **per story** |
| Blast radius of one epic | One repo | Several repos at once |
| Status | Built (`#495` orchestration, fleet enablement) | **Not built — this is the go/no-go** |

So the gap is narrow but sharp: the driver is `REPO`-scoped at *every* API touch point, and a
cross-repo epic needs the repo to be a property of each **story**, not a single run-level constant.

## 1. Current single-repo scoping and the minimal extension surface (AC #1)

### 1.1 Where `REPO` is load-bearing today

`REPO` is read once (`initiative-driver.sh:54`, default `petry-projects/.github-private`), frozen
`readonly` (`:80`), and threaded into **every** GitHub API call. There is exactly one repo per process:

| Concern | Code | Repo binding |
|---|---|---|
| Epic label read (gate) | `labels_of` → `gh api "repos/$REPO/issues/$1"` (`:88-90`, called `:111`) | `$REPO` |
| Sub-issue enumeration (DAG nodes) | `gh api --paginate "repos/$REPO/issues/$epic/sub_issues"` (`:118`, `:143`) | `$REPO` |
| Nested-epic guard children | `sub_issue_numbers` → `repos/$REPO/issues/$1/sub_issues` (`:93-99`, `:192`) | `$REPO` |
| `blocked_by` resolution | `gh api "repos/$REPO/issues/$n/dependencies/blocked_by"` (`:198-201`) | `$REPO` |
| Per-story label reads (in-flight, hands-off, hold) | `labels_of` (`:151`, `:168`) | `$REPO` |
| **Label write (the release)** | `gh issue edit "$n" --repo "$REPO" --add-label "$DEV_LEAD_LABEL"` (`:210`) | `$REPO` |
| Sweep discovery | `gh api ... "repos/$REPO/issues" -f labels="$GATE_LABEL"` (`:227-229`) | `$REPO` |

The DAG traversal itself is repo-agnostic in shape (it walks native `sub_issues` and
`dependencies/blocked_by` edges) — but each edge lookup is issued against the one `$REPO`. GitHub's
native sub-issue and `blocked_by` relationships are **cross-repo capable** at the API level (an issue in
repo A can be `blocked_by` an issue in repo B), which the current code neither uses nor accounts for.

### 1.2 The minimal extension surface

The smallest change that delivers cross-repo coordination while touching the least logic:

1. **Repo becomes a per-story property, not a run constant.** The epic (in the coordinating repo)
   declares its target repos, and each story is associated with the repo it lives in. Concretely, two
   plausible shapes:
   - **(a) `target_repos` list on the epic** — the epic body/field enumerates the repos in scope; each
     native sub-issue already carries its own `repository` **and `labels`** in the GitHub API payload,
     so the driver reads the story's own repo and label state directly from the `sub_issues` response
     rather than assuming `$REPO` or calling `labels_of` per child — eliminating the N+1 query pattern
     across the fan-out. This is the lowest-surface option: the DAG is authored as native cross-repo
     sub-issues/`blocked_by` edges, and the driver simply stops hard-coding `$REPO` into per-story
     calls, deriving repo and label state from each node instead. `target_repos` then functions as an
     **allowlist / scope assertion** — the driver refuses to act on any story whose repo is not in the
     epic's declared `target_repos`, so a stray cross-repo edge cannot widen blast radius silently.
   - **(b) per-story `repo` annotation** — if native cross-repo sub-issue links prove unreliable, the
     plan encodes each story's repo explicitly (mirroring the planner's existing `target_repo` notion,
     §4) and the driver reads that.

   Option (a) is preferred: it reuses GitHub's native graph, keeps the planner as the source of truth
   for structure, and makes `target_repos` a **bound** (a cap on which repos may be touched) rather than
   a new imperative dispatch list.

2. **Every `$REPO` interpolation becomes story-qualified.** `labels_of`, `sub_issue_numbers`, the
   `blocked_by` call, and the release write (`:210`) take the story's own `owner/repo`. The epic-gate
   read (`:111`) stays against the coordinating repo where the epic lives.

3. **Sweep discovery stays single-repo (the coordinating repo).** The sweep (`:227`) discovers armed
   **epics** by label in the coordinating repo. It does **not** need to fan out across repos to find
   epics — a cross-repo epic is still one epic in one place. What fans out is the **release targets** of
   that epic's stories, resolved per node in §1.2.1. This keeps sweep-mode discovery unchanged and
   bounds the blast-radius surface to "epics a maintainer armed *here*."

### 1.2.1 Interaction with sweep-mode discovery and `target_repos`

The existing sweep (`EPIC` empty ⇒ discover every open issue carrying `GATE_LABEL` in `$REPO`,
`:226-235`) and the new `target_repos` notion compose cleanly if kept in their lanes:

- **Discovery axis (unchanged):** sweep finds *epics* in the coordinating repo by `initiative:auto`.
- **Release axis (new):** for each discovered epic, `target_repos` (or the per-node repo, §1.2) decides
  *where* each ready story's `dev-lead` label is written.

The trap to avoid: do **not** turn the sweep into a multi-repo epic-discovery loop. That would let any
armed epic in any enrolled repo release stories into any other repo — an unbounded surface. Keeping
discovery single-repo means a cross-repo epic is only ever *created and armed in one place a maintainer
controls*, and `target_repos` is a declared, reviewable allowlist on that single epic.

## 2. Every per-repo safety gate, honored across repos without weakening (AC #2, #3)

The analysis is explicit: per-repo isolation + human gates are a **deliberate safety choice**, not an
accident of the single-repo implementation. A multi-repo extension must keep each gate *per repo* — a
cross-repo epic gets the **intersection** of every repo's gates, never a relaxation. Each gate below is
mapped to its current code and to how the extension honors it.

### 2.1 `initiative:auto` opt-in — honored per epic, re-asserted per target repo

- **Today:** the epic must carry `GATE_LABEL` (`initiative:auto`) or `drive_epic` no-ops
  (`initiative-driver.sh:112-115`). In sweep mode it is the discovery filter (`:227-229`); in single-epic
  mode it is re-checked (`:111-112`).
- **Cross-repo:** the coordinating epic must carry `initiative:auto` (unchanged). **Additionally**, each
  target repo must independently opt in — a repo is only a valid release target if it, too, has enrolled
  (shipped the driver caller stub + provisioned the PAT, per fleet enablement). The design adds **no
  weaker path**: an epic naming repo B in `target_repos` cannot release into B unless B is enrolled. The
  opt-in is thus **two-key**: the epic is armed once, but no repo receives a label unless that repo is a
  declared, enrolled target. This is strictly *more* restrictive than the single-repo gate, never less.

### 2.2 `dev-lead:hands-off` / `initiative:hold` never-release — honored on each story in its own repo

- **Today:** a story carrying `HANDS_OFF_LABEL` or `HOLD_LABEL` is skipped and never released
  (`:169-176`). These are read from the story's own labels via `labels_of` (`:168`).
- **Cross-repo:** unchanged in spirit — `labels_of` is issued against the **story's own repo**, so a
  hold placed by a maintainer *in repo B* on a story *in repo B* still blocks that story. The
  never-release check is evaluated where the story lives, so each repo's maintainers retain veto over
  their own stories. No cross-repo epic can override a local hold.

### 2.3 `MAX_IN_FLIGHT` — the blast-radius cap, applied per epic *and* bounded per repo

- **Today:** `MAX_IN_FLIGHT` (default 2) caps concurrently-released sub-issues per epic (`:157-161`),
  counting in-flight items as open stories already carrying `dev-lead` (`:150-156`). This is the primary
  cost / blast-radius control.
- **Cross-repo — this is the key blast-radius decision (AC #3):** the cap must remain a **hard bound on
  the total coordinated change**, and additionally must not let one repo absorb the whole budget in a way
  that surprises another repo's maintainers. The design specifies **both** bounds, enforced together:
  - **Per-epic total cap (unchanged):** the epic never has more than `MAX_IN_FLIGHT` stories in flight
    across *all* its repos combined. A cross-repo epic is therefore never noisier, in aggregate, than a
    single-repo one. This directly answers AC #3: one coordinated change **cannot** become one unbounded
    agent session — the same integer that bounds a single-repo epic bounds the cross-repo one.
  - **Per-repo sub-cap (new, defensive):** optionally, a `MAX_IN_FLIGHT_PER_REPO` bound so a single
    coordinated epic cannot dump N simultaneous `dev-lead` runs into one target repo even within the
    total budget. Default = the total cap (i.e. no extra restriction unless set), so the simple case is
    unchanged.

  In-flight counting must become **repo-aware**: the current count reads open `dev-lead`-labelled
  stories from `$REPO` (`:143-156`); the extension counts them per target repo and sums, so the cap
  reflects reality across the fan-out. Counting only the coordinating repo would under-count in-flight
  work and silently breach the cap — an explicit correctness requirement for any build.

  **Implementation efficiency note:** the `sub_issues` API response already returns full issue objects
  including both `labels` and `repository` fields. The in-flight count, hands-off check, and hold check
  can all be satisfied from this initial payload — no per-child `labels_of` call is needed. This avoids
  the N+1 query pattern (one extra API call per story) that would otherwise compound across the fan-out.

### 2.4 `holdout-guard` — a per-repo CI gate that is already independent and stays that way

- **Today:** `holdout-guard.yml` runs on **every PR in the repo it lives in** (no `paths:` filter,
  `.github/workflows/holdout-guard.yml:12-21`), failing any PR whose author is the skill-proposer
  identity and that touches a held-out path (`scripts/lib/holdout-guard.sh` `hg_evaluate`,
  `:81-116`). The decision keys purely on **PR author + changed paths** in that repo.
- **Cross-repo:** this gate is **structurally already per-repo and requires no driver change** — it is a
  PR-time CI check in each target repo, entirely downstream of the driver. When the driver releases a
  story into repo B, dev-lead opens a PR *in B*, and *B's own* `holdout-guard` evaluates it. The driver
  never bypasses it because the driver never merges — it only applies a label. The design's obligation is
  a **negative** one: the multi-repo driver must not introduce any path that merges or writes to held-out
  files directly; it must keep routing all change through per-repo PRs so each repo's `holdout-guard`
  keeps firing. Enrollment prerequisite: every target repo must actually **have** `holdout-guard.yml`
  installed (it is a repo-specific workflow, per AGENTS.md), so a target repo without it is a weaker link
  — the enrollment runbook for multi-repo targets must verify the guard's presence as a precondition.

### 2.5 Isolation summary (AC #3)

| Gate | Where enforced | Cross-repo rule |
|---|---|---|
| `initiative:auto` | Epic (coordinating repo) + each target enrolled | Two-key: armed epic **and** enrolled target repo |
| `dev-lead:hands-off` / `initiative:hold` | Each story, in its own repo | Evaluated where the story lives; local veto preserved |
| `MAX_IN_FLIGHT` | Per epic (total), optional per-repo sub-cap | Total cap unchanged; in-flight count becomes repo-aware |
| `holdout-guard` | Per-repo PR CI | Already independent; driver must keep routing via per-repo PRs |
| Concurrency lane | Per target repo (`initiative-driver.yml:57`) | Retained per target repo so fan-out writes serialize per repo |
| dev-lead per-issue concurrency | dev-lead.yml, per issue | Unchanged — each released story is still an isolated agent session |

The through-line: a cross-repo epic is the **intersection** of every repo's gates plus a single shared
`MAX_IN_FLIGHT` budget. There is no aggregate agent session — each released story is still one isolated
dev-lead run in its own repo, behind its own repo's CI. That is precisely the property AC #3 requires.

## 3. PAT / permission model implication (AC #4)

The driver's cross-workflow-triggering constraint is **load-bearing** and becomes *more* demanding across
repos.

- **Why a PAT at all (unchanged):** GitHub does not start new workflow runs from events created by the
  default `GITHUB_TOKEN` (loop prevention). The `dev-lead` label **must** be applied with
  `GH_PAT_WORKFLOWS`, or the resulting `issues:[labeled]` event will **not** trigger `dev-lead.yml`
  (`scripts/initiative-driver.sh:25-29`; the workflow fails fast if the PAT is absent,
  `.github/workflows/initiative-driver.yml:87-99`). This is the same class of bug as pr-review #463.
- **What changes across repos:** the label write (`initiative-driver.sh:210`) already runs as
  `GH_PAT_WORKFLOWS` (`initiative-driver.yml:99`). For a cross-repo release, that **same PAT must have
  `issues: write` (and repo read) scope on *every* target repo**, not just the coordinating repo. The
  existing single-`target_repo` fleet path already relies on this (cross-repo writes use
  `GH_PAT_WORKFLOWS`); the multi-repo case widens the requirement from "the PAT can write to *one* other
  repo per run" to "the PAT can write to *all* repos this epic coordinates."
- **Permission-model implication to name explicitly (AC #4):** a single PAT with write access spanning
  many repos is itself a blast-radius concentrator — it is the one credential that can label (and thus
  set dev-lead loose) across the whole coordinated set. The design must therefore treat the PAT's scope
  as a **first-class safety boundary**:
  - The PAT's repo scope is the *outer* bound on which repos an epic can ever touch — narrower than
    `target_repos` if the PAT lacks a repo, the release into that repo simply fails (fail-closed), which
    is the desired direction.
  - Prefer a **fine-grained PAT** scoped to exactly the enrolled target repos with only
    `issues: write`, over a broad classic PAT. This keeps the credential's blast radius equal to the
    declared `target_repos`, not "every repo the owner can reach."
  - **Fine-grained PAT limitation — cross-org constraint:** GitHub fine-grained PATs are restricted to
    a single resource owner (one user or one organization). If the multi-repo initiative coordinates
    repos that span *different organizations*, a single fine-grained PAT cannot cover them all. In that
    case, prefer a **GitHub App installation token** (one installation per org, token scoped to that
    org's enrolled repos) or, if an App is not available, a classic PAT scoped to the minimum required
    permissions. For the primary use case — a coordinated epic whose target repos all live within one
    organization — a fine-grained PAT remains the preferred choice and this limitation does not apply.
  - The workflow already runs with `contents: read` only and pushes all mutation through the PAT
    (`initiative-driver.yml:48-49`); that split is preserved — no target repo needs to grant the
    *workflow* write, only the PAT.

## 4. The planner's `target_repo` notion and how the driver side should read scope

The initiative planner already supports a **single** `target_repo` (empty ⇒ self/dogfood, non-empty ⇒
one named fleet repo — `idea-to-initiative-pipeline.md` §"Fleet enablement", `initiative-planner/redispatch.sh`).
Today that is *one* repo per plan: the planner writes the whole epic + DAG into that one repo.

For the driver-side multi-repo extension, the design's recommendation is:

- **Read a `target_repos` (plural) scope declared on the epic**, treated as an **allowlist / bound**, not
  an imperative dispatch list (§1.2 option (a)). The per-story repo is resolved from the native
  `sub_issues` graph; `target_repos` asserts the set of repos that graph is *allowed* to span. A story
  whose repo is outside `target_repos` is refused — fail-closed.
- **This composes with, and does not replace, sweep-mode discovery** (§1.2.1): discovery stays
  single-repo (find armed epics in the coordinating repo); `target_repos` governs only where that epic's
  ready stories may be released. The two live on separate axes and must not be merged into a multi-repo
  discovery loop (the unbounded-surface trap).
- **Planner alignment is a prerequisite, not part of this story.** For a coordinated epic to exist, the
  planner would need to author stories that live in (or link to) multiple repos and declare
  `target_repos` on the epic. That planner change is out of scope here and is called out as a story in
  the follow-up epic (§5).

## 5. Go/no-go recommendation

**Recommendation: GO — but staged and human-gated, not a single build.**

Rationale:

- **The gap is real and the highest-value one.** Coordinated cross-repo rollouts (e.g. "apply this
  standard to repos A/B/C in order") are exactly what an initiative driver should enable, and today it
  cannot — `REPO` is single-valued at every touch point (§1.1).
- **The extension surface is narrow and mechanical.** The core change is "stop hard-coding `$REPO` into
  per-story calls; derive the repo from each node; assert it against a declared `target_repos`
  allowlist" (§1.2). The DAG shape, the gate checks, and the release mechanic are otherwise unchanged.
- **Every safety gate survives, and most get *stronger*.** The opt-in becomes two-key (§2.1), the cap
  stays a hard total bound with an optional per-repo sub-cap (§2.3), holdouts stay per-repo PR-time CI
  (§2.4), and isolation is preserved because each released story is still one isolated dev-lead run
  (§2.5). Nothing about the design collapses the coordinated change into one unbounded session (AC #3).
- **The one genuinely new risk is credential concentration** (§3): a PAT that can write to many repos.
  This is manageable with a fine-grained PAT scoped to exactly the enrolled targets, and it fails closed
  (missing scope ⇒ release into that repo fails).

Because of the PAT-concentration risk and the fan-out blast radius, the build must be **its own
human-gated epic**, delivered in small, independently reviewable stories — not one large change. The
scoped follow-up epic below is what a future plan would create.

### If GO — scoped follow-up build epic (outline only; no plan is materialized here)

A future `initiative-planner` run would create an epic with roughly these PR-sized stories, in dependency
order:

1. **Repo-qualify the driver's per-story API calls.** Refactor `labels_of`, `sub_issue_numbers`, the
   `blocked_by` lookup, and the release write so each takes an explicit `owner/repo` derived from the
   story node, with `$REPO` as the default for the coordinating/self path. Behavior-preserving for the
   single-repo case; covered by extending `tests/test_initiative_driver.bats`.
2. **Resolve each story's repo from the native `sub_issues` graph** and add the `target_repos` allowlist
   read on the epic, with fail-closed refusal of any out-of-allowlist story. *(blocked_by: story 1)*
3. **Make in-flight counting and `MAX_IN_FLIGHT` repo-aware**, plus the optional
   `MAX_IN_FLIGHT_PER_REPO` sub-cap; assert the total cap still bounds the whole fan-out.
   *(blocked_by: story 2)*
4. **Two-key `initiative:auto`: require each target repo to be enrolled** (stub + `holdout-guard`
   present + PAT scope) before releasing into it; verify the enrollment precondition. *(blocked_by: story 2)*
5. **PAT scope hardening + docs:** move to a fine-grained PAT scoped to the enrolled target set; document
   the credential as a first-class safety boundary; update the enrollment runbook. *(blocked_by: story 4)*
6. **Planner alignment:** teach `initiative-planner` to author cross-repo epics (stories in multiple
   repos, `target_repos` declared on the epic). *(blocked_by: story 2; can parallelize with 3–5)*
7. **Cross-repo driver canary + observability:** extend `initiative-driver-canary.yml` to smoke-test the
   multi-repo release path (a dry-run epic fanning across ≥2 fixture repos), so a silent regression of the
   fan-out surfaces the same way the single-repo hollow-green does today. *(blocked_by: stories 3–5)*

Each story ships behind the same human gates that guard the existing pipeline (`idea:approved` →
`initiative:auto`), dry-run-first, and each modifies the driver in a small, reviewable increment. The
epic itself would carry `initiative:auto` **off** until a maintainer reviews the full DAG — consistent
with the bootstrap discipline in `agentic-release-strategy-orchestration.md` §"Bootstrap order".

## References

- [`scripts/initiative-driver.sh`](../../scripts/initiative-driver.sh) — the single-`REPO` driver this design extends
- [`.github/workflows/initiative-driver.yml`](../../.github/workflows/initiative-driver.yml) — trigger, PAT wiring, per-target concurrency lane
- [`scripts/lib/holdout-guard.sh`](../../scripts/lib/holdout-guard.sh) / [`.github/workflows/holdout-guard.yml`](../../.github/workflows/holdout-guard.yml) — per-repo held-out immutability gate
- [`docs/initiatives/agentic-release-strategy-orchestration.md`](./agentic-release-strategy-orchestration.md) — how the driver delivers an epic; existing `target_repo` fleet enablement
- [`docs/initiatives/idea-to-initiative-pipeline.md`](./idea-to-initiative-pipeline.md) — the two human gates and the planner's `target_repo` notion
- [`AGENTS.md`](../../AGENTS.md) — repo standards; `initiative-driver-canary.yml` and `holdout-guard.yml` exceptions
