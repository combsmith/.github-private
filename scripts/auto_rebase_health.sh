#!/usr/bin/env bash
# auto_rebase_health.sh — Auto-rebase instrumentation report (#737, epic #736).
#
# Measures two things the maintainer needs to make the Merge Queue vs. auto-rebase
# decision with concrete numbers instead of estimates:
#
#   1. Agentic-conflict-resolution rate — how often the auto-rebase conflict
#      sentinel (`<!-- auto-rebase-conflict:`) fires and how often dev-lead emits
#      a `rebase` intent in response. Both are HTML-comment markers that GitHub
#      search cannot index reliably (discussion #735), so we scan the repo's
#      issue comments directly:
#        * sentinels  — comments containing `<!-- auto-rebase-conflict:`
#                       (the marker scripts/dev-lead-intent.sh keys on)
#        * responses  — dev-lead terminal markers `... intent=rebase status=... -->`
#                       posted by scripts/dev-lead-fix-reviews.sh (any status)
#        * applied    — the `status=applied` subset (resolved & force-pushed)
#
#   2. Fan-out CI-run volume — the `Auto-rebase non-Dependabot PRs` workflow
#      (.github/workflows/auto-rebase.yml) runs per push to main and fans
#      branch-update CI re-runs onto behind PRs. Per-run behind-PR counts are not
#      logged in this repo (the update-branch calls live in the central reusable),
#      so the re-run volume is an ESTIMATE: runs × current open non-Dependabot PRs.
#
# Layout (mirrors scripts/token_report.sh):
#   * The count_*/summarize_*/fmt_*/render_report functions are PURE — they take
#     JSON / scalars and write to stdout. Unit-tested in tests/auto_rebase_health.bats.
#   * main() does the network I/O: token selection, comment + run telemetry pulls.
#
# Env vars consumed:
#   GH_TOKEN        — primary token (needs actions:read + repo read on this repo)
#   GH_PAT_FALLBACK — optional fallback PAT if GH_TOKEN lacks run-telemetry access
#   AGENT_REPO      — repo to scan (default: combsmith/.github-private)
#   LOOKBACK_DAYS   — days of history to consider (default: 7)
#   AUTO_REBASE_HEALTH_OUT — optional path; report is written there in addition to stdout
#   GITHUB_STEP_SUMMARY — written by the Actions runner when present

set -euo pipefail

WORKFLOW_REPO="${AGENT_REPO:-combsmith/.github-private}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"
AUTO_REBASE_WORKFLOW="auto-rebase.yml"

# Markers (kept in one place so a rename in the dev-lead scripts is a one-line fix).
SENTINEL_MARKER='<!-- auto-rebase-conflict:'
REBASE_RESPONSE_MARKER='intent=rebase status='
REBASE_APPLIED_MARKER='intent=rebase status=applied'

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested; no network)
# ---------------------------------------------------------------------------

# count_marker <comments_json> <substring>
# Counts comment objects whose `.body` contains <substring>. Absent/empty JSON → 0.
count_marker() {
  local json="${1:-}" needle="${2:-}"
  [ -n "$json" ] || json='[]'
  printf '%s' "$json" | jq --arg n "$needle" \
    '[.[] | select((.body // "") | contains($n))] | length'
}

# summarize_sentinels <comments_json>
# Emits TSV: sentinels<TAB>responses<TAB>applied
#   sentinels — conflict sentinels fired
#   responses — dev-lead rebase intents that ran to a terminal/posted state
#   applied   — the resolved-and-pushed subset of responses
summarize_sentinels() {
  local json="${1:-}"
  [ -n "$json" ] || json='[]'
  printf '%s' "$json" | jq -r \
    --arg sent "$SENTINEL_MARKER" \
    --arg resp "$REBASE_RESPONSE_MARKER" \
    --arg appl "$REBASE_APPLIED_MARKER" '
      [.[] | .body // ""] as $b |
      [
        ([$b[] | select(contains($sent))] | length),
        ([$b[] | select(contains($resp))] | length),
        ([$b[] | select(contains($appl))] | length)
      ] | @tsv'
}

# summarize_runs <runs_json>
# Emits TSV: total<TAB>success<TAB>failed over the auto-rebase run telemetry.
summarize_runs() {
  local json="${1:-}"
  [ -n "$json" ] || json='[]'
  printf '%s' "$json" | jq -r '
    [
      length,
      ([.[] | select(.conclusion == "success")] | length),
      ([.[] | select(.conclusion == "failure")] | length)
    ] | @tsv'
}

# estimate_fanout <run_count> <behind_prs>
# Estimated branch-update CI re-runs = runs × current open non-Dependabot PRs.
estimate_fanout() {
  local runs="${1:-0}" behind="${2:-0}"
  echo $(( runs * behind ))
}

# fmt_rate <num> <denom>
# Integer percentage with a zero-denominator guard ("n/a"), so a window with no
# sentinels never divides by zero.
fmt_rate() {
  local num="${1:-0}" denom="${2:-0}"
  if [ "$denom" -le 0 ]; then
    echo "n/a"
    return 0
  fi
  echo "$(( num * 100 / denom ))%"
}

# render_report <comments_json> <runs_json> <lookback_days> <behind_prs> [today]
# Writes the full Markdown report to stdout. Pure: no network.
render_report() {
  local comments_json="${1:-[]}" runs_json="${2:-[]}"
  local lookback="${3:-7}" behind="${4:-0}" today="${5:-}"
  [ -n "$today" ] || today="$(date -u +%Y-%m-%d)"

  local sentinels responses applied
  IFS=$'\t' read -r sentinels responses applied < <(summarize_sentinels "$comments_json")

  local total success failed
  IFS=$'\t' read -r total success failed < <(summarize_runs "$runs_json")

  local fanout
  fanout="$(estimate_fanout "$total" "$behind")"

  local runs_per_day rerun_per_day
  runs_per_day="$(awk -v t="$total" -v d="$lookback" 'BEGIN { printf "%.1f", (d > 0 ? t / d : 0) }')"
  rerun_per_day="$(awk -v t="$fanout" -v d="$lookback" 'BEGIN { printf "%.1f", (d > 0 ? t / d : 0) }')"

  printf '# 🔁 Auto-rebase Health — %s\n\n' "$today"
  printf '_Repo `%s` · lookback %s day(s)_\n\n' "$WORKFLOW_REPO" "$lookback"

  printf '## Agentic conflict-resolution rate\n\n'
  printf -- '- **Sentinels fired** (`%s`): %s\n' "$SENTINEL_MARKER" "$sentinels"
  printf -- '- **Dev-lead rebase responses** (`intent=rebase`): %s\n' "$responses"
  printf -- '- **Resolved & pushed** (`status=applied`): %s\n' "$applied"
  printf -- '- **Resolution rate** (responses ÷ sentinels): %s\n' "$(fmt_rate "$responses" "$sentinels")"
  printf -- '- **Applied rate** (applied ÷ sentinels): %s\n\n' "$(fmt_rate "$applied" "$sentinels")"

  printf '## Auto-rebase fan-out volume (estimate)\n\n'
  printf -- '- **Workflow runs** (`%s`): %s total · %s success · %s failed\n' \
    "$AUTO_REBASE_WORKFLOW" "$total" "$success" "$failed"
  printf -- '- **Behind-PR multiplier** (open non-Dependabot PRs): %s\n' "$behind"
  printf -- '- **Estimated branch-update CI re-runs**: ~%s\n' "$fanout"
  printf -- '- **Per-day baseline**: %s auto-rebase run(s)/day · ~%s CI re-run(s)/day\n\n' \
    "$runs_per_day" "$rerun_per_day"
  printf '> Fan-out is an **estimate** — per-run behind-PR counts are not logged in this repo, '
  printf 'so re-runs = runs × current open non-Dependabot PR count.\n'
}

# ---------------------------------------------------------------------------
# Network I/O (main)
# ---------------------------------------------------------------------------

main() {
  local today cutoff
  today="$(date -u +%Y-%m-%d)"
  # GNU date: -d "N days ago"; BSD/macOS: -v-Nd
  cutoff="$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)"

  echo "=== Auto-rebase Health Report ===" >&2
  echo "  Repo:     $WORKFLOW_REPO" >&2
  echo "  Lookback: ${LOOKBACK_DAYS} day(s) (since ${cutoff})" >&2
  echo "  Date:     $today" >&2

  # Token selection — verify run-telemetry access; fall back to a PAT if needed.
  if ! gh api "repos/${WORKFLOW_REPO}/actions/workflows/${AUTO_REBASE_WORKFLOW}/runs?per_page=1" \
       >/dev/null 2>&1; then
    if [ -n "${GH_PAT_FALLBACK:-}" ]; then
      echo "::warning::GH_TOKEN cannot read ${AUTO_REBASE_WORKFLOW} runs — using GH_PAT_FALLBACK" >&2
      export GH_TOKEN="$GH_PAT_FALLBACK"
    else
      echo "::error::GH_TOKEN cannot read ${AUTO_REBASE_WORKFLOW} run telemetry and GH_PAT_FALLBACK is unset." >&2
      echo "::error::Grant actions:read on ${WORKFLOW_REPO} or set the fallback PAT secret." >&2
      exit 1
    fi
  fi

  # 1. Comments — the issues/comments endpoint covers PR comments too (PRs are
  #    issues), and `since` filters server-side so we only pull the window.
  local comments_json
  comments_json="$(gh api \
    "repos/${WORKFLOW_REPO}/issues/comments?since=${cutoff}&per_page=100" --paginate \
    --jq '.[] | {body, created_at, html_url}' 2>/dev/null \
    | jq -s '.' 2>/dev/null || echo '[]')"

  # 2. Auto-rebase run telemetry. --paginate so long manual-dispatch windows are
  #    not silently truncated at 100 runs (GitHub still caps created>= at 1,000).
  local runs_json
  runs_json="$(gh api \
    "repos/${WORKFLOW_REPO}/actions/workflows/${AUTO_REBASE_WORKFLOW}/runs?per_page=100&created=>=${cutoff}" \
    --paginate --jq '.workflow_runs | map({conclusion, created_at})' 2>/dev/null \
    | jq -s 'add // []' 2>/dev/null || echo '[]')"

  # 3. Behind-PR multiplier — open non-Dependabot PRs (proxy for branches the
  #    fan-out updates). Best-effort; defaults to 0 so the report still renders.
  local behind
  behind="$(gh pr list --repo "$WORKFLOW_REPO" --state open --limit 200 --json author \
    --jq '[.[] | select((.author?.login // "") | test("dependabot"; "i") | not)] | length' \
    2>/dev/null || echo 0)"

  local report
  report="$(render_report "$comments_json" "$runs_json" "$LOOKBACK_DAYS" "$behind" "$today")"

  printf '%s\n' "$report"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$report" >> "$GITHUB_STEP_SUMMARY"
  fi
  if [ -n "${AUTO_REBASE_HEALTH_OUT:-}" ]; then
    printf '%s\n' "$report" > "$AUTO_REBASE_HEALTH_OUT"
  fi
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
