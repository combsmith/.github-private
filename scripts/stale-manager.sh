#!/usr/bin/env bash
set -euo pipefail
# scripts/stale-manager.sh
# Org-wide stale issue/PR manager.
#
# Scans all non-archived repos in TARGET_ORG for open issues and PRs.
# Determines staleness using configured thresholds, generates contextual
# comments via Claude, and applies labels/close actions.
#
# Environment:
#   TARGET_ORG         — GitHub org to scan (default: petry-projects)
#   STALE_DAYS_ISSUE   — days before issue is stale (default: 60)
#   STALE_DAYS_PR      — days before PR is stale (default: 30)
#   GRACE_DAYS         — days after stale label before closure (default: 7)
#   DRY_RUN            — if true, report only; no writes (default: true)
#   REVIEW_ENGINE      — LLM engine for comment generation (default: claude)
#   GH_TOKEN           — GitHub PAT with repo + read:org scope
#   CLAUDE_CODE_OAUTH_TOKEN — required when REVIEW_ENGINE=claude

TARGET_ORG="${TARGET_ORG:-petry-projects}"
STALE_DAYS_ISSUE="${STALE_DAYS_ISSUE:-60}"
STALE_DAYS_PR="${STALE_DAYS_PR:-30}"
GRACE_DAYS="${GRACE_DAYS:-7}"
DRY_RUN="${DRY_RUN:-true}"
REVIEW_ENGINE="${REVIEW_ENGINE:-claude}"
ACTION_TIMEOUT_SEC="${ACTION_TIMEOUT_SEC:-120}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_DIR="${PROMPTS_DIR:-$SCRIPT_DIR/../prompts}"

# Model family → current id resolver (#1979): name a family, never pin a version.
# shellcheck source=scripts/lib/engine-models.sh
source "$SCRIPT_DIR/lib/engine-models.sh"

SUMMARY_ROWS=()
ACTIONS_TAKEN=0
ACTIONS_SKIPPED=0

log()  { echo "[stale-manager] $*" >&2; }
warn() { echo "::warning::stale-manager: $*"; }

# now_ts — unix timestamp in seconds (UTC)
now_ts() { date -u +%s; }

# iso_to_ts <iso8601> — convert ISO 8601 timestamp to unix epoch
iso_to_ts() {
  # Try GNU date first, fall back to BSD date (macOS)
  date -u -d "$1" +%s 2>/dev/null \
    || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null \
    || echo "0"
}

# days_since <iso8601> — returns integer days since the timestamp
days_since() {
  local ts
  ts=$(iso_to_ts "$1")
  echo $(( ( $(now_ts) - ts ) / 86400 ))
}

# labels_include <labels_json> <label_name>
labels_include() {
  echo "$1" | jq -e --arg l "$2" 'any(.[]; .name == $l)' >/dev/null 2>&1
}

# has_stale_warning_comment <repo> <number> — checks for the idempotency marker
has_stale_warning_comment() {
  local repo="$1" number="$2"
  gh api "repos/$repo/issues/$number/comments" \
    --paginate \
    --jq '.[].body' 2>/dev/null \
  | grep -qF '<!-- stale-manager: warned -->' || return 1
}

# get_stale_label_ts <repo> <number> — returns ISO 8601 timestamp when stale label was last applied, or ""
get_stale_label_ts() {
  local repo="$1" number="$2"
  gh api "repos/$repo/issues/$number/events" \
    --paginate \
    --jq '[.[] | select(.event == "labeled" and .label.name == "stale")] | last | .created_at // empty' \
    2>/dev/null || echo ""
}

# generate_comment <item_type> <number> <title> <body> <url> <repo> <days> <action>
generate_comment() {
  local item_type="$1" number="$2" title="$3" body="$4" url="$5" \
        repo="$6" days="$7" action="$8"

  local prompt_template="$PROMPTS_DIR/aw/stale-manager.md"
  if [ ! -f "$prompt_template" ]; then
    echo "This ${item_type} has been inactive for ${days} days and will be closed in ${GRACE_DAYS} days if there is no activity. <!-- stale-manager: warned -->"
    return
  fi

  # Build a rendered prompt by substituting variables
  local rendered_prompt
  rendered_prompt=$(
    ITEM_TYPE="$item_type" \
    ITEM_NUMBER="$number" \
    ITEM_TITLE="$title" \
    ITEM_BODY="$(echo "$body" | head -c 2000)" \
    ITEM_URL="$url" \
    REPO="$repo" \
    DAYS_INACTIVE="$days" \
    ACTION="$action" \
    GRACE_DAYS="$GRACE_DAYS" \
    envsubst '${ITEM_TYPE},${ITEM_NUMBER},${ITEM_TITLE},${ITEM_BODY},${ITEM_URL},${REPO},${DAYS_INACTIVE},${ACTION},${GRACE_DAYS}' \
    < "$prompt_template"
  )

  local tmp_prompt
  tmp_prompt=$(mktemp --suffix=.md)
  printf '%s' "$rendered_prompt" > "$tmp_prompt"

  local comment
  case "$REVIEW_ENGINE" in
    claude)
      comment=$(timeout "$ACTION_TIMEOUT_SEC" claude --print \
        --model "$(ai_model_for_family sonnet)" \
        --disallowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch,WebSearch,Task,TodoWrite,NotebookEdit" \
        < "$tmp_prompt" 2>/dev/null) || comment=""
      ;;
    *)
      if [ "$action" = "close" ]; then
        comment="Closing this ${item_type} due to inactivity after the grace period. Feel free to re-open if it is still relevant. <!-- stale-manager: closed -->"
      else
        comment="This ${item_type} has been inactive for ${days} days and will be closed in ${GRACE_DAYS} days if there is no activity. <!-- stale-manager: warned -->"
      fi
      ;;
  esac

  rm -f "$tmp_prompt"

  if [ -z "$comment" ]; then
    # Fallback if Claude fails
    if [ "$action" = "warn" ]; then
      echo "This ${item_type} has been inactive for ${days} days and will be closed in ${GRACE_DAYS} days if there is no activity. <!-- stale-manager: warned -->"
    else
      echo "Closing this ${item_type} due to inactivity after the grace period. Feel free to re-open if it is still relevant. <!-- stale-manager: closed -->"
    fi
  else
    echo "$comment"
  fi
}

# apply_action <action> <repo> <item_type> <number> <title> <last_updated> <labels_json>
apply_action() {
  local action="$1" repo="$2" item_type="$3" number="$4" title="$5" \
        last_updated="$6" labels_json="$7"
  local days
  days=$(days_since "$last_updated")
  local url="https://github.com/$repo/issues/$number"

  SUMMARY_ROWS+=("| $repo | $item_type #$number | $days days | $action |")

  if [ "$DRY_RUN" = "true" ]; then
    log "DRY-RUN: $action $item_type #$number in $repo (inactive $days days)"
    ACTIONS_SKIPPED=$((ACTIONS_SKIPPED + 1))
    return
  fi

  case "$action" in
    warn)
      local comment
      comment=$(generate_comment "$item_type" "$number" "$title" "" "$url" "$repo" "$days" "warn")
      gh api "repos/$repo/issues/$number/labels" \
        --method POST \
        --field 'labels[]=stale' \
        --silent
      gh api "repos/$repo/issues/$number/comments" \
        --method POST \
        --raw-field "body=$comment" \
        --silent
      log "Warned $item_type #$number in $repo (inactive $days days)"
      ACTIONS_TAKEN=$((ACTIONS_TAKEN + 1))
      ;;

    close)
      local comment
      comment=$(generate_comment "$item_type" "$number" "$title" "" "$url" "$repo" "$days" "close")
      gh api "repos/$repo/issues/$number/comments" \
        --method POST \
        --raw-field "body=$comment" \
        --silent
      gh api "repos/$repo/issues/$number" \
        --method PATCH \
        --field "state=closed" \
        --field "state_reason=not_planned" \
        --silent
      log "Closed $item_type #$number in $repo (inactive $days days)"
      ACTIONS_TAKEN=$((ACTIONS_TAKEN + 1))
      ;;

    unstale)
      gh api "repos/$repo/issues/$number/labels/stale" \
        --method DELETE \
        --silent 2>/dev/null || true
      log "Removed stale label from $item_type #$number in $repo (activity detected)"
      ACTIONS_TAKEN=$((ACTIONS_TAKEN + 1))
      ;;
  esac
}

# process_item — evaluate a single issue or PR and determine the action
process_item() {
  local repo="$1" item_json="$2" item_type="$3"
  local number title last_updated labels_json
  # Extract fields in one call for efficiency
  IFS=$'\t' read -r number title last_updated labels_json < <(
    echo "$item_json" | jq -r '[.number, .title, .updated_at, (.labels|tojson)] | @tsv'
  )

  local stale_threshold
  if [ "$item_type" = "PR" ]; then
    stale_threshold="$STALE_DAYS_PR"
  else
    stale_threshold="$STALE_DAYS_ISSUE"
  fi

  # Skip exempt items
  if labels_include "$labels_json" "pinned" || labels_include "$labels_json" "no-stale"; then
    log "Skipping exempt $item_type #$number in $repo (pinned or no-stale)"
    SUMMARY_ROWS+=("| $repo | $item_type #$number | — | skip (exempt) |")
    return
  fi

  local has_stale_label=false
  if labels_include "$labels_json" "stale"; then
    has_stale_label=true
  fi

  local days_inactive
  days_inactive=$(days_since "$last_updated")

  if [ "$has_stale_label" = "true" ]; then
    local stale_ts
    stale_ts=$(get_stale_label_ts "$repo" "$number")

    if [ -n "$stale_ts" ]; then
      local last_updated_ts stale_label_ts days_stale
      last_updated_ts=$(iso_to_ts "$last_updated")
      stale_label_ts=$(iso_to_ts "$stale_ts")
      days_stale=$(( ( $(now_ts) - stale_label_ts ) / 86400 ))

      if [ "$last_updated_ts" -gt "$stale_label_ts" ]; then
        # Activity detected after stale label was applied — remove stale
        apply_action "unstale" "$repo" "$item_type" "$number" "$title" "$last_updated" "$labels_json"
      elif [ "$days_stale" -ge "$GRACE_DAYS" ]; then
        # Grace period elapsed since stale label was applied — close
        apply_action "close" "$repo" "$item_type" "$number" "$title" "$last_updated" "$labels_json"
      else
        log "Stale $item_type #$number in $repo still in grace period ($days_stale days since stale)"
        SUMMARY_ROWS+=("| $repo | $item_type #$number | $days_inactive days | grace period |")
      fi
    else
      # Stale label timestamp unavailable (transient API/event failure) — skip rather
      # than falling back to updated_at, which label actions refresh and would
      # incorrectly unstale recently-warned items on the very next run.
      log "Stale $item_type #$number in $repo: skipping — stale label timestamp unavailable"
      SUMMARY_ROWS+=("| $repo | $item_type #$number | $days_inactive days | stale (ts unavailable) |")
    fi
  else
    if [ "$days_inactive" -ge "$stale_threshold" ]; then
      # Past threshold — warn
      apply_action "warn" "$repo" "$item_type" "$number" "$title" "$last_updated" "$labels_json"
    else
      log "Active $item_type #$number in $repo ($days_inactive days)"
      SUMMARY_ROWS+=("| $repo | $item_type #$number | $days_inactive days | active |")
    fi
  fi
}

# process_repo — scan all open issues and PRs for a given repo
process_repo() {
  local repo="$1"
  log "Scanning $repo..."

  # Fetch open issues (excludes PRs via is:issue filter via separate call)
  local issues
  issues=$(gh api "repos/$repo/issues" \
    --method GET \
    -f state=open \
    -f per_page=100 \
    --paginate \
    --jq '.[] | select(.pull_request == null)' 2>/dev/null || echo "")

  while IFS= read -r issue; do
    [ -z "$issue" ] && continue
    process_item "$repo" "$issue" "issue"
  done < <(echo "$issues" | jq -c '.')

  # Fetch open PRs
  local prs
  prs=$(gh api "repos/$repo/pulls" \
    --method GET \
    -f state=open \
    -f per_page=100 \
    --paginate \
    --jq '.[]' 2>/dev/null || echo "")

  while IFS= read -r pr; do
    [ -z "$pr" ] && continue
    process_item "$repo" "$pr" "PR"
  done < <(echo "$prs" | jq -c '.')
}

# print_summary — write GitHub Actions step summary
print_summary() {
  if [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
    return
  fi
  {
    echo "## Stale Manager Run Summary"
    echo ""
    if [ "$DRY_RUN" = "true" ]; then
      echo "> **DRY-RUN mode** — no changes were made to GitHub"
      echo ""
    fi
    echo "| Repo | Item | Inactive | Action |"
    echo "|---|---|---|---|"
    for row in "${SUMMARY_ROWS[@]}"; do
      echo "$row"
    done
    echo ""
    echo "**Actions taken:** $ACTIONS_TAKEN | **Skipped (dry-run or exempt):** $ACTIONS_SKIPPED"
  } >> "$GITHUB_STEP_SUMMARY"
}

# ── Main ──────────────────────────────────────────────────────────────────────

log "Starting stale manager (org=$TARGET_ORG, dry_run=$DRY_RUN)"
log "Thresholds: issues>${STALE_DAYS_ISSUE}d, PRs>${STALE_DAYS_PR}d, grace=${GRACE_DAYS}d"

# List all non-archived repos in the org
repos=$(gh api "orgs/$TARGET_ORG/repos" \
  --method GET \
  -f per_page=100 \
  --paginate \
  --jq '.[] | select(.archived == false) | .full_name' 2>/dev/null || echo "")

if [ -z "$repos" ]; then
  warn "No repos found in org $TARGET_ORG — check GH_TOKEN scope"
  exit 0
fi

while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  process_repo "$repo" || warn "Error processing $repo — continuing"
done < <(echo "$repos")

print_summary

log "Done. Actions taken: $ACTIONS_TAKEN, skipped: $ACTIONS_SKIPPED"
