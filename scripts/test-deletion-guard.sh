#!/usr/bin/env bash
# test-deletion-guard.sh — fail a PR that deletes files under tests/ unless a
# maintainer acknowledged it with the `ack-test-deletion` label (#655/#823).
# Run by .github/workflows/test-deletion-guard.yml from the repo root.
#
# The PR's deletions are measured from the MERGE BASE of the base and head
# (#2254), not from the base tip: a test file the base branch gained after the
# branch point is absent on the head, and diffing against the tip reported it as
# deleted by the PR (PR #2252). A missing merge base fails closed.
#
# Env: BASE_SHA, HEAD_SHA (the PR's base and head commits), ACK ("true" when the
# `ack-test-deletion` label is present). Needs full history (fetch-depth: 0).

set -euo pipefail

: "${BASE_SHA:?BASE_SHA is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
ACK="${ACK:-false}"

if ! merge_base="$(git merge-base "$BASE_SHA" "$HEAD_SHA" 2>/dev/null)" || [ -z "$merge_base" ]; then
  echo "::error title=Test-Deletion Guard::No merge base between base ${BASE_SHA} and head ${HEAD_SHA} — cannot tell which test files this PR deletes." >&2
  exit 2
fi

deleted="$(git diff --diff-filter=D --name-only "$merge_base" "$HEAD_SHA" -- 'tests/')"
if [ -z "$deleted" ]; then
  echo "No files deleted under tests/. OK."
  exit 0
fi
echo "::warning title=Test files deleted::This PR deletes file(s) under tests/:"
printf '%s\n' "$deleted"
if [ "$ACK" = "true" ]; then
  echo "::notice::Deletion acknowledged via the 'ack-test-deletion' label."
  exit 0
fi
{
  echo "::error title=Unacknowledged test deletion::This PR deletes test file(s) under tests/ without acknowledgement."
  echo "A maintainer must add the 'ack-test-deletion' label to confirm the removal is intentional."
  echo "Guard rationale (#655): a stale-base PR once reverted a shipped fix AND deleted its regression test in the same diff — CI stayed green because the guard was gone."
} >&2
exit 1
