#!/usr/bin/env bash
# Backfill missing `<!-- pr-review-agent v1 sha=<SHA> -->` markers onto
# fix-request comments posted by the bot that predate the fix in
# post-pr-review.sh (PR #134).
#
# For each target PR:
#   1. Fetch current head SHA.
#   2. Find issue comments by BOT_USER whose body matches the fix-request
#      pattern ("## Review — fix requested") but lacks the marker.
#   3. PATCH each such comment to prepend the marker using the PR's current
#      head SHA and the risk level extracted from the comment body (or MEDIUM
#      as a safe default).
#
# Usage:
#   bash scripts/backfill-review-markers.sh <pr-url> [<pr-url> ...]
#
#   # Or pipe a list:
#   cat prs.txt | xargs bash scripts/backfill-review-markers.sh
#
# Env:
#   GH_TOKEN   — PAT with repo read + issues write (defaults to env or gh auth)
#   BOT_USER   — bot login to filter by (default: donpetry-bot)
#   DRY_RUN    — "true" to print what would change without patching (default: false)

set -euo pipefail

BOT_USER="${BOT_USER:-donpetry-bot}"
DRY_RUN="${DRY_RUN:-false}"

if [[ "$#" -eq 0 ]]; then
  echo "Usage: $0 <pr-url> [<pr-url> ...]" >&2
  exit 1
fi

patched=0
skipped=0
already_ok=0

for PR_URL in "$@"; do
  echo "==> $PR_URL"

  # Resolve owner/repo and PR number from the URL.
  OWNER_REPO=$(echo "$PR_URL" | sed -E 's|https?://github\.com/([^/]+/[^/]+)/pull/.*|\1|')
  PR_NUM=$(echo "$PR_URL" | sed -E 's|.*/([0-9]+)$|\1|')

  # Current head SHA — used as the backfill value for all unmarked comments on
  # this PR (they were all posted against the same unmoving head).
  HEAD_SHA=$(gh pr view "$PR_URL" --json headRefOid --jq '.headRefOid' 2>/dev/null)
  if [[ -z "$HEAD_SHA" ]]; then
    echo "  error: could not resolve head SHA for $PR_URL — skipping" >&2
    continue
  fi
  echo "  head SHA: $HEAD_SHA"

  # Fetch all issue comments; stage to a temp file to avoid shell quoting
  # issues with control characters in user-authored bodies.
  COMMENTS_FILE=$(mktemp)
  gh api --paginate "repos/$OWNER_REPO/issues/$PR_NUM/comments" > "$COMMENTS_FILE"

  # Select comments by BOT_USER that look like fix-request comments but lack
  # the marker. Output: one comment ID per line.
  CANDIDATES=$(jq -r --arg bot "$BOT_USER" '
    .[]
    | select(.user.login == $bot)
    | select(.body != null)
    | select(.body | test("## Review — fix requested"))
    | select(.body | test("<!-- pr-review-agent v1 sha=[a-f0-9]+") | not)
    | .id
  ' "$COMMENTS_FILE")

  if [[ -z "$CANDIDATES" ]]; then
    echo "  no unmarked fix-request comments by $BOT_USER — nothing to do"
    already_ok=$((already_ok + 1))
    rm -f "$COMMENTS_FILE"
    continue
  fi

  echo "  found $(echo "$CANDIDATES" | wc -l | tr -d ' ') candidate comment(s)"

  while IFS= read -r CID; do
    [[ -z "$CID" ]] && continue

    # Extract the existing body for this comment.
    OLD_BODY=$(jq -r --argjson id "$CID" '.[] | select(.id == $id) | .body' "$COMMENTS_FILE")

    # Attempt to infer risk from "risk=LEVEL" in the existing body; fall back
    # to MEDIUM if not found (safe default that won't change behaviour).
    RISK=$(echo "$OLD_BODY" | grep -oE 'risk=[A-Z]+' | head -1 | cut -d= -f2 || true)
    RISK="${RISK:-MEDIUM}"

    MARKER="<!-- pr-review-agent v1 sha=${HEAD_SHA} --> <!-- decision=fix-requested risk=${RISK} -->"
    NEW_BODY="${MARKER}"$'\n\n'"${OLD_BODY}"

    echo "  comment $CID: prepending marker (risk=$RISK)"

    if [[ "$DRY_RUN" = "true" ]]; then
      echo "  [DRY RUN] would PATCH comment $CID with:"
      echo "    $MARKER"
      skipped=$((skipped + 1))
      continue
    fi

    PATCH_ERR=$(jq -n --arg b "$NEW_BODY" '{body: $b}' \
      | gh api -X PATCH "repos/$OWNER_REPO/issues/comments/$CID" --input - \
        2>&1 >/dev/null) || {
      echo "  error: failed to patch comment $CID — $PATCH_ERR" >&2
      skipped=$((skipped + 1))
      continue
    }

    echo "  patched comment $CID ✓"
    patched=$((patched + 1))
  done <<< "$CANDIDATES"

  rm -f "$COMMENTS_FILE"
done

echo ""
echo "Done. patched=$patched skipped=$skipped already_ok=$already_ok"
