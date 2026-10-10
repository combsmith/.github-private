# shellcheck shell=bash
# scripts/lib/budget-breaker.sh — Reactive budget breaker, DECISION ONLY
# (#2221, slice 3a of #1565).
#
# The breaker is reactive: it pauses the fleet when the fleet itself observes
# that the model provider is refusing work, and resumes at the reset time those
# refusals report. It does not read the usage endpoint (the fleet's credential
# cannot, see #2029).
#
# This library DECIDES and READS. It never acts: nothing here sets, clears or
# writes anything, on GitHub or anywhere else. The workflow that acts on the
# decision is slice 3b (#2153). A static test holds this file to that.
#
# ----------------------------------------------------------------------------
# Public functions
#
#   bb_decide <observations_json> <paused> <pause_source> <pause_until> [<now_epoch>]
#     PURE (jq only: no network, no gh, no writes, no clock unless <now_epoch>
#     is omitted). Prints one JSON object:
#       {"action": "trip"|"hold"|"resume"|"none",
#        "until": "<ISO-8601 UTC>"|null, "reason": "<text>", "evidence_count": <n>}
#     <observations_json>  JSON array, one object per quota marker:
#                            {"repo": "owner/name", "item": <issue or PR number>,
#                             "created": "<ISO>", "reset": "<ISO>"|null|""}
#                          (extra keys, e.g. "kind", are ignored).
#     <paused>             the fleet pause switch's value. "true" in any letter
#                          case means paused: the workflows gate on a GitHub
#                          expression (`!= 'true'`), which ignores case, so a
#                          human's `TRUE` pauses the fleet and must be honored.
#     <pause_source>       who set the pause ("" = a human).
#     <pause_until>        when the breaker's own pause ends (ISO-8601 UTC).
#     <now_epoch>          epoch seconds; default bb_now.
#     Timestamps are strict `YYYY-MM-DDTHH:MM:SSZ`, the only form the marker
#     writers and the GitHub API produce.
#
#   bb_observations_from_comments <repo>          (stdin: JSON array of comments)
#     PURE. Turns issue-comment objects from the GitHub REST API
#     ({body, created_at, issue_url, author_association}) into the observation
#     array bb_decide takes. Returns 1 (prints nothing) on unreadable input.
#
#   bb_collect <org> [<org>...]
#     READ-ONLY network. Lists each organisation's repositories and prints the
#     observation array for the current window. It is these two, composed:
#       bb_list_repos <org>                 one "owner/name" per line (non-forks)
#       bb_collect_observations <repo>...   the observation array for those repos
#     A collector that could read nothing prints nothing and returns 1, so its
#     output fed to bb_decide can only yield "none", never "trip".
#
# ----------------------------------------------------------------------------
# Decision rules (the issue is the spec; this is a summary)
#
#   Fleet paused:
#     no source, or a source that is not the breaker's -> none. Always. A human
#       pause is never tripped over and never resumed.
#     the breaker's own source, <pause_until> in the future -> hold.
#     the breaker's own source, <pause_until> passed        -> resume.
#     the breaker's own source, <pause_until> missing or unparseable -> resume
#       (fail open: bad data never keeps the fleet paused).
#     The observations are not consulted while paused (evidence_count is 0).
#   Fleet not paused:
#     trip when at least BUDGET_BREAKER_MIN_ITEMS distinct ITEMS (repo + number;
#       one item retried many times counts once) carry a quota marker created
#       within the last BUDGET_BREAKER_WINDOW_MIN minutes whose reset is in the
#       future or absent. `until` is the latest future reset among them, or,
#       when none carries one, now + BUDGET_BREAKER_PROBE_HOURS: the fleet
#       resumes, and if the cap still applies the next refusals trip it again.
#     otherwise none.
#   An unparseable time -> none. On the trip path, an unparseable setting,
#   observation array, or single observation in it -> none. Never trip on a guess.
#
# Settings (environment):
#   BUDGET_BREAKER_MIN_ITEMS      distinct items needed to trip        (default 3)
#   BUDGET_BREAKER_WINDOW_MIN     evidence window, minutes             (default 30)
#   BUDGET_BREAKER_PROBE_HOURS    pause length when no reset is known  (default 2)
#   BUDGET_BREAKER_MARKER_KINDS   marker kinds the collector reports, space
#                                 separated (default: the three dev-lead kinds)
#   BUDGET_BREAKER_NOW            epoch seconds override (tests)
#
# ----------------------------------------------------------------------------
# What counts as a quota marker
#
# A comment whose FIRST line is one of the markers below, carrying
# `status=rate-limited`, posted by an owner, organisation member or
# collaborator of the repository:
#   dev-lead-fix-ci        dev-lead-fix-ci.sh        post_rate_limited
#   dev-lead-fix-reviews   dev-lead-fix-reviews.sh   post_reviews_rate_limited
#   dev-lead-issue         dev-lead-fix-issue.sh     handle_engine_failure
# Each means every engine in that run's chain refused it for quota.
#
# Never counted:
#   - `status=blocked` (a PR blocker, not quota), and the legacy
#     `status=rate-limited reason=blocked|resolve-failed` spelling of the same
#     hold that an older-pinned repo can still post (#1568).
#   - pr-review's `<!-- pr-review-agent rate-limited v1 ... -->` marker (kind
#     `pr-review-advisory`). It also says `status=rate-limited`, but
#     review-one-pr.sh posts it when an ADVISORY REVIEWER BOT is out of quota
#     (detect_advisory_rate_limit) and its reset is a fixed backoff, not a
#     provider reset. It is recognised and can be opted in through
#     BUDGET_BREAKER_MARKER_KINDS, but it is not evidence that the model
#     provider is refusing the fleet, so it is off by default.
#   - a marker quoted further down a comment.
#   - a marker posted by anyone else: repositories here are public, and three
#     drive-by comments must not be able to pause the fleet. These are reported
#     with a `::warning::`, never silently dropped, because GitHub reports an
#     author's association as the reading credential sees it (a private
#     organisation member reads as a plain contributor to an outside reader),
#     so a wrong credential must not look like a quiet fleet.
#
# Sourced (`# shellcheck source=scripts/lib/budget-breaker.sh`). At source time
# it only sources lib/rate-limit-markers.sh (definitions only).

# Marker prefixes + the reset capture, shared with scripts/dev-lead-retry.sh.
# Resolved at source time: a caller may run by a relative path and cd later (#2152).
# shellcheck source=scripts/lib/rate-limit-markers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)/rate-limit-markers.sh"

# The pause-source value that marks a pause as this breaker's own.
BUDGET_BREAKER_PAUSE_SOURCE="rate-limit-observed"

# Marker kinds that are quota evidence (see the header for why pr-review's is not).
BUDGET_BREAKER_MARKER_KINDS_DEFAULT="dev-lead-fix-ci dev-lead-fix-reviews dev-lead-issue"

# pr-review's advisory withhold marker. Owned by lib/advisory-review-gate.sh
# (maybe_post_rate_limited_marker); lib/pr-automation-budget.sh holds the same
# literal as PR_RATE_LIMITED_MARKER_PREFIX and its value is used when that
# library is already loaded. A test pins the two to each other.
_BB_ADVISORY_MARKER_PREFIX="${PR_RATE_LIMITED_MARKER_PREFIX:-<!-- pr-review-agent rate-limited v1 sha=}"

# Comment authors whose markers are believed (REST `author_association`).
_BB_TRUSTED_ASSOCIATIONS='["OWNER","MEMBER","COLLABORATOR"]'

bb_warn() { printf '::warning::budget-breaker: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# bb_now — epoch seconds, honoring $BUDGET_BREAKER_NOW (testability).
# ---------------------------------------------------------------------------
bb_now() {
  if [ -n "${BUDGET_BREAKER_NOW:-}" ]; then
    printf '%s' "$BUDGET_BREAKER_NOW"
    return 0
  fi
  date -u +%s
}

# The whole decision, as one jq program. Every input arrives as a string and is
# validated here, so a bad value becomes a named "none", not a jq error.
# shellcheck disable=SC2016  # jq program: $names are jq variables, not shell
_BB_DECIDE_JQ='
  def iso:
    if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
    then (try fromdateiso8601 catch null) else null end;
  def posint:
    if type == "string" and test("^[0-9]{1,6}$")
    then (tonumber | if . > 0 then . else null end) else null end;
  def itemnum:
    if type == "number" and . >= 1 and . == floor then .
    elif type == "string" and test("^[1-9][0-9]{0,11}$") then tonumber
    else null end;
  def verdict($action; $until; $reason; $n):
    {action: $action, until: $until, reason: $reason, evidence_count: $n};
  def none($reason): verdict("none"; null; $reason; 0);

  (if ($now | test("^[0-9]{1,12}$")) then ($now | tonumber) else null end) as $t
  | if $t == null then
      none("the current time (\($now | tojson)) is not epoch seconds; failing open")
    elif ($paused | ascii_downcase) == "true" then
      if $source == "" then
        none("the fleet is paused with no source: a human pause is never tripped over and never resumed")
      elif $source != $own then
        none("the fleet is paused by another source (\($source | tojson)): not a pause this breaker set, so never tripped over and never resumed")
      else
        ($until | iso) as $u
        | if $u == null then
            verdict("resume"; null;
              "own pause, but its until (\($until | tojson)) is missing or unparseable; failing open so bad data never keeps the fleet paused"; 0)
          elif $u > $t then
            verdict("hold"; $until; "own pause holds until \($until)"; 0)
          else
            verdict("resume"; null; "own pause ended at \($until)"; 0)
          end
      end
    else
      ($min | posint) as $m | ($win | posint) as $w | ($probe | posint) as $p
      | if $m == null or $w == null or $p == null then
          none("a setting is not a positive integer (min_items=\($min | tojson) window_min=\($win | tojson) probe_hours=\($probe | tojson)); failing open")
        else
          (try ($obs | fromjson) catch null) as $o
          | if ($o | type) != "array" then
              none("the observations are not a JSON array; failing open")
            else
              [ $o[]
                | if type != "object" then null
                  else
                    (.created | iso) as $c
                    | (if .reset == null or .reset == "" then "absent" else (.reset | iso) end) as $r
                    | (.item | itemnum) as $i
                    | if (.repo | type) != "string" or .repo == "" or $i == null or $c == null or $r == null
                      then null
                      else {key: "\(.repo)#\($i)", created: $c,
                            reset: (if $r == "absent" then null else $r end)}
                      end
                  end
              ] as $rows
              | ($rows | map(. == null) | index(true)) as $bad
              | if $bad != null then
                  none("observation \($bad) is malformed (needs repo, item, created; reset optional; ISO-8601 UTC times); failing open")
                else
                  # Quota evidence: created in the window that ends now, and not
                  # already past its own reset.
                  [ $rows[] | select(.created >= ($t - $w * 60) and .created <= $t)
                            | select(.reset == null or .reset > $t) ] as $live
                  | ($live | map(.key) | unique | length) as $n
                  | if $n < $m then
                      verdict("none"; null;
                        "\($n) distinct item(s) with a live quota marker in the last \($w) min; \($m) needed"; $n)
                    else
                      ([ $live[] | .reset | select(. != null) ] | max) as $latest
                      | if $latest != null then
                          verdict("trip"; ($latest | todate);
                            "\($n) distinct items refused for quota in the last \($w) min; pausing until the latest reported reset"; $n)
                        else
                          verdict("trip"; (($t + $p * 3600) | todate);
                            "\($n) distinct items refused for quota in the last \($w) min, none with a parseable reset; pausing for the \($p) h probe interval"; $n)
                        end
                    end
                end
            end
        end
    end
'

# ---------------------------------------------------------------------------
# bb_decide <observations_json> <paused> <pause_source> <pause_until> [<now_epoch>]
# See the header. Always prints exactly one JSON object and returns 0; if the
# decision itself cannot be evaluated (jq missing or failing) that object is a
# "none".
# ---------------------------------------------------------------------------
bb_decide() {
  local observations="${1:-}" paused="${2:-}" pause_source="${3:-}" pause_until="${4:-}"
  local now="${5:-}" out
  [ -n "$now" ] || now="$(bb_now)"
  out=$(jq -cn \
    --arg obs "$observations" \
    --arg paused "$paused" --arg source "$pause_source" --arg until "$pause_until" \
    --arg now "$now" --arg own "$BUDGET_BREAKER_PAUSE_SOURCE" \
    --arg min "${BUDGET_BREAKER_MIN_ITEMS:-3}" \
    --arg win "${BUDGET_BREAKER_WINDOW_MIN:-30}" \
    --arg probe "${BUDGET_BREAKER_PROBE_HOURS:-2}" \
    "$_BB_DECIDE_JQ" 2>/dev/null) || out=""
  if [ -z "$out" ]; then
    bb_warn "the decision could not be evaluated (jq failed); failing open with action=none"
    out='{"action":"none","until":null,"reason":"the decision could not be evaluated (jq failed); failing open","evidence_count":0}'
  fi
  printf '%s\n' "$out"
}

# Comments -> observations. A marker must be the comment's first line: every
# writer puts it there, and it keeps a marker merely quoted in a discussion out.
# shellcheck disable=SC2016  # jq program: $names are jq variables, not shell
_BB_OBSERVE_JQ='
  if type != "array" then error("comments are not a JSON array") else . end
  | ($kinds | split(" ") | map(select(. != ""))) as $want
  | [ .[]
      | select(type == "object")
      | (((.body // "") | sub("^\\s+"; "") | split("\n")[0]) // "") as $line
      | select($line | test("-->\\s*$"))
      | (if   ($line | startswith($ci))       then "dev-lead-fix-ci"
         elif ($line | startswith($reviews))  then "dev-lead-fix-reviews"
         elif ($line | startswith($issue))    then "dev-lead-issue"
         elif ($line | startswith($advisory)) then "pr-review-advisory"
         else null end) as $kind
      | select($kind != null)
      | select($kind as $k | any($want[]; . == $k))
      # fix-ci ends with a free-text check name: keep it out of the field parse.
      | ($line | sub(" check=.*$"; " -->")) as $m
      | select($m | test(" status=rate-limited( |$)"))
      | select(($m | test(" reason=(blocked|resolve-failed)( |$)")) | not)
      | { trusted: ((.author_association // "") as $a | any($trusted[]; . == $a)),
          observation: {
            repo: $repo,
            item: (((.issue_url // "") | capture("/issues/(?<n>[0-9]+)$") | .n | tonumber) // null),
            created: (.created_at // null),
            reset: (($m | capture($resetre) | .r) // null),
            kind: $kind } }
    ] as $found
  | { observations: [ $found[] | select(.trusted) | .observation ],
      untrusted: ([ $found[] | select(.trusted | not) ] | length) }
'

# ---------------------------------------------------------------------------
# bb_observations_from_comments <repo>   (stdin: JSON array of comment objects)
# Prints the observation array. Returns 1 and prints nothing when the input is
# not a JSON array of comments (the caller must not read that as "no markers").
# An observation whose item or creation time could not be read is still
# emitted, with null in that field, so bb_decide refuses to decide on it
# instead of the marker quietly going missing.
# ---------------------------------------------------------------------------
bb_observations_from_comments() {
  local repo="${1:-}" result untrusted
  result=$(jq -c \
    --arg repo "$repo" \
    --arg ci "$CI_MARKER_PREFIX" --arg reviews "$REVIEWS_MARKER_PREFIX" \
    --arg issue "$ISSUE_MARKER_PREFIX" --arg advisory "$_BB_ADVISORY_MARKER_PREFIX" \
    --arg resetre "$RATE_LIMIT_RESET_CAPTURE_RE" \
    --arg kinds "${BUDGET_BREAKER_MARKER_KINDS:-$BUDGET_BREAKER_MARKER_KINDS_DEFAULT}" \
    --argjson trusted "$_BB_TRUSTED_ASSOCIATIONS" \
    "$_BB_OBSERVE_JQ" 2>/dev/null) || return 1
  [ -n "$result" ] || return 1
  untrusted=$(jq -r '.untrusted' <<< "$result")
  if [ "${untrusted:-0}" != "0" ]; then
    bb_warn "${repo}: ignored ${untrusted} quota marker(s) whose author is not an owner, member or collaborator as this credential sees it; they are not counted"
  fi
  jq -c '.observations' <<< "$result"
}

# ---------------------------------------------------------------------------
# bb_list_repos <org> — one "owner/name" per line, forks excluded (the same set
# dev-lead-retry.sh scans). Returns 1 with a warning when the list cannot be
# read or is empty: an empty list is far more likely a credential problem than
# an empty organisation.
# ---------------------------------------------------------------------------
bb_list_repos() {
  local org="${1:-}" out
  [ -n "$org" ] || { bb_warn "bb_list_repos: no organisation given"; return 1; }
  if ! out=$(gh repo list "$org" --limit 1000 --json nameWithOwner,isFork \
      --jq '.[] | select(.isFork == false) | .nameWithOwner' 2>/dev/null); then
    bb_warn "cannot list repositories for ${org}"
    return 1
  fi
  if [ -z "$out" ]; then
    bb_warn "no repositories listed for ${org}; check the credential can read the organisation"
    return 1
  fi
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# bb_collect_observations <repo>... — READ-ONLY. One listing call per repo:
# GitHub search cannot index HTML comments, so the markers are read from the
# repo-wide issue-comment listing (issues and pull requests alike), filtered
# server-side by `since=`. That filter is on a comment's last UPDATE, so an old
# comment edited recently can come back; bb_decide windows on creation time and
# drops it.
#
# Prints the observation array. A repo that cannot be read is a `::warning::`
# and is skipped: the breaker then sees less evidence, which can only make it
# trip later, never sooner. If no repo at all could be read, prints nothing and
# returns 1.
# ---------------------------------------------------------------------------
bb_collect_observations() {
  local now win since repo raw obs all='[]' read_ok=0
  now="$(bb_now)"
  win="${BUDGET_BREAKER_WINDOW_MIN:-30}"
  if ! [[ "$now" =~ ^[0-9]{1,12}$ && "$win" =~ ^[0-9]{1,6}$ ]] || [ "$((10#$win))" -le 0 ]; then
    bb_warn "cannot compute the evidence window (now='${now}' window_min='${win}'); collecting nothing"
    return 1
  fi
  since=$(jq -nr --argjson t "$(( 10#$now - 10#$win * 60 ))" '$t | todate') || return 1

  for repo in "$@"; do
    if ! raw=$(gh api --paginate \
        "repos/${repo}/issues/comments?since=${since}&per_page=100" \
        --jq '.[] | {body, created_at, issue_url, author_association}' 2>/dev/null); then
      bb_warn "cannot read issue comments for ${repo}; its quota markers are not counted"
      continue
    fi
    if ! obs=$(printf '%s' "$raw" | jq -s '.' 2>/dev/null | bb_observations_from_comments "$repo"); then
      bb_warn "cannot parse issue comments for ${repo}; its quota markers are not counted"
      continue
    fi
    read_ok=$(( read_ok + 1 ))
    all=$(jq -cn --argjson a "$all" --argjson b "$obs" '$a + $b') || return 1
  done

  if [ "$read_ok" -eq 0 ]; then
    bb_warn "no repository could be read; there is no evidence to decide on"
    return 1
  fi
  printf '%s\n' "$all"
}

# ---------------------------------------------------------------------------
# bb_collect <org> [<org>...] — READ-ONLY. The observation array for every
# non-fork repository of the given organisations, for the current window.
# An organisation that cannot be listed is a `::warning::` (from bb_list_repos)
# and is skipped; if none yields a repository, prints nothing and returns 1.
# ---------------------------------------------------------------------------
bb_collect() {
  local org listed repo repos=()
  for org in "$@"; do
    listed=$(bb_list_repos "$org") || continue
    while IFS= read -r repo; do
      [ -n "$repo" ] && repos+=("$repo")
    done <<< "$listed"
  done
  if [ "${#repos[@]}" -eq 0 ]; then
    bb_warn "no repositories to scan; there is no evidence to decide on"
    return 1
  fi
  bb_collect_observations "${repos[@]}"
}
