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

# cl_retract_body <body> <reason>
#   The retracted form of a claim reply. Removes the addressed-marker and the claim
#   comment (so neither the thread gate nor another bot can treat it as a fix),
#   prefixes a plain-language retraction, keeps the original text as a quote for
#   the record, and appends `<!-- dev-lead:retracted reason=<reason> -->`. <reason>
#   is restricted to [a-z-] (anything else becomes `unknown`) so it can never break
#   out of the HTML comment. Pure.
cl_retract_body() {
  local body="${1:-}" reason="${2:-unknown}"
  [[ "$reason" =~ ^[a-z][a-z-]*$ ]] || reason="unknown"

  local stripped
  stripped=$(jq -Rsr --arg marker "$_DEV_LEAD_ADDRESSED_MARKER" '
      gsub($marker; "")
      | gsub("<!--[[:space:]]*dev-lead:claim[^\\n]*-->"; "")
      | sub("\\s+$"; "")
    ' <<<"$body" 2>/dev/null) || stripped=""
  local quoted
  quoted=$(printf '%s\n' "$stripped" | sed 's/^/> /')

  printf '%s\n\n%s\n\n%s\n\n%s%s -->\n' \
    "**⚠️ Retracted by the dev-lead harness (\`${reason}\`).** This reply's claim could not be verified as a fix produced and pushed by this pass (its commit was not produced by this pass, or the push did not land), so it no longer counts as addressed. The thread stays open; the next dev-lead pass re-verifies against the pushed diff." \
    "Original reply, kept for the record (unverified — it does not count as a fix):" \
    "$quoted" \
    "$_CL_RETRACTED_PREFIX" "$reason"
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
