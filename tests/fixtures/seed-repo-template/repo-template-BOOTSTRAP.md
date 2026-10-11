# Bootstrap a new repo from this template

This template ships the org baseline: the thin-caller workflow stubs (pinned to
their published `@<name>/v<MAJOR>-stable` channel tags) and the root/baseline files. Most
of it works out of the box. Two things are **per-stack** and must be picked once,
after you create your repo from the template:

## 1. Pick your Dependabot stack

`.github/dependabot.yml` ships with the `frontend` (npm) stack by default.
Replace it with the stack that matches your project — the canonical stacks live
in `petry-projects/.github` under `standards/dependabot/<stack>.yml`. Available
stacks: `frontend` (npm), `backend-go`, `backend-python`, `backend-rust`,
`fullstack` (npm + Go + Terraform), and `infra-terraform`.

## 2. Customize `ci.yml` for your stack

`.github/workflows/ci.yml` ships as a documented **customize-per-stack stub**.
It runs the stack-agnostic checks out of the box; add your build/test/lint steps
for your language and toolchain. (The single-template default keeps one `ci.yml`
that you tailor; per-stack `ci.yml` variants remain an advisory open question and
are not required to start.)

## 3. Set your Sonar project key

If you enable the `sonarcloud` workflow, set `sonar.projectKey` /
`sonar.organization` in `sonar-project.properties` to match your repo.

## 4. Contributing & Commercial Support

All repositories in `petry-projects` automatically inherit the organization's canonical `CONTRIBUTING.md` from `petry-projects/.github` (do not add a bespoke `CONTRIBUTING.md` unless repo-specific overrides are strictly necessary). Ensure your repository's `README.md` includes the org-standard **Commercial Support & Integration** section referencing [CombSmith LLC](https://combsmith.com) per `standards/commercial-support-standard.md`.

---

## What this template does NOT do

Two onboarding questions are resolved here so they are not left implicit:

- **Framework subtrees (`frameworks/`) are opt-in — they are not seeded by this
  template.** The agentic frameworks (`bmad-method`, `spec-kit`, `gsd`) are
  `git subtree` development tooling maintained in `petry-projects/.github-private`;
  a product repo does not need them on day 0. If your project uses one, add it on
  demand with `git subtree add` against its upstream — see that repo's `AGENTS.md`.

- **App installs (Claude, CodeRabbit) are a manual org-admin step — the bootstrap
  does not install them.** `bootstrap-new-repo.sh` runs as `GITHUB_TOKEN` and
  cannot install org GitHub Apps; installation is a one-time org-level action by an
  org admin. The bootstrap only *disables those apps' check-suite auto-trigger* on
  the new repo (so queued-but-never-completed suites never block auto-merge),
  assuming the apps are already installed org-wide.

- **Advisory review bots (Gemini Code Assist, Codex) need per-repo enablement on
  their vendor consoles — the GitHub org App install is not enough.** These bots
  keep their own list of repos to review, separate from the GitHub App grant, so a
  brand-new repo is silent until it is added there. Without this, the pr-review
  advisory gate can wait indefinitely for reviews that never arrive.
    - **Gemini Code Assist:** in **Google Cloud → Developer Connect**
      (project `code-assist-<org>`, region `us-east1`), open the org's GitHub
      connection and **Link Repositories** for the new repo. The org GitHub App is
      `repository_selection: all` and does *not* by itself make Gemini review a new
      repo — Developer Connect is the gate.
    - **Codex (`chatgpt-codex-connector`):** enable code review for the new repo in
      the ChatGPT/OpenAI Codex connector settings.
    - **Verify:** open a throwaway PR and comment `/gemini review`; a
      `gemini-code-assist[bot]` review should post within a few minutes (compare
      against an established repo). CodeRabbit and SonarCloud work org-wide and
      need no per-repo step.

---

The rest — CODEOWNERS, AGENTS.md/CLAUDE.md pointers, LICENSE, SECURITY.md,
.gitignore — is ready as shipped. Repo settings, rulesets, labels, and security
configuration are applied separately by the org `bootstrap-new-repo.sh` flow.