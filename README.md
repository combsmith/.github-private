# .github-private

[![Contributing](https://img.shields.io/badge/contributions-welcome-brightgreen.svg)](https://github.com/petry-projects/.github/blob/main/CONTRIBUTING.md)

Org-wide Copilot custom agents, automated workflows, prompts, scripts, and frameworks for `petry-projects`.

## What This Repo Does

This is the [`.github-private` convention](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/customize-cloud-agent/create-custom-agents) repo for the petry-projects org.
Agent profiles in `/agents/` are available org-wide — invocable from GitHub.com, VS Code, JetBrains, and Copilot CLI.

It also contains automated workflows (GitHub Actions agents running on events and schedules),
prompts, scripts, and the scheduled reporting dashboards that run across the org.

It also contains the scheduled PR review automation (workflows + scripts + prompts) that runs hourly across the org.

## Structure

```
agents/                   # Copilot custom agent profiles (org-wide)
  agentic-workflows.md    # Agentic workflow orchestration
  compliance-auditor.md   # Org standards compliance checking
  feature-ideator.md      # Feature idea generation
  pr-reviewer.md          # Multi-tier cascading PR review
prompts/                  # Prompt libraries used by workflows
scripts/                  # Shell orchestration for GitHub Actions
frameworks/               # Installed agentic frameworks (git subtree)
  bmad-bgreat-suite/      # bmad-bgreat-suite @ ae8914e84b87: SRE, DevOps, and Security agents
  bmad-method/            # BMAD-METHOD v6.8.0: multi-agent development lifecycle
  bmad-test-architecture/ # bmad-method-test-architecture-enterprise v1.19.0
.github/workflows/        # Scheduled automation (PR review, health checks)
```

## @-Mention Agents

| Agent | Purpose | Invoke with |
|-------|---------|-------------|
| [`agentic-workflows`](agents/agentic-workflows.md) | Agentic workflow orchestration | `@agentic-workflows` in any org repo |
| [`compliance-auditor`](agents/compliance-auditor.md) | Audit repo against org standards | `@compliance-auditor` in any org repo |
| [`feature-ideator`](agents/feature-ideator.md) | Generate and prioritize feature ideas | `@feature-ideator` in any org repo |
| [`pr-reviewer`](agents/pr-reviewer.md) | Cascading PR review (triage → deep → security audit) with cross-engine adversarial review (see also [`pr-review-trigger.yml`](.github/workflows/pr-review-trigger.yml) for scheduled automation) | `@pr-reviewer` in any org PR |

## Automated Workflows

Autonomous agents that run as GitHub Actions, triggered by events or schedules across the org.

| Workflow | Purpose |
|----------|---------|
| [`ci-failure-analyst-reusable.yml`](.github/workflows/ci-failure-analyst-reusable.yml) | CI failure analyst — diagnoses failed CI/Lint/Test runs and comments root-cause analysis |
| [`feature-ideation.yml`](.github/workflows/feature-ideation.yml) | Feature research & ideation agent (BMAD Analyst) — turns sources into scoped feature ideas |
| [`idea-triage.yml`](.github/workflows/idea-triage.yml) | Idea triage agent — scores queued ideas and promotes them into the backlog |
| [`initiative-driver.yml`](.github/workflows/initiative-driver.yml) | Initiative driver — auto-releases an epic's ready sub-issues to Dev-Lead |
| [`initiative-planner.yml`](.github/workflows/initiative-planner.yml) | Initiative planner (BMAD Scrum Master) — breaks an approved initiative into an epic + sub-issues |
| [`issue-triage-runner.yml`](.github/workflows/issue-triage-runner.yml) | Issue triage agent — labels and routes newly opened issues |
| [`pr-review-trigger.yml`](.github/workflows/pr-review-trigger.yml) | PR review agent — cascading triage → deep → security review on open PRs across the org; auto-approves LOW/MEDIUM risk PRs with passing CI, escalates HIGH risk to human review (see also [`@pr-reviewer`](agents/pr-reviewer.md)). Trigger manually: `gh workflow run pr-review-trigger.yml --repo petry-projects/.github-private` or comment `@petry-review-bot` on any org PR |
| [`release-notes.yml`](.github/workflows/release-notes.yml) | Release-notes agent — drafts Keep-a-Changelog entries from merged PRs and opens a CHANGELOG PR |
| [`stale-manager.yml`](.github/workflows/stale-manager.yml) | Stale manager agent — warns and closes stale issues/PRs across the org |

## Reporting & Dashboards

Scheduled workflows post reports and dashboards as issues or run summaries for maintainers.

**In this repo (`.github-private`):**

| Workflow | Purpose |
|----------|---------|
| [`actions-fleet-monitor.yml`](.github/workflows/actions-fleet-monitor.yml) | Actions fleet monitor — org-wide workflow token usage and run anomalies |
| [`auto-rebase-health.yml`](.github/workflows/auto-rebase-health.yml) | Daily auto-rebase health report (issue) — rebase success/failure trends |
| [`daily-pr-review-health.yml`](.github/workflows/daily-pr-review-health.yml) | Daily PR-review health check — flags PR-review agent failures as an issue |
| [`docs-health-check.yml`](.github/workflows/docs-health-check.yml) | Docs health check — flags stale/broken docs as an issue |
| [`engine-token-liveness.yml`](.github/workflows/engine-token-liveness.yml) | Engine-token liveness monitor — asserts dev-lead/pr-review caller stubs are not failing at the "Engine token preflight" step, and escalates a sustained fleet-wide outage that would otherwise go unalerted (#1587) |
| [`premature-closure-audit.yml`](.github/workflows/premature-closure-audit.yml) | Premature-closure audit — flags issues closed as completed with no merged closing PR, and OPEN issues carrying an unbacked completion claim (#1445) |
| [`reviewer-report.yml`](.github/workflows/reviewer-report.yml) | Reviewer scorecard (per workflow-run summary) — per-reviewer PR-review activity |
| [`skill-eval-report.yml`](.github/workflows/skill-eval-report.yml) | Skill-eval results report — agent skill pass/fail trends (self-improving-skills pipeline) |
| [`token-report.yml`](.github/workflows/token-report.yml) | LLM token-cost report (per workflow-run summary) for maintainers |

**In `.github` (org-level):**

| Workflow | Purpose |
|----------|---------|
| [`compliance-audit-and-improvement.yml`](https://github.com/petry-projects/.github/blob/main/.github/workflows/compliance-audit-and-improvement.yml) | Weekly org standards compliance audit + runtime health survey, with per-finding remediation issues |
| [`daily-org-status.yml`](https://github.com/petry-projects/.github/blob/main/.github/workflows/daily-org-status.yml) | Daily "Org Status" digest posted as an issue for maintainers |
| [`org-scorecard.yml`](https://github.com/petry-projects/.github/blob/main/.github/workflows/org-scorecard.yml) | Weekly OpenSSF Scorecard security-posture review across public repos; findings tracked as issues |
| [`standards-deploy.yml`](https://github.com/petry-projects/.github/blob/main/.github/workflows/standards-deploy.yml) | Weekly fleet sweep that opens standards-sync PRs for repos drifted off the org-standard workflow stubs |

## Standards

Engineering standards live in `petry-projects/.github/standards/`.
Notable subtopics are listed below to aid discoverability; see the standards directory for full documentation.

| Standard | Notable subtopics |
|----------|-------------------|
| [`advanced-security`](https://github.com/petry-projects/.github/blob/main/standards/advanced-security.md) | Code Security Configurations, push-protection live-fire (canary), licensing & billing, compliance audit checks |
| [`agent-rate-limits`](https://github.com/petry-projects/.github/blob/main/standards/agent-rate-limits.md) | Token-budget breaker, canary scope (enforcing vs log-only), daily budget as per-agent cost bound, exempt actors, operator runbook |
| [`agent-standards`](https://github.com/petry-projects/.github/blob/main/standards/agent-standards.md) | Required files, compliance exemptions, AgentShield CI workflow, decision-making reusables, BMAD Method Workflows |
| [`ci-standards`](https://github.com/petry-projects/.github/blob/main/standards/ci-standards.md) | Staged promotion through concentric rings, reusable workflow versioning (`stable` channel), action pinning policy, permissions policy, Dev-Lead Agent |
| [`codeowners-standard`](https://github.com/petry-projects/.github/blob/main/standards/codeowners-standard.md) | Team composition, required setup for new bots, branch protection, verified end-to-end |
| [`copilot-instructions-standard`](https://github.com/petry-projects/.github/blob/main/standards/copilot-instructions-standard.md) | Canonical instruction files, adding a new language, required sections, content quality rules |
| [`dependabot-policy`](https://github.com/petry-projects/.github/blob/main/standards/dependabot-policy.md) | Configuration files, auto-merge workflow, vulnerability audit CI check, applying to a repository |
| [`feature-ideation-sources`](https://github.com/petry-projects/.github/blob/main/standards/feature-ideation-sources.md) | AI/ML vendor & lab sources, developer tooling changelogs, security & compliance sources, newsletters, podcasts |
| [`github-settings`](https://github.com/petry-projects/.github/blob/main/standards/github-settings.md) | Org-level settings, repository rulesets, required checks ruleset, GitHub Apps & integrations, org-level secrets |
| [`gitignore-standard`](https://github.com/petry-projects/.github/blob/main/standards/gitignore-standard.md) | Two-Layer Model (L1 secrets baseline, L2 ecosystem extension), managed-block markers, negation discipline, compliance check |
| [`initiatives-project`](https://github.com/petry-projects/.github/blob/main/standards/initiatives-project.md) | Project board fields, Theme → Initiative, how auto-add works, initiative classification |
| [`persona-standards`](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md) | Canary onboarding (the last step), trigger matrix, trust & permissions, definition of done |
| [`pr-limits`](https://github.com/petry-projects/.github/blob/main/standards/pr-limits.md) | Exempt actors, operator runbook, reconciliation with the Dependabot cap |
| [`push-protection`](https://github.com/petry-projects/.github/blob/main/standards/push-protection.md) | Layer 1 (GitHub push protection), Layer 2 (local pre-commit), Layer 3 (CI secret scanning), incident response |
| [`ruleset-remediation-runbook`](https://github.com/petry-projects/.github/blob/main/standards/ruleset-remediation-runbook.md) | Bypass actors, migrate checks into `code-quality`, delete legacy rulesets, rollback procedure |
| [`standards-versioning`](https://github.com/petry-projects/.github/blob/main/standards/standards-versioning.md) | Two tag forms, who/what moves it, cutting a release, N-1 resolvability, opting in |

## Documentation

- [Architecture & Capabilities](docs/pr-review-agent/pr-review-agent.md)
- [Setup Guide](docs/pr-review-agent/setup.md)
- [Machine User Setup](docs/pr-review-agent/machine-user-setup.md)

---

## 💼 Commercial Support & Agent Architecture Advisory

Building agentic workflows, autonomous CI/CD pipelines, or enterprise AI coding agent infrastructure?

Commercial support and enterprise services are offered through **[CombSmith LLC](https://combsmith.com)**:
- **Standard SLA & Priority Support:** $199/month per organization for managed workflow maintenance, issue triage, and security updates.
- **Custom Agent Engineering & Architecture Advisory:** $250/hour for bespoke Copilot agents, autonomous GitHub Actions workflows, multi-agent frameworks (BMAD), and automated PR review pipelines.
- **Consulting & Implementation:** Architectural guidance, token-budget governance, and enterprise CI/CD integration.

For commercial inquiries, email [support@combsmith.com](mailto:support@combsmith.com) or visit [combsmith.com](https://combsmith.com).

---

## Contributing

See the org-wide [Contributing Guide](https://github.com/petry-projects/.github/blob/main/CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
