#!/usr/bin/env bash
# bot-comment-retry.sh — retry a lost fix-bot-comment pass for an undispositioned
# registered reviewer-bot PR issue comment (#2017).
#
# WHY THIS EXISTS
#   A registered bot's PR issue comment is dispositioned ONLY by dev-lead's
#   fix-bot-comment intent, and the maintainer-comment gate withholds approval
#   until it is (#1813). Every PR event shares one concurrency lane
#   (dev-lead-pr-<N>), and GitHub keeps at most ONE pending run per group: a burst
#   of bot comments right after a PR opens supersedes the pending fix-bot-comment
#   runs before they start (#2009: the CodeRabbit and CodeAnt runs were cancelled
#   with zero steps while the `opened` run held the lane). Nothing retried them, so
#   the PR sat green behind the gate until a human @mentioned dev-lead.
#
#   The comment still exists, so — unlike on-mention's USER_INSTRUCTION — its
#   context CAN be reconstructed: the retry pass re-fetches it by node id.
#
# WHAT THIS LIBRARY DECIDES (bcr_retry_decisions, PURE — no gh/network)
#   For each candidate comment — authored by a trusted registered reviewer bot,
#   not agent-marked, not minimized RESOLVED (unless it was edited after its
#   newest covering disposition, which the gate re-blocks: #2008, #2166), not
#   cleared by its source's info_status_pattern (the same filters the gate
#   applies) — whether to dispatch
#   a fix-bot-comment retry now. A comment's VERSION is lastEditedAt // createdAt;
#   all coverage checks are against the current version, so an edit re-opens it.
#     dispositioned            a `dev-lead:comment-disposition id=<id>` reply exists
#                              at/after the version → covered, nothing to do
#     pass-completed           a fix-bot-comment pass already ended on this version
#                              (its terminal marker carries `comment=<id>` and the
#                              `version=` it processed) without a disposition → do
#                              not loop; only an edit re-opens
#     retry-pending            a retry marker for this version is younger than the
#                              pending window → that retry may still be queued or
#                              running; never duplicate it
#     rate-limited             a fix-bot-comment pass on this PR ended rate-limited
#                              (or blocked) and its reset= time is still ahead
#     retry-attempts-exhausted this version already had MAX retry attempts since the
#                              last rate-limited end (an attempt that ended rate-
#                              limited does not count), or MAX_TOTAL in all
#     grace-period             the comment is too new — the original event-driven
#                              run may still be pending or running
#     (dispatch)               otherwise, as attempt <previous attempts + 1>
#
#   Only markers posted by our own automation count: the author's login must be
#   one of <automation_logins_csv> (dev-lead's and pr-review's acting identities)
#   AND carry a trusted association (OWNER/MEMBER/COLLABORATOR). Neither an outside
#   commenter nor another repository member can forge a disposition that
#   suppresses the retry or a marker that blocks it (CWE-863). This matches the
#   resolver, which only honours a disposition authored by dev-lead's identity
#   (cdv_select_disposition).
#
# SECURITY: nothing here (or in the sweep that uses it) minimizes or resolves a
#   comment. A retry only causes dev-lead to post a disposition, which the harness
#   then verifies as usual (resolve_dispositioned_comments). The gate is unchanged.
#
# Tunables (env):
#   BOT_COMMENT_RETRY_MIN_AGE_SEC   grace for the original run (default 900 = 15 min)
#   BOT_COMMENT_RETRY_PENDING_SEC   how long a dispatched retry is treated as still
#                                   pending/running (default 9000 = 150 min: the
#                                   dispatch job's 120-min timeout plus queue time)
#   BOT_COMMENT_RETRY_MAX_ATTEMPTS  retries per comment version since the last
#                                   rate-limited end (default 2)
#   BOT_COMMENT_RETRY_MAX_TOTAL     hard ceiling on retries per comment version,
#                                   rate-limited ones included (default 6)
#   BOT_COMMENT_RETRY_VERSION_SKEW_SEC  tolerance when matching a pass's stamped
#                                   version to the comment's version (default 2):
#                                   an edited comment's version comes from the
#                                   webhook's updated_at, which can trail GraphQL's
#                                   lastEditedAt by a second. A pass stamped with
#                                   the comment's exact createdAt processed the
#                                   creation, so the skew never lets it cover an
#                                   edit made seconds later.

# The gate's agent-marker regex and info-status registry reader — one source of
# truth for "which comments need a disposition" (#1813 / #1918). Source the gate
# library only if the caller has not already (its marker regex is readonly).
if [ -z "${_MAINTAINER_GATE_AGENT_MARKERS:-}" ]; then
  # shellcheck source=maintainer-comment-gate.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/maintainer-comment-gate.sh"
fi

BCR_RETRY_MARKER_NAME="dev-lead-bot-comment-retry"

# bcr_retry_decisions <comments_json> <trusted_bots_csv> <info_patterns_json> <now_epoch> <automation_logins_csv>
#   <comments_json>      the PR's issue-comment nodes, each {id, author{login,
#                        __typename}, authorAssociation, body, createdAt,
#                        lastEditedAt, isMinimized, minimizedReason}
#                        (bcr_fetch_pr_comments)
#   <trusted_bots_csv>   registered bots dev-lead acts on ("coderabbitai[bot],…";
#                        the [bot] suffix is optional)
#   <info_patterns_json> {bare_login: info_status_pattern} (may be "{}")
#   <now_epoch>          current time, unix seconds
#   <automation_logins_csv> the logins our own automation posts markers as
#                        ("don-petry,donpetry-bot"); required — empty fails closed
# Echoes a compact JSON array, oldest comment first, of
#   {id, login, version, attempt, decision: "dispatch"|"skip", reason}
# Returns non-zero (and echoes nothing) when the input cannot be evaluated, so a
# caller fails closed rather than dispatching on a misread.
bcr_retry_decisions() {
  local comments="${1:-}" trusted_csv="${2:-}" info_patterns="${3:-}" now_epoch="${4:-}"
  local automation_csv="${5:-}"
  [ -n "$info_patterns" ] || info_patterns='{}'
  [[ "$now_epoch" =~ ^[0-9]+$ ]] || return 1
  # Without our own logins no marker can be trusted, and an untrusted marker set
  # would read as "no retry yet" on every scan — fail closed instead.
  [[ "$automation_csv" =~ [A-Za-z0-9] ]] || return 1
  local min_age="${BOT_COMMENT_RETRY_MIN_AGE_SEC:-900}"
  local pending="${BOT_COMMENT_RETRY_PENDING_SEC:-9000}"
  local max_attempts="${BOT_COMMENT_RETRY_MAX_ATTEMPTS:-2}"
  local max_total="${BOT_COMMENT_RETRY_MAX_TOTAL:-6}"
  local skew="${BOT_COMMENT_RETRY_VERSION_SKEW_SEC:-2}"
  [[ "$min_age" =~ ^[0-9]+$ ]] || min_age=900
  [[ "$pending" =~ ^[0-9]+$ ]] || pending=9000
  [[ "$max_attempts" =~ ^[0-9]+$ ]] || max_attempts=2
  [[ "$max_total" =~ ^[0-9]+$ ]] || max_total=6
  [[ "$skew" =~ ^[0-9]+$ ]] || skew=2

  printf '%s' "$comments" | jq -ce \
    --arg markers "$_MAINTAINER_GATE_AGENT_MARKERS" \
    --arg trusted "$trusted_csv" \
    --arg automation "$automation_csv" \
    --arg retry_name "$BCR_RETRY_MARKER_NAME" \
    --arg sibling_name "dev-lead-bot-thread-retry" \
    --argjson info "$info_patterns" \
    --argjson now "$now_epoch" \
    --argjson min_age "$min_age" \
    --argjson pending "$pending" \
    --argjson max_attempts "$max_attempts" \
    --argjson max_total "$max_total" \
    --argjson skew "$skew" \
    --arg botuser "${BOT_USER:-donpetry-bot}" "$_MAINTAINER_GATE_DISP_JQ_DEFS"'
    def bare: if endswith("[bot]") then .[0:-5] else . end;
    def epoch: (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601);
    # A marker-supplied timestamp: its epoch, or null when absent/unparseable.
    def vepoch: if type == "string" then (try epoch catch null) else null end;
    # Attribute strings of every <!-- <name> ... --> marker in this comment body.
    def markers($name): [ (.body // "") | scan("<!--\\s*" + $name + "\\s+([^>]*?)\\s*-->") | .[0] ];
    def attr($k): [ scan("(?:^|\\s)" + $k + "=(\\S+)") | .[0] ] | first // null;

    if type != "array" then error("comments must be an array") else . end
    | . as $all
    | ($trusted | split(",") | map(gsub("^\\s+|\\s+$"; "") | bare) | map(select(length > 0))) as $tb
    # Logins compare without a `[bot]` suffix: GraphQL omits it where REST keeps it.
    | ($automation | split(",") | map(gsub("^\\s+|\\s+$"; "") | bare) | map(select(length > 0))) as $auto
    # Our own automation: one of our acting logins AND a trusted association — a
    # marker from anyone else (outside commenter or another member) never counts.
    | [ .[] | objects
        | select((.author?.login // "" | tostring | bare) as $l | ($auto | index($l)) != null)
        | select(((.authorAssociation // "") as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a)) != null)
        | (markers("dev-lead-fix-reviews") | map(select(attr("intent") == "fix-bot-comment"))) as $fr
        | {t: (.createdAt | epoch),
           disp: markers("dev-lead:comment-disposition"),
           pass: ($fr | map(select(attr("comment") != null))),
           hold: ($fr | map(select(attr("status") == "rate-limited" or attr("status") == "blocked"))
                      | map(attr("reset") | vepoch)),
           retry: markers($retry_name),
           sibling: (markers($sibling_name) | length)} ] as $notes
    # A fix-bot-comment pass that ended rate-limited/blocked names no comment, so it
    # holds every comment on the PR: until its reset= time, and it ends the count
    # of attempts that ran into it.
    | ([ $notes[] | select((.hold | length) > 0) | .t ] | max) as $last_hold
    | ([ $notes[] | .hold[] | select(. != null) ] | max) as $hold_until
    # A pending bot-thread retry holds the per-PR lane: a second dispatch would
    # supersede it.
    | ([ $notes[] | select(.sibling > 0) | .t ] | max) as $sibling_retry
    | [ .[] | objects
        | (.author?.login // "" | tostring | bare) as $l
        | select($l != "" and ($tb | index($l)) != null)
        | select((.author?.__typename // "") == "Bot")
        | select(((.body // "") | test($markers)) | not)
        | select(($info[$l] // null) as $p | ($p == null) or (((.body // "") | test($p)) | not))
        # A RESOLVED comment is done, unless it was edited after its newest
        # covering disposition (or has none): the gate re-blocks exactly that
        # (#2008), so it needs a fresh pass like an undispositioned one (#2166).
        | select((((.isMinimized // false) == true
                   and ((.minimizedReason // "") | ascii_downcase) == "resolved") | not)
                 or (edit_state as $e
                     | ($e != "never" and $e != "unreadable")
                       and (latest_cover($all; (.id // "" | tostring)) as $cov
                            | $cov == null or $e > $cov.createdAt)))
        | .id as $id
        | (.lastEditedAt // .createdAt) as $ver
        | ($ver | epoch) as $vt
        | ([ $notes[] | select(.t >= $vt) | .disp[] | select(attr("id") == $id) ] | length > 0) as $covered
        | (.createdAt | vepoch) as $ct
        # A pass covers the version it PROCESSED (its version= stamp), so an edit
        # made while it ran stays open. A legacy marker without the stamp falls
        # back to "posted at/after this version". The skew absorbs only an
        # edited-event stamp lag; a creation stamp must match exactly.
        | ([ $notes[] | .t as $t | .pass[] | select(attr("comment") == $id)
             | (attr("version") | vepoch) as $pv
             | select(if $pv == null then $t >= $vt
                      elif $pv == $ct then $pv >= $vt
                      else ($pv + $skew) >= $vt end) ] | length > 0) as $ran
        # Retry markers match this version by VALUE (epoch), not by string, so a
        # timestamp format difference between fetches cannot hide a pending retry.
        | [ $notes[] | .t as $t | .retry[]
            | select(attr("id") == $id and (attr("version") | vepoch) == $vt)
            | {t: $t, attempt: ((attr("attempt") // "0") | tonumber? // 0)} ] as $retries
        | ([ $retries[].attempt ] + [ ($retries | length) ] | max) as $attempts
        | ([ $retries[] | select($last_hold == null or .t > $last_hold) ] | length) as $counted
        | ([ $retries[].t ] | max) as $last_retry
        | {id: $id, login: $l, version: $ver, created: .createdAt, attempt: ($attempts + 1)}
        + ( if $covered then {decision: "skip", reason: "dispositioned"}
            elif $ran then {decision: "skip", reason: "pass-completed"}
            elif ($last_retry != null and ($now - $last_retry) < $pending)
              then {decision: "skip", reason: "retry-pending"}
            elif ($sibling_retry != null and ($now - $sibling_retry) < $pending)
              then {decision: "skip", reason: "retry-pending"}
            elif ($hold_until != null and $hold_until > $now) then {decision: "skip", reason: "rate-limited"}
            elif ($counted >= $max_attempts or $attempts >= $max_total)
              then {decision: "skip", reason: "retry-attempts-exhausted"}
            elif ($now - $vt) < $min_age then {decision: "skip", reason: "grace-period"}
            else {decision: "dispatch", reason: "undispositioned"}
            end )
      ]
    | sort_by(.created) | map(del(.created))
  ' 2>/dev/null
}

# bcr_fetch_pr_comments <repo> <pr_number>
#   Echo every PR issue-comment node (paginated GraphQL) as one JSON array with
#   the fields bcr_retry_decisions reads. Returns 1 (echoing nothing on stdout, one
#   `[warn]` line naming the failure on stderr) on any API or parse failure — a
#   partial list could hide a disposition, so callers fail closed.
#   Pages are merged from a temp file, never passed to jq as arguments: a PR's
#   accumulated comment JSON outgrows the exec argument limit (#2072, PR #1953).
bcr_fetch_pr_comments() {
  local pages_file rc
  pages_file=$(mktemp "${TMPDIR:-/tmp}/bcr-comments.XXXXXX") || {
    echo "  [warn] bot-comment retry: could not create a temp file for PR $2 comments" >&2
    return 1
  }
  # A subshell with its own EXIT trap removes the temp file (it holds fetched
  # comment bodies) even on interruption, without touching the caller's traps;
  # `|| rc=$?` keeps errexit from skipping the status capture.
  rc=0
  (
    trap 'rm -f "$pages_file"' EXIT
    _bcr_fetch_pr_comments_into "$1" "$2" "$pages_file"
  ) || rc=$?
  rm -f "$pages_file"
  return "$rc"
}

# _bcr_fetch_pr_comments_into <repo> <pr_number> <pages_file>
#   bcr_fetch_pr_comments' body: appends each page's nodes array to <pages_file>
#   (one per line) and echoes their concatenation once every page has been read.
_bcr_fetch_pr_comments_into() {
  local repo="$1" pr="$2" pages_file="$3"
  local warn="  [warn] bot-comment retry: PR ${pr} comments in ${repo}:"
  # shellcheck disable=SC2016  # $owner/$repo/$pr/$cursor are GraphQL variables
  local query='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        comments(first:100,after:$cursor){
          pageInfo{hasNextPage endCursor}
          nodes{ id author{login __typename} authorAssociation body createdAt lastEditedAt isMinimized minimizedReason }
        }
      }
    }
  }'
  local cursor="" prev_cursor="" has_next="true" page
  local cursor_args=()
  while [ "$has_next" = "true" ]; do
    page=$(gh api graphql -f query="$query" -F owner="${repo%%/*}" -F repo="${repo##*/}" \
      -F pr="$pr" "${cursor_args[@]}" 2>/dev/null) || {
      echo "${warn} API request failed" >&2; return 1; }
    # A partial response (GraphQL errors alongside data) or an unreadable page
    # cursor is a partial snapshot — it could hide a disposition. Fail closed.
    printf '%s' "$page" | jq -e 'type == "object"' >/dev/null 2>&1 || {
      echo "${warn} unparseable API response" >&2; return 1; }
    printf '%s' "$page" | jq -e '(.errors // []) | length == 0' >/dev/null 2>&1 || {
      echo "${warn} response carried GraphQL errors" >&2; return 1; }
    printf '%s' "$page" | jq -ce '.data.repository.pullRequest.comments.nodes | arrays' \
      >> "$pages_file" 2>/dev/null || {
      echo "${warn} unparseable comment page (no nodes array)" >&2; return 1; }
    has_next=$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.comments.pageInfo.hasNextPage
      | if type == "boolean" then tostring else "invalid" end' 2>/dev/null) || has_next="invalid"
    cursor=$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.comments.pageInfo.endCursor // ""' 2>/dev/null) \
      || cursor=""
    case "$has_next" in true|false) ;; *)
      echo "${warn} invalid pagination info (hasNextPage)" >&2; return 1 ;;
    esac
    if [ "$has_next" = "true" ] && [ -z "$cursor" ]; then
      echo "${warn} invalid pagination info (no endCursor)" >&2; return 1
    fi
    # A cursor that did not advance would re-fetch the same page forever.
    if [ "$has_next" = "true" ] && [ "$cursor" = "$prev_cursor" ]; then
      echo "${warn} invalid pagination info (endCursor did not advance)" >&2; return 1
    fi
    prev_cursor="$cursor"
    cursor_args=(-f "cursor=${cursor}")
  done
  # Concatenate the pages from the file — never via jq arguments (#2072).
  jq -cs 'add // []' "$pages_file" 2>/dev/null || {
    echo "${warn} could not merge comment pages" >&2; return 1; }
}

# bcr_retry_marker <comment_id> <version> <attempt> <now_iso>
#   The hidden dedup marker the sweep posts BEFORE dispatching. It carries the
#   `dev-lead` prefix, so the maintainer-comment gate never counts it as a finding.
bcr_retry_marker() {
  printf '<!-- %s id=%s version=%s attempt=%s at=%s -->' \
    "$BCR_RETRY_MARKER_NAME" "$1" "$2" "$3" "$4"
}
