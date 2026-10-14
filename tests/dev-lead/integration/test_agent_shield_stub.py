#!/usr/bin/env python3
"""Validate that agent-shield.yml is the canonical org stub pinned to @agent-shield/v2-stable.

The org standard requires agent-shield.yml to be a thin caller stub that delegates
to the reusable at the major-scoped channel tag @agent-shield/v2-stable (#1184). A
bare @agent-shield/stable tier pin (missing the major scope) is drift (issue #1393).

Standard: petry-projects/.github/standards/ci-standards.md#centralization-tiers
Source of truth: petry-projects/.github/standards/workflows/agent-shield.yml
"""
from __future__ import annotations

import sys

try:
    import yaml
except ImportError:
    print("FAIL: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

WORKFLOW = ".github/workflows/agent-shield.yml"
EXPECTED_USES = "petry-projects/.github/.github/workflows/agent-shield-reusable.yml@agent-shield/v2-stable"
EXPECTED_JOB = "agent-shield"
REQUIRED_TRIGGERS = {"push", "pull_request"}


def validate_workflow(doc) -> None:
    if not isinstance(doc, dict):
        raise ValueError("Workflow configuration must be a dictionary")
    jobs = doc.get("jobs")
    if jobs is None:
        raise ValueError("Workflow configuration is missing the 'jobs' key")
    if not isinstance(jobs, dict):
        raise ValueError("The 'jobs' key in workflow configuration must be a dictionary")


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

    try:
        validate_workflow(doc)
    except ValueError as err:
        print(f"FAIL: {WORKFLOW}: {err}")
        return 1

    # Validate required trigger configuration
    # PyYAML (YAML 1.1) parses `on:` as boolean True, so check both forms
    on = doc.get(True, doc.get("on")) or {}
    if isinstance(on, str):
        on = {on: None}
    elif isinstance(on, list):
        on = {item: None for item in on}
    missing_triggers = REQUIRED_TRIGGERS - set(on.keys())
    if missing_triggers:
        print(f"FAIL: {WORKFLOW} is missing required triggers: {sorted(missing_triggers)}")
        return 1

    # Validate top-level permissions block is present
    if "permissions" not in doc:
        print(f"FAIL: {WORKFLOW} is missing top-level 'permissions' key")
        return 1

    jobs = doc["jobs"]

    # Validate required job identity exists
    if EXPECTED_JOB not in jobs:
        print(f"FAIL: {WORKFLOW} is missing required job '{EXPECTED_JOB}'")
        return 1

    expected_job = jobs[EXPECTED_JOB]
    if not isinstance(expected_job, dict):
        print(
            f"FAIL: {WORKFLOW} job '{EXPECTED_JOB}' is not a mapping\n"
            f"  Expected a mapping with: uses: {EXPECTED_USES}"
        )
        return 1

    uses = expected_job.get("uses")
    if not isinstance(uses, str):
        print(
            f"FAIL: {WORKFLOW} job '{EXPECTED_JOB}' is missing the 'uses' key\n"
            f"  Expected: uses: {EXPECTED_USES}"
        )
        return 1

    if uses != EXPECTED_USES:
        print(
            f"FAIL: {WORKFLOW} job '{EXPECTED_JOB}' uses '{uses}'\n"
            f"  Expected: '{EXPECTED_USES}'\n"
            f"  Fix: replace the `uses:` value with the canonical @agent-shield/v2-stable ref."
        )
        return 1

    # Validate no extra jobs (thin-stub delegates only via single job)
    extra_jobs = [job_key for job_key in jobs.keys() if job_key != EXPECTED_JOB]
    if extra_jobs:
        print(
            f"FAIL: {WORKFLOW} has unexpected job(s): {extra_jobs}\n"
            f"  A thin stub must have only the '{EXPECTED_JOB}' job."
        )
        return 1

    print(f"PASS: {EXPECTED_JOB} job correctly delegates to {EXPECTED_USES}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
