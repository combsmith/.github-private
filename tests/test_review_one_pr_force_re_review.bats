#!/usr/bin/env bats
# Regression guard for issue #1590: the sweep's automated orphan-rescue path must
# NOT bypass the quality gates.
#
# Before #1590, the orphan-rescue dispatch (scripts/sweep-stuck-reviews.sh) passed
# force_review=true, which mapped straight onto FORCE_REVIEW in review-one-pr.sh —
# the human break-glass that bypasses EVERY gate (ci-failing, ci-pending, advisory,
# maintainer, changes-requested, …). The sweep only wanted to defeat the same-SHA
# idempotency no-op on the orphan marker, so it was silently converting a
# reliability rescue into a full gate bypass, and the CI snapshot it validated
# could go stale (TOCTOU) before the forced review ran.
#
# The fix splits the flag:
#   • FORCE_REVIEW    — human @mention break-glass; bypasses all gates (unchanged).
#   • FORCE_RE_REVIEW — narrow: clears ONLY the same-SHA idempotency no-op and
#                       leaves every quality gate armed. The orphan-rescue sweep
#                       (force_review input on workflow_dispatch/call) maps here.
#
# These tests drive scripts/review-one-pr.sh end-to-end. The gh stub satisfies the
# advisory-bot and maintainer gates on the green-CI paths (no advisory-bot output +
# an old head commit ⇒ advisory gate proceeds; empty review-thread set + our own
# marker comments clear the maintainer gates) so the idempotency block is reached.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"

  export SHA="8203876e5b0718dd3d672fed4eec8394e5d3729d"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/1590"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  export SNAPSHOT="$TEST_DIR/snapshot.json"
  export GH_LOG="$TEST_DIR/gh_calls.log"
  : > "$GH_LOG"

  # gh stub: honors `pr view --jq <filter>` (so the idempotency block's own marker
  # query works), returns the snapshot for a plain `pr view`, and answers the
  # GraphQL shapes the gates use with old timestamps so they clear.
  cat > "$TEST_DIR/bin/gh" <<'GHEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  jqf=""; prev=""
  for a in "$@"; do
    [ "$prev" = "--jq" ] && jqf="$a"
    prev="$a"
  done
  if [ -n "$jqf" ]; then jq -r "$jqf" "$SNAPSHOT"; else cat "$SNAPSHOT"; fi
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  case "$*" in
    *reviewThreads*) printf '%s' '{"data":{"resource":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' ;;
    *pushedDate*)    printf '%s' '{"data":{"resource":{"commits":{"nodes":[{"commit":{"pushedDate":"2020-01-01T00:00:00Z","committer":{"date":"2020-01-01T00:00:00Z"}}}]}}}}' ;;
    *)               printf '%s\n' '2020-01-01T00:00:00Z' ;;
  esac
  exit 0
fi
exit 0
GHEOF
  chmod +x "$TEST_DIR/bin/gh"

  # Stub engines so a bypassed (proceed) run can't block on a real CLI.
  for e in claude copilot gemini; do
    printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/$e"
    chmod +x "$TEST_DIR/bin/$e"
  done

  export PATH="$TEST_DIR/bin:$PATH"
  export REVIEW_ENGINE="claude" GH_TOKEN="fake" DRY_RUN="true"
  unset FORCE_REVIEW FORCE_RE_REVIEW
}

# No teardown: $BATS_TEST_TMPDIR (our $TEST_DIR) is a per-test dir that BATS
# creates and removes automatically, so manual `rm -rf` cleanup is redundant.

# write_snapshot <rollup-json> [marker-comment-body]
# Green rollup by default is the caller's; marker comment is optional (an orphan
# idempotency marker at head when present).
write_snapshot() {
  local rollup="$1" marker_body="${2:-}"
  local comments='[]'
  if [ -n "$marker_body" ]; then
    comments=$(jq -n --arg b "$marker_body" '[{author:{login:"donpetry-bot"},createdAt:"2026-08-19T12:06:00Z",body:$b}]')
  fi
  jq -n --arg sha "$SHA" --argjson rollup "$rollup" --argjson comments "$comments" '{
    headRefOid: $sha,
    statusCheckRollup: $rollup,
    reviewDecision: "",
    reviews: [],
    labels: [],
    closingIssuesReferences: [],
    body: "PR body",
    comments: $comments
  }' > "$SNAPSHOT"
}

ROLLUP_PASS='[{"name":"CI / build","status":"COMPLETED","conclusion":"SUCCESS"}]'
ROLLUP_FAIL='[{"name":"CI / build","status":"COMPLETED","conclusion":"FAILURE"}]'
ROLLUP_PENDING='[{"name":"CI / build","status":"IN_PROGRESS","conclusion":null}]'

# ── The core AC: the narrow flag does NOT bypass the CI gates ────────────────

@test "AC1: FORCE_RE_REVIEW=true + failing CI → skip ci-failing (narrow flag does NOT bypass the CI gate)" {
  export FORCE_RE_REVIEW="true"
  write_snapshot "$ROLLUP_FAIL"
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"ci-failing"'* ]]
  # Must NOT announce the break-glass ci-failing bypass — that is FORCE_REVIEW only.
  [[ "$output" != *"bypassing the ci-failing gate"* ]]
}

@test "AC1: FORCE_RE_REVIEW=true + pending CI → skip ci-pending (narrow flag does NOT bypass the CI-pending gate)" {
  export FORCE_RE_REVIEW="true"
  write_snapshot "$ROLLUP_PENDING"
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"ci-pending"'* ]]
}

# ── The narrow flag DOES bypass the same-SHA idempotency no-op ───────────────

@test "AC2: FORCE_RE_REVIEW=true + green CI + orphan marker at head → idempotency no-op bypassed" {
  export FORCE_RE_REVIEW="true"
  # Orphan marker: stamped at head but NO decision= verdict (the #1548 strand).
  write_snapshot "$ROLLUP_PASS" '<!-- pr-review-agent v1 sha='"$SHA"' -->'
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  # It must NOT no-op as already-reviewed-at-head…
  [[ "$output" != *'"reason":"already-reviewed-at-head"'* ]]
  # …and must announce the idempotency bypass and enter the cascade (exit != 100).
  [[ "$output" == *"re-running cascade"* ]]
  [ "$status" -ne 100 ]
}

# ── The narrow flag is orphan-only: a genuine verdict at head is NOT re-run ───

@test "AC2b: FORCE_RE_REVIEW=true + green CI + COMPLETE verdict at head → no-op (does NOT re-run a completed review — #1598 race)" {
  export FORCE_RE_REVIEW="true"
  # A genuine verdict (decision=approved) landed at head after the sweep snapshot.
  # FORCE_RE_REVIEW rescues orphans only, so this must defer to the idempotency no-op.
  write_snapshot "$ROLLUP_PASS" '<!-- pr-review-agent v1 sha='"$SHA"' decision=approved risk=LOW -->'
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"already-reviewed-at-head"'* ]]
  [[ "$output" != *"re-running cascade"* ]]
}

# ── Control: with NO flag the same-SHA marker still no-ops (idempotency armed) ─

@test "control: no flag + green CI + marker at head → no-op already-reviewed-at-head" {
  unset FORCE_REVIEW FORCE_RE_REVIEW
  write_snapshot "$ROLLUP_PASS" '<!-- pr-review-agent v1 sha='"$SHA"' -->'
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"already-reviewed-at-head"'* ]]
}

# ── The human break-glass (FORCE_REVIEW) is unchanged ───────────────────────

@test "unchanged: FORCE_REVIEW=true + failing CI → ci-failing gate bypassed (break-glass #619)" {
  export FORCE_REVIEW="true"
  write_snapshot "$ROLLUP_FAIL"
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [[ "$output" != *'"reason":"ci-failing"'* ]]
  [[ "$output" == *"bypassing the ci-failing gate"* ]]
  [ "$status" -ne 100 ]
}

@test "unchanged: FORCE_REVIEW=true + green CI + marker at head → idempotency bypassed" {
  export FORCE_REVIEW="true"
  write_snapshot "$ROLLUP_PASS" '<!-- pr-review-agent v1 sha='"$SHA"' -->'
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [[ "$output" != *'"reason":"already-reviewed-at-head"'* ]]
  [[ "$output" == *"re-running cascade"* ]]
  [ "$status" -ne 100 ]
}

@test "unchanged: FORCE_REVIEW=true + green CI + COMPLETE verdict at head → break-glass still bypasses (orphan-only gate is FORCE_RE_REVIEW's)" {
  export FORCE_REVIEW="true"
  # The human break-glass bypasses idempotency even for a genuine verdict at head.
  write_snapshot "$ROLLUP_PASS" '<!-- pr-review-agent v1 sha='"$SHA"' decision=approved risk=LOW -->'
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [[ "$output" != *'"reason":"already-reviewed-at-head"'* ]]
  [[ "$output" == *"re-running cascade"* ]]
  [ "$status" -ne 100 ]
}
