#!/usr/bin/env bash
# verify-persona-identity.sh — LIVE-ish drift check for persona runtime identity.
#
# The schema (persona.schema.json) validates the SHAPE of runtime.identity and
# validate-personas.py makes it MANDATORY. This script closes the loop between the
# manifest and the workflows that consume it, so the declared identity and the
# actual CI wiring can never silently diverge (the failure mode behind
# .github-private#1316). For each persona it asserts:
#
#   1. credential naming — a non-grandfathered credential MUST be
#      GH_PAT_<ACCOUNT_UPPER_SNAKE>[_<QUALIFIER>] for the declared account.
#   2. credential is real — the secret is referenced by at least one workflow
#      (guards against declaring a phantom/typo'd secret).
#   3. runtime consumption — a persona that ships a write workflow MUST resolve
#      its identity from the manifest (call resolve-persona-identity.sh), not from
#      the shared vars.BOT_USER.
#
# Usage: verify-persona-identity.sh [personas-root]
# Exit 0 = all good; exit 1 = a drift/violation was found.
set -euo pipefail

ROOT="${1:-personas}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$SCRIPT_DIR/lib/resolve-persona-identity.sh"
WORKFLOWS_DIR=".github/workflows"

# Credentials that pre-date the GH_PAT_<ACCOUNT> convention (kept as-is). Mirror
# GRANDFATHERED_CREDENTIALS in personas/validate-personas.py.
GRANDFATHERED=(
  DON_PETRY_BOT_GH_PAT
  DON_PETRY_BOT_GH_PAT_CLASSIC
)

# Personas that ship a write workflow which MUST consume the manifest identity.
# id:workflow-path pairs. Advisory personas post via the shared persona runner
# and are covered by checks 1-2 only.
declare -a WRITE_RUNTIMES=(
  "dev-lead:.github/workflows/dev-lead-reusable.yml"
  "pr-review:.github/workflows/pr-review.yml"
)

fail() { echo "::error::verify-persona-identity: $*" >&2; exit 1; }

is_grandfathered() {
  local c="$1" g
  for g in "${GRANDFATHERED[@]}"; do [[ "$c" = "$g" ]] && return 0; done
  return 1
}

# Upper-snake-case conversion for account names is done inline via pure Bash parameter expansion.

runtime_for() {
  local id="$1" pair
  for pair in "${WRITE_RUNTIMES[@]}"; do
    [[ "${pair%%:*}" = "$id" ]] && { printf '%s' "${pair#*:}"; return 0; }
  done
  return 1
}

count=0
for manifest in "$ROOT"/*/persona.yml; do
  [[ -f "$manifest" ]] || continue
  manifest_dir="${manifest%/persona.yml}"
  id="${manifest_dir##*/}"
  account="$(bash "$RESOLVE" "$id" "$ROOT" account)"
  credential="$(bash "$RESOLVE" "$id" "$ROOT" credential)"

  # 1. credential naming convention
  if ! is_grandfathered "$credential"; then
    upper_account="${account^^}"
    expect="GH_PAT_${upper_account//-/_}"
    case "$credential" in
      "$expect" | "${expect}_"*) : ;;
      *) fail "$id: credential '$credential' does not match '${expect}[_<QUALIFIER>]' for account '$account'" ;;
    esac
  fi

  # 2. credential is referenced by at least one workflow
  if ! grep -rqlE "secrets\.${credential}([^A-Z0-9_]|$)" "$WORKFLOWS_DIR" 2>/dev/null; then
    fail "$id: credential secret '$credential' is not referenced by any workflow in $WORKFLOWS_DIR"
  fi

  # 3. write personas must consume the manifest identity at runtime
  if wf="$(runtime_for "$id")"; then
    [[ -f "$wf" ]] || fail "$id: declared runtime workflow '$wf' does not exist"
    if ! grep -qE '(bash|sh)[[:space:]]+.*resolve-persona-identity\.sh' "$wf"; then
      fail "$id: runtime workflow '$wf' must resolve identity from the manifest (call resolve-persona-identity.sh), not vars.BOT_USER"
    fi
  fi

  echo "  ok: $id acts as '$account' via secret '$credential'"
  count=$((count + 1))
done

if [[ "$count" -eq 0 ]]; then
  echo "no persona manifests under $ROOT — nothing to verify."
else
  echo "verify-persona-identity: $count persona identity mapping(s) consistent."
fi
