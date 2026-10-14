#!/usr/bin/env bats
# Unit tests for scripts/seed-repo-template.sh — the DRY_RUN-aware generator that
# seeds petry-projects/repo-template with the org baseline file scaffold:
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

# The published channel a caller stub is repinned to is DERIVED from the canonical
# stub's own major-scoped `uses:` ref (`<name>/v<MAJOR>-stable`, #1184) rather than
# read from a hardcoded table — so a future channel promotion (e.g. v2 → v3) cannot
# reintroduce the pre-#1184 skew fixed in #1436. These tests therefore assert against
# the derived major-scoped channel, and exercise the script's own
# `_derive_stable_channel` helper directly where the derivation itself is under test.

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

# gh stub for the STANDARDS_REF pinning tests (#1448): records every call to
# $CALLS, resolves the published channel commit for <exists-ref> (default
# standards/v1-stable), 404s any other /commits/ ref, and returns a base64
# caller-stub body for /contents/ reads so the emit/repin path stays valid.
_stub_gh_ref_recorder() { # [exists-commit-ref]
  local exists="${1:-standards/v1-stable}"
  cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\$*" in
  *"/commits/${exists}"*) echo "cafef00d00000000000000000000000000000000" ;;
  *"/commits/"*) exit 0 ;;
  *"/contents/"*) printf '%s' "\$(printf '    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-next\n' | base64 -w0 2>/dev/null || printf '    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-next\n' | base64)" ;;
  *) echo '' ;;
esac
EOF
  chmod +x "$STUB_BIN/gh"
}

# Drop every standards/ fixture the full seed loop needs (all 10 workflow stubs,
# the frontend dependabot stack, gitleaks) so the ownership-aware seed can emit
# each file. Mirrors the seeding-orchestration setup.
_drop_all_standards_fixtures() {
  local n
  for n in "${EXPECTED_STUBS[@]}"; do
    if printf '%s\n' "${INLINE_STUBS[@]}" | grep -qx "$n"; then
      printf 'name: %s\n' "$n" | _fixture_workflow "$n.yml"
    else
      printf '  uses: ./.github/workflows/%s-reusable.yml@%s/v2-next\n' "$n" "$n" \
        | _fixture_workflow "$n.yml"
    fi
  done
  printf 'version: 2\n' > "$STANDARDS_DIR/standards/dependabot/frontend.yml"
  printf 'title = "gitleaks config"\n' > "$STANDARDS_DIR/standards/gitleaks.toml"
}

# gh stub that serves pre-set "existing" file contents for the target repo's
# contents READS (so the ownership-aware seeder can decide CREATE/PRESERVE/WRITE),
# and logs every WRITE (PUT/POST/pr create) to $CALLS. Existing contents are given
# as "path=contentfile" pairs; a read for a path with no fixture returns {} (the
# absent shape → the seeder treats the file as new). The write cases are ordered
# BEFORE the contents-read cases so a PUT to a served path is logged, not served.
_stub_gh_existing() { # <path1> <file1> [<path2> <file2> ...]
  {
    echo '#!/usr/bin/env bash'
    echo 'args="$*"'
    echo 'case "$args" in'
    echo "  *\"--method PUT\"*|*\"--method POST\"*|*\"PATCH\"*|*\"pr create\"*) echo \"\$args\" >> \"$CALLS\"; echo '{}' ;;"
    echo '  *"pr list"*) ;;'
    while [ $# -ge 2 ]; do
      local p="$1" f="$2"; shift 2
      local b64; b64="$(base64 -w0 < "$f" 2>/dev/null || base64 < "$f")"
      echo "  *\"contents/${p}?\"*|*\"contents/${p} \"*|*\"contents/${p}\") echo '{\"sha\":\"feedface\",\"content\":\"${b64}\"}' ;;"
    done
    echo "  *) echo '{}' ;;"
    echo 'esac'
  } > "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
}

# ── #1448: standards content is fetched at an explicit, logged ref ─────────────
@test "print-ref: STANDARDS_DIR local override short-circuits resolution (no network)" {
  # setup() exports STANDARDS_DIR → the local-checkout seam is used, resolution
  # never hits the network. The retained test override (issue #1448 step 2).
  _stub_gh_empty
  run bash "$SEED" --print-ref
  [ "$status" -eq 0 ]
  [[ "$output" == *"STANDARDS_DIR"* || "$output" == *"local"* ]]
}

@test "print-ref: defaults to the published stable channel when it exists (AC #7)" {
  unset STANDARDS_DIR
  _stub_gh_ref_recorder standards/v1-stable
  run bash "$SEED" --print-ref
  [ "$status" -eq 0 ]
  [[ "$output" == *"standards/v1-stable"* ]]
  [[ "$output" == *"cafef00d"* ]]          # resolved commit SHA recorded (AC #7)
  [[ "$output" == *"channel"* ]]
}

@test "print-ref: STANDARDS_REF overrides resolution with an explicit pin (AC #7)" {
  unset STANDARDS_DIR
  _stub_gh_ref_recorder standards/v9-stable
  run env STANDARDS_REF="standards/v2-stable" bash "$SEED" --print-ref
  [ "$status" -eq 0 ]
  [[ "$output" == *"standards/v2-stable"* ]]
  [[ "$output" == *"explicit"* ]]
}

@test "print-ref: HEAD fallback logs the resolved commit SHA when the channel is absent (AC #10)" {
  # step-1 prerequisite (corpus channel) not yet published → the fetch stays on
  # HEAD but resolves + reports the commit SHA so runs remain explainable.
  unset STANDARDS_DIR
  cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/commits/standards/v1-stable"*) exit 0 ;;               # channel not published
  *"/commits/HEAD"*) echo "abc123def4567890000000000000000000000000" ;;
  *) echo '' ;;
esac
EOF
  chmod +x "$STUB_BIN/gh"
  run bash "$SEED" --print-ref
  [ "$status" -eq 0 ]
  [[ "$output" == *"abc123def456"* ]]        # HEAD commit SHA is resolved + logged
  [[ "$output" == *"head-fallback"* ]]
}

@test "emit-workflow: fetches standards at the pinned ref, never unpinned (AC #7)" {
  unset STANDARDS_DIR
  _stub_gh_ref_recorder standards/v1-stable
  run env STANDARDS_REF="standards/v1-stable" bash "$SEED" --emit-workflow ci.yml
  [ "$status" -eq 0 ]
  # every standards contents read carries an explicit ref — never an unpinned
  # default-branch read (the #1448 defect at seed-repo-template.sh:116).
  grep -q "contents/standards/workflows/ci.yml" "$CALLS"
  grep "contents/standards/workflows/ci.yml" "$CALLS" | grep -q "ref=standards/v1-stable"
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

# ── repin: caller stubs → published major-scoped channel tags (AC #1, #2) ──────
@test "repin: public caller dogfood ref → major-scoped @<name>/v<MAJOR>-stable on petry-projects/.github" {
  run bash -c 'printf "%s\n" "    uses: ./.github/workflows/auto-rebase-reusable.yml@auto-rebase/v2-next" | bash "$0" --repin auto-rebase' "$SEED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uses: petry-projects/.github/.github/workflows/auto-rebase-reusable.yml@auto-rebase/v2-stable"* ]]
  [[ "$output" != *"./.github/workflows/auto-rebase-reusable.yml"* ]]
  [[ "$output" != *"auto-rebase/v2-next"* ]]
  # AC #1: never the pre-#1184 legacy non-major-scoped channel.
  [[ "$output" != *"@auto-rebase/stable"* ]]
}

@test "repin: private dev-lead → @dev-lead/v<MAJOR>-stable on .github-private and agent_ref repinned" {
  src=$'    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-next\n    with:\n      agent_ref: dev-lead/v1-next'
  run bash -c 'printf "%s\n" "$1" | bash "$0" --repin dev-lead' "$SEED" "$src"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-stable"* ]]
  [[ "$output" == *"agent_ref: dev-lead/v1-stable"* ]]
  [[ "$output" != *"dev-lead/v1-next"* ]]
  [[ "$output" != *"@dev-lead/stable"* ]]
}

@test "repin: NO shipped caller stub retains a ./… dogfood ref, a /next channel, or a legacy non-major-scoped pin" {
  # The derived channel preserves whatever major the canonical stub carries and
  # flips the tier to stable; v3 here is arbitrary, proving the derivation tracks
  # the stub's own major line rather than a hardcoded per-stub channel.
  for name in "${CALLER_STUBS[@]}"; do
    src="    uses: ./.github/workflows/${name}-reusable.yml@${name}/v3-next"
    run bash -c 'printf "%s\n" "$1" | bash "$0" --repin "$2"' "$SEED" "$src" "$name"
    [ "$status" -eq 0 ]
    [[ "$output" != *"./.github/workflows/${name}-reusable.yml"* ]] \
      || { echo "$name still has ./ ref" >&2; false; }
    [[ "$output" != *"${name}/v3-next"* ]] \
      || { echo "$name still has the dogfood /next channel" >&2; false; }
    [[ "$output" == *"${name}-reusable.yml@${name}/v3-stable"* ]] \
      || { echo "$name not repinned to its derived major-scoped stable channel" >&2; false; }
    # AC #1: never the pre-#1184 legacy non-major-scoped <name>/stable.
    [[ "$output" != *"@${name}/stable"* ]] \
      || { echo "$name emitted the legacy non-major-scoped channel" >&2; false; }
  done
}

# AC #2/#4: the repin channel is DERIVED from the canonical stub's own ref.
@test "_derive_stable_channel: preserves the major line and flips the tier to stable" {
  source "$SEED"
  # dogfood next tier → published stable tier, same major.
  got="$(printf '%s\n' '    uses: x/dev-lead-reusable.yml@dev-lead/v1-next' | _derive_stable_channel dev-lead)"
  [ "$got" = "dev-lead/v1-stable" ]
  # already-stable major-scoped pin → unchanged.
  got="$(printf '%s\n' '    uses: x/agent-shield-reusable.yml@agent-shield/v2-stable' | _derive_stable_channel agent-shield)"
  [ "$got" = "agent-shield/v2-stable" ]
  # a different major is preserved verbatim.
  got="$(printf '%s\n' '    uses: x/pr-review-mention-reusable.yml@pr-review-mention/v7-next' | _derive_stable_channel pr-review-mention)"
  [ "$got" = "pr-review-mention/v7-stable" ]
}

# AC #13 (#1493): a canonical stub ALREADY pinned @<name>/v<MAJOR>-stable must round-trip
# through the generator UNCHANGED — the repin is idempotent and can never reintroduce a
# legacy bare-tier <name>/stable pin. Supersedes #1436 AC #5 (the guard #1448 references).
@test "repin round-trip: a canonical @<name>/v<MAJOR>-stable stub is unchanged (#1493 AC 13)" {
  for name in "${CALLER_STUBS[@]}"; do
    # Multi-line stub so the round-trip covers surrounding context, not just the uses: line.
    host="petry-projects/.github"
    [ "$name" = "dev-lead" ] && host="petry-projects/.github-private"
    src=$'jobs:\n  call:\n    uses: '"${host}/.github/workflows/${name}-reusable.yml@${name}/v1-stable"$'\n    with:\n      agent_ref: '"${name}/v1-stable"
    run bash -c 'printf "%s" "$1" | bash "$0" --repin "$2"' "$SEED" "$src" "$name"
    [ "$status" -eq 0 ]
    # Byte-for-byte identical: canonical in → canonical out (idempotent).
    [ "$output" = "$src" ] \
      || { echo "$name: canonical stub was mutated by round-trip" >&2; printf 'IN:\n%s\nOUT:\n%s\n' "$src" "$output" >&2; false; }
    # And it certainly must not have become the pre-#1184 legacy bare-tier pin.
    [[ "$output" != *"@${name}/stable"* ]] \
      || { echo "$name: round-trip emitted legacy bare-tier channel" >&2; false; }
  done
}

@test "_derive_stable_channel: FAILS LOUD on a legacy non-major-scoped ref (no v<MAJOR> to preserve)" {
  # A canonical stub that is NOT major-scoped is itself a standards violation
  # (#1184); the derivation must error rather than silently emit a legacy pin.
  run bash -c 'source "$0"; printf "%s\n" "    uses: x/agent-shield-reusable.yml@agent-shield/stable" | _derive_stable_channel agent-shield' "$SEED"
  [ "$status" -ne 0 ]
}

# ── emit-workflow: fetch byte-identical, repin callers, pass inline through ────
@test "emit-workflow: inline workflow ships byte-identically (no mutation)" {
  printf 'name: CI\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n' \
    | _fixture_workflow ci.yml
  run bash "$SEED" --emit-workflow ci.yml
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$STANDARDS_DIR/standards/workflows/ci.yml")" ]
}

@test "emit-workflow: caller stub fetched from standards is repinned to its derived major-scoped channel" {
  printf '%s\n' 'jobs:' '  run:' \
    '    uses: ./.github/workflows/dependency-audit-reusable.yml@dependency-audit/v2-next' \
    | _fixture_workflow dependency-audit.yml
  run bash "$SEED" --emit-workflow dependency-audit.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"uses: petry-projects/.github/.github/workflows/dependency-audit-reusable.yml@dependency-audit/v2-stable"* ]]
  [[ "$output" != *"./.github/workflows/dependency-audit-reusable.yml"* ]]
  [[ "$output" != *"@dependency-audit/stable"* ]]
}

@test "emit-workflow: AC#4 regression — a canonical @<name>/v<MAJOR>-stable pin is emitted verbatim, NOT rewritten to legacy @<name>/stable" {
  # #1436: the pre-#1184 hardcoded table took the CORRECT major-scoped canonical
  # pin and rewrote it to legacy <name>/stable, so template-drift's expected
  # baseline contradicted standards/ and reported the correct template as DRIFTED.
  # The repin must reproduce the canonical major-scoped stable pin byte-for-byte.
  printf '%s\n' 'jobs:' '  run:' \
    '    uses: petry-projects/.github/.github/workflows/agent-shield-reusable.yml@agent-shield/v2-stable' \
    | _fixture_workflow agent-shield.yml
  run bash "$SEED" --emit-workflow agent-shield.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"@agent-shield/v2-stable"* ]]
  [[ "$output" != *"@agent-shield/stable"* ]]
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
  local emitted="$BATS_TEST_TMPDIR/sonarcloud.yml"
  run bash -c 'bash "$1" --emit-workflow sonarcloud.yml > "$2"' _ "$SEED" "$emitted"
  [ "$status" -eq 0 ]
  cmp -s "$emitted" "$STANDARDS_DIR/standards/workflows/sonarcloud.yml"
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

@test "emit-workflow: FAILS LOUD when gh api returns a non-empty 404 JSON body (exits non-zero)" {
  # Regression guard for the #1448 defect observed in CI: when fetching a file that
  # does not exist at the pinned standards ref, gh api writes the 404 JSON body to
  # stdout AND exits non-zero. A naive `content="$(gh api ...)" || true` captures the
  # non-empty JSON and bypasses the empty-content guard, using the error body as the
  # "expected" content. The corrected `|| content=""` must clear content so the guard
  # catches it and the emit fails loud rather than silently shipping the 404 body.
  unset STANDARDS_DIR
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/repos/contents","status":"404"}'
exit 1
GHEOF
  chmod +x "$STUB_BIN/gh"
  run bash "$SEED" --emit-workflow sonarcloud.yml
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not fetch standards/workflows/sonarcloud.yml"* ]]
  # Must NOT have shipped the raw 404 JSON body as workflow content.
  [[ "$output" != *'"message":"Not Found"'* ]]
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
  [[ "$output" == *"* @petry-projects/org-leads"* ]]
}

@test "baseline: AGENTS.md is a consumer pointer to the org AGENTS.md" {
  run bash "$SEED" --emit-baseline AGENTS.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"petry-projects/.github"* ]]
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

@test "baseline: BOOTSTRAP.md documents per-repo advisory-review-bot enablement (Gemini Developer Connect + Codex)" {
  run bash "$SEED" --emit-baseline BOOTSTRAP.md
  [ "$status" -eq 0 ]
  # Gemini reviews are gated by Developer Connect repo linking, not the GitHub App grant.
  [[ "$output" == *"Gemini"* ]]
  [[ "$output" == *"Developer Connect"* ]]
  [[ "$output" == *"Link Repositories"* ]]
  # Codex connector needs per-repo review enablement too.
  [[ "$output" == *"Codex"* ]]
  # And a concrete verification step.
  [[ "$output" == *"/gemini review"* ]]
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

@test "baseline: .gitleaks.toml FAILS LOUD when gh api returns a non-empty 404 JSON body (exits non-zero)" {
  # Regression guard for the #1448 defect observed in CI: gh api returns a 404 JSON
  # body to stdout AND exits non-zero when the file doesn't exist at the pinned ref.
  # `content="$(gh api ...)" || content=""` must clear content so the empty-guard fires.
  unset STANDARDS_DIR
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/repos/contents","status":"404"}'
exit 1
GHEOF
  chmod +x "$STUB_BIN/gh"
  run bash "$SEED" --emit-baseline .gitleaks.toml
  [ "$status" -ne 0 ]
  [[ "$output" == *"gitleaks.toml"* ]]
  [[ "$output" != *'"message":"Not Found"'* ]]
}

@test "baseline: dependabot.yml FAILS LOUD when gh api returns a non-empty 404 JSON body (exits non-zero)" {
  # Same regression: the Dependabot special-case path uses `_fetch_standard` too.
  unset STANDARDS_DIR
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/repos/contents","status":"404"}'
exit 1
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env DEPENDABOT_STACK=frontend bash "$SEED" --emit-baseline .github/dependabot.yml
  [ "$status" -ne 0 ]
  [[ "$output" == *"dependabot"* || "$output" == *"frontend"* ]]
  [[ "$output" != *'"message":"Not Found"'* ]]
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

# ── #1435: Dependabot must not bump the byte-identity workflow artifacts ───────
# repo-template's shipped workflows are a distribution artifact of standards/ and
# are kept current by re-seeding, not by Dependabot. A github-actions Dependabot
# run in the template edits those artifacts directly and drifts template-drift.
# The seed therefore scopes the github-actions package-ecosystem out of the
# shipped .github/dependabot.yml; other ecosystems (npm/gomod/…) pass through.
@test "scope-out: removes the github-actions ecosystem, keeps npm (#1435)" {
  source "$SEED"
  out="$(printf '%s\n' \
    'version: 2' \
    'updates:' \
    '  - package-ecosystem: "github-actions"' \
    '    directory: "/"' \
    '    schedule:' \
    '      interval: weekly' \
    '  - package-ecosystem: "npm"' \
    '    directory: "/"' \
    | _dependabot_scope_out_actions)"
  [[ "$out" != *"github-actions"* ]]
  [[ "$out" == *"package-ecosystem: \"npm\""* ]]
  [[ "$out" == *"version: 2"* ]]
}

@test "scope-out: removes a github-actions block that is LAST in the list (#1435)" {
  source "$SEED"
  out="$(printf '%s\n' \
    'version: 2' \
    'updates:' \
    '  - package-ecosystem: gomod' \
    '    directory: "/"' \
    '  - package-ecosystem: github-actions' \
    '    directory: "/"' \
    '    open-pull-requests-limit: 10' \
    | _dependabot_scope_out_actions)"
  [[ "$out" != *"github-actions"* ]]
  [[ "$out" != *"open-pull-requests-limit"* ]]   # its child lines go too
  [[ "$out" == *"package-ecosystem: gomod"* ]]
}

@test "scope-out: removes a github-actions block in the MIDDLE, keeps both siblings (#1435)" {
  source "$SEED"
  out="$(printf '%s\n' \
    'updates:' \
    '  - package-ecosystem: npm' \
    '  - package-ecosystem: github-actions' \
    '    directory: "/"' \
    '  - package-ecosystem: pip' \
    | _dependabot_scope_out_actions)"
  [[ "$out" != *"github-actions"* ]]
  [[ "$out" == *"package-ecosystem: npm"* ]]
  [[ "$out" == *"package-ecosystem: pip"* ]]
}

@test "scope-out: discards the dropped block's leading comment (#1435)" {
  source "$SEED"
  out="$(printf '%s\n' \
    'updates:' \
    '  # GitHub Actions — version updates (keep actions current)' \
    '  - package-ecosystem: "github-actions"' \
    '    directory: "/"' \
    '  # npm deps' \
    '  - package-ecosystem: "npm"' \
    | _dependabot_scope_out_actions)"
  [[ "$out" != *"GitHub Actions"* ]]            # the block's own comment is gone
  [[ "$out" == *"# npm deps"* ]]                # a kept block keeps its comment
  [[ "$out" == *"package-ecosystem: \"npm\""* ]]
}

@test "scope-out: a standalone comment inside the dropped block does not leak (#1435)" {
  source "$SEED"
  out="$(printf '%s\n' \
    'updates:' \
    '  - package-ecosystem: "github-actions"' \
    '    directory: "/"' \
    '    # inline note that belongs to the dropped block' \
    '    schedule:' \
    '      interval: weekly' \
    '  - package-ecosystem: "npm"' \
    | _dependabot_scope_out_actions)"
  [[ "$out" != *"github-actions"* ]]
  [[ "$out" != *"inline note"* ]]                 # the mid-block comment is dropped too
  [[ "$out" == *"package-ecosystem: \"npm\""* ]]
}

@test "scope-out: a config with no github-actions passes through unchanged (#1435)" {
  source "$SEED"
  in="$(printf '%s\n' 'version: 2' 'updates:' '  - package-ecosystem: npm' '    directory: "/"')"
  out="$(printf '%s' "$in" | _dependabot_scope_out_actions)"
  [ "$out" = "$in" ]
}

@test "scope-out: keeps subsequent top-level keys after a dropped block (#1435)" {
  source "$SEED"
  out="$(printf '%s\n' \
    'updates:' \
    '  - package-ecosystem: github-actions' \
    '    directory: "/"' \
    'registries:' \
    '  some-registry:' \
    '    type: docker-registry' \
    | _dependabot_scope_out_actions)"
  [[ "$out" != *"github-actions"* ]]
  [[ "$out" == *"registries:"* ]]
  [[ "$out" == *"some-registry:"* ]]
}

@test "scope-out: preserves trailing comments at the end of the file (#1435)" {
  source "$SEED"
  out="$(printf '%s\n' \
    'updates:' \
    '  - package-ecosystem: npm' \
    '# trailing comment' \
    | _dependabot_scope_out_actions)"
  [[ "$out" == *"# trailing comment"* ]]
}

@test "baseline: emitted dependabot.yml ships with github-actions scoped out (#1435)" {
  cat > "$STANDARDS_DIR/standards/dependabot/frontend.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: weekly
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: weekly
EOF
  run env DEPENDABOT_STACK=frontend bash "$SEED" --emit-baseline .github/dependabot.yml
  [ "$status" -eq 0 ]
  [[ "$output" != *"github-actions"* ]]
  [[ "$output" == *"package-ecosystem: \"npm\""* ]]
}

# ── seeding orchestration: DRY_RUN ────────────────────────────────────────────
@test "DRY_RUN: exits 0, names the target repo, makes no write API calls" {
  # Dry-run now PLANS each file (reads current content, reports intent) so it needs
  # the same standards fixtures the live seed does — but still makes zero writes.
  _stub_gh
  _drop_all_standards_fixtures
  run env DEPENDABOT_STACK=frontend DRY_RUN=true bash "$SEED" --repo petry-projects/repo-template
  [ "$status" -eq 0 ]
  [[ "$output" == *"petry-projects/repo-template"* ]]
  [ ! -f "$CALLS" ]
}

@test "seeding: writes workflow stubs and baseline files cross-repo via contents PUT" {
  _stub_gh
  for n in "${EXPECTED_STUBS[@]}"; do
    if printf '%s\n' "${INLINE_STUBS[@]}" | grep -qx "$n"; then
      printf 'name: %s\n' "$n" | _fixture_workflow "$n.yml"
    else
      printf '  uses: ./.github/workflows/%s-reusable.yml@%s/v2-next\n' "$n" "$n" \
        | _fixture_workflow "$n.yml"
    fi
  done
  printf 'version: 2\n' > "$STANDARDS_DIR/standards/dependabot/frontend.yml"
  printf 'title = "gitleaks config"\n' > "$STANDARDS_DIR/standards/gitleaks.toml"
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo petry-projects/repo-template
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
      printf '  uses: ./.github/workflows/%s-reusable.yml@%s/v2-next\n' "$n" "$n" \
        | _fixture_workflow "$n.yml"
    fi
  done
  printf 'version: 2\n' > "$STANDARDS_DIR/standards/dependabot/frontend.yml"
  printf 'title = "gitleaks config"\n' > "$STANDARDS_DIR/standards/gitleaks.toml"
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo petry-projects/repo-template
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #42 already open"* ]]
  [ ! -f "$CALLS" ] || ! grep -q "pr create" "$CALLS"
}

# ── #1812: ownership-aware seeding — never destroy files it does not own ───────

# The org secrets baseline that a separate .github sync owns (gitignore-standard
# L1). Its managed-block marker must make the seeder leave the file alone.
_managed_gitignore_fixture() { # -> path of a fixture file on stdout
  local f="$BATS_TEST_TMPDIR/existing_gitignore"
  {
    echo '# >>> BEGIN petry-projects secrets baseline (managed by .github — do not edit) >>>'
    echo '# First layer of defense in the Push Protection Standard.'
    echo '.env'
    echo '*.pem'
    echo 'id_rsa'
    echo '# <<< END petry-projects secrets baseline <<<'
  } > "$f"
  printf '%s' "$f"
}

@test "AC#1: seeding a repo whose .gitignore carries the managed marker PRESERVES it (no PUT)" {
  set -e
  _drop_all_standards_fixtures
  local gi; gi="$(_managed_gitignore_fixture)"
  _stub_gh_existing ".gitignore" "$gi"
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo petry-projects/repo-template
  [ "$status" -eq 0 ]
  # The preservation is reported by name + reason (check $output before `run grep`).
  [[ "$output" == *".gitignore"* ]]
  [[ "$output" == *"managed"* || "$output" == *"PRESERV"* ]]
  [ -f "$CALLS" ]
  # Files the seeder DOES own are still written.
  grep -qF "contents/.github/CODEOWNERS" "$CALLS"
  # The managed .gitignore is NEVER written — no contents PUT touches it.
  run grep -qF "contents/.gitignore" "$CALLS"
  [ "$status" -eq 1 ]
}

@test "AC#2: seeding a repo whose ci.yml already exists (drift-allowlisted) leaves it UNTOUCHED" {
  set -e
  _drop_all_standards_fixtures
  local ci="$BATS_TEST_TMPDIR/existing_ci"
  printf 'name: CI\n# customized per stack by the consumer\njobs:\n  build:\n    runs-on: ubuntu-latest\n' > "$ci"
  _stub_gh_existing ".github/workflows/ci.yml" "$ci"
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo petry-projects/repo-template
  [ "$status" -eq 0 ]
  [[ "$output" == *"ci.yml"* ]]
  [ -f "$CALLS" ]
  # A non-allowlisted workflow is still seeded.
  grep -qF "contents/.github/workflows/auto-rebase.yml" "$CALLS"
  # ci.yml is on TEMPLATE_DRIFT_ALLOWLIST → the seeder must not overwrite it.
  run grep -qF "contents/.github/workflows/ci.yml" "$CALLS"
  [ "$status" -eq 1 ]
}

@test "AC#2: the allowlist is DERIVED from template_stub_drift.sh, not a second literal" {
  set -e
  # Sourcing the seeder must make the drift checker's allowlist helper available —
  # proof the single source is consumed, not copied.
  source "$SEED"
  run template_drift_allowlisted ".github/workflows/ci.yml"
  [ "$status" -eq 0 ]
  # And the seeder must NOT declare its own copy of the list (the exact drift this
  # script pair already demonstrates).
  run grep -q 'TEMPLATE_DRIFT_ALLOWLIST=(' "$SEED"
  [ "$status" -eq 1 ]
}

@test "AC#1: fresh repo (files absent) STILL creates .gitignore and ci.yml" {
  set -e
  # Ownership-awareness must not degrade to deletion — a brand-new repo needs both.
  _drop_all_standards_fixtures
  _stub_gh   # every contents read returns {} → absent → create
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo petry-projects/repo-template
  [ "$status" -eq 0 ]
  [ -f "$CALLS" ]
  grep -qF "contents/.gitignore" "$CALLS"
  grep -qF "contents/.github/workflows/ci.yml" "$CALLS"
}

@test "AC#3: _seed_file is a NO-OP when unchanged and writes when content differs" {
  set -e
  source "$SEED"
  local out="$BATS_TEST_TMPDIR/existing"; printf 'same-bytes\n' > "$out"
  _stub_gh_existing "docs/x.txt" "$out"
  # Unchanged: existing == new content → no write, reported as unchanged.
  run _seed_file petry-projects/repo-template "docs/x.txt" "$(printf 'same-bytes\n')" seed-branch main
  [ "$status" -eq 0 ]
  [[ "$output" == *"unchanged"* || "$output" == *"preserv"* ]]
  if [ -f "$CALLS" ]; then
    run grep -qF "docs/x.txt" "$CALLS"
    [ "$status" -eq 1 ]
  fi
  # Differing: existing != new content → a write happens.
  run _seed_file petry-projects/repo-template "docs/x.txt" "$(printf 'new-bytes\n')" seed-branch main
  [ "$status" -eq 0 ]
  grep -qF "contents/docs/x.txt" "$CALLS"
}

@test "AC#4: DRY_RUN reports the managed .gitignore would be PRESERVED, not silently replaced" {
  set -e
  _drop_all_standards_fixtures
  local gi; gi="$(_managed_gitignore_fixture)"
  _stub_gh_existing ".gitignore" "$gi"
  run env DRY_RUN=true DEPENDABOT_STACK=frontend bash "$SEED" --repo petry-projects/repo-template
  [ "$status" -eq 0 ]
  # The destructive-avoidance is visible: named, with the managed reason.
  [[ "$output" == *".gitignore"* ]]
  [[ "$output" == *"managed"* ]]
  [[ "$output" == *"PRESERV"* || "$output" == *"NOT overwrit"* ]]
  # No writes under dry-run.
  [ ! -f "$CALLS" ]
}

@test "AC#1: a non-404 gh api failure on the contents read ABORTS, never CREATEs over an unreadable file" {
  set -e
  source "$SEED"
  # gh api writes a rate-limit/5xx body to stdout AND exits non-zero. Decoding that
  # as empty content would let _seed_file treat the file as absent and CREATE over
  # it; instead the read helper must fail loud and _seed_file must abort (#1812;
  # codeant/gemini review of #1868). Only a 404 body is a benign "absent".
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"--method PUT"*|*"--method POST"*|*"PATCH"*|*"pr create"*) echo "$args" >> "$CALLS"; echo '{}' ;;
  *"contents/"*) printf '{"message":"API rate limit exceeded","status":"403"}'; exit 1 ;;
  *) echo '{}' ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  run _existing_file_content petry-projects/repo-template docs/x.txt main
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh api failed"* ]]
  # _seed_file propagates the failure — no CREATE PUT for the unreadable file.
  run _seed_file petry-projects/repo-template docs/x.txt "$(printf 'new\n')" seed-branch main
  [ "$status" -ne 0 ]
  if [ -f "$CALLS" ]; then
    run grep -qF "contents/docs/x.txt" "$CALLS"
    [ "$status" -eq 1 ]
  fi
}

@test "AC#1: a genuine 404 on the contents read is treated as absent (empty content)" {
  set -e
  source "$SEED"
  # The one benign failure: a 404 body means the file is truly absent → empty content
  # (so a fresh repo still gets a CREATE), distinct from a masked hard failure.
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
exit 1
GHEOF
  chmod +x "$STUB_BIN/gh"
  run _existing_file_content petry-projects/repo-template docs/x.txt main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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
