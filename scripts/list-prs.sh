#!/usr/bin/env bash
# Enumerate open, non-draft PRs the agent should consider reviewing.
#
# Searches across:
#   1. All open PRs in repos owned by $BOT_USER (the bot's personal account)
#   2. All open PRs in repos owned by $TARGET_ORG (organization)
#   3. All open PRs in additional orgs listed in $DELEGATION_ORGS
#
# Filters:
#   --draft=false       — skip work-in-progress PRs
#
# CI filtering is intentionally omitted here — review-one-pr.sh enforces it
# per-PR as a second layer. Filtering by --checks success would exclude repos
# with no CI configured (GitHub treats "no checks" as not matching --checks
# success), causing their PRs to never enter the candidate pool.
#
# Self-authored PRs (PRs whose author is $BOT_USER) are excluded here, because
# GitHub's GraphQL API rejects self-approval unconditionally — including such a
# PR in the queue previously triggered a fatal session abort that starved every
# subsequent candidate (see issue #96).
#
# Output ordering (stable, deterministic):
#   1. .github and .github-private PRs first (priority 0)
#   2. All other repos (priority 1)
#   Within each priority tier, PRs are sorted oldest-first by createdAt.
#
# Filters:
#   --draft=false       — skip work-in-progress PRs
#
# CI filtering is intentionally omitted here — review-one-pr.sh enforces it
# per-PR as a second layer. Filtering by --checks success would exclude repos
# with no CI configured (GitHub treats "no checks" as not matching --checks
# success), causing their PRs to never enter the candidate pool.
#
# Self-authored PRs (PRs whose author is $BOT_USER) are excluded here, because
# GitHub's GraphQL API rejects self-approval unconditionally — including such a
# PR in the queue previously triggered a fatal session abort that starved every
# subsequent candidate (see issue #96).
#
# Output ordering (stable, deterministic):
#   1. .github and .github-private PRs first (priority 0)
#   2. All other repos (priority 1)
#   Within each priority tier, PRs are sorted oldest-first by createdAt.
#
# Output: one PR URL per line on stdout.

set -euo pipefail

# Configurable via environment / repo variables. BOT_USER is the GitHub
# identity the workflow PAT authenticates as — both the queue scope (which
# repos to scan) and the self-approval filter use it.
BOT_USER="${BOT_USER:-donpetry-bot}"
TARGET_ORG="${TARGET_ORG:-combsmith}"
DELEGATION_ORGS="${DELEGATION_ORGS:-}"

# Reject BOT_USER values that aren't valid GitHub usernames before
# interpolating into a jq program. GitHub usernames are 1–39 chars of
# [A-Za-z0-9-] and may not start or end with a hyphen. Anything else is
# either a misconfiguration or an injection attempt — fail loud rather
# than silently dropping PRs.
if ! [[ "$BOT_USER" =~ ^[A-Za-z0-9](-?[A-Za-z0-9]){0,38}$ ]]; then
  echo "::error::BOT_USER='$BOT_USER' is not a valid GitHub username" >&2
  exit 1
fi

all_entries=""

# JQ filter: emit  <priority>|<createdAt>|<url>  for non-bot-authored PRs.
#   Priority 0 — .github / .github-private repos (infra PRs reviewed first)
#   Priority 1 — all other repos
# ISO-8601 createdAt sorts lexicographically, so oldest-first within each
# tier is achieved with a plain string sort on field 2.
JQ_WITH_SORT=".[] | select(.author.login != \"$BOT_USER\") |
  (if (.url | test(\"/[.]github(-private)?/pull/\")) then \"0\" else \"1\" end)
    + \"|\" + .createdAt + \"|\" + .url"

# Search all open, non-draft PRs across every repo owned by $owner.
# --limit 200 on repo list handles orgs that grow beyond gh's default 30.
search_namespace() {
  local owner="$1"
  while IFS= read -r repo; do
    entries=$(gh search prs \
      --state open \
      --repo "$repo" \
      --draft=false \
      --limit 100 \
      --json url,author,createdAt \
      --jq "$JQ_WITH_SORT" 2>/dev/null || true)
    all_entries="${all_entries}${entries}"$'\n'
  done < <(gh repo list "$owner" --limit 200 --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true)
}

# Bot's personal account
search_namespace "$BOT_USER"

# Primary org
search_namespace "$TARGET_ORG"

# Additional orgs from DELEGATION_ORGS (skip TARGET_ORG and BOT_USER — already covered above)
if [ -n "$DELEGATION_ORGS" ]; then
  IFS=',' read -ra _ORGS <<< "$DELEGATION_ORGS"
  for _org in "${_ORGS[@]}"; do
    if [ "$_org" != "$TARGET_ORG" ] && [ "$_org" != "$BOT_USER" ]; then
      search_namespace "$_org"
    fi
  done
fi

# 1. Drop blank lines
# 2. Deduplicate by URL (field 3) keeping first occurrence
# 3. Sort: priority (field 1) ascending, then createdAt (field 2) ascending
# 4. Strip the sort keys — output only the URL
grep -v '^$' <<< "$all_entries" \
  | sort -t'|' -k3 -u \
  | sort -t'|' -k1,1n -k2,2 \
  | cut -d'|' -f3- \
  || true