#!/usr/bin/env bash
# Repair PRs that have agent approval comments but no actual approval reviews.
#
# Problem: agent was posting comments with decision=approved instead of
# actual approval reviews, so auto-merge never triggered.
#
# Solution: find these PRs across all repos and post proper approval reviews.
#
# Usage: repair-pr-approvals.sh [dry_run]
#   dry_run = "true" for dry-run (default: false)

set -euo pipefail

# Default to dry-run (true) unless explicitly set to false
DRY_RUN="${1:-true}"

# Verify GitHub auth is available
if ! gh auth status &>/dev/null; then
  echo "ERROR: Not authenticated with GitHub. Run 'gh auth login' first."
  exit 1
fi

echo "=== Repairing PRs with missing approval reviews ==="
echo "Dry run: $DRY_RUN"
echo ""

approved=0
failed=0
automerge_enabled=0
skipped=0

# Build list of all repos
while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  echo "Checking $repo..."

  # Get all open PRs with approval marker comments in this repo
  while IFS='|' read -r pr_url pr_num; do
    # Check if PR has agent approval marker comment
    marker=$(gh pr view "$pr_url" --json comments --jq '.comments[] | select(.body | contains("pr-review-agent") and contains("decision=approved")) | .body' 2>/dev/null | head -1 || true)
    [ -z "$marker" ] && continue

    # Check if PR already has an actual approval review
    approval_count=$(gh pr view "$pr_url" --json reviews --jq '[.reviews[] | select(.state == "APPROVED")] | length' 2>/dev/null || echo 0)
    if [ "$approval_count" -gt 0 ]; then
      echo "  ✓ PR #$pr_num - already has approval review"
      skipped=$((skipped + 1))
      continue
    fi

    # Get the approval comment to use as review body
    comment=$(gh pr view "$pr_url" --json comments --jq '.comments[] | select(.body | contains("pr-review-agent") and contains("decision=approved")) | .body' 2>/dev/null | tail -1 || true)
    [ -z "$comment" ] && continue

    echo "  → PR #$pr_num - posting approval review..."
    if [ "$DRY_RUN" = "true" ]; then
      echo "    [DRY RUN] Would post approval review"
      approved=$((approved + 1))
    else
      if gh pr review "$pr_url" --approve --body "$comment" 2>&1; then
        echo "    ✓ Posted approval review"
        approved=$((approved + 1))

        # Check if auto-merge is enabled, enable if needed
        automerge=$(gh pr view "$pr_url" --json autoMerge --jq '.autoMerge != null' 2>/dev/null || echo false)
        if [ "$automerge" = "false" ]; then
          echo "    → Enabling auto-merge..."
          if gh pr merge "$pr_url" --auto --squash 2>&1; then
            echo "    ✓ Auto-merge enabled"
            automerge_enabled=$((automerge_enabled + 1))
          else
            echo "    ✗ Failed to enable auto-merge"
          fi
        fi
      else
        rc=$?
        echo "    ✗ Failed to post approval review (exit code $rc)"
        failed=$((failed + 1))
      fi
    fi
  done < <(gh pr list --repo "$repo" --state open --json url,number,comments --limit 100 2>/dev/null | jq -r '.[] | select(.comments | length > 0) | {url, number} | "\(.url)|\(.number)"')
done < <(
  {
    gh repo list "${BOT_USER:-donpetry-bot}" --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true
    gh repo list "${TARGET_ORG:-petry-projects}" --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true
  } | sort -u
)

echo ""
echo "=== Summary ==="
echo "Already have approval reviews: $skipped"
echo "Approval reviews posted: $approved"
echo "Auto-merge enabled: $automerge_enabled"
echo "Failures: $failed"
