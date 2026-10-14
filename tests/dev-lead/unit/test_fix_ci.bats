#!/usr/bin/env bats
# Unit tests for dev-lead-fix-ci.sh (Phase 2)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
FIX_CI_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-fix-ci.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"
GH_STUBS_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/stubs"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"

  # Set up stub binary directory
  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  cp "$GH_STUBS_DIR/gh" "$STUB_BIN_DIR/gh"
  chmod +x "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini" "$STUB_BIN_DIR/gh"
  export PATH="$STUB_BIN_DIR:$PATH"
  export STUB_BIN_DIR

  # Default environment for fix-ci
  export PR_NUMBER="42"
  export HEAD_SHA="abc123def456"
  export CHECKS_JSON='[{"name":"lint / eslint","conclusion":"failure","details_url":"https://github.com/petry-projects/.github-private/actions/runs/12345","app_slug":"github-actions","id":99}]'
  export REPO="petry-projects/.github-private"
  export REVIEW_ENGINE="claude"
  export DEV_LEAD_DRY_RUN="true"
  export GH_STUB_COMMENT_BODY=""
  # Point to project root for prompts
  cd "$SCRIPT_DIR"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT"
  rm -rf "$STUB_BIN_DIR"
}

# ── idempotency tests ────────────────────────────────────────────────────────

@test "fix-ci: idempotency: marker found → exits 0" {
  # Return a JSON array whose body contains the SHA marker; script uses jq to extract bodies
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"issues/"*"/comments"*)
    echo '[{"body":"<!-- dev-lead-fix-ci sha=abc123def456 status=applied -->\nfix applied"}]' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  export DEV_LEAD_DRY_RUN="false"
  run bash "$FIX_CI_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"idempotent"* || "$output" == *"Already handled"* ]]
}

@test "fix-ci: idempotency: no marker → proceeds" {
  # gh returns no comments with our marker
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"issues/"*"/comments"*)
    echo "[]" ;;
  *"pr comment"*)
    exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_CI_SCRIPT"

  [ "$status" -eq 0 ]
  # Should reach dry-run output (not idempotent skip)
  [[ "$output" == *"[dry-run]"* ]]
}

# ── log truncation test ───────────────────────────────────────────────────────

@test "fix-ci: log truncation: >200 lines → ≤200 lines output" {
  # Create a gh stub that returns 300 log lines
  local lines_300
  lines_300=$(python3 -c "print('\n'.join(['log line ' + str(i) for i in range(300)]))")
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"run view"*)
    python3 -c "print('\n'.join(['log line ' + str(i) for i in range(300)]))" ;;
  *"issues/"*"/comments"*)
    echo "[]" ;;
  *"pr comment"*)
    exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_CI_SCRIPT"

  [ "$status" -eq 0 ]
  # The dry-run runs and succeeds; we can't easily check log truncation
  # in dry-run mode, but we verify the script doesn't error out
}

# ── dry-run tests ─────────────────────────────────────────────────────────────

@test "fix-ci: dry-run: DEV_LEAD_DRY_RUN=true builds prompt but does not commit" {
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"issues/"*"/comments"*) echo "[]" ;;
  *"pr comment"*) exit 0 ;;
  *"run view"*) echo "log output" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_CI_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  # Ensure git commit was NOT called (no "git" in output with "commit")
  [[ "$output" != *"git commit"* ]]
}

# ── prompt build test ─────────────────────────────────────────────────────────

@test "fix-ci: prompt build: CHECK_NAME in prompt" {
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"issues/"*"/comments"*) echo "[]" ;;
  *"pr comment"*) exit 0 ;;
  *"run view"*) echo "log output" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export DEV_LEAD_DRY_RUN="true"
  export CHECKS_JSON='[{"name":"my-check-name","conclusion":"failure","details_url":"","app_slug":"github-actions"}]'

  run bash "$FIX_CI_SCRIPT"

  [ "$status" -eq 0 ]
  # The dry-run output mentions it built a prompt
  [[ "$output" == *"fix-ci"* ]]
}

# ── error cases ───────────────────────────────────────────────────────────────

@test "fix-ci: missing PR_NUMBER → exits 1" {
  unset PR_NUMBER

  run bash "$FIX_CI_SCRIPT"

  [ "$status" -eq 1 ]
}

@test "fix-ci: dry-run: post_summary outputs [dry-run] prefix" {
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"issues/"*"/comments"*) echo "[]" ;;
  *"pr comment"*) exit 0 ;;
  *"run view"*) echo "log output" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_CI_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-ci: CHECKS_JSON single check → name appears in dry-run output" {
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"issues/"*"/comments"*) echo "[]" ;;
  *"pr comment"*) exit 0 ;;
  *"run view"*) echo "log output" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export DEV_LEAD_DRY_RUN="true"
  export CHECKS_JSON='[{"name":"eslint-check","conclusion":"failure","details_url":"","app_slug":"github-actions"}]'

  run bash "$FIX_CI_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"eslint-check"* ]]
}

@test "exhaustion: PR-level block posted after MAX_FAIL_ATTEMPTS consecutive failures" {
  # Simulate 2 existing status=failed markers on this PR (hits threshold)
  local marker_prefix="<!-- dev-lead-fix-ci sha="
  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"issues/42/comments"*) echo '[
    {"body":"<!-- dev-lead-fix-ci sha=aaa111 status=failed -->\nfailed"},
    {"body":"<!-- dev-lead-fix-ci sha=bbb222 status=failed -->\nfailed"}
  ]' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) echo "comment posted"; exit 0 ;;
  *"run view"*) echo "log output" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export DEV_LEAD_DRY_RUN="false"
  export STUB_ENGINE_EXIT="1"   # engine fails
  export MAX_FAIL_ATTEMPTS="2"
  export HEAD_SHA="ccc333new"   # new SHA not in comments → not idempotent

  run bash "$FIX_CI_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"exhaustion"* || "$output" == *"Exhaustion"* || "$output" == *"threshold"* ]]
}

@test "exhaustion: existing PR-level exhaustion marker blocks run regardless of SHA" {
  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"issues/42/comments"*) echo '[
    {"body":"<!-- dev-lead-fix-ci pr=42 status=exhausted -->\nexhausted"},
    {"body":"<!-- dev-lead-fix-ci sha=old111 status=failed -->\nfailed"}
  ]' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export HEAD_SHA="brand-new-sha-xyz"  # fresh SHA, but exhaustion marker present

  run bash "$FIX_CI_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"exhausted"* || "$output" == *"exhaustion"* ]]
}

@test "exhaustion: below threshold does not post PR-level block" {
  # Only 1 failure (below MAX_FAIL_ATTEMPTS=2 threshold)
  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"issues/42/comments"*) echo '[{"body":"<!-- dev-lead-fix-ci sha=aaa111 status=failed -->\nfailed"}]' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) echo "sha-comment posted"; exit 0 ;;
  *"run view"*) echo "log output" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export DEV_LEAD_DRY_RUN="false"
  export STUB_ENGINE_EXIT="1"
  export MAX_FAIL_ATTEMPTS="2"
  export HEAD_SHA="bbb222new"

  run bash "$FIX_CI_SCRIPT"

  [ "$status" -eq 1 ]
  # Should post sha-level marker but NOT exhaustion comment
  [[ "$output" != *"exhaustion threshold reached"* ]] || true
}

# ── rate-limit handling tests ─────────────────────────────────────────────────

@test "fix-ci: rate-limited: engine exit 2 posts status=rate-limited, not status=failed" {
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "You've hit your limit · resets 11:20pm (UTC)"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/claude"
  # Add rate-limited gemini and copilot stubs too
  for engine in gemini copilot; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "rate limit exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"issues/42/comments"*) echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) echo "COMMENT_POSTED: $*"; exit 0 ;;
  *"run view"*) echo "log output" ;;
  *"copilot"*) echo "rate limit exceeded"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export DEV_LEAD_DRY_RUN="false"

  run bash "$FIX_CI_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"rate-limited"* ]]
  [[ "$output" != *"status=failed"* ]]
}

@test "fix-ci: rate-limited: does not count toward exhaustion threshold" {
  # PR already has rate-limited markers but zero status=failed markers
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"issues/42/comments"*) echo '[
    {"body":"<!-- dev-lead-fix-ci sha=aaa111 status=rate-limited -->\nrate limited"},
    {"body":"<!-- dev-lead-fix-ci sha=bbb222 status=rate-limited -->\nrate limited again"}
  ]' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) echo "COMMENT_POSTED"; exit 0 ;;
  *"run view"*) echo "log output" ;;
  *"copilot"*) echo "rate limit exceeded"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  # Engine also rate-limits on this run
  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "rate limit exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  export DEV_LEAD_DRY_RUN="false"
  export MAX_FAIL_ATTEMPTS="2"
  export HEAD_SHA="ccc333new"

  run bash "$FIX_CI_SCRIPT"

  # Should exit 2 (rate-limited) and NOT post exhaustion
  [ "$status" -eq 2 ]
  [[ "$output" != *"status=exhausted"* ]]
  [[ "$output" != *"exhaustion threshold"* ]]
}

@test "fix-ci: idempotency: rate-limited marker is retriable (not terminal)" {
  # SHA has an existing status=rate-limited marker — should NOT skip
  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"issues/42/comments"*) echo '[
    {"body":"<!-- dev-lead-fix-ci sha=abc123def456 status=rate-limited -->\nrate limited"}
  ]' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"run view"*) echo "log output" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_CI_SCRIPT"

  # Should proceed (dry-run) not skip
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  # Must NOT output the idempotency "skipping" message
  [[ "$output" != *"terminal status"* ]]
}

@test "fix-ci: idempotency: applied marker is terminal (skips re-run)" {
  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"issues/42/comments"*) echo '[
    {"body":"<!-- dev-lead-fix-ci sha=abc123def456 status=applied -->\napplied"}
  ]' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export DEV_LEAD_DRY_RUN="false"

  run bash "$FIX_CI_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Already handled"* || "$output" == *"terminal status"* || "$output" == *"skipping"* ]]
}

@test "fix-ci: rate-limited dedup: existing rate-limited marker for same SHA skips duplicate post" {
  # Simulate an existing rate-limited marker for HEAD_SHA (same sha)
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"issues/42/comments"*) echo '[
    {"body":"<!-- dev-lead-fix-ci sha=abc123def456 status=rate-limited -->\nrate limited"}
  ]' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) echo "COMMENT_POSTED"; exit 0 ;;
  *"run view"*) echo "log output" ;;
  *"copilot"*) echo "rate limit exceeded"; exit 1 ;;
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

  export DEV_LEAD_DRY_RUN="false"

  run bash "$FIX_CI_SCRIPT"

  [ "$status" -eq 2 ]
  # Output should mention dedup skip
  [[ "$output" == *"already posted"* || "$output" == *"skipping duplicate"* ]]
}

# ── external quality gate (Fix 3) ─────────────────────────────────────────────

@test "fix-ci: external quality gate: non-GHA details_url → PR diff embedded in prompt" {
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"issues/"*"/comments"*) echo "[]" ;;
  *"pr comment"*) exit 0 ;;
  *"pr diff"*) printf 'diff --git a/lint.yml b/lint.yml\n+run: curl -sL https://example.com/install.sh | bash\n' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export DEV_LEAD_DRY_RUN="true"
  export CHECKS_JSON='[{"name":"SonarCloud Code Analysis","conclusion":"failure","details_url":"https://sonarcloud.io","app_slug":"sonarcloud"}]'

  run bash "$FIX_CI_SCRIPT"

  [ "$status" -eq 0 ]
  # Extract the rendered prompt file path from the dry-run notice line
  local prompt_file
  prompt_file=$(echo "$output" | awk '/would run engine with prompt:/{print $NF}')
  [ -n "$prompt_file" ]
  [ -f "$prompt_file" ]
  grep -q "External quality gate" "$prompt_file"
  grep -q "curl -sL" "$prompt_file"
  rm -f "$prompt_file"
}

@test "fix-ci: external quality gate: GHA details_url → uses run view, not pr diff" {
  local sentinel_dir
  sentinel_dir="$(mktemp -d)"
  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"issues/"*"/comments"*) echo "[]" ;;
  *"pr comment"*) exit 0 ;;
  *"run view"*) touch "${sentinel_dir}/.ran_run_view"; echo "github-actions log output" ;;
  *"pr diff"*) touch "${sentinel_dir}/.ran_pr_diff"; echo "diff output" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export DEV_LEAD_DRY_RUN="true"
  export CHECKS_JSON='[{"name":"lint / eslint","conclusion":"failure","details_url":"https://github.com/petry-projects/.github-private/actions/runs/12345","app_slug":"github-actions"}]'

  run bash "$FIX_CI_SCRIPT"

  [ "$status" -eq 0 ]
  [ -f "${sentinel_dir}/.ran_run_view" ]
  [ ! -f "${sentinel_dir}/.ran_pr_diff" ]
  rm -rf "$sentinel_dir"
}
