#!/usr/bin/env bash
# bot-thread-retry.sh — retry a lost fix-reviews pass for unreplied trusted-bot
# review threads (#2046). The review-thread counterpart of bot-comment-retry.sh
# (#2017), which covers only PR issue comments.
#
# WHY THIS EXISTS
#   A trusted reviewer bot's review thread is processed only by a dev-lead
#   fix-reviews pass. When that pass is lost, nothing retried it. The pass can be
#   superseded in the per-PR concurrency lane, the event can route elsewhere, or
#   the pass can run without seeing the thread (the old single-page thread query,
#   see open-review-threads.sh). The thread then sits with no reply and no
#   resolution, and required_review_thread_resolution blocks the merge. On PR
#   #1953 eleven cubic and Codex threads had no reply at all.
#
# WHAT THIS LIBRARY DECIDES (btr_retry_decisions, PURE — no gh/network)
#   A CANDIDATE thread is unresolved, not outdated, and its originating comment is
#   by a `Bot` that is a trusted registered reviewer source. Outdated, resolved and
#   maintainer (User-originated) threads are never candidates. For each candidate:
#     replied                  some later comment in the thread is by our own
#                              automation (dev-lead/pr-review) — a fix, a deferral
#                              or a skip note all count; the thread was processed
#     thread-unreadable        the thread has more comments than were fetched, so
#                              a reply could be hidden; fail closed
#     retry-pending            a thread retry marker on this PR is younger than the
#                              pending window. The marker can name any thread: one
#                              fix-reviews pass sees every thread, and a second
#                              dispatch would supersede it in the per-PR lane
#     rate-limited             a fix-reviews pass on this PR ended rate-limited (or
#                              blocked) and its reset= time is still ahead
#     retry-attempts-exhausted the thread already had MAX retries since the last
#                              rate-limited end (an attempt that ran into the limit
#                              does not count), or MAX_TOTAL in all
#     grace-period             the thread is too new: the original event-driven run
#                              may still be pending or running
#     unreplied                otherwise → dispatch, as attempt <previous + 1>
#
#   Only markers and replies from our own automation count: the author's login
#   must be one of <automation_logins_csv>. A marker must also carry a trusted
#   association (OWNER/MEMBER/COLLABORATOR), as in bot-comment-retry.sh (CWE-863).
#
# SECURITY: nothing here (or in the sweep that uses it) replies to, resolves or
#   minimizes a thread. A retry only dispatches a fix-reviews pass, whose replies
#   and resolutions go through the harness's usual verification.
#
# Tunables (env), defaults mirror bot-comment-retry.sh:
#   BOT_THREAD_RETRY_MIN_AGE_SEC   grace for the original run (default 900 = 15 min)
#   BOT_THREAD_RETRY_PENDING_SEC   how long a dispatched retry is treated as still
#                                  pending/running (default 9000 = 150 min)
#   BOT_THREAD_RETRY_MAX_ATTEMPTS  retries per thread since the last rate-limited
#                                  end (default 2)
#   BOT_THREAD_RETRY_MAX_TOTAL     hard ceiling on retries per thread, rate-limited
#                                  ones included (default 6)

BTR_RETRY_MARKER_NAME="dev-lead-bot-thread-retry"
BTR_EXHAUSTED_MARKER_NAME="dev-lead-bot-thread-retry-exhausted"

# btr_retry_decisions <threads_json> <comments_json> <trusted_bots_csv> <now_epoch> <automation_logins_csv>
#   <threads_json>   the PR's review-thread nodes, each {id, isResolved, isOutdated,
#                    path, line, comments{totalCount, nodes[{author{login,
#                    __typename}, body, createdAt}]}} (btr_fetch_pr_threads)
#   <comments_json>  the PR's issue-comment nodes, which carry the retry, notice and
#                    fix-reviews markers (bcr_fetch_pr_comments)
#   <trusted_bots_csv> registered bots dev-lead acts on (the [bot] suffix is optional)
#   <now_epoch>      current time, unix seconds
#   <automation_logins_csv> the logins our own automation posts as; required
# Echoes one compact JSON object:
#   {threads: [{id, login, path, line, attempt, decision, reason}] (oldest first),
#    dispatch: [ids to retry now], attempt: <attempt number for the retry marker>,
#    exhausted: [ids out of attempts], exhausted_unnoticed: [those not yet named by
#    an exhaustion notice]}
# Returns non-zero (echoing nothing) when the input cannot be evaluated, so a
# caller fails closed rather than dispatching on a misread.
btr_retry_decisions() {
  local threads="${1:-}" comments="${2:-}" trusted_csv="${3:-}" now_epoch="${4:-}"
  local automation_csv="${5:-}"
  [[ "$now_epoch" =~ ^[0-9]+$ ]] || return 1
  [[ "$automation_csv" =~ [A-Za-z0-9] ]] || return 1
  local min_age="${BOT_THREAD_RETRY_MIN_AGE_SEC:-900}"
  local pending="${BOT_THREAD_RETRY_PENDING_SEC:-9000}"
  local max_attempts="${BOT_THREAD_RETRY_MAX_ATTEMPTS:-2}"
  local max_total="${BOT_THREAD_RETRY_MAX_TOTAL:-6}"
  [[ "$min_age" =~ ^[0-9]+$ ]] || min_age=900
  [[ "$pending" =~ ^[0-9]+$ ]] || pending=9000
  [[ "$max_attempts" =~ ^[0-9]+$ ]] || max_attempts=2
  [[ "$max_total" =~ ^[0-9]+$ ]] || max_total=6

  # Both arrays go through stdin, not --argjson: a busy PR's threads or comments
  # can exceed the kernel's per-argument size limit.
  printf '%s\n%s\n' "$threads" "$comments" | jq -sce \
    --arg trusted "$trusted_csv" \
    --arg automation "$automation_csv" \
    --arg retry_name "$BTR_RETRY_MARKER_NAME" \
    --arg notice_name "$BTR_EXHAUSTED_MARKER_NAME" \
    --arg sibling_name "dev-lead-bot-comment-retry" \
    --argjson now "$now_epoch" \
    --argjson min_age "$min_age" \
    --argjson pending "$pending" \
    --argjson max_attempts "$max_attempts" \
    --argjson max_total "$max_total" '
    def bare: if endswith("[bot]") then .[0:-5] else . end;
    def epoch: (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601);
    def vepoch: if type == "string" then (try epoch catch null) else null end;
    # Attribute strings of every <!-- <name> ... --> marker in this comment body.
    # The name must be followed by whitespace, so the retry marker never matches
    # the exhaustion notice (<name>-exhausted).
    def markers($name): [ (.body // "") | scan("<!--\\s*" + $name + "\\s+([^>]*?)\\s*-->") | .[0] ];
    def attr($k): [ scan("(?:^|\\s)" + $k + "=(\\S+)") | .[0] ] | first // null;
    def ids: (attr("threads") // "") | split(",") | map(select(length > 0));

    if length != 2 or (.[0] | type) != "array" or (.[1] | type) != "array"
    then error("threads and comments must be arrays") else . end
    | .[0] as $threads | .[1] as $comments
    | ($trusted | split(",") | map(gsub("^\\s+|\\s+$"; "") | bare) | map(select(length > 0))) as $tb
    | ($automation | split(",") | map(gsub("^\\s+|\\s+$"; "") | bare) | map(select(length > 0))) as $auto
    | [ $comments[] | objects
        | select((.author?.login // "" | tostring | bare) as $l | ($auto | index($l)) != null)
        | select(((.authorAssociation // "") as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a)) != null)
        | (.createdAt | epoch) as $t
        | {t: $t,
           hold: (markers("dev-lead-fix-reviews") | map(select(attr("intent") == "fix-reviews"))
                  | map(select(attr("status") == "rate-limited" or attr("status") == "blocked"))
                  | map((attr("reset") | vepoch) // ($t + $pending))),
           retry: (markers($retry_name) | map(ids)),
           sibling: (markers($sibling_name) | length),
           notice: (markers($notice_name) | map(ids))} ] as $notes
    | ([ $notes[] | select((.hold | length) > 0) | .t ] | max) as $last_hold
    | ([ $notes[] | .hold[] | select(. != null) ] | max) as $hold_until
    # A pending bot-comment retry holds the per-PR lane too: a second dispatch
    # would supersede it, so it counts as pending here.
    | ([ $notes[] | select((.retry | length) > 0 or .sibling > 0) | .t ] | max) as $last_retry
    | ([ $notes[] | .notice[][] ] | unique) as $noticed
    | [ $threads[] | objects
        | select((.isResolved | type) == "boolean" and (.isOutdated | type) == "boolean"
                 and .isResolved == false and .isOutdated == false)
        | ((.comments?.nodes // []) | if type == "array" then . else [] end) as $cs
        | select(($cs | length) > 0)
        | ($cs[0].author?.login // "" | tostring | bare) as $l
        | select($l != "" and ($tb | index($l)) != null)
        | select(($cs[0].author?.__typename // "") == "Bot")
        | .id as $id
        | ($cs[0].createdAt | epoch) as $ct
        | ([ $cs[1:][] | select((.author?.login // "" | tostring | bare) as $r | ($auto | index($r)) != null) ]
           | length > 0) as $replied
        | (.comments?.totalCount) as $tc
        | (if ($tc | type) == "number" then $tc > ($cs | length) else true end) as $truncated
        | [ $notes[] | .t as $t | .retry[] | select(index($id) != null) | $t ] as $retries
        | ($retries | length) as $attempts
        | ([ $retries[] | select($last_hold == null or . > $last_hold) ] | length) as $counted
        | {id: $id, login: $l, path: (.path // null), line: (.line // null),
           created: $ct, attempt: ($attempts + 1)}
        + ( if $replied then {decision: "skip", reason: "replied"}
            elif $truncated then {decision: "skip", reason: "thread-unreadable"}
            elif ($last_retry != null and ($now - $last_retry) < $pending)
              then {decision: "skip", reason: "retry-pending"}
            elif ($hold_until != null and $hold_until > $now) then {decision: "skip", reason: "rate-limited"}
            elif ($counted >= $max_attempts or $attempts >= $max_total)
              then {decision: "skip", reason: "retry-attempts-exhausted"}
            elif ($now - $ct) < $min_age then {decision: "skip", reason: "grace-period"}
            else {decision: "dispatch", reason: "unreplied"}
            end )
      ]
    | sort_by(.created) | map(del(.created))
    | { threads: .,
        dispatch: [ .[] | select(.decision == "dispatch") | .id ],
        attempt: ([ .[] | select(.decision == "dispatch") | .attempt ] | max),
        exhausted: [ .[] | select(.reason == "retry-attempts-exhausted") | .id ] }
    | .exhausted_unnoticed = [ .exhausted[] | . as $e | select(($noticed | index($e)) == null) ]
  ' 2>/dev/null
}

# btr_fetch_pr_threads <repo> <pr_number>
#   Echo every review-thread node (paginated GraphQL) as one JSON array with the
#   fields btr_retry_decisions reads. Returns 1 (echoing nothing) on any API or
#   parse failure: a partial snapshot fails closed.
btr_fetch_pr_threads() {
  local repo="$1" pr="$2"
  # shellcheck disable=SC2016  # $owner/$repo/$pr/$cursor are GraphQL variables
  local query='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        reviewThreads(first:100,after:$cursor){
          pageInfo{hasNextPage endCursor}
          nodes{ id isResolved isOutdated path line
            comments(first:100){ totalCount nodes{ author{login __typename} createdAt } } }
        }
      }
    }
  }'
  local all='[]' has_next="true" cursor prior_cursor="" page nodes
  local cursor_args=()
  while [[ "$has_next" = "true" ]]; do
    page=$(gh api graphql -f query="$query" -F owner="${repo%%/*}" -F repo="${repo##*/}" \
      -F pr="$pr" "${cursor_args[@]}" 2>/dev/null) || return 1
    printf '%s' "$page" | jq -e '(.errors // []) | length == 0' >/dev/null 2>&1 || return 1
    nodes=$(printf '%s' "$page" | jq -ce '.data.repository.pullRequest.reviewThreads.nodes | arrays' 2>/dev/null) \
      || return 1
    all=$(jq -cn --argjson a "$all" --argjson b "$nodes" '$a + $b') || return 1
    has_next=$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage
      | if type == "boolean" then tostring else "invalid" end' 2>/dev/null) || return 1
    case "$has_next" in true|false) ;; *) return 1 ;; esac
    cursor=$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""')
    if [[ "$has_next" = "true" ]] && [[ -z "$cursor" ]]; then
      return 1
    fi
    if [[ "$has_next" = "true" ]] && [[ "$cursor" = "$prior_cursor" ]]; then
      return 1
    fi
    prior_cursor="$cursor"
    cursor_args=(-f "cursor=${cursor}")
  done
  printf '%s\n' "$all"
}

# btr_retry_marker <thread_ids_csv> <attempt> <now_iso>
#   The hidden dedup marker the sweep posts BEFORE dispatching. It carries the
#   `dev-lead` prefix, so the maintainer-comment gate never counts it as a finding.
btr_retry_marker() {
  printf '<!-- %s threads=%s attempt=%s at=%s -->' "$BTR_RETRY_MARKER_NAME" "$1" "$2" "$3"
}

# btr_exhausted_marker <thread_ids_csv>
#   The hidden marker on the exhaustion notice, so each exhausted thread is noticed
#   once.
btr_exhausted_marker() {
  printf '<!-- %s threads=%s -->' "$BTR_EXHAUSTED_MARKER_NAME" "$1"
}
