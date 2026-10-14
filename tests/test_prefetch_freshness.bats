#!/usr/bin/env bats
# Unit tests for the HEAD-SHA freshness safeguard (epic #1101, Story 5 / #1106):
# assert_prefetch_context_fresh <pr_url> [out_dir].
#
# Just before the agentic tiers (deep / audit / single) consume the Story 2
# pre-fed context, this re-checks the PR's CURRENT head SHA against the SHA
# stamped on the pre-fed files, so a force-push / new push mid-run can never let
# a tier review stale code. It must:
#   - be a no-op returning 0 (and doing NO gh call) when PREFETCH_CONTEXT_ENABLED
#     is off (AC #4),
#   - when the current head SHA still MATCHES the stamp, return 0 and leave the
#     pre-fed context untouched (AC #2 — used as-is, no extra fetch beyond the
#     one bounded head-SHA call),
#   - when HEAD MOVED, invalidate the stale pre-fed context (remove the files,
#     unset the PR_CONTEXT_* exports) and return the skip sentinel 100 so the
#     caller retries at the new SHA (AC #3),
#   - bound the check to a SINGLE lightweight `gh pr view --json headRefOid`
#     (AC #4).
#
# `gh` is stubbed via a PATH shim that logs every invocation so we can assert
# fetch volume and returns a chosen head SHA from STUB_CURRENT_SHA.
#
# Run with: bats tests/test_prefetch_freshness.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/pr-context-prefetch.sh"

  STUB_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  export PATH="$STUB_DIR:$PATH"
  export GH_CALL_LOG="$STUB_DIR/gh_calls.log"
  : > "$GH_CALL_LOG"

  OUT_DIR="$STUB_DIR/cascade"
  mkdir -p "$OUT_DIR"

  PR_URL="https://github.com/petry-projects/example/pull/42"
  STAMPED_SHA="abc123def456"
}

teardown() {
  rm -rf "$STUB_DIR"
}

# Write pre-fed context files stamped with $STAMPED_SHA, mirroring the format
# prefetch_pr_context persists, and export their paths as the tiers would see.
_seed_prefed_context() {
  DIFF_FILE="$OUT_DIR/pr-context-diff.txt"
  META_FILE="$OUT_DIR/pr-context-metadata.json"
  printf '# PR_HEAD_SHA: %s\ndiff --git a/x b/x\n' "$STAMPED_SHA" > "$DIFF_FILE"
  printf '{"number":42,"pr_head_sha":"%s"}' "$STAMPED_SHA" > "$META_FILE"
  export PR_CONTEXT_DIFF_FILE="$DIFF_FILE"
  export PR_CONTEXT_METADATA_FILE="$META_FILE"
}

# gh stub: `pr view` prints {"headRefOid":"$STUB_CURRENT_SHA"} and logs the call.
_install_gh_head_stub() {
  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALL_LOG"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  printf '{"headRefOid":"%s"}' "$STUB_CURRENT_SHA"
  exit 0
fi
exit 0
STUB
  chmod +x "$STUB_DIR/gh"
}

# gh stub whose `pr view` fails (e.g. transient API error) on stderr.
_install_gh_failing_stub() {
  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALL_LOG"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo "could not resolve to a PullRequest" >&2
  exit 1
fi
exit 0
STUB
  chmod +x "$STUB_DIR/gh"
}

# ---------------------------------------------------------------------------
# Flag OFF: default-off => no gh call, return 0, pre-fed context untouched
# ---------------------------------------------------------------------------
@test "freshness OFF (unset): no-op, no gh call" {
  _install_gh_head_stub
  export STUB_CURRENT_SHA="ffffffffffff"  # would be a mismatch if it ran
  _seed_prefed_context
  unset PREFETCH_CONTEXT_ENABLED

  run assert_prefetch_context_fresh "$PR_URL" "$OUT_DIR"
  [ "$status" -eq 0 ]

  # No gh call when the feature is off.
  [ ! -s "$GH_CALL_LOG" ]
  # Pre-fed context left intact.
  [ -f "$DIFF_FILE" ]
  [ -f "$META_FILE" ]
}

@test "freshness OFF (explicit false): no-op, no gh call" {
  _install_gh_head_stub
  export STUB_CURRENT_SHA="ffffffffffff"
  _seed_prefed_context
  export PREFETCH_CONTEXT_ENABLED=false

  run assert_prefetch_context_fresh "$PR_URL" "$OUT_DIR"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_CALL_LOG" ]
}

# ---------------------------------------------------------------------------
# Matched SHA: return 0, exactly one gh pr view, pre-fed context untouched
# ---------------------------------------------------------------------------
@test "freshness ON matched: returns 0 and keeps the pre-fed context" {
  _install_gh_head_stub
  export STUB_CURRENT_SHA="$STAMPED_SHA"   # HEAD unchanged
  _seed_prefed_context
  export PREFETCH_CONTEXT_ENABLED=true

  run assert_prefetch_context_fresh "$PR_URL" "$OUT_DIR"
  [ "$status" -eq 0 ]

  # Files still present (used as-is).
  [ -f "$OUT_DIR/pr-context-diff.txt" ]
  [ -f "$OUT_DIR/pr-context-metadata.json" ]

  # Bounded to a single lightweight head-SHA call.
  run grep -c 'pr view' "$GH_CALL_LOG"
  [ "$output" -eq 1 ]
  # It requested only headRefOid (no full metadata/diff re-fetch).
  grep -q 'headRefOid' "$GH_CALL_LOG"
  run grep -c 'pr diff' "$GH_CALL_LOG"
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Moved SHA: invalidate stale context, unset exports, return 100
# ---------------------------------------------------------------------------
@test "freshness ON moved: invalidates stale context and returns 100" {
  _install_gh_head_stub
  export STUB_CURRENT_SHA="999999999999"   # force-push moved HEAD
  _seed_prefed_context
  export PREFETCH_CONTEXT_ENABLED=true

  # Run in the current shell (not `run`) so we can assert the exports were unset.
  set +e
  assert_prefetch_context_fresh "$PR_URL" "$OUT_DIR"
  rc=$?
  set -e
  [ "$rc" -eq 100 ]

  # Stale pre-fed files discarded so no tier can consume them.
  [ ! -f "$OUT_DIR/pr-context-diff.txt" ]
  [ ! -f "$OUT_DIR/pr-context-metadata.json" ]
  # Exports cleared.
  [ -z "${PR_CONTEXT_DIFF_FILE:-}" ]
  [ -z "${PR_CONTEXT_METADATA_FILE:-}" ]
}

# ---------------------------------------------------------------------------
# Nothing pre-fed: no stamp to validate => no-op (belt-and-suspenders)
# ---------------------------------------------------------------------------
@test "freshness ON but nothing pre-fed: no-op returns 0, no gh call" {
  _install_gh_head_stub
  export STUB_CURRENT_SHA="$STAMPED_SHA"
  export PREFETCH_CONTEXT_ENABLED=true
  unset PR_CONTEXT_DIFF_FILE PR_CONTEXT_METADATA_FILE

  run assert_prefetch_context_fresh "$PR_URL" "$OUT_DIR"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_CALL_LOG" ]
}

# ---------------------------------------------------------------------------
# gh failure: degrade to proceed (return 0) rather than crash the run
# ---------------------------------------------------------------------------
@test "freshness ON gh failure: degrades to 0 and keeps the pre-fed context" {
  _install_gh_failing_stub
  _seed_prefed_context
  export PREFETCH_CONTEXT_ENABLED=true

  run assert_prefetch_context_fresh "$PR_URL" "$OUT_DIR"
  [ "$status" -eq 0 ]

  # Context untouched — the safeguard must not discard on an inconclusive check.
  [ -f "$OUT_DIR/pr-context-diff.txt" ]
  [ -f "$OUT_DIR/pr-context-metadata.json" ]
}
