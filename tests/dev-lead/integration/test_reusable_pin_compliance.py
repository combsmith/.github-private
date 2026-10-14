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
  petry-projects/.github-private/.github/workflows/*-reusable.yml
  petry-projects/.github/.github/workflows/*-reusable.yml
plus the self-host pr-review caller (petry-projects/.github-private/.github/workflows/pr-review.yml)
— across .github/workflows/* and templates/*. Local `./` reusable calls carry no
`@ref` (GitHub uses the caller's own commit) and are out of scope. Third-party
actions still follow the SHA-pin standard and are untouched.

Canonical pins (#687 AC #7, #1184): the *canonical* channel is the major-scoped
form `<name>/v<MAJOR>-{stable,next,ring<N>}`, an immutable
`<name>/vMAJOR.MINOR.PATCH` release tag, or a bare `@vN`. A bare
`<name>/{stable,next,ring<N>}` channel is the pre-#1184 **legacy** form: it is
reported as DEPRECATED (with file, line, and the major-scoped ref it should
become). The #1184 migration is now complete, so the enforcement flip has landed
(#687/#1493 AC #12): a DEPRECATED pin is a hard **failure** — inventoried first
(AC #9) so it is diagnosable, then it fails the run. It can never merge again.

Usage:
    python3 tests/dev-lead/integration/test_reusable_pin_compliance.py [FILE ...]
With no args it scans the default roots; with args it scans exactly those files
(used to exercise the classifier against fixtures). Exit 0 = compliant.
"""
from __future__ import annotations

import os
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
    # Recursive patterns cover files in subdirectories of .github/workflows/.
    # Python < 3.12 requires ** to match at least one component, so the
    # non-recursive *.yml lines above remain to catch top-level files.
    ".github/workflows/**/*.yml",
    ".github/workflows/**/*.yaml",
    "templates/**/*.yml",
    "templates/**/*.yaml",
)

# owner/repo/.github/workflows/<file> for a first-party reusable path.
FIRST_PARTY_PATH_RE = re.compile(
    r"^petry-projects/(?:\.github|\.github-private)/\.github/workflows/"
    r"(?P<file>[A-Za-z0-9._-]+\.ya?ml)$"
)

SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")
# Legacy (pre-#1184) bare-tier channel — DEPRECATED, not canonical (#687 AC #7/#8).
CHANNEL_LEGACY_RE = re.compile(
    r"^(?P<name>[a-z0-9][a-z0-9-]*)/(?P<tier>stable|next|ring\d+)$"
)
CHANNEL_MAJOR_RE = re.compile(r"^[a-z0-9][a-z0-9-]*/v\d+-(?:stable|next|ring\d+)$")
SEMVER_RE = re.compile(r"^[a-z0-9][a-z0-9-]*/v\d+\.\d+\.\d+$")
BARE_VN_RE = re.compile(r"^v\d+$")

USES_LINE_RE = re.compile(r"^\s*uses:\s*(?P<val>[^\s#]+)\s*(?P<comment>#.*)?$")
# A branch annotation naming main/master is off-channel; a SHA + `# main` comment
# is the classic pin-with-branch-note that this standard forbids for first-party.
OFF_CHANNEL_COMMENT_RE = re.compile(r"(?<![\w-])(?:main|master)(?![\w-])", re.IGNORECASE)

# Matches a job key line at any consistent indentation (two-space, four-space, etc.)
# with or without quoting.  The `indent` group captures leading spaces so callers
# can detect and enforce the actual jobs-child indentation level.
_JOB_KEY_RE = re.compile(
    r"""^(?P<indent> +)(?:(?P<bare>[A-Za-z0-9_-]+)|["'](?P<quoted>[A-Za-z0-9_-]+)["']):\s*(?:#.*)?$"""
)

# Matches the root `jobs:` mapping key. YAML permits the key to be quoted
# (`"jobs":` / `'jobs':`) and to carry a trailing comment (`jobs: # …`); a plain
# `line.strip() == "jobs:"` misses those forms, leaving the source maps empty so
# deprecated pins report line 0 and canonical pins bypass off-channel validation.
_ROOT_JOBS_KEY_RE = re.compile(r"""^(?:jobs|["']jobs["']):\s*(?:#.*)?$""")


def _is_root_jobs_key(line: str) -> bool:
    """Return True if `line` is the root `jobs:` key (quoted or comment-trailed)."""
    return bool(_ROOT_JOBS_KEY_RE.match(line))


def _detect_job_indent(line: str) -> str | None:
    """Return the leading-space string if `line` looks like a job key, else None."""
    m = _JOB_KEY_RE.match(line)
    return m.group("indent") if m else None


def _parse_job_id(line: str, expected_indent: str | None = None) -> str | None:
    """Return the job ID if `line` is a job-key line at `expected_indent`, else None.

    When `expected_indent` is None any leading-space indent is accepted (only safe
    before the first job key has been seen and the indent level is known).
    """
    m = _JOB_KEY_RE.match(line)
    if not m:
        return None
    if expected_indent is not None and m.group("indent") != expected_indent:
        return None
    return m.group("bare") or m.group("quoted")


def is_first_party_reusable(path: str) -> bool:
    m = FIRST_PARTY_PATH_RE.match(path)
    if not m:
        return False
    name = m.group("file")
    return (
        name.endswith("-reusable.yml") or name.endswith("-reusable.yaml")
        or name in ("pr-review.yml", "pr-review.yaml")
    )


def is_canonical_tag(ref: str) -> bool:
    """A canonical pin: major-scoped channel, immutable semver, or a bare @vN (#1184)."""
    return bool(
        CHANNEL_MAJOR_RE.match(ref)
        or SEMVER_RE.match(ref)
        or BARE_VN_RE.match(ref)
    )


def classify_ref(ref: str) -> tuple[str, str | None]:
    """Classify a first-party reusable `@ref`.

    Returns ``(status, detail)`` where ``status`` is one of:
      - ``"ok"``         — a canonical pin; ``detail`` is ``None``.
      - ``"deprecated"`` — a legacy bare `<name>/<tier>` channel (#1184); ``detail``
                            is the major-scoped ref it should become
                            (``<name>/v<MAJOR>-<tier>``). Post-migration this is a
                            hard failure at the run level (#1493 AC #12); the status
                            stays ``"deprecated"`` so the pin is inventoried first.
      - ``"violation"``  — a hard violation (SHA / off-channel / unsanctioned /
                            missing ref); ``detail`` is the human-readable reason.
    """
    if ref == "":
        return "violation", "no @ref — a first-party reusable must pin a canonical channel/version tag"
    if SHA_RE.match(ref):
        return "violation", (
            f"SHA-pinned (@{ref}) — first-party reusables must pin a channel/version "
            "tag, not a 40-hex SHA"
        )
    if ref in ("main", "master") or ref.endswith("/main") or ref.endswith("/master"):
        return "violation", (
            f"off-channel pin (@{ref}) — must pin a canonical channel/version tag, not main/master"
        )
    m = CHANNEL_LEGACY_RE.match(ref)
    if m:
        suggestion = f"{m.group('name')}/v<MAJOR>-{m.group('tier')}"
        return "deprecated", suggestion
    if not is_canonical_tag(ref):
        return "violation", (
            f"unsanctioned ref (@{ref}) — expected <name>/v<MAJOR>-<tier>, "
            "<name>/vX.Y.Z, or @vN"
        )
    return "ok", None


def _expected_channel_name(job_path: str) -> str | None:
    """Return the expected ref name-prefix for a first-party reusable path, or None.

    Derives the channel-name segment from the reusable filename:
      dev-lead-reusable.yml  → 'dev-lead'
      pr-review.yml          → 'pr-review'
    Returns None when the path is not a recognised first-party reusable.
    """
    m = FIRST_PARTY_PATH_RE.match(job_path)
    if not m:
        return None
    filename = m.group("file")
    for suffix in ("-reusable.yml", "-reusable.yaml"):
        if filename.endswith(suffix):
            return filename[: -len(suffix)]
    # pr-review.yml / pr-review.yaml (special allowlisted non-reusable name)
    return filename.rsplit(".", 1)[0]


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
    job_indent: str | None = None
    for line in text.splitlines():
        if _is_root_jobs_key(line):
            in_jobs = True
            job_indent = None
            continue
        if in_jobs:
            if job_indent is None:
                job_indent = _detect_job_indent(line)
            job_id = _parse_job_id(line, job_indent)
            if job_id is not None:
                current_job = job_id
                continue
            elif re.match(r"^[^#\s]", line):
                in_jobs = False
                current_job = None
                job_indent = None
                continue
            if current_job:
                m_uses = USES_LINE_RE.match(line)
                if m_uses and m_uses.group("comment"):
                    val = m_uses.group("val").strip().strip('"').strip("'")
                    out[(current_job, val)] = m_uses.group("comment")
    return out


def uses_line_map(text: str) -> dict[tuple[str, str], int]:
    """Map (job_id, uses_val) to the 1-based line number of its `uses:` line."""
    out: dict[tuple[str, str], int] = {}
    current_job: str | None = None
    in_jobs = False
    job_indent: str | None = None
    for i, line in enumerate(text.splitlines(), start=1):
        if _is_root_jobs_key(line):
            in_jobs = True
            job_indent = None
            continue
        if in_jobs:
            if job_indent is None:
                job_indent = _detect_job_indent(line)
            job_id = _parse_job_id(line, job_indent)
            if job_id is not None:
                current_job = job_id
                continue
            elif re.match(r"^[^#\s]", line):
                in_jobs = False
                current_job = None
                job_indent = None
                continue
            if current_job:
                m_uses = USES_LINE_RE.match(line)
                if m_uses:
                    val = m_uses.group("val").strip().strip('"').strip("'")
                    out.setdefault((current_job, val), i)
    return out


def scan_file(path: Path) -> tuple[list[str], list[dict], int, int]:
    """Scan one workflow/template file for first-party reusable pins.

    Returns ``(violations, deprecations, checked, canonical)``:
      - ``violations``  — hard-failure strings (SHA/off-channel/unsanctioned/…).
      - ``deprecations`` — legacy bare-tier pins, each a dict with keys
        ``path``, ``job``, ``line``, ``ref``, ``suggestion`` (#687 AC #8/#9).
      - ``checked``     — count of first-party reusable refs inspected.
      - ``canonical``   — count of those that are canonical (major-scoped/semver/@vN).
    """
    text = path.read_text(encoding="utf-8")
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as err:
        return [f"{path}: not valid YAML: {err}"], [], 0, 0
    if not isinstance(doc, dict):
        return [], [], 0, 0
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        return [], [], 0, 0

    comments = raw_comment_map(text)
    lines = uses_line_map(text)
    violations: list[str] = []
    deprecations: list[dict] = []
    checked = 0
    canonical = 0

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
        status, detail = classify_ref(ref)
        # Reject refs whose name prefix doesn't match the reusable filename's channel name.
        # A ref like 'pr-review/v1-stable' on 'dev-lead-reusable.yml' would otherwise
        # pass as canonical even though it points to the wrong reusable's channel.
        if status != "violation" and "/" in ref:
            ref_name = ref.split("/")[0]
            expected_name = _expected_channel_name(job_path)
            if expected_name and ref_name != expected_name:
                filename = job_path.rsplit("/", 1)[-1]
                status = "violation"
                detail = (
                    f"ref name mismatch: '@{ref}' does not belong to '{filename}' "
                    f"(expected prefix '{expected_name}/')"
                )
        if status == "violation":
            violations.append(f"{path}: job '{job_id}': {detail}")
        elif status == "deprecated":
            deprecations.append(
                {
                    "path": str(path),
                    "job": job_id,
                    "line": lines.get((job_id, uses), 0),
                    "ref": ref,
                    "suggestion": detail,
                }
            )
        else:
            canonical += 1
            # Off-channel comments are only checked on canonical pins; a deprecated
            # pin already fails the run on its own (#1493 AC #12), so there is no
            # separate off-channel escalation to add for it.
            comment = comments.get((job_id, uses))
            if off_channel_comment(comment):
                violations.append(
                    f"{path}: job '{job_id}': off-channel `{comment.strip()}` annotation "
                    "on a first-party reusable pin"
                )
    return violations, deprecations, checked, canonical


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


def emit_inventory(deprecations: list[dict], checked: int, canonical: int) -> None:
    """Print the legacy→major-scoped inventory + counts, and append them to the
    GitHub run summary when `$GITHUB_STEP_SUMMARY` is set (#687 AC #9)."""
    legacy = len(deprecations)
    print(
        f"\nPin inventory (#1184 migration): {canonical} canonical (major-scoped) / "
        f"{legacy} legacy (DEPRECATED) of {checked} first-party pin(s) checked."
    )
    for d in deprecations:
        print(
            f"  DEPRECATED: {d['path']}:{d['line']} job '{d['job']}' pins "
            f"@{d['ref']} — repin to @{d['suggestion']} (bare <name>/<tier> is the "
            "pre-#1184 legacy form)."
        )

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return
    rows = [
        "### Reusable-pin migration inventory (#1184)",
        "",
        f"- **canonical (major-scoped)**: {canonical}",
        f"- **legacy (DEPRECATED)**: {legacy}",
        f"- **checked**: {checked}",
        "",
    ]
    if deprecations:
        rows.append("| file | line | job | current (legacy) | should become |")
        rows.append("|---|---|---|---|---|")
        for d in deprecations:
            rows.append(
                f"| `{d['path']}` | {d['line']} | `{d['job']}` | "
                f"`@{d['ref']}` | `@{d['suggestion']}` |"
            )
        rows.append("")
        rows.append(
            "> The #1184 migration is complete: legacy bare-tier pins are now a "
            "**failure** (#1493 AC #12) — repin each to its major-scoped channel."
        )
    else:
        rows.append("No legacy bare-tier pins remain. ✅")
    rows.append("")
    with open(summary_path, "a", encoding="utf-8") as fh:
        fh.write("\n".join(rows))


def main(argv: list[str]) -> int:
    files, explicit = collect_files(argv[1:])
    violations: list[str] = []
    deprecations: list[dict] = []
    checked = 0
    canonical = 0
    for f in files:
        if not f.is_file():
            print(f"FAIL: {f} not found")
            return 1
        file_violations, file_deprecations, file_checked, file_canonical = scan_file(f)
        violations.extend(file_violations)
        deprecations.extend(file_deprecations)
        checked += file_checked
        canonical += file_canonical

    # Inventory + counts are always emitted (green or not) so the run summary is a
    # complete, machine-readable census of the migration (#687 AC #9).
    emit_inventory(deprecations, checked, canonical)

    if violations:
        print(f"\nFAIL: {len(violations)} first-party reusable pin compliance violation(s):")
        for v in violations:
            print(f"  {v}")
        print(
            "\n  Fix: pin first-party reusables to a canonical channel/version tag "
            "(<name>/v<MAJOR>-<tier>, <name>/vX.Y.Z, or @vN).\n"
            "  See AGENTS.md 'Release channel tags & the mutable-ref exception'."
        )
        return 1

    if not explicit and checked == 0:
        print(
            "FAIL: scanned the default roots but found no first-party reusable refs — "
            "the scanner globs are likely broken; refusing to pass vacuously."
        )
        return 1

    if deprecations:
        # Enforcement flip (#687/#1493 AC #12): the #1184 legacy→major-scoped
        # migration is complete, so a bare `<name>/<tier>` pin is now a hard
        # FAILURE — it can never merge again. The pin is still inventoried above
        # (AC #9) so the failure is fully diagnosable, then the run fails.
        print(
            f"\nFAIL: {len(deprecations)} legacy bare-tier pin(s) remain — the #1184 "
            "migration is complete and DEPRECATED pins are now rejected (#1493 AC #12). "
            "See the DEPRECATED lines in the inventory above for each offending pin."
        )
        print(
            "\n  Fix: repin the first-party reusable to its major-scoped channel "
            "(<name>/v<MAJOR>-<tier>).\n"
            "  See AGENTS.md 'Release channel tags & the mutable-ref exception'."
        )
        return 1

    print(
        f"\nPASS: {checked} first-party reusable pin(s) across {len(files)} "
        "file(s) compliant (all canonical)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
