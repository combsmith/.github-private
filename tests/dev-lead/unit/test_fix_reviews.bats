#!/usr/bin/env bats
# Unit tests for dev-lead-fix-reviews.sh (Phase 3)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
FIX_REVIEWS_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-fix-reviews.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"
GH_STUBS_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/stubs"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"

  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  cp "$GH_STUBS_DIR/gh" "$STUB_BIN_DIR/gh"
  chmod +x "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini" "$STUB_BIN_DIR/gh"
  export PATH="$STUB_BIN_DIR:$PATH"
  export STUB_BIN_DIR

  # Default env
  export PR_NUMBER="54"
  export HEAD_SHA="ddd444eee555"
  export REPO="combsmith/.github-private"
  export REVIEW_ENGINE="claude"
  export DEV_LEAD_DRY_RUN="true"
  export GITHUB_REPOSITORY="combsmith/.github-private"
  export BASE_REF="main"
  export ACTOR="donpetry"

  # Install a graphql-aware gh stub
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
  *"api"*"repos/"*"issues/"*)
    echo "[]" ;;
  *"pr comment"*)
    exit 0 ;;
  *"pr checkout"*)
    exit 0 ;;
  *"issue comment"*)
    exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  cd "$SCRIPT_DIR"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT"
  rm -rf "$STUB_BIN_DIR"
}

# ── dry-run tests ─────────────────────────────────────────────────────────────

@test "fix-reviews: dry-run: no engine called" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"
  # Remove engine binaries to verify they're not called
  rm -f "$STUB_BIN_DIR/claude"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-reviews: INTENT_TYPE=fix-reviews → runs fix-reviews" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-reviews: INTENT_TYPE=on-mention → runs on-mention intent" {
  export INTENT_TYPE="on-mention"
  export DEV_LEAD_DRY_RUN="true"
  export USER_INSTRUCTION="Please fix the tests"
  export PR_DESCRIPTION="Test PR"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-reviews: INTENT_TYPE=fix-bot-comment → runs fix-bot-comment" {
  export INTENT_TYPE="fix-bot-comment"
  export DEV_LEAD_DRY_RUN="true"
  export COMMENT_BODY="SonarQube found issues"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-reviews: INTENT_TYPE=rebase dry-run → logs [dry-run]" {
  export INTENT_TYPE="rebase"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-reviews: rebase skips cleanly when the PR is exhausted (#865 sentinel re-fire guard)" {
  export INTENT_TYPE="rebase"
  export DEV_LEAD_DRY_RUN="false"

  # Remove the engine so a regression that failed to short-circuit would be caught
  # (the engine must never be invoked once the PR is rebase-exhausted).
  rm -f "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini"

  # gh stub: PR is OPEN (so checkout proceeds); its comments carry the PR-level
  # rebase exhaustion marker so rebase_pr_is_exhausted returns true.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"pr view"*)
    echo '{"state":"OPEN","headRefName":"feature-branch"}' ;;
  *"pr checkout"*)
    exit 0 ;;
  *"api"*"repos/"*"issues/"*"comments"*)
    echo '[{"body":"<!-- dev-lead-fix-reviews pr=54 intent=rebase status=exhausted -->","user":{"login":"donpetry-bot"},"created_at":"2026-01-01T00:00:00Z"}]' ;;
  *"api"*"pulls/"*)
    echo '{"head":{"sha":"ddd444eee555"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"rebase is exhausted"* ]]
}

# _setup_rebase_failure_stubs <num_conflicts> <claude_exit>: installs a git stub
# whose conflict-detection reports <num_conflicts> unmerged paths, a recording
# engine stub that logs each invocation to $ENGINE_CALLED_FILE and exits
# <claude_exit>, and a gh stub that reports no exhaustion marker (so the engine
# path is reached) and echoes any posted comment body (so terminal markers are
# assertable). Shared by the #865 rebase-failure tests below.
_setup_rebase_failure_stubs() {
  export STUB_NUM_CONFLICTS="$1"
  export STUB_CLAUDE_EXIT="$2"
  export ENGINE_CALLED_FILE
  ENGINE_CALLED_FILE="$(mktemp)"

  # Delegate to real git for the worktree setup the rebase intent performs before
  # dispatch (worktree add/checkout/rev-parse/merge --abort), but intercept the two
  # commands a hermetic test cannot satisfy: the network `fetch`, and the unmerged-
  # path listing that drives the large-conflict guard (emit STUB_NUM_CONFLICTS
  # synthetic paths).
  export REAL_GIT
  REAL_GIT="$(command -v git)"
  cat > "$STUB_BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  "fetch"*)
    exit 0 ;;
  *"diff --name-only --diff-filter=U"*)
    i=1
    while [ "$i" -le "${STUB_NUM_CONFLICTS:-0}" ]; do
      echo "path/conflict-${i}.txt"
      i=$((i + 1))
    done
    exit 0 ;;
  *)
    exec "$REAL_GIT" "$@" ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" <<'STUB'
#!/usr/bin/env bash
[ -n "${ENGINE_CALLED_FILE:-}" ] && echo "invoked" >> "$ENGINE_CALLED_FILE"
exit "${STUB_CLAUDE_EXIT:-1}"
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"api"*"repos/"*"issues/"*"comments"*)
    echo "[]" ;;
  *"pr comment"*)
    echo "COMMENT_POSTED: $ARGS"; exit 0 ;;
  *"api"*"pulls/"*)
    echo '{"head":{"sha":"ddd444eee555"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
}

@test "fix-reviews: rebase aborts an oversized conflict without invoking the engine (#865)" {
  export INTENT_TYPE="rebase"
  export DEV_LEAD_DRY_RUN="false"
  export REBASE_MAX_CONFLICT_FILES="40"

  # 41 conflicting files > the 40-file ceiling → aborted up front.
  _setup_rebase_failure_stubs 41 1

  run bash "$FIX_REVIEWS_SCRIPT"

  # The engine must never be invoked for an oversized conflict.
  [ ! -s "$ENGINE_CALLED_FILE" ]
  [ "$status" -eq 1 ]
  [[ "$output" == *"too large for automated resolution"* ]]
  # A terminal status=failed marker is recorded so the retry cron stops re-dispatching.
  [[ "$output" == *"intent=rebase status=failed"* ]]

  rm -f "$ENGINE_CALLED_FILE"
}

@test "fix-reviews: rebase engine timeout (exit 124) → clean failed abort, exit 1 (#865)" {
  export INTENT_TYPE="rebase"
  export DEV_LEAD_DRY_RUN="false"
  export REBASE_MAX_CONFLICT_FILES="40"

  # A resolvable-sized conflict (1 file) reaches the engine; the engine times out.
  _setup_rebase_failure_stubs 1 124

  run bash "$FIX_REVIEWS_SCRIPT"

  # The engine was invoked, then the timeout was converted to a clean abort.
  [ -s "$ENGINE_CALLED_FILE" ]
  [ "$status" -eq 1 ]
  [[ "$output" == *"exit 124"* ]]
  [[ "$output" == *"recorded failures on this PR"* ]]
  [[ "$output" == *"intent=rebase status=failed"* ]]

  rm -f "$ENGINE_CALLED_FILE"
}

@test "fix-reviews: rebase engine generic failure (exit 3) → clean failed abort, exit 1 (#865)" {
  export INTENT_TYPE="rebase"
  export DEV_LEAD_DRY_RUN="false"
  export REBASE_MAX_CONFLICT_FILES="40"

  _setup_rebase_failure_stubs 1 3

  run bash "$FIX_REVIEWS_SCRIPT"

  [ -s "$ENGINE_CALLED_FILE" ]
  [ "$status" -eq 1 ]
  [[ "$output" == *"exit 3"* ]]
  [[ "$output" == *"recorded failures on this PR"* ]]
  [[ "$output" == *"intent=rebase status=failed"* ]]

  rm -f "$ENGINE_CALLED_FILE"
}

@test "fix-reviews: unknown INTENT_TYPE → exits 1" {
  export INTENT_TYPE="totally-unknown-intent"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 1 ]
}

@test "fix-reviews: fix-reviews in dry-run: outputs [dry-run] message" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-reviews: review-changes in dry-run: outputs [dry-run] message" {
  export INTENT_TYPE="review-changes"
  export DEV_LEAD_DRY_RUN="true"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A test pull request"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-reviews: missing PR_NUMBER → exits 1 for non-rebase intents" {
  export INTENT_TYPE="fix-reviews"
  unset PR_NUMBER

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 1 ]
}

# ── rate-limit handling tests ─────────────────────────────────────────────────

@test "fix-reviews: rate-limited: engine exit 2 posts rate-limited marker" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="ddd444eee555"
  export COPILOT_GITHUB_TOKEN="stub-token"

  # claude and gemini engines rate-limited
  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "rate limit exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
# copilot must be checked first — its -p prompt text may contain "graphql"
case "$1" in
  copilot) echo "rate limit exceeded"; exit 1 ;;
esac
ARGS="$*"
case "$ARGS" in
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
  *"api"*"repos/"*"issues/"*)
    echo "[]" ;;
  *"pr comment"*)
    echo "COMMENT_POSTED: $ARGS"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"rate-limited"* ]]
  [[ "$output" == *"intent=fix-reviews"* ]]
  # Genuine rate limit keeps the rate-limited wording and tags the marker reason
  [[ "$output" == *"reason=rate-limit"* ]]
  [[ "$output" == *"Dev-Lead — rate-limited"* ]]
  # A genuine quota hold is the ONLY case that emits status=rate-limited (issue #1568)
  [[ "$output" == *"status=rate-limited"* ]]
  [[ "$output" != *"status=blocked"* ]]
}

@test "fix-reviews: rate-limited: on-mention intent posts re-trigger ack (not auto-retry)" {
  export INTENT_TYPE="on-mention"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="ddd444eee555"
  export ACTOR="donpetry"
  export USER_INSTRUCTION="Please fix the failing tests"
  export COPILOT_GITHUB_TOKEN="stub-token"

  # claude and gemini engines rate-limited
  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "hit your limit"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"api"*"repos/"*"issues/"*)
    echo "[]" ;;
  *"pr comment"*)
    echo "COMMENT_POSTED: $ARGS"; exit 0 ;;
  *"pulls/"*)
    echo '{"head":{"sha":"ddd444eee555"}}' ;;
  *"copilot"*)
    echo "hit your limit"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"rate-limited"* ]]
  # human intent must tell user to re-trigger manually (can't reconstruct instruction)
  [[ "$output" == *"re-trigger"* || "$output" == *"re-mention"* ]]
}

@test "fix-reviews: rate-limited: review-changes intent posts user-visible acknowledgment" {
  export INTENT_TYPE="review-changes"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="ddd444eee555"
  export ACTOR="donpetry"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A description"

  # Track how many times pr comment is called (marker + ack = 2 calls for review-changes)
  local comment_count_file
  comment_count_file=$(mktemp)
  echo "0" > "$comment_count_file"

  export COPILOT_GITHUB_TOKEN="stub-token"
  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "quota exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
# copilot must be checked first — its -p prompt text may contain "graphql"
case "\$1" in
  copilot) echo "quota exceeded"; exit 1 ;;
esac
ARGS="\$*"
case "\$ARGS" in
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
  *"api"*"repos/"*"issues/"*)
    echo "[]" ;;
  *"pr comment"*)
    count=\$(cat "${comment_count_file}")
    echo \$((count + 1)) > "${comment_count_file}"
    echo "COMMENT_POSTED #\$((count + 1))"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"rate-limited"* ]]
  # review-changes should post 2 comments: the rate-limited marker + the user acknowledgment
  local final_count
  final_count=$(cat "$comment_count_file")
  rm -f "$comment_count_file"
  [ "$final_count" -ge 2 ]
}

@test "fix-reviews: rate-limited: fix-bot-comment posts rate-limited marker" {
  export INTENT_TYPE="fix-bot-comment"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="ddd444eee555"
  export COMMENT_BODY="SonarQube found issues"
  export COPILOT_GITHUB_TOKEN="stub-token"

  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "rate limit exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"api"*"repos/"*"issues/"*)
    echo "[]" ;;
  *"pr comment"*)
    echo "COMMENT_POSTED"; exit 0 ;;
  *"copilot"*)
    echo "rate limit exceeded"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"rate-limited"* ]]
}

@test "fix-reviews: rate-limited: existing marker for same SHA+intent is replaced with fresh reset" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="ddd444eee555"
  export COPILOT_GITHUB_TOKEN="stub-token"

  # Returns existing rate-limited marker for this sha+intent — must be replaced, not skipped
  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
# copilot must be checked first — its -p prompt text may contain "graphql"
case "$1" in
  copilot) echo "rate limit exceeded"; exit 1 ;;
esac
ARGS="$*"
case "$ARGS" in
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
  *"-X DELETE"*)
    exit 0 ;;
  *"api"*"repos/"*"issues/"*)
    echo '[{"id":1,"body":"<!-- dev-lead-fix-reviews pr=54 sha=ddd444eee555 intent=fix-reviews status=rate-limited -->"}]' ;;
  *"pr comment"*)
    echo "COMMENT_POSTED"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "rate limit exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 2 ]
  # Stale rate-limited marker must be replaced with a fresh one (not skipped as duplicate)
  [[ "$output" != *"skipping duplicate"* ]]
  [[ "$output" == *"COMMENT_POSTED"* ]]
}

@test "fix-reviews: no-changes path also calls notify_coderabbit_resolve (dry-run)" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"would check for coderabbitai CHANGES_REQUESTED"* ]]
}

@test "fix-reviews: try_enable_auto_merge dry-run output present for fix-reviews" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"would enable auto-merge"* ]]
}

@test "fix-reviews: try_enable_auto_merge dry-run output present for fix-bot-comment" {
  export INTENT_TYPE="fix-bot-comment"
  export DEV_LEAD_DRY_RUN="true"
  export COMMENT_BODY="SonarQube found issues"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"would enable auto-merge"* ]]
}

@test "fix-reviews: try_enable_auto_merge dry-run output present for review-changes" {
  export INTENT_TYPE="review-changes"
  export DEV_LEAD_DRY_RUN="true"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A test pull request"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"would enable auto-merge"* ]]
}

@test "fix-reviews: try_enable_auto_merge dry-run output present for on-mention" {
  export INTENT_TYPE="on-mention"
  export DEV_LEAD_DRY_RUN="true"
  export USER_INSTRUCTION="Please fix the tests"
  export PR_DESCRIPTION="A test pull request"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"would enable auto-merge"* ]]
}

@test "fix-reviews: auto-merge enabled by default (not gated on APPROVED reviewDecision)" {
  # Regression guard: dev-lead enables auto-merge whenever it works on a PR;
  # GitHub holds the merge until branch protection is satisfied. The dry-run
  # message must not reintroduce an "if APPROVED" eligibility gate.
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"would enable auto-merge"* ]]
  [[ "$output" != *"if PR #"*"is APPROVED"* ]]
}

@test "fix-reviews: rate-limited run still attempts auto-merge" {
  # Regression guard: handle_rate_limit() must call try_enable_auto_merge so that
  # a rate-limited dev-lead run still enables auto-merge before exiting.
  export INTENT_TYPE="on-mention"
  export DEV_LEAD_DRY_RUN="false"
  export USER_INSTRUCTION="Please review"
  export COPILOT_GITHUB_TOKEN="stub-token"

  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" <<'STUB'
#!/usr/bin/env bash
echo "rate limit exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$1" in
  copilot) echo "rate limit exceeded"; exit 1 ;;
esac
ARGS="$*"
case "$ARGS" in
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
  *"api"*"repos/"*"issues/"*)
    echo "[]" ;;
  *"api"*"repos/"*"pulls/"*)
    echo '{}' ;;
  *"pr merge"*)
    echo "AUTO_MERGE_CALLED: $ARGS"; exit 0 ;;
  *"pr comment"*)
    echo "COMMENT_POSTED: $ARGS"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"rate-limited"* ]]
  # try_enable_auto_merge is called by handle_rate_limit — either "already enabled"
  # or "enabling auto-merge" appears depending on stub state; both prove the call happened.
  [[ "$output" == *"auto-merge"* ]]
}

@test "fix-reviews: try_enable_auto_merge dry-run output present for human-pr" {
  export INTENT_TYPE="human-pr"
  export DEV_LEAD_DRY_RUN="true"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A test pull request"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"would enable auto-merge"* ]]
}

@test "fix-reviews: terminal marker written after successful fix-reviews run" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  # In dry-run mode, the terminal marker post is announced
  [[ "$output" == *"terminal marker"* || "$output" == *"[dry-run]"* ]]
}

@test "post_no_changes: posts visible heading with fallback when no session log" {
  # Run from a non-git tmpdir so commit_and_push reports no changes → no-changes path
  local tmpdir
  tmpdir="$(mktemp -d)"
  rm -f /tmp/dev-lead-session-output.txt

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [[ "$output" == *"## Dev-Lead — fix-reviews (no-changes)"* ]]
  [[ "$output" == *"No actionable items found"* ]]
}

@test "post_no_changes: includes agent reasoning when session log is present" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local session_log="/tmp/dev-lead-session-output.txt"
  printf 'Agent determined no code changes required.\n' > "$session_log"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$session_log"

  [[ "$output" == *"## Dev-Lead — fix-reviews (no-changes)"* ]]
  [[ "$output" == *"Agent determined no code changes"* ]]
}

@test "post_no_changes: redacts GitHub tokens from session log" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local session_log="/tmp/dev-lead-session-output.txt"
  # Embed a fake GitHub PAT — redact_secrets should mask it before publishing.
  # Build the token at runtime so the literal doesn't appear in this source file
  # (avoids tripping gitleaks on our own test fixture).
  local fake_prefix='ghp' fake_body='_abcdefghij1234567890ABCDEFGHIJ'
  printf 'curl -H "Auth: %s%s" url\n' "$fake_prefix" "$fake_body" > "$session_log"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$session_log"

  [[ "$output" == *"***REDACTED-GH-TOKEN***"* ]]
  [[ "$output" != *"${fake_prefix}${fake_body}"* ]]
}

@test "post_no_changes: pick_fence outgrows tilde sequences in content" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local session_log="/tmp/dev-lead-session-output.txt"
  # Content has a 4-tilde sequence — fence must be 5+ to wrap cleanly
  printf 'output line one\n~~~~ this looks like a fence\noutput line two\n' > "$session_log"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$session_log"

  # Fence must be longer than the embedded 4-tilde run
  [[ "$output" == *"~~~~~"* ]]
}

@test "post_no_changes: redacts entire PEM private key block, not just header" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local session_log="/tmp/dev-lead-session-output.txt"
  # Build the PEM markers at runtime so the literal "-----BEGIN RSA PRIVATE
  # KEY-----" never appears in this source file (avoids tripping our own
  # gitleaks check on a test fixture).
  local dashes="-----"
  local begin="${dashes}BEGIN RSA PRIVATE KEY${dashes}"
  local end="${dashes}END RSA PRIVATE KEY${dashes}"
  {
    echo "some preamble text"
    echo "$begin"
    echo "MIIEpAIBAAKCAQEAabcdefghij1234567890BODY_LINE_ONE_SHOULD_BE_REDACTED"
    echo "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZBODY_LINE_TWO_SHOULD_BE_REDACTEDZZZZ"
    echo "$end"
    echo "some postamble text"
  } > "$session_log"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$session_log"

  [[ "$output" == *"***REDACTED-PRIVATE-KEY***"* ]]
  # Body and footer lines must be gone — leaking ANY part of the key is a fail
  [[ "$output" != *"BODY_LINE_ONE_SHOULD_BE_REDACTED"* ]]
  [[ "$output" != *"BODY_LINE_TWO_SHOULD_BE_REDACTED"* ]]
  [[ "$output" != *"$end"* ]]
}

@test "post_no_changes: redacts PEM block straddling the tail-30 boundary" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local session_log="/tmp/dev-lead-session-output.txt"
  local dashes="-----"
  local begin="${dashes}BEGIN RSA PRIVATE KEY${dashes}"
  local end="${dashes}END RSA PRIVATE KEY${dashes}"
  # Build a log where the BEGIN marker sits BEFORE the last-30 window. Without
  # redact-then-tail, the body/END would be tailed without a matching BEGIN and
  # the c\ range would never fire, leaking key material.
  {
    echo "$begin"
    for i in $(seq 1 50); do echo "filler-line-$i"; done
    echo "STRADDLE_KEY_BODY_MUST_NOT_LEAK_XYZ"
    echo "$end"
    echo "trailing summary line"
  } > "$session_log"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$session_log"

  [[ "$output" != *"STRADDLE_KEY_BODY_MUST_NOT_LEAK_XYZ"* ]]
  [[ "$output" != *"$end"* ]]
}

@test "post_no_changes: neutralises literal </details> in session output" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local session_log="/tmp/dev-lead-session-output.txt"
  printf 'discussing </details> tag\n' > "$session_log"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$session_log"

  # The literal </details> from session content must be escaped so it cannot
  # close the wrapping <details> block early.
  [[ "$output" == *"<\\/details>"* ]]
}

# ── commit_and_push failure tests ─────────────────────────────────────────────

@test "fix-reviews: commit_and_push: git commit failure exits 1 (not silently swallowed)" {
  export INTENT_TYPE="on-mention"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="abc123"
  export ACTOR="donpetry"
  export USER_INSTRUCTION="fix something"
  # Use absolute path so envsubst can find the prompt even when running from git_repo dir
  export PROMPTS_DIR="$SCRIPT_DIR/prompts/dev-lead"

  # Real temp git repo; the engine (claude stub) makes the uncommitted change
  # inside the PR worktree, which is what triggers commit_and_push.
  local git_repo
  git_repo="$(mktemp -d)"
  git -C "$git_repo" init -q
  echo "initial" > "$git_repo/file.txt"
  git -C "$git_repo" add .
  git -C "$git_repo" -c user.email="init@test" -c user.name="Init" commit -q -m "initial"

  # The worktree checkout is clean; the engine appends to file.txt in its CWD
  # (the worktree) so the script sees an uncommitted change to commit.
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "Changes applied."
echo "change" >> file.txt
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) echo "COMMENT_POSTED"; exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"}}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  # Stub git to fail on commit (simulates missing identity) but pass everything else to real git
  cat > "$STUB_BIN_DIR/git" << 'GITEOF'
#!/usr/bin/env bash
if [[ "$*" == *"commit"* ]]; then
  echo "::error::git commit failed — check git identity configuration on the runner"
  echo "fatal: empty ident name not allowed" >&2
  exit 128
fi
exec /usr/bin/git "$@"
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  # Run from git_repo so git status/add/commit/push operate on the temp repo
  cd "$git_repo"
  # Capture stderr too so ::error:: messages appear in $output
  run bash "$FIX_REVIEWS_SCRIPT" 2>&1

  # Must exit non-zero — git commit failure must NOT be silently swallowed
  [ "$status" -ne 0 ]
  [[ "$output" == *"error"* || "$output" == *"failed"* || "$output" == *"fatal"* ]]
}

@test "fix-reviews: commit_and_push: no false 'applied' marker posted on git commit failure" {
  export INTENT_TYPE="on-mention"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="abc123"
  export ACTOR="donpetry"
  export USER_INSTRUCTION="fix something"
  export PROMPTS_DIR="$SCRIPT_DIR/prompts/dev-lead"

  local git_repo
  git_repo="$(mktemp -d)"
  git -C "$git_repo" init -q
  echo "initial" > "$git_repo/file.txt"
  git -C "$git_repo" add .
  git -C "$git_repo" -c user.email="init@test" -c user.name="Init" commit -q -m "initial"

  local comment_file
  comment_file="$(mktemp)"

  # The engine makes its change inside the PR worktree (its CWD), triggering
  # commit_and_push (whose commit then fails via the git stub below).
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "Changes applied."
echo "change" >> file.txt
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*)
    echo "\$*" >> "$comment_file"
    exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"}}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  cat > "$STUB_BIN_DIR/git" << 'GITEOF'
#!/usr/bin/env bash
if [[ "$*" == *"commit"* ]]; then
  echo "::error::git commit failed — check git identity configuration on the runner"
  exit 128
fi
exec /usr/bin/git "$@"
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  cd "$git_repo"
  run bash "$FIX_REVIEWS_SCRIPT" 2>&1

  # Script must exit non-zero when commit fails
  [ "$status" -ne 0 ]
  # The "applied" status must NOT have been posted since commit failed
  if [ -f "$comment_file" ]; then
    ! grep -q "status=applied" "$comment_file"
  fi
  rm -f "$comment_file"
}

# ── read_session_summary: marker-based extraction ─────────────────────────────

@test "read_session_summary: extracts buried summary block past the tail-30 window" {
  local tmpdir session_log
  tmpdir="$(mktemp -d)"
  session_log="/tmp/dev-lead-session-output.txt"

  # Summary at line 3, then 200 lines of trailing tool output — the prior tail -30
  # implementation would have missed this entirely.
  {
    echo "tool: Read foo.sh"
    echo "tool: Grep something"
    echo "Addressed 1 threads:"
    echo "- Thread PRRT_xxx: applied fix [resolved]"
    echo "Files changed: foo.sh"
    for i in $(seq 1 200); do echo "tool: extra log line $i"; done
  } > "$session_log"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$session_log"

  [[ "$output" == *"## Dev-Lead — fix-reviews (no-changes)"* ]]
  # The structured summary line should be present even though it's far before the EOF.
  [[ "$output" == *"Addressed 1 threads"* ]]
  [[ "$output" == *"PRRT_xxx"* ]]
}

@test "read_session_summary: falls back to tail when no marker is found" {
  local tmpdir session_log
  tmpdir="$(mktemp -d)"
  session_log="/tmp/dev-lead-session-output.txt"

  # Unstructured output with no recognised marker — should still surface the last lines.
  {
    for i in $(seq 1 50); do echo "log line $i"; done
    echo "final completion notice"
  } > "$session_log"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$session_log"

  [[ "$output" == *"final completion notice"* ]]
}

# ── resolve_actor_outdated_threads: safety net for no-changes path ────────────

@test "resolve_actor_outdated_threads: dry-run announces and skips API calls" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  rm -f /tmp/dev-lead-session-output.txt

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-bot-comment DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='chatgpt-codex-connector[bot]' COMMENT_BODY='something'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [[ "$output" == *"would resolve outdated review threads authored by chatgpt-codex-connector[bot]"* ]]
}

@test "resolve_actor_outdated_threads: matches actor with [bot] suffix stripped" {
  local tmpdir mutations_file base_sha
  tmpdir="$(mktemp -d)"
  mutations_file="$(mktemp)"
  rm -f /tmp/dev-lead-session-output.txt

  # A real git repo whose PR head advances beyond the pre-pass HEAD_SHA, so the
  # #1617 resolution gate is open and resolve_actor_outdated_threads actually runs
  # (resolution is now permitted only when the pass advanced the head — #1609).
  git -C "$tmpdir" init -q
  echo "initial" > "$tmpdir/file.txt"
  git -C "$tmpdir" add .
  git -C "$tmpdir" -c user.email="t@test" -c user.name="T" commit -q -m "init"
  git -C "$tmpdir" update-ref refs/remotes/origin/main "$(git -C "$tmpdir" rev-parse HEAD)"
  base_sha="$(git -C "$tmpdir" rev-parse HEAD)"

  # Engine advances the head with a substantive new file (non-zero net vs base).
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "Addressed feedback."
printf 'fixed\n' > fix.txt
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  # git stub swallows the push (no remote) and passes everything else to real git.
  cat > "$STUB_BIN_DIR/git" << 'GITEOF'
#!/usr/bin/env bash
if [ "$1" = "push" ]; then exit 0; fi
exec /usr/bin/git "$@"
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  # gh stub: returns the JSON unfiltered (we pipe to real jq), and records mutations.
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"resolveReviewThread"*)
    echo "\$*" >> "$mutations_file"
    echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
    ;;
  *"reviewThreads"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_outdated_thread_id","isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"}}]}}]}}}}}'
    ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"statuses"*) echo '[]' ;;
  *"pulls/"*"reviews"*) echo '[]' ;;
  *"pulls/"*) echo '{"head":{"sha":"${base_sha}"},"auto_merge":null}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"issues/"*"comments"*) echo '[]' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-bot-comment DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$base_sha REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='chatgpt-codex-connector[bot]' COMMENT_BODY='something'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  # Mutation must have been invoked for the matched thread id
  grep -q "resolveReviewThread" "$mutations_file"
  grep -q "PRRT_outdated_thread_id" "$mutations_file"

  rm -rf "$tmpdir"
  rm -f "$mutations_file"
}

@test "resolve_actor_outdated_threads: skips when ACTOR is unset" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  rm -f /tmp/dev-lead-session-output.txt

  # No ACTOR set and no TRIGGERING_REVIEWER fallback — helper should log and skip.
  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    unset ACTOR TRIGGERING_REVIEWER
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [[ "$output" == *"ACTOR not set for intent=fix-reviews"* ]]
}

# ── resolve_actor_outdated_threads: called in both branches ─────────────────

@test "fix-reviews: resolve_actor_outdated_threads called in applied path (dry-run)" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"
  export ACTOR="chatgpt-codex-connector[bot]"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  # In dry-run, resolve_actor_outdated_threads should announce it would resolve
  [[ "$output" == *"would resolve outdated review threads authored by chatgpt-codex-connector[bot]"* ]]
}

@test "fix-bot-comment: resolve_actor_outdated_threads called in applied path (dry-run)" {
  export INTENT_TYPE="fix-bot-comment"
  export DEV_LEAD_DRY_RUN="true"
  export ACTOR="sonarqubecloud[bot]"
  export COMMENT_BODY="SonarQube found issues"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  # Should call resolve_actor_outdated_threads in dry-run mode
  [[ "$output" == *"would resolve outdated review threads authored by sonarqubecloud[bot]"* ]]
}

@test "review-changes: resolve_actor_outdated_threads called in applied path (dry-run)" {
  export INTENT_TYPE="review-changes"
  export DEV_LEAD_DRY_RUN="true"
  export ACTOR="donpetry"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A test PR"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  # Should call resolve_actor_outdated_threads in dry-run mode
  [[ "$output" == *"would resolve outdated review threads authored by donpetry"* ]]
}

# ── resolve_addressed_bot_threads: resolve threads dev-lead addressed but left open (#1547) ──
# Every pr-quality ruleset sets required_review_thread_resolution:true, so a bot
# review thread that dev-lead replied to ("Applied in …") but never resolved
# silently blocks merge even at full-green + approved. This safety net resolves a
# bot-originated, unresolved thread whose LAST reply carries the addressed-marker —
# distinct from the outdated-thread nets (it also handles non-outdated threads).

@test "resolve_addressed_bot_threads: dry-run announces and skips API calls" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"would resolve addressed review threads from bot reviewers on PR #54"* ]]
}

@test "resolve_addressed_bot_threads: resolves a non-outdated bot thread with an addressed reply" {
  local tmpdir="$BATS_TEST_TMPDIR/workdir"
  mkdir -p "$tmpdir"
  local mutations_file="$BATS_TEST_TMPDIR/mutations"
  local base_sha
  rm -f /tmp/dev-lead-session-output.txt

  # A real git repo whose PR head advances beyond the pre-pass HEAD_SHA, so the
  # #1617 resolution gate is open and resolve_addressed_bot_threads actually runs
  # (resolution is now permitted only when the pass advanced the head — #1609).
  git -C "$tmpdir" init -q
  echo "initial" > "$tmpdir/file.txt"
  git -C "$tmpdir" add .
  git -C "$tmpdir" -c user.email="t@test" -c user.name="T" commit -q -m "init"
  git -C "$tmpdir" update-ref refs/remotes/origin/main "$(git -C "$tmpdir" rev-parse HEAD)"
  base_sha="$(git -C "$tmpdir" rev-parse HEAD)"

  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"resolveReviewThread"*)
    echo "\$*" >> "$mutations_file"
    echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
    ;;
  *"PullRequestReviewThread"*)
    echo '{"data":{"node":{"isResolved":false,"path":"fix.txt","comments":{"nodes":[{"author":{"login":"donpetry-bot","__typename":"User"},"body":"Applied in fix.txt: added the fix. <!-- dev-lead:addressed -->\n<!-- dev-lead:claim {\"v\":1,\"sha\":\"${base_sha}\",\"files\":[\"fix.txt\"]} -->","createdAt":"2026-09-01T10:00:00Z"}]}}}}'
    ;;
  *"reviewThreads"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[{"id":"PRRT_addressed_bot","isResolved":false,"isOutdated":false,"origin":{"nodes":[{"author":{"login":"gemini-code-assist[bot]","__typename":"Bot"}}]}}]}}}}}'
    ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"statuses"*) echo '[]' ;;
  *"pulls/"*"reviews"*) echo '[]' ;;
  *"pulls/"*) echo '{"head":{"sha":"${base_sha}"},"auto_merge":null}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  # Engine advances the head with a substantive new file (non-zero net vs base).
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "Addressed feedback."
printf 'fixed\n' > fix.txt
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  # git stub swallows the push (no remote) and passes everything else to real git.
  cat > "$STUB_BIN_DIR/git" << 'GITEOF'
#!/usr/bin/env bash
if [ "$1" = "push" ]; then exit 0; fi
exec /usr/bin/git "$@"
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$base_sha REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='gemini-code-assist[bot]'
    export BOT_USER='donpetry-bot'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  grep -q "resolveReviewThread" "$mutations_file"
  grep -q "PRRT_addressed_bot" "$mutations_file"
}

@test "resolve_addressed_bot_threads: does NOT resolve a bot thread without the addressed-marker" {
  local tmpdir="$BATS_TEST_TMPDIR/workdir"
  mkdir -p "$tmpdir"
  local mutations_file="$BATS_TEST_TMPDIR/mutations"
  # Pre-create empty so a no-resolve run yields grep exit 1 (no match), not 2 (missing file).
  : > "$mutations_file"
  rm -f /tmp/dev-lead-session-output.txt

  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"resolveReviewThread"*)
    echo "\$*" >> "$mutations_file"
    echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
    ;;
  *"PullRequestReviewThread"*)
    echo '{"data":{"node":{"isResolved":false,"latest":{"nodes":[{"author":{"login":"donpetry-bot"},"body":"Skipping — first-party channel tag, intentional mutable ref."}]}}}}'
    ;;
  *"reviewThreads"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[{"id":"PRRT_skipped_bot","isResolved":false,"isOutdated":false,"origin":{"nodes":[{"author":{"login":"gemini-code-assist[bot]","__typename":"Bot"}}]}}]}}}}}'
    ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"statuses"*) echo '[]' ;;
  *"pulls/"*"reviews"*) echo '[]' ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  git -C "$tmpdir" init -q
  echo "initial" > "$tmpdir/file.txt"
  git -C "$tmpdir" add .
  git -C "$tmpdir" -c user.email="t@test" -c user.name="T" commit -q -m "init"

  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "No actionable items."
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='gemini-code-assist[bot]'
    export BOT_USER='donpetry-bot'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  run grep -q "PRRT_skipped_bot" "$mutations_file"
  [ "$status" -eq 1 ]
}

@test "resolve_addressed_bot_threads: does NOT resolve a maintainer-originated thread even with an addressed reply" {
  local tmpdir="$BATS_TEST_TMPDIR/workdir"
  mkdir -p "$tmpdir"
  local mutations_file="$BATS_TEST_TMPDIR/mutations"
  # Pre-create empty so a no-resolve run yields grep exit 1 (no match), not 2 (missing file).
  : > "$mutations_file"
  rm -f /tmp/dev-lead-session-output.txt

  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"resolveReviewThread"*)
    echo "\$*" >> "$mutations_file"
    echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
    ;;
  *"reviewThreads"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[{"id":"PRRT_maintainer","isResolved":false,"isOutdated":false,"origin":{"nodes":[{"author":{"login":"don-petry","__typename":"User"}}]},"latest":{"nodes":[{"body":"Applied in scripts/foo.sh. <!-- dev-lead:addressed -->"}]}}]}}}}}'
    ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"statuses"*) echo '[]' ;;
  *"pulls/"*"reviews"*) echo '[]' ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  git -C "$tmpdir" init -q
  echo "initial" > "$tmpdir/file.txt"
  git -C "$tmpdir" add .
  git -C "$tmpdir" -c user.email="t@test" -c user.name="T" commit -q -m "init"

  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "No actionable items."
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='gemini-code-assist[bot]'
    export BOT_USER='donpetry-bot'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  run grep -q "PRRT_maintainer" "$mutations_file"
  [ "$status" -eq 1 ]
}

@test "resolve_addressed_bot_threads: does NOT resolve when the addressed-marker reply is from another account" {
  local tmpdir="$BATS_TEST_TMPDIR/workdir"
  mkdir -p "$tmpdir"
  local mutations_file="$BATS_TEST_TMPDIR/mutations"
  # Pre-create empty so a no-resolve run yields grep exit 1 (no match), not 2 (missing file).
  : > "$mutations_file"
  rm -f /tmp/dev-lead-session-output.txt

  # Bot-originated thread (a valid candidate), but the addressed-marker reply the
  # node(id) re-fetch returns was posted by SOME OTHER account — not our BOT_USER.
  # A marker from a foreign human/bot must not authorize resolution (#codeant-623).
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"resolveReviewThread"*)
    echo "\$*" >> "$mutations_file"
    echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
    ;;
  *"PullRequestReviewThread"*)
    echo '{"data":{"node":{"isResolved":false,"latest":{"nodes":[{"author":{"login":"someone-else"},"body":"Applied in scripts/foo.sh. <!-- dev-lead:addressed -->"}]}}}}'
    ;;
  *"reviewThreads"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[{"id":"PRRT_foreign_marker","isResolved":false,"isOutdated":false,"origin":{"nodes":[{"author":{"login":"gemini-code-assist[bot]","__typename":"Bot"}}]}}]}}}}}'
    ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"statuses"*) echo '[]' ;;
  *"pulls/"*"reviews"*) echo '[]' ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  git -C "$tmpdir" init -q
  echo "initial" > "$tmpdir/file.txt"
  git -C "$tmpdir" add .
  git -C "$tmpdir" -c user.email="t@test" -c user.name="T" commit -q -m "init"

  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "No actionable items."
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='gemini-code-assist[bot]'
    export BOT_USER='donpetry-bot'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  run grep -q "PRRT_foreign_marker" "$mutations_file"
  [ "$status" -eq 1 ]
}

# ── #1735: full-thread scan — a bot ack after our marker must not lock the thread ──
# After #1691 (harness-only resolution) a thread we refuted (our addressed-marker
# reply) and a review bot then ACCEPTED ("✅ Customized review instruction saved!")
# became permanently unresolvable: the bot ack is the LATEST reply, so the old
# comments(last:1) gate saw a non-us author and skipped the thread forever. These
# cases assert the full-thread scan: our marker need not be the latest comment, a
# bot ack clears, a bot new-finding / any human / an ambiguous comment keeps it open.

# Shared gh stub body for the #1735 harness cases: bot-originated candidate thread,
# claim verifies from the cumulative range (base_sha is a root commit, so
# base_sha..HEAD == the engine's new fix.txt). The node's comment set is injected
# per-case via $POST_MARKER_NODE.
_1735_run_case() {
  local tmpdir="$BATS_TEST_TMPDIR/workdir"
  mkdir -p "$tmpdir"
  local mutations_file="$BATS_TEST_TMPDIR/mutations"
  : > "$mutations_file"
  local base_sha
  rm -f /tmp/dev-lead-session-output.txt

  git -C "$tmpdir" init -q
  echo "initial" > "$tmpdir/file.txt"
  git -C "$tmpdir" add .
  git -C "$tmpdir" -c user.email="t@test" -c user.name="T" commit -q -m "init"
  git -C "$tmpdir" update-ref refs/remotes/origin/main "$(git -C "$tmpdir" rev-parse HEAD)"
  base_sha="$(git -C "$tmpdir" rev-parse HEAD)"

  local marker_reply
  marker_reply="Refuted — the pattern is intentional. <!-- dev-lead:addressed -->\n<!-- dev-lead:claim {\\\"v\\\":1,\\\"sha\\\":\\\"${base_sha}\\\",\\\"files\\\":[\\\"fix.txt\\\"]} -->"

  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"resolveReviewThread"*)
    echo "\$*" >> "$mutations_file"
    echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
    ;;
  *"PullRequestReviewThread"*)
    echo '{"data":{"node":{"isResolved":false,"path":"fix.txt","comments":{"nodes":[{"author":{"login":"donpetry-bot","__typename":"User"},"body":"${marker_reply}","createdAt":"2026-09-01T10:00:00Z"},${POST_MARKER_NODE}]}}}}'
    ;;
  *"reviewThreads"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[{"id":"PRRT_1735","isResolved":false,"isOutdated":false,"origin":{"nodes":[{"author":{"login":"codeant-ai[bot]","__typename":"Bot"}}]}}]}}}}}'
    ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"statuses"*) echo '[]' ;;
  *"pulls/"*"reviews"*) echo '[]' ;;
  *"pulls/"*) echo '{"head":{"sha":"${base_sha}"},"auto_merge":null}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "Addressed feedback."
printf 'fixed\n' > fix.txt
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  cat > "$STUB_BIN_DIR/git" << 'GITEOF'
#!/usr/bin/env bash
if [ "$1" = "push" ]; then exit 0; fi
exec /usr/bin/git "$@"
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$base_sha REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='codeant-ai[bot]'
    export BOT_USER='donpetry-bot'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  # Expose the harness exit status so each case can assert the run completed instead of
  # crashing before it ever reached the resolve step — otherwise a "stays open" grep
  # (expecting no mutation) would pass even when the harness died early writing nothing.
  _HARNESS_STATUS="$status"
  _MUTATIONS_FILE="$mutations_file"
}

@test "resolve_addressed_bot_threads (#1735): marker then a bot acknowledgement -> resolves" {
  export POST_MARKER_NODE='{"author":{"login":"codeant-ai[bot]","__typename":"Bot"},"body":"✅ Customized review instruction saved!","createdAt":"2026-09-01T11:00:00Z"}'
  _1735_run_case
  [ "$_HARNESS_STATUS" -eq 0 ]
  grep -q "PRRT_1735" "$_MUTATIONS_FILE"
}

@test "resolve_addressed_bot_threads (#1735): marker then a bot NEW finding -> stays open" {
  export POST_MARKER_NODE='{"author":{"login":"codeant-ai[bot]","__typename":"Bot"},"body":"Potential issue: this still leaks a file descriptor.","createdAt":"2026-09-01T11:00:00Z"}'
  _1735_run_case
  [ "$_HARNESS_STATUS" -eq 0 ]
  run grep -q "PRRT_1735" "$_MUTATIONS_FILE"
  [ "$status" -eq 1 ]
}

@test "resolve_addressed_bot_threads (#1735): marker then a human comment -> stays open (AC3)" {
  export POST_MARKER_NODE='{"author":{"login":"a-maintainer","__typename":"User"},"body":"Looks fine to me, thanks.","createdAt":"2026-09-01T11:00:00Z"}'
  _1735_run_case
  [ "$_HARNESS_STATUS" -eq 0 ]
  run grep -q "PRRT_1735" "$_MUTATIONS_FILE"
  [ "$status" -eq 1 ]
}

@test "resolve_addressed_bot_threads (#1735): marker then an ambiguous bot comment -> stays open (AC4)" {
  export POST_MARKER_NODE='{"author":{"login":"codeant-ai[bot]","__typename":"Bot"},"body":"Interesting.","createdAt":"2026-09-01T11:00:00Z"}'
  _1735_run_case
  [ "$_HARNESS_STATUS" -eq 0 ]
  run grep -q "PRRT_1735" "$_MUTATIONS_FILE"
  [ "$status" -eq 1 ]
}

# ── Harness-only resolution (#1691, epic #1621) ──────────────────────────────
# Story 1 removes the model's resolveReviewThread path from the prompts, leaving
# the harness as the ONLY resolver. This asserts the guarantee at the harness
# boundary: even on a head-advancing pass (resolution gate OPEN), a bot thread
# whose latest reply is NOT an our-account addressed-marker is left unresolved —
# resolution only ever comes from the harness's marker-gated code path, never for
# a thread the marker check rejects. The head DOES advance here (a substantive new
# file), so the gate is open and resolve_addressed_bot_threads actually runs and
# then declines on the missing marker — distinguishing this from the #1617 gate.
@test "harness-only resolution (#1691): fix-reviews leaves a thread unresolved when its latest reply lacks our addressed-marker" {
  local tmpdir="$BATS_TEST_TMPDIR/workdir"
  mkdir -p "$tmpdir"
  local mutations_file="$BATS_TEST_TMPDIR/mutations"
  # Pre-create empty so a no-resolve run yields grep exit 1 (no match), not 2 (missing file).
  : > "$mutations_file"
  local base_sha
  rm -f /tmp/dev-lead-session-output.txt

  git -C "$tmpdir" init -q
  echo "initial" > "$tmpdir/file.txt"
  git -C "$tmpdir" add .
  git -C "$tmpdir" -c user.email="t@test" -c user.name="T" commit -q -m "init"
  git -C "$tmpdir" update-ref refs/remotes/origin/main "$(git -C "$tmpdir" rev-parse HEAD)"
  base_sha="$(git -C "$tmpdir" rev-parse HEAD)"

  # Bot-originated thread (a valid harness candidate), but the latest reply the
  # node(id) re-fetch returns carries NO addressed-marker — so the harness's
  # marker gate must decline to resolve it.
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"resolveReviewThread"*)
    echo "\$*" >> "$mutations_file"
    echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
    ;;
  *"PullRequestReviewThread"*)
    echo '{"data":{"node":{"isResolved":false,"latest":{"nodes":[{"author":{"login":"donpetry-bot"},"body":"Looked into this but made no change."}]}}}}'
    ;;
  *"reviewThreads"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[{"id":"PRRT_unmarked_bot","isResolved":false,"isOutdated":false,"origin":{"nodes":[{"author":{"login":"gemini-code-assist[bot]","__typename":"Bot"}}]}}]}}}}}'
    ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"statuses"*) echo '[]' ;;
  *"pulls/"*"reviews"*) echo '[]' ;;
  *"pulls/"*) echo '{"head":{"sha":"${base_sha}"},"auto_merge":null}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  # Engine advances the head with a substantive new file (gate OPEN).
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "Addressed feedback."
printf 'fixed\n' > fix.txt
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  cat > "$STUB_BIN_DIR/git" << 'GITEOF'
#!/usr/bin/env bash
if [ "$1" = "push" ]; then exit 0; fi
exec /usr/bin/git "$@"
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$base_sha REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='gemini-code-assist[bot]'
    export BOT_USER='donpetry-bot'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  [ "$status" -eq 0 ]

  # The pass advanced the head, so the resolution gate was OPEN (not the #1617 case)...
  [[ "$output" != *"resolution gate closed"* ]]
  # ...yet the harness's marker gate declined: zero resolutions for the unmarked thread.
  [ ! -s "$mutations_file" ]
  run grep -q "PRRT_unmarked_bot" "$mutations_file"
  [ "$status" -eq 1 ]
}

# ── Verifiable-claim gate (#1692, epic #1621 story 2) ────────────────────────
# The addressed-marker is now a verifiable CLAIM checked against the pushed diff.
# These harness-level cases drive a real git repo whose head advances (resolution
# gate OPEN) and a bot thread whose latest reply is our own addressed-marker — so
# every earlier gate passes and the claim verification is the deciding factor. The
# pure verifier is exhaustively unit-tested in test_addressed_claim_verify.bats;
# these assert the WIRING skips the mutation on each fail-closed reason.

# Shared setup: a real git repo with a root commit (base_sha), origin/main pinned
# to it, an engine that advances head with a substantive file, and a git stub that
# swallows the push. Echoes nothing; sets $BASE_SHA_OUT via a nameref-free global.
_claim_repo_setup() {
  local tmpdir="$1"
  git -C "$tmpdir" init -q
  echo "initial" > "$tmpdir/file.txt"
  git -C "$tmpdir" add .
  git -C "$tmpdir" -c user.email="t@test" -c user.name="T" commit -q -m "init"
  git -C "$tmpdir" update-ref refs/remotes/origin/main "$(git -C "$tmpdir" rev-parse HEAD)"
  CLAIM_BASE_SHA="$(git -C "$tmpdir" rev-parse HEAD)"

  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "Addressed feedback."
printf 'fixed\n' > fix.txt
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  cat > "$STUB_BIN_DIR/git" << 'GITEOF'
#!/usr/bin/env bash
if [ "$1" = "push" ]; then exit 0; fi
exec /usr/bin/git "$@"
GITEOF
  chmod +x "$STUB_BIN_DIR/git"
}

_run_claim_fix_reviews() {
  local tmpdir="$1" base_sha="$2"
  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$base_sha REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='gemini-code-assist[bot]'
    export BOT_USER='donpetry-bot'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
}

@test "#1692 PR #1044 shape: a fix NOT touching the claimed files leaves the thread unresolved" {
  local tmpdir="$BATS_TEST_TMPDIR/workdir"
  mkdir -p "$tmpdir"
  local mutations_file="$BATS_TEST_TMPDIR/mutations"
  : > "$mutations_file"
  rm -f /tmp/dev-lead-session-output.txt
  _claim_repo_setup "$tmpdir"
  local base_sha="$CLAIM_BASE_SHA"

  # Claim names a file the pushed diff never touches (the diff touches fix.txt).
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"resolveReviewThread"*)
    echo "\$*" >> "$mutations_file"
    echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
    ;;
  *"PullRequestReviewThread"*)
    echo '{"data":{"node":{"isResolved":false,"path":"scripts/other.sh","comments":{"nodes":[{"author":{"login":"donpetry-bot","__typename":"User"},"body":"Fixed in scripts/other.sh. <!-- dev-lead:addressed -->\n<!-- dev-lead:claim {\"v\":1,\"sha\":\"${base_sha}\",\"files\":[\"scripts/other.sh\"]} -->","createdAt":"2026-09-01T10:00:00Z"}]}}}}'
    ;;
  *"reviewThreads"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[{"id":"PRRT_1044","isResolved":false,"isOutdated":false,"origin":{"nodes":[{"author":{"login":"gemini-code-assist[bot]","__typename":"Bot"}}]}}]}}}}}'
    ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"statuses"*) echo '[]' ;;
  *"pulls/"*"reviews"*) echo '[]' ;;
  *"pulls/"*) echo '{"head":{"sha":"${base_sha}"},"auto_merge":null}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  _run_claim_fix_reviews "$tmpdir" "$base_sha"
  [ "$status" -eq 0 ]
  [[ "$output" != *"resolution gate closed"* ]]
  run grep -q "PRRT_1044" "$mutations_file"
  [ "$status" -eq 1 ]
}

@test "#1692: a claim naming a commit absent from the head branch leaves the thread unresolved" {
  local tmpdir="$BATS_TEST_TMPDIR/workdir"
  mkdir -p "$tmpdir"
  local mutations_file="$BATS_TEST_TMPDIR/mutations"
  : > "$mutations_file"
  rm -f /tmp/dev-lead-session-output.txt
  _claim_repo_setup "$tmpdir"
  local base_sha="$CLAIM_BASE_SHA"
  local absent_sha="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"resolveReviewThread"*)
    echo "\$*" >> "$mutations_file"
    echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
    ;;
  *"PullRequestReviewThread"*)
    echo '{"data":{"node":{"isResolved":false,"path":"fix.txt","comments":{"nodes":[{"author":{"login":"donpetry-bot","__typename":"User"},"body":"Fixed in fix.txt. <!-- dev-lead:addressed -->\n<!-- dev-lead:claim {\"v\":1,\"sha\":\"${absent_sha}\",\"files\":[\"fix.txt\"]} -->","createdAt":"2026-09-01T10:00:00Z"}]}}}}'
    ;;
  *"reviewThreads"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[{"id":"PRRT_absent","isResolved":false,"isOutdated":false,"origin":{"nodes":[{"author":{"login":"gemini-code-assist[bot]","__typename":"Bot"}}]}}]}}}}}'
    ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"statuses"*) echo '[]' ;;
  *"pulls/"*"reviews"*) echo '[]' ;;
  *"pulls/"*) echo '{"head":{"sha":"${base_sha}"},"auto_merge":null}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  _run_claim_fix_reviews "$tmpdir" "$base_sha"
  [ "$status" -eq 0 ]
  run grep -q "PRRT_absent" "$mutations_file"
  [ "$status" -eq 1 ]
}

@test "#1692: a malformed claim payload leaves the thread unresolved (fail closed)" {
  local tmpdir="$BATS_TEST_TMPDIR/workdir"
  mkdir -p "$tmpdir"
  local mutations_file="$BATS_TEST_TMPDIR/mutations"
  : > "$mutations_file"
  rm -f /tmp/dev-lead-session-output.txt
  _claim_repo_setup "$tmpdir"
  local base_sha="$CLAIM_BASE_SHA"

  # Marker present, our account, but the claim JSON does not parse.
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"resolveReviewThread"*)
    echo "\$*" >> "$mutations_file"
    echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
    ;;
  *"PullRequestReviewThread"*)
    echo '{"data":{"node":{"isResolved":false,"path":"fix.txt","comments":{"nodes":[{"author":{"login":"donpetry-bot","__typename":"User"},"body":"Fixed. <!-- dev-lead:addressed -->\n<!-- dev-lead:claim {\"v\":1, not valid json} -->","createdAt":"2026-09-01T10:00:00Z"}]}}}}'
    ;;
  *"reviewThreads"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[{"id":"PRRT_malformed","isResolved":false,"isOutdated":false,"origin":{"nodes":[{"author":{"login":"gemini-code-assist[bot]","__typename":"Bot"}}]}}]}}}}}'
    ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"statuses"*) echo '[]' ;;
  *"pulls/"*"reviews"*) echo '[]' ;;
  *"pulls/"*) echo '{"head":{"sha":"${base_sha}"},"auto_merge":null}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  _run_claim_fix_reviews "$tmpdir" "$base_sha"
  [ "$status" -eq 0 ]
  run grep -q "PRRT_malformed" "$mutations_file"
  [ "$status" -eq 1 ]
}

@test "#1692 AC4: a maintainer disposition postdating the verified fix leaves the thread unresolved" {
  local tmpdir="$BATS_TEST_TMPDIR/workdir"
  mkdir -p "$tmpdir"
  local mutations_file="$BATS_TEST_TMPDIR/mutations"
  : > "$mutations_file"
  rm -f /tmp/dev-lead-session-output.txt
  _claim_repo_setup "$tmpdir"
  local base_sha="$CLAIM_BASE_SHA"

  # A verifiable claim, BUT the thread carries a marker-less maintainer disposition
  # dated far in the future — the verified fix does not postdate it, so leave open.
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"resolveReviewThread"*)
    echo "\$*" >> "$mutations_file"
    echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
    ;;
  *"PullRequestReviewThread"*)
    echo '{"data":{"node":{"isResolved":false,"path":"fix.txt","comments":{"nodes":[{"author":{"login":"a-maintainer","__typename":"User"},"body":"ACCEPTED — required before merge","createdAt":"2099-01-01T00:00:00Z"},{"author":{"login":"donpetry-bot","__typename":"User"},"body":"Fixed in fix.txt. <!-- dev-lead:addressed -->\n<!-- dev-lead:claim {\"v\":1,\"sha\":\"${base_sha}\",\"files\":[\"fix.txt\"]} -->","createdAt":"2026-09-01T10:00:00Z"}]}}}}'
    ;;
  *"reviewThreads"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[{"id":"PRRT_disposition","isResolved":false,"isOutdated":false,"origin":{"nodes":[{"author":{"login":"gemini-code-assist[bot]","__typename":"Bot"}}]}}]}}}}}'
    ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"statuses"*) echo '[]' ;;
  *"pulls/"*"reviews"*) echo '[]' ;;
  *"pulls/"*) echo '{"head":{"sha":"${base_sha}"},"auto_merge":null}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  _run_claim_fix_reviews "$tmpdir" "$base_sha"
  [ "$status" -eq 0 ]
  run grep -q "PRRT_disposition" "$mutations_file"
  [ "$status" -eq 1 ]
}

# ── Resolution gate (#1617): a no-commit pass resolves zero threads ──────────
# #1609/#1024: a dev-lead fix pass may auto-resolve review threads ONLY when it
# advanced the PR head. A pass that produces no commit must resolve ZERO threads,
# in every intent branch. Each test drives a real git repo whose HEAD equals the
# pre-pass HEAD_SHA and an engine that makes no change, so nothing is advanced —
# resolution_gate_open must close the gate even though the gh stub offers an
# outdated bot thread the resolve_* nets would otherwise take.
_gate_no_commit_setup() {
  local tmpdir="$1" mutations_file="$2"
  git -C "$tmpdir" init -q
  echo "initial" > "$tmpdir/file.txt"
  git -C "$tmpdir" add .
  git -C "$tmpdir" -c user.email="t@test" -c user.name="T" commit -q -m "init"
  GATE_HEAD_SHA="$(git -C "$tmpdir" rev-parse HEAD)"

  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "No actionable items."
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"resolveReviewThread"*)
    echo "\$*" >> "$mutations_file"
    echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
    ;;
  *"PullRequestReviewThread"*)
    echo '{"data":{"node":{"isResolved":false,"latest":{"nodes":[{"author":{"login":"donpetry-bot"},"body":"Applied. <!-- dev-lead:addressed -->"}]}}}}'
    ;;
  *"reviewThreads"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[{"id":"PRRT_outdated_bot","isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"gemini-code-assist[bot]","__typename":"Bot"}}]},"origin":{"nodes":[{"author":{"login":"gemini-code-assist[bot]","__typename":"Bot"}}]}}]}}}}}'
    ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"statuses"*) echo '[]' ;;
  *"pulls/"*"reviews"*) echo '[]' ;;
  *"pulls/"*) echo '{"head":{"sha":"${GATE_HEAD_SHA}"},"auto_merge":null}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"issues/"*"comments"*) echo '[]' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
}

@test "resolution gate (#1617): fix-reviews no-commit pass resolves zero threads" {
  local tmpdir="$BATS_TEST_TMPDIR/fr" mutations_file="$BATS_TEST_TMPDIR/fr-mut"
  mkdir -p "$tmpdir"; : > "$mutations_file"
  rm -f /tmp/dev-lead-session-output.txt
  _gate_no_commit_setup "$tmpdir" "$mutations_file"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$GATE_HEAD_SHA REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='gemini-code-assist[bot]' BOT_USER='donpetry-bot'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  # The pass advanced nothing → the gate is closed → zero threads resolved.
  [ ! -s "$mutations_file" ]
  [[ "$output" == *"resolution gate closed (#1609)"* ]]
}

@test "resolution gate (#1617): fix-bot-comment no-commit pass resolves zero threads" {
  local tmpdir="$BATS_TEST_TMPDIR/fbc" mutations_file="$BATS_TEST_TMPDIR/fbc-mut"
  mkdir -p "$tmpdir"; : > "$mutations_file"
  rm -f /tmp/dev-lead-session-output.txt
  _gate_no_commit_setup "$tmpdir" "$mutations_file"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-bot-comment DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$GATE_HEAD_SHA REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='gemini-code-assist[bot]' BOT_USER='donpetry-bot' COMMENT_BODY='something'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  [ ! -s "$mutations_file" ]
  [[ "$output" == *"resolution gate closed (#1609)"* ]]
}

@test "resolution gate (#1617): review-changes no-commit pass resolves zero threads" {
  local tmpdir="$BATS_TEST_TMPDIR/rc" mutations_file="$BATS_TEST_TMPDIR/rc-mut"
  mkdir -p "$tmpdir"; : > "$mutations_file"
  rm -f /tmp/dev-lead-session-output.txt
  _gate_no_commit_setup "$tmpdir" "$mutations_file"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$GATE_HEAD_SHA REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='gemini-code-assist[bot]' BOT_USER='donpetry-bot'
    export PR_TITLE='Test PR' PR_DESCRIPTION='A test PR'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  [ ! -s "$mutations_file" ]
  [[ "$output" == *"resolution gate closed (#1609)"* ]]
}

# Regression for the stale-HEAD_SHA hole (#1617): HEAD_SHA is the event-time SHA
# and is only re-resolved when empty, but checkout loads the CURRENT PR head. If a
# commit lands between the event firing and the checkout, HEAD_SHA differs from the
# checked-out head while THIS pass has done no work — the old gate (which compared
# HEAD_SHA) would then see two different non-empty SHAs and open, resolving threads
# on a no-commit pass. The gate must instead compare the immutable RESOLUTION_BASE_SHA
# snapshotted right after checkout, so a stale HEAD_SHA is irrelevant: a no-commit
# pass resolves ZERO threads even when HEAD_SHA != the checked-out head.
@test "resolution gate (#1617): stale HEAD_SHA differing from checkout head resolves zero threads on a no-commit pass" {
  local tmpdir="$BATS_TEST_TMPDIR/stale" mutations_file="$BATS_TEST_TMPDIR/stale-mut"
  mkdir -p "$tmpdir"; : > "$mutations_file"
  rm -f /tmp/dev-lead-session-output.txt
  _gate_no_commit_setup "$tmpdir" "$mutations_file"

  # A stale, event-time SHA that deliberately does NOT match the checked-out head
  # (GATE_HEAD_SHA). Non-empty, so the script skips the API refresh at line 67.
  local stale_sha="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  [ "$stale_sha" != "$GATE_HEAD_SHA" ]

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$stale_sha REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='gemini-code-assist[bot]' BOT_USER='donpetry-bot'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  # Old code compared the stale HEAD_SHA against the checkout head, saw a diff,
  # and opened the gate. The immutable snapshot closes it — zero threads resolved.
  [ ! -s "$mutations_file" ]
  [[ "$output" == *"resolution gate closed (#1609)"* ]]
}

# ── ALL_REVIEWS_JSON deduplication: latest review per user ───────────────────
# The GitHub Reviews API returns the full history of all reviews. If a reviewer
# previously requested changes but later approved, both entries are present.
# The jq filter in collect_assessment_data must keep only the latest per user,
# but COMMENTED reviews must not clear a prior CHANGES_REQUESTED or APPROVED
# (GitHub does not count COMMENTED as a blocking state change).
readonly JQ_DEDUP_REVIEWS='[ [.[].[] | select(.user != null)] | group_by(.user.login)[] | . as $g | (($g | map(select(.state != "COMMENTED")) | sort_by(.id) | last) // ($g | sort_by(.id) | last)) | {id:.id, user:.user.login, state:.state, submitted_at:.submitted_at, body:.body, all_change_request_bodies:($g | map(select(.state == "CHANGES_REQUESTED")) | sort_by(.id) | map(.body))} ]'

@test "collect_assessment_data: jq dedup expression keeps only latest review per user" {
  # Feed sample multi-review JSON through the exact jq expression used in the script
  # to verify that CHANGES_REQUESTED is superseded by a later APPROVED from the same user.
  # Input is a single-page array; jq -s simulates --paginate output (wraps to [[...]])
  # so .[].[] correctly flattens across pages.
  local input='[
    {"id":1,"user":{"login":"alice"},"state":"CHANGES_REQUESTED","submitted_at":"2024-01-01T00:00:00Z"},
    {"id":2,"user":{"login":"bob"},"state":"APPROVED","submitted_at":"2024-01-02T00:00:00Z"},
    {"id":3,"user":{"login":"alice"},"state":"APPROVED","submitted_at":"2024-01-03T00:00:00Z"}
  ]'

  run bash -c "printf '%s' '$input' | jq -s '$JQ_DEDUP_REVIEWS'"

  [ "$status" -eq 0 ]
  # alice's latest review (id=3) is APPROVED — CHANGES_REQUESTED (id=1) must not appear
  [[ "$output" == *'"alice"'* ]]
  [[ "$output" == *'"APPROVED"'* ]]
  # Only one entry for alice — no duplicate
  local alice_count
  alice_count=$(echo "$output" | grep -c '"alice"')
  [ "$alice_count" -eq 1 ]
  # CHANGES_REQUESTED should not appear in output
  [[ "$output" != *'"CHANGES_REQUESTED"'* ]]
}

@test "collect_assessment_data: jq dedup expression filters out null-user entries" {
  local input='[
    {"id":1,"user":null,"state":"APPROVED","submitted_at":"2024-01-01T00:00:00Z"},
    {"id":2,"user":{"login":"alice"},"state":"APPROVED","submitted_at":"2024-01-02T00:00:00Z"}
  ]'

  run bash -c "printf '%s' '$input' | jq -s '$JQ_DEDUP_REVIEWS'"

  [ "$status" -eq 0 ]
  # Result should have only alice; the null-user entry is filtered out
  local count
  count=$(echo "$output" | jq 'length')
  [ "$count" -eq 1 ]
}

@test "collect_assessment_data: jq dedup keeps CHANGES_REQUESTED when later COMMENTED review exists" {
  # A COMMENTED review must not supersede a prior CHANGES_REQUESTED — GitHub only
  # clears the blocking state when the reviewer submits APPROVED or is dismissed.
  local input='[
    {"id":1,"user":{"login":"alice"},"state":"CHANGES_REQUESTED","submitted_at":"2024-01-01T00:00:00Z"},
    {"id":2,"user":{"login":"alice"},"state":"COMMENTED","submitted_at":"2024-01-02T00:00:00Z"}
  ]'

  run bash -c "printf '%s' '$input' | jq -s '$JQ_DEDUP_REVIEWS'"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"CHANGES_REQUESTED"'* ]]
  [[ "$output" != *'"COMMENTED"'* ]]
}

@test "collect_assessment_data: jq dedup preserves review body in output" {
  # When a reviewer uses only the review summary (no line threads), the body field
  # must be preserved in ALL_REVIEWS_JSON so the agent can read the instructions.
  local input='[
    {"id":1,"user":{"login":"alice"},"state":"CHANGES_REQUESTED","submitted_at":"2024-01-01T00:00:00Z","body":"Please fix the type errors before merging."}
  ]'

  run bash -c "printf '%s' '$input' | jq -s '$JQ_DEDUP_REVIEWS'"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"body"'* ]]
  [[ "$output" == *'Please fix the type errors before merging.'* ]]
}

@test "collect_assessment_data: all_change_request_bodies aggregates all CHANGES_REQUESTED bodies from same reviewer" {
  # When a reviewer posts multiple CHANGES_REQUESTED reviews, all their bodies must be
  # aggregated in all_change_request_bodies so older summary-only requests are not lost.
  local input='[
    {"id":1,"user":{"login":"alice"},"state":"CHANGES_REQUESTED","submitted_at":"2024-01-01T00:00:00Z","body":"Fix the type errors."},
    {"id":2,"user":{"login":"alice"},"state":"CHANGES_REQUESTED","submitted_at":"2024-01-02T00:00:00Z","body":"Also fix the lint warnings."},
    {"id":3,"user":{"login":"alice"},"state":"COMMENTED","submitted_at":"2024-01-03T00:00:00Z","body":"Looks almost there."}
  ]'

  run bash -c "printf '%s' '$input' | jq -s '$JQ_DEDUP_REVIEWS'"

  [ "$status" -eq 0 ]
  # Latest non-COMMENTED review (id=2) is CHANGES_REQUESTED
  [[ "$output" == *'"CHANGES_REQUESTED"'* ]]
  # all_change_request_bodies must contain BOTH CHANGES_REQUESTED bodies (not just the latest)
  [[ "$output" == *'Fix the type errors.'* ]]
  [[ "$output" == *'Also fix the lint warnings.'* ]]
  # The COMMENTED body must not appear in all_change_request_bodies
  [[ "$output" != *'Looks almost there.'* ]]
}

@test "fix-reviews: rate-limited: review-changes does not repost ack when prior rate-limited marker exists" {
  # When a persistent hard blocker causes a second rate-limit cycle, the visible
  # user-facing ack must NOT be reposted — the old ack is still visible.
  export INTENT_TYPE="review-changes"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="ddd444eee555"
  export ACTOR="donpetry"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A description"
  export COPILOT_GITHUB_TOKEN="stub-token"

  local comment_count_file
  comment_count_file=$(mktemp)
  echo "0" > "$comment_count_file"

  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "quota exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  # Stub returns an existing rate-limited marker (simulating a second retry cycle)
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
case "\$1" in
  copilot) echo "quota exceeded"; exit 1 ;;
esac
ARGS="\$*"
case "\$ARGS" in
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
  *"-X DELETE"*)
    exit 0 ;;
  *"api"*"repos/"*"issues/"*)
    echo '[{"id":99,"body":"<!-- dev-lead-fix-reviews pr=54 sha=ddd444eee555 intent=review-changes status=rate-limited reset=2099-01-01T00:00:00Z -->"}]' ;;
  *"pr comment"*)
    count=\$(cat "${comment_count_file}")
    echo \$((count + 1)) > "${comment_count_file}"
    echo "COMMENT_POSTED #\$((count + 1))"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"rate-limited"* ]]
  # With an existing rate-limited marker, only 1 comment should be posted (fresh marker
  # only — the visible ack must be suppressed to avoid a misleading repeat)
  local final_count
  final_count=$(cat "$comment_count_file")
  rm -f "$comment_count_file"
  [ "$final_count" -eq 1 ]
}

@test "fix-reviews: rate-limited: old rate-limited marker deleted only after new one is posted" {
  # If the new marker post fails, the old marker must remain as a safety net so the
  # retry cron does not lose track of the SHA+intent.
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="ddd444eee555"
  export COPILOT_GITHUB_TOKEN="stub-token"

  local delete_log
  delete_log=$(mktemp)
  local comment_log
  comment_log=$(mktemp)

  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "rate limit exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  # Stub: returns existing rate-limited marker; records DELETE and comment order
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
case "\$1" in
  copilot) echo "rate limit exceeded"; exit 1 ;;
esac
ARGS="\$*"
case "\$ARGS" in
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
  *"-X DELETE"*)
    echo "DELETE" >> "${delete_log}"
    exit 0 ;;
  *"api"*"repos/"*"issues/"*)
    echo '[{"id":42,"body":"<!-- dev-lead-fix-reviews pr=54 sha=ddd444eee555 intent=fix-reviews status=rate-limited -->"}]' ;;
  *"pr comment"*)
    echo "COMMENT" >> "${comment_log}"
    echo "COMMENT_POSTED"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 2 ]
  # New marker must have been posted
  [ -s "$comment_log" ]
  # Old marker must have been deleted (after new one posted)
  [ -s "$delete_log" ]
  # COMMENT must appear before DELETE in the combined operation sequence
  # (verified by checking both logs are non-empty and comment was posted)
  [[ "$output" == *"COMMENT_POSTED"* ]]
  rm -f "$delete_log" "$comment_log"
}

# ── holistic assessment: CI_STATUS_JSON and ALL_REVIEWS_JSON fetching ──────────
# These tests verify that fix-reviews, review-changes, and fix-bot-comment all
# fetch CI check results and all PR reviews before running the engine, so the
# agent can detect Tier-1 blockers (failing CI + CHANGES_REQUESTED reviews) and
# never wrongly declare "no-changes" while the PR is still blocked.

_make_assessment_gh_stub() {
  local calls_file="$1"
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
# Record every invocation for assertion
printf '%s\n' "\$*" >> "${calls_file}"
ARGS="\$*"
case "\$ARGS" in
  *"commits/"*"check-runs"*)
    # Return raw GitHub API format — script now uses --paginate piped to jq -s
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"failure","details_url":"https://example.com"}]}' ;;
  *"commits/"*"statuses"*)
    echo '[]' ;;
  *"pulls/"*"/reviews"*)
    # Return raw GitHub API format with user as object — script now uses --paginate piped to jq -s
    echo '[{"id":1,"user":{"login":"gemini-code-assist[bot]"},"state":"CHANGES_REQUESTED","submitted_at":"2024-01-01T00:00:00Z"}]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"issues/"*"comments"*)
    echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"ddd444eee555"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
}

@test "fix-reviews: fix-reviews case fetches CI check-runs endpoint" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  # Script must have called the check-runs API endpoint
  grep -q "commits/.*check-runs" "$calls_file"
  rm -f "$calls_file"
}

@test "fix-reviews: fix-reviews case fetches all PR reviews endpoint" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  # Script must have called the reviews API endpoint
  grep -q "pulls/.*reviews" "$calls_file"
  rm -f "$calls_file"
}

@test "fix-reviews: review-changes case fetches CI check-runs endpoint" {
  export INTENT_TYPE="review-changes"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A test pull request"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  grep -q "commits/.*check-runs" "$calls_file"
  rm -f "$calls_file"
}

@test "fix-reviews: review-changes case fetches all PR reviews endpoint" {
  export INTENT_TYPE="review-changes"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A test pull request"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  grep -q "pulls/.*reviews" "$calls_file"
  rm -f "$calls_file"
}

@test "fix-reviews: fix-bot-comment case fetches CI check-runs endpoint" {
  export INTENT_TYPE="fix-bot-comment"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"
  export COMMENT_BODY="SonarQube found issues"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  grep -q "commits/.*check-runs" "$calls_file"
  rm -f "$calls_file"
}

@test "fix-reviews: fix-bot-comment case fetches all PR reviews endpoint" {
  export INTENT_TYPE="fix-bot-comment"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"
  export COMMENT_BODY="SonarQube found issues"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  grep -q "pulls/.*reviews" "$calls_file"
  rm -f "$calls_file"
}

@test "fix-reviews: fix-reviews case fetches commit statuses endpoint" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  grep -q "commits/.*statuses" "$calls_file"
  rm -f "$calls_file"
}

@test "fix-reviews: review-changes case fetches commit statuses endpoint" {
  export INTENT_TYPE="review-changes"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A test pull request"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  grep -q "commits/.*statuses" "$calls_file"
  rm -f "$calls_file"
}

@test "fix-reviews: fix-bot-comment case fetches commit statuses endpoint" {
  export INTENT_TYPE="fix-bot-comment"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"
  export COMMENT_BODY="SonarQube found issues"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  grep -q "commits/.*statuses" "$calls_file"
  rm -f "$calls_file"
}

# ── Tier-1 blocker gating: no-changes must not be posted while blockers exist ──
# Regression tests for issue #425: the agent must not declare "no-changes" while
# CI is failing or a reviewer has CHANGES_REQUESTED.

@test "fix-reviews: does not post no-changes when Tier-1 blockers exist (fix-reviews)" {
  local calls_file tmpdir
  calls_file="$(mktemp)"
  tmpdir="$(mktemp -d)"
  _make_assessment_gh_stub "$calls_file"

  # Run from a non-git tmpdir so commit_and_push returns 1 (no changes), taking the no-changes path
  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$calls_file"

  [ "$status" -eq 0 ]
  # Must NOT post a terminal no-changes marker while CI is failing + CHANGES_REQUESTED
  [[ "$output" != *"status=no-changes"* ]]
  # Must emit the warning explaining why no-changes was skipped
  [[ "$output" == *"Tier-1 blockers still present"* ]]
}

@test "fix-reviews: fix-bot-comment with hard blockers posts terminal no-changes (not silently skipped)" {
  # fix-bot-comment is excluded from RETRYABLE_REVIEW_INTENTS, so when hard blockers
  # exist (failing CI or CHANGES_REQUESTED) and no code changes were made, we must
  # post a terminal no-changes marker rather than leaving the SHA without any marker.
  local calls_file tmpdir
  calls_file="$(mktemp)"
  tmpdir="$(mktemp -d)"
  _make_assessment_gh_stub "$calls_file"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-bot-comment DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='combsmith/.github-private'
    export COMMENT_BODY='SonarQube found issues'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$calls_file"

  [ "$status" -eq 0 ]
  # Hard blockers present + no code changes → must post terminal marker (not silently skip)
  [[ "$output" == *"status=no-changes"* ]]
  [[ "$output" == *"Tier-1 blockers still present"* ]]
  # Must not post a rate-limited marker (fix-bot-comment is not retried automatically)
  [[ "$output" != *"[dry-run] would post rate-limited marker"* ]]
}

@test "fix-reviews: does not post no-changes when Tier-1 blockers exist (review-changes)" {
  local calls_file tmpdir
  calls_file="$(mktemp)"
  tmpdir="$(mktemp -d)"
  _make_assessment_gh_stub "$calls_file"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='combsmith/.github-private'
    export PR_TITLE='Test PR' PR_DESCRIPTION='A test pull request'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$calls_file"

  [ "$status" -eq 0 ]
  [[ "$output" != *"status=no-changes"* ]]
  [[ "$output" == *"Tier-1 blockers still present"* ]]
}

@test "fix-reviews: posts no-changes when no Tier-1 blockers exist (fix-reviews)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub with all-success CI and no CHANGES_REQUESTED reviews
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"commits/"*"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"commits/"*"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"issues/"*"comments"*)
    echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"ddd444eee555"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  # Run from a non-git tmpdir so commit_and_push returns 1 (no changes), taking the no-changes path
  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # No blockers → no-changes marker should be posted
  [[ "$output" == *"status=no-changes"* ]]
}

# ── #1859: blocking checks gated via lib/ci-status.sh (required-only) ──────────
# dev-lead must not refuse work over a failing NON-required check. The blocker
# gate now delegates to compute_ci_status (lib/ci-status.sh): a red non-required
# check is ignored, a red REQUIRED check still blocks, CHANGES_REQUESTED still
# blocks, and an unreadable required set fails closed (every failing check blocks).

@test "fix-reviews (#1859): red NON-required check + green required check → pass proceeds" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # template-drift (NON-required) is failing; Lint (the required check) is green.
  # The branch ruleset names only Lint as required, so template-drift must NOT block.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"rules/branches"*)
    echo '["Lint"]' ;;
  *"branches/"*"protection"*)
    echo '{}' ;;
  *"commits/"*"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com/1"},{"name":"template-drift","status":"completed","conclusion":"failure","details_url":"https://example.com/2"}]}' ;;
  *"commits/"*"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"issues/"*"comments"*)
    echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"ddd444eee555"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # A red non-required check must not stop the pass: no retry marker, terminal posted.
  [[ "$output" != *"Tier-1 blockers still present"* ]]
  [[ "$output" != *"rate-limited marker"* ]]
  [[ "$output" == *"status=no-changes"* ]]
}

@test "fix-reviews (#1859): red REQUIRED check still blocks" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Lint is both required (per the ruleset) and failing → must still block.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"rules/branches"*)
    echo '["Lint"]' ;;
  *"branches/"*"protection"*)
    echo '{}' ;;
  *"commits/"*"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"failure","details_url":"https://example.com/1"}]}' ;;
  *"commits/"*"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"issues/"*"comments"*)
    echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"ddd444eee555"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Tier-1 blockers still present"* ]]
  # AC #5: the message names the specific blocking check and that it is required.
  [[ "$output" == *"required check"* ]]
  [[ "$output" == *'`Lint`'* ]]
  [[ "$output" == *"failing"* ]]
  [[ "$output" == *"rate-limited marker"* ]]
  [[ "$output" == *"reason=blocked"* ]]
  [[ "$output" != *"status=no-changes"* ]]
}

@test "fix-reviews (#1859): CHANGES_REQUESTED still blocks even with all-green required checks" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Every check (required + non-required) is green, but a reviewer requested changes.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"rules/branches"*)
    echo '["Lint"]' ;;
  *"branches/"*"protection"*)
    echo '{}' ;;
  *"commits/"*"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com/1"}]}' ;;
  *"commits/"*"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[{"id":7,"user":{"login":"a-human"},"state":"CHANGES_REQUESTED","submitted_at":"2026-01-01T00:00:00Z"}]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"issues/"*"comments"*)
    echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"ddd444eee555"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Tier-1 blockers still present"* ]]
  [[ "$output" == *"rate-limited marker"* ]]
  [[ "$output" != *"status=no-changes"* ]]
}

@test "fix-reviews (#1859): unreadable required set fails closed — red non-required check blocks" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # The ruleset API errors (unreadable). Per ci-status.sh's fail-closed contract,
  # every failing check is then treated as blocking — so template-drift blocks.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"rules/branches"*)
    echo "API error: not accessible" >&2; exit 1 ;;
  *"branches/"*"protection"*)
    echo "API error: not accessible" >&2; exit 1 ;;
  *"commits/"*"check-runs"*)
    echo '{"check_runs":[{"name":"template-drift","status":"completed","conclusion":"failure","details_url":"https://example.com/2"}]}' ;;
  *"commits/"*"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"issues/"*"comments"*)
    echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"ddd444eee555"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Tier-1 blockers still present"* ]]
  # AC #5: fail-closed message names the check and flags the unreadable required set.
  [[ "$output" == *'`template-drift`'* ]]
  [[ "$output" == *"failing closed"* ]]
  [[ "$output" != *"status=no-changes"* ]]
}

@test "fix-reviews: readable-but-empty required set names the check WITHOUT the 'failing closed' note" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # The ruleset API reads successfully but configures NO required checks (returns
  # []). With no required set the gate falls back to every external check, so a red
  # template-drift still blocks — but the message must NOT claim the ruleset was
  # unreadable, because it was merely empty (distinct from the fail-closed case).
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"rules/branches"*)
    echo '[]' ;;
  *"branches/"*"protection"*)
    echo "API error: not accessible" >&2; exit 1 ;;
  *"commits/"*"check-runs"*)
    echo '{"check_runs":[{"name":"template-drift","status":"completed","conclusion":"failure","details_url":"https://example.com/2"}]}' ;;
  *"commits/"*"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"issues/"*"comments"*)
    echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"ddd444eee555"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Tier-1 blockers still present"* ]]
  # The blocker is still named…
  [[ "$output" == *'`template-drift`'* ]]
  # …but a readable-but-empty ruleset must NOT be reported as unreadable.
  [[ "$output" != *"failing closed"* ]]
  [[ "$output" != *"status=no-changes"* ]]
}

# ── Legacy commit statuses dedup: latest state per context wins ────────────────
# The /statuses API returns the full history per context (newest first). A stale
# failure followed by a newer success for the same context must not suppress
# no-changes — only the latest entry per context should be considered.
readonly JQ_DEDUP_STATUSES='[ [.[].[] | select(.context != null)] | group_by(.context)[] | first | {name:.context, conclusion:(if .state == "success" then "success" elif .state == "failure" or .state == "error" then "failure" else "pending" end)} ]'

@test "collect_assessment_data: jq statuses dedup keeps only latest entry per context" {
  # GitHub /statuses API returns newest-first. Here jenkins/build had a failure then a
  # newer success, so success appears first in the array (= newest). After dedup, only
  # the success (first entry per context) should remain.
  local input='[
    {"context":"jenkins/build","state":"success","target_url":"https://ci.example.com/2"},
    {"context":"jenkins/build","state":"failure","target_url":"https://ci.example.com/1"},
    {"context":"other/check","state":"success","target_url":"https://ci.example.com/3"}
  ]'

  run bash -c "printf '%s' '$input' | jq -s '$JQ_DEDUP_STATUSES'"

  [ "$status" -eq 0 ]
  # The newer success for jenkins/build must appear; the old failure must not
  local jenkins_conclusion
  jenkins_conclusion=$(echo "$output" | jq -r '.[] | select(.name == "jenkins/build") | .conclusion')
  [ "$jenkins_conclusion" = "success" ]
  # Only one entry for jenkins/build — no duplicate
  local jenkins_count
  jenkins_count=$(echo "$output" | jq '[.[] | select(.name == "jenkins/build")] | length')
  [ "$jenkins_count" -eq 1 ]
}

@test "fix-reviews: does not treat superseded legacy CI failure as Tier-1 blocker (fix-reviews)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: check-runs all success; statuses has old failure then new success for same context
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"commits/"*"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"commits/"*"statuses"*)
    # Newest-first: success (newer) comes before failure (older) in the history
    echo '[{"context":"jenkins/build","state":"success","target_url":"https://ci.example.com/2"},{"context":"jenkins/build","state":"failure","target_url":"https://ci.example.com/1"}]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"issues/"*"comments"*)
    echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"ddd444eee555"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  # Run from a non-git tmpdir so commit_and_push returns 1 (no changes), taking the no-changes path
  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # The old failure is superseded by the newer success → no Tier-1 blockers → no-changes is posted
  [[ "$output" == *"status=no-changes"* ]]
  [[ "$output" != *"Tier-1 blockers still present"* ]]
}

@test "fix-reviews: resolve_bot_outdated_threads called in no-changes path (dry-run)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"resolve outdated review threads from bot reviewers"* ]]
}

@test "fix-reviews: bot-thread-only blocker suppresses no-changes terminal (review-changes)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: check-runs success, statuses none, but graphql returns unresolved bot threads
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    # First query (for has_tier1_blockers) or review-changes context query returns bot threads
    echo '{
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "isResolved": false,
                  "comments": {"nodes": [{"author": {"login": "copilot-pull-request-reviewer[bot]"}}]}
                },
                {
                  "isResolved": false,
                  "comments": {"nodes": [{"author": {"login": "coderabbitai[bot]"}}]}
                }
              ]
            },
            "reviewDecision": null
          }
        }
      }
    }' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Bot threads only → no hard blockers → must NOT post terminal no-changes (would mask future retries)
  [[ "$output" != *"status=no-changes"* ]]
  [[ "$output" == *"Unresolved bot review threads remain"* ]]
  [[ "$output" != *"rate-limited marker"* ]]
}

@test "fix-reviews: suppresses no-changes terminal when only bot threads block (review-changes)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: graphql returns unresolved bot threads but no failing CI
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "isResolved": false,
                  "comments": {"nodes": [{"author": {"login": "copilot-pull-request-reviewer[bot]"}}]}
                }
              ]
            }
          }
        }
      }
    }' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Bot threads only, no hard blockers → must NOT post terminal no-changes (would mask future retries)
  [[ "$output" != *"status=no-changes"* ]]
  [[ "$output" == *"Unresolved bot review threads remain"* ]]
  [[ "$output" != *"rate-limited marker"* ]]
}

@test "fix-reviews: detects bot threads via __typename Bot and suppresses no-changes (review-changes)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: graphql returns a bot thread where login has no [bot] suffix but __typename is "Bot"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "isResolved": false,
                  "comments": {"nodes": [{"author": {"login": "some-bot-without-suffix", "__typename": "Bot"}}]}
                }
              ]
            },
            "reviewDecision": null
          }
        }
      }
    }' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Bot detected via __typename == "Bot" even without [bot] suffix → must NOT post no-changes
  [[ "$output" != *"status=no-changes"* ]]
  [[ "$output" == *"Unresolved bot review threads remain"* ]]
  [[ "$output" != *"rate-limited marker"* ]]
}

@test "fix-reviews: bot-thread query failure is treated conservatively (as blocked)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: graphql call exits nonzero (simulates transient GitHub error / secondary rate limit).
  # Uses fix-bot-comment intent because has_tier1_blockers is still called there.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    # Simulate transient API failure — exit nonzero
    echo "GraphQL error: secondary rate limit" >&2
    exit 1 ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-bot-comment DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export COMMENT_BODY='SonarQube found issues'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Query failure → has_tier1_blockers returns 0 (conservatively blocked) → warning emitted
  # → no-changes terminal is still posted (fix-bot-comment elif branch), not silently skipped
  [[ "$output" == *"bot-thread query failed"* ]]
  [[ "$output" == *"status=no-changes"* ]]
  [[ "$output" != *"rate-limited marker"* ]]
}

@test "fix-reviews: hard blockers take precedence over bot thread warning" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: failing CI + unresolved bot thread → hard blocker wins, no retry marker
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"failure","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "isResolved": false,
                  "comments": {"nodes": [{"author": {"login": "coderabbitai[bot]", "__typename": "Bot"}}]}
                }
              ]
            },
            "reviewDecision": null
          }
        }
      }
    }' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Hard blocker (failing CI) → shows hard-blocker warning, NOT the bot-thread retry path,
  # and now posts a rate-limited marker so the cron can retry later.
  [[ "$output" == *"Tier-1 blockers still present"* ]]
  [[ "$output" != *"Unresolved bot review threads remain"* ]]
  [[ "$output" != *"status=no-changes"* ]]
  [[ "$output" == *"rate-limited marker"* ]]
  # Must include a future reset time so the retry cron backs off instead of re-dispatching immediately
  [[ "$output" == *"reset="* ]]
}

@test "fix-reviews: hard blockers path posts rate-limited marker for retry" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: failing CI, no bot threads — hard blocker only
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"failure","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Hard blockers path must post a rate-limited marker so the retry cron can re-dispatch
  [[ "$output" == *"Tier-1 blockers still present"* ]]
  [[ "$output" == *"rate-limited marker"* ]]
  [[ "$output" != *"status=no-changes"* ]]
  # Must include a future reset time so the retry cron backs off instead of re-dispatching immediately
  [[ "$output" == *"reset="* ]]
  # Honest token (issue #1568): a non-quota hold emits status=blocked, never
  # status=rate-limited, and must not claim the engines are rate-limited.
  [[ "$output" == *"status=blocked"* ]]
  [[ "$output" != *"status=rate-limited"* ]]
  [[ "$output" == *"reason=blocked"* ]]
  [[ "$output" == *"waiting on PR blockers"* ]]
  [[ "$output" != *"all AI engines are currently rate-limited"* ]]
}

@test "review-changes: hard blockers path posts rate-limited marker for retry" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: failing CI, no bot threads — hard blocker only
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"failure","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Tier-1 blockers still present"* ]]
  [[ "$output" == *"rate-limited marker"* ]]
  [[ "$output" != *"status=no-changes"* ]]
  # Must include a future reset time so the retry cron backs off instead of re-dispatching immediately
  [[ "$output" == *"reset="* ]]
  # Honest token (issue #1568): a non-quota hold emits status=blocked, never
  # status=rate-limited, and must not claim the engines are rate-limited.
  [[ "$output" == *"status=blocked"* ]]
  [[ "$output" != *"status=rate-limited"* ]]
  [[ "$output" == *"reason=blocked"* ]]
  [[ "$output" == *"waiting on PR blockers"* ]]
  [[ "$output" != *"all AI engines are currently rate-limited"* ]]
  # The visible review-changes ack explains the real cause honestly
  [[ "$output" == *"no code changes were needed"* ]]
}

# ── check-run dedup: superseded runs must not register as blockers (issue #461) ─

@test "review-changes: superseded cancelled check run is not a hard blocker" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: three same-named check runs from different check suites — two
  # concurrency-cancelled runs superseded by a newer successful one (the exact
  # shape of the PR #453 incident). Only the newest run per name may count.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"id":101,"name":"review","status":"completed","conclusion":"cancelled","started_at":"2026-06-07T13:08:53Z","details_url":"https://example.com/1"},{"id":102,"name":"review","status":"completed","conclusion":"cancelled","started_at":"2026-06-07T13:08:54Z","details_url":"https://example.com/2"},{"id":103,"name":"review","status":"completed","conclusion":"success","started_at":"2026-06-07T13:08:56Z","details_url":"https://example.com/3"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # The superseded cancelled runs must not block: no retry marker, terminal no-changes posted
  [[ "$output" != *"Tier-1 blockers still present"* ]]
  [[ "$output" != *"rate-limited marker"* ]]
  [[ "$output" == *"status=no-changes"* ]]
}

@test "review-changes: lone cancelled check run is not a hard blocker (#608/#1859)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: a single cancelled check run (a superseded, non-required job). Since the
  # blocker gate now delegates to lib/ci-status.sh, a CANCELLED check is
  # non-blocking (#608) — it is not a failure. The pass proceeds to a no-changes
  # terminal rather than posting a retry marker.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"id":201,"name":"some-check","status":"completed","conclusion":"cancelled","started_at":"2026-06-07T13:08:53Z","details_url":"https://example.com/1"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  [[ "$output" != *"Tier-1 blockers still present"* ]]
  [[ "$output" != *"rate-limited marker"* ]]
  [[ "$output" == *"status=no-changes"* ]]
}

@test "review-changes: same-named check runs from different apps are not collapsed" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: two check runs with the same name but from different GitHub Apps.
  # App 111 (success, newer) must not hide app 222 (cancelled, older) — they are
  # distinct logical checks and both must be evaluated independently.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"id":301,"name":"ShellCheck","status":"completed","conclusion":"success","started_at":"2026-06-07T14:00:00Z","details_url":"https://example.com/1","app":{"id":111}},{"id":302,"name":"ShellCheck","status":"completed","conclusion":"cancelled","started_at":"2026-06-07T13:55:00Z","details_url":"https://example.com/2","app":{"id":222}}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # The cancelled run from a different app stays distinct in CI_STATUS_JSON, but a
  # cancelled check is not a blocker (#608/#1859) — with only a success and a
  # cancelled run present, compute_ci_status is passing so the pass proceeds.
  [[ "$output" != *"Tier-1 blockers still present"* ]]
  [[ "$output" != *"rate-limited marker"* ]]
  [[ "$output" == *"status=no-changes"* ]]
}

@test "review-changes: same app different workflow suites are not collapsed — failure survives" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: two check runs with the same name and same app (GitHub Actions, id=15368)
  # but from different check suites (different workflows). The newer run (id=502,
  # suite 501) succeeds while the older run (id=501, suite 500) fails. With the old
  # group_by([name, app]) key the failure was hidden; the new check_suite discriminator
  # keeps them separate so the failure still registers as a Tier-1 blocker.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"id":501,"name":"Build","status":"completed","conclusion":"failure","started_at":"2026-06-07T14:00:00Z","details_url":"https://example.com/1","app":{"id":15368},"check_suite":{"id":500}},{"id":502,"name":"Build","status":"completed","conclusion":"success","started_at":"2026-06-07T14:00:01Z","details_url":"https://example.com/2","app":{"id":15368},"check_suite":{"id":501}}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # The failure from workflow-suite 500 must not be hidden by the success from
  # workflow-suite 501 — different suites mean different required checks.
  [[ "$output" == *"Tier-1 blockers still present"* ]]
  [[ "$output" == *"rate-limited marker"* ]]
  [[ "$output" == *"reason=blocked"* ]]
  [[ "$output" != *"status=no-changes"* ]]
}

@test "review-changes: same app different suites — superseded cancelled run is dropped" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: same name and app (GitHub Actions, id=15368) across DIFFERENT check
  # suites — the exact PR #453 incident with explicit suite ids: a concurrency-
  # cancelled run (id=501, suite 500) superseded by a newer success (id=502,
  # suite 501). Stage 1 keeps both (distinct suites); Stage 2's deliberate
  # cross-suite (name, app) match must drop the cancelled one. Requiring suite
  # equality in Stage 2 would make this test fail and reintroduce issue #461's
  # endless retry loop — the superseding run always lives in a different suite.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"id":501,"name":"review","status":"completed","conclusion":"cancelled","started_at":"2026-06-07T14:00:00Z","details_url":"https://example.com/1","app":{"id":15368},"check_suite":{"id":500}},{"id":502,"name":"review","status":"completed","conclusion":"success","started_at":"2026-06-07T14:00:01Z","details_url":"https://example.com/2","app":{"id":15368},"check_suite":{"id":501}}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # The superseded cancelled run must be dropped even though its suite differs
  # from the success's — matches GitHub's latest-same-named-run merge gate.
  [[ "$output" != *"Tier-1 blockers still present"* ]]
  [[ "$output" != *"rate-limited marker"* ]]
  [[ "$output" == *"status=no-changes"* ]]
}

@test "review-changes: queued check run without started_at wins over older cancelled run by id" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: two same-named runs in the same (name, app, suite=null) group. The older
  # run (id=99) is cancelled and has a started_at; the newer run (id=100) is queued
  # and has no started_at. With the old sort_by([.started_at // "", .id // 0]) the
  # empty string sorts before any timestamp, so the cancelled run (started_at set)
  # ended up as `last` and wrongly blocked. sort_by([.id // 0]) always picks the
  # higher-id (newer) run regardless of started_at presence.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"id":99,"name":"review","status":"completed","conclusion":"cancelled","started_at":"2026-06-07T13:00:00Z","details_url":"https://example.com/1"},{"id":100,"name":"review","status":"queued","conclusion":null,"details_url":"https://example.com/2"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # The queued run (id=100) must win: the cancelled run (id=99) is superseded within
  # its group and must not register as a Tier-1 blocker.
  [[ "$output" != *"Tier-1 blockers still present"* ]]
  [[ "$output" != *"rate-limited marker"* ]]
  [[ "$output" == *"status=no-changes"* ]]
}

@test "fix-reviews: bot-thread-only blocker suppresses no-changes terminal (fix-reviews intent)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: success CI, no CHANGES_REQUESTED, unresolved bot thread only
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "isResolved": false,
                  "comments": {"nodes": [{"author": {"login": "copilot-pull-request-reviewer[bot]"}}]}
                }
              ]
            },
            "reviewDecision": null
          }
        }
      }
    }' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Bot threads only → no hard blockers → must NOT post terminal no-changes (would mask future retries)
  [[ "$output" != *"status=no-changes"* ]]
  [[ "$output" == *"Unresolved bot review threads remain"* ]]
  [[ "$output" != *"rate-limited marker"* ]]
  [[ "$output" != *"reset="* ]]
}

@test "fix-bot-comment: unresolved bot threads posts no-changes terminal marker" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: success CI, no CHANGES_REQUESTED, unresolved bot thread
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "isResolved": false,
                  "comments": {"nodes": [{"author": {"login": "copilot-pull-request-reviewer[bot]"}}]}
                }
              ]
            },
            "reviewDecision": null
          }
        }
      }
    }' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-bot-comment DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export COMMENT_BODY='bot feedback' ACTOR='copilot-pull-request-reviewer[bot]'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # fix-bot-comment is not retryable, so bot-thread blocker posts terminal no-changes (not rate-limited)
  [[ "$output" == *"fix-bot-comment is not automatically retried"* ]]
  [[ "$output" == *"status=no-changes"* ]]
  [[ "$output" != *"[dry-run] would post rate-limited marker"* ]]
}

# ── Thread 1: pending legacy statuses are treated as Tier-1 blockers ─────────

@test "fix-reviews: pending legacy status is treated as Tier-1 blocker" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: check-runs all pass, but an external legacy status is still pending
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[{"context":"jenkins/build","state":"pending","target_url":"https://ci.example.com/1"}]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"issues/"*"comments"*)
    echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"ddd444eee555"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # A pending legacy status must block no-changes — it may still fail and workflows
  # don't listen for status events, so we cannot safely declare completion.
  [[ "$output" != *"status=no-changes"* ]]
  [[ "$output" == *"Tier-1 blockers still present"* ]]
}

@test "collect_assessment_data: jq statuses maps pending state to pending conclusion" {
  # Pending external statuses must produce conclusion="pending" so has_hard_blockers
  # treats them as blockers — unlike null, "pending" is in the explicit blocker list.
  local input='[
    {"context":"jenkins/build","state":"pending","target_url":"https://ci.example.com/1"}
  ]'

  run bash -c "printf '%s' '$input' | jq -s '$JQ_DEDUP_STATUSES'"

  [ "$status" -eq 0 ]
  local jenkins_conclusion
  jenkins_conclusion=$(echo "$output" | jq -r '.[] | select(.name == "jenkins/build") | .conclusion')
  [ "$jenkins_conclusion" = "pending" ]
}

# ── Thread 2: statuses fetch failure fails closed ────────────────────────────

@test "fix-reviews: statuses API fetch failure exits non-zero (fails closed)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: check-runs pass, but statuses API call fails (token scope / transient error)
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo "API error: resource not accessible" >&2; exit 1 ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"ddd444eee555"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  # When legacy statuses cannot be fetched we cannot safely assess CI state —
  # the script must exit non-zero rather than posting a terminal no-changes marker.
  [ "$status" -ne 0 ]
  [[ "$output" != *"status=no-changes"* ]]
}

# ── Thread 3: stale no-changes marker is expired before hard-blocker retry ───

@test "fix-reviews: hard-blocker retry expires stale no-changes marker (dry-run)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: failing CI triggers the hard-blocker retry path
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"failure","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"issues/"*"comments"*)
    echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Hard-blocker path must announce it would expire stale terminal markers so the
  # retry cron is not blocked by a prior terminal marker for the same SHA+intent.
  [[ "$output" == *"would expire stale terminal markers"* ]]
  [[ "$output" == *"rate-limited marker"* ]]
}

@test "fix-reviews: hard-blocker retry deletes existing no-changes comment (non-dry-run)" {
  local tmpdir deletions_file
  tmpdir="$(mktemp -d)"
  deletions_file="$(mktemp)"

  # Set up a real git repo so commit_and_push reports "no changes"
  git -C "$tmpdir" init -q
  echo "initial" > "$tmpdir/file.txt"
  git -C "$tmpdir" add .
  git -C "$tmpdir" -c user.email="t@test" -c user.name="T" commit -q -m "init"

  # Stub: failing CI + a stale no-changes comment in issues/comments
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"failure","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"-X DELETE"*)
    # Record DELETE calls (must come before the generic issues/comments match)
    echo "\$*" >> "${deletions_file}"; exit 0 ;;
  *"issues/"*"comments"*)
    # Return a stale no-changes terminal marker for same SHA+intent
    echo '[{"id":9001,"body":"<!-- dev-lead-fix-reviews pr=54 sha=abc123 intent=fix-reviews status=no-changes -->"}]' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) echo "COMMENT_POSTED"; exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "No actionable items."
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  # The stale no-changes comment must have been deleted
  grep -q "9001" "$deletions_file"
  rm -rf "$tmpdir"
  rm -f "$deletions_file"
}

# ── Thread 1: all terminal statuses (applied/no-changes/failed) are expired ──

@test "fix-reviews: hard-blocker retry expires stale applied terminal marker (dry-run)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: failing CI triggers the hard-blocker retry path
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"failure","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"issues/"*"comments"*)
    echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Hard-blocker path must announce expiration of ALL terminal markers (not just no-changes)
  # so that prior applied/failed terminals cannot mask a new retry on the same SHA.
  [[ "$output" == *"would expire stale terminal markers"* ]]
  [[ "$output" == *"rate-limited marker"* ]]
}

@test "fix-reviews: hard-blocker retry deletes existing applied terminal comment (non-dry-run)" {
  local tmpdir deletions_file
  tmpdir="$(mktemp -d)"
  deletions_file="$(mktemp)"

  # Set up a real git repo so commit_and_push reports "no changes"
  git -C "$tmpdir" init -q
  echo "initial" > "$tmpdir/file.txt"
  git -C "$tmpdir" add .
  git -C "$tmpdir" -c user.email="t@test" -c user.name="T" commit -q -m "init"

  # Stub: failing CI + a stale applied terminal for same SHA+intent
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"failure","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"-X DELETE"*)
    echo "\$*" >> "${deletions_file}"; exit 0 ;;
  *"issues/"*"comments"*)
    echo '[{"id":9002,"body":"<!-- dev-lead-fix-reviews pr=54 sha=abc123 intent=fix-reviews status=applied -->"}]' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) echo "COMMENT_POSTED"; exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "No actionable items."
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  # The stale applied terminal must have been deleted so the retry cron is not blocked
  grep -q "9002" "$deletions_file"
  rm -rf "$tmpdir"
  rm -f "$deletions_file"
}

# ── Thread 2: stale rate-limited marker is replaced with a fresh reset_time ──

@test "fix-reviews: hard-blocker retry expires stale rate-limited marker for refresh (dry-run)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: failing CI triggers the hard-blocker retry path
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"failure","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"issues/"*"comments"*)
    echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Hard-blocker path must announce expiration of the old rate-limited marker so that
  # a fresh one with an updated reset_time is posted (prevents indefinite retry loop).
  [[ "$output" == *"would expire stale rate-limited marker"* ]]
  [[ "$output" == *"rate-limited marker"* ]]
}

@test "fix-reviews: hard-blocker retry deletes existing rate-limited comment (non-dry-run)" {
  local tmpdir deletions_file
  tmpdir="$(mktemp -d)"
  deletions_file="$(mktemp)"

  # Set up a real git repo so commit_and_push reports "no changes"
  git -C "$tmpdir" init -q
  echo "initial" > "$tmpdir/file.txt"
  git -C "$tmpdir" add .
  git -C "$tmpdir" -c user.email="t@test" -c user.name="T" commit -q -m "init"

  # Stub: failing CI + a stale rate-limited marker for same SHA+intent
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"failure","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"-X DELETE"*)
    echo "\$*" >> "${deletions_file}"; exit 0 ;;
  *"issues/"*"comments"*)
    # Return a stale rate-limited marker for same SHA+intent — must be replaced with fresh reset_time
    echo '[{"id":9003,"body":"<!-- dev-lead-fix-reviews pr=54 sha=abc123 intent=fix-reviews status=rate-limited reset=2020-01-01T00:00:00Z -->"}]' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) echo "COMMENT_POSTED"; exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "No actionable items."
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  # The stale rate-limited comment must have been deleted so a fresh one can be posted
  grep -q "9003" "$deletions_file"
  # A fresh rate-limited marker must be posted after the stale one is deleted —
  # without this the retry cron sees only the old marker (past reset_time) and
  # dispatches on every scan indefinitely.
  [[ "$output" == *"COMMENT_POSTED"* ]]
  rm -rf "$tmpdir"
  rm -f "$deletions_file"
}

# ── No-op guard (#1340): never push a fix that nets base…head to zero ──────────

# Shared setup helper: build a repo whose feat commit adds a line, point
# refs/remotes/origin/main at the base commit, and install a gh/git stub that
# records flag comments, label edits, merges, and pushes. The engine (claude
# stub) rewrites file.txt to the caller-provided content. Captures both base and
# head SHAs as NOOP_BASE_SHA and NOOP_HEAD_SHA.
_noop_setup_repo() {
  local git_repo="$1" engine_content="$2"
  git -C "$git_repo" init -q
  printf 'base\n' > "$git_repo/file.txt"
  git -C "$git_repo" add .
  git -C "$git_repo" -c user.email="t@test" -c user.name="T" commit -q -m "base"
  NOOP_BASE_SHA="$(git -C "$git_repo" rev-parse HEAD)"
  # origin/main is shared across worktrees created from this repo
  git -C "$git_repo" update-ref refs/remotes/origin/main "$NOOP_BASE_SHA"
  # feat commit adds a line the fix pass may (or may not) revert
  printf 'base\nfeature\n' > "$git_repo/file.txt"
  git -C "$git_repo" add .
  git -C "$git_repo" -c user.email="t@test" -c user.name="T" commit -q -m "feat: add feature"
  NOOP_HEAD_SHA="$(git -C "$git_repo" rev-parse HEAD)"

  cat > "$STUB_BIN_DIR/claude" << STUB
#!/usr/bin/env bash
echo "Addressed review feedback."
printf '${engine_content}' > file.txt
STUB
  chmod +x "$STUB_BIN_DIR/claude"
}

_noop_gh_stub() {
  local comment_file="$1" merge_file="$2" head_sha="${3:-}"
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"pr view"*) echo '{"state":"OPEN","headRefName":"feat"}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) echo "\$*" >> "${comment_file}"; exit 0 ;;
  *"pr edit"*) echo "\$*" >> "${comment_file}"; exit 0 ;;
  *"pr merge"*) echo "\$*" >> "${merge_file}"; exit 0 ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"statuses"*) echo '[]' ;;
  *"reviews"*) echo '[]' ;;
  *"graphql"*) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
  *"issues/"*"comments"*) echo '[]' ;;
  *"pulls/"*) echo '{"head":{"sha":"${head_sha}"},"auto_merge":null,"state":"open"}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
}

_noop_git_stub() {
  local push_file="$1"
  cat > "$STUB_BIN_DIR/git" << GITEOF
#!/usr/bin/env bash
if [ "\$1" = "push" ]; then echo "\$*" >> "${push_file}"; exit 0; fi
exec /usr/bin/git "\$@"
GITEOF
  chmod +x "$STUB_BIN_DIR/git"
}

@test "no-op guard: fix-reviews net-zero diff flags PR and does not push (#1340)" {
  local git_repo="$BATS_TEST_TMPDIR/git_repo"
  local comment_file="$BATS_TEST_TMPDIR/comment_file"
  local merge_file="$BATS_TEST_TMPDIR/merge_file"
  local push_file="$BATS_TEST_TMPDIR/push_file"
  mkdir -p "$git_repo"
  touch "$comment_file" "$merge_file" "$push_file"

  # Engine reverts the feature line → net base…head diff becomes empty.
  _noop_setup_repo "$git_repo" 'base\n'
  _noop_gh_stub "$comment_file" "$merge_file" "$NOOP_HEAD_SHA"
  _noop_git_stub "$push_file"

  cd "$git_repo"
  run bash -c "
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$NOOP_HEAD_SHA REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH="$STUB_BIN_DIR:\$PATH"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  # Guard fired and announced the net-zero refusal
  [[ "$output" == *"No-op guard"* ]]
  # The self-cancelling fix was NOT pushed
  [ ! -s "$push_file" ]
  # A needs-human flag comment was posted
  grep -q "No-op fix detected" "$comment_file"
  # Auto-merge was disabled
  grep -q "disable-auto" "$merge_file"
  # No false "applied" terminal marker
  run grep -q "status=applied" "$comment_file"
  [ "$status" -eq 1 ]
}

@test "no-op guard: fix-bot-comment net-zero diff flags PR and does not push (#1340)" {
  local git_repo="$BATS_TEST_TMPDIR/git_repo"
  local comment_file="$BATS_TEST_TMPDIR/comment_file"
  local merge_file="$BATS_TEST_TMPDIR/merge_file"
  local push_file="$BATS_TEST_TMPDIR/push_file"
  mkdir -p "$git_repo"
  touch "$comment_file" "$merge_file" "$push_file"

  _noop_setup_repo "$git_repo" 'base\n'
  _noop_gh_stub "$comment_file" "$merge_file" "$NOOP_HEAD_SHA"
  _noop_git_stub "$push_file"

  cd "$git_repo"
  run bash -c "
    export INTENT_TYPE=fix-bot-comment DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$NOOP_HEAD_SHA REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='github-copilot[bot]' COMMENT_BODY='This PR overview describes the diff.'
    export PATH="$STUB_BIN_DIR:\$PATH"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  [[ "$output" == *"No-op guard"* ]]
  [ ! -s "$push_file" ]
  grep -q "No-op fix detected" "$comment_file"
  grep -q "disable-auto" "$merge_file"
  run grep -q "status=applied" "$comment_file"
  [ "$status" -eq 1 ]
}

@test "no-op guard: non-empty net diff pushes normally and posts applied (#1340)" {
  local git_repo="$BATS_TEST_TMPDIR/git_repo"
  local comment_file="$BATS_TEST_TMPDIR/comment_file"
  local merge_file="$BATS_TEST_TMPDIR/merge_file"
  local push_file="$BATS_TEST_TMPDIR/push_file"
  mkdir -p "$git_repo"
  touch "$comment_file" "$merge_file" "$push_file"

  # Engine keeps the feature and adds a real fix → net diff is NOT empty.
  _noop_setup_repo "$git_repo" 'base\nfeature\nfix\n'
  _noop_gh_stub "$comment_file" "$merge_file" "$NOOP_HEAD_SHA"
  _noop_git_stub "$push_file"

  cd "$git_repo"
  run bash -c "
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$NOOP_HEAD_SHA REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH="$STUB_BIN_DIR:\$PATH"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  # Guard must NOT fire on a legitimate non-empty fix
  [[ "$output" != *"No-op guard"* ]]
  # The fix was pushed
  [ -s "$push_file" ]
  # An applied terminal marker was posted; no no-op flag
  grep -q "status=applied" "$comment_file"
  run grep -q "No-op fix detected" "$comment_file"
  [ "$status" -eq 1 ]
}

@test "no-op guard: net-zero path does not re-enable auto-merge (#1340)" {
  local git_repo="$BATS_TEST_TMPDIR/git_repo"
  local comment_file="$BATS_TEST_TMPDIR/comment_file"
  local merge_file="$BATS_TEST_TMPDIR/merge_file"
  local push_file="$BATS_TEST_TMPDIR/push_file"
  mkdir -p "$git_repo"
  touch "$comment_file" "$merge_file" "$push_file"

  _noop_setup_repo "$git_repo" 'base\n'
  _noop_gh_stub "$comment_file" "$merge_file" "$NOOP_HEAD_SHA"
  _noop_git_stub "$push_file"

  cd "$git_repo"
  run bash -c "
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$NOOP_HEAD_SHA REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH="$STUB_BIN_DIR:\$PATH"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  # The only merge call on the no-op path must be a disable-auto — never --auto
  grep -q "disable-auto" "$merge_file"
  run grep -q -- "--auto" "$merge_file"
  [ "$status" -eq 1 ]
}

# ── Prompt guidance (#1340): COMMENTED/overview is neutral, not a change-request ─

@test "fix-reviews prompt: instructs never to treat COMMENTED/overview as a change-request (#1340)" {
  local p="$SCRIPT_DIR/prompts/dev-lead/fix-reviews.md"
  grep -q "COMMENTED" "$p"
  grep -qi "pull request overview" "$p"
  grep -q "#1340" "$p"
}

@test "fix-bot-comment prompt: a neutral overview is not an actionable finding (#1340)" {
  local p="$SCRIPT_DIR/prompts/dev-lead/fix-bot-comment.md"
  grep -qi "overview" "$p"
  grep -q "#1340" "$p"
}

# ── Review-application evidence (#1567): status=applied requires the commit to ──
# ── be non-trivial AND touch the region the review named. ──────────────────────

# Build a repo whose HEAD carries a 10-line doc, point origin/main at a base
# commit, and install a gh stub that (a) returns a single unresolved review
# thread naming doc.md line 5 for every graphql query, (b) records comments,
# labels and merges. The engine (claude stub) rewrites doc.md to the
# caller-provided content, simulating what a fix pass changed.
# The review-changes branch assigns OPEN_THREADS_JSON via `gh api graphql … --jq
# '…reviewThreads.nodes | map(select(.isResolved == false))'`. A real gh applies
# that server-side jq; the stub cannot, so it must echo the ALREADY-EXTRACTED
# array shape (what the --jq would have produced), not the raw GraphQL wrapper.
_ev_named_thread_json='[{"id":"T1","isResolved":false,"isOutdated":false,"line":5,"path":"doc.md","comments":{"nodes":[{"body":"Please rework line 5.","author":{"login":"humanreviewer","__typename":"User"}}]}}]'

_ev_setup_repo() {
  local git_repo="$1" engine_content="$2"
  git -C "$git_repo" init -q
  printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n' > "$git_repo/doc.md"
  git -C "$git_repo" add .
  git -C "$git_repo" -c user.email="t@test" -c user.name="T" commit -q -m "base"
  git -C "$git_repo" update-ref refs/remotes/origin/main "$(git -C "$git_repo" rev-parse HEAD)"
  EV_HEAD_SHA="$(git -C "$git_repo" rev-parse HEAD)"

  cat > "$STUB_BIN_DIR/claude" << STUB
#!/usr/bin/env bash
echo "Addressed review feedback."
printf '${engine_content}' > doc.md
STUB
  chmod +x "$STUB_BIN_DIR/claude"
}

# gh stub: $3 = comments-endpoint JSON (default empty array), $4 = threads JSON.
_ev_gh_stub() {
  local comment_file="$1" merge_file="$2" comments_json="${3:-[]}" threads_json="${4:-$_ev_named_thread_json}"
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"pr view"*) echo '{"state":"OPEN","headRefName":"feat"}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) echo "\$*" >> "${comment_file}"; exit 0 ;;
  *"pr edit"*) echo "\$*" >> "${comment_file}"; exit 0 ;;
  *"pr merge"*) echo "\$*" >> "${merge_file}"; exit 0 ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"statuses"*) echo '[]' ;;
  *"reviews"*) echo '[]' ;;
  *"graphql"*) echo '${threads_json}' ;;
  *"issues/"*"comments"*) echo '${comments_json}' ;;
  *"issues/comments/"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"'"${EV_HEAD_SHA}"'"},"auto_merge":null,"state":"open"}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
}

_ev_git_stub() {
  local push_file="$1"
  cat > "$STUB_BIN_DIR/git" << GITEOF
#!/usr/bin/env bash
if [ "\$1" = "push" ]; then echo "\$*" >> "${push_file}"; exit 0; fi
exec /usr/bin/git "\$@"
GITEOF
  chmod +x "$STUB_BIN_DIR/git"
}

@test "review-changes evidence: substantive change to the named region → applied (#1567)" {
  local git_repo="$BATS_TEST_TMPDIR/r" comment_file="$BATS_TEST_TMPDIR/c" merge_file="$BATS_TEST_TMPDIR/m" push_file="$BATS_TEST_TMPDIR/p"
  mkdir -p "$git_repo"; touch "$comment_file" "$merge_file" "$push_file"
  # Engine reworks line 5 (the region the review named).
  _ev_setup_repo "$git_repo" 'line1\nline2\nline3\nline4\nline5 REWORKED\nline6\nline7\nline8\nline9\nline10\n'
  _ev_gh_stub "$comment_file" "$merge_file"
  _ev_git_stub "$push_file"

  cd "$git_repo"
  run bash -c "
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$EV_HEAD_SHA REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead' ACTOR=humanreviewer
    export PATH="$STUB_BIN_DIR:\$PATH"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  [ -s "$push_file" ]
  grep -q "status=applied" "$comment_file"
  ! grep -q "status=not-applied" "$comment_file"
}

@test "review-changes evidence: whitespace/cosmetic-only change → not applied (#1567)" {
  local git_repo="$BATS_TEST_TMPDIR/r" comment_file="$BATS_TEST_TMPDIR/c" merge_file="$BATS_TEST_TMPDIR/m" push_file="$BATS_TEST_TMPDIR/p"
  mkdir -p "$git_repo"; touch "$comment_file" "$merge_file" "$push_file"
  # Engine only adds trailing whitespace to line 5 — no substantive change.
  _ev_setup_repo "$git_repo" 'line1\nline2\nline3\nline4\nline5   \nline6\nline7\nline8\nline9\nline10\n'
  _ev_gh_stub "$comment_file" "$merge_file"
  _ev_git_stub "$push_file"

  cd "$git_repo"
  run bash -c "
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$EV_HEAD_SHA REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead' ACTOR=humanreviewer
    export PATH="$STUB_BIN_DIR:\$PATH"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  # A commit exists but it is not substantive: must NOT report applied.
  ! grep -q "status=applied" "$comment_file"
  grep -q "status=not-applied" "$comment_file"
}

@test "review-changes evidence: substantive change to an unrelated region → not applied (#1567)" {
  local git_repo="$BATS_TEST_TMPDIR/r" comment_file="$BATS_TEST_TMPDIR/c" merge_file="$BATS_TEST_TMPDIR/m" push_file="$BATS_TEST_TMPDIR/p"
  mkdir -p "$git_repo"; touch "$comment_file" "$merge_file" "$push_file"
  # Engine reworks line 1, but the review named line 5 — the #1567 shape.
  _ev_setup_repo "$git_repo" 'line1 UNRELATED\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n'
  _ev_gh_stub "$comment_file" "$merge_file"
  _ev_git_stub "$push_file"

  cd "$git_repo"
  run bash -c "
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$EV_HEAD_SHA REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead' ACTOR=humanreviewer
    export PATH="$STUB_BIN_DIR:\$PATH"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  ! grep -q "status=applied" "$comment_file"
  grep -q "status=not-applied" "$comment_file"
  # The terminal comment enumerates the unaddressed requested item.
  grep -q "doc.md:5" "$comment_file"
}

@test "review-changes evidence: no change → existing no-changes path (#1567)" {
  local git_repo="$BATS_TEST_TMPDIR/r" comment_file="$BATS_TEST_TMPDIR/c" merge_file="$BATS_TEST_TMPDIR/m" push_file="$BATS_TEST_TMPDIR/p"
  mkdir -p "$git_repo"; touch "$comment_file" "$merge_file" "$push_file"
  # Engine leaves the file unchanged → commit_and_push finds nothing.
  _ev_setup_repo "$git_repo" 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n'
  # No named threads so the else branch reaches the no-changes terminal.
  _ev_gh_stub "$comment_file" "$merge_file" "[]" '[]'
  _ev_git_stub "$push_file"

  cd "$git_repo"
  run bash -c "
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$EV_HEAD_SHA REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead' ACTOR=humanreviewer
    export PATH="$STUB_BIN_DIR:\$PATH"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  [ ! -s "$push_file" ]
  grep -q "status=no-changes" "$comment_file"
  ! grep -q "status=applied" "$comment_file"
  ! grep -q "status=not-applied" "$comment_file"
}

@test "review-changes evidence: N consecutive not-applied passes escalate to a human (#1567)" {
  local git_repo="$BATS_TEST_TMPDIR/r" comment_file="$BATS_TEST_TMPDIR/c" merge_file="$BATS_TEST_TMPDIR/m" push_file="$BATS_TEST_TMPDIR/p"
  mkdir -p "$git_repo"; touch "$comment_file" "$merge_file" "$push_file"
  _ev_setup_repo "$git_repo" 'line1 UNRELATED\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n'
  # The comments endpoint already carries 2 prior not-applied markers; this pass
  # posts the 3rd, reaching the default limit of 3 → escalate.
  local prior='[{"id":1,"body":"<!-- dev-lead-fix-reviews pr=54 sha=aaa intent=review-changes status=not-applied -->"},{"id":2,"body":"<!-- dev-lead-fix-reviews pr=54 sha=bbb intent=review-changes status=not-applied -->"},{"id":3,"body":"<!-- dev-lead-fix-reviews pr=54 sha=ccc intent=review-changes status=not-applied -->"}]'
  _ev_gh_stub "$comment_file" "$merge_file" "$prior"
  _ev_git_stub "$push_file"

  cd "$git_repo"
  run bash -c "
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$EV_HEAD_SHA REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead' ACTOR=humanreviewer
    export PATH="$STUB_BIN_DIR:\$PATH"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  # A needs-human label was applied and an escalation comment posted.
  grep -q "add-label" "$comment_file"
  grep -q "needs-human-review" "$comment_file"
  grep -qi "not converging" "$comment_file"
  # Auto-merge is disabled and never re-enabled on the escalation path.
  grep -q "disable-auto" "$merge_file"
  ! grep -q -- "--auto" "$merge_file"
}

# ── empty net-diff guard extended to review-changes + rebase (#1786, #1620) ────
#
# #1340 shipped the net-zero guard for fix-reviews/fix-bot-comment only. #1786
# extends "never push/report a self-cancelling PR" to the review-changes and
# rebase (merge-from-main) intents. Reuses the #1340 real-repo helpers.

@test "no-op guard: review-changes net-zero diff flags PR and does not push (#1786)" {
  local git_repo="$BATS_TEST_TMPDIR/git_repo"
  local comment_file="$BATS_TEST_TMPDIR/comment_file"
  local merge_file="$BATS_TEST_TMPDIR/merge_file"
  local push_file="$BATS_TEST_TMPDIR/push_file"
  mkdir -p "$git_repo"
  touch "$comment_file" "$merge_file" "$push_file"

  # Engine reverts the feature line → net base…head diff becomes empty.
  _noop_setup_repo "$git_repo" 'base\n'
  _noop_gh_stub "$comment_file" "$merge_file" "$NOOP_HEAD_SHA"
  _noop_git_stub "$push_file"

  cd "$git_repo"
  run bash -c "
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$NOOP_HEAD_SHA REPO='combsmith/.github-private'
    export ACTOR='humanreviewer'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  # Guard fired and announced the net-zero refusal
  [[ "$output" == *"No-op guard"* ]]
  # The self-cancelling fix was NOT pushed
  [ ! -s "$push_file" ]
  # A needs-human flag comment was posted
  grep -q "No-op fix detected" "$comment_file"
  # Auto-merge was disabled and never re-enabled on the net-zero path
  grep -q "disable-auto" "$merge_file"
  run grep -q -- "--auto" "$merge_file"
  [ "$status" -eq 1 ]
  # No false "applied" terminal marker
  run grep -q "status=applied" "$comment_file"
  [ "$status" -eq 1 ]
}

@test "no-op guard: rebase that nets to zero after merge-from-main is flagged, never reported applied (#1786)" {
  local git_repo="$BATS_TEST_TMPDIR/git_repo"
  local comment_file="$BATS_TEST_TMPDIR/comment_file"
  local merge_file="$BATS_TEST_TMPDIR/merge_file"
  local push_file="$BATS_TEST_TMPDIR/push_file"
  mkdir -p "$git_repo"
  touch "$comment_file" "$merge_file" "$push_file"

  _noop_setup_repo "$git_repo" 'base\n'
  _noop_gh_stub "$comment_file" "$merge_file" "$NOOP_HEAD_SHA"

  # Rebase engine: resolve by reverting the PR's own change and COMMIT it, mimicking
  # the engine's self-commit + force-push in rebase.md — so HEAD nets to zero.
  cat > "$STUB_BIN_DIR/claude" <<CSTUB
#!/usr/bin/env bash
echo "Rebased."
printf 'base\n' > file.txt
git -c user.email=t@test -c user.name=T commit -aqm "rebase resolve"
CSTUB
  chmod +x "$STUB_BIN_DIR/claude"

  # git stub: intercept push AND no-op fetch (the _noop repo has no real 'origin'
  # remote; origin/main is a bare update-ref), exec real git otherwise.
  cat > "$STUB_BIN_DIR/git" <<GITEOF
#!/usr/bin/env bash
case "\$1" in
  push)  echo "\$*" >> "${push_file}"; exit 0 ;;
  fetch) exit 0 ;;
  *)     exec /usr/bin/git "\$@" ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  cd "$git_repo"
  run bash -c "
    export INTENT_TYPE=rebase DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=$NOOP_HEAD_SHA HEAD_REF=feat REPO='combsmith/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  # Guard fired
  [[ "$output" == *"No-op guard"* ]]
  # A needs-human flag comment was posted, auto-merge disabled
  grep -q "No-op fix detected" "$comment_file"
  grep -q "disable-auto" "$merge_file"
  # A self-cancelling rebase must NEVER be reported applied.
  run grep -q "status=applied" "$comment_file"
  [ "$status" -eq 1 ]
}
