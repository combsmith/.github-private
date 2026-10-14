# security-lead — persona

Formalized under the [Agentic Persona Standard](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md).
Follows the **wrap-a-vendored-framework-agent, advisory-everywhere** path
established by [`qa-lead`](../qa-lead/README.md) and
[`scrum-master`](../scrum-master/README.md).

## What security-lead is

`security-lead` wraps the vendored [BMAD B-Great Suite](../../frameworks/bmad-bgreat-suite/VENDOR.md)
security agent (`bgr-agent-sam-security`, pinned `ae8914e84b87`), consumed **by
path** as plain markdown. It advises on threat modeling (STRIDE/PASTA), security
architecture (defense in depth, least privilege), compliance mapping
(SOC2/HIPAA/PCI/GDPR), and supply-chain security (SCA/SBOM/provenance). It is
**advisory on every surface and writes nowhere** — the safe default for a new
persona. The advisory contract lives in
[`prompts/security-lead/advisory.md`](../../prompts/security-lead/advisory.md).

## Why `security-lead` and not the upstream agent's name

The vendored agent has a person-name upstream ("Sam"). We do not use it. A
persona is named for its **role** ([§1.6](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md)):
`@petry-projects/security-lead` tells a reader in a PR comment who is being
addressed and why; the upstream cast list does not. It also means swapping the
agent underneath — or replacing it with a first-party layer — never changes how
this persona is addressed. Upstream is referenced only by its technical skill id
(`framework.skill: bgr-agent-sam-security`).

## How it is addressed

```text
@petry-projects/security-lead please threat-model this design
```

The handle is the org **team** `petry-projects/security-lead`, **never** the bare
`@security-lead` account — that is a real GitHub account owned by an unrelated
person, so a bare role mention would notify a stranger on every use. The team is
`privacy: closed` with `notification_setting: notifications_disabled`: it exists
to route a webhook, not to page anyone. See
[§4.1](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md).

## Overlap with existing security surfaces

`security-lead` is **advisory, not a replacement** for the org's existing
security automation:

- [`agents/compliance-auditor.md`](../../agents/compliance-auditor.md) audits a
  repo against org standards (CI, agent config, push protection) and can auto-fix
  non-breaking gaps. `security-lead` does not audit or fix — it advises a human on
  threat models and compliance strategy when mentioned.
- [`dependency-audit.yml`](../../.github/workflows/dependency-audit.yml) is a
  scheduled dependency/supply-chain audit workflow. `security-lead` complements
  its findings with human-facing risk framing; it does not run scans or gate
  merges.

Neither is superseded — `security-lead` is a mention-invoked advisor that sits
alongside them.

## Status: draft

`security-lead` ships **no dedicated reusable workflow yet**, so:

- there is **no `agents.security-lead` entry in `canary-rings.json`** yet
  (nothing to roll out via rings until it has a reusable), and
- the manifest carries no `runtime:` block.

The `address` block and the `mention` surface are declared, but nothing
dispatches on them until the router and a runtime exist — declaring the
addressing contract is deliberately separate from serving it.

To promote `security-lead` past `draft`:

1. Wire a dedicated advisory workflow (e.g. mention-triggered security review) as
   a caller stub + reusable, and add its `runtime:` block.
2. Expand the held-out eval set under
   [`evals/security-lead/holdout/`](../../evals/security-lead/holdout/cases.jsonl).
   It carries a synthetic starter set; grow it to `min_cases` with real
   (de-identified) cases and wire the scorer/judge before promotion. The set
   lives under the repo `evals/` tree so `validate-cases.py` and `holdout-guard.yml`
   already cover it.
3. Register the one `agents.security-lead` entry in `canary-rings.json` and cut
   `security-lead/v0.1.0`.
4. Soak `next → ring0 → ring1 → stable`, eval gate green before `stable`.

The full gate is the Definition of Done in `persona-standards.md` §7.

## Contributing upstream

This persona's behavior lives upstream in
`petry-projects/bmad-bgreat-suite`. Do not hand-edit `frameworks/`. Org-specific
behavior is layered via `definition.layers[].local_overrides`; anything general
enough to help other BMAD users should be raised upstream
(`upstream_candidate: true`) rather than kept as private drift.
