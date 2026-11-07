#!/usr/bin/env bash
# redispatch.sh — bridge a `discussion [labeled]` event to a supported event.
#
# The initiative planner's documented primary trigger is a maintainer adding
# `idea:approved` to an Ideas Discussion, which fires `on: discussion [labeled]`.
# But the planner's "Plan the initiative" step uses claude-code-action, which
# only recognizes issues / pull_request / issue_comment / workflow_dispatch event
# contexts and aborts on a `discussion` event:
#
#   Action failed with error: Unsupported event type: discussion
#
# So on the discussion event we DON'T plan inline; we resolve the discussion
# number and re-invoke the SAME workflow via workflow_dispatch, under which the
# action runs cleanly. The `idea:approved` label stays the human gate; the
# re-dispatch is an invisible bridge.
#
# IMPORTANT — the re-dispatch requires a PAT, not GITHUB_TOKEN:
#   GitHub does not start new workflow runs from events created with the default
#   GITHUB_TOKEN (loop prevention). A workflow_dispatch fired with GITHUB_TOKEN
#   would be accepted but would NEVER start a run, so the caller MUST provide a
#   PAT (GH_PAT_WORKFLOWS) as GH_TOKEN. This is the same constraint documented in
#   scripts/initiative-driver.sh for the dev-lead label trigger.
#
# Env:
#   REPO               owner/repo to DISPATCH the planner in (required). For the
#                      dogfood path this is .github-private itself; for fleet
#                      callers (per-repo stub, #820) it is the central planner repo.
#   TARGET_REPO        owner/repo the planner should PLAN FOR (default: REPO).
#                      The dogfood/self path leaves this unset so target == self.
#   DISCUSSION_REPO    owner/repo holding the Discussion, when it differs from
#                      TARGET_REPO (graduation). Forwarded as discussion_repo only
#                      when set, so the default dispatch is unchanged.
#   DISCUSSION_NUMBER  Ideas Discussion number to plan (required)
#   WORKFLOW_FILE      workflow to dispatch (default: initiative-planner.yml)
#   DRY_RUN            "1"/"true" => dispatch dry_run=true (default: false)
#   FORCE_REPLAN       "1"/"true" => dispatch force_replan=true (default: false);
#                      set by the `initiative:replan` label path to supersede an
#                      already-planned discussion's epic instead of no-opping
#   RECONCILE          "1"/"true" => dispatch reconcile=true (default: false); set
#                      by the `initiative:reconcile` label path to ADD newly-surfaced
#                      work to the discussion's existing epic in place (#708). Mutually
#                      exclusive with FORCE_REPLAN — apply-plan.sh rejects both set.
#   GH_TOKEN           a PAT with workflow scope (required at the call site)
set -euo pipefail

REPO="${REPO:?REPO required}"
TARGET_REPO="${TARGET_REPO:-$REPO}"
DISCUSSION_NUMBER="${DISCUSSION_NUMBER:?DISCUSSION_NUMBER required}"
WORKFLOW_FILE="${WORKFLOW_FILE:-initiative-planner.yml}"

# Validate before the value reaches the gh command line.
[[ "$DISCUSSION_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
  echo "::error::DISCUSSION_NUMBER must be a positive integer, got: '$DISCUSSION_NUMBER'" >&2
  exit 1
}

# Map DRY_RUN to a boolean string for the workflow input
_dry_run="${DRY_RUN:-}"
if [[ "$_dry_run" == "1" || "${_dry_run,,}" == "true" ]]; then
  DISPATCH_DRY_RUN="true"
else
  DISPATCH_DRY_RUN="false"
fi

# Map FORCE_REPLAN to a boolean string for the workflow input. The
# `initiative:replan` label path sets this so the re-dispatch supersedes the
# discussion's existing epic instead of no-opping on apply-plan's idempotency guard.
_force_replan="${FORCE_REPLAN:-}"
if [[ "$_force_replan" == "1" || "${_force_replan,,}" == "true" ]]; then
  DISPATCH_FORCE_REPLAN="true"
else
  DISPATCH_FORCE_REPLAN="false"
fi

# Map RECONCILE to a boolean string for the workflow input. The
# `initiative:reconcile` label path sets this so the re-dispatch binds to the
# discussion's existing epic and ADDS newly-surfaced work in place (#708) instead
# of no-opping on apply-plan's idempotency guard.
_reconcile="${RECONCILE:-}"
if [[ "$_reconcile" == "1" || "${_reconcile,,}" == "true" ]]; then
  DISPATCH_RECONCILE="true"
else
  DISPATCH_RECONCILE="false"
fi

# Use GITHUB_REF if it is a branch or tag to support testing on feature branches
REF_FLAGS=()
if [[ -n "${GITHUB_REF:-}" && ( "$GITHUB_REF" == refs/heads/* || "$GITHUB_REF" == refs/tags/* ) ]]; then
  REF_FLAGS=(--ref "$GITHUB_REF")
fi

DISC_FLAGS=()
if [[ -n "${DISCUSSION_REPO:-}" ]]; then
  [[ "$DISCUSSION_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    echo "::error::DISCUSSION_REPO must be owner/repo, got: '$DISCUSSION_REPO'" >&2
    exit 1
  }
  DISC_FLAGS=(-f discussion_repo="$DISCUSSION_REPO")
fi

echo "Discussion event → re-dispatching ${WORKFLOW_FILE} for discussion ${DISCUSSION_REPO:-}#${DISCUSSION_NUMBER} (target ${TARGET_REPO}) via workflow_dispatch."
gh workflow run "$WORKFLOW_FILE" --repo "$REPO" "${REF_FLAGS[@]}" \
  -f discussion="$DISCUSSION_NUMBER" \
  -f target_repo="$TARGET_REPO" \
  "${DISC_FLAGS[@]}" \
  -f dry_run="$DISPATCH_DRY_RUN" \
  -f force_replan="$DISPATCH_FORCE_REPLAN" \
  -f reconcile="$DISPATCH_RECONCILE"
echo "Dispatched ${WORKFLOW_FILE} (discussion=${DISCUSSION_NUMBER}, target_repo=${TARGET_REPO}, dry_run=${DISPATCH_DRY_RUN}, force_replan=${DISPATCH_FORCE_REPLAN}, reconcile=${DISPATCH_RECONCILE})."
