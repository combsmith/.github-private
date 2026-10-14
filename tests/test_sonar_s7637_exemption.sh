#!/usr/bin/env bash
set -euo pipefail
# test_sonar_s7637_exemption.sh — regression guard for issue #943.
#
# SonarCloud's githubactions:S7637 ("pin actions to a full-length commit SHA")
# fires on the first-party petry-projects/.github(-private) reusable refs in our
# thin caller stubs. Those refs are intentionally pinned to a moving channel/tag
# (@<name>/stable, @v1/@v2) by org standard — NOT SHA-pinned. sonar-project.properties
# MUST suppress S7637 on each caller-stub file individually (one criterion per file),
# and MUST NOT use a blanket resourceKey that would also drop S7637 on ci.yml /
# sonarcloud.yml where third-party actions must stay SHA-pinned.
#
# Standard: standards/ci-standards.md#sonarcloud-exemption-first-party-reusable-ref-s7637

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROPS="${ROOT_DIR}/sonar-project.properties"
WORKFLOWS_DIR="${ROOT_DIR}/.github/workflows"
RULE="githubactions:S7637"
fail=0

# Canonical first-party reusable-ref caller stubs (standards/ci-standards.md). A
# repo exempts only the stubs it actually carries.
CANONICAL_STUBS=(
  agent-shield.yml
  pr-review-mention.yml
  pr-auto-review.yml
  auto-rebase.yml
  dependabot-rebase.yml
  dependabot-automerge.yml
  dependency-audit.yml
  feature-ideation.yml
  add-to-project.yml
  dev-lead.yml
  agent-ingress.yml
)

# Blanket resourceKeys that would over-suppress S7637 onto non-stub workflows.
FORBIDDEN_RESOURCEKEYS=(
  '**/.github/workflows/*.yml'
  '**/workflows/*.yml'
  'workflows/*.yml'
  '*.yml'
  '**/*.yml'
  '**'
)

if [ ! -f "$PROPS" ]; then
  echo "FAIL: $PROPS not found"
  exit 1
fi

# Collect the resourceKey of every multicriteria entry whose ruleKey is S7637.
s7637_resourcekeys=()
while IFS= read -r line; do
  # line shape: sonar.issue.ignore.multicriteria.<id>.ruleKey=githubactions:S7637
  id="${line#sonar.issue.ignore.multicriteria.}"
  id="${id%%.ruleKey=*}"
  rk_line="$(grep -E "^sonar\.issue\.ignore\.multicriteria\.${id}\.resourceKey=" "$PROPS" || true)"
  if [ -z "$rk_line" ]; then
    echo "FAIL: S7637 criterion '${id}' has no matching resourceKey in $PROPS"
    fail=1
    continue
  fi
  s7637_resourcekeys+=("${rk_line#*=}")
done < <(grep -E "^sonar\.issue\.ignore\.multicriteria\.[^.]+\.ruleKey=${RULE}$" "$PROPS" || true)

# 1) At least one S7637 exemption must exist (this is the sonar-s7637-exemption-missing check).
if [ "${#s7637_resourcekeys[@]}" -eq 0 ]; then
  echo "FAIL: $PROPS has no sonar.issue.ignore criterion for ${RULE}"
  echo "  Add a per-stub exemption — see standards/ci-standards.md#sonarcloud-exemption-first-party-reusable-ref-s7637"
  exit 1
fi

# Helper: is value present in the s7637_resourcekeys array?
has_resourcekey() {
  local needle="$1" rk
  for rk in "${s7637_resourcekeys[@]}"; do
    [ "$rk" = "$needle" ] && return 0
  done
  return 1
}

# 2) No blanket resourceKey may be paired with S7637 (sonar-s7637-exemption-too-broad).
for bad in "${FORBIDDEN_RESOURCEKEYS[@]}"; do
  if has_resourcekey "$bad"; then
    echo "FAIL: $PROPS suppresses ${RULE} with blanket resourceKey '${bad}'"
    echo "  This would also drop S7637 on ci.yml / sonarcloud.yml. Scope it per caller-stub file instead."
    fail=1
  fi
done

# 3) Every canonical caller stub present in this repo must have its own per-file exemption.
for stub in "${CANONICAL_STUBS[@]}"; do
  if [ -f "${WORKFLOWS_DIR}/${stub}" ]; then
    if ! has_resourcekey "**/${stub}"; then
      echo "FAIL: caller stub '${stub}' exists but $PROPS has no ${RULE} exemption with resourceKey '**/${stub}'"
      fail=1
    fi
  fi
done

# 4) Every S7637 resourceKey must point at a present canonical stub (no stale/wrong entries).
for rk in "${s7637_resourcekeys[@]}"; do
  base="${rk##*/}"
  is_canonical=0
  for stub in "${CANONICAL_STUBS[@]}"; do
    [ "$base" = "$stub" ] && is_canonical=1 && break
  done
  if [ "$is_canonical" -ne 1 ]; then
    echo "FAIL: $PROPS has an ${RULE} exemption for non-canonical resourceKey '${rk}'"
    fail=1
  elif [ ! -f "${WORKFLOWS_DIR}/${base}" ]; then
    echo "FAIL: $PROPS exempts '${rk}' for ${RULE} but workflow '${base}' does not exist"
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "PASS: $PROPS scopes ${RULE} exemption per present first-party caller stub (${#s7637_resourcekeys[@]} stubs)"
fi
exit "$fail"
