#!/usr/bin/env bats
# Unit tests for scripts/lib/base-residue-guard.sh (#2216).
#
# On PR #2198 a fix-bot-comment session left origin/main's content for the PR's
# files in the working tree (the `git checkout origin/main -- .` shape), and the
# harness's `git add -A` committed the exact inverse of the PR. The rule: the
# agent's own commits may revert PR files, uncommitted residue may not. Residue
# is found here and dropped before the harness stages anything.

bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/base-residue-guard.sh"

_commit() {
  git add -A
  git -c user.email=t@test -c user.name=T commit -q -m "$1"
}

setup() {
  # shellcheck source=scripts/lib/base-residue-guard.sh
  source "$LIB"
  REPO_DIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO_DIR"
  cd "$REPO_DIR"
  git init -q
  printf 'a-base\n' > a.txt
  printf 'b-base\n' > b.txt
  printf 'c-base\n' > c.txt
  printf 'gone\n' > gone.txt
  _commit base
  BASE_SHA=$(git rev-parse HEAD)
  git update-ref refs/remotes/origin/main "$BASE_SHA"
  # The PR: edits a.txt and b.txt, adds new.txt, deletes gone.txt.
  printf 'a-base\na-pr\n' > a.txt
  printf 'b-base\nb-pr\n' > b.txt
  printf 'new\n' > new.txt
  rm gone.txt
  _commit "feat: the PR"
}

@test "base-residue-guard.sh is safe to source under set -euo pipefail" {
  run bash -c "set -euo pipefail; source '$LIB'"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "brg_find_residue: a clean worktree has no residue" {
  run brg_find_residue main
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "brg_find_residue: total revert — 'git checkout origin/main -- .' is residue on every PR file it touches (#2198)" {
  git checkout -q origin/main -- .
  run brg_find_residue main
  [[ "$status" -eq 0 ]]
  [[ "$output" == $'a.txt\nb.txt\ngone.txt' ]]
}

@test "brg_find_residue: partial revert — only the restored PR file is residue; real edits are not" {
  git checkout -q origin/main -- a.txt
  printf 'b-base\nb-pr\nb-fix\n' > b.txt   # a real fix to a PR file
  printf 'c-base\nc-fix\n' > c.txt         # a real fix outside the PR's files
  run brg_find_residue main
  [[ "$status" -eq 0 ]]
  [[ "$output" == "a.txt" ]]
}

@test "brg_find_residue: removing a file the PR added is residue (absent at base)" {
  rm new.txt
  run brg_find_residue main
  [[ "$status" -eq 0 ]]
  [[ "$output" == "new.txt" ]]
}

@test "brg_find_residue: an untracked copy of a file the PR deleted is residue" {
  git show "${BASE_SHA}:gone.txt" > gone.txt
  run brg_find_residue main
  [[ "$status" -eq 0 ]]
  [[ "$output" == "gone.txt" ]]
}

@test "brg_find_residue: base moved ahead — content of the origin/<base> tip is residue too" {
  git checkout -q "$BASE_SHA" 2>/dev/null
  printf 'a-main-moved\n' > a.txt
  _commit "main moves"
  git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)"
  git checkout -q -
  git checkout -q origin/main -- a.txt
  run brg_find_residue main
  [[ "$status" -eq 0 ]]
  [[ "$output" == "a.txt" ]]
}

@test "brg_find_residue: a mode-only PR change restored to base is residue" {
  chmod +x c.txt
  _commit "chore: make c.txt executable"
  git checkout -q origin/main -- c.txt
  run brg_find_residue main
  [[ "$status" -eq 0 ]]
  [[ "$output" == "c.txt" ]]
}

@test "brg_find_residue: an agent COMMIT that reverts a PR file is not residue (eb763aa8 shape)" {
  git checkout -q origin/main -- a.txt
  _commit "fix: restore a.txt to main"
  run brg_find_residue main
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "brg_find_residue: an unresolvable base fails open (rc 2, no paths)" {
  git checkout -q origin/main -- .
  run --separate-stderr brg_find_residue no-such-branch
  [[ "$status" -eq 2 ]]
  [[ -z "$output" ]]
  [[ "$stderr" == *"origin/no-such-branch does not resolve"* ]]
}

@test "brg_drop_residue: total revert is dropped back to HEAD — nothing left to commit" {
  git checkout -q origin/main -- .
  mapfile -t paths < <(brg_find_residue main)
  brg_drop_residue "${paths[@]}"
  [[ -z "$(git status --porcelain)" ]]
}

@test "brg_drop_residue: partial revert drops only the residue and keeps real edits" {
  git checkout -q origin/main -- a.txt
  printf 'c-base\nc-fix\n' > c.txt
  mapfile -t paths < <(brg_find_residue main)
  brg_drop_residue "${paths[@]}"
  [[ "$(git status --porcelain)" == " M c.txt" ]]
  [[ "$(cat a.txt)" == $'a-base\na-pr' ]]
}

@test "brg_drop_residue: removes a residue file HEAD does not have, staged or untracked" {
  git checkout -q origin/main -- gone.txt   # staged re-add
  brg_drop_residue gone.txt
  [[ ! -e gone.txt ]]
  [[ -z "$(git status --porcelain)" ]]
  git show "${BASE_SHA}:gone.txt" > gone.txt  # untracked re-add
  brg_drop_residue gone.txt
  [[ ! -e gone.txt ]]
  [[ -z "$(git status --porcelain)" ]]
}
