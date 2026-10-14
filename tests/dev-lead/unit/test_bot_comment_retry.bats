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
  ! grep -qE '^\s*dispatch_(ci|reviews)_retry ' "$RETRY_SCRIPT"
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
  ! sed -n "${guard_line},${scan_line}p" "$REVIEW" | grep -qE '^\s*fi\s*$'
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
