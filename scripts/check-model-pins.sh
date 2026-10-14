#!/usr/bin/env bash
set -euo pipefail
# scripts/check-model-pins.sh (#1979) — fail when a concrete Claude model id is
# hard-pinned outside the allowed files.
#
# The org standard: name a model FAMILY (opus|sonnet|haiku) and let
# ai_model_for_family (scripts/lib/engine-models.sh) return the current id, so a
# model swap is one variable/chain edit rather than a hunt across the tree
# (companion petry-projects/.github#1199).
#
# A "pin" is any concrete, digit-versioned Claude id — claude-<family>-<digit>…
# (opus|sonnet|haiku|fable) — appearing under a scanned directory. Two escape
# hatches keep legitimate concrete ids from failing the check:
#   1. Allow-listed files (the resolver that defines the mapping; the price table
#      that must name ids for historical token records).
#   2. Any line carrying the marker `model-pin-ok:` (a per-line, reasoned
#      exception — e.g. the eval judge held fixed for confound control).
#
# Usage: check-model-pins.sh [root]   (root defaults to the repo root)
# Exit:  0 clean · 1 one or more unmarked pins (each printed as file:line)
#        2 a scan error (grep failed), so the tree cannot be certified clean

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# docs/ is deliberately NOT scanned: docs legitimately cite concrete ids (pricing
# history, override examples, migration notes). Describe a workflow's model by
# its family there; this gate covers the code and config that actually run.
SCAN_DIRS=(.github scripts prompts agents personas)
# Family-first ids (claude-<family>-<N>…) and the legacy version-first form
# (claude-<N>-<N>-<family>-<date>).
PATTERN='claude-((opus|sonnet|haiku|fable)-[0-9]|[0-9]+(-[0-9]+)?-(opus|sonnet|haiku|fable))'

# Allow-listed paths (relative to ROOT). These files legitimately name concrete
# ids: the resolver defines the family→id mapping, the price table records rates.
is_allowed() {
  case "$1" in
    scripts/lib/engine-models.sh)  return 0 ;;
    scripts/lib/model-pricing.tsv) return 0 ;;
  esac
  return 1
}

found=0
for d in "${SCAN_DIRS[@]}"; do
  [ -d "$ROOT/$d" ] || continue
  # Capture matches. grep exits 0 (match), 1 (no match — expected/clean) or >1
  # (a real scan error: missing grep, unreadable tree). Never mask >1 with
  # `|| true` — that would report a false clean and let hard pins pass; fail loud.
  hits=""
  hits="$(grep -rnIE "$PATTERN" "$ROOT/$d" 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "::error::check-model-pins: scan of '$d' failed (grep exit $rc) — cannot certify clean." >&2
    exit 2
  fi
  [ -n "$hits" ] || continue
  while IFS= read -r hit || [ -n "$hit" ]; do
    [ -n "$hit" ] || continue
    file="${hit%%:*}"
    rel="${file#"$ROOT"/}"
    is_allowed "$rel" && continue
    case "$hit" in *model-pin-ok:*) continue ;; esac
    # Reprint with a repo-relative path for readable CI annotations.
    printf '%s\n' "${rel}:${hit#*:}"
    found=1
  done <<< "$hits"
done

if [ "$found" -ne 0 ]; then
  echo "::error::check-model-pins: hard-pinned Claude model id(s) found above — name a family (opus|sonnet|haiku) via ai_model_for_family, or mark the line 'model-pin-ok: <reason>' if a concrete id is required."
  exit 1
fi

echo "check-model-pins: no unmarked model pins found."
