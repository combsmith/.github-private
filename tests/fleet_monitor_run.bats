#!/usr/bin/env bats
# End-to-end tests for scripts/fleet_monitor.sh: the real script, run against a
# `gh` shim that serves a small fixture org, so no live API call is made. Run:
#   bats tests/fleet_monitor_run.bats
#
# tests/fleet_stub_registry.bats also drives the real script, but its repos have
# no workflows, so the per-workflow metrics loop (section 2) never executes
# there. These tests give the org one repo with one ordinary (non-ingress)
# workflow that has completed runs, which is the path every scheduled run takes.

MONITOR="${BATS_TEST_DIRNAME}/../scripts/fleet_monitor.sh"
REPO="petry-projects/demo"

setup() {
  WORK="$(mktemp -d "${BATS_TEST_TMPDIR}/work.XXXXXX")"
  # FAKE_API/<name>.json is the JSON body the shim answers with; the script's own
  # --jq filter is then applied to it, exactly as gh would.
  # FAKE_ROOT/<owner>/<repo>/<path> is a file served for a contents read; an
  # absent file answers HTTP 404, like the contents API.
  # FAKE_API/jobs.json maps a run's node id to its jobs for the GraphQL jobs
  # read; every request body is appended to GRAPHQL_LOG, one JSON per line.
  FAKE_API="${WORK}/api"; export FAKE_API
  FAKE_ROOT="${WORK}/root"; export FAKE_ROOT
  CALLS="${WORK}/calls.log"; export CALLS
  GRAPHQL_LOG="${WORK}/graphql.log"; export GRAPHQL_LOG
  : > "$GRAPHQL_LOG"
  unset FAKE_GRAPHQL_FAIL FLEET_PAUSE_BATCH
  ORG="petry-projects"; export ORG
  STUB_BIN="${WORK}/bin"
  mkdir -p "$FAKE_API" "$FAKE_ROOT" "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH"
  unset GITHUB_ENV GITHUB_STEP_SUMMARY

  cat > "$STUB_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
[ "$1" = "api" ] || exit 0
shift
raw=0; jq_expr=""; path=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) [ "$2" = "Accept: application/vnd.github.raw" ] && raw=1; shift 2 ;;
    --jq) jq_expr="$2"; shift 2 ;;
    --method|-X|--field|-f|-F|--input) shift 2 ;;
    -*) shift ;;
    *) [ -z "$path" ] && path="$1"; shift ;;
  esac
done
# answer <name> <default-json> — FAKE_API/<name>.json (or the default) through
# the caller's --jq filter.
answer() {
  local body="$2"
  [ -f "${FAKE_API}/$1.json" ] && body="$(cat "${FAKE_API}/$1.json")"
  if [ -n "$jq_expr" ]; then printf '%s' "$body" | jq -r "$jq_expr"; else printf '%s\n' "$body"; fi
}
case "$path" in
  graphql)
    # The batched jobs read (#2266): {query, variables: {ids}} on stdin. Answer
    # each id with its jobs from jobs.json; an id with no entry ran one ordinary
    # job. FAKE_GRAPHQL_FAIL=1 fails the request with no body.
    body="$(cat)"
    printf '%s\n' "$(jq -c . <<< "$body")" >> "$GRAPHQL_LOG"
    [ -z "${FAKE_GRAPHQL_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
    jobs='{}'; [ -f "${FAKE_API}/jobs.json" ] && jobs="$(cat "${FAKE_API}/jobs.json")"
    jq -c --argjson jobs "$jobs" '{data: {nodes: [.variables.ids[] as $id
      | {id: $id, checkSuite: {checkRuns: {nodes:
          ($jobs[$id] // [{name: "work", conclusion: "SUCCESS"}])}}}]}}' <<< "$body" ;;
  "orgs/${ORG}") echo '{}' ;;
  "orgs/${ORG}/repos"*) answer repos '[]' ;;
  search/issues*) answer search '{"items":[]}' ;;
  repos/*/contents/*)
    rest="${path#repos/}"; repo="${rest%%/contents/*}"
    file="${rest#*/contents/}"; file="${file%%\?*}"
    f="${FAKE_ROOT}/${repo}/${file}"
    if [ ! -f "$f" ]; then
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    if [ "$raw" -eq 1 ]; then cat "$f"; else git hash-object "$f"; fi ;;
  repos/*/actions/workflows/*/runs*)
    wf="${path#*/actions/workflows/}"; wf="${wf%%/runs*}"
    answer "runs-${wf}" '{"workflow_runs":[]}' ;;
  repos/*/actions/workflows\?*) answer workflows '{"workflows":[]}' ;;
  repos/*/actions/artifacts*) answer artifacts '{"artifacts":[]}' ;;
  repos/*/issues/comments*) answer comments '[]' ;;
  repos/*/labels*) answer labels '[]' ;;
  repos/*/*) ;;
  repos/*) answer repo '{"default_branch":"main"}' ;;
esac
exit 0
SHIM
  chmod +x "$STUB_BIN/gh"

  printf '[{"full_name":"%s","archived":false}]\n' "$REPO" > "${FAKE_API}/repos.json"
}

teardown() {
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  return 0
}

# put_workflow <id> <file> — register an active workflow and serve stdin as its
# file content. Call once per workflow; rows accumulate in workflows.json.
put_workflow() {
  local id="$1" file="$2" list="${FAKE_API}/workflows.json"
  [ -f "$list" ] || echo '{"workflows":[]}' > "$list"
  jq --argjson id "$id" --arg path "$file" \
    '.workflows += [{id: $id, path: $path, state: "active"}]' "$list" > "${list}.tmp"
  mv "${list}.tmp" "$list"
  mkdir -p "$(dirname "${FAKE_ROOT}/${REPO}/${file}")"
  cat > "${FAKE_ROOT}/${REPO}/${file}"
}

# put_runs <workflow-id> <conclusion>... — one completed run per conclusion, in
# the shape the runs API returns. Run N has node id RUN_<workflow-id>_<N>.
put_runs() {
  local id="$1"; shift
  local n=0 c rows="[]"
  for c in "$@"; do
    n=$(( n + 1 ))
    rows="$(jq -c --arg c "$c" --argjson n "$n" --arg node "RUN_${id}_${n}" \
      '. += [{id: (1000 + $n), node_id: $node, run_number: $n, conclusion: $c,
              event: "push", created_at: "2026-10-10T10:00:00Z",
              updated_at: "2026-10-10T10:01:00Z",
              html_url: ("https://github.test/runs/" + ($n | tostring))}]' <<< "$rows")"
  done
  jq -n --argjson rows "$rows" '{workflow_runs: $rows}' > "${FAKE_API}/runs-${id}.json"
}

run_monitor() {
  cd "$WORK"
  run bash "$MONITOR"
}

# put_jobs <node-id> <name>=<CONCLUSION>... — the jobs of one run, as the GraphQL
# check-run list reports them (upper-case conclusions).
put_jobs() {
  local node="$1" map="${FAKE_API}/jobs.json" kv list="[]"; shift
  [ -f "$map" ] || echo '{}' > "$map"
  for kv in "$@"; do
    list="$(jq -c --arg n "${kv%%=*}" --arg c "${kv##*=}" '. += [{name: $n, conclusion: $c}]' <<< "$list")"
  done
  jq --arg node "$node" --argjson list "$list" '.[$node] = $list' "$map" > "${map}.tmp"
  mv "${map}.tmp" "$map"
}

# A workflow gated on AGENTS_PAUSED with a notice job, as #2249 wrote them.
NOTICE_WORKFLOW='name: Stale Manager
on:
  schedule:
    - cron: "29 9 * * 1"
jobs:
  stale:
    if: vars.AGENTS_PAUSED != '"'true'"'
    runs-on: ubuntu-latest
    steps:
      - run: echo work
  fleet-paused:
    if: vars.AGENTS_PAUSED == '"'true'"'
    runs-on: ubuntu-latest
    steps:
      - run: echo paused
'

# paused_job / worked_job <node-id> — the two shapes a green run of
# NOTICE_WORKFLOW takes: paused (only the notice ran) or not (only the work ran).
paused_job() { put_jobs "$1" "stale=SKIPPED" "fleet-paused=SUCCESS"; }
worked_job() { put_jobs "$1" "stale=SUCCESS" "fleet-paused=SKIPPED"; }

# paused_row <workflow-file> — the "Paused runs" cell of that workflow's row in
# the "Fleet-paused runs" section, or empty when it has no row.
paused_row() {
  awk -F'|' -v h="## Fleet-paused runs" -v wf=" \`$1\` " '
    $0 == h { f = 1; next }
    f && /^## / { exit }
    f && $3 == wf { gsub(/ /, "", $4); print $4; exit }
  ' "${WORK}/fleet_monitor_report.md"
}

# detail_row <workflow-file> — that workflow's row of the "Fleet Detail" table,
# cut down to its "Total | ✅ | ❌ | ⚪ | Failure Rate" cells.
detail_row() {
  awk -F'|' -v wf=" \`$1\` " '$3 == wf { print $5 "|" $6 "|" $7 "|" $8 "|" $9; exit }' \
    "${WORK}/fleet_monitor_report.md"
}

# attribution_row <role> — that role's row of the per-role attribution table.
attribution_row() {
  awk -v h="## Run attribution (by role, across collapse)" -v role="| \`$1\` |" '
    $0 == h { f = 1; next }
    f && index($0, role) == 1 { print; exit }
  ' "${WORK}/fleet_monitor_report.md"
}

# ---------------------------------------------------------------------------
# The metrics loop runs to completion on an ordinary workflow
# ---------------------------------------------------------------------------

@test "fleet_monitor: a repo with an ordinary workflow and completed runs is measured, not a crash" {
  # Regression: the loop appends each non-ingress workflow's runs to the legacy
  # attribution file. That file used to be created ~330 lines AFTER the loop, so
  # under `set -u` the first workflow with runs aborted the monitor with
  # "legacy_attr_file: unbound variable" and no report was written.
  printf 'name: CI\non:\n  push:\njobs:\n  test:\n    runs-on: ubuntu-latest\n' \
    | put_workflow 11 ".github/workflows/ci.yml"
  put_runs 11 success success failure

  run_monitor
  [ "$status" -eq 0 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" == *"=== Fleet monitor complete ==="* ]]

  # The loop's own numbers reached the report: 3 runs, 2 green, 1 red.
  [ "$(detail_row ".github/workflows/ci.yml")" = " 3 | 2 | 1 | 0 | 33.3% " ]
}

# ---------------------------------------------------------------------------
# Per-role run attribution (#1727): every collected run is in the table
# ---------------------------------------------------------------------------

@test "fleet_monitor: every run the loop collects reaches the per-role attribution table" {
  # The loop writes one {role,conclusion} record per run and the report section
  # reads them back ~450 lines later. The section used to combine its two JSONL
  # inputs with `jq -s add`, which MERGES objects: three runs became one record,
  # the last one, so this row read `| 1 | 0 | 1 | 0 |`.
  printf 'name: CI\non:\n  push:\njobs:\n  test:\n    runs-on: ubuntu-latest\n' \
    | put_workflow 11 ".github/workflows/ci.yml"
  put_runs 11 success success failure

  run_monitor
  [ "$status" -eq 0 ]
  [ "$(attribution_row ci)" = '| `ci` | 3 | 2 | 1 | 0 |' ]
}

@test "fleet_monitor: two workflows get one attribution row each, not one row for the fleet" {
  printf 'name: CI\non:\n  push:\njobs:\n  test:\n    runs-on: ubuntu-latest\n' \
    | put_workflow 11 ".github/workflows/ci.yml"
  put_runs 11 success success failure
  printf 'name: Lint\non:\n  push:\njobs:\n  lint:\n    runs-on: ubuntu-latest\n' \
    | put_workflow 12 ".github/workflows/lint.yml"
  put_runs 12 success cancelled

  run_monitor
  [ "$status" -eq 0 ]
  [ "$(attribution_row ci)" = '| `ci` | 3 | 2 | 1 | 0 |' ]
  [ "$(attribution_row lint)" = '| `lint` | 2 | 1 | 0 | 1 |' ]
}

# ---------------------------------------------------------------------------
# Fleet-paused runs (#2266): counted as paused, left out of every rate
# ---------------------------------------------------------------------------

# five_runs_two_paused — NOTICE_WORKFLOW with five completed runs: two that only
# reported the pause, one that did its work, one failure and one skipped.
five_runs_two_paused() {
  printf '%s' "$NOTICE_WORKFLOW" | put_workflow 21 ".github/workflows/stale-manager.yml"
  put_runs 21 success success success failure skipped
  paused_job RUN_21_1
  paused_job RUN_21_2
  worked_job RUN_21_3
}

@test "fleet_monitor: a run that only reported the fleet pause is counted as paused, not as a success" {
  five_runs_two_paused

  run_monitor
  [ "$status" -eq 0 ]

  # Two paused runs, in their own section.
  [ "$(paused_row ".github/workflows/stale-manager.yml")" = "2" ]
  # They are not successes and not in the total: 3 runs, 1 green, 1 red. Counted
  # as before this would read ` 5 | 3 | 1 | 0 | 20% `.
  [ "$(detail_row ".github/workflows/stale-manager.yml")" = " 3 | 1 | 1 | 0 | 33.3% " ]
}

@test "fleet_monitor: paused runs are left out of the high-failure export and the attribution table" {
  five_runs_two_paused

  run_monitor
  [ "$status" -eq 0 ]

  # 1 failure in 3 counted runs is 33%, over the 10% tracking line; with the two
  # paused runs in the denominator it would be exported as 1 in 5.
  run jq -c '.[] | select(.workflow == ".github/workflows/stale-manager.yml") | [.total, .success, .failed]' \
    "${WORK}/fleet_high_failure.json"
  [ "$output" = "[3,1,1]" ]
  [ "$(attribution_row stale-manager)" = '| `stale-manager` | 3 | 1 | 1 | 0 |' ]
}

@test "fleet_monitor: with no pause in the window the numbers are what they always were" {
  # The same five runs, none paused: every green run did its work.
  printf '%s' "$NOTICE_WORKFLOW" | put_workflow 21 ".github/workflows/stale-manager.yml"
  put_runs 21 success success success failure skipped
  worked_job RUN_21_1
  worked_job RUN_21_2
  worked_job RUN_21_3

  run_monitor
  [ "$status" -eq 0 ]
  [ "$(detail_row ".github/workflows/stale-manager.yml")" = " 5 | 3 | 1 | 0 | 20% " ]
  run grep -c "Fleet-paused runs" "${WORK}/fleet_monitor_report.md"
  [ "$output" = "0" ]
}

@test "fleet_monitor: a run with every job skipped is not reported as paused" {
  # A paused run of a workflow WITHOUT a notice job ends like this, and so does
  # any run an event filter skipped. Nothing tells them apart, so neither is
  # called paused, and no jobs read is spent on them.
  printf '%s' "$NOTICE_WORKFLOW" | put_workflow 21 ".github/workflows/stale-manager.yml"
  put_runs 21 skipped skipped
  put_jobs RUN_21_1 "stale=SKIPPED" "fleet-paused=SKIPPED"
  put_jobs RUN_21_2 "stale=SKIPPED" "fleet-paused=SKIPPED"

  run_monitor
  [ "$status" -eq 0 ]
  [ "$(detail_row ".github/workflows/stale-manager.yml")" = " 2 | 0 | 0 | 0 | 0% " ]
  [ -z "$(paused_row ".github/workflows/stale-manager.yml")" ]
  [ ! -s "$GRAPHQL_LOG" ]
}

@test "fleet_monitor: a caller of a reusable that carries the notice job is recognised by the nested job name" {
  # persona-runner.yml declares no fleet-paused job itself: it calls
  # persona-runner-reusable.yml, a job-gate row of the registry, and the jobs API
  # names the nested job "<caller-key> / fleet-paused".
  printf 'name: Persona Runtime\non:\n  repository_dispatch:\njobs:\n  run:\n    uses: ./.github/workflows/persona-runner-reusable.yml\n' \
    | put_workflow 31 ".github/workflows/persona-runner.yml"
  put_runs 31 success success
  put_jobs RUN_31_1 "run / run=SKIPPED" "run / fleet-paused=SUCCESS"
  put_jobs RUN_31_2 "run / run=SUCCESS" "run / fleet-paused=SKIPPED"

  run_monitor
  [ "$status" -eq 0 ]
  [ "$(paused_row ".github/workflows/persona-runner.yml")" = "1" ]
  [ "$(detail_row ".github/workflows/persona-runner.yml")" = " 1 | 1 | 0 | 0 | 0% " ]
}

@test "fleet_monitor: only green runs of a workflow with a notice job are asked about, in one request" {
  five_runs_two_paused
  # An ordinary workflow beside it: no notice job, so no jobs read at all.
  printf 'name: CI\non:\n  push:\njobs:\n  test:\n    runs-on: ubuntu-latest\n' \
    | put_workflow 11 ".github/workflows/ci.yml"
  put_runs 11 success success failure

  run_monitor
  [ "$status" -eq 0 ]

  # One request for the whole fleet, naming the three green stale-manager runs:
  # not its failed or skipped run, and nothing from ci.yml.
  [ "$(wc -l < "$GRAPHQL_LOG" | tr -d ' ')" = "1" ]
  run jq -c '.variables.ids' "$GRAPHQL_LOG"
  [ "$output" = '["RUN_21_1","RUN_21_2","RUN_21_3"]' ]
  # ci.yml is untouched by any of it.
  [ "$(detail_row ".github/workflows/ci.yml")" = " 3 | 2 | 1 | 0 | 33.3% " ]
}

@test "fleet_monitor: the jobs read is batched, one request per FLEET_PAUSE_BATCH runs" {
  five_runs_two_paused
  export FLEET_PAUSE_BATCH=2

  run_monitor
  [ "$status" -eq 0 ]
  run jq -c '.variables.ids' "$GRAPHQL_LOG"
  [ "${lines[0]}" = '["RUN_21_1","RUN_21_2"]' ]
  [ "${lines[1]}" = '["RUN_21_3"]' ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(paused_row ".github/workflows/stale-manager.yml")" = "2" ]
}

@test "fleet_monitor: a failed jobs read warns and leaves the runs counted as before" {
  five_runs_two_paused
  export FAKE_GRAPHQL_FAIL=1

  run_monitor
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Cannot read jobs for 3 run(s)"* ]]
  # Nothing is dropped or guessed: the old numbers, and no paused section.
  [ "$(detail_row ".github/workflows/stale-manager.yml")" = " 5 | 3 | 1 | 0 | 20% " ]
  [ -z "$(paused_row ".github/workflows/stale-manager.yml")" ]
}
