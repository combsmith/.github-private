#!/usr/bin/env bats
# Unit tests for scripts/dev-lead-resume.sh — the event-first resume bridge
# (#1407). On a clearing event (a review submitted or a check_run success), a
# blocked/rate-limited dev-lead state is re-dispatched IMMEDIATELY via PAT
# repository_dispatch instead of waiting for the dev-lead-retry.yml safety-net
# cron. The resume reuses scan_pr_for_rate_limits from dev-lead-retry.sh so the
# dispatch + every stop condition (human markers, per-PR automation budget,
# reset window, terminal markers) is identical to the cron path.
#
# resume_main is guarded behind a BASH_SOURCE check so sourcing the script here
# exposes it without resolving a real event.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
RESUME_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-resume.sh"

setup() {
  MOCK_BIN="$BATS_TEST_TMPDIR"
  export PATH="$MOCK_BIN:$PATH"

  export DRY_RUN="true"
  export NOW_ISO="2026-08-08T00:00:00Z"
  export HEAD_SHA="abc123def456"
  # A fix-ci rate-limited marker on the current head with a reset already in the
  # past → eligible to resume (so a suppress is the only thing that stops it).
  export COMMENTS_JSON
  COMMENTS_JSON="$(jq -nc --arg s "$HEAD_SHA" \
    '["<!-- dev-lead-fix-ci sha=\($s) status=rate-limited reset=2020-01-01T00:00:00Z check=CI failure -->"]')"
  export LABELS_JSON='[]'
  # gather_pr_automation_events pulls commits/reviews for the budget check;
  # default to empty so the budget is not exhausted unless a test says so.
  export COMMITS_JSON='[]'

  export PAYLOAD_FILE="$MOCK_BIN/payload.json"
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *dispatches*)          cat > "${PAYLOAD_FILE:-/dev/null}"; exit 0 ;;
  *pulls/*/commits*)     printf '%s' "${COMMITS_JSON}" ;;
  *pulls/*/reviews*)     printf '%s' '[]' ;;
  *issues/*/comments*)   printf '%s' "${COMMENTS_JSON}" ;;
  *check-runs*)          printf '%s' '{"id":"","details_url":""}' ;;
  *pulls/*)              jq -nc --arg s "${HEAD_SHA}" --argjson l "${LABELS_JSON}" \
                           --arg state "${PR_STATE:-open}" \
                           '{head:{sha:$s}, labels:($l | map({name:.})), state:$state}' ;;
  *)                     echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"

  export REPO="petry-projects/demo"
  export PR_NUMBER="860"

  source "$RESUME_SCRIPT"
}

teardown() {
  :
}

# ── (a) a clearing event resumes a pending rate-limited state ──────────────────
@test "resume: clearing event with a pending rate-limited marker dispatches a resume" {
  run resume_main

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-ci-failure"* ]]
}

# ── (b) an exhausted budget suppresses the resume ─────────────────────────────
@test "resume: exhausted per-PR automation budget suppresses the resume" {
  # 10 bot commits since the last human interaction → budget exhausted (#926).
  COMMITS_JSON="$(jq -nc '[range(10) | {commit:{author:{date:"2026-08-08T00:00:00Z"}}, author:{login:"donpetry-bot"}}]')"

  run resume_main

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
}

# ── (c) a human stop marker suppresses the resume ─────────────────────────────
@test "resume: needs-human-review marker suppresses the resume" {
  LABELS_JSON='["needs-human-review"]'

  run resume_main

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
}

# ── (d) no pending blocked state → nothing to resume ──────────────────────────
@test "resume: no rate-limited marker → no dispatch" {
  COMMENTS_JSON='["just a normal human comment"]'

  run resume_main

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
}

# ── (e) clearing event for a closed PR → no dispatch ──────────────────────────
@test "resume: closed PR suppresses the resume" {
  export PR_STATE="closed"

  run resume_main

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
}

# ── unresolved PR (event carried no PR) → clean no-op ─────────────────────────
@test "resume: empty PR_NUMBER is a clean no-op" {
  PR_NUMBER=""

  run resume_main

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
  [[ "$output" == *"nothing to resume"* ]]
}
