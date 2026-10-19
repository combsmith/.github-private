#!/usr/bin/env bash
# redispatch.sh — bridge a `discussion [labeled]` event to a supported event.
#
# The decision-brief stage's documented trigger is a maintainer adding
# `needs-brief` to an Ideas Discussion, which fires `on: discussion [labeled]`.
# But the "Draft the decision brief" step uses claude-code-action, which only
# recognizes issues / pull_request / issue_comment / workflow_dispatch event
# contexts and aborts on a `discussion` event:
#
#   Action failed with error: Unsupported event type: discussion
#
# So on the discussion event we DON'T brief inline; we resolve the discussion
# number and re-invoke the SAME workflow via workflow_dispatch, under which the
# action runs cleanly. This is the same bridge initiative-planner.yml uses
# (scripts/initiative-planner/redispatch.sh); it is a separate script only
# because the two workflows declare different dispatch inputs, and `gh workflow
# run` rejects an input the target workflow does not declare.
#
# IMPORTANT — the re-dispatch requires a PAT, not GITHUB_TOKEN:
#   GitHub does not start new workflow runs from events created with the default
#   GITHUB_TOKEN (loop prevention). A workflow_dispatch fired with GITHUB_TOKEN
#   would be accepted but would NEVER start a run, so the caller MUST provide a
#   PAT (GH_PAT_DON_PETRY or GH_PAT_WORKFLOWS) as GH_TOKEN.
#
# Env:
#   REPO               owner/repo to DISPATCH the brief workflow in (required).
#                      For the dogfood path this is .github-private itself; for
#                      fleet callers it is the central repo.
#   TARGET_REPO        owner/repo the brief is FOR (default: REPO) — where the
#                      Discussion lives and where the PR is opened.
#   DISCUSSION_NUMBER  Ideas Discussion number to brief (required)
#   WORKFLOW_FILE      workflow to dispatch (default: decision-brief.yml)
#   DRY_RUN            "1"/"true" => dispatch dry_run=true (default: false)
#   GH_TOKEN           a PAT with workflow scope (required at the call site)
set -euo pipefail

REPO="${REPO:?REPO required}"
TARGET_REPO="${TARGET_REPO:-$REPO}"
DISCUSSION_NUMBER="${DISCUSSION_NUMBER:?DISCUSSION_NUMBER required}"
WORKFLOW_FILE="${WORKFLOW_FILE:-decision-brief.yml}"

# Validate before the value reaches the gh command line.
[[ "$DISCUSSION_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
  echo "::error::DISCUSSION_NUMBER must be a positive integer, got: '$DISCUSSION_NUMBER'" >&2
  exit 1
}
[[ "$TARGET_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
  echo "::error::TARGET_REPO must be owner/repo, got: '$TARGET_REPO'" >&2
  exit 1
}

_dry_run="${DRY_RUN:-}"
if [[ "$_dry_run" == "1" || "${_dry_run,,}" == "true" ]]; then
  DISPATCH_DRY_RUN="true"
else
  DISPATCH_DRY_RUN="false"
fi

# Use GITHUB_REF if it is a branch or tag to support testing on feature branches.
REF_FLAGS=()
if [[ -n "${GITHUB_REF:-}" && ( "$GITHUB_REF" == refs/heads/* || "$GITHUB_REF" == refs/tags/* ) ]]; then
  REF_FLAGS=(--ref "$GITHUB_REF")
fi

echo "Discussion event → re-dispatching ${WORKFLOW_FILE} for discussion #${DISCUSSION_NUMBER} (target ${TARGET_REPO}) via workflow_dispatch."
gh workflow run "$WORKFLOW_FILE" --repo "$REPO" "${REF_FLAGS[@]}" \
  -f discussion="$DISCUSSION_NUMBER" \
  -f target_repo="$TARGET_REPO" \
  -f dry_run="$DISPATCH_DRY_RUN"
echo "Dispatched ${WORKFLOW_FILE} (discussion=${DISCUSSION_NUMBER}, target_repo=${TARGET_REPO}, dry_run=${DISPATCH_DRY_RUN})."
