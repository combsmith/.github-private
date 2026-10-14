#!/usr/bin/env bats
# Channel-skew guard for the dev-lead retry sweep (#2050).
#
# dev-lead-retry.yml runs scripts/dev-lead-retry.sh, which dispatches runs that
# execute the harness at the channel this repo's caller stub pins
# (dev-lead.yml `agent_ref`). Running the sweep from `main` let it send payload
# fields the pinned harness could not read (#2017: every fix-bot-comment retry
# failed until stable caught up). The sweep must therefore check out scripts/ at
# that same channel. These tests pin:
#   • the workflow reads `agent_ref` from dev-lead.yml on the default branch;
#   • the agent checkout's `ref:` is that resolved value (never main, never a
#     hard-coded major);
#   • the resolve step (executed from the workflow text) accepts the live stub
#     and other majors, and fails on an empty or malformed value.
#
# Run: bats tests/dev-lead/unit/test_dev_lead_retry_channel.bats

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
WF="$REPO_ROOT/.github/workflows/dev-lead-retry.yml"
STUB="$REPO_ROOT/.github/workflows/dev-lead.yml"

setup() {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  : >"$GITHUB_OUTPUT"
  RESOLVE_SCRIPT="$BATS_TEST_TMPDIR/resolve.sh"
  # yq extracts the resolve step: skip locally without it, but never silently in CI.
  if ! command -v yq >/dev/null 2>&1; then
    if [ -n "${CI:-}" ]; then
      echo "yq is required in CI" >&2
      return 1
    fi
    skip "yq not installed"
  fi
  yq -r '.jobs.retry.steps[] | select(.id == "channel") | .run' "$WF" >"$RESOLVE_SCRIPT"
}

# Write a minimal caller stub fixture pinning agent_ref to $1.
_stub_fixture() {
  local f="$BATS_TEST_TMPDIR/dev-lead.yml"
  cat >"$f" <<EOF
jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@$1
    with:
      agent_ref: $1
EOF
  printf '%s' "$f"
}

@test "workflow sparse-checks-out dev-lead.yml from the default branch first" {
  local first
  first="$(yq -r '.jobs.retry.steps[0].with["sparse-checkout"]' "$WF")"
  [[ "$first" == *".github/workflows/dev-lead.yml"* ]]
  [ "$(yq -r '.jobs.retry.steps[0].with.ref' "$WF")" = '${{ github.event.repository.default_branch }}' ]
}

@test "resolve step reads the stub file the first checkout fetched" {
  local path stub_file
  path="$(yq -r '.jobs.retry.steps[0].with.path' "$WF")"
  stub_file="$(yq -r '.jobs.retry.steps[] | select(.id == "channel") | .env.STUB_FILE' "$WF")"
  [ "$stub_file" = "$path/.github/workflows/dev-lead.yml" ]
}

@test "agent checkout ref is the resolved agent_ref channel" {
  run yq -r '.jobs.retry.steps[] | select(.name == "Checkout agent repo") | .with.ref' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" = '${{ steps.channel.outputs.agent_ref }}' ]
}

@test "channel is resolved before the agent checkout and before the sweep runs" {
  local names
  names="$(yq -r '.jobs.retry.steps[].name' "$WF")"
  local resolve checkout sweep
  resolve="$(grep -n 'Resolve pinned dev-lead channel' <<<"$names" | cut -d: -f1)"
  checkout="$(grep -n '^Checkout agent repo$' <<<"$names" | cut -d: -f1)"
  sweep="$(grep -n 'Scan and retry' <<<"$names" | cut -d: -f1)"
  [ -n "$resolve" ] && [ -n "$checkout" ] && [ -n "$sweep" ]
  [ "$resolve" -lt "$checkout" ]
  [ "$checkout" -lt "$sweep" ]
}

@test "workflow does not hard-code a dev-lead major version" {
  run grep -nE 'dev-lead/v[0-9]+' "$WF"
  [ "$status" -eq 1 ]
}

@test "resolve step returns the live stub's agent_ref" {
  local expected
  expected="$(yq -r '.jobs["dev-lead"].with.agent_ref' "$STUB")"
  [ -n "$expected" ] && [ "$expected" != "null" ]
  STUB_FILE="$STUB" run bash "$RESOLVE_SCRIPT"
  [ "$status" -eq 0 ]
  grep -qxF "agent_ref=$expected" "$GITHUB_OUTPUT"
}

@test "resolve step accepts any major and every ring" {
  local ch
  for ch in dev-lead/v140-next dev-lead/v7-ring0 dev-lead/v12-ring1 dev-lead/v1000-stable; do
    : >"$GITHUB_OUTPUT"
    STUB_FILE="$(_stub_fixture "$ch")" run bash "$RESOLVE_SCRIPT"
    [ "$status" -eq 0 ]
    grep -qxF "agent_ref=$ch" "$GITHUB_OUTPUT"
  done
}

@test "resolve step fails when agent_ref is missing" {
  local f="$BATS_TEST_TMPDIR/dev-lead.yml"
  printf 'jobs:\n  dev-lead:\n    uses: x\n' >"$f"
  STUB_FILE="$f" run bash "$RESOLVE_SCRIPT"
  [ "$status" -eq 1 ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "resolve step fails on a malformed or non-channel agent_ref" {
  local bad
  for bad in main dev-lead/v139 dev-lead/vX-stable dev-lead/v139-canary pr-review/v1-stable 'dev-lead/v139-stable;x'; do
    : >"$GITHUB_OUTPUT"
    STUB_FILE="$(_stub_fixture "$bad")" run bash "$RESOLVE_SCRIPT"
    [ "$status" -eq 1 ]
    [ ! -s "$GITHUB_OUTPUT" ]
  done
}
