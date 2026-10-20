# repo-template

Org baseline scaffold for new `combsmith` repositories. Click **Use this
template** to create a repo pre-wired with the standard workflow stubs and
baseline files, then hand the new repo to an agent with:

> Follow `BOOTSTRAP.md` to bootstrap this repo. Stack: `<frontend | backend-go |
> backend-python | backend-rust | fullstack | infra-terraform | none>`.
> Description: `<one sentence>`. Project context: `<3–5 sentences>`.

**[BOOTSTRAP.md](./BOOTSTRAP.md)** is the agent-executable runbook: the inputs
to collect, what to do with every shipped file (keep / customize / delete), the
verification checks, and the short list of org-admin steps a human finishes.

## What you get on day 0

| Area | Shipped | Status in a new repo |
|---|---|---|
| Thin-caller workflow stubs (dev-lead, pr-auto-review, pr-review-mention, persona-mention, dependabot-automerge/rebase, dependency-audit, agent-shield, auto-rebase, add-to-project, initiative-driver, feature-ideation) | `.github/workflows/` | Working as-is; `feature-ideation.yml` needs its `project_context` set |
| CI (`build-and-test`, `Secret scan (gitleaks)`, `coverage`) and SonarCloud | `ci.yml`, `sonarcloud.yml` | Green out of the box; replace the shell steps with your stack's |
| Copilot cloud-agent setup | `copilot-setup-steps.yml` | Uncomment your stack block |
| Dependabot | `.github/dependabot.yml` | `frontend` stack by default; swap for yours |
| Baseline files | `CODEOWNERS`, `AGENTS.md`, `CLAUDE.md`, `SECURITY.md`, `LICENSE`, `.gitignore` (secrets baseline), `.gitleaks.toml`, `sonar-project.properties`, `copilot-instructions.md` | Docs and Sonar key need the project's name |
| Repo settings, rulesets, labels, GHAS | not files | Applied by `bootstrap-new-repo.sh` in `combsmith/.github` (org admin) |
| Initiatives board (`add-to-project`) | stub only | Red until an org admin both grants the repo the `INITIATIVES_APP_*` org secrets (selected visibility) and adds it to the `combsmith-planner` app installation |

The workflow stubs and baseline files here are a distribution artifact of the org
standards in [`combsmith/.github`](https://github.com/combsmith/.github)
(`standards/`) and are regenerated from it — edit the standards, not this copy.
`tests/` holds the bats guards that keep this template byte-aligned with those
standards; they are template-only and are removed during bootstrap.

---