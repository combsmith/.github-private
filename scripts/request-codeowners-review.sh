#!/usr/bin/env bash
# Request review from every CODEOWNERS entry in a PR's repository.
#
# Inputs:
#   $1 — PR URL
#
# Reads CODEOWNERS from .github/CODEOWNERS, CODEOWNERS, or docs/CODEOWNERS in
# the PR's repo. Extracts every @user / @org/team mention (path-pattern rules
# are not parsed — for an escalation we want every owner notified, not just
# the ones whose patterns match the diff). Requests review from each entry.
#
# Best-effort: every individual request-review call is tolerated to fail. The
# whole script also exits 0 unconditionally so the caller can chain it with
# other escalation steps.

set -uo pipefail

PR_URL="${1:?usage: request-codeowners-review.sh <pr-url>}"
OWNER_REPO=$(echo "$PR_URL" | sed -E 's|.*/([^/]+)/([^/]+)/pull/.*|\1/\2|')

CODEOWNERS=""
for path in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
  encoded=$(gh api "repos/$OWNER_REPO/contents/$path" --jq '.content' 2>/dev/null) || continue
  [[ -z "$encoded" ]] && continue
  decoded=$(printf '%s' "$encoded" | base64 -d 2>/dev/null) || continue
  [[ -n "$decoded" ]] && { CODEOWNERS="$decoded"; break; }
done

if [[ -z "$CODEOWNERS" ]]; then
  echo "    CODEOWNERS not found in $OWNER_REPO — relying on needs-human-review label only"
  exit 0
fi

# Strip comments, then collect every @user and @org/team mention.
mentions=$(printf '%s\n' "$CODEOWNERS" \
  | sed 's/#.*//' \
  | grep -oE '@[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)?' \
  | sed 's|^@||' \
  | sort -u)

if [[ -z "$mentions" ]]; then
  echo "    CODEOWNERS in $OWNER_REPO has no @mentions"
  exit 0
fi

while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  if gh pr edit "$PR_URL" --add-reviewer "$entry" 2>/dev/null; then
    echo "    requested review from @$entry"
  else
    echo "    warn: failed to request review from @$entry (insufficient scope or unknown user/team?)"
  fi
done <<< "$mentions"

exit 0
