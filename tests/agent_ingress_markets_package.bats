#!/usr/bin/env bats
# Regression test for the markets collapse package (#2038, ADR-0010): the §3
# `agent-ingress.yml` in docs/initiatives/agent-ingress-collapse-markets.md must
# pass BOTH ingress guards as rendered, so the package cannot drift back to a
# non-conforming concurrency block (run_id / inputs.* fallbacks, expression
# cancel-in-progress). The §3 YAML is extracted from the doc itself — the test
# reads the package, not a copy of it.
#
# The pinned reusables are resolved from trimmed snapshots
# (tests/fixtures/agent-ingress/markets-pinned-reusables/) via VCI_RESOLVE_DIR so
# the collision check is deterministic and offline. Changes to checked inputs or
# concurrency declarations behind channel refs are not fetched; refresh the
# snapshots to test those changes.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
PACKAGE="$SCRIPT_DIR/docs/initiatives/agent-ingress-collapse-markets.md"
SNAPSHOTS="$SCRIPT_DIR/tests/fixtures/agent-ingress/markets-pinned-reusables"

setup() {
  ROOT="$(mktemp -d)" || { echo "Failed to create temp dir" >&2; return 1; }
  mkdir -p "$ROOT/.github/workflows"
  INGRESS="$ROOT/.github/workflows/agent-ingress.yml"
  # The first ```yaml fence after the "## 3." heading is the §3 ingress.
  awk '
    /^## 3\./ { in3 = 1; next }
    in3 && /^## / { exit }
    in3 && !open && /^```yaml$/ { open = 1; next }
    open && /^```$/ { exit }
    open { print }
  ' "$PACKAGE" > "$INGRESS"
}

teardown() {
  rm -rf "$ROOT"
}

@test "markets §3: the ingress block is extracted and declares the five role jobs" {
  [ -s "$INGRESS" ]
  run yq -r '.jobs | keys | sort | join(",")' "$INGRESS"
  [ "$status" -eq 0 ]
  [ "$output" = "ci-failure-analyst,dev-lead,pr-auto-review,pr-review,pr-review-mention" ]
}

@test "markets §3: validate-ingress-if.sh passes (pure if:, bounded concurrency)" {
  VIIF_ROOT="$ROOT" run bash "$SCRIPT_DIR/scripts/validate-ingress-if.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ingress-if: OK"* ]]
}

@test "markets §3: every snapshot's recorded uses: target is still the ingress's pin (PINNED-USES)" {
  local uses rec n=0
  for rec in "$SNAPSHOTS"/*.yml; do
    uses="$(sed -n 's/^# PINNED-USES: //p' "$rec")"
    yq '.jobs[].uses' "$INGRESS" | grep -qxF "$uses"
    n=$((n + 1))
  done
  [ "$n" -ge 4 ]
}

@test "markets §3: each role job uses the target recorded in its own snapshot" {
  local expected
  expected="$(sed -n 's/^# PINNED-USES: //p' "$SNAPSHOTS/pr-auto-review-reusable.yml")"
  [ -n "$expected" ]
  [ "$(yq -r '.jobs["pr-auto-review"].uses' "$INGRESS")" = "$expected" ]

  expected="$(sed -n 's/^# PINNED-USES: //p' "$SNAPSHOTS/ci-failure-analyst-reusable.yml")"
  [ -n "$expected" ]
  [ "$(yq -r '.jobs["ci-failure-analyst"].uses' "$INGRESS")" = "$expected" ]
}

@test "markets §3: validate-caller-inputs.sh passes against the pinned reusables (no collision)" {
  VCI_ROOT="$ROOT" VCI_RESOLVE_DIR="$SNAPSHOTS" run bash "$SCRIPT_DIR/scripts/validate-caller-inputs.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pr-review' concurrency group does not collide"* ]]
  [[ "$output" == *"pr-auto-review' concurrency group does not collide"* ]]
  [[ "$output" == *"ci-failure-analyst' concurrency group does not collide"* ]]
}

@test "markets §3: every concurrency group is role-prefixed and every cancel-in-progress is a literal boolean" {
  source "$SCRIPT_DIR/scripts/validate-ingress-if.sh"
  local job group cancel stem n=0
  for job in pr-auto-review pr-review ci-failure-analyst; do
    IFS=$'\x1f' read -r group cancel < <(viif_job_concurrency "$INGRESS" "$job")
    [ -n "$group" ]
    [[ "$cancel" == "true" || "$cancel" == "false" ]]
    while IFS= read -r stem; do
      [[ "$stem" == "$job"-* ]]
      n=$((n + 1))
    done < <(viif_group_stems "$group")
  done
  [ "$n" -ge 3 ]
}

@test "markets §3: no group falls back to github.run_id or the inputs.* context" {
  run yq '.jobs[].concurrency.group // ""' "$INGRESS"
  [ "$status" -eq 0 ]
  [[ "$output" != *"run_id"* ]]
  # github.event.inputs.* is the workflow_dispatch payload; a bare inputs.* is not.
  ! printf '%s\n' "$output" | grep -Eq '(^|[^.[:alnum:]_])inputs\.'
}

@test "markets §3: pr-review's shared fallback slot is not the reusable's pr-review-batch" {
  # The collision check compares literal stems (a tripwire, ADR-0010). A caller
  # fallback of 'batch' would resolve to the reusable's own 'pr-review-batch'
  # group while passing the stem check, so pin the chosen literal here.
  run yq '.jobs["pr-review"].concurrency.group' "$INGRESS"
  [ "$status" -eq 0 ]
  [[ "$output" == pr-review-* ]]
  [[ "$output" != *"'batch'"* ]]
  # PR-identity branches must stay, in order, ahead of the 'enumerate' fallback.
  local re="pull_request\\.number.*check_suite\\.pull_requests\\[0\\]\\.number.*inputs\\.pr_url.*client_payload\\.pr_url.*'enumerate'"
  printf '%s' "$output" | tr '\n' ' ' | grep -Eq "$re"
}

@test "markets §3: pr-auto-review uses a per-event slot, not a shared per-SHA slot" {
  # The deployed markets ingress (#2171) gives each check_suite / workflow_run
  # its own slot so a run on a shared commit never cancels another PR's review
  # (the #1126 hazard). Pin the branch order and the absence of head_sha.
  run yq '.jobs["pr-auto-review"].concurrency.group' "$INGRESS"
  [ "$status" -eq 0 ]
  [[ "$output" == pr-auto-review-* ]]
  [[ "$output" != *"head_sha"* ]]
  # Tighten the assertion: verify || operators are present and in correct order.
  # This catches regressions like missing branches, wrong order, or invalid fallbacks.
  local normalized
  normalized=$(printf '%s' "$output" | tr '\n' ' ')
  # Exact pattern: pull_request.number || check_suite.id || workflow_run.id || 'none'
  [[ "$normalized" =~ pull_request\.number[^}]*\|\|[^}]*check_suite\.id[^}]*\|\|[^}]*workflow_run\.id[^}]*\|\|[^}]*\'none\' ]]
  # Also verify no run_id or head_sha crept in (beyond the above tests)
  [[ "$normalized" != *"run_id"* ]]
  run yq '.jobs["pr-auto-review"].concurrency["cancel-in-progress"]' "$INGRESS"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "markets §3: ci-failure-analyst concurrency is unchanged" {
  run yq -r '.jobs["ci-failure-analyst"].concurrency.group' "$INGRESS"
  [ "$output" = 'ci-failure-analyst-${{ github.event.check_run.head_sha }}' ]
  run yq '.jobs["ci-failure-analyst"].concurrency["cancel-in-progress"]' "$INGRESS"
  [ "$output" = "false" ]
}

@test "markets §3: ci-failure-analyst's self-exclusion prefix matches its real check run, and no DEFECTIVE PIN remains" {
  # The analyst's own check run is '<caller job key> / <reusable job id>'. The
  # old 'CI Failure Analyst' prefix never matched it (#2175), so the analyst
  # could re-trigger on its own failure.
  local job_id check_name prefix
  job_id="$(yq -r '.jobs | keys | .[0]' "$SNAPSHOTS/ci-failure-analyst-reusable.yml")"
  [ "$job_id" = "analyze" ]
  check_name="ci-failure-analyst / ${job_id}"
  prefix="$(yq -r '.jobs["ci-failure-analyst"].if' "$INGRESS" |
    sed -n "s/.*!startsWith(github\.event\.check_run\.name, '\([^']*\)').*/\1/p")"
  [ -n "$prefix" ]
  [[ "$check_name" == "$prefix"* ]]

  local fixture="$SCRIPT_DIR/tests/fixtures/agent-ingress/markets-agent-ingress.yml"
  [ -s "$fixture" ]
  # A mid-test `! cmd` does not trip errexit, so check each status explicitly.
  run grep -c 'DEFECTIVE PIN' "$fixture"
  [ "$status" -eq 1 ]
  [ "$output" -eq 0 ]
  run grep -c 'DEFECTIVE PIN' "$INGRESS"
  [ "$status" -eq 1 ]
  [ "$output" -eq 0 ]
}
