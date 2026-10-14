#!/usr/bin/env bats
# Dry-run budget poller (#2029, slice 2 of #1565).
#
# Drives scripts/budget_poller.sh end-to-end with a MOCKED curl (no live network)
# through the real adapter (scripts/lib/usage-telemetry.sh), the real file seam
# (AGENT_TOKEN_BUDGET_TELEMETRY_FILE), and the pinned verbatim copy of the shipped
# public gates (tests/fixtures/agent-rate-limit). Asserts the logged decision per
# envelope shape (AC #3), the liveness / degraded records (AC #4, #7), the burn
# rate incl. the first-ever poll (AC #5), the fleet-monitor staleness warning
# (AC #4), and statically that nothing writes a variable (AC #2).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
POLLER="$SCRIPT_DIR/scripts/budget_poller.sh"
POLLER_LIB="$SCRIPT_DIR/scripts/lib/budget-poller.sh"
WORKFLOW="$SCRIPT_DIR/.github/workflows/budget-poller.yml"
FIXTURE="$SCRIPT_DIR/tests/fixtures/agent-rate-limit"

setup() {
  bats_require_minimum_version 1.5.0
  # The PRODUCTION public config (weekly_all.enabled=false): the poller must arm a
  # private temp copy itself to report what the glide breaker WOULD do.
  export AGENT_RATE_LIMITS_CONFIG="$FIXTURE/agent-rate-limits.json"
  export BUDGET_POLLER_PUBLIC_LIB="$FIXTURE/agent-rate-limit.sh"

  export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-test"
  export CLAUDE_CODE_VERSION="9.9.9"

  # 1789488000 = 2026-09-15T16:00:00Z, exactly 7 days before WEEKLY_RESET, so
  # the glide threshold is ceiling - reserve*7 = 100 - 14 = 86.
  WEEKLY_RESET="2026-09-22T16:00:00Z"
  SESSION_RESET="2026-09-15T19:00:00Z"
  NOW_EPOCH=1789488000
  export BUDGET_POLLER_NOW="$NOW_EPOCH"

  MOCK_CURL="$BATS_TEST_TMPDIR/curl-mock.sh"
  cat > "$MOCK_CURL" << 'MOCK'
#!/usr/bin/env bash
set -euo pipefail
hdrfile=""; prev=""
for arg in "$@"; do
  if [ "$prev" = "-D" ]; then hdrfile="$arg"; fi
  prev="$arg"
done
status="${MOCK_STATUS:-200}"
if [ -n "$hdrfile" ]; then
  { printf 'HTTP/2 %s\r\n' "$status"
    if [ -n "${MOCK_RETRY_AFTER:-}" ]; then printf 'retry-after: %s\r\n' "$MOCK_RETRY_AFTER"; fi
    printf '\r\n'; } > "$hdrfile"
fi
printf '%s' "${MOCK_BODY:-}"
printf '\n%s' "$status"
MOCK
  chmod +x "$MOCK_CURL"
  export USAGE_TELEMETRY_CURL="$MOCK_CURL"

  export BUDGET_POLLER_LOG="$BATS_TEST_TMPDIR/budget-poller-log.jsonl"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  unset MOCK_STATUS MOCK_BODY MOCK_RETRY_AFTER BUDGET_POLLER_STALE_HOURS
}

_body() {
  # $1 = session percent, $2 = weekly_all percent
  printf '{"limits":[{"kind":"session","percent":%s,"is_active":true,"resets_at":"%s"},{"kind":"weekly_all","percent":%s,"is_active":true,"resets_at":"%s"}]}' \
    "$1" "$SESSION_RESET" "$2" "$WEEKLY_RESET"
}

_last() { tail -n 1 "$BUDGET_POLLER_LOG"; }
_field() { _last | jq -r "$1"; }

# ---------------------------------------------------------------------------
# AC #3 — the logged decision per envelope shape
# ---------------------------------------------------------------------------

@test "200 normal: both gates allow, record is OK with the liveness line" {
  export MOCK_STATUS=200
  MOCK_BODY="$(_body 33 50)"; export MOCK_BODY
  run bash "$POLLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"telemetry read OK, session=33% weekly_all=50%"* ]]
  [ "$(_field .poll)" = "ok" ]
  [ "$(_field .http_status)" = "200" ]
  [ "$(_field .session_pct)" = "33" ]
  [ "$(_field .weekly_all_pct)" = "50" ]
  [ "$(_field .session_resets_at)" = "$SESSION_RESET" ]
  [ "$(_field .weekly_all_resets_at)" = "$WEEKLY_RESET" ]
  [ "$(_field .session_decision)" = "allow" ]
  [ "$(_field .weekly_glide_decision)" = "allow" ]
  [ "$(_field .would_pause)" = "false" ]
  [ "$(_field .decision_window)" = "none" ]
  [ "$(_field .dry_run)" = "true" ]
  [ "$(_field .line)" = "telemetry read OK, session=33% weekly_all=50%" ]
}

@test "200 above the glide threshold: weekly glide gate would defer (armed copy), production arm recorded" {
  export MOCK_STATUS=200
  MOCK_BODY="$(_body 40 90)"; export MOCK_BODY
  run bash "$POLLER"
  [ "$status" -eq 0 ]
  [ "$(_field .poll)" = "ok" ]
  [ "$(_field .session_decision)" = "allow" ]
  [ "$(_field .weekly_glide_decision)" = "defer" ]
  [ "$(_field .weekly_glide_config_enabled)" = "false" ]
  [ "$(_field .would_pause)" = "true" ]
  [ "$(_field .decision_window)" = "weekly_all" ]
  [ "$(_field .decision_pct)" = "90" ]
  [[ "$output" == *"would pause"* ]]
}

@test "200 with session over its threshold: session gate would defer and names the session window" {
  export MOCK_STATUS=200
  MOCK_BODY="$(_body 95 50)"; export MOCK_BODY
  run bash "$POLLER"
  [ "$status" -eq 0 ]
  [ "$(_field .session_decision)" = "defer" ]
  [ "$(_field .weekly_glide_decision)" = "allow" ]
  [ "$(_field .decision_window)" = "session" ]
  [ "$(_field .decision_pct)" = "95" ]
}

@test "429 with retry-after: both gates defer via transport, record is DEGRADED not OK" {
  export MOCK_STATUS=429
  export MOCK_RETRY_AFTER=300
  export MOCK_BODY='{"error":"rate_limited"}'
  run bash "$POLLER"
  [ "$status" -eq 0 ]
  [ "$(_field .http_status)" = "429" ]
  [ "$(_field .retry_after)" = "300" ]
  [ "$(_field .poll)" = "degraded" ]
  [ "$(_field .session_decision)" = "defer" ]
  [ "$(_field .weekly_glide_decision)" = "defer" ]
  [ "$(_field .would_pause)" = "true" ]
  [ "$(_field .decision_window)" = "transport-429" ]
  [[ "$(_field .line)" == "telemetry read DEGRADED"* ]]
  [[ "$output" != *"telemetry read OK"* ]]
}

@test "non-200 (503): gates fail safe to allow, record is DEGRADED and visible" {
  export MOCK_STATUS=503
  export MOCK_BODY='{"error":"unavailable"}'
  run bash "$POLLER"
  [ "$status" -eq 0 ]
  [ "$(_field .poll)" = "degraded" ]
  [ "$(_field .reason)" = "http-503" ]
  [ "$(_field .session_decision)" = "allow" ]
  [ "$(_field .weekly_glide_decision)" = "allow" ]
  [ "$(_field .would_pause)" = "false" ]
  [[ "$output" == *"::warning::"*"telemetry read DEGRADED"* ]]
  [[ "$output" != *"telemetry read OK"* ]]
}

@test "malformed 200 body: gates allow, record is DEGRADED (malformed-body)" {
  export MOCK_STATUS=200
  export MOCK_BODY='this is not json'
  run bash "$POLLER"
  [ "$status" -eq 0 ]
  [ "$(_field .poll)" = "degraded" ]
  [ "$(_field .reason)" = "malformed-body" ]
  [ "$(_field .session_decision)" = "allow" ]
  [ "$(_field .weekly_glide_decision)" = "allow" ]
  [ "$(_field .session_pct)" = "null" ]
  [[ "$(_field .line)" == "telemetry read DEGRADED"* ]]
}

@test "missing token: fail-open DEGRADED record, never fails the run" {
  unset CLAUDE_CODE_OAUTH_TOKEN
  run bash "$POLLER"
  [ "$status" -eq 0 ]
  [ "$(_field .poll)" = "degraded" ]
  [ "$(_field .http_status)" = "0" ]
  [ "$(_field .reason)" = "transport-error" ]
}

@test "public library unavailable: fail-open DEGRADED record, never fails the run" {
  export BUDGET_POLLER_PUBLIC_LIB="$BATS_TEST_TMPDIR/nope.sh"
  export MOCK_STATUS=200
  MOCK_BODY="$(_body 33 50)"; export MOCK_BODY
  run bash "$POLLER"
  [ "$status" -eq 0 ]
  [ "$(_field .poll)" = "degraded" ]
  [ "$(_field .reason)" = "public-library-unavailable" ]
  [ "$(_field .session_decision)" = "unavailable" ]
  [[ "$output" != *"telemetry read OK"* ]]
}

# ---------------------------------------------------------------------------
# AC #5 — burn rate against the previous record, incl. the first-ever poll
# ---------------------------------------------------------------------------

@test "first-ever poll (no previous log): burn rate is null and nothing errors" {
  [ ! -e "$BUDGET_POLLER_LOG" ]
  export MOCK_STATUS=200
  MOCK_BODY="$(_body 33 50)"; export MOCK_BODY
  run bash "$POLLER"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BUDGET_POLLER_LOG" | tr -d ' ')" = "1" ]
  [ "$(_field .burn_session_pph)" = "null" ]
  [ "$(_field .burn_weekly_all_pph)" = "null" ]
  [ "$(_field .burn_basis)" = "first-poll" ]
}

@test "burn rate: percentage points per hour against the previous OK record" {
  export MOCK_STATUS=200
  MOCK_BODY="$(_body 30 48)"; export MOCK_BODY
  BUDGET_POLLER_NOW=$((NOW_EPOCH - 7200)) bash "$POLLER" >/dev/null 2>&1
  MOCK_BODY="$(_body 36 51)"; export MOCK_BODY
  run bash "$POLLER"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BUDGET_POLLER_LOG" | tr -d ' ')" = "2" ]
  [ "$(_field .burn_session_pph)" = "3" ]
  [ "$(_field .burn_weekly_all_pph)" = "1.5" ]
  [ "$(_field .burn_basis)" = "previous-record" ]
}

@test "burn rate: a degraded record in between is skipped; the last OK record is the basis" {
  export MOCK_STATUS=200
  MOCK_BODY="$(_body 30 48)"; export MOCK_BODY
  BUDGET_POLLER_NOW=$((NOW_EPOCH - 3600)) bash "$POLLER" >/dev/null 2>&1
  MOCK_STATUS=503 MOCK_BODY='{}' BUDGET_POLLER_NOW=$((NOW_EPOCH - 1800)) bash "$POLLER" >/dev/null 2>&1
  MOCK_BODY="$(_body 32 49)"; export MOCK_BODY
  run bash "$POLLER"
  [ "$status" -eq 0 ]
  [ "$(_field .burn_session_pph)" = "2" ]
  [ "$(_field .burn_weekly_all_pph)" = "1" ]
}

@test "burn rate: a window that reset since the previous record is not differenced" {
  export MOCK_STATUS=200
  printf '%s\n' '{"epoch":1789484400,"poll":"ok","session_pct":80,"weekly_all_pct":48,"session_resets_at":"2026-09-15T14:00:00Z","weekly_all_resets_at":"2026-09-22T16:00:00Z"}' > "$BUDGET_POLLER_LOG"
  MOCK_BODY="$(_body 5 50)"; export MOCK_BODY
  run bash "$POLLER"
  [ "$status" -eq 0 ]
  [ "$(_field .burn_session_pph)" = "null" ]
  [ "$(_field .burn_weekly_all_pph)" = "2" ]
}

@test "degraded poll still logs a record with a null burn rate" {
  export MOCK_STATUS=503
  export MOCK_BODY='{}'
  run bash "$POLLER"
  [ "$status" -eq 0 ]
  [ "$(_field .burn_session_pph)" = "null" ]
}

@test "the log is bounded to BUDGET_POLLER_MAX_RECORDS (oldest dropped)" {
  export MOCK_STATUS=200
  MOCK_BODY="$(_body 33 50)"; export MOCK_BODY
  export BUDGET_POLLER_MAX_RECORDS=3
  for i in 1 2 3 4; do
    BUDGET_POLLER_NOW=$((NOW_EPOCH + i * 3600)) bash "$POLLER" >/dev/null 2>&1
  done
  [ "$(wc -l < "$BUDGET_POLLER_LOG" | tr -d ' ')" = "3" ]
  [ "$(head -n1 "$BUDGET_POLLER_LOG" | jq -r .epoch)" = "$((NOW_EPOCH + 7200))" ]
}

@test "job summary carries the record, the liveness line and the dry-run banner" {
  export MOCK_STATUS=200
  MOCK_BODY="$(_body 33 50)"; export MOCK_BODY
  run bash "$POLLER"
  [ "$status" -eq 0 ]
  grep -q 'telemetry read OK, session=33% weekly_all=50%' "$GITHUB_STEP_SUMMARY"
  grep -qi 'dry-run' "$GITHUB_STEP_SUMMARY"
  grep -q 'HTTP status' "$GITHUB_STEP_SUMMARY"
}

@test "the token never appears in the log, summary, or output" {
  export MOCK_STATUS=200
  MOCK_BODY="$(_body 33 50)"; export MOCK_BODY
  run bash "$POLLER"
  [[ "$output" != *"sk-ant-oat01-test"* ]]
  run grep -q 'sk-ant-oat01-test' "$BUDGET_POLLER_LOG" "$GITHUB_STEP_SUMMARY"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC #4 — liveness / staleness as seen by the fleet monitor
# ---------------------------------------------------------------------------

_seed_ok() {
  # $1 = epoch of the OK record
  jq -cn --argjson e "$1" '{epoch:$e, ts:"x", poll:"ok", http_status:200, session_pct:33, weekly_all_pct:50,
    session_decision:"allow", weekly_glide_decision:"allow", would_pause:false, decision_window:"none",
    decision_pct:null, line:"telemetry read OK, session=33% weekly_all=50%"}' >> "$BUDGET_POLLER_LOG"
}
_seed_degraded() {
  jq -cn --argjson e "$1" '{epoch:$e, ts:"y", poll:"degraded", http_status:503, reason:"http-503",
    session_decision:"allow", weekly_glide_decision:"allow", would_pause:false, decision_window:"none",
    line:"telemetry read DEGRADED, status=503 reason=http-503"}' >> "$BUDGET_POLLER_LOG"
}

@test "staleness: warning fires when the last OK record is older than the default 3h window" {
  # shellcheck source=scripts/lib/budget-poller.sh
  source "$POLLER_LIB"
  _seed_ok $((NOW_EPOCH - 4 * 3600))
  _seed_degraded $((NOW_EPOCH - 600))
  run bp_staleness_warning "$BUDGET_POLLER_LOG" "$NOW_EPOCH"
  [ "$status" -eq 0 ]
  [[ "$output" == "::warning::"*"budget-poller"*"stale"* ]]
}

@test "staleness: no warning when the last OK record is inside the window" {
  source "$POLLER_LIB"
  _seed_ok $((NOW_EPOCH - 3600))
  run bp_staleness_warning "$BUDGET_POLLER_LOG" "$NOW_EPOCH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "staleness: the window is configurable via BUDGET_POLLER_STALE_HOURS" {
  source "$POLLER_LIB"
  _seed_ok $((NOW_EPOCH - 4 * 3600))
  BUDGET_POLLER_STALE_HOURS=5 run bp_staleness_warning "$BUDGET_POLLER_LOG" "$NOW_EPOCH"
  [ -z "$output" ]
  BUDGET_POLLER_STALE_HOURS=2 run bp_staleness_warning "$BUDGET_POLLER_LOG" "$NOW_EPOCH"
  [[ "$output" == "::warning::"* ]]
}

@test "staleness: a log with only degraded records (or no log) warns — a failure never reads as OK" {
  source "$POLLER_LIB"
  _seed_degraded $((NOW_EPOCH - 60))
  run bp_staleness_warning "$BUDGET_POLLER_LOG" "$NOW_EPOCH"
  [[ "$output" == "::warning::"*"no OK"* ]]
  run bp_staleness_warning "$BATS_TEST_TMPDIR/missing.jsonl" "$NOW_EPOCH"
  [[ "$output" == "::warning::"*"no OK"* ]]
}

@test "fleet section: names the last OK age, the decision window and percent" {
  source "$POLLER_LIB"
  _seed_ok $((NOW_EPOCH - 7200))
  jq -cn --argjson e "$((NOW_EPOCH - 60))" '{epoch:$e, ts:"z", poll:"ok", http_status:200, session_pct:40,
    weekly_all_pct:90, session_decision:"allow", weekly_glide_decision:"defer", would_pause:true,
    decision_window:"weekly_all", decision_pct:90, burn_session_pph:1.5, burn_weekly_all_pph:0.5,
    line:"telemetry read OK, session=40% weekly_all=90%"}' >> "$BUDGET_POLLER_LOG"
  run bp_fleet_section "$BUDGET_POLLER_LOG" "$NOW_EPOCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Budget poller (dry-run)"* ]]
  [[ "$output" == *"0h 1m"* ]]
  [[ "$output" == *"would pause"*"weekly_all"*"90%"* ]]
  [[ "$output" == *"telemetry read OK, session=40% weekly_all=90%"* ]]
  [[ "$output" != *"STALE"* ]]
}

@test "fleet section: flags STALE when the last OK record is past the window" {
  source "$POLLER_LIB"
  _seed_ok $((NOW_EPOCH - 5 * 3600))
  run bp_fleet_section "$BUDGET_POLLER_LOG" "$NOW_EPOCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STALE"* ]]
  [[ "$output" == *"5h 0m"* ]]
}

@test "fleet section: no log renders a NO OK RECORD line without erroring" {
  source "$POLLER_LIB"
  run bp_fleet_section "$BATS_TEST_TMPDIR/missing.jsonl" "$NOW_EPOCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Budget poller (dry-run)"* ]]
  [[ "$output" == *"no OK"* ]]
}

# ---------------------------------------------------------------------------
# AC #1 / #2 — workflow shape and the static no-write assertion
# ---------------------------------------------------------------------------

@test "workflow runs on schedule only (no workflow_dispatch) with read-only permissions" {
  [ -f "$WORKFLOW" ]
  grep -qE '^  schedule:' "$WORKFLOW"
  # Manual dispatch could run branch code holding the OAuth secret.
  run grep -nE '^  workflow_dispatch:' "$WORKFLOW"
  [ "$status" -eq 1 ]
  grep -qE '^[[:space:]]+- cron:' "$WORKFLOW"
  # Only read scopes are granted anywhere in the workflow. (`run !`, not a bare
  # `! grep`: errexit ignores a negated command, so a bare `!` asserts nothing.)
  run grep -nE '^[[:space:]]+[a-z-]+:[[:space:]]*write([[:space:]]|$)' "$WORKFLOW"
  [ "$status" -eq 1 ]
  run grep -nE 'write-all' "$WORKFLOW"
  [ "$status" -eq 1 ]
  grep -qE '^[[:space:]]+contents:[[:space:]]*read' "$WORKFLOW"
  # Authenticates with the existing secret only.
  grep -q 'secrets.CLAUDE_CODE_OAUTH_TOKEN' "$WORKFLOW"
}

@test "static: workflow and poller scripts contain no pause-variable or variables-API write" {
  local f
  for f in "$WORKFLOW" "$POLLER" "$POLLER_LIB"; do
    [ -f "$f" ]
    run grep -nE 'AGENTS_PAUSED|AGENTS_PAUSE_SOURCE' "$f"
    [ "$status" -eq 1 ]
    run grep -nE 'gh[[:space:]]+variable[[:space:]]+(set|delete)' "$f"
    [ "$status" -eq 1 ]
    run grep -niE 'actions/variables' "$f"
    [ "$status" -eq 1 ]
    run grep -nE '(-X|--method)[[:space:]]*(POST|PUT|PATCH|DELETE)' "$f"
    [ "$status" -eq 1 ]
    run grep -niE 'updateVariable|createVariable|deleteVariable|(create|update|delete)(Org|Repo)Variable' "$f"
    [ "$status" -eq 1 ]
  done
}

@test "static: the no-write assertion is not vacuous (it trips on a planted write)" {
  local planted="$BATS_TEST_TMPDIR/planted.sh"
  printf 'gh variable set AGENTS_PAUSED --org combsmith --body true\n' > "$planted"
  run grep -nE 'AGENTS_PAUSED|AGENTS_PAUSE_SOURCE' "$planted"
  [ "$status" -eq 0 ]
  run grep -nE 'gh[[:space:]]+variable[[:space:]]+(set|delete)' "$planted"
  [ "$status" -eq 0 ]
}

@test "bp_stale_hours: a leading-zero value is normalized to base 10" {
  run bash -c 'source scripts/lib/budget-poller.sh; BUDGET_POLLER_STALE_HOURS=08 bp_stale_hours'
  [ "$status" -eq 0 ]
  [ "$output" = "8" ]
}

@test "bp_build_record: a malformed now does not abort, and unavailable gates read indeterminate" {
  run bash -c 'source scripts/lib/budget-poller.sh
    r="$(bp_build_record notanumber 200 "" 10 20 a b unavailable unavailable false "" "")" || exit 1
    bp_decision_text "$r"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"indeterminate"* ]]
}

# ---------------------------------------------------------------------------
# #2148 — bp_download_latest_log: the artifact trust filter
#
# `gh` and `unzip` are replaced by a PATH shim (no live network). The `gh` shim
# evaluates the function's OWN `--jq` filter against per-page fixture listings,
# so dropping the head_branch filter, --paginate, or the branch allow-list is
# observable. Fixture "zips" hold the JSONL directly; the `unzip` shim copies one
# into the -d directory (content starting CORRUPT makes it fail).
# ---------------------------------------------------------------------------

_dl_setup() {
  MOCK_GH_DIR="$BATS_TEST_TMPDIR/gh"
  mkdir -p "$MOCK_GH_DIR/zip" "$BATS_TEST_TMPDIR/shim"
  export MOCK_GH_DIR MOCK_DEFAULT_BRANCH="${1-main}"
  cat > "$BATS_TEST_TMPDIR/shim/gh" << 'MOCK'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$MOCK_GH_DIR/calls.log"
[ "${1:-}" = "api" ] || exit 1
shift
paginate=0; filter="."; path=""
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) paginate=1 ;;
    --jq) filter="$2"; shift ;;
    *) path="$1" ;;
  esac
  shift
done
case "$path" in
  repos/*/*/actions/artifacts\?*)
    n=1
    while [ -f "$MOCK_GH_DIR/page$n.json" ] || [ -f "$MOCK_GH_DIR/page$n.fail" ]; do
      [ -f "$MOCK_GH_DIR/page$n.fail" ] && exit 1
      jq -r "$filter" "$MOCK_GH_DIR/page$n.json" || exit 1
      [ "$paginate" -eq 1 ] || break
      n=$((n + 1))
    done ;;
  repos/*/*/actions/artifacts/*/zip)
    id="${path%/zip}"; id="${id##*/}"
    printf '%s\n' "$id" >> "$MOCK_GH_DIR/downloads.log"
    [ -f "$MOCK_GH_DIR/zip/$id" ] || exit 1
    cat "$MOCK_GH_DIR/zip/$id" ;;
  repos/*/*)
    [ -f "$MOCK_GH_DIR/repo.fail" ] && exit 1
    jq -n --arg b "$MOCK_DEFAULT_BRANCH" '{default_branch: $b}' | jq -r "$filter" ;;
  *) exit 1 ;;
esac
MOCK
  cat > "$BATS_TEST_TMPDIR/shim/unzip" << 'MOCK'
#!/usr/bin/env bash
zip=""; dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d) dir="$2"; shift ;;
    -*) ;;
    *) zip="$1" ;;
  esac
  shift
done
[ -n "$zip" ] && [ -n "$dir" ] || exit 10
head -n 1 "$zip" | grep -q '^CORRUPT' && exit 9
mkdir -p "$dir" && cp "$zip" "$dir/budget-poller-log.jsonl"
MOCK
  chmod +x "$BATS_TEST_TMPDIR/shim/gh" "$BATS_TEST_TMPDIR/shim/unzip"
  DL_DEST="$BATS_TEST_TMPDIR/dest.jsonl"
}

# _art <id> <head_branch> <created_at> [expired=false] — one listing entry.
_art() {
  jq -nc --argjson id "$1" --arg b "$2" --arg c "$3" --argjson e "${4:-false}" \
    '{id: $id, name: "budget-poller-log", expired: $e, created_at: $c, workflow_run: {head_branch: $b}}'
}

# _page <n> <artifact-json>... — write listing page n (API order: newest first).
_page() {
  local n="$1"; shift
  printf '%s\n' "$@" | jq -s '{total_count: length, artifacts: .}' > "$MOCK_GH_DIR/page$n.json"
}

# _zip <id> [content] — a downloadable artifact whose log is one valid record.
_zip() {
  printf '%s\n' "${2:-{\"poll\":\"ok\",\"artifact\":$1\}}" > "$MOCK_GH_DIR/zip/$1"
}

_download() {
  PATH="$BATS_TEST_TMPDIR/shim:$PATH" run bash -c \
    'source "$1"; bp_download_latest_log combsmith/.github-private "$2"' _ "$POLLER_LIB" "$DL_DEST"
}

_chosen() { jq -r '.artifact' "$DL_DEST"; }

@test "download (#2148 AC1): a newer PR-branch artifact is ignored for an older default-branch one" {
  _dl_setup main
  _page 1 "$(_art 900 attacker/pr-branch 2026-09-15T15:00:00Z)" \
          "$(_art 100 main 2026-09-15T14:00:00Z)"
  _zip 900 '{"poll":"ok","artifact":900,"session_pct":0}'
  _zip 100
  _download
  [ "$status" -eq 0 ]
  [ "$(_chosen)" = "100" ]
  # The PR-branch artifact is never even fetched.
  run grep -qx 900 "$MOCK_GH_DIR/downloads.log"
  [ "$status" -eq 1 ]
}

@test "download (#2148 AC2): a single page with one matching artifact is selected" {
  _dl_setup main
  _page 1 "$(_art 42 main 2026-09-15T14:00:00Z)"
  _zip 42
  _download
  [ "$status" -eq 0 ]
  [ "$(_chosen)" = "42" ]
  # The listing is scoped to the artifact name and paginated.
  grep -q -- '--paginate repos/combsmith/.github-private/actions/artifacts?name=budget-poller-log&per_page=100' \
    "$MOCK_GH_DIR/calls.log"
}

@test "download (#2148 AC2): the repo's actual default branch is the trusted one, not a hard-coded main" {
  _dl_setup develop
  _page 1 "$(_art 200 main 2026-09-15T15:00:00Z)" \
          "$(_art 100 develop 2026-09-15T14:00:00Z)"
  _zip 200
  _zip 100
  _download
  [ "$status" -eq 0 ]
  [ "$(_chosen)" = "100" ]
}

@test "download (#2148 AC3): the newest trusted artifact on page 2 is found when page 1 is all other branches" {
  _dl_setup main
  _page 1 "$(_art 905 pr-a 2026-09-15T15:05:00Z)" \
          "$(_art 904 pr-b 2026-09-15T15:04:00Z)" \
          "$(_art 903 pr-c 2026-09-15T15:03:00Z)"
  _page 2 "$(_art 300 main 2026-09-15T13:00:00Z)" \
          "$(_art 200 main 2026-09-15T12:00:00Z)"
  _zip 905; _zip 904; _zip 903; _zip 300; _zip 200
  _download
  [ "$status" -eq 0 ]
  [ "$(_chosen)" = "300" ]
}

@test "download (#2148 AC4): a listing failure on a later page returns 2 and does not abort the caller" {
  _dl_setup main
  _page 1 "$(_art 100 main 2026-09-15T14:00:00Z)"
  touch "$MOCK_GH_DIR/page2.fail"
  _zip 100
  printf 'durable\n' > "$DL_DEST"
  PATH="$BATS_TEST_TMPDIR/shim:$PATH" run bash -c '
    set -euo pipefail
    source "$1"
    rc=0
    bp_download_latest_log combsmith/.github-private "$2" || rc=$?
    echo "rc=$rc"
    echo "caller continued"' _ "$POLLER_LIB" "$DL_DEST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=2"* ]]
  [[ "$output" == *"caller continued"* ]]
  # A partial listing is not trusted: nothing is downloaded, dest is untouched.
  [ ! -e "$MOCK_GH_DIR/downloads.log" ]
  [ "$(cat "$DL_DEST")" = "durable" ]
}

@test "download (#2148 AC5): no usable artifact returns 1 (empty listing, other branches only, all expired)" {
  _dl_setup main
  _page 1
  _download
  [ "$status" -eq 1 ]

  _page 1 "$(_art 900 pr-branch 2026-09-15T15:00:00Z)"
  _zip 900
  _download
  [ "$status" -eq 1 ]

  _page 1 "$(_art 100 main 2026-09-15T14:00:00Z true)"
  _zip 100
  _download
  [ "$status" -eq 1 ]
  [ ! -e "$DL_DEST" ]
}

@test "download (#2148 AC5): an expired newer default-branch artifact is skipped" {
  _dl_setup main
  _page 1 "$(_art 200 main 2026-09-15T15:00:00Z true)" \
          "$(_art 100 main 2026-09-15T14:00:00Z)"
  _zip 200
  _zip 100
  _download
  [ "$status" -eq 0 ]
  [ "$(_chosen)" = "100" ]
  run grep -qx 200 "$MOCK_GH_DIR/downloads.log"
  [ "$status" -eq 1 ]
}

@test "download (#2148 AC6): unreadable or non-JSON newer artifacts fall through to the next older valid one" {
  _dl_setup main
  _page 1 "$(_art 50 main 2026-09-15T15:00:00Z)" \
          "$(_art 40 main 2026-09-15T14:50:00Z)" \
          "$(_art 30 main 2026-09-15T14:40:00Z)" \
          "$(_art 20 main 2026-09-15T14:30:00Z)" \
          "$(_art 10 main 2026-09-15T14:20:00Z)"
  # 50: download fails; 40: unzip fails; 30: empty log; 20: not JSON; 10: valid.
  _zip 40 'CORRUPT'
  : > "$MOCK_GH_DIR/zip/30"
  _zip 20 'not json {'
  _zip 10
  _download
  [ "$status" -eq 0 ]
  [ "$(_chosen)" = "10" ]
  [ "$(tr '\n' ' ' < "$MOCK_GH_DIR/downloads.log")" = "50 40 30 20 10 " ]
}

@test "download (#2148 AC7): an unsafe default-branch name falls back to main and is never interpolated raw" {
  local unsafe
  for unsafe in 'main" or true or "' 'x"] | .[] | ["' 'main$(touch pwned)' 'main branch' ''; do
    _dl_setup "$unsafe"
    rm -f "$MOCK_GH_DIR/calls.log" "$DL_DEST"
    # Newer artifacts from the unsafe-named branch and a PR branch; older on main.
    _page 1 "$(_art 901 "$unsafe" 2026-09-15T15:01:00Z)" \
            "$(_art 900 pr-branch 2026-09-15T15:00:00Z)" \
            "$(_art 100 main 2026-09-15T14:00:00Z)"
    _zip 901; _zip 900; _zip 100
    _download
    [ "$status" -eq 0 ]
    [ "$(_chosen)" = "100" ]
    grep -qF '.workflow_run.head_branch == "main")' "$MOCK_GH_DIR/calls.log"
    if [ -n "$unsafe" ]; then
      run grep -qF -- "$unsafe" "$MOCK_GH_DIR/calls.log"
      [ "$status" -eq 1 ]
    fi
  done
}

@test "download (#2148 AC7): a failed default-branch lookup falls back to main" {
  _dl_setup develop
  touch "$MOCK_GH_DIR/repo.fail"
  _page 1 "$(_art 200 develop 2026-09-15T15:00:00Z)" \
          "$(_art 100 main 2026-09-15T14:00:00Z)"
  _zip 200; _zip 100
  _download
  [ "$status" -eq 0 ]
  [ "$(_chosen)" = "100" ]
}
