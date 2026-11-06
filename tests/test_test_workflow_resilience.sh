#!/usr/bin/env bash
set -euo pipefail
# test_test_workflow_resilience.sh — regression guard for issue #1364.
#
# The Tests workflow (.github/workflows/test.yml) flaked at ~14.8% of runs. Its
# only non-deterministic step is "Install test dependencies", which fetches
# packages over the network:
#   - pip install pyyaml
#   - sudo apt-get update && sudo apt-get install -y yq
# Transient PyPI / apt-mirror failures (and pip falling back to a source build)
# failed the whole run even though every test itself is pure and local. This
# test asserts the install step is hardened so a single transient fetch failure
# no longer fails the workflow:
#   1. network installs are wrapped in a bounded retry,
#   2. pip is pinned and binary-only (no flaky source build).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="${SCRIPT_DIR}/../.github/workflows/test.yml"
STEP_NAME="Install test dependencies"
fail=0

if ! command -v yq >/dev/null 2>&1; then
  echo "FAIL: yq is required to run this test"
  exit 2
fi

if [[ ! -f "$WORKFLOW" ]]; then
  echo "FAIL: $WORKFLOW not found"
  exit 1
fi

# Bracket-index the hyphenated job key: under jq-based yq (kislyuk), `.jobs.unit-tests`
# parses as `.jobs.unit - tests` and fails with "tests/0 is not defined" (issue #1364).
run=$(yq '.jobs["unit-tests"].steps[] | select(.name == "'"$STEP_NAME"'") | .run' "$WORKFLOW")

if [[ -z "$run" ]] || [[ "$run" = "null" ]]; then
  echo "FAIL: could not find the \"$STEP_NAME\" step in $WORKFLOW"
  exit 1
fi

# Normalize newlines and repeated spaces into a single logical line so the checks
# below are robust to multi-line run blocks and backslash line continuations
# (e.g. "retry \<newline>  pip install ...") that a line-by-line grep would miss.
normalized_run=$(printf '%s\n' "$run" | tr '\n' ' ' | tr -s ' ')

# 1. A retry helper must be defined so transient fetch failures are absorbed.
# Use POSIX [[:space:]] rather than the PCRE \s shorthand so the check is
# portable to BSD/macOS grep. Assert grep exits exactly 1 (no match) so a grep
# error (exit 2) can't be mistaken for "not found".
status=0
grep -Eq 'retry[[:space:]]*\(\)' <<<"$normalized_run" || status=$?
if [[ "$status" -eq 2 ]]; then
  echo "FAIL: grep error while checking for retry() helper"
  exit 2
elif [[ "$status" -eq 1 ]]; then
  echo "FAIL: \"$STEP_NAME\" must define a retry() helper to absorb transient"
  echo "  network failures (apt mirror / PyPI) — issue #1364."
  fail=1
fi

# 2. Every network fetch must go through retry (check all occurrences are wrapped).
while IFS= read -r cmd; do
  if grep -Eq "$cmd" <<<"$normalized_run"; then
    # Count total occurrences and retry-wrapped occurrences; they must match.
    # Anchor "retry" directly before the command (allowing only a "sudo" prefix,
    # which is how the real invocations read: "retry pip install", "retry sudo
    # apt-get update"). A greedy "retry.*$cmd" is wrong two ways: it spans across
    # logical commands — after newline normalization there are no ;|& separators
    # to stop it, so an un-retried "apt-get install" preceded by any earlier
    # "retry" would false-pass — and its single leftmost-longest match undercounts
    # when a command legitimately appears more than once.
    total=$(grep -Eo "(^|[^a-z])$cmd" <<<"$normalized_run" | wc -l)
    wrapped=$(grep -Eo "retry[[:space:]]+(sudo[[:space:]]+)?$cmd" <<<"$normalized_run" | wc -l)
    if [[ "$total" -ne "$wrapped" ]]; then
      echo "FAIL: all occurrences of \"$cmd\" in \"$STEP_NAME\" must be wrapped in retry"
      echo "  (found $total, wrapped $wrapped) — issue #1364"
      fail=1
    fi
  fi
done <<'CMDS'
apt-get update
apt-get install
pip install
CMDS

# 3. pip must be pinned and binary-only so it never falls back to a source build.
if grep -Eq 'pip install' <<<"$normalized_run"; then
  status=0
  grep -Fq -- '--only-binary' <<<"$normalized_run" || status=$?
  if [[ "$status" -eq 2 ]]; then
    echo "FAIL: grep error while checking for --only-binary"
    exit 2
  elif [[ "$status" -eq 1 ]]; then
    echo "FAIL: the pip install in \"$STEP_NAME\" must use --only-binary to avoid"
    echo "  a flaky source build (issue #1364)."
    fail=1
  fi
  status=0
  grep -Eiq 'pyyaml==[0-9]+\.[0-9]+\.[0-9]+' <<<"$normalized_run" || status=$?
  if [[ "$status" -eq 2 ]]; then
    echo "FAIL: grep error while checking for the pyyaml version pin"
    exit 2
  elif [[ "$status" -eq 1 ]]; then
    echo "FAIL: the pip install in \"$STEP_NAME\" must pin pyyaml to a specific"
    echo "  version (pyyaml==X.Y.Z) for reproducible installs (issue #1364)."
    fail=1
  fi
fi

if [[ "$fail" -eq 0 ]]; then
  echo "PASS: $WORKFLOW dependency install is retry-hardened and pinned"
fi
exit "$fail"
