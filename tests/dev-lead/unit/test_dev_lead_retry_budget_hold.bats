#!/usr/bin/env bats
# Unit tests for the retry cron's budget hold (#2139, split 1 of 2 from #1863).
#
# dev-lead-retry.sh reads the dry-run budget poller's published
# `budget-poller-log` artifact ONCE per cron run (bp_download_latest_log), takes
# the latest poll=="ok" record (bp_last_ok), and holds status=rate-limited
# retries while the `session` or `weekly_all` window is at/above 100% with a
# future reset. Every failure fails open to today's retry behaviour.
#
# `gh` is a PATH shim (no live network): it evaluates the caller's own `--jq`
# filter against fixture REST payloads, and serves real zip files built with
# python3's zipfile, so the real `unzip` and the poller's own download helper run.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
RETRY_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-retry.sh"
RETRY_WORKFLOW="$SCRIPT_DIR/.github/workflows/dev-lead-retry.yml"
POLLER_LIB="$SCRIPT_DIR/scripts/lib/budget-poller.sh"

# 2026-10-09T12:00:00Z
NOW_EPOCH=1791547200

setup() {
  MOCK_DIR="$BATS_TEST_TMPDIR/mock"
  mkdir -p "$MOCK_DIR/zip" "$BATS_TEST_TMPDIR/shim"
  export MOCK_DIR
  export PATH="$BATS_TEST_TMPDIR/shim:$PATH"
  export DRY_RUN="true"
  export NOW_ISO="2026-10-09T12:00:00Z"
  export DISPATCH_DELAY_SEC=0
  unset BUDGET_POLLER_STALE_HOURS SWEEP_AGENT_REF BUDGET_HOLD_UNTIL BUDGET_HOLD_WINDOW
  # Default fixtures: no artifacts, no issue comments, no open PRs.
  printf '{"total_count":0,"artifacts":[]}' > "$MOCK_DIR/artifacts.json"
  printf '[]' > "$MOCK_DIR/comments.json"
  printf '[]' > "$MOCK_DIR/pulls.json"
  printf '[]' > "$MOCK_DIR/issues.json"
  printf '[]' > "$MOCK_DIR/repos.json"

  cat > "$BATS_TEST_TMPDIR/shim/gh" << 'MOCK'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$MOCK_DIR/calls.log"
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "list" ]; then
  cat "$MOCK_DIR/repos.json"; exit 0
fi
[ "${1:-}" = "api" ] || exit 1
shift
filter="."; path=""
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) ;;
    --jq) filter="$2"; shift ;;
    --method|-X|-f|-F|--input) shift ;;
    *) path="$1" ;;
  esac
  shift
done
_eval() { jq -r "$filter" "$1"; }
case "$path" in
  repos/*/*/actions/artifacts\?*)
    printf 'list\n' >> "$MOCK_DIR/artifact-lists.log"
    [ -f "$MOCK_DIR/list.fail" ] && exit 1
    _eval "$MOCK_DIR/artifacts.json" ;;
  repos/*/*/actions/artifacts/*/zip)
    id="${path%/zip}"; id="${id##*/}"
    printf '%s\n' "$id" >> "$MOCK_DIR/downloads.log"
    [ -f "$MOCK_DIR/zip/$id" ] || exit 1
    cat "$MOCK_DIR/zip/$id" ;;
  repos/*/*/dispatches)
    printf 'dispatch\n' >> "$MOCK_DIR/dispatches.log" ;;
  repos/*/*/issues/*/comments*) _eval "$MOCK_DIR/comments.json" ;;
  repos/*/*/issues\?*) _eval "$MOCK_DIR/issues.json" ;;
  repos/*/*/pulls\?*) _eval "$MOCK_DIR/pulls.json" ;;
  *)
    if [[ "$path" =~ ^repos/[^/]+/[^/]+$ ]]; then
      jq -n '{default_branch: "main"}' | jq -r "$filter"
    else
      exit 1
    fi ;;
esac
MOCK
  chmod +x "$BATS_TEST_TMPDIR/shim/gh"

  source "$RETRY_SCRIPT"
}

# _artifact <id> <jsonl-file> — publish <jsonl-file> as the newest default-branch
# budget-poller-log artifact (a real zip, as upload-artifact produces).
_artifact() {
  local id="$1" log="$2"
  python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.write(sys.argv[2], "budget-poller-log.jsonl")' "$MOCK_DIR/zip/$id" "$log"
  jq -n --argjson id "$id" '{total_count: 1, artifacts: [{id: $id, name: "budget-poller-log",
    expired: false, created_at: "2026-10-09T11:30:00Z", workflow_run: {head_branch: "main"}}]}' \
    > "$MOCK_DIR/artifacts.json"
}

# _record <epoch> <session_pct> <weekly_pct> <session_reset> <weekly_reset> [poll]
# — a minimal record in the poller's shape (fields as bp_build_record names them).
_record() {
  jq -cn --argjson e "$1" --arg sp "$2" --arg wp "$3" --arg sr "$4" --arg wr "$5" --arg p "${6:-ok}" '
    def n($v): if $v == "" then null else ($v | tonumber) end;
    def s($v): if $v == "" then null else $v end;
    {epoch: $e, ts: ($e | todate), poll: $p, session_pct: n($sp), weekly_all_pct: n($wp),
     session_resets_at: s($sr), weekly_all_resets_at: s($wr)}'
}

# _publish <record-line>... — publish these lines as the artifact's log.
_publish() {
  printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/log.jsonl"
  _artifact 101 "$BATS_TEST_TMPDIR/log.jsonl"
}

# _init — run budget_hold_init in THIS shell (its globals are what later scans
# read) and capture its log in $HOLD_LOG.
_init() {
  HOLD_LOG="$BATS_TEST_TMPDIR/hold.log"
  budget_hold_init > "$HOLD_LOG" 2>&1
}

# _rate_limited_issue [status] — issues 478 and 479's newest markers, their own
# reset already passed (so today's logic would retry them).
_rate_limited_issue() {
  jq -n --arg s "${1:-rate-limited}" '[478, 479] | map(
    {body: "<!-- dev-lead-issue \(.) status=\($s) attempt=1 reason=rate-limited run=9 reset=2026-10-09T08:00:00Z -->"})' \
    > "$MOCK_DIR/comments.json"
}

_downloads() { [ -f "$MOCK_DIR/downloads.log" ] && wc -l < "$MOCK_DIR/downloads.log" | tr -d ' ' || echo 0; }

# ── AC1: the hold itself ─────────────────────────────────────────────────────

@test "hold (#2139 AC1): weekly window at 100% with a future reset suppresses a rate-limited retry" {
  _publish "$(_record $((NOW_EPOCH - 1800)) 40 100 2026-10-09T14:00:00Z 2026-10-12T16:00:00Z)"
  _init
  [ "$BUDGET_HOLD_UNTIL" = "2026-10-12T16:00:00Z" ]
  grep -qx 'retry-cron: weekly window exhausted, holding retries until 2026-10-12T16:00:00Z (poll 0h 30m old)' "$HOLD_LOG"

  _rate_limited_issue
  run scan_issue_for_retry petry-projects/demo 478
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0" ]
  [[ "$output" == *"[skip] issue #478 rate-limit held by the budget poller until 2026-10-12T16:00:00Z"* ]]
  [[ "$output" != *"would dispatch"* ]]
}

@test "hold (#2139 AC1): the same exhausted weekly window with a PAST reset does not hold" {
  _publish "$(_record $((NOW_EPOCH - 1800)) 40 100 2026-10-09T14:00:00Z 2026-10-09T11:00:00Z)"
  _init
  [ -z "$BUDGET_HOLD_UNTIL" ]
  grep -qx 'retry-cron: no Claude window exhausted with a future reset (poll 0h 30m old), retrying as usual' "$HOLD_LOG"

  _rate_limited_issue
  run scan_issue_for_retry petry-projects/demo 478
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
}

@test "hold (#2139 AC1): a session window at 100% holds only until its OWN reset" {
  _publish "$(_record $((NOW_EPOCH - 600)) 100 60 2026-10-09T14:00:00Z 2026-10-12T16:00:00Z)"
  _init
  [ "$BUDGET_HOLD_UNTIL" = "2026-10-09T14:00:00Z" ]
  grep -qx 'retry-cron: session window exhausted, holding retries until 2026-10-09T14:00:00Z (poll 0h 10m old)' "$HOLD_LOG"

  _rate_limited_issue
  run scan_issue_for_retry petry-projects/demo 478
  [ "${lines[-1]}" = "0" ]

  # Past the session reset (the weekly window is not exhausted), it retries.
  NOW_ISO="2026-10-09T14:00:01Z"
  run scan_issue_for_retry petry-projects/demo 478
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
}

@test "hold (#2139 AC1): when both windows are exhausted the LATER reset is honoured" {
  _publish "$(_record $((NOW_EPOCH - 600)) 100 100 2026-10-09T14:00:00Z 2026-10-12T16:00:00Z)"
  _init
  [ "$BUDGET_HOLD_UNTIL" = "2026-10-12T16:00:00Z" ]
  grep -qx 'retry-cron: session and weekly windows exhausted, holding retries until 2026-10-12T16:00:00Z (poll 0h 10m old)' "$HOLD_LOG"

  # Order of the resets does not matter: a later session reset wins too.
  run budget_hold_from_record "$(_record $((NOW_EPOCH - 600)) 100 100 2026-10-13T01:00:00Z 2026-10-12T16:00:00Z)" "$NOW_EPOCH"
  [ "$output" = "hold session+weekly 2026-10-13T01:00:00Z" ]
}

@test "hold (#2139 AC1): below-limit windows do not hold" {
  _publish "$(_record $((NOW_EPOCH - 600)) 99 99 2026-10-09T14:00:00Z 2026-10-12T16:00:00Z)"
  _init
  [ -z "$BUDGET_HOLD_UNTIL" ]
  grep -q 'retry-cron: no Claude window exhausted with a future reset' "$HOLD_LOG"
  _rate_limited_issue
  run scan_issue_for_retry petry-projects/demo 478
  [ "${lines[-1]}" = "1" ]
}

@test "hold (#2139 AC1): over 100% counts as exhausted; an offset or fractional reset is normalised" {
  run budget_hold_from_record "$(_record "$NOW_EPOCH" 20 104 "" 2026-10-12T18:00:00.512+02:00)" "$NOW_EPOCH"
  [ "$output" = "hold weekly 2026-10-12T16:00:00Z" ]
}

@test "hold (#2139): weekly_scoped is never read (per-model, handled by model fallback)" {
  local rec
  rec="$(_record "$NOW_EPOCH" 10 10 2026-10-09T14:00:00Z 2026-10-12T16:00:00Z \
    | jq -c '. + {weekly_scoped_pct: 100, weekly_scoped_resets_at: "2026-10-12T16:00:00Z"}')"
  run budget_hold_from_record "$rec" "$NOW_EPOCH"
  [ "$output" = "none" ]
  # The script mentions it only in comments saying it is never read.
  grep -q 'weekly_scoped' "$RETRY_SCRIPT"
  [ -z "$(grep -n 'weekly_scoped' "$RETRY_SCRIPT" | grep -v '^[0-9]*:[[:space:]]*#')" ]
}

@test "hold (#2139): only status=rate-limited retries are held — a status=failed issue still retries" {
  _publish "$(_record $((NOW_EPOCH - 600)) 40 100 "" 2026-10-12T16:00:00Z)"
  _init
  [ -n "$BUDGET_HOLD_UNTIL" ]
  _rate_limited_issue failed
  run scan_issue_for_retry petry-projects/demo 478
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
}

# _scan_pr <json-array-of-marker-bodies> — scan_pr_for_rate_limits on PR 2000.
_scan_pr() {
  export MARKERS_JSON="$1"
  gh() {
    case "$*" in
      *"/pulls/2000"*) echo '{"state":"open","head":{"sha":"abc"},"labels":[]}' ;;
      *"/comments"*) echo "$MARKERS_JSON" ;;
      *) echo '[]' ;;
    esac
  }
  pr_resume_suppressed() { return 1; }
  post_dispatch_guard() { :; }
  fetch_pr_comment_nodes() { echo '[{"id":"IC_cr"}]'; }
  stale_disposition_needs_dispatch() { return 0; }
  dispatch_reviews_retry() { echo "DISPATCH intent=$4" >&2; }
  dispatch_ci_retry() { echo "DISPATCH ci" >&2; }
  run scan_pr_for_rate_limits "petry-projects/demo" 2000
}

@test "hold (#2139): a rate-limited fix-reviews PR is held, and so is its #2008 edit re-dispatch" {
  _publish "$(_record $((NOW_EPOCH - 600)) 40 100 "" 2026-10-12T16:00:00Z)"
  _init
  _scan_pr '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=rate-limited reason=rate-limited reset=2026-10-09T08:00:00Z -->"]'
  [ "${lines[-1]}" = "0" ]
  [[ "$output" != *"DISPATCH"* ]]
  [[ "$output" == *"[skip] fix-reviews rate-limit for PR 2000 held by the budget poller until 2026-10-12T16:00:00Z"* ]]
}

@test "hold (#2139): a rate-limited fix-ci PR is held" {
  _publish "$(_record $((NOW_EPOCH - 600)) 40 100 "" 2026-10-12T16:00:00Z)"
  _init
  _scan_pr '["<!-- dev-lead-fix-ci sha=abc status=rate-limited check=lint reset=2026-10-09T08:00:00Z -->"]'
  [ "${lines[-1]}" = "0" ]
  [[ "$output" != *"DISPATCH"* ]]
  [[ "$output" == *"[skip] fix-ci rate-limit for PR 2000 held by the budget poller until 2026-10-12T16:00:00Z"* ]]
}

@test "hold (#2139): a status=blocked fix-reviews hold (not a quota) is not held by the budget" {
  _publish "$(_record $((NOW_EPOCH - 600)) 40 100 "" 2026-10-12T16:00:00Z)"
  _init
  _scan_pr '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=blocked reason=ci -->"]'
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"DISPATCH intent=fix-reviews"* ]]
}

@test "hold (#2139): without a hold the rate-limited PR retries exactly as today" {
  _publish "$(_record $((NOW_EPOCH - 600)) 40 50 "" 2026-10-12T16:00:00Z)"
  _init
  _scan_pr '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=rate-limited reason=rate-limited reset=2026-10-09T08:00:00Z -->"]'
  [ "${lines[-1]}" = "1" ]
  [ "$(grep -c 'DISPATCH' <<< "$output")" -eq 1 ]
}

# ── AC2: every failure mode and a stale record fail open ─────────────────────

# _assert_fail_open <expected-reason-substring> — the init logged a fail-open
# line with this reason, set no hold, and a rate-limited issue retries as today.
_assert_fail_open() {
  [ -z "${BUDGET_HOLD_UNTIL:-}" ]
  grep -q "^retry-cron: budget hold fail-open (.*$1.*), retrying as usual$" "$HOLD_LOG"
  [ "$(grep -c '^retry-cron:' "$HOLD_LOG")" -eq 1 ]
  _rate_limited_issue
  run scan_issue_for_retry petry-projects/demo 478
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
  [[ "$output" != *"held by the budget poller"* ]]
}

@test "fail-open (#2139 AC2): no artifact at all (poller not yet running)" {
  _init
  _assert_fail_open "no readable budget-poller-log artifact"
}

@test "fail-open (#2139 AC2): only an expired artifact" {
  _publish "$(_record $((NOW_EPOCH - 600)) 40 100 "" 2026-10-12T16:00:00Z)"
  jq '.artifacts[0].expired = true' "$MOCK_DIR/artifacts.json" > "$MOCK_DIR/a.tmp" && mv "$MOCK_DIR/a.tmp" "$MOCK_DIR/artifacts.json"
  _init
  _assert_fail_open "no readable budget-poller-log artifact"
}

@test "fail-open (#2139 AC2): artifact listing API error" {
  _publish "$(_record $((NOW_EPOCH - 600)) 40 100 "" 2026-10-12T16:00:00Z)"
  touch "$MOCK_DIR/list.fail"
  _init
  _assert_fail_open "artifact download error"
}

@test "fail-open (#2139 AC2): the zip download itself fails" {
  _publish "$(_record $((NOW_EPOCH - 600)) 40 100 "" 2026-10-12T16:00:00Z)"
  rm -f "$MOCK_DIR/zip/101"
  _init
  _assert_fail_open "no readable budget-poller-log artifact"
}

@test "fail-open (#2139 AC2): an unparseable record (no epoch) is not believed" {
  _publish '{"poll":"ok","weekly_all_pct":100,"weekly_all_resets_at":"2026-10-12T16:00:00Z"}'
  _init
  _assert_fail_open "unparseable record"
}

@test "fail-open (#2139 AC2): a log of garbage lines has no poll==ok record" {
  _publish 'not json at all' '{"poll":"ok"'
  _init
  # bp_download_latest_log rejects a log jq cannot parse, so this reads as no artifact.
  _assert_fail_open "no readable budget-poller-log artifact"
}

@test "fail-open (#2139 AC2): no poll==ok record (only degraded polls)" {
  _publish "$(_record $((NOW_EPOCH - 600)) 40 100 "" 2026-10-12T16:00:00Z degraded)"
  _init
  _assert_fail_open "no poll==ok record"
}

@test "fail-open (#2139 AC2): a missing window (exhausted weekly with no reset) does not hold" {
  _publish "$(_record $((NOW_EPOCH - 600)) 40 100 "" "")"
  _init
  _assert_fail_open "weekly_all window missing or unparseable"
}

@test "fail-open (#2139 AC2): a missing pct does not hold" {
  _publish "$(_record $((NOW_EPOCH - 600)) "" 50 "" 2026-10-12T16:00:00Z)"
  _init
  _assert_fail_open "session window missing or unparseable"
}

@test "fail-open (#2139 AC2): an unparseable reset does not hold" {
  _publish "$(_record $((NOW_EPOCH - 600)) 40 100 "" "next week")"
  _init
  _assert_fail_open "weekly_all window missing or unparseable"
}

@test "fail-open (#2139 AC2): a record older than bp_stale_hours is ignored" {
  # Default window is 6h (raised from 3h so a dropped hourly cron tick does not
  # make the record stale): 6h01m old is stale, even though it says exhausted.
  _publish "$(_record $((NOW_EPOCH - 21660)) 40 100 "" 2026-10-12T16:00:00Z)"
  _init
  _assert_fail_open "stale record, poll 6h 1m old > 6h"
}

@test "hold (#2139 AC2): a 3h01m-old record is FRESH under the 6h default, so the hold applies" {
  _publish "$(_record $((NOW_EPOCH - 10860)) 40 100 "" 2026-10-12T16:00:00Z)"
  _init
  [ "$BUDGET_HOLD_UNTIL" = "2026-10-12T16:00:00Z" ]
  grep -q '(poll 3h 1m old)' "$HOLD_LOG"
}

@test "fail-open (#2139 AC2): a 3h01m-old record is STALE when BUDGET_POLLER_STALE_HOURS=3" {
  export BUDGET_POLLER_STALE_HOURS=3
  _publish "$(_record $((NOW_EPOCH - 10860)) 40 100 "" 2026-10-12T16:00:00Z)"
  _init
  _assert_fail_open "stale record, poll 3h 1m old > 3h"
}

@test "fail-open (#2139 AC2): the staleness bound is the poller's own (BUDGET_POLLER_STALE_HOURS)" {
  export BUDGET_POLLER_STALE_HOURS=1
  _publish "$(_record $((NOW_EPOCH - 3900)) 40 100 "" 2026-10-12T16:00:00Z)"
  _init
  _assert_fail_open "stale record, poll 1h 5m old > 1h"
}

@test "fail-open (#2139 AC2): the latest OK record is used even behind a newer degraded poll" {
  _publish "$(_record $((NOW_EPOCH - 1200)) 40 100 "" 2026-10-12T16:00:00Z)" \
           "$(_record $((NOW_EPOCH - 600)) "" "" "" "" degraded)"
  _init
  [ "$BUDGET_HOLD_UNTIL" = "2026-10-12T16:00:00Z" ]
  grep -q '(poll 0h 20m old)' "$HOLD_LOG"
}

@test "fail-open (#2139): is_reset_in_future keeps its default (unknown reset = retry)" {
  run is_reset_in_future ""
  [ "$status" -eq 1 ]
  run budget_hold_active
  [ "$status" -eq 1 ]
}

# ── AC3: the artifact is downloaded at most once per cron run ────────────────

@test "once (#2139 AC3): main downloads the artifact once however many items are retried" {
  _publish "$(_record $((NOW_EPOCH - 600)) 40 100 "" 2026-10-12T16:00:00Z)"
  printf '["petry-projects/a","petry-projects/b","petry-projects/c"]' > "$MOCK_DIR/repos.json"
  jq -n '[{number: 478, labels: [{name: "dev-lead"}], pull_request: null},
          {number: 479, labels: [{name: "dev-lead"}], pull_request: null}]' > "$MOCK_DIR/issues.json"
  _rate_limited_issue

  run main
  [ "$status" -eq 0 ]
  [ "$(_downloads)" -eq 1 ]
  [ "$(wc -l < "$MOCK_DIR/artifact-lists.log")" -eq 1 ]
  [ "$(grep -c '^retry-cron:' <<< "$output")" -eq 1 ]
  [ "$(grep -c 'held by the budget poller' <<< "$output")" -eq 6 ]
  [[ "$output" != *"would dispatch"* ]]
}

@test "once (#2139 AC3): with no hold, main still reads once and retries every item as today" {
  printf '["petry-projects/a","petry-projects/b"]' > "$MOCK_DIR/repos.json"
  jq -n '[{number: 478, labels: [{name: "dev-lead"}], pull_request: null}]' > "$MOCK_DIR/issues.json"
  _rate_limited_issue

  run main
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MOCK_DIR/artifact-lists.log")" -eq 1 ]
  [ "$(grep -c 'would dispatch dev-lead-issue-retry' <<< "$output")" -eq 2 ]
  [[ "$output" == *"retry-cron: budget hold fail-open (no readable budget-poller-log artifact), retrying as usual"* ]]
}

# ── AC4: workflow change is only `actions: read`, and no Claude token ───────

@test "workflow (#2139 AC4): no CLAUDE_CODE_OAUTH_TOKEN in dev-lead-retry.yml" {
  run grep -n 'CLAUDE_CODE_OAUTH_TOKEN' "$RETRY_WORKFLOW"
  [ "$status" -eq 1 ]
}

@test "workflow (#2139 AC4): permissions are exactly contents: write + actions: read, none per job" {
  run python3 -I -c 'import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
assert doc["permissions"] == {"contents": "write", "actions": "read"}, doc["permissions"]
for name, job in doc["jobs"].items():
    assert "permissions" not in job, name
print("ok")' "$RETRY_WORKFLOW"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "workflow (#2139 AC4): secrets referenced are only the existing GitHub PATs/token" {
  run bash -c "grep -oE 'secrets\.[A-Za-z0-9_]+' '$RETRY_WORKFLOW' | sort -u"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'secrets.GH_PAT_DON_PETRY\nsecrets.GH_PAT_WORKFLOWS\nsecrets.GITHUB_TOKEN')" ]
}

# ── AC6: no weekday literal in the change ────────────────────────────────────

@test "no weekday (#2139 AC6): the retry script and workflow contain no weekday name" {
  # Names are generated, so this test file holds no weekday literal either.
  local i day full short
  for i in 0 1 2 3 4 5 6; do
    full="$(LC_ALL=C date -u -d "@$((i * 86400))" +%A)"
    short="$(LC_ALL=C date -u -d "@$((i * 86400))" +%a)"
    for day in "$full" "$short"; do
      for f in "$RETRY_SCRIPT" "$RETRY_WORKFLOW" "$BATS_TEST_FILENAME"; do
        if grep -qiw -- "$day" "$f"; then
          echo "weekday '$day' found in $f" >&2
          return 1
        fi
      done
    done
  done
}

# ── AC7: production wiring — the poller's own writer feeds the reader ────────

@test "wiring (#2139 AC7): a record built by the poller's bp_build_record drives the hold end to end" {
  local rec
  # The exact argument order scripts/budget_poller.sh passes: 200 OK, session 37%,
  # weekly_all 100% resetting in three days, glide deferred, config disarmed.
  rec="$(bash -c 'source "$1"; bp_build_record "$2" 200 "" 37 100 \
      2026-10-09T15:00:00.000000+00:00 2026-10-12T16:00:00.000000+00:00 allow defer false "" ""' \
      _ "$POLLER_LIB" "$((NOW_EPOCH - 2700))")"
  [ "$(jq -r .poll <<< "$rec")" = "ok" ]
  # Written exactly as the poller writes it (bp_append_record), byte for byte.
  bash -c 'source "$1"; bp_append_record "$2" "$3"' _ "$POLLER_LIB" "$BATS_TEST_TMPDIR/real.jsonl" "$rec"
  [ "$(cat "$BATS_TEST_TMPDIR/real.jsonl")" = "$rec" ]
  _artifact 202 "$BATS_TEST_TMPDIR/real.jsonl"

  _init
  [ "$BUDGET_HOLD_UNTIL" = "2026-10-12T16:00:00Z" ]
  grep -qx 'retry-cron: weekly window exhausted, holding retries until 2026-10-12T16:00:00Z (poll 0h 45m old)' "$HOLD_LOG"
  [ "$(_downloads)" -eq 1 ]

  _rate_limited_issue
  run scan_issue_for_retry petry-projects/demo 478
  [ "${lines[-1]}" = "0" ]
  [[ "$output" == *"held by the budget poller until 2026-10-12T16:00:00Z"* ]]
}

@test "wiring (#2139 AC7): the reader uses exactly the field names the writer emits" {
  local rec
  rec="$(bash -c 'source "$1"; bp_build_record 1791547200 200 "" 1 2 a b allow allow false "" ""' _ "$POLLER_LIB")"
  # epoch and poll are read through bp_last_ok / bp_staleness themselves.
  for key in epoch poll session_pct weekly_all_pct session_resets_at weekly_all_resets_at; do
    jq -e --arg k "$key" 'has($k)' <<< "$rec" >/dev/null
  done
  for key in session_pct weekly_all_pct session_resets_at weekly_all_resets_at; do
    grep -q "\\.${key}\\b" "$RETRY_SCRIPT"
  done
}
