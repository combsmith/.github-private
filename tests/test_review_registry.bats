#!/usr/bin/env bats
# Unit tests for the rubric-registry lookup helper in
# scripts/lib/review-registry.sh (issue #611).
#
# The registry is an input-adapter layer ABOVE engine.sh: it maps an
# artifact_type to the rubric (prompt cascade) and output_channel that should
# review it. Phase 1 registers only pr_diff, which must resolve to today's
# behavior with no change.
#
# Run with: bats tests/test_review_registry.bats
# Install bats: https://github.com/bats-core/bats-core

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$REPO_ROOT/scripts/lib/review-registry.sh"
  POST_SCRIPT="$REPO_ROOT/scripts/post-pr-review.sh"
  VERDICT_FILE="$BATS_TEST_TMPDIR/verdict.json"

  # Gate 4 (#1766) enumerates the PR's review threads for any approve verdict —
  # including under DRY_RUN, so a dry run faithfully previews the real downgrade.
  # These contract tests must stay hermetic (no real network), so stub gh with a
  # clean, fully-enumerated, zero-unresolved thread set: gate 4 clears and the
  # verdict is surfaced unchanged, exactly as these contracts intend.
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/bin/bash
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  case "$*" in
    *reviewThreads*) printf '%s' '{"data":{"resource":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' ;;
    *)               echo "Unmapped graphql query: $*" >&2; exit 1 ;;
  esac
  exit 0
fi
echo "Unmapped gh command: $*" >&2
exit 1
GHEOF
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
}

# write_verdict <decision> <risk> [body]
#   Materializes a verdict JSON in the pr_diff output_channel's documented shape
#   (see scripts/post-pr-review.sh header) for the marker/verdict guard below.
write_verdict() {
  local decision="$1" risk="$2" body="${3:-test review body}"
  jq -n --arg d "$decision" --arg r "$risk" --arg b "$body" \
    '{decision: $d, risk: $r, summary: "s", findings: [], body: $b}' > "$VERDICT_FILE"
}

# ---------------------------------------------------------------------------
# Schema version
# ---------------------------------------------------------------------------

@test "reports a non-empty integer schema version" {
  run review_registry_version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

# ---------------------------------------------------------------------------
# Registered types — pr_diff stays registered (AC #2). Phase 2 (#614) added
# plan_json additively; this guard pins that pr_diff is never removed or
# renamed, not that it is the sole type.
# ---------------------------------------------------------------------------

@test "pr_diff is registered" {
  run review_registry_types
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "pr_diff"
}

# ---------------------------------------------------------------------------
# Lookup — rubric resolves to the existing cascade (AC #3)
# ---------------------------------------------------------------------------

@test "pr_diff rubric resolves to the triage -> deep-review -> synthesize cascade" {
  run review_registry_lookup pr_diff rubric
  [ "$status" -eq 0 ]
  [ "$output" = "prompts/triage.md,prompts/deep-review.md,prompts/synthesize.md" ]
}

@test "pr_diff output_channel resolves to post-pr-review.sh" {
  run review_registry_lookup pr_diff output_channel
  [ "$status" -eq 0 ]
  [ "$output" = "scripts/post-pr-review.sh" ]
}

# ---------------------------------------------------------------------------
# Lookup errors — unknown type / field fail non-zero
# ---------------------------------------------------------------------------

@test "unknown artifact_type fails non-zero" {
  run review_registry_lookup plan rubric
  [ "$status" -ne 0 ]
}

@test "unknown field fails non-zero" {
  run review_registry_lookup pr_diff not_a_field
  [ "$status" -ne 0 ]
}

@test "missing artifact_type argument fails non-zero" {
  run review_registry_lookup
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# The registry references TODAY's cascade, not a copy (AC #3): every
# referenced rubric file and the output_channel must exist on disk.
# ---------------------------------------------------------------------------

@test "every referenced rubric file exists" {
  run review_registry_lookup pr_diff rubric
  [ "$status" -eq 0 ]
  IFS=',' read -ra rubric_files <<< "$output"
  [ "${#rubric_files[@]}" -gt 0 ]
  for f in "${rubric_files[@]}"; do
    [ -f "$REPO_ROOT/$f" ] || { echo "missing rubric file: $f"; false; }
  done
}

@test "referenced output_channel exists" {
  run review_registry_lookup pr_diff output_channel
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/$output" ]
}

# ---------------------------------------------------------------------------
# Defensive: missing manifest — all three functions fail cleanly
# ---------------------------------------------------------------------------

@test "review_registry_version fails with clear message when manifest is missing" {
  REVIEW_REGISTRY_MANIFEST="/nonexistent/review-registry.tsv" run review_registry_version
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest file not found"* ]]
}

@test "review_registry_types fails with clear message when manifest is missing" {
  REVIEW_REGISTRY_MANIFEST="/nonexistent/review-registry.tsv" run review_registry_types
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest file not found"* ]]
}

@test "review_registry_lookup fails with clear message when manifest is missing" {
  REVIEW_REGISTRY_MANIFEST="/nonexistent/review-registry.tsv" run review_registry_lookup pr_diff rubric
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest file not found"* ]]
}

# ===========================================================================
# Regression guard: the pr_diff verdict/marker contract (issue #613, AC #2).
#
# The registry decides WHERE the verdict goes (output_channel ->
# scripts/post-pr-review.sh, asserted above). These tests pin WHAT that channel
# accepts and emits so registering a new artifact_type can never silently
# regress production PR review:
#   - the decision vocabulary is exactly approve | escalate (with skip as an
#     explicit no-op),
#   - risk LOW|MEDIUM|HIGH round-trips and HIGH is treated specially,
#   - the idempotency marker format is unchanged.
# DRY_RUN=true still short-circuits the real review/merge posting; the only
# network touch is gate 4's review-thread enumeration (#1766), which the setup
# gh stub answers with a clean thread set, so these run hermetically.
# ===========================================================================

# --- decision vocabulary: approve | escalate (AC #2) -----------------------

@test "verdict contract: decision=approve is accepted and surfaced (DRY_RUN)" {
  write_verdict approve LOW
  run env PR_HEAD_SHA=abc123 bash "$POST_SCRIPT" "https://github.com/o/r/pull/1" "$VERDICT_FILE" true
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^Decision: approve$'
}

@test "verdict contract: decision=escalate is accepted and surfaced (DRY_RUN)" {
  write_verdict escalate HIGH
  run env PR_HEAD_SHA=abc123 bash "$POST_SCRIPT" "https://github.com/o/r/pull/1" "$VERDICT_FILE" true
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^Decision: escalate$'
}

@test "verdict contract: an unknown decision is rejected non-zero" {
  write_verdict frobnicate LOW
  run env PR_HEAD_SHA=abc123 bash "$POST_SCRIPT" "https://github.com/o/r/pull/1" "$VERDICT_FILE" false
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "invalid decision"
}

@test "verdict contract: decision=skip is an explicit no-op (exit 100), not a verdict" {
  write_verdict skip LOW
  run env PR_HEAD_SHA=abc123 bash "$POST_SCRIPT" "https://github.com/o/r/pull/1" "$VERDICT_FILE" false
  [ "$status" -eq 100 ]
}

# --- risk vocabulary: LOW | MEDIUM | HIGH (AC #2) --------------------------

@test "verdict contract: risk LOW|MEDIUM|HIGH are surfaced unchanged (DRY_RUN)" {
  local risk
  for risk in LOW MEDIUM HIGH; do
    write_verdict approve "$risk"
    run env PR_HEAD_SHA=abc123 bash "$POST_SCRIPT" "https://github.com/o/r/pull/1" "$VERDICT_FILE" true
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE "^Risk: ${risk}$"
  done
}

@test "risk contract: HIGH risk bypasses AI delegation (forces human escalation)" {
  run grep -qE 'RISK.*!=.*HIGH' "$POST_SCRIPT"
  [ "$status" -eq 0 ]
}

# --- idempotency marker format (AC #2) ------------------------------------

@test "marker contract: post-pr-review.sh emits the canonical v1 sha marker" {
  run grep -qF '<!-- pr-review-agent v1 sha=$PR_HEAD_SHA -->' "$POST_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "marker contract: prior-agent items are detected by the v1 sha=[a-f0-9]+ regex" {
  run grep -qF 'pr-review-agent v1 sha=[a-f0-9]+' "$POST_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "marker contract: superseded items carry the superseded sentinel" {
  run grep -qF '<!-- pr-review-agent superseded -->' "$POST_SCRIPT"
  [ "$status" -eq 0 ]
}
