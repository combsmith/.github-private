#!/usr/bin/env bats
# Per-target payload-field gate for the dev-lead retry sweep (#2086).
#
# The sweep runs one release of scripts/ (the channel this repo's dev-lead.yml
# pins, #2050) but sends repository_dispatch events to every repo in the org, and
# each target parses them with dev-lead-intent.sh at ITS OWN dev-lead.yml pin. A
# payload carrying a client_payload field that parser does not read must be held
# back; a payload of fields every release reads must still reach older-pinned
# repos (the fleet sits on stable). These tests pin:
#   • agent_ref parsing (any plain ref; the reusable's default `main` when absent);
#   • pin reads: found / no stub (404 on a readable repo) / unreadable repo /
#     read error / unresolvable, cached;
#   • the fields a ref's parser reads: parser + libs it names, comments ignored,
#     an unreadable file fails closed, cached, ref URL-encoded;
#   • the decision: gate off without SWEEP_AGENT_REF, same pin skips the lookup,
#     a missing field holds with one warning naming it, informational fields ignored;
#   • every dispatcher is gated, and BOT_COMMENT_RETRY_FIELDS matches its payload;
#   • main(): every repo is still scanned; an invalid SWEEP_AGENT_REF is an error.
#
# Run: bats tests/dev-lead/unit/test_dispatch_channel_gate.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
RETRY_SCRIPT="$REPO_ROOT/scripts/dev-lead-retry.sh"

# The v1 parser reads every field except comment_node_id (the #2050 skew).
V1_FIELDS=(pr_number issue_number head_sha checks intent_type)

setup() {
  MOCK_BIN="$(mktemp -d)"
  export MOCK_BIN
  export PATH="$MOCK_BIN:$PATH"
  mkdir -p "$MOCK_BIN/stubs" "$MOCK_BIN/src" "$MOCK_BIN/unreadable"
  : >"$MOCK_BIN/calls"
  export DRY_RUN="false"
  export DISPATCH_DELAY_SEC="0"
  export TARGET_ORG="petry-projects"
  export DCG_HOST_REPO="petry-projects/.github-private"
  unset SWEEP_AGENT_REF DELEGATION_ORGS GITHUB_REPOSITORY
  # The per-sweep cache dcg_init would make.
  export DCG_CACHE_DIR="$BATS_TEST_TMPDIR/dcg"
  mkdir -p "$DCG_CACHE_DIR"

  # gh stub. Every call is logged to $MOCK_BIN/calls; an unexpected call fails
  # loudly (exit 97) so a test never passes on a silent default.
  #   repos/<host>/contents/<path>?ref=<enc-ref>
  #       -> $MOCK_BIN/src/<enc-ref>/<path, / as __>; missing -> HTTP 404
  #   repos/<owner>/<name>/contents/.github/workflows/dev-lead.yml
  #       -> $MOCK_BIN/stubs/<owner>__<name>; missing -> HTTP 404;
  #          a file containing exactly ERROR -> HTTP 502
  #   repos/<owner>/<name> --jq .full_name -> readable, unless
  #       $MOCK_BIN/unreadable/<owner>__<name> exists (HTTP 404)
  #   repos/<repo>/dispatches -> body appended to $MOCK_BIN/dispatched
  #   repo list -> $REPO_LIST_JSON
  cat >"$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_BIN/calls"
args="$*"
case "$args" in
  "repo list"*) printf '%s' "${REPO_LIST_JSON:-[]}"; exit 0 ;;
  *"/dispatches"*) cat >>"$MOCK_BIN/dispatched"; echo >>"$MOCK_BIN/dispatched"; exit 0 ;;
  *"contents/"*"?ref="*)
    p="${args#*/contents/}"; p="${p%% *}"
    ref="${p#*\?ref=}"; path="${p%%\?ref=*}"
    f="$MOCK_BIN/src/${ref}/${path//\//__}"
    if [ ! -f "$f" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    cat "$f"; exit 0 ;;
  *contents/.github/workflows/dev-lead.yml*)
    repo="${args#*repos/}"; repo="${repo%%/contents/*}"
    f="$MOCK_BIN/stubs/${repo//\//__}"
    if [ ! -f "$f" ]; then
      printf '{"message":"Not Found","status":"404"}'
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    if [ "$(cat "$f")" = "ERROR" ]; then
      echo "gh: Bad Gateway (HTTP 502)" >&2
      exit 1
    fi
    cat "$f"; exit 0 ;;
  "api repos/"*" --jq .full_name")
    repo="${args#api repos/}"; repo="${repo%% *}"
    if [ -f "$MOCK_BIN/unreadable/${repo//\//__}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    echo "$repo"; exit 0 ;;
  *) echo "mock gh: unexpected call: $args" >&2; exit 97 ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"

  # shellcheck disable=SC1090
  source "$RETRY_SCRIPT"
}

teardown() {
  rm -rf "$MOCK_BIN"
}

# _pin <owner/name> <agent_ref>: give a repo a dev-lead.yml caller stub.
_pin() {
  cat >"$MOCK_BIN/stubs/${1//\//__}" <<EOF
jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@$2  # NOSONAR
    with:
      agent_ref: $2
EOF
}

# _parser <ref> <field>...: the host repo's dev-lead-intent.sh at <ref> reads
# <field>s — the last one through a lib it sources.
_parser() {
  local ref="$1" enc; shift
  enc="$(jq -rn --arg r "$ref" '$r | @uri')"
  mkdir -p "$MOCK_BIN/src/$enc"
  local f last="" body=""
  for f in "$@"; do last="$f"; done
  for f in "$@"; do
    [ "$f" = "$last" ] && continue
    body+="  ${f}=\$(jq -r '.client_payload.${f} // empty' \"\$EVENT_PATH\")"$'\n'
  done
  {
    echo '#!/usr/bin/env bash'
    echo '# .client_payload.comment_node_id is named only in this comment'
    echo 'source "$(dirname "$0")/lib/helper.sh"'
    echo 'parse() {'
    printf '%s' "$body"
    echo '}'
  } >"$MOCK_BIN/src/$enc/scripts__dev-lead-intent.sh"
  printf 'helper() { jq -r %s; }\n' "'.client_payload.${last} // empty'" \
    >"$MOCK_BIN/src/$enc/scripts__lib__helper.sh"
}

_calls() { grep -c -- "$1" "$MOCK_BIN/calls" || true; }

# ── dcg_parse_agent_ref ──────────────────────────────────────────────────────

@test "parse: returns the agent_ref of a caller stub" {
  local ch out
  for ch in dev-lead/v139-stable dev-lead/v1-next dev-lead/v7-ring0 main 4fd4eac; do
    _pin o/r "$ch"
    out="$(dcg_parse_agent_ref <"$MOCK_BIN/stubs/o__r")"
    [ "$out" = "$ch" ]
  done
}

@test "parse: accepts a quoted agent_ref with a trailing comment" {
  out="$(printf '    with:\n      agent_ref: "dev-lead/v139-ring1"  # pin\n' | dcg_parse_agent_ref)"
  [ "$out" = "dev-lead/v139-ring1" ]
}

@test "parse: no agent_ref → the reusable's default, main" {
  out="$(printf 'jobs:\n  dev-lead:\n    uses: o/r/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-stable\n' | dcg_parse_agent_ref)"
  [ "$out" = "main" ]
}

@test "parse: reads this repo's live dev-lead.yml stub" {
  run dcg_parse_agent_ref <"$REPO_ROOT/.github/workflows/dev-lead.yml"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^dev-lead/v[0-9]+-(next|ring0|ring1|stable)$ ]]
}

@test "parse: rejects an empty or non-literal agent_ref" {
  local bad
  for bad in '' '${{ inputs.ref }}' '../../x' '-x'; do
    run dcg_parse_agent_ref <<<"      agent_ref: $bad"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}

# ── dcg_target_pin ───────────────────────────────────────────────────────────

@test "pin: returns the repo's agent_ref, read once per sweep" {
  _pin petry-projects/markets dev-lead/v139-ring1
  run dcg_target_pin petry-projects/markets
  [ "$status" -eq 0 ]
  [ "$output" = "dev-lead/v139-ring1" ]
  dcg_target_pin petry-projects/markets >/dev/null
  [ "$(dcg_target_pin petry-projects/markets)" = "dev-lead/v139-ring1" ]
  [ "$(_calls 'repos/petry-projects/markets/contents')" -eq 1 ]
}

@test "pin: a 404 from a repo the token cannot read is unreadable (1), not absent" {
  touch "$MOCK_BIN/unreadable/petry-projects__private"
  run dcg_target_pin petry-projects/private
  [ "$status" -eq 1 ]
  DCG_SWEEP_REF=dev-lead/v139-ring0
  run dcg_target_reads petry-projects/private pr_number
  [ "$status" -eq 1 ]
  [[ "$output" == *"::warning::"* ]]
}

@test "pin: no dev-lead.yml → 2; read error or unresolvable pin → 1" {
  run dcg_target_pin petry-projects/no-stub
  [ "$status" -eq 2 ]
  echo ERROR >"$MOCK_BIN/stubs/petry-projects__flaky"
  run dcg_target_pin petry-projects/flaky
  [ "$status" -eq 1 ]
  _pin petry-projects/expr '${{ inputs.ref }}'
  run dcg_target_pin petry-projects/expr
  [ "$status" -eq 1 ]
}

# ── dcg_fields_read_at ───────────────────────────────────────────────────────

@test "fields: the parser's reads plus its libs', not names in comments" {
  _parser dev-lead/v1-stable "${V1_FIELDS[@]}"
  run dcg_fields_read_at dev-lead/v1-stable
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "${V1_FIELDS[@]}" | sort -u)" ]
  # The ref is URL-encoded and read from the host repo.
  grep -q 'repos/petry-projects/.github-private/contents/scripts/lib/helper.sh?ref=dev-lead%2Fv1-stable' "$MOCK_BIN/calls"
}

@test "fields: a lib that cannot be read fails closed" {
  _parser dev-lead/v1-stable "${V1_FIELDS[@]}"
  rm "$MOCK_BIN/src/dev-lead%2Fv1-stable/scripts__lib__helper.sh"
  run dcg_fields_read_at dev-lead/v1-stable
  [ "$status" -eq 1 ]
}

@test "fields: cached per ref within a sweep" {
  _parser dev-lead/v1-stable "${V1_FIELDS[@]}"
  dcg_fields_read_at dev-lead/v1-stable >/dev/null
  dcg_fields_read_at dev-lead/v1-stable >/dev/null
  [ "$(_calls 'dev-lead-intent.sh?ref=')" -eq 1 ]
}

# ── dcg_init / dcg_target_reads ──────────────────────────────────────────────

@test "init: unset → gate off; a channel tag → on with a cache dir; anything else is an error" {
  dcg_init
  [ -z "$DCG_SWEEP_REF" ]
  DCG_CACHE_DIR=""
  SWEEP_AGENT_REF=dev-lead/v139-ring0 RUNNER_TEMP="$BATS_TEST_TMPDIR" dcg_init
  [ "$DCG_SWEEP_REF" = "dev-lead/v139-ring0" ]
  [ -d "$DCG_CACHE_DIR" ]
  [[ "$DCG_CACHE_DIR" == "$BATS_TEST_TMPDIR"/dcg.* ]]
  SWEEP_AGENT_REF=main run dcg_init
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
}

@test "reads: gate off → allowed with no API call" {
  run dcg_target_reads petry-projects/broodly comment_node_id
  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_BIN/calls" ]
}

@test "reads: pinned to the sweep's channel → allowed without reading its parser" {
  DCG_SWEEP_REF=dev-lead/v139-ring0
  _pin petry-projects/x dev-lead/v139-ring0
  run dcg_target_reads petry-projects/x comment_node_id
  [ "$status" -eq 0 ]
  [ "$(_calls 'dev-lead-intent.sh')" -eq 0 ]
}

@test "reads: an older pin whose parser reads every field → allowed" {
  DCG_SWEEP_REF=dev-lead/v139-ring0
  _pin petry-projects/broodly dev-lead/v1-stable
  _parser dev-lead/v1-stable "${V1_FIELDS[@]}"
  run dcg_target_reads petry-projects/broodly pr_number head_sha repo intent_type
  [ "$status" -eq 0 ]
  [[ "$output" != *"::warning::"* ]]
}

@test "reads: informational fields (repo, attempt) need no reader" {
  DCG_SWEEP_REF=dev-lead/v139-ring0
  _pin petry-projects/broodly dev-lead/v1-stable
  _parser dev-lead/v1-stable issue_number
  run dcg_target_reads petry-projects/broodly issue_number repo attempt
  [ "$status" -eq 0 ]
}

@test "reads: a field the pinned parser does not read → held, one warning naming it" {
  DCG_SWEEP_REF=dev-lead/v139-ring0
  _pin petry-projects/broodly dev-lead/v1-stable
  _parser dev-lead/v1-stable "${V1_FIELDS[@]}"
  local err="$BATS_TEST_TMPDIR/err" rc=0
  dcg_target_reads petry-projects/broodly pr_number comment_node_id 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  dcg_target_reads petry-projects/broodly pr_number comment_node_id 2>>"$err" || rc=$?
  [ "$(grep -c '::warning::' "$err")" -eq 1 ]
  grep -q '::warning::.*petry-projects/broodly.*dev-lead/v1-stable.*comment_node_id' "$err"
}

@test "reads: the cache survives the subshells the sweep calls it in" {
  DCG_SWEEP_REF=dev-lead/v139-ring0
  _pin petry-projects/broodly dev-lead/v1-stable
  _parser dev-lead/v1-stable "${V1_FIELDS[@]}"
  local i out
  for i in 1 2 3; do
    out="$(dcg_target_reads petry-projects/broodly pr_number comment_node_id 2>&1 || true)"
  done
  [ "$(_calls 'repos/petry-projects/broodly/contents')" -eq 1 ]
  [ "$(_calls 'dev-lead-intent.sh?ref=')" -eq 1 ]
  [ "$(_calls 'helper.sh?ref=')" -eq 1 ]
  # ...and so does warn-once: the later calls only log the hold.
  [[ "$out" != *"::warning::"* ]]
  [[ "$out" == *"[hold] petry-projects/broodly"* ]]
}

@test "reads: no dev-lead.yml → held without a warning" {
  DCG_SWEEP_REF=dev-lead/v139-ring0
  run dcg_target_reads petry-projects/no-stub pr_number
  [ "$status" -eq 1 ]
  [[ "$output" != *"::warning::"* ]]
}

@test "reads: unreadable pin or parser → held with a warning (fail closed)" {
  DCG_SWEEP_REF=dev-lead/v139-ring0
  echo ERROR >"$MOCK_BIN/stubs/petry-projects__flaky"
  run dcg_target_reads petry-projects/flaky pr_number
  [ "$status" -eq 1 ]
  [[ "$output" == *"::warning::"* ]]
  _pin petry-projects/old dev-lead/v1-ring1   # no parser source at that ref
  run dcg_target_reads petry-projects/old pr_number
  [ "$status" -eq 1 ]
  [[ "$output" == *"::warning::"* ]]
}

# ── dispatchers ──────────────────────────────────────────────────────────────

_v1_target() {
  DCG_SWEEP_REF=dev-lead/v139-ring0
  _pin petry-projects/broodly dev-lead/v1-stable
  _parser dev-lead/v1-stable "${V1_FIELDS[@]}"
}

@test "dispatch: a bot-comment retry is held from a target that drops comment_node_id" {
  _v1_target
  run dispatch_bot_comment_retry petry-projects/broodly 7 abc IC_x
  [ "$status" -eq 1 ]
  [ ! -s "$MOCK_BIN/dispatched" ]
}

@test "dispatch: reviews, CI and issue retries still reach a v1-pinned target" {
  _v1_target
  lookup_check_run_details() { echo '{"id":"","details_url":""}'; }
  dispatch_reviews_retry petry-projects/broodly 7 abc fix-reviews
  dispatch_ci_retry petry-projects/broodly 7 abc "CI"
  dispatch_issue_retry petry-projects/broodly 9 1
  [ "$(grep -c 'client_payload' "$MOCK_BIN/dispatched")" -eq 3 ]
}

@test "dispatch: every dispatcher in the sweep consults the gate" {
  local fn n=0
  for fn in $(declare -F | awk '{print $3}'); do
    # A sweep dispatcher POSTs its payload to the target's /dispatches.
    declare -f "$fn" | grep -qF 'POST "repos/${repo}/dispatches"' || continue
    n=$((n + 1))
    declare -f "$fn" | grep -q 'dcg_payload_allowed' || { echo "ungated: $fn"; return 1; }
  done
  [ "$n" -ge 4 ]
}

@test "BOT_COMMENT_RETRY_FIELDS matches dispatch_bot_comment_retry's payload" {
  dispatch_bot_comment_retry petry-projects/x 7 abc IC_x
  [ "$(jq -r '.client_payload | keys[]' "$MOCK_BIN/dispatched" | sort)" \
    = "$(printf '%s\n' "${BOT_COMMENT_RETRY_FIELDS[@]}" | sort)" ]
}

# ── main() wiring ────────────────────────────────────────────────────────────

@test "main: with the gate on, every repo is still scanned" {
  export REPO_LIST_JSON='["petry-projects/.github-private","petry-projects/broodly"]'
  scan_repo() { echo "SCANNED $1"; }
  SWEEP_AGENT_REF=dev-lead/v139-ring0 run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"sweep channel: dev-lead/v139-ring0"* ]]
  [[ "$output" == *"SCANNED petry-projects/.github-private"* ]]
  [[ "$output" == *"SCANNED petry-projects/broodly"* ]]
}

@test "main: SWEEP_AGENT_REF unset → gate off, logged" {
  export REPO_LIST_JSON='["petry-projects/a"]'
  scan_repo() { echo "SCANNED $1"; }
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate off"* ]]
  [[ "$output" == *"SCANNED petry-projects/a"* ]]
}

@test "main: an invalid SWEEP_AGENT_REF fails the sweep before any scan" {
  export REPO_LIST_JSON='["petry-projects/a"]'
  scan_repo() { echo "SCANNED $1"; }
  SWEEP_AGENT_REF='dev-lead/v139-canary' run main
  [ "$status" -ne 0 ]
  [[ "$output" != *"SCANNED"* ]]
}

@test "workflow: the run step passes the resolved channel as SWEEP_AGENT_REF" {
  grep -q 'SWEEP_AGENT_REF: \${{ steps.channel.outputs.agent_ref }}' \
    "$REPO_ROOT/.github/workflows/dev-lead-retry.yml"
}
