#!/usr/bin/env bats
# Unit tests for the engine-token liveness detector
# (scripts/lib/engine_liveness_detect.sh, issue #1587).
#
# #1587: dev-lead failed 100% of runs across 8 repos for seven days — every run
# died at the "Engine token preflight" step ("CLAUDE_CODE_OAUTH_TOKEN is not
# provided") — and nothing alerted a human. Two gaps: (a) pr-review had no
# preflight so it failed OPEN (looked healthy while reviewing nothing), and
# (b) a sustained fleet-wide preflight failure only accumulated in periodic
# health reports instead of escalating.
#
# This library is the machine-checkable decision layer. Given already-gathered
# run/step metadata it decides, per repo, whether the engine-token preflight is
# failing, and whether the aggregate warrants a FLEET-level alert (the outage
# class) vs. ISOLATED health-check reporting vs. NONE. It also classifies a
# credential's scope/expiry (GH_PAT_DON_PETRY). Detection only — never mutates.
#
# Escalation contract (issue scope 3):
#   AGENTS_PAUSED=true                              -> silent (handled by caller)
#   >=2 consecutive preflight failures in >=2 repos -> FLEET alert
#   otherwise any single-repo failure               -> ISOLATED (routine report)
#
# Run with: bats tests/test_engine_liveness_detect.bats

setup() {
  # BATS creates $BATS_TEST_TMPDIR fresh per test and removes it afterwards, so
  # use it directly — no manual mktemp/teardown, no parallel-run collisions or
  # leftover dirs on failure (gemini review, #1587).
  TMP="$BATS_TEST_TMPDIR"
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/engine_liveness_detect.sh"
}

# ---------------------------------------------------------------------------
# is_preflight_step / step_is_preflight_failure — the step matcher
# ---------------------------------------------------------------------------

@test "is_preflight_step matches the verbatim step name" {
  run is_preflight_step "Engine token preflight (#1525)"
  [ "$status" -eq 0 ]
}

@test "is_preflight_step ignores an unrelated step" {
  run is_preflight_step "Checkout agent repo"
  [ "$status" -ne 0 ]
}

@test "step_is_preflight_failure fires only on a FAILED preflight step" {
  run step_is_preflight_failure "Engine token preflight (#1525)" failure
  [ "$status" -eq 0 ]
}

@test "step_is_preflight_failure does not fire on a passing preflight step" {
  run step_is_preflight_failure "Engine token preflight (#1525)" success
  [ "$status" -ne 0 ]
}

@test "step_is_preflight_failure does not fire on a failure of a DIFFERENT step" {
  run step_is_preflight_failure "Review each PR (cascade)" failure
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# repo_liveness_state <consecutive_preflight_failures>
# ---------------------------------------------------------------------------

@test "repo_liveness_state: 0 consecutive failures -> OK" {
  run repo_liveness_state 0
  [ "$output" = "OK" ]
}

@test "repo_liveness_state: 1 consecutive failure -> FAIL (not yet sustained)" {
  run repo_liveness_state 1
  [ "$output" = "FAIL" ]
}

@test "repo_liveness_state: 2 consecutive failures -> OUTAGE (sustained)" {
  run repo_liveness_state 2
  [ "$output" = "OUTAGE" ]
}

@test "repo_liveness_state: many consecutive failures -> OUTAGE" {
  run repo_liveness_state 7
  [ "$output" = "OUTAGE" ]
}

@test "repo_liveness_state: non-numeric input degrades to OK (never crashes)" {
  run repo_liveness_state "abc"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "repo_liveness_state: missing input -> OK" {
  run repo_liveness_state
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# fleet_escalation <sustained_repo_count> <any_failure_repo_count>
# FLEET requires >=2 repos each sustaining (>=2 consecutive) failures.
# ---------------------------------------------------------------------------

@test "fleet_escalation: 2 sustained repos -> FLEET (the outage class)" {
  run fleet_escalation 2 2
  [ "$output" = "FLEET" ]
}

@test "fleet_escalation: 3 sustained repos -> FLEET" {
  run fleet_escalation 3 3
  [ "$output" = "FLEET" ]
}

@test "fleet_escalation: 1 sustained repo -> ISOLATED (single-repo, not fleet)" {
  run fleet_escalation 1 1
  [ "$output" = "ISOLATED" ]
}

@test "fleet_escalation: 0 sustained but 1 failing repo -> ISOLATED" {
  run fleet_escalation 0 1
  [ "$output" = "ISOLATED" ]
}

@test "fleet_escalation: no failures anywhere -> NONE" {
  run fleet_escalation 0 0
  [ "$output" = "NONE" ]
}

@test "fleet_escalation: a single repo failing on many runs is still ISOLATED, not FLEET" {
  # The fleet gate is about BREADTH (>=2 repos), not depth. One repo alone,
  # however many consecutive failures, must never trip the fleet alarm.
  run fleet_escalation 1 1
  [ "$output" = "ISOLATED" ]
}

@test "fleet_escalation: non-numeric input degrades to NONE" {
  run fleet_escalation "x" "y"
  [ "$output" = "NONE" ]
}

# ---------------------------------------------------------------------------
# monitoring_status <inspected_stubs> <api_errors>
# A NONE all-clear is only trustworthy if the monitor actually inspected
# something. 0 stubs inspected + >=1 non-404 API error -> DEGRADED (#1587).
# ---------------------------------------------------------------------------

@test "monitoring_status: 0 inspected and >=1 API error -> DEGRADED (blind run, not all-clear)" {
  run monitoring_status 0 1
  [ "$output" = "DEGRADED" ]
}

@test "monitoring_status: 0 inspected but 0 API errors -> OK (genuinely nothing to monitor)" {
  run monitoring_status 0 0
  [ "$output" = "OK" ]
}

@test "monitoring_status: some stubs inspected despite an API error -> OK (partial visibility)" {
  run monitoring_status 3 2
  [ "$output" = "OK" ]
}

@test "monitoring_status: non-numeric input degrades to OK (never crashes)" {
  run monitoring_status "x" "y"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# pat_expiry_state <expiration_value> [warn_days] [now_epoch]
# ---------------------------------------------------------------------------

@test "pat_expiry_state: empty value -> NO_EXPIRY (a classic PAT with no expiry)" {
  run pat_expiry_state "" 14 100000
  [ "$output" = "NO_EXPIRY" ]
}

@test "pat_expiry_state: an expiry already in the past -> EXPIRED" {
  # now = 2026-08-30, expiry = 2026-08-01
  now=$(date -u -d "2026-08-30T00:00:00Z" +%s)
  run pat_expiry_state "2026-08-01 12:00:00 UTC" 14 "$now"
  [ "$output" = "EXPIRED" ]
}

@test "pat_expiry_state: an expiry inside the warn window -> EXPIRING" {
  now=$(date -u -d "2026-08-30T00:00:00Z" +%s)
  run pat_expiry_state "2026-09-05 00:00:00 UTC" 14 "$now"
  [ "$output" = "EXPIRING" ]
}

@test "pat_expiry_state: an expiry far in the future -> OK" {
  now=$(date -u -d "2026-08-30T00:00:00Z" +%s)
  run pat_expiry_state "2027-08-30 00:00:00 UTC" 14 "$now"
  [ "$output" = "OK" ]
}

@test "pat_expiry_state: unparseable value -> UNKNOWN" {
  run pat_expiry_state "not-a-date" 14 100000
  [ "$output" = "UNKNOWN" ]
}

@test "pat_expiry_state: exactly at the warn boundary -> EXPIRING" {
  now=$(date -u -d "2026-08-30T00:00:00Z" +%s)
  # 14 days out, warn window 14 days -> within window (<=), so EXPIRING
  run pat_expiry_state "2026-09-13 00:00:00 UTC" 14 "$now"
  [ "$output" = "EXPIRING" ]
}

# ---------------------------------------------------------------------------
# pat_missing_scopes / pat_scopes_ok
# ---------------------------------------------------------------------------

@test "pat_missing_scopes: all required present -> empty" {
  run pat_missing_scopes "repo, workflow, read:org" "repo workflow"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pat_missing_scopes: a missing scope is named" {
  run pat_missing_scopes "repo, read:org" "repo workflow"
  [[ "$output" == *"workflow"* ]]
}

@test "pat_scopes_ok exit 0 when nothing missing, non-zero when missing" {
  run pat_scopes_ok "repo, workflow" "repo workflow"
  [ "$status" -eq 0 ]
  run pat_scopes_ok "repo" "repo workflow"
  [ "$status" -ne 0 ]
}

@test "pat_missing_scopes: empty scopes string reports every required scope" {
  run pat_missing_scopes "" "repo workflow"
  [[ "$output" == *"repo"* ]]
  [[ "$output" == *"workflow"* ]]
}

@test "pat_missing_scopes: a glob in required is treated literally, not path-expanded" {
  # Run from a dir with files present, so an unquoted '*' would expand to them.
  cd "$BATS_TEST_TMPDIR"
  : > sentinel-file
  run pat_missing_scopes "repo, workflow" "*"
  [ "$status" -eq 0 ]
  [ "$output" = "*" ]
}

# ---------------------------------------------------------------------------
# escalation_headline — one-line human summary per level
# ---------------------------------------------------------------------------

@test "escalation_headline: FLEET names a fleet-wide outage" {
  run escalation_headline FLEET
  [[ "$output" == *"FLEET"* || "$output" == *"fleet"* ]]
  [[ "$output" == *"outage"* || "$output" == *"OUTAGE"* ]]
}

@test "escalation_headline: NONE is an all-clear" {
  run escalation_headline NONE
  [[ "$output" == *"healthy"* || "$output" == *"clear"* || "$output" == *"OK"* ]]
}

# ---------------------------------------------------------------------------
# render_liveness_table — per-repo markdown table / all-clear line
# ---------------------------------------------------------------------------

@test "render_liveness_table renders each repo row with its state" {
  f=$(mktemp "$TMP/rows.XXXXXX")
  printf '%s\t%s\t%s\t%s\n' "petry-projects/ContentTwin" "dev-lead.yml" "OUTAGE" "3" > "$f"
  printf '%s\t%s\t%s\t%s\n' "petry-projects/markets" "pr-review.yml" "OK" "0" >> "$f"
  run render_liveness_table "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ContentTwin"* ]]
  [[ "$output" == *"OUTAGE"* ]]
  [[ "$output" == *"markets"* ]]
}

@test "render_liveness_table on an empty file prints an all-clear line, not a table" {
  f=$(mktemp "$TMP/rows.XXXXXX")
  : > "$f"
  run render_liveness_table "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"| Repo |"* ]]
}

@test "render_liveness_table surfaces each repo's last-run timestamp (#1600)" {
  # A reader must be able to tell "healthy" from "not recently exercised" without
  # opening Actions — the table carries the newest run's timestamp per stub.
  f=$(mktemp "$TMP/rows.XXXXXX")
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "petry-projects/ContentTwin" "dev-lead.yml" "STALE" "0" "2026-08-28T18:57:00Z" > "$f"
  run render_liveness_table "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Last run"* ]]
  [[ "$output" == *"2026-08-28T18:57:00Z"* ]]
  [[ "$output" == *"STALE"* ]]
}

# ---------------------------------------------------------------------------
# Recency bound (#1600) — a stale pre-incident failure streak must NOT be
# reported as a live OUTAGE. The signal is bounded by BOTH streak and recency.
# ---------------------------------------------------------------------------

@test "within_lookback: a run inside the window is within (exit 0)" {
  now=1788134400   # 2026-08-31T00:00:00Z
  ep=1788048000    # 2026-08-30T00:00:00Z (1 day old)
  run within_lookback "$ep" "$now" 3
  [ "$status" -eq 0 ]
}

@test "within_lookback: a run older than the window is outside (non-zero)" {
  now=1788134400   # 2026-08-31T00:00:00Z
  ep=1787616000    # 2026-08-25T00:00:00Z (6 days old)
  run within_lookback "$ep" "$now" 3
  [ "$status" -ne 0 ]
}

@test "within_lookback: a run exactly at the cutoff is still within (inclusive boundary)" {
  now=1788134400   # 2026-08-31T00:00:00Z
  ep=1787875200    # 2026-08-28T00:00:00Z (exactly 3 days)
  run within_lookback "$ep" "$now" 3
  [ "$status" -eq 0 ]
}

@test "repo_liveness_state: newest run not recent -> STALE regardless of streak" {
  run repo_liveness_state 5 no
  [ "$output" = "STALE" ]
}

@test "repo_liveness_state: recency flag defaults to recent (back-compat, one-arg form)" {
  run repo_liveness_state 2
  [ "$output" = "OUTAGE" ]
}

@test "repo_liveness_from_runs: STALE when failures predate the window, OUTAGE when >=2 are inside it (#1600 — both directions)" {
  # now = the first real run of the monitor (2026-08-31T03:19Z, from the issue).
  now=1788146340   # 2026-08-31T03:19:00Z

  # ContentTwin's exact shape: two preflight failures 3-6 days old, no runs since.
  # Its streak never cleared, but the newest run predates the lookback window, so
  # this is STALE (unverified) — NOT a live OUTAGE.
  stale="$TMP/stale.tsv"
  {
    printf '%s\t%s\n' "2026-08-27T18:57:00Z" "yes"   # ~3.4 days old
    printf '%s\t%s\n' "2026-08-25T07:21:00Z" "yes"   # ~6 days old
  } > "$stale"
  run repo_liveness_from_runs "$stale" "$now" 3
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]

  # A GENUINE live outage: >=2 consecutive preflight failures INSIDE the window.
  # The #1587 behaviour must not regress — this still reports OUTAGE.
  live="$TMP/live.tsv"
  {
    printf '%s\t%s\n' "2026-08-31T00:10:00Z" "yes"   # hours old
    printf '%s\t%s\n' "2026-08-30T09:00:00Z" "yes"   # ~18h old
  } > "$live"
  run repo_liveness_from_runs "$live" "$now" 3
  [ "$status" -eq 0 ]
  [ "$output" = "OUTAGE" ]
}

@test "repo_liveness_from_runs: failures older than the window are ignored in the streak" {
  now=1788146340   # 2026-08-31T03:19:00Z
  f="$TMP/mix.tsv"
  {
    printf '%s\t%s\n' "2026-08-31T00:00:00Z" "no"    # recent success
    printf '%s\t%s\n' "2026-08-24T00:00:00Z" "yes"   # old failure, outside window
    printf '%s\t%s\n' "2026-08-23T00:00:00Z" "yes"   # old failure, outside window
  } > "$f"
  run repo_liveness_from_runs "$f" "$now" 3
  [ "$output" = "OK" ]
}

@test "repo_liveness_from_runs: a single recent preflight failure -> FAIL (not yet sustained)" {
  now=1788146340   # 2026-08-31T03:19:00Z
  f="$TMP/one.tsv"
  {
    printf '%s\t%s\n' "2026-08-31T00:00:00Z" "yes"   # recent failure
    printf '%s\t%s\n' "2026-08-30T00:00:00Z" "no"    # recent success -> breaks streak
  } > "$f"
  run repo_liveness_from_runs "$f" "$now" 3
  [ "$output" = "FAIL" ]
}

@test "repo_liveness_from_runs: no runs at all -> STALE (unverified, the honest state)" {
  now=1788146340   # 2026-08-31T03:19:00Z
  f="$TMP/empty.tsv"; : > "$f"
  run repo_liveness_from_runs "$f" "$now" 3
  [ "$output" = "STALE" ]
}

# ---------------------------------------------------------------------------
# run_should_fail — a STALE repo must NOT fail the workflow (#1600 AC), while a
# within-window OUTAGE still does (#1587 must not regress).
# ---------------------------------------------------------------------------

@test "run_should_fail: a within-window sustained OUTAGE fails the run" {
  run run_should_fail 1
  [ "$status" -eq 0 ]
}

@test "run_should_fail: no within-window outage does not fail the run (STALE/OK non-failing)" {
  run run_should_fail 0
  [ "$status" -ne 0 ]
}

@test "run_should_fail: non-numeric input degrades to non-failing" {
  run run_should_fail "x"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# _el_to_epoch normalization must be ANCHORED (#1600 regression guard).
# A blanket `${v//T/ }` also rewrites the T inside a timezone NAME: GitHub's PAT
# `expires_at` form "YYYY-MM-DD HH:MM:SS UTC" became "... U C" and stopped
# parsing, so pat_expiry_state reported every real expiry as UNKNOWN.
# ---------------------------------------------------------------------------

@test "_el_to_epoch: a 'UTC' timezone suffix survives normalization (#1600)" {
  run _el_to_epoch "2026-08-01 12:00:00 UTC"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" -gt 0 ]
}

@test "_el_to_epoch: an ISO 8601 T/Z timestamp still parses (#1600)" {
  run _el_to_epoch "2026-08-31T03:19:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "1788146340" ]
}

@test "_el_to_epoch: the ISO and 'UTC' forms of the same instant agree (#1600)" {
  local a b
  a="$(_el_to_epoch "2026-08-31T03:19:00Z")"
  b="$(_el_to_epoch "2026-08-31 03:19:00 UTC")"
  [ -n "$a" ] && [ "$a" = "$b" ]
}

@test "_el_to_epoch: unparseable input still yields empty (#1600)" {
  run _el_to_epoch "not-a-date"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
