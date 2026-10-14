#!/usr/bin/env bats
# Tests for scripts/fleet_stub_remediate.sh — the pure remediation-plan builder
# for the Actions Fleet Monitor stub-drift remediation (#1149, epic #1148).
#
# The module derives a network-free remediation plan from the DRIFTED set emitted
# as fleet_stub_drift.json: for each DRIFTED entry {repo, status, repo_sha,
# canonical_sha, stub, stub_file}, it names the consumer repo, the stub, the
# per-repo stub_file path, and the canonical source (CANONICAL_STUB_REPO +
# the stub's canonical_path from STUB_REGISTRY) — excluding ALIGNED/MISSING
# entries and a never-overwrite REMEDIATION_ALLOWLIST.
#
# All assertions here are PURE (no network): they exercise the plan builder,
# the canonical-source resolver, and the allowlist predicate over synthetic
# fleet_stub_drift.json fixtures. Run:
#   bats tests/fleet_stub_remediate.bats

PLANNER_STUB=".github/workflows/initiative-planner.yml"
DRIVER_STUB=".github/workflows/initiative-driver.yml"

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/fleet_stub_remediate.sh"

setup() {
  # shellcheck source=scripts/fleet_stub_remediate.sh
  source "${BATS_TEST_DIRNAME}/../scripts/fleet_stub_remediate.sh"

  # A fleet_stub_drift.json fixture mixing DRIFTED (remediable), ALIGNED, and
  # MISSING entries across both tracked stubs. Only the DRIFTED rows are
  # remediable (AC #2); ALIGNED/MISSING must never reach the plan.
  DRIFT_JSON="$(mktemp)"
  cat > "$DRIFT_JSON" <<JSON
[
  { "repo": "petry-projects/bravo", "status": "DRIFTED", "repo_sha": "bbbb", "canonical_sha": "aaaa", "stub": "Initiative-planner", "stub_file": "${PLANNER_STUB}" },
  { "repo": "petry-projects/alpha", "status": "ALIGNED", "repo_sha": "aaaa", "canonical_sha": "aaaa", "stub": "Initiative-planner", "stub_file": "${PLANNER_STUB}" },
  { "repo": "petry-projects/charlie", "status": "MISSING", "repo_sha": "", "canonical_sha": "aaaa", "stub": "Initiative-planner", "stub_file": "${PLANNER_STUB}" },
  { "repo": "petry-projects/delta", "status": "DRIFTED", "repo_sha": "dddd", "canonical_sha": "cccc", "stub": "Initiative-driver", "stub_file": "${DRIVER_STUB}" }
]
JSON

  # ── gh shim harness (network-driver tests) ──────────────────────────────────
  # A gh stub on PATH logs every write (branch create / contents PUT / pr create)
  # to $CALLS and answers reads deterministically so the driver's branch+PUT+PR
  # sequence can be asserted with no network. Tunable via env the shim reads at
  # call time: EXISTING_PR (pr list result), BASE_SHA, CANON_B64, CANON_SHA,
  # WRITTEN_SHA (the post-PUT blob SHA — defaults to CANON_SHA ⇒ byte-identity).
  STUB_BIN="$(mktemp -d "${BATS_TEST_TMPDIR}/stub_bin.XXXXXX")"
  export PATH="$STUB_BIN:$PATH"
  CALLS="$STUB_BIN/calls.log"; export CALLS
  cat > "$STUB_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
args="$*"
: "${CALLS:?}"
canon_b64="${CANON_B64:-$(printf 'name: canon\n' | base64 | tr -d '\n')}"
canon_sha="${CANON_SHA:-cafebabecafebabecafebabecafebabecafebabe}"
case "$args" in
  *"pr list"*)              printf '%s' "${EXISTING_PR:-}" ;;
  *"pr create"*)            printf 'pr create %s\n' "${args//$'\n'/ }" >> "$CALLS"; echo "https://example/pr/1" ;;
  *"git/refs"*)             echo "branch $args" >> "$CALLS"; echo '{}' ;;   # POST create branch
  *"--method PUT"*)         echo "put $args" >> "$CALLS"; echo '{}' ;;      # contents PUT
  *"git/ref/heads/"*)       printf '%s' "${BASE_SHA:-basesha0000000000000000000000000000000000}" ;;
  *"contents/"*".content"*) printf '%s' "$canon_b64" ;;                     # canonical bytes
  *"contents/"*"?ref="*)    printf '%s' "${WRITTEN_SHA:-$canon_sha}" ;;     # consumer read/verify .sha
  *"contents/"*)            printf '%s' "$canon_sha" ;;                     # canonical .sha
  *)                        echo '{}' ;;
esac
SHIM
  chmod +x "$STUB_BIN/gh"
}

teardown() {
  rm -f "${DRIFT_JSON:-}"
  [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"
  return 0
}

# ---------------------------------------------------------------------------
# resolve_canonical_path <stub_file> — maps a per-repo stub path to the
# canonical org-template path from STUB_REGISTRY (AC #1).
# ---------------------------------------------------------------------------

@test "resolve_canonical_path: planner stub resolves to its canonical path" {
  run resolve_canonical_path "$PLANNER_STUB"
  [ "$status" -eq 0 ]
  [ "$output" = "standards/workflows/initiative-planner.yml" ]
}

@test "resolve_canonical_path: driver stub resolves to its canonical path" {
  run resolve_canonical_path "$DRIVER_STUB"
  [ "$status" -eq 0 ]
  [ "$output" = "standards/workflows/initiative-driver.yml" ]
}

@test "resolve_canonical_path: an unknown stub_file is unresolved (non-zero)" {
  run resolve_canonical_path ".github/workflows/nope.yml"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# remediation_allowlisted <repo> <stub_file> — never-overwrite predicate,
# keyed by repo or repo+stub_file (AC #3).
# ---------------------------------------------------------------------------

@test "remediation_allowlisted: a whole-repo allowlist entry matches any stub in that repo" {
  REMEDIATION_ALLOWLIST=("petry-projects/bravo")
  run remediation_allowlisted "petry-projects/bravo" "$PLANNER_STUB"
  [ "$status" -eq 0 ]
}

@test "remediation_allowlisted: a repo+stub_file entry matches only that file" {
  REMEDIATION_ALLOWLIST=("petry-projects/bravo|${PLANNER_STUB}")
  run remediation_allowlisted "petry-projects/bravo" "$PLANNER_STUB"
  [ "$status" -eq 0 ]
  # A different stub_file in the same repo is NOT allowlisted.
  run remediation_allowlisted "petry-projects/bravo" "$DRIVER_STUB"
  [ "$status" -ne 0 ]
}

@test "remediation_allowlisted: a non-allowlisted repo returns non-zero" {
  REMEDIATION_ALLOWLIST=()
  run remediation_allowlisted "petry-projects/bravo" "$PLANNER_STUB"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# build_remediation_plan <json_file> — the pure plan builder (AC #1, #2, #3).
# ---------------------------------------------------------------------------

@test "build_remediation_plan: selects only DRIFTED entries (ALIGNED/MISSING excluded)" {
  REMEDIATION_ALLOWLIST=()
  run build_remediation_plan "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  len=$(printf '%s' "$output" | jq 'length')
  [ "$len" -eq 2 ]
  repos=$(printf '%s' "$output" | jq -r '.[].repo' | sort | tr '\n' ',')
  [ "$repos" = "petry-projects/bravo,petry-projects/delta," ]
  # The ALIGNED and MISSING repos must not appear.
  printf '%s' "$output" | jq -e 'all(.[]; .repo != "petry-projects/alpha")' >/dev/null
  printf '%s' "$output" | jq -e 'all(.[]; .repo != "petry-projects/charlie")' >/dev/null
}

@test "build_remediation_plan: each entry names repo, stub, stub_file, and canonical source" {
  REMEDIATION_ALLOWLIST=()
  run build_remediation_plan "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  # The bravo planner entry carries the canonical source of record.
  entry=$(printf '%s' "$output" | jq -c '.[] | select(.repo == "petry-projects/bravo")')
  [ "$(printf '%s' "$entry" | jq -r '.stub')" = "Initiative-planner" ]
  [ "$(printf '%s' "$entry" | jq -r '.stub_file')" = "$PLANNER_STUB" ]
  [ "$(printf '%s' "$entry" | jq -r '.canonical_repo')" = "petry-projects/.github" ]
  [ "$(printf '%s' "$entry" | jq -r '.canonical_path')" = "standards/workflows/initiative-planner.yml" ]
  # The driver entry resolves to the driver canonical path.
  driver=$(printf '%s' "$output" | jq -c '.[] | select(.repo == "petry-projects/delta")')
  [ "$(printf '%s' "$driver" | jq -r '.canonical_path')" = "standards/workflows/initiative-driver.yml" ]
}

@test "build_remediation_plan: an allowlisted repo never appears in the plan (AC #3)" {
  REMEDIATION_ALLOWLIST=("petry-projects/bravo")
  run build_remediation_plan "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  len=$(printf '%s' "$output" | jq 'length')
  [ "$len" -eq 1 ]
  printf '%s' "$output" | jq -e 'all(.[]; .repo != "petry-projects/bravo")' >/dev/null
  [ "$(printf '%s' "$output" | jq -r '.[0].repo')" = "petry-projects/delta" ]
}

@test "build_remediation_plan: an allowlisted repo+stub_file excludes only that file (AC #3)" {
  REMEDIATION_ALLOWLIST=("petry-projects/bravo|${PLANNER_STUB}")
  run build_remediation_plan "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  # bravo's planner stub is excluded; delta's driver stub remains.
  printf '%s' "$output" | jq -e 'all(.[]; .repo != "petry-projects/bravo")' >/dev/null
  printf '%s' "$output" | jq -e 'any(.[]; .repo == "petry-projects/delta")' >/dev/null
}

@test "build_remediation_plan: an empty array yields an empty plan" {
  empty="$(mktemp)"
  echo "[]" > "$empty"
  run build_remediation_plan "$empty"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  rm -f "$empty"
}

@test "build_remediation_plan: an absent file yields an empty plan" {
  run build_remediation_plan "/nonexistent/fleet_stub_drift.json"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "build_remediation_plan: malformed (non-array) input fails loud, not silently empty" {
  bad="$(mktemp)"
  echo '{ "not": "an array" }' > "$bad"
  run build_remediation_plan "$bad"
  [ "$status" -ne 0 ]                       # must NOT be a silent exit 0
  [[ "$output" == *"not a readable JSON array"* ]]
  rm -f "$bad"
}

# ---------------------------------------------------------------------------
# Source-guard idiom (AC #4): sourcing exposes the pure helpers without
# executing the CLI driver.
# ---------------------------------------------------------------------------

@test "module is sourced (not executed): pure helpers are available as functions" {
  run type -t build_remediation_plan
  [ "$output" = "function" ]
  run type -t resolve_canonical_path
  [ "$output" = "function" ]
  run type -t remediation_allowlisted
  [ "$output" = "function" ]
}

# ---------------------------------------------------------------------------
# Network driver main() — DRY_RUN gate, branch+PUT+PR sequence, idempotency,
# one-PR-per-repo grouping, SHA byte-identity verify, fail-closed scope guard.
# The gh shim (setup) logs writes to $CALLS; reads are deterministic.
# ---------------------------------------------------------------------------

@test "driver: DRY_RUN is the default — logs intent and makes ZERO write API calls (AC #2)" {
  run bash "$SCRIPT" "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  # No branch create / contents PUT / pr create was ever invoked.
  [ ! -f "$CALLS" ]
  # The intended mutations are logged per repo.
  [[ "$output" == *"dry-run"* ]]
  [[ "$output" == *"petry-projects/bravo"* ]]
  [[ "$output" == *"petry-projects/delta"* ]]
}

@test "driver: --dry-run also forces dry-run even when DRY_RUN=false in env" {
  run env DRY_RUN=false bash "$SCRIPT" --dry-run --pilot petry-projects/bravo "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS" ]
}

@test "driver: a live pilot repo runs branch → PUT → one PR (AC #1, #4)" {
  run env DRY_RUN=false bash "$SCRIPT" --pilot petry-projects/bravo "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  [ -f "$CALLS" ]
  # Branch created on the consumer repo, the drifted stub PUT, and exactly one PR.
  grep -q "branch .*petry-projects/bravo/git/refs" "$CALLS"
  grep -q "put .*petry-projects/bravo/contents/${PLANNER_STUB}" "$CALLS"
  [ "$(grep -c 'pr create' "$CALLS")" -eq 1 ]
  # The PR targets the consumer default branch (a proposal, never a direct push).
  grep -q "pr create .*--base" "$CALLS"
  # The out-of-pilot-scope drifted repo (delta) is never touched.
  run grep -q "petry-projects/delta" "$CALLS"
  [ "$status" -eq 1 ]
}

@test "driver: PR title/body cite the canonical source of record (AC #4)" {
  run env DRY_RUN=false bash "$SCRIPT" --pilot petry-projects/bravo "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  # The single PR references the canonical repo + path the drift was measured against.
  grep -q "pr create" "$CALLS"
  grep "pr create" "$CALLS" | grep -q "petry-projects/.github"
  grep "pr create" "$CALLS" | grep -q "standards/workflows/initiative-planner.yml"
}

@test "driver: an already-open remediation PR is skipped — no writes (AC #3)" {
  run env DRY_RUN=false EXISTING_PR=77 bash "$SCRIPT" --pilot petry-projects/bravo "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"77"* ]]
  # Idempotent: no branch create, no PUT, no second pr create.
  if [ -f "$CALLS" ]; then
    run grep -q "pr create" "$CALLS"
    [ "$status" -eq 1 ]
    run grep -q "put " "$CALLS"
    [ "$status" -eq 1 ]
  fi
}

@test "driver: two drifted stubs in one repo yield ONE branch, two PUTs, ONE PR (AC #1)" {
  multi="$(mktemp "${BATS_TEST_TMPDIR}/multi.XXXXXX")"
  cat > "$multi" <<JSON
[
  { "repo": "petry-projects/echo", "status": "DRIFTED", "repo_sha": "1111", "canonical_sha": "aaaa", "stub": "Initiative-planner", "stub_file": "${PLANNER_STUB}" },
  { "repo": "petry-projects/echo", "status": "DRIFTED", "repo_sha": "2222", "canonical_sha": "cccc", "stub": "Initiative-driver", "stub_file": "${DRIVER_STUB}" }
]
JSON
  run env DRY_RUN=false bash "$SCRIPT" --pilot petry-projects/echo "$multi"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'branch .*petry-projects/echo/git/refs' "$CALLS")" -eq 1 ]
  [ "$(grep -c 'put .*petry-projects/echo/contents/' "$CALLS")" -eq 2 ]
  [ "$(grep -c 'pr create' "$CALLS")" -eq 1 ]
  rm -f "$multi"
}

@test "driver: a post-PUT blob SHA that != canonical SHA fails the repo and opens NO PR (AC #5)" {
  run env DRY_RUN=false WRITTEN_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
    bash "$SCRIPT" --pilot petry-projects/bravo "$DRIFT_JSON"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mismatch"* || "$output" == *"::error::"* ]]
  # Wrote the file but the byte-identity check caught the mismatch → no misleading PR.
  if [ -f "$CALLS" ]; then
    run grep -q "pr create" "$CALLS"
    [ "$status" -eq 1 ]
  fi
}

@test "driver: DRY_RUN=false with NO pilot repo stays dry-run + warns (fail-closed, AC #4)" {
  run env DRY_RUN=false bash "$SCRIPT" "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  # Fail-closed: no writes despite DRY_RUN=false, because no pilot repo was named.
  [ ! -f "$CALLS" ]
}

# ---------------------------------------------------------------------------
# Phase 3 (#1151) — pilot scope, per-run cap, drift-closed verification.
#   Pilot scope (AC #1/#4): live remediation is bounded to the named pilot
#   repo(s); other DRIFTED repos are announced 'out of pilot scope' and skipped.
#   Per-run cap (AC #2): REMEDIATE_MAX_REPOS bounds live remediations; repos
#   beyond the cap are logged as deferred (no silent truncation).
#   Verification (AC #3): each live remediation reports drift-closed yes/no
#   (pushed blob SHA == canon) to the run log and an optional summary artifact.
# ---------------------------------------------------------------------------

@test "driver: pilot scope remediates ONLY the named pilot; other DRIFTED repos are out-of-scope (AC #1)" {
  run env DRY_RUN=false REMEDIATE_PILOT_REPO=petry-projects/bravo bash "$SCRIPT" "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  # The pilot repo (bravo) is remediated: branch + PUT + one PR.
  grep -q "put .*petry-projects/bravo/contents/${PLANNER_STUB}" "$CALLS"
  [ "$(grep -c 'pr create' "$CALLS")" -eq 1 ]
  # The out-of-pilot DRIFTED repo (delta) is announced and never written.
  [[ "$output" == *"petry-projects/delta"*"out of pilot scope"* ]]
  run grep -q "petry-projects/delta" "$CALLS"
  [ "$status" -eq 1 ]
}

@test "driver: pilot unset forces fully dry-run even with DRY_RUN=false (AC #4)" {
  run env DRY_RUN=false bash "$SCRIPT" "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"pilot"* ]]
  # No pilot named ⇒ no live writes at all.
  [ ! -f "$CALLS" ]
}

@test "driver: per-run cap defers repos beyond REMEDIATE_MAX_REPOS (no silent truncation, AC #2)" {
  # Both bravo and delta are named pilots and DRIFTED, but the cap allows only one.
  run env DRY_RUN=false REMEDIATE_MAX_REPOS=1 \
    REMEDIATE_PILOT_REPO="petry-projects/bravo petry-projects/delta" \
    bash "$SCRIPT" "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  # Exactly one repo remediated (bravo sorts first); the other is deferred, logged.
  [ "$(grep -c 'pr create' "$CALLS")" -eq 1 ]
  grep -q "put .*petry-projects/bravo/contents/" "$CALLS"
  [[ "$output" == *"petry-projects/delta deferred"* ]]
  [[ "$output" == *"REMEDIATE_MAX_REPOS=1"* ]]
  # Deferred repo received no writes.
  run grep -q "petry-projects/delta" "$CALLS"
  [ "$status" -eq 1 ]
}

@test "driver: emits a per-repo drift-closed verification summary (log + artifact, AC #3)" {
  summary="$(mktemp "${BATS_TEST_TMPDIR}/summary.XXXXXX")"
  run env DRY_RUN=false REMEDIATE_PILOT_REPO=petry-projects/bravo \
    REMEDIATE_SUMMARY_FILE="$summary" bash "$SCRIPT" "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  # The run log surfaces the drift-closed verdict for the pilot repo.
  [[ "$output" == *"drift-closed=yes"* ]]
  [[ "$output" == *"petry-projects/bravo"* ]]
  # The emitted JSON artifact records the verdict machine-readably.
  [ "$(jq -r '.[0].repo' "$summary")" = "petry-projects/bravo" ]
  [ "$(jq -r '.[0].drift_closed' "$summary")" = "true" ]
  rm -f "$summary"
}

@test "driver: a byte-identity mismatch is reported drift-closed=no in the summary (AC #3, #5)" {
  summary="$(mktemp "${BATS_TEST_TMPDIR}/summary.XXXXXX")"
  run env DRY_RUN=false WRITTEN_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
    REMEDIATE_PILOT_REPO=petry-projects/bravo REMEDIATE_SUMMARY_FILE="$summary" \
    bash "$SCRIPT" "$DRIFT_JSON"
  [ "$status" -ne 0 ]
  [[ "$output" == *"drift-closed=no"* ]]
  [ "$(jq -r '.[0].drift_closed' "$summary")" = "false" ]
  # No misleading PR was opened for the unverified remediation.
  if [ -f "$CALLS" ]; then
    run grep -q "pr create" "$CALLS"
    [ "$status" -eq 1 ]
  fi
  rm -f "$summary"
}

@test "driver: an idempotent skip (existing PR) reports status=skipped, NOT drift-closed=yes (AC #3)" {
  # A pre-existing remediation PR must not be reported as a verified drift close:
  # nothing was written or re-verified this run.
  summary="$(mktemp "${BATS_TEST_TMPDIR}/summary.XXXXXX")"
  run env DRY_RUN=false EXISTING_PR=77 REMEDIATE_PILOT_REPO=petry-projects/bravo \
    REMEDIATE_SUMMARY_FILE="$summary" bash "$SCRIPT" "$DRIFT_JSON"
  [ "$status" -eq 0 ]                                   # a skip is not a failure
  [[ "$output" == *"drift-closed=skipped"* ]]
  [[ "$output" != *"drift-closed=yes"* ]]               # must NOT claim a verified close
  [ "$(jq -r '.[0].status' "$summary")" = "skipped" ]
  [ "$(jq -r '.[0].drift_closed' "$summary")" = "false" ]
  rm -f "$summary"
}

@test "driver: a non-numeric REMEDIATE_MAX_REPOS fails loud (never a bad -ge comparison, AC #2)" {
  run env DRY_RUN=false REMEDIATE_MAX_REPOS=abc REMEDIATE_PILOT_REPO=petry-projects/bravo \
    bash "$SCRIPT" "$DRIFT_JSON"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REMEDIATE_MAX_REPOS must be a non-negative integer"* ]]
}

@test "pilot helpers: _in_pilot matches a named repo and fail-closes on empty (AC #1, #4)" {
  REMEDIATE_PILOT_REPO="petry-projects/bravo petry-projects/delta"
  run _in_pilot "petry-projects/bravo"
  [ "$status" -eq 0 ]
  run _in_pilot "petry-projects/charlie"
  [ "$status" -ne 0 ]
  # An empty pilot list means NOTHING is eligible (fail-closed, unlike _in_scope).
  REMEDIATE_PILOT_REPO=""
  run _in_pilot "petry-projects/bravo"
  [ "$status" -ne 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Per-job (role-selector) remediation over a collapsed agent-ingress.yml (#1726).
# Remediation must PATCH a single job block (read-modify-write) — never overwrite
# the whole file and never touch a sibling job — and must NEVER recreate a
# deliberately-removed block. These are PURE (no network): they exercise
# patch_job_block over the agent-ingress fixtures plus the role-aware resolver,
# allowlist, and plan builder with a synthetic role registry entry.
# ═══════════════════════════════════════════════════════════════════════════════

INGRESS_CANON="${BATS_TEST_DIRNAME}/fixtures/agent-ingress/canonical.yml"
INGRESS_DRIFTED="${BATS_TEST_DIRNAME}/fixtures/agent-ingress/drifted-dev-lead.yml"
INGRESS_NO_DEVLEAD="${BATS_TEST_DIRNAME}/fixtures/agent-ingress/collapsed-no-dev-lead.yml"
INGRESS_STUB=".github/workflows/agent-ingress.yml"

# QA input #6: remediation of a drift in EXACTLY ONE job must patch ONLY that job
# and leave the sibling job byte-identical.
@test "patch_job_block: patching one role block re-aligns it to canon and leaves the sibling untouched (AC #3, QA #6)" {
  block_tmp="$(mktemp)"
  extract_job_block "dev-lead" < "$INGRESS_CANON" > "$block_tmp"

  patched="$(patch_job_block "dev-lead" "$block_tmp" < "$INGRESS_DRIFTED")"
  # The dev-lead block now equals canon ...
  canon_dl="$(job_block_sha "dev-lead" < "$INGRESS_CANON")"
  patched_dl="$(printf '%s' "$patched" | job_block_sha "dev-lead")"
  [ "$patched_dl" = "$canon_dl" ]
  # ... while the sibling pr-review-mention block is byte-identical to the pre-patch file.
  before_prm="$(job_block_sha "pr-review-mention" < "$INGRESS_DRIFTED")"
  after_prm="$(printf '%s' "$patched" | job_block_sha "pr-review-mention")"
  [ "$before_prm" = "$after_prm" ]
  rm -f "$block_tmp"
}

@test "patch_job_block: a removed block is NEVER recreated (refuses with exit 3, AC #3)" {
  block_tmp="$(mktemp)"
  extract_job_block "dev-lead" < "$INGRESS_CANON" > "$block_tmp"
  # The repo deliberately dropped its dev-lead job — patching must refuse, not insert.
  run patch_job_block "dev-lead" "$block_tmp" < "$INGRESS_NO_DEVLEAD"
  [ "$status" -eq 3 ]
  # The output must not contain a resurrected dev-lead job.
  [[ "$output" != *"dev-lead-reusable.yml"* ]]
  rm -f "$block_tmp"
}

@test "remediation_allowlisted: a role-granular entry protects only that job block (AC #3)" {
  REMEDIATION_ALLOWLIST=("petry-projects/foxtrot|${INGRESS_STUB}|dev-lead")
  # The allowlisted role is protected ...
  run remediation_allowlisted "petry-projects/foxtrot" "$INGRESS_STUB" "dev-lead"
  [ "$status" -eq 0 ]
  # ... but a sibling role in the SAME file is NOT protected.
  run remediation_allowlisted "petry-projects/foxtrot" "$INGRESS_STUB" "pr-review-mention"
  [ "$status" -eq 1 ]
}

@test "resolve_canonical_path: (stub_file, role) disambiguates collapsed roles that share a file (AC #1)" {
  STUB_REGISTRY+=(
    $'dev-lead\tDev-lead\t.github/workflows/agent-ingress.yml\tstandards/workflows/agent-ingress.yml\tdev-lead\t\t'
  )
  run resolve_canonical_path "$INGRESS_STUB" "dev-lead"
  [ "$status" -eq 0 ]
  [ "$output" = "standards/workflows/agent-ingress.yml" ]
  # A wrong/absent role for the same file does NOT resolve (would be ambiguous).
  run resolve_canonical_path "$INGRESS_STUB" "no-such-role"
  [ "$status" -eq 1 ]
  # The whole-file resolver (empty role) is unaffected by the added role entry.
  run resolve_canonical_path "$PLANNER_STUB"
  [ "$status" -eq 0 ]
  [ "$output" = "standards/workflows/initiative-planner.yml" ]
}

@test "build_remediation_plan: carries role and resolves the collapsed canonical (AC #1, #3)" {
  STUB_REGISTRY+=(
    $'dev-lead\tDev-lead\t.github/workflows/agent-ingress.yml\tstandards/workflows/agent-ingress.yml\tdev-lead\t\t'
    $'pr-review-mention\tPr-review-mention\t.github/workflows/agent-ingress.yml\tstandards/workflows/agent-ingress.yml\tpr-review-mention\t\t'
  )
  role_json="$(mktemp)"
  cat > "$role_json" <<JSON
[
  { "repo": "petry-projects/foxtrot", "status": "DRIFTED", "repo_sha": "1", "canonical_sha": "2", "stub": "Dev-lead", "stub_file": "${INGRESS_STUB}", "role": "dev-lead" },
  { "repo": "petry-projects/foxtrot", "status": "DRIFTED", "repo_sha": "3", "canonical_sha": "4", "stub": "Pr-review-mention", "stub_file": "${INGRESS_STUB}", "role": "pr-review-mention" }
]
JSON
  REMEDIATION_ALLOWLIST=()
  run build_remediation_plan "$role_json"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" -eq 2 ]
  dl="$(printf '%s' "$output" | jq -c '.[] | select(.role == "dev-lead")')"
  [ "$(printf '%s' "$dl" | jq -r '.canonical_path')" = "standards/workflows/agent-ingress.yml" ]
  [ "$(printf '%s' "$dl" | jq -r '.stub_file')" = "$INGRESS_STUB" ]
  rm -f "$role_json"
}

@test "build_remediation_plan: a role-granular allowlist excludes only that block, sibling remains (AC #3)" {
  STUB_REGISTRY+=(
    $'dev-lead\tDev-lead\t.github/workflows/agent-ingress.yml\tstandards/workflows/agent-ingress.yml\tdev-lead\t\t'
    $'pr-review-mention\tPr-review-mention\t.github/workflows/agent-ingress.yml\tstandards/workflows/agent-ingress.yml\tpr-review-mention\t\t'
  )
  role_json="$(mktemp)"
  cat > "$role_json" <<JSON
[
  { "repo": "petry-projects/foxtrot", "status": "DRIFTED", "repo_sha": "1", "canonical_sha": "2", "stub": "Dev-lead", "stub_file": "${INGRESS_STUB}", "role": "dev-lead" },
  { "repo": "petry-projects/foxtrot", "status": "DRIFTED", "repo_sha": "3", "canonical_sha": "4", "stub": "Pr-review-mention", "stub_file": "${INGRESS_STUB}", "role": "pr-review-mention" }
]
JSON
  REMEDIATION_ALLOWLIST=("petry-projects/foxtrot|${INGRESS_STUB}|dev-lead")
  run build_remediation_plan "$role_json"
  [ "$status" -eq 0 ]
  # Only the sibling (pr-review-mention) block survives; the allowlisted dev-lead is gone.
  [ "$(printf '%s' "$output" | jq 'length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].role')" = "pr-review-mention" ]
  rm -f "$role_json"
}
