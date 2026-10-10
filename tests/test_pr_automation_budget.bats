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
  run pr_resume_suppressed 860 petry-projects/demo '["needs-human-review"]' '[]'
  [ "$status" -eq 0 ]
}

@test "pr_resume_suppressed: exhausted budget (no label) → suppress (exit 0)" {
  run pr_resume_suppressed 860 petry-projects/demo '["bug"]' "$(mk_bot_events 10)"
  [ "$status" -eq 0 ]
}

@test "pr_resume_suppressed: clean labels + budget remaining → proceed (exit 1)" {
  run pr_resume_suppressed 860 petry-projects/demo '["bug"]' "$(mk_bot_events 3)"
  [ "$status" -ne 0 ]
}

@test "pr_resume_suppressed: human label wins even with budget remaining" {
  run pr_resume_suppressed 860 petry-projects/demo '["needs-human-review"]' "$(mk_bot_events 1)"
  [ "$status" -eq 0 ]
}

@test "pr_resume_suppressed(#2089): dev-lead:hands-off → suppress without reading budget events" {
  # The budget gate is stubbed to "not exhausted" and the events are unreadable,
  # so only the hold itself can suppress: it must short-circuit before the budget.
  pr_budget_exhausted() { return 1; }
  gather_pr_automation_events() { echo "events read" >&2; return 1; }
  run pr_resume_suppressed 2085 petry-projects/demo '["bug","dev-lead:hands-off"]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"carries dev-lead:hands-off"* ]]
  [[ "$output" != *"events read"* ]]
}

@test "pr_resume_suppressed(#2089 review): an unreadable label set suppresses (fail closed)" {
  pr_budget_exhausted() { return 1; }
  local bad
  for bad in 'not json' 'null' '{"labels":[]}'; do
    run pr_resume_suppressed 2085 petry-projects/demo "$bad" '[]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"labels unavailable"* ]]
  done
  # A failed label fetch (labels not passed in) suppresses too — never read as `[]`.
  gh() { return 1; }
  run pr_resume_suppressed 2085 petry-projects/demo '' '[]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"labels unavailable"* ]]
  # …while a label set that was read and is empty still proceeds.
  run pr_resume_suppressed 2085 petry-projects/demo '[]' '[]'
  [ "$status" -ne 0 ]
}

@test "pr_resume_suppressed(#2089): dev-lead:needs-human → suppress" {
  run pr_resume_suppressed 2085 petry-projects/demo '["dev-lead:needs-human"]' "$(mk_bot_events 1)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"carries dev-lead:needs-human"* ]]
}

@test "pr_resume_suppressed(#2089): needs-human-review keeps its #946 message" {
  run pr_resume_suppressed 2085 petry-projects/demo '["dev-lead:hands-off","needs-human-review"]' '[]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"carries needs-human-review — human-gated; not resuming (#946)"* ]]
}

@test "pr_resume_suppressed(#2089): a label merely containing a hold name does not suppress" {
  run pr_resume_suppressed 2085 petry-projects/demo '["dev-lead:hands-off-later","x-dev-lead:needs-human"]' "$(mk_bot_events 1)"
  [ "$status" -ne 0 ]
}

@test "pr_hold_gate_label(#2089): prints the held label; malformed input is not held" {
  run pr_hold_gate_label '["bug","dev-lead:hands-off"]'
  [ "$status" -eq 0 ]
  [ "$output" = "dev-lead:hands-off" ]
  run pr_hold_gate_label 'not json'
  [ "$status" -ne 0 ]
  run pr_hold_gate_label '[]'
  [ "$status" -ne 0 ]
}

@test "pr_resume_suppressed: FORCE_REVIEW must not bypass the budget" {
  FORCE_REVIEW=true run pr_resume_suppressed 860 petry-projects/demo '["bug"]' "$(mk_bot_events 10)"
  [ "$status" -eq 0 ]
}

@test "pr_resume_suppressed: API failure in gather_pr_automation_events → suppress (fail-closed)" {
  # When the GitHub API is unavailable, gather_pr_automation_events exits 1.
  # pr_resume_suppressed must suppress (return 0) rather than proceeding with
  # an unproven budget — prevents runaway automation during outages.
  gather_pr_automation_events() { return 1; }
  # No events_json passed so pr_resume_suppressed calls gather_pr_automation_events.
  run pr_resume_suppressed 860 petry-projects/demo '[]'
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
  PATH="$BATS_TEST_TMPDIR:$PATH" run gather_pr_automation_events 860 petry-projects/demo
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# pr_hold_kind — classify WHY a needs-human-review PR is held so the sweep can
# log the honored hold (#1550 AC#5) and exempt the rate-limit-only hold whose
# recovery it must not disable (#1550 AC#1/#3). Genuine escalations take
# precedence over a co-present rate-limit marker (AC#3).
# ---------------------------------------------------------------------------

# items <body>...  → JSON array of {body} objects (reviews + comments shape).
items() { printf '%s\n' "$@" | jq -R '{body: .}' | jq -s '.'; }

RL_AT() {  # RL_AT <head> → a rate-limited withhold marker body at <head>
  printf '<!-- pr-review-agent rate-limited v1 sha=%s status=rate-limited reset=2000-01-01T00:00:00Z -->' "$1"
}

@test "pr_hold_kind: budget-exhaustion marker wins" {
  local j; j=$(items "<!-- pr-automation-budget exhausted -->" "$(RL_AT deadbeef)")
  run pr_hold_kind "$j" deadbeef
  [ "$output" = "budget-exhaustion" ]
}

@test "pr_hold_kind: cycle-cap escalation marker wins" {
  local j; j=$(items "<!-- pr-review-agent escalation -->" "$(RL_AT deadbeef)")
  run pr_hold_kind "$j" deadbeef
  [ "$output" = "cycle-cap" ]
}

@test "pr_hold_kind: rate-limit marker at head + no escalation marker → rate-limit-only" {
  local j; j=$(items "$(RL_AT deadbeef)")
  run pr_hold_kind "$j" deadbeef
  [ "$output" = "rate-limit-only" ]
}

@test "pr_hold_kind: SHA-prefixed lookalike WITHOUT status=rate-limited is NOT rate-limit-only (spoof-resistant, #1553)" {
  # A body that quotes the marker opener + current head but omits the canonical
  # status=rate-limited field must fall through to manual (stay paused) — it must
  # not grant the rate-limit-only exemption to a user/unrelated-automation lookalike.
  local j; j=$(items "<!-- pr-review-agent rate-limited v1 sha=deadbeef spoofed, no status field -->")
  run pr_hold_kind "$j" deadbeef
  [ "$output" = "manual" ]
}

@test "pr_hold_kind: rate-limit marker for a DIFFERENT head is NOT rate-limit-only (manual)" {
  local j; j=$(items "$(RL_AT 0ldhead0)")
  run pr_hold_kind "$j" deadbeef
  [ "$output" = "manual" ]
}

@test "pr_hold_kind: no markers → manual" {
  local j; j=$(items "just a normal comment")
  run pr_hold_kind "$j" deadbeef
  [ "$output" = "manual" ]
}

@test "pr_hold_kind: budget marker present even without a rate-limit marker → budget-exhaustion" {
  local j; j=$(items "<!-- pr-automation-budget exhausted -->")
  run pr_hold_kind "$j" deadbeef
  [ "$output" = "budget-exhaustion" ]
}

@test "pr_hold_kind: empty/missing input degrades to manual" {
  run pr_hold_kind '[]' deadbeef
  [ "$output" = "manual" ]
  run pr_hold_kind
  [ "$output" = "manual" ]
}

# ---------------------------------------------------------------------------
# Dependabot merge pipeline (#2224): on a PR authored by dependabot[bot], the
# pipeline's own events — Dependabot's commit, and the dependabot-automerge
# App's `update-branch` merge commits and re-approvals — are caused by pushes to
# `main`, not by an agent reacting to an agent. They neither count nor reset.
# Every other bot on such a PR, and the same App on anyone else's PR, counts as
# before, so an agent loop on a Dependabot PR still trips the breaker.
# ---------------------------------------------------------------------------

DEPENDABOT="dependabot[bot]"
AUTOMRG="petry-projects-dependabot-automrg[bot]"

# The ten events the counter saw on petry-projects/broodminder-data#176.
bd176_events() {
  events \
    "$(ev 2026-10-08T15:33:54Z "$DEPENDABOT")" \
    "$(ev 2026-10-08T15:34:09Z "$AUTOMRG")" \
    "$(ev 2026-10-08T15:34:21Z "coderabbitai[bot]")" \
    "$(ev 2026-10-08T20:57:06Z "$AUTOMRG")" \
    "$(ev 2026-10-08T20:57:25Z "$AUTOMRG")" \
    "$(ev 2026-10-08T20:59:58Z "$AUTOMRG")" \
    "$(ev 2026-10-08T21:00:58Z "$AUTOMRG")" \
    "$(ev 2026-10-09T04:09:46Z "$AUTOMRG")" \
    "$(ev 2026-10-09T04:16:18Z "$AUTOMRG")" \
    "$(ev 2026-10-09T04:17:40Z "sonarqubecloud[bot]")"
}

@test "#2224: the #176 events on a Dependabot PR count 2, not exhausted" {
  local j; j=$(pr_budget_flag_mechanical "$(bd176_events)" "$DEPENDABOT")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "2" ]
  run pr_budget_exhausted "$j"
  [ "$status" -ne 0 ]
}

@test "#2224: the same ten events on a PR authored by anyone else count 10, exhausted" {
  local j; j=$(pr_budget_flag_mechanical "$(bd176_events)" "don-petry")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "10" ]
  run pr_budget_exhausted "$j"
  [ "$status" -eq 0 ]
}

@test "#2224: an agent looping on a Dependabot PR still exhausts the budget" {
  local j; j=$(pr_budget_flag_mechanical "$(mk_bot_events 10)" "$DEPENDABOT")
  run pr_budget_exhausted "$j"
  [ "$status" -eq 0 ]
}

@test "#2224: pipeline events after a human event count 0 and do not move the reset point" {
  local j
  j=$(pr_budget_flag_mechanical "$(events \
    "$(ev 2026-10-08T01:00:00Z "$BOT")" \
    "$(ev 2026-10-08T02:00:00Z "$HUMAN")" \
    "$(ev 2026-10-08T03:00:00Z "$AUTOMRG")" \
    "$(ev 2026-10-08T04:00:00Z "$AUTOMRG")")" "$DEPENDABOT")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "0" ]
  # The reset point is still the human event: a bot event after it counts, and
  # the bot event before it does not come back.
  j=$(jq --arg l "$BOT" '. + [{when:"2026-10-08T05:00:00Z", login:$l}]' <<<"$j")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "1" ]
}

@test "#2224: an empty or missing PR author exempts nothing (fail closed)" {
  run compute_pr_automation_cycles "$(pr_budget_flag_mechanical "$(bd176_events)" "")"
  [ "$output" = "10" ]
  run compute_pr_automation_cycles "$(pr_budget_flag_mechanical "$(bd176_events)")"
  [ "$output" = "10" ]
}

@test "#2224: PR_BUDGET_MECHANICAL_LOGINS is honoured, and empty disables the exemption" {
  local j
  j=$(PR_BUDGET_MECHANICAL_LOGINS="$DEPENDABOT" pr_budget_flag_mechanical "$(bd176_events)" "$DEPENDABOT")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "9" ]   # only Dependabot's own commit is exempt
  j=$(PR_BUDGET_MECHANICAL_LOGINS="" pr_budget_flag_mechanical "$(bd176_events)" "$DEPENDABOT")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "10" ]
}

@test "#2224: pr_budget_flag_mechanical keeps every event (the stall scans read .when)" {
  local j; j=$(pr_budget_flag_mechanical "$(bd176_events)" "$DEPENDABOT")
  [ "$(jq 'length' <<<"$j")" = "10" ]
  [ "$(jq '[.[] | select(.mechanical == true)] | length' <<<"$j")" = "8" ]
}

@test "#2224: pr_budget_flag_mechanical returns malformed input unchanged" {
  run pr_budget_flag_mechanical "not json" "$DEPENDABOT"
  [ "$status" -eq 0 ]
  [ "$output" = "not json" ]
}

# ---------------------------------------------------------------------------
# Agent comments posted under a human login (#2224). dev-lead, the personas and
# auto-rebase post as the owner account, so login alone reads them as a human
# and each one re-armed the budget. A comment or review whose body carries one
# of our automation markers is an agent event whatever its login: it never
# resets. It does not count either — only bot logins count, as before.
# ---------------------------------------------------------------------------

OWNER="don-petry"

# mev <when> <login> — an event the gather step marked as carrying an agent marker.
mev() { jq -n --arg when "$1" --arg login "$2" '{when: $when, login: $login, agent_marked: true}'; }

@test "#2224: a marker-carrying comment under a human login does not reset the budget" {
  # #176: ten bot events, then dev-lead's hold notice posted as the owner.
  local j; j=$(jq --argjson m "$(mev 2026-10-09T04:35:08Z "$OWNER")" '. + [$m]' <<<"$(bd176_events)")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "10" ]
  run pr_budget_exhausted "$j"
  [ "$status" -eq 0 ]
}

@test "#2224: a marker-carrying comment under a human login does not count" {
  local j
  j=$(events \
    "$(mev 2026-10-09T01:00:00Z "$OWNER")" \
    "$(mev 2026-10-09T02:00:00Z "$OWNER")" \
    "$(ev  2026-10-09T03:00:00Z "$BOT")")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "1" ]
}

@test "#2224: an unmarked comment under the same login still resets the budget" {
  local j
  j=$(jq --arg l "$OWNER" '. + [{when:"2026-10-09T05:00:00Z", login:$l}]' <<<"$(bd176_events)")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "0" ]
}

@test "#2224: the reset point is the last UNMARKED human event" {
  local j
  j=$(events \
    "$(ev  2026-10-09T01:00:00Z "$BOT")" \
    "$(ev  2026-10-09T02:00:00Z "$OWNER")" \
    "$(ev  2026-10-09T03:00:00Z "$BOT")" \
    "$(mev 2026-10-09T04:00:00Z "$OWNER")" \
    "$(ev  2026-10-09T05:00:00Z "$BOT")")
  run compute_pr_automation_cycles "$j"
  [ "$output" = "2" ]
}

@test "#2224: every automation marker family is recognised as an agent body" {
  local body
  for body in \
    "<!-- dev-lead-hold-notice label=needs-human-review -->
**dev-lead is holding this PR**" \
    "<!-- dev-lead-fix-reviews pr=1 sha=abc status=no-changes -->" \
    "<!-- dev-lead-dispatch-guard sha=abc -->" \
    "<!-- dev-lead:comment-disposition id=1 disposition=informational -->" \
    "<!-- dev-lead rate-limit-ack -->" \
    "<!-- persona:qa-lead -->
## QA Lead" \
    "<!-- pr-review-claim sha=abc -->" \
    "<!-- dependency-advisory -->" \
    "<!-- auto-rebase-conflict:10bb907a -->" \
    "<!-- auto-rebase-stuck -->" \
    "Replying inline.

<!-- dev-lead:addressed sha=abc -->" \
    "$PR_AUTOMATION_EXHAUSTION_MARKER
## Automated activity budget exhausted" \
    "$PR_CYCLE_CAP_ESCALATION_MARKER" \
    "${PR_RATE_LIMITED_MARKER_PREFIX}abc status=rate-limited reset=2000-01-01T00:00:00Z -->"; do
    run pr_budget_body_is_agent_marked "$body"
    [ "$status" -eq 0 ] || { echo "not recognised: $body"; return 1; }
  done
}

@test "#2224: a human's own body is not an agent body" {
  local body
  for body in \
    "@dev-lead - please fix this PR" \
    "LGTM" \
    "" \
    "<!-- maintainer:not-a-finding -->" \
    "<!-- maintainer-resolve id=1 -->" \
    "the marker is written <!-- dev-lead and never closed" \
    "<!-- some-other-tool note -->"; do
    run pr_budget_body_is_agent_marked "$body"
    [ "$status" -ne 0 ] || { echo "wrongly recognised: $body"; return 1; }
  done
}

@test "#2224: the budget's marker set covers the comment gate's agent markers (except the maintainer's own tool)" {
  # maintainer-comment-gate.sh owns the registered list. maintainer-resolve is
  # the reply a maintainer posts through maintainer-resolve-comment.sh — a human
  # act, so it must keep resetting the budget.
  # The budget regex is intentionally more restrictive to prevent false positives
  # when humans quote marker keywords: it requires proper delimiters (space, dash,
  # or colon) after keywords without built-in delimiters. Test with valid bodies.
  local gate fam suffix
  gate=$(grep -m1 "^readonly _MAINTAINER_GATE_AGENT_MARKERS=" \
    "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/maintainer-comment-gate.sh")
  [ -n "$gate" ]
  gate=${gate#*\(}; gate=${gate%%\)*}
  while IFS= read -r fam; do
    [ -n "$fam" ] || continue
    [ "$fam" = "maintainer-resolve" ] && continue
    # Keywords with built-in delimiters can use any suffix; others need space/dash/colon
    case "$fam" in
      persona:|auto-rebase-*:*) suffix="x y=z" ;;    # Has built-in delimiter
      auto-rebase-*) suffix="x y=z" ;;               # Dash is delimiter
      *) suffix=" x y=z" ;;                          # Needs space delimiter
    esac
    run pr_budget_body_is_agent_marked "<!-- ${fam}${suffix} -->"
    [ "$status" -eq 0 ] || { echo "gate marker not covered: $fam"; return 1; }
  done < <(tr '|' '\n' <<<"$gate")
}

# gh stub for the gather tests: serves fixtures from $FIXD, and the PR author
# from $FIXD/author (no such file → the author call fails).
budget_gh_stub() {
  FIXD="$BATS_TEST_TMPDIR/fix"; mkdir -p "$FIXD"; export FIXD
  echo '[]' > "$FIXD/comments.json"; echo '[]' > "$FIXD/commits.json"; echo '[]' > "$FIXD/reviews.json"
  cat > "$BATS_TEST_TMPDIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"/issues/"*"/comments"*) cat "$FIXD/comments.json" ;;
  *"/pulls/"*"/commits"*)   cat "$FIXD/commits.json" ;;
  *"/pulls/"*"/reviews"*)   cat "$FIXD/reviews.json" ;;
  *"/pulls/"*)              [ -f "$FIXD/author" ] && cat "$FIXD/author" || exit 1 ;;
  *) printf '[]' ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/gh"
  PATH="$BATS_TEST_TMPDIR:$PATH"
}

# The #176 history in GitHub API shape, as it stood when pr-review escalated.
bd176_fixture() {
  cat > "$FIXD/commits.json" <<'JSON'
[{"commit":{"author":{"date":"2026-10-08T15:33:54Z","name":"dependabot[bot]"}},"author":{"login":"dependabot[bot]"}},
 {"commit":{"author":{"date":"2026-10-08T20:57:06Z"}},"author":{"login":"petry-projects-dependabot-automrg[bot]"}},
 {"commit":{"author":{"date":"2026-10-08T20:59:58Z"}},"author":{"login":"petry-projects-dependabot-automrg[bot]"}},
 {"commit":{"author":{"date":"2026-10-09T04:09:46Z"}},"author":{"login":"petry-projects-dependabot-automrg[bot]"}}]
JSON
  cat > "$FIXD/reviews.json" <<'JSON'
[{"submitted_at":"2026-10-08T15:34:09Z","user":{"login":"petry-projects-dependabot-automrg[bot]"},"body":""},
 {"submitted_at":"2026-10-08T20:57:25Z","user":{"login":"petry-projects-dependabot-automrg[bot]"},"body":""},
 {"submitted_at":"2026-10-08T21:00:58Z","user":{"login":"petry-projects-dependabot-automrg[bot]"},"body":""},
 {"submitted_at":"2026-10-09T04:16:18Z","user":{"login":"petry-projects-dependabot-automrg[bot]"},"body":""}]
JSON
  cat > "$FIXD/comments.json" <<'JSON'
[{"created_at":"2026-10-08T15:34:21Z","user":{"login":"coderabbitai[bot]"},"body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->"},
 {"created_at":"2026-10-09T04:17:40Z","user":{"login":"sonarqubecloud[bot]"},"body":"## Quality Gate Passed"}]
JSON
}

@test "#2224 gather: the #176 history on a Dependabot PR is not exhausted, and says why" {
  budget_gh_stub; bd176_fixture
  printf 'dependabot[bot]' > "$FIXD/author"
  local j; j=$(gather_pr_automation_events 176 petry-projects/demo 2>"$BATS_TEST_TMPDIR/err")
  [ "$(jq 'length' <<<"$j")" = "10" ]
  [ "$(compute_pr_automation_cycles "$j")" = "2" ]
  grep -q "8 Dependabot-pipeline event(s)" "$BATS_TEST_TMPDIR/err"
  run enforce_pr_budget 176 petry-projects/demo
  [ "$status" -ne 0 ]
}

@test "#2224 gather: the same history on a PR by another author is exhausted" {
  budget_gh_stub; bd176_fixture
  printf 'don-petry' > "$FIXD/author"
  local j; j=$(gather_pr_automation_events 176 petry-projects/demo 2>/dev/null)
  [ "$(compute_pr_automation_cycles "$j")" = "10" ]
}

@test "#2224 gather: an unreadable PR author exempts nothing and is not an API failure" {
  budget_gh_stub; bd176_fixture   # no author file → the author call exits 1
  local j rc=0
  j=$(gather_pr_automation_events 176 petry-projects/demo 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(compute_pr_automation_cycles "$j")" = "10" ]
}

@test "#2224 gather: dev-lead's hold notice and its own escalation comment do not re-arm the budget" {
  budget_gh_stub; bd176_fixture
  printf 'don-petry' > "$FIXD/author"
  local tmp; tmp=$(mktemp)
  jq '. + [
    {created_at:"2026-10-09T04:34:02Z", user:{login:"don-petry"}, body:"<!-- pr-automation-budget exhausted -->\n## Automated activity budget exhausted"},
    {created_at:"2026-10-09T04:35:08Z", user:{login:"don-petry"}, body:"<!-- dev-lead-hold-notice label=needs-human-review -->\n\n**dev-lead is holding this PR**"}
  ]' "$FIXD/comments.json" > "$tmp" && mv "$tmp" "$FIXD/comments.json"
  local j; j=$(gather_pr_automation_events 176 petry-projects/demo 2>"$BATS_TEST_TMPDIR/err")
  [ "$(compute_pr_automation_cycles "$j")" = "10" ]
  grep -q "2 marker-carrying agent event(s)" "$BATS_TEST_TMPDIR/err"
}

@test "#2224 gather: a marker-carrying review body under a human login does not reset; a plain human comment does" {
  budget_gh_stub; bd176_fixture
  printf 'don-petry' > "$FIXD/author"
  local tmp; tmp=$(mktemp)
  jq '. + [{submitted_at:"2026-10-09T05:00:00Z", user:{login:"don-petry"}, body:"<!-- persona:qa-lead -->\n## QA Lead"}]' \
    "$FIXD/reviews.json" > "$tmp" && mv "$tmp" "$FIXD/reviews.json"
  local j; j=$(gather_pr_automation_events 176 petry-projects/demo 2>/dev/null)
  [ "$(compute_pr_automation_cycles "$j")" = "10" ]
  jq '. + [{created_at:"2026-10-09T06:00:00Z", user:{login:"don-petry"}, body:"Looked at this, carry on."}]' \
    "$FIXD/comments.json" > "$tmp" && mv "$tmp" "$FIXD/comments.json"
  j=$(gather_pr_automation_events 176 petry-projects/demo 2>/dev/null)
  [ "$(compute_pr_automation_cycles "$j")" = "0" ]
}

@test "#2224 gather: event bodies are not carried in the result" {
  budget_gh_stub; bd176_fixture
  printf 'don-petry' > "$FIXD/author"
  local j; j=$(gather_pr_automation_events 176 petry-projects/demo 2>/dev/null)
  [ "$(jq '[.[] | select(has("body"))] | length' <<<"$j")" = "0" ]
}
