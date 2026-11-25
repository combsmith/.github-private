#!/usr/bin/env bash
# deep-specialist.sh — issue-type classifier routing for the deep review tier
# (issue #1091, epic #1088).
#
# The Tier-1 triage prompt (prompts/triage.md) now emits a `type` label that
# classifies an escalated diff into one of {security, logic, performance,
# style}. This helper turns that label into the specialist deep-review prompt
# the cascade should load for the deep tier — resolved DATA-DRIVEN through the
# rubric registry (scripts/lib/review-registry.tsv `deep_specialist:<type>`
# rows), NOT a switch statement in review-one-pr.sh. That keeps specialist
# routing consistent with the artifact-contract standard: add a manifest row,
# do not fork the reviewer.
#
# The classifier rides on the existing Haiku-tier triage call — there is no new
# model tier and no extra call, so median review cost is unchanged.
#
# Fallback (AC #4): when the label is absent/ambiguous, has no registry row, or
# points at a specialist prompt that is not on disk, resolution falls back to
# the monolithic prompts/deep-review.md so the deep tier never dead-ends.
#
# Usage: source this file, then call:
#   normalize_diff_type <raw-label>     -> canonical class or "ambiguous"
#   classify_triage_type <triage-json>  -> canonical class or "ambiguous"
#   resolve_deep_specialist <type> <fallback-prompt>
#       -> specialist prompt path, or <fallback-prompt> if unresolved

set -euo pipefail

# The classes the triage classifier may emit. Anything else is "ambiguous"
# and takes the monolithic fallback path.
DEEP_SPECIALIST_CLASSES=(security logic performance style)

# Bring in the shared registry lookup helper if the caller has not already
# sourced it (review-one-pr.sh sources both; tests may source only this file).
if ! declare -F review_registry_lookup >/dev/null 2>&1; then
  # shellcheck source=review-registry.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review-registry.sh"
fi

# normalize_diff_type <raw-label>
#   Lower-cases and strips whitespace from the raw label, echoing it only when
#   it is one of DEEP_SPECIALIST_CLASSES; otherwise echoes "ambiguous". Never
#   fails, so callers can rely on a usable value on the escalate path.
normalize_diff_type() {
  local raw="${1:-}" c
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  for c in "${DEEP_SPECIALIST_CLASSES[@]}"; do
    if [[ "$raw" = "$c" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  printf 'ambiguous\n'
}

# classify_triage_type <triage-json>
#   Extracts the `.type` field from the triage JSON and normalizes it. Missing
#   or invalid JSON, or a missing/unknown field, yields "ambiguous". Never fails.
classify_triage_type() {
  local json="${1:-}" raw
  raw="$(printf '%s' "$json" | jq -r '.type // empty' 2>/dev/null || true)"
  normalize_diff_type "$raw"
}

# resolve_deep_specialist <type> <fallback-prompt>
#   Resolves the specialist deep-review prompt for <type> via the rubric
#   registry (the `deep_specialist:<type>` row). Prints the specialist prompt
#   path when the type is a known class AND the registry resolves it AND the
#   file exists on disk; otherwise prints <fallback-prompt>. Never fails — the
#   fallback guarantees a usable prompt (AC #4).
#
#   The repo root used to confirm the specialist file exists is derived from
#   this file's location; override with DEEP_SPECIALIST_REPO_ROOT in tests.
resolve_deep_specialist() {
  local type fallback root specialist
  type="$(normalize_diff_type "${1:-}")"
  fallback="${2:?resolve_deep_specialist: fallback prompt required}"
  root="${DEEP_SPECIALIST_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

  if [[ "$type" = "ambiguous" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi

  specialist="$(review_registry_lookup "deep_specialist:$type" rubric 2>/dev/null | tr -d '\r')" || {
    printf '%s\n' "$fallback"
    return 0
  }

  if [[ -n "$specialist" ]] && [[ -f "$root/$specialist" ]]; then
    printf '%s\n' "$specialist"
  else
    printf '%s\n' "$fallback"
  fi
}
