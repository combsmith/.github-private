#!/usr/bin/env bats
# Tests for comment-disposition-verify.sh (issue #1813)
#
# The pure verifier that turns a dev-lead comment-disposition reply into a
# machine-checkable claim, and decides whether the harness may resolve (minimize
# as RESOLVED) the original PR issue comment. Mirrors addressed-claim-verify.sh
# (review-thread path) for the issue-comment path.
#
#   cdv_parse_disposition <reply_body>
#     0 + canonical JSON {id,disposition,sha,ref}   (valid single marker)
#     1 + reason token (no-disposition | multiple-dispositions | bad-id |
#                       bad-disposition | bad-sha | missing-ref)
#   cdv_authorize <disposition> <is_human> <verified>
#     0 = the harness may minimize the comment RESOLVED; 1 = leave it open
#   cdv_reply_needs_response <bot_reply_body>
#     0 = the bot's reply-to-our-disposition raises a NEW finding (answer it)
#     1 = boilerplate / acknowledgement / ambiguous (do NOT answer — loop safety)

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME%/*}")" && pwd)/../../scripts"
  LIB="$SCRIPT_DIR/lib/comment-disposition-verify.sh"
}

teardown() {
  unset SCRIPT_DIR
}

_parse() {
  run bash -c "source '$LIB'; cdv_parse_disposition \"\$1\"" _ "$1"
}

_authorize() {
  run bash -c "source '$LIB'; cdv_authorize \"\$1\" \"\$2\" \"\$3\"" _ "$1" "$2" "$3"
}

_needs_response() {
  run bash -c "source '$LIB'; cdv_reply_needs_response \"\$1\"" _ "$1"
}

# ────────────────────────────────────────────────────────────────────
# STRUCTURAL
# ────────────────────────────────────────────────────────────────────

@test "verifier: has correct shebang" {
  head -1 "$LIB" | grep -q "^#!/usr/bin/env bash"
}

@test "verifier: uses set -euo pipefail" {
  grep -q "^set -euo pipefail" "$LIB"
}

@test "verifier: shellcheck passes" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  shellcheck --shell=bash --severity=warning "$LIB"
}

# ────────────────────────────────────────────────────────────────────
# cdv_parse_disposition
# ────────────────────────────────────────────────────────────────────

@test "parse: valid answered disposition → JSON" {
  _parse 'Answered below.
<!-- dev-lead:comment-disposition id=IC_123 disposition=answered -->'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.id == "IC_123" and .disposition == "answered"'
}

@test "parse: valid fixed disposition with sha → JSON" {
  _parse 'Fixed.
<!-- dev-lead:comment-disposition id=IC_9 disposition=fixed sha=3cc4132fd4b4692aa20865f8b68ea8e21de604b8 -->'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.disposition == "fixed" and (.sha | length) == 40'
}

@test "parse: valid out-of-scope disposition with ref → JSON" {
  _parse 'Tracked elsewhere.
<!-- dev-lead:comment-disposition id=IC_9 disposition=out-of-scope ref=#42 -->'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.disposition == "out-of-scope" and .ref == "#42"'
}

@test "parse: no marker → no-disposition rc1" {
  _parse 'Just a plain reply with no marker.'
  [ "$status" -eq 1 ]
  [ "$output" = "no-disposition" ]
}

@test "parse: two markers → multiple-dispositions rc1" {
  _parse '<!-- dev-lead:comment-disposition id=a disposition=answered -->
<!-- dev-lead:comment-disposition id=b disposition=invalid -->'
  [ "$status" -eq 1 ]
  [ "$output" = "multiple-dispositions" ]
}

@test "parse: unknown disposition word → bad-disposition rc1" {
  _parse '<!-- dev-lead:comment-disposition id=a disposition=maybe -->'
  [ "$status" -eq 1 ]
  [ "$output" = "bad-disposition" ]
}

@test "parse: fixed without sha → bad-sha rc1" {
  _parse '<!-- dev-lead:comment-disposition id=a disposition=fixed -->'
  [ "$status" -eq 1 ]
  [ "$output" = "bad-sha" ]
}

@test "parse: fixed with abbreviated sha → bad-sha rc1" {
  _parse '<!-- dev-lead:comment-disposition id=a disposition=fixed sha=3cc4132 -->'
  [ "$status" -eq 1 ]
  [ "$output" = "bad-sha" ]
}

@test "parse: out-of-scope without ref → missing-ref rc1" {
  _parse '<!-- dev-lead:comment-disposition id=a disposition=out-of-scope -->'
  [ "$status" -eq 1 ]
  [ "$output" = "missing-ref" ]
}

@test "parse: missing id → bad-id rc1" {
  _parse '<!-- dev-lead:comment-disposition disposition=answered -->'
  [ "$status" -eq 1 ]
  [ "$output" = "bad-id" ]
}

# ────────────────────────────────────────────────────────────────────
# cdv_authorize  (AC4 / AC5)
# ────────────────────────────────────────────────────────────────────

@test "authorize: bot comment + any verified disposition → 0 (resolve)" {
  _authorize answered false true
  [ "$status" -eq 0 ]
}

@test "authorize: bot comment + unverified disposition → 1 (leave open)" {
  _authorize answered false false
  [ "$status" -eq 1 ]
}

# AC9(c): a fixed disposition whose sha is not on head is unverified → blocks.
@test "AC9c: fixed disposition, sha not on head (verified=false) → 1 (block)" {
  _authorize fixed false false
  [ "$status" -eq 1 ]
}

# AC5: a human maintainer comment auto-resolves ONLY on a verified fixed.
@test "AC5: human comment + verified fixed → 0 (resolve)" {
  _authorize fixed true true
  [ "$status" -eq 0 ]
}

# AC9(d): a human comment with a non-fixed disposition stays open for the human.
@test "AC9d: human comment + verified invalid → 1 (leave open for human)" {
  _authorize invalid true true
  [ "$status" -eq 1 ]
}

@test "AC9d: human comment + verified answered → 1 (leave open for human)" {
  _authorize answered true true
  [ "$status" -eq 1 ]
}

# ────────────────────────────────────────────────────────────────────
# cdv_reply_needs_response  (AC7 / AC9f — loop safety)
# ────────────────────────────────────────────────────────────────────

# AC9(f): a bot's boilerplate/acknowledgement reply does not trigger another reply.
@test "AC9f: bot boilerplate ack reply → 1 (do not respond)" {
  _needs_response '✅ Customized review instruction saved!'
  [ "$status" -eq 1 ]
}

@test "AC9f: bot reply with a genuinely new finding → 0 (respond)" {
  _needs_response 'Potential issue: this introduces a SQL injection vulnerability.'
  [ "$status" -eq 0 ]
}

@test "AC9f: ambiguous bot reply → 1 (do not respond — no chain)" {
  _needs_response 'Thanks for the update.'
  [ "$status" -eq 1 ]
}

# ────────────────────────────────────────────────────────────────────
# cdv_select_disposition  (issue #1992 — duplicate recovery / idempotency)
#
#   cdv_select_disposition <cid> <bot_user> <comments_json>
#     Picks, among BOT_USER-authored, non-minimized, parseable disposition
#     replies citing <cid>, the LATEST by createdAt (tie-break: node id). Emits
#     {auth_count, chosen:{id,createdAt,disposition}, superseded:[ids]} and
#     returns 0 when >=1, else emits auth_count 0 and returns 1. Pure.
# ────────────────────────────────────────────────────────────────────

_select() {
  run bash -c "source '$LIB'; cdv_select_disposition \"\$1\" \"\$2\" \"\$3\"" _ "$1" "$2" "$3"
}

# A BOT_USER disposition reply node. $1=id $2=createdAt $3=disposition $4=target-id [$5=sha]
_mk_reply() {
  local id="$1" created="$2" disp="$3" tid="$4" sha="${5:-}"
  local marker="<!-- dev-lead:comment-disposition id=${tid} disposition=${disp}"
  [ -n "$sha" ] && marker="${marker} sha=${sha}"
  marker="${marker} -->"
  jq -n --arg id "$id" --arg c "$created" \
    --arg body "Looked into it.
${marker}" \
    '{id:$id, author:{login:"donpetry-bot", __typename:"User"}, body:$body, isMinimized:false, minimizedReason:null, createdAt:$c}'
}

@test "select: single authorized disposition → auth_count 1, chosen is it, no superseded (idempotent)" {
  local c; c=$(jq -s '.' <(_mk_reply "R1" "2026-09-26T21:00:00Z" "invalid" "IC_X"))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "1" ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R1" ]
  [ "$(echo "$output" | jq -r '.superseded | length')" = "0" ]
}

@test "select: three authorized dispositions → latest chosen, other two superseded (#1952)" {
  local c
  c=$(jq -s '.' \
    <(_mk_reply "R_fixed" "2026-09-26T21:44:49Z" "fixed" "IC_X" "c03ecdac03ecdac03ecdac03ecdac03ecdac03ec") \
    <(_mk_reply "R_inv1"  "2026-09-26T21:56:53Z" "invalid" "IC_X") \
    <(_mk_reply "R_inv2"  "2026-09-26T22:16:28Z" "invalid" "IC_X"))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "3" ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R_inv2" ]
  [ "$(echo "$output" | jq -r '.chosen.disposition.disposition')" = "invalid" ]
  [ "$(echo "$output" | jq -r '.superseded | sort | join(",")')" = "R_fixed,R_inv1" ]
}

@test "select: non-BOT_USER disposition is ignored and cannot win (CWE-863)" {
  # An attacker posts a LATER disposition citing the same id; it must not win,
  # and must not even be counted — only the earlier BOT_USER reply is authorized.
  local attacker bot c
  attacker=$(jq -n '{id:"R_attack", author:{login:"mallory", __typename:"User"},
    body:"fixed it\n<!-- dev-lead:comment-disposition id=IC_X disposition=fixed sha=c03ecdac03ecdac03ecdac03ecdac03ecdac03ec -->",
    isMinimized:false, minimizedReason:null, createdAt:"2026-09-27T00:00:00Z"}')
  bot=$(_mk_reply "R_bot" "2026-09-26T21:00:00Z" "invalid" "IC_X")
  c=$(jq -s '.' <(echo "$bot") <(echo "$attacker"))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "1" ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R_bot" ]
  [ "$(echo "$output" | jq -r '.superseded | length')" = "0" ]
}

@test "select: minimized disposition replies are excluded" {
  local minimized bot c
  minimized=$(jq -n '{id:"R_old", author:{login:"donpetry-bot", __typename:"User"},
    body:"old\n<!-- dev-lead:comment-disposition id=IC_X disposition=invalid -->",
    isMinimized:true, minimizedReason:"OUTDATED", createdAt:"2026-09-27T00:00:00Z"}')
  bot=$(_mk_reply "R_live" "2026-09-26T21:00:00Z" "answered" "IC_X")
  c=$(jq -s '.' <(echo "$minimized") <(echo "$bot"))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "1" ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R_live" ]
}

@test "select: unparseable marker among them is ignored (fails closed, not counted)" {
  local bad bot c
  bad=$(jq -n '{id:"R_bad", author:{login:"donpetry-bot", __typename:"User"},
    body:"two markers\n<!-- dev-lead:comment-disposition id=IC_X disposition=invalid -->\n<!-- dev-lead:comment-disposition id=IC_X disposition=fixed -->",
    isMinimized:false, minimizedReason:null, createdAt:"2026-09-27T05:00:00Z"}')
  bot=$(_mk_reply "R_good" "2026-09-26T21:00:00Z" "invalid" "IC_X")
  c=$(jq -s '.' <(echo "$bad") <(echo "$bot"))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "1" ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R_good" ]
}

@test "select: a disposition citing a DIFFERENT id does not match" {
  local c; c=$(jq -s '.' <(_mk_reply "R1" "2026-09-26T21:00:00Z" "invalid" "IC_OTHER"))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "0" ]
}

@test "select: zero authorized dispositions → rc1, auth_count 0" {
  _select "IC_X" "donpetry-bot" "[]"
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "0" ]
}

@test "select: equal createdAt ties broken deterministically by node id (higher wins)" {
  local c
  c=$(jq -s '.' \
    <(_mk_reply "R_aaa" "2026-09-26T21:00:00Z" "invalid" "IC_X") \
    <(_mk_reply "R_zzz" "2026-09-26T21:00:00Z" "answered" "IC_X"))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R_zzz" ]
  [ "$(echo "$output" | jq -r '.superseded[0]')" = "R_aaa" ]
}

@test "select: a reply with missing isMinimized is excluded (fails closed)" {
  local c
  c=$(jq -s '.' \
    <(_mk_reply "R_ok" "2026-09-26T21:00:00Z" "invalid" "IC_X") \
    <(_mk_reply "R_unk" "2026-09-26T22:00:00Z" "invalid" "IC_X" | jq 'del(.isMinimized)'))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "1" ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R_ok" ]
}

@test "select: a reply with a malformed createdAt cannot win as latest (fails closed)" {
  local c
  c=$(jq -s '.' \
    <(_mk_reply "R_ok" "2026-09-26T21:00:00Z" "invalid" "IC_X") \
    <(_mk_reply "R_bad" "zzzz-not-a-time" "invalid" "IC_X"))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "1" ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R_ok" ]
}

@test "select: matches BOT_USER given with [bot] suffix (graphql-stripped login)" {
  local c; c=$(jq -s '.' <(_mk_reply "R1" "2026-09-26T21:00:00Z" "invalid" "IC_X"))
  _select "IC_X" "donpetry-bot[bot]" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R1" ]
}

# ── #2008: edits re-open a dispositioned comment ─────────────────────────────
# cdv_disposition_is_stale <comment_lastEditedAt> <disposition_createdAt>
#   0 = the comment was edited AFTER the disposition (stale — needs a fresh one)
#   1 = not stale (never edited, or edited at/before the disposition)
#   2 = a timestamp is unreadable (caller fails closed)

_stale() {
  run bash -c "source '$LIB'; cdv_disposition_is_stale \"\$1\" \"\$2\"" _ "$1" "$2"
}

@test "stale(#2008): edited after the disposition → 0 (stale)" {
  _stale "2026-10-01T20:35:00Z" "2026-10-01T19:23:54Z"
  [ "$status" -eq 0 ]
}

@test "stale(#2008): edited before the disposition → 1" {
  _stale "2026-10-01T19:20:00Z" "2026-10-01T19:23:54Z"
  [ "$status" -eq 1 ]
}

@test "stale(#2008): edited at exactly the disposition time → 1 (the disposition saw that body)" {
  _stale "2026-10-01T19:23:54Z" "2026-10-01T19:23:54Z"
  [ "$status" -eq 1 ]
}

@test "stale(#2008): never edited (empty or null lastEditedAt) → 1" {
  _stale "" "2026-10-01T19:23:54Z"
  [ "$status" -eq 1 ]
  _stale "null" "2026-10-01T19:23:54Z"
  [ "$status" -eq 1 ]
}

@test "stale(#2008): an unreadable timestamp fails closed → 2" {
  _stale "yesterday" "2026-10-01T19:23:54Z"
  [ "$status" -eq 2 ]
  _stale "2026-10-01T20:35:00Z" ""
  [ "$status" -eq 2 ]
  _stale "2026-10-01T20:35:00Z" "not-a-time"
  [ "$status" -eq 2 ]
}

# ── #2004: a `fixed` disposition is verified by the cited commit's DIFF CONTENT ──
# On PR #1977 a `fixed` disposition cited 89f46597, the commit that INTRODUCED the
# finding (it added `--emit-workflow-only`), not e7e7008b, the commit that removed
# it. The cited diff must REMOVE a distinctive token from the finding and must not
# ADD it. A tokenless finding fails closed unless the commit is from this pass.
#   cdv_finding_tokens <body>                  → one token per line
#   cdv_diff_token_verdict <diff> <tokens>     → content-removes-token (rc0) |
#       content-adds-token | content-no-token-removed | no-tokens (rc1)
#   cdv_removed_token <diff> <tokens>          → the token the diff removes (rc0)
#   cdv_fixed_verdict <on_head> <in_base> <own_files> <commit_date> <finding_created> <content>
#       → content-removes-token | tokenless-this-pass (rc0), else a reason token (rc1)

_tokens() {
  run bash -c "source '$LIB'; cdv_finding_tokens \"\$1\"" _ "$1"
}

_diff_verdict() {
  run bash -c "source '$LIB'; cdv_diff_token_verdict \"\$1\" \"\$2\"" _ "$1" "$2"
}

_fixed_verdict() {
  run bash -c "source '$LIB'; cdv_fixed_verdict \"\$@\"" _ "$@"
}

# The #1977 CodeAnt nitpick, the introducing diff, and the fixing diff.
_1977_FINDING='**Nitpick:** this comment names a nonexistent `--emit-workflow-only` mode in `scripts/template_stub_drift.sh`; the real mode is "--emit-workflow".'
_1977_INTRODUCING='diff --git a/scripts/template_stub_drift.sh b/scripts/template_stub_drift.sh
--- a/scripts/template_stub_drift.sh
+++ b/scripts/template_stub_drift.sh
@@ -10,0 +11 @@
+# the --emit-workflow-only REFERENCE_MANIFEST mode'
_1977_FIXING='diff --git a/scripts/template_stub_drift.sh b/scripts/template_stub_drift.sh
--- a/scripts/template_stub_drift.sh
+++ b/scripts/template_stub_drift.sh
@@ -11 +11 @@
-#  --emit-workflow-only
+#  --emit-workflow'

@test "tokens(#2004): backticked spans, flags and quoted identifiers are extracted" {
  _tokens "$_1977_FINDING"
  [ "$status" -eq 0 ]
  grep -qxF -- '--emit-workflow-only' <<< "$output"
  ! grep -qxF -- 'scripts/template_stub_drift.sh' <<< "$output"  # path-like spans are generic (#2004 rule 3a)
  grep -qxF -- '--emit-workflow' <<< "$output"
}

@test "tokens(#2004): HTML comments and fenced code blocks are ignored; short spans dropped" {
  _tokens 'See `x` and <!-- `hidden_token` --> here.
```suggestion
`fenced_token`
```
Also `real_token`.'
  [ "$status" -eq 0 ]
  [ "$output" = "real_token" ]
}

@test "tokens(#2004): a finding with no distinctive token yields nothing" {
  _tokens "Please double-check the null path."
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tokens(#2004): an apostrophe in prose is not a quoted identifier" {
  _tokens "It's fine, but don't skip it."
  [ -z "$output" ]
}

@test "diff verdict(#2004): the INTRODUCING diff (adds the token) is content-adds-token" {
  _diff_verdict "$_1977_INTRODUCING" "$(bash -c "source '$LIB'; cdv_finding_tokens \"\$1\"" _ "$_1977_FINDING")"
  [ "$status" -eq 1 ]
  [ "$output" = "content-adds-token" ]
}

@test "diff verdict(#2004): the FIXING diff (removes the token) is content-removes-token" {
  _diff_verdict "$_1977_FIXING" "$(bash -c "source '$LIB'; cdv_finding_tokens \"\$1\"" _ "$_1977_FINDING")"
  [ "$status" -eq 0 ]
  [ "$output" = "content-removes-token" ]
  run bash -c "source '$LIB'; cdv_removed_token \"\$1\" \"\$2\"" _ "$_1977_FIXING" "--emit-workflow-only"
  [ "$status" -eq 0 ]
  [ "$output" = "--emit-workflow-only" ]
}

@test "diff verdict(#2004): an UNRELATED diff is content-no-token-removed" {
  _diff_verdict 'diff --git a/other.txt b/other.txt
--- a/other.txt
+++ b/other.txt
@@ -1 +1 @@
-hello
+world' $'--emit-workflow-only\nscripts/template_stub_drift.sh'
  [ "$status" -eq 1 ]
  [ "$output" = "content-no-token-removed" ]
}

@test "diff verdict(#2004): a token removed on one line and re-added on another does not count" {
  _diff_verdict '--- a/f
+++ b/f
@@ -1 +1 @@
-run --emit-workflow-only now
+run --emit-workflow-only later' "--emit-workflow-only"
  [ "$status" -eq 1 ]
  [ "$output" = "content-adds-token" ]
}

@test "diff verdict(#2004): file headers never count as removed or added lines" {
  _diff_verdict '--- a/scripts/template_stub_drift.sh
+++ b/scripts/template_stub_drift.sh
@@ -1 +1 @@
-a
+b' "scripts/template_stub_drift.sh"
  [ "$status" -eq 1 ]
  [ "$output" = "content-no-token-removed" ]
}

@test "diff verdict(#2004): no tokens → no-tokens" {
  _diff_verdict "$_1977_FIXING" ""
  [ "$status" -eq 1 ]
  [ "$output" = "no-tokens" ]
}

@test "fixed verdict(#2004): a content-verified ancestor commit after the finding verifies" {
  _fixed_verdict true false 1 "2026-10-02T12:00:00Z" "2026-10-02T10:00:00Z" content-removes-token
  [ "$status" -eq 0 ]
  [ "$output" = "content-removes-token" ]
}

@test "fixed verdict(#2004): no token fails closed unless the commit is from this pass" {
  _fixed_verdict true false 1 "2026-10-02T12:00:00Z" "2026-10-02T10:00:00Z" no-tokens
  [ "$status" -eq 1 ]
  [ "$output" = "tokenless-not-this-pass" ]
  _fixed_verdict true false 1 "2026-10-02T12:00:00Z" "2026-10-02T10:00:00Z" no-tokens false
  [ "$status" -eq 1 ]
  [ "$output" = "tokenless-not-this-pass" ]
  _fixed_verdict true false 1 "2026-10-02T12:00:00Z" "2026-10-02T10:00:00Z" no-tokens true
  [ "$status" -eq 0 ]
  [ "$output" = "tokenless-this-pass" ]
}

@test "finding tokens(#2004): generic spans (local, true, numbers, paths) are not tokens" {
  _tokens 'Drop `local` here, and `true`, `42`, `scripts/foo.sh`, `return`.'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  _tokens 'The `local` keyword and `my_helper` call.'
  [ "$output" = "my_helper" ]
}

@test "diff verdict(#2004): a local-only finding is tokenless, so deleting a local line does not verify" {
  tokens=$(bash -c "source '$LIB'; cdv_finding_tokens \"\$1\"" _ 'Remove `local` here.')
  [ -z "$tokens" ]
  run bash -c "source '$LIB'; cdv_diff_token_verdict \"\$1\" \"\$2\"" _ $'-  local x=1' "$tokens"
  [ "$status" -eq 1 ]
  [ "$output" = "no-tokens" ]
}

@test "fixed verdict(#2004): each failure has its own reason token" {
  _fixed_verdict false false 1 "2026-10-02T12:00:00Z" "2026-10-02T10:00:00Z" content-removes-token
  [ "$status" -eq 1 ]; [ "$output" = "not-on-head" ]
  _fixed_verdict true unknown 1 "2026-10-02T12:00:00Z" "2026-10-02T10:00:00Z" content-removes-token
  [ "$status" -eq 1 ]; [ "$output" = "base-unknown" ]
  _fixed_verdict true true 1 "2026-10-02T12:00:00Z" "2026-10-02T10:00:00Z" content-removes-token
  [ "$status" -eq 1 ]; [ "$output" = "on-base-branch" ]
  _fixed_verdict true false 0 "2026-10-02T12:00:00Z" "2026-10-02T10:00:00Z" content-removes-token
  [ "$status" -eq 1 ]; [ "$output" = "empty-diff" ]
  _fixed_verdict true false 1 "2026-10-02T12:00:00Z" "2026-10-02T10:00:00Z" content-adds-token
  [ "$status" -eq 1 ]; [ "$output" = "content-adds-token" ]
  _fixed_verdict true false 1 "2026-10-02T12:00:00Z" "2026-10-02T10:00:00Z" content-no-token-removed
  [ "$status" -eq 1 ]; [ "$output" = "content-no-token-removed" ]
  _fixed_verdict true false 1 "" "2026-10-02T10:00:00Z" content-removes-token
  [ "$status" -eq 1 ]; [ "$output" = "undated" ]
  _fixed_verdict true false 1 "2026-10-02T09:00:00Z" "2026-10-02T10:00:00Z" content-removes-token
  [ "$status" -eq 1 ]; [ "$output" = "predates-finding" ]
}

@test "fixed verdict(#2004): a tokenless this-pass commit that predates the finding fails" {
  _fixed_verdict true false 1 "2026-10-02T09:00:00Z" "2026-10-02T10:00:00Z" no-tokens true
  [ "$status" -eq 1 ]
  [ "$output" = "predates-finding" ]
}

@test "fixed verdict(#2004): an unknown content verdict fails closed" {
  _fixed_verdict true false 1 "2026-10-02T12:00:00Z" "2026-10-02T10:00:00Z" ""
  [ "$status" -eq 1 ]
  [ "$output" = "content-unknown" ]
}

@test "diff verdict(#2051): token match is whole-token, not substring" {
  local d=$'--- a/x\n+++ b/x\n@@ -1 +0,0 @@\n-run --emit-workflow-only now'
  run bash -c "source '$LIB'; cdv_removed_token \"\$1\" \"\$2\"" _ "$d" "--emit-workflow"
  [ "$status" -eq 1 ]
  run bash -c "source '$LIB'; cdv_removed_token \"\$1\" \"\$2\"" _ "$d" "--emit-workflow-only"
  [ "$status" -eq 0 ]
}

@test "diff verdict(#2051): incidental token removal in unrelated change" {
  # Finding with multiple distinct tokens extracted from different issues
  # An unrelated change that incidentally removes one token but leaves the core issue
  local tokens=$'emit_only\nmanifest_ref'
  # Example: diff changes a comment that mentions both tokens, but the change is unrelated
  local d=$'--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n- # Use emit_only and manifest_ref carefully\n+ # Fixed for manifest_ref only\n  other code'
  _diff_verdict "$d" "$tokens"
  # Current implementation accepts if any token appears on a removed line
  # (emit_only is removed, even though the change is not a real fix)
  [ "$status" -eq 0 ]
  [ "$output" = "content-removes-token" ]
}

@test "#2051: a token at column 0 of a removed line is matched (diff marker stripped)" {
  local d=$'--- a/x.md\n+++ b/x.md\n@@ -1,2 +1,1 @@\n---emit-gone usage\n keep'
  run bash -c "source '$LIB'; cdv_removed_token \"\$1\" \"\$2\"" _ "$d" "--emit-gone"
  [ "$status" -eq 0 ]
  [ "$output" = "--emit-gone" ]
}

# ── #2152: the lib dir must survive the caller's cd into the PR worktree ──────

@test "#2152: cdv_body_has_findings is cwd-independent when sourced by a relative path" {
  # dev-lead-fix-reviews.sh runs as `bash .dev-lead/scripts/...` and cds into the
  # PR worktree before this is called. A no-finding notice must still read as
  # no-finding (1); resolving the lib dir at call time failed closed to 0.
  local root="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$root/.dev-lead" "$root/pr-worktree"
  ln -s "$SCRIPT_DIR" "$root/.dev-lead/scripts"
  local notice="> [!NOTE] > Gemini is unable to generate a review for this pull request due to the file types involved not being currently supported."
  run bash -c "cd '$root' && source .dev-lead/scripts/lib/comment-disposition-verify.sh && cd pr-worktree && cdv_body_has_findings \"\$1\"" _ "$notice"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "#2152: a finding-bearing body still reads as finding-bearing after the cd" {
  local root="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$root/.dev-lead" "$root/pr-worktree"
  ln -s "$SCRIPT_DIR" "$root/.dev-lead/scripts"
  run bash -c "cd '$root' && source .dev-lead/scripts/lib/comment-disposition-verify.sh && cd pr-worktree && cdv_body_has_findings '**Actionable comments posted: 2**'"
  [ "$status" -eq 0 ]
}
