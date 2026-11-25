#!/usr/bin/env bash
set -euo pipefail
# pr-stall-detect.sh — the STALL DETECTION net for the Class-2 timer narrowing
# (issue #1410, epic #1402). The instrument built BEFORE `dev-lead-retry` and
# `pr-review-sweep` are narrowed (#1407 / #1408), so a genuinely un-eventable
# transition that used to be caught only by the cron backstop is still caught —
# as a PUSHED signal — instead of stalling unseen.
#
# It is the mirror image of scripts/lib/pr-runaway-detect.sh: the runaway net
# flags a PR with too MUCH automated activity; this net flags one with too
# LITTLE — an open PR that is CI-green and REVIEW_REQUIRED (awaiting an automated
# review step), with no agent activity and no pending triggering event, for
# longer than a configurable threshold. That is the precise failure mode a
# narrowed timer could introduce: CI settles green with no `workflow_run` fast
# path (a cross-repo or GitHub-App check like SonarCloud), and once the cron is
# narrowed nothing re-dispatches the review.
#
# Like pr-runaway-detect.sh this is a set of PURE functions given already-gathered
# PR metrics; it NEVER mutates a PR. Surfacing is the caller's job
# (scripts/pr_stall_scan.sh, wired into the daily health check — no new cron).
#
#   pr_stall_reasons <ci_status> <review_decision> <reviewed_at_head> <mins_idle> <gated>
#     Prints one reason line when the PR is stalled; nothing otherwise. The unit
#     under test. <gated> is "true"/"false" — computed by pr_stall_is_gated.
#   is_pr_stall <...same args...>
#     Exit 0 when the PR is stalled, 1 otherwise.
#   pr_stall_is_gated <labels_json>
#     Exit 0 (GATED → never a stall) when the PR carries an INTENTIONAL, human-
#     gated stop: needs-human-review, dev-lead:hands-off, or initiative:hold.
#     This is AC#2's fail-quiet clause.
#   pr_minutes_since <iso8601> [now_epoch]
#     Whole minutes between a timestamp and now (default: current time).
#   generate_stall_report <candidates_tsv_file>
#     Renders the markdown health-report section from a candidates TSV.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Reuse the CANONICAL human-gate check rather than re-deriving it: pr-automation-
# budget.sh owns pr_has_escalation_label (needs-human-review) and the exhaustion
# marker constant, so the stall net and the budget breaker agree on what a
# human-gated stop is (AC#2).
# shellcheck source=scripts/lib/pr-automation-budget.sh
source "${SCRIPT_DIR}/pr-automation-budget.sh"

# Idle threshold — a PR green + REVIEW_REQUIRED longer than this (with no agent
# activity) is a stall CANDIDATE. Default 30 min: double the pr-review-sweep
# scheduled backstop cadence (≤15 min, `2,17,32,47 * * * *`), so a candidate has
# outlived at least two full backstop windows — a genuine stall, not a PR merely
# in flight. Env-overridable (AC#1).
# TASK FOR #1408: when pr-review-sweep's cron is narrowed, re-derive this default
# so it remains ≥ 2× the new backstop interval (see §11.1 of
# docs/agentic-interaction-model.md — the derivation is stale once the cadence changes).
: "${STALL_MIN_AGE_MINUTES:=30}"

# Never-release labels beyond needs-human-review (which pr_has_escalation_label
# owns). Space-separated; overridable. These are the same never-release markers
# initiative-driver.sh honours (dev-lead:hands-off / initiative:hold).
: "${STALL_HOLD_LABELS:=dev-lead:hands-off initiative:hold}"

# Stranded-approval idle threshold in HOURS (#1665 AC8). A PR that is CI-green
# with auto-merge ARMED but carries NO standing approval will never merge; if it
# also sits idle (no sweep re-dispatch, no review activity) longer than this, it
# is the silent strand #1665 fixes in the sweep — surfaced here as a pushed
# backstop signal. Default 4h: well past the sweep's sub-15-min backstop cadence,
# so a candidate has outlived many re-dispatch windows and is a genuine strand,
# not a PR merely between review runs. Env-overridable.
: "${STRANDED_APPROVAL_MIN_HOURS:=4}"

# _stall_int <value>
#   Echo <value> as a non-negative integer, or 0 for empty/non-numeric input.
#   Mirrors pr-runaway-detect.sh so a bad metric can never break the integer
#   comparisons below ("integer expression expected").
_stall_int() {
  case "${1:-}" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$1" ;;
  esac
}

# _stall_threshold <value> <default>
#   Like _stall_int but falls back to <default> instead of 0 for empty/non-numeric
#   input, so a bad threshold override can never silently drop to 0 and flag every
#   green PR as a stall.
_stall_threshold() {
  local val="${1:-}" default="${2:-0}"
  case "$val" in
    ''|*[!0-9]*) echo "$default" ;;
    *) echo "$val" ;;
  esac
}

# pr_stall_is_gated <labels_json>
#   Exit 0 when the PR is INTENTIONALLY stopped by a human gate — in which case it
#   is NEVER a stall (AC#2, fail-quiet on intentional stops). Gates:
#     • needs-human-review           — via the canonical pr_has_escalation_label
#     • any label in STALL_HOLD_LABELS (dev-lead:hands-off, initiative:hold)
#   The pr-automation-budget exhaustion marker is intentionally excluded: it is an
#   immutable audit comment that can never be cleared, so gating on it would
#   permanently suppress stall detection after a re-engaged PR removes
#   needs-human-review. Only removable labels are valid gates (see pr-automation-
#   budget.sh pr_has_escalation_label for the same reasoning).
#   Malformed/empty labels degrade to NOT gated (exit 1) so a data glitch fails
#   loud (a real stall is still reported) rather than quietly suppressing one.
pr_stall_is_gated() {
  local labels_json="${1:-[]}"
  if pr_has_escalation_label "$labels_json"; then
    return 0
  fi
  local lbl
  for lbl in $STALL_HOLD_LABELS; do
    if jq -e --arg l "$lbl" \
         'if type == "array" then any(.[]; . == $l) else false end' \
         <<<"$labels_json" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# pr_stall_reasons <ci_status> <review_decision> <reviewed_at_head> <mins_idle> <gated>
#   Print a single reason line when the PR is stalled, empty otherwise. A stall is
#   the actionable-but-unresolved state: CI green, GitHub still wants a review
#   (REVIEW_REQUIRED), no review has landed at the current head, and it has been
#   idle past STALL_MIN_AGE_MINUTES — AND the PR is not human-gated.
pr_stall_reasons() {
  local ci="${1:-}" decision="${2:-}" reviewed mins gated="${5:-false}"
  reviewed=$(_stall_int "${3:-0}")
  mins=$(_stall_int "${4:-0}")

  local min_age
  min_age=$(_stall_threshold "${STALL_MIN_AGE_MINUTES}" 30)

  # Fail-quiet on intentional stops (AC#2): a human-gated PR is never a stall.
  case "$gated" in
    true|TRUE|1) return 0 ;;
  esac

  # Only the actionable-but-unresolved state can stall.
  [[ "$ci" = "passing" ]] || return 0
  [[ "$decision" = "REVIEW_REQUIRED" ]] || return 0
  [ "$reviewed" -eq 0 ] || return 0
  [ "$mins" -gt "$min_age" ] || return 0

  printf 'stalled %sm: CI-green + REVIEW_REQUIRED, no agent activity or pending event (>%sm)\n' \
    "$mins" "$min_age"
  return 0
}

# is_pr_stall <...same args as pr_stall_reasons...>
#   Exit 0 when the PR is stalled, 1 otherwise.
is_pr_stall() {
  local reasons
  reasons=$(pr_stall_reasons "$@")
  [[ -n "$reasons" ]]
}

# pr_minutes_since <iso8601> [now_epoch]
#   Whole minutes since <iso8601>. now_epoch defaults to the current time and is
#   injectable so callers/tests are deterministic. Unparseable input -> 0.
pr_minutes_since() {
  local ts="${1:-}" now
  now=$(_stall_int "${2:-}")
  [ "$now" -gt 0 ] || now=$(date -u +%s)
  local ts_epoch
  ts_epoch=$(date -u -d "$ts" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || true)
  if [[ -z "$ts_epoch" ]]; then
    echo 0
    return 0
  fi
  local diff=$(( now - ts_epoch ))
  if [ "$diff" -lt 0 ]; then
    diff=0
  fi
  echo $(( diff / 60 ))
}

# generate_stall_report <candidates_tsv>
#   Render the "Stalled PR Candidates" markdown section for the health report.
#   Input: TSV rows (one per line) pr_number <TAB> html_url <TAB> title <TAB> reason,
#   passed as a single string (no temp file). Empty/blank input prints an all-clear
#   line and no table, so a clean fleet still gets an explicit signal.
generate_stall_report() {
  local content="${1:-}"
  local min_age
  min_age=$(_stall_threshold "${STALL_MIN_AGE_MINUTES}" 30)

  printf '## Stalled PR Candidates\n\n'
  printf 'Open PRs stuck **CI-green + REVIEW_REQUIRED** with no agent activity and '
  printf 'no pending triggering event for over %sm — the un-eventable-transition ' "$min_age"
  printf 'failure mode the narrowed Class-2 timers (#1407/#1408) could introduce. '
  printf 'Human-gated halts (needs-human-review, dev-lead:hands-off, initiative:hold) are excluded. '
  printf 'Detection only — no PR is mutated. See #1410 / the #860 post-mortem (detection must be pushed).\n\n'

  if [[ -z "$content" ]]; then
    printf '✅ No open PR is stalled.\n'
    return 0
  fi

  printf '| PR | Title | Stall signal |\n'
  printf '|---|---|---|\n'
  local num url title reason
  while IFS=$'\t' read -r num url title reason; do
    [[ -n "$num" ]] || continue
    printf '| [#%s](%s) | %s | %s |\n' "$num" "$url" "$title" "$reason"
  done <<< "$content"
}

# ---------------------------------------------------------------------------
# Stranded-approval backstop (issue #1665 AC8) — detect-only observability.
#
# The dual of the stall net for the marker-vs-standing-approval bug. A PR that is
# CI-green with auto-merge ARMED but NO standing approval (its only "approval" is
# a non-standing marker: a dismissed review or an issue comment) will never merge
# — nothing stands to satisfy the gate. If it also sits idle past
# STRANDED_APPROVAL_MIN_HOURS (no sweep re-dispatch, no review activity), that is
# exactly the silent strand #1665 fixes in the sweep, surfaced as a pushed signal
# in case a residual path still strands such a PR. Pure functions; never mutate.
# ---------------------------------------------------------------------------

# pr_stranded_approval_reasons <ci_status> <auto_merge_armed> <standing_approval> <hours_idle> <gated>
#   Print a single reason line when the PR is a stranded-approval candidate, empty
#   otherwise: CI green, auto-merge armed, zero standing approvals, idle past
#   STRANDED_APPROVAL_MIN_HOURS — AND not human-gated (fail-quiet on intentional
#   stops, same clause as the stall net). Non-numeric metrics degrade to 0.
pr_stranded_approval_reasons() {
  local ci="${1:-}" armed="${2:-false}" standing hours gated="${5:-false}"
  standing=$(_stall_int "${3:-0}")
  hours=$(_stall_int "${4:-0}")

  local min_hours
  min_hours=$(_stall_threshold "${STRANDED_APPROVAL_MIN_HOURS}" 4)

  # Fail-quiet on intentional stops: a human-gated PR is never reported.
  case "$gated" in
    true|TRUE|1) return 0 ;;
  esac

  # Only a green, auto-merge-armed PR with no standing approval can strand.
  [[ "$ci" = "passing" ]] || return 0
  case "$armed" in
    true|TRUE|1) ;;
    *) return 0 ;;
  esac
  [ "$standing" -eq 0 ] || return 0
  [ "$hours" -gt "$min_hours" ] || return 0

  printf 'stranded %sh: CI-green + auto-merge armed, no standing approval (>%sh)\n' \
    "$hours" "$min_hours"
  return 0
}

# is_pr_stranded_approval <...same args as pr_stranded_approval_reasons...>
#   Exit 0 when the PR is a stranded-approval candidate, 1 otherwise.
is_pr_stranded_approval() {
  local reasons
  reasons=$(pr_stranded_approval_reasons "$@")
  [[ -n "$reasons" ]]
}

# generate_stranded_approval_report <candidates_tsv>
#   Render the "Stranded-Approval PR Candidates" markdown section for the health
#   report. Input: TSV rows (one per line) pr_number <TAB> html_url <TAB> title
#   <TAB> reason, passed as a single string (no temp file). Empty/blank input
#   prints an all-clear line and no table.
generate_stranded_approval_report() {
  local content="${1:-}"
  local min_hours
  min_hours=$(_stall_threshold "${STRANDED_APPROVAL_MIN_HOURS}" 4)

  printf '## Stranded-Approval PR Candidates\n\n'
  printf 'Open PRs stuck **CI-green + auto-merge armed** with **no standing approval** '
  printf '(no approving review stands at head — whether never approved, dismissed, or '
  printf 'approved only via a non-standing marker such as an issue comment) and no '
  printf 'sweep re-dispatch for over %sh — the marker-vs-standing-approval strand #1665 ' "$min_hours"
  printf 'fixes in the sweep, surfaced here as a backstop. '
  printf 'Human-gated halts (needs-human-review, dev-lead:hands-off, initiative:hold) are excluded. '
  printf 'Detection only — no PR is mutated.\n\n'

  if [[ -z "$content" ]]; then
    printf '✅ No open PR has a stranded approval.\n'
    return 0
  fi

  printf '| PR | Title | Stranded-approval signal |\n'
  printf '|---|---|---|\n'
  local num url title reason
  while IFS=$'\t' read -r num url title reason; do
    [[ -n "$num" ]] || continue
    printf '| [#%s](%s) | %s | %s |\n' "$num" "$url" "$title" "$reason"
  done <<< "$content"
}
