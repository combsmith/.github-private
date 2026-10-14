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
# template_drift_row5 adds a 5th field (matched) and the AHEAD status (#1926).

EXPECTED="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
# N-1 (immediately-preceding published version) expected blob SHA.
N1="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
# Blob SHA of the emission at the standards default-branch HEAD (#1926).
HEAD_BLOB="cccccccccccccccccccccccccccccccccccccccc"
# A committed blob that matches no standards emission (a hand edit).
HAND_EDIT="ffffffffffffffffffffffffffffffffffffffff"

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
# #1729 (AC #12) — reference rows: agent-ingress.yml is enrolled as an EXPECTED
# file for post-collapse byte-identity coverage, but seed-repo-template.sh
# deliberately never seeds it into repo-template until a pilot repo collapses
# (it lives in the --emit-workflow-only REFERENCE_MANIFEST). A MISSING reference
# row must therefore NOT print the generic "re-seed via seed-repo-template.sh"
# remedy — that remedy can never clear the warning and points maintainers at a
# premature live ingress. It gets a distinct, non-actionable notice instead.
# ---------------------------------------------------------------------------

@test "template_drift_is_reference: agent-ingress.yml is a reference row (#1729)" {
  run template_drift_is_reference ".github/workflows/agent-ingress.yml"
  [ "$status" -eq 0 ]
}

@test "template_drift_is_reference: a normal covered stub is NOT a reference row (#1729)" {
  run template_drift_is_reference ".github/workflows/dev-lead.yml"
  [ "$status" -eq 1 ]
}

@test "annotate: a MISSING reference row does NOT print the generic re-seed remedy and does not fail (#1729)" {
  tsv="$(mktemp)"
  printf '%s\t%s\t%s\t%s\n' ".github/workflows/agent-ingress.yml" "MISSING" "" "$EXPECTED" >> "$tsv"
  run template_drift_annotate "$tsv"
  [ "$status" -eq 0 ]
  # Non-actionable: the generic re-seed remedy must not appear for a reference row.
  [[ "$output" != *"re-seed via scripts/seed-repo-template.sh"* ]]
  # It is still surfaced, but as a non-actionable notice naming this story.
  [[ "$output" == *"::notice"* ]]
  [[ "$output" == *"agent-ingress.yml"* ]]
  [[ "$output" == *"1729"* ]]
  rm -f "$tsv"
}

@test "annotate: a MISSING non-reference row still prints the generic re-seed remedy (#1729 regression)" {
  tsv="$(mktemp)"
  printf '%s\t%s\t%s\t%s\n' "CLAUDE.md" "MISSING" "" "$EXPECTED" >> "$tsv"
  run template_drift_annotate "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"re-seed via scripts/seed-repo-template.sh"* ]]
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
# #1926 — AHEAD: a committed file that matches neither N nor N-1 but DOES match
# the emission at the standards default-branch HEAD is ahead of the published
# channel. It is not drift, and the re-seed remedy would regress it, so it gets
# its own status, its own message (promote standards), and does not fail the job.
# The five outcomes (AC #4): ALIGNED (N), ALIGNED (N-1), AHEAD, DRIFTED, MISSING.
# ---------------------------------------------------------------------------

@test "AHEAD classify: a committed file matching N is ALIGNED (N), HEAD given (#1926)" {
  run template_drift_classify "$EXPECTED" "$EXPECTED" "$N1" "$HEAD_BLOB"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ALIGNED\tN')" ]
}

@test "AHEAD classify: a committed file matching N-1 is ALIGNED (N-1), HEAD given (#1926)" {
  run template_drift_classify "$N1" "$EXPECTED" "$N1" "$HEAD_BLOB"
  [ "$output" = "$(printf 'ALIGNED\tN-1')" ]
}

@test "AHEAD classify: a committed file matching only the HEAD emission is AHEAD (#1926)" {
  run template_drift_classify "$HEAD_BLOB" "$EXPECTED" "$N1" "$HEAD_BLOB"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'AHEAD\tHEAD')" ]
}

@test "AHEAD classify: AHEAD needs no N-1 ref (#1926)" {
  run template_drift_classify "$HEAD_BLOB" "$EXPECTED" "" "$HEAD_BLOB"
  [ "$output" = "$(printf 'AHEAD\tHEAD')" ]
}

@test "AHEAD classify: a committed file matching none of N, N-1, HEAD is DRIFTED (#1926)" {
  run template_drift_classify "$HAND_EDIT" "$EXPECTED" "$N1" "$HEAD_BLOB"
  [ "$output" = "$(printf 'DRIFTED\t')" ]
}

@test "AHEAD classify: an empty committed SHA is MISSING even with a HEAD emission (#1926)" {
  run template_drift_classify "" "$EXPECTED" "$N1" "$HEAD_BLOB"
  [ "$output" = "$(printf 'MISSING\t')" ]
}

@test "AHEAD classify: N wins when the channel already is HEAD — never AHEAD (#1926)" {
  run template_drift_classify "$EXPECTED" "$EXPECTED" "" "$EXPECTED"
  [ "$output" = "$(printf 'ALIGNED\tN')" ]
}

@test "AHEAD classify: an uncomputable HEAD emission leaves DRIFTED tagged ahead-unchecked (#1926)" {
  run template_drift_classify "$HAND_EDIT" "$EXPECTED" "$N1" "unknown"
  [ "$output" = "$(printf 'DRIFTED\tahead-unchecked')" ]
}

@test "AHEAD classify: an uncomputable HEAD emission never downgrades an ALIGNED file (#1926)" {
  run template_drift_classify "$EXPECTED" "$EXPECTED" "$N1" "unknown"
  [ "$output" = "$(printf 'ALIGNED\tN')" ]
}

@test "template_drift_row5: an AHEAD file gets a row tagged matched=HEAD (#1926)" {
  run template_drift_row5 ".github/workflows/agent-shield.yml" "$HEAD_BLOB" "$EXPECTED" "$N1" "$HEAD_BLOB"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '.github/workflows/agent-shield.yml\tAHEAD\t%s\t%s\tHEAD' "$HEAD_BLOB" "$EXPECTED")" ]
}

@test "annotate: an AHEAD row warns, points at promotion, and does NOT fail (#1926 AC #2/#3)" {
  tsv="$BATS_TEST_TMPDIR/drift.tsv"
  printf '%s\t%s\t%s\t%s\t%s\n' ".github/workflows/agent-shield.yml" "AHEAD" "$HEAD_BLOB" "$EXPECTED" "HEAD" >> "$tsv"
  run template_drift_annotate "$tsv" "standards/v1-stable" "1234567890abcdef1234567890abcdef12345678"
  [ "$status" -eq 0 ]                                   # a propagation lag, not corruption
  [[ "$output" == *"::warning file=.github/workflows/agent-shield.yml::"* ]]
  [[ "$output" != *"::error"* ]]
  [[ "$output" == *'is ahead of `standards/v1-stable`'* ]]
  [[ "$output" == *"cut-standards-release.sh"* ]]
  [[ "$output" == *"instead of re-seeding"* ]]
  [[ "$output" == *"1234567890ab"* ]]                   # the standards HEAD commit
  # The DRIFTED remedy must never be printed for an AHEAD file.
  [[ "$output" != *"Re-seed it via scripts/seed-repo-template.sh"* ]]
  [[ "$output" != *"has DRIFTED"* ]]
}

@test "annotate: an AHEAD row names the default channel when no ref is passed (#1926)" {
  tsv="$BATS_TEST_TMPDIR/drift.tsv"
  printf '%s\t%s\t%s\t%s\t%s\n' "CLAUDE.md" "AHEAD" "$HEAD_BLOB" "$EXPECTED" "HEAD" >> "$tsv"
  run template_drift_annotate "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *'is ahead of `standards/v1-stable`'* ]]
}

@test "annotate: AHEAD beside a real DRIFTED file still fails, each with its own remedy (#1926)" {
  tsv="$BATS_TEST_TMPDIR/drift.tsv"
  printf '%s\t%s\t%s\t%s\t%s\n' ".github/workflows/agent-shield.yml" "AHEAD" "$HEAD_BLOB" "$EXPECTED" "HEAD" >> "$tsv"
  printf '%s\t%s\t%s\t%s\t%s\n' ".github/CODEOWNERS" "DRIFTED" "$HAND_EDIT" "$EXPECTED" "" >> "$tsv"
  run template_drift_annotate "$tsv" "standards/v1-stable"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::warning file=.github/workflows/agent-shield.yml::"* ]]
  [[ "$output" == *"::error file=.github/CODEOWNERS::"*"Re-seed it via scripts/seed-repo-template.sh"* ]]
  [[ "$output" != *"::error file=.github/workflows/agent-shield.yml"* ]]
}

@test "annotate: a DRIFTED row tagged ahead-unchecked fails WITHOUT the bare re-seed remedy (#1926)" {
  tsv="$BATS_TEST_TMPDIR/drift.tsv"
  printf '%s\t%s\t%s\t%s\t%s\n' ".github/CODEOWNERS" "DRIFTED" "$HAND_EDIT" "$EXPECTED" "ahead-unchecked" >> "$tsv"
  run template_drift_annotate "$tsv" "standards/v1-stable"
  [ "$status" -ne 0 ]                                   # still drift until proven otherwise
  [[ "$output" == *"::error file=.github/CODEOWNERS::"* ]]
  [[ "$output" == *"could NOT be compared against standards HEAD"* ]]
  [[ "$output" == *"STANDARDS_REF="* ]]
  [[ "$output" != *"Re-seed it via scripts/seed-repo-template.sh"* ]]
}

@test "report header: names the standards HEAD commit used for AHEAD detection (#1926)" {
  run template_drift_report_header "standards/v1-stable" "feedfacefeedface0000000000000000" "" "1234567890abcdef1234567890abcdef12345678"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1234567890ab"* ]]
  [[ "$output" == *"AHEAD"* ]]
}

@test "report header: says nothing about AHEAD when the channel already is HEAD (#1926)" {
  run template_drift_report_header "standards/v1-stable" "feedfacefeedface0000000000000000" ""
  [[ "$output" != *"AHEAD"* ]]
}

@test "_template_drift_head_sha: a 40-hex SHA is returned as-is (#1926)" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nprintf "1234567890abcdef1234567890abcdef12345678"\n' > "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run _template_drift_head_sha
  [ "$status" -eq 0 ]
  [ "$output" = "1234567890abcdef1234567890abcdef12345678" ]
}

@test "_template_drift_head_sha: an API error body yields empty, never a bogus ref (#1926)" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nprintf "{\\"message\\":\\"API rate limit exceeded\\",\\"status\\":\\"403\\"}"\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run _template_drift_head_sha
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# #1926 — the driver, end to end, with the four network seams replaced. The
# "template" below holds one file in each of the five states. Emissions are the
# string "<name>@<ref>", so a file's blob SHA says which standards ref it matches.
# ---------------------------------------------------------------------------

DRV_N_SHA="1111111111111111111111111111111111111111"
DRV_HEAD_SHA="2222222222222222222222222222222222222222"

# _drv_stub <head_sha> — replace main's network seams. <head_sha> is what the
# standards default-branch HEAD resolves to ("" = unresolvable).
_drv_stub() {
  DRV_HEAD="$1"
  DRV_EMIT_LOG="$BATS_TEST_TMPDIR/emit.log"
  : > "$DRV_EMIT_LOG"
  export STANDARDS_PREV_REF="prev-ref"
  _template_drift_resolve_ref() { printf '%s\t%s\t%s\n' "standards/v1-stable" "$DRV_N_SHA" "channel"; }
  _template_drift_head_sha() { printf '%s' "$DRV_HEAD"; }
  _template_drift_emit() {
    printf '%s@%s\n' "$2" "$3" >> "$DRV_EMIT_LOG"
    [ "${DRV_EMIT_FAIL:-}" = "$3" ] && return 1
    printf '%s@%s' "$2" "$3"
  }
  _template_drift_committed_sha() {
    local name ref
    case "$1" in
      .github/workflows/*) name="${1##*/}" ;;
      *) name="$1" ;;
    esac
    case "$1" in
      .github/workflows/agent-shield.yml)         ref="$DRV_HEAD_SHA" ;;        # AHEAD
      .github/workflows/copilot-setup-steps.yml)  ref="prev-ref" ;;             # ALIGNED (N-1)
      .github/workflows/dependabot-automerge.yml) ref="${DRV_HAND_EDIT_REF:-hand-edited}" ;;  # DRIFTED
      CLAUDE.md)                                  return 0 ;;                   # MISSING
      *)                                          ref="standards/v1-stable" ;;  # ALIGNED (N)
    esac
    printf '%s@%s' "$name" "$ref" | git hash-object --stdin
  }
}

# _drv_row <path> — the "<status>\t<matched>" of <path> in the driver's output.
_drv_row() {
  printf '%s\n' "$output" | awk -F'\t' -v p="$1" '$1 == p { printf "%s\t%s", $2, $5 }'
}

@test "driver: one file in each state — AHEAD is told apart from DRIFTED (#1926 AC #1/#4)" {
  _drv_stub "$DRV_HEAD_SHA"
  run main
  [ "$status" -ne 0 ]                                   # the one DRIFTED file fails it
  [ "$(_drv_row .github/workflows/auto-rebase.yml)" = "$(printf 'ALIGNED\tN')" ]
  [ "$(_drv_row .github/workflows/copilot-setup-steps.yml)" = "$(printf 'ALIGNED\tN-1')" ]
  [ "$(_drv_row .github/workflows/agent-shield.yml)" = "$(printf 'AHEAD\tHEAD')" ]
  [ "$(_drv_row .github/workflows/dependabot-automerge.yml)" = "$(printf 'DRIFTED\t')" ]
  [ "$(_drv_row CLAUDE.md)" = "$(printf 'MISSING\t')" ]
  [[ "$output" == *"::warning file=.github/workflows/agent-shield.yml::"*'is ahead of `standards/v1-stable`'* ]]
  [[ "$output" == *"::error file=.github/workflows/dependabot-automerge.yml::"* ]]
  [[ "$output" != *"::error file=.github/workflows/agent-shield.yml"* ]]
}

@test "driver: only would-be DRIFTED files pay for a HEAD emission (#1926 AC #1)" {
  _drv_stub "$DRV_HEAD_SHA"
  run main
  run grep "@${DRV_HEAD_SHA}\$" "$DRV_EMIT_LOG"
  [ "$output" = "$(printf 'agent-shield.yml@%s\ndependabot-automerge.yml@%s' "$DRV_HEAD_SHA" "$DRV_HEAD_SHA")" ]
}

@test "driver: an AHEAD-only template passes with a warning (#1926 AC #3)" {
  _drv_stub "$DRV_HEAD_SHA"
  # Same template, minus the hand edit: nothing is DRIFTED, one file is AHEAD.
  DRV_HAND_EDIT_REF="standards/v1-stable"
  run main
  [ "$status" -eq 0 ]
  [ "$(_drv_row .github/workflows/agent-shield.yml)" = "$(printf 'AHEAD\tHEAD')" ]
  [[ "$output" == *"::warning file=.github/workflows/agent-shield.yml::"* ]]
  [[ "$output" != *"::error"* ]]
}

@test "driver: when the channel already is HEAD nothing is AHEAD and no HEAD emission is made (#1926)" {
  _drv_stub "$DRV_N_SHA"
  run main
  [ "$status" -ne 0 ]
  # With nothing newer than N, a file that matches only some other ref is plain drift.
  [ "$(_drv_row .github/workflows/agent-shield.yml)" = "$(printf 'DRIFTED\t')" ]
  [[ "$output" == *"::error file=.github/workflows/agent-shield.yml::"*"Re-seed it via"* ]]
  run grep -c "@${DRV_HEAD_SHA}\$" "$DRV_EMIT_LOG"
  [ "$output" = "0" ]
}

@test "driver: an unresolvable standards HEAD is named, and DRIFTED is tagged ahead-unchecked (#1926)" {
  _drv_stub ""
  run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"::warning::Could not resolve the standards default-branch HEAD commit"* ]]
  [ "$(_drv_row .github/workflows/agent-shield.yml)" = "$(printf 'DRIFTED\tahead-unchecked')" ]
  [[ "$output" == *"::error file=.github/workflows/agent-shield.yml::"*"could NOT be compared against standards HEAD"* ]]
  [[ "$output" != *"Re-seed it via scripts/seed-repo-template.sh"* ]]
  # Files that match the channel are unaffected by the failed lookup.
  [ "$(_drv_row .github/workflows/auto-rebase.yml)" = "$(printf 'ALIGNED\tN')" ]
}

@test "driver: a failed HEAD emission for one file is named and tags only that file (#1926)" {
  _drv_stub "$DRV_HEAD_SHA"
  DRV_EMIT_FAIL="$DRV_HEAD_SHA"
  run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"::warning::Could not compute the standards HEAD emission for .github/workflows/agent-shield.yml"* ]]
  [ "$(_drv_row .github/workflows/agent-shield.yml)" = "$(printf 'DRIFTED\tahead-unchecked')" ]
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
