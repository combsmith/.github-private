#!/usr/bin/env bats
# Trusted records only (#2147): the Gemini tier snapshot and history are built from
# token-usage artifacts collected across the organisation, and an artifact is
# untrusted input (a pull request from a fork can upload one of any name and
# content). These tests pin the rule that decides which artifacts are believed,
# the hand-off that passes only their records on, and the reader a dispatch
# decision must use, which answers `unknown` whenever the snapshot cannot vouch
# for itself.
#
# No network: `gh` is a stub on PATH that serves fixture files. Every temporary
# file lives under $BATS_TEST_TMPDIR.
# Run locally: bats tests/token_report_trust.bats

ROOT="${BATS_TEST_DIRNAME}/.."
TOKEN_REPORT="$ROOT/scripts/token_report.sh"
TIER_REPORT="$ROOT/scripts/gemini_tier_report.sh"
QUOTA_LIB="$ROOT/scripts/lib/gemini-quota.sh"
FLEET_MONITOR="$ROOT/.github/workflows/actions-fleet-monitor.yml"

# 2026-10-10T12:00:00Z, inside the Pacific quota day that started 07:00Z.
NOW=1791633600

setup() {
  FIX="$BATS_TEST_TMPDIR/fix"
  BIN="$BATS_TEST_TMPDIR/bin"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$FIX" "$BIN" "$OUT"
  export FIX
  # The gh stub: `gh api <path> ...` answers from $FIX; everything else is a no-op.
  cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "api" ] || exit 0
case "${2:-}" in
  orgs/*/repos*) cat "$FIX/repos.txt" ;;
  repos/*/actions/artifacts/*/zip)
    id="${2%/zip}"; id="${id##*/}"
    [ -f "$FIX/$id.zip" ] || exit 1
    cat "$FIX/$id.zip" ;;
  repos/*/actions/artifacts*) cat "$FIX/artifacts.json" ;;
  repos/*/actions/runs/*)
    id="${2##*/}"
    echo "$id" >> "$FIX/lookups.log"
    [ -f "$FIX/run-$id.json" ] || exit 1
    cat "$FIX/run-$id.json" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$BIN/gh"
  PATH="$BIN:$PATH"
  export ORG=combsmith LOOKBACK_DAYS=7 COLLECT_CONCURRENCY=2 ARTIFACT_OP_TIMEOUT=0
  printf 'combsmith/test-repo:main\n' > "$FIX/repos.txt"
  : > "$FIX/lookups.log"
}

# _zip <artifact_id> <jsonl line>... — a token-usage artifact holding those records.
_zip() {
  local id="$1"; shift
  printf '%s\n' "$@" > "$FIX/$id.jsonl"
  python3 - "$FIX/$id.zip" "$FIX/$id.jsonl" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.write(sys.argv[2], "token-usage.jsonl")
PY
}

# _zip_files <artifact_id> <name>=<content>... — an artifact holding those files.
_zip_files() {
  local id="$1" spec dir="$FIX/src-$1"; shift
  mkdir -p "$dir"
  for spec in "$@"; do printf '%s\n' "${spec#*=}" > "$dir/${spec%%=*}"; done
  python3 - "$FIX/$id.zip" "$dir" <<'PY'
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for name in sorted(os.listdir(sys.argv[2])):
        z.write(os.path.join(sys.argv[2], name), name)
PY
}

# _gemini <context> [extra json] — one Gemini token record, tagged so a test can
# tell which artifact it came from.
_gemini() {
  jq -cn --arg c "$1" --argjson extra "${2:-{\}}" \
    '{ts:"2026-10-10T10:00:00Z", workflow:"dev-lead", engine:"gemini", model:"gemini-3.8-flash",
      key_index:1, input_tokens:10, cache_read_tokens:0, output_tokens:2, context:$c} + $extra'
}

# _artifact <id> <run_id> <repository_id> <head_repository_id> <head_branch>
_artifact() {
  jq -cn --argjson id "$1" --argjson run "$2" --argjson repo "$3" --argjson head "$4" --arg branch "$5" \
    '{id:$id, name:"token-usage-\($run)", expired:false, created_at:"2099-01-01T00:00:00Z",
      workflow_run:{id:$run, repository_id:$repo, head_repository_id:$head, head_branch:$branch, head_sha:"0"}}'
}

# _listing <artifact json>... — the artifact listing the stub serves.
_listing() {
  printf '%s\n' "$@" | jq -s '{artifacts: .}' > "$FIX/artifacts.json"
}

# _run <run_id> <repository_id> <head_repository_id> <actor> [triggering_actor]
_run() {
  jq -cn --argjson id "$1" --argjson repo "$2" --argjson head "$3" --arg actor "$4" --arg trig "${5:-$4}" \
    '{id:$id, event:"pull_request", repository:{id:$repo}, head_repository:{id:$head},
      actor:{login:$actor}, triggering_actor:{login:$trig}}' > "$FIX/run-$1.json"
}

# _collect — run the collector into $OUT; prints nothing.
_collect() {
  # shellcheck source=scripts/token_report.sh
  source "$TOKEN_REPORT"
  collect_org_jsonl "$OUT" >/dev/null
}

# _stamp <context> — "<trusted> <basis> <run_id>" of the collected record tagged <context>.
_stamp() {
  cat "$OUT"/*.jsonl 2>/dev/null | jq -r --arg c "$1" \
    'select(.context == $c) | "\(.provenance.trusted) \(.provenance.basis) \(.provenance.run_id)"'
}

# ---------------------------------------------------------------------------
# The trust rule, at the point of collection
# ---------------------------------------------------------------------------

@test "trust: a default-branch run of the repository is trusted from the listing alone" {
  _zip 101 "$(_gemini a101)"
  _listing "$(_artifact 101 9001 1 1 main)"
  _collect
  [ "$(_stamp a101)" = "true default-branch 9001" ]
  # No extra API call was spent on it.
  [ ! -s "$FIX/lookups.log" ]
}

@test "trust: a same-repository pull request branch run is trusted once the run look-up confirms it" {
  _zip 102 "$(_gemini a102)"
  _listing "$(_artifact 102 9002 1 1 feature/x)"
  _run 9002 1 1 don-petry
  _collect
  [ "$(_stamp a102)" = "true same-repository-run 9002" ]
  [ "$(cat "$FIX/lookups.log")" = "9002" ]
}

@test "trust: a fork run is never trusted, even from a branch named like the default branch" {
  _zip 103 "$(_gemini a103)"
  _listing "$(_artifact 103 9003 1 2 main)"
  _run 9003 1 1 don-petry
  _collect
  [ "$(_stamp a103)" = "false not-this-repository 9003" ]
  # A fork is settled by the listing: the run is not even asked about.
  [ ! -s "$FIX/lookups.log" ]
}

@test "trust: what an artifact says about its own provenance is replaced, not believed" {
  _zip 103 "$(_gemini a103 '{"provenance":{"run_id":9001,"trusted":true,"basis":"default-branch"},"trusted":true,"run_id":"9001","repo":"combsmith/other"}')"
  _listing "$(_artifact 103 9003 1 2 feature/x)"
  _collect
  [ "$(_stamp a103)" = "false not-this-repository 9003" ]
  [ "$(cat "$OUT"/*.jsonl | jq -r '.repo')" = "combsmith/test-repo" ]
}

@test "trust: a look-up that FAILS is not an answer: untrusted, and stamped run-lookup-failed" {
  # 9004: gh exits non-zero (403, 404, rate limit, timeout). 9021: an error body
  # with exit 0. 9022: not JSON. 9023: an empty body.
  _zip 104 "$(_gemini a104)"
  _zip 121 "$(_gemini a121)"
  _zip 122 "$(_gemini a122)"
  _zip 123 "$(_gemini a123)"
  _listing "$(_artifact 104 9004 1 1 feature/y)" "$(_artifact 121 9021 1 1 feature/y)" \
    "$(_artifact 122 9022 1 1 feature/y)" "$(_artifact 123 9023 1 1 feature/y)"
  printf '%s\n' '{"message":"API rate limit exceeded","status":"403"}' > "$FIX/run-9021.json"
  printf 'upstream connect error\n' > "$FIX/run-9022.json"
  : > "$FIX/run-9023.json"
  _collect
  [ "$(_stamp a104)" = "false run-lookup-failed 9004" ]
  [ "$(_stamp a121)" = "false run-lookup-failed 9021" ]
  [ "$(_stamp a122)" = "false run-lookup-failed 9022" ]
  [ "$(_stamp a123)" = "false run-lookup-failed 9023" ]
  [ "$(sort "$FIX/lookups.log" | paste -sd, -)" = "9004,9021,9022,9023" ]
}

@test "trust: a run is looked up once, however many artifacts it uploaded" {
  # A re-run attempt uploads another artifact under the same run id.
  _zip 131 "$(_gemini a131)"
  _zip 132 "$(_gemini a132)"
  _zip 133 "$(_gemini a133)"
  _zip 134 "$(_gemini a134)"
  _listing "$(_artifact 131 9031 1 1 feature/x)" "$(_artifact 132 9031 1 1 feature/x)" \
    "$(_artifact 133 9031 1 1 feature/x)" "$(_artifact 134 9032 1 1 feature/y)"
  _run 9031 1 1 don-petry
  _collect
  [ "$(_stamp a131)" = "true same-repository-run 9031" ]
  [ "$(_stamp a132)" = "true same-repository-run 9031" ]
  [ "$(_stamp a133)" = "true same-repository-run 9031" ]
  [ "$(_stamp a134)" = "false run-lookup-failed 9032" ]
  [ "$(sort "$FIX/lookups.log" | paste -sd, -)" = "9031,9032" ]
}

@test "trust: a Dependabot run is not trusted (as actor or as triggering actor)" {
  _zip 105 "$(_gemini a105)"
  _zip 115 "$(_gemini a115)"
  _listing "$(_artifact 105 9005 1 1 dependabot/npm/x)" "$(_artifact 115 9015 1 1 dependabot/npm/y)"
  _run 9005 1 1 'dependabot[bot]'
  _run 9015 1 1 don-petry 'Dependabot[bot]'
  _collect
  [ "$(_stamp a105)" = "false run-not-verified 9005" ]
  [ "$(_stamp a115)" = "false run-not-verified 9015" ]
}

@test "trust: an artifact with no workflow_run in the listing is not trusted" {
  _zip 106 "$(_gemini a106)"
  jq -cn '{artifacts:[{id:106, name:"token-usage-x", expired:false, created_at:"2099-01-01T00:00:00Z"}]}' \
    > "$FIX/artifacts.json"
  _collect
  [ "$(_stamp a106)" = "false run-unknown null" ]
}

# A fork is known to be a fork: nothing is missing. An artifact whose run the
# listing does not name may be real usage, so the collection is incomplete.
@test "hand-off: an artifact the listing names no run for is a failed read; a fork's is not" {
  _zip 106 "$(_gemini a106)"
  _zip 103 "$(_gemini a103)"
  jq -cn --argjson fork "$(_artifact 103 9003 1 2 main)" \
    '{artifacts:[{id:106, name:"token-usage-x", expired:false, created_at:"2099-01-01T00:00:00Z",
                  workflow_run:{id:9006, repository_id:1}}, $fork]}' > "$FIX/artifacts.json"
  export GEMINI_RECORDS_OUT="$BATS_TEST_TMPDIR/gemini-records.jsonl"
  export GEMINI_COLLECTION_OUT="$BATS_TEST_TMPDIR/collection.json"
  run bash "$TOKEN_REPORT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.repo_listings_failed, .artifacts_failed, .run_lookups_failed, .record_files_malformed]' "$GEMINI_COLLECTION_OUT")" = "[0,0,1,0]" ]
  [[ "$output" == *"artifact 106 from"*"the listing does not say which run uploaded it"* ]]
  [[ "$output" != *"artifact 103 from"*"does not say which run"* ]]
  [ ! -s "$GEMINI_RECORDS_OUT" ]
}

@test "trust: a look-up that answers with another run, another head repository or no actor is not trusted" {
  _zip 107 "$(_gemini a107)"
  _zip 108 "$(_gemini a108)"
  _zip 109 "$(_gemini a109)"
  _listing "$(_artifact 107 9007 1 1 feature/a)" "$(_artifact 108 9008 1 1 feature/b)" \
    "$(_artifact 109 9009 1 1 feature/c)"
  _run 9007 1 1 don-petry
  jq -c '.id = 4242' "$FIX/run-9007.json" > "$FIX/run-9007.json.tmp" && mv "$FIX/run-9007.json.tmp" "$FIX/run-9007.json"
  _run 9008 1 2 don-petry
  _run 9009 1 1 don-petry
  jq -c 'del(.actor)' "$FIX/run-9009.json" > "$FIX/run-9009.json.tmp" && mv "$FIX/run-9009.json.tmp" "$FIX/run-9009.json"
  _collect
  [ "$(_stamp a107)" = "false run-not-verified 9007" ]
  [ "$(_stamp a108)" = "false run-not-verified 9008" ]
  [ "$(_stamp a109)" = "false run-not-verified 9009" ]
}

@test "trust: without the repository's default branch every same-repository run takes the look-up" {
  printf 'combsmith/test-repo\n' > "$FIX/repos.txt"
  _zip 101 "$(_gemini a101)"
  _zip 111 "$(_gemini a111)"
  _listing "$(_artifact 101 9001 1 1 main)" "$(_artifact 111 9011 1 1 main)"
  _run 9001 1 1 don-petry
  _collect
  [ "$(_stamp a101)" = "true same-repository-run 9001" ]
  [ "$(_stamp a111)" = "false run-lookup-failed 9011" ]
}

@test "trust: a caller that passes no origin (canary_report.sh) still collects, stamped untrusted" {
  _zip 120 "$(_gemini a120)"
  # shellcheck source=scripts/token_report.sh
  source "$TOKEN_REPORT"
  export COLLECT_JSONL_DIR="$OUT" COLLECT_WORKDIR="$BATS_TEST_TMPDIR/work" COLLECT_MARKER_DIR="$BATS_TEST_TMPDIR/work/markers"
  mkdir -p "$COLLECT_MARKER_DIR"
  _collect_one_artifact combsmith/test-repo 120
  [ -f "$COLLECT_MARKER_DIR/120" ]
  [ "$(_stamp a120)" = "false not-this-repository null" ]
}

# ---------------------------------------------------------------------------
# The hand-off to the tier report
# ---------------------------------------------------------------------------

# _mixed_fixture — one trusted default-branch artifact, one trusted branch run, one
# fork artifact that forges 30 rejected attempts, and one branch run whose look-up
# ANSWERS and does not qualify (its head is another repository).
_mixed_fixture() {
  local forged=() i
  for i in $(seq 1 30); do
    forged+=("$(jq -cn --arg ts "2026-10-10T10:00:$(printf '%02d' "$i")Z" \
      '{kind:"gemini_attempt", ts:$ts, engine:"gemini", key_index:1, model:"gemini-3.8-flash", rejected:true,
        provenance:{run_id:9001, trusted:true, basis:"default-branch"}}')")
  done
  _zip 101 "$(_gemini a101)" '{"ts":"2026-10-10T10:00:00Z","engine":"claude","model":"claude-opus-4-7","input_tokens":5,"output_tokens":1,"context":"c101"}'
  _zip 102 "$(_gemini a102)"
  _zip 103 "${forged[@]}"
  _zip 104 "$(_gemini a104)"
  _listing "$(_artifact 101 9001 1 1 main)" "$(_artifact 102 9002 1 1 feature/x)" \
    "$(_artifact 103 9003 1 2 main)" "$(_artifact 104 9004 1 1 feature/y)"
  _run 9002 1 1 don-petry
  _run 9004 1 2 don-petry
}

@test "hand-off: only records from trusted runs reach the tier report; the rest are counted, not passed" {
  _mixed_fixture
  export GEMINI_RECORDS_OUT="$BATS_TEST_TMPDIR/gemini-records.jsonl"
  export GEMINI_COLLECTION_OUT="$BATS_TEST_TMPDIR/collection.json"
  run bash "$TOKEN_REPORT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.context' "$GEMINI_RECORDS_OUT" | sort | paste -sd, -)" = "a101,a102" ]
  [ "$(jq -r 'select(.kind == "gemini_attempt") | .kind' "$GEMINI_RECORDS_OUT" | wc -l | tr -d ' ')" = "0" ]
  # Logged, annotated, and in the job summary (stdout).
  [[ "$output" == *"Gemini ledger: 2 record(s) from trusted runs handed to the tier report; 31 record(s) in 2 artifact(s) ignored"* ]]
  [[ "$output" == *"::warning::[gemini-ledger] 31 Gemini record(s) in 2 token-usage artifact(s) were ignored"* ]]
  [[ "$output" == *"### Gemini ledger provenance"* ]]
  # The cost report is not filtered: it still shows every collected call.
  [[ "$output" == *"4 agent runs"* ]]
  [ "$(jq -c '[.handed_over, .artifacts_listed, .repo_listings_failed, .artifacts_failed, .gemini_records_trusted, .gemini_records_ignored, .artifacts_ignored, .gemini_records_unlisted]' "$GEMINI_COLLECTION_OUT")" = "[true,4,0,0,2,31,2,0]" ]
  # A look-up that answered "no" is ignored usage, not a failed read.
  [ "$(jq -c '[.run_lookups_failed, .record_files_malformed]' "$GEMINI_COLLECTION_OUT")" = "[0,0]" ]
  [[ "$output" != *"the collection is incomplete"* ]]
  # The complete collection carries through to a snapshot a decision may use.
  _snapshot_from "$GEMINI_COLLECTION_OUT"
  [ "$(jq -c '[.collection.complete, .collection.records]' "$SNAP")" = '[true,"trusted-runs-only"]' ]
}

@test "hand-off: a run look-up that fails is a failed read: the collection is incomplete and the decision unknown" {
  _mixed_fixture
  rm -f "$FIX/run-9004.json"
  export GEMINI_RECORDS_OUT="$BATS_TEST_TMPDIR/gemini-records.jsonl"
  export GEMINI_COLLECTION_OUT="$BATS_TEST_TMPDIR/collection.json"
  run bash "$TOKEN_REPORT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.handed_over, .repo_listings_failed, .artifacts_failed, .run_lookups_failed, .record_files_malformed]' "$GEMINI_COLLECTION_OUT")" = "[true,0,0,1,0]" ]
  [[ "$output" == *"::warning::[gemini-ledger] the collection is incomplete: 0 repository listing(s), 0 artifact(s), 1 run look-up(s) and 0 record file(s) could not be read"* ]]
  [[ "$output" == *"run 9004 could not be looked up"* ]]
  # Its records are still not handed over.
  [ "$(jq -r '.context' "$GEMINI_RECORDS_OUT" | sort | paste -sd, -)" = "a101,a102" ]
  _snapshot_from "$GEMINI_COLLECTION_OUT"
  [ "$(jq -c '[.collection.complete, .collection.records, .collection.run_lookups_failed]' "$SNAP")" = '[false,"trusted-runs-only",1]' ]
  # shellcheck source=scripts/lib/gemini-quota.sh
  source "$QUOTA_LIB"
  GEMINI_QUOTA_NOW="$NOW" run gq_tier_decision "$SNAP" triage
  [ "$status" -eq 2 ]
  [[ "$output" == "unknown "*"1 run look-up(s)"* ]]
}

@test "hand-off: a record file that is not valid JSONL is a failed read; the artifact's other file is kept" {
  _zip_files 101 "a.jsonl=$(_gemini a101)" 'b.jsonl={"engine":"gemini","key_index":1,'
  _listing "$(_artifact 101 9001 1 1 main)"
  export GEMINI_RECORDS_OUT="$BATS_TEST_TMPDIR/gemini-records.jsonl"
  export GEMINI_COLLECTION_OUT="$BATS_TEST_TMPDIR/collection.json"
  run bash "$TOKEN_REPORT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.context' "$GEMINI_RECORDS_OUT")" = "a101" ]
  [ "$(jq -c '[.artifacts_failed, .run_lookups_failed, .record_files_malformed, .gemini_records_trusted]' "$GEMINI_COLLECTION_OUT")" = "[0,0,1,1]" ]
  [[ "$output" == *"a record file is not valid JSONL"* ]]
  [[ "$output" == *"1 record file(s) could not be read"* ]]
  _snapshot_from "$GEMINI_COLLECTION_OUT"
  [ "$(jq -c '[.collection.complete, .collection.record_files_malformed]' "$SNAP")" = '[false,1]' ]
}

@test "hand-off: nothing is left in the temporary directory, whether or not records were handed over" {
  _mixed_fixture
  mkdir -p "$BATS_TEST_TMPDIR/tmp"
  export GEMINI_RECORDS_OUT="$BATS_TEST_TMPDIR/gemini-records.jsonl"
  TMPDIR="$BATS_TEST_TMPDIR/tmp" run bash "$TOKEN_REPORT"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/tmp")" ]
  # An early exit (the organisation cannot be listed) leaves nothing either.
  rm -f "$FIX/repos.txt"
  TMPDIR="$BATS_TEST_TMPDIR/tmp" run bash "$TOKEN_REPORT"
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/tmp")" ]
}

@test "hand-off: test-fixture records in a trusted run's ledger are counted apart and reported" {
  # A real agent run whose session also ran engine tests: they inherit the job's
  # ledger path and write records no production call writes.
  _zip 101 "$(_gemini a101)" \
    "$(_gemini fixture-model '{"model":"gemini-test","key_index":2}')" \
    "$(_gemini fixture-key '{"key_index":"1b"}')" \
    "$(_gemini no-key '{"model":"gemini-same","key_index":null}')"
  _listing "$(_artifact 101 9001 1 1 main)"
  export GEMINI_RECORDS_OUT="$BATS_TEST_TMPDIR/gemini-records.jsonl"
  export GEMINI_COLLECTION_OUT="$BATS_TEST_TMPDIR/collection.json"
  run bash "$TOKEN_REPORT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.gemini_records_trusted, .gemini_records_ignored, .gemini_records_unlisted]' "$GEMINI_COLLECTION_OUT")" = "[4,0,2]" ]
  [[ "$output" == *"::warning::[gemini-ledger] 2 Gemini record(s) from trusted runs are for a key index and model the caps file does not list"* ]]
  [[ "$output" == *"1b:gemini-3.8-flash"* ]]
  [[ "$output" == *"2:gemini-test"* ]]
}

@test "hand-off: a failed download is reported as a failed artifact, so the collection reads incomplete" {
  _mixed_fixture
  rm -f "$FIX/102.zip"
  export GEMINI_RECORDS_OUT="$BATS_TEST_TMPDIR/gemini-records.jsonl"
  export GEMINI_COLLECTION_OUT="$BATS_TEST_TMPDIR/collection.json"
  run bash "$TOKEN_REPORT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.artifacts_listed, .repo_listings_failed, .artifacts_failed]' "$GEMINI_COLLECTION_OUT")" = "[4,0,1]" ]
}

@test "hand-off: a failed artifact listing is reported as a failed repository listing" {
  _mixed_fixture
  rm -f "$FIX/artifacts.json"
  export GEMINI_RECORDS_OUT="$BATS_TEST_TMPDIR/gemini-records.jsonl"
  export GEMINI_COLLECTION_OUT="$BATS_TEST_TMPDIR/collection.json"
  run bash "$TOKEN_REPORT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.artifacts_listed, .repo_listings_failed, .artifacts_failed, .gemini_records_trusted]' "$GEMINI_COLLECTION_OUT")" = "[0,1,0,0]" ]
}

@test "hand-off: a record that carries no collector stamp is not handed over" {
  # shellcheck source=scripts/token_report.sh
  source "$TOKEN_REPORT"
  local d="$BATS_TEST_TMPDIR/dir" t="$BATS_TEST_TMPDIR/trusted"
  mkdir -p "$d" "$t"
  {
    _gemini unstamped
    _gemini string-true '{"provenance":{"run_id":1,"trusted":"true","basis":"default-branch"}}'
    _gemini no-run '{"provenance":{"run_id":null,"trusted":true,"basis":"default-branch"}}'
    _gemini good '{"provenance":{"run_id":7,"trusted":true,"basis":"default-branch"}}'
  } > "$d/1-run.jsonl"
  trusted_records_dir "$d" "$t"
  [ "$(jq -r '.context' "$t/trusted.jsonl")" = "good" ]
  [ "$(gemini_provenance_counts "$d")" = "$(printf '1\t3\t1')" ]
}

# ---------------------------------------------------------------------------
# The snapshot says what it was built from
# ---------------------------------------------------------------------------

# _tier_report <collection json|""> — run the tier report on one trusted record at
# NOW; the snapshot lands in $BATS_TEST_TMPDIR/state/snapshot.json.
_tier_report() {
  local in="$BATS_TEST_TMPDIR/in.jsonl"
  _gemini a101 '{"provenance":{"run_id":9001,"trusted":true,"basis":"default-branch"}}' > "$in"
  export GEMINI_TIER_STATE_DIR="$BATS_TEST_TMPDIR/state" GEMINI_RECORDS_IN="$in" GEMINI_QUOTA_NOW="$NOW"
  unset GEMINI_COLLECTION_IN
  if [ -n "${1:-}" ]; then
    printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/collection.json"
    export GEMINI_COLLECTION_IN="$BATS_TEST_TMPDIR/collection.json"
  fi
  run bash "$TIER_REPORT"
  SNAP="$BATS_TEST_TMPDIR/state/snapshot.json"
}

# _snapshot_from <collection report file> — the tier report's snapshot ($SNAP) for
# that collection report, generated at NOW.
_snapshot_from() {
  _tier_report "$(cat "$1")"
  [ "$status" -eq 0 ]
}

_complete='{"collected_at":"2026-10-10T11:59:00Z","collected_epoch":1791633540,"handed_over":true,"artifacts_listed":4,"repo_listings_failed":0,"artifacts_failed":0,"run_lookups_failed":0,"record_files_malformed":0,"gemini_records_trusted":2,"gemini_records_ignored":31,"artifacts_ignored":2,"gemini_records_unlisted":0}'

@test "snapshot: a complete, trusted-only collection is recorded as such" {
  _tier_report "$_complete"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.collection.complete, .collection.records, .collection.gemini_records_ignored]' "$SNAP")" = '[true,"trusted-runs-only",31]' ]
  [[ "$output" == *"only from trusted runs (2 handed over, 31 ignored in 2 artifact(s))"* ]]
  [[ "$output" == *"collection complete"* ]]
}

@test "snapshot: with no collection report it says unverified and incomplete" {
  _tier_report ""
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.collection.complete, .collection.records]' "$SNAP")" = '[false,"unverified"]' ]
  [[ "$output" == *"INCOMPLETE"* ]]
}

@test "snapshot: a failed listing or download makes the collection incomplete, and a malformed report unverified" {
  _tier_report "$(jq -c '.artifacts_failed = 1' <<< "$_complete")"
  [ "$(jq -c '[.collection.complete, .collection.records]' "$SNAP")" = '[false,"trusted-runs-only"]' ]
  _tier_report "$(jq -c '.repo_listings_failed = 2' <<< "$_complete")"
  [ "$(jq -r '.collection.complete' "$SNAP")" = "false" ]
  _tier_report "$(jq -c '.run_lookups_failed = 1' <<< "$_complete")"
  [ "$(jq -c '[.collection.complete, .collection.records]' "$SNAP")" = '[false,"trusted-runs-only"]' ]
  [[ "$output" == *"INCOMPLETE"*"1 run look-up(s)"* ]]
  _tier_report "$(jq -c '.record_files_malformed = 1' <<< "$_complete")"
  [ "$(jq -r '.collection.complete' "$SNAP")" = "false" ]
  _tier_report "$(jq -c 'del(.run_lookups_failed)' <<< "$_complete")"
  [ "$(jq -r '.collection.complete' "$SNAP")" = "false" ]
  _tier_report "$(jq -c 'del(.record_files_malformed)' <<< "$_complete")"
  [ "$(jq -r '.collection.complete' "$SNAP")" = "false" ]
  _tier_report "$(jq -c '.handed_over = "true"' <<< "$_complete")"
  [ "$(jq -c '[.collection.complete, .collection.records]' "$SNAP")" = '[false,"unverified"]' ]
  _tier_report "$(jq -c 'del(.artifacts_failed)' <<< "$_complete")"
  [ "$(jq -r '.collection.complete' "$SNAP")" = "false" ]
  _tier_report 'not json'
  [ "$(jq -c '[.collection.complete, .collection.records]' "$SNAP")" = '[false,"unverified"]' ]
}

@test "snapshot: unlisted records in the ledger (test fixtures) make the collection unusable for a decision" {
  _tier_report "$(jq -c '.gemini_records_unlisted = 2' <<< "$_complete")"
  [ "$(jq -c '[.collection.complete, .collection.records, .collection.gemini_records_unlisted]' "$SNAP")" = '[false,"trusted-runs-only",2]' ]
  [[ "$output" == *"INCOMPLETE"*"caps file does not list"* ]]
  _tier_report "$(jq -c 'del(.gemini_records_unlisted)' <<< "$_complete")"
  [ "$(jq -r '.collection.complete' "$SNAP")" = "false" ]
  # shellcheck source=scripts/lib/gemini-quota.sh
  source "$QUOTA_LIB"
  jq -c --argjson now "$NOW" '.generated_epoch = ($now - 60)' "$SNAP" > "$BATS_TEST_TMPDIR/d.json"
  GEMINI_QUOTA_NOW="$NOW" run gq_tier_decision "$BATS_TEST_TMPDIR/d.json" triage
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# The reader a dispatch decision must use: "cannot tell" is never "available"
# ---------------------------------------------------------------------------

# _decide <jq edit of the good snapshot> [tier] [max_age] — gq_tier_decision at NOW
# on a snapshot generated 60 s earlier from a complete, trusted-only collection.
_decide() {
  _tier_report "$_complete"
  [ "$status" -eq 0 ]
  local snap="$BATS_TEST_TMPDIR/decide.json"
  jq -c --argjson now "$NOW" '.generated_epoch = ($now - 60) | '"$1" "$SNAP" > "$snap"
  # shellcheck source=scripts/lib/gemini-quota.sh
  source "$QUOTA_LIB"
  export GEMINI_QUOTA_NOW="$NOW"
  run gq_tier_decision "$snap" "${2:-triage}" ${3:+"$3"}
}

@test "decision: a fresh snapshot from a complete trusted-only collection answers with the tier status" {
  _decide '.'
  [ "$status" -eq 0 ]
  [ "$output" = "available" ]
  _decide '(.tiers[] | select(.tier == "triage")) |= (.status = "degraded" | .degraded_to = "model-b")'
  [ "$status" -eq 0 ]
  [ "$output" = "degraded model-b" ]
  _decide '(.tiers[] | select(.tier == "triage")).status = "unavailable"'
  [ "$status" -eq 1 ]
  [ "$output" = "unavailable" ]
}

@test "decision: records of unverified provenance are unknown, never available" {
  _decide '.collection.records = "unverified"'
  [ "$status" -eq 2 ]
  [[ "$output" == "unknown "*"trusted runs"* ]]
  _decide 'del(.collection)'
  [ "$status" -eq 2 ]
  [[ "$output" == "unknown "* ]]
}

@test "decision: an incomplete collection is unknown, never available" {
  _decide '.collection.complete = false | .collection.reason = "1 repository listing(s) and 0 artifact(s) could not be read"'
  [ "$status" -eq 2 ]
  [[ "$output" == "unknown "*"incomplete"*"1 repository listing"* ]]
}

@test "decision: a stale snapshot, or one from the future, is unknown" {
  _decide '.generated_epoch -= 3600'
  [ "$status" -eq 2 ]
  [[ "$output" == "unknown "*"old"* ]]
  _decide '.generated_epoch += 86400'
  [ "$status" -eq 2 ]
  [[ "$output" == "unknown "* ]]
  # The limit is the caller's: 30 s rejects the 60 s old snapshot.
  _decide '.' triage 30
  [ "$status" -eq 2 ]
  _decide '.' triage not-a-number
  [ "$status" -eq 2 ]
}

@test "decision: a snapshot of a quota day that has ended is unknown" {
  _decide '.window.day_end = (.generated_epoch + 30)'
  [ "$status" -eq 2 ]
  [[ "$output" == "unknown "*"quota day"* ]]
}

@test "decision: an unreadable snapshot, a missing tier and an unknown status are unknown" {
  # shellcheck source=scripts/lib/gemini-quota.sh
  source "$QUOTA_LIB"
  export GEMINI_QUOTA_NOW="$NOW"
  run gq_tier_decision "$BATS_TEST_TMPDIR/absent.json" triage
  [ "$status" -eq 2 ]
  [[ "$output" == "unknown "* ]]
  printf 'not json\n' > "$BATS_TEST_TMPDIR/bad.json"
  run gq_tier_decision "$BATS_TEST_TMPDIR/bad.json" triage
  [ "$status" -eq 2 ]
  _decide '.' no-such-tier
  [ "$status" -eq 2 ]
  _decide '(.tiers[] | select(.tier == "triage")).status = "unknown"'
  [ "$status" -eq 2 ]
  _decide '.schema_version = 2'
  [ "$status" -eq 2 ]
}

@test "decision: a snapshot whose window, collection or tiers is not what it should be is unknown" {
  local bad
  for bad in '"a string"' '42' '[1,2]' 'null' 'true'; do
    _decide ".window = $bad"
    [ "$status" -eq 2 ] || { echo "window=$bad gave $status: $output"; false; }
    [[ "$output" == "unknown "* ]]
    _decide ".collection = $bad"
    [ "$status" -eq 2 ] || { echo "collection=$bad gave $status: $output"; false; }
    [[ "$output" == "unknown "* ]]
    _decide ".tiers = $bad"
    [ "$status" -eq 2 ] || { echo "tiers=$bad gave $status: $output"; false; }
    [[ "$output" == "unknown "* ]]
  done
  _decide 'del(.window)'
  [ "$status" -eq 2 ]
  _decide 'del(.tiers)'
  [ "$status" -eq 2 ]
  _decide '.tiers = ["triage", 7]'
  [ "$status" -eq 2 ]
  _decide '.window.day_start = "soon"'
  [ "$status" -eq 2 ]
  _decide '.collection.complete = "true"'
  [ "$status" -eq 2 ]
  # The same holds for a caller that runs under pipefail.
  _decide '.window = "a string"'
  set -o pipefail
  run gq_tier_decision "$BATS_TEST_TMPDIR/decide.json" triage
  set +o pipefail
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# The snapshot the tier report writes: schema contract and a clean failure
# ---------------------------------------------------------------------------

# The validator is Python `jsonschema`, as in
# tests/dev-lead/unit/test_gemini_tier_view.bats. CI installs it (the bats job of
# lint.yml, the unit job of test-dev-lead.yml), so there a missing validator FAILS
# the test. On a machine without it the test is SKIPPED and says so: nothing about
# the schema is checked locally in that case.
_need_validator() {
  python3 -c 'import jsonschema' 2>/dev/null && return 0
  if [ -n "${CI:-}${GITHUB_ACTIONS:-}" ]; then
    echo "python jsonschema is not installed in CI: the schema contract cannot be checked" >&2
    return 1
  fi
  skip "python jsonschema is not installed: the snapshot schema contract is NOT checked here (CI checks it)"
}

# _validate <snapshot> — validate against the documented schema; prints "valid".
_validate() {
  python3 -c '
import json, sys, jsonschema
jsonschema.validate(json.load(open(sys.argv[1])), json.load(open(sys.argv[2])))
print("valid")' "$1" "$ROOT/scripts/lib/gemini-tier-snapshot.schema.json"
}

@test "schema: the snapshot the tier report writes WITH a collection report validates" {
  _need_validator
  _tier_report "$_complete"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.collection | keys | length' "$SNAP")" = "12" ]
  run _validate "$SNAP"
  [ "$status" -eq 0 ]
  [ "$output" = "valid" ]
  _tier_report "$(jq -c '.run_lookups_failed = 3 | .record_files_malformed = 1 | .gemini_records_unlisted = 2' <<< "$_complete")"
  run _validate "$SNAP"
  [ "$status" -eq 0 ]
  [ "$output" = "valid" ]
}

@test "schema: the snapshot the tier report writes WITHOUT a collection report validates" {
  _need_validator
  _tier_report ""
  [ "$status" -eq 0 ]
  [ "$(jq -r '.collection.records' "$SNAP")" = "unverified" ]
  run _validate "$SNAP"
  [ "$status" -eq 0 ]
  [ "$output" = "valid" ]
}

@test "schema: a collection block with an unknown field, or without a required one, is rejected" {
  _need_validator
  _tier_report "$_complete"
  jq -c '.collection.surprise = 1' "$SNAP" > "$BATS_TEST_TMPDIR/extra.json"
  run _validate "$BATS_TEST_TMPDIR/extra.json"
  [ "$status" -ne 0 ]
  jq -c 'del(.collection.run_lookups_failed)' "$SNAP" > "$BATS_TEST_TMPDIR/short.json"
  run _validate "$BATS_TEST_TMPDIR/short.json"
  [ "$status" -ne 0 ]
}

@test "snapshot: a write that fails leaves no snapshot and no working file to be cached or uploaded" {
  # jq fails exactly where the collection block is merged into the snapshot.
  local real_jq; real_jq="$(command -v jq)"
  mkdir -p "$BATS_TEST_TMPDIR/jqbin"
  cat > "$BATS_TEST_TMPDIR/jqbin/jq" <<STUB
#!/usr/bin/env bash
case "\$*" in *'collection: \$c'*) exit 5 ;; esac
exec "$real_jq" "\$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/jqbin/jq"
  _tier_report "$_complete"
  [ "$status" -eq 0 ]
  [ -s "$SNAP" ]
  [ -z "$(find "$BATS_TEST_TMPDIR/state" -name '*.tmp*')" ]
  PATH="$BATS_TEST_TMPDIR/jqbin:$PATH" _tier_report "$_complete"
  [ "$status" -ne 0 ]
  [ ! -e "$SNAP" ]
  [ -z "$(find "$BATS_TEST_TMPDIR/state" -name '*.tmp*')" ]
}

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------

@test "wiring: the fleet monitor hands the collection report from the token report to the tier report" {
  run grep -c 'GEMINI_COLLECTION_OUT: \${{ runner.temp }}/gemini-collection.json' "$FLEET_MONITOR"
  [ "$output" = "1" ]
  run grep -c 'GEMINI_COLLECTION_IN: \${{ runner.temp }}/gemini-collection.json' "$FLEET_MONITOR"
  [ "$output" = "1" ]
}

@test "wiring: the history store cache was renamed, so no record collected before the filter survives" {
  run grep -c 'gemini-tier-history-v2-' "$FLEET_MONITOR"
  [ "$output" = "3" ]
  run grep -c 'gemini-tier-history-\${{' "$FLEET_MONITOR"
  [ "$output" = "0" ]
}
