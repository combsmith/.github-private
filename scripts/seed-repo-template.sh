#!/usr/bin/env bash
set -euo pipefail
# seed-repo-template.sh — DRY_RUN-aware generator that seeds the org baseline file
# scaffold into combsmith/repo-template so a template click yields the
# standard layout with no manual copying (issue #966, epic #964).
#
# The scaffold is a DISTRIBUTION ARTIFACT of standards/ in the public
# combsmith/.github repo — regenerable from it, NOT a hand-edited fork. This
# script therefore FETCHES the ~10 thin-caller workflow stubs from
# standards/workflows/ and the Dependabot config from standards/dependabot/, then:
#
#   • copies the workflow stubs byte-identically (AC #1), and
#   • repins each CALLER stub from the local `./…`/`@<name>/next` dogfood ref the
#     source repo uses internally to the PUBLISHED channel tag a consumer must pin
#     (`@<name>/v<MAJOR>-stable`; public reusables on combsmith/.github, the
#     private dev-lead reusable on combsmith/.github-private). Inline workflows
#     (ci/copilot-setup-steps/sonarcloud) carry no reusable ref and ship verbatim
#     (AC #2). ci.yml is a customize-per-stack stub; the post-clone "pick your
#     Dependabot + ci.yml stack" step is documented in the generated BOOTSTRAP.md
#     (AC #4).
#
# It also emits the root/baseline files (AC #3): AGENTS.md (consumer pointer),
# CLAUDE.md (1-line pointer), .github/CODEOWNERS, .github/dependabot.yml (from the
# chosen standards/dependabot/<stack>), sonar-project.properties, .gitignore,
# LICENSE, README.md, BOOTSTRAP.md (SECURITY.md is inherited org-wide from
# combsmith/.github). No issue/PR templates and no
# labeler config are introduced (AC #5). README.md's commercial-support section is
# read from standards/commercial-support-standard.md at the resolved ref (#2233).
#
# A live run that finds an open seed-scaffold/* PR on the target updates that PR's
# branch rather than opening another (#2233).
#
# Cross-repo file creation follows the aw-standards-sync.sh / bootstrap-new-repo.sh
# pattern (branch + contents API PUT + a single gh pr create); it never pushes
# directly to the default branch.
#
# Usage:
#   bash scripts/seed-repo-template.sh                       # seed the default repo (opens a PR)
#   bash scripts/seed-repo-template.sh --repo owner/name     # seed a specific repo
#   DRY_RUN=true bash scripts/seed-repo-template.sh          # print intent, no writes
#   bash scripts/seed-repo-template.sh --list-workflows      # list shipped workflow stubs
#   bash scripts/seed-repo-template.sh --list-baseline       # list shipped baseline files
#   bash scripts/seed-repo-template.sh --emit-workflow ci.yml        # print the shipped stub
#   bash scripts/seed-repo-template.sh --emit-baseline AGENTS.md     # print a baseline file
#   printf '%s' "$content" | bash scripts/seed-repo-template.sh --repin auto-rebase  # pure repin
#
# No workflow runs a seed. An operator does, following
# docs/release/seeding-repo-template.md (dry run first; leave STANDARDS_REF unset).
# The seed PR body records the standards ref, its source and its commit; older open
# seed PRs are closed as superseded; and a file that is AHEAD of the resolved ref is
# refused rather than downgraded (#1925).
#
# Env:
#   DRY_RUN          "true" → print intent, make no write API calls.
#   TEMPLATE_REPO    target repo to seed (default combsmith/repo-template).
#   STANDARDS_REPO   repo holding the canonical standards/ (default combsmith/.github).
#   STANDARDS_DIR    optional local checkout of STANDARDS_REPO; when set, files are
#                    read from disk instead of the GitHub API (regeneration seam,
#                    retained for tests — #1448 step 2).
#   STANDARDS_REF    explicit ref to fetch standards content at (a tag, branch, or
#                    SHA). When empty (default), the ref is RESOLVED: the published
#                    corpus-level stable channel (STANDARDS_CHANNEL) if it exists,
#                    else the default-branch HEAD commit SHA (a logged fallback while
#                    the step-1 publication scheme is unavailable). A standards read
#                    is therefore NEVER an unpinned default-branch read (#1448 AC #7).
#   STANDARDS_CHANNEL the published corpus-level moving channel the fetch defaults
#                    to (default standards/v1-stable, #1448 step 1).
#   DEPENDABOT_STACK standards/dependabot/<stack>.yml to ship as .github/dependabot.yml
#                    (default frontend; one of: frontend, backend-go, backend-python,
#                    backend-rust, fullstack, infra-terraform).
#   GH_TOKEN         PAT with repo scope (create a branch + PR on TEMPLATE_REPO).

SEED_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

DRY_RUN="${DRY_RUN:-false}"
TEMPLATE_REPO="${TEMPLATE_REPO:-combsmith/repo-template}"
STANDARDS_REPO="${STANDARDS_REPO:-combsmith/.github}"
STANDARDS_REF="${STANDARDS_REF:-}"
STANDARDS_CHANNEL="${STANDARDS_CHANNEL:-standards/v1-stable}"
DEPENDABOT_STACK="${DEPENDABOT_STACK:-frontend}"

_is_dry() { [ "$DRY_RUN" = "true" ]; }

# _require <cmd>... — fail loud if any listed command is missing. Checked at the
# point of use (not unconditionally up front) so the local-only emit seams — e.g.
# --emit-workflow of a docs/ reference, which only cats a file — stay reachable
# without gh/base64, which they never invoke (#1724).
_require() {
  local cmd rc=0
  for cmd in "$@"; do
    command -v "$cmd" > /dev/null 2>&1 || { echo "::error::${cmd} is required but not installed." >&2; rc=1; }
  done
  return "$rc"
}

# ── Ownership boundary: the drift allowlist is the single source of truth ──────
# scripts/template_stub_drift.sh owns TEMPLATE_DRIFT_ALLOWLIST — the files the
# drift checker treats as intentionally per-consumer (currently ci.yml). The
# seeder must not overwrite those on an already-seeded repo (#1812 AC #2), so we
# DERIVE the list by sourcing that one file rather than copying the paths here —
# copying is the exact drift this script pair already demonstrates. Include-guarded
# so a caller that already sourced it does not hit a readonly re-declaration.
if ! declare -p TEMPLATE_DRIFT_ALLOWLIST > /dev/null 2>&1; then
  # shellcheck source=scripts/template_stub_drift.sh
  source "${SEED_REPO_ROOT}/scripts/template_stub_drift.sh"
fi

# ── Workflow manifest ─────────────────────────────────────────────────────────
# One row per shipped stub: "name|kind|host".
#   kind=caller → wraps <name>-reusable.yml; repinned to <host>@<channel>, where
#                 <channel> is DERIVED from the canonical stub's own major-scoped
#                 `uses:` ref (`<name>/v<MAJOR>-stable`, #1184) — not hardcoded, so
#                 a channel promotion (v2→v3) cannot reintroduce a stale pin (#1436).
#   kind=inline → self-contained; shipped byte-identically (host unused).
# ci is the documented customize-per-stack inline stub (AC #4).
readonly -a WORKFLOW_MANIFEST=(
  "agent-shield|caller|combsmith/.github"
  "auto-rebase|caller|combsmith/.github"
  "ci|inline|-"
  "copilot-setup-steps|inline|-"
  "dependabot-automerge|caller|combsmith/.github"
  "dependabot-rebase|caller|combsmith/.github"
  "dependency-audit|caller|combsmith/.github"
  "dev-lead|caller|combsmith/.github-private"
  "pr-review-mention|caller|combsmith/.github"
  "sonarcloud|inline|-"
)

# ── Reference manifest (ADR-0007, #1724) ──────────────────────────────────────
# NON-executing canonical references emittable by name via --emit-workflow but
# DELIBERATELY NOT in WORKFLOW_MANIFEST: they are byte-identity baselines authored
# under docs/, NOT stubs seeded into repo-template (that would double-dispatch the
# per-role callers — a behavior change forbidden by #1724 AC #5). So --list-workflows
# and _seed_repo never include them; only --emit-workflow reaches them, reading the
# local file verbatim (no standards fetch, no repin). One row: "name|repo-relative-path".
readonly -a REFERENCE_MANIFEST=(
  "agent-ingress|docs/architecture/reference/agent-ingress.yml"
)

# _reference_row <name-with-or-without-.yml> — echo the matching REFERENCE_MANIFEST
# row, or return 1 if the name is not a known reference.
_reference_row() {
  local key="${1%.yml}" row
  for row in "${REFERENCE_MANIFEST[@]}"; do
    [ "${row%%|*}" = "$key" ] && { printf '%s\n' "$row"; return 0; }
  done
  return 1
}

# _emit_reference <row> — print a reference artifact verbatim from its local path.
_emit_reference() {
  local path="${1#*|}" file
  file="${SEED_REPO_ROOT}/${path}"
  if [ ! -f "$file" ]; then
    echo "::error::reference artifact not found: ${path}" >&2
    return 1
  fi
  cat "$file"
}

# Baseline files (AC #3). One row per file: "path|source".
#   source=gen → generated inline by _gen_baseline.
#   source=fetch:<standards-path> → fetched verbatim from STANDARDS_REPO at that path.
#   source=fetch (bare) → the Dependabot stack special case (path is DEPENDABOT_STACK-derived).
readonly -a BASELINE_MANIFEST=(
  "AGENTS.md|gen"
  "CLAUDE.md|gen"
  ".github/CODEOWNERS|gen"
  ".github/dependabot.yml|fetch"
  ".gitleaks.toml|fetch:standards/gitleaks.toml"
  "sonar-project.properties|gen"
  ".gitignore|gen"
  "LICENSE|gen"
  "README.md|gen"
  "BOOTSTRAP.md|gen"
)

# _manifest_row <name-with-or-without-.yml> — echo the matching WORKFLOW_MANIFEST
# row, or return 1 if the stub is unknown.
_manifest_row() {
  local key="${1%.yml}" row
  for row in "${WORKFLOW_MANIFEST[@]}"; do
    [ "${row%%|*}" = "$key" ] && { printf '%s\n' "$row"; return 0; }
  done
  return 1
}

# ── Resolve the ref standards content is fetched at (#1448 AC #7, #10) ─────────
# The pre-#1448 bug read standards/ from the default branch WITHOUT a ref, so the
# "expected" baseline was whatever combsmith/.github had at the moment of
# execution — the same commit passed or failed template-drift purely on WHEN the
# check ran. The fetch is now pinned to an explicit, logged ref.
#
# Precedence (memoized in _STD_REF / _STD_SHA / _STD_SRC; first call resolves):
#   1. STANDARDS_DIR set    → local checkout seam; ref="STANDARDS_DIR", no network.
#   2. STANDARDS_REF set     → explicit override, used verbatim.
#   3. STANDARDS_CHANNEL      → the published corpus-level stable channel, IF it
#                              resolves to a commit (step-1 publication scheme live).
#   4. otherwise              → the default-branch HEAD commit SHA (AC #10): the
#                              step-1 prerequisite is not yet published, so the fetch
#                              stays on HEAD but resolves to a concrete SHA that is
#                              LOGGED, so runs stay explainable rather than mysterious.
# Never resolves to an unpinned default-branch read.

# _ref_commit_sha <ref> — commit SHA <ref> resolves to on STANDARDS_REPO, or empty
# if the ref does not exist / cannot be read.
_ref_commit_sha() {
  gh api "repos/${STANDARDS_REPO}/commits/${1}" --jq '.sha' 2>/dev/null || true
}

_resolve_standards_ref() {
  if [ -n "${_STD_REF+x}" ]; then printf '%s' "$_STD_REF"; return 0; fi
  local ref sha src
  if [ -n "${STANDARDS_DIR:-}" ]; then
    ref="STANDARDS_DIR"; sha=""; src="local"
  elif [ -n "${STANDARDS_REF:-}" ]; then
    ref="$STANDARDS_REF"; sha=""; src="explicit"
  else
    _require gh || return 1
    sha="$(_ref_commit_sha "$STANDARDS_CHANNEL")"
    if [ -n "$sha" ]; then
      ref="$STANDARDS_CHANNEL"; src="channel"
    else
      sha="$(_ref_commit_sha HEAD)"; ref="${sha:-HEAD}"; src="head-fallback"
    fi
  fi
  _STD_REF="$ref"; _STD_SHA="$sha"; _STD_SRC="$src"
  printf '%s' "$_STD_REF"
}

# _resolved_standards_sha — commit SHA of the resolved ref (for logging + the drift
# report). Computed lazily so the explicit-ref emit path makes no extra API call
# unless a caller actually wants the SHA. Empty for the STANDARDS_DIR local seam.
_resolved_standards_sha() {
  _resolve_standards_ref > /dev/null
  if [ -z "${_STD_SHA:-}" ] && [ "$_STD_REF" != "STANDARDS_DIR" ]; then
    _STD_SHA="$(_ref_commit_sha "$_STD_REF")"
  fi
  printf '%s' "${_STD_SHA:-}"
}

# ── Fetch a path from the canonical standards repo (or a local checkout) ───────
_fetch_standard() {
  local path="$1" ref
  if [ -n "${STANDARDS_DIR:-}" ] && [ -f "${STANDARDS_DIR}/${path}" ]; then
    cat "${STANDARDS_DIR}/${path}"
    return 0
  fi
  _require gh || return 1
  ref="$(_resolve_standards_ref)"
  # A seed run pins every read to the commit it recorded in the PR body (#1925).
  # Reading through the ref name would follow a channel that moved mid-run, and the
  # PR would then name a commit its content did not come from.
  [ -z "${_STD_PIN:-}" ] || ref="$_STD_PIN"
  local -a ref_q=()
  case "$ref" in
    ""|STANDARDS_DIR) : ;;                 # no explicit ref (local seam / default)
    *) ref_q=(-f "ref=${ref}") ;;          # GET field → URL-encoded ?ref=<ref>
  esac
  gh api --method GET -H "Accept: application/vnd.github.v3.raw" \
    "repos/${STANDARDS_REPO}/contents/${path}" "${ref_q[@]}" 2>/dev/null
}

# ── Derive the published channel from the canonical stub (AC #1, #2) ───────────
# Reads stub content on stdin and derives the channel a consumer must pin: the
# SAME major-scoped line as the canonical stub's own `<name>-reusable.yml@<ref>`
# pin, `stable` tier (`<name>/v<MAJOR>-stable`, #1184). This tracks the canonical
# stub's major line instead of a hardcoded per-stub channel that goes stale on a
# promotion (v2→v3) — the pre-#1184 skew that made template-drift's baseline
# contradict standards/ (#1436). Fails loud on a non-major-scoped ref: a canonical
# stub that is not major-scoped is itself a standards violation, and silently
# emitting a legacy `<name>/stable` pin is exactly the bug this replaces.
_derive_stable_channel() {
  local name="$1" ref ref_matches
  ref_matches="$(grep -oE "${name}-reusable\.yml@[^[:space:]\"']+" || true)"
  ref="${ref_matches%%$'\n'*}"
  ref="${ref#*@}"
  if [[ "$ref" =~ ^${name}/v([0-9]+)(-|$) ]]; then
    printf '%s/v%s-stable\n' "$name" "${BASH_REMATCH[1]}"
    return 0
  fi
  echo "::error::could not derive a major-scoped stable channel for ${name} — canonical stub ref '${ref:-<none>}' is not <name>/v<MAJOR>-<tier> (#1184)." >&2
  return 1
}

# ── Repin a caller stub (AC #1, #2) ───────────────────────────────────────────
# Reads stub content on stdin; rewrites the `uses:` ref for <name>-reusable.yml
# (whether a local ./… ref or any owner/repo@ref form) to <host>@<channel>, and
# repins any `agent_ref:` value to <channel>, where <channel> is DERIVED from the
# stub's own major-scoped ref via _derive_stable_channel. Inline stubs (no reusable
# ref) and unrelated lines pass through unchanged. Indentation is preserved.
_repin_stub_content() {
  local name="$1" host="$2" content channel
  content="$(cat)"
  channel="$(printf '%s' "$content" | _derive_stable_channel "$name")" || return 1
  printf '%s' "$content" | sed -E \
    -e "s#^([[:space:]]*)uses:[[:space:]]*[^[:space:]]*${name}-reusable\.yml(@[^[:space:]]*)?#\1uses: ${host}/.github/workflows/${name}-reusable.yml@${channel}#" \
    -e "s#^([[:space:]]*)(agent_ref:[[:space:]]*['\"]?)[^[:space:]'\"]+#\1\2${channel}#"
}

# _emit_workflow <name.yml> — fetch the stub from standards/ and (for callers)
# repin it; print the shipped content.
_emit_workflow() {
  local row name kind host content
  # NON-executing canonical references (ADR-0007) are emittable by name but read
  # from their local docs/ path verbatim — no standards fetch, no repin.
  if row="$(_reference_row "$1")"; then
    _emit_reference "$row"
    return $?
  fi
  row="$(_manifest_row "$1")" || { echo "::error::unknown workflow stub: $1" >&2; return 2; }
  IFS='|' read -r name kind host <<<"$row"
  content="$(_fetch_standard "standards/workflows/${name}.yml")" || content=""
  if [ -z "$content" ]; then
    echo "::error::could not fetch standards/workflows/${name}.yml from ${STANDARDS_REPO}" >&2
    return 1
  fi
  if [ "$kind" = "caller" ]; then
    _repin_stub_content "$name" "$host" <<< "$content"
  else
    printf '%s\n' "$content"
  fi
}

# ── Commercial-support README section (#2233) ─────────────────────────────────
# Prints the canonical README block of standards/commercial-support-standard.md:
# the body of the first ```markdown fence under its "## Canonical README Section"
# heading, fetched at the resolved standards ref. Fails loud if the standard or
# the block is missing — emitting README.md without it would delete the section.
readonly COMMERCIAL_SUPPORT_STANDARD="standards/commercial-support-standard.md"

_commercial_support_section() {
  local content section
  content="$(_fetch_standard "$COMMERCIAL_SUPPORT_STANDARD")" || content=""
  if [ -z "$content" ]; then
    echo "::error::could not fetch ${COMMERCIAL_SUPPORT_STANDARD} from ${STANDARDS_REPO}" >&2
    return 1
  fi
  section="$(printf '%s\n' "$content" | awk '
    /^## Canonical README Section[[:space:]]*$/ { in_sec = 1; next }
    in_sec && !in_block && /^## / { exit }
    in_sec && !in_block && /^```markdown[[:space:]]*$/ { in_block = 1; next }
    in_block && /^```[[:space:]]*$/ { done = 1; exit }
    in_block { print }
    END { if (!done) exit 1 }
  ')" || section=""
  if [ -z "$section" ]; then
    echo "::error::no \`\`\`markdown block under '## Canonical README Section' in ${COMMERCIAL_SUPPORT_STANDARD}" >&2
    return 1
  fi
  printf '%s\n' "$section"
}

# ── Baseline file content (AC #3, #4) ─────────────────────────────────────────
_gen_baseline() {
  case "$1" in
    AGENTS.md) cat <<'EOF'
# AGENTS.md

This repository follows the organization-wide development standards defined in
[`combsmith/.github/AGENTS.md`](https://github.com/combsmith/.github/blob/main/AGENTS.md).

Read that file before making changes that touch CI, agent configuration, repo
settings, or labels. Repo-specific deviations, if any, are documented below.

## What this repository is

`repo-template` is the org's **template repository**: the scaffold every new
`combsmith` repo starts from via **Use this template**. It has no application
code. Its contents are the org-standard workflow stubs, baseline files, and a
bats suite that guards them.

- **Creating a repo from this template?** Follow [`BOOTSTRAP.md`](./BOOTSTRAP.md).
  It is an agent-executable runbook: inputs, per-file actions, verification,
  and the org-admin hand-off.
- **Changing this template?** Most files here are a distribution artifact of
  `combsmith/.github` `standards/` and are regenerated by
  `seed-repo-template.sh` (in `combsmith/.github-private`). Edit the standard,
  not the copy. Only `tests/` and `.github/copilot-instructions.md` are owned
  here outright. `README.md`, `BOOTSTRAP.md`, `AGENTS.md` and
  `sonar-project.properties` are *generated* by the seeder: a change made here
  must also be mirrored into the seeder's heredocs, or the next seed PR will
  propose reverting it.

## Local Development Commands

- Install: none (no application dependencies). Tests need `bats`, `shellcheck`,
  `yq`, `python3` with PyYAML, and GNU bash 5 (`brew install bash bats-core shellcheck yq`;
  on macOS run tests with Homebrew bash first on `PATH`, stock bash 3.2 cannot
  parse the test heredocs).
- Dev run: n/a
- Test: `bats tests/`
- Lint: `find . -path ./.git -prune -o -name '*.sh' -exec shellcheck {} +` (no
  shell scripts ship today, so a bare `shellcheck *.sh` fails on the unmatched
  glob; CI uses `shopt -s nullglob` for the same reason)
- Typecheck: n/a

## Required Environment Variables

- None for local work. CI secrets (`SONAR_TOKEN`, `APP_ID`/`APP_PRIVATE_KEY`,
  `GH_PAT_WORKFLOWS`, `CLAUDE_CODE_OAUTH_TOKEN`) are org-level and inherited.

## Rules specific to this template

- **Stubs are byte-exact.** `tests/*-stub.bats` compare each thin-caller
  workflow against an inline snapshot of the canonical template, trailing
  newline included (the committed stubs have none). Never reformat them.
- **`ci.yml` and `sonarcloud.yml` are intentionally ahead of the canonical
  templates** (retry/backoff, timeouts, `persist-credentials: false`). They are
  allowlisted in the template drift guard; keep their invariants in sync with
  `tests/ci-*.bats` and `tests/sonarcloud-stub.bats`.
- **No `TODO`/`FIXME` in workflow files.** SonarCloud rule S1135 is enforced by
  the stub tests. Reword to `Customize:`.
- **Deleting a file under `tests/`** may be gated by PR automation on the
  `ack-test-deletion` label (created by the org bootstrap). Add it if asked.
EOF
      ;;
    CLAUDE.md) cat <<'EOF'
See [AGENTS.md](./AGENTS.md), which points to the org standards in `combsmith/.github`.
EOF
      ;;
    .github/CODEOWNERS) cat <<'EOF'
# Default owner for all files
* @combsmith/org-leads
EOF
      ;;
    sonar-project.properties) cat <<'EOF'
# Project key / organization are derived from the repo by .github/workflows/sonarcloud.yml.
sonar.sources=.
sonar.exclusions=**/node_modules/**,**/vendor/**,**/dist/**
EOF
      ;;
    .gitignore) cat <<'EOF'
# OS / editor
.DS_Store
*.swp
.idea/
.vscode/

# Dependencies / build output
node_modules/
dist/
build/
coverage/

# Logs / env
*.log
.env
.env.*
EOF
      ;;
    LICENSE) cat <<'EOF'
MIT License

Copyright (c) combsmith

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
      ;;
    README.md)
      # The commercial-support section is read from the standard at the resolved
      # standards ref, never copied here, so the seed cannot strip or fork it (#2233).
      local section
      section="$(_commercial_support_section)" || return 1
      cat <<'EOF'
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
| Baseline files | `CODEOWNERS`, `AGENTS.md`, `CLAUDE.md`, `LICENSE`, `.gitignore` (secrets baseline), `.gitleaks.toml`, `sonar-project.properties`, `copilot-instructions.md` | Docs need the project's name; the Sonar key is derived from the repo by `sonarcloud.yml` |
| Repo settings, rulesets, labels, GHAS | not files | Applied by `bootstrap-new-repo.sh` in `combsmith/.github` (org admin) |
| Initiatives board (`add-to-project`) | stub only | Red until an org admin both grants the repo the `INITIATIVES_APP_*` org secrets (selected visibility) and adds it to the `combsmith-planner` app installation |

The workflow stubs and baseline files here are a distribution artifact of the org
standards in [`combsmith/.github`](https://github.com/combsmith/.github)
(`standards/`) and are regenerated from it — edit the standards, not this copy.
`tests/` holds the bats guards that keep this template byte-aligned with those
standards; they are template-only and are removed during bootstrap.

---

EOF
      printf '%s\n' "$section"
      ;;
    BOOTSTRAP.md) cat <<'EOF'
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
| `CLAUDE.md`, `LICENSE` | Org pointer and license (`SECURITY.md` is inherited org-wide from `combsmith/.github`). |
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
EOF
      ;;
    *) echo "::error::no generator for baseline file: $1" >&2; return 2 ;;
  esac
}

# ── Scope Dependabot out of the byte-identity workflow artifacts (#1435) ───────
# Reads a dependabot.yml on stdin and DROPS the `github-actions` package-ecosystem
# block, passing every other ecosystem (npm/gomod/pip/…) through unchanged.
#
# repo-template's shipped workflows are a DISTRIBUTION ARTIFACT of standards/ and
# are kept current by re-seeding, not by Dependabot. A `github-actions` Dependabot
# run in the template edits those artifacts directly — every bump changes a
# committed blob, drifts template-drift, and (because a non-required red check
# halts pr-review here) silently stops review. Dependabot's github-actions
# ecosystem has no per-file exclusion, so the whole ecosystem is scoped out; this
# also correctly stops Dependabot from bumping the first-party channel-tag pins in
# the caller stubs (the sanctioned mutable-ref exception). See AGENTS.md
# "Template drift guard (repo-template)".
#
# A block is the `- package-ecosystem:` list item and all of its deeper-indented
# child lines; its immediately-preceding comment line(s) are discarded with it.
_dependabot_scope_out_actions() {
  awk '
    /^[[:space:]]*#/ {
      match($0, /^[[:space:]]*/)
      if (drop && RLENGTH < drop_indent) { drop = 0 }
      pending = pending $0 ORS; next
    }
    /^[[:space:]]*-[[:space:]]+package-ecosystem:/ {
      match($0, /^[[:space:]]*/)
      drop_indent = RLENGTH
      if ($0 ~ /github-actions/) { drop = 1; pending = "" }
      else { drop = 0; printf "%s", pending; pending = ""; print }
      next
    }
    {
      match($0, /^[[:space:]]*/)
      if (drop && RLENGTH < drop_indent) { drop = 0 }
      if (!drop) { printf "%s", pending; print }
      pending = ""
    }
    END { if (!drop) printf "%s", pending }
  '
}

# _emit_baseline <path> — print a baseline file's shipped content.
_emit_baseline() {
  local path="$1" row source
  for row in "${BASELINE_MANIFEST[@]}"; do
    [ "${row%%|*}" = "$path" ] && { source="${row#*|}"; break; }
  done
  if [ -z "${source:-}" ]; then
    echo "::error::unknown baseline file: $path" >&2
    return 2
  fi
  local content std_path scope_actions=0
  if [ "$source" = "gen" ]; then
    _gen_baseline "$path"
  else
    if [ "$source" = "fetch" ]; then
      # Dependabot special case: the standards path is DEPENDABOT_STACK-derived.
      # Scope github-actions out so a Dependabot bump can't drift the template (#1435).
      std_path="standards/dependabot/${DEPENDABOT_STACK}.yml"
      scope_actions=1
    elif [ "${source#fetch:}" != "$source" ]; then
      # General verbatim fetch: source=fetch:<standards-path> (e.g. .gitleaks.toml).
      std_path="${source#fetch:}"
      if [ -z "$std_path" ]; then
        echo "::error::empty standards path in source '${source}' for ${path}" >&2
        return 2
      fi
    else
      echo "::error::unknown baseline source '${source}' for ${path}" >&2
      return 2
    fi
    content="$(_fetch_standard "$std_path")" || content=""
    if [ -z "$content" ]; then
      echo "::error::could not fetch ${std_path} from ${STANDARDS_REPO}" >&2
      return 1
    fi
    if [ "$scope_actions" = 1 ]; then
      printf '%s\n' "$content" | _dependabot_scope_out_actions
    else
      printf '%s\n' "$content"
    fi
  fi
}

# ── Managed-block ownership (AC #1) ────────────────────────────────────────────
# A file may carry a block owned by a DIFFERENT managed process, delimited by a
# marker of the form `>>> BEGIN … (managed by <owner> — do not edit) >>>`. The
# live case is the org secrets baseline synced into .gitignore from the
# gitignore-standard (combsmith/.github): a 420-line L1 block the seeder does
# not own. Detection is GENERIC — any content carrying a "managed by … do not
# edit" marker is treated as owned elsewhere and preserved, regardless of path —
# so the next managed file is not discovered by losing it (#1812).
_content_has_managed_marker() {
  printf '%s' "${1:-}" | grep -qiE 'managed by .*do not edit'
}

# _existing_file_content <repo> <path> <ref> — decoded content of the file as it
# currently exists in <repo> at <ref>, or empty if it is absent (404). Mirrors the
# decode path in template_stub_drift.sh (gh api → jq .content → base64 -d), kept
# separate from the jq call so a 404 JSON body yields "" rather than a spurious
# blob. Trailing newlines are stripped by the caller's $()-capture, symmetrically
# with the emitted content, so a trailing-newline-only difference is not "drift".
_existing_file_content() {
  local repo="$1" path="$2" ref="$3" out rc=0
  _require gh jq base64 || return 1
  out="$(gh api "repos/${repo}/contents/${path}?ref=${ref}" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # A 404 is the ONE benign failure: the file is genuinely absent → empty content.
    # Any other failure (auth, rate-limit, 5xx, network) must abort loudly rather
    # than masquerade as "absent", which would let _seed_file CREATE over a file it
    # simply could not read (#1812; codeant/gemini review of #1868).
    if grep -q '"message":[[:space:]]*"Not Found"' <<< "$out"; then
      return 0
    fi
    echo "::error::gh api failed (exit ${rc}) reading ${path} on ${repo}@${ref}: ${out}" >&2
    return "$rc"
  fi
  jq -r '.content // empty' <<< "$out" 2>/dev/null | base64 -d 2>/dev/null || true
}

# _seed_report_dry <path> <action> <reason> <existing> <new> — under DRY_RUN,
# report the per-file decision, naming any content that would be REPLACED and its
# magnitude, so a destructive write is visible before it happens (#1812 AC #4).
_seed_report_dry() {
  local path="$1" action="$2" reason="$3" existing="$4" content="$5" old_lines new_lines
  old_lines="$(printf '%s' "$existing" | grep -c '' 2>/dev/null || true)"
  new_lines="$(printf '%s' "$content" | grep -c '' 2>/dev/null || true)"
  case "$action" in
    create) echo "  [dry-run] would CREATE ${path} (${new_lines} lines) — ${reason}" ;;
    write)
      if [ "$new_lines" -lt "$old_lines" ]; then
        echo "  [dry-run] would REPLACE ${path}: ${old_lines}-line file → ${new_lines}-line content (DESTRUCTIVE — ${reason})"
      else
        echo "  [dry-run] would UPDATE ${path}: ${old_lines} → ${new_lines} lines (${reason})"
      fi ;;
    preserve) echo "  [dry-run] would PRESERVE ${path} (${old_lines} lines) — ${reason}; NOT overwriting" ;;
    ahead)    echo "  [dry-run] would REFUSE ${path} (${old_lines} lines) — ${reason}; NOT overwriting" ;;
    skip)     echo "  [dry-run] would SKIP ${path} — ${reason} (no change)" ;;
  esac
}

# ── No downgrades (#1925 AC #3) ───────────────────────────────────────────────
# The seed writes each file as it is at the RESOLVED standards ref, normally the
# published channel. The channel lags the standards default branch until someone
# promotes it. A template file that already matches the emission at a NEWER
# standards commit is therefore ahead of the channel, and writing the channel's
# version over it is a downgrade: on 2026-09-23 a seed PR would have stripped the
# merge_group trigger a previous seed had shipped.
#
# So a file that differs from this run's emission is compared once more, against
# the emission at the standards default-branch HEAD. A match is AHEAD: the seed
# refuses to overwrite it and reports that the channel is behind the template.
# This is the same test template_stub_drift.sh uses for its AHEAD status, and it
# reuses that file's HEAD + ancestry reads (#1926, #2237).
#
# "Cannot tell" is never "not ahead": if the HEAD commit, its relation to the
# resolved ref, or the HEAD emission cannot be read, the seed aborts instead of
# overwriting a file it could not check.
_SEED_NEWER_STATE=""   # "" (not resolved yet) | none | newer | unknown
_SEED_NEWER_SHA=""
_SEED_WRITES=0         # files written by this run
_SEED_AHEAD=()         # paths refused because the template is ahead

# _seed_newer_standards — resolve ONCE whether the standards default branch is past
# the resolved ref. Sets _SEED_NEWER_STATE / _SEED_NEWER_SHA; call it in the
# current shell (not $()) so the result is kept.
#   none    — nothing newer: the resolved ref already is HEAD, or it is ahead of /
#             diverged from HEAD (an explicit STANDARDS_REF off the default
#             branch), or the STANDARDS_DIR local seam, which has no ref at all.
#   newer   — the resolved commit is an ancestor of HEAD (_SEED_NEWER_SHA).
#   unknown — HEAD, the resolved commit, or their relation could not be read.
_seed_newer_standards() {
  [ -z "$_SEED_NEWER_STATE" ] || return 0
  _SEED_NEWER_STATE="none"; _SEED_NEWER_SHA=""
  [ "${_STD_SRC:-}" != "local" ] || return 0
  local head relation
  head="$(_template_drift_head_sha)"
  if [ -z "$head" ] || [ -z "${_STD_SHA:-}" ]; then
    _SEED_NEWER_STATE="unknown"
    return 0
  fi
  [ "$head" != "$_STD_SHA" ] || return 0
  relation="$(_template_drift_compare "$_STD_SHA" "$head")"
  case "$relation" in
    ahead) _SEED_NEWER_STATE="newer"; _SEED_NEWER_SHA="$head" ;;
    identical|behind|diverged) : ;;
    *) _SEED_NEWER_STATE="unknown" ;;
  esac
}

# _seed_emit_at <ref> <emit_flag> <emit_arg> — the content this script emits for one
# file with standards pinned at <ref>. A child process, because the resolved ref is
# memoized per process. Non-zero when the emission fails or is empty.
_seed_emit_at() {
  local out
  out="$(STANDARDS_REF="$1" DRY_RUN=false bash "${SEED_REPO_ROOT}/scripts/seed-repo-template.sh" "$2" "$3" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# _seed_is_ahead <existing_content> <emit_flag> <emit_arg>
#   0 — <existing_content> matches the emission at a newer standards commit.
#   1 — it does not (or there is no newer commit): a normal update.
#   2 — it could not be checked; an ::error:: names what could not be read.
_seed_is_ahead() {
  local existing="$1" flag="$2" arg="$3" newer
  _seed_newer_standards
  case "$_SEED_NEWER_STATE" in
    none) return 1 ;;
    unknown)
      echo "::error::cannot tell whether ${STANDARDS_REPO} has a standards commit newer than ${_STD_REF:-the resolved ref} — refusing to overwrite a differing file that may be ahead of it (#1925)" >&2
      return 2 ;;
  esac
  if ! newer="$(_seed_emit_at "$_SEED_NEWER_SHA" "$flag" "$arg")"; then
    echo "::error::cannot compute the standards HEAD (${_SEED_NEWER_SHA:0:12}) emission for ${arg} — refusing to overwrite a differing file that may be ahead of ${_STD_REF} (#1925)" >&2
    return 2
  fi
  [ "$existing" = "$newer" ]
}

# _seed_report_ahead — after the per-file pass, say once that the channel is behind
# the template when any file was refused. Prints nothing otherwise.
_seed_report_ahead() {
  [ "${#_SEED_AHEAD[@]}" -gt 0 ] || return 0
  echo "::warning::standards channel is behind the template — promote standards (scripts/cut-standards-release.sh in ${STANDARDS_REPO}). ${#_SEED_AHEAD[@]} file(s) already match the emission at standards HEAD ${_SEED_NEWER_SHA:0:12}, newer than ${_STD_REF}, and were NOT overwritten: ${_SEED_AHEAD[*]} (#1925)"
}

# ── Seed PR provenance + supersede (#1925 AC #1, #2) ──────────────────────────

# _seed_source_label <source> — one line saying how the standards ref was chosen.
# shellcheck disable=SC2016
_seed_source_label() {
  case "${1:-}" in
    channel)       printf 'channel — the published standards channel `%s`' "$STANDARDS_CHANNEL" ;;
    explicit)      printf 'explicit — `STANDARDS_REF` was set for this run' ;;
    head-fallback) printf 'HEAD fallback — the channel `%s` is not published, so the default-branch HEAD was used' "$STANDARDS_CHANNEL" ;;
    local)         printf 'local — a `STANDARDS_DIR` checkout, not a ref on %s' "$STANDARDS_REPO" ;;
    *)             printf 'unknown' ;;
  esac
}

# _seed_pr_body <ref> <sha> <source> [<ahead_path>...] — the seed PR body. It
# states which standards ref the seed was generated from, how that ref was chosen
# and the commit it resolved to, so a regressing seed can be explained without
# reconstructing it from blob diffs. The hidden marker carries the same three
# values for tooling. Any refused (ahead) files are listed. Pure.
# shellcheck disable=SC2016
_seed_pr_body() {
  local ref="${1:-}" sha="${2:-}" src="${3:-}" p
  [ $# -lt 3 ] || shift 3
  printf 'Seeds the org baseline scaffold (workflow stubs pinned to published channel tags + root/baseline files) from %s standards/. Generated by seed-repo-template.sh (#966).\n\n' "$STANDARDS_REPO"
  printf '## Standards provenance\n\n'
  printf -- '- **Resolved ref:** `%s`\n' "$ref"
  printf -- '- **Source:** %s\n' "$(_seed_source_label "$src")"
  printf -- '- **Commit:** `%s`\n\n' "${sha:-unknown}"
  printf '<!-- seed-repo-template standards_ref=%s standards_sha=%s source=%s -->\n' "$ref" "${sha:-unknown}" "$src"
  if [ $# -gt 0 ]; then
    printf '\n## Left alone: the template is ahead of the channel\n\n'
    printf 'These files already match the seed emission at a newer standards commit than `%s`, so this run did not overwrite them. The standards channel is behind the template: promote standards.\n\n' "$ref"
    for p in "$@"; do printf -- '- `%s`\n' "$p"; done
  fi
}

# _seed_close_superseded <repo> <keep_pr> <open_seed_lines> — close every open
# seed-scaffold/* PR other than <keep_pr>, each with a comment linking it, so one
# seed PR is open per repo. <open_seed_lines> is "<number>\t<branch>" per line.
# Returns non-zero when a PR that should have been closed was not.
_seed_close_superseded() {
  local repo="$1" keep="$2" lines="$3" n b failed=0
  while IFS=$'\t' read -r n b; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    [ "${b#seed-scaffold/}" != "$b" ] || continue
    [ "$n" != "$keep" ] || continue
    if [ -z "$keep" ]; then
      echo "::warning::could not identify this run's seed PR on ${repo} — leaving older seed PR #${n} open; close it by hand" >&2
      failed=1
      continue
    fi
    if gh pr close "$n" --repo "$repo" \
        --comment "Superseded by #${keep}, which carries the current seed (standards ref \`${_STD_REF:-unknown}\`, commit \`${_STD_SHA:-unknown}\`). Closing this one so a single seed PR is open (#1925)." \
        > /dev/null 2>&1; then
      echo "[seed] closed superseded seed PR #${n} on ${repo} (kept #${keep})"
    else
      echo "::warning::could not close superseded seed PR #${n} on ${repo} — close it by hand; #${keep} carries the current seed" >&2
      failed=1
    fi
  done <<< "$lines"
  return "$failed"
}

# _seed_file <repo> <path> <new_content> <branch> <base_ref>
# Ownership-aware write of ONE seeded file. Decides, from the file's CURRENT
# committed content at <base_ref> (the branch is cut from it), whether to write:
#   • absent            → CREATE  (a fresh repo still needs the file).
#   • drift-allowlisted → PRESERVE (intentionally customized per consumer, AC #2).
#   • managed marker    → PRESERVE (owned by another managed process, AC #1).
#   • byte-identical    → SKIP     (a re-seed writes nothing, AC #3).
#   • ahead of the ref  → REFUSE   (it matches the emission at a newer standards
#                         commit; writing would downgrade it — #1925 AC #3).
#   • otherwise         → WRITE    (genuine update).
# Under DRY_RUN it REPORTS the action (including destructive magnitude) and makes
# no write API call (AC #4); otherwise writes go through _put_file.
#
# <reuse>=1 means <branch> is an already-open seed PR's branch, not a fresh cut
# of <base_ref> (#2233). It may carry edits from an older run, so the file is made
# to match what this run wants on the branch — the new content, or for PRESERVE
# the base content — and is written only if the branch differs from that.
#
# <emit_flag> <emit_arg> name how this file is emitted (--emit-workflow <name.yml>
# or --emit-baseline <path>). They enable the no-downgrade check; a caller that
# omits them gets no such check.
_seed_file() {
  local repo="$1" path="$2" content="$3" branch="$4" base_ref="$5" reuse="${6:-0}"
  local emit_flag="${7:-}" emit_arg="${8:-}"
  local existing action reason desired on_branch ahead_rc
  # Assign, THEN check status: a command substitution in a conditional list disables
  # errexit inside its subshell, so an unreadable existing file (non-404) must fail
  # the seed rather than be treated as absent and overwritten with a CREATE (#1812).
  existing="$(_existing_file_content "$repo" "$path" "$base_ref")"
  [ $? -eq 0 ] || return 1

  if [ -z "$existing" ]; then
    action="create"; reason="new file"
  elif template_drift_allowlisted "$path"; then
    action="preserve"; reason="drift-allowlisted, customized per consumer (AC #2)"
  elif _content_has_managed_marker "$existing"; then
    action="preserve"; reason="carries a managed-block marker owned by another process (AC #1)"
  elif [ "$existing" = "$content" ]; then
    action="skip"; reason="unchanged (AC #3)"
  else
    action="write"; reason="content differs from the standards-derived baseline"
    # Only a file that would be overwritten pays for the newer-commit comparison.
    if [ -n "$emit_flag" ]; then
      ahead_rc=0
      _seed_is_ahead "$existing" "$emit_flag" "$emit_arg" || ahead_rc=$?
      case "$ahead_rc" in
        0)
          action="ahead"
          reason="the template is ahead of ${_STD_REF}: it matches the emission at standards HEAD ${_SEED_NEWER_SHA:0:12}"
          _SEED_AHEAD+=("$path")
          ;;
        1) : ;;
        *) return 1 ;;
      esac
    fi
  fi

  if _is_dry; then
    _seed_report_dry "$path" "$action" "$reason" "$existing" "$content"
    return 0
  fi

  if [ "$reuse" = 1 ]; then
    if [ "$action" = "preserve" ] || [ "$action" = "ahead" ]; then desired="$existing"; else desired="$content"; fi
    on_branch="$(_existing_file_content "$repo" "$path" "$branch")"
    [ $? -eq 0 ] || return 1
    if [ "$on_branch" = "$desired" ]; then
      echo "  [seed] ${path} already current on ${branch} — ${reason}"
    else
      _put_file "$repo" "$path" "$desired" "$branch" "seed ${path}"
    fi
    return
  fi

  case "$action" in
    create|write) _put_file "$repo" "$path" "$content" "$branch" "seed ${path}" ;;
    preserve|skip) echo "  [seed] preserved ${path} — ${reason}" ;;
    ahead) echo "  [seed] REFUSED ${path} — ${reason}; not overwriting" ;;
  esac
}

# _seed_all_files <repo> <branch> <base_ref> [<reuse>] — emit every workflow stub +
# baseline file and apply it ownership-aware via _seed_file. Shared by the live and
# dry-run paths so both make the SAME per-file decisions (#1812).
_seed_all_files() {
  local repo="$1" branch="$2" base_ref="$3" reuse="${4:-0}" row name path content
  for row in "${WORKFLOW_MANIFEST[@]}"; do
    name="${row%%|*}"
    path=".github/workflows/${name}.yml"
    # Assign first, then check $?: a command substitution in a conditional list
    # (`content="$(…)" || return 1`) disables errexit inside its subshell, swallowing
    # an internal failure of _emit_workflow instead of aborting the seed (#1868 review).
    content="$(_emit_workflow "${name}.yml")"
    [ $? -eq 0 ] || return 1
    _seed_file "$repo" "$path" "$content" "$branch" "$base_ref" "$reuse" --emit-workflow "${name}.yml" || return 1
  done
  for row in "${BASELINE_MANIFEST[@]}"; do
    path="${row%%|*}"
    # README.md carries the commercial-support section read from the standard
    # (#2233). If that cannot be read, leave README.md alone: writing it without
    # the section is the deletion this guards against, and one unreadable file
    # must not block every other update.
    # Emit once and decide on that single read, so a second fetch cannot fail
    # after the guard passed and abort the run.
    if [ "$path" = "README.md" ]; then
      if ! content="$(_emit_baseline "$path")"; then
        echo "::warning::skipping README.md — ${COMMERCIAL_SUPPORT_STANDARD} is unreadable; leaving the existing file untouched" >&2
        continue
      fi
    else
      content="$(_emit_baseline "$path")"
      [ $? -eq 0 ] || return 1
    fi
    _seed_file "$repo" "$path" "$content" "$branch" "$base_ref" "$reuse" --emit-baseline "$path" || return 1
  done
}

# ── Cross-repo seeding (branch + contents PUT + one PR) ────────────────────────
_seed_repo() {
  local repo="$1" branch default_branch base_sha
  branch="seed-scaffold/$(date -u +%Y-%m-%d)"

  # Resolve in the current shell (not $()) so the memoized _STD_* globals persist.
  _resolve_standards_ref > /dev/null
  _resolved_standards_sha > /dev/null
  # From here on, fetch standards at the resolved COMMIT, not through the ref name,
  # so the content and the provenance the PR records cannot come apart. A local
  # STANDARDS_DIR has no commit, and reads the checkout as before.
  if [[ "${_STD_SHA:-}" =~ ^[0-9a-f]{40}$ ]]; then
    _STD_PIN="$_STD_SHA"
  fi
  echo "[seed] target repo: ${repo} (stack: ${DEPENDABOT_STACK})"
  echo "[seed] standards ref: ${_STD_REF} (commit ${_STD_SHA:-unknown}, source ${_STD_SRC:-?}) on ${STANDARDS_REPO}"
  if [ "${_STD_SRC:-}" = "head-fallback" ]; then
    echo "[seed] note: STANDARDS_CHANNEL '${STANDARDS_CHANNEL}' is not published yet — fetching at HEAD commit ${_STD_SHA:-unknown} (#1448 AC #10)."
  fi
  echo "[seed] workflow stubs: $(printf '%s ' "${WORKFLOW_MANIFEST[@]%%|*}")"
  echo "[seed] baseline files: $(printf '%s ' "${BASELINE_MANIFEST[@]%%|*}")"

  # Ownership decisions compare against the file's CURRENT content on the target's
  # default branch (the seed branch is cut from it), so a re-seed can tell CREATE
  # from PRESERVE from WRITE (#1812). Resolved for both live and dry-run; the
  # dry-run reads only and reports, making no write API call (AC #4).
  # Resolve the target's real default branch. A failure here must abort loudly: a
  # silent fallback to `main` would inspect and cut a PR against the WRONG branch on
  # a repo whose default is not main, or let a dry-run falsely succeed (#1868 review).
  local drc=0
  default_branch="$(gh api "repos/${repo}" --jq '.default_branch' 2>/dev/null)" || drc=$?
  if [ "$drc" -ne 0 ] || [ -z "$default_branch" ]; then
    echo "::error::cannot resolve default branch on ${repo} (gh api exit ${drc})" >&2
    return 1
  fi

  if _is_dry; then
    echo "[seed] [dry-run] planning per-file writes against ${default_branch} on ${repo} (no writes will be made):"
    _seed_all_files "$repo" "$branch" "$default_branch" || return 1
    _seed_report_ahead
    echo "[seed] PASS (dry-run) — ${repo}"
    return 0
  fi

  base_sha="$(gh api "repos/${repo}/git/ref/heads/${default_branch}" --jq '.object.sha' 2>/dev/null || true)"
  if [ -z "$base_sha" ]; then
    echo "::error::cannot read ${default_branch} head on ${repo}" >&2
    return 1
  fi
  # One open seed PR per repo (#2233, #1925): if a seed-scaffold/* PR is already
  # open, update its branch instead of cutting a new dated one, so seed PRs no
  # longer pile up. The newest one wins if several are open; the others are closed
  # as superseded once this run's PR is settled (#1925 AC #2).
  # The limit is applied before the jq filter, so it must cover every open PR on
  # the repo, not just the seed ones: a seed PR cut off by it would be missed and
  # a second one opened.
  # A failed listing must not read as "no seed PR is open": that would open a second
  # seed PR and leave the older ones open, which is the pile-up this prevents.
  local open_seeds open_seed open_pr="" open_branch="" reuse=0 branch_created=0
  if ! open_seeds="$(gh pr list --repo "$repo" --state open --limit 1000 --json number,headRefName \
      --jq '[.[] | select(.headRefName | startswith("seed-scaffold/"))] | sort_by(.number) | .[] | "\(.number)\t\(.headRefName)"' \
      2>/dev/null)"; then
    echo "::error::cannot list open pull requests on ${repo} — not seeding, because an open seed PR could not be ruled out" >&2
    return 1
  fi
  open_seed="$(printf '%s\n' "$open_seeds" | tail -n 1)"
  IFS=$'\t' read -r open_pr open_branch <<< "$open_seed" || true
  if [ -n "$open_pr" ] && [ "${open_branch#seed-scaffold/}" != "$open_branch" ]; then
    branch="$open_branch"; reuse=1
    echo "[seed] seed PR #${open_pr} is already open on ${repo} — updating its branch ${branch} instead of opening another"
  elif gh api "repos/${repo}/git/refs" --method POST \
      --field "ref=refs/heads/${branch}" --field "sha=${base_sha}" --silent 2>/dev/null; then
    branch_created=1
  else
    gh api "repos/${repo}/git/ref/heads/${branch}" --silent 2>/dev/null \
      || { echo "::error::cannot create branch ${branch} on ${repo}" >&2; return 1; }
    # Today's branch already exists, left by an earlier run. Like an open seed PR's
    # branch it may carry that run's edits, so every file is made to match what
    # THIS run wants. Otherwise a file this run skips, preserves or refuses would
    # keep the earlier run's content, and a refused downgrade could still ship.
    reuse=1
    echo "[seed] branch ${branch} already exists on ${repo} — bringing it in line with this run"
  fi

  _seed_all_files "$repo" "$branch" "$default_branch" "$reuse" || return 1
  _seed_report_ahead

  # Nothing was written to a fresh branch: there is nothing to open a PR for. This
  # is the outcome when the template already matches the ref, or when every
  # differing file is ahead of it — a refused downgrade must not become a PR.
  if [ "$branch_created" = 1 ] && [ "$_SEED_WRITES" -eq 0 ]; then
    gh api "repos/${repo}/git/refs/heads/${branch}" --method DELETE --silent 2>/dev/null \
      || echo "::warning::could not delete the empty branch ${branch} on ${repo}" >&2
    if [ "${#_SEED_AHEAD[@]}" -gt 0 ]; then
      echo "[seed] no PR opened on ${repo}: the only differing files are ahead of ${_STD_REF} (see the warning above)"
    else
      echo "[seed] no PR opened on ${repo}: it already matches ${_STD_REF}"
    fi
    echo "[seed] PASS — ${repo}"
    return 0
  fi

  local existing_pr pr_body pr_url keep_pr=""
  pr_body="$(_seed_pr_body "$_STD_REF" "${_STD_SHA:-}" "${_STD_SRC:-}" "${_SEED_AHEAD[@]}")"
  # A failed lookup must not read as "no PR": that would open a duplicate.
  if ! existing_pr="$(gh pr list --repo "$repo" --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null)"; then
    echo "::warning::could not list open PRs for ${branch} on ${repo} — not opening a PR to avoid a duplicate" >&2
    return 1
  fi
  # A dated branch left by an earlier run, with no open PR, and nothing written by
  # this run: open a PR only if the branch still has something the base lacks. If
  # that cannot be read, go on to `gh pr create`, which fails loudly on an empty PR.
  if [ -z "$existing_pr" ] && [ "$branch_created" != 1 ] && [ "$_SEED_WRITES" -eq 0 ]; then
    local ahead_by
    ahead_by="$(gh api "repos/${repo}/compare/${default_branch}...${branch}" --jq '.ahead_by' 2>/dev/null || true)"
    if [ "$ahead_by" = "0" ]; then
      echo "[seed] no PR opened on ${repo}: branch ${branch} has nothing ${default_branch} lacks"
      echo "[seed] PASS — ${repo}"
      return 0
    fi
  fi

  if [ -n "$existing_pr" ]; then
    echo "[seed] PR #$existing_pr already open for branch $branch on $repo"
    keep_pr="$existing_pr"
    # The PR now carries THIS run's content, so its body must name this run's ref.
    gh pr edit "$existing_pr" --repo "$repo" --body "$pr_body" > /dev/null 2>&1 \
      || { echo "::error::cannot update the standards provenance on PR #${existing_pr} on ${repo}" >&2; return 1; }
  else
    pr_url="$(gh pr create --repo "$repo" --head "$branch" --base "$default_branch" \
      --title "chore: seed org baseline file scaffold" \
      --body "$pr_body" 2>/dev/null)" \
      || { echo "::error::cannot open PR on ${repo}" >&2; return 1; }
    keep_pr="${pr_url##*/}"
    [[ "$keep_pr" =~ ^[0-9]+$ ]] || keep_pr=""
    [ -z "$keep_pr" ] || echo "[seed] opened seed PR #${keep_pr} on ${repo}"
  fi

  if ! _seed_close_superseded "$repo" "$keep_pr" "$open_seeds"; then
    echo "::error::the seed PR is open on ${repo}, but an older seed PR could not be closed — see the warning above" >&2
    return 1
  fi
  echo "[seed] PASS — ${repo}"
}

# _put_file <repo> <path> <content> <branch> <message>
_put_file() {
  local repo="$1" path="$2" content="$3" branch="$4" msg="$5" sha encoded
  _require base64 || return 1
  local -a sha_arg=()
  sha="$(gh api "repos/${repo}/contents/${path}?ref=${branch}" --jq '.sha' 2>/dev/null || true)"
  [ -n "$sha" ] && [ "$sha" != "null" ] && sha_arg=(--field "sha=${sha}")
  encoded="$(printf '%s' "$content" | base64 -w 0 2>/dev/null || printf '%s' "$content" | base64)"
  gh api "repos/${repo}/contents/${path}" --method PUT \
    --field "message=${msg}" --field "content=${encoded}" --field "branch=${branch}" \
    "${sha_arg[@]}" --silent 2>/dev/null \
    || { echo "::error::cannot write ${path} on ${repo}" >&2; return 1; }
  _SEED_WRITES=$((_SEED_WRITES + 1))
  echo "  [seed] wrote ${path}"
}

# ── CLI ───────────────────────────────────────────────────────────────────────
_list_workflows() { local r; for r in "${WORKFLOW_MANIFEST[@]}"; do printf '%s.yml\n' "${r%%|*}"; done; }
_list_baseline()  { local r; for r in "${BASELINE_MANIFEST[@]}"; do printf '%s\n' "${r%%|*}"; done; }

main() {
  # gh/base64 are required lazily at their points of use (_fetch_standard,
  # _resolve_standards_ref network path, _put_file) so local-only seams such as
  # --emit-workflow of a docs/ reference stay reachable without them (#1724).
  local repo="$TEMPLATE_REPO"
  while [ $# -gt 0 ]; do
    case "$1" in
      --list-workflows) _list_workflows; return 0 ;;
      --list-baseline)  _list_baseline;  return 0 ;;
      --print-ref)
        # Report the resolved standards ref for the drift report (#1448 AC #7):
        # "<ref>\t<commit-sha>\t<source>". source ∈ local|explicit|channel|head-fallback.
        # Resolve in the current shell (not $()) so the memoized _STD_* globals persist.
        _resolve_standards_ref > /dev/null
        _resolved_standards_sha > /dev/null
        printf '%s\t%s\t%s\n' "$_STD_REF" "${_STD_SHA:-}" "${_STD_SRC:-?}"
        return 0 ;;
      --emit-workflow)  [ $# -ge 2 ] || { echo "::error::--emit-workflow needs a name" >&2; return 2; }; _emit_workflow "$2"; return $? ;;
      --emit-baseline)  [ $# -ge 2 ] || { echo "::error::--emit-baseline needs a path" >&2; return 2; }; _emit_baseline "$2"; return $? ;;
      --repin)
        [ $# -ge 2 ] || { echo "::error::--repin needs a stub name" >&2; return 2; }
        local row name kind host
        row="$(_manifest_row "$2")" || { echo "::error::unknown workflow stub: $2" >&2; return 2; }
        IFS='|' read -r name kind host <<<"$row"
        if [ "$kind" = "caller" ]; then
          _repin_stub_content "$name" "$host"
        else
          cat
        fi
        return 0 ;;
      --repo) [ $# -ge 2 ] || { echo "::error::--repo needs a value" >&2; return 2; }; repo="$2"; shift 2; continue ;;
      --repo=*) repo="${1#--repo=}"; shift; continue ;;
      --dry-run) DRY_RUN=true; shift; continue ;;
      -h|--help) sed -n '2,40p' "$0"; return 0 ;;
      *) echo "::error::unknown argument: $1" >&2; return 2 ;;
    esac
  done

  case "$repo" in
    */*) : ;;
    *) echo "::error::--repo must be owner/name, got: ${repo}" >&2; return 2 ;;
  esac

  _seed_repo "$repo"
}

# Source-guard: tests source this to exercise individual helpers.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
