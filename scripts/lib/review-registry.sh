#!/usr/bin/env bash
# review-registry.sh — sourced lookup helper for the rubric registry (issue #611).
#
# The artifact contract treats every reviewable thing as four fields:
#   {artifact_type, content_ref, rubric, output_channel}
# (see scripts/lib/README.md for the full contract). This helper owns the
# {artifact_type -> rubric, output_channel} half of that contract: it is the
# input-adapter / registry layer ABOVE engine.sh, so the reviewer's logic can
# later be reused for plans and skills without forking it three ways.
#
# Data lives in the versioned manifest review-registry.tsv (same directory) —
# code resolves, the manifest registers. Phase 1 registers only pr_diff,
# resolving to today's PR-review behavior with no change.
#
# Usage: source this file, then call:
#   review_registry_version                       -> schema version (integer)
#   review_registry_types                         -> registered artifact_types, one per line
#   review_registry_lookup <artifact_type> <field>
#       field is "rubric" or "output_channel"; prints the value.
#       Returns 1 for an unknown artifact_type, 2 for an unknown/missing field.

set -euo pipefail

# Resolve the manifest path once, relative to this file (works when sourced
# from anywhere). Honor an override so callers/tests can point elsewhere.
if [[ -z "${REVIEW_REGISTRY_MANIFEST:-}" ]]; then
  REVIEW_REGISTRY_MANIFEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review-registry.tsv"
fi

# review_registry_version
#   Prints the manifest's schema_version (read from its `# schema_version: N`
#   comment). Returns non-zero if absent so callers can detect a malformed
#   manifest rather than silently using an unversioned one.
review_registry_version() {
  [[ -f "$REVIEW_REGISTRY_MANIFEST" ]] || { echo "review_registry_version: manifest file not found at $REVIEW_REGISTRY_MANIFEST" >&2; return 1; }
  local v
  v=$(awk '/^#[[:space:]]*schema_version:/ {
            gsub(/[^0-9]/, "", $0); print; exit
          }' "$REVIEW_REGISTRY_MANIFEST") || true
  [[ -n "$v" ]] || { echo "review_registry_version: no schema_version in $REVIEW_REGISTRY_MANIFEST" >&2; return 1; }
  printf '%s\n' "$v"
}

# review_registry_types
#   Prints every registered artifact_type (first column of each data row),
#   one per line. Comment and blank lines are ignored.
review_registry_types() {
  [[ -f "$REVIEW_REGISTRY_MANIFEST" ]] || { echo "review_registry_types: manifest file not found at $REVIEW_REGISTRY_MANIFEST" >&2; return 1; }
  awk -F'\t' '!/^[[:space:]]*#/ && $1 != "" { print $1 }' "$REVIEW_REGISTRY_MANIFEST"
}

# review_registry_lookup <artifact_type> <field>
#   Resolves an artifact_type to one field of its registry entry.
#   field: "rubric" (ordered comma-separated prompt cascade) or
#          "output_channel" (script that delivers the verdict).
#   Exit codes: 0 ok; 1 unknown artifact_type; 2 missing/unknown field.
review_registry_lookup() {
  local artifact_type="${1:-}" field="${2:-}" col
  [[ -n "$artifact_type" ]] || { echo "review_registry_lookup: artifact_type required" >&2; return 2; }
  case "$field" in
    rubric)         col=2 ;;
    output_channel) col=3 ;;
    '')             echo "review_registry_lookup: field required (rubric|output_channel)" >&2; return 2 ;;
    *)              echo "review_registry_lookup: unknown field '$field' (allowed: rubric, output_channel)" >&2; return 2 ;;
  esac
  [[ -f "$REVIEW_REGISTRY_MANIFEST" ]] || { echo "review_registry_lookup: manifest file not found at $REVIEW_REGISTRY_MANIFEST" >&2; return 2; }
  local value
  value=$(awk -F'\t' -v t="$artifact_type" -v c="$col" '
            !/^[[:space:]]*#/ && $1 == t { print $c; found = 1; exit }
            END { exit(found ? 0 : 1) }
          ' "$REVIEW_REGISTRY_MANIFEST") || {
    echo "review_registry_lookup: unknown artifact_type '$artifact_type'" >&2
    return 1
  }
  [[ -n "$value" ]] || { echo "review_registry_lookup: field '$field' is empty for '$artifact_type'" >&2; return 2; }
  printf '%s\n' "$value"
}
