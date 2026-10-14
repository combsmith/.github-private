#!/usr/bin/env bash
set -euo pipefail
# scripts/aw-readme-refresh.sh
# Weekly README Refresh agent. Reads live org state, regenerates the four org
# "meta-repo" READMEs via Claude, and opens (or updates) one rolling PR per repo.
#
# Targets:
#   combsmith/.github          profile/README.md   (public org profile)
#   combsmith/.github          README.md           (repo landing page)
#   combsmith/.github-private  README.md           (repo landing page)
#   combsmith/.github-private  profile/README.md   (member-only org profile)
#
# Environment:
#   ORG                     — org login (default: combsmith)
#   DRY_RUN                 — if true, generate + diff only; no branch/PR (default: false)
#   GH_TOKEN                — GitHub PAT with repo write on both target repos
#   CLAUDE_CODE_OAUTH_TOKEN — Claude auth (read by the claude CLI)
#   CLAUDE_MODEL            — model id (default: claude-sonnet-4-6)
#   ACTION_TIMEOUT_SEC      — per-target claude timeout (default: 300)
#   README_REFRESH_OUTPUT_DIR — if set, copy each generated file here (debug/dry-run inspection)

ORG="${ORG:-combsmith}"
DRY_RUN="${DRY_RUN:-false}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
ACTION_TIMEOUT_SEC="${ACTION_TIMEOUT_SEC:-300}"
BRANCH="chore/readme-refresh"
LABEL="readme-refresh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROMPT_TEMPLATE="$REPO_ROOT/prompts/aw/readme-refresh.md"

# shellcheck source=scripts/lib/git-identity.sh
source "$SCRIPT_DIR/lib/git-identity.sh"

log()    { echo "[readme-refresh] $*" >&2; }
notice() { echo "::notice::readme-refresh: $*"; }
warn()   { echo "::warning::readme-refresh: $*"; }

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error::GH_TOKEN must be set" >&2
  exit 1
fi
if [ ! -f "$PROMPT_TEMPLATE" ]; then
  echo "::error::Prompt template not found at $PROMPT_TEMPLATE" >&2
  exit 1
fi

# ── Facts bundle ──────────────────────────────────────────────────────────────
# Assemble authoritative live org state so Claude never invents names.

EMPTY_DESC_REPOS=""   # populated by gather_facts; surfaced in the PR body

gather_facts() {
  local facts_file="$WORK_DIR/facts.md"
  local repo_json standards_list

  repo_json=$(gh repo list "$ORG" --limit 1000 \
    --json name,description,primaryLanguage,isArchived,isPrivate \
    --jq 'sort_by(.name)' 2>/dev/null || echo "[]")

  EMPTY_DESC_REPOS=$(echo "$repo_json" \
    | jq -r '[.[] | select((.description // "") == "") | .name] | join(", ")' 2>/dev/null || echo "")
  # gather_facts runs in a $(...) subshell, so persist this for the parent via a sidecar file.
  printf '%s' "$EMPTY_DESC_REPOS" > "$WORK_DIR/empty_desc.txt"

  # Standards docs live in the sibling .github repo; fetch via API (not checked out here).
  standards_list=$(gh api "repos/$ORG/.github/contents/standards" \
    --jq '[.[] | select((.name // "") | endswith(".md")) | .name | sub("\\.md$";"")] | sort | .[]' \
    2>/dev/null || echo "(unavailable)")

  {
    echo "### Live repositories in \`$ORG\` (source of truth for the projects table)"
    echo ""
    echo '```json'
    echo "$repo_json"
    echo '```'
    echo ""
    if [ -n "$EMPTY_DESC_REPOS" ]; then
      echo "Repos with an EMPTY GitHub description (keep any existing curated text; do not blank): ${EMPTY_DESC_REPOS}"
      echo ""
    fi
    echo "### Standards docs in \`$ORG/.github/standards/\`"
    echo ""
    if [ -n "$standards_list" ]; then
      echo "$standards_list" | sed 's/^/- /'
    fi
    echo ""
    echo "### Custom agents in \`.github-private/agents/\`"
    echo ""
    local f name desc
    for f in "$REPO_ROOT"/agents/*.md; do
      [ -e "$f" ] || continue
      name="$(basename "$f" .md)"
      desc="$(awk '/^description:/{sub(/^description:[[:space:]]*/,"");gsub(/^["'"'"']|["'"'"']$/,"");print;exit}' "$f")"
      printf -- '- `%s`: %s\n' "$name" "$desc"
    done
    echo ""
    echo "### Installed frameworks in \`.github-private/frameworks/\` (from each VENDOR.md)"
    echo ""
    local d src
    for d in "$REPO_ROOT"/frameworks/*/; do
      [ -d "$d" ] || continue
      name="$(basename "$d")"
      src="$(grep -iE '^(source|upstream|tag|version)' "$d/VENDOR.md" 2>/dev/null | head -2 | tr '\n' '; ' | sed 's/; *$//' || true)"
      printf -- '- `%s` (%s)\n' "$name" "${src:-vendored}"
    done
  } > "$facts_file"

  echo "$facts_file"
}

# ── Prompt rendering ──────────────────────────────────────────────────────────
# Scalars via envsubst; multiline blocks (facts, current content) injected by awk
# to avoid ARG_MAX limits (same technique as release-notes.sh).

render_prompt() {
  if [ $# -lt 5 ]; then return 1; fi
  local facts_file="$1" current_file="$2" target_label="$3" target_type="$4" maxlen="$5"
  TARGET_LABEL="$target_label" TARGET_TYPE="$target_type" LINT_MAXLEN="$maxlen" \
    envsubst '${TARGET_LABEL} ${TARGET_TYPE} ${LINT_MAXLEN}' < "$PROMPT_TEMPLATE" \
    | awk -v ff="$facts_file" -v cf="$current_file" '
        /\$\{FACTS_BUNDLE\}/    { while ((getline l < ff) > 0) print l; close(ff); next }
        /\$\{CURRENT_CONTENT\}/ { while ((getline l < cf) > 0) print l; close(cf); next }
        { print }'
}

# ── Content generation ────────────────────────────────────────────────────────

generate_content() {
  local prompt_file="$1"
  local err_file="$WORK_DIR/claude-stderr.$$"
  timeout "$ACTION_TIMEOUT_SEC" claude --print \
    --model "$CLAUDE_MODEL" \
    --disallowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch,WebSearch,Task,TodoWrite,NotebookEdit" \
    < "$prompt_file" 2>"$err_file" || { warn "claude invocation failed: $(tail -n5 "$err_file" 2>/dev/null)"; echo ""; }
}

# Extract the file body between the sentinel markers the prompt requires. This is robust
# against reasoning preambles / trailing commentary the model may add around the body.
extract_readme() {
  printf '%s\n' "$1" | awk '
    /^===README-END===[[:space:]]*$/   { f=0 }
    f                                   { print }
    /^===README-BEGIN===[[:space:]]*$/ { f=1 }'
}

# Remove leading and trailing blank lines (interior blanks preserved).
trim_blank_edges() {
  printf '%s\n' "$1" | sed '/./,$!d' | tac | sed '/./,$!d' | tac
}

# Comma-list of body line numbers whose length exceeds maxlen, excluding table rows and
# fenced code blocks (both exempt from markdownlint MD013). Empty if all lines fit.
overlong_lines() {
  local content="$1" maxlen="$2"
  printf '%s\n' "$content" | awk -v max="$maxlen" '
    /^[[:space:]]*```/  { infence = !infence; next }
    infence             { next }
    /^[[:space:]]*\|/   { next }
    length > max        { printf "%s%d", (c++ ? "," : ""), NR }'
}

# Reject obviously-malformed output before writing (protects lint + prevents junk PRs).
valid_content() {
  local content="$1" target_type="$2"
  [ -n "$content" ] || return 1
  [ "$content" = "SKIP" ] && return 1
  case "$target_type" in
    org-profile-public|github-repo-readme)
      # .github repo requires MD041: first line is a top-level heading.
      printf '%s\n' "$content" | head -n1 | grep -q '^# ' || return 1
      ;;
  esac
  return 0
}

# ── Per-repo processing ───────────────────────────────────────────────────────
# Target matrix, grouped by repo. Fields: <rel_path>|<target_type>|<label>|<maxlen>

targets_for_repo() {
  if [ $# -lt 1 ]; then return 1; fi
  case "$1" in
    ".github")
      printf '%s\n' \
        "profile/README.md|org-profile-public|the PUBLIC org profile (.github/profile/README.md)|200" \
        "README.md|github-repo-readme|the .github repo landing README|200"
      ;;
    ".github-private")
      printf '%s\n' \
        "README.md|github-private-repo-readme|the .github-private repo landing README|400" \
        "profile/README.md|org-profile-member|the MEMBER-ONLY org profile (.github-private/profile/README.md)|400"
      ;;
  esac
}

process_repo() {
  if [ $# -lt 2 ]; then return 1; fi
  local repo="$1" facts_file="$2"
  local full_repo="$ORG/$repo"
  local dir="$WORK_DIR/$repo"
  local LINT_WARNINGS=""

  log "Cloning $full_repo"
  # Auth is handled by gh's git credential helper (configured in main via `gh auth setup-git`),
  # which works for both PATs and App tokens. Guard the clone so a failure aborts this repo
  # loudly instead of silently generating into an empty directory.
  if ! GIT_TERMINAL_PROMPT=0 git clone --quiet "https://github.com/${full_repo}.git" "$dir" || [ ! -d "$dir/.git" ]; then
    warn "clone failed for $full_repo — skipping this repo"
    return 1
  fi
  local default_branch
  default_branch="$(git -C "$dir" symbolic-ref --short HEAD)"
  # Rolling branch: always reset to default HEAD so the PR reflects "main + fresh READMEs".
  git -C "$dir" checkout -q -B "$BRANCH"

  local changed=0 rel_path target_type label maxlen
  while IFS='|' read -r rel_path target_type label maxlen; do
    [ -n "$rel_path" ] || continue
    local target_path="$dir/$rel_path"
    local current_file="$WORK_DIR/current.$$"
    if [ -f "$target_path" ]; then cp "$target_path" "$current_file"; else : > "$current_file"; fi

    local prompt_file="$WORK_DIR/prompt.md"
    render_prompt "$facts_file" "$current_file" "$label" "$target_type" "$maxlen" > "$prompt_file"

    log "Generating: $repo/$rel_path ($target_type)"
    local raw content violations="" attempt=1
    while :; do
      raw="$(generate_content "$prompt_file")"
      if [ "$attempt" -eq 1 ] && [ "$(printf '%s' "$raw" | tr -d '[:space:]')" = "SKIP" ]; then
        if [ -s "$current_file" ]; then
          content="__SKIP__"; break
        else
          log "  → SKIP rejected: target is new/empty, retrying"
          attempt=$((attempt + 1))
          continue
        fi
      fi
      content="$(trim_blank_edges "$(extract_readme "$raw")")"
      if ! valid_content "$content" "$target_type"; then content="__INVALID__"; break; fi
      violations="$(overlong_lines "$content" "$maxlen")"
      if [ -z "$violations" ] || [ "$attempt" -ge 2 ]; then break; fi
      log "  → retry: body line(s) over $maxlen chars at $violations"
      {
        printf '\n## Correction (attempt %d)\n' "$((attempt + 1))"
        printf 'Your previous output had prose line(s) exceeding %s characters (body line(s): %s).\n' "$maxlen" "$violations"
        printf 'Re-emit the FULL body between the markers with EVERY prose line hard-wrapped to <= %s characters. Tables and fenced code blocks are exempt.\n' "$maxlen"
      } >> "$prompt_file"
      attempt=$((attempt + 1))
    done

    if [ "$content" = "__SKIP__" ]; then
      log "  → SKIP (already accurate)"
      rm -f "$current_file"
      continue
    fi
    if [ "$content" = "__INVALID__" ]; then
      warn "  → invalid/empty output for $repo/$rel_path — leaving unchanged"
      rm -f "$current_file"
      continue
    fi
    if [ -n "$violations" ]; then
      warn "  → $repo/$rel_path still has body line(s) over $maxlen ($violations) after retry — writing; trim before merge"
      LINT_WARNINGS="${LINT_WARNINGS}- \`$rel_path\`: body line(s) exceed ${maxlen} chars (${violations})"$'\n'
    fi

    mkdir -p "$(dirname "$target_path")"
    printf '%s\n' "$content" > "$target_path"
    if [ -n "${README_REFRESH_OUTPUT_DIR:-}" ]; then
      mkdir -p "$README_REFRESH_OUTPUT_DIR/$repo/$(dirname "$rel_path")"
      cp "$target_path" "$README_REFRESH_OUTPUT_DIR/$repo/$rel_path"
    fi
    if git -C "$dir" diff --quiet -- "$rel_path" 2>/dev/null && \
       [ -n "$(git -C "$dir" ls-files -- "$rel_path")" ]; then
      log "  → no change"
    else
      log "  → updated"
      changed=1
    fi
    rm -f "$current_file"
  done < <(targets_for_repo "$repo")

  if [ "$changed" -eq 0 ]; then
    notice "$full_repo: all READMEs already accurate — nothing to do"
    return 0
  fi

  git -C "$dir" add -A
  if git -C "$dir" diff --cached --quiet; then
    notice "$full_repo: no net changes after staging — skipping"
    return 0
  fi

  echo "### $full_repo" >> "$WORK_DIR/summary.md"
  git -C "$dir" --no-pager diff --cached --stat >> "$WORK_DIR/summary.md" 2>/dev/null || true

  if [ "$DRY_RUN" = "true" ]; then
    log "DRY-RUN: would open/update PR on $full_repo (branch $BRANCH). Diff:"
    git -C "$dir" --no-pager diff --cached --stat >&2 || true
    return 0
  fi

  ( cd "$dir" && setup_git_identity )
  git -C "$dir" commit -q -m "docs: refresh org READMEs from live state (automated) [skip ci]"
  git -C "$dir" push --force-with-lease --quiet origin "$BRANCH"

  # Ensure the label exists (idempotent), then create the PR if none is open.
  gh label create "$LABEL" --repo "$full_repo" --color BFD4F2 \
    --description "Automated README refresh" >/dev/null 2>&1 || true

  local existing
  existing="$(gh pr list --repo "$full_repo" --head "$BRANCH" --state open \
    --json url --jq '.[0]?.url' 2>/dev/null || echo "")"

  local empty_note=""
  [ -n "$EMPTY_DESC_REPOS" ] && empty_note=$'\n\n**Action needed:** these repos have empty GitHub descriptions — set them on the repo page so future refreshes can enrich the table: '"$EMPTY_DESC_REPOS"
  local lint_note=""
  [ -n "$LINT_WARNINGS" ] && lint_note=$'\n\n**⚠️ Trim before merge — these lines exceed the markdownlint length limit:**\n'"$LINT_WARNINGS"

  if [ -n "$existing" ]; then
    notice "$full_repo: updated existing PR $existing"
  else
    local url
    url="$(gh pr create --repo "$full_repo" --base "$default_branch" --head "$BRANCH" \
      --label "$LABEL" \
      --title "docs: refresh org READMEs (automated)" \
      --body "$(cat <<EOF
## Automated README refresh

Regenerated the org meta-repo README(s) in \`$full_repo\` from live org state
(repository list, standards docs, agent profiles, and installed frameworks).

Generated by the weekly \`readme-refresh\` workflow in \`$ORG/.github-private\`.
Review the diff — curated prose is preserved; only missing/stale facts are corrected.${empty_note}${lint_note}
EOF
)")"
    notice "$full_repo: opened PR $url"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

log "Starting README refresh (org=$ORG, dry_run=$DRY_RUN, model=$CLAUDE_MODEL)"
if ! command -v claude >/dev/null 2>&1; then
  echo "::error::claude CLI not found on PATH" >&2
  exit 1
fi

# Route git's github.com credentials through gh (uses GH_TOKEN). This authenticates the
# cross-repo clone/push for any token type — unlike an embedded x-access-token: or
# "Authorization: Bearer" header, which GitHub rejects for a classic/fine-grained PAT.
# Isolate the config writes to a temp file so local runs don't mutate ~/.gitconfig; CI
# sets GIT_CONFIG_GLOBAL already, so we only override when it is unset.
if [ -z "${GIT_CONFIG_GLOBAL:-}" ]; then
  _gc_tmp="$(mktemp)"
  export GIT_CONFIG_GLOBAL="$_gc_tmp"
fi
if ! gh auth setup-git --hostname github.com >/dev/null 2>&1; then
  warn "gh auth setup-git failed — cross-repo git push may not authenticate"
fi

facts_file="$(gather_facts)"
EMPTY_DESC_REPOS="$(cat "$WORK_DIR/empty_desc.txt" 2>/dev/null || echo "")"
log "Facts bundle assembled ($(wc -l < "$facts_file") lines); empty-desc repos: ${EMPTY_DESC_REPOS:-none}"

for _repo in ".github" ".github-private"; do
  if ! process_repo "$_repo" "$facts_file"; then
    warn "$ORG/$_repo: processing failed — continuing with remaining repos"
  fi
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "$WORK_DIR/summary.md" ]; then
  {
    echo "## README Refresh"
    [ "$DRY_RUN" = "true" ] && echo "> **DRY-RUN** — no branches or PRs were created" && echo ""
    cat "$WORK_DIR/summary.md"
  } >> "$GITHUB_STEP_SUMMARY"
fi

log "Done"
