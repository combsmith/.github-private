#!/usr/bin/env python3
"""Fixture cases for the agent-shield stub validator (#1393, #2625).

The validator must accept any major-scoped agent-shield channel
(`@agent-shield/v<N>-{stable,next,ring<N>}`) — which tier is correct is decided by
the standards sweep and the org audit (canary-rings.json), not by this test — and
must keep rejecting the bare `@agent-shield/<tier>` form (#1393), a SHA, and @main.

Standalone runner (repo convention: `python3 <file>`, exit 0 = pass). No pytest.
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import test_agent_shield_stub as mod  # noqa: E402

REUSABLE = "combsmith/.github/.github/workflows/agent-shield-reusable.yml"

_failures: list[str] = []


def fixture(uses: str, job: str = "agent-shield", triggers=("push", "pull_request")) -> dict:
    return {
        True: {t: None for t in triggers},
        "permissions": {"contents": "read"},
        "jobs": {job: {"uses": uses}},
    }


def expect(doc: dict, ok: bool, label: str) -> None:
    err = mod.check_workflow(doc)
    passed = (err is None) == ok
    verdict = "passes" if ok else "fails"
    if passed:
        print(f"  ok: {label} {verdict}")
    else:
        _failures.append(label)
        print(f"  FAIL: {label} should {verdict[:-1]} -> {err!r}")


def main() -> int:
    expect(fixture(f"{REUSABLE}@agent-shield/v2-stable"), True, "v2-stable")
    expect(fixture(f"{REUSABLE}@agent-shield/v2-next"), True, "v2-next")
    expect(fixture(f"{REUSABLE}@agent-shield/v3-stable"), True, "alternate major v3-stable")
    expect(fixture(f"{REUSABLE}@agent-shield/v2-ring0"), True, "ring tier v2-ring0")
    expect(fixture(f"{REUSABLE}@agent-shield/stable"), False, "bare @agent-shield/stable")
    expect(fixture(f"{REUSABLE}@{'a' * 40}"), False, "SHA ref")
    expect(fixture(f"{REUSABLE}@main"), False, "@main ref")
    expect(fixture(f"{REUSABLE}@agent-shield/v2-stable", job="shield"), False, "wrong job name")
    expect(fixture(f"{REUSABLE}@agent-shield/v2-stable", triggers=("push",)), False, "missing pull_request trigger")

    if _failures:
        print(f"FAIL: {len(_failures)} case(s) failed: {_failures}")
        return 1
    print("PASS: all agent-shield stub fixture cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
