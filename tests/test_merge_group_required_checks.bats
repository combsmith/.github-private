#!/usr/bin/env bats
# Guard for #1871 (merge-queue prerequisite for #1864): every locally-owned
# required-status-check workflow must trigger on `merge_group`, or the merge
# queue would wedge — a queued PR stays BLOCKED on a required check that never
# reports on the queue's `gh-readonly-queue/*` ref.
#
# These tests pin the `merge_group` trigger onto three of the five required-check
# workflows: the locally-owned `SonarCloud`, `duplicate-decl-gate`, and advanced-setup
# `CodeQL` workflows. They assert that required-check context names are unchanged —
# a rename silently un-requires the check, because the ruleset matches by context
# name (AC #4). The two caller stubs (`agent-shield.yml`, `dependency-audit.yml`)
# are out of scope here; their `merge_group` wiring is tracked in petry-projects/.github#1157.
#
# The two thin caller stubs (agent-shield.yml, dependency-audit.yml) are out of
# scope here — they carry "You MUST NOT change: trigger events" and are tracked
# in petry-projects/.github#1157.
#
# Run with: bats tests/test_merge_group_required_checks.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  WORKFLOWS="$REPO_ROOT/.github/workflows"
}

# Helper: evaluate a python expression against a parsed workflow document.
# $1 = workflow file path, $2 = python expression referencing `on` and `jobs`.
# Prints the repr of the result so bats can assert on stdout.
# Requires PyYAML (hard requirement; fails with a clear error if missing).
_wf() {
  WF="$1" EXPR="$2" python3 - <<'PY'
import os, sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required to run these tests (pip install pyyaml)")

def parse_yaml(text):
    return yaml.safe_load(text)

with open(os.environ["WF"], encoding="utf-8") as fh:
    doc = parse_yaml(fh.read())

if not isinstance(doc, dict):
    raise TypeError(f"Expected YAML root to be a dict, got {type(doc).__name__}")

# PyYAML parses the bare `on:` key as the boolean True (YAML 1.1). Normalize.
on = doc.get("on", doc.get(True))
if on is None:
    raise KeyError("The 'on' trigger section is missing from the workflow file.")

jobs = doc.get("jobs", {}) or {}
print(eval(os.environ["EXPR"]))
PY
}

# ── SonarCloud (context: SonarCloud) ─────────────────────────────────────────

@test "sonarcloud.yml triggers on merge_group (AC1)" {
  run _wf "$WORKFLOWS/sonarcloud.yml" "'merge_group' in on"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "sonarcloud.yml keeps its existing push+pull_request triggers (AC1)" {
  run _wf "$WORKFLOWS/sonarcloud.yml" "'push' in on and 'pull_request' in on"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "sonarcloud.yml required-check context 'SonarCloud' is unchanged (AC4)" {
  run _wf "$WORKFLOWS/sonarcloud.yml" "jobs.get('sonarcloud', {}).get('name')"
  [ "$status" -eq 0 ]
  [ "$output" = "SonarCloud" ]
}

@test "sonarcloud.yml merge_group trigger is unfiltered (AC1)" {
  run _wf "$WORKFLOWS/sonarcloud.yml" "on.get('merge_group') is None"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

# ── duplicate-decl-gate (context: duplicate-decl-gate) ───────────────────────

@test "duplicate-decl-gate.yml triggers on merge_group (AC1)" {
  run _wf "$WORKFLOWS/duplicate-decl-gate.yml" "'merge_group' in on"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "duplicate-decl-gate.yml keeps its existing pull_request+push triggers (AC1)" {
  run _wf "$WORKFLOWS/duplicate-decl-gate.yml" "'pull_request' in on and 'push' in on"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "duplicate-decl-gate.yml required-check job id 'duplicate-decl-gate' is unchanged (AC4)" {
  # The effective check name is jobs['duplicate-decl-gate'].name when set, else
  # the job id. Assert it resolves to 'duplicate-decl-gate' so a future explicit
  # rename (which would silently un-require the check) is also caught.
  run _wf "$WORKFLOWS/duplicate-decl-gate.yml" "'duplicate-decl-gate' in jobs and jobs['duplicate-decl-gate'].get('name', 'duplicate-decl-gate') == 'duplicate-decl-gate'"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "duplicate-decl-gate.yml merge_group trigger is unfiltered (AC1)" {
  run _wf "$WORKFLOWS/duplicate-decl-gate.yml" "on.get('merge_group') is None"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

# ── CodeQL advanced setup (context: CodeQL) ──────────────────────────────────

@test "codeql.yml exists" {
  [ -f "$WORKFLOWS/codeql.yml" ]
}

@test "codeql.yml triggers on pull_request, push, and merge_group (AC2)" {
  run _wf "$WORKFLOWS/codeql.yml" "'pull_request' in on and 'push' in on and 'merge_group' in on"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "codeql.yml merge_group trigger is unfiltered (AC2)" {
  run _wf "$WORKFLOWS/codeql.yml" "on.get('merge_group') is None"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "codeql.yml push trigger is scoped to the main branch (AC2)" {
  run _wf "$WORKFLOWS/codeql.yml" "(on.get('push') or {}).get('branches', []) == ['main']"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "codeql.yml covers the actions and python languages (AC2)" {
  run _wf "$WORKFLOWS/codeql.yml" "'actions' in jobs.get('analyze', {}).get('strategy', {}).get('matrix', {}).get('language', []) and 'python' in jobs.get('analyze', {}).get('strategy', {}).get('matrix', {}).get('language', [])"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "codeql.yml uses the extended query suite (AC2)" {
  run _wf "$WORKFLOWS/codeql.yml" "any('security-extended' in str(step.get('with', {}).get('queries', '')) for step in jobs.get('analyze', {}).get('steps', []))"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

# The required-check context for code scanning is `CodeQL` (the code-scanning
# results check the analyze step uploads via SARIF), NOT the per-language job
# runs `Analyze (actions)` / `Analyze (python)`. Pin the analyze job name so a
# silent rename of the matrix job is caught structurally (AC4).
@test "codeql.yml analyze job name template is unchanged (AC4)" {
  run _wf "$WORKFLOWS/codeql.yml" "jobs.get('analyze', {}).get('name')"
  [ "$status" -eq 0 ]
  [ "$output" = 'Analyze (${{ matrix.language }})' ]
}

@test "codeql.yml has aggregation job named 'CodeQL' (AC4)" {
  # The effective check name is jobs['CodeQL'].name when set, else the job id.
  # Assert it resolves to 'CodeQL' so a future explicit rename is caught.
  run _wf "$WORKFLOWS/codeql.yml" "'CodeQL' in jobs and jobs['CodeQL'].get('name', 'CodeQL') == 'CodeQL'"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "codeql.yml CodeQL aggregation job requires analyze and always runs (AC4)" {
  run _wf "$WORKFLOWS/codeql.yml" "jobs.get('CodeQL', {}).get('needs') == 'analyze' and jobs.get('CodeQL', {}).get('if') == 'always()'"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

# Fail closed: a cancelled/skipped matrix completes no scan and must not report
# the required `CodeQL` check green. Execute the job's script for each result.
_codeql_agg_run() {
  local script
  script="$(_wf "$WORKFLOWS/codeql.yml" "jobs['CodeQL']['steps'][0]['run']")" || return 1
  [ -n "$script" ] || return 1
  ANALYZE_RESULT="$1" bash -c "$script"
}

@test "codeql.yml CodeQL aggregation job passes only on success (AC4)" {
  run _codeql_agg_run success
  [ "$status" -eq 0 ]
}

@test "codeql.yml CodeQL aggregation job fails for every non-success result (AC4)" {
  for r in failure cancelled skipped; do
    run _codeql_agg_run "$r"
    [ "$status" -ne 0 ]
  done
}

@test "codeql.yml CodeQL aggregation job reads needs.analyze.result via env (AC4)" {
  run _wf "$WORKFLOWS/codeql.yml" "jobs['CodeQL']['steps'][0]['env']['ANALYZE_RESULT']"
  [ "$status" -eq 0 ]
  [ "$output" = '${{ needs.analyze.result }}' ]
}

# SonarCloud must receive the short branch name, never a full refs/heads/ ref.
@test "sonarcloud.yml scan and retry steps never pass a refs/heads/ branch name (AC1)" {
  run _wf "$WORKFLOWS/sonarcloud.yml" "all('refs/heads/' not in str(s.get('with', {}).get('args', '')) and 'merge_group.base_ref' not in str(s.get('with', {}).get('args', '')) for s in jobs['sonarcloud']['steps'])"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

# Both scanner steps must actually consume the resolved branch output; without
# this the test above passes even if the branch argument is dropped entirely.
@test "sonarcloud.yml scan and retry steps both use the resolved branch output (AC1)" {
  run _wf "$WORKFLOWS/sonarcloud.yml" "[('-Dsonar.branch.name' in str(s['with']['args']) and 'steps.branch.outputs.name' in str(s['with']['args'])) for s in jobs['sonarcloud']['steps'] if 'sonarqube-scan-action' in str(s.get('uses', ''))]"
  [ "$status" -eq 0 ]
  [ "$output" = "[True, True]" ]
}

@test "sonarcloud.yml strips refs/heads/ in the branch-resolution step (AC1)" {
  run _wf "$WORKFLOWS/sonarcloud.yml" "any('#refs/heads/' in str(s.get('run', '')) for s in jobs['sonarcloud']['steps'] if s.get('id') == 'branch')"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}
