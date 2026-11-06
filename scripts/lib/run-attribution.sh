#!/usr/bin/env bash
# run-attribution.sh — pure run→role attribution for the collapsed agent-ingress
# (ADR-0007, epic #1723, story #1727).
#
# Phase 2 of the Class-1 caller collapse folds many per-role caller stubs into ONE
# agent-ingress.yml with one job per role (role-bearing job keys: dev-lead,
# pr-review-mention, …). The fleet monitor and pr-review health scans sample runs
# BY WORKFLOW NAME; once many workflow names collapse into one, every role lands in
# a single "agent-ingress" bucket — the ADR-0006-fact-3 attribution regression.
#
# These helpers retarget ingress runs to key on the role-bearing JOB name (via the
# jobs API), while legacy per-role workflows keep their workflow-name (basename)
# bucket. A role that ran both before AND after the collapse therefore lands in the
# SAME bucket (parity, AC #4). A run whose role cannot be named is bucketed under a
# loud UNATTRIBUTED sentinel rather than silently dropped (AC #5).
#
# All functions are PURE: args / stdin -> stdout, no network, no side effects.
# Network I/O lives in the wrappers that source this (scripts/fleet_monitor.sh,
# scripts/pr_review_health.sh). Unit-tested in tests/run_attribution.bats.
#
# Normalized bucket-input shape: JSON array of {role, conclusion}.
# Bucket TSV (5 fields): role <TAB> total <TAB> success <TAB> failed <TAB> cancelled

# The collapsed ingress workflow basename (ADR-0007). Overridable for tests/tools.
INGRESS_WORKFLOW_BASENAME="${INGRESS_WORKFLOW_BASENAME:-agent-ingress.yml}"

# Sentinel role for a run that ran but whose role could not be named — surfaced
# loudly so a broken attribution fails as visibly as a wrong bucket (AC #5).
UNATTRIBUTED_ROLE="__unattributed__"

# attribution_is_ingress <workflow_file>
#   Exit 0 iff the workflow file's basename is the collapsed ingress workflow.
attribution_is_ingress() {
  local wf="${1:-}"
  [[ -n "$wf" ]] || return 1
  [[ "${wf##*/}" = "$INGRESS_WORKFLOW_BASENAME" ]]
}

# attribution_role_from_workflow <workflow_file>   (legacy path, AC #3)
#   Role = basename minus a .yml/.yaml suffix. Pre-collapse, one workflow == one
#   role, so the workflow basename IS the role key.
attribution_role_from_workflow() {
  local wf="${1:-}" base
  base="${wf##*/}"
  base="${base%.yml}"
  base="${base%.yaml}"
  printf '%s\n' "$base"
}

# attribution_role_from_job <job_name>   (AC #2)
#   The jobs API prefixes a reusable-caller job's nested jobs with
#   "<caller-key> / <nested>"; the role token is the caller key (first segment
#   before the first " / "). An empty name yields the UNATTRIBUTED sentinel.
attribution_role_from_job() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    printf '%s\n' "$UNATTRIBUTED_ROLE"
    return 0
  fi
  printf '%s\n' "${name%% / *}"
}

# normalize_legacy_runs <workflow_file>   (runs JSON on stdin)
#   Maps each COMPLETED run to {role, conclusion}, where role is the workflow
#   basename (legacy keying). Runs with a null conclusion (still in flight) are
#   dropped, mirroring the fleet metrics loop.
normalize_legacy_runs() {
  local wf="${1:-}" role
  role="$(attribution_role_from_workflow "$wf")"
  jq -c --arg role "$role" '
    (if type == "array" then . else [] end)
    | map(select(.conclusion != null))
    | map({role: $role, conclusion: .conclusion})
  '
}

# normalize_ingress_runs   (per-run jobs JSON on stdin)
#   Input : JSON array of {run_id, jobs:[{name, conclusion}]}, one element per
#           ingress run (jobs as returned by the jobs API for that run).
#   Output: JSON array of {role, conclusion}, ONE record PER ROLE PER RUN.
#
#   Per-run reduction rules:
#     - role = caller key (segment before " / "); empty name -> UNATTRIBUTED.
#     - a role's several nested jobs collapse to ONE record (parity with a legacy
#       one-run-per-workflow count); failure precedence picks the worst outcome.
#     - a role whose only jobs are `skipped` (excluded by the if: event filter)
#       produces NO record — it did not run.
#     - a run with NO jobs at all yields ONE UNATTRIBUTED record, never vanishing
#       silently (AC #5).
normalize_ingress_runs() {
  jq -c --arg unattr "$UNATTRIBUTED_ROLE" '
    # rank: precedence for the ONE conclusion that represents a role within a run.
    # 0 == did-not-run (null/skipped), dropped later. Every OTHER completed
    # conclusion ranks > 0 so it is retained — legacy attribution keeps every
    # non-null run, so ingress must likewise keep neutral/stale/startup_failure
    # /unknown conclusions or its totals undercount runs legacy retains.
    def rank(c):
      if   c == "failure" or c == "timed_out" or c == "action_required" or c == "startup_failure" then 5
      elif c == "success"                                                                          then 4
      elif c == "cancelled"                                                                        then 3
      elif c == null or c == "skipped"                                                             then 0
      else 2 end;   # neutral/stale/other completed conclusion: retained, not dropped
    def role_of(name):
      if (name // "") == "" then $unattr
      else (name | split(" / ")[0]) end;

    (if type == "array" then . else [] end)
    | map(
        (.jobs // []) as $jobs
        | if ($jobs | length) == 0 then
            # completed run with no jobs -> loud UNATTRIBUTED, never dropped.
            [{role: $unattr, conclusion: "unknown"}]
          else
            $jobs
            | map({role: role_of(.name), conclusion: .conclusion, rank: rank(.conclusion)})
            | group_by(.role)
            | map(max_by(.rank))              # worst-outcome precedence per role
            | map(select(.rank > 0))          # all-skipped role did not run
            | map({role: .role, conclusion: .conclusion})
          end
      )
    | add // []
  '
}

# attribution_buckets   (normalized {role,conclusion} JSON on stdin)
#   Output: TSV, one row per role (sorted by role):
#     role <TAB> total <TAB> success <TAB> failed <TAB> cancelled
#   `failed` counts failure/timed_out/action_required; `total` counts every record
#   so nothing is silently dropped from the denominator.
attribution_buckets() {
  jq -r '
    (if type == "array" then . else [] end)
    | group_by(.role)
    | map({
        role:      .[0].role,
        total:     length,
        success:   (map(select(.conclusion == "success")) | length),
        failed:    (map(select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required")) | length),
        cancelled: (map(select(.conclusion == "cancelled")) | length)
      })
    | sort_by(.role)
    | .[]
    | [ .role,
        (.total     | tostring),
        (.success   | tostring),
        (.failed    | tostring),
        (.cancelled | tostring) ]
    | @tsv
  '
}

# attribution_role_present <buckets_tsv> <role>   (loud MISSING guard, AC #5)
#   Exit 0 iff a bucket for <role> exists in the TSV file. A silently absent role
#   is the regression this guard exists to catch.
attribution_role_present() {
  local tsv="${1:-}" role="${2:-}"
  [[ -n "$tsv" ]] && [[ -f "$tsv" ]] || return 1
  [[ -n "$role" ]] || return 1
  local first
  while IFS=$'\t' read -r first _; do
    [[ "$first" = "$role" ]] && return 0
  done < "$tsv"
  return 1
}

# generate_attribution_report <buckets_tsv> [heading]
#   Renders the per-role attribution buckets as a deterministic Markdown table.
#   An empty/missing file prints nothing (the section is omitted). An UNATTRIBUTED
#   bucket is surfaced loudly (AC #5). Pure: no network.
generate_attribution_report() {
  local tsv="${1:-}" heading="${2:-Run attribution by role}"
  [[ -n "$tsv" ]] && [[ -f "$tsv" ]] && [[ -s "$tsv" ]] || return 0

  printf '## %s\n\n' "$heading"
  printf 'Runs attributed to the role-bearing job (agent-ingress collapse, ADR-0007) '
  printf 'or the legacy per-role workflow — computed deterministically by '
  printf '`run-attribution.sh`, not the model.\n\n'
  printf '| Role | total | success | failed | cancelled |\n'
  printf '|---|---:|---:|---:|---:|\n'

  local role total success failed cancelled label
  while IFS=$'\t' read -r role total success failed cancelled; do
    [[ -n "$role" ]] || continue
    if [[ "$role" = "$UNATTRIBUTED_ROLE" ]]; then
      label='**⚠ UNATTRIBUTED**'
    else
      label="\`$role\`"
    fi
    printf '| %s | %s | %s | %s | %s |\n' \
      "$label" "$total" "$success" "$failed" "$cancelled"
  done < "$tsv"

  printf '\n'
}
