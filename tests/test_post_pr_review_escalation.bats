#!/usr/bin/env bats
# Issue #1754: pr-review counts a human-escalation as a posted review.
#
# scripts/post-pr-review.sh's decision=escalate → human-escalation branch used to
# add the needs-human-review label, request CODEOWNERS, then fall through to
# `exit 0`. review-batch.sh's `case "$rc" in 0)` then counted it as a posted
# review — the run reported "1 reviews posted" while NOTHING landed on the PR.
#
# These tests pin the fixed contract:
#   AC1  human-escalation exits 101 (escalated), not 0 (posted) or 100 (no-op).
#   AC2  escalation leaves a visible artifact — a marker-keyed PR comment —
#        created once and UPDATED IN PLACE on re-escalation (never appended).
#   AC3  the needs-human-review label is added only when absent (no relabel churn).
#   AC4  an approve review with an empty or marker-less body is not submitted —
#        fail closed.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export POST_SCRIPT="$REPO_ROOT/scripts/post-pr-review.sh"

  export SHA="d53a7fc6b0718dd3d672fed4eec8394e5d372900"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/1703"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  export REVIEW_OUT="$TEST_DIR/posted_review.txt";   : > "$REVIEW_OUT"
  export COMMENT_OUT="$TEST_DIR/posted_comment.txt"; : > "$COMMENT_OUT"
  export PATCH_OUT="$TEST_DIR/patched_comment.txt";  : > "$PATCH_OUT"
  export EVENTS="$TEST_DIR/label_events.txt";        : > "$EVENTS"
  export EXISTING_COMMENTS_FILE="$TEST_DIR/existing_comments.json"
  echo '[]' > "$EXISTING_COMMENTS_FILE"
  export LABELS_JSON='{"labels":[]}'
  export POSTED_REVIEWS_FILE="$TEST_DIR/posted_reviews.json"
  echo '[]' > "$POSTED_REVIEWS_FILE"

  export LABELS_FILE="$TEST_DIR/labels.json"
  export LABEL_EVENTS_FILE="$TEST_DIR/label_timeline.json"
  echo '[]' > "$LABEL_EVENTS_FILE"

  cat > "$TEST_DIR/bin/gh" <<'GHEOF'
#!/bin/bash
sub1="${1:-}"; sub2="${2:-}"

# Model the PR's label set as a mutable file so add/remove-label are reflected
# by a subsequent read — post-pr-review.sh now confirms label state after a
# mutation (#1754). Lazily seed it from LABELS_JSON on first touch.
_labels_init() {
  if [ ! -f "${LABELS_FILE:-/dev/null}" ]; then
    local seed="${LABELS_JSON:-}"
    [ -n "$seed" ] || seed='{"labels":[]}'
    printf '%s' "$seed" > "${LABELS_FILE:-/dev/null}"
  fi
}

if [ "$sub1" = "api" ]; then
  method="GET"; path=""; jqf=""; slurp="false"; prev=""
  for a in "$@"; do
    case "$prev" in
      -X) method="$a" ;;
      --jq) jqf="$a" ;;
    esac
    case "$a" in
      --slurp) slurp="true" ;;
      repos/*) path="$a" ;;
    esac
    prev="$a"
  done
  case "$path" in
    *contents/*) exit 1 ;;                                   # no CODEOWNERS
    */issues/*/comments)
      if [ "$slurp" = "true" ]; then
        jq -s '.' "${EXISTING_COMMENTS_FILE:-/dev/null}"
      else
        cat "${EXISTING_COMMENTS_FILE:-/dev/null}"
      fi
      exit 0 ;;
    */issues/*/events*)
      cat "${LABEL_EVENTS_FILE:-/dev/null}"
      exit 0 ;;
    */pulls/*/reviews)
      if [ "$slurp" = "true" ]; then
        jq -s '.' "${POSTED_REVIEWS_FILE:-/dev/null}"
      else
        cat "${POSTED_REVIEWS_FILE:-/dev/null}"
      fi
      exit 0 ;;
  esac
  if [ "$method" = "PATCH" ]; then
    case "$path" in
      */issues/comments/*)
        if [ -n "${PATCH_FAILS:-}" ]; then cat >/dev/null; exit 1; fi
        cat > "${PATCH_OUT:-/dev/null}"; exit 0 ;;
    esac
  fi
  exit 0
fi

if [ "$sub1" = "pr" ] && [ "$sub2" = "review" ]; then
  prev=""; for a in "$@"; do
    [ "$prev" = "--body" ] && printf '%s' "$a" > "${REVIEW_OUT:-/dev/null}"
    [ "$a" = "--approve" ] && printf '[{"id":1,"state":"APPROVED","user":{"login":"%s"},"commit_id":"%s","submitted_at":"2026-09-21T03:25:39Z","body":""}]' "${BOT_USER:-donpetry-bot}" "$SHA" > "${POSTED_REVIEWS_FILE:-/dev/null}"
    prev="$a"
  done
  exit 0
fi

if [ "$sub1" = "pr" ] && [ "$sub2" = "comment" ]; then
  [ -n "${COMMENT_FAILS:-}" ] && exit 1
  prev=""; for a in "$@"; do
    [ "$prev" = "--body" ] && printf '%s' "$a" > "${COMMENT_OUT:-/dev/null}"
    prev="$a"
  done
  exit 0
fi

if [ "$sub1" = "pr" ] && [ "$sub2" = "view" ]; then
  jqf=""; json=""; prev=""
  for a in "$@"; do
    [ "$prev" = "--jq" ]  && jqf="$a"
    [ "$prev" = "--json" ] && json="$a"
    prev="$a"
  done
  case "$json" in
    *labels*)          _labels_init; data="$(cat "${LABELS_FILE:-/dev/null}")" ;;
    *mergeStateStatus*) data='{"mergeStateStatus":"UNKNOWN"}' ;;
    *)                 data='{}' ;;
  esac
  if [ -n "$jqf" ]; then printf '%s' "$data" | jq -r "$jqf"; else printf '%s' "$data"; fi
  exit 0
fi

if [ "$sub1" = "pr" ] && [ "$sub2" = "edit" ]; then
  args="$*"
  _labels_init
  case "$args" in
    *"--add-label needs-human-review"*)
      echo "ADD_LABEL" >> "${EVENTS:-/dev/null}"
      jq '.labels |= (map(.name) + ["needs-human-review"] | unique | map({name: .}))' \
        "$LABELS_FILE" > "$LABELS_FILE.tmp" && mv "$LABELS_FILE.tmp" "$LABELS_FILE" ;;
    *"--remove-label needs-human-review"*)
      echo "REMOVE_LABEL" >> "${EVENTS:-/dev/null}"
      jq '.labels |= map(select(.name != "needs-human-review"))' \
        "$LABELS_FILE" > "$LABELS_FILE.tmp" && mv "$LABELS_FILE.tmp" "$LABELS_FILE" ;;
  esac
  exit 0
fi

exit 0
GHEOF
  chmod +x "$TEST_DIR/bin/gh"
  export PATH="$TEST_DIR/bin:$PATH"

  export PR_HEAD_SHA="$SHA"
  export DRY_RUN="false"
  export AI_DELEGATION_ENABLED="false"   # force the human-escalation branch
  export REVIEW_CYCLE="3"
  export MAX_REVIEW_CYCLES="3"
  export BOT_USER="donpetry-bot"         # the escalation-comment author (#1754)
  export LABEL_RETRY_DELAY="0"           # no real sleeps between confirm retries
}

teardown() { rm -rf "$TEST_DIR"; }

write_escalate_verdict() {
  local f="$TEST_DIR/verdict.json"
  jq -n '{decision:"escalate", risk:"LOW", summary:"needs a human", body:"- some finding"}' > "$f"
  echo "$f"
}

write_approve_verdict() {
  # $1 = body content
  local f="$TEST_DIR/verdict.json"
  jq -n --arg b "$1" '{decision:"approve", risk:"LOW", summary:"lgtm", body:$b}' > "$f"
  echo "$f"
}

# ── AC1 ─────────────────────────────────────────────────────────────────────
@test "AC1: human-escalation exits 101 (escalated), not 0 (posted)" {
  local vf; vf=$(write_escalate_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 101 ]
}

# ── AC2 ─────────────────────────────────────────────────────────────────────
@test "AC2: escalation posts a marker-keyed comment when none exists" {
  local vf; vf=$(write_escalate_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  cat "$COMMENT_OUT" >&2
  [ "$status" -eq 101 ]
  grep -q '<!-- pr-review-agent human-escalation v1 -->' "$COMMENT_OUT"
  grep -q 'escalated to human' "$COMMENT_OUT"
  grep -q '3/3' "$COMMENT_OUT"
  grep -q '\*\*Reviewer summary:\*\* needs a human' "$COMMENT_OUT"
  grep -q 'remove the `needs-human-review` label to re-engage' "$COMMENT_OUT"
  grep -q "$SHA" "$COMMENT_OUT"
}

@test "AC2: re-escalation updates the existing comment in place (no new comment)" {
  # Existing marker-keyed comment already on the PR (id 555), authored by the bot.
  jq -n '[{"id":555,"user":{"login":"donpetry-bot"},"body":"<!-- pr-review-agent human-escalation v1 -->\nold escalation note"}]' \
    > "$EXISTING_COMMENTS_FILE"

  local vf; vf=$(write_escalate_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2

  [ "$status" -eq 101 ]
  # Updated in place: the PATCH body was captured and carries the marker.
  grep -q '<!-- pr-review-agent human-escalation v1 -->' "$PATCH_OUT"
  # The patched body carries the CURRENT details, not the old note.
  grep -q 'Reviewer summary' "$PATCH_OUT"
  grep -q 'needs a human' "$PATCH_OUT"
  grep -q '3/3' "$PATCH_OUT"
  ! grep -q 'old escalation note' "$PATCH_OUT"
  # And NO brand-new comment was appended.
  [ ! -s "$COMMENT_OUT" ]
}

@test "AC2: a human-authored comment quoting the marker is NOT patched over (#1754)" {
  # A maintainer pasted the marker into their own comment (id 777). It must not
  # be selected for the in-place PATCH; a fresh agent comment is posted instead.
  jq -n '[{"id":777,"user":{"login":"a-maintainer"},"body":"<!-- pr-review-agent human-escalation v1 -->\nquoting this in my note"}]' \
    > "$EXISTING_COMMENTS_FILE"

  local vf; vf=$(write_escalate_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2

  [ "$status" -eq 101 ]
  # No PATCH of the human's comment; a brand-new agent comment was posted.
  [ ! -s "$PATCH_OUT" ]
  grep -q '<!-- pr-review-agent human-escalation v1 -->' "$COMMENT_OUT"
}

@test "AC2: a failed in-place PATCH falls back to posting a fresh comment (#1754)" {
  # Existing bot-authored marker comment (id 555), but PATCH fails. The
  # escalation must still leave a visible artifact via a fresh comment.
  jq -n '[{"id":555,"user":{"login":"donpetry-bot"},"body":"<!-- pr-review-agent human-escalation v1 -->\nold note"}]' \
    > "$EXISTING_COMMENTS_FILE"
  export PATCH_FAILS=1

  local vf; vf=$(write_escalate_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2

  [ "$status" -eq 101 ]
  grep -q '<!-- pr-review-agent human-escalation v1 -->' "$COMMENT_OUT"
}

# ── AC3 ─────────────────────────────────────────────────────────────────────
@test "AC3: label is added when absent" {
  export LABELS_JSON='{"labels":[]}'
  local vf; vf=$(write_escalate_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  grep -q 'ADD_LABEL' "$EVENTS"
}

@test "AC3: label is NOT re-added when already present (no churn)" {
  export LABELS_JSON='{"labels":[{"name":"needs-human-review"}]}'
  local vf; vf=$(write_escalate_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  # No add-label event, and no remove-label event either — zero churn.
  run grep -q 'ADD_LABEL' "$EVENTS"
  [ "$status" -eq 1 ]
  run grep -q 'REMOVE_LABEL' "$EVENTS"
  [ "$status" -eq 1 ]
}

# ── AC4 ─────────────────────────────────────────────────────────────────────
@test "AC4: approve with empty body fails closed and submits nothing" {
  local vf; vf=$(write_approve_verdict "")
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  [ ! -s "$REVIEW_OUT" ]
  [ "$(cat "$POSTED_REVIEWS_FILE")" = "[]" ]
}

@test "AC4: approve with a marker-less body fails closed and submits nothing" {
  local vf; vf=$(write_approve_verdict "## Looks good, no marker here")
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  [ ! -s "$REVIEW_OUT" ]
  [ "$(cat "$POSTED_REVIEWS_FILE")" = "[]" ]
}

@test "AC4: approve with a marked, non-empty body is submitted" {
  local body="<!-- pr-review-agent v1 sha=${SHA} decision=approved risk=LOW -->

## Automated review — APPROVED"
  local vf; vf=$(write_approve_verdict "$body")
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  grep -q '<!-- pr-review-agent v1 sha=' "$REVIEW_OUT"
}

@test "AC4: approve with a current-SHA fix-request marker fails closed (#1754)" {
  # sha matches head, but the decision is fix-requested (sha and decision in
  # SEPARATE markers) — this must NOT reach gh pr review --approve.
  local body="<!-- pr-review-agent v1 sha=${SHA} --> <!-- decision=fix-requested risk=LOW -->

## Review — fix requested"
  local vf; vf=$(write_approve_verdict "$body")
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  [ ! -s "$REVIEW_OUT" ]
  [ "$(cat "$POSTED_REVIEWS_FILE")" = "[]" ]
}

@test "AC4: approve with a current-SHA but decision-less marker fails closed (#1754)" {
  # Right SHA, valid v1 marker, but no decision=approved anywhere → fail closed.
  local body="<!-- pr-review-agent v1 sha=${SHA} risk=LOW -->

## Some review with no decision"
  local vf; vf=$(write_approve_verdict "$body")
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  [ ! -s "$REVIEW_OUT" ]
  [ "$(cat "$POSTED_REVIEWS_FILE")" = "[]" ]
}

@test "AC4: approve with a prose-quoted marker (no HTML comment) fails closed" {
  local body="The agent wrote pr-review-agent v1 sha=${SHA} decision=approved in prose, not a marker."
  local vf; vf=$(write_approve_verdict "$body")
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  [ ! -s "$REVIEW_OUT" ]
  [ "$(cat "$POSTED_REVIEWS_FILE")" = "[]" ]
}

@test "AC4: approve with a valid marker for a STALE sha fails closed before gh pr review" {
  local old="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  local body="<!-- pr-review-agent v1 sha=${old} decision=approved risk=LOW -->

## Automated review — APPROVED"
  local vf; vf=$(write_approve_verdict "$body")
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match PR_HEAD_SHA"* ]]
  [ ! -s "$REVIEW_OUT" ]
  [ "$(cat "$POSTED_REVIEWS_FILE")" = "[]" ]
}

# ── #2169: the marker word is derived from the verdict, not model text ──────
# prompts/cascade-action.md substituted the verdict's raw `decision` value
# (`approve`) into the marker, while the #1754 guard requires `decision=approved`.
# A valid approve verdict then failed on formatting alone and nothing was posted.

@test "#2169: approve verdict whose marker says decision=approve is submitted as decision=approved" {
  local body="<!-- pr-review-agent v1 sha=${SHA} decision=approve risk=MEDIUM -->

## Automated review — APPROVED ✓"
  local vf; vf=$(write_approve_verdict "$body")
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [[ "$output" != *"lacks a complete approval marker"* ]]
  grep -qF "<!-- pr-review-agent v1 sha=${SHA} decision=approved risk=MEDIUM -->" "$REVIEW_OUT"
  ! grep -qE 'decision=approve([[:space:]]|-->)' "$REVIEW_OUT"
}

@test "#2169: decision=approve directly before the marker close is normalized too" {
  local body="<!-- pr-review-agent v1 sha=${SHA} risk=LOW decision=approve-->

## Automated review — APPROVED ✓"
  local vf; vf=$(write_approve_verdict "$body")
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  grep -qF "decision=approved-->" "$REVIEW_OUT"
}

@test "#2169: decision=approve for a STALE sha still fails closed" {
  local old="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  local body="<!-- pr-review-agent v1 sha=${old} decision=approve risk=LOW -->

## Automated review — APPROVED ✓"
  local vf; vf=$(write_approve_verdict "$body")
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  [ ! -s "$REVIEW_OUT" ]
  [ "$(cat "$POSTED_REVIEWS_FILE")" = "[]" ]
}

@test "#2169: an approve verdict whose marker contradicts it (decision=escalate) still fails closed" {
  local body="<!-- pr-review-agent v1 sha=${SHA} decision=escalate risk=HIGH -->

## Automated review — NEEDS HUMAN REVIEW"
  local vf; vf=$(write_approve_verdict "$body")
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  [[ "$output" == *"lacks a complete approval marker"* ]]
  [ ! -s "$REVIEW_OUT" ]
  [ "$(cat "$POSTED_REVIEWS_FILE")" = "[]" ]
}

@test "#2169: decision=approve outside the v1 marker (prose) is not rewritten and still fails closed" {
  local body="<!-- pr-review-agent v1 sha=${SHA} risk=LOW -->

The verdict was decision=approve in prose only."
  local vf; vf=$(write_approve_verdict "$body")
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  [ ! -s "$REVIEW_OUT" ]
}

@test "#2169: cascade-action prompt maps the decision word before substituting the marker" {
  local prompt="$REPO_ROOT/prompts/cascade-action.md"
  grep -qF 'DECISION_MARKER=$([ "$DECISION" = "approve" ] && echo "approved" || echo "escalated")' "$prompt"
  grep -qF 's|PLACEHOLDER_DECISION|$DECISION_MARKER|g' "$prompt"
  ! grep -qF 's|PLACEHOLDER_DECISION|$DECISION|g' "$prompt"
}

@test "AC2: exit 100 (not 101) when no escalation comment can be confirmed" {
  export COMMENT_FAILS=1
  local vf; vf=$(write_escalate_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 100 ]
  [[ "$output" == *"::error::escalation: no human-escalation comment"* ]]
}

# ── fix-request hold provenance ─────────────────────────────────────────────
fix_request_setup() {
  export AI_DELEGATION_ENABLED="true"
  export REVIEW_CYCLE="1"
  export RISK="LOW"
  export METADATA_ONLY="false"
  export LABELS_JSON='{"labels":[{"name":"needs-human-review"}]}'
}

@test "fix-request clears an automation-set hold" {
  fix_request_setup
  echo '[{"event":"labeled","label":{"name":"needs-human-review"},"actor":{"login":"github-actions[bot]"}}]' > "$LABEL_EVENTS_FILE"
  local vf; vf=$(write_escalate_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  grep -q 'REMOVE_LABEL' "$EVENTS"
}

@test "fix-request leaves a human-set hold in place" {
  fix_request_setup
  echo '[{"event":"labeled","label":{"name":"needs-human-review"},"actor":{"login":"a-maintainer"}}]' > "$LABEL_EVENTS_FILE"
  local vf; vf=$(write_escalate_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  ! grep -q 'REMOVE_LABEL' "$EVENTS"
}

@test "fix-request with undeterminable hold provenance leaves the hold (fail closed)" {
  fix_request_setup
  local vf; vf=$(write_escalate_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  [ "$status" -eq 0 ]
  ! grep -q 'REMOVE_LABEL' "$EVENTS"
}

@test "fix-request does not clear the hold when the comment fails to post" {
  fix_request_setup
  echo '[{"event":"labeled","label":{"name":"needs-human-review"},"actor":{"login":"github-actions[bot]"}}]' > "$LABEL_EVENTS_FILE"
  export COMMENT_FAILS=1
  local vf; vf=$(write_escalate_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 1 ]
  ! grep -q 'REMOVE_LABEL' "$EVENTS"
}

@test "approve clears an automation-set hold with confirmation" {
  export LABELS_JSON='{"labels":[{"name":"needs-human-review"}]}'
  echo '[{"event":"labeled","label":{"name":"needs-human-review"},"actor":{"login":"donpetry-bot"}}]' > "$LABEL_EVENTS_FILE"
  local body="<!-- pr-review-agent v1 sha=${SHA} decision=approved risk=LOW -->

## Automated review — APPROVED"
  local vf; vf=$(write_approve_verdict "$body")
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  grep -q 'REMOVE_LABEL' "$EVENTS"
}
