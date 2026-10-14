# 0001. Thin-caller / reusable two-tier workflow model

## Status

accepted

## Context

Agentic automation (dev-lead, pr-review, auto-rebase, …) runs in many
`petry-projects` repos. If each repo carried the full workflow logic, a
behavior change would mean editing every repo, and the copies would drift.

Lifted from `AGENTS.md` §"Workflow Files" and §"Reusable caller-input contract":
`.github/workflows/dev-lead.yml` is a thin caller stub that delegates to
`dev-lead-reusable.yml` (the canonical logic). "To change behavior for all org
repos, edit `dev-lead-reusable.yml`." The reusable is the tier that holds
logic; the stub is the tier that only wires triggers and forwards inputs.

## Decision

We will split every first-party agentic workflow into two tiers with a fixed
boundary:

- **Reusable tier** — a `workflow_call` reusable (`*-reusable.yml`) that owns
  all logic. Behavior changes for the whole fleet are made here.
- **Caller-stub tier** — a `.github/workflows/*.yml` stub that only declares
  `on:` triggers and forwards inputs via `with:` to a pinned first-party
  `petry-projects/*` reusable. Repo-specific trigger adjustments are the only
  logic a stub may carry (per the stub's header comment).

The boundary a check can later assert: **a caller-stub job must `uses:` a
pinned first-party `petry-projects/*` reusable — and, because a `uses:` job
carries no `steps` or `run:` keys of its own under the Actions schema, it must
declare none — must forward only inputs the pinned ref declares under
`workflow_call.inputs`, and must pass any secret only via the `secrets:` key,
never interpolated into a `with:` input.** (The `validate-caller-inputs` job in
`lint.yml`, #1253, already enforces the input-declaration half.)

## Consequences

- One edit to a reusable changes the whole fleet — the intended leverage.
- The stub is deliberately underpowered: adding real logic to a stub is a
  layering violation, and pushing a `with:` forward ahead of the pinned
  channel's declared inputs causes a post-merge "unexpected input" failure
  (the #1034 channel-skew defect). The narrow boundary is what makes that
  failure statically catchable.
- Repos that need genuinely local behavior must either add a repo-specific
  trigger to the stub or justify a documented exception (as several workflows
  in `AGENTS.md` §"Workflow Files" already do) — the two-tier split trades
  per-repo flexibility for fleet consistency.
