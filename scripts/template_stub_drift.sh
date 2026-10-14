#!/usr/bin/env bash
set -euo pipefail
# template_stub_drift.sh — drift guard for the repo-template scaffold (#969, epic
# #964). Fails CI when a file committed in combsmith/repo-template has
# drifted from its canonical standards-derived baseline, so the template stays a
# thin distribution layer of standards/ and never becomes a competing fork.
#
# repo-template is a DISTRIBUTION ARTIFACT of the canonical standards/ in the
# public combsmith/.github repo: scripts/seed-repo-template.sh fetches each
# canonical workflow stub / baseline file and ships it (caller stubs repinned to
# the published @<name>/stable channel, inline stubs + baseline files verbatim).
# This guard re-derives that standards-based content and compares it, file by
# file, against what is actually committed in the template repo.
#
# It REUSES the byte-identity drift model from fleet_stub_drift.sh:
#   classify_stub_drift <expected_sha> <committed_sha> -> ALIGNED|DRIFTED|MISSING
#   stub_drift_row <file> <expected_sha> <committed_sha>
# The "expected" SHA is the git blob SHA of seed-repo-template.sh's emission for
# the file (the standards-derived content, repin included); the "committed" SHA
# is the blob SHA the contents API returns for the file in the template repo.
# Equal blob SHAs ⇒ byte-identical files ⇒ the template still tracks standards.
#
# All functions here are PURE (no network): they take SHAs / a drift TSV and
# write to stdout, exactly like fleet_stub_drift.sh. The network (gh contents
# reads + git hash-object of the seed emission) lives only in the CLI driver
# (main) at the bottom, mirroring how fleet_monitor.sh drives fleet_stub_drift.sh.
#
# Drift TSV format (4 fields, tab-separated), shared with fleet_stub_drift.sh:
#   1:file  2:status  3:committed_sha  4:expected_sha

TEMPLATE_DRIFT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TEMPLATE_REPO="${TEMPLATE_REPO:-combsmith/repo-template}"

# shellcheck source=scripts/fleet_stub_drift.sh
source "${TEMPLATE_DRIFT_DIR}/fleet_stub_drift.sh"

# ── Covered-file manifest (AC #2) ─────────────────────────────────────────────
# Each row: "path|emit_flag|emit_arg" — the committed repo-template path plus how
# seed-repo-template.sh emits its standards-derived expected content. Covers every
# shipped workflow stub EXCEPT the allowlisted ci.yml (see below), plus the
# verbatim baseline files dependabot.yml, CODEOWNERS, and CLAUDE.md.
readonly -a TEMPLATE_DRIFT_FILES=(
  ".github/workflows/agent-shield.yml|--emit-workflow|agent-shield.yml"
  ".github/workflows/auto-rebase.yml|--emit-workflow|auto-rebase.yml"
  ".github/workflows/copilot-setup-steps.yml|--emit-workflow|copilot-setup-steps.yml"
  ".github/workflows/dependabot-automerge.yml|--emit-workflow|dependabot-automerge.yml"
  ".github/workflows/dependabot-rebase.yml|--emit-workflow|dependabot-rebase.yml"
  ".github/workflows/dependency-audit.yml|--emit-workflow|dependency-audit.yml"
  ".github/workflows/dev-lead.yml|--emit-workflow|dev-lead.yml"
  ".github/workflows/pr-review-mention.yml|--emit-workflow|pr-review-mention.yml"
  ".github/workflows/sonarcloud.yml|--emit-workflow|sonarcloud.yml"
  ".github/dependabot.yml|--emit-baseline|.github/dependabot.yml"
  ".github/CODEOWNERS|--emit-baseline|.github/CODEOWNERS"
  "CLAUDE.md|--emit-baseline|CLAUDE.md"
  ".gitleaks.toml|--emit-baseline|.gitleaks.toml"
)

# ── Documented allowlist (AC #2) ──────────────────────────────────────────────
# ci.yml is the ONE shipped stub that intentionally carries real per-stack
# build/test steps and is customized per consumer (see the template's BOOTSTRAP.md
# "Customize ci.yml for your stack" step and AGENTS.md). A byte-identity guard
# would false-positive on the template's richer ci.yml default, so it is excluded
# here — mirroring how AGENTS.md documents the lint.yml / token-report.yml /
# pr-review-sweep.yml exceptions. Add a path here ONLY with a recorded rationale.
readonly -a TEMPLATE_DRIFT_ALLOWLIST=(
  ".github/workflows/ci.yml"
)

# template_drift_allowlisted <path> — return 0 if the path is an allowlisted,
# intentionally-customizable file excluded from byte-identity drift.
template_drift_allowlisted() {
  local path="${1:-}" a
  for a in "${TEMPLATE_DRIFT_ALLOWLIST[@]}"; do
    [ "$a" = "$path" ] && return 0
  done
  return 1
}

# template_drift_covered — print the covered file paths (manifest minus allowlist),
# one per line. Pure: writes stdout only.
template_drift_covered() {
  local row path
  for row in "${TEMPLATE_DRIFT_FILES[@]}"; do
    path="${row%%|*}"
    template_drift_allowlisted "$path" && continue
    printf '%s\n' "$path"
  done
}

# template_drift_annotate <tsv_file> — emit a GitHub `::error::` annotation for
# every DRIFTED row, naming the file and BOTH SHAs (AC #3). Returns 1 if any row
# is DRIFTED (so the CI job fails), 0 otherwise. MISSING rows are surfaced as a
# non-fatal `::warning::` — only DRIFTED fails the job (AC #1). Pure: reads the
# TSV, writes stdout. An absent/empty file is a clean pass.
template_drift_annotate() {
  local f="${1:-}" file status committed expected drifted=0
  [ -n "$f" ] && [ -f "$f" ] || return 0
  while IFS=$'\t' read -r file status committed expected; do
    [ -n "$file" ] || continue
    case "$status" in
      DRIFTED)
        drifted=1
        printf '::error file=%s::Template stub %s has DRIFTED from the standards-derived baseline (committed blob %s != expected %s). Re-seed it via scripts/seed-repo-template.sh — do not hand-edit the template; edit standards/ instead.\n' \
          "$file" "$file" "${committed:0:12}" "${expected:0:12}"
        ;;
      MISSING)
        printf '::warning file=%s::Template stub %s is MISSING from %s (expected blob %s) — re-seed via scripts/seed-repo-template.sh.\n' \
          "$file" "$file" "$TEMPLATE_REPO" "${expected:0:12}"
        ;;
    esac
  done < "$f"
  [ "$drifted" -eq 0 ]
}

# ── CLI driver (network) ──────────────────────────────────────────────────────
# For each covered file: compute the expected SHA (git blob SHA of the
# seed-repo-template.sh emission, which fetches standards/ and repins) and the
# committed SHA (contents API `.sha` on the template repo), classify via
# stub_drift_row, print the drift table, annotate, and exit non-zero on any
# DRIFTED file. A SHA that cannot be computed/read degrades to a non-fatal
# `::warning::` skip (mirrors fleet_monitor.sh) so a transient cross-repo read
# failure does not flake the PR lint job — only real drift fails it.

# _template_drift_expected_sha <emit_flag> <emit_arg> — git blob SHA of the
# standards-derived content seed-repo-template.sh would ship for this file.
# Captures via $(...) so trailing newlines are stripped exactly the way the seed
# script strips them before writing the file (contents-API blob parity).
_template_drift_expected_sha() {
  local content
  content="$(DRY_RUN=false bash "${TEMPLATE_DRIFT_DIR}/seed-repo-template.sh" "$1" "$2" 2>/dev/null)" || return 1
  [ -n "$content" ] || return 1
  printf '%s' "$content" | git hash-object --stdin
}

# _template_drift_committed_sha <path> — contents-API blob SHA of the file as
# committed in the template repo. Empty on 404 (file absent ⇒ MISSING).
# Note: gh api with --jq does not apply the jq filter on error responses in some
# gh versions — it writes the raw 404 JSON to stdout instead. Separating the gh
# call from jq processing ensures the 404 body is filtered via .sha // empty,
# returning "" so classify_stub_drift produces MISSING rather than DRIFTED.
_template_drift_committed_sha() {
  local out
  out="$(gh api "repos/${TEMPLATE_REPO}/contents/${1}" 2>/dev/null)" || true
  printf '%s' "$out" | jq -r '.sha // empty' 2>/dev/null || true
}

main() {
  local cmd
  for cmd in gh git; do
    command -v "$cmd" > /dev/null 2>&1 || { echo "::error::${cmd} is required but not installed." >&2; return 1; }
  done

  local tsv row path flag arg expected committed
  tsv="$(mktemp)"
  echo "Template stub drift check — ${TEMPLATE_REPO} vs standards-derived baseline:"
  for row in "${TEMPLATE_DRIFT_FILES[@]}"; do
    IFS='|' read -r path flag arg <<< "$row"
    template_drift_allowlisted "$path" && continue
    if ! expected="$(_template_drift_expected_sha "$flag" "$arg")"; then
      echo "::warning::Could not compute the standards-derived SHA for ${path} (seed emit failed) — skipping its drift check."
      continue
    fi
    committed="$(_template_drift_committed_sha "$path")"
    stub_drift_row "$path" "$expected" "$committed" >> "$tsv"
  done

  cat "$tsv"
  local rc=0
  template_drift_annotate "$tsv" || rc=$?
  rm -f "$tsv"
  return "$rc"
}

# Source-guard: tests source this to exercise the pure helpers; CI executes it.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
