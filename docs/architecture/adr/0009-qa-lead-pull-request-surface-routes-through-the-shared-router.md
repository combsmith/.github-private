# 0009. qa-lead's pull_request advisory surface routes through the shared mention router, not a second runtime

## Status

accepted

## Context

qa-lead is served on two surfaces (`personas/qa-lead/interaction.yml`): a
mention routed through the shared `persona-mention` → `persona-runner` path, and
an event-driven `pull_request` advisory (#1646) served by
`.github/workflows/qa-lead-pr-advisory.yml`. The mention surface has a
deployable form — a thin caller stub pinned to a published channel — so a repo
other than `.github-private` can serve it by adopting that stub. The
`pull_request` surface has **no deployable form at all** (#1869). As of
2026-09-21 `qa-lead-pr-advisory.yml` is self-contained, not a thin caller stub:
it checks this repo out and `source`s `scripts/qa-lead-advisory-gate.sh` (a
script that exists only here), it calls the **local** reusable
`./.github/workflows/persona-runner-reusable.yml` rather than an org-published
one, and there is no `standards/workflows/` template in `petry-projects/.github`
for the standards sweep to carry. So the surface cannot simply be listed as
deployable: copying the file into another repo would reference a gate script and
a reusable that do not exist there.

Epic #1643 (Phase 2) requires qa-lead's `pull_request` advisory to reach beyond
`.github-private`. Three options were framed on #1869: **(a)** publish the
persona runtime as an org reusable, give it a `persona-runner/v1-*` channel,
relocate the gate script to travel with it, and author a thin caller stub;
**(b)** fold the `pull_request` trigger into the already-published mention/router
path so the event reaches the one shared runtime; or **(c)** keep the surface
`.github-private`-only by design and make the declared contract say so.

The solution-architect advisory on #1869 (2026-09-23) decided **(b)** and
directed that it be implemented. The router change itself is **cross-repo**
(it lives in `petry-projects/.github`) and is filed separately; this ADR records
the decision and its consequences for this repo. This ADR does not supersede any
existing ADR — it applies ADR-0007's governing rule to a concrete surface.

The grounds are ADR-0007 and ADR-0006. ADR-0007 collapses a repo's per-role
caller stubs into a single ingress precisely to stop per-role stub
proliferation; its fact 4 already names `persona-mention` → `persona-runner` as
the fleet's hub-and-spoke model — "the centralization a webhook promises is
already in hand." Option (a) would publish a **second** persona runtime with its
own `persona-runner/v1-*` channel and, with it, a **second agent-ingress path**
for the `pull_request` event. That repeats, at the ingress-path level, the exact
per-role-stub proliferation ADR-0007 just collapsed, and it duplicates the
shared runtime ADR-0006 recorded as the unit that serves every persona. The
`persona-runner/v1-*` channel is not itself the problem — a versioned runtime is
ADR-0002-shaped and fine; the second **ingress path** it requires is what
ADR-0007 forbids. Option (b) reuses the one router and the one runtime, adding a
trigger to an ingress path that already exists rather than standing up a new one.

The real open risk in (b) is **not** the routing choice — it is the #1745
stop-marker semantics. On the local surface, `scripts/qa-lead-advisory-gate.sh`
enforces the stop markers (the `qa-lead:hands-off` opt-out, the canonical
`needs-human-review` check via `pr_has_escalation_label`, and
`dev-lead:needs-human`) before the runner is ever invoked; a human hold binds
there. When the router serves the `pull_request` event instead, that same
binding must hold for a `pull_request`-sourced dispatch, not only a
mention-sourced one — otherwise a human hold on a PR would be silently ignored
on the new surface. This ADR records that requirement as a hard precondition on
retiring the local surface (see Consequences).

## Decision

We will **route qa-lead's `pull_request` advisory event into the existing shared
`persona-mention` → `persona-runner` path**, and we will **not** publish a second
persona runtime or stand up a second agent-ingress path to serve this surface.

The checkable boundaries:

- **No second ingress path.** The `pull_request` event is absorbed by the
  already-published router (the cross-repo change in `petry-projects/.github`),
  reaching the one shared runtime ADR-0006 records. Option (a)'s separate
  `persona-runner/v1-*` ingress path is rejected on ADR-0007 grounds.
- **The router change is out of scope for this repo.** It is cross-repo and
  filed separately. **No caller stub is edited here**, consistent with #1869
  AC #5 (deployment goes through the standards sweep, not a hand-edited stub).
- **`.github/workflows/qa-lead-pr-advisory.yml` is NOT retired in this change.**
  It is the only thing serving the advisory today. Retiring it before the router
  change is released to its channel would leave the surface dead — the same
  ordering failure as landing a fail-closed validator ahead of its data.
  Retirement is sequenced as a **follow-up gated on the router change reaching
  the `persona-mention/v1-next` channel** this repo pins, and on the
  stop-marker verification below.
- **The interim contract states the truth.** While both the local workflow and
  the pending router serve the surface, `personas/qa-lead/persona.yml`,
  `personas/qa-lead/interaction.yml`, and `personas/qa-lead/README.md` say the
  `pull_request` surface is served **locally in `.github-private` today** and by
  the shared router after the pending cross-repo change — the #1647 rule that a
  declared surface must be a served one. The surface stays `enabled: true`
  because it is served today.

The hard precondition on retirement:

- **The #1745 stop-marker semantics MUST be verified on a `pull_request`-sourced
  dispatch before the local surface is retired.** Concretely: on a PR carrying
  `qa-lead:hands-off`, `needs-human-review`, or `dev-lead:needs-human`, the
  router-served path must produce **no** advisory, exactly as
  `scripts/qa-lead-advisory-gate.sh` does today — a human hold must still bind.
  This is verified by execution (a real router run on a held PR posts nothing),
  not by inspection, before `qa-lead-pr-advisory.yml` is removed. The gate's stop
  markers are pure-logic and bats-covered (`tests/test_qa_lead_advisory_gate.bats`);
  the router must apply the equivalent suppression for the `pull_request` source,
  and that equivalence is the retirement gate.

## Consequences

- The `pull_request` surface becomes deployable to any repo the router already
  reaches — Phase 2 of #1643 is met without a second runtime. A repo serves it
  by adopting the shared ingress, not a qa-lead-specific stub.
- **One ingress path per repo is preserved** (ADR-0007). The cost is the same
  one ADR-0007 and ADR-0006 already accepted twice: coarser per-repo,
  per-surface staging — a repo that adopts the router reaches this surface with
  no per-surface lever to narrow it beyond the per-item `qa-lead:hands-off`
  opt-out.
- **A sequencing debt is created and must be paid in order.** The surface is now
  served by *two* things — the local workflow and the pending router — until the
  router change lands on `persona-mention/v1-next` and the stop-marker
  verification passes. Only then is `qa-lead-pr-advisory.yml` retired. Removing
  it earlier re-opens #1869 by leaving the surface dead; leaving it forever is
  duplicate serving. This ADR is the record that retirement is a deliberate,
  gated follow-up, not an oversight.
- **The event model changes.** Today `qa-lead-pr-advisory.yml` subscribes to
  `pull_request: [opened, ready_for_review]` directly and gates in
  `scripts/qa-lead-advisory-gate.sh`. Under the router the `pull_request` event
  reaches the shared dispatch path, so the gate's suppression logic (test
  surface, opt-out, human gates, budget, one-per-PR idempotency) must be honored
  on the router side. The `synchronize` exclusion (#1646) must be preserved: one
  advisory as a PR enters review, not one per push.
- **The stop-marker binding is the load-bearing risk, not the routing.** If the
  router cannot suppress on a `pull_request`-sourced hold with the same fidelity
  as the local gate, the local surface cannot be retired — and if the router
  cannot absorb the event at all, this decision must be superseded by a new ADR
  recording the specific reason (per the advisory, that is the fact a future ADR
  would need); option (c) is the fallback only if both (a) and (b) fail. We do
  not silently fall back to (a).
- **The fleet-wide claim in the advisory prompt stays true** (#1644). The body
  qa-lead prints tells a reader to "opt out on this item with the
  qa-lead:hands-off label"; keeping the local surface until the router honors
  that label on the `pull_request` source is what keeps the printed claim true
  everywhere it can appear.

## References

- ADR-0007 (one agent-ingress stub per repo, not one stub per role) — the
  governing rule; option (a)'s second ingress path is the proliferation this
  forbids. Not superseded.
- ADR-0006 (shared-runtime personas are not ring-registered) — the shared
  runtime this surface routes into; a persona is a caller of it, not a reusable.
- ADR-0002 (channel-tag release and rings) — the model the router's
  `persona-mention/v1-*` channel follows; retirement is gated on the router
  reaching `persona-mention/v1-next`.
- ADR-0001 (thin-caller / reusable two-tier) — why `qa-lead-pr-advisory.yml`,
  being self-contained rather than a thin caller stub, has no deployable form.
- Issue petry-projects/.github-private#1869 and its solution-architect advisory
  (2026-09-23) that decided option (b) — the decision thread.
- Related history: #1646 (built this surface), #1647 (declared surfaces must
  match served ones), #1745 (stop markers), #1643 (epic).
- `scripts/qa-lead-advisory-gate.sh` and `tests/test_qa_lead_advisory_gate.bats`
  — the stop-marker semantics the router must reproduce for the `pull_request`
  source before retirement.
