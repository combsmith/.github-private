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
  export ORG=petry-projects LOOKBACK_DAYS=7 COLLECT_CONCURRENCY=2 ARTIFACT_OP_TIMEOUT=0
  printf 'petry-projects/test-repo:main\n' > "$FIX/repos.txt"
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
  _zip 103 "$(_gemini a103 '{"provenance":{"run_id":9001,"trusted":true,"basis":"default-branch"},"trusted":true,"run_id":"9001","repo":"petry-projects/other"}')"
  _listing "$(_artifact 103 9003 1 2 feature/x)"
  _collect
  [ "$(_stamp a103)" = "false not-this-repository 9003" ]
  [ "$(cat "$OUT"/*.jsonl | jq -r '.repo')" = "petry-projects/test-repo" ]
}

@test "trust: a branch run that cannot be looked up is not trusted" {
  _zip 104 "$(_gemini a104)"
  _listing "$(_artifact 104 9004 1 1 feature/y)"
  _collect
  [ "$(_stamp a104)" = "false run-not-verified 9004" ]
  [ "$(cat "$FIX/lookups.log")" = "9004" ]
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
  [ "$(_stamp a106)" = "false not-this-repository null" ]
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
  printf 'petry-projects/test-repo\n' > "$FIX/repos.txt"
  _zip 101 "$(_gemini a101)"
  _zip 111 "$(_gemini a111)"
  _listing "$(_artifact 101 9001 1 1 main)" "$(_artifact 111 9011 1 1 main)"
  _run 9001 1 1 don-petry
  _collect
  [ "$(_stamp a101)" = "true same-repository-run 9001" ]
  [ "$(_stamp a111)" = "false run-not-verified 9011" ]
}

@test "trust: a caller that passes no origin (canary_report.sh) still collects, stamped untrusted" {
  _zip 120 "$(_gemini a120)"
  # shellcheck source=scripts/token_report.sh
  source "$TOKEN_REPORT"
  export COLLECT_JSONL_DIR="$OUT" COLLECT_WORKDIR="$BATS_TEST_TMPDIR/work" COLLECT_MARKER_DIR="$BATS_TEST_TMPDIR/work/markers"
  mkdir -p "$COLLECT_MARKER_DIR"
  _collect_one_artifact petry-projects/test-repo 120
  [ -f "$COLLECT_MARKER_DIR/120" ]
  [ "$(_stamp a120)" = "false not-this-repository null" ]
}

# ---------------------------------------------------------------------------
# The hand-off to the tier report
# ---------------------------------------------------------------------------

# _mixed_fixture — one trusted default-branch artifact, one trusted branch run, one
# fork artifact that forges 30 rejected attempts, one unverifiable branch run.
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

_complete='{"collected_at":"2026-10-10T11:59:00Z","collected_epoch":1791633540,"handed_over":true,"artifacts_listed":4,"repo_listings_failed":0,"artifacts_failed":0,"gemini_records_trusted":2,"gemini_records_ignored":31,"artifacts_ignored":2,"gemini_records_unlisted":0}'

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
