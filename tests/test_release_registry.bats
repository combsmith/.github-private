#!/usr/bin/env bats
# Validates release/registry.yml — the fleet registry the Release_Manager
# soak-and-promote automation (#993/#994/#999) reads to gate + promote each
# first-party reusable. This guards the shape of the dev-lead onboarding intake
# (#1005): host, the health-gate workflow, gate knobs, and the ordered
# next→ring0→ring1→stable rollout ladder with its validated repo lists.
#
# Run with: bats tests/test_release_registry.bats

REGISTRY="$(dirname "$BATS_TEST_FILENAME")/../release/registry.yml"

setup() {
  command -v yq >/dev/null 2>&1 || { echo "ERROR: yq is required but not installed" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not installed" >&2; return 1; }
}

@test "registry.yml: is valid YAML with a schema version" {
  run yq -e '.version' "$REGISTRY"
  [ "$status" -eq 0 ]
}

@test "registry.yml: has a non-empty reusables map" {
  run yq -e '.reusables | length > 0' "$REGISTRY"
  [ "$status" -eq 0 ]
}

@test "registry.yml: dev-lead entry is present" {
  run yq -e '.reusables | has("dev-lead")' "$REGISTRY"
  [ "$status" -eq 0 ]
}

@test "registry.yml: dev-lead is hosted in .github-private" {
  run yq -e '.reusables."dev-lead".host == "combsmith/.github-private"' "$REGISTRY"
  [ "$status" -eq 0 ]
}

@test "registry.yml: dev-lead declares a run_workflow for the health gate" {
  run yq -e '.reusables."dev-lead".run_workflow' "$REGISTRY"
  [ "$status" -eq 0 ]
}

@test "registry.yml: dev-lead gate soak_window_days is 7" {
  run yq -e '.reusables."dev-lead".gate.soak_window_days == 7' "$REGISTRY"
  [ "$status" -eq 0 ]
}

@test "registry.yml: dev-lead gate requires the shadow_dual_run signal (#605)" {
  run bash -c "yq -o=json '$REGISTRY' | jq -er '(.reusables.\"dev-lead\".gate.signals // []) | index(\"shadow_dual_run\") != null'"
  [ "$status" -eq 0 ]
}

@test "registry.yml: dev-lead has four rings" {
  run yq -e '.reusables."dev-lead".rings | length == 4' "$REGISTRY"
  [ "$status" -eq 0 ]
}

@test "registry.yml: dev-lead ring channels are next/ring0/ring1/stable in order" {
  run bash -c "yq -o=json '$REGISTRY' | jq -er '[.reusables.\"dev-lead\".rings[].channel] == [\"next\",\"ring0\",\"ring1\",\"stable\"]'"
  [ "$status" -eq 0 ]
}

@test "registry.yml: dev-lead ring order values are 0..3 ascending" {
  run bash -c "yq -o=json '$REGISTRY' | jq -er '[.reusables.\"dev-lead\".rings[].order] == [0,1,2,3]'"
  [ "$status" -eq 0 ]
}

@test "registry.yml: dev-lead next ring is the self-host repo" {
  run bash -c "yq -o=json '$REGISTRY' | jq -er '(.reusables.\"dev-lead\".rings[] | select(.channel==\"next\").repos) == [\"combsmith/.github-private\"]'"
  [ "$status" -eq 0 ]
}

@test "registry.yml: dev-lead ring0 is the other org-infra repo" {
  run bash -c "yq -o=json '$REGISTRY' | jq -er '(.reusables.\"dev-lead\".rings[] | select(.channel==\"ring0\").repos) == [\"combsmith/.github\"]'"
  [ "$status" -eq 0 ]
}

@test "registry.yml: dev-lead ring1 carries the two low-traffic consumers" {
  run bash -c "yq -o=json '$REGISTRY' | jq -er '(.reusables.\"dev-lead\".rings[] | select(.channel==\"ring1\").repos) == [\"combsmith/TalkTerm\",\"combsmith/bmad-bgreat-suite\"]'"
  [ "$status" -eq 0 ]
}

@test "registry.yml: dev-lead stable carries the remaining four consumers" {
  run bash -c "yq -o=json '$REGISTRY' | jq -er '(.reusables.\"dev-lead\".rings[] | select(.channel==\"stable\").repos) == [\"combsmith/ContentTwin\",\"combsmith/google-app-scripts\",\"combsmith/markets\",\"combsmith/broodly\"]'"
  [ "$status" -eq 0 ]
}
