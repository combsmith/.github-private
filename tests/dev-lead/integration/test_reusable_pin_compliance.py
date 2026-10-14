#!/usr/bin/env python3
"""Generalized pin-compliance scanner for first-party reusables (issue #687).

One CI check that scans every first-party reusable caller/template and fails on a
SHA or off-channel (`@main` / `# main`) pin while allowing the sanctioned channel
and version tags. This inverts the usual SHA-pin standard: that standard targets
*third-party* actions (see AGENTS.md "Release channel tags & the mutable-ref
exception"), whereas first-party reusables we own are versioned via *mutable*
channel tags — so for them a SHA / `@main` pin is the violation and a channel or
version tag is required.

Scope (AC #1): job-level `uses:` refs pointing at a first-party reusable —
  combsmith/.github-private/.github/workflows/*-reusable.yml
  combsmith/.github/.github/workflows/*-reusable.yml
plus the self-host pr-review caller (combsmith/.github-private/.github/workflows/pr-review.yml)
— across .github/workflows/* and templates/*. Local `./` reusable calls carry no
`@ref` (GitHub uses the caller's own commit) and are out of scope. Third-party
actions still follow the SHA-pin standard and are untouched.

Sanctioned pins (AC #3): a channel tag `<name>/{stable,next,ring<N>}` or its
major-scoped form `<name>/v<MAJOR>-{stable,next,ring<N>}`, an immutable
`<name>/vMAJOR.MINOR.PATCH` release tag, or a bare `@vN`.

Usage:
    python3 tests/dev-lead/integration/test_reusable_pin_compliance.py [FILE ...]
With no args it scans the default roots; with args it scans exactly those files
(used to exercise the classifier against fixtures). Exit 0 = compliant.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("FAIL: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

DEFAULT_GLOBS = (
    ".github/workflows/*.yml",
    ".github/workflows/*.yaml",
    "templates/**/*.yml",
    "templates/**/*.yaml",
)

# owner/repo/.github/workflows/<file> for a first-party reusable path.
FIRST_PARTY_PATH_RE = re.compile(
    r"^combsmith/(?:\.github|\.github-private)/\.github/workflows/"
    r"(?P<file>[A-Za-z0-9._-]+\.ya?ml)$"
)

SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")
CHANNEL_RE = re.compile(r"^[a-z0-9][a-z0-9-]*/(?:stable|next|ring\d+)$")
CHANNEL_MAJOR_RE = re.compile(r"^[a-z0-9][a-z0-9-]*/v\d+-(?:stable|next|ring\d+)$")
SEMVER_RE = re.compile(r"^[a-z0-9][a-z0-9-]*/v\d+\.\d+\.\d+$")
BARE_VN_RE = re.compile(r"^v\d+$")

USES_LINE_RE = re.compile(r"^\s*uses:\s*(?P<val>[^\s#]+)\s*(?P<comment>#.*)?$")
# A branch annotation naming main/master is off-channel; a SHA + `# main` comment
# is the classic pin-with-branch-note that this standard forbids for first-party.
OFF_CHANNEL_COMMENT_RE = re.compile(r"(?<![\w-])(?:main|master)(?![\w-])", re.IGNORECASE)


def is_first_party_reusable(path: str) -> bool:
    m = FIRST_PARTY_PATH_RE.match(path)
    if not m:
        return False
    name = m.group("file")
    return (
        name.endswith("-reusable.yml") or name.endswith("-reusable.yaml")
        or name in ("pr-review.yml", "pr-review.yaml")
    )


def is_sanctioned_tag(ref: str) -> bool:
    return bool(
        CHANNEL_RE.match(ref)
        or CHANNEL_MAJOR_RE.match(ref)
        or SEMVER_RE.match(ref)
        or BARE_VN_RE.match(ref)
    )


def classify_ref(ref: str) -> str | None:
    """Return a violation reason, or None when the ref is a sanctioned pin."""
    if ref == "":
        return "no @ref — a first-party reusable must pin a sanctioned channel/version tag"
    if SHA_RE.match(ref):
        return (
            f"SHA-pinned (@{ref}) — first-party reusables must pin a channel/version "
            "tag, not a 40-hex SHA"
        )
    if ref in ("main", "master") or ref.endswith("/main") or ref.endswith("/master"):
        return f"off-channel pin (@{ref}) — must pin a sanctioned channel/version tag, not main/master"
    if not is_sanctioned_tag(ref):
        return (
            f"unsanctioned ref (@{ref}) — expected <name>/{{stable,next,ring<N>}}, "
            "<name>/v<MAJOR>-<tier>, <name>/vX.Y.Z, or @vN"
        )
    return None


def off_channel_comment(comment: str | None) -> bool:
    if not comment:
        return False
    cleaned = re.sub(r"NOSONAR\([^)]*\)", "", comment)
    return bool(OFF_CHANNEL_COMMENT_RE.search(cleaned))


def raw_comment_map(text: str) -> dict[tuple[str, str], str]:
    """Map (job_id, uses_val) to its trailing comment (YAML strips comments on load)."""
    out: dict[tuple[str, str], str] = {}
    current_job: str | None = None
    in_jobs = False
    for line in text.splitlines():
        if line.strip() == "jobs:":
            in_jobs = True
            continue
        if in_jobs:
            m_job = re.match(r"^  (?P<job_id>[A-Za-z0-9_-]+):\s*(?:#.*)?$", line)
            if m_job:
                current_job = m_job.group("job_id")
                continue
            elif re.match(r"^[^#\s]", line):
                in_jobs = False
                current_job = None
                continue
            if current_job:
                m_uses = USES_LINE_RE.match(line)
                if m_uses and m_uses.group("comment"):
                    val = m_uses.group("val").strip().strip('"').strip("'")
                    out[(current_job, val)] = m_uses.group("comment")
    return out


def scan_file(path: Path) -> tuple[list[str], int]:
    """Return (violations, first_party_refs_checked) for one workflow/template file."""
    text = path.read_text(encoding="utf-8")
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as err:
        return [f"{path}: not valid YAML: {err}"], 0
    if not isinstance(doc, dict):
        return [], 0
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        return [], 0

    comments = raw_comment_map(text)
    violations: list[str] = []
    checked = 0

    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        uses = job.get("uses")
        if not isinstance(uses, str):
            continue
        job_path, _, ref = uses.partition("@")
        if not is_first_party_reusable(job_path):
            continue
        checked += 1
        reason = classify_ref(ref)
        if reason:
            violations.append(f"{path}: job '{job_id}': {reason}")
        comment = comments.get((job_id, uses))
        if off_channel_comment(comment):
            violations.append(
                f"{path}: job '{job_id}': off-channel `{comment.strip()}` annotation "
                "on a first-party reusable pin"
            )
    return violations, checked


def collect_files(argv: list[str]) -> tuple[list[Path], bool]:
    if argv:
        return [Path(a) for a in argv], True
    root = Path(".")
    files: list[Path] = []
    seen: set[Path] = set()
    for pattern in DEFAULT_GLOBS:
        for f in sorted(root.glob(pattern)):
            if f not in seen:
                seen.add(f)
                files.append(f)
    return files, False


def main(argv: list[str]) -> int:
    files, explicit = collect_files(argv[1:])
    violations: list[str] = []
    checked = 0
    for f in files:
        if not f.is_file():
            print(f"FAIL: {f} not found")
            return 1
        file_violations, file_checked = scan_file(f)
        violations.extend(file_violations)
        checked += file_checked

    if violations:
        print(f"FAIL: {len(violations)} first-party reusable pin compliance violation(s):")
        for v in violations:
            print(f"  {v}")
        print(
            "\n  Fix: pin first-party reusables to a sanctioned channel/version tag "
            "(<name>/stable, <name>/v<MAJOR>-<tier>, <name>/vX.Y.Z, or @vN).\n"
            "  See AGENTS.md 'Release channel tags & the mutable-ref exception'."
        )
        return 1

    if not explicit and checked == 0:
        print(
            "FAIL: scanned the default roots but found no first-party reusable refs — "
            "the scanner globs are likely broken; refusing to pass vacuously."
        )
        return 1

    print(f"PASS: {checked} first-party reusable pin(s) across {len(files)} file(s) compliant")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
