#!/usr/bin/env bash
# check-duplicate-decls.sh — required CI gate against the #1485 corruption class.
#
# Fails when any scanned file carries the #1485 whole-block-duplication signature:
#   - scripts/**/*.sh   — the same top-level FUNCTION declared more than once.
#     Bash last-definition-wins semantics mean a duplicated function silently
#     shadows its earlier copies, so the test suite stays green while the file
#     content is wrong — the mechanism that let the #1292 and #1378 merges land
#     wholesale duplicated scripts on main (see #1485 for the incident record and
#     #1520 for this gate's story).
#   - prompts/**/*.md   — the same markdown HEADING repeated in a file. A prompt
#     that restates a "Phase 2/3/4" block twice instructs the agent to repeat the
#     phase; fix-ci.md (46 lines) and fix-reviews.md (20 lines) shipped exactly
#     this (#1779).
#   - personas/**/*.yml — the same KEY declared twice in one mapping. YAML
#     last-key-wins hides it from yaml.safe_load-based validators, and the moment
#     the two values diverge the first is silently discarded (persona.yml carried
#     a duplicate `reusable:` under `runtime:`, #1779).
#
# The md/yml scopes close the scan-scope gap filed as petry-projects/.github#1041
# (the shipped gate only ever looked at scripts/). This is that one gate widened,
# not a second gate.
#
# Deliberately narrow (#1520 AC, extended by #1779):
#   - Tree-state, not diff-aware: standing corruption fails, whoever introduced
#     it. The parent-aware introduction detector is lib/conflict-integrity.sh
#     on the rebase path (#1482); this gate is the merge-blocking backstop.
#   - Shell VARIABLE reassignment at column 0 is legitimate (defaults overwritten
#     conditionally), so var duplicates are not gated — functions only.
#   - YAML keys repeated across DIFFERENT list items or DIFFERENT mappings are not
#     duplicates and are not flagged (see extract_yaml_mapping_keys).
#   - A verified-benign duplicate heading is recorded in MD_HEADING_ALLOWLIST with
#     a rationale — the only escape hatch, and only for headings.
#
# Usage: check-duplicate-decls.sh [dir]
#   - No args: full repo scan — scripts/ (this file's dir), prompts/ and personas/.
#   - <dir>:   legacy mode — scan <dir> for duplicate .sh functions only. The md
#     and yml scans stay OFF unless DUPLICATE_DECL_PROMPTS_DIR /
#     DUPLICATE_DECL_PERSONAS_DIR name a directory, keeping .sh-only fixtures
#     isolated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/conflict-integrity.sh
source "$SCRIPT_DIR/lib/conflict-integrity.sh"

SCAN_DIR="${1:-$SCRIPT_DIR}"
if [ ! -d "$SCAN_DIR" ]; then
  echo "::error::check-duplicate-decls: scan directory does not exist: ${SCAN_DIR}" >&2
  exit 2
fi

if [ "$#" -ge 1 ]; then
  PROMPTS_DIR="${DUPLICATE_DECL_PROMPTS_DIR:-}"
  PERSONAS_DIR="${DUPLICATE_DECL_PERSONAS_DIR:-}"
else
  PROMPTS_DIR="${DUPLICATE_DECL_PROMPTS_DIR:-$REPO_ROOT/prompts}"
  PERSONAS_DIR="${DUPLICATE_DECL_PERSONAS_DIR:-$REPO_ROOT/personas}"
fi

# Verified-benign duplicate markdown headings the gate must NOT flag. Format:
# "<repo-relative-file>::<exact heading line>". Add an entry only with a recorded
# rationale (mirrors TEMPLATE_DRIFT_ALLOWLIST / REMEDIATION_ALLOWLIST).
#   - prompts/triage.md "## Issue-type classification": the classification
#     guidance is intentionally stated once per issue-type pass and was verified
#     benign by the #1779 sweep — do not "fix" it.
MD_HEADING_ALLOWLIST=(
  "prompts/triage.md::## Issue-type classification"
)

fail=0
report=""

# Enumerate each scan's files up front. A `done < <(find …)` process substitution
# does not propagate `find`'s exit status to the consuming loop under
# `set -o pipefail`, so an unreadable directory could emit a partial list, exit
# nonzero, and still leave the gate green. Capturing via command substitution
# (which pipefail *does* honor) lets us fail closed instead (#1782).
# --- scripts/ : duplicate top-level shell functions --------------------------
if ! sh_files="$(find "$SCAN_DIR" -name '*.sh' -type f | LC_ALL=C sort)"; then
  echo "::error::check-duplicate-decls: failed to enumerate .sh files under ${SCAN_DIR}" >&2
  exit 2
fi
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # `grep` exits 1 on a file with no functions at all — that is a clean result,
  # not an error, so neutralize the pipeline status under `set -o pipefail`.
  findings="$(extract_top_level_symbols "$f" \
    | { grep '^fn:' || true; } \
    | sed 's/^fn://' \
    | LC_ALL=C sort | uniq -c \
    | awk '$1 > 1 { print $2 "\t" $1 }')"
  if [ -n "$findings" ]; then
    fail=1
    report="${report}$(format_integrity_findings "$f" "$findings")
"
  fi
done <<< "$sh_files"

# --- prompts/ : duplicate markdown headings ----------------------------------
if [ -n "$PROMPTS_DIR" ] && [ -d "$PROMPTS_DIR" ]; then
  if ! md_files="$(find "$PROMPTS_DIR" -name '*.md' -type f | LC_ALL=C sort)"; then
    echo "::error::check-duplicate-decls: failed to enumerate .md files under ${PROMPTS_DIR}" >&2
    exit 2
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$REPO_ROOT"/}"
    while IFS= read -r heading; do
      [ -n "$heading" ] || continue
      allowed=0
      for entry in "${MD_HEADING_ALLOWLIST[@]}"; do
        if [ "$entry" = "${rel}::${heading}" ]; then allowed=1; break; fi
      done
      [ "$allowed" -eq 1 ] && continue
      fail=1
      report="${report}- \`${rel}\` — duplicate markdown heading: \`${heading}\`
"
    done < <(extract_markdown_headings "$f" | LC_ALL=C sort | uniq -d)
  done <<< "$md_files"
fi

# --- personas/ : duplicate keys in the same mapping --------------------------
if [ -n "$PERSONAS_DIR" ] && [ -d "$PERSONAS_DIR" ]; then
  if ! yml_files="$(find "$PERSONAS_DIR" \( -name '*.yml' -o -name '*.yaml' \) -type f | LC_ALL=C sort)"; then
    echo "::error::check-duplicate-decls: failed to enumerate persona YAML files under ${PERSONAS_DIR}" >&2
    exit 2
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$REPO_ROOT"/}"
    while IFS= read -r dupline; do
      [ -n "$dupline" ] || continue
      scope="${dupline%%$'\t'*}"
      key="${dupline##*$'\t'}"
      [ -n "$scope" ] || scope="<root>"
      fail=1
      report="${report}- \`${rel}\` — duplicate key \`${key}\` in mapping \`${scope}\`
"
    done < <(extract_yaml_mapping_keys "$f" | LC_ALL=C sort | uniq -d)
  done <<< "$yml_files"
fi

if [ "$fail" -ne 0 ]; then
  echo "::error::Duplicate declarations found — the #1485 corruption class. This merge is blocked."
  printf '%s\n' "$report"
  echo "This is the signature of a botched automated conflict resolution (see #1485"
  echo "for the incident record and restoration playbook, #1520 for this gate,"
  echo "#1779 for the prompts/personas widening)."
  echo "Fix by removing the duplicated definitions — do not patch around the check."
  exit 1
fi

echo "duplicate-decl-gate: no duplicate top-level function declarations under ${SCAN_DIR}" \
     "(and no duplicate prompt headings or persona mapping keys)"
