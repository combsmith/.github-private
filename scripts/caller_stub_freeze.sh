#!/usr/bin/env bash
set -euo pipefail
# caller_stub_freeze.sh — stub-freeze drift guard for the ring-0 / self-host
# caller stubs (#1255, epic #1052 Part B). Backstops the #1253
# validate-caller-inputs check for the specific self-host caller stubs whose
# reusable is hosted in THIS repo and pinned to a canary channel tag.
#
# WHY (channel skew, #1034): `pull_request` CI runs the BASE-branch caller stub,
# and GitHub validates a reusable's inputs only at startup against the PINNED
# ref — so a trigger/input-forwarding change to a channel-pinned caller stub is
# exercised by nothing in PR CI and only breaks post-merge. Part A (#1253)
# resolves same-repo channel tags and validates inputs ⊆ declared inputs. This
# part adds a stronger, byte-identity BACKSTOP for the self-host stubs: each
# stub's trigger (`on:`) + `uses:`/`with:` forwarding block must stay
# byte-identical to a committed baseline (tests/fixtures/caller-stub-freeze/
# *.block). Any edit to a frozen block fails CI unless the baseline is
# intentionally regenerated in the same reviewed diff (an explicit channel
# change), converting a silent post-merge break into a deliberate decision.
#
# It REUSES the byte-identity drift model from fleet_stub_drift.sh:
#   classify_stub_drift <baseline_sha> <current_sha> -> ALIGNED|DRIFTED|MISSING
#   stub_drift_row <file> <baseline_sha> <current_sha>
# The "baseline" SHA is the git blob SHA of the committed .block fixture; the
# "current" SHA is the git blob SHA of the block extracted from the live stub.
# Equal blob SHAs ⇒ byte-identical forwarding blocks ⇒ the stub is still frozen.
#
# All functions here are PURE (no network): they read in-repo files / SHAs and
# write to stdout, exactly like fleet_stub_drift.sh / template_stub_drift.sh.
#
# Drift TSV format (4 fields, tab-separated), shared with fleet_stub_drift.sh:
#   1:file  2:status  3:current_sha  4:baseline_sha

CALLER_FREEZE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CALLER_FREEZE_ROOT="${CALLER_FREEZE_ROOT:-$(cd "${CALLER_FREEZE_DIR}/.." && pwd)}"
CALLER_FREEZE_FIXTURE_DIR="${CALLER_FREEZE_ROOT}/tests/fixtures/caller-stub-freeze"

# shellcheck source=scripts/fleet_stub_drift.sh
source "${CALLER_FREEZE_DIR}/fleet_stub_drift.sh"

# ── Covered-stub manifest ─────────────────────────────────────────────────────
# Each row: "stub_path|baseline_name" — the ring-0 / self-host caller stubs whose
# reusable lives in combsmith/.github-private and is pinned to a canary
# channel tag (docs/initiatives/agentic-release-strategy.md §5). These are the
# stubs Part A can least afford to get wrong (a broken forwarding change here
# breaks the source repo's own automation post-merge), so they are frozen.
readonly -a CALLER_FREEZE_STUBS=(
  ".github/workflows/dev-lead.yml|dev-lead.block"
  ".github/workflows/pr-review-trigger.yml|pr-review-trigger.block"
  ".github/workflows/ci-failure-analyst.lock.yml|ci-failure-analyst.block"
)

# caller_freeze_covered — print the covered stub paths, one per line. Pure.
caller_freeze_covered() {
  local row
  for row in "${CALLER_FREEZE_STUBS[@]}"; do
    printf '%s\n' "${row%%|*}"
  done
}

# extract_forwarding_block <stub_file> — emit the frozen region of a caller stub:
# the top-level `on:` trigger block, followed by the job's channel-pinned `uses:`
# line and its `with:` forwarding block. Nothing else (permissions/secrets blocks
# and their header comments are excluded). Pure: reads the file, writes stdout.
#
# Boundaries (deterministic, byte-identity friendly):
#   - `on:` block: the `on:` line plus every following indented line, blank
#     line, or column-0 comment; it ends at the next non-blank, non-comment,
#     column-0 line (i.e. the next top-level YAML key). Blank lines and
#     column-0 comments are included so an attacker cannot hide new triggers
#     after a blank line or comment within the `on:` mapping.
#   - forwarding block: the first job-indented `uses:` line plus every following
#     line, until a job-indented `secrets:` or `permissions:` key ends it.
extract_forwarding_block() {
  local file="${1:-}"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  awk '
    /^on:/ { insec="on"; print; next }
    insec=="on" {
      if (/^[[:space:]]/ || /^$/ || /^#/) { print; next }
      insec=""
    }
    insec=="" && /^[[:space:]]+uses:[[:space:]]/ { insec="fwd"; print; next }
    insec=="fwd" {
      if (/^[[:space:]]+(secrets|permissions):/) { insec="done"; next }
      print; next
    }
  ' "$file"
}

# caller_freeze_current_sha <stub_file> — git blob SHA of the forwarding block
# extracted from the live stub. Empty if the stub is absent or has no block
# (⇒ classify_stub_drift yields MISSING). Pure (git hash-object is local).
caller_freeze_current_sha() {
  local file="${1:-}" block
  block="$(extract_forwarding_block "$file")"
  [ -n "$block" ] || return 0
  extract_forwarding_block "$file" | git hash-object --stdin
}

# caller_freeze_baseline_sha <baseline_file> — git blob SHA of the committed
# baseline .block file. Empty if the baseline is absent. Pure.
caller_freeze_baseline_sha() {
  local file="${1:-}"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  git hash-object "$file"
}

# caller_freeze_annotate <tsv_file> — emit a GitHub `::error::` annotation for
# every DRIFTED or MISSING stub, naming the file and BOTH SHAs. Returns 1 if
# any row is DRIFTED or MISSING (so the CI job fails), 0 otherwise. For ring-0
# stubs, MISSING (stub absent or extraction empty) is a hard failure — it means
# the guard is broken and cannot protect the stub. Pure: reads the TSV, writes
# stdout. An absent/empty file is a clean pass.
caller_freeze_annotate() {
  local f="${1:-}" file status current baseline drifted=0
  [ -n "$f" ] && [ -f "$f" ] || return 0
  while IFS=$'\t' read -r file status current baseline; do
    [ -n "$file" ] || continue
    case "$status" in
      DRIFTED)
        drifted=1
        printf '::error file=%s::Caller stub %s forwarding block has DRIFTED from its frozen baseline (current block %s != baseline %s). A channel-pinned self-host stub change is invisible to PR CI and only breaks post-merge (#1034). If this change is intentional, regenerate the baseline: bash scripts/caller_stub_freeze.sh --update, and commit tests/fixtures/caller-stub-freeze/*.block\n' \
          "$file" "$file" "${current:0:12}" "${baseline:0:12}"
        ;;
      MISSING)
        drifted=1
        printf '::error file=%s::Caller stub %s has no extractable forwarding block or its baseline is absent (current %s, baseline %s). For ring-0 stubs, MISSING means the guard cannot protect this stub — regenerate via bash scripts/caller_stub_freeze.sh --update, and commit tests/fixtures/caller-stub-freeze/*.block\n' \
          "$file" "$file" "${current:0:12}" "${baseline:0:12}"
        ;;
    esac
  done < "$f"
  [ "$drifted" -eq 0 ]
}

# caller_freeze_build_tsv — classify every covered stub against its committed
# baseline and print the drift TSV to stdout. Pure (all local).
caller_freeze_build_tsv() {
  local row path baseline stub_abs base_abs cur base
  for row in "${CALLER_FREEZE_STUBS[@]}"; do
    IFS='|' read -r path baseline <<< "$row"
    stub_abs="${CALLER_FREEZE_ROOT}/${path}"
    base_abs="${CALLER_FREEZE_FIXTURE_DIR}/${baseline}"
    cur="$(caller_freeze_current_sha "$stub_abs")"
    base="$(caller_freeze_baseline_sha "$base_abs")"
    stub_drift_row "$path" "$base" "$cur"
  done
}

# caller_freeze_check — build the drift table, print it, annotate, and return
# non-zero on any DRIFTED stub. This is the check-mode entrypoint.
caller_freeze_check() {
  local tsv rc=0
  tsv="$(mktemp)"
  caller_freeze_build_tsv > "$tsv"
  echo "Ring-0 caller-stub freeze check — forwarding blocks vs committed baselines:"
  cat "$tsv"
  caller_freeze_annotate "$tsv" || rc=$?
  rm -f "$tsv"
  return "$rc"
}

# caller_freeze_update — regenerate every baseline from the live stubs. This is
# how an intentional, reviewed channel change is recorded: the diff to
# tests/fixtures/caller-stub-freeze/*.block is what a reviewer signs off on.
caller_freeze_update() {
  local row path baseline stub_abs base_abs
  mkdir -p "$CALLER_FREEZE_FIXTURE_DIR"
  for row in "${CALLER_FREEZE_STUBS[@]}"; do
    IFS='|' read -r path baseline <<< "$row"
    stub_abs="${CALLER_FREEZE_ROOT}/${path}"
    base_abs="${CALLER_FREEZE_FIXTURE_DIR}/${baseline}"
    if [ ! -f "$stub_abs" ]; then
      echo "::warning::caller stub ${path} not found — skipping baseline update." >&2
      continue
    fi
    extract_forwarding_block "$stub_abs" > "$base_abs"
    echo "updated ${baseline} from ${path}"
  done
}

main() {
  command -v git > /dev/null 2>&1 || { echo "::error::git is required but not installed." >&2; return 1; }
  case "${1:-}" in
    --update) caller_freeze_update ;;
    ""|--check) caller_freeze_check ;;
    *) echo "usage: caller_stub_freeze.sh [--check|--update]" >&2; return 2 ;;
  esac
}

# Source-guard: tests source this to exercise the pure helpers; CI executes it.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
