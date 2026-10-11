#!/usr/bin/env bats
# The bats suites never write to a token ledger they inherited (#2304).
#
# A suite started with TOKEN_LOG_FILE exported — the dev-lead job exports it, and
# the agent session ran these suites — appended its fixture calls, rejections and
# cooldowns to the run's real ledger. setup_suite.bash drops the variable before
# any test file starts; these tests keep that true for every directory.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"

setup() {
  AMBIENT_DIR="$BATS_TEST_TMPDIR/ambient"
  mkdir -p "$AMBIENT_DIR" "$BATS_TEST_TMPDIR/home"
  cd "$SCRIPT_DIR"
}

# _fresh_bats <bats args...> — a new bats run started the way a session inside
# the dev-lead job starts one: the ledger variables exported, and none of THIS
# run's bats or suite-guard state.
_fresh_bats() {
  # bats puts its own libexec directory first on PATH, where `bats` is the
  # internal entry point rather than the launcher; start from the launcher.
  local path=":$PATH:"
  path="${path//":${BATS_LIBEXEC:-}:"/:}"
  path="${path#:}"
  env -i PATH="${path%:}" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR" \
    TOKEN_LOG_FILE="$AMBIENT_DIR/ledger.jsonl" \
    GEMINI_LEDGER_FILE="$AMBIENT_DIR/gemini-ledger.jsonl" \
    _ENGINE_USAGE_OUT="$AMBIENT_DIR/usage" \
    TOKEN_WORKFLOW=dev-lead \
    bats "$@"
}

# Every planned test ran (so the check below is not vacuous), and nothing — no
# record, no usage sidecar, no lock — was written beside the inherited ledger.
_assert_ran_and_ledger_untouched() {
  local planned ran
  planned="$(printf '%s\n' "$output" | sed -n 's/^1\.\.\([0-9][0-9]*\)$/\1/p' | head -1)"
  ran="$(printf '%s\n' "$output" | grep -cE '^(ok|not ok) ' || true)"
  [ "${planned:-0}" -gt 0 ]
  [ "$ran" -eq "$planned" ]
  [ -z "$(ls -A "$AMBIENT_DIR")" ]
}

@test "ledger isolation: every directory of bats files has suite hooks that drop an inherited ledger" {
  # A test that would write to any ledger it can see.
  cat > "$BATS_TEST_TMPDIR/probe.bats" <<PROBE
@test "probe: no ledger variable is visible, and the writers write nothing" {
  [ -z "\${TOKEN_LOG_FILE+x}\${GEMINI_LEDGER_FILE+x}\${_ENGINE_USAGE_OUT+x}" ]
  source "$SCRIPT_DIR/scripts/lib/token-metrics.sh"
  source "$SCRIPT_DIR/scripts/lib/gemini-quota.sh"
  emit_token_record fixture triage gemini gemini-fixture-model 1 0 1 fixture
  gq_record_attempt 1 gemini-fixture-model
  gq_record_cooldown 1 gemini-fixture-model 60 fixture
}
PROBE
  local dir dirs=0
  while IFS= read -r dir; do
    dirs=$((dirs + 1))
    [ -f "$dir/setup_suite.bash" ] || { echo "no setup_suite.bash in $dir"; return 1; }
    run _fresh_bats --setup-suite-file "$dir/setup_suite.bash" "$BATS_TEST_TMPDIR/probe.bats"
    echo "$dir: $output"
    [ "$status" -eq 0 ]
    _assert_ran_and_ledger_untouched
  done < <(find tests -type f -name '*.bats' -exec dirname {} \; | sort -u)
  [ "$dirs" -ge 3 ]
}

# One real engine suite that wrote records and sidecar files to an inherited
# ledger before #2304. One is enough: the isolation is suite-wide (the hook
# above), so more suites would add minutes to this job and no coverage.
@test "ledger isolation: a real engine suite leaves an inherited ledger untouched" {
  local -a suites=(
    tests/dev-lead/unit/test_engine_gemini_35.bats
  )
  run _fresh_bats "${suites[@]}"
  echo "$output"
  _assert_ran_and_ledger_untouched
}

@test "ledger isolation: suites outside the unit directory leave an inherited ledger untouched" {
  local -a suites=(
    tests/test_opus_5_5_validation.bats
    tests/test_model_ab_dispatch.bats
    tests/test_review_one_pr_carry_forward.bats
  )
  run _fresh_bats "${suites[@]}"
  echo "$output"
  _assert_ran_and_ledger_untouched
}
