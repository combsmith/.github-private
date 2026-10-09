#!/usr/bin/env bash
# Daily telemetry check for the PR Review Agent workflow.
#
# Fetches recent pr-review.yml run data, computes health metrics, and
# writes a structured markdown report to both GITHUB_STEP_SUMMARY and
# pr_review_health_report.md. Sets HAS_FAILURES=true in GITHUB_ENV when
# failed runs are detected.
#
# Env vars consumed:
#   GH_TOKEN      — must have actions:read on WORKFLOW_REPO
#   LOOKBACK_DAYS — days of history to consider (default: 1)
#   GITHUB_ENV    — written by Actions runner
#   GITHUB_STEP_SUMMARY — written by Actions runner

set -euo pipefail

# Pure by-event outcome-mix helpers (#1422). Sourced so the cancellation-rate
# breakdown is unit-tested (tests/pr_review_outcomes.bats) rather than inlined.
# shellcheck source=scripts/lib/pr-review-outcomes.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/pr-review-outcomes.sh"

# Pure sweep-hit-rate helpers (#1408, epic #1402). Sourced so the metric that
# tracks how often the pr-review-sweep scheduled backstop actually had to act is
# unit-tested (tests/pr_review_sweep_metrics.bats) rather than inlined. Live
# gh-API I/O for this metric lives below in this wrapper.
# shellcheck source=scripts/lib/pr-review-sweep-metrics.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/pr-review-sweep-metrics.sh"

# Pure run→role attribution for the collapsed agent-ingress (#1727, ADR-0007).
# Sourced so the pr-review health scan can re-sample post-collapse runs keyed on
# the role-bearing JOB name instead of the (soon shared) workflow name, keeping
# the pr-review signal intact once pr-review-mention collapses into agent-ingress.
# shellcheck source=scripts/lib/run-attribution.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/run-attribution.sh"

# Model family → current id resolver (#1979): name a family, never pin a version.
# Also lists break-glass overrides of config/ai-engines.json (ai_engines_overrides).
# shellcheck source=scripts/lib/engine-models.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/engine-models.sh"

LOOKBACK_DAYS="${LOOKBACK_DAYS:-1}"
WORKFLOW_REPO="${AGENT_REPO:-petry-projects/.github-private}"
WORKFLOW_FILE="pr-review-trigger.yml"
SWEEP_WORKFLOW_FILE="pr-review-sweep.yml"
# The role-bearing agent-ingress job that carries the pr-review signal post-collapse
# (ADR-0007). Env-overridable so a repo that names the role differently can retarget
# without a code change.
PR_REVIEW_INGRESS_ROLE="${PR_REVIEW_INGRESS_ROLE:-pr-review-mention}"
REPORT_FILE="pr_review_health_report.md"
TODAY=$(date -u +%Y-%m-%d)

echo "=== PR Review Agent — Daily Health Check ==="
echo "  Repo:         $WORKFLOW_REPO"
echo "  Workflow:     $WORKFLOW_FILE"
echo "  Lookback:     ${LOOKBACK_DAYS} day(s)"
echo "  Date:         $TODAY"
echo ""

# ---------------------------------------------------------------------------
# 0. Token selection
# ---------------------------------------------------------------------------
if ! gh api "repos/${WORKFLOW_REPO}/actions/workflows/${WORKFLOW_FILE}/runs?per_page=1" \
     >/dev/null 2>&1; then
  if [ -n "${GH_PAT_FALLBACK:-}" ]; then
    echo "::warning::GH_TOKEN cannot access ${WORKFLOW_REPO} — using GH_PAT_FALLBACK"
    export GH_TOKEN="$GH_PAT_FALLBACK"
  else
    echo "::error::GH_TOKEN cannot access ${WORKFLOW_REPO} and GH_PAT_FALLBACK is not set."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Fetch run metadata
# ---------------------------------------------------------------------------
CUTOFF=$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)

echo "Fetching runs since: $CUTOFF"

runs_json=$(gh api \
  --paginate \
  "repos/${WORKFLOW_REPO}/actions/workflows/${WORKFLOW_FILE}/runs?per_page=100&created=>=${CUTOFF}" \
  --jq '.workflow_runs | map({
    id: .id,
    run_number: .run_number,
    status: .status,
    conclusion: .conclusion,
    event: .event,
    created_at: .created_at,
    html_url: .html_url,
    duration_s: ((.updated_at | fromdate) - (.created_at | fromdate))
  })' 2>/dev/null | jq -s 'add // []' 2>/dev/null || echo '[]')

# ---------------------------------------------------------------------------
# 1b. Sweep-hit-rate telemetry (#1408)
#
# Fetch pr-review-sweep runs in the window and, for each SCHEDULED (cron) tick,
# derive how many reviews it re-dispatched by parsing the deterministic
# "Sweep summary: … K review(s) dispatched." line from the run's log. The pure
# helper (pr_review_sweep_hit_rate) counts only event=="schedule" entries, so
# workflow_run fast-path runs are naturally excluded. A scheduled tick that
# re-dispatched a review is, by construction (#1408 narrowing), a genuinely
# un-eventable case the event fast path did not cover.
#
# Best-effort and gracefully degrading: a log that cannot be fetched yields a
# dispatched count of 0 (the tick still counts, mirroring the LOG_DIR pattern
# for failed-run logs above). SWEEP_MAX_LOG_FETCH bounds the per-run log I/O so
# a busy window cannot blow the job's time budget; ticks beyond the cap are
# omitted so the denominator stays consistent with the hits actually measured.
# ---------------------------------------------------------------------------
SWEEP_MAX_LOG_FETCH="${SWEEP_MAX_LOG_FETCH:-200}"
sweep_runs_meta=$(gh api \
  --paginate \
  "repos/${WORKFLOW_REPO}/actions/workflows/${SWEEP_WORKFLOW_FILE}/runs?per_page=100&created=>=${CUTOFF}" \
  --jq '[.workflow_runs[]? | select(.event == "schedule") | {id: .id, event: .event}]' \
  2>/dev/null | jq -s 'add // []' 2>/dev/null || echo '[]')

sweep_dispatched=()
sweep_fetched=0
total_sweep_ticks=$(jq 'length' <<< "$sweep_runs_meta" 2>/dev/null || echo 0)
while IFS= read -r sweep_id; do
  [ -n "$sweep_id" ] || continue
  if [ "$sweep_fetched" -ge "$SWEEP_MAX_LOG_FETCH" ]; then
    echo "::warning::sweep-hit-rate: reached SWEEP_MAX_LOG_FETCH=${SWEEP_MAX_LOG_FETCH}; omitting remaining ticks from the metric"
    break
  fi
  sweep_fetched=$((sweep_fetched + 1))
  sweep_log=$(gh run view "$sweep_id" --repo "$WORKFLOW_REPO" --log 2>/dev/null || true)
  dispatched=$(pr_review_sweep_dispatched_from_log "$sweep_log")
  sweep_dispatched+=("${dispatched:-0}")
done < <(jq -r '.[].id' <<< "$sweep_runs_meta")

if [ "${#sweep_dispatched[@]}" -gt 0 ]; then
  sweep_telemetry=$(jq -n '$ARGS.positional | map({event: "schedule", dispatched: (. | tonumber)})' --args "${sweep_dispatched[@]}")
else
  sweep_telemetry='[]'
fi

# ---------------------------------------------------------------------------
# 1c. Agent Ingress per-role attribution for the pr-review signal (#1727)
#
# Once the pr-review-mention Class-1 caller collapses into agent-ingress.yml
# (ADR-0007), sampling BY WORKFLOW NAME (Section 1, legacy pr-review-trigger.yml)
# no longer sees those runs, and a name-keyed scan would lump the pr-review role
# in with every other collapsed role. Here we re-sample the agent-ingress runs
# keyed on the role-bearing JOB name (jobs API) and keep only the pr-review role
# bucket, so the pr-review signal survives the collapse. Additive and a complete
# no-op when the repo carries no agent-ingress.yml (current reality) — the legacy
# pr-review-trigger.yml sampling above is untouched (AC #3). A run whose role
# cannot be named is bucketed UNATTRIBUTED, never dropped (AC #5).
# ---------------------------------------------------------------------------
ingress_attr_jsonl=$(mktemp)
# A failed workflow-discovery read must NOT look like a repo without ingress:
# distinguish the API/authz failure (warn) from a genuinely absent ingress
# workflow (empty id -> silent no-op, the current reality). `first(...) // empty`
# avoids piping to `head -1`, which can SIGPIPE (141) under `set -o pipefail`.
if ! ingress_wf_id=$(gh api "repos/${WORKFLOW_REPO}/actions/workflows?per_page=100" --paginate \
  --jq "first(.workflows[] | select((.path | split(\"/\") | last) == \"${INGRESS_WORKFLOW_BASENAME}\") | .id | tostring) // empty" \
  2>/dev/null); then
  echo "::warning::Cannot read workflows for ${WORKFLOW_REPO} — pr-review ingress attribution skipped"
elif [ -n "$ingress_wf_id" ]; then
  # A failed run-list read must not silently collapse to "no runs" — that would
  # hide the post-collapse signal. Warn and skip rather than report an empty set.
  if ! ingress_run_ids=$(gh api \
    "repos/${WORKFLOW_REPO}/actions/workflows/${ingress_wf_id}/runs?per_page=100&created=>=${CUTOFF}" \
    --paginate \
    --jq '.workflow_runs[] | select(.conclusion != null) | (.id | tostring)' \
    2>/dev/null); then
    echo "::warning::Cannot read ingress runs for ${WORKFLOW_REPO} — pr-review ingress attribution skipped"
  else
    per_run_tmp=$(mktemp)
    while IFS= read -r run_id; do
      [ -n "$run_id" ] || continue
      if ! jobs_raw=$(gh api "repos/${WORKFLOW_REPO}/actions/runs/${run_id}/jobs?per_page=100" --paginate \
        --jq '[.jobs[] | {name, conclusion}]' 2>/dev/null); then
        echo "::warning::Cannot read jobs for run ${run_id} — pr-review ingress attribution may undercount"
        continue
      fi
      jobs_json=$(printf '%s' "$jobs_raw" | jq -s 'add // []')
      jq -n --argjson rid "$run_id" --argjson jobs "$jobs_json" \
        '{run_id: $rid, jobs: $jobs}' >> "$per_run_tmp"
    done <<< "$ingress_run_ids"
    # Normalize per-run jobs → one {role,conclusion} per role, then keep the
    # pr-review role AND the loud UNATTRIBUTED sentinel (this scan is the pr-review
    # signal, not the whole fleet, but a completed run whose role could not be
    # named must stay visible rather than silently vanish — AC #5).
    jq -s '.' "$per_run_tmp" | normalize_ingress_runs \
      | jq -c --arg role "$PR_REVIEW_INGRESS_ROLE" --arg unattr "$UNATTRIBUTED_ROLE" \
          '.[] | select(.role == $role or .role == $unattr)' \
      >> "$ingress_attr_jsonl"
    rm -f "$per_run_tmp"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Compute aggregate stats
# ---------------------------------------------------------------------------
read -r total_runs failed_runs success_runs cancelled_runs < <(echo "$runs_json" | jq -r '
  [
    length,
    ([.[] | select(.conclusion == "failure")] | length),
    ([.[] | select(.conclusion == "success")] | length),
    ([.[] | select(.conclusion == "cancelled")] | length)
  ] | @tsv')

echo "  Total:      $total_runs"
echo "  Success:    $success_runs"
echo "  Failed:     $failed_runs"
echo "  Cancelled:  $cancelled_runs"

if [ "$total_runs" -gt 0 ]; then
  failure_rate=$(echo "scale=1; $failed_runs * 100 / $total_runs" | bc)
else
  failure_rate="0.0"
fi

# Duration percentiles across all completed runs. Surfaced deterministically in the
# report output as a convergence-latency signal for the pre/post baseline (#1411).
read -r dur_n dur_min dur_p50 dur_p95 dur_max < <(echo "$runs_json" | jq -r '
  [.[] | select(.conclusion != null and .duration_s > 0) | .duration_s] | sort |
  if length == 0 then "0 0 0 0 0"
  else . as $d | ($d | length) as $n |
    "\($n) \($d | min) \($d[$n * 50 / 100 | floor]) \($d[$n * 95 / 100 | floor]) \($d | max)"
  end')

# ---------------------------------------------------------------------------
# 3. Helpers
# ---------------------------------------------------------------------------
fmt_dur() {
  local s=$1
  if [ "$s" -ge 60 ]; then
    printf '%dm%ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}

conclusion_icon() {
  case "$1" in
    success)   echo "✅" ;;
    failure)   echo "❌" ;;
    cancelled) echo "⚪" ;;
    skipped)   echo "⏭️" ;;
    *)         echo "⏳" ;;
  esac
}

# overall is the pre-computed status fed as a hint to the LLM prompt below.
# shellcheck disable=SC2034
if [ "$failed_runs" -eq 0 ]; then
  overall="HEALTHY"
elif [ "$(echo "$failure_rate > 50" | bc)" -eq 1 ]; then
  overall="CRITICAL"
elif [ "$(echo "$failure_rate > 20" | bc)" -eq 1 ]; then
  overall="DEGRADED"
else
  overall="WARNING"
fi

# ---------------------------------------------------------------------------
# 4. Build report
# ---------------------------------------------------------------------------
[ -n "${GITHUB_ENV:-}" ] && {
  if [ "$failed_runs" -gt 0 ]; then
    echo "HAS_FAILURES=true" >> "$GITHUB_ENV"
  else
    echo "HAS_FAILURES=false" >> "$GITHUB_ENV"
  fi
}

RUNS_SUMMARY=$(echo "$runs_json" | jq -r '
  sort_by(.run_number) | reverse
  | map("#\(.run_number) \(.conclusion // .status) @ \(.created_at)")
  | join("\n")
')
LOG_DIR="${LOG_DIR:-}"

logs_file=$(mktemp)
# One jq pass over failed runs; append each log file in the same order
while IFS=$'\t' read -r run_id run_meta; do
  [ -n "$LOG_DIR" ] || continue
  log_file="${LOG_DIR}/run_${run_id}.txt"
  [ -f "$log_file" ] || continue
  {
    printf '=== LOG: %s ===\n' "$run_meta"
    cat "$log_file"
    printf '=== END LOG ===\n\n'
  } >> "$logs_file"
done < <(echo "$runs_json" | jq -r \
  '.[] | select(.conclusion == "failure") | [(.id | tostring), "run #\(.run_number) (\(.conclusion)) at \(.created_at)"] | @tsv')

workflow_source=$(gh api "repos/${WORKFLOW_REPO}/contents/.github/workflows/${WORKFLOW_FILE}" \
  --jq '.content' 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null \
  || echo "(workflow source unavailable)")

# ---------------------------------------------------------------------------
# 5. Surface the (already-computed) duration percentiles deterministically.
# Written BEFORE the model-generated content so that workflow truncation
# (60 000 bytes in daily-pr-review-health.yml) cannot discard this section.
# ---------------------------------------------------------------------------
{
  printf '## Convergence latency (deterministic)\n\n'
  printf 'Workflow duration across %s completed run(s) in the window — computed by `%s`, not the model.\n\n' \
    "$dur_n" "$(basename "$0")"
  printf '| Workflow | Runs | min | p50 | p95 | max |\n'
  printf '|---|---:|---:|---:|---:|---:|\n'
  printf '| `%s` | %s | %s | %s | %s | %s |\n' \
    "$WORKFLOW_FILE" "$dur_n" \
    "$(fmt_dur "$dur_min")" "$(fmt_dur "$dur_p50")" "$(fmt_dur "$dur_p95")" "$(fmt_dur "$dur_max")"
  printf '\n'
  # Run-outcome mix by triggering event (#1422). Deterministic — same truncation
  # guarantee as the percentiles above: written before the model-generated body.
  pr_review_render_outcome_mix "$runs_json"
  # Sweep hit-rate (#1408). Deterministic — how often the scheduled backstop
  # actually re-reviewed a PR the event fast path did not cover. Same truncation
  # guarantee: written before the model-generated body.
  pr_review_render_sweep_hit_rate "$sweep_telemetry" "$total_sweep_ticks"
  # Per-role attribution for the post-collapse pr-review signal (#1727).
  # Deterministic — same truncation guarantee. Omitted when the repo carries no
  # agent-ingress.yml (current reality), so legacy repos see no empty section.
  if [ -s "$ingress_attr_jsonl" ]; then
    attr_tsv=$(mktemp)
    # Fold the PRE-collapse legacy pr-review runs (Section 1's runs_json) into the
    # SAME per-role bucket as the POST-collapse ingress records so a role that ran
    # on both sides of the collapse is counted once across the window (parity, AC
    # #4) instead of the bucket reflecting only post-collapse runs. The legacy runs
    # are keyed to PR_REVIEW_INGRESS_ROLE (via a synthetic workflow basename) so
    # they share the ingress role's key rather than the legacy workflow's name.
    legacy_attr_jsonl=$(mktemp)
    printf '%s' "$runs_json" | normalize_legacy_runs "${PR_REVIEW_INGRESS_ROLE}.yml" \
      | jq -c '.[]' > "$legacy_attr_jsonl"
    jq -s '.' "$ingress_attr_jsonl" "$legacy_attr_jsonl" | attribution_buckets > "$attr_tsv"
    generate_attribution_report "$attr_tsv" "PR-review run attribution (by role, across collapse)"
    rm -f "$attr_tsv" "$legacy_attr_jsonl"
  fi
  # Break-glass overrides (#1973): an AI_MODELS_* key or AI_ENGINES that differs
  # from config/ai-engines.json. Listed every day until it is folded back into
  # the file, so a temporary override cannot live on silently. Deterministic —
  # same truncation guarantee.
  printf '## Engine configuration overrides\n\n'
  if ! engine_overrides="$(ai_engines_overrides)"; then
    engine_overrides=""
    printf 'Could not read `config/ai-engines.json` — see the run log.\n\n'
  else
    model_problems="$(ai_models_problems)"
    if [ -n "$engine_overrides" ]; then
      printf 'These Actions variables override `config/ai-engines.json`. Fold each into the file through a normal release, then delete the variable.\n\n'
      printf '%s\n' "$engine_overrides" | sed 's/^/- `/; s/$/`/'
      printf '\n'
    fi
    if [ -n "$model_problems" ]; then
      printf 'Invalid engine model overrides (ignored):\n\n'
      printf '%s\n' "$model_problems" | sed 's/^/- `/; s/$/`/'
      printf '\n'
    fi
    if [ -z "$engine_overrides" ] && [ -z "$model_problems" ]; then
      printf 'None: every engine and model setting comes from `config/ai-engines.json`.\n\n'
    fi
  fi
} > "$REPORT_FILE"
rm -f "$ingress_attr_jsonl"

if [ -n "${engine_overrides:-}" ]; then
  while IFS= read -r line; do
    echo "::warning::engine override differs from config/ai-engines.json: $line"
  done <<< "$engine_overrides"
fi

echo "Duration percentiles — p50 $(fmt_dur "$dur_p50") / p95 $(fmt_dur "$dur_p95") across $dur_n run(s)"
echo "Outcome mix (by event):"
pr_review_outcomes_by_event "$runs_json" | sed 's/^/  /'
IFS=$'\t' read -r sweep_ticks sweep_hits sweep_rate < <(pr_review_sweep_hit_rate "$sweep_telemetry")
echo "Sweep hit-rate: ${sweep_hits}/${sweep_ticks} scheduled tick(s) re-dispatched — ${sweep_rate}"
if [ "${total_sweep_ticks:-0}" -gt 0 ] && [ "$sweep_ticks" -lt "$total_sweep_ticks" ]; then
  echo "  (partial: ${sweep_ticks} of ${total_sweep_ticks} ticks measured — cap or fetch errors omitted the rest)"
fi

echo "Invoking Claude for log analysis..."
# Claude writes errors to stdout (not stderr), so they'd silently land in
# $REPORT_FILE with the stdout redirect below.  Wrap in `if !` so a non-zero
# exit surfaces the file contents to the Actions log before aborting.
if ! claude --print --model "$(ai_model_for_family sonnet)" --no-session-persistence >> "$REPORT_FILE" <<PROMPT
You are analyzing GitHub Actions workflow run logs for the PR Review Agent.

## Context
- Workflow: \`${WORKFLOW_FILE}\` in repo \`${WORKFLOW_REPO}\`
- Analysis window: last ${LOOKBACK_DAYS} days (all runs fetched via pagination)
- Report date: ${TODAY}
- Total runs fetched: ${total_runs} | Successful: ${success_runs} | Failed: ${failed_runs} | Cancelled: ${cancelled_runs}
- Run duration across ${dur_n} completed run(s): p50 $(fmt_dur "$dur_p50") | p95 $(fmt_dur "$dur_p95") (min $(fmt_dur "$dur_min") / max $(fmt_dur "$dur_max"))

## Run Summary
${RUNS_SUMMARY}

## Workflow Source (.github/workflows/${WORKFLOW_FILE})
\`\`\`yaml
${workflow_source}
\`\`\`

## Failed Run Logs
$(cat "$logs_file")

---

Analyze these logs and produce a markdown health report with the following sections:

### 1. Executive Summary
Use F-style layout — lead with the most critical signal, then supporting bullets. No prose paragraphs.

Format:
**Status:** BLOCKING | DEGRADED | WARNING | HEALTHY
**Period:** <date range>
**Result:** <X of Y runs failed (Z%)>

Key findings:
- <dominant failure cause — one line>
- <secondary issue if any — one line>
- <any pattern worth noting — one line>

Action required: <one imperative sentence, or "None" if healthy>

### 2. Failure Breakdown
A table with columns: Failure Category | Affected Runs | Example Error Message.
Categories to look for (not exhaustive):
- CLI breaking change (e.g. invalid flag values)
- Permission / auth error (403, 401, insufficient scope)
- GitHub API rate limit
- Missing token scope (e.g. read:org, read:packages)
- Engine rate limit (Claude or Copilot quota)
- Timeout / infrastructure
- Other / unknown

### 3. Error Patterns
For each category found: quote the exact error message from the logs, identify which step and script it comes from, and explain the root cause.

### 4. Token Scope Analysis
From the workflow source and any gh auth status output in the logs, list:
- Scopes currently present
- Scopes that appear missing or insufficient based on the errors
- Recommendation for each missing scope

### 5. Recommendations
Numbered list. For each issue include: what to change (file, line, command), why, expected impact after fix, and urgency: [CRITICAL | HIGH | MEDIUM | LOW].
Mark CRITICAL if the issue causes 100% workflow failure.

### 6. Health Score
Single line: \`Health: X/10 — <one-sentence verdict>\`
(10 = all runs passing; 0 = complete outage)

Output ONLY the markdown report — no preamble or commentary outside the report sections.
PROMPT
then
  echo "::error::Claude invocation failed. CLI output follows:"
  cat "$REPORT_FILE" >&2
  rm -f "$logs_file"
  exit 1
fi
rm -f "$logs_file"

[ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "$REPORT_FILE" ] && cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"

echo ""
echo "Report written to $REPORT_FILE ($(wc -c < "$REPORT_FILE") bytes)"
echo "=== Health check complete ==="