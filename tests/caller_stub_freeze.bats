#!/usr/bin/env bats
# Tests for scripts/caller_stub_freeze.sh — the ring-0 / self-host caller-stub
# freeze guard (#1255, epic #1052 Part B). It backstops the #1253
# validate-caller-inputs check for the specific self-host caller stubs
# (dev-lead.yml, pr-review-trigger.yml, ci-failure-analyst.lock.yml) whose
# reusable lives in this repo and is pinned to a canary channel tag.
#
# The guard reuses fleet_stub_drift.sh's byte-identity (blob-SHA equality)
# ALIGNED/DRIFTED/MISSING model: each stub's trigger (`on:`) + `uses:`/`with:`
# forwarding block must stay byte-identical to a committed baseline under
# tests/fixtures/caller-stub-freeze/*.block. Any edit flips it DRIFTED and fails
# CI unless the baseline is intentionally regenerated (a reviewed channel change).
#
# Most assertions are PURE (synthetic SHAs / in-repo files, no network). Run:
#   bats tests/caller_stub_freeze.bats
#
# Drift TSV format (4 fields, tab-separated), shared with fleet_stub_drift.sh:
#   1:file  2:status  3:current_sha  4:baseline_sha
# status ∈ { ALIGNED, DRIFTED, MISSING }

EXPECTED="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  # shellcheck source=scripts/caller_stub_freeze.sh
  source "${REPO_ROOT}/scripts/caller_stub_freeze.sh"
}

# ---------------------------------------------------------------------------
# Classification reused from fleet_stub_drift.sh over the caller-stub set.
# ---------------------------------------------------------------------------

@test "classify_stub_drift is available (sourced from fleet_stub_drift.sh)" {
  run type -t classify_stub_drift
  [ "$output" = "function" ]
}

@test "caller stub set: a byte-identical block is ALIGNED" {
  run classify_stub_drift "$EXPECTED" "$EXPECTED"
  [ "$status" -eq 0 ]
  [ "$output" = "ALIGNED" ]
}

@test "caller stub set: an edited forwarding block is DRIFTED" {
  run classify_stub_drift "$EXPECTED" "ffffffffffffffffffffffffffffffffffffffff"
  [ "$output" = "DRIFTED" ]
}

@test "caller stub set: a missing/empty block is MISSING" {
  run classify_stub_drift "$EXPECTED" ""
  [ "$output" = "MISSING" ]
}

# ---------------------------------------------------------------------------
# Covered-stub manifest — the three ring-0 self-host caller stubs.
# ---------------------------------------------------------------------------

@test "covered set: lists the three ring-0 self-host caller stubs" {
  run caller_freeze_covered
  [ "$status" -eq 0 ]
  [[ "$output" == *".github/workflows/dev-lead.yml"* ]]
  [[ "$output" == *".github/workflows/pr-review-trigger.yml"* ]]
  [[ "$output" == *".github/workflows/ci-failure-analyst.lock.yml"* ]]
}

# ---------------------------------------------------------------------------
# extract_forwarding_block — the frozen region is the `on:` trigger block
# (including blank lines and column-0 comments before the next top-level key)
# plus the job's `uses:`/`with:` forwarding. Secrets/permissions blocks and
# their values are excluded, but blank/comment separators within the on: zone
# are included to prevent hidden-trigger bypass (#1268).
# ---------------------------------------------------------------------------

@test "extract: dev-lead block has the on trigger, the channel-pinned uses, and with" {
  run extract_forwarding_block "${REPO_ROOT}/.github/workflows/dev-lead.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == on:* ]]
  [[ "$output" == *"pull_request_review:"* ]]
  [[ "$output" == *"uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-stable"* ]]
  [[ "$output" == *"with:"* ]]
  [[ "$output" == *"agent_ref: dev-lead/v1-stable"* ]]
  # The secrets/permissions blocks are NOT part of the frozen forwarding region.
  [[ "$output" != *"secrets: inherit"* ]]
  [[ "$output" != *"contents: write"* ]]
}

@test "extract: pr-review-trigger keeps the with-forwarding and the on-block separator comment" {
  run extract_forwarding_block "${REPO_ROOT}/.github/workflows/pr-review-trigger.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uses: combsmith/.github-private/.github/workflows/pr-review.yml@pr-review/v1-next"* ]]
  [[ "$output" == *"force_review: \${{ inputs.force_review || '' }}"* ]]
  # Column-0 comments before the top-level permissions: key are now included in
  # the frozen block (security fix: prevents hidden-trigger bypass via blank/comment).
  [[ "$output" == *"Granted to the called reusable"* ]]
  # The permissions values themselves are NOT part of the frozen forwarding region.
  [[ "$output" != *"contents: read"* ]]
  [[ "$output" != *"secrets: inherit"* ]]
}

@test "extract: ci-failure-analyst (no with) yields just the on block and the channel-pinned uses" {
  run extract_forwarding_block "${REPO_ROOT}/.github/workflows/ci-failure-analyst.lock.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == on:* ]]
  [[ "$output" == *"uses: combsmith/.github-private/.github/workflows/ci-failure-analyst-reusable.yml@ci-failure-analyst/v1-stable"* ]]
  [[ "$output" != *"with:"* ]]
  [[ "$output" != *"CLAUDE_CODE_OAUTH_TOKEN"* ]]
}

# ---------------------------------------------------------------------------
# caller_freeze_annotate — emits an annotation per DRIFTED stub naming both SHAs
# and fails the job on any drift; MISSING warns only; all-ALIGNED passes.
# ---------------------------------------------------------------------------

@test "annotate: a DRIFTED row emits a ::error:: naming the stub and both SHAs, and fails" {
  tsv="$(mktemp "${BATS_TEST_TMPDIR}/freeze_tsv.XXXXXX")"
  printf '%s\t%s\t%s\t%s\n' ".github/workflows/dev-lead.yml" "ALIGNED" "$EXPECTED" "$EXPECTED" >> "$tsv"
  printf '%s\t%s\t%s\t%s\n' ".github/workflows/pr-review-trigger.yml" "DRIFTED" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$EXPECTED" >> "$tsv"
  run caller_freeze_annotate "$tsv"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error"* ]]
  [[ "$output" == *"pr-review-trigger.yml"* ]]
  [[ "$output" == *"bbbbbbb"* ]]
  [[ "$output" == *"aaaaaaa"* ]]
  [[ "$output" != *"::error"*"dev-lead.yml"* ]]
  rm -f "$tsv"
}

@test "annotate: an all-ALIGNED set passes (exit 0, no error annotation)" {
  tsv="$(mktemp "${BATS_TEST_TMPDIR}/freeze_tsv.XXXXXX")"
  printf '%s\t%s\t%s\t%s\n' ".github/workflows/dev-lead.yml" "ALIGNED" "$EXPECTED" "$EXPECTED" >> "$tsv"
  printf '%s\t%s\t%s\t%s\n' ".github/workflows/pr-review-trigger.yml" "ALIGNED" "$EXPECTED" "$EXPECTED" >> "$tsv"
  run caller_freeze_annotate "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::error"* ]]
  rm -f "$tsv"
}

@test "annotate: an absent TSV passes (nothing to check)" {
  run caller_freeze_annotate "/nonexistent/freeze.tsv"
  [ "$status" -eq 0 ]
}

@test "annotate: a MISSING row fails the job (ring-0 stubs must have an extractable block)" {
  tsv="$(mktemp "${BATS_TEST_TMPDIR}/freeze_tsv.XXXXXX")"
  printf '%s\t%s\t%s\t%s\n' ".github/workflows/dev-lead.yml" "MISSING" "" "$EXPECTED" >> "$tsv"
  run caller_freeze_annotate "$tsv"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error"* ]]
  rm -f "$tsv"
}

# ---------------------------------------------------------------------------
# stub_drift_row (reused) classifies a caller stub end-to-end into a TSV row.
# ---------------------------------------------------------------------------

@test "stub_drift_row: classifies a drifted caller stub into a 4-field TSV row" {
  run stub_drift_row ".github/workflows/dev-lead.yml" "$EXPECTED" "cccccccccccccccccccccccccccccccccccccccc"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '.github/workflows/dev-lead.yml\tDRIFTED\tcccccccccccccccccccccccccccccccccccccccc\t%s' "$EXPECTED")" ]
}

# ---------------------------------------------------------------------------
# Live regression: every committed stub's extracted block is byte-identical to
# its committed baseline (ALIGNED). This is the guard's real steady state and
# also proves the baselines were generated from the current stubs.
# ---------------------------------------------------------------------------

@test "live: every ring-0 caller stub is ALIGNED with its committed baseline" {
  run caller_freeze_check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"DRIFTED"* ]]
}

# ---------------------------------------------------------------------------
# Acceptance (#1255): editing a frozen block fails; a regenerated baseline
# passes. Exercised against a scratch copy so the repo's real stubs/baselines
# are untouched.
# ---------------------------------------------------------------------------

@test "acceptance: editing a frozen block fails, regenerating the baseline passes" {
  work="$(mktemp -d "${BATS_TEST_TMPDIR}/work.XXXXXX")"
  mkdir -p "$work/.github/workflows" "$work/tests/fixtures/caller-stub-freeze"
  cp "${REPO_ROOT}/.github/workflows/dev-lead.yml" "$work/.github/workflows/dev-lead.yml"

  # Seed a baseline from the pristine stub, then confirm it is ALIGNED.
  extract_forwarding_block "$work/.github/workflows/dev-lead.yml" \
    > "$work/tests/fixtures/caller-stub-freeze/dev-lead.block"
  cur="$(caller_freeze_current_sha "$work/.github/workflows/dev-lead.yml")"
  base="$(caller_freeze_baseline_sha "$work/tests/fixtures/caller-stub-freeze/dev-lead.block")"
  [ "$(classify_stub_drift "$base" "$cur")" = "ALIGNED" ]

  # Edit the frozen forwarding block (repoint the channel) → DRIFTED.
  sed 's#@dev-lead/v1-stable#@dev-lead/next#' "$work/.github/workflows/dev-lead.yml" \
    > "$work/.github/workflows/dev-lead.yml.tmp"
  mv "$work/.github/workflows/dev-lead.yml.tmp" "$work/.github/workflows/dev-lead.yml"
  cur2="$(caller_freeze_current_sha "$work/.github/workflows/dev-lead.yml")"
  [ "$(classify_stub_drift "$base" "$cur2")" = "DRIFTED" ]

  # Intentional, reviewed baseline update → ALIGNED again.
  extract_forwarding_block "$work/.github/workflows/dev-lead.yml" \
    > "$work/tests/fixtures/caller-stub-freeze/dev-lead.block"
  base2="$(caller_freeze_baseline_sha "$work/tests/fixtures/caller-stub-freeze/dev-lead.block")"
  [ "$(classify_stub_drift "$base2" "$cur2")" = "ALIGNED" ]
}
