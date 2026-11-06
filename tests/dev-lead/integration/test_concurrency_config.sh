#!/usr/bin/env bash
# Validates dev-lead's concurrency model: per-PR and per-issue lanes with
# cancel-in-progress:false, which serialize runs WITHIN a PR/issue (one active
# run at a time, the rest queued) while letting unrelated PRs/issues proceed in
# their own lanes.
#
# Same-PR serialization matters: two dev-lead runs editing one PR's branch in
# parallel would push over each other (and, with auto-merge on, race a merge).
# A per-PR group + cancel-in-progress:false is what guarantees one-at-a-time.
#
# Regression note: this previously asserted a single repo-wide 'dev-lead' group
# (#278). #450 replaced that with per-PR/per-issue lanes so issue pickups are no
# longer cancelled by unrelated PR traffic — this test was updated to match.
set -euo pipefail

FAIL=0

# check_concurrency_field: grep within the concurrency: YAML block only.
# Extracts lines from '^concurrency:' to the next top-level key, then strips
# comment-only lines so the assertion cannot be satisfied by comment text
# (dev-lead-reusable.yml has the routing strings in comments at lines 33-39;
# without this isolation, deleting the actual concurrency.group entries would
# leave the test green).
check_concurrency_field() {
  local file="$1" pattern="$2" label="$3"
  local block
  block=$(awk '/^concurrency:/{found=1} found && /^[a-z]/ && !/^concurrency:/{found=0} found{print}' "$file" \
    | grep -Ev '^[[:space:]]*#' || true)
  if printf '%s\n' "$block" | grep -qF "$pattern"; then
    echo "PASS [$label]: '$pattern' present in concurrency YAML of $(basename "$file")"
  else
    echo "FAIL [$label]: '$pattern' not found in concurrency YAML of $file"
    FAIL=$((FAIL + 1))
  fi
}

# check_concurrency_order: verify $before appears at a lower line number than
# $after within the concurrency: block. Presence alone is insufficient for
# short-circuit || chains: swapping two predicates keeps all tokens present
# while silently mis-routing events (e.g. issue.number before issue.pull_request
# would route PR-comment events to the issue lane instead of the PR lane).
check_concurrency_order() {
  local file="$1" before="$2" after="$3" label="$4"
  local block
  block=$(awk '/^concurrency:/{found=1} found && /^[a-z]/ && !/^concurrency:/{found=0} found{print}' "$file" \
    | grep -Ev '^[[:space:]]*#' || true)
  local line_before line_after
  line_before=$(printf '%s\n' "$block" | grep -nF "$before" | head -1 | cut -d: -f1 || true)
  line_after=$(printf '%s\n' "$block" | grep -nF "$after" | head -1 | cut -d: -f1 || true)
  if [[ -z "$line_before" || -z "$line_after" ]]; then
    echo "FAIL [$label]: '$before' or '$after' not found in concurrency YAML of $file"
    FAIL=$((FAIL + 1))
    return
  fi
  if [[ "$line_before" -lt "$line_after" ]]; then
    echo "PASS [$label]: '$before' precedes '$after' in concurrency YAML of $(basename "$file")"
  else
    echo "FAIL [$label]: '$before' must precede '$after' in concurrency YAML of $file"
    FAIL=$((FAIL + 1))
  fi
}

# dev-lead-reusable.yml is the single source of truth for concurrency (#450).
# Caller stubs (dev-lead.yml) must NOT carry their own concurrency block — if
# they did, the stub's outer group would take precedence and break per-PR/issue
# routing before the reusable's concurrency could apply. All concurrency checks
# therefore target only dev-lead-reusable.yml.
WORKFLOWS=(
  ".github/workflows/dev-lead-reusable.yml"
)

# Guard: dev-lead.yml must NOT declare a top-level concurrency block.
STUB=".github/workflows/dev-lead.yml"
if grep -q '^concurrency:' "$STUB"; then
  echo "FAIL [no-stub-concurrency]: $STUB must not have a top-level concurrency block (reusable is the source of truth)"
  FAIL=$((FAIL + 1))
else
  echo "PASS [no-stub-concurrency]: $STUB correctly has no top-level concurrency block"
fi

for wf in "${WORKFLOWS[@]}"; do
  # Per-PR lane → serializes all runs touching one PR (PR, review, review
  # comment, issue_comment-on-PR, and repository_dispatch all map here).
  check_concurrency_field "$wf" "dev-lead-pr-" "per-PR serialization lane"
  # Per-issue lane → serializes runs working a single issue.
  check_concurrency_field "$wf" "dev-lead-issue-" "per-issue serialization lane"
  # ci-relay keeps its own ephemeral per-SHA slot so it fires without blocking
  # or being blocked by the dispatch queue.
  check_concurrency_field "$wf" "dev-lead-ci-relay-" "ci-relay per-SHA group"
  # cancel-in-progress:false is what makes same-lane runs QUEUE (serialize)
  # rather than cancel — dropping queued runs would lose pickups.
  check_concurrency_field "$wf" "cancel-in-progress: false" "cancel-in-progress is false"
  # issue.pull_request must precede issue.number in the || chain: an
  # issue_comment on a PR has both issue.pull_request and issue.number truthy,
  # so the first match wins — reversing them would route PR comments to the
  # issue lane (dev-lead-issue-*) instead of the PR lane (dev-lead-pr-*).
  check_concurrency_order "$wf" "issue.pull_request" "dev-lead-issue-" "issue.pull_request before issue lane"
  # client_payload.pr_number must precede the run-id fallback so
  # repository_dispatch events land in the correct PR lane, not a unique slot.
  check_concurrency_order "$wf" "client_payload.pr_number" "github.run_id" "client_payload.pr_number before run-id fallback"
done

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "All concurrency config checks passed."
else
  echo "$FAIL check(s) failed."
  exit 1
fi
