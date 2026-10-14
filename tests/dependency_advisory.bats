#!/usr/bin/env bats
# Offline tests for the dependency-advisory runner (scripts/aw-dependency-advisory.sh).
#
# The DEGRADED signal in #1672 traced to a single transient `API Error: 529
# Overloaded` from the Claude CLI hard-failing an *advisory* (non-gating)
# workflow. These tests pin the resilience contract: transient Claude failures
# are retried with backoff, and a persistent transient error degrades
# gracefully (warn + exit 0) rather than failing the advisory. A genuinely
# non-transient failure still exits 1.
#
# The script is driven against STUB `gh` and `claude` binaries placed first on
# PATH, so every branch is exercised with NO network — mirroring the
# stub-engine discipline of tests/test_eval_health_notify.bats.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$ROOT/scripts/aw-dependency-advisory.sh"
  TMP="$BATS_TEST_TMPDIR"
  GH_LOG="$TMP/gh.log"
  CLAUDE_LOG="$TMP/claude.log"
  CLAUDE_COUNT_FILE="$TMP/claude.count"
  : >"$GH_LOG"
  : >"$CLAUDE_LOG"
  : >"$CLAUDE_COUNT_FILE"

  BIN="$TMP/bin"
  mkdir -p "$BIN"

  # Stub gh: logs every invocation and dispatches by subcommand/URL. Emits a
  # single-file dependency diff by default (DIFF_MODE=nodep flips to a
  # source-only diff), a PR-author of $PR_AUTHOR (default alice), an empty
  # existing-comment lookup, and `true` for the triage/push permission probe.
  cat >"$BIN/gh" <<'SH'
#!/usr/bin/env bash
echo "ARGS: $*" >>"$GH_LOG"
case "$1" in
  api)
    url="$2"
    case "$url" in
      */pulls/*)
        printf '{"author":"%s","title":"t","base":"main","head":"feat"}' "${PR_AUTHOR:-alice}"
        ;;
      */issues/comments/*)
        : # PATCH update of an existing comment — no output needed
        ;;
      */issues/*/comments)
        printf '%s' "${EXISTING_COMMENT_ID:-}"
        ;;
      *)
        # Bare repos/OWNER/REPO — the triage/push permission probe.
        echo "true"
        ;;
    esac
    ;;
  pr)
    case "$2" in
      diff)
        if [ "${DIFF_MODE:-dep}" = "nodep" ]; then
          cat <<'DIFF'
diff --git a/src/main.js b/src/main.js
index 111..222 100644
--- a/src/main.js
+++ b/src/main.js
@@ -1 +1 @@
-const x = 1;
+const x = 2;
DIFF
        else
          cat <<'DIFF'
diff --git a/package.json b/package.json
index 111..222 100644
--- a/package.json
+++ b/package.json
@@ -1,3 +1,3 @@
-    "lodash": "4.17.19"
+    "lodash": "4.17.21"
DIFF
        fi
        ;;
      comment)
        : # posting a new comment — logged above
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$BIN/gh"

  # Stub claude: increments a shared attempt counter and fails the first
  # CLAUDE_FAIL_ATTEMPTS attempts with a transient (529) or non-transient
  # signature per CLAUDE_FAIL_MODE, then succeeds with a valid advisory body.
  cat >"$BIN/claude" <<'SH'
#!/usr/bin/env bash
echo "ARGS: $*" >>"$CLAUDE_LOG"
n=0
[ -f "$CLAUDE_COUNT_FILE" ] && n=$(cat "$CLAUDE_COUNT_FILE")
n=$((n + 1))
echo "$n" >"$CLAUDE_COUNT_FILE"
if [ "$n" -le "${CLAUDE_FAIL_ATTEMPTS:-0}" ]; then
  case "${CLAUDE_FAIL_MODE:-transient}" in
    nontransient) echo "API Error: 400 invalid_request_error: bad prompt" >&2 ;;
    *) echo "API Error: 529 Overloaded. This is a server-side issue, usually temporary — try again in a moment." >&2 ;;
  esac
  exit 1
fi
cat <<'BODY'
<!-- dependency-advisory -->
## Dependency Advisory

All dependency changes appear low-risk. No action required.
BODY
exit 0
SH
  chmod +x "$BIN/claude"
}

run_advisory() {
  run env "PATH=$BIN:$PATH" \
    GH_LOG="$GH_LOG" CLAUDE_LOG="$CLAUDE_LOG" CLAUDE_COUNT_FILE="$CLAUDE_COUNT_FILE" \
    REPO="petry-projects/.github-private" PR_NUMBER="5" \
    CLAUDE_CODE_OAUTH_TOKEN="test-token" \
    SKIP_BOT_PRS="false" \
    DEP_ADVISORY_RETRY_BASE_SEC="0" \
    "$@" bash "$SCRIPT"
}

claude_calls() { local n; n="$(cat "$CLAUDE_COUNT_FILE")"; echo "${n:-0}"; }

# --- happy path (no regression) ---------------------------------------------

@test "success on first attempt posts a comment with exactly one claude call" {
  run_advisory CLAUDE_FAIL_ATTEMPTS=0
  [ "$status" -eq 0 ]
  [ "$(claude_calls)" -eq 1 ]
  grep -q "ARGS: pr comment 5" "$GH_LOG"
}

# --- transient retry (the #1672 fix) ----------------------------------------

@test "a transient 529 on the first attempt is retried and then succeeds" {
  run_advisory CLAUDE_FAIL_ATTEMPTS=1 DEP_ADVISORY_MAX_ATTEMPTS=3
  [ "$status" -eq 0 ]
  [ "$(claude_calls)" -eq 2 ]
  grep -q "ARGS: pr comment 5" "$GH_LOG"
  # The retry is surfaced, not silent.
  echo "$output" | grep -qi "retry"
}

@test "a persistent transient 529 degrades gracefully (warn + exit 0, no comment)" {
  run_advisory CLAUDE_FAIL_ATTEMPTS=99 DEP_ADVISORY_MAX_ATTEMPTS=3
  [ "$status" -eq 0 ]
  [ "$(claude_calls)" -eq 3 ]
  # Advisory is informational — a persistent overload must not post a comment...
  ! grep -q "ARGS: pr comment" "$GH_LOG"
  # ...and must emit a visible warning rather than fail silently.
  echo "$output" | grep -q "::warning::"
}

# --- non-transient failure is still fatal -----------------------------------

@test "a non-transient claude failure still exits 1 and is not retried" {
  run_advisory CLAUDE_FAIL_ATTEMPTS=99 CLAUDE_FAIL_MODE=nontransient DEP_ADVISORY_MAX_ATTEMPTS=3
  [ "$status" -eq 1 ]
  [ "$(claude_calls)" -eq 1 ]
  ! grep -q "ARGS: pr comment" "$GH_LOG"
}

# --- pre-existing skip branches (regression guards) -------------------------

@test "a bot PR is skipped before any claude call" {
  run_advisory PR_AUTHOR="dependabot[bot]" SKIP_BOT_PRS="true"
  [ "$status" -eq 0 ]
  [ "$(claude_calls)" -eq 0 ]
  ! grep -q "ARGS: pr comment" "$GH_LOG"
}

@test "no dependency changes in the diff skips before any claude call" {
  run_advisory DIFF_MODE="nodep"
  [ "$status" -eq 0 ]
  [ "$(claude_calls)" -eq 0 ]
  ! grep -q "ARGS: pr comment" "$GH_LOG"
}
