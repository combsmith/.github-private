#!/usr/bin/env bats
# Tests for scripts/ci-failure-analyst-resolve.sh (#2235).
#
# The CI Failure Analyst reusable is called from a stub that triggers on
# check_run (third-party checks such as SonarCloud) and, once the stubs gain it,
# on workflow_run (failed GitHub Actions runs). The resolver reads whichever
# payload the run carries and must end every unusable payload in the
# "skipping" notice with exit 0, never in `jq: Cannot iterate over null`.
#
# gh is stubbed: each `gh api <path>` call is answered from a fixture file and
# the call's own --jq filter is applied with real jq, so the filters the script
# passes are exercised, not mocked away.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci-failure-analyst-resolve.sh"

SHA="0123456789abcdef0123456789abcdef01234567"

# setup — initialize test environment with temporary directories, gh stub, and fixtures.
setup() {
  TMP="$(mktemp -d)" || { echo "Failed to create temp directory" >&2; exit 1; }
  STUB_BIN="$TMP/bin"
  GH_FIXTURES="$TMP/fixtures"
  GH_CALLS="$TMP/gh-calls.log"
  mkdir -p "$STUB_BIN" "$GH_FIXTURES"
  : > "$GH_CALLS"
  export GH_FIXTURES GH_CALLS

  # gh stub: `gh api <path> [--paginate] [--jq <expr>]`. The fixture for
  # <path> is $GH_FIXTURES/<path with / as _>.json; a missing fixture is a
  # failed call (like a 404).
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
[ "${1:-}" = "api" ] || exit 1
shift
path="" expr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) expr="$2"; shift 2 ;;
    --paginate) shift ;;
    -*) shift ;;
    *) [ -z "$path" ] && path="$1"; shift ;;
  esac
done
fixture="$GH_FIXTURES/$(printf '%s' "$path" | tr '/' '_').json"
[ -f "$fixture" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
if [ -n "$expr" ]; then
  jq -r "$expr" "$fixture"
else
  cat "$fixture"
fi
GHEOF
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"

  export REPO="combsmith/.github-private"
  export GITHUB_OUTPUT="$TMP/output"
  : > "$GITHUB_OUTPUT"
  export GITHUB_EVENT_PATH="$TMP/event.json"
  unset PR_NUMBER HEAD_SHA
}

# teardown — clean up temporary directory and all test artifacts.
teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# fixture <api-path> <json> — write a mock gh api response fixture for testing.
fixture() {
  printf '%s\n' "$2" > "$GH_FIXTURES/$(printf '%s' "$1" | tr '/' '_').json"
}

# out <key> — retrieve the last value written for <key> to GITHUB_OUTPUT.
out() {
  grep "^$1=" "$GITHUB_OUTPUT" | tail -n 1 | cut -d= -f2-
}

check_run_event() {
  cat > "$GITHUB_EVENT_PATH" <<JSON
{
  "action": "completed",
  "check_run": {
    "id": 555,
    "name": "SonarCloud Code Analysis",
    "conclusion": "failure",
    "head_sha": "$SHA",
    "details_url": "https://sonarcloud.io/dashboard?id=petry-projects_x",
    "pull_requests": [
      {"number": 42,
       "state": "open",
       "head": {"repo": {"id": 1}},
       "base": {"repo": {"id": 1}}}
    ]
  }
}
JSON
}

# workflow_run_event <pull_requests-json> [head_branch]
workflow_run_event() {
  cat > "$GITHUB_EVENT_PATH" <<JSON
{
  "action": "completed",
  "workflow_run": {
    "id": 777,
    "name": "Lint",
    "conclusion": "failure",
    "head_sha": "$SHA",
    "head_branch": "${2:-feature/x}",
    "html_url": "https://github.com/combsmith/.github-private/actions/runs/777",
    "pull_requests": $1
  }
}
JSON
}

# failed_jobs_fixture — create a mock GitHub Actions jobs API response with failed jobs.
failed_jobs_fixture() {
  fixture "repos/$REPO/actions/runs/777/jobs" '{
    "total_count": 3,
    "jobs": [
      {"name": "shellcheck", "conclusion": "failure",
       "steps": [{"name": "Set up job", "conclusion": "success"},
                 {"name": "Run tests", "conclusion": "failure"}]},
      {"name": "markdownlint", "conclusion": "success", "steps": []},
      {"name": "template-drift", "conclusion": "failure", "steps": []}
    ]
  }'
}

# ── check_run ────────────────────────────────────────────────────────────────

@test "check_run: PR, SHA, name and details URL come from the check_run payload" {
  check_run_event
  fixture "repos/$REPO/pulls/42" '{"state": "open"}'
  run bash "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  [ "$(out skip)" = "false" ]
  [ "$(out event)" = "check_run" ]
  [ "$(out pr_number)" = "42" ]
  [ "$(out head_sha)" = "$SHA" ]
  [ "$(out check_name)" = "SonarCloud Code Analysis" ]
  [ "$(out details_url)" = "https://sonarcloud.io/dashboard?id=petry-projects_x" ]
  [ "$(out check_run_id)" = "555" ]
  # A third-party check has no Actions run behind it.
  [ "$(out run_id)" = "" ]
  [ "$(out failed_jobs)" = "" ]
  # The embedded PR was used; no commits-to-pulls lookup was needed.
  run grep -c "commits/$SHA/pulls" "$GH_CALLS"
  [ "$output" = "0" ]
}

@test "check_run: an Actions details URL yields the run id and its failed jobs" {
  check_run_event
  fixture "repos/$REPO/pulls/42" '{"state": "open"}'
  jq '.check_run.details_url = "https://github.com/combsmith/.github-private/actions/runs/777/job/9"' \
    "$GITHUB_EVENT_PATH" > "$TMP/e" && mv "$TMP/e" "$GITHUB_EVENT_PATH"
  failed_jobs_fixture
  run bash "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  [ "$(out run_id)" = "777" ]
  [ "$(out failed_jobs)" = "shellcheck / Run tests; template-drift" ]
}

@test "check_run: a failed jobs lookup fails the step instead of emitting empty failed_jobs" {
  check_run_event
  fixture "repos/$REPO/pulls/42" '{"state": "open"}'
  jq '.check_run.details_url = "https://github.com/combsmith/.github-private/actions/runs/777/job/9"' \
    "$GITHUB_EVENT_PATH" > "$TMP/e" && mv "$TMP/e" "$GITHUB_EVENT_PATH"
  run bash "$SCRIPT" resolve
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not look up the failed jobs"* ]]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "check_run: empty pull_requests falls back to the commits-to-pulls lookup" {
  check_run_event
  jq '.check_run.pull_requests = []' "$GITHUB_EVENT_PATH" > "$TMP/e" && mv "$TMP/e" "$GITHUB_EVENT_PATH"
  fixture "repos/$REPO/commits/$SHA/pulls" '[
    {"number": 43, "state": "open", "head": {"repo": {"full_name": "combsmith/.github-private"}}}
  ]'
  run bash "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  [ "$(out skip)" = "false" ]
  [ "$(out pr_number)" = "43" ]
}

# ── workflow_run ─────────────────────────────────────────────────────────────

@test "workflow_run: SHA, PR, run id and failed jobs come from the workflow_run payload" {
  workflow_run_event '[{"number": 99, "state": "open", "head": {"repo": {"id": 7}}, "base": {"repo": {"id": 7}}}]'
  fixture "repos/$REPO/pulls/99" '{"state": "open"}'
  failed_jobs_fixture
  run bash "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  [ "$(out skip)" = "false" ]
  [ "$(out event)" = "workflow_run" ]
  [ "$(out pr_number)" = "99" ]
  [ "$(out head_sha)" = "$SHA" ]
  [ "$(out check_name)" = "Lint" ]
  [ "$(out details_url)" = "https://github.com/combsmith/.github-private/actions/runs/777" ]
  [ "$(out run_id)" = "777" ]
  [ "$(out check_run_id)" = "" ]
  [ "$(out failed_jobs)" = "shellcheck / Run tests; template-drift" ]
}

@test "workflow_run: a fork PR in the payload is ignored and the lookup decides" {
  workflow_run_event '[{"number": 5, "head": {"repo": {"id": 8}}, "base": {"repo": {"id": 7}}}]'
  fixture "repos/$REPO/commits/$SHA/pulls" '[
    {"number": 5, "state": "open", "head": {"repo": {"full_name": "someone/fork"}}}
  ]'
  run bash "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  [ "$(out skip)" = "true" ]
  [[ "$output" == *"::notice::No non-fork PR for SHA $SHA"*"skipping"* ]]
}

@test "workflow_run: empty pull_requests falls back to the commits-to-pulls lookup" {
  workflow_run_event '[]'
  fixture "repos/$REPO/commits/$SHA/pulls" '[
    {"number": 101, "state": "open", "head": {"repo": {"full_name": "combsmith/.github-private"}}}
  ]'
  failed_jobs_fixture
  run bash "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  [ "$(out skip)" = "false" ]
  [ "$(out pr_number)" = "101" ]
}

@test "workflow_run on the default branch with no PR: skipping notice, exit 0" {
  workflow_run_event '[]' main
  # A push to main: the commit's only associated PR is the one already merged.
  fixture "repos/$REPO/commits/$SHA/pulls" '[
    {"number": 88, "state": "closed", "head": {"repo": {"full_name": "combsmith/.github-private"}}}
  ]'
  run bash "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  [ "$(out skip)" = "true" ]
  [ "$(out pr_number)" = "" ]
  [[ "$output" == *"::notice::No non-fork PR for SHA $SHA"*"skipping"* ]]
}

@test "workflow_run with null pull_requests never reaches a jq iteration error" {
  workflow_run_event 'null'
  fixture "repos/$REPO/commits/$SHA/pulls" '[]'
  run bash "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  [ "$(out skip)" = "true" ]
  [[ "$output" != *"Cannot iterate"* ]]
}

@test "workflow_run: an embedded PR that has since closed is not reported" {
  workflow_run_event '[{"number": 99, "head": {"repo": {"id": 7}}, "base": {"repo": {"id": 7}}}]'
  fixture "repos/$REPO/pulls/99" '{"state": "closed"}'
  fixture "repos/$REPO/commits/$SHA/pulls" '[]'
  run bash "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  [ "$(out skip)" = "true" ]
}

@test "workflow_run: a closed first embedded PR does not hide a later open one" {
  workflow_run_event '[{"number": 98, "head": {"repo": {"id": 7}}, "base": {"repo": {"id": 7}}},
                       {"number": 99, "head": {"repo": {"id": 7}}, "base": {"repo": {"id": 7}}}]'
  fixture "repos/$REPO/pulls/98" '{"state": "closed"}'
  fixture "repos/$REPO/pulls/99" '{"state": "open"}'
  failed_jobs_fixture
  run bash "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  [ "$(out skip)" = "false" ]
  [ "$(out pr_number)" = "99" ]
}

@test "workflow_run: a failed PR-state lookup fails loudly instead of skipping" {
  workflow_run_event '[{"number": 99, "head": {"repo": {"id": 7}}, "base": {"repo": {"id": 7}}}]'
  run bash "$SCRIPT" resolve
  [ "$status" -ne 0 ]
  [ "$(out skip)" = "" ]
}

@test "workflow_run: a failed commits-to-pulls lookup fails loudly instead of skipping" {
  workflow_run_event '[]'
  run bash "$SCRIPT" resolve
  [ "$status" -ne 0 ]
  [ "$(out skip)" = "" ]
}

# ── unusable payloads ────────────────────────────────────────────────────────

@test "empty payload: skipping notice, exit 0, no jq error, no API call" {
  echo '{}' > "$GITHUB_EVENT_PATH"
  run bash "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  [ "$(out skip)" = "true" ]
  [[ "$output" == *"::notice::"*"skipping"* ]]
  [[ "$output" != *"Cannot iterate"* ]]
  [ ! -s "$GH_CALLS" ]
}

@test "zero-byte, non-JSON and missing payload files all skip with exit 0" {
  : > "$GITHUB_EVENT_PATH"
  run bash "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  [ "$(out skip)" = "true" ]

  : > "$GITHUB_OUTPUT"
  echo 'not json' > "$GITHUB_EVENT_PATH"
  run bash "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  [ "$(out skip)" = "true" ]

  : > "$GITHUB_OUTPUT"
  rm -f "$GITHUB_EVENT_PATH"
  run bash "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  [ "$(out skip)" = "true" ]
}

# ── idempotency: one analysis per commit ─────────────────────────────────────

@test "idempotency: no marker comment yet means the analysis runs" {
  export PR_NUMBER=99 HEAD_SHA="$SHA"
  fixture "repos/$REPO/issues/99/comments" '[{"id": 1, "body": "unrelated"}]'
  run bash "$SCRIPT" idempotency
  [ "$status" -eq 0 ]
  [ "$(out exists)" = "false" ]
}

@test "two failures on one SHA: the second trigger finds the marker and skips" {
  fixture "repos/$REPO/issues/99/comments" '[]'

  # First failure: a workflow_run for Lint.
  workflow_run_event '[{"number": 99, "state": "open", "head": {"repo": {"id": 7}}, "base": {"repo": {"id": 7}}}]'
  fixture "repos/$REPO/pulls/99" '{"state": "open"}'
  failed_jobs_fixture
  run bash "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  first_sha="$(out head_sha)"
  PR_NUMBER="$(out pr_number)" HEAD_SHA="$first_sha" run bash "$SCRIPT" idempotency
  [ "$status" -eq 0 ]
  [ "$(out exists)" = "false" ]

  # The first analysis posts its comment.
  fixture "repos/$REPO/issues/99/comments" "[{\"id\": 321, \"body\": \"<!-- ci-analyst sha=$first_sha -->\\n## CI Failure: Lint\"}]"

  # Second failure on the same commit: a different workflow (Tests), and a
  # third-party check_run, both resolve to the same SHA and so the same marker.
  : > "$GITHUB_OUTPUT"
  workflow_run_event '[{"number": 99, "state": "open", "head": {"repo": {"id": 7}}, "base": {"repo": {"id": 7}}}]'
  fixture "repos/$REPO/pulls/99" '{"state": "open"}'
  jq '.workflow_run.name = "Tests" | .workflow_run.id = 778' "$GITHUB_EVENT_PATH" > "$TMP/e" && mv "$TMP/e" "$GITHUB_EVENT_PATH"
  fixture "repos/$REPO/actions/runs/778/jobs" '{"jobs": []}'
  run bash "$SCRIPT" resolve
  [ "$(out head_sha)" = "$first_sha" ]
  PR_NUMBER="$(out pr_number)" HEAD_SHA="$(out head_sha)" run bash "$SCRIPT" idempotency
  [ "$status" -eq 0 ]
  [ "$(out exists)" = "true" ]
  [[ "$output" == *"already posted (id=321)"* ]]
}

@test "idempotency: a marker for a different SHA does not suppress this one" {
  export PR_NUMBER=99 HEAD_SHA="$SHA"
  fixture "repos/$REPO/issues/99/comments" '[{"id": 2, "body": "<!-- ci-analyst sha=ffffffffffffffffffffffffffffffffffffffff -->"}]'
  run bash "$SCRIPT" idempotency
  [ "$status" -eq 0 ]
  [ "$(out exists)" = "false" ]
}

@test "idempotency: a failed comment lookup fails closed instead of posting a duplicate" {
  export PR_NUMBER=99 HEAD_SHA="$SHA"
  # no fixture for the comments path: the gh stub answers with a 404 failure
  run bash "$SCRIPT" idempotency
  [ "$status" -eq 0 ]
  [ "$(out exists)" = "true" ]
  [[ "$output" == *"lookup failed"* ]]
}

@test "unknown subcommand is a usage error" {
  run bash "$SCRIPT" bogus
  [ "$status" -eq 2 ]
}
