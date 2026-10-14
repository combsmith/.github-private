#!/usr/bin/env python3
"""Validate agentic persona manifests.

Every `personas/<id>/persona.yml` is validated against the canonical persona
schema (owned by petry-projects/.github) PLUS the cross-invariants the JSON
schema cannot express on its own:

  * `id` == the persona directory name == `canary.agent`
  * `address.handle`'s team slug == `id` (so a mention routes by prefix-strip).
    This makes handle uniqueness a THEOREM rather than a check: the schema pins
    the org (^petry-projects/...), slug == id, id == the persona directory name,
    and directory names are unique — so two personas cannot claim the same
    handle. There is deliberately no cross-file uniqueness check.

    Scope of that claim: it covers `address.handle`, which is the only thing the
    mention router resolves. `address.aliases` shared the handle namespace and
    was NOT covered by it — which is why a uniqueness check existed while
    aliases did. Aliases are being removed from the addressing contract
    (petry-projects/.github#755 finding 1); this repo has already dropped every
    use, and the companion PR drops the field from the schema. Until that lands
    the schema still PERMITS an alias, so re-adding one here would reopen the
    namespace this theorem does not cover. Do not.
  * every `definition.layers[].path` exists on disk
  * every `skills[].path` exists on disk, and when it points at a `<name>/SKILL.md`
    the directory name equals the entry `name` (name<->path agreement)
  * a `framework-agent` layer's `framework.vendor_pin` actually appears in the
    referenced `frameworks/<name>/VENDOR.md` (pin ↔ vendored version agree)
  * every surface a manifest declares `enabled: true` is actually served by a
    deployed workflow — derived, not hand-maintained: the serving signal comes
    from `personas/<id>/interaction.yml`'s `interaction.triggers.events[]` (the
    union of the deployed `on:` blocks, #1404/#1418). A declared-but-unserved
    surface fails closed (the #1279 handle-collision precedent): an advertised
    interaction contract nothing honors is the same category of silent wrongness.
    A persona with NO `interaction.yml` is SKIPPED with a `::notice::` (not failed)
    — interaction.yml is the derivation source, so its absence is a different
    defect (a missing contract file) with its own issue, not an over-declared
    surface. This is the AC #2/#5 invariant of petry-projects/.github-private#1647.
  * each eval set (`evals.path`, or every entry of `evals.paths`) carries both
    `dev/cases.jsonl` and `holdout/cases.jsonl`; and once the persona has reached
    its `evals.required_before` ring, each held-out set has >= `min_cases`
    (the enforceable half of principle 5 — a draft is exempt)
  * registration matches the manifest's own declaration (ADR-0006): a persona
    WITH a `canary` block ships its own reusable, so past `draft` it must have a
    matching `agents.<id>` entry in `canary-rings.json` (status never outruns
    registration); a persona WITHOUT one rides the shared persona runtime, is
    never ring-registered, and must NOT appear in the registry at all

Schema resolution order (#1707):
  1. --schema PATH                     (explicit local file; used by tests)
  2. $PERSONA_SCHEMA_FILE              (local file)
  3. $PERSONA_SCHEMA_REF               (explicit ref; exactly this, no widening)
  4. the standards channel             (STANDARDS_CHANNEL, default standards/v1-stable)
     PLUS its N-1 immutable release    (a manifest valid under EITHER passes)

The schema lives in the org standards repo, not here — this validator reads it
the same way any consumer repo reads a published standard. When run against the
canary registry check, the registry is read the same way.

Why the channel, not `main`: the standard is versioned but the fetch used to be
pinned to the org repo's DEFAULT BRANCH, so a merge there changed the pass/fail
verdict of every open PR here with no coordinating change on this side (the
2026-09-07 outage: an org-repo schema tightening red-lined the whole fleet 21
seconds after it merged). Pinning to a moving channel tag — the same model
scripts/seed-repo-template.sh already uses (STANDARDS_CHANNEL, #1448) — decouples
this repo's verdict from unpublished org-repo commits. Accepting N-1 for the
schema means promoting a standards version does not fail every consumer at once
mid-propagation. A pinned-channel MISS is a LOUD, named fallback (a ::warning::
naming the ref wanted and the ref used) — never a silent widening back to `main`,
which is exactly the coupling this removes.

Usage:
  validate-personas.py [personas_root] [--schema PATH] [--registry PATH]

Exit 0 on success; non-zero with a diagnostic on the first failure class found.
"""
import argparse
import json
import os
import re
import sys
import urllib.request
from pathlib import Path
from typing import NoReturn

SCHEMA_REPO = "petry-projects/.github"
SCHEMA_PATH_IN_REPO = "standards/personas/persona.schema.json"
REGISTRY_PATH_IN_REPO = "standards/canary-rings.json"
MANIFEST_NAME = "persona.yml"

# The standards are versioned; the fetch must be too (#1707). Consumers pin to a
# moving channel tag, not the org repo's default branch — the same channel model
# scripts/seed-repo-template.sh already uses (STANDARDS_CHANNEL, #1448).
STANDARDS_CHANNEL = os.environ.get("PERSONA_SCHEMA_CHANNEL", "standards/v1-stable")

# A pinned-channel miss falls back here — but LOUDLY (a named ::warning::), never
# silently. Silent widening to the default branch is exactly the coupling #1707
# removes, so the fallback exists only to keep the validator alive during an org-repo
# tag outage, and it announces itself so a run is never mysteriously back on `main`.
FALLBACK_REF = "main"

# An immutable standards release tag: standards/vMAJOR.MINOR.PATCH (the channel tag
# standards/v<MAJOR>-stable is deliberately NOT matched — it is a moving pointer, not
# a release the N-1 window steps back to).
_SEMVER_TAG = re.compile(r"^standards/v(\d+)\.(\d+)\.(\d+)$")

# The MAJOR a moving channel tag pins: standards/v1-stable → 1 (also -next, -ring<N>).
_CHANNEL_MAJOR = re.compile(r"/v(\d+)-")


def fail(msg: str) -> NoReturn:
    print(f"::error::persona manifest invalid: {msg}", file=sys.stderr)
    sys.exit(1)


def _raw_url(ref: str, path: str) -> str:
    return f"https://raw.githubusercontent.com/{SCHEMA_REPO}/{ref}/{path}"


# ── Pure resolution logic (no I/O — ADR-0004) ─────────────────────────────────

def _semver(tag: str) -> tuple[int, int, int] | None:
    m = _SEMVER_TAG.match(tag)
    return (int(m[1]), int(m[2]), int(m[3])) if m else None


def current_and_previous(version_tags: list[str]) -> tuple[str | None, str | None]:
    """(current, previous) standards immutable-release tags, highest semver first.

    `previous` — the N-1 target — is None when fewer than two releases exist.
    Ordering is numeric (v1.10.0 > v1.2.0), not lexical. Pure: the caller supplies
    the tag list (an I/O concern), so this stays deterministic and unit-testable."""
    ranked = sorted(
        ((v, t) for t in version_tags if (v := _semver(t)) is not None),
        reverse=True,
    )
    current = ranked[0][1] if ranked else None
    previous = ranked[1][1] if len(ranked) > 1 else None
    return current, previous


def _channel_major(channel: str) -> int | None:
    """The MAJOR a moving channel tag pins (standards/v1-stable → 1), or None when
    the channel is not the v<MAJOR>-<tier> shape. Pure."""
    m = _CHANNEL_MAJOR.search(channel)
    return int(m[1]) if m else None


def _rank_channel_releases(version_tags: list[str], channel: str) -> list[str]:
    """Immutable release tags in `channel`'s major LINE, highest semver first
    (standards/v1-stable → v1.x only; numeric, so v1.10.0 > v1.2.0). Filtering to the
    channel's major keeps the N-1 window from pairing the channel with an unrelated
    release line — a v2.x release while the validator is pinned to v1-stable. A channel
    with no v<MAJOR>- shape imposes no filter. Pure: the caller supplies the tag list."""
    major = _channel_major(channel)
    ranked = sorted(
        ((v, t) for t in version_tags
         if (v := _semver(t)) is not None and (major is None or v[0] == major)),
        reverse=True,
    )
    return [t for _, t in ranked]


def previous_in_channel(version_tags: list[str], channel: str) -> str | None:
    """N-1 of the NEWEST release in `channel`'s major line — the degrade path used when
    the channel's current target release cannot be resolved (see
    previous_relative_to_target for the target-aware selection the live discovery uses).
    Pure: the caller supplies the tag list (an I/O concern)."""
    ranked = _rank_channel_releases(version_tags, channel)
    return ranked[1] if len(ranked) > 1 else None


def previous_relative_to_target(version_tags: list[str], channel: str,
                                target: str | None) -> str | None:
    """The greatest immutable release STRICTLY BELOW the channel's current `target`
    release, within the channel's major line — the true N-1 (#1707 review).

    Cutting a release does not move the channel (the runbook: cutting is not gated), so
    the newest release tag can be AHEAD of what the channel serves: with v1.2.0 cut but
    the channel still at v1.1.0, plain newest-below returns v1.1.0 — the channel's OWN
    target — as 'N-1' and never steps back to v1.0.0. Taking N-1 relative to the resolved
    target fixes that. A `target` that is None (unresolvable) or absent from the release
    set degrades to previous_in_channel (newest-below). Pure: the caller resolves the
    target (an I/O concern)."""
    if target is None:
        return previous_in_channel(version_tags, channel)
    ranked = _rank_channel_releases(version_tags, channel)
    if target not in ranked:
        return previous_in_channel(version_tags, channel)
    i = ranked.index(target)
    return ranked[i + 1] if i + 1 < len(ranked) else None


def schema_ref_plan(env_ref: str | None, channel: str,
                    previous: str | None) -> list[tuple[str, str]]:
    """Ordered [(ref, label)] the schema is ACCEPTED against, highest precedence
    first. Pure — the caller does the fetching.

      * env_ref (PERSONA_SCHEMA_REF) set → exactly that ref, nothing else. An
        explicit pin is explicit: no channel, no N-1 widening.
      * otherwise                        → the channel (N), then the N-1 immutable
        release if one exists, so promoting a standards version does not fail every
        consumer mid-propagation (#1707 AC #3, per #1448's N-1 clause)."""
    if env_ref:
        return [(env_ref, "PERSONA_SCHEMA_REF")]
    plan = [(channel, "channel")]
    if previous:
        plan.append((previous, "N-1"))
    return plan


def first_schema_error(manifest: dict, validators: list[tuple[str, object]]):
    """(label, error) for the FIRST accepted-schema version the manifest FAILS — or
    None if it satisfies ANY of them (the N-1 tolerance window, #1707 AC #3). The
    reported failure is against the FIRST (current) version, the one to conform to.
    Pure over the supplied validators."""
    first = None
    for label, validator in validators:
        error = next(validator.iter_errors(manifest), None)
        if error is None:
            return None
        if first is None:
            first = (label, error)
    return first


def fallback_warning(what: str, wanted: str, used: str) -> str:
    """The loud, named condition emitted when a pinned ref is unreachable (#1707
    AC #4). Names the ref it WANTED and the ref it USED so a run is never silently
    widened back to the default branch — the exact coupling #1707 removes."""
    return (f"::warning::{what} unreachable at pinned ref '{wanted}' — falling back "
            f"to '{used}'. This widens to {SCHEMA_REPO}'s default branch, the #1707 "
            f"coupling; fix the pin, do not rely on this fallback.")


# ── I/O ───────────────────────────────────────────────────────────────────────

def _read_json_file(path: str, what: str) -> dict:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"could not read/parse {what} {path}: {exc}")


def _fetch_json_at(path: str, ref: str) -> dict | None:
    """Fetch a JSON file from the standards repo at a specific ref, or None if it is
    unreachable/unparseable — the caller decides whether to fall back (so the
    fallback stays loud and centralized rather than hidden in here)."""
    url = _raw_url(ref, path)
    try:
        with urllib.request.urlopen(url, timeout=20) as resp:  # noqa: S310 (fixed host)
            return json.loads(resp.read().decode("utf-8"))
    except Exception:  # noqa: BLE001
        return None


def _ref_commit(ref: str) -> str | None:
    """The commit SHA `ref` resolves to on the standards repo, dereferencing an
    annotated tag (release tags are annotated; channel tags are lightweight pointers).
    None if unreachable — best-effort, used only to resolve the channel's current target
    so N-1 is taken relative to it (#1707 review)."""
    url = f"https://api.github.com/repos/{SCHEMA_REPO}/commits/{ref}"
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
        token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        with urllib.request.urlopen(req, timeout=20) as resp:  # noqa: S310 (fixed host)
            return json.loads(resp.read().decode("utf-8")).get("sha")
    except Exception:  # noqa: BLE001
        return None


def _resolve_channel_target(channel: str, ranked_releases: list[str]) -> str | None:
    """Which ranked release the channel currently points at, matched by COMMIT identity
    (a channel is a lightweight pointer at some release's commit). Walks releases
    newest-first and returns the first whose commit equals the channel's — usually the
    newest, so the common case costs two API calls. None if the channel or no release
    resolves, so the caller degrades to newest-below rather than erroring (N-1 is a
    tolerance, not a requirement, #1707)."""
    channel_commit = _ref_commit(channel)
    if channel_commit is None:
        return None
    for tag in ranked_releases:
        if _ref_commit(tag) == channel_commit:
            return tag
    return None


def _discover_previous_version(channel: str) -> str | None:
    """The N-1 immutable release tag, or None if it can't be determined. Best-effort
    network read: N-1 is a tolerance widening, not a requirement, so any failure degrades
    to channel-only rather than erroring.

    N-1 is taken relative to the release the channel CURRENTLY serves — not merely the
    newest release tag. Cutting a release does not move the channel, so a release cut but
    not yet promoted (v1.2.0 while the channel is still at v1.1.0) must not shadow the
    true N-1 (v1.0.0) — see previous_relative_to_target (#1707 review)."""
    try:
        url = (f"https://api.github.com/repos/{SCHEMA_REPO}"
               f"/git/matching-refs/tags/standards/v")
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
        token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        with urllib.request.urlopen(req, timeout=20) as resp:  # noqa: S310 (fixed host)
            refs = json.loads(resp.read().decode("utf-8"))
        tags = [r["ref"].split("refs/tags/", 1)[1] for r in refs
                if isinstance(r, dict) and isinstance(r.get("ref"), str)
                and "refs/tags/" in r["ref"]]
    except Exception:  # noqa: BLE001
        return None
    # Rank the channel's own major line, resolve the release it currently targets, then
    # take the greatest release below that target. An unresolvable target degrades to
    # newest-below (previous_in_channel).
    ranked = _rank_channel_releases(tags, channel)
    target = _resolve_channel_target(channel, ranked)
    return previous_relative_to_target(tags, channel, target)


def load_schemas(explicit: str | None) -> list[tuple[str, dict]]:
    """Ordered [(label, schema)] to validate each manifest against; a manifest is
    accepted if it satisfies ANY of them. Normally one entry; two during a standards
    promotion window (current + N-1, #1707 AC #3). See the module docstring for the
    full resolution order."""
    candidate = explicit or os.environ.get("PERSONA_SCHEMA_FILE")
    if candidate:
        return [("local", _read_json_file(candidate, "schema"))]

    env_ref = os.environ.get("PERSONA_SCHEMA_REF")
    previous = None if env_ref else _discover_previous_version(STANDARDS_CHANNEL)
    plan = schema_ref_plan(env_ref, STANDARDS_CHANNEL, previous)

    schemas: list[tuple[str, dict]] = []
    channel_ok = False
    for ref, label in plan:
        doc = _fetch_json_at(SCHEMA_PATH_IN_REPO, ref)
        if doc is not None:
            schemas.append((f"{label} ({ref})", doc))
            if label == "channel":
                channel_ok = True
    if schemas:
        # A pinned-channel miss must be LOUD even when N-1 keeps the run alive: if the
        # channel was unreachable but an N-1 release still validated, name the failed
        # channel and the N-1 ref we fell through to (#1707 AC #4). This is NOT the
        # widen-to-main fallback (N-1 is a legitimate promotion-window tolerance), so it
        # is a distinct warning. An explicit env_ref plan has no channel entry — skip it.
        if not env_ref and not channel_ok:
            print(f"::warning::persona schema channel unreachable at pinned ref "
                  f"'{plan[0][0]}' — falling through to {schemas[0][0]} only. N-1 is a "
                  f"promotion-window tolerance, not a substitute for the channel; "
                  f"restore the channel pin.", file=sys.stderr)
        return schemas

    # An explicit PERSONA_SCHEMA_REF is an EXACT pin (docstring resolution order #3):
    # if it is unreachable, FAIL — never widen to the default branch, which would
    # validate against a different schema than the one explicitly requested. The loud
    # fallback below is only for the channel default, to survive a channel-tag outage.
    if env_ref:
        fail(f"PERSONA_SCHEMA_REF='{env_ref}' is unreachable: could not fetch "
             f"{SCHEMA_PATH_IN_REPO} from {SCHEMA_REPO} at that ref. An explicit pin "
             f"is exact — refusing to widen to '{FALLBACK_REF}'. Fix the ref, or pass "
             f"--schema / $PERSONA_SCHEMA_FILE.")

    # Loud fallback (AC #4): the pinned channel is unreachable — announce, never widen silently.
    wanted = plan[0][0]
    print(fallback_warning("persona schema", wanted, FALLBACK_REF), file=sys.stderr)
    doc = _fetch_json_at(SCHEMA_PATH_IN_REPO, FALLBACK_REF)
    if doc is None:
        fail(f"could not fetch persona schema from {SCHEMA_REPO} at '{wanted}' or "
             f"fallback '{FALLBACK_REF}'. Ensure {SCHEMA_REPO} carries "
             f"{SCHEMA_PATH_IN_REPO}, or pass --schema / $PERSONA_SCHEMA_FILE.")
    return [(f"fallback ({FALLBACK_REF})", doc)]


def load_registry(explicit: str | None) -> dict:
    """The canary-rings registry, read the way any consumer reads a published
    standard. UNLIKE the schema it is pinned to the channel ONLY, not N-1: a ring
    registry is volatile (it moves as agents promote ring-to-ring) and the
    registration invariants below assert against CURRENT registration, so accepting a
    stale N-1 registry would mask a real 'status outran its registration' defect. Same
    loud fallback as the schema (#1707 AC #4)."""
    candidate = explicit or os.environ.get("PERSONA_REGISTRY_FILE")
    if candidate:
        return _read_json_file(candidate, "registry")
    env_ref = os.environ.get("PERSONA_SCHEMA_REF")
    ref = env_ref or STANDARDS_CHANNEL
    doc = _fetch_json_at(REGISTRY_PATH_IN_REPO, ref)
    if doc is not None:
        return doc
    # An explicit PERSONA_SCHEMA_REF is an EXACT pin (mirroring load_schemas): if its
    # registry is unreachable, FAIL — never widen to the default branch, which would
    # validate a schema from the explicit ref against registry data from a DIFFERENT
    # tree. The loud fallback below is only for the channel default, to survive a
    # channel-tag outage.
    if env_ref:
        fail(f"PERSONA_SCHEMA_REF='{env_ref}' registry is unreachable: could not fetch "
             f"{REGISTRY_PATH_IN_REPO} from {SCHEMA_REPO} at that ref. An explicit pin "
             f"is exact — refusing to widen to '{FALLBACK_REF}'. Fix the ref, or pass "
             f"--registry / $PERSONA_REGISTRY_FILE.")
    print(fallback_warning("canary registry", ref, FALLBACK_REF), file=sys.stderr)
    doc = _fetch_json_at(REGISTRY_PATH_IN_REPO, FALLBACK_REF)
    if doc is None:
        fail(f"could not fetch canary registry from {SCHEMA_REPO} at '{ref}' or "
             f"fallback '{FALLBACK_REF}'. Ensure {SCHEMA_REPO} carries "
             f"{REGISTRY_PATH_IN_REPO}, or pass --registry / $PERSONA_REGISTRY_FILE.")
    return doc


def registry_has_agent(registry: dict, persona_id: str) -> bool:
    agents = registry.get("agents", {})
    return isinstance(agents, dict) and persona_id in agents


def discover_manifests(root: Path) -> list[Path]:
    return sorted(p / MANIFEST_NAME for p in root.iterdir()
                  if p.is_dir() and (p / MANIFEST_NAME).is_file())


def handle_slug(manifest_path: Path, field: str, value: object) -> str:
    """Validate an 'org/team-slug' handle and return its slug.

    The canonical schema's pattern already guarantees this shape, so against the
    real schema this never fires. It earns its keep because the validator accepts
    `--schema`: a test double, or a stale local copy, can let a malformed handle
    through — and this module's contract is a diagnostic on failure, not a
    traceback (see the module docstring).
    """
    if not isinstance(value, str) or "/" not in value:
        fail(f"{manifest_path}: {field} must be an 'org/team-slug' string "
             f"(e.g. 'petry-projects/qa-lead'), got {value!r}")
    return value.split("/", 1)[1]


RING_ORDER = {"draft": 0, "canary": 1, "ring0": 2, "ring1": 3, "stable": 4, "retired": 5}


def _eval_set_dirs(evals: dict) -> list[str]:
    """The eval-set dir(s) a manifest declares — `path` (one) or `paths` (many).

    The schema guarantees exactly one of the two is present; this mirrors that so
    the validator reads both shapes. A stale --schema that allowed neither yields
    an empty list (no sets to check), which is safe.
    """
    if "path" in evals:
        return [evals["path"]]
    return list(evals.get("paths", []))


def check_evals(manifest: dict, manifest_path: Path, repo_root: Path) -> None:
    """Every eval set has dev/ + holdout/ splits; and once the persona has reached
    its `required_before` ring, each held-out set carries at least `min_cases`.

    This is the enforceable half of principle 5 ("no persona reaches stable
    without an eval gate"): the SCORED gate (running the cases against a judge)
    needs a harness and is tracked separately, but "you cannot promote past
    required_before on placeholder evals" is a hermetic line-count and belongs
    here. A draft persona is exempt — draft is exactly when seed cases are still
    placeholders.
    """
    evals = manifest.get("evals")
    if evals is None:
        return
    min_cases = evals.get("min_cases", 1)
    required_before = evals.get("required_before", "stable")
    status = manifest.get("status", "draft")
    # Gate the count once the persona has reached (or passed) the ring by which
    # the evals were promised. Splits must always exist; the count only bites at
    # promotion so seed sets can be filled in while draft.
    enforce_count = RING_ORDER.get(status, 0) >= RING_ORDER.get(required_before, 4)

    for rel in _eval_set_dirs(evals):
        try:
            eval_dir = (repo_root / rel).resolve()
            eval_dir.relative_to(repo_root.resolve())
        except (ValueError, OSError):
            fail(f"{manifest_path}: eval set '{rel}' must be a valid path inside the repository root")
        for split in ("dev", "holdout"):
            cases = eval_dir / split / "cases.jsonl"
            if not cases.is_file():
                fail(f"{manifest_path}: eval set '{rel}' is missing its {split} split "
                     f"(expected {cases})")
        if enforce_count:
            holdout = eval_dir / "holdout" / "cases.jsonl"
            with holdout.open(encoding="utf-8") as f:
                n = sum(1 for line in f if line.strip())
            if n < min_cases:
                fail(f"{manifest_path}: status '{status}' has reached required_before "
                     f"'{required_before}', but eval set '{rel}' holds only {n} held-out "
                     f"case(s) < min_cases {min_cases} (principle 5: no promotion on "
                     f"placeholder evals)")


# Credentials that pre-date the GH_PAT_<ACCOUNT> naming convention and are kept
# as-is (they are already account-named, just in the legacy suffix order). New
# personas MUST use the GH_PAT_<ACCOUNT>[_<QUALIFIER>] form.
GRANDFATHERED_CREDENTIALS = frozenset({
    "DON_PETRY_BOT_GH_PAT",
    "DON_PETRY_BOT_GH_PAT_CLASSIC",
})


def check_identity(manifest: dict, manifest_path: Path) -> None:
    """Every persona MUST declare the account it acts as. The schema validates the
    SHAPE of runtime.identity when present; this makes it MANDATORY and enforces
    the credential naming convention — so no persona can silently fall back to a
    shared machine user (the dev-lead->donpetry-bot regression, .github-private#1316)."""
    runtime = manifest.get("runtime")
    if not isinstance(runtime, dict) or "identity" not in runtime:
        fail(f"{manifest_path}: missing runtime.identity — every persona must declare the "
             f"account it acts as (account + credential). See persona-standards.md §5.1.")
    identity = runtime["identity"]
    if not isinstance(identity, dict) or "credential" not in identity or "account" not in identity:
        fail(f"{manifest_path}: runtime.identity must be a mapping containing 'account' and "
             f"'credential'. See persona-standards.md §5.1.")
    credential = identity["credential"]
    account = identity["account"]
    if credential not in GRANDFATHERED_CREDENTIALS:
        upper_account = account.upper().replace("-", "_")
        prefix = f"GH_PAT_{upper_account}"
        if credential != prefix and not credential.startswith(prefix + "_"):
            fail(f"{manifest_path}: runtime.identity.credential '{credential}' must follow the "
                 f"GH_PAT_<ACCOUNT>[_<QUALIFIER>] convention for account '{account}' "
                 f"(expected '{prefix}[_<QUALIFIER>]'). See persona-standards.md §5.1.")


def check_skills(manifest: dict, manifest_path: Path, repo_root: Path) -> None:
    """`skills[]` is the persona's declarative skill inventory. Validate that each
    entry's `path` exists on disk (mirroring the definition.layers[].path check),
    and that name and path agree: when a path points at a `<name>/SKILL.md`, the
    directory name must equal the entry `name`. That name<->directory rule is
    general (it holds for both `src/agents/<n>/SKILL.md` and
    `src/workflows/<...>/<n>/SKILL.md`) and hardcodes no framework layout, so a
    mislabelled entry — a name that points at a different skill's SKILL.md — fails.

    A `path` must be repo-relative and resolve inside `repo_root`: an absolute or
    `..`-escaping path would let an unrelated filesystem object masquerade as a
    declared skill, so it is rejected before the existence check.

    Filesystem existence only, no network: this validator is hermetic on purpose.
    The schema guarantees the shape of each entry; the defensive shape check keeps
    a stale/test-double --schema producing a diagnostic rather than a traceback
    (the module's contract — see the docstring)."""
    skills = manifest.get("skills")
    if skills is None:
        return
    if not isinstance(skills, list):
        fail(f"{manifest_path}: 'skills' must be a list, got {skills!r}")
    for i, skill in enumerate(skills):
        if (not isinstance(skill, dict)
                or not isinstance(skill.get("name"), str)
                or not isinstance(skill.get("path"), str)):
            fail(f"{manifest_path}: skills[{i}] must be a mapping with string 'name' and "
                 f"'path', got {skill!r}")
        # A skill path is a repo-relative pointer. An absolute or `..`-escaping
        # path would let an unrelated filesystem object masquerade as a declared
        # skill, so require it to resolve inside repo_root (mirrors the eval-set
        # containment check above).
        try:
            spath = (repo_root / skill["path"]).resolve()
            spath.relative_to(repo_root.resolve())
        except (ValueError, OSError):
            fail(f"{manifest_path}: skills[{i}].path '{skill['path']}' must be a "
                 f"repo-relative path inside the repository root")
        if not spath.exists():
            fail(f"{manifest_path}: skills[{i}].path '{skill['path']}' does not exist")
        p = Path(skill["path"])
        if p.name == "SKILL.md" and p.parent.name != skill["name"]:
            fail(f"{manifest_path}: skills[{i}].name '{skill['name']}' does not match its "
                 f"skill directory '{p.parent.name}' (path '{skill['path']}')")


# Surface -> the set of GitHub webhook event names that, when present in a
# persona's interaction.yml triggers.events[], serve that surface. A surface is
# matched on the BASE event name (the part before any ':qualifier'). The event
# names here are DISTINCT GitHub webhooks — `check_run` and `check_suite` are
# separate events, so a `check_suite`-only workflow does NOT serve a `check_run`
# surface and is deliberately not listed under it. The `mention` surface is
# special: a human @mention is delivered through the comment webhooks by the
# shared persona-mention router, OR bridged to a persona's own reusable via the
# router's `repository_dispatch:<role>-mention` dispatch — either form serves it
# (the latter is how pr-review's mention surface is wired). Only that
# mention-bridge dispatch counts; an unrelated `repository_dispatch:<other>` (e.g.
# dev-lead's ci-failure/issue-retry bridges) does not serve the mention surface.
# This mapping is the one piece of surface-routing knowledge that is not itself in
# a manifest; it encodes the fixed GitHub-event semantics, not any per-persona
# decision.
_COMMENT_EVENTS = frozenset({"issue_comment", "pull_request_review_comment",
                             "discussion_comment"})
SURFACE_SERVING_EVENTS: dict[str, frozenset[str]] = {
    "pull_request": frozenset({"pull_request"}),
    "pull_request_review": frozenset({"pull_request_review"}),
    "issues": frozenset({"issues"}),
    "check_run": frozenset({"check_run"}),
    "discussion": frozenset({"discussion"}),
    "mention": _COMMENT_EVENTS,
    "schedule": frozenset({"schedule"}),
}

# The router bridges a mention to a persona's own reusable via a
# repository_dispatch whose type is '<role>-mention' (persona-mention,
# pr-review-mention, …). Only such a qualified dispatch serves the mention surface.
_MENTION_BRIDGE_SUFFIX = "-mention"


def _interaction_events(interaction_path: Path) -> set[str]:
    """The event names an interaction.yml records under
    interaction.triggers.events[] (full names, any ':qualifier' preserved)."""
    import yaml
    try:
        contract = yaml.safe_load(interaction_path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        fail(f"{interaction_path}: could not read/parse interaction contract: {exc}")
    if not isinstance(contract, dict):
        fail(f"{interaction_path}: interaction contract must be a mapping")
    # interaction.yml is not schema-validated before this read, so check each
    # nested container is a mapping before descending — the module's contract is a
    # clean diagnostic on a malformed contract, not an AttributeError traceback.
    interaction = contract.get("interaction") or {}
    if not isinstance(interaction, dict):
        fail(f"{interaction_path}: 'interaction' must be a mapping")
    triggers = interaction.get("triggers") or {}
    if not isinstance(triggers, dict):
        fail(f"{interaction_path}: 'interaction.triggers' must be a mapping")
    events = triggers.get("events") or []
    if not isinstance(events, list):
        fail(f"{interaction_path}: interaction.triggers.events must be a list")
    return {str(e) for e in events}


def _surface_served(surface: str, events: set[str]) -> bool:
    """Derive whether `surface` is served by the recorded interaction events."""
    base_events = {e.split(":", 1)[0] for e in events}
    serving = SURFACE_SERVING_EVENTS.get(surface, frozenset())
    if serving & base_events:
        return True
    # A mention may be bridged to a persona's own reusable via the router's
    # repository_dispatch:<role>-mention. Only that mention-bridge dispatch serves
    # it — an unrelated repository_dispatch:<other> does not.
    if surface == "mention" and any(
            e.startswith("repository_dispatch:")
            and e.split(":", 1)[1].endswith(_MENTION_BRIDGE_SUFFIX)
            for e in events):
        return True
    return False


def check_surface_liveness(manifest: dict, manifest_path: Path) -> None:
    """Every `enabled: true` surface must be served by a deployed workflow, as
    recorded in the persona's interaction.yml triggers.events[] (derived, not
    hand-maintained). Fails closed on an enabled-but-unserved surface. A persona
    with no interaction.yml is skipped with a ::notice:: (see module docstring)."""
    surfaces = (manifest.get("triggers") or {}).get("surfaces") or []
    enabled = [s for s in surfaces
               if isinstance(s, dict) and s.get("enabled") is True and "surface" in s]
    if not enabled:
        return
    pid = manifest.get("id", manifest_path.parent.name)
    interaction_path = manifest_path.parent / "interaction.yml"
    if not interaction_path.is_file():
        print(f"::notice::persona '{pid}': no interaction.yml — skipping surface-liveness "
              f"check (the derivation source is absent; a missing contract file is a "
              f"distinct defect, not an over-declared surface)")
        return
    events = _interaction_events(interaction_path)
    for s in enabled:
        surface = s["surface"]
        if not _surface_served(surface, events):
            fail(f"{manifest_path}: surface '{surface}' is enabled: true but no deployed "
                 f"workflow serves it — {interaction_path.name} records events "
                 f"{sorted(events)}, none of which serve '{surface}'. Either wire a "
                 f"workflow (and record its event in interaction.yml) or set the surface "
                 f"enabled: false with a note (persona-standards §1.1; .github-private#1647).")


def check_invariants(manifest: dict, manifest_path: Path, repo_root: Path,
                     registry_arg: str | None) -> None:
    persona_dir = manifest_path.parent
    pid = manifest["id"]

    if pid != persona_dir.name:
        fail(f"{manifest_path}: id '{pid}' != directory name '{persona_dir.name}'")
    # `canary` is OPTIONAL per ADR-0006: a persona served wholly by the shared
    # persona runtime is NOT ring-registered and omits the block entirely. Only
    # a persona that ships its own reusable carries one — and then it must name
    # itself. Read it defensively; an unconditional read here is what would turn
    # a conforming shared-runtime manifest into a crash.
    canary = manifest.get("canary")
    if canary is not None:
        if not isinstance(canary, dict):
            fail(f"{manifest_path}: canary must be a mapping, got {canary!r}")
        if canary.get("agent") != pid:
            fail(f"{manifest_path}: canary.agent '{canary.get('agent')}' != id '{pid}'")

    # The addressing handle is 'org/team-slug'; the slug carries the role name,
    # so it MUST equal `id` — that is what lets the mention router resolve a
    # persona by stripping the org prefix, with the role written exactly once.
    # (That the team exists / is closed / has notifications off are LIVE
    # properties; they need the network and are checked by CI, not here. This
    # validator is hermetic on purpose — see tests/test_validate_personas.bats.)
    address = manifest.get("address")
    if address is not None:
        if not isinstance(address, dict):
            fail(f"{manifest_path}: address must be a mapping, got {address!r}")
        slug = handle_slug(manifest_path, "address.handle", address.get("handle"))
        if slug != pid:
            fail(f"{manifest_path}: address.handle '{address['handle']}' team slug "
                 f"'{slug}' != id '{pid}' (the handle must address the role by its id)")

    for i, layer in enumerate(manifest["definition"]["layers"]):
        lpath = repo_root / layer["path"]
        if not lpath.exists():
            fail(f"{manifest_path}: definition.layers[{i}].path '{layer['path']}' does not exist")
        if layer["kind"] == "framework-agent":
            fw = layer["framework"]
            vendor_md = repo_root / "frameworks" / fw["name"] / "VENDOR.md"
            if not vendor_md.is_file():
                fail(f"{manifest_path}: framework '{fw['name']}' has no VENDOR.md at {vendor_md}")
            if fw["vendor_pin"] not in vendor_md.read_text(encoding="utf-8"):
                fail(f"{manifest_path}: vendor_pin '{fw['vendor_pin']}' not found in {vendor_md} "
                     f"(manifest pin and vendored version disagree)")

    check_skills(manifest, manifest_path, repo_root)

    check_surface_liveness(manifest, manifest_path)

    check_identity(manifest, manifest_path)

    check_evals(manifest, manifest_path, repo_root)

    # Registration is CONDITIONAL (ADR-0006), keyed on the manifest's own
    # `canary` block — the declaration of which path the persona is on:
    #   - Ships its own reusable (canary present): it must not outrun its
    #     registration, so once past draft it must be registered.
    #   - Shared-runtime (no canary): it has no per-persona channel tag for a
    #     ring to advance, so it is NEVER registered at ANY status — a registry
    #     entry is always a defect, draft or not (ADR-0006: "a registered
    #     persona ID is a defect, not a promotion").
    # We need the registry to answer either question, so load it unless the
    # persona is a draft that declares a canary block (the only case with no
    # invariant to check here).
    if manifest["status"] != "draft" or canary is None:
        registry = load_registry(registry_arg)
        registered = registry_has_agent(registry, pid)
        if canary is not None and not registered:
            fail(f"{manifest_path}: status '{manifest['status']}' is past draft and the manifest "
                 f"declares a canary block, but no agents.{pid} entry exists in "
                 f"{REGISTRY_PATH_IN_REPO} (register once)")
        if canary is None and registered:
            fail(f"{manifest_path}: no canary block (shared-runtime persona, ADR-0006) but an "
                 f"agents.{pid} entry exists in {REGISTRY_PATH_IN_REPO} — a registered "
                 f"shared-runtime persona is a defect, not a promotion; remove the entry")


def main() -> None:
    ap = argparse.ArgumentParser(description="Validate persona manifests.")
    ap.add_argument("root", nargs="?", default="personas",
                    help="personas root directory (default: personas)")
    ap.add_argument("--schema", help="path to a local persona.schema.json (else fetched)")
    ap.add_argument("--registry", help="path to a local canary-rings.json (else fetched)")
    args = ap.parse_args()

    try:
        import yaml
    except ImportError:
        fail("PyYAML not installed (pip install pyyaml)")
    try:
        import jsonschema
    except ImportError:
        fail("jsonschema not installed (pip install 'jsonschema>=4')")

    root = Path(args.root)
    if not root.is_dir():
        print(f"no personas root at {root} — nothing to validate.")
        return
    repo_root = root.parent

    manifests = discover_manifests(root)
    if not manifests:
        print(f"no persona manifests found under {root} — nothing to validate.")
        return

    validators = []
    for label, schema in load_schemas(args.schema):
        # A fetched schema document may itself be malformed (not a valid JSON Schema).
        # Skip it with a diagnostic and try the next resolved ref rather than letting
        # check_schema's SchemaError escape as a traceback — the module's contract is a
        # diagnostic on failure, and N-1 may still be usable when the channel is not.
        try:
            jsonschema.Draft202012Validator.check_schema(schema)
        except jsonschema.exceptions.SchemaError as exc:
            print(f"::warning::skipping unusable persona schema {label}: {exc.message}",
                  file=sys.stderr)
            continue
        validators.append((label, jsonschema.Draft202012Validator(schema)))
    if not validators:
        fail("no usable persona schema: every resolved schema document failed "
             "JSON-Schema validation. Fix the standards schema, or pass a valid "
             "--schema / $PERSONA_SCHEMA_FILE.")

    for manifest_path in manifests:
        try:
            manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
        except (OSError, yaml.YAMLError) as exc:
            fail(f"could not read/parse {manifest_path}: {exc}")
        # Accept the manifest if it satisfies ANY accepted schema version (current
        # or N-1) — the propagation-tolerance window (#1707 AC #3).
        failure = first_schema_error(manifest, validators)
        if failure is not None:
            _, error = failure
            loc = "/".join(str(p) for p in error.absolute_path) or "<root>"
            fail(f"{manifest_path}: schema violation at {loc}: {error.message}")
        check_invariants(manifest, manifest_path, repo_root, args.registry)

    print(f"OK: {len(manifests)} persona manifest(s) valid, invariants hold.")


if __name__ == "__main__":
    main()
