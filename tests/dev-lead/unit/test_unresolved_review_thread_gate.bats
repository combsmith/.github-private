#!/usr/bin/env bats
# Tests for unresolved-review-thread-gate.sh (issue #1766)
#
# Mechanical enforcement of decision gate 4 ("No unresolved review threads
# requesting changes", prompts/shared.md). Distinct from the #1415 maintainer
# review-thread gate: this gate counts EVERY unresolved review thread regardless
# of author — the same unit the `required_review_thread_resolution` ruleset uses
# to block merge — because an `approve` while any thread is unresolved is
# contradictory (the PR cannot merge). The gate on PR #1742 was defeated because
# the maintainer gate excludes advisory bots (gemini-code-assist, coderabbitai),
# which authored all 15 unresolved threads.
#
#   check_unresolved_review_threads <threads_json>
#     0 = enumeration complete AND zero unresolved threads → approval allowed
#     1 = one or more unresolved review threads → withhold approval (escalate)
#     2 = the snapshot cannot be evaluated (missing/empty/malformed/incomplete
#         pagination) → fail closed (escalate). An unknown count is never zero.

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME%/*}")" && pwd)/../../scripts"
  GATE="$SCRIPT_DIR/lib/unresolved-review-thread-gate.sh"
}

teardown() {
  unset SCRIPT_DIR
}

_run_check() {
  # _run_check <threads_json>
  run bash -c "source '$GATE'; check_unresolved_review_threads \"\$1\"" _ "$1"
}

# ────────────────────────────────────────────────────────────────────
# STRUCTURAL TESTS
# ────────────────────────────────────────────────────────────────────

@test "Unresolved-thread gate: script is executable" {
  [ -x "$GATE" ]
}

@test "Unresolved-thread gate: script has correct shebang" {
  (head -n 1 "$GATE" || true) | grep -q "^#!/usr/bin/env bash"
}

@test "Unresolved-thread gate: script uses set -euo pipefail" {
  grep -q "^set -euo pipefail" "$GATE"
}

@test "Unresolved-thread gate: defines check_unresolved_review_threads function" {
  grep -q "check_unresolved_review_threads()" "$GATE"
}

@test "Unresolved-thread gate: defines urtg_fetch_review_threads function" {
  grep -q "urtg_fetch_review_threads()" "$GATE"
}

@test "Unresolved-thread gate: BASH_SOURCE guard prevents source-time execution" {
  grep -q 'if \[\[ "${BASH_SOURCE\[0\]}" = "${0}" \]\]' "$GATE"
}

@test "Unresolved-thread gate: shellcheck passes" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  shellcheck --shell=bash --severity=warning "$GATE"
}

# ────────────────────────────────────────────────────────────────────
# CLEAR (rc 0) — enumeration complete, no unresolved threads
# ────────────────────────────────────────────────────────────────────

@test "check: complete snapshot with no threads → 0 (approval allowed)" {
  _run_check '{"complete": true, "reviewThreads": []}'
  [ "$status" -eq 0 ]
}

@test "check: complete snapshot where every thread is resolved → 0 (approval allowed)" {
  _run_check '{"complete": true, "reviewThreads": [{"isResolved": true}, {"isResolved": true}]}'
  [ "$status" -eq 0 ]
}

# ────────────────────────────────────────────────────────────────────
# BLOCK (rc 1) — at least one unresolved thread
# ────────────────────────────────────────────────────────────────────

@test "check: one unresolved thread → 1 (withhold approval)" {
  _run_check '{"complete": true, "reviewThreads": [{"isResolved": false}]}'
  [ "$status" -eq 1 ]
}

@test "check: mixed resolved + unresolved → 1 (withhold approval)" {
  _run_check '{"complete": true, "reviewThreads": [{"isResolved": true}, {"isResolved": false}, {"isResolved": true}]}'
  [ "$status" -eq 1 ]
}

@test "check: #1742 shape — 15 unresolved advisory-bot threads → 1 (withhold approval)" {
  # The exact defect: an author-agnostic count blocks where the maintainer gate
  # (which excludes advisory bots) let it through.
  local threads
  threads=$(jq -c -n '{complete: true, reviewThreads: [range(15) | {isResolved: false}]}')
  _run_check "$threads"
  [ "$status" -eq 1 ]
}

@test "check: a thread missing isResolved is treated as unresolved → 1 (fail closed per-thread)" {
  _run_check '{"complete": true, "reviewThreads": [{}]}'
  [ "$status" -eq 1 ]
}

# ────────────────────────────────────────────────────────────────────
# FAIL CLOSED (rc 2) — snapshot cannot be evaluated
# ────────────────────────────────────────────────────────────────────

@test "check: empty string → 2 (fail closed)" {
  _run_check ""
  [ "$status" -eq 2 ]
}

@test "check: malformed JSON → 2 (fail closed)" {
  _run_check '{not json'
  [ "$status" -eq 2 ]
}

@test "check: incomplete enumeration (pagination) → 2 (fail closed, unknown != zero)" {
  # complete=false models hasNextPage=true or an API failure — the count of
  # unresolved threads is unknown, so it must NOT read as zero.
  _run_check '{"complete": false, "reviewThreads": []}'
  [ "$status" -eq 2 ]
}

@test "check: complete flag absent → 2 (fail closed)" {
  _run_check '{"reviewThreads": []}'
  [ "$status" -eq 2 ]
}

@test "check: non-object JSON (array) → 2 (fail closed)" {
  _run_check '[]'
  [ "$status" -eq 2 ]
}
