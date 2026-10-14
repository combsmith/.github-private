#!/usr/bin/env bats
# Unit tests for scripts/lib/deferred-thread-verify.sh (#2045).
#
# A bot review thread whose finding dev-lead defers as out of scope had no outcome:
# the skip reply carried no marker, so the thread stayed unresolved forever and
# blocked merge (PR #1953). The deferral marker `<!-- dev-lead:deferred ref=#<n> -->`
# lets the harness resolve the thread once the cited tracking issue is open and
# links the thread. These tests exercise the pure helpers; the harness wiring is
# covered in test_fix_reviews.bats.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/deferred-thread-verify.sh"

THREAD_ID="PRRT_kwDOabc123"
DB_ID="2401234567"
LINK="https://github.com/petry-projects/.github-private/pull/1953#discussion_r${DB_ID}"

setup() {
  # shellcheck source=scripts/lib/deferred-thread-verify.sh
  source "$LIB"
}

@test "deferred-thread-verify.sh is safe to source under set -euo pipefail" {
  run bash -c "set -euo pipefail; source '$LIB'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── dtv_parse_deferral ───────────────────────────────────────────────────────

@test "dtv_parse_deferral: a single well-formed marker yields the issue number" {
  run dtv_parse_deferral "Valid, but deferring — out of scope. Tracked in #2050.

<!-- dev-lead:deferred ref=#2050 -->"
  [ "$status" -eq 0 ]
  [ "$output" = "2050" ]
}

@test "dtv_parse_deferral: replies carrying an addressed-marker or claim are rejected" {
  local marker
  for marker in '<!-- dev-lead:addressed -->' '<!-- dev-lead:claim {"v":1} -->'; do
    run dtv_parse_deferral "Deferring. Tracked in #2050.

${marker}
<!-- dev-lead:deferred ref=#2050 -->"
    [ "$status" -eq 1 ]
    [ "$output" = "mixed-addressed" ]
  done
}

@test "dtv_parse_deferral: no marker -> no-deferral" {
  run dtv_parse_deferral "Valid, but deferring — out of scope for this PR."
  [ "$status" -eq 1 ]
  [ "$output" = "no-deferral" ]
}

@test "dtv_parse_deferral: empty body -> no-deferral" {
  run dtv_parse_deferral ""
  [ "$status" -eq 1 ]
  [ "$output" = "no-deferral" ]
}

@test "dtv_parse_deferral: more than one marker -> multiple-deferrals" {
  run dtv_parse_deferral "<!-- dev-lead:deferred ref=#2050 -->
<!-- dev-lead:deferred ref=#2050 -->"
  [ "$status" -eq 1 ]
  [ "$output" = "multiple-deferrals" ]
}

@test "dtv_parse_deferral: marker without ref -> missing-ref" {
  run dtv_parse_deferral "<!-- dev-lead:deferred -->"
  [ "$status" -eq 1 ]
  [ "$output" = "missing-ref" ]
}

@test "dtv_parse_deferral: empty ref value -> bad-ref" {
  run dtv_parse_deferral "<!-- dev-lead:deferred ref= -->"
  [ "$status" -eq 1 ]
  [ "$output" = "bad-ref" ]
}

@test "dtv_parse_deferral: ref without # or non-numeric -> bad-ref" {
  run dtv_parse_deferral "<!-- dev-lead:deferred ref=2050 -->"
  [ "$status" -eq 1 ]
  [ "$output" = "bad-ref" ]
  run dtv_parse_deferral "<!-- dev-lead:deferred ref=#abc -->"
  [ "$status" -eq 1 ]
  [ "$output" = "bad-ref" ]
  run dtv_parse_deferral "<!-- dev-lead:deferred ref=#0 -->"
  [ "$status" -eq 1 ]
  [ "$output" = "bad-ref" ]
}

@test "dtv_parse_deferral: cross-repo ref -> bad-ref" {
  run dtv_parse_deferral "<!-- dev-lead:deferred ref=other/repo#12 -->"
  [ "$status" -eq 1 ]
  [ "$output" = "bad-ref" ]
}

@test "dtv_parse_deferral: two ref keys are ambiguous -> bad-ref" {
  run dtv_parse_deferral "<!-- dev-lead:deferred ref=#1 ref=#2 -->"
  [ "$status" -eq 1 ]
  [ "$output" = "bad-ref" ]
}

@test "dtv_parse_deferral: unclosed marker -> malformed" {
  run dtv_parse_deferral "<!-- dev-lead:deferred ref=#2050"
  [ "$status" -eq 1 ]
  [ "$output" = "malformed" ]
}

@test "dtv_parse_deferral: a look-alike marker name is not a deferral" {
  run dtv_parse_deferral "<!-- dev-lead:deferredX ref=#2050 -->"
  [ "$status" -eq 1 ]
  [ "$output" = "malformed" ]
}

@test "dtv_parse_deferral: the deferral marker counts as agent-authored (never a maintainer finding)" {
  source "$SCRIPT_DIR/scripts/lib/maintainer-review-thread-gate.sh"
  review_thread_is_agent_authored "Deferring. <!-- dev-lead:deferred ref=#2050 -->"
}

# ── dtv_latest_own_reply_index ───────────────────────────────────────────────

@test "dtv_latest_own_reply_index: returns the LAST our-account comment" {
  local c='[{"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"body":"finding"},
            {"author":{"login":"donpetry-bot","__typename":"User"},"body":"first"},
            {"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"body":"ack"},
            {"author":{"login":"donpetry-bot","__typename":"User"},"body":"second"}]'
  run dtv_latest_own_reply_index "$c" "donpetry-bot"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "dtv_latest_own_reply_index: matches the [bot]-stripped login" {
  local c='[{"author":{"login":"x","__typename":"Bot"},"body":"f"},{"author":{"login":"donpetry-bot","__typename":"Bot"},"body":"r"}]'
  run dtv_latest_own_reply_index "$c" "donpetry-bot[bot]"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "dtv_latest_own_reply_index: no reply from our account -> 1" {
  local c='[{"author":{"login":"x","__typename":"Bot"},"body":"f"},{"author":{"login":"someone","__typename":"User"},"body":"<!-- dev-lead:deferred ref=#1 -->"}]'
  run dtv_latest_own_reply_index "$c" "donpetry-bot"
  [ "$status" -eq 1 ]
}

@test "dtv_latest_own_reply_index: unparseable JSON -> 1" {
  run dtv_latest_own_reply_index "not json" "donpetry-bot"
  [ "$status" -eq 1 ]
}

# ── dtv_text_mentions_thread ─────────────────────────────────────────────────

@test "dtv_text_mentions_thread: the originating comment URL counts" {
  run dtv_text_mentions_thread "- [ ] duration_ms missing — ${LINK}" "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 0 ]
}

@test "dtv_text_mentions_thread: the thread node id counts" {
  run dtv_text_mentions_thread "thread ${THREAD_ID}: deferred" "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 0 ]
}

@test "dtv_text_mentions_thread: a different discussion anchor is not a mention" {
  run dtv_text_mentions_thread "see #discussion_r${DB_ID}9 and PRRT_kwDOabc1234" "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 1 ]
}

@test "dtv_text_mentions_thread: empty text or unusable ids -> 1" {
  run dtv_text_mentions_thread "" "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 1 ]
  run dtv_text_mentions_thread "anything .* goes" ".*" "abc"
  [ "$status" -eq 1 ]
}

# ── dtv_verify_tracking_issue ────────────────────────────────────────────────

@test "dtv_verify_tracking_issue: open issue whose body links the thread -> ok" {
  local issue
  issue=$(jq -cn --arg b "Deferred findings:\n- ${LINK}" '{number:2050,title:"dev-lead: deferred review findings",author_association:"MEMBER",state:"open",body:$b}')
  run dtv_verify_tracking_issue "$issue" "[]" "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "dtv_verify_tracking_issue: open issue whose COMMENT links the thread -> ok" {
  local comments
  comments=$(jq -cn --arg b "Appended: ${LINK}" '[{author_association:"MEMBER",body:"unrelated"},{author_association:"MEMBER",body:$b}]')
  run dtv_verify_tracking_issue '{"number":2050,"title":"dev-lead: deferred review findings","author_association":"MEMBER","state":"open","body":"Deferred findings"}' \
    "$comments" "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "dtv_verify_tracking_issue: a link only in an UNTRUSTED author's issue body -> untrusted-mention" {
  local issue
  issue=$(jq -cn --arg b "Deferred findings:\n- ${LINK}" '{number:2050,title:"dev-lead: deferred review findings",author_association:"NONE",state:"open",body:$b}')
  run dtv_verify_tracking_issue "$issue" "[]" "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 1 ]
  [ "$output" = "untrusted-mention" ]
}

@test "dtv_verify_tracking_issue: a link only in an UNTRUSTED comment -> untrusted-mention" {
  local comments
  comments=$(jq -cn --arg b "Appended: ${LINK}" '[{author_association:"CONTRIBUTOR",body:$b}]')
  run dtv_verify_tracking_issue '{"number":2050,"title":"dev-lead: deferred review findings","author_association":"MEMBER","state":"open","body":"Deferred findings"}' \
    "$comments" "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 1 ]
  [ "$output" = "untrusted-mention" ]
}

@test "dtv_verify_tracking_issue: a TRUSTED comment links the thread on an untrusted author's issue -> ok" {
  local comments
  comments=$(jq -cn --arg b "Appended: ${LINK}" '[{author_association:"NONE",body:"spam"},{author_association:"COLLABORATOR",body:$b}]')
  run dtv_verify_tracking_issue '{"number":2050,"title":"dev-lead: deferred review findings","author_association":"NONE","state":"open","body":"Deferred findings"}' \
    "$comments" "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "dtv_verify_tracking_issue: missing / nonexistent issue -> missing" {
  run dtv_verify_tracking_issue "" "[]" "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 1 ]
  [ "$output" = "missing" ]
  run dtv_verify_tracking_issue '{"message":"Not Found","status":"404"}' "[]" "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 1 ]
  [ "$output" = "missing" ]
}

@test "dtv_verify_tracking_issue: closed issue -> closed" {
  local issue
  issue=$(jq -cn --arg b "${LINK}" '{number:2050,title:"dev-lead: deferred review findings",author_association:"MEMBER",state:"closed",body:$b}')
  run dtv_verify_tracking_issue "$issue" "[]" "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 1 ]
  [ "$output" = "closed" ]
}

@test "dtv_verify_tracking_issue: a pull request is not a tracking issue" {
  local issue
  issue=$(jq -cn --arg b "${LINK}" '{number:2050,title:"dev-lead: deferred review findings",author_association:"MEMBER",state:"open",body:$b,pull_request:{url:"x"}}')
  run dtv_verify_tracking_issue "$issue" "[]" "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 1 ]
  [ "$output" = "not-an-issue" ]
}

@test "dtv_verify_tracking_issue: issue that does not mention the thread -> no-mention" {
  run dtv_verify_tracking_issue '{"number":2050,"title":"dev-lead: deferred review findings","author_association":"MEMBER","state":"open","body":"Deferred findings"}' \
    '[{"body":"some other thread #discussion_r1"}]' "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 1 ]
  [ "$output" = "no-mention" ]
}

@test "dtv_verify_tracking_issue: unparseable comments read as none (fail closed)" {
  run dtv_verify_tracking_issue '{"number":2050,"title":"dev-lead: deferred review findings","author_association":"MEMBER","state":"open","body":"x"}' "garbage" "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 1 ]
  [ "$output" = "no-mention" ]
}

@test "dtv_parse_deferral: text after the marker is malformed (marker must end the reply)" {
  run dtv_parse_deferral "Deferring. <!-- dev-lead:deferred ref=#2050 --> trailing prose"
  [ "$status" -eq 1 ]
  [ "$output" = "malformed" ]
}

@test "dtv_text_mentions_thread: bare discussion_r token in prose is not a link" {
  run dtv_text_mentions_thread "see discussion_r${DB_ID} for context" "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 1 ]
}

# ── review-round hardening ───────────────────────────────────────────────────

@test "dtv_parse_deferral: stray attribute tokens beside a valid ref -> bad-ref" {
  run dtv_parse_deferral "<!-- dev-lead:deferred junk ref=#2050 -->"
  [ "$status" -eq 1 ]
  [ "$output" = "bad-ref" ]
  run dtv_parse_deferral "<!-- dev-lead:deferred ref=#2050 extra -->"
  [ "$status" -eq 1 ]
  [ "$output" = "bad-ref" ]
}

@test "dtv_text_mentions_thread: scoped to repo+PR; other PR or repo is not a mention" {
  local url="https://github.com/petry-projects/.github-private/pull/54#discussion_r${DB_ID}"
  run dtv_text_mentions_thread "$url" "$THREAD_ID" "$DB_ID" "petry-projects/.github-private" "54"
  [ "$status" -eq 0 ]
  run dtv_text_mentions_thread "$url" "$THREAD_ID" "$DB_ID" "petry-projects/.github-private" "55"
  [ "$status" -eq 1 ]
  run dtv_text_mentions_thread "$url" "$THREAD_ID" "$DB_ID" "other/repo" "54"
  [ "$status" -eq 1 ]
}

@test "dtv_text_mentions_thread: a letter suffix after the comment id is not a mention" {
  run dtv_text_mentions_thread "https://github.com/o/r/pull/54#discussion_r${DB_ID}x" "$THREAD_ID" "$DB_ID" "o/r" "54"
  [ "$status" -eq 1 ]
}

@test "dtv_verify_tracking_issue: non-tracker title -> wrong-title" {
  local issue
  issue=$(jq -cn --arg b "${LINK}" '{number:7,title:"per-finding issue",state:"open",body:$b}')
  run dtv_verify_tracking_issue "$issue" "[]" "$THREAD_ID" "$DB_ID"
  [ "$status" -eq 1 ]
  [ "$output" = "wrong-title" ]
}

@test "dtv_text_mentions_thread: a host merely ending in github.com is not a link" {
  run dtv_text_mentions_thread "https://evilgithub.com/o/r/pull/54#discussion_r${DB_ID}" "$THREAD_ID" "$DB_ID" "o/r" "54"
  [ "$status" -eq 1 ]
}
