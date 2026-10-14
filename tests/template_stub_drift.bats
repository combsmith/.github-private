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
# N-1 (immediately-preceding published version) expected blob SHA.
N1="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

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
  [[ "$output" == *".github/CODEOWNERS"* ]]
  [[ "$output" == *"CLAUDE.md"* ]]
  [[ "$output" == *".gitleaks.toml"* ]]
}

@test "covered set: excludes the allowlisted ci.yml (per-stack customizable)" {
  run template_drift_covered
  [ "$status" -eq 0 ]
  [[ "$output" != *".github/workflows/ci.yml"* ]]
}

# ---------------------------------------------------------------------------
# #1726 — the collapsed Class-1 caller agent-ingress.yml gets whole-file
# byte-identity coverage, WITHOUT dropping the per-role stubs so the template
# is guarded in both the pre-collapse and post-collapse states (no hole).
# ---------------------------------------------------------------------------

@test "covered set: includes the collapsed agent-ingress.yml (#1726)" {
  run template_drift_covered
  [ "$status" -eq 0 ]
  [[ "$output" == *".github/workflows/agent-ingress.yml"* ]]
}

@test "covered set: keeps the per-role dev-lead.yml/pr-review-mention.yml rows (backward-compat, #1726)" {
  run template_drift_covered
  [ "$status" -eq 0 ]
  [[ "$output" == *".github/workflows/dev-lead.yml"* ]]
  [[ "$output" == *".github/workflows/pr-review-mention.yml"* ]]
}

@test "agent-ingress.yml is emitted via --emit-workflow (whole-file, offline reference)" {
  local row hit=""
  for row in "${TEMPLATE_DRIFT_FILES[@]}"; do
    case "$row" in
      ".github/workflows/agent-ingress.yml|"*) hit="$row" ;;
    esac
  done
  [ "$hit" = ".github/workflows/agent-ingress.yml|--emit-workflow|agent-ingress.yml" ]
}

@test "template_drift_allowlisted: ci.yml is allowlisted" {
  run template_drift_allowlisted ".github/workflows/ci.yml"
  [ "$status" -eq 0 ]
}

@test "template_drift_allowlisted: a covered stub is NOT allowlisted" {
  run template_drift_allowlisted ".github/workflows/dev-lead.yml"
  [ "$status" -ne 0 ]
}

@test "template_drift_allowlisted: sonarcloud.yml is allowlisted (per-consumer customization, #1448)" {
  run template_drift_allowlisted ".github/workflows/sonarcloud.yml"
  [ "$status" -eq 0 ]
}

@test "template_drift_allowlisted: dependabot.yml is allowlisted (per-consumer customization, #1448)" {
  run template_drift_allowlisted ".github/dependabot.yml"
  [ "$status" -eq 0 ]
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

# ---------------------------------------------------------------------------
# #1448 AC #8 — N / N-1 acceptance: a stub is ALIGNED if it matches the emission
# at either the current published version (N) or the immediately preceding one
# (N-1); an N-1 match is a visible propagation notice, not silent.
# ---------------------------------------------------------------------------

@test "N/N-1 classify: a committed file matching N is ALIGNED, matched N (AC #8)" {
  run template_drift_classify "$EXPECTED" "$EXPECTED" "$N1"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ALIGNED\tN')" ]
}

@test "N/N-1 classify: a committed file matching N-1 is ALIGNED, matched N-1 (AC #8)" {
  run template_drift_classify "$N1" "$EXPECTED" "$N1"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ALIGNED\tN-1')" ]
}

@test "N/N-1 classify: a committed file matching neither N nor N-1 is DRIFTED (AC #8)" {
  run template_drift_classify "ffffffffffffffffffffffffffffffffffffffff" "$EXPECTED" "$N1"
  [[ "$output" == DRIFTED* ]]
}

@test "N/N-1 classify: an empty committed SHA is MISSING" {
  run template_drift_classify "" "$EXPECTED" "$N1"
  [[ "$output" == MISSING* ]]
}

@test "N/N-1 classify: with no N-1 available, only N is accepted (an N-1-shaped SHA is DRIFTED)" {
  run template_drift_classify "$N1" "$EXPECTED" ""
  [[ "$output" == DRIFTED* ]]
}

@test "template_drift_row5: emits a 5-field row tagged with the matched version" {
  run template_drift_row5 "CLAUDE.md" "$N1" "$EXPECTED" "$N1"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'CLAUDE.md\tALIGNED\t%s\t%s\tN-1' "$N1" "$EXPECTED")" ]
}

@test "annotate: an N-1 match is ALIGNED but emits a visible ::notice:: (propagation pending, AC #8)" {
  tsv="$BATS_TEST_TMPDIR/drift.tsv"
  printf '%s\t%s\t%s\t%s\t%s\n' ".github/workflows/dev-lead.yml" "ALIGNED" "$N1" "$EXPECTED" "N-1" >> "$tsv"
  run template_drift_annotate "$tsv"
  [ "$status" -eq 0 ]                                  # N-1 match still passes
  [[ "$output" == *"::notice"* ]]
  [[ "$output" == *".github/workflows/dev-lead.yml"* ]]
  [[ "$output" == *"N-1"* || "$output" == *"preceding"* || "$output" == *"propagation"* ]]
}

@test "annotate: an N match (matched=N) passes with no notice and no error" {
  tsv="$BATS_TEST_TMPDIR/drift.tsv"
  printf '%s\t%s\t%s\t%s\t%s\n' ".github/CODEOWNERS" "ALIGNED" "$EXPECTED" "$EXPECTED" "N" >> "$tsv"
  run template_drift_annotate "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::notice"* ]]
  [[ "$output" != *"::error"* ]]
}

# ---------------------------------------------------------------------------
# #1448 AC #7 — the resolved standards ref + commit SHA are recorded in the
# drift report so a mismatch is explainable rather than mysterious.
# ---------------------------------------------------------------------------

@test "report header: names the resolved standards ref and commit SHA (AC #7)" {
  run template_drift_report_header "standards/v1-stable" "feedfacefeedface0000000000000000" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"standards/v1-stable"* ]]
  [[ "$output" == *"feedface"* ]]
}

@test "report header: notes N-1 acceptance when a previous ref is configured (AC #8)" {
  run template_drift_report_header "standards/v2-stable" "aaaaaaaaaaaa" "standards/v1-stable"
  [ "$status" -eq 0 ]
  [[ "$output" == *"standards/v1-stable"* ]]
  [[ "$output" == *"N-1"* ]]
}

# ---------------------------------------------------------------------------
# #1448 AC #9 — a guard asserts the resolved standards content uses major-scoped
# <name>/v<MAJOR>-<tier> reusable pins, so neither N nor N-1 can reintroduce the
# pre-#1184 legacy channel pins this issue's fix removed.
# ---------------------------------------------------------------------------

@test "major-scoped guard: passes on a major-scoped v<MAJOR>-stable reusable pin (AC #9)" {
  run template_drift_assert_major_scoped "    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-stable"
  [ "$status" -eq 0 ]
}

@test "major-scoped guard: FAILS on a legacy bare-tier reusable pin (AC #9)" {
  run template_drift_assert_major_scoped "    uses: combsmith/.github/.github/workflows/pr-review-mention-reusable.yml@pr-review-mention/stable"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pr-review-mention"* || "$output" == *"legacy"* || "$output" == *"major"* ]]
}

@test "major-scoped guard: inline content with no reusable pin passes (nothing to assert)" {
  run template_drift_assert_major_scoped "$(printf 'name: CI\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n')"
  [ "$status" -eq 0 ]
}

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
