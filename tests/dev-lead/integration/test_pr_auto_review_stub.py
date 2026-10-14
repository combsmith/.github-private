#!/usr/bin/env python3
"""Validate that the pr-auto-review.yml caller stub skips Dependabot-triggered events.

A Dependabot `pull_request` run has no access to org/repo secrets, so the caller's
`secrets.GH_PAT_DON_PETRY || secrets.GH_PAT_WORKFLOWS` resolves to an empty string and
the reusable's ready-check tooling checkout fails at startup with
"Input required and not supplied: token" (the 20% failure the Fleet Monitor flagged in
#1390). The fix mirrors the documented #864 precedent in dev-lead-reusable.yml: guard the
calling job with `if: github.actor != 'dependabot[bot]'` so it skips cleanly before the
reusable's checkout. Dependabot PRs are handled by dependabot-automerge.yml and never need
the review-agent dispatch.

Regression guard: dropping the Dependabot guard (or repinning off the @pr-auto-review/v1-next
channel) reintroduces the failure class.
"""
from __future__ import annotations

import sys

try:
    import yaml
except ImportError:
    yaml = None

WORKFLOW = ".github/workflows/pr-auto-review.yml"
REUSABLE = "petry-projects/.github/.github/workflows/pr-auto-review-reusable.yml"
EXPECTED_REF = "@pr-auto-review/v1-next"
DEPENDABOT_ACTOR = "dependabot[bot]"


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
    except yaml.YAMLError as exc:
        print(f"FAIL: {WORKFLOW} contains invalid YAML: {exc}", file=sys.stderr)
        return 1

    if not isinstance(doc, dict):
        print(f"FAIL: {WORKFLOW} did not parse as a YAML mapping")
        return 1

    jobs = doc.get("jobs") or {}
    if not isinstance(jobs, dict):
        print(f"FAIL: {WORKFLOW} 'jobs' key is not a mapping")
        return 1

    caller_jobs = [
        job
        for job in jobs.values()
        if isinstance(job, dict) and isinstance(job.get("uses"), str) and REUSABLE in job["uses"]
    ]

    if not caller_jobs:
        print(f"FAIL: {WORKFLOW} does not call {REUSABLE}")
        return 1

    failures = []
    for job in caller_jobs:
        ref = job["uses"]
        if not ref.endswith(EXPECTED_REF):
            failures.append(
                f"  Wrong ref: {ref!r}\n"
                f"  Expected:  '{REUSABLE}{EXPECTED_REF}'\n"
                "  Reason: first-party reusable must stay on the @pr-auto-review/v1-next\n"
                "  moving channel (AGENTS.md §Release channel tags)."
            )

        expected_guard = (
            f"github.actor != '{DEPENDABOT_ACTOR}' && "
            f"github.event.pull_request.user.login != '{DEPENDABOT_ACTOR}'"
        )
        guard = job.get("if")
        if not isinstance(guard, str) or guard.strip() != expected_guard:
            failures.append(
                f"  Missing Dependabot guard: job 'if' is {guard!r}\n"
                f"  Expected exactly:\n"
                f"    if: {expected_guard}\n"
                "  Reason: actor-only guard is bypassed on re-runs; PR-author check\n"
                "  also skips pull_request_review events on Dependabot PRs.\n"
                "  Dependabot runs lack GH_PAT_WORKFLOWS, so the reusable's\n"
                "  checkout fails with 'Input required and not supplied: token' (#1390, #864)."
            )

    if failures:
        print(f"FAIL: {WORKFLOW} caller stub is misconfigured:")
        for msg in failures:
            print(msg)
        return 1

    print(
        f"PASS: {WORKFLOW} pins {REUSABLE}{EXPECTED_REF} and skips {DEPENDABOT_ACTOR}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
