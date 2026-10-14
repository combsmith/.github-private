#!/usr/bin/env bash
# test-tamper-guard.sh — a fix pass must not silently rewrite an existing test to
# make its own change pass (#2013).
#
# WHAT IS WRONG WITHOUT THIS
#   On petry-projects/.github#1220 a cubic finding said, literally, "update the
#   older test to assert failure precedence so the Bats suite can pass". dev-lead
#   applied it: it rewrote an existing test (#1023 "success precedence …") into
#   "failure precedence", inverting a deliberate behavior, and the rewritten test
#   did not even match the branch. "Do not modify tests to force a pass" lived only
#   in the prompt, so nothing in the harness could stop it.
#
# THE RULE
#   A fix pass (base = the pre-pass head) is:
#     clean      it changes no existing line of a test file and adds no skip —
#                ADDING a new test is always fine;
#     justified  it does change/delete an existing test line or add a skip, AND a
#                commit in the pass carries an explicit, cited
#                `Test-Change-Justification: <why, with a reference>` trailer;
#     tampered   it does so with no justification. The harness refuses to push and
#                escalates to a human.
#   "Changed" means the test file has REMOVED lines in `git diff --numstat` (an
#   edit is a removal + an addition; a deletion is all removals), so a pure
#   addition never trips it.
#
# "EXISTING" MEANS EXISTING BEFORE THE PR (#2141)
#   The pass diff is still taken from the pre-pass head, but a removed line counts
#   only when it is present at the MERGE BASE of the PR branch and its base branch,
#   and an added skip counts only in a test file that exists there. A test file,
#   case or assertion the PR itself added is ordinary review work and needs no
#   trailer (PR #2135: editing a test the PR added was refused and five unrelated
#   "Fixed" replies were retracted). When the pass touches a test file, a merge
#   base that cannot be resolved fails closed (`unknown`), exactly like an
#   unresolvable pre-pass head; a pass that touches no test file needs no merge
#   base (and no fetch).
#
# PURITY / TESTABILITY (ADR-0004)
#   ttg_is_test_path, ttg_touched_existing_tests, ttg_count_added_skips,
#   ttg_count_preexisting_removals, ttg_numstat_has_tests, ttg_has_justification
#   and ttg_classify are PURE. ttg_scan_pass, ttg_pass_touches_tests and
#   ttg_resolve_merge_base are the impure gatherers (all git calls). Sourced under `set -euo pipefail`; helpers only `return`, never
#   `exit`.

set -euo pipefail

# git_ensure_merge_base (#2053) — the one copy of the un-shallow logic.
if ! declare -F git_ensure_merge_base >/dev/null; then
  # shellcheck source=scripts/lib/git-history.sh
  source "$(dirname "${BASH_SOURCE[0]}")/git-history.sh"
fi

# Minimum length of the justification text — rules out a bare "so it passes".
readonly _TTG_MIN_JUSTIFICATION_CHARS=20

# Added lines that silence a test, across the frameworks the org uses.
readonly _TTG_SKIP_RE='^\+[[:space:]]*(skip([[:space:]]|$|\()|@pytest\.mark\.(skip|xfail)|pytestmark[[:space:]]*=[[:space:]]*(\[[[:space:]]*)?pytest\.mark\.(skip|xfail)|pytest\.(skip|xfail|importorskip)\(|@unittest\.skip|@Disabled|@Ignore|#\[ignore\]|t\.Skip(Now|f)?\(|(it|test|describe)\.(skip|todo)\(|x(it|describe|test)\()'

# ttg_is_test_path <path>
#   0 when <path> is a test file: under a tests?/ / __tests__/ / spec/ directory, a
#   .bats file, or a test-named file (test_*.py, *_test.*, *.test.*, *.spec.*,
#   *_spec.rb). Pure.
ttg_is_test_path() {
  local p="${1:-}"
  [[ -z "$p" ]] && return 1
  local base="${p##*/}"
  case "/$p" in
    */tests/*|*/test/*|*/__tests__/*|*/spec/*) return 0 ;;
  esac
  case "$base" in
    *.bats|test_*.py|*_test.*|*.test.*|*.spec.*|*_spec.rb) return 0 ;;
  esac
  return 1
}

# ttg_touched_existing_tests <numstat>
#   <numstat> is `git diff --numstat` output (`added\tdeleted\tpath`). Echoes, one
#   per line, every test path with removed lines (changed or deleted existing
#   lines). A binary row (`-\t-`) on a test path is reported too (fail closed).
#   Pure.
ttg_touched_existing_tests() {
  local numstat="${1:-}"
  local _added deleted path
  while IFS=$'\t' read -r _added deleted path; do
    [[ -z "${path:-}" ]] && continue
    ttg_is_test_path "$path" || continue
    if [[ "$deleted" == "-" ]] || { [[ "$deleted" =~ ^[0-9]+$ ]] && (( deleted > 0 )); }; then
      printf '%s\n' "$path"
    fi
  done <<<"$numstat"
}

# ttg_count_added_skips <unified_diff>
#   Number of ADDED lines in test files (per the `+++ b/<path>` headers) that skip
#   or disable a test. Pure.
ttg_count_added_skips() {
  local diff="${1:-}"
  local line cur="" n=0
  while IFS= read -r line; do
    if [[ "$line" == "+++ "* ]]; then
      cur="${line#+++ }"
      cur="${cur#b/}"
      continue
    fi
    [[ -z "$cur" ]] && continue
    ttg_is_test_path "$cur" || continue
    [[ "$line" =~ $_TTG_SKIP_RE ]] && n=$((n + 1))
  done <<<"$diff"
  echo "$n"
}

# ttg_count_preexisting_removals <pass_file_diff> <pr_file_diff>
#   Both are `git diff --unified=0` output for ONE file: <pass_file_diff> from the
#   pre-pass head to the pass result, <pr_file_diff> from the merge base to the
#   pre-pass head. Echoes how many lines the pass removed that the PR did NOT add,
#   i.e. lines that were already there at the merge base. Works on line numbers in
#   the pre-pass head (the old side of the pass diff, the new side of the PR diff),
#   so a common line such as `}` is never mistaken for a pre-PR one. A file the PR
#   created is all PR-added, so it always yields 0. Pure.
ttg_count_preexisting_removals() {
  local pass_diff="${1:-}" pr_diff="${2:-}"
  local line start count i n=0 l
  local -a added=()
  while IFS= read -r line; do
    [[ "$line" =~ ^@@\ -[0-9]+(,[0-9]+)?\ \+([0-9]+)(,([0-9]+))?\ @@ ]] || continue
    start="${BASH_REMATCH[2]}"
    count="${BASH_REMATCH[4]:-1}"
    (( count > 0 )) && added+=("$start" "$((start + count - 1))")
  done <<<"$pr_diff"
  while IFS= read -r line; do
    [[ "$line" =~ ^@@\ -([0-9]+)(,([0-9]+))?\ \+ ]] || continue
    start="${BASH_REMATCH[1]}"
    count="${BASH_REMATCH[3]:-1}"
    for (( l = start; l < start + count; l++ )); do
      for (( i = 0; i < ${#added[@]}; i += 2 )); do
        (( l >= added[i] && l <= added[i + 1] )) && continue 2
      done
      n=$((n + 1))
    done
  done <<<"$pass_diff"
  echo "$n"
}

# ttg_has_justification <commit_messages>
#   0 when some line is `Test-Change-Justification: <text>` with at least
#   _TTG_MIN_JUSTIFICATION_CHARS of non-blank text AND a recognizable reference
#   (an issue/PR `#123`, a 7-40 hex commit SHA, or a URL) to the review, issue, or
#   commit that establishes the old test was wrong. Pure.
ttg_has_justification() {
  local msgs="${1:-}" line text
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*Test-Change-Justification:[[:space:]]*(.*)$ ]] || continue
    text="${BASH_REMATCH[1]}"
    text="${text%"${text##*[![:space:]]}"}"
    (( ${#text} >= _TTG_MIN_JUSTIFICATION_CHARS )) || continue
    [[ "$text" =~ (^|[^[:alnum:]])#[0-9]+ || "$text" =~ (^|[^[:alnum:]])[0-9a-fA-F]{7,40}($|[^[:alnum:]]) || "$text" =~ https?:// ]] && return 0
  done <<<"$msgs"
  return 1
}

# ttg_classify <touched_files_nl> <added_skips> <justified:true|false>
#   Echoes clean | justified | tampered; returns 1 only for tampered. A
#   non-numeric skip count fails closed (tampered). Pure.
ttg_classify() {
  local touched="${1:-}" skips="${2:-}" justified="${3:-false}"
  local has_touch=0
  [[ -n "$(printf '%s' "$touched" | tr -d '[:space:]')" ]] && has_touch=1
  if ! [[ "$skips" =~ ^[0-9]+$ ]]; then
    echo "tampered"
    return 1
  fi
  if (( has_touch == 0 && skips == 0 )); then
    echo "clean"
    return 0
  fi
  if [[ "$justified" == "true" ]]; then
    echo "justified"
    return 0
  fi
  echo "tampered"
  return 1
}

# ttg_numstat_has_tests <numstat>
#   0 when some row of `git diff --numstat` output is a test path. Pure.
ttg_numstat_has_tests() {
  local numstat="${1:-}" _a _d path
  while IFS=$'\t' read -r _a _d path; do
    [[ -n "${path:-}" ]] && ttg_is_test_path "$path" && return 0
  done <<<"$numstat"
  return 1
}

# ttg_pass_touches_tests <base_sha>
#   Impure. 0 when the working tree differs from <base_sha> in some test file, or
#   when that cannot be determined (so the caller still resolves the merge base and
#   ttg_scan_pass decides). 1 only when the pass provably touches no test file.
ttg_pass_touches_tests() {
  local base="${1:-}" numstat
  [[ -n "$base" ]] || return 0
  numstat=$(git -c core.quotePath=false diff --no-renames --numstat "$base" 2>/dev/null) || return 0
  ttg_numstat_has_tests "$numstat"
}

# ttg_scan_pass <base_sha> [head] <merge_base_sha>
#   The impure gatherer. Compares <base_sha> (the pre-pass head) against the
#   WORKING TREE (so committed and not-yet-committed edits are both seen), keeps
#   only removals of lines present at <merge_base_sha> and skips added to test
#   files that exist there (#2141), reads the justification from the commit
#   messages in <base_sha>..<head>, and echoes the verdict on the first line
#   followed by the offending test paths (one per line). Returns 0 for
#   clean/justified, 1 for tampered, 2 (echoing `unknown`) when <base_sha> is
#   empty or does not resolve, or when the pass touches a test file and
#   <merge_base_sha> is empty or does not resolve.
ttg_scan_pass() {
  local base="${1:-}" head="${2:-HEAD}" mb="${3:-}"
  if [[ -z "$base" ]] || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
    echo "unknown"
    return 2
  fi
  local numstat diff msgs candidates touched="" skips justified=false verdict rc=0
  local path pass_fd pr_fd removed _a _d
  local -a mb_tests=()
  numstat=$(git -c core.quotePath=false diff --no-renames --numstat "$base" 2>/dev/null) || { echo "unknown"; return 2; }
  # A pass that touches no test file is clean whatever the merge base is; one that
  # does cannot be judged without it (fail closed, #2141).
  if ! ttg_numstat_has_tests "$numstat"; then
    echo "clean"
    return 0
  fi
  if [[ -z "$mb" ]] || ! git cat-file -e "${mb}^{commit}" 2>/dev/null; then
    echo "unknown"
    return 2
  fi
  candidates=$(ttg_touched_existing_tests "$numstat")
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    # A file absent at the merge base was added by the PR: nothing in it pre-dates it.
    git cat-file -e "${mb}:${path}" 2>/dev/null || continue
    if [[ $'\n'"$numstat"$'\n' == *$'\n-\t-\t'"$path"$'\n'* ]]; then
      # Binary: no lines to compare, so a pre-PR file fails closed.
      touched+="${path}"$'\n'
      continue
    fi
    pass_fd=$(git --literal-pathspecs diff --no-renames --unified=0 "$base" -- "$path" 2>/dev/null) || { echo "unknown"; return 2; }
    pr_fd=$(git --literal-pathspecs diff --no-renames --unified=0 "$mb" "$base" -- "$path" 2>/dev/null) || { echo "unknown"; return 2; }
    removed=$(ttg_count_preexisting_removals "$pass_fd" "$pr_fd")
    (( removed > 0 )) && touched+="${path}"$'\n'
  done <<<"$candidates"
  touched="${touched%$'\n'}"
  # Skips count only in test files that exist at the merge base.
  while IFS=$'\t' read -r _a _d path; do
    [[ -z "${path:-}" ]] && continue
    ttg_is_test_path "$path" || continue
    git cat-file -e "${mb}:${path}" 2>/dev/null && mb_tests+=("$path")
  done <<<"$numstat"
  diff=""
  if (( ${#mb_tests[@]} > 0 )); then
    diff=$(git -c core.quotePath=false --literal-pathspecs diff --no-renames --unified=0 "$base" -- "${mb_tests[@]}" 2>/dev/null) || { echo "unknown"; return 2; }
  fi
  msgs=$(git log --format=%B "${base}..${head}" 2>/dev/null || true)
  skips=$(ttg_count_added_skips "$diff")
  ttg_has_justification "$msgs" && justified=true
  verdict=$(ttg_classify "$touched" "$skips" "$justified") || rc=$?
  echo "$verdict"
  [[ -n "$touched" ]] && printf '%s\n' "$touched"
  return "$rc"
}

# ttg_resolve_merge_base <base_ref> <pre_pass_sha> [head_ref]
#   Impure. Makes the merge base resolvable on a shallow checkout with
#   git_ensure_merge_base (#2053), then echoes the merge base of <pre_pass_sha>
#   and origin/<base_ref>. Returns non-zero with no SHA on stdout when it cannot
#   be resolved (history unavailable, base not fetchable, unrelated histories);
#   the reason goes to stderr. Callers must treat that as a refusal (fail closed).
ttg_resolve_merge_base() {
  local base_ref="${1:-}" pre_pass="${2:-}" head_ref="${3:-}"
  local msg rc=0 mb
  if [[ -z "$base_ref" || -z "$pre_pass" ]]; then
    echo "test-tamper guard: base ref or pre-pass head missing — merge base unresolvable" >&2
    return 2
  fi
  msg=$(git_ensure_merge_base "$base_ref" "$head_ref") || rc=$?
  if (( rc != 0 )); then
    echo "test-tamper guard: merge base with origin/${base_ref} unresolvable (rc ${rc})${msg:+: ${msg}}" >&2
    return 2
  fi
  mb=$(git merge-base "$pre_pass" "origin/${base_ref}" 2>/dev/null) || mb=""
  if [[ -z "$mb" ]]; then
    echo "test-tamper guard: no merge base between ${pre_pass} and origin/${base_ref}" >&2
    return 2
  fi
  echo "$mb"
}
