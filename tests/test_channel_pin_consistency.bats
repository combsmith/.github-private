#!/usr/bin/env bats
# Channel-pin/comment same-file consistency guard (#1866 AC #3; regression of #1819).
#
# The workflow-stub sync generator (standards-deploy.yml, in the PUBLIC
# petry-projects/.github repo) is meant to PRESERVE each destination repo's own
# `uses:` channel pin. #1819 exposed the receiving-side hazard: a guard COMMENT
# that names a channel can drift out of step with the actual pin in the same file
# (it moved dev-lead's comment while leaving the pin, or vice versa). Nothing in
# this repo guarded that same-file property.
#
# This is the receiving-side guard, in the same family as validate-caller-inputs
# (#1253), caller-stub-freeze (#1255), sync-scope-guard (#1700), and the SC2
# self-review-channel guard (#1624): it asserts that any channel a caller stub's
# COMMENTS or `agent_ref:` name for its OWN reusable matches the `uses:` pin in
# the same file. Intentional CONTRAST references (a promotion target, a legacy
# form, a different agent's duty) are excluded so they do not false-fail.
#
# All assertions are PURE: helper/unit tests use fixture stubs, and the LIVE guard
# reads the committed workflow files. No network.
#
# Run: bats tests/test_channel_pin_consistency.bats

setup() {
  # shellcheck source=scripts/lib/channel-pin-consistency.sh
  source "${BATS_TEST_DIRNAME}/../scripts/lib/channel-pin-consistency.sh"
  FIXTURES="${BATS_TEST_DIRNAME}/fixtures/channel-pin"
  REPO_ROOT="${BATS_TEST_DIRNAME}/.."
}

# ---------------------------------------------------------------------------
# cpc_channel_refs — extract `<agent>/<channel>` channel refs from arbitrary text.
# ---------------------------------------------------------------------------

@test "channel refs: pulls a backtick-quoted channel ref out of prose" {
  run bash -c 'source "'"${BATS_TEST_DIRNAME}"'/../scripts/lib/channel-pin-consistency.sh"; printf "%s\n" "pinned to the \`demo/v1-next\` channel" | cpc_channel_refs'
  [ "$status" -eq 0 ]
  [ "$output" = "demo/v1-next" ]
}

@test "channel refs: pulls the ref out of a full workflow@ref token" {
  run bash -c 'source "'"${BATS_TEST_DIRNAME}"'/../scripts/lib/channel-pin-consistency.sh"; printf "%s\n" "demo-reusable.yml@demo/v2-stable # NOSONAR" | cpc_channel_refs'
  [ "$status" -eq 0 ]
  [ "$output" = "demo/v2-stable" ]
}

@test "channel refs: a bare tier with no agent prefix yields nothing" {
  run bash -c 'source "'"${BATS_TEST_DIRNAME}"'/../scripts/lib/channel-pin-consistency.sh"; printf "%s\n" "the bare next canary" | cpc_channel_refs'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "channel refs: an ordinary path (docs/release/versioning.md) yields nothing" {
  run bash -c 'source "'"${BATS_TEST_DIRNAME}"'/../scripts/lib/channel-pin-consistency.sh"; printf "%s\n" "see docs/release/versioning.md" | cpc_channel_refs'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# cpc_line_is_contrast — the contrast-marker predicate.
# ---------------------------------------------------------------------------

@test "contrast: a promotion-target line is a contrast reference" {
  run cpc_line_is_contrast "promoted to demo/v1-stable (the fleet)"
  [ "$status" -eq 0 ]
}

@test "contrast: a plain pin-assertion line is NOT a contrast reference" {
  run cpc_line_is_contrast "it is pinned to the demo/v1-stable channel"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# cpc_stub_conflicts — the core same-file detector.
# ---------------------------------------------------------------------------

@test "conflicts: an aligned stub reports none" {
  run cpc_stub_conflicts "${FIXTURES}/stub-aligned.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "conflicts: a comment naming a different channel is a conflict" {
  run cpc_stub_conflicts "${FIXTURES}/stub-comment-mismatch.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"demo/v2-stable"* ]]
  [[ "$output" == *"demo/v2-next"* ]]
}

@test "conflicts: a comment differing in BOTH tier and version is a conflict" {
  run cpc_stub_conflicts "${FIXTURES}/stub-both-differ.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"demo/v1-stable"* ]]
  [[ "$output" == *"demo/v2-next"* ]]
}

@test "conflicts: an intentional contrast reference is NOT a conflict" {
  run cpc_stub_conflicts "${FIXTURES}/stub-contrast.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "conflicts: a different agent's channel is NOT a conflict" {
  run cpc_stub_conflicts "${FIXTURES}/stub-other-agent.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "conflicts: a desynced agent_ref is a conflict" {
  run cpc_stub_conflicts "${FIXTURES}/stub-agent-ref-desync.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent_ref"* ]]
  [[ "$output" == *"demo/v1-next"* ]]
  [[ "$output" == *"demo/v1-stable"* ]]
}

@test "conflicts: a workflow with no channel pin reports none (N/A)" {
  run cpc_stub_conflicts "${FIXTURES}/stub-no-pin.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# cpc_assert_consistent — end-to-end guard + its actionable message.
# ---------------------------------------------------------------------------

@test "assert: an aligned stub passes" {
  run cpc_assert_consistent "${FIXTURES}/stub-aligned.yml" "stub-aligned.yml"
  [ "$status" -eq 0 ]
}

@test "assert: a no-pin workflow passes as N/A" {
  run cpc_assert_consistent "${FIXTURES}/stub-no-pin.yml" "stub-no-pin.yml"
  [ "$status" -eq 0 ]
}

@test "assert: a comment/pin mismatch FAILS naming the issue and both refs" {
  run cpc_assert_consistent "${FIXTURES}/stub-comment-mismatch.yml" "stub-comment-mismatch.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1866"* ]]
  [[ "$output" == *"1819"* ]]
  [[ "$output" == *"demo/v2-stable"* ]]
  [[ "$output" == *"demo/v2-next"* ]]
  # It must steer a contributor to fix the COMMENT, not repin `uses:`.
  [[ "$output" == *"comment"* || "$output" == *"COMMENT"* ]]
}

@test "assert: a desynced agent_ref FAILS" {
  run cpc_assert_consistent "${FIXTURES}/stub-agent-ref-desync.yml" "stub-agent-ref-desync.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent_ref"* ]]
}

# ---------------------------------------------------------------------------
# LIVE regression guard (AC #3): every committed caller stub is self-consistent.
# This is what fails if a future sync/PR moves a guard comment (or agent_ref)
# without moving the pin it names — the #1819 defect.
# ---------------------------------------------------------------------------

@test "LIVE: every .github/workflows/*.yml caller stub is comment/pin consistent" {
  shopt -s nullglob
  local wf failed=0 tmpfile
  tmpfile="$(mktemp)" || { echo "Failed to create temp file"; return 1; }
  for wf in "${REPO_ROOT}"/.github/workflows/*.yml; do
    if ! cpc_assert_consistent "$wf" "$(basename "$wf")" >"$tmpfile" 2>&1; then
      echo "INCONSISTENT: $wf"
      cat "$tmpfile"
      failed=1
    fi
  done
  rm -f "$tmpfile"
  [ "$failed" -eq 0 ]
}

@test "LIVE: pr-review-mention.yml's comment channel matches its uses: pin" {
  run cpc_assert_consistent "${REPO_ROOT}/.github/workflows/pr-review-mention.yml" "pr-review-mention.yml"
  [ "$status" -eq 0 ]
}
