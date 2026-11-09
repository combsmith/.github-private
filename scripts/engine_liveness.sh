#!/usr/bin/env bash
# engine_liveness.sh — scheduled engine-token liveness monitor (#1587).
#
# #1587: dev-lead failed 100% of runs across 8 repos for seven days — every run
# died at the "Engine token preflight" step ("CLAUDE_CODE_OAUTH_TOKEN is not
# provided to dev-lead-reusable.") — and no alert reached a human; the fleet only
# noticed because a person went looking. This monitor is the missing escalation:
# for every repo that hosts a dev-lead or pr-review caller stub it inspects the
# most-recent run(s) of that stub and asserts they did NOT fail at the preflight
# step, then escalates a SUSTAINED, FLEET-WIDE failure differently from a flake:
#
#   AGENTS_PAUSED=true                               -> silent, no alert (a
#                                                       deliberate maintainer pause
#                                                       is never a false alarm)
#   >=2 consecutive preflight failures in >=2 repos  -> FLEET alert (the outage
#                                                       class this exists to catch)
#   otherwise any single-repo preflight failure      -> ISOLATED health-check report
#
# It also checks the GH_PAT_DON_PETRY credential's scope/expiry — a classic PAT is
# a silent single point of failure for the apply-repo-settings initiative
# (#984/#985/#1209): rotation/revocation surfaces only as an opaque 401/403 on the
# next scheduled run unless something reports it ahead of time.
#
# The DECISION logic (what counts as a preflight failure, the per-repo state, the
# fleet gate, the PAT scope/expiry classification, the report rendering) lives in
# scripts/lib/engine_liveness_detect.sh and is unit-tested there. This wrapper is
# the network layer: gh/jq gathering + report/GITHUB_ENV side-effects. It NEVER
# raises the alert itself — it emits ENGINE_LIVENESS_ESCALATION so the workflow
# can find-or-create the fleet issue only when warranted.
#
# Env vars consumed:
#   GH_TOKEN                     — org-scoped read (actions:read on target repos)
#   AGENTS_PAUSED                — "true" suppresses the monitor entirely
#   ENGINE_LIVENESS_REPOS        — optional space/comma repo override (else manifest)
#   ENGINE_LIVENESS_STUBS        — optional space/comma stub-file override
#   ENGINE_LIVENESS_MAX_RUNS     — most-recent runs to inspect per stub (default 3)
#   ENGINE_LIVENESS_LOOKBACK_DAYS— recency window in days (default 3); runs older
#                                  than this are ignored when computing the streak,
#                                  and a stub whose newest run predates it is STALE,
#                                  not OUTAGE, and does NOT fail the run (#1600)
#   ENGINE_PAT_EXPIRY_WARN_DAYS  — expiry warn window in days (default 14)
#   ENGINE_PAT_REQUIRED_SCOPES   — space-separated required scopes (default "repo workflow")
#   MANIFEST_FILE                — consumer manifest path (default scripts/lib/consumer-manifest.json)
#   REPORT_FILE / ALERT_BODY_FILE — output paths (defaults below)
#   GITHUB_ENV / GITHUB_STEP_SUMMARY — written by the Actions runner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/engine_liveness_detect.sh
source "${SCRIPT_DIR}/lib/engine_liveness_detect.sh"

MANIFEST_FILE="${MANIFEST_FILE:-${SCRIPT_DIR}/lib/consumer-manifest.json}"
MAX_RUNS=$(_el_int "${ENGINE_LIVENESS_MAX_RUNS:-3}")
[ "$MAX_RUNS" -ge 1 ] || MAX_RUNS=3
LOOKBACK_DAYS=$(_el_int "${ENGINE_LIVENESS_LOOKBACK_DAYS:-$ENGINE_LIVENESS_DEFAULT_LOOKBACK_DAYS}")
[ "$LOOKBACK_DAYS" -ge 1 ] || LOOKBACK_DAYS=$ENGINE_LIVENESS_DEFAULT_LOOKBACK_DAYS
NOW_EPOCH=$(date -u +%s)
PAT_WARN_DAYS=$(_el_int "${ENGINE_PAT_EXPIRY_WARN_DAYS:-14}")
[ "$PAT_WARN_DAYS" -ge 1 ] || PAT_WARN_DAYS=14
PAT_REQUIRED_SCOPES="${ENGINE_PAT_REQUIRED_SCOPES:-repo workflow}"
REPORT_FILE="${REPORT_FILE:-engine_liveness_report.md}"
ALERT_BODY_FILE="${ALERT_BODY_FILE:-engine_liveness_alert.md}"
TODAY=$(date -u +%Y-%m-%d)

# Caller-stub workflow filenames to inspect in each repo. dev-lead callers use
# dev-lead.yml; pr-review callers use pr-review.yml or pr-review-reusable.yml
# (both are live during the pr-review.yml -> pr-review-reusable.yml rename — the
# manifest enumerates consumers pinned to EITHER, so both must be queried or the
# reusable-pinned consumers go unmonitored and falsely healthy, #1587), or
# pr-review-trigger.yml (the ring-0 self-host stub in this repo). A repo that has
# none of these under a given name is skipped silently (404 on the runs API).
DEFAULT_STUBS="dev-lead.yml pr-review.yml pr-review-reusable.yml pr-review-trigger.yml"
STUBS="${ENGINE_LIVENESS_STUBS:-$DEFAULT_STUBS}"
STUBS="${STUBS//,/ }"

# ---------------------------------------------------------------------------
# 0. Deliberate-pause gate — never alert on a maintainer pause (#1587 scope 3).
# ---------------------------------------------------------------------------
if [[ "${AGENTS_PAUSED:-false}" = "true" ]]; then
  echo "::notice::engine-liveness: agent fleet deliberately paused (AGENTS_PAUSED=true) — liveness not evaluated, no alert (#1525/#1587)"
  {
    printf '# Engine-Token Liveness — %s\n\n' "$TODAY"
    printf '**Fleet paused** (`AGENTS_PAUSED=true`) — preflight liveness not evaluated and no alert raised (#1525/#1587).\n'
  } > "$REPORT_FILE"
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
      echo "ENGINE_LIVENESS_PAUSED=true"
      echo "ENGINE_LIVENESS_ESCALATION=NONE"
      echo "ENGINE_LIVENESS_SHOULD_FAIL=false"
    } >> "$GITHUB_ENV"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Enumerate the repos that host a dev-lead or pr-review caller stub.
# ---------------------------------------------------------------------------
enumerate_repos() {
  if [[ -n "${ENGINE_LIVENESS_REPOS:-}" ]]; then
    printf '%s\n' "${ENGINE_LIVENESS_REPOS//,/ }" | tr ' ' '\n' | sed '/^$/d'
    return 0
  fi
  if [[ ! -f "$MANIFEST_FILE" ]]; then
    echo "::warning::engine-liveness: manifest ${MANIFEST_FILE} not found and ENGINE_LIVENESS_REPOS unset — nothing to monitor" >&2
    return 0
  fi
  # Consumers whose pinned refs include the dev-lead or pr-review reusable.
  jq -r '
    .consumers[]
    | select([.refs[] | test("dev-lead-reusable\\.yml$|pr-review(-reusable)?\\.yml$")] | any)
    | .repo
  ' "$MANIFEST_FILE" 2>/dev/null | sort -u
}

# run_failed_at_preflight <repo> <run_id> — echo "yes" when any job step of the
# run is the engine-token preflight AND concluded "failure"; "no" when steps are
# readable and none match; "unknown" when the jobs API could not be read.
run_failed_at_preflight() {
  local repo="$1" run_id="$2" steps
  steps=$(gh api --paginate "repos/${repo}/actions/runs/${run_id}/jobs" \
    --jq '.jobs[].steps[]? | [(.name // ""), (.conclusion // "")] | @tsv' 2>/dev/null) \
    || { echo "unknown"; return 0; }
  [[ -n "$steps" ]] || { echo "no"; return 0; }
  local name concl
  while IFS=$'\t' read -r name concl; do
    if step_is_preflight_failure "$name" "$concl"; then
      echo "yes"
      return 0
    fi
  done <<< "$steps"
  echo "no"
}

# gather_runs_tsv <repo> <stub_file> <out_tsv> — write, most-recent-first, one row
# "<run_started_at_iso> <TAB> <yes|no>" per COMPLETED run of <stub_file> to
# <out_tsv> (yes == the run failed at the engine-token preflight step). This gives
# the recency-aware detector (#1600) BOTH each run's timestamp and its preflight
# verdict so a stale pre-incident streak is not read as a live outage.
#   Echoes "SKIP"  when the workflow is absent (HTTP 404) — a stub is not counted
#          as failing just because it does not exist in this repo.
#   Echoes "STALE" when the workflow EXISTS (HTTP 200) but has no completed runs:
#          it is present-yet-unverified, so it must be reported STALE and counted
#          as inspected, NOT silently skipped like an absent stub — otherwise the
#          monitor falsely appears fully covered (#1601).
#   Echoes "ERROR" on any OTHER API failure (auth/rate-limit/5xx) or an unreadable
#          jobs API: such a query inspected nothing, and treating it as SKIP would
#          let a fleet-wide outage masquerade as a clean NONE all-clear (#1587).
#   Echoes "OK"    when <out_tsv> was populated with >=1 inspected run.
gather_runs_tsv() {
  local repo="$1" stub="$2" out="$3" lines errfile
  errfile=$(mktemp)
  if ! lines=$(gh api "repos/${repo}/actions/workflows/${stub}/runs?status=completed&per_page=${MAX_RUNS}" \
        --jq '.workflow_runs[] | [(.id|tostring), (.run_started_at // .created_at // "")] | @tsv' 2>"$errfile"); then
    if grep -qi 'HTTP 404' "$errfile"; then
      rm -f "$errfile"
      echo "SKIP"        # workflow absent in this repo — legitimately not counted
      return 0
    fi
    echo "::warning::engine-liveness: ${repo} / ${stub}: workflow-runs query failed with a non-404 API error (auth/rate-limit/5xx) — this stub could NOT be inspected: $(tr '\n' ' ' < "$errfile")" >&2
    rm -f "$errfile"
    echo "ERROR"         # blind spot — a NONE all-clear must not be trusted
    return 0
  fi
  rm -f "$errfile"
  # Workflow exists (200) but has no completed runs: present-yet-unverified. Report
  # STALE so it is counted/inspected rather than skipped as if absent (#1601).
  [[ -n "$lines" ]] || { echo "STALE"; return 0; }

  # The workflow-runs API orders by created_at desc, which is NOT guaranteed to be
  # run_started_at desc for delayed/queued runs. The detector treats row order as
  # recency order (most-recent first), so re-sort by the gathered timestamp
  # (run_started_at, created_at fallback — field 2) descending to make that
  # invariant hold; otherwise a delayed run mis-orders the streak/stale verdict
  # (#1601). ISO-8601 Z timestamps sort lexically == chronologically.
  lines=$(printf '%s\n' "$lines" | sort -t$'\t' -k2,2r)

  : > "$out"
  local rid iso verdict failed
  while IFS=$'\t' read -r rid iso; do
    [[ -n "$rid" ]] || continue
    verdict=$(run_failed_at_preflight "$repo" "$rid")
    if [[ "$verdict" = "unknown" ]]; then
      # The jobs API could not be read for this run — the streak would inspect
      # nothing reliable, so surface it as a blind spot rather than silently
      # reporting a trustworthy count (#1587).
      echo "ERROR"
      return 0
    fi
    failed="no"; [[ "$verdict" = "yes" ]] && failed="yes"
    printf '%s\t%s\n' "$iso" "$failed" >> "$out"
  done <<< "$lines"
  [[ -s "$out" ]] || { echo "SKIP"; return 0; }
  echo "OK"
}

# ---------------------------------------------------------------------------
# 2. Per-repo × per-stub inspection.
# ---------------------------------------------------------------------------
rows_file=$(mktemp) || { echo "mktemp failed" >&2; exit 1; }
runs_tsv=$(mktemp) || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -f "$rows_file" "$runs_tsv"' EXIT

sustained_repos=0   # repos with >=1 stub in a WITHIN-WINDOW OUTAGE (>=2 recent preflight failures)
failing_repos=0     # repos with >=1 stub failing at all in-window (FAIL or OUTAGE)
stale_repos=0       # repos whose worst stub is STALE — no run inside the lookback window (#1600)
inspected_stubs=0   # stubs actually inspected (a real runs answer, incl. empty)
api_errors=0        # non-404 API failures — queries that inspected nothing

mapfile -t REPOS < <(enumerate_repos)
echo "=== Engine-Token Liveness Monitor — #1587 / #1600 ==="
echo "  Date:         $TODAY"
echo "  Repos:        ${#REPOS[@]}"
echo "  Stubs:        $STUBS"
echo "  Runs/stub:    $MAX_RUNS"
echo "  Lookback:     ${LOOKBACK_DAYS} day(s) — runs older than this are ignored (#1600)"
echo ""

# repo_worst severity ranking: OK(0) < STALE(1) < FAIL(2) < OUTAGE(3). STALE is
# BELOW FAIL — it is unverified, not failing (#1600).
_worse() { # <current> <candidate> -> the more-severe of the two
  local -A rank=( [OK]=0 [STALE]=1 [FAIL]=2 [OUTAGE]=3 )
  if [ "${rank[$2]:-0}" -gt "${rank[$1]:-0}" ]; then echo "$2"; else echo "$1"; fi
}

for repo in "${REPOS[@]}"; do
  [[ -n "$repo" ]] || continue
  repo_worst="OK"
  for stub in $STUBS; do
    gather=$(gather_runs_tsv "$repo" "$stub" "$runs_tsv")
    [[ "$gather" = "SKIP" ]] && continue
    if [[ "$gather" = "ERROR" ]]; then
      api_errors=$(( api_errors + 1 ))
      echo "  ${repo} / ${stub}: ERROR (API query failed — stub not inspected)"
      continue
    fi
    if [[ "$gather" = "STALE" ]]; then
      # Workflow present but no completed runs — inspected yet unverified (#1601).
      inspected_stubs=$(( inspected_stubs + 1 ))
      printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$stub" "STALE" "0" "" >> "$rows_file"
      echo "  ${repo} / ${stub}: STALE (workflow exists but has no completed runs — unverified)"
      repo_worst=$(_worse "$repo_worst" "STALE")
      continue
    fi
    inspected_stubs=$(( inspected_stubs + 1 ))
    state=$(repo_liveness_from_runs "$runs_tsv" "$NOW_EPOCH" "$LOOKBACK_DAYS")
    consec=$(within_window_streak "$runs_tsv" "$NOW_EPOCH" "$LOOKBACK_DAYS")
    IFS=$'\t' read -r last_run _ < "$runs_tsv"
    printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$stub" "$state" "$consec" "$last_run" >> "$rows_file"
    echo "  ${repo} / ${stub}: ${state} (${consec} in-window preflight failure(s); last run ${last_run:-unknown})"
    repo_worst=$(_worse "$repo_worst" "$state")
  done
  case "$repo_worst" in
    OUTAGE) sustained_repos=$(( sustained_repos + 1 )); failing_repos=$(( failing_repos + 1 )) ;;
    FAIL)   failing_repos=$(( failing_repos + 1 )) ;;
    STALE)  stale_repos=$(( stale_repos + 1 )) ;;
  esac
done

escalation=$(fleet_escalation "$sustained_repos" "$failing_repos")
monitoring=$(monitoring_status "$inspected_stubs" "$api_errors")
should_fail="false"
if run_should_fail "$sustained_repos"; then should_fail="true"; fi
echo ""
echo "Inspected ${inspected_stubs} stub(s); API errors: ${api_errors}; sustained-outage repos: ${sustained_repos}; failing repos: ${failing_repos}; stale repos: ${stale_repos}."
echo "Escalation: ${escalation}; Monitoring: ${monitoring}; Should-fail: ${should_fail}"
if [[ "$monitoring" = "DEGRADED" ]]; then
  # 0 stubs inspected AND >=1 non-404 API error: the monitor learned nothing, so
  # the NONE escalation above is not a trustworthy all-clear (#1587).
  echo "::error::engine-liveness: monitoring DEGRADED — 0 stubs inspected and ${api_errors} non-404 API error(s) (auth/rate-limit/5xx). A '${escalation}' escalation is NOT a reliable all-clear; investigate GH_TOKEN scope/validity and GitHub API availability."
fi

# ---------------------------------------------------------------------------
# 3. GH_PAT_DON_PETRY scope/expiry (#1587 scope 4).
# ---------------------------------------------------------------------------
pat_scope_state="UNKNOWN"
pat_missing=""
pat_expiry="UNKNOWN"
pat_scopes_seen=""
pat_expiry_raw=""
if resp=$(gh api -i user 2>/dev/null); then
  # An ABSENT header here is a normal, expected condition — a fine-grained PAT or
  # a GitHub App token carries no `x-oauth-scopes`, and a never-expiring classic
  # PAT carries no `github-authentication-token-expiration`. Under `set -euo
  # pipefail` an unguarded `grep` that legitimately finds nothing exits 1, the
  # pipeline/assignment inherits it, and errexit kills the script BEFORE section 4
  # ever writes the report, the GITHUB_ENV flags, or the alert body (#1605). Guard
  # the extraction with `|| true` so a missing header yields empty — a
  # classification INPUT, not a fatal error.
  pat_scopes_seen=$(printf '%s\n' "$resp" | grep -im 1 '^x-oauth-scopes:' | cut -d: -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
  pat_expiry_raw=$(printf '%s\n' "$resp" | grep -im 1 '^github-authentication-token-expiration:' | cut -d: -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
  if [[ -z "$pat_scopes_seen" ]]; then
    # No x-oauth-scopes header: a fine-grained PAT or App token, whose access is
    # not expressible as classic oauth scopes. That is UNKNOWN (unclassifiable),
    # NOT a MISSING classic-scope failure — reporting a fine-grained token as
    # "missing repo workflow" would be a false alarm (#1605).
    pat_scope_state="UNKNOWN"
    pat_missing=""
  else
    pat_missing=$(pat_missing_scopes "$pat_scopes_seen" "$PAT_REQUIRED_SCOPES")
    if [[ -z "$pat_missing" ]]; then
      pat_scope_state="OK"
    else
      pat_scope_state="MISSING"
    fi
  fi
  pat_expiry=$(pat_expiry_state "$pat_expiry_raw" "$PAT_WARN_DAYS")
else
  echo "::warning::engine-liveness: could not read GH_PAT identity (gh api user) — PAT scope/expiry not evaluated"
fi
echo "  GH_PAT_DON_PETRY scopes: '${pat_scopes_seen:-<none/fine-grained>}' -> ${pat_scope_state}${pat_missing:+ (missing: ${pat_missing})}"
echo "  GH_PAT_DON_PETRY expiry: '${pat_expiry_raw:-<none>}' -> ${pat_expiry}"

# ---------------------------------------------------------------------------
# 4. Render report + fleet-alert body + GITHUB_ENV flags.
# ---------------------------------------------------------------------------
{
  printf '# Engine-Token Liveness — %s\n\n' "$TODAY"
  printf '**Escalation:** `%s` — %s\n\n' "$escalation" "$(escalation_headline "$escalation")"
  if [[ "$monitoring" = "DEGRADED" ]]; then
    printf '> **⚠️ Monitoring DEGRADED** — %s non-404 API error(s) and **0 stubs inspected**. The escalation above is **not** a reliable all-clear: an outage or auth failure can look like `NONE`. Investigate `GH_TOKEN` scope/validity and GitHub API availability (#1587).\n\n' "$api_errors"
  fi
  printf '**Repos monitored:** %s | **Stubs inspected:** %s | **API errors:** %s | **Sustained-outage repos:** %s | **Failing repos:** %s | **Stale repos:** %s\n\n' \
    "${#REPOS[@]}" "$inspected_stubs" "$api_errors" "$sustained_repos" "$failing_repos" "$stale_repos"
  printf '> **Recency window:** `%s` day(s) (`ENGINE_LIVENESS_LOOKBACK_DAYS`). A stub whose newest run predates this window is reported **STALE** (unverified) — a resolved pre-incident failure streak is not a live outage, and does not fail the run (#1600).\n\n' "$LOOKBACK_DAYS"
  printf '## Per-repo caller-stub preflight liveness\n\n'
  render_liveness_table "$rows_file"
  printf '\n## Credential — GH_PAT_DON_PETRY (#1587 scope 4)\n\n'
  printf '| Check | Value | State |\n|---|---|---|\n'
  printf '| Scopes | `%s` | %s |\n' "${pat_scopes_seen:-<none/fine-grained>}" "$pat_scope_state${pat_missing:+ (missing: ${pat_missing})}"
  printf '| Expiry | `%s` | %s |\n' "${pat_expiry_raw:-<none>}" "$pat_expiry"
} > "$REPORT_FILE"

[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"

# Fleet-alert body (only meaningful when escalation == FLEET; the workflow gates
# the actual issue create/update on ENGINE_LIVENESS_ESCALATION).
{
  printf '## %s\n\n' "$(escalation_headline "$escalation")"
  printf 'The engine-token preflight is failing on **>=%s consecutive runs in >=2 repos** — ' "$ENGINE_SUSTAINED_RUNS"
  printf 'the fleet-outage class from #1587. A job `success` conclusion elsewhere is **not** '
  printf 'evidence the engine is healthy. This is distinct from routine health-check output.\n\n'
  printf 'To pause deliberately, set `AGENTS_PAUSED=true` instead of withholding the secret '
  printf '(this monitor stays silent on a deliberate pause). Otherwise restore '
  printf '`CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`) in the affected repos/org.\n\n'
  render_liveness_table "$rows_file"
} > "$ALERT_BODY_FILE"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "ENGINE_LIVENESS_PAUSED=false"
    echo "ENGINE_LIVENESS_ESCALATION=${escalation}"
    echo "ENGINE_LIVENESS_MONITORING=${monitoring}"
    echo "ENGINE_LIVENESS_API_ERRORS=${api_errors}"
    echo "ENGINE_LIVENESS_SUSTAINED_REPOS=${sustained_repos}"
    echo "ENGINE_LIVENESS_FAILING_REPOS=${failing_repos}"
    echo "ENGINE_LIVENESS_STALE_REPOS=${stale_repos}"
    echo "ENGINE_LIVENESS_SHOULD_FAIL=${should_fail}"
    echo "ENGINE_LIVENESS_PAT_SCOPE_STATE=${pat_scope_state}"
    echo "ENGINE_LIVENESS_PAT_EXPIRY_STATE=${pat_expiry}"
  } >> "$GITHUB_ENV"
fi

echo ""
echo "Report written to ${REPORT_FILE} ($(wc -c < "$REPORT_FILE") bytes)"
echo "=== Engine-token liveness monitor complete ==="

# The wrapper itself always exits 0 once it has written the report, the alert body
# and the GITHUB_ENV flags. The workflow's final `always() && SHOULD_FAIL == 'true'`
# step owns the run's red/green decision, so the FLEET alert step (which lacks
# always()) stays reachable and the run's exit status tracks SHOULD_FAIL rather
# than an incidental abort (#1605). Never turn a normal classification outcome
# into a non-zero exit here.
exit 0
