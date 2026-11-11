#!/usr/bin/env bats
# Shadow-mode suppression at the posting handlers (#1713): hold-notice (comment +
# PATCH paths), fix-ci and fix-reviews. Each handler is run with a recording gh
# stub; write calls are logged to $GH_LOG. Shadow off → writes proceed (hold-notice);
# shadow on → no write call at all, even with DEV_LEAD_DRY_RUN=false.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
HOLD_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-hold-notice.sh"
FIX_CI_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-fix-ci.sh"
FIX_REVIEWS_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-fix-reviews.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

# setup — recording gh stub (logs only write calls) + isolated env.
setup() {
  export GITHUB_ENV="$BATS_TEST_TMPDIR/gh_env"; : > "$GITHUB_ENV"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/gh_out"; : > "$GITHUB_OUTPUT"
  export DEV_LEAD_SIDECAR_DIR="$BATS_TEST_TMPDIR"
  export GH_LOG="$BATS_TEST_TMPDIR/gh_writes.log"; : > "$GH_LOG"
  STUB_BIN_DIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUB_BIN_DIR"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  chmod +x "$STUB_BIN_DIR/claude"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"issue comment"*|*"pr comment"*|*"-X PATCH"*|*"pr review"*|*"pr edit"*|*"issue edit"*|*"pr merge"*)
    cat >/dev/null 2>&1 </dev/null || true
    echo "$ARGS" >> "$GH_LOG"; exit 0 ;;
  *"issues/comments/"*) printf '<!-- dev-lead-hold-notice label=old-label -->\nold' ;;
  *"issues/"*"/comments"*)
    echo '[{"id":7,"user":{"login":"bot"},"body":"<!-- dev-lead-hold-notice label=old-label -->\nold"}]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' ;;
  *"pr view"*"isCrossRepository"*) echo '{"isCrossRepository":false}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export PATH="$STUB_BIN_DIR:$PATH"
  export REPO="combsmith/.github-private" GITHUB_REPOSITORY="combsmith/.github-private"
  export SUBJECT_NUMBER="5" NOTICE_AUTHOR="bot" HOLD_LABEL="needs-human-review"
  export PR_NUMBER="42" HEAD_SHA="abc123def456" BASE_REF="main" REVIEW_ENGINE="claude"
  export CHECKS_JSON='[{"name":"lint","conclusion":"failure","details_url":"https://github.com/x/y/actions/runs/1","app_slug":"github-actions","id":9}]'
  unset DEV_LEAD_SHADOW_MODE
  export DEV_LEAD_DRY_RUN="false"
  cd "$SCRIPT_DIR" || return 1
}

# ── hold-notice: comment path ────────────────────────────────────────────────

@test "hold-notice: shadow off → notice comment IS posted" {
  export DEV_LEAD_SHADOW_MODE="false" MODE="notice"
  run bash "$HOLD_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "issue comment" "$GH_LOG"
}

@test "hold-notice: shadow on → notice comment suppressed" {
  export DEV_LEAD_SHADOW_MODE="true" MODE="notice"
  run bash "$HOLD_SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

# ── hold-notice: PATCH (supersede) path ──────────────────────────────────────

@test "hold-notice: shadow off → supersede PATCH IS issued" {
  export DEV_LEAD_SHADOW_MODE="false" MODE="supersede"
  run bash "$HOLD_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "PATCH" "$GH_LOG"
}

@test "hold-notice: shadow on → supersede PATCH suppressed" {
  export DEV_LEAD_SHADOW_MODE="true" MODE="supersede"
  run bash "$HOLD_SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "hold-notice: shadow undetermined → suppressed (fail-closed)" {
  export DEV_LEAD_SHADOW_MODE="maybe" MODE="notice"
  run bash "$HOLD_SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

# ── fix-ci / fix-reviews: shadow forces the dry-run "post nothing" path ───────

@test "fix-ci: shadow on + DRY_RUN=false → no write calls, no push" {
  export DEV_LEAD_SHADOW_MODE="true"
  run bash "$FIX_CI_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [ ! -s "$GH_LOG" ]
}

@test "fix-reviews: shadow on + DRY_RUN=false → no write calls, no push" {
  export DEV_LEAD_SHADOW_MODE="true"
  run bash "$FIX_REVIEWS_SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}
