#!/usr/bin/env bats
# Unit tests for scripts/lib/open-review-threads.sh (#2056).
#
# dev-lead's fix-reviews / review-changes passes read a PR's review threads with
# an unpaginated reviewThreads(first:50). On PR #1953 (66 threads, 65 resolved,
# one open Codex P1 at position 66) the open thread fell past the window, so
# OPEN_THREADS_JSON came out empty and the pass "addressed 0 threads".
# ort_fetch_open_threads paginates until exhausted and fails closed, so a failed
# page fetch can never masquerade as "nothing to do".

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/open-review-threads.sh"

bats_require_minimum_version 1.5.0

setup() {
  STUB_BIN_DIR="$(mktemp -d)"
  FIXTURE_DIR="$(mktemp -d)"
  export STUB_BIN_DIR FIXTURE_DIR
  export GH_CALLS_FILE="$FIXTURE_DIR/calls"
  : > "$GH_CALLS_FILE"

  # Cursor-aware gh stub: serves $FIXTURE_DIR/threads.json (a JSON array of
  # thread nodes) in pages of `first`, using the numeric offset as the cursor.
  # GH_FAIL_PAGE=<n> makes the n-th call (1-based) fail; GH_PAGE_OVERRIDE=<n>
  # with GH_PAGE_BODY replaces the n-th response body verbatim.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
# One line per call (the GraphQL query itself spans many lines).
printf '%s\n' "$*" | tr '\n' ' ' >> "$GH_CALLS_FILE"
echo >> "$GH_CALLS_FILE"
call_no=$(wc -l < "$GH_CALLS_FILE" | tr -d ' ')
if [ -n "${GH_FAIL_PAGE:-}" ] && [ "$call_no" -eq "$GH_FAIL_PAGE" ]; then
  echo "HTTP 502: Bad Gateway" >&2
  exit 1
fi
if [ -n "${GH_PAGE_OVERRIDE:-}" ] && [ "$call_no" -eq "$GH_PAGE_OVERRIDE" ]; then
  printf '%s' "$GH_PAGE_BODY"
  exit 0
fi
query="" cursor="" first=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f|-F)
      case "$2" in
        query=*) query="${2#query=}" ;;
        cursor=*) cursor="${2#cursor=}" ;;
      esac
      shift 2 ;;
    *) shift ;;
  esac
done
first=$(printf '%s' "$query" | grep -o 'reviewThreads(first:[0-9]*' | grep -o '[0-9]*$')
offset="${cursor:-0}"
jq -c --argjson off "$offset" --argjson n "${first:-50}" '
  . as $all
  | ($all[$off:$off+$n]) as $page
  | ($off + ($page | length)) as $end
  | {data:{repository:{pullRequest:{reviewThreads:{
      pageInfo:{hasNextPage:($end < ($all|length)),
                endCursor:(if ($page|length) > 0 then ($end|tostring) else null end)},
      nodes:$page}}}}}' "$FIXTURE_DIR/threads.json"
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export PATH="$STUB_BIN_DIR:$PATH"

  # shellcheck source=scripts/lib/open-review-threads.sh
  source "$LIB"
}

teardown() {
  rm -rf "$STUB_BIN_DIR" "$FIXTURE_DIR"
}

# make_fixture <total> <open_positions...> — writes <total> thread nodes; the
# 1-based positions listed are unresolved, every other thread is resolved.
make_fixture() {
  local total="$1"; shift
  local open_csv
  open_csv=$(IFS=,; echo "$*")
  jq -n --argjson total "$total" --arg open "$open_csv" '
    ($open | split(",") | map(select(length > 0) | tonumber)) as $o
    | [range(1; $total + 1) as $i
       | {id: ("PRRT_" + ($i|tostring)),
          isResolved: (($o | index($i)) == null),
          isOutdated: false, line: $i, path: "scripts/f.sh",
          comments: {nodes: [{body: ("finding " + ($i|tostring)),
                              author: {login: "chatgpt-codex-connector", __typename: "Bot"}}]}}]' \
    > "$FIXTURE_DIR/threads.json"
}

@test "open-review-threads.sh is safe to source under set -euo pipefail" {
  run bash -c "set -euo pipefail; source '$LIB'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ort_fetch_open_threads: 51 threads, only open one is #51 (page boundary at 50) → seen" {
  make_fixture 51 51
  export ORT_PAGE_SIZE=50
  run ort_fetch_open_threads "petry-projects/.github-private" 1953
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].id')" = "PRRT_51" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].line')" = "51" ]
  [ "$(wc -l < "$GH_CALLS_FILE")" -eq 2 ]
}

@test "ort_fetch_open_threads: 101 threads, only open one is #101 (page boundary at 100) → seen" {
  make_fixture 101 101
  run ort_fetch_open_threads "petry-projects/.github-private" 1953
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.[].id] | join(",")')" = "PRRT_101" ]
  [ "$(wc -l < "$GH_CALLS_FILE")" -eq 2 ]
}

@test "ort_fetch_open_threads: PR #1953 shape (66 threads, open at #66) with 50-thread pages → seen" {
  make_fixture 66 66
  export ORT_PAGE_SIZE=50
  run ort_fetch_open_threads "petry-projects/.github-private" 1953
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.[].id] | join(",")')" = "PRRT_66" ]
}

@test "ort_fetch_open_threads: open threads spread across three pages are all collected in order" {
  make_fixture 120 3 50 51 100 101 120
  export ORT_PAGE_SIZE=50
  run ort_fetch_open_threads "petry-projects/.github-private" 7
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.[].line] | join(",")')" = "3,50,51,100,101,120" ]
  [ "$(wc -l < "$GH_CALLS_FILE")" -eq 3 ]
}

@test "ort_fetch_open_threads: exactly 100 threads in one full page → single fetch, open one seen" {
  make_fixture 100 100
  run ort_fetch_open_threads "petry-projects/.github-private" 7
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].id')" = "PRRT_100" ]
  [ "$(wc -l < "$GH_CALLS_FILE")" -eq 1 ]
}

@test "ort_fetch_open_threads: default page size is the GraphQL max (100)" {
  make_fixture 1
  run ort_fetch_open_threads "petry-projects/.github-private" 7
  [ "$status" -eq 0 ]
  grep -q 'reviewThreads(first:100' "$GH_CALLS_FILE"
}

@test "ort_fetch_open_threads: second page passes the first page's endCursor" {
  make_fixture 51 51
  export ORT_PAGE_SIZE=50
  run ort_fetch_open_threads "petry-projects/.github-private" 7
  [ "$status" -eq 0 ]
  sed -n 2p "$GH_CALLS_FILE" | grep -q 'cursor=50'
  ! sed -n 1p "$GH_CALLS_FILE" | grep -q 'cursor='
}

@test "ort_fetch_open_threads: emits the thread fields the prompts consume" {
  make_fixture 1 1
  run ort_fetch_open_threads "petry-projects/.github-private" 7
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.[0] | has("id") and has("isResolved") and has("isOutdated") and has("line") and has("path") and (.comments.nodes[0].author.__typename == "Bot")'
  # The fixture is returned verbatim by the stub, so assert the query itself
  # selects every field the prompts consume.
  local sel
  for sel in 'id isResolved isOutdated line path' 'comments(first:5)' 'body author { login __typename }'; do
    grep -qF -- "$sel" "$GH_CALLS_FILE"
  done
}

@test "ort_fetch_open_threads: missing/null/non-boolean hasNextPage → non-zero (never a silent truncation)" {
  make_fixture 10 5
  export GH_PAGE_OVERRIDE=1
  local body
  for body in \
    '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"endCursor":"5"},"nodes":[]}}}}}' \
    '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":null,"endCursor":"5"},"nodes":[]}}}}}' \
    '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":"true","endCursor":"5"},"nodes":[]}}}}}'; do
    : > "$GH_CALLS_FILE"  # the stub's page override keys off the call count
    GH_PAGE_BODY="$body" run --separate-stderr ort_fetch_open_threads "petry-projects/.github-private" 7
    [ "$status" -eq 1 ]
    [ -z "$output" ]
  done
}

@test "ort_fetch_open_threads: endCursor that does not advance → non-zero (no infinite loop)" {
  make_fixture 10 5
  export GH_PAGE_OVERRIDE=2
  export GH_PAGE_BODY='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"5"},"nodes":[]}}}}}'
  export ORT_PAGE_SIZE=5
  run --separate-stderr ort_fetch_open_threads "petry-projects/.github-private" 7
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "ort_fetch_open_threads: no open threads → empty array, success" {
  make_fixture 60
  export ORT_PAGE_SIZE=50
  run ort_fetch_open_threads "petry-projects/.github-private" 7
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "ort_fetch_open_threads: zero threads → empty array, success" {
  echo '[]' > "$FIXTURE_DIR/threads.json"
  run ort_fetch_open_threads "petry-projects/.github-private" 7
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# ── fail closed ──────────────────────────────────────────────────────────────

@test "ort_fetch_open_threads: failed second page fetch → non-zero, no partial list on stdout" {
  make_fixture 101 1 101
  export GH_FAIL_PAGE=2
  run --separate-stderr ort_fetch_open_threads "petry-projects/.github-private" 7
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "ort_fetch_open_threads: failed first page fetch → non-zero (not an empty list)" {
  make_fixture 10 5
  export GH_FAIL_PAGE=1
  run --separate-stderr ort_fetch_open_threads "petry-projects/.github-private" 7
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "ort_fetch_open_threads: GraphQL errors payload → non-zero" {
  make_fixture 10 5
  export GH_PAGE_OVERRIDE=1
  export GH_PAGE_BODY='{"data":null,"errors":[{"message":"Something went wrong"}]}'
  run --separate-stderr ort_fetch_open_threads "petry-projects/.github-private" 7
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "ort_fetch_open_threads: response missing reviewThreads.nodes → non-zero" {
  make_fixture 10 5
  export GH_PAGE_OVERRIDE=1
  export GH_PAGE_BODY='{}'
  run --separate-stderr ort_fetch_open_threads "petry-projects/.github-private" 7
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "ort_fetch_open_threads: non-JSON response → non-zero" {
  make_fixture 10 5
  export GH_PAGE_OVERRIDE=1
  export GH_PAGE_BODY='<html>502</html>'
  run --separate-stderr ort_fetch_open_threads "petry-projects/.github-private" 7
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "ort_fetch_open_threads: hasNextPage without an endCursor → non-zero (never a silent truncation)" {
  make_fixture 10 5
  export GH_PAGE_OVERRIDE=1
  export GH_PAGE_BODY='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":null},"nodes":[]}}}}}'
  run --separate-stderr ort_fetch_open_threads "petry-projects/.github-private" 7
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "ort_fetch_open_threads: missing repo or PR argument → non-zero without calling gh" {
  run --separate-stderr ort_fetch_open_threads "" 7
  [ "$status" -eq 1 ]
  run --separate-stderr ort_fetch_open_threads "petry-projects/.github-private" ""
  [ "$status" -eq 1 ]
  [ ! -s "$GH_CALLS_FILE" ]
}

@test "ort_fetch_open_threads: a large open-thread set (>128KB) is merged without hitting argv limits" {
  # 150 open threads, each with a ~2KB body → ~300KB of JSON across two pages.
  jq -n '[range(1; 151) as $i | {id: ("PRRT_" + ($i|tostring)), isResolved: false,
          isOutdated: false, line: $i, path: "scripts/f.sh",
          comments: {nodes: [{body: ("x" * 2000), author: {login: "coderabbitai", __typename: "Bot"}}]}}]' \
    > "$FIXTURE_DIR/threads.json"
  run ort_fetch_open_threads "petry-projects/.github-private" 7
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" -eq 150 ]
}
