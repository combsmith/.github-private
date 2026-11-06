#!/usr/bin/env bash
set -euo pipefail
# pr-mergeready-detect.sh — the MERGE-READY-AND-IDLE detection net (issue #1469,
# epic #1402). The third member of the runaway (#948) / stall (#1410) detection
# family, all wired into the daily health check as PUSHED signals (the #860
# lesson: detection must be pushed, not pulled).
#
#   • runaway (pr-runaway-detect.sh) flags a PR with too MUCH automated activity.
#   • stall   (pr-stall-detect.sh)   flags a PR awaiting an automated REVIEW step.
#   • this net flags a PR that is fully MERGE-READY — reviewDecision APPROVED,
#     mergeable MERGEABLE, all required checks green — yet has sat idle past a
#     threshold with NO agent acting and NOTHING reporting that. #1451 sat exactly
#     this way for 77h and merged only when a human noticed it in a PR-list sweep.
#
# "merge-ready but idle" is a DISTINCT failure mode from the two adjacent ones the
# detector must not conflate (AC#2), so triage doesn't re-diagnose which of the
# three a stalled PR is in:
#   • #1425 — agent-blocked-by-untrusted-bot: an UNRESOLVED review thread from a
#             bot OUTSIDE TRUSTED_BOTS that no agent is authorized to resolve. Here
#             an agent WOULD act if it could. Classified `agent-blocked`.
#   • #1427 — reviewer-defers-on-pending-check: a pending / zombie check that makes
#             pr-review defer (ci_status == "pending"). Here an agent is actively
#             (if wrongly) deferring. Classified `reviewer-defer`.
# Neither is double-counted as merge-ready (AC#4); each is classified distinctly.
#
# Like its siblings this is a set of PURE functions given already-gathered PR
# metrics; it NEVER mutates a PR (AC#3). Surfacing is the caller's job
# (scripts/pr_mergeready_scan.sh, wired into the daily health check — no new cron).
#
# The public functions (args, unless noted, are:
#   <review_decision> <mergeable> <ci_status> <agent_blocked> <hours_idle> <gated>):
#   pr_mergeready_shape ...
#     Prints the three-way classification of a would-be-ready idle PR:
#     "merge-ready-idle" | "agent-blocked" | "reviewer-defer" | "" (not applicable).
#   pr_mergeready_reasons ...
#     Prints one reason line ONLY for the merge-ready-idle shape; empty otherwise.
#   is_pr_mergeready ...
#     Exit 0 iff the PR is merge-ready-and-idle (the flag; excludes the two shapes).
#   pr_mergeready_is_gated <labels_json>
#     Exit 0 (GATED → never flagged) on an intentional human-gated stop.
#   pr_mergeready_thread_agent_blocked <threads_json> <trusted_bots_csv>
#     Exit 0 when an UNRESOLVED review thread is authored by a Bot outside the
#     trusted set — the #1425 discriminator computed by the scan from the PR's
#     review threads.
#   pr_mergeready_hours_since <iso8601> [now_epoch]
#     Whole hours between a timestamp and now (default: current time).
#   generate_mergeready_report <candidates_tsv_file>
#     Renders the markdown health-report section from a candidates TSV.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Reuse the CANONICAL human-gate check rather than re-deriving it: pr-automation-
# budget.sh owns pr_has_escalation_label (needs-human-review), so this net and the
# budget breaker / stall net agree on what a human-gated stop is (AC#2).
# shellcheck source=scripts/lib/pr-automation-budget.sh
source "${SCRIPT_DIR}/pr-automation-budget.sh"

# Idle threshold — an APPROVED + MERGEABLE + green PR idle longer than this (with
# no agent activity) is a merge-ready-idle CANDIDATE. Default 12h: chosen to alert
# well before #1451's measured 77h. This is a STARTING POINT, not a researched
# constant — #1451's 77h is the only measured data point so far; tune once more
# instances are observed (issue #1469 Dev Notes). Env-overridable (AC#1).
: "${MERGEREADY_MIN_AGE_HOURS:=12}"

# Never-flag labels beyond needs-human-review (which pr_has_escalation_label owns).
# Space-separated; overridable. Same never-release markers the stall net and
# initiative-driver.sh honour (dev-lead:hands-off / initiative:hold).
: "${MERGEREADY_HOLD_LABELS:=dev-lead:hands-off initiative:hold}"

# _mergeready_int <value>
#   Echo <value> as a non-negative integer, or 0 for empty/non-numeric input, so a
#   bad metric can never break the integer comparisons below.
_mergeready_int() {
  case "${1:-}" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$1" ;;
  esac
}

# _mergeready_threshold <value> <default>
#   Like _mergeready_int but falls back to <default> instead of 0 for empty/
#   non-numeric input, so a bad threshold override can never silently drop to 0 and
#   flag every green PR.
_mergeready_threshold() {
  local val="${1:-}" default="${2:-0}"
  case "$val" in
    ''|*[!0-9]*) echo "$default" ;;
    *) echo "$val" ;;
  esac
}

# pr_mergeready_is_gated <labels_json>
#   Exit 0 when the PR is INTENTIONALLY stopped by a human gate — in which case it
#   is NEVER flagged (AC#2, fail-quiet on intentional stops). Gates:
#     • needs-human-review           — via the canonical pr_has_escalation_label
#     • any label in MERGEREADY_HOLD_LABELS (dev-lead:hands-off, initiative:hold)
#   Only removable labels are valid gates (the same reasoning as the stall net):
#   the pr-automation-budget exhaustion marker is an immutable audit comment and is
#   intentionally NOT a gate. Malformed/empty labels degrade to NOT gated (exit 1)
#   so a data glitch fails loud (a real stranded PR is still reported).
pr_mergeready_is_gated() {
  local labels_json="${1:-[]}"
  if pr_has_escalation_label "$labels_json"; then
    return 0
  fi
  local lbl
  local -a hold_labels
  read -r -a hold_labels <<< "$MERGEREADY_HOLD_LABELS"
  for lbl in "${hold_labels[@]}"; do
    if jq -e --arg l "$lbl" \
         'if type == "array" then any(.[]; . == $l) else false end' \
         <<<"$labels_json" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# pr_mergeready_thread_agent_blocked <threads_json> <trusted_bots_csv>
#   The #1425 discriminator. Exit 0 when the PR carries an UNRESOLVED review thread
#   authored by a Bot whose login is OUTSIDE the trusted set — a thread no agent is
#   authorized to resolve, so the PR is agent-BLOCKED rather than merge-ready-idle.
#
#   <threads_json> is the shape scripts/pr_mergeready_scan.sh fetches:
#     {"reviewThreads":[{"isResolved":bool,
#       "comments":{"nodes":[{"author":{"login":..,"__typename":".."}}]}}]}
#   <trusted_bots_csv> is dev-lead's TRUSTED_BOTS (comma-separated, e.g.
#     "copilot-pull-request-reviewer[bot],coderabbitai[bot]"). The `[bot]` suffix is
#   stripped from both sides before comparison because GraphQL author.login omits it.
#
#   Only BOT-authored threads are classified here (author.__typename == "Bot"): the
#   #1425 shape is specifically the untrusted-bot case. A human maintainer thread is
#   a different situation and is deliberately NOT reported by this discriminator.
#   A resolved thread, a trusted-bot thread, no threads, or malformed input all
#   degrade to NOT blocked (exit 1) — fail-quiet, so an undeterminable thread state
#   never wrongly reclassifies a genuinely merge-ready PR as agent-blocked.
pr_mergeready_thread_agent_blocked() {
  local threads_json="${1:-}" trusted_csv="${2:-}"
  [[ -n "$threads_json" ]] || return 1
  # Normalize the trusted set to a JSON array of `[bot]`-suffix-stripped logins.
  local trusted_json
  trusted_json=$(printf '%s' "$trusted_csv" \
    | jq -R 'split(",") | map(sub("\\[bot\\]$"; "")) | map(select(. != ""))' \
      2>/dev/null) || trusted_json='[]'
  [[ -n "$trusted_json" ]] || trusted_json='[]'
  jq -e --argjson trusted "$trusted_json" '
    def strip: sub("\\[bot\\]$"; "");
    if (type != "object") then false
    else
      [ (.reviewThreads // [])[]
        | select(.isResolved != true)
        | (.comments?.nodes?[0]?.author // null) as $a
        | select($a != null)
        | select(($a.__typename // "") == "Bot")
        | (($a.login // "") | strip) as $login
        | select($login != "")
        | select(($trusted | index($login)) == null)
      ] | length > 0
    end
  ' <<<"$threads_json" >/dev/null 2>&1
}

# pr_mergeready_shape <review_decision> <mergeable> <ci_status> <agent_blocked> <hours_idle> <gated>
#   Classify a would-be-ready idle PR into exactly one of the three epic shapes, or
#   nothing when it is not (yet) a candidate. <agent_blocked> / <gated> are
#   "true"/"false". Precedence (each earlier branch excludes the later, so a shape
#   is never double-counted, AC#4):
#     ""                 — gated, recently active, not APPROVED, or not MERGEABLE
#     "reviewer-defer"   — CI pending/zombie check (#1427); an agent is deferring
#     "agent-blocked"    — unresolved untrusted-bot thread (#1425); no agent can act
#     "merge-ready-idle" — APPROVED + MERGEABLE + green + no pending/agent-block,
#                          idle past the threshold (#1469); nobody is acting
#   CI "failing" prints nothing: a failing PR is correctly waiting on a fix, not
#   stranded-ready.
pr_mergeready_shape() {
  local decision="${1:-}" mergeable="${2:-}" ci="${3:-}" \
        agent_blocked="${4:-false}" hours gated="${6:-false}"
  hours=$(_mergeready_int "${5:-0}")

  local min_age
  min_age=$(_mergeready_threshold "${MERGEREADY_MIN_AGE_HOURS}" 12)

  # Fail-quiet on intentional stops (AC#2).
  case "$gated" in
    true|TRUE|1) return 0 ;;
  esac

  # Not a candidate unless idle past the threshold and fully review-/merge-ready.
  [ "$hours" -gt "$min_age" ] || return 0  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449
  [[ "$decision" = "APPROVED" ]] || return 0
  [[ "$mergeable" = "MERGEABLE" ]] || return 0

  # A pending/zombie check means pr-review would defer — the #1427 shape.
  if [[ "$ci" = "pending" ]]; then
    printf 'reviewer-defer\n'
    return 0
  fi
  # Only a green PR can be merge-ready; a failing one is waiting on a fix.
  [[ "$ci" = "passing" ]] || return 0

  # Green + approved + mergeable + idle: agent-blocked (#1425) or truly stranded.
  case "$agent_blocked" in
    true|TRUE|1) printf 'agent-blocked\n'; return 0 ;;
  esac
  printf 'merge-ready-idle\n'
  return 0
}

# pr_mergeready_reasons <...same args as pr_mergeready_shape...>
#   Print a single reason line ONLY when the PR is merge-ready-and-idle (the flag
#   this detector raises); empty for the adjacent shapes and non-candidates. The
#   line names WHY it is distinct from #1425 / #1427 so triage need not re-diagnose.
pr_mergeready_reasons() {
  local shape
  shape=$(pr_mergeready_shape "$@")
  [[ "$shape" = "merge-ready-idle" ]] || return 0

  local hours min_age
  hours=$(_mergeready_int "${5:-0}")
  min_age=$(_mergeready_threshold "${MERGEREADY_MIN_AGE_HOURS}" 12)

  printf 'merge-ready-idle %sh: APPROVED + MERGEABLE + required checks green — no pending check (not #1427), no agent-blocking thread (not #1425) — idle with no agent acting (>%sh)\n' \
    "$hours" "$min_age"
  return 0
}

# is_pr_mergeready <...same args...>
#   Exit 0 iff the PR is merge-ready-and-idle (the flag). The two adjacent shapes
#   return non-zero — they are classified but NOT counted here (AC#4).
is_pr_mergeready() {
  local reasons
  reasons=$(pr_mergeready_reasons "$@")
  [[ -n "$reasons" ]]
}

# pr_mergeready_hours_since <iso8601> [now_epoch]
#   Whole hours since <iso8601>. now_epoch defaults to the current time and is
#   injectable so callers/tests are deterministic. Unparseable input -> 0.
pr_mergeready_hours_since() {
  local ts="${1:-}" now
  now=$(_mergeready_int "${2:-}")
  [ "$now" -gt 0 ] || now=$(date -u +%s)  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449
  local ts_epoch
  ts_epoch=$(date -u -d "$ts" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || true)
  if [[ -z "$ts_epoch" ]]; then
    echo 0
    return 0
  fi
  local diff=$(( now - ts_epoch ))
  if [[ "$diff" -lt 0 ]]; then
    diff=0
  fi
  echo $(( diff / 3600 ))
}

# generate_mergeready_report <candidates_tsv_file>
#   Render the "Merge-Ready but Idle PR Candidates" markdown section for the health
#   report. Input TSV rows: pr_number <TAB> html_url <TAB> title <TAB> reason.
#   An empty/missing file prints an all-clear line and no table, so a clean fleet
#   still gets an explicit signal.
generate_mergeready_report() {
  local f="${1:-}"
  local min_age
  min_age=$(_mergeready_threshold "${MERGEREADY_MIN_AGE_HOURS}" 12)

  printf '## Merge-Ready but Idle PR Candidates\n\n'
  printf 'Open PRs that are **APPROVED + MERGEABLE + green on required checks** yet '
  printf 'have sat idle for over %sh with no agent acting — the "nothing is wrong, ' "$min_age"
  printf 'but nothing is happening either" failure mode (#1451 sat this way for 77h). '
  printf 'This is DISTINCT from #1425 (agent-blocked by an untrusted-bot thread) and '
  printf '#1427 (reviewer deferring on a pending check); both are classified separately '
  printf 'and are NOT counted here. Human-gated halts (needs-human-review, '
  printf 'dev-lead:hands-off, initiative:hold) are excluded. Detection only — no PR is '
  printf 'mutated, nudged, or auto-merged (#1469 AC#3). See #1469 / the #860 post-mortem.\n\n'

  if [[ -z "$f" ]] || [[ ! -s "$f" ]]; then
    printf '✅ No open PR is merge-ready and stranded.\n'
    return 0
  fi

  printf '| PR | Title | Merge-ready signal |\n'
  printf '|---|---|---|\n'
  local num url title reason
  while IFS=$'\t' read -r num url title reason; do
    [[ -n "$num" ]] || continue
    printf '| [#%s](%s) | %s | %s |\n' "$num" "$url" "$title" "$reason"
  done < "$f"
}
