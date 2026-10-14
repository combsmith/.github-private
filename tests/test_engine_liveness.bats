#!/usr/bin/env bats
# Integration tests for the engine-token liveness WRAPPER
# (scripts/engine_liveness.sh, issue #1605).
#
# #1605: under `set -euo pipefail`, the PAT audit extracted the credential's
# scopes with `pat_scopes_seen=$(… | grep -im1 '^x-oauth-scopes:' | …)`. When the
# response carries no `x-oauth-scopes` header — the normal case for a fine-grained
# PAT or a GitHub App token — `grep` exits 1, `pipefail` propagates it, the
# command-substitution assignment exits 1, and `errexit` KILLS the script. That
# abort happens BEFORE section 4, so the report, the `GITHUB_ENV` flags, and the
# fleet-alert body were never written: the fleet-outage alert could never fire and
# the run's exit code contradicted its own Should-fail decision (`Should-fail:
# false` yet exit 1). An absent header is a classification INPUT, not a fatal error.
#
# These tests drive the wrapper end-to-end with a `gh` PATH stub so both defects
# are exercised the way the issue demands — "verify by running", not by reading
# the diff:
#   - a `gh api -i user` response with NO x-oauth-scopes/expiry header must let the
#     script COMPLETE (report + GITHUB_ENV flags written), classifying scope as
#     UNKNOWN / `<none/fine-grained>` rather than aborting;
#   - the workflow-run exit status must equal ENGINE_LIVENESS_SHOULD_FAIL: 0
#     sustained outages -> green; a sustained outage in >=2 repos -> red AND the
#     FLEET alert body actually produced.
#
# Run with: bats tests/test_engine_liveness.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/engine_liveness.sh"

  # BATS_TEST_TMPDIR is created fresh per test and cleaned up afterwards.
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  export PATH="$STUB_DIR:$PATH"
  export GH_CALL_LOG="$BATS_TEST_TMPDIR/gh_calls.log"
  : > "$GH_CALL_LOG"

  # Pin "now" so the recency math (#1600 lookback window) and the report date are
  # deterministic regardless of the wall clock: without this, the suite would start
  # failing by calendar once real time passes the hardcoded run/expiry timestamps
  # below. The stub fixes only the two "now" reads the wrapper makes (`date -u +%s`
  # and `date -u +%Y-%m-%d`) and delegates every other invocation — notably the
  # detector's ISO→epoch `date -u -d …` conversions — to the real binary.
  # 1800000000 == 2027-01-15T08:00:00Z.
  export REAL_DATE
  REAL_DATE="$(command -v date)"
  cat > "$STUB_DIR/date" << 'DATEEOF'
#!/usr/bin/env bash
if [ "$1" = "-u" ] && [ "$2" = "+%s" ]; then
  echo "1800000000"      # 2027-01-15T08:00:00Z
elif [ "$1" = "-u" ] && [ "$2" = "+%Y-%m-%d" ]; then
  echo "2027-01-15"
else
  exec "$REAL_DATE" "$@"
fi
DATEEOF
  chmod +x "$STUB_DIR/date"

  # Wrapper side-effect sinks — kept out of the repo working tree.
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  : > "$GITHUB_ENV"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/step_summary"
  export REPORT_FILE="$BATS_TEST_TMPDIR/report.md"
  export ALERT_BODY_FILE="$BATS_TEST_TMPDIR/alert.md"

  # Drive the repo/stub set explicitly so no consumer manifest or network is
  # needed. Two repos so a fleet-wide (>=2 repos) outage is expressible.
  export ENGINE_LIVENESS_REPOS="petry-projects/repo-a petry-projects/repo-b"
  export ENGINE_LIVENESS_STUBS="dev-lead.yml"
  export GH_TOKEN="dummy-token-for-stub"
}

# env_val <NAME> — echo the value written for NAME in the wrapper's GITHUB_ENV.
env_val() {
  grep -m1 "^$1=" "$GITHUB_ENV" | cut -d= -f2-
}

# _fail_gate_if <workflow_yml> — echo the `if:` expression of the step whose run
# body contains `exit 1` (the run's fail-gate). Empty when no such step exists, so
# a removed/renamed gate is DETECTABLE rather than silently assumed present.
_fail_gate_if() {
  awk '
    function flush() { if (cur_if != "" && cur_exit) print cur_if }
    /^      - / { flush(); cur_if=""; cur_exit=0 }
    /^        if:/ { line=$0; sub(/^ *if:[ ]*/, "", line); cur_if=line }
    /exit 1/ { cur_exit=1 }
    END { flush() }
  ' "$1"
}

# workflow_run_outcome — derive the run's red/green from the ACTUAL workflow's
# fail-gate, NOT a hand-copied condition (#1606 review, codeant): a duplicated
# inline condition passes even when the real gate is deleted or reordered. This
# reads the fail step's `if:` straight out of engine-token-liveness.yml, requires
# that gate to be an always() guard on an `env.<NAME> == '<value>'` comparison,
# then evaluates THAT parsed comparison against what the wrapper wrote to
# GITHUB_ENV — returning 1 (run red) when it holds, 0 (green) otherwise. If the
# gate step is removed, no longer wraps an `exit 1` body, loses always(), or stops
# comparing an env var, the parse fails (return 2) and the asserting test fails.
workflow_run_outcome() {
  local wf gate var want
  wf="$REPO_ROOT/.github/workflows/engine-token-liveness.yml"
  [ -f "$wf" ] || return 2
  gate=$(_fail_gate_if "$wf")
  [ -n "$gate" ] || return 2
  case "$gate" in *"always()"*) : ;; *) return 2 ;; esac
  [[ "$gate" =~ env\.([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*==[[:space:]]*\'([^\']*)\' ]] || return 2
  var="${BASH_REMATCH[1]}"
  want="${BASH_REMATCH[2]}"
  [ "$(env_val "$var")" = "$want" ] && return 1
  return 0
}

# make_gh_stub — install a `gh` shim on PATH. Behaviour is env-driven:
#   GH_STUB_PREFLIGHT      failure|success (the "Engine token preflight" step's
#                          conclusion for every inspected run; default success)
#   GH_STUB_EMIT_SCOPES    1 to emit an `x-oauth-scopes` header (classic PAT);
#                          unset/0 omits it (fine-grained PAT / App token — #1605)
#   GH_STUB_EMIT_EXPIRY    1 to emit a `github-authentication-token-expiration`
#                          header; unset/0 omits it.
# The stub emits POST-`--jq` output directly (the script always passes `--jq`),
# matching the repo's other gh-stub tests.
make_gh_stub() {
  cat > "$STUB_DIR/gh" << 'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
[ "$1" = "api" ] || exit 0
shift

resource=""
for a in "$@"; do
  case "$a" in
    -i|--paginate|--jq|-H|--hostname) : ;;   # flags (value-taking flags handled below)
    -*) : ;;                                  # any other flag
    user) resource="user" ;;
    repos/*) resource="$a" ;;
    *) : ;;                                   # jq expression / flag values — ignore
  esac
done

case "$resource" in
  user)
    # Identity response WITH headers (`gh api -i user`). A fine-grained PAT / App
    # token omits x-oauth-scopes entirely — that omission is the #1605 trigger.
    printf 'HTTP/2.0 200 OK\r\n'
    printf 'Server: GitHub.com\r\n'
    if [ "${GH_STUB_EMIT_SCOPES:-0}" = "1" ]; then
      printf 'x-oauth-scopes: repo, workflow\r\n'
    fi
    if [ "${GH_STUB_EMIT_EXPIRY:-0}" = "1" ]; then
      printf 'github-authentication-token-expiration: 2027-12-31 00:00:00 UTC\r\n'
    fi
    printf '\r\n'
    printf '{"login":"don-petry"}\n'
    ;;
  */actions/workflows/*/runs*)
    # Two most-recent COMPLETED runs, both RECENT (inside the default 3-day
    # lookback relative to the stubbed now 2027-01-15T08:00:00Z), post-jq form:
    # "<id>\t<run_started_at_iso>". Hardcoded ISO literals — no GNU-only
    # `date -u -d` — so the stub is portable (GNU/BSD) and fully deterministic.
    printf '111\t2027-01-15T07:00:00Z\n'   # 1 hour before now
    printf '222\t2027-01-15T02:00:00Z\n'   # 6 hours before now
    ;;
  */actions/runs/*/jobs)
    # Per-run job steps, post-jq form: "<step_name>\t<conclusion>".
    printf 'Checkout agent repo\tsuccess\n'
    printf 'Engine token preflight\t%s\n' "${GH_STUB_PREFLIGHT:-success}"
    ;;
  *)
    exit 0
    ;;
esac
STUBEOF
  chmod +x "$STUB_DIR/gh"
}

# ---------------------------------------------------------------------------
# #1605 root cause — an absent x-oauth-scopes / expiry header must be a
# classification input, not a fatal abort.
# ---------------------------------------------------------------------------

@test "no x-oauth-scopes header: script COMPLETES, writes report + GITHUB_ENV flags (not an abort) (#1605)" {
  export GH_STUB_PREFLIGHT=success
  export GH_STUB_EMIT_SCOPES=0   # fine-grained PAT / App token — no scopes header
  export GH_STUB_EMIT_EXPIRY=0   # …and no expiry header either
  make_gh_stub

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  # The report exists and got past the PAT-audit line that used to abort.
  [ -s "$REPORT_FILE" ]
  grep -q 'Engine-Token Liveness' "$REPORT_FILE"
  grep -q 'monitor complete' <<< "$output"

  # The GITHUB_ENV flags the alert/fail steps gate on were written.
  grep -q '^ENGINE_LIVENESS_ESCALATION='   "$GITHUB_ENV"
  grep -q '^ENGINE_LIVENESS_SHOULD_FAIL='   "$GITHUB_ENV"
  grep -q '^ENGINE_LIVENESS_PAT_SCOPE_STATE='  "$GITHUB_ENV"
  grep -q '^ENGINE_LIVENESS_PAT_EXPIRY_STATE=' "$GITHUB_ENV"

  # An absent header is classified, not fatal: UNKNOWN scope / NO_EXPIRY, and the
  # report shows the designed <none/fine-grained> placeholder.
  [ "$(env_val ENGINE_LIVENESS_PAT_SCOPE_STATE)" = "UNKNOWN" ]
  [ "$(env_val ENGINE_LIVENESS_PAT_EXPIRY_STATE)" = "NO_EXPIRY" ]
  grep -q 'none/fine-grained' "$REPORT_FILE"
}

@test "classic PAT WITH scopes header still classifies OK (no regression) (#1605)" {
  export GH_STUB_PREFLIGHT=success
  export GH_STUB_EMIT_SCOPES=1
  export GH_STUB_EMIT_EXPIRY=1
  make_gh_stub

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(env_val ENGINE_LIVENESS_PAT_SCOPE_STATE)" = "OK" ]
  [ "$(env_val ENGINE_LIVENESS_PAT_EXPIRY_STATE)" = "OK" ]
}

# ---------------------------------------------------------------------------
# #1605 — the run's exit status must equal ENGINE_LIVENESS_SHOULD_FAIL.
# ---------------------------------------------------------------------------

@test "0 sustained outages: exits 0, SHOULD_FAIL=false, escalation NONE; run stays green (#1605)" {
  export GH_STUB_PREFLIGHT=success   # every inspected run passes preflight
  make_gh_stub

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(env_val ENGINE_LIVENESS_SHOULD_FAIL)" = "false" ]
  [ "$(env_val ENGINE_LIVENESS_ESCALATION)" = "NONE" ]
  [ "$(env_val ENGINE_LIVENESS_SUSTAINED_REPOS)" = "0" ]

  # Run exit status == SHOULD_FAIL: false -> green.
  run workflow_run_outcome
  [ "$status" -eq 0 ]

  # No fleet-alert body was produced for an all-clear.
  [ ! -s "$ALERT_BODY_FILE" ] || ! grep -q 'FLEET-WIDE' "$ALERT_BODY_FILE"
}

@test ">=2 repos in sustained outage: FLEET escalation, alert body produced, SHOULD_FAIL=true; run goes red (#1605)" {
  export GH_STUB_PREFLIGHT=failure   # both repos: 2 recent preflight failures each
  make_gh_stub

  run bash "$SCRIPT"
  # The wrapper itself still exits 0 so the workflow's alert step (which lacks
  # always()) remains reachable; the always() fail-step owns the red/green.
  [ "$status" -eq 0 ]

  [ "$(env_val ENGINE_LIVENESS_ESCALATION)" = "FLEET" ]
  [ "$(env_val ENGINE_LIVENESS_SHOULD_FAIL)" = "true" ]
  [ "$(env_val ENGINE_LIVENESS_SUSTAINED_REPOS)" = "2" ]

  # The fleet-alert body — never once produced before this fix — now exists.
  [ -s "$ALERT_BODY_FILE" ]
  grep -qi 'FLEET-WIDE ENGINE-TOKEN OUTAGE' "$ALERT_BODY_FILE"

  # Run exit status == SHOULD_FAIL: true -> red.
  run workflow_run_outcome
  [ "$status" -eq 1 ]
}
