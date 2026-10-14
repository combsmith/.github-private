#!/usr/bin/env bats
# #1933: pr-review must re-evaluate — not no-op `already-reviewed-at-head` — when
# its approval at the head was dismissed by its OWN gate and every gate now
# passes at that same head. Replays the #1907 sequence: approve af711476 →
# maintainer-comment gate dismisses it (#1813) → comments dispositioned → the
# next run used to no-op forever.
#
# Unit tests cover lib/self-dismissed-approval.sh (the decision); the end-to-end
# tests drive scripts/review-one-pr.sh with the same gh stub as
# tests/test_review_one_pr_force_re_review.bats, plus REST reviews/events fixtures.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"

  export SHA="af7114760000000000000000000000000000beef"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/1907"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  export SNAPSHOT="$TEST_DIR/snapshot.json"
  export REST_REVIEWS="$TEST_DIR/reviews.json" REST_EVENTS="$TEST_DIR/events.json"
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
if [ "$1" = "api" ]; then
  case "$*" in
    *"/pulls/1907/reviews"*) [ -f "$REST_REVIEWS" ] && cat "$REST_REVIEWS"; exit 0 ;;
    *"/issues/1907/events"*) [ -f "$REST_EVENTS" ] && cat "$REST_EVENTS"; exit 0 ;;
  esac
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
APPROVAL_BODY() { printf '<!-- pr-review-agent v1 sha=%s decision=approved risk=LOW -->\n## Automated review — APPROVED' "$SHA"; }
GATE_MSG_1813="Dismissing approval due to a PR issue comment lacking a verified disposition (#1813)"
GATE_MSG_1415="Dismissing approval due to unaddressed maintainer review thread (#1415)"

# write_state <review-state> [dismisser] [dismissal-message]
# One pr-review approval at head (now <review-state>) in both the snapshot and
# the REST reviews; when dismissed, one review_dismissed event.
write_state() {
  local state="$1" actor="${2:-donpetry-bot}" msg="${3:-$GATE_MSG_1813}"
  local body; body="$(APPROVAL_BODY)"
  jq -n --arg sha "$SHA" --argjson rollup "$ROLLUP_PASS" --arg body "$body" --arg st "$state" '{
    headRefOid: $sha, statusCheckRollup: $rollup, reviewDecision: "",
    reviews: [{id:"PRR_1", author:{login:"donpetry-bot"}, state:$st, submittedAt:"2026-09-25T03:10:00Z",
               commit:{oid:$sha}, body:$body}],
    labels: [], closingIssuesReferences: [], body: "PR body", comments: []
  }' > "$SNAPSHOT"
  jq -n --arg sha "$SHA" --arg body "$body" --arg st "$state" \
    '[{id:101, user:{login:"donpetry-bot"}, state:$st, commit_id:$sha, body:$body}]' > "$REST_REVIEWS"
  if [ "$state" = "DISMISSED" ]; then
    jq -n --arg a "$actor" --arg m "$msg" \
      '[{event:"review_dismissed", actor:{login:$a}, created_at:"2026-09-25T03:14:49Z",
         dismissed_review:{state:"approved", review_id:101, dismissal_message:$m}}]' > "$REST_EVENTS"
  else
    echo '[]' > "$REST_EVENTS"
  fi
}

# ── lib unit tests ────────────────────────────────────────────────────────────

_sda() {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/self-dismissed-approval.sh"
  sda_pending_reevaluation "$(cat "$REST_REVIEWS")" "$(cat "$REST_EVENTS")" "$SHA" donpetry-bot "donpetry-bot github-actions[bot]"
}

@test "lib: approval dismissed by pr-review's disposition gate → pending re-evaluation" {
  write_state DISMISSED donpetry-bot "$GATE_MSG_1813"
  run _sda
  [ "$status" -eq 0 ]
}

@test "lib: approval dismissed by pr-review's maintainer-thread gate → pending re-evaluation" {
  write_state DISMISSED "github-actions[bot]" "$GATE_MSG_1415"
  run _sda
  [ "$status" -eq 0 ]
}

@test "lib: a HUMAN dismissal is never pending re-evaluation" {
  write_state DISMISSED don-petry "$GATE_MSG_1813"
  run _sda
  [ "$status" -ne 0 ]
}

@test "lib: the #1596 accepted-defect dismissal still needs a new commit" {
  write_state DISMISSED donpetry-bot "Auto-dismissed: a trusted advisory reviewer found an accepted defect after this approval at af711476 (pr-review miss, #1596). Re-review required."
  run _sda
  [ "$status" -ne 0 ]
}

@test "lib: an approval still standing, or an unreadable timeline, is not pending" {
  write_state APPROVED
  run _sda
  [ "$status" -ne 0 ]
  write_state DISMISSED
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/self-dismissed-approval.sh"
  run sda_pending_reevaluation "$(cat "$REST_REVIEWS")" "not json" "$SHA" donpetry-bot
  [ "$status" -ne 0 ]
  run sda_pending_reevaluation "$(cat "$REST_REVIEWS")" "$(cat "$REST_EVENTS")" "0000000000000000000000000000000000000000" donpetry-bot
  [ "$status" -ne 0 ]
}

@test "lib: the NEWEST approval at head decides — a later human dismissal is not revived (#1933 review)" {
  # 101 gate-dismissed → re-evaluation approved again as 102 → a maintainer
  # dismissed 102. The older gate dismissal must not re-open the cascade.
  write_state DISMISSED
  local body; body="$(APPROVAL_BODY)"
  jq -n --arg sha "$SHA" --arg body "$body" \
    '[{id:101, user:{login:"donpetry-bot"}, state:"DISMISSED", commit_id:$sha, body:$body},
      {id:102, user:{login:"donpetry-bot"}, state:"DISMISSED", commit_id:$sha, body:$body}]' > "$REST_REVIEWS"
  jq -n --arg m "$GATE_MSG_1813" \
    '[{event:"review_dismissed", actor:{login:"donpetry-bot"}, dismissed_review:{state:"approved", review_id:101, dismissal_message:$m}},
      {event:"review_dismissed", actor:{login:"don-petry"}, dismissed_review:{state:"approved", review_id:102, dismissal_message:"no"}}]' > "$REST_EVENTS"
  run _sda
  [ "$status" -ne 0 ]
  # …and the mirror image: a human-dismissed 101 then a gate-dismissed 102 IS pending.
  jq -n --arg m "$GATE_MSG_1813" \
    '[{event:"review_dismissed", actor:{login:"don-petry"}, dismissed_review:{state:"approved", review_id:101, dismissal_message:"no"}},
      {event:"review_dismissed", actor:{login:"donpetry-bot"}, dismissed_review:{state:"approved", review_id:102, dismissal_message:$m}}]' > "$REST_EVENTS"
  run _sda
  [ "$status" -eq 0 ]
}

@test "lib: review ids match across number/string encodings; a missing id never matches (#1933 review)" {
  write_state DISMISSED
  jq '.[0].dismissed_review.review_id |= tostring' "$REST_EVENTS" > "$REST_EVENTS.tmp" && mv "$REST_EVENTS.tmp" "$REST_EVENTS"
  run _sda
  [ "$status" -eq 0 ]
  # null on both sides must not pair a review with a dismissal event.
  jq 'map(del(.id))' "$REST_REVIEWS" > "$REST_REVIEWS.tmp" && mv "$REST_REVIEWS.tmp" "$REST_REVIEWS"
  jq 'map(del(.dismissed_review.review_id))' "$REST_EVENTS" > "$REST_EVENTS.tmp" && mv "$REST_EVENTS.tmp" "$REST_EVENTS"
  run _sda
  [ "$status" -ne 0 ]
}

@test "lib: the recognised messages match the gate dismissals in review-one-pr.sh" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/self-dismissed-approval.sh"
  local p
  for p in "${SDA_GATE_DISMISSAL_PREFIXES[@]}"; do
    grep -qF -- "msg=\"$p" "$REPO_ROOT/scripts/review-one-pr.sh"
  done
  [ "$(grep -c 'dismissPullRequestReview' "$REPO_ROOT/scripts/review-one-pr.sh")" -eq "${#SDA_GATE_DISMISSAL_PREFIXES[@]}" ]
}

# ── end to end: scripts/review-one-pr.sh ─────────────────────────────────────

@test "#1933: gate-dismissed approval at head + gates now clear → re-evaluates at the same head (no new commit)" {
  write_state DISMISSED donpetry-bot "$GATE_MSG_1813"
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [[ "$output" != *'"reason":"already-reviewed-at-head"'* ]]
  [[ "$output" == *"was dismissed by its own gate"*"re-evaluating at the same head (#1933)"* ]]
  [ "$status" -ne 100 ]
}

@test "#1933 control: a standing approval at head still no-ops (no duplicate cascade)" {
  write_state APPROVED
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"already-reviewed-at-head"'* ]]
}

@test "#1933 control: a human-dismissed approval at head still no-ops" {
  write_state DISMISSED don-petry "$GATE_MSG_1813"
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"already-reviewed-at-head"'* ]]
  [[ "$output" != *"(#1933)"* ]]
}
