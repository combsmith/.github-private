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
#   ORG             — GitHub org to scan (default: combsmith)
#   LOOKBACK_DAYS   — days of history to consider (default: 1)
#   GITHUB_ENV      — written by Actions runner
#   GITHUB_STEP_SUMMARY — written by Actions runner (1 MB hard limit per job)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/fleet_report.sh
source "${SCRIPT_DIR}/fleet_report.sh"
# shellcheck source=scripts/fleet_stub_drift.sh
source "${SCRIPT_DIR}/fleet_stub_drift.sh"

ORG="${ORG:-combsmith}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-1}"
REPORT_FILE="fleet_monitor_report.md"
TODAY=$(date -u +%Y-%m-%d)

# Initiative-planner stub coverage & drift (#822). The per-repo thin-caller stub
# is deployed verbatim from the canonical org template; we compare blob SHAs.
STUB_PATH="${STUB_PATH:-.github/workflows/initiative-planner.yml}"
CANONICAL_STUB_REPO="${CANONICAL_STUB_REPO:-combsmith/.github}"
CANONICAL_STUB_PATH="${CANONICAL_STUB_PATH:-standards/workflows/initiative-planner.yml}"

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
  done < <(echo "$workflows" | jq -r '.[] | [.id, .file] | @tsv')
done

# ---------------------------------------------------------------------------
# 2a. Initiative-planner stub coverage & drift (#822, AC#2 + AC#3)
# For each discovered repo, compare its per-repo planner stub blob SHA against
# the canonical org-template SHA. Reuses the repo list already discovered above
# (extends the Fleet Monitor rather than building a parallel monitor, per #627).
# The contents API `.sha` is the git blob object ID, so equal SHAs => identical.
# ---------------------------------------------------------------------------
stub_drift_file=$(mktemp)
canonical_stub_sha=$(gh api \
  "repos/${CANONICAL_STUB_REPO}/contents/${CANONICAL_STUB_PATH}" \
  --jq '.sha' 2>/dev/null || true)

if [ -z "$canonical_stub_sha" ]; then
  echo "::warning::Could not read canonical stub SHA (${CANONICAL_STUB_REPO}/${CANONICAL_STUB_PATH}) — skipping stub drift detection."
else
  echo "Canonical stub SHA: ${canonical_stub_sha} (${CANONICAL_STUB_REPO}/${CANONICAL_STUB_PATH})"
  for repo in "${repos[@]}"; do
    # 404 (no stub) => empty SHA => MISSING (not enrolled); non-fatal.
    repo_stub_sha=$(gh api "repos/${repo}/contents/${STUB_PATH}" \
      --jq '.sha' 2>/dev/null || true)
    stub_drift_row "$repo" "$canonical_stub_sha" "$repo_stub_sha" >> "$stub_drift_file"
  done
fi

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
# 3. Generate reports
# ---------------------------------------------------------------------------
report_header() {
  printf '# Actions Fleet Monitor — %s\n\n' "$TODAY"
  printf '**Org:** `%s` | **Lookback:** %s day(s) | **Repos:** %s | **Workflows:** %s\n\n' \
    "$ORG" "$LOOKBACK_DAYS" "$repo_count" "$total_workflows"
}

# stub_drift_section — appends the #822 coverage/drift block when we have data.
stub_drift_section() {
  if [ -s "$stub_drift_file" ]; then
    printf '\n'
    generate_stub_drift_report "$stub_drift_file" "$canonical_stub_sha"
  fi
}

# Step Summary — Tier 1 visualizations only (Mermaid not rendered there)
# GitHub Step Summary has a 1 MB hard limit per job. At ~200 bytes per row
# this supports ~5 000 workflows before truncation.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { report_header; generate_report "$metrics_file" "$failed_file" "false" "$issues_lookup_file"; stub_drift_section; } \
    >> "$GITHUB_STEP_SUMMARY"
fi

# Report file — full report with Mermaid charts (used as Issue body)
{ report_header; generate_report "$metrics_file" "$failed_file" "true" "$issues_lookup_file"; stub_drift_section; } \
  > "$REPORT_FILE"

# ---------------------------------------------------------------------------
# 3b. Export high-failure items as JSON for per-workflow issue tracking (>10%)
# ---------------------------------------------------------------------------
# Reads the raw metrics TSV and produces fleet_high_failure.json — an array of
# objects for every workflow whose failure rate exceeds 10%. The downstream
# "Track high-failure workflows" step reads this file to find/update or create
# a tracked GitHub Issue for each item and apply the dev-lead label.
HIGH_FAILURE_FILE="fleet_high_failure.json"
if [ -s "$metrics_file" ]; then
  jq -Rn '
    [inputs | select(length > 0) | split("\t") | select(length >= 12) |
     {
       sort_key:  .[0],
       repo:      .[1],
       workflow:  .[2],
       total:    (.[3]  | tonumber? // 0),
       success:  (.[4]  | tonumber? // 0),
       failed:   (.[5]  | tonumber? // 0),
       cancelled:(.[6]  | tonumber? // 0),
       rate:      .[7],
       p50:      (.[8]  | tonumber? // 0),
       p95:      (.[9]  | tonumber? // 0),
       label:     .[10],
       rate_int: (.[11] | tonumber? // 0)
     }] |
    # Apply confidence filter: CRITICAL rows with < 5 total runs become LOW-CONF
    map(if .label == "CRITICAL" and .total < 5 then .label = "LOW-CONF" else . end) |
    # Keep trackable items:
    #   ERROR rows (monitor could not read runs — always noteworthy regardless of rate)
    #   WARNING/DEGRADED/CRITICAL with exact failure rate > 10%
    #   (uses .failed/.total directly to avoid integer-truncation false negatives)
    map(select(
      .label == "ERROR" or
      (
        .label != "LOW-CONF" and
        (.label | IN("WARNING","DEGRADED","CRITICAL")) and
        .total > 0 and
        (.failed * 100.0 / .total > 10)
      )
    )) |
    sort_by(.failed * 100.0 / (if .total > 0 then .total else 1 end)) | reverse
  ' < "$metrics_file" > "$HIGH_FAILURE_FILE"
  hf_count=$(jq 'length' "$HIGH_FAILURE_FILE")
  echo "High-failure items (>10%): ${hf_count}"
  [ -n "${GITHUB_ENV:-}" ] && echo "HIGH_FAILURE_COUNT=${hf_count}" >> "$GITHUB_ENV"
else
  echo "[]" > "$HIGH_FAILURE_FILE"
fi

# ---------------------------------------------------------------------------
# 3c. Export drifted stubs as JSON for alerting (#822, AC#3)
# Produces fleet_stub_drift.json — the DRIFTED enrolled repos. The workflow's
# "Alert on stub drift" step reads this and HAS_STUB_DRIFT to wake dev-lead.
# ---------------------------------------------------------------------------
STUB_DRIFT_JSON="fleet_stub_drift.json"
stub_drift_alert_json "$stub_drift_file" > "$STUB_DRIFT_JSON"
stub_drift_count=$(jq 'length' "$STUB_DRIFT_JSON")
echo "Drifted initiative-planner stubs: ${stub_drift_count}"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "STUB_DRIFT_COUNT=${stub_drift_count}" >> "$GITHUB_ENV"
  [ "$stub_drift_count" -gt 0 ] && echo "HAS_STUB_DRIFT=true" >> "$GITHUB_ENV"
fi

rm -f "$metrics_file" "$failed_file" "$issues_lookup_file" "$stub_drift_file"

# ---------------------------------------------------------------------------
# 4. Export env flags
# ---------------------------------------------------------------------------
if [ "$any_failures" -eq 1 ]; then
  [ -n "${GITHUB_ENV:-}" ] && echo "HAS_FAILURES=true" >> "$GITHUB_ENV"
fi

echo ""
echo "Report: $REPORT_FILE ($(wc -c < "$REPORT_FILE") bytes)"
echo "=== Fleet monitor complete ==="
