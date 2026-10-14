#!/usr/bin/env python3
"""Validate that auto-rebase.yml uses the @auto-rebase/v2-next channel tag, not a SHA or frozen @vX.

AGENTS.md §"Release channel tags & the mutable-ref exception" exempts first-party
reusable workflows from the SHA-pin standard. This repo (.github-private) is pinned
to the @auto-rebase/v2-next channel (major-scope repin #657), which is the current
moving channel for this ring ahead of the canonical @auto-rebase/next standard.

Regression guard: a SHA-pinned or frozen-tag reference is a compliance violation (issue #139).
"""
from __future__ import annotations

import re
import sys

try:
    import yaml
except ImportError:
    yaml = None

WORKFLOW = ".github/workflows/auto-rebase.yml"
REUSABLE = "petry-projects/.github/.github/workflows/auto-rebase-reusable.yml"
EXPECTED_REF = "@auto-rebase/v2-next"
SHA_PATTERN = re.compile(r"@[0-9a-f]{40}\b")


def main() -> int:
    if yaml is None:
        print("FAIL: PyYAML is required (pip install pyyaml)", file=sys.stderr)
        return 2

    try:
        with open(WORKFLOW, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except FileNotFoundError:
        print(f"FAIL: {WORKFLOW} not found")
        return 1

    if not isinstance(doc, dict):
        print(f"FAIL: {WORKFLOW} did not parse as a YAML mapping")
        return 1

    jobs = doc.get("jobs") or {}
    if not isinstance(jobs, dict):
        print(f"FAIL: {WORKFLOW} 'jobs' key is not a mapping")
        return 1

    uses_values = [
        job["uses"]
        for job in jobs.values()
        if isinstance(job, dict) and isinstance(job.get("uses"), str)
    ]

    reusable_refs = [u for u in uses_values if REUSABLE in u]

    if not reusable_refs:
        print(f"FAIL: {WORKFLOW} does not call {REUSABLE}")
        return 1

    failures = []
    for ref in reusable_refs:
        if SHA_PATTERN.search(ref):
            failures.append(
                f"  SHA-pinned: {ref!r}\n"
                f"  Expected:   '{REUSABLE}{EXPECTED_REF}'\n"
                "  Reason: first-party reusable workflows must use the @auto-rebase/v2-next\n"
                "  channel tag, not a SHA (AGENTS.md §Release channel tags)."
            )
        elif not ref.endswith(EXPECTED_REF):
            failures.append(
                f"  Wrong ref: {ref!r}\n"
                f"  Expected:  '{REUSABLE}{EXPECTED_REF}'"
            )

    if failures:
        print(f"FAIL: {WORKFLOW} does not reference the reusable with {EXPECTED_REF}:")
        for msg in failures:
            print(msg)
        return 1

    print(f"PASS: {WORKFLOW} correctly references {REUSABLE}{EXPECTED_REF}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
