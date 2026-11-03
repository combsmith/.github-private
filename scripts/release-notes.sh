#!/usr/bin/env bash
set -euo pipefail
# scripts/release-notes.sh
# Generates CHANGELOG entries for a push to main and opens a PR.
#
# Environment:
#   GITHUB_REPOSITORY  — owner/repo (set by GitHub Actions)
#   GITHUB_SHA         — HEAD commit SHA of the push
#   BEFORE_SHA         — commit SHA before the push (github.event.before)
#   DRY_RUN            — if true, print to summary only; no PR (default: true)
#   CHANGELOG_FILE     — path to changelog (default: CHANGELOG.md)
#   CHANGELOG_LABELS   — comma-separated labels to include (default: feat,fix)
#   REVIEW_ENGINE      — LLM engine (default: claude)
#   GH_TOKEN           — GitHub PAT with repo scope
#   CLAUDE_CODE_OAUTH_TOKEN — required when REVIEW_ENGINE=claude

REPO="${GITHUB_REPOSITORY:-}"
HEAD_SHA="${GITHUB_SHA:-}"
BEFORE_SHA="${BEFORE_SHA:-}"
DRY_RUN="${DRY_RUN:-true}"
CHANGELOG_FILE="${CHANGELOG_FILE:-CHANGELOG.md}"
CHANGELOG_LABELS="${CHANGELOG_LABELS:-feat,fix}"
REVIEW_ENGINE="${REVIEW_ENGINE:-claude}"
ACTION_TIMEOUT_SEC="${ACTION_TIMEOUT_SEC:-120}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_DIR="${PROMPTS_DIR:-$SCRIPT_DIR/../prompts}"

# Model family → current id resolver (#1979): name a family, never pin a version.
# shellcheck source=scripts/lib/engine-models.sh
source "$SCRIPT_DIR/lib/engine-models.sh"

log()  { echo "[release-notes] $*" >&2; }
notice() { echo "::notice::release-notes: $*"; }
warn() { echo "::warning::release-notes: $*"; }

if [[ -z "$REPO" ]] || [[ -z "$HEAD_SHA" ]]; then
  echo "::error::GITHUB_REPOSITORY and GITHUB_SHA must be set"
  exit 1
fi

SHORT_SHA="${HEAD_SHA:0:7}"

# ── Idempotency check ─────────────────────────────────────────────────────────

check_existing_pr() {
  local marker="release-notes: sha=${HEAD_SHA}"
  local existing
  existing=$(gh api "repos/$REPO/pulls" \
    --method GET \
    -f state=all \
    -f per_page=100 \
    --paginate \
    2>/dev/null \
    | jq -r --arg m "$marker" '.[] | select(.body != null and (.body | contains($m))) | .html_url' \
    || echo "")
  echo "$existing"
}

# ── Find merged PRs in the push range ────────────────────────────────────────

find_merged_prs() {
  if [[ -z "$BEFORE_SHA" ]] || [[ "$BEFORE_SHA" = "0000000000000000000000000000000000000000" ]]; then
    log "No before SHA — using single-commit range"
    BEFORE_SHA="${HEAD_SHA}^"
  fi

  log "Finding PRs merged between $BEFORE_SHA and $HEAD_SHA"

  # Get all commits in the range
  local commits
  commits=$(git log --pretty=format:"%H" "${BEFORE_SHA}..${HEAD_SHA}" 2>/dev/null || echo "")

  if [[ -z "$commits" ]]; then
    log "No commits found in range ${BEFORE_SHA}..${HEAD_SHA}"
    echo "[]"
    return
  fi

  # For each commit, find associated merged PRs via GitHub API search
  local pr_numbers=()
  while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    local associated
    associated=$(gh api "repos/$REPO/commits/$sha/pulls" \
      --jq '.[].number' 2>/dev/null || echo "")
    while IFS= read -r n; do
      [[ -n "$n" ]] && pr_numbers+=("$n")
    done < <(echo "$associated")
  done < <(echo "$commits")

  if [[ "${#pr_numbers[@]}" -eq 0 ]]; then
    echo "[]"
    return
  fi

  # Deduplicate
  local unique_prs
  unique_prs=$(printf '%s\n' "${pr_numbers[@]}" | sort -u)

  # Fetch PR metadata and filter for merged PRs
  local pr_data_list=()
  while IFS= read -r pr_num; do
    [[ -z "$pr_num" ]] && continue
    local pr_data
    # Omit body to keep payload small and avoid ARG_MAX issues with envsubst
    pr_data=$(gh api "repos/$REPO/pulls/$pr_num" \
      --jq 'select(.merged_at != null) | {number: .number, title: .title, labels: [.labels[].name], merged_at: .merged_at, html_url: .html_url}' \
      2>/dev/null || echo "")
    [[ -n "$pr_data" ]] && pr_data_list+=("$pr_data")
  done < <(echo "$unique_prs")

  local prs_json="[]"
  if [[ ${#pr_data_list[@]} -gt 0 ]]; then
    prs_json=$(printf '%s\n' "${pr_data_list[@]}" | jq -s '.')
  fi

  echo "$prs_json"
}

# ── Filter PRs by changelog-worthy labels ────────────────────────────────────

filter_prs() {
  local all_prs_json="$1"
  local label_array
  IFS=',' read -ra label_array <<< "$CHANGELOG_LABELS"

  local filter
  filter=$(printf '"%s",' "${label_array[@]}")
  filter="[${filter%,}]"

  echo "$all_prs_json" | jq --argjson labels "$filter" \
    '[.[] | select(any(.labels[]; . as $l | $labels | any(. == $l)))]'
}

# ── Generate CHANGELOG content via Claude ────────────────────────────────────

generate_changelog_block() {
  local pr_list_json="$1"

  local prompt_template="$PROMPTS_DIR/aw/release-notes.md"
  if [[ ! -f "$prompt_template" ]]; then
    warn "Prompt template not found at $prompt_template — using fallback"
    echo "$pr_list_json" | jq -r '.[] | "- \(.title) (#\(.number))"'
    return
  fi

  local tmp_json rendered_prompt
  tmp_json=$(mktemp)
  printf '%s' "$pr_list_json" > "$tmp_json"
  rendered_prompt=$(
    REPO="$REPO" \
    HEAD_SHA="$HEAD_SHA" \
    SHORT_SHA="$SHORT_SHA" \
    envsubst '${REPO},${HEAD_SHA},${SHORT_SHA}' \
    < "$prompt_template" \
    | awk -v json_file="$tmp_json" '
        /\$\{PR_LIST_JSON\}/ { while ((getline line < json_file) > 0) print line; close(json_file); next }
        { print }
      '
  )
  rm -f "$tmp_json"

  local tmp_prompt
  tmp_prompt=$(mktemp --suffix=.md)
  printf '%s' "$rendered_prompt" > "$tmp_prompt"

  local content
  case "$REVIEW_ENGINE" in
    claude)
      content=$(timeout "$ACTION_TIMEOUT_SEC" claude --print \
        --model "$(ai_model_for_family sonnet)" \
        --disallowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch,WebSearch,Task,TodoWrite,NotebookEdit" \
        < "$tmp_prompt" 2>/dev/null) || content=""
      ;;
    *)
      content=$(echo "$pr_list_json" | jq -r '.[] | "- \(.title) (#\(.number))"')
      ;;
  esac

  rm -f "$tmp_prompt"
  echo "${content:-SKIP}"
}

# ── Ensure CHANGELOG exists with header ──────────────────────────────────────

ensure_changelog() {
  if [[ ! -f "$CHANGELOG_FILE" ]]; then
    log "Creating $CHANGELOG_FILE with Keep-a-Changelog header"
    cat > "$CHANGELOG_FILE" <<'EOF'
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
EOF
  fi
}

# ── Prepend new entries to CHANGELOG ────────────────────────────────────────

prepend_changelog() {
  local block="$1"
  local today
  today=$(date -u +%Y-%m-%d)

  local tmp
  tmp=$(mktemp)

  if grep -q '^## \[Unreleased\]' "$CHANGELOG_FILE"; then
    # Reuse the existing Unreleased section — insert entries right after its heading
    awk -v block="$block" '
      /^## \[Unreleased\]/ && !inserted { print; printf "\n%s\n", block; inserted=1; next }
      { print }
    ' "$CHANGELOG_FILE" > "$tmp"
  else
    local new_section
    new_section=$(printf '\n## [Unreleased] — %s\n\n%s\n' "$today" "$block")
    awk -v section="$new_section" '
      /^## / && !inserted { print section; inserted=1 }
      { print }
      END { if (!inserted) print section }
    ' "$CHANGELOG_FILE" > "$tmp"
  fi
  mv "$tmp" "$CHANGELOG_FILE"
}

# ── Open the changelog PR ────────────────────────────────────────────────────

open_changelog_pr() {
  local block="$1"
  local branch="chore/changelog-${SHORT_SHA}"
  local pr_title="chore: update CHANGELOG for ${SHORT_SHA}"
  local idempotency_marker="<!-- release-notes: sha=${HEAD_SHA} -->"

  # Create branch, commit, push
  git checkout -b "$branch"
  ensure_changelog
  prepend_changelog "$block"
  git add "$CHANGELOG_FILE"
  git commit -m "chore: update CHANGELOG for ${SHORT_SHA} [skip ci]"
  git push origin "$branch"

  # Open PR
  gh pr create \
    --title "$pr_title" \
    --base main \
    --head "$branch" \
    --body "$(cat <<EOF
## Changelog update for push \`${SHORT_SHA}\`

This PR updates \`CHANGELOG.md\` with entries for PRs merged in push \`${HEAD_SHA}\`.

${idempotency_marker}
EOF
)"
  notice "Opened CHANGELOG PR: $pr_title"
}

# ── Summary output ────────────────────────────────────────────────────────────

write_summary() {
  local all_prs_json="$1" filtered_prs_json="$2" block="$3"
  [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] && return
  {
    echo "## Release Notes Generator — Push \`${SHORT_SHA}\`"
    echo ""
    if [[ "$DRY_RUN" = "true" ]]; then
      echo "> **DRY-RUN mode** — no branch or PR was created"
      echo ""
    fi
    echo "### Merged PRs found"
    echo ""
    echo "$all_prs_json" | jq -r '.[] | "- #\(.number): \(.title) (\(.labels | join(", ")))"' || echo "none"
    echo ""
    echo "### PRs included in CHANGELOG (filtered by: $CHANGELOG_LABELS)"
    echo ""
    echo "$filtered_prs_json" | jq -r '.[] | "- #\(.number): \(.title)"' || echo "none"
    echo ""
    echo "### Generated CHANGELOG block"
    echo ""
    echo '```markdown'
    echo "$block"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
}

# ── Main ──────────────────────────────────────────────────────────────────────

log "Starting release-notes generator (repo=$REPO, sha=$SHORT_SHA, dry_run=$DRY_RUN)"

# Idempotency: skip if CHANGELOG PR already exists for this SHA
existing_pr=$(check_existing_pr)
if [[ -n "$existing_pr" ]]; then
  notice "CHANGELOG PR already exists for SHA $HEAD_SHA — skipping ($existing_pr)"
  exit 0
fi

# Find and filter PRs
all_prs_json=$(find_merged_prs)
filtered_prs_json=$(filter_prs "$all_prs_json")

pr_count=$(echo "$filtered_prs_json" | jq 'length')
if [[ "$pr_count" -eq 0 ]]; then
  notice "No feat/fix PRs found in push $SHORT_SHA — skipping changelog"
  exit 0
fi

log "Found $pr_count PR(s) for changelog"

# Generate content
changelog_block=$(generate_changelog_block "$filtered_prs_json")

if [[ "$changelog_block" = "SKIP" ]] || [[ -z "$changelog_block" ]]; then
  notice "Claude returned SKIP — no user-facing changes in push $SHORT_SHA"
  exit 0
fi

# Write summary in all cases
write_summary "$all_prs_json" "$filtered_prs_json" "$changelog_block"

if [[ "$DRY_RUN" = "true" ]]; then
  log "DRY-RUN: would open PR 'chore: update CHANGELOG for $SHORT_SHA'"
  exit 0
fi

# Configure git identity for the commit
git config --global user.email "donpetry-bot@users.noreply.github.com"
git config --global user.name "donpetry-bot"

open_changelog_pr "$changelog_block"
log "Done"
