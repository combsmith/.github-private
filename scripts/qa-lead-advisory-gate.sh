#!/usr/bin/env bash
set -euo pipefail
# qa-lead-advisory-gate.sh — the pure fire/skip decision for the qa-lead PR
# advisory (issue #1646 — [qa-lead S3]).
#
# scripts/qa-lead-pr-gate.sh (called by the runner's pull_request pre-gate,
# scripts/persona-pr-pregate.sh) gathers a PR's signals — changed files, labels,
# whether a qa-lead advisory already exists, whether the automation budget is
# exhausted — and calls qa_lead_gate_decision, which is pure
# and unit-tested (tests/test_qa_lead_advisory_gate.bats) so every suppressor has
# a regression test. Keeping the policy here (not inline in yaml) is what lets us
# pin it.
#
# It composes:
#   AC #3  the test-surface heuristic          (qa_lead_test_surface)
#   AC #4  the qa-lead:hands-off opt-out label
#   AC #5  one advisory per PR (idempotency)
#   AC #6  budget / human gates — reusing pr_has_escalation_label as the CANONICAL
#          needs-human-review check (do NOT re-derive it here)
#
# Sourcing this file pulls in the heuristic + budget libs and defines the pure
# decision functions WITHOUT running main (guarded by BASH_SOURCE == $0).

_QA_LEAD_GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/qa-lead-test-surface.sh
source "${_QA_LEAD_GATE_DIR}/lib/qa-lead-test-surface.sh"
# shellcheck source=scripts/lib/pr-automation-budget.sh
source "${_QA_LEAD_GATE_DIR}/lib/pr-automation-budget.sh"

# The opt-out label (AC #4) and the dev-lead human-handoff label (AC #6). The
# needs-human-review label is owned by pr-automation-budget.sh (NEEDS_HUMAN_REVIEW_LABEL)
# and checked via its canonical pr_has_escalation_label — not re-listed here.
: "${QA_LEAD_OPT_OUT_LABEL:=qa-lead:hands-off}"
: "${DEV_LEAD_NEEDS_HUMAN_LABEL:=dev-lead:needs-human}"

# qa_lead_labels_contain <labels_json> <needle>
#   Exit 0 iff the JSON array of label names contains <needle> EXACTLY. The
#   generic predicate behind the two non-canonical labels (opt-out and
#   dev-lead:needs-human). Malformed/empty input degrades to "not present".
qa_lead_labels_contain() {
  local labels_json="${1:-[]}" needle="$2"
  if jq -e --arg l "$needle" \
      'if type == "array" then any(.[]; . == $l) else false end' \
      <<< "$labels_json" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# qa_lead_gate_decision <changed_paths> <labels_json> <existing_advisory 0|1> <budget_exhausted 0|1>
#   Prints "run" (exit 0) or "skip:<reason>" (exit 1). Suppressors are checked in
#   a fixed order so the printed reason is deterministic:
#     no-test-surface  -> opt-out  -> human-gated  -> budget-exhausted  -> already-advised
#   Human gates precede budget/idempotency so a human-held PR reports the human
#   reason even when it is also over budget or already advised.
qa_lead_gate_decision() {
  local changed_paths="$1"
  local labels_json="${2:-[]}"
  local existing_advisory="${3:-0}"
  local budget_exhausted="${4:-0}"

  # AC #3 — no real test surface: silent, whatever else is true.
  if ! qa_lead_test_surface "$changed_paths"; then
    echo "skip:no-test-surface"
    return 1
  fi

  # AC #4 — explicit opt-out.
  if qa_lead_labels_contain "$labels_json" "$QA_LEAD_OPT_OUT_LABEL"; then
    echo "skip:opt-out"
    return 1
  fi

  # AC #6 — human gates. pr_has_escalation_label is the canonical needs-human-review
  # check; dev-lead:needs-human is the sibling handoff label.
  if pr_has_escalation_label "$labels_json" \
     || qa_lead_labels_contain "$labels_json" "$DEV_LEAD_NEEDS_HUMAN_LABEL"; then
    echo "skip:human-gated"
    return 1
  fi

  # AC #6 — automation budget exhausted (the #860/#926 runaway breaker tripped).
  if [ "$budget_exhausted" = "1" ]; then
    echo "skip:budget-exhausted"
    return 1
  fi

  # AC #5 — one advisory per PR: don't stack open-as-draft + ready_for_review.
  if [ "$existing_advisory" = "1" ]; then
    echo "skip:already-advised"
    return 1
  fi

  echo "run"
  return 0
}

main() {
  qa_lead_gate_decision "$@"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
