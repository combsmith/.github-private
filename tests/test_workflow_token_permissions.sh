#!/usr/bin/env bash
set -euo pipefail
# test_workflow_token_permissions.sh — regression guard for issue #216
# (OpenSSF Scorecard "Token-Permissions", scored 0/10).
#
# Scorecard drops this check to 0 when any workflow leaves its top-level
# `permissions:` undeclared (the token then gets the repository default, which
# may be read/write) or grants a write scope there. A workflow-level grant
# applies to EVERY job, including jobs that only print a line, so write scopes
# belong on the job that needs them.
#
# This test asserts that every .github/workflows/*.yml file:
#   1. declares a top-level `permissions:` key, and
#   2. sets it to `{}`, `read-all`, or a map in which every scope is `read` or
#      `none`.
# Job-level write grants are allowed: that is where they should live.
#
# Self-tests run the checker against synthetic workflows first, so a broken
# checker cannot pass silently.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_DIR="${WORKFLOW_DIR:-${SCRIPT_DIR}/../.github/workflows}"

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "FAIL: python3 with PyYAML is required to run this test"
  exit 2
fi

# check_files <file>... — print one FAIL line per violation; exit 1 on any.
check_files() {
  python3 - "$@" <<'PY'
import sys
import yaml

READ_ONLY = {"read", "none"}
bad = 0
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    if not isinstance(doc, dict) or "permissions" not in doc:
        print(f"FAIL: {path}: no top-level 'permissions:' (token gets the repository default)")
        bad = 1
        continue
    perms = doc["permissions"]
    if perms in ({}, "read-all"):
        continue
    if isinstance(perms, dict):
        writes = sorted(k for k, v in perms.items() if v not in READ_ONLY)
        if writes:
            print(f"FAIL: {path}: top-level permissions grant write scope(s): {', '.join(writes)}"
                  " (move them to the job that needs them)")
            bad = 1
        continue
    print(f"FAIL: {path}: top-level permissions is {perms!r}; use {{}}, read-all, or read/none scopes")
    bad = 1
sys.exit(bad)
PY
}

# ── Self-tests ──────────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/good-empty.yml" <<'YAML'
on: push
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    permissions:
      issues: write
    steps: [{run: "true"}]
YAML
cat > "$TMP/good-read.yml" <<'YAML'
on: push
permissions:
  contents: read
  actions: none
jobs: {a: {runs-on: ubuntu-latest, steps: [{run: "true"}]}}
YAML
cat > "$TMP/good-readall.yml" <<'YAML'
on: push
permissions: read-all
jobs: {a: {runs-on: ubuntu-latest, steps: [{run: "true"}]}}
YAML
cat > "$TMP/bad-write.yml" <<'YAML'
on: push
permissions:
  contents: read
  issues: write
jobs: {a: {runs-on: ubuntu-latest, steps: [{run: "true"}]}}
YAML
cat > "$TMP/bad-writeall.yml" <<'YAML'
on: push
permissions: write-all
jobs: {a: {runs-on: ubuntu-latest, steps: [{run: "true"}]}}
YAML
cat > "$TMP/bad-missing.yml" <<'YAML'
on: push
jobs: {a: {runs-on: ubuntu-latest, steps: [{run: "true"}]}}
YAML

selftest_fail=0
for f in good-empty good-read good-readall; do
  if ! check_files "$TMP/$f.yml" >/dev/null; then
    echo "FAIL (self-test): checker rejected compliant fixture $f.yml"
    selftest_fail=1
  fi
done
for f in bad-write bad-writeall bad-missing; do
  if check_files "$TMP/$f.yml" >/dev/null; then
    echo "FAIL (self-test): checker accepted non-compliant fixture $f.yml"
    selftest_fail=1
  fi
done
if [ "$selftest_fail" -ne 0 ]; then
  exit 1
fi

# ── Real workflows ──────────────────────────────────────────────────────────
shopt -s nullglob
files=("$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml)
if [ "${#files[@]}" -eq 0 ]; then
  echo "FAIL: no workflow files found under $WORKFLOW_DIR"
  exit 1
fi

if check_files "${files[@]}"; then
  echo "PASS: all ${#files[@]} workflows keep top-level token permissions read-only (#216)"
else
  echo "Remediation: https://github.com/ossf/scorecard/blob/main/docs/checks.md#token-permissions"
  exit 1
fi
