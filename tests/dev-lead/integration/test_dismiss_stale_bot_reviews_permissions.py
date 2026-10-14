#!/usr/bin/env python3
"""Validate that dismiss-stale-bot-reviews.yml has a top-level permissions: declaration.

Org least-privilege policy requires every workflow to declare permissions at the
top level (even if just `permissions: {}`) so that GitHub's default
write-all grant is never silently inherited.  The single `dismiss` job then
overrides with its own scoped block (`pull-requests: write`).

Compliance: missing-permissions-dismiss-stale-bot-reviews.yml (petry-projects/.github-private#1291)
Standard: https://github.com/petry-projects/.github/blob/main/standards/ci-standards.md#permissions-policy
"""
from __future__ import annotations

import sys

try:
    import yaml
except ImportError:
    print("FAIL: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

WORKFLOW = ".github/workflows/dismiss-stale-bot-reviews.yml"


def main() -> int:
    try:
        with open(WORKFLOW, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except FileNotFoundError:
        print(f"FAIL: {WORKFLOW} not found")
        return 1
    except yaml.YAMLError as exc:
        print(f"FAIL: {WORKFLOW} could not be parsed as YAML: {exc}")
        return 1

    if not isinstance(doc, dict):
        print(f"FAIL: {WORKFLOW} did not parse as a YAML mapping")
        return 1

    if "permissions" not in doc:
        print(
            f"FAIL: {WORKFLOW} is missing a top-level 'permissions:' declaration.\n"
            "  Add `permissions: {}` before `jobs:` to satisfy the least-privilege policy.\n"
            "  The dismiss job already has its own scoped permissions block — the top-level\n"
            "  block only needs to reset the GitHub default (write-all) to none."
        )
        return 1

    if doc.get("permissions") != {}:
        print(
            f"FAIL: {WORKFLOW} must set top-level permissions to an empty mapping.\n"
            "  Expected: `permissions: {}` to reset default token scopes to none."
        )
        return 1

    # Validate the dismiss job's scoped permissions contract.
    jobs = doc.get("jobs", {})
    if "dismiss" not in jobs:
        print(f"FAIL: {WORKFLOW} is missing the expected 'dismiss' job.")
        return 1

    dismiss_job = jobs["dismiss"]
    job_perms = dismiss_job.get("permissions")
    if not isinstance(job_perms, dict):
        print(
            f"FAIL: {WORKFLOW} 'dismiss' job is missing a 'permissions:' block.\n"
            "  The job must declare `pull-requests: write` to dismiss PR reviews."
        )
        return 1

    if job_perms.get("pull-requests") != "write":
        print(
            f"FAIL: {WORKFLOW} 'dismiss' job must set 'pull-requests: write'.\n"
            f"  Got: {job_perms!r}"
        )
        return 1

    allowed_keys = {"pull-requests"}
    extra = set(job_perms.keys()) - allowed_keys
    if extra:
        print(
            f"FAIL: {WORKFLOW} 'dismiss' job has unexpected extra permissions: {sorted(extra)}.\n"
            "  Least-privilege policy requires only 'pull-requests: write' on this job."
        )
        return 1

    print(f"PASS: {WORKFLOW} has a top-level 'permissions: {{}}' declaration.")
    print("PASS: 'dismiss' job declares exactly 'pull-requests: write' (least-privilege).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
