#!/usr/bin/env bats
# Unit + fixture tests for scripts/validate-caller-inputs.sh
# (Part A of #1052 channel-skew prevention — see issue #1253).
#
# The guard resolves, for every `uses: <owner>/<repo>/.github/workflows/<wf>.yml@<ref>`
# with a `with:` block, the reusable AT THE PINNED REF and asserts:
#   (a) every forwarded `with:` key is a declared workflow_call input there, and
#   (b) every `required: true` input is forwarded.
# It fails loud on any forwarded key not declared at that ref (the #1034 class),
# and only soft-passes (logged ::warning::) when a ref genuinely can't be resolved.
#
# Run with: bats tests/dev-lead/unit/test_validate_caller_inputs.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/validate-caller-inputs.sh"
  FIX="$REPO_ROOT/tests/dev-lead/fixtures/caller-inputs"
  # shellcheck source=/dev/null
  source "$SCRIPT"
}

# ---------------------------------------------------------------------------
# vci_parse_uses — pull owner/repo, wf path, and ref out of a `uses:` line
# ---------------------------------------------------------------------------

@test "vci_parse_uses parses a same-repo reusable ref with a channel tag" {
  run vci_parse_uses "    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-next"
  [ "$status" -eq 0 ]
  [ "$output" = "petry-projects/.github-private	.github/workflows/dev-lead-reusable.yml	dev-lead/v1-next" ]
}

@test "vci_parse_uses parses a cross-repo reusable ref and strips a trailing comment" {
  run vci_parse_uses "    uses: petry-projects/.github/.github/workflows/add-to-project-reusable.yml@add-to-project/v1-stable  # NOSONAR"
  [ "$status" -eq 0 ]
  [ "$output" = "petry-projects/.github	.github/workflows/add-to-project-reusable.yml	add-to-project/v1-stable" ]
}

@test "vci_parse_uses emits nothing for a regular action uses (not a reusable workflow)" {
  run vci_parse_uses "      uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6.0.3"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "vci_parse_uses emits nothing for a line without uses:" {
  run vci_parse_uses "    with:"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# vci_with_keys_for_job — collect the forwarded with: keys for a job
# ---------------------------------------------------------------------------

@test "vci_with_keys_for_job collects the direct with: keys" {
  local caller="$FIX/good/.github/workflows/caller.yml"
  local lineno
  lineno="$(grep -n 'uses: petry-projects' "$caller" | head -1 | cut -d: -f1)"
  run vci_with_keys_for_job "$caller" "$lineno"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent_ref"* ]]
  [[ "$output" == *"mode"* ]]
}

@test "vci_with_keys_for_job returns nothing when the job has no with: block" {
  tmp="$(mktemp)"
  cat > "$tmp" <<'YML'
jobs:
  call:
    uses: petry-projects/.github-private/.github/workflows/x.yml@stable
    secrets: inherit
YML
  local lineno
  lineno="$(grep -n 'uses:' "$tmp" | head -1 | cut -d: -f1)"
  run vci_with_keys_for_job "$tmp" "$lineno"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# vci_declared_inputs — parse workflow_call.inputs (name + required flag)
# ---------------------------------------------------------------------------

@test "vci_declared_inputs lists inputs with their required flag" {
  run vci_declared_inputs "$FIX/reusable/dev-lead-reusable.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'agent_ref\tfalse'* ]]
  [[ "$output" == *$'mode\ttrue'* ]]
  # secrets are NOT inputs — TOKEN must not appear
  [[ "$output" != *"TOKEN"* ]]
}

# ---------------------------------------------------------------------------
# vci_validate — the pure (a)+(b) comparison
# ---------------------------------------------------------------------------

@test "vci_validate passes when forwarded ⊆ declared and required forwarded" {
  run vci_validate $'agent_ref\nmode' $'agent_ref\tfalse\nmode\ttrue'
  [ "$status" -eq 0 ]
}

@test "vci_validate fails (a) on a forwarded key absent from declared inputs" {
  run vci_validate $'agent_ref\nmode\nextra_flag' $'agent_ref\tfalse\nmode\ttrue'
  [ "$status" -ne 0 ]
  [[ "$output" == *"extra_flag"* ]]
  [[ "$output" == *"not a declared"* ]]
}

@test "vci_validate fails (b) on a required input that is not forwarded" {
  run vci_validate $'agent_ref' $'agent_ref\tfalse\nmode\ttrue'
  [ "$status" -ne 0 ]
  [[ "$output" == *"mode"* ]]
  [[ "$output" == *"not forwarded"* ]]
}

# ---------------------------------------------------------------------------
# End-to-end scan over fixture repo trees (via VCI_RESOLVE_DIR — no network)
# ---------------------------------------------------------------------------

@test "clean caller tree passes" {
  run env VCI_ROOT="$FIX/good" VCI_RESOLVE_DIR="$FIX/reusable" bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "#1034 regression: forwarded key absent at the pinned ref FAILS" {
  run env VCI_ROOT="$FIX/regression-1034" VCI_RESOLVE_DIR="$FIX/reusable" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"extra_flag"* ]]
  [[ "$output" == *"not a declared"* ]]
}

@test "missing required input FAILS" {
  run env VCI_ROOT="$FIX/missing-required" VCI_RESOLVE_DIR="$FIX/reusable" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mode"* ]]
  [[ "$output" == *"not forwarded"* ]]
}

# ---------------------------------------------------------------------------
# Multi-pin per file (ADR-0007 agent-ingress): one file, MULTIPLE distinct
# per-job pins. Each job must be resolved+validated at its OWN ref, not under a
# single whole-file assumption (guards the #1034/#1052 channel-skew defect from
# recurring per-surface). The vci_with_keys_for_job indentation contract must
# hold even when if:/permissions: precede uses: and a job has no with: block.
# ---------------------------------------------------------------------------

@test "ingress: vci_with_keys_for_job scopes each job's with: keys independently" {
  local ingress="$FIX/ingress/.github/workflows/agent-ingress.yml"
  # dev-lead job: if: precedes uses:, then with: {agent_ref, mode}.
  local dl
  dl="$(grep -n 'dev-lead-reusable.yml' "$ingress" | head -1 | cut -d: -f1)"
  run vci_with_keys_for_job "$ingress" "$dl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent_ref"* ]]
  [[ "$output" == *"mode"* ]]
  # It must NOT bleed the sibling pr-review-mention job's forwarded keys.
  [[ "$output" != *"force_review"* ]]

  # pr-review-mention job: if:/permissions: precede uses:, then with:.
  local prm
  prm="$(grep -n 'pr-review-mention-reusable.yml' "$ingress" | head -1 | cut -d: -f1)"
  run vci_with_keys_for_job "$ingress" "$prm"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent_ref"* ]]
  [[ "$output" == *"force_review"* ]]
  [[ "$output" != *"mode"* ]]

  # ci-failure-analyst job: if:/permissions: precede uses:, and there is NO with:
  # block. vci_with_keys_for_job must return 0 with EMPTY output — proving the
  # indentation contract holds for a no-with reusable job and does not bleed the
  # sibling jobs' forwarded keys into this layout.
  local cfa
  cfa="$(grep -n 'ci-failure-analyst-reusable.yml' "$ingress" | head -1 | cut -d: -f1)"
  run vci_with_keys_for_job "$ingress" "$cfa"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ingress: multi-pin file passes when each job forwards its own declared inputs" {
  run env VCI_ROOT="$FIX/ingress" VCI_RESOLVE_DIR="$FIX/ingress-reusable" bash "$SCRIPT"
  echo "$output"
  [ "$status" -eq 0 ]
  # Both distinct pins were resolved and checked.
  [[ "$output" == *"checked=2"* ]]
}

@test "ingress: a single drifted job in an otherwise-valid ingress FAILS naming the bad input" {
  run env VCI_ROOT="$FIX/ingress-drift" VCI_RESOLVE_DIR="$FIX/ingress-reusable" bash "$SCRIPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bogus_input"* ]]
  [[ "$output" == *"not a declared"* ]]
  # The valid dev-lead job's inputs (mode/agent_ref) must NOT be reported.
  [[ "$output" != *"'mode' is not a declared"* ]]
}

# ---------------------------------------------------------------------------
# ADR-0010 collision rule: an agent-ingress job's caller-side concurrency group
# must not reuse any group its pinned reusable declares, or the nested caller and
# reusable groups block or cancel each other. Only the reusable AT THE PINNED REF
# can answer that, so this guard (which already resolves it) owns the check.
# ---------------------------------------------------------------------------

@test "ingress concurrency: a role-prefixed group distinct from the reusable's groups passes" {
  run env VCI_ROOT="$FIX/ingress-concurrency-ok" VCI_RESOLVE_DIR="$FIX/ingress-concurrency-reusable" bash "$SCRIPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked=1"* ]]
}

@test "ingress concurrency: a group colliding with a reusable-declared group FAILS" {
  run env VCI_ROOT="$FIX/ingress-concurrency-collide" VCI_RESOLVE_DIR="$FIX/ingress-concurrency-reusable" bash "$SCRIPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"'dev-lead'"* ]]
  [[ "$output" == *"dev-lead-pr-"* ]]
  [[ "$output" == *"collides"* ]]
}

@test "ingress concurrency: an unresolvable same-repo reusable FAILS closed" {
  empty="$(mktemp -d)"
  run env VCI_ROOT="$FIX/ingress-concurrency-ok" VCI_RESOLVE_DIR="$empty" bash "$SCRIPT"
  rmdir "$empty"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not be resolved"* ]]
  [[ "$output" == *"::error::"* ]]
}

@test "ingress concurrency: an unresolvable cross-repo reusable soft-passes with a warning only" {
  empty="$(mktemp -d)"
  run env VCI_ROOT="$FIX/ingress-concurrency-crossrepo" VCI_RESOLVE_DIR="$empty" bash "$SCRIPT"
  rmdir "$empty"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" != *"::error::"* ]]
}

# ---------------------------------------------------------------------------
# --pair mode: validate a single caller against an explicit reusable file
# ---------------------------------------------------------------------------

@test "--pair passes a good caller against its reusable" {
  run bash "$SCRIPT" --pair "$FIX/good/.github/workflows/caller.yml" "$FIX/reusable/dev-lead-reusable.yml"
  [ "$status" -eq 0 ]
}

@test "--pair fails the #1034 caller against its reusable" {
  run bash "$SCRIPT" --pair "$FIX/regression-1034/.github/workflows/caller.yml" "$FIX/reusable/dev-lead-reusable.yml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"extra_flag"* ]]
}

# ---------------------------------------------------------------------------
# An unresolvable ref must soft-pass with a logged ::warning:: (never silent)
# ---------------------------------------------------------------------------

@test "unresolvable ref soft-passes with a warning" {
  # VCI_RESOLVE_DIR points at an empty dir → resolution fails for every ref.
  empty="$(mktemp -d)"
  run env VCI_ROOT="$FIX/regression-1034" VCI_RESOLVE_DIR="$empty" bash "$SCRIPT"
  rm -rf "$empty"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
}
