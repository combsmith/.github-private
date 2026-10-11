#!/usr/bin/env bash
# fleet-pause.sh — recognise a run that did no work because the agent fleet was
# paused (#2266, follow-up to #2249).
#
# With AGENTS_PAUSED=true every gated workflow skips its work job (AGENTS.md,
# "Pausing the agent fleet"). The variable's value when a run started is not in
# the Actions API afterwards, so a monitor reads what the run itself recorded:
#
#   * A workflow with a pause notice job (registry mode `job-gate`) runs its
#     `fleet-paused` job ONLY when the variable is true, so that job concluding
#     `success` is the record of the pause. The run as a whole ends `success`,
#     which is why a monitor that reads only the run conclusion counts it as
#     healthy.
#   * A workflow with no notice job (`job-gate-silent`: dev-lead, pr-review,
#     ci-failure-analyst, spec-drift) ends `skipped` with every job skipped. An
#     event filter ends a run the same way, so `skipped` alone is NOT a pause and
#     nothing in this file reports it as one.
#
# All functions are PURE: args / stdin -> stdout or exit status, no network.
# Network I/O lives in the callers (scripts/fleet_monitor.sh,
# scripts/initiative_canary.sh). Unit-tested in tests/test_fleet_paused_run.bats.

# The pause notice job's key in every `job-gate` workflow (#2249).
FLEET_PAUSED_JOB="${FLEET_PAUSED_JOB:-fleet-paused}"

# jq predicate shared by the REST and GraphQL readers: does a list of
# {name, conclusion} hold a notice job that concluded success? The jobs API names
# a reusable's job "<caller-key> / fleet-paused", so the last " / " segment is
# compared. REST answers `success` and GraphQL `SUCCESS`, hence ascii_downcase.
_FLEET_PAUSE_JQ='
  def notice_ran($job):
    any(.[]?;
        ((.name // "") | split(" / ") | last) == $job
        and ((.conclusion // "") | ascii_downcase) == "success");
'

# fleet_pause_notice_ran   (jobs JSON on stdin: [{name, conclusion}])
#   Exit 0 iff the run's pause notice job concluded success. Empty or unparseable
#   input is "not paused": a monitor that cannot read the jobs must fall back to
#   what it reported before, never invent a pause.
fleet_pause_notice_ran() {
  jq -e --arg job "$FLEET_PAUSED_JOB" "${_FLEET_PAUSE_JQ}"'
    (if type == "array" then . else [] end) | notice_ran($job)
  ' >/dev/null 2>&1
}

# fleet_pause_paused_run_nodes   (GraphQL `nodes` response on stdin)
#   Input : {data: {nodes: [{id, checkSuite: {checkRuns: {nodes: [{name,
#           conclusion}]}}}]}} — one node per workflow run. A node the API could
#           not resolve is null and is skipped.
#   Output: the node id of each run whose notice job concluded success, one per
#           line.
fleet_pause_paused_run_nodes() {
  jq -r --arg job "$FLEET_PAUSED_JOB" "${_FLEET_PAUSE_JQ}"'
    .data.nodes[]?
    | select(type == "object")
    | select((.checkSuite.checkRuns.nodes // []) | notice_ran($job))
    | .id // empty
  ' 2>/dev/null || true
}

# fleet_pause_drop_runs <paused_nodes_json>   (runs JSON on stdin)
#   Prints the runs whose `node_id` is NOT in the given JSON array of node ids.
#   A run with no `node_id` is always kept.
fleet_pause_drop_runs() {
  local paused="${1:-[]}"
  jq -c --argjson paused "$paused" '
    (if type == "array" then . else [] end)
    | map(select((.node_id // "") as $n | any($paused[]; . == $n) | not))
  '
}

# fleet_pause_notice_workflows [registry_tsv]
#   The workflow files that carry a notice job: the registry rows of mode
#   `job-gate`, one file name per line. A missing registry prints nothing.
fleet_pause_notice_workflows() {
  local registry="${1:-$(dirname "${BASH_SOURCE[0]}")/fleet-pause-registry.tsv}"
  [ -f "$registry" ] || return 0
  awk -F'\t' '!/^#/ && $2 == "job-gate" { print $1 }' "$registry"
}

# fleet_pause_workflow_has_notice [<notice-workflow>...]   (workflow YAML on stdin)
#   Exit 0 iff a run of this workflow can hold the notice job: the file declares a
#   `fleet-paused` job itself, or one of its jobs calls (`uses:`) one of the given
#   workflow files, by local path or by `owner/repo/...@ref`. Comment lines are
#   ignored. This only decides which workflows are worth a jobs read; whether a
#   run was paused is always decided by the job's own conclusion.
fleet_pause_workflow_has_notice() {
  awk -v job="$FLEET_PAUSED_JOB" -v names="$*" '
    BEGIN { n = split(names, want, " ") }
    /^[[:space:]]*#/ { next }
    $0 ~ ("^[[:space:]]+" job ":[[:space:]]*(#.*)?$") { found = 1 }
    /^[[:space:]]*(-[[:space:]]+)?uses:/ {
      ref = $0
      sub(/^[^:]*uses:[[:space:]]*/, "", ref)
      sub(/[[:space:]]+#.*$/, "", ref)
      gsub(/["\047[:space:]]/, "", ref)
      sub(/@.*$/, "", ref)
      for (i = 1; i <= n; i++) {
        suffix = "/.github/workflows/" want[i]
        if (length(ref) >= length(suffix) &&
            substr(ref, length(ref) - length(suffix) + 1) == suffix) found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

# generate_fleet_paused_report <paused_tsv>
#   Renders the "Fleet-paused runs" section from a TSV with one row per workflow
#   that had paused runs in the window:  repo <TAB> workflow <TAB> paused
#   An empty or missing file prints nothing (the section is omitted, which is the
#   normal case: no pause in the window). Pure: no network.
generate_fleet_paused_report() {
  local f="${1:-}"
  [ -n "$f" ] && [ -s "$f" ] || return 0
  printf '## Fleet-paused runs\n\n'
  printf 'Runs that did no work because the agent fleet was paused (`AGENTS_PAUSED=true`): their `%s` notice job ran. ' "$FLEET_PAUSED_JOB"
  printf 'They are counted here only. They are not in the totals, the success or failure counts, the failure rates or the durations above.\n\n'
  printf '| Repo | Workflow | Paused runs |\n'
  printf '|---|---|---:|\n'
  local repo wf paused
  sort -t$'\t' -k1,1 -k2,2 "$f" | while IFS=$'\t' read -r repo wf paused || [ -n "$repo" ]; do
    [ -n "$repo" ] || continue
    printf '| `%s` | `%s` | %s |\n' "$repo" "$wf" "$paused"
  done
  printf '\n'
  printf '_A paused run of a workflow with no notice job (dev-lead, pr-review, ci-failure-analyst, spec-drift) ends `skipped`, exactly like a run an event filter skipped. The two cannot be told apart afterwards, so it is not listed here; it stays in its workflow'"'"'s total as every skipped run does, and was never a success or a failure._\n'
}
