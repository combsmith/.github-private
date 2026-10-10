# shellcheck shell=bash
# scripts/lib/rate-limit-markers.sh — the comment-marker shapes dev-lead posts
# when a run is held, defined once for every READER of them (#2221).
#
# Readers: scripts/dev-lead-retry.sh (re-dispatches a held run) and
# scripts/lib/budget-breaker.sh (counts quota refusals across the fleet). Both
# source this file, so the two cannot disagree about what a marker looks like.
#
# The WRITERS keep their own literals (dev-lead-fix-ci.sh `MARKER_PREFIX`,
# dev-lead-fix-reviews.sh `REVIEWS_MARKER_PREFIX`, dev-lead-fix-issue.sh
# `ISSUE_MARKER_PREFIX`). tests/dev-lead/unit/test_budget_breaker.bats runs the
# real posting functions and feeds what they post to the reader, so a writer
# that changes its marker fails a test instead of drifting silently.
#
# Definitions only: sourcing this file runs nothing and reads no environment.

# Marker shapes (the part before the per-item fields):
#   <!-- dev-lead-fix-ci sha=<SHA> status=<s> [reset=<ISO>] [check=<name>] -->
#   <!-- dev-lead-fix-reviews pr=<N> sha=<SHA> intent=<i> status=<s> [reason=<r>] [reset=<ISO>] -->
#   <!-- dev-lead-issue <N> status=<s> attempt=<K> reason=<r> run=<id> [reset=<ISO>] -->
# shellcheck disable=SC2034  # read by the scripts that source this file
CI_MARKER_PREFIX="<!-- dev-lead-fix-ci sha="
# shellcheck disable=SC2034
REVIEWS_MARKER_PREFIX="<!-- dev-lead-fix-reviews pr="
# shellcheck disable=SC2034
ISSUE_MARKER_PREFIX="<!-- dev-lead-issue "

# jq/Oniguruma regex that captures a marker's reset time as `.r`. It is the
# expression dev-lead-retry.sh's scan_pr_for_rate_limits uses inline
# (`capture("reset=(?<r>[0-9T:Z-]+)")`); a test pins the two to each other.
# shellcheck disable=SC2034
RATE_LIMIT_RESET_CAPTURE_RE='reset=(?<r>[0-9T:Z-]+)'
