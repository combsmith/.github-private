#!/usr/bin/env bash
set -euo pipefail
# auto-merge.sh — hold GitHub auto-merge while dev-lead works a PR, and push
# defensively so a PR that merges mid-run doesn't fail the job.
#
# Why
# ---
# dev-lead enables auto-merge (squash) by default on every PR it touches (#447).
# GitHub's auto-merge is asynchronous and is NOT gated by the workflow's
# concurrency lane, so a review approval landing while the agent is mid-edit can
# merge — and delete — the branch out from under the run, which then fails on
# push with:
#
#   ! [remote rejected] ... (cannot lock ref 'refs/heads/...':
#     unable to resolve reference 'refs/heads/...')
#
# (petry-projects/.github-private run 27078382804; issue #452.)
#
# Mitigation
# ----------
#  - hold_auto_merge        turns auto-merge OFF at the start of a modifying run
#                           so a mid-flight approval can't merge the branch.
#  - restore_auto_merge     (EXIT trap) puts auto-merge back exactly as it was,
#                           however the run exits (success, error, or timeout).
#  - push_with_merge_guard  treats "branch merged/closed mid-run" as a benign
#                           success instead of a hard, red-X failure.
#
# All functions read PR_NUMBER / REPO / DEV_LEAD_DRY_RUN from the environment.

# push_with_merge_guard shares the #1607 stale-base guard with push_no_clobber:
# incorporate the true remote head (or escalate) before pushing, and pin every
# force-push lease. Source it here so callers that pull in auto-merge.sh but not
# git-push-guard.sh (e.g. dev-lead-fix-ci.sh) still get those helpers.
# shellcheck source=scripts/lib/git-push-guard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-push-guard.sh"

# Set to 1 by hold_auto_merge only when it actually turned auto-merge off, so
# restore_auto_merge re-enables exactly what we disabled and nothing else (it
# must never newly enable auto-merge on a PR that never had it).
_AM_NEEDS_RESTORE=0
# Merge method captured by hold_auto_merge; used by restore_auto_merge to replay
# the original strategy (merge/squash/rebase) rather than always choosing squash.
_AM_MERGE_METHOD="squash"
# Custom commit title/message captured from auto_merge; replayed on restore so the
# user's selected merge message is not lost when auto-merge is re-enabled.
_AM_COMMIT_TITLE=""
_AM_COMMIT_MESSAGE=""
# PR head SHA captured at hold time; used by restore_auto_merge only as a
# fallback when re-fetching the PR's current head fails. Restore prefers the
# freshly-fetched head so --match-head-commit matches commits pushed during the
# run (own commits, or the rebase engine's direct force-push).
_AM_HEAD_SHA=""

# hold_auto_merge — disable auto-merge for the duration of the run, if it is on.
hold_auto_merge() {
  [ -n "${PR_NUMBER:-}" ] || return 0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would hold auto-merge OFF on PR #${PR_NUMBER} while working"
    return 0
  fi
  local state
  state=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.auto_merge.merge_method // empty' 2>/dev/null || true)
  [ -n "$state" ] || return 0   # already off — leave it alone
  _AM_MERGE_METHOD="$state"
  _AM_COMMIT_TITLE=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.auto_merge.commit_title // empty' 2>/dev/null || true)
  _AM_COMMIT_MESSAGE=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.auto_merge.commit_message // empty' 2>/dev/null || true)
  _AM_HEAD_SHA=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha' 2>/dev/null || true)
  echo "::notice::PR #${PR_NUMBER} — holding auto-merge OFF while dev-lead works"
  if gh pr merge "$PR_NUMBER" --repo "$REPO" --disable-auto 2>/dev/null; then
    _AM_NEEDS_RESTORE=1
  else
    # An approval may have landed in the window between the auto_merge probe above
    # and this call, causing GitHub to merge and close the PR. If so, exit cleanly
    # instead of continuing into checkout_pr_in_worktree on a deleted branch.
    local merged_state
    merged_state=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.state' 2>/dev/null || true)
    if [ -n "$merged_state" ] && [ "$merged_state" != "open" ]; then
      echo "::notice::PR #${PR_NUMBER} is ${merged_state} — merged/closed before hold could be set; exiting cleanly."
      exit 0
    fi
    echo "::error::could not disable auto-merge on PR #${PR_NUMBER} — aborting to prevent mid-run merge race" >&2
    exit 1
  fi
}

# restore_auto_merge — EXIT-trap safety net: re-enable auto-merge iff
# hold_auto_merge disabled it and the PR is still open. Best-effort and
# idempotent; no-ops when the success path already re-enabled it.
restore_auto_merge() {
  [ "${_AM_NEEDS_RESTORE:-0}" = "1" ] || return 0
  _AM_NEEDS_RESTORE=0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would restore auto-merge on PR #${PR_NUMBER}"
    return 0
  fi
  local pr_state
  pr_state=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.state' 2>/dev/null || true)
  [ "$pr_state" != "closed" ] || return 0   # merged/closed — nothing to restore
  local am
  am=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.auto_merge // empty' 2>/dev/null || true)
  if [ -n "$am" ]; then return 0; fi     # success path already restored it
  local merge_flag
  case "${_AM_MERGE_METHOD:-squash}" in
    merge)  merge_flag="--merge" ;;
    rebase) merge_flag="--rebase" ;;
    *)      merge_flag="--squash" ;;
  esac
  local restore_args=("--auto" "$merge_flag")
  [[ -n "${_AM_COMMIT_TITLE:-}" ]] && restore_args+=("--subject" "${_AM_COMMIT_TITLE}")
  [[ -n "${_AM_COMMIT_MESSAGE:-}" ]] && restore_args+=("--body" "${_AM_COMMIT_MESSAGE}")
  # Match against the PR's CURRENT head, re-fetched now — not a SHA captured at
  # hold time. The head can advance during the run via our own commits, the
  # rebase engine's direct `git push --force-with-lease` (prompts/dev-lead/rebase.md,
  # which bypasses push_with_merge_guard), or otherwise; a stale
  # --match-head-commit makes GitHub reject the restore and leaves auto-merge
  # off. Fall back to the hold-time SHA only when the re-fetch fails.
  local match_sha
  match_sha=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha' 2>/dev/null || true)
  match_sha="${match_sha:-${_AM_HEAD_SHA:-}}"
  [[ -n "$match_sha" ]] && restore_args+=("--match-head-commit" "$match_sha")
  echo "::notice::PR #${PR_NUMBER} — restoring auto-merge (${_AM_MERGE_METHOD:-squash})"
  gh pr merge "$PR_NUMBER" --repo "$REPO" "${restore_args[@]}" 2>/dev/null \
    || echo "::warning::could not restore auto-merge on PR #${PR_NUMBER}"
}

# push_with_merge_guard [git push args...] — push the current branch, but exit 0
# cleanly when the push fails because the PR was merged/closed (its branch
# deleted) mid-run. Returns 0 on a real push; returns 1 on a genuine failure.
push_with_merge_guard() {
  # #1607: reconcile with the true remote head first — incorporate a concurrent
  # steering commit, or stop/escalate (return non-zero) if it cannot be
  # incorporated cleanly. A fetch failure (e.g. the branch was deleted by a
  # mid-run merge) returns 0, leaving the merge-race handling below to run.
  local reconcile_rc=0
  incorporate_remote_head "$@" || reconcile_rc=$?
  if [ "$reconcile_rc" -ne 0 ]; then
    # A PR merged/closed mid-run can make the reconcile fail (e.g. a rebase
    # conflict against a head that is about to vanish). That is the benign merge
    # race this guard exists for, not a genuine escalation — check the PR's state
    # before failing the job, exactly as the post-push path below does.
    local reconcile_state
    reconcile_state=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.state' 2>/dev/null || true)
    if [ -n "$reconcile_state" ] && [ "$reconcile_state" != "open" ]; then
      echo "::notice::PR #${PR_NUMBER} is ${reconcile_state} — merged/closed mid-run; nothing to push. Exiting cleanly."
      exit 0
    fi
    return "$reconcile_rc"
  fi

  local errf
  errf="$(mktemp)"
  if git push "$@" 2>"$errf"; then
    rm -f "$errf"
    # Refresh the held SHA after our own push so the EXIT-trap restore uses
    # --match-head-commit against the new head rather than the pre-push SHA.
    _AM_HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || true)
    return 0
  fi

  # A non-fast-forward rejection while the local branch has diverged from its
  # upstream means the engine rewrote history — e.g. it resolved a rebase under
  # an intent (on-mention, review-changes) whose plain push can never publish
  # the rewritten branch. Retry once with a PINNED lease (#1607): an explicit
  # lease against the remote head incorporate_remote_head just verified, or
  # --force-with-lease --force-if-includes when no fetch succeeded. Either aborts
  # if the remote advanced to a commit we did not incorporate, so a concurrent
  # steering push is never clobbered.
  local upstream
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  if grep -qiE 'non-fast-forward|\[rejected\]|fetch first' "$errf" \
     && [ -n "$upstream" ] \
     && ! git merge-base --is-ancestor "$upstream" HEAD 2>/dev/null; then
    local discarded
    discarded=$(git rev-list "HEAD..${upstream}" 2>/dev/null | tr '\n' ' ')
    echo "::notice::push rejected (non-fast-forward) and HEAD has diverged from ${upstream} — history was rewritten (likely a self-rebase); retrying with a pinned lease. Overwriting dev-lead's own commit(s): ${discarded:-<none>}" >&2
    if _pinned_force_push "$@" 2>>"$errf"; then
      rm -f "$errf"
      _AM_HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || true)
      return 0
    fi
  fi

  cat "$errf" >&2
  rm -f "$errf"

  # The PR merging out from under us is the expected benign race: GitHub closes
  # the PR (state != open) and deletes its branch, so our push can't lock the ref.
  local state
  state=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.state' 2>/dev/null || true)
  if [ -n "$state" ] && [ "$state" != "open" ]; then
    echo "::notice::PR #${PR_NUMBER} is ${state} — its branch was merged/closed mid-run; nothing to push. Exiting cleanly."
    exit 0
  fi

  echo "::error::git push failed — check remote access and branch permissions" >&2
  return 1
}
