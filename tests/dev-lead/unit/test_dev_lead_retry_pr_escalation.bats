#!/usr/bin/env bats
# Unit tests for dev-lead-retry.sh — escalated-PR skip in scan_pr_for_rate_limits
# (issue #946: retry crons must skip escalated/needs-human PRs before re-dispatching).
#
# A PR that hit the per-PR automation budget (#928) carries the
# needs-human-review label. The retry cron must NOT re-dispatch it (that re-ignites
# exactly the runaway the breaker stops — the #860 "amplifier" failure mode). A
# human removing the label re-enables the retry path (AC3).
#
# The script guards `main "$@"` behind a BASH_SOURCE check, so sourcing it here
# exposes scan_pr_for_rate_limits without running the org-wide scan.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
RETRY_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-retry.sh"

setup() {
  MOCK_BIN="$BATS_TEST_TMPDIR"
  export PATH="$MOCK_BIN:$PATH"

  export DRY_RUN="true"
  export NOW_ISO="2026-06-19T00:00:00Z"
  export HEAD_SHA="abc123def456"
  # A fix-ci rate-limited marker on the current head with a reset already in the
  # past → would normally be re-dispatched (so the skip is the only thing that
  # can prevent a dispatch).
  export COMMENTS_JSON
  COMMENTS_JSON="$(jq -nc --arg s "$HEAD_SHA" \
    '["<!-- dev-lead-fix-ci sha=\($s) status=rate-limited reset=2020-01-01T00:00:00Z check=CI failure -->"]')"
  export LABELS_JSON='[]'
  # gather_pr_automation_events pulls commits/reviews for the budget check;
  # default to empty so the budget is not exhausted unless a test says so.
  export COMMITS_JSON='[]'

  # gh stub. Distinguishes the PR-object fetch (returns {head,labels}), the
  # comments fetch (returns the post-jq array of bodies), the budget commits
  # fetch, and captures dispatches.
  export PAYLOAD_FILE="$MOCK_BIN/payload.json"
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *dispatches*)        cat > "${PAYLOAD_FILE:-/dev/null}"; exit 0 ;;
  *pulls/*/commits*)   printf '%s' "${COMMITS_JSON}" ;;
  *pulls/*/reviews*)   printf '%s' '[]' ;;
  *issues/*/comments*) printf '%s' "${COMMENTS_JSON}" ;;
  *check-runs*)        printf '%s' '{"id":"","details_url":""}' ;;
  *pulls/*)            jq -nc --arg s "${HEAD_SHA}" --argjson l "${LABELS_JSON}" \
                         --arg state "${PR_STATE:-open}" \
                         '{head:{sha:$s}, labels:($l | map({name:.})), state:$state}' ;;
  *)                   echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"

  source "$RETRY_SCRIPT"
}

teardown() {
  :
}

@test "retry PR: needs-human-review present → skips (no dispatch)" {
  LABELS_JSON='["needs-human-review"]'

  run scan_pr_for_rate_limits "petry-projects/demo" 860

  [ "$status" -eq 0 ]
  [[ "$output" == *"needs-human-review"* ]]
  [[ "$output" != *"would dispatch"* ]]
  # Last line is the dispatched count — must be 0.
  [ "$(printf '%s\n' "$output" | tail -n1)" = "0" ]
}

@test "retry PR: no escalation label → re-dispatches the rate-limited retry" {
  LABELS_JSON='[]'

  run scan_pr_for_rate_limits "petry-projects/demo" 860

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-ci-failure"* ]]
  [ "$(printf '%s\n' "$output" | tail -n1)" = "1" ]
}

@test "retry PR: exhausted automation budget (no label) → skips (no dispatch)" {
  # No needs-human-review label, but 10 bot commits since the last human
  # interaction → the per-PR automation budget is exhausted (#926). The
  # safety-net cron must consult the budget, not just the label, so it can
  # never re-ignite the #860 amplifier (#1407 AC #3).
  LABELS_JSON='["bug"]'
  COMMITS_JSON="$(jq -nc '[range(10) | {commit:{author:{date:"2026-06-18T00:00:00Z"}}, author:{login:"donpetry-bot"}}]')"

  run scan_pr_for_rate_limits "petry-projects/demo" 860

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
  [ "$(printf '%s\n' "$output" | tail -n1)" = "0" ]
}

@test "retry PR: removing needs-human-review re-enables dispatch (AC3)" {
  # Same PR/markers as the skip case, but the human has dropped the label.
  LABELS_JSON='["bug","p1"]'

  run scan_pr_for_rate_limits "petry-projects/demo" 860

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-ci-failure"* ]]
  [ "$(printf '%s\n' "$output" | tail -n1)" = "1" ]
}

@test "retry PR: closed PR → skips (no dispatch)" {
  # PR resolved from an event but already closed/merged before scan runs.
  export PR_STATE="closed"

  run scan_pr_for_rate_limits "petry-projects/demo" 860

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
  [ "$(printf '%s\n' "$output" | tail -n1)" = "0" ]
}

@test "retry PR: merged PR → skips (no dispatch)" {
  export PR_STATE="merged"

  run scan_pr_for_rate_limits "petry-projects/demo" 860

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
  [ "$(printf '%s\n' "$output" | tail -n1)" = "0" ]
}

@test "retry PR: recent dispatch guard in comments → skips to avoid duplicate" {
  # A dispatch guard for the current SHA posted 5 minutes before NOW_ISO
  # (within the 10-minute DISPATCH_GUARD_WINDOW_SEC window).
  COMMENTS_JSON="$(jq -nc --arg s "$HEAD_SHA" \
    '["<!-- dev-lead-fix-ci sha=\($s) status=rate-limited reset=2020-01-01T00:00:00Z check=CI failure -->",
      "<!-- dev-lead-dispatch-guard sha=\($s) at=2026-06-18T23:55:00Z -->"]')"

  run scan_pr_for_rate_limits "petry-projects/demo" 860

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
  [ "$(printf '%s\n' "$output" | tail -n1)" = "0" ]
}

@test "retry PR: stale dispatch guard (> window) → proceeds with dispatch" {
  # Guard posted 20 minutes before NOW_ISO — outside the 10-minute window.
  COMMENTS_JSON="$(jq -nc --arg s "$HEAD_SHA" \
    '["<!-- dev-lead-fix-ci sha=\($s) status=rate-limited reset=2020-01-01T00:00:00Z check=CI failure -->",
      "<!-- dev-lead-dispatch-guard sha=\($s) at=2026-06-18T23:40:00Z -->"]')"

  run scan_pr_for_rate_limits "petry-projects/demo" 860

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-ci-failure"* ]]
  [ "$(printf '%s\n' "$output" | tail -n1)" = "1" ]
}
