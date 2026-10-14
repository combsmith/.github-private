#!/usr/bin/env bats
# Unit tests for the pure helpers in scripts/cut-release.sh
# (valid_agent, validate_version, release_ref, major_of, channel_ref). The
# git-backed flow in main() is not exercised here.
#
# Run with: bats tests/test_cut_release.bats

setup() {
  # Sourcing must NOT run main() (source-guard); it only defines the helpers.
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/cut-release.sh"
}

# ---------------------------------------------------------------------------
# valid_agent
# ---------------------------------------------------------------------------

# Consistent-path invariant (#1076): EVERY tag operation — this-repo AND cross-repo —
# goes through `gh api`, never a local `git push`/`git tag`. A local push is not granted
# the release-manager App's ruleset bypass for a tag UPDATE, so it GH013s ("Cannot update
# this protected ref") on protected channel moves such as dev-lead/next. This guard fails
# if the local-git path is ever reintroduced.
@test "cut-release: no local git tag/push path — all tag ops go through gh api (#1076)" {
  local script; script="$(dirname "$BATS_TEST_FILENAME")/../scripts/cut-release.sh"
  ! grep -Ev '^[[:space:]]*#' "$script" | grep -Eq '\bgit[[:space:]]+(tag|push)\b'
  grep -q 'agent_host_repo' "$script"
}

@test "agent_host_repo: cross-repo agent resolves to petry-projects/.github" {
  run agent_host_repo "agent-shield"
  [ "$status" -eq 0 ]
  [ "$output" = "petry-projects/.github" ]
}

@test "agent_host_repo: this-repo agent resolves to the current repo (GITHUB_REPOSITORY)" {
  export GITHUB_REPOSITORY="petry-projects/.github-private"
  run agent_host_repo "dev-lead"
  [ "$status" -eq 0 ]
  [ "$output" = "petry-projects/.github-private" ]
}

@test "valid_agent: pr-review is accepted" {
  run valid_agent "pr-review"
  [ "$status" -eq 0 ]
}

@test "valid_agent: dev-lead is accepted" {
  run valid_agent "dev-lead"
  [ "$status" -eq 0 ]
}

# ci-failure-analyst is hosted in THIS repo (.github-private), brought under the
# versioned-release model in #1159.
@test "valid_agent: ci-failure-analyst is accepted" {
  run valid_agent "ci-failure-analyst"
  [ "$status" -eq 0 ]
}

@test "agent_host_repo: ci-failure-analyst resolves to this repo (not cross-repo)" {
  export GITHUB_REPOSITORY="petry-projects/.github-private"
  run agent_host_repo "ci-failure-analyst"
  [ "$status" -eq 0 ]
  [ "$output" = "petry-projects/.github-private" ]
}

@test "valid_agent: feature-ideation is accepted" {
  run valid_agent "feature-ideation"
  [ "$status" -eq 0 ]
}

# idea-enhancer's reusable is hosted cross-repo in petry-projects/.github, brought
# under the versioned-release model in #515.
@test "valid_agent: idea-enhancer is accepted" {
  run valid_agent "idea-enhancer"
  [ "$status" -eq 0 ]
}

@test "valid_agent: add-to-project is accepted" {
  run valid_agent "add-to-project"
  [ "$status" -eq 0 ]
}

@test "valid_agent: pr-auto-review is accepted" {
  run valid_agent "pr-auto-review"
  [ "$status" -eq 0 ]
}

@test "agent_host_repo: pr-auto-review resolves to petry-projects/.github (cross-repo)" {
  run agent_host_repo "pr-auto-review"
  [ "$status" -eq 0 ]
  [ "$output" = "petry-projects/.github" ]
}

@test "agent_host_repo: add-to-project resolves to petry-projects/.github (cross-repo)" {
  run agent_host_repo "add-to-project"
  [ "$status" -eq 0 ]
  [ "$output" = "petry-projects/.github" ]
}

@test "agent_host_repo: idea-enhancer resolves to petry-projects/.github (cross-repo)" {
  run agent_host_repo "idea-enhancer"
  [ "$status" -eq 0 ]
  [ "$output" = "petry-projects/.github" ]
}

# The six .github-hosted reusables migrated by #482, brought under the ring model (#870).
@test "valid_agent: agent-shield is accepted" {
  run valid_agent "agent-shield"
  [ "$status" -eq 0 ]
}

@test "valid_agent: auto-rebase is accepted" {
  run valid_agent "auto-rebase"
  [ "$status" -eq 0 ]
}

@test "valid_agent: dependency-audit is accepted" {
  run valid_agent "dependency-audit"
  [ "$status" -eq 0 ]
}

@test "valid_agent: dependabot-automerge is accepted" {
  run valid_agent "dependabot-automerge"
  [ "$status" -eq 0 ]
}

@test "valid_agent: dependabot-rebase is accepted" {
  run valid_agent "dependabot-rebase"
  [ "$status" -eq 0 ]
}

@test "valid_agent: pr-review-mention is accepted" {
  run valid_agent "pr-review-mention"
  [ "$status" -eq 0 ]
}

@test "valid_agent: persona-mention is accepted" {
  run valid_agent "persona-mention"
  [ "$status" -eq 0 ]
}

@test "valid_agent: unknown agent is rejected" {
  run valid_agent "totally-not-an-agent"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# cross_repo_agent — agents whose reusable lives in petry-projects/.github
# (this repo holds only the thin caller stub), so live cuts are refused until
# the cross-repo push target is wired (TODO #872).
# ---------------------------------------------------------------------------

@test "cross_repo_agent: feature-ideation is cross-repo" {
  run cross_repo_agent "feature-ideation"
  [ "$status" -eq 0 ]
}

@test "cross_repo_agent: agent-shield is cross-repo" {
  run cross_repo_agent "agent-shield"
  [ "$status" -eq 0 ]
}

@test "cross_repo_agent: auto-rebase is cross-repo" {
  run cross_repo_agent "auto-rebase"
  [ "$status" -eq 0 ]
}

@test "cross_repo_agent: dependency-audit is cross-repo" {
  run cross_repo_agent "dependency-audit"
  [ "$status" -eq 0 ]
}

@test "cross_repo_agent: dependabot-automerge is cross-repo" {
  run cross_repo_agent "dependabot-automerge"
  [ "$status" -eq 0 ]
}

@test "cross_repo_agent: dependabot-rebase is cross-repo" {
  run cross_repo_agent "dependabot-rebase"
  [ "$status" -eq 0 ]
}

@test "cross_repo_agent: pr-review-mention is cross-repo" {
  run cross_repo_agent "pr-review-mention"
  [ "$status" -eq 0 ]
}

@test "cross_repo_agent: persona-mention is cross-repo (reusable in .github)" {
  run cross_repo_agent "persona-mention"
  [ "$status" -eq 0 ]
}

@test "cross_repo_agent: pr-review is NOT cross-repo (hosted here)" {
  run cross_repo_agent "pr-review"
  [ "$status" -ne 0 ]
}

@test "cross_repo_agent: dev-lead is NOT cross-repo (hosted here)" {
  run cross_repo_agent "dev-lead"
  [ "$status" -ne 0 ]
}

@test "cross_repo_agent: unknown agent is NOT cross-repo" {
  run cross_repo_agent "ci-failure-analyst"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# validate_version — strict MAJOR.MINOR.PATCH
# ---------------------------------------------------------------------------

@test "validate_version: 1.0.0 is valid" {
  run validate_version "1.0.0"
  [ "$status" -eq 0 ]
}

@test "validate_version: 12.4.37 is valid" {
  run validate_version "12.4.37"
  [ "$status" -eq 0 ]
}

@test "validate_version: leading v is rejected" {
  run validate_version "v1.0.0"
  [ "$status" -ne 0 ]
}

@test "validate_version: two-part version is rejected" {
  run validate_version "1.2"
  [ "$status" -ne 0 ]
}

@test "validate_version: four-part version is rejected" {
  run validate_version "1.2.3.4"
  [ "$status" -ne 0 ]
}

@test "validate_version: non-numeric is rejected" {
  run validate_version "1.2.x"
  [ "$status" -ne 0 ]
}

@test "validate_version: empty is rejected" {
  run validate_version ""
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# release_ref / channel_ref — tag-name formatting
# ---------------------------------------------------------------------------

@test "release_ref: prepends agent and v" {
  run release_ref "pr-review" "1.0.0"
  [ "$output" = "pr-review/v1.0.0" ]
}

@test "release_ref: dev-lead variant" {
  run release_ref "dev-lead" "2.3.1"
  [ "$output" = "dev-lead/v2.3.1" ]
}

@test "release_ref: ci-failure-analyst variant" {
  run release_ref "ci-failure-analyst" "0.1.0"
  [ "$output" = "ci-failure-analyst/v0.1.0" ]
}

@test "release_ref: feature-ideation variant" {
  run release_ref "feature-ideation" "1.4.0"
  [ "$output" = "feature-ideation/v1.4.0" ]
}

@test "release_ref: agent-shield variant" {
  run release_ref "agent-shield" "1.0.0"
  [ "$output" = "agent-shield/v1.0.0" ]
}

@test "release_ref: dependabot-automerge variant" {
  run release_ref "dependabot-automerge" "2.1.3"
  [ "$output" = "dependabot-automerge/v2.1.3" ]
}

# ---------------------------------------------------------------------------
# major_of — extract the MAJOR component of a MAJOR.MINOR.PATCH version (#1184)
# ---------------------------------------------------------------------------

@test "major_of: 1.2.3 is 1" {
  run major_of "1.2.3"
  [ "$output" = "1" ]
}

@test "major_of: 2.0.0 is 2" {
  run major_of "2.0.0"
  [ "$output" = "2" ]
}

@test "major_of: 12.4.37 is 12" {
  run major_of "12.4.37"
  [ "$output" = "12" ]
}

# ---------------------------------------------------------------------------
# channel_ref — major-scoped channel tag names (#1184, epic #657)
# A bare tier is prefixed with v<major(version)>-; a fully-qualified
# v<M>-<tier> passes through unchanged (its own major wins).
# ---------------------------------------------------------------------------

@test "channel_ref: bare tier is prefixed with the version's major" {
  run channel_ref "pr-review" "1.0.0" "stable"
  [ "$output" = "pr-review/v1-stable" ]
}

@test "channel_ref: dev-lead 2.0.0 stable -> dev-lead/v2-stable" {
  run channel_ref "dev-lead" "2.0.0" "stable"
  [ "$output" = "dev-lead/v2-stable" ]
}

@test "channel_ref: ci-failure-analyst 0.1.0 stable -> ci-failure-analyst/v0-stable" {
  run channel_ref "ci-failure-analyst" "0.1.0" "stable"
  [ "$output" = "ci-failure-analyst/v0-stable" ]
}

@test "channel_ref: next channel is major-scoped" {
  run channel_ref "dev-lead" "1.4.2" "next"
  [ "$output" = "dev-lead/v1-next" ]
}

@test "channel_ref: feature-ideation ring0 channel is major-scoped" {
  run channel_ref "feature-ideation" "3.1.0" "ring0"
  [ "$output" = "feature-ideation/v3-ring0" ]
}

@test "channel_ref: explicit v<M>-<tier> passes through unchanged" {
  run channel_ref "dev-lead" "2.0.0" "v1-ring0"
  [ "$output" = "dev-lead/v1-ring0" ]
}

@test "channel_ref: explicit v<M>-<tier> wins over the version's major" {
  run channel_ref "pr-review" "9.9.9" "v1-stable"
  [ "$output" = "pr-review/v1-stable" ]
}

@test "channel_ref: major bump is reflected in the prefix (1.x -> v1-, 2.x -> v2-)" {
  run channel_ref "dev-lead" "1.7.2" "stable"
  [ "$output" = "dev-lead/v1-stable" ]
  run channel_ref "dev-lead" "2.0.0" "stable"
  [ "$output" = "dev-lead/v2-stable" ]
}

# ---------------------------------------------------------------------------
# strip_origin — normalize a local-style ref to a remote-repo ref name (#872)
# ---------------------------------------------------------------------------

@test "strip_origin: origin/main becomes main" {
  run strip_origin "origin/main"
  [ "$output" = "main" ]
}

@test "strip_origin: a bare ref passes through" {
  run strip_origin "main"
  [ "$output" = "main" ]
}

@test "strip_origin: a SHA passes through" {
  run strip_origin "376a4fcb1117444595e3e702fa450873d0e54310"
  [ "$output" = "376a4fcb1117444595e3e702fa450873d0e54310" ]
}

@test "strip_origin: only the leading origin/ is stripped" {
  run strip_origin "origin/release/origin/x"
  [ "$output" = "release/origin/x" ]
}
