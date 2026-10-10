#!/usr/bin/env bash
# base-residue-guard.sh — an agent session must not leave base-branch content in
# the PR worktree for the harness to commit (#2216, follow-up to #2211).
#
# WHAT IS WRONG WITHOUT THIS
#   On PR #2198 (run 38072695498) a fix-bot-comment session checked whether a
#   failure was "pre-existing on origin/main" and left origin/main's content for
#   the PR's three files in the working tree, HEAD still on the PR branch. The
#   harness's `git add -A` committed that as 23ad348, the exact inverse of the PR.
#   The no-op guard caught it only because the revert was total; a partial revert
#   (some PR files back at base) would have been committed and pushed.
#
# THE RULE
#   The agent's own COMMITS may revert PR files (a deliberate "restore X to main"
#   fix, the eb763aa8 shape). UNCOMMITTED residue may not. A path is base-content
#   residue when all of these hold:
#     1. it is in the PR's net diff, `<merge-base>..HEAD` (HEAD includes the
#        agent's commits, so a file the agent's commits already reverted is out);
#     2. its working-tree content differs from HEAD (the change is uncommitted,
#        staged or not);
#     3. its working-tree content equals its content at the merge base OR at the
#        local tip of origin/<base> (what `git checkout origin/<base> -- .` puts
#        there). "Absent" is a content: a PR-deleted file brought back, or a
#        PR-added file removed, matches too.
#   Residue is dropped (restored to HEAD in index and working tree) with a
#   warning; every other uncommitted change is still committed. It applies only
#   to the intents whose prompts make the agent commit its fixes before claiming
#   them (fix-reviews, fix-bot-comment, review-changes, human-pr) — elsewhere a
#   legitimate restore is uncommitted too, so residue and fix cannot be told apart.
#
# FAIL-OPEN contract: when origin/<base> or the merge base cannot be resolved,
#   brg_find_residue returns 2 and nothing is dropped. This is a cleanup, not a
#   gate: the no-op guard (#1340) remains the backstop for a total revert.
#
# Sourced under `set -euo pipefail`; helpers only `return`, never `exit`.

# git_history_deepen (#2053) — the one copy of the un-shallow logic.
if ! declare -F git_history_deepen >/dev/null; then
  # shellcheck source=scripts/lib/git-history.sh
  source "$(dirname "${BASH_SOURCE[0]}")/git-history.sh"
fi

# _brg_rev_blob <rev> <path> — echo the blob SHA of <path> at <rev>, or `absent`.
_brg_rev_blob() {
  git rev-parse --verify --quiet "${1}:${2}" 2>/dev/null || echo "absent"
}

# _brg_worktree_blob <path> — echo the blob SHA the working-tree <path> would be
# stored as, or `absent`.
_brg_worktree_blob() {
  local p="$1"
  if [[ -L "$p" ]]; then
    printf '%s' "$(readlink -- "$p")" | git hash-object --stdin
  elif [[ -f "$p" ]]; then
    git hash-object -- "$p"
  else
    echo "absent"
  fi
}

# brg_find_residue <base_ref>
#   Impure. Echoes, one per line, every uncommitted path that restores a PR file
#   to its base content (see THE RULE). Returns 0 (possibly with no output), or 2
#   with the reason on stderr when origin/<base_ref> or the merge base cannot be
#   resolved. Uses the LOCAL origin/<base_ref> — the ref the agent session saw —
#   and fetches only when it is missing.
brg_find_residue() {
  local base="${1:-}" tip mb path wt
  if [[ -z "$base" ]]; then
    echo "base-residue guard: no base ref given" >&2
    return 2
  fi
  git_history_deepen "$base"
  if ! tip=$(git rev-parse --verify --quiet "origin/${base}^{commit}" 2>/dev/null); then
    git fetch --quiet origin "+refs/heads/${base}:refs/remotes/origin/${base}" 2>/dev/null || true
    tip=$(git rev-parse --verify --quiet "origin/${base}^{commit}" 2>/dev/null) || tip=""
  fi
  if [[ -z "$tip" ]]; then
    echo "base-residue guard: origin/${base} does not resolve" >&2
    return 2
  fi
  mb=$(git merge-base "$tip" HEAD 2>/dev/null) || mb=""
  if [[ -z "$mb" ]]; then
    echo "base-residue guard: no merge base between origin/${base} and HEAD" >&2
    return 2
  fi

  local pr_paths dirty
  pr_paths=$(git -c core.quotePath=false diff --no-renames --name-only "$mb" HEAD 2>/dev/null) || {
    echo "base-residue guard: git diff ${mb}..HEAD failed" >&2
    return 2
  }
  [[ -n "$pr_paths" ]] || return 0
  dirty=$( {
    git -c core.quotePath=false diff --no-renames --name-only HEAD 2>/dev/null
    git -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null
  } | sort -u)
  [[ -n "$dirty" ]] || return 0

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    grep -qxF -- "$path" <<<"$pr_paths" || continue
    wt=$(_brg_worktree_blob "$path")
    [[ "$wt" != "$(_brg_rev_blob HEAD "$path")" ]] || continue
    if [[ "$wt" == "$(_brg_rev_blob "$mb" "$path")" || "$wt" == "$(_brg_rev_blob "$tip" "$path")" ]]; then
      printf '%s\n' "$path"
    fi
  done <<<"$dirty"
  return 0
}

# brg_drop_residue <path>...
#   Impure. Restores each path to HEAD in both the index and the working tree; a
#   path HEAD does not have is removed from both. Returns non-zero if any restore
#   fails.
brg_drop_residue() {
  local path rc=0
  for path in "$@"; do
    [[ -n "$path" ]] || continue
    if git cat-file -e "HEAD:${path}" 2>/dev/null; then
      git --literal-pathspecs restore --source=HEAD --staged --worktree -- "$path" || rc=1
    else
      git --literal-pathspecs rm -q --cached --ignore-unmatch -- "$path" >/dev/null || rc=1
      rm -f -- "$path" || rc=1
    fi
  done
  return "$rc"
}
