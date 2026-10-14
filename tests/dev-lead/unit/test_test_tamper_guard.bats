#!/usr/bin/env bats
# Unit tests for scripts/lib/test-tamper-guard.sh (#2013).
#
# On petry-projects/.github#1220 a cubic finding said, literally, "update the
# older test to assert failure precedence so the Bats suite can pass", and
# dev-lead rewrote an existing test (#1023 "success precedence …") to match its
# own change — inverting deliberate behavior. "Don't edit tests to make them pass"
# lived only in the prompt. This guard makes it a harness check: a fix pass that
# changes or deletes an EXISTING test line, or adds a skip, without a cited
# `Test-Change-Justification:` trailer is tampered; adding a new test is clean.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/test-tamper-guard.sh"

setup() {
  # shellcheck source=scripts/lib/test-tamper-guard.sh
  source "$LIB"
}

@test "test-tamper-guard.sh is safe to source under set -euo pipefail" {
  run bash -c "set -euo pipefail; source '$LIB'"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

# ---------------------------------------------------------------------------
# ttg_is_test_path
# ---------------------------------------------------------------------------

@test "ttg_is_test_path: recognises common test file shapes" {
  local p
  for p in tests/canary_rollout.bats test/x.sh tests/dev-lead/unit/a.bats pkg/foo_test.go \
           src/__tests__/a.js src/a.test.ts src/a.spec.js tests/test_x.py app/test_y.py \
           spec/models/user_spec.rb; do
    ttg_is_test_path "$p" || { echo "not a test path: $p"; return 1; }
  done
}

@test "ttg_is_test_path: ignores non-test source files" {
  local p
  for p in scripts/canary-rollout.sh src/app.ts README.md scripts/lib/testing-helpers.md \
           docs/test-plan.md contest/a.go; do
    if ttg_is_test_path "$p"; then echo "wrongly a test path: $p"; return 1; fi
  done
}

# ---------------------------------------------------------------------------
# ttg_touched_existing_tests — test files with REMOVED lines (changed/deleted)
# ---------------------------------------------------------------------------

@test "ttg_touched_existing_tests: a pure addition to a test file is not a touch" {
  run ttg_touched_existing_tests $'12\t0\ttests/canary_rollout.bats\n3\t1\tscripts/canary-rollout.sh'
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "ttg_touched_existing_tests: inverting an existing test (removed lines) is a touch" {
  run ttg_touched_existing_tests $'4\t4\ttests/canary_rollout.bats\n3\t1\tscripts/canary-rollout.sh'
  [[ "$output" == "tests/canary_rollout.bats" ]]
}

@test "ttg_touched_existing_tests: deleting a test file is a touch" {
  run ttg_touched_existing_tests $'0\t40\ttests/old_test.py'
  [[ "$output" == "tests/old_test.py" ]]
}

@test "ttg_touched_existing_tests: a binary numstat row on a test path fails closed (touch)" {
  run ttg_touched_existing_tests $'-\t-\ttests/fixtures/blob.bats'
  [[ "$output" == "tests/fixtures/blob.bats" ]]
}

# ---------------------------------------------------------------------------
# ttg_count_added_skips — a skip added to a test file silences it
# ---------------------------------------------------------------------------

@test "ttg_count_added_skips: counts skips added in test files only" {
  local diff
  diff=$'diff --git a/tests/a.bats b/tests/a.bats\n--- a/tests/a.bats\n+++ b/tests/a.bats\n@@ -1,2 +1,3 @@\n @test "x" {\n+  skip "flaky"\n   run true\ndiff --git a/src/a.test.ts b/src/a.test.ts\n--- a/src/a.test.ts\n+++ b/src/a.test.ts\n@@ -1 +1 @@\n+it.skip("y", () => {})\ndiff --git a/scripts/run.sh b/scripts/run.sh\n--- a/scripts/run.sh\n+++ b/scripts/run.sh\n@@ -1 +1 @@\n+  skip "not a test file"'
  run ttg_count_added_skips "$diff"
  [[ "$output" == "2" ]]
}

@test "ttg_count_added_skips: recognizes the pytest, unittest, JUnit, Rust, Go and JS skip forms" {
  local diff
  diff=$'+++ b/tests/test_x.py\n+@pytest.mark.skip("x")\n+pytestmark = pytest.mark.skip("x")\n+pytest.skip("x")\n+pytest.importorskip("x")\n+@unittest.skip("x")\n+++ b/tests/FooTest.java\n+@Disabled\n+@Ignore\n+++ b/tests/x_test.rs\n+#[ignore]\n+++ b/tests/x_test.go\n+t.Skip("x")\n+t.SkipNow()\n+++ b/src/a.spec.js\n+xit("y", () => {})\n+it.todo("z")'
  run ttg_count_added_skips "$diff"
  [[ "$output" == "12" ]]
}

@test "ttg_count_added_skips: no skips -> 0" {
  run ttg_count_added_skips $'+++ b/tests/a.bats\n+@test "new" {\n+  run true\n+}'
  [[ "$output" == "0" ]]
}

# ---------------------------------------------------------------------------
# ttg_has_justification — the explicit, cited justification trailer
# ---------------------------------------------------------------------------

@test "ttg_has_justification: a non-trivial trailer is a justification" {
  run ttg_has_justification $'fix: x\n\nTest-Change-Justification: test asserted the old exit code; #1023 renamed it per maintainer review r123'
  [[ "$status" -eq 0 ]]
}

@test "ttg_has_justification: missing or empty trailer is not" {
  run ttg_has_justification $'fix(reviews): address review comments [skip ci-relay]'
  [[ "$status" -eq 1 ]]
  run ttg_has_justification $'fix: x\n\nTest-Change-Justification:   '
  [[ "$status" -eq 1 ]]
  run ttg_has_justification $'fix: x\n\nTest-Change-Justification: so it passes'
  [[ "$status" -eq 1 ]]
}

@test "ttg_has_justification: long prose with no issue/SHA/URL reference is not a justification" {
  run ttg_has_justification $'fix: x\n\nTest-Change-Justification: the old test was simply wrong and needed changing'
  [[ "$status" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# ttg_classify — the pure verdict
# ---------------------------------------------------------------------------

@test "ttg_classify: nothing touched, no skips -> clean rc0" {
  run ttg_classify "" 0 false
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ttg_classify: existing test changed without justification -> tampered rc1" {
  run ttg_classify "tests/canary_rollout.bats" 0 false
  [[ "$status" -eq 1 ]]
  [[ "$output" == "tampered" ]]
}

@test "ttg_classify: skip added without justification -> tampered rc1" {
  run ttg_classify "" 1 false
  [[ "$status" -eq 1 ]]
  [[ "$output" == "tampered" ]]
}

@test "ttg_classify: existing test changed WITH justification -> justified rc0" {
  run ttg_classify "tests/canary_rollout.bats" 0 true
  [[ "$status" -eq 0 ]]
  [[ "$output" == "justified" ]]
}

@test "ttg_classify: unrecognised skip count fails closed -> tampered" {
  run ttg_classify "" "" false
  [[ "$status" -eq 1 ]]
  [[ "$output" == "tampered" ]]
}

# ---------------------------------------------------------------------------
# ttg_scan_pass — the impure gatherer over <base>..<head>
# ---------------------------------------------------------------------------

_mk_repo() {
  REPO_DIR="$BATS_TEST_TMPDIR/repo"
  git init -q "$REPO_DIR"
  cd "$REPO_DIR"
  git config user.email t@t; git config user.name T
  mkdir -p tests scripts
  printf '@test "success precedence" {\n  run f\n  [ "$output" = success ]\n}\n' > tests/canary.bats
  echo 'f() { echo success; }' > scripts/canary.sh
  git add -A; git commit -q -m base
  BASE="$(git rev-parse HEAD)"
  # The merge base of the PR branch and its base branch: here the PR has no
  # commits of its own yet, so it is the pre-pass head too.
  MB="$BASE"
}

@test "ttg_scan_pass: code change + NEW test -> clean" {
  _mk_repo
  echo 'g() { :; }' >> scripts/canary.sh
  printf '@test "new" {\n  run g\n}\n' >> tests/canary.bats
  git commit -q -am "fix(reviews): address review comments"
  run ttg_scan_pass "$BASE" HEAD "$MB"
  [[ "$status" -eq 0 ]]
  [[ "$(printf '%s' "$output" | head -1)" == "clean" ]]
}

@test "ttg_scan_pass: the #1220 shape — existing test inverted to match the code -> tampered, file named" {
  _mk_repo
  sed -i 's/success precedence/failure precedence/; s/= success/= failure/' tests/canary.bats
  echo 'f() { echo failure; }' > scripts/canary.sh
  git commit -q -am "fix(reviews): address review comments"
  run ttg_scan_pass "$BASE" HEAD "$MB"
  [[ "$status" -eq 1 ]]
  [[ "$(printf '%s' "$output" | head -1)" == "tampered" ]]
  [[ "$output" == *"tests/canary.bats"* ]]
}

@test "ttg_scan_pass: same edit with a Test-Change-Justification trailer -> justified" {
  _mk_repo
  sed -i 's/= success/= SUCCESS/' tests/canary.bats
  git commit -q -am $'fix: rename\n\nTest-Change-Justification: maintainer asked to upper-case the status token in review #4159678193'
  run ttg_scan_pass "$BASE" HEAD "$MB"
  [[ "$status" -eq 0 ]]
  [[ "$(printf '%s' "$output" | head -1)" == "justified" ]]
}

@test "ttg_scan_pass: uncommitted working-tree edits to an existing test are scanned too" {
  _mk_repo
  sed -i 's/= success/= failure/' tests/canary.bats
  run ttg_scan_pass "$BASE" HEAD "$MB"
  [[ "$status" -eq 1 ]]
  [[ "$(printf '%s' "$output" | head -1)" == "tampered" ]]
}

@test "ttg_scan_pass: unknown base fails closed -> unknown rc2" {
  _mk_repo
  run ttg_scan_pass "" HEAD "$MB"
  [[ "$status" -eq 2 ]]
  [[ "$(printf '%s' "$output" | head -1)" == "unknown" ]]
}

# ---------------------------------------------------------------------------
# "Existing" means existing before the PR (#2141)
#
# On PR #2135 a fix-bot-comment pass edited tests/dev-lead/unit/
# test_ai_engines_config.bats — a file the PR itself added (+195 −0, absent on
# main). The guard compared against the pre-pass head, called it an existing test,
# refused the push and retracted five unrelated "Fixed" replies. Only a line that
# is present at the merge base of the PR branch and its base is protected.
# ---------------------------------------------------------------------------

# ttg_count_preexisting_removals — pure line-number arithmetic over -U0 diffs

@test "ttg_count_preexisting_removals: removing a line the PR added is not counted" {
  # PR (merge base -> pre-pass head) added lines 5-7; the pass removes line 6.
  run ttg_count_preexisting_removals $'@@ -5,1 +5,1 @@\n-x\n+y' $'@@ -4,0 +5,3 @@\n+a\n+b\n+c'
  [[ "$output" == "0" ]]
}

@test "ttg_count_preexisting_removals: removing a line that exists at the merge base is counted" {
  run ttg_count_preexisting_removals $'@@ -2,2 +2,2 @@\n-x\n-y\n+X\n+Y' $'@@ -4,0 +5,3 @@\n+a\n+b\n+c'
  [[ "$output" == "2" ]]
}

@test "ttg_count_preexisting_removals: a hunk spanning PR-added and merge-base lines counts only the latter" {
  # Pass removes lines 4-6; PR added 5-7, so only line 4 pre-dates the PR.
  run ttg_count_preexisting_removals $'@@ -4,3 +3,0 @@\n-a\n-b\n-c' $'@@ -4,0 +5,3 @@\n+a\n+b\n+c'
  [[ "$output" == "1" ]]
}

@test "ttg_count_preexisting_removals: an omitted hunk count means 1; a pure insertion removes nothing" {
  run ttg_count_preexisting_removals $'@@ -3 +3 @@\n-x\n+y\n@@ -9,0 +10,2 @@\n+n\n+m' ''
  [[ "$output" == "1" ]]
}

@test "ttg_count_preexisting_removals: a file the PR created (all lines PR-added) is never counted" {
  run ttg_count_preexisting_removals $'@@ -1,4 +1,4 @@\n-a\n-b\n-c\n-d\n+A\n+B\n+C\n+D' $'@@ -0,0 +1,10 @@\n+1'
  [[ "$output" == "0" ]]
}

# ttg_scan_pass against a real merge base

# _mk_pr: the base commit (main) holds tests/canary.bats; the PR branch then adds a
# whole new test file AND a new test case inside the existing file. BASE becomes
# the pre-pass head (PR tip); MB stays the merge base.
_mk_pr() {
  _mk_repo
  git checkout -q -b feat
  printf '@test "engines config" {\n  run cfg\n  [ "$output" = gemini ]\n}\n' > tests/ai_engines_config.bats
  printf '@test "pr case" {\n  run f\n  [ "$status" -eq 0 ]\n}\n' >> tests/canary.bats
  git add -A; git commit -q -m "feat: PR adds tests"
  BASE="$(git rev-parse HEAD)"
}

@test "ttg_scan_pass (#2141): a PR-added test file edited in a later pass -> clean" {
  _mk_pr
  sed -i 's/= gemini/= claude/' tests/ai_engines_config.bats
  git commit -q -am "fix(bot): address bot feedback"
  run ttg_scan_pass "$BASE" HEAD "$MB"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ttg_scan_pass (#2141): deleting a PR-added test file -> clean" {
  _mk_pr
  git rm -q tests/ai_engines_config.bats
  git commit -q -m "fix(bot): drop it"
  run ttg_scan_pass "$BASE" HEAD "$MB"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ttg_scan_pass (#2141): a PR-added test case inside a file that exists on the base, edited -> clean" {
  _mk_pr
  sed -i 's/"\$status" -eq 0/"$status" -eq 1/' tests/canary.bats
  git commit -q -am "fix(reviews): address review comments"
  run ttg_scan_pass "$BASE" HEAD "$MB"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ttg_scan_pass (#2141): the #1220 shape — an assertion present at the merge base inverted -> tampered" {
  _mk_pr
  sed -i 's/= success/= failure/' tests/canary.bats
  git commit -q -am "fix(reviews): address review comments"
  run ttg_scan_pass "$BASE" HEAD "$MB"
  [[ "$status" -eq 1 ]]
  [[ "$(printf '%s' "$output" | head -1)" == "tampered" ]]
  [[ "$output" == *"tests/canary.bats"* ]]
}

@test "ttg_scan_pass (#2141): a skip added to a test that exists at the merge base still counts" {
  _mk_pr
  sed -i 's/^  run f$/  skip "flaky"\n  run f/' tests/canary.bats
  git commit -q -am "fix(reviews): address review comments"
  run ttg_scan_pass "$BASE" HEAD "$MB"
  [[ "$status" -eq 1 ]]
  [[ "$(printf '%s' "$output" | head -1)" == "tampered" ]]
}

@test "ttg_scan_pass (#2141): a skip added to a PR-added test file -> clean" {
  _mk_pr
  sed -i 's/^  run cfg$/  skip "pending engine"\n  run cfg/' tests/ai_engines_config.bats
  git commit -q -am "fix(bot): address bot feedback"
  run ttg_scan_pass "$BASE" HEAD "$MB"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ttg_scan_pass (#2141): merge base missing or unresolvable fails closed -> unknown rc2" {
  _mk_pr
  sed -i 's/= gemini/= claude/' tests/ai_engines_config.bats
  run ttg_scan_pass "$BASE" HEAD ""
  [[ "$status" -eq 2 ]]
  [[ "$output" == "unknown" ]]
  run ttg_scan_pass "$BASE" HEAD "0000000000000000000000000000000000000000"
  [[ "$status" -eq 2 ]]
  [[ "$output" == "unknown" ]]
}

@test "ttg_scan_pass (#2141): a pass touching no test file is clean without a merge base" {
  _mk_pr
  echo 'h() { :; }' >> scripts/canary.sh
  run ttg_scan_pass "$BASE" HEAD ""
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ttg_pass_touches_tests: true for a test-file change or an unknown base, false otherwise" {
  _mk_pr
  echo 'h() { :; }' >> scripts/canary.sh
  run ttg_pass_touches_tests "$BASE"
  [[ "$status" -eq 1 ]]
  echo '# note' >> tests/canary.bats
  run ttg_pass_touches_tests "$BASE"
  [[ "$status" -eq 0 ]]
  run ttg_pass_touches_tests ""
  [[ "$status" -eq 0 ]]
}

# ttg_resolve_merge_base — the impure resolver over git_ensure_merge_base (#2053)

# _mk_remote: a bare origin holding main (the base commit) and a clone with the
# PR branch checked out.
_mk_remote() {
  _mk_pr
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  git init -q --bare "$REMOTE"
  git remote add origin "file://$REMOTE"
  git push -q origin "$MB:refs/heads/main" feat
}

@test "ttg_resolve_merge_base: resolves the PR's merge base with origin/<base>" {
  _mk_remote
  run ttg_resolve_merge_base main "$BASE" feat
  [[ "$status" -eq 0 ]]
  [[ "$output" == "$MB" ]]
}

@test "ttg_resolve_merge_base: a base branch that cannot be fetched fails closed (non-zero, no SHA)" {
  _mk_remote
  run ttg_resolve_merge_base no-such-branch "$BASE" feat
  [[ "$status" -ne 0 ]]
  [[ ! "$output" =~ ^[0-9a-f]{40}$ ]]
}

@test "ttg_resolve_merge_base: unrelated histories (no merge base) fail closed" {
  _mk_remote
  # A root commit sharing no history with the PR branch becomes origin's main.
  local orphan
  orphan=$(git commit-tree -m orphan "$(git mktree </dev/null)")
  git push -q --force origin "$orphan:refs/heads/main"
  run ttg_resolve_merge_base main "$BASE" feat
  [[ "$status" -ne 0 ]]
}

@test "ttg_scan_pass: a skip added to a non-ASCII test path at the merge base still counts" {
  _mk_repo
  mkdir -p src
  printf 'it "x" do\n  expect(1).to eq 1\nend\n' > "src/café_spec.rb"
  git add -A; git commit -q -m "base spec"
  BASE="$(git rev-parse HEAD)"; MB="$BASE"
  sed -i 's/^it "x" do$/it "x" do\n  skip "flaky"/' "src/café_spec.rb"
  git commit -q -am "fix(reviews): address review comments"
  run ttg_scan_pass "$BASE" HEAD "$MB"
  [[ "$status" -eq 1 ]]
  [[ "$(printf '%s' "$output" | head -1)" == "tampered" ]]
}
