#!/usr/bin/env bats
# Unit tests for scripts/lib/channel-pin-guard.sh and its wiring (#2220).
#
# On #2157 and #1796 a dev-lead pass "fixed" a red, non-required `template-drift`
# check by re-seeding .github/workflows/dev-lead.yml from the standards template.
# That repinned this repo's caller stub from `dev-lead/v139-ring0` to the legacy
# `dev-lead/v1-stable` channel (a 2026-09-22 release) and deleted the comment
# explaining the pin. Nothing in the harness stopped a pass editing its own stub.
# This guard does: a pass that changes a first-party channel pin (`uses:` ref or
# `agent_ref`) on a workflow file is refused before the push and escalated. A red
# `template-drift` alone no longer starts a fix pass at all.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/channel-pin-guard.sh"
REVIEWS="$SCRIPT_DIR/scripts/dev-lead-fix-reviews.sh"
FIX_CI="$SCRIPT_DIR/scripts/dev-lead-fix-ci.sh"
REUSABLE="$SCRIPT_DIR/.github/workflows/dev-lead-reusable.yml"

STUB=".github/workflows/dev-lead.yml"
REUSABLE_REF="petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml"

setup() {
  # shellcheck source=scripts/lib/channel-pin-guard.sh
  source "$LIB"
}

@test "channel-pin-guard.sh is safe to source under set -euo pipefail" {
  run bash -c "set -euo pipefail; source '$LIB'"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

# ---------------------------------------------------------------------------
# cpg_is_channel_ref / cpg_pins — pure
# ---------------------------------------------------------------------------

@test "cpg_is_channel_ref: moving channel tags are channel refs; SHAs, branches and semver are not" {
  cpg_is_channel_ref "dev-lead/v139-ring0"
  cpg_is_channel_ref "dev-lead/v1-stable"
  cpg_is_channel_ref "pr-review/v1-next"
  cpg_is_channel_ref "dev-lead/stable"
  run cpg_is_channel_ref "main";  [[ "$status" -eq 1 ]]
  run cpg_is_channel_ref "v1";    [[ "$status" -eq 1 ]]
  run cpg_is_channel_ref "4fd4eac0123456789abcdef0123456789abcdef0"; [[ "$status" -eq 1 ]]
  run cpg_is_channel_ref "";      [[ "$status" -eq 1 ]]
}

@test "cpg_pins: lists first-party uses: refs and agent_ref values, not comments or third-party actions" {
  local content
  content=$(_stub_body "dev-lead/v139-ring0")
  content+=$'\n      - uses: actions/checkout@v4\n'
  run cpg_pins "$content"
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 2 ]]
  [[ "${lines[0]}" == "uses"$'\t'"${REUSABLE_REF}@dev-lead/v139-ring0" ]]
  [[ "${lines[1]}" == "agent_ref"$'\t'"dev-lead/v139-ring0" ]]
}

# ---------------------------------------------------------------------------
# cpg_scan_pass — the impure gatherer over <pre-pass>..<head>
# ---------------------------------------------------------------------------

# _stub_body <ref> — this repo's dev-lead.yml shape, pinned to <ref>.
_stub_body() {
  cat <<EOF
name: Dev-Lead Agent
on:
  pull_request:
    branches: [main]
jobs:
  dev-lead:
    # Pinned to the moving channel tag. Asserted by
    # tests/test_sc2_self_review_channel.bats — never repin this to next.
    uses: ${REUSABLE_REF}@${1}  # NOSONAR(githubactions:S7637) first-party channel ref
    with:
      agent_ref: ${2:-$1}
    secrets: inherit
EOF
}

# _mk_pr: main holds the stub pinned to v139-ring0, a README and an unpinned
# workflow; the PR branch adds a feature commit. PRE is the pre-pass head.
_mk_pr() {
  REPO_DIR="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$REPO_DIR"
  cd "$REPO_DIR"
  git config user.email t@t; git config user.name T
  mkdir -p .github/workflows
  echo "# repo" > README.md
  _stub_body "dev-lead/v139-ring0" > "$STUB"
  printf 'name: lint\non: push\njobs:\n  l:\n    runs-on: ubuntu-latest\n' > .github/workflows/lint.yml
  git add -A; git commit -q -m base
  git checkout -q -b feat
  echo "feature" > feature.txt
  git add -A; git commit -q -m "feat: x"
  PRE="$(git rev-parse HEAD)"
}

@test "cpg_scan_pass: the #2157/#1796 shape — repin v139-ring0 -> v1-stable is refused (drift rc1)" {
  _mk_pr
  _stub_body "dev-lead/v1-stable" > "$STUB"
  git commit -qam "fix(template-drift): re-sync dev-lead.yml to standards baseline with v1-stable channel tag"
  run cpg_scan_pass "$PRE" HEAD
  [[ "$status" -eq 1 ]]
  [[ "${lines[0]}" == "drift" ]]
  [[ "${lines[1]}" == "${STUB}"$'\t'* ]]
  [[ "${lines[1]}" == *"dev-lead/v139-ring0"* ]]
  [[ "${lines[1]}" == *"dev-lead/v1-stable"* ]]
}

@test "cpg_scan_pass: changing only agent_ref is refused" {
  _mk_pr
  _stub_body "dev-lead/v139-ring0" "dev-lead/v1-stable" > "$STUB"
  git commit -qam "fix: agent_ref"
  run cpg_scan_pass "$PRE" HEAD
  [[ "$status" -eq 1 ]]
  [[ "${lines[0]}" == "drift" ]]
}

@test "cpg_scan_pass: SHA-pinning a channel-pinned stub is refused" {
  _mk_pr
  _stub_body "4fd4eac0123456789abcdef0123456789abcdef0" > "$STUB"
  git commit -qam "fix: pin to sha"
  run cpg_scan_pass "$PRE" HEAD
  [[ "$status" -eq 1 ]]
}

@test "cpg_scan_pass: deleting a channel-pinned stub is refused" {
  _mk_pr
  git rm -q "$STUB"; git commit -qm "chore: drop stub"
  run cpg_scan_pass "$PRE" HEAD
  [[ "$status" -eq 1 ]]
  [[ "${lines[1]}" == "${STUB}"$'\t'*$'\t'"<deleted>" ]]
}

@test "cpg_scan_pass: a comment-only edit to the stub keeps the pin -> clean" {
  _mk_pr
  sed -i 's/never repin this to next/never repin this/' "$STUB"
  git commit -qam "docs: comment"
  run cpg_scan_pass "$PRE" HEAD
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "cpg_scan_pass: edits to files without a channel pin are clean" {
  _mk_pr
  echo more >> README.md
  printf '    timeout-minutes: 5\n' >> .github/workflows/lint.yml
  git commit -qam "chore: unrelated"
  run cpg_scan_pass "$PRE" HEAD
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "cpg_scan_pass: a pass that changes nothing is clean" {
  _mk_pr
  run cpg_scan_pass "$PRE" HEAD
  [[ "$status" -eq 0 ]]
}

@test "cpg_scan_pass: restoring the base branch's pin is clean (cleanup of a bad repin)" {
  _mk_pr
  _stub_body "dev-lead/v1-stable" > "$STUB"
  git commit -qam "fix(ci): re-seed dev-lead.yml"   # the bad repin, already on the PR
  PRE="$(git rev-parse HEAD)"
  _stub_body "dev-lead/v139-ring0" > "$STUB"
  git commit -qam "revert the repin"
  run cpg_scan_pass "$PRE" HEAD main
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
  # Without the base rev the same change is not provably a restore.
  run cpg_scan_pass "$PRE" HEAD
  [[ "$status" -eq 1 ]]
}

@test "cpg_scan_pass: adopting a pin the base branch moved to (rebase) is clean" {
  _mk_pr
  git checkout -q main
  _stub_body "dev-lead/v140-ring0" > "$STUB"
  git commit -qam "chore: promote stub to v140"
  git checkout -q feat
  git merge -q --no-edit main
  run cpg_scan_pass "$PRE" HEAD main
  [[ "$status" -eq 0 ]]
}

@test "cpg_scan_pass: an unresolvable pre-pass head fails closed -> unknown rc2" {
  _mk_pr
  run cpg_scan_pass "" HEAD
  [[ "$status" -eq 2 ]]
  [[ "$output" == "unknown" ]]
  run cpg_scan_pass "0000000000000000000000000000000000000000" HEAD
  [[ "$status" -eq 2 ]]
}

@test "cpg_refused_body: names the stub, both pins, and says nothing was pushed" {
  local rows
  rows="${STUB}"$'\t'"uses ${REUSABLE_REF}@dev-lead/v139-ring0, agent_ref dev-lead/v139-ring0"$'\t'"uses ${REUSABLE_REF}@dev-lead/v1-stable, agent_ref dev-lead/v1-stable"
  run cpg_refused_body "fix-ci" "$rows"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"\`${STUB}\`"* ]]
  [[ "$output" == *"dev-lead/v139-ring0"* ]]
  [[ "$output" == *"dev-lead/v1-stable"* ]]
  [[ "$output" == *"did not push"* ]]
  [[ "$output" == *"#2220"* ]]
}

@test "cpg_refused_body: an unverifiable scan says so" {
  run cpg_refused_body "fix-reviews" ""
  [[ "$output" == *"could not be verified"* ]]
  [[ "$output" == *"did not push"* ]]
}

# ---------------------------------------------------------------------------
# Harness wiring — fix-reviews (every pushing intent) and fix-ci
# ---------------------------------------------------------------------------

@test "Wiring: fix-reviews sources the guard and commit_and_push refuses a repin with rc 4 for every pushing intent" {
  grep -q 'source "$(dirname "$0")/lib/channel-pin-guard.sh"' "$REVIEWS"
  local body block
  body=$(awk '/^commit_and_push\(\) \{/,/^}/' "$REVIEWS")
  grep -q 'cpg_scan_pass' <<<"$body"
  # Not scoped to bot intents: only enable-auto-merge (which never pushes) is exempt.
  block=$(grep -B6 -A14 'cpg_scan_pass' <<<"$body")
  grep -q 'enable-auto-merge) ;;' <<<"$block"
  grep -q 'cpg_flag_refused' <<<"$block"
  grep -q 'return 4' <<<"$block"
  # The guard runs before the push.
  local guard_line push_line
  guard_line=$(grep -n 'cpg_scan_pass' <<<"$body" | head -1 | cut -d: -f1)
  push_line=$(grep -n 'push_no_clobber ||' <<<"$body" | head -1 | cut -d: -f1)
  [[ "$guard_line" -lt "$push_line" ]]
}

@test "Wiring: on-mention and rebase stop on a guard refusal (rc 4) instead of reporting applied/no-changes" {
  local body
  body=$(awk '/^  on-mention\)$/,/^    ;;$/' "$REVIEWS")
  grep -A14 'commit_and_push "on-mention"' <<<"$body" | grep -q '"\$cp_rc" -eq 4'
  body=$(awk '/commit_and_push "rebase" \|\| cp_rc/,/verify_resolution_integrity/' "$REVIEWS")
  grep -q '"\$cp_rc" -eq 4' <<<"$body"
}

@test "Wiring: fix-ci runs the guard before push_with_merge_guard" {
  grep -qF 'source "$(dirname "${BASH_SOURCE[0]}")/lib/channel-pin-guard.sh"' "$FIX_CI"
  local guard_line push_line
  guard_line=$(grep -n 'fix_ci_channel_pin_guard "' "$FIX_CI" | head -1 | cut -d: -f1)
  push_line=$(grep -n 'push_with_merge_guard || exit 1' "$FIX_CI" | head -1 | cut -d: -f1)
  [[ -n "$guard_line" && -n "$push_line" ]]
  [[ "$guard_line" -lt "$push_line" ]]
}

# fix-ci is sourceable (main runs only when executed), so the guard runs for real
# against a git fixture with gh stubbed out.
_stub_gh() {
  STUB_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN_DIR"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_CALLS"
case "$*" in
  *"/comments"*) echo "[]" ;;
  *"pulls/"*) echo '{"base":{"ref":"main"},"state":"open"}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export PATH="$STUB_BIN_DIR:$PATH"
  export GH_CALLS="$BATS_TEST_TMPDIR/gh-calls"
  : > "$GH_CALLS"
}

@test "fix-ci: a pass whose diff repins the stub is refused before the push and escalated" {
  _mk_pr
  _stub_gh
  _stub_body "dev-lead/v1-stable" > "$STUB"
  git commit -qam "fix(ci): re-seed dev-lead.yml from standards to resolve template-drift check"
  run bash -c "export PR_NUMBER=42 HEAD_SHA=$PRE REPO=o/r DEV_LEAD_DRY_RUN=false PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    source '$FIX_CI'
    fix_ci_channel_pin_guard '$PRE' main"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Channel-pin guard"* ]]
  grep -q 'issues/42/labels' "$GH_CALLS"          # held for a human
  grep -q 'pr comment 42' "$GH_CALLS"             # escalation comment
  grep -q 'disable-auto' "$GH_CALLS"              # auto-merge off
  grep -q 'status=refused' "$GH_CALLS"            # terminal marker for this SHA
}

@test "fix-ci: a pass that leaves the pin alone passes the guard" {
  _mk_pr
  _stub_gh
  echo fix >> feature.txt
  git commit -qam "fix(ci): real fix"
  run bash -c "export PR_NUMBER=42 HEAD_SHA=$PRE REPO=o/r DEV_LEAD_DRY_RUN=false PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    source '$FIX_CI'
    fix_ci_channel_pin_guard '$PRE' main"
  [[ "$status" -eq 0 ]]
  ! grep -q 'pr comment' "$GH_CALLS"
}

@test "fix-ci: a refused SHA is terminal for idempotency" {
  grep -qE 'status=\(applied\|failed\|no-changes\|refused\)' "$FIX_CI"
}

# ---------------------------------------------------------------------------
# AC 2 — a red `template-drift` alone dispatches nothing
# ---------------------------------------------------------------------------

@test "ci-relay: a red template-drift check is not relayed (the job's if: excludes it)" {
  local cond
  cond=$(awk '/^  ci-relay:$/,/runs-on:/' "$REUSABLE")
  [[ -n "$cond" ]]
  grep -q "github.event.check_run.name != 'template-drift'" <<<"$cond"
}

@test "ci-relay: the workflow exclusion and fix-ci's ignored-check list agree" {
  source "$FIX_CI"
  local name
  for name in "${FIX_CI_IGNORED_CHECKS[@]}"; do
    awk '/^  ci-relay:$/,/runs-on:/' "$REUSABLE" | grep -qF "github.event.check_run.name != '${name}'"
  done
}

@test "fix-ci: a dispatch carrying only a red template-drift runs no engine and pushes nothing" {
  _stub_gh
  run env PR_NUMBER=42 HEAD_SHA=abc123 REPO=o/r DEV_LEAD_DRY_RUN=true \
    PROMPTS_DIR="$SCRIPT_DIR/prompts/dev-lead" \
    CHECKS_JSON='[{"name":"template-drift","conclusion":"failure","details_url":"https://github.com/o/r/actions/runs/1/job/2","id":7}]' \
    bash "$FIX_CI"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"not a fix-ci trigger"* ]]
  [[ "$output" != *"would run engine"* ]]
  ! grep -q 'pr comment' "$GH_CALLS"
}

@test "fix-ci: template-drift alongside a real failure still runs (only the real check is a trigger)" {
  _stub_gh
  run env PR_NUMBER=42 HEAD_SHA=abc123 REPO=o/r DEV_LEAD_DRY_RUN=true \
    PROMPTS_DIR="$SCRIPT_DIR/prompts/dev-lead" \
    CHECKS_JSON='[{"name":"template-drift","conclusion":"failure","id":7},{"name":"unit","conclusion":"failure","id":8}]' \
    bash "$FIX_CI"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"would run engine"* ]]
}

@test "fix-ci: an empty CHECKS_JSON is not treated as all-ignored (behavior unchanged)" {
  _stub_gh
  run env PR_NUMBER=42 HEAD_SHA=abc123 REPO=o/r DEV_LEAD_DRY_RUN=true \
    PROMPTS_DIR="$SCRIPT_DIR/prompts/dev-lead" CHECKS_JSON='[]' \
    bash "$FIX_CI"
  [[ "$output" != *"not a fix-ci trigger"* ]]
}
