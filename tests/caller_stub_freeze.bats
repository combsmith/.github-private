#!/usr/bin/env bats
# Tests for scripts/caller_stub_freeze.sh — the ring-0 / self-host caller-stub
# freeze guard (#1255, epic #1052 Part B; taught the ingress form in #1725).
#
# It backstops the #1253 validate-caller-inputs check for the self-host caller
# stubs whose reusable lives in this repo and is pinned to a canary channel tag.
# The guard reuses fleet_stub_drift.sh's byte-identity ALIGNED/DRIFTED/MISSING
# model: each frozen block must stay byte-identical to a committed baseline under
# tests/fixtures/caller-stub-freeze/*.block.
#
# #1725 makes the extractor JOB-SCOPED so the guard survives the collapse of the
# per-role stubs into a single multi-job agent-ingress.yml: extract_forwarding_block
# now takes a JOB NAME and captures the shared `on:` block plus THAT job's
# `uses:`/`with:`/`permissions:` sub-blocks (`if:`/`secrets:`/`name:` excluded).
#
# QA test-risk #8: a single parameterised (form, file, job) table drives BOTH the
# legacy per-role stub and the collapsed ingress form, so a new case is answered
# for both or fails to run. Backward-compat (AC #4) is proven by FAILURE, not just
# passing (QA #6): a drifted job flips DRIFTED and the annotation message + job
# name are asserted, so a silent no-op cannot pass.
#
# Run: bats tests/caller_stub_freeze.bats
#
# Drift TSV format is fleet_stub_drift.sh's 4 fields plus a 5th job column added
# here: 1:file  2:status  3:current_sha  4:baseline_sha  5:job
# status ∈ { ALIGNED, DRIFTED, MISSING }

EXPECTED="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  INGRESS="${REPO_ROOT}/tests/fixtures/caller-stub-freeze/ingress/.github/workflows/agent-ingress.yml"
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
# Covered-stub manifest — the three ring-0 self-host caller stubs, now with a
# per-role/per-job granularity (path|job|baseline).
# ---------------------------------------------------------------------------

@test "covered set: lists the three ring-0 self-host caller stubs" {
  run caller_freeze_covered
  [ "$status" -eq 0 ]
  [[ "$output" == *".github/workflows/dev-lead.yml"* ]]
  [[ "$output" == *".github/workflows/pr-review-trigger.yml"* ]]
  [[ "$output" == *".github/workflows/ci-failure-analyst.lock.yml"* ]]
}

# ---------------------------------------------------------------------------
# extract_forwarding_block <file> <job> — JOB-SCOPED. The frozen region is the
# shared `on:` block (including blank lines / column-0 comments before the next
# top-level key, anti-hidden-trigger #1268) plus the NAMED job's `uses:`/`with:`/
# `permissions:` sub-blocks. `if:`/`secrets:`/`name:` are excluded.
# ---------------------------------------------------------------------------

@test "extract (legacy): dev-lead job has the on-trigger, the channel-pinned uses, with, and its permissions" {
  run extract_forwarding_block "${REPO_ROOT}/.github/workflows/dev-lead.yml" "dev-lead"
  [ "$status" -eq 0 ]
  [[ "$output" == on:* ]]
  [[ "$output" == *"pull_request_review:"* ]]
  # Version-agnostic: assert the SHAPE (a dev-lead channel pin forwarded into
  # agent_ref), not a literal version.
  [[ "$output" =~ uses:\ petry-projects/\.github-private/\.github/workflows/dev-lead-reusable\.yml@dev-lead/[A-Za-z0-9._-]+ ]]
  [[ "$output" == *"with:"* ]]
  [[ "$output" =~ agent_ref:\ dev-lead/[A-Za-z0-9._-]+ ]]
  _uses_ref="$(printf '%s\n' "$output" | sed -n 's#.*dev-lead-reusable\.yml@\([^[:space:]]*\).*#\1#p' | head -1)"
  _aref="$(printf '%s\n' "$output" | sed -n 's#.*agent_ref:[[:space:]]*\([^[:space:]]*\).*#\1#p' | head -1)"
  [ -n "$_uses_ref" ] && [ "$_uses_ref" = "$_aref" ]
  # The per-job permissions: block IS now part of the frozen region (#1725) — a
  # silent permission escalation on a channel-pinned job must be caught.
  [[ "$output" == *"contents: write"* ]]
  # secrets: is NOT part of the frozen forwarding region.
  [[ "$output" != *"secrets: inherit"* ]]
}

@test "extract (legacy): pr-review-trigger review job keeps with-forwarding and the on-block separator comment" {
  run extract_forwarding_block "${REPO_ROOT}/.github/workflows/pr-review-trigger.yml" "review"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uses: petry-projects/.github-private/.github/workflows/pr-review.yml@pr-review/v1-next"* ]]
  [[ "$output" == *"force_review: \${{ inputs.force_review || '' }}"* ]]
  # Column-0 comments before the top-level permissions: key stay in the on: block
  # (anti-hidden-trigger). The permissions VALUES are top-level here (not job-level)
  # so they are not part of this job's frozen region.
  [[ "$output" == *"Granted to the called reusable"* ]]
  [[ "$output" != *"secrets: inherit"* ]]
}

@test "extract (legacy): ci-failure-analyst analyze job yields the on block and the channel-pinned uses only" {
  run extract_forwarding_block "${REPO_ROOT}/.github/workflows/ci-failure-analyst.lock.yml" "analyze"
  [ "$status" -eq 0 ]
  [[ "$output" == on:* ]]
  [[ "$output" == *"uses: petry-projects/.github-private/.github/workflows/ci-failure-analyst-reusable.yml@ci-failure-analyst/v1-stable"* ]]
  [[ "$output" != *"with:"* ]]
  # if: and secrets: are excluded from the frozen region.
  [[ "$output" != *"CLAUDE_CODE_OAUTH_TOKEN"* ]]
  [[ "$output" != *"conclusion == 'failure'"* ]]
}

# ---------------------------------------------------------------------------
# Ingress form: one shared on:, one job per role. The extractor must select each
# job independently — this is the collapse the guard has to survive (AC #1).
# ---------------------------------------------------------------------------

@test "extract (ingress): dev-lead job selects its own pin/with/permissions from the multi-job file" {
  run extract_forwarding_block "$INGRESS" "dev-lead"
  [ "$status" -eq 0 ]
  [[ "$output" == on:* ]]
  [[ "$output" == *"uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v139-stable"* ]]
  [[ "$output" == *"agent_ref: dev-lead/v139-stable"* ]]
  [[ "$output" == *"contents: write"* ]]
  # It must NOT bleed into the sibling job's pin.
  [[ "$output" != *"pr-review-mention-reusable.yml"* ]]
  [[ "$output" != *"secrets:"* ]]
}

@test "extract (ingress): pr-review-mention job (no with) selects its own pin/permissions" {
  run extract_forwarding_block "$INGRESS" "pr-review-mention"
  [ "$status" -eq 0 ]
  [[ "$output" == on:* ]]
  [[ "$output" == *"uses: petry-projects/.github/.github/workflows/pr-review-mention-reusable.yml@pr-review-mention/v2-next"* ]]
  [[ "$output" == *"pull-requests: write"* ]]
  [[ "$output" != *"with:"* ]]
  # It must NOT bleed into the sibling dev-lead pin.
  [[ "$output" != *"dev-lead-reusable.yml"* ]]
}

@test "extract: a YAML-quoted \"on\": trigger key is still captured (drift can't hide behind quoting)" {
  # The trigger key may be written quoted (\"on\":/'on':) to dodge YAML 1.1's
  # on->true coercion. If the extractor only matched an unquoted, column-0 on:,
  # the whole trigger block would drop out of the frozen region and a trigger
  # change could slip past the freeze. It must be captured either way.
  work="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/quoted.XXXXXX")"
  cat > "$work/stub.yml" <<'YAML'
"on":
  pull_request_review:
    types: [submitted]

jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-stable
    with:
      agent_ref: dev-lead/v1-stable
YAML
  run extract_forwarding_block "$work/stub.yml" "dev-lead"
  rm -rf "$work"
  [ "$status" -eq 0 ]
  [[ "$output" == '"on":'* ]]
  [[ "$output" == *"pull_request_review:"* ]]
  [[ "$output" == *"dev-lead-reusable.yml@dev-lead/v1-stable"* ]]
}

@test "extract: a named-but-ABSENT job yields an EMPTY block and classifies MISSING, never ALIGNED (#1772)" {
  # Regression for the pre-#1772 bug: the extractor emitted the shared on: block
  # BEFORE checking the job, so an unknown/deleted job produced a non-empty
  # on:-only block that could hash and be frozen ALIGNED — a ring-0 guard passing
  # while checking nothing. An absent job must now yield an EMPTY extraction.
  work="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/absent.XXXXXX")"
  cat > "$work/stub.yml" <<'YAML'
"on":
  pull_request_review:
    types: [submitted]

jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-stable
    with:
      agent_ref: dev-lead/v1-stable
YAML
  # A real baseline frozen from the present job.
  extract_forwarding_block "$work/stub.yml" "dev-lead" > "$work/base.block"
  base="$(caller_freeze_baseline_sha "$work/base.block")"

  # A job that does not exist in the file must extract to EMPTY (not a bare on:).
  run extract_forwarding_block "$work/stub.yml" "no-such-job"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # The empty extraction must classify MISSING against a baseline, not ALIGNED.
  cur="$(caller_freeze_current_sha "$work/stub.yml" "no-such-job")"
  [ -z "$cur" ]
  [ "$(classify_stub_drift "$base" "$cur")" = "MISSING" ]
  rm -rf "$work"
}

# ---------------------------------------------------------------------------
# Parameterised (form, file, job) table — a byte-identical block is ALIGNED and
# repointing the channel flips DRIFTED, for BOTH the legacy stub and each ingress
# job. One table so a new case is answered for both forms.
# ---------------------------------------------------------------------------

freeze_table() {
  # form|file|job|reusable-basename
  cat <<EOF
legacy|${REPO_ROOT}/.github/workflows/dev-lead.yml|dev-lead|dev-lead-reusable.yml
ingress|${INGRESS}|dev-lead|dev-lead-reusable.yml
ingress|${INGRESS}|pr-review-mention|pr-review-mention-reusable.yml
EOF
}

@test "table: each (form, file, job) is ALIGNED with a fresh baseline and DRIFTS when its channel is repointed" {
  local form file job reusable
  while IFS='|' read -r form file job reusable; do
    [ -n "$form" ] || continue
    work="$(mktemp -d "${BATS_TEST_TMPDIR}/tbl.XXXXXX")"
    cp "$file" "$work/stub.yml"

    # Fresh baseline from the pristine block → ALIGNED.
    extract_forwarding_block "$work/stub.yml" "$job" > "$work/base.block"
    [ -s "$work/base.block" ] || { echo "[$form/$job] empty block"; return 1; }
    cur="$(caller_freeze_current_sha "$work/stub.yml" "$job")"
    base="$(caller_freeze_baseline_sha "$work/base.block")"
    if [ "$(classify_stub_drift "$base" "$cur")" != "ALIGNED" ]; then
      echo "[$form/$job] expected ALIGNED"; return 1
    fi

    # Repoint just THIS job's reusable ref → DRIFTED. Derive the current ref so a
    # channel move can't turn the edit into a silent no-op.
    _ref="$(sed -n "s#.*${reusable}@\([^[:space:]]*\).*#\1#p" "$work/stub.yml" | head -1)"
    [ -n "$_ref" ] || { echo "[$form/$job] no ref found"; return 1; }
    sed "s#@${_ref}#@some/other-channel#" "$work/stub.yml" > "$work/stub.yml.tmp"
    mv "$work/stub.yml.tmp" "$work/stub.yml"
    cur2="$(caller_freeze_current_sha "$work/stub.yml" "$job")"
    if [ "$(classify_stub_drift "$base" "$cur2")" != "DRIFTED" ]; then
      echo "[$form/$job] expected DRIFTED after repoint"; return 1
    fi
  done < <(freeze_table)
}

# ---------------------------------------------------------------------------
# A drifted single job in an otherwise-valid multi-job ingress is caught, while
# its sibling stays ALIGNED (AC #5: "a drifted single job is caught").
# ---------------------------------------------------------------------------

@test "ingress: repointing one job drifts only that job; the sibling stays ALIGNED" {
  work="$(mktemp -d "${BATS_TEST_TMPDIR}/one.XXXXXX")"
  cp "$INGRESS" "$work/agent-ingress.yml"

  # Baselines for both jobs from the pristine file.
  extract_forwarding_block "$work/agent-ingress.yml" "dev-lead" > "$work/dev-lead.block"
  extract_forwarding_block "$work/agent-ingress.yml" "pr-review-mention" > "$work/prm.block"
  base_dl="$(caller_freeze_baseline_sha "$work/dev-lead.block")"
  base_prm="$(caller_freeze_baseline_sha "$work/prm.block")"

  # Drift ONLY the dev-lead job's pin.
  sed 's#@dev-lead/v139-stable#@dev-lead/drifted#' "$work/agent-ingress.yml" > "$work/agent-ingress.yml.tmp"
  mv "$work/agent-ingress.yml.tmp" "$work/agent-ingress.yml"

  cur_dl="$(caller_freeze_current_sha "$work/agent-ingress.yml" "dev-lead")"
  cur_prm="$(caller_freeze_current_sha "$work/agent-ingress.yml" "pr-review-mention")"
  [ "$(classify_stub_drift "$base_dl" "$cur_dl")" = "DRIFTED" ]
  [ "$(classify_stub_drift "$base_prm" "$cur_prm")" = "ALIGNED" ]
}

# ---------------------------------------------------------------------------
# caller_freeze_annotate — emits an annotation per DRIFTED/MISSING row naming the
# stub, the JOB, and both SHAs; fails the job on any drift; all-ALIGNED passes.
# Rows carry the 5th job column (#1725).
# ---------------------------------------------------------------------------

@test "annotate: a DRIFTED row emits an ::error:: naming the stub, the job, and both SHAs, and fails" {
  tsv="$(mktemp "${BATS_TEST_TMPDIR}/freeze_tsv.XXXXXX")"
  printf '%s\t%s\t%s\t%s\t%s\n' ".github/workflows/agent-ingress.yml" "ALIGNED" "$EXPECTED" "$EXPECTED" "dev-lead" >> "$tsv"
  printf '%s\t%s\t%s\t%s\t%s\n' ".github/workflows/agent-ingress.yml" "DRIFTED" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$EXPECTED" "pr-review-mention" >> "$tsv"
  run caller_freeze_annotate "$tsv"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error"* ]]
  [[ "$output" == *"agent-ingress.yml"* ]]
  [[ "$output" == *"pr-review-mention"* ]]
  [[ "$output" == *"bbbbbbb"* ]]
  [[ "$output" == *"aaaaaaa"* ]]
  rm -f "$tsv"
}

@test "annotate: an all-ALIGNED set passes (exit 0, no error annotation)" {
  tsv="$(mktemp "${BATS_TEST_TMPDIR}/freeze_tsv.XXXXXX")"
  printf '%s\t%s\t%s\t%s\t%s\n' ".github/workflows/dev-lead.yml" "ALIGNED" "$EXPECTED" "$EXPECTED" "dev-lead" >> "$tsv"
  printf '%s\t%s\t%s\t%s\t%s\n' ".github/workflows/pr-review-trigger.yml" "ALIGNED" "$EXPECTED" "$EXPECTED" "review" >> "$tsv"
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
  printf '%s\t%s\t%s\t%s\t%s\n' ".github/workflows/dev-lead.yml" "MISSING" "" "$EXPECTED" "dev-lead" >> "$tsv"
  run caller_freeze_annotate "$tsv"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error"* ]]
  rm -f "$tsv"
}

# ---------------------------------------------------------------------------
# Live regression: every committed stub's extracted block is byte-identical to
# its committed baseline (ALIGNED). This is the guard's real steady state and
# proves the baselines were regenerated from the current stubs (backward-compat).
# ---------------------------------------------------------------------------

@test "live: every ring-0 caller stub is ALIGNED with its committed baseline" {
  run caller_freeze_check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"DRIFTED"* ]]
}
