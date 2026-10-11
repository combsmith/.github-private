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
  FAKE_API="${WORK}/api"; export FAKE_API
  FAKE_ROOT="${WORK}/root"; export FAKE_ROOT
  CALLS="${WORK}/calls.log"; export CALLS
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
