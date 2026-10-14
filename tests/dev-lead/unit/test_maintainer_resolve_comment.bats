#!/usr/bin/env bats
# Tests for maintainer-resolve-comment.sh (issue #1910, epic #1894 AC #4).
#
# AC #4 gap: the ONLY thing that ever minimizes an undispositioned PR issue
# comment RESOLVED is dev-lead. On a PR where dev-lead is suppressed,
# rate-limited, cancelled, or never dispatched, a maintainer's own comment stays
# undispositioned forever and no approval can stand (maintainer-comment-gate.sh
# blocks). This script gives a maintainer a dev-lead-INDEPENDENT path to satisfy
# that gate against THEIR OWN comment: minimize it with GraphQL minimizeComment
# classifier RESOLVED — the exact signal the gate already honours. It must NOT
# weaken the RESOLVED-minimized requirement, and must only ever act on the
# invoking user's own comment (fail closed otherwise).

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/../../../scripts"
  MRC="$SCRIPT_DIR/maintainer-resolve-comment.sh"
  GATE="$SCRIPT_DIR/lib/maintainer-comment-gate.sh"
}

teardown() {
  unset SCRIPT_DIR
}

# ────────────────────────────────────────────────────────────────────
# STRUCTURAL TESTS
# ────────────────────────────────────────────────────────────────────

@test "MRC: script exists and is executable" {
  [ -x "$MRC" ]
}

@test "MRC: script has correct shebang" {
  head -1 "$MRC" | grep -q "^#!/usr/bin/env bash"
}

@test "MRC: script uses set -euo pipefail" {
  grep -q "^set -euo pipefail" "$MRC"
}

@test "MRC: BASH_SOURCE guard prevents source-time execution of main" {
  grep -q 'if \[\[ "${BASH_SOURCE\[0\]}" = "${0}" \]\]' "$MRC"
}

@test "MRC: shellcheck passes" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  shellcheck --shell=bash --severity=warning "$MRC"
}

# AC #2 — the maintainer path is documented via --help.
@test "AC2: --help documents the RESOLVED-minimize requirement" {
  run bash "$MRC" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "RESOLVED"
  echo "$output" | grep -qi "minimiz"
  echo "$output" | grep -qi "own comment"
}

# ────────────────────────────────────────────────────────────────────
# PURE-HELPER TESTS
# ────────────────────────────────────────────────────────────────────

# AC #2 — the requirement is not weakened: the mutation hardcodes classifier RESOLVED.
@test "AC2: minimize mutation uses classifier RESOLVED and nothing else" {
  run bash -c "source '$MRC'; mrc_minimize_mutation"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "minimizeComment"
  echo "$output" | grep -q "classifier:RESOLVED"
  # It must NOT offer any weaker classifier (OUTDATED, RESOLVED must be the only one).
  ! echo "$output" | grep -q "OUTDATED"
}

@test "ref-kind: a node id (IC_...) is recognised as a node ref" {
  run bash -c "source '$MRC'; mrc_ref_kind 'IC_kwDOAbc123'"
  [ "$status" -eq 0 ]
  [ "$output" = "node" ]
}

@test "ref-kind: a PR comment URL is recognised as a url ref" {
  run bash -c "source '$MRC'; mrc_ref_kind 'https://github.com/petry-projects/.github-private/pull/42#issuecomment-999'"
  [ "$status" -eq 0 ]
  [ "$output" = "url" ]
}

@test "ref-kind: garbage input is invalid (fail closed)" {
  run bash -c "source '$MRC'; mrc_ref_kind 'not-a-ref'"
  [ "$status" -eq 1 ]
}

# PR-only: a bare /issues/ comment URL must NOT be accepted — this path may only
# target a pull-request comment (#1910 self-scope hardening).
@test "ref-kind: a non-PR /issues/ comment URL is rejected (fail closed)" {
  run bash -c "source '$MRC'; mrc_ref_kind 'https://github.com/petry-projects/.github-private/issues/42#issuecomment-999'"
  [ "$status" -eq 1 ]
}

@test "url-parse: PR number extracted from a /pull/ comment URL" {
  run bash -c "source '$MRC'; mrc_pr_number_from_url 'https://github.com/o/r/pull/1234#issuecomment-987654'"
  [ "$status" -eq 0 ]
  [ "$output" = "1234" ]
}

@test "url-parse: PR number extraction rejects a non-PR /issues/ URL (fail closed)" {
  run bash -c "source '$MRC'; mrc_pr_number_from_url 'https://github.com/o/r/issues/1234#issuecomment-987654'"
  [ "$status" -eq 1 ]
}

@test "url-parse: database id extracted from #issuecomment anchor" {
  run bash -c "source '$MRC'; mrc_comment_dbid_from_url 'https://github.com/o/r/pull/42#issuecomment-987654'"
  [ "$status" -eq 0 ]
  [ "$output" = "987654" ]
}

@test "url-parse: owner/repo extracted from URL" {
  run bash -c "source '$MRC'; mrc_repo_from_url 'https://github.com/petry-projects/.github-private/pull/42#issuecomment-1'"
  [ "$status" -eq 0 ]
  [ "$output" = "petry-projects/.github-private" ]
}

# AC #1 / self-scope — only the invoking user's OWN comment may be resolved here.
@test "authz: invoking user resolving their own comment is authorized" {
  run bash -c "source '$MRC'; mrc_authorize_self 'a-maintainer' 'a-maintainer'"
  [ "$status" -eq 0 ]
}

@test "authz: resolving someone else's comment is rejected (fail closed)" {
  run bash -c "source '$MRC'; mrc_authorize_self 'a-maintainer' 'someone-else'"
  [ "$status" -eq 1 ]
}

@test "authz: empty author or empty viewer is rejected (fail closed)" {
  run bash -c "source '$MRC'; mrc_authorize_self '' 'a-maintainer'"
  [ "$status" -eq 1 ]
  run bash -c "source '$MRC'; mrc_authorize_self 'a-maintainer' ''"
  [ "$status" -eq 1 ]
}

# ────────────────────────────────────────────────────────────────────
# #1918 — maintainer path for a REGISTERED REVIEWER BOT's comment
# ────────────────────────────────────────────────────────────────────

# --help now documents the bot-comment escape hatch and the required --reason.
@test "AC3: --help documents the registered-bot path and the --reason requirement" {
  run bash "$MRC" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "reviewer bot"
  echo "$output" | grep -q -- "--reason"
}

@test "AC3: normalize strips a trailing [bot] suffix" {
  run bash -c "source '$MRC'; mrc_normalize_login 'sonarqubecloud[bot]'"
  [ "$status" -eq 0 ]
  [ "$output" = "sonarqubecloud" ]
  run bash -c "source '$MRC'; mrc_normalize_login 'sonarqubecloud'"
  [ "$output" = "sonarqubecloud" ]
}

@test "AC3: a registered reviewer bot author is recognised (with or without [bot])" {
  local reg=$'sonarqubecloud\ncodeant-ai\ngraphite-app'
  run bash -c "source '$MRC'; mrc_is_registered_bot 'sonarqubecloud[bot]' \"\$1\"" _ "$reg"
  [ "$status" -eq 0 ]
  run bash -c "source '$MRC'; mrc_is_registered_bot 'sonarqubecloud' \"\$1\"" _ "$reg"
  [ "$status" -eq 0 ]
}

# A human (not in the registry) is refused — this is the #1910 restriction that
# keeps another person's finding out of this path.
@test "AC3: a human author (not in the registry) is refused" {
  local reg=$'sonarqubecloud\ncodeant-ai'
  run bash -c "source '$MRC'; mrc_is_registered_bot 'a-maintainer' \"\$1\"" _ "$reg"
  [ "$status" -eq 1 ]
}

@test "AC3: an empty author is refused (fail closed)" {
  local reg=$'sonarqubecloud'
  run bash -c "source '$MRC'; mrc_is_registered_bot '' \"\$1\"" _ "$reg"
  [ "$status" -eq 1 ]
}

# --reason is mandatory for the bot path (posted as a reply before minimizing).
@test "AC3: reason validation requires a non-empty reason" {
  run bash -c "source '$MRC'; mrc_reason_ok 'quality gate passed on head'"
  [ "$status" -eq 0 ]
  run bash -c "source '$MRC'; mrc_reason_ok ''"
  [ "$status" -eq 1 ]
  run bash -c "source '$MRC'; mrc_reason_ok '   '"
  [ "$status" -eq 1 ]
}

# The reply carries the loop-safe marker + the author + reason, so the gate treats
# it as one of our own comments (not a new blocker).
@test "AC3: reply body carries the maintainer-resolve marker, author, and reason" {
  run bash -c "source '$MRC'; mrc_build_reply_body 'sonarqubecloud' 'a-maintainer' 'quality gate passed'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "<!-- maintainer-resolve"
  echo "$output" | grep -q "sonarqubecloud"
  echo "$output" | grep -q "quality gate passed"
}

# Round-trip: the reply the bot path posts is IGNORED by the maintainer-comment
# gate (it must not become a fresh undispositioned blocker).
@test "AC3: the reply body the script posts is ignored by the gate → 0" {
  local body reply json
  body="$(bash -c "source '$MRC'; mrc_build_reply_body 'sonarqubecloud' 'a-maintainer' 'quality gate passed'")"
  # Encode the reply body as a JSON string value for the snapshot.
  reply="$(printf '%s' "$body" | jq -Rs .)"
  json='{"comments":[{"author":{"login":"a-maintainer"},"body":'"$reply"',"isMinimized":false,"minimizedReason":""}]}'
  run bash -c "source '$GATE'; check_maintainer_comments \"\$1\" donpetry-bot" _ "$json"
  [ "$status" -eq 0 ]
}

# Idempotency — an already-RESOLVED-minimized comment needs no action.
@test "idempotency: already-RESOLVED-minimized comment is detected" {
  run bash -c "source '$MRC'; mrc_is_resolved_minimized 'true' 'resolved'"
  [ "$status" -eq 0 ]
  run bash -c "source '$MRC'; mrc_is_resolved_minimized 'true' 'RESOLVED'"
  [ "$status" -eq 0 ]
}

@test "idempotency: a non-minimized or non-RESOLVED comment is not treated as resolved" {
  run bash -c "source '$MRC'; mrc_is_resolved_minimized 'false' ''"
  [ "$status" -eq 1 ]
  run bash -c "source '$MRC'; mrc_is_resolved_minimized 'true' 'outdated'"
  [ "$status" -eq 1 ]
}

# ────────────────────────────────────────────────────────────────────
# ROUND-TRIP: the signal this script produces is EXACTLY what the gate honours
# ────────────────────────────────────────────────────────────────────

# The minimizedReason fed to the gate here is DERIVED from the classifier the
# script's own mutation carries (mrc_minimize_mutation), not handcrafted — so if
# that classifier is ever softened (e.g. RESOLVED → OUTDATED), this JSON follows
# and the gate stops clearing, breaking the round-trip. This is what genuinely
# ties "the signal this script produces" to "what the gate honours".
_mrc_minimized_reason() {
  # GraphQL enum surfaces as lowercase in the read shape the gate consumes.
  source "$MRC"
  mrc_minimize_mutation | grep -oE 'classifier:[A-Za-z]+' | cut -d: -f2 | tr '[:upper:]' '[:lower:]'
}

# A comment this script has resolved (minimized with the mutation's classifier)
# must clear the maintainer-comment gate — proving the maintainer path satisfies
# the gate without dev-lead executing, and does not invent a new/weaker signal.
@test "round-trip: a maintainer comment minimized with the mutation's classifier clears the gate" {
  local reason json
  reason="$(_mrc_minimized_reason)"
  [ "$reason" = "resolved" ]
  json='{"comments":[{"author":{"login":"a-maintainer"},"body":"Please double-check the null path.","isMinimized":true,"minimizedReason":"'"$reason"'"}]}'
  run bash -c "source '$GATE'; check_maintainer_comments \"\$1\" donpetry-bot" _ "$json"
  [ "$status" -eq 0 ]
}

# Control: before this script runs, the same comment (not minimized) blocks —
# so the RESOLVED-minimize is what flips the verdict, nothing else.
@test "round-trip: the same comment un-minimized still blocks the gate" {
  local json='{"comments":[{"author":{"login":"a-maintainer"},"body":"Please double-check the null path.","isMinimized":false,"minimizedReason":""}]}'
  run bash -c "source '$GATE'; check_maintainer_comments \"\$1\" donpetry-bot" _ "$json"
  [ "$status" -eq 1 ]
}

# ────────────────────────────────────────────────────────────────────
# ENTRYPOINT (main) — no-network fail-closed paths
# ────────────────────────────────────────────────────────────────────

@test "main: no argument prints usage and exits 2" {
  run bash "$MRC"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qi "usage"
}

@test "main: an unrecognised comment reference fails closed (exit 2, no minimize)" {
  run bash "$MRC" "totally-not-a-comment-ref"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qi "unrecognised comment reference"
}

# #1918 review: the registered-bot path must require a GitHub App actor. A PERSON
# whose login happens to equal a registered bot login (e.g. a user account named
# `sonarqubecloud`) must be refused like any other human — never minimized.
# A SonarCloud clean-status body that matches its registered info_status_pattern.
SONAR_PASS_JSON_BODY='**Quality Gate passed**\n[0 New issues]\n[0 Security Hotspots]'

_mrc_fake_gh() {
  # $1 = author __typename, $2 = author login (default sonarqubecloud), $3 = the
  # comment body as a JSON string fragment (default a matching SonarCloud clean
  # status). Writes a `gh` shim on PATH that answers the one GraphQL read and
  # records any other call (a minimize or reply would be a failure).
  local login="${2:-sonarqubecloud}" body="${3:-$SONAR_PASS_JSON_BODY}"
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<SHIM
#!/usr/bin/env bash
if [[ "\$*" == *"viewer{login}"* ]]; then
  printf '%s' '{"data":{"viewer":{"login":"don-petry"},"node":{"author":{"__typename":"$1","login":"$login"},"body":"$body","isMinimized":false,"minimizedReason":null,"url":"https://github.com/o/r/pull/1#issuecomment-1"}}}'
  exit 0
fi
echo "\$*" >> "$BATS_TEST_TMPDIR/gh-writes.log"
printf '%s' '{"data":{}}'
SHIM
  chmod +x "$bin/gh"
  export PATH="$bin:$PATH"
}

@test "AC3: a USER account whose login equals a registered bot is refused (exit 3, no write)" {
  _mrc_fake_gh User
  run bash "$MRC" "IC_kwDOfake1" --reason "status only"
  [ "$status" -eq 3 ]
  echo "$output" | grep -qi "refusing to resolve"
  [ ! -s "$BATS_TEST_TMPDIR/gh-writes.log" ]
}

@test "AC3: the same registered login as a Bot actor is authorized for the bot path" {
  _mrc_fake_gh Bot
  run bash "$MRC" "IC_kwDOfake1" --reason "status only"
  # Authorized: it proceeds past authz to the reply + minimize writes.
  [ "$status" -ne 3 ]
  [ -s "$BATS_TEST_TMPDIR/gh-writes.log" ]
}

# #1995 review: registering a bot that ALSO posts findings (Codex, CodeRabbit,
# Qodo) must not let the bot path minimize those findings. The body must match
# the author's info_status_pattern, not just the login.
@test "#1995: a registered bot's FINDING (body does not match its pattern) is refused (exit 3, no write)" {
  _mrc_fake_gh Bot chatgpt-codex-connector '**P1** Possible null dereference in scripts/foo.sh:42 — guard the lookup.'
  run bash "$MRC" "IC_kwDOfake1" --reason "status only"
  [ "$status" -eq 3 ]
  echo "$output" | grep -qi "info_status_pattern"
  [ ! -s "$BATS_TEST_TMPDIR/gh-writes.log" ]
}

@test "#1995: a registered bot's matching NOTICE is still authorized for the bot path" {
  _mrc_fake_gh Bot chatgpt-codex-connector 'You have reached your Codex usage limits for code reviews. You can see your limits in the Codex usage dashboard.'
  run bash "$MRC" "IC_kwDOfake1" --reason "usage-limit notice"
  [ "$status" -ne 3 ]
  [ -s "$BATS_TEST_TMPDIR/gh-writes.log" ]
}

@test "#1995: a SonarCloud 'Quality Gate failed' comment is refused on the bot path" {
  _mrc_fake_gh Bot sonarqubecloud '**Quality Gate failed**\n[3 New issues]'
  run bash "$MRC" "IC_kwDOfake1" --reason "status only"
  [ "$status" -eq 3 ]
  [ ! -s "$BATS_TEST_TMPDIR/gh-writes.log" ]
}

@test "#1995: mrc_bot_body_matches is login-pinned and fails closed" {
  local pats
  pats=$'chatgpt-codex-connector\t^You have reached your Codex usage limits?( for code reviews)?\\.'
  run bash -c "source '$MRC'; mrc_bot_body_matches 'chatgpt-codex-connector[bot]' 'You have reached your Codex usage limit.' \"\$1\"" _ "$pats"
  [ "$status" -eq 0 ]
  run bash -c "source '$MRC'; mrc_bot_body_matches 'someone-else' 'You have reached your Codex usage limit.' \"\$1\"" _ "$pats"
  [ "$status" -ne 0 ]
  run bash -c "source '$MRC'; mrc_bot_body_matches 'chatgpt-codex-connector' '' \"\$1\"" _ "$pats"
  [ "$status" -ne 0 ]
  run bash -c "source '$MRC'; mrc_bot_body_matches 'chatgpt-codex-connector' 'You have reached your Codex usage limit.' ''"
  [ "$status" -ne 0 ]
}

# #1920 review: the reply-idempotency lookup must (a) only accept an existing
# reply the invoking maintainer authored — a forged marker from any other login
# must NOT suppress the audit reply (CWE-345) — and (b) fail closed if the
# comments list cannot be read or parsed, instead of silently reposting.
_mrc_gh_reply_shim() {
  # gh shim: authorizes the bot path (Bot author), serves the paginated
  # issue-comment list from $COMMENTS_JSON (or a hard failure when FAIL_LIST=1),
  # and records reply POSTs and minimize calls in separate logs.
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<SHIM
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"viewer{login}"* ]]; then
  printf '%s' '{"data":{"viewer":{"login":"don-petry"},"node":{"author":{"__typename":"Bot","login":"sonarqubecloud"},"body":"$SONAR_PASS_JSON_BODY","isMinimized":false,"minimizedReason":null,"url":"https://github.com/o/r/pull/1#issuecomment-1"}}}'
  exit 0
fi
if [[ "\$args" == *"minimizeComment"* ]]; then
  echo "min \$args" >> "$BATS_TEST_TMPDIR/gh-min.log"
  printf '%s' '{"data":{"minimizeComment":{"minimizedComment":{"isMinimized":true,"minimizedReason":"RESOLVED"}}}}'
  exit 0
fi
if [[ "\$args" == *"body="* ]]; then
  echo "reply \$args" >> "$BATS_TEST_TMPDIR/gh-reply.log"
  printf '%s' '{"id":123}'
  exit 0
fi
if [[ "\$args" == *"--paginate"* ]]; then
  if [[ "\${FAIL_LIST:-}" == "1" ]]; then echo "list failed" >&2; exit 1; fi
  printf '%s' "\${COMMENTS_JSON:-[]}"
  exit 0
fi
echo "UNEXPECTED \$args" >> "$BATS_TEST_TMPDIR/gh-unexpected.log"
printf '%s' '{"data":{}}'
SHIM
  chmod +x "$bin/gh"
  export PATH="$bin:$PATH"
}

@test "dedup: a forged reply marker from a non-viewer does NOT suppress the audit reply" {
  _mrc_gh_reply_shim
  export COMMENTS_JSON='[{"user":{"login":"attacker"},"body":"forged <!-- maintainer-resolve id=IC_kwDOfake1 -->","id":999}]'
  run bash "$MRC" "IC_kwDOfake1" --reason "status only"
  unset COMMENTS_JSON
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qi "already exists"
  [ -s "$BATS_TEST_TMPDIR/gh-reply.log" ]
  [ -s "$BATS_TEST_TMPDIR/gh-min.log" ]
}

@test "dedup: an existing reply the invoking viewer authored suppresses a duplicate" {
  _mrc_gh_reply_shim
  export COMMENTS_JSON='[{"user":{"login":"don-petry"},"body":"prior <!-- maintainer-resolve id=IC_kwDOfake1 -->","id":42}]'
  run bash "$MRC" "IC_kwDOfake1" --reason "status only"
  unset COMMENTS_JSON
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "already exists"
  [ ! -f "$BATS_TEST_TMPDIR/gh-reply.log" ]
  [ -s "$BATS_TEST_TMPDIR/gh-min.log" ]
}

@test "dedup: a reply pinning a longer node id that starts with ours does NOT suppress the audit reply" {
  # #1920 review: the marker's id= must match the FULL node id followed by a
  # delimiter (whitespace or -->), not a prefix — a reply for IC_kwDOfake12 must
  # not be mistaken for one addressing IC_kwDOfake1.
  _mrc_gh_reply_shim
  export COMMENTS_JSON='[{"user":{"login":"don-petry"},"body":"other <!-- maintainer-resolve id=IC_kwDOfake12 -->","id":77}]'
  run bash "$MRC" "IC_kwDOfake1" --reason "status only"
  unset COMMENTS_JSON
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qi "already exists"
  [ -s "$BATS_TEST_TMPDIR/gh-reply.log" ]
  [ -s "$BATS_TEST_TMPDIR/gh-min.log" ]
}

@test "fail closed: a failed comments-list lookup aborts before posting or minimizing" {
  _mrc_gh_reply_shim
  export FAIL_LIST=1
  run bash "$MRC" "IC_kwDOfake1" --reason "status only"
  unset FAIL_LIST
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "failing closed"
  [ ! -f "$BATS_TEST_TMPDIR/gh-reply.log" ]
  [ ! -f "$BATS_TEST_TMPDIR/gh-min.log" ]
}

# ────────────────────────────────────────────────────────────────────
# #2008 — a rate-limit notice must never clear findings. CodeRabbit's live summary
# (PR #2000, comment 5938681830) carries the OSS rate-limit block AND a Security
# Architecture Review with a Medium finding in ONE comment; the bot path must
# refuse it, and the finding-section guard must refuse any finding-bearing body
# even when a registered pattern would otherwise match it.
# ────────────────────────────────────────────────────────────────────

_mrc_fake_gh_file() {
  # $1 = author __typename, $2 = author login, $3 = file holding the RAW body.
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  jq -cn --arg t "$1" --arg l "$2" --rawfile b "$3" \
    '{data:{viewer:{login:"don-petry"},node:{author:{__typename:$t,login:$l},body:$b,isMinimized:false,minimizedReason:null,url:"https://github.com/o/r/pull/1#issuecomment-1"}}}' \
    > "$BATS_TEST_TMPDIR/node.json"
  cat > "$bin/gh" <<SHIM
#!/usr/bin/env bash
if [[ "\$*" == *"viewer{login}"* ]]; then
  cat "$BATS_TEST_TMPDIR/node.json"
  exit 0
fi
echo "\$*" >> "$BATS_TEST_TMPDIR/gh-writes.log"
printf '%s' '{"data":{}}'
SHIM
  chmod +x "$bin/gh"
  export PATH="$bin:$PATH"
}

@test "#2008: PR #2000's CodeRabbit summary (rate-limit block + security finding) is refused on the bot path (exit 3, no write)" {
  _mrc_fake_gh_file Bot coderabbitai "$BATS_TEST_DIRNAME/../../fixtures/coderabbit/pr2000-ratelimited-with-security-finding.md"
  run bash "$MRC" "IC_kwDOfake1" --reason "rate-limit notice only"
  [ "$status" -eq 3 ]
  echo "$output" | grep -qi "refusing to resolve"
  [ ! -s "$BATS_TEST_TMPDIR/gh-writes.log" ]
}

@test "#2008: mrc_bot_body_matches refuses a finding-bearing body even when the pattern matches" {
  local pats body
  # A deliberately permissive pattern: the section guard, not the pattern, must refuse.
  pats=$'coderabbitai\tReview limit reached'
  body=$'Review limit reached\n<!-- architecture_review_start -->\n**Retained concerns**\n- **Medium · security · inferred:** real finding.\n<!-- architecture_review_end -->'
  run bash -c "source '$MRC'; mrc_bot_body_matches coderabbitai \"\$2\" \"\$1\"" _ "$pats" "$body"
  [ "$status" -eq 1 ]
  # The same permissive pattern on a finding-free body is still authorized.
  run bash -c "source '$MRC'; mrc_bot_body_matches coderabbitai 'Review limit reached' \"\$1\"" _ "$pats"
  [ "$status" -eq 0 ]
}
