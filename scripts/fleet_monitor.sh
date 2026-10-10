#!/usr/bin/env bash
# Org-wide Actions Fleet Monitor.
#
# Dynamically discovers all non-archived repos in an org, all active
# workflows per repo, and fetches run telemetry for each over the lookback
# window. Writes a fleet summary to GITHUB_STEP_SUMMARY and
# fleet_monitor_report.md. Sets HAS_FAILURES=true in GITHUB_ENV when any
# workflow has failed runs.
#
# Env vars consumed:
#   GH_TOKEN        — PAT with actions:read across the org, consumed by gh CLI;
#                     intentionally a PAT (not GITHUB_TOKEN) because the default
#                     Actions token lacks cross-org actions:read
#   GH_PAT_FALLBACK — optional secondary token if primary lacks org-level access
#   ORG             — GitHub org to scan (default: petry-projects)
#   LOOKBACK_DAYS   — days of history to consider (default: 1)
#   BUDGET_POLLER_REPO        — repo whose budget-poller-log artifact is read
#                               (default: petry-projects/.github-private, #2029)
#   BUDGET_POLLER_STALE_HOURS — warn when the last OK poll is older (default: 6)
#   GITHUB_ENV      — written by Actions runner
#   GITHUB_STEP_SUMMARY — written by Actions runner (1 MB hard limit per job)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/fleet_report.sh
source "${SCRIPT_DIR}/fleet_report.sh"
# shellcheck source=scripts/fleet_stub_drift.sh
source "${SCRIPT_DIR}/fleet_stub_drift.sh"
# shellcheck source=scripts/lib/run-attribution.sh
source "${SCRIPT_DIR}/lib/run-attribution.sh"
# shellcheck source=scripts/lib/budget-poller.sh
source "${SCRIPT_DIR}/lib/budget-poller.sh"

ORG="${ORG:-petry-projects}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-1}"
REPORT_FILE="fleet_monitor_report.md"
TODAY=$(date -u +%Y-%m-%d)

# Per-repo thin-caller stub coverage & drift (#822 planner, #886 driver, #1726
# per-job). Each stub is deployed verbatim from a canonical org template; we
# compare blob SHAs. The registry generalizes the original single-stub path (#822)
# so the same pure helpers run per stub kind. Each entry is TAB-separated:
#   name <TAB> label <TAB> stub_path <TAB> canonical_path <TAB> role <TAB> legacy_path <TAB> legacy_canonical_path
#     name            — slug used in log lines
#     label           — section heading / alert grouping ("Initiative-planner")
#     stub_path       — per-repo thin-caller path under each enrolled repo
#     canonical_path  — org-template path under $CANONICAL_STUB_REPO
#     role            — OPTIONAL job/role selector (#1726). Empty ⇒ whole-file blob
#                       SHA comparison (the #822/#886 behavior, kept for stubs that
#                       are NOT collapsing — initiative-planner/driver are separate
#                       per-repo files, not agent-ingress.yml jobs). Non-empty ⇒
#                       stub_path is the collapsed agent-ingress.yml and the
#                       comparison unit is the EXTRACTED `<role>` job block, so a
#                       per-role Class-1 stub that has collapsed into an
#                       agent-ingress.yml job is understood rather than read as
#                       MISSING once its standalone file 404s.
#     legacy_path     — OPTIONAL per-role stub path for a mixed-fleet repo that has
#                       NOT yet collapsed (no agent-ingress.yml). Only consulted when
#                       role is set AND the repo carries no agent-ingress.yml; a
#                       collapsed repo IGNORES it so a deleted per-role stub is never
#                       resurrected (AC #4). Whole-file compared against ...
#     legacy_canonical_path — ... this org-template per-role canonical path.
CANONICAL_STUB_REPO="${CANONICAL_STUB_REPO:-petry-projects/.github}"
STUB_REGISTRY=(
  $'initiative-planner\tInitiative-planner\t.github/workflows/initiative-planner.yml\tstandards/workflows/initiative-planner.yml\t\t\t'
  $'initiative-driver\tInitiative-driver\t.github/workflows/initiative-driver.yml\tstandards/workflows/initiative-driver.yml\t\t\t'
  # Collapsed agent-ingress.yml roles (#1729 AC11): one row per job in the
  # petry-projects/markets ingress. These entries register for future drift
  # coverage once the canonical standards/workflows/agent-ingress.yml is
  # published to petry-projects/.github (#1729 AC11). Until then, a canonical
  # 404 gracefully skips these rows with a warning, leaving them without
  # coverage. The monitor and remediation helpers handle this degradation
  # automatically (see the @test "fleet_monitor: a 404 canonical
  # agent-ingress skips every role row with a warning and stays green" in
  # tests/fleet_stub_registry.bats).
  # legacy_canonical_path is empty for pr-review and ci-failure-analyst because
  # petry-projects/.github publishes no standards/workflows/<role>.yml for them
  # (checked 2026-10-10), so a repo that has not collapsed classifies MISSING
  # for those two roles.
  $'dev-lead\tDev-lead\t.github/workflows/agent-ingress.yml\tstandards/workflows/agent-ingress.yml\tdev-lead\t.github/workflows/dev-lead.yml\tstandards/workflows/dev-lead.yml'
  $'pr-auto-review\tPr-auto-review\t.github/workflows/agent-ingress.yml\tstandards/workflows/agent-ingress.yml\tpr-auto-review\t.github/workflows/pr-auto-review.yml\tstandards/workflows/pr-auto-review.yml'
  $'pr-review\tPr-review\t.github/workflows/agent-ingress.yml\tstandards/workflows/agent-ingress.yml\tpr-review\t.github/workflows/pr-review.yml\t'
  $'pr-review-mention\tPr-review-mention\t.github/workflows/agent-ingress.yml\tstandards/workflows/agent-ingress.yml\tpr-review-mention\t.github/workflows/pr-review-mention.yml\tstandards/workflows/pr-review-mention.yml'
  $'ci-failure-analyst\tCi-failure-analyst\t.github/workflows/agent-ingress.yml\tstandards/workflows/agent-ingress.yml\tci-failure-analyst\t.github/workflows/ci-failure-analyst.yml\t'
)

# fetch_raw_content <repo> <path> — emit a file's raw contents on stdout. Returns
# 0 on success, 2 when the file is genuinely absent (HTTP 404), and 1 on ANY other
# failure (auth, rate-limit, network) after logging the API error to stderr.
# Callers MUST treat a 1 as fatal: a masked read failure must never be misread as
# "file absent" and silently skip drift detection or fall back to the legacy path
# (review on #1726). HTTP 404 is the ONE tolerated non-success — the canonical
# template not yet merged (#886 AC#5) or a consumer repo carrying no
# agent-ingress.yml (legacy fallback).
fetch_raw_content() {
  local repo="$1" path="$2" errf rc
  errf="$(mktemp)"
  if gh api -H "Accept: application/vnd.github.raw" \
      "repos/${repo}/contents/${path}" 2>"$errf"; then
    rm -f "$errf"
    return 0
  fi
  rc=$?
  if grep -q 'HTTP 404' "$errf"; then
    rm -f "$errf"
    return 2
  fi
  echo "::error::GitHub API read failed for ${repo}/${path} (exit ${rc}):" >&2
  cat "$errf" >&2
  rm -f "$errf"
  return 1
}

echo "=== Actions Fleet Monitor ==="
echo "  Org:      $ORG"
echo "  Lookback: ${LOOKBACK_DAYS} day(s)"
echo "  Date:     $TODAY"
echo ""

# ---------------------------------------------------------------------------
# 0. Token check — fall back to GH_PAT_FALLBACK if org is not reachable
# ---------------------------------------------------------------------------
if ! gh api "orgs/${ORG}" >/dev/null 2>&1; then
  if [ -n "${GH_PAT_FALLBACK:-}" ]; then
    echo "::warning::GH_TOKEN cannot access org ${ORG} — using GH_PAT_FALLBACK"
    export GH_TOKEN="$GH_PAT_FALLBACK"
    if ! gh api "orgs/${ORG}" >/dev/null 2>&1; then
      echo "::error::GH_PAT_FALLBACK also cannot access org ${ORG}."
      exit 1
    fi
  else
    echo "::error::GH_TOKEN cannot access org ${ORG} and GH_PAT_FALLBACK is not set."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Discover repos
# ---------------------------------------------------------------------------
CUTOFF=$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)

# Window epochs for schedule-reliability expected-tick expansion (#725). The
# same [CUTOFF, now) window used for the run query is passed to the pure cron
# tick counter in fleet_report.sh so expected ticks align with observed runs.
WINDOW_START_EPOCH=$(date -u -d "$CUTOFF" +%s 2>/dev/null \
  || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$CUTOFF" +%s)
WINDOW_END_EPOCH=$(date -u +%s)

echo "Discovering repos in ${ORG}..."
repos_raw=$(gh api "orgs/${ORG}/repos?per_page=100&type=all" --paginate \
  --jq '.[] | select(.archived == false) | .full_name' 2>/dev/null || true)

if [ -z "$repos_raw" ]; then
  echo "::error::No repos returned — check token has read:org and repo access."
  exit 1
fi

mapfile -t repos < <(echo "$repos_raw" | sort)
repo_count="${#repos[@]}"
echo "Found ${repo_count} non-archived repos — window: since ${CUTOFF}"
echo ""

# ---------------------------------------------------------------------------
# 2. Collect metrics per repo → per workflow
# ---------------------------------------------------------------------------
metrics_file=$(mktemp)
failed_file=$(mktemp)
# Parallel schedule-reliability metrics (#725) — kept separate from the 12-field
# metrics TSV so the existing high-failure JSON export contract is untouched.
# TSV: repo <TAB> wf_file <TAB> expected <TAB> actual <TAB> hit_rate <TAB> missed <TAB> label
schedule_metrics_file=$(mktemp)
any_failures=0
total_workflows=0

for repo in "${repos[@]}"; do
  printf '  %s\n' "$repo"

  if ! workflows_raw=$(gh api "repos/${repo}/actions/workflows?per_page=100" --paginate \
    --jq '[.workflows[] | select(.state == "active") | {id: (.id | tostring), file: .path}]' \
    2>/dev/null); then
    echo "::warning::Cannot read workflows for ${repo} — check token has actions:read"
    continue
  fi
  workflows=$(echo "$workflows_raw" | jq -s 'add // []')

  wf_count=$(echo "$workflows" | jq 'length')
  [ "$wf_count" -eq 0 ] && continue
  total_workflows=$(( total_workflows + wf_count ))

  while IFS=$'\t' read -r wf_id wf_file; do
    # Note: GitHub caps created>= queries at 1,000 results even with --paginate.
    # At >1,000 runs/window (>143/day) older runs are silently omitted.
    if ! runs_raw=$(gh api \
      "repos/${repo}/actions/workflows/${wf_id}/runs?per_page=100&created=>=${CUTOFF}" \
      --paginate \
      --jq '.workflow_runs | map({
        run_number: .run_number,
        conclusion: .conclusion,
        event: .event,
        created_at: .created_at,
        html_url: .html_url,
        duration_s: ((.updated_at | fromdate) - (.created_at | fromdate) | floor)
      })' 2>/dev/null); then
      echo "::warning::Cannot read runs for ${repo}/${wf_file} — recording as ERROR"
      # Record an ERROR sentinel so the report shows this workflow as unresolvable
      # rather than silently omitting it (which could produce a falsely clean result).
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "6" "$repo" "$wf_file" "?" "" "" "" "error" "0" "0" "ERROR" "0" \
        >> "$metrics_file"
      any_failures=1  # ERROR rows represent monitor failures that need attention
      continue
    fi
    # Exclude queued/in_progress runs — only completed conclusions give valid metrics.
    runs_json=$(echo "$runs_raw" | jq -s 'add // [] | [.[] | select(.conclusion != null)]')

    # Accumulate legacy (non-ingress) runs normalized to {role,conclusion} for
    # parity combining with post-collapse ingress runs (#1727 AC #4).
    if ! attribution_is_ingress "$wf_file"; then
      printf '%s' "$runs_json" | normalize_legacy_runs "$wf_file" | jq -c '.[]' >> "$legacy_attr_file"
    fi

    total=$(echo "$runs_json" | jq 'length')
    failed=$(echo "$runs_json" | jq '[.[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required")] | length')
    success=$(echo "$runs_json" | jq '[.[] | select(.conclusion == "success")] | length')
    cancelled=$(echo "$runs_json" | jq '[.[] | select(.conclusion == "cancelled")] | length')

    if [ "$total" -gt 0 ]; then
      rate_int=$(( failed * 100 / total ))
      rate_display=$(awk -v f="$failed" -v t="$total" \
        'BEGIN { pct = f * 100 / t; printf (pct == int(pct)) ? "%d%%" : "%.1f%%", pct }')
      # Use exact float comparison so 1/200 = 0.5% correctly classifies as WARNING,
      # not HEALTHY (which integer truncation would produce).
      read -r label sort_key < <(awk -v f="$failed" -v t="$total" 'BEGIN {
        pct = f * 100 / t
        if (f == 0)    { print "HEALTHY 3" }
        else if (pct > 50) { print "CRITICAL 0" }
        else if (pct > 20) { print "DEGRADED 1" }
        else               { print "WARNING 2"  }
      }')
    else
      rate_int=0
      rate_display="n/a"
      label="—"
      sort_key=4
    fi

    read -r p50 p95 < <(echo "$runs_json" | jq -r '
      [.[] | select(.conclusion != null and .duration_s > 0) | .duration_s] | sort |
      if length == 0 then "0 0"
      else . as $d | ($d | length) as $n |
        "\($d[$n * 50 / 100 | floor]) \($d[$n * 95 / 100 | floor])"
      end')

    # 12 fields: sort_key repo wf_file total success failed cancelled
    #            rate_display p50 p95 label rate_int
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$sort_key" "$repo" "$wf_file" \
      "$total" "$success" "$failed" "$cancelled" \
      "$rate_display" "$p50" "$p95" "$label" "$rate_int" \
      >> "$metrics_file"

    if [ "$failed" -gt 0 ]; then
      any_failures=1
      {
        printf '\n### `%s` / `%s`\n\n' "$repo" "$wf_file"
        printf '| Run | Date | Duration | Link |\n|---|---|---|---|\n'
        while IFS=$'\t' read -r run_num created_at dur_s url; do
          printf '| #%s | %s | %s | [view](%s) |\n' \
            "$run_num" "${created_at%%T*}" "$(fmt_dur "$dur_s")" "$url"
        done < <(echo "$runs_json" | jq -r '
          [.[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required")] | sort_by(.run_number) | reverse[] |
          [(.run_number | tostring), .created_at, (.duration_s | tostring), .html_url] | @tsv')
      } >> "$failed_file"
    fi

    # --- Schedule reliability (#725) ---------------------------------------
    # The actions/workflows API does not expose cron, so fetch the workflow file
    # content and parse schedule.cron from it. A read/parse failure is non-fatal
    # (warn + skip) — consistent with the ERROR-sentinel tolerance elsewhere.
    # Only workflows with a schedule trigger (expected > 0) get a row, so a cron
    # that silently never fired (actual 0, expected N) surfaces as STALLED even
    # though it produced no runs to otherwise flag.
    wf_content=$(gh api -H "Accept: application/vnd.github.raw" \
      "repos/${repo}/contents/${wf_file}" 2>/dev/null || true)
    if [ -n "$wf_content" ]; then
      expected_ticks=$(printf '%s' "$wf_content" \
        | workflow_expected_ticks "$WINDOW_START_EPOCH" "$WINDOW_END_EPOCH")
    else
      expected_ticks=0
      echo "::warning::Cannot read workflow file ${repo}/${wf_file} for cron parse — schedule reliability skipped for this workflow"
    fi
    case "${expected_ticks:-0}" in ''|*[!0-9]*) expected_ticks=0 ;; esac
    if [ "$expected_ticks" -gt 0 ]; then
      # Count schedule-triggered runs from the raw set (incl. in-progress) so a
      # tick that fired but is still running is not miscounted as a miss.
      sched_actual=$(echo "$runs_raw" \
        | jq -s 'add // [] | [.[] | select(.event == "schedule")] | length')
      IFS=$'\t' read -r sched_label sched_hr sched_missed \
        < <(classify_schedule_reliability "$expected_ticks" "$sched_actual")
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$repo" "$wf_file" "$expected_ticks" "$sched_actual" \
        "$sched_hr" "$sched_missed" "$sched_label" \
        >> "$schedule_metrics_file"
    fi
  done < <(echo "$workflows" | jq -r '.[] | [.id, .file] | @tsv')
done

# ---------------------------------------------------------------------------
# 2a. Per-repo stub coverage & drift (#822 planner, #886 driver — AC#2 + AC#3)
# For each registered stub, and each discovered repo, compare the repo's per-repo
# stub blob SHA against the canonical org-template SHA. Reuses the repo list
# already discovered above (extends the Fleet Monitor rather than building a
# parallel monitor, per #627). The contents API `.sha` is the git blob object
# ID, so equal SHAs => identical files.
#
# Parallel arrays accumulate per-processed-stub state for the report (3.) and
# alert export (3c.): a stub whose canonical SHA cannot be read is skipped with
# a per-stub `::warning::` (non-fatal) so a not-yet-merged template degrades
# gracefully (#886 AC#5) rather than failing the whole run.
# ---------------------------------------------------------------------------
stub_drift_files=()
stub_drift_labels=()
stub_drift_paths=()
stub_drift_canon=()
stub_drift_roles=()

for entry in "${STUB_REGISTRY[@]}"; do
  IFS=$'\t' read -r stub_name stub_label stub_path canonical_path \
    role legacy_path legacy_canonical_path <<< "$entry"

  if [ -z "$role" ]; then
    # ── Whole-file path (#822 planner, #886 driver) ──────────────────────────
    # role empty ⇒ stub_path is a standalone per-repo file compared byte-for-byte
    # against its canonical template. Unchanged from the pre-#1726 behavior.
    canonical_stub_sha=$(gh api \
      "repos/${CANONICAL_STUB_REPO}/contents/${canonical_path}" \
      --jq '.sha' 2>/dev/null || true)

    if [ -z "$canonical_stub_sha" ]; then
      echo "::warning::Could not read canonical stub SHA (${CANONICAL_STUB_REPO}/${canonical_path}) — skipping ${stub_name} stub drift detection."
      continue
    fi

    echo "Canonical ${stub_name} stub SHA: ${canonical_stub_sha} (${CANONICAL_STUB_REPO}/${canonical_path})"
    stub_drift_file=$(mktemp)
    for repo in "${repos[@]}"; do
      # 404 (no stub) => empty SHA => MISSING (not enrolled); non-fatal.
      repo_stub_sha=$(gh api "repos/${repo}/contents/${stub_path}" \
        --jq '.sha' 2>/dev/null || true)
      stub_drift_row "$repo" "$canonical_stub_sha" "$repo_stub_sha" >> "$stub_drift_file"
    done

    stub_drift_files+=("$stub_drift_file")
    stub_drift_labels+=("$stub_label")
    stub_drift_paths+=("$stub_path")
    stub_drift_canon+=("$canonical_stub_sha")
    stub_drift_roles+=("")
    continue
  fi

  # ── Per-job (role-selector) path (#1726) ───────────────────────────────────
  # role set ⇒ stub_path is the collapsed agent-ingress.yml and the comparison
  # unit is the extracted `<role>` job BLOCK. We fetch canonical CONTENT (not just
  # `.sha`) to hash the block, and for each repo detect whether an agent-ingress.yml
  # is present: present ⇒ compare block SHAs (absent block ⇒ MISSING, never
  # resurrected from a legacy file); absent ⇒ fall back to the legacy per-role
  # whole-file SHAs so a not-yet-collapsed repo is still classified (AC #4).
  canonical_ingress="$(fetch_raw_content "$CANONICAL_STUB_REPO" "$canonical_path")" && canon_rc=0 || canon_rc=$?
  case "$canon_rc" in
    0) ;;
    2) echo "::warning::Canonical agent-ingress not found (${CANONICAL_STUB_REPO}/${canonical_path}) — skipping ${stub_name} (${role}) stub drift detection."
       continue ;;
    *) echo "::error::Aborting: cannot read canonical agent-ingress (${CANONICAL_STUB_REPO}/${canonical_path}) — API failure must not be masked as absent (see error above)." >&2
       exit 1 ;;
  esac
  if [ -z "$canonical_ingress" ]; then
    echo "::warning::Canonical agent-ingress is empty (${CANONICAL_STUB_REPO}/${canonical_path}) — skipping ${stub_name} (${role}) stub drift detection."
    continue
  fi
  canon_block_sha=$(printf '%s' "$canonical_ingress" | job_block_sha "$role")
  if [ -z "$canon_block_sha" ]; then
    echo "::warning::Canonical agent-ingress has no '${role}' job block — skipping ${stub_name} (${role}) stub drift detection."
    continue
  fi

  # Legacy per-role canonical whole-file SHA (for mixed-fleet, pre-collapse repos).
  # Optional: absence only means legacy repos for this role cannot be classified.
  legacy_canon_sha=""
  if [ -n "$legacy_canonical_path" ]; then
    legacy_canon_sha=$(gh api \
      "repos/${CANONICAL_STUB_REPO}/contents/${legacy_canonical_path}" \
      --jq '.sha' 2>/dev/null || true)
  fi

  echo "Canonical ${stub_name} (${role}) block SHA: ${canon_block_sha} (${CANONICAL_STUB_REPO}/${canonical_path}#${role})"
  stub_drift_file=$(mktemp)
  for repo in "${repos[@]}"; do
    repo_ingress="$(fetch_raw_content "$repo" "$stub_path")" && ingress_rc=0 || ingress_rc=$?
    # A hard failure (rc 1) must abort — treating it as "absent" would wrongly
    # trigger the legacy fallback for a repo that actually has an agent-ingress.yml.
    if [ "$ingress_rc" -eq 1 ]; then
      echo "::error::Aborting: cannot read ${repo}/${stub_path} — API failure must not be masked as a missing ingress (see error above)." >&2
      exit 1
    fi
    if [ "$ingress_rc" -eq 0 ] && [ -n "$repo_ingress" ]; then
      ingress_present="yes"
      repo_block_sha=$(printf '%s' "$repo_ingress" | job_block_sha "$role")
      legacy_repo_sha=""
    else
      # True 404 (rc 2) or present-but-empty — no usable agent-ingress.yml, so
      # consult the legacy per-role stub (if any).
      ingress_present="no"
      repo_block_sha=""
      legacy_repo_sha=""
      if [ -n "$legacy_path" ]; then
        legacy_repo_sha=$(gh api "repos/${repo}/contents/${legacy_path}" \
          --jq '.sha' 2>/dev/null || true)
      fi
    fi
    stub_drift_row_role "$repo" "$ingress_present" "$canon_block_sha" \
      "$repo_block_sha" "$legacy_canon_sha" "$legacy_repo_sha" >> "$stub_drift_file"
  done

  stub_drift_files+=("$stub_drift_file")
  stub_drift_labels+=("$stub_label")
  stub_drift_paths+=("$stub_path")
  stub_drift_canon+=("$canon_block_sha")
  stub_drift_roles+=("$role")
done

# ---------------------------------------------------------------------------
# 2b. Build issue lookup for open fleet-tracker issues (linked inline in report)
# Issues now live in their target repo, so search org-wide.
# Note: the Search API caps at 1,000 results total; if the org has >1,000 open
# fleet-tracker issues the lookup may be incomplete, but that is not expected in
# practice. On search failure (auth error, rate-limit, etc.) inline links will
# simply be absent from the report — non-fatal for the monitoring workflow.
# ---------------------------------------------------------------------------
issues_lookup_file=$(mktemp)
if ! gh api "search/issues?q=org:${ORG}+label:fleet-tracker+is:open+is:issue&per_page=100" \
  --paginate \
  --jq '.items[] | select(.title | startswith("[Fleet Monitor] ")) |
    (.title | ltrimstr("[Fleet Monitor] ") | split(" — ")) as $p |
    select(($p | length) == 2) |
    [$p[0], $p[1], .html_url, (.number | tostring)] | @tsv' \
  > "$issues_lookup_file" 2>&1; then
  echo "::warning::Could not fetch fleet-tracker issues org-wide — inline issue links may be incomplete. Check token auth/rate-limit."
  : > "$issues_lookup_file"  # ensure file exists but is empty on failure
fi

# ---------------------------------------------------------------------------
# 2c. Dev-Lead timeout observability (#1019, story C of #901)
# Count dev-lead status markers by failure reason over the window, per repo, so a
# rising timeout ("wall") rate is visible distinctly from generic engine-error.
# Markers are HTML comments (`<!-- dev-lead-issue ... reason=timeout ... -->`,
# Story B / #1018) that GitHub search cannot index, so — like auto_rebase_health.sh
# — we pull each repo's issue comments server-side filtered by `since=`. Only
# repos with >=1 marker in the window get a row; the section is omitted entirely
# when the fleet had no dev-lead activity. Best-effort: a comment-read failure on
# one repo is a per-repo warning, not a fatal error for the monitor.
#
# The timeout rate is reported as prevalence (timeout / total dev-lead runs, #1030),
# so each row also carries the repo's total `dev-lead.yml` runs in the window —
# read from the per-workflow metrics already collected above (matched by repo +
# workflow basename), not a new API scan. A missing row or non-numeric total (the
# ERROR sentinel `?`) sanitizes to 0, which the report renders as `n/a`.
# ---------------------------------------------------------------------------
dev_lead_reason_file=$(mktemp)
for repo in "${repos[@]}"; do
  if ! comments_raw=$(gh api \
    "repos/${repo}/issues/comments?since=${CUTOFF}&per_page=100" --paginate \
    --jq '.[] | {body}' 2>/dev/null); then
    echo "::warning::Cannot read issue comments for ${repo} — dev-lead timeout counts may undercount"
    continue
  fi
  comments_json=$(printf '%s' "$comments_raw" | jq -s '.' 2>/dev/null || echo '[]')
  IFS=$'\t' read -r dl_timeout dl_engine_error dl_total \
    < <(summarize_dev_lead_timeouts "$comments_json")
  if [ "${dl_total:-0}" -gt 0 ]; then
    # Total dev-lead runs = the `dev-lead.yml` row's `total` (field 4) for this
    # repo in metrics_file, matched by workflow-file basename. Empty when the
    # repo has no dev-lead.yml row; '?' when that row is an ERROR sentinel.
    dl_runs=$(awk -F'\t' -v r="$repo" '
      $2 == r {
        n = split($3, parts, "/")
        if (parts[n] == "dev-lead.yml") { print $4; exit }
      }' "$metrics_file")
    case "${dl_runs:-}" in
      ''|*[!0-9]*) dl_runs=0 ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$repo" "$dl_timeout" "$dl_engine_error" "$dl_total" "$dl_runs" \
      >> "$dev_lead_reason_file"
  fi
done

# Fleet-wide total dev-lead runs in the window = the sum of every repo's
# `dev-lead.yml` row `total` (field 4) in the per-workflow metrics, across ALL
# repos — including all-success repos with no markers. This is the prevalence
# denominator for the timeout rate (#1030); summing only marker repos would
# inflate the rate. Non-numeric totals (the ERROR sentinel `?`) are skipped.
fleet_dl_runs=$(awk -F'\t' '
  { n = split($3, p, "/"); if (p[n] == "dev-lead.yml" && $4 ~ /^[0-9]+$/) s += $4 }
  END { print s + 0 }
' "$metrics_file")

# ---------------------------------------------------------------------------
# 2d. Persona opt-out label coverage (#1644)
# Every persona advisory tells maintainers to opt out with `<id>:hands-off`, and
# the mention router matches that label by EXACT name — a label that does not
# exist can never match, so a missing opt-out is silently read as "not opted
# out" (fail-open by omission). Surface any repo missing a derived opt-out label
# so the drift is reported here, not discovered by hand. The family is DERIVED
# from personas/*/persona.yml (never enumerated): a new persona is covered
# automatically. Best-effort: a per-repo labels-read failure is a `::warning::`,
# never fatal (mirrors the stub-drift / dev-lead paths). Reuses the already
# discovered repo list rather than building a parallel monitor (#627).
# ---------------------------------------------------------------------------
persona_optout_file=$(mktemp)
persona_optout_family=$(derive_persona_optout_labels "${SCRIPT_DIR}/../personas")
persona_optout_total=$(printf '%s\n' "$persona_optout_family" | sed '/^$/d' | grep -c . || true)
if [ "${persona_optout_total:-0}" -gt 0 ]; then
  for repo in "${repos[@]}"; do
    if ! repo_labels=$(gh api "repos/${repo}/labels?per_page=100" --paginate \
      --jq '.[].name' 2>/dev/null); then
      echo "::warning::Cannot read labels for ${repo} — persona opt-out coverage skipped for this repo"
      continue
    fi
    persona_optout_row "$repo" "$persona_optout_family" "$repo_labels" >> "$persona_optout_file"
  done
else
  echo "::warning::No persona opt-out labels derived from personas/ — coverage check skipped"
fi

# ---------------------------------------------------------------------------
# 2e. Agent Ingress run attribution by role (#1727, ADR-0007, epic #1723)
# The Class-1 caller collapse folds many per-role workflows into ONE
# agent-ingress.yml with one job per role. Section 2 samples runs BY WORKFLOW
# NAME, which would lump every collapsed role into a single "agent-ingress"
# bucket — the ADR-0006-fact-3 attribution regression. Here we RE-sample the
# agent-ingress runs keyed on the role-bearing JOB name (jobs API), so each role
# gets its own bucket that lands in the SAME key as its legacy per-role workflow
# bucket (parity, AC #4). A run whose role cannot be named is bucketed under the
# loud UNATTRIBUTED sentinel, never silently dropped (AC #5). Additive and a
# complete no-op when no repo carries an agent-ingress.yml (current reality — it
# is a reference template, not yet deployed to any live repo), preserving legacy
# per-workflow sampling for not-yet-collapsed roles (AC #3). Best-effort: a
# per-repo API read failure is a `::warning::`, never fatal (mirrors 2a–2d).
# ---------------------------------------------------------------------------
ingress_attr_file=$(mktemp)   # accumulates normalized {role,conclusion} JSONL
legacy_attr_file=$(mktemp)    # accumulates normalized legacy runs for parity
for repo in "${repos[@]}"; do
  # The collapsed ingress workflow id for this repo (basename match), if present.
  if ! ingress_wf_id=$(gh api "repos/${repo}/actions/workflows?per_page=100" --paginate \
    --jq "first(.workflows[] | select((.path | split(\"/\") | last) == \"${INGRESS_WORKFLOW_BASENAME}\") | .id | tostring) // empty" \
    2>/dev/null); then
    echo "::warning::Cannot read workflows for ${repo} — ingress attribution skipped for this repo"
    continue
  fi
  [ -n "$ingress_wf_id" ] || continue   # no agent-ingress.yml here — legacy repo

  # Completed run ids for the ingress workflow over the window (the jobs API keys
  # on run id, so unlike Section 2 we must keep the id, not just run_number).
  if ! ingress_run_ids=$(gh api \
    "repos/${repo}/actions/workflows/${ingress_wf_id}/runs?per_page=100&created=>=${CUTOFF}" \
    --paginate \
    --jq '.workflow_runs[] | select(.conclusion != null) | (.id | tostring)' \
    2>/dev/null); then
    echo "::warning::Cannot read ingress runs for ${repo} — ingress attribution skipped for this repo"
    continue
  fi
  [ -n "$ingress_run_ids" ] || continue

  # Build the per-run jobs JSON the lib expects: [{run_id, jobs:[{name,conclusion}]}].
  per_run_tmp=$(mktemp)
  while IFS= read -r run_id; do
    [ -n "$run_id" ] || continue
    if ! jobs_raw=$(gh api "repos/${repo}/actions/runs/${run_id}/jobs?per_page=100" --paginate \
      --jq '[.jobs[] | {name, conclusion}]' 2>/dev/null); then
      echo "::warning::Cannot read jobs for ${repo} run ${run_id} — ingress attribution may undercount"
      continue
    fi
    jobs_json=$(printf '%s' "$jobs_raw" | jq -s 'add // []')
    jq -n --argjson rid "$run_id" --argjson jobs "$jobs_json" \
      '{run_id: $rid, jobs: $jobs}' >> "$per_run_tmp"
  done <<< "$ingress_run_ids"

  # Normalize per-run jobs → one {role,conclusion} per role (failure precedence,
  # skipped roles dropped, unnamed/empty → UNATTRIBUTED), then append as JSONL to
  # the fleet accumulator. The repo dimension collapses into the fleet-wide
  # per-role bucket, exactly as legacy per-workflow buckets sum across repos.
  jq -s '.' "$per_run_tmp" | normalize_ingress_runs | jq -c '.[]' >> "$ingress_attr_file"
  rm -f "$per_run_tmp"
done

# ---------------------------------------------------------------------------
# 2f. Dry-run budget poller liveness (#2029, slice 2 of #1565)
# Read the newest `budget-poller-log` artifact the twice-hourly Budget Poller
# uploads and report the age of the last OK telemetry record, runs received in
# the last 24h against the 48 expected (#2160), the dry-run decision (which
# window, what percent), and the burn rate. A last OK record older than
# BUDGET_POLLER_STALE_HOURS (default 6) — or none at all — raises a `::warning::`
# so a silently dead feed is visible. Best-effort and read-only: a missing
# artifact or API error renders "no OK record", never fails the monitor.
# ---------------------------------------------------------------------------
budget_poller_log_file=$(mktemp) || { echo "::error::budget-poller: failed to create temporary file" >&2; exit 1; }
if ! bp_download_latest_log "${BUDGET_POLLER_REPO:-petry-projects/.github-private}" "$budget_poller_log_file"; then
  echo "::notice::budget-poller: no readable ${BUDGET_POLLER_ARTIFACT} artifact — reporting no OK record"
  : > "$budget_poller_log_file"
fi
budget_poller_now=$(date +%s)
bp_staleness_warning "$budget_poller_log_file" "$budget_poller_now"

# ---------------------------------------------------------------------------
# 3. Generate reports
# ---------------------------------------------------------------------------
report_header() {
  printf '# Actions Fleet Monitor — %s\n\n' "$TODAY"
  printf '**Org:** `%s` | **Lookback:** %s day(s) | **Repos:** %s | **Workflows:** %s\n\n' \
    "$ORG" "$LOOKBACK_DAYS" "$repo_count" "$total_workflows"
}

# stub_drift_section — appends a coverage/drift block per processed stub (#822
# planner, #886 driver). One section per stub kind, headlined by its label.
stub_drift_section() {
  [ ${#stub_drift_files[@]} -eq 0 ] && return 0
  local i
  for i in "${!stub_drift_files[@]}"; do
    [ -s "${stub_drift_files[$i]}" ] || continue
    printf '\n'
    generate_stub_drift_report "${stub_drift_files[$i]}" "${stub_drift_canon[$i]}" "${stub_drift_labels[$i]}"
  done
}

# dev_lead_timeout_section — appends the Dev-Lead timeout ("wall") observability
# block (#1019) when any repo had dev-lead status markers in the window.
dev_lead_timeout_section() {
  [ -s "$dev_lead_reason_file" ] || return 0
  printf '\n'
  generate_dev_lead_timeout_report "$dev_lead_reason_file" "${fleet_dl_runs:-0}"
}

# schedule_reliability_section — appends the Schedule Reliability block (#725)
# when any scheduled workflow was seen in the window.
schedule_reliability_section() {
  [ -s "$schedule_metrics_file" ] || return 0
  printf '\n'
  generate_schedule_reliability_report "$schedule_metrics_file"
}

# persona_optout_section — appends the Persona opt-out label coverage block
# (#1644) when any repo's labels were readable.
persona_optout_section() {
  [ -s "$persona_optout_file" ] || return 0
  printf '\n'
  generate_persona_optout_report "$persona_optout_file" "${persona_optout_total:-0}"
}

# ingress_attribution_section — appends the Agent Ingress per-role run
# attribution block (#1727) when any repo carried agent-ingress runs. Buckets the
# accumulated normalized {role,conclusion} records by role. Omitted entirely when
# no ingress runs were seen (the current no-op reality).
ingress_attribution_section() {
  # Combine legacy (pre-collapse) and ingress (post-collapse) runs so a role that
  # ran on both sides of the collapse shares the required bucket (#1727 AC #4).
  local combined_attr_file attr_tsv
  combined_attr_file=$(mktemp)
  if [ -s "$legacy_attr_file" ] || [ -s "$ingress_attr_file" ]; then
    jq -s 'add // []' "$legacy_attr_file" "$ingress_attr_file" > "$combined_attr_file"
  fi
  [ -s "$combined_attr_file" ] || { rm -f "$combined_attr_file"; return 0; }
  attr_tsv=$(mktemp)
  jq -s '.' "$combined_attr_file" | attribution_buckets > "$attr_tsv"
  printf '\n'
  generate_attribution_report "$attr_tsv" "Run attribution (by role, across collapse)"
  rm -f "$attr_tsv" "$combined_attr_file"
}

# budget_poller_section — appends the dry-run budget poller liveness block
# (#2029): last OK record age (STALE past the window), decision window + percent.
budget_poller_section() {
  printf '\n'
  bp_fleet_section "$budget_poller_log_file" "$budget_poller_now"
}

# Step Summary — Tier 1 visualizations only (Mermaid not rendered there)
# GitHub Step Summary has a 1 MB hard limit per job. At ~200 bytes per row
# this supports ~5 000 workflows before truncation.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { report_header; generate_report "$metrics_file" "$failed_file" "false" "$issues_lookup_file"; dev_lead_timeout_section; schedule_reliability_section; persona_optout_section; ingress_attribution_section; stub_drift_section; budget_poller_section; } \
    >> "$GITHUB_STEP_SUMMARY"
fi

# Report file — full report with Mermaid charts (used as Issue body)
{ report_header; generate_report "$metrics_file" "$failed_file" "true" "$issues_lookup_file"; dev_lead_timeout_section; schedule_reliability_section; persona_optout_section; ingress_attribution_section; stub_drift_section; budget_poller_section; } \
  > "$REPORT_FILE"

# ---------------------------------------------------------------------------
# 3b. Export high-failure items as JSON for per-workflow issue tracking (>10%)
# ---------------------------------------------------------------------------
# Reads the raw metrics TSV and produces fleet_high_failure.json — an array of
# objects for every workflow whose failure rate exceeds 10%. The downstream
# "Track high-failure workflows" step reads this file to find/update or create
# a tracked GitHub Issue for each item and apply the dev-lead label.
# Gate workflows (FLEET_GATE_WORKFLOWS in fleet_report.sh) are excluded here —
# their failures are intentional policy enforcement, not breakage (#941).
HIGH_FAILURE_FILE="fleet_high_failure.json"
if [ -s "$metrics_file" ]; then
  filter_high_failure "$metrics_file" > "$HIGH_FAILURE_FILE"
  hf_count=$(jq 'length' "$HIGH_FAILURE_FILE")
  echo "High-failure items (>10%): ${hf_count}"
  [ -n "${GITHUB_ENV:-}" ] && echo "HIGH_FAILURE_COUNT=${hf_count}" >> "$GITHUB_ENV"
else
  echo "[]" > "$HIGH_FAILURE_FILE"
fi

# ---------------------------------------------------------------------------
# 3c. Export drifted stubs as JSON for alerting (#822 planner, #886 driver — AC#3)
# Produces fleet_stub_drift.json — the DRIFTED enrolled repos across every
# processed stub, each row tagged with its `stub`/`stub_file` so the workflow's
# "Track stub drift" step can group/route per stub kind. HAS_STUB_DRIFT wakes
# dev-lead. A combined empty array is emitted when no stub drifted.
# ---------------------------------------------------------------------------
STUB_DRIFT_JSON="fleet_stub_drift.json"
if [ ${#stub_drift_files[@]} -gt 0 ]; then
  stub_alert_tmp=$(mktemp)
  for i in "${!stub_drift_files[@]}"; do
    stub_drift_alert_json "${stub_drift_files[$i]}" "${stub_drift_labels[$i]}" "${stub_drift_paths[$i]}" "${stub_drift_roles[$i]}" \
      >> "$stub_alert_tmp"
  done
  # Merge the per-stub JSON arrays into one (empty → []).
  jq -s 'add // []' "$stub_alert_tmp" > "$STUB_DRIFT_JSON"
  rm -f "$stub_alert_tmp"
else
  echo "[]" > "$STUB_DRIFT_JSON"
fi
stub_drift_count=$(jq 'length' "$STUB_DRIFT_JSON")
echo "Drifted stubs (all kinds): ${stub_drift_count}"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "STUB_DRIFT_COUNT=${stub_drift_count}" >> "$GITHUB_ENV"
  [ "$stub_drift_count" -gt 0 ] && echo "HAS_STUB_DRIFT=true" >> "$GITHUB_ENV"
fi

# ---------------------------------------------------------------------------
# 3d. Export persona opt-out drift as a machine-readable JSON artifact (#1644)
# fleet_persona_optout.json is the array of INCOMPLETE repos (a persona can be
# mentioned there but its mandated <id>:hands-off opt-out does not exist), each
# with its missing labels — the same idiom as fleet_high_failure.json so the
# drift is available to a follow-up tracker, not just the rendered report.
# Empty array when nothing drifted.
# ---------------------------------------------------------------------------
PERSONA_OPTOUT_JSON="fleet_persona_optout.json"
persona_optout_alert_json "$persona_optout_file" > "$PERSONA_OPTOUT_JSON"
persona_optout_incomplete_count=$(jq 'length' "$PERSONA_OPTOUT_JSON")
echo "Persona opt-out INCOMPLETE repos: ${persona_optout_incomplete_count}"
# Export the drift count + a HAS_ flag so a downstream workflow step can track/
# alert on incomplete opt-out coverage — mirrors the HIGH_FAILURE_COUNT (3b) and
# STUB_DRIFT_COUNT/HAS_STUB_DRIFT (3c) idiom. Without this the JSON artifact is
# written but never consumed, so the drift is neither tracked nor alerted.
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "PERSONA_OPTOUT_INCOMPLETE_COUNT=${persona_optout_incomplete_count}" >> "$GITHUB_ENV"
  [ "$persona_optout_incomplete_count" -gt 0 ] && echo "HAS_PERSONA_OPTOUT_DRIFT=true" >> "$GITHUB_ENV"
fi

rm -f "$metrics_file" "$failed_file" "$issues_lookup_file" "$dev_lead_reason_file" "$schedule_metrics_file" "$persona_optout_file" "$ingress_attr_file" "$legacy_attr_file" "$budget_poller_log_file"
[ ${#stub_drift_files[@]} -gt 0 ] && rm -f "${stub_drift_files[@]}"

# ---------------------------------------------------------------------------
# 4. Export env flags
# ---------------------------------------------------------------------------
if [ "$any_failures" -eq 1 ]; then
  [ -n "${GITHUB_ENV:-}" ] && echo "HAS_FAILURES=true" >> "$GITHUB_ENV"
fi

echo ""
echo "Report: $REPORT_FILE ($(wc -c < "$REPORT_FILE") bytes)"
echo "=== Fleet monitor complete ==="
