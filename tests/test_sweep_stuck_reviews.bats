#!/usr/bin/env bats
# Unit tests for scripts/sweep-stuck-reviews.sh (issue #573).
#
# The sweep closes the event-driven re-trigger gap: PRs that the cascade
# legitimately skipped as ci-pending/ci-failing, but whose CI later settled
# green, never get a fresh review because no event re-fires. The sweep
# enumerates open PRs, selects the ones that are REVIEW_REQUIRED + CI passing +
# not already reviewed at head, and re-dispatches pr-review-trigger.yml for each.
#
# gh is fully mocked: `gh pr view <url>` returns a per-PR fixture and
# `gh workflow run ...` is logged so we can assert on the dispatched command.
#
# Run with: bats tests/test_sweep_stuck_reviews.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/sweep-stuck-reviews.sh"

setup() {
  MOCK_BIN="$(mktemp -d)"
  FIXTURE_DIR="$(mktemp -d)"
  GH_LOG="$(mktemp)"
  PRS_FILE="$(mktemp)"
  export MOCK_BIN FIXTURE_DIR GH_LOG
  export PATH="$MOCK_BIN:$PATH"
  export SWEEP_PRS_FILE="$PRS_FILE"
  export AGENT_REPO="combsmith/.github-private"

  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  pr)
    # gh pr view <url> --json ...
    if [ "$2" = "view" ]; then
      url="$3"
      num="${url##*/}"
      f="$FIXTURE_DIR/pr_${num}.json"
      if [ -f "$f" ]; then cat "$f"; exit 0; fi
      echo "no fixture for $url" >&2
      exit 1
    fi
    ;;
  workflow)
    printf '%s\n' "$*" >> "$GH_LOG"
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$MOCK_BIN/gh"
}

teardown() {
  rm -rf "${MOCK_BIN:-}" "${FIXTURE_DIR:-}"
  rm -f "${GH_LOG:-}" "${PRS_FILE:-}"
}

# write_pr <num> <reviewDecision> <rollup-json> [head] [reviews-json] [comments-json] [labels-json]
# labels-json is a JSON array of label-name strings (default: none).
write_pr() {
  local num="$1" decision="$2" rollup="$3" head="${4-deadbeef}" reviews="${5:-[]}" comments="${6:-[]}" labels="${7:-[]}"
  jq -n --arg d "$decision" --argjson r "$rollup" --arg h "$head" \
        --argjson rv "$reviews" --argjson cm "$comments" --argjson lb "$labels" \
    '{headRefOid:$h, reviewDecision:$d, statusCheckRollup:$r, reviews:$rv, comments:$cm, labels:($lb | map({name:.}))}' \
    > "$FIXTURE_DIR/pr_${num}.json"
}

# Common rollups
ROLLUP_PASS='[{"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]'
ROLLUP_PENDING='[{"name":"CI","status":"IN_PROGRESS","conclusion":null}]'
ROLLUP_FAIL='[{"name":"CI","status":"COMPLETED","conclusion":"FAILURE"}]'
# Own pr-review check still pending alongside a green external check.
ROLLUP_OWN_PENDING='[{"name":"review","status":"IN_PROGRESS","conclusion":null},{"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]'

url_for() { echo "https://github.com/combsmith/demo/pull/$1"; }

@test "stuck-green PR (REVIEW_REQUIRED + passing + no marker) is dispatched" {
  write_pr 569 "REVIEW_REQUIRED" "$ROLLUP_PASS"
  url_for 569 > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF "workflow run pr-review-trigger.yml" "$GH_LOG"
  grep -qF -- "--repo combsmith/.github-private" "$GH_LOG"
  grep -qF -- "-f pr_url=$(url_for 569)" "$GH_LOG"
}

@test "PR with CI still pending is NOT dispatched" {
  write_pr 570 "REVIEW_REQUIRED" "$ROLLUP_PENDING"
  url_for 570 > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "PR with CI failing is NOT dispatched" {
  write_pr 571 "REVIEW_REQUIRED" "$ROLLUP_FAIL"
  url_for 571 > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "PR that is not REVIEW_REQUIRED is NOT dispatched" {
  write_pr 572 "APPROVED" "$ROLLUP_PASS"
  url_for 572 > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "PR already reviewed at head (marker present) is NOT dispatched" {
  local comments='[{"body":"<!-- pr-review-agent v1 sha=deadbeef --> <!-- decision=fix-requested risk=low -->"}]'
  write_pr 573 "REVIEW_REQUIRED" "$ROLLUP_PASS" "deadbeef" "[]" "$comments"
  url_for 573 > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "marker for a DIFFERENT (stale) head does not block re-dispatch" {
  local comments='[{"body":"<!-- pr-review-agent v1 sha=0ldsha00 -->"}]'
  write_pr 574 "REVIEW_REQUIRED" "$ROLLUP_PASS" "deadbeef" "[]" "$comments"
  url_for 574 > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f pr_url=$(url_for 574)" "$GH_LOG"
}

@test "own pr-review pending check is filtered — green external still dispatches" {
  write_pr 575 "REVIEW_REQUIRED" "$ROLLUP_OWN_PENDING"
  url_for 575 > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f pr_url=$(url_for 575)" "$GH_LOG"
}

@test "DRY_RUN=true selects but does not dispatch" {
  write_pr 576 "REVIEW_REQUIRED" "$ROLLUP_PASS"
  url_for 576 > "$SWEEP_PRS_FILE"
  export DRY_RUN=true

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
  [[ "$output" == *"$(url_for 576)"* ]]
}

@test "MAX_DISPATCH caps the number of dispatches" {
  write_pr 580 "REVIEW_REQUIRED" "$ROLLUP_PASS" "sha580"
  write_pr 581 "REVIEW_REQUIRED" "$ROLLUP_PASS" "sha581"
  { url_for 580; url_for 581; } > "$SWEEP_PRS_FILE"
  export MAX_DISPATCH=1

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'workflow run' "$GH_LOG")" -eq 1 ]
}

@test "mixed batch: only the stuck-green PR is dispatched" {
  write_pr 590 "REVIEW_REQUIRED" "$ROLLUP_PASS"   "sha590"   # stuck-green
  write_pr 591 "REVIEW_REQUIRED" "$ROLLUP_PENDING" "sha591"  # pending
  write_pr 592 "APPROVED"        "$ROLLUP_PASS"    "sha592"  # already approved
  { url_for 590; url_for 591; url_for 592; } > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'workflow run' "$GH_LOG")" -eq 1 ]
  grep -qF -- "-f pr_url=$(url_for 590)" "$GH_LOG"
}

@test "a PR that cannot be fetched is skipped without aborting the sweep" {
  # 595 has no fixture (gh pr view fails); 596 is stuck-green and must still run.
  write_pr 596 "REVIEW_REQUIRED" "$ROLLUP_PASS" "sha596"
  { url_for 595; url_for 596; } > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f pr_url=$(url_for 596)" "$GH_LOG"
}

@test "empty candidate list is a clean no-op" {
  : > "$SWEEP_PRS_FILE"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

# ───────────────────────────────────────────────────────────────────────────
# Escalated-PR skip (issue #946)
#
# A PR that hit the per-PR automation budget (#928) carries the
# needs-human-review label (and the cascade has paused). The sweep must NOT
# re-review it — re-dispatching would re-ignite the runaway the breaker stops
# (the #860 "amplifier" failure mode). Re-engagement is human-gated: a human
# removing the label re-enables the sweep, even though the immutable
# `<!-- pr-automation-budget exhausted -->` marker comment remains.
# ───────────────────────────────────────────────────────────────────────────

@test "escalated PR (needs-human-review label) is NOT re-reviewed even when stuck-green (#946)" {
  write_pr 946 "REVIEW_REQUIRED" "$ROLLUP_PASS" "sha946" "[]" "[]" '["needs-human-review"]'
  url_for 946 > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
  [[ "$output" == *"needs-human-review"* ]]
}

@test "removing needs-human-review re-enables the sweep despite a lingering budget marker (#946 AC3)" {
  # No label (human removed it) but the exhaustion marker comment still exists.
  # Gating on the label — not the marker — means this stuck-green PR re-dispatches.
  local comments='[{"body":"<!-- pr-automation-budget exhausted -->\n\nbudget note"}]'
  write_pr 947 "REVIEW_REQUIRED" "$ROLLUP_PASS" "sha947" "[]" "$comments" '[]'
  url_for 947 > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f pr_url=$(url_for 947)" "$GH_LOG"
}

@test "passes GITHUB_REF when it is a branch (feature-branch testing)" {
  write_pr 600 "REVIEW_REQUIRED" "$ROLLUP_PASS" "sha600"
  url_for 600 > "$SWEEP_PRS_FILE"
  export GITHUB_REF="refs/heads/feature-x"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "--ref refs/heads/feature-x" "$GH_LOG"
}

@test "ignores GITHUB_REF when it is a pull-request ref" {
  write_pr 601 "REVIEW_REQUIRED" "$ROLLUP_PASS" "sha601"
  url_for 601 > "$SWEEP_PRS_FILE"
  export GITHUB_REF="refs/pull/12/merge"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -qF -- "--ref" "$GH_LOG"
}

# ───────────────────────────────────────────────────────────────────────────
# Rate-limited withhold retry (issue #711)
#
# A pr-review run that withholds approval because advisory bots were
# rate-limited leaves a distinct marker:
#   <!-- pr-review-agent rate-limited v1 sha=<HEAD> status=rate-limited reset=<ISO> -->
# Once the embedded reset has passed (and the PR has NOT since been reviewed at
# head), the sweep re-dispatches it — even when the CI rollup is not "passing"
# (unrelated cancelled/failed sibling checks must not suppress the retry).
# ───────────────────────────────────────────────────────────────────────────

# rl_comment <head> <reset-iso>: a rate-limited withhold marker comment body.
rl_comment() {
  printf '[{"body":"<!-- pr-review-agent rate-limited v1 sha=%s status=rate-limited reset=%s -->\\n\\nAdvisory bots were rate-limited."}]' "$1" "$2"
}
PAST_RESET='2000-01-01T00:00:00Z'
FUTURE_RESET='2999-01-01T00:00:00Z'

@test "rate-limited marker with elapsed reset is re-dispatched (CI passing)" {
  write_pr 711 "REVIEW_REQUIRED" "$ROLLUP_PASS" "rl711" "[]" "$(rl_comment rl711 "$PAST_RESET")"
  url_for 711 > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f pr_url=$(url_for 711)" "$GH_LOG"
  # Retry uses the normal trigger path — never force_review (the advisory gate
  # must stay armed so we never approve while bots are still rate-limited).
  ! grep -qF -- "force_review" "$GH_LOG"
}

@test "rate-limited retry fires even when a sibling check is FAILING (issue #711 AC3)" {
  write_pr 712 "REVIEW_REQUIRED" "$ROLLUP_FAIL" "rl712" "[]" "$(rl_comment rl712 "$PAST_RESET")"
  url_for 712 > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f pr_url=$(url_for 712)" "$GH_LOG"
}

@test "rate-limited retry fires even when a sibling check is CANCELLED" {
  local rollup_cancelled='[{"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"dev-lead / dispatch","status":"COMPLETED","conclusion":"CANCELLED"}]'
  write_pr 713 "REVIEW_REQUIRED" "$rollup_cancelled" "rl713" "[]" "$(rl_comment rl713 "$PAST_RESET")"
  url_for 713 > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f pr_url=$(url_for 713)" "$GH_LOG"
}

@test "rate-limited marker whose reset is still in the future is NOT re-dispatched" {
  write_pr 714 "REVIEW_REQUIRED" "$ROLLUP_PASS" "rl714" "[]" "$(rl_comment rl714 "$FUTURE_RESET")"
  url_for 714 > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "rate-limited marker is ignored once the PR has been reviewed at head" {
  # An idempotency marker at the same head means a real review already landed —
  # the rate-limited state is resolved, so the retry must NOT fire.
  local comments
  comments='[{"body":"<!-- pr-review-agent rate-limited v1 sha=rl715 status=rate-limited reset=2000-01-01T00:00:00Z -->"},{"body":"<!-- pr-review-agent v1 sha=rl715 --> reviewed"}]'
  write_pr 715 "REVIEW_REQUIRED" "$ROLLUP_PASS" "rl715" "[]" "$comments"
  url_for 715 > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "rate-limited marker for a DIFFERENT (stale) head does not trigger a retry" {
  # Marker is for an old head; current head has no marker and CI is failing, so
  # neither the rate-limited branch nor the normal stuck-green branch fires.
  write_pr 716 "REVIEW_REQUIRED" "$ROLLUP_FAIL" "rl716NEW" "[]" "$(rl_comment rl716OLD "$PAST_RESET")"
  url_for 716 > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "rate-limited retry honours DRY_RUN" {
  write_pr 717 "REVIEW_REQUIRED" "$ROLLUP_FAIL" "rl717" "[]" "$(rl_comment rl717 "$PAST_RESET")"
  url_for 717 > "$SWEEP_PRS_FILE"
  export DRY_RUN=true

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
  [[ "$output" == *"$(url_for 717)"* ]]
}

# ---------------------------------------------------------------------------
# Event-driven fast path (#898): a `workflow_run: completed` kick scopes the
# sweep to the completing run's PR(s) via the event payload, so a PR that just
# went green is re-reviewed in seconds instead of waiting for the cron backstop.
# The same REVIEW_REQUIRED + CI-green + not-reviewed-at-head gate still decides.
# ---------------------------------------------------------------------------

# write_event <file> <repo_full_name> <pr-numbers-json-array>
write_event() {
  local file="$1" repo="$2" prs="$3"
  jq -n --arg repo "$repo" --argjson prs "$prs" \
    '{repository:{full_name:$repo}, workflow_run:{pull_requests: ($prs | map({number: .}))}}' \
    > "$file"
}

# In the event path the script derives the PR url as
# https://github.com/<repo>/pull/<N>; the gh mock keys the fixture off the
# trailing <N>, so pr_<N>.json must exist.
ghp_event_url() { echo "https://github.com/combsmith/.github-private/pull/$1"; }

@test "workflow_run kick: ci-pending→green PR (REVIEW_REQUIRED + green + no marker) is dispatched, scoped to the event" {
  unset SWEEP_PRS_FILE
  local ev="$FIXTURE_DIR/event.json"
  write_event "$ev" "combsmith/.github-private" '[898]'
  export GITHUB_EVENT_NAME=workflow_run
  export GITHUB_EVENT_PATH="$ev"
  write_pr 898 "REVIEW_REQUIRED" "$ROLLUP_PASS" "greensha"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF "workflow run pr-review-trigger.yml" "$GH_LOG"
  grep -qF -- "-f pr_url=$(ghp_event_url 898)" "$GH_LOG"
}

@test "workflow_run kick: empty pull_requests (fork PR / branch push) is a clean no-op" {
  unset SWEEP_PRS_FILE
  local ev="$FIXTURE_DIR/event.json"
  write_event "$ev" "combsmith/.github-private" '[]'
  export GITHUB_EVENT_NAME=workflow_run
  export GITHUB_EVENT_PATH="$ev"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "workflow_run kick: event PR with CI still pending is NOT dispatched (too-early fire backstopped by cron)" {
  unset SWEEP_PRS_FILE
  local ev="$FIXTURE_DIR/event.json"
  write_event "$ev" "combsmith/.github-private" '[899]'
  export GITHUB_EVENT_NAME=workflow_run
  export GITHUB_EVENT_PATH="$ev"
  write_pr 899 "REVIEW_REQUIRED" "$ROLLUP_PENDING" "pendsha"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "workflow_run kick: already-reviewed-at-head event PR is NOT re-dispatched" {
  unset SWEEP_PRS_FILE
  local ev="$FIXTURE_DIR/event.json"
  write_event "$ev" "combsmith/.github-private" '[900]'
  export GITHUB_EVENT_NAME=workflow_run
  export GITHUB_EVENT_PATH="$ev"
  local comments='[{"body":"<!-- pr-review-agent v1 sha=donesha --> reviewed"}]'
  write_pr 900 "REVIEW_REQUIRED" "$ROLLUP_PASS" "donesha" "[]" "$comments"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "workflow_run kick: multiple PRs on the run are each evaluated" {
  unset SWEEP_PRS_FILE
  local ev="$FIXTURE_DIR/event.json"
  write_event "$ev" "combsmith/.github-private" '[901,902]'
  export GITHUB_EVENT_NAME=workflow_run
  export GITHUB_EVENT_PATH="$ev"
  write_pr 901 "REVIEW_REQUIRED" "$ROLLUP_PASS" "g901"          # green → dispatch
  write_pr 902 "REVIEW_REQUIRED" "$ROLLUP_FAIL" "f902"          # failing → skip

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f pr_url=$(ghp_event_url 901)" "$GH_LOG"
  ! grep -qF -- "-f pr_url=$(ghp_event_url 902)" "$GH_LOG"
}

# ───────────────────────────────────────────────────────────────────────────
# Scheduled-path narrowing (#1408): on the schedule (cron) event the sweep is
# the GUARANTEED backstop for genuinely un-eventable cases — GitHub-App /
# cross-repo checks like SonarCloud that emit no workflow_run (no workflowName in
# the rollup). A PR whose green state is fully determined by EVENTABLE GitHub
# Actions checks (each carrying a workflowName) belongs to the workflow_run fast
# path, so the cron must NOT re-dispatch it. The narrowing is scheduled-only:
# the fast path, workflow_dispatch, and explicit-file paths are unchanged.
# ───────────────────────────────────────────────────────────────────────────

# Eventable rollup: every passing check is a GitHub Actions check (workflowName).
ROLLUP_PASS_EVENTABLE='[{"name":"build","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]'
# Un-eventable rollup: a SonarCloud-style check with no workflowName (emits no
# workflow_run this repo can key on) — only the cron re-reviews it.
ROLLUP_PASS_UNEVENTABLE='[{"context":"SonarCloud","state":"SUCCESS"}]'
# Mixed: an eventable CI check plus the un-eventable SonarCloud residue.
ROLLUP_PASS_MIXED='[{"name":"build","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS"},{"context":"SonarCloud","state":"SUCCESS"}]'

@test "scheduled path: stuck-green PR with ONLY eventable checks is NOT dispatched (fast path owns it)" {
  write_pr 1408 "REVIEW_REQUIRED" "$ROLLUP_PASS_EVENTABLE" "evt1408"
  url_for 1408 > "$SWEEP_PRS_FILE"
  export GITHUB_EVENT_NAME=schedule

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "scheduled path: stuck-green PR with an un-eventable (SonarCloud) check IS dispatched" {
  write_pr 1409 "REVIEW_REQUIRED" "$ROLLUP_PASS_UNEVENTABLE" "unev1409"
  url_for 1409 > "$SWEEP_PRS_FILE"
  export GITHUB_EVENT_NAME=schedule

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f pr_url=$(url_for 1409)" "$GH_LOG"
}

@test "scheduled path: mixed eventable + un-eventable residue IS dispatched" {
  write_pr 1410 "REVIEW_REQUIRED" "$ROLLUP_PASS_MIXED" "mix1410"
  url_for 1410 > "$SWEEP_PRS_FILE"
  export GITHUB_EVENT_NAME=schedule

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f pr_url=$(url_for 1410)" "$GH_LOG"
}

@test "scheduled path: mixed batch keeps only the un-eventable residue on the cron" {
  write_pr 1411 "REVIEW_REQUIRED" "$ROLLUP_PASS_EVENTABLE"   "evt1411"   # fast-path → skip on cron
  write_pr 1412 "REVIEW_REQUIRED" "$ROLLUP_PASS_UNEVENTABLE" "unev1412"  # un-eventable → dispatch
  { url_for 1411; url_for 1412; } > "$SWEEP_PRS_FILE"
  export GITHUB_EVENT_NAME=schedule

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'workflow run' "$GH_LOG")" -eq 1 ]
  grep -qF -- "-f pr_url=$(url_for 1412)" "$GH_LOG"
  run grep -qF -- "-f pr_url=$(url_for 1411)" "$GH_LOG"
  [ "$status" -eq 1 ]
}

@test "fast path is UNCHANGED: workflow_run kick dispatches an eventable-only PR" {
  # The narrowing must not touch the fast path — a PR that just went green on an
  # eventable CI workflow is exactly what the workflow_run path is for.
  unset SWEEP_PRS_FILE
  local ev="$FIXTURE_DIR/event.json"
  write_event "$ev" "combsmith/.github-private" '[1413]'
  export GITHUB_EVENT_NAME=workflow_run
  export GITHUB_EVENT_PATH="$ev"
  write_pr 1413 "REVIEW_REQUIRED" "$ROLLUP_PASS_EVENTABLE" "evt1413"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f pr_url=$(ghp_event_url 1413)" "$GH_LOG"
}

@test "non-scheduled path is UNCHANGED: eventable-only PR still dispatches (no narrowing)" {
  # Default invocation (no GITHUB_EVENT_NAME) is not the scheduled backstop, so
  # the un-eventable narrowing must not apply.
  write_pr 1414 "REVIEW_REQUIRED" "$ROLLUP_PASS_EVENTABLE" "evt1414"
  url_for 1414 > "$SWEEP_PRS_FILE"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f pr_url=$(url_for 1414)" "$GH_LOG"
}

# ───────────────────────────────────────────────────────────────────────────
# Rate-limit retry + scheduled narrowing (#1408 + #711 interaction)
#
# When the scheduled sweep encounters a PR with an elapsed rate-limit marker it
# must still apply the un-eventable narrowing before dispatching: an eventable-only
# PR should be skipped (the workflow_run fast path covers it once the rate limit
# clears), while a PR with any un-eventable check must be re-dispatched.
# ───────────────────────────────────────────────────────────────────────────

@test "scheduled path: rate-limited marker (elapsed) with eventable-only rollup is NOT dispatched (#1408+#711)" {
  write_pr 1415 "REVIEW_REQUIRED" "$ROLLUP_PASS_EVENTABLE" "rl1415" "[]" "$(rl_comment rl1415 "$PAST_RESET")"
  url_for 1415 > "$SWEEP_PRS_FILE"
  export GITHUB_EVENT_NAME=schedule

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
  [[ "$output" == *"un-eventable-only"* ]]
}

@test "scheduled path: rate-limited marker (elapsed) with un-eventable rollup IS dispatched" {
  write_pr 1416 "REVIEW_REQUIRED" "$ROLLUP_PASS_UNEVENTABLE" "rl1416" "[]" "$(rl_comment rl1416 "$PAST_RESET")"
  url_for 1416 > "$SWEEP_PRS_FILE"
  export GITHUB_EVENT_NAME=schedule

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f pr_url=$(url_for 1416)" "$GH_LOG"
}

@test "non-scheduled path: rate-limited retry with eventable-only rollup still dispatches (narrowing is schedule-only)" {
  write_pr 1417 "REVIEW_REQUIRED" "$ROLLUP_PASS_EVENTABLE" "rl1417" "[]" "$(rl_comment rl1417 "$PAST_RESET")"
  url_for 1417 > "$SWEEP_PRS_FILE"
  # No GITHUB_EVENT_NAME → not the scheduled backstop → narrowing must not apply.

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "-f pr_url=$(url_for 1417)" "$GH_LOG"
}
