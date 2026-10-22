#!/usr/bin/env bats
# Unit tests for scripts/lib/git-push-guard.sh :: incorporate_remote_head +
# push_no_clobber's stale-base guard (#1607).
#
# Regression for the #1604 destruction: dev-lead force-pushed a branch it had
# rebuilt from a stale base, silently discarding a maintainer steering commit
# pushed to the branch after dev-lead's last fetch. Before pushing, dev-lead
# must fetch the true remote head and INCORPORATE it (rebase onto it) — or, when
# it cannot be incorporated cleanly, STOP and escalate rather than force over it.
# A commit dev-lead has no record of writing is steering: never discarded, and
# called out in the run summary. Since #2313 that record is the SHAs this run
# pushed or a Dev-Lead-Stamp trailer, never the committer email — the owner
# commits with the same noreply address dev-lead does.

BOT_EMAIL_SUFFIX="don-petry@users.noreply.github.com"

setup() {
  GUARD_LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/scripts/lib/git-push-guard.sh"

  # dev-lead acts as `don-petry` (ADR-0008), the same account the owner uses.
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

# dev-lead's git identity. Since ADR-0008 the owner commits with it too, so it
# classifies nothing on its own (#2313).
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

# ── #2313: ownership comes from dev-lead's records, not the committer email ──
# The owner, every Claude Code session on the owner's machine and dev-lead all
# commit as <id>+don-petry@users.noreply.github.com. On combsmith/.github #1314
# and #1315 the owner's commits were classified as dev-lead's and force-pushed
# over.

# The owner pushing to the branch with dev-lead's EXACT identity.
_owner_push() {
  local file="$1" content="$2"
  local other="$BATS_TEST_TMPDIR/owner.$RANDOM"
  git clone -q "$REMOTE" "$other"
  (
    cd "$other"
    _dev_identity
    printf '%s\n' "$content" > "$file"; git add "$file"
    git commit -q -m "owner: $file"
    git push -q origin main
  )
}

# An earlier dev-lead run: a stamped commit pushed from its own clone.
_earlier_run_push() {
  local file="$1" content="$2"
  local other="$BATS_TEST_TMPDIR/earlier.$RANDOM"
  git clone -q "$REMOTE" "$other"
  (
    cd "$other"
    _dev_identity
    source "$GUARD_LIB"
    printf '%s\n' "$content" > "$file"; git add "$file"
    git commit -q -m "dev-lead: $file" -m "$(dev_lead_stamp_trailer)"
    git push -q origin main
  )
}

@test "#2313: an owner commit with dev-lead's exact email is kept, not force-pushed over" {
  cd "$WORK"
  source "$GUARD_LIB"
  _PUSH_GUARD_PUSHED=""
  # The #1314 shape: dev-lead builds a commit on the head it checked out...
  echo devfix > devfix; git add devfix; git commit -q -m "dev-lead fix"
  # ...while the owner pushes a fix to the same branch with the same identity.
  _owner_push owner.txt "the approved fix"
  local owner_sha; owner_sha=$(_remote_head)
  [ "$(git --git-dir="$REMOTE" log -1 --format=%ce main)" = "$(git log -1 --format=%ce HEAD)" ]

  run push_no_clobber origin main
  [ "$status" -eq 0 ]
  # The owner's commit is still on the branch, under dev-lead's.
  git --git-dir="$REMOTE" merge-base --is-ancestor "$owner_sha" main
  local head_tree; head_tree=$(git --git-dir="$REMOTE" ls-tree --name-only -r main)
  echo "$head_tree" | grep -qx owner.txt
  echo "$head_tree" | grep -qx devfix
  # And the run says so.
  grep -q 'owner: owner.txt' "$GITHUB_STEP_SUMMARY"
  # The owner's commit entered neither ledger: a second push in this run, or a
  # later run, still sees it as foreign.
  run grep -qxF "$owner_sha" <<<"$_PUSH_GUARD_PUSHED"
  [ "$status" -ne 0 ]
  run git --git-dir="$REMOTE" notes --ref=refs/notes/dev-lead-pushed list "$owner_sha"
  [ "$status" -ne 0 ]
  run _commit_is_dev_lead "$owner_sha"
  [ "$status" -ne 0 ]
}

@test "#2313: an owner commit with dev-lead's email that conflicts stops the push" {
  cd "$WORK"
  source "$GUARD_LIB"
  printf 'dev-lead line\n' >> base; git add base; git commit -q -m "dev-lead edits base"
  _owner_push base "owner rewrite of base"
  local preserved; preserved=$(_remote_head)

  run push_no_clobber origin main
  [ "$status" -eq 2 ]
  [ "$(_remote_head)" = "$preserved" ]
  grep -q 'STOPPED' "$GITHUB_STEP_SUMMARY"
}

@test "#2313: dev-lead's rewrite of a commit an earlier run stamped still force-pushes" {
  _earlier_run_push work v1
  cd "$WORK"
  git pull -q origin main
  source "$GUARD_LIB"
  local stamped; stamped=$(git rev-parse HEAD)
  run _commit_is_dev_lead "$stamped"
  [ "$status" -eq 0 ]

  # This run amends the earlier run's commit: a legitimate self-rewrite.
  echo v2 > work; git add work; git commit -q --amend -m "dev-lead: work v2"
  local amended; amended=$(git rev-parse HEAD)

  run push_no_clobber origin main
  [ "$status" -eq 0 ]
  [ "$(_remote_head)" = "$amended" ]
  echo "$output" | grep -q "${stamped:0:12}"
}

@test "#2313: a commit this run pushed is its own even with no stamp" {
  cd "$WORK"
  source "$GUARD_LIB"
  echo v1 > work; git add work; git commit -q -m "engine commit, unstamped"
  local pushed; pushed=$(git rev-parse HEAD)
  run _commit_is_dev_lead "$pushed"
  [ "$status" -ne 0 ]
  push_no_clobber origin main
  run _commit_is_dev_lead "$pushed"
  [ "$status" -eq 0 ]
  grep -qxF "$pushed" <<<"$_PUSH_GUARD_PUSHED"
}

@test "#2313: a stamp copied onto another author's commit is not trusted" {
  _earlier_run_push work v1
  # The owner amends dev-lead's stamped commit: new content, same message, so the
  # Dev-Lead-Stamp line is carried over verbatim onto a commit dev-lead never made.
  local other="$BATS_TEST_TMPDIR/owner-amend"
  git clone -q "$REMOTE" "$other"
  (
    cd "$other"
    git config user.email "12345+${BOT_EMAIL_SUFFIX}"
    git config user.name "Don Petry"
    echo "owner fix" > work; git add work
    git commit -q --amend --no-edit
    git push -q --force origin main
  )
  local spoofed; spoofed=$(_remote_head)
  git --git-dir="$REMOTE" log -1 --format=%B main | grep -q '^Dev-Lead-Stamp: '

  cd "$WORK"
  source "$GUARD_LIB"
  run _commit_is_dev_lead "$spoofed"
  [ "$status" -ne 0 ]

  # dev-lead, behind the owner, pushes its own unrelated fix: the owner's commit
  # must survive.
  echo devfix > devfix; git add devfix; git commit -q -m "dev-lead fix"
  run push_no_clobber origin main
  [ "$status" -eq 0 ]
  git --git-dir="$REMOTE" merge-base --is-ancestor "$spoofed" main
  [ "$(git --git-dir="$REMOTE" show main:work)" = "owner fix" ]
}

# A later dev-lead run: a fresh clone of the branch, with an empty in-run ledger.
_later_run_clone() {
  local dir="$BATS_TEST_TMPDIR/later.$RANDOM"
  git clone -q "$REMOTE" "$dir"
  ( cd "$dir"; _dev_identity )
  printf '%s\n' "$dir"
}

@test "#2313: an engine-made commit an earlier run pushed is dev-lead's own via the ledger; its amend force-pushes" {
  cd "$WORK"
  source "$GUARD_LIB"
  # The engine commits with its own `git commit`: no stamp.
  echo v1 > work; git add work; git commit -q -m "fix: engine's own commit"
  local engine_sha; engine_sha=$(git rev-parse HEAD)
  push_no_clobber origin main
  # Pushed exactly as committed — never rewritten — and noted in the remote ledger.
  [ "$(_remote_head)" = "$engine_sha" ]
  git --git-dir="$REMOTE" notes --ref=refs/notes/dev-lead-pushed list "$engine_sha"

  # A later run: fresh clone, empty in-run ledger.
  local later; later=$(_later_run_clone)
  cd "$later"
  _PUSH_GUARD_PUSHED=""
  source "$GUARD_LIB"
  echo v2 > work; git add work; git commit -q --amend -m "fix: engine's own commit v2"
  local amended; amended=$(git rev-parse HEAD)

  run push_no_clobber origin main
  [ "$status" -eq 0 ]
  [ "$(_remote_head)" = "$amended" ]
  echo "$output" | grep -q "${engine_sha:0:12}"
  run grep -q 'STOPPED' "$GITHUB_STEP_SUMMARY"
  [ "$status" -ne 0 ]
  # The amended copy is noted as well; the copy dev-lead never pushed is not.
  git --git-dir="$REMOTE" notes --ref=refs/notes/dev-lead-pushed list "$amended"
}

@test "#2313: the ledger never vouches for a copy — an owner amend of a noted commit is foreign" {
  cd "$WORK"
  source "$GUARD_LIB"
  echo v1 > work; git add work; git commit -q -m "fix: engine's own commit"
  push_no_clobber origin main
  # The owner amends dev-lead's pushed commit with the same identity.
  local other="$BATS_TEST_TMPDIR/owner-amend-noted"
  git clone -q "$REMOTE" "$other"
  (
    cd "$other"; _dev_identity
    echo "owner fix" > work; git add work; git commit -q --amend --no-edit
    git push -q --force origin main
  )
  local owner_sha; owner_sha=$(_remote_head)

  local later; later=$(_later_run_clone)
  cd "$later"
  _PUSH_GUARD_PUSHED=""
  source "$GUARD_LIB"
  git reset -q --hard HEAD~1
  echo devfix > devfix; git add devfix; git commit -q -m "dev-lead fix"
  run push_no_clobber origin main
  [ "$status" -eq 0 ]
  git --git-dir="$REMOTE" merge-base --is-ancestor "$owner_sha" main
  [ "$(git --git-dir="$REMOTE" show main:work)" = "owner fix" ]
}

@test "#2313: publishing to the ledger keeps notes another run wrote" {
  cd "$WORK"
  source "$GUARD_LIB"
  echo one > one; git add one; git commit -q -m one
  local first; first=$(git rev-parse HEAD)
  push_no_clobber origin main

  # Another run, whose clone never fetched the ledger, pushes a second commit.
  local later; later=$(_later_run_clone)
  cd "$later"
  _PUSH_GUARD_PUSHED=""
  source "$GUARD_LIB"
  run git notes --ref=refs/notes/dev-lead-pushed list
  [ -z "$output" ]
  echo two > two; git add two; git commit -q -m two
  local second; second=$(git rev-parse HEAD)
  push_no_clobber origin main

  git --git-dir="$REMOTE" notes --ref=refs/notes/dev-lead-pushed list "$first"
  git --git-dir="$REMOTE" notes --ref=refs/notes/dev-lead-pushed list "$second"
}

@test "#2313: _push_guard_ownership_verdict — pushed SHA, matching stamp, and nothing else" {
  source "$GUARD_LIB"
  local tree=4b825dc642cb6eb9a060e54bf8d69288fbee4904
  local p1=1111111111111111111111111111111111111111
  local p2=2222222222222222222222222222222222222222
  local stamp; stamp=$(dev_lead_stamp_of "$tree" "$p1")

  run _push_guard_ownership_verdict aaaa "$tree" "$p1" "msg" $'bbbb\naaaa'
  [ "$status" -eq 0 ]; [ "$output" = own-pushed ]

  run _push_guard_ownership_verdict aaaa "$tree" "$p1" "msg" "" true
  [ "$status" -eq 0 ]; [ "$output" = own-ledger ]
  run _push_guard_ownership_verdict aaaa "$tree" "$p1" "msg" "" false
  [ "$status" -eq 1 ]; [ "$output" = foreign ]

  run _push_guard_ownership_verdict aaaa "$tree" "$p1" $'msg\n\nDev-Lead-Stamp: '"$stamp" ""
  [ "$status" -eq 0 ]; [ "$output" = own-stamped ]

  # The same stamp on a commit with another parent (a cherry-pick or rebase).
  run _push_guard_ownership_verdict aaaa "$tree" "$p2" $'msg\n\nDev-Lead-Stamp: '"$stamp" ""
  [ "$status" -eq 1 ]; [ "$output" = foreign ]

  # A merge commit's stamp covers both parents, in order.
  local merge_stamp; merge_stamp=$(dev_lead_stamp_of "$tree" "$p1" "$p2")
  run _push_guard_ownership_verdict aaaa "$tree" "$p1 $p2" "Dev-Lead-Stamp: ${merge_stamp}" ""
  [ "$status" -eq 0 ]; [ "$output" = own-stamped ]
  run _push_guard_ownership_verdict aaaa "$tree" "$p2 $p1" "Dev-Lead-Stamp: ${merge_stamp}" ""
  [ "$status" -eq 1 ]

  # A SHA that merely contains a pushed SHA is not it.
  run _push_guard_ownership_verdict aaaa "$tree" "$p1" "msg" "aaaab"
  [ "$status" -eq 1 ]; [ "$output" = foreign ]

  # No record at all: foreign, whatever identity made it.
  run _push_guard_ownership_verdict aaaa "$tree" "$p1" "msg" ""
  [ "$status" -eq 1 ]; [ "$output" = foreign ]
}

@test "#2313: the committer email is not a signal — dev-lead's exact noreply address alone is foreign" {
  cd "$WORK"
  source "$GUARD_LIB"
  GIT_COMMITTER_EMAIL="12345+don-petry@users.noreply.github.com" \
    git commit -q --allow-empty -m idprefix
  run _commit_is_dev_lead HEAD
  [ "$status" -ne 0 ]
  GIT_COMMITTER_EMAIL="don-petry@users.noreply.github.com" \
    git commit -q --allow-empty -m bare
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
