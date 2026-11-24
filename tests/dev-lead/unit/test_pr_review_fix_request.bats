#!/usr/bin/env bats
# Unit tests for scripts/lib/pr-review-fix-request.sh and the fix-reviews arm that
# hands its selection to the prompt (#2168).
#
# pr-review posts a fix request as a PR issue comment, not a review thread, so the
# fix-reviews pass never saw it. The harness now selects the newest trusted one at
# the PR's live head and passes it to the prompt as findings to check.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
FIX_REVIEWS_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-fix-reviews.sh"
LIB="$SCRIPT_DIR/scripts/lib/pr-review-fix-request.sh"
PROMPT="$SCRIPT_DIR/prompts/dev-lead/fix-reviews.md"

HEAD40="0940901d0940901d0940901d0940901d0940901d"
OLD40="53478e6d53478e6d53478e6d53478e6d53478e6d"
FINDING="FINDING_TEXT_feature-ideation_uses_echo_none"
REJECTED="REJECTED_TEXT_must_not_reach_prompt"

setup() {
  STUB_BIN_DIR="$(mktemp -d)"
  export STUB_BIN_DIR
  # The persona manifest resolves pr-review's login; pin it so a test never depends
  # on the checked-in manifest's value.
  export PR_REVIEW_USER="donpetry-bot"
  # BOT_USER is dev-lead's own login; the selection must never use it.
  export BOT_USER="don-petry"
}

teardown() {
  rm -rf "$STUB_BIN_DIR"
}

# _body <sha> <decision> [finding]: a fix-request body as post-pr-review.sh writes it.
_body() {
  printf '<!-- pr-review-agent v1 sha=%s --> <!-- decision=%s risk=MEDIUM -->\n\n## Review — fix requested (cycle 2/3)\n\n### Findings to fix\n%s\n' \
    "$1" "$2" "${3:-$FINDING}"
}

# _node <id> <login> <body> [createdAt] [lastEditedAt|null] [isMinimized]
_node() {
  jq -nc --arg id "$1" --arg l "$2" --arg b "$3" --arg c "${4:-2026-11-22T10:00:00Z}" \
    --arg e "${5:-null}" --argjson m "${6:-false}" '
    {id:$id, author:{login:$l, __typename:"User"}, authorAssociation:"CONTRIBUTOR",
     body:$b, createdAt:$c, lastEditedAt:(if $e == "null" then null else $e end),
     isMinimized:$m, minimizedReason:(if $m then "RESOLVED" else null end)}'
}

# _select <nodes-json>: the selected comment's id ("" when none).
_select() {
  run bash -c "
    source '$LIB'
    prfr_select_fix_request \"\$1\" donpetry-bot '$HEAD40' | jq -r '.id // empty'
  " _ "$1"
}

@test "prfr(#2168): the bot's fix request at the live head is selected" {
  _select "[$(_node IC_sel donpetry-bot "$(_body "$HEAD40" fix-requested)")]"
  [ "$status" -eq 0 ]
  [ "$output" = "IC_sel" ]
}

@test "prfr(#2168): another login with a byte-identical body is not selected" {
  local l
  for l in don-petry coderabbitai someone; do
    _select "[$(_node IC_x "$l" "$(_body "$HEAD40" fix-requested)")]"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "prfr(#2168): a login that merely contains the bot's login is not selected" {
  local l
  for l in donpetry-bot2 xdonpetry-bot "donpetry-bot[bot]" DonPetry-Bot; do
    _select "[$(_node IC_x "$l" "$(_body "$HEAD40" fix-requested)")]"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "prfr(#2168): a stale sha is not selected" {
  _select "[$(_node IC_x donpetry-bot "$(_body "$OLD40" fix-requested)")]"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prfr(#2168): a short sha prefix of the live head is not selected" {
  _select "[$(_node IC_x donpetry-bot "$(_body "${HEAD40:0:12}" fix-requested)")]"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prfr(#2168): a marker quoted mid-body is not selected" {
  _select "[$(_node IC_x donpetry-bot "Quoting the earlier request:
$(_body "$HEAD40" fix-requested)")]"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prfr(#2168): a superseded body is not selected" {
  _select "[$(_node IC_x donpetry-bot "<!-- pr-review-agent superseded -->
<details><summary>Superseded</summary>

$(_body "$HEAD40" fix-requested)
</details>")]"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prfr(#2168): an edited comment is not selected" {
  _select "[$(_node IC_x donpetry-bot "$(_body "$HEAD40" fix-requested)" 2026-11-22T10:00:00Z 2026-11-22T10:05:00Z)]"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prfr(#2168): a minimized comment is not selected" {
  _select "[$(_node IC_x donpetry-bot "$(_body "$HEAD40" fix-requested)" 2026-11-22T10:00:00Z null true)]"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prfr(#2168): decision=approved is not selected" {
  _select "[$(_node IC_x donpetry-bot "$(_body "$HEAD40" approved)")]"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prfr(#2168): the newest of two fix requests wins, whatever the list order" {
  local a b
  a=$(_node IC_old donpetry-bot "$(_body "$HEAD40" fix-requested old)" 2026-11-22T09:00:00Z)
  b=$(_node IC_new donpetry-bot "$(_body "$HEAD40" fix-requested new)" 2026-11-22T11:00:00Z)
  _select "[$a,$b]"
  [ "$output" = "IC_new" ]
  _select "[$b,$a]"
  [ "$output" = "IC_new" ]
}

@test "prfr(#2168): an empty live head selects nothing" {
  run bash -c "
    source '$LIB'
    prfr_select_fix_request \"\$1\" donpetry-bot '' | jq -r '.id // empty'
  " _ "[$(_node IC_sel donpetry-bot "$(_body "" fix-requested)")]"
  [ -z "$output" ]
}

@test "prfr(#2168): pr-review's login honours PR_REVIEW_USER and is never BOT_USER" {
  run bash -c "source '$LIB'; PR_REVIEW_USER=custom-review BOT_USER=don-petry prfr_pr_review_login '$SCRIPT_DIR/scripts'"
  [ "$output" = "custom-review" ]
  run bash -c "source '$LIB'; unset PR_REVIEW_USER; BOT_USER=don-petry prfr_pr_review_login '$STUB_BIN_DIR/nowhere'"
  [ "$output" = "donpetry-bot" ]
}

# ── the fix-reviews arm: export_pr_review_fix_request + prompt ────────────────

# _export_env <comments-json|FAIL> <live-head|FAIL>: run export_pr_review_fix_request
# against a gh stub and print PR_REVIEW_FIX_REQUEST.
_export_env() {
  export PRFR_COMMENTS="$1" PRFR_HEAD="$2"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *graphql*)
    [ "$PRFR_COMMENTS" = "FAIL" ] && exit 1
    jq -nc --argjson n "$PRFR_COMMENTS" \
      '{data:{repository:{pullRequest:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$n}}}}}' ;;
  *pulls/*)
    [ "$PRFR_HEAD" = "FAIL" ] && exit 1
    printf '%s\n' "$PRFR_HEAD" ;;
  *) exit 1 ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  run bash -c "
    export PATH='$STUB_BIN_DIR':\"\$PATH\" REPO=o/r PR_NUMBER=54 HEAD_SHA=stale
    AGENT_SCRIPT_DIR='$SCRIPT_DIR/scripts'
    source '$SCRIPT_DIR/scripts/lib/bot-comment-retry.sh'
    source '$LIB'
    source <(sed -n '/^export_pr_review_fix_request()/,/^}/p' '$FIX_REVIEWS_SCRIPT')
    export_pr_review_fix_request >/dev/null 2>&1
    printf '%s' \"\$PR_REVIEW_FIX_REQUEST\"
  "
}

# _render <PR_REVIEW_FIX_REQUEST value>: the fix-reviews prompt as build_and_run
# renders it (envsubst scoped to the declared variables).
_render() {
  local vars
  vars=$(head -1 "$PROMPT" | sed 's/<!-- VARIABLES: //; s/ -->//' \
    | tr ',' '\n' | awk '{gsub(/^ +| +$/, ""); if (length) printf "${%s}", $0}')
  REPO=o/r PR_REVIEW_FIX_REQUEST="$1" envsubst "$vars" < "$PROMPT"
}

@test "fix-reviews(#2168): the prompt declares PR_REVIEW_FIX_REQUEST and renders it" {
  head -1 "$PROMPT" | grep -q 'PR_REVIEW_FIX_REQUEST'
  local out
  out=$(_render "SENTINEL_FIX_REQUEST")
  [[ "$out" == *"SENTINEL_FIX_REQUEST"* ]]
  [[ "$out" != *'${PR_REVIEW_FIX_REQUEST}'* ]]
}

@test "fix-reviews(#2168): the fix-reviews arm computes the fix request before the model runs" {
  local block
  block="$(sed -n '/^  fix-reviews)$/,/build_and_run "fix-reviews"/p' "$FIX_REVIEWS_SCRIPT")"
  [[ "$block" == *"export_pr_review_fix_request"* ]]
}

@test "fix-reviews(#2168): the selected finding reaches the rendered prompt; the rejected comment does not" {
  local sel rej
  sel=$(_node IC_sel donpetry-bot "$(_body "$HEAD40" fix-requested)" 2026-11-22T09:00:00Z)
  rej=$(_node IC_rej don-petry "$(_body "$HEAD40" fix-requested "$REJECTED")" 2026-11-22T11:00:00Z)
  _export_env "[$sel,$rej]" "$HEAD40"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$FINDING"* ]]
  [[ "$output" != *"$REJECTED"* ]]
  local out
  out=$(_render "$output")
  [[ "$out" == *"$FINDING"* ]]
  [[ "$out" != *"$REJECTED"* ]]
}

@test "fix-reviews(#2168): the live head is read from the API, not the dispatch's HEAD_SHA" {
  # HEAD_SHA=stale in _export_env; a request at the live head is still selected.
  _export_env "[$(_node IC_sel donpetry-bot "$(_body "$HEAD40" fix-requested)")]" "$HEAD40"
  [[ "$output" == *"$FINDING"* ]]
  # A request at the old head is not, even though the live head moved past it.
  _export_env "[$(_node IC_sel donpetry-bot "$(_body "$OLD40" fix-requested)")]" "$HEAD40"
  [[ "$output" == "None."* ]]
}

@test "fix-reviews(#2168): nothing selected renders an explicit None" {
  _export_env "[$(_node IC_x don-petry "$(_body "$HEAD40" fix-requested)")]" "$HEAD40"
  [ "$status" -eq 0 ]
  [[ "$output" == "None."* ]]
  [[ "$output" != *"$FINDING"* ]]
}

@test "fix-reviews(#2168): a body with triple backticks and \${REPO} stays inert JSON" {
  local nasty
  # shellcheck disable=SC2016  # literal ${REPO} is the point of the test
  nasty='```
end fence ${REPO} $(touch "$HOME/pwned") "quoted"
```'
  _export_env "[$(_node IC_sel donpetry-bot "$(_body "$HEAD40" fix-requested "$nasty")")]" "$HEAD40"
  [ "$status" -eq 0 ]
  # The body is one JSON string: no raw fence or raw newline escapes the encoding.
  [[ "$output" != *'```'$'\n'* ]]
  [[ "$output" == *'```\nend fence ${REPO}'* ]]
  local json
  json=$(printf '%s\n' "$output" | grep -m1 '^"')
  [ "$(jq -r 'type' <<< "$json")" = "string" ]
  [[ "$(jq -r '.' <<< "$json")" == *'end fence ${REPO} $(touch "$HOME/pwned")'* ]]
  # Rendering does not expand the ${REPO} inside the body.
  local out
  out=$(_render "$output")
  [[ "$out" == *'end fence ${REPO}'* ]]
}

@test "fix-reviews(#2168): an oversized body is capped at 30,000 characters" {
  local big
  big=$(head -c 40000 /dev/zero | tr '\0' 'a')
  _export_env "[$(_node IC_sel donpetry-bot "$(_body "$HEAD40" fix-requested "$big")")]" "$HEAD40"
  [ "$status" -eq 0 ]
  local json
  json=$(printf '%s\n' "$output" | grep -m1 '^"')
  [ "$(jq -r 'length' <<< "$json")" -le 30000 ]
  [[ "$output" == *"truncated"* ]]
  [[ "$output" != *"Read the rest"* ]]
}

@test "fix-reviews(#2168): an unreadable comment list gives could-not-be-determined, never None" {
  _export_env FAIL "$HEAD40"
  [ "$status" -eq 0 ]
  [[ "$output" == "Could not be determined"* ]]
  [[ "$output" != *"None."* ]]
}

@test "fix-reviews(#2168): an unreadable or malformed live head gives could-not-be-determined" {
  local nodes
  nodes="[$(_node IC_sel donpetry-bot "$(_body "$HEAD40" fix-requested)")]"
  _export_env "$nodes" FAIL
  [[ "$output" == "Could not be determined"* ]]
  [[ "$output" != *"$FINDING"* ]]
  _export_env "$nodes" "null"
  [[ "$output" == "Could not be determined"* ]]
}

@test "fix-reviews(#2168): a malformed login makes the selector fail (so the wrapper reports could-not-be-determined)" {
  run bash -c "source '$LIB'; prfr_select_fix_request '[]' 'bad login!' '$HEAD40'"
  [ "$status" -ne 0 ]
}

@test "prfr(#2168): a marker pair with no space between the markers is not selected" {
  body="<!-- pr-review-agent v1 sha=$HEAD40 --><!-- decision=fix-requested risk=MEDIUM -->
$FINDING"
  _select "[$(_node IC_nospace donpetry-bot "$body")]"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prfr(#2168): a marker pair with two spaces between the markers is not selected" {
  body="<!-- pr-review-agent v1 sha=$HEAD40 -->  <!-- decision=fix-requested risk=MEDIUM -->
$FINDING"
  _select "[$(_node IC_twospace donpetry-bot "$body")]"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prfr(#2168): a marker pair split by a newline is not selected" {
  body="<!-- pr-review-agent v1 sha=$HEAD40 -->
<!-- decision=fix-requested risk=MEDIUM -->
$FINDING"
  _select "[$(_node IC_newline donpetry-bot "$body")]"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prfr(#2168): risk value run into meta= with no space is not selected" {
  body="<!-- pr-review-agent v1 sha=$HEAD40 --> <!-- decision=fix-requested risk=MEDIUMmeta=0123456789abcdef -->
$FINDING"
  _select "[$(_node IC_nometasp donpetry-bot "$body")]"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prfr(#2168): producer contract — the marker line post-pr-review.sh writes is selected" {
  line=$(grep -F 'decision=fix-requested risk=$RISK$META_ATTR' "$SCRIPT_DIR/scripts/post-pr-review.sh" | head -n1)
  [ -n "$line" ]
  for meta in "" " meta=0123456789abcdef"; do
    l="${line//\$PR_HEAD_SHA/$HEAD40}"
    l="${l//\$RISK/HIGH}"
    l="${l//\$META_ATTR/$meta}"
    _select "[$(_node IC_prod donpetry-bot "$l"$'\n\n'"$FINDING")]"
    [ "$status" -eq 0 ]
    [ "$output" = "IC_prod" ]
  done
}
