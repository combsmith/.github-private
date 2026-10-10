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
    printf '%s\t%s\t%s\t%s\n' "petry-projects/alpha"   "ALIGNED" "$CANON" "$CANON"
    printf '%s\t%s\t%s\t%s\n' "petry-projects/bravo"   "DRIFTED" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$CANON"
    printf '%s\t%s\t%s\t%s\n' "petry-projects/charlie" "MISSING" "" "$CANON"
    printf '%s\t%s\t%s\t%s\n' "petry-projects/delta"   "DRIFTED" "dddddddddddddddddddddddddddddddddddddddd" "$CANON"
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
  run stub_drift_row "petry-projects/bravo" "$CANON" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'petry-projects/bravo\tDRIFTED\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t%s' "$CANON")" ]
}

@test "stub_drift_row: a missing stub records an empty repo SHA" {
  run stub_drift_row "petry-projects/charlie" "$CANON" ""
  [ "$output" = "$(printf 'petry-projects/charlie\tMISSING\t\t%s' "$CANON")" ]
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
  [ "$repos" = "petry-projects/bravo,petry-projects/delta," ]
  # Each entry carries both SHAs so the alert can show the drift.
  printf '%s' "$output" | jq -e '.[0] | has("repo") and has("repo_sha") and has("canonical_sha")' >/dev/null
}

@test "stub_drift_alert_json: an all-aligned TSV yields an empty array" {
  aligned="$(mktemp)"
  printf '%s\t%s\t%s\t%s\n' "petry-projects/alpha" "ALIGNED" "$CANON" "$CANON" > "$aligned"
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
  [[ "$output" == *"petry-projects/bravo"* ]]
  [[ "$output" == *"petry-projects/delta"* ]]
  # The canonical SHA (short form) is shown.
  [[ "$output" == *"aaaaaaa"* ]]
}

@test "generate_stub_drift_report: a passed stub label headlines the section (multi-stub)" {
  run generate_stub_drift_report "$DRIFT_TSV" "$CANON" "Initiative-driver"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Initiative-driver stub"* ]]
  # It must not silently fall back to the planner heading.
  [[ "$output" != *"Initiative-planner stub"* ]]
  [[ "$output" == *"petry-projects/bravo"* ]]
}

@test "generate_stub_drift_report: the default label is still Initiative-planner (regression)" {
  run generate_stub_drift_report "$DRIFT_TSV" "$CANON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Initiative-planner stub"* ]]
}

@test "generate_stub_drift_report: a clean fleet reports no drift" {
  aligned="$(mktemp)"
  printf '%s\t%s\t%s\t%s\n' "petry-projects/alpha" "ALIGNED" "$CANON" "$CANON" > "$aligned"
  run generate_stub_drift_report "$aligned" "$CANON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALIGNED"* || "$output" == *"aligned"* || "$output" == *"No drift"* ]]
  rm -f "$aligned"
}

# ---------------------------------------------------------------------------
# Per-job (role-selector) extraction over an agent-ingress.yml fixture (#1726).
# The per-role Class-1 stubs collapse into ONE agent-ingress.yml with one job per
# role; detection moves from whole-file blob SHA to extracted-per-job-block SHA.
# Fixtures live under tests/fixtures/agent-ingress/.
# ---------------------------------------------------------------------------

INGRESS="${BATS_TEST_DIRNAME}/fixtures/agent-ingress/canonical.yml"
INGRESS_DRIFTED="${BATS_TEST_DIRNAME}/fixtures/agent-ingress/drifted-dev-lead.yml"
INGRESS_NO_DEVLEAD="${BATS_TEST_DIRNAME}/fixtures/agent-ingress/collapsed-no-dev-lead.yml"

@test "extract_job_block: extracts ONLY the named job's block" {
  run extract_job_block "dev-lead" < "$INGRESS"
  [ "$status" -eq 0 ]
  # The dev-lead block carries its own reusable pin ...
  [[ "$output" == *"dev-lead-reusable.yml"* ]]
  [[ "$output" == *"  dev-lead:"* ]]
  # ... and NOT the sibling job's key or reusable (block isolation).
  [[ "$output" != *"pr-review-mention-reusable.yml"* ]]
  [[ "$output" != *"pr-review-mention:"* ]]
}

@test "extract_job_block: an absent job yields empty output" {
  run extract_job_block "does-not-exist" < "$INGRESS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "job_block_sha: distinct job blocks hash differently; identical file hashes equal" {
  dl="$(job_block_sha "dev-lead" < "$INGRESS")"
  prm="$(job_block_sha "pr-review-mention" < "$INGRESS")"
  [ -n "$dl" ]
  [ -n "$prm" ]
  [ "$dl" != "$prm" ]
  # Same file, same job ⇒ same block SHA (deterministic).
  dl2="$(job_block_sha "dev-lead" < "$INGRESS")"
  [ "$dl" = "$dl2" ]
}

@test "job_block_sha: an absent job block is empty (classifies MISSING, not resurrected)" {
  run job_block_sha "dev-lead" < "$INGRESS_NO_DEVLEAD"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# QA input #6: drift introduced in EXACTLY ONE job block must be DETECTED and the
# SPECIFIC job identified — while the sibling job is proven NOT to have drifted.
@test "classify_role_drift: drift in one job is DETECTED on that job, sibling stays ALIGNED (AC #1, QA #6)" {
  canon_dl="$(job_block_sha "dev-lead" < "$INGRESS")"
  repo_dl="$(job_block_sha "dev-lead" < "$INGRESS_DRIFTED")"
  # The dev-lead block genuinely differs between canon and the drifted fixture.
  [ "$canon_dl" != "$repo_dl" ]
  run classify_role_drift "yes" "$canon_dl" "$repo_dl" "" ""
  [ "$output" = "DRIFTED" ]

  # The sibling pr-review-mention block is byte-identical ⇒ ALIGNED (not drifted).
  canon_prm="$(job_block_sha "pr-review-mention" < "$INGRESS")"
  repo_prm="$(job_block_sha "pr-review-mention" < "$INGRESS_DRIFTED")"
  [ "$canon_prm" = "$repo_prm" ]
  run classify_role_drift "yes" "$canon_prm" "$repo_prm" "" ""
  [ "$output" = "ALIGNED" ]
}

@test "classify_role_drift: an aligned ingress block is ALIGNED" {
  canon_dl="$(job_block_sha "dev-lead" < "$INGRESS")"
  run classify_role_drift "yes" "$canon_dl" "$canon_dl" "" ""
  [ "$output" = "ALIGNED" ]
}

# Never-resurrect: a collapsed repo (ingress present) with the role block removed
# is MISSING — even when a legacy per-role blob SHA is supplied, the legacy file
# is IGNORED so remediation can never recreate the deleted stub.
@test "classify_role_drift: ingress present + absent block is MISSING, legacy ignored (never resurrect)" {
  canon_dl="$(job_block_sha "dev-lead" < "$INGRESS")"
  absent_block="$(job_block_sha "dev-lead" < "$INGRESS_NO_DEVLEAD")"   # empty
  [ -z "$absent_block" ]
  run classify_role_drift "yes" "$canon_dl" "$absent_block" "legacycanon00000000000000000000000000000" "legacyrepo000000000000000000000000000000"
  [ "$output" = "MISSING" ]
}

# Backward compatibility (AC #4): a legacy repo with NO agent-ingress.yml still
# classifies on the whole-file per-role SHAs, exactly as before.
@test "classify_role_drift: no ingress (legacy repo) classifies on whole-file per-role SHAs (AC #4)" {
  local canon="cafecafecafecafecafecafecafecafecafecafe"
  run classify_role_drift "no" "irrelevant-block-sha" "" "$canon" "$canon"
  [ "$output" = "ALIGNED" ]
  run classify_role_drift "no" "irrelevant-block-sha" "" "$canon" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  [ "$output" = "DRIFTED" ]
  run classify_role_drift "no" "irrelevant-block-sha" "" "$canon" ""
  [ "$output" = "MISSING" ]
}

# A role with no published per-role canonical (#1729: pr-review,
# ci-failure-analyst) cannot compare a legacy file, so it is MISSING, not DRIFTED.
@test "classify_role_drift: no ingress and no legacy canonical is MISSING, never DRIFTED" {
  run classify_role_drift "no" "irrelevant-block-sha" "" "" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  [ "$output" = "MISSING" ]
}

# ---------------------------------------------------------------------------
# stub_drift_row_role — role rows flow through the SAME 4-field TSV shape as
# whole-file rows, so the report/alert path is shared. The emitted SHAs are the
# pair actually compared (block SHAs when ingress present, else legacy SHAs).
# ---------------------------------------------------------------------------

@test "stub_drift_row_role: ingress present emits the BLOCK SHAs and its status" {
  canon_dl="$(job_block_sha "dev-lead" < "$INGRESS")"
  repo_dl="$(job_block_sha "dev-lead" < "$INGRESS_DRIFTED")"
  run stub_drift_row_role "petry-projects/alpha" "yes" "$canon_dl" "$repo_dl" "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'petry-projects/alpha\tDRIFTED\t%s\t%s' "$repo_dl" "$canon_dl")" ]
}

@test "stub_drift_row_role: ingress present + removed block is MISSING with an empty repo SHA (never resurrect)" {
  canon_dl="$(job_block_sha "dev-lead" < "$INGRESS")"
  run stub_drift_row_role "petry-projects/charlie" "yes" "$canon_dl" "" "legacycanon00000000000000000000000000000" "legacyrepo000000000000000000000000000000"
  [ "$status" -eq 0 ]
  # Legacy SHAs are IGNORED: the emitted row carries the (empty) block SHA + canon block.
  [ "$output" = "$(printf 'petry-projects/charlie\tMISSING\t\t%s' "$canon_dl")" ]
}

@test "stub_drift_row_role: no ingress (legacy repo) emits the legacy whole-file SHAs (AC #4)" {
  local canon="cafecafecafecafecafecafecafecafecafecafe"
  run stub_drift_row_role "petry-projects/delta" "no" "block-sha-ignored" "" "$canon" "$canon"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'petry-projects/delta\tALIGNED\t%s\t%s' "$canon" "$canon")" ]
}
