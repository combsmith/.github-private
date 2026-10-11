#!/usr/bin/env bats
# Budget breaker WRITER (#2153, slice 3b of #1565).
#
# Drives scripts/budget_breaker.sh end to end against a STATEFUL `gh` stub on
# PATH (no live network): the stub keeps the organisation's Actions variables
# in a file, applies every PATCH / POST / DELETE to it, and records which of
# the three credentials each call was made with (by label, never by value).
# The decision itself is the real scripts/lib/budget-breaker.sh.
#
#   AC #1  disarmed; armed with no secret; trip; hold; resume; none; collector
#          failure: what is written, and what is only logged.
#   AC #2  a human pause (no source, or a foreign source) is left exactly as it
#          is, by trip and by resume, in the run and in the planner.
#   AC #3  no credential value ever reaches the log, the summary or any file.
#   AC #4  anti-flap: same state twice writes once; no write when the state
#          already matches; a resume before the minimum hold does not write.
#   AC #5  write order on trip and resume; a refused write is ONE actionable
#          error, a red run, no retry and no unowned pause.
#   AC #6  static: the write secret is named only in the new workflow, this
#          test and the docs; the poller still has no write path.
#   3a     the collector reads with the read credential, markers dropped as
#          untrusted are counted and reported, and pr-review's marker can not
#          be opted in.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/budget_breaker.sh"
WRITER_LIB="$REPO_ROOT/scripts/lib/budget-breaker-writer.sh"
DECISION_LIB="$REPO_ROOT/scripts/lib/budget-breaker.sh"
MARKERS_LIB="$REPO_ROOT/scripts/lib/rate-limit-markers.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/budget-breaker.yml"
POLLER_WORKFLOW="$REPO_ROOT/.github/workflows/budget-poller.yml"
POLLER="$REPO_ROOT/scripts/budget_poller.sh"
POLLER_LIB="$REPO_ROOT/scripts/lib/budget-poller.sh"

# The write secret's name. Allowed here, in the workflow and in the docs only.
PAT_NAME="BUDGET_BREAKER_PAT"

# 2026-10-10T12:00:00Z
NOW=1791633600

setup() {
  bats_require_minimum_version 1.5.0
  unset BUDGET_BREAKER_MIN_ITEMS BUDGET_BREAKER_WINDOW_MIN BUDGET_BREAKER_PROBE_HOURS \
    BUDGET_BREAKER_MARKER_KINDS BUDGET_BREAKER_MIN_HOLD_MIN BUDGET_BREAKER_VISIBILITY_REF \
    BUDGET_BREAKER_ROTATE_DAYS BUDGET_BREAKER_ARMED PR_RATE_LIMITED_MARKER_PREFIX \
    BUDGET_BREAKER_VARS_PAUSED BUDGET_BREAKER_VARS_SOURCE BUDGET_BREAKER_VARS_UNTIL \
    GITHUB_SERVER_URL GITHUB_RUN_ID GITHUB_REPOSITORY

  # Obviously fake credentials, built at run time so no token-shaped literal is
  # ever committed. Three different values: a call made with the wrong one shows.
  WRITE_CRED="fake-WRITE-credential-${RANDOM}${RANDOM}-not-a-real-token"
  READ_CRED="fake-READ-credential-${RANDOM}${RANDOM}-not-a-real-token"
  NOTIFY_CRED="fake-NOTIFY-credential-${RANDOM}${RANDOM}-not-a-real-token"
  export MOCK_WRITE_CRED="$WRITE_CRED" MOCK_READ_CRED="$READ_CRED" MOCK_NOTIFY_CRED="$NOTIFY_CRED"

  export BUDGET_BREAKER_TOKEN="$WRITE_CRED"
  export BUDGET_BREAKER_READ_TOKEN="$READ_CRED"
  export BUDGET_BREAKER_NOTIFY_TOKEN="$NOTIFY_CRED"
  export BUDGET_BREAKER_SECRET_NAME="$PAT_NAME"
  export BUDGET_BREAKER_ORG="acme"
  export BUDGET_BREAKER_NOTIFY_REPO="acme/.github-private"
  export BUDGET_BREAKER_NOW="$NOW"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  # An ambient credential the script must never use.
  AMBIENT="ambient-${RANDOM}${RANDOM}-must-never-be-used"
  export GH_TOKEN="$AMBIENT" GITHUB_TOKEN="$AMBIENT"

  export MOCK_DIR="$BATS_TEST_TMPDIR/mock"
  mkdir -p "$MOCK_DIR/comments" "$MOCK_DIR/posted" "$BATS_TEST_TMPDIR/bin"
  : > "$MOCK_DIR/calls.log"
  : > "$MOCK_DIR/writes.log"
  printf '[{"nameWithOwner":"acme/app","isFork":false},{"nameWithOwner":"acme/lib","isFork":false},{"nameWithOwner":"acme/fork","isFork":true}]' \
    > "$MOCK_DIR/repos.json"
  printf '[]' > "$MOCK_DIR/issues.json"
  MOCK_NOW_ISO="$(ts 0)"
  export MOCK_NOW_ISO
  unset MOCK_FAIL_ON MOCK_FAIL_STATUS MOCK_LEAK MOCK_LIST_FAIL_STATUS MOCK_REPOS_FAIL \
    MOCK_COMMENT_FAIL MOCK_FLIP_AFTER_LIST
  # Switches added with #2251 (all off unless a test sets them).
  unset MOCK_HUMAN_AFTER_WRITE MOCK_HUMAN_JQ MOCK_FAIL_DELETE MOCK_LIST_FAIL_FROM \
    MOCK_LIST_FAIL_FROM_STATUS MOCK_NOTICE_LOOKUP_FAIL

  # The organisation as it is today: no pause switch yet, and a fleet variable
  # visible to all repositories for a created variable to copy.
  set_vars "$(var AI_ENGINES claude all)"

  install_gh
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# ── helpers ──────────────────────────────────────────────────────────────────

# ts <offset_sec> — ISO-8601 UTC for NOW + offset.
ts() { jq -nr --argjson t "$(( NOW + $1 ))" '$t | todate'; }

# var <name> <value> [<visibility> [<updated_offset_sec>]] — one variable.
var() {
  jq -cn --arg n "$1" --arg v "$2" --arg vis "${3:-all}" --arg u "$(ts "${4:--86400}")" \
    '{name: $n, value: $v, visibility: $vis, created_at: $u, updated_at: $u}'
}

# set_vars <var>... — replace the organisation's variables.
set_vars() { printf '%s\n' "$@" | jq -cs 'map({key: .name, value: .}) | from_entries' > "$MOCK_DIR/vars.json"; }

# org_var <name> — a variable's current value in the stub ("<absent>" if none).
org_var() { jq -r --arg n "$1" '.[$n].value // "<absent>"' "$MOCK_DIR/vars.json"; }

# marker <kind> <item> — a real-shaped first line, from the shared prefixes.
marker() {
  # shellcheck source=../../../scripts/lib/rate-limit-markers.sh
  source "$MARKERS_LIB"
  case "$1" in
    ci)       printf '%sabc%s status=rate-limited reset=%s check=CI -->' "$CI_MARKER_PREFIX" "$2" "$(ts 3600)" ;;
    reviews)  printf '%s%s sha=abc intent=fix-reviews status=rate-limited reset=%s -->' "$REVIEWS_MARKER_PREFIX" "$2" "$(ts 5400)" ;;
    issue)    printf '%s%s status=rate-limited attempt=1 reason=quota run=1 reset=%s -->' "$ISSUE_MARKER_PREFIX" "$2" "$(ts 7200)" ;;
    noreset)  printf '%s%s status=rate-limited attempt=1 reason=quota run=1 -->' "$ISSUE_MARKER_PREFIX" "$2" ;;
    advisory) printf '<!-- pr-review-agent rate-limited v1 sha=abc%s status=rate-limited reset=%s -->' "$2" "$(ts 3600)" ;;
  esac
}

# comment <kind> <item> [<association> [<created_offset_sec>]] — one issue comment.
comment() {
  jq -cn --arg b "$(marker "$1" "$2")"$'\n\nAll engines were rate-limited.' \
    --arg c "$(ts "${4:--300}")" --arg a "${3:-MEMBER}" \
    --arg u "https://api.github.com/repos/acme/app/issues/$2" \
    '{body: $b, created_at: $c, issue_url: $u, author_association: $a}'
}

# seed_comments <repo> <comment>... — what the repo's comment listing returns.
seed_comments() {
  local repo="$1"
  shift
  printf '%s\n' "$@" | jq -cs '.' > "$MOCK_DIR/comments/${repo//\//__}.json"
}

# seed_quota [<association>] — three items refused for quota inside the window:
# enough for the decision to trip, with the latest reset two hours out.
seed_quota() {
  seed_comments acme/app \
    "$(comment ci 11 "${1:-MEMBER}")" "$(comment reviews 12 "${1:-MEMBER}")" "$(comment issue 13 "${1:-MEMBER}")"
}
TRIP_UNTIL_OFFSET=7200

# own_pause <until_offset_sec> [<paused_updated_offset_sec>] — the fleet as the
# breaker's own trip leaves it.
own_pause() {
  set_vars "$(var AI_ENGINES claude all)" \
    "$(var AGENTS_PAUSE_SOURCE rate-limit-observed all "${2:--7200}")" \
    "$(var AGENTS_PAUSE_UNTIL "$(ts "$1")" all "${2:--7200}")" \
    "$(var AGENTS_PAUSED true all "${2:--7200}")"
}

writes() { cat "$MOCK_DIR/writes.log"; }
no_writes() {
  [ ! -s "$MOCK_DIR/writes.log" ] || { echo "unexpected writes:"; cat "$MOCK_DIR/writes.log"; return 1; }
}
no_notice() {
  [ -z "$(ls -A "$MOCK_DIR/posted")" ] || { echo "unexpected notice:"; cat "$MOCK_DIR"/posted/*; return 1; }
  run grep -cE $'^notify\t' "$MOCK_DIR/calls.log"
  [ "$output" = "0" ]
}
# calls_by <who> — the calls made with that credential.
calls_by() { grep -E "^$1"$'\t' "$MOCK_DIR/calls.log" || true; }

# assert_no_credential_anywhere — none of the three credential values (nor the
# ambient one's use) appears in the output, the summary or any file the run or
# the stub wrote.
assert_no_credential_anywhere() {
  local c
  for c in "$WRITE_CRED" "$READ_CRED" "$NOTIFY_CRED"; do
    if [[ "$output" == *"$c"* ]]; then
      echo "a credential value is in the output"
      return 1
    fi
    if grep -rqF -- "$c" "$BATS_TEST_TMPDIR" 2>/dev/null; then
      echo "a credential value is in a file under the test directory:"
      grep -rlF -- "$c" "$BATS_TEST_TMPDIR"
      return 1
    fi
  done
  # No call ever ran without a named credential, or with the ambient one.
  run grep -cE $'^(none|unknown)\t' "$MOCK_DIR/calls.log"
  [ "$output" = "0" ]
}

armed() { export BUDGET_BREAKER_ARMED="true"; }

install_gh() {
  cat > "$BATS_TEST_TMPDIR/bin/gh" << 'GH'
#!/usr/bin/env bash
# Stateful gh stub. Never prints or stores a credential unless MOCK_LEAK asks
# it to (to prove the caller redacts what gh itself might say).
set -uo pipefail
D="$MOCK_DIR"
case "${GH_TOKEN:-}" in
  "")                  who="none" ;;
  "$MOCK_READ_CRED")   who="read" ;;
  "$MOCK_WRITE_CRED")  who="write" ;;
  "$MOCK_NOTIFY_CRED") who="notify" ;;
  *)                   who="unknown" ;;
esac
printf '%s\t%s\n' "$who" "$*" >> "$D/calls.log"

fail() {  # fail <status> <message>
  if [ -n "${MOCK_LEAK:-}" ]; then
    printf 'gh: %s; credential %s was rejected (HTTP %s)\n' "$2" "${GH_TOKEN:-}" "$1" >&2
  else
    printf 'gh: %s (HTTP %s)\n' "$2" "$1" >&2
  fi
  exit 1
}
need() { [ "$who" = "$1" ] || fail 403 "Resource not accessible by this credential"; }

jqf="" method="GET" title="" body="" number="" paginate=""
fields=() labels=() rest=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jqf="$2"; shift 2 ;;
    -X|--method) method="$2"; shift 2 ;;
    -f) fields+=("$2"); shift 2 ;;
    -F|--field|--raw-field|--input) echo "stub gh: a typed or file field ($1) is never expected" >&2; exit 97 ;;
    --title) title="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --label) labels+=("$2"); shift 2 ;;
    --limit|--json|--repo|--state|--color|--description) shift 2 ;;
    --paginate) paginate=1; shift ;;
    *) rest+=("$1"); shift ;;
  esac
done
field() {  # field <key> — the value of a -f key=value
  local f
  for f in "${fields[@]}"; do
    case "$f" in "$1="*) printf '%s' "${f#*=}"; return 0 ;; esac
  done
  return 1
}
put() { jq -c "$@" "$D/vars.json" > "$D/vars.json.tmp" && mv "$D/vars.json.tmp" "$D/vars.json"; }
# paged <per_page> <wrap_filter> — the JSON array on stdin, served the way
# `gh api` serves a REST listing: <per_page> items a page, each page wrapped by
# <wrap_filter> (which sees the page as `.` and the whole array as $all) and
# then put through the caller's --jq, ONE evaluation per page. Without
# --paginate only the first page is served, as the real gh does.
paged() {
  local per="$1" wrap="$2" all total offset=0
  all="$(cat)"
  total="$(jq 'length' <<< "$all")"
  while :; do
    jq -c --argjson all "$all" --argjson o "$offset" --argjson n "$per" \
      ".[\$o:\$o + \$n] | ${wrap}" <<< "$all" | jq -c "$jqf"
    offset=$(( offset + per ))
    [ -n "$paginate" ] && [ "$offset" -lt "$total" ] || break
  done
}
# human_acts <variable just written> — someone else changes the organisation's
# variables right after the breaker's write to MOCK_HUMAN_AFTER_WRITE, once:
# MOCK_HUMAN_JQ is applied to them ($u is the stub's clock). It is not one of
# the breaker's writes, so it is not in writes.log.
human_acts() {
  [ -n "${MOCK_HUMAN_AFTER_WRITE:-}" ] && [ "$MOCK_HUMAN_AFTER_WRITE" = "$1" ] || return 0
  [ ! -f "$D/human-acted" ] || return 0
  put --arg u "$MOCK_NOW_ISO" "$MOCK_HUMAN_JQ"
  : > "$D/human-acted"
}

case "${rest[0]:-} ${rest[1]:-}" in
  "repo list")
    [ -z "${MOCK_REPOS_FAIL:-}" ] || fail 500 "cannot list repositories"
    need read
    jq -r "$jqf" "$D/repos.json" ;;
  "label create")
    need notify
    exit 0 ;;
  "issue list")
    need notify
    cat "$D/issues.json" ;;
  "issue create")
    need notify
    jq -c --arg t "$title" '. + [{number: 77, title: $t}]' "$D/issues.json" > "$D/issues.json.tmp" \
      && mv "$D/issues.json.tmp" "$D/issues.json"
    printf '%s\n' "${labels[@]}" > "$D/issue-labels.txt"
    printf '%s' "$body" > "$D/issue-body.md"
    echo "https://github.com/acme/.github-private/issues/77" ;;
  "issue comment")
    need notify
    [ -z "${MOCK_COMMENT_FAIL:-}" ] || fail 403 "Resource not accessible by integration"
    number="${rest[2]:-}"
    n=$(find "$D/posted" -type f | wc -l | tr -d ' ')
    printf '%s' "$body" > "$D/posted/$(( n + 1 ))-issue-${number}.md" ;;
  api\ *)
    path="${rest[1]}"
    case "$method $path" in
      "GET repos/"*"/issues/comments?"*)
        need read
        repo="${path#repos/}"; repo="${repo%%/issues/*}"
        f="$D/comments/${repo//\//__}.json"
        [ -f "$f" ] || { echo -n; exit 0; }
        jq -c "$jqf" "$f" ;;
      "GET repos/"*"/actions/secrets/"*)
        need read
        [ -f "$D/secret.json" ] || fail 404 "Not Found"
        jq -r "$jqf" "$D/secret.json" ;;
      "GET repos/"*"/issues/"*"/comments?per_page="*)
        # The comments of ONE issue: what the stub has posted on it.
        need notify
        [ -z "${MOCK_NOTICE_LOOKUP_FAIL:-}" ] || fail 502 "Bad Gateway"
        number="${path#*/issues/}"; number="${number%%/*}"
        find "$D/posted" -type f -name "*-issue-${number}.md" | sort -V \
          | while IFS= read -r f; do jq -Rs '{body: .}' "$f"; done | jq -cs '.' \
          | paged "${path##*per_page=}" '.' ;;
      "GET orgs/"*"/actions/variables?per_page=30")
        [ -z "${MOCK_LIST_FAIL_STATUS:-}" ] || fail "$MOCK_LIST_FAIL_STATUS" "Resource not accessible by personal access token"
        # MOCK_LIST_FAIL_FROM=<n>: the n-th listing since the test began (or
        # since it removed $D/listings), and every later one, fails.
        listings=$(( $(cat "$D/listings" 2>/dev/null || echo 0) + 1 ))
        echo "$listings" > "$D/listings"
        if [ -n "${MOCK_LIST_FAIL_FROM:-}" ] && [ "$listings" -ge "$MOCK_LIST_FAIL_FROM" ]; then
          fail "${MOCK_LIST_FAIL_FROM_STATUS:-502}" "Resource not accessible by personal access token"
        fi
        need write
        jq -c '[.[]]' "$D/vars.json" | paged "${path##*per_page=}" '{total_count: ($all | length), variables: .}'
        # A human changes the switch right after the run's first read.
        if [ -n "${MOCK_FLIP_AFTER_LIST:-}" ] && [ ! -f "$D/flipped" ]; then
          cp "$MOCK_FLIP_AFTER_LIST" "$D/vars.json"
          : > "$D/flipped"
        fi ;;
      "PATCH orgs/"*"/actions/variables/"*)
        name="${path##*/}"
        value="$(field value)" || { echo "stub gh: PATCH without -f value=" >&2; exit 97; }
        field visibility >/dev/null && { echo "stub gh: PATCH must not send a visibility" >&2; exit 97; }
        if [ "${MOCK_FAIL_ON:-}" = "$name" ]; then
          echo "FAILED PATCH $name=$value" >> "$D/writes.log"
          fail "${MOCK_FAIL_STATUS:-403}" "Resource not accessible by personal access token"
        fi
        need write
        [ "$(jq -r --arg n "$name" 'has($n)' "$D/vars.json")" = "true" ] || fail 404 "Not Found"
        put --arg n "$name" --arg v "$value" --arg u "$MOCK_NOW_ISO" '.[$n].value = $v | .[$n].updated_at = $u'
        echo "PATCH $name=$value" >> "$D/writes.log"
        human_acts "$name" ;;
      "POST orgs/"*"/actions/variables")
        name="$(field name)"; value="$(field value)"; vis="$(field visibility)"
        if [ "${MOCK_FAIL_ON:-}" = "$name" ]; then
          echo "FAILED POST $name=$value visibility=$vis" >> "$D/writes.log"
          fail "${MOCK_FAIL_STATUS:-403}" "Resource not accessible by personal access token"
        fi
        need write
        [ "$(jq -r --arg n "$name" 'has($n)' "$D/vars.json")" = "false" ] || fail 409 "Already exists"
        put --arg n "$name" --arg v "$value" --arg vis "$vis" --arg u "$MOCK_NOW_ISO" \
          '.[$n] = {name: $n, value: $v, visibility: $vis, created_at: $u, updated_at: $u}'
        echo "POST $name=$value visibility=$vis" >> "$D/writes.log"
        human_acts "$name" ;;
      "DELETE orgs/"*"/actions/variables/"*)
        name="${path##*/}"
        if [ "${MOCK_FAIL_ON:-}" = "$name" ] || [ "${MOCK_FAIL_DELETE:-}" = "$name" ]; then
          echo "FAILED DELETE $name" >> "$D/writes.log"
          fail "${MOCK_FAIL_STATUS:-403}" "Resource not accessible by personal access token"
        fi
        need write
        [ "$(jq -r --arg n "$name" 'has($n)' "$D/vars.json")" = "true" ] || fail 404 "Not Found"
        put --arg n "$name" 'del(.[$n])'
        echo "DELETE $name" >> "$D/writes.log" ;;
      *)
        echo "stub gh: unexpected api call: $method $path" >&2
        exit 98 ;;
    esac ;;
  *)
    echo "stub gh: unexpected command: ${rest[*]}" >&2
    exit 98 ;;
esac
GH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

# ── AC #1: default off, twice ────────────────────────────────────────────────

@test "disarmed: a trip is decided and logged as the write it would have made; nothing is written" {
  seed_quota
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: disarmed"* ]]
  [[ "$output" == *"decision: trip (evidence_count=3)"* ]]
  [[ "$output" == *"NOT WRITING (disarmed). Would have written: AGENTS_PAUSE_SOURCE=rate-limit-observed; AGENTS_PAUSE_UNTIL=$(ts "$TRIP_UNTIL_OFFSET"); AGENTS_PAUSED=true"* ]]
  no_writes
  no_notice
  # A disarmed run makes no call at all with the write credential.
  [ -z "$(calls_by write)" ]
  [ "$(org_var AGENTS_PAUSED)" = "<absent>" ]
  grep -q 'would have written: AGENTS_PAUSE_SOURCE=rate-limit-observed' "$GITHUB_STEP_SUMMARY"
}

@test "disarmed: only the exact string true arms; TRUE, True, 1, yes and a padded value do not" {
  local v
  seed_quota
  for v in TRUE True 1 yes " true" "true " on; do
    : > "$MOCK_DIR/calls.log"
    BUDGET_BREAKER_ARMED="$v" run bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "armed='$v' status=$status"; false; }
    [[ "$output" == *"NOT WRITING (disarmed)"* ]] || { echo "armed='$v' was not disarmed: $output"; false; }
    no_writes
    [ -z "$(calls_by write)" ] || { echo "armed='$v' used the write credential"; false; }
  done
}

@test "disarmed, quiet fleet: logs every run that it would have written nothing" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: none"* ]]
  [[ "$output" == *"NOT WRITING (disarmed). Would have written: nothing"* ]]
  no_writes
}

@test "disarmed: the pause state comes from the vars context, and an expired own pause logs the resume it would make" {
  export BUDGET_BREAKER_VARS_PAUSED="true" BUDGET_BREAKER_VARS_SOURCE="rate-limit-observed"
  BUDGET_BREAKER_VARS_UNTIL="$(ts -60)"
  export BUDGET_BREAKER_VARS_UNTIL
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pause state from this repository's vars context"* ]]
  [[ "$output" == *"decision: resume"* ]]
  [[ "$output" == *"Would have written: AGENTS_PAUSED=false; delete AGENTS_PAUSE_SOURCE; delete AGENTS_PAUSE_UNTIL"* ]]
  no_writes
  no_notice
}

@test "armed with no secret: the named, non-failing no-op, and still the would-write log" {
  armed
  unset BUDGET_BREAKER_TOKEN
  seed_quota
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"breaker armed but ${PAT_NAME} is not configured"* ]]
  [[ "$output" == *"NOT WRITING (armed, no credential). Would have written: AGENTS_PAUSE_SOURCE=rate-limit-observed"* ]]
  [[ "$output" != *"::error::"* ]]
  no_writes
  no_notice
  [ -z "$(calls_by write)" ]
}

# ── AC #1 / #5: trip ─────────────────────────────────────────────────────────

@test "armed, trip: source, then until, then the pause; one notice; each call with its own credential" {
  armed
  seed_quota
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: armed"* ]]
  [[ "$output" == *"pause state from organisation API"* ]]
  # The pause switch does not exist yet: all three are created, in order, with
  # the visibility read from the fleet's existing variable.
  [ "$(writes)" = "POST AGENTS_PAUSE_SOURCE=rate-limit-observed visibility=all
POST AGENTS_PAUSE_UNTIL=$(ts "$TRIP_UNTIL_OFFSET") visibility=all
POST AGENTS_PAUSED=true visibility=all" ]
  [ "$(org_var AGENTS_PAUSED)" = "true" ]
  [ "$(org_var AGENTS_PAUSE_SOURCE)" = "rate-limit-observed" ]
  [ "$(org_var AGENTS_PAUSE_UNTIL)" = "$(ts "$TRIP_UNTIL_OFFSET")" ]
  [[ "$output" == *"::notice::budget-breaker: fleet PAUSED until $(ts "$TRIP_UNTIL_OFFSET")"* ]]

  # Exactly one notice, on a tracking issue created on first use and labelled
  # so dev-lead ignores it.
  [ "$(find "$MOCK_DIR/posted" -type f | wc -l | tr -d ' ')" = "1" ]
  grep -q 'Fleet paused by the budget breaker' "$MOCK_DIR/posted/1-issue-77.md"
  grep -qF "$(ts "$TRIP_UNTIL_OFFSET")" "$MOCK_DIR/posted/1-issue-77.md"
  grep -qF '`acme/app#11`' "$MOCK_DIR/posted/1-issue-77.md"
  grep -qx 'budget-breaker' "$MOCK_DIR/issue-labels.txt"
  grep -qx 'dev-lead:hands-off' "$MOCK_DIR/issue-labels.txt"

  # Credential separation: the scan with the read credential, every variable
  # call with the write credential, the notice with the workflow token.
  [ "$(calls_by read | grep -c 'issues/comments')" = "2" ]
  [ "$(calls_by read | grep -c 'actions/variables')" = "0" ]
  [ "$(calls_by write | grep -vc 'actions/variables')" = "0" ]
  [ "$(calls_by notify | grep -c 'actions/variables')" = "0" ]
  [ "$(grep -c 'actions/variables' "$MOCK_DIR/calls.log")" = "$(calls_by write | wc -l | tr -d ' ')" ]
  assert_no_credential_anywhere
}

@test "armed, trip: an existing variable is updated in place (value only, visibility untouched), a missing one is created to match" {
  armed
  seed_quota
  set_vars "$(var AI_ENGINES claude all)" "$(var AGENTS_PAUSED false private)"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # The pause switch itself is the visibility reference for its two companions.
  [ "$(writes)" = "POST AGENTS_PAUSE_SOURCE=rate-limit-observed visibility=private
POST AGENTS_PAUSE_UNTIL=$(ts "$TRIP_UNTIL_OFFSET") visibility=private
PATCH AGENTS_PAUSED=true" ]
  [ "$(jq -r '.AGENTS_PAUSED.visibility' "$MOCK_DIR/vars.json")" = "private" ]
  # The stub rejects a PATCH carrying a visibility and any typed (-F) field, so
  # reaching here also proves the value went as a raw string.
  run grep -cE -- ' -F | --field ' "$MOCK_DIR/calls.log"
  [ "$output" = "0" ]
  grep -qF -- '-f value=true' "$MOCK_DIR/calls.log"
}

@test "armed, trip: no visibility reference, or one visible to selected repositories, creates nothing and says what to do" {
  armed
  seed_quota
  set_vars "$(var UNRELATED x all)"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"none of the reference variables"* ]]
  [[ "$output" == *"If AGENTS_PAUSED does not exist, create it (value false) as an Actions variable of the organisation acme by hand"* ]]
  # It is not a credential problem, and the error does not send anyone to the token.
  [[ "$output" != *"The token in"* ]]
  no_writes

  set_vars "$(var AI_ENGINES claude selected)"
  : > "$MOCK_DIR/writes.log"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the reference variable AI_ENGINES is visible to selected repositories only"* ]]
  [ "$(grep -c '::error::' <<< "$output")" = "1" ]
  no_writes
  no_notice

  # A pause switch that is itself limited to selected repositories: its two
  # companions cannot be created to match, so nothing is written at all (the
  # switch is not updated either).
  set_vars "$(var AI_ENGINES claude all)" "$(var AGENTS_PAUSED false selected)"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the reference variable AGENTS_PAUSED is visible to selected repositories only"* ]]
  no_writes
  [ "$(org_var AGENTS_PAUSED)" = "false" ]
}

# ── AC #1: hold, resume, none ────────────────────────────────────────────────

@test "armed, hold: an own pause that has not ended writes nothing and posts nothing" {
  armed
  own_pause 1800
  seed_quota
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: hold"* ]]
  [[ "$output" == *"nothing to write (hold)"* ]]
  no_writes
  no_notice
  # Paused: the markers are not consulted, so the fleet is not even scanned.
  [ -z "$(calls_by read | grep 'issues/comments')" ]
}

@test "armed, resume: the pause is lifted first, then source and until are removed; one notice" {
  armed
  own_pause -60
  printf '[{"number":41,"title":"Budget breaker: automatic fleet pauses (tracking)"},{"number":40,"title":"something else"}]' \
    > "$MOCK_DIR/issues.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: resume"* ]]
  [ "$(writes)" = "PATCH AGENTS_PAUSED=false
DELETE AGENTS_PAUSE_SOURCE
DELETE AGENTS_PAUSE_UNTIL" ]
  [ "$(org_var AGENTS_PAUSED)" = "false" ]
  [ "$(org_var AGENTS_PAUSE_SOURCE)" = "<absent>" ]
  [ "$(org_var AGENTS_PAUSE_UNTIL)" = "<absent>" ]
  [[ "$output" == *"::notice::budget-breaker: fleet RESUMED"* ]]
  # The existing tracking issue is reused: no second issue, one comment.
  [ ! -f "$MOCK_DIR/issue-labels.txt" ]
  [ "$(find "$MOCK_DIR/posted" -type f | wc -l | tr -d ' ')" = "1" ]
  grep -q 'Fleet resumed by the budget breaker' "$MOCK_DIR/posted/1-issue-41.md"
  assert_no_credential_anywhere
}

@test "armed, resume: an own pause whose until is missing is released (fail open)" {
  armed
  set_vars "$(var AI_ENGINES claude all)" \
    "$(var AGENTS_PAUSE_SOURCE rate-limit-observed all -7200)" "$(var AGENTS_PAUSED true all -7200)"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(writes)" = "PATCH AGENTS_PAUSED=false
DELETE AGENTS_PAUSE_SOURCE" ]
}

@test "armed, none: a quiet fleet, or too little evidence, writes nothing" {
  armed
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: none"* ]]
  no_writes
  no_notice

  seed_comments acme/app "$(comment ci 11)" "$(comment reviews 12)"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"quota markers read: 2 trusted, 0 dropped as untrusted"* ]]
  [[ "$output" == *"decision: none (evidence_count=2)"* ]]
  no_writes
  no_notice
}

# ── AC #1: fail open ─────────────────────────────────────────────────────────

@test "collector failure: no evidence is no write, with a warning, never a pause" {
  armed
  seed_quota
  export MOCK_REPOS_FAIL=1
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::budget-breaker: the collector could not read the fleet's quota markers; failing open"* ]]
  [[ "$output" == *"decision: none"* ]]
  no_writes
  no_notice
}

@test "collector failure: no read credential never falls back to another credential" {
  armed
  seed_quota
  unset BUDGET_BREAKER_READ_TOKEN
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no read credential is configured"* ]]
  no_writes
  # The fleet scan was not attempted with the write or the ambient credential.
  run grep -cE 'repo list|issues/comments' "$MOCK_DIR/calls.log"
  [ "$output" = "0" ]
}

@test "an unreadable pause state that is not a permission problem is a warning and no write" {
  armed
  seed_quota
  export MOCK_LIST_FAIL_STATUS=502
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::budget-breaker: could not read the organisation's Actions variables (HTTP 502"* ]]
  no_writes
}

@test "a decision that does not fit the state is never written (the planner checks ownership itself)" {
  # shellcheck source=../../../scripts/lib/budget-breaker.sh
  source "$DECISION_LIB"
  # shellcheck source=../../../scripts/lib/budget-breaker-writer.sh
  source "$WRITER_LIB"
  local human foreign own unpaused upper
  human="$(printf '%s\n' "$(var AGENTS_PAUSED true)" | jq -cs 'map({key: .name, value: .}) | from_entries')"
  foreign="$(printf '%s\n' "$(var AGENTS_PAUSED true)" "$(var AGENTS_PAUSE_SOURCE maintenance)" | jq -cs 'map({key: .name, value: .}) | from_entries')"
  upper="$(printf '%s\n' "$(var AGENTS_PAUSED TRUE)" | jq -cs 'map({key: .name, value: .}) | from_entries')"
  own="$(printf '%s\n' "$(var AGENTS_PAUSED true)" "$(var AGENTS_PAUSE_SOURCE rate-limit-observed)" | jq -cs 'map({key: .name, value: .}) | from_entries')"
  unpaused='{}'
  local trip resume
  trip="$(jq -cn --arg u "$(ts 3600)" '{action: "trip", until: $u, reason: "forged", evidence_count: 3}')"
  resume='{"action":"resume","until":null,"reason":"forged","evidence_count":0}'

  # A forged trip over any pause, and a forged resume of a pause that is not
  # the breaker's, are refused: no plan at all, so nothing can be written.
  local s
  for s in "$human" "$foreign" "$upper" "$own"; do
    run bbw_plan "$trip" "$s"
    [ "$status" -ne 0 ] || { echo "trip planned over: $s"; false; }
    [ -z "$output" ]
  done
  for s in "$human" "$foreign" "$upper" "$unpaused"; do
    run bbw_plan "$resume" "$s"
    [ "$status" -ne 0 ] || { echo "resume planned for: $s"; false; }
    [ -z "$output" ]
  done
  # A trip with no readable end time is refused too.
  run bbw_plan '{"action":"trip","until":null,"reason":"x","evidence_count":3}' "$unpaused"
  [ "$status" -ne 0 ]
  # ... while the legitimate pair plans, and hold / none plan nothing.
  run bbw_plan "$trip" "$unpaused"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'map(.name) | join(",")' <<< "$output")" = "AGENTS_PAUSE_SOURCE,AGENTS_PAUSE_UNTIL,AGENTS_PAUSED" ]
  run bbw_plan "$resume" "$own"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'map("\(.op) \(.name)") | join(",")' <<< "$output")" = "set AGENTS_PAUSED,delete AGENTS_PAUSE_SOURCE" ]
  run bbw_plan '{"action":"hold","until":"x","reason":"x","evidence_count":0}' "$own"
  [ "$output" = "[]" ]
  run bbw_plan '{"action":"none","until":null,"reason":"x","evidence_count":0}' "$human"
  [ "$output" = "[]" ]
}

# ── AC #2: a human pause is never touched ────────────────────────────────────

@test "human pause with no source: left exactly as it is, by trip and by resume" {
  armed
  seed_quota
  set_vars "$(var AI_ENGINES claude all)" "$(var AGENTS_PAUSED true all -7200)"
  cp "$MOCK_DIR/vars.json" "$BATS_TEST_TMPDIR/before.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: none"* ]]
  [[ "$output" == *"a human pause is never tripped over and never resumed"* ]]
  no_writes
  no_notice
  cmp "$MOCK_DIR/vars.json" "$BATS_TEST_TMPDIR/before.json"

  # ... and with a leftover until long past, which would end an OWN pause.
  set_vars "$(var AI_ENGINES claude all)" "$(var AGENTS_PAUSED true all -7200)" \
    "$(var AGENTS_PAUSE_UNTIL "$(ts -3600)" all -7200)"
  cp "$MOCK_DIR/vars.json" "$BATS_TEST_TMPDIR/before.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: none"* ]]
  no_writes
  cmp "$MOCK_DIR/vars.json" "$BATS_TEST_TMPDIR/before.json"
}

@test "human pause with a foreign source: left exactly as it is, by trip and by resume" {
  armed
  seed_quota
  set_vars "$(var AI_ENGINES claude all)" "$(var AGENTS_PAUSED true all -7200)" \
    "$(var AGENTS_PAUSE_SOURCE maintenance all -7200)" "$(var AGENTS_PAUSE_UNTIL "$(ts -3600)" all -7200)"
  cp "$MOCK_DIR/vars.json" "$BATS_TEST_TMPDIR/before.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: none"* ]]
  [[ "$output" == *"not a pause this breaker set"* ]]
  no_writes
  no_notice
  cmp "$MOCK_DIR/vars.json" "$BATS_TEST_TMPDIR/before.json"
}

@test "human pause written as TRUE is honoured as a pause and left alone" {
  armed
  seed_quota
  set_vars "$(var AI_ENGINES claude all)" "$(var AGENTS_PAUSED TRUE all -7200)"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: none"* ]]
  no_writes
}

@test "a human pause set while the run was deciding is not overwritten" {
  armed
  seed_quota
  # The first read sees an unpaused fleet; a maintainer pauses by hand before
  # the write. The second read, taken just before the first write, sees it.
  printf '%s\n' "$(var AI_ENGINES claude all)" "$(var AGENTS_PAUSED true all 0)" \
    | jq -cs 'map({key: .name, value: .}) | from_entries' > "$BATS_TEST_TMPDIR/human.json"
  export MOCK_FLIP_AFTER_LIST="$BATS_TEST_TMPDIR/human.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: trip"* ]]
  [[ "$output" == *"the pause state changed while this run was deciding"* ]]
  no_writes
  no_notice
  [ "$(org_var AGENTS_PAUSED)" = "true" ]
  [ "$(org_var AGENTS_PAUSE_SOURCE)" = "<absent>" ]
}

# ── AC #3: the credential never reaches any output ───────────────────────────

@test "no credential value is in the log, the summary or any file: disarmed, tripping, resuming, refused" {
  seed_quota
  run bash "$SCRIPT"
  assert_no_credential_anywhere

  armed
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_no_credential_anywhere

  own_pause -60
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_no_credential_anywhere

  export MOCK_LIST_FAIL_STATUS=403
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  assert_no_credential_anywhere
}

@test "a credential echoed back by gh itself is redacted before it is logged" {
  armed
  seed_quota
  # The stub's error text now carries the credential it was called with.
  export MOCK_LEAK=1 MOCK_FAIL_ON=AGENTS_PAUSE_SOURCE
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"credential *** was rejected"* ]]
  [[ "$output" != *"$WRITE_CRED"* ]]
  ! grep -qF -- "$WRITE_CRED" "$GITHUB_STEP_SUMMARY"

  # The same for the read path (state listing) ...
  unset MOCK_FAIL_ON
  export MOCK_LIST_FAIL_STATUS=403
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"credential *** was rejected"* ]]
  [[ "$output" != *"$WRITE_CRED"* ]]

  # ... and for the notice.
  unset MOCK_LIST_FAIL_STATUS
  export MOCK_COMMENT_FAIL=1
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" != *"$NOTIFY_CRED"* ]]
  [[ "$output" != *"$WRITE_CRED"* ]]
  ! grep -rqF -- "$NOTIFY_CRED" "$GITHUB_STEP_SUMMARY" "$MOCK_DIR/posted"
}

@test "the credentials are taken out of the environment: no child process inherits one it was not handed" {
  # shellcheck source=../../../scripts/lib/budget-breaker.sh
  source "$DECISION_LIB"
  # shellcheck source=../../../scripts/lib/budget-breaker-writer.sh
  source "$WRITER_LIB"
  bbw_take_credentials
  # (The stub's own MOCK_* copies are test scaffolding, not the script's.)
  run env -u MOCK_WRITE_CRED -u MOCK_READ_CRED -u MOCK_NOTIFY_CRED env
  [[ "$output" != *"$WRITE_CRED"* ]]
  [[ "$output" != *"$READ_CRED"* ]]
  [[ "$output" != *"$NOTIFY_CRED"* ]]
  [[ "$output" != *"$AMBIENT"* ]]
  # A call without a credential is refused before gh runs.
  : > "$MOCK_DIR/calls.log"
  bbw_drop_write_credentials
  run bbw_read_org_vars acme
  [ "$status" -ne 0 ]
  [ ! -s "$MOCK_DIR/calls.log" ]
}

# ── AC #4: anti-flap ─────────────────────────────────────────────────────────

@test "anti-flap: two consecutive runs on the same evidence write once and notify once" {
  armed
  seed_quota
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(writes | wc -l | tr -d ' ')" = "3" ]
  : > "$MOCK_DIR/writes.log"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: hold"* ]]
  no_writes
  [ "$(find "$MOCK_DIR/posted" -type f | wc -l | tr -d ' ')" = "1" ]
}

@test "anti-flap: a step whose target already holds the wanted value is not written again" {
  armed
  seed_quota
  # Left behind by a trip that failed before it reached the pause switch.
  set_vars "$(var AI_ENGINES claude all)" "$(var AGENTS_PAUSE_SOURCE rate-limit-observed all -600)" \
    "$(var AGENTS_PAUSE_UNTIL "$(ts "$TRIP_UNTIL_OFFSET")" all -600)"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(writes)" = "POST AGENTS_PAUSED=true visibility=all" ]
}

@test "a source of the breaker's left on an unpaused fleet is warned about every run, and not written away" {
  armed
  set_vars "$(var AI_ENGINES claude all)" "$(var AGENTS_PAUSED false all -600)" \
    "$(var AGENTS_PAUSE_SOURCE rate-limit-observed all -7200)" "$(var AGENTS_PAUSE_UNTIL "$(ts -600)" all -7200)"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: none"* ]]
  [[ "$output" == *"::warning::budget-breaker: AGENTS_PAUSE_SOURCE=rate-limit-observed is set while the fleet is not paused"* ]]
  no_writes
  no_notice
  # No such warning for a clean, quiet fleet.
  set_vars "$(var AI_ENGINES claude all)"
  run bash "$SCRIPT"
  [[ "$output" != *"is set while the fleet is not paused"* ]]
}

@test "anti-flap: a resume before the minimum hold does not write; after it, it does" {
  armed
  # The pause was set 10 minutes ago and its until has already passed.
  own_pause -60 -600
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: resume"* ]]
  [[ "$output" == *"resume deferred by the minimum hold"* ]]
  [[ "$output" == *"1200s of the 30 min hold remain"* ]]
  no_writes
  no_notice
  [ "$(org_var AGENTS_PAUSED)" = "true" ]

  # 31 minutes after it was set, the same state resumes.
  own_pause -60 -1860
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(writes | head -n 1)" = "PATCH AGENTS_PAUSED=false" ]
}

@test "anti-flap: the minimum hold is configurable, and an unreadable one falls back to 30 minutes" {
  armed
  own_pause -60 -600
  BUDGET_BREAKER_MIN_HOLD_MIN=5 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(writes | head -n 1)" = "PATCH AGENTS_PAUSED=false" ]

  own_pause -60 -600
  : > "$MOCK_DIR/writes.log"
  BUDGET_BREAKER_MIN_HOLD_MIN="soon" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUDGET_BREAKER_MIN_HOLD_MIN is not a whole number of minutes; using 30"* ]]
  no_writes
}

@test "bbw_hold_remaining: seconds left of the hold, and 0 on any unreadable input (fail open)" {
  # shellcheck source=../../../scripts/lib/budget-breaker.sh
  source "$DECISION_LIB"
  # shellcheck source=../../../scripts/lib/budget-breaker-writer.sh
  source "$WRITER_LIB"
  [ "$(bbw_hold_remaining "$(ts -600)" "$NOW" 30)" = "1200" ]
  [ "$(bbw_hold_remaining "$(ts -1800)" "$NOW" 30)" = "0" ]
  [ "$(bbw_hold_remaining "$(ts -7200)" "$NOW" 30)" = "0" ]
  [ "$(bbw_hold_remaining "" "$NOW" 30)" = "0" ]
  [ "$(bbw_hold_remaining "yesterday" "$NOW" 30)" = "0" ]
  [ "$(bbw_hold_remaining "$(ts -600)" "noon" 30)" = "0" ]
  [ "$(bbw_hold_remaining "$(ts -600)" "$NOW" "")" = "0" ]
  [ "$(bbw_hold_remaining "$(ts -600)" "$NOW" 0)" = "0" ]
}

# ── AC #5: ordering under failure, and the single actionable error ───────────

@test "403 on the first write: ONE actionable error naming the permission, a red run, nothing else attempted" {
  armed
  seed_quota
  export MOCK_FAIL_ON=AGENTS_PAUSE_SOURCE MOCK_FAIL_STATUS=403
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(grep -c '::error::' <<< "$output")" = "1" ]
  [[ "$output" == *"HTTP 403"* ]]
  [[ "$output" == *"The token in ${PAT_NAME} must be a fine-grained personal access token"* ]]
  [[ "$output" == *'organisation permission "Variables: read and write"'* ]]
  [[ "$output" == *"Nothing is retried in this run"* ]]
  # One attempt, no retry, and nothing after the failed step.
  [ "$(writes)" = "FAILED POST AGENTS_PAUSE_SOURCE=rate-limit-observed visibility=all" ]
  [ "$(org_var AGENTS_PAUSED)" = "<absent>" ]
  no_notice
  grep -q 'FAILED at step' "$GITHUB_STEP_SUMMARY"
}

@test "trip failing at the pause switch: source and until are set, the fleet is not paused, so no unowned pause" {
  armed
  seed_quota
  export MOCK_FAIL_ON=AGENTS_PAUSED MOCK_FAIL_STATUS=404
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(grep -c '::error::' <<< "$output")" = "1" ]
  [[ "$output" == *"HTTP 404"* ]]
  [[ "$output" == *"Completed before the failure: AGENTS_PAUSE_SOURCE=rate-limit-observed"* ]]
  [ "$(writes | tail -n 1)" = "FAILED POST AGENTS_PAUSED=true visibility=all" ]
  [ "$(org_var AGENTS_PAUSED)" = "<absent>" ]
  [ "$(org_var AGENTS_PAUSE_SOURCE)" = "rate-limit-observed" ]
  no_notice
}

@test "resume failing after the pause is lifted: the fleet runs, and a pause is never left without its source" {
  armed
  own_pause -60
  export MOCK_FAIL_ON=AGENTS_PAUSE_SOURCE MOCK_FAIL_STATUS=500
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(grep -c '::error::' <<< "$output")" = "1" ]
  [[ "$output" == *"HTTP 500"* ]]
  [ "$(writes)" = "PATCH AGENTS_PAUSED=false
FAILED DELETE AGENTS_PAUSE_SOURCE" ]
  [ "$(org_var AGENTS_PAUSED)" = "false" ]
  no_notice
}

@test "resume failing at the pause switch: nothing else is touched, the pause keeps its source" {
  armed
  own_pause -60
  export MOCK_FAIL_ON=AGENTS_PAUSED
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(writes)" = "FAILED PATCH AGENTS_PAUSED=false" ]
  [ "$(org_var AGENTS_PAUSED)" = "true" ]
  [ "$(org_var AGENTS_PAUSE_SOURCE)" = "rate-limit-observed" ]
}

@test "a refused credential on the state read (401, 403, 404) is the same single actionable error, never a silent no-op" {
  local code
  armed
  seed_quota
  for code in 401 403 404; do
    MOCK_LIST_FAIL_STATUS="$code" run bash "$SCRIPT"
    [ "$status" -eq 1 ] || { echo "HTTP $code: status=$status"; false; }
    [ "$(grep -c '::error::' <<< "$output")" = "1" ]
    [[ "$output" == *"HTTP ${code}"* ]]
    [[ "$output" == *"The token in ${PAT_NAME} must be"* ]]
    [[ "$output" == *"No variable was written"* ]]
    no_writes
  done
}

@test "a notice that cannot be posted fails the run, after the state was written" {
  armed
  seed_quota
  export MOCK_COMMENT_FAIL=1
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(org_var AGENTS_PAUSED)" = "true" ]
  [ "$(grep -c '::error::' <<< "$output")" = "1" ]
  [[ "$output" == *"the notice could not be posted"* ]]
}

# ── slice 3a carry-over: which markers count, and who reads them ─────────────

@test "untrusted: every marker dropped as untrusted means no trip, with a visible warning and the count" {
  armed
  # The same three refusals, but the reader does not see their author as a
  # member (the wrong read credential): CONTRIBUTOR, NONE.
  seed_comments acme/app "$(comment ci 11 CONTRIBUTOR)" "$(comment reviews 12 NONE)" "$(comment issue 13 CONTRIBUTOR)"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"quota markers read: 0 trusted, 3 dropped as untrusted"* ]]
  [[ "$output" == *"::warning::budget-breaker: every quota marker seen (3) was dropped as untrusted"* ]]
  [[ "$output" == *"the breaker can never trip"* ]]
  # The collector's own per-repository warning is replayed too.
  [[ "$output" == *"acme/app: ignored 3 quota marker(s)"* ]]
  [[ "$output" == *"decision: none"* ]]
  no_writes
  no_notice
  grep -q '0 trusted, 3 dropped as untrusted' "$GITHUB_STEP_SUMMARY"
}

@test "untrusted: dropped markers are counted across repositories, next to the trusted ones" {
  armed
  seed_comments acme/app "$(comment ci 11)" "$(comment reviews 12 NONE)"
  seed_comments acme/lib "$(comment issue 13 CONTRIBUTOR)" "$(comment ci 14 FIRST_TIME_CONTRIBUTOR)"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"quota markers read: 1 trusted, 3 dropped as untrusted"* ]]
  [[ "$output" != *"every quota marker seen"* ]]
  no_writes
}

@test "untrusted: OWNER, MEMBER and COLLABORATOR are the trusted authors" {
  armed
  seed_comments acme/app "$(comment ci 11 OWNER)" "$(comment reviews 12 MEMBER)" "$(comment issue 13 COLLABORATOR)"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"quota markers read: 3 trusted, 0 dropped as untrusted"* ]]
  [[ "$output" == *"decision: trip"* ]]
}

@test "bbw_untrusted_count reads the real collector's warning (a reworded warning fails here)" {
  # shellcheck source=../../../scripts/lib/budget-breaker.sh
  source "$DECISION_LIB"
  # shellcheck source=../../../scripts/lib/budget-breaker-writer.sh
  source "$WRITER_LIB"
  local err="$BATS_TEST_TMPDIR/collector.err"
  printf '%s\n' "$(comment ci 11 NONE)" "$(comment ci 12 NONE)" | jq -cs '.' \
    | bb_observations_from_comments acme/app 2> "$err" >/dev/null
  printf '%s\n' "$(comment ci 13 NONE)" | jq -cs '.' \
    | bb_observations_from_comments acme/lib 2>> "$err" >/dev/null
  [ "$(bbw_untrusted_count "$err")" = "3" ]
  [ "$(bbw_untrusted_count "$BATS_TEST_TMPDIR/absent")" = "0" ]
}

@test "pr-review's rate-limited marker is never counted, even when the environment tries to opt it in" {
  armed
  seed_comments acme/app "$(comment advisory 11)" "$(comment advisory 12)" "$(comment advisory 13)"
  BUDGET_BREAKER_MARKER_KINDS="dev-lead-fix-ci dev-lead-fix-reviews dev-lead-issue pr-review-advisory" \
    run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"quota markers read: 0 trusted, 0 dropped as untrusted"* ]]
  [[ "$output" == *"decision: none"* ]]
  no_writes
}

@test "the organisation is scanned with the read credential only, forks excluded" {
  seed_quota
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(calls_by read | grep -c 'repo list acme')" = "1" ]
  [ "$(calls_by read | grep -c 'repos/acme/app/issues/comments')" = "1" ]
  [ "$(calls_by read | grep -c 'repos/acme/lib/issues/comments')" = "1" ]
  [ "$(grep -c 'acme/fork' "$MOCK_DIR/calls.log")" = "0" ]
  [ "$(grep -E 'repo list|issues/comments' "$MOCK_DIR/calls.log" | grep -vcE $'^read\t')" = "0" ]
}

# ── the write secret's age (maintainer note on #2153: the token has no expiry) ─

@test "secret age: logged when the API exposes it, a warning past the rotation policy, silent failure otherwise" {
  jq -cn --arg u "$(ts $(( -10 * 86400 )))" '{name: "x", created_at: $u, updated_at: $u}' > "$MOCK_DIR/secret.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"age of ${PAT_NAME}: last updated 10 day(s) ago"* ]]
  [ "$(calls_by read | grep -c "actions/secrets/${PAT_NAME}")" = "1" ]

  jq -cn --arg u "$(ts $(( -120 * 86400 )))" '{name: "x", created_at: $u, updated_at: $u}' > "$MOCK_DIR/secret.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::budget-breaker: ${PAT_NAME} was last updated 120 day(s) ago"* ]]
  [[ "$output" == *"rotation policy is every 90 days"* ]]

  rm -f "$MOCK_DIR/secret.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"age of ${PAT_NAME}: not available"* ]]
  [[ "$output" != *"::error::"* ]]
}

# ── job summary ──────────────────────────────────────────────────────────────

@test "job summary: mode, state, markers, decision, plan and result on every run" {
  armed
  seed_quota
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^## Budget breaker' "$GITHUB_STEP_SUMMARY"
  grep -q '| Mode | armed |' "$GITHUB_STEP_SUMMARY"
  grep -q '| Quota markers | 3 trusted, 0 dropped as untrusted |' "$GITHUB_STEP_SUMMARY"
  grep -q '| Decision | trip (evidence_count=3)' "$GITHUB_STEP_SUMMARY"
  grep -q 'notice posted on #77' "$GITHUB_STEP_SUMMARY"
}

# ── AC #6: static ────────────────────────────────────────────────────────────

@test "static: the write secret is named only in the breaker workflow, this test and the docs" {
  local files f
  cd "$REPO_ROOT"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    files="$(git grep -l --untracked -F "$PAT_NAME" -- . || true)"
  else
    files="$(grep -rlF "$PAT_NAME" --exclude-dir=.git . | sed 's|^\./||' || true)"
  fi
  # It IS named where it must be, so the search above is not vacuous.
  grep -qx '.github/workflows/budget-breaker.yml' <<< "$files"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      .github/workflows/budget-breaker.yml) ;;
      tests/dev-lead/unit/test_budget_breaker_writer.bats) ;;
      AGENTS.md|docs/*) ;;
      *) echo "the write secret is named in: $f"; false ;;
    esac
  done <<< "$files"
}

@test "static: the workflow reads the secret in exactly one place, the script step's env, and only when armed" {
  [ "$(grep -c "secrets\.${PAT_NAME}" "$WORKFLOW")" = "1" ]
  grep -qE "^          BUDGET_BREAKER_TOKEN: \\$\\{\\{ vars\\.BUDGET_BREAKER_ARMED == 'true' && secrets\\.${PAT_NAME} \\|\\| '' \\}\\}\$" "$WORKFLOW"
  # The workflow token is withheld the same way.
  grep -qE "^          BUDGET_BREAKER_NOTIFY_TOKEN: \\$\\{\\{ vars\\.BUDGET_BREAKER_ARMED == 'true' && github\\.token \\|\\| '' \\}\\}\$" "$WORKFLOW"
  # No secret is interpolated into a script body, and the secret is never the
  # generic gh credential of a step.
  run grep -nE '^[[:space:]]+(GH_TOKEN|GITHUB_TOKEN):' "$WORKFLOW"
  [ "$status" -eq 1 ]
  [ "$(grep -cE '^[[:space:]]+run:' "$WORKFLOW")" = "1" ]
  grep -qE '^[[:space:]]+run: bash scripts/budget_breaker\.sh$' "$WORKFLOW"
  # The read credential is the fleet's scan credential, never the write secret
  # and never this repository's workflow token.
  grep -qE '^          BUDGET_BREAKER_READ_TOKEN: \$\{\{ secrets\.GH_PAT_DON_PETRY \|\| secrets\.GH_PAT_WORKFLOWS \}\}$' "$WORKFLOW"
  # The marker kinds are not configurable from the workflow.
  run grep -n 'BUDGET_BREAKER_MARKER_KINDS' "$WORKFLOW"
  [ "$status" -eq 1 ]
}

@test "static: the workflow is schedule-only with minimal permissions, a pinned checkout and no credential left behind" {
  # `on:` has exactly one trigger, schedule.
  local triggers
  triggers="$(awk '/^on:/ {f=1; next} f && /^[A-Za-z]/ {f=0} f && /^  [A-Za-z_]+:/ {sub(/^  /, ""); sub(/:.*/, ""); print}' "$WORKFLOW")"
  [ "$triggers" = "schedule" ]
  run grep -nE '^[[:space:]]*(workflow_dispatch|pull_request|pull_request_target|push|workflow_call|workflow_run|repository_dispatch|issue_comment):' "$WORKFLOW"
  [ "$status" -eq 1 ]
  # Off the top of the hour.
  run grep -nE "cron:[[:space:]]*['\"]0[[:space:]]" "$WORKFLOW"
  [ "$status" -eq 1 ]

  # Top-level permissions are exactly contents: read and issues: write, and no
  # job widens them.
  local perms
  perms="$(awk '/^permissions:/ {f=1; next} f && /^[A-Za-z]/ {f=0} f && /^  [a-z-]+:/ {sub(/^  /, ""); sub(/[[:space:]]*#.*/, ""); print}' "$WORKFLOW")"
  [ "$perms" = "contents: read
issues: write" ]
  [ "$(grep -cE '^[[:space:]]*permissions:' "$WORKFLOW")" = "1" ]
  run grep -nE 'write-all' "$WORKFLOW"
  [ "$status" -eq 1 ]

  # Every action is pinned to a full commit SHA, and the checkout keeps no token.
  [ "$(grep -cE '^[[:space:]]+uses:' "$WORKFLOW")" = "1" ]
  run grep -nE '^[[:space:]]+uses:' "$WORKFLOW"
  [[ "$output" =~ uses:\ actions/checkout@[0-9a-f]{40}[[:space:]] ]]
  grep -qE '^[[:space:]]+persist-credentials: false$' "$WORKFLOW"
  # It checks out the default branch only: no ref, no other repository.
  run grep -nE '^[[:space:]]+(ref|repository):' "$WORKFLOW"
  [ "$status" -eq 1 ]
  grep -qE '^[[:space:]]+timeout-minutes: [0-9]+$' "$WORKFLOW"
  grep -qE '^  group: budget-breaker$' "$WORKFLOW"
}

@test "static: the dry-run poller still has no write path and does not see the breaker's secret" {
  local f
  for f in "$POLLER_WORKFLOW" "$POLLER" "$POLLER_LIB"; do
    [ -f "$f" ]
    run grep -nE 'AGENTS_PAUSED|AGENTS_PAUSE_SOURCE|AGENTS_PAUSE_UNTIL' "$f"
    [ "$status" -eq 1 ]
    run grep -nE 'gh[[:space:]]+variable[[:space:]]+(set|delete)' "$f"
    [ "$status" -eq 1 ]
    run grep -niE 'actions/variables' "$f"
    [ "$status" -eq 1 ]
    run grep -nE '(-X|--method)[[:space:]]*(POST|PUT|PATCH|DELETE)' "$f"
    [ "$status" -eq 1 ]
    run grep -nE 'BUDGET_BREAKER|budget-breaker-writer|budget_breaker\.sh' "$f"
    [ "$status" -eq 1 ]
  done
  # Read-only permissions, schedule only, unchanged.
  run grep -nE '^[[:space:]]+[a-z-]+:[[:space:]]*write([[:space:]]|$)' "$POLLER_WORKFLOW"
  [ "$status" -eq 1 ]
  run grep -nE '^  workflow_dispatch:' "$POLLER_WORKFLOW"
  [ "$status" -eq 1 ]
}

@test "static: the variables API is written from one file only, and always with the write credential" {
  local f offenders=""
  cd "$REPO_ROOT"
  while IFS= read -r f; do
    case "$f" in
      scripts/lib/budget-breaker-writer.sh) ;;
      *) offenders="${offenders}${f}"$'\n' ;;
    esac
  done < <(grep -rlE 'actions/variables|gh[[:space:]]+variable[[:space:]]+(set|delete)' scripts .github/workflows || true)
  [ -z "$offenders" ] || { echo "the variables API is used outside the writer library:"; echo "$offenders"; false; }

  # Every write method in the writer library is a call made with the write
  # credential, and the three write calls are all there is.
  [ "$(grep -cE -- '-X (PATCH|POST|DELETE)' "$WRITER_LIB")" = "3" ]
  run grep -nE -- '-X (PATCH|POST|DELETE)' "$WRITER_LIB"
  while IFS= read -r f; do
    [[ "$f" == *'_bbw_gh "$_BBW_WRITE_CRED" api -X '* ]] || { echo "a write not made with the write credential: $f"; false; }
  done <<< "$output"
  # No typed field (which would send `true` as a boolean), and no bare gh call:
  # every gh invocation goes through _bbw_gh with a named credential.
  run grep -nE '[[:space:]](-F|--field|--input)[[:space:]]' "$WRITER_LIB" "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(grep -cE '^[^#]*[^_[:alnum:]]gh "\$@"' "$WRITER_LIB")" = "1" ]
  run grep -nE '^[^#]*(^|[^_[:alnum:]-])gh[[:space:]]+(api|issue|label|repo|variable|secret|pr|workflow)' "$WRITER_LIB" "$SCRIPT"
  [ "$status" -eq 1 ]
  # The script never names the credential variables after handing them over.
  run grep -nE 'GH_TOKEN|GITHUB_TOKEN' "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "static: the script pins the marker kinds to the library default before anything reads them" {
  local unset_line source_line collect_line
  unset_line="$(grep -nE '^unset BUDGET_BREAKER_MARKER_KINDS$' "$SCRIPT" | cut -d: -f1)"
  [ -n "$unset_line" ]
  collect_line="$(grep -nE 'bbw_collect ' "$SCRIPT" | head -n 1 | cut -d: -f1)"
  [ "$unset_line" -lt "$collect_line" ]
  # ... and the default itself is still the three dev-lead kinds.
  source_line="$(grep -E '^BUDGET_BREAKER_MARKER_KINDS_DEFAULT=' "$DECISION_LIB")"
  [ "$source_line" = 'BUDGET_BREAKER_MARKER_KINDS_DEFAULT="dev-lead-fix-ci dev-lead-fix-reviews dev-lead-issue"' ]
}

@test "shellcheck: the writer script and library are clean" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  cd "$REPO_ROOT"
  run shellcheck --severity=warning -x scripts/budget_breaker.sh scripts/lib/budget-breaker-writer.sh
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# ═════════════════════════════════════════════════════════════════════════════
# #2251: the gaps closed before the breaker is armed
# ═════════════════════════════════════════════════════════════════════════════

# human_pauses_after <variable> — a maintainer sets AGENTS_PAUSED=true by hand
# right after the breaker's write of <variable>.
human_pauses_after() {
  export MOCK_HUMAN_AFTER_WRITE="$1"
  export MOCK_HUMAN_JQ='.AGENTS_PAUSED = {name: "AGENTS_PAUSED", value: "true", visibility: "all", created_at: $u, updated_at: $u}'
}

# listings — how many times the organisation's variables were listed.
listings() { grep -c 'actions/variables?per_page=30' "$MOCK_DIR/calls.log" || true; }

# posted — how many notices the stub has posted.
posted() { find "$MOCK_DIR/posted" -type f | wc -l | tr -d ' '; }

# fillers <n> — n unrelated organisation variables.
fillers() {
  local i
  for (( i = 1; i <= $1; i++ )); do
    var "FILLER_${i}" x all
  done
}

# own_pause_stamped <until_offset_sec> <jq_filter> — an own pause whose
# AGENTS_PAUSED variable is put through <jq_filter> (to break its updated_at).
own_pause_stamped() {
  set_vars "$(var AI_ENGINES claude all)" \
    "$(var AGENTS_PAUSE_SOURCE rate-limit-observed all -7200)" \
    "$(var AGENTS_PAUSE_UNTIL "$(ts "$1")" all -7200)" \
    "$(var AGENTS_PAUSED true all -7200 | jq -c "$2")"
}

# ── item 1: the race with a pause set by hand ────────────────────────────────

@test "race: a human pause that lands after the source and until are written is not claimed; both are taken back and nothing else is set" {
  armed
  seed_quota
  human_pauses_after AGENTS_PAUSE_UNTIL
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: trip"* ]]
  # Source, until, then the second look: the fleet is paused by someone else,
  # so the pause is never written and the two values go, the source first.
  [ "$(writes)" = "POST AGENTS_PAUSE_SOURCE=rate-limit-observed visibility=all
POST AGENTS_PAUSE_UNTIL=$(ts "$TRIP_UNTIL_OFFSET") visibility=all
DELETE AGENTS_PAUSE_SOURCE
DELETE AGENTS_PAUSE_UNTIL" ]
  [ "$(org_var AGENTS_PAUSED)" = "true" ]
  [ "$(org_var AGENTS_PAUSE_SOURCE)" = "<absent>" ]
  [ "$(org_var AGENTS_PAUSE_UNTIL)" = "<absent>" ]
  [[ "$output" == *"::warning::budget-breaker: the fleet was paused by someone else while this run was tripping"* ]]
  [[ "$output" == *"Removed what this run had written: deleted AGENTS_PAUSE_SOURCE; deleted AGENTS_PAUSE_UNTIL"* ]]
  [[ "$output" != *"::error::"* ]]
  [[ "$output" != *"fleet PAUSED until"* ]]
  no_notice
  [ "$(listings)" = "3" ]
  grep -q 'no pause set: trip stopped (paused)' "$GITHUB_STEP_SUMMARY"
  assert_no_credential_anywhere

  # What is left is a human pause: the next run leaves it exactly as it is.
  : > "$MOCK_DIR/writes.log"
  cp "$MOCK_DIR/vars.json" "$BATS_TEST_TMPDIR/before.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a human pause is never tripped over and never resumed"* ]]
  no_writes
  cmp "$MOCK_DIR/vars.json" "$BATS_TEST_TMPDIR/before.json"
}

@test "race: a human pause that lands between the source and the until writes is caught by the same look" {
  armed
  seed_quota
  human_pauses_after AGENTS_PAUSE_SOURCE
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(writes)" = "POST AGENTS_PAUSE_SOURCE=rate-limit-observed visibility=all
POST AGENTS_PAUSE_UNTIL=$(ts "$TRIP_UNTIL_OFFSET") visibility=all
DELETE AGENTS_PAUSE_SOURCE
DELETE AGENTS_PAUSE_UNTIL" ]
  [ "$(org_var AGENTS_PAUSED)" = "true" ]
  [ "$(org_var AGENTS_PAUSE_SOURCE)" = "<absent>" ]
  no_notice
}

@test "race, the other order: a pause set by hand before the first write is seen by the first look and nothing is written at all" {
  armed
  seed_quota
  printf '%s\n' "$(var AI_ENGINES claude all)" "$(var AGENTS_PAUSED true all 0)" \
    | jq -cs 'map({key: .name, value: .}) | from_entries' > "$BATS_TEST_TMPDIR/human.json"
  export MOCK_FLIP_AFTER_LIST="$BATS_TEST_TMPDIR/human.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"the pause state changed while this run was deciding"* ]]
  no_writes
  no_notice
  # Two looks, not three: the second look only follows a write of this run.
  [ "$(listings)" = "2" ]
}

@test "race: the second look is taken only when this run wrote a source or an until" {
  armed
  seed_quota
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(org_var AGENTS_PAUSED)" = "true" ]
  [ "$(listings)" = "3" ]

  # Source and until already as wanted (a trip that failed at the switch): the
  # look before the first write IS the look before the pause.
  set_vars "$(var AI_ENGINES claude all)" "$(var AGENTS_PAUSE_SOURCE rate-limit-observed all -600)" \
    "$(var AGENTS_PAUSE_UNTIL "$(ts "$TRIP_UNTIL_OFFSET")" all -600)"
  : > "$MOCK_DIR/calls.log"
  : > "$MOCK_DIR/writes.log"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(writes)" = "POST AGENTS_PAUSED=true visibility=all" ]
  [ "$(listings)" = "2" ]
}

@test "race: a source that someone deleted before the pause was set does not leave a pause without its source" {
  armed
  seed_quota
  export MOCK_HUMAN_AFTER_WRITE=AGENTS_PAUSE_UNTIL MOCK_HUMAN_JQ='del(.AGENTS_PAUSE_SOURCE)'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::budget-breaker: the pause state changed while this run was tripping"* ]]
  # The pause is never set; the source is no longer this run's to delete, the
  # until still is.
  [ "$(writes)" = "POST AGENTS_PAUSE_SOURCE=rate-limit-observed visibility=all
POST AGENTS_PAUSE_UNTIL=$(ts "$TRIP_UNTIL_OFFSET") visibility=all
DELETE AGENTS_PAUSE_UNTIL" ]
  [[ "$output" == *"Left as found: AGENTS_PAUSE_SOURCE (it no longer holds the value this run wrote)"* ]]
  [ "$(org_var AGENTS_PAUSED)" = "<absent>" ]
  [ "$(org_var AGENTS_PAUSE_UNTIL)" = "<absent>" ]
  no_notice
}

@test "race, roll-back failing at the source: ONE error, the until is left on purpose, and the error says what to delete" {
  armed
  seed_quota
  human_pauses_after AGENTS_PAUSE_UNTIL
  export MOCK_FAIL_DELETE=AGENTS_PAUSE_SOURCE MOCK_FAIL_STATUS=500
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(grep -c '::error::' <<< "$output")" = "1" ]
  [[ "$output" == *"Taking back a trip that was stopped before the pause was set (step: delete AGENTS_PAUSE_SOURCE) failed (HTTP 500"* ]]
  [[ "$output" == *"AGENTS_PAUSE_SOURCE=rate-limit-observed is STILL SET"* ]]
  [[ "$output" == *"Delete AGENTS_PAUSE_SOURCE by hand now"* ]]
  # One attempt, no retry, and the until is NOT deleted: a pause that carries
  # the breaker's source with no end time would be lifted by the next run.
  [ "$(writes)" = "POST AGENTS_PAUSE_SOURCE=rate-limit-observed visibility=all
POST AGENTS_PAUSE_UNTIL=$(ts "$TRIP_UNTIL_OFFSET") visibility=all
FAILED DELETE AGENTS_PAUSE_SOURCE" ]
  [ "$(org_var AGENTS_PAUSE_UNTIL)" = "$(ts "$TRIP_UNTIL_OFFSET")" ]
  no_notice
  grep -q 'roll-back failed at: delete AGENTS_PAUSE_SOURCE' "$GITHUB_STEP_SUMMARY"
}

@test "race, roll-back failing at the until: ONE error, and what is left is a human pause that the next run leaves alone" {
  armed
  seed_quota
  human_pauses_after AGENTS_PAUSE_UNTIL
  export MOCK_FAIL_DELETE=AGENTS_PAUSE_UNTIL
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(grep -c '::error::' <<< "$output")" = "1" ]
  [[ "$output" == *"AGENTS_PAUSE_UNTIL is left over and has no effect without the source"* ]]
  [ "$(writes)" = "POST AGENTS_PAUSE_SOURCE=rate-limit-observed visibility=all
POST AGENTS_PAUSE_UNTIL=$(ts "$TRIP_UNTIL_OFFSET") visibility=all
DELETE AGENTS_PAUSE_SOURCE
FAILED DELETE AGENTS_PAUSE_UNTIL" ]
  [ "$(org_var AGENTS_PAUSED)" = "true" ]
  [ "$(org_var AGENTS_PAUSE_SOURCE)" = "<absent>" ]
  no_notice

  unset MOCK_FAIL_DELETE
  : > "$MOCK_DIR/writes.log"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a human pause is never tripped over and never resumed"* ]]
  no_writes
}

@test "race with a source an earlier run left: it is not this run's to remove, so the run fails loudly and removes nothing" {
  armed
  seed_quota
  # A trip that failed at the switch left the source and an older until.
  set_vars "$(var AI_ENGINES claude all)" "$(var AGENTS_PAUSE_SOURCE rate-limit-observed all -600)" \
    "$(var AGENTS_PAUSE_UNTIL "$(ts 600)" all -600)"
  human_pauses_after AGENTS_PAUSE_UNTIL
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(grep -c '::error::' <<< "$output")" = "1" ]
  [[ "$output" == *"was already set before this run (an earlier run left it; this run did not write it, so it does not remove it)"* ]]
  [[ "$output" == *"To keep the pause, delete AGENTS_PAUSE_SOURCE"* ]]
  [ "$(writes)" = "PATCH AGENTS_PAUSE_UNTIL=$(ts "$TRIP_UNTIL_OFFSET")" ]
  [ "$(org_var AGENTS_PAUSE_SOURCE)" = "rate-limit-observed" ]
  [ "$(org_var AGENTS_PAUSE_UNTIL)" = "$(ts "$TRIP_UNTIL_OFFSET")" ]
  no_notice
}

@test "race: a second look that cannot read takes back what the run wrote and never sets the pause" {
  armed
  seed_quota
  export MOCK_LIST_FAIL_FROM=3
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::budget-breaker: the state could not be read again before the pause was set (HTTP 502"* ]]
  [[ "$output" != *"::error::"* ]]
  [ "$(writes)" = "POST AGENTS_PAUSE_SOURCE=rate-limit-observed visibility=all
POST AGENTS_PAUSE_UNTIL=$(ts "$TRIP_UNTIL_OFFSET") visibility=all
DELETE AGENTS_PAUSE_SOURCE
DELETE AGENTS_PAUSE_UNTIL" ]
  [ "$(org_var AGENTS_PAUSED)" = "<absent>" ]
  [ "$(org_var AGENTS_PAUSE_SOURCE)" = "<absent>" ]
  no_notice

  # A refused credential on that read is the single actionable error.
  rm -f "$MOCK_DIR/listings"
  : > "$MOCK_DIR/writes.log"
  export MOCK_LIST_FAIL_FROM_STATUS=403
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(grep -c '::error::' <<< "$output")" = "1" ]
  [[ "$output" == *"Reading the organisation's Actions variables again before setting the pause failed (HTTP 403"* ]]
  [[ "$output" == *"The token in ${PAT_NAME} must be"* ]]
  [ "$(org_var AGENTS_PAUSED)" = "<absent>" ]
  [ "$(org_var AGENTS_PAUSE_SOURCE)" = "<absent>" ]
  [ "$(org_var AGENTS_PAUSE_UNTIL)" = "<absent>" ]
}

# ── item 2: pagination of the variable listing ───────────────────────────────

@test "pagination: the stub serves 30 variables a page, and the second page only with --paginate" {
  local -a extra
  mapfile -t extra < <(fillers 29)
  set_vars "$(var AI_ENGINES claude all)" "${extra[@]}" "$(var AGENTS_PAUSED true all -7200)" "$(var LAST x all)"
  run env GH_TOKEN="$WRITE_CRED" gh api "orgs/acme/actions/variables?per_page=30" --jq '.variables[] | .name'
  [ "$status" -eq 0 ]
  [ "$(wc -l <<< "$output" | tr -d ' ')" = "30" ]
  [[ "$output" != *"AGENTS_PAUSED"* ]]
  run env GH_TOKEN="$WRITE_CRED" gh api --paginate "orgs/acme/actions/variables?per_page=30" --jq '.variables[] | .name'
  [ "$status" -eq 0 ]
  [ "$(wc -l <<< "$output" | tr -d ' ')" = "32" ]
  [ "$(tail -n 2 <<< "$output" | head -n 1)" = '"AGENTS_PAUSED"' ]
  # Every page reports the whole count, as the API does.
  run env GH_TOKEN="$WRITE_CRED" gh api --paginate "orgs/acme/actions/variables?per_page=30" --jq '.total_count'
  [ "$output" = "32
32" ]
}

@test "pagination: a human pause that is only on the second page of the listing is seen, and left alone" {
  local -a extra
  armed
  seed_quota
  mapfile -t extra < <(fillers 29)
  set_vars "$(var AI_ENGINES claude all)" "${extra[@]}" "$(var AGENTS_PAUSED true all -7200)"
  cp "$MOCK_DIR/vars.json" "$BATS_TEST_TMPDIR/before.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'[AGENTS_PAUSED, AGENTS_PAUSE_SOURCE, AGENTS_PAUSE_UNTIL] = ["true",null,null]'* ]]
  [[ "$output" == *"decision: none"* ]]
  [[ "$output" == *"a human pause is never tripped over and never resumed"* ]]
  no_writes
  no_notice
  cmp "$MOCK_DIR/vars.json" "$BATS_TEST_TMPDIR/before.json"
}

@test "pagination: an own pause whose source and until are on the second page is still the breaker's own" {
  local -a extra
  armed
  mapfile -t extra < <(fillers 28)
  set_vars "$(var AI_ENGINES claude all)" "${extra[@]}" "$(var AGENTS_PAUSED true all -7200)" \
    "$(var AGENTS_PAUSE_SOURCE rate-limit-observed all -7200)" "$(var AGENTS_PAUSE_UNTIL "$(ts -60)" all -7200)"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: resume"* ]]
  [ "$(writes)" = "PATCH AGENTS_PAUSED=false
DELETE AGENTS_PAUSE_SOURCE
DELETE AGENTS_PAUSE_UNTIL" ]
}

# ── item 3: the minimum hold when the time the switch was set cannot be read ──

@test "minimum hold: a missing or unusable updated_at defers the resume, measured from the pause's end time, and never blocks it" {
  local broken
  armed
  for broken in 'del(.updated_at)' '.updated_at = null' '.updated_at = ""' '.updated_at = "yesterday"' \
      '.updated_at = 12345' '.updated_at = "2099-01-01T00:00:00Z"'; do
    # The pause's end time passed a minute ago.
    own_pause_stamped -60 "$broken"
    : > "$MOCK_DIR/writes.log"
    : > "$MOCK_DIR/calls.log"
    rm -f "$MOCK_DIR"/posted/*
    run bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$broken: status=$status"; false; }
    [[ "$output" == *"decision: resume"* ]]
    [[ "$output" == *"::warning::budget-breaker: the time AGENTS_PAUSED was last set cannot be used"* ]] || { echo "$broken: no warning: $output"; false; }
    [[ "$output" == *"resume deferred by the minimum hold: measured from the pause's end time $(ts -60), 1740s of the 30 min hold remain"* ]] || { echo "$broken: not deferred: $output"; false; }
    no_writes
    no_notice
    [ "$(org_var AGENTS_PAUSED)" = "true" ]

    # One second short of the hold it still waits; at the hold it resumes.
    BUDGET_BREAKER_NOW=$(( NOW + 1739 )) run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1s of the 30 min hold remain"* ]]
    no_writes
    BUDGET_BREAKER_NOW=$(( NOW + 1740 )) run bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$broken: status=$status at the hold"; false; }
    [ "$(writes)" = "PATCH AGENTS_PAUSED=false
DELETE AGENTS_PAUSE_SOURCE
DELETE AGENTS_PAUSE_UNTIL" ] || { echo "$broken: did not resume: $(writes)"; false; }
  done
}

@test "minimum hold: with neither the set time nor an end time to measure from, the resume goes ahead (fail open)" {
  armed
  set_vars "$(var AI_ENGINES claude all)" \
    "$(var AGENTS_PAUSE_SOURCE rate-limit-observed all -7200)" \
    "$(var AGENTS_PAUSED true all -7200 | jq -c 'del(.updated_at)')"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::budget-breaker: minimum hold not evaluated: neither the time AGENTS_PAUSED was last set nor the pause's end time can be used"* ]]
  [ "$(writes)" = "PATCH AGENTS_PAUSED=false
DELETE AGENTS_PAUSE_SOURCE" ]
}

@test "minimum hold: a readable updated_at is still what the hold is measured from, with no warning" {
  armed
  own_pause -60 -600
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume deferred by the minimum hold: AGENTS_PAUSED was last set at $(ts -600), 1200s of the 30 min hold remain"* ]]
  [[ "$output" != *"cannot be used"* ]]
  no_writes
}

@test "bbw_time_not_after: only a well-formed time that is not later than now can start the hold" {
  # shellcheck source=../../../scripts/lib/budget-breaker.sh
  source "$DECISION_LIB"
  # shellcheck source=../../../scripts/lib/budget-breaker-writer.sh
  source "$WRITER_LIB"
  bbw_time_not_after "$(ts -600)" "$NOW"
  bbw_time_not_after "$(ts 0)" "$NOW"
  run ! bbw_time_not_after "$(ts 1)" "$NOW"
  run ! bbw_time_not_after "2099-01-01T00:00:00Z" "$NOW"
  run ! bbw_time_not_after "" "$NOW"
  run ! bbw_time_not_after "null" "$NOW"
  run ! bbw_time_not_after "yesterday" "$NOW"
  run ! bbw_time_not_after "2026-13-45T99:99:99Z" "$NOW"
  run ! bbw_time_not_after "$(ts -600)" "noon"
  run ! bbw_time_not_after "$(ts -600)" ""
}

# ── item 4: a notice that could not be posted ────────────────────────────────

@test "missing notice: the run after a trip whose notice failed posts it, exactly once" {
  armed
  seed_quota
  export MOCK_COMMENT_FAIL=1
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the notice could not be posted"* ]]
  [[ "$output" == *"A later run that holds this pause posts the missing notice, once"* ]]
  [ "$(org_var AGENTS_PAUSED)" = "true" ]
  [ "$(posted)" = "0" ]

  # The following run holds the pause, finds no notice of it and posts one.
  unset MOCK_COMMENT_FAIL
  : > "$MOCK_DIR/writes.log"
  cp "$MOCK_DIR/vars.json" "$BATS_TEST_TMPDIR/before.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: hold"* ]]
  [[ "$output" == *"::notice::budget-breaker: posted the missing notice of the pause until $(ts "$TRIP_UNTIL_OFFSET") on tracking issue #77"* ]]
  no_writes
  cmp "$MOCK_DIR/vars.json" "$BATS_TEST_TMPDIR/before.json"
  [ "$(posted)" = "1" ]
  [ "$(head -n 1 "$MOCK_DIR/posted/1-issue-77.md")" = "<!-- budget-breaker-notice kind=pause until=$(ts "$TRIP_UNTIL_OFFSET") -->" ]
  grep -q 'Fleet paused by the budget breaker (late notice)' "$MOCK_DIR/posted/1-issue-77.md"
  grep -qF "\`$(ts "$TRIP_UNTIL_OFFSET")\`" "$MOCK_DIR/posted/1-issue-77.md"
  grep -q 'posted the missing pause notice on #77' "$GITHUB_STEP_SUMMARY"

  # A third run finds that notice and posts nothing.
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: hold"* ]]
  [[ "$output" == *"the notice of this pause (until $(ts "$TRIP_UNTIL_OFFSET")) is on tracking issue #77"* ]]
  no_writes
  [ "$(posted)" = "1" ]
  # The look-up and the post are made with the workflow token, never the write
  # or the read credential.
  [ "$(grep -c 'issues/77/comments' "$MOCK_DIR/calls.log")" = "$(calls_by notify | grep -c 'issues/77/comments')" ]
  assert_no_credential_anywhere
}

@test "missing notice: a trip that did post is not announced a second time by the runs that hold it" {
  armed
  seed_quota
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(posted)" = "1" ]
  [ "$(head -n 1 "$MOCK_DIR/posted/1-issue-77.md")" = "<!-- budget-breaker-notice kind=pause until=$(ts "$TRIP_UNTIL_OFFSET") -->" ]
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: hold"* ]]
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(posted)" = "1" ]
}

@test "missing notice: a late notice that fails again, or a look-up that fails, is ONE error, a red run and no variable write" {
  armed
  seed_quota
  export MOCK_COMMENT_FAIL=1
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  : > "$MOCK_DIR/writes.log"
  cp "$MOCK_DIR/vars.json" "$BATS_TEST_TMPDIR/before.json"

  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision: hold"* ]]
  [ "$(grep -c '::error::' <<< "$output")" = "1" ]
  [[ "$output" == *"posting the missing notice failed again"* ]]
  no_writes
  [ "$(posted)" = "0" ]

  unset MOCK_COMMENT_FAIL
  export MOCK_NOTICE_LOOKUP_FAIL=1
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(grep -c '::error::' <<< "$output")" = "1" ]
  [[ "$output" == *"whether that pause was announced on the tracking issue in acme/.github-private could not be checked (HTTP 502"* ]]
  no_writes
  [ "$(posted)" = "0" ]
  cmp "$MOCK_DIR/vars.json" "$BATS_TEST_TMPDIR/before.json"
}

@test "missing notice: looked for only while the pause is under an hour old, or its age cannot be read" {
  armed
  # Set 59 minutes ago, never announced, no tracking issue yet: announced now.
  own_pause 1800 -3540
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: hold"* ]]
  [ "$(posted)" = "1" ]
  grep -qx 'dev-lead:hands-off' "$MOCK_DIR/issue-labels.txt"
  no_writes

  # Set 60 minutes ago: a settled pause is not looked up at all.
  rm -f "$MOCK_DIR"/posted/*
  printf '[]' > "$MOCK_DIR/issues.json"
  : > "$MOCK_DIR/calls.log"
  own_pause 1800 -3600
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: hold"* ]]
  no_writes
  no_notice

  # An age that cannot be read is looked up: a pause is never left unannounced
  # for want of a timestamp.
  own_pause_stamped 1800 'del(.updated_at)'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(posted)" = "1" ]
  no_writes
}

@test "bbw_pause_notice_posted: finds this pause's marker on a later page of comments, and only this pause's" {
  # shellcheck source=../../../scripts/lib/budget-breaker.sh
  source "$DECISION_LIB"
  # shellcheck source=../../../scripts/lib/budget-breaker-writer.sh
  source "$WRITER_LIB"
  bbw_take_credentials
  local i rc
  printf '[{"number":77,"title":"Budget breaker: automatic fleet pauses (tracking)"}]' > "$MOCK_DIR/issues.json"

  # No tracking issue comment at all.
  rc=0; bbw_pause_notice_posted acme/.github-private "$(ts 7200)" || rc=$?
  [ "$rc" -eq 1 ]

  # 100 other comments (one of them another pause's notice), then this one's:
  # it is the only comment on the second page.
  for (( i = 1; i <= 100; i++ )); do
    printf 'comment %s\n' "$i" > "$MOCK_DIR/posted/${i}-issue-77.md"
  done
  printf '%s\nan earlier pause\n' "$(bbw_pause_marker "$(ts 3600)")" > "$MOCK_DIR/posted/50-issue-77.md"
  rc=0; bbw_pause_notice_posted acme/.github-private "$(ts 7200)" || rc=$?
  [ "$rc" -eq 1 ]
  printf '%s\nthis pause\n' "$(bbw_pause_marker "$(ts 7200)")" > "$MOCK_DIR/posted/101-issue-77.md"
  rc=0; bbw_pause_notice_posted acme/.github-private "$(ts 7200)" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$BBW_TRACKING_NUMBER" = "77" ]
  rc=0; bbw_pause_notice_posted acme/.github-private "$(ts 3600)" || rc=$?
  [ "$rc" -eq 0 ]
  rc=0; bbw_pause_notice_posted acme/.github-private "$(ts 1800)" || rc=$?
  [ "$rc" -eq 1 ]

  # An end time that is not a time is never put into the filter: cannot tell.
  : > "$MOCK_DIR/calls.log"
  rc=0; bbw_pause_notice_posted acme/.github-private 'x") or true or ("' || rc=$?
  [ "$rc" -eq 2 ]
  [ ! -s "$MOCK_DIR/calls.log" ]
  # A look-up that fails cannot tell either.
  export MOCK_NOTICE_LOOKUP_FAIL=1
  rc=0; bbw_pause_notice_posted acme/.github-private "$(ts 7200)" || rc=$?
  [ "$rc" -eq 2 ]
}

# ── item 5: the arming value ─────────────────────────────────────────────────

@test "arming value: a value that is set but is not exactly true is ONE error line and a disarmed run" {
  local v
  seed_quota
  for v in TRUE True tRuE " true" "true " 1 yes on false " "; do
    : > "$MOCK_DIR/calls.log"
    BUDGET_BREAKER_ARMED="$v" run bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "armed='$v' status=$status"; false; }
    [ "$(grep -c '::error::' <<< "$output")" = "1" ] || { echo "armed='$v': not one error: $output"; false; }
    [[ "$output" == *"::error::budget-breaker: BUDGET_BREAKER_ARMED is set to \"${v}\", which is not the exact lowercase string true, so the breaker is DISARMED and writes nothing."* ]] || { echo "armed='$v': $output"; false; }
    [[ "$output" == *"NOT WRITING (disarmed)"* ]]
    # The credential the workflow would have handed over for TRUE is dropped.
    [[ "$output" == *"The workflow handed the write credential to this step all the same"* ]]
    no_writes
    no_notice
    [ -z "$(calls_by write)" ] || { echo "armed='$v' used the write credential"; false; }
  done
  grep -q '| Mode | disarmed (BUDGET_BREAKER_ARMED is set but is not exactly true) |' "$GITHUB_STEP_SUMMARY"
  assert_no_credential_anywhere
}

@test "arming value: the error does not claim a credential was handed over when none was" {
  unset BUDGET_BREAKER_TOKEN
  BUDGET_BREAKER_ARMED="yes" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '::error::' <<< "$output")" = "1" ]
  [[ "$output" != *"handed the write credential"* ]]
}

@test "arming value: unset, empty and the exact true log no such error" {
  seed_quota
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT WRITING (disarmed)"* ]]
  [[ "$output" != *"::error::"* ]]
  BUDGET_BREAKER_ARMED="" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT WRITING (disarmed)"* ]]
  [[ "$output" != *"::error::"* ]]
  grep -q '| Mode | disarmed |' "$GITHUB_STEP_SUMMARY"
  BUDGET_BREAKER_ARMED="true" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: armed"* ]]
  [[ "$output" != *"::error::"* ]]
  [[ "$output" != *"BUDGET_BREAKER_ARMED is set to"* ]]
}

@test "arming value: a value with a line break cannot start a log line of its own, and a long one is cut" {
  BUDGET_BREAKER_ARMED=$'true\n::error::forged' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^::error::' <<< "$output")" = "1" ]
  [[ "$output" == *'is set to "true?::error::forged"'* ]]
  [[ "$output" == *"NOT WRITING (disarmed)"* ]]
  BUDGET_BREAKER_ARMED="$(printf 'y%.0s' {1..200})" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is set to \"$(printf 'y%.0s' {1..40})\", which"* ]]
}

@test "static: a run that is not armed drops the write and notify credentials before it logs anything about the arming value" {
  # The branch taken when BUDGET_BREAKER_ARMED is not exactly `true`.
  local branch drop_line error_line
  branch="$(awk '/^if \[ "\$ARMED_VALUE" != "true" \]; then$/ {f=1; next} f && /^elif / {exit} f' "$SCRIPT")"
  [ -n "$branch" ]
  drop_line="$(grep -n '^  bbw_drop_write_credentials$' <<< "$branch" | head -n 1 | cut -d: -f1)"
  error_line="$(grep -n 'bbw_error ' <<< "$branch" | head -n 1 | cut -d: -f1)"
  [ -n "$drop_line" ]
  [ -n "$error_line" ]
  [ "$drop_line" -lt "$error_line" ]
  # ... and what it drops is both of them.
  # shellcheck source=../../../scripts/lib/budget-breaker.sh
  source "$DECISION_LIB"
  # shellcheck source=../../../scripts/lib/budget-breaker-writer.sh
  source "$WRITER_LIB"
  bbw_take_credentials
  bbw_has_write_credential
  bbw_drop_write_credentials
  run ! bbw_has_write_credential
  : > "$MOCK_DIR/calls.log"
  run bbw_find_tracking_issue acme/.github-private
  [ "$status" -ne 0 ]
  [ ! -s "$MOCK_DIR/calls.log" ]
}
