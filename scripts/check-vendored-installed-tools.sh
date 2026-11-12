#!/usr/bin/env bash
# check-vendored-installed-tools.sh — narrow guard (#1541, split from #1468 AC 3)
# against the #1449 failure class.
#
# Fails when a tool this repo's CI installs via a package manager
# (`apt-get install`, `npm install`/`npm ci`, `pip install`) is *also* committed
# as a vendored copy under a dependency-manager directory (node_modules/,
# vendor/, .venv/) in the same tree. That is exactly what happened in #1449:
# dev-lead committed node_modules/bats/ while lint.yml already ran
# `apt-get install -y bats`, so CI installed bats twice from two sources and the
# committed copy was pure noise.
#
# Deliberately narrow (#1468 Dev Notes, AC #2):
#   - Static allowlist of (tool leaf -> install-step regex) tuples. NOT a general
#     dependency resolver — a tool is only checked if it is in the allowlist AND
#     an actual workflow install step names it.
#   - Fires ONLY on the overlap: CI installs tool X *and* a vendored copy of X is
#     present under a dependency-manager directory. A legitimate first-party
#     committed asset (not under node_modules/vendor/.venv, or of a tool CI does
#     not install) never trips it.
#   - Scans git-tracked files when the tree is a git work tree, so a gitignored
#     local `npm install` (per .gitignore, bats lives under node_modules/ at dev
#     time) never fires — only a COMMITTED vendored copy does, matching the
#     #1449 signature. Non-git trees (test fixtures) fall back to a filesystem
#     scan.
#
# Usage: check-vendored-installed-tools.sh [tree]   (default: the repo root that
#        contains this scripts/ directory)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TREE="${1:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [[ ! -d "$TREE" ]]; then
  echo "::error::check-vendored-installed-tools: tree does not exist: ${TREE}" >&2
  exit 2
fi

WF_DIR="$TREE/.github/workflows"

# Dependency-manager directories a vendored copy would live under.
DEP_DIRS="node_modules|vendor|\.venv"

# Allowlist of tool leaf-names to guard. Each maps (via tool_install_regex) to an
# ERE that matches a package-manager install step naming that exact tool. Add a
# row here + its regex to guard another tool.
TOOL_LEAVES=(bats yq markdownlint-cli2)

# The install-step regex for a tool: an install verb (apt-get install /
# npm install|ci / pip[3] install) followed on the same line by the tool name as
# a whole word.
# Word boundaries use POSIX ERE character classes — (^|[^...]) / ($|[^...]) —
# rather than the GNU-only `\b`, so the regex behaves the same under BSD/macOS
# grep as under GNU grep.
tool_install_regex() {
  local verb='(apt-get +install|npm +(install|ci)|pip[0-9]* +install)'
  case "$1" in
    bats|yq|markdownlint-cli2)
      printf '%s.*(^|[^a-zA-Z0-9_-])%s($|[^a-zA-Z0-9_-])\n' "$verb" "$1"
      ;;
    *) return 1 ;;
  esac
}

# List the tree's files. Prefer git-tracked paths (so an untracked/gitignored
# local install is invisible); fall back to a filesystem walk for non-git trees.
list_tree_files() {
  # Check that $TREE is itself a git work tree root (has a .git dir/file), not
  # merely nested inside a parent repo — otherwise `git ls-files` would run
  # against the parent and return nothing for an untracked tree (e.g. a BATS
  # temp dir created under the repo during local dev), silently passing.
  if [[ -e "$TREE/.git" ]]; then
    git -C "$TREE" ls-files
  else
    ( cd "$TREE" && find . -type f | sed 's|^\./||' )
  fi
}

# Workflow files whose text contains an install step matching $1 (ERE). Each
# file's shell line-continuations (a trailing `\` folding onto the next line)
# are joined before matching, so an install split across physical lines — e.g.
# `apt-get install -y \` then `bats` on the next line — is still detected;
# plain per-line grep would miss it.
workflow_install_files() {
  [[ -d "$WF_DIR" ]] || return 0
  local f
  find "$WF_DIR" -type f 2>/dev/null | while IFS= read -r f; do
    if awk '{ while (sub(/\\$/, "")) { if ((getline nxt) > 0) $0 = $0 nxt; else break } print }' "$f" \
      | grep -qE "$1"; then
      printf '%s\n' "$f"
    fi
  done
}

tree_files="$(list_tree_files || true)"

fail=0
report=""
for leaf in "${TOOL_LEAVES[@]}"; do
  regex="$(tool_install_regex "$leaf")" || continue

  install_files="$(workflow_install_files "$regex")"
  [[ -n "$install_files" ]] || continue

  # Vendored directories of this leaf under a dependency-manager directory.
  vendored="$(printf '%s\n' "$tree_files" \
    | grep -E "(^|/)(${DEP_DIRS})/${leaf}(/|$)" \
    | sed -E "s#^(.*(${DEP_DIRS})/${leaf}).*#\\1#" \
    | LC_ALL=C sort -u || true)"
  [[ -n "$vendored" ]] || continue

  fail=1
  report="${report}Tool '${leaf}' is installed by CI:
$(printf '%s\n' "$install_files" | sed 's|^|    |')
  but a vendored copy is committed under a dependency-manager directory:
$(printf '%s\n' "$vendored" | sed 's|^|    |')
"
done

if [ "$fail" -ne 0 ]; then
  echo "::error::Vendored copy of a CI-installed tool detected (#1541 / #1449)."
  printf '%s\n' "$report"
  echo "CI already installs this tool via a package manager, so the committed"
  echo "vendored copy is redundant (and was never meant to be checked in). Remove"
  echo "the vendored directory under node_modules/, vendor/, or .venv/ and rely on"
  echo "the package-manager install."
  exit 1
fi

echo "vendored-installed-tools: no CI-installed tool is also committed as a vendored copy under ${TREE}"
exit 0
