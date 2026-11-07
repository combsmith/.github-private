#!/usr/bin/env bats
# Unit tests for scripts/lib/git-push-guard.sh :: push_no_clobber (#1311).
#
# Defense-in-depth for the concurrent-writer race: after dev-lead's agent runs,
# the push must never discard a commit dev-lead did not fetch. A plain
# fast-forward push can only ever be REJECTED (never overwrites); a rewritten
# (rebased) branch is retried with --force-with-lease, which ABORTS if the
# remote advanced beyond the last-seen remote-tracking ref. A bare --force is
# never used.

setup() {
  GUARD_LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/scripts/lib/git-push-guard.sh"

  # dev-lead acts as `don-petry`. The seed commit stands for an earlier dev-lead
  # run: it carries a Dev-Lead-Stamp, so the #1607/#2313 guard classifies it as
  # OWN (a self-rewrite may be force-with-leased) rather than foreign steering
  # (which is never discarded). The email alone would not (#2313).
  export BOT_USER="don-petry"

  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  WORK="$BATS_TEST_TMPDIR/work"

  # Bare remote seeded with commit A on `main` (stamped by dev-lead).
  git init -q --bare "$REMOTE"
  local seed="$BATS_TEST_TMPDIR/seed"
  git init -q "$seed"
  (
    cd "$seed"
    source "$GUARD_LIB"
    git config user.email "1+don-petry@users.noreply.github.com"; git config user.name don-petry
    echo A > f; git add f; git commit -q -m A -m "$(dev_lead_stamp_trailer)"
    git branch -M main
    git remote add origin "$REMOTE"
    git push -q -u origin main
  )
  # Point the bare remote's HEAD at main so fresh clones check it out.
  git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main

  # dev-lead's working checkout (origin/main tracked, last seen = A).
  git clone -q "$REMOTE" "$WORK"
  ( cd "$WORK"; git config user.email "1+don-petry@users.noreply.github.com"; git config user.name don-petry )
}

# Advance the remote's `main` from an independent clone (a concurrent writer)
# WITHOUT updating $WORK's remote-tracking ref — simulates an unseen commit.
_advance_remote() {
  local other="$BATS_TEST_TMPDIR/other"
  git clone -q "$REMOTE" "$other"
  (
    cd "$other"
    git config user.email o@o.co; git config user.name o
    echo C >> f; git add f; git commit -q -m C
    git push -q origin main
  )
}

_remote_head() { git --git-dir="$REMOTE" rev-parse main; }

@test "push_no_clobber: fast-forward push succeeds and updates the remote" {
  cd "$WORK"
  source "$GUARD_LIB"
  echo B >> f; git add f; git commit -q -m B
  local local_head; local_head=$(git rev-parse HEAD)

  run push_no_clobber origin main
  [ "$status" -eq 0 ]
  [ "$(_remote_head)" = "$local_head" ]
}

@test "push_no_clobber: rewritten branch pushes with lease when remote is unchanged" {
  cd "$WORK"
  source "$GUARD_LIB"
  # Rewrite history (rebase-like) so the branch diverges from origin/main.
  echo A2 > f; git add f; git commit -q --amend -m A2
  local local_head; local_head=$(git rev-parse HEAD)

  run push_no_clobber origin main
  [ "$status" -eq 0 ]
  [ "$(_remote_head)" = "$local_head" ]
}

@test "push_no_clobber: rewritten branch ABORTS when the remote moved under us — unseen commit survives" {
  cd "$WORK"
  source "$GUARD_LIB"
  # dev-lead rewrites its branch...
  echo A2 > f; git add f; git commit -q --amend -m A2
  # ...but meanwhile a concurrent writer advanced the remote to an unseen commit.
  _advance_remote
  local unseen; unseen=$(_remote_head)

  run push_no_clobber origin main
  [ "$status" -ne 0 ]
  # The unseen commit is preserved — dev-lead did NOT force over it.
  [ "$(_remote_head)" = "$unseen" ]
}

@test "push_no_clobber: non-fast-forward without divergence is refused (no force), remote preserved" {
  cd "$WORK"
  source "$GUARD_LIB"
  # dev-lead adds a commit on top (no rewrite)...
  echo B >> f; git add f; git commit -q -m B
  # ...but the remote advanced to an unseen commit.
  _advance_remote
  local unseen; unseen=$(_remote_head)

  run push_no_clobber origin main
  [ "$status" -ne 0 ]
  [ "$(_remote_head)" = "$unseen" ]
}

@test "push_no_clobber: never invokes a bare --force" {
  # A bare --force would defeat the lease guard entirely. Every force on a
  # `git push` command in the lib must be --force-with-lease. (Scoped to git push
  # invocations so prose in comments does not trip the check.)
  local bare
  bare=$(grep -nE 'git push[^|&]*--force([^-]|$)' "$GUARD_LIB" | grep -v -- '--force-with-lease' || true)
  [ -z "$bare" ]
}

@test "push_no_clobber: every force-with-lease is pinned — explicit value or --force-if-includes (#1607)" {
  # A bare --force-with-lease leases against the remote-tracking ref and is
  # silently defeated by any fetch that refreshed it (the #1604 hole). Every
  # lease in the lib must be pinned: either an explicit =<ref>:<sha> value or
  # paired with --force-if-includes.
  local leased weak
  leased=$(grep -nE 'git push[^|&]*--force-with-lease' "$GUARD_LIB" || true)
  [ -n "$leased" ]
  weak=$(printf '%s\n' "$leased" \
    | grep -v -- '--force-if-includes' \
    | grep -v -- '--force-with-lease=' || true)
  [ -z "$weak" ]
}
