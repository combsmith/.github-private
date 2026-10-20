#!/usr/bin/env bash
# gather-context.sh — assemble everything Mary may ground a decision brief in.
#
# Discussions and the target repo's incubation template are not part of this
# repo's checkout, so we fetch them here and hand the agent ONE JSON file. The
# provenance guard (shared.md, .github-private#1160) only works if the agent's
# grounded inputs are explicit: everything in $CONTEXT_PATH is "real input";
# anything else Mary states must be cited or marked "unknown — needs discovery".
#
# What goes in:
#   discussion         title / body / url / labels / first 50 comments
#   enhancement        the feature-ideation enhancement comment, if one exists
#                      (marker <!-- feature-ideation:enhanced --> or the legacy
#                      <!-- idea-enhancer:enhanced -->) — the sharpened problem,
#                      impact/effort and suggested ACs it carries are the brief's
#                      first-class input (see the business-analyst advisory on
#                      combsmith/incubator#3)
#   queue_excerpt      the lines of the target's "Idea Promotion Queue" tracking
#                      issue (label idea-triage) that mention this discussion —
#                      the idea-triage ripeness verdict and its promotion note
#   template           ideas/_TEMPLATE/{brief,market-research,ost}.md from the
#                      TARGET repo's default branch — Mary fills THESE, so each
#                      repo controls its own brief shape
#   package_spec       ideas/package-spec.json (the gate's required sections), or
#                      null when the target has none
#   existing_package   files already under ideas/<slug>/ — on the open
#                      incubate/<slug> branch when one exists, else the default
#                      branch (with brief.md's content, so a re-brief updates
#                      rather than overwrites blind; a brief for ANOTHER
#                      discussion under the same slug is a collision → error)
#   referenced_issues  issues / PRs the Discussion thread links by #N
#
# Emits:
#   - $CONTEXT_PATH (JSON)
#   - DISCUSSION_NODE_ID, SLUG, IDEA_TITLE -> $GITHUB_ENV
#   - discussion_node_id, slug, idea_title -> $GITHUB_OUTPUT (step outputs)
#
# Env: REPO, DISCUSSION_NUMBER, CONTEXT_PATH (required); GH_TOKEN;
#      SLUG (optional override — otherwise derived from the title);
#      SPEC_PATH (optional: where to write the fetched package-spec.json);
#      TEMPLATE_DIR (default ideas/_TEMPLATE); IDEAS_DIR (default ideas);
#      BRANCH_PREFIX (default incubate).
set -euo pipefail

REPO="${REPO:?REPO required}"
DISCUSSION_NUMBER="${DISCUSSION_NUMBER:?DISCUSSION_NUMBER required}"
CONTEXT_PATH="${CONTEXT_PATH:?CONTEXT_PATH required}"
TEMPLATE_DIR="${TEMPLATE_DIR:-ideas/_TEMPLATE}"
IDEAS_DIR="${IDEAS_DIR:-ideas}"
BRANCH_PREFIX="${BRANCH_PREFIX:-incubate}"

[[ "$DISCUSSION_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
  echo "::error::DISCUSSION_NUMBER must be a positive integer, got: '$DISCUSSION_NUMBER'" >&2
  exit 1
}

# shellcheck source=scripts/decision-brief/lib/slug.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/slug.sh"

owner="${REPO%/*}"
name="${REPO#*/}"

# ── the idea (GraphQL: discussions are not in the REST issues space) ──────────
disc="$(gh api graphql -f query='
  query($owner:String!,$name:String!,$num:Int!){
    repository(owner:$owner,name:$name){
      discussion(number:$num){
        id title body url createdAt updatedAt
        author{ login }
        category{ name slug }
        labels(first:20){ nodes{ name } }
        comments(first:50){ nodes{ author{login} body createdAt url } }
      }
    }
  }' -F owner="$owner" -F name="$name" -F num="$DISCUSSION_NUMBER")"

node_id="$(printf '%s' "$disc" | jq -r '.data.repository.discussion.id // empty')"
if [[ -z $node_id ]]; then
  echo "::error::discussion #${DISCUSSION_NUMBER} not found in ${REPO}" >&2
  exit 1
fi
category="$(printf '%s' "$disc" | jq -r '.data.repository.discussion.category.name // ""')"
if [[ $category != "Ideas" ]]; then
  echo "::warning::discussion #${DISCUSSION_NUMBER} is in category '${category}', not 'Ideas' — briefing anyway."
fi
title="$(printf '%s' "$disc" | jq -r '.data.repository.discussion.title // ""')"

# ── slug ──────────────────────────────────────────────────────────────────────
slug="${SLUG:-}"
[[ -n $slug ]] || slug="$(db_slug_from_title "$title")"
if ! db_slug_is_valid "$slug"; then
  echo "::error::could not derive a valid slug from discussion #${DISCUSSION_NUMBER} title '${title}' (got '${slug}'); dispatch again with an explicit slug" >&2
  exit 1
fi

# ── the enhancement comment (feature-ideation's single enhancer) ─────────────
enhancement="$(printf '%s' "$disc" | jq -c '
  [.data.repository.discussion.comments.nodes[]
   | select((.body // "") | test("<!-- (feature-ideation|idea-enhancer):enhanced -->"))
   | {author: (.author.login // null), body, createdAt, url}]
  | first // null')"

# ── the Idea Promotion Queue verdict for this idea (if triage runs here) ──────
queue_excerpt='null'
if queue_body="$(gh issue list --repo "$REPO" --label idea-triage --state open \
  --json number,title,body --jq 'map(select(.title | test("Idea Promotion Queue"))) | .[0] // empty' 2>/dev/null)" \
  && [[ -n $queue_body ]]; then
  # Exact token match: "#4" must not pick up the rows for #44 or #413.
  queue_excerpt="$(printf '%s' "$queue_body" | jq -c --arg n "$DISCUSSION_NUMBER" '
    {number, title,
     lines: ((.body // "") | split("\n")
             | map(select(test("(^|[^0-9#])#" + $n + "([^0-9]|$)|/discussions/" + $n + "([^0-9]|$)"))))}')"
fi

# ── the target repo's template + package spec (default branch) ───────────────
_fetch_file() { # <path> — prints decoded content, or nothing when absent
  gh api "repos/${REPO}/contents/${1}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true
}
tmpl_brief="$(_fetch_file "${TEMPLATE_DIR}/brief.md")"
tmpl_mr="$(_fetch_file "${TEMPLATE_DIR}/market-research.md")"
tmpl_ost="$(_fetch_file "${TEMPLATE_DIR}/ost.md")"
if [[ -z $tmpl_brief ]]; then
  echo "::error::${REPO} has no ${TEMPLATE_DIR}/brief.md on its default branch — the decision-brief stage fills the TARGET repo's own template (copy ideas/_TEMPLATE/ from combsmith/incubator first)" >&2
  exit 1
fi
spec_raw="$(_fetch_file "${IDEAS_DIR}/package-spec.json")"
package_spec='null'
if [[ -n $spec_raw ]] && printf '%s' "$spec_raw" | jq -e . >/dev/null 2>&1; then
  package_spec="$(printf '%s' "$spec_raw" | jq -c .)"
  # Materialise it so validate-package.sh can enforce the target's own
  # required_sections (--spec), not just the stage's built-in list.
  if [[ -n "${SPEC_PATH:-}" ]]; then printf '%s\n' "$package_spec" >"$SPEC_PATH"; fi
fi

# ── anything already under ideas/<slug>/ (re-brief / update mode) ────────────
# A brief PR may already be open from incubate/<slug>; a re-dispatch must see
# THAT branch's files (reviewed / hand-edited in flight), not the default
# branch's, because open-pr.sh appends to the same branch.
pkg_ref=""
if gh api "repos/${REPO}/git/ref/heads/${BRANCH_PREFIX}/${slug}" --jq '.object.sha' >/dev/null 2>&1; then
  pkg_ref="${BRANCH_PREFIX}/${slug}"
fi
_ref_q=""; [[ -n $pkg_ref ]] && _ref_q="?ref=${pkg_ref}"
existing_files="$(gh api "repos/${REPO}/contents/${IDEAS_DIR}/${slug}${_ref_q}" --jq '[.[] | select(.type=="file") | .name]' 2>/dev/null || echo '[]')"
printf '%s' "$existing_files" | jq -e 'type=="array"' >/dev/null 2>&1 || existing_files='[]'
existing_brief=""
if printf '%s' "$existing_files" | jq -e 'index("brief.md") != null' >/dev/null; then
  existing_brief="$(gh api "repos/${REPO}/contents/${IDEAS_DIR}/${slug}/brief.md${_ref_q}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)"
  # Collision guard: the same slug derived from a different idea's title would
  # overwrite another package. A brief that does not link THIS discussion is
  # someone else's — stop and ask for an explicit SLUG.
  if [[ -n $existing_brief ]] && ! grep -qE "/discussions/${DISCUSSION_NUMBER}([^0-9]|$)" <<<"$existing_brief"; then
    echo "::error::${IDEAS_DIR}/${slug}/brief.md (ref ${pkg_ref:-default}) belongs to another Discussion — slug collision; dispatch again with an explicit slug" >&2
    exit 1
  fi
fi

# ── issues / PRs the thread references (#N) ───────────────────────────────────
refs="$(printf '%s' "$disc" \
  | jq -r '.data.repository.discussion | ((.body // "") + " " + ([.comments.nodes[].body // empty] | join(" ")))' \
  | grep -oE '#[0-9]+' | tr -d '#' | sort -un | head -30 || true)"
ref_json='[]'
if [[ -n $refs ]]; then
  ref_json="$(while IFS= read -r n; do
      [[ -n $n ]] || continue
      [[ "$n" == "$DISCUSSION_NUMBER" ]] && continue
      gh api "repos/${REPO}/issues/${n}" --jq '{number, title, state, url: .html_url}' 2>/dev/null \
        || echo "::notice::skipping referenced #${n} (not a fetchable issue/PR — discussion/self-ref)" >&2
    done <<<"$refs" | jq -sc '.')"
fi

# ── assemble ──────────────────────────────────────────────────────────────────
jq -n \
  --arg repo "$REPO" \
  --arg slug "$slug" \
  --arg ideas_dir "$IDEAS_DIR" \
  --argjson num "$DISCUSSION_NUMBER" \
  --argjson disc "$disc" \
  --argjson enhancement "$enhancement" \
  --argjson queue "$queue_excerpt" \
  --arg tb "$tmpl_brief" --arg tm "$tmpl_mr" --arg to "$tmpl_ost" \
  --argjson spec "$package_spec" \
  --argjson existing "$existing_files" \
  --arg existing_brief "$existing_brief" \
  --arg pkg_ref "$pkg_ref" \
  --argjson refs "$ref_json" \
  '{
     repo: $repo,
     slug: $slug,
     package_dir: ($ideas_dir + "/" + $slug),
     discussion: ($disc.data.repository.discussion
       | {number: $num, title, body, url, createdAt, updatedAt,
          author: (.author.login // null),
          category: .category.name,
          labels: [.labels.nodes[].name],
          comments: [.comments.nodes[] | {author: (.author.login // null), body, createdAt, url}]}),
     enhancement: $enhancement,
     queue_excerpt: $queue,
     template: {"brief.md": $tb, "market-research.md": $tm, "ost.md": $to},
     package_spec: $spec,
     existing_package: {ref: (if $pkg_ref == "" then null else $pkg_ref end), files: $existing, "brief.md": (if $existing_brief == "" then null else $existing_brief end)},
     referenced_issues: $refs
   }' >"$CONTEXT_PATH"

# Exported twice on purpose. $GITHUB_ENV serves the model step in this job;
# $GITHUB_OUTPUT (step outputs, fixed once this step ends) serves the separate
# `land` job that validates and opens the PR — a later step (the model) can
# append to $GITHUB_ENV but cannot rewrite a finished step's outputs.
for target in "${GITHUB_ENV:-}" "${GITHUB_OUTPUT:-}"; do
  [[ -n "$target" ]] || continue
  if [[ "$target" == "${GITHUB_OUTPUT:-}" ]]; then
    { printf 'discussion_node_id=%s\n' "$node_id"; printf 'slug=%s\n' "$slug"
      printf 'idea_title<<__EOT__\n%s\n__EOT__\n' "$title"; } >>"$target"
  else
    { printf 'DISCUSSION_NODE_ID=%s\n' "$node_id"; printf 'SLUG=%s\n' "$slug"
      # Multi-line safe: titles are single-line, but guard anyway.
      printf 'IDEA_TITLE<<__EOT__\n%s\n__EOT__\n' "$title"; } >>"$target"
  fi
done

echo "context written to ${CONTEXT_PATH} (repo=${REPO}, discussion=#${DISCUSSION_NUMBER}, slug=${slug}, enhancement=$(if [[ $enhancement != "null" ]]; then echo yes; else echo no; fi), existing=$(printf '%s' "$existing_files" | jq 'length'), refs=$(printf '%s' "$ref_json" | jq 'length'))"
