#!/usr/bin/env bats
# Unit tests for the undispositioned bot-comment retry (#2017).
#
# A registered reviewer bot's PR issue comment is dispositioned ONLY by
# dev-lead's fix-bot-comment intent. When that run is lost (superseded while
# pending in the per-PR concurrency lane — the #2009 case), nothing retried it and
# the PR stalled at the maintainer-comment gate. These tests pin:
#   • the pure decision (lib/bot-comment-retry.sh, bcr_retry_decisions);
#   • the sweep wiring in dev-lead-retry.sh (exactly one dispatch, dedup marker,
#     payload carries the comment node id — never its body).

bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/bot-comment-retry.sh"
RETRY_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-retry.sh"

TRUSTED='coderabbitai[bot],codeant-ai[bot],chatgpt-codex-connector[bot]'
INFO='{"chatgpt-codex-connector":"^You have reached your Codex usage limits"}'
# The logins our own automation posts markers as (dev-lead, pr-review).
AUTOMATION='don-petry,donpetry-bot'
# 2026-10-02T01:00:00Z — two hours after the comments below were posted.
NOW_EPOCH=1790902800

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
  export BOT_COMMENT_RETRY_MIN_AGE_SEC=900
  export BOT_COMMENT_RETRY_PENDING_SEC=9000
  export BOT_COMMENT_RETRY_MAX_ATTEMPTS=2
}

# _bot <id> <login> <body> [createdAt] [lastEditedAt] [minimizedReason]
_bot() {
  jq -nc --arg id "$1" --arg l "$2" --arg b "$3" \
    --arg c "${4:-2026-10-01T23:05:43Z}" --arg e "${5:-}" --arg m "${6:-}" '
    {id:$id, author:{login:$l, __typename:"Bot"}, authorAssociation:"NONE",
     body:$b, createdAt:$c, lastEditedAt:(if $e == "" then null else $e end),
     isMinimized:($m != ""), minimizedReason:(if $m == "" then null else $m end)}'
}

# _ours <body> [createdAt] [association] [login] — a comment from our own automation.
_ours() {
  jq -nc --arg b "$1" --arg c "${2:-2026-10-01T23:30:00Z}" --arg a "${3:-OWNER}" --arg l "${4:-don-petry}" '
    {id:("IC_ours_" + ($c | gsub("[^0-9]";"")) + "_" + $l), author:{login:$l, __typename:"User"},
     authorAssociation:$a, body:$b, createdAt:$c, lastEditedAt:null,
     isMinimized:false, minimizedReason:null}'
}

_decide() {
  local comments
  comments="$(jq -sc '.' <<< "$*")"
  bcr_retry_decisions "$comments" "$TRUSTED" "$INFO" "$NOW_EPOCH" "$AUTOMATION"
}

_dispatches() { jq -r '[.[] | select(.decision == "dispatch")] | length' <<< "$1"; }
_reason_for() { jq -r --arg id "$2" 'first(.[] | select(.id == $id)) | .reason // "none"' <<< "$1"; }

# ── bcr_retry_decisions: AC5 matrix ──────────────────────────────────────────

@test "bcr: registered-bot comment, no disposition, no info-status match → exactly one dispatch" {
  out="$(_decide "$(_bot IC_cr coderabbitai 'Walkthrough: summary of changes')")"
  [ "$(_dispatches "$out")" = "1" ]
  [ "$(jq -r '.[0].id' <<< "$out")" = "IC_cr" ]
  [ "$(jq -r '.[0].attempt' <<< "$out")" = "1" ]
  [ "$(jq -r '.[0].version' <<< "$out")" = "2026-10-01T23:05:43Z" ]
}

@test "bcr: a comment with a current disposition dispatches none" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead:comment-disposition id=IC_cr disposition=informational -->
Summary only, nothing to fix.')")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "dispositioned" ]
}

@test "bcr: a disposition that PREDATES an edit does not cover the edited comment" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough v2' 2026-10-01T23:05:43Z 2026-10-01T23:40:00Z)" \
    "$(_ours '<!-- dev-lead:comment-disposition id=IC_cr disposition=informational -->
ok' 2026-10-01T23:30:00Z)")"
  [ "$(_dispatches "$out")" = "1" ]
  [ "$(jq -r '.[0].version' <<< "$out")" = "2026-10-01T23:40:00Z" ]
}

@test "bcr: a disposition citing ANOTHER comment does not cover this one" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead:comment-disposition id=IC_cr2 disposition=informational -->
ok')")"
  [ "$(_dispatches "$out")" = "1" ]
}

@test "bcr: a disposition marker from an untrusted author is ignored (CWE-863)" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead:comment-disposition id=IC_cr disposition=invalid -->
spoof' 2026-10-01T23:30:00Z NONE)")"
  [ "$(_dispatches "$out")" = "1" ]
}

@test "bcr: a pending/running retry (marker inside the pending window) is not duplicated" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-02T00:30:00Z -->' 2026-10-02T00:30:00Z)")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "retry-pending" ]
}

@test "bcr: a retry marker past the pending window (lost run) re-dispatches as the next attempt" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-01T22:00:00Z -->' 2026-10-01T22:00:00Z)")"
  # NOW - 22:00 = 3h > 150 min pending window → the retry is no longer live.
  [ "$(_dispatches "$out")" = "1" ]
  [ "$(jq -r '.[0].attempt' <<< "$out")" = "2" ]
}

@test "bcr: attempts for this comment version exhausted → no dispatch" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-01T20:00:00Z -->' 2026-10-01T20:00:00Z)" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=2 at=2026-10-01T21:00:00Z -->' 2026-10-01T21:00:00Z)")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "retry-attempts-exhausted" ]
}

@test "bcr: a retry marker for an OLDER version does not block an edited comment" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough v2' 2026-10-01T23:05:43Z 2026-10-02T00:40:00Z)" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-02T00:30:00Z -->' 2026-10-02T00:30:00Z)")"
  [ "$(_dispatches "$out")" = "1" ]
  [ "$(jq -r '.[0].attempt' <<< "$out")" = "1" ]
}

@test "bcr: a fix-bot-comment pass that ENDED without a disposition is not retried" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-fix-reviews pr=2009 sha=abc intent=fix-bot-comment status=no-changes comment=IC_cr -->
## Dev-Lead — fix-bot-comment (no-changes)')")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "pass-completed" ]
}

@test "bcr: a pass that ended BEFORE the comment was edited does not block a retry" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough v2' 2026-10-01T23:05:43Z 2026-10-01T23:50:00Z)" \
    "$(_ours '<!-- dev-lead-fix-reviews pr=2009 sha=abc intent=fix-bot-comment status=no-changes comment=IC_cr -->' 2026-10-01T23:30:00Z)")"
  [ "$(_dispatches "$out")" = "1" ]
}

@test "bcr: a comment still inside the grace period (original run may be pending) → no dispatch" {
  out="$(_decide "$(_bot IC_cr coderabbitai 'Walkthrough' 2026-10-02T00:55:00Z)")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "grace-period" ]
}

@test "bcr: info_status_pattern match is not a candidate" {
  out="$(_decide "$(_bot IC_cx chatgpt-codex-connector 'You have reached your Codex usage limits for code reviews.')")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(jq 'length' <<< "$out")" = "0" ]
}

@test "bcr: a comment already minimized RESOLVED is not a candidate" {
  out="$(_decide "$(_bot IC_cr coderabbitai 'Walkthrough' 2026-10-01T23:05:43Z '' RESOLVED)")"
  [ "$(jq 'length' <<< "$out")" = "0" ]
}

# #2166: the gate re-blocks a RESOLVED bot comment edited after its newest
# disposition, so pr-review's retry hook must dispatch for that stale case too —
# not only for a comment with no disposition at all.
@test "bcr(#2166): a RESOLVED comment edited AFTER its disposition is a candidate and dispatches" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Review limit reached' 2026-10-01T23:05:43Z 2026-10-01T23:40:00Z RESOLVED)" \
    "$(_ours '<!-- dev-lead:comment-disposition id=IC_cr disposition=informational -->
ok' 2026-10-01T23:30:00Z)")"
  [ "$(_dispatches "$out")" = "1" ]
  [ "$(jq -r '.[0].id' <<< "$out")" = "IC_cr" ]
  [ "$(jq -r '.[0].version' <<< "$out")" = "2026-10-01T23:40:00Z" ]
}

@test "bcr(#2166): a RESOLVED comment with a disposition newer than its edit is still not a candidate" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Review limit reached' 2026-10-01T23:05:43Z 2026-10-01T23:20:00Z RESOLVED)" \
    "$(_ours '<!-- dev-lead:comment-disposition id=IC_cr disposition=informational -->
ok' 2026-10-01T23:30:00Z)")"
  [ "$(jq 'length' <<< "$out")" = "0" ]
}

@test "bcr(#2166): a maintainer-resolve reply after the edit keeps a RESOLVED comment out (the gate clears it)" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Review limit reached' 2026-10-01T23:05:43Z 2026-10-01T23:40:00Z RESOLVED)" \
    "$(_ours '<!-- maintainer-resolve id=IC_cr -->
Resolved by the maintainer.' 2026-10-01T23:50:00Z)")"
  [ "$(jq 'length' <<< "$out")" = "0" ]
}

@test "bcr: unregistered bots and humans are not candidates" {
  human="$(jq -nc '{id:"IC_h", author:{login:"alice",__typename:"User"}, authorAssociation:"CONTRIBUTOR",
    body:"please fix", createdAt:"2026-10-01T23:05:43Z", lastEditedAt:null, isMinimized:false, minimizedReason:null}')"
  out="$(_decide "$human" "$(_bot IC_x some-other-bot 'hello')")"
  [ "$(jq 'length' <<< "$out")" = "0" ]
}

@test "bcr: our own agent-marked comments are never candidates" {
  out="$(_decide "$(_bot IC_m coderabbitai '<!-- dev-lead note --> mirrored')")"
  [ "$(jq 'length' <<< "$out")" = "0" ]
}

@test "bcr: node ids with regex metacharacters are compared literally" {
  out="$(_decide \
    "$(_bot 'IC_a+b/c=' coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead:comment-disposition id=IC_aXb/c= disposition=informational -->
ok')")"
  [ "$(_dispatches "$out")" = "1" ]
}

@test "bcr: malformed comments JSON fails closed (non-zero, no decision)" {
  run bcr_retry_decisions 'not-json' "$TRUSTED" "$INFO" "$NOW_EPOCH" "$AUTOMATION"
  [ "$status" -ne 0 ]
}

@test "bcr: no automation logins fails closed (no marker could be trusted)" {
  run bcr_retry_decisions "[$(_bot IC_cr coderabbitai 'Walkthrough')]" "$TRUSTED" "$INFO" "$NOW_EPOCH" ""
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "bcr: a disposition from another repository member (not our automation) is ignored" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead:comment-disposition id=IC_cr disposition=invalid -->
forged' 2026-10-01T23:30:00Z OWNER mallory)")"
  [ "$(_dispatches "$out")" = "1" ]
}

@test "bcr: a retry marker another member pasted does not hold or exhaust the retry" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=9 at=2026-10-02T00:50:00Z -->' 2026-10-02T00:50:00Z MEMBER mallory)")"
  [ "$(_dispatches "$out")" = "1" ]
  [ "$(jq -r '.[0].attempt' <<< "$out")" = "1" ]
}

@test "bcr: pr-review's own retry marker (its scan posts as donpetry-bot) counts as pending" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-02T00:30:00Z -->' 2026-10-02T00:30:00Z MEMBER donpetry-bot)")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "retry-pending" ]
}

@test "bcr: a trusted-bot login whose author type is not Bot is not a candidate" {
  spoof="$(jq -nc '{id:"IC_s", author:{login:"coderabbitai",__typename:"User"}, authorAssociation:"NONE",
    body:"Walkthrough", createdAt:"2026-10-01T23:05:43Z", lastEditedAt:null, isMinimized:false, minimizedReason:null}')"
  out="$(_decide "$spoof")"
  [ "$(jq 'length' <<< "$out")" = "0" ]
}

@test "bcr: a retry marker matches its version by value, not by string format" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43.000Z attempt=1 at=2026-10-02T00:30:00Z -->' 2026-10-02T00:30:00Z)")"
  [ "$(_reason_for "$out" IC_cr)" = "retry-pending" ]
}

@test "bcr: a pass stamped with the version it processed covers that version" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-fix-reviews pr=2009 sha=abc intent=fix-bot-comment status=no-changes comment=IC_cr version=2026-10-01T23:05:43Z -->' 2026-10-01T23:30:00Z)")"
  [ "$(_reason_for "$out" IC_cr)" = "pass-completed" ]
}

@test "bcr: an edit made WHILE a pass ran is not covered by that pass (version stamp predates the edit)" {
  # Pass read the 23:05 body; the bot edited at 23:20; the pass ended (marker) at 23:30.
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough v2' 2026-10-01T23:05:43Z 2026-10-01T23:20:00Z)" \
    "$(_ours '<!-- dev-lead-fix-reviews pr=2009 sha=abc intent=fix-bot-comment status=no-changes comment=IC_cr version=2026-10-01T23:05:43Z -->' 2026-10-01T23:30:00Z)")"
  [ "$(_dispatches "$out")" = "1" ]
}

@test "bcr: a fix-bot-comment pass that ended rate-limited holds retries until its reset" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-fix-reviews pr=2009 sha=abc intent=fix-bot-comment status=rate-limited reason=rate-limited reset=2026-10-02T02:00:00Z -->' 2026-10-01T23:30:00Z)")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "rate-limited" ]
}

@test "bcr: attempts that ran into a rate limit do not exhaust the retry cap" {
  # Two attempts, both followed by a rate-limited end whose reset has passed.
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-01T19:00:00Z -->' 2026-10-01T19:00:00Z)" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=2 at=2026-10-01T21:00:00Z -->' 2026-10-01T21:00:00Z)" \
    "$(_ours '<!-- dev-lead-fix-reviews pr=2009 sha=abc intent=fix-bot-comment status=rate-limited reason=rate-limited reset=2026-10-01T22:00:00Z -->' 2026-10-01T21:10:00Z)")"
  [ "$(_dispatches "$out")" = "1" ]
  # Attempt numbering stays monotonic (the claim check is scoped to it).
  [ "$(jq -r '.[0].attempt' <<< "$out")" = "3" ]
}

@test "bcr: the hard ceiling caps attempts even when every one ran into a rate limit" {
  export BOT_COMMENT_RETRY_MAX_TOTAL=2
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-01T19:00:00Z -->' 2026-10-01T19:00:00Z)" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=2 at=2026-10-01T21:00:00Z -->' 2026-10-01T21:00:00Z)" \
    "$(_ours '<!-- dev-lead-fix-reviews pr=2009 sha=abc intent=fix-bot-comment status=rate-limited reason=rate-limited reset=2026-10-01T22:00:00Z -->' 2026-10-01T21:10:00Z)")"
  [ "$(_reason_for "$out" IC_cr)" = "retry-attempts-exhausted" ]
}

@test "bcr: an automation login with a [bot] suffix still matches a suffix-less GraphQL login" {
  out="$(bcr_retry_decisions "$(jq -sc '.' <<< "$(_bot IC_cr coderabbitai 'Walkthrough')
$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-02T00:30:00Z -->' 2026-10-02T00:30:00Z MEMBER some-app)")" \
    "$TRUSTED" "$INFO" "$NOW_EPOCH" "don-petry,some-app[bot]")"
  [ "$(_reason_for "$out" IC_cr)" = "retry-pending" ]
}

@test "bcr: a pass stamped a second before the comment's lastEditedAt still covers that edit (skew)" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough v2' 2026-10-01T23:05:43Z 2026-10-01T23:20:01Z)" \
    "$(_ours '<!-- dev-lead-fix-reviews pr=2009 sha=abc intent=fix-bot-comment status=no-changes comment=IC_cr version=2026-10-01T23:20:00Z -->' 2026-10-01T23:30:00Z)")"
  [ "$(_reason_for "$out" IC_cr)" = "pass-completed" ]
}

@test "bcr: a pass stamped with the comment's createdAt never covers an edit made seconds later" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough v2' 2026-10-01T23:05:43Z 2026-10-01T23:05:44Z)" \
    "$(_ours '<!-- dev-lead-fix-reviews pr=2009 sha=abc intent=fix-bot-comment status=no-changes comment=IC_cr version=2026-10-01T23:05:43Z -->' 2026-10-01T23:30:00Z)")"
  [ "$(_reason_for "$out" IC_cr)" != "pass-completed" ]
}

# ── bcr_fetch_pr_comments: fails closed on a partial snapshot ────────────────

@test "bcr_fetch_pr_comments: a GraphQL response carrying errors fails closed" {
  gh() { printf '%s' '{"errors":[{"message":"rate limited"}],"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'; }
  run --separate-stderr bcr_fetch_pr_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"GraphQL errors"* ]]
}

@test "bcr_fetch_pr_comments: hasNextPage true without a cursor fails closed" {
  gh() { printf '%s' '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":true,"endCursor":null},"nodes":[]}}}}}'; }
  run --separate-stderr bcr_fetch_pr_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"pagination"* ]]
}

@test "bcr_fetch_pr_comments: a non-boolean hasNextPage fails closed" {
  gh() { printf '%s' '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"endCursor":null},"nodes":[]}}}}}'; }
  run --separate-stderr bcr_fetch_pr_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"pagination"* ]]
}

# #2072: a failed API call and an unparseable page each fail closed with their
# own reason, so a fetch failure is distinguishable from a parse failure.
@test "bcr_fetch_pr_comments: a failed API call fails closed with a fetch reason" {
  gh() { return 1; }
  run --separate-stderr bcr_fetch_pr_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"API request failed"* ]]
}

@test "bcr_fetch_pr_comments: an unparseable page fails closed with a parse reason" {
  gh() { printf '%s' '<html>502 Bad Gateway</html>'; }
  run --separate-stderr bcr_fetch_pr_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"unparseable"* ]]
  [[ "$stderr" != *"API request failed"* ]]
}

# A page that reports more pages but repeats the cursor it was fetched with
# would loop on the same page forever; it fails closed instead.
@test "bcr_fetch_pr_comments: a repeated non-empty endCursor fails closed" {
  gh() { printf '%s' '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":true,"endCursor":"same"},"nodes":[]}}}}}'; }
  run --separate-stderr bcr_fetch_pr_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"did not advance"* ]]
}

# The temp file holds fetched comment bodies; it is removed on success and failure.
@test "bcr_fetch_pr_comments: leaves no temp file behind" {
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  gh() { printf '%s' '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'; }
  run bcr_fetch_pr_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 0 ]
  gh() { return 1; }
  run bcr_fetch_pr_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

# #2072: PR #1953's comment history grew past the per-argument size limit and the
# scan died with "jq: Argument list too long" because pages were merged through
# `jq --argjson`. Thousands of comments and several MB of body text — far beyond
# ARG_MAX — must be read in full.
@test "bcr_fetch_pr_comments: reads thousands of comments and MBs of text (well over ARG_MAX)" {
  local pages_dir="$BATS_TEST_TMPDIR/pages" pages=30 per_page=100 i
  mkdir -p "$pages_dir"
  for ((i = 1; i <= pages; i++)); do
    jq -nc --argjson p "$i" --argjson n "$per_page" --argjson last "$pages" '
      ("x" * 2048) as $pad
      | {data: {repository: {pullRequest: {comments: {
          pageInfo: {hasNextPage: ($p < $last),
                     endCursor: (if $p < $last then "c\($p + 1)" else null end)},
          nodes: [range($n) as $k
            | {id: "IC_\($p)_\($k)", author: {login: "coderabbitai", __typename: "Bot"},
               authorAssociation: "NONE", body: "comment \($p)/\($k) \($pad)",
               createdAt: "2026-10-01T23:05:43Z", lastEditedAt: null,
               isMinimized: false, minimizedReason: null}]}}}}}' > "$pages_dir/c$i.json"
  done
  export PAGES_DIR="$pages_dir"
  gh() {
    local a cursor="c1"
    for a in "$@"; do
      case "$a" in cursor=*) cursor="${a#cursor=}" ;; esac
    done
    cat "$PAGES_DIR/$cursor.json"
  }
  local out_file="$BATS_TEST_TMPDIR/out.json" err_file="$BATS_TEST_TMPDIR/err.txt"
  bcr_fetch_pr_comments "petry-projects/.github-private" 1953 > "$out_file" 2> "$err_file"
  [ ! -s "$err_file" ]
  # Well over ARG_MAX, so it could never have been passed as one argument.
  [ "$(wc -c < "$out_file")" -gt "$(getconf ARG_MAX)" ]
  [ "$(jq 'length' "$out_file")" -eq $((pages * per_page)) ]
  [ "$(jq -r 'first.id' "$out_file")" = "IC_1_0" ]
  [ "$(jq -r 'last.id' "$out_file")" = "IC_${pages}_$((per_page - 1))" ]
  # The full set still drives the pure decision without hitting the size limit.
  run bcr_retry_decisions "$(cat "$out_file")" "$TRUSTED" "$INFO" "$NOW_EPOCH" "$AUTOMATION"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq $((pages * per_page)) ]
}

# ── dev-lead-retry.sh sweep wiring ───────────────────────────────────────────

_setup_sweep() {
  MOCK_BIN="$(mktemp -d)"
  export PATH="$MOCK_BIN:$PATH"
  export DRY_RUN="false"
  export NOW_ISO="2026-10-02T01:00:00Z"
  export GH_LOG="$MOCK_BIN/gh.log"
  export BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC=0
  if [ -z "${PR_JSON:-}" ]; then
    export PR_JSON='{"state":"open","head":{"sha":"abc","ref":"dev-lead/issue-2008-x","repo":{"full_name":"petry-projects/.github-private"}},"user":{"login":"don-petry"},"labels":[]}'
  fi
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
case "$args" in
  *"/dispatches"*) cat > "$GH_LOG.payload"; exit 0 ;;
  *"api graphql"*) printf '%s' "$GRAPHQL_RESPONSE" ;;
  *"--method POST"*"/comments"*) echo "777" ;;
  # The post-write marker listing (concurrency check) sees only our own marker.
  *"comments?per_page"*"dev-lead-bot-comment-retry id="*) echo "777" ;;
  *"/pulls/"*) printf '%s' "$PR_JSON" ;;
  *) echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"
  # shellcheck source=/dev/null
  source "$RETRY_SCRIPT"
  # The automation-budget gate needs its own API reads; it is covered elsewhere.
  pr_resume_suppressed() { return 1; }
}

_graphql_page() {
  jq -nc --argjson nodes "$(jq -sc '.' <<< "$*")" \
    '{data:{repository:{pullRequest:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$nodes}}}}}'
}

@test "sweep: an undispositioned registered-bot comment dispatches exactly one fix-bot-comment retry by node id" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page \
    "$(_bot IC_cr coderabbitai 'Walkthrough body \$(rm -rf /)')" \
    "$(_bot IC_ca codeant-ai 'Nitpicks' 2026-10-01T23:08:08Z)")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "1" ]
  # Exactly ONE dispatch per PR per scan (a second would supersede the first
  # while it is pending in the per-PR lane).
  [ "$(grep -c '/dispatches' "$GH_LOG")" -eq 1 ]
  payload="$(cat "$GH_LOG.payload")"
  [ "$(jq -r '.event_type' <<< "$payload")" = "dev-lead-reviews-retry" ]
  [ "$(jq -r '.client_payload.intent_type' <<< "$payload")" = "fix-bot-comment" ]
  [ "$(jq -r '.client_payload.comment_node_id' <<< "$payload")" = "IC_cr" ]
  [ "$(jq -r '.client_payload.pr_number' <<< "$payload")" = "2009" ]
  # The comment body is never forwarded — the pass re-fetches it by node id.
  [[ "$payload" != *"Walkthrough"* ]]
  # A dedup marker was posted BEFORE the dispatch.
  grep -q 'dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1' "$GH_LOG"
  marker_line=$(grep -n 'dev-lead-bot-comment-retry' "$GH_LOG" | head -1 | cut -d: -f1)
  dispatch_line=$(grep -n '/dispatches' "$GH_LOG" | head -1 | cut -d: -f1)
  [ "$marker_line" -lt "$dispatch_line" ]
}

@test "sweep(#2086): a target whose pinned parser drops comment_node_id gets no retry marker and no dispatch" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"
  # Gate on; the target pins an older channel whose parser reads every retry
  # field except comment_node_id (the #2050 skew).
  DCG_SWEEP_REF=dev-lead/v139-ring0
  dcg_target_pin() { echo dev-lead/v1-stable; }
  dcg_fields_read_at() { printf '%s\n' checks head_sha intent_type issue_number pr_number; }

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0" ]
  [[ "$output" == *"::warning::"*"comment_node_id"* ]]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q 'dev-lead-bot-comment-retry' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi

  # Once that channel reads the field, the same scan dispatches.
  dcg_fields_read_at() { printf '%s\n' checks comment_node_id head_sha intent_type issue_number pr_number; }
  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "1" ]
  [ "$(grep -c '/dispatches' "$GH_LOG")" -eq 1 ]
}

@test "sweep(#2089): a dev-lead:hands-off PR gets no retry marker and no dispatch" {
  export PR_JSON='{"state":"open","head":{"sha":"abc","ref":"dev-lead/issue-2008-x","repo":{"full_name":"petry-projects/.github-private"}},"user":{"login":"don-petry"},"labels":[{"name":"dev-lead:hands-off"}]}'
  _setup_sweep
  # Use the REAL resume gate (the default harness stubs it to "proceed").
  # shellcheck source=/dev/null
  source "$(dirname "$RETRY_SCRIPT")/lib/pr-automation-budget.sh"
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2085
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q 'dev-lead-bot-comment-retry' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q 'dev-lead-dispatch-guard' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a dispositioned comment dispatches nothing" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead:comment-disposition id=IC_cr disposition=informational -->
ok')")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a pending retry is not duplicated" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-02T00:50:00Z -->' 2026-10-02T00:50:00Z)")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a lost run's expired attempt-1 marker does not block the attempt-2 retry" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-01T22:00:00Z -->' 2026-10-01T22:00:00Z)")"
  # The PR still carries the expired attempt-1 marker (id 100, older than ours).
  # Only a listing scoped to attempt=2 sees our new marker (777) alone.
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *"/dispatches"*) cat > "$GH_LOG.payload"; exit 0 ;;
  *"api graphql"*) printf '%s' "$GRAPHQL_RESPONSE" ;;
  *"--method POST"*"/comments"*) echo "777" ;;
  *"comments?per_page"*"attempt=2 "*) echo "777" ;;
  *"comments?per_page"*"dev-lead-bot-comment-retry id="*) printf '100\n777\n' ;;
  *"/pulls/"*) printf '%s' "$PR_JSON" ;;
  *) echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "1" ]
  [ "$(grep -c '/dispatches' "$GH_LOG")" -eq 1 ]
  grep -q 'dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=2' "$GH_LOG"
  if grep -q -- '-X DELETE' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a dev-lead/issue-* branch name alone is not ownership (author is someone else)" {
  export PR_JSON='{"state":"open","head":{"sha":"abc","ref":"dev-lead/issue-2008-x","repo":{"full_name":"petry-projects/.github-private"}},"user":{"login":"mallory"},"labels":[]}'
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q 'api graphql' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a fork head is never swept, even when dev-lead is the PR author" {
  export PR_JSON='{"state":"open","head":{"sha":"abc","ref":"dev-lead/issue-2008-x","repo":{"full_name":"mallory/.github-private"}},"user":{"login":"don-petry"},"labels":[]}'
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: the post-claim marker check only counts markers our own automation posted" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "1" ]
  listing="$(grep 'comments?per_page' "$GH_LOG" | head -1)"
  [[ "$listing" == *'.user.login'* ]]
  [[ "$listing" == *'"don-petry","donpetry-bot"'* ]]
}

# _claim_gh <listing-output> [post-output] — a fake gh whose post-claim marker
# listing (and optionally the marker POST) is controlled by the test.
_claim_gh() {
  export CLAIM_LISTING="$1" CLAIM_POST="${2-777}"
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *"/dispatches"*) cat > "$GH_LOG.payload"; exit 0 ;;
  *"api graphql"*) printf '%s' "$GRAPHQL_RESPONSE" ;;
  *"--method POST"*"/comments"*) printf '%s' "$CLAIM_POST" ;;
  *"comments?per_page"*"dev-lead-bot-comment-retry id="*)
    [ "$CLAIM_LISTING" = "FAIL" ] && exit 1
    printf '%s' "$CLAIM_LISTING" ;;
  *"/pulls/"*) printf '%s' "$PR_JSON" ;;
  *) echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"
}

@test "sweep: a marker posted under an untrusted identity fails closed (no dispatch without dedup)" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"
  # Our marker (777) does not come back from the trusted-author listing.
  _claim_gh ""

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  grep -q -- '-X DELETE repos/petry-projects/.github-private/issues/comments/777' "$GH_LOG"
  [[ "$output" == *"does not trust"* ]]
  # The listing requires a trusted association as well as an automation login.
  grep -q 'author_association' "$GH_LOG"
}

@test "sweep: an unreadable marker re-listing fails closed and withdraws the marker" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"
  _claim_gh FAIL

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  grep -q -- '-X DELETE repos/petry-projects/.github-private/issues/comments/777' "$GH_LOG"
}

@test "sweep: a marker posted with an unreadable id is never dispatched over" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"
  _claim_gh "777" ""

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q -- '-X DELETE repos/petry-projects/.github-private/issues/comments/$' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "dispatch helpers report a failed dispatch, and only accepted ones are counted" {
  # shellcheck source=/dev/null
  source "$RETRY_SCRIPT"
  export DRY_RUN="false"
  gh() { return 1; }
  run dispatch_reviews_retry "petry-projects/.github-private" 2009 abc fix-reviews
  [ "$status" -eq 1 ]
  lookup_check_run_details() { echo '{}'; }
  run dispatch_ci_retry "petry-projects/.github-private" 2009 abc "CI failure"
  [ "$status" -eq 1 ]
  # The rate-limit scan increments its count only inside `if dispatch_…; then`.
  ! grep -qE '^\s*dispatch_(ci|reviews)_retry ' "$RETRY_SCRIPT" || false
  grep -qE 'if dispatch_ci_retry ' "$RETRY_SCRIPT"
  grep -qE 'if dispatch_reviews_retry ' "$RETRY_SCRIPT"
}

@test "sweep: a closed PR is never swept" {
  export PR_JSON='{"state":"closed","head":{"sha":"abc","ref":"dev-lead/issue-1-x"},"user":{"login":"don-petry"},"labels":[]}'
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a human-authored PR (not dev-lead's) is never swept" {
  export PR_JSON='{"state":"open","head":{"sha":"abc","ref":"feature/x"},"user":{"login":"alice"},"labels":[]}'
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: DRY_RUN posts no marker and sends no dispatch" {
  _setup_sweep
  export DRY_RUN="true"
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"would dispatch dev-lead-reviews-retry"*"fix-bot-comment"* ]]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q 'dev-lead-bot-comment-retry' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a comment-fetch failure fails closed (no dispatch)" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE='{"errors":[{"message":"boom"}]}'

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "retry header: the 'cannot be reconstructed' rationale names on-mention only" {
  run grep -n 'NOT retried automatically: on-mention$' "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -qE 'NOT retried automatically:.*fix-bot-comment' "$RETRY_SCRIPT"
}

@test "sweep: a failed dispatch withdraws its retry marker (never blocks the next attempt)" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *"/dispatches"*) exit 1 ;;
  *"api graphql"*) printf '%s' "$GRAPHQL_RESPONSE" ;;
  *"--method POST"*"/comments"*) echo "777" ;;
  *"comments?per_page"*"dev-lead-bot-comment-retry id="*) echo "777" ;;
  *"/pulls/"*) printf '%s' "$PR_JSON" ;;
  *) echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  # It reached (and failed) the dispatch — not the concurrent-scan back-off path.
  grep -q '/dispatches' "$GH_LOG"
  [[ "$output" != *"a concurrent scan already recorded a retry"* ]]
  grep -q -- '-X DELETE repos/petry-projects/.github-private/issues/comments/777' "$GH_LOG"
}

# ── AC3: pr-review acts on its own undispositioned-pr-comment verdict ─────────

@test "review-one-pr: the undispositioned-pr-comment no-op triggers the bot-comment retry scan first" {
  REVIEW="$SCRIPT_DIR/scripts/review-one-pr.sh"
  scan_line=$(grep -n 'scan_pr_for_undispositioned_bot_comments "\$_OWNER_REPO"' "$REVIEW" | head -1 | cut -d: -f1)
  verdict_line=$(grep -n 'emit_verdict skip undispositioned-pr-comment' "$REVIEW" | head -1 | cut -d: -f1)
  gate_line=$(grep -n 'if \[ "\$mc_gate_rc" -eq 1 \]' "$REVIEW" | head -1 | cut -d: -f1)
  [ -n "$scan_line" ] && [ -n "$verdict_line" ] && [ -n "$gate_line" ]
  # Inside the rc=1 (undispositioned) branch, before its verdict/exit.
  [ "$gate_line" -lt "$scan_line" ]
  [ "$scan_line" -lt "$verdict_line" ]
  # Never in DRY_RUN, and best-effort (cannot fail the review run). Anchored to
  # the retry block's OWN guard (it is the condition that also requires an
  # owner/repo), not to an unrelated DRY_RUN check elsewhere in the range.
  guard_line=$(grep -n 'if \[ "\${DRY_RUN:-false}" != "true" \] && \[ -n "\$_OWNER_REPO" \]' "$REVIEW" | head -1 | cut -d: -f1)
  [ -n "$guard_line" ]
  [ "$gate_line" -lt "$guard_line" ]
  [ "$guard_line" -lt "$scan_line" ]
  # The scan sits inside that guard: no `fi` closes it before the scan call.
  ! sed -n "${guard_line},${scan_line}p" "$REVIEW" | grep -qE '^\s*fi\s*$' || false
  sed -n "${gate_line},${verdict_line}p" "$REVIEW" | grep -q ') 2>&1 ) || true'
}

@test "review-one-pr: the retry scan sourced from pr-review resolves a real function" {
  # The hook sources dev-lead-retry.sh in a subshell; make sure that works from
  # an arbitrary caller and exposes the function without running main.
  run bash -c "source '$RETRY_SCRIPT' && declare -F scan_pr_for_undispositioned_bot_comments"
  [ "$status" -eq 0 ]
  [ "$output" = "scan_pr_for_undispositioned_bot_comments" ]
}

@test "scan_repo: a PR that already got a rate-limit retry this scan gets no bot-comment dispatch" {
  _setup_sweep
  scan_pr_for_rate_limits() { echo "1"; }
  scan_pr_for_undispositioned_bot_comments() { echo "CALLED" >&2; echo "1"; }
  scan_repo_issues() { :; }
  gh() { echo '[{"number":2009,"head_sha":"abc"}]'; }

  run scan_repo "petry-projects/.github-private"
  [[ "$output" != *"CALLED"* ]]
  [[ "$output" == *"dispatched 1 PR retries"* ]]
}

@test "scan_repo: a PR with no rate-limit retry is swept for undispositioned bot comments" {
  _setup_sweep
  scan_pr_for_rate_limits() { echo "0"; }
  scan_pr_for_undispositioned_bot_comments() { echo "CALLED" >&2; echo "1"; }
  scan_repo_issues() { :; }
  gh() { echo '[{"number":2009,"head_sha":"abc"}]'; }

  run scan_repo "petry-projects/.github-private"
  [[ "$output" == *"CALLED"* ]]
  [[ "$output" == *"dispatched 1 PR retries"* ]]
}

@test "sweep: the claim waits BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC before re-listing markers" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"
  _claim_gh "777"
  export BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC=3
  sleep() { echo "sleep $*" >> "$GH_LOG"; }

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "1" ]
  # The wait comes after the marker POST and before the re-list.
  order="$(grep -n -e '--method POST' -e '^sleep 3' -e 'comments?per_page' "$GH_LOG" | cut -d: -f2- | cut -c1-12)"
  [ "$(printf '%s\n' "$order" | sed -n 2p)" = "sleep 3" ]
}

@test "withdraw_bot_comment_retry_marker: a failed delete is surfaced as a warning" {
  # shellcheck source=/dev/null
  source "$RETRY_SCRIPT"
  gh() { return 1; }
  run withdraw_bot_comment_retry_marker "petry-projects/.github-private" 777
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"*"777"* ]]
}

@test "sweep: a comment id outside the node-id alphabet is never spliced into a marker or filter" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot "IC_x' or true" coderabbitai 'Walkthrough')")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  if grep -q -- '--method POST' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "dev-lead-retry.sh can be sourced after the maintainer gate is already loaded (pr-review backstop path)" {
  run bash -c "source '$SCRIPT_DIR/scripts/lib/maintainer-comment-gate.sh' && source '$RETRY_SCRIPT' && declare -F scan_pr_for_undispositioned_bot_comments stale_disposition_needs_dispatch"
  [ "$status" -eq 0 ]
  [[ "$output" == *scan_pr_for_undispositioned_bot_comments* ]]
}

# ── #2262: a retry cancelled before it starts ────────────────────────────────
# The retry's own run joins the PR's concurrency lane, where a newer event
# cancels it before a step runs. The sweep records the run it dispatched on the
# marker (run=<id>) and passes what the Actions API says about recorded runs to
# the pure decision. NOW is 2026-10-02T01:00:00Z; the pending window is 150 min
# and the lost-retry backoff defaults to the 15-min grace.

RUN_LOST='{"status":"completed","conclusion":"cancelled","started":false}'
RUN_QUEUED='{"status":"queued","conclusion":null,"started":null}'
RUN_RUNNING='{"status":"in_progress","conclusion":null,"started":null}'

# _retry <comment id> <attempt> <posted at> [run id] [association] [login]
#   A retry marker for the default comment version, from our automation unless
#   an association/login says otherwise.
_retry() {
  _ours "<!-- dev-lead-bot-comment-retry id=$1 version=2026-10-01T23:05:43Z attempt=$2 at=$3${4:+ run=$4} -->" \
    "$3" "${5:-OWNER}" "${6:-don-petry}"
}

# _decide_runs <run_states_json> <comment>… — the decision, given run states.
_decide_runs() {
  local states="$1"; shift
  bcr_retry_decisions "$(jq -sc '.' <<< "$*")" "$TRUSTED" "$INFO" "$NOW_EPOCH" "$AUTOMATION" "$states"
}

# _run_ids <comment>… — the run ids the sweep would read.
_run_ids() {
  bcr_retry_run_ids "$(jq -sc '.' <<< "$*")" "$TRUSTED" "$INFO" "$NOW_EPOCH" "$AUTOMATION"
}

@test "bcr(#2262): a retry whose run was cancelled before it started re-dispatches without waiting out the pending window" {
  cr="$(_bot IC_cr coderabbitai 'Walkthrough')"
  # Posted 30 min ago: well inside the 150-min pending window.
  m="$(_retry IC_cr 1 2026-10-02T00:30:00Z 501)"
  out="$(_decide_runs "{\"501\":${RUN_LOST}}" "$cr" "$m")"
  [ "$(_dispatches "$out")" = "1" ]
  # The attempt number stays monotonic: the sweep's claim is scoped to it.
  [ "$(jq -r '.[0].attempt' <<< "$out")" = "2" ]
  # Without the run state the same marker is still a pending retry.
  out="$(_decide "$cr" "$m")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "retry-pending" ]
}

@test "bcr(#2262): cancelled retries do not exhaust BOT_COMMENT_RETRY_MAX_ATTEMPTS" {
  cr="$(_bot IC_cr coderabbitai 'Walkthrough')"
  # Two retries (MAX_ATTEMPTS is 2), both cancelled before they started.
  out="$(_decide_runs "{\"501\":${RUN_LOST},\"502\":${RUN_LOST}}" "$cr" \
    "$(_retry IC_cr 1 2026-10-01T20:00:00Z 501)" \
    "$(_retry IC_cr 2 2026-10-01T21:00:00Z 502)")"
  [ "$(_dispatches "$out")" = "1" ]
  [ "$(jq -r '.[0].attempt' <<< "$out")" = "3" ]
  # A lost retry gives back only its own attempt. Lost, ran, lost: one attempt used.
  out="$(_decide_runs "{\"501\":${RUN_LOST},\"503\":${RUN_LOST}}" "$cr" \
    "$(_retry IC_cr 1 2026-10-01T19:00:00Z 501)" \
    "$(_retry IC_cr 2 2026-10-01T20:00:00Z 502)" \
    "$(_retry IC_cr 3 2026-10-01T21:00:00Z 503)")"
  [ "$(_dispatches "$out")" = "1" ]
  [ "$(jq -r '.[0].attempt' <<< "$out")" = "4" ]
  # Lost, ran, lost, ran: both attempts used.
  out="$(_decide_runs "{\"501\":${RUN_LOST},\"503\":${RUN_LOST}}" "$cr" \
    "$(_retry IC_cr 1 2026-10-01T19:00:00Z 501)" \
    "$(_retry IC_cr 2 2026-10-01T20:00:00Z 502)" \
    "$(_retry IC_cr 3 2026-10-01T21:00:00Z 503)" \
    "$(_retry IC_cr 4 2026-10-01T22:00:00Z 504)")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "retry-attempts-exhausted" ]
}

@test "bcr(#2262): the hard ceiling still stops a lane that keeps cancelling" {
  cr="$(_bot IC_cr coderabbitai 'Walkthrough')"
  states="{\"501\":${RUN_LOST},\"502\":${RUN_LOST},\"503\":${RUN_LOST},\"504\":${RUN_LOST},\"505\":${RUN_LOST},\"506\":${RUN_LOST}}"
  five=("$(_retry IC_cr 1 2026-10-01T17:00:00Z 501)" "$(_retry IC_cr 2 2026-10-01T18:00:00Z 502)" \
        "$(_retry IC_cr 3 2026-10-01T19:00:00Z 503)" "$(_retry IC_cr 4 2026-10-01T20:00:00Z 504)" \
        "$(_retry IC_cr 5 2026-10-01T21:00:00Z 505)")
  # Five cancelled retries: none used an attempt, and the default ceiling is 6.
  out="$(_decide_runs "$states" "$cr" "${five[@]}")"
  [ "$(_dispatches "$out")" = "1" ]
  [ "$(jq -r '.[0].attempt' <<< "$out")" = "6" ]
  # The sixth is the last, however it ended: lost retries count toward MAX_TOTAL.
  out="$(_decide_runs "$states" "$cr" "${five[@]}" "$(_retry IC_cr 6 2026-10-01T22:00:00Z 506)")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "retry-attempts-exhausted" ]
  # The ceiling is the tunable.
  export BOT_COMMENT_RETRY_MAX_TOTAL=3
  out="$(_decide_runs "$states" "$cr" "${five[@]:0:2}")"
  [ "$(_dispatches "$out")" = "1" ]
  out="$(_decide_runs "$states" "$cr" "${five[@]:0:3}")"
  [ "$(_reason_for "$out" IC_cr)" = "retry-attempts-exhausted" ]
}

@test "bcr(#2262): a retry whose run is queued or running is never duplicated, and holds the PR's other comments" {
  cr="$(_bot IC_cr coderabbitai 'Walkthrough')"
  ca="$(_bot IC_ca codeant-ai 'Nitpicks' 2026-10-01T23:08:08Z)"
  m="$(_retry IC_cr 1 2026-10-02T00:30:00Z 501)"
  local st
  for st in "$RUN_QUEUED" "$RUN_RUNNING" '{"status":"pending"}' '{"status":"waiting"}'; do
    out="$(_decide_runs "{\"501\":${st}}" "$cr" "$ca" "$m")"
    [ "$(_dispatches "$out")" = "0" ]
    [ "$(_reason_for "$out" IC_cr)" = "retry-pending" ]
    # Every retry shares the per-PR lane: dispatching for the other comment would
    # cancel the queued run (the PR #2205 sequence).
    [ "$(_reason_for "$out" IC_ca)" = "retry-pending" ]
  done
  # A queued retry for an OLDER version of an edited comment holds too: when it
  # runs it re-reads the comment's current body.
  edited="$(_bot IC_cr coderabbitai 'Walkthrough v2' 2026-10-01T23:05:43Z 2026-10-02T00:40:00Z)"
  out="$(_decide_runs "{\"501\":${RUN_QUEUED}}" "$edited" "$m")"
  [ "$(_reason_for "$out" IC_cr)" = "retry-pending" ]
  # The hold is bounded by the pending window, like every pending retry.
  out="$(_decide_runs "{\"501\":${RUN_QUEUED}}" "$cr" "$ca" "$(_retry IC_cr 1 2026-10-01T22:00:00Z 501)")"
  [ "$(_dispatches "$out")" = "2" ]
}

@test "bcr(#2262): only a run KNOWN to be cancelled before it started is lost — anything else keeps the pending window" {
  cr="$(_bot IC_cr coderabbitai 'Walkthrough')"
  m="$(_retry IC_cr 1 2026-10-02T00:30:00Z 501)"
  # Control: the known-lost state does release the retry.
  [ "$(_dispatches "$(_decide_runs "{\"501\":${RUN_LOST}}" "$cr" "$m")")" = "1" ]
  local st
  for st in \
    '{}' '' 'not json' '[]' 'null' \
    "{\"999\":${RUN_LOST}}" \
    "{\"501\":${RUN_LOST}} {\"501\":${RUN_LOST}}" \
    '{"501":{"status":"completed","conclusion":"cancelled","started":null}}' \
    '{"501":{"status":"completed","conclusion":"cancelled","started":true}}' \
    '{"501":{"status":"completed","conclusion":"cancelled"}}' \
    '{"501":{"status":"completed","conclusion":"cancelled","started":"false"}}' \
    '{"501":{"status":"completed","conclusion":"failure","started":false}}' \
    '{"501":{"status":"completed","conclusion":"success","started":null}}' \
    '{"501":{"status":"completed","conclusion":"skipped","started":false}}' \
    '{"501":{"conclusion":"cancelled","started":false}}' \
    '{"501":null}' '{"501":"cancelled"}' '{"501":[]}'; do
    out="$(_decide_runs "$st" "$cr" "$m")" || { echo "state <$st> failed the decision"; return 1; }
    [ "$(_dispatches "$out")" = "0" ] || { echo "state <$st> dispatched: $out"; return 1; }
    [ "$(_reason_for "$out" IC_cr)" = "retry-pending" ] || { echo "state <$st>: $out"; return 1; }
  done
  # A marker whose run= is not a run id is a marker without a run.
  bad="$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-02T00:30:00Z run=abc -->' 2026-10-02T00:30:00Z)"
  out="$(_decide_runs "{\"abc\":${RUN_LOST}}" "$cr" "$bad")"
  [ "$(_reason_for "$out" IC_cr)" = "retry-pending" ]
  [ "$(_run_ids "$cr" "$bad")" = "[]" ]
}

@test "bcr(#2262): a retry lost moments ago backs off before the PR's next retry" {
  cr="$(_bot IC_cr coderabbitai 'Walkthrough')"
  ca="$(_bot IC_ca codeant-ai 'Nitpicks' 2026-10-01T23:08:08Z)"
  # Dispatched 10 min ago and already cancelled: whatever cancelled it has just
  # taken the lane's pending slot, and a dispatch now would cancel that in turn.
  m="$(_retry IC_cr 1 2026-10-02T00:50:00Z 501)"
  out="$(_decide_runs "{\"501\":${RUN_LOST}}" "$cr" "$ca" "$m")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "retry-cancelled-backoff" ]
  [ "$(_reason_for "$out" IC_ca)" = "retry-cancelled-backoff" ]
  # Past the backoff (it defaults to the 15-min grace) both are dispatchable.
  out="$(_decide_runs "{\"501\":${RUN_LOST}}" "$cr" "$ca" "$(_retry IC_cr 1 2026-10-02T00:44:00Z 501)")"
  [ "$(_dispatches "$out")" = "2" ]
  # The backoff is tunable; 0 turns it off.
  export BOT_COMMENT_RETRY_LOST_BACKOFF_SEC=0
  out="$(_decide_runs "{\"501\":${RUN_LOST}}" "$cr" "$ca" "$m")"
  [ "$(_dispatches "$out")" = "2" ]
  [ "$(jq -r '.[0].attempt' <<< "$out")" = "2" ]
}

@test "bcr(#2262): only our own automation's markers name a run, and bcr_retry_run_ids lists just the runs worth reading" {
  cr="$(_bot IC_cr coderabbitai 'Walkthrough')"
  ours="$(_retry IC_cr 1 2026-10-02T00:30:00Z 501)"
  member="$(_retry IC_cr 1 2026-10-02T00:40:00Z 998 MEMBER mallory)"
  outsider="$(_retry IC_cr 1 2026-10-02T00:41:00Z 999 NONE don-petry)"
  # Markers anyone else posted name no run to read (CWE-863)…
  [ "$(_run_ids "$cr" "$ours" "$member" "$outsider")" = '["501"]' ]
  # …cannot release our pending retry by naming a cancelled run…
  out="$(_decide_runs "{\"998\":${RUN_LOST},\"999\":${RUN_LOST}}" "$cr" "$ours" "$member" "$outsider")"
  [ "$(_reason_for "$out" IC_cr)" = "retry-pending" ]
  # …and cannot hold the PR by naming a live one.
  out="$(_decide_runs "{\"998\":${RUN_QUEUED},\"999\":${RUN_QUEUED}}" "$cr" "$member" "$outsider")"
  [ "$(_dispatches "$out")" = "1" ]

  # pr-review's scan posts markers too (donpetry-bot): its run is read.
  [ "$(_run_ids "$cr" "$(_retry IC_cr 1 2026-10-02T00:30:00Z 601 MEMBER donpetry-bot)")" = '["601"]' ]
  # Outside the pending window a run matters only when a lost one could give an
  # attempt back: out of MAX_ATTEMPTS, under MAX_TOTAL.
  old1="$(_retry IC_cr 1 2026-10-01T20:00:00Z 701)"
  old2="$(_retry IC_cr 2 2026-10-01T21:00:00Z 702)"
  [ "$(_run_ids "$cr" "$old1")" = '[]' ]
  [ "$(_run_ids "$cr" "$old1" "$old2")" = '["701","702"]' ]
  # A dispositioned comment needs no run read.
  [ "$(_run_ids "$cr" "$old1" "$old2" "$(_ours '<!-- dev-lead:comment-disposition id=IC_cr disposition=informational -->
ok')")" = '[]' ]
  # At MAX_TOTAL nothing can change the answer.
  export BOT_COMMENT_RETRY_MAX_TOTAL=2
  [ "$(_run_ids "$cr" "$old1" "$old2")" = '[]' ]
  # Unevaluable input fails closed, as the decision does.
  run bcr_retry_run_ids '{"not":"an array"}' "$TRUSTED" "$INFO" "$NOW_EPOCH" "$AUTOMATION"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "bcr_run_state(#2262): only a complete job list with no step run reads as not started" {
  run_json='{"id":501,"event":"repository_dispatch","status":"completed","conclusion":"cancelled"}'
  # The shape the Actions API returned for the cancelled PR #2205 retries.
  unstarted='{"total_count":3,"jobs":[
    {"name":"dev-lead / dispatch","status":"completed","conclusion":"cancelled","steps":[]},
    {"name":"dev-lead / ci-relay","status":"completed","conclusion":"cancelled","steps":[]},
    {"name":"dev-lead / resume","status":"completed","conclusion":"cancelled"}]}'
  [ "$(bcr_run_state 501 "$run_json" "$unstarted")" = "$RUN_LOST" ]
  # A run superseded before any job was created.
  [ "$(bcr_run_state 501 "$run_json" '{"total_count":0,"jobs":[]}' | jq -r '.started')" = "false" ]
  # A job that ran a step, or ended any way but cancelled/skipped: it started.
  ran='{"total_count":2,"jobs":[
    {"conclusion":"cancelled","steps":[{"name":"Set up job","conclusion":"success"}]},
    {"conclusion":"cancelled","steps":[]}]}'
  [ "$(bcr_run_state 501 "$run_json" "$ran" | jq -r '.started')" = "true" ]
  [ "$(bcr_run_state 501 "$run_json" '{"total_count":1,"jobs":[{"conclusion":"success","steps":[]}]}' | jq -r '.started')" = "true" ]
  # Missing, unreadable or truncated job list: unknown, never "not started".
  local j
  for j in '' 'not json' '[]' '{"jobs":[]}' '{"total_count":5,"jobs":[{"conclusion":"cancelled","steps":[]}]}'; do
    [ "$(bcr_run_state 501 "$run_json" "$j" | jq -r '.started')" = "null" ] || { echo "jobs <$j>"; return 1; }
  done
  # A live run keeps its status; no conclusion yet.
  [ "$(bcr_run_state 501 '{"id":501,"event":"repository_dispatch","status":"queued","conclusion":null}')" \
    = '{"status":"queued","conclusion":null,"started":null}' ]
  # Not the run asked for, not a repository_dispatch run, or not a run at all.
  run bcr_run_state 502 "$run_json" "$unstarted"
  [ "$status" -ne 0 ]
  run bcr_run_state 501 '{"id":501,"event":"issue_comment","status":"completed","conclusion":"cancelled"}' "$unstarted"
  [ "$status" -ne 0 ]
  run bcr_run_state 501 '{"message":"Not Found"}' "$unstarted"
  [ "$status" -ne 0 ]
  run bcr_run_state abc "$run_json" "$unstarted"
  [ "$status" -ne 0 ]
}

# _listed_run <id> <created_at> [display_title] [path] [event] — one workflow_runs entry.
_listed_run() {
  jq -nc --argjson id "$1" --arg c "$2" --arg t "${3:-dev-lead-reviews-retry}" \
    --arg p "${4:-.github/workflows/dev-lead.yml}" --arg e "${5:-repository_dispatch}" \
    '{id:$id, created_at:$c, display_title:$t, path:$p, event:$e, status:"queued", conclusion:null}'
}

# _runs_listing <run>… — a GET /actions/runs response holding exactly these runs.
_runs_listing() {
  jq -sc '{total_count: length, workflow_runs: .}' <<< "$*"
}

@test "bcr_pick_dispatched_run(#2262): a dispatch is paired only with exactly one candidate run" {
  since=2026-10-02T00:59:58Z
  ours="$(_listed_run 9001 2026-10-02T01:00:02Z)"
  noise=("$(_listed_run 8000 2026-10-02T00:59:40Z)" \
         "$(_listed_run 9002 2026-10-02T01:00:03Z pr-review-mention .github/workflows/pr-review-trigger.yml)" \
         "$(_listed_run 9003 2026-10-02T01:00:03Z dev-lead-ci-failure)" \
         "$(_listed_run 9004 2026-10-02T01:00:03Z dev-lead-reviews-retry .github/workflows/other.yml)" \
         "$(_listed_run 9005 2026-10-02T01:00:03Z dev-lead-reviews-retry .github/workflows/dev-lead.yml issue_comment)")
  # An earlier retry's run, another workflow, another event type: not candidates.
  [ "$(bcr_pick_dispatched_run "$(_runs_listing "$ours" "${noise[@]}")" "$since")" = '{"count":1,"id":"9001"}' ]
  # A run created in the same second as the dispatch is a candidate.
  [ "$(bcr_pick_dispatched_run "$(_runs_listing "$(_listed_run 9001 "$since")")" "$since" | jq -r '.id')" = "9001" ]
  # Two candidates cannot be told apart (a run that has not started has no payload).
  [ "$(bcr_pick_dispatched_run "$(_runs_listing "$ours" "$(_listed_run 9010 2026-10-02T01:00:04Z)")" "$since")" \
    = '{"count":2,"id":null}' ]
  # None yet.
  [ "$(bcr_pick_dispatched_run "$(_runs_listing "${noise[@]}")" "$since")" = '{"count":0,"id":null}' ]
  # An unreadable or truncated listing is not "no run".
  local l
  for l in '[]' '' 'not json' '{"message":"Not Found"}' \
           "$(jq -c '.total_count = 250' <<< "$(_runs_listing "$ours")")"; do
    run bcr_pick_dispatched_run "$l" "$since"
    [ "$status" -ne 0 ] || { echo "listing <$l> was read as an answer: $output"; return 1; }
    [ -z "$output" ]
  done
  run bcr_pick_dispatched_run "$(_runs_listing "$ours")" "not a time"
  [ "$status" -ne 0 ]
}

@test "bcr_retry_marker(#2262): the run id is a trailing attribute, and a marker without one is unchanged" {
  [ "$(bcr_retry_marker IC_cr 2026-10-01T23:05:43Z 1 2026-10-02T01:00:00Z)" \
    = '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-02T01:00:00Z -->' ]
  with_run="$(bcr_retry_marker IC_cr 2026-10-01T23:05:43Z 1 2026-10-02T01:00:00Z 9001)"
  [ "$with_run" = '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-02T01:00:00Z run=9001 -->' ]
  # The sweep's claim listing and the thread-retry arbitration match on these
  # prefixes; the maintainer-comment gate must still see an agent marker.
  [[ "$with_run" == *'dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 '* ]]
  [[ "$with_run" == '<!-- dev-lead-bot-comment-retry id='* ]]
  [ "$(jq -rn --arg b "$with_run" --arg m "$_MAINTAINER_GATE_AGENT_MARKERS" '$b | test($m)')" = "true" ]
}

# ── #2262: sweep wiring ──────────────────────────────────────────────────────

# _run_gh — a fake gh that also answers the Actions API:
#   GET …/actions/runs (the listing)  → $RUNS_LISTING; unset or "FAIL" exits 1
#   …/actions/runs/<id>               → $MOCK_BIN/run_<id>.json; missing exits 1
#   …/actions/runs/<id>/jobs          → $MOCK_BIN/jobs_<id>.json; missing exits 1
#   PATCH …/issues/comments/<id>      → exits $PATCH_RC (default 0)
# Call after _setup_sweep.
_run_gh() {
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
dir="$(dirname "$0")"
args="$*"
case "$args" in
  *"/dispatches"*) cat > "$GH_LOG.payload"; exit 0 ;;
  *"api graphql"*) printf '%s' "$GRAPHQL_RESPONSE" ;;
  *"/actions/runs/"*)
    rest="${args##*/actions/runs/}"; id="${rest%%[!0-9]*}"
    case "$rest" in *"/jobs"*) file="$dir/jobs_${id}.json" ;; *) file="$dir/run_${id}.json" ;; esac
    [ -f "$file" ] || exit 1
    cat "$file" ;;
  *"/actions/runs"*)
    [ "${RUNS_LISTING:-FAIL}" = "FAIL" ] && exit 1
    printf '%s' "$RUNS_LISTING" ;;
  *"--method PATCH"*"/issues/comments/"*) exit "${PATCH_RC:-0}" ;;
  *"--method POST"*"/comments"*) echo "777" ;;
  *"comments?per_page"*"dev-lead-bot-comment-retry id="*) echo "777" ;;
  *"/pulls/"*) printf '%s' "$PR_JSON" ;;
  *) echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"
}

# _recorded_run <id> <status> [conclusion] — what GET …/actions/runs/<id> returns.
_recorded_run() {
  jq -nc --argjson id "$1" --arg s "$2" --arg c "${3:-}" \
    '{id:$id, event:"repository_dispatch", status:$s, conclusion:(if $c == "" then null else $c end),
      display_title:"dev-lead-reviews-retry", path:".github/workflows/dev-lead.yml"}' > "$MOCK_BIN/run_$1.json"
}

# _unstarted_jobs <id> — the job list of a run cancelled before any step ran.
_unstarted_jobs() {
  printf '%s' '{"total_count":3,"jobs":[
    {"name":"dev-lead / dispatch","status":"completed","conclusion":"cancelled","steps":[]},
    {"name":"dev-lead / ci-relay","status":"completed","conclusion":"cancelled","steps":[]},
    {"name":"dev-lead / resume","status":"completed","conclusion":"cancelled","steps":[]}]}' > "$MOCK_BIN/jobs_$1.json"
}

_patches() { grep -c -- '--method PATCH' "$GH_LOG" || true; }

@test "sweep(#2262): the run a retry dispatch created is recorded on its marker by editing it" {
  _setup_sweep
  _run_gh
  export TRUSTED_BOTS="$TRUSTED" GRAPHQL_RESPONSE RUNS_LISTING
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"
  # NOW_ISO is 01:00:00Z. One retry run appeared after the dispatch; the others
  # are an earlier retry's run and another workflow's.
  RUNS_LISTING="$(_runs_listing \
    "$(_listed_run 9001 2026-10-02T01:00:02Z)" \
    "$(_listed_run 8000 2026-10-02T00:59:40Z)" \
    "$(_listed_run 9002 2026-10-02T01:00:03Z pr-review-mention .github/workflows/pr-review-trigger.yml)")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "1" ]
  # It asked only for repository_dispatch runs created at/after the dispatch.
  grep -q -- 'actions/runs -f event=repository_dispatch -f created=>=2026-10-02T00:59:58Z' "$GH_LOG"
  # The marker it posted (777) is edited to the same marker plus run=<id>…
  grep -qF -- '--method PATCH repos/petry-projects/.github-private/issues/comments/777 -f body=<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-02T01:00:00Z run=9001 -->' "$GH_LOG"
  # …after the dispatch…
  dispatch_line=$(grep -n '/dispatches' "$GH_LOG" | head -1 | cut -d: -f1)
  patch_line=$(grep -n -- '--method PATCH' "$GH_LOG" | head -1 | cut -d: -f1)
  [ "$dispatch_line" -lt "$patch_line" ]
  # …and never re-posted: a new comment would start a run in the PR's lane and
  # cancel the retry just dispatched.
  [ "$(grep -c -- '--method POST.*/comments' "$GH_LOG")" -eq 1 ]
  [ "$(grep -c '/dispatches' "$GH_LOG")" -eq 1 ]
  [[ "$output" == *"[run]"*"9001"* ]]

  # A failed edit is surfaced, and the dispatch still counts.
  : > "$GH_LOG"
  export PATCH_RC=1
  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"::warning::"*"could not record Actions run 9001"* ]]

  # DRY_RUN dispatches nothing, so it looks up and edits nothing.
  : > "$GH_LOG"
  export DRY_RUN="true" PATCH_RC=0
  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "1" ]
  if grep -q -e 'actions/runs' -e '--method PATCH' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep(#2262): a dispatch that cannot be paired with exactly one run records none" {
  _setup_sweep
  _run_gh
  export TRUSTED_BOTS="$TRUSTED" GRAPHQL_RESPONSE RUNS_LISTING
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"

  # Two retry runs since the dispatch (another PR's retry reached this repo in
  # the same seconds): they cannot be told apart.
  RUNS_LISTING="$(_runs_listing "$(_listed_run 9001 2026-10-02T01:00:02Z)" "$(_listed_run 9010 2026-10-02T01:00:03Z)")"
  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"cannot tell which"* ]]
  [ "$(_patches)" -eq 0 ]
  [ "$(grep -c 'actions/runs -f' "$GH_LOG")" -eq 1 ]

  # No run yet: it looks BOT_COMMENT_RETRY_RUN_LOOKUP_TRIES times, then gives up.
  : > "$GH_LOG"
  RUNS_LISTING="$(_runs_listing "$(_listed_run 8000 2026-10-02T00:59:40Z)")"
  BOT_COMMENT_RETRY_RUN_LOOKUP_TRIES=2
  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "1" ]
  [ "$(grep -c 'actions/runs -f' "$GH_LOG")" -eq 2 ]
  [[ "$output" == *"no dev-lead-reviews-retry run appeared"* ]]
  [ "$(_patches)" -eq 0 ]

  # An unreadable listing is named, not read as "no run": one look, no edit.
  : > "$GH_LOG"
  RUNS_LISTING="FAIL"
  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"::warning::"*"could not read the Actions runs"* ]]
  [ "$(grep -c 'actions/runs -f' "$GH_LOG")" -eq 1 ]
  [ "$(_patches)" -eq 0 ]

  # A truncated listing could hide a second candidate: unreadable too.
  : > "$GH_LOG"
  RUNS_LISTING="$(jq -c '.total_count = 250' <<< "$(_runs_listing "$(_listed_run 9001 2026-10-02T01:00:02Z)")")"
  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"::warning::"*"could not read the Actions runs"* ]]
  [ "$(_patches)" -eq 0 ]
}

@test "sweep(#2262): a retry cancelled before it started is re-dispatched on the next scan, as the next attempt" {
  _setup_sweep
  _run_gh
  export TRUSTED_BOTS="$TRUSTED" GRAPHQL_RESPONSE RUNS_LISTING
  # Attempt 1 was dispatched 30 min ago (inside the 150-min pending window) and
  # its run was cancelled in the PR's lane before any step ran.
  GRAPHQL_RESPONSE="$(_graphql_page \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_retry IC_cr 1 2026-10-02T00:30:00Z 501)")"
  _recorded_run 501 completed cancelled
  _unstarted_jobs 501
  RUNS_LISTING="$(_runs_listing "$(_listed_run 9001 2026-10-02T01:00:02Z)")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"[lost]"*"run 501"* ]]
  [ "$(grep -c '/dispatches' "$GH_LOG")" -eq 1 ]
  [ "$(jq -r '.client_payload.comment_node_id' "$GH_LOG.payload")" = "IC_cr" ]
  # A fresh attempt-2 marker claims the retry, and its own run is recorded.
  grep -qF -- '--method POST repos/petry-projects/.github-private/issues/2009/comments -f body=<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=2 at=2026-10-02T01:00:00Z -->' "$GH_LOG"
  grep -qF -- 'attempt=2 at=2026-10-02T01:00:00Z run=9001 -->' "$GH_LOG"
  # The state came from the run and its jobs, read once each.
  [ "$(grep -c 'actions/runs/501$' "$GH_LOG")" -eq 1 ]
  [ "$(grep -c 'actions/runs/501/jobs' "$GH_LOG")" -eq 1 ]
}

@test "sweep(#2262): a retry whose run is still queued is not duplicated, and no other comment is dispatched over it" {
  _setup_sweep
  _run_gh
  export TRUSTED_BOTS="$TRUSTED" GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_bot IC_ca codeant-ai 'Nitpicks' 2026-10-01T23:08:08Z)" \
    "$(_retry IC_cr 1 2026-10-02T00:30:00Z 501)")"
  local status_now
  for status_now in queued in_progress; do
    : > "$GH_LOG"
    _recorded_run 501 "$status_now"
    run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "0" ]
    # It read the run, and found it live: nothing is posted or dispatched —
    # not for this comment, and not for the PR's other comment either.
    grep -q 'actions/runs/501$' "$GH_LOG"
    [[ "$output" == *"bot-comment IC_cr "*"retry-pending"* ]]
    [[ "$output" == *"bot-comment IC_ca "*"retry-pending"* ]]
    if grep -q -e '/dispatches' -e '--method POST' -e '--method PATCH' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
    # Only a cancelled run's jobs are read.
    if grep -q 'actions/runs/501/jobs' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  done
}

@test "sweep(#2262): a run that cannot be read, or that started before it was cancelled, is never treated as lost" {
  _setup_sweep
  _run_gh
  export TRUSTED_BOTS="$TRUSTED" GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_retry IC_cr 1 2026-10-02T00:30:00Z 501)")"

  # The run read fails (API error, or a token that cannot read Actions).
  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  [[ "$output" == *"::warning::"*"could not read Actions run 501"* ]]
  [[ "$output" == *"bot-comment IC_cr "*"retry-pending"* ]]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi

  # Cancelled, but its jobs cannot be read: whether it started is unknown.
  : > "$GH_LOG"
  _recorded_run 501 completed cancelled
  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  [[ "$output" == *"::warning::"*"could not read the jobs of cancelled Actions run 501"* ]]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi

  # Cancelled after a job ran a step: it did work, so it stays a pending attempt.
  : > "$GH_LOG"
  printf '%s' '{"total_count":1,"jobs":[{"name":"dev-lead / dispatch","conclusion":"cancelled",
    "steps":[{"name":"Set up job","conclusion":"success"}]}]}' > "$MOCK_BIN/jobs_501.json"
  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  grep -q 'actions/runs/501/jobs' "$GH_LOG"
  [[ "$output" != *"[lost]"* ]]
  [[ "$output" == *"bot-comment IC_cr "*"retry-pending"* ]]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi

  # The id reads back as some other kind of run: not ours to judge.
  : > "$GH_LOG"
  jq -c '.event = "issue_comment"' "$MOCK_BIN/run_501.json" > "$MOCK_BIN/run_501.tmp"
  mv "$MOCK_BIN/run_501.tmp" "$MOCK_BIN/run_501.json"
  _unstarted_jobs 501
  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  [[ "$output" == *"::warning::"*"did not read back as a repository_dispatch run"* ]]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep(#2262): a lane that keeps cancelling stops at BOT_COMMENT_RETRY_MAX_TOTAL" {
  _setup_sweep
  _run_gh
  export TRUSTED_BOTS="$TRUSTED" GRAPHQL_RESPONSE RUNS_LISTING
  export BOT_COMMENT_RETRY_MAX_TOTAL=3
  local n
  for n in 501 502 503; do _recorded_run "$n" completed cancelled; _unstarted_jobs "$n"; done
  RUNS_LISTING="$(_runs_listing "$(_listed_run 9001 2026-10-02T01:00:02Z)")"

  # Two cancelled retries: the third (and last) is dispatched.
  GRAPHQL_RESPONSE="$(_graphql_page \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_retry IC_cr 1 2026-10-01T23:30:00Z 501)" \
    "$(_retry IC_cr 2 2026-10-02T00:00:00Z 502)")"
  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "1" ]
  grep -q 'dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=3 ' "$GH_LOG"

  # Three cancelled retries: the ceiling holds, nothing is posted or dispatched.
  : > "$GH_LOG"
  GRAPHQL_RESPONSE="$(_graphql_page \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_retry IC_cr 1 2026-10-01T23:30:00Z 501)" \
    "$(_retry IC_cr 2 2026-10-02T00:00:00Z 502)" \
    "$(_retry IC_cr 3 2026-10-02T00:30:00Z 503)")"
  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0" ]
  [[ "$output" == *"bot-comment IC_cr "*"retry-attempts-exhausted"* ]]
  if grep -q -e '/dispatches' -e '--method POST' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

# ── #2262 review: backoff window, skipped steps, pairing race, lookup deadline ─

@test "bcr(#2262): a lost-retry backoff longer than the pending window still has the retry's run read" {
  export BOT_COMMENT_RETRY_PENDING_SEC=1200 BOT_COMMENT_RETRY_LOST_BACKOFF_SEC=3600
  cr="$(_bot IC_cr coderabbitai 'Walkthrough')"
  ca="$(_bot IC_ca codeant-ai 'Nitpicks' 2026-10-01T23:08:08Z)"
  # Dispatched 30 min ago: past the 20-min pending window, inside the 60-min
  # backoff. Unread, its run could not be known lost and the backoff would not hold.
  m="$(_retry IC_cr 1 2026-10-02T00:30:00Z 501)"
  [ "$(_run_ids "$cr" "$ca" "$m")" = '["501"]' ]
  out="$(_decide_runs "{\"501\":${RUN_LOST}}" "$cr" "$ca" "$m")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "retry-cancelled-backoff" ]
  [ "$(_reason_for "$out" IC_ca)" = "retry-cancelled-backoff" ]
  # Past both windows the run cannot change a decision, so it is not read.
  [ "$(_run_ids "$cr" "$ca" "$(_retry IC_cr 1 2026-10-01T23:50:00Z 501)")" = '[]' ]
}

@test "bcr_run_state(#2262): a job whose only steps were skipped did not start" {
  run_json='{"id":501,"event":"repository_dispatch","status":"completed","conclusion":"cancelled"}'
  skipped='{"total_count":1,"jobs":[{"conclusion":"cancelled","steps":[
    {"name":"Set up job","status":"completed","conclusion":"skipped"},
    {"name":"Run dev-lead","status":"completed","conclusion":"skipped"}]}]}'
  [ "$(bcr_run_state 501 "$run_json" "$skipped")" = "$RUN_LOST" ]
  # One step that ran among skipped ones: it started.
  mixed='{"total_count":1,"jobs":[{"conclusion":"cancelled","steps":[
    {"name":"Set up job","conclusion":"success"},{"name":"Run dev-lead","conclusion":"skipped"}]}]}'
  [ "$(bcr_run_state 501 "$run_json" "$mixed" | jq -r '.started')" = "true" ]
  # A cancelled step may have begun, and a step with no conclusion is unknown:
  # neither is read as "did not run".
  local steps
  for steps in '[{"name":"Set up job","conclusion":"cancelled"}]' '[{"name":"Set up job"}]' '["Set up job"]' '"not a list"'; do
    [ "$(bcr_run_state 501 "$run_json" "{\"total_count\":1,\"jobs\":[{\"conclusion\":\"cancelled\",\"steps\":${steps}}]}" | jq -r '.started')" = "true" ] \
      || { echo "steps <$steps>"; return 1; }
  done
}

@test "bcr(#2262): the pairing and the run state hold on the Actions API's own answers for PR #2205's cancelled retry" {
  # tests/fixtures/bot-comment-retry/ holds what GitHub returned on 2026-10-11
  # for the retry run of 2026-10-10T17:50:45Z, cut down to the fields read here:
  # the run listing for event=repository_dispatch around it (the other entry is
  # pr-review's dispatch nine seconds later), the run, and its jobs.
  local fx="$SCRIPT_DIR/tests/fixtures/bot-comment-retry"
  [ "$(bcr_pick_dispatched_run "$(cat "$fx/runs-listing-pr2205.json")" 2026-10-10T17:50:43Z)" \
    = '{"count":1,"id":"38073395880"}' ]
  [ "$(bcr_run_state 38073395880 "$(cat "$fx/run-38073395880.json")" "$(cat "$fx/run-38073395880-jobs.json")")" \
    = "$RUN_LOST" ]
}

# _listing_sequence <listing>… — call after _run_gh. The Actions run listing
# answers with each argument in turn, then repeats the last: what a listing that
# catches up between looks returns.
_listing_sequence() {
  local n=0 l
  for l in "$@"; do
    n=$((n + 1))
    printf '%s' "$l" > "$MOCK_BIN/listing_${n}.json"
  done
  : > "$MOCK_BIN/listing.calls"
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
dir="$(dirname "$0")"
args="$*"
case "$args" in
  *"/dispatches"*) cat > "$GH_LOG.payload"; exit 0 ;;
  *"api graphql"*) printf '%s' "$GRAPHQL_RESPONSE" ;;
  *"/actions/runs -f"*)
    echo look >> "$dir/listing.calls"
    n=$(wc -l < "$dir/listing.calls" | tr -d ' ')
    while [ ! -f "$dir/listing_${n}.json" ] && [ "$n" -gt 1 ]; do n=$((n - 1)); done
    cat "$dir/listing_${n}.json" ;;
  *"--method PATCH"*"/issues/comments/"*) exit 0 ;;
  *"--method POST"*"/comments"*) echo "777" ;;
  *"comments?per_page"*"dev-lead-bot-comment-retry id="*) echo "777" ;;
  *"/pulls/"*) printf '%s' "$PR_JSON" ;;
  *) echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"
}

@test "sweep(#2262): another PR's retry run listed before ours is not recorded as ours" {
  _setup_sweep
  _run_gh
  export TRUSTED_BOTS="$TRUSTED" GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"
  # First look: only another PR's retry run (9010) is listed. Second look: ours
  # (9001) has appeared beside it. One look would have recorded 9010.
  _listing_sequence \
    "$(_runs_listing "$(_listed_run 9010 2026-10-02T01:00:01Z)")" \
    "$(_runs_listing "$(_listed_run 9010 2026-10-02T01:00:01Z)" "$(_listed_run 9001 2026-10-02T01:00:02Z)")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "1" ]
  [ "$(grep -c 'actions/runs -f' "$GH_LOG")" -eq 2 ]
  [[ "$output" == *"cannot tell which"* ]]
  [ "$(_patches)" -eq 0 ]
}

@test "sweep(#2262): a run is recorded only once a second look shows the same single candidate" {
  _setup_sweep
  _run_gh
  export TRUSTED_BOTS="$TRUSTED" GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"
  local none one
  none="$(_runs_listing "$(_listed_run 8000 2026-10-02T00:59:40Z)")"
  one="$(_runs_listing "$(_listed_run 9001 2026-10-02T01:00:02Z)")"

  # Seen on the last look only: nothing confirms it, so nothing is recorded.
  _listing_sequence "$none" "$one"
  BOT_COMMENT_RETRY_RUN_LOOKUP_TRIES=2
  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "1" ]
  [ "$(grep -c 'actions/runs -f' "$GH_LOG")" -eq 2 ]
  [[ "$output" == *"run 9001"*"could not be confirmed"* ]]
  [ "$(_patches)" -eq 0 ]

  # With a look to spare the same candidate is confirmed and recorded.
  : > "$GH_LOG"
  _listing_sequence "$none" "$one"
  BOT_COMMENT_RETRY_RUN_LOOKUP_TRIES=3
  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "1" ]
  [ "$(grep -c 'actions/runs -f' "$GH_LOG")" -eq 3 ]
  grep -qF -- 'attempt=1 at=2026-10-02T01:00:00Z run=9001 -->' "$GH_LOG"
  [ "$(_patches)" -eq 1 ]
}

@test "sweep(#2262): past the lookup deadline a dispatch still counts and records no run" {
  _setup_sweep
  _run_gh
  export TRUSTED_BOTS="$TRUSTED" GRAPHQL_RESPONSE RUNS_LISTING
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"
  RUNS_LISTING="$(_runs_listing "$(_listed_run 9001 2026-10-02T01:00:02Z)")"
  # The scan has already run longer than the deadline allows.
  BOT_COMMENT_RETRY_RUN_LOOKUP_DEADLINE_SEC=0

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "1" ]
  [ "$(grep -c '/dispatches' "$GH_LOG")" -eq 1 ]
  [[ "$output" == *"limit for run lookups"* ]]
  if grep -q -e 'actions/runs' -e '--method PATCH' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep(#2262): a retry whose run was cancelled before any job was created is re-dispatched" {
  _setup_sweep
  _run_gh
  export TRUSTED_BOTS="$TRUSTED" GRAPHQL_RESPONSE RUNS_LISTING
  GRAPHQL_RESPONSE="$(_graphql_page \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_retry IC_cr 1 2026-10-02T00:30:00Z 501)")"
  _recorded_run 501 completed cancelled
  printf '%s' '{"total_count":0,"jobs":[]}' > "$MOCK_BIN/jobs_501.json"
  RUNS_LISTING="$(_runs_listing "$(_listed_run 9001 2026-10-02T01:00:02Z)")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"[lost]"*"run 501"* ]]
  grep -q 'dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=2 ' "$GH_LOG"
}
