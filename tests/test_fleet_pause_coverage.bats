#!/usr/bin/env bats
# Fleet pause coverage (#2249): every model-calling workflow honours
# AGENTS_PAUSED, or is listed as deliberately not paused.
#
# The check itself is tests/dev-lead/integration/test_fleet_pause_coverage.py,
# which reads scripts/lib/fleet-pause-registry.tsv. This suite
#   • runs it on the live tree;
#   • asserts, for every gated job and step, that it is skipped when the variable
#     is `true` and runs when it is unset or `false`, and that the `fleet-paused`
#     notice job is the exact complement;
#   • executes each notice step and checks the one line it prints;
#   • proves the check fails under mutation: a gate removed or made bypassable, a
#     new model-calling workflow with no row, a second ungated model job, a notice
#     job lost or on different events, a bad registry row;
#   • keeps the AGENTS.md inventory table equal to the registry.
#
# Run: bats tests/test_fleet_pause_coverage.bats   (needs python3 + PyYAML)

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECK="$REPO_ROOT/tests/dev-lead/integration/test_fleet_pause_coverage.py"
REGISTRY_REL="scripts/lib/fleet-pause-registry.tsv"

# The workflows #2249 gated with a job condition and a `fleet-paused` notice job
# (dev-lead-reusable.yml was gated before, by #1525; spec-drift.yml is gated by
# #2249 with no notice job; daily-pr-review-health.yml is gated per step).
NEWLY_GATED=(
  pr-review.yml persona-runner-reusable.yml ci-failure-analyst-reusable.yml
  gh-aw-cross-org.yml issue-triage-runner.yml initiative-planner.yml idea-triage.yml
  dependency-advisory.yml docs-health-check.yml readme-refresh.yml
  release-notes.yml stale-manager.yml skill-eval-report.yml model-ab.yml
  dev-lead-retry.yml pr-review-sweep.yml
)

setup() {
  # PyYAML parses the workflows: skip locally without it, never silently in CI.
  if ! python3 -c 'import yaml' 2>/dev/null; then
    if [ -n "${CI:-}" ]; then
      echo "PyYAML is required in CI" >&2
      return 1
    fi
    skip "PyYAML not installed"
  fi
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/.github" "$TREE/scripts/lib"
  cp -R "$REPO_ROOT/.github/workflows" "$TREE/.github/workflows"
  cp "$REPO_ROOT/$REGISTRY_REL" "$TREE/$REGISTRY_REL"
  WF="$TREE/.github/workflows"
  REG="$TREE/$REGISTRY_REL"
}

check() { run python3 "$CHECK" --root "$TREE" "$@"; }

# add_row <workflow> <mode> <detail> <note>
add_row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$REG"; }

# drop_row <workflow>
drop_row() {
  grep -v "^$1	" "$REG" > "$REG.tmp"
  mv "$REG.tmp" "$REG"
}

# replace_in <file> <python-regex> <replacement> — exactly one substitution, or fail.
replace_in() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
path, pattern, repl = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
new, count = re.subn(pattern, repl, text, count=1, flags=re.M)
if count != 1:
    sys.exit(f"replace_in: pattern not found in {path}: {pattern}")
open(path, "w", encoding="utf-8").write(new)
PY
}

# notice_script <workflow> — the `run:` of the fleet-paused job's notice step.
notice_script() {
  python3 - "$REPO_ROOT/.github/workflows/$1" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = doc["jobs"]["fleet-paused"]["steps"]
print(steps[0]["run"])
PY
}

# ── the live tree ────────────────────────────────────────────────────────────

@test "live tree: every model-calling workflow honours AGENTS_PAUSED or is listed" {
  run python3 "$CHECK" --root "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: every model-calling workflow honours AGENTS_PAUSED or is listed"* ]]
}

@test "live tree: the one workflow that is not paused is reported, not hidden" {
  run python3 "$CHECK" --root "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^NOT PAUSED: ' <<< "$output")" -eq 1 ]
  [[ "$output" == *"NOT PAUSED: feature-ideation.yml (model call in petry-projects/.github/.github/workflows/feature-ideation-reusable.yml)"* ]]
}

@test "registry: each workflow #2249 gated has a job-gate row" {
  local wf
  for wf in "${NEWLY_GATED[@]}"; do
    grep -q "^${wf}	job-gate	" "$REPO_ROOT/$REGISTRY_REL" || { echo "no job-gate row for $wf"; return 1; }
  done
  grep -q "^daily-pr-review-health.yml	step-gate	" "$REPO_ROOT/$REGISTRY_REL"
  grep -q "^dev-lead-reusable.yml	job-gate-silent	dispatch,ci-relay,resume	" "$REPO_ROOT/$REGISTRY_REL"
  grep -q "^spec-drift.yml	job-gate-silent	spec-drift	" "$REPO_ROOT/$REGISTRY_REL"
}

# ── skipped when true, runs when unset or false (AC 2, AC 3) ─────────────────

@test "truth table: every gated job and step is skipped for true/TRUE and runs for unset/false" {
  run python3 "$CHECK" --root "$REPO_ROOT" --table
  [ "$status" -eq 0 ]
  local rows wf job value outcome want n=0
  rows="$(grep -c "	" <<< "$output")"
  [ "$rows" -gt 0 ]
  while IFS=$'\t' read -r wf job value outcome; do
    [ -n "$outcome" ] || continue
    case "$value" in
      true|TRUE) want=skipped ;;
      unset|false) want=runs ;;
      *) echo "unexpected value '$value'"; return 1 ;;
    esac
    # The notice job is the complement of the job it speaks for.
    if [ "$job" = "fleet-paused" ]; then
      if [ "$want" = skipped ]; then want=runs; else want=skipped; fi
    fi
    [ "$outcome" = "$want" ] || { echo "$wf $job AGENTS_PAUSED=$value: $outcome, want $want"; return 1; }
    n=$((n + 1))
  done <<< "$output"
  [ "$n" -eq "$rows" ]
}

@test "truth table: covers the model job and the notice job of each workflow #2249 gated" {
  run python3 "$CHECK" --root "$REPO_ROOT" --table
  [ "$status" -eq 0 ]
  local wf
  for wf in "${NEWLY_GATED[@]}"; do
    # 4 values for the gated job + 4 for fleet-paused.
    [ "$(grep -c "^${wf}	" <<< "$output")" -eq 8 ] || { echo "$wf: expected 8 table rows"; return 1; }
    grep -q "^${wf}	fleet-paused	true	runs$" <<< "$output"
    grep -q "^${wf}	fleet-paused	unset	skipped$" <<< "$output"
  done
  grep -q "^daily-pr-review-health.yml	health-check/Run health check	true	skipped$" <<< "$output"
  grep -q "^daily-pr-review-health.yml	health-check/Assert MCP connectivity	false	runs$" <<< "$output"
  # dev-lead keeps its three #1525 gates and has no notice job; nor has spec-drift.
  [ "$(grep -c "^dev-lead-reusable.yml	" <<< "$output")" -eq 12 ]
  [ "$(grep -c "^spec-drift.yml	spec-drift	" <<< "$output")" -eq 4 ]
  grep -q "^spec-drift.yml	spec-drift	true	skipped$" <<< "$output"
  grep -q "^spec-drift.yml	spec-drift	unset	runs$" <<< "$output"
  run grep -E "^(dev-lead-reusable|spec-drift).yml	fleet-paused	" <<< "$output"
  [ "$status" -eq 1 ]
}

# ── the log line a paused run prints ─────────────────────────────────────────

@test "notice: each fleet-paused job prints one ::notice line naming source and until" {
  local wf script
  for wf in "${NEWLY_GATED[@]}"; do
    script="$(notice_script "$wf")"
    PAUSE_SOURCE=rate-limit-observed PAUSE_UNTIL=2026-10-13T16:00:00Z run bash -c "$script"
    [ "$status" -eq 0 ] || { echo "$wf: notice step failed"; return 1; }
    [ "${#lines[@]}" -eq 1 ] || { echo "$wf: expected one line, got ${#lines[@]}"; return 1; }
    [[ "$output" == "::notice title=Agent fleet paused::"*"the agent fleet is paused (AGENTS_PAUSED=true)."* ]]
    [[ "$output" == *"Pause source: rate-limit-observed. Paused until: 2026-10-13T16:00:00Z." ]]
  done
}

@test "notice: an unset source and until time read as not set (a pause set by hand)" {
  local wf script
  for wf in pr-review.yml dev-lead-retry.yml; do
    script="$(notice_script "$wf")"
    PAUSE_SOURCE='' PAUSE_UNTIL='' run bash -c "$script"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == *"Pause source: not set (paused by hand). Paused until: not set." ]]
  done
}

# ── mutation: a gate removed or made bypassable ──────────────────────────────

@test "mutation: removing the gate from pr-review's review job fails" {
  replace_in "$WF/pr-review.yml" "^      vars\.AGENTS_PAUSED != 'true' &&\n" ""
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"pr-review.yml: job 'review' is not paused by AGENTS_PAUSED"* ]]
}

@test "mutation: neutralising the gate fails, for every job-gate workflow in the registry" {
  local wf jobs job n=0
  while IFS=$'\t' read -r wf jobs; do
    job="${jobs%%,*}"
    # The first `vars.AGENTS_PAUSED != 'true'` in the file is that job's gate.
    replace_in "$WF/$wf" "vars\.AGENTS_PAUSED != 'true'" "true"
    check
    [ "$status" -eq 1 ] || { echo "$wf: a neutralised gate was not detected"; return 1; }
    [[ "$output" == *"$wf: job '$job' is not paused by AGENTS_PAUSED"* ]] || { echo "$wf: wrong message: $output"; return 1; }
    cp "$REPO_ROOT/.github/workflows/$wf" "$WF/$wf"
    n=$((n + 1))
  done < <(awk -F'\t' '$2 == "job-gate" { print $1 "\t" $3 }' "$REPO_ROOT/$REGISTRY_REL")
  [ "$n" -eq "${#NEWLY_GATED[@]}" ]
  check
  [ "$status" -eq 0 ]
}

@test "mutation: removing one of dev-lead's three gates fails" {
  replace_in "$WF/dev-lead-reusable.yml" "      vars\.AGENTS_PAUSED != 'true' &&\n      github\.event_name == 'check_run' &&" "      github.event_name == 'check_run' &&"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"dev-lead-reusable.yml: job 'ci-relay' is not paused by AGENTS_PAUSED"* ]]
}

@test "mutation: removing the gate from spec-drift (gated, no notice job) fails" {
  replace_in "$WF/spec-drift.yml" "^      vars\\.AGENTS_PAUSED != 'true' &&\\n" ""
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"spec-drift.yml: job 'spec-drift' is not paused by AGENTS_PAUSED"* ]]
}

@test "mutation: a gate that a top-level || can bypass fails" {
  replace_in "$WF/stale-manager.yml" "^    if: vars\.AGENTS_PAUSED != 'true'\$" "    if: vars.AGENTS_PAUSED != 'true' && github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale-manager.yml: job 'stale' is not paused by AGENTS_PAUSED"* ]]
  [[ "$output" == *"top-level \`||\`"* ]]
}

@test "mutation: a gate that is not the first term fails; the same || inside parentheses passes" {
  replace_in "$WF/stale-manager.yml" "^    if: vars\.AGENTS_PAUSED != 'true'\$" "    if: github.event_name == 'schedule' || vars.AGENTS_PAUSED != 'true'"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale-manager.yml: job 'stale' is not paused by AGENTS_PAUSED"* ]]

  cp "$REPO_ROOT/.github/workflows/stale-manager.yml" "$WF/stale-manager.yml"
  replace_in "$WF/stale-manager.yml" "^    if: vars\.AGENTS_PAUSED != 'true'\$" "    if: vars.AGENTS_PAUSED != 'true' && (github.event_name == 'schedule' || github.event_name == 'workflow_dispatch')"
  replace_in "$WF/stale-manager.yml" "^    if: vars\.AGENTS_PAUSED == 'true'\$" "    if: vars.AGENTS_PAUSED == 'true' && (github.event_name == 'schedule' || github.event_name == 'workflow_dispatch')"
  check
  [ "$status" -eq 0 ]
}

@test "mutation: removing the gate from a gated step fails" {
  replace_in "$WF/daily-pr-review-health.yml" "vars\.AGENTS_PAUSED != 'true' && hashFiles" "hashFiles"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"daily-pr-review-health.yml: step 'Assert MCP connectivity' is not paused by AGENTS_PAUSED"* ]]
}

# ── mutation: a new model-calling workflow ───────────────────────────────────

@test "mutation: a new workflow holding a model credential, with no gate and no row, fails" {
  cat > "$WF/new-agent.yml" <<'YAML'
name: New Agent
on:
  workflow_dispatch:
permissions: {}
jobs:
  think:
    runs-on: ubuntu-latest
    env:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    steps:
      - run: bash scripts/some-new-agent.sh
YAML
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"new-agent.yml can reach a model (job 'think': model credential) but has no row in scripts/lib/fleet-pause-registry.tsv"* ]]
}

@test "mutation: a new workflow that only installs an AI CLI, or uses the Claude action, fails" {
  cat > "$WF/new-cli.yml" <<'YAML'
name: New CLI
on:
  workflow_dispatch:
jobs:
  go:
    runs-on: ubuntu-latest
    steps:
      - run: npm install -g @google/gemini-cli && gemini -p hello
YAML
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"new-cli.yml can reach a model (job 'go': AI CLI or action)"* ]]
  rm "$WF/new-cli.yml"

  cat > "$WF/new-action.yml" <<'YAML'
name: New Action
on:
  workflow_dispatch:
jobs:
  go:
    runs-on: ubuntu-latest
    steps:
      - uses: anthropics/claude-code-action@v1
        with:
          prompt: hello
YAML
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"new-action.yml can reach a model (job 'go': AI CLI or action)"* ]]
}

@test "mutation: a new caller that hands every secret to a reusable fails" {
  cat > "$WF/new-caller.yml" <<'YAML'
name: New Caller
on:
  workflow_dispatch:
jobs:
  call:
    uses: some-org/some-repo/.github/workflows/agent-reusable.yml@v1
    secrets: inherit
YAML
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"new-caller.yml can reach a model (job 'call': reusable call with secrets: inherit)"* ]]
}

@test "mutation: a credential in the workflow-level env counts for every job" {
  cat > "$WF/new-env.yml" <<'YAML'
name: New Env
on:
  workflow_dispatch:
env:
  GEMINI_API_KEY: ${{ secrets.GOOGLE_API_KEY }}
jobs:
  go:
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/whatever.sh
YAML
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"new-env.yml can reach a model (job 'go': model credential in workflow env)"* ]]
}

@test "a new workflow that makes no model call needs no row, and a comment is not a call" {
  cat > "$WF/new-linter.yml" <<'YAML'
# Not an agent: holds no CLAUDE_CODE_OAUTH_TOKEN and installs no @anthropic-ai/claude-code.
name: New Linter
on:
  pull_request:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: shellcheck scripts/*.sh  # no gh copilot here
YAML
  check
  [ "$status" -eq 0 ]
}

@test "a new model-calling workflow passes once gated and registered, or exempt with a reason" {
  cat > "$WF/new-agent.yml" <<'YAML'
name: New Agent
on:
  workflow_dispatch:
jobs:
  think:
    if: vars.AGENTS_PAUSED != 'true'
    runs-on: ubuntu-latest
    env:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    steps:
      - run: bash scripts/some-new-agent.sh
  fleet-paused:
    if: vars.AGENTS_PAUSED == 'true'
    runs-on: ubuntu-latest
    env:
      PAUSE_SOURCE: ${{ vars.AGENTS_PAUSE_SOURCE }}
      PAUSE_UNTIL: ${{ vars.AGENTS_PAUSE_UNTIL }}
    steps:
      - run: echo "::notice::paused ${PAUSE_SOURCE} ${PAUSE_UNTIL}"
YAML
  add_row new-agent.yml job-gate think -
  check
  [ "$status" -eq 0 ]

  drop_row new-agent.yml
  add_row new-agent.yml exempt - "Must run through a pause because it is the only thing that can lift one."
  check
  [ "$status" -eq 0 ]

  drop_row new-agent.yml
  add_row new-agent.yml exempt - -
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"new-agent.yml is 'exempt' and needs a reason in the note column"* ]]
}

@test "mutation: a second, ungated model-calling job in a gated workflow fails" {
  cat >> "$WF/stale-manager.yml" <<'YAML'

  second-opinion:
    runs-on: ubuntu-latest
    env:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    steps:
      - run: bash scripts/stale-manager.sh
YAML
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale-manager.yml: job 'second-opinion' reaches a model (model credential) but is not in the registry's gated jobs (stale)"* ]]
}

@test "mutation: a thin caller that grows its own model-calling job fails" {
  cat >> "$WF/persona-runner.yml" <<'YAML'

  inline:
    runs-on: ubuntu-latest
    steps:
      - run: npm install -g @anthropic-ai/claude-code && claude -p hi
YAML
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"persona-runner.yml: job 'inline' reaches a model (AI CLI or action) outside the reusable the registry names (persona-runner-reusable.yml)"* ]]
}

# ── mutation: the notice job ─────────────────────────────────────────────────

@test "mutation: dropping the fleet-paused job fails" {
  python3 - "$WF/readme-refresh.yml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
head, sep, _ = text.partition("\n  # Fleet pause notice (#2249).")
assert sep, "notice job not found"
open(path, "w", encoding="utf-8").write(head + "\n")
PY
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"readme-refresh.yml: missing the \`fleet-paused\` job that logs why the run was skipped"* ]]
}

@test "mutation: a notice job on different events than the job it speaks for fails" {
  # initiative-planner's plan job runs on workflow_dispatch only; a notice that
  # dropped the filter would also fire on every discussion label.
  replace_in "$WF/initiative-planner.yml" "      vars\.AGENTS_PAUSED == 'true' &&\n      github\.event_name == 'workflow_dispatch'\n" "      vars.AGENTS_PAUSED == 'true'\n"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"initiative-planner.yml: job 'fleet-paused' must run on the same events as 'plan'"* ]]
}

@test "mutation: a notice that does not name the pause source or until time fails" {
  replace_in "$WF/idea-triage.yml" '            "Pause source: \$\{PAUSE_SOURCE:-not set \(paused by hand\)\}\." \\\n' ""
  replace_in "$WF/idea-triage.yml" "      PAUSE_SOURCE: \\$\{\{ vars\.AGENTS_PAUSE_SOURCE \}\}\n" ""
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"idea-triage.yml: job 'fleet-paused': the notice must name the pause source and until time (PAUSE_SOURCE)"* ]]
  [[ "$output" == *"idea-triage.yml: job 'fleet-paused' must read vars.AGENTS_PAUSE_SOURCE"* ]]
}

@test "mutation: a notice job that waits on another job fails" {
  replace_in "$WF/skill-eval-report.yml" "  fleet-paused:\n" "  fleet-paused:\n    needs: eval-report\n"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"skill-eval-report.yml: job 'fleet-paused' must stand alone"* ]]
}

# ── mutation: the registry ───────────────────────────────────────────────────

@test "mutation: deleting a gated workflow's row fails (the workflow still calls a model)" {
  drop_row pr-review.yml
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"pr-review.yml can reach a model"*"but has no row in"* ]]
  # ...and its thin caller no longer points at a gated reusable.
  [[ "$output" == *"pr-review-trigger.yml: mode caller points at pr-review.yml, which has no job-gate row"* ]]
}

@test "mutation: registry rows that name a missing workflow, an unknown mode, or a duplicate fail" {
  add_row no-such-workflow.yml exempt - "Reason."
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"no-such-workflow.yml is not a file under .github/workflows"* ]]

  drop_row no-such-workflow.yml
  add_row lint.yml paused-ish - -
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown mode 'paused-ish' for lint.yml"* ]]

  drop_row lint.yml
  add_row budget-poller.yml exempt - "Again."
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate row for budget-poller.yml"* ]]
}

@test "mutation: a job-gate row naming a job the workflow does not have fails" {
  drop_row model-ab.yml
  add_row model-ab.yml job-gate model-abc -
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"model-ab.yml: registry names job 'model-abc', which the workflow does not have"* ]]
  [[ "$output" == *"model-ab.yml: job 'model-ab' reaches a model"* ]]
}

@test "mutation: an upstream row must name a reusable in another repository that the workflow calls" {
  drop_row feature-ideation.yml
  add_row feature-ideation.yml upstream petry-projects/.github/.github/workflows/something-else.yml "Reason."
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"feature-ideation.yml: no job calls the reusable the registry names"* ]]

  drop_row feature-ideation.yml
  add_row feature-ideation.yml upstream petry-projects/.github-private/.github/workflows/pr-review.yml "Reason."
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"feature-ideation.yml: mode upstream needs"* ]]
}

# ── documentation stays equal to the registry ────────────────────────────────

@test "AGENTS.md: the pause inventory table is the one generated from the registry" {
  run python3 "$CHECK" --root "$REPO_ROOT" --markdown
  [ "$status" -eq 0 ]
  local line n=0
  while IFS= read -r line; do
    grep -qxF -- "$line" "$REPO_ROOT/AGENTS.md" || { echo "AGENTS.md is missing this generated row (regenerate with --markdown): $line"; return 1; }
    n=$((n + 1))
  done <<< "$output"
  # Header, separator, and one row per registry entry.
  [ "$n" -eq "$(( $(grep -cvE '^(#|$)' "$REPO_ROOT/$REGISTRY_REL") + 2 ))" ]
  # No stale row: every table row in that section names a registered workflow.
  local doc_rows
  doc_rows="$(sed -n '/^#### Which workflows honour the pause/,/^Every workflow not listed/p' "$REPO_ROOT/AGENTS.md" | grep -c '^| `')"
  [ "$doc_rows" -eq "$(grep -cvE '^(#|$)' "$REPO_ROOT/$REGISTRY_REL")" ]
}

@test "CI wiring: the check runs in test-dev-lead.yml and this suite in lint.yml" {
  grep -q 'python3 tests/dev-lead/integration/test_fleet_pause_coverage.py' "$REPO_ROOT/.github/workflows/test-dev-lead.yml"
  grep -q 'tests/test_fleet_pause_coverage.bats' "$REPO_ROOT/.github/workflows/lint.yml"
}
