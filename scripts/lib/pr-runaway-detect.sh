#!/usr/bin/env bash
set -euo pipefail
# pr-runaway-detect.sh — the runaway-PR DETECTION net (issue #948, #860 follow-up).
#
# #860 ran away to 378 commits / 1,582 comments produced entirely by agents
# looping — and ran for FOUR DAYS with no human noticing, because detection was
# pull (someone happens to look), not push. The per-PR budget (#926) and the org
# self-trigger fix *prevent/bound* runaways; this library is the complementary
# *signal* so the next novel runaway surface is flagged on day one.
#
# It is a set of PURE functions: given a PR's already-gathered metrics, decide
# whether the PR is a runaway CANDIDATE and which soft threshold(s) it crossed.
# It never mutates a PR — surfacing/routing is the caller's job
# (scripts/pr_runaway_scan.sh, wired into the daily health check).
#
#   pr_runaway_reasons <commits> <comments> <cycles> <age_hours>
#     Prints one human-readable reason line per crossed threshold; nothing when
#     the PR is within all thresholds. This is the unit under test.
#   is_pr_runaway <commits> <comments> <cycles> <age_hours>
#     Exit 0 when ANY threshold is crossed, 1 otherwise.
#   pr_age_hours <created_at_iso8601> [now_epoch]
#     Whole hours between created_at and now (default: current time).
#   generate_runaway_report <candidates_tsv_file>
#     Renders the markdown health-report section from a candidates TSV.
#
# Thresholds are SOFT and env-overridable with sane defaults (AC#2). All are
# strict greater-than ("> 50 commits", etc.), matching the issue wording. The
# age criterion additionally requires ACTIVE agent churn (>= RUNAWAY_CHURN_MIN_
# CYCLES automated cycles since the last human) so a normal PR that merely sat
# open past 48h with no agent activity does NOT false-positive (AC#3).

# Soft thresholds — a PR is a candidate when it exceeds ANY of these.
: "${RUNAWAY_MAX_COMMITS:=50}"       # > this many commits
: "${RUNAWAY_MAX_COMMENTS:=200}"     # > this many issue comments
: "${RUNAWAY_MAX_CYCLES:=25}"        # > this many automated cycles: half the #926 cap, p95 of PRs (#2224)
: "${RUNAWAY_MIN_AGE_HOURS:=48}"     # open longer than this, AND churning
: "${RUNAWAY_CHURN_MIN_CYCLES:=1}"   # min cycles that count as "active churn"

# Merge-stacked (rebase/squash-candidate) smell — issue #949, #860 follow-up.
# #860's branch carried a stale April base and was repeatedly `merge main`-d
# instead of rebased, inflating it to 378 commits for an 18-file net diff. That
# disproportion — a commit count that vastly exceeds the changed-file count — is
# the tell of a branch that should have been rebased/squashed. It fires only when
# BOTH conditions hold (so a genuinely broad PR with many files does not flag).
: "${REBASE_SMELL_MIN_COMMITS:=50}"  # > this many commits, AND
: "${REBASE_SMELL_MAX_FILES:=20}"    # < this many changed files

# _runaway_int <value>
#   Echo the value as a non-negative integer, or 0 for empty/non-numeric input.
#   Mirrors the defensive degradation in pr-automation-budget.sh so a bad metric
#   can never break the integer comparisons below ("integer expression expected").
_runaway_int() {
  case "${1:-}" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$1" ;;
  esac
}

# _runaway_threshold <value> <default>
#   Like _runaway_int but falls back to <default> instead of 0 for empty/non-numeric
#   input. Used for threshold env vars so a bad override can never silently set a
#   threshold to 0 and spam every open PR as a runaway candidate.
_runaway_threshold() {
  local val="${1:-}" default="${2:-0}"
  case "$val" in
    ''|*[!0-9]*) echo "$default" ;;
    *) echo "$val" ;;
  esac
}

# pr_runaway_reasons <commits> <comments> <cycles> <age_hours>
#   Print one reason line per crossed soft threshold (empty when within bounds).
pr_runaway_reasons() {
  local commits comments cycles age
  commits=$(_runaway_int "${1:-0}")
  comments=$(_runaway_int "${2:-0}")
  cycles=$(_runaway_int "${3:-0}")
  age=$(_runaway_int "${4:-0}")

  local max_commits max_comments max_cycles min_age churn_floor
  max_commits=$(_runaway_threshold "${RUNAWAY_MAX_COMMITS}" 50)
  max_comments=$(_runaway_threshold "${RUNAWAY_MAX_COMMENTS}" 200)
  max_cycles=$(_runaway_threshold "${RUNAWAY_MAX_CYCLES}" 25)
  min_age=$(_runaway_threshold "${RUNAWAY_MIN_AGE_HOURS}" 48)
  churn_floor=$(_runaway_threshold "${RUNAWAY_CHURN_MIN_CYCLES}" 1)

  [ "$commits" -gt "$max_commits" ] && \
    printf 'commits: %s (>%s)\n' "$commits" "$max_commits"
  [ "$comments" -gt "$max_comments" ] && \
    printf 'comments: %s (>%s)\n' "$comments" "$max_comments"
  [ "$cycles" -gt "$max_cycles" ] && \
    printf 'automated cycles: %s (>%s)\n' "$cycles" "$max_cycles"
  if [ "$age" -gt "$min_age" ] && [ "$cycles" -ge "$churn_floor" ]; then
    printf 'open %sh with agent churn (%s cycles, >%sh)\n' \
      "$age" "$cycles" "$min_age"
  fi
  return 0
}

# is_pr_runaway <commits> <comments> <cycles> <age_hours>
#   Exit 0 when the PR crosses any soft threshold, 1 otherwise.
is_pr_runaway() {
  local reasons
  reasons=$(pr_runaway_reasons "$@")
  [ -n "$reasons" ]
}

# pr_rebase_smell <commits> <changed_files>
#   Print a single "rebase/squash candidate" reason line when a PR's commit count
#   vastly exceeds its changed-file count — the #860 merge-stacking signature (378
#   commits for an 18-file net diff), see #949. Fires only when
#   commits > REBASE_SMELL_MIN_COMMITS AND 0 < changed_files < REBASE_SMELL_MAX_FILES.
#   The 0-file guard is deliberate: a zero-file diff is an API/data glitch, not a
#   merge-stacked branch, and must not false-positive. Empty output otherwise.
pr_rebase_smell() {
  local commits files min_commits max_files
  commits=$(_runaway_int "${1:-0}")
  files=$(_runaway_int "${2:-0}")
  min_commits=$(_runaway_threshold "${REBASE_SMELL_MIN_COMMITS}" 50)
  max_files=$(_runaway_threshold "${REBASE_SMELL_MAX_FILES}" 20)

  if [ "$commits" -gt "$min_commits" ] && [ "$files" -gt 0 ] && [ "$files" -lt "$max_files" ]; then
    printf 'merge-stacked: %s commits / %s files — rebase/squash candidate (>%s commits, <%s files)\n' \
      "$commits" "$files" "$min_commits" "$max_files"
  fi
  return 0
}

# pr_age_hours <created_at_iso8601> [now_epoch]
#   Whole hours since created_at. now_epoch defaults to the current time; it is
#   injectable so callers/tests are deterministic. Unparseable input -> 0.
pr_age_hours() {
  local created="${1:-}" now
  now=$(_runaway_int "${2:-}")
  [ "$now" -gt 0 ] || now=$(date -u +%s)
  local created_epoch
  created_epoch=$(date -u -d "$created" +%s 2>/dev/null || date -u -v0d -f "%Y-%m-%dT%H:%M:%SZ" "$created" +%s 2>/dev/null || true)
  if [ -z "$created_epoch" ]; then
    echo 0
    return 0
  fi
  local diff=$(( now - created_epoch ))
  [ "$diff" -lt 0 ] && diff=0
  echo $(( diff / 3600 ))
}

# generate_runaway_report <candidates_tsv_file>
#   Render the "Runaway PR Candidates" markdown section for the health report.
#   Input TSV rows: pr_number <TAB> html_url <TAB> title <TAB> reasons
#   (reasons already joined with "; "). An empty/missing file prints an
#   all-clear line and no table, so a clean fleet still gets an explicit signal.
generate_runaway_report() {
  local f="${1:-}"
  local max_commits max_comments max_cycles min_age smell_commits smell_files
  max_commits=$(_runaway_threshold "${RUNAWAY_MAX_COMMITS}" 50)
  max_comments=$(_runaway_threshold "${RUNAWAY_MAX_COMMENTS}" 200)
  max_cycles=$(_runaway_threshold "${RUNAWAY_MAX_CYCLES}" 25)
  min_age=$(_runaway_threshold "${RUNAWAY_MIN_AGE_HOURS}" 48)
  smell_commits=$(_runaway_threshold "${REBASE_SMELL_MIN_COMMITS}" 50)
  smell_files=$(_runaway_threshold "${REBASE_SMELL_MAX_FILES}" 20)

  printf '## Runaway PR Candidates\n\n'
  printf 'Open PRs exceeding a soft runaway threshold '
  printf '(commits >%s, comments >%s, automated cycles >%s, open >%sh with agent churn, ' \
    "$max_commits" "$max_comments" "$max_cycles" "$min_age"
  printf 'or merge-stacked: >%s commits with <%s files — a rebase/squash candidate). ' \
    "$smell_commits" "$smell_files"
  printf 'Detection only — no PR is mutated. See #948 / #949 / the #860 post-mortem.\n\n'

  if [ -z "$f" ] || [ ! -s "$f" ]; then
    printf '✅ No open PR crossed a runaway threshold.\n'
    return 0
  fi

  printf '| PR | Title | Triggering metric(s) |\n'
  printf '|---|---|---|\n'
  local num url title reasons
  while IFS=$'\t' read -r num url title reasons; do
    [ -n "$num" ] || continue
    printf '| [#%s](%s) | %s | %s |\n' "$num" "$url" "$title" "$reasons"
  done < "$f"
}
