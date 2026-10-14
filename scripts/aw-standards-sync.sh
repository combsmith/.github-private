#!/usr/bin/env bash
# Standards Sync — checks all org repos for required files (AGENTS.md, CODEOWNERS)
# and opens PRs on non-compliant repos. Opens a summary issue in .github-private.
#
# Env vars consumed:
#   GH_TOKEN          — PAT with repo scope (create branches and PRs cross-repo)
#   ORG               — GitHub org to scan (default: petry-projects)
#   STANDARDS_REPO    — repo containing org standards templates (default: petry-projects/.github)
#   REPORT_REPO       — repo for summary issue (default: ORG/.github-private)
#   SYNC_LABEL        — label for opened PRs and summary issue (default: standards-sync)
#   SKIP_REPOS        — comma-separated list of repos to skip
#   GITHUB_ENV        — set by Actions runner

set -euo pipefail

# shellcheck source=scripts/lib/push-protection.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/push-protection.sh"

ORG="${ORG:-petry-projects}"
STANDARDS_REPO="${STANDARDS_REPO:-${ORG}/.github}"
REPORT_REPO="${REPORT_REPO:-${ORG}/.github-private}"
SYNC_LABEL="${SYNC_LABEL:-standards-sync}"
TODAY=$(date -u +%Y-%m-%d)
BRANCH_NAME="standards-sync/${TODAY}"

# Required files: format "local_path_in_repo|template_path_in_standards_repo"
REQUIRED_FILES=(
  "AGENTS.md|standards/AGENTS.md"
  ".github/CODEOWNERS|standards/CODEOWNERS"
)

# Required repository security settings derived from PP_REQUIRED_SA_SETTINGS in push-protection.sh.
# Format: "setting_label|jq_path|api_payload"
REQUIRED_SECURITY_SETTINGS=()
for _key in "${PP_REQUIRED_SA_SETTINGS[@]}"; do
  _payload=$(jq -n --arg k "$_key" '{"security_and_analysis": {($k): {"status": "enabled"}}}')
  REQUIRED_SECURITY_SETTINGS+=(
    "${_key}|.security_and_analysis.${_key}.status|${_payload}"
  )
done
unset _key _payload

echo "=== Standards Sync ==="
echo "  Org:            ${ORG}"
echo "  Standards repo: ${STANDARDS_REPO}"
echo "  Report repo:    ${REPORT_REPO}"
echo "  Date:           ${TODAY}"
echo ""

# ---------------------------------------------------------------------------
# 1. Build skip list
# ---------------------------------------------------------------------------
IFS=',' read -ra _SKIP_RAW <<< "${SKIP_REPOS:-}"
SKIP_LIST=()
for _r in "${_SKIP_RAW[@]+"${_SKIP_RAW[@]}"}"; do
  _r="${_r#"${_r%%[![:space:]]*}"}"
  _r="${_r%"${_r##*[![:space:]]}"}"
  [ -n "$_r" ] && SKIP_LIST+=("$_r")
done

_is_skipped() {
  local repo="$1"
  for skip in "${SKIP_LIST[@]+"${SKIP_LIST[@]}"}"; do
    [ "$repo" = "$skip" ] && return 0
    [ "${repo##*/}" = "$skip" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# 2. Enumerate active repos
# ---------------------------------------------------------------------------
echo "Enumerating repos in ${ORG}..."
repos=$(gh api "orgs/${ORG}/repos?per_page=100&type=all" \
  --jq '[.[] | select(.archived == false)] | .[].full_name' 2>/dev/null || true)

if [ -z "$repos" ]; then
  echo "::error::Could not enumerate repos for org ${ORG}."
  exit 1
fi

repo_count=$(echo "$repos" | wc -l | tr -d ' ')
echo "  Found ${repo_count} active repos."
echo ""

# ---------------------------------------------------------------------------
# 3. For each required file, fetch template content from standards repo
# ---------------------------------------------------------------------------
declare -A TEMPLATE_CONTENT
for entry in "${REQUIRED_FILES[@]}"; do
  _template="${entry#*|}"
  content=$(gh api "repos/${STANDARDS_REPO}/contents/${_template}" \
    --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [ -z "$content" ]; then
    echo "::warning::Template not found in ${STANDARDS_REPO}: ${_template} — skipping this requirement."
  fi
  TEMPLATE_CONTENT["$_template"]="$content"
done

# ---------------------------------------------------------------------------
# 4. Scan repos for compliance and open PRs
# ---------------------------------------------------------------------------
prs_opened=0
compliant_count=0
settings_applied=0

# Collect summary rows for the final issue
summary_rows=""

while IFS= read -r repo; do
  _is_skipped "$repo" && {
    echo "  [skip] ${repo}"
    continue
  }

  missing_files=()

  _repo_api_error=false
  for entry in "${REQUIRED_FILES[@]}"; do
    required_path="${entry%%|*}"
    _check_err=$(mktemp)
    # Check existence via contents API; 200 = exists, 404 = missing, other = API error
    if gh api "repos/${repo}/contents/${required_path}" --silent 2>"$_check_err"; then
      rm -f "$_check_err"
    elif grep -qiE 'HTTP 404|Not Found' "$_check_err" 2>/dev/null; then
      rm -f "$_check_err"
      missing_files+=("$entry")
    else
      echo "  [warn] ${repo}/${required_path} — API error (skipping repo): $(head -1 "$_check_err")"
      rm -f "$_check_err"
      _repo_api_error=true
      break
    fi
  done

  if [ "$_repo_api_error" = "true" ]; then
    summary_rows="${summary_rows}| \`${repo}\` | (skip) | (skip) | API error during compliance check |\n"
    continue
  fi

  # ── Security settings enforcement ──────────────────────────────────────────
  security_notes=""
  for setting_entry in "${REQUIRED_SECURITY_SETTINGS[@]}"; do
    setting_label="${setting_entry%%|*}"
    _rest="${setting_entry#*|}"
    jq_path="${_rest%%|*}"
    api_payload="${_rest#*|}"

    current_val=$(gh api "repos/${repo}" --jq "${jq_path} // \"null\"" 2>/dev/null || echo "error")

    if [ "$current_val" = "enabled" ]; then
      : # already enabled — nothing to do
    elif [ "$current_val" = "error" ]; then
      echo "  [warn] ${repo} — could not read ${setting_label}"
      security_notes="${security_notes} \`${setting_label}\`:error"
    else
      # dependabot_security_updates requires Dependabot alerts to be enabled first.
      if [ "$setting_label" = "dependabot_security_updates" ]; then
        gh api -X PUT "repos/${repo}/vulnerability-alerts" --silent 2>/dev/null || \
          echo "  [warn] ${repo} — could not enable vulnerability alerts (prerequisite for dependabot_security_updates)"
      fi
      if printf '%s' "$api_payload" | \
           gh api "repos/${repo}" --method PATCH --input - --silent 2>/dev/null; then
        settings_applied=$((settings_applied + 1))
        echo "  [fix]  ${repo} — enabled ${setting_label}"
        security_notes="${security_notes} \`${setting_label}\`:enabled"
      else
        echo "  [warn] ${repo} — could not enable ${setting_label} (may require Advanced Security)"
        security_notes="${security_notes} \`${setting_label}\`:error"
      fi
    fi
  done

  if [ "${#missing_files[@]}" -eq 0 ] && [ -z "$security_notes" ]; then
    compliant_count=$((compliant_count + 1))
    echo "  [ok]   ${repo}"
    summary_rows="${summary_rows}| \`${repo}\` | ✅ | ✅ | Compliant |\n"
    continue
  elif [ "${#missing_files[@]}" -eq 0 ]; then
    # Files compliant but security settings were applied/errored
    compliant_count=$((compliant_count + 1))
    echo "  [ok]   ${repo} (security settings updated)"
    summary_rows="${summary_rows}| \`${repo}\` | ✅ | ✅ | Security settings:${security_notes} |\n"
    continue
  fi

  # Check for existing open standards-sync PR
  existing_pr=$(gh pr list \
    --repo "$repo" \
    --label "$SYNC_LABEL" \
    --state open \
    --json number \
    --jq '.[0].number // ""' 2>/dev/null || true)

  if [ -n "$existing_pr" ]; then
    echo "  [skip] ${repo} — PR #${existing_pr} already open"
    summary_rows="${summary_rows}| \`${repo}\` | (see PR) | (see PR) | PR #${existing_pr} already open |\n"
    continue
  fi

  # Get default branch SHA for creating the branch
  default_branch=$(gh api "repos/${repo}" --jq '.default_branch' 2>/dev/null || echo "main")
  base_sha=$(gh api "repos/${repo}/git/ref/heads/${default_branch}" \
    --jq '.object.sha' 2>/dev/null || true)

  if [ -z "$base_sha" ]; then
    echo "  [warn] ${repo} — could not get SHA for ${default_branch}, skipping"
    continue
  fi

  # Create the sync branch; if it already exists (failed previous run) reuse it
  if ! gh api "repos/${repo}/git/refs" \
      --method POST \
      --field "ref=refs/heads/${BRANCH_NAME}" \
      --field "sha=${base_sha}" \
      --silent 2>/dev/null; then
    if ! gh api "repos/${repo}/git/ref/heads/${BRANCH_NAME}" --silent 2>/dev/null; then
      echo "  [warn] ${repo} — could not create branch ${BRANCH_NAME}, skipping"
      continue
    fi
    echo "  [info] ${repo} — branch ${BRANCH_NAME} already exists, reusing for PR creation"
  fi

  # Create each missing file via the Contents API
  missing_labels=""
  # Machine-readable manifest of the exact paths this PR intends to sync (#1700
  # AC1). Emitted into the PR body so the sync-scope guard can fail the PR if its
  # diff ever strays outside this set (the #1523 failure mode).
  declared_manifest=""
  for entry in "${missing_files[@]}"; do
    required_path="${entry%%|*}"
    template_key="${entry#*|}"
    file_content="${TEMPLATE_CONTENT[$template_key]:-}"

    if [ -z "$file_content" ]; then
      echo "  [warn] ${repo} — no template for ${required_path}, skipping file"
      continue
    fi

    encoded=$(printf '%s' "$file_content" | base64 -w 0)
    gh api "repos/${repo}/contents/${required_path}" \
      --method PUT \
      --field "message=chore: add ${required_path} (standards-sync)" \
      --field "content=${encoded}" \
      --field "branch=${BRANCH_NAME}" \
      --silent 2>/dev/null || \
      echo "  [warn] ${repo} — could not create ${required_path}"

    missing_labels="${missing_labels} \`${required_path}\`"
    declared_manifest="${declared_manifest}${required_path}"$'\n'
  done

  # HTML-comment block: invisible in the rendered PR, machine-readable for the
  # scope guard (scripts/lib/sync-scope-check.sh recognises this exact marker).
  declared_block=$(printf '<!-- standards-sync:declared-paths\n%s-->' "$declared_manifest")

  # Open PR
  pr_url=$(gh pr create \
    --repo "$repo" \
    --head "$BRANCH_NAME" \
    --base "$default_branch" \
    --title "chore: add missing org standard files (standards-sync)" \
    --body "$(printf 'This PR adds files required by the \`petry-projects\` org standards.\n\n**Missing files added:**%s\n\n%s\n\nOpened by the [standards-sync](%s) workflow.\n' "$missing_labels" "$declared_block" "https://github.com/${REPORT_REPO}/actions")" \
    --label "$SYNC_LABEL" \
    2>/dev/null || true)

  if [ -n "$pr_url" ]; then
    prs_opened=$((prs_opened + 1))
    echo "  [pr]   ${repo} — opened ${pr_url}"
    # Make the PR auto-rebase-eligible from creation (petry-projects/.github#711):
    # without the ready label an unapproved PR is skipped by auto-rebase, drifts
    # into conflict, and cannot be approved (pr-review skips red PRs) — a deadlock.
    # Ensure the label exists (idempotent) so a repo missing it does not break.
    gh label create "auto-rebase:ready" --repo "$repo" \
      --description "Opts a non-draft PR into auto-rebase without an approval (auto-rebase ready_label)" \
      --color "0e8a16" --force >/dev/null 2>&1 || true
    gh pr edit "$pr_url" --repo "$repo" --add-label "auto-rebase:ready" >/dev/null 2>&1 || true
    summary_rows="${summary_rows}| \`${repo}\` | ❌ | ❌ | PR opened: ${pr_url} |\n"
  else
    echo "  [warn] ${repo} — could not open PR"
    summary_rows="${summary_rows}| \`${repo}\` | ❌ | ❌ | PR creation failed |\n"
  fi
done <<< "$repos"

# ---------------------------------------------------------------------------
# 5. Open summary issue in report repo
# ---------------------------------------------------------------------------
total_scanned=$(echo "$repos" | wc -l | tr -d ' ')

summary_body="$(printf '## Standards Sync — %s\n\n| Repo | AGENTS.md | CODEOWNERS | Action |\n|------|-----------|------------|--------|\n%b\n**Total:** %d repos scanned · %d compliant · %d PRs opened · %d security settings applied\n\n---\n_Generated by standards-sync workflow on %s._\n' \
  "$TODAY" "$summary_rows" "$total_scanned" "$compliant_count" "$prs_opened" "$settings_applied" "$TODAY")"

echo ""
# The summary issue embeds the date in its title, so a fresh one is created each
# run with no close path. Close prior open standards-sync summaries before opening
# today's so only the current snapshot stays open.
gh issue list --repo "${REPORT_REPO}" --label "${SYNC_LABEL}" --state open \
  --search "Standards Sync — in:title" --limit 200 \
  --json number,title \
  -q '.[] | select(.title | startswith("Standards Sync — ")) | .number' 2>/dev/null \
| while read -r prev; do
    [ -n "$prev" ] || continue
    gh issue close "$prev" --repo "${REPORT_REPO}" \
      --comment "Superseded by the newer standards-sync summary." >/dev/null 2>&1 || true
  done || true

echo "Opening summary issue in ${REPORT_REPO}..."
gh api "repos/${REPORT_REPO}/issues" \
  --method POST \
  --field "title=Standards Sync — ${TODAY}" \
  --field "body=${summary_body}" \
  --field "labels[]=${SYNC_LABEL}" \
  --field "labels[]=automated-report" \
  --silent
echo "  Summary issue created."

echo ""
echo "=== Standards sync complete: ${total_scanned} scanned, ${compliant_count} compliant, ${prs_opened} PRs opened, ${settings_applied} security settings applied ==="
