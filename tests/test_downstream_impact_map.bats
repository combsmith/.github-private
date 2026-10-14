#!/usr/bin/env bats
# Unit tests for the pure downstream-impact mapping helper
# (issue #750, epic #748): compute_downstream_impact <changed_files> <manifest>.
#
# The helper is PURE — bash + jq over the Story-1 consumer manifest, no `gh`/network.
# Given a newline-delimited changed-file list and a manifest path it emits a
# well-formed JSON object describing the impacted shared surfaces and the
# exact-matched consumers. Matching is single-hop and exact-path:
#   (a) a changed reusable-workflow path a consumer ref pins exactly -> direct surface
#   (b) a changed scripts/lib/*.sh or prompts/* path listed in a surface_sources
#       value -> that reusable surface -> the reusable's consumers
# Malformed/empty input degrades to an empty, well-formed object (never an error).
#
# Run with: bats tests/test_downstream_impact_map.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/downstream-impact.sh"
  MANIFEST="$(dirname "$BATS_TEST_FILENAME")/fixtures/downstream-impact/manifest.json"
}

# ---------------------------------------------------------------------------
# (a) Direct reusable-workflow change -> its consumers
# ---------------------------------------------------------------------------

@test "direct reusable-workflow change maps to the consumers that pin it" {
  run compute_downstream_impact ".github/workflows/pr-review.yml" "$MANIFEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.impacted_surfaces == [".github/workflows/pr-review.yml"]'
  printf '%s\n' "$output" | jq -e '[.impacted_consumers[].repo] == ["petry-projects/alpha", "petry-projects/bravo"]'
  printf '%s\n' "$output" | jq -e '.impacted_consumers[] | select(.repo == "petry-projects/alpha") | .via == [".github/workflows/pr-review.yml"]'
  printf '%s\n' "$output" | jq -e '.unmatched == []'
}

@test "direct change to the other reusable maps to a different consumer set" {
  run compute_downstream_impact ".github/workflows/dev-lead-reusable.yml" "$MANIFEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.impacted_surfaces == [".github/workflows/dev-lead-reusable.yml"]'
  printf '%s\n' "$output" | jq -e '[.impacted_consumers[].repo] == ["petry-projects/alpha", "petry-projects/charlie"]'
}

# ---------------------------------------------------------------------------
# (b) scripts/lib change mapped via surface_sources -> reusable -> consumers
# ---------------------------------------------------------------------------

@test "scripts/lib change maps via surface_sources to its reusable and consumers" {
  run compute_downstream_impact "scripts/lib/ci-status.sh" "$MANIFEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.impacted_surfaces == [".github/workflows/pr-review.yml"]'
  printf '%s\n' "$output" | jq -e '[.impacted_consumers[].repo] == ["petry-projects/alpha", "petry-projects/bravo"]'
  printf '%s\n' "$output" | jq -e '.unmatched == []'
}

# ---------------------------------------------------------------------------
# (b) prompts/ change mapped via surface_sources
# ---------------------------------------------------------------------------

@test "prompts change maps via surface_sources to its reusable and consumers" {
  run compute_downstream_impact "prompts/dev-lead/fix-ci.md" "$MANIFEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.impacted_surfaces == [".github/workflows/dev-lead-reusable.yml"]'
  printf '%s\n' "$output" | jq -e '[.impacted_consumers[].repo] == ["petry-projects/alpha", "petry-projects/charlie"]'
}

# ---------------------------------------------------------------------------
# No-impact change -> empty impact, no false positives
# ---------------------------------------------------------------------------

@test "a change in no shared surface produces an empty impact result" {
  run compute_downstream_impact "README.md
docs/architecture.md" "$MANIFEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.impacted_surfaces == []'
  printf '%s\n' "$output" | jq -e '.impacted_consumers == []'
  printf '%s\n' "$output" | jq -e '.unmatched == ["README.md", "docs/architecture.md"] or .unmatched == ["docs/architecture.md", "README.md"]'
}

@test "a scripts/lib file not listed in any surface_sources is no-impact" {
  run compute_downstream_impact "scripts/lib/git-identity.sh" "$MANIFEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.impacted_surfaces == []'
  printf '%s\n' "$output" | jq -e '.impacted_consumers == []'
  printf '%s\n' "$output" | jq -e '.unmatched == ["scripts/lib/git-identity.sh"]'
}

# ---------------------------------------------------------------------------
# Change touching multiple surfaces -> union of surfaces + consumers
# ---------------------------------------------------------------------------

@test "a source shared by two reusables impacts both surfaces and the union of consumers" {
  # scripts/lib/review-cycle.sh is listed under BOTH reusables in surface_sources.
  run compute_downstream_impact "scripts/lib/review-cycle.sh" "$MANIFEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.impacted_surfaces == [".github/workflows/dev-lead-reusable.yml", ".github/workflows/pr-review.yml"]'
  printf '%s\n' "$output" | jq -e '[.impacted_consumers[].repo] == ["petry-projects/alpha", "petry-projects/bravo", "petry-projects/charlie"]'
  # alpha pins both reusables -> via lists both surfaces.
  printf '%s\n' "$output" | jq -e '.impacted_consumers[] | select(.repo == "petry-projects/alpha") | .via == [".github/workflows/dev-lead-reusable.yml", ".github/workflows/pr-review.yml"]'
  # bravo only pins pr-review.yml.
  printf '%s\n' "$output" | jq -e '.impacted_consumers[] | select(.repo == "petry-projects/bravo") | .via == [".github/workflows/pr-review.yml"]'
  # charlie only pins dev-lead-reusable.yml.
  printf '%s\n' "$output" | jq -e '.impacted_consumers[] | select(.repo == "petry-projects/charlie") | .via == [".github/workflows/dev-lead-reusable.yml"]'
}

@test "changed list mixing an impacting and a non-impacting path reports both correctly" {
  run compute_downstream_impact ".github/workflows/pr-review.yml
docs/notes.md" "$MANIFEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.impacted_surfaces == [".github/workflows/pr-review.yml"]'
  printf '%s\n' "$output" | jq -e '.unmatched == ["docs/notes.md"]'
}

@test "duplicate changed paths are de-duplicated" {
  run compute_downstream_impact "scripts/lib/ci-status.sh
scripts/lib/ci-status.sh" "$MANIFEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.impacted_surfaces == [".github/workflows/pr-review.yml"]'
}

# ---------------------------------------------------------------------------
# Defensive degradation — never an error that breaks the cascade
# ---------------------------------------------------------------------------

@test "empty changed-file list yields an empty, well-formed object" {
  run compute_downstream_impact "" "$MANIFEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.impacted_surfaces == [] and .impacted_consumers == [] and .unmatched == []'
}

@test "missing argument yields an empty, well-formed object" {
  run compute_downstream_impact
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.impacted_surfaces == [] and .impacted_consumers == [] and .unmatched == []'
}

@test "a non-existent manifest path degrades to an empty object" {
  run compute_downstream_impact ".github/workflows/pr-review.yml" "/no/such/manifest.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.impacted_surfaces == [] and .impacted_consumers == []'
}

@test "a malformed manifest degrades to an empty object, not an error" {
  bad="$BATS_TEST_TMPDIR/bad.json"
  printf '{ "providers": [".github",,] ' > "$bad"
  run compute_downstream_impact ".github/workflows/pr-review.yml" "$bad"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.impacted_surfaces == [] and .impacted_consumers == []'
}

@test "a manifest missing keys still yields a well-formed object" {
  empty="$BATS_TEST_TMPDIR/empty.json"
  printf '{}' > "$empty"
  run compute_downstream_impact ".github/workflows/pr-review.yml" "$empty"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.impacted_surfaces == [] and .impacted_consumers == [] and .unmatched == [".github/workflows/pr-review.yml"]'
}

@test "output is always single well-formed JSON object on every path" {
  run compute_downstream_impact "scripts/lib/review-cycle.sh" "$MANIFEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e 'type == "object" and has("impacted_surfaces") and has("impacted_consumers") and has("unmatched")'
}
