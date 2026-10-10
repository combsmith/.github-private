#!/usr/bin/env bats
# Unit tests for scripts/lib/git-push-guard.sh :: incorporate_remote_head +
# push_no_clobber's stale-base guard (#1607).
#
# Regression for the #1604 destruction: dev-lead force-pushed a branch it had
# rebuilt from a stale base, silently discarding a maintainer steering commit
# pushed to the branch after dev-lead's last fetch. Before pushing, dev-lead
# must fetch the true remote head and INCORPORATE it (rebase onto it) — or, when
# it cannot be incorporated cleanly, STOP and escalate rather than force over it.
# A commit authored by anyone other than dev-lead's own identity is steering:
# never discarded, and called out in the run summary.

BOT_EMAIL_SUFFIX="don-petry@users.noreply.github.com"

setup() {
  GUARD_LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/scripts/lib/git-push-guard.sh"

  # dev-lead acts as `don-petry`; classify by the bot's noreply email.
  export BOT_USER="don-petry"

  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  WORK="$BATS_TEST_TMPDIR/work"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  : > "$GITHUB_STEP_SUMMARY"

  git init -q --bare "$REMOTE"
  local seed="$BATS_TEST_TMPDIR/seed"
  git init -q "$seed"
  (
    cd "$seed"
    _dev_identity
    echo A > base; git add base; git commit -q -m A
    git branch -M main
    git remote add origin "$REMOTE"
    git push -q -u origin main
  )
  git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main

  git clone -q "$REMOTE" "$WORK"
  ( cd "$WORK"; _dev_identity )
}

# dev-lead's own git identity (bot noreply email → classified as OWN).
_dev_identity() {
  git config user.email "12345+${BOT_EMAIL_SUFFIX}"
  git config user.name "don-petry"
}

# A maintainer pushing directly to the branch — a DIFFERENT identity (steering).
_maintainer_push() {
  local file="$1" content="$2"
  local other="$BATS_TEST_TMPDIR/maintainer.$RANDOM"
  git clone -q "$REMOTE" "$other"
  (
    cd "$other"
    git config user.email "someone@corp.example"
    git config user.name "Human Maintainer"
    printf '%s\n' "$content" > "$file"; git add "$file"
    git commit -q -m "steering: $file"
    git push -q origin main
  )
}

_remote_head() { git --git-dir="$REMOTE" rev-parse main; }
_remote_log()  { git --git-dir="$REMOTE" log --format='%s' main; }

@test "AC5: a maintainer commit pushed after dev-lead's last fetch survives — head contains BOTH" {
  cd "$WORK"
  source "$GUARD_LIB"

  # dev-lead makes its fix on a non-conflicting file.
  echo devfix > devfix; git add devfix; git commit -q -m "dev-lead fix"

  # Maintainer pushes a steering commit to the same branch AFTER dev-lead's
  # last fetch (dev-lead's origin/main is stale).
  _maintainer_push steering.txt "keep me"

  run push_no_clobber origin main
  [ "$status" -eq 0 ]

  # Both the maintainer's file and dev-lead's file are present on the remote.
  local head_tree; head_tree=$(git --git-dir="$REMOTE" ls-tree --name-only -r main)
  echo "$head_tree" | grep -qx steering.txt
  echo "$head_tree" | grep -qx devfix

  # Both commits are in the remote history.
  _remote_log | grep -q "steering: steering.txt"
  _remote_log | grep -q "dev-lead fix"
}

@test "AC4: incorporating a steering commit is called out in the run summary" {
  cd "$WORK"
  source "$GUARD_LIB"
  echo devfix > devfix; git add devfix; git commit -q -m "dev-lead fix"
  _maintainer_push steering.txt "keep me"

  run push_no_clobber origin main
  [ "$status" -eq 0 ]
  grep -qi 'steering' "$GITHUB_STEP_SUMMARY"
}

@test "AC1/AC2: an un-incorporable steering commit is NOT force-pushed over — escalate, remote preserved" {
  cd "$WORK"
  source "$GUARD_LIB"

  # dev-lead edits the shared file...
  printf 'dev-lead line\n' >> base; git add base; git commit -q -m "dev-lead edits base"
  # ...and the maintainer edits the SAME region, creating a rebase conflict.
  _maintainer_push base "maintainer rewrite of base"
  local preserved; preserved=$(_remote_head)

  run push_no_clobber origin main
  [ "$status" -ne 0 ]
  # The steering commit is untouched on the remote.
  [ "$(_remote_head)" = "$preserved" ]
  grep -qi 'steering' "$GITHUB_STEP_SUMMARY"
}

@test "own-rewrite (dev-lead amends its own commit) still force-with-leases cleanly" {
  cd "$WORK"
  source "$GUARD_LIB"

  # dev-lead pushes its own commit, then amends it (a legitimate self-rewrite).
  echo v1 > work; git add work; git commit -q -m "dev-lead work"
  push_no_clobber origin main
  echo v2 > work; git add work; git commit -q --amend -m "dev-lead work v2"
  local amended; amended=$(git rev-parse HEAD)

  run push_no_clobber origin main
  [ "$status" -eq 0 ]
  [ "$(_remote_head)" = "$amended" ]
}

@test "AC3: a force-push logs the discarded SHA(s)" {
  cd "$WORK"
  source "$GUARD_LIB"
  echo v1 > work; git add work; git commit -q -m "dev-lead work"
  push_no_clobber origin main
  local discarded; discarded=$(git rev-parse HEAD)
  echo v2 > work; git add work; git commit -q --amend -m "dev-lead work v2"

  run push_no_clobber origin main
  [ "$status" -eq 0 ]
  # The overwritten commit SHA appears in the guard's output for audit.
  echo "$output" | grep -q "${discarded:0:12}"
}

@test "security: only the exact bot noreply local-part is classified as dev-lead (#1610)" {
  cd "$WORK"
  source "$GUARD_LIB"

  # Exact login as the whole local part → OWN.
  GIT_COMMITTER_EMAIL="don-petry@users.noreply.github.com" \
    git commit -q --allow-empty -m bare
  run _commit_is_dev_lead HEAD
  [ "$status" -eq 0 ]

  # Numeric user-id prefix + login → OWN.
  GIT_COMMITTER_EMAIL="12345+don-petry@users.noreply.github.com" \
    git commit -q --allow-empty -m idprefix
  run _commit_is_dev_lead HEAD
  [ "$status" -eq 0 ]

  # A spoofed local part that merely ENDS WITH the login is FOREIGN (steering).
  GIT_COMMITTER_EMAIL="attacker-don-petry@users.noreply.github.com" \
    git commit -q --allow-empty -m spoof
  run _commit_is_dev_lead HEAD
  [ "$status" -ne 0 ]

  # A non-numeric prefix before "+login" is also FOREIGN.
  GIT_COMMITTER_EMAIL="evil+don-petry@users.noreply.github.com" \
    git commit -q --allow-empty -m evilprefix
  run _commit_is_dev_lead HEAD
  [ "$status" -ne 0 ]
}

@test "no divergence: plain fast-forward push still works" {
  cd "$WORK"
  source "$GUARD_LIB"
  echo ff > ff; git add ff; git commit -q -m "ff commit"
  local head; head=$(git rev-parse HEAD)

  run push_no_clobber origin main
  [ "$status" -eq 0 ]
  [ "$(_remote_head)" = "$head" ]
}

# ── #2032: a clean rebase records old→new SHAs ───────────────────────────────
# The model's "Fixed in <sha>" replies cite dev-lead's PRE-rebase commits. When
# the guard rebases them onto a steering commit, those SHAs exist nowhere on the
# remote, so the claim sweep needs the map to keep the claims that did land.

@test "#2032: a clean rebase onto steering records each dev-lead commit's rebased SHA" {
  cd "$WORK"
  source "$GUARD_LIB"
  echo one > one; git add one; git commit -q -m "dev-lead fix one"
  local old1; old1=$(git rev-parse HEAD)
  echo two > two; git add two; git commit -q -m "dev-lead fix two"
  local old2; old2=$(git rev-parse HEAD)
  _maintainer_push steering.txt "keep me"

  push_no_clobber origin main
  local new2 new1
  new2=$(git rev-parse HEAD); new1=$(git rev-parse HEAD~1)
  [ "$new2" != "$old2" ]
  [ "$(_remote_head)" = "$new2" ]
  grep -qx "${old1}"$'\t'"${new1}" <<<"$_PUSH_GUARD_REWRITES"
  grep -qx "${old2}"$'\t'"${new2}" <<<"$_PUSH_GUARD_REWRITES"
  [ "$(grep -c . <<<"$_PUSH_GUARD_REWRITES")" -eq 2 ]
}

@test "#2032: no rebase (plain fast-forward) records no rewrites" {
  cd "$WORK"
  source "$GUARD_LIB"
  echo ff > ff; git add ff; git commit -q -m "ff commit"
  push_no_clobber origin main
  [ -z "$_PUSH_GUARD_REWRITES" ]
}

@test "#2032: an un-incorporable steering commit records no rewrites" {
  cd "$WORK"
  source "$GUARD_LIB"
  printf 'dev-lead line\n' >> base; git add base; git commit -q -m "dev-lead edits base"
  _maintainer_push base "maintainer rewrite of base"
  local push_status=0
  push_no_clobber origin main || push_status=$?
  [ "$push_status" -ne 0 ]
  [ -z "$_PUSH_GUARD_REWRITES" ]
}

@test "#2032: _push_guard_rewrite_map pairs only unique keys" {
  source "$GUARD_LIB"
  local old new
  old=$(printf 'o1\tk1\no2\tk2\no3\tdup\no4\tdup\no5\tgone\n')
  new=$(printf 'n1\tk1\nn2\tk2\nn3\tdup\nn4\tdup\n')
  run _push_guard_rewrite_map "$old" "$new"
  [ "$status" -eq 0 ]
  [ "$(sort <<<"$output")" = "$(printf 'o1\tn1\no2\tn2')" ]
}
