#!/usr/bin/env bats
# Unit tests for scripts/lib/delayed-retry-arming.sh (issue #2533).
#
# The sweep arms pr-review-delayed-retry.yml for two waits whose deadline is known
# when it defers a PR: a rate-limit marker's reset=, and the advisory gate's
# head-age timeout. Whether to arm is a pure decision, tested here without gh.
#
# Run with: bats tests/test_delayed_retry_arming.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/delayed-retry-arming.sh"

setup() {
  # shellcheck source=../scripts/lib/delayed-retry-arming.sh
  source "$LIB"
  MANIFEST="$(mktemp)"
  cat > "$MANIFEST" <<'EOF'
{
  "consumers": [
    {"repo": "combsmith/.github-private", "refs": [".github-private/.github/workflows/pr-review.yml"]},
    {"repo": "combsmith/markets", "refs": [".github-private/.github/workflows/dev-lead-reusable.yml",
                                           ".github-private/.github/workflows/pr-review.yml"]},
    {"repo": "combsmith/.github", "refs": [".github/.github/workflows/agent-shield-reusable.yml",
                                           ".github-private/.github/workflows/dev-lead-reusable.yml"]}
  ]
}
EOF
}

teardown() {
  rm -f "${MANIFEST:-}"
}

NOW=1000000
HORIZON=3600

# ---------------------------------------------------------------------------
# delayed_retry_arm_decision
# ---------------------------------------------------------------------------
@test "decision: a near rate-limit reset arms" {
  run delayed_retry_arm_decision rate-limit $((NOW + 600)) "$NOW" "$HORIZON" abc123 abc123 false true
  [ "$status" -eq 0 ]
  [ "$output" = "arm" ]
}

@test "decision: a near advisory head-age deadline arms" {
  run delayed_retry_arm_decision advisory-bots $((NOW + 900)) "$NOW" "$HORIZON" abc123 abc123 false true
  [ "$status" -eq 0 ]
  [ "$output" = "arm" ]
}

@test "decision: a deadline exactly at the horizon arms; one second past it does not" {
  run delayed_retry_arm_decision rate-limit $((NOW + HORIZON)) "$NOW" "$HORIZON" a a false true
  [ "$output" = "arm" ]
  run delayed_retry_arm_decision rate-limit $((NOW + HORIZON + 1)) "$NOW" "$HORIZON" a a false true
  [ "$status" -eq 1 ]
  [ "$output" = "skip:beyond-horizon" ]
}

@test "decision: does not arm when the head moved" {
  run delayed_retry_arm_decision advisory-bots $((NOW + 600)) "$NOW" "$HORIZON" oldhead newhead false true
  [ "$status" -eq 1 ]
  [ "$output" = "skip:head-moved" ]
  run delayed_retry_arm_decision rate-limit $((NOW + 600)) "$NOW" "$HORIZON" oldhead newhead false true
  [ "$output" = "skip:head-moved" ]
}

@test "decision: does not arm when a retry is already in flight for the same pr_url + head_sha" {
  run delayed_retry_arm_decision rate-limit $((NOW + 600)) "$NOW" "$HORIZON" a a true true
  [ "$status" -eq 1 ]
  [ "$output" = "skip:in-flight" ]
  run delayed_retry_arm_decision advisory-bots $((NOW + 600)) "$NOW" "$HORIZON" a a true true
  [ "$output" = "skip:in-flight" ]
}

@test "decision: does not arm for a repo that is not a pr-review consumer" {
  run delayed_retry_arm_decision rate-limit $((NOW + 600)) "$NOW" "$HORIZON" a a false false
  [ "$status" -eq 1 ]
  [ "$output" = "skip:not-consumer" ]
  run delayed_retry_arm_decision advisory-bots $((NOW + 600)) "$NOW" "$HORIZON" a a false false
  [ "$output" = "skip:not-consumer" ]
}

@test "decision: an elapsed deadline does not arm (the review is due now)" {
  run delayed_retry_arm_decision rate-limit "$NOW" "$NOW" "$HORIZON" a a false true
  [ "$status" -eq 1 ]
  [ "$output" = "skip:elapsed" ]
  run delayed_retry_arm_decision advisory-bots $((NOW - 5)) "$NOW" "$HORIZON" a a false true
  [ "$output" = "skip:elapsed" ]
}

@test "decision: a missing or non-numeric deadline does not arm" {
  run delayed_retry_arm_decision rate-limit "" "$NOW" "$HORIZON" a a false true
  [ "$status" -eq 1 ]
  [ "$output" = "skip:no-deadline" ]
  run delayed_retry_arm_decision rate-limit "soon" "$NOW" "$HORIZON" a a false true
  [ "$output" = "skip:no-deadline" ]
}

@test "decision: an unknown wait kind does not arm" {
  run delayed_retry_arm_decision ci-pending $((NOW + 600)) "$NOW" "$HORIZON" a a false true
  [ "$status" -eq 1 ]
  [ "$output" = "skip:unknown-wait" ]
}

@test "decision: an empty head on either side counts as moved" {
  run delayed_retry_arm_decision rate-limit $((NOW + 600)) "$NOW" "$HORIZON" "" a false true
  [ "$output" = "skip:head-moved" ]
  run delayed_retry_arm_decision rate-limit $((NOW + 600)) "$NOW" "$HORIZON" a "" false true
  [ "$output" = "skip:head-moved" ]
}

# ---------------------------------------------------------------------------
# pr_review_consumer_repo
# ---------------------------------------------------------------------------
@test "consumer: a repo whose manifest refs include the pr-review reusable is a consumer" {
  run pr_review_consumer_repo combsmith/markets combsmith/.github-private "$MANIFEST"
  [ "$status" -eq 0 ]
}

@test "consumer: a repo that uses other reusables but not pr-review is not a consumer" {
  run pr_review_consumer_repo combsmith/.github combsmith/.github-private "$MANIFEST"
  [ "$status" -eq 1 ]
}

@test "consumer: a repo absent from the manifest is not a consumer" {
  run pr_review_consumer_repo combsmith/demo combsmith/.github-private "$MANIFEST"
  [ "$status" -eq 1 ]
}

@test "consumer: the agent repo is always a consumer, even with an unreadable manifest" {
  run pr_review_consumer_repo combsmith/.github-private combsmith/.github-private /nonexistent/manifest.json
  [ "$status" -eq 0 ]
}

@test "consumer: another repo with an unreadable manifest is not a consumer" {
  run pr_review_consumer_repo combsmith/markets combsmith/.github-private /nonexistent/manifest.json
  [ "$status" -eq 1 ]
}

@test "consumer: an empty repo is not a consumer" {
  run pr_review_consumer_repo "" combsmith/.github-private "$MANIFEST"
  [ "$status" -eq 1 ]
}

@test "consumer: the shipped manifest lists the agent repo and google-app-scripts as consumers" {
  run pr_review_consumer_repo combsmith/google-app-scripts combsmith/.github-private "$REPO_ROOT/scripts/lib/consumer-manifest.json"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# advisory_head_age_deadline
# ---------------------------------------------------------------------------
@test "deadline: head committer time plus the timeout, as an epoch" {
  run advisory_head_age_deadline "2026-11-14T00:00:00Z" 1200
  [ "$status" -eq 0 ]
  [ "$output" = "$(( $(date -u -d '2026-11-14T00:00:00Z' +%s) + 1200 ))" ]
}

@test "deadline: an unparseable or empty committer time yields nothing" {
  run advisory_head_age_deadline "not-a-date" 1200
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run advisory_head_age_deadline "" 1200
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "deadline: a non-numeric timeout yields nothing" {
  run advisory_head_age_deadline "2026-11-14T00:00:00Z" "abc"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
