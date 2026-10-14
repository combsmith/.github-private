#!/usr/bin/env python3
"""Validate the dev-lead caller<->reusable GITHUB_TOKEN permission contract.

A reusable workflow's jobs can only use token permissions that the CALLER grants
at `jobs.<id>.permissions`. If any reusable job requests MORE than the caller
template grants, every consumer pinned to that reusable fails at startup
("startup_failure") — there is no runtime error, the run is simply invalid.

This is exactly what happened in petry-projects/.github#402: #435 added
`statuses: read` to the reusable's job permissions but the caller template was
never updated, so every @main consumer broke (.github was 15/15 startup_failure).

The contract: for every permission scope, the caller template must grant a level
>= the maximum any reusable job requests. This guard fails the build the moment
the reusable asks for something the template doesn't grant — at the PR that edits
the reusable, in the reusable's own repo, where the breaking change is made.

Reads:
  - reusable:  .github/workflows/dev-lead-reusable.yml   (this repo, local)
  - template:  standards/workflows/dev-lead.yml          (petry-projects/.github, fetched)
"""
from __future__ import annotations

import base64
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - CI installs it; clear message if not
    print("FAIL: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

LEVELS = {"none": 0, "read": 1, "write": 2}
INV = {v: k for k, v in LEVELS.items()}

TEMPLATE_REPO = "petry-projects/.github"
TEMPLATE_PATH = "standards/workflows/dev-lead.yml"
REUSABLE_PATH = ".github/workflows/dev-lead-reusable.yml"


def lvl(value) -> int:
    v = str(value).strip().lower()
    if v not in LEVELS:
        raise ValueError(f"Unknown permission level: {value!r}")
    return LEVELS[v]


def load_local(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def fetch_template() -> dict:
    """Fetch the caller template from the public petry-projects/.github repo."""
    res = subprocess.run(
        ["gh", "api", f"repos/{TEMPLATE_REPO}/contents/{TEMPLATE_PATH}", "--jq", ".content"],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        print(f"FAIL: could not fetch {TEMPLATE_REPO}:{TEMPLATE_PATH}\n{res.stderr.strip()}",
              file=sys.stderr)
        sys.exit(2)
    return yaml.safe_load(base64.b64decode(res.stdout))


def reusable_required(reusable: dict) -> dict[str, int]:
    """Max level each permission scope is requested across all reusable jobs.

    Records ``"*"`` as a wildcard key when a job (or inherited workflow-level
    block) uses the scalar shorthands ``write-all`` / ``read-all``, mirroring
    how ``caller_grants`` represents those shorthands on the caller side.
    """
    required: dict[str, int] = {}
    if not isinstance(reusable, dict):
        return required
    # Jobs without a per-job permissions block inherit the workflow-level permissions.
    workflow_perms = reusable.get("permissions") or {}
    for job in (reusable.get("jobs") or {}).values():
        perms = job.get("permissions") if isinstance(job, dict) else None
        if isinstance(perms, str):
            # Per-job scalar shorthand (write-all / read-all): record as wildcard.
            val = lvl("write" if perms == "write-all" else "read" if perms == "read-all" else "none")
            required["*"] = max(required.get("*", 0), val)
            continue
        if not isinstance(perms, dict):
            # No per-job block; inherit workflow-level permissions.
            if isinstance(workflow_perms, str):
                # Workflow-level scalar shorthand: record as wildcard.
                val = lvl("write" if workflow_perms == "write-all" else "read" if workflow_perms == "read-all" else "none")
                required["*"] = max(required.get("*", 0), val)
                continue
            perms = workflow_perms if isinstance(workflow_perms, dict) else None
        if not isinstance(perms, dict):
            continue
        for scope, level in perms.items():
            required[scope] = max(required.get(scope, 0), lvl(level))
    return required


def caller_grants(template: dict) -> list[tuple[str, dict[str, int]]]:
    """(job_key, grants) pairs for every job in the template that calls the reusable.

    Handles string shorthand permissions (write-all / read-all) by mapping them to
    a wildcard key ``"*"`` so the caller check in main() can fall back to it for
    any scope not explicitly listed. When a calling job omits its own permissions
    block, the workflow-level permissions are used as the default.
    """
    if not isinstance(template, dict):
        return []
    workflow_perms = template.get("permissions") or {}
    results = []
    for job_key, job in (template.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        if "dev-lead-reusable" in str(job.get("uses", "")):
            perms = job.get("permissions")
            if perms is None:
                # Fall back to workflow-level permissions when the job omits its own block.
                perms = workflow_perms
            if isinstance(perms, str):
                val = lvl("write" if perms == "write-all" else "read" if perms == "read-all" else "none")
                results.append((job_key, {"*": val}))
            elif isinstance(perms, dict):
                results.append((job_key, {scope: lvl(level) for scope, level in perms.items()}))
            else:
                results.append((job_key, {}))
    return results


def main() -> int:
    reusable = load_local(REUSABLE_PATH)
    template = fetch_template()

    required = reusable_required(reusable)
    all_grants = caller_grants(template)

    if not all_grants:
        print(f"FAIL: no job in {TEMPLATE_REPO}:{TEMPLATE_PATH} calls dev-lead-reusable")
        return 1

    failures = []
    for job_key, granted in all_grants:
        if len(all_grants) > 1:
            print(f"Caller job '{job_key}':")
        for scope, need in sorted(required.items()):
            if need == 0:
                continue
            have = granted.get(scope, granted.get("*", 0))
            status = "OK" if have >= need else "MISSING"
            print(f"  [{status}] {scope}: reusable needs {INV[need]}, template grants {INV.get(have, 'none')}")
            if have < need:
                failures.append((scope, need, have, job_key))

    print()
    if failures:
        print("FAIL: caller template under-grants permissions the reusable requests.")
        for scope, need, have, job_key in failures:
            print(f"  - add `{scope}: {INV[need]}` to {TEMPLATE_REPO}:{TEMPLATE_PATH} "
                  f"jobs.{job_key}.permissions (currently {INV.get(have, 'none')})")
        print("\nWithout it, every @main consumer fails at startup (startup_failure).")
        return 1

    print("PASS: caller template grants >= every permission the reusable jobs request.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
