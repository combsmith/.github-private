#!/usr/bin/env python3
"""Validate agentic persona manifests.

Every `personas/<id>/persona.yml` is validated against the canonical persona
schema (owned by combsmith/.github) PLUS the cross-invariants the JSON
schema cannot express on its own:

  * `id` == the persona directory name == `canary.agent`
  * `address.handle`'s team slug == `id` (so a mention routes by prefix-strip).
    This makes handle uniqueness a THEOREM rather than a check: the schema pins
    the org (^combsmith/...), slug == id, id == the persona directory name,
    and directory names are unique — so two personas cannot claim the same
    handle. There is deliberately no cross-file uniqueness check.

    Scope of that claim: it covers `address.handle`, which is the only thing the
    mention router resolves. `address.aliases` shared the handle namespace and
    was NOT covered by it — which is why a uniqueness check existed while
    aliases did. Aliases are being removed from the addressing contract
    (combsmith/.github#755 finding 1); this repo has already dropped every
    use, and the companion PR drops the field from the schema. Until that lands
    the schema still PERMITS an alias, so re-adding one here would reopen the
    namespace this theorem does not cover. Do not.
  * every `definition.layers[].path` exists on disk
  * a `framework-agent` layer's `framework.vendor_pin` actually appears in the
    referenced `frameworks/<name>/VENDOR.md` (pin ↔ vendored version agree)
  * each eval set (`evals.path`, or every entry of `evals.paths`) carries both
    `dev/cases.jsonl` and `holdout/cases.jsonl`; and once the persona has reached
    its `evals.required_before` ring, each held-out set has >= `min_cases`
    (the enforceable half of principle 5 — a draft is exempt)
  * a non-`draft` persona has a matching `agents.<id>` entry in the canary ring
    registry (`canary-rings.json`), so status never outruns registration

Schema resolution order:
  1. --schema PATH                     (explicit local file; used by tests)
  2. $PERSONA_SCHEMA_FILE              (local file)
  3. fetch from combsmith/.github at $PERSONA_SCHEMA_REF (default: main)

The schema lives in the org standards repo, not here — this validator reads it
the same way any consumer repo reads a published standard. When run against the
canary registry check, the registry is read the same way.

Usage:
  validate-personas.py [personas_root] [--schema PATH] [--registry PATH]

Exit 0 on success; non-zero with a diagnostic on the first failure class found.
"""
import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path
from typing import NoReturn

SCHEMA_REPO = "combsmith/.github"
SCHEMA_PATH_IN_REPO = "standards/personas/persona.schema.json"
REGISTRY_PATH_IN_REPO = "standards/canary-rings.json"
MANIFEST_NAME = "persona.yml"


def fail(msg: str) -> NoReturn:
    print(f"::error::persona manifest invalid: {msg}", file=sys.stderr)
    sys.exit(1)


def _raw_url(ref: str, path: str) -> str:
    return f"https://raw.githubusercontent.com/{SCHEMA_REPO}/{ref}/{path}"


def _fetch_json(path: str, what: str) -> dict:
    """Fetch a JSON file from the standards repo, trying the configured ref then
    falling back to main (self-healing once a feature branch merges/deletes)."""
    ref = os.environ.get("PERSONA_SCHEMA_REF", "main")
    refs = [ref] if ref == "main" else [ref, "main"]
    last = None
    for r in refs:
        url = _raw_url(r, path)
        try:
            with urllib.request.urlopen(url, timeout=20) as resp:  # noqa: S310 (fixed host)
                return json.loads(resp.read().decode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            last = f"{url}: {exc}"
    fail(f"could not fetch {what} from {SCHEMA_REPO} (tried {', '.join(refs)}): {last}. "
         f"Ensure {SCHEMA_REPO} carries {path}, or pass a local override.")


def load_schema(explicit: str | None) -> dict:
    candidate = explicit or os.environ.get("PERSONA_SCHEMA_FILE")
    if candidate:
        try:
            return json.loads(Path(candidate).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            fail(f"could not read/parse schema {candidate}: {exc}")
    return _fetch_json(SCHEMA_PATH_IN_REPO, "persona schema")


def load_registry(explicit: str | None) -> dict:
    candidate = explicit or os.environ.get("PERSONA_REGISTRY_FILE")
    if candidate:
        try:
            return json.loads(Path(candidate).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            fail(f"could not read/parse registry {candidate}: {exc}")
    return _fetch_json(REGISTRY_PATH_IN_REPO, "canary registry")


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
             f"(e.g. 'combsmith/qa-lead'), got {value!r}")
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


def check_invariants(manifest: dict, manifest_path: Path, repo_root: Path,
                     registry_arg: str | None) -> None:
    persona_dir = manifest_path.parent
    pid = manifest["id"]

    if pid != persona_dir.name:
        fail(f"{manifest_path}: id '{pid}' != directory name '{persona_dir.name}'")
    if manifest["canary"]["agent"] != pid:
        fail(f"{manifest_path}: canary.agent '{manifest['canary']['agent']}' != id '{pid}'")

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

    check_identity(manifest, manifest_path)

    check_evals(manifest, manifest_path, repo_root)

    if manifest["status"] != "draft":
        registry = load_registry(registry_arg)
        if not registry_has_agent(registry, pid):
            fail(f"{manifest_path}: status '{manifest['status']}' is past draft but no "
                 f"agents.{pid} entry exists in {REGISTRY_PATH_IN_REPO} (register once)")


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

    schema = load_schema(args.schema)
    jsonschema.Draft202012Validator.check_schema(schema)
    validator = jsonschema.Draft202012Validator(schema)

    for manifest_path in manifests:
        try:
            manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
        except (OSError, yaml.YAMLError) as exc:
            fail(f"could not read/parse {manifest_path}: {exc}")
        error = next(validator.iter_errors(manifest), None)
        if error is not None:
            loc = "/".join(str(p) for p in error.absolute_path) or "<root>"
            fail(f"{manifest_path}: schema violation at {loc}: {error.message}")
        check_invariants(manifest, manifest_path, repo_root, args.registry)

    print(f"OK: {len(manifests)} persona manifest(s) valid, invariants hold.")


if __name__ == "__main__":
    main()
