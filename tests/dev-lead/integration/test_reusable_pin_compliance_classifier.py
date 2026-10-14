#!/usr/bin/env python3
"""Classifier unit/behavior tests for the reusable-pin compliance scanner (#1493).

Exercises the #1184 legacy→major-scoped migration semantics that #687 ACs 7–9 add
on top of the original #687 scanner:

  - AC 7: the *canonical* form is the major-scoped channel `<name>/v<MAJOR>-<tier>`
    (or an immutable `<name>/vX.Y.Z`); a bare `<name>/<tier>` is NOT canonical.
  - AC 8: a bare `<name>/<tier>` is classified DEPRECATED — reported with file, line,
    and the major-scoped ref it should become.
  - AC 9: every legacy pin is inventoried with counts.
  - AC 12 (enforcement flip): the #1184 migration is complete, so a DEPRECATED legacy
    pin is now a FAILURE (exit 1), not a migration-window warning. The pin is still
    inventoried as DEPRECATED first (AC 9) and then fails the run.

Standalone runner (repo convention: `python3 <file>`, exit 0 = pass). No pytest.
"""
from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCANNER = HERE / "test_reusable_pin_compliance.py"

_spec = importlib.util.spec_from_file_location("pin_scanner", SCANNER)
assert _spec and _spec.loader
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)  # type: ignore[union-attr]

_failures: list[str] = []


def check(cond: bool, msg: str) -> None:
    if not cond:
        _failures.append(msg)
        print(f"  FAIL: {msg}")
    else:
        print(f"  ok: {msg}")


def test_classify_ref_canonical() -> None:
    print("test_classify_ref_canonical")
    for ref in (
        "dev-lead/v1-stable",
        "pr-review/v2-next",
        "agent-shield/v2-ring0",
        "ci-failure-analyst/v0-stable",
        "dev-lead/v1.2.3",
        "v1",
    ):
        status, detail = mod.classify_ref(ref)
        check(status == "ok" and detail is None, f"{ref!r} is canonical (ok) -> {status,detail}")


def test_classify_ref_deprecated() -> None:
    print("test_classify_ref_deprecated")
    cases = {
        "pr-review/next": "pr-review/v<MAJOR>-next",
        "ci-failure-analyst/stable": "ci-failure-analyst/v<MAJOR>-stable",
        "dev-lead/ring1": "dev-lead/v<MAJOR>-ring1",
    }
    for ref, want in cases.items():
        status, detail = mod.classify_ref(ref)
        check(
            status == "deprecated" and detail == want,
            f"{ref!r} is DEPRECATED with suggestion {want!r} -> {status,detail}",
        )


def test_classify_ref_violation() -> None:
    print("test_classify_ref_violation")
    for ref in (
        "",
        "a" * 40,  # SHA
        "main",
        "dev-lead/main",
        "not-a-tag",
    ):
        status, _ = mod.classify_ref(ref)
        check(status == "violation", f"{ref!r} is a violation -> {status}")


def _write(tmp: Path, name: str, body: str) -> Path:
    p = tmp / name
    p.write_text(body, encoding="utf-8")
    return p


def test_scan_file_captures_line_and_suggestion() -> None:
    print("test_scan_file_captures_line_and_suggestion")
    body = (
        "name: x\n"
        "on: [push]\n"
        "jobs:\n"
        "  review:\n"
        "    uses: petry-projects/.github-private/.github/workflows/pr-review.yml@pr-review/next\n"
    )
    with tempfile.TemporaryDirectory() as d:
        p = _write(Path(d), "wf.yml", body)
        violations, deprecations, checked, canonical = mod.scan_file(p)
        check(not violations, f"no hard violations -> {violations}")
        check(checked == 1, f"one first-party ref checked -> {checked}")
        check(canonical == 0, f"zero canonical -> {canonical}")
        check(len(deprecations) == 1, f"one deprecation -> {len(deprecations)}")
        if deprecations:
            dep = deprecations[0]
            check(dep["line"] == 5, f"deprecation at line 5 -> {dep.get('line')}")
            check(dep["ref"] == "pr-review/next", f"ref recorded -> {dep.get('ref')}")
            check(
                dep["suggestion"] == "pr-review/v<MAJOR>-next",
                f"suggestion recorded -> {dep.get('suggestion')}",
            )


def test_scan_file_canonical_passes_clean() -> None:
    print("test_scan_file_canonical_passes_clean")
    body = (
        "jobs:\n"
        "  dl:\n"
        "    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-stable\n"
    )
    with tempfile.TemporaryDirectory() as d:
        p = _write(Path(d), "wf.yml", body)
        violations, deprecations, checked, canonical = mod.scan_file(p)
        check(not violations and not deprecations, "canonical pin is clean")
        check(canonical == 1, f"one canonical -> {canonical}")


def _run_cli(files: list[str], env_extra: dict | None = None) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        [sys.executable, str(SCANNER), *files],
        capture_output=True,
        text=True,
        env=env,
    )


def test_cli_deprecated_now_fails_after_enforcement_flip() -> None:
    """AC 12: with the migration complete, a legacy bare-tier pin FAILS the run
    (exit 1) — it is still inventoried as DEPRECATED, then fails."""
    print("test_cli_deprecated_now_fails_after_enforcement_flip")
    body = (
        "jobs:\n"
        "  review:\n"
        "    uses: petry-projects/.github-private/.github/workflows/pr-review.yml@pr-review/next\n"
    )
    with tempfile.TemporaryDirectory() as d:
        summary = Path(d) / "summary.md"
        p = _write(Path(d), "wf.yml", body)
        proc = _run_cli([str(p)], {"GITHUB_STEP_SUMMARY": str(summary)})
        check(proc.returncode == 1, f"DEPRECATED legacy pin now fails (exit 1) -> {proc.returncode}\n{proc.stdout}")
        check("DEPRECATED" in proc.stdout, "output still labels the pin DEPRECATED (inventoried before failing)")
        check("pr-review/v<MAJOR>-next" in proc.stdout, "output shows the suggested major-scoped ref")
        # AC 9: exact counts still land in the run summary even on failure.
        text = summary.read_text(encoding="utf-8") if summary.exists() else ""
        check("- **canonical (major-scoped)**: 0" in text, f"run summary carries canonical count -> {text!r}")
        check("- **legacy (DEPRECATED)**: 1" in text, f"run summary carries legacy count -> {text!r}")
        check("- **checked**: 1" in text, f"run summary carries checked count -> {text!r}")


def test_cli_sha_still_fails() -> None:
    print("test_cli_sha_still_fails")
    body = (
        "jobs:\n"
        "  dl:\n"
        "    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@"
        + "a" * 40
        + "\n"
    )
    with tempfile.TemporaryDirectory() as d:
        p = _write(Path(d), "wf.yml", body)
        proc = _run_cli([str(p)])
        check(proc.returncode == 1, f"SHA pin still fails -> {proc.returncode}")


def test_scan_file_rejects_canonical_ref_with_mismatched_name() -> None:
    """A syntactically canonical ref whose name prefix does not match the reusable is a violation."""
    print("test_scan_file_rejects_canonical_ref_with_mismatched_name")
    # dev-lead-reusable.yml expects 'dev-lead/' prefix; 'pr-review/' belongs to another reusable.
    body = (
        "jobs:\n"
        "  dl:\n"
        "    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml"
        "@pr-review/v1-stable\n"
    )
    with tempfile.TemporaryDirectory() as d:
        p = _write(Path(d), "wf.yml", body)
        violations, deprecations, checked, canonical = mod.scan_file(p)
        check(len(violations) == 1, f"mismatched canonical name is a violation -> {violations}")
        check(
            any("mismatch" in v for v in violations),
            f"violation message mentions mismatch -> {violations}",
        )
        check(not deprecations, f"not classified as deprecation -> {deprecations}")


def test_scan_file_rejects_legacy_ref_with_mismatched_name() -> None:
    """A syntactically deprecated ref whose name prefix does not match the reusable is a violation, not a warning."""
    print("test_scan_file_rejects_legacy_ref_with_mismatched_name")
    # dev-lead-reusable.yml expects 'dev-lead/' prefix; 'other-name/' is wrong.
    body = (
        "jobs:\n"
        "  dl:\n"
        "    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml"
        "@other-name/next\n"
    )
    with tempfile.TemporaryDirectory() as d:
        p = _write(Path(d), "wf.yml", body)
        violations, deprecations, checked, canonical = mod.scan_file(p)
        check(len(violations) == 1, f"mismatched legacy name is a violation -> {violations}")
        check(not deprecations, f"not classified as deprecation -> {deprecations}")


def test_scan_file_quoted_job_id_line_mapping() -> None:
    """Quoted job keys like '"review":' must be tracked with the correct line number."""
    print("test_scan_file_quoted_job_id_line_mapping")
    body = (
        'name: x\n'
        'on: [push]\n'
        'jobs:\n'
        '  "review":\n'
        '    uses: petry-projects/.github-private/.github/workflows/pr-review.yml@pr-review/next\n'
    )
    with tempfile.TemporaryDirectory() as d:
        p = _write(Path(d), "wf.yml", body)
        violations, deprecations, checked, canonical = mod.scan_file(p)
        check(not violations, f"no hard violations for quoted job key -> {violations}")
        check(checked == 1, f"one first-party ref checked -> {checked}")
        check(len(deprecations) == 1, f"one deprecation -> {len(deprecations)}")
        if deprecations:
            dep = deprecations[0]
            check(dep["line"] == 5, f"correct line 5 (not 0) for quoted job -> {dep.get('line')}")


def test_scan_file_deprecated_with_off_channel_comment_classified_deprecation() -> None:
    """A deprecated legacy pin with an off-channel comment is classified as a deprecation, not a violation (enforcement of deprecations is decided by the caller, #1493 AC #12)."""
    print("test_scan_file_deprecated_with_off_channel_comment_classified_deprecation")
    body = (
        "jobs:\n"
        "  review:\n"
        "    uses: petry-projects/.github-private/.github/workflows/pr-review.yml"
        "@pr-review/next  # main\n"
    )
    with tempfile.TemporaryDirectory() as d:
        p = _write(Path(d), "wf.yml", body)
        violations, deprecations, checked, canonical = mod.scan_file(p)
        check(not violations, f"deprecated + off-channel comment stays warning, not violation -> {violations}")
        check(len(deprecations) == 1, f"one deprecation -> {len(deprecations)}")


def test_nested_workflow_included_in_inventory() -> None:
    """DEFAULT_GLOBS must inventory first-party pins in .github/workflows/ subdirectories.

    Post-flip (AC 12) a nested legacy pin is inventoried as DEPRECATED and then fails
    the run (exit 1)."""
    print("test_nested_workflow_included_in_inventory")
    body = (
        "jobs:\n"
        "  dl:\n"
        "    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/next\n"
    )
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        nested_dir = tmp / ".github" / "workflows" / "subdir"
        nested_dir.mkdir(parents=True)
        (nested_dir / "nested.yml").write_text(body, encoding="utf-8")
        proc = subprocess.run(
            [sys.executable, str(SCANNER)],
            capture_output=True,
            text=True,
            cwd=d,
        )
        check(proc.returncode == 1, f"nested legacy pin fails after the flip (exit 1) -> {proc.returncode}\n{proc.stdout}")
        check("DEPRECATED" in proc.stdout, f"nested pin still inventoried as DEPRECATED -> {proc.stdout}")


def test_scan_file_four_space_job_indent_line_mapping_and_comment() -> None:
    """Four-space job-key indentation: line mapping and comment detection must both work."""
    print("test_scan_file_four_space_job_indent_line_mapping_and_comment")
    # Deprecated legacy pin at four-space indent — line must be captured (not 0).
    body_deprecated = (
        "name: x\n"
        "on: [push]\n"
        "jobs:\n"
        "    review:\n"
        "        uses: petry-projects/.github-private/.github/workflows/pr-review.yml"
        "@pr-review/next\n"
    )
    with tempfile.TemporaryDirectory() as d:
        p = _write(Path(d), "wf.yml", body_deprecated)
        violations, deprecations, checked, canonical = mod.scan_file(p)
        check(not violations, f"no violations for four-space job indent (deprecated) -> {violations}")
        check(len(deprecations) == 1, f"one deprecation at four-space indent -> {len(deprecations)}")
        if deprecations:
            check(
                deprecations[0]["line"] == 5,
                f"correct line 5 (not 0) for four-space job indent -> {deprecations[0].get('line')}",
            )

    # Canonical pin with off-channel comment at four-space indent — raw_comment_map()
    # must capture the comment so the violation is reported (not silently bypassed).
    body_canonical_comment = (
        "name: x\n"
        "on: [push]\n"
        "jobs:\n"
        "    review:\n"
        "        uses: petry-projects/.github-private/.github/workflows/pr-review.yml"
        "@pr-review/v1-stable  # main\n"
    )
    with tempfile.TemporaryDirectory() as d:
        p = _write(Path(d), "wf.yml", body_canonical_comment)
        violations, deprecations, checked, canonical = mod.scan_file(p)
        check(
            len(violations) == 1,
            f"canonical + off-channel comment is a violation at four-space indent -> {violations}",
        )
        check(not deprecations, f"no deprecations for canonical pin -> {deprecations}")


def test_scan_file_quoted_root_jobs_key_line_and_comment() -> None:
    """A quoted root key (`"jobs":`) must still map lines and off-channel comments."""
    print("test_scan_file_quoted_root_jobs_key_line_and_comment")
    # Deprecated legacy pin under a quoted root jobs key — line must be captured (not 0).
    body_deprecated = (
        'name: x\n'
        'on: [push]\n'
        '"jobs":\n'
        '  review:\n'
        '    uses: petry-projects/.github-private/.github/workflows/pr-review.yml'
        '@pr-review/next\n'
    )
    with tempfile.TemporaryDirectory() as d:
        p = _write(Path(d), "wf.yml", body_deprecated)
        violations, deprecations, checked, canonical = mod.scan_file(p)
        check(not violations, f"no violations under quoted root jobs key -> {violations}")
        check(len(deprecations) == 1, f"one deprecation under quoted root jobs key -> {len(deprecations)}")
        if deprecations:
            check(
                deprecations[0]["line"] == 5,
                f"correct line 5 (not 0) under quoted root jobs key -> {deprecations[0].get('line')}",
            )

    # Canonical pin with off-channel comment under a quoted root jobs key — the
    # comment must be captured so the violation is reported (not silently bypassed).
    body_canonical_comment = (
        'name: x\n'
        'on: [push]\n'
        '"jobs":\n'
        '  review:\n'
        '    uses: petry-projects/.github-private/.github/workflows/pr-review.yml'
        '@pr-review/v1-stable  # main\n'
    )
    with tempfile.TemporaryDirectory() as d:
        p = _write(Path(d), "wf.yml", body_canonical_comment)
        violations, deprecations, checked, canonical = mod.scan_file(p)
        check(
            len(violations) == 1,
            f"canonical + off-channel comment is a violation under quoted root jobs key -> {violations}",
        )


def test_scan_file_commented_root_jobs_key_line_and_comment() -> None:
    """A root key with a trailing comment (`jobs: # …`) must still map lines and comments."""
    print("test_scan_file_commented_root_jobs_key_line_and_comment")
    # Deprecated legacy pin under a comment-trailed root jobs key — line captured (not 0).
    body_deprecated = (
        "name: x\n"
        "on: [push]\n"
        "jobs:  # source-map test\n"
        "  review:\n"
        "    uses: petry-projects/.github-private/.github/workflows/pr-review.yml"
        "@pr-review/next\n"
    )
    with tempfile.TemporaryDirectory() as d:
        p = _write(Path(d), "wf.yml", body_deprecated)
        violations, deprecations, checked, canonical = mod.scan_file(p)
        check(not violations, f"no violations under commented root jobs key -> {violations}")
        check(len(deprecations) == 1, f"one deprecation under commented root jobs key -> {len(deprecations)}")
        if deprecations:
            check(
                deprecations[0]["line"] == 5,
                f"correct line 5 (not 0) under commented root jobs key -> {deprecations[0].get('line')}",
            )

    # Canonical pin with off-channel comment under a comment-trailed root jobs key.
    body_canonical_comment = (
        "name: x\n"
        "on: [push]\n"
        "jobs:  # source-map test\n"
        "  review:\n"
        "    uses: petry-projects/.github-private/.github/workflows/pr-review.yml"
        "@pr-review/v1-stable  # main\n"
    )
    with tempfile.TemporaryDirectory() as d:
        p = _write(Path(d), "wf.yml", body_canonical_comment)
        violations, deprecations, checked, canonical = mod.scan_file(p)
        check(
            len(violations) == 1,
            f"canonical + off-channel comment is a violation under commented root jobs key -> {violations}",
        )


def main() -> int:
    test_classify_ref_canonical()
    test_classify_ref_deprecated()
    test_classify_ref_violation()
    test_scan_file_captures_line_and_suggestion()
    test_scan_file_canonical_passes_clean()
    test_scan_file_rejects_canonical_ref_with_mismatched_name()
    test_scan_file_rejects_legacy_ref_with_mismatched_name()
    test_cli_deprecated_now_fails_after_enforcement_flip()
    test_cli_sha_still_fails()
    test_scan_file_quoted_job_id_line_mapping()
    test_scan_file_deprecated_with_off_channel_comment_classified_deprecation()
    test_nested_workflow_included_in_inventory()
    test_scan_file_four_space_job_indent_line_mapping_and_comment()
    test_scan_file_quoted_root_jobs_key_line_and_comment()
    test_scan_file_commented_root_jobs_key_line_and_comment()
    if _failures:
        print(f"\nFAIL: {len(_failures)} classifier assertion(s) failed")
        return 1
    print("\nPASS: reusable-pin classifier migration semantics (#1493)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
