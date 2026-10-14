#!/usr/bin/env bats
# Unit tests for the per-PR automated-churn circuit breaker
# (scripts/lib/pr-automation-budget.sh, issue #926).
#
# The breaker bounds TOTAL automated activity on one PR over its lifetime:
# agent-authored commits + review cycles + acks since the last *human*
# interaction. Its reset is human-gated — a machine event (bot comment, bot
# commit, machine approval) must never reset the budget; only a human action
# does. This is the guard that PR #860 lacked (378 commits / 1,582 comments
# produced entirely by agents looping, with no human in the thread).
#
# Run with: bats tests/test_pr_automation_budget.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/pr-automation-budget.sh"
}

# Build a {when, login} activity event.
ev() {  # ev <when> <login>
  jq -n --arg when "$1" --arg login "$2" '{when: $when, login: $login}'
}
events() {  # events <event-json>...
  printf '%s\n' "$@" | jq -s '.'
}

BOT="donpetry-bot"
APP="github-actions[bot]"
HUMAN="alice"

# ---------------------------------------------------------------------------
# compute_pr_automation_cycles: basics / defensive degradation
# ---------------------------------------------------------------------------

@test "empty array counts 0" {
  run compute_pr_automation_cycles '[]'
  [ "$output" = "0" ]
}

@test "missing argument counts 0" {
  run compute_pr_automation_cycles
  [ "$output" = "0" ]
}

@test "malformed JSON degrades to 0, not an error" {
  run compute_pr_automation_cycles 'not json'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "items with null/empty timestamps are ignored, not fatal" {
  local j
  j=$(events \
    "$(jq -n --arg l "$BOT" '{when:null, login:$l}')" \
    "$(ev 2026-06-24T01:00:00Z "$BOT")")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# compute_pr_automation_cycles: counting agent activity
# ---------------------------------------------------------------------------

@test "all bot events with no human interaction all count" {
  local j
  j=$(events \
    "$(ev 2026-06-24T01:00:00Z "$BOT")" \
    "$(ev 2026-06-24T01:00:09Z "$BOT")" \
    "$(ev 2026-06-24T01:00:18Z "$APP")")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "3" ]
}

@test "human events never count toward the budget" {
  local j
  j=$(events \
    "$(ev 2026-06-24T01:00:00Z "$HUMAN")" \
    "$(ev 2026-06-24T02:00:00Z "$HUMAN")")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# compute_pr_automation_cycles: human-gated reset (the core guarantee)
# ---------------------------------------------------------------------------

@test "a human interaction resets the budget: only bot events AFTER it count" {
  local j
  j=$(events \
    "$(ev 2026-06-24T01:00:00Z "$BOT")" \
    "$(ev 2026-06-24T02:00:00Z "$HUMAN")" \
    "$(ev 2026-06-24T03:00:00Z "$BOT")" \
    "$(ev 2026-06-24T04:00:00Z "$BOT")")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "2" ]
}

@test "a trailing human interaction zeroes the budget" {
  local j
  j=$(events \
    "$(ev 2026-06-24T01:00:00Z "$BOT")" \
    "$(ev 2026-06-24T02:00:00Z "$BOT")" \
    "$(ev 2026-06-24T03:00:00Z "$HUMAN")")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "0" ]
}

@test "latest human interaction wins among several" {
  local j
  j=$(events \
    "$(ev 2026-06-24T01:00:00Z "$HUMAN")" \
    "$(ev 2026-06-24T02:00:00Z "$BOT")" \
    "$(ev 2026-06-24T03:00:00Z "$HUMAN")" \
    "$(ev 2026-06-24T04:00:00Z "$BOT")")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# compute_pr_automation_cycles: bot identity detection
# ---------------------------------------------------------------------------

@test "any login ending in [bot] is treated as a bot" {
  local j
  j=$(events "$(ev 2026-06-24T01:00:00Z "dependabot[bot]")")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "1" ]
}

@test "AUTOMATION_BOT_LOGINS is honoured for non-suffixed bot accounts" {
  local j
  j=$(events \
    "$(ev 2026-06-24T01:00:00Z "repair-approvals")" \
    "$(ev 2026-06-24T02:00:00Z "$HUMAN")")
  AUTOMATION_BOT_LOGINS="donpetry-bot repair-approvals" run compute_pr_automation_cycles "$j"
  # repair-approvals counts as bot (before human reset) -> after human reset = 0
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# pr_budget_exhausted: threshold behaviour
# ---------------------------------------------------------------------------

mk_bot_events() {  # mk_bot_events <count>
  local n="$1" i=0 out=()
  while [ "$i" -lt "$n" ]; do
    out+=("$(ev "2026-06-24T01:00:$(printf '%02d' "$i")Z" "$BOT")")
    i=$((i + 1))
  done
  events "${out[@]}"
}

@test "below threshold is not exhausted (exit 1)" {
  run pr_budget_exhausted "$(mk_bot_events 9)"
  [ "$status" -ne 0 ]
}

@test "reaching MAX_PR_AUTOMATION_CYCLES is exhausted (exit 0)" {
  run pr_budget_exhausted "$(mk_bot_events 10)"
  [ "$status" -eq 0 ]
}

@test "MAX_PR_AUTOMATION_CYCLES override is respected" {
  MAX_PR_AUTOMATION_CYCLES=3 run pr_budget_exhausted "$(mk_bot_events 3)"
  [ "$status" -eq 0 ]
  MAX_PR_AUTOMATION_CYCLES=3 run pr_budget_exhausted "$(mk_bot_events 2)"
  [ "$status" -ne 0 ]
}

@test "a human interaction rescues a PR from exhaustion" {
  local many j
  many=$(mk_bot_events 20)
  # Append a trailing human event -> resets to 0 -> not exhausted.
  j=$(echo "$many" | jq --arg l "$HUMAN" '. + [{when:"2026-06-25T00:00:00Z", login:$l}]')
  run pr_budget_exhausted "$j"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# pr_has_escalation_label: the human-controlled re-engagement gate (#946)
#
# The retry/sweep crons skip a PR while it carries the needs-human-review label
# (added by this breaker on exhaustion). Gating on the LABEL — not the immutable
# exhaustion marker comment — is what lets a human re-engage by removing it.
# ---------------------------------------------------------------------------

@test "pr_has_escalation_label: needs-human-review present → exit 0" {
  run pr_has_escalation_label '["bug","needs-human-review","p1"]'
  [ "$status" -eq 0 ]
}

@test "pr_has_escalation_label: label absent → exit 1" {
  run pr_has_escalation_label '["bug","enhancement"]'
  [ "$status" -ne 0 ]
}

@test "pr_has_escalation_label: empty array → exit 1 (not escalated)" {
  run pr_has_escalation_label '[]'
  [ "$status" -ne 0 ]
}

@test "pr_has_escalation_label: missing argument → exit 1 (not escalated)" {
  run pr_has_escalation_label
  [ "$status" -ne 0 ]
}

@test "pr_has_escalation_label: malformed JSON degrades to not-escalated (exit 1)" {
  run pr_has_escalation_label 'not json'
  [ "$status" -ne 0 ]
}

@test "pr_has_escalation_label: NEEDS_HUMAN_REVIEW_LABEL override is honoured" {
  NEEDS_HUMAN_REVIEW_LABEL="paused" run pr_has_escalation_label '["paused"]'
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# pr_resume_suppressed: the single stop-condition both the event-first resume
# (scripts/dev-lead-resume.sh) and the safety-net cron (scripts/dev-lead-retry.sh)
# consult before re-dispatching a blocked/rate-limited state (#1407 AC #3). It
# must SUPPRESS (exit 0 = do not resume) when the PR is human-gated OR its
# per-PR automation budget is exhausted, so neither path can re-ignite the #860
# amplifier. labels_json + events_json are injected here to keep the unit test
# hermetic (no gh network); the callers pass what they already fetched.
# ---------------------------------------------------------------------------

@test "pr_resume_suppressed: needs-human-review label → suppress (exit 0)" {
  run pr_resume_suppressed 860 combsmith/demo '["needs-human-review"]' '[]'
  [ "$status" -eq 0 ]
}

@test "pr_resume_suppressed: exhausted budget (no label) → suppress (exit 0)" {
  run pr_resume_suppressed 860 combsmith/demo '["bug"]' "$(mk_bot_events 10)"
  [ "$status" -eq 0 ]
}

@test "pr_resume_suppressed: clean labels + budget remaining → proceed (exit 1)" {
  run pr_resume_suppressed 860 combsmith/demo '["bug"]' "$(mk_bot_events 3)"
  [ "$status" -ne 0 ]
}

@test "pr_resume_suppressed: human label wins even with budget remaining" {
  run pr_resume_suppressed 860 combsmith/demo '["needs-human-review"]' "$(mk_bot_events 1)"
  [ "$status" -eq 0 ]
}

@test "pr_resume_suppressed: FORCE_REVIEW must not bypass the budget" {
  FORCE_REVIEW=true run pr_resume_suppressed 860 combsmith/demo '["bug"]' "$(mk_bot_events 10)"
  [ "$status" -eq 0 ]
}

@test "pr_resume_suppressed: API failure in gather_pr_automation_events → suppress (fail-closed)" {
  # When the GitHub API is unavailable, gather_pr_automation_events exits 1.
  # pr_resume_suppressed must suppress (return 0) rather than proceeding with
  # an unproven budget — prevents runaway automation during outages.
  gather_pr_automation_events() { return 1; }
  # No events_json passed so pr_resume_suppressed calls gather_pr_automation_events.
  run pr_resume_suppressed 860 combsmith/demo '[]'
  [ "$status" -eq 0 ]
}

@test "gather_pr_automation_events: any API failure propagates as exit 1" {
  # Use a PATH-based gh stub so the mock is visible inside the run subshell.
  cat > "$BATS_TEST_TMPDIR/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *commits*) exit 1 ;;
  *) printf '[]' ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/gh"
  PATH="$BATS_TEST_TMPDIR:$PATH" run gather_pr_automation_events 860 combsmith/demo
  [ "$status" -ne 0 ]
}
