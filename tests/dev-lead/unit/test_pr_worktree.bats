#!/usr/bin/env bats
# Unit tests for scripts/lib/pr-worktree.sh
#
# Regression coverage for issue #448: checking out a PR branch must NOT remove
# the agent's own prompt/script files from the working tree. The library
# isolates the PR branch in a separate git worktree, so the agent checkout —
# and an absolute PROMPTS_DIR pinned to it — survives the branch switch.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/pr-worktree.sh"

setup() {
  STUB_BIN_DIR="$(mktemp -d)"
  # PR_STATE_API controls the state returned by the gh stub's `pr view` JSON response.
  # Set unconditionally so the runner environment cannot leak in and break unrelated tests.
  export PR_STATE_API="OPEN"

  # gh stub: `gh pr checkout <n>` switches the worktree to the PR branch,
  # mirroring the real command (which is what made the old prompt files vanish).
  # `gh pr view` returns a JSON object with state and headRefName so the combined
  # call in checkout_pr_in_worktree handles both the closed-PR guard (issue #405)
  # and the stale-worktree release (issue #470) in a single round-trip.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  "pr checkout"*) git checkout -q old ;;
  "pr view"*)     echo "{\"state\": \"${PR_STATE_API:-OPEN}\", \"headRefName\": \"old\", \"isCrossRepository\": ${PR_CROSS_API:-false}}" ;;
  *)              echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export PATH="$STUB_BIN_DIR:$PATH"

  # Repo with a `main` branch that has prompts/x.md and an `old` branch that
  # predates it — the exact shape that broke run 27077585464.
  AGENT_REPO="$(mktemp -d)"
  git -C "$AGENT_REPO" init -q -b main
  git -C "$AGENT_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$AGENT_REPO" branch old
  mkdir -p "$AGENT_REPO/prompts"
  echo "PROMPT BODY" > "$AGENT_REPO/prompts/x.md"
  git -C "$AGENT_REPO" add prompts/x.md
  git -C "$AGENT_REPO" -c user.email=t@t -c user.name=t commit -q -m "add prompt"
}

teardown() {
  rm -rf "$STUB_BIN_DIR" "$AGENT_REPO"
}

@test "resolve_abs: leaves an absolute path unchanged" {
  source "$LIB"
  run resolve_abs /etc
  [ "$status" -eq 0 ]
  [ "$output" = "/etc" ]
}

@test "resolve_abs: converts an existing relative path to absolute" {
  source "$LIB"
  cd "$AGENT_REPO"
  run resolve_abs prompts
  [ "$status" -eq 0 ]
  [ "$output" = "$AGENT_REPO/prompts" ]
}

@test "resolve_abs: returns a non-existent path unchanged" {
  source "$LIB"
  run resolve_abs does/not/exist
  [ "$status" -eq 0 ]
  [ "$output" = "does/not/exist" ]
}

@test "checkout_pr_in_worktree: PR branch switch does not clobber the agent prompts" {
  source "$LIB"
  cd "$AGENT_REPO"
  # Pin PROMPTS_DIR before entering the worktree, as the real scripts do.
  local prompts; prompts="$(resolve_abs prompts)"

  checkout_pr_in_worktree 42 owner/repo

  # We are now inside the worktree, on the `old` branch where prompts/x.md
  # never existed — proving the branch switch really happened here.
  [ "$PWD" = "$PR_WORKTREE_DIR" ]
  [ ! -e "$PWD/prompts/x.md" ]

  # The agent checkout (and the absolute PROMPTS_DIR pointing at it) is intact:
  # this is the guarantee that issue #448 broke.
  [ -f "$prompts/x.md" ]
  [ "$(cat "$prompts/x.md")" = "PROMPT BODY" ]

  cleanup_pr_worktree
}

@test "cleanup_pr_worktree: removes the worktree and returns to the agent checkout" {
  source "$LIB"
  cd "$AGENT_REPO"

  checkout_pr_in_worktree 42 owner/repo
  local wt="$PR_WORKTREE_DIR"
  [ -d "$wt" ]

  cleanup_pr_worktree

  [ "$PWD" = "$AGENT_REPO" ]
  [ ! -d "$wt" ]
  [ -z "$PR_WORKTREE_DIR" ]
  # Registry no longer references the removed worktree.
  run git -C "$AGENT_REPO" worktree list
  [[ "$output" != *"$wt"* ]]
}

@test "cleanup_pr_worktree: is a no-op when no worktree is active" {
  source "$LIB"
  PR_WORKTREE_DIR=""
  run cleanup_pr_worktree
  [ "$status" -eq 0 ]
}

@test "checkout_pr_in_worktree: chains onto a pre-existing EXIT trap (does not clobber it)" {
  # The scripts register restore_auto_merge as an EXIT trap BEFORE checking out
  # the worktree; checkout must preserve it so auto-merge is still restored.
  source "$LIB"
  cd "$AGENT_REPO"
  trap 'echo PRIOR' EXIT

  checkout_pr_in_worktree 42 owner/repo

  local current
  current="$(trap -p EXIT)"
  [[ "$current" == *cleanup_pr_worktree* ]]
  [[ "$current" == *"echo PRIOR"* ]]

  cleanup_pr_worktree
  trap - EXIT
}

# --- issue #470: PR-branch worktree-collision recovery -----------------------
# `gh pr checkout` fails with "'<branch>' is already used by worktree at ..."
# when a crashed prior run on the same runner left the PR's head branch claimed.
# checkout_pr_in_worktree must release the branch before checking it out.

@test "checkout_pr_in_worktree: recovers when PR branch is held by a stale sibling worktree" {
  source "$LIB"
  cd "$AGENT_REPO"

  # Simulate a crashed prior run: the PR branch (`old`) is checked out in a
  # leftover sibling worktree that is still registered AND still on disk.
  local stale_parent stale
  stale_parent="$(mktemp -d)"; stale="$stale_parent/stale-wt"
  git -C "$AGENT_REPO" worktree add --quiet "$stale" old
  run git -C "$AGENT_REPO" worktree list
  [[ "$output" == *"$stale"* ]]

  # Without the fix this aborts with "already used by worktree".
  checkout_pr_in_worktree 383 owner/repo

  [ "$PWD" = "$PR_WORKTREE_DIR" ]
  # We are on the PR branch in the fresh worktree (prompts/x.md absent on `old`).
  [ ! -e "$PWD/prompts/x.md" ]
  # The stale worktree was released.
  run git -C "$AGENT_REPO" worktree list
  [[ "$output" != *"$stale"* ]]

  cleanup_pr_worktree
  rm -rf "$stale_parent"
}

@test "checkout_pr_in_worktree: recovers from a stale registry entry whose dir is gone" {
  source "$LIB"
  cd "$AGENT_REPO"

  # Crashed run left a registry entry for `old`, but the directory was deleted
  # out from under git (no `git worktree remove`). prune must clear it.
  local stale_parent stale
  stale_parent="$(mktemp -d)"; stale="$stale_parent/gone-wt"
  git -C "$AGENT_REPO" worktree add --quiet "$stale" old
  rm -rf "$stale"

  checkout_pr_in_worktree 383 owner/repo

  [ "$PWD" = "$PR_WORKTREE_DIR" ]
  [ ! -e "$PWD/prompts/x.md" ]

  cleanup_pr_worktree
  rm -rf "$stale_parent"
}

@test "checkout_pr_in_worktree: recovers when the agent checkout itself holds the PR branch" {
  source "$LIB"
  cd "$AGENT_REPO"
  # The agent's own checkout is on the PR branch (`old`). It must be detached in
  # place (never removed) so the new worktree can claim the branch.
  git -C "$AGENT_REPO" checkout -q old

  checkout_pr_in_worktree 383 owner/repo

  [ "$PWD" = "$PR_WORKTREE_DIR" ]
  [ ! -e "$PWD/prompts/x.md" ]

  cleanup_pr_worktree

  # The agent checkout still exists and is usable (was detached in place, not
  # removed) — and it no longer holds the `old` branch, so a future checkout of
  # the same PR won't collide on it.
  [ -d "$AGENT_REPO/.git" ]
  run git -C "$AGENT_REPO" symbolic-ref -q HEAD
  [ "$status" -ne 0 ]   # detached HEAD has no symbolic ref
}

@test "checkout_pr_in_worktree: detaches agent checkout even when invoked from a subdirectory" {
  # `git worktree list` reports the worktree ROOT, but PR_WORKTREE_AGENT_DIR is
  # captured from pwd — here a SUBDIRECTORY of the repo. The comparison must
  # resolve to the repo top-level so the agent checkout is still recognized and
  # detached (regression guard for the PR #494 review finding).
  source "$LIB"
  git -C "$AGENT_REPO" checkout -q old
  mkdir -p "$AGENT_REPO/prompts"   # a real subdir to run from
  cd "$AGENT_REPO/prompts"

  checkout_pr_in_worktree 383 owner/repo

  [ "$PWD" = "$PR_WORKTREE_DIR" ]
  [ ! -e "$PWD/prompts/x.md" ]

  cleanup_pr_worktree

  # Agent checkout preserved (detached, not removed despite the subdir cwd).
  [ -d "$AGENT_REPO/.git" ]
  run git -C "$AGENT_REPO" symbolic-ref -q HEAD
  [ "$status" -ne 0 ]
}

# --- issue #405: merged/closed PR early-exit guard ---------------------------
# When a trusted-bot comment arrives on an already-merged PR (branch deleted),
# checkout_pr_in_worktree must exit 0 cleanly rather than crashing with
# "fatal: couldn't find remote ref" from `gh pr checkout`.

@test "checkout_pr_in_worktree: exits cleanly when PR is already merged (MERGED state)" {
  source "$LIB"
  cd "$AGENT_REPO"
  export PR_STATE_API="MERGED"

  run checkout_pr_in_worktree 519 owner/repo

  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #519 is MERGED"* ]]
  [[ "$output" == *"skipping checkout"* ]]
  # The agent repo must NOT have been switched to another branch by gh pr checkout.
  [ "$(git -C "$AGENT_REPO" rev-parse --abbrev-ref HEAD)" = "main" ]
}

@test "checkout_pr_in_worktree: a head in another repository is not checked out" {
  source "$LIB"
  cd "$AGENT_REPO"
  export PR_CROSS_API="true"

  run checkout_pr_in_worktree 7 owner/repo

  [ "$status" -eq 0 ]
  [[ "$output" == *"head in another repository"* ]]
  [ "$(git -C "$AGENT_REPO" rev-parse --abbrev-ref HEAD)" = "main" ]
  [ "$(git -C "$AGENT_REPO" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]
}

@test "checkout_pr_in_worktree: an unreadable head location fails closed" {
  source "$LIB"
  cd "$AGENT_REPO"
  export PR_CROSS_API="null"

  run checkout_pr_in_worktree 7 owner/repo

  [ "$status" -eq 1 ]
  [[ "$output" == *"could not confirm"* ]]
  [ "$(git -C "$AGENT_REPO" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]
}

@test "checkout_pr_in_worktree: a failed PR lookup fails closed" {
  source "$LIB"
  cd "$AGENT_REPO"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_BIN_DIR/gh"

  run checkout_pr_in_worktree 7 owner/repo

  [ "$status" -eq 1 ]
  [[ "$output" == *"could not confirm"* ]]
  [ "$(git -C "$AGENT_REPO" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]
}

@test "checkout_pr_in_worktree: exits cleanly when PR is closed without merge (CLOSED state)" {
  source "$LIB"
  cd "$AGENT_REPO"
  export PR_STATE_API="CLOSED"

  run checkout_pr_in_worktree 99 owner/repo

  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #99 is CLOSED"* ]]
  [[ "$output" == *"skipping checkout"* ]]
  [ "$(git -C "$AGENT_REPO" rev-parse --abbrev-ref HEAD)" = "main" ]
}
