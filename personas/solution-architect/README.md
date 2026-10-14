# solution-architect — persona

Formalized under the [Agentic Persona Standard](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md).
Follows the **wrap-a-vendored-framework-agent, advisory-everywhere** path
established by [`security-lead`](../security-lead/README.md) and
[`qa-lead`](../qa-lead/README.md).

## What solution-architect is

`solution-architect` wraps the vendored [BMAD Method](../../frameworks/bmad-method/VENDOR.md)
solutioning agent (`bmad-agent-architect`, pinned `v6.8.0`), consumed **by path**
as plain markdown. It advises on **structural review**: it reads the recorded
architecture decisions in [`docs/architecture/adr/`](../../docs/architecture/adr/)
(the S1 ADRs) and measures a proposed change against them, **citing the governing
ADR by number**. It is **advisory on every deployed surface and writes nowhere** — the
safe default for a new persona. The advisory contract lives in
[`prompts/solution-architect/advisory.md`](../../prompts/solution-architect/advisory.md).

The load-bearing rule in that prompt: **if it cannot cite a governing ADR, it
says so** rather than asserting invented doctrine. That is what keeps it off the
ratchet — an advisor with no recorded decision to measure against would otherwise
ratify drift by dressing preference up as policy.

## Why `solution-architect` and not the upstream agent's name

The vendored agent has a person-name upstream ("Winston"). We do not use it. A
persona is named for its **role** ([§1.6](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md)):
`@petry-projects/solution-architect` tells a reader in a PR comment who is being
addressed and why; the upstream cast list does not. It also means swapping the
agent underneath — or replacing it with a first-party layer — never changes how
this persona is addressed. Upstream is referenced only by its technical skill id
(`framework.skill: bmad-agent-architect`).

## How it is addressed

```text
@petry-projects/solution-architect please measure this design against our ADRs
```

The handle is the org **team** `petry-projects/solution-architect`, **never** the
bare `@solution-architect` account — a bare role mention would notify a stranger
on every use. The team is `privacy: closed` with
`notification_setting: notifications_disabled`: it exists to route a webhook, not
to page anyone. See
[§4.1](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md).

## Overlap with existing review surfaces

`solution-architect` is **advisory, not a replacement** for the org's existing
review paths. It is the one lens positioned to notice *structural* drift and told
to measure it against the ADRs — a gap the surfaces below deliberately leave open:

- [`prompts/deep-review-style.md`](../../prompts/deep-review-style.md) is the
  style/behavior-preservation lens in the pr-review cascade. It is explicitly
  told **not** to block a correct, consistent change over subjective preference —
  to *approve* it (see its "Keep findings proportional … approve it" close). That
  is correct for style, but it means structural drift that is internally
  consistent gets waved through. `solution-architect` is the lens that measures
  such a change against the recorded architecture decision instead of ratifying
  it — it advises, it does not gate the cascade.
- The **pr-review cascade** (`prompts/deep-review.md` / triage → deep review)
  classifies risk and can escalate, but does not read `docs/architecture/adr/` or
  cite an ADR. `solution-architect` complements it with ADR-grounded structural
  framing when mentioned; it does not run the cascade or block merges.
- [`dev-lead`](../../.github/workflows/dev-lead.yml) implements issues and opens
  PRs. `solution-architect` reviews *structure* on request and never writes — it
  is an advisor a maintainer summons, not a replacement for the implementer.

Neither is superseded — `solution-architect` is a mention-invoked advisor that
sits alongside them.

## Status: draft — and the propagation posture for promoting it

`solution-architect` ships **no dedicated reusable workflow** (it is served by the
shared mention router, not a per-persona stub), so there is **no
`agents.solution-architect` entry in `canary-rings.json`** yet. The `address` block
and the `mention` surface are declared and served by the shared router; the
[`interaction.yml`](./interaction.yml) in this directory records what is actually
deployed (`issue_comment` / `pull_request_review_comment` / `discussion_comment`),
not aspirational surfaces.

### The #1592 propagation hazard — routed around, not silently ignored

Autocut cuts a new channel version only when a **reusable's blob** changes, but
`solution-architect`'s advisory logic is a **prompt file**
([`prompts/solution-architect/advisory.md`](../../prompts/solution-architect/advisory.md))
checked out at the pinned `agent_ref`, not a reusable of its own. A status/ring move
on a prompt-only persona can therefore advance the scoreboard yet **propagate to
nobody** — the [#1592](https://github.com/petry-projects/.github/issues/1592) hazard.

**Posture: route-around, not resolve.** Because `solution-architect` is
mention-routed via the **shared** `persona-mention` channel
([`.github/workflows/persona-mention.yml`](../../.github/workflows/persona-mention.yml)),
which the router already owns and cuts, promotion rides **that** channel rather than a
dedicated reusable. The #1592 hazard does not apply on a dedicated-blob axis here —
there is no dedicated blob — so this persona does **not** rely on a ring label moving
to reach consumers. Instead promotion is **verified against a real consumer** (below).

### Verification: propagation must reach a consumer (routes-to ≠ promoted)

A ring label moving is **not** evidence a promotion reached a consumer
([Discussion #1360](https://github.com/petry-projects/.github/discussions/1360) §3b,
learning 12). Two checks gate promotion:

- **Hermetic guard, re-runnable at PR time** —
  [`scripts/persona_reach_check.sh`](../../scripts/persona_reach_check.sh) (tests:
  [`tests/persona_reach_check.bats`](../../tests/persona_reach_check.bats)) asserts the
  persona's deployed surface stays a subset of the shared mention router's events (no
  new trigger surface) and separates *routes-to* from *promoted*: it **fails** only on
  the skew state — status past `draft` with **no** `agents.solution-architect`
  registration — which is the [#1052](https://github.com/petry-projects/.github/issues/1052)
  hollow-green class. Run: `bash scripts/persona_reach_check.sh solution-architect`.
- **Live smoke, operational** — mirror qa-lead's
  [#1300](https://github.com/petry-projects/.github/issues/1300) mention smoke test:
  post a real `@petry-projects/solution-architect` mention on a fixture item and
  confirm the resulting `persona-runner` run **resolves to this persona** and posts its
  advisory. Trust the live mention, not the ring label.

### Promotion sequencing — why status is still `draft`

Advancing `status` past `draft` makes the `validate-personas` job
([`personas/validate-personas.py`](../validate-personas.py)) require an
`agents.solution-architect` entry in the **cross-repo**
`petry-projects/.github/standards/canary-rings.json` (persona-standards §6 step 2 —
"register once", the single place ring membership is written). That entry is an
**untracked cross-repo prerequisite** and cannot be authored from this repo; flipping
`status` here **before** it lands turns `validate-personas` red post-merge — the exact
skew this route-around exists to prevent. So the order is fixed:

1. **Register first (cross-repo).** Add the one `agents.solution-architect` entry to
   `petry-projects/.github/standards/canary-rings.json` (`host`, `run_workflow`,
   `rings[]`, `gate`) — served by the shared `persona-mention` router, not a dedicated
   reusable, so it registers on that channel the way the existing `persona-mention`
   entry does. This is the epic's untracked prerequisite.
2. **Green the scored eval gate.** The held-out set under
   [`evals/solution-architect/holdout/`](../../evals/solution-architect/holdout/cases.jsonl)
   must clear `scripts/evals/score-gate.sh solution-architect` (threshold from
   [`evals/solution-architect/scorer.json`](../../evals/solution-architect/scorer.json))
   — the **scored** (not counted) gate is the precondition for `stable`
   (persona-standards §7 Definition of Done).
3. **Only then flip `status`** `draft → next` here, and stage outward one ring at a
   time — `next → ring0 → ring1 → stable` — each a single central channel-tag move,
   gated by the soak/dwell defaults in the registry, with the scored gate green before
   `stable`.
4. **No new trigger surface** at any step — promotion changes status/rings only, never
   the trigger surface (still mention-routed only; no `pull_request: synchronize`, no
   cron, no fan-out — §7 of the story, learning 11). `persona_reach_check.sh` enforces
   this.

The full gate is the Definition of Done in `persona-standards.md` §7.

## Contributing upstream

This persona's behavior lives upstream in `bmad-code-org/BMAD-METHOD`. Do not
hand-edit `frameworks/`. Org-specific behavior is layered via
`definition.layers[].local_overrides`; anything general enough to help other BMAD
users should be raised upstream (`upstream_candidate: true`) rather than kept as
private drift.
