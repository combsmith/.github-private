#!/usr/bin/env bash
# Dependency Advisory — analyses dependency manifest changes in a PR and posts
# a risk-assessment comment via Claude.
#
# Env vars consumed:
#   GH_TOKEN                  — token for gh CLI (PR comment + diff)
#   CLAUDE_CODE_OAUTH_TOKEN   — Claude auth token
#   PR_NUMBER                 — pull request number
#   REPO                      — owner/repo (e.g. combsmith/my-repo)
#   SKIP_BOT_PRS              — "true" to skip Dependabot/Renovate PRs (default: true)
#   GITHUB_ENV                — set by Actions runner

set -euo pipefail

PR_NUMBER="${PR_NUMBER:?PR_NUMBER is required}"
REPO="${REPO:?REPO is required}"
SKIP_BOT_PRS="${SKIP_BOT_PRS:-true}"
BOT_AUTHORS="${BOT_AUTHORS:-dependabot[bot],renovate[bot]}"
COMMENT_MARKER="<!-- dependency-advisory -->"

echo "=== Dependency Advisory ==="
echo "  Repo:       ${REPO}"
echo "  PR:         #${PR_NUMBER}"
echo ""

# ---------------------------------------------------------------------------
# 1. Get PR metadata
# ---------------------------------------------------------------------------
pr_json=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" \
  --jq '{author: .user.login, title: .title, base: .base.ref, head: .head.ref}')

pr_author=$(echo "$pr_json" | jq -r '.author')
echo "  Author:     ${pr_author}"

# Skip bot PRs if configured
if [ "$SKIP_BOT_PRS" = "true" ]; then
  IFS=',' read -ra _bot_list <<< "$BOT_AUTHORS"
  for bot in "${_bot_list[@]}"; do
    bot="${bot#"${bot%%[![:space:]]*}"}"
    bot="${bot%"${bot##*[![:space:]]}"}"
    if [ "$pr_author" = "$bot" ]; then
      echo "::notice::Skipping bot PR by ${pr_author} (SKIP_BOT_PRS=true)"
      exit 0
    fi
  done
fi

# ---------------------------------------------------------------------------
# 2. Check for existing advisory comment (dedup)
# ---------------------------------------------------------------------------
existing_comment_id=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
  --paginate \
  --jq "[.[] | select(.body | startswith(\"${COMMENT_MARKER}\"))] | .[0].id // \"\"" \
  2>/dev/null || true)

# ---------------------------------------------------------------------------
# 3. Get diff for dependency files only
# ---------------------------------------------------------------------------
_diff_tmp=$(mktemp)
if ! gh pr diff "$PR_NUMBER" --repo "$REPO" > "$_diff_tmp"; then
  rm -f "$_diff_tmp"
  echo "::error::Failed to retrieve diff for PR #${PR_NUMBER} in ${REPO}."
  exit 1
fi
dep_diff=$(awk '
  /^diff --git/ {
    in_dep = ($0 ~ /package\.json|package-lock\.json|yarn\.lock|go\.mod|go\.sum|requirements\.txt|Pipfile|Gemfile|Cargo\.toml|pyproject\.toml|pom\.xml|build\.gradle/)
    if (in_dep) print
    next
  }
  in_dep { print }
' "$_diff_tmp")
rm -f "$_diff_tmp"

if [ -z "$dep_diff" ]; then
  echo "::notice::No dependency file changes found in diff — skipping advisory."
  exit 0
fi

diff_lines=$(echo "$dep_diff" | wc -l | tr -d ' ')
echo "  Dep diff:   ${diff_lines} lines"

# ---------------------------------------------------------------------------
# 4. Invoke Claude for risk assessment
# ---------------------------------------------------------------------------
ADVISORY_FILE=$(mktemp)
trap 'rm -f "$ADVISORY_FILE"' EXIT

# Skip Claude invocation when fork PR secrets are unavailable (GitHub does not
# pass repository secrets to fork PRs, so CLAUDE_CODE_OAUTH_TOKEN will be unset).
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "::notice::CLAUDE_CODE_OAUTH_TOKEN not available (fork PR) — skipping dependency advisory."
  echo "=== Dependency advisory complete (skipped — no Claude token) ==="
  exit 0
fi

echo "Invoking Claude for dependency risk assessment..."
if ! claude --print --model claude-sonnet-4-6 --no-session-persistence \
     > "$ADVISORY_FILE" <<PROMPT
You are reviewing dependency changes in a pull request for security and stability risk.

## Context
- Repo: \`${REPO}\`
- PR: #${PR_NUMBER}
- Author: ${pr_author}

## Dependency Diff
\`\`\`diff
${dep_diff}
\`\`\`

---

Produce a dependency advisory comment in markdown. Structure:

${COMMENT_MARKER}
## Dependency Advisory

| Package | Change | Ecosystem | Risk | Notes |
|---------|--------|-----------|------|-------|
| <name> | <old → new or "added" or "removed"> | npm/go/pip/etc | LOW/MEDIUM/HIGH/CRITICAL | <one-line note> |

### Risk Legend
- **LOW** — Patch/minor bump, lockfile regeneration, well-maintained package
- **MEDIUM** — Minor bump with new APIs, new direct dependency, deprecation notice
- **HIGH** — Major version bump, package with recent CVE, unusual transitive deps
- **CRITICAL** — Active CVE, known supply-chain risk, abandoned package

### Details
<For each MEDIUM/HIGH/CRITICAL item: what changed, why it is risky, and what the reviewer should check.>

<If all changes are LOW risk, write: "All dependency changes appear low-risk. No action required.">

Output ONLY the comment body — no preamble outside the markdown.
PROMPT
then
  echo "::error::Claude invocation failed. CLI output:"
  cat "$ADVISORY_FILE" >&2
  exit 1
fi

advisory_body=$(cat "$ADVISORY_FILE")

# ---------------------------------------------------------------------------
# 5. Post or update PR comment
# ---------------------------------------------------------------------------
# Skip comment writes when the token cannot create PR/issue comments.
# Commenting needs triage-level access or higher — do not require push.
if ! gh api "repos/${REPO}" --jq '(.permissions.triage // false) or (.permissions.push // false)' 2>/dev/null | grep -q "^true$"; then
  echo "::notice::Token lacks comment access to ${REPO} — skipping advisory comment (read-only context)."
  echo "=== Dependency advisory complete (comment skipped — no write access) ==="
  exit 0
fi

if [ -n "$existing_comment_id" ]; then
  echo "Updating existing advisory comment #${existing_comment_id}..."
  gh api "repos/${REPO}/issues/comments/${existing_comment_id}" \
    --method PATCH \
    --field "body=${advisory_body}" \
    --silent
else
  echo "Posting new advisory comment on PR #${PR_NUMBER}..."
  gh pr comment "$PR_NUMBER" \
    --repo "$REPO" \
    --body "$advisory_body"
fi

echo "=== Dependency advisory complete ==="
