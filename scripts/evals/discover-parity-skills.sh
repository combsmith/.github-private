#!/usr/bin/env bash
set -euo pipefail
# discover-parity-skills.sh — list the skills scored at PARITY tier (#1702).
#
# The weekly persona-parity cadence in skill-eval-report.yml scores a skill at
# the tier its evals/<skill>/scorer.json declares. A skill is at parity when it
# declares `"engine": "persona"`; a skill without that field defaults to the
# Haiku-tier triage scorer and is NOT part of this cadence. This script derives
# that set from the scorer configs themselves — never a hardcoded skill list —
# so adding a persona to the parity cadence requires no edit to the workflow
# (AC #3, the same derive-don't-enumerate rule as the `<id>:hands-off` family,
# #756). It is the single source of truth run-eval.sh already reads for the tier.
#
# Emits a single-line JSON array of skill names (sorted, unique) to stdout, ready
# to feed a GitHub Actions `strategy.matrix`. An evals tree with no parity skill
# emits `[]` — never a crash — so the matrix simply has no jobs.
#
# Env overrides:
#   EVALS_DIR   held-out eval root (default: <repo>/evals); read-only. Mirrors
#               run-eval.sh so offline tests point it at a fixture tree.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EVALS_DIR="${EVALS_DIR:-$REPO_ROOT/evals}"

command -v jq >/dev/null 2>&1 || { echo "::error::discover-parity-skills: jq is required but not installed" >&2; exit 2; }

skills=()
for cfg in "$EVALS_DIR"/*/scorer.json; do
  [[ -f "$cfg" ]] || continue   # no scorer.json (or glob matched nothing) => triage default, skip
  # Assign in its own statement, not inside the `|| continue` list: a `$(jq …)`
  # substitution whose failure is swallowed by `||` would let a malformed
  # scorer.json be silently skipped under `set -e`. A bare assignment lets a jq
  # parse error abort the script loudly instead.
  engine="$(jq -r '.engine // "triage"' "$cfg")"
  [[ "$engine" = "persona" ]] || continue
  skills+=("$(basename "$(dirname "$cfg")")")
done

if [[ "${#skills[@]}" -eq 0 ]]; then
  echo "[]"
else
  printf '%s\n' "${skills[@]}" | sort -u | jq -R . | jq -cs .
fi
