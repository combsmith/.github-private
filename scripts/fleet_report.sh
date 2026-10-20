#!/usr/bin/env bash
# fleet_report.sh — visualization and report generation for the Actions Fleet Monitor.
# Sourced by fleet_monitor.sh. All functions are pure (accept args / stdin; write stdout).
#
# Metrics TSV format (12 fields, tab-separated):
#   1:sort_key  2:repo  3:wf_file  4:total  5:success  6:failed
#   7:cancelled  8:rate_display  9:p50(s)  10:p95(s)  11:label  12:rate_int

# Gate workflows: their `failure` conclusion is intentional policy enforcement
# (e.g. blocking a PR that violates a rule), not flakiness or breakage. A high
# "failure rate" for these is the guard doing its job, so they are excluded from
# high-failure issue tracking to avoid false-positive Fleet Monitor trackers
# (#941). Matched by workflow file basename. See AGENTS.md "Exception:
# test-deletion-guard.yml". Override via env with the full space-separated
# gate list for testing; add permanent gates to the default below.
FLEET_GATE_WORKFLOWS="${FLEET_GATE_WORKFLOWS:-test-deletion-guard.yml holdout-guard.yml engine-config-validate.yml}"

# Dev-Lead status-marker prefix (#1019, story C of #901). Mirrors
# ISSUE_MARKER_PREFIX in dev-lead-fix-issue.sh / dev-lead-retry.sh: every
# dev-lead failure/retry/escalation posts an HTML-comment marker of the form
#   <!-- dev-lead-issue <N> status=<s> attempt=<k> reason=<r> run=<id> [reset=...] -->
# GitHub search cannot index HTML comments, so callers pass the repo's windowed
# issue comments (issues/comments?since=) and summarize_dev_lead_timeouts tallies
# the markers by their reason= field. Kept in one place so a rename in the
# dev-lead scripts is a one-line fix here.
DEV_LEAD_ISSUE_MARKER="${DEV_LEAD_ISSUE_MARKER:-<!-- dev-lead-issue }"

# Schedule-reliability tuning (#725, epic #722). Scheduled GitHub Actions runs
# are best-effort by design (#656): a tick can fire late or be dropped under
# load. SCHEDULE_TOLERANCE_TICKS absorbs a few late/boundary ticks so a
# late-but-present run is NOT scored as a miss; SCHEDULE_RELIABILITY_THRESHOLD
# is the hit-rate percent below which a workflow is surfaced as DEGRADED.
# A workflow with zero schedule-triggered runs against a non-trivial expected
# count is the silent-never-fired case this feature exists to expose (STALLED).
SCHEDULE_TOLERANCE_TICKS="${SCHEDULE_TOLERANCE_TICKS:-1}"
SCHEDULE_RELIABILITY_THRESHOLD="${SCHEDULE_RELIABILITY_THRESHOLD:-50}"

# count_cron_ticks <cron_expr> <start_epoch> <end_epoch>
# Counts how many times a single 5-field cron expression fires in the half-open
# window [start_epoch, end_epoch) (UTC). The actions/workflows API does not
# expose cron, so callers parse it from the workflow YAML (see extract_crons).
# Supports '*', ',', '-', and '/' in every field. Day-of-month / day-of-week
# follow the standard Vixie-cron rule: when BOTH are restricted the tick fires
# if EITHER matches; when one is '*' the other is ANDed. An empty or malformed
# expression yields 0 (tolerated as unknown, never fatal).
count_cron_ticks() {
  local cron="${1:-}" start="${2:-0}" end="${3:-0}"
  if [ -z "$cron" ]; then printf '0'; return 0; fi
  CRON="$cron" START="$start" END="$end" python3 -c '
import os, sys
from datetime import datetime, timezone

cron = os.environ.get("CRON", "").strip()
try:
    start = int(os.environ["START"]); end = int(os.environ["END"])
except (KeyError, ValueError):
    print(0); sys.exit(0)

fields = cron.split()
if len(fields) != 5:
    print(0); sys.exit(0)

def parse(spec, lo, hi):
    allowed = set()
    for term in spec.split(","):
        term = term.strip()
        if not term:
            return None
        step = 1
        if "/" in term:
            base, _, s = term.partition("/")
            try:
                step = int(s)
            except ValueError:
                return None
            if step <= 0:
                return None
        else:
            base = term
        if base == "*":
            a, b = lo, hi
        elif "-" in base:
            p, _, q = base.partition("-")
            try:
                a, b = int(p), int(q)
            except ValueError:
                return None
        else:
            try:
                a = b = int(base)
            except ValueError:
                return None
        v = a
        while v <= b:
            if lo <= v <= hi:
                allowed.add(v)
            v += step
    return allowed

mins  = parse(fields[0], 0, 59)
hours = parse(fields[1], 0, 23)
doms  = parse(fields[2], 1, 31)
mons  = parse(fields[3], 1, 12)
# Normalize day-of-week 7 -> 0 (both mean Sunday).
dows_raw = parse(fields[4], 0, 7)
if dows_raw is None:
    dows = None
else:
    dows = {0 if d == 7 else d for d in dows_raw}

if any(x is None for x in (mins, hours, doms, mons, dows)):
    print(0); sys.exit(0)

dom_restricted = fields[2].strip() != "*"
dow_restricted = fields[4].strip() != "*"

# Align to the first minute boundary at or after start.
t = start + ((60 - (start % 60)) % 60)
count = 0
while t < end:
    dt = datetime.fromtimestamp(t, tz=timezone.utc)
    if dt.minute in mins and dt.hour in hours and dt.month in mons:
        cron_dow = (dt.weekday() + 1) % 7  # Mon=0..Sun=6 -> Sun=0..Sat=6
        if dom_restricted and dow_restricted:
            day_ok = (dt.day in doms) or (cron_dow in dows)
        elif dom_restricted:
            day_ok = dt.day in doms
        elif dow_restricted:
            day_ok = cron_dow in dows
        else:
            day_ok = True
        if day_ok:
            count += 1
    t += 60
print(count)
'
}

# extract_crons  (reads workflow YAML on stdin)
# Prints each schedule.cron expression, one per line. The workflows API does not
# return cron, so it is parsed from the file content via text pattern matching
# (no third-party YAML parser required). Tolerates malformed or non-standard
# YAML — any parse failure prints nothing and exits 0 (recorded upstream as
# "no schedule / unknown").
extract_crons() {
  python3 -c '
import sys, re
content = sys.stdin.read()
for m in re.finditer(r"^\s*-\s+cron:\s*(.+)$", content, re.MULTILINE):
    v = m.group(1).strip()
    v = v.split(" #")[0].strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in (chr(34), chr(39)):
        v = v[1:-1]
    if v:
        print(v)
'
}

# workflow_expected_ticks <start_epoch> <end_epoch>  (reads workflow YAML stdin)
# Extracts every schedule.cron from the workflow YAML and sums the expected tick
# counts across all cron entries over [start, end). Multi-cron workflows are
# summed (each cron entry triggers its own run). Prints 0 for a workflow with no
# schedule trigger. A single Python invocation handles both cron extraction and
# tick counting to avoid O(N) process spawning per workflow.
workflow_expected_ticks() {
  local start="${1:-0}" end="${2:-0}"
  START="$start" END="$end" python3 -c '
import os, sys, re
from datetime import datetime, timezone

content = sys.stdin.read()

# Extract cron expressions via line-based parsing (no third-party YAML parser needed).
crons = []
for m in re.finditer(r"^\s*-\s+cron:\s*(.+)$", content, re.MULTILINE):
    v = m.group(1).strip()
    v = v.split(" #")[0].strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in (chr(34), chr(39)):
        v = v[1:-1]
    if v:
        crons.append(v)

if not crons:
    print(0); sys.exit(0)

try:
    start = int(os.environ.get("START", 0))
    end = int(os.environ.get("END", 0))
except ValueError:
    print(0); sys.exit(0)

def parse(spec, lo, hi):
    allowed = set()
    for term in spec.split(","):
        term = term.strip()
        if not term:
            return None
        step = 1
        if "/" in term:
            base, _, s = term.partition("/")
            try:
                step = int(s)
            except ValueError:
                return None
            if step <= 0:
                return None
        else:
            base = term
        if base == "*":
            a, b = lo, hi
        elif "-" in base:
            p, _, q = base.partition("-")
            try:
                a, b = int(p), int(q)
            except ValueError:
                return None
        else:
            try:
                a = b = int(base)
            except ValueError:
                return None
        v = a
        while v <= b:
            if lo <= v <= hi:
                allowed.add(v)
            v += step
    return allowed

total_ticks = 0
for cron in crons:
    fields = cron.split()
    if len(fields) != 5:
        continue
    mins  = parse(fields[0], 0, 59)
    hours = parse(fields[1], 0, 23)
    doms  = parse(fields[2], 1, 31)
    mons  = parse(fields[3], 1, 12)
    dows_raw = parse(fields[4], 0, 7)
    if dows_raw is None:
        continue
    dows = {0 if d == 7 else d for d in dows_raw}
    if any(x is None for x in (mins, hours, doms, mons, dows)):
        continue
    dom_restricted = fields[2].strip() != "*"
    dow_restricted = fields[4].strip() != "*"
    t = start + ((60 - (start % 60)) % 60)
    while t < end:
        dt = datetime.fromtimestamp(t, tz=timezone.utc)
        if dt.minute in mins and dt.hour in hours and dt.month in mons:
            cron_dow = (dt.weekday() + 1) % 7
            if dom_restricted and dow_restricted:
                day_ok = (dt.day in doms) or (cron_dow in dows)
            elif dom_restricted:
                day_ok = dt.day in doms
            elif dow_restricted:
                day_ok = cron_dow in dows
            else:
                day_ok = True
            if day_ok:
                total_ticks += 1
        t += 60
print(total_ticks)
'
}

# classify_schedule_reliability <expected> <actual> [tolerance] [threshold_pct]
# Classifies scheduled-run reliability and prints TSV:
#   <label> <TAB> <hit_rate_display> <TAB> <missed>
# where missed = max(0, expected - actual) and hit_rate is capped at 100%.
#   STALLED  — actual == 0 while a non-trivial number of ticks was expected
#              (a cron that silently never fired — the #725 core signal)
#   DEGRADED — actual materially below expected: missed exceeds the tolerance
#              AND hit rate is below the threshold
#   STABLE   — within tolerance, or hit rate at/above the threshold (not surfaced)
# expected <= 0 (no schedule) yields "STABLE n/a 0".
classify_schedule_reliability() {
  local expected="${1:-0}" actual="${2:-0}"
  local tol="${3:-$SCHEDULE_TOLERANCE_TICKS}"
  local thr="${4:-$SCHEDULE_RELIABILITY_THRESHOLD}"
  awk -v e="$expected" -v a="$actual" -v tol="$tol" -v thr="$thr" 'BEGIN {
    e += 0; a += 0; tol += 0; thr += 0
    if (e <= 0) { printf "STABLE\tn/a\t0"; exit }
    missed = e - a; if (missed < 0) missed = 0
    eff = missed - tol; if (eff < 0) eff = 0
    hr = a * 100.0 / e; if (hr > 100) hr = 100
    hr_disp = (hr == int(hr)) ? sprintf("%d%%", hr) : sprintf("%.1f%%", hr)
    if (eff == 0)        label = "STABLE"
    else if (a == 0)     label = "STALLED"
    else if (hr < thr)   label = "DEGRADED"
    else                 label = "STABLE"
    printf "%s\t%s\t%d\n", label, hr_disp, missed
  }'
}

# generate_schedule_reliability_report <schedule_metrics_file>
# Renders the Schedule Reliability section (#725) from a TSV file with one row
# per scheduled workflow:
#   repo <TAB> wf <TAB> expected <TAB> actual <TAB> hit_rate <TAB> missed <TAB> label
# Rows are sorted by severity (STALLED, then DEGRADED, then STABLE) so a silently
# stalled cron surfaces at the top, consistent with the high-failure tracking
# style. An empty or missing file prints nothing (section omitted when no
# scheduled workflows were seen).
generate_schedule_reliability_report() {
  local f="${1:-}"
  [ -n "$f" ] && [ -s "$f" ] || return 0
  printf '## Schedule Reliability\n\n'
  printf 'Expected cron ticks vs. actual `schedule`-triggered runs per scheduled workflow over the window. A cron that silently stopped firing shows as **STALLED** even when its last run "succeeded" — so a stalled backlog stops hiding behind a green check.\n\n'
  printf '| Repo | Workflow | Expected | Actual | Hit Rate | Missed | Status |\n'
  printf '|---|---|---|---|---|---|---|\n'
  awk 'BEGIN { FS = OFS = "\t" } {
    k = 3
    if ($7 == "STALLED")      k = 0
    else if ($7 == "DEGRADED") k = 1
    print k, $0
  }' "$f" | sort -t$'\t' -k1,1n -k2,2 -k3,3 | cut -f2- | \
  while IFS=$'\t' read -r repo wf expected actual hr missed label; do
    [ -n "$repo" ] || continue
    icon=$(label_to_icon "$label")
    printf '| `%s` | `%s` | %s | %s | %s | %s | %s %s |\n' \
      "$repo" "$wf" "$expected" "$actual" "$hr" "$missed" "$icon" "$label"
  done
  printf '\n'
  printf '_Scheduled runs are best-effort — GitHub may delay or drop ticks under load and only schedules crons on the **default branch**. A tolerance of %s tick(s) is applied so a late-but-present run is not scored as a miss, and only `schedule`-event runs are counted (workflow_dispatch / push / repository_dispatch excluded). Run queries are capped at 1000 results per window, so very high-volume workflows may under-report actual runs._\n' \
    "$SCHEDULE_TOLERANCE_TICKS"
}

# label_to_icon <label>
# Returns the health icon matching the scorecard legend.
label_to_icon() {
  case "$1" in
    CRITICAL) printf '🔴' ;;
    DEGRADED) printf '🟠' ;;
    WARNING)  printf '🟡' ;;
    HEALTHY)  printf '✅' ;;
    ERROR)    printf '⚫' ;;
    LOW-CONF) printf '🟡' ;;
    STALLED)  printf '🔴' ;;
    STABLE)   printf '✅' ;;
    *)        printf '⬜' ;;
  esac
}

# fmt_dur <seconds>
# Formats an integer number of seconds as "XmYs" or "Zs".
fmt_dur() {
  local s="${1:-0}"
  if [ "$s" -ge 60 ]; then
    printf '%dm%ds' $(( s / 60 )) $(( s % 60 ))
  else
    printf '%ds' "$s"
  fi
}

# generate_scorecard <metrics_file>
# Prints a one-line fleet health summary with counts per status.
generate_scorecard() {
  local f="$1"
  local critical degraded warning healthy
  critical=$(awk -F'\t' '$11 == "CRITICAL"' "$f" | wc -l | tr -d ' ')
  degraded=$(awk -F'\t' '$11 == "DEGRADED"' "$f" | wc -l | tr -d ' ')
  warning=$(awk -F'\t'  '$11 == "WARNING"'  "$f" | wc -l | tr -d ' ')
  healthy=$(awk -F'\t'  '$11 == "HEALTHY"'  "$f" | wc -l | tr -d ' ')
  printf '🔴 CRITICAL: %s  🟠 DEGRADED: %s  🟡 WARNING: %s  ✅ HEALTHY: %s\n' \
    "$critical" "$degraded" "$warning" "$healthy"
}

# apply_confidence_filter
# Reads metrics rows from stdin; re-labels CRITICAL rows with < 5 total runs
# as LOW-CONF and moves them to sort_key 5 (sorted after HEALTHY).
apply_confidence_filter() {
  awk 'BEGIN { FS=OFS="\t" } {
    if ($11 == "CRITICAL" && $4 + 0 < 5) { $1 = 5; $11 = "LOW-CONF" }
    print
  }'
}

# filter_high_failure <metrics_file>
# Reads a metrics TSV and prints fleet_high_failure JSON — the array of workflows
# worth tracking as a per-workflow issue:
#   * ERROR rows (the monitor could not read runs — always noteworthy)
#   * WARNING/DEGRADED/CRITICAL with exact failure rate > 10%
# CRITICAL rows with < 5 total runs are downgraded to LOW-CONF and dropped.
# Gate workflows (FLEET_GATE_WORKFLOWS, matched by basename) are excluded from
# the rate-based path — their failures are intentional policy enforcement (#941) —
# but a gate's ERROR row still surfaces (a read failure is not the gate's doing).
filter_high_failure() {
  local f="${1:-}"
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    echo "Error: metrics file '${f}' does not exist or is not specified" >&2
    return 1
  fi
  jq -Rn --arg gates "$FLEET_GATE_WORKFLOWS" '
    ($gates | split(" ") | map(select(length > 0))) as $gate |
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
    #   non-gate WARNING/DEGRADED/CRITICAL with exact failure rate > 10%
    #   (uses .failed/.total directly to avoid integer-truncation false negatives)
    map(select(
      .label == "ERROR" or
      (
        ((.workflow | split("/") | last | IN($gate[])) | not) and
        .label != "LOW-CONF" and
        (.label | IN("WARNING","DEGRADED","CRITICAL")) and
        .total > 0 and
        (.failed * 100.0 / .total > 10)
      )
    )) |
    sort_by(.failed * 100.0 / (if .total > 0 then .total else 1 end)) | reverse
  ' < "$f"
}

# summarize_dev_lead_timeouts <comments_json>
# Reads a JSON array of issue-comment objects ({body,...}) and tallies dev-lead
# status markers by failure reason. A stage timeout ("wall") is reason=timeout
# (Story B, #1018); generic engine failures are reason=engine-error. Emits TSV:
#   timeout <TAB> engine_error <TAB> total
# `total` is every dev-lead-issue marker in the window (all reasons; there is no
# success marker, so total == dev-lead failure/retry/escalation markers).
# Comments that merely mention `reason=` without the marker prefix are ignored.
# Absent/empty JSON → "0\t0\t0".
summarize_dev_lead_timeouts() {
  local json="${1:-}"
  [ -n "$json" ] || json='[]'
  printf '%s' "$json" | jq -r --arg p "$DEV_LEAD_ISSUE_MARKER" '
    [ .[]? | (.body // "") | select(contains($p))
      | (try (capture("reason=(?<r>[a-z]+(?:-[a-z]+)*)").r) catch "unknown") ] as $reasons
    | [ ([ $reasons[] | select(. == "timeout") ]      | length),
        ([ $reasons[] | select(. == "engine-error") ] | length),
        ($reasons | length) ]
    | @tsv'
}

# generate_dev_lead_timeout_report <reason_tsv_file>
# Renders the Dev-Lead timeout ("wall") observability section (#1019, story C of
# #901; prevalence rate #1030). Input is a TSV file with one row per repo that
# had >=1 dev-lead marker in the window:
#   `repo <TAB> timeout <TAB> engine_error <TAB> markers <TAB> total_runs`
# where `markers` is the count of all dev-lead failure/retry/escalation markers
# (the composition breakdown) and `total_runs` is the repo's total dev-lead.yml
# runs in the window (the prevalence denominator, from the fleet monitor's
# per-workflow metrics). Prints a per-repo table (raw timeout + engine-error
# counts retained), fleet totals, and the timeout **prevalence** rate
# (`reason=timeout` / total dev-lead runs — over ALL runs, not just failures) —
# the "wall rate" Story A/B aim to drive down. When total_runs is missing,
# non-numeric (e.g. an ERROR sentinel), or zero for a repo it is shown as `n/a`
# and contributes 0 to the denominator (no divide-by-zero). An empty or missing
# file prints nothing, so the section is omitted when there was no dev-lead
# activity in the window.
generate_dev_lead_timeout_report() {
  local f="${1:-}" fleet_runs="${2:-}"
  [ -n "$f" ] && [ -s "$f" ] || return 0
  # Prevalence denominator = ALL dev-lead runs fleet-wide (passed in by the
  # caller from the per-workflow metrics), NOT just runs from repos that happened
  # to have a marker. Summing only marker repos drops every all-success repo from
  # the denominator and inflates the rate — the exact flaw #1030 set out to fix.
  case "${fleet_runs:-}" in ''|*[!0-9]*) fleet_runs=0 ;; esac

  local repo t e tot runs runs_disp
  local sum_t=0 sum_e=0 sum_tot=0

  printf '## Dev-Lead Timeouts (walls)\n\n'
  printf 'Stage timeouts (`reason=timeout`) that escalate to a human, broken out from generic `engine-error`, over the window.\n\n'
  printf '| Repo | Timeouts | Engine-errors | Failure markers | Total runs |\n'
  printf '|---|---|---|---|---|\n'
  while IFS=$'\t' read -r repo t e tot runs; do
    [ -n "$repo" ] || continue
    # Sanitize total_runs: empty / non-numeric (ERROR sentinel '?') → 0 → n/a.
    case "${runs:-}" in
      ''|*[!0-9]*) runs=0 ;;
    esac
    runs_disp="n/a"
    [ "$runs" -gt 0 ] && runs_disp="$runs"
    printf '| `%s` | %s | %s | %s | %s |\n' "$repo" "$t" "$e" "$tot" "$runs_disp"
    sum_t=$(( sum_t + ${t:-0} ))
    sum_e=$(( sum_e + ${e:-0} ))
    sum_tot=$(( sum_tot + ${tot:-0} ))
  done < "$f"
  local runs_total_disp="n/a"
  [ "$fleet_runs" -gt 0 ] && runs_total_disp="$fleet_runs"
  printf '| **Fleet total** | **%s** | **%s** | **%s** | **%s** |\n\n' \
    "$sum_t" "$sum_e" "$sum_tot" "$runs_total_disp"
  printf '_Per-repo rows list only repos with >=1 dev-lead marker in the window; the **Total runs** fleet total (and the rate denominator) include **all** dev-lead runs fleet-wide, incl. all-success repos with no markers._\n\n'

  local rate
  rate=$(awk -v t="$sum_t" -v n="$fleet_runs" 'BEGIN {
    if (n <= 0) { print "n/a"; exit }
    pct = t * 100 / n
    printf (pct == int(pct)) ? "%d%%" : "%.1f%%", pct
  }')
  printf '**Timeout rate** (`reason=timeout` / total dev-lead runs fleet-wide — prevalence over all runs, not just failures): %s (%s / %s)\n' \
    "$rate" "$sum_t" "$runs_total_disp"
}

# detect_systemic_failures <metrics_file>
# Prints the name of each workflow file that has failures in 3 or more repos.
detect_systemic_failures() {
  local f="$1"
  awk -F'\t' '$6 > 0 { print $3 }' "$f" \
    | sort | uniq -c \
    | awk '$1 >= 3 { print $2 }'
}

# flag_duration_variance <p50> <p95>
# Prints ⚠️ when p95 > 5 × p50 and p50 >= 30s; otherwise prints nothing.
flag_duration_variance() {
  local p50="${1:-0}" p95="${2:-0}"
  if [ "$p50" -ge 30 ] && [ "$p95" -gt $(( p50 * 5 )) ]; then
    printf '⚠️'
  fi
}

# generate_ascii_bar <rate_int>
# Prints a 10-character block bar (0–100 → 0–10 filled blocks).
generate_ascii_bar() {
  local rate="${1:-0}"
  local filled=$(( rate / 10 ))
  local bar="" i
  for (( i = 0; i < filled; i++ ));        do bar="${bar}█"; done
  for (( i = 0; i < 10 - filled; i++ )); do bar="${bar}░"; done
  printf '%s' "$bar"
}

# generate_repo_rollup <metrics_file> [issues_file]
# Prints a markdown table with one row per repo: workflow count, total runs,
# total failures, open issue links, and worst status with health icon.
# Repos with no runs in the lookback window are omitted.
generate_repo_rollup() {
  local f="$1"
  local issues_file="${2:-}"
  printf '| Repo | Workflows | Total Runs | Failures | Issues | Worst Status |\n'
  printf '|---|---|---|---|---|---|\n'
  awk 'BEGIN { FS=OFS="\t" } {
    repo = $2
    seen[repo] = 1
    runs[repo]    += $4
    failed[repo]  += $6
    wf_ct[repo]++
    # Lower sort_key = worse status; track minimum
    if (!(repo in best_key) || $1 + 0 < best_key[repo] + 0) {
      best_key[repo]    = $1
      best_label[repo]  = $11
    }
  }
  END {
    for (repo in seen)
      if (runs[repo] + 0 > 0)
        printf "%s\t%s\t%s\t%s\t%s\n",
          repo, wf_ct[repo], runs[repo], failed[repo], best_label[repo]
  }' "$f" | sort -t$'\t' -k1,1 | \
  while IFS=$'\t' read -r repo wf_ct total_runs failed label; do
    local icon issues_links
    icon=$(label_to_icon "$label")
    issues_links=" "
    if [ -n "$issues_file" ] && [ -f "$issues_file" ] && [ -s "$issues_file" ]; then
      issues_links=$(awk -F'\t' -v r="$repo" \
        '$1 == r { printf "[#%s](%s) ", $4, $3 }' "$issues_file")
      issues_links="${issues_links% }"
    fi
    [ -z "$issues_links" ] && issues_links=" "
    printf '| `%s` %s | %s | %s | %s | %s | %s %s |\n' \
      "$repo" "$icon" "$wf_ct" "$total_runs" "$failed" "$issues_links" "$icon" "$label"
  done
}

# generate_mermaid_pie <metrics_file>
# Prints a Mermaid pie chart of workflow status distribution.
generate_mermaid_pie() {
  local f="$1"
  local critical degraded warning healthy
  critical=$(awk -F'\t' '$11 == "CRITICAL"' "$f" | wc -l | tr -d ' ')
  degraded=$(awk -F'\t' '$11 == "DEGRADED"' "$f" | wc -l | tr -d ' ')
  warning=$(awk -F'\t'  '$11 == "WARNING"'  "$f" | wc -l | tr -d ' ')
  healthy=$(awk -F'\t'  '$11 == "HEALTHY"'  "$f" | wc -l | tr -d ' ')
  printf '```mermaid\n'
  printf 'pie title Workflow Status Distribution\n'
  [ "$critical" -gt 0 ] && printf '  "CRITICAL" : %s\n' "$critical"
  [ "$degraded" -gt 0 ] && printf '  "DEGRADED" : %s\n' "$degraded"
  [ "$warning"  -gt 0 ] && printf '  "WARNING" : %s\n'  "$warning"
  [ "$healthy"  -gt 0 ] && printf '  "HEALTHY" : %s\n'  "$healthy"
  printf '```\n'
}

# generate_mermaid_bar <metrics_file>
# Prints a Mermaid xychart-beta bar chart for the top 10 failing workflows
# with at least 5 runs (excludes low-confidence single-run entries).
generate_mermaid_bar() {
  local f="$1"
  local min_runs=5
  local top10
  top10=$(awk -F'\t' -v min="$min_runs" '
    $11 != "HEALTHY" && $11 != "—" && $6 > 0 && $4 + 0 >= min {
      rate = $12 + 0
      # Strip org prefix for label brevity
      label = $2 "/" $3
      sub(/^[^/]+\//, "", label)
      printf "%s\t%s\n", rate, label
    }
  ' "$f" | sort -t$'\t' -k1,1rn | head -10)

  if [ -z "$top10" ]; then
    return
  fi

  local labels="" values=""
  while IFS=$'\t' read -r rate label; do
    labels="${labels}\"${label}\","
    values="${values}${rate},"
  done <<< "$top10"
  labels="${labels%,}"
  values="${values%,}"

  printf '```mermaid\n'
  printf 'xychart-beta\n'
  printf '  title "Top Failing Workflows (≥%s runs)"\n' "$min_runs"
  printf '  x-axis [%s]\n' "$labels"
  printf '  y-axis "Failure Rate %%" 0 --> 100\n'
  printf '  bar [%s]\n' "$values"
  printf '```\n'
}

# generate_report <metrics_file> <failed_file> <with_mermaid> [issues_file]
# Generates the complete fleet report. with_mermaid="true" includes Mermaid
# charts (suitable for GitHub Issues); "false" omits them (for Step Summary).
generate_report() {
  local metrics_file="$1"
  local failed_file="$2"
  local with_mermaid="${3:-false}"
  local issues_file="${4:-}"

  # Apply confidence filter and sort by severity
  local filtered
  filtered=$(mktemp)
  apply_confidence_filter < "$metrics_file" | sort -t$'\t' -k1,1n > "$filtered"

  # --- Scorecard ---
  printf '## Fleet Health\n\n'
  generate_scorecard "$filtered"
  printf '\n'

  # --- Mermaid pie (Issues only) ---
  if [ "$with_mermaid" = "true" ]; then
    generate_mermaid_pie "$filtered"
    printf '\n'
  fi

  # --- Systemic failures ---
  local systemic
  systemic=$(detect_systemic_failures "$filtered")
  if [ -n "$systemic" ]; then
    printf '## ⚠️ Systemic Issues\n\n'
    printf 'These workflow files are failing across multiple repos — fix the shared definition:\n\n'
    while IFS= read -r wf; do
      local count
      count=$(awk -F'\t' -v w="$wf" '$3 == w && $6 > 0' "$filtered" | wc -l | tr -d ' ')
      printf -- '- `%s` — failing in **%s** repos\n' "$wf" "$count"
    done <<< "$systemic"
    printf '\n'
  fi

  # --- Mermaid bar (Issues only) ---
  if [ "$with_mermaid" = "true" ]; then
    printf '## Top Failing Workflows\n\n'
    generate_mermaid_bar "$filtered"
    printf '\n'
  fi

  # --- Per-repo rollup ---
  printf '## Per-Repo Summary\n\n'
  generate_repo_rollup "$filtered" "$issues_file"
  printf '\n'

  # --- Fleet detail table ---
  printf '## Fleet Detail\n\n'
  printf '| Repo | Workflow | Issues | Total | ✅ | ❌ | ⚪ | Failure Rate | | p50 | p95 | Status |\n'
  printf '|---|---|---|---|---|---|---|---|---|---|---|---|\n'

  while IFS=$'\t' read -r _key repo wf_file total success failed cancelled \
                              rate_display p50 p95 label rate_int; do
    [ "$total" = "0" ] && continue
    local bar vflag icon issues_link
    bar=$(generate_ascii_bar "$rate_int")
    vflag=$(flag_duration_variance "$p50" "$p95")
    icon=$(label_to_icon "$label")
    issues_link=" "
    if [ -n "$issues_file" ] && [ -f "$issues_file" ] && [ -s "$issues_file" ]; then
      issues_link=$(awk -F'\t' -v r="$repo" -v w="$wf_file" \
        '$1 == r && $2 == w { printf "[#%s](%s)", $4, $3; exit }' "$issues_file")
    fi
    [ -z "$issues_link" ] && issues_link=" "
    printf '| `%s` %s | `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s%s | %s %s |\n' \
      "$repo" "$icon" "$wf_file" "$issues_link" "$total" "$success" "$failed" "$cancelled" \
      "$rate_display" "$bar" \
      "$(fmt_dur "$p50")" "$(fmt_dur "$p95")" "$vflag" "$icon" "$label"
  done < "$filtered"

  # --- Failed runs ---
  if [ -s "$failed_file" ]; then
    printf '\n## Failed Runs\n'
    cat "$failed_file"
  fi

  rm -f "$filtered"
}

# ---------------------------------------------------------------------------
# Persona opt-out label coverage / drift (#1644)
#
# Every persona advisory footer tells maintainers they can opt out with an
# `<id>:hands-off` label, and the mention router matches that label by EXACT
# name (persona-mention-reusable.yml `grep -qxF`). A label that does not exist
# can never match, so a missing opt-out reads silently as "not opted out" —
# fail-open by omission. This block lets the Fleet Monitor SURFACE that drift
# (a repo missing a persona opt-out label) instead of it being found by hand.
#
# All functions are PURE (args/stdin -> stdout; no network). Label fetching
# lives in fleet_monitor.sh. The opt-out family is DERIVED from the persona
# manifests, never enumerated: adding a persona directory adds its label
# automatically (#756's explicit constraint, #1644 AC #3).
#
# Drift TSV format (5 fields, tab-separated):
#   1:repo  2:status  3:present_count  4:total  5:missing_csv
# status ∈ { COMPLETE, INCOMPLETE }
#   COMPLETE   — repo carries every derived opt-out label
#   INCOMPLETE — missing one or more labels (the alertable signal, even if all are missing)

# derive_persona_optout_labels [personas_dir]
# Prints the derived <id>:hands-off family, one per line, sorted-unique, by
# reading `opt_out_label:` from every <personas_dir>/*/persona.yml. A missing
# dir, a missing manifest, or a manifest without the key contributes nothing
# (no crash) — the family is whatever the manifests currently declare.
derive_persona_optout_labels() {
  local dir="${1:-}"
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  local f val
  for f in "$dir"/*/persona.yml; do
    [ -f "$f" ] || continue
    val=$(sed -n 's/^[[:space:]]*opt_out_label:[[:space:]]*//p' "$f")
    val="${val%%$'\n'*}"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    [ -n "$val" ] && printf '%s\n' "$val"
  done | sort -u
}

# persona_optout_missing <expected_multiline> <actual_multiline>
# Prints the labels present in <expected> but absent from <actual>, sorted-unique.
# Both inputs are newline-separated label lists; blank lines are ignored.
persona_optout_missing() {
  local expected="${1:-}" actual="${2:-}"
  comm -23 \
    <(printf '%s\n' "$expected" | sed '/^$/d' | sort -u) \
    <(printf '%s\n' "$actual"   | sed '/^$/d' | sort -u)
}

# persona_optout_row <repo> <expected_multiline> <actual_multiline>
# Classifies one repo's opt-out coverage and emits one TSV row (see format above).
# Labels on the repo that are not part of the derived family are ignored.
persona_optout_row() {
  local repo="${1:-}" expected="${2:-}" actual="${3:-}"
  local total missing missing_ct present status missing_csv
  total=$(printf '%s\n' "$expected" | sed '/^$/d' | sort -u | grep -c . || true)
  missing=$(persona_optout_missing "$expected" "$actual")
  missing_ct=$(printf '%s' "$missing" | grep -c . || true)
  present=$(( total - missing_ct ))
  if [ "$missing_ct" -eq 0 ]; then
    status="COMPLETE"
  else
    status="INCOMPLETE"
  fi
  missing_csv=$(printf '%s' "$missing" | paste -sd, -)
  printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$status" "$present" "$total" "$missing_csv"
}

# generate_persona_optout_report <tsv_file> [total_expected]
# Renders the "Persona opt-out label coverage" section. Surfaces every INCOMPLETE
# repo (missing one or more derived labels). COMPLETE repos are counted only.
# An empty or missing file prints nothing (section omitted).
generate_persona_optout_report() {
  local f="${1:-}" total="${2:-}"
  [ -n "$f" ] && [ -s "$f" ] || return 0
  local complete incomplete
  complete=$(awk -F'\t' '$2 == "COMPLETE"'   "$f" | wc -l | tr -d ' ')
  incomplete=$(awk -F'\t' '$2 == "INCOMPLETE"' "$f" | wc -l | tr -d ' ')

  printf '## Persona opt-out label coverage\n\n'
  printf 'Every persona advisory tells maintainers they can opt out with `<id>:hands-off`, and the mention router matches that label by **exact name** — a label that does not exist can never match, so a missing opt-out reads silently as "not opted out" (fail-open by omission, #1644). The family is **derived** from `personas/*/persona.yml`, so a new persona is covered automatically.\n\n'
  printf '✅ COMPLETE: %s  🔴 INCOMPLETE: %s' \
    "$complete" "$incomplete"
  [ -n "$total" ] && printf '  ·  derived family size: %s' "$total"
  printf '\n\n'

  if [ "$incomplete" -eq 0 ]; then
    printf '_No persona opt-out drift — every enrolled repo carries the full derived family._\n'
    return 0
  fi

  printf 'These repos carry **some but not all** persona opt-out labels — the escape hatch is inert for the missing personas. Fan out the derived family:\n\n'
  printf '| Repo | Present | Missing opt-out labels |\n'
  printf '|---|---|---|\n'
  awk -F'\t' '$2 == "INCOMPLETE" {
    printf "| `%s` | %s/%s | `%s` |\n", $1, $3, $4, $5
  }' "$f"
}

# persona_optout_alert_json <tsv_file>
# Emits a JSON array of the INCOMPLETE repos (the alertable drift set), each with
# its missing labels, so a downstream step can route/track. Empty/absent → [].
persona_optout_alert_json() {
  local f="${1:-}"
  if [ -z "$f" ] || [ ! -s "$f" ]; then
    echo "[]"
    return 0
  fi
  jq -Rn '
    [ inputs
      | select(length > 0)
      | split("\t")
      | select(length >= 5 and .[1] == "INCOMPLETE")
      | { repo:    .[0],
          status:  .[1],
          present: (.[2] | tonumber? // 0),
          total:   (.[3] | tonumber? // 0),
          missing: (.[4] | split(",") | map(select(length > 0))) }
    ]' < "$f"
}

# generate_rate_limit_samples_report [jsonl_file...]
# Renders the "Unparsed rate-limit messages" section (#2140) from token-ledger
# JSONL files: every kind:"rate_limit_sample" record (one per message shape per
# run, already redacted and truncated by engine.sh) grouped by shape across runs,
# with an occurrence count, the first-seen time, and the earliest sample —
# HTML-escaped inside <pre> so a sample cannot break the rendered page. This is
# the real text the reset parser could not read, kept so a follow-up parser
# (e.g. the weekly cap, #1863) is built from it. Always renders: with no samples
# (or no files) it prints a "None" line. Malformed lines are skipped.
generate_rate_limit_samples_report() {
  local samples
  if [ $# -eq 0 ]; then
    printf '## Unparsed rate-limit messages\n\n'
    printf '_No ledger data available._\n'
    return 0
  fi

  samples=$(cat "$@" 2>/dev/null </dev/null | jq -cR '
    fromjson? | select(type == "object" and .kind == "rate_limit_sample"
                       and (.shape // "") != "" and (.sample // "") != "")' \
    | jq -cs '
    group_by(.shape)
    | map(sort_by(.ts // "") | {shape: .[0].shape, count: length,
                                first_seen: (.[0].ts // "unknown"),
                                sample: .[0].sample})
    | sort_by(.first_seen)' 2>/dev/null)
  [ -n "$samples" ] || samples='[]'

  printf '## Unparsed rate-limit messages\n\n'
  if [ "$samples" = "[]" ]; then
    printf '_No unparsed rate-limit samples were found in the available ledger data._\n'
    return 0
  fi
  printf '%s distinct message shape(s) the reset parser could not read (redacted, truncated):\n\n' \
    "$(jq 'length' <<< "$samples")"
  jq -r '.[:100] | .[] |
    "#### Shape `\(.shape)` — \(.count) occurrence(s), first seen \(.first_seen)\n\n<pre>\(
      .sample | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;"))</pre>\n"' \
    <<< "$samples"
}
