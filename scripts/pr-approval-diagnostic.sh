#!/usr/bin/env bash
# pr-approval-diagnostic.sh — "why isn't this PR approved?" (#1894)
#
# Answers from the REAL gate chain, not a model of it: runs scripts/review-one-pr.sh
# in diagnose mode (PR_REVIEW_DIAGNOSE=true — read-only, never forced, stops before
# any model runs) and reports the single verdict that run reaches — which gate holds
# the PR, and what would change the decision — together with the PR facts a reader
# needs (review decision, approvals at the head, hold labels, merge state).
#
# The previous attempt (#1902) re-implemented each gate in a separate library and
# drifted from the real ones (bot-comment handling, the unsupported-file regex,
# check-run participation, the thread-gate fail-closed path). Running the gate chain
# itself makes that drift impossible: a gate change is a diagnostic change.
#
# Usage: pr-approval-diagnostic.sh <pr-url> [--json]
#   Needs the same environment a pr-review run needs to READ the PR (GH_TOKEN with
#   repo read; BOT_USER defaults to donpetry-bot). Writes nothing to GitHub.
# Exit: 0 diagnosed · 2 no diagnosis: the gate chain produced no verdict (its log
#       tail is printed), the PR facts could not be read, or the head moved while
#       diagnosing (re-run)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/hold-gate.sh
source "$SCRIPT_DIR/lib/hold-gate.sh"
PR_URL="${1:-}"
FORMAT="markdown"
[[ "${2:-}" = "--json" ]] && FORMAT="json"
if [[ ! "$PR_URL" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$ ]]; then
  echo "usage: pr-approval-diagnostic.sh https://github.com/<owner>/<repo>/pull/<n> [--json]" >&2
  exit 2
fi

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

set +e
PR_REVIEW_DIAGNOSE=true GITHUB_STEP_SUMMARY="" bash "$SCRIPT_DIR/review-one-pr.sh" "$PR_URL" >"$LOG" 2>&1
rc=$?
set -e

# The run's verdict is its LAST emit_verdict line (a JSON object with .decision).
verdict=$(grep -E '^\{"pr":' "$LOG" | tail -n 1 || true)
if [[ -z "$verdict" ]] || ! jq -e '.decision' <<<"$verdict" >/dev/null 2>&1; then
  echo "pr-approval-diagnostic: the gate chain produced no verdict (exit $rc); last lines:" >&2
  tail -n 20 "$LOG" >&2
  exit 2
fi

# Facts come from a second read of the PR. A failed read is reported as such —
# never as "no approvals, no holds" — and a head that moved since the gate run
# would describe a different commit than the verdict, so both stop the report.
pr_json=$(gh pr view "$PR_URL" --json state,isDraft,headRefOid,reviewDecision,mergeStateStatus,labels,reviews 2>/dev/null) \
  && jq -e '.headRefOid' <<<"$pr_json" >/dev/null 2>&1 \
  || { echo "pr-approval-diagnostic: could not read the PR's review facts (gh pr view failed)" >&2; exit 2; }
verdict_sha=$(jq -r '.sha // ""' <<<"$verdict")
if [[ -n "$verdict_sha" ]] && [[ "$(jq -r '.headRefOid' <<<"$pr_json")" != "$verdict_sha" ]]; then
  echo "pr-approval-diagnostic: the PR head moved while diagnosing (gate run saw ${verdict_sha:0:8}); re-run" >&2
  exit 2
fi
facts=$(jq -c --arg holds "$(hold_gate_labels | tr '\n' ' ')" '
      .headRefOid as $head
      | {state, isDraft, reviewDecision, mergeStateStatus,
         holds: [(.labels // [])[].name | select(. as $l | ($holds | split(" ") | index($l)))],
         approvals_at_head: [(.reviews // [])[]
            | select(.state == "APPROVED" and (.commit.oid // "") == $head)
            | (.author.login // "?")] | unique}' <<<"$pr_json")

# The gate log keeps the gates' own lines (indented) and the advisory gate's
# `[advisory-gate]` lines — e.g. which unavailable bots reduced the required set.
gate_log=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E '^    |\[advisory-gate\]' || true)
report=$(jq -cn --argjson v "$verdict" --argjson f "$facts" --arg log "$gate_log" \
  '$v + {facts: $f, gate_log: $log}')

if [[ "$FORMAT" = "json" ]]; then
  printf '%s\n' "$report"
  exit 0
fi

jq -r '
  def code: "`" + (. // "") + "`";
  .facts as $f
  # GitHub can still show an approval while a gate would now hold the PR: lead
  # with the gate, not "Approved". Every verdict holds except `proceed` and the
  # one true no-op, `already-reviewed-at-head` (e.g. `noop human-escalated` holds).
  | (if ($f.reviewDecision // "") == "APPROVED" and .decision != "proceed" and .reason != "already-reviewed-at-head"
     then "**GitHub shows the PR approved, but pr-review would now hold it** at the " + (.reason | code) + " gate."
     elif ($f.reviewDecision // "") == "APPROVED"
     then "**Approved.** Merge state: " + (($f.mergeStateStatus // "unknown") | code) + "."
     else "**Not approved** (review decision: " + (($f.reviewDecision // "none") | if . == "" then "none" else . end | code) + ")."
     end) as $status
  | [ "## pr-review approval diagnostic: " + .pr,
      "",
      $status,
      "",
      "| | |",
      "|---|---|",
      "| Head | " + ((.sha // "")[0:8] | code) + " |",
      "| What pr-review would do now | " + (.decision | code) + " — " + (.reason | code) + " |",
      "| What changes that | " + ((.would_change // "") | gsub("\\|"; "\\|")) + " |",
      "| dev-lead hold labels | " + (if (($f.holds // []) | length) > 0 then ($f.holds | map(code) | join(", ")) else "none" end) + " |",
      "| Approvals at head | " + (if (($f.approvals_at_head // []) | length) > 0 then ($f.approvals_at_head | join(", ")) else "none" end) + " |",
      "",
      "",
      "_dev-lead hold labels stop dev-lead acting on the PR. Of them, pr-review gates only on `needs-human-review`, and when it holds the PR the verdict above names it._",
      (if .decision == "proceed"
       then "No gate holds this PR: the next pr-review run reviews it, and that review decides."
       else "This is the first gate that holds the PR, in the order a pr-review run checks them. Gates after it were not evaluated."
       end),
      "",
      "<details><summary>Gate log</summary>",
      "",
      "```",
      .gate_log,
      "```",
      "</details>"
    ] | join("\n")' <<<"$report"
