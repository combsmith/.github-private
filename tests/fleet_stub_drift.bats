#!/usr/bin/env bats
# Tests for scripts/fleet_stub_drift.sh — initiative-planner stub coverage &
# drift detection for the Actions Fleet Monitor (#822, AC#2 + AC#3).
#
# All functions are pure: they take a canonical SHA + a per-repo stub blob SHA
# (or a drift TSV) and write to stdout. No network. Run:
#   bats tests/fleet_stub_drift.bats
#
# Drift TSV format (4 fields, tab-separated):
#   1:repo  2:status  3:repo_sha  4:canonical_sha
# status ∈ { ALIGNED, DRIFTED, MISSING }

CANON="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

setup() {
  # shellcheck source=scripts/fleet_stub_drift.sh
  source "${BATS_TEST_DIRNAME}/../scripts/fleet_stub_drift.sh"

  DRIFT_TSV="$(mktemp)"
  {
    printf '%s\t%s\t%s\t%s\n' "combsmith/alpha"   "ALIGNED" "$CANON" "$CANON"
    printf '%s\t%s\t%s\t%s\n' "combsmith/bravo"   "DRIFTED" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$CANON"
    printf '%s\t%s\t%s\t%s\n' "combsmith/charlie" "MISSING" "" "$CANON"
    printf '%s\t%s\t%s\t%s\n' "combsmith/delta"   "DRIFTED" "dddddddddddddddddddddddddddddddddddddddd" "$CANON"
  } > "$DRIFT_TSV"
}

teardown() {
  rm -f "${DRIFT_TSV:-}"
}

# ---------------------------------------------------------------------------
# classify_stub_drift <canonical_sha> <repo_sha>
# ---------------------------------------------------------------------------

@test "classify_stub_drift: identical SHAs are ALIGNED" {
  run classify_stub_drift "$CANON" "$CANON"
  [ "$status" -eq 0 ]
  [ "$output" = "ALIGNED" ]
}

@test "classify_stub_drift: a different SHA is DRIFTED" {
  run classify_stub_drift "$CANON" "ffffffffffffffffffffffffffffffffffffffff"
  [ "$output" = "DRIFTED" ]
}

@test "classify_stub_drift: an empty repo SHA is MISSING (not enrolled)" {
  run classify_stub_drift "$CANON" ""
  [ "$output" = "MISSING" ]
}

@test "classify_stub_drift: a null repo SHA is MISSING" {
  run classify_stub_drift "$CANON" "null"
  [ "$output" = "MISSING" ]
}

# ---------------------------------------------------------------------------
# stub_drift_row <repo> <canonical_sha> <repo_sha>
# ---------------------------------------------------------------------------

@test "stub_drift_row: emits a 4-field TSV with the classified status" {
  run stub_drift_row "combsmith/bravo" "$CANON" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'combsmith/bravo\tDRIFTED\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t%s' "$CANON")" ]
}

@test "stub_drift_row: a missing stub records an empty repo SHA" {
  run stub_drift_row "combsmith/charlie" "$CANON" ""
  [ "$output" = "$(printf 'combsmith/charlie\tMISSING\t\t%s' "$CANON")" ]
}

# ---------------------------------------------------------------------------
# count_stub_drift <tsv_file> <status>
# ---------------------------------------------------------------------------

@test "count_stub_drift: counts rows per status" {
  run count_stub_drift "$DRIFT_TSV" "DRIFTED"
  [ "$output" -eq 2 ]
  run count_stub_drift "$DRIFT_TSV" "ALIGNED"
  [ "$output" -eq 1 ]
  run count_stub_drift "$DRIFT_TSV" "MISSING"
  [ "$output" -eq 1 ]
}

@test "count_stub_drift: an absent status returns 0" {
  run count_stub_drift "$DRIFT_TSV" "NOPE"
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# stub_drift_alert_json <tsv_file> — DRIFTED rows are the alertable set
# ---------------------------------------------------------------------------

@test "stub_drift_alert_json: emits only DRIFTED enrolled repos" {
  run stub_drift_alert_json "$DRIFT_TSV"
  [ "$status" -eq 0 ]
  len=$(printf '%s' "$output" | jq 'length')
  [ "$len" -eq 2 ]
  repos=$(printf '%s' "$output" | jq -r '.[].repo' | sort | tr '\n' ',')
  [ "$repos" = "combsmith/bravo,combsmith/delta," ]
  # Each entry carries both SHAs so the alert can show the drift.
  printf '%s' "$output" | jq -e '.[0] | has("repo") and has("repo_sha") and has("canonical_sha")' >/dev/null
}

@test "stub_drift_alert_json: an all-aligned TSV yields an empty array" {
  aligned="$(mktemp)"
  printf '%s\t%s\t%s\t%s\n' "combsmith/alpha" "ALIGNED" "$CANON" "$CANON" > "$aligned"
  run stub_drift_alert_json "$aligned"
  [ "$output" = "[]" ]
  rm -f "$aligned"
}

@test "stub_drift_alert_json: an empty/absent TSV yields an empty array" {
  empty="$(mktemp)"
  run stub_drift_alert_json "$empty"
  [ "$output" = "[]" ]
  rm -f "$empty"
}

@test "stub_drift_alert_json: a stub label/file tags each DRIFTED row (multi-stub)" {
  run stub_drift_alert_json "$DRIFT_TSV" "Initiative-driver" ".github/workflows/initiative-driver.yml"
  [ "$status" -eq 0 ]
  len=$(printf '%s' "$output" | jq 'length')
  [ "$len" -eq 2 ]
  # Each entry is tagged so the workflow can group/route per stub kind.
  printf '%s' "$output" | jq -e 'all(.[]; .stub == "Initiative-driver")' >/dev/null
  printf '%s' "$output" | jq -e 'all(.[]; .stub_file == ".github/workflows/initiative-driver.yml")' >/dev/null
  # The repo + SHA fields are still present.
  printf '%s' "$output" | jq -e '.[0] | has("repo") and has("repo_sha") and has("canonical_sha")' >/dev/null
}

# ---------------------------------------------------------------------------
# generate_stub_drift_report <tsv_file> <canonical_sha>
# ---------------------------------------------------------------------------

@test "generate_stub_drift_report: summarizes counts and lists drifted repos" {
  run generate_stub_drift_report "$DRIFT_TSV" "$CANON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Initiative-planner stub"* ]]
  # Drifted repos are called out by name.
  [[ "$output" == *"combsmith/bravo"* ]]
  [[ "$output" == *"combsmith/delta"* ]]
  # The canonical SHA (short form) is shown.
  [[ "$output" == *"aaaaaaa"* ]]
}

@test "generate_stub_drift_report: a passed stub label headlines the section (multi-stub)" {
  run generate_stub_drift_report "$DRIFT_TSV" "$CANON" "Initiative-driver"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Initiative-driver stub"* ]]
  # It must not silently fall back to the planner heading.
  [[ "$output" != *"Initiative-planner stub"* ]]
  [[ "$output" == *"combsmith/bravo"* ]]
}

@test "generate_stub_drift_report: the default label is still Initiative-planner (regression)" {
  run generate_stub_drift_report "$DRIFT_TSV" "$CANON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Initiative-planner stub"* ]]
}

@test "generate_stub_drift_report: a clean fleet reports no drift" {
  aligned="$(mktemp)"
  printf '%s\t%s\t%s\t%s\n' "combsmith/alpha" "ALIGNED" "$CANON" "$CANON" > "$aligned"
  run generate_stub_drift_report "$aligned" "$CANON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALIGNED"* || "$output" == *"aligned"* || "$output" == *"No drift"* ]]
  rm -f "$aligned"
}
