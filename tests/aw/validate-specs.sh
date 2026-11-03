#!/usr/bin/env bash
# tests/aw/validate-specs.sh
#
# Validates the agentic workflow (aw) specs, docs, and workflow YAML files.
# Each workflow must have:
#   1. A non-empty scenario spec at tests/aw/{name}/scenarios.md
#   2. A non-empty doc at docs/aw/{name}.md
#   3. A valid YAML workflow at .github/workflows/{name}.yml
#      (checked via python3 yaml.safe_load)
#   4. The workflow YAML must contain: 'name:', 'on:', 'jobs:'
#   5. An executable shell script at scripts/aw-{name}.sh
#      (checked via bash -n syntax validation)
#
# Exit code: 0 = all checks pass; 1 = one or more checks failed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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

# ---------------------------------------------------------------------------
# Workflows to validate
# ---------------------------------------------------------------------------
WORKFLOWS=(
  "docs-health-check"
  "dependency-advisory"
  "standards-sync"
)

# ---------------------------------------------------------------------------
# Per-workflow checks
# ---------------------------------------------------------------------------
for wf in "${WORKFLOWS[@]}"; do
  echo ""
  echo "--- ${wf} ---"

  # 1. Scenario spec exists and is non-empty
  spec="${REPO_ROOT}/tests/aw/${wf}/scenarios.md"
  if [[ -f "$spec" ]] && [[ -s "$spec" ]]; then
    ok "${wf}: scenario spec exists (tests/aw/${wf}/scenarios.md)"
  elif [[ ! -f "$spec" ]]; then
    fail "${wf}: scenario spec missing" "tests/aw/${wf}/scenarios.md not found"
  else
    fail "${wf}: scenario spec empty" "tests/aw/${wf}/scenarios.md is zero bytes"
  fi

  # Scenario spec must have at least one "## Scenario" heading
  if [[ -f "$spec" ]] && grep -q "^## Scenario" "$spec" 2>/dev/null; then
    ok "${wf}: scenario spec has scenario headings"
  else
    fail "${wf}: scenario spec malformed" "no '## Scenario' headings found in tests/aw/${wf}/scenarios.md"
  fi

  # 2. Doc exists and is non-empty
  doc="${REPO_ROOT}/docs/aw/${wf}.md"
  if [[ -f "$doc" ]] && [[ -s "$doc" ]]; then
    ok "${wf}: doc exists (docs/aw/${wf}.md)"
  elif [[ ! -f "$doc" ]]; then
    fail "${wf}: doc missing" "docs/aw/${wf}.md not found"
  else
    fail "${wf}: doc empty" "docs/aw/${wf}.md is zero bytes"
  fi

  # 3. Workflow YAML exists and is valid YAML
  yml="${REPO_ROOT}/.github/workflows/${wf}.yml"
  if [[ ! -f "$yml" ]]; then
    fail "${wf}: workflow YAML missing" ".github/workflows/${wf}.yml not found"
  else
    if python3 -c "
import sys, yaml
try:
    yaml.safe_load(open(sys.argv[1]))
    sys.exit(0)
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" "$yml" 2>/dev/null; then
      ok "${wf}: workflow YAML is valid"
    else
      fail "${wf}: workflow YAML invalid" ".github/workflows/${wf}.yml failed yaml.safe_load"
    fi

    # 4. Workflow YAML has required top-level keys
    for key in name on jobs; do
      if grep -q "^${key}:" "$yml" 2>/dev/null; then
        ok "${wf}: workflow YAML has '${key}:'"
      else
        fail "${wf}: workflow YAML missing '${key}:'" ".github/workflows/${wf}.yml has no top-level '${key}:' key"
      fi
    done

    # 5. Workflow YAML references the corresponding script
    if grep -q "aw-${wf}.sh" "$yml" 2>/dev/null; then
      ok "${wf}: workflow YAML references scripts/aw-${wf}.sh"
    else
      fail "${wf}: workflow YAML does not reference script" ".github/workflows/${wf}.yml has no reference to scripts/aw-${wf}.sh"
    fi
  fi

  # 6. Shell script exists and passes bash -n syntax check
  script="${REPO_ROOT}/scripts/aw-${wf}.sh"
  if [[ ! -f "$script" ]]; then
    fail "${wf}: script missing" "scripts/aw-${wf}.sh not found"
  else
    if bash -n "$script" 2>/dev/null; then
      ok "${wf}: scripts/aw-${wf}.sh passes bash -n"
    else
      fail "${wf}: script has syntax errors" "bash -n scripts/aw-${wf}.sh failed"
    fi

    # Script must have set -euo pipefail
    if grep -q "set -euo pipefail" "$script" 2>/dev/null; then
      ok "${wf}: script uses set -euo pipefail"
    else
      fail "${wf}: script missing set -euo pipefail" "scripts/aw-${wf}.sh does not call 'set -euo pipefail'"
    fi
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
  printf '%b' "$ERRORS"
  exit 1
fi
