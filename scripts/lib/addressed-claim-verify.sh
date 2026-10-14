#!/usr/bin/env bash
# addressed-claim-verify.sh — the pure verifier that turns the dev-lead
# addressed-marker into a *verifiable claim* against the pushed diff (#1692,
# epic #1621 story 2 of 2; blocked-by #1691).
#
# WHAT IS WRONG WITHOUT THIS
#   resolve_addressed_bot_threads() (dev-lead-fix-reviews.sh) resolved a bot thread
#   the moment its LAST reply carried `<!-- dev-lead:addressed -->` and was authored
#   by our account. It verified WHO claimed and THAT a claim was made — never
#   WHETHER the claim was true. On combsmith/.github PR #1044 three functions
#   were byte-identical between two commits, carried addressed-markers, and were
#   resolved exactly as designed. It also read `comments(last:1)` only, so an earlier
#   maintainer "ACCEPTED — required before merge" reply went invisible the moment the
#   model appended its own marker after it.
#
# THE CLAIM PAYLOAD SCHEMA (normative — the single source of truth)
#   The addressed reply carries TWO HTML comments. The existing marker is unchanged
#   (so review_reply_is_addressed_marker keeps working); the claim is ADDITIVE:
#
#     Fixed in scripts/lib/auto-merge.sh: added `set -euo pipefail` ...
#
#     <!-- dev-lead:addressed -->
#     <!-- dev-lead:claim {"v":1,"sha":"<40-hex>","files":["path/a","path/b"]} -->
#
#   Field contract:
#     v      integer. 1 today. An unrecognised v is unverifiable -> do not resolve
#            (fail closed), never "assume v1".
#     sha    full 40-character commit SHA. Abbreviated SHAs are rejected.
#     files  JSON array of repo-relative POSIX paths exactly as they appear in the
#            diff (no leading ./ or /, no quoting). Must be non-empty. Parsed with jq
#            (never IFS/cut/tr) so paths with spaces/commas/unicode are safe.
#
#   Extraction: exactly ONE claim comment per reply. Zero -> unverifiable (the
#   pre-migration case). More than one -> malformed. Do not "take the last one."
#
# PURITY / TESTABILITY
#   Every acv_* function except acv_gather_commit_facts is PURE: no network, no git,
#   no gh — inputs are the claim payload, diff file lists, and thread comments. That
#   is what makes the verifier exhaustively bats-testable offline. The single impure
#   gatherer (acv_gather_commit_facts) isolates all `git` calls, mirroring the
#   pure/impure split the repo uses elsewhere. Sourced under `set -euo pipefail`, so
#   the pure helpers only `return`, never `exit`, and fail closed on every ambiguity.

set -euo pipefail

# review_thread_is_agent_authored is the mandated human-vs-ours discriminator for the
# maintainer-disposition scan (AC4) — reuse it, do not invent a second classifier.
# Source the gate lib only if the caller has not already (the main script sources it
# first, so this never double-sources and never re-declares its readonly vars).
if ! declare -F review_thread_is_agent_authored >/dev/null 2>&1; then
  # shellcheck source=maintainer-review-thread-gate.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/maintainer-review-thread-gate.sh"
fi

# The literal delimiters of the claim comment. Kept as constants so the emitter
# (prompt) and this parser reference one definition.
readonly _ACV_CLAIM_PREFIX='<!-- dev-lead:claim '
readonly _ACV_CLAIM_SUFFIX=' -->'

# A maintainer "required disposition" (AC4). Matched case-insensitively against a
# marker-less human comment. Deliberately conservative: it recognises a standing
# "must land before merge" style assertion (the PR #1044 "ACCEPTED — required before
# merge" shape) rather than any human chatter, so a neutral "thanks" never blocks.
readonly _ACV_DISPOSITION_RE_UPPER='(REQUIRED|MUST BE (FIXED|ADDRESSED|RESOLVED|CHANGED)|CHANGES REQUIRED|BLOCKING|REQUEST(ING|ED)? CHANGES)'

# Post-marker BOT-comment classification (#1735 AC2/AC4). A review bot that replies
# AFTER our addressed-marker either ACKNOWLEDGES (accepts our refutation / records a
# custom rule — the codeant-ai "✅ Customized review instruction saved!" shape) or
# raises a NEW finding. An acknowledgement must not keep the thread open; a new
# finding must. Both regexes are matched case-insensitively (against the upper-cased
# body). They are deliberately NARROW and the finding signal is checked FIRST, so a
# comment that is neither a clear ack nor a clear finding — or that mixes ack phrasing
# with a new point — resolves toward "undeterminable" / "finding" (fail closed): a
# stuck thread is a nuisance, a wrongly-resolved one clears a merge gate.
readonly _ACV_BOT_ACK_RE_UPPER='(CUSTOMIZED REVIEW INSTRUCTION SAVED|REVIEW INSTRUCTION SAVED|INSTRUCTION (SAVED|RECORDED)|ACKNOWLEDG|WILL NOT (FLAG|REPORT|RAISE)|NO (FURTHER|MORE) (ACTION|CONCERNS?)|MARKING (THIS )?(AS )?RESOLVED|DISMISS(ED|ING)?)'
readonly _ACV_BOT_FINDING_RE_UPPER='(POTENTIAL ISSUE|REFACTOR SUGGESTION|SUGGESTION:|NEW (ISSUE|FINDING|PROBLEM|CONCERN)|SECURITY|VULNERABILIT|BUG|MUST (FIX|BE FIXED)|SHOULD (FIX|BE FIXED)|NITPICK|CRITICAL|BLOCKER|CHANGES REQUIRED)'
# A NEGATED acknowledgement ("cannot acknowledge this", "won't acknowledge", "unable to
# acknowledge") is not an ack — the bare ACKNOWLEDG alternative above would otherwise
# clear a thread the bot explicitly refused to accept. Detected before the ack match so
# such comments fall through to "undeterminable" (fail closed → thread stays open). The
# negator may be separated from ACKNOWLEDG by up to three words (e.g. "unable to fully
# acknowledge") so it survives light hedging.
readonly _ACV_BOT_ACK_NEGATION_RE_UPPER='(CANNOT|CAN.?T|COULD ?NOT|COULDN.?T|WILL NOT|WON.?T|DO(ES)? NOT|DON.?T|DOESN.?T|DID ?NOT|DIDN.?T|UNABLE|NOT ABLE|NEVER|NOT)[[:space:]]+([A-Z]+[[:space:]]+){0,3}ACKNOWLEDG'

# acv_parse_claim <reply_body>
#   Extract and validate the single claim payload from a reply body. On success,
#   echoes the canonical compact JSON and returns 0. On any failure, echoes a reason
#   token (no-claim | multiple-claims | malformed-json | bad-version | bad-sha |
#   bad-files) and returns 1. Pure — no gh/git/network.
acv_parse_claim() {
  local body="${1:-}"
  if [[ -z "$body" ]]; then
    echo "no-claim"
    return 1
  fi

  # Count claim comments. Zero -> pre-migration (unverifiable). More than one ->
  # malformed; never silently pick one.
  # Guard the grep: under `set -o pipefail` a no-match `grep` exits 1 and would
  # terminate the script on this bare assignment (the pre-migration no-claim case
  # is the common path). `|| true` neutralises only grep's exit; `wc -l` still
  # reports 0 for the empty stream, so the count stays correct.
  local count
  count=$( { grep -oF "$_ACV_CLAIM_PREFIX" <<<"$body" || true; } | wc -l | tr -d '[:space:]')
  if [[ "$count" == "0" ]]; then
    echo "no-claim"
    return 1
  fi
  if [[ "$count" != "1" ]]; then
    echo "multiple-claims"
    return 1
  fi

  # Extract the JSON between the literal prefix and the first trailing ` -->`.
  local rest json
  rest="${body#*"$_ACV_CLAIM_PREFIX"}"
  json="${rest%%"$_ACV_CLAIM_SUFFIX"*}"

  # Parse and enforce the field contract in one jq pass. Order matters: type checks
  # gate the length/element checks so a null/scalar field never errors the program.
  local verdict
  verdict=$(printf '%s' "$json" | jq -er '
      if (.v | type) != "number" or .v != 1 then "bad-version"
      elif (.sha | type) != "string" or ((.sha) | test("^[0-9a-f]{40}$") | not) then "bad-sha"
      elif (.files | type) != "array"
           or ((.files) | length) == 0
           or ((.files) | any(.[]; (type != "string") or (. == ""))) then "bad-files"
      else "ok" end
    ' 2>/dev/null) || {
    echo "malformed-json"
    return 1
  }

  if [[ "$verdict" != "ok" ]]; then
    echo "$verdict"
    return 1
  fi

  printf '%s' "$json" | jq -c . 2>/dev/null || {
    echo "malformed-json"
    return 1
  }
  return 0
}

# acv_latest_marker_index <comments_json> <bot_user>
#   Full-thread scan for OUR addressed-marker reply (#1735 AC1). <comments_json> is a
#   JSON array of {author:{login,__typename}, body, createdAt} in thread order. Echoes
#   the 0-based index of the LATEST comment authored by our account (bot_user or its
#   [bot]-stripped form) that carries the dev-lead addressed-marker, and returns 0.
#   Returns 1 (echoing nothing) when no such reply exists — the unchanged no-marker
#   case. The marker need NOT be the thread's last comment: a bot acknowledgement (or
#   our own later note) landing after it no longer hides the marker (the pre-#1735
#   comments(last:1) hole). Pure — no gh/git/network.
acv_latest_marker_index() {
  local comments_json="${1:-}" bot_user="${2:-}"
  local bot_user_stripped="${bot_user%\[bot\]}"

  # Single jq pass (no per-comment subprocess loop): select our-account comments whose
  # body carries the addressed-marker and echo the LAST such index. The marker regex is
  # the SAME _DEV_LEAD_ADDRESSED_MARKER constant review_reply_is_addressed_marker uses,
  # so the pattern still has a single source of truth. Only OUR account's marker
  # authorizes resolution (a foreign marker does not).
  local idx
  idx=$(jq -r \
    --arg bot_user "$bot_user" \
    --arg bot_user_stripped "$bot_user_stripped" \
    --arg pattern "$_DEV_LEAD_ADDRESSED_MARKER" \
      'if type == "array" then
        to_entries
        | map(select(
            (.value.author.login == $bot_user or .value.author.login == $bot_user_stripped) and
            ((.value.body // "") | test($pattern))
          ))
        | last | .key // ""
      else
        ""
      end' <<<"$comments_json" 2>/dev/null) || return 1

  if [[ -n "$idx" ]]; then
    echo "$idx"
    return 0
  fi
  return 1
}

# acv_bot_comment_is_acknowledgement <body>
#   Classify a post-marker BOT comment (#1735 AC2/AC4). Returns:
#     0 = acknowledgement / no new finding  (does not block resolution)
#     1 = a new finding                      (blocks — thread stays open)
#     2 = undeterminable                     (fail closed — thread stays open, AC4)
#   The finding signal is checked FIRST so a comment that both acknowledges and raises
#   a new point fails toward blocking. Pure — no gh/git/network.
acv_bot_comment_is_acknowledgement() {
  local body="${1:-}"
  [[ -z "$body" ]] && return 2
  local up="${body^^}"
  if [[ "$up" =~ $_ACV_BOT_FINDING_RE_UPPER ]]; then
    return 1
  fi
  # A negated acknowledgement is not an ack — fail closed rather than clearing.
  if [[ "$up" =~ $_ACV_BOT_ACK_NEGATION_RE_UPPER ]]; then
    return 2
  fi
  if [[ "$up" =~ $_ACV_BOT_ACK_RE_UPPER ]]; then
    return 0
  fi
  return 2
}

# acv_post_marker_clear <comments_json> <marker_index> <bot_user>
#   Assert nothing UNADDRESSED has landed since our marker reply (#1735 AC2/AC3/AC4).
#   Scans every comment AFTER <marker_index> and classifies it, reusing the SAME
#   discriminators the rest of the gate uses (no second classifier, #1735 AC3):
#     - our own account (login == bot_user / stripped)         -> ours, ignored;
#     - an agent-marker-bearing comment (review_thread_is_agent_authored) -> ours;
#     - a bot comment (author __typename Bot, or login endswith [bot]) -> classified
#       by acv_bot_comment_is_acknowledgement: ack clears, finding blocks (rc1),
#       undeterminable fails closed (rc2);
#     - any other marker-less User comment ALWAYS blocks (rc1), regardless of content
#       — this preserves the #1415 maintainer guard exactly;
#     - any other undeterminable author type -> fail closed (rc2).
#   Echoes a short reason token ("clear" | "bot-finding" | "bot-ambiguous" | "human" |
#   "unknown-author" | "unparseable"). Returns 0 only when clear. Pure.
acv_post_marker_clear() {
  local comments_json="${1:-}" marker_index="${2:-0}" bot_user="${3:-}"
  local bot_user_stripped="${bot_user%\[bot\]}"

  # Single jq pass extracts the three fields of every post-marker comment as one TSV
  # row (login, typename, base64(body)). Body is base64-encoded so embedded tabs and
  # newlines survive the row split; the loop then decodes it and runs the SAME shared
  # discriminators (review_thread_is_agent_authored, acv_bot_comment_is_acknowledgement)
  # — no jq is spawned inside the loop and no second classifier is introduced (#1735 AC3).
  local rows
  rows=$(jq -r --argjson mi "$marker_index" '
      if type == "array" then
        to_entries[]
        | select(.key > $mi)
        | [ (.value.author.login // ""), (.value.author.__typename // ""), ((.value.body // "") | @base64) ]
        | @tsv
      else empty end
    ' <<<"$comments_json" 2>/dev/null) || { echo "unparseable"; return 2; }
  [[ -z "$rows" ]] && { echo "clear"; return 0; }

  local login typename body_b64 body ack_rc
  while IFS=$'\t' read -r login typename body_b64; do
    body=$(base64 --decode <<<"$body_b64" 2>/dev/null || printf '')
    # Our own account is never an unaddressed comment.
    [[ "$login" == "$bot_user" || "$login" == "$bot_user_stripped" ]] && continue
    # An agent-marker-bearing comment is ours by the shared discriminator.
    review_thread_is_agent_authored "$body" && continue
    if [[ "$typename" == "Bot" || "$login" == *"[bot]" ]]; then
      acv_bot_comment_is_acknowledgement "$body" && ack_rc=0 || ack_rc=$?
      if [[ "$ack_rc" -eq 0 ]]; then
        continue
      elif [[ "$ack_rc" -eq 1 ]]; then
        echo "bot-finding"; return 1
      else
        echo "bot-ambiguous"; return 2
      fi
    fi
    if [[ "$typename" == "User" ]]; then
      echo "human"; return 1
    fi
    # Undeterminable author type -> fail closed.
    echo "unknown-author"; return 2
  done <<<"$rows"

  echo "clear"
  return 0
}

# acv_verify_intersection <files_json> <own_diff_files_nl> <cumulative_diff_files_nl>
#   The file-level hard gate (AC2/AC3). <files_json> is the claim's `files` array;
#   the two diff lists are newline-separated repo-relative paths (own = the named
#   commit's own diff; cumulative = `<sha>^..HEAD`). Returns 0 and echoes the range
#   that verified ("own" or "cumulative") when at least one claimed path is touched;
#   the named commit's own diff is checked first, the cumulative range second (the
#   amended/split-commit case). Returns 1 and echoes a reason (empty-diff |
#   no-file-intersection) otherwise. Non-empty diff is required: both lists empty ->
#   empty-diff. Pure — no gh/git/network.
acv_verify_intersection() {
  local files_json="${1:-}" own="${2:-}" cumulative="${3:-}"

  # Non-empty diff (AC2): nothing changed in either range -> fail closed.
  local own_has cum_has
  own_has=$(printf '%s' "$own" | grep -c '[^[:space:]]' || true)
  cum_has=$(printf '%s' "$cumulative" | grep -c '[^[:space:]]' || true)
  if [[ "${own_has:-0}" -eq 0 && "${cum_has:-0}" -eq 0 ]]; then
    echo "empty-diff"
    return 1
  fi

  if _acv_intersects "$files_json" "$own"; then
    echo "own"
    return 0
  fi
  if _acv_intersects "$files_json" "$cumulative"; then
    echo "cumulative"
    return 0
  fi
  echo "no-file-intersection"
  return 1
}

# _acv_intersects <files_json> <diff_files_nl>
#   Pure helper: 0 when any newline path in <diff_files_nl> is a member of the
#   <files_json> array, 1 otherwise. jq does the membership so paths with spaces or
#   unicode compare correctly.
_acv_intersects() {
  local files_json="${1:-}" diff="${2:-}"
  [[ -z "$files_json" ]] && return 1
  local hit
  hit=$(printf '%s' "$diff" | jq -R -s --argjson claim "$files_json" '
      (split("\n") | map(select(length > 0))) as $d
      | ($claim | any(.[]; . as $c | $d | index($c) != null))
    ' 2>/dev/null) || return 1
  [[ "$hit" == "true" ]]
}

# acv_latest_maintainer_disposition <comments_json> <bot_user>
#   Scan ALL comments in a thread (AC4) for a standing maintainer disposition.
#   <comments_json> is a JSON array of {author:{login,__typename}, body, createdAt}.
#   A comment counts as a maintainer disposition when it is: not our account, a
#   User (not a Bot), MARKER-LESS per review_thread_is_agent_authored (the mandated
#   discriminator), and asserts a required disposition (_ACV_DISPOSITION_RE_UPPER).
#   Returns:
#     0 + echoes the latest such comment's ISO createdAt  (a gate applies)
#     1 + echoes ""                                        (no disposition found)
#     2 + echoes "unparseable"                             (a disposition was found
#                                                           but its createdAt is
#                                                           missing/unparseable ->
#                                                           fail closed, leave open)
#   Pure — no gh/git/network.
acv_latest_maintainer_disposition() {
  local comments_json="${1:-}" bot_user="${2:-}"
  local bot_user_stripped="${bot_user%\[bot\]}"

  # Nothing to scan -> no disposition. An empty/invalid array is treated as "none"
  # (the thread's OTHER gates still apply); a genuinely unreadable value returns 1.
  # Each comment is emitted as one compact JSON line so an empty createdAt (the
  # exact fail-closed case) is not lost to IFS-whitespace field collapsing, and a
  # body with embedded newlines stays on a single line (JSON-escaped).
  local rows
  rows=$(printf '%s' "$comments_json" | jq -c '
      if type == "array" then .[] else empty end
    ' 2>/dev/null) || return 1
  [[ -z "$rows" ]] && return 1

  local latest="" saw_unparseable=0
  local obj login typename created body
  while IFS= read -r obj; do
    [[ -z "$obj" ]] && continue
    login=$(printf '%s' "$obj" | jq -r '.author.login // ""' 2>/dev/null || printf '')
    typename=$(printf '%s' "$obj" | jq -r '.author.__typename // ""' 2>/dev/null || printf '')
    created=$(printf '%s' "$obj" | jq -r '.createdAt // ""' 2>/dev/null || printf '')
    body=$(printf '%s' "$obj" | jq -r '.body // ""' 2>/dev/null || printf '')
    # Our own account / non-User authors are never maintainer dispositions.
    [[ "$login" == "$bot_user" || "$login" == "$bot_user_stripped" ]] && continue
    [[ "$typename" != "User" ]] && continue
    # Marker-less is the discriminator: an agent-authored comment (carrying one of
    # our markers) is ours, never a maintainer finding.
    review_thread_is_agent_authored "$body" && continue
    # Does the marker-less human comment assert a required disposition?
    [[ "${body^^}" =~ $_ACV_DISPOSITION_RE_UPPER ]] || continue
    # A disposition with no parseable timestamp cannot be ordered against the fix ->
    # fail closed.
    if [[ -z "$created" ]] || ! _acv_is_iso8601 "$created"; then
      saw_unparseable=1
      continue
    fi
    if [[ -z "$latest" || "$created" > "$latest" ]]; then
      latest="$created"
    fi
  done <<<"$rows"

  if [[ -n "$latest" ]]; then
    echo "$latest"
    return 0
  fi
  if [[ "$saw_unparseable" -eq 1 ]]; then
    echo "unparseable"
    return 2
  fi
  echo ""
  return 1
}

# _acv_is_iso8601 <string>
#   0 when <string> parses as an ISO-8601 instant, 1 otherwise. Uses jq's
#   fromdateiso8601 so the same parser the maintainer-review gate relies on decides.
_acv_is_iso8601() {
  local s="${1:-}"
  [[ -z "$s" ]] && return 1
  jq -e -n --arg s "$s" '($s | fromdateiso8601)' >/dev/null 2>&1
}

# acv_gather_commit_facts <sha>
#   The SINGLE impure gatherer: all git access lives here so the verifier above stays
#   pure. Echoes a JSON object:
#     {"on_head":bool,"own_files":[...],"cumulative_files":[...],"commit_date":"iso"}
#   - on_head: <sha> is reachable from HEAD (i.e. on the PR head branch).
#   - own_files: files in <sha>'s own diff.
#   - cumulative_files: files in `<sha>^..HEAD` (falls back to `<sha>..HEAD` when
#     <sha> is a root commit with no parent).
#   - commit_date: <sha>'s committer date, ISO-8601, or "" if unresolved.
#   Fails closed: any git error yields on_head=false and empty lists, so a caller can
#   never read an error as "verified". Runs in the current working directory (the PR
#   worktree at resolution time).
acv_gather_commit_facts() {
  local sha="${1:-}"
  local on_head=false own_files='[]' cumulative_files='[]' commit_date=""

  if [[ -n "$sha" ]] && git cat-file -e "${sha}^{commit}" 2>/dev/null; then
    if git merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
      on_head=true
    fi
    # Emit a Z-terminated UTC ISO-8601 instant (e.g. 2026-09-07T21:40:05Z), the
    # SAME shape GitHub's createdAt uses. `%cI` would emit a `+00:00` offset that
    # jq's fromdateiso8601 rejects and that does not compare lexicographically
    # against the Z-form disposition timestamps.
    commit_date=$(TZ=UTC git show -s --date=format-local:'%Y-%m-%dT%H:%M:%SZ' --format=%cd "$sha" 2>/dev/null || printf '')
    own_files=$(git diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null \
      | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || printf '[]')
    local range="${sha}^..HEAD"
    if ! git rev-parse -q --verify "${sha}^" >/dev/null 2>&1; then
      range="${sha}..HEAD"
    fi
    cumulative_files=$(git diff --name-only "$range" 2>/dev/null \
      | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || printf '[]')
  fi

  jq -c -n \
    --argjson on_head "$on_head" \
    --argjson own "$own_files" \
    --argjson cumulative "$cumulative_files" \
    --arg date "$commit_date" \
    '{on_head: $on_head, own_files: $own, cumulative_files: $cumulative, commit_date: $date}' \
    2>/dev/null || printf '{"on_head":false,"own_files":[],"cumulative_files":[],"commit_date":""}'
}
