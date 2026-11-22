#!/usr/bin/env bash
# pr-review-fix-request.sh — select pr-review's fix request for the fix-reviews
# pass (#2168).
#
# pr-review posts a fix request as a PR issue comment, not a review thread, so the
# fix-reviews pass (which reads threads) never saw it, and its prompt told the model
# to skip every comment carrying a `<!-- pr-review-agent … -->` marker. The harness
# now picks the request out before the engine runs and hands its body to the
# prompt as a declared variable.
#
# WHO MAY PUT TEXT INTO THE PROMPT THROUGH THIS ROUTE:
#   - The marker alone never makes a comment trusted: anyone can type it. Only a
#     comment AUTHORED by pr-review's own login (exact match) is selected, and that
#     login comes from the pr-review persona manifest next to the running scripts
#     (PR_REVIEW_USER override, donpetry-bot fallback). It is never BOT_USER (that
#     is dev-lead's own login) and never read from the PR's worktree.
#   - Text from any other account never reaches the prompt this way.
#   - An edited comment keeps its author's login whoever edited it, so an edited
#     (lastEditedAt set) or minimized comment is never selected.
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
  if [ -z "$login" ]; then
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
#   <live_head> must be a full 40-character sha; anything else selects nothing.
#   Exit status is non-zero only when <comments_json> is not parseable.
prfr_select_fix_request() {
  local comments="$1" login="$2" head="$3"
  [[ "$login" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$ ]] || return 0
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 0
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
