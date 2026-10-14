#!/usr/bin/env bash
# claim-landing.sh — "did the push land, and which claims must be retracted?" as
# pure verdicts (#2013).
#
# WHAT IS WRONG WITHOUT THIS
#   The fix-reviews / fix-bot-comment model posts its "Fixed in …" reply (with the
#   addressed-marker + #1692 claim) from its OWN shell, BEFORE the harness commits
#   and pushes. On petry-projects/.github#1220 that left false "Fixed" replies
#   standing when the push never landed, and when the claim named the PR's FIRST
#   commit (a stale pre-pass head). Separately, CodeRabbit marked a thread
#   "✅ Confirmed as addressed" on a reply describing `15a919e`, which WAS pushed:
#   a wrong fix (a new test added, an existing one broken without being edited)
#   cleared a review gate. Landing checks cannot catch that one; the
#   test-regression guard does.
#   The #1692 claim check ran only at thread-RESOLUTION time; nothing ever took a
#   posted claim back.
#
# THE CONTRACT
#   - cl_push_landed_verdict decides, from SHAs alone, whether the pass's pushed
#     commit is on the remote head. commit_and_push treats anything but `landed` as
#     a failed push.
#   - cl_select_pass_claims picks OUR claim/marker replies created during this pass.
#   - each selected claim is checked with acv_claim_in_pass against the REMOTE head
#     (addressed-claim-verify.sh); any that fails is rewritten with cl_retract_body,
#     which strips both markers so the reply can never authorize resolution again.
#     A claim whose commit the push guard rebased onto a foreign commit is first
#     re-pointed at its rebased successor (cl_map_sha + cl_rewrite_claim_sha, #2032).
#   - at the START of every pass, cl_select_earlier_claims picks OUR claim replies
#     from earlier passes (a cancelled run never reached its own sweep, #2032) and
#     cl_earlier_claim_verdict decides each: an unlanded one is retracted, and a
#     retracted one whose fix is on the remote head is restored (cl_restore_body).
#
# PURITY / TESTABILITY (ADR-0004)
#   Every cl_* function except cl_remote_head is PURE: no network, no git, no gh.
#   cl_remote_head is the single impure reader. Sourced under `set -euo pipefail`,
#   so helpers only `return`, never `exit`, and fail closed on every ambiguity.

set -euo pipefail

# acv_parse_claim is the single claim parser — reuse it, never a second one.
if ! declare -F acv_parse_claim >/dev/null 2>&1; then
  # shellcheck source=addressed-claim-verify.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/addressed-claim-verify.sh"
fi

# The retraction marker. Matches the shared `<!-- dev-lead… -->` agent-marker
# discriminator, so a retracted reply is still recognised as ours, but it is NOT the
# addressed-marker, so it can never authorize resolution.
readonly _CL_RETRACTED_PREFIX='<!-- dev-lead:retracted reason='
# A retracted reply keeps its original claim payload here (#2032) so a later pass
# can re-verify it. `retracted-claim` is not `<!-- dev-lead:claim `, so
# acv_parse_claim never reads it as a claim.
readonly _CL_RETRACTED_CLAIM_PREFIX='<!-- dev-lead:retracted-claim '
# The line cl_retract_body puts above the quoted original reply.
readonly _CL_UNADDRESSED_MARKER='<!-- dev-lead:retracted-unaddressed -->'
readonly _CL_ORIGINAL_HEADER='Original reply, kept for the record'

# cl_push_landed_verdict <start_head> <pushed_sha> <remote_head> <pushed_on_remote>
#   Echoes one token and returns 0 only for `landed`:
#     landed      <pushed_sha> advanced past <start_head> and is contained in the
#                 remote head (<pushed_on_remote> == "true"; the remote may have
#                 moved on past it).
#     unknown     any SHA is empty — fail closed.
#     no-advance  <pushed_sha> == <start_head>: nothing of this pass was pushed.
#     not-landed  the remote head does not contain <pushed_sha> (rejected /
#                 non-fast-forward / remote moved without our commit).
#   Pure — no gh/git/network.
cl_push_landed_verdict() {
  local start="${1:-}" pushed="${2:-}" remote="${3:-}" on_remote="${4:-}"
  if [[ -z "$start" || -z "$pushed" || -z "$remote" ]]; then
    echo "unknown"
    return 1
  fi
  if [[ "$pushed" == "$start" ]]; then
    echo "no-advance"
    return 1
  fi
  if [[ "$on_remote" != "true" ]]; then
    echo "not-landed"
    return 1
  fi
  echo "landed"
  return 0
}

# cl_select_pass_claims <comments_json> <bot_user> <since_iso>
#   <comments_json> is the REST `pulls/{pr}/comments` array ({id, user.login, body,
#   created_at}). Emits one `<id>\t<sha>` row per comment that (a) our account
#   authored (bot_user or its [bot]-suffixed / stripped form), (b) was created at or
#   after <since_iso> (the pass start), and (c) still carries the addressed-marker or
#   a claim comment. <sha> is the parsed claim SHA, or empty when the claim is
#   missing/malformed (unverifiable -> the caller retracts). An empty <since_iso> or
#   a non-array payload selects nothing: without a pass boundary the sweep must
#   never reach back and retract a previous pass's replies. Pure.
cl_select_pass_claims() {
  local comments_json="${1:-}" bot_user="${2:-}" since="${3:-}"
  [[ -z "$since" ]] && return 0
  local bot_stripped="${bot_user%\[bot\]}"

  local rows
  rows=$(jq -r \
    --arg u "$bot_user" --arg us "$bot_stripped" --arg since "$since" \
    --arg marker "$_DEV_LEAD_ADDRESSED_MARKER" --arg claim "$_ACV_CLAIM_PREFIX" '
      if type == "array" then
        .[] | objects
        | (.user.login // "") as $l
        | select($l == $u or $l == $us or $l == ($us + "[bot]"))
        | select((.created_at // "") >= $since)
        | select(((.body // "") | test($marker)) or ((.body // "") | contains($claim)))
        | [(.id | tostring), ((.body // "") | @base64)]
        | @tsv
      else empty end
    ' <<<"$comments_json" 2>/dev/null) || return 1
  [[ -z "$rows" ]] && return 0

  local id body_b64 body claim sha
  while IFS=$'\t' read -r id body_b64; do
    [[ -z "$id" ]] && continue
    body=$(base64 --decode <<<"$body_b64" 2>/dev/null || printf '')
    sha=""
    if claim=$(acv_parse_claim "$body"); then
      sha=$(jq -r '.sha // ""' <<<"$claim" 2>/dev/null || printf '')
    fi
    printf '%s\t%s\n' "$id" "$sha"
  done <<<"$rows"
}

# cl_install_reply_recorder <record_file> [real_gh]
#   Attribution by IDENTITY, not by time window (#2079 AC4). dev-lead posts as the SAME
#   account the maintainer uses, so "our login since the pass start" would also match a
#   comment the human posts mid-pass. Instead a `gh` shim is installed in a fresh
#   directory (echoed on stdout; the caller prepends it to the engine's PATH). The shim
#   forwards every call to the real gh unchanged and, for an
#   reply-creating call (the GraphQL reply mutation, any */replies* REST path,
#   in_reply_to, or a query/payload read from --input / @file), appends the posted reply's node id to
#   <record_file> (or the literal UNATTRIBUTED when the response carries no id, so the
#   caller can fail closed). The record file is created empty. Returns 1 on failure.
cl_install_reply_recorder() {
  local record="${1:-}" real="${2:-}"
  [[ -z "$record" ]] && return 1
  [[ -z "$real" ]] && { real=$(command -v gh 2>/dev/null) || real=""; }
  [[ -z "$real" ]] && return 1
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/dev-lead-recorder.XXXXXX") || return 1
  : > "$record" || return 1
  {
    printf '#!/usr/bin/env bash\n'
    printf 'real=%q\nrec=%q\n' "$real" "$record"
    cat <<'SHIM'
flag=0
tmpin=""
check() {
  case "$1" in
    *addPullRequestReviewThreadReply*|*/replies*|*in_reply_to*) flag=1 ;;
  esac
}
check "$*"
prev=""
for a in "$@"; do
  f=""
  [ "$prev" = "--input" ] && f=$a
  case "$a" in
    --input=*) f=${a#--input=} ;;
    *=@*) f=${a#*=@} ;;
    @*) f=${a#@} ;;
  esac
  if [ -n "$f" ]; then
    if [ "$f" = "-" ]; then
      if [ -z "$tmpin" ]; then
        tmpin=$(mktemp)
        cat > "$tmpin"
      fi
      check "$(cat "$tmpin")"
    elif [ -r "$f" ]; then
      check "$(cat "$f")"
    else
      flag=1
    fi
  fi
  prev=$a
done
run_real() {
  if [ -n "$tmpin" ]; then "$real" "$@" < "$tmpin"; else "$real" "$@"; fi
}
if [ "$flag" -eq 1 ]; then
  rc=0
  out=$(run_real "$@") || rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -eq 0 ]; then
    id=$(jq -r '(.data.addPullRequestReviewThreadReply.comment.id // .node_id // empty) | tostring' <<<"$out" 2>/dev/null || true)
    printf '%s\n' "${id:-UNATTRIBUTED}" >> "$rec"
  fi
  [ -n "$tmpin" ] && rm -f "$tmpin"
  exit "$rc"
fi
if [ -n "$tmpin" ]; then
  rc=0
  run_real "$@" || rc=$?
  rm -f "$tmpin"
  exit "$rc"
fi
exec "$real" "$@"
SHIM
  } > "$dir/gh"
  chmod +x "$dir/gh"
  printf '%s\n' "$dir"
}

# cl_recorded_reply_ids <record_file>
#   Emits the unique node ids the recorder captured, one per line. Returns 1 when the
#   record is missing or holds an UNATTRIBUTED entry (a reply whose id is unknown, so
#   nothing can be trusted: the no-change path must be disabled). Pure.
cl_recorded_reply_ids() {
  local record="${1:-}"
  [[ -n "$record" && -f "$record" ]] || return 1
  if grep -qx 'UNATTRIBUTED' "$record"; then
    return 1
  fi
  { grep -v '^[[:space:]]*$' "$record" || true; } | sort -u
  return 0
}

# cl_reply_stamp_body <body>
#   The stamped form of an unmarked pass reply: the original text followed by the
#   `<!-- dev-lead:reply -->` marker, which review_thread_is_agent_authored
#   recognises, so the reply can never again be read as a maintainer verdict. Pure.
cl_reply_stamp_body() {
  printf '%s\n\n<!-- dev-lead:reply -->\n' "${1:-}"
}

# cl_escape_dashes <text>
#   <text> with every `--` rewritten as `-\u002d` (a JSON escape), so a claim payload
#   can sit inside an HTML comment without closing it. Pure.
cl_escape_dashes() {
  local t="${1:-}"
  printf '%s' "${t//--/-\\u002d}"
}

# cl_retract_body <body> <reason>
#   The retracted form of a claim reply. Removes the addressed-marker and the claim
#   comment (so neither the thread gate nor another bot can treat it as a fix),
#   prefixes a plain-language retraction, keeps the original text as a quote for
#   the record, and appends `<!-- dev-lead:retracted reason=<reason> -->`. <reason>
#   is restricted to [a-z-] (anything else becomes `unknown`) so it can never break
#   out of the HTML comment. When the reply carried a valid claim, its payload is
#   kept in `<!-- dev-lead:retracted-claim {…} -->` so a later pass can re-verify
#   and restore it (#2032). Pure.
cl_retract_body() {
  local body="${1:-}" reason="${2:-unknown}"
  [[ "$reason" =~ ^[a-z][a-z-]*$ ]] || reason="unknown"

  # A payload containing `--` could close the HTML comment early, so each `--` is
  # stored with a JSON `\u002d` escape (cl_escape_dashes): the reply stays
  # restorable. Whether the original carried the addressed-marker is recorded too,
  # so a restore never grants a marker the reply never had.
  local claim="" claim_line="" unaddressed_line=""
  claim=$(acv_parse_claim "$body") || claim=""
  if [[ -n "$claim" ]]; then
    claim_line="${_CL_RETRACTED_CLAIM_PREFIX}$(cl_escape_dashes "$claim")${_ACV_CLAIM_SUFFIX}"$'\n'
  fi
  if ! [[ "$body" =~ $_DEV_LEAD_ADDRESSED_MARKER ]]; then
    unaddressed_line="${_CL_UNADDRESSED_MARKER}"$'\n'
  fi

  local stripped
  stripped=$(jq -Rsr --arg marker "$_DEV_LEAD_ADDRESSED_MARKER" '
      gsub($marker; "")
      | gsub("<!--[[:space:]]*dev-lead:claim[^\\n]*-->"; "")
      | sub("\\s+$"; "")
    ' <<<"$body" 2>/dev/null) || stripped=""
  local quoted
  quoted=$(printf '%s\n' "$stripped" | sed 's/^/> /')

  printf '%s\n\n%s\n\n%s\n\n%s%s%s%s -->\n' \
    "**⚠️ Retracted by the dev-lead harness (\`${reason}\`).** This reply's claim could not be verified as a fix produced and pushed by this pass (its commit was not produced by this pass, or the push did not land), so it no longer counts as addressed. The thread stays open; the next dev-lead pass re-verifies against the pushed diff." \
    "${_CL_ORIGINAL_HEADER} (unverified — it does not count as a fix):" \
    "$quoted" \
    "$claim_line" "$unaddressed_line" "$_CL_RETRACTED_PREFIX" "$reason"
}

# cl_restore_body <retracted_body> <claim_json>
#   The inverse of cl_retract_body (#2032): un-quotes the original reply kept under
#   the "Original reply…" header and re-appends the addressed-marker and the claim
#   <claim_json> (re-validated with acv_parse_claim). Used when a later pass finds
#   the retracted claim's commit on the remote head. Returns 1 (echoing nothing)
#   when the claim is invalid or the body is not a cl_retract_body retraction. Pure.
cl_restore_body() {
  local body="${1:-}" claim_json="${2:-}"
  local claim
  claim=$(acv_parse_claim "${_ACV_CLAIM_PREFIX}${claim_json}${_ACV_CLAIM_SUFFIX}") || return 1
  [[ "$body" == *"$_CL_ORIGINAL_HEADER"* ]] || return 1

  local original
  original=$(awk -v hdr="$_CL_ORIGINAL_HEADER" '
      index($0, hdr) == 1 { on = 1; next }
      on && /^<!-- dev-lead:retracted/ { exit }
      on { sub(/^> ?/, ""); print }
    ' <<<"$body" | sed -e '/./,$!d')

  # Only a reply that carried the addressed-marker gets it back.
  local marker_line="<!-- dev-lead:addressed -->"$'\n'
  if grep -qxF "$_CL_UNADDRESSED_MARKER" <<<"$body"; then
    marker_line=""
  fi
  printf '%s\n\n%s%s%s%s\n' \
    "$original" "$marker_line" "$_ACV_CLAIM_PREFIX" "$(cl_escape_dashes "$claim")" "$_ACV_CLAIM_SUFFIX"
}

# cl_rewrite_claim_sha <body> <new_sha>
#   <body> with its claim's SHA replaced by <new_sha> (a full 40-hex SHA); every
#   other byte, including the claim's files, is kept. Used when the push guard
#   rebased the claimed commit and the claim must name its successor (#2032).
#   Returns 1 (echoing nothing) when the body has no valid claim or <new_sha> is
#   not a full SHA. Pure.
cl_rewrite_claim_sha() {
  local body="${1:-}" new_sha="${2:-}"
  [[ "$new_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  local claim
  claim=$(acv_parse_claim "$body") || return 1
  claim=$(jq -c --arg s "$new_sha" '.sha = $s' <<<"$claim" 2>/dev/null) || return 1

  local before rest after
  before="${body%%"$_ACV_CLAIM_PREFIX"*}"
  rest="${body#*"$_ACV_CLAIM_PREFIX"}"
  after="${rest#*"$_ACV_CLAIM_SUFFIX"}"
  printf '%s%s%s%s%s\n' "$before" "$_ACV_CLAIM_PREFIX" "$claim" "$_ACV_CLAIM_SUFFIX" "$after"
}

# cl_map_sha <sha> <rewrites>
#   <rewrites> is newline-separated `<old>\t<new>` rows (_PUSH_GUARD_REWRITES from
#   git-push-guard.sh). Echoes <sha>'s rebased successor and returns 0, or returns 1
#   when <sha> was not rewritten. Follows chains (A->B then B->C yields C), since
#   the guard can rebase more than once in a run. Pure.
cl_map_sha() {
  local sha="${1:-}" rewrites="${2:-}"
  [[ -z "$sha" || -z "$rewrites" ]] && return 1
  local cur="$sha" new hops=0
  while ((hops < 32)); do
    new=$(awk -F'\t' -v s="$cur" '$1 == s && $2 != "" { print $2; exit }' <<<"$rewrites")
    [[ -n "$new" && "$new" != "$cur" ]] || break
    cur="$new"
    hops=$((hops + 1))
  done
  [[ "$cur" != "$sha" ]] || return 1
  echo "$cur"
}

# cl_select_earlier_claims <comments_json> <bot_user> <since_iso>
#   The start-of-pass counterpart of cl_select_pass_claims (#2032). A run that was
#   cancelled or killed after its model replied never reached its own sweep, so
#   each pass checks OUR replies created BEFORE <since_iso>. Emits one
#   `<id>\t<state>\t<claim_json>\t<finding_at>` row per reply that is either
#     claimed    still carries a `<!-- dev-lead:claim … -->` comment. <claim_json>
#                is the parsed claim, or empty when it is malformed (the caller
#                retracts it). Marker-only replies (pre-#1692) carry nothing to
#                verify and are not selected.
#     retracted  carries no addressed-marker and a valid retracted-claim payload
#                (cl_retract_body), so a later pass can restore it.
#   <finding_at> is the created_at of the comment the reply answers
#   (in_reply_to_id), or empty when that comment is not in the listing. An empty
#   <since_iso> or a non-array payload selects nothing. Pure.
cl_select_earlier_claims() {
  local comments_json="${1:-}" bot_user="${2:-}" since="${3:-}"
  [[ -z "$since" ]] && return 0
  local bot_stripped="${bot_user%\[bot\]}"

  local rows
  rows=$(jq -r \
    --arg u "$bot_user" --arg us "$bot_stripped" --arg since "$since" \
    --arg marker "$_DEV_LEAD_ADDRESSED_MARKER" --arg claim "$_ACV_CLAIM_PREFIX" \
    --arg rclaim "$_CL_RETRACTED_CLAIM_PREFIX" '
      if type == "array" then
        (map(objects | {key: (.id | tostring), value: (.created_at // "")}) | from_entries) as $at
        | .[] | objects
        | (.user.login // "") as $l
        | select($l == $u or $l == $us or $l == ($us + "[bot]"))
        | select((.created_at // "") < $since)
        | (.body // "") as $b
        | (if ($b | contains($claim)) then "claimed"
           elif ($b | contains($rclaim)) and (($b | test($marker)) | not) then "retracted"
           else empty end) as $state
        | [(.id | tostring), $state, ($b | @base64),
           (if .in_reply_to_id == null then "" else ($at[.in_reply_to_id | tostring] // "") end)]
        | join("\u001f")
      else empty end
    ' <<<"$comments_json" 2>/dev/null) || return 1
  [[ -z "$rows" ]] && return 0

  local id state body_b64 finding_at body claim rest
  while IFS=$'\x1f' read -r id state body_b64 finding_at; do
    [[ -z "$id" ]] && continue
    body=$(base64 --decode <<<"$body_b64" 2>/dev/null || printf '')
    if [[ "$state" == "retracted" ]]; then
      rest="${body#*"$_CL_RETRACTED_CLAIM_PREFIX"}"
      claim=$(acv_parse_claim "${_ACV_CLAIM_PREFIX}${rest%%"$_ACV_CLAIM_SUFFIX"*}${_ACV_CLAIM_SUFFIX}") || continue
    else
      claim=$(acv_parse_claim "$body") || claim=""
    fi
    printf '%s\x1f%s\x1f%s\x1f%s\n' "$id" "$state" "$claim" "$finding_at"
  done <<<"$rows"
}

# cl_earlier_claim_verdict <on_ref> <touches_files> <commit_date> <finding_at>
#   The verdict on a claim posted by an EARLIER pass (#2032). Its commit is expected
#   to predate this pass, so acv_claim_in_pass does not apply; instead the claim
#   must name a commit that is on the remote head (<on_ref>), touches the claimed
#   files (<touches_files>), and was committed no earlier than the comment it
#   answers (<commit_date> >= <finding_at>; both Z-form ISO-8601, compared as
#   strings). An empty <finding_at> skips the order rule; a finding date without a
#   commit date fails closed. <on_ref>/<touches_files> are the literal strings
#   "true"/"false". Echoes one token — kept | not-on-ref | no-file-intersection |
#   unverifiable | predates-finding — and returns 0 only for kept. Pure.
cl_earlier_claim_verdict() {
  local on_ref="${1:-}" touches="${2:-}" commit_date="${3:-}" finding_at="${4:-}"
  if [[ "$on_ref" != "true" ]]; then
    echo "not-on-ref"
    return 1
  fi
  if [[ "$touches" != "true" ]]; then
    echo "no-file-intersection"
    return 1
  fi
  if [[ -n "$finding_at" ]]; then
    if [[ -z "$commit_date" ]]; then
      echo "unverifiable"
      return 1
    fi
    if [[ "$commit_date" < "$finding_at" ]]; then
      echo "predates-finding"
      return 1
    fi
  fi
  echo "kept"
  return 0
}

# cl_remote_head
#   The single impure reader: fetch the current branch's upstream and echo the TRUE
#   remote head SHA (not a stale remote-tracking ref). Returns 1 (echoing nothing)
#   when the branch has no upstream, 2 when the fetch or lookup fails.
cl_remote_head() {
  local up remote branch
  up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  [[ -z "$up" ]] && return 1
  remote="${up%%/*}"
  branch="${up#*/}"
  git fetch --quiet "$remote" "$branch" 2>/dev/null || return 2
  local sha
  sha=$(git rev-parse --verify --quiet "refs/remotes/${remote}/${branch}" 2>/dev/null \
    || git rev-parse --verify --quiet FETCH_HEAD 2>/dev/null || true)
  [[ -z "$sha" ]] && return 2
  echo "$sha"
}
