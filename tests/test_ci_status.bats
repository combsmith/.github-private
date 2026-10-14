#!/usr/bin/env bats
# Unit tests for compute_ci_status in scripts/lib/ci-status.sh
# (issue #469: own check runs must never cause ci-pending/ci-failing classification)
#
# Run with: bats tests/test_ci_status.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/ci-status.sh"
}

# ---------------------------------------------------------------------------
# Helpers to build statusCheckRollup items
# ---------------------------------------------------------------------------

# check_run <name> <status> [conclusion]
# Models a GitHub Actions CheckRun in the statusCheckRollup array.
check_run() {
  local name="$1" status="$2" conclusion="${3:-null}"
  if [ "$conclusion" = "null" ]; then
    jq -n --arg name "$name" --arg status "$status" \
      '{name: $name, status: $status, conclusion: null}'
  else
    jq -n --arg name "$name" --arg status "$status" --arg conclusion "$conclusion" \
      '{name: $name, status: $status, conclusion: $conclusion}'
  fi
}

# check_run_wf <name> <workflowName> <status> [conclusion]
# Models a CheckRun that also carries a workflowName (as the real rollup does).
check_run_wf() {
  local name="$1" wf="$2" status="$3" conclusion="${4:-null}"
  if [ "$conclusion" = "null" ]; then
    jq -n --arg name "$name" --arg wf "$wf" --arg status "$status" \
      '{name: $name, workflowName: $wf, status: $status, conclusion: null}'
  else
    jq -n --arg name "$name" --arg wf "$wf" --arg status "$status" --arg conclusion "$conclusion" \
      '{name: $name, workflowName: $wf, status: $status, conclusion: $conclusion}'
  fi
}

# check_run_started <name> <status> <conclusion|null> <startedAt>
# Models a CheckRun that also carries a startedAt timestamp (as the real rollup
# does) — used by the ci_pending_age_exceeded bounded-deferral tests (#1427).
check_run_started() {
  local name="$1" status="$2" conclusion="$3" started="$4"
  if [ "$conclusion" = "null" ]; then
    jq -n --arg name "$name" --arg status "$status" --arg started "$started" \
      '{name: $name, status: $status, conclusion: null, startedAt: $started}'
  else
    jq -n --arg name "$name" --arg status "$status" --arg conclusion "$conclusion" --arg started "$started" \
      '{name: $name, status: $status, conclusion: $conclusion, startedAt: $started}'
  fi
}

# status_ctx <context> <state>
# Models a commit StatusContext in the statusCheckRollup array.
status_ctx() {
  jq -n --arg context "$1" --arg state "$2" \
    '{context: $context, state: $state}'
}

# rollup <item-json>...
# Wraps items into a JSON array.
rollup() {
  printf '%s\n' "$@" | jq -s '.'
}

# ---------------------------------------------------------------------------
# Baseline: empty / all-passing rollups
# ---------------------------------------------------------------------------

@test "empty rollup returns passing" {
  run compute_ci_status '[]'
  [ "$status" -eq 0 ]
  [ "$output" = "passing" ]
}

@test "single passing external check returns passing" {
  local r
  r=$(rollup "$(check_run "Lint" "COMPLETED" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "single skipped external check returns passing" {
  local r
  r=$(rollup "$(check_run "Path-filtered" "COMPLETED" "SKIPPED")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "single neutral external check returns passing" {
  local r
  r=$(rollup "$(check_run "Informational" "COMPLETED" "NEUTRAL")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

# ---------------------------------------------------------------------------
# External pending / failing without own checks
# ---------------------------------------------------------------------------

@test "single external IN_PROGRESS check returns pending" {
  local r
  r=$(rollup "$(check_run "Build" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "single external QUEUED check returns pending" {
  local r
  r=$(rollup "$(check_run "Test" "QUEUED")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "single external failing check returns failing" {
  local r
  r=$(rollup "$(check_run "Test" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

# ---------------------------------------------------------------------------
# PR Review Agent bare job name IS filtered (actual rollup shape)
# `gh pr view --json statusCheckRollup` exposes the job name only (not the
# workflow name, per gh/cli#9091), so the PR Review Agent's own job appears as
# a bare name: "review". This is filtered to prevent the cascade from blocking
# on its own pending check run.
# Dev-Lead BARE job names ("dispatch", "ci-relay") remain NOT filtered: only the
# nested "<role> / <job>" form (e.g. "dev-lead / dispatch", the real rollup shape)
# is filtered as an agent check (#1427), so a genuine external check that merely
# happens to be named "dispatch" is never swallowed.
# ---------------------------------------------------------------------------

@test "bare PR Review Agent check 'review' (IN_PROGRESS) is filtered → passing" {
  local r
  r=$(rollup "$(check_run "review" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "bare Dev-Lead check 'dispatch' (IN_PROGRESS) is NOT filtered → pending" {
  local r
  r=$(rollup "$(check_run "dispatch" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "bare Dev-Lead check 'ci-relay' (IN_PROGRESS) is NOT filtered → pending" {
  local r
  r=$(rollup "$(check_run "ci-relay" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "bare check named 'pr-review-mention' (IN_PROGRESS) is NOT filtered → pending" {
  local r
  r=$(rollup "$(check_run "pr-review-mention" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "bare check named 'mention-ack' (IN_PROGRESS) is NOT filtered → pending" {
  local r
  r=$(rollup "$(check_run "mention-ack" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

# ---------------------------------------------------------------------------
# Known PR Review workflow checks ARE filtered — workflow / job-name form
# ---------------------------------------------------------------------------

@test "'PR Review Agent / review' (IN_PROGRESS) is filtered out → passing" {
  local r
  r=$(rollup "$(check_run "PR Review Agent / review" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "'PR Review Reusable / review' (IN_PROGRESS) is filtered out → passing" {
  local r
  r=$(rollup "$(check_run "PR Review Reusable / review" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "'PR Review — Mention Trigger / pr-review-mention' (IN_PROGRESS) is filtered out → passing" {
  local r
  r=$(rollup "$(check_run "PR Review — Mention Trigger / pr-review-mention" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

# #497 self-host: invoked via the trigger stub, the cascade's own check appears
# as the nested "review / review" — must still be filtered so a stale/failed own
# check never blocks the agent from re-reviewing.
@test "nested 'review / review' (FAILURE) is filtered out → passing" {
  local r
  r=$(rollup "$(check_run "review / review" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "nested 'review / review' FAILURE alongside an external pass → passing" {
  local r
  r=$(rollup "$(check_run "review / review" "COMPLETED" "FAILURE")" "$(check_run "SonarCloud" "COMPLETED" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "a genuinely external failing check still → failing (regression guard)" {
  local r
  r=$(rollup "$(check_run "review / review" "COMPLETED" "FAILURE")" "$(check_run "SonarCloud" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

# #536 consumer fan-out: a consumer's OLD pr-review check appears as
# "pr-review / review" with workflowName "PR Review Agent" — filtered by
# workflowName so a stale failed own-check doesn't block re-review.
@test "consumer 'pr-review / review' (workflowName PR Review Agent, FAILURE) is filtered → passing" {
  local r
  r=$(rollup "$(check_run_wf "pr-review / review" "PR Review Agent" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "workflowName filter does NOT swallow an external failing check" {
  local r
  r=$(rollup "$(check_run_wf "pr-review / review" "PR Review Agent" "COMPLETED" "FAILURE")" "$(check_run_wf "Backend CI" "Backend CI" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

# ---------------------------------------------------------------------------
# Other first-party agents' own check runs ARE filtered (issue #1427, AC #1/#2)
# A writing agent's own orchestration check (e.g. 'dev-lead / dispatch') must not
# gate the reviewing agent. The excluded roles are derived from the declared
# interaction contracts (interaction-contracts/*.yml, #1404) — the same registry
# that names each role's workflows — not a second hand-maintained name list.
# The nested "<role> / <job>" form is what the real rollup carries (caller-job /
# reusable-job); a generic external 'workflow / review' suffix (e.g. 'Build /
# review') is NOT a role slug and must still block so external required checks are
# never silently bypassed.
# ---------------------------------------------------------------------------

@test "'dev-lead / dispatch' (IN_PROGRESS) is filtered → passing (#1427)" {
  local r
  r=$(rollup "$(check_run "dev-lead / dispatch" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "'dev-lead / ci-relay' (IN_PROGRESS) is filtered → passing (#1427)" {
  local r
  r=$(rollup "$(check_run "dev-lead / ci-relay" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

# #1420 fixture: a lone in-progress 'dev-lead / dispatch' alongside an otherwise
# fully-green PR must not defer the review.
@test "#1420 fixture: dev-lead/dispatch IN_PROGRESS + all external green → passing" {
  local r
  r=$(rollup \
    "$(check_run "dev-lead / dispatch" "IN_PROGRESS")" \
    "$(check_run "bats" "COMPLETED" "SUCCESS")" \
    "$(check_run "unit" "COMPLETED" "SUCCESS")" \
    "$(check_run "unit-tests" "COMPLETED" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

# A genuine external check literally named '<role> / *' is still filtered only for
# a real declared role. 'Build / review' does not start with any role slug, so it
# still blocks.
@test "'Build / review' (IN_PROGRESS) is NOT filtered → pending" {
  local r
  r=$(rollup "$(check_run "Build / review" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

# A genuinely-pending external required check must still defer (AC #4/#6): the
# agent-check filter and the terminal-conclusion rule must not swallow it.
@test "genuinely-pending external required check still → pending (regression)" {
  local r
  r=$(rollup \
    "$(check_run "dev-lead / dispatch" "IN_PROGRESS")" \
    "$(check_run "required-ci" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

# ---------------------------------------------------------------------------
# Zombie check: IN_PROGRESS carrying a terminal conclusion is complete (#1427,
# AC #3). Observed on PR #1426: 'Validate AW specs, docs, and workflows' reported
# status IN_PROGRESS while carrying conclusion SUCCESS. A conclusion is by
# definition terminal, so the check is classified by its conclusion, not deferred.
# ---------------------------------------------------------------------------

@test "zombie check: IN_PROGRESS + conclusion SUCCESS → passing (#1426)" {
  local r
  r=$(rollup "$(check_run "Validate AW specs, docs, and workflows" "IN_PROGRESS" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "zombie SUCCESS alongside a genuine external pending → still pending" {
  local r
  r=$(rollup \
    "$(check_run "Validate AW specs" "IN_PROGRESS" "SUCCESS")" \
    "$(check_run "Build" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "IN_PROGRESS carrying terminal conclusion FAILURE → failing (terminal wins)" {
  local r
  r=$(rollup "$(check_run "Flaky" "IN_PROGRESS" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

# ---------------------------------------------------------------------------
# ci_pending_age_exceeded — bounded ci-pending deferral (#1427, AC #3/#4).
# True only when there is ≥1 external (non-own, non-agent) pending check AND every
# such check has been pending longer than the configured max age. Unknown age is
# fail-safe (not exceeded). Callers use it to bound the review DECISION only; the
# merge gate is enforced independently by the ruleset.
# ---------------------------------------------------------------------------

@test "ci_pending_age_exceeded: pending check older than max age → true" {
  local now old r
  now=2000000000
  old="2001-09-09T01:46:40Z"
  r=$(rollup "$(check_run_started "Build" "IN_PROGRESS" "null" "$old")")
  run ci_pending_age_exceeded "$r" 1800 "$now"
  [ "$output" = "true" ]
}

@test "ci_pending_age_exceeded: recently-started pending check → false" {
  local now recent r
  now=2000000000
  recent="2033-05-18T03:23:20Z"
  r=$(rollup "$(check_run_started "Build" "IN_PROGRESS" "null" "$recent")")
  run ci_pending_age_exceeded "$r" 1800 "$now"
  [ "$output" = "false" ]
}

@test "ci_pending_age_exceeded: no pending checks → false" {
  local r
  r=$(rollup "$(check_run "Build" "COMPLETED" "SUCCESS")")
  run ci_pending_age_exceeded "$r" 1800 2000000000
  [ "$output" = "false" ]
}

@test "ci_pending_age_exceeded: pending check with no timestamp → false (fail-safe)" {
  local r
  r=$(rollup "$(check_run "Build" "IN_PROGRESS")")
  run ci_pending_age_exceeded "$r" 1800 2000000000
  [ "$output" = "false" ]
}

@test "ci_pending_age_exceeded: one old + one recent pending → false (not all stuck)" {
  local now old recent r
  now=2000000000
  old="2001-09-09T01:46:40Z"
  recent="2033-05-18T03:23:20Z"
  r=$(rollup \
    "$(check_run_started "Old" "IN_PROGRESS" "null" "$old")" \
    "$(check_run_started "Recent" "IN_PROGRESS" "null" "$recent")")
  run ci_pending_age_exceeded "$r" 1800 "$now"
  [ "$output" = "false" ]
}

@test "ci_pending_age_exceeded: a stuck agent check is ignored → false" {
  # A stuck 'dev-lead / dispatch' is filtered from the pending set entirely, so it
  # cannot itself trip the external-pending timeout.
  local now old r
  now=2000000000
  old="2001-09-09T01:46:40Z"
  r=$(rollup "$(check_run_started "dev-lead / dispatch" "IN_PROGRESS" "null" "$old")")
  run ci_pending_age_exceeded "$r" 1800 "$now"
  [ "$output" = "false" ]
}

# ---------------------------------------------------------------------------
# Failure classification: PR Review checks (bare and compound) are filtered
# ---------------------------------------------------------------------------

@test "bare PR Review Agent check 'review' (COMPLETED/FAILURE) is filtered → passing" {
  local r
  r=$(rollup "$(check_run "review" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "'PR Review Agent / review' (COMPLETED/FAILURE) is filtered out → passing" {
  local r
  r=$(rollup "$(check_run "PR Review Agent / review" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

# ---------------------------------------------------------------------------
# Mix: PR Review workflow pending + external passing → passing (filtered)
# ---------------------------------------------------------------------------

@test "mix: 'PR Review Agent / review' pending + external passing → passing" {
  local r
  r=$(rollup \
    "$(check_run "PR Review Agent / review" "IN_PROGRESS")" \
    "$(check_run "CI / build" "COMPLETED" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

# ---------------------------------------------------------------------------
# Mix: bare PR Review Agent checks filtered; external result determines status
# ---------------------------------------------------------------------------

@test "mix: bare 'review' filtered + external passing → passing" {
  local r
  r=$(rollup \
    "$(check_run "review" "IN_PROGRESS")" \
    "$(check_run "Lint" "COMPLETED" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "mix: bare 'dispatch' NOT filtered + external passing → pending" {
  local r
  r=$(rollup \
    "$(check_run "dispatch" "IN_PROGRESS")" \
    "$(check_run "Build" "COMPLETED" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

# ---------------------------------------------------------------------------
# Mix: bare PR Review Agent check filtered + external pending → pending
# ---------------------------------------------------------------------------

@test "mix: bare 'review' filtered + external pending → pending" {
  local r
  r=$(rollup \
    "$(check_run "review" "IN_PROGRESS")" \
    "$(check_run "Build" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

# ---------------------------------------------------------------------------
# Mix: bare PR Review Agent check filtered + external failing → failing
# ---------------------------------------------------------------------------

@test "mix: bare 'review' filtered + external failing → failing" {
  # 'review' is filtered out; only 'Test' (COMPLETED/FAILURE) remains in $ext.
  local r
  r=$(rollup \
    "$(check_run "review" "IN_PROGRESS")" \
    "$(check_run "Test" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

# ---------------------------------------------------------------------------
# Rollup with only PR Review workflow checks → passing (all filtered)
# ---------------------------------------------------------------------------

@test "rollup with only PR Review workflow/job form checks returns passing" {
  local r
  r=$(rollup \
    "$(check_run "PR Review Agent / review" "IN_PROGRESS")" \
    "$(check_run "PR Review — Mention Trigger / pr-review-mention" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

# ---------------------------------------------------------------------------
# Rollup with only PR Review Agent bare job names → passing (all filtered)
# ---------------------------------------------------------------------------

@test "rollup: 'review' filtered, Dev-Lead 'dispatch' + 'ci-relay' NOT filtered → pending" {
  local r
  r=$(rollup \
    "$(check_run "review" "IN_PROGRESS")" \
    "$(check_run "dispatch" "IN_PROGRESS")" \
    "$(check_run "ci-relay" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

# ---------------------------------------------------------------------------
# CANCELLED checks are non-blocking (issue #608)
# dev-lead's orchestration jobs (dispatch, ci-relay) are routinely CANCELLED by
# dev-lead's own concurrency when a run is superseded. A cancelled check is not a
# failed check, so it must not classify the PR as failing. It is treated as
# non-blocking (success-equivalent), not pending — a superseded check never
# completes, so pending would leave the PR perpetually un-reviewable.
# ---------------------------------------------------------------------------

@test "single external CANCELLED check returns passing" {
  local r
  r=$(rollup "$(check_run "Build" "COMPLETED" "CANCELLED")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "CANCELLED dev-lead 'dispatch' check returns passing" {
  local r
  r=$(rollup "$(check_run "dispatch" "COMPLETED" "CANCELLED")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "CANCELLED 'dev-lead / dispatch' check returns passing" {
  local r
  r=$(rollup "$(check_run "dev-lead / dispatch" "COMPLETED" "CANCELLED")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "CANCELLED check alongside external passing → passing" {
  local r
  r=$(rollup \
    "$(check_run "dev-lead / dispatch" "COMPLETED" "CANCELLED")" \
    "$(check_run "CI / build" "COMPLETED" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "CANCELLED check alongside external FAILURE → failing (regression guard)" {
  local r
  r=$(rollup \
    "$(check_run "dev-lead / dispatch" "COMPLETED" "CANCELLED")" \
    "$(check_run "CI / build" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

@test "CANCELLED check alongside external IN_PROGRESS → pending (regression guard)" {
  local r
  r=$(rollup \
    "$(check_run "dev-lead / dispatch" "COMPLETED" "CANCELLED")" \
    "$(check_run "CI / build" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

# ---------------------------------------------------------------------------
# classify_rollup_eventability (#1408) — split a PR's non-own checks into the
# genuinely un-eventable residue (GitHub-App / cross-repo checks like SonarCloud
# that emit no workflow_run, detected by the absence of a workflowName) versus
# eventable GitHub Actions check runs (which carry a workflowName and whose
# completion the pr-review-sweep fast path already keys on). The scheduled
# (cron) sweep re-dispatches only for the un-eventable residue.
#   Emits: "none" | "eventable-only" | "has-uneventable"
# ---------------------------------------------------------------------------

@test "classify_rollup_eventability: a GitHub Actions check (has workflowName) is eventable-only" {
  local r
  r=$(rollup "$(check_run_wf "build" "CI" "COMPLETED" "SUCCESS")")
  run classify_rollup_eventability "$r"
  [ "$output" = "eventable-only" ]
}

@test "classify_rollup_eventability: a StatusContext (no workflowName) is un-eventable residue" {
  local r
  r=$(rollup "$(status_ctx "SonarCloud" "SUCCESS")")
  run classify_rollup_eventability "$r"
  [ "$output" = "has-uneventable" ]
}

@test "classify_rollup_eventability: a GitHub-App CheckRun with no workflowName is un-eventable" {
  local r
  r=$(rollup "$(check_run "SonarCloud Code Analysis" "COMPLETED" "SUCCESS")")
  run classify_rollup_eventability "$r"
  [ "$output" = "has-uneventable" ]
}

@test "classify_rollup_eventability: mixed eventable + un-eventable is has-uneventable" {
  local r
  r=$(rollup \
    "$(check_run_wf "build" "CI" "COMPLETED" "SUCCESS")" \
    "$(status_ctx "SonarCloud" "SUCCESS")")
  run classify_rollup_eventability "$r"
  [ "$output" = "has-uneventable" ]
}

@test "classify_rollup_eventability: own pr-review checks are ignored, not counted as un-eventable" {
  # A bare own 'review' check has no workflowName but must not be mistaken for the
  # un-eventable residue — it is filtered before classification.
  local r
  r=$(rollup \
    "$(check_run "review" "COMPLETED" "SUCCESS")" \
    "$(check_run_wf "build" "CI" "COMPLETED" "SUCCESS")")
  run classify_rollup_eventability "$r"
  [ "$output" = "eventable-only" ]
}

@test "classify_rollup_eventability: no external checks at all → none" {
  local r
  r=$(rollup "$(check_run "review" "COMPLETED" "SUCCESS")")
  run classify_rollup_eventability "$r"
  [ "$output" = "none" ]
}

@test "classify_rollup_eventability: empty rollup → none" {
  run classify_rollup_eventability '[]'
  [ "$output" = "none" ]
}

@test "classify_rollup_eventability: workflowName NOT in sweep trigger list is un-eventable" {
  # 'Dependency audit' and 'AgentShield' are not in the workflow_run trigger list;
  # the sweep never fires for them, so they can only be covered by the cron backstop.
  local r
  r=$(rollup "$(check_run_wf "dep-audit" "Dependency audit" "COMPLETED" "SUCCESS")")
  run classify_rollup_eventability "$r"
  [ "$output" = "has-uneventable" ]
}

@test "classify_rollup_eventability: all five trigger workflow names are individually eventable" {
  # Each name in the classifier's eventable-workflow list must classify as eventable-only.
  local r wf
  while IFS= read -r wf; do
    r=$(rollup "$(check_run_wf "job" "$wf" "COMPLETED" "SUCCESS")")
    run classify_rollup_eventability "$r"
    [ "$output" = "eventable-only" ] || { echo "FAIL for workflowName='$wf': got '$output'"; return 1; }
  done < <(jq -r '.[]' <<< "$_CI_STATUS_EVENTABLE_WORKFLOWS")
}

@test "classify_rollup_eventability: classifier allowlist matches pr-review-sweep.yml workflow_run.workflows" {
  # Drift guard: the classifier's _CI_STATUS_EVENTABLE_WORKFLOWS must stay in
  # sync with the actual trigger list in pr-review-sweep.yml. This test fails
  # automatically when either list is updated without updating the other.
  local sweep_yml configured_json
  sweep_yml="$(dirname "$BATS_TEST_FILENAME")/../.github/workflows/pr-review-sweep.yml"
  configured_json=$(grep -m1 'workflows: \[' "$sweep_yml" | sed 's/.*workflows: //')
  [ "$(jq -r '.[]' <<< "$configured_json" | sort)" = \
    "$(jq -r '.[]' <<< "$_CI_STATUS_EVENTABLE_WORKFLOWS" | sort)" ]
}

@test "rollup of only CANCELLED dev-lead orchestration checks → passing (issue #608 repro)" {
  local r
  r=$(rollup \
    "$(check_run "dev-lead / dispatch" "COMPLETED" "CANCELLED")" \
    "$(check_run "dev-lead / ci-relay" "COMPLETED" "CANCELLED")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "own pr-review 'review / review' check CANCELLED → passing (issue #1421 regression)" {
  # PR #1421: the pr-review run was evicted while pending, leaving a terminal
  # CANCELLED "review / review" check that gh pr checks rendered as `fail`. The
  # cascade must not treat its own cancelled check as a merge-blocking failure.
  local r
  r=$(rollup "$(check_run "review / review" "COMPLETED" "CANCELLED")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "own pr-review CANCELLED check alongside external SUCCESS → passing (issue #1421)" {
  local r
  r=$(rollup \
    "$(check_run "review / review" "COMPLETED" "CANCELLED")" \
    "$(check_run "Build" "COMPLETED" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "PR #1531 rollup: many superseded CANCELLED agent checks + a real green check → passing (issue #1552 repro)" {
  # PR #1531 (2026-08-19) sat clean-but-unreviewed for 100 min. Its rollup carried
  # 12-13 red-rendering CANCELLED entries, ALL concurrency-superseded agent-workflow
  # runs (review / review ×5, dev-lead / dispatch|ci-relay|resume, Dismiss), while a
  # real required check (CI) was green. The operator's in-incident theory was that
  # pr-review defers on these reds — this test rules that out: the whole rollup
  # classifies PASSING, so NO human re-run of the cancelled checks is needed to
  # converge (#1552 AC#1/AC#4). "Dismiss" is not an agent role — it is non-blocking
  # purely via the CANCELLED whitelist (#608), which is exactly the point.
  local r
  r=$(rollup \
    "$(check_run "review / review" "COMPLETED" "CANCELLED")" \
    "$(check_run "review / review" "COMPLETED" "CANCELLED")" \
    "$(check_run "review / review" "COMPLETED" "CANCELLED")" \
    "$(check_run "review / review" "COMPLETED" "CANCELLED")" \
    "$(check_run "review / review" "COMPLETED" "CANCELLED")" \
    "$(check_run "dev-lead / dispatch" "COMPLETED" "CANCELLED")" \
    "$(check_run "dev-lead / ci-relay" "COMPLETED" "CANCELLED")" \
    "$(check_run "dev-lead / resume" "COMPLETED" "CANCELLED")" \
    "$(check_run "Dismiss" "COMPLETED" "CANCELLED")" \
    "$(check_run "CI" "COMPLETED" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "PR #1531 rollup: the same superseded CANCELLED agent checks with NO real check → passing (issue #1552)" {
  # The pre-green window of the same incident: only the superseded CANCELLED agent
  # runs are present (no external required check yet). This must still be passing —
  # a rollup of only cancelled agent orchestration checks is never a merge blocker.
  local r
  r=$(rollup \
    "$(check_run "review / review" "COMPLETED" "CANCELLED")" \
    "$(check_run "dev-lead / dispatch" "COMPLETED" "CANCELLED")" \
    "$(check_run "dev-lead / ci-relay" "COMPLETED" "CANCELLED")" \
    "$(check_run "dev-lead / resume" "COMPLETED" "CANCELLED")" \
    "$(check_run "Dismiss" "COMPLETED" "CANCELLED")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "PR #1531 rollup regression guard: one genuinely FAILING required check among the CANCELLED still → failing (issue #1552)" {
  # The safety converse: the CANCELLED whitelist must not mask a real failure. If a
  # required check genuinely fails alongside the superseded cancelled agent runs,
  # the rollup must still classify failing so pr-review correctly withholds.
  local r
  r=$(rollup \
    "$(check_run "review / review" "COMPLETED" "CANCELLED")" \
    "$(check_run "dev-lead / dispatch" "COMPLETED" "CANCELLED")" \
    "$(check_run "Dismiss" "COMPLETED" "CANCELLED")" \
    "$(check_run "CI" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

@test "status context CANCELLED-equivalent: real TIMED_OUT conclusion still → failing" {
  # Guards that only CANCELLED is whitelisted — other non-success terminal
  # conclusions (e.g. TIMED_OUT) must still block.
  local r
  r=$(rollup "$(check_run "Build" "COMPLETED" "TIMED_OUT")")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

# ---------------------------------------------------------------------------
# StatusContext checks are unaffected by the own-check filter
# ---------------------------------------------------------------------------

@test "status context with PENDING state still causes pending classification" {
  local r
  r=$(rollup "$(status_ctx "sonarcloud" "PENDING")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "status context with FAILURE state still causes failing classification" {
  local r
  r=$(rollup "$(status_ctx "sonarcloud" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

@test "status context named 'external-ci' (non-own-check) with PENDING state still causes pending" {
  # StatusContext entries that do not match any own-check prefix must still block
  # as pending — verifies the filter doesn't accidentally swallow external statuses.
  local r
  r=$(rollup "$(status_ctx "external-ci" "PENDING")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

# ---------------------------------------------------------------------------
# Malformed / edge input
# ---------------------------------------------------------------------------

@test "malformed JSON input returns passing (safe default)" {
  run compute_ci_status "not-json"
  [ "$status" -eq 0 ]
  [ "$output" = "passing" ]
}

@test "null JSON input returns passing (safe default)" {
  run compute_ci_status "null"
  [ "$output" = "passing" ]
}

# ---------------------------------------------------------------------------
# Required-check gating (#1549). `gh pr view --json statusCheckRollup` marks each
# entry with .isRequired (GitHub's per-PR verdict combining the target branch's
# rulesets AND classic protection). When any remaining (non-own, non-agent) check
# is flagged required, compute_ci_status gates ONLY on the required set — a red
# NON-required check (a superseded 'dev-lead / dispatch', or 'template-drift' from
# a repo-template Dependabot bump) no longer blocks the review that would approve
# an otherwise-green PR (the circular skip in #1549). When nothing is flagged
# required (isRequired absent — older gh, no protection, or required checks not
# yet reported), the gate falls back to evaluating every external check.
# ---------------------------------------------------------------------------

# check_run_req <name> <status> <conclusion|null> <isRequired: true|false>
# Models a CheckRun carrying the .isRequired field the real rollup exposes (#1549).
check_run_req() {
  local name="$1" status="$2" conclusion="$3" req="$4"
  if [ "$conclusion" = "null" ]; then
    jq -n --arg name "$name" --arg status "$status" --argjson req "$req" \
      '{name: $name, status: $status, conclusion: null, isRequired: $req}'
  else
    jq -n --arg name "$name" --arg status "$status" --arg conclusion "$conclusion" --argjson req "$req" \
      '{name: $name, status: $status, conclusion: $conclusion, isRequired: $req}'
  fi
}

# status_ctx_req <context> <state> <isRequired: true|false>
status_ctx_req() {
  jq -n --arg context "$1" --arg state "$2" --argjson req "$3" \
    '{context: $context, state: $state, isRequired: $req}'
}

@test "required gating: required SUCCESS + non-required FAILURE → passing (#1549)" {
  local r
  r=$(rollup \
    "$(check_run_req "Lint" "COMPLETED" "SUCCESS" true)" \
    "$(check_run_req "template-drift" "COMPLETED" "FAILURE" false)")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "required gating: required FAILURE + non-required SUCCESS → failing" {
  local r
  r=$(rollup \
    "$(check_run_req "Lint" "COMPLETED" "FAILURE" true)" \
    "$(check_run_req "template-drift" "COMPLETED" "SUCCESS" false)")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

# #1549 repro (ContentTwin #372, 2026-08-18): every required check green while a
# non-required org-plumbing check is red must classify passing so the review can
# post the approval that is the PR's only remaining merge requirement.
@test "#1549 repro: all required green + non-required 'template-drift' FAILURE → passing" {
  local r
  r=$(rollup \
    "$(check_run_req "SonarCloud" "COMPLETED" "SUCCESS" true)" \
    "$(check_run_req "CodeQL" "COMPLETED" "SUCCESS" true)" \
    "$(check_run_req "Lint" "COMPLETED" "SUCCESS" true)" \
    "$(check_run_req "Format" "COMPLETED" "SUCCESS" true)" \
    "$(check_run_req "agent-shield" "COMPLETED" "SUCCESS" true)" \
    "$(check_run_req "dependency-audit" "COMPLETED" "SUCCESS" true)" \
    "$(check_run_req "template-drift" "COMPLETED" "FAILURE" false)")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "required gating: pending required check → pending (non-required failure ignored)" {
  local r
  r=$(rollup \
    "$(check_run_req "Lint" "IN_PROGRESS" "null" true)" \
    "$(check_run_req "template-drift" "COMPLETED" "FAILURE" false)")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "required gating: non-required pending is ignored → passing" {
  local r
  r=$(rollup \
    "$(check_run_req "Lint" "COMPLETED" "SUCCESS" true)" \
    "$(check_run_req "template-drift" "IN_PROGRESS" "null" false)")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "required gating: required StatusContext (isRequired) is gated" {
  local r
  r=$(rollup \
    "$(status_ctx_req "sonarcloud" "FAILURE" true)" \
    "$(check_run_req "template-drift" "COMPLETED" "FAILURE" false)")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

# Fail-safe: when NOTHING is flagged required (isRequired absent — the shape today's
# fixtures produce), classification must not silently pass a genuine failure. It
# reverts to evaluating every external check (backward-compatible).
@test "required gating: no isRequired anywhere → evaluates all external (failing)" {
  local r
  r=$(rollup \
    "$(check_run "Lint" "COMPLETED" "SUCCESS")" \
    "$(check_run "template-drift" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

# Fail-safe: every check explicitly isRequired:false and one is failing → the
# required set is empty, so the gate falls back to all-external and still fails.
@test "required gating: all isRequired:false with a failure → fail-safe evaluates all (failing)" {
  local r
  r=$(rollup \
    "$(check_run_req "Lint" "COMPLETED" "SUCCESS" false)" \
    "$(check_run_req "template-drift" "COMPLETED" "FAILURE" false)")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

@test "required gating: own/agent checks still filtered even when required marks present" {
  local r
  r=$(rollup \
    "$(check_run "review / review" "COMPLETED" "FAILURE")" \
    "$(check_run "dev-lead / dispatch" "COMPLETED" "FAILURE")" \
    "$(check_run_req "Lint" "COMPLETED" "SUCCESS" true)")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

# Direct #1549 fingerprint: required checks green + a red 'dev-lead / dispatch'.
# Belt-and-braces: the agent filter (#1427) already drops dev-lead's check, and
# even if it did not, isRequired:false would exclude it from the gate.
@test "#1549 fingerprint: required green + non-required 'dev-lead / dispatch' FAILURE → passing" {
  local r
  r=$(rollup \
    "$(check_run_req "SonarCloud" "COMPLETED" "SUCCESS" true)" \
    "$(check_run_req "Lint" "COMPLETED" "SUCCESS" true)" \
    "$(check_run_req "dev-lead / dispatch" "COMPLETED" "FAILURE" false)")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

# ---------------------------------------------------------------------------
# Ruleset-derived required-set gating (#1795). The rollup's own .isRequired field
# is not reliably populated for ruleset-protected branches (a ruleset, not classic
# protection, so the field is often absent — the #1795 deadlock: the fallback then
# reverts to all-external and template-drift blocks every PR again). The authoritative
# signal is the branch ruleset's required-status-check contexts, read from the API
# and passed to compute_ci_status as a second arg. When that set is NON-EMPTY the
# gate is the UNION of (name ∈ ruleset set) OR (.isRequired == true) — never narrower
# than either source, so a genuinely-required check can never slip the gate. When the
# set is empty/absent (API unreadable — fail closed), the existing .isRequired-then-all
# fallback applies (today's behaviour).
# ---------------------------------------------------------------------------

# The five contexts the main ruleset requires today (issue #1795). Passed as the
# required-name set; template-drift is deliberately NOT among them.
REQUIRED_SET='["SonarCloud","CodeQL","agent-shield / AgentShield","dependency-audit / Detect ecosystems","duplicate-decl-gate"]'

@test "#1795 ruleset gating: all required green + non-required 'template-drift' FAILURE → passing" {
  local r
  r=$(rollup \
    "$(check_run "SonarCloud" "COMPLETED" "SUCCESS")" \
    "$(check_run "CodeQL" "COMPLETED" "SUCCESS")" \
    "$(check_run "agent-shield / AgentShield" "COMPLETED" "SUCCESS")" \
    "$(check_run "dependency-audit / Detect ecosystems" "COMPLETED" "SUCCESS")" \
    "$(check_run "duplicate-decl-gate" "COMPLETED" "SUCCESS")" \
    "$(check_run "template-drift" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r" "$REQUIRED_SET"
  [ "$output" = "passing" ]
}

@test "#1795 ruleset gating: a red REQUIRED check (name in ruleset set) → failing" {
  local r
  r=$(rollup \
    "$(check_run "SonarCloud" "COMPLETED" "FAILURE")" \
    "$(check_run "CodeQL" "COMPLETED" "SUCCESS")" \
    "$(check_run "template-drift" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r" "$REQUIRED_SET"
  [ "$output" = "failing" ]
}

@test "#1795 ruleset gating: a pending REQUIRED check → pending (non-required red ignored)" {
  local r
  r=$(rollup \
    "$(check_run "CodeQL" "IN_PROGRESS")" \
    "$(check_run "template-drift" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r" "$REQUIRED_SET"
  [ "$output" = "pending" ]
}

# The rollup does NOT carry .isRequired (the real ruleset-branch shape), yet the
# ruleset set still correctly gates only on the required contexts. This is the exact
# case #1549's .isRequired fallback could not clear.
@test "#1795 ruleset gating: no .isRequired anywhere, ruleset set supplied, only non-required red → passing" {
  local r
  r=$(rollup \
    "$(check_run "SonarCloud" "COMPLETED" "SUCCESS")" \
    "$(check_run "duplicate-decl-gate" "COMPLETED" "SUCCESS")" \
    "$(check_run "template-drift" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r" "$REQUIRED_SET"
  [ "$output" = "passing" ]
}

# Fail closed: an empty required set (API unreadable) must NOT pass a genuine failure —
# it reverts to today's all-external behaviour.
@test "#1795 ruleset gating: empty required set (fail closed) + red non-required → failing" {
  local r
  r=$(rollup \
    "$(check_run "SonarCloud" "COMPLETED" "SUCCESS")" \
    "$(check_run "template-drift" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r" '[]'
  [ "$output" = "failing" ]
}

# Union safety: even if the ruleset name set is stale/misses a context, a rollup
# entry GitHub flagged .isRequired:true is still gated (never weakens what blocks).
@test "#1795 ruleset gating: union honours .isRequired even when name not in ruleset set → failing" {
  local r
  r=$(rollup \
    "$(check_run_req "some-new-required-check" "COMPLETED" "FAILURE" true)" \
    "$(check_run "template-drift" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r" "$REQUIRED_SET"
  [ "$output" = "failing" ]
}

@test "#1795 ruleset gating: own/agent checks still filtered when ruleset set supplied" {
  local r
  r=$(rollup \
    "$(check_run "review / review" "COMPLETED" "FAILURE")" \
    "$(check_run "dev-lead / dispatch" "COMPLETED" "FAILURE")" \
    "$(check_run "SonarCloud" "COMPLETED" "SUCCESS")" \
    "$(check_run "CodeQL" "COMPLETED" "SUCCESS")" \
    "$(check_run "agent-shield / AgentShield" "COMPLETED" "SUCCESS")" \
    "$(check_run "dependency-audit / Detect ecosystems" "COMPLETED" "SUCCESS")" \
    "$(check_run "duplicate-decl-gate" "COMPLETED" "SUCCESS")" \
    "$(check_run "template-drift" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r" "$REQUIRED_SET"
  [ "$output" = "passing" ]
}

# ---------------------------------------------------------------------------
# ci_nonrequired_failures (#1795 AC #4) — names the failing external checks that
# are neither in the ruleset required set nor flagged .isRequired, so a review that
# proceeds past a red advisory check can name it (never silently ignore it).
# ---------------------------------------------------------------------------

@test "ci_nonrequired_failures: names a red non-required check" {
  local r
  r=$(rollup \
    "$(check_run "SonarCloud" "COMPLETED" "SUCCESS")" \
    "$(check_run "template-drift" "COMPLETED" "FAILURE")")
  run ci_nonrequired_failures "$r" "$REQUIRED_SET"
  [ "$output" = "template-drift" ]
}

@test "ci_nonrequired_failures: a red REQUIRED check is NOT named (it blocks, not ignored)" {
  local r
  r=$(rollup \
    "$(check_run "SonarCloud" "COMPLETED" "FAILURE")" \
    "$(check_run "template-drift" "COMPLETED" "FAILURE")")
  run ci_nonrequired_failures "$r" "$REQUIRED_SET"
  [ "$output" = "template-drift" ]
}

@test "ci_nonrequired_failures: nothing failing → empty" {
  local r
  r=$(rollup \
    "$(check_run "SonarCloud" "COMPLETED" "SUCCESS")" \
    "$(check_run "template-drift" "COMPLETED" "SUCCESS")")
  run ci_nonrequired_failures "$r" "$REQUIRED_SET"
  [ -z "$output" ]
}

@test "ci_nonrequired_failures: own/agent red checks are not named" {
  local r
  r=$(rollup \
    "$(check_run "review / review" "COMPLETED" "FAILURE")" \
    "$(check_run "dev-lead / dispatch" "COMPLETED" "FAILURE")" \
    "$(check_run "template-drift" "COMPLETED" "FAILURE")")
  run ci_nonrequired_failures "$r" "$REQUIRED_SET"
  [ "$output" = "template-drift" ]
}

# ---------------------------------------------------------------------------
# ruleset_required_checks (#1795): the required set now lives in this lib so every
# compute_ci_status caller (review-one-pr.sh, the stuck-review sweep, the
# stall/merge-ready scans) reads the SAME authoritative set — closing the deadlock
# on the callers that previously passed only the rollup and so reverted to blocking
# on red non-required checks.
# ---------------------------------------------------------------------------

# Install a gh stub on PATH that returns a required-context array from the ruleset
# endpoint (and 404s the classic-protection fallback) and records each invocation.
_install_gh_ruleset_stub() {
  GH_CALL_LOG="$BATS_TEST_TMPDIR/gh_calls.log"; : > "$GH_CALL_LOG"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$GH_CALL_LOG"
if [ "\$1" = "api" ]; then
  case "\$2" in
    *rules/branches*) printf '%s' '["SonarCloud","CodeQL"]'; exit 0 ;;
    *protection*) exit 1 ;;
  esac
fi
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "ruleset_required_checks: reads the ruleset API and returns its contexts" {
  _install_gh_ruleset_stub
  run ruleset_required_checks "petry-projects/.github-private" "main"
  [ "$output" = '["SonarCloud","CodeQL"]' ]
  grep -q 'api repos/petry-projects/.github-private/rules/branches/main' "$GH_CALL_LOG"
}

@test "ruleset_required_checks: empty repo or branch returns empty (no API call)" {
  _install_gh_ruleset_stub
  run ruleset_required_checks "" "main"
  [ -z "$output" ]
  [ ! -s "$GH_CALL_LOG" ]
}

# End-to-end #1795 for a loop caller: its required set (from ruleset_required_checks)
# fed into compute_ci_status lets a green-required PR pass even with a red
# non-required template-drift — the deadlock closed on the sweep/scan paths.
@test "ruleset_required_checks + compute_ci_status: red non-required check does not block" {
  _install_gh_ruleset_stub
  local req r
  req=$(ruleset_required_checks "petry-projects/.github-private" "main")
  r=$(rollup \
    "$(check_run "SonarCloud" "COMPLETED" "SUCCESS")" \
    "$(check_run "CodeQL" "COMPLETED" "SUCCESS")" \
    "$(check_run "template-drift" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r" "$req"
  [ "$output" = "passing" ]
}
