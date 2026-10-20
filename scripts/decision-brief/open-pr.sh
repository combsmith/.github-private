#!/usr/bin/env bash
# open-pr.sh — land a validated brief package in the TARGET repo as a PR.
#
# Writes ideas/<slug>/{brief.md,market-research.md,ost.md} to the branch
# `incubate/<slug>` of the target repo (the incubator's own incubation-PR
# naming, ideas/PACKAGE.md) and opens — or refreshes — the PR for it, then
# links the PR from the source Discussion. Nothing is merged and no label is
# applied to the Discussion: the human still decides by adding `idea:approved`.
#
# Everything goes through the GitHub API (`gh api`, Git Data endpoints), not a
# clone, so there is no checkout of the target repo, no credential on disk, one
# commit per run, and every call is mockable in tests the way the rest of this
# repo's tooling is.
#
# Idempotent:
#   - the branch already exists        -> the new commit is appended to it
#   - an open PR for the branch exists  -> no second PR; a refresh comment is posted
#   - DRY_RUN=1                         -> every intended mutation is logged to
#                                          $DRY_RUN_LOG as JSONL, nothing is written
#
# Env:
#   REPO               owner/repo of the TARGET (required)
#   SLUG               idea slug (required)
#   PACKAGE_DIR        local dir holding the drafted files (required)
#   IDEAS_DIR          target path prefix (default: ideas)
#   DISCUSSION_NUMBER  source Discussion number (required)
#   DISCUSSION_NODE_ID GraphQL node id of the Discussion (optional; enables the
#                      back-link comment)
#   IDEA_TITLE         Discussion title (optional, for the PR title)
#   STATUS_PATH        Mary's JSON status (optional; summarised in the PR body)
#   BRANCH_PREFIX      default: incubate
#   PR_LABEL           label applied to the PR (default: decision-brief; created
#                      on first use)
#   GIT_USER_NAME / GIT_USER_EMAIL
#                      commit author (default: the business-analyst persona's
#                      runtime identity, via scripts/lib/resolve-persona-identity.sh)
#   RUN_URL            link to this Actions run (optional, for provenance)
#   DRY_RUN / DRY_RUN_LOG
#   GH_TOKEN           token with contents+pull-requests(+discussions) write on
#                      the target (required when not DRY_RUN)
set -euo pipefail

REPO="${REPO:?REPO required}"
SLUG="${SLUG:?SLUG required}"
PACKAGE_DIR="${PACKAGE_DIR:?PACKAGE_DIR required}"
DISCUSSION_NUMBER="${DISCUSSION_NUMBER:?DISCUSSION_NUMBER required}"
IDEAS_DIR="${IDEAS_DIR:-ideas}"
BRANCH_PREFIX="${BRANCH_PREFIX:-incubate}"
PR_LABEL="${PR_LABEL:-decision-brief}"
IDEA_TITLE="${IDEA_TITLE:-discussion #${DISCUSSION_NUMBER}}"

[[ "$DISCUSSION_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "::error::DISCUSSION_NUMBER must be a positive integer" >&2; exit 1; }
[[ "$SLUG" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "::error::SLUG must be kebab-case, got '$SLUG'" >&2; exit 1; }
[[ -d "$PACKAGE_DIR" ]] || { echo "::error::PACKAGE_DIR '$PACKAGE_DIR' is not a directory" >&2; exit 1; }

_is_dry_run() { [[ "${DRY_RUN:-0}" == "1" ]]; }
_dry_log() { printf '%s\n' "$1" >>"${DRY_RUN_LOG:-./dry-run.jsonl}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── commit identity: the persona's declared runtime account, never a shared var ─
if [[ -z "${GIT_USER_NAME:-}" ]]; then
  GIT_USER_NAME="$(bash "$ROOT/scripts/lib/resolve-persona-identity.sh" business-analyst "$ROOT/personas" account 2>/dev/null || true)"
fi
GIT_USER_NAME="${GIT_USER_NAME:-decision-brief}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-${GIT_USER_NAME}@users.noreply.github.com}"

# ── the files ─────────────────────────────────────────────────────────────────
files=()
while IFS= read -r f; do files+=("$f"); done < <(cd "$PACKAGE_DIR" && find . -type f ! -name '.*' | sed 's#^\./##' | sort)
[[ ${#files[@]} -gt 0 ]] || { echo "::error::PACKAGE_DIR '$PACKAGE_DIR' holds no files" >&2; exit 1; }
[[ -f "$PACKAGE_DIR/brief.md" ]] || { echo "::error::PACKAGE_DIR has no brief.md" >&2; exit 1; }

branch="${BRANCH_PREFIX}/${SLUG}"
dest_prefix="${IDEAS_DIR}/${SLUG}"
disc_url="https://github.com/${REPO}/discussions/${DISCUSSION_NUMBER}"
title="brief(${SLUG}): decision brief for \"${IDEA_TITLE}\" (discussion #${DISCUSSION_NUMBER})"

# ── PR body ───────────────────────────────────────────────────────────────────
status_summary=""
if [[ -n "${STATUS_PATH:-}" && -s "${STATUS_PATH}" ]] && jq -e . "$STATUS_PATH" >/dev/null 2>&1; then
  status_summary="$(jq -r '
    def list(x): if (x|length)==0 then "_none_" else (x|map("- " + (if type=="string" then . else tojson end))|join("\n")) end;
    "**Recommendation:** " + ((.recommendation // "see brief") | tostring) + "\n" +
    "**Score:** " + ((.score // "see brief") | tostring) + "\n" +
    "**Status:** `" + ((.status // "unknown") | tostring) + "`\n\n" +
    "**Assumptions tagged in the brief:**\n" + list(.assumptions // []) + "\n\n" +
    "**Open questions for the decider:**\n" + list(.open_questions // []) + "\n\n" +
    "**Sources cited:** " + ((.sources // []) | length | tostring)
  ' "$STATUS_PATH")"
fi
# One list line per file (a single printf with two %s would reuse the format
# across the argument list and pair the files with each other).
file_list=""
for f in "${files[@]}"; do
  file_list+="- \`${dest_prefix}/${f}\`"$'\n'
done
body="$(cat <<EOF
<!-- decision-brief:slug=${SLUG} discussion=${DISCUSSION_NUMBER} -->
## Decision brief — ${IDEA_TITLE}

Drafted by **Mary (Analyst)** via the org decision-brief stage for ${disc_url}.
This brief **informs** the go/no-go; it does not make it. Approve the idea by adding
\`idea:approved\` to the source Discussion, or decline it there — not by merging this PR
(merging records the package; the incubation gate may stay red until the rest of the
package — brainstorm, PRD — exists).

### Files
${file_list}

### Mary's status
${status_summary:-_no status file attached_}

### Provenance
Every market claim in the package either cites a source, is tagged \`[ASSUMPTION]\`, or says
"unknown — needs discovery" (enforced by \`scripts/decision-brief/validate-package.sh\` in
combsmith/.github-private before this PR was opened). Nothing here is fabricated to fill a section.
${RUN_URL:+
Run: ${RUN_URL}}
EOF
)"

if _is_dry_run; then
  _dry_log "$(jq -nc --arg op open_pr --arg repo "$REPO" --arg branch "$branch" --arg title "$title" \
    --arg body "$body" --arg author "$GIT_USER_NAME" \
    --argjson files "$(printf '%s\n' "${files[@]}" | jq -R . | jq -sc --arg p "$dest_prefix" 'map($p + "/" + .)')" \
    '{op:$op, repo:$repo, branch:$branch, title:$title, files:$files, author:$author, body_len:($body|length)}')"
  if [[ -n "${DISCUSSION_NODE_ID:-}" ]]; then
    _dry_log "$(jq -nc --arg op discussion_comment --arg repo "$REPO" --argjson n "$DISCUSSION_NUMBER" \
      '{op:$op, repo:$repo, discussion:$n}')"
  fi
  echo "[dry-run] would push ${#files[@]} file(s) to ${REPO}@${branch} under ${dest_prefix}/ and open PR '${title}'"
  exit 0
fi

# ── base + branch state ───────────────────────────────────────────────────────
default_branch="$(gh api "repos/${REPO}" --jq '.default_branch')"
base_sha="$(gh api "repos/${REPO}/git/ref/heads/${default_branch}" --jq '.object.sha')"
[[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::could not resolve ${default_branch} on ${REPO} to a commit (got '${base_sha:0:80}')" >&2; exit 1; }
# `gh api` prints the error BODY to stdout on a non-2xx (the HTTP error goes to
# stderr), so `$(gh api … || true)` captures `{"message":"Not Found",…}` as the
# SHA on the first run for a slug and the next call becomes
# git/commits/{"message"…}. Only a 404 means "no branch yet"; anything else
# must fail closed rather than be read as a fresh branch.
err_file="$(mktemp)"
if parent_sha="$(gh api "repos/${REPO}/git/ref/heads/${branch}" --jq '.object.sha' 2>"$err_file")"; then
  [[ "$parent_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::${branch} resolved to '${parent_sha:0:80}', not a commit SHA" >&2; rm -f "$err_file"; exit 1; }
elif grep -qE 'HTTP 404|Not Found' "$err_file"; then
  parent_sha=""
else
  echo "::error::could not resolve ${branch} on ${REPO} — $(tr '\n' ' ' <"$err_file" | cut -c1-200); not landing" >&2
  rm -f "$err_file"; exit 1
fi
rm -f "$err_file"
branch_exists=0
if [[ -n "$parent_sha" ]]; then
  branch_exists=1
  # Two Discussions can derive the same slug and reach this point in parallel
  # (gather's collision check ran before either branch existed). Before
  # appending, the branch's brief must link THIS Discussion.
  # Only a 404 means "no brief on the branch yet"; any other failure must not
  # read as "no collision" — fail closed.
  err_file="$(mktemp)"
  if branch_brief_b64="$(gh api "repos/${REPO}/contents/${dest_prefix}/brief.md?ref=${branch}" --jq '.content' 2>"$err_file")"; then
    branch_brief="$(printf '%s' "$branch_brief_b64" | base64 -d)"
  elif grep -qE 'HTTP 404|Not Found' "$err_file"; then
    branch_brief=""
  else
    echo "::error::could not read ${dest_prefix}/brief.md on ${branch} to check for a slug collision — $(tr '\n' ' ' <"$err_file" | cut -c1-200); not appending" >&2
    rm -f "$err_file"; exit 1
  fi
  rm -f "$err_file"
  if [[ -n "$branch_brief" ]] && ! grep -qE "/discussions/${DISCUSSION_NUMBER}([^0-9]|$)" <<<"$branch_brief"; then
    echo "::error::${branch} already carries a brief for another Discussion — slug collision; dispatch again with an explicit slug" >&2
    exit 1
  fi
else
  parent_sha="$base_sha"
fi
base_tree="$(gh api "repos/${REPO}/git/commits/${parent_sha}" --jq '.tree.sha')"

# ── one commit: blobs → tree → commit → ref ───────────────────────────────────
tree_entries='[]'
for f in "${files[@]}"; do
  blob_sha="$(jq -n --rawfile c "$PACKAGE_DIR/$f" '{content:$c, encoding:"utf-8"}' \
    | gh api "repos/${REPO}/git/blobs" -X POST --input - --jq '.sha')"
  tree_entries="$(jq -c --arg p "${dest_prefix}/${f}" --arg s "$blob_sha" \
    '. + [{path:$p, mode:"100644", type:"blob", sha:$s}]' <<<"$tree_entries")"
done
tree_sha="$(jq -nc --arg base "$base_tree" --argjson t "$tree_entries" '{base_tree:$base, tree:$t}' \
  | gh api "repos/${REPO}/git/trees" -X POST --input - --jq '.sha')"
message="$(printf 'brief(%s): decision brief for discussion #%s\n\n%s\n\nDrafted by the decision-brief stage (Mary, Analyst). Source: %s' \
  "$SLUG" "$DISCUSSION_NUMBER" "$IDEA_TITLE" "$disc_url")"
commit_sha="$(jq -nc --arg m "$message" --arg t "$tree_sha" --arg p "$parent_sha" \
    --arg n "$GIT_USER_NAME" --arg e "$GIT_USER_EMAIL" \
    '{message:$m, tree:$t, parents:[$p], author:{name:$n, email:$e}, committer:{name:$n, email:$e}}' \
  | gh api "repos/${REPO}/git/commits" -X POST --input - --jq '.sha')"
if [[ "$branch_exists" == "1" ]]; then
  gh api "repos/${REPO}/git/refs/heads/${branch}" -X PATCH -f sha="$commit_sha" >/dev/null
  echo "appended ${commit_sha:0:7} to existing ${branch}"
else
  gh api "repos/${REPO}/git/refs" -X POST -f ref="refs/heads/${branch}" -f sha="$commit_sha" >/dev/null
  echo "created ${branch} at ${commit_sha:0:7}"
fi

# ── the PR (find-or-create) ───────────────────────────────────────────────────
existing_pr="$(gh pr list --repo "$REPO" --head "$branch" --state open --json number,url \
  --jq '.[0].url // empty' 2>/dev/null || true)"
if [[ -n "$existing_pr" ]]; then
  # A re-brief may change the recommendation, score or open questions: the
  # PR's title and body must say what the files now say, not what the first
  # run said. Then a short comment points reviewers at the new commit.
  body_file="$(mktemp)"
  printf '%s\n' "$body" >"$body_file"
  gh pr edit "$existing_pr" --repo "$REPO" --title "$title" --body-file "$body_file" >/dev/null
  rm -f "$body_file"
  gh pr comment "$existing_pr" --repo "$REPO" \
    --body "$(printf '<!-- decision-brief:refresh -->\nRefreshed by the decision-brief stage: commit %s updates `%s/`; the PR title and summary above reflect the current brief.%s' \
      "${commit_sha:0:7}" "$dest_prefix" "${RUN_URL:+ Run: ${RUN_URL}}")" >/dev/null
  pr_url="$existing_pr"
  echo "refreshed existing PR ${pr_url} (title + summary updated)"
else
  gh label create "$PR_LABEL" --repo "$REPO" \
    --description "Decision brief drafted by the org decision-brief stage (Mary)" --color 5319e7 2>/dev/null || true
  body_file="$(mktemp)"
  printf '%s\n' "$body" >"$body_file"
  pr_url="$(gh pr create --repo "$REPO" --base "$default_branch" --head "$branch" \
    --title "$title" --body-file "$body_file" --label "$PR_LABEL")"
  rm -f "$body_file"
  echo "opened PR ${pr_url}"
fi
[[ -n "${GITHUB_OUTPUT:-}" ]] && printf 'pr_url=%s\n' "$pr_url" >>"$GITHUB_OUTPUT"

# ── back-link from the Discussion (best effort) ───────────────────────────────
if [[ -n "${DISCUSSION_NODE_ID:-}" ]]; then
  comment="$(printf '<!-- decision-brief:pr -->\n## Decision brief drafted\n\nMary drafted `%s/brief.md` (+ market-research.md, ost.md): %s\n\nRead the brief, then decide here: add `idea:approved` to this Discussion to approve, or say why not. The brief informs the call; it does not make it.' \
    "$dest_prefix" "$pr_url")"
  if ! gh api graphql -f query='mutation($id:ID!,$body:String!){ addDiscussionComment(input:{discussionId:$id, body:$body}){ comment{ url } } }' \
      -F id="$DISCUSSION_NODE_ID" -F body="$comment" >/dev/null; then
    echo "::warning::could not post the PR link back to discussion #${DISCUSSION_NUMBER} (needs discussions:write on ${REPO}); the PR is open: ${pr_url}"
  else
    echo "linked PR from discussion #${DISCUSSION_NUMBER}"
  fi
fi
