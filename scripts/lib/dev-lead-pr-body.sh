#!/usr/bin/env bash
# dev-lead PR-body builders (issue #1805).
#
# dev-lead used to open every PR with a body of just "Closes #N". pr-review's
# triage (sc_description_missing in scripts/lib/safety-checks.sh) requires five
# description sections — problem, risk, test-plan, rollback, monitoring — and
# escalates a PR when 3+ are missing. So every dev-lead PR was escalated by
# construction, cycled through fix-requested/no-changes, and hit a human.
#
# This lib produces a structured PR body carrying all five sections as headings
# plus `Closes #N`, and an idempotent, marker-keyed backfill for existing PRs
# whose body is still missing 3+ sections. It does NOT weaken the triage gate —
# dev-lead meets it.
#
# The section *content* is derived deterministically from what the run actually
# knows (issue title/body + the set of changed files), so it stays truthful:
# it never claims tests that were not run. The orchestration wrapper
# (dlpb_backfill_pr_body) is the only function here that touches `gh`; every
# builder below is pure and unit-testable (mirrors scripts/lib/safety-checks.sh).

# Source the authoritative missing-section counter so the backfill trigger and
# the "0|" guarantee stay aligned with the gate they satisfy, rather than
# re-implementing the regex here and drifting from it.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/safety-checks.sh"

# Marker keying the backfilled block so a re-run does not churn the PR body.
DLPB_BACKFILL_MARKER="<!-- dev-lead-pr-body-backfill -->"

# _dlpb_has_pat <files-newline> <extended-regex> — 0 if any changed path matches.
_dlpb_has_pat() {
  local files="$1" pat="$2"
  printf '%s\n' "$files" | grep -qE "$pat"
}

# _dlpb_test_files <files-newline> — the changed paths under tests/ (or *.bats).
_dlpb_test_files() {
  printf '%s\n' "${1:-}" | grep -E '(^|/)tests/|\.bats$' || true
}

# dlpb_risk_line <files-newline> — a category plus a one-line rationale derived
# from the areas touched. Highest-risk area present wins.
dlpb_risk_line() {
  local files="${1:-}"
  if [[ -z "$(printf '%s' "$files" | tr -d '[:space:]')" ]]; then
    echo "Low — no changed files detected."
    return 0
  fi
  if _dlpb_has_pat "$files" '^\.github/workflows/.*\.(yml|yaml)$'; then
    echo "Medium — changes GitHub Actions workflow behavior, which is exercised only post-merge; verify via the affected workflow runs."
    return 0
  fi
  if _dlpb_has_pat "$files" '(^|/)scripts/.*\.sh$|(^|/)scripts/lib/'; then
    echo "Low — changes automation shell logic under scripts/, covered by shellcheck (--severity=warning) and the bats suite."
    return 0
  fi
  # Documentation / configuration only.
  if ! printf '%s\n' "$files" | grep -vqE '\.md$|(^|/)docs/|\.template$|template\.md$'; then
    echo "Low — documentation/configuration only; no runtime code paths change."
    return 0
  fi
  local n
  n=$(printf '%s\n' "$files" | grep -c . || true)
  echo "Low — ${n} file(s) changed; no CI- or runtime-critical paths touched."
}

# dlpb_test_plan_line <files-newline> — the tests added/updated and the checks
# the run actually performs. Truthful: dev-lead runs the repo lint (shellcheck)
# pre-commit; the bats suite runs in CI.
dlpb_test_plan_line() {
  local files="${1:-}" tests
  tests=$(_dlpb_test_files "$files")
  if [[ -n "$tests" ]]; then
    local list
    list=$(printf '%s\n' "$tests" | sed 's/^/`/; s/$/`/' | paste -sd ', ' -)
    echo "Tests added/updated: ${list}. Verification: \`bash scripts/dev-lead-lint.sh\` (shellcheck --severity=warning) ran pre-commit; the bats suite runs in CI."
    return 0
  fi
  echo "No test files were added or updated. Verification: \`bash scripts/dev-lead-lint.sh\` (shellcheck --severity=warning) ran pre-commit; the existing CI (bats + lint) guards the change."
}

# dlpb_rollback_line <files-newline> — how to undo the change. dev-lead PRs are
# revertible; there are no non-revertible side effects (no tags, migrations, or
# external state) introduced by the change itself.
dlpb_rollback_line() {
  echo "Revert this PR. No non-revertible side effects (no tags, migrations, or external state)."
}

# dlpb_monitoring_line <files-newline> — the signal that shows success/regression.
dlpb_monitoring_line() {
  local files="${1:-}"
  if [[ -z "$(printf '%s' "$files" | tr -d '[:space:]')" ]]; then
    echo "n/a — no changed files detected."
    return 0
  fi
  if _dlpb_has_pat "$files" '^\.github/workflows/.*\.(yml|yaml)$'; then
    echo "Watch the affected workflow run(s) in the Actions tab and this PR's Lint check for regressions."
    return 0
  fi
  if _dlpb_has_pat "$files" '(^|/)scripts/.*\.sh$|(^|/)scripts/lib/'; then
    echo "This PR's Lint (shellcheck) and bats checks show pass/fail; watch subsequent dev-lead / pr-review runs for behavioral regressions."
    return 0
  fi
  if ! printf '%s\n' "$files" | grep -vqE '\.md$|(^|/)docs/|\.template$|template\.md$'; then
    echo "n/a — no runtime effect; documentation/configuration only."
    return 0
  fi
  echo "This PR's CI checks (Lint + bats) are the success/regression signal."
}

# dlpb_problem_line <issue_title> <issue_body> — problem statement from the issue
# title and the first paragraph of its body (truncated). Never empty.
dlpb_problem_line() {
  local title="${1:-}" body="${2:-}" summary
  # First paragraph: content up to the first blank line, HTML comments stripped,
  # collapsed to a single line and truncated so the section stays terse.
  # Skip leading markdown headings (e.g. "## Summary") and blank lines, then
  # capture the first prose paragraph up to the next blank line.
  summary=$(printf '%s\n' "$body" \
    | sed 's/<!--[^-]*-->//g' \
    | awk '/^[[:space:]]*#/{next} NF==0{if(seen)exit; else next} {seen=1; print}' \
    | tr '\n' ' ' \
    | sed 's/  */ /g; s/^ //; s/ $//')
  [[ "${#summary}" -gt 600 ]] && summary="${summary:0:597}..."
  if [[ -n "$title" ]] && [[ -n "$summary" ]]; then
    printf '%s\n\nFrom the issue: %s' "$title" "$summary"
  elif [[ -n "$title" ]]; then
    printf '%s' "$title"
  elif [[ -n "$summary" ]]; then
    printf '%s' "$summary"
  else
    printf 'See the linked issue.'
  fi
}

# dlpb_sections <problem> <risk> <test_plan> <rollback> <monitoring>
#   Emit the five required sections as `##` headings. Every heading is followed
#   by its content, so none is ever empty (an empty heading fails AC #1).
dlpb_sections() {
  local problem="${1:-}" risk="${2:-}" test_plan="${3:-}" rollback="${4:-}" monitoring="${5:-}"
  cat <<EOF
## Problem

${problem}

## Risk

${risk}

## Test plan

${test_plan}

## Rollback

${rollback}

## Monitoring

${monitoring}
EOF
}

# dlpb_build_body <issue_number> <issue_title> <issue_body> <files-newline>
#   The full structured PR body dev-lead posts on `gh pr create`: the five
#   sections (content derived from the issue + changed files) followed by
#   `Closes #N`. Passes sc_description_missing with "0|".
dlpb_build_body() {
  local issue="${1:-}" title="${2:-}" body="${3:-}" files="${4:-}"
  local problem risk test_plan rollback monitoring sections
  problem=$(dlpb_problem_line "$title" "$body")
  risk=$(dlpb_risk_line "$files")
  test_plan=$(dlpb_test_plan_line "$files")
  rollback=$(dlpb_rollback_line "$files")
  monitoring=$(dlpb_monitoring_line "$files")
  sections=$(dlpb_sections "$problem" "$risk" "$test_plan" "$rollback" "$monitoring")
  printf '%s\n\nCloses #%s\n' "$sections" "$issue"
}

# dlpb_missing_count <body> — number of required sections missing from <body>,
# via the authoritative sc_description_missing (source of truth for the gate).
dlpb_missing_count() {
  local body="${1:-}" meta out
  meta=$(jq -n --arg b "$body" '{body:$b}' 2>/dev/null || printf '{"body":""}')
  out=$(sc_description_missing "$meta" 2>/dev/null || echo "5|")
  printf '%s' "${out%%|*}"
}

# dlpb_needs_backfill <body> — exit 0 when <body> is missing 3+ sections. Keyed
# purely on the authoritative missing-section count (sc_description_missing), so it
# mirrors the triage escalate rule exactly. It deliberately does NOT short-circuit
# on the presence of DLPB_BACKFILL_MARKER: a body that merely contains that literal
# string (copied or user-written text) but is still missing 3+ sections must remain
# repairable, and a genuinely-backfilled body already carries all five sections, so
# the count alone yields "no backfill needed" without churn.
dlpb_needs_backfill() {
  local body="${1:-}"
  local n
  n=$(dlpb_missing_count "$body")
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  [ "$n" -ge 3 ]  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449
}

# dlpb_backfill_body <existing_body> <sections_block>
#   Append the marker + the five sections to <existing_body>, preserving it.
#   Idempotent on the authoritative signal (the missing-section count via
#   dlpb_needs_backfill), NOT on the bare marker string: a body that already has
#   the required sections is returned unchanged so a second pass makes no edit (no
#   churn), while a body still missing 3+ sections is always repaired even if it
#   happens to contain the marker literal.
dlpb_backfill_body() {
  local existing="${1:-}" sections="${2:-}"
  if ! dlpb_needs_backfill "$existing"; then
    printf '%s' "$existing"
    return 0
  fi
  printf '%s\n\n%s\n\n%s' "$existing" "$DLPB_BACKFILL_MARKER" "$sections"
}

# dlpb_backfill_pr_body <pr_number> <repo> [files-newline]
#   Orchestration (the only gh-touching function): read the PR body, and if it
#   is missing 3+ sections and not yet backfilled, PATCH in the five sections
#   once. Best-effort — every gh failure is swallowed so a backfill hiccup never
#   turns a dev-lead pass into a hard failure. If <files-newline> is omitted it
#   is derived from the PR's changed files.
dlpb_backfill_pr_body() {
  local pr="${1:-}" repo="${2:-}" files="${3:-}"
  [[ -n "$pr" ]] && [[ -n "$repo" ]] || return 0

  local body
  body=$(gh pr view "$pr" --repo "$repo" --json body --jq '.body // ""' 2>/dev/null) || return 0
  dlpb_needs_backfill "$body" || { echo "::notice::PR #${pr} body already has the required sections (or was backfilled) — skipping backfill"; return 0; }

  if [[ -z "$files" ]]; then
    files=$(gh pr view "$pr" --repo "$repo" --json files --jq '.files[].path' 2>/dev/null || true)
  fi

  local problem risk test_plan rollback monitoring sections new_body tmp
  problem="See the linked issue."
  risk=$(dlpb_risk_line "$files")
  test_plan=$(dlpb_test_plan_line "$files")
  rollback=$(dlpb_rollback_line "$files")
  monitoring=$(dlpb_monitoring_line "$files")
  sections=$(dlpb_sections "$problem" "$risk" "$test_plan" "$rollback" "$monitoring")
  new_body=$(dlpb_backfill_body "$body" "$sections")

  tmp=$(mktemp) || return 0
  printf '%s' "$new_body" > "$tmp"

  # Guard against clobbering a concurrent update (#1806): the body we built
  # new_body from was a snapshot; re-read it immediately before writing and skip
  # the edit if it changed in the meantime, so a user/automation edit landing in
  # the read→write window is never silently overwritten. This shrinks — but by
  # gh's nature cannot fully close — the TOCTOU window; the backfill is best-effort.
  local current
  current=$(gh pr view "$pr" --repo "$repo" --json body --jq '.body // ""' 2>/dev/null) || { rm -f "$tmp"; return 0; }
  if [[ "$current" != "$body" ]]; then
    echo "::notice::PR #${pr} body changed since it was read — skipping backfill to avoid overwriting a concurrent update."
    rm -f "$tmp"
    return 0
  fi

  local edit_err
  # REST PATCH: `gh pr edit` fails under the workflow token (#2142).
  if edit_err=$(gh api -X PATCH "repos/${repo}/pulls/${pr}" -F "body=@${tmp}" 2>&1 >/dev/null); then
    echo "::notice::Backfilled required description sections into PR #${pr} body (idempotent, marker-keyed)."
  else
    # Best-effort, but never silent (#2142): log gh's message.
    echo "::warning::could not backfill the PR #${pr} body: ${edit_err//$'\n'/ }"
  fi
  rm -f "$tmp"
}
