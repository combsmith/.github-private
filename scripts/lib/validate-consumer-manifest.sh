#!/usr/bin/env bash
set -euo pipefail
# validate-consumer-manifest.sh — schema + local-surface validator for the
# consumer manifest (issue #749, epic #748).
#
# The manifest (consumer-manifest.json, same directory) is the single
# machine-checkable source of truth mapping each provider reusable workflow to
# the org repos (consumers) that pin it, plus the in-provider scripts/lib, prompts
# and config each reusable sources (surface_sources). This validator is the gate that keeps
# the manifest honest. It exits non-zero on:
#   - invalid JSON or a violated top-level schema shape
#   - a surface_sources KEY that is not an existing reusable-workflow path in
#     this repo (a file under .github/workflows/ that declares `workflow_call`)
#   - a surface_sources VALUE that is not an existing scripts/lib/*.sh,
#     scripts/lib/*.tsv, prompts/*, or config/*.json path in this repo
#
# Existence is always checked against --repo-root (the .github-private working
# tree), independent of where the manifest file itself lives, so a fixture in a
# tmp dir can be validated against the real repo surfaces.
#
# Usage:
#   validate-consumer-manifest.sh [--manifest PATH] [--repo-root DIR]
# Env overrides (lower precedence than flags):
#   CONSUMER_MANIFEST     path to the manifest JSON
#   MANIFEST_REPO_ROOT    repo root used for local-surface existence checks
# Exit codes: 0 valid; 1 invalid (one or more errors printed to stderr); 2 usage.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MANIFEST="${CONSUMER_MANIFEST:-$SCRIPT_DIR/consumer-manifest.json}"
REPO_ROOT="${MANIFEST_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest)
      if [ "$#" -lt 2 ]; then
        echo "validate-consumer-manifest: --manifest requires a value" >&2
        exit 2
      fi
      MANIFEST="$2"
      shift 2
      ;;
    --repo-root)
      if [ "$#" -lt 2 ]; then
        echo "validate-consumer-manifest: --repo-root requires a value" >&2
        exit 2
      fi
      REPO_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "validate-consumer-manifest: unknown argument '$1'" >&2
      exit 2 ;;
  esac
done

errors=0
err() { echo "validate-consumer-manifest: $*" >&2; errors=$((errors + 1)); }

[ -f "$MANIFEST" ] || { err "manifest not found: $MANIFEST"; exit 1; }

# 1. Valid JSON. jq empty parses without emitting output; any syntax error here
#    means the whole manifest is unusable, so fail fast.
if ! jq empty "$MANIFEST" 2>/dev/null; then
  err "manifest is not valid JSON: $MANIFEST"
  exit 1
fi

# 2. Top-level schema shape:
#    providers = non-empty array of strings
#    consumers = array of {repo: string, refs: [string]}
#    surface_sources = object whose values are arrays of strings
schema_ok=$(jq -r '
  . as $manifest |
  def is_str_array: type == "array" and (all(.[]; type == "string"));
  def valid_ref: . as $ref | $manifest.providers | any(. as $p | ($ref | startswith($p + "/")));
  ( ($manifest.providers | type == "array" and length > 0 and is_str_array)
    and ($manifest.consumers | type == "array"
         and all(.[]; type == "object"
                 and (.repo | type == "string")
                 and (.refs | is_str_array and all(.[]; valid_ref))))
    and ($manifest.surface_sources | type == "object"
         and all(.[]; is_str_array))
  )
' "$MANIFEST" 2>/dev/null || echo "false")

if [ "$schema_ok" != "true" ]; then
  err "manifest violates the required schema (providers/consumers/surface_sources shape)"
  exit 1
fi

# 3. surface_sources keys must be existing reusable-workflow paths in this repo;
#    their values must be existing scripts/lib/*.sh, scripts/lib/*.tsv, prompts/*,
#    or config/*.json paths in this repo (config/ai-engines.json, #1973).
#    Paths are resolved via realpath to prevent traversal sequences from escaping
#    their intended root directories.
wf_root=$(realpath -m "$REPO_ROOT/.github/workflows")
lib_root=$(realpath -m "$REPO_ROOT/scripts/lib")
prompts_root=$(realpath -m "$REPO_ROOT/prompts")
config_root=$(realpath -m "$REPO_ROOT/config")

while IFS= read -r key; do
  [ -n "$key" ] || continue
  case "$key" in
    .github/workflows/*) : ;;
    *) err "surface_sources key is not under .github/workflows/: $key"; continue ;;
  esac
  resolved=$(realpath -m "$REPO_ROOT/$key")
  if [ "${resolved#"${wf_root}/"}" = "$resolved" ]; then
    err "surface_sources key contains path traversal: $key"
    continue
  fi
  if [ ! -f "$resolved" ]; then
    err "surface_sources key is not an existing reusable-workflow path: $key"
    continue
  fi
  if ! grep -q 'workflow_call' "$resolved"; then
    err "surface_sources key is not a reusable workflow (no workflow_call): $key"
  fi
done < <(jq -r '.surface_sources | keys[]' "$MANIFEST")

while IFS= read -r value; do
  [ -n "$value" ] || continue
  case "$value" in
    scripts/lib/*.sh|scripts/lib/*.tsv|prompts/*|config/*.json) : ;;
    *)
      err "surface_sources value is not a scripts/lib/*.sh, scripts/lib/*.tsv, prompts/*, or config/*.json path: $value"
      continue ;;
  esac
  resolved=$(realpath -m "$REPO_ROOT/$value")
  if [ "${resolved#"${lib_root}/"}" = "$resolved" ] && [ "${resolved#"${prompts_root}/"}" = "$resolved" ] \
     && [ "${resolved#"${config_root}/"}" = "$resolved" ]; then
    err "surface_sources value contains path traversal: $value"
    continue
  fi
  if [ ! -f "$resolved" ]; then
    err "surface_sources value points at a non-existent local surface: $value"
  fi
done < <(jq -r '.surface_sources | to_entries[] | .value[]' "$MANIFEST")

if [ "$errors" -ne 0 ]; then
  echo "validate-consumer-manifest: FAILED with $errors error(s)" >&2
  exit 1
fi

echo "validate-consumer-manifest: OK ($MANIFEST)"
