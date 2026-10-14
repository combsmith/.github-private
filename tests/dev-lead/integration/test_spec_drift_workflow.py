#!/usr/bin/env python3
"""Validate the structural + behavioral contract of spec-drift.yml (#1146, epic #1142).

spec-drift.yml is an OPT-IN, default-OFF post-merge workflow that runs the
validated detector (scripts/spec-drift.sh) on merged initiative-story PRs and
posts a single ADVISORY comment on a DRIFT verdict. It must never edit code,
reopen the issue, or fail the merge, and must cost nothing until a maintainer
turns it on.

This test pins the machine-checkable acceptance criteria so a future edit cannot
silently regress them:

  AC#1 — post-merge trigger scoped to merged PRs (pull_request: closed + a
         `merged == true` job gate).
  AC#2 — OPT-IN, byte-identical no-op when disabled: the job is gated on an
         explicit enable knob (vars.SPEC_DRIFT_ENABLED == 'true') so a skipped
         job spends zero runner minutes when off.
  AC#3/#4 — advisory only: least-privilege permissions (no `contents: write`),
         no reopen, and the detector is surfaced (never blocks the merge).
  AC#5 — the detector runs at most once (single `scripts/spec-drift.sh`
         invocation, no matrix fan-out).
  Plus: top-level `permissions: {}` (org least-privilege policy) and SHA-pinned
  actions per AGENTS.md.

Standard: petry-projects/.github/standards/ci-standards.md
"""
from __future__ import annotations

import re
import sys

try:
    import yaml
except ImportError:
    print("FAIL: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

WORKFLOW = ".github/workflows/spec-drift.yml"
ENABLE_KNOB = "SPEC_DRIFT_ENABLED"
DETECTOR = "scripts/spec-drift.sh"
SHA_PIN = re.compile(r"@[0-9a-f]{40}\b")


def _get_on(doc: dict):
    # PyYAML (YAML 1.1) parses the `on:` key as the boolean True.
    for key in (True, "on"):
        if key in doc:
            return doc[key]
    return None


def _iter_steps(jobs: dict):
    for job in jobs.values():
        if isinstance(job, dict):
            for step in job.get("steps") or []:
                if isinstance(step, dict):
                    yield step


def main() -> int:
    failures: list[str] = []

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

    # ── Top-level least-privilege reset ──────────────────────────────────────
    if doc.get("permissions") != {}:
        failures.append(
            "top-level `permissions:` must be an empty mapping ({}) to reset the "
            "default write-all grant."
        )

    # ── AC#1: post-merge trigger on closed PRs ───────────────────────────────
    on = _get_on(doc)
    pr_trigger = on.get("pull_request") if isinstance(on, dict) else None
    types = (pr_trigger or {}).get("types") if isinstance(pr_trigger, dict) else None
    if not (isinstance(types, list) and "closed" in types):
        failures.append(
            "trigger must be `pull_request: types: [closed]` so it runs post-merge "
            "(AC#1)."
        )
    # No cron: this workflow adds no scheduled automation (cost cap).
    if isinstance(on, dict) and "schedule" in on:
        failures.append("must NOT add a `schedule:` cron — one run per merged PR only (AC#5).")

    jobs = doc.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        print(f"FAIL: {WORKFLOW} 'jobs' key is missing, empty, or not a mapping")
        return 1

    # ── AC#1 + AC#2: merged gate AND opt-in enable knob ──────────────────────
    guarded = False
    for job in jobs.values():
        if not isinstance(job, dict):
            continue
        cond = str(job.get("if") or "")
        cond_norm = cond.replace(" ", "")
        if "merged==true" in cond_norm and f"vars.{ENABLE_KNOB}=='true'" in cond_norm:
            guarded = True
    if not guarded:
        failures.append(
            "a job must be gated on BOTH `github.event.pull_request.merged == true` "
            f"AND `vars.{ENABLE_KNOB} == 'true'` so it runs only on merged initiative "
            "PRs and is a zero-cost no-op when the enable knob is off (AC#1, AC#2)."
        )

    # ── AC#3/#4: least privilege — advisory only, never blocks/edits code ─────
    for job_key, job in jobs.items():
        if not isinstance(job, dict):
            continue
        perms = job.get("permissions")
        if not isinstance(perms, dict):
            failures.append(f"job '{job_key}' must declare a scoped `permissions:` block.")
            continue
        if perms.get("contents") == "write":
            failures.append(
                f"job '{job_key}' must NOT grant `contents: write` — the workflow "
                "never edits code (AC#3)."
            )
        if perms.get("issues") != "write":
            failures.append(
                f"job '{job_key}' needs `issues: write` to post the advisory comment (AC#3)."
            )

    # ── AC#5: detector runs at most once, no matrix fan-out ──────────────────
    for job_key, job in jobs.items():
        if isinstance(job, dict) and isinstance(job.get("strategy"), dict):
            if "matrix" in job["strategy"]:
                failures.append(
                    f"job '{job_key}' must not use a `strategy.matrix` — the detector "
                    "runs exactly once per merged PR (AC#5)."
                )

    detector_steps = [
        s for s in _iter_steps(jobs) if DETECTOR in str(s.get("run") or "")
    ]
    if len(detector_steps) != 1:
        failures.append(
            f"expected exactly ONE step invoking `{DETECTOR}`, found "
            f"{len(detector_steps)} (AC#5)."
        )

    # ── AC#1 false-negative guard: story resolution must distinguish a story from
    #    an epic by the BMAD story shape, not the `initiative` label alone —
    #    apply-plan.sh labels BOTH epics and stories `initiative`, so an epic could
    #    otherwise shadow the story, run the detector against a non-spec, return
    #    INDETERMINATE, and silently miss a real story DRIFT. ────────────────────
    resolve_steps = [
        s for s in _iter_steps(jobs)
        if "closingIssuesReferences" in str(s.get("run") or "")
    ]
    if not resolve_steps:
        failures.append(
            "expected a step resolving the closing story via "
            "`closingIssuesReferences` (AC#1)."
        )
    for s in resolve_steps:
        run = str(s.get("run") or "")
        if "## Story" not in run or "## Acceptance Criteria" not in run:
            failures.append(
                "the story-resolution step must require the BMAD story shape "
                "(`## Story` + `## Acceptance Criteria`), not just the `initiative` "
                "label — an epic carries that label too and would shadow the story, "
                "yielding INDETERMINATE and silently missing a real DRIFT (AC#1)."
            )

    # ── Advisory must never reopen the closed issue ──────────────────────────
    for step in _iter_steps(jobs):
        blob = str(step.get("run") or "") + str((step.get("with") or {}).get("script") or "")
        if re.search(r"state\s*:\s*['\"]?open", blob) or "reopenIssue" in blob:
            failures.append(
                "no step may reopen the closed story issue — the comment is a nudge, "
                "not a re-open (AC#3)."
            )

    # ── SHA-pinned actions (AGENTS.md) ───────────────────────────────────────
    for step in _iter_steps(jobs):
        uses = step.get("uses")
        if isinstance(uses, str) and not SHA_PIN.search(uses):
            failures.append(f"action `{uses}` must be pinned to a 40-char commit SHA (AGENTS.md).")

    if failures:
        print(f"FAIL: {WORKFLOW} violates the spec-drift contract:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print(f"PASS: {WORKFLOW} satisfies the spec-drift post-merge advisory contract.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
