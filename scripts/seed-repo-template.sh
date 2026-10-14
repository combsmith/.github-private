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
# LICENSE, SECURITY.md, README.md, BOOTSTRAP.md. No issue/PR templates and no
# labeler config are introduced (AC #5).
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

DRY_RUN="${DRY_RUN:-false}"
TEMPLATE_REPO="${TEMPLATE_REPO:-combsmith/repo-template}"
STANDARDS_REPO="${STANDARDS_REPO:-combsmith/.github}"
STANDARDS_REF="${STANDARDS_REF:-}"
STANDARDS_CHANNEL="${STANDARDS_CHANNEL:-standards/v1-stable}"
DEPENDABOT_STACK="${DEPENDABOT_STACK:-frontend}"

_is_dry() { [ "$DRY_RUN" = "true" ]; }

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
  "SECURITY.md|gen"
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
  ref="$(_resolve_standards_ref)"
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

# ── Baseline file content (AC #3, #4) ─────────────────────────────────────────
_gen_baseline() {
  case "$1" in
    AGENTS.md) cat <<'EOF'
# AGENTS.md

This repository follows the organization-wide development standards defined in
[`combsmith/.github/AGENTS.md`](https://github.com/combsmith/.github/blob/main/AGENTS.md).

Read that file before making changes that touch CI, agent configuration, repo
settings, or labels. Repo-specific deviations, if any, are documented below.
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
# Customize sonar.projectKey / sonar.organization for this repo before enabling
# the sonarcloud workflow. See BOOTSTRAP.md.
sonar.projectKey=petry-projects_repo-template
sonar.organization=petry-projects
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
    SECURITY.md) cat <<'EOF'
# Security Policy

To report a vulnerability, please follow the org-wide policy in
[`combsmith/.github`](https://github.com/combsmith/.github/blob/main/SECURITY.md).

Do not open public issues for security reports.
EOF
      ;;
    README.md) cat <<'EOF'
# repo-template

Org baseline scaffold for new `combsmith` repositories. Click **Use this
template** to create a repo pre-wired with the standard workflow stubs and
baseline files.

After creating your repo, follow **[BOOTSTRAP.md](./BOOTSTRAP.md)** to finish the
one-time, per-stack setup (Dependabot + `ci.yml`).

The workflow stubs and baseline files here are a distribution artifact of the org
standards in [`combsmith/.github`](https://github.com/combsmith/.github)
(`standards/`) and are regenerated from it — edit the standards, not this copy.
EOF
      ;;
    BOOTSTRAP.md) cat <<'EOF'
# Bootstrap a new repo from this template

This template ships the org baseline: the thin-caller workflow stubs (pinned to
their published `@<name>/v<MAJOR>-stable` channel tags) and the root/baseline files. Most
of it works out of the box. Two things are **per-stack** and must be picked once,
after you create your repo from the template:

## 1. Pick your Dependabot stack

`.github/dependabot.yml` ships with the `frontend` (npm) stack by default.
Replace it with the stack that matches your project — the canonical stacks live
in `combsmith/.github` under `standards/dependabot/<stack>.yml`. Available
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

---

## What this template does NOT do

Two onboarding questions are resolved here so they are not left implicit:

- **Framework subtrees (`frameworks/`) are opt-in — they are not seeded by this
  template.** The agentic frameworks (`bmad-method`, `spec-kit`, `gsd`) are
  `git subtree` development tooling maintained in `combsmith/.github-private`;
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

# ── Cross-repo seeding (branch + contents PUT + one PR) ────────────────────────
_seed_repo() {
  local repo="$1" branch default_branch base_sha
  branch="seed-scaffold/$(date -u +%Y-%m-%d)"

  # Resolve in the current shell (not $()) so the memoized _STD_* globals persist.
  _resolve_standards_ref > /dev/null
  _resolved_standards_sha > /dev/null
  echo "[seed] target repo: ${repo} (stack: ${DEPENDABOT_STACK})"
  echo "[seed] standards ref: ${_STD_REF} (commit ${_STD_SHA:-unknown}, source ${_STD_SRC:-?}) on ${STANDARDS_REPO}"
  if [ "${_STD_SRC:-}" = "head-fallback" ]; then
    echo "[seed] note: STANDARDS_CHANNEL '${STANDARDS_CHANNEL}' is not published yet — fetching at HEAD commit ${_STD_SHA:-unknown} (#1448 AC #10)."
  fi
  echo "[seed] workflow stubs: $(printf '%s ' "${WORKFLOW_MANIFEST[@]%%|*}")"
  echo "[seed] baseline files: $(printf '%s ' "${BASELINE_MANIFEST[@]%%|*}")"

  if _is_dry; then
    echo "[seed] [dry-run] would create branch ${branch} on ${repo}, write the"
    echo "       scaffold via the contents API, and open one PR. No writes made."
    echo "[seed] PASS (dry-run) — ${repo}"
    return 0
  fi

  default_branch="$(gh api "repos/${repo}" --jq '.default_branch' 2>/dev/null || echo main)"
  base_sha="$(gh api "repos/${repo}/git/ref/heads/${default_branch}" --jq '.object.sha' 2>/dev/null || true)"
  if [ -z "$base_sha" ]; then
    echo "::error::cannot read ${default_branch} head on ${repo}" >&2
    return 1
  fi
  gh api "repos/${repo}/git/refs" --method POST \
    --field "ref=refs/heads/${branch}" --field "sha=${base_sha}" --silent 2>/dev/null \
    || gh api "repos/${repo}/git/ref/heads/${branch}" --silent 2>/dev/null \
    || { echo "::error::cannot create branch ${branch} on ${repo}" >&2; return 1; }

  local row name path content
  for row in "${WORKFLOW_MANIFEST[@]}"; do
    name="${row%%|*}"
    path=".github/workflows/${name}.yml"
    content="$(_emit_workflow "${name}.yml")" || return 1
    _put_file "$repo" "$path" "$content" "$branch" "seed ${path}" || return 1
  done
  for row in "${BASELINE_MANIFEST[@]}"; do
    path="${row%%|*}"
    content="$(_emit_baseline "$path")" || return 1
    _put_file "$repo" "$path" "$content" "$branch" "seed ${path}" || return 1
  done

  local existing_pr
  existing_pr="$(gh pr list --repo "$repo" --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
  if [ -n "$existing_pr" ]; then
    echo "[seed] PR #$existing_pr already open for branch $branch on $repo"
  else
    gh pr create --repo "$repo" --head "$branch" --base "$default_branch" \
      --title "chore: seed org baseline file scaffold" \
      --body "$(printf 'Seeds the org baseline scaffold (workflow stubs pinned to published channel tags + root/baseline files) from %s standards/. Generated by seed-repo-template.sh (#966).\n' "$STANDARDS_REPO")" \
      2>/dev/null \
      || { echo "::error::cannot open PR on ${repo}" >&2; return 1; }
  fi
  echo "[seed] PASS — ${repo}"
}

# _put_file <repo> <path> <content> <branch> <message>
_put_file() {
  local repo="$1" path="$2" content="$3" branch="$4" msg="$5" sha encoded
  local -a sha_arg=()
  sha="$(gh api "repos/${repo}/contents/${path}?ref=${branch}" --jq '.sha' 2>/dev/null || true)"
  [ -n "$sha" ] && [ "$sha" != "null" ] && sha_arg=(--field "sha=${sha}")
  encoded="$(printf '%s' "$content" | base64 -w 0 2>/dev/null || printf '%s' "$content" | base64)"
  gh api "repos/${repo}/contents/${path}" --method PUT \
    --field "message=${msg}" --field "content=${encoded}" --field "branch=${branch}" \
    "${sha_arg[@]}" --silent 2>/dev/null \
    || { echo "::error::cannot write ${path} on ${repo}" >&2; return 1; }
  echo "  [seed] wrote ${path}"
}

# ── CLI ───────────────────────────────────────────────────────────────────────
_list_workflows() { local r; for r in "${WORKFLOW_MANIFEST[@]}"; do printf '%s.yml\n' "${r%%|*}"; done; }
_list_baseline()  { local r; for r in "${BASELINE_MANIFEST[@]}"; do printf '%s\n' "${r%%|*}"; done; }

main() {
  local cmd
  for cmd in gh base64; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
      echo "::error::${cmd} is required but not installed." >&2
      return 1
    fi
  done

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
