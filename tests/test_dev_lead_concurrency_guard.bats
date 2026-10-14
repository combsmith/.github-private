#!/usr/bin/env bats
# Regression guard for petry-projects/.github#443 (and #402/#450).
#
# The dev-lead issue-pickup race: GitHub fires one issues:labeled event per label
# added in a single API call. If the reusable's per-issue concurrency used
# cancel-in-progress:true, a later (non-dev-lead) labeled event could CANCEL the
# run triggered by the dev-lead label before it dispatched — a "successful"
# workflow that opened no PR. The fix (#450) is separate per-issue/per-PR lanes
# with cancel-in-progress: false, so same-lane events queue behind the active run
# and the pickup always finishes. These asserts fail loudly if anyone flips it back.

REUSABLE=".github/workflows/dev-lead-reusable.yml"

@test "dev-lead reusable concurrency is cancel-in-progress: false (#443/#450)" {
  run grep -E '^[[:space:]]*cancel-in-progress:[[:space:]]*false[[:space:]]*$' "$REUSABLE"
  [ "$status" -eq 0 ]
}

@test "dev-lead reusable has NO cancel-in-progress: true (would re-open the #443 race)" {
  run grep -E '^[[:space:]]*cancel-in-progress:[[:space:]]*true[[:space:]]*$' "$REUSABLE"
  [ "$status" -eq 1 ]
}

@test "dev-lead reusable routes issue events to a per-issue lane (#402 lanes)" {
  run grep -F "format('dev-lead-issue-{0}', github.event.issue.number)" "$REUSABLE"
  [ "$status" -eq 0 ]
}
