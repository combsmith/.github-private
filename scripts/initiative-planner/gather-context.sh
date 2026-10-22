#!/usr/bin/env bash
# gather-context.sh — assemble the planning context for the BMAD Scrum Master.
#
# Discussions are not part of the git checkout, so we fetch the approved idea
# (title/body/first 50 comments + GraphQL node id) here and hand it to the agent as a
# single JSON file. We also surface the open `initiative` epics (so Bob can
# avoid duplicating one) and the issue numbers the idea references (likely
# prerequisites). The agent reads everything else (AGENTS.md, scripts, docs)
# straight from the checkout with its own tools.
#
# Under RECONCILE=1 (#708 reconcile-in-place) we additionally bind to the epic
# already planned for this idea (via the same back-reference #598/apply-plan.sh
# key) and harvest its sub-issues — their state, labels (in-flight detection),
# and comments — so Bob can surface newly-flagged follow-ups from review/sub-issue
# threads and route them through the plan-critic acceptance gate. Read-only: this
# never mutates the epic.
#
# Cross-repo graduation: the approved idea's Discussion may live in a DIFFERENT
# repo (DISCUSSION_REPO, e.g. the incubator) from the repo we plan INTO (REPO,
# e.g. the product repo). The Discussion and the issues it references are read
# from DISCUSSION_REPO; open epics, the reconcile harvest and the planning
# artifacts are read from REPO. DISCUSSION_REPO defaults to REPO (same-repo path).
#
# Planning artifacts: when REPO has BMAD planning output under
# _bmad-output/planning-artifacts/ (the org's planning source of truth, see
# AGENTS.md), its markdown files are included under `planning_artifacts`:
# prd.md in full, every other .md truncated to PLANNING_ARTIFACT_MAX_CHARS. A
# 404 on the folder (or no markdown in it) yields `planning_artifacts: null` and
# Bob plans from the Discussion as before. Any other API failure fails loud.
#
# Emits:
#   - $CONTEXT_PATH (JSON)               the planning context
#   - DISCUSSION_NODE_ID -> $GITHUB_ENV  so apply-plan can comment back
#
# Env: REPO, DISCUSSION_NUMBER, CONTEXT_PATH (all required); GH_TOKEN;
#      DISCUSSION_REPO (optional owner/repo holding the Discussion; default REPO);
#      RECONCILE (optional, "1" => also harvest the bound epic's sub-issues);
#      PLANNING_ARTIFACTS_DIR (default _bmad-output/planning-artifacts);
#      PLANNING_ARTIFACT_MAX_CHARS (default 12000; per non-PRD file);
#      PLANNING_ARTIFACT_MAX_FILES (default 20; markdown files read).
set -euo pipefail

REPO="${REPO:?REPO required}"
DISCUSSION_NUMBER="${DISCUSSION_NUMBER:?DISCUSSION_NUMBER required}"
CONTEXT_PATH="${CONTEXT_PATH:?CONTEXT_PATH required}"
DISCUSSION_REPO="${DISCUSSION_REPO:-$REPO}"
PLANNING_ARTIFACTS_DIR="${PLANNING_ARTIFACTS_DIR:-_bmad-output/planning-artifacts}"
PLANNING_ARTIFACT_MAX_CHARS="${PLANNING_ARTIFACT_MAX_CHARS:-12000}"
PLANNING_ARTIFACT_MAX_FILES="${PLANNING_ARTIFACT_MAX_FILES:-20}"

# Validate before the values reach a gh command line or an API path.
repo_re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
for v in REPO DISCUSSION_REPO; do
  [[ ${!v} =~ $repo_re ]] || { echo "::error::${v} must be owner/repo, got: '${!v}'" >&2; exit 1; }
done
[[ $DISCUSSION_NUMBER =~ ^[1-9][0-9]*$ ]] || {
  echo "::error::DISCUSSION_NUMBER must be a positive integer, got: '${DISCUSSION_NUMBER}'" >&2
  exit 1
}

owner="${DISCUSSION_REPO%/*}"
name="${DISCUSSION_REPO#*/}"

# The idempotency back-reference apply-plan.sh stamps on the epic. Same-repo it
# stays "#N" (unchanged, so existing epics still bind); cross-repo it is the
# fully-qualified "owner/repo#N" so it links to the right Discussion.
disc_ref="#${DISCUSSION_NUMBER}"
[[ $DISCUSSION_REPO == "$REPO" ]] || disc_ref="${DISCUSSION_REPO}#${DISCUSSION_NUMBER}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── the approved idea (GraphQL: discussion is not in the REST issues space) ────
disc="$(gh api graphql -f query='
  query($owner:String!,$name:String!,$num:Int!){
    repository(owner:$owner,name:$name){
      discussion(number:$num){
        id title body url
        category{ name }
        comments(first:50){ nodes{ author{login} body createdAt } }
      }
    }
  }' -F owner="$owner" -F name="$name" -F num="$DISCUSSION_NUMBER")"

node_id="$(printf '%s' "$disc" | jq -r '.data.repository.discussion.id')"
category="$(printf '%s' "$disc" | jq -r '.data.repository.discussion.category.name // ""')"
if [[ -z $node_id ]] || [[ $node_id = "null" ]]; then
  echo "::error::discussion #${DISCUSSION_NUMBER} not found in ${DISCUSSION_REPO}" >&2
  exit 1
fi
if [[ $category != "Ideas" ]]; then
  echo "::warning::discussion #${DISCUSSION_NUMBER} is in category '${category}', not 'Ideas' — planning anyway."
fi
printf 'DISCUSSION_NODE_ID=%s\n' "$node_id" >>"${GITHUB_ENV:-/dev/null}"

# ── existing open epics (avoid duplicate initiatives) ─────────────────────────
if ! epics="$(gh issue list --repo "$REPO" --label initiative --state open \
  --json number,title --jq '[.[] | {number, title}]' 2>/dev/null)"; then
  echo "::error::failed to fetch open initiative epics for ${REPO}" >&2
  exit 1
fi

# ── issue numbers referenced by the idea (likely prerequisites) ───────────────
refs="$(printf '%s' "$disc" \
  | jq -r '.data.repository.discussion | ((.body // "") + " " + ([.comments.nodes[].body // empty] | join(" ")))' \
  | grep -oE '#[0-9]+' | tr -d '#' | sort -un | head -30 || true)"
ref_json='[]'
if [[ -n $refs ]]; then
  ref_json="$(while IFS= read -r n; do
      [[ -n $n ]] || continue
      # A bare #N in the Discussion resolves against the Discussion's OWN repo,
      # so fetch it from DISCUSSION_REPO and record that repo on each entry
      # (cross-repo, these are NOT issues in REPO and must not become
      # blocked_by_existing_issues edges there).
      # A referenced #N may be an issue, a PR, a Discussion, or the idea's own
      # number. Note that the GitHub issues API also returns PRs, so both issues
      # and PRs are fetched successfully. Skip anything the issues endpoint
      # can't return (404 for discussions / self-refs) instead of failing the
      # whole run; a genuine API/auth fault still surfaces via the epics query
      # above (which fails fast).
      gh api "repos/${DISCUSSION_REPO}/issues/${n}" --jq "{repo: \"${DISCUSSION_REPO}\", number, title, state}" 2>/dev/null \
        || echo "::notice::skipping referenced #${n} (not a fetchable issue/PR — discussion/self-ref)" >&2
    done <<<"$refs" | jq -sc '.')"
fi

# ── reconcile harvest (#708): the bound epic's sub-issues + comments ──────────
# Only under RECONCILE=1. Bind to the epic already planned for this idea using
# the SAME back-reference as apply-plan.sh/find_existing_epic, then harvest its
# sub-issues (open + closed) with labels and comments so Bob can pick up
# follow-ups flagged in review/sub-issue threads. Read-only; on no bound epic we
# emit an empty harvest and let apply-plan's reconcile no-op path handle it.
reconcile_json='null'
if [[ "${RECONCILE:-0}" == "1" ]]; then
  backref="Planned from idea discussion ${disc_ref}"
  bound_epic="$(gh issue list --repo "$REPO" --label initiative --state open \
    --search "\"$backref\"" --json number,body 2>/dev/null \
    | jq -r --arg ref "$backref" 'first(.[] | select((.body // "" | tostring) | contains($ref)) | .number) // empty' || true)"
  subs_json='[]'
  if [[ -n $bound_epic ]]; then
    # sub_issues returns every child regardless of state; enrich each with its
    # labels and comment thread so in-flight (dev-lead-labelled) stories are
    # distinguishable and comment-surfaced follow-ups are visible to Bob.
    # Fetch sub_issues once (paginated); --jq emits one NDJSON object per sub-issue
    # so metadata is extracted without a separate API call per sub-issue. Comments are
    # capped to the first page (no --paginate) to keep the harvest bounded (#708).
    sub_issues_meta="$(gh api "repos/${REPO}/issues/${bound_epic}/sub_issues" --paginate \
      --jq '.[] | {number, title, state, labels: [.labels[].name]}' 2>/dev/null || true)"
    if [[ -n $sub_issues_meta ]]; then
      subs_json="$(while IFS= read -r sub; do
          [[ -n $sub ]] || continue
          sn="$(jq -r '.number' <<< "$sub")"
          cmts="$(gh api "repos/${REPO}/issues/${sn}/comments" \
            --jq '[.[] | {author: .user?.login, body, createdAt: .created_at}]' 2>/dev/null || echo '[]')"
          jq -nc --argjson m "$sub" --argjson c "$cmts" '$m + {comments: $c}'
        done <<< "$sub_issues_meta" | jq -sc '.')"
    fi
    reconcile_json="$(jq -nc --argjson epic "$bound_epic" --argjson subs "$subs_json" \
      '{mode:"reconcile", epic:$epic, sub_issues:$subs}')"
  else
    echo "::warning::reconcile: no existing epic bound to idea discussion ${disc_ref} — harvesting nothing."
    reconcile_json="$(jq -nc '{mode:"reconcile", epic:null, sub_issues:[]}')"
  fi
fi

# ── planning artifacts (target repo's BMAD planning output) ───────────────────
# List the folder via the contents API. 404 => no artifacts (null, unchanged
# behaviour). Any other failure fails loud rather than letting Bob silently plan
# from Discussion prose when a PRD exists. Each file is fetched raw into $work and
# fed to jq with --rawfile, so a large PRD never rides on a command-line argument.
printf 'null\n' >"$work/artifacts.json"
art_err="$work/artifacts.err"
if listing="$(gh api "repos/${REPO}/contents/${PLANNING_ARTIFACTS_DIR}" 2>"$art_err")"; then
  if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$listing"; then
    echo "::notice::${REPO}:${PLANNING_ARTIFACTS_DIR} is not a directory listing — no planning artifacts."
    listing='[]'
  fi
  # prd.md first, then the rest by name; only top-level markdown files are read.
  mapfile -t md_paths < <(jq -r --argjson max "$PLANNING_ARTIFACT_MAX_FILES" '
    [.[] | select(.type == "file" and (.name | test("\\.md$"; "i")))]
    | sort_by((.name | ascii_downcase) != "prd.md", .name)
    | .[:$max][] | .path' <<<"$listing")
  jq -c --argjson max "$PLANNING_ARTIFACT_MAX_FILES" '
    [.[] | select(.type == "file" and (.name | test("\\.md$"; "i")))] as $md
    | [.[] | select((.type == "file" and (.name | test("\\.md$"; "i"))) | not) | .name]
      + [$md | sort_by((.name | ascii_downcase) != "prd.md", .name) | .[$max:][] | .name]' \
    <<<"$listing" >"$work/skipped.json"
  i=0
  for path in "${md_paths[@]}"; do
    [[ $path =~ ^[A-Za-z0-9_./-]+$ ]] || {
      echo "::warning::skipping planning artifact with an unsafe path: '${path}'"
      continue
    }
    i=$((i + 1))
    gh api -H 'Accept: application/vnd.github.raw' "repos/${REPO}/contents/${path}" >"$work/art.$i.md"
    jq -n --rawfile c "$work/art.$i.md" --arg path "$path" --argjson max "$PLANNING_ARTIFACT_MAX_CHARS" '
      ($path | split("/") | last) as $name
      | (($name | ascii_downcase) == "prd.md") as $full
      | {name: $name, path: $path, chars: ($c | length),
         truncated: ((($full | not)) and (($c | length) > $max)),
         content: (if $full then $c else $c[:$max] end)}' >"$work/art.$i.json"
  done
  if [[ $i -gt 0 ]]; then
    jq -s --arg dir "$PLANNING_ARTIFACTS_DIR" --slurpfile skipped "$work/skipped.json" \
      '{dir: $dir,
        prd: (map(select((.name | ascii_downcase) == "prd.md")) | first | .path? // null),
        files: .,
        skipped: $skipped[0]}' "$work"/art.*.json >"$work/artifacts.json"
  else
    echo "::notice::${REPO}:${PLANNING_ARTIFACTS_DIR} has no markdown files — no planning artifacts."
  fi
elif grep -qE 'HTTP 404|Not Found' "$art_err"; then
  echo "::notice::no ${PLANNING_ARTIFACTS_DIR} in ${REPO} — planning from the Discussion only."
else
  echo "::error::failed to list ${PLANNING_ARTIFACTS_DIR} in ${REPO}: $(cat "$art_err")" >&2
  exit 1
fi

# ── assemble ──────────────────────────────────────────────────────────────────
jq -n \
  --argjson disc "$disc" \
  --argjson epics "$epics" \
  --argjson refs "$ref_json" \
  --argjson reconcile "$reconcile_json" \
  --slurpfile artifacts "$work/artifacts.json" \
  --arg repo "$REPO" \
  --arg disc_repo "$DISCUSSION_REPO" \
  --argjson num "$DISCUSSION_NUMBER" \
  '{
     repo: $repo,
     discussion_repo: $disc_repo,
     discussion: ($disc.data.repository.discussion | {number: $num, title, body, url, category: .category.name, comments: [.comments.nodes[] | {author: .author.login, body, createdAt}]}),
     open_epics: $epics,
     referenced_issues: $refs,
     reconcile: $reconcile,
     planning_artifacts: $artifacts[0]
   }' >"$CONTEXT_PATH"

echo "context written to ${CONTEXT_PATH} (discussion=${DISCUSSION_REPO}#${DISCUSSION_NUMBER}, node=${node_id}, artifacts=$(jq '.planning_artifacts.files // [] | length' "$CONTEXT_PATH"), refs=$(printf '%s' "$ref_json" | jq 'length'), epics=$(printf '%s' "$epics" | jq 'length')$(if [[ "${RECONCILE:-0}" == "1" ]]; then printf ', reconcile_subs=%s' "$(printf '%s' "$reconcile_json" | jq '.sub_issues | length')"; fi))"
