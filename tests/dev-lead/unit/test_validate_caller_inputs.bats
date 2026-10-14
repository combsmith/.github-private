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
  run vci_parse_uses "    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-next"
  [ "$status" -eq 0 ]
  [ "$output" = "combsmith/.github-private	.github/workflows/dev-lead-reusable.yml	dev-lead/v1-next" ]
}

@test "vci_parse_uses parses a cross-repo reusable ref and strips a trailing comment" {
  run vci_parse_uses "    uses: combsmith/.github/.github/workflows/add-to-project-reusable.yml@add-to-project/v1-stable  # NOSONAR"
  [ "$status" -eq 0 ]
  [ "$output" = "combsmith/.github	.github/workflows/add-to-project-reusable.yml	add-to-project/v1-stable" ]
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
  lineno="$(grep -n 'uses: combsmith' "$caller" | head -1 | cut -d: -f1)"
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
    uses: combsmith/.github-private/.github/workflows/x.yml@stable
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
