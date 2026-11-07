#!/usr/bin/env bats
# Unit tests for the shared PR-context prefetch (epic #1101, Story 2 / #1103):
# prefetch_pr_context <pr_url> <pr_head_sha> <full_diff_file> [out_dir].
#
# The prefetch gathers the FULL PR diff + a superset metadata JSON ONCE and
# persists them to SHA-bound files exposed to the agentic tiers, behind a
# DEFAULT-OFF feature flag (PREFETCH_CONTEXT_ENABLED). It must:
#   - OFF  => write ZERO files and export ZERO env vars (byte-identical no-op),
#   - ON   => write the full (untruncated) diff + superset metadata, each
#             SHA-stamped, and export PR_CONTEXT_DIFF_FILE / PR_CONTEXT_METADATA_FILE,
#   - reuse the already-fetched full diff (no extra `gh pr diff`) and perform
#     exactly ONE additional `gh pr view` for the superset metadata,
#   - degrade gracefully on gh rate-limit (return the skip sentinel 100) rather
#     than crashing the run.
#
# `gh` is stubbed via a PATH shim that logs every invocation so we can assert
# fetch volume; `is_rate_limited` is loaded from engine.sh.
#
# Run with: bats tests/test_prefetch_context.bats

setup() {
  # engine.sh provides is_rate_limited (used by the rate-limit degrade path).
  export REVIEW_ENGINE="claude"
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/engine.sh" >/dev/null 2>&1 || true
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/pr-context-prefetch.sh"

  STUB_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  export PATH="$STUB_DIR:$PATH"
  export GH_CALL_LOG="$STUB_DIR/gh_calls.log"
  : > "$GH_CALL_LOG"

  OUT_DIR="$STUB_DIR/cascade"
  mkdir -p "$OUT_DIR"

  PR_URL="https://github.com/combsmith/example/pull/42"
  SHA="abc123def456"

  # A full diff (more lines than any triage truncation) written to a file the
  # prefetch is expected to REUSE rather than re-fetch.
  FULL_DIFF_FILE="$STUB_DIR/full-diff.txt"
  {
    for i in $(seq 1 5000); do printf 'diff line %d\n' "$i"; done
  } > "$FULL_DIFF_FILE"

  # Metadata JSON the `gh pr view` stub returns — a superset of every field the
  # deep/audit/single and rubber-duck prompts read.
  export STUB_META_JSON='{"number":42,"title":"T","headRefOid":"abc123def456","headRepository":{"name":"example"},"headRepositoryOwner":{"login":"combsmith"},"repository":{"name":"example"},"files":[{"path":"a.sh","status":"modified","additions":3,"deletions":1,"patch":"@@"}],"reviews":[],"comments":[],"commits":[]}'
}

teardown() {
  rm -rf "$STUB_DIR"
}

# Install a `gh` stub that logs calls and prints STUB_META_JSON for `pr view`.
_install_gh_stub() {
  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALL_LOG"
# The real CLI refuses a field it does not know.
if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ ",$*," =~ [\ ,]repository[,\ ] ]]; then
  echo 'Unknown JSON field: "repository"' >&2
  exit 1
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  printf '%s' "$STUB_META_JSON"
  exit 0
fi
exit 0
STUB
  chmod +x "$STUB_DIR/gh"
}

# Install a `gh` stub whose `pr view` fails with a rate-limit message on stderr.
_install_gh_rate_limited_stub() {
  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALL_LOG"
# The real CLI refuses a field it does not know.
if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ ",$*," =~ [\ ,]repository[,\ ] ]]; then
  echo 'Unknown JSON field: "repository"' >&2
  exit 1
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo "API rate limit exceeded for user" >&2
  exit 1
fi
exit 0
STUB
  chmod +x "$STUB_DIR/gh"
}

# ---------------------------------------------------------------------------
# OFF: default-off => zero files, zero env exports, zero fetches
# ---------------------------------------------------------------------------
@test "prefetch OFF (unset): writes no files and exports nothing" {
  _install_gh_stub
  unset PREFETCH_CONTEXT_ENABLED
  unset PR_CONTEXT_DIFF_FILE PR_CONTEXT_METADATA_FILE

  prefetch_pr_context "$PR_URL" "$SHA" "$FULL_DIFF_FILE" "$OUT_DIR"

  [ ! -f "$OUT_DIR/pr-context-diff.txt" ]
  [ ! -f "$OUT_DIR/pr-context-metadata.json" ]
  [ -z "${PR_CONTEXT_DIFF_FILE:-}" ]
  [ -z "${PR_CONTEXT_METADATA_FILE:-}" ]
  # No gh call at all when the feature is off.
  [ ! -s "$GH_CALL_LOG" ]
}

@test "prefetch OFF (explicit false): writes no files and exports nothing" {
  _install_gh_stub
  export PREFETCH_CONTEXT_ENABLED=false
  unset PR_CONTEXT_DIFF_FILE PR_CONTEXT_METADATA_FILE

  prefetch_pr_context "$PR_URL" "$SHA" "$FULL_DIFF_FILE" "$OUT_DIR"

  [ ! -f "$OUT_DIR/pr-context-diff.txt" ]
  [ ! -f "$OUT_DIR/pr-context-metadata.json" ]
  [ -z "${PR_CONTEXT_DIFF_FILE:-}" ]
  [ -z "${PR_CONTEXT_METADATA_FILE:-}" ]
}

# ---------------------------------------------------------------------------
# ON: files present, SHA-stamped, full diff, superset metadata, paths exported
# ---------------------------------------------------------------------------
@test "prefetch ON: writes both files and exports their paths" {
  _install_gh_stub
  export PREFETCH_CONTEXT_ENABLED=true

  prefetch_pr_context "$PR_URL" "$SHA" "$FULL_DIFF_FILE" "$OUT_DIR"

  [ -f "$OUT_DIR/pr-context-diff.txt" ]
  [ -f "$OUT_DIR/pr-context-metadata.json" ]
  [ "$PR_CONTEXT_DIFF_FILE" = "$OUT_DIR/pr-context-diff.txt" ]
  [ "$PR_CONTEXT_METADATA_FILE" = "$OUT_DIR/pr-context-metadata.json" ]
}

@test "prefetch ON: diff is FULL (untruncated) and SHA-stamped" {
  _install_gh_stub
  export PREFETCH_CONTEXT_ENABLED=true

  prefetch_pr_context "$PR_URL" "$SHA" "$FULL_DIFF_FILE" "$OUT_DIR"

  # The full diff has 5000 lines — the persisted copy must not be truncated to
  # the 3000-line triage cap.
  run grep -c 'diff line' "$OUT_DIR/pr-context-diff.txt"
  [ "$status" -eq 0 ]
  [ "$output" -eq 5000 ]
  # First body line reappears; last line survives (proves no truncation).
  grep -q '^diff line 5000$' "$OUT_DIR/pr-context-diff.txt"
  # SHA stamp present in the header.
  grep -q "$SHA" "$OUT_DIR/pr-context-diff.txt"
}

@test "prefetch ON: metadata is SHA-stamped and a superset of tier fields" {
  _install_gh_stub
  export PREFETCH_CONTEXT_ENABLED=true

  prefetch_pr_context "$PR_URL" "$SHA" "$FULL_DIFF_FILE" "$OUT_DIR"

  # SHA stamp injected as a top-level field consumers (Story 5) can verify.
  run jq -r '.pr_head_sha' "$OUT_DIR/pr-context-metadata.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$SHA" ]

  # Superset: the head repository fields must be present so no tier loses them.
  run jq -e '.headRepository and .headRepositoryOwner' "$OUT_DIR/pr-context-metadata.json"
  [ "$status" -eq 0 ]

  # Full (non-simplified) files entries retain fields beyond triage's projection.
  run jq -e '.files[0].patch' "$OUT_DIR/pr-context-metadata.json"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Fetch volume: reuse the diff (no extra `gh pr diff`); exactly ONE `gh pr view`
# ---------------------------------------------------------------------------
@test "prefetch ON: reuses the diff (no gh pr diff) and does exactly one gh pr view" {
  _install_gh_stub
  export PREFETCH_CONTEXT_ENABLED=true

  prefetch_pr_context "$PR_URL" "$SHA" "$FULL_DIFF_FILE" "$OUT_DIR"

  run grep -c 'pr diff' "$GH_CALL_LOG"
  [ "$output" -eq 0 ]
  run grep -c 'pr view' "$GH_CALL_LOG"
  [ "$output" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Graceful degradation: gh rate-limit during the extra fetch => skip sentinel 100
# ---------------------------------------------------------------------------
@test "prefetch ON: gh rate-limit returns skip sentinel 100 without crashing" {
  _install_gh_rate_limited_stub
  export PREFETCH_CONTEXT_ENABLED=true

  run prefetch_pr_context "$PR_URL" "$SHA" "$FULL_DIFF_FILE" "$OUT_DIR"
  [ "$status" -eq 100 ]

  # No partial context files left behind on the skip path.
  [ ! -f "$OUT_DIR/pr-context-metadata.json" ]
  [ ! -f "$OUT_DIR/pr-context-diff.txt" ]
}

# ── The field lists against the real CLI ─────────────────────────────────────
# A stub accepts anything. The real `gh pr view` fails the whole call on one unknown
# field, which silently turned the prefetch into a no-op.

_real_gh_pr_fields() {
  # Bypass any stub on PATH: this test needs the installed CLI.
  local gh_bin
  gh_bin=$(type -aP gh | grep -v "^$STUB_DIR/" | head -n1)
  [ -n "$gh_bin" ] || return 1
  "$gh_bin" pr view --help | sed -n '/^JSON FIELDS/,/^$/p' | tail -n +2 | tr -d ' ' | tr ',' '\n' | grep -v '^$'
}

_assert_all_known() { # <label> <comma-separated fields> <known fields file>
  local f
  for f in $(tr ',' ' ' <<< "$2"); do
    grep -qxF "$f" "$3" || { echo "$1 asks gh pr view for unknown field '$f'" >&2; return 1; }
  done
}

@test "every field the prefetch requests is one real gh pr view accepts" {
  _real_gh_pr_fields > "$STUB_DIR/known" || skip "gh is not installed"
  [ -s "$STUB_DIR/known" ]
  _assert_all_known prefetch "$PR_CONTEXT_METADATA_FIELDS" "$STUB_DIR/known"
}

@test "every gh pr view --json list in the review prompts is one real gh accepts" {
  _real_gh_pr_fields > "$STUB_DIR/known" || skip "gh is not installed"
  [ -s "$STUB_DIR/known" ]
  local root="${BATS_TEST_DIRNAME}/.." file fields
  for file in "$root"/prompts/*.md; do
    while IFS= read -r fields; do
      _assert_all_known "$(basename "$file")" "$fields" "$STUB_DIR/known"
    done < <(sed -nE 's/.*gh pr view "\$PR_URL" --json ([a-zA-Z,]+).*/\1/p' "$file")
  done
}

@test "a failed metadata fetch says why" {
  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
echo 'Unknown JSON field: "nope"' >&2
exit 1
STUB
  chmod +x "$STUB_DIR/gh"
  export PREFETCH_CONTEXT_ENABLED=true
  run prefetch_pr_context "$PR_URL" "$SHA" "$FULL_DIFF_FILE" "$OUT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Unknown JSON field'* ]]
}
