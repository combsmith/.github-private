#!/usr/bin/env bash
# git-history.sh — make the merge base of HEAD and origin/<base> resolvable on a
# shallow checkout (#2053).
#
# actions/checkout defaults to a depth-1 clone: only the tip of each ref is
# present, so a PR branch and its base appear to share no ancestor. A three-dot
# diff, a trial merge, or `git rebase origin/<base>` then sees "unrelated
# histories". A plain `git fetch origin <base>` does NOT deepen a shallow
# checkout, so history must be deepened explicitly. This is the single copy of
# that logic — the rebase arm, pr_nets_to_zero and net-diff-guard.sh all use it.
#
# Two entry points:
#   git_history_deepen    <base> [head_ref] — best-effort deepen; always rc 0.
#   git_ensure_merge_base <base> [head_ref] — deepen, then verify:
#       0 → merge base of HEAD and origin/<base> resolves
#       1 → history is complete but there is no merge base (genuinely unrelated)
#       2 → history could not be deepened, or origin/<base> could not be
#           fetched: an infrastructure failure, NOT a conflict.

# git_history_deepen <base> [head_ref] — if the repo is shallow, un-shallow it;
# if that is refused, fall back to a deep fetch of the base and head refs.
# Best-effort: never fails the caller, which decides what an incomplete history
# means for it.
git_history_deepen() {
  local base="$1" head_ref="${2:-}"
  local is_shallow
  is_shallow=$(git rev-parse --is-shallow-repository 2>/dev/null) || is_shallow="false"
  [[ "$is_shallow" = "true" ]] || return 0
  git fetch --quiet --unshallow origin 2>/dev/null && return 0
  # Plain ref names (no forced destination), as the pre-#2053 copies did: this
  # deepens both histories without force-moving origin/<head_ref>, which the
  # push lease (--force-with-lease, #1607) is measured against.
  local refs=()
  [[ -n "$base" ]] && refs+=("$base")
  if [[ -z "$head_ref" ]]; then
    # Callers may omit head_ref: deepen the checked-out branch, or the detached
    # HEAD commit, so HEAD's own ancestry is fetched too.
    head_ref=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse HEAD 2>/dev/null || true)
  fi
  [[ -n "$head_ref" ]] && refs+=("$head_ref")
  [[ "${#refs[@]}" -gt 0 ]] || return 0
  git fetch --quiet --depth=2147483647 origin "${refs[@]}" 2>/dev/null || true
  return 0
}

# git_ensure_merge_base <base> [head_ref] — refresh origin/<base>, deepen
# history, and report whether the merge base of HEAD and origin/<base> resolves
# (see the header for the return codes). On rc 2 it prints one line to stdout
# saying what could not be done, so callers can quote it.
git_ensure_merge_base() {
  local base="$1" head_ref="${2:-}"
  local baseref="origin/${base}"

  local fetched=1
  git fetch --quiet origin "+refs/heads/${base}:refs/remotes/origin/${base}" 2>/dev/null || fetched=0
  git_history_deepen "$base" "$head_ref"
  # The first fetch may have hit a transient failure; retry once after the
  # deepen so a recovered connection counts as a successful refresh.
  if [ "$fetched" -eq 0 ]; then
    git fetch --quiet origin "+refs/heads/${base}:refs/remotes/origin/${base}" 2>/dev/null && fetched=1
  fi

  if ! git rev-parse --verify --quiet "${baseref}^{commit}" >/dev/null 2>&1; then
    echo "git history could not be deepened: ${baseref} is not available in this checkout (fetch from origin failed)"
    return 2
  fi
  local mb_rc=0
  git merge-base HEAD "$baseref" >/dev/null 2>&1 || mb_rc=$?
  if [ "$mb_rc" -eq 0 ]; then
    # A merge base against a stale local copy of the base is not good enough:
    # rebasing onto it would leave the PR conflicting with the real base.
    if [ "$fetched" -eq 0 ]; then
      echo "git history could not be refreshed: fetching ${baseref} from origin failed, so the local copy may be stale"
      return 2
    fi
    return 0
  fi
  if [ "$mb_rc" -ne 1 ]; then
    echo "git history could not be checked: git merge-base failed with status ${mb_rc}"
    return 2
  fi
  local still_shallow
  still_shallow=$(git rev-parse --is-shallow-repository 2>/dev/null) || still_shallow="true"
  if [[ "$still_shallow" = "true" ]]; then
    echo "git history could not be deepened: the checkout is still shallow after un-shallowing and a deep fetch of ${baseref}${head_ref:+ and origin/${head_ref}}, so the merge base with HEAD cannot be computed"
    return 2
  fi
  # Complete history, but the base refresh failed: the merge base was computed
  # against a possibly stale local origin/<base>, so "unrelated" is not proven.
  if [ "$fetched" -eq 0 ]; then
    echo "git history could not be refreshed: fetching ${baseref} from origin failed, so the absence of a merge base with the local copy does not prove the histories are unrelated"
    return 2
  fi
  return 1
}
