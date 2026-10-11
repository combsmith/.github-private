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
#                              running; never duplicate it. A retry whose recorded
#                              run was cancelled before it started is LOST and does
#                              not hold (#2262, see RUN STATES below). A retry on
#                              this PR whose recorded run is known to be queued or
#                              running holds every comment: all retries share the
#                              per-PR lane, and a second dispatch would cancel a
#                              queued one
#     rate-limited             a fix-bot-comment pass on this PR ended rate-limited
#                              (or blocked) and its reset= time is still ahead
#     retry-attempts-exhausted this version already had MAX retry attempts since the
#                              last rate-limited end (an attempt that ended rate-
#                              limited does not count, nor does a LOST one), or
#                              MAX_TOTAL in all — rate-limited and lost included,
#                              so a lane that keeps cancelling is still bounded
#     grace-period             the comment is too new — the original event-driven
#                              run may still be pending or running
#     retry-cancelled-backoff  a retry on this PR was lost less than the backoff
#                              ago: the event that cancelled it has just taken the
#                              lane's pending slot, and dispatching now would
#                              cancel that run in turn
#     (dispatch)               otherwise, as attempt <previous attempts + 1>
#
# RUN STATES (#2262)
#   A dispatched retry joins the PR's concurrency lane, where GitHub keeps one
#   pending run: any newer PR event cancels it before a step runs. The sweep
#   records the run it dispatched on the marker (`run=<id>`) and, on later scans,
#   passes what the Actions API says about those runs as the optional
#   <run_states_json>: {"<run id>": {status, conclusion, started}} (bcr_run_state).
#     lost  status=completed, conclusion=cancelled, started=false (no job ran a
#           step). Not pending, and not one of MAX_ATTEMPTS.
#     live  any status other than completed (queued, pending, in_progress, …).
#   Everything else keeps the time-based behaviour: a marker with no `run=`, a run
#   that is absent from the map (the API could not be read), a run cancelled after
#   it started, a run that completed any other way. Unknown is never read as lost.
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
#                                   rate-limited and lost ones included (default 6)
#   BOT_COMMENT_RETRY_LOST_BACKOFF_SEC  how long after a lost retry's dispatch the
#                                   PR's next retry waits (default: the MIN_AGE
#                                   grace, for the same reason — the run that took
#                                   the lane may still be pending or running)
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
# The repository_dispatch the retry sends, and the caller stub that subscribes to
# it in every target repo. bcr_pick_dispatched_run pairs a dispatch with its run
# by these (a repository_dispatch run's title is its event type).
BCR_RETRY_EVENT_TYPE="dev-lead-reviews-retry"
BCR_RETRY_WORKFLOW_PATH=".github/workflows/dev-lead.yml"

# bcr_retry_decisions <comments_json> <trusted_bots_csv> <info_patterns_json> <now_epoch> <automation_logins_csv> [run_states_json]
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
#   <run_states_json>    optional {"<run id>": {status, conclusion, started}} for
#                        the runs recorded on retry markers (RUN STATES above).
#                        Omitted, empty or not a JSON object reads as "no run is
#                        known", which is the time-based behaviour.
# Echoes a compact JSON array, oldest comment first, of
#   {id, login, version, attempt, decision: "dispatch"|"skip", reason}
# Returns non-zero (and echoes nothing) when the input cannot be evaluated, so a
# caller fails closed rather than dispatching on a misread.
bcr_retry_decisions() {
  _bcr_evaluate decisions "$@"
}

# bcr_retry_run_ids <comments_json> <trusted_bots_csv> <info_patterns_json> <now_epoch> <automation_logins_csv>
#   PURE. Echoes a compact JSON array of the run ids (strings) whose state could
#   change a decision, so the sweep reads only those from the Actions API:
#     • every trusted retry marker on the PR still inside the pending window (its
#       run may be lost, or live and holding the lane) or inside the lost-retry
#       backoff when that is longer (a lost run there still holds the backoff),
#       and
#     • the markers of a comment version that is out of MAX_ATTEMPTS but under
#       MAX_TOTAL (a lost one gives an attempt back).
#   Same arguments and failure behaviour as bcr_retry_decisions.
bcr_retry_run_ids() {
  _bcr_evaluate run-ids "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}"
}

# _bcr_evaluate <decisions|run-ids> <bcr_retry_decisions arguments…>
#   The one evaluation both public functions read, so the run ids the sweep
#   fetches are exactly the ones the decision would use.
_bcr_evaluate() {
  local mode="$1"; shift
  local comments="${1:-}" trusted_csv="${2:-}" info_patterns="${3:-}" now_epoch="${4:-}"
  local automation_csv="${5:-}" run_states="${6:-}"
  [ -n "$info_patterns" ] || info_patterns='{}'
  # An unreadable run-state map is "no run is known" — never a reason to treat a
  # retry as lost.
  run_states=$(jq -ces 'select(length == 1) | .[0] | objects' <<< "$run_states" 2>/dev/null) \
    || run_states='{}'
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
  local lost_backoff="${BOT_COMMENT_RETRY_LOST_BACKOFF_SEC:-$min_age}"
  [[ "$lost_backoff" =~ ^[0-9]+$ ]] || lost_backoff="$min_age"

  printf '%s' "$comments" | jq -ce \
    --arg mode "$mode" \
    --argjson runs "$run_states" \
    --argjson lost_backoff "$lost_backoff" \
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
    # Every trusted retry marker on the PR, with what is known about the run it
    # recorded (#2262). `lost` and `live` are false unless the run state says so:
    # a marker without run=, or a run missing from $runs, is neither.
    | [ $notes[] | .t as $t | .retry[]
        | (attr("run") | if type == "string" and test("^[0-9]+$") then . else null end) as $rid
        | (if $rid == null then null else ($runs[$rid] // null) end) as $st
        | {t: $t, id: attr("id"), v: (attr("version") | vepoch),
           attempt: ((attr("attempt") // "0") | tonumber? // 0), run: $rid,
           lost: (($st | type) == "object" and $st.status == "completed"
                  and $st.conclusion == "cancelled" and $st.started == false),
           live: (($st | type) == "object" and ($st.status | type) == "string"
                  and $st.status != "completed")} ] as $all_retries
    # A retry whose run is known to be queued or running holds the whole PR: the
    # lane keeps one pending run, so another dispatch would cancel a queued one.
    | ([ $all_retries[] | select(.live) | .t ] | max) as $live_retry
    | ([ $all_retries[] | select(.lost) | .t ] | max) as $lost_retry
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
        | [ $all_retries[] | select(.id == $id and .v == $vt) ] as $retries
        # Every marker counts here, lost ones too: the attempt number stays
        # monotonic (the claim is scoped to it) and MAX_TOTAL bounds a lane that
        # keeps cancelling.
        | ([ $retries[].attempt ] + [ ($retries | length) ] | max) as $attempts
        # A lost retry did no work: it neither uses up one of MAX_ATTEMPTS nor
        # holds the comment as pending.
        | ([ $retries[] | select(.lost | not)
             | select($last_hold == null or .t > $last_hold) ] | length) as $counted
        | ([ $retries[] | select(.lost | not) | .t ] | max) as $last_retry
        | {id: $id, login: $l, version: $ver, created: .createdAt, attempt: ($attempts + 1),
           # Runs worth reading for this comment (bcr_retry_run_ids): only when a
           # lost one could give an attempt back.
           runs: (if (($covered or $ran) | not)
                     and $counted >= $max_attempts and $attempts < $max_total
                  then [ $retries[].run | select(. != null) ] else [] end)}
        + ( if $covered then {decision: "skip", reason: "dispositioned"}
            elif $ran then {decision: "skip", reason: "pass-completed"}
            elif ($last_retry != null and ($now - $last_retry) < $pending)
              then {decision: "skip", reason: "retry-pending"}
            elif ($sibling_retry != null and ($now - $sibling_retry) < $pending)
              then {decision: "skip", reason: "retry-pending"}
            elif ($live_retry != null and ($now - $live_retry) < $pending)
              then {decision: "skip", reason: "retry-pending"}
            elif ($hold_until != null and $hold_until > $now) then {decision: "skip", reason: "rate-limited"}
            elif ($counted >= $max_attempts or $attempts >= $max_total)
              then {decision: "skip", reason: "retry-attempts-exhausted"}
            elif ($now - $vt) < $min_age then {decision: "skip", reason: "grace-period"}
            elif ($lost_retry != null and ($now - $lost_retry) < $lost_backoff)
              then {decision: "skip", reason: "retry-cancelled-backoff"}
            else {decision: "dispatch", reason: "undispositioned"}
            end )
      ]
    | sort_by(.created)
    | if $mode == "run-ids"
      # The longer of the two windows a run state is read in: a live run holds
      # for $pending, and a lost one starts a backoff of $lost_backoff.
      then ([ $all_retries[]
              | select(.run != null and ($now - .t) < ([$pending, $lost_backoff] | max)) | .run ]
            + [ .[].runs[] ] | unique)
      else map(del(.created, .runs))
      end
  ' 2>/dev/null
}

# bcr_run_state <run_id> <run_json> [jobs_json]
#   PURE. Reduce the Actions API's answers about one run to the state
#   bcr_retry_decisions reads: {status, conclusion, started}.
#     <run_json>   GET /repos/{repo}/actions/runs/{id}
#     <jobs_json>  GET /repos/{repo}/actions/runs/{id}/jobs — only needed for a
#                  cancelled run; pass "" when it was not (or could not be) read
#   `started` is false only when the job list is complete and no job ran a step
#   or ended any way but cancelled/skipped, true when one did, and null when the
#   job list is missing, unreadable or truncated. A step whose conclusion is
#   `skipped` did not run; any other listed step counts as run, a cancelled one
#   included, since it may have begun. Returns non-zero (echoing
#   nothing) unless <run_json> is the repository_dispatch run <run_id> — the
#   caller then leaves the run out of the map (unknown).
bcr_run_state() {
  local run_id="${1:-}" run="${2:-}" jobs="${3:-}"
  [[ "$run_id" =~ ^[0-9]+$ ]] || return 1
  jobs=$(jq -ces 'select(length == 1) | .[0] | objects' <<< "$jobs" 2>/dev/null) || jobs='null'
  printf '%s' "$run" | jq -ce --arg id "$run_id" --argjson jobs "$jobs" '
    select(type == "object" and (.id | tostring) == $id
           and .event == "repository_dispatch" and (.status | type) == "string")
    | {status, conclusion: (.conclusion // null),
       started: (if ($jobs | type) == "object" and ($jobs.jobs | type) == "array"
                    and ($jobs.total_count | type) == "number"
                    and $jobs.total_count == ($jobs.jobs | length)
                 then any($jobs.jobs[];
                          ((.steps // [])
                           | if type == "array"
                             then any(.[]; if type == "object"
                                           then (.conclusion // "") != "skipped"
                                           else true end)
                             else true end)
                          or ((.conclusion // "cancelled") as $c
                              | ["cancelled", "skipped"] | index($c) == null))
                 else null end)}
  ' 2>/dev/null
}

# bcr_pick_dispatched_run <runs_listing_json> <since_iso>
#   PURE. From GET /repos/{repo}/actions/runs (event=repository_dispatch), count
#   the runs a retry dispatch sent at/after <since_iso> could have created: the
#   dev-lead caller stub's, titled with the retry's event type. Echoes
#   {count, id} — id is the run id (a string) only when count is exactly 1, since
#   a run that has not started exposes no payload to tell two candidates apart.
#   Returns non-zero (echoing nothing) when the listing is unreadable or truncated.
bcr_pick_dispatched_run() {
  local listing="${1:-}" since="${2:-}"
  printf '%s' "$listing" | jq -ce --arg since "$since" \
    --arg title "$BCR_RETRY_EVENT_TYPE" --arg path "$BCR_RETRY_WORKFLOW_PATH" '
    def epoch: (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601);
    ($since | epoch) as $s
    | select(type == "object" and (.workflow_runs | type) == "array"
             and (.total_count | type) == "number"
             and .total_count <= (.workflow_runs | length))
    | [ .workflow_runs[] | objects
        | select(.event == "repository_dispatch" and .display_title == $title and .path == $path)
        | select((.id | type) == "number" and (.created_at | type) == "string")
        | select((.created_at | epoch) >= $s) | .id ] as $ids
    | {count: ($ids | length), id: (if ($ids | length) == 1 then ($ids[0] | tostring) else null end)}
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

# bcr_retry_marker <comment_id> <version> <attempt> <now_iso> [run_id]
#   The hidden dedup marker the sweep posts BEFORE dispatching. It carries the
#   `dev-lead` prefix, so the maintainer-comment gate never counts it as a finding.
#   <run_id> is appended as a trailing `run=<id>` once the dispatched run is known
#   (#2262); every reader treats a marker without it as before.
bcr_retry_marker() {
  printf '<!-- %s id=%s version=%s attempt=%s at=%s%s -->' \
    "$BCR_RETRY_MARKER_NAME" "$1" "$2" "$3" "$4" "${5:+ run=$5}"
}
