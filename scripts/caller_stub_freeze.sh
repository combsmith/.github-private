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
# Drift TSV format: fleet_stub_drift.sh's 4 fields plus a 5th job column added
# here so a multi-job agent-ingress.yml (ADR-0007) yields one row per collapsed
# role (#1725):
#   1:file  2:status  3:current_sha  4:baseline_sha  5:job

CALLER_FREEZE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CALLER_FREEZE_ROOT="${CALLER_FREEZE_ROOT:-$(cd "${CALLER_FREEZE_DIR}/.." && pwd)}"
CALLER_FREEZE_FIXTURE_DIR="${CALLER_FREEZE_ROOT}/tests/fixtures/caller-stub-freeze"

# shellcheck source=scripts/fleet_stub_drift.sh
source "${CALLER_FREEZE_DIR}/fleet_stub_drift.sh"

# ── Covered-stub manifest ─────────────────────────────────────────────────────
# Each row: "stub_path|job|baseline_name" — the ring-0 / self-host caller stubs
# whose reusable lives in petry-projects/.github-private and is pinned to a canary
# channel tag (docs/initiatives/agentic-release-strategy.md §5). These are the
# stubs Part A can least afford to get wrong (a broken forwarding change here
# breaks the source repo's own automation post-merge), so they are frozen.
#
# The manifest is per-role/per-JOB (#1725): the middle field names the job whose
# forwarding block is frozen. Today these are three single-job per-role stubs; on
# the collapse (epic #1723) each collapsed role becomes a job row against the one
# agent-ingress.yml — the same job-scoped extractor covers both shapes, so this
# guard lands BEFORE the collapse without breaking current CI.
readonly -a CALLER_FREEZE_STUBS=(
  ".github/workflows/dev-lead.yml|dev-lead|dev-lead.block"
  ".github/workflows/pr-review-trigger.yml|review|pr-review-trigger.block"
  ".github/workflows/ci-failure-analyst.lock.yml|analyze|ci-failure-analyst.block"
)

# caller_freeze_covered — print the covered stub paths, one per line. Pure.
caller_freeze_covered() {
  local row
  for row in "${CALLER_FREEZE_STUBS[@]}"; do
    printf '%s\n' "${row%%|*}"
  done
}

# extract_forwarding_block <stub_file> <job> — emit the frozen region of a caller
# stub for a NAMED job (#1725, job-scoped): the top-level `on:` trigger block,
# followed by that job's channel-pinned `uses:` line, its `with:` forwarding
# block, and its `permissions:` block. `if:`, `secrets:`, `name:`, and job-body
# comments before the first captured child are excluded. Pure: reads the file,
# writes stdout.
#
# WHY job-scoped: the pre-#1725 extractor assumed ONE top-level `on:` and the
# FIRST job-indented `uses:` — it collapses on a multi-job agent-ingress.yml (one
# shared `on:`, many `uses:`), forwarding the wrong job's block. Selecting by job
# name lets one guard freeze both a single-job per-role stub and one job of the
# collapsed ingress, so the guard survives the collapse (epic #1723).
#
# WHY permissions is now frozen: in the ingress each job re-grants its own
# least-privilege `permissions:` (a reusable can be granted no more than its
# calling job). A silent permission escalation on a channel-pinned job is exactly
# the invisible-to-PR-CI change (#1034 class) this backstop exists to catch.
#
# Boundaries (deterministic, byte-identity friendly):
#   - `on:` block: the top-level trigger key (`on:`, or its YAML-quoted spellings
#     `"on":`/`'on':`) plus every following indented line, blank line,
#     or column-0 comment; it ends at the next non-blank, non-comment, column-0
#     line (the next top-level YAML key). Blanks and column-0 comments are kept so
#     a new trigger cannot hide after a blank line or comment (#1268).
#   - job block: within `jobs:`, the named job's `uses:`/`with:`/`permissions:`
#     direct children and their nested lines, in document order, until the next
#     job key (or a dedent to the job-key indent) ends it. Trailing blank lines
#     are dropped; blanks/comments interior to a captured sub-block are kept.
extract_forwarding_block() {
  local file="${1:-}" job="${2:-}"
  [ -n "$file" ] && [ -f "$file" ] || return 0

  # No job name ⇒ empty extraction ⇒ MISSING (a hard failure for ring-0 roles).
  [ -n "$job" ] || return 0

  # 1) Buffer the NAMED job's uses:/with:/permissions: block FIRST. When the job
  #    name is supplied but absent from the file, this awk emits nothing — and we
  #    then emit NOTHING at all (below), so an unknown/deleted job yields an EMPTY
  #    extraction (⇒ classify_stub_drift = MISSING, the hard error ring-0 roles
  #    require). Emitting the shared `on:` block up-front (as the pre-#1772 order
  #    did) would make an absent job hash a non-empty on:-only block, which
  #    `caller_freeze_update` could freeze and `classify_stub_drift` then report
  #    ALIGNED — a ring-0 guard passing while checking nothing (#1772).
  local job_block
  job_block="$(awk -v jobre="$job" '
    function indent_of(line) { match(line, /^[[:space:]]*/); return RLENGTH }
    BEGIN { found_jobs=0; in_job=0; job_key_indent=-1; child_indent=-1; keep=0; pending=0 }
    !found_jobs {
      if ($0 ~ /^jobs:[[:space:]]*(#.*)?$/) found_jobs=1
      next
    }
    found_jobs && !in_job {
      if ($0 ~ /^[[:space:]]*$/) next
      ind=indent_of($0); body=substr($0, ind+1)
      if (ind > 0 && body ~ ("^" jobre ":[[:space:]]*(#.*)?$")) {
        in_job=1; job_key_indent=ind; child_indent=-1; keep=0; pending=0
      }
      next
    }
    in_job {
      if ($0 ~ /^[[:space:]]*$/) { if (keep) pending++; next }
      ind=indent_of($0); body=substr($0, ind+1)
      if (ind <= job_key_indent) { in_job=0; found_jobs=0; next }   # left the job
      if (body ~ /^#/) { if (keep) { while (pending>0) { print ""; pending-- } print } next }
      if (child_indent < 0) child_indent=ind
      if (ind == child_indent) {
        key=body; sub(/:.*/, "", key)
        keep = (key=="uses" || key=="with" || key=="permissions") ? 1 : 0
      }
      if (keep) { while (pending>0) { print ""; pending-- } print }
      next
    }
  ' "$file")"

  # An absent job ⇒ empty job block ⇒ emit nothing (MISSING); the shared `on:`
  # block is never emitted on its own.
  [ -n "$job_block" ] || return 0

  # 2) The shared top-level `on:` trigger block, then the buffered job block.
  awk '
    /^("on"|'\''on'\''|on):/ { insec="on"; print; next }
    insec=="on" {
      if (/^[[:space:]]/ || /^$/ || /^#/) { print; next }
      insec=""
    }
  ' "$file"
  printf '%s\n' "$job_block"
}

# caller_freeze_current_sha <stub_file> — git blob SHA of the forwarding block
# extracted from the live stub. Empty if the stub is absent or has no block
# (⇒ classify_stub_drift yields MISSING). Pure (git hash-object is local).
caller_freeze_current_sha() {
  local file="${1:-}" job="${2:-}" block
  block="$(extract_forwarding_block "$file" "$job")"
  [ -n "$block" ] || return 0
  extract_forwarding_block "$file" "$job" | git hash-object --stdin
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
  local f="${1:-}" file status current baseline job drifted=0
  [ -n "$f" ] && [ -f "$f" ] || return 0
  while IFS=$'\t' read -r file status current baseline job; do
    [ -n "$file" ] || continue
    case "$status" in
      DRIFTED)
        drifted=1
        printf '::error file=%s::Caller stub %s job '"'"'%s'"'"' forwarding block has DRIFTED from its frozen baseline (current block %s != baseline %s). A channel-pinned self-host stub change is invisible to PR CI and only breaks post-merge (#1034). If this change is intentional, regenerate the baseline: bash scripts/caller_stub_freeze.sh --update, and commit tests/fixtures/caller-stub-freeze/*.block\n' \
          "$file" "$file" "$job" "${current:0:12}" "${baseline:0:12}"
        ;;
      MISSING)
        drifted=1
        printf '::error file=%s::Caller stub %s job '"'"'%s'"'"' has no extractable forwarding block or its baseline is absent (current %s, baseline %s). For ring-0 stubs, MISSING means the guard cannot protect this stub — regenerate via bash scripts/caller_stub_freeze.sh --update, and commit tests/fixtures/caller-stub-freeze/*.block\n' \
          "$file" "$file" "$job" "${current:0:12}" "${baseline:0:12}"
        ;;
    esac
  done < "$f"
  [ "$drifted" -eq 0 ]
}

# caller_freeze_build_tsv — classify every covered stub against its committed
# baseline and print the drift TSV to stdout. Pure (all local).
caller_freeze_build_tsv() {
  local row path job baseline stub_abs base_abs cur base
  for row in "${CALLER_FREEZE_STUBS[@]}"; do
    IFS='|' read -r path job baseline <<< "$row"
    stub_abs="${CALLER_FREEZE_ROOT}/${path}"
    base_abs="${CALLER_FREEZE_FIXTURE_DIR}/${baseline}"
    cur="$(caller_freeze_current_sha "$stub_abs" "$job")"
    base="$(caller_freeze_baseline_sha "$base_abs")"
    printf '%s\t%s\n' "$(stub_drift_row "$path" "$base" "$cur")" "$job"
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
  local row path job baseline stub_abs base_abs block
  mkdir -p "$CALLER_FREEZE_FIXTURE_DIR"
  for row in "${CALLER_FREEZE_STUBS[@]}"; do
    IFS='|' read -r path job baseline <<< "$row"
    stub_abs="${CALLER_FREEZE_ROOT}/${path}"
    base_abs="${CALLER_FREEZE_FIXTURE_DIR}/${baseline}"
    if [ ! -f "$stub_abs" ]; then
      echo "::warning::caller stub ${path} not found — skipping baseline update." >&2
      continue
    fi
    block="$(extract_forwarding_block "$stub_abs" "$job")"
    if [ -z "$block" ]; then
      echo "::warning::caller stub ${path} job '${job}' has no extractable forwarding block — skipping baseline update (refusing to freeze an empty block, which would classify ALIGNED for an absent job)." >&2
      continue
    fi
    printf '%s\n' "$block" > "$base_abs"
    echo "updated ${baseline} from ${path} (job ${job})"
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
