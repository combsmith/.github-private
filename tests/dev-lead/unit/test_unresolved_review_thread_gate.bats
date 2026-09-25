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

# ────────────────────────────────────────────────────────────────────
# NORMALIZATION (urtg_fetch_review_threads) — raw GraphQL → snapshot
#
# The fetch helper turns a raw reviewThreads GraphQL response into the
# {complete, reviewThreads} snapshot the pure check consumes. A response
# missing pageInfo, hasNextPage, or nodes (or carrying a GraphQL errors
# field, or a second page) is not a complete enumeration and MUST normalize
# to complete:false so the check fails closed rather than under-counting.
# gh is stubbed on PATH so the helper stays offline.
# ────────────────────────────────────────────────────────────────────

_mock_gh() {
  # _mock_gh <raw_json> — install a `gh` shim on PATH that emits <raw_json>.
  MOCK_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  printf '#!/usr/bin/env bash\ncat <<'\''__RAW__'\''\n%s\n__RAW__\n' "$1" > "$MOCK_BIN/gh"
  chmod +x "$MOCK_BIN/gh"
}

_run_fetch() {
  # _run_fetch <raw_json> — stub gh to emit <raw_json>, run urtg_fetch_review_threads.
  _mock_gh "$1"
  run bash -c "export PATH=\"$MOCK_BIN:\$PATH\"; source '$GATE'; urtg_fetch_review_threads 'https://github.com/o/r/pull/1'"
}

@test "fetch: well-formed single-page response → complete:true, threads passed through" {
  _run_fetch '{"data":{"resource":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":true}]}}}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.complete == true'
  echo "$output" | jq -e '.reviewThreads == [{"isResolved":true}]'
}

@test "fetch: response missing pageInfo → complete:false (fail closed)" {
  _run_fetch '{"data":{"resource":{"reviewThreads":{"nodes":[{"isResolved":false}]}}}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.complete == false'
  echo "$output" | jq -e '.reviewThreads == []'
}

@test "fetch: response missing hasNextPage → complete:false (fail closed)" {
  _run_fetch '{"data":{"resource":{"reviewThreads":{"pageInfo":{},"nodes":[]}}}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.complete == false'
}

@test "fetch: response missing nodes → complete:false (fail closed)" {
  _run_fetch '{"data":{"resource":{"reviewThreads":{"pageInfo":{"hasNextPage":false}}}}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.complete == false'
}

@test "fetch: response with GraphQL errors field → complete:false (fail closed)" {
  _run_fetch '{"errors":[{"message":"boom"}],"data":null}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.complete == false'
}

@test "fetch: hasNextPage true (second page) → complete:false (fail closed)" {
  _run_fetch '{"data":{"resource":{"reviewThreads":{"pageInfo":{"hasNextPage":true},"nodes":[{"isResolved":true}]}}}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.complete == false'
}

@test "fetch→check: missing pageInfo normalizes to complete:false and the check fails closed (rc 2)" {
  _mock_gh '{"data":{"resource":{"reviewThreads":{"nodes":[]}}}}'
  run bash -c "export PATH=\"$MOCK_BIN:\$PATH\"; source '$GATE'; s=\$(urtg_fetch_review_threads 'https://github.com/o/r/pull/1'); check_unresolved_review_threads \"\$s\""
  [ "$status" -eq 2 ]
}

@test "fetch: gh exits non-zero → complete:false (fail closed on API failure)" {
  MOCK_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$MOCK_BIN/gh"
  chmod +x "$MOCK_BIN/gh"
  run bash -c "export PATH=\"$MOCK_BIN:\$PATH\"; source '$GATE'; urtg_fetch_review_threads 'https://github.com/o/r/pull/1'"
  [ "$status" -eq 0 ]
  echo "$stdout" | jq -e '.complete == false'
  echo "$stdout" | jq -e '.reviewThreads == []'
}

@test "fetch: gh emits empty output → complete:false (fail closed on no data)" {
  MOCK_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  printf '#!/usr/bin/env bash\necho -n ""\n' > "$MOCK_BIN/gh"
  chmod +x "$MOCK_BIN/gh"
  run bash -c "export PATH=\"$MOCK_BIN:\$PATH\"; source '$GATE'; urtg_fetch_review_threads 'https://github.com/o/r/pull/1'"
  [ "$status" -eq 0 ]
  echo "$stdout" | jq -e '.complete == false'
  echo "$stdout" | jq -e '.reviewThreads == []'
}

@test "fetch: gh emits non-JSON garbage → complete:false (fail closed on parse error)" {
  MOCK_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  printf '#!/usr/bin/env bash\necho "not json at all {{{"\n' > "$MOCK_BIN/gh"
  chmod +x "$MOCK_BIN/gh"
  run bash -c "export PATH=\"$MOCK_BIN:\$PATH\"; source '$GATE'; urtg_fetch_review_threads 'https://github.com/o/r/pull/1'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.complete == false'
  echo "$output" | jq -e '.reviewThreads == []'
}
