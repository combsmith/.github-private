#!/usr/bin/env bash
# Enumerate open, non-draft PRs the agent should consider reviewing.
#
# Searches across:
#   1. All open PRs in repos owned by $BOT_USER (the bot's personal account)
#   2. All open PRs in repos owned by $TARGET_ORG (organization)
#   3. All open PRs in additional orgs listed in $DELEGATION_ORGS
#
# Enumeration source — the List API, not the Search API (issue #1744):
#   PRs are listed per-repo with `gh pr list`, which reads the strongly-
#   consistent pull-request endpoint. The prior implementation used
#   `gh search prs` — the *eventually consistent* Search API — which silently
#   omitted a PR (#1710) that had just been pushed (its approval dismissed): the
#   Search index had not yet re-indexed the mutation, so the PR was absent from
#   results even though it was open, green, and owed a review. The List API has
#   no such re-index lag, so a just-mutated PR enters the pool immediately (which
#   is also why targeting the same PR directly always reviewed it fine).
#
# Filters (every exclusion is logged — see "Observability" below):
#   - drafts (isDraft == true)          — work in progress
#   - self-authored (author == BOT_USER) — GitHub rejects self-approval
#     unconditionally; queuing such a PR previously aborted the whole session
#     and starved every later candidate (issue #96).
#
# CI filtering is intentionally omitted here — review-one-pr.sh enforces it
# per-PR as a second layer. Filtering by CI status would exclude repos with no
# CI configured, causing their PRs to never enter the candidate pool.
#
# Observability (issue #1744, AC #3):
#   A candidate that is *seen but excluded* is never dropped silently — each
#   exclusion is logged to stderr as a `::notice::` naming the PR and the reason,
#   and a per-run summary reports how many PRs were seen / kept / excluded. An
#   omission must never be indistinguishable from an empty queue. Notices go to
#   stderr because stdout is the candidate list (the caller redirects it to a
#   file); GitHub Actions still surfaces `::notice::` annotations from stderr.
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
TARGET_ORG="${TARGET_ORG:-petry-projects}"
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
seen=0
kept=0
excluded=0

# JQ filter: classify each PR from a `gh pr list --json url,author,createdAt,isDraft`
# array into one tab-delimited record per line:
#   KEEP<TAB><priority>|<createdAt>|<url>   — an eligible candidate
#   DROP<TAB><reason><TAB><url>             — a seen-but-excluded PR
# Priority 0 — .github / .github-private repos (infra PRs reviewed first);
# priority 1 — all other repos. ISO-8601 createdAt sorts lexicographically, so
# oldest-first within each tier is a plain string sort on the createdAt field.
JQ_CLASSIFY='.[] |
  if .isDraft == true then
    "DROP\tdraft\t" + .url
  elif .author?.login == $bot then
    "DROP\tself-authored\t" + .url
  else
    "KEEP\t"
      + (if (.url | test("/[.]github(-private)?/pull/")) then "0" else "1" end)
      + "|" + .createdAt + "|" + .url
  end'

# Route one repo's classified PRs into the candidate buffer, logging every
# exclusion. Runs in the current shell (no subshell) so the counters and
# all_entries accumulate across repos.
process_repo_prs() {
  local raw="$1" line tag rest reason url
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    tag="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    case "$tag" in
      KEEP)
        all_entries="${all_entries}${rest}"$'\n'
        kept=$((kept + 1))
        seen=$((seen + 1))
        ;;
      DROP)
        reason="${rest%%$'\t'*}"
        url="${rest#*$'\t'}"
        echo "::notice::list-prs: excluded $url from candidate pool (reason: $reason)" >&2
        excluded=$((excluded + 1))
        seen=$((seen + 1))
        ;;
    esac
  done < <(jq -r --arg bot "$BOT_USER" "$JQ_CLASSIFY" <<< "$raw" 2>/dev/null)
}

# List all open PRs across every repo owned by $owner via the List API.
# Both --limit values are set high enough that neither repos nor per-repo PRs
# are silently truncated: a hard cap would omit eligible open PRs beyond it,
# reintroducing the very silent-omission defect this script exists to prevent
# (issue #1744). gh paginates internally up to the requested limit.
search_namespace() {
  local owner="$1" raw
  while IFS= read -r repo || [ -n "$repo" ]; do
    [ -z "$repo" ] && continue
    raw=$(gh pr list \
      --repo "$repo" \
      --state open \
      --limit 1000 \
      --json url,author,createdAt,isDraft 2>/dev/null || echo '[]')
    [ -z "$raw" ] && raw='[]'
    process_repo_prs "$raw"
  done < <(gh repo list "$owner" --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true)
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

# Per-run enumeration summary — makes the pool composition observable so an
# excluded candidate can never be mistaken for an empty queue (issue #1744).
echo "::notice::list-prs: enumeration complete — ${seen} open PR(s) seen, ${kept} kept as candidates, ${excluded} excluded (drafts + self-authored, logged above)" >&2

# 1. Drop blank lines
# 2. Deduplicate by URL (field 3) keeping first occurrence
# 3. Sort: priority (field 1) ascending, then createdAt (field 2) ascending
# 4. Strip the sort keys — output only the URL
grep -v '^$' <<< "$all_entries" \
  | sort -t'|' -k3 -u \
  | sort -t'|' -k1,1n -k2,2 \
  | cut -d'|' -f3- \
  || true
