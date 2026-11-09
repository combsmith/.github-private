#!/usr/bin/env bash
# engine_liveness_detect.sh — the engine-token liveness DECISION layer (#1587).
#
# #1587: dev-lead failed 100% of runs across 8 repos for seven days — every run
# died at the "Engine token preflight" step with
# "CLAUDE_CODE_OAUTH_TOKEN is not provided to dev-lead-reusable." — and NOTHING
# escalated to a human. Two gaps let a total engine outage run silently:
#   1. a sustained fleet-wide preflight failure only accumulated in periodic
#      health reports instead of escalating differently from a flaky check;
#   2. pr-review had no preflight, so a tokenless run failed OPEN (exit success
#      having reviewed nothing) and its green conclusion was cited as "healthy".
#
# This is a set of PURE functions: given already-gathered run/step metadata,
# decide — per repo — whether the engine-token preflight is failing, and whether
# the aggregate warrants a FLEET-level alert (the outage class this monitor
# exists to catch) vs. ISOLATED single-repo health-check reporting vs. NONE. It
# also classifies a credential's scope/expiry (GH_PAT_DON_PETRY, a classic PAT
# whose silent rotation surfaces only as an opaque 401/403 on the next run). It
# NEVER touches the network or mutates anything — the gh/jq gathering and the
# alert/report side-effects are the caller's job (scripts/engine_liveness.sh).
#
# Escalation contract (issue scope 3), all keyed on the preflight step outcome:
#   AGENTS_PAUSED=true                               -> silent, no alert (caller)
#   >=2 consecutive preflight failures in >=2 repos  -> FLEET alert
#   otherwise any single-repo preflight failure      -> ISOLATED (routine report)

# The verbatim step name both dev-lead-reusable.yml and pr-review.yml carry. A
# run that fails HERE is the outage signature; a run that fails at a LATER step
# is a different problem this monitor does not own.
readonly ENGINE_PREFLIGHT_STEP_NAME="Engine token preflight"

# Sustained-failure threshold: a repo is in OUTAGE once its most-recent runs show
# this many consecutive preflight failures. Two = "not a one-off flake".
readonly ENGINE_SUSTAINED_RUNS=2

# Default recency window in days (#1600). A preflight-failure streak is only a
# LIVE outage if it is recent: a low-traffic repo whose last runs predate a
# resolved incident must not be reported as a sustained OUTAGE forever. Runs
# older than this window are ignored when computing the streak, and a repo whose
# newest run is older than the window is reported STALE (unverified), not OUTAGE.
# Callers override via ENGINE_LIVENESS_LOOKBACK_DAYS.
readonly ENGINE_LIVENESS_DEFAULT_LOOKBACK_DAYS=3

# _el_int <value> — echo a non-negative integer, or 0 for empty/non-numeric input.
# Keeps a bad metric from breaking the integer comparisons below.
_el_int() {
  case "${1:-}" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$1" ;;
  esac
}

# is_preflight_step <step_name>
#   Exit 0 when the step name is the engine-token preflight (substring match, so
#   the "(#1525)" suffix and any future annotation still match).
is_preflight_step() {
  case "${1:-}" in
    *"$ENGINE_PREFLIGHT_STEP_NAME"*) return 0 ;;
    *) return 1 ;;
  esac
}

# step_is_preflight_failure <step_name> <conclusion>
#   Exit 0 only when the preflight step itself concluded "failure" — the exact
#   outage signature. A failure at any OTHER step is deliberately NOT a preflight
#   failure (the monitor must not conflate an unrelated red run with a token
#   outage), and a passing preflight is never a failure.
step_is_preflight_failure() {
  is_preflight_step "${1:-}" || return 1
  [[ "${2:-}" = "failure" ]]
}

# repo_liveness_state <consecutive_preflight_failures> [newest_run_recent]
#   Classify one repo's caller-stub health from the number of consecutive
#   most-recent runs that failed at the preflight step WITHIN the lookback window,
#   plus whether the newest run is itself recent:
#     newest_run_recent != "yes" -> STALE  (no recent activity; unverified, #1600)
#     >=2 (and recent)           -> OUTAGE (sustained; the outage class)
#      1  (and recent)           -> FAIL   (a single most-recent failure; not yet sustained)
#      0  (and recent)           -> OK
#   newest_run_recent defaults to "yes" so the one-argument form keeps the
#   pre-#1600 (recency-unaware) contract for existing callers/tests.
repo_liveness_state() {
  local n newest
  n=$(_el_int "${1:-0}")
  newest="${2:-yes}"
  if [[ "$newest" != "yes" ]]; then
    echo "STALE"
  elif [ "$n" -ge "$ENGINE_SUSTAINED_RUNS" ]; then
    echo "OUTAGE"
  elif [ "$n" -ge 1 ]; then
    echo "FAIL"
  else
    echo "OK"
  fi
}

# within_lookback <run_epoch> <now_epoch> <lookback_days>
#   Exit 0 when a run's epoch-seconds timestamp falls INSIDE the recency window
#   (i.e. it is no older than <lookback_days> before <now_epoch>). The boundary is
#   inclusive: a run exactly <lookback_days> old is still within. Non-numeric or
#   empty inputs degrade to "outside" (non-zero) so a bad timestamp is treated as
#   not-recent rather than silently counted as live (#1600).
within_lookback() {
  local run now days cutoff
  run=$(_el_int "${1:-}")
  now=$(_el_int "${2:-}")
  days=$(_el_int "${3:-$ENGINE_LIVENESS_DEFAULT_LOOKBACK_DAYS}")
  [ "$days" -ge 1 ] || days=$ENGINE_LIVENESS_DEFAULT_LOOKBACK_DAYS
  [ "$run" -gt 0 ] || return 1
  [ "$now" -gt 0 ] || return 1
  cutoff=$(( now - days * 86400 ))
  [ "$run" -ge "$cutoff" ]
}

# newest_run_recent <runs_tsv_file> <now_epoch> <lookback_days>
#   Echo "yes" when the most-recent run (the first row) is within the lookback
#   window, else "no". An empty/missing file -> "no" (no recent activity). Rows
#   are "<run_iso> <TAB> <yes|no>", most-recent first.
newest_run_recent() {
  local f="${1:-}" now="${2:-}" days="${3:-}" iso epoch
  if [[ -z "$f" ]] || [[ ! -s "$f" ]]; then
    echo "no"
    return 0
  fi
  IFS=$'\t' read -r iso _ < "$f"
  epoch=$(_el_to_epoch "$iso")
  if within_lookback "$(_el_int "$epoch")" "$now" "$days"; then
    echo "yes"
  else
    echo "no"
  fi
}

# within_window_streak <runs_tsv_file> <now_epoch> <lookback_days>
#   Echo the number of leading (most-recent-first) runs that failed at the
#   preflight step AND fall inside the lookback window. The streak stops at the
#   first run that either did NOT fail at preflight OR is older than the window —
#   runs outside the window are IGNORED, never counted (#1600). Rows are
#   "<run_iso> <TAB> <yes|no>", most-recent first.
within_window_streak() {
  local f="${1:-}" now="${2:-}" days="${3:-}" streak=0 iso failed epoch
  { [[ -n "$f" ]] && [[ -s "$f" ]]; } || { echo 0; return 0; }
  while IFS=$'\t' read -r iso failed; do
    [[ -n "$iso" ]] || continue
    epoch=$(_el_to_epoch "$iso")
    within_lookback "$(_el_int "$epoch")" "$now" "$days" || break
    [[ "$failed" = "yes" ]] || break
    streak=$(( streak + 1 ))
  done < "$f"
  echo "$streak"
}

# repo_liveness_from_runs <runs_tsv_file> <now_epoch> <lookback_days>
#   The recency-aware per-repo classifier (#1600). Given a TSV of a stub's
#   most-recent completed runs — rows "<run_iso> <TAB> <yes|no>" (yes == the run
#   failed at the engine-token preflight step), most-recent first — decide the
#   repo's state, bounding the signal by BOTH streak and recency:
#     newest run older than the window (or no runs) -> STALE  (unverified)
#     >=2 consecutive preflight failures inside it  -> OUTAGE (live, sustained)
#      1 such failure                               -> FAIL
#      none                                         -> OK
repo_liveness_from_runs() {
  local f="${1:-}" now days streak recent
  now=$(_el_int "${2:-}")
  days=$(_el_int "${3:-$ENGINE_LIVENESS_DEFAULT_LOOKBACK_DAYS}")
  [ "$days" -ge 1 ] || days=$ENGINE_LIVENESS_DEFAULT_LOOKBACK_DAYS
  recent=$(newest_run_recent "$f" "$now" "$days")
  streak=$(within_window_streak "$f" "$now" "$days")
  repo_liveness_state "$streak" "$recent"
}

# run_should_fail <sustained_repo_count>
#   Exit 0 (the workflow SHOULD fail) only when at least one repo is in a
#   within-window OUTAGE — a genuine, live, sustained preflight failure. STALE
#   repos never contribute to the sustained count, so a repo whose only failures
#   predate the window does NOT fail the run (#1600). This keeps the #1587
#   "a real outage goes red" behaviour without letting resolved history stay red.
run_should_fail() {
  local sustained; sustained=$(_el_int "${1:-0}")
  [ "$sustained" -ge 1 ]
}

# fleet_escalation <sustained_repo_count> <any_failure_repo_count>
#   The fleet gate is about BREADTH, not depth: only a sustained (>=2 consecutive)
#   preflight failure across >=2 repos is the fleet outage class. One repo alone —
#   however many consecutive failures — is ISOLATED, routed to routine reporting.
#     sustained_repos >= 2 -> FLEET
#     else any_failure  >= 1 -> ISOLATED
#     else                    -> NONE
fleet_escalation() {
  local sustained any
  sustained=$(_el_int "${1:-0}")
  any=$(_el_int "${2:-0}")
  if [ "$sustained" -ge 2 ]; then
    echo "FLEET"
  elif [ "$any" -ge 1 ]; then
    echo "ISOLATED"
  else
    echo "NONE"
  fi
}

# monitoring_status <inspected_stubs> <api_errors>
#   Distinguish a genuine all-clear from a BLIND run. GitHub API errors on the
#   workflow-runs query are treated as SKIP by the gathering layer (a repo that
#   simply lacks a stub 404s), so an outage or auth failure that errors EVERY
#   query would otherwise surface as escalation=NONE with zero stubs inspected — a
#   false all-clear. When not a single stub could be inspected AND at least one
#   query failed with a non-404 API error, the monitor learned nothing:
#     inspected_stubs == 0 AND api_errors >= 1 -> DEGRADED (fail loud, not NONE)
#     else                                     -> OK
#   (#1587 — GitHub-API-error / false-all-clear defect.)
monitoring_status() {
  local inspected api_errors
  inspected=$(_el_int "${1:-0}")
  api_errors=$(_el_int "${2:-0}")
  if [ "$inspected" -eq 0 ] && [ "$api_errors" -ge 1 ]; then
    echo "DEGRADED"
  else
    echo "OK"
  fi
}

# escalation_headline <escalation>
#   One-line human summary for a level — reused in the step summary and the
#   fleet-alert issue body so both read consistently.
escalation_headline() {
  case "${1:-}" in
    FLEET)
      echo "FLEET-WIDE ENGINE-TOKEN OUTAGE — the preflight is failing on >=2 consecutive runs in >=2 repos (#1587)"
      ;;
    ISOLATED)
      echo "Isolated engine-token preflight failure — single-repo, routed to routine health-check reporting"
      ;;
    NONE)
      echo "All engine-token preflights healthy — no repo is failing at the preflight step"
      ;;
    *)
      echo "Engine-token liveness: unknown escalation state '${1:-}'"
      ;;
  esac
}

# _el_to_epoch <value>
#   Best-effort parse of space-separated UTC timestamp (YYYY-MM-DD HH:MM:SS) or
#   ISO 8601 (YYYY-MM-DDTHH:MM:SSZ) to epoch seconds. Returns empty on failure.
#   Portable across GNU/BSD date implementations (#1600).
_el_to_epoch() {
  local v="${1:-}" normalized
  [[ -n "$v" ]] || { echo ""; return 0; }
  # Normalize ISO 8601 to a space-separated form for the BSD fallback below.
  #
  # This MUST be anchored, not a blanket substitution: `${v//T/ }` also rewrites
  # the T inside a timezone name, so GitHub's PAT `expires_at` form
  # "2026-08-01 12:00:00 UTC" became "2026-08-01 12:00:00 U C" and stopped
  # parsing — pat_expiry_state then fell through to UNKNOWN and reported every
  # real expiry as unknown. Replace only the `T` that separates date from time,
  # and only a TRAILING `Z`.
  if [[ "$v" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2}.*)$ ]]; then
    normalized="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  else
    normalized="$v"
  fi
  normalized="${normalized%Z}"
  date -u -d "$normalized" +%s 2>/dev/null \
    || date -u -jf "%Y-%m-%d %H:%M:%S %Z" "$normalized" +%s 2>/dev/null \
    || date -u -jf "%Y-%m-%d %H:%M:%S" "$normalized" +%s 2>/dev/null \
    || echo ""
}

# pat_expiry_state <expiration_value> [warn_days] [now_epoch]
#   Classify a PAT's expiry from the value GitHub returns in the
#   `github-authentication-token-expiration` response header:
#     empty                       -> NO_EXPIRY  (a classic PAT set to never expire)
#     unparseable                 -> UNKNOWN
#     already past now            -> EXPIRED
#     within warn_days of now      -> EXPIRING
#     else                        -> OK
#   warn_days defaults to 14; now_epoch defaults to the current time (injectable
#   so the boundary is deterministically testable).
pat_expiry_state() {
  local value warn_days now exp
  value="${1:-}"
  warn_days=$(_el_int "${2:-14}")
  [ "$warn_days" -eq 0 ] && warn_days=14
  now="${3:-$(date -u +%s)}"

  if [[ -z "$value" ]]; then
    echo "NO_EXPIRY"
    return 0
  fi
  exp=$(_el_to_epoch "$value")
  if [[ -z "$exp" ]]; then
    echo "UNKNOWN"
    return 0
  fi
  if [ "$exp" -le "$now" ]; then
    echo "EXPIRED"
  elif [ "$exp" -le $(( now + warn_days * 86400 )) ]; then
    echo "EXPIRING"
  else
    echo "OK"
  fi
}

# pat_missing_scopes <scopes_csv> <required_scopes>
#   Echo (space-separated) the required scopes NOT present in <scopes_csv>. The
#   scopes string is the `x-oauth-scopes` header value ("repo, workflow, read:org");
#   required is a space-separated list. Exact-token match (no umbrella expansion).
#   Empty output means every required scope is present.
pat_missing_scopes() {
  local scopes_csv="${1:-}" required="${2:-}"
  # Normalise the CSV to space-delimited tokens for whole-word matching.
  local normalized=" ${scopes_csv//,/ } "
  local missing="" scope
  # Split into an array so a glob in the required override cannot trigger
  # pathname expansion (which could turn a token into repository paths).
  local -a required_scopes
  read -r -a required_scopes <<< "$required"
  for scope in "${required_scopes[@]}"; do
    case "$normalized" in
      *" $scope "*) : ;;
      *) missing="${missing:+$missing }$scope" ;;
    esac
  done
  printf '%s' "$missing"
}

# pat_scopes_ok <scopes_csv> <required_scopes>
#   Exit 0 when no required scope is missing, non-zero otherwise.
pat_scopes_ok() {
  local missing
  missing=$(pat_missing_scopes "$@")
  [[ -z "$missing" ]]
}

# render_liveness_table <rows_tsv_file>
#   Render the per-repo markdown table from a TSV whose rows are
#   repo <TAB> stub <TAB> state <TAB> consecutive_preflight_failures <TAB> last_run_iso.
#   The last-run timestamp lets a reader tell "healthy" from "not recently
#   exercised" (STALE) without opening Actions (#1600). last_run may be empty
#   (rendered as an em dash). An empty/missing file prints an explicit all-clear
#   line and no table, so a clean run still emits a signal.
render_liveness_table() {
  local f="${1:-}"
  if [[ -z "$f" ]] || [[ ! -s "$f" ]]; then
    printf 'No engine-token preflight failure detected across the monitored caller stubs.\n'
    return 0
  fi
  printf '| Repo | Stub | State | Consecutive preflight failures (in window) | Last run |\n'
  printf '|---|---|---|---|---|\n'
  local repo stub state consec last_run
  while IFS=$'\t' read -r repo stub state consec last_run; do
    [[ -n "$repo" ]] || continue
    printf '| %s | `%s` | %s | %s | %s |\n' "$repo" "$stub" "$state" "$consec" "${last_run:-—}"
  done < "$f"
}
