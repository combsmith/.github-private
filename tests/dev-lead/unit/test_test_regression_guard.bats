#!/usr/bin/env bats
# Unit tests for scripts/lib/test-regression-guard.sh (#2013).
#
# The `15a919e` shape from petry-projects/.github#1220: a fix pass added a NEW test
# and broke an EXISTING one without editing it. The test-tamper guard is silent, the
# claim names a real in-pass commit — only running the suite against the pre-pass
# baseline catches it.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/test-regression-guard.sh"
bats_require_minimum_version 1.5.0

setup() {
  # shellcheck source=scripts/lib/test-regression-guard.sh
  source "$LIB"
  unset DEV_LEAD_TEST_CMD
}

@test "test-regression-guard.sh is safe to source under set -euo pipefail" {
  run bash -c "set -euo pipefail; source '$LIB'"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "trg_extract_failures: reads TAP not-ok and pytest FAILED lines, ignores TODO/skip" {
  run trg_extract_failures <<'OUT'
1..4
ok 1 fine
not ok 2 existing behaviour
not ok 3 later # skip not yet
not ok 4 wip # TODO later
FAILED tests/test_a.py::test_b - assert 1 == 2
OUT
  [[ "$status" -eq 0 ]]
  [[ "$output" == $'existing behaviour\ntests/test_a.py::test_b' ]]
}

@test "trg_classify: a passing suite is green" {
  run trg_classify false "" "" 0 ""
  [[ "$status" -eq 0 ]]
  [[ "$output" == "green" ]]
}

@test "trg_classify: the 15a919e shape — an existing test newly fails — is a regression" {
  run trg_classify true 0 "" 1 "existing behaviour"
  [[ "$status" -eq 1 ]]
  [[ "${lines[0]}" == "regression" ]]
  [[ "${lines[1]}" == "existing behaviour" ]]
}

@test "trg_classify: a failure that already existed on the pre-pass head does not block" {
  run trg_classify true 1 "old failure" 1 "old failure"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "preexisting" ]]
}

@test "trg_classify: one old failure plus one new failure is a regression naming only the new one" {
  run trg_classify true 1 "old failure" 1 $'new failure\nold failure'
  [[ "$status" -eq 1 ]]
  [[ "${lines[1]}" == "new failure" ]]
  [[ "${#lines[@]}" -eq 2 ]]
}

@test "trg_classify: red with no readable names is a regression only if the baseline was green" {
  run trg_classify true 0 "" 2 ""
  [[ "$status" -eq 1 ]]
  run trg_classify true 1 "" 2 ""
  [[ "$status" -eq 0 ]]
  [[ "$output" == "unattributed" ]]
}

@test "trg_classify: red with no baseline run is unbaselined, a timeout is timeout, never green" {
  run trg_classify false "" "" 1 "x"
  [[ "$output" == "unbaselined" ]]
  run trg_classify false "" "" 124 ""
  [[ "$output" == "timeout" ]]
}

@test "trg_classify: an unreadable head status fails closed" {
  run trg_classify true 0 "" "" ""
  [[ "$status" -eq 1 ]]
  [[ "${lines[0]}" == "regression" ]]
}

@test "trg_summary_line: not-run never implies green" {
  run trg_summary_line not-run ""
  [[ "$output" == *"NOT RUN"* ]]
  [[ "$output" == *"NOT verified green"* ]]
  run trg_summary_line green "make test"
  [[ "$output" == *"PASSED"* ]]
}

@test "trg_discover_cmd: DEV_LEAD_TEST_CMD wins; an empty repo has no command" {
  local d="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$d"
  run trg_discover_cmd "$d"
  [[ "$status" -eq 1 ]]
  DEV_LEAD_TEST_CMD="./run-tests" run trg_discover_cmd "$d"
  [[ "$output" == "./run-tests" ]]
}

@test "trg_discover_cmd: finds make test and npm test" {
  local d="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$d"
  printf 'test:\n\ttrue\n' > "$d/Makefile"
  run trg_discover_cmd "$d"
  [[ "$output" == "make test" ]]
  printf '{"scripts":{"test":"jest"}}\n' > "$d/package.json"
  run trg_discover_cmd "$d"
  [[ "$output" == "npm test" ]]
}

# --- trg_scan_pass against a real repo: the 15a919e fixture -------------------

_mk_repo() {
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  printf 'ok\n' > "$R/state.txt"
  # A tiny TAP "suite": one test per line of checks.sh.
  cat > "$R/suite.sh" <<'SH'
#!/usr/bin/env bash
n=0; rc=0
t() { n=$((n+1)); if eval "$2"; then echo "ok $n $1"; else echo "not ok $n $1"; rc=1; fi; }
t "existing behaviour" '[ "$(cat state.txt)" = ok ]'
[ -f new_test_marker ] && t "new test" 'true'
exit $rc
SH
  chmod +x "$R/suite.sh"
  git -C "$R" add .
  git -C "$R" -c user.email=t@t -c user.name=T commit -q -m init
  BASE="$(git -C "$R" rev-parse HEAD)"
  export DEV_LEAD_TEST_CMD="./suite.sh"
}

@test "trg_scan_pass: 15a919e shape — new test added, existing test broken but untouched — is refused" {
  _mk_repo
  cd "$R"
  : > new_test_marker           # adds a new (passing) test
  printf 'broken\n' > state.txt # breaks the existing test without editing it
  git add -A
  git -c user.email=t@t -c user.name=T commit -q -m fix
  run --separate-stderr trg_scan_pass "$BASE"
  [[ "$status" -eq 1 ]]
  [[ "${lines[0]}" == $'regression\t./suite.sh' ]]
  [[ "${lines[1]}" == "existing behaviour" ]]
  # the checkout is restored to the pass's result
  [[ "$(cat state.txt)" == "broken" ]]
}

@test "trg_scan_pass: a green result is green, and an already-red baseline does not block" {
  _mk_repo
  cd "$R"
  : > new_test_marker
  git add -A
  git -c user.email=t@t -c user.name=T commit -q -m fix
  run --separate-stderr trg_scan_pass "$BASE"
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == $'green\t./suite.sh' ]]

  # Base already red for the same test: break state.txt in the BASE commit.
  git checkout -q "$BASE"
  printf 'broken\n' > state.txt
  git -c user.email=t@t -c user.name=T commit -q -am redbase
  RED="$(git rev-parse HEAD)"
  : > new_test_marker
  git add -A
  git -c user.email=t@t -c user.name=T commit -q -m fix2
  run --separate-stderr trg_scan_pass "$RED"
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == $'preexisting\t./suite.sh' ]]
}

@test "trg_scan_pass: no test command means not-run, status 0" {
  local d="$BATS_TEST_TMPDIR/bare"
  mkdir -p "$d"
  cd "$d"
  git init -q
  unset DEV_LEAD_TEST_CMD
  run --separate-stderr trg_scan_pass ""
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == $'not-run\t' ]]
}

@test "trg_extract_failures: strips the bats timing suffix so the same test compares equal" {
  run trg_extract_failures <<'OUT'
not ok 1 existing behaviour in 123ms
OUT
  [[ "$output" == "existing behaviour" ]]
}

@test "trg_extract_failures: reads jest FAIL and go --- FAIL lines" {
  run trg_extract_failures <<'OUT'
FAIL src/a.test.js
--- FAIL: TestThing (0.00s)
OUT
  [[ "${lines[0]}" == "TestThing" ]]
  [[ "${lines[1]}" == "src/a.test.js" ]]
  [[ "${#lines[@]}" -eq 2 ]]
}

@test "trg_classify: a timed-out baseline is unbaselined, not preexisting" {
  run trg_classify true 124 "x" 1 "x"
  [[ "$output" == "unbaselined" ]]
}

@test "_trg_run: write-capable credentials are not visible to the suite" {
  GH_TOKEN=secret GITHUB_TOKEN=secret run _trg_run 'echo "[${GH_TOKEN:-}${GITHUB_TOKEN:-}]"'
  [[ "$output" == "[]" ]]
}

@test "_trg_run: allowlisted env and no git credential reach the suite (#2013)" {
  d="$BATS_TEST_TMPDIR/credrepo"; mkdir -p "$d"; cd "$d"
  git init -q
  git config http.https://github.com/.extraheader "AUTHORIZATION: basic FAKE_GIT_CRED_9f3"
  printf '[http "https://github.com/"]\n\textraheader = FAKE_INCLUDED_CRED_7a1\n' > "$BATS_TEST_TMPDIR/inc.cfg"
  git config include.path "$BATS_TEST_TMPDIR/inc.cfg"
  export GH_PAT_DON_PETRY=FAKE_PAT_1 COPILOT_GITHUB_TOKEN=FAKE_PAT_2 GOOGLE_API_KEY=FAKE_G1 GEMINI_API_KEY=FAKE_G2 SOME_NEW_SECRET=FAKE_N3
  run _trg_run 'env; git config --list --show-origin 2>&1; cat .git/config 2>&1; git config --global --list 2>&1; echo END'
  [[ "$output" == *END* ]]
  [[ "$output" != *FAKE_* ]]
  [[ "$output" != *extraheader* ]]
  # the real checkout's git config is untouched
  [[ "$(git config --get-all http.https://github.com/.extraheader)" == *FAKE_GIT_CRED_9f3* ]]
}

@test "trg_scan_pass: an unbaselinable base (unknown sha) is unbaselined and not blocked" {
  d="$BATS_TEST_TMPDIR/repo"; mkdir -p "$d"; cd "$d"
  git init -q; git -c user.email=t@t -c user.name=T commit -q --allow-empty -m i
  DEV_LEAD_TEST_CMD="echo 'not ok 1 broken'; exit 1" run --separate-stderr trg_scan_pass "0000000000000000000000000000000000000000"
  [[ "${lines[0]}" == $'unbaselined\t'* ]]
  [[ "$status" -eq 0 ]]
}

@test "dev-lead-reusable.yml installs bats before the first Run step and maps DEV_LEAD_TEST_CMD from vars (#2013)" {
  local wf="$BATS_TEST_DIRNAME/../../../.github/workflows/dev-lead-reusable.yml"
  local inst run
  inst=$(grep -n -- '- name: Install bats' "$wf" | head -1 | cut -d: -f1)
  run=$(grep -n -- '- name: Run ' "$wf" | head -1 | cut -d: -f1)
  [[ -n "$inst" && -n "$run" && "$inst" -lt "$run" ]]
  grep -q 'apt-get install -y bats' "$wf"
  grep -qF 'DEV_LEAD_TEST_CMD: ${{ vars.DEV_LEAD_TEST_CMD }}' "$wf"
}

# --- #2055: the scratch copy has a commit; the run log explains the verdict ----

@test "_trg_run: a suite whose only test reads HEAD passes in the scratch copy (#2055)" {
  d="$BATS_TEST_TMPDIR/headrepo"; mkdir -p "$d"; cd "$d"
  git init -q
  printf 'x\n' > f.txt
  git add -A; git -c user.email=t@t -c user.name=T commit -q -m i
  run _trg_run 'git rev-parse --verify HEAD && echo "ok 1 reads HEAD"'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"ok 1 reads HEAD"* ]]
  # the snapshot adds no remote and the working tree is clean in the copy
  run _trg_run 'git remote; git status --porcelain; echo END'
  [[ "$output" == "END" ]]
}

@test "_trg_run: the baseline copy has a commit too (#2055)" {
  _mk_repo
  cd "$R"
  run _trg_run 'git rev-parse --verify HEAD >/dev/null && cat state.txt' "$BASE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "ok" ]]
}

@test "trg_scan_pass: green logs the run's elapsed seconds and no baseline run (#2055)" {
  _mk_repo
  cd "$R"
  run --separate-stderr trg_scan_pass "$BASE"
  [[ "${lines[0]}" == $'green\t./suite.sh' ]]
  [[ "$stderr" =~ result\ suite\ run\ took\ [0-9]+s ]]
  [[ "$stderr" != *"baseline suite run"* ]]
  [[ "$stderr" != *"failing test"* ]]
}

@test "trg_scan_pass: a red verdict logs failing names for result and baseline, capped at 20 (#2055)" {
  _mk_repo
  cd "$R"
  export DEV_LEAD_TEST_CMD='for i in $(seq 1 25); do echo "not ok $i t$i"; done; exit 1'
  run --separate-stderr trg_scan_pass "$BASE"
  [[ "${lines[0]}" == $'preexisting\t'* ]]
  [[ "$stderr" =~ result\ suite\ run\ took\ [0-9]+s ]]
  [[ "$stderr" =~ baseline\ suite\ run\ took\ [0-9]+s ]]
  [[ "$stderr" == *"result: 25 parsed/named failing test(s)"* ]]
  [[ "$stderr" == *"baseline: 25 parsed/named failing test(s)"* ]]
  [[ "$stderr" == *"  t1"* ]]
  [[ "$(printf '%s\n' "$stderr" | grep -c '^  t')" -eq 40 ]]
  [[ "$stderr" == *"and 5 more"* ]]
}
