#!/usr/bin/env bash
# net-diff-guard.sh — shared "net diff against base" helpers (#1786, slice 1 of
# epic #1620).
#
# dev-lead must never open a PR, claim completion, or push a self-cancelling
# update whose NET diff against the base branch is empty. The net diff is the
# three-dot compare `origin/<base>...HEAD` — the changes the branch's own commits
# introduce relative to their merge-base with the base — NOT the PR's file list
# (a file touched and then reverted still appears in the file list but nets to
# zero). Merging a `Closes #N` PR that nets to zero would auto-close its
# compliance issue while the finding stays unfixed, and the idempotent audit
# would immediately re-open it (the #1340 failure mode, generalised here to the
# PR-open and completion-claim paths as well as every push).
#
# Two entry points:
#   net_diff_is_empty <base>  — true (rc 0) iff the three-dot net diff is empty.
#   net_diff_summary  <base>  — echo a human-readable "N file(s), +A/-D lines".
#
# FAIL-OPEN contract: when the base ref cannot be resolved to a concrete commit
# (no ref, fetch fails, shallow clone with no common ancestor, diff errors),
# net_diff_is_empty returns 1 ("not net-zero") and warns, so an UNVERIFIABLE
# state never blocks a legitimate push/PR. Resolution requires a NON-EMPTY base
# SHA — an empty rev-parse result is treated as unresolved, not as "base is the
# empty tree" — which is what keeps PATH-stubbed unit tests (whose git stub
# echoes nothing for unknown args) failing open instead of falsely aborting.

# git_history_deepen (#2053): the single shared un-shallow helper.
# shellcheck source=scripts/lib/git-history.sh
source "$(dirname "${BASH_SOURCE[0]}")/git-history.sh"

# _ndg_resolve_base_sha <base> — echo the concrete commit SHA for origin/<base>,
# deepening a shallow clone and fetching the ref if needed. Echoes nothing (and
# the caller fails open) when it cannot be resolved.
_ndg_resolve_base_sha() {
  local base="$1"
  local baseref="origin/${base}"

  # actions/checkout defaults to a depth-1 shallow clone, which lacks the common
  # ancestor the three-dot diff needs. Deepen it first (shared helper, #2053).
  git_history_deepen "$base"

  # Always fetch the base ref to ensure we have the latest version, not a stale
  # cached copy. Use FETCH_HEAD to get the exact commit that was just fetched,
  # which is more robust than relying on the remote-tracking branch.
  git fetch --quiet origin "$base" 2>/dev/null || true
  local sha
  sha=$(git rev-parse --verify --quiet "FETCH_HEAD^{commit}" 2>/dev/null || true)
  if [[ -z "$sha" ]]; then
    # Fall back to the remote-tracking branch if FETCH_HEAD is not available.
    sha=$(git rev-parse --verify --quiet "${baseref}^{commit}" 2>/dev/null || true)
  fi
  printf '%s' "$sha"
}

# net_diff_is_empty [base] — returns 0 (true) when the branch's net diff against
# its base is empty (every change its own commits introduced has been undone, so
# `origin/<base>...HEAD` shows zero changed files). Returns 1 when the net diff
# is non-empty OR when the base cannot be verified (fail-open).
net_diff_is_empty() {
  local base="${1:-${BASE_REF:-main}}"
  local baseref="origin/${base}"

  local base_sha
  base_sha=$(_ndg_resolve_base_sha "$base")
  if [[ -z "$base_sha" ]]; then
    echo "::warning::net-diff guard: could not resolve ${baseref} to a commit — cannot verify net diff, proceeding" >&2
    return 1
  fi

  # A merge-base must exist before diffing; without it "${base_sha}...HEAD" errors
  # and the guard would silently fail. Treat an absent merge-base as unverifiable.
  if ! git merge-base "$base_sha" HEAD >/dev/null 2>&1; then
    echo "::warning::net-diff guard: no merge-base between ${baseref} and HEAD — proceeding" >&2
    return 1
  fi

  local changed
  changed=$(git diff --name-only "${base_sha}...HEAD" 2>/dev/null) || {
    echo "::warning::net-diff guard: git diff against ${baseref} failed — proceeding" >&2
    return 1
  }
  [[ -z "$changed" ]]
}

# net_diff_summary [base] — echo a compact, human-readable summary of the net
# diff against the base: "<N> file(s), +<added>/-<deleted> lines". When the base
# cannot be resolved, echo an explicit "unknown" note rather than a misleading
# zero (the caller only reaches here on a verified non-empty diff, but the
# summary itself must never assert "0 files" from an unresolved base).
net_diff_summary() {
  local base="${1:-${BASE_REF:-main}}"
  local baseref="origin/${base}"

  local base_sha
  base_sha=$(_ndg_resolve_base_sha "$base")
  if [[ -z "$base_sha" ]] || ! git merge-base "$base_sha" HEAD >/dev/null 2>&1; then
    printf 'unknown (could not resolve %s)' "$baseref"
    return 0
  fi

  local numstat
  numstat=$(git diff --numstat "${base_sha}...HEAD" 2>/dev/null || true)
  if [[ -z "$numstat" ]]; then
    printf '0 files, +0/-0 lines'
    return 0
  fi
  # Binary files show "-\t-\t<path>"; treat their non-numeric counts as 0.
  local files added deleted
  read -r files added deleted < <(printf '%s\n' "$numstat" | awk '
    {
      files++
      if ($1 ~ /^[0-9]+$/) added += $1
      if ($2 ~ /^[0-9]+$/) deleted += $2
    }
    END {
      print files, added + 0, deleted + 0
    }
  ')
  printf '%s file(s), +%s/-%s lines' "$files" "$added" "$deleted"
}
