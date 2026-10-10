#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/fleet_stub_drift.sh
# Pull in the pure per-job extraction/patch helpers (extract_job_block,
# job_block_sha, patch_job_block) so role-scoped remediation can read-modify-write
# a single agent-ingress.yml job block (#1726). Guarded so a missing sibling in an
# unusual layout does not hard-fail sourcing (the whole-file path still works).
if ! declare -F patch_job_block > /dev/null 2>&1; then
  _fsr_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  [ -f "${_fsr_dir}/fleet_stub_drift.sh" ] && source "${_fsr_dir}/fleet_stub_drift.sh"
fi
# fleet_stub_remediate.sh — pure remediation-plan builder for the Actions Fleet
# Monitor stub-drift remediation (#1149, epic #1148). Sourced (not executed) so
# bats can exercise the pure helpers, mirroring fleet_stub_drift.sh.
#
# The Fleet Monitor emits the DRIFTED enrolled-repo set as fleet_stub_drift.json
# (see stub_drift_alert_json / fleet_monitor.sh): an array of objects
#   { repo, status, repo_sha, canonical_sha, stub, stub_file }
# where `stub` is the stub label and `stub_file` is the per-repo thin-caller
# path. This module derives a network-free remediation PLAN from that set: for
# each DRIFTED entry it names the consumer repo, the stub, the per-repo
# stub_file, and the canonical source of record (CANONICAL_STUB_REPO + the
# stub's canonical_path from STUB_REGISTRY) — the exact bytes the detector
# compared against. The two tracked fleet stubs are deployed VERBATIM from that
# canonical path, so the canonical bytes ARE the remediation content (they must
# NOT be routed through seed-repo-template.sh --emit-workflow, whose manifest is
# the repo-template baseline set and which repins caller refs).
#
# ALIGNED and MISSING entries are excluded (only DRIFTED is remediable), and a
# never-overwrite REMEDIATION_ALLOWLIST drops intentionally-customized files so
# the remediation step can never overwrite them — mirroring template_stub_drift.sh's
# TEMPLATE_DRIFT_ALLOWLIST + its recorded-rationale rule.
#
# The plan-building helpers here are PURE (no network): they take a JSON file /
# SHAs and write to stdout. The Phase-2 network driver (#1150) is co-located
# below the pure section — reading canonical bytes and opening PRs — reached only
# from main() on a direct run, mirroring how seed-repo-template.sh co-locates
# pure helpers with a network main().
#
# Remediation plan format — a JSON array of objects:
#   { repo, stub, stub_file, canonical_repo, canonical_path, role }
# `role` is "" for a whole-file stub (overwrite verbatim) and a job name for a
# collapsed agent-ingress.yml stub (patch only that job block, #1726).

# Canonical source of record for the tracked fleet stubs, mirroring
# fleet_monitor.sh (kept in lockstep with its STUB_REGISTRY). Kept here (rather
# than sourced from fleet_monitor.sh) because fleet_monitor.sh is the network
# driver — it executes on source and cannot be sourced purely. Each STUB_REGISTRY
# entry is TAB-separated:
#   name <TAB> label <TAB> stub_path <TAB> canonical_path <TAB> role <TAB> legacy_path <TAB> legacy_canonical_path
#     name           — slug used in log lines
#     label          — the `stub` value carried in fleet_stub_drift.json
#     stub_path      — the `stub_file` value carried in fleet_stub_drift.json
#     canonical_path — org-template path under $CANONICAL_STUB_REPO
#     role           — OPTIONAL job/role selector (#1726). Empty ⇒ stub_path is a
#                      standalone file remediated by overwriting it VERBATIM with
#                      the canonical bytes (the #822/#886 behavior). Non-empty ⇒
#                      stub_path is the collapsed agent-ingress.yml and remediation
#                      PATCHES only the `<role>` job block (read-modify-write) so
#                      sibling jobs are never touched and a deliberately-removed
#                      block is never resurrected.
#     legacy_path / legacy_canonical_path — OPTIONAL pre-collapse per-role paths,
#                      carried for parity with fleet_monitor.sh; unused by
#                      remediation (only DRIFTED entries — a present, differing
#                      block — are remediable; MISSING/legacy repos are not).
CANONICAL_STUB_REPO="${CANONICAL_STUB_REPO:-petry-projects/.github}"
STUB_REGISTRY=(
  $'initiative-planner\tInitiative-planner\t.github/workflows/initiative-planner.yml\tstandards/workflows/initiative-planner.yml\t\t\t'
  $'initiative-driver\tInitiative-driver\t.github/workflows/initiative-driver.yml\tstandards/workflows/initiative-driver.yml\t\t\t'
  # Collapsed agent-ingress.yml roles (#1729 AC11): one row per job in the
  # petry-projects/markets ingress. These entries register for future drift
  # coverage once the canonical standards/workflows/agent-ingress.yml is
  # published to petry-projects/.github (#1729 AC11). Until then, a canonical
  # 404 gracefully skips these rows with a warning, leaving them without
  # coverage. The monitor and remediation helpers handle this degradation
  # automatically (see the @test "fleet_monitor: a 404 canonical
  # agent-ingress skips every role row with a warning and stays green" in
  # tests/fleet_stub_registry.bats).
  # legacy_canonical_path is empty for pr-review and ci-failure-analyst because
  # petry-projects/.github publishes no standards/workflows/<role>.yml for them
  # (checked 2026-10-10), so a repo that has not collapsed classifies MISSING
  # for those two roles.
  $'dev-lead\tDev-lead\t.github/workflows/agent-ingress.yml\tstandards/workflows/agent-ingress.yml\tdev-lead\t.github/workflows/dev-lead.yml\tstandards/workflows/dev-lead.yml'
  $'pr-auto-review\tPr-auto-review\t.github/workflows/agent-ingress.yml\tstandards/workflows/agent-ingress.yml\tpr-auto-review\t.github/workflows/pr-auto-review.yml\tstandards/workflows/pr-auto-review.yml'
  $'pr-review\tPr-review\t.github/workflows/agent-ingress.yml\tstandards/workflows/agent-ingress.yml\tpr-review\t.github/workflows/pr-review.yml\t'
  $'pr-review-mention\tPr-review-mention\t.github/workflows/agent-ingress.yml\tstandards/workflows/agent-ingress.yml\tpr-review-mention\t.github/workflows/pr-review-mention.yml\tstandards/workflows/pr-review-mention.yml'
  $'ci-failure-analyst\tCi-failure-analyst\t.github/workflows/agent-ingress.yml\tstandards/workflows/agent-ingress.yml\tci-failure-analyst\t.github/workflows/ci-failure-analyst.yml\t'
)

# ── Never-overwrite allowlist (AC #3) ─────────────────────────────────────────
# Files that the remediation step must NEVER re-sync, because a consumer repo has
# intentionally customized them. An allowlisted entry never appears in the plan
# output, so the remediation can never touch it — mirroring template_stub_drift.sh's
# TEMPLATE_DRIFT_ALLOWLIST. Each entry is one of:
#   "owner/repo"                 — never remediate ANY tracked stub in that repo,
#   "owner/repo|stub_file"       — never remediate that one stub_file in that repo,
#   "owner/repo|stub_file|role"  — never remediate that one collapsed job block
#                                  (role-granular, #1726): a repo can deliberately
#                                  customize ONE agent-ingress.yml job while its
#                                  sibling jobs stay auto-remediated.
# Add an entry ONLY with a recorded rationale (the same recorded-rationale rule
# AGENTS.md applies to the template ci.yml exception): name the repo/file and why
# the customization is deliberate, so the never-overwrite decision stays auditable.
# It is intentionally empty until a first deliberate customization is recorded —
# by default every DRIFTED fleet stub is a verbatim deployment and IS remediable.
REMEDIATION_ALLOWLIST=()

# remediation_allowlisted <repo> <stub_file> [role] — return 0 if the repo
# (whole-repo entry), the specific repo+stub_file, or (when <role> is given) the
# repo+stub_file+role is on the never-overwrite allowlist. The role-granular form
# lets one collapsed job block be protected without exempting its siblings.
remediation_allowlisted() {
  local repo="${1:-}" stub_file="${2:-}" role="${3:-}" a
  for a in "${REMEDIATION_ALLOWLIST[@]}"; do
    if [ "$a" = "$repo" ] || [ "$a" = "${repo}|${stub_file}" ]; then
      return 0
    fi
    if [ -n "$role" ] && [ "$a" = "${repo}|${stub_file}|${role}" ]; then
      return 0
    fi
  done
  return 1
}

# resolve_canonical_path <stub_file> [role] — echo the canonical_path from
# STUB_REGISTRY for the registered stub whose per-repo stub_path equals <stub_file>
# AND whose role equals <role>. The role is part of the key because once several
# roles collapse into one agent-ingress.yml they SHARE a stub_file, so stub_file
# alone is ambiguous (#1726); an empty <role> matches the whole-file entries.
# Returns 1 (no output) for an unrecognized (stub_file, role) pair, so the plan
# builder can skip an entry it cannot map to a canonical source.
resolve_canonical_path() {
  local stub_file="${1:-}" want_role="${2:-}" entry stub_path canonical_path reg_role
  for entry in "${STUB_REGISTRY[@]}"; do
    # Fields 1-2 (name, label) are unused by the resolver — discard them.
    IFS=$'\t' read -r _ _ stub_path canonical_path reg_role _ _ <<< "$entry"
    if [ "$stub_path" = "$stub_file" ] && [ "$reg_role" = "$want_role" ]; then
      printf '%s\n' "$canonical_path"
      return 0
    fi
  done
  return 1
}

# build_remediation_plan <json_file> — PURE. Reads a fleet_stub_drift.json array
# and emits the remediation plan as a JSON array. For each DRIFTED entry
# (ALIGNED/MISSING excluded, AC #2) that is NOT allowlisted (AC #3) and whose
# stub_file resolves to a canonical source (AC #1), emits an object naming the
# consumer repo, the stub, the per-repo stub_file, and the canonical source
# (CANONICAL_STUB_REPO + canonical_path). An empty/absent file yields "[]".
build_remediation_plan() {
  local json="${1:-}"
  if [ -z "$json" ] || [ ! -s "$json" ]; then
    echo "[]"
    return 0
  fi

  # Fail loud on malformed input. If the driving jq below can't parse "$json",
  # the read loop sees nothing and the function would emit an empty plan with
  # exit 0 — silently reading as "nothing to remediate" and hiding real drift.
  if ! jq -e 'type == "array"' "$json" > /dev/null 2>&1; then
    echo "::error::fleet_stub_remediate: input is not a readable JSON array: $json" >&2
    return 1
  fi

  local tmp repo stub stub_file role canonical_path
  tmp="$(mktemp)"
  while IFS=$'\t' read -r repo stub stub_file role; do
    [ -n "$repo" ] || continue
    remediation_allowlisted "$repo" "$stub_file" "$role" && continue
    if ! canonical_path="$(resolve_canonical_path "$stub_file" "$role")"; then
      # Unrecognized (stub_file, role): intentionally skipped (only registered
      # stubs are remediable), but warn so a registry gap is auditable, not silent.
      echo "::warning::fleet_stub_remediate: no canonical source for stub_file '$stub_file'${role:+ role '$role'} in $repo — skipping" >&2
      continue
    fi
    jq -n \
      --arg repo "$repo" \
      --arg stub "$stub" \
      --arg stub_file "$stub_file" \
      --arg role "$role" \
      --arg canonical_repo "$CANONICAL_STUB_REPO" \
      --arg canonical_path "$canonical_path" \
      '{repo: $repo, stub: $stub, stub_file: $stub_file, role: $role,
        canonical_repo: $canonical_repo, canonical_path: $canonical_path}' \
      >> "$tmp"
  done < <(jq -r '
    .[]
    | select(.status == "DRIFTED")
    | [.repo, (.stub // ""), (.stub_file // ""), (.role // "")]
    | @tsv' "$json")

  # Guarantee temp cleanup regardless of the final jq's exit, and propagate its
  # status rather than swallowing it.
  local out status
  out="$(jq -s '.' "$tmp")"; status=$?
  rm -f "$tmp"
  [ "$status" -eq 0 ] || return "$status"
  printf '%s\n' "$out"
}

# ══════════════════════════════════════════════════════════════════════════════
# Network driver (Phase 2, #1150). Everything above is PURE; everything below
# performs network I/O and is only reached from main() on a direct run. The
# driver consumes the plan from build_remediation_plan, groups entries by repo,
# and — per repo — creates a branch, PUTs the canonical bytes, verifies
# byte-identity, and opens exactly one PR. It mirrors seed-repo-template.sh's
# cross-repo machinery (_is_dry, branch + contents PUT + a single gh pr create).
# ══════════════════════════════════════════════════════════════════════════════

# DRY_RUN defaults to true (#1150 AC #2): the first wiring is inert. A write only
# happens when DRY_RUN=false AND an explicit repo scope is supplied (AC #7).
DRY_RUN="${DRY_RUN:-true}"
# Explicit repo scope (AC #7): a space/comma-separated allowlist of consumer
# repos the driver may write to. Empty means "no scope" — live writes are refused
# (fail-closed); dry-run logs the whole plan regardless.
REMEDIATE_REPOS="${REMEDIATE_REPOS:-}"

# ── Phase 3 pilot-first rollout (#1151, epic #1148) ───────────────────────────
# Mirror the repo's pilot/canary-first discipline (AGENTS.md): dry-run by default
# → a single named pilot repo → human go/no-go → fleet-wide. These three additive
# controls bound the blast radius of live remediation and prove the loop works
# before it touches the whole fleet.
#
# Pilot scope (AC #1/#4): a space/comma-separated pilot allowlist — the ONLY
# consumer repos eligible for LIVE remediation. Live remediation REQUIRES a named
# pilot repo; with none set the driver stays fully dry-run (fail-closed). Every
# DRIFTED repo outside the pilot scope is logged 'would remediate (out of pilot
# scope)' and skipped without writes. Typically ONE repo (the per-run cap below
# is the count bound); modeled as an allowlist so the two controls stay orthogonal.
REMEDIATE_PILOT_REPO="${REMEDIATE_PILOT_REPO:-}"
# Per-run repo cap (AC #2): the maximum number of repos remediated LIVE in a single
# run. Repos beyond the cap are logged as deferred (never silently truncated) and
# picked up on a later run. Small default keeps the pilot blast radius bounded.
REMEDIATE_MAX_REPOS="${REMEDIATE_MAX_REPOS:-1}"
# Optional path for the emitted per-repo drift-closed verification summary (AC #3).
# When set, the run writes a JSON array [{repo, drift_closed}] artifact there in
# addition to logging the verdicts.
REMEDIATE_SUMMARY_FILE="${REMEDIATE_SUMMARY_FILE:-}"

_is_dry() { [ "$DRY_RUN" = "true" ]; }

# Pure-Bash list splitting (comma/space separated) — no `tr`/`grep`/subshells, so
# the per-repo _in_scope/_in_pilot checks in run_remediation's loop spawn no
# external processes.

# _scope_list — echo the normalized repo scope, one repo per line (may be empty).
_scope_list() {
  local r
  for r in ${REMEDIATE_REPOS//,/ }; do echo "$r"; done
}

# _in_scope <repo> — 0 if <repo> is within scope. An empty scope means every repo
# in the plan is in scope (used by dry-run, which never writes).
_in_scope() {
  local repo="$1" r any=0
  for r in ${REMEDIATE_REPOS//,/ }; do
    any=1
    [ "$r" = "$repo" ] && return 0
  done
  [ "$any" -eq 0 ] && return 0   # empty scope = every repo in scope
  return 1
}

# _pilot_list — echo the normalized pilot allowlist, one repo per line (may be empty).
_pilot_list() {
  local p
  for p in ${REMEDIATE_PILOT_REPO//,/ }; do echo "$p"; done
}

# _in_pilot <repo> — 0 if <repo> is a named pilot repo. Unlike _in_scope, an EMPTY
# pilot list means NOTHING is eligible (fail-closed): live remediation requires an
# explicitly named pilot repo (AC #1/#4).
_in_pilot() {
  local repo="$1" p
  for p in ${REMEDIATE_PILOT_REPO//,/ }; do
    [ "$p" = "$repo" ] && return 0
  done
  return 1
}

# _emit_verification_summary <tsv> — surface the per-repo drift-closed verdicts
# (AC #3). <tsv> is newline-separated "repo<TAB>status" where status is one of:
#   verified — a PR was opened AND the pushed blob SHA was verified == canon
#              (drift_closed=true);
#   skipped  — a remediation PR was already open (idempotent), so nothing was
#              written or re-verified this run (drift_closed=false — NOT a
#              verified close, and NOT a failure);
#   failed   — remediation failed (e.g. byte-identity mismatch) (drift_closed=false).
# Always logs a summary block; when REMEDIATE_SUMMARY_FILE is set, also writes the
# verdicts as a JSON array artifact carrying BOTH the status and the drift_closed
# boolean (true only for `verified`).
_emit_verification_summary() {
  local tsv="$1" repo status
  echo "[remediate] Verification summary (drift-closed = pushed blob SHA == canon):"
  if [ ! -s "$tsv" ]; then
    echo "  [verify] (no live remediations this run)"
  else
    while IFS=$'\t' read -r repo status; do
      [ -n "$repo" ] || continue
      case "$status" in
        verified) echo "  [verify] ${repo}: drift-closed=yes" ;;
        skipped)  echo "  [verify] ${repo}: drift-closed=skipped (remediation PR already open — not re-verified this run)" ;;
        *)        echo "  [verify] ${repo}: drift-closed=no" ;;
      esac
    done < "$tsv"
  fi
  if [ -n "$REMEDIATE_SUMMARY_FILE" ]; then
    if [ -s "$tsv" ]; then
      jq -R -s 'split("\n") | map(select(length > 0) | split("\t"))
                | map({repo: (.[0] // "" | tostring),
                       status: (.[1] // "" | tostring),
                       drift_closed: (.[1] == "verified")})' "$tsv" \
        > "$REMEDIATE_SUMMARY_FILE"
    else
      echo "[]" > "$REMEDIATE_SUMMARY_FILE"
    fi
    echo "[remediate] wrote verification summary artifact: ${REMEDIATE_SUMMARY_FILE}"
  fi
}

# _canonical_bytes <canonical_repo> <canonical_path> — echo the raw bytes of the
# canonical stub (the source of record the SHA drift was measured against).
# Mirrors fleet_monitor.sh's canonical read: request the raw media type rather
# than decoding base64 locally, which avoids the macOS/BSD (`base64 -D`) vs Linux
# (`base64 -d`) portability split.
_canonical_bytes() {
  gh api -H "Accept: application/vnd.github.raw" "repos/${1}/contents/${2}" 2>/dev/null || true
}

# _canonical_sha <canonical_repo> <canonical_path> — echo the canonical git blob
# SHA (the byte-identity target for the post-PUT verify, AC #5).
_canonical_sha() {
  gh api "repos/${1}/contents/${2}" --jq '.sha' 2>/dev/null || true
}

# _blob_sha <repo> <path> <ref> — echo the git blob SHA of <path> on <ref>.
_blob_sha() {
  gh api "repos/${1}/contents/${2}?ref=${3}" --jq '.sha' 2>/dev/null || true
}

# _repo_bytes <repo> <path> <ref> — echo the raw bytes of <path> on <ref>. Used by
# role-scoped remediation to read the CURRENT agent-ingress.yml before patching a
# single job block into it (read-modify-write). Requests the raw media type rather
# than decoding base64 locally, avoiding the macOS/BSD (`base64 -D`) vs Linux
# (`base64 -d`) portability split.
_repo_bytes() {
  gh api -H "Accept: application/vnd.github.raw" "repos/${1}/contents/${2}?ref=${3}" 2>/dev/null || true
}

# _put_file <repo> <path> <content> <branch> <message> [expected_sha] — write
# <content> to <path> on <branch> via the contents PUT, passing the existing file
# SHA when overwriting. Mirrors seed-repo-template.sh's _put_file. When a sixth
# argument is supplied it is used as the PUT's `sha` VERBATIM (optimistic lock):
# the caller passes the blob SHA of the exact version it read, so a concurrent
# write between that read and this PUT is rejected by the API (409) instead of
# silently clobbered (#1726 race). Without it, the SHA is re-fetched here — the
# legacy whole-file behavior, where re-fetching is acceptable because the write is
# a verbatim canonical overwrite.
_put_file() {
  local repo="$1" path="$2" content="$3" branch="$4" msg="$5" sha encoded
  local -a sha_arg=()
  if [ "$#" -ge 6 ]; then
    sha="$6"
  else
    sha="$(_blob_sha "$repo" "$path" "$branch")"
  fi
  [ -n "$sha" ] && [ "$sha" != "null" ] && sha_arg=(--field "sha=${sha}")
  encoded="$(printf '%s' "$content" | base64 -w 0 2>/dev/null || printf '%s' "$content" | base64)"
  gh api "repos/${repo}/contents/${path}" --method PUT \
    --field "message=${msg}" --field "content=${encoded}" --field "branch=${branch}" \
    "${sha_arg[@]}" --silent 2>/dev/null \
    || { echo "::error::cannot write ${path} on ${repo}" >&2; return 1; }
  echo "  [remediate] wrote ${path}"
}

# _remediate_role_block <repo> <stub_file> <canonical_repo> <canonical_path> \
#                       <role> <branch> — remediate ONE collapsed job block in a
# consumer repo's agent-ingress.yml via read-modify-write (#1726 AC #3). Extracts
# the canonical <role> block, patches ONLY that block into the repo's current file
# (siblings untouched), PUTs the modified whole file, and verifies the pushed
# block's SHA == canon. A deliberately-removed block is NEVER resurrected: when the
# repo file has no <role> block, patch_job_block refuses (exit 3) and we skip
# without writing. Returns 1 on a hard failure (unreadable canon/repo, patch error,
# or a post-push per-block verify mismatch) so the caller fails the repo.
_remediate_role_block() {
  local repo="$1" sf="$2" cr="$3" cp="$4" role="$5" branch="$6"
  local canon_bytes block_tmp canon_block_sha repo_bytes repo_read_sha patched patched_tmp written_block_sha rc

  canon_bytes="$(_canonical_bytes "$cr" "$cp")"
  if [ -z "$canon_bytes" ]; then
    echo "::error::could not fetch canonical agent-ingress ${cr}/${cp} for ${repo} — failing repo" >&2
    return 1
  fi
  block_tmp="$(mktemp)"
  printf '%s' "$canon_bytes" | extract_job_block "$role" > "$block_tmp"
  if [ ! -s "$block_tmp" ]; then
    rm -f "$block_tmp"
    echo "::error::canonical ${cr}/${cp} has no '${role}' job block — cannot remediate ${repo}:${sf}#${role}" >&2
    return 1
  fi
  canon_block_sha="$(printf '%s' "$canon_bytes" | job_block_sha "$role")"

  # Optimistic lock (#1726 race): capture the blob SHA of the version we base the
  # patch on BEFORE reading its bytes, then PUT conditioned on it. SHA-first
  # ordering fails closed — any concurrent write to agent-ingress.yml after this
  # point (during the read, patch, or PUT) makes the SHA stale, so the PUT is
  # rejected (409) rather than overwriting the concurrent change with stale
  # sibling-job content.
  repo_read_sha="$(_blob_sha "$repo" "$sf" "$branch")"
  repo_bytes="$(_repo_bytes "$repo" "$sf" "$branch")"
  if [ -z "$repo_bytes" ]; then
    rm -f "$block_tmp"
    echo "::error::could not read ${repo}:${sf} on ${branch} — cannot patch '${role}' block; failing repo" >&2
    return 1
  fi

  patched_tmp="$(mktemp)"
  if printf '%s' "$repo_bytes" | patch_job_block "$role" "$block_tmp" > "$patched_tmp"; then rc=0; else rc=$?; fi
  rm -f "$block_tmp"
  if [ "$rc" -eq 3 ]; then
    rm -f "$patched_tmp"
    echo "::warning::${repo}:${sf} has no '${role}' job block — refusing to recreate a removed stub (never resurrect); skipping" >&2
    return 0
  elif [ "$rc" -ne 0 ]; then
    rm -f "$patched_tmp"
    echo "::error::failed to patch '${role}' block in ${repo}:${sf}; failing repo" >&2
    return 1
  fi

  IFS= read -r -d '' patched < "$patched_tmp" || true
  rm -f "$patched_tmp"
  _put_file "$repo" "$sf" "$patched" "$branch" \
    "chore: remediate drifted ${role} job block in ${sf} from ${cr}/${cp}" \
    "$repo_read_sha" || return 1

  # Per-block verify (AC #3/#5): re-extract the role block from the PUSHED file and
  # confirm its SHA equals canon. A whole-file compare would wrongly fail here,
  # because sibling jobs (correctly) differ from the single-role canonical block.
  written_block_sha="$(_repo_bytes "$repo" "$sf" "$branch" | job_block_sha "$role")"
  if [ "$written_block_sha" != "$canon_block_sha" ]; then
    echo "::error::per-block verify failed on ${repo}:${sf}#${role} — wrote ${written_block_sha}, canonical ${canon_block_sha}; not opening a PR" >&2
    return 1
  fi
  echo "  [remediate] verified ${sf}#${role} block == canonical (${canon_block_sha})"
}

# _remediate_repo <repo> <entries_tsv> — remediate one consumer repo. <entries_tsv>
# is newline-separated "stub_file<TAB>canonical_repo<TAB>canonical_path<TAB>stub<TAB>role"
# lines (all of this repo's DRIFTED, non-allowlisted stubs). Creates one branch;
# for each entry either overwrites the whole file (role empty) or patches only the
# <role> job block (read-modify-write); verifies (whole-file or per-block) identity,
# and opens one PR.
_remediate_repo() {
  local repo="$1" entries="$2"
  local branch default_branch base_sha
  branch="fleet-stub-remediate/$(date -u +%Y-%m-%d)"

  local stub_files
  stub_files="$(printf '%s\n' "$entries" | cut -f1 | paste -sd' ' -)"
  echo "[remediate] target repo: ${repo} (stubs:${stub_files:+ }${stub_files})"

  if _is_dry; then
    local sf cr cp
    while IFS=$'\t' read -r sf cr cp _; do
      [ -n "$sf" ] || continue
      echo "[remediate] [dry-run] would fetch ${cr}/${cp} and write ${sf}"
    done <<< "$entries"
    echo "[remediate] [dry-run] would create branch ${branch} on ${repo}, PUT the above,"
    echo "       and open one PR against the default branch. No writes made."
    echo "[remediate] PASS (dry-run) — ${repo}"
    return 0
  fi

  # Idempotent skip (AC #3): an already-open remediation PR for this head means
  # the proposal exists — do not create a second branch/PR. Mirrors
  # seed-repo-template.sh's gh pr list --head check.
  local existing_pr
  existing_pr="$(gh pr list --repo "$repo" --head "$branch" --state open --json number --jq '(.[0]?.number // "" | tostring)' 2>/dev/null || true)"
  if [ -n "$existing_pr" ]; then
    echo "[remediate] PR #${existing_pr} already open for branch ${branch} on ${repo} — skipping (idempotent)"
    # Distinct code (not 0): a pre-existing PR is NOT a fresh verified remediation.
    # The caller records this as `skipped`, not `verified`, so the verification
    # summary never reports drift-closed=yes for a run that verified nothing.
    return 3
  fi

  default_branch="$(gh api "repos/${repo}" --jq '.default_branch' 2>/dev/null || echo main)"
  base_sha="$(gh api "repos/${repo}/git/ref/heads/${default_branch}" --jq '(.object?.sha // "" | tostring)' 2>/dev/null || true)"
  if [ -z "$base_sha" ]; then
    echo "::error::cannot read ${default_branch} head on ${repo}" >&2
    return 1
  fi
  # Create the branch, or reuse it if it already exists (AC #3: never re-create).
  gh api "repos/${repo}/git/refs" --method POST \
    --field "ref=refs/heads/${branch}" --field "sha=${base_sha}" --silent 2>/dev/null \
    || gh api "repos/${repo}/git/ref/heads/${branch}" --silent 2>/dev/null \
    || { echo "::error::cannot create branch ${branch} on ${repo}" >&2; return 1; }

  local sf cr cp stub role content canon_sha written_sha bytes_tmp
  while IFS=$'\t' read -r sf cr cp stub role; do
    [ -n "$sf" ] || continue
    if [ -n "$role" ]; then
      _remediate_role_block "$repo" "$sf" "$cr" "$cp" "$role" "$branch" || return 1
      continue
    fi
    # ── Whole-file overwrite (#822/#886) ─────────────────────────────────────
    bytes_tmp="$(mktemp)"
    _canonical_bytes "$cr" "$cp" > "$bytes_tmp" 2>/dev/null || true
    if [ ! -s "$bytes_tmp" ]; then
      rm -f "$bytes_tmp"
      echo "::error::could not fetch canonical bytes ${cr}/${cp} for ${repo} — failing repo" >&2
      return 1
    fi
    IFS= read -r -d '' content < "$bytes_tmp" || true
    rm -f "$bytes_tmp"
    canon_sha="$(_canonical_sha "$cr" "$cp")"
    if [ -z "$canon_sha" ]; then
      echo "::error::could not read canonical blob SHA ${cr}/${cp} for ${repo} — cannot verify byte-identity; failing repo" >&2
      return 1
    fi
    _put_file "$repo" "$sf" "$content" "$branch" "chore: remediate drifted stub ${sf} from ${cr}/${cp}" || return 1
    # Byte-identity verify (AC #5): the written blob SHA must equal the canonical
    # blob SHA. On mismatch, fail the repo BEFORE opening a misleading PR.
    written_sha="$(_blob_sha "$repo" "$sf" "$branch")"
    if [ "$written_sha" != "$canon_sha" ]; then
      echo "::error::byte-identity mismatch on ${repo}:${sf} — wrote ${written_sha}, canonical ${canon_sha}; not opening a PR" >&2
      return 1
    fi
    echo "  [remediate] verified ${sf} == canonical (${canon_sha})"
  done <<< "$entries"

  # One PR per repo (AC #1, #4): a proposal against the default branch citing the
  # canonical source and the drifted stubs — never a direct push to default.
  local title body
  title="chore: remediate drifted workflow stub(s) — ${repo}"
  body="$(printf 'Auto-remediates fleet stub drift by deploying the canonical bytes verbatim.\n\nCanonical source of record: %s\nStubs remediated:\n%s\n\nContent is byte-identical to canon (blob SHA verified); opened as a proposal by fleet_stub_remediate.sh (#1150).\n' \
    "$(printf '%s\n' "$entries" | awk -F'\t' 'NF{print "- "$2"/"$3}' | sort -u | paste -sd'; ' -)" \
    "$(printf '%s\n' "$entries" | awk -F'\t' 'NF{print "- "$1}')")"
  gh pr create --repo "$repo" --head "$branch" --base "$default_branch" \
    --title "$title" --body "$body" 2>/dev/null \
    || { echo "::error::cannot open PR on ${repo}" >&2; return 1; }
  echo "[remediate] PASS — ${repo} (1 PR opened against ${default_branch})"
}

# run_remediation <json> — build the plan, group by repo, apply the pilot-scope
# gate + per-run cap, remediate each eligible repo (one branch + one PR per repo),
# and surface the per-repo drift-closed verification summary.
run_remediation() {
  local json="$1" plan repo entries failed=0

  # Pilot-first fail-closed gate (AC #4): live remediation requires an explicitly
  # named pilot repo. With none, refuse to write — stay fully dry-run and warn.
  if ! _is_dry && [ -z "$(_pilot_list)" ]; then
    echo "::warning::fleet_stub_remediate: DRY_RUN=false but no pilot repo (REMEDIATE_PILOT_REPO/--pilot) — refusing live writes; staying dry-run (pilot-scope gate: live remediation requires an explicitly named pilot repo)."
    DRY_RUN=true
  fi

  plan="$(build_remediation_plan "$json")" || return 1
  if [ "$(printf '%s' "$plan" | jq 'length')" -eq 0 ]; then
    echo "[remediate] no remediable drift — nothing to do."
    return 0
  fi

  local max remediated=0 summary_tmp rc
  max="$REMEDIATE_MAX_REPOS"
  # Validate the per-run cap before the numeric `-ge` comparison below: an empty
  # or non-numeric value would make `[ "$remediated" -ge "$max" ]` error out and,
  # under set -e, abort the whole run with an opaque failure.
  case "$max" in
    ''|*[!0-9]*)
      echo "::error::fleet_stub_remediate: REMEDIATE_MAX_REPOS must be a non-negative integer, got '${max}'" >&2
      return 2 ;;
  esac
  summary_tmp="$(mktemp)" || { echo "::error::fleet_stub_remediate: mktemp failed" >&2; return 1; }

  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    if ! _in_scope "$repo"; then
      echo "[remediate] ${repo} not in scope — skipping"
      continue
    fi

    # Live-only gating (dry-run logs the whole plan intent below; it never writes).
    if ! _is_dry; then
      # Pilot-scope gate (AC #1): only a named pilot repo is remediated live; every
      # other DRIFTED repo is announced and skipped without writes.
      if ! _in_pilot "$repo"; then
        echo "[remediate] ${repo} would remediate (out of pilot scope) — skipping without writes"
        continue
      fi
      # Per-run cap (AC #2): defer (and log) repos beyond the ceiling — no silent
      # truncation; deferred repos are picked up on a later run.
      if [ "$remediated" -ge "$max" ]; then
        echo "[remediate] ${repo} deferred — per-run cap reached (REMEDIATE_MAX_REPOS=${max}); will be picked up on a later run"
        continue
      fi
      remediated=$((remediated + 1))
    fi

    entries="$(printf '%s' "$plan" | jq -r --arg r "$repo" \
      '.[] | select(.repo == $r) | [.stub_file, .canonical_repo, .canonical_path, .stub, (.role // "")] | @tsv')"
    # Capture the exact exit code without tripping set -e: 0 = opened+verified,
    # 3 = idempotent skip (PR already open, nothing verified), other = failed.
    if _remediate_repo "$repo" "$entries"; then rc=0; else rc=$?; fi
    if ! _is_dry; then
      case "$rc" in
        0) printf '%s\t%s\n' "$repo" "verified" >> "$summary_tmp" ;;
        3) printf '%s\t%s\n' "$repo" "skipped"  >> "$summary_tmp" ;;
        *) printf '%s\t%s\n' "$repo" "failed"   >> "$summary_tmp"; failed=1 ;;
      esac
    elif [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
      failed=1
    fi
  done < <(printf '%s' "$plan" | jq -r '[.[].repo] | unique | .[]')

  # Drift-closed verification (AC #3): surface per-repo verdicts for live runs.
  if ! _is_dry; then
    _emit_verification_summary "$summary_tmp"
  fi
  rm -f "$summary_tmp"

  return "$failed"
}

# ── CLI ───────────────────────────────────────────────────────────────────────
main() {
  local cmd
  for cmd in gh jq base64; do
    command -v "$cmd" > /dev/null 2>&1 || { echo "::error::${cmd} is required but not installed." >&2; return 1; }
  done

  local json="fleet_stub_drift.json"
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)     [ $# -ge 2 ] || { echo "::error::--repo needs a value" >&2; return 2; }
                  REMEDIATE_REPOS="${REMEDIATE_REPOS:+$REMEDIATE_REPOS }$2"; shift 2; continue ;;
      --repo=*)   REMEDIATE_REPOS="${REMEDIATE_REPOS:+$REMEDIATE_REPOS }${1#--repo=}"; shift; continue ;;
      --pilot)    [ $# -ge 2 ] || { echo "::error::--pilot needs a value" >&2; return 2; }
                  REMEDIATE_PILOT_REPO="${REMEDIATE_PILOT_REPO:+$REMEDIATE_PILOT_REPO }$2"; shift 2; continue ;;
      --pilot=*)  REMEDIATE_PILOT_REPO="${REMEDIATE_PILOT_REPO:+$REMEDIATE_PILOT_REPO }${1#--pilot=}"; shift; continue ;;
      --max-repos)   [ $# -ge 2 ] || { echo "::error::--max-repos needs a value" >&2; return 2; }
                  REMEDIATE_MAX_REPOS="$2"; shift 2; continue ;;
      --max-repos=*) REMEDIATE_MAX_REPOS="${1#--max-repos=}"; shift; continue ;;
      --dry-run)  DRY_RUN=true; shift; continue ;;
      -h|--help)  sed -n '2,31p' "$0"; return 0 ;;
      --*)        echo "::error::unknown argument: $1" >&2; return 2 ;;
      *)          json="$1"; shift; continue ;;
    esac
  done

  run_remediation "$json"
}

# Source-guard: tests source this to exercise the pure helpers; a direct run
# drives the network remediation from a local fleet_stub_drift.json.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
