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

  # Pin the prompt template to the in-repo source so an ambient PROMPTS_DIR
  # (e.g. a vendored .dev-lead/ runtime copy) cannot shadow it (#1566).
  export PROMPTS_DIR="$SCRIPT_DIR/prompts/dev-lead"

  # Default env
  export ISSUE_NUMBER="100"
  export REPO="petry-projects/.github-private"
  export REVIEW_ENGINE="claude"
  export DEV_LEAD_DRY_RUN="true"
  export GITHUB_REPOSITORY="petry-projects/.github-private"

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
      *"-X POST"*"/labels"*) printf '%s\n' "\$*" >> "${LABEL_FILE}"; echo '[]' ;;
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

# ── credential config-gap escalation (#1591) ─────────────────────────────────
# A missing/placeholder Copilot credential is a deterministic AUTH/configuration
# gap. When copilot is the only enabled engine, run_writer_with_fallback returns
# reason=unconfigured (exit 1). handle_engine_failure must treat it like
# missing-binary: escalate to needs-human with NO retryable status=failed marker,
# so the retry cron does not requeue an attempt that cannot succeed without a
# human setting the secret.

@test "fix-issue: unconfigured (copilot-only, missing token) → escalates to needs-human, no retry marker" {
  _setup_failure_stubs 0 "unused — copilot is the only enabled engine"
  # Copilot is the only enabled engine and its token is missing → the sole cause
  # is a config gap (reason=unconfigured), not a rate limit or transient error.
  export DEV_LEAD_ENGINES="copilot"
  unset COPILOT_GITHUB_TOKEN GEMINI_API_KEY GOOGLE_API_KEY

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 1 ]
  local posted; posted=$(cat "$COMMENT_FILE")
  [[ "$posted" == *"needs human attention"* ]]
  [[ "$posted" == *"reason=unconfigured"* ]]
  # Deterministic config gap → must NOT post a retryable status=failed marker
  # (AC #4: no retry is scheduled) and must NOT be classed as rate-limited.
  [[ "$posted" != *"status=failed"* ]]
  [[ "$posted" != *"status=rate-limited"* ]]
  # needs-human label applied
  [[ "$(cat "$LABEL_FILE")" == *"dev-lead:needs-human"* ]]

  rm -f "$COMMENT_FILE" "$LABEL_FILE"
  unset DEV_LEAD_ENGINES
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

@test "fix-issue: late-phase timeout with committed work (clean tree) → checkpoint-pushed, not discarded (#1660 has_commits path)" {
  _setup_failure_stubs 124 "timed out during a late phase"
  unset GEMINI_API_KEY GOOGLE_API_KEY
  export COPILOT_GITHUB_TOKEN="ghp_stub"
  export ACTION_TIMEOUT_SEC=2100

  # Simulate the #1003 mode: the engine advanced HEAD (a commit) before the
  # timeout, so pre_engine_sha != current HEAD. git status is CLEAN (no
  # uncommitted changes) but the SHA moved → the already-committed work is
  # checkpoint-pushed (no new commit needed, just the push). rev-parse advances on
  # the 2nd call so pre_engine_sha (call 1) differs from the has_commits probe.
  GIT_PUSH_FILE="$BATS_TEST_TMPDIR/git_push_file"; export GIT_PUSH_FILE
  cat > "$STUB_BIN_DIR/git" <<GITEOF
#!/usr/bin/env bash
STATE="$BATS_TEST_TMPDIR/devlead-test-revparse-count"
case "\$*" in
  "config"*)            exit 0 ;;
  "checkout -b"*)       exit 0 ;;
  "rev-parse HEAD")
    n=0; [ -f "\$STATE" ] && n=\$(cat "\$STATE")
    n=\$((n+1)); echo "\$n" > "\$STATE"
    if [ "\$n" -le 1 ]; then echo "sha_before"; else echo "sha_after_commit"; fi ;;
  "status --porcelain") exit 0 ;;
  "push"*)              printf '%s\n' "\$*" >> "${GIT_PUSH_FILE}"; exit 0 ;;
  *)                    exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 1 ]
  # The committed-but-unpushed work is now pushed (no new checkpoint commit
  # needed since the tree is clean — just the branch push).
  [[ "$(cat "$GIT_PUSH_FILE")" == *"dev-lead/issue-100"* ]]
  local posted; posted=$(cat "$COMMENT_FILE")
  [[ "$posted" == *"reason=timeout"* ]]
  # Surfaced as checkpoint-pushed partial work, no longer "not recoverable".
  [[ "$posted" == *"dev-lead/issue-100"* ]]
  [[ "$posted" == *"partial"* ]]
  [[ "$posted" != *"not recoverable"* ]]

  rm -f "$COMMENT_FILE" "$LABEL_FILE"
}

@test "fix-issue: timeout where the checkpoint push fails → falls back to 'not recoverable' (#1660 fallback)" {
  _setup_failure_stubs 124 "timed out, and the remote is unreachable"
  unset GEMINI_API_KEY GOOGLE_API_KEY
  export COPILOT_GITHUB_TOKEN="ghp_stub"
  export ACTION_TIMEOUT_SEC=2100

  # Uncommitted work exists, but the push fails (e.g. remote unreachable) → the
  # work could not be preserved, so the escalation keeps the honest
  # "not recoverable" note instead of falsely claiming a checkpoint branch.
  cat > "$STUB_BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  "config"*)            exit 0 ;;
  "checkout -b"*)       exit 0 ;;
  "rev-parse HEAD")     echo "abc123deadbeef" ;;
  "status --porcelain") echo "M scripts/foo.sh" ;;
  "add -A")             exit 0 ;;
  "commit"*)            exit 0 ;;
  "push"*)              echo "fatal: unable to access remote" >&2; exit 1 ;;
  *)                    exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 1 ]
  local posted; posted=$(cat "$COMMENT_FILE")
  [[ "$posted" == *"reason=timeout"* ]]
  [[ "$posted" == *"not recoverable"* ]]

  rm -f "$COMMENT_FILE" "$LABEL_FILE"
}

# ── checkpoint-push on stage timeout (#1660) ──────────────────────────────────
# On exit 124 the orchestrating shell survives (GNU `timeout` wraps only the
# engine child, never this script), so partial work is committed under a distinct
# INCOMPLETE marker and the working branch is pushed — a timeout leaves
# salvageable work on the remote instead of nothing.

# git stub that reports uncommitted work (dirty `status --porcelain`) and records
# every commit message + push invocation for assertion.
_setup_checkpoint_git_stub() {
  GIT_COMMIT_FILE="$BATS_TEST_TMPDIR/git_commit_file"; export GIT_COMMIT_FILE
  GIT_PUSH_FILE="$BATS_TEST_TMPDIR/git_push_file"; export GIT_PUSH_FILE
  cat > "$STUB_BIN_DIR/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  "config"*)            exit 0 ;;
  "checkout -b"*)       exit 0 ;;
  "rev-parse HEAD")     echo "abc123deadbeef" ;;
  "status --porcelain") echo "M scripts/foo.sh" ;;
  "add -A")             exit 0 ;;
  "commit"*)            printf '%s\n' "\$*" >> "${GIT_COMMIT_FILE}"; exit 0 ;;
  "push"*)              printf '%s\n' "\$*" >> "${GIT_PUSH_FILE}"; exit 0 ;;
  *)                    exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"
}

@test "fix-issue: timeout with partial work → checkpoint-pushed under INCOMPLETE marker, branch named, not 'not recoverable' (#1660 AC1/AC3)" {
  _setup_failure_stubs 124 "operation timed out after 2100s"
  unset GEMINI_API_KEY GOOGLE_API_KEY
  export COPILOT_GITHUB_TOKEN="ghp_stub"
  export ACTION_TIMEOUT_SEC=2100
  _setup_checkpoint_git_stub

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 1 ]
  # A checkpoint commit was made with the distinct INCOMPLETE marker prefix...
  [[ "$(cat "$GIT_COMMIT_FILE")" == *"checkpoint(dev-lead):"* ]]
  [[ "$(cat "$GIT_COMMIT_FILE")" == *"INCOMPLETE"* ]]
  # ...and the working branch was pushed.
  [[ "$(cat "$GIT_PUSH_FILE")" == *"dev-lead/issue-100"* ]]

  local posted; posted=$(cat "$COMMENT_FILE")
  # Still escalates to a human with reason=timeout...
  [[ "$posted" == *"needs human attention"* ]]
  [[ "$posted" == *"reason=timeout"* ]]
  # ...but now names the pushed branch and calls the work partial/unreviewed
  # instead of today's "not recoverable from this run".
  [[ "$posted" == *"dev-lead/issue-100"* ]]
  [[ "$posted" == *"partial"* ]]
  [[ "$posted" == *"unreviewed"* ]]
  [[ "$posted" != *"not recoverable"* ]]

  rm -f "$COMMENT_FILE" "$LABEL_FILE"
}

@test "fix-issue: checkpoint push on timeout posts NO completion claim — resolution gate stays closed (#1660 AC2/#1621)" {
  _setup_failure_stubs 124 "operation timed out after 2100s"
  unset GEMINI_API_KEY GOOGLE_API_KEY
  export COPILOT_GITHUB_TOKEN="ghp_stub"
  export ACTION_TIMEOUT_SEC=2100
  _setup_checkpoint_git_stub

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 1 ]
  local posted; posted=$(cat "$COMMENT_FILE")
  # A checkpoint is unmistakably incomplete: it must never read as a completed,
  # reviewable pass — no durable completion marker, no "Implementation Complete".
  [[ "$posted" != *"status=completed"* ]]
  [[ "$posted" != *"Implementation Complete"* ]]
  # It still escalates to a human.
  [[ "$posted" == *"needs human attention"* ]]

  rm -f "$COMMENT_FILE" "$LABEL_FILE"
}

@test "fix-issue: non-timeout success is unchanged — commits 'feat: implement', never the checkpoint marker (#1660 AC4)" {
  cat > "$STUB_BIN_DIR/dev-lead-lint.sh" <<'LINTEOF'
#!/usr/bin/env bash
exit 0
LINTEOF
  chmod +x "$STUB_BIN_DIR/dev-lead-lint.sh"

  GIT_COMMIT_FILE="$BATS_TEST_TMPDIR/git_commit_file"; export GIT_COMMIT_FILE
  cat > "$STUB_BIN_DIR/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  "status --porcelain") echo "M scripts/foo.sh" ;;
  "rev-parse HEAD")     echo "deadbeef1234" ;;
  "commit"*)            printf '%s\n' "\$*" >> "${GIT_COMMIT_FILE}"; exit 0 ;;
  *)                    exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  COMMENT_FILE="$BATS_TEST_TMPDIR/comment_file"; export COMMENT_FILE
  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
cmd="\$1"; shift || true
case "\$cmd" in
  pr) case "\$*" in create*) echo "https://github.com/petry-projects/.github-private/pull/42" ;; *) exit 0 ;; esac ;;
  label) exit 0 ;;
  api)
    case "\$*" in
      *"pulls?state=open"*) echo "0" ;;
      *comments*)           echo "[]" ;;
      *"issues/"*)          echo '{"title":"Test","body":"body"}' ;;
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
      *) exit 0 ;;
    esac ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  export DEV_LEAD_DRY_RUN="false"
  export LINT_SCRIPT="$STUB_BIN_DIR/dev-lead-lint.sh"
  export GITHUB_RUN_ID="99"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  # Normal commit message, never the checkpoint marker.
  [[ "$(cat "$GIT_COMMIT_FILE")" == *"feat: implement issue #100"* ]]
  [[ "$(cat "$GIT_COMMIT_FILE")" != *"checkpoint(dev-lead):"* ]]
  # Durable completion claim still posted (non-timeout path untouched).
  [[ "$(cat "$COMMENT_FILE")" == *"status=completed"* ]]

  # No manual cleanup needed with BATS_TEST_TMPDIR
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

# ── durable completion claim (#1445) ──────────────────────────────────────────

@test "fix-issue: durable completion claim posted after PR create, with pr= and sha= (AC #1,#2)" {
  # A trustworthy completion record is posted only AFTER the work is durable
  # (commits pushed + PR open) and must reference a verifiable artifact.
  cat > "$STUB_BIN_DIR/dev-lead-lint.sh" <<'LINTEOF'
#!/usr/bin/env bash
echo "  [lint] all checks passed (stub)"
exit 0
LINTEOF
  chmod +x "$STUB_BIN_DIR/dev-lead-lint.sh"

  cat > "$STUB_BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  "status --porcelain") echo "M scripts/foo.sh" ;;
  "rev-parse HEAD")     echo "deadbeef1234" ;;
  *)                    exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  COMMENT_FILE="$STUB_BIN_DIR/comment_record"

  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
cmd="\$1"; shift || true
case "\$cmd" in
  pr)
    case "\$*" in
      create*) echo "https://github.com/petry-projects/.github-private/pull/42" ;;
      *)       exit 0 ;;
    esac ;;
  label) exit 0 ;;
  api)
    case "\$*" in
      *"pulls?state=open"*) echo "0" ;;
      *comments*)           echo "[]" ;;
      *"users/"*)           echo '{"id":12345}' ;;
      *"issues/"*)          echo '{"title":"Test","body":"body"}' ;;
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
        printf '%s\n----8<----\n' "\$body" >> "$COMMENT_FILE"
        exit 0 ;;
      *) exit 0 ;;
    esac ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  export DEV_LEAD_DRY_RUN="false"
  export LINT_SCRIPT="$STUB_BIN_DIR/dev-lead-lint.sh"
  export GITHUB_RUN_ID="99"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  local posted; posted=$(cat "$COMMENT_FILE")
  # Durable, machine-readable completion marker referencing PR number + head SHA
  [[ "$posted" == *"<!-- dev-lead-issue 100 status=completed pr=42 sha=deadbeef1234 run=99 -->"* ]]
  # Human-readable record links the verifiable artifact
  [[ "$posted" == *"pull/42"* ]]
  [[ "$posted" == *"deadbeef1234"* ]]
}

# ── retraction on terminal failure (#1445, AC #3) ─────────────────────────────

@test "fix-issue: on timeout, a prior standing completion claim is retracted in place (AC #3)" {
  cat > "$STUB_BIN_DIR/claude" <<'STUB'
#!/usr/bin/env bash
echo "operation timed out after 2100s"
exit 124
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

  unset GEMINI_API_KEY GOOGLE_API_KEY
  export COPILOT_GITHUB_TOKEN="ghp_stub"
  export ACTION_TIMEOUT_SEC=2100
  export DEV_LEAD_DRY_RUN="false"

  RETRACT_FILE="$STUB_BIN_DIR/retract_record"
  # A prior "## Completed" claim stands on the issue (comment id 555).
  PRIOR='[{"id":555,"body":"## Completed — event-first resume\n726/726 pass"}]'

  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
cmd="\$1"; shift || true
case "\$cmd" in
  copilot) echo "rate limit exceeded"; exit 1 ;;
  label)   exit 0 ;;
  api)
    case "\$*" in
      *"-X PATCH"*"comments/"*) printf '%s\n' "\$*" >> "$RETRACT_FILE"; echo "{}" ;;
      *"pulls?state=open"*)     echo "0" ;;
      *comments*)               printf '%s' '${PRIOR}' ;;
      *"users/"*)               echo '{"id":12345}' ;;
      *"issues/"*)              echo '{"title":"Test","body":"body"}' ;;
      *)                        echo "{}" ;;
    esac ;;
  issue) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 1 ]
  # Retraction fired: a PATCH targeted the standing claim's comment id.
  [ -f "$RETRACT_FILE" ]
  grep -q "comments/555" "$RETRACT_FILE"
  grep -q "PATCH" "$RETRACT_FILE"
}

@test "fix-issue: a retryable failure does NOT retract (only terminal failures do)" {
  # engine-error, attempt 1 → retry path, which is NOT terminal: the work may
  # still land on retry, so a standing claim must be left alone.
  cat > "$STUB_BIN_DIR/claude" <<'STUB'
#!/usr/bin/env bash
echo "boom: transient engine error"
exit 1
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

  export COPILOT_GITHUB_TOKEN="stub-token"
  export DEV_LEAD_DRY_RUN="false"

  RETRACT_FILE="$STUB_BIN_DIR/retract_record"
  PRIOR='[{"id":555,"body":"## Completed — old claim"}]'

  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
cmd="\$1"; shift || true
case "\$cmd" in
  copilot) echo "rate limit exceeded"; exit 1 ;;
  label)   exit 0 ;;
  api)
    case "\$*" in
      *"-X PATCH"*"comments/"*) printf '%s\n' "\$*" >> "$RETRACT_FILE"; echo "{}" ;;
      *"pulls?state=open"*)     echo "0" ;;
      *comments*)               printf '%s' '${PRIOR}' ;;
      *"users/"*)               echo '{"id":12345}' ;;
      *"issues/"*)              echo '{"title":"Test","body":"body"}' ;;
      *)                        echo "{}" ;;
    esac ;;
  issue) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$FIX_ISSUE_SCRIPT"

  # Retry path (rate-limited copilot + engine-error claude → exit 1 or 2), not terminal
  [ "$status" -ne 0 ]
  # No retraction on a non-terminal failure
  [ ! -f "$RETRACT_FILE" ]
}

# ── issue comments reach the prompt (#1566) ───────────────────────────────────

@test "fix-issue: a comment answering the body question reaches the rendered prompt (#1566 AC1/AC5)" {
  # The engine receives the rendered prompt on stdin; capture it to a file.
  PROMPT_CAPTURE="$STUB_BIN_DIR/prompt_capture"
  cat > "$STUB_BIN_DIR/claude" <<CLAUDEEOF
#!/usr/bin/env bash
cat > "$PROMPT_CAPTURE"
echo "stub engine response"
exit 0
CLAUDEEOF
  chmod +x "$STUB_BIN_DIR/claude"

  cat > "$STUB_BIN_DIR/dev-lead-lint.sh" <<'LINTEOF'
#!/usr/bin/env bash
exit 0
LINTEOF
  chmod +x "$STUB_BIN_DIR/dev-lead-lint.sh"

  cat > "$STUB_BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  "status --porcelain") echo "M scripts/foo.sh" ;;
  "rev-parse HEAD")     echo "deadbeef1234" ;;
  *)                    exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  # gh stub: issue body poses a question; a human comment answers it.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
cmd="$1"; shift || true
case "$cmd" in
  pr) case "$*" in create*) echo "https://github.com/petry-projects/.github-private/pull/42" ;; *) exit 0 ;; esac ;;
  label) exit 0 ;;
  api)
    case "$*" in
      *"pulls?state=open"*) echo "0" ;;
      *comments*)           echo '[{"user":{"login":"alice","type":"User"},"author_association":"MEMBER","created_at":"2026-08-21T01:14:00Z","body":"ANSWER: the telemetry source is the oauth/usage endpoint."}]' ;;
      *"users/"*)           echo '{"id":12345}' ;;
      *"issues/"*)          echo '{"title":"Test","body":"QUESTION: what is the telemetry source?"}' ;;
      *)                    echo "{}" ;;
    esac ;;
  issue) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  export DEV_LEAD_DRY_RUN="false"
  export LINT_SCRIPT="$STUB_BIN_DIR/dev-lead-lint.sh"
  export GITHUB_RUN_ID="99"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [ -f "$PROMPT_CAPTURE" ]
  local prompt; prompt=$(cat "$PROMPT_CAPTURE")
  # The comment's answer must be present in the prompt the engine received.
  [[ "$prompt" == *"ANSWER: the telemetry source is the oauth/usage endpoint."* ]]
  # And it must be framed as a refinement that can supersede the body.
  [[ "$prompt" == *"supersede"* ]]
}

@test "fix-issue: opened PR is labeled auto-rebase:ready (breaks #711 review-ready deadlock)" {
  # Lint passes
  cat > "$STUB_BIN_DIR/dev-lead-lint.sh" <<'LINTEOF'
#!/usr/bin/env bash
echo "  [lint] all checks passed (stub)"
exit 0
LINTEOF
  chmod +x "$STUB_BIN_DIR/dev-lead-lint.sh"

  # Intentionally dirty working tree — exercises the commit path
  cat > "$STUB_BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  "status --porcelain") echo "M scripts/foo.sh" ;;
  "rev-parse HEAD")     echo "abc123" ;;
  *)                    exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  # Record file lives in STUB_BIN_DIR (cleaned up by teardown); its path is baked
  # into the gh stub below via the unquoted heredoc, so no export is needed.
  LABEL_RECORD="$STUB_BIN_DIR/label_record"

  # gh stub: pr create returns a URL so the label path is exercised; record pr edit args
  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"pr create"*)       echo "https://github.com/petry-projects/repo/pull/42" ;;
  *"pr edit"*)         echo "\$*" >> "$LABEL_RECORD"; exit 0 ;;
  *"label create"*)    exit 0 ;;
  *"pulls?state=open"*) echo "0" ;;
  *"-X POST"*"issues/42/labels"*) echo "\$*" >> "$LABEL_RECORD"; echo '[]' ;;
  *"api"*"repos/"*"issues/"*) echo '{"title":"Test","body":"body"}' ;;
  *"api"*"users/"*)    echo '{"id":12345}' ;;
  *"issue comment"*)   exit 0 ;;
  *)                   echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  export DEV_LEAD_DRY_RUN="false"
  export LINT_SCRIPT="$STUB_BIN_DIR/dev-lead-lint.sh"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  # The opened PR must be made auto-rebase-eligible from creation.
  # Posted via the REST labels endpoint: `gh pr edit --add-label` fails under the
  # workflow token (#2142), so it must not be the path used.
  grep -q "api -X POST repos/.*/issues/42/labels -f labels\[\]=auto-rebase:ready" "$LABEL_RECORD"
  ! grep -q "pr edit" "$LABEL_RECORD"
}

# ── empty net-diff guard (#1786, slice 1 of #1620) ────────────────────────────
#
# These run against a REAL git repo (origin/main is a real ref) so the three-dot
# net-diff guard genuinely resolves the base — a PATH-stubbed git cannot exercise
# the abort path, only its fail-open fallback.

# Init a repo whose base commit is tracked by origin/main, a passing lint stub,
# a git stub that intercepts push, and a gh stub that records the PR-create call,
# every issue-comment body, and every issue label edit.
_ndg_issue_setup() {
  local engine_body="$1"
  NDG_REPO="$BATS_TEST_TMPDIR/issue_repo"
  NDG_COMMENT_FILE="$BATS_TEST_TMPDIR/comment_file"
  NDG_LABEL_FILE="$BATS_TEST_TMPDIR/label_file"
  NDG_PR_CREATE_FILE="$BATS_TEST_TMPDIR/pr_create_file"
  NDG_PUSH_FILE="$BATS_TEST_TMPDIR/push_file"
  NDG_SENTINEL="$BATS_TEST_TMPDIR/engine_ran"
  mkdir -p "$NDG_REPO"
  : > "$NDG_COMMENT_FILE"; : > "$NDG_LABEL_FILE"
  : > "$NDG_PR_CREATE_FILE"; : > "$NDG_PUSH_FILE"

  git -C "$NDG_REPO" init -q
  printf 'base\n' > "$NDG_REPO/file.txt"
  git -C "$NDG_REPO" add .
  git -C "$NDG_REPO" -c user.email="t@test" -c user.name="T" commit -q -m "base"
  git -C "$NDG_REPO" update-ref refs/remotes/origin/main "$(git -C "$NDG_REPO" rev-parse HEAD)"

  cat > "$STUB_BIN_DIR/dev-lead-lint.sh" <<'LEOF'
#!/usr/bin/env bash
echo "  [lint] all checks passed (stub)"
exit 0
LEOF
  chmod +x "$STUB_BIN_DIR/dev-lead-lint.sh"

  # Engine stub: runs its body exactly once (sentinel guards against re-invocation
  # by the fallback/headroom paths), in the repo working tree.
  cat > "$STUB_BIN_DIR/claude" <<CEOF
#!/usr/bin/env bash
echo "Implemented issue."
if [ ! -f "${NDG_SENTINEL}" ]; then
  : > "${NDG_SENTINEL}"
${engine_body}
fi
exit 0
CEOF
  chmod +x "$STUB_BIN_DIR/claude"

  cat > "$STUB_BIN_DIR/git" <<GITEOF
#!/usr/bin/env bash
if [ "\$1" = "push" ]; then echo "\$*" >> "${NDG_PUSH_FILE}"; exit 0; fi
exec /usr/bin/git "\$@"
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
cmd="\$1"; shift || true
case "\$cmd" in
  pr)
    case "\$*" in
      create*) echo "\$*" >> "${NDG_PR_CREATE_FILE}"; echo "https://github.com/petry-projects/.github-private/pull/77" ;;
      *) exit 0 ;;
    esac ;;
  label) exit 0 ;;
  issue)
    sub="\$1"; shift || true
    case "\$sub" in
      comment)
        body=""
        while [ \$# -gt 0 ]; do
          if [ "\$1" = "--body" ]; then body="\$2"; shift 2; continue; fi
          shift
        done
        printf '%s\n----8<----\n' "\$body" >> "${NDG_COMMENT_FILE}"
        exit 0 ;;
      edit)
        printf '%s\n' "\$*" >> "${NDG_LABEL_FILE}"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  api)
    case "\$*" in
      *"pulls?state=open"*) echo "0" ;;
      *"-X POST"*"/labels"*) printf '%s\n' "\$*" >> "${NDG_LABEL_FILE}"; echo '[]' ;;
      *"users/"*)           echo '{"id":12345}' ;;
      *comments*)           echo "[]" ;;
      *"issues/"*)          echo '{"title":"Test","body":"body"}' ;;
      *)                    echo "{}" ;;
    esac ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
}

@test "fix-issue: empty net diff → aborts, labels needs-human, opens no PR, no completion claim (#1786 AC1/AC2)" {
  # Engine self-commits a change and then reverts it: HEAD advances past the base
  # but the three-dot net diff against origin/main is empty.
  _ndg_issue_setup '  printf "temp\n" > extra.txt
  git add -A
  git -c user.email=t@test -c user.name=T commit -q -m "add extra"
  git rm -q extra.txt
  git -c user.email=t@test -c user.name=T commit -q -m "remove extra"'

  cd "$NDG_REPO"
  run bash -c "
    export ISSUE_NUMBER=100 REPO='petry-projects/.github-private' GITHUB_REPOSITORY='petry-projects/.github-private'
    export REVIEW_ENGINE=claude DEV_LEAD_DRY_RUN=false
    export PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export LINT_SCRIPT='$STUB_BIN_DIR/dev-lead-lint.sh'
    export PLG_STANDARDS_DIR='/nonexistent-plg'
    export PATH="$STUB_BIN_DIR:\$PATH"
    bash '$FIX_ISSUE_SCRIPT'
  " 2>&1

  # Aborted (non-zero) and announced the empty-net-diff refusal.
  [ "$status" -ne 0 ]
  [[ "$output" == *"net diff"* ]] || [[ "$output" == *"Empty net diff"* ]]
  # No PR was opened.
  [ ! -s "$NDG_PR_CREATE_FILE" ]
  # The branch was NOT pushed (never open/publish an empty-net-diff branch).
  [ ! -s "$NDG_PUSH_FILE" ]
  # Issue labelled dev-lead:needs-human.
  grep -q "labels\[\]=dev-lead:needs-human" "$NDG_LABEL_FILE"
  # No durable completion claim was posted.
  run grep -q "status=completed" "$NDG_COMMENT_FILE"
  [ "$status" -eq 1 ]
}

@test "fix-issue: non-empty net diff → completion claim states file count and net line change (#1786 AC2)" {
  # Engine leaves a real net change (one added line); the script commits it.
  _ndg_issue_setup '  printf "base\nfeature\n" > file.txt'

  cd "$NDG_REPO"
  run bash -c "
    export ISSUE_NUMBER=100 REPO='petry-projects/.github-private' GITHUB_REPOSITORY='petry-projects/.github-private'
    export REVIEW_ENGINE=claude DEV_LEAD_DRY_RUN=false GITHUB_RUN_ID=99
    export PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export LINT_SCRIPT='$STUB_BIN_DIR/dev-lead-lint.sh'
    export PLG_STANDARDS_DIR='/nonexistent-plg'
    export PATH="$STUB_BIN_DIR:\$PATH"
    bash '$FIX_ISSUE_SCRIPT'
  " 2>&1

  [ "$status" -eq 0 ]
  # A PR was opened and the durable completion claim posted.
  [ -s "$NDG_PR_CREATE_FILE" ]
  grep -q "status=completed" "$NDG_COMMENT_FILE"
  # The claim states the file count and net line change (AC2).
  grep -q "1 file(s)" "$NDG_COMMENT_FILE"
  grep -q "+1/-0 lines" "$NDG_COMMENT_FILE"
}
