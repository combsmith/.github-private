#!/usr/bin/env bats
# Unit tests for scripts/seed-repo-template.sh — the DRY_RUN-aware generator that
# seeds combsmith/repo-template with the org baseline file scaffold:
# the ~10 thin-caller workflow stubs (fetched byte-identically from the public
# standards/ and repinned from local ./… dogfood refs to published channel tags)
# plus the root/baseline files (issue #966, epic #964). Mirrors the cross-repo
# stub/seam patterns in tests/test_bootstrap_new_repo.bats.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SEED="$SCRIPT_DIR/scripts/seed-repo-template.sh"

# The exact set of workflow stubs the scaffold must ship (AC #1).
EXPECTED_STUBS=(
  agent-shield auto-rebase ci copilot-setup-steps dependabot-automerge
  dependabot-rebase dependency-audit dev-lead pr-review-mention sonarcloud
)
# The caller stubs that wrap a reusable workflow and must be repinned (AC #2).
CALLER_STUBS=(
  agent-shield auto-rebase dependabot-automerge dependabot-rebase
  dependency-audit dev-lead pr-review-mention
)
# Self-contained inline workflows that ship byte-identically (no reusable ref).
INLINE_STUBS=(ci copilot-setup-steps sonarcloud)

setup() {
  STUB_BIN="$(mktemp -d)" || { echo "Failed to create STUB_BIN" >&2; exit 1; }
  export PATH="$STUB_BIN:$PATH"
  CALLS="$STUB_BIN/calls.log"; export CALLS
  STANDARDS_DIR="$(mktemp -d)" || { echo "Failed to create STANDARDS_DIR" >&2; exit 1; }
  mkdir -p "$STANDARDS_DIR/standards/workflows" "$STANDARDS_DIR/standards/dependabot"
  export STANDARDS_DIR
}
teardown() {
  [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"
  [ -n "${STANDARDS_DIR:-}" ] && rm -rf "$STANDARDS_DIR"
  return 0
}

# gh stub: logs every write (POST/PUT/PATCH/pr create) to $CALLS; returns empty
# JSON for reads so the cross-repo orchestration never fails on a read.
# pr list returns nothing (no existing PR) so seeding creates a fresh PR.
_stub_gh() {
  cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"--method POST"*|*"--method PUT"*|*"PATCH"*|*"pr create"*) echo "\$args" >> "$CALLS"; echo '{}' ;;
  *"pr list"*) ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$STUB_BIN/gh"
}

# Drop a fake standards/workflows/<name> fixture used by --emit-workflow / seeding.
_fixture_workflow() { # <name> <heredoc-content-on-stdin>
  cat > "$STANDARDS_DIR/standards/workflows/$1"
}

# gh stub that returns NOTHING for every call. Used by the fail-loud tests so a
# fixture absent from STANDARDS_DIR cannot fall through to a real network fetch
# (which would succeed for files that exist in the live standards repo and make
# the test pass/fail on network state instead of the seeder's behavior).
_stub_gh_empty() {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
}

# ── manifest: workflow set (AC #1, #5) ────────────────────────────────────────
@test "list-workflows: ships exactly the 10 named stubs" {
  run bash "$SEED" --list-workflows
  [ "$status" -eq 0 ]
  mapfile -t got < <(printf '%s\n' "$output" | sort)
  mapfile -t want < <(printf '%s\n' "${EXPECTED_STUBS[@]}" | sed 's/$/.yml/' | sort)
  [ "${#got[@]}" -eq "${#want[@]}" ]
  for i in "${!want[@]}"; do [ "${got[$i]}" = "${want[$i]}" ]; done
}

@test "list-workflows: no issue/PR template or labeler config (AC #5)" {
  run bash "$SEED" --list-workflows
  [ "$status" -eq 0 ]
  [[ "$output" != *"ISSUE_TEMPLATE"* ]]
  [[ "$output" != *"PULL_REQUEST_TEMPLATE"* ]]
  [[ "$output" != *"labeler"* ]]
}

@test "list-baseline: no issue/PR template or labeler config (AC #5)" {
  run bash "$SEED" --list-baseline
  [ "$status" -eq 0 ]
  [[ "$output" != *"ISSUE_TEMPLATE"* ]]
  [[ "$output" != *"PULL_REQUEST_TEMPLATE"* ]]
  [[ "$output" != *"labeler"* ]]
}

# ── manifest: baseline set (AC #3) ────────────────────────────────────────────
@test "list-baseline: includes every required root/baseline file" {
  run bash "$SEED" --list-baseline
  [ "$status" -eq 0 ]
  for f in AGENTS.md CLAUDE.md .github/CODEOWNERS .github/dependabot.yml \
           .gitleaks.toml sonar-project.properties .gitignore LICENSE \
           SECURITY.md README.md BOOTSTRAP.md; do
    [[ "$output" == *"$f"* ]] || { echo "missing baseline: $f" >&2; false; }
  done
}

# ── repin: caller stubs → published channel tags (AC #2) ───────────────────────
@test "repin: public caller ./… dogfood ref → @<name>/stable on combsmith/.github" {
  run bash -c 'printf "%s\n" "    uses: ./.github/workflows/auto-rebase-reusable.yml@auto-rebase/next" | bash "$0" --repin auto-rebase' "$SEED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uses: combsmith/.github/.github/workflows/auto-rebase-reusable.yml@auto-rebase/stable"* ]]
  [[ "$output" != *"./.github/workflows/auto-rebase-reusable.yml"* ]]
  [[ "$output" != *"auto-rebase/next"* ]]
}

@test "repin: private dev-lead → @dev-lead/stable on .github-private and agent_ref repinned" {
  src=$'    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/next\n    with:\n      agent_ref: dev-lead/next'
  run bash -c 'printf "%s\n" "$1" | bash "$0" --repin dev-lead' "$SEED" "$src"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/stable"* ]]
  [[ "$output" == *"agent_ref: dev-lead/stable"* ]]
  [[ "$output" != *"dev-lead/next"* ]]
}

@test "repin: NO shipped caller stub retains a ./… dogfood ref or a /next channel" {
  for name in "${CALLER_STUBS[@]}"; do
    src="    uses: ./.github/workflows/${name}-reusable.yml@${name}/next"
    run bash -c 'printf "%s\n" "$1" | bash "$0" --repin "$2"' "$SEED" "$src" "$name"
    [ "$status" -eq 0 ]
    [[ "$output" != *"./.github/workflows/${name}-reusable.yml"* ]] \
      || { echo "$name still has ./ ref" >&2; false; }
    [[ "$output" != *"${name}/next"* ]] || { echo "$name still has /next" >&2; false; }
    [[ "$output" == *"${name}-reusable.yml@${name}/stable"* ]] \
      || { echo "$name not pinned to @${name}/stable" >&2; false; }
  done
}

# ── emit-workflow: fetch byte-identical, repin callers, pass inline through ────
@test "emit-workflow: inline workflow ships byte-identically (no mutation)" {
  printf 'name: CI\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n' \
    | _fixture_workflow ci.yml
  run bash "$SEED" --emit-workflow ci.yml
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$STANDARDS_DIR/standards/workflows/ci.yml")" ]
}

@test "emit-workflow: caller stub fetched from standards is repinned" {
  printf '%s\n' 'jobs:' '  run:' \
    '    uses: ./.github/workflows/dependency-audit-reusable.yml@dependency-audit/next' \
    | _fixture_workflow dependency-audit.yml
  run bash "$SEED" --emit-workflow dependency-audit.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"uses: combsmith/.github/.github/workflows/dependency-audit-reusable.yml@dependency-audit/stable"* ]]
  [[ "$output" != *"./.github/workflows/dependency-audit-reusable.yml"* ]]
}

@test "emit-workflow: sonarcloud inline stub ships byte-identically (no repin)" {
  # sonarcloud is kind=inline: it carries no reusable ref and must pass through
  # verbatim, exactly like ci.yml. Covers the second inline workflow (#966 follow-up).
  _fixture_workflow sonarcloud.yml <<'EOF'
name: SonarCloud Analysis
on: [push]
jobs:
  sonarcloud:
    name: SonarCloud
    runs-on: ubuntu-latest
EOF
  run bash "$SEED" --emit-workflow sonarcloud.yml
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$STANDARDS_DIR/standards/workflows/sonarcloud.yml")" ]
}

@test "emit-workflow: FAILS LOUD when an inline workflow's standard file is absent" {
  # Regression guard for the original #966 defect: ci/sonarcloud are declared
  # kind=inline but were MISSING from standards/workflows/. The emit path must
  # exit non-zero with a clear error, never silently ship an empty workflow.
  # No fixture for sonarcloud.yml is written → the fetch must fail.
  _stub_gh_empty
  run bash "$SEED" --emit-workflow sonarcloud.yml
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not fetch standards/workflows/sonarcloud.yml"* ]]
}

@test "emit-workflow: every inline manifest stub fails loud when its standard is absent" {
  # Guards the whole inline set, so a future manifest addition can't silently
  # 404 at seed time the way ci.yml did.
  _stub_gh_empty
  for name in "${INLINE_STUBS[@]}"; do
    run bash "$SEED" --emit-workflow "${name}.yml"
    [ "$status" -ne 0 ] || { echo "$name did not fail loud on a missing standard" >&2; false; }
    [[ "$output" == *"could not fetch standards/workflows/${name}.yml"* ]] \
      || { echo "$name missing the fail-loud error message" >&2; false; }
  done
}

# ── baseline content (AC #3, #4) ──────────────────────────────────────────────
@test "baseline: CODEOWNERS is the org default rule" {
  run bash "$SEED" --emit-baseline .github/CODEOWNERS
  [ "$status" -eq 0 ]
  [[ "$output" == *"* @combsmith/org-leads"* ]]
}

@test "baseline: AGENTS.md is a consumer pointer to the org AGENTS.md" {
  run bash "$SEED" --emit-baseline AGENTS.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"combsmith/.github"* ]]
  [[ "$output" == *"AGENTS.md"* ]]
}

@test "baseline: CLAUDE.md is a one-line pointer" {
  run bash "$SEED" --emit-baseline CLAUDE.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"AGENTS.md"* ]]
  # one-line pointer: at most a couple of non-blank lines
  nonblank="$(printf '%s\n' "$output" | grep -c . || true)"
  [ "$nonblank" -le 3 ]
}

@test "baseline: BOOTSTRAP.md documents the per-stack ci.yml + Dependabot post-clone step (AC #4)" {
  run bash "$SEED" --emit-baseline BOOTSTRAP.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"ci.yml"* ]]
  [[ "$output" == *"Dependabot"* || "$output" == *"dependabot"* ]]
  [[ "$output" == *"stack"* ]]
}

@test "baseline: BOOTSTRAP.md resolves the two open onboarding questions — frameworks opt-in, app installs manual (#970 AC #4)" {
  run bash "$SEED" --emit-baseline BOOTSTRAP.md
  [ "$status" -eq 0 ]
  # Q1: framework subtrees (frameworks/) are opt-in, NOT seeded by the template.
  [[ "$output" == *"frameworks/"* ]]
  [[ "$output" == *"opt-in"* ]]
  [[ "$output" == *"not"*"seed"* || "$output" == *"not seeded"* ]]
  # Q2: app installs (Claude/CodeRabbit) are a manual org-admin step, not done by bootstrap.
  [[ "$output" == *"Claude"* ]]
  [[ "$output" == *"CodeRabbit"* ]]
  [[ "$output" == *"manual"* ]]
  [[ "$output" == *"auto-trigger"* ]]
}

# ── .gitleaks.toml baseline is fetched verbatim from standards/gitleaks.toml ───
# Seeds the secret-scan job's required config (push-protection.md); without it the
# template ci.yml's `gitleaks detect --config .gitleaks.toml` fails file-not-found.
@test "baseline: .gitleaks.toml is fetched verbatim from standards/gitleaks.toml (#575)" {
  printf 'title = "gitleaks config"\n[allowlist]\npaths = [ %s ]\n' "'''_bmad/'''" \
    > "$STANDARDS_DIR/standards/gitleaks.toml"
  run bash "$SEED" --emit-baseline .gitleaks.toml
  [ "$status" -eq 0 ]
  [[ "$output" == *'title = "gitleaks config"'* ]]
  [[ "$output" == *"_bmad/"* ]]
}

@test "baseline: .gitleaks.toml FAILS LOUD when standards/gitleaks.toml is absent" {
  # No fixture written; empty gh stub blocks the network fallback so the general
  # fetch:<path> source must fail loud, not emit empty (it exists in the live repo).
  _stub_gh_empty
  run bash "$SEED" --emit-baseline .gitleaks.toml
  [ "$status" -ne 0 ]
  [[ "$output" == *"standards/gitleaks.toml"* ]]
}

# ── dependabot baseline is sourced from the chosen standards/ stack template ───
@test "baseline: dependabot.yml comes from the chosen standards/dependabot stack" {
  printf 'version: 2\nupdates:\n  - package-ecosystem: npm\n' \
    > "$STANDARDS_DIR/standards/dependabot/frontend.yml"
  run env DEPENDABOT_STACK=frontend bash "$SEED" --emit-baseline .github/dependabot.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"package-ecosystem: npm"* ]]
}

@test "baseline: dependabot.yml stack is a flat standards/dependabot/<stack>.yml file (not a subdir)" {
  # Regression guard (#966 follow-up): the canonical layout is flat files
  # (standards/dependabot/frontend.yml), NOT standards/dependabot/<stack>/dependabot.yml.
  printf 'version: 2\nupdates:\n  - package-ecosystem: gomod\n' \
    > "$STANDARDS_DIR/standards/dependabot/backend-go.yml"
  run env DEPENDABOT_STACK=backend-go bash "$SEED" --emit-baseline .github/dependabot.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"package-ecosystem: gomod"* ]]
}

@test "baseline: default DEPENDABOT_STACK is a real flat stack file (frontend)" {
  printf 'version: 2\nupdates:\n  - package-ecosystem: npm\n' \
    > "$STANDARDS_DIR/standards/dependabot/frontend.yml"
  run bash "$SEED" --emit-baseline .github/dependabot.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"package-ecosystem: npm"* ]]
}

@test "baseline: FAILS LOUD when the chosen dependabot stack file is absent" {
  # No fixture written → the fetch must fail non-zero, never ship an empty file.
  _stub_gh_empty
  run env DEPENDABOT_STACK=frontend bash "$SEED" --emit-baseline .github/dependabot.yml
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not fetch standards/dependabot/frontend.yml"* ]]
}

# ── seeding orchestration: DRY_RUN ────────────────────────────────────────────
@test "DRY_RUN: exits 0, names the target repo, makes no write API calls" {
  _stub_gh
  printf 'name: CI\n' | _fixture_workflow ci.yml
  printf 'name: Auto\n  uses: ./.github/workflows/auto-rebase-reusable.yml@auto-rebase/next\n' \
    | _fixture_workflow auto-rebase.yml
  run env DRY_RUN=true bash "$SEED" --repo combsmith/repo-template
  [ "$status" -eq 0 ]
  [[ "$output" == *"combsmith/repo-template"* ]]
  [ ! -f "$CALLS" ]
}

@test "seeding: writes workflow stubs and baseline files cross-repo via contents PUT" {
  _stub_gh
  for n in "${EXPECTED_STUBS[@]}"; do
    if printf '%s\n' "${INLINE_STUBS[@]}" | grep -qx "$n"; then
      printf 'name: %s\n' "$n" | _fixture_workflow "$n.yml"
    else
      printf '  uses: ./.github/workflows/%s-reusable.yml@%s/next\n' "$n" "$n" \
        | _fixture_workflow "$n.yml"
    fi
  done
  printf 'version: 2\n' > "$STANDARDS_DIR/standards/dependabot/frontend.yml"
  printf 'title = "gitleaks config"\n' > "$STANDARDS_DIR/standards/gitleaks.toml"
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo combsmith/repo-template
  [ "$status" -eq 0 ]
  [ -f "$CALLS" ]
  grep -q "contents/.github/workflows/auto-rebase.yml" "$CALLS"
  grep -q "contents/.github/CODEOWNERS" "$CALLS"
  grep -q "contents/.gitleaks.toml" "$CALLS"
  grep -q "pr create" "$CALLS"
}

@test "seeding: skips pr create when a PR already exists for the branch" {
  cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"--method POST"*|*"--method PUT"*|*"PATCH"*) echo "\$args" >> "$CALLS"; echo '{}' ;;
  *"pr list"*) echo '42' ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$STUB_BIN/gh"
  for n in "${EXPECTED_STUBS[@]}"; do
    if printf '%s\n' "${INLINE_STUBS[@]}" | grep -qx "$n"; then
      printf 'name: %s\n' "$n" | _fixture_workflow "$n.yml"
    else
      printf '  uses: ./.github/workflows/%s-reusable.yml@%s/next\n' "$n" "$n" \
        | _fixture_workflow "$n.yml"
    fi
  done
  printf 'version: 2\n' > "$STANDARDS_DIR/standards/dependabot/frontend.yml"
  printf 'title = "gitleaks config"\n' > "$STANDARDS_DIR/standards/gitleaks.toml"
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo combsmith/repo-template
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #42 already open"* ]]
  [ ! -f "$CALLS" ] || ! grep -q "pr create" "$CALLS"
}

# ── argument handling ─────────────────────────────────────────────────────────
@test "errors on a malformed --repo value (not owner/name)" {
  _stub_gh
  run bash "$SEED" --repo not-a-slug
  [ "$status" -ne 0 ]
}

@test "errors on an unknown workflow name to --repin" {
  run bash -c 'printf "x\n" | bash "$0" --repin no-such-stub' "$SEED"
  [ "$status" -ne 0 ]
}
