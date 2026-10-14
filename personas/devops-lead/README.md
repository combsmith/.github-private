# DevOps Lead — infrastructure, CI/CD, and deployment advisor

Formalized under the [Agentic Persona Standard](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md).
`devops-lead` wraps the vendored [BMAD B-Great Suite](../../frameworks/bmad-bgreat-suite/VENDOR.md)
DevOps agent (`bgr-agent-riley-devops`, pinned to commit `ae8914e84b87`), consumed
**by path** as plain markdown.

## What devops-lead is

It advises on infrastructure-as-code, CI/CD pipeline architecture, container
orchestration (Kubernetes), GitOps, progressive delivery (blue-green/canary), and
environment isolation. It is **advisory on every surface and writes nowhere** —
the safe default for a new persona. Its principles are automation-first: manual
changes that bypass a pipeline, infrastructure not captured in code, and
configuration drift are treated as defects, not conveniences.

## Why `devops-lead` and not the upstream agent's name

The vendored agent has a person-name upstream. We do not use it. A persona is
named for its **role** ([§1.6](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md)):
`@petry-projects/devops-lead` tells a reader in a PR comment who is being
addressed and why; the upstream cast list does not. Swapping the agent
underneath — or replacing it with a first-party layer — never changes how this
persona is addressed. Upstream is referenced only by its technical skill id
(`framework.skill: bgr-agent-riley-devops`).

## How it is addressed

```text
@petry-projects/devops-lead please review the deployment strategy on this PR
```

The handle is the org **team** `petry-projects/devops-lead`, not a user account —
`@devops-lead` is a real GitHub account owned by an unrelated person, so a bare
role mention would notify a stranger on every use. The team is `privacy: closed`
with `notification_setting: notifications_disabled`: it exists to route a
webhook, not to page anyone. See
[§4.1](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md).

## Relationship to the auto-rebase / CI tooling

`devops-lead` overlaps in subject matter with this repo's existing delivery
automation — the `auto-rebase` workflows, the reusable-workflow release channels,
and the CI lint/guard suite. That tooling is the **mechanism**: it enforces
pins, freezes caller stubs, and drives rebases. `devops-lead` is **advice about**
that mechanism — it reviews pipeline and infrastructure design and flags gaps
(missing promotion gates, unsafe rollout, drift) in prose. It is **advisory, not
a replacement**: it never edits workflows, moves a channel tag, or triggers a
rebase. The CI guards remain the source of truth; the persona only comments.

## Status: draft

`devops-lead` ships **no dedicated reusable workflow yet**, so:

- there is **no `agents.devops-lead` entry in `canary-rings.json`** yet (nothing
  to roll out via rings until it has a reusable), and
- the manifest carries no `runtime:` block.

The `address` block and the `mention` surface are declared, but nothing
dispatches on them until the router and a runtime exist — declaring the
addressing contract is deliberately separate from serving it.

To promote `devops-lead` past `draft`:

1. Wire a dedicated advisory workflow (e.g. mention-triggered delivery review) as
   a caller stub + reusable, and add its `runtime:` block.
2. Expand the held-out eval set under
   [`evals/devops-lead/holdout/`](../../evals/devops-lead/holdout/cases.jsonl). It
   carries a synthetic starter set; grow it to the `min_cases` gate with real
   (de-identified) cases and wire the scorer/judge before promotion. The set
   lives under the repo `evals/` tree so `validate-cases.py` and
   `holdout-guard.yml` already cover it.
3. Register the one `agents.devops-lead` entry in `canary-rings.json` and cut
   `devops-lead/v0.1.0`.
4. Soak `next → ring0 → ring1 → stable`, eval gate green before `stable`.

The full gate is the Definition of Done in `persona-standards.md` §7.

## Contributing upstream

This persona's behavior lives upstream in `petry-projects/bmad-bgreat-suite`. Do
not hand-edit `frameworks/`. Org-specific behavior is layered via
`definition.layers[].local_overrides`; anything general enough to help other BMAD
users should be raised upstream (`upstream_candidate: true`) rather than kept as
private drift.
