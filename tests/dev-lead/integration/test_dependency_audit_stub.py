#!/usr/bin/env python3
"""Validate that dependency-audit.yml is the canonical org stub pinned to @dependency-audit/v2-next.

The org standard requires dependency-audit.yml to be a thin caller stub that
delegates to the reusable at @dependency-audit/v2-next (major-scope repin #657;
this repo is pinned to the v2 channel ahead of the canonical @dependency-audit/next).

Standard: petry-projects/.github/standards/ci-standards.md#centralization-tiers
Source of truth: petry-projects/.github/standards/workflows/dependency-audit.yml
"""
from __future__ import annotations

import sys

try:
    import yaml
except ImportError:
    print("FAIL: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

WORKFLOW = ".github/workflows/dependency-audit.yml"
EXPECTED_USES = "petry-projects/.github/.github/workflows/dependency-audit-reusable.yml@dependency-audit/v2-next"


def main() -> int:
    try:
        with open(WORKFLOW, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except FileNotFoundError:
        print(f"FAIL: {WORKFLOW} not found")
        return 1
    except yaml.YAMLError as err:
        print(f"FAIL: {WORKFLOW} is not valid YAML: {err}")
        return 1

    if not isinstance(doc, dict):
        print(f"FAIL: {WORKFLOW} did not parse as a YAML mapping")
        return 1

    jobs = doc.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        print(f"FAIL: {WORKFLOW} 'jobs' key is missing, empty, or not a mapping")
        return 1

    for job_key, job in jobs.items():
        if not isinstance(job, dict):
            continue
        uses = job.get("uses")
        if isinstance(uses, str) and "dependency-audit-reusable.yml" in uses:
            if uses == EXPECTED_USES:
                print(f"PASS: {WORKFLOW} job '{job_key}' delegates to {EXPECTED_USES}")
                return 0
            else:
                print(
                    f"FAIL: {WORKFLOW} job '{job_key}' uses '{uses}'\n"
                    f"  Expected: '{EXPECTED_USES}'\n"
                    f"  Fix: replace the `uses:` value with the canonical @dependency-audit/next ref."
                )
                return 1

    print(
        f"FAIL: {WORKFLOW} has no job calling dependency-audit-reusable.yml\n"
        f"  Expected a job with: uses: {EXPECTED_USES}"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
