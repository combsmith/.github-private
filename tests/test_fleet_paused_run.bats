#!/usr/bin/env bats
# Tests for how the monitors read a run that did no work because the agent fleet
# was paused (#2266, follow-up to #2249):
#   * scripts/lib/fleet-pause.sh    — the shared pure helpers
#   * scripts/initiative_canary.sh  — a paused planner run is PAUSED, not OK
#   * scripts/pr_review_canary.sh   — a paused review run is PAUSED, not FAILED
# The fleet monitor's side is tested end to end in tests/fleet_monitor_run.bats.
#
# The two canaries define functions of the same name, so each test sources the
# one script it is about (every bats test runs in its own subshell).
#
# Run with: bats tests/test_fleet_paused_run.bats

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="${ROOT}/scripts/lib/fleet-pause.sh"
INITIATIVE="${ROOT}/scripts/initiative_canary.sh"
PR_REVIEW="${ROOT}/scripts/pr_review_canary.sh"
WORKFLOWS="${ROOT}/.github/workflows"

# What the jobs API reports for an initiative-planner dispatch (job keys from
# initiative-planner.yml): paused, and not paused.
PAUSED_JOBS='[{"name":"redispatch","conclusion":"skipped"},{"name":"plan","conclusion":"skipped"},{"name":"fleet-paused","conclusion":"success"}]'
WORKED_JOBS='[{"name":"redispatch","conclusion":"skipped"},{"name":"plan","conclusion":"success"},{"name":"fleet-paused","conclusion":"skipped"}]'

# ---------------------------------------------------------------------------
# fleet_pause_notice_ran   (jobs JSON on stdin)
# ---------------------------------------------------------------------------

@test "fleet_pause_notice_ran: the notice job concluding success is a paused run" {
  source "$LIB"
  run fleet_pause_notice_ran <<< "$PAUSED_JOBS"
  [ "$status" -eq 0 ]
}

@test "fleet_pause_notice_ran: the notice job skipped (the work ran) is not a paused run" {
  source "$LIB"
  run fleet_pause_notice_ran <<< "$WORKED_JOBS"
  [ "$status" -ne 0 ]
}

@test "fleet_pause_notice_ran: every job skipped is NOT a paused run" {
  # An event filter ends a run this way too, so it proves nothing about a pause.
  source "$LIB"
  run fleet_pause_notice_ran <<< '[{"name":"plan","conclusion":"skipped"},{"name":"fleet-paused","conclusion":"skipped"}]'
  [ "$status" -ne 0 ]
  run fleet_pause_notice_ran <<< '[{"name":"dev-lead / dispatch","conclusion":"skipped"},{"name":"dev-lead / resume","conclusion":"skipped"}]'
  [ "$status" -ne 0 ]
}

@test "fleet_pause_notice_ran: a reusable's nested notice job counts (\"<caller> / fleet-paused\")" {
  source "$LIB"
  run fleet_pause_notice_ran <<< '[{"name":"run / run","conclusion":"skipped"},{"name":"run / fleet-paused","conclusion":"success"}]'
  [ "$status" -eq 0 ]
}

@test "fleet_pause_notice_ran: GraphQL's upper-case conclusions are read the same" {
  source "$LIB"
  run fleet_pause_notice_ran <<< '[{"name":"stale","conclusion":"SKIPPED"},{"name":"fleet-paused","conclusion":"SUCCESS"}]'
  [ "$status" -eq 0 ]
}

@test "fleet_pause_notice_ran: a job that only resembles the notice job does not count" {
  source "$LIB"
  run fleet_pause_notice_ran <<< '[{"name":"not-fleet-paused","conclusion":"success"},{"name":"fleet-paused / report","conclusion":"success"}]'
  [ "$status" -ne 0 ]
}

@test "fleet_pause_notice_ran: a failed or cancelled notice job is not a recorded pause" {
  source "$LIB"
  run fleet_pause_notice_ran <<< '[{"name":"fleet-paused","conclusion":"failure"}]'
  [ "$status" -ne 0 ]
  run fleet_pause_notice_ran <<< '[{"name":"fleet-paused","conclusion":"cancelled"}]'
  [ "$status" -ne 0 ]
  run fleet_pause_notice_ran <<< '[{"name":"fleet-paused","conclusion":null}]'
  [ "$status" -ne 0 ]
}

@test "fleet_pause_notice_ran: empty or unreadable input is not a paused run" {
  source "$LIB"
  run fleet_pause_notice_ran <<< ''
  [ "$status" -ne 0 ]
  run fleet_pause_notice_ran <<< '[]'
  [ "$status" -ne 0 ]
  run fleet_pause_notice_ran <<< 'Plan complete (dry-run): no issues created.'
  [ "$status" -ne 0 ]
  run fleet_pause_notice_ran <<< '{"message":"Not Found"}'
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# fleet_pause_paused_run_nodes / fleet_pause_drop_runs
# ---------------------------------------------------------------------------

@test "fleet_pause_paused_run_nodes: prints the runs whose notice job succeeded, skipping unresolved nodes" {
  source "$LIB"
  resp='{"data":{"nodes":[
    {"id":"A","checkSuite":{"checkRuns":{"nodes":[{"name":"stale","conclusion":"SKIPPED"},{"name":"fleet-paused","conclusion":"SUCCESS"}]}}},
    null,
    {"id":"B","checkSuite":{"checkRuns":{"nodes":[{"name":"stale","conclusion":"SUCCESS"},{"name":"fleet-paused","conclusion":"SKIPPED"}]}}},
    {"id":"C","checkSuite":null},
    {"id":"D","checkSuite":{"checkRuns":{"nodes":[{"name":"run / fleet-paused","conclusion":"SUCCESS"}]}}}
  ]},"errors":[{"type":"NOT_FOUND"}]}'
  run fleet_pause_paused_run_nodes <<< "$resp"
  [ "$status" -eq 0 ]
  [ "$output" = "A"$'\n'"D" ]
}

@test "fleet_pause_paused_run_nodes: an empty or unreadable response prints nothing" {
  source "$LIB"
  run fleet_pause_paused_run_nodes <<< ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run fleet_pause_paused_run_nodes <<< 'gh: HTTP 502'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fleet_pause_drop_runs: removes exactly the paused runs and keeps a run with no node id" {
  source "$LIB"
  runs='[{"node_id":"A","conclusion":"success"},{"node_id":"B","conclusion":"success"},{"conclusion":"failure"}]'
  run fleet_pause_drop_runs '["A"]' <<< "$runs"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"node_id":"B","conclusion":"success"},{"conclusion":"failure"}]' ]
  run fleet_pause_drop_runs '[]' <<< "$runs"
  [ "$output" = "$(jq -c . <<< "$runs")" ]
}

# ---------------------------------------------------------------------------
# fleet_pause_notice_workflows / fleet_pause_workflow_has_notice
# ---------------------------------------------------------------------------

@test "fleet_pause_notice_workflows: lists the registry's job-gate rows and no silent or caller row" {
  source "$LIB"
  run fleet_pause_notice_workflows
  [ "$status" -eq 0 ]
  [[ $'\n'"$output"$'\n' == *$'\n'"persona-runner-reusable.yml"$'\n'* ]]
  [[ $'\n'"$output"$'\n' == *$'\n'"initiative-planner.yml"$'\n'* ]]
  # job-gate-silent: no notice job, a paused run ends skipped.
  [[ $'\n'"$output"$'\n' != *$'\n'"pr-review.yml"$'\n'* ]]
  [[ $'\n'"$output"$'\n' != *$'\n'"dev-lead-reusable.yml"$'\n'* ]]
  [[ $'\n'"$output"$'\n' != *$'\n'"persona-runner.yml"$'\n'* ]]
}

@test "fleet_pause_notice_workflows: a missing registry lists nothing" {
  source "$LIB"
  run fleet_pause_notice_workflows "${BATS_TEST_TMPDIR}/no-such-registry.tsv"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fleet_pause_workflow_has_notice: every job-gate workflow in this repo is recognised from its own file" {
  source "$LIB"
  local wf n=0
  while IFS= read -r wf; do
    n=$(( n + 1 ))
    run fleet_pause_workflow_has_notice < "${WORKFLOWS}/${wf}"
    [ "$status" -eq 0 ] || { echo "not recognised: ${wf}"; return 1; }
  done < <(fleet_pause_notice_workflows)
  [ "$n" -ge 10 ]
}

@test "fleet_pause_workflow_has_notice: the workflows with no notice job are not candidates" {
  source "$LIB"
  local wf names=()
  mapfile -t names < <(fleet_pause_notice_workflows)
  for wf in pr-review.yml pr-review-trigger.yml dev-lead-reusable.yml dev-lead.yml \
            ci-failure-analyst-reusable.yml ci-failure-analyst.lock.yml spec-drift.yml lint.yml; do
    run fleet_pause_workflow_has_notice "${names[@]}" < "${WORKFLOWS}/${wf}"
    [ "$status" -ne 0 ] || { echo "wrongly a candidate: ${wf}"; return 1; }
  done
}

@test "fleet_pause_workflow_has_notice: a caller of a notice-carrying reusable is a candidate, by local path or pinned ref" {
  source "$LIB"
  local names=()
  mapfile -t names < <(fleet_pause_notice_workflows)
  # The real caller in this repo (local path).
  run fleet_pause_workflow_has_notice "${names[@]}" < "${WORKFLOWS}/persona-runner.yml"
  [ "$status" -eq 0 ]
  # A consumer repo pins the same reusable by ref.
  run fleet_pause_workflow_has_notice "${names[@]}" <<< $'jobs:\n  run:\n    uses: petry-projects/.github-private/.github/workflows/persona-runner-reusable.yml@persona-runner/v1-stable  # pinned\n'
  [ "$status" -eq 0 ]
  # Without the registry names the caller's own text says nothing.
  run fleet_pause_workflow_has_notice < "${WORKFLOWS}/persona-runner.yml"
  [ "$status" -ne 0 ]
}

@test "fleet_pause_workflow_has_notice: comments and look-alike names are not a notice job" {
  source "$LIB"
  run fleet_pause_workflow_has_notice persona-runner-reusable.yml <<< $'jobs:\n  # fleet-paused:\n  work:\n    # uses: ./.github/workflows/persona-runner-reusable.yml\n    uses: ./.github/workflows/my-persona-runner-reusable.yml.bak\n    steps:\n      - run: echo "fleet-paused: no"\n'
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# generate_fleet_paused_report <paused_tsv>
# ---------------------------------------------------------------------------

@test "generate_fleet_paused_report: one row per workflow, sorted, and the counted-here-only statement" {
  source "$LIB"
  local f="${BATS_TEST_TMPDIR}/paused.tsv"
  printf 'org/b\t.github/workflows/z.yml\t4\norg/a\t.github/workflows/y.yml\t2\n' > "$f"
  run generate_fleet_paused_report "$f"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "## Fleet-paused runs" ]
  [[ "$output" == *'| `org/a` | `.github/workflows/y.yml` | 2 |'$'\n''| `org/b` | `.github/workflows/z.yml` | 4 |'* ]]
  [[ "$output" == *"They are not in the totals, the success or failure counts, the failure rates or the durations above."* ]]
}

@test "generate_fleet_paused_report: no paused runs prints nothing" {
  source "$LIB"
  local f="${BATS_TEST_TMPDIR}/empty.tsv"
  : > "$f"
  run generate_fleet_paused_report "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run generate_fleet_paused_report "${BATS_TEST_TMPDIR}/absent.tsv"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# initiative_canary.sh — pure helpers
# ---------------------------------------------------------------------------

@test "initiative canary: a green run whose notice job ran is PAUSED, not OK" {
  source "$INITIATIVE"
  run classify_canary_run "success" "" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "PAUSED" ]
}

@test "initiative canary: a green run that was not paused is still OK" {
  source "$INITIATIVE"
  run classify_canary_run "success" "" "false"
  [ "$output" = "OK" ]
  run classify_canary_run "success" ""
  [ "$output" = "OK" ]
}

@test "initiative canary: PAUSED never hides a failure, a missing run or the regression fingerprint" {
  source "$INITIATIVE"
  run classify_canary_run "failure" "" "true"
  [ "$output" = "FAILED" ]
  run classify_canary_run "cancelled" "" "true"
  [ "$output" = "FAILED" ]
  run classify_canary_run "" "" "true"
  [ "$output" = "NO_RUN" ]
  run classify_canary_run "success" "Unsupported event type: discussion" "true"
  [ "$output" = "UNSUPPORTED_EVENT" ]
}

@test "initiative canary: PAUSED does not alert" {
  source "$INITIATIVE"
  run canary_is_failure "PAUSED"
  [ "$status" -ne 0 ]
}

@test "initiative canary: the PAUSED report says paused, not passed and not failed" {
  source "$INITIATIVE"
  run canary_report "PAUSED" "petry-projects/.github-private" "42" "https://x/run/1" "2026-10-11"
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Result:** PAUSED"* ]]
  [[ "$output" == *"AGENTS_PAUSED=true"* ]]
  [[ "$output" == *"neither a pass nor a failure"* ]]
  [[ "$output" != *"canary passed"* ]]
  [[ "$output" != *"did not conclude successfully"* ]]
}

# ---------------------------------------------------------------------------
# initiative_canary.sh — main() against a mocked gh
# ---------------------------------------------------------------------------

# _mock_planner_gh <jobs-json> — a gh whose dispatched planner run ended
# `success` with the given jobs. An empty <jobs-json> makes the jobs read fail.
_mock_planner_gh() {
  MOCK_BIN="$(mktemp -d "${BATS_TEST_TMPDIR}/mock_bin.XXXXXX")"
  GH_LOG="$(mktemp "${BATS_TEST_TMPDIR}/gh_log.XXXXXX")"
  MOCK_JOBS="$1"
  export GH_LOG MOCK_BIN MOCK_JOBS
  export PATH="$MOCK_BIN:$PATH"
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
# Apply the real --jq filter (as gh would) so main()'s jq is exercised.
jqf=""; args=("$@")
for ((i=0;i<${#args[@]};i++)); do [ "${args[i]}" = "--jq" ] && jqf="${args[i+1]}"; done
emit() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
case "$1 $2" in
  "workflow run") exit 0 ;;
  "run list")
    echo '[{"databaseId":555,"status":"completed","conclusion":"success","createdAt":"2026-10-11T06:30:00Z","event":"workflow_dispatch"}]' | emit
    ;;
  "run view")
    case " $* " in
      *" --json jobs "*)
        [ -n "$MOCK_JOBS" ] || { echo "gh: HTTP 502" >&2; exit 1; }
        printf '{"jobs":%s}\n' "$MOCK_JOBS" | emit ;;
      *) echo "fleet-paused	Report the fleet pause	2026-10-11T06:30:10Z ##[notice]Initiative Planner: not run" ;;
    esac
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"

  export REPO="petry-projects/.github-private"
  export CANARY_DISCUSSION="42"
  export GH_TOKEN="pat"
  export CANARY_POLL_TIMEOUT="5"
  export CANARY_POLL_INTERVAL="1"
  CANARY_OUT="$(mktemp "${BATS_TEST_TMPDIR}/canary_out.XXXXXX")"; export CANARY_OUT
  GITHUB_ENV="$(mktemp "${BATS_TEST_TMPDIR}/github_env.XXXXXX")"; export GITHUB_ENV
  unset GITHUB_STEP_SUMMARY
}

@test "initiative canary main: a paused planner run is reported PAUSED, exits clean and raises no alert" {
  _mock_planner_gh "$PAUSED_JOBS"

  run bash "$INITIATIVE"
  [ "$status" -eq 0 ]

  # Paused: not OK (a pass), not FAILED, and no alert flag for the issue step.
  grep -qxF "CANARY_STATUS=PAUSED" "$GITHUB_ENV"
  run grep -c "CANARY_FAILED" "$GITHUB_ENV"
  [ "$output" = "0" ]
  grep -qF "**Result:** PAUSED" "$CANARY_OUT"

  # It read the run's jobs to find that out: exactly one extra call.
  run grep -c -- "run view 555 --repo petry-projects/.github-private --json jobs" "$GH_LOG"
  [ "$output" = "1" ]
}

@test "initiative canary main: a paused run is never announced as passed" {
  _mock_planner_gh "$PAUSED_JOBS"

  run bash "$INITIATIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice title=Agent fleet paused::"* ]]
  [[ "$output" != *"canary passed"* ]]
}

@test "initiative canary main: a green run whose notice job was skipped is still OK" {
  _mock_planner_gh "$WORKED_JOBS"

  run bash "$INITIATIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Initiative-planner canary passed"* ]]
  grep -qxF "CANARY_STATUS=OK" "$GITHUB_ENV"
}

@test "initiative canary main: an unreadable jobs list falls back to the conclusion (OK), never to PAUSED" {
  _mock_planner_gh ""

  run bash "$INITIATIVE"
  [ "$status" -eq 0 ]
  grep -qxF "CANARY_STATUS=OK" "$GITHUB_ENV"
}

# ---------------------------------------------------------------------------
# pr_review_canary.sh — pure helpers
# ---------------------------------------------------------------------------

@test "pr-review canary: a skipped run while the fleet is paused is PAUSED, not FAILED" {
  source "$PR_REVIEW"
  run classify_canary_run "skipped" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "PAUSED" ]
  # GitHub compares the variable without regard to case.
  run classify_canary_run "skipped" "TRUE"
  [ "$output" = "PAUSED" ]
}

@test "pr-review canary: a skipped run alone is NOT read as a pause" {
  # Every job skipped is all a paused pr-review run records, but an event filter
  # produces the same run, so without the pause switch it stays FAILED.
  source "$PR_REVIEW"
  run classify_canary_run "skipped"
  [ "$output" = "FAILED" ]
  run classify_canary_run "skipped" ""
  [ "$output" = "FAILED" ]
  run classify_canary_run "skipped" "false"
  [ "$output" = "FAILED" ]
  run classify_canary_run "skipped" "truthy"
  [ "$output" = "FAILED" ]
}

@test "pr-review canary: the pause switch alone changes no other conclusion" {
  source "$PR_REVIEW"
  run classify_canary_run "success" "true"
  [ "$output" = "OK" ]
  run classify_canary_run "failure" "true"
  [ "$output" = "FAILED" ]
  run classify_canary_run "cancelled" "true"
  [ "$output" = "FAILED" ]
  run classify_canary_run "startup_failure" "true"
  [ "$output" = "STARTUP_FAILURE" ]
  run classify_canary_run "" "true"
  [ "$output" = "NO_RUN" ]
}

@test "pr-review canary: PAUSED does not alert" {
  source "$PR_REVIEW"
  run canary_is_failure "PAUSED"
  [ "$status" -ne 0 ]
}

@test "pr-review canary: the PAUSED report says paused, not passed and not FAILED" {
  source "$PR_REVIEW"
  run canary_report "PAUSED" "petry-projects/.github-private" "https://x/run/1" "2026-10-11"
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Result:** PAUSED"* ]]
  [[ "$output" == *"AGENTS_PAUSED=true"* ]]
  [[ "$output" == *"neither a pass nor a failure"* ]]
  [[ "$output" != *"canary passed"* ]]
  [[ "$output" != *"concluded FAILED"* ]]
  [[ "$output" != *"concluded non-success"* ]]
}

# ---------------------------------------------------------------------------
# pr_review_canary.sh — main() against a mocked gh
# ---------------------------------------------------------------------------

# _mock_review_gh <conclusion> — a gh whose dispatched pr-review-trigger run
# ended with the given conclusion.
_mock_review_gh() {
  MOCK_BIN="$(mktemp -d "${BATS_TEST_TMPDIR}/mock_bin.XXXXXX")"
  GH_LOG="$(mktemp "${BATS_TEST_TMPDIR}/gh_log.XXXXXX")"
  MOCK_CONCLUSION="$1"
  export GH_LOG MOCK_BIN MOCK_CONCLUSION
  export PATH="$MOCK_BIN:$PATH"
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
jqf=""; args=("$@")
for ((i=0;i<${#args[@]};i++)); do [ "${args[i]}" = "--jq" ] && jqf="${args[i+1]}"; done
emit() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
case "$1 $2" in
  "workflow run") exit 0 ;;
  "run list")
    printf '[{"databaseId":777,"status":"completed","conclusion":"%s","createdAt":"2026-10-11T06:50:00Z","event":"workflow_dispatch"}]\n' "$MOCK_CONCLUSION" | emit
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"

  export REPO="petry-projects/.github-private"
  export GH_TOKEN="pat"
  export CANARY_POLL_TIMEOUT="5"
  export CANARY_POLL_INTERVAL="1"
  CANARY_OUT="$(mktemp "${BATS_TEST_TMPDIR}/canary_out.XXXXXX")"; export CANARY_OUT
  GITHUB_ENV="$(mktemp "${BATS_TEST_TMPDIR}/github_env.XXXXXX")"; export GITHUB_ENV
  unset GITHUB_STEP_SUMMARY AGENTS_PAUSED
}

@test "pr-review canary main: a paused (skipped) run is reported PAUSED, exits clean and raises no alert" {
  _mock_review_gh "skipped"
  export AGENTS_PAUSED="true"

  run bash "$PR_REVIEW"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice title=Agent fleet paused::"* ]]
  [[ "$output" != *"canary passed"* ]]

  grep -qxF "CANARY_STATUS=PAUSED" "$GITHUB_ENV"
  run grep -c "CANARY_FAILED" "$GITHUB_ENV"
  [ "$output" = "0" ]
  grep -qF "**Result:** PAUSED" "$CANARY_OUT"
  run grep -c "FAILED" "$CANARY_OUT"
  [ "$output" = "0" ]
}

@test "pr-review canary main: a skipped run with the fleet not paused is still FAILED (unchanged)" {
  _mock_review_gh "skipped"

  run bash "$PR_REVIEW"
  [ "$status" -eq 0 ]
  grep -qxF "CANARY_STATUS=FAILED" "$GITHUB_ENV"
}

@test "pr-review canary main: a startup_failure still fails loud while the fleet is paused" {
  _mock_review_gh "startup_failure"
  export AGENTS_PAUSED="true"

  run bash "$PR_REVIEW"
  [ "$status" -ne 0 ]
  grep -qxF "CANARY_STATUS=STARTUP_FAILURE" "$GITHUB_ENV"
  grep -qxF "CANARY_FAILED=true" "$GITHUB_ENV"
}

# ---------------------------------------------------------------------------
# The canary workflows: PAUSED reaches the script and is not announced as a pass
# ---------------------------------------------------------------------------

# step_field <workflow-file> <step-name> <field> — the value of <field> on the
# named step (first line only).
step_field() {
  awk -v name="      - name: $2" -v field="        $3: " '
    $0 == name { f = 1; next }
    f && /^      - / { exit }
    f && index($0, field) == 1 { print substr($0, length(field) + 1); exit }
  ' "${WORKFLOWS}/$1"
}

@test "canary workflows: the 'passed' annotation does not run on PAUSED" {
  local f cond
  for f in initiative-planner-canary.yml pr-review-canary.yml; do
    cond="$(step_field "$f" "Annotate clean canary" "if")"
    [[ "$cond" == *"env.CANARY_FAILED != 'true'"* ]] || { echo "$f: $cond"; return 1; }
    [[ "$cond" == *"env.CANARY_STATUS != 'PAUSED'"* ]] || { echo "$f: $cond"; return 1; }
  done
}

@test "pr-review canary workflow: the script is given the fleet pause switch" {
  run grep -c '^          AGENTS_PAUSED: \${{ vars.AGENTS_PAUSED }}$' "${WORKFLOWS}/pr-review-canary.yml"
  [ "$output" = "1" ]
}
