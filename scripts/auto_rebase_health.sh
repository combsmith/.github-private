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
#   3. Fleet merge-state observability (AC7, #1440) — a snapshot of how many open
#      non-draft, non-Dependabot PRs are currently `mergeStateStatus: BEHIND` vs
#      DIRTY. This makes the effectiveness of the AC1/AC2 auto-rebase fixes
#      (petry-projects/.github#926) measurable per run without another manual
#      audit. Repo-scoped — fleet-wide would need a cross-repo PAT this report
#      does not carry.
#
#   4. Base-merge necessity (#1881) — a deterministic counter that splits the open
#      BEHIND queue into base merges that are genuinely REQUIRED (being behind
#      blocks the PR: the ruleset requires up-to-date branches, or the PR is queued
#      to merge, or it carries the explicit request label) vs SKIPPABLE no-ops. The
#      required/skippable split is derived from repository configuration (the
#      ruleset's `strict_required_status_checks_policy`), so if strict is re-armed
#      the counter follows with no code change. `skippable` is the no-op base-merge
#      volume #1881 removes at the source — the second input to #1864 AC #4 alongside
#      #1865's `reviews_carried_forward`. The gate that acts on this lives in the
#      central auto-rebase reusable; this report only measures it.
#
# Layout (mirrors scripts/token_report.sh):
#   * The count_*/summarize_*/fmt_*/render_report functions are PURE — they take
#     JSON / scalars and write to stdout. Unit-tested in tests/auto_rebase_health.bats.
#   * main() does the network I/O: token selection, comment + run telemetry pulls.
#
# Env vars consumed:
#   GH_TOKEN        — primary token (needs actions:read + repo read on this repo)
#   GH_PAT_FALLBACK — optional fallback PAT if GH_TOKEN lacks run-telemetry access
#   AGENT_REPO      — repo to scan (default: petry-projects/.github-private)
#   LOOKBACK_DAYS   — days of history to consider (default: 7)
#   PR_LIST_LIMIT   — max open PRs fetched for BEHIND/DIRTY/multiplier metrics (default: 1000)
#                     raise if the repo regularly has >1000 open PRs; a truncation warning
#                     is rendered in the report whenever the fetched count equals the limit
#   AUTO_REBASE_HEALTH_OUT — optional path; report is written there in addition to stdout
#   GITHUB_STEP_SUMMARY — written by the Actions runner when present

set -euo pipefail

WORKFLOW_REPO="${AGENT_REPO:-petry-projects/.github-private}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"
PR_LIST_LIMIT="${PR_LIST_LIMIT:-1000}"
AUTO_REBASE_WORKFLOW="auto-rebase.yml"

# Markers (kept in one place so a rename in the dev-lead scripts is a one-line fix).
SENTINEL_MARKER='<!-- auto-rebase-conflict:'
REBASE_RESPONSE_MARKER='intent=rebase status='
REBASE_APPLIED_MARKER='intent=rebase status=applied'

# Label a human/PR can add to explicitly demand an up-to-date branch even when the
# ruleset does not require it — the "or a human/label requests it" arm of #1881 AC #1.
# Same label the central reusable's review-ready eligibility predicate already honours.
AUTO_REBASE_REQUEST_LABEL="${AUTO_REBASE_REQUEST_LABEL:-auto-rebase:ready}"
# Branch whose ruleset drives the up-to-date policy. Left empty by default so
# main() resolves the repo's ACTUAL default branch — an AGENT_REPO whose default
# branch is not `main` would otherwise have its rules read from the wrong branch.
# Set this env to pin a specific branch and skip the lookup.
DEFAULT_BRANCH="${DEFAULT_BRANCH:-}"

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

# summarize_merge_states <prs_json>
# Emits TSV: behind<TAB>dirty — counts of open PRs whose GitHub `mergeStateStatus`
# is BEHIND (head is behind base; needs an auto-rebase update) vs DIRTY (merge
# conflict; needs human/agent resolution), over the subset of PRs that are
# non-draft AND non-Dependabot-authored. This is the AC7 observability metric
# (#1440): it makes the effectiveness of the AC1/AC2 fixes measurable per run.
# Input JSON is an array of {mergeStateStatus, isDraft, author:{login}} objects
# (as returned by `gh pr list --json mergeStateStatus,isDraft,author`).
# Absent/empty JSON → "0\t0".
summarize_merge_states() {
  local json="${1:-}"
  [ -n "$json" ] || json='[]'
  jq -r '
    [ .[]
      | select((.isDraft // false) | not)
      | select(((.author?.login // "" | tostring) | test("dependabot"; "i")) | not)
    ] as $prs |
    [
      ([$prs[] | select(.mergeStateStatus == "BEHIND")] | length),
      ([$prs[] | select(.mergeStateStatus == "DIRTY")]  | length)
    ] | @tsv' <<< "$json"
}

# strict_from_branch_rules <rules_json>
# Reads whether the default branch's ruleset requires PRs to be up to date with
# base — the `strict_required_status_checks_policy` flag (#1864). Input is the JSON
# array from `gh api repos/{repo}/rules/branches/<branch>`. Echoes "true" iff some
# active required_status_checks rule sets that policy true, else "false". This is
# the config-derived condition of #1881 AC #2: if strict is re-armed later the flag
# flips with no code change. Absent/empty/unparseable input → "false".
strict_from_branch_rules() {
  local json="${1:-}"
  [ -n "$json" ] || json='[]'
  local r
  r="$(printf '%s' "$json" | jq -r '
    [ .[]?
      | select(.type == "required_status_checks")
      | (.parameters.strict_required_status_checks_policy // false)
    ] | any' 2>/dev/null || echo false)"
  echo "$r"
}

# summarize_base_merges <prs_json> <strict_policy> [request_label]
# Emits TSV: required<TAB>skippable — over the open non-draft, non-Dependabot,
# mergeStateStatus==BEHIND PRs, the count whose base merge is genuinely REQUIRED vs
# a no-op that should be SKIPPED (#1881 AC #4). A BEHIND PR's base merge is required
# when being behind actually blocks it — ANY of:
#   * strict is on for THAT PR's base branch (ruleset requires up-to-date branches), OR
#   * the PR is enqueued in the merge queue (mergeQueueEntry non-null — actual
#     merge-queue membership, not auto-merge arming, which does not force an
#     up-to-date branch), OR
#   * the PR carries the explicit request label (default AUTO_REBASE_REQUEST_LABEL).
# Otherwise the base merge is skippable churn. DIRTY PRs are deliberately NOT counted:
# they take the conflict/rebase path unchanged (AC #3). Absent/empty JSON → "0\t0".
#
# <strict_policy> is either a scalar "true"/"false" applied to every base branch, OR
# a JSON object mapping baseRefName → boolean so each PR is classified against its OWN
# base's ruleset (#1887): a release branch with a different strict policy no longer
# borrows the default branch's flag. A base absent from the map defaults to false.
summarize_base_merges() {
  local json="${1:-}" strict="${2:-false}" label="${3:-$AUTO_REBASE_REQUEST_LABEL}"
  [ -n "$json" ] || json='[]'
  jq -r --arg strict "$strict" --arg label "$label" '
    ($strict | (fromjson? // false)) as $sp |
    [ .[]
      | select((.isDraft // false) | not)
      | select(((.author?.login // "" | tostring) | test("dependabot"; "i")) | not)
      | select(.mergeStateStatus == "BEHIND")
    ] | map(
      (if ($sp | type) == "object" then ($sp[(.baseRefName // "")] // false) else $sp end)
      or (.mergeQueueEntry != null)
      or ([ (.labels // [])[] | (.name // "") ] | index($label) != null)
    ) as $flags |
    [
      ([ $flags[] | select(.) ]       | length),
      ([ $flags[] | select(. | not) ] | length)
    ] | @tsv' <<< "$json" 2>/dev/null || printf '0\t0'
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

# render_report <comments_json> <runs_json> <lookback_days> <behind_prs> [today] [prs_json] [pr_list_truncated] [pr_list_limit] [strict_enabled] [request_label] [strict_policy]
# Writes the full Markdown report to stdout. Pure: no network.
# pr_list_truncated=true renders a warning that BEHIND/DIRTY counts may undercount.
# strict_enabled ("true"/"false") is the DEFAULT branch's config-derived
# up-to-date-branches policy — shown as the report headline.
# strict_policy is what actually drives the base-merge-necessity counter (#1881):
# either the same scalar, or a JSON object mapping baseRefName → boolean so each PR
# is classified against its own base's ruleset (#1887). Defaults to strict_enabled.
render_report() {
  local comments_json="${1:-[]}" runs_json="${2:-[]}"
  local lookback="${3:-7}" behind="${4:-0}" today="${5:-}" prs_json="${6:-[]}"
  local pr_list_truncated="${7:-false}" pr_list_limit="${8:-1000}"
  local strict_enabled="${9:-false}" request_label="${10:-$AUTO_REBASE_REQUEST_LABEL}"
  local strict_policy="${11:-$strict_enabled}"
  [ -n "$today" ] || today="$(date -u +%Y-%m-%d)"

  local sentinels responses applied
  IFS=$'\t' read -r sentinels responses applied < <(summarize_sentinels "$comments_json")

  local total success failed
  IFS=$'\t' read -r total success failed < <(summarize_runs "$runs_json")

  local ms_behind ms_dirty
  IFS=$'\t' read -r ms_behind ms_dirty < <(summarize_merge_states "$prs_json")

  local bm_required bm_skippable
  IFS=$'\t' read -r bm_required bm_skippable < <(summarize_base_merges "$prs_json" "$strict_policy" "$request_label")

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
  printf 'so re-runs = runs × current open non-Dependabot PR count.\n\n'

  printf '## Fleet merge-state observability (AC7)\n\n'
  printf -- '- **BEHIND** (open non-draft non-Dependabot PRs `mergeStateStatus: BEHIND`): %s\n' "$ms_behind"
  printf -- '- **DIRTY** (open non-draft non-Dependabot PRs `mergeStateStatus: DIRTY`): %s\n\n' "$ms_dirty"
  if [ "$pr_list_truncated" = "true" ]; then
    printf '> ⚠ **PR list capped at %s** — BEHIND/DIRTY counts cover only the first %s open PRs ' \
      "$pr_list_limit" "$pr_list_limit"
    printf 'and may undercount the true backlog. Set `PR_LIST_LIMIT` to raise the cap.\n\n'
  fi
  printf '> Snapshot of the current open-PR queue, scoped to **`%s`** — fleet-wide counts would '  "$WORKFLOW_REPO"
  printf 'require a cross-repo PAT this report does not carry. Tracks the effectiveness of the '
  printf 'AC1/AC2 auto-rebase fixes (petry-projects/.github#926) without a manual audit.\n\n'

  printf '## Base-merge necessity (#1881)\n\n'
  printf -- '- **Up-to-date-branches policy** (ruleset `strict_required_status_checks_policy`): `%s`\n' "$strict_enabled"
  printf -- '- **Base merges required** (behind actually blocks: strict on, enqueued in merge queue, or `%s` label): %s\n' \
    "$request_label" "$bm_required"
  printf -- '- **Base merges skippable** (BEHIND with no such requirement — a no-op churn): %s\n' "$bm_skippable"
  printf -- '- `base_merges_required=%s base_merges_skippable=%s`\n\n' "$bm_required" "$bm_skippable"
  printf '> Deterministic counter over open non-draft non-Dependabot **BEHIND** PRs (DIRTY PRs keep the '
  printf 'conflict/rebase path, so they are excluded). `skippable` is the no-op base-merge volume #1881 '
  printf 'removes at the source; it is the second input to #1864 AC #4 alongside #1865 `reviews_carried_forward`. '
  printf 'The policy flag is read from repository configuration — if `strict` is re-armed, every BEHIND PR '
  printf 'becomes `required` with no code change.\n'
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

  # 3. Open-PR snapshot — pulled once with the fields the behind-PR multiplier, the
  #    AC7 merge-state (BEHIND/DIRTY) metric, and the #1881 base-merge-necessity
  #    counter (labels + mergeQueueEntry + baseRefName) all need. Fetched over GraphQL
  #    rather than `gh pr list --json` because `mergeQueueEntry` — actual merge-queue
  #    membership, the queue-specific signal #1881 wants (not `autoMergeRequest`, which
  #    only means auto-merge is armed) — is not a documented `gh pr list` field. The
  #    node set is reshaped to the same object shape the pure helpers consume. Best
  #    effort; defaults to [] so the report still renders when the query fails.
  local owner="${WORKFLOW_REPO%%/*}" name="${WORKFLOW_REPO##*/}"
  local prs_json pr_list_truncated pr_count
  # shellcheck disable=SC2016 # $owner/$name/$endCursor are GraphQL vars, not shell vars
  prs_json="$(gh api graphql --paginate \
    -f owner="$owner" -f name="$name" \
    -f query='query($owner:String!, $name:String!, $endCursor:String) {
      repository(owner:$owner, name:$name) {
        pullRequests(states: OPEN, first: 100, after: $endCursor) {
          nodes {
            number isDraft mergeStateStatus baseRefName
            author { login }
            labels(first: 100) { nodes { name } }
            mergeQueueEntry { id }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }' --jq '.data.repository.pullRequests.nodes[]' 2>/dev/null \
    | jq -s 'map({number, isDraft, mergeStateStatus, baseRefName, author, labels: (.labels.nodes // []), mergeQueueEntry})' 2>/dev/null || echo '[]')"
  [ -n "$prs_json" ] || prs_json='[]'
  pr_count="$(printf '%s' "$prs_json" | jq 'length' 2>/dev/null || echo 0)"
  if [ "$pr_count" -ge "$PR_LIST_LIMIT" ]; then
    pr_list_truncated=true
    prs_json="$(jq -c --argjson lim "$PR_LIST_LIMIT" '.[:$lim]' <<< "$prs_json" 2>/dev/null || printf '%s' "$prs_json")"
  else
    pr_list_truncated=false
  fi

  # Behind-PR multiplier — open non-Dependabot PRs (proxy for branches the
  # fan-out updates), derived from the same snapshot.
  local behind
  behind="$(printf '%s' "$prs_json" \
    | jq '[.[] | select((.author?.login // "") | test("dependabot"; "i") | not)] | length' \
    2>/dev/null || echo 0)"

  # 4. Up-to-date-branches policy — read from the default branch's ruleset so the
  #    base-merge-necessity counter (#1881) is derived from config, not hardcoded.
  #    Best-effort: if the ruleset cannot be read the report degrades to strict=false
  #    with a warning (so a silent read failure cannot masquerade as "no requirement"),
  #    matching the token-degradation posture above.
  #
  #    Resolve the branch first: when DEFAULT_BRANCH is not pinned via env, query the
  #    repo's ACTUAL default branch so an AGENT_REPO whose default is not `main` reads
  #    its rules from the right branch (#1887). Fall back to `main` if the lookup fails.
  local default_branch="${DEFAULT_BRANCH:-}"
  if [ -z "$default_branch" ]; then
    default_branch="$(gh api "repos/${WORKFLOW_REPO}" --jq '.default_branch' 2>/dev/null || echo main)"
    [ -n "$default_branch" ] || default_branch=main
  fi

  # Capture the command-substitution exit status into a variable first (rather than
  # running it directly inside `if`) so a failure is not swallowed under `set -e`.
  local rules_json strict_enabled api_status=0
  rules_json="$(gh api "repos/${WORKFLOW_REPO}/rules/branches/${default_branch}" 2>/dev/null)" || api_status=$?
  if [ "$api_status" -eq 0 ]; then
    [ -n "$rules_json" ] || rules_json='[]'
  else
    rules_json='[]'
    echo "::warning::Could not read branch rules for ${WORKFLOW_REPO}@${default_branch} — base-merge necessity assumes strict=false; skippable counts may be overstated." >&2
  fi
  strict_enabled="$(strict_from_branch_rules "$rules_json")"

  # Resolve the up-to-date policy PER base branch, not just the default (#1887). The
  # open-PR snapshot has no default-branch filter and the auto-rebase workflow updates
  # every behind PR, so a PR based on a release branch with a different strict policy
  # would otherwise be classified against `main`'s ruleset. Build a baseRefName→bool
  # map covering the distinct bases of the eligible (non-draft, non-Dependabot, BEHIND)
  # PRs and hand it to the counter. Seed it with the already-resolved default branch so
  # that base is not re-fetched.
  local strict_policy
  strict_policy="$(jq -cn --arg k "$default_branch" --argjson v "$strict_enabled" '{($k): $v}')"
  local base_branches base
  base_branches="$(printf '%s' "$prs_json" | jq -r '
    [ .[]
      | select((.isDraft // false) | not)
      | select(((.author?.login // "" | tostring) | test("dependabot"; "i")) | not)
      | select(.mergeStateStatus == "BEHIND")
      | .baseRefName // empty
    ] | unique[]' 2>/dev/null || true)"
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    [ "$base" = "$default_branch" ] && continue
    local b_rules b_status=0 b_strict
    b_rules="$(gh api "repos/${WORKFLOW_REPO}/rules/branches/${base}" 2>/dev/null)" || b_status=$?
    if [ "$b_status" -eq 0 ]; then
      [ -n "$b_rules" ] || b_rules='[]'
    else
      b_rules='[]'
      echo "::warning::Could not read branch rules for ${WORKFLOW_REPO}@${base} — base-merge necessity assumes strict=false for PRs targeting it; skippable counts may be overstated." >&2
    fi
    b_strict="$(strict_from_branch_rules "$b_rules")"
    strict_policy="$(jq -c --arg k "$base" --argjson v "$b_strict" '. + {($k): $v}' <<< "$strict_policy")"
  done <<< "$base_branches"

  local report
  report="$(render_report "$comments_json" "$runs_json" "$LOOKBACK_DAYS" "$behind" "$today" "$prs_json" "$pr_list_truncated" "$PR_LIST_LIMIT" "$strict_enabled" "$AUTO_REBASE_REQUEST_LABEL" "$strict_policy")"

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
