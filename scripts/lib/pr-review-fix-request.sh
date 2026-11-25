#!/usr/bin/env bash
# pr-review-fix-request.sh — select pr-review's fix request for the fix-reviews
# pass (#2168, #2614).
#
# pr-review used to post a fix request as a PR issue comment, not a review thread,
# so the fix-reviews pass (which reads threads) never saw it, and its prompt told
# the model to skip every comment carrying a `<!-- pr-review-agent … -->` marker.
# The harness picks the request out before the engine runs and hands its body to
# the prompt as a declared variable.
#
# Since #2614 the fix request is a COMMENT review. Its line-cited findings are
# inline comments, so they reach the pass as ordinary open review threads with no
# route here. Only the review BODY (its marker pair and the findings that cite no
# line) still comes through this selector. COMMENTED review nodes are turned into
# the same node shape as comments (prfr_review_nodes), so one selector covers both
# a review and a legacy comment posted before the switch. Retiring this route
# needs a home for line-less findings first (#2614 AC3, follow-up).
#
# WHO MAY PUT TEXT INTO THE PROMPT THROUGH THIS ROUTE:
#   - The marker alone never makes a comment trusted: anyone can type it. Only a
#     comment AUTHORED by pr-review's own login (exact match) is selected, and that
#     login comes from the pr-review persona manifest next to the running scripts
#     (PR_REVIEW_USER override, donpetry-bot fallback). It is never BOT_USER (that
#     is dev-lead's own login) and never read from the PR's worktree.
#   - Text from any other account never reaches the prompt this way.
#   - An edited comment keeps its author's login whoever edited it, so an edited
#     (lastEditedAt set) or minimized comment is never selected. The same holds for
#     a review body; a review superseded by a newer one is edited (and starts with
#     the superseded sentinel), so it is never selected either.
#   - The pr-review body is itself written by a model that read an untrusted diff,
#     so even a selected body is passed as FINDINGS TO CHECK against the code,
#     JSON-encoded, never as commands.
#
# Sourced by dev-lead-fix-reviews.sh. Pure functions apart from the persona lookup.

# PRFR_MAX_CHARS: the cap on the selected body, the same bound as the other
# harness-computed prompt variables (an env string over 128 KiB stops envsubst and
# the agent subprocess from starting).
PRFR_MAX_CHARS=30000
# PRFR_MAX_BYTES: a second bound on the ENCODED body. JSON escapes control
# characters as six bytes each, so a 30,000-character body could still exceed
# MAX_ARG_STRLEN once encoded; the body is shortened until it fits.
PRFR_MAX_BYTES=100000

# prfr_pr_review_login <scripts_dir>: pr-review's acting login — the same lookup
# as pr_review_identity in dev-lead-retry.sh. <scripts_dir> is the directory of the
# RUNNING scripts (AGENT_SCRIPT_DIR), never a path inside the PR's worktree.
prfr_pr_review_login() {
  local scripts_dir="$1" login="${PR_REVIEW_USER:-}"
  if [[ -z "$login" ]]; then
    login=$(bash "$scripts_dir/lib/resolve-persona-identity.sh" pr-review \
      "$scripts_dir/../personas" account 2>/dev/null || true)
    login="${login:-donpetry-bot}"
  fi
  printf '%s' "$login"
}

# prfr_select_fix_request <comments_json> <login> <live_head>
#   Prints the newest comment node (compact JSON) that is pr-review's fix request
#   at <live_head>, or nothing. All of these must hold:
#     - author.login == <login> exactly;
#     - the body STARTS with
#       `<!-- pr-review-agent v1 sha=<live_head> --> <!-- decision=fix-requested risk=<RISK>[ meta=<16 hex>] -->`
#       (a stale sha, a superseded body, or a marker quoted further down fails);
#     - isMinimized is false and lastEditedAt is present and null.
#   <live_head> must be a full 40-character sha. Exit status is non-zero when
#   <login> or <live_head> is malformed, or <comments_json> is not parseable.
prfr_select_fix_request() {
  local comments="$1" login="$2" head="$3"
  [[ "$login" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$ ]] || return 1
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  jq -c --arg login "$login" --arg head "$head" '
    ("\\A<!-- pr-review-agent v1 sha=" + $head
      + " --> <!-- decision=fix-requested risk=[A-Za-z0-9_]*( meta=[0-9a-f]{16})? -->") as $re
    | [ .[]? | objects
        | select((.author.login? // null) == $login)
        | select(.isMinimized == false)
        | select(has("lastEditedAt") and .lastEditedAt == null)
        | select((.body | type) == "string" and (.body | test($re)))
      ]
    | sort_by(.createdAt // "") | last // empty
  ' <<< "$comments" 2>/dev/null
}

# prfr_encode_body <node_json>: prints the node's body as one JSON string, capped
# at PRFR_MAX_CHARS characters (and PRFR_MAX_BYTES encoded bytes), then a line
# `truncated` when it was shortened.
prfr_encode_body() {
  jq -r --argjson maxc "$PRFR_MAX_CHARS" --argjson maxb "$PRFR_MAX_BYTES" '
    (.body // "") as $b
    | ([($b | length), $maxc] | min) as $n0
    | [$n0] | until(($b[0:.[0]] | tojson | utf8bytelength) <= $maxb; [(.[0] * 3 / 4 | floor)]) | .[0] as $n
    | ($b[0:$n] | tojson), (if $n < ($b | length) then "truncated" else empty end)
  ' <<< "$1"
}

# prfr_review_nodes <reviews_json>: turns GraphQL review nodes (id, author.login,
# body, state, submittedAt, lastEditedAt) into selector nodes. Only COMMENTED
# reviews are kept: a fix request is never posted with another state (#2614).
# submittedAt becomes createdAt so a review and a comment sort together. A review
# cannot be minimized, so isMinimized is false. Missing lastEditedAt stays absent,
# so prfr_select_fix_request rejects the node. Non-zero on unparseable input.
prfr_review_nodes() {
  jq -c '
    if type != "array" then error("not an array") else . end
    | [ .[] | objects
        | select(.state == "COMMENTED")
        | {id, author, body, createdAt: (.submittedAt // ""), isMinimized: false, kind: "review"}
          + (if has("lastEditedAt") then {lastEditedAt} else {} end) ]
  ' <<< "$1" 2>/dev/null
}

# prfr_fetch_review_nodes <repo> <pr_number>: every review on the PR as selector
# nodes (prfr_review_nodes), paginated. Non-zero, with no output, when any page
# cannot be read: the caller reports "could not be determined", never "none".
prfr_fetch_review_nodes() {
  local repo="$1" pr="$2" cursor="" page all='[]' has_next
  # shellcheck disable=SC2016  # $owner/$repo/$pr/$cursor are GraphQL variables
  local query='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
    repository(owner:$owner,name:$repo){ pullRequest(number:$pr){
      reviews(first:100,after:$cursor){
        pageInfo{hasNextPage endCursor}
        nodes{ id author{login} body state submittedAt lastEditedAt }
      } } } }'
  while :; do
    local cursor_args=()
    [[ -n "$cursor" ]] && cursor_args=(-f "cursor=$cursor")
    page=$(gh api graphql -f query="$query" -F owner="${repo%%/*}" -F repo="${repo##*/}" \
      -F pr="$pr" "${cursor_args[@]}" 2>/dev/null) || return 1
    jq -e '.data.repository.pullRequest.reviews.nodes | type == "array"' <<< "$page" >/dev/null 2>&1 || return 1
    all=$(jq -c --argjson acc "$all" '$acc + .data.repository.pullRequest.reviews.nodes' <<< "$page") || return 1
    has_next=$(jq -r '.data.repository.pullRequest.reviews.pageInfo.hasNextPage // false' <<< "$page")
    cursor=$(jq -r '.data.repository.pullRequest.reviews.pageInfo.endCursor // ""' <<< "$page")
    [[ "$has_next" == "true" && -n "$cursor" ]] || break
  done
  prfr_review_nodes "$all"
}
