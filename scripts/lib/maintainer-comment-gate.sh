#!/usr/bin/env bash
# Maintainer issue-comment gate (issues #1290, #1813)
#
# A maintainer finding posted as a PR *issue comment* — what `gh pr comment` and
# the GitHub main comment box produce — creates NO review thread. So unlike an
# inline review comment it:
#   1. does not trip `required_review_thread_resolution` → does not block merge, and
#   2. is never enumerated by dev-lead's fix-reviews prompt (it walks reviewThreads),
# and pr-review approves → the PR auto-merges with the defect intact. The same
# words, posted two ways, have opposite force; the easy path (`gh pr comment`) is
# the silent one.
#
# This gate closes the "does not block" half at the pr-review approval boundary.
#
# #1813 REDESIGN — "addressed" means a VERIFIED DISPOSITION, not a timestamp.
#   The original gate (#1290) judged a comment addressed by comparing timestamps:
#   a push at/after the comment cleared it. That was wrong twice over:
#     • it depended on the head-push timestamp, which GitHub now always returns
#       as null, so the gate failed closed on every open PR (the #1813 outage); and
#     • a push is only a proxy — it says nothing about whether a comment's finding
#       was read, checked, and acted on.
#   The redesign removes the push-timestamp model entirely. dev-lead
#   researches each undispositioned comment and posts exactly one evidence-backed
#   reply carrying `<!-- dev-lead:comment-disposition id=<id> disposition=<...> -->`;
#   the harness verifies that disposition and then minimizes the ORIGINAL comment
#   with classifier RESOLVED (GraphQL minimizeComment). This gate treats a
#   RESOLVED-minimized comment as addressed and withholds approval while ANY
#   non-agent issue comment lacks that signal.
#
#   Scope: EVERY PR issue comment, from human maintainers and bots alike
#   (codeant-ai, qodo-code-review, auto-rebase-conflict, and so on). No author is
#   exempt for being a bot — a conflict report is a finding, a trial-ended notice
#   has an operational consequence. The ONLY exclusion is our own automation's
#   disposition/ack/note replies (so the agent never has to answer itself): our
#   bot login, or a body carrying one of our automation markers (which includes
#   the `<!-- dev-lead:comment-disposition ... -->` reply itself).
#
# It FAILS CLOSED: an inability to evaluate the snapshot must block, and is
# reported DISTINCTLY (return 2 → a distinct verdict reason) so an undeterminable
# gate state can never recur disguised as a legitimate hold (#1813 AC8).
#
# check_maintainer_comments <pr_snapshot_json> [bot_user]
#   <pr_snapshot_json> — output of `gh pr view --json comments,...`; each comment
#                        must carry {author.login, body, isMinimized, minimizedReason}.
#   [bot_user]         — the agent's own login (default donpetry-bot)
# Returns:
#   0 = every non-agent issue comment is minimized RESOLVED (or none exist)
#   1 = at least one non-agent issue comment lacks a verified disposition → block
#   2 = the snapshot could not be evaluated (malformed) → fail closed → block
#
# The check is pure: it makes no `gh`/network calls and reuses the snapshot the
# caller already fetched, so it adds no API round-trip and is trivially testable.
# maintainer_gate_head_committer_date() is a thin `gh` helper retained for the
# sibling review-thread gate's push-time needs; it uses committer.date and reads
# NO push-timestamp field (#1813 AC1 / matching advisory-review-gate.sh, #577).

set -euo pipefail

# Regex (case-sensitive) matching the HTML markers our own automation stamps into
# comment bodies — pr-review reviews/acks (`<!-- pr-review-agent ... -->`,
# `<!-- persona:pr-review -->`), the pr-review re-review claim marker
# (`<!-- pr-review-claim ... -->`, issue #1589), dev-lead notes AND dev-lead
# comment-dispositions (`<!-- dev-lead ... -->` / `<!-- dev-lead:comment-disposition ... -->`),
# and the dependency-advisory pass (`<!-- dependency-advisory -->`). A comment
# carrying any of these is one of ours, never a finding we must disposition.
# This marker-based exclusion is essential because these workflows post as the
# human owner (`don-petry`) — the same account a human maintainer would use — so
# login alone cannot separate the agent's comments from a person's. It is also
# the loop-safety guard (#860 / #1813 AC7): our own disposition reply carries the
# `dev-lead` marker, so it is never itself counted as a comment needing a response.
# `maintainer-resolve` is the marker on the reply maintainer-resolve-comment.sh
# posts when it dispositions a registered reviewer bot's comment (#1918) — that
# reply must not itself become a fresh undispositioned blocker.
readonly _MAINTAINER_GATE_AGENT_MARKERS='<!-- (pr-review-agent|pr-review-claim|persona:|dev-lead|dependency-advisory|maintainer-resolve)[^>]*-->'

# This library's own directory, resolved ONCE at source time. dev-lead-fix-reviews.sh
# is run by a relative path (`bash .dev-lead/scripts/...`) and later cds into the
# PR worktree, so a function resolving BASH_SOURCE at call time gets a path that
# no longer exists and every registry read fails closed (#2208, as #2152).
_MAINTAINER_GATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
readonly _MAINTAINER_GATE_LIB_DIR

log_info() {
  echo "[maintainer-gate] $*" >&2
}

# _maintainer_gate_info_patterns_json
#   Echo a JSON object mapping each reviewer-source login to its known clean
#   *informational* status-comment pattern (#1918), read from the reviewer-source
#   registry (scripts/lib/reviewer-sources.tsv, column info_status_pattern). A
#   comment authored by such a login whose body matches the pattern is a clean
#   status report (e.g. SonarCloud's "Quality Gate passed") that carries no finding.
#   FAILS OPEN TO "{}" — an unreadable registry yields an empty map, so the gate
#   degrades to blocking EVERY undispositioned bot comment (fail closed on the gate
#   verdict: an info comment we can't classify simply stays a blocker), never to
#   clearing something it cannot classify.
_maintainer_gate_info_patterns_json() {
  local lib_dir="$_MAINTAINER_GATE_LIB_DIR" patterns status
  if [[ ! -f "$lib_dir/reviewer-sources.sh" ]]; then
    printf '%s' '{}'
    return 0
  fi
  # Source in a subshell so the registry helper's vars/functions never leak into
  # the gate's caller; capture only the login\tpattern lines. Assign the command
  # substitution and capture its status separately (with set -e disabled) rather
  # than in a `|| { … }` list, so a failure inside the subshell cannot be swallowed
  # by set -e in a conditional context.
  set +e
  patterns="$(
    # shellcheck source=reviewer-sources.sh
    source "$lib_dir/reviewer-sources.sh" 2>/dev/null \
      && reviewer_sources_info_status_patterns 2>/dev/null
  )"
  status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    printf '%s' '{}'
    return 0
  fi
  [[ -n "$patterns" ]] || { printf '%s' '{}'; return 0; }
  printf '%s\n' "$patterns" \
    | jq -R -s 'split("\n") | map(select(length > 0) | split("\t"))
                | map(select(length == 2) | {(.[0]): .[1]}) | add // {}' 2>/dev/null \
    || printf '%s' '{}'
}

# _maintainer_gate_registry_value <function>
#   Echo the output of a reviewer-sources.sh accessor, sourced in a subshell so the
#   registry helper never leaks into the gate's caller. Returns 1 (echoing nothing)
#   when the registry cannot be read. Each caller picks its own fail-closed default.
_maintainer_gate_registry_value() {
  local fn="${1:-}" lib_dir="$_MAINTAINER_GATE_LIB_DIR" out status
  [[ -n "$fn" && -f "$lib_dir/reviewer-sources.sh" ]] || return 1
  set +e
  out="$(
    # shellcheck source=reviewer-sources.sh
    source "$lib_dir/reviewer-sources.sh" 2>/dev/null && "$fn" 2>/dev/null
  )"
  status=$?
  set -e
  [[ $status -eq 0 && -n "$out" ]] || return 1
  printf '%s' "$out"
}

# _maintainer_gate_finding_re
#   The registry's finding-bearing-section regex (#2008). FAILS CLOSED to a regex
#   that matches EVERY body when the registry is unreadable. Then no
#   info_status_pattern can clear a comment, and no `informational` disposition can
#   cover one.
_maintainer_gate_finding_re() {
  _maintainer_gate_registry_value reviewer_sources_finding_section_pattern \
    || printf '%s' '[\s\S]'
}

# _maintainer_gate_registered_logins_json
#   JSON array of every registered reviewer-source login, or `null` when the
#   registry is unreadable. The edit re-open check (#2008) applies to registered
#   bots. Given `null`, it applies to EVERY RESOLVED comment (fail closed).
_maintainer_gate_registered_logins_json() {
  local logins
  if ! logins="$(_maintainer_gate_registry_value reviewer_sources_logins)"; then
    printf '%s' 'null'
    return 0
  fi
  printf '%s\n' "$logins" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null \
    || printf '%s' 'null'
}

# Shared jq definitions for the disposition-coverage check (#2008). They are used
# by the gate and by maintainer_gate_stale_dispositions (the dev-lead-retry.sh
# sweep), so both read "covered" the same way. The caller binds $botuser.
#   iso           — a well-formed ISO-8601 UTC timestamp (second precision).
#   trusted_reply — authored by our bot account or by a repo OWNER/MEMBER/
#                   COLLABORATOR, and explicitly NOT minimized. A missing
#                   isMinimized fails closed, and a superseded reply minimized
#                   OUTDATED stops counting. A marker from a drive-by account
#                   never covers an edit.
#   covers($cid)  — the {createdAt, kind} this reply asserts for comment $cid,
#                   or empty. kind is the dev-lead disposition word, or
#                   "maintainer-resolve" for the maintainer escape hatch's reply
#                   (which pins id=<node>). A reply carrying more than one
#                   dev-lead disposition marker is malformed and covers nothing,
#                   matching cdv_parse_disposition. latest_cover breaks a
#                   createdAt tie in favour of `informational`, so a reply that
#                   also carries a maintainer-resolve marker cannot mask it.
#   resolved_verdict($all; $findre) — for a comment minimized RESOLVED: "block"
#                   when it was edited and no covering disposition exists, when it
#                   was edited strictly after its latest one, or when that one is
#                   `informational` but the body is finding-bearing, or when it
#                   has no covering disposition at all and the body is
#                   finding-bearing; "unreadable"
#                   when its edit time cannot be read; else "clear".
#   edit_state    — the comment's last-edit time; "never" when the comment was
#                   never edited; "unreadable" when the edit time cannot be read.
#                   It reads lastEditedAt and nothing else. updatedAt is never a
#                   proxy, because it moves on non-edit mutations: minimizing the
#                   comment would make every disposition look stale. gh pr view's
#                   includesCreatedEdit=false proves "never edited" when
#                   lastEditedAt was not fetched.
readonly _MAINTAINER_GATE_DISP_JQ_DEFS='
  def iso: test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
  def bot_stripped: ($botuser | if endswith("[bot]") then .[0:-5] else . end);
  def trusted_reply:
    (.isMinimized == false)
    and ((.createdAt // "") | tostring | iso)
    and (
      ((.author?.login // "") as $l | $l == $botuser or $l == bot_stripped)
      or (((.authorAssociation // "") | tostring | ascii_upcase) as $a
          | ["OWNER", "MEMBER", "COLLABORATOR"] | index($a) != null)
    );
  def attr($k): (" " + .) | (capture("\\s" + $k + "=(?<v>[^\\s]+)") | .v) // "";
  def covers($cid):
    (.body // "" | tostring) as $b
    | .createdAt as $c
    | ([$b | scan("<!-- dev-lead:comment-disposition ([^>]*?) -->") | .[0]]) as $dl
    | ([$b | scan("<!-- maintainer-resolve ([^>]*?) -->") | .[0]]) as $mr
    | ( if ($dl | length) == 1 and ($dl[0] | attr("id")) == $cid
        then ($dl[0] | attr("disposition")) as $k
          | if (["fixed","answered","invalid","out-of-scope","informational"] | index($k)) != null
               and ($k != "fixed" or (($dl[0] | attr("sha")) | test("^[0-9a-f]{40}$")))
               and ($k != "out-of-scope" or (($dl[0] | attr("ref")) != ""))
            then {createdAt: $c, kind: $k} else empty end
        else empty end ),
      ( $mr[] | select(attr("id") == $cid) | {createdAt: $c, kind: "maintainer-resolve"} );
  def latest_cover($all; $cid):
    [ $all[] | objects | select(trusted_reply) | covers($cid) ]
    | sort_by([.createdAt, (if .kind == "informational" then 1 else 0 end)]) | last;
  def edit_state:
    if has("lastEditedAt") then
      (if .lastEditedAt == null then "never"
       elif (.lastEditedAt | tostring | iso) then .lastEditedAt
       else "unreadable" end)
    elif .includesCreatedEdit == false then "never"
    else "unreadable" end;
  def resolved_verdict($all; $findre):
    edit_state as $e
    | latest_cover($all; (.id // "" | tostring)) as $cov
    | if $e == "unreadable" then "unreadable"
      elif $e != "never" and ($cov == null or $e > $cov.createdAt) then "block"
      elif ($cov == null or $cov.kind == "informational")
           and ((.body // "") | tostring | test($findre)) then "block"
      else "clear" end;
'

log_warn() {
  echo "[maintainer-gate] WARNING: $*" >&2
}

# maintainer_gate_merge_edit_times <pr_url> <pr_snapshot_json>
#   Echo <pr_snapshot_json> with each comment's lastEditedAt merged in by node id
#   (#2008). `gh pr view --json comments` exposes no edit timestamp, only the
#   includesCreatedEdit boolean, so one paginated GraphQL read supplies it.
#   An edit-time lookup that fails, or a comment the lookup does not return, leaves
#   that comment WITHOUT a lastEditedAt key. The gate then fails closed (rc 2) for
#   any edited RESOLVED bot comment. The snapshot is never fabricated: on any
#   failure it is echoed unchanged.
maintainer_gate_merge_edit_times() {
  local pr_url="${1:-}" snapshot="${2:-}"
  [[ -n "$snapshot" ]] || return 0
  if [[ -z "$pr_url" ]]; then
    printf '%s' "$snapshot"
    return 0
  fi
  # shellcheck disable=SC2016  # $url/$cursor are GraphQL variables, not shell
  local _gql='query($url:URI!,$cursor:String){resource(url:$url){...on PullRequest{comments(first:100,after:$cursor){pageInfo{hasNextPage endCursor} nodes{id lastEditedAt}}}}}'
  local edits="[]" page nodes has_next="true" cursor="" pages=0
  local -a cursor_args=()
  while [[ "$has_next" == "true" ]]; do
    pages=$((pages + 1))
    # A runaway pagination loop is undeterminable: stop and keep the snapshot unchanged.
    if [[ $pages -gt 50 ]]; then
      printf '%s' "$snapshot"
      return 0
    fi
    page=$(gh api graphql -f query="$_gql" -f url="$pr_url" ${cursor_args[@]+"${cursor_args[@]}"} 2>/dev/null) || {
      log_warn "could not fetch comment edit times — edited comments will fail closed"
      printf '%s' "$snapshot"
      return 0
    }
    # Reject GraphQL errors and incomplete nodes: a missing lastEditedAt must stay
    # unknown (fail closed), never read as "never edited".
    nodes=$(printf '%s' "$page" | jq -ce '
      if ((.errors // []) | length) > 0 then error("GraphQL errors")
      elif ((.data.resource.comments.nodes // []) | type) != "array"
           or any(.data.resource.comments.nodes[]?;
                  (type != "object") or (has("id") | not) or (has("lastEditedAt") | not))
      then error("incomplete comment edit data")
      else .data.resource.comments.nodes // empty
      end
    ' 2>/dev/null) || nodes=""
    if [[ -z "$nodes" ]]; then
      log_warn "comment edit-time lookup returned no data — edited comments will fail closed"
      printf '%s' "$snapshot"
      return 0
    fi
    edits=$(jq -cn --argjson a "$edits" --argjson b "$nodes" '$a + $b' 2>/dev/null) || {
      printf '%s' "$snapshot"
      return 0
    }
    has_next=$(printf '%s' "$page" | jq -r '.data.resource.comments.pageInfo.hasNextPage // false' 2>/dev/null || echo false)
    cursor=$(printf '%s' "$page" | jq -r '.data.resource.comments.pageInfo.endCursor // ""' 2>/dev/null || echo "")
    [[ -n "$cursor" ]] || has_next="false"
    cursor_args=(-f "cursor=${cursor}")
  done
  printf '%s' "$snapshot" | jq -c --argjson edits "$edits" '
    ([ $edits[] | objects | select(.id != null) | {key: .id, value: .lastEditedAt} ] | from_entries) as $m
    | if (.comments | type) == "array" then
        .comments |= map(if (type == "object") and ((.id // null) | type) == "string"
                            and (.id as $id | $m | has($id))
                         then . + {lastEditedAt: $m[.id]} else . end)
      else . end
  ' 2>/dev/null || printf '%s' "$snapshot"
}

# maintainer_gate_reopen_candidates <comments_array_json> [bot_user]
#   The dev-lead harness's view of the #2008 re-open rule. <comments_array_json>
#   has the same node shape as maintainer_gate_stale_dispositions takes. Echoes a
#   JSON array of the node ids of every comment the gate would re-block after it
#   was minimized RESOLVED: authored by a Bot (or a registered reviewer login), and
#   either edited with no covering disposition, edited strictly after its latest one,
#   or covered only by `informational` while the body is finding-bearing. The
#   harness UNMINIMIZES these, so the comment is visibly open again and the next
#   pass dispositions the current body. A comment whose edit time is unreadable is
#   left alone here; the gate fails closed on it. Unreadable input echoes nothing
#   and returns 1.
maintainer_gate_reopen_candidates() {
  local comments="${1:-}" bot_user="${2:-donpetry-bot}" registered finding_re
  registered="$(_maintainer_gate_registered_logins_json)"
  finding_re="$(_maintainer_gate_finding_re)"
  printf '%s' "$comments" | jq -c \
    --arg botuser "$bot_user" \
    --arg findre "$finding_re" \
    --argjson registered "$registered" "$_MAINTAINER_GATE_DISP_JQ_DEFS"'
    . as $all
    | if type != "array" then error("not an array") else . end
    | [ .[] | objects
        | (.author?.login // "" | tostring | if endswith("[bot]") then .[0:-5] else . end) as $lbare
        | select(((.author?.__typename // "") == "Bot")
                 or ($registered != null and ($registered | index($lbare)) != null))
        | select(((.isMinimized // false) == true)
                 and (((.minimizedReason // "") | ascii_downcase) == "resolved"))
        | select((.id // "") != "")
        | select(resolved_verdict($all; $findre) == "block")
        | .id ]
  ' 2>/dev/null
}

# maintainer_gate_stale_dispositions <comments_array_json> [bot_user]
#   The dev-lead-retry.sh sweep's view of the #2008 re-open rule. <comments_array_json>
#   is an array of PR issue-comment nodes, each
#   {id, author{login,__typename}, authorAssociation, body, createdAt, isMinimized,
#   minimizedReason, lastEditedAt}.
#   Echoes a JSON array of {id, lastEditedAt} for every comment that is ALL of:
#   authored by a Bot (or a registered reviewer login); minimized RESOLVED or not
#   minimized (re-opened by the harness); covered by a dev-lead disposition; and
#   edited strictly after its latest covering disposition. Those are the comments
#   a fresh dev-lead pass must re-disposition.
#   Comments covered only by a maintainer-resolve reply are included too: an edit
#   after that reply re-blocks the gate, so a fresh pass must re-disposition them.
#   Unreadable input echoes nothing and returns 1, so a caller never dispatches on
#   a guess. Pure apart from reading the registry.
maintainer_gate_stale_dispositions() {
  local comments="${1:-}" bot_user="${2:-donpetry-bot}" registered
  registered="$(_maintainer_gate_registered_logins_json)"
  printf '%s' "$comments" | jq -c \
    --arg botuser "$bot_user" \
    --argjson registered "$registered" "$_MAINTAINER_GATE_DISP_JQ_DEFS"'
    . as $all
    | if type != "array" then error("not an array") else . end
    | [ .[] | objects
        | (.author?.login // "" | tostring | if endswith("[bot]") then .[0:-5] else . end) as $lbare
        | select(((.author?.__typename // "") == "Bot")
                 or ($registered != null and ($registered | index($lbare)) != null))
        # RESOLVED (cleared but stale), or not minimized at all (already re-opened
        # by the harness and still awaiting a fresh disposition). A comment
        # minimized for any other reason (OUTDATED, …) is not ours to chase.
        | select(((.isMinimized // false) == false)
                 or (((.minimizedReason // "") | ascii_downcase) == "resolved"))
        | edit_state as $e
        | select($e != "never" and $e != "unreadable")
        | (.id // "") as $cid
        | select($cid != "")
        | latest_cover($all; $cid) as $cov
        | select($cov != null)
        | select($e > $cov.createdAt)
        | {id: $cid, lastEditedAt: $e} ]
  ' 2>/dev/null
}

# maintainer_gate_head_committer_date <pr_url>
#   Echo the committer.date of the PR's head commit via a single GraphQL query.
#   Uses committer.date (not the deprecated, now-null push timestamp) so a cherry-pick
#   or rebase reflects when it was applied rather than the original author date —
#   the same cherry-pick-safe semantics advisory-review-gate.sh uses (#577). This
#   gate no longer decides "addressed" from push time; the helper is retained only
#   for the sibling review-thread gate, which sources this file for it. Echoes
#   empty on any API failure.
maintainer_gate_head_committer_date() {
  local pr_url="${1:-}"
  [[ -z "$pr_url" ]] && return 0
  # shellcheck disable=SC2016  # $url is a GraphQL variable placeholder, not shell
  local _gql='query($url:URI!){resource(url:$url){...on PullRequest{commits(last:1){nodes{commit{committer{date}}}}}}}'
  gh api graphql -f query="$_gql" -f url="$pr_url" \
    --jq '.data.resource.commits.nodes[0].commit.committer.date // empty' 2>/dev/null || true
}

# check_maintainer_comments <pr_snapshot_json> [bot_user]
check_maintainer_comments() {
  local json="${1:-}"
  local bot_user="${2:-donpetry-bot}"

  # Count non-agent issue comments that are NOT yet resolved. A comment is
  # "cleared" when it is authored by our own account, carries one of our
  # automation markers (our disposition/ack/note replies), OR has been minimized
  # with classifier RESOLVED (the harness's verified-disposition signal). Anything
  # else — a bot or human comment without a verified disposition — blocks.
  # A jq failure (malformed snapshot, or a value that can't be indexed with
  # .comments) exits non-zero → return 2 so undeterminable input fails closed
  # rather than silently reading as "no findings".
  # Data-driven info-status classifier (#1918): {login: pattern} of KNOWN CLEAN
  # informational status comments (e.g. sonarqubecloud → "Quality Gate passed"),
  # read from the reviewer-source registry. A comment authored by a listed login
  # whose body matches its pattern carries no finding and is treated as addressed.
  # An unreadable registry yields "{}" → no comment is auto-cleared (fail closed).
  local info_patterns
  info_patterns="$(_maintainer_gate_info_patterns_json)"
  # #2008: the finding-bearing-section regex (fails closed to "every body has
  # findings") and the registered reviewer logins (fails closed to `null`, meaning
  # the edit re-open check applies to every RESOLVED comment).
  local finding_re registered
  finding_re="$(_maintainer_gate_finding_re)"
  registered="$(_maintainer_gate_registered_logins_json)"

  # Per non-agent comment, classify: "clear" | "block" | "unreadable".
  #   • A KNOWN CLEAN info-status comment (registered login + its pattern) is clear,
  #     unless its body carries a finding-bearing section (#2008). A rate-limit or
  #     status notice never clears the findings beside it.
  #   • A comment not minimized RESOLVED blocks.
  #   • A RESOLVED comment by a registered reviewer bot (#2008) is re-checked
  #     against its LATEST covering disposition (see _MAINTAINER_GATE_DISP_JQ_DEFS):
  #       – edit time unreadable → unreadable (fail closed, rc 2);
  #       – edited, and no covering disposition or edited strictly after it → block.
  #         The bot changed the body after it was judged, so a fresh disposition
  #         must cover the current body;
  #       – covered by `informational` while the body is finding-bearing → block.
  #         Dispositioning only a notice never clears findings;
  #       – otherwise clear.
  #   • Any other RESOLVED comment is clear (the #1813 verified-disposition signal).
  local verdict
  verdict=$(printf '%s' "$json" | jq -c \
    --arg markers "$_MAINTAINER_GATE_AGENT_MARKERS" \
    --arg botuser "$bot_user" \
    --arg findre "$finding_re" \
    --argjson registered "$registered" \
    --argjson infopatterns "$info_patterns" "$_MAINTAINER_GATE_DISP_JQ_DEFS"'
      (.comments // []) as $all
      | [ $all[] | objects
        | (.author?.login // "" | tostring) as $l
        | ($l | if endswith("[bot]") then .[0:-5] else . end) as $lbare
        | select($l != $botuser and $l != bot_stripped)
        | select(((.body // "") | test($markers)) | not)
        | ((.body // "") | tostring | test($findre)) as $findings
        # Drop KNOWN CLEAN info-status comments: author is a registered source, its
        # body matches that source pattern, and it carries no finding-bearing
        # section. Anything else (a failing status, an unrecognised body, a bot
        # with no pattern, a human) is still evaluated.
        | select(
            ($infopatterns[$lbare] // null) as $p
            | ($p == null) or $findings or (((.body // "") | test($p)) | not)
          )
        | if ((.isMinimized // false) == true)
             and (((.minimizedReason // "") | ascii_downcase) == "resolved") | not
          then "block"
          elif ($registered != null and ($registered | index($lbare)) == null) then "clear"
          else resolved_verdict($all; $findre)
          end
      ]
      | {blockers: (map(select(. == "block")) | length),
         unreadable: (map(select(. == "unreadable")) | length)}
    ' 2>/dev/null) || {
    log_warn "could not parse PR snapshot — failing closed (blocking approval)"
    return 2
  }

  local blockers unreadable
  blockers=$(printf '%s' "$verdict" | jq -r '.blockers // empty' 2>/dev/null || true)
  unreadable=$(printf '%s' "$verdict" | jq -r '.unreadable // empty' 2>/dev/null || true)

  if [[ -n "$unreadable" && "$unreadable" -gt 0 ]]; then
    log_warn "$unreadable RESOLVED reviewer-bot comment(s) have an unreadable edit time — cannot tell whether they changed after their disposition; failing closed (blocking approval) (#2008)"
    return 2
  fi

  # Empty output (jq produced nothing at all) is undeterminable → fail closed.
  if [[ -z "$blockers" ]]; then
    log_warn "PR snapshot produced no verdict — failing closed (blocking approval)"
    return 2
  fi

  if [[ "$blockers" -eq 0 ]]; then
    log_info "no undispositioned PR issue comments"
    return 0
  fi

  log_warn "$blockers PR issue comment(s) lack a verified disposition (not minimized RESOLVED) — withholding approval (#1813)"
  return 1
}

# Run standalone against a PR URL (only if executed, not sourced).
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  _pr_url="${1:-}"
  if [[ -z "$_pr_url" ]]; then
    echo "usage: maintainer-comment-gate.sh <pr-url>" >&2
    exit 2
  fi
  _snap=$(gh pr view "$_pr_url" --json comments,reviews,headRefOid 2>/dev/null) || {
    echo "[maintainer-gate] ERROR: gh pr view failed for $_pr_url" >&2
    exit 2
  }
  # #2008: merge each comment's lastEditedAt (gh pr view does not expose it).
  _snap=$(maintainer_gate_merge_edit_times "$_pr_url" "$_snap")
  check_maintainer_comments "$_snap" "${BOT_USER:-donpetry-bot}"
  exit $?
fi
