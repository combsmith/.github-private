#!/usr/bin/env python3
"""Validate config/ai-engines.json (#2631, part 1 of #1973).

  validate-ai-engines.py [--config PATH] [--schema PATH] [--pricing PATH]

Defaults are resolved relative to this script: config/ai-engines.json,
config/ai-engines.schema.json and scripts/lib/model-pricing.tsv.

The file is checked against the schema (JSON Schema draft 2020-12, with the
same jsonschema setup evals/validate-cases.py uses), then against the rules the
schema cannot express. It fails when:

  - a task names a model missing from `models`, or marked `retired`;
  - a model appears in a chain of a provider other than its own;
  - an enabled provider's model has no price row in effect today in
    model-pricing.tsv. Rows are matched the way price_for
    (scripts/lib/model-pricing.sh) matches them, on the id without its vendor
    prefix, which is how engine.sh records it (openai/o4-mini -> o4-mini);
  - `duck`, `fable` or any Copilot chain lists more than one model (the lib
    keeps only the first, and the GitHub Models client has no chain).

Every failure is printed as a ::error:: line. Exit 0 when the file is valid,
1 otherwise.
"""
import argparse
import datetime
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SINGLE_MODEL_TASKS = ("duck", "fable")
SINGLE_MODEL_PROVIDERS = ("copilot",)
PROVIDERS = ("claude", "gemini", "copilot")
# Tasks every enabled provider must have a chain for. `duck` is Claude-only on
# purpose (a provider left out follows its triage chain); `fable` is Claude's.
CHAIN_TASKS = ("triage", "deep", "audit", "action", "single")
DUCK_PROVIDERS = ("claude",)
_MISSING = object()


def error(msg: str) -> None:
    print(f"::error::ai-engines: {msg}", file=sys.stderr)


def load_json(path: Path, what: str):
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        error(f"could not read {what} {path}: {exc}")
        return _MISSING
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        error(f"{what} {path} is not valid JSON: {exc}")
        return _MISSING


def glob_to_regex(glob: str) -> "re.Pattern[str]":
    """The price_for glob: '*' is any run, '?' one character, all else literal."""
    parts = []
    for ch in glob:
        if ch == "*":
            parts.append(".*")
        elif ch == "?":
            parts.append(".")
        else:
            parts.append(re.escape(ch))
    return re.compile("^" + "".join(parts) + "$")


def load_price_rows(path: Path):
    """[(regex, effective_from)] from the TSV, skipping comments and short rows."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        error(f"could not read price table {path}: {exc}")
        return None
    rows = []
    for line in lines:
        if line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 6:
            continue
        rows.append((glob_to_regex(fields[0]), fields[1]))
    return rows


def price_key(model_id: str) -> str:
    """The id token records and the price table use: without a vendor prefix."""
    return model_id.split("/", 1)[1] if "/" in model_id else model_id


def has_price(model_id: str, rows, today: str) -> bool:
    key = price_key(model_id)
    return any(rx.match(key) and eff <= today for rx, eff in rows)


def schema_errors(config, schema) -> list:
    try:
        import jsonschema
    except ImportError:
        return ["jsonschema not installed (pip install --require-hashes -r requirements/ci/jsonschema.txt)"]
    try:
        jsonschema.Draft202012Validator.check_schema(schema)
    except jsonschema.exceptions.SchemaError as exc:
        return [f"the schema itself is invalid: {exc.message}"]
    validator = jsonschema.Draft202012Validator(schema)
    out = []
    for err in sorted(validator.iter_errors(config), key=lambda e: list(e.absolute_path)):
        where = ".".join(str(p) for p in err.absolute_path) or "(root)"
        out.append(f"schema: {where}: {err.message}")
    return out


def rule_errors(config, price_rows, today: str) -> list:
    models = config["models"]
    providers = config["providers"]
    out = []

    enabled = [p for p in PROVIDERS if providers[p]["enabled"]]
    if not enabled:
        out.append("providers: no provider is enabled")
    for provider in enabled:
        for task in CHAIN_TASKS:
            if provider not in config["tasks"][task]:
                out.append(f"tasks.{task}.{provider}: missing chain for enabled provider {provider}")
    if "claude" not in config["tasks"]["duck"] and providers["claude"]["enabled"]:
        out.append("tasks.duck.claude: missing chain for enabled provider claude")
    for provider in config["tasks"]["duck"]:
        if provider in PROVIDERS and provider not in DUCK_PROVIDERS:
            out.append(f"tasks.duck.{provider}: duck is Claude-only; {provider} follows its triage chain")

    for task, chains in config["tasks"].items():
        for provider, chain in chains.items():
            if provider not in PROVIDERS:
                continue  # `prefer`, not a chain
            where = f"tasks.{task}.{provider}"
            for model_id in chain:
                entry = models.get(model_id)
                if entry is None:
                    out.append(f"{where}: {model_id} is not in models")
                    continue
                if entry["status"] == "retired":
                    out.append(f"{where}: {model_id} is retired")
                if entry["provider"] != provider:
                    out.append(f"{where}: {model_id} belongs to provider {entry['provider']}, not {provider}")
            if len(chain) > 1 and (task in SINGLE_MODEL_TASKS or provider in SINGLE_MODEL_PROVIDERS):
                out.append(f"{where}: takes one model, got {len(chain)} ({','.join(chain)})")

    for model_id, entry in models.items():
        if not providers[entry["provider"]]["enabled"]:
            continue
        if entry["status"] == "retired":
            continue
        if not has_price(model_id, price_rows, today):
            out.append(
                f"models.{model_id}: no price row in effect today in model-pricing.tsv "
                f"(looked up as {price_key(model_id)}; provider {entry['provider']} is enabled)"
            )
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", type=Path, default=REPO_ROOT / "config" / "ai-engines.json")
    ap.add_argument("--schema", type=Path, default=REPO_ROOT / "config" / "ai-engines.schema.json")
    ap.add_argument("--pricing", type=Path, default=REPO_ROOT / "scripts" / "lib" / "model-pricing.tsv")
    args = ap.parse_args(argv)

    config = load_json(args.config, "config")
    schema = load_json(args.schema, "schema")
    if config is _MISSING or schema is _MISSING:
        return 1
    if not isinstance(config, dict) or not isinstance(schema, dict):
        error("config and schema must each be a JSON object")
        return 1

    errors = schema_errors(config, schema)
    if errors:
        # The rules below index the file by its schema shape; on a shape error
        # report the schema failures alone rather than crash on them.
        for msg in errors:
            error(msg)
        return 1

    price_rows = load_price_rows(args.pricing)
    if price_rows is None:
        return 1
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")

    errors = rule_errors(config, price_rows, today)
    for msg in errors:
        error(msg)
    if errors:
        print(f"ai-engines: {len(errors)} error(s) in {args.config}", file=sys.stderr)
        return 1

    n_chains = sum(1 for chains in config["tasks"].values() for p in chains if p in PROVIDERS)
    print(f"ai-engines OK: {len(config['models'])} model(s), {n_chains} chain(s) in {args.config}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
