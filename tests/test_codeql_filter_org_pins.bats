#!/usr/bin/env bats
# scripts/codeql-filter-org-pins.sh — drops CodeQL's actions/unpinned-tag
# results on the org's own refs from a SARIF file and keeps every other result;
# fails closed on a SARIF it cannot read. The last tests pin the CodeQL workflow
# to analyze without uploading, filter, then upload the filtered file.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FILTER="$REPO_ROOT/scripts/codeql-filter-org-pins.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/codeql.yml"

ORG_MSG="Job [Job: dev-lead](1) in 'Dev-Lead Agent' uses reusable workflow 'combsmith/.github-private/.github/workflows/dev-lead-reusable.yml' with ref 'dev-lead/v139-ring0', not a pinned commit hash"
THIRD_MSG="Unpinned 3rd party Action 'CI' step [Uses Step](1) uses 'someone/setup-thing' with ref 'v2', not a pinned commit hash"

setup() {
  SANDBOX="$(mktemp -d)"
  SRC="$SANDBOX/src"
  mkdir -p "$SRC/.github/workflows"
  # Line 3: an org channel pin. Line 7: a third-party action pinned by tag.
  printf '%s\n' \
    'jobs:' \
    '  dev-lead:' \
    '    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v139-ring0  # first-party channel ref' \
    '  build:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - uses: someone/setup-thing@v2' \
    '      - uses: "Combsmith/.github/.github/workflows/x-reusable.yml@x/v1-stable"' \
    '      - uses: combsmith-evil/thing@v1' \
    '      - uses: notcombsmith/thing@v1' \
    "      - uses: 'combsmith/some-action@v3'" \
    > "$SRC/.github/workflows/ci.yml"
  IN="$SANDBOX/in.sarif"
  OUT="$SANDBOX/out/actions.sarif"
  export ORG=combsmith
}

teardown() {
  rm -rf "$SANDBOX"
}

# _result RULE URI LINE MESSAGE — one SARIF result as compact JSON.
_result() {
  jq -cn --arg rule "$1" --arg uri "$2" --argjson line "$3" --arg msg "$4" '{
    ruleId: $rule, rule: {id: $rule, index: 0},
    message: {text: $msg},
    locations: [{physicalLocation: {
      artifactLocation: {uri: $uri, uriBaseId: "%SRCROOT%", index: 0},
      region: {startLine: $line, startColumn: 11, endColumn: 95}}}]}'
}

# _sarif RESULT_JSON... — a one-run SARIF log holding the given results.
_sarif() {
  printf '%s\n' "$@" | jq -s '{
    "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
    version: "2.1.0",
    runs: [{
      tool: {driver: {name: "CodeQL", semanticVersion: "2.27.5"}},
      automationDetails: {id: "/language:actions/"},
      artifacts: [{location: {uri: ".github/workflows/ci.yml", uriBaseId: "%SRCROOT%"}}],
      results: .}]}' > "$IN"
}

_filter() {
  run "$FILTER" "$IN" "$OUT" "$SRC"
}

_out_messages() {
  jq -r '.runs[].results[].message.text' "$OUT"
}

# ── the rule ────────────────────────────────────────────────────────────────

@test "an org channel pin on a reusable workflow job is dropped" {
  _sarif "$(_result actions/unpinned-tag .github/workflows/ci.yml 3 "$ORG_MSG")"
  _filter
  [ "$status" -eq 0 ]
  [ "$(jq '.runs[0].results | length' "$OUT")" -eq 0 ]
  [[ "$output" == *"dropped: .github/workflows/ci.yml:3 uses combsmith/.github-private/"* ]]
  [[ "$output" == *"1 results in, 1 org-ref actions/unpinned-tag dropped, 0 other"* ]]
}

@test "a third-party action pinned by tag is kept" {
  _sarif "$(_result actions/unpinned-tag .github/workflows/ci.yml 7 "$THIRD_MSG")"
  _filter
  [ "$status" -eq 0 ]
  [ "$(_out_messages)" = "$THIRD_MSG" ]
  [[ "$output" == *"kept:    .github/workflows/ci.yml:7"* ]]
}

@test "every other rule is kept, even on an org pin line" {
  _sarif \
    "$(_result actions/untrusted-checkout/medium .github/workflows/ci.yml 3 "uses reusable workflow 'combsmith/a/b.yml' with ref 'x', not a pinned commit hash")" \
    "$(_result actions/missing-workflow-permissions .github/workflows/ci.yml 3 "$ORG_MSG")" \
    "$(_result actions/unpinned-tag .github/workflows/ci.yml 3 "$ORG_MSG")"
  _filter
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.runs[0].results[].ruleId] | join(",")' "$OUT")" = "actions/untrusted-checkout/medium,actions/missing-workflow-permissions" ]
}

@test "a mixed log keeps the third-party and other results in order and the run's metadata" {
  _sarif \
    "$(_result actions/unpinned-tag .github/workflows/ci.yml 7 "$THIRD_MSG")" \
    "$(_result actions/unpinned-tag .github/workflows/ci.yml 3 "$ORG_MSG")" \
    "$(_result py/sql-injection app.py 1 "SQL built from user input")"
  _filter
  [ "$status" -eq 0 ]
  [ "$(jq '.runs[0].results | length' "$OUT")" -eq 2 ]
  [ "$(jq -r '.runs[0].results[0].message.text' "$OUT")" = "$THIRD_MSG" ]
  [ "$(jq -r '.runs[0].results[1].ruleId' "$OUT")" = "py/sql-injection" ]
  [ "$(jq -r '.runs[0].automationDetails.id' "$OUT")" = "/language:actions/" ]
  [ "$(jq -r '.runs[0].tool.driver.name' "$OUT")" = "CodeQL" ]
  [ "$(jq -r '.version' "$OUT")" = "2.1.0" ]
}

@test "the owner is matched without case, and a quoted uses value is read" {
  _sarif "$(_result actions/unpinned-tag .github/workflows/ci.yml 8 "Unpinned 3rd party Action 'CI' step [Uses Step](1) uses 'Combsmith/.github/.github/workflows/x-reusable.yml' with ref 'x/v1-stable', not a pinned commit hash")"
  _filter
  [ "$status" -eq 0 ]
  [ "$(jq '.runs[0].results | length' "$OUT")" -eq 0 ]
}

@test "an org action step (not only a reusable workflow) is dropped" {
  _sarif "$(_result actions/unpinned-tag .github/workflows/ci.yml 11 "Unpinned 3rd party Action 'CI' step [Uses Step](1) uses 'combsmith/some-action' with ref 'v3', not a pinned commit hash")"
  _filter
  [ "$status" -eq 0 ]
  [ "$(jq '.runs[0].results | length' "$OUT")" -eq 0 ]
}

@test "an owner that only starts or ends with the org name is kept" {
  _sarif \
    "$(_result actions/unpinned-tag .github/workflows/ci.yml 9 "Unpinned 3rd party Action 'CI' step [Uses Step](1) uses 'combsmith-evil/thing' with ref 'v1', not a pinned commit hash")" \
    "$(_result actions/unpinned-tag .github/workflows/ci.yml 10 "Unpinned 3rd party Action 'CI' step [Uses Step](1) uses 'notcombsmith/thing' with ref 'v1', not a pinned commit hash")"
  _filter
  [ "$status" -eq 0 ]
  [ "$(jq '.runs[0].results | length' "$OUT")" -eq 2 ]
}

@test "a workflow name that quotes an org ref cannot hide a third-party action" {
  local spoof="Unpinned 3rd party Action 'x uses reusable workflow 'combsmith/a/b.yml' with ref 'v1', not a pinned commit hash' step [Uses Step](1) uses 'someone/setup-thing' with ref 'v2', not a pinned commit hash"
  _sarif "$(_result actions/unpinned-tag .github/workflows/ci.yml 7 "$spoof")"
  _filter
  [ "$status" -eq 0 ]
  [ "$(jq '.runs[0].results | length' "$OUT")" -eq 1 ]
}

@test "the line and the message must agree: an org line with a third-party message is kept" {
  _sarif "$(_result actions/unpinned-tag .github/workflows/ci.yml 3 "$THIRD_MSG")"
  _filter
  [ "$status" -eq 0 ]
  [ "$(jq '.runs[0].results | length' "$OUT")" -eq 1 ]
}

@test "an org message on a third-party line is kept" {
  _sarif "$(_result actions/unpinned-tag .github/workflows/ci.yml 7 "$ORG_MSG")"
  _filter
  [ "$status" -eq 0 ]
  [ "$(jq '.runs[0].results | length' "$OUT")" -eq 1 ]
}

@test "a result whose line cannot be read is kept: missing file, path outside the checkout, absolute path, no line, a line with no uses" {
  _sarif \
    "$(_result actions/unpinned-tag .github/workflows/gone.yml 3 "$ORG_MSG")" \
    "$(_result actions/unpinned-tag ../src/.github/workflows/ci.yml 3 "$ORG_MSG")" \
    "$(_result actions/unpinned-tag "$SRC/.github/workflows/ci.yml" 3 "$ORG_MSG")" \
    "$(_result actions/unpinned-tag .github/workflows/ci.yml 0 "$ORG_MSG")" \
    "$(_result actions/unpinned-tag .github/workflows/ci.yml 2 "$ORG_MSG")"
  _filter
  [ "$status" -eq 0 ]
  [ "$(jq '.runs[0].results | length' "$OUT")" -eq 5 ]
}

@test "a path given only by artifact index is resolved" {
  _sarif "$(_result actions/unpinned-tag .github/workflows/ci.yml 3 "$ORG_MSG" | jq -c 'del(.locations[0].physicalLocation.artifactLocation.uri)')"
  _filter
  [ "$status" -eq 0 ]
  [ "$(jq '.runs[0].results | length' "$OUT")" -eq 0 ]
}

@test "a rule id given only under rule.id is read" {
  _sarif "$(_result actions/unpinned-tag .github/workflows/ci.yml 3 "$ORG_MSG" | jq -c 'del(.ruleId)')"
  _filter
  [ "$status" -eq 0 ]
  [ "$(jq '.runs[0].results | length' "$OUT")" -eq 0 ]
}

@test "ORG names the exempt owner" {
  _sarif "$(_result actions/unpinned-tag .github/workflows/ci.yml 3 "$ORG_MSG")"
  ORG=someone-else run "$FILTER" "$IN" "$OUT" "$SRC"
  [ "$status" -eq 0 ]
  [ "$(jq '.runs[0].results | length' "$OUT")" -eq 1 ]
}

@test "a run with no results passes through" {
  jq -n '{version: "2.1.0", runs: [{tool: {driver: {name: "CodeQL"}}, results: []}, {tool: {driver: {name: "CodeQL"}}}]}' > "$IN"
  _filter
  [ "$status" -eq 0 ]
  [ "$(jq '.runs | length' "$OUT")" -eq 2 ]
}

@test "is_org_ref: only ORG/<repo>[/<path>]@<ref> counts" {
  run bash -c '
    source "$1"; ORG=combsmith
    for ref in combsmith/a@v1 combsmith/a/.github/workflows/b.yml@b/v1-next COMBSMITH/a@x; do
      is_org_ref "$ref" || { echo "rejected $ref"; exit 1; }
    done
    for ref in combsmith/@v1 combsmith//a@v1 combsmith/a combsmith/a@ combsmith@v1 /combsmith/a@v1 combsmithx/a@v1 x/combsmith/a@v1; do
      if is_org_ref "$ref"; then echo "accepted $ref"; exit 1; fi
    done' _ "$FILTER"
  [ "$status" -eq 0 ]
}

# ── fails closed ────────────────────────────────────────────────────────────

@test "fails closed: input that is not JSON exits 2 and writes nothing" {
  printf 'not json\n' > "$IN"
  _filter
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not a SARIF log"* ]]
  [ ! -e "$OUT" ]
}

@test "fails closed: no runs array, an empty runs array, or a results field that is not an array" {
  local bad
  for bad in '{"version":"2.1.0"}' '{"runs":[]}' '{"runs":{}}' '{"runs":[{"results":{}}]}' '[]' '{"runs":["x"]}'; do
    printf '%s\n' "$bad" > "$IN"
    _filter
    [ "$status" -eq 2 ] || { echo "accepted: $bad"; return 1; }
    [ ! -e "$OUT" ] || { echo "wrote output for: $bad"; return 1; }
  done
}

@test "fails closed: a missing input file exits 2" {
  run "$FILTER" "$SANDBOX/none.sarif" "$OUT" "$SRC"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no SARIF file"* ]]
  [ ! -e "$OUT" ]
}

@test "fails closed: wrong argument count or a bad ORG exits 2" {
  _sarif "$(_result actions/unpinned-tag .github/workflows/ci.yml 3 "$ORG_MSG")"
  run "$FILTER" "$IN"
  [ "$status" -eq 2 ]
  ORG='bad/org' run "$FILTER" "$IN" "$OUT" "$SRC"
  [ "$status" -eq 2 ]
  [ ! -e "$OUT" ]
}

# ── the workflow ────────────────────────────────────────────────────────────

@test "codeql.yml: analyze does not upload, the filter runs, then upload-sarif sends the filtered file" {
  grep -Eq '^[[:space:]]+upload:[[:space:]]*failure-only[[:space:]]*$' "$WORKFLOW"
  grep -q 'scripts/codeql-filter-org-pins.sh' "$WORKFLOW"
  grep -Eq '^[[:space:]]+uses:[[:space:]]*github/codeql-action/upload-sarif@' "$WORKFLOW"
  local analyze filter upload
  analyze="$(grep -n 'github/codeql-action/analyze@' "$WORKFLOW" | cut -d: -f1)"
  filter="$(grep -n 'scripts/codeql-filter-org-pins.sh' "$WORKFLOW" | head -1 | cut -d: -f1)"
  upload="$(grep -n 'github/codeql-action/upload-sarif@' "$WORKFLOW" | cut -d: -f1)"
  [ "$analyze" -lt "$filter" ]
  [ "$filter" -lt "$upload" ]
}

@test "codeql.yml: init, analyze and upload-sarif share one pinned commit" {
  run bash -c "grep -Eo 'github/codeql-action/(init|analyze|upload-sarif)@[0-9a-f]{40}' '$WORKFLOW' | sed 's/.*@//' | sort -u"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(grep -Ec 'github/codeql-action/(init|analyze|upload-sarif)@[0-9a-f]{40}' "$WORKFLOW")" -eq 3 ]
}

@test "codeql.yml: the upload keeps the per-language category and the CodeQL job" {
  [ "$(grep -Ec '^[[:space:]]+category:[[:space:]]*/language:\$\{\{ matrix.language \}\}[[:space:]]*$' "$WORKFLOW")" -eq 2 ]
  grep -Eq '^[[:space:]]+name:[[:space:]]*CodeQL[[:space:]]*$' "$WORKFLOW"
}
