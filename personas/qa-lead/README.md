# QA Lead — Master Test Architect & Quality Advisor

Worked example for the [Agentic Persona Standard](https://github.com/combsmith/.github/blob/main/standards/persona-standards.md).
`qa-lead` is the reference for the **wrap-a-vendored-framework-agent,
advisory-everywhere** path.

## What qa-lead is

`qa-lead` wraps the vendored [BMAD Test Architecture](../../frameworks/bmad-test-architecture/VENDOR.md)
agent (`bmad-tea`, pinned `v1.19.0`), consumed **by path** as plain markdown.
It advises on risk-based test strategy, fixture architecture, ATDD, API/UI
automation, CI/CD quality gates, and test review. It is **advisory on every
surface and writes nowhere** — the safe default for a new persona.

It is already consulted during planning by the Scrum Master overlay (see
[`prompts/bmad/scrum-master.md`](../../prompts/bmad/scrum-master.md), Step 4).
This manifest makes it a first-class, addressable persona.

## Why `qa-lead` and not the upstream agent's name

The vendored agent has a person-name upstream. We do not use it. A persona is
named for its **role** ([§1.6](https://github.com/combsmith/.github/blob/main/standards/persona-standards.md)):
`@combsmith/qa-lead` tells a reader in a PR comment who is being addressed
and why; the upstream cast list does not. It also means swapping the agent
underneath — or replacing it with a first-party layer — never changes how this
persona is addressed. Upstream is referenced only by its technical skill id
(`framework.skill: bmad-tea`).

## How it is addressed

```text
@combsmith/qa-lead please assess test risk on this PR
```

The handle is the org **team** `combsmith/qa-lead`, not a user account —
`@qa-lead` is a real GitHub account owned by an unrelated person, so a bare
role mention would notify a stranger on every use. The team is `privacy: closed`
with `notification_setting: notifications_disabled`: it exists to route a
webhook, not to page anyone. See
[§4.1](https://github.com/combsmith/.github/blob/main/standards/persona-standards.md).

## Status: draft

`qa-lead` ships **no dedicated reusable workflow yet**, so:

- there is **no `agents.qa-lead` entry in `canary-rings.json`** yet (nothing to
  roll out via rings until it has a reusable), and
- the manifest carries no `runtime:` block.

The `address` block and the `mention` surface are declared, but nothing
dispatches on them until the router and a runtime exist — declaring the
addressing contract is deliberately separate from serving it.

To promote `qa-lead` past `draft`:

1. Wire a dedicated advisory workflow (e.g. mention- or `check_run`-triggered
   test review) as a caller stub + reusable, and add its `runtime:` block.
2. Expand the held-out eval set under
   [`evals/qa-lead/holdout/`](../../evals/qa-lead/holdout/cases.jsonl). It
   already carries a synthetic starter set that clears the `min_cases` gate
   (6 held-out, 4 dev); grow it with real (de-identified) cases and wire the
   scorer/judge before promotion. The set lives under the repo `evals/` tree so
   `validate-cases.py` and `holdout-guard.yml` already cover it.
3. Register the one `agents.qa-lead` entry in `canary-rings.json` and cut
   `qa-lead/v0.1.0`.
4. Soak `next → ring0 → ring1 → stable`, eval gate green before `stable`.

The full gate is the Definition of Done in `persona-standards.md` §7.

## Contributing upstream

This persona's behavior lives upstream in
`bmad-code-org/bmad-method-test-architecture-enterprise`. Do not hand-edit
`frameworks/`. Org-specific behavior is layered via
`definition.layers[].local_overrides`; anything general enough to help other
BMAD users should be raised upstream (`upstream_candidate: true`) rather than
kept as private drift.
