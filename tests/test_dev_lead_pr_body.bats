#!/usr/bin/env bats
# Unit tests for scripts/lib/dev-lead-pr-body.sh (issue #1805).
#
# dev-lead PRs previously carried only "Closes #N", so pr-review's triage
# (sc_description_missing) counted 3+ of 5 required sections missing and
# escalated every dev-lead PR by construction. These tests pin the pure body
# builders + the idempotent, marker-keyed backfill so the generated body passes
# sc_description_missing with "0|" and a second backfill pass is a no-op.
#
# Everything here is deterministic and side-effect-free — no `gh`, no network.
#
# Run with: bats tests/test_dev_lead_pr_body.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/dev-lead-pr-body.sh"
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/safety-checks.sh"
}

# _missing <body> — run sc_description_missing over a body, echo "count|csv".
_missing() {
  local body="$1" meta
  meta=$(jq -n --arg b "$body" '{body:$b}')
  sc_description_missing "$meta"
}

# ---------------------------------------------------------------------------
# Full body builder
# ---------------------------------------------------------------------------

@test "build_body: generated body passes sc_description_missing with 0|" {
  local files='scripts/lib/dev-lead-pr-body.sh
tests/test_dev_lead_pr_body.bats'
  local body
  body=$(dlpb_build_body "1805" "Structured PR bodies" "The problem body." "$files")
  run _missing "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "0|" ]
}

@test "build_body: includes all five headings and Closes #N" {
  local body
  body=$(dlpb_build_body "42" "Some title" "Some body" "scripts/foo.sh")
  echo "$body" | grep -q '## Problem'
  echo "$body" | grep -q '## Risk'
  echo "$body" | grep -q '## Test plan'
  echo "$body" | grep -q '## Rollback'
  echo "$body" | grep -q '## Monitoring'
  echo "$body" | grep -q 'Closes #42'
}

@test "build_body: problem section reflects the issue title" {
  local body
  body=$(dlpb_build_body "7" "Fix the widget frobnicator" "Details about frobnication." "docs/readme.md")
  echo "$body" | grep -q 'Fix the widget frobnicator'
}

@test "problem_line: skips leading markdown headings and uses the prose paragraph" {
  local body out
  body=$(printf '## Summary\n\nThe real problem prose.\n\n## Evidence\n\nmore')
  out=$(dlpb_problem_line "T" "$body")
  echo "$out" | grep -q 'The real problem prose.'
  ! echo "$out" | grep -q '## Summary'
}

@test "build_body: no section heading is left empty" {
  local body
  body=$(dlpb_build_body "9" "T" "B" "scripts/x.sh")
  # Every heading must be followed by non-blank content before the next heading.
  # Assert each of the five sections has a non-empty first content line.
  for h in Problem Risk "Test plan" Rollback Monitoring; do
    run bash -c "printf '%s\n' \"\$1\" | awk -v h=\"## \$2\" 'index(\$0,h){f=1;next} f&&/^## /{exit} f&&NF{print;exit}'" _ "$body" "$h"
    [ -n "$output" ]
  done
}

# ---------------------------------------------------------------------------
# Section derivation — truthful, path-driven
# ---------------------------------------------------------------------------

@test "risk_line: docs-only change is Low with a docs rationale" {
  run dlpb_risk_line 'docs/foo.md
README.md'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'low'
  echo "$output" | grep -qi 'doc'
}

@test "risk_line: workflow change flags CI/workflow risk" {
  run dlpb_risk_line '.github/workflows/lint.yml'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qiE 'workflow|ci'
}

@test "test_plan_line: lists changed test files when present" {
  run dlpb_test_plan_line 'scripts/lib/dev-lead-pr-body.sh
tests/test_dev_lead_pr_body.bats'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'tests/test_dev_lead_pr_body.bats'
  # references shellcheck/lint as the verification actually run pre-commit
  echo "$output" | grep -qiE 'shellcheck|lint'
}

@test "test_plan_line: says no test files changed when none present" {
  run dlpb_test_plan_line 'docs/readme.md'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'no test'
}

@test "monitoring_line: docs-only is explicit n/a with a reason" {
  run dlpb_monitoring_line 'docs/readme.md'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'n/a'
}

@test "rollback_line: is present and mentions reverting the PR" {
  run dlpb_rollback_line 'scripts/foo.sh'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'revert'
}

# ---------------------------------------------------------------------------
# Backfill — idempotent, marker-keyed
# ---------------------------------------------------------------------------

@test "needs_backfill: true when body has 3+ missing sections and no marker" {
  run dlpb_needs_backfill "Closes #10"
  [ "$status" -eq 0 ]
}

@test "needs_backfill: false when body already has all sections" {
  local full
  full=$(dlpb_build_body "10" "T" "B" "scripts/x.sh")
  run dlpb_needs_backfill "$full"
  [ "$status" -eq 1 ]
}

@test "backfill: appends sections so body passes sc_description_missing 0|" {
  local sections out
  sections=$(dlpb_sections "P" "R" "TP" "RB" "M")
  out=$(dlpb_backfill_body "Closes #10" "$sections")
  run _missing "$out"
  [ "$output" = "0|" ]
}

@test "backfill: is idempotent — second pass makes no edit" {
  local sections first second
  sections=$(dlpb_sections "P" "R" "TP" "RB" "M")
  first=$(dlpb_backfill_body "Closes #10" "$sections")
  second=$(dlpb_backfill_body "$first" "$sections")
  [ "$first" = "$second" ]
}

@test "backfill: marker present means needs_backfill is false" {
  local sections out
  sections=$(dlpb_sections "P" "R" "TP" "RB" "M")
  out=$(dlpb_backfill_body "Closes #10" "$sections")
  run dlpb_needs_backfill "$out"
  [ "$status" -eq 1 ]
}

@test "needs_backfill: stray marker in body missing sections still needs backfill" {
  # A body that merely contains the marker literal (e.g. copied/user text) but is
  # still missing 3+ sections must remain repairable — the count is authoritative,
  # not the marker string (#1806).
  local body
  body=$(printf 'Closes #10\n\n%s\n' "$DLPB_BACKFILL_MARKER")
  run dlpb_needs_backfill "$body"
  [ "$status" -eq 0 ]
}

@test "backfill: repairs a body carrying only a stray marker" {
  local sections out
  sections=$(dlpb_sections "P" "R" "TP" "RB" "M")
  out=$(dlpb_backfill_body "$(printf 'Closes #10\n\n%s' "$DLPB_BACKFILL_MARKER")" "$sections")
  run _missing "$out"
  [ "$output" = "0|" ]
}

@test "backfill: preserves the original body content" {
  local sections out
  sections=$(dlpb_sections "P" "R" "TP" "RB" "M")
  out=$(dlpb_backfill_body "Original body text here. Closes #10" "$sections")
  echo "$out" | grep -q 'Original body text here'
}

# ---------------------------------------------------------------------------
# AC #5 — a literal "none" in Rollback still counts the section present
# ---------------------------------------------------------------------------

@test "rollback literal none: sc_description_missing still counts rollback present" {
  local sections body
  sections=$(dlpb_sections "P" "R" "TP" "none" "M")
  body=$(printf '%s\n\nCloses #10\n' "$sections")
  run _missing "$body"
  [ "$output" = "0|" ]
}

# ---------------------------------------------------------------------------
# AC #4 — the repo PR template carries the same five headings
# ---------------------------------------------------------------------------
# Since #2604 only filled text counts, so the template is checked filled: one
# line of text under every heading must give 0|. Unfilled, it scores like an
# empty body, which is what escalates an unfilled pull request (#1976).

@test "pull_request_template, filled, passes sc_description_missing with 0|" {
  local tmpl body
  tmpl="$(dirname "$BATS_TEST_FILENAME")/../.github/pull_request_template.md"
  body=$(awk '{ print } /^## / { print "filled in by the author" }' "$tmpl")
  run _missing "$body"
  [ "$output" = "0|" ]
}

@test "pull_request_template, unfilled, scores like an empty body (#2604, #1976)" {
  local tmpl
  tmpl="$(dirname "$BATS_TEST_FILENAME")/../.github/pull_request_template.md"
  run _missing "$(cat "$tmpl")"
  [ "$output" = "$(_missing "")" ]
}
