#!/usr/bin/env bats
# Tests for scripts/template_stub_drift.sh — the repo-template drift guard (#969,
# epic #964). The guard reuses fleet_stub_drift.sh's byte-identity (blob-SHA
# equality) ALIGNED/DRIFTED/MISSING model to fail CI when a file committed in
# combsmith/repo-template has drifted from its standards-derived baseline
# (what seed-repo-template.sh emits).
#
# All assertions here are PURE: they exercise the classification + allowlist +
# annotation helpers over synthetic SHAs. No network. Run:
#   bats tests/template_stub_drift.bats
#
# Drift TSV format (4 fields, tab-separated), shared with fleet_stub_drift.sh:
#   1:file  2:status  3:committed_sha  4:expected_sha
# status ∈ { ALIGNED, DRIFTED, MISSING }

EXPECTED="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

setup() {
  # shellcheck source=scripts/template_stub_drift.sh
  source "${BATS_TEST_DIRNAME}/../scripts/template_stub_drift.sh"
}

# ---------------------------------------------------------------------------
# Classification is reused from fleet_stub_drift.sh over the template's set.
# ---------------------------------------------------------------------------

@test "classify_stub_drift is available (sourced from fleet_stub_drift.sh)" {
  run type -t classify_stub_drift
  [ "$output" = "function" ]
}

@test "template stub set: a byte-identical committed file is ALIGNED" {
  run classify_stub_drift "$EXPECTED" "$EXPECTED"
  [ "$status" -eq 0 ]
  [ "$output" = "ALIGNED" ]
}

@test "template stub set: a hand-edited committed file is DRIFTED" {
  run classify_stub_drift "$EXPECTED" "ffffffffffffffffffffffffffffffffffffffff"
  [ "$output" = "DRIFTED" ]
}

@test "template stub set: a missing committed file is MISSING" {
  run classify_stub_drift "$EXPECTED" ""
  [ "$output" = "MISSING" ]
}

# ---------------------------------------------------------------------------
# Covered-file manifest + documented allowlist (AC #2)
# ---------------------------------------------------------------------------

@test "covered set: includes the workflow stubs plus the verbatim baseline" {
  run template_drift_covered
  [ "$status" -eq 0 ]
  # A repinned caller stub, an inline verbatim stub, and each verbatim baseline.
  [[ "$output" == *".github/workflows/dev-lead.yml"* ]]
  [[ "$output" == *".github/workflows/sonarcloud.yml"* ]]
  [[ "$output" == *".github/dependabot.yml"* ]]
  [[ "$output" == *".github/CODEOWNERS"* ]]
  [[ "$output" == *"CLAUDE.md"* ]]
  [[ "$output" == *".gitleaks.toml"* ]]
}

@test "covered set: excludes the allowlisted ci.yml (per-stack customizable)" {
  run template_drift_covered
  [ "$status" -eq 0 ]
  [[ "$output" != *".github/workflows/ci.yml"* ]]
}

@test "template_drift_allowlisted: ci.yml is allowlisted" {
  run template_drift_allowlisted ".github/workflows/ci.yml"
  [ "$status" -eq 0 ]
}

@test "template_drift_allowlisted: a covered stub is NOT allowlisted" {
  run template_drift_allowlisted ".github/workflows/dev-lead.yml"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# template_drift_annotate — emits an annotation per DRIFTED file naming both
# SHAs and fails the job on any drift (AC #1, AC #3).
# ---------------------------------------------------------------------------

@test "annotate: a DRIFTED row emits a ::error:: naming the file and both SHAs, and fails" {
  tsv="$(mktemp)"
  printf '%s\t%s\t%s\t%s\n' ".github/workflows/dev-lead.yml" "ALIGNED" "$EXPECTED" "$EXPECTED" >> "$tsv"
  printf '%s\t%s\t%s\t%s\n' ".github/CODEOWNERS" "DRIFTED" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$EXPECTED" >> "$tsv"
  run template_drift_annotate "$tsv"
  [ "$status" -ne 0 ]                                 # any DRIFTED ⇒ non-zero exit
  [[ "$output" == *"::error"* ]]
  [[ "$output" == *".github/CODEOWNERS"* ]]           # names the drifted file
  [[ "$output" == *"bbbbbbb"* ]]                      # committed SHA (short)
  [[ "$output" == *"aaaaaaa"* ]]                      # expected SHA (short)
  # The ALIGNED file is not reported as an error.
  [[ "$output" != *"dev-lead.yml"* ]]
  rm -f "$tsv"
}

@test "annotate: an all-ALIGNED set passes (exit 0, no error annotation)" {
  tsv="$(mktemp)"
  printf '%s\t%s\t%s\t%s\n' ".github/workflows/dev-lead.yml" "ALIGNED" "$EXPECTED" "$EXPECTED" >> "$tsv"
  printf '%s\t%s\t%s\t%s\n' ".github/dependabot.yml" "ALIGNED" "$EXPECTED" "$EXPECTED" >> "$tsv"
  run template_drift_annotate "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::error"* ]]
  rm -f "$tsv"
}

@test "annotate: an absent TSV passes (nothing to check)" {
  run template_drift_annotate "/nonexistent/drift.tsv"
  [ "$status" -eq 0 ]
}

@test "annotate: MISSING alone does not fail the job (only DRIFTED fails, AC #1)" {
  tsv="$(mktemp)"
  printf '%s\t%s\t%s\t%s\n' "CLAUDE.md" "MISSING" "" "$EXPECTED" >> "$tsv"
  run template_drift_annotate "$tsv"
  [ "$status" -eq 0 ]
  rm -f "$tsv"
}

# ---------------------------------------------------------------------------
# stub_drift_row (reused) classifies a template file end-to-end.
# ---------------------------------------------------------------------------

@test "stub_drift_row: classifies a drifted template file into a 4-field TSV row" {
  run stub_drift_row ".github/CODEOWNERS" "$EXPECTED" "cccccccccccccccccccccccccccccccccccccccc"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '.github/CODEOWNERS\tDRIFTED\tcccccccccccccccccccccccccccccccccccccccc\t%s' "$EXPECTED")" ]
}

# ---------------------------------------------------------------------------
# _template_drift_committed_sha — 404 handling (regression guard: gh api on
# some versions writes the raw 404 JSON to stdout when --jq is not applied
# on error responses; the function must return "" so classify_stub_drift
# yields MISSING rather than DRIFTED).
# ---------------------------------------------------------------------------

@test "_template_drift_committed_sha: 404 response yields empty string, not raw JSON" {
  local stub_bin orig_path
  stub_bin="$(mktemp -d)"
  cat > "$stub_bin/gh" <<'GHEOF'
#!/usr/bin/env bash
# Simulate gh api writing the 404 JSON body to stdout (as observed in CI)
printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/repos/contents#get-repository-content","status":"404"}'
exit 1
GHEOF
  chmod +x "$stub_bin/gh"
  orig_path="$PATH"
  export PATH="$stub_bin:$PATH"
  run _template_drift_committed_sha ".github/workflows/agent-shield.yml"
  export PATH="$orig_path"
  rm -rf "$stub_bin"
  [ "$status" -eq 0 ]
  [ -z "$output" ]  # empty ⇒ classify_stub_drift returns MISSING, not DRIFTED
}
