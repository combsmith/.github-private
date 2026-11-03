#!/usr/bin/env bash
# tests/test_copilot_setup_steps.sh
#
# Validates that .github/workflows/copilot-setup-steps.yml exists and contains
# a job named exactly `copilot-setup-steps`, which GitHub requires to recognise
# the file for the Copilot cloud agent setup feature.
#
# Run: bash tests/test_copilot_setup_steps.sh

set -euo pipefail

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required to run this script." >&2
  exit 1
fi

if ! python3 -c "import yaml" &>/dev/null; then
  echo "ERROR: python3 'yaml' module (PyYAML) is required to run this script." >&2
  exit 1
fi

PASS=0
FAIL=0
ERRORS=""

ok() {
  local name="$1"
  PASS=$((PASS + 1))
  printf 'PASS  %s\n' "$name"
}

fail() {
  local name="$1"
  local msg="$2"
  FAIL=$((FAIL + 1))
  ERRORS="${ERRORS}FAIL  ${name}: ${msg}\n"
  printf 'FAIL  %s: %s\n' "$name" "$msg"
}

WORKFLOW=".github/workflows/copilot-setup-steps.yml"
YAML_VALID=0

# ---------------------------------------------------------------------------
# Test 1: File exists
# ---------------------------------------------------------------------------
if [[ -f "$WORKFLOW" ]]; then
  ok "copilot-setup-steps.yml exists"
else
  fail "copilot-setup-steps.yml exists" "file not found at $WORKFLOW"
fi

# ---------------------------------------------------------------------------
# Test 1.5: YAML is valid
# ---------------------------------------------------------------------------
if [[ -f "$WORKFLOW" ]]; then
  if python3 - "$WORKFLOW" << 'PY' 2>/dev/null
import sys, yaml
with open(sys.argv[1]) as f:
    yaml.safe_load(f)
PY
  then
    ok "copilot-setup-steps.yml is valid YAML"
    YAML_VALID=1
  else
    fail "copilot-setup-steps.yml is valid YAML" "failed to parse YAML file"
  fi
fi

# ---------------------------------------------------------------------------
# Test 2: Job named `copilot-setup-steps` is present
# GitHub requires this exact name to activate the workflow for Copilot agent.
# ---------------------------------------------------------------------------
if [[ "$YAML_VALID" -eq 1 ]]; then
  if python3 - "$WORKFLOW" << 'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    wf = yaml.safe_load(f) or {}
jobs = wf.get("jobs") or {}
if "copilot-setup-steps" not in jobs:
    print(f"jobs keys found: {list(jobs.keys())}", file=sys.stderr)
    sys.exit(1)
PY
  then
    ok "job named 'copilot-setup-steps' is present"
  else
    fail "job named 'copilot-setup-steps' is present" \
      "no job with that exact name — GitHub will not recognise the workflow"
  fi
fi

# ---------------------------------------------------------------------------
# Test 3: No other job names (GitHub only uses the copilot-setup-steps job)
# ---------------------------------------------------------------------------
if [[ "$YAML_VALID" -eq 1 ]]; then
  JOB_COUNT=$(python3 - "$WORKFLOW" << 'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    wf = yaml.safe_load(f) or {}
print(len(wf.get("jobs") or {}))
PY
)
  if [[ "$JOB_COUNT" == "1" ]]; then
    ok "workflow contains exactly 1 job"
  else
    fail "workflow contains exactly 1 job" "found $JOB_COUNT jobs — expected only copilot-setup-steps"
  fi
fi

# ---------------------------------------------------------------------------
# Test 4: timeout-minutes does not exceed 59 (GitHub hard limit)
# ---------------------------------------------------------------------------
if [[ "$YAML_VALID" -eq 1 ]]; then
  TIMEOUT=$(python3 - "$WORKFLOW" << 'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    wf = yaml.safe_load(f) or {}
jobs = wf.get("jobs") or {}
job = jobs.get("copilot-setup-steps") or {}
print(job.get("timeout-minutes", 0))
PY
)
  if [[ "$TIMEOUT" =~ ^[0-9]+$ ]] && [ "$TIMEOUT" -le 59 ] && [ "$TIMEOUT" -gt 0 ]; then  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449
    ok "timeout-minutes ($TIMEOUT) is within GitHub's 59-minute limit"
  else
    fail "timeout-minutes within limit" \
      "timeout-minutes=$TIMEOUT is invalid (must be 1–59)"
  fi
fi

# ---------------------------------------------------------------------------
# Test 5: Top-level permissions are reset to {} (least-privilege policy)
# ---------------------------------------------------------------------------
if [[ "$YAML_VALID" -eq 1 ]]; then
  PERMS=$(python3 - "$WORKFLOW" << 'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    wf = yaml.safe_load(f) or {}
perms = wf.get("permissions", "MISSING")
# {} or None (null) both represent "reset to empty" in YAML
if perms == {} or perms is None:
    print("empty")
else:
    print(repr(perms))
PY
)
  if [[ "$PERMS" = "empty" ]]; then
    ok "top-level permissions reset to {}"
  else
    fail "top-level permissions reset to {}" \
      "got: $PERMS — ci-standards.md requires top-level permissions: {}"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  printf '%b' "$ERRORS"
  exit 1
fi
