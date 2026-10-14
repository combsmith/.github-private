#!/usr/bin/env bash
set -euo pipefail
# template_stub_drift.sh — drift guard for the repo-template scaffold (#969, epic
# #964). Fails CI when a file committed in petry-projects/repo-template has
# drifted from its canonical standards-derived baseline, so the template stays a
# thin distribution layer of standards/ and never becomes a competing fork.
#
# repo-template is a DISTRIBUTION ARTIFACT of the canonical standards/ in the
# public petry-projects/.github repo: scripts/seed-repo-template.sh fetches each
# canonical workflow stub / baseline file and ships it (caller stubs repinned to
# the published @<name>/v<MAJOR>-stable channel, inline stubs + baseline files verbatim).
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
# Drift TSV format (5 fields, tab-separated); the first 4 are shared with
# fleet_stub_drift.sh, the 5th records which published version the committed file
# matched under #1448's N / N-1 acceptance:
#   1:file  2:status  3:committed_sha  4:expected_sha(N)  5:matched(N|N-1|"")
# A file is ALIGNED if it matches the emission at the current published version (N)
# or the immediately-preceding one (N-1); an N-1 match is a visible propagation
# notice, not silent (#1448 AC #8). The resolved standards ref + commit SHA the
# baseline is derived at is recorded in the report header (AC #7), and a guard
# asserts neither N nor N-1 carries a pre-#1184 legacy non-major-scoped pin (AC #9).

TEMPLATE_DRIFT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TEMPLATE_REPO="${TEMPLATE_REPO:-petry-projects/repo-template}"

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
  # Collapsed Class-1 caller (ADR-0007, #1726): once repo-template collapses the
  # per-role dev-lead.yml/pr-review-mention.yml stubs into one agent-ingress.yml,
  # this row gives it byte-identity coverage. Until then the template has no such
  # file and it reports the non-fatal MISSING every not-yet-seeded row does, so the
  # per-role rows above still guard the un-collapsed template — no coverage hole in
  # either state, and no false failure during the rollout.
  ".github/workflows/agent-ingress.yml|--emit-workflow|agent-ingress.yml"
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
# pr-review-sweep.yml exceptions.
# Add a path here ONLY with a recorded rationale.
readonly -a TEMPLATE_DRIFT_ALLOWLIST=(
  ".github/workflows/ci.yml"
  # sonarcloud.yml and dependabot.yml diverge intentionally from standards because
  # repo-template uses npm-based tooling (dependabot for npm packages, sonarcloud
  # with standard action versions) while .github-private uses GitHub Actions
  # orchestration (dependabot for GitHub Actions, sonarcloud with custom Java
  # provisioning args). These divergences are legitimate per-consumer customization
  # and should not block the drift guard (#1448).
  ".github/workflows/sonarcloud.yml"
  ".github/dependabot.yml"
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

# ── Reference rows (#1729, AC #12) ────────────────────────────────────────────
# A reference row is a file the manifest ENROLLS for post-collapse byte-identity
# coverage but which seed-repo-template.sh deliberately never seeds into
# repo-template until a pilot repo's per-role stubs collapse into it. It lives in
# the --emit-workflow REFERENCE_MANIFEST of seed-repo-template.sh (reachable
# for hashing, but never written by _seed_repo into the seeded set). Until #1729's
# pilot lands the collapse, the template has no such file, so a reference row
# reports MISSING every run — but the GENERIC "re-seed via seed-repo-template.sh"
# remedy can never clear that warning (seed deliberately won't emit it) and, worse,
# following it means hand-copying a live executing ingress into every new repo
# ahead of the pilot (#1729 AC #12). A reference row therefore gets a distinct,
# NON-ACTIONABLE notice instead of the generic remedy. When #1729's pilot collapse
# lands, this file is seeded in the SAME change that retires the per-role stubs it
# replaces, and its row stops being a reference row.
readonly -a TEMPLATE_DRIFT_REFERENCE=(
  ".github/workflows/agent-ingress.yml"
)

# template_drift_is_reference <path> — return 0 if the path is a reference row
# (enrolled for coverage but intentionally not seeded yet). Pure.
template_drift_is_reference() {
  local path="${1:-}" r
  for r in "${TEMPLATE_DRIFT_REFERENCE[@]}"; do
    [ "$r" = "$path" ] && return 0
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

# ── N / N-1 acceptance (#1448 AC #8) ──────────────────────────────────────────
# A stub is ALIGNED if its committed blob matches the emission at EITHER the
# current published version (N) or the immediately preceding one (N-1) — so a
# standards promotion does not instantly fail every consumer while the new version
# propagates. An N-1 match is reported (matched=N-1) so the annotate step can raise
# a visible propagation notice rather than accept it silently.
#
# template_drift_classify <committed> <expected_n> <expected_n1>
#   → "<status>\t<matched>"  where status ∈ ALIGNED|DRIFTED|MISSING and
#     matched ∈ N | N-1 | "" (empty when not ALIGNED). N-1 is only consulted when
#     <expected_n1> is non-empty (the publication scheme provides a previous ref).
template_drift_classify() {
  local committed="${1:-}" expected_n="${2:-}" expected_n1="${3:-}"
  if [ -z "$committed" ] || [ "$committed" = "null" ]; then
    printf 'MISSING\t\n'
  elif [ -n "$expected_n" ] && [ "$committed" = "$expected_n" ]; then
    printf 'ALIGNED\tN\n'
  elif [ -n "$expected_n1" ] && [ "$committed" = "$expected_n1" ]; then
    printf 'ALIGNED\tN-1\n'
  else
    printf 'DRIFTED\t\n'
  fi
}

# template_drift_row5 <file> <committed> <expected_n> <expected_n1>
#   → one 5-field TSV row: file<TAB>status<TAB>committed<TAB>expected_n<TAB>matched.
# The expected SHA column carries N (the current published version) so a DRIFTED
# annotation points at what the file SHOULD be at the current version.
template_drift_row5() {
  local file="${1:-}" committed="${2:-}" expected_n="${3:-}" expected_n1="${4:-}"
  local status matched
  IFS=$'\t' read -r status matched < <(template_drift_classify "$committed" "$expected_n" "$expected_n1")
  printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$status" "$committed" "$expected_n" "$matched"
}

# template_drift_report_header <resolved_ref> <resolved_sha> <prev_ref>
# One-line report header naming the resolved standards ref + commit SHA the
# baseline was derived at (#1448 AC #7), and — when a previous (N-1) ref is
# configured — noting that N-1 emissions are also accepted (AC #8). Pure.
template_drift_report_header() {
  local ref="${1:-}" sha="${2:-}" prev="${3:-}"
  printf 'Baseline derived from standards ref `%s` (commit `%s`) on %s.\n' \
    "$ref" "${sha:0:12}" "$TEMPLATE_REPO"
  if [ -n "$prev" ]; then
    printf 'Also accepting the immediately-preceding version (N-1) at ref `%s` while a promotion propagates.\n' "$prev"
  fi
}

# ── Major-scoped pin guard (#1448 AC #9) ──────────────────────────────────────
# Assert the resolved standards content does NOT carry a pre-#1184 legacy
# non-major-scoped reusable pin (`<name>-reusable.yml@<name>/<tier>` with a bare
# tier — stable/next/ring0/ring1 — instead of `<name>/v<MAJOR>-<tier>`). Neither N
# nor N-1 may resolve to such content, so this issue's fix cannot be undone by a
# pin. Content with no reusable pin (inline stubs, baseline files) passes. Returns
# 1 and annotates on any legacy pin found; 0 otherwise. Pure: reads args/stdin.
template_drift_assert_major_scoped() {
  local content legacy
  if [ $# -ge 1 ]; then
    content="$1"
  else
    content="$(cat)"
  fi
  # A reusable pin whose tier is a bare stable|next|ring0|ring1 not preceded by v<MAJOR>-.
  legacy="$(printf '%s\n' "$content" \
    | grep -oE '[A-Za-z0-9._-]+-reusable\.yml@[A-Za-z0-9._-]+/(stable|next|ring0|ring1)([^A-Za-z0-9./-]|$)' \
    || true)"
  if [ -n "$legacy" ]; then
    printf '::error::resolved standards content carries a pre-#1184 legacy non-major-scoped reusable pin (%s) — neither N nor N-1 may reintroduce it (#1448 AC #9).\n' \
      "${legacy%%$'\n'*}"
    return 1
  fi
  return 0
}

# template_drift_annotate <tsv_file> — walk the drift TSV and annotate:
#   • DRIFTED → `::error::` naming the file and BOTH SHAs (AC #3); fails the job.
#   • ALIGNED with matched=N-1 → `::notice::` (propagation pending): the file
#     matches the immediately-preceding published version, not the current one, so
#     it is accepted but flagged visibly, not silently (#1448 AC #8).
#   • MISSING → non-fatal `::warning::` — only DRIFTED fails the job (AC #1).
# Reads either the legacy 4-field rows or the 5-field (matched) rows; a missing
# 5th field is treated as an N (current-version) match. Pure: reads the TSV,
# writes stdout. An absent/empty file is a clean pass.
template_drift_annotate() {
  local f="${1:-}" row file status committed expected matched drifted=0
  [ -n "$f" ] && [ -f "$f" ] || return 0
  # Split each row on tabs WITHOUT collapsing empty fields — `IFS=$'\t' read`
  # treats a tab as whitespace-IFS and would coalesce the empty committed field on
  # a MISSING row, shifting every later column. Peel fields off explicitly instead.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    file="${row%%$'\t'*}";      row="${row#*$'\t'}"
    status="${row%%$'\t'*}";    row="${row#*$'\t'}"
    committed="${row%%$'\t'*}"; row="${row#*$'\t'}"
    expected="${row%%$'\t'*}"
    if [ "$row" != "$expected" ] || [[ "$row" == *$'\t'* ]]; then
      row="${row#*$'\t'}"
      matched="${row%%$'\t'*}"
    else
      matched=""
    fi
    [ -n "$file" ] || continue
    case "$status" in
      DRIFTED)
        drifted=1
        printf '::error file=%s::Template stub %s has DRIFTED from the standards-derived baseline (committed blob %s != expected %s). Re-seed it via scripts/seed-repo-template.sh — do not hand-edit the template; edit standards/ instead.\n' \
          "$file" "$file" "${committed:0:12}" "${expected:0:12}"
        ;;
      ALIGNED)
        if [ "$matched" = "N-1" ]; then
          printf '::notice file=%s::Template stub %s matches the immediately-preceding published standards version (N-1), not the current one (N) — propagation pending, accepted as ALIGNED (#1448 AC #8).\n' \
            "$file" "$file"
        fi
        ;;
      MISSING)
        if template_drift_is_reference "$file"; then
          # Reference row: enrolled for post-collapse coverage but intentionally
          # NOT seeded yet (#1729 AC #12). Emit a non-actionable notice — never
          # the generic re-seed remedy, which can never clear here and would push
          # a live executing ingress into every new repo ahead of the pilot.
          printf '::notice file=%s::Template reference %s is expected but intentionally NOT seeded into %s yet (ADR-0007 / #1729) — seed-repo-template.sh deliberately never emits it until the pilot repo collapse lands. This is NOT actionable: do not hand-seed it to silence this. It will be seeded in the same change that retires the per-role stubs it replaces. See AGENTS.md -> Template drift guard.\n' \
            "$file" "$file" "$TEMPLATE_REPO"
        else
          printf '::warning file=%s::Template stub %s is MISSING from %s (expected blob %s) — re-seed via scripts/seed-repo-template.sh.\n' \
            "$file" "$file" "$TEMPLATE_REPO" "${expected:0:12}"
        fi
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

# _template_drift_emit <emit_flag> <emit_arg> <standards_ref> — the standards-
# derived content seed-repo-template.sh ships for this file, fetched PINNED at
# <standards_ref> (#1448 AC #7). The ref is passed as STANDARDS_REF on the child
# process env so both the N and N-1 passes read the same corpus at a fixed ref
# rather than the live default branch. Empty output → return 1 (seed emit failed
# / file absent). Captures via $(...)+printf '%s' so trailing newlines are stripped
# exactly the way the seed script / committed-SHA path strip them (blob parity).
_template_drift_emit() {
  local content
  content="$(DRY_RUN=false STANDARDS_REF="${3:-}" bash "${TEMPLATE_DRIFT_DIR}/seed-repo-template.sh" "$1" "$2" 2>/dev/null)" || return 1
  [ -n "$content" ] || return 1
  printf '%s' "$content"
}

# _template_drift_committed_sha <path> — git blob SHA of the file as committed in
# the template repo, RE-HASHED from its decoded content through the same trailing-
# newline-stripping path as _template_drift_expected_sha (command substitution +
# printf '%s'). The raw contents-API `.sha` is the blob SHA of the exact committed
# bytes, so a file that is byte-identical to the seed emission EXCEPT for a trailing
# newline (e.g. one edited via the GitHub web editor, which appends one) would hash
# differently and false-positive as DRIFTED — even though the expected side strips
# that newline. Normalizing both sides the same way makes the comparison symmetric:
# a trailing-newline-only difference is not drift, but any genuine content change
# still yields a different SHA. Empty on 404 (file absent ⇒ MISSING): an error body
# has no .content, so decoding yields "".
# Note: gh api with --jq does not apply the jq filter on error responses in some
# gh versions — it writes the raw 404 JSON to stdout instead. Separating the gh
# call from jq processing ensures the 404 body is filtered via .content // empty,
# returning "" so classify_stub_drift produces MISSING rather than DRIFTED.
_template_drift_committed_sha() {
  local out content
  out="$(gh api "repos/${TEMPLATE_REPO}/contents/${1}" 2>/dev/null)" || true
  content="$(printf '%s' "$out" | jq -r '.content // empty' 2>/dev/null | base64 -d 2>/dev/null)" || true
  [ -n "$content" ] || return 0
  printf '%s' "$content" | git hash-object --stdin
}

main() {
  local cmd
  for cmd in gh git; do
    command -v "$cmd" > /dev/null 2>&1 || { echo "::error::${cmd} is required but not installed." >&2; return 1; }
  done

  # Resolve N — the ref the current published baseline is derived at (#1448 AC #7).
  # STANDARDS_PREV_REF, when set, is N-1: the immediately-preceding published
  # version, also accepted while a promotion propagates (AC #8). It defaults empty
  # because the corpus-level publication scheme (step 1) is not yet available — in
  # that state seed-repo-template.sh resolves N to the HEAD commit SHA and there is
  # no N-1, so the check degrades to single-ref matching but stays explainable.
  local n_ref n_sha n_src prev_ref
  IFS=$'\t' read -r n_ref n_sha n_src < <(bash "${TEMPLATE_DRIFT_DIR}/seed-repo-template.sh" --print-ref 2>/dev/null || true)
  prev_ref="${STANDARDS_PREV_REF:-}"

  echo "Template stub drift check — ${TEMPLATE_REPO} vs standards-derived baseline:"
  echo "Resolved standards ref source: ${n_src:-<unresolved>} (#1448 AC #7/#10)."
  template_drift_report_header "${n_ref:-<unresolved>}" "${n_sha:-}" "$prev_ref"

  local tsv row path flag arg content_n content_n1 expected_n expected_n1 committed guard_rc=0
  tsv="$(mktemp)"
  for row in "${TEMPLATE_DRIFT_FILES[@]}"; do
    IFS='|' read -r path flag arg <<< "$row"
    template_drift_allowlisted "$path" && continue

    if ! content_n="$(_template_drift_emit "$flag" "$arg" "$n_ref")"; then
      echo "::warning::Could not compute the standards-derived content for ${path} at N (${n_ref:-<unresolved>}) — skipping its drift check."
      continue
    fi
    # AC #9: neither N nor N-1 may reintroduce a pre-#1184 legacy channel pin.
    template_drift_assert_major_scoped "$content_n" || guard_rc=1
    expected_n="$(printf '%s' "$content_n" | git hash-object --stdin)"

    expected_n1=""
    if [ -n "$prev_ref" ]; then
      if content_n1="$(_template_drift_emit "$flag" "$arg" "$prev_ref")"; then
        template_drift_assert_major_scoped "$content_n1" || guard_rc=1
        expected_n1="$(printf '%s' "$content_n1" | git hash-object --stdin)"
      else
        echo "::warning::Could not compute the N-1 baseline for ${path} at ${prev_ref} — comparing against N only."
      fi
    fi

    committed="$(_template_drift_committed_sha "$path")"
    template_drift_row5 "$path" "$committed" "$expected_n" "$expected_n1" >> "$tsv"
  done

  cat "$tsv"
  local rc=0
  template_drift_annotate "$tsv" || rc=$?
  [ "$guard_rc" -eq 0 ] || { echo "::error::a resolved standards baseline (N or N-1) carries a legacy non-major-scoped reusable pin — see annotations above (#1448 AC #9)."; rc=1; }
  rm -f "$tsv"
  return "$rc"
}

# Source-guard: tests source this to exercise the pure helpers; CI executes it.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
