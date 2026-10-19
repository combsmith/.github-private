#!/usr/bin/env bats
# Invariants of the decision-brief stage's three workflow files
# (combsmith/incubator#3): the central .github/workflows/decision-brief.yml,
# the hosted fleet-dispatch reusable decision-brief-reusable.yml, and the thin
# caller stub standards/workflows/decision-brief.yml. Mirrors
# tests/test_feature_ideation.bats: structural greps, no network.
#
# Run with: bats tests/test_decision_brief_workflow.bats

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CENTRAL="$ROOT/.github/workflows/decision-brief.yml"
REUSABLE="$ROOT/.github/workflows/decision-brief-reusable.yml"
STUB="$ROOT/standards/workflows/decision-brief.yml"
REUSABLE_REF="combsmith/.github-private/.github/workflows/decision-brief-reusable.yml"
CHANNEL="decision-brief/v1-stable"

setup() { cd "$ROOT"; }

# ── the central workflow ──────────────────────────────────────────────────────

@test "central: exists, is org-private automation (claude-code-action pinned to a SHA), and resolves a model FAMILY" {
  [ -f "$CENTRAL" ]
  grep -qE 'uses: anthropics/claude-code-action@[0-9a-f]{40}' "$CENTRAL"
  grep -q 'source scripts/lib/engine-models.sh' "$CENTRAL"
  grep -q 'ai_model_for_family' "$CENTRAL"
  # No concrete model id anywhere in the file (#1979).
  ! grep -qE 'claude-(opus|sonnet|haiku)-[0-9]' "$CENTRAL" || false
}

@test "central: the needs-brief label fires a redispatch bridge that runs only on the discussion event" {
  grep -qE '^[[:space:]]+redispatch:' "$CENTRAL"
  grep -qE "github\.event_name[[:space:]]*==[[:space:]]*'discussion'[[:space:]]*&&[[:space:]]*github\.event\.label\.name[[:space:]]*==[[:space:]]*'needs-brief'" "$CENTRAL"
  grep -q 'run: bash scripts/decision-brief/redispatch.sh' "$CENTRAL"
  # The bridge needs a PAT — GITHUB_TOKEN never starts a workflow_dispatch run.
  grep -q 'secrets.GH_PAT_DON_PETRY || secrets.GH_PAT_WORKFLOWS' "$CENTRAL"
}

@test "central: the model job runs only under workflow_dispatch, never inline on the discussion event" {
  # brief job: paused-first `if:` then the workflow_dispatch filter (#2249 shape).
  grep -qE "if: vars\.AGENTS_PAUSED != 'true' && github\.event_name == 'workflow_dispatch' && inputs\.from_queue != true" "$CENTRAL"
  # The notice job is the exact complement.
  grep -qE "^[[:space:]]+fleet-paused:" "$CENTRAL"
  grep -qE "vars\.AGENTS_PAUSED == 'true' &&" "$CENTRAL"
}

@test "central: the provenance gate is its own step AFTER the model step and BEFORE the PR step" {
  action_line="$(grep -n 'uses: anthropics/claude-code-action' "$CENTRAL" | cut -d: -f1)"
  gate_line="$(grep -n 'name: Provenance + structure gate' "$CENTRAL" | cut -d: -f1)"
  pr_line="$(grep -n 'run: bash scripts/decision-brief/open-pr.sh' "$CENTRAL" | cut -d: -f1)"
  [ -n "$action_line" ] && [ -n "$gate_line" ] && [ -n "$pr_line" ]
  [ "$action_line" -lt "$gate_line" ]
  [ "$gate_line" -lt "$pr_line" ]
  # The gate step runs the validator the model is also told to run.
  grep -qc 'scripts/decision-brief/validate-package.sh' "$CENTRAL"
  [ "$(grep -c 'scripts/decision-brief/validate-package.sh' "$CENTRAL")" -ge 2 ]
}

@test "central: Mary is told the provenance rule and the overlay, and may research the web" {
  grep -q 'cat prompts/incubation/shared.md' "$CENTRAL"
  grep -q 'cat prompts/incubation/decision-brief-stage.md' "$CENTRAL"
  grep -q 'unknown — needs discovery' "$CENTRAL"
  grep -q 'No fabrication' "$CENTRAL"
  grep -qE -- '--allowedTools .*WebSearch' "$CENTRAL"
}

@test "central: never applies idea:approved — the human gate stays human" {
  # The label is named only in prose/the prompt, never in a label mutation.
  ! grep -E 'gh (label|discussion).*idea:approved|--add-label.*idea:approved|addLabelsToLabelable' "$CENTRAL" | grep -vq '#' || false
  grep -q 'NEVER applies' "$CENTRAL"
}

@test "central: target_repo parameterizes reads + writes; self path uses GITHUB_TOKEN, cross-repo the PAT" {
  grep -q "REPO: \${{ github.event.inputs.target_repo || github.repository }}" "$CENTRAL"
  grep -qE "TARGET_GH_TOKEN: .*github\.event\.inputs\.target_repo == '' .*secrets\.GITHUB_TOKEN .*secrets\.GH_PAT_DON_PETRY" "$CENTRAL"
  grep -q 'GH_TOKEN: ${{ env.TARGET_GH_TOKEN }}' "$CENTRAL"
  grep -q 'github_token: ${{ env.TARGET_GH_TOKEN }}' "$CENTRAL"
}

@test "central: one lane per (target repo, discussion); sweep takes the queue lane; never cancels" {
  grep -q "group: decision-brief-\${{ github.event.inputs.target_repo || github.repository }}-\${{ github.event.inputs.discussion || github.event.discussion.number || 'queue' }}" "$CENTRAL"
  grep -q 'cancel-in-progress: false' "$CENTRAL"
}

@test "central: the queue sweep dispatches per-idea runs with no model call of its own" {
  grep -qE '^[[:space:]]+sweep:' "$CENTRAL"
  grep -q 'bash scripts/decision-brief/ripe-from-queue.sh' "$CENTRAL"
  # Between `sweep:` and `brief:` there is no model credential or action.
  ! sed -n '/^  sweep:/,/^  brief:/p' "$CENTRAL" | grep -qE 'CLAUDE_CODE_OAUTH_TOKEN|claude-code-action' || false
}

@test "central: a dry run uploads the drafted package and the intended-PR log" {
  grep -q 'name: decision-brief-${{ env.SLUG || ' "$CENTRAL"
  grep -q 'dry-run.jsonl' "$CENTRAL"
  grep -qE 'default: true' "$CENTRAL"   # dry_run defaults to true on manual dispatch
}

# ── the hosted reusable (fleet dispatch bridge) ───────────────────────────────

@test "reusable: workflow_call with central_repo defaulting to this repo; no model credential" {
  [ -f "$REUSABLE" ]
  grep -q 'workflow_call:' "$REUSABLE"
  grep -q 'default: "combsmith/.github-private"' "$REUSABLE"
  # Outside comments: no model credential, no model action.
  ! grep -vE '^[[:space:]]*#' "$REUSABLE" | grep -q 'CLAUDE_CODE_OAUTH_TOKEN' || false
  ! grep -vE '^[[:space:]]*#' "$REUSABLE" | grep -q 'claude-code-action' || false
}

@test "reusable: fires on the needs-brief label, schedule and manual dispatch; label path needs a trusted actor" {
  grep -q "github.event.action == 'labeled' && github.event.label.name == inputs.label" "$REUSABLE"
  grep -q "github.event_name == 'schedule'" "$REUSABLE"
  grep -q 'collaborators/${ACTOR}/permission' "$REUSABLE"
  grep -q "if: steps.trust.outputs.trusted == 'true'" "$REUSABLE"
}

@test "reusable: dispatches the central workflow with target_repo=caller, dry_run=false; sweep uses from_queue=true" {
  grep -q 'gh workflow run decision-brief.yml' "$REUSABLE"
  grep -qE -- '-f discussion="\$\{DISCUSSION_NUMBER\}"' "$REUSABLE"
  grep -qE -- '-f target_repo="\$\{TARGET_REPO\}"' "$REUSABLE"
  grep -q -- '-f dry_run=false' "$REUSABLE"
  grep -q -- '-f from_queue=true' "$REUSABLE"
  grep -q 'TARGET_REPO: ${{ github.repository }}' "$REUSABLE"
  grep -q 'positive integer' "$REUSABLE"
}

# ── the thin caller stub ──────────────────────────────────────────────────────

@test "stub: pins the hosted reusable to the decision-brief/v1-stable channel with the S7637 marker" {
  [ -f "$STUB" ]
  grep -qF "uses: ${REUSABLE_REF}@${CHANNEL}" "$STUB"
  grep -q 'NOSONAR(githubactions:S7637)' "$STUB"
  grep -q 'secrets: inherit' "$STUB"
  grep -qE '^permissions: \{\}' "$STUB"
}

@test "stub: a thin caller — no steps, no run:, forwards only inputs the reusable declares" {
  ! grep -qE '^[[:space:]]+(steps|run):' "$STUB" || false
  # Every `with:` key is a declared workflow_call input of the reusable.
  declared="$(awk '/^    inputs:/{f=1;next} /^    secrets:/{f=0} f && /^      [a-z_]+:/{sub(/^      /,""); sub(/:.*/,""); print}' "$REUSABLE")"
  forwarded="$(awk '/^    with:/{f=1;next} /^    secrets:/{f=0} f && /^      [a-z_]+:/{sub(/^      /,""); sub(/:.*/,""); print}' "$STUB")"
  [ -n "$forwarded" ]
  while IFS= read -r k; do
    grep -qx "$k" <<<"$declared" || { echo "stub forwards undeclared input: $k"; return 1; }
  done <<<"$forwarded"
}

@test "stub: validate-caller-inputs accepts the stub against the reusable (pair mode)" {
  run bash "$ROOT/scripts/validate-caller-inputs.sh" --pair "$STUB" "$REUSABLE"
  [ "$status" -eq 0 ]
}

@test "stub: triggers are discussion:labeled + an off-peak weekly schedule + workflow_dispatch; #571-safe inputs" {
  grep -qE '^  discussion:' "$STUB"
  grep -qE '^    types: \[labeled\]' "$STUB"
  cron="$(grep -oE "cron: '[^']+'" "$STUB" | head -1 | sed "s/cron: '//; s/'$//")"
  [ -n "$cron" ]
  [ "${cron%% *}" != "0" ]
  grep -qE '^  workflow_dispatch:' "$STUB"
  # The reusable `with:` reads github.event.inputs.*, never the `inputs` context.
  grep -q 'discussion: ${{ github.event.inputs.discussion }}' "$STUB"
  ! grep -qE '\$\{\{[[:space:]]*inputs\.' "$STUB" || false
}

@test "stub: adoption notes name the two labels the incubator must create" {
  grep -q 'needs-brief' "$STUB"
  grep -q 'idea:approved' "$STUB"
  grep -q 'ideas/_TEMPLATE' "$STUB"
}

# ── wiring in this repo ───────────────────────────────────────────────────────

@test "wiring: the fleet-pause registry gates the brief job; the §4 table classifies both workflows" {
  grep -qE '^decision-brief\.yml	job-gate	brief	' "$ROOT/scripts/lib/fleet-pause-registry.tsv"
  grep -q '`.github/workflows/decision-brief.yml` | 1 |' "$ROOT/docs/agentic-interaction-model.md"
  grep -q '`.github/workflows/decision-brief-reusable.yml` | Reusable workflow' "$ROOT/docs/agentic-interaction-model.md"
}

@test "wiring: lint.yml runs both decision-brief suites; cut-release knows the agent" {
  grep -q 'tests/test_decision_brief.bats' "$ROOT/.github/workflows/lint.yml"
  grep -q 'tests/test_decision_brief_workflow.bats' "$ROOT/.github/workflows/lint.yml"
  source "$ROOT/scripts/cut-release.sh"
  run valid_agent "decision-brief"
  [ "$status" -eq 0 ]
  export GITHUB_REPOSITORY="combsmith/.github-private"
  run agent_host_repo "decision-brief"
  [ "$output" = "combsmith/.github-private" ]
}

@test "wiring: the overlay prompt exists and names the four inputs, ICE-by-default and the provenance rule" {
  f="$ROOT/prompts/incubation/decision-brief-stage.md"
  [ -f "$f" ]
  grep -q 'Riskiest assumption' "$f"
  grep -qi 'ICE.*by default' "$f"
  grep -q 'unknown — needs discovery' "$f"
  grep -q 'validate-package.sh' "$f"
  [ -f "$ROOT/prompts/incubation/producer-ost.md" ]
}
