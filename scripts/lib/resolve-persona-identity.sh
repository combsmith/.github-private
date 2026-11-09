#!/usr/bin/env bash
# resolve-persona-identity.sh — print a persona's declared runtime identity.
#
# Usage: resolve-persona-identity.sh <persona-id> <personas-root> [field]
#   field: account (default) | credential
#
# Reads <personas-root>/<persona-id>/persona.yml and prints runtime.identity.<field>.
# This is the SINGLE runtime source of a persona's acting GitHub identity: the
# dev-lead and pr-review workflows resolve BOT_USER from `account` here instead of
# the shared `vars.BOT_USER` that let dev-lead regress to committing as the
# review-only machine user donpetry-bot (.github-private#1316).
#
# Exits non-zero (message on stderr) if the manifest, the identity block, or the
# requested field is missing — it never emits a silent fallback identity.  Callers
# decide whether to treat the non-zero exit as fatal or fall back to a safe default.
set -euo pipefail

id="${1:?usage: resolve-persona-identity.sh <persona-id> <personas-root> [field]}"
root="${2:?usage: resolve-persona-identity.sh <persona-id> <personas-root> [field]}"
field="${3:-account}"

case "$field" in
  account | credential) ;;
  *)
    echo "resolve-persona-identity: field must be 'account' or 'credential', got '$field'" >&2
    exit 2
    ;;
esac

manifest="${root%/}/${id}/persona.yml"
if [[ ! -f "$manifest" ]]; then
  echo "resolve-persona-identity: no manifest at $manifest" >&2
  exit 1
fi

# Prefer PyYAML (same parser validate-personas.py uses); fall back to a simple
# standard-library-only parser if PyYAML is not installed to avoid pip install
# overhead and PEP 668 ("externally-managed-environment") failures.
python3 - "$manifest" "$field" <<'PY'
import sys

manifest, field = sys.argv[1], sys.argv[2]
val = None

try:
    import yaml
    with open(manifest, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}
    identity = ((doc.get("runtime") or {}).get("identity")) or {}
    val = identity.get(field)
except ImportError:
    # Fallback to a simple line-by-line parser if PyYAML is not installed
    try:
        with open(manifest, encoding="utf-8") as fh:
            state = "start"
            runtime_indent = -1
            identity_indent = -1
            for line in fh:
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                indent = len(line) - len(line.lstrip())
                if state == "start" and stripped == "runtime:":
                    state = "runtime"
                    runtime_indent = indent
                elif state == "runtime":
                    if indent <= runtime_indent:
                        state = "start"
                    elif stripped == "identity:":
                        state = "identity"
                        identity_indent = indent
                elif state == "identity":
                    if indent <= identity_indent:
                        if indent <= runtime_indent:
                            state = "start"
                        else:
                            state = "runtime"
                    else:
                        if ":" in stripped:
                            k, v = stripped.split(":", 1)
                            if k.strip() == field:
                                val = v.strip().strip("'\"")
                                break
    except Exception as e:
        sys.stderr.write(f"resolve-persona-identity: fallback parser failed: {e}\n")
        sys.exit(5)

if not val:
    sys.stderr.write(
        f"resolve-persona-identity: runtime.identity.{field} missing in {manifest}\n"
    )
    sys.exit(4)
print(val)
PY
