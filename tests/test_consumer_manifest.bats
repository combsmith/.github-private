#!/usr/bin/env bats
# Unit tests for the consumer manifest + its validator (issue #749, epic #748).
#
# The manifest (scripts/lib/consumer-manifest.json) is the single machine-checkable
# source of truth that maps each provider reusable workflow to the org repos
# (consumers) that pin it, plus the in-provider scripts/lib + prompts each reusable
# sources (surface_sources). The validator (scripts/lib/validate-consumer-manifest.sh)
# is the gate: it must reject invalid JSON/schema, a surface_sources key that is not
# an existing reusable-workflow path in this repo, and a surface_sources value that
# does not point at an existing scripts/lib or prompts file in this repo.
#
# Run with: bats tests/test_consumer_manifest.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  VALIDATOR="$REPO_ROOT/scripts/lib/validate-consumer-manifest.sh"
  MANIFEST="$REPO_ROOT/scripts/lib/consumer-manifest.json"
  FIXTURE="$BATS_TEST_TMPDIR/manifest.json"
}

# Existence checks always resolve against the real repo root, so a fixture can
# reference real-or-bogus surfaces while living in the tmp dir.
run_validator() {
  run "$VALIDATOR" --manifest "$1" --repo-root "$REPO_ROOT"
}

# ---------------------------------------------------------------------------
# Happy path — the committed manifest is well-formed and self-consistent
# ---------------------------------------------------------------------------

@test "committed manifest passes the validator" {
  run_validator "$MANIFEST"
  [ "$status" -eq 0 ]
}

@test "committed manifest is valid JSON with the required top-level keys" {
  run jq -e '.providers and .consumers and .surface_sources' "$MANIFEST"
  [ "$status" -eq 0 ]
}

@test "committed manifest declares both providers" {
  run jq -e '.providers == [".github", ".github-private"]' "$MANIFEST"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Malformed JSON fails
# ---------------------------------------------------------------------------

@test "malformed JSON fails validation" {
  printf '{ "providers": [".github",,] ' > "$FIXTURE"
  run_validator "$FIXTURE"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Schema-shape violations fail
# ---------------------------------------------------------------------------

@test "missing surface_sources key fails validation" {
  jq 'del(.surface_sources)' "$MANIFEST" > "$FIXTURE"
  run_validator "$FIXTURE"
  [ "$status" -ne 0 ]
}

@test "consumer entry missing repo fails validation" {
  jq '.consumers = [{"refs": [".github-private/.github/workflows/pr-review.yml"]}]' \
    "$MANIFEST" > "$FIXTURE"
  run_validator "$FIXTURE"
  [ "$status" -ne 0 ]
}

@test "consumer entry with non-array refs fails validation" {
  jq '.consumers = [{"repo": "petry-projects/markets", "refs": "nope"}]' \
    "$MANIFEST" > "$FIXTURE"
  run_validator "$FIXTURE"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# surface_sources referencing a non-existent local surface fails
# ---------------------------------------------------------------------------

@test "surface_sources key that is not an existing reusable workflow fails" {
  jq '.surface_sources = {".github/workflows/does-not-exist.yml": []}' \
    "$MANIFEST" > "$FIXTURE"
  run_validator "$FIXTURE"
  [ "$status" -ne 0 ]
}

@test "surface_sources value pointing at a missing scripts/lib file fails" {
  jq '.surface_sources = {".github/workflows/pr-review.yml": ["scripts/lib/nope-does-not-exist.sh"]}' \
    "$MANIFEST" > "$FIXTURE"
  run_validator "$FIXTURE"
  [ "$status" -ne 0 ]
}

@test "surface_sources value pointing at a missing prompts file fails" {
  jq '.surface_sources = {".github/workflows/pr-review.yml": ["prompts/nope-does-not-exist.md"]}' \
    "$MANIFEST" > "$FIXTURE"
  run_validator "$FIXTURE"
  [ "$status" -ne 0 ]
}

@test "surface_sources value outside scripts/lib or prompts fails" {
  # A real, existing file that is NOT under scripts/lib/ or prompts/ must still
  # be rejected — surface_sources only declares lib/prompt surfaces.
  jq '.surface_sources = {".github/workflows/pr-review.yml": ["scripts/engine.sh"]}' \
    "$MANIFEST" > "$FIXTURE"
  run_validator "$FIXTURE"
  [ "$status" -ne 0 ]
}

@test "a well-formed minimal manifest with real surfaces passes" {
  cat > "$FIXTURE" <<'JSON'
{
  "providers": [".github", ".github-private"],
  "consumers": [
    { "repo": "petry-projects/markets", "refs": [".github-private/.github/workflows/pr-review.yml"] }
  ],
  "surface_sources": {
    ".github/workflows/pr-review.yml": ["prompts/single-review.md", "scripts/lib/ci-status.sh"]
  }
}
JSON
  run_validator "$FIXTURE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Consumer refs must reference a declared provider
# ---------------------------------------------------------------------------

@test "consumer ref not matching a declared provider fails validation" {
  jq '.consumers = [{"repo": "petry-projects/foo", "refs": ["not-a-provider/.github/workflows/foo.yml"]}]' \
    "$MANIFEST" > "$FIXTURE"
  run_validator "$FIXTURE"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Path traversal in surface_sources is rejected
# ---------------------------------------------------------------------------

@test "surface_sources key with path traversal is rejected" {
  jq '.surface_sources = {".github/workflows/../../scripts/lib/auto-merge.sh": []}' \
    "$MANIFEST" > "$FIXTURE"
  run_validator "$FIXTURE"
  [ "$status" -ne 0 ]
}

@test "surface_sources value with path traversal is rejected" {
  # scripts/lib/*.sh glob matches this path, but realpath resolves it outside scripts/lib/
  jq '.surface_sources = {".github/workflows/pr-review.yml": ["scripts/lib/../../scripts/engine.sh"]}' \
    "$MANIFEST" > "$FIXTURE"
  run_validator "$FIXTURE"
  [ "$status" -ne 0 ]
}
