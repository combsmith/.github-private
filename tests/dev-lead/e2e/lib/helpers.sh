#!/usr/bin/env bash
# tests/dev-lead/e2e/lib/helpers.sh — Shared helpers for dev-lead E2E tests.
# Sourced by each scenario script.
set -euo pipefail

# ── configuration ─────────────────────────────────────────────────────────────

E2E_TARGET_REPO="${E2E_TARGET_REPO:-petry-projects/.github-private}"
E2E_CLEANUP="${E2E_CLEANUP:-true}"
E2E_RESULTS_DIR="${E2E_RESULTS_DIR:-$(dirname "${BASH_SOURCE[0]}")/../results}"

# Resolve token: prefer GH_TOKEN, fall back to GH_PAT
GH_TOKEN="${GH_TOKEN:-${GH_PAT:-}}"
if [ -z "$GH_TOKEN" ]; then
  echo "[helpers] WARNING: neither GH_TOKEN nor GH_PAT is set — API calls will fail" >&2
fi
export GH_TOKEN

# ── logging ───────────────────────────────────────────────────────────────────

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
info() { echo "[$(date -u +%H:%M:%S)] INFO  $*"; }
warn() { echo "[$(date -u +%H:%M:%S)] WARN  $*" >&2; }
err()  { echo "[$(date -u +%H:%M:%S)] ERROR $*" >&2; }

# ── create_test_branch <name> ─────────────────────────────────────────────────
# Creates a branch from main with a unique timestamp suffix.
# Prints the full branch name to stdout.
create_test_branch() {
  local base_name="${1:-e2e-test}"
  local ts
  ts=$(date -u +%Y%m%d-%H%M%S)
  local branch_name="${base_name}-${ts}"
  info "Creating branch: ${branch_name} from main on ${E2E_TARGET_REPO}"

  # Get the SHA of main
  local main_sha
  main_sha=$(gh api "repos/${E2E_TARGET_REPO}/git/ref/heads/main" \
    --jq '.object.sha' 2>/dev/null)

  if [ -z "$main_sha" ]; then
    err "Failed to resolve main SHA on ${E2E_TARGET_REPO}"
    return 1
  fi

  gh api "repos/${E2E_TARGET_REPO}/git/refs" \
    --method POST \
    --field "ref=refs/heads/${branch_name}" \
    --field "sha=${main_sha}" \
    --silent

  echo "${branch_name}"
}

# ── create_test_pr <branch> <title> [body] ────────────────────────────────────
# Opens a PR from <branch> → main and prints the PR number to stdout.
create_test_pr() {
  local branch="${1:?branch required}"
  local title="${2:?title required}"
  local body="${3:-E2E test PR — safe to close}"

  info "Creating PR: '${title}' (${branch} → main) on ${E2E_TARGET_REPO}"

  local pr_number
  pr_number=$(gh pr create \
    --repo "${E2E_TARGET_REPO}" \
    --head "${branch}" \
    --base "main" \
    --title "${title}" \
    --body "${body}" \
    2>&1 | grep -oE '[0-9]+$' | head -1)

  if [ -z "$pr_number" ]; then
    err "Failed to create PR for branch ${branch}"
    return 1
  fi

  info "Created PR #${pr_number}"
  echo "${pr_number}"
}

# ── wait_for_workflow <repo> <workflow_name> <head_sha> <timeout_sec> ─────────
# Polls GitHub every 15 s until a workflow run matching the workflow name and
# head SHA completes, then prints the conclusion to stdout.
# Returns 1 if timed out.
wait_for_workflow() {
  local repo="${1:?repo required}"
  local workflow_name="${2:?workflow_name required}"
  local head_sha="${3:?head_sha required}"
  local timeout_sec="${4:-300}"

  local deadline=$(( $(date +%s) + timeout_sec ))
  local poll_interval=15

  info "Waiting for workflow '${workflow_name}' on SHA ${head_sha:0:8}... (timeout: ${timeout_sec}s)"

  while [ "$(date +%s)" -lt "$deadline" ]; do
    local run_data
    run_data=$(gh api \
      "repos/${repo}/actions/runs?head_sha=${head_sha}&per_page=20" \
      --jq ".workflow_runs[] | select(.name == \"${workflow_name}\")" \
      2>/dev/null || true)

    if [ -n "$run_data" ]; then
      local status conclusion
      status=$(echo "$run_data" | jq -r '.status' 2>/dev/null | head -1)
      conclusion=$(echo "$run_data" | jq -r '.conclusion // ""' 2>/dev/null | head -1)

      if [ "$status" = "completed" ] && [ -n "$conclusion" ]; then
        info "Workflow '${workflow_name}' completed: conclusion=${conclusion}"
        echo "${conclusion}"
        return 0
      fi
      info "  status=${status} conclusion=${conclusion} — still running..."
    else
      info "  no runs yet for '${workflow_name}' on ${head_sha:0:8}..."
    fi

    sleep "$poll_interval"
  done

  err "Timed out after ${timeout_sec}s waiting for workflow '${workflow_name}'"
  echo "timeout"
  return 1
}

# ── wait_for_workflow_by_event <repo> <workflow_name> <event> <timeout_sec> ───
# Polls until the most recent workflow run triggered by <event> completes.
# Used for events like repository_dispatch or issues where we don't have a SHA.
wait_for_workflow_by_event() {
  local repo="${1:?repo required}"
  local workflow_name="${2:?workflow_name required}"
  local event="${3:?event required}"
  local timeout_sec="${4:-300}"
  local created_after="${5:-}"   # ISO8601 string; filters to runs created after this time

  local deadline=$(( $(date +%s) + timeout_sec ))
  local poll_interval=15

  info "Waiting for workflow '${workflow_name}' triggered by '${event}'... (timeout: ${timeout_sec}s)"

  while [ "$(date +%s)" -lt "$deadline" ]; do
    local runs_json
    runs_json=$(gh api \
      "repos/${repo}/actions/runs?event=${event}&per_page=10" \
      2>/dev/null || echo '{"workflow_runs":[]}')

    local run_data
    run_data=$(echo "$runs_json" | jq -r \
      ".workflow_runs[] | select(.name == \"${workflow_name}\")" \
      2>/dev/null | head -c 4096 || true)

    if [ -n "$run_data" ]; then
      # If created_after filter, select only runs newer than it
      if [ -n "$created_after" ]; then
        run_data=$(echo "$runs_json" | jq -r \
          ".workflow_runs[] | select(.name == \"${workflow_name}\" and .created_at > \"${created_after}\")" \
          2>/dev/null | head -c 4096 || true)
      fi
    fi

    if [ -n "$run_data" ]; then
      local status conclusion
      status=$(echo "$run_data" | jq -rs '.[0].status // ""')
      conclusion=$(echo "$run_data" | jq -rs '.[0].conclusion // ""')

      if [ "$status" = "completed" ] && [ -n "$conclusion" ] && [ "$conclusion" != "null" ]; then
        info "Workflow '${workflow_name}' completed: conclusion=${conclusion}"
        echo "${conclusion}"
        return 0
      fi
      info "  status=${status} conclusion=${conclusion} — still running..."
    else
      info "  no matching runs yet for '${workflow_name}'..."
    fi

    sleep "$poll_interval"
  done

  err "Timed out after ${timeout_sec}s waiting for workflow '${workflow_name}'"
  echo "timeout"
  return 1
}

# ── wait_for_comment <repo> <pr_number> <pattern> <timeout_sec> ───────────────
# Polls until a PR comment matching the grep pattern appears.
# Prints the matching comment body to stdout.
# Returns 1 if timed out.
wait_for_comment() {
  local repo="${1:?repo required}"
  local pr_number="${2:?pr_number required}"
  local pattern="${3:?pattern required}"
  local timeout_sec="${4:-300}"

  local deadline=$(( $(date +%s) + timeout_sec ))
  local poll_interval=15

  info "Waiting for comment matching '${pattern}' on PR #${pr_number}... (timeout: ${timeout_sec}s)"

  while [ "$(date +%s)" -lt "$deadline" ]; do
    local match
    match=$(gh api "repos/${repo}/issues/${pr_number}/comments" \
      --jq '.[].body' 2>/dev/null \
      | grep -F "$pattern" | head -1 || true)

    if [ -n "$match" ]; then
      info "Found comment matching '${pattern}'"
      echo "$match"
      return 0
    fi

    info "  no matching comment yet..."
    sleep "$poll_interval"
  done

  err "Timed out after ${timeout_sec}s waiting for comment '${pattern}' on PR #${pr_number}"
  return 1
}

# ── cleanup_branch <branch> ───────────────────────────────────────────────────
# Deletes the branch from the remote, even if a PR is still open.
cleanup_branch() {
  local branch="${1:?branch required}"
  if [ "${E2E_CLEANUP}" != "true" ]; then
    warn "E2E_CLEANUP=false — skipping deletion of branch ${branch}"
    return 0
  fi
  info "Cleaning up branch: ${branch}"
  gh api "repos/${E2E_TARGET_REPO}/git/refs/heads/${branch}" \
    --method DELETE 2>/dev/null || warn "Could not delete branch ${branch} (may already be gone)"
}

# ── cleanup_pr <pr_number> ────────────────────────────────────────────────────
# Closes a PR without merging.
cleanup_pr() {
  local pr_number="${1:?pr_number required}"
  if [ "${E2E_CLEANUP}" != "true" ]; then
    warn "E2E_CLEANUP=false — skipping closure of PR #${pr_number}"
    return 0
  fi
  info "Closing PR #${pr_number}"
  gh pr close "${pr_number}" --repo "${E2E_TARGET_REPO}" 2>/dev/null || \
    warn "Could not close PR #${pr_number} (may already be closed)"
}

# ── cleanup_issue <issue_number> ──────────────────────────────────────────────
# Closes an issue.
cleanup_issue() {
  local issue_number="${1:?issue_number required}"
  if [ "${E2E_CLEANUP}" != "true" ]; then
    warn "E2E_CLEANUP=false — skipping closure of issue #${issue_number}"
    return 0
  fi
  info "Closing issue #${issue_number}"
  gh issue close "${issue_number}" --repo "${E2E_TARGET_REPO}" 2>/dev/null || \
    warn "Could not close issue #${issue_number} (may already be closed)"
}

# ── assert_conclusion <actual> <expected> <scenario> ─────────────────────────
# Prints PASS or FAIL and returns appropriate exit code.
assert_conclusion() {
  local actual="${1:-}"
  local expected="${2:?expected required}"
  local scenario="${3:?scenario required}"

  if [ "$actual" = "$expected" ]; then
    echo "[PASS] ${scenario}: conclusion=${actual}"
    return 0
  else
    echo "[FAIL] ${scenario}: expected conclusion=${expected}, got conclusion=${actual}"
    return 1
  fi
}

# ── assert_eq <actual> <expected> <label> ────────────────────────────────────
# Generic equality assertion.
assert_eq() {
  local actual="${1:-}"
  local expected="${2:-}"
  local label="${3:-assert_eq}"

  if [ "$actual" = "$expected" ]; then
    echo "[PASS] ${label}: '${actual}' == '${expected}'"
    return 0
  else
    echo "[FAIL] ${label}: expected '${expected}', got '${actual}'"
    return 1
  fi
}

# ── assert_contains <string> <substring> <label> ────────────────────────────
# Asserts that <string> contains <substring>.
assert_contains() {
  local string="${1:-}"
  local substring="${2:?substring required}"
  local label="${3:-assert_contains}"

  if echo "$string" | grep -qF "$substring"; then
    echo "[PASS] ${label}: output contains '${substring}'"
    return 0
  else
    echo "[FAIL] ${label}: output does not contain '${substring}'"
    echo "       actual: ${string}"
    return 1
  fi
}

# ── get_head_sha <repo> <branch> ─────────────────────────────────────────────
# Returns the current HEAD SHA of <branch>.
get_head_sha() {
  local repo="${1:?repo required}"
  local branch="${2:?branch required}"
  gh api "repos/${repo}/git/ref/heads/${branch}" \
    --jq '.object.sha' 2>/dev/null
}

# ── push_file_to_branch <branch> <file_path> <content> <commit_msg> ──────────
# Commits a single file to an existing branch via the GitHub Contents API.
# content should be base64-encoded.
push_file_to_branch() {
  local branch="${1:?branch required}"
  local file_path="${2:?file_path required}"
  local content_b64="${3:?content required}"
  local commit_msg="${4:-e2e test commit}"

  local current_sha
  current_sha=$(get_head_sha "${E2E_TARGET_REPO}" "${branch}")

  # Check if file already exists (needed for SHA to update)
  local existing_sha=""
  existing_sha=$(gh api "repos/${E2E_TARGET_REPO}/contents/${file_path}?ref=${branch}" \
    --jq '.sha' 2>/dev/null || true)

  local payload
  if [ -n "$existing_sha" ]; then
    payload=$(jq -n \
      --arg message "$commit_msg" \
      --arg content "$content_b64" \
      --arg branch "$branch" \
      --arg sha "$existing_sha" \
      '{message:$message, content:$content, branch:$branch, sha:$sha}')
  else
    payload=$(jq -n \
      --arg message "$commit_msg" \
      --arg content "$content_b64" \
      --arg branch "$branch" \
      '{message:$message, content:$content, branch:$branch}')
  fi

  echo "$payload" | gh api "repos/${E2E_TARGET_REPO}/contents/${file_path}" \
    --method PUT \
    --input - \
    --silent

  # Return the new HEAD SHA
  get_head_sha "${E2E_TARGET_REPO}" "${branch}"
}

# ── record_result <scenario_name> <status> <details> ─────────────────────────
# Writes a result line to the results directory.
record_result() {
  local scenario="${1:?scenario required}"
  local status="${2:?status required}"   # PASS or FAIL
  local details="${3:-}"

  mkdir -p "${E2E_RESULTS_DIR}"
  local result_file="${E2E_RESULTS_DIR}/results.txt"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "${ts} [${status}] ${scenario}: ${details}" >> "${result_file}"
}

# ── now_iso ───────────────────────────────────────────────────────────────────
# Prints current UTC time in ISO8601 format suitable for GitHub API filtering.
now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}
