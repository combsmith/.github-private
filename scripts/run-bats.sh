#!/usr/bin/env bash
set -euo pipefail
# run-bats.sh — resilient wrapper around `bats` for the lint.yml `bats` job.
#
# Plain `bats <file> ...` aborts the whole run (executing zero tests) the moment
# one listed path is missing — so a single not-yet-present test file on a feature
# branch turns the entire CI job red with no test signal at all.
#
# This wrapper instead runs every listed file that exists, emits a GitHub
# `::warning::` annotation for any that is missing, and fails only when a real
# test fails or when none of the listed files exist.
#
# Usage: run-bats.sh <test-file> [<test-file> ...]

if [[ "$#" -eq 0 ]]; then
  echo "run-bats: no test files given" >&2
  exit 2
fi

present_tmp="$(mktemp)"
trap 'rm -f "$present_tmp"' EXIT
for f in "$@"; do
  if [[ -f "$f" ]]; then
    printf '%s\n' "$f" >> "$present_tmp"
  elif [[ -d "$f" ]]; then
    # Expand directory to find .bats files within it
    find "$f" -type f -name "*.bats" -print | sort >> "$present_tmp"
  else
    echo "::warning::run-bats: test file '$f' not found — skipping" >&2
  fi
done

if [[ ! -s "$present_tmp" ]]; then
  echo "run-bats: no test files exist out of $# listed — nothing to run" >&2
  exit 1
fi

set --
while IFS= read -r file; do
  set -- "$@" "$file"
done < "$present_tmp"
exec bats "$@"
