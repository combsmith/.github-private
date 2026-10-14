#!/usr/bin/env bats
# Unit tests for dev-lead-intent.sh — the fix-bot-comment RETRY dispatch (#2017).
#
# A `dev-lead-reviews-retry` with intent_type=fix-bot-comment carries only the
# comment's node id. The classifier must re-fetch the comment BY NODE ID (its
# CURRENT, possibly edited body, author and lastEditedAt) and re-check every
# fix-bot-comment precondition — it must never trust a body from the payload.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
INTENT_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-intent.sh"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  export BOT_USER="don-petry"
  export TRUSTED_BOTS="coderabbitai[bot],codeant-ai[bot],chatgpt-codex-connector[bot]"
  export TRIGGER_PHRASES="@dev-lead"
  export GITHUB_REPOSITORY="petry-projects/.github-private"
  export GITHUB_EVENT_NAME="repository_dispatch"
  MOCK_BIN="$(mktemp -d)"
  export PATH="$MOCK_BIN:$PATH"
  export GH_LOG="$MOCK_BIN/gh.log"
  # Defaults; tests override.
  export NODE_JSON=""
  export COMMENTS_JSON='[]'
  cat > "$MOCK_BIN/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *"/labels"*) exit 0 ;;
  *"api graphql"*"node(id"*) printf '%s' "$NODE_JSON" ;;
  *"api graphql"*) jq -nc --argjson n "$COMMENTS_JSON" \
       '{data:{repository:{pullRequest:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$n}}}}}' ;;
  # Any other call is unexpected in the classify path — fail it so a new API
  # call surfaces as a test failure instead of silently returning empty data.
  *) exit 1 ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"
  EVENT_FILE="$(mktemp --suffix=.json)"
  export GITHUB_EVENT_PATH="$EVENT_FILE"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$EVENT_FILE"
  rm -rf "$MOCK_BIN"
}

_get_env() {
  local key="$1" delim_line delimiter
  delim_line=$(grep "^${key}<<" "$GITHUB_ENV" 2>/dev/null | head -1)
  if [ -n "$delim_line" ]; then
    delimiter="${delim_line#*<<}"
    awk -v start="${key}<<${delimiter}" -v end="${delimiter}" \
      'found && $0==end{exit} found{print} $0==start{found=1}' "$GITHUB_ENV"
    return
  fi
  grep "^${key}=" "$GITHUB_ENV" | cut -d= -f2- | head -1
}

_ctx() { _get_env INTENT_CONTEXT | jq -r ".$1 // empty"; }

# _event [node_id] [body-in-payload]
_event() {
  jq -nc --arg id "${1-IC_cr}" --arg b "${2:-}" '
    {action:"dev-lead-reviews-retry",
     client_payload:({pr_number:2009, repo:"petry-projects/.github-private",
                      intent_type:"fix-bot-comment"}
                     + (if $id == "" then {} else {comment_node_id:$id} end)
                     + (if $b == "" then {} else {body:$b} end))}' > "$EVENT_FILE"
}

# _node <login> <body> [minimizedReason] [pr_number] [pr_author] [state] [lastEditedAt]
#       [author_typename] [isCrossRepository] [repo]
_node() {
  NODE_JSON="$(jq -nc --arg l "$1" --arg b "$2" --arg m "${3:-}" \
    --argjson pr "${4:-2009}" --arg pa "${5:-don-petry}" --arg st "${6:-OPEN}" \
    --arg e "${7:-}" --arg ty "${8-Bot}" --argjson cross "${9:-false}" \
    --arg repo "${10:-petry-projects/.github-private}" '
    {data:{node:{id:"IC_cr", author:({login:$l} + (if $ty == "" then {} else {__typename:$ty} end)), body:$b,
      createdAt:"2026-10-01T23:05:43Z", lastEditedAt:(if $e == "" then null else $e end),
      isMinimized:($m != ""), minimizedReason:(if $m == "" then null else $m end),
      pullRequest:{number:$pr, state:$st, isCrossRepository:$cross, author:{login:$pa},
                   repository:{nameWithOwner:$repo}}}}}')"
  export NODE_JSON
}

# The PR's own copy of the bot comment, as the disposition check reads it.
CR_NODE='{"id":"IC_cr","author":{"login":"coderabbitai","__typename":"Bot"},"authorAssociation":"NONE",
    "body":"Walkthrough","createdAt":"2026-10-01T23:05:43Z","lastEditedAt":null,"isMinimized":false,"minimizedReason":null}'

@test "bot-comment retry: re-fetches the comment by node id and routes to fix-bot-comment with its CURRENT body" {
  _event IC_cr "STALE PAYLOAD BODY"
  _node coderabbitai "Edited walkthrough — current body" "" 2009 don-petry OPEN 2026-10-01T23:40:00Z

  run bash "$INTENT_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "fix-bot-comment" ]
  [ "$(_get_env INTENT_REASON)" = "bot-comment-retry-dispatch" ]
  [ "$(_ctx body)" = "Edited walkthrough — current body" ]
  [ "$(_ctx comment_node_id)" = "IC_cr" ]
  # The version of the body it read, for the pass's terminal marker.
  [ "$(_ctx comment_version)" = "2026-10-01T23:40:00Z" ]
  [ "$(_ctx actor)" = "coderabbitai[bot]" ]
  [ "$(_ctx pr_number)" = "2009" ]
  # It asked for the node by id (not a body search) and read lastEditedAt.
  grep -q 'node(id' "$GH_LOG"
  grep -q 'lastEditedAt' "$GH_LOG"
  grep -q 'id=IC_cr' "$GH_LOG"
}

@test "bot-comment retry: payload without a comment node id → skip (cannot target a disposition)" {
  _event ""

  run bash "$INTENT_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "bot-comment-retry-no-node-id" ]
}

@test "bot-comment retry: malformed node id → skip" {
  _event 'IC_cr"; rm -rf /'

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "bot-comment-retry-no-node-id" ]
}

@test "bot-comment retry: node fetch fails → skip (fail closed)" {
  _event IC_cr
  export NODE_JSON='{"errors":[{"message":"Could not resolve to a node"}]}'

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "bot-comment-retry-fetch-failed" ]
}

@test "bot-comment retry: comment already minimized RESOLVED → skip" {
  _event IC_cr
  _node coderabbitai "Walkthrough" RESOLVED

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "bot-comment-already-resolved" ]
}

@test "bot-comment retry: comment already carries a current disposition → skip" {
  _event IC_cr
  _node coderabbitai "Walkthrough"
  export COMMENTS_JSON='[{"id":"IC_cr","author":{"login":"coderabbitai","__typename":"Bot"},"authorAssociation":"NONE",
    "body":"Walkthrough","createdAt":"2026-10-01T23:05:43Z","lastEditedAt":null,"isMinimized":false,"minimizedReason":null},
    {"id":"IC_d","author":{"login":"don-petry","__typename":"User"},"authorAssociation":"OWNER",
    "body":"<!-- dev-lead:comment-disposition id=IC_cr disposition=informational -->\nok",
    "createdAt":"2026-10-01T23:30:00Z","lastEditedAt":null,"isMinimized":false,"minimizedReason":null}]'

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "bot-comment-already-dispositioned" ]
}

@test "bot-comment retry: info_status_pattern notice → skip" {
  _event IC_cr
  _node chatgpt-codex-connector "You have reached your Codex usage limits for code reviews."

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "info-status-notice" ]
}

@test "bot-comment retry: author is not a trusted bot → skip" {
  _event IC_cr
  _node alice "please change this"

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "bot-comment-retry-untrusted-author" ]
}

@test "bot-comment retry: comment belongs to a different PR → skip" {
  _event IC_cr
  _node coderabbitai "Walkthrough" "" 1234

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "bot-comment-retry-pr-mismatch" ]
}

@test "bot-comment retry: PR is closed → skip" {
  _event IC_cr
  _node coderabbitai "Walkthrough" "" 2009 don-petry MERGED

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "pr-already-closed" ]
}

@test "bot-comment retry: PR not dev-lead authored → skip" {
  _event IC_cr
  _node coderabbitai "x" "" 2009 alice

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "not-dev-lead-authored" ]
}

@test "bot-comment retry: a dev-lead/issue-* branch name alone is not ownership (author is someone else) → skip" {
  _event IC_cr
  # The query no longer even reads the branch name: ownership is author + same-repo head.
  _node coderabbitai "x" "" 2009 mallory

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_REASON)" = "not-dev-lead-authored" ]
  ! grep -q 'headRefName' "$GH_LOG"
}

@test "bot-comment retry: a cross-repository (fork) head → skip, even when dev-lead is the author" {
  _event IC_cr
  _node coderabbitai "x" "" 2009 don-petry OPEN "" Bot true

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "not-dev-lead-authored" ]
}

@test "bot-comment retry: a same-numbered PR in ANOTHER repository → skip (pr-mismatch)" {
  _event IC_cr
  _node coderabbitai "x" "" 2009 don-petry OPEN "" Bot false "someone/else"

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "bot-comment-retry-pr-mismatch" ]
}

@test "bot-comment retry: a trusted-bot login with author type User → skip" {
  _event IC_cr
  _node coderabbitai "x" "" 2009 don-petry OPEN "" User

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "bot-comment-retry-untrusted-author" ]
}

@test "bot-comment retry: a missing author type → skip (fail closed)" {
  _event IC_cr
  _node coderabbitai "x" "" 2009 don-petry OPEN "" ""

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "bot-comment-retry-untrusted-author" ]
}

@test "bot-comment retry: a bot login carrying the [bot] suffix is normalized and routed" {
  _event IC_cr
  _node "coderabbitai[bot]" "Walkthrough"
  export COMMENTS_JSON="[${CR_NODE}]"

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "fix-bot-comment" ]
  [ "$(_ctx actor)" = "coderabbitai[bot]" ]
}

@test "bot-comment retry: a fix-bot-comment pass already completed on this version → skip" {
  _event IC_cr
  _node coderabbitai "Walkthrough"
  export COMMENTS_JSON='[{"id":"IC_cr","author":{"login":"coderabbitai","__typename":"Bot"},"authorAssociation":"NONE",
    "body":"Walkthrough","createdAt":"2026-10-01T23:05:43Z","lastEditedAt":null,"isMinimized":false,"minimizedReason":null},
    {"id":"IC_t","author":{"login":"don-petry"},"authorAssociation":"OWNER",
    "body":"<!-- dev-lead-fix-reviews pr=2009 sha=abc intent=fix-bot-comment status=no-changes comment=IC_cr -->",
    "createdAt":"2026-10-01T23:30:00Z","lastEditedAt":null,"isMinimized":false,"minimizedReason":null}]'

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "bot-comment-pass-completed" ]
}

@test "bot-comment retry: unreadable PR comment list → skip (fail closed; never a blind pass)" {
  _event IC_cr
  _node coderabbitai "Walkthrough"
  export COMMENTS_JSON='null'

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "bot-comment-retry-state-unreadable" ]
}

@test "bot-comment retry: a disposition from another member (not dev-lead) does not suppress the pass" {
  _event IC_cr
  _node coderabbitai "Walkthrough"
  export COMMENTS_JSON="[${CR_NODE},
    {\"id\":\"IC_m\",\"author\":{\"login\":\"mallory\",\"__typename\":\"User\"},\"authorAssociation\":\"MEMBER\",
    \"body\":\"<!-- dev-lead:comment-disposition id=IC_cr disposition=invalid -->\",
    \"createdAt\":\"2026-10-01T23:30:00Z\",\"lastEditedAt\":null,\"isMinimized\":false,\"minimizedReason\":null}]"

  run bash "$INTENT_SCRIPT"
  [ "$(_get_env INTENT_TYPE)" = "fix-bot-comment" ]
}
