#!/usr/bin/env bash
# pr-review-outcomes.sh — pure helpers for the pr-review run-outcome-by-event
# breakdown surfaced on the daily health report (#1422 AC #1, epic #1402).
#
# The pr-review concurrency model admits one running + one pending run per group;
# a third same-group event evicts the older PENDING run, which concludes as
# `cancelled`. Over the 2026-08-02 observation window ~49% of runs were cancelled,
# and a cancelled run rendered as a failing check (#1421). Making the outcome mix a
# TRACKED number — split by the triggering event, since the fan-in is per-event —
# is what turns that cancellation rate from an anecdote into a monitored metric.
#
# These functions are PURE: they take run telemetry JSON on argv and write to
# stdout. No network, no side effects. Unit-tested in tests/pr_review_outcomes.bats.
# main-side network I/O lives in scripts/pr_review_health.sh, which sources this.

# pr_review_outcomes_by_event <runs_json>
#   Input : JSON array of run objects, each carrying {event, conclusion} as
#           returned by the GitHub Actions runs API (.event / .conclusion).
#   Output: TSV, one row per triggering event (sorted by event name) followed by a
#           TOTAL row:
#             event<TAB>success<TAB>cancelled<TAB>skipped<TAB>failure<TAB>total
#           `total` is the count of ALL runs for the event (so in-flight/other
#           conclusions are still counted in the denominator, not silently
#           dropped). `failure` counts both `failure` and `timed_out` conclusions.
#           A run with a null event folds into an "unknown" bucket.
#           Absent/empty JSON → a single zeroed TOTAL row.
pr_review_outcomes_by_event() {
  local json="${1:-}"
  [[ -n "$json" ]] || json='[]'
  jq -r '
    (if type == "array" then . else [] end) as $r
    | ($r
       | group_by(.event // "unknown")
       | map({
           event:     (.[0].event // "unknown"),
           success:   (map(select(.conclusion == "success"))   | length),
           cancelled: (map(select(.conclusion == "cancelled")) | length),
           skipped:   (map(select(.conclusion == "skipped"))   | length),
           failure:   (map(select(.conclusion == "failure" or .conclusion == "timed_out")) | length),
           total:     length
         })
       | sort_by(.event)) as $rows
    | ($rows + [{
          event:     "TOTAL",
          success:   ($rows | map(.success)   | add // 0),
          cancelled: ($rows | map(.cancelled) | add // 0),
          skipped:   ($rows | map(.skipped)   | add // 0),
          failure:   ($rows | map(.failure)   | add // 0),
          total:     ($rows | map(.total)     | add // 0)
        }])
    | .[]
    | [ .event,
        (.success   | tostring),
        (.cancelled | tostring),
        (.skipped   | tostring),
        (.failure   | tostring),
        (.total     | tostring) ]
    | @tsv
  ' <<< "$json" 2>/dev/null || printf 'TOTAL\t0\t0\t0\t0\t0\n'
}

# _pr_review_cancel_rate <cancelled> <total>
#   Integer percentage "N%" of cancelled ÷ total, or "n/a" when total is 0 (a
#   window with no runs must never divide by zero). Internal helper.
_pr_review_cancel_rate() {
  local cancelled="${1:-0}" total="${2:-0}"
  case "${total#-}" in
    ''|*[!0-9]*)
      printf 'n/a'
      return 0
      ;;
  esac
  if [ "$total" -le 0 ]; then
    printf 'n/a'
    return 0
  fi
  case "${cancelled#-}" in
    ''|*[!0-9]*)
      cancelled=0
      ;;
  esac
  printf '%d%%' "$(( cancelled * 100 / total ))"
}

# pr_review_render_outcome_mix <runs_json>
#   Renders the by-event outcome breakdown as a deterministic Markdown section
#   (a table with a cancel-rate column). Pure: no network. Written by the health
#   script into the report BEFORE any model-generated content so truncation can
#   never discard it (same guarantee as the convergence-latency section).
pr_review_render_outcome_mix() {
  local json="${1:-}"
  [[ -n "$json" ]] || json='[]'

  printf '## Run-outcome mix by triggering event\n\n'
  printf 'pr-review run conclusions over the window, split by the event that '
  printf 'triggered each run — computed deterministically by `%s`, not the model. '  "pr-review-outcomes.sh"
  printf 'A high `cancelled` share means runs were evicted while PENDING '
  printf '(concurrency admits one running + one pending per group); a cancelled '
  printf 'run is non-blocking but historically rendered as a failing check (#1421).\n\n'
  printf '| Event | success | cancelled | skipped | failure | total | cancel %% |\n'
  printf '|---|---:|---:|---:|---:|---:|---:|\n'

  local event success cancelled skipped failure total rate label
  while IFS=$'\t' read -r event success cancelled skipped failure total; do
    [[ -n "$event" ]] || continue
    rate="$(_pr_review_cancel_rate "$cancelled" "$total")"
    if [[ "$event" = "TOTAL" ]]; then
      label='**TOTAL**'
    else
      label="\`$event\`"
    fi
    printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
      "$label" "$success" "$cancelled" "$skipped" "$failure" "$total" "$rate"
  done < <(pr_review_outcomes_by_event "$json")

  printf '\n'
}
