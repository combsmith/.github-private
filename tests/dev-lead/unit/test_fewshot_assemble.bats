#!/usr/bin/env bats
# Unit tests for the merged-PR few-shot injection helper (issue #1093,
# epic #1088, Phase 2): scripts/lib/fewshot.sh.
#
# The deep tier is given a few-shot file of past review->merge outcomes so it
# calibrates to what this repo's maintainers actually accept and flag. The
# examples MUST come only from a proposer-visible / dev split — never from
# evals/**/holdout, the set the held-out gate later scores against — and must be
# de-identified (evals/README.md decision A3), opt-in, inert by default, and
# size-bounded so they stay within the ET cost cap.
#
# This suite pins the non-negotiable guarantees:
#   - fewshot_source_is_holdout hard-refuses any evals/**/holdout source path
#     (mirrors the holdout-guard rule);
#   - assemble_fewshot REFUSES a holdout source (never injects held-out cases);
#   - de-identification strips secrets/tokens/hostnames/emails before injection;
#   - the assembled block is bounded by max-examples and max-bytes;
#   - FEWSHOT_FILE is exported and points at the written file;
#   - a missing/empty source degrades to literal "(none)" (inert), exit 0.
#
# Run with: bats tests/dev-lead/unit/test_fewshot_assemble.bats

setup() {
  source "$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/scripts/lib/fewshot.sh"

  # $BATS_TEST_TMPDIR is created per-test and auto-removed on exit (incl. failure),
  # so no manual mktemp -d / rm -rf is needed.
  OUT_FILE="$BATS_TEST_TMPDIR/fewshot.txt"
  SRC="$BATS_TEST_TMPDIR/fewshot.jsonl"

  # Assemble the GitHub-PAT-shaped fixture from fragments at runtime so the literal
  # secret pattern (ghp_ + 16+ chars) never appears contiguously in source — that
  # shape trips secret scanners (gitleaks/SonarCloud) even when the value is fake.
  # The runtime value still matches fewshot_scrub's ghp_ redaction regex, so the
  # scrubbing path is exercised exactly as before.
  local tok_prefix='ghp_'
  FAKE_PAT="${tok_prefix}NOTAREALTOKEN0123456789"

  # A dev-split source line carrying content that MUST be scrubbed before it can
  # reach the reviewer prompt: an email, a GitHub token, an internal hostname.
  cat > "$SRC" << JSONL
{"id":"fs-1","title":"Harden auth token handling","summary":"contact alice@example.com about db01.internal rotation","decision":"escalate","risk":"HIGH","rationale":"leaked ${FAKE_PAT} in a run step"}
{"id":"fs-2","title":"Add formatter tests","summary":"test-only change","decision":"approve","risk":"LOW","rationale":"all gates green"}
JSONL
}

teardown() {
  unset FEWSHOT_FILE FEWSHOT_MAX_EXAMPLES FEWSHOT_MAX_BYTES FAKE_PAT
}

# ---------------------------------------------------------------------------
# Hard holdout guard (Task 3 / AC #2)
# ---------------------------------------------------------------------------

@test "fewshot_source_is_holdout flags an evals/**/holdout path" {
  run fewshot_source_is_holdout "evals/deep-review/holdout/cases.jsonl"
  [ "$status" -eq 0 ]
  run fewshot_source_is_holdout "evals/deep-review/holdout"
  [ "$status" -eq 0 ]
}

@test "fewshot_source_is_holdout passes a dev-split path" {
  run fewshot_source_is_holdout "evals/deep-review/dev/fewshot.jsonl"
  [ "$status" -ne 0 ]
  run fewshot_source_is_holdout "prompts/deep-review.md"
  [ "$status" -ne 0 ]
}

@test "assemble_fewshot REFUSES a holdout source and injects nothing" {
  local holdout="$BATS_TEST_TMPDIR/holdout"
  mkdir -p "$holdout"
  # Give the holdout path a real, non-empty cases file so refusal is proven to
  # come from the path guard, not from an empty/missing source.
  cp "$SRC" "$holdout/cases.jsonl"
  run assemble_fewshot "evals/deep-review/holdout/cases.jsonl" "$OUT_FILE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  # No example content leaked into the output file.
  run grep -q "Harden auth token handling" "$OUT_FILE"
  [ "$status" -ne 0 ]
}

@test "assemble_fewshot REFUSES a dev-split symlink that resolves into holdout" {
  # A lexically-clean dev-split path that is actually a symlink into an
  # evals/**/holdout file must still be refused — the guard resolves the real
  # path before the read that would otherwise follow the link and leak the
  # held-out set.
  mkdir -p "$BATS_TEST_TMPDIR/evals/deep-review/holdout"
  cp "$SRC" "$BATS_TEST_TMPDIR/evals/deep-review/holdout/cases.jsonl"
  ln -s "$BATS_TEST_TMPDIR/evals/deep-review/holdout/cases.jsonl" \
    "$BATS_TEST_TMPDIR/dev-split.jsonl"
  run assemble_fewshot "$BATS_TEST_TMPDIR/dev-split.jsonl" "$OUT_FILE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  run grep -q "Harden auth token handling" "$OUT_FILE"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# De-identification (Task 1 / A3)
# ---------------------------------------------------------------------------

@test "de-identification strips email, token, and internal hostname" {
  run assemble_fewshot "$SRC" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$OUT_FILE" ]
  # The raw sensitive strings must be gone.
  ! grep -q "alice@example.com" "$OUT_FILE" || false
  ! grep -q "$FAKE_PAT" "$OUT_FILE" || false
  ! grep -q "db01.internal" "$OUT_FILE" || false
  # A redaction marker is present in their place.
  grep -q "REDACTED" "$OUT_FILE"
  # Non-sensitive few-shot signal survives (the title / decision is still there).
  grep -q "Harden auth token handling" "$OUT_FILE"
}

@test "fewshot_scrub redacts secrets in an arbitrary string" {
  run fewshot_scrub "reach me at bob@corp.example with token AKIAIOSFODNN7EXAMPLE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"bob@corp.example"* ]]
  [[ "$output" != *"AKIAIOSFODNN7EXAMPLE"* ]]
  [[ "$output" == *"REDACTED"* ]]
}

@test "fewshot_scrub redacts a fine-grained github_pat_ token" {
  # Assemble the token from a prefix fragment so the literal github_pat_ + body
  # shape never appears contiguously in source (keeps secret scanners quiet); the
  # runtime value still exercises fewshot_scrub's github_pat_ redaction rule.
  local fine_prefix='github_pat_'
  local fake_fine_pat="${fine_prefix}11ABCDEF0123456789NOTAREAL0123456789"
  run fewshot_scrub "leaked $fake_fine_pat in a run step"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$fake_fine_pat"* ]]
  [[ "$output" == *"REDACTED"* ]]
}

@test "fewshot_scrub redacts standalone localhost and localhost URLs" {
  run fewshot_scrub "ping localhost then browse http://localhost:8080/admin now"
  [ "$status" -eq 0 ]
  [[ "$output" != *"localhost"* ]]
  [[ "$output" == *"REDACTED"* ]]
}

# ---------------------------------------------------------------------------
# Export + happy path
# ---------------------------------------------------------------------------

@test "FEWSHOT_FILE is exported and points at the written file" {
  assemble_fewshot "$SRC" "$OUT_FILE"
  [ "$FEWSHOT_FILE" = "$OUT_FILE" ]
  [ -f "$FEWSHOT_FILE" ]
}

@test "both dev-split examples render into the block" {
  run assemble_fewshot "$SRC" "$OUT_FILE"
  [ "$status" -eq 0 ]
  grep -q "Harden auth token handling" "$OUT_FILE"
  grep -q "Add formatter tests" "$OUT_FILE"
}

@test "the synthetic seed fixture renders through assemble_fewshot" {
  # The synthetic fs-seed-* examples live under tests/ (a test-only fixture), NOT
  # in the enabled evals/deep-review/dev/fewshot.jsonl dev split — that path is
  # populated only by scripts/evals/extract-fewshot.sh from real merged-PR history.
  local repo_root fixture
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  fixture="$repo_root/tests/dev-lead/fixtures/fewshot-seed.jsonl"
  [ -f "$fixture" ]
  FEWSHOT_MAX_EXAMPLES=3 run assemble_fewshot "$fixture" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^- \[' "$OUT_FILE")" -eq 3 ]
}

# ---------------------------------------------------------------------------
# Bounds (AC #3 — stays within the ET cost cap)
# ---------------------------------------------------------------------------

@test "FEWSHOT_MAX_EXAMPLES caps the number of examples injected" {
  FEWSHOT_MAX_EXAMPLES=1 run assemble_fewshot "$SRC" "$OUT_FILE"
  [ "$status" -eq 0 ]
  grep -q "Harden auth token handling" "$OUT_FILE"
  ! grep -q "Add formatter tests" "$OUT_FILE"
}

@test "the assembled block is truncated to the configured byte cap" {
  FEWSHOT_MAX_BYTES=40 run assemble_fewshot "$SRC" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$OUT_FILE" ]
  [ "$(wc -c < "$OUT_FILE")" -le 40 ]
}

@test "FEWSHOT_MAX_BYTES caps output in BYTES even for multi-byte UTF-8" {
  # A block full of multi-byte characters (é = 2 bytes, 😀 = 4 bytes) must not
  # overrun the byte cap — character-based slicing (${block:0:n}) would let the
  # byte count exceed n. The cap is enforced with head -c, so wc -c must hold.
  printf '%s\n' '{"id":"u1","title":"ééééééééééééé 😀😀😀😀😀😀😀😀","summary":"ünïcödé rätiönälé","decision":"approve","risk":"LOW","rationale":"çà"}' > "$SRC"
  FEWSHOT_MAX_BYTES=40 run assemble_fewshot "$SRC" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$OUT_FILE" ]
  [ "$(wc -c < "$OUT_FILE")" -le 40 ]
}

# ---------------------------------------------------------------------------
# Inert by default (AC #3)
# ---------------------------------------------------------------------------

@test "a missing source writes literal (none) and injects nothing" {
  run assemble_fewshot "$BATS_TEST_TMPDIR/does-not-exist.jsonl" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT_FILE")" = "(none)" ]
}

@test "an empty source writes literal (none)" {
  : > "$BATS_TEST_TMPDIR/empty.jsonl"
  run assemble_fewshot "$BATS_TEST_TMPDIR/empty.jsonl" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT_FILE")" = "(none)" ]
}
