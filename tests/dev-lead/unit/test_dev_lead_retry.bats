#!/usr/bin/env bats
# Unit tests for dev-lead-retry.sh — issue-retry scan/decision logic (#781)
#
# The script guards `main "$@"` behind a BASH_SOURCE check, so sourcing it here
# exposes scan_issue_for_retry / dispatch_issue_retry / open_issue_pr_exists
# without running the org-wide scan.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
RETRY_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-retry.sh"

# run --separate-stderr (gh_api_list warnings go to stderr)
bats_require_minimum_version 1.5.0

setup() {
  MOCK_BIN="$(mktemp -d)"
  export PATH="$MOCK_BIN:$PATH"

  # Defaults; individual tests override COMMENTS_JSON / OPEN_PR_COUNT / NOW_ISO.
  export COMMENTS_JSON='[]'
  export OPEN_PR_COUNT="0"
  export DRY_RUN="true"
  export NOW_ISO="2026-06-19T00:00:00Z"

  # gh stub: emulates the *post-jq* output the script expects (the real gh
  # applies --jq server/client-side; the stub returns the finished value).
  #   …/issues/<n>/comments  -> $COMMENTS_JSON   (array of comment bodies)
  #   …/pulls?state=open      -> $OPEN_PR_COUNT matching PRs (as an array)
  #   …/dispatches            -> capture payload to $PAYLOAD_FILE (POST path)
  export PAYLOAD_FILE="$MOCK_BIN/payload.json"
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *dispatches*) cat > "${PAYLOAD_FILE:-/dev/null}"; exit 0 ;;
  *comments*)   printf '%s' "${COMMENTS_JSON}" ;;
  *pulls*)      jq -nc --argjson n "${OPEN_PR_COUNT}" '[range($n) | {}]' ;;
  *)            echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"

  source "$RETRY_SCRIPT"
}

teardown() {
  rm -rf "$MOCK_BIN"
}

_marker() {
  # _marker <status> <attempt> [reset]
  local status="$1" attempt="$2" reset="${3:-}"
  local r=""
  [ -n "$reset" ] && r=" reset=${reset}"
  printf '<!-- dev-lead-issue 478 status=%s attempt=%s reason=engine-error run=99%s -->' \
    "$status" "$attempt" "$r"
}

# ── scan_issue_for_retry decision matrix ──────────────────────────────────────

@test "retry: failed marker, attempt 1, no PR → dispatches" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker failed 1)" '[$m]')"

  run scan_issue_for_retry "combsmith/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
  [[ "$output" == *"attempt=1"* ]]
}

@test "retry: rate-limited marker with reset in the future → skips" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker rate-limited 1 2026-06-19T06:00:00Z)" '[$m]')"

  run scan_issue_for_retry "combsmith/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"not yet cleared"* ]]
  [[ "$output" != *"would dispatch"* ]]
}

@test "retry: rate-limited marker with reset in the past → dispatches" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker rate-limited 1 2026-06-18T00:00:00Z)" '[$m]')"

  run scan_issue_for_retry "combsmith/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
}

@test "retry: attempt at the ceiling (attempt=3, MAX=3) → skips" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker failed 3)" '[$m]')"

  run scan_issue_for_retry "combsmith/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"attempts exhausted"* ]]
  [[ "$output" != *"would dispatch"* ]]
}

@test "retry: newest marker wins (failed attempt=2 supersedes attempt=1)" {
  COMMENTS_JSON="$(jq -nc \
    --arg a "$(_marker failed 1)" \
    --arg b "$(_marker failed 2)" '[$a, $b]')"

  run scan_issue_for_retry "combsmith/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
  [[ "$output" == *"attempt=2"* ]]
}

@test "retry: non-retryable marker (status=needs-human) → skips" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker needs-human 2)" '[$m]')"

  run scan_issue_for_retry "combsmith/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"not retryable"* ]]
  [[ "$output" != *"would dispatch"* ]]
}

@test "retry: an open dev-lead PR already exists → skips" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker failed 1)" '[$m]')"
  OPEN_PR_COUNT="1"

  run scan_issue_for_retry "combsmith/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"open dev-lead PR already exists"* ]]
  [[ "$output" != *"would dispatch"* ]]
}

@test "retry: no failure marker → no dispatch (returns 0)" {
  COMMENTS_JSON='["just a normal human comment"]'

  run scan_issue_for_retry "combsmith/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
}

# ── dispatch_issue_retry payload ──────────────────────────────────────────────

@test "dispatch: issue-retry payload carries event_type + issue_number + attempt" {
  export DRY_RUN="false"

  run dispatch_issue_retry "combsmith/.github" 478 2

  [ "$status" -eq 0 ]
  [ -f "$PAYLOAD_FILE" ]
  [ "$(jq -r '.event_type' "$PAYLOAD_FILE")" = "dev-lead-issue-retry" ]
  [ "$(jq -r '.client_payload.issue_number' "$PAYLOAD_FILE")" = "478" ]
  [ "$(jq -r '.client_payload.attempt' "$PAYLOAD_FILE")" = "2" ]
}

@test "dispatch: DRY_RUN=true does not POST a dispatch" {
  export DRY_RUN="true"
  rm -f "$PAYLOAD_FILE"

  run dispatch_issue_retry "combsmith/.github" 478 1

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] would dispatch"* ]]
  [ ! -f "$PAYLOAD_FILE" ]
}

# ── a repo whose list endpoint answers with an error body ─────────────────────
# On an HTTP error gh prints the API's error JSON to stdout (no --jq applied) and
# exits 1. GHSA temporary private forks answer 404 on /issues, and the old
# `gh api ... || echo "[]"` + `jq -s 'add'` turned that into object + array, a
# jq crash that set -e made fatal to the whole org sweep.

# _real_jq_gh_stub: a gh stub that, like the real gh, applies --jq to a raw
# response, and answers with an error body for the endpoints in $GH_FAIL_PATHS
# (space-separated globs). `gh repo list` returns $REPOS_RAW through --jq.
_real_jq_gh_stub() {
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
filter="." path="" prev=""
for a in "$@"; do
  [ "$prev" = "--jq" ] && filter="$a"
  case "$a" in repos/*) [ -n "$path" ] || path="$a" ;; esac
  prev="$a"
done
if [ "$1 $2" = "repo list" ]; then
  printf '%s' "${REPOS_RAW:-[]}" | jq -c "$filter"; exit
fi
for f in ${GH_FAIL_PATHS:-}; do
  # shellcheck disable=SC2053  # $f is a glob on purpose
  if [[ "$path" == $f ]]; then
    printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
  fi
done
case "$path" in
  repos/*/issues\?*)      raw="${ISSUES_RAW:-[]}" ;;
  repos/*/pulls/[0-9]*)   raw="${PR_RAW:-{\}}" ;;
  *)                      raw="[]" ;;
esac
printf '%s' "$raw" | jq -c "$filter"
GHEOF
  chmod +x "$MOCK_BIN/gh"
}

@test "gh_api_list: an error body becomes [] with a warning naming repo and endpoint" {
  _real_jq_gh_stub
  export GH_FAIL_PATHS='repos/combsmith/x-ghsa-pc5f-cw67-7cmm/issues*'

  run --separate-stderr gh_api_list "combsmith/x-ghsa-pc5f-cw67-7cmm" "issues?state=open&per_page=100" '[.[] | {number}]'

  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
  [[ "$stderr" == *"::warning::"*"repos/combsmith/x-ghsa-pc5f-cw67-7cmm/issues failed"*"(Not Found)"* ]]
}

@test "gh_api_list: a failure partway through pagination drops the pages already read" {
  # Page 1 arrives, then gh prints the error body of page 2 and exits 1.
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo '[{"number":1}]'
printf '{"message":"You have exceeded a secondary rate limit","status":"403"}'
exit 1
GHEOF
  chmod +x "$MOCK_BIN/gh"

  run --separate-stderr gh_api_list "combsmith/a" "issues?per_page=100" '.'

  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
  [[ "$stderr" == *"repos/combsmith/a/issues failed"*"(You have exceeded a secondary rate limit)"* ]]
}

@test "retry: markers on two pages — the newest still wins" {
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *comments*) printf '%s\n%s\n' "$PAGE1" "$PAGE2" ;;
  *pulls*)    echo '[]' ;;
  *)          echo '[]' ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"
  PAGE1="$(jq -nc --arg m "$(_marker failed 1)" '[$m, "chatter"]')"
  PAGE2="$(jq -nc --arg m "$(_marker failed 2)" '["more chatter", $m]')"
  export PAGE1 PAGE2

  run scan_issue_for_retry "combsmith/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
  [[ "$output" == *"attempt=2"* ]]
}

@test "lookup_check_run_details: a failed call prints exactly the fallback object" {
  _real_jq_gh_stub
  export GH_FAIL_PATHS='repos/combsmith/app/commits/*'

  run --separate-stderr lookup_check_run_details "combsmith/app" abc123 "CI"

  [ "$status" -eq 0 ]
  [ "$output" = '{"id":"","details_url":""}' ]
  [[ "$stderr" == *"::warning::"*"'CI'"*"combsmith/app@abc123"* ]]
}

# _strict_gh_stub: parses its arguments the way the real gh does — value flags
# take the next word, and `gh api` accepts exactly one positional (the endpoint),
# else "accepts 1 arg(s), received N" and exit 1. The check-runs endpoint answers
# $CHECK_RUNS_RAW (one JSON page per line; only the first without --paginate,
# all back to back with it, as gh does) through --jq; dispatches are captured to $PAYLOAD_FILE.
_strict_gh_stub() {
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
shift  # "api"
filter="." pages=1 pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jq|-q)                       filter="$2"; shift 2 ;;
    --method|-X|-f|-F|-H|--input)  shift 2 ;;
    --paginate)                    pages=0; shift ;;
    --silent|-i)                   shift ;;
    *)                             pos+=("$1"); shift ;;
  esac
done
if [ "${#pos[@]}" -ne 1 ]; then
  echo "accepts 1 arg(s), received ${#pos[@]}" >&2
  exit 1
fi
case "${pos[0]}" in
  */dispatches)  cat > "${PAYLOAD_FILE:-/dev/null}" ;;
  */check-runs*) printf '%s\n' "${CHECK_RUNS_RAW:-{\}}" \
                   | if [ "$pages" -eq 1 ]; then head -n 1; else cat; fi | jq -c "$filter" ;;
  *)             echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"
}

# Two failed runs of "CI" (the later one wins), a success and another check.
_check_runs_raw() {
  jq -nc --arg name "${1:-CI}" '{check_runs: [
    {id: 11, name: $name, conclusion: "failure", completed_at: "2026-06-18T01:00:00Z",
     details_url: "https://github.com/combsmith/app/actions/runs/1/job/11"},
    {id: 12, name: $name, conclusion: "failure", completed_at: "2026-06-18T02:00:00Z",
     details_url: "https://github.com/combsmith/app/actions/runs/2/job/12"},
    {id: 13, name: $name, conclusion: "success", completed_at: "2026-06-18T03:00:00Z",
     details_url: "https://github.com/combsmith/app/actions/runs/3/job/13"},
    {id: 14, name: "lint", conclusion: "failure", completed_at: "2026-06-18T04:00:00Z",
     details_url: "https://github.com/combsmith/app/actions/runs/4/job/14"}]}'
}

@test "lookup_check_run_details: returns the id and URL of the latest failed run of the check" {
  _strict_gh_stub
  CHECK_RUNS_RAW="$(_check_runs_raw)"
  export CHECK_RUNS_RAW

  run --separate-stderr lookup_check_run_details "combsmith/app" abc123 "CI"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.id' <<<"$output")" = "12" ]
  [ "$(jq -r '.details_url' <<<"$output")" = "https://github.com/combsmith/app/actions/runs/2/job/12" ]
  [ -z "$stderr" ]
}

@test "lookup_check_run_details: a check name with quotes, backslashes and \\(...) matches literally" {
  _strict_gh_stub
  local name='build "x" \\ \(env.OS) (ubuntu)'
  CHECK_RUNS_RAW="$(_check_runs_raw "$name")"
  export CHECK_RUNS_RAW

  run --separate-stderr lookup_check_run_details "combsmith/app" abc123 "$name"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.id' <<<"$output")" = "12" ]
}

@test "lookup_check_run_details: the warning keeps a hostile check name to one bounded line" {
  _strict_gh_stub
  CHECK_RUNS_RAW="$(_check_runs_raw)"
  export CHECK_RUNS_RAW

  run --separate-stderr lookup_check_run_details "combsmith/app" abc123 $'x\n::error::y %0A'"$(printf 'z%.0s' {1..300})"

  [ "$status" -eq 0 ]
  [ "$output" = '{"id":"","details_url":""}' ]
  [ "$(wc -l <<<"$stderr")" -eq 1 ]
  [[ "$stderr" != *"::error::"* ]]
  [[ "$stderr" != *"%0A"* ]]
}

@test "lookup_check_run_details: a failure on a later page is found (all pages are read)" {
  _strict_gh_stub
  CHECK_RUNS_RAW="$(jq -nc '{check_runs: [{id: 1, name: "lint", conclusion: "success"}]}')"$'\n'"$(_check_runs_raw)"
  export CHECK_RUNS_RAW

  run --separate-stderr lookup_check_run_details "combsmith/app" abc123 "CI"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.id' <<<"$output")" = "12" ]
  [ "$(jq -r '.details_url' <<<"$output")" = "https://github.com/combsmith/app/actions/runs/2/job/12" ]
}

@test "lookup_check_run_details: no failed run of the check prints empty fields, not null" {
  _strict_gh_stub
  CHECK_RUNS_RAW="$(_check_runs_raw)"
  export CHECK_RUNS_RAW

  run --separate-stderr lookup_check_run_details "combsmith/app" abc123 "deploy (prod)"

  [ "$status" -eq 0 ]
  [ "$output" = '{"id":"","details_url":""}' ]
  [[ "$stderr" == *"::warning::"*"'deploy (prod)'"*"combsmith/app@abc123"* ]]
  [ "$(grep -c '::warning::' <<<"$stderr")" -eq 1 ]
}

@test "dispatch_ci_retry: the payload carries the check run id and URL" {
  _strict_gh_stub
  CHECK_RUNS_RAW="$(_check_runs_raw)"
  export CHECK_RUNS_RAW DRY_RUN="false"
  rm -f "$PAYLOAD_FILE"

  run dispatch_ci_retry "combsmith/app" 42 abc123 "CI"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.event_type' "$PAYLOAD_FILE")" = "dev-lead-ci-failure" ]
  [ "$(jq -r '.client_payload.checks[0].id' "$PAYLOAD_FILE")" = "12" ]
  [ "$(jq -r '.client_payload.checks[0].details_url' "$PAYLOAD_FILE")" = "https://github.com/combsmith/app/actions/runs/2/job/12" ]
}

@test "gh_api_list: pages are joined into one array; a non-array page becomes []" {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$PAGES"\n' > "$MOCK_BIN/gh"
  chmod +x "$MOCK_BIN/gh"

  PAGES=$'[{"number":1}]\n[{"number":2}]' run gh_api_list "combsmith/a" "pulls" '.'
  [ "$status" -eq 0 ]
  [ "$output" = '[{"number":1},{"number":2}]' ]

  PAGES=$'[{"number":1}]\n{"message":"Server Error"}' run --separate-stderr gh_api_list "combsmith/a" "pulls" '.'
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
  [[ "$stderr" == *"::warning::"*"repos/combsmith/a/pulls"* ]]
}

@test "scan_repo_issues: an error body on the issues endpoint is no issues, not a crash" {
  _real_jq_gh_stub
  export GH_FAIL_PATHS='repos/combsmith/broken/issues*'

  run bash -c 'set -euo pipefail; source "$1"; scan_repo_issues combsmith/broken; echo "after"' _ "$RETRY_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"*"repos/combsmith/broken/issues"* ]]
  [[ "$output" == *"no open dev-lead issues in combsmith/broken"* ]]
  [[ "$output" == *"after"* ]]
}

@test "scan_repo: an error body on the pulls endpoint is no PRs, and the issue scan still runs" {
  _real_jq_gh_stub
  export GH_FAIL_PATHS='repos/combsmith/broken/pulls*'
  export ISSUES_RAW='[{"number":7,"labels":[{"name":"dev-lead"}]}]'

  run bash -c 'set -euo pipefail; source "$1"; scan_repo combsmith/broken; echo "after"' _ "$RETRY_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"*"repos/combsmith/broken/pulls"* ]]
  [[ "$output" == *"no open PRs in combsmith/broken"* ]]
  [[ "$output" == *"found 1 open dev-lead issue(s)"* ]]
  [[ "$output" == *"after"* ]]
}

@test "retry: open PRs that cannot be listed hold the issue retry (fail closed)" {
  _real_jq_gh_stub
  export GH_FAIL_PATHS='repos/combsmith/.github/pulls*'
  export DRY_RUN="false"
  rm -f "$PAYLOAD_FILE"

  run open_issue_pr_exists "combsmith/.github" 478
  [ "$status" -eq 2 ]

  # The caller holds a retryable issue, says why, and POSTs nothing.
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker failed 1)" '[$m]')"
  export COMMENTS_JSON
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *dispatches*) cat > "${PAYLOAD_FILE:-/dev/null}"; exit 0 ;;
  *comments*)   printf '%s' "${COMMENTS_JSON}" ;;
  *pulls*)      printf '{"message":"Not Found","status":"404"}'; exit 1 ;;
  *)            echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"

  run scan_issue_for_retry "combsmith/.github" 478

  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0" ]
  [[ "$output" == *"[hold] issue #478: the open PR list of combsmith/.github is unreadable"* ]]
  [ ! -f "$PAYLOAD_FILE" ]
}

@test "sweep: repos whose issues or pulls endpoint errors are skipped with warnings and the sweep reaches the next repo" {
  _real_jq_gh_stub
  export GH_FAIL_PATHS='repos/combsmith/no-issues/issues* repos/combsmith/no-pulls/pulls*'
  export ISSUES_RAW='[{"number":7,"labels":[{"name":"dev-lead"}]}]'
  export REPOS_RAW='[{"nameWithOwner":"combsmith/no-issues","isFork":false},
                     {"nameWithOwner":"combsmith/no-pulls","isFork":false},
                     {"nameWithOwner":"combsmith/healthy","isFork":false}]'
  export DISPATCH_DELAY_SEC=0 TARGET_ORG=combsmith DELEGATION_ORGS=""
  unset SWEEP_AGENT_REF

  run bash "$RETRY_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"*"repos/combsmith/no-issues/issues"* ]]
  [[ "$output" == *"::warning::"*"repos/combsmith/no-pulls/pulls"* ]]
  [[ "$output" == *"[retry] scanning combsmith/healthy..."* ]]
  [[ "$output" == *"dispatched 0 issue retries from combsmith/healthy"* ]]
  [[ "$output" == *"[retry] done at"* ]]
  [[ "$output" != *"jq: error"* ]]
}

# _repo <name> <isFork> <isPrivate> <hasIssuesEnabled>
_repo() {
  jq -nc --arg n "combsmith/$1" --argjson f "$2" --argjson p "$3" --argjson i "$4" \
    '{nameWithOwner: $n, isFork: $f, isPrivate: $p, hasIssuesEnabled: $i}'
}

@test "list_repos_for_org: GHSA temporary private forks and real forks are left out" {
  _real_jq_gh_stub
  REPOS_RAW=$(jq -sc '.' <<< "$(_repo TalkTerm false false true)
$(_repo TalkTerm-ghsa-pc5f-cw67-7cmm false true false)
$(_repo .github-private false false true)
$(_repo .github-private-ghsa-rw84-v39h-45cp false true false)
$(_repo upstream-copy true false true)")
  export REPOS_RAW

  run list_repos_for_org combsmith

  [ "$status" -eq 0 ]
  [ "$output" = '["combsmith/TalkTerm","combsmith/.github-private"]' ]
}

@test "list_repos_for_org: a GHSA-shaped name alone never leaves a repo out" {
  _real_jq_gh_stub
  # Each kept repo misses one signal: public; issues enabled; no repo of the
  # prefix name in the org; not a GHSA id (the id alphabet has no 'a' or 'b').
  REPOS_RAW=$(jq -sc '.' <<< "$(_repo app false true false)
$(_repo app-ghsa-pc5f-cw67-7cmm false false false)
$(_repo app-ghsa-rw84-v39h-45cp false true true)
$(_repo gone-ghsa-fx78-wx9r-525p false true false)
$(_repo app-ghsa-aaaa-bbbb-aaaa false true false)
$(_repo ghsa-notes false true false)")
  export REPOS_RAW

  run list_repos_for_org combsmith

  [ "$status" -eq 0 ]
  [ "$output" = '["combsmith/app","combsmith/app-ghsa-pc5f-cw67-7cmm","combsmith/app-ghsa-rw84-v39h-45cp","combsmith/gone-ghsa-fx78-wx9r-525p","combsmith/app-ghsa-aaaa-bbbb-aaaa","combsmith/ghsa-notes"]' ]
}

@test "scan_pr_for_rate_limits: unreadable PR comments skip the PR (fail closed)" {
  _real_jq_gh_stub
  export GH_FAIL_PATHS='repos/combsmith/app/issues/12/comments*'
  export PR_RAW='{"number":12,"state":"open","head":{"sha":"abc123def456"},"labels":[]}'
  pr_resume_suppressed() { return 1; }  # past the human/budget gate

  run --separate-stderr scan_pr_for_rate_limits "combsmith/app" 12

  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  [[ "$stderr" == *"could not read PR 12 comments in combsmith/app"* ]]
}

# ── #2008: sweep trigger for bot comments edited after their disposition ──────
# CodeRabbit edits ONE summary comment in place (e.g. appending a Security
# Architecture finding). dev-lead only fires on CREATED comments, and the caller
# stub's `on:` is standards-owned, so the safety-net sweep re-dispatches a
# fix-reviews pass when a RESOLVED bot comment was edited after its latest
# dev-lead disposition. #2166: it is deduplicated on a disposition NEWER than the
# edit, not on a run marker — a pass that ran after the edit but wrote no fresh
# disposition left the gate blocked forever. Passes that started after the edit
# only bound it (STALE_DISPOSITION_MAX_PASSES), so it never loops unattended.

# _sweep_nodes <lastEditedAt> <disposition_createdAt> [run_marker_createdAt] [run_marker_association] [run_marker_read_at]
_sweep_nodes() {
  jq -cn --arg e "$1" --arg d "$2" --arg r "${3:-}" --arg ra "${4:-OWNER}" --arg rr "${5:-}" '
    [ {id:"IC_cr", author:{login:"coderabbitai", __typename:"Bot"}, authorAssociation:"NONE",
       body:"summary", createdAt:"2026-10-01T19:12:40Z", isMinimized:true, minimizedReason:"RESOLVED",
       lastEditedAt:$e},
      {id:"IC_d", author:{login:"don-petry", __typename:"User"}, authorAssociation:"OWNER",
       body:"notice\n<!-- dev-lead:comment-disposition id=IC_cr disposition=informational -->",
       createdAt:$d, isMinimized:false, minimizedReason:null, lastEditedAt:null} ]
    + (if $r == "" then [] else [
      {id:"IC_run", author:{login:"don-petry", __typename:"User"}, authorAssociation:$ra,
       body:("<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=no-changes" + (if $rr == "" then "" else " read_at=\($rr)" end) + " -->"),
       createdAt:$r, isMinimized:false, minimizedReason:null, lastEditedAt:null} ] end)'
}

@test "sweep(#2008): a bot comment edited after its dev-lead disposition needs a fix-reviews dispatch" {
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z)" 2000
  [ "$status" -eq 0 ]
}

@test "sweep(#2008): an edit BEFORE the disposition needs no dispatch" {
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T19:20:00Z 2026-10-01T19:23:54Z)" 2000
  [ "$status" -eq 1 ]
}

@test "sweep(#2166): a fix-reviews marker after the edit is not proof — only a disposition newer than the edit clears" {
  # One pass ran after the edit but wrote no fresh disposition: still stale, so
  # dispatch again (PRs empower-personal-dashboard#65/#66/#67 held forever here).
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z)" 2000
  [ "$status" -eq 0 ]
  # A run marker that PREDATES the edit does not suppress it either.
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T19:24:23Z)" 2000
  [ "$status" -eq 0 ]
  # A disposition newer than the edit is the dedup key: nothing to dispatch.
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T20:36:00Z 2026-10-01T20:36:15Z)" 2000
  [ "$status" -eq 1 ]
}

@test "sweep(#2166): bounded — after STALE_DISPOSITION_MAX_PASSES passes since the edit it holds (rc 3) instead of looping" {
  local nodes
  nodes=$(jq -c '. + [ .[] | select(.id == "IC_run") | .id = "IC_run2" | .createdAt = "2026-10-01T20:50:00Z" ]' \
    <<< "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z)")
  run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 3 ]
  STALE_DISPOSITION_MAX_PASSES=3 run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 0 ]
  # A non-numeric cap falls back to the default (2).
  STALE_DISPOSITION_MAX_PASSES=x run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 3 ]
}

@test "sweep(#2166): the stale-disposition hold comment names the real gate and no dead-end advice" {
  local body
  body=$(sed -n '/stale bot comment disposition needs human action/,/\$hold_marker/p' "$RETRY_SCRIPT")
  [[ "$body" == *'undispositioned-pr-comment'* ]]
  [[ "$body" != *'required_review_thread_resolution'* ]]
  [[ "$body" != *'@mention dev-lead'* ]]
}

@test "sweep(#2008): a run marker for a DIFFERENT PR does not suppress the dispatch" {
  export STALE_DISPOSITION_MAX_PASSES=1  # one counted pass reaches the cap
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z)" 20
  [ "$status" -eq 0 ]
}

@test "sweep(#2008): a run marker from an untrusted author does not suppress the dispatch" {
  export STALE_DISPOSITION_MAX_PASSES=1  # one counted pass reaches the cap
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z NONE)" 2000
  [ "$status" -eq 0 ]
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z CONTRIBUTOR)" 2000
  [ "$status" -eq 0 ]
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z MEMBER)" 2000
  [ "$status" -eq 3 ]
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z COLLABORATOR)" 2000
  [ "$status" -eq 3 ]
}

@test "sweep(#2008): a pass that STARTED before the edit does not suppress the dispatch, even if it finished after" {
  export STALE_DISPOSITION_MAX_PASSES=1  # one counted pass reaches the cap
  # Marker posted after the edit (20:36:15) by a pass that read the comments at 20:30.
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z OWNER 2026-10-01T20:30:00Z)" 2000
  [ "$status" -eq 0 ]
  # A pass that started after the edit counts toward the cap.
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z OWNER 2026-10-01T20:35:30Z)" 2000
  [ "$status" -eq 3 ]
}

# ── #2247: a pass that dies before any terminal marker still counts ────────────
# A fix-reviews pass that sees a stale disposition posts a start marker before the
# model runs. A pass whose runner is lost after that posts nothing else, so the cap
# has to count start markers too. A pass that posts both counts once (same read_at).

# _start_node <id> <createdAt> <read_at> [pr] [association]: a start-marker node.
_start_node() {
  jq -cn --arg id "$1" --arg c "$2" --arg r "$3" --arg pr "${4:-2000}" --arg a "${5:-OWNER}" '
    {id:$id, author:{login:"don-petry", __typename:"User"}, authorAssociation:$a,
     body:"<!-- dev-lead-fix-reviews-start pr=\($pr) sha=abc intent=fix-reviews edit=2026-10-01T20:35:00Z read_at=\($r) -->",
     createdAt:$c, isMinimized:false, minimizedReason:null, lastEditedAt:null}'
}

# _with_nodes <nodes-json> <node-json>...: append nodes to a node array.
_with_nodes() {
  local nodes="$1" n
  shift
  for n in "$@"; do nodes=$(jq -c --argjson n "$n" '. + [$n]' <<< "$nodes"); done
  printf '%s' "$nodes"
}

@test "sweep(#2247): two passes that only posted a start marker reach the cap (rc 3)" {
  local base nodes
  base=$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z)
  nodes=$(_with_nodes "$base" "$(_start_node IC_s1 2026-10-01T20:40:01Z 2026-10-01T20:40:00Z)")
  run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 0 ]
  nodes=$(_with_nodes "$nodes" "$(_start_node IC_s2 2026-10-01T20:55:01Z 2026-10-01T20:55:00Z)")
  run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 3 ]
}

@test "sweep(#2247): a pass that posts a start and a terminal marker counts once" {
  local nodes
  # The terminal marker (IC_run) carries the same read_at as the start marker.
  nodes=$(_with_nodes "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:45:00Z OWNER 2026-10-01T20:40:00Z)" \
    "$(_start_node IC_s1 2026-10-01T20:40:01Z 2026-10-01T20:40:00Z)")
  run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 0 ]
  STALE_DISPOSITION_MAX_PASSES=1 run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 3 ]
}

@test "sweep(#2247): millisecond-precision read_at is parsed, deduped across start+terminal, and compared to the edit" {
  local nodes
  # Start (createdAt ...01Z) and terminal (...45Z) markers share read_at=...:00.123Z: one pass.
  nodes=$(_with_nodes "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:45:00Z OWNER 2026-10-01T20:40:00.123Z)" \
    "$(_start_node IC_s1 2026-10-01T20:40:01Z 2026-10-01T20:40:00.123Z)")
  run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 0 ]
  STALE_DISPOSITION_MAX_PASSES=1 run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 3 ]
  # A pass that read at 20:30:00.500Z (before the edit) posted after it: not counted.
  nodes=$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z OWNER 2026-10-01T20:30:00.500Z)
  STALE_DISPOSITION_MAX_PASSES=1 run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 0 ]
  # read_at 20:35:00.000Z equals the edit second: counted (fraction must not sort it below).
  nodes=$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z OWNER 2026-10-01T20:35:00.000Z)
  STALE_DISPOSITION_MAX_PASSES=1 run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 3 ]
}

@test "sweep(#2247): a start marker before the edit, for another PR, or from an untrusted author does not count" {
  export STALE_DISPOSITION_MAX_PASSES=1  # one counted pass reaches the cap
  local base
  base=$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z)
  run stale_disposition_needs_dispatch "$(_with_nodes "$base" "$(_start_node IC_s 2026-10-01T20:36:00Z 2026-10-01T20:30:00Z)")" 2000
  [ "$status" -eq 0 ]
  run stale_disposition_needs_dispatch "$(_with_nodes "$base" "$(_start_node IC_s 2026-10-01T20:41:00Z 2026-10-01T20:40:00Z 20)")" 2000
  [ "$status" -eq 0 ]
  run stale_disposition_needs_dispatch "$(_with_nodes "$base" "$(_start_node IC_s 2026-10-01T20:41:00Z 2026-10-01T20:40:00Z 2000 NONE)")" 2000
  [ "$status" -eq 0 ]
  run stale_disposition_needs_dispatch "$(_with_nodes "$base" "$(_start_node IC_s 2026-10-01T20:41:00Z 2026-10-01T20:40:00Z)")" 2000
  [ "$status" -eq 3 ]
}

@test "sweep(#2247): two passes start and post no terminal marker — the third sweep holds and posts the capped hold" {
  export DRY_RUN="false" POSTS_FILE="$BATS_TEST_TMPDIR/posts"
  : > "$POSTS_FILE"
  gh() {
    case "$*" in
      *"--method POST"*) printf '%s\n' "$*" >> "$POSTS_FILE" ;;
      *"/pulls/2000"*) echo '{"state":"open","head":{"sha":"abc"},"labels":[]}' ;;
      *"/comments"*) jq -c 'map(.body)' <<< "$SWEEP_NODES" ;;
      *) echo '[]' ;;
    esac
  }
  pr_resume_suppressed() { return 1; }
  post_dispatch_guard() { :; }
  fetch_pr_comment_nodes() { printf '%s' "$SWEEP_NODES"; }
  dispatch_reviews_retry() { echo "DISPATCH intent=$4" >&2; }

  # Sweeps 1 and 2 dispatch; each dispatched pass posts its start marker, then dies.
  export SWEEP_NODES
  SWEEP_NODES=$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z)
  run scan_pr_for_rate_limits "combsmith/.github-private" 2000
  [[ "$output" == *"DISPATCH intent=fix-reviews"* ]]
  SWEEP_NODES=$(_with_nodes "$SWEEP_NODES" "$(_start_node IC_s1 2026-10-01T20:40:01Z 2026-10-01T20:40:00Z)")
  run scan_pr_for_rate_limits "combsmith/.github-private" 2000
  [[ "$output" == *"DISPATCH intent=fix-reviews"* ]]
  [ ! -s "$POSTS_FILE" ]
  SWEEP_NODES=$(_with_nodes "$SWEEP_NODES" "$(_start_node IC_s2 2026-10-01T20:55:01Z 2026-10-01T20:55:00Z)")

  # Sweep 3: no dispatch, and the capped hold comment is posted.
  run scan_pr_for_rate_limits "combsmith/.github-private" 2000
  [ "${lines[-1]}" = "0" ]
  [[ "$output" != *"DISPATCH"* ]]
  [[ "$output" == *"::warning::"*"#2166"* ]]
  grep -q 'dev-lead-stale-disposition-hold pr=2000 sha=abc max_passes=2' "$POSTS_FILE"
}

@test "sweep(#2008): unreadable comment data never dispatches (no guessing)" {
  run stale_disposition_needs_dispatch "not json" 2000
  [ "$status" -eq 1 ]
}

@test "sweep(#2008): scan_pr_for_rate_limits consults the stale-disposition check" {
  grep -q 'stale_disposition_needs_dispatch' "$RETRY_SCRIPT"
  grep -q 'lastEditedAt' "$RETRY_SCRIPT"
}

# _scan_with_hold <reset_iso>: run scan_pr_for_rate_limits on a PR whose only
# marker is a fix-reviews hold resetting at <reset_iso>, with a stale-edited bot
# comment waiting (the #2008 re-dispatch would fire if nothing else stopped it).
_scan_with_hold() {
  local reset="$1"
  export HOLD_RESET="$reset"
  gh() {
    case "$*" in
      *"/pulls/2000"*) echo '{"state":"open","head":{"sha":"abc"},"labels":[]}' ;;
      *"/comments"*) jq -cn --arg r "$HOLD_RESET" '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=rate-limited reason=rate-limited reset=\($r) -->"]' ;;
      *) echo '[]' ;;
    esac
  }
  pr_resume_suppressed() { return 1; }
  post_dispatch_guard() { :; }
  fetch_pr_comment_nodes() { echo '[{"id":"IC_cr"}]'; }
  stale_disposition_needs_dispatch() { return 0; }
  dispatch_reviews_retry() { echo "DISPATCH intent=$4" >&2; }
  run scan_pr_for_rate_limits "combsmith/.github-private" 2000
}

@test "sweep(#2008): an active rate-limit hold also holds the edit re-dispatch" {
  _scan_with_hold "2026-06-19T05:00:00Z"
  [ "${lines[-1]}" = "0" ]
  [[ "$output" != *"DISPATCH"* ]]
  [[ "$output" != *"stale-disposition"* ]]
}

@test "sweep(#2008): once the hold has reset, the retry dispatch covers the edit (one run)" {
  _scan_with_hold "2026-06-18T23:00:00Z"
  [ "${lines[-1]}" = "1" ]
  [ "$(grep -c 'DISPATCH' <<< "$output")" -eq 1 ]
}

@test "sweep(#2166): a stale disposition past its pass cap is held with a warning, not dispatched" {
  gh() {
    case "$*" in
      *"/pulls/2000"*) echo '{"state":"open","head":{"sha":"abc"},"labels":[]}' ;;
      *) echo '[]' ;;
    esac
  }
  pr_resume_suppressed() { return 1; }
  post_dispatch_guard() { echo "GUARD" >&2; }
  fetch_pr_comment_nodes() { echo '[{"id":"IC_cr"}]'; }
  stale_disposition_needs_dispatch() { return 3; }
  dispatch_reviews_retry() { echo "DISPATCH intent=$4" >&2; }
  run scan_pr_for_rate_limits "combsmith/.github-private" 2000
  [ "${lines[-1]}" = "0" ]
  [[ "$output" != *"DISPATCH"* ]]
  [[ "$output" != *"GUARD"* ]]
  [[ "$output" == *"::warning::"*"#2166"* ]]
}

# _scan_with_markers <json-array-of-bodies>: scan a PR whose comments are exactly those.
_scan_with_markers() {
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
  fetch_pr_comment_nodes() { echo '[]'; }
  stale_disposition_needs_dispatch() { return 1; }
  dispatch_reviews_retry() { echo "DISPATCH intent=$4" >&2; }
  run scan_pr_for_rate_limits "combsmith/.github-private" 2000
}

@test "retry(#2089): a dev-lead:hands-off PR with a reset hold neither guards nor dispatches" {
  gh() {
    case "$*" in
      *"/pulls/2000"*) echo '{"state":"open","head":{"sha":"abc"},"labels":[{"name":"dev-lead:hands-off"}]}' ;;
      *"/comments"*) echo '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=rate-limited reason=rate-limited reset=2026-06-18T23:00:00Z -->"]' ;;
      *) echo '[]' ;;
    esac
  }
  # The REAL resume gate (from lib/pr-automation-budget.sh) — not the stub the
  # other scans use — so the hold-label suppression itself is under test.
  # shellcheck source=/dev/null
  source "$(dirname "$RETRY_SCRIPT")/lib/pr-automation-budget.sh"
  post_dispatch_guard() { echo "GUARD" >&2; }
  fetch_pr_comment_nodes() { echo '[{"id":"IC_cr"}]'; }
  stale_disposition_needs_dispatch() { return 0; }
  dispatch_reviews_retry() { echo "DISPATCH intent=$4" >&2; }
  run scan_pr_for_rate_limits "combsmith/.github-private" 2000
  [ "${lines[-1]}" = "0" ]
  [[ "$output" != *"DISPATCH"* ]]
  [[ "$output" != *"GUARD"* ]]
  [[ "$output" == *"carries dev-lead:hands-off"* ]]
}

@test "retry: history-unavailable marker AFTER an older terminal failed marker still dispatches" {
  _scan_with_markers '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=failed -->","<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=history-unavailable -->"]'
  [[ "$output" == *"DISPATCH intent=fix-reviews"* ]]
}

@test "retry: history-unavailable marker BEFORE a later terminal marker does not dispatch" {
  _scan_with_markers '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=history-unavailable -->","<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=applied -->"]'
  [[ "$output" != *"DISPATCH"* ]]
}

@test "retry: repeated history-unavailable markers hit the retry limit and stop dispatching" {
  local m='<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=history-unavailable -->'
  _scan_with_markers "[\"$m\",\"$m\",\"$m\"]"
  [[ "$output" != *"DISPATCH"* ]]
}

@test "retry: history-unavailable below the retry limit still dispatches" {
  local m='<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=history-unavailable -->'
  _scan_with_markers "[\"$m\",\"$m\"]"
  [[ "$output" == *"DISPATCH intent=fix-reviews"* ]]
}

@test "retry: partial marker AFTER an older terminal no-changes marker still dispatches" {
  _scan_with_markers '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=no-changes -->","<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=partial -->"]'
  [[ "$output" == *"DISPATCH intent=fix-reviews"* ]]
}

@test "retry: repeated partial markers hit the retry limit and stop dispatching" {
  local m='<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=partial -->'
  _scan_with_markers "[\"$m\",\"$m\",\"$m\"]"
  [[ "$output" != *"DISPATCH"* ]]
}

@test "retry: partial retry limit holds the PR, escalates, and blocks the stale-disposition dispatch" {
  local m='<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=partial -->'
  export MARKERS_JSON="[\"$m\",\"$m\",\"$m\"]"
  gh() {
    case "$*" in
      *"/pulls/2000"*) echo '{"state":"open","head":{"sha":"abc"},"labels":[]}' ;;
      *"/comments"*) echo "$MARKERS_JSON" ;;
      *) echo '[]' ;;
    esac
  }
  pr_resume_suppressed() { return 1; }
  post_dispatch_guard() { :; }
  pr_automation_escalate() { echo "ESCALATE $1" >&2; }
  # The stale-disposition path would dispatch if the hold did not apply.
  fetch_pr_comment_nodes() { echo '[{"id":"x"}]'; }
  stale_disposition_needs_dispatch() { return 0; }
  dispatch_reviews_retry() { echo "DISPATCH intent=$4" >&2; }
  run scan_pr_for_rate_limits "combsmith/.github-private" 2000
  [[ "$output" != *"DISPATCH"* ]]
  [[ "$output" == *"ESCALATE 2000"* ]]
}

@test "retry: partial markers before a later applied marker do not hold or escalate" {
  local p='<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=partial -->'
  local a='<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=applied -->'
  pr_automation_escalate() { echo "ESCALATE $1" >&2; }
  _scan_with_markers "[\"$p\",\"$p\",\"$p\",\"$a\"]"
  [[ "$output" != *"DISPATCH"* ]]
  [[ "$output" != *"ESCALATE"* ]]
}

@test "retry: partial markers before a later no-changes marker do not hold or escalate" {
  local p='<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=partial -->'
  local nc='<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=no-changes -->'
  pr_automation_escalate() { echo "ESCALATE $1" >&2; }
  _scan_with_markers "[\"$p\",\"$p\",\"$p\",\"$nc\"]"
  [[ "$output" != *"DISPATCH"* ]]
  [[ "$output" != *"ESCALATE"* ]]
}

@test "retry: unrelated-histories after history-unavailable is terminal" {
  _scan_with_markers '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=history-unavailable -->","<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=unrelated-histories -->"]'
  [[ "$output" != *"DISPATCH"* ]]
}

# ── #2262: the run a bot-comment retry dispatched ────────────────────────────
# The decision matrix and the sweep wiring are covered in
# test_bot_comment_retry.bats; these pin the two properties the recording rests on.

@test "retry(#2262): the retry marker records its run by an EDIT, and the caller stub starts no run on a comment edit" {
  local body types
  body="$(declare -f record_bot_comment_retry_run)"
  [ -n "$body" ]
  # The run is recorded on the marker the scan already posted…
  [[ "$body" == *'--method PATCH "repos/${repo}/issues/comments/${marker_id}"'* ]]
  # …never by posting another comment: an issue_comment `created` event starts a
  # dev-lead run in the PR's lane, and that run would cancel the retry just sent.
  if grep -q -- '--method POST' <<< "$body"; then echo "$body"; return 1; fi
  # The caller stub (copied verbatim into every repo) subscribes to `created`
  # only. If it ever subscribes to `edited`, the edit above cancels the retry it
  # describes, and the run has to be recorded some other way.
  types="$(awk '/^  issue_comment:/ {found=1; next}
                found && /^    types:/ {print; exit}
                found && /^  [a-z_]+:/ {exit}' "$BATS_TEST_DIRNAME/../../../.github/workflows/dev-lead.yml")"
  [ "$(tr -d '[:space:]' <<< "$types")" = "types:[created]" ]
}

@test "retry(#2262): an Actions run that cannot be read is left out of the run states, never guessed" {
  local out="$MOCK_BIN/out" err="$MOCK_BIN/err"
  # Every read fails: an empty map (all retries keep the time-based window), rc 0.
  gh() { return 1; }
  fetch_bot_comment_retry_run_states "combsmith/.github" '["501","502"]' > "$out" 2> "$err"
  [ "$(cat "$out")" = "{}" ]
  [ "$(grep -c '::warning::.*could not read Actions run 50[12] ' "$err")" -eq 2 ]
  # One readable live run and one unreadable: only the readable one is reported.
  gh() {
    case "$*" in
      *"/actions/runs/501") echo '{"id":501,"event":"repository_dispatch","status":"in_progress","conclusion":null}' ;;
      *) return 1 ;;
    esac
  }
  fetch_bot_comment_retry_run_states "combsmith/.github" '["501","502"]' > "$out" 2> "$err"
  [ "$(cat "$out")" = '{"501":{"status":"in_progress","conclusion":null,"started":null}}' ]
  grep -q '::warning::.*could not read Actions run 502 ' "$err"
  # Ids that are not run ids are never sent to the API.
  gh() { echo "CALLED $*" >&2; return 1; }
  run fetch_bot_comment_retry_run_states "combsmith/.github" '["../x","5 01",7,null]'
  [ "$status" -eq 0 ]
  [[ "$output" != *"CALLED"* ]]
  [ "${lines[-1]}" = "{}" ]
}
