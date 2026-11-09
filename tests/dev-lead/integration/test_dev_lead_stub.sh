#!/usr/bin/env bash
# Validates that dev-lead.yml is a thin caller stub, not an inline workflow.
#
# The org standard (standards/ci-standards.md#5-dev-lead-agent) requires
# dev-lead.yml to delegate all logic to dev-lead-reusable.yml via a `uses:`
# call. An inline copy drifts independently and cannot benefit from central
# fixes to the reusable.
#
# Regression guard: compliance audit check `non-stub-dev-lead.yml` (issue #395)
# was filed because dev-lead.yml had diverged into a full inline workflow.
set -euo pipefail

WORKFLOW=".github/workflows/dev-lead.yml"
FAIL=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

# 1. File must exist.
if [[ ! -f "$WORKFLOW" ]]; then
  echo "ERROR: $WORKFLOW not found"
  exit 1
fi

# 2. Must contain a `uses:` line that calls dev-lead-reusable.yml at some ref.
#    Accepted: @main or a first-party channel tag (@dev-lead/stable, etc.).
#    See AGENTS.md §"Release channel tags & the mutable-ref exception".
if grep -qE 'dev-lead-reusable\.yml@\S+' "$WORKFLOW"; then
  ref=$(grep -oE 'dev-lead-reusable\.yml@\S+' "$WORKFLOW" | head -1)
  pass "dev-lead.yml delegates to ${ref} (thin caller stub)"
else
  fail "dev-lead.yml does not call dev-lead-reusable.yml — it must be a thin caller stub delegating to @main or a channel tag"
fi

# 3. Must NOT contain inline job steps (run: blocks with bash scripts).
#    A thin caller stub has no run: steps; all logic lives in the reusable.
if grep -qE '^\s+run:' "$WORKFLOW"; then
  fail "dev-lead.yml contains inline run: steps — expected a thin caller stub with no inline steps"
else
  pass "dev-lead.yml contains no inline run: steps (thin caller confirmed)"
fi

# 4. Must have `permissions: {}` at workflow level (zero standing permissions;
#    the reusable job declares its own per-job permissions).
if grep -qE '^permissions:\s*\{\s*\}' "$WORKFLOW"; then
  pass "dev-lead.yml has workflow-level permissions: {}"
else
  fail "dev-lead.yml must have 'permissions: {}' at workflow level (reusable job owns its permissions)"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All stub-structure checks passed."
else
  echo "$FAIL check(s) failed."
  exit 1
fi
