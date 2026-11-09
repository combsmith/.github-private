#!/usr/bin/env bash
# pr-review-sweep-metrics.sh — pure helpers for the pr-review sweep-hit-rate
# metric surfaced on the daily health report (#1408, epic #1402).
#
# The pr-review-sweep scheduled (cron) path is the guaranteed backstop for
# genuinely UN-eventable cases — GitHub-App / cross-repo checks like SonarCloud
# that emit no workflow_run — while the workflow_run fast path handles every
# eventable case near-instantly. The sweep-hit-rate makes "how often does the
# timer actually have to act?" a TRACKED number:
#
#   sweep-hit-rate = scheduled ticks that re-dispatched a review
#                    ÷ total scheduled ticks
#
# Because the scheduled path now fires only for the un-eventable residue, every
# scheduled re-dispatch is by construction a case the event fast path did not
# cover. Interpretation (AC #3): a LOW rate confirms the timer stays
# exception-only; a RISING rate signals an eventable case is leaking onto the
# timer (a hole in the narrowing) and should be investigated.
#
# These functions are PURE: they take telemetry / log text on argv and write to
# stdout. No network, no side effects. Unit-tested in
# tests/pr_review_sweep_metrics.bats. Live gh-API I/O lives in
# scripts/pr_review_health.sh, which sources this.

# pr_review_sweep_hit_rate <sweep_runs_json>
#   Input : JSON array of sweep run objects, each carrying
#             {event, dispatched}
#           where `event` is the triggering event (".event" from the runs API)
#           and `dispatched` is the count of reviews that run re-dispatched
#           (absent/null → treated as 0). Only scheduled ticks (event ==
#           "schedule") are counted — workflow_run fast-path runs are excluded.
#   Output: a single TSV line: ticks<TAB>hits<TAB>rate
#             ticks — number of scheduled sweep ticks in the window
#             hits  — scheduled ticks that re-dispatched ≥1 review
#             rate  — "N%" (integer hits*100/ticks) or "n/a" when ticks == 0
#           Absent/empty JSON → "0\t0\tn/a".
pr_review_sweep_hit_rate() {
  local json="${1:-}"
  [[ -n "$json" ]] || json='[]'
  jq -r '
    (if type == "array" then . else [] end) as $r
    | ([$r[] | select(.event == "schedule")]) as $ticks
    | ($ticks | length) as $n
    | ([$ticks[] | select((.dispatched // 0) > 0)] | length) as $hits
    | if $n == 0 then "0\t0\tn/a"
      else "\($n)\t\($hits)\t\(($hits * 100 / $n) | floor)%"
      end
  ' <<< "$json" 2>/dev/null || printf '0\t0\tn/a\n'
}

# pr_review_sweep_dispatched_from_log <log_text>
#   Parse the review-dispatch count from a sweep run's log. The sweep prints a
#   deterministic summary line:
#     "Sweep summary: inspected N candidate(s), M stuck-green, K review(s) dispatched."
#   Emits K (the dispatched count), or 0 when no summary line is present. Pure:
#   reads the log text on argv, no network.
pr_review_sweep_dispatched_from_log() {
  local log="${1:-}"
  local count
  count=$(printf '%s\n' "$log" \
    | grep -oE '[0-9]+ review\(s\) dispatched' \
    | grep -oE '^[0-9]+' \
    | tail -n1 || true)
  printf '%s' "${count:-0}"
}

# pr_review_render_sweep_hit_rate <sweep_runs_json>
#   Render the sweep-hit-rate as a deterministic Markdown section, including the
#   documented interpretation note (AC #3). Pure: no network. Written by the
#   health script into the report BEFORE any model-generated content so
#   truncation can never discard it (same guarantee as the outcome-mix section).
pr_review_render_sweep_hit_rate() {
  local json="${1:-}" total_in_window="${2:-0}"
  [[ -n "$json" ]] || json='[]'

  local ticks hits rate
  IFS=$'\t' read -r ticks hits rate < <(pr_review_sweep_hit_rate "$json")

  printf '## Sweep hit-rate (deterministic)\n\n'
  printf 'How often the pr-review-sweep **scheduled backstop** actually had to '
  printf 're-review a PR — computed deterministically by `%s`, not the model. ' "pr-review-sweep-metrics.sh"
  printf 'The scheduled (cron) path re-dispatches only for genuinely un-eventable '
  printf 'cases (GitHub-App / cross-repo checks like SonarCloud that emit no '
  printf '`workflow_run`); the `workflow_run` fast path handles every eventable '
  printf 'case, so a scheduled re-dispatch is always a case the fast path did not '
  printf 'cover.\n\n'
  printf '| Metric | Value |\n'
  printf '|---|---:|\n'
  printf '| Scheduled sweep ticks | %s |\n' "$ticks"
  printf '| Ticks that re-dispatched a review (hits) | %s |\n' "$hits"
  printf '| **Sweep hit-rate** | **%s** |\n' "$rate"
  if [ "${total_in_window:-0}" -gt 0 ] && [ "$ticks" -lt "$total_in_window" ]; then
    printf '| _Coverage_ | _%s of %s ticks measured (partial — cap or fetch errors)_ |\n' \
      "$ticks" "$total_in_window"
  fi
  printf '\n'
  printf '_Interpretation:_ a **low** rate confirms the timer stays '
  printf '**exception-only** (the event fast path is carrying the load); a '
  printf '**rising** rate is a signal that an **eventable case is leaking onto '
  printf 'the timer** — a hole in the narrowing worth investigating.\n\n'
}
