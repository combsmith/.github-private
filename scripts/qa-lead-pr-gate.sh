#!/usr/bin/env bash
set -euo pipefail
# qa-lead-pr-gate.sh — signal gathering + fire/skip decision for the qa-lead
# pull_request advisory (issue #1905).
#
# This is the ONE implementation of the gathering the qa-lead PR advisory needs.
# Its caller is .github/workflows/persona-runner-reusable.yml — the router-served
# pull_request surface — whose event pre-gate calls it via
# scripts/persona-pr-pregate.sh. Before #1905 the gathering lived inline in a
# local, self-contained workflow's YAML, so the router-served pull_request path
# had NONE of it and posted on every trusted PR; #1905 moved it here so both
# paths shared it, and #2243 retired the local workflow, leaving the router path.
#
# It gathers the PR's signals via `gh` and hands them to the pure, unit-tested
# decision qa_lead_gate_decision (scripts/qa-lead-advisory-gate.sh). Sourcing this
# file pulls in that decision + the heuristic/budget libs WITHOUT running main
# (guarded by BASH_SOURCE == $0 there).

_QA_LEAD_PR_GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/qa-lead-advisory-gate.sh
source "${_QA_LEAD_PR_GATE_DIR}/qa-lead-advisory-gate.sh"

# The recursion marker every qa-lead advisory begins with — the idempotency key
# for the already-advised suppressor (the runner's read/write split stamps it).
: "${QA_LEAD_ADVISORY_MARKER:=<!-- persona:qa-lead -->}"

# _qa_lead_pr_gate_fail_closed <repo> <pr> <what>
#   Fail CLOSED: name the derivation that could not be resolved on a ::error
#   (AGENTS.md: "when an input can't be resolved, fail loudly and name the
#   derivation that failed") and print the skip decision. Silence is the safe
#   default — a signal we cannot read must never degrade to an empty value that
#   would bypass a suppressor or duplicate an advisory.
_qa_lead_pr_gate_fail_closed() {
  local repo="$1" pr="$2" what="$3"
  echo "::error::qa-lead pull_request pre-gate: ${what} for ${repo}#${pr} — failing closed (skip)" >&2
  printf 'skip:signal-unavailable\n'
}

# qa_lead_pr_gather_and_decide <repo> <pr>
#   Gather the PR's signals and return the fire/skip decision. Prints exactly one
#   decision line on stdout: "run" or "skip:<reason>". Returns 0 for run, 1 for
#   skip. Any unreadable signal fails closed (skip) via the helper above.
#
#   Signals gathered:
#     * changed files — with the completeness (3000-file cap) and control-character
#       guards, so a truncated or LF-forged list never mislabels the PR;
#     * label names — never degraded to [] on an API error (that would bypass the
#       opt-out / human gates);
#     * existing qa-lead advisory marker (idempotency);
#     * per-PR automation budget events (#860/#926 breaker).
qa_lead_pr_gather_and_decide() {
  local repo="$1" pr="$2"
  local files_json declared_files received_files changed_paths labels_json
  local comment_bodies existing_advisory budget_exhausted events_json decision

  # Changed files as a JSON array of filenames — validated BEFORE it is flattened
  # to the newline text qa_lead_test_surface consumes. gh rejects --slurp together
  # with --jq, so the filter runs in external jq; `pipefail` (set above) makes a
  # failure of EITHER side of the pipe reach the fail-closed branch.
  if ! files_json="$(gh api --paginate --slurp \
      "repos/${repo}/pulls/${pr}/files" | jq -c '[.[][].filename]')"; then
    _qa_lead_pr_gate_fail_closed "$repo" "$pr" "changed-file list unavailable"
    return 1
  fi

  # Completeness: the /pulls/{n}/files endpoint caps at 3000 files, so a larger
  # PR yields a truncated list that could omit a test/source path. Compare the
  # received count against the declared changed_files and skip on an incomplete
  # list rather than advise off partial data.
  if ! declared_files="$(gh api "repos/${repo}/pulls/${pr}" \
      --jq '.changed_files')"; then
    _qa_lead_pr_gate_fail_closed "$repo" "$pr" "changed-file count unavailable"
    return 1
  fi
  received_files="$(jq 'length' <<< "$files_json")"
  if ! qa_lead_file_list_complete "$received_files" "$declared_files"; then
    _qa_lead_pr_gate_fail_closed "$repo" "$pr" \
      "changed-file list incomplete (${received_files}/${declared_files})"
    return 1
  fi

  # Control characters: a filename containing an LF would split into phantom
  # records once flattened (a docs-only PR could forge a SOURCE path). Reject
  # before flattening.
  if qa_lead_paths_have_control_char "$files_json"; then
    _qa_lead_pr_gate_fail_closed "$repo" "$pr" \
      "changed-file list contains control characters"
    return 1
  fi

  changed_paths="$(jq -r '.[]' <<< "$files_json")"

  # Label names — an API failure must NOT degrade to [] (that would bypass the
  # opt-out and human-gating suppressors).
  if ! labels_json="$(gh api "repos/${repo}/pulls/${pr}" \
      --jq '[.labels[]?.name]')"; then
    _qa_lead_pr_gate_fail_closed "$repo" "$pr" "labels unavailable"
    return 1
  fi

  # Existing qa-lead advisory? Scan the (shared) issue comment stream for the
  # recursion marker. A comment API failure is indistinguishable from "no marker",
  # so failing open here would risk a duplicate advisory — fail closed instead.
  if ! comment_bodies="$(gh api --paginate \
      "repos/${repo}/issues/${pr}/comments" --jq 'if type == "array" then .[].body else error("expected comments array") end')"; then
    _qa_lead_pr_gate_fail_closed "$repo" "$pr" "existing-advisory scan unavailable"
    return 1
  fi
  if grep -qF "$QA_LEAD_ADVISORY_MARKER" <<< "$comment_bodies"; then
    existing_advisory=1
  else
    existing_advisory=0
  fi

  # Per-PR automation budget. gather_pr_automation_events returns non-zero when
  # any API call fails; a failure must NOT degrade to an empty event list (an
  # exhausted PR would then pass the budget gate during a transient outage).
  budget_exhausted=0
  if events_json="$(gather_pr_automation_events "$pr" "$repo")"; then
    if pr_budget_exhausted "$events_json"; then
      budget_exhausted=1
    fi
  else
    _qa_lead_pr_gate_fail_closed "$repo" "$pr" "automation-budget events unavailable"
    return 1
  fi

  decision="$(qa_lead_gate_decision \
    "$changed_paths" "$labels_json" "$existing_advisory" "$budget_exhausted" || true)"
  if [ -z "$decision" ]; then
    _qa_lead_pr_gate_fail_closed "$repo" "$pr" "gate decision empty"
    return 1
  fi
  printf '%s\n' "$decision"
  # Return the status explicitly rather than leaving a bare `[ ... ]` as the
  # function's last line: under `set -e`, a standalone conditional that evaluates
  # false propagates as a failure that can terminate a sourcing caller.
  if [ "$decision" = "run" ]; then
    return 0
  fi
  return 1
}
