#!/usr/bin/env bats
# Unit tests for dev-lead-retry.sh — retry markers count only from our automation.
# `gh` is a PATH shim that evaluates the caller's own --jq filter against fixture
# comments, so the author filter itself runs.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
RETRY_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-retry.sh"
HEAD_SHA="abc123def456"

setup() {
  export MOCK_DIR="$BATS_TEST_TMPDIR/mock"
  mkdir -p "$MOCK_DIR" "$BATS_TEST_TMPDIR/shim"
  export PATH="$BATS_TEST_TMPDIR/shim:$PATH"
  export DRY_RUN="false" DISPATCH_DELAY_SEC=0 NOW_ISO="2026-10-09T12:00:00Z"
  export DEV_LEAD_USER="don-petry" PR_REVIEW_USER="donpetry-bot"
  : > "$MOCK_DIR/dispatches.log"
  printf '[]' > "$MOCK_DIR/comments.json"

  cat > "$BATS_TEST_TMPDIR/shim/gh" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = "api" ] || exit 1
shift
filter="."; path=""; is_post=0
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) ;;
    --jq) filter="$2"; shift ;;
    --method|-X) [ "$2" = "POST" ] && is_post=1; shift ;;
    -f|-F|--input) shift ;;
    *) path="$1" ;;
  esac
  shift
done
case "$path" in
  */dispatches) cat >> "$MOCK_DIR/dispatches.log"; echo >> "$MOCK_DIR/dispatches.log"; exit 0 ;;
  */issues/*/comments*)
    [ "$is_post" = 1 ] && exit 0
    jq -c "$filter" "$MOCK_DIR/comments.json"; exit 0 ;;
  */pulls/*)
    printf '{"number":7,"state":"open","head":{"sha":"%s"},"labels":[]}' "abc123def456" | jq -c "$filter"; exit 0 ;;
  *) echo "[]"; exit 0 ;;
esac
MOCK
  chmod +x "$BATS_TEST_TMPDIR/shim/gh"
  source "$RETRY_SCRIPT"
  pr_resume_suppressed() { return 1; }
  open_issue_pr_exists() { return 1; }
}

# _comment <login> <body>: one fixture comment.
_comment() {
  jq -nc --arg l "$1" --arg b "$2" '[{user:{login:$l},body:$b}]' > "$MOCK_DIR/comments.json"
}

_pr_marker() {
  printf '<!-- dev-lead-fix-reviews pr=7 sha=%s intent=%s status=rate-limited reset=2020-01-01T00:00:00Z -->' "$HEAD_SHA" "$1"
}

_ci_marker() {
  printf '%s%s status=rate-limited check=build reset=2020-01-01T00:00:00Z -->' "$CI_MARKER_PREFIX" "$HEAD_SHA"
}

_dispatches() { grep -c '"event_type"' "$MOCK_DIR/dispatches.log" || true; }

@test "PR retry marker: dev-lead's own marker dispatches" {
  _comment "don-petry" "$(_pr_marker rebase)"
  run scan_pr_for_rate_limits "combsmith/app" 7
  [ "$status" -eq 0 ]
  [ "$(_dispatches)" -eq 1 ]
}

@test "PR retry marker: pr-review's marker also counts as automation" {
  _comment "donpetry-bot" "$(_pr_marker fix-reviews)"
  run scan_pr_for_rate_limits "combsmith/app" 7
  [ "$(_dispatches)" -eq 1 ]
}

@test "PR retry marker: every retryable intent is ignored from any other account" {
  local intent
  for intent in rebase fix-reviews review-changes; do
    _comment "someone-else" "$(_pr_marker "$intent")"
    run scan_pr_for_rate_limits "combsmith/app" 7
    [ "$status" -eq 0 ]
    [ "$(_dispatches)" -eq 0 ]
  done
}

@test "fix-ci retry marker: ignored from any other account" {
  _comment "someone-else" "$(_ci_marker)"
  run scan_pr_for_rate_limits "combsmith/app" 7
  [ "$(_dispatches)" -eq 0 ]
}

@test "fix-ci retry marker: dev-lead's own marker dispatches" {
  _comment "don-petry" "$(_ci_marker)"
  run scan_pr_for_rate_limits "combsmith/app" 7
  [ "$(_dispatches)" -eq 1 ]
}

@test "another account's dispatch guard does not hold off a real retry" {
  jq -nc --arg m "$(_pr_marker rebase)" --arg g "${DISPATCH_GUARD_PREFIX}${HEAD_SHA} at=${NOW_ISO} -->" \
    '[{user:{login:"don-petry"},body:$m},{user:{login:"someone-else"},body:$g}]' > "$MOCK_DIR/comments.json"
  run scan_pr_for_rate_limits "combsmith/app" 7
  [ "$(_dispatches)" -eq 1 ]
}

@test "issue retry marker: dev-lead's own marker dispatches" {
  _comment "don-petry" '<!-- dev-lead-issue 478 status=failed attempt=1 reason=engine-error run=9 -->'
  run scan_issue_for_retry "combsmith/app" 478
  [ "$(_dispatches)" -eq 1 ]
}

@test "issue retry marker: ignored from any other account" {
  _comment "someone-else" '<!-- dev-lead-issue 478 status=failed attempt=1 reason=engine-error run=9 -->'
  run scan_issue_for_retry "combsmith/app" 478
  [ "$status" -eq 0 ]
  [ "$(_dispatches)" -eq 0 ]
}
