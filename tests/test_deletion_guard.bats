#!/usr/bin/env bats
# Tests for scripts/test-deletion-guard.sh — the Test-Deletion Guard (#655/#823).
#
# #2254: PR #2252 was cut before main gained tests/…/test_budget_breaker_writer.bats.
# The guard diffed the base TIP against the head, so a file main added after the
# branch point read as deleted by the PR. The PR's own changes are measured from
# the merge base.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GUARD="$REPO_ROOT/scripts/test-deletion-guard.sh"
  REPO_DIR="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$REPO_DIR"
  cd "$REPO_DIR"
  git config user.email t@t; git config user.name T
  mkdir -p tests
  printf '@test "a" { true; }\n' > tests/a.bats
  printf '@test "b" { true; }\n' > tests/b.bats
  git add -A; git commit -q -m base
  git checkout -q -b feat
}

_run_guard() {
  run env BASE_SHA="$(git rev-parse main)" HEAD_SHA="$(git rev-parse feat)" ACK="${ACK:-false}" bash "$GUARD"
}

@test "#2254: a branch behind a base that gained a test file passes" {
  printf '@test "pr" { true; }\n' > tests/pr.bats
  git add -A; git commit -q -m "feat: PR adds a test"
  git checkout -q main
  printf '@test "new on main" { true; }\n' > tests/new_on_main.bats
  git add -A; git commit -q -m "main gains a test"
  git checkout -q feat
  _run_guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"No files deleted under tests/"* ]]
  [[ "$output" != *"new_on_main"* ]]
}

@test "a PR that deletes a test file fails without the ack label and names it" {
  git rm -q tests/b.bats
  git commit -q -m "drop b"
  _run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests/b.bats"* ]]
  [[ "$output" == *"ack-test-deletion"* ]]
}

@test "a PR behind its base that deletes a test file still fails" {
  git rm -q tests/b.bats
  git commit -q -m "drop b"
  git checkout -q main
  printf '@test "new on main" { true; }\n' > tests/new_on_main.bats
  git add -A; git commit -q -m "main gains a test"
  git checkout -q feat
  _run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests/b.bats"* ]]
  [[ "$output" != *"new_on_main"* ]]
}

@test "the ack-test-deletion label acknowledges a deletion" {
  git rm -q tests/b.bats
  git commit -q -m "drop b"
  ACK=true _run_guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"acknowledged"* ]]
}

@test "no merge base between base and head fails closed" {
  local orphan
  orphan=$(git commit-tree -m orphan "$(git mktree </dev/null)")
  run env BASE_SHA="$orphan" HEAD_SHA="$(git rev-parse feat)" ACK=false bash "$GUARD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"merge base"* ]]
}
