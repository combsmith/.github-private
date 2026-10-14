# .github-private

Org-wide Copilot custom agents, Claude Code skills, and agentic workflow infrastructure for `combsmith`.

## What This Repo Does

This is the [`.github-private` convention](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/customize-cloud-agent/create-custom-agents) repo for the combsmith org. Agent profiles in `/agents/` are available org-wide — invocable from GitHub.com, VS Code, JetBrains, and Copilot CLI.

It also contains the scheduled PR review automation (workflows + scripts + prompts) that runs hourly across the org.

## Structure

```
agents/                  # Copilot custom agent profiles (org-wide)
  pr-reviewer.md         # Multi-tier cascading PR review
  feature-ideator.md     # Feature idea generation
  compliance-auditor.md  # Org standards compliance checking
prompts/                 # Prompt libraries used by workflows
scripts/                 # Shell orchestration for GitHub Actions
frameworks/              # Installed agentic frameworks (git subtree)
  bmad-method/           # BMAD-METHOD: multi-agent development lifecycle
  spec-kit/              # spec-kit: spec → plan → tasks pipeline
  gsd/                   # get-shit-done: context engineering & milestones
.github/workflows/       # Scheduled automation (PR review, health checks)
```

## Agents

| Agent | Purpose | Invoke with |
|-------|---------|-------------|
| `pr-reviewer` | Cascading PR review (triage → deep → security audit) | `@pr-reviewer` in any org PR |
| `feature-ideator` | Generate and prioritize feature ideas | `@feature-ideator` in any org repo |
| `compliance-auditor` | Audit repo against org standards | `@compliance-auditor` in any org repo |

## PR Review Automation

The scheduled workflow reviews all open PRs across `combsmith` hourly:
- Classifies risk (LOW/MEDIUM/HIGH) via cascading tiers
- Auto-approves LOW/MEDIUM risk PRs with passing CI
- Cross-engine adversarial review (Claude + Copilot rubber duck)
- Escalates HIGH risk or failing PRs to human review

Trigger manually: `gh workflow run pr-review.yml --repo combsmith/.github-private`

Mention trigger: Comment `@petry-review-bot` on any org PR for immediate review.

## Documentation

- [Architecture & Capabilities](docs/pr-review-agent/pr-review-agent.md)
- [Setup Guide](docs/pr-review-agent/setup.md)
- [Machine User Setup](docs/pr-review-agent/machine-user-setup.md)
