#!/usr/bin/env python3
"""Validate config/ai-engines.json (#1973).

Usage: validate-ai-engines.py [config.json] [schema.json] [pricing.tsv]

Defaults to the repo's config/ai-engines.json, config/ai-engines.schema.json
and scripts/lib/model-pricing.tsv. Validates the file against the JSON Schema
(draft 2020-12, the same `jsonschema>=4` setup evals/validate-cases.py uses),
then checks what a schema cannot express:

  - every model a task names is in `models` and not `retired`;
  - every model a task names belongs to the provider of the chain it is in;
  - every non-retired model of an enabled provider has a price row in
    model-pricing.tsv (a vendor-prefixed id such as openai/o4-mini is priced by
    its bare name, as token records store it);
  - `duck`, and every `copilot` chain, holds one model (neither has an
    in-engine chain).

Every problem is reported as a `::error::` line. Exit 0 when valid, 1 otherwise.
"""
import json
import os
import re
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SINGLE_MODEL_TASKS = ("duck",)
SINGLE_MODEL_PROVIDERS = ("copilot",)
PROVIDERS = ("claude", "gemini", "copilot")


def error(msg: str) -> None:
    print(f"::error::ai-engines config invalid: {msg}", file=sys.stderr)


def safe_path(arg: str, what: str) -> Path:
    """Resolve a CLI-supplied path and confine it to the repo or the system temp dir
    (the bats tests stage fixtures there), refusing traversal elsewhere."""
    resolved = Path(os.path.realpath(arg))
    roots = (os.path.realpath(REPO), os.path.realpath(tempfile.gettempdir()))
    if not any(resolved == Path(r) or Path(r) in resolved.parents for r in roots):
        error(f"{what} path {arg} is outside the repository and the temp dir")
        sys.exit(1)
    return resolved


def load_json(path: Path, what: str):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        error(f"could not read/parse {what} {path}: {exc}")
        sys.exit(1)


def price_globs(path: Path) -> list:
    """The model_glob column of model-pricing.tsv (comments and short rows skipped,
    as scripts/lib/model-pricing.sh does)."""
    globs = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        error(f"could not read price table {path}: {exc}")
        sys.exit(1)
    for line in lines:
        if re.match(r"^\s*#", line):
            continue
        cols = line.split("\t")
        if len(cols) >= 6 and cols[0]:
            globs.append(cols[0])
    return globs


def glob_matches(glob: str, model: str) -> bool:
    """model-pricing.sh's glob rule: '*' and '?' are wildcards, the rest literal."""
    regex = "".join(".*" if c == "*" else "." if c == "?" else re.escape(c) for c in glob)
    return re.fullmatch(regex, model) is not None


def check_schema(config, schema) -> list:
    try:
        import jsonschema
    except ImportError:
        error("jsonschema not installed (pip install 'jsonschema>=4')")
        sys.exit(1)
    validator = jsonschema.Draft202012Validator(schema)
    problems = []
    for err in sorted(validator.iter_errors(config), key=lambda e: list(e.absolute_path)):
        where = "/".join(str(p) for p in err.absolute_path) or "(root)"
        problems.append(f"schema: {where}: {err.message}")
    return problems


def check_references(config, globs) -> list:
    problems = []
    models = config["models"]
    providers = config["providers"]
    if not any(entry["enabled"] for name, entry in providers.items() if name in PROVIDERS):
        problems.append("providers: every provider is disabled; enable at least one")
    for task, chains in config["tasks"].items():
        if not isinstance(chains, dict):
            continue  # $comment
        for provider in PROVIDERS:
            # The duck runs on Claude only; the other tasks need a chain per enabled provider.
            needed = provider == "claude" if task in SINGLE_MODEL_TASKS else True
            if needed and providers[provider]["enabled"] and provider not in chains:
                problems.append(f"tasks.{task}.{provider}: missing chain for enabled provider {provider}")
        for provider, chain in chains.items():
            if provider not in PROVIDERS:
                continue  # prefer, $comment
            for model in chain:
                entry = models.get(model)
                if entry is None:
                    problems.append(f"tasks.{task}.{provider}: '{model}' is not in models")
                    continue
                if entry["status"] == "retired":
                    problems.append(f"tasks.{task}.{provider}: '{model}' is retired")
                if entry["provider"] != provider:
                    problems.append(
                        f"tasks.{task}.{provider}: '{model}' belongs to provider "
                        f"{entry['provider']}, not {provider}")
            if len(chain) > 1 and (task in SINGLE_MODEL_TASKS or provider in SINGLE_MODEL_PROVIDERS):
                why = "the duck runs one model" if task in SINGLE_MODEL_TASKS else "Copilot has no in-engine chain"
                problems.append(f"tasks.{task}.{provider}: takes one model ({why}), got {len(chain)}")
    for model, entry in models.items():
        if entry["status"] == "retired" or not providers[entry["provider"]]["enabled"]:
            continue
        # Only the Copilot path strips a vendor prefix before pricing a run.
        bare = model.split("/", 1)[1] if entry["provider"] == "copilot" and "/" in model else model
        if not any(glob_matches(g, model) or glob_matches(g, bare) for g in globs):
            problems.append(
                f"models.{model}: provider {entry['provider']} is enabled but the model has "
                f"no price row in scripts/lib/model-pricing.tsv")
    return problems


def main(argv) -> int:
    config_path = safe_path(argv[1], "config") if len(argv) > 1 else REPO / "config" / "ai-engines.json"
    schema_path = safe_path(argv[2], "schema") if len(argv) > 2 else REPO / "config" / "ai-engines.schema.json"
    pricing_path = safe_path(argv[3], "pricing") if len(argv) > 3 else REPO / "scripts" / "lib" / "model-pricing.tsv"

    config = load_json(config_path, "config")
    schema = load_json(schema_path, "schema")
    problems = check_schema(config, schema)
    # The reference checks index into the shape the schema guarantees.
    if not problems:
        problems = check_references(config, price_globs(pricing_path))
    for p in problems:
        error(p)
    if problems:
        print(f"ai-engines config INVALID: {len(problems)} problem(s) in {config_path}", file=sys.stderr)
        return 1
    tasks = [t for t in config["tasks"] if t != "$comment"]
    print(f"ai-engines config OK: {len(config['models'])} model(s), {len(tasks)} task(s) ({config_path})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
