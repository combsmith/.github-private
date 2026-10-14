#!/usr/bin/env bash
# test-regression-guard.sh — a fix pass may not push with the suite newly red (#2013).
#
# WHAT IS WRONG WITHOUT THIS
#   On petry-projects/.github#1220 the `15a919e` fix added a NEW test and broke an
#   EXISTING one without editing it. The test-tamper guard is silent about that (no
#   existing test line changed) and the claim names a real in-pass commit, so every
#   other check passed. Only running the suite against the pre-pass baseline sees it.
#
# THE RULE
#   Run the repo's test command on the pass's result. Then:
#     green        the suite passes;
#     preexisting  it fails, but every failing test also fails on the pre-pass head;
#     regression   a test fails that did not fail on the pre-pass head (a previously
#                  passing test broke, or a new test fails). The harness refuses to
#                  push and escalates to a human;
#     unattributed it fails on both heads and no failing test names could be read,
#                  so the failure cannot be pinned on the pass (reported, not blocked);
#     unbaselined  it fails and the pre-pass head could not be run (not blocked, said
#                  loudly);
#     timeout      the suite did not finish (not blocked, said loudly);
#     not-run      no test command could be determined — the suite was NOT run, and
#                  the run summary says so. Never report or imply green.
#
# HOW THE COMMAND IS FOUND (no workflow_call input — channel-pin sequencing)
#   1. $DEV_LEAD_TEST_CMD, 2. `npm test` (package.json with a test script),
#   3. `make test` (Makefile with a test target), 4. `pytest` (pytest config or tests
#   dir with test_*.py), 5. `bats --recursive tests` when bats and *.bats are present.
#
# PURITY / TESTABILITY (ADR-0004)
#   trg_extract_failures, trg_classify and trg_summary_line are PURE. trg_discover_cmd
#   only reads the working tree; trg_scan_pass is the single impure gatherer (runs the
#   suite, and checks out the pre-pass head to baseline a red suite). Sourced under
#   `set -euo pipefail`; helpers only `return`, never `exit`.

set -euo pipefail

# trg_extract_failures — failing test names from suite output on stdin, sorted and
# unique. Reads TAP (`not ok 3 name`, as bats/prove print) and pytest short summaries
# (`FAILED path::name - reason`). A `# TODO`/`# skip` TAP line is not a failure. Pure.
trg_extract_failures() {
  local line name
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^not\ ok\ [0-9]+[[:space:]]+(.*)$ ]]; then
      name="${BASH_REMATCH[1]}"
      # bats appends the measured duration ("in 123ms"); strip it so the same test
      # failing on both heads compares equal despite differing timings.
      name="${name%% in [0-9]*ms}"
      [[ "$name" =~ \#[[:space:]]*(TODO|skip|SKIP) ]] && continue
      printf '%s\n' "$name"
    elif [[ "$line" =~ ^FAILED\ ([^[:space:]]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^FAIL\ +([^[:space:]]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"            # jest/vitest: FAIL path/to/file.test.js
    elif [[ "$line" =~ ^[[:space:]]*---\ FAIL:\ ([^[:space:]]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"            # go test: --- FAIL: TestName
    fi
  done | sort -u
}

# trg_classify <base_ran:true|false> <base_rc> <base_failures_nl> <head_rc> <head_failures_nl>
#   Echoes the verdict (above) on the first line, then the offending test names for a
#   regression, one per line. Returns 1 only for `regression`. A non-numeric head rc
#   fails closed (regression). Pure.
trg_classify() {
  local base_ran="${1:-false}" base_rc="${2:-}" base_fail="${3:-}" head_rc="${4:-}" head_fail="${5:-}"
  if ! [[ "$head_rc" =~ ^[0-9]+$ ]]; then
    echo "regression"
    echo "(suite result unreadable)"
    return 1
  fi
  if (( head_rc == 0 )); then
    echo "green"
    return 0
  fi
  if (( head_rc == 124 )); then
    echo "timeout"
    return 0
  fi
  if [[ "$base_ran" != "true" ]] || ! [[ "$base_rc" =~ ^[0-9]+$ ]] || (( base_rc == 124 )); then
    echo "unbaselined"
    return 0
  fi
  local new="" t
  if [[ -n "$(printf '%s' "$head_fail" | tr -d '[:space:]')" ]]; then
    while IFS= read -r t; do
      [[ -z "$t" ]] && continue
      printf '%s\n' "$base_fail" | grep -qxF -- "$t" || new+="${t}"$'\n'
    done <<<"$head_fail"
    if [[ -n "$new" ]]; then
      echo "regression"
      printf '%s' "$new"
      return 1
    fi
    echo "preexisting"
    return 0
  fi
  # Red on the head, no names to compare.
  if (( base_rc == 0 )); then
    echo "regression"
    echo "(suite exited ${head_rc}; it passed on the pre-pass head)"
    return 1
  fi
  echo "unattributed"
  return 0
}

# trg_summary_line <verdict> [cmd] — the one line for the run summary. Never implies
# green unless the suite really passed. Pure.
trg_summary_line() {
  local verdict="${1:-}" cmd="${2:-}"
  case "$verdict" in
    green)        echo "Test suite: PASSED on the pass's result (\`${cmd}\`)." ;;
    preexisting)  echo "Test suite: red, but every failing test already failed on the pre-pass head (\`${cmd}\`) — not caused by this pass." ;;
    unattributed) echo "Test suite: red on both the pre-pass head and the result (\`${cmd}\`); no test names could be read, so the failure could not be attributed. NOT verified green." ;;
    unbaselined)  echo "Test suite: red (\`${cmd}\`) and the pre-pass head could not be run for comparison. NOT verified green." ;;
    timeout)      echo "Test suite: did not finish within the time limit (\`${cmd}\`). NOT verified green." ;;
    regression)   echo "Test suite: REGRESSION — a test that passed on the pre-pass head fails on the result (\`${cmd}\`). Push refused." ;;
    not-run|*)    echo "Test suite: NOT RUN — no test command could be determined (set DEV_LEAD_TEST_CMD). The pass is NOT verified green." ;;
  esac
}

# trg_discover_cmd [dir] — echoes the test command for <dir> (default .), or returns 1
# when none can be determined.
trg_discover_cmd() {
  local dir="${1:-.}"
  if [[ -n "${DEV_LEAD_TEST_CMD:-}" ]]; then
    echo "$DEV_LEAD_TEST_CMD"
    return 0
  fi
  if [[ -f "$dir/package.json" ]] && grep -q '"test"[[:space:]]*:' "$dir/package.json" 2>/dev/null; then
    echo "npm test"
    return 0
  fi
  if [[ -f "$dir/Makefile" ]] && grep -qE '^test[[:space:]]*:' "$dir/Makefile" 2>/dev/null; then
    echo "make test"
    return 0
  fi
  if [[ -f "$dir/pytest.ini" || -f "$dir/tox.ini" || -f "$dir/pyproject.toml" || -f "$dir/setup.cfg" ]] \
     && command -v pytest >/dev/null 2>&1 \
     && [[ -n "$(find "$dir" -path "$dir/.git" -prune -o -name 'test_*.py' -print -quit 2>/dev/null)" ]]; then
    echo "pytest -q"
    return 0
  fi
  if [[ -d "$dir/tests" ]] && command -v bats >/dev/null 2>&1 \
     && [[ -n "$(find "$dir/tests" -name '*.bats' -print -quit 2>/dev/null)" ]]; then
    echo "bats --recursive tests"
    return 0
  fi
  return 1
}

# _trg_stage <scratch> [base_sha] — fill <scratch>/tree with a credential-free copy of
# the current working tree (everything but .git, so installed deps come along). With
# <base_sha>, the tracked files are replaced by that commit's. A fresh `git init` gives
# git-using tests a repo; it carries none of the real checkout's git config, so the
# saved checkout credential (http.*.extraheader) does not exist in the copy. A
# snapshot commit (throwaway identity, no remote) gives it a HEAD: without one every
# test that reads HEAD failed on both copies and the gate was always red (#2055).
_trg_stage() {
  local scratch="$1" base="${2:-}" f
  mkdir -p "$scratch/tree" "$scratch/home" "$scratch/tmp"
  tar --exclude=.git -cf - . | tar -xf - -C "$scratch/tree"
  if [[ -n "$base" ]]; then
    # Drop head-tracked files, then lay the base commit's files over the copy.
    while IFS= read -r -d '' f; do
      rm -rf -- "${scratch:?}/tree/$f"
    done < <(git ls-files -z 2>/dev/null)
    git archive "$base" | tar -xf - -C "$scratch/tree"
  fi
  (
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
    git -C "$scratch/tree" init -q &&
      git -C "$scratch/tree" add -A &&
      git -C "$scratch/tree" \
        -c user.name=trg -c user.email=trg@invalid -c commit.gpgsign=false \
        commit -q --no-verify --allow-empty -m snapshot
  ) 2>&1 || {
    echo "Test-regression guard: could not create the scratch snapshot commit (#2055); the suite cannot run" >&2
    return 1
  }
}

# _trg_log_failures <label> <failures_nl> — the run log's list of failing tests for a
# red verdict: the count, then the first 20 names (#2055). To stderr, never stdout.
_trg_log_failures() {
  local label="$1" fail="$2" n
  n=$(grep -c . <<<"$fail" || true)
  {
    echo "Test-regression guard: ${label}: ${n} parsed/named failing test(s)"
    if (( n > 0 )); then
      grep . <<<"$fail" | head -20 | sed 's/^/  /' || true
      if (( n > 20 )); then echo "  … and $(( n - 20 )) more"; fi
    fi
  } >&2
  return 0
}

# _trg_run <cmd> [base_sha] — run the suite with a time limit in a scratch copy of the
# tree (never the real checkout, so a killed run cannot leave it changed); combined
# output on stdout, the exit status as the return code.
_trg_run() {
  local cmd="$1" base="${2:-}" limit="${DEV_LEAD_TEST_TIMEOUT:-1500}" scratch rc=0
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/trg.XXXXXX") || return 1
  _trg_stage "$scratch" "$base" || { rm -rf -- "$scratch"; return 1; }
  # PR-controlled code runs here: an ALLOWLIST environment (env -i), not a denylist, so
  # no token — whatever its name — reaches the test process.
  local -a runner=(env -i "PATH=${PATH}" "HOME=${scratch}/home" "TMPDIR=${scratch}/tmp"
    "LANG=${LANG:-C.UTF-8}" "CI=${CI:-true}" "TERM=${TERM:-dumb}"
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1)
  if command -v timeout >/dev/null 2>&1; then
    runner+=(timeout "$limit")
  fi
  ( cd "$scratch/tree" && "${runner[@]}" bash -c "$cmd" 2>&1 ) || rc=$?
  rm -rf -- "$scratch"
  return "$rc"
}

# trg_scan_pass <base_sha>
#   The single impure gatherer. Runs the suite on the CURRENT checkout (the pass's
#   result). Only when it is red, runs it again against <base_sha> in a scratch copy
#   (the real checkout is never touched). Echoes `<verdict>\t<cmd>` on the first line, then the
#   offending tests. Returns 1 only for `regression`. The run log (stderr) gets each
#   suite run's elapsed time and, for any verdict but green, the failing tests (#2055).
trg_scan_pass() {
  local base="${1:-}" cmd out head_rc=0 head_fail base_out base_rc="" base_fail="" base_ran=false t0
  if ! cmd=$(trg_discover_cmd .); then
    printf 'not-run\t\n'
    return 0
  fi
  t0=$SECONDS
  out=$(_trg_run "$cmd") || head_rc=$?
  echo "Test-regression guard: result suite run took $(( SECONDS - t0 ))s (exit ${head_rc})" >&2
  head_fail=$(printf '%s\n' "$out" | trg_extract_failures)
  if (( head_rc != 0 && head_rc != 124 )) && [[ -n "$base" ]] && git cat-file -e "${base}^{commit}" 2>/dev/null; then
    base_rc=0
    t0=$SECONDS
    base_out=$(_trg_run "$cmd" "$base") || base_rc=$?
    echo "Test-regression guard: baseline suite run took $(( SECONDS - t0 ))s (exit ${base_rc})" >&2
    base_fail=$(printf '%s\n' "$base_out" | trg_extract_failures)
    base_ran=true
  fi
  local verdict_out verdict rc=0
  verdict_out=$(trg_classify "$base_ran" "$base_rc" "$base_fail" "$head_rc" "$head_fail") || rc=$?
  verdict=$(printf '%s\n' "$verdict_out" | head -1)
  if [[ "$verdict" != "green" ]]; then
    _trg_log_failures result "$head_fail"
    if [[ "$base_ran" == "true" ]]; then _trg_log_failures baseline "$base_fail"; fi
  fi
  printf '%s\t%s\n' "$verdict" "$cmd"
  printf '%s\n' "$verdict_out" | sed '1d'
  return "$rc"
}
