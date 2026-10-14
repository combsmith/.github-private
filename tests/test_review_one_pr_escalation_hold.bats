#!/usr/bin/env bats
# Regression guard for #2090: an automated dispatch must never re-review a PR
# that pr-review escalated to a human, nor clear its `needs-human-review` hold.
#
# The #1902 sequence (2026-10-09): pr-review escalated at cycle 3/3 and added
# `needs-human-review`; auto-rebase then moved the head; pr-auto-review's plain
# `repository_dispatch` (no client_payload.force_review) re-ran the full cascade
# three times in 10 minutes (twice on the same head) and its fix-request path
# removed the hold. Root cause: the `pr-review/v1-next` channel still served
# pr-review.yml from before #2078, where ANY repository_dispatch set
# FORCE_REVIEW=true — the human break-glass that bypasses the escalation pause,
# the same-SHA idempotency no-op and the cycle cap. Since #2078 such a dispatch
# yields FORCE_REVIEW=false + FORCE_RE_REVIEW=true (the narrow idempotency
# bypass). These tests pin that the narrow flag, on its own, honours the
# escalation pause in every shape of the #1902 sequence.
#
# Harness: the same gh stub as tests/test_review_one_pr_force_re_review.bats
# (green CI, gates that clear), driving scripts/review-one-pr.sh end to end.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"

  export SHA="f53038594ebf608a42f504d64a13db31c4e69983"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/1902"

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


ROLLUP_PASS='[{"name":"CI / build","status":"COMPLETED","conclusion":"SUCCESS"}]'
OLD_SHA="6c686c54dcf39fc7585773200195f95bdf156fac"

# write_escalated_snapshot <labels-json> [extra-comment-json...]
# A PR whose last cycle (3/3, on OLD_SHA) escalated to a human via the verdict
# path (`human-escalation v1` comment, edited in place with a reset stamp).
write_escalated_snapshot() {
  local labels="$1"; shift
  local extra='[]'
  [ "$#" -gt 0 ] && extra=$(jq -sc '.' <<<"$*")
  jq -n --arg sha "$SHA" --arg old "$OLD_SHA" --argjson rollup "$ROLLUP_PASS" \
        --argjson labels "$labels" --argjson extra "$extra" '{
    headRefOid: $sha,
    statusCheckRollup: $rollup,
    reviewDecision: "REVIEW_REQUIRED",
    reviews: [],
    labels: ($labels | map({name: .})),
    closingIssuesReferences: [],
    body: "PR body",
    comments: ([
      {author:{login:"donpetry-bot"}, createdAt:"2026-10-09T03:00:00Z",
       body:("<!-- pr-review-agent v1 sha=" + $old + " --> <!-- decision=fix-requested risk=MEDIUM -->")},
      {author:{login:"donpetry-bot"}, createdAt:"2026-10-09T03:20:00Z",
       body:("<!-- pr-review-agent v1 sha=" + $old + " --> <!-- decision=fix-requested risk=MEDIUM -->")},
      {author:{login:"donpetry-bot"}, createdAt:"2026-10-09T03:44:00Z",
       body:("<!-- pr-review-agent v1 sha=" + $old + " --> <!-- decision=fix-requested risk=MEDIUM -->")},
      {author:{login:"donpetry-bot"}, createdAt:"2026-10-08T20:00:00Z",
       body:"<!-- pr-review-agent human-escalation v1 -->\n<!-- pr-review-agent human-escalation reset=2026-10-09T04:44:28Z -->\n## Automated review — escalated to human"}
    ] + $extra)
  }' > "$SNAPSHOT"
}

# _assert_held — the run paused on the human escalation: no cascade, no label edit.
_assert_held() {
  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"human-escalated"'* ]]
  [[ "$output" != *"re-engaging cascade"* ]]
  [[ "$output" != *"re-running cascade"* ]]
  if grep -q -- '--remove-label' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "#2090: auto-rebase moved the head — an automated dispatch (FORCE_RE_REVIEW only) stays paused on the hold" {
  export FORCE_RE_REVIEW="true"
  write_escalated_snapshot '["needs-human-review","dev-lead:hands-off"]'
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  _assert_held
}

@test "#2090: a verdict already at the new head — an automated dispatch neither re-runs nor un-holds" {
  export FORCE_RE_REVIEW="true"
  write_escalated_snapshot '["needs-human-review"]' \
    '{"author":{"login":"donpetry-bot"},"createdAt":"2026-10-09T05:04:30Z","body":"<!-- pr-review-agent v1 sha='"$SHA"' --> <!-- decision=fix-requested risk=MEDIUM -->"}'
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 100 ]
  [[ "$output" != *"re-engaging cascade"* ]]
  [[ "$output" != *"re-running cascade"* ]]
  if grep -q -- '--remove-label' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "#2090: an unforced event run also stays paused on the hold" {
  unset FORCE_REVIEW FORCE_RE_REVIEW
  write_escalated_snapshot '["needs-human-review"]'
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  _assert_held
}

@test "#2090 control: once a human removes the label, the cascade re-engages with a fresh budget" {
  unset FORCE_REVIEW FORCE_RE_REVIEW
  write_escalated_snapshot '[]'
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [[ "$output" == *"re-engage: escalation marker present but needs-human-review label removed"* ]]
  [[ "$output" == *"review cycle: 0 (max: 3)"* ]]
}

@test "#2090 control: the human @mention break-glass (FORCE_REVIEW) still re-engages an escalated PR" {
  export FORCE_REVIEW="true"
  write_escalated_snapshot '["needs-human-review"]'
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [[ "$output" == *"force-review: escalation marker present, but FORCE_REVIEW=true"* ]]
}

@test "#2090: pr-review.yml derives FORCE_REVIEW only from an explicit client_payload.force_review" {
  # The #1902 runs used a pr-review.yml whose FORCE_REVIEW was
  # `github.event_name == 'repository_dispatch'` alone. Pin the #2078 expression.
  grep -qF "FORCE_REVIEW: \${{ github.event_name == 'repository_dispatch' && (github.event.client_payload.force_review == true || github.event.client_payload.force_review == 'true') && 'true' || 'false' }}" \
    "$REPO_ROOT/.github/workflows/pr-review.yml"
}
