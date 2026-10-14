# sre-lead — persona

Formalized under the [Agentic Persona Standard](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md).
`sre-lead` wraps the vendored [BMAD B-Great SRE](../../frameworks/bmad-bgreat-suite/VENDOR.md)
agent (`bgr-agent-morgan-sre`), consumed **by path** as plain markdown, and makes
the role addressable as an org **team** handle.

## What sre-lead is

`sre-lead` is a **reliability advisor**. It advises on observability strategy and
the golden signals, SLO/SLI and error budgets, incident response and runbooks,
blameless postmortems, disaster recovery (RTO/RPO), chaos engineering, and
eliminating toil. It is **advisory on every surface and writes nowhere** — the
safe default for a new persona. The advisory contract lives in
[`prompts/sre-lead/advisory.md`](../../prompts/sre-lead/advisory.md).

## Why `sre-lead` and not the upstream agent's name

The vendored agent has a person-name upstream. We do not use it. A persona is
named for its **role** ([§1.6](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md)):
the org handle tells a reader in a PR comment who is being addressed and why; the
upstream cast list does not. Swapping the agent underneath — or replacing it with
a first-party layer — never changes how this persona is addressed. Upstream is
referenced only by its technical skill id (`framework.skill: bgr-agent-morgan-sre`).

## How it is addressed

```text
@petry-projects/sre-lead please assess reliability risk on this change
```

The handle is the org **team** `petry-projects/sre-lead`, not a user account —
the bare `@sre-lead` account is a real GitHub account owned by an unrelated
person, so a bare role mention would notify a stranger on every use. The team is
`privacy: closed` with `notification_setting: notifications_disabled`: it exists
to route a webhook, not to page anyone. See
[§4.1](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md).

## Overlap with other personas

None significant. `sre-lead` owns reliability and operations (monitoring,
alerting, SLOs, incident response, DR, resilience) — a lane the current personas
(qa-lead, dev-lead, business-analyst, scrum-master) do not cover. When a future
DevOps or Security persona from the same B-Great suite is onboarded, revisit the
shared-concern boundaries the vendored skill already documents (infrastructure
and deployment safety with DevOps; security-incident handling and redaction with
Security).

## Status: draft

`sre-lead` ships **no dedicated reusable workflow yet**, so:

- there is **no `agents.sre-lead` entry in `canary-rings.json`** yet (nothing to
  roll out via rings until it has a reusable), and
- the manifest carries no `runtime:` block.

The `address` block and the `mention` surface are declared, but nothing
dispatches on them until the router and a runtime exist — declaring the
addressing contract is deliberately separate from serving it.

To promote `sre-lead` past `draft`:

1. Wire a dedicated advisory workflow (e.g. mention-triggered reliability review)
   as a caller stub + reusable, and add its `runtime:` block.
2. Expand the held-out eval set under
   [`evals/sre-lead/holdout/`](../../evals/sre-lead/holdout/cases.jsonl) to at
   least `min_cases` real (de-identified) cases and wire the scorer/judge before
   promotion. The set lives under the repo `evals/` tree so `validate-cases.py`
   and `holdout-guard.yml` already cover it.
3. Register the one `agents.sre-lead` entry in `canary-rings.json` and cut
   `sre-lead/v0.1.0`.
4. Soak `next → ring0 → ring1 → stable`, eval gate green before `stable`.

The full gate is the Definition of Done in `persona-standards.md` §7.

## Contributing upstream

This persona's behavior lives upstream in
`petry-projects/bmad-bgreat-suite`. Do not hand-edit `frameworks/`. Org-specific
behavior is layered via `definition.layers[].local_overrides`; anything general
enough to help other B-Great users should be raised upstream
(`upstream_candidate: true`) rather than kept as private drift.
