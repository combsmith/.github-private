# Bootstrap a new repo from this template

This file is the **customization runbook** for a repository that was just created
from `combsmith/repo-template` with **Use this template**. It is written so an
agent (Claude Code, Copilot coding agent, Codex) can execute it end to end from
a handful of inputs, with a human doing only the org-admin steps it cannot.

Everything the template ships is already org-compliant. Bootstrapping is the
small set of edits that turn the generic scaffold into *this* project, plus the
removal of the files that only exist to test the template itself.

Run the steps in order. Each step says what to edit, what to leave alone, and
how to check it. When every step is done, including the hand-off (step 9) and the done criteria (step 10), delete this file as the very last action.

_Last validated end to end on 2026-10-20 with `STACK=backend-python` on a
throwaway repo: the untouched template was green on every check at creation,
and the bootstrap PR was green on every required check. The stack-specific
notes below (pip-audit file, ruff and Markdown, org-secret grant) come from
that run._

---

## 0. Inputs — collect these before editing anything

| Input | Example | Used by |
|---|---|---|
| `REPO` — `owner/name` of the new repo | `combsmith/hive-health` | `README.md`, `copilot-instructions.md`, `feature-ideation.yml` |
| `DESCRIPTION` — one sentence, what the repo is | `Beehive telemetry dashboard and alerting service` | `README.md`, `copilot-instructions.md`, repo description |
| `STACK` — one of `frontend`, `backend-go`, `backend-python`, `backend-rust`, `fullstack`, `infra-terraform`, `none` | `backend-python` | `dependabot.yml`, `ci.yml`, `copilot-setup-steps.yml`, `.gitignore` L2, `.github/instructions/` |
| `PROJECT_CONTEXT` — 3 to 5 sentences: product, target users, competitive landscape | see `feature-ideation.yml` header | `feature-ideation.yml` (`project_context`) |

Rules for an agent:

- If `STACK` or `PROJECT_CONTEXT` is missing, **ask once** and stop. Do not infer
  the stack from an empty repo.
- `none` is valid for `STACK` (docs-only or not-yet-decided repos): keep the
  shipped shell-based `ci.yml` and the `frontend` Dependabot file, and revisit
  when code lands.
- **Ask the maintainer to run step 9 item 1 (`bootstrap-new-repo.sh`) before
  you open the PR.** A repo fresh from the template has no rulesets, so nothing
  gates a merge: on the validation run the bootstrap PR was merged two minutes
  after it was opened, with no approving review, and a Dependabot major bump
  merged the same way. If the rulesets are not in place yet, open the PR as a
  **draft** and say so in the hand-off.
- Work on a branch and open one PR titled `chore: bootstrap from repo-template`.
  Never push to `main`. The PR body must carry the org's required sections,
  each at least one line: `## Problem`, `## Risk`, `## Test plan`,
  `## Rollback`, `## Monitoring` (PR triage escalates a PR missing three or
  more of them).
- Commit with a GitHub no-reply address (`<id>+<login>@users.noreply.github.com`,
  as in `git config user.email` of an existing checkout). GitHub rejects a push
  whose commits carry a private personal email (`GH007`).
- Run every `gh api … | base64 -d > file` download with `set -o pipefail` (or
  check the file is non-empty before using it). Without it, an auth or 404
  failure in `gh` is masked by `base64`'s zero exit and leaves an empty file.
- If the stack's toolchain is not available locally (wrong Python, no Node),
  do not fake a local run: push the branch and let the PR's CI verify. Report
  which checks you could and could not run.

---

## 1. File inventory — what to do with every shipped file

**Keep verbatim** (managed by org automation; the standards sweep re-syncs them
by PR, and the compliance audit flags any hand edit as drift):

| Path | Why it is untouchable |
|---|---|
| `.github/workflows/add-to-project.yml`, `agent-shield.yml`, `auto-rebase.yml`, `dependabot-automerge.yml`, `dependabot-rebase.yml`, `dependency-audit.yml`, `dev-lead.yml`, `initiative-driver.yml`, `persona-mention.yml`, `pr-auto-review.yml`, `pr-review-mention.yml` | Thin caller stubs. Behaviour lives in the org reusables; the `uses:` pin is moved centrally. `agent-shield.yml` is additionally a security boundary agents must never modify. |
| `.github/CODEOWNERS` | `* @combsmith/org-leads` must stay the first owner on every line. Add path lines only *after* it. |
| `CLAUDE.md`, `SECURITY.md`, `LICENSE` | Org pointers and license. |
| `.gitignore` — the block between `>>> BEGIN combsmith secrets baseline` and `<<< END` | Hash-checked by the compliance audit. Edit only **below** the END marker. |
| `.gitleaks.toml` | Keep the file; you may only **append** allowlist paths under `[allowlist]`. |
| `.github/workflows/sonarcloud.yml` | Keep as shipped; the `SonarCloud` job name is a required check, and it derives `sonar.projectKey` / `sonar.organization` from the repo (`<owner>_<name>` / `<owner>`), so no per-repo key is needed. |

**Customize** (step numbers below):

| Path | Step |
|---|---|
| `.github/dependabot.yml` | 2 |
| `.github/workflows/ci.yml` | 3 |
| `.github/workflows/copilot-setup-steps.yml` | 4 |
| `.github/workflows/feature-ideation.yml` | 5 |
| `sonar-project.properties` | 6 (only if `sonar.sources` / `sonar.tests` need narrowing) |
| `README.md`, `AGENTS.md`, `.github/copilot-instructions.md`, `.github/instructions/` | 7 |
| `.gitignore` (below the END marker), `.worktreeinclude` | 7 |

**Delete** (template-only; they exist to test the template repo itself):

| Path | Why |
|---|---|
| `tests/*.bats` | Regression guards for *this template's* stubs and its shell `ci.yml`. In a product repo they fail the moment `ci.yml` is customized, and the org compliance audit already guards the stubs. Delete them (step 8 names the one narrow exception for shell-script repos). If PR automation asks for the `ack-test-deletion` label, add it: these are not product tests. |
| `standards/rulesets/pr-quality.json` | Codified copy used by the template's tests. The live ruleset is applied to the new repo by `bootstrap-new-repo.sh` (step 9). |
| `BOOTSTRAP.md` | This runbook, deleted as the very last action after step 10. |

---

## 2. Dependabot — pick the stack

For `STACK=none`, skip this step: keep the shipped `frontend` file untouched.
Otherwise replace `.github/dependabot.yml` with the canonical file for `STACK`
(`frontend` ships by default). Every stack file already contains the required
`github-actions` entry; do not add a second one.

```bash
set -o pipefail
gh api repos/combsmith/.github/contents/standards/dependabot/${STACK}.yml \
  --jq '.content' | base64 -d > .github/dependabot.yml.new \
  && [ -s .github/dependabot.yml.new ] \
  && mv .github/dependabot.yml.new .github/dependabot.yml
```

Adjust only `directory:` paths if manifests are not at the repo root. Policy:
[`standards/dependabot-policy.md`](https://github.com/combsmith/.github/blob/main/standards/dependabot-policy.md).

`fullstack.yml` carries `npm`, `gomod`, `terraform` and `github-actions`
entries but **no `pip` entry**. A `fullstack` repo that also has Python code
adds the `pip` block from `backend-python.yml` (same `schedule`, `groups` and
`labels` shape as the other entries; adjust `directory:`), still with a single
`github-actions` entry.

**Python stacks (`backend-python`, or `fullstack` with Python) also need
`scripts/pip-audit-requirements.txt`.** The org `dependency-audit` reusable's
`pip-audit` job installs pip-audit from that hash-pinned file in the consumer
repo and fails with "No such file" when it is absent (observed on the
validation run). Copy it verbatim:

```bash
mkdir -p scripts
gh api repos/combsmith/.github/contents/scripts/pip-audit-requirements.txt \
  --jq '.content' | base64 -d > scripts/pip-audit-requirements.txt \
  && [ -s scripts/pip-audit-requirements.txt ]
```

The other ecosystems (npm, pnpm, Go, Cargo) need no extra file; their audit
jobs key off the lockfile.

Check: the file parses as YAML with `version: 2`. Use whichever parser is
installed: `yq '.version' .github/dependabot.yml` or
`python3 -c 'import yaml; print(yaml.safe_load(open(".github/dependabot.yml"))["version"])'`
(PyYAML is not in the standard library; `python3 -m pip install pyyaml` if needed).

---

## 3. `ci.yml` — replace the shell checks with your stack's checks

For `STACK=none`, skip this step: there are no stack-specific checks, so keep
the shipped shell-based `ci.yml` as is.

`.github/workflows/ci.yml` ships with three jobs. Keep all three job ids and
display names; two of them are org required checks and the third is this repo's
required CI check:

| Job id | `name:` | What to change |
|---|---|---|
| `build-and-test` | `build-and-test` | Replace the *Install tools*, *Lint shell scripts* and *Run bats tests* steps with your stack's lint, format check, type check and unit tests. |
| `secret-scan` | `Secret scan (gitleaks)` | Nothing. |
| `coverage` | `coverage` | Replace the shell/bats block with your stack's coverage command (examples are in the file's trailing comment). It must stay green when no tests exist yet. |

Do **not** change: the workflow `name: CI` (`pr-auto-review.yml` waits on that
name), the triggers, `permissions: {}` at top level with `contents: read` per
job, the `concurrency` block, or `timeout-minutes` on every job. SHA-pin every
third-party action (`uses: owner/action@<40-char sha> # vX.Y.Z`). Keep the
retry-with-increasing-backoff pattern for any network install step; the Fleet
Monitor flags flaky installs.

Stack patterns:
[`ci-standards.md` → Workflow Patterns by Tech Stack](https://github.com/combsmith/.github/blob/main/standards/ci-standards.md#workflow-patterns-by-tech-stack).
Those patterns show `@vN` tags; the SHA-pinned equivalents for `setup-node`,
`pnpm/action-setup`, `setup-go` and `setup-python` are already in the comment
blocks of `copilot-setup-steps.yml`. To pin any other action, resolve the tag
yourself and record the tag in the trailing comment:

```bash
gh api repos/<owner>/<action>/git/ref/tags/<tag> --jq '.object | "\(.type) \(.sha)"'
# type "commit" → use the sha. type "tag" (annotated) → dereference once more:
gh api repos/<owner>/<action>/git/tags/<sha> --jq '.object.sha'
```

Stack notes from the validation run:

- **Coverage guard.** When the stack has no tests yet, let the test runner
  decide (`python -m pytest --collect-only -q`, `npm test -- --listTests`, …)
  rather than globbing filenames, so both `test_*.py` and `*_test.py` styles
  count. Treat only the runner's documented "no tests collected" result as the
  green-until-tests case and propagate every other exit code. For pytest that
  result is exit status 5:

  ```bash
  rc=0
  python -m pytest --collect-only -q >/dev/null 2>&1 || rc=$?   # `|| rc=$?` keeps bash -e from aborting on exit 5
  if [ "$rc" -eq 5 ]; then echo "No tests found — coverage is green until tests exist."; exit 0; fi
  [ "$rc" -eq 0 ] || exit "$rc"
  python -m pytest -q --cov=src --cov-report=term --cov-report=xml
  ```
- **Python.** `ruff format --check .` also formats Python code blocks inside
  Markdown, including the copied `.github/instructions/python.instructions.md`.
  Either run `ruff format` once over the repo before committing, or add
  `extend-exclude = [".github/instructions"]` under `[tool.ruff]`.

Check: the file still parses as YAML (same parser options as step 2), and both
the job ids and the display names are intact (each command prints `3`):

```bash
grep -cE '^  (build-and-test|secret-scan|coverage):$' .github/workflows/ci.yml
grep -cE '^    name: (build-and-test|Secret scan \(gitleaks\)|coverage)$' .github/workflows/ci.yml
```

---

## 4. `copilot-setup-steps.yml` — enable your stack block

In `.github/workflows/copilot-setup-steps.yml`, uncomment the block(s) matching
`STACK` (Node/npm, Node/pnpm, Go, Python) and **delete** the blocks that do not
apply. Do not touch the job name, the fork guard, the triggers, or the
*Verify environment* step. For `STACK=none`, leave the file as shipped.

---

## 5. `feature-ideation.yml` — set `project_context`

Replace the `TODO:`/`Example:` placeholder under `project_context:` with
`PROJECT_CONTEXT`. This is the only edit allowed in that file; the compliance
audit raises `feature-ideation-placeholder-context` until it is done.

Check: `! grep -q 'TODO: Replace this' .github/workflows/feature-ideation.yml` exits 0.

---

## 6. `sonar-project.properties` — nothing to set unless you narrow the sources

`sonarcloud.yml` derives `sonar.projectKey` (`<owner>_<name>`) and
`sonar.organization` (`<owner>`) from the repo at run time, so the shipped
file needs no project key and **no edit** for most repos. SonarCloud
auto-provisions the project on the first scan; it is enabled org-wide and no
console step is needed for a public repo. Do not add `sonar.projectKey` or
`sonar.organization` to the file: the workflow's `-D` arguments take precedence
over the properties file, so a value there cannot override the derived identity
and would only mislead the next reader.

Edit the file only if the defaults (`sonar.sources=.` plus the
`node_modules`/`vendor`/`dist` exclusions) are wrong for this repo:

- `sonar.sources` — the source directories, e.g. `src`, if scanning `.` pulls
  in generated or vendored code the exclusions do not cover.
- `sonar.tests` — the test directory; omit the line if there are no tests yet.
  If you add it, also narrow `sonar.sources` so the two do not overlap: with
  `sonar.sources=.` and `sonar.tests=tests` every file under `tests/` is in
  both scopes and the analysis fails with `can't be indexed twice`.

If the repo is ever renamed, the derived key changes with it. Keep the history
by updating the key on the existing SonarCloud project (Administration → Update
Key) to the new `<owner>_<name>` rather than adding an override here.

Java properties files only treat `#` as a comment at the start of a line: a
trailing `# note` after a value becomes part of the value, so do not annotate
the lines themselves.

---

## 7. Docs and per-repo config

1. **`README.md`** — replace everything above the `---` rule with the project's
   own title, `DESCRIPTION`, quick start and usage. **Keep the
   `## 💼 Commercial Support & Enterprise Services` section verbatim**; it is
   org-standard text.
2. **`AGENTS.md`** — keep the org-standards pointer paragraph. Replace the
   template-specific sections with this repo's: project overview and
   architecture, `## Local Development Commands`, `## Required Environment
   Variables`, testing approach and coverage threshold, code style. The two
   `##` headings named here are mandatory per the org `AGENTS.md`.
3. **`.github/copilot-instructions.md`** — rewrite for this repo following the
   required sections in
   [`copilot-instructions-standard.md`](https://github.com/combsmith/.github/blob/main/standards/copilot-instructions-standard.md)
   (About, Tech Stack, Project Structure, Local Dev Commands, Required
   Environment Variables, Testing Framework, Repo-Specific Overrides, Org
   Standards). Keep it to about two pages.
4. **`.github/instructions/`** — for each language in `STACK`, copy the
   canonical path-scoped file and list it under `## Org Standards` in
   `copilot-instructions.md`. The language list follows from `STACK`; add
   `shell` whenever the repo has shell scripts of its own, whatever the stack,
   and `python` for a `fullstack` repo that has Python code (the same repos
   that add the `pip` Dependabot block in step 2). The canonical repo has no
   Rust file, so `STACK=backend-rust` gets no language-specific instruction
   file:

   | `STACK` | Languages |
   |---|---|
   | `frontend` | `typescript javascript` |
   | `backend-go` | `go` |
   | `backend-python` | `python` |
   | `backend-rust` | none |
   | `infra-terraform` | `terraform` |
   | `fullstack` | `typescript javascript go terraform`, plus `python` when the repo has Python code |
   | `none` | none |

   ```bash
   set -o pipefail
   mkdir -p .github/instructions
   case "$STACK" in
     frontend)          langs="typescript javascript" ;;
     backend-go)        langs="go" ;;
     backend-python)    langs="python" ;;
     infra-terraform)   langs="terraform" ;;
     fullstack)         langs="typescript javascript go terraform" ;;
     backend-rust|none) langs="" ;;
     *) echo "unknown STACK: $STACK" >&2; exit 1 ;;
   esac
   if find . -path ./.git -prune -o -name '*.sh' -print -quit | grep -q .; then
     langs="$langs shell"
   fi
   if [ "$STACK" = fullstack ] \
     && find . -path ./.git -prune -o -name '*.py' -print -quit | grep -q .; then
     langs="$langs python"
   fi
   for lang in $langs; do
     gh api repos/combsmith/.github/contents/.github/instructions/${lang}.instructions.md \
       --jq '.content' | base64 -d > .github/instructions/${lang}.instructions.md \
       && [ -s .github/instructions/${lang}.instructions.md ]
   done
   ```

5. **`.gitignore`** — append the matching
   [github/gitignore](https://github.com/github/gitignore) template **below**
   the `<<< END combsmith secrets baseline <<<` marker. Never re-ignore a path
   the baseline negates (`!.env.example`, `!*.crt`, `!*.pub`, `!*.enc.yaml`).
6. **`.worktreeinclude`** (optional) — list gitignored files agents need copied
   into worktrees, typically `.env` and `.env.local`.
7. **`.gitleaks.toml`** — append allowlist paths only for real false positives
   (test fixtures, generated keys). Keep the `_bmad/` entry.

Check: no template placeholder text survives. The patterns below are the
template's own wording, so a project that legitimately mentions
`repo-template` (for example in a provenance line) still passes. `grep` exits
`1` for "no match" and `2` for an error such as a missing file; only `1` is a
pass, so a negated `! grep -q …` would silently pass when a listed file is
absent. Branch on the exit code instead:

```bash
rc=0
grep -E 'Org baseline scaffold|combsmith_repo-template|Copilot Instructions — repo-template|What this repository is' \
    README.md AGENTS.md .github/copilot-instructions.md sonar-project.properties || rc=$?
case "$rc" in
  1) echo "OK: no template placeholder text" ;;
  0) echo "FAIL: template placeholder text survives (matches above)" >&2; exit 1 ;;
  *) echo "ERROR: grep exited $rc — a listed file is missing or unreadable" >&2; exit "$rc" ;;
esac
```

---

## 8. Remove template-only files

Every template Bats file other than `tests/ci-*.bats` (the `*-stub.bats`
guards, `gitignore-baseline.bats`, `pr-quality-ruleset.bats`,
`dependabot-github-actions-ecosystem.bats`, `pr-auto-review-concurrency.bats`)
tests the template, not the project, and goes in every repo. Derive the set
from the directory rather than naming files, so nothing is left behind:

```bash
find tests -maxdepth 1 -name '*.bats' ! -name 'ci-*.bats' -exec git rm {} +
git rm -r standards
```

The `tests/ci-*.bats` files guard the template's shell `ci.yml` and go too,
with one exception: a `STACK=none` repo whose code is itself shell scripts
tested with Bats may keep individual `tests/ci-*.bats` files as a starting
point. For every other repo:

```bash
git rm tests/ci-*.bats
```

Remove only the Bats files, not the `tests/` directory: your own test suite
(`tests/test_*.py`, `tests/*.test.ts`, …) may already live there or will.

Do **not** install agent frameworks here. BMAD and the other frameworks are
**vendored** into a repo as `git subtree` from `combsmith/.github-private` (or
`software-factory`) when a project needs them; never run `npx bmad-method
install`, and never ask the maintainer whether to. `_bmad/` stays allowlisted
in `.gitleaks.toml` for the vendored case.

---

## 9. Org-admin steps (human; the agent cannot do these)

Report these to the maintainer as the hand-off. None of them require code changes.

| # | Action | Command / where |
|---|---|---|
| 1 | Apply repo settings, GHAS + push protection, the `pr-quality` and `code-quality` rulesets, the standard label set, CODEOWNERS verification, and confirm the release ring. | In a checkout of `combsmith/.github`: `DRY_RUN=true bash scripts/bootstrap-new-repo.sh REPO`, review, then `bash scripts/bootstrap-new-repo.sh REPO`. Needs a classic PAT with `repo` + `admin:org`. |
| 2 | Set the repo description and topics; enable Discussions and create the **Ideas** (💡) and **General** (💬) categories. | `gh repo edit REPO --description "DESCRIPTION"`; categories via Settings → Discussions (no REST API). |
| 3 | Add the new repo to the advisory review bots' per-repo lists. | Gemini Code Assist: Google Cloud → Developer Connect (`code-assist-<org>`, `us-east1`) → Link Repositories. Codex: ChatGPT Codex connector settings. Verify with a throwaway PR and `/gemini review`. CodeRabbit and SonarCloud need no per-repo step. |
| 4 | Confirm CodeQL default setup is `configured` (the org security configuration applies it at creation; step 1 re-asserts it). | `gh api repos/REPO/code-scanning/default-setup --jq .state` |
| 5 | Grant the new repo access to the **selected-visibility** org secrets `INITIATIVES_APP_ID` and `INITIATIVES_APP_PRIVATE_KEY` (the `combsmith-planner` app), and make sure that app's installation includes the repo. Until then every `add-to-project` run fails with `The 'client-id' … must be set to a non-empty string` (observed on the validation run). | Org settings → Secrets and variables → Actions → each secret → Repository access; or `gh api -X PUT orgs/combsmith/actions/secrets/INITIATIVES_APP_ID/repositories/<repo_id>` (same for the private key). |

All other org secrets the stubs use (`SONAR_TOKEN`, `APP_ID`/`APP_PRIVATE_KEY`,
`GH_PAT_WORKFLOWS`, `CLAUDE_CODE_OAUTH_TOKEN`) have **all-repositories**
visibility and need nothing per repo. The Claude and CodeRabbit GitHub Apps are
installed org-wide. `DRY_RUN=true` for item 1 was verified to print the full plan
and `PASS` with a plain `gh auth token`; the real run needs the classic PAT
because the CodeQL and check-suite-preference reads return 404 otherwise.

---

## 10. Done criteria

- [ ] `.github/dependabot.yml` is the `STACK` file (or `frontend` for `none`).
- [ ] `ci.yml` runs the stack's lint / format / typecheck / tests / coverage; jobs `build-and-test`, `Secret scan (gitleaks)`, `coverage` still exist; workflow is still named `CI`.
- [ ] `copilot-setup-steps.yml` has exactly the stack block(s) enabled.
- [ ] `feature-ideation.yml` carries a real `project_context`.
- [ ] `README.md`, `AGENTS.md`, `copilot-instructions.md` describe this repo; language instruction files copied and listed.
- [ ] `tests/*.bats` and `standards/` removed (step 8 exception aside).
- [ ] No stub listed under *Keep verbatim* has a diff.
- [ ] The bootstrap PR is green on `build-and-test`, `Secret scan (gitleaks)`, `coverage`, `SonarCloud`, `CodeQL`, `agent-shield / AgentShield`, `dependency-audit / Detect ecosystems`, and on the stack's own audit job (`dependency-audit / pip-audit`, `npm audit`, `govulncheck` or `cargo audit`). `dev-lead / *` jobs showing *cancelled* is normal: a burst of review events collapses them onto the newest run.
- [ ] Hand-off message to the maintainer lists the five org-admin actions in step 9, and says `add-to-project` will stay red until item 5 is done.
- [ ] Last action: `git rm BOOTSTRAP.md` and commit, once every item above is checked.

---

## Why the template looks the way it does

- **Stubs are a distribution artifact.** Everything under *Keep verbatim* is
  regenerated from [`combsmith/.github`](https://github.com/combsmith/.github)
  `standards/` by `seed-repo-template.sh` (in `combsmith/.github-private`) and
  kept in sync in every repo by `deploy-standard-workflows.sh`. Fix the
  standard, not the copy.
- **Framework subtrees (`frameworks/`) are not seeded.** `bmad-method`,
  `spec-kit` and `gsd` are `git subtree` tooling maintained in
  `combsmith/.github-private`; add one on demand with `git subtree add`.
- **App installs are org-level.** The bootstrap script only disables the
  Claude/CodeRabbit check-suite auto-trigger on the new repo so queued-but-never-
  completed suites cannot block auto-merge.

Standards index: [`combsmith/.github/AGENTS.md`](https://github.com/combsmith/.github/blob/main/AGENTS.md).