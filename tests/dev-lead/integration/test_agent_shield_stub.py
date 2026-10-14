#!/usr/bin/env python3
"""Validate that agent-shield.yml is the canonical org stub pinned to a major-scoped channel.

The org standard requires agent-shield.yml to be a thin caller stub that delegates
to the reusable at a major-scoped channel tag `@agent-shield/v<N>-<tier>` (#1184),
with tier one of stable | next | ring<N>. Which tier a repo pins is decided by the
ring registry (combsmith/.github standards/canary-rings.json), the standards sweep
and the org audit — not by this test (#2625). A bare `@agent-shield/<tier>` pin
(missing the major scope) is drift (#1393); a SHA or `@main` ref is also rejected.

Standard: petry-projects/.github/standards/ci-standards.md#centralization-tiers
Source of truth: petry-projects/.github/standards/workflows/agent-shield.yml
"""
from __future__ import annotations

import re
import sys

try:
    import yaml
except ImportError:
    print("FAIL: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

WORKFLOW = ".github/workflows/agent-shield.yml"
REUSABLE = "combsmith/.github/.github/workflows/agent-shield-reusable.yml"
EXPECTED_USES = f"{REUSABLE}@agent-shield/v<N>-<stable|next|ring<N>>"
USES_RE = re.compile(re.escape(REUSABLE) + r"@agent-shield/v\d+-(?:stable|next|ring\d+)")
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


def check_workflow(doc) -> str | None:
    """Return a failure message for a parsed agent-shield.yml, or None if it conforms."""
    try:
        validate_workflow(doc)
    except ValueError as err:
        return f"is invalid: {err}"

    # Validate required trigger configuration
    # PyYAML (YAML 1.1) parses `on:` as boolean True, so check both forms
    on = doc.get(True, doc.get("on")) or {}
    if isinstance(on, str):
        on = {on: None}
    elif isinstance(on, list):
        on = {item: None for item in on}
    if not isinstance(on, dict):
        return "has an invalid 'on' trigger configuration"
    missing_triggers = REQUIRED_TRIGGERS - set(on.keys())
    if missing_triggers:
        return f"is missing required triggers: {sorted(missing_triggers)}"

    # Validate top-level permissions block is present
    if "permissions" not in doc:
        return "is missing top-level 'permissions' key"

    jobs = doc["jobs"]

    # Validate required job identity exists
    if EXPECTED_JOB not in jobs:
        return f"is missing required job '{EXPECTED_JOB}'"

    expected_job = jobs[EXPECTED_JOB]
    if not isinstance(expected_job, dict):
        return (
            f"job '{EXPECTED_JOB}' is not a mapping\n"
            f"  Expected a mapping with: uses: {EXPECTED_USES}"
        )

    uses = expected_job.get("uses")
    if not isinstance(uses, str):
        return (
            f"job '{EXPECTED_JOB}' is missing the 'uses' key\n"
            f"  Expected: uses: {EXPECTED_USES}"
        )

    if not USES_RE.fullmatch(uses):
        return (
            f"job '{EXPECTED_JOB}' uses '{uses}'\n"
            f"  Expected: '{EXPECTED_USES}'\n"
            f"  Fix: pin the reusable at a major-scoped agent-shield channel "
            f"(e.g. @agent-shield/v2-stable), not a bare tier, SHA, or branch."
        )

    # Validate no extra jobs (thin-stub delegates only via single job)
    extra_jobs = [job_key for job_key in jobs.keys() if job_key != EXPECTED_JOB]
    if extra_jobs:
        return (
            f"has unexpected job(s): {extra_jobs}\n"
            f"  A thin stub must have only the '{EXPECTED_JOB}' job."
        )

    return None


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

    err = check_workflow(doc)
    if err is not None:
        print(f"FAIL: {WORKFLOW} {err}")
        return 1

    uses = doc["jobs"][EXPECTED_JOB]["uses"]
    print(f"PASS: {EXPECTED_JOB} job correctly delegates to {uses}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
