#!/usr/bin/env bats
# Regression tests for scripts/list-prs.sh candidate enumeration (issue #1744).
#
# The sweep reported success while silently omitting an open, non-draft,
# non-self-authored PR (#1710) from the candidate pool. Root cause: enumeration
# used `gh search prs` — the eventually-consistent Search API. #1710 had just
# been pushed (its approval dismissed), so the Search index had not yet
# re-indexed it and it was absent from results, while the strongly-consistent
# List API (`gh pr list`) returns it immediately. The omission was invisible
# because filter/scope exclusions were never logged.
#
# These tests pin the fix:
#   - enumeration sources candidates from the List API (`gh pr list`), so an
#     eligible PR is present even when the Search API returns nothing;
#   - every PR excluded by a filter is logged at notice level with its reason,
#     so an omission can never be mistaken for an empty queue;
#   - a per-run enumeration summary reports seen/kept/excluded counts.
#
# gh is fully mocked: `gh repo list` emits repo names per owner, `gh pr list`
# emits a JSON fixture per repo, and `gh search prs` returns nothing — so a test
# passes only if list-prs.sh reads from the List API, not the Search index.
#
# stdout (the candidate URL list) and stderr (the `::notice::` observability
# stream) are captured to separate files so the two channels never bleed
# together — the whole point of the fix is that they are distinct.
#
# Run with: bats tests/test_list_prs_enumeration.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/list-prs.sh"

setup() {
  MOCK_BIN="$BATS_TEST_TMPDIR/mock_bin"
  REPO_LIST_DIR="$BATS_TEST_TMPDIR/repo_list"
  PR_LIST_DIR="$BATS_TEST_TMPDIR/pr_list"
  OUT="$BATS_TEST_TMPDIR/out"
  ERR="$BATS_TEST_TMPDIR/err"
  mkdir -p "$MOCK_BIN" "$REPO_LIST_DIR" "$PR_LIST_DIR"
  export MOCK_BIN REPO_LIST_DIR PR_LIST_DIR
  export PATH="$MOCK_BIN:$PATH"

  export BOT_USER="donpetry-bot"
  export TARGET_ORG="petry-projects"
  unset DELEGATION_ORGS || true

  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
sub="$1 $2"
case "$sub" in
  "repo list")
    owner="$3"
    cat "$REPO_LIST_DIR/${owner}.txt" 2>/dev/null || true
    exit 0
    ;;
  "pr list")
    repo=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--repo" ]; then repo="$2"; break; fi
      shift
    done
    f="$PR_LIST_DIR/${repo//\//__}.json"
    if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
    exit 0
    ;;
  "search prs")
    # The Search API is eventually consistent — the source of the #1744 bug.
    # Returning nothing here proves the candidate pool no longer depends on it.
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$MOCK_BIN/gh"

  # Default: only the org owns repos; the bot account owns none.
  printf 'petry-projects/.github-private\n' > "$REPO_LIST_DIR/petry-projects.txt"
}

# write_prs <repo> <json-array>
write_prs() {
  printf '%s' "$2" > "$PR_LIST_DIR/${1//\//__}.json"
}

# run_list_prs — invoke the script capturing stdout/stderr to $OUT/$ERR.
run_list_prs() {
  bash "$SCRIPT" >"$OUT" 2>"$ERR"
}

@test "eligible open non-draft non-self PR is present in the candidate pool" {
  write_prs "petry-projects/.github-private" \
    '[{"url":"https://github.com/petry-projects/.github-private/pull/1710","author":{"login":"don-petry"},"createdAt":"2026-09-13T00:00:00Z","isDraft":false}]'

  run_list_prs
  grep -qx 'https://github.com/petry-projects/.github-private/pull/1710' "$OUT"
}

@test "eligible PR is found via the List API even when the Search API is empty" {
  # This is the #1710 case: a just-pushed PR the Search index has not re-indexed.
  # The mocked `gh search prs` returns nothing; the PR must still appear because
  # enumeration reads from the strongly-consistent List API.
  write_prs "petry-projects/.github-private" \
    '[{"url":"https://github.com/petry-projects/.github-private/pull/1710","author":{"login":"don-petry"},"createdAt":"2026-09-13T00:00:00Z","isDraft":false}]'

  run_list_prs
  [ "$(grep -c '/pull/1710' "$OUT")" -eq 1 ]
}

@test "draft PR is excluded from the pool AND logged with a reason at notice level" {
  write_prs "petry-projects/.github-private" \
    '[{"url":"https://github.com/petry-projects/.github-private/pull/2000","author":{"login":"don-petry"},"createdAt":"2026-09-13T00:00:00Z","isDraft":true}]'

  run_list_prs
  # Not in the candidate list (stdout)...
  ! grep -q '/pull/2000' "$OUT"
  # ...but observably excluded with its reason (stderr notice).
  grep -q '::notice::' "$ERR"
  grep -q '/pull/2000' "$ERR"
  grep -qi 'draft' "$ERR"
}

@test "self-authored PR is excluded from the pool AND logged with a reason" {
  write_prs "petry-projects/.github-private" \
    '[{"url":"https://github.com/petry-projects/.github-private/pull/2001","author":{"login":"donpetry-bot"},"createdAt":"2026-09-13T00:00:00Z","isDraft":false}]'

  run_list_prs
  ! grep -q '/pull/2001' "$OUT"
  grep -q '::notice::' "$ERR"
  grep -q '/pull/2001' "$ERR"
  grep -qi 'self-authored' "$ERR"
}

@test "an eligible PR is kept while a draft alongside it is dropped and logged" {
  write_prs "petry-projects/.github-private" \
    '[{"url":"https://github.com/petry-projects/.github-private/pull/1710","author":{"login":"don-petry"},"createdAt":"2026-09-13T00:00:00Z","isDraft":false},{"url":"https://github.com/petry-projects/.github-private/pull/2000","author":{"login":"don-petry"},"createdAt":"2026-09-13T00:00:00Z","isDraft":true}]'

  run_list_prs
  grep -qx 'https://github.com/petry-projects/.github-private/pull/1710' "$OUT"
  ! grep -q '/pull/2000' "$OUT"
  grep -q '/pull/2000' "$ERR"
  grep -qi 'draft' "$ERR"
}

@test "enumeration emits a seen/kept/excluded summary at notice level" {
  write_prs "petry-projects/.github-private" \
    '[{"url":"https://github.com/petry-projects/.github-private/pull/1710","author":{"login":"don-petry"},"createdAt":"2026-09-13T00:00:00Z","isDraft":false},{"url":"https://github.com/petry-projects/.github-private/pull/2000","author":{"login":"don-petry"},"createdAt":"2026-09-13T00:00:00Z","isDraft":true}]'

  run_list_prs
  grep -q '::notice::' "$ERR"
  grep -qi 'enumeration' "$ERR"
  grep -qi 'seen' "$ERR"
  grep -qi 'excluded' "$ERR"
}
