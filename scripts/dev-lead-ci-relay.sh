#!/usr/bin/env bash
set -euo pipefail
# dev-lead-ci-relay.sh — Resolves the PR associated with a check_run and writes
# relay decision to GITHUB_OUTPUT.
#
# Env inputs:
#   CHECK_RUN_PRS      — JSON array from check_run.pull_requests (may be [])
#   CHECK_RUN_HEAD_SHA — commit SHA from the check_run event
#   REPO_FULL_NAME     — "owner/repo" string
#   GITHUB_OUTPUT      — path to the GitHub Actions output file (or /dev/null)
#
# Writes to GITHUB_OUTPUT:
#   should_relay=true|false
#   pr_number=N  (only when should_relay=true)

GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
CHECK_RUN_PRS="${CHECK_RUN_PRS:-[]}"
CHECK_RUN_HEAD_SHA="${CHECK_RUN_HEAD_SHA:-}"
REPO_FULL_NAME="${REPO_FULL_NAME:-}"

pr_count=$(echo "$CHECK_RUN_PRS" | jq 'length')

if [ "$pr_count" -eq 0 ]; then
  # GitHub App check_runs (SonarCloud, external CodeQL gates, etc.) do not
  # populate check_run.pull_requests. Fall back to the commits-to-pulls API.
  echo "::notice::check_run.pull_requests is empty — trying commits-to-pulls API fallback for SHA ${CHECK_RUN_HEAD_SHA}"
  pulls_json=$(gh api \
    -H "Accept: application/vnd.github+json" \
    "repos/${REPO_FULL_NAME}/commits/${CHECK_RUN_HEAD_SHA}/pulls" 2>/dev/null || echo "[]")
  # Filter to open PRs only — merged PRs can share the same commit SHA.
  open_pulls=$(echo "$pulls_json" | jq '[.[] | select(.state=="open")]')
  pr_count=$(echo "$open_pulls" | jq 'length')
  if [ "$pr_count" -eq 0 ]; then
    echo "::notice::No open PRs found for commit ${CHECK_RUN_HEAD_SHA} — skipping relay"
    echo "should_relay=false" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  head_repo_full=$(echo "$open_pulls" | jq -r '.[0].head.repo.full_name // empty')
  if [[ -n "$head_repo_full" ]] && [[ "$head_repo_full" != "$REPO_FULL_NAME" ]]; then
    echo "::notice::Commit ${CHECK_RUN_HEAD_SHA} belongs to fork (${head_repo_full}) — skipping relay"
    echo "should_relay=false" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  pr_number=$(echo "$open_pulls" | jq -r '.[0].number')
  echo "should_relay=true" >> "$GITHUB_OUTPUT"
  echo "pr_number=$pr_number" >> "$GITHUB_OUTPUT"
  exit 0
fi

# check_run.pull_requests is populated (GitHub Actions check_run).
# Fork check: pull_requests[*].head.repo only has id/url/name (not full_name),
# so compare the API URL against the expected base URL for this repo.
head_repo_url=$(echo "$CHECK_RUN_PRS" | jq -r '.[0].head.repo.url // empty')
expected_url="https://api.github.com/repos/${REPO_FULL_NAME}"
if [[ -n "$head_repo_url" ]] && [[ "$head_repo_url" != "$expected_url" ]]; then
  echo "::notice::check_run PR head repo URL ($head_repo_url) does not match expected ($expected_url) — fork, skipping relay"
  echo "should_relay=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
pr_number=$(echo "$CHECK_RUN_PRS" | jq -r '.[0].number')
echo "should_relay=true" >> "$GITHUB_OUTPUT"
echo "pr_number=$pr_number" >> "$GITHUB_OUTPUT"
