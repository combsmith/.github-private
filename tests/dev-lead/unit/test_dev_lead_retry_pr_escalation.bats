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
  MOCK_BIN="$(mktemp -d)" || { echo "Failed to create temp dir" >&2; exit 1; }
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

  # gh stub. Distinguishes the PR-object fetch (returns {head,labels}) from the
  # comments fetch (returns the post-jq array of bodies) and captures dispatches.
  export PAYLOAD_FILE="$MOCK_BIN/payload.json"
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *dispatches*)        cat > "${PAYLOAD_FILE:-/dev/null}"; exit 0 ;;
  *issues/*/comments*) printf '%s' "${COMMENTS_JSON}" ;;
  *check-runs*)        printf '%s' '{"id":"","details_url":""}' ;;
  *pulls/*)            jq -nc --arg s "${HEAD_SHA}" --argjson l "${LABELS_JSON}" \
                         '{head:{sha:$s}, labels:($l | map({name:.}))}' ;;
  *)                   echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"

  source "$RETRY_SCRIPT"
}

teardown() {
  rm -rf "$MOCK_BIN"
}

@test "retry PR: needs-human-review present → skips (no dispatch)" {
  LABELS_JSON='["needs-human-review"]'

  run scan_pr_for_rate_limits "combsmith/demo" 860

  [ "$status" -eq 0 ]
  [[ "$output" == *"needs-human-review"* ]]
  [[ "$output" != *"would dispatch"* ]]
  # Last line is the dispatched count — must be 0.
  [ "$(printf '%s\n' "$output" | tail -n1)" = "0" ]
}

@test "retry PR: no escalation label → re-dispatches the rate-limited retry" {
  LABELS_JSON='[]'

  run scan_pr_for_rate_limits "combsmith/demo" 860

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-ci-failure"* ]]
  [ "$(printf '%s\n' "$output" | tail -n1)" = "1" ]
}

@test "retry PR: removing needs-human-review re-enables dispatch (AC3)" {
  # Same PR/markers as the skip case, but the human has dropped the label.
  LABELS_JSON='["bug","p1"]'

  run scan_pr_for_rate_limits "combsmith/demo" 860

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-ci-failure"* ]]
  [ "$(printf '%s\n' "$output" | tail -n1)" = "1" ]
}
