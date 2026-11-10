#!/usr/bin/env bash
# tests/aw/test_test_aw_yml.sh
#
# Structural regression test for .github/workflows/test-aw.yml.
# Guards against the failure mode reported in issue #696: the workflow installed
# PyYAML with the naive `pip install --quiet pyyaml` (no version pin, no
# --only-binary). That path resolves the latest version over the network on every
# run and can fall back to building from a source distribution — a slow,
# network-fragile step that intermittently failed or hit the 5-minute job timeout,
# driving the workflow's 29.4% failure rate. The fix pins the version and forces a
# wheel via --only-binary, matching the resilient pattern in issue-triage-runner.yml.
#
# Run: bash tests/aw/test_test_aw_yml.sh  (requires python3 + PyYAML)
set -euo pipefail

PASS=0
FAIL=0
ERRORS=""

ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS="${ERRORS}FAIL  $1: $2"$'\n'; printf 'FAIL  %s: %s\n' "$1" "$2"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
WF="${REPO_ROOT}/.github/workflows/test-aw.yml"
readonly WF

if ! command -v python3 &>/dev/null; then
  echo "Error: python3 is required to run these tests." >&2
  exit 1
fi
if ! python3 -c "import yaml" &>/dev/null; then
  echo "Error: PyYAML (python3-yaml) is required to run these tests." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Test 1: workflow file exists
# ---------------------------------------------------------------------------
if [[ -f "$WF" ]]; then
  ok "test-aw.yml: file exists"
else
  fail "test-aw.yml: file exists" "test-aw.yml not found"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# ---------------------------------------------------------------------------
# Test 2: every PyYAML install step is version-pinned and binary-only
# A run step that invokes `pip install ... pyyaml ...` must:
#   - pin the version (contain "pyyaml==", inline or in the hash-pinned
#     requirements/ci file it installs with --require-hashes -r, #1240)
#   - force a wheel (contain "--only-binary")
# so it cannot resolve an arbitrary version or build from source over the network.
# ---------------------------------------------------------------------------
if python3 - "$WF" <<'PYEOF'; then
import re
import sys
import yaml
with open(sys.argv[1], encoding='utf-8') as f:
    wf = yaml.safe_load(f) or {}

install_steps = []
for job in (wf.get('jobs', {}) or {}).values():
    for step in job.get('steps', []) or []:
        run = step.get('run') or ''
        # Identify steps that install pyyaml via pip (case-insensitive on the package name)
        if re.search(r'pip[0-9]*\s+install', run) and re.search(r'pyyaml', run, re.IGNORECASE):
            install_steps.append((step.get('name') or '<unnamed>', run))

if not install_steps:
    print("no PyYAML pip-install step found in test-aw.yml", file=sys.stderr)
    sys.exit(1)

import os
repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(sys.argv[1]))))

def pin_text(run):
    # Since #1240 the pin may live in a hash-pinned requirements file
    # (--require-hashes -r requirements/ci/<set>.txt) that itself pins pyyaml==X.
    text = run
    if '--require-hashes' in run:
        for req in re.findall(r'-r\s+(requirements/ci/[A-Za-z0-9._-]+\.txt)', run):
            path = os.path.join(repo_root, req)
            if os.path.isfile(path):
                with open(path, encoding='utf-8') as fh:
                    text += '\n' + fh.read()
    return text

bad = []
for name, run in install_steps:
    pinned = bool(re.search(r'pyyaml\s*==', pin_text(run), re.IGNORECASE))
    binary_only = '--only-binary' in run
    if not (pinned and binary_only):
        bad.append(f"{name!r}: pinned={pinned} only-binary={binary_only} :: {run.strip()!r}")

if bad:
    for b in bad:
        print(b, file=sys.stderr)
    sys.exit(1)
PYEOF
  ok "test-aw.yml: PyYAML installs are version-pinned and use --only-binary"
else
  fail "test-aw.yml: PyYAML installs are version-pinned and use --only-binary" \
    "each 'pip install ... pyyaml' step must pin the version (pyyaml==) and pass --only-binary so it cannot build from source over the network (issue #696)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  printf '%s' "$ERRORS"
  exit 1
fi
