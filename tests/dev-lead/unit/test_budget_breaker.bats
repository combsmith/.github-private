#!/usr/bin/env bats
# Reactive budget breaker, decision only (#2221, slice 3a of #1565).
#
#   AC #1  table-driven tests of the pure decision (bb_decide).
#   AC #2  the collector reads marker text PRODUCED BY the real posting
#          functions (dev-lead fix-ci / fix-reviews / fix-issue, and pr-review),
#          captured from a stubbed `gh`, so writer and reader cannot drift.
#   AC #3  static: the library writes nothing and names no secret.
#   AC #4  the retry cron shares the marker definitions (its own suites are the
#          proof that its behaviour is unchanged).
#
# No live network: `gh` is always a stub on PATH.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/budget-breaker.sh"
MARKERS_LIB="$REPO_ROOT/scripts/lib/rate-limit-markers.sh"
RETRY="$REPO_ROOT/scripts/dev-lead-retry.sh"
FIX_CI="$REPO_ROOT/scripts/dev-lead-fix-ci.sh"
FIX_REVIEWS="$REPO_ROOT/scripts/dev-lead-fix-reviews.sh"
FIX_ISSUE="$REPO_ROOT/scripts/dev-lead-fix-issue.sh"
ADVISORY_GATE="$REPO_ROOT/scripts/lib/advisory-review-gate.sh"
PR_BUDGET_LIB="$REPO_ROOT/scripts/lib/pr-automation-budget.sh"

# 2026-10-10T12:00:00Z
NOW=1791633600

setup() {
  bats_require_minimum_version 1.5.0
  unset BUDGET_BREAKER_MIN_ITEMS BUDGET_BREAKER_WINDOW_MIN BUDGET_BREAKER_PROBE_HOURS \
    BUDGET_BREAKER_MARKER_KINDS PR_RATE_LIMITED_MARKER_PREFIX
  export BUDGET_BREAKER_NOW="$NOW"
  # shellcheck source=../../../scripts/lib/budget-breaker.sh
  source "$LIB"

  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  export BB_TEST_POSTED="$BATS_TEST_TMPDIR/posted.jsonl"
  export BB_TEST_CALLS="$BATS_TEST_TMPDIR/gh-calls"
  export BB_TEST_FLEET="$BATS_TEST_TMPDIR/fleet"
  : > "$BB_TEST_POSTED"
  : > "$BB_TEST_CALLS"
  mkdir -p "$BB_TEST_FLEET"
}

teardown() {
  # The dev-lead writers read these fixed sidecar paths; leave none behind.
  rm -f /tmp/dev-lead-rate-limit-reset /tmp/dev-lead-failure-reason
}

# ── helpers ──────────────────────────────────────────────────────────────────

# ts <offset_sec> — ISO-8601 UTC for NOW + offset.
ts() { jq -nr --argjson t "$(( NOW + $1 ))" '$t | todate'; }

# row <repo> <item> <created_offset_sec> [<reset_offset_sec>] — one observation.
row() {
  if [ -n "${4:-}" ]; then
    jq -cn --arg r "$1" --argjson i "$2" --arg c "$(ts "$3")" --arg x "$(ts "$4")" \
      '{repo: $r, item: $i, created: $c, reset: $x}'
  else
    jq -cn --arg r "$1" --argjson i "$2" --arg c "$(ts "$3")" \
      '{repo: $r, item: $i, created: $c, reset: null}'
  fi
}

# arr <json>... — a JSON array of the given values.
arr() { local IFS=,; printf '[%s]' "$*"; }

# expect <case> <want_action> <want_until|null> <want_count> <observations> [<paused> [<source> [<until>]]]
# One row of a decision table. Also holds every verdict to the output contract.
expect() {
  local name="$1" want_action="$2" want_until="$3" want_count="$4" got
  got=$(bb_decide "${5:-}" "${6:-}" "${7:-}" "${8:-}")
  if [ "$(jq -r '.action' <<< "$got")" != "$want_action" ] \
    || [ "$(jq -r '.until // "null"' <<< "$got")" != "$want_until" ] \
    || [ "$(jq -r '.evidence_count' <<< "$got")" != "$want_count" ]; then
    echo "case '${name}': want action=${want_action} until=${want_until} evidence_count=${want_count}" >&2
    echo "  got ${got}" >&2
    return 1
  fi
  if ! jq -e '(keys == ["action","evidence_count","reason","until"])
              and (.reason | type == "string" and length > 0)
              and (.evidence_count | type == "number")' <<< "$got" >/dev/null; then
    echo "case '${name}': verdict breaks the output contract: ${got}" >&2
    return 1
  fi
}

# real_defs <script> <name>... — print top-level definitions EXACTLY as the
# script has them: `name=` for an assignment line, otherwise the function.
real_defs() {
  local script="$1" n
  shift
  for n in "$@"; do
    case "$n" in
      *=) sed -n "/^${n}/p" "$script" ;;
      *)  sed -n "/^${n}()/,/^}/p" "$script" ;;
    esac
  done
}

# gh stub that records the body of every comment the code under test posts
# (one JSON string per line) and answers every read with "no comments".
install_gh_recorder() {
  cat > "$STUB_BIN/gh" << 'GH'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  if [ "$prev" = "--body" ]; then printf '%s' "$a" | jq -Rs '.' >> "$BB_TEST_POSTED"; fi
  prev="$a"
done
[ "${1:-}" = "api" ] && echo '[]'
exit 0
GH
  chmod +x "$STUB_BIN/gh"
}

# run_real <driver-file> — run a driver built from real_defs with the recorder.
run_real() { PATH="$STUB_BIN:$PATH" bash "$1"; }

# post_fix_ci <pr> <reset|""> — the REAL dev-lead-fix-ci.sh post_rate_limited.
post_fix_ci() {
  local driver="$BATS_TEST_TMPDIR/fix-ci-driver.sh"
  printf '%s' "$2" > /tmp/dev-lead-rate-limit-reset
  { echo 'set -euo pipefail'
    real_defs "$FIX_CI" MARKER_PREFIX= has_rate_limited_marker post_rate_limited
    echo 'post_rate_limited'
  } > "$driver"
  PR_NUMBER="$1" HEAD_SHA=abc123def456 REPO=acme/app DEV_LEAD_DRY_RUN=false \
    CHECKS_JSON='[{"name":"lint / eslint"}]' run_real "$driver"
}

# post_fix_reviews <pr> <intent> <reason> <reset|""> — the REAL
# dev-lead-fix-reviews.sh post_reviews_rate_limited.
post_fix_reviews() {
  local driver="$BATS_TEST_TMPDIR/fix-reviews-driver.sh"
  printf '%s' "$4" > /tmp/dev-lead-rate-limit-reset
  { echo 'set -euo pipefail'
    echo 'ci_blocking_reason() { :; }   # visible wording only; not part of the marker'
    real_defs "$FIX_REVIEWS" REVIEWS_MARKER_PREFIX= expire_stale_terminal_markers \
      has_reviews_rate_limited_marker blocking_reason_phrase post_reviews_rate_limited
    echo 'post_reviews_rate_limited "$1" "$2"'
  } > "$driver"
  PR_NUMBER="$1" HEAD_SHA=ddd444eee555 REPO=acme/app DEV_LEAD_DRY_RUN=false ACTOR=someone \
    PATH="$STUB_BIN:$PATH" bash "$driver" "$2" "$3"
}

# post_fix_issue <issue> <engine_rc> <reset|""> — the REAL dev-lead-fix-issue.sh
# handle_engine_failure (it exits with the engine's class: 2 = rate-limited).
post_fix_issue() {
  local driver="$BATS_TEST_TMPDIR/fix-issue-driver.sh" rc=0
  printf '%s' "$3" > /tmp/dev-lead-rate-limit-reset
  printf 'engine-error' > /tmp/dev-lead-failure-reason
  { echo 'set -euo pipefail'
    real_defs "$FIX_ISSUE" ISSUE_MARKER_PREFIX= MAX_ATTEMPTS= count_prior_attempts \
      html_escape session_snippet handle_engine_failure
    echo 'handle_engine_failure "$1"'
  } > "$driver"
  ISSUE_NUMBER="$1" REPO=acme/app GITHUB_RUN_ID=777 \
    PATH="$STUB_BIN:$PATH" bash "$driver" "$2" || rc=$?
  [ "$rc" -eq "$2" ]
}

# post_pr_review <reset> — the REAL advisory-review-gate.sh maybe_post_rate_limited_marker.
post_pr_review() {
  PATH="$STUB_BIN:$PATH" bash -c '
    source "$1"
    maybe_post_rate_limited_marker "https://github.com/acme/app/pull/61" "f00dfeed" "$2" "{\"comments\":[]}"
  ' _ "$ADVISORY_GATE" "$1"
}

# posted_comments <item> [<created_offset_sec> [<author_association>]] — wrap
# every recorded body in the REST issue-comment shape, then forget them.
posted_comments() {
  jq -cs --arg item "$1" --arg created "$(ts "${2:--60}")" --arg assoc "${3:-MEMBER}" \
    '[.[] | {body: ., created_at: $created, author_association: $assoc,
             issue_url: ("https://api.github.com/repos/acme/app/issues/" + $item)}]' \
    "$BB_TEST_POSTED"
  : > "$BB_TEST_POSTED"
}

# ── AC #1: the decision ──────────────────────────────────────────────────────

@test "decide: below the item threshold is none, and reports how much evidence there was" {
  expect "no observations" none null 0 '[]'
  expect "one item"        none null 1 "$(arr "$(row acme/app 1 -60 3600)")"
  expect "two items"       none null 2 "$(arr "$(row acme/app 1 -60 3600)" "$(row acme/app 2 -60 3600)")"
}

@test "decide: three distinct items in the window with future resets trips, until = the latest reset" {
  expect "three items" trip "$(ts 7200)" 3 \
    "$(arr "$(row acme/app 1 -60 3600)" "$(row acme/app 2 -600 7200)" "$(row acme/web 9 -1700 1800)")"
  expect "five items" trip "$(ts 9000)" 5 \
    "$(arr "$(row acme/app 1 -60 60)" "$(row acme/app 2 -60 9000)" "$(row acme/app 3 -60 3600)" \
           "$(row acme/web 1 -60 3600)" "$(row acme/web 2 -60 3600)")"
}

@test "decide: distinct ITEMS, not markers: one item retried many times counts once" {
  expect "same item three times" none null 1 \
    "$(arr "$(row acme/app 7 -60 3600)" "$(row acme/app 7 -300 3600)" "$(row acme/app 7 -900 3600)")"
  expect "two items, six markers" none null 2 \
    "$(arr "$(row acme/app 7 -60 3600)" "$(row acme/app 7 -70 3600)" "$(row acme/app 7 -80 3600)" \
           "$(row acme/app 8 -60 3600)" "$(row acme/app 8 -70 3600)" "$(row acme/app 8 -80 3600)")"
  # The same number in another repository is another item; "7" and 7 are one.
  expect "same number, three repos" trip "$(ts 3600)" 3 \
    "$(arr "$(row acme/app 7 -60 3600)" "$(row acme/web 7 -60 3600)" "$(row acme/api 7 -60 3600)")"
  expect "string and number item" none null 2 \
    "$(arr "$(row acme/app 7 -60 3600)" "$(row acme/app 7 -60 3600 | jq -c '.item = "7"')" "$(row acme/app 8 -60 3600)")"
}

@test "decide: markers outside the window are not evidence" {
  expect "all older than 30 min" none null 0 \
    "$(arr "$(row acme/app 1 -1801 3600)" "$(row acme/app 2 -3600 3600)" "$(row acme/app 3 -86400 3600)")"
  expect "two fresh, one stale" none null 2 \
    "$(arr "$(row acme/app 1 -60 3600)" "$(row acme/app 2 -60 3600)" "$(row acme/app 3 -1801 3600)")"
  expect "exactly at the window edge counts" trip "$(ts 3600)" 3 \
    "$(arr "$(row acme/app 1 -1800 3600)" "$(row acme/app 2 -1800 3600)" "$(row acme/app 3 -1800 3600)")"
  # The window ENDS now: a marker dated after the decision time is outside it
  # (a replay against an earlier clock must not count what came later).
  expect "created now counts" trip "$(ts 3600)" 3 \
    "$(arr "$(row acme/app 1 0 3600)" "$(row acme/app 2 0 3600)" "$(row acme/app 3 0 3600)")"
  expect "created after now" none null 0 \
    "$(arr "$(row acme/app 1 1 3600)" "$(row acme/app 2 600 3600)" "$(row acme/app 3 86400 90000)")"
}

@test "decide: a marker whose reset has already passed is not evidence" {
  expect "all resets passed" none null 0 \
    "$(arr "$(row acme/app 1 -600 -1)" "$(row acme/app 2 -600 -60)" "$(row acme/app 3 -600 0)")"
  expect "two live, one expired" none null 2 \
    "$(arr "$(row acme/app 1 -60 3600)" "$(row acme/app 2 -60 3600)" "$(row acme/app 3 -600 -1)")"
}

@test "decide: no parseable reset trips with the probe interval" {
  expect "no resets at all" trip "$(ts 7200)" 3 \
    "$(arr "$(row acme/app 1 -60)" "$(row acme/app 2 -60)" "$(row acme/app 3 -60)")"
  expect "empty-string reset is absent too" trip "$(ts 7200)" 3 \
    "$(arr "$(row acme/app 1 -60 | jq -c '.reset = ""')" "$(row acme/app 2 -60)" "$(row acme/app 3 -60)")"
  # One known reset among absent ones: the known reset wins over the probe.
  expect "mixed: one reset known" trip "$(ts 900)" 3 \
    "$(arr "$(row acme/app 1 -60)" "$(row acme/app 2 -60 900)" "$(row acme/app 3 -60)")"
}

@test "decide: own pause holds before until and resumes after it" {
  local three
  three="$(arr "$(row acme/app 1 -60 3600)" "$(row acme/app 2 -60 3600)" "$(row acme/app 3 -60 3600)")"
  expect "before until"          hold   "$(ts 600)" 0 '[]'     true rate-limit-observed "$(ts 600)"
  expect "before until, evidence" hold  "$(ts 600)" 0 "$three" true rate-limit-observed "$(ts 600)"
  expect "after until"           resume null 0 '[]'     true rate-limit-observed "$(ts -1)"
  expect "after until, evidence" resume null 0 "$three" true rate-limit-observed "$(ts -600)"
  expect "until is now"          resume null 0 '[]'     true rate-limit-observed "$(ts 0)"
}

@test "decide: own pause with a missing or unparseable until resumes (fail open) and says so" {
  local until
  for until in "" "soon" "2026-10-10" "1791633600" "2026-13-45T99:00:00Z"; do
    expect "until='${until}'" resume null 0 '[]' true rate-limit-observed "$until"
    run bb_decide '[]' true rate-limit-observed "$until"
    [[ "$output" == *"missing or unparseable"* ]]
    [[ "$output" == *"failing open"* ]]
  done
  # Bad observations do not keep an own pause in place either.
  expect "garbage observations" resume null 0 'not json' true rate-limit-observed "$(ts -1)"
}

@test "decide: a human pause (no source) is never tripped over and never resumed" {
  local three
  three="$(arr "$(row acme/app 1 -60 3600)" "$(row acme/app 2 -60 3600)" "$(row acme/app 3 -60 3600)")"
  expect "trip evidence"       none null 0 "$three" true ""
  expect "expired until"       none null 0 '[]'     true "" "$(ts -3600)"
  expect "future until"        none null 0 '[]'     true "" "$(ts 3600)"
  expect "both at once"        none null 0 "$three" true "" "$(ts -3600)"
  # GitHub expressions compare case-insensitively, so TRUE pauses the fleet too.
  expect "TRUE, trip evidence" none null 0 "$three" TRUE ""
  expect "True, expired until" none null 0 '[]'     True "" "$(ts -3600)"
}

@test "decide: a pause with a foreign source is never tripped over and never resumed" {
  local three source
  three="$(arr "$(row acme/app 1 -60 3600)" "$(row acme/app 2 -60 3600)" "$(row acme/app 3 -60 3600)")"
  for source in weekly-glide five-hour "Rate-Limit-Observed" "rate-limit-observed " manual; do
    expect "${source}: trip evidence" none null 0 "$three" true "$source"
    expect "${source}: expired until" none null 0 '[]'     true "$source" "$(ts -3600)"
    expect "${source}: future until"  none null 0 "$three" true "$source" "$(ts 3600)"
  done
}

@test "decide: an unpaused fleet is judged on evidence even with a leftover source or until" {
  local three
  three="$(arr "$(row acme/app 1 -60 3600)" "$(row acme/app 2 -60 3600)" "$(row acme/app 3 -60 3600)")"
  expect "paused unset"  trip "$(ts 3600)" 3 "$three" ""    rate-limit-observed "$(ts -60)"
  expect "paused false"  trip "$(ts 3600)" 3 "$three" false rate-limit-observed "$(ts 600)"
  expect "no evidence"   none null 0 '[]' false rate-limit-observed "$(ts -60)"
}

@test "decide: malformed input is none, never trip" {
  local good three
  good="$(row acme/app 1 -60 3600)"
  three="$(arr "$good" "$(row acme/app 2 -60 3600)" "$(row acme/app 3 -60 3600)")"

  expect "empty observations"   none null 0 ''
  expect "not JSON"             none null 0 'status=rate-limited'
  expect "truncated JSON"       none null 0 '[{"repo":"acme/app"'
  expect "an object, not array" none null 0 "$good"
  expect "a number"             none null 0 '3'
  expect "null"                 none null 0 'null'

  # One bad row poisons an otherwise tripping set: never trip on a guess.
  local bad
  for bad in \
    '"a string"' '7' 'null' '[]' \
    "$(jq -c 'del(.repo)' <<< "$good")" \
    "$(jq -c '.repo = ""' <<< "$good")" \
    "$(jq -c '.repo = 5' <<< "$good")" \
    "$(jq -c 'del(.item)' <<< "$good")" \
    "$(jq -c '.item = "x7"' <<< "$good")" \
    "$(jq -c '.item = 0' <<< "$good")" \
    "$(jq -c '.item = 1.5' <<< "$good")" \
    "$(jq -c '.item = null' <<< "$good")" \
    "$(jq -c 'del(.created)' <<< "$good")" \
    "$(jq -c '.created = null' <<< "$good")" \
    "$(jq -c '.created = "yesterday"' <<< "$good")" \
    "$(jq -c '.created = "2026-10-10 11:59:00"' <<< "$good")" \
    "$(jq -c '.created = 1791633540' <<< "$good")" \
    "$(jq -c '.reset = "11:20pm"' <<< "$good")" \
    "$(jq -c '.reset = "2026-10-10T25:61:00Z"' <<< "$good")" \
    "$(jq -c '.reset = 1791637200' <<< "$good")"; do
    expect "three good rows + ${bad}" none null 0 "$(jq -c --argjson b "$bad" '. + [$b]' <<< "$three")"
  done
}

@test "decide: an unparseable clock or setting is none, never trip" {
  local three got
  three="$(arr "$(row acme/app 1 -60 3600)" "$(row acme/app 2 -60 3600)" "$(row acme/app 3 -60 3600)")"
  for now in "now" "2026-10-10T12:00:00Z" "-5" "1.5e9" " "; do
    got=$(bb_decide "$three" "" "" "" "$now")
    [ "$(jq -r '.action' <<< "$got")" = "none" ]
  done
  local name value
  for name in BUDGET_BREAKER_MIN_ITEMS BUDGET_BREAKER_WINDOW_MIN BUDGET_BREAKER_PROBE_HOURS; do
    for value in 0 -1 three 2.5 "3 " 99999999999; do
      got=$(env "$name=$value" bash -c 'source "$1"; bb_decide "$2" "" "" ""' _ "$LIB" "$three")
      [ "$(jq -r '.action' <<< "$got")" = "none" ] || { echo "$name=$value -> $got" >&2; false; }
      [[ "$(jq -r '.reason' <<< "$got")" == *"setting"* ]]
    done
  done
}

@test "decide: the three settings come from the environment, with the issue's defaults" {
  local two three
  two="$(arr "$(row acme/app 1 -60)" "$(row acme/app 2 -60)")"
  three="$(arr "$(row acme/app 1 -600)" "$(row acme/app 2 -600)" "$(row acme/app 3 -600)")"
  # Defaults: 3 items, 30 minutes, 2 hours.
  expect "default threshold" none null 2 "$two"
  expect "default window and probe" trip "$(ts 7200)" 3 "$three"

  BUDGET_BREAKER_MIN_ITEMS=2 expect "min items 2" trip "$(ts 7200)" 2 "$two"
  BUDGET_BREAKER_MIN_ITEMS=4 expect "min items 4" none null 3 "$three"
  BUDGET_BREAKER_WINDOW_MIN=5 expect "window 5 min" none null 0 "$three"
  BUDGET_BREAKER_WINDOW_MIN=10 expect "window 10 min" trip "$(ts 7200)" 3 "$three"
  BUDGET_BREAKER_PROBE_HOURS=6 expect "probe 6 h" trip "$(ts 21600)" 3 "$three"
  # An empty variable means "not set".
  BUDGET_BREAKER_MIN_ITEMS="" expect "empty = default" none null 2 "$two"
}

@test "decide: the clock defaults to bb_now, which honors BUDGET_BREAKER_NOW" {
  [ "$(bb_now)" = "$NOW" ]
  local three
  three="$(arr "$(row acme/app 1 -60)" "$(row acme/app 2 -60)" "$(row acme/app 3 -60)")"
  # Two hours later the same markers are outside the window.
  expect "same clock" trip "$(ts 7200)" 3 "$three"
  BUDGET_BREAKER_NOW=$(( NOW + 7200 )) expect "two hours on" none null 0 "$three"
  # Without the override it is the real clock.
  unset BUDGET_BREAKER_NOW
  [[ "$(bb_now)" =~ ^[0-9]+$ ]]
  [ "$(bb_now)" -gt 1700000000 ]
}

@test "decide: the breaker's own pause source is rate-limit-observed" {
  [ "$BUDGET_BREAKER_PAUSE_SOURCE" = "rate-limit-observed" ]
}

# ── AC #2: the collector against text the real writers post ──────────────────

@test "collector: reads dev-lead-fix-ci's real rate-limited marker, with and without a reset" {
  install_gh_recorder
  post_fix_ci 42 "$(ts 3600)"
  [ "$(wc -l < "$BB_TEST_POSTED")" -eq 1 ]
  grep -q 'status=rate-limited' "$BB_TEST_POSTED"   # the writer really posted one
  run bb_observations_from_comments acme/app < <(posted_comments 42)
  [ "$status" -eq 0 ]
  [ "$(jq -c '.' <<< "$output")" = "$(jq -cn --arg c "$(ts -60)" --arg r "$(ts 3600)" \
    '[{repo: "acme/app", item: 42, created: $c, reset: $r, kind: "dev-lead-fix-ci"}]')" ]

  post_fix_ci 43 ""
  run bb_observations_from_comments acme/app < <(posted_comments 43)
  [ "$status" -eq 0 ]
  [ "$(jq -c '.[0] | [.item, .reset, .kind]' <<< "$output")" = '[43,null,"dev-lead-fix-ci"]' ]
  [ "$(jq 'length' <<< "$output")" -eq 1 ]
}

@test "collector: reads dev-lead-fix-reviews's real rate-limited marker for each intent" {
  install_gh_recorder
  local intent
  for intent in fix-reviews rebase fix-bot-comment; do
    post_fix_reviews 54 "$intent" rate-limit "$(ts 1800)"
    run bb_observations_from_comments acme/app < <(posted_comments 54)
    [ "$status" -eq 0 ]
    [ "$(jq -c '.' <<< "$output")" = "$(jq -cn --arg c "$(ts -60)" --arg r "$(ts 1800)" \
      '[{repo: "acme/app", item: 54, created: $c, reset: $r, kind: "dev-lead-fix-reviews"}]')" ]
  done
  # No reset known (today's weekly-cap wording): still one observation, reset null.
  post_fix_reviews 54 fix-reviews rate-limit ""
  run bb_observations_from_comments acme/app < <(posted_comments 54)
  [ "$(jq -c '.[0] | [.item, .reset]' <<< "$output")" = '[54,null]' ]
}

@test "collector: review-changes posts a marker AND a visible ack; only the marker is an observation" {
  install_gh_recorder
  post_fix_reviews 55 review-changes rate-limit "$(ts 1800)"
  [ "$(wc -l < "$BB_TEST_POSTED")" -eq 2 ]
  run bb_observations_from_comments acme/app < <(posted_comments 55)
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.[0].kind' <<< "$output")" = "dev-lead-fix-reviews" ]
}

@test "collector: status=blocked from the real writer is never an observation" {
  install_gh_recorder
  local reason
  for reason in blocked resolve-failed; do
    post_fix_reviews 56 fix-reviews "$reason" ""
    grep -q 'status=blocked' "$BB_TEST_POSTED"   # the writer really posted a blocked marker
    run bb_observations_from_comments acme/app < <(posted_comments 56)
    [ "$status" -eq 0 ]
    [ "$(jq -c '.' <<< "$output")" = '[]' ]
  done
}

@test "collector: reads dev-lead-fix-issue's real rate-limited marker; a failed run is not quota" {
  install_gh_recorder
  post_fix_issue 100 2 "$(ts 5400)"
  grep -q 'status=rate-limited' "$BB_TEST_POSTED"
  run bb_observations_from_comments acme/app < <(posted_comments 100)
  [ "$status" -eq 0 ]
  [ "$(jq -c '.' <<< "$output")" = "$(jq -cn --arg c "$(ts -60)" --arg r "$(ts 5400)" \
    '[{repo: "acme/app", item: 100, created: $c, reset: $r, kind: "dev-lead-issue"}]')" ]

  post_fix_issue 101 2 ""
  run bb_observations_from_comments acme/app < <(posted_comments 101)
  [ "$(jq -c '.[0] | [.item, .reset]' <<< "$output")" = '[101,null]' ]

  # Engine error (exit 1): the same writer posts status=failed. Not quota.
  post_fix_issue 102 1 ""
  grep -q 'status=failed' "$BB_TEST_POSTED"
  run bb_observations_from_comments acme/app < <(posted_comments 102)
  [ "$(jq -c '.' <<< "$output")" = '[]' ]
}

@test "collector: pr-review's real marker is recognised, and is not quota evidence by default" {
  install_gh_recorder
  post_pr_review "$(ts 3600)"
  grep -q 'pr-review-agent rate-limited v1' "$BB_TEST_POSTED"
  cp "$BB_TEST_POSTED" "$BATS_TEST_TMPDIR/pr-review.jsonl"

  # Default kinds: an advisory reviewer bot being out of quota says nothing
  # about the model provider, so it is not an observation.
  run bb_observations_from_comments acme/app < <(posted_comments 61)
  [ "$status" -eq 0 ]
  [ "$(jq -c '.' <<< "$output")" = '[]' ]

  # Opted in: the reader does parse the writer's text.
  cp "$BATS_TEST_TMPDIR/pr-review.jsonl" "$BB_TEST_POSTED"
  BUDGET_BREAKER_MARKER_KINDS="dev-lead-issue pr-review-advisory" \
    run bb_observations_from_comments acme/app < <(posted_comments 61)
  [ "$status" -eq 0 ]
  [ "$(jq -c '.' <<< "$output")" = "$(jq -cn --arg c "$(ts -60)" --arg r "$(ts 3600)" \
    '[{repo: "acme/app", item: 61, created: $c, reset: $r, kind: "pr-review-advisory"}]')" ]
}

@test "end to end: real markers on three items trip; the same three as blocked do not" {
  install_gh_recorder
  local all='[]' part
  post_fix_ci 42 "$(ts 3600)"
  part=$(posted_comments 42 -120);  all=$(jq -c --argjson p "$part" '. + $p' <<< "$all")
  post_fix_reviews 54 fix-reviews rate-limit "$(ts 5400)"
  part=$(posted_comments 54 -300);  all=$(jq -c --argjson p "$part" '. + $p' <<< "$all")
  post_fix_issue 100 2 ""
  part=$(posted_comments 100 -900); all=$(jq -c --argjson p "$part" '. + $p' <<< "$all")

  local obs
  obs=$(bb_observations_from_comments acme/app <<< "$all")
  [ "$(jq 'length' <<< "$obs")" -eq 3 ]
  expect "three real markers" trip "$(ts 5400)" 3 "$obs"
  # ... and a human pause still wins over that evidence.
  expect "three real markers, human pause" none null 0 "$obs" true ""

  # status=blocked on three items: never counted, so nothing to trip on.
  all='[]'
  local pr
  for pr in 71 72 73; do
    post_fix_reviews "$pr" fix-reviews blocked ""
    part=$(posted_comments "$pr"); all=$(jq -c --argjson p "$part" '. + $p' <<< "$all")
  done
  [ "$(jq 'length' <<< "$all")" -eq 3 ]
  obs=$(bb_observations_from_comments acme/app <<< "$all")
  expect "three blocked markers" none null 0 "$obs"
}

# ── the collector's own rules ────────────────────────────────────────────────

# comment <body> [<item> [<association>]] — one REST-shaped comment.
comment() {
  jq -cn --arg b "$1" --arg i "${2:-5}" --arg a "${3:-MEMBER}" --arg t "$(ts -60)" \
    '{body: $b, created_at: $t, author_association: $a,
      issue_url: ("https://api.github.com/repos/acme/app/issues/" + $i)}'
}

@test "collector: only a marker on the comment's first line counts, never a quoted one" {
  local m='<!-- dev-lead-fix-reviews pr=5 sha=abc intent=fix-reviews status=rate-limited reason=rate-limit -->'
  run bb_observations_from_comments acme/app <<< "$(arr "$(comment "$m"$'\nvisible text')")"
  [ "$(jq 'length' <<< "$output")" -eq 1 ]
  run bb_observations_from_comments acme/app <<< "$(arr \
    "$(comment "Look at this marker:"$'\n'"$m")" \
    "$(comment "> $m")" \
    "$(comment "\`$m\`")" \
    "$(comment "status=rate-limited reset=2026-10-10T13:00:00Z")" \
    "$(comment "<!-- dev-lead rate-limit-ack -->"$'\n'"all AI engines are currently rate-limited")" \
    "$(comment "<!-- dev-lead-fix-reviews pr=5 sha=abc intent=fix-reviews status=rate-limited")" \
    "$(comment "")")"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.' <<< "$output")" = '[]' ]
}

@test "collector: non-quota statuses and the legacy blocked spelling are never counted" {
  run bb_observations_from_comments acme/app <<< "$(arr \
    "$(comment '<!-- dev-lead-fix-reviews pr=5 sha=abc intent=fix-reviews status=blocked reason=blocked reset=2026-10-10T12:30:00Z -->')" \
    "$(comment '<!-- dev-lead-fix-reviews pr=5 sha=abc intent=fix-reviews status=blocked -->')" \
    "$(comment '<!-- dev-lead-fix-reviews pr=5 sha=abc intent=fix-reviews status=blocked reason=rate-limit reset=2026-10-10T12:30:00Z -->')" \
    "$(comment '<!-- dev-lead-fix-ci sha=abc status=blocked check=lint -->')" \
    "$(comment '<!-- dev-lead-issue 5 status=blocked attempt=1 reason=rate-limited run=1 -->')" \
    "$(comment '<!-- dev-lead-fix-reviews pr=5 sha=abc intent=fix-reviews status=rate-limited reason=blocked reset=2026-10-10T12:30:00Z -->')" \
    "$(comment '<!-- dev-lead-fix-reviews pr=5 sha=abc intent=fix-reviews status=rate-limited reason=resolve-failed -->')" \
    "$(comment '<!-- dev-lead-fix-reviews pr=5 sha=abc intent=fix-reviews status=partial -->')" \
    "$(comment '<!-- dev-lead-fix-reviews pr=5 sha=abc intent=fix-reviews status=history-unavailable -->')" \
    "$(comment '<!-- dev-lead-fix-reviews pr=5 sha=abc intent=fix-reviews status=applied -->')" \
    "$(comment '<!-- dev-lead-fix-ci sha=abc status=failed -->')" \
    "$(comment '<!-- dev-lead-fix-ci sha=abc status=applied check=status=rate-limited -->')" \
    "$(comment '<!-- dev-lead-issue 5 status=failed attempt=1 reason=engine-error run=1 -->')" \
    "$(comment '<!-- dev-lead-issue 5 status=needs-human attempt=3 reason=rate-limited run=1 -->')" \
    "$(comment '<!-- dev-lead-issue 5 status=rate-limited-ish attempt=1 reason=x run=1 -->')")"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.' <<< "$output")" = '[]' ]
}

@test "collector: a marker from an author who is not an owner, member or collaborator is ignored, loudly" {
  local m='<!-- dev-lead-issue 5 status=rate-limited attempt=1 reason=rate-limited run=1 reset=2099-01-01T00:00:00Z -->'
  local assoc
  for assoc in OWNER MEMBER COLLABORATOR; do
    run --separate-stderr bb_observations_from_comments acme/app <<< "$(arr "$(comment "$m" 5 "$assoc")")"
    [ "$(jq 'length' <<< "$output")" -eq 1 ]
    [ -z "$stderr" ]
  done
  run --separate-stderr bb_observations_from_comments acme/app <<< "$(arr \
    "$(comment "$m" 5 NONE)" "$(comment "$m" 6 CONTRIBUTOR)" "$(comment "$m" 7 FIRST_TIME_CONTRIBUTOR)" \
    "$(comment "$m" 8 MEMBER | jq -c 'del(.author_association)')")"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.' <<< "$output")" = '[]' ]
  [[ "$stderr" == *"::warning::"* ]]
  [[ "$stderr" == *"ignored 4 quota marker(s)"* ]]
}

@test "collector: a marker whose item or creation time cannot be read stops the decision, not vanishes" {
  local m='<!-- dev-lead-issue 5 status=rate-limited attempt=1 reason=rate-limited run=1 -->'
  local good bad obs
  good="$(arr "$(comment "$m" 1)" "$(comment "$m" 2)" "$(comment "$m" 3)")"
  obs=$(bb_observations_from_comments acme/app <<< "$good")
  expect "three readable" trip "$(ts 7200)" 3 "$obs"
  for bad in 'del(.created_at)' '.created_at = null' 'del(.issue_url)' '.issue_url = "https://example.invalid/x"'; do
    obs=$(jq -c --argjson b "$(comment "$m" 4 | jq -c "$bad")" '. + [$b]' <<< "$good" \
      | bb_observations_from_comments acme/app)
    [ "$(jq 'length' <<< "$obs")" -eq 4 ]
    expect "three readable + one with ${bad}" none null 0 "$obs"
  done
}

@test "collector: input that is not a JSON array of comments fails, it is not 'no markers'" {
  local input
  for input in '' 'not json' '{"body":"x"}' '"a string"'; do
    run bb_observations_from_comments acme/app <<< "$input"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
  done
  run bb_observations_from_comments acme/app <<< '[]'
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

# ── the network half, against a stubbed gh ───────────────────────────────────

# A gh stub that serves API-shaped fixtures and applies the caller's --jq, so
# the library's own filters run. Every invocation is logged.
install_gh_fleet() {
  cat > "$STUB_BIN/gh" << 'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BB_TEST_CALLS"
filter="." prev=""
for a in "$@"; do
  [ "$prev" = "--jq" ] && filter="$a"
  prev="$a"
done
case "$1 $2" in
  "repo list") f="$BB_TEST_FLEET/repos.$3.json" ;;
  "api --paginate")
    f="$BB_TEST_FLEET/$(printf '%s' "$3" | sed -E 's#^repos/([^/]+)/([^/]+)/issues/comments\?.*$#\1_\2#').json" ;;
  *) exit 1 ;;
esac
[ -f "$f" ] || exit 1
jq -rc "$filter" "$f"
GH
  chmod +x "$STUB_BIN/gh"
  PATH="$STUB_BIN:$PATH"
}

# api_comment <item> <created_offset> <body> — a full REST issue comment.
api_comment() {
  jq -cn --arg i "$1" --arg t "$(ts "$2")" --arg b "$3" \
    '{id: 1, node_id: "IC_x", body: $b, created_at: $t, updated_at: $t,
      author_association: "MEMBER", user: {login: "don-petry", type: "User"},
      html_url: ("https://github.com/acme/app/issues/" + $i + "#issuecomment-1"),
      issue_url: ("https://api.github.com/repos/acme/app/issues/" + $i)}'
}

@test "bb_collect: lists the org's non-fork repos and reads each repo's comments once, for the window" {
  install_gh_recorder
  post_fix_ci 42 "$(ts 3600)";                          local ci;  ci=$(jq -r '.' "$BB_TEST_POSTED");  : > "$BB_TEST_POSTED"
  post_fix_reviews 54 fix-reviews rate-limit "";        local rv;  rv=$(jq -r '.' "$BB_TEST_POSTED");  : > "$BB_TEST_POSTED"
  post_fix_issue 100 2 "$(ts 1800)";                    local is;  is=$(jq -r '.' "$BB_TEST_POSTED");  : > "$BB_TEST_POSTED"

  install_gh_fleet
  echo '[{"nameWithOwner":"acme/app","isFork":false},{"nameWithOwner":"acme/forked","isFork":true},{"nameWithOwner":"acme/web","isFork":false}]' \
    > "$BB_TEST_FLEET/repos.acme.json"
  arr "$(api_comment 42 -120 "$ci")" "$(api_comment 54 -300 "$rv")" "$(api_comment 9 -60 "just a comment")" \
    > "$BB_TEST_FLEET/acme_app.json"
  arr "$(api_comment 100 -900 "$is")" > "$BB_TEST_FLEET/acme_web.json"

  run --separate-stderr bb_collect acme
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(jq -c 'map([.repo, .item, .kind])' <<< "$output")" = \
    '[["acme/app",42,"dev-lead-fix-ci"],["acme/app",54,"dev-lead-fix-reviews"],["acme/web",100,"dev-lead-issue"]]' ]
  expect "collected evidence" trip "$(ts 3600)" 3 "$output"

  # One listing call per org, one comments call per non-fork repo, the fork skipped.
  [ "$(grep -c '^repo list acme ' "$BB_TEST_CALLS")" -eq 1 ]
  [ "$(grep -c '^api ' "$BB_TEST_CALLS")" -eq 2 ]
  run grep -c 'acme/forked' "$BB_TEST_CALLS"
  [ "$output" = "0" ]
  # The server-side window is now minus BUDGET_BREAKER_WINDOW_MIN.
  grep -qF "repos/acme/app/issues/comments?since=$(ts -1800)&per_page=100" "$BB_TEST_CALLS"
  # Reads only: nothing in any call can write.
  run grep -nE '(^| )(-X|--method|-f|-F|--field|--raw-field|--input)( |=|$)|^(variable|secret|issue|pr|workflow|run) ' "$BB_TEST_CALLS"
  [ "$status" -eq 1 ]
}

@test "bb_collect: the window follows BUDGET_BREAKER_WINDOW_MIN" {
  install_gh_fleet
  echo '[{"nameWithOwner":"acme/app","isFork":false}]' > "$BB_TEST_FLEET/repos.acme.json"
  echo '[]' > "$BB_TEST_FLEET/acme_app.json"
  BUDGET_BREAKER_WINDOW_MIN=5 run bb_collect acme
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
  grep -qF "since=$(ts -300)&" "$BB_TEST_CALLS"
}

@test "bb_collect: an unreadable repo is a warning and is skipped; the rest still count" {
  install_gh_fleet
  echo '[{"nameWithOwner":"acme/app","isFork":false},{"nameWithOwner":"acme/gone","isFork":false}]' \
    > "$BB_TEST_FLEET/repos.acme.json"
  arr "$(api_comment 7 -60 '<!-- dev-lead-issue 7 status=rate-limited attempt=1 reason=rate-limited run=1 -->')" \
    > "$BB_TEST_FLEET/acme_app.json"
  run --separate-stderr bb_collect acme
  [ "$status" -eq 0 ]
  [ "$(jq -c 'map(.item)' <<< "$output")" = '[7]' ]
  [[ "$stderr" == *"::warning::"*"cannot read issue comments for acme/gone"* ]]
}

@test "bb_collect: when nothing can be read it fails and prints nothing, which decides none" {
  install_gh_fleet
  # No repo list at all.
  run --separate-stderr bb_collect acme
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"::warning::"*"cannot list repositories for acme"* ]]
  expect "collector printed nothing" none null 0 "$output"

  # An empty list is treated as unreadable, not as an empty organisation.
  echo '[]' > "$BB_TEST_FLEET/repos.acme.json"
  run --separate-stderr bb_collect acme
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no repositories listed for acme"* ]]

  # Repos listed, none readable.
  echo '[{"nameWithOwner":"acme/app","isFork":false}]' > "$BB_TEST_FLEET/repos.acme.json"
  run --separate-stderr bb_collect acme
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no repository could be read"* ]]

  # No organisation given.
  run --separate-stderr bb_collect
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "bb_collect: several organisations are merged; one that cannot be listed is skipped" {
  install_gh_fleet
  echo '[{"nameWithOwner":"acme/app","isFork":false}]' > "$BB_TEST_FLEET/repos.acme.json"
  arr "$(api_comment 7 -60 '<!-- dev-lead-issue 7 status=rate-limited attempt=1 reason=rate-limited run=1 -->')" \
    > "$BB_TEST_FLEET/acme_app.json"
  run --separate-stderr bb_collect missing-org acme
  [ "$status" -eq 0 ]
  [ "$(jq -c 'map([.repo, .item])' <<< "$output")" = '[["acme/app",7]]' ]
  [[ "$stderr" == *"cannot list repositories for missing-org"* ]]
}

# ── AC #3: static — no write, no secret ──────────────────────────────────────

# static_violations <file> — print every line that could write an Actions
# variable (or anything else) or that names a secret. Empty output = clean.
static_violations() {
  local f="$1"
  # Naming or writing an Actions variable / the pause switch.
  grep -nE 'gh[[:space:]]+variable' "$f"
  grep -niE 'actions/variables' "$f"
  grep -nE 'AGENTS_PAUSED|AGENTS_PAUSE_SOURCE' "$f"
  grep -niE 'updateVariable|createVariable|deleteVariable|(create|update|delete)(Org|Repo)Variable' "$f"
  # Any write method or request body on an API call (`gh api -f` is a POST).
  grep -nE '(-X|--method)[[:space:]=]*[A-Za-z]' "$f"
  grep -nE '[[:space:]](-f|-F|--field|--raw-field|--input)[[:space:]=]' "$f"
  grep -niE 'graphql|mutation' "$f"
  # Every gh call must be one of the two reads.
  grep -nE '(^|[^[:alnum:]_.#-])gh[[:space:]]+[a-z]' "$f" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -vE 'gh (repo list|api --paginate)( |$)'
  # Secret names.
  grep -nE '[A-Z0-9_]*(TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|API_KEY|PRIVATE_KEY|_PAT)[A-Z0-9_]*' "$f"
  grep -nE 'secrets\.' "$f"
  return 0
}

@test "static: the library holds no Actions-variable write, no write call and no secret name" {
  local f
  for f in "$LIB" "$MARKERS_LIB"; do
    [ -f "$f" ]
    run static_violations "$f"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "$f:"; echo "$output"; false; }
  done
  # The library does call gh, so the gh rule above is not vacuous.
  [ "$(grep -cE '^[^#]*gh (repo list|api --paginate)' "$LIB")" -eq 2 ]
  # It sources exactly one other file, the marker definitions checked above.
  [ "$(grep -cE '^[[:space:]]*(source|\.)[[:space:]]' "$LIB")" -eq 1 ]
  grep -qE '^source .*/rate-limit-markers\.sh"$' "$LIB"
  run grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "$MARKERS_LIB"
  [ "$status" -eq 1 ]
}

@test "static: the no-write assertion is not vacuous (each planted line trips it)" {
  local planted="$BATS_TEST_TMPDIR/planted.sh" line
  while IFS= read -r line; do
    printf '%s\n' "$line" > "$planted"
    run static_violations "$planted"
    [ -n "$output" ] || { echo "not caught: $line"; false; }
  done << 'PLANTED'
gh variable set SOME_SWITCH --org acme --body true
gh variable delete SOME_SWITCH --org acme
gh api -X PATCH "orgs/acme/actions/variables/SOME_SWITCH" -f value=true
gh api --method PUT "repos/acme/app/actions/variables/X"
gh api "orgs/acme/actions/variables" --input body.json
gh api repos/acme/app/issues/1/comments -f body=hello
gh api graphql -f query='mutation { x }'
gh pr comment 1 --repo acme/app --body hi
gh issue edit 1 --add-label x
gh workflow run breaker.yml
echo "$AGENTS_PAUSED"
curl -H "Authorization: Bearer $GH_TOKEN" https://api.github.com
echo "${CLAUDE_CODE_OAUTH_TOKEN}"
echo "${{ secrets.ANYTHING }}"
export EXAMPLE_ORG_PAT=x
PLANTED
}

# ── AC #4: one definition of the markers, shared with the retry cron ─────────

@test "markers: the retry cron takes its prefixes from the shared definition" {
  grep -qF 'source "$SCRIPT_DIR/lib/rate-limit-markers.sh"' "$RETRY"
  run grep -nE '^(CI_MARKER_PREFIX|REVIEWS_MARKER_PREFIX|ISSUE_MARKER_PREFIX)=' "$RETRY"
  [ "$status" -eq 1 ]
  # ... and the reset capture it uses inline is the shared one.
  [ "$(grep -cF "capture(\"${RATE_LIMIT_RESET_CAPTURE_RE}\")" "$RETRY")" -ge 2 ]
}

@test "markers: the shared prefixes are the writers' own literals" {
  [ "$(real_defs "$FIX_CI" MARKER_PREFIX=)" = "MARKER_PREFIX=\"${CI_MARKER_PREFIX}\"" ]
  [ "$(real_defs "$FIX_REVIEWS" REVIEWS_MARKER_PREFIX=)" = "REVIEWS_MARKER_PREFIX=\"${REVIEWS_MARKER_PREFIX}\"" ]
  [ "$(real_defs "$FIX_ISSUE" ISSUE_MARKER_PREFIX=)" = "ISSUE_MARKER_PREFIX=\"${ISSUE_MARKER_PREFIX}\"" ]
  # pr-review's prefix: the breaker's fallback literal equals its owner's value,
  # and the owner's value is used when that library is loaded first.
  local owner
  owner=$(bash -c 'source "$1"; printf "%s" "$PR_RATE_LIMITED_MARKER_PREFIX"' _ "$PR_BUDGET_LIB")
  [ -n "$owner" ]
  [ "$_BB_ADVISORY_MARKER_PREFIX" = "$owner" ]
  [ "$(PR_RATE_LIMITED_MARKER_PREFIX='<!-- other ' bash -c 'source "$1"; printf "%s" "$_BB_ADVISORY_MARKER_PREFIX"' _ "$LIB")" = '<!-- other ' ]
}

@test "library: sourcing it changes no shell options and works from another directory" {
  run bash -c 'cd / && source "$1" && [[ $- != *e* && $- != *u* ]] && bb_decide "[]" "" "" "" 1791633600' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.action' <<< "$output")" = "none" ]
  run bash -euo pipefail -c 'source "$1"; bb_decide "[]" "" "" ""' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.action' <<< "$output")" = "none" ]
}
