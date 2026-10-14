#!/usr/bin/env bats
# Tests for scripts/sync-scope-guard.sh — the WRAPPER policy around the pure
# sync-scope library (scripts/lib/sync-scope-check.sh, #1700 AC1, #1523).
#
# The pure matching logic is covered by tests/test_sync_scope_check.bats. This
# file pins the wrapper's I/O-driven policy branches, with `gh` mocked on PATH so
# no network call is made:
#   * a human PR (no sync label, no marker) passes — the guard never applies (AC4)
#   * a generated sync PR with NO declared-paths manifest FAILS closed: with no
#     manifest the diff is unbounded, the #1523 hole, so it must exit nonzero
#   * a generated sync PR that DOES declare paths still enforces scope (a diff
#     inside its manifest passes)
#
# Run with: bats tests/test_sync_scope_guard.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/sync-scope-guard.sh"

# _install_gh_mock <labels_json> <body> [files_newline]
#   Stub `gh` so:
#     gh pr view ... --json labels,body  -> {"labels":[...],"body":"..."}
#     gh api repos/.../files --paginate  -> one filename per line (optional)
_install_gh_mock() {
  MOCK_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/mock_bin.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
  export MOCK_BIN
  export MOCK_PR_JSON="{\"labels\":$1,\"body\":$(printf '%s' "$2" | jq -Rs .)}"
  export MOCK_FILES="${3:-}"
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") printf '%s' "$MOCK_PR_JSON" ;;
  "api "*|"api") printf '%s' "$MOCK_FILES" ;;
  *) : ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"
  export PATH="$MOCK_BIN:$PATH"
}

teardown() {
  rm -rf "${MOCK_BIN:-}"
}

@test "wrapper: a human PR (no label, no marker) passes — guard does not apply (AC4)" {
  _install_gh_mock '[{"name":"bug"}]' "a normal human PR body"
  PR_NUMBER=42 REPO="petry-projects/.github-private" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scope check does not apply"* ]]
}

@test "wrapper: a labelled sync PR with NO path manifest FAILS closed (#1523)" {
  _install_gh_mock '[{"name":"standards-sync"}]' "regenerate me — no declared-paths marker here"
  PR_NUMBER=99 REPO="petry-projects/.github-private" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"declares no path manifest"* ]]
}

@test "wrapper: a sync PR whose diff stays inside its declared manifest passes" {
  body=$'syncing one stub\n<!-- standards-sync:declared-paths\n.github/workflows/claude.yml\n-->\n'
  _install_gh_mock '[{"name":"standards-sync"}]' "$body" $'.github/workflows/claude.yml\n'
  PR_NUMBER=7 REPO="petry-projects/.github-private" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"within the declared sync scope"* ]]
}

@test "wrapper: a sync PR whose diff strays outside its declared manifest FAILS" {
  body=$'syncing one stub\n<!-- standards-sync:declared-paths\n.github/workflows/claude.yml\n-->\n'
  _install_gh_mock '[{"name":"standards-sync"}]' "$body" $'.github/workflows/claude.yml\npackage.json\n'
  PR_NUMBER=8 REPO="petry-projects/.github-private" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"out of scope: package.json"* ]]
}
