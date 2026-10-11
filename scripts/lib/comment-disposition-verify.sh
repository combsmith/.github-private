#!/usr/bin/env bash
# comment-disposition-verify.sh — the pure verifier for the dev-lead PR
# issue-comment DISPOSITION marker (#1813).
#
# WHY THIS EXISTS
#   maintainer-comment-gate.sh (#1290) judged an issue comment "addressed" by
#   comparing timestamps: a push after the comment cleared it. That is a proxy —
#   it says nothing about whether the comment's finding was read, checked, and
#   acted on, and it depended on pushedDate (now always null), so the gate failed
#   closed on every open PR (#1813). The redesign makes "addressed" mean a
#   VERIFIED DISPOSITION: dev-lead researches each comment and posts exactly one
#   evidence-backed reply carrying
#
#     <!-- dev-lead:comment-disposition id=<comment_id> disposition=<fixed|invalid|
#          out-of-scope|answered|informational> [sha=<40-hex>] [ref=#<n>] -->
#
#   and the harness verifies that disposition and then minimizes the ORIGINAL
#   comment with classifier RESOLVED (GraphQL minimizeComment). The pr-review gate
#   then treats a RESOLVED-minimized comment as addressed. This library is the
#   issue-comment sibling of addressed-claim-verify.sh (the review-thread path).
#
# PURITY / TESTABILITY
#   Every cdv_* function here is PURE: no gh/git/network. Verification of a claim
#   against the pushed diff (the `fixed` case) reuses acv_gather_commit_facts from
#   addressed-claim-verify.sh in the caller; this library only decides, from the
#   parsed disposition and a caller-supplied `verified` boolean, whether the
#   harness may resolve the comment. Sourced under `set -euo pipefail`, so the
#   helpers only `return`, never `exit`, and fail closed on every ambiguity.

set -euo pipefail

# The literal marker delimiters — one definition shared by the emitter (prompt)
# and this parser.
readonly _CDV_MARKER_PREFIX='<!-- dev-lead:comment-disposition '
readonly _CDV_MARKER_SUFFIX=' -->'

# The five sanctioned dispositions (issue #1813 Design). Any other word is
# unverifiable → parse fails closed rather than guessing.
readonly _CDV_VALID_DISPOSITIONS='fixed invalid out-of-scope answered informational'

# This library's own directory, resolved ONCE at source time. The caller is run
# by a relative path (`bash .dev-lead/scripts/...`) and later cds into the PR
# worktree, so a function resolving BASH_SOURCE at call time gets a path that no
# longer exists and its registry read fails closed (#2152).
_CDV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
readonly _CDV_LIB_DIR

# The post-disposition BOT-reply classification (AC7 loop safety) reuses the
# review-thread verifier's acknowledgement/finding discriminators so there is a
# single source of truth. Source it only if the caller has not already (the main
# script sources both, so this never double-sources or re-declares readonly vars).
if ! declare -F acv_bot_comment_is_acknowledgement >/dev/null 2>&1; then
  # shellcheck source=addressed-claim-verify.sh
  source "$_CDV_LIB_DIR/addressed-claim-verify.sh"
fi

# cdv_parse_disposition <reply_body>
#   Extract and validate the single disposition marker from a reply body. On
#   success echoes canonical compact JSON {id,disposition,sha,ref} and returns 0
#   (sha/ref are "" when absent). On any failure echoes a reason token and
#   returns 1: no-disposition | multiple-dispositions | bad-id | bad-disposition
#   | bad-sha | missing-ref. Pure — no gh/git/network.
cdv_parse_disposition() {
  local body="${1:-}"
  if [[ -z "$body" ]]; then
    echo "no-disposition"
    return 1
  fi

  # Count markers. Zero → nothing to verify; more than one → malformed (never
  # silently pick one). `|| true` neutralises grep's no-match exit under pipefail.
  local count
  count=$( { grep -oF "$_CDV_MARKER_PREFIX" <<<"$body" || true; } | wc -l | tr -d '[:space:]')
  if [[ "$count" == "0" ]]; then
    echo "no-disposition"
    return 1
  fi
  if [[ "$count" != "1" ]]; then
    echo "multiple-dispositions"
    return 1
  fi

  # Extract the attribute string between the literal prefix and the trailing ` -->`.
  local rest attrs
  rest="${body#*"$_CDV_MARKER_PREFIX"}"
  # An unclosed marker (no trailing ` -->`) is malformed — reject it rather than
  # letting `attrs` absorb the entire remaining body and parse valid-looking keys.
  if [[ "$rest" != *"$_CDV_MARKER_SUFFIX"* ]]; then
    echo "bad-disposition"
    return 1
  fi
  attrs="${rest%%"$_CDV_MARKER_SUFFIX"*}"

  # Pull each key=value token. Keys are matched anchored so `id=` cannot capture
  # a substring of another key. A value runs to the next whitespace.
  local id disposition sha ref
  id=$(_cdv_attr "$attrs" id)
  disposition=$(_cdv_attr "$attrs" disposition)
  sha=$(_cdv_attr "$attrs" sha)
  ref=$(_cdv_attr "$attrs" ref)

  if [[ -z "$id" ]]; then
    echo "bad-id"
    return 1
  fi
  if [[ -z "$disposition" ]] || ! _cdv_is_valid_disposition "$disposition"; then
    echo "bad-disposition"
    return 1
  fi
  # `fixed` must cite a full 40-hex sha (abbreviated SHAs are rejected, matching
  # the addressed-claim contract).
  if [[ "$disposition" == "fixed" ]]; then
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "bad-sha"
      return 1
    fi
  fi
  # `out-of-scope` must cite the tracking reference it defers to.
  if [[ "$disposition" == "out-of-scope" && -z "$ref" ]]; then
    echo "missing-ref"
    return 1
  fi

  jq -c -n \
    --arg id "$id" \
    --arg disposition "$disposition" \
    --arg sha "$sha" \
    --arg ref "$ref" \
    '{id:$id, disposition:$disposition, sha:$sha, ref:$ref}' 2>/dev/null || {
    echo "bad-id"
    return 1
  }
}

# _cdv_attr <attr_string> <key>
#   Echo the value of `<key>=<value>` in a space-delimited attribute string, or
#   empty when the key is absent. Value runs to the next whitespace.
_cdv_attr() {
  local attrs="${1:-}" key="${2:-}"
  [[ -z "$key" ]] && return 0
  # Prepend a space so a leading key matches the same ` <key>=` pattern.
  local padded=" $attrs"
  if [[ "$padded" =~ [[:space:]]${key}=([^[:space:]]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# _cdv_is_valid_disposition <word>
#   0 when <word> is one of the five sanctioned dispositions, 1 otherwise.
_cdv_is_valid_disposition() {
  local w="${1:-}" d
  for d in $_CDV_VALID_DISPOSITIONS; do
    [[ "$w" == "$d" ]] && return 0
  done
  return 1
}

# cdv_authorize <disposition> <is_human> <verified>
#   Decide whether the harness may resolve (minimize RESOLVED) the ORIGINAL
#   comment. <is_human> and <verified> are the strings "true"/"false".
#     - <verified> is the disposition-specific verification the CALLER computed:
#         fixed        → cdv_fixed_verdict accepted the cited sha (#2004)
#         out-of-scope → the referenced issue exists
#         invalid/answered/informational → a reply with non-empty evidence exists
#     - A human maintainer's comment is auto-resolved ONLY on a verified `fixed`
#       (AC5); any other disposition leaves it open for the human to resolve, so
#       an agent can never dismiss a person's finding by arguing with it.
#     - A bot comment is resolved on any verified disposition (AC4).
#   Returns 0 = the harness may minimize; 1 = leave the comment open. Pure.
cdv_authorize() {
  local disposition="${1:-}" is_human="${2:-}" verified="${3:-}"
  [[ "$verified" == "true" ]] || return 1
  if [[ "$is_human" == "true" ]]; then
    [[ "$disposition" == "fixed" ]] && return 0
    return 1
  fi
  return 0
}

# ── `fixed` verification by diff content (#2004) ──────────────────────────────
# On PR #1977 a `fixed` disposition cited 89f46597, the commit that INTRODUCED the
# finding (its diff added `--emit-workflow-only`), not e7e7008b, the commit that
# removed it. The old rule ("the cited sha was produced by THIS pass") could never
# accept the real fix from an earlier pass, so the comment stayed open forever.
# Accepting any later commit instead would fail OPEN: an unrelated commit would
# resolve the comment. So the cited commit's own diff must REMOVE (a `-` line) a
# distinctive token named by the finding and must not ADD it (a `+` line). Only a
# finding with no extractable token falls back to the date rule, and the verdict
# fails closed unless the cited commit was produced by this pass (`tokenless-not-this-pass`).

# The jq program behind cdv_finding_tokens. HTML comments and fenced code blocks
# are dropped first: a fenced block is usually a suggested patch, whose text the
# fixing commit ADDS. Then it collects backticked spans, `--flag` names, and
# double- or single-quoted identifiers. A single quote counts only when it is not
# inside a word, so prose apostrophes ("it's") never open a span. The "p" flag
# lets `.` cross newlines, so a multi-line comment or fence is removed whole.
_CDV_TOKEN_JQ=$(cat <<'JQ'
def generic:
  (ascii_downcase) as $t
  | ($t | test("^[0-9]+([.][0-9]+)?$"))
    or ($t | test("^(local|true|false|if|then|else|elif|fi|return|echo|exit|set|unset|null|none|for|do|done|while|case|esac|in|function|export|readonly|declare|eval|test|and|or|not|the|and|git|jq|gh|bash|sh)$"))
    or ($t | test("^[a-z0-9_.-]*/[a-z0-9_./-]*$"))
    or ($t | test("^[a-z0-9_.-]+[.](sh|md|yml|yaml|json|bats|py|js|ts|txt)$"));
$b
| gsub("<!--.*?-->"; ""; "p")
| gsub("```.*?```"; ""; "p")
| [ (scan("`([^`\n]+)`") | .[0]),
    (scan("(?:^|[^A-Za-z0-9_-])(--[A-Za-z][A-Za-z0-9_-]*[A-Za-z0-9])") | .[0]),
    (scan("[\"“]([A-Za-z_][A-Za-z0-9_.:/-]*)[\"”]") | .[0]),
    (scan("(?:^|[^A-Za-z0-9])'([A-Za-z_][A-Za-z0-9_.:/-]*)'(?![A-Za-z0-9])") | .[0]) ]
| map(gsub("^\\s+|\\s+$"; ""))
| map(select(length >= 3 and length <= 200))
| map(select(generic | not))
| unique
| .[]
JQ
)
readonly _CDV_TOKEN_JQ

# cdv_finding_tokens <comment_body>
#   Echo the finding's distinctive tokens, one per line (sorted, unique). Spans
#   shorter than 3 characters, shell keywords, bare numbers and pure path-like spans
#   are dropped as too generic to identify a fix. Echoes
#   nothing (rc 0) when the body names no token. Pure.
cdv_finding_tokens() {
  local body="${1:-}"
  [[ -z "$body" ]] && return 0
  jq -rn --arg b "$body" "$_CDV_TOKEN_JQ" 2>/dev/null || true
}

# _cdv_diff_side <diff> <-|+>
#   The removed (`-`) or added (`+`) lines of a unified diff, without the
#   `--- a/…` / `+++ b/…` file headers and without the one-character diff
#   marker, so a token at column 0 is not flanked by `-`/`+`. Pure.
_cdv_diff_side() {
  local diff="${1:-}" side="${2:-}"
  if [[ "$side" == "-" ]]; then
    { grep -E '^-' <<< "$diff" || true; } | { grep -vE '^--- (a/|/dev/null)' || true; } | sed 's/^.//'
  else
    { grep -E '^\+' <<< "$diff" || true; } | { grep -vE '^\+\+\+ (b/|/dev/null)' || true; } | sed 's/^.//'
  fi
}

# _cdv_has_token <text> <token>
#   rc 0 when <token> occurs in <text> as a whole token: not flanked by a
#   word character or `-`, so `--emit-workflow` never matches inside
#   `--emit-workflow-only`. Pure.
_cdv_has_token() {
  local text="${1:-}" tok="${2:-}" esc
  esc=$(sed 's/[][\.^$*+?(){}|/]/\\&/g' <<< "$tok")
  grep -qE -- "(^|[^A-Za-z0-9_-])${esc}($|[^A-Za-z0-9_-])" <<< "$text"
}

# cdv_removed_token <diff> <tokens>
#   Echo the first token (from the newline-separated <tokens>) that appears on a
#   removed line of <diff> and on no added line; rc 0. rc 1 when there is none.
#   Matching is whole-token (see _cdv_has_token). Pure.
cdv_removed_token() {
  local diff="${1:-}" tokens="${2:-}" removed added tok
  removed=$(_cdv_diff_side "$diff" "-")
  added=$(_cdv_diff_side "$diff" "+")
  while IFS= read -r tok; do
    [[ -z "$tok" ]] && continue
    if _cdv_has_token "$removed" "$tok" && ! _cdv_has_token "$added" "$tok"; then
      printf '%s' "$tok"
      return 0
    fi
  done <<< "$tokens"
  return 1
}

# cdv_diff_token_verdict <diff> <tokens>
#   Judge whether the cited commit's diff addresses the finding. Echoes one token:
#     content-removes-token    — a token is removed and not re-added (rc 0)
#     content-adds-token       — no such token, and the diff ADDS one (the
#                                introducing commit, the #1977 shape) (rc 1)
#     content-no-token-removed — the diff does not touch any token (an unrelated
#                                commit) (rc 1)
#     no-tokens                — <tokens> is empty (rc 1); cdv_fixed_verdict then
#                                requires the commit to be from this pass
#   Note: #2051 — when a finding has multiple distinct issues (multiple tokens),
#   this function accepts a commit that removes only one, even if others remain.
#   The verification could be strengthened by requiring all tokens to be removed
#   or by checking that no unrelated changes accompany the token removal.
#   Pure.
cdv_diff_token_verdict() {
  local diff="${1:-}" tokens="${2:-}" added tok
  local cleaned_tokens
  cleaned_tokens=$(sed '/^[[:space:]]*$/d' <<< "$tokens") || true
  if [[ -z "$cleaned_tokens" ]]; then
    echo "no-tokens"
    return 1
  fi
  if cdv_removed_token "$diff" "$tokens" >/dev/null; then
    echo "content-removes-token"
    return 0
  fi
  added=$(_cdv_diff_side "$diff" "+")
  while IFS= read -r tok; do
    [[ -z "$tok" ]] && continue
    if _cdv_has_token "$added" "$tok"; then
      echo "content-adds-token"
      return 1
    fi
  done <<< "$tokens"
  echo "content-no-token-removed"
  return 1
}

# cdv_fixed_verdict <on_head> <in_base> <own_files> <commit_date> <finding_created> <content_verdict> [this_pass]
#   The full `fixed` verdict. Arguments are facts the caller gathered:
#     <on_head>          "true" when the sha is reachable from the PR's pushed head
#     <in_base>          "true" / "false" (the sha is / is not on the base branch),
#                        or "unknown" when the base branch could not be read
#     <own_files>        the number of files in the sha's own diff
#     <commit_date>      the sha's committer date (ISO-8601 Z), "" if unreadable
#     <finding_created>  the original comment's createdAt (ISO-8601 Z)
#     <content_verdict>  cdv_diff_token_verdict's token
#     <this_pass>        "true" when the sha is a commit produced by THIS pass (not
#                        reachable from RESOLUTION_BASE_SHA); only a tokenless
#                        finding consults it
#   Echoes the first failing reason, in this order: not-on-head | base-unknown |
#   on-base-branch | empty-diff | content-adds-token | content-no-token-removed |
#   content-unknown | undated | predates-finding | tokenless-not-this-pass (rc 1).
#   On success echoes content-removes-token, or tokenless-this-pass when the finding
#   had no token and the commit was produced by this pass (rc 0).
#   Fails closed on every unreadable input. Pure.
cdv_fixed_verdict() {
  local on_head="${1:-}" in_base="${2:-}" own_files="${3:-0}" commit_date="${4:-}"
  local finding_created="${5:-}" content="${6:-}" this_pass="${7:-false}"
  local iso='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  if [[ "$on_head" != "true" ]]; then
    echo "not-on-head"; return 1
  fi
  if [[ "$in_base" != "true" && "$in_base" != "false" ]]; then
    echo "base-unknown"; return 1
  fi
  if [[ "$in_base" == "true" ]]; then
    echo "on-base-branch"; return 1
  fi
  if [[ ! "$own_files" =~ ^[0-9]+$ ]] || [[ "$own_files" -eq 0 ]]; then
    echo "empty-diff"; return 1
  fi
  case "$content" in
    content-removes-token|no-tokens) ;;
    content-adds-token|content-no-token-removed)
      echo "$content"; return 1 ;;
    *)
      echo "content-unknown"; return 1 ;;
  esac
  if [[ ! "$commit_date" =~ $iso ]]; then
    echo "undated"; return 1
  fi
  # An unreadable finding time cannot show the commit came after it: fail closed.
  if [[ ! "$finding_created" =~ $iso ]] || [[ "$commit_date" < "$finding_created" ]]; then
    echo "predates-finding"; return 1
  fi
  if [[ "$content" == "no-tokens" ]]; then
    # No token to match against a diff: only a commit this pass produced counts.
    if [[ "$this_pass" != "true" ]]; then
      echo "tokenless-not-this-pass"; return 1
    fi
    echo "tokenless-this-pass"
  else
    echo "content-removes-token"
  fi
  return 0
}

# cdv_select_disposition <cid> <bot_user> <comments_json>
#   Duplicate recovery / idempotency (#1992). The pre-#1992 resolver required
#   EXACTLY ONE authorized disposition per comment and failed closed on more, so
#   a comment that was dispositioned but not minimized in the same pass could
#   never converge: each later pass posted a second disposition, the resolver
#   then skipped the comment forever, and the maintainer gate deadlocked (#1952,
#   #1953). This picks ONE disposition deterministically so N authorized replies
#   collapse to one that the caller verifies + minimizes, while the rest are
#   reported as superseded for the caller to minimize OUTDATED.
#
#   Among the comments in <comments_json> (the PR's issue-comment nodes, each
#   {id, author{login,__typename}, body, isMinimized, minimizedReason, createdAt})
#   it keeps only replies that are ALL of:
#     - authored by <bot_user> (login == bot_user or its [bot]-stripped form) —
#       the authorization gate (CWE-863): a disposition from any other author
#       never counts and can never win, so an external commenter cannot smuggle a
#       marker citing a candidate id past the resolver;
#     - explicitly NOT minimized (isMinimized == false; a missing or unreadable
#       value fails closed, and a superseded reply we minimized on a prior pass
#       stops counting, so the count truly converges to one);
#     - carrying a well-formed ISO-8601 createdAt (an unreadable timestamp could
#       otherwise win the "latest" comparison, so it fails closed);
#     - parseable by cdv_parse_disposition AND citing id=<cid> (an unparseable or
#       mis-targeted marker is ignored — fail closed, never guessed).
#   Of those it selects the LATEST by createdAt, tie-broken by node id (lexical,
#   higher wins) so the choice is fully deterministic. Recommends the latest per
#   the issue, and the latest reflects dev-lead's most recent research.
#
#   Emits compact JSON and returns 0 when >=1 authorized disposition is found:
#     {auth_count:N, chosen:{id,createdAt,disposition:{…}}, superseded:[id,…]}
#   Emits {auth_count:0, chosen:null, superseded:[]} and returns 1 when none.
#   Pure — no gh/git/network (jq + cdv_parse_disposition only).
cdv_select_disposition() {
  local cid="${1:-}" bot_user="${2:-}" comments_json="${3:-}"
  if [[ -z "$cid" || -z "$comments_json" ]]; then
    echo '{"auth_count":0,"chosen":null,"superseded":[]}'
    return 1
  fi
  local bot_stripped="$bot_user"
  [[ "$bot_user" == *"[bot]" ]] && bot_stripped="${bot_user%\[bot\]}"

  # Base64-frame each candidate record so bodies with newlines/quotes survive the
  # read loop. jq does the author + not-minimized filtering; cdv_parse_disposition
  # (bash) does the per-reply parse because it is the single source of truth.
  local records
  records=$(printf '%s' "$comments_json" | jq -r \
    --arg botuser "$bot_user" --arg botstripped "$bot_stripped" '
      (.[]? // empty) | objects
      | (.author?.login // "" | tostring) as $l
      | select($l == $botuser or $l == $botstripped)
      | select(.isMinimized == false)
      | select((.createdAt // "" | tostring) | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      | {id:(.id // ""), createdAt:.createdAt, body:(.body // "")} | @base64
    ' 2>/dev/null || true)

  local auth_count=0 chosen_id="" chosen_created="" chosen_disp=""
  local superseded=()
  local rec rec_json rid rcreated rbody parsed pid newer
  while IFS= read -r rec; do
    [[ -z "$rec" ]] && continue
    rec_json=$(printf '%s' "$rec" | base64 -d 2>/dev/null || true)
    [[ -z "$rec_json" ]] && continue
    rbody=$(printf '%s' "$rec_json" | jq -r '.body // ""' 2>/dev/null || echo "")
    rid=$(printf '%s' "$rec_json" | jq -r '.id // ""' 2>/dev/null || echo "")
    rcreated=$(printf '%s' "$rec_json" | jq -r '.createdAt // ""' 2>/dev/null || echo "")
    parsed=$(cdv_parse_disposition "$rbody" 2>/dev/null) || continue
    pid=$(printf '%s' "$parsed" | jq -r '.id // ""' 2>/dev/null || echo "")
    [[ "$pid" == "$cid" ]] || continue
    auth_count=$((auth_count + 1))
    newer="false"
    if [[ -z "$chosen_id" ]]; then
      newer="true"
    elif [[ "$rcreated" > "$chosen_created" ]]; then
      newer="true"
    elif [[ "$rcreated" == "$chosen_created" && "$rid" > "$chosen_id" ]]; then
      newer="true"
    fi
    if [[ "$newer" == "true" ]]; then
      [[ -n "$chosen_id" ]] && superseded+=("$chosen_id")
      chosen_id="$rid"
      chosen_created="$rcreated"
      chosen_disp="$parsed"
    else
      superseded+=("$rid")
    fi
  done <<< "$records"

  if [[ "$auth_count" -eq 0 ]]; then
    echo '{"auth_count":0,"chosen":null,"superseded":[]}'
    return 1
  fi

  local sup_json
  sup_json=$(printf '%s\n' "${superseded[@]:-}" | jq -R . | jq -s 'map(select(. != ""))' 2>/dev/null || echo "[]")
  jq -c -n \
    --argjson ac "$auth_count" \
    --arg cid2 "$chosen_id" \
    --arg cc "$chosen_created" \
    --argjson disp "$chosen_disp" \
    --argjson sup "$sup_json" \
    '{auth_count:$ac, chosen:{id:$cid2, createdAt:$cc, disposition:$disp}, superseded:$sup}' 2>/dev/null
}

# cdv_disposition_is_stale <comment_lastEditedAt> <disposition_createdAt>
#   Edits re-open a dispositioned comment (#2008). CodeRabbit edits ONE summary
#   comment in place, so a disposition made BEFORE the latest edit judged an older
#   body. On PR #2000 a security finding was appended about an hour after the
#   comment was dispositioned `informational` and minimized, and it was never
#   addressed. This compares the comment's lastEditedAt with the createdAt of the
#   disposition chosen by cdv_select_disposition.
#     0 = stale: edited strictly AFTER the disposition, so a fresh one is needed
#     1 = current: never edited ("" / "null"), or edited at/before the disposition
#     2 = unreadable: a timestamp that is not ISO-8601 UTC (or an empty
#         disposition time), so the caller fails closed
#   Edit timestamps are second-granular. An edit in the same second as the
#   disposition counts as seen, so a disposition is never re-opened by its own
#   race. Pure.
cdv_disposition_is_stale() {
  local edited="${1:-}" disposed="${2:-}"
  local iso='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  [[ "$disposed" =~ $iso ]] || return 2
  if [[ -z "$edited" || "$edited" == "null" ]]; then
    return 1
  fi
  [[ "$edited" =~ $iso ]] || return 2
  [[ "$edited" > "$disposed" ]] && return 0
  return 1
}

# cdv_body_has_findings <comment_body>
#   0 when <comment_body> carries a FINDING-BEARING section per the reviewer-source
#   registry's reviewer_sources_finding_section_pattern (#2008), such as CodeRabbit's
#   Security Architecture Review with retained concerns, even when the same comment
#   also shows a rate-limit block. 1 when it carries none.
#   An `informational` disposition never verifies against a body this returns 0
#   for: a rate-limit notice covers only its own section, never the findings
#   beside it.
#   FAILS CLOSED: an unreadable registry or a jq error returns 0 ("has findings"),
#   so an `informational` disposition can never be certified on a body we could not
#   classify. Pure apart from reading the registry file.
cdv_body_has_findings() {
  local body="${1:-}" pattern result
  pattern="$(
    # shellcheck source=reviewer-sources.sh
    source "$_CDV_LIB_DIR/reviewer-sources.sh" 2>/dev/null \
      && reviewer_sources_finding_section_pattern 2>/dev/null
  )" || return 0
  [[ -n "$pattern" ]] || return 0
  result="$(jq -nr --arg b "$body" --arg p "$pattern" '$b | test($p)' 2>/dev/null)" || return 0
  [[ "$result" == "false" ]] && return 1
  return 0
}

# cdv_reply_needs_response <bot_reply_body>
#   Loop safety (#860 / AC7): a bot that replies AFTER our disposition is answered
#   again ONLY if it raises a genuinely NEW finding — boilerplate/acknowledgements
#   never start a reply chain. Reuses acv_bot_comment_is_acknowledgement (the same
#   discriminator the review-thread path uses):
#     new finding (rc1)                    → 0 (respond)
#     acknowledgement (rc0) / ambiguous(2) → 1 (do NOT respond)
#   Pure — no gh/git/network.
cdv_reply_needs_response() {
  local body="${1:-}"
  local ack_rc=0
  acv_bot_comment_is_acknowledgement "$body" || ack_rc=$?
  [[ "$ack_rc" -eq 1 ]] && return 0
  return 1
}
