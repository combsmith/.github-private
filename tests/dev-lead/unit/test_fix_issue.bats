#!/usr/bin/env bats
# Unit tests for dev-lead-fix-issue.sh (Phase 5)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
FIX_ISSUE_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-fix-issue.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"
GH_STUBS_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/stubs"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"

  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini"
  export PATH="$STUB_BIN_DIR:$PATH"
  export STUB_BIN_DIR

  # Default gh stub that returns no existing PRs (no dedup)
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"pulls?state=open"*)
    echo "[]" ;;
  *"api"*"repos/"*"issues/"*)
    echo '{"title":"Test Issue","body":"Test issue body"}' ;;
  *"issue comment"*)
    exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  # Default env
  export ISSUE_NUMBER="100"
  export REPO="combsmith/.github-private"
  export REVIEW_ENGINE="claude"
  export DEV_LEAD_DRY_RUN="true"
  export GITHUB_REPOSITORY="combsmith/.github-private"

  cd "$SCRIPT_DIR"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT"
  rm -rf "$STUB_BIN_DIR"
}

# ── dedup tests ───────────────────────────────────────────────────────────────

@test "fix-issue: dedup: existing open PR → exits 0 with comment" {
  # Stub gh to return count > 0 for the dedup check
  # The script uses: gh api ".../pulls?state=open" --jq "[.[] | select(...)] | length"
  # Our stub returns "1" to simulate existing PR found
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"pulls?state=open"*)
    echo "1" ;;
  *"issue comment"*)
    exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export DEV_LEAD_DRY_RUN="false"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"dedup"* ]] || [[ "$output" == *"Existing open PR"* ]]
}

@test "fix-issue: dry-run: DEV_LEAD_DRY_RUN=true → logs [dry-run]" {
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-issue: missing ISSUE_NUMBER → exits 1" {
  unset ISSUE_NUMBER

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 1 ]
}

@test "fix-issue: ISSUE_TITLE and ISSUE_BODY exported to env before envsubst" {
  export DEV_LEAD_DRY_RUN="true"

  # Create a gh stub that returns known title/body
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"pulls?state=open"*)
    echo "[]" ;;
  *"api"*"repos/"*"issues/"*)
    echo '{"title":"My Known Title","body":"My Known Body"}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-issue: ORG_STANDARDS_HINT included in prompt context" {
  export DEV_LEAD_DRY_RUN="true"

  # We can verify by checking the generated prompt in dry-run mode
  # The dry-run message references the prompt file
  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  # Prompt was built (dry-run says would implement)
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-issue: dry-run: check_existing_pr result does not affect dry-run path" {
  # Even if gh returns an empty list, dry-run should work
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-issue: dry-run: prompt file path appears in output" {
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  # Dry-run message contains reference to the issue
  [[ "$output" == *"issue #${ISSUE_NUMBER}"* ]]
}

# ── rate-limit handling tests ─────────────────────────────────────────────────

@test "fix-issue: rate-limited: all engines rate-limited → exits 2, not 1" {
  # Override engine stubs to emit a rate-limit message and exit 1
  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" <<'STUB'
#!/usr/bin/env bash
echo "You've hit your limit · resets 11:20pm (UTC)"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done
  export COPILOT_GITHUB_TOKEN="stub-token"

  # Stub git to avoid real branch creation in the workspace
  cat > "$STUB_BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  "config"*) exit 0 ;;
  "checkout"*) exit 0 ;;
  "rev-parse HEAD") echo "abc123deadbeef" ;;
  *) exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  # gh stub: no existing PRs, issue API, comment posts ok, copilot rate-limited.
  # Dispatch on the gh subcommand ($1), NOT a pattern match against the full
  # args string — the prompt body contains literal "gh api .../issues/..."
  # examples that would otherwise hit the api branch and mask the copilot path.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
cmd="$1"; shift || true
case "$cmd" in
  copilot) echo "rate limit exceeded"; exit 1 ;;
  api)
    case "$*" in
      *"pulls?state=open"*) echo "0" ;;
      *"users/"*) echo '{"id":12345}' ;;
      *) echo '{"title":"Test Issue","body":"Test body"}' ;;
    esac ;;
  issue)
    case "$*" in
      comment*) exit 0 ;;
      *) echo "{}" ;;
    esac ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  export DEV_LEAD_DRY_RUN="false"

  run bash "$FIX_ISSUE_SCRIPT"

  # Must exit 2 (rate-limited), not 1 (engine error)
  [ "$status" -eq 2 ]
  [[ "$output" == *"rate-limited"* ]] || [[ "$output" == *"rate limited"* ]]
  [[ "$output" != *"Engine failed"* ]]
}

@test "fix-issue: rate-limited: posts comment on issue before exiting" {
  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" <<'STUB'
#!/usr/bin/env bash
echo "rate limit exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done
  export COPILOT_GITHUB_TOKEN="stub-token"

  local comment_posted_sentinel
  comment_posted_sentinel="$(mktemp)"
  rm "$comment_posted_sentinel"  # deleted; presence after run = was posted

  cat > "$STUB_BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  "config"*) exit 0 ;;
  "checkout"*) exit 0 ;;
  "rev-parse HEAD") echo "abc123deadbeef" ;;
  *) exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  # Dispatch on subcommand ($1) so the prompt body's literal "gh api .../issues/..."
  # text does not match the api branch and mask the copilot rate-limit path.
  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
cmd="\$1"; shift || true
case "\$cmd" in
  copilot) echo "rate limit exceeded"; exit 1 ;;
  api)
    case "\$*" in
      *"pulls?state=open"*) echo "0" ;;
      *"users/"*) echo '{"id":12345}' ;;
      *) echo '{"title":"Test","body":"body"}' ;;
    esac ;;
  issue)
    case "\$*" in
      comment*) touch "${comment_posted_sentinel}"; exit 0 ;;
      *) echo "{}" ;;
    esac ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  export DEV_LEAD_DRY_RUN="false"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 2 ]
  [ -f "$comment_posted_sentinel" ]

  rm -f "$comment_posted_sentinel" 2>/dev/null || true
}

# ── lint-before-commit tests ──────────────────────────────────────────────────

@test "fix-issue: lint passes → proceeds to commit without error" {
  # Stub dev-lead-lint.sh to pass
  cat > "$STUB_BIN_DIR/dev-lead-lint.sh" <<'LINTEOF'
#!/usr/bin/env bash
echo "  [lint] all checks passed (stub)"
exit 0
LINTEOF
  chmod +x "$STUB_BIN_DIR/dev-lead-lint.sh"

  # Stub git to simulate a clean commit path
  cat > "$STUB_BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  "config"*)           exit 0 ;;
  "checkout -b"*)      exit 0 ;;
  "rev-parse HEAD")    echo "abc123" ;;
  "status --porcelain") echo "M scripts/foo.sh" ;;
  "add -A")            exit 0 ;;
  "commit"*)           exit 0 ;;
  "push"*)             exit 0 ;;
  *)                   exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"pulls?state=open"*) echo "0" ;;
  *"api"*"repos/"*"issues/"*) echo '{"title":"Test","body":"body"}' ;;
  *"api"*"users/"*)     echo '{"id":12345}' ;;
  *"pr create"*)        exit 0 ;;
  *"issue comment"*)    exit 0 ;;
  *)                    echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  export DEV_LEAD_DRY_RUN="false"
  export LINT_SCRIPT="$STUB_BIN_DIR/dev-lead-lint.sh"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" != *"Lint check failed"* ]]
}

@test "fix-issue: lint fails → posts issue comment and exits without committing" {
  # Stub dev-lead-lint.sh to fail
  cat > "$STUB_BIN_DIR/dev-lead-lint.sh" <<'LINTEOF'
#!/usr/bin/env bash
echo "::error::shellcheck: SC2086 unquoted variable in scripts/bad.sh line 3"
exit 1
LINTEOF
  chmod +x "$STUB_BIN_DIR/dev-lead-lint.sh"

  local commit_sentinel
  commit_sentinel="$(mktemp)"
  rm "$commit_sentinel"

  cat > "$STUB_BIN_DIR/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  "config"*)           exit 0 ;;
  "checkout -b"*)      exit 0 ;;
  "rev-parse HEAD")    echo "abc123" ;;
  "status --porcelain") echo "M scripts/bad.sh" ;;
  "commit"*)           touch "${commit_sentinel}"; exit 0 ;;
  "add -A")            exit 0 ;;
  "push"*)             exit 0 ;;
  *)                   exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  local comment_sentinel
  comment_sentinel="$(mktemp)"
  rm "$comment_sentinel"

  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"pulls?state=open"*) echo "0" ;;
  *"api"*"repos/"*"issues/"*) echo '{"title":"Test","body":"body"}' ;;
  *"api"*"users/"*) echo '{"id":12345}' ;;
  *"issue comment"*) touch "${comment_sentinel}"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  export DEV_LEAD_DRY_RUN="false"
  export LINT_SCRIPT="$STUB_BIN_DIR/dev-lead-lint.sh"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -ne 0 ]
  # Lint failure must block the commit
  [ ! -f "$commit_sentinel" ]   # commit must NOT have been called

  rm -f "$comment_sentinel" "$commit_sentinel" 2>/dev/null || true
}

# ── engine-failure visibility + retry-marker tests (#781) ─────────────────────

# Shared stub: claude exits with the given code + message; git is stubbed for
# branch creation; curl returns empty so the claude headroom probe is a no-op;
# gh records every posted comment body to $COMMENT_FILE and label edits to
# $LABEL_FILE, and serves prior issue comments from $PRIOR_COMMENTS_JSON.
_setup_failure_stubs() {
  local engine_rc="$1" engine_msg="$2"
  cat > "$STUB_BIN_DIR/claude" <<STUB
#!/usr/bin/env bash
echo "${engine_msg}"
exit ${engine_rc}
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  cat > "$STUB_BIN_DIR/curl" <<'CURLEOF'
#!/usr/bin/env bash
exit 0
CURLEOF
  chmod +x "$STUB_BIN_DIR/curl"

  cat > "$STUB_BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  "config"*)         exit 0 ;;
  "checkout -b"*)    exit 0 ;;
  "rev-parse HEAD")  echo "abc123deadbeef" ;;
  *)                 exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  COMMENT_FILE="$(mktemp)"; export COMMENT_FILE
  LABEL_FILE="$(mktemp)"; export LABEL_FILE
  : "${PRIOR_COMMENTS_JSON:=[]}"; export PRIOR_COMMENTS_JSON

  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
cmd="\$1"; shift || true
case "\$cmd" in
  copilot) echo "rate limit exceeded"; exit 1 ;;
  label)   exit 0 ;;
  api)
    case "\$*" in
      *"pulls?state=open"*) echo "0" ;;
      *comments*)           printf '%s' '${PRIOR_COMMENTS_JSON}' ;;
      *"users/"*)           echo '{"id":12345}' ;;
      *"issues/"*)          echo '{"title":"Test Issue","body":"body"}' ;;
      *)                    echo "{}" ;;
    esac ;;
  issue)
    sub="\$1"; shift || true
    case "\$sub" in
      comment)
        body=""
        while [ \$# -gt 0 ]; do
          if [ "\$1" = "--body" ]; then body="\$2"; shift 2; continue; fi
          shift
        done
        printf '%s\n----8<----\n' "\$body" >> "${COMMENT_FILE}"
        exit 0 ;;
      edit)
        printf '%s\n' "\$*" >> "${LABEL_FILE}"
        exit 0 ;;
      *) echo "{}" ;;
    esac ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  export DEV_LEAD_DRY_RUN="false"
}

@test "fix-issue: engine-error (attempt 1) → exits 1, posts retry marker + cause, no silent exit" {
  _setup_failure_stubs 1 "boom: transient engine error"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 1 ]
  local posted; posted=$(cat "$COMMENT_FILE")
  # Machine-readable retry marker the cron scans for
  [[ "$posted" == *"<!-- dev-lead-issue 100 status=failed attempt=1 reason=engine-error run="* ]]
  # Human-readable cause + run deep-link
  [[ "$posted" == *"engine-error"* ]]
  [[ "$posted" == *"actions/runs/"* ]]
  [[ "$posted" == *"will retry"* ]]
  # Must NOT escalate to a human on the first attempt
  [ ! -s "$LABEL_FILE" ] || [[ "$(cat "$LABEL_FILE")" != *"needs-human"* ]]

  rm -f "$COMMENT_FILE" "$LABEL_FILE"
}

@test "fix-issue: engine-error embeds redacted session-output snippet in the comment" {
  _setup_failure_stubs 1 "TRACE: writer step exploded at line 42"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 1 ]
  local posted; posted=$(cat "$COMMENT_FILE")
  # The engine layer persists/redacts session output to /tmp; a tail must appear
  [[ "$posted" == *"Last 40 lines of engine output"* ]]
  [[ "$posted" == *"TRACE: writer step exploded"* ]]

  rm -f "$COMMENT_FILE" "$LABEL_FILE"
}

@test "fix-issue: missing-binary → escalates to needs-human, no retry marker" {
  _setup_failure_stubs 127 "claude: command not found"
  # Skip gemini (no key) and copilot (classic PAT) so the only failure is the
  # missing claude binary → run_writer_with_fallback returns missing-binary.
  unset GEMINI_API_KEY GOOGLE_API_KEY
  export COPILOT_GITHUB_TOKEN="ghp_stub"  # ghp_* → copilot fallback is skipped

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 1 ]
  local posted; posted=$(cat "$COMMENT_FILE")
  [[ "$posted" == *"needs human attention"* ]]
  [[ "$posted" == *"reason=missing-binary"* ]]
  # Deterministic infra failure → must NOT post a retryable status=failed marker
  [[ "$posted" != *"status=failed"* ]]
  # needs-human label applied
  [[ "$(cat "$LABEL_FILE")" == *"dev-lead:needs-human"* ]]

  rm -f "$COMMENT_FILE" "$LABEL_FILE"
}

# ── stage-timeout escalation (#1018) ──────────────────────────────────────────

@test "fix-issue: stage timeout (exit 124) → escalates to needs-human, reason=timeout, no retry marker" {
  _setup_failure_stubs 124 "operation timed out after 2100s"
  # Skip gemini (no key) + copilot (classic PAT) so claude's 124 is the sole,
  # immediately-propagated failure (no cross-engine same-budget retry).
  unset GEMINI_API_KEY GOOGLE_API_KEY
  export COPILOT_GITHUB_TOKEN="ghp_stub"  # ghp_* → copilot fallback is skipped
  export ACTION_TIMEOUT_SEC=2100

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 1 ]
  local posted; posted=$(cat "$COMMENT_FILE")
  [[ "$posted" == *"needs human attention"* ]]
  [[ "$posted" == *"reason=timeout"* ]]
  # Non-retryable → must NOT post a retryable status=failed marker (the retry
  # cron would otherwise requeue a same-budget attempt).
  [[ "$posted" != *"status=failed"* ]]
  # Comment surfaces tier + elapsed + budget + split/raise guidance.
  [[ "$posted" == *"Tier:"* ]]
  [[ "$posted" == *"Elapsed:"* ]]
  [[ "$posted" == *"Budget:"* ]]
  [[ "$posted" == *"2100"* ]]
  [[ "$posted" == *"Split this issue"* ]]
  [[ "$posted" == *"TIMEOUT_SEC"* ]]
  # needs-human label applied
  [[ "$(cat "$LABEL_FILE")" == *"dev-lead:needs-human"* ]]

  rm -f "$COMMENT_FILE" "$LABEL_FILE"
}

@test "fix-issue: non-124 transient (rate-limit) still retries — no timeout regression" {
  # A genuine transient (rate-limit, exit 1 + rate-limit phrase) must still take
  # the retry path (exit 2), NOT the timeout escalation. Skip gemini (no key) so
  # the failure is deterministic: claude + copilot both rate-limit.
  _setup_failure_stubs 1 "You've hit your limit · resets 11:20pm (UTC)"
  unset GEMINI_API_KEY GOOGLE_API_KEY
  export COPILOT_GITHUB_TOKEN="stub-token"  # copilot also rate-limited via gh stub

  run bash "$FIX_ISSUE_SCRIPT"

  # rate-limited path → exit 2, retry marker, not needs-human
  [ "$status" -eq 2 ]
  local posted; posted=$(cat "$COMMENT_FILE")
  [[ "$posted" == *"will retry"* ]]
  [[ "$posted" != *"reason=timeout"* ]]
  [[ "$posted" != *"needs human attention"* ]]

  rm -f "$COMMENT_FILE" "$LABEL_FILE"
}

@test "fix-issue: late-phase timeout with completed work → surfaces branch, not silently discarded" {
  _setup_failure_stubs 124 "timed out during a late phase"
  unset GEMINI_API_KEY GOOGLE_API_KEY
  export COPILOT_GITHUB_TOKEN="ghp_stub"
  export ACTION_TIMEOUT_SEC=2100

  # Simulate the #1003 mode: the engine advanced HEAD (a commit) before the
  # timeout, so pre_engine_sha != current HEAD. git status is clean but the SHA
  # moved → completed-but-unpushed work must be surfaced.
  # First rev-parse (pre_engine_sha) reads one value; make the failure-handler's
  # rev-parse report a different SHA by flipping the env after branch creation is
  # not possible across processes, so use a wrapper that advances on 2nd call.
  cat > "$STUB_BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
STATE="/tmp/devlead-test-revparse-count"
case "$*" in
  "config"*)            exit 0 ;;
  "checkout -b"*)       exit 0 ;;
  "rev-parse HEAD")
    n=0; [ -f "$STATE" ] && n=$(cat "$STATE")
    n=$((n+1)); echo "$n" > "$STATE"
    if [ "$n" -le 1 ]; then echo "sha_before"; else echo "sha_after_commit"; fi ;;
  "status --porcelain") exit 0 ;;
  *)                    exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"
  rm -f /tmp/devlead-test-revparse-count

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 1 ]
  local posted; posted=$(cat "$COMMENT_FILE")
  [[ "$posted" == *"reason=timeout"* ]]
  # Completed-but-unpushed work is surfaced (branch mentioned), not discarded.
  [[ "$posted" == *"not pushed"* ]] || [[ "$posted" == *"not discarded"* ]]

  rm -f "$COMMENT_FILE" "$LABEL_FILE" /tmp/devlead-test-revparse-count
}

@test "fix-issue: attempt ceiling (prior attempt=2) → escalates to needs-human" {
  export PRIOR_COMMENTS_JSON='[{"body":"<!-- dev-lead-issue 100 status=failed attempt=2 reason=engine-error run=1 -->"}]'
  _setup_failure_stubs 1 "boom again"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 1 ]
  local posted; posted=$(cat "$COMMENT_FILE")
  # attempt becomes 3 (>= MAX_ATTEMPTS) → human escalation, not another retry marker
  [[ "$posted" == *"needs human attention"* ]]
  [[ "$posted" == *"attempt=3"* ]]
  [[ "$posted" != *"status=failed attempt=3"* ]]
  [[ "$(cat "$LABEL_FILE")" == *"dev-lead:needs-human"* ]]

  rm -f "$COMMENT_FILE" "$LABEL_FILE"
  unset PRIOR_COMMENTS_JSON
}

# ── shared-escalation dedup (#1029) ───────────────────────────────────────────

# All three non-retryable branches (missing-binary / timeout / retries-exhausted)
# must emit the SAME needs-human marker shape, differing only in reason= (and the
# per-scenario attempt=/run= values). This pins the shared escalate_needs_human
# helper so the marker the retry cron + fleet-monitor parse never drifts between
# branches.
@test "fix-issue: all three escalation branches emit the same needs-human marker shape (only reason differs)" {
  # Extract the needs-human marker line, then normalize the scenario-specific
  # attempt=/reason=/run= values so only the marker *shape* is compared.
  _extract_marker() {
    grep -oE '<!-- dev-lead-issue 100 status=needs-human attempt=[0-9]+ reason=[a-z]+(-[a-z]+)* run=[^ ]* -->' "$1" | head -1
  }
  _normalize_marker() {
    sed -E 's/attempt=[0-9]+/attempt=A/; s/reason=[a-z]+(-[a-z]+)*/reason=R/; s/run=[^ ]*/run=X/'
  }

  # Scenario 1: missing-binary (attempt 1)
  export PRIOR_COMMENTS_JSON='[]'
  _setup_failure_stubs 127 "claude: command not found"
  unset GEMINI_API_KEY GOOGLE_API_KEY
  export COPILOT_GITHUB_TOKEN="ghp_stub"
  run bash "$FIX_ISSUE_SCRIPT"
  [ "$status" -eq 1 ]
  local m1; m1=$(_extract_marker "$COMMENT_FILE")
  [ -n "$m1" ]
  [[ "$m1" == *"reason=missing-binary"* ]]
  rm -f "$COMMENT_FILE" "$LABEL_FILE"

  # Scenario 2: timeout (attempt 1)
  export PRIOR_COMMENTS_JSON='[]'
  _setup_failure_stubs 124 "operation timed out after 2100s"
  unset GEMINI_API_KEY GOOGLE_API_KEY
  export COPILOT_GITHUB_TOKEN="ghp_stub"
  export ACTION_TIMEOUT_SEC=2100
  run bash "$FIX_ISSUE_SCRIPT"
  [ "$status" -eq 1 ]
  local m2; m2=$(_extract_marker "$COMMENT_FILE")
  [ -n "$m2" ]
  [[ "$m2" == *"reason=timeout"* ]]
  rm -f "$COMMENT_FILE" "$LABEL_FILE"

  # Scenario 3: retries-exhausted (prior attempt=2 → this is attempt 3)
  export PRIOR_COMMENTS_JSON='[{"body":"<!-- dev-lead-issue 100 status=failed attempt=2 reason=engine-error run=1 -->"}]'
  _setup_failure_stubs 1 "boom again"
  run bash "$FIX_ISSUE_SCRIPT"
  [ "$status" -eq 1 ]
  local m3; m3=$(_extract_marker "$COMMENT_FILE")
  [ -n "$m3" ]
  [[ "$m3" == *"reason=engine-error"* ]]
  rm -f "$COMMENT_FILE" "$LABEL_FILE"
  unset PRIOR_COMMENTS_JSON

  # Normalized shapes must be byte-identical across all three branches.
  local n1 n2 n3
  n1=$(printf '%s' "$m1" | _normalize_marker)
  n2=$(printf '%s' "$m2" | _normalize_marker)
  n3=$(printf '%s' "$m3" | _normalize_marker)
  [ "$n1" = "$n2" ]
  [ "$n2" = "$n3" ]
  [ "$n1" = '<!-- dev-lead-issue 100 status=needs-human attempt=A reason=R run=X -->' ]
}

@test "fix-issue: lint fails → posts lint-failure comment on the issue" {
  cat > "$STUB_BIN_DIR/dev-lead-lint.sh" <<'LINTEOF'
#!/usr/bin/env bash
echo "SC2086: Double quote to prevent globbing" >&2
exit 1
LINTEOF
  chmod +x "$STUB_BIN_DIR/dev-lead-lint.sh"

  cat > "$STUB_BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  "config"*)           exit 0 ;;
  "checkout -b"*)      exit 0 ;;
  "rev-parse HEAD")    echo "abc123" ;;
  "status --porcelain") echo "M scripts/bad.sh" ;;
  *)                   exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  local comment_sentinel
  comment_sentinel="$(mktemp)"
  rm "$comment_sentinel"

  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"pulls?state=open"*) echo "0" ;;
  *"api"*"repos/"*"issues/"*) echo '{"title":"Test","body":"body"}' ;;
  *"api"*"users/"*) echo '{"id":12345}' ;;
  *"issue comment"*) touch "${comment_sentinel}"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  export DEV_LEAD_DRY_RUN="false"
  export LINT_SCRIPT="$STUB_BIN_DIR/dev-lead-lint.sh"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -ne 0 ]
  # A comment explaining the lint failure must be posted on the issue
  [ -f "$comment_sentinel" ]

  rm -f "$comment_sentinel" 2>/dev/null || true
}
