#!/usr/bin/env bats
# Tests for scripts/lib/miss-harvest.sh — harvests accepted pr-review misses
# (issue #1596) into evals/deep-review/dev/cases.jsonl as regression cases.
#
# HARD INVARIANT under test: harvested cases go to dev/ ONLY. The harvester must
# refuse to write any holdout/ path — auto-harvesting into holdout/ would destroy
# the held-out guarantee (#1088). It must also de-identify the case before it is
# written (evals/README.md decision A3).
#
# Run locally: bats tests/test_miss_harvest.bats

setup() {
  # shellcheck source=scripts/lib/miss-harvest.sh
  source "${BATS_TEST_DIRNAME}/../scripts/lib/miss-harvest.sh"
  # $BATS_TEST_TMPDIR is created per-test and auto-removed on exit (incl. failure).
  TMP="$BATS_TEST_TMPDIR"
  # Assemble the GitHub-PAT-shaped fixture from fragments at runtime so the literal
  # secret pattern (ghp_ + 16+ chars) never appears contiguously in source — that
  # shape trips secret scanners (SonarCloud/gitleaks) even when the value is fake.
  # The assembled runtime value still matches _mh_deidentify's ghp_ redaction regex,
  # so the scrubbing path is exercised exactly as before.
  local tok_prefix='ghp_'
  local fake_pat="${tok_prefix}NOTAREALTOKEN1234"
  MISS="{\"repo\":\"petry-projects/.github\",\"pr\":\"https://github.com/petry-projects/.github/pull/995\",\"bot\":\"coderabbitai\",\"finding\":\"ADR asserts a rolling 5-hour window while also asserting utilization is monotonic — a self-contradiction. cc @don-petry https://internal.example.com/x token ${fake_pat}\"}"
}

# ---------------------------------------------------------------------------
# The dev-only invariant — the harvester CANNOT write a holdout/ path
# ---------------------------------------------------------------------------

@test "mh_assert_dev_path: rejects a holdout/ path" {
  run mh_assert_dev_path "evals/deep-review/holdout/cases.jsonl"
  [ "$status" -ne 0 ]
}

@test "mh_assert_dev_path: accepts a dev/ path" {
  run mh_assert_dev_path "evals/deep-review/dev/cases.jsonl"
  [ "$status" -eq 0 ]
}

@test "mh_assert_dev_path: rejects a path that is neither dev/ nor holdout/" {
  run mh_assert_dev_path "/tmp/somewhere/cases.jsonl"
  [ "$status" -ne 0 ]
}

@test "mh_assert_dev_path: rejects a dev/ path with a .. traversal component" {
  # A lexical dev/ match is defeated by '..' that resolves outside the dev split.
  run mh_assert_dev_path "evals/deep-review/dev/../../../README.md"
  [ "$status" -ne 0 ]
}

@test "mh_harvest: refuses a dev/ target that escapes via .. and writes nothing" {
  target="$TMP/dev/../escape.jsonl"
  mkdir -p "$TMP/dev"
  run mh_harvest "$MISS" "$target"
  [ "$status" -ne 0 ]
  [ ! -f "$TMP/escape.jsonl" ]
}

@test "mh_harvest: refuses to write when handed a holdout/ target and writes nothing" {
  target="$TMP/holdout/cases.jsonl"
  mkdir -p "$TMP/holdout"
  run mh_harvest "$MISS" "$target"
  [ "$status" -ne 0 ]
  [ ! -f "$target" ]
}

@test "mh_harvest: appends a valid JSONL case to a dev/ target" {
  target="$TMP/dev/cases.jsonl"
  mkdir -p "$TMP/dev"
  run mh_harvest "$MISS" "$target"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  # Exactly one line, and it is valid JSON carrying a non-empty id.
  [ "$(wc -l < "$target")" -eq 1 ]
  run jq -e '.id | type == "string" and length > 0' "$target"
  [ "$status" -eq 0 ]
}

@test "mh_harvest: harvesting the same miss twice is idempotent (no duplicate case)" {
  target="$TMP/dev/cases.jsonl"
  mkdir -p "$TMP/dev"
  run mh_harvest "$MISS" "$target"
  [ "$status" -eq 0 ]
  run mh_harvest "$MISS" "$target"
  [ "$status" -eq 0 ]
  # The stable id is checked against the file, so the second harvest is a no-op.
  [ "$(wc -l < "$target")" -eq 1 ]
}

@test "mh_harvest: concurrent harvests of the same miss write the case only once" {
  target="$TMP/dev/cases.jsonl"
  mkdir -p "$TMP/dev"
  # Fire several harvesters of the same miss in parallel. The flock-guarded
  # recheck+append must let exactly one writer win — without the lock two
  # processes both see the id absent and both append a duplicate.
  for _ in 1 2 3 4 5 6 7 8; do
    mh_harvest "$MISS" "$target" &
  done
  wait
  [ -f "$target" ]
  [ "$(wc -l < "$target")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# De-identification (evals/README.md decision A3)
# ---------------------------------------------------------------------------

@test "mh_build_case: strips URLs, @mentions and token-like strings" {
  run mh_build_case "$MISS"
  [ "$status" -eq 0 ]
  # No raw URL, @mention, or ghp_ token survives into the committed case.
  ! grep -q "https://" <<<"$output"
  ! grep -q "@don-petry" <<<"$output"
  ! grep -q "ghp_" <<<"$output"
  # Still valid JSON with the expected shape.
  run jq -e '.id and .input and .expected' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "mh_build_case: id is stable for the same finding (idempotent harvest key)" {
  a="$(mh_build_case "$MISS" | jq -r '.id')"
  b="$(mh_build_case "$MISS" | jq -r '.id')"
  [ "$a" = "$b" ]
  [ -n "$a" ]
}
