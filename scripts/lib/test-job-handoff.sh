#!/usr/bin/env bash
# test-job-handoff.sh — run the test-regression suite in a job that holds no secrets (#2143).
#
# WHAT IS WRONG WITHOUT THIS
#   The test-regression guard (#2013) runs the repo's test suite, which is code from
#   the PR branch. Under `env -i` in a scratch copy (#2019) it no longer inherits a
#   token by accident, but it still runs as the harness's OS user in the job that
#   holds GH_PAT_DON_PETRY, the engine tokens and the API keys. Code that goes looking
#   can read them from /proc/$PPID/environ or from the real checkout's credential.
#
# THE SHAPE (.github/workflows/dev-lead-reusable.yml)
#   dispatch   (work)  the model runs and commits. At the guard point the harness
#                      writes a handoff tarball (tjh_write) and stops. Nothing is pushed.
#   test-suite (test)  no secrets, `permissions: {}`, no checkout. It unpacks the
#                      handoff and runs trg_scan_pass (tjh_run_suite). Its only output
#                      is a JSON verdict.
#   push       (push)  restores the pass's exact commits (tjh_restore,
#                      tjh_apply_result), reads the verdict (tjh_verdict) and pushes
#                      only when the verdict allows. Then it runs everything that
#                      follows a push.
#
# THE HANDOFF (one tar; its sha256 travels as a dispatch job output, so the
# test-suite job cannot swap it before the push job reads it)
#   result.bundle    git bundle of HEAD over the pre-pass head (the push job pushes
#                    these exact commits, so the SHAs in claim replies still match)
#   result-tree.tar  the work tree without .git, untracked files included (deps the
#                    model installed reach the suite, as they did in the scratch copy)
#   base-tree.tar    `git archive` of the pre-pass head (absent when it is unknown)
#   tracked.z        `git ls-files -z` of the result
#   state.json       what the push job needs to re-enter the intent handler
#   guard/           this library and test-regression-guard.sh (the test-suite job
#                    has no credential to check the private scripts repo out)
#
# PURITY / TESTABILITY (ADR-0004)
#   tjh_verdict is PURE. tjh_write, tjh_run_suite, tjh_restore and tjh_apply_result
#   are the gatherers. Sourced under `set -euo pipefail`; helpers only `return`.

set -euo pipefail

TJH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The verdicts trg_scan_pass can report. Anything else from the test job is "no verdict".
TJH_VERDICTS="green preexisting unattributed unbaselined timeout not-run regression"

# tjh_write <out_dir> <base_sha> <state_json> — work job, run from the PR worktree
# with the pass's result committed. Writes <out_dir>/handoff.tar and echoes its
# sha256. Returns 1 if any part could not be written.
tjh_write() {
  local out="$1" base="$2" state="$3" stage rc=0
  mkdir -p "$out" || return 1
  stage=$(mktemp -d "${TMPDIR:-/tmp}/tjh-stage.XXXXXX") || return 1
  mkdir -p "$stage/guard" &&
    printf '%s\n' "$state" > "$stage/state.json" &&
    cp "$TJH_LIB_DIR/test-regression-guard.sh" "$TJH_LIB_DIR/test-job-handoff.sh" "$stage/guard/" &&
    tar --exclude=.git -cf "$stage/result-tree.tar" . &&
    git ls-files -z > "$stage/tracked.z" || rc=1
  if (( rc == 0 )); then
    if [[ -n "$base" ]] && git cat-file -e "${base}^{commit}" 2>/dev/null; then
      git archive -o "$stage/base-tree.tar" "$base" &&
        { git bundle create "$stage/result.bundle" HEAD "^${base}" 2>/dev/null ||
          git bundle create "$stage/result.bundle" HEAD 2>/dev/null; } || rc=1
    else
      git bundle create "$stage/result.bundle" HEAD 2>/dev/null || rc=1
    fi
  fi
  if (( rc == 0 )); then
    tar -C "$stage" -cf "$out/handoff.tar" . || rc=1
  fi
  rm -rf -- "$stage"
  (( rc == 0 )) || { echo "Test-job handoff: could not write the handoff (#2143)" >&2; return 1; }
  sha256sum "$out/handoff.tar" | cut -d' ' -f1
}

# tjh_run_suite <handoff_tar> <workdir> — test job. Rebuilds a throwaway repo from
# the handoff: a commit of the pre-pass tree, then a commit of the result's tracked
# files, with the result's untracked files in the work tree. Runs trg_scan_pass
# against it and echoes the verdict as one JSON line:
#   {"verdict":"…","cmd":"…","tests":["…"]}
# Status 0 for every verdict, regression included: the verdict is the answer. Status
# 2 (and no JSON) when the handoff cannot be unpacked, which the push job reads as
# "no verdict". The suite's run log (timings, failing tests) goes to stderr.
tjh_run_suite() {
  local tar="$1" work="$2" x repo base="" out trg_rc=0 head verdict cmd tests
  x="$work/handoff"
  repo="$work/repo"
  mkdir -p "$x" "$repo" || return 2
  tar -xf "$tar" -C "$x" 2>/dev/null || { echo "Test-job handoff: cannot unpack ${tar} (#2143)" >&2; return 2; }
  [[ -f "$x/result-tree.tar" && -f "$x/tracked.z" ]] || { echo "Test-job handoff: incomplete handoff (#2143)" >&2; return 2; }
  # No inherited git config: the throwaway repo has no remote and no credential.
  if ! base=$(
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
    local -a id=(-c user.name=trg -c user.email=trg@invalid -c commit.gpgsign=false)
    git -C "$repo" init -q || exit 1
    b=""
    if [[ -f "$x/base-tree.tar" ]]; then
      tar -xf "$x/base-tree.tar" -C "$repo" &&
        git -C "$repo" add -A -f &&
        git -C "$repo" "${id[@]}" commit -q --no-verify --allow-empty -m base &&
        b=$(git -C "$repo" rev-parse HEAD) || exit 1
      find "$repo" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} + || exit 1
      git -C "$repo" rm -r -q --cached --ignore-unmatch . >/dev/null || exit 1
    fi
    tar -xf "$x/result-tree.tar" -C "$repo" || exit 1
    ( cd "$repo" && xargs -0 -r git add -f -- < "$x/tracked.z" ) || exit 1
    git -C "$repo" "${id[@]}" commit -q --no-verify --allow-empty -m result || exit 1
    printf '%s' "$b"
  ); then
    echo "Test-job handoff: could not rebuild the pass's result (#2143)" >&2
    return 2
  fi
  out=$(cd "$repo" && trg_scan_pass "$base") || trg_rc=$?
  (( trg_rc <= 1 )) || return 2
  head="${out%%$'\n'*}"
  verdict="${head%%$'\t'*}"
  cmd="${head#*$'\t'}"
  tests=$(printf '%s\n' "$out" | sed '1d')
  jq -cn --arg v "$verdict" --arg c "$cmd" --arg t "$tests" \
    '{verdict:$v, cmd:$c, tests:($t | split("\n") | map(select(length > 0)))}'
}

# tjh_verdict <test_job_result> <verdict_json> — push job. Echoes the verdict in
# trg_scan_pass's format (`<verdict>\t<cmd>`, then the offending tests) and returns
# what trg_scan_pass would: 1 for regression, else 0. Fails CLOSED with status 2
# and a first line `no-verdict\t<reason>` when the test job did not succeed (failed,
# cancelled, timed out, skipped) or its verdict is missing, unreadable or unknown.
# Pure.
tjh_verdict() {
  local result="${1:-}" json="${2:-}" verdict cmd
  if [[ "$result" != "success" ]]; then
    printf 'no-verdict\tthe test-suite job ended %s\n' "${result:-without a result}"
    return 2
  fi
  if ! verdict=$(jq -er '.verdict | strings' <<<"$json" 2>/dev/null) \
     || [[ "$verdict" == *[[:space:]]* ]] || [[ " ${TJH_VERDICTS} " != *" ${verdict} "* ]]; then
    printf 'no-verdict\tthe test-suite job reported no readable verdict\n'
    return 2
  fi
  cmd=$(jq -r '.cmd // "" | tostring' <<<"$json")
  printf '%s\t%s\n' "$verdict" "$cmd"
  jq -r '.tests // [] | .[] | tostring' <<<"$json" 2>/dev/null || true
  [[ "$verdict" == "regression" ]] && return 1
  return 0
}

# tjh_restore <handoff_tar> <expected_sha256> <dest_dir> — push job. Refuses a
# missing tarball or one whose digest is not the one the dispatch job published,
# then unpacks it into <dest_dir>.
tjh_restore() {
  local tar="$1" want="$2" dest="$3" got
  [[ -f "$tar" ]] || { echo "Test-job handoff: the handoff artifact is missing (#2143)" >&2; return 1; }
  got=$(sha256sum "$tar" | cut -d' ' -f1)
  if [[ -z "$want" || "$got" != "$want" ]]; then
    echo "Test-job handoff: digest mismatch (expected ${want:-<none>}, got ${got}) — refusing the handoff (#2143)" >&2
    return 1
  fi
  mkdir -p "$dest" && tar -xf "$tar" -C "$dest"
}

# tjh_apply_result <restored_dir> <result_sha> — push job, run from the PR worktree
# at the pre-pass head. Fetches the pass's commits from the bundle and moves the
# branch to <result_sha>, so the push sends the very commits the work job made. A
# bundle whose prerequisites a shallow clone lacks gets the history fetched first.
tjh_apply_result() {
  local want="$2" b="$1/result.bundle" got
  [[ -f "$b" && -n "$want" ]] || return 1
  if ! git bundle verify -q "$b" >/dev/null 2>&1; then
    # git_history_deepen (lib/git-history.sh, sourced by the caller) is the one
    # copy of the un-shallow logic (#2053).
    if declare -F git_history_deepen >/dev/null; then
      git_history_deepen "${BASE_REF:-main}"
    fi
    git bundle verify -q "$b" >/dev/null 2>&1 || {
      echo "Test-job handoff: the result bundle does not apply to this checkout (#2143)" >&2
      return 1
    }
  fi
  git fetch --quiet "$b" HEAD 2>/dev/null || return 1
  got=$(git rev-parse FETCH_HEAD 2>/dev/null || true)
  if [[ "$got" != "$want" ]]; then
    echo "Test-job handoff: the bundle carries ${got:-nothing}, not the recorded result ${want} (#2143)" >&2
    return 1
  fi
  git reset --quiet --hard "$want"
}
