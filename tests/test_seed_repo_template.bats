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
  *"/contents/"*) printf '%s' "\$(printf '    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-next\n' | base64 -w0 2>/dev/null || printf '    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-next\n' | base64)" ;;
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
@test "repin: public caller dogfood ref → major-scoped @<name>/v<MAJOR>-stable on combsmith/.github" {
  run bash -c 'printf "%s\n" "    uses: ./.github/workflows/auto-rebase-reusable.yml@auto-rebase/v2-next" | bash "$0" --repin auto-rebase' "$SEED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uses: combsmith/.github/.github/workflows/auto-rebase-reusable.yml@auto-rebase/v2-stable"* ]]
  [[ "$output" != *"./.github/workflows/auto-rebase-reusable.yml"* ]]
  [[ "$output" != *"auto-rebase/v2-next"* ]]
  # AC #1: never the pre-#1184 legacy non-major-scoped channel.
  [[ "$output" != *"@auto-rebase/stable"* ]]
}

@test "repin: private dev-lead → @dev-lead/v<MAJOR>-stable on .github-private and agent_ref repinned" {
  src=$'    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-next\n    with:\n      agent_ref: dev-lead/v1-next'
  run bash -c 'printf "%s\n" "$1" | bash "$0" --repin dev-lead' "$SEED" "$src"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-stable"* ]]
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
    host="combsmith/.github"
    [ "$name" = "dev-lead" ] && host="combsmith/.github-private"
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
  [[ "$output" == *"uses: combsmith/.github/.github/workflows/dependency-audit-reusable.yml@dependency-audit/v2-stable"* ]]
  [[ "$output" != *"./.github/workflows/dependency-audit-reusable.yml"* ]]
  [[ "$output" != *"@dependency-audit/stable"* ]]
}

@test "emit-workflow: AC#4 regression — a canonical @<name>/v<MAJOR>-stable pin is emitted verbatim, NOT rewritten to legacy @<name>/stable" {
  # #1436: the pre-#1184 hardcoded table took the CORRECT major-scoped canonical
  # pin and rewrote it to legacy <name>/stable, so template-drift's expected
  # baseline contradicted standards/ and reported the correct template as DRIFTED.
  # The repin must reproduce the canonical major-scoped stable pin byte-for-byte.
  printf '%s\n' 'jobs:' '  run:' \
    '    uses: combsmith/.github/.github/workflows/agent-shield-reusable.yml@agent-shield/v2-stable' \
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
  [[ "$output" == *"* @combsmith/org-leads"* ]]
}

@test "baseline: AGENTS.md points to the org AGENTS.md and carries the template-specific sections" {
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
  [[ "$output" == *"not seeded"* ]]
  [[ "$output" == *"on demand"* ]]
  # Q2: app installs (Claude/CodeRabbit) are a manual org-admin step, not done by bootstrap.
  [[ "$output" == *"Claude"* ]]
  [[ "$output" == *"CodeRabbit"* ]]
  [[ "$output" == *"org-level"* ]]
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
  run env DEPENDABOT_STACK=frontend DRY_RUN=true bash "$SEED" --repo combsmith/repo-template
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
      printf '  uses: ./.github/workflows/%s-reusable.yml@%s/v2-next\n' "$n" "$n" \
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
      printf '  uses: ./.github/workflows/%s-reusable.yml@%s/v2-next\n' "$n" "$n" \
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

# ── #1812: ownership-aware seeding — never destroy files it does not own ───────

# The org secrets baseline that a separate .github sync owns (gitignore-standard
# L1). Its managed-block marker must make the seeder leave the file alone.
_managed_gitignore_fixture() { # -> path of a fixture file on stdout
  local f="$BATS_TEST_TMPDIR/existing_gitignore"
  {
    echo '# >>> BEGIN combsmith secrets baseline (managed by .github — do not edit) >>>'
    echo '# First layer of defense in the Push Protection Standard.'
    echo '.env'
    echo '*.pem'
    echo 'id_rsa'
    echo '# <<< END combsmith secrets baseline <<<'
  } > "$f"
  printf '%s' "$f"
}

@test "AC#1: seeding a repo whose .gitignore carries the managed marker PRESERVES it (no PUT)" {
  set -e
  _drop_all_standards_fixtures
  local gi; gi="$(_managed_gitignore_fixture)"
  _stub_gh_existing ".gitignore" "$gi"
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo combsmith/repo-template
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
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo combsmith/repo-template
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
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo combsmith/repo-template
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
  run _seed_file combsmith/repo-template "docs/x.txt" "$(printf 'same-bytes\n')" seed-branch main
  [ "$status" -eq 0 ]
  [[ "$output" == *"unchanged"* || "$output" == *"preserv"* ]]
  if [ -f "$CALLS" ]; then
    run grep -qF "docs/x.txt" "$CALLS"
    [ "$status" -eq 1 ]
  fi
  # Differing: existing != new content → a write happens.
  run _seed_file combsmith/repo-template "docs/x.txt" "$(printf 'new-bytes\n')" seed-branch main
  [ "$status" -eq 0 ]
  grep -qF "contents/docs/x.txt" "$CALLS"
}

@test "AC#4: DRY_RUN reports the managed .gitignore would be PRESERVED, not silently replaced" {
  set -e
  _drop_all_standards_fixtures
  local gi; gi="$(_managed_gitignore_fixture)"
  _stub_gh_existing ".gitignore" "$gi"
  run env DRY_RUN=true DEPENDABOT_STACK=frontend bash "$SEED" --repo combsmith/repo-template
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
  run _existing_file_content combsmith/repo-template docs/x.txt main
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh api failed"* ]]
  # _seed_file propagates the failure — no CREATE PUT for the unreadable file.
  run _seed_file combsmith/repo-template docs/x.txt "$(printf 'new\n')" seed-branch main
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
  run _existing_file_content combsmith/repo-template docs/x.txt main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── #2233: commercial-support sections + one open seed PR per repo ─────────────
# Fixtures: standards/commercial-support-standard.md at standards/v1.2.0, and
# README.md / BOOTSTRAP.md / AGENTS.md from combsmith/repo-template main at 3e073f87 (#259).
SEED_FIXTURES="$SCRIPT_DIR/tests/fixtures/seed-repo-template"
# Git blob SHAs of those two repo-template files (guards the fixtures themselves
# against an editor/hook adding a trailing newline).
REPO_TEMPLATE_README_BLOB=a6b17a8c32f6181248e55a17f9254bb0480f0f3d
REPO_TEMPLATE_BOOTSTRAP_BLOB=18f42406609dcb019362fc012c2ffc70b5c8de43
REPO_TEMPLATE_AGENTS_BLOB=1c5e6cb3b131037b7a103ebf33c243fac9facd0c

_fixture_commercial_standard() {
  cp "$SEED_FIXTURES/commercial-support-standard.md" \
    "$STANDARDS_DIR/standards/commercial-support-standard.md"
}

# The canonical README block of a standard file, extracted independently of the
# seeder: the body of the ```markdown fence.
_standard_readme_block() { # <standard-file>
  sed -n '/^```markdown$/,/^```$/p' "$1" | sed '1d;$d'
}

# Blob SHA of content as the seeder writes it: the $()-capture drops trailing
# newlines and _put_file encodes it with printf '%s'.
_seeded_blob() { printf '%s' "$1" | git hash-object --stdin; }

@test "#2233: BOOTSTRAP.md emission is blob-identical to repo-template main (3e073f87)" {
  [ "$(git hash-object "$SEED_FIXTURES/repo-template-BOOTSTRAP.md")" = "$REPO_TEMPLATE_BOOTSTRAP_BLOB" ]
  run bash "$SEED" --emit-baseline BOOTSTRAP.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"## 10. Done criteria"* ]]
  [ "$(_seeded_blob "$output")" = "$REPO_TEMPLATE_BOOTSTRAP_BLOB" ]
}

@test "repo-template#253: AGENTS.md emission is blob-identical to repo-template main (3e073f87)" {
  [ "$(git hash-object "$SEED_FIXTURES/repo-template-AGENTS.md")" = "$REPO_TEMPLATE_AGENTS_BLOB" ]
  run bash "$SEED" --emit-baseline AGENTS.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Local Development Commands"* ]]
  [ "$(_seeded_blob "$output")" = "$REPO_TEMPLATE_AGENTS_BLOB" ]
}

@test "#2233: README.md keeps repo-template's preamble and appends the standard's canonical section" {
  [ "$(git hash-object "$SEED_FIXTURES/repo-template-README.md")" = "$REPO_TEMPLATE_README_BLOB" ]
  _stub_gh_empty
  _fixture_commercial_standard
  run bash "$SEED" --emit-baseline README.md
  [ "$status" -eq 0 ]
  # Everything on repo-template main before its commercial section, byte for byte.
  local preamble; preamble="$(sed '/^## Commercial Support/,$d' "$SEED_FIXTURES/repo-template-README.md")"
  [[ "$preamble" == *$'\n---' ]]
  [ "${output:0:${#preamble}}" = "$preamble" ]
  # …followed by one blank line and exactly the standard's canonical block.
  local block; block="$(_standard_readme_block "$STANDARDS_DIR/standards/commercial-support-standard.md")"
  [ -n "$block" ]
  [ "$output" = "${preamble}"$'\n\n'"${block}" ]
}

@test "#2233: README.md section is read from the standard, not a copy in the script" {
  _stub_gh_empty
  _fixture_commercial_standard
  sed -i -e 's/\$199\/month/$299\/month/' -e 's/^## 💼 Commercial Support.*/## Commercial Support (changed upstream)/' \
    "$STANDARDS_DIR/standards/commercial-support-standard.md"
  run bash "$SEED" --emit-baseline README.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Commercial Support (changed upstream)"* ]]
  [[ "$output" == *'$299/month'* ]]
  [[ "$output" != *'$199/month'* ]]
  [[ "$output" == *"$(_standard_readme_block "$STANDARDS_DIR/standards/commercial-support-standard.md")" ]]
}

@test "#2233: README.md FAILS LOUD when the commercial-support standard is absent" {
  _stub_gh_empty
  run bash "$SEED" --emit-baseline README.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"commercial-support-standard.md"* ]]
}

@test "#2233: README.md FAILS LOUD when the standard has no canonical README block" {
  _stub_gh_empty
  printf '# Commercial Support\n\n## Canonical README Section\n\nNo fence here.\n\n## Other\n' \
    > "$STANDARDS_DIR/standards/commercial-support-standard.md"
  run bash "$SEED" --emit-baseline README.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"Canonical README Section"* ]]
}

@test "#2233: a seed run whose commercial standard is unreadable leaves README.md untouched" {
  _stub_gh
  _drop_all_standards_fixtures
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo combsmith/repo-template
  [ "$status" -eq 0 ]
  [[ "$output" == *"README.md"* ]]
  grep -qF "contents/BOOTSTRAP.md" "$CALLS"
  run grep -qF "contents/README.md" "$CALLS"
  [ "$status" -eq 1 ]
}

# gh stub with an OPEN older seed PR (#17 on seed-scaffold/2026-10-01). Contents
# reads are served per ref from "<path>@<ref>=<file>" pairs; anything else reads
# as absent. Writes are logged to $CALLS.
_stub_gh_open_seed_pr() { # [<path>@<ref> <file> ...]
  {
    echo '#!/usr/bin/env bash'
    echo 'args="$*"'
    echo 'case "$args" in'
    echo "  *\"--method PUT\"*|*\"--method POST\"*|*\"PATCH\"*|*\"pr create\"*) echo \"\$args\" >> \"$CALLS\"; echo '{}' ;;"
    echo "  *\"pr list\"*\"--head seed-scaffold/2026-10-01\"*) echo 17 ;;"
    echo "  *\"pr list\"*\"headRefName\"*) printf '17\\tseed-scaffold/2026-10-01\\n' ;;"
    echo '  *"pr list"*) ;;'
    echo "  *\"git/ref/heads/\"*) echo basesha ;;"
    echo "  *\"repos/combsmith/repo-template --jq\"*) echo main ;;"
    while [ $# -ge 2 ]; do
      local p="${1%@*}" r="${1##*@}" f="$2"; shift 2
      local b64; b64="$(base64 -w0 < "$f" 2>/dev/null || base64 < "$f")"
      echo "  *\"contents/${p}?ref=${r}\"*) echo '{\"sha\":\"feedface\",\"content\":\"${b64}\"}' ;;"
    done
    echo "  *) echo '{}' ;;"
    echo 'esac'
  } > "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
}

@test "#2233: an open seed-scaffold/* PR is updated in place — no second PR, no new branch" {
  _drop_all_standards_fixtures
  _fixture_commercial_standard
  _stub_gh_open_seed_pr
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo combsmith/repo-template
  [ "$status" -eq 0 ]
  [[ "$output" == *"#17"* ]]
  [ -f "$CALLS" ]
  # Writes land on the existing PR's branch…
  grep -qF "contents/BOOTSTRAP.md" "$CALLS"
  grep -qF "branch=seed-scaffold/2026-10-01" "$CALLS"
  run grep -F "branch=seed-scaffold/$(date -u +%Y-%m-%d)" "$CALLS"
  [ "$status" -eq 1 ]
  # …no branch is created and no PR is opened.
  run grep -F "git/refs --method POST" "$CALLS"
  [ "$status" -eq 1 ]
  run grep -F "pr create" "$CALLS"
  [ "$status" -eq 1 ]
}

@test "#2233: updating an open seed PR restores files its branch changed but the fresh seed would not" {
  _drop_all_standards_fixtures
  _fixture_commercial_standard
  local current="$BATS_TEST_TMPDIR/codeowners" stale="$BATS_TEST_TMPDIR/stale" agents="$BATS_TEST_TMPDIR/agents"
  bash "$SEED" --emit-baseline .github/CODEOWNERS > "$current"
  bash "$SEED" --emit-baseline AGENTS.md > "$agents"
  printf '* @someone-else\n' > "$stale"
  # CODEOWNERS: main already matches the seed, but the old PR's branch changed it.
  # AGENTS.md: main and the branch both already match the seed.
  _stub_gh_open_seed_pr \
    ".github/CODEOWNERS@main" "$current" \
    ".github/CODEOWNERS@seed-scaffold/2026-10-01" "$stale" \
    "AGENTS.md@main" "$agents" \
    "AGENTS.md@seed-scaffold/2026-10-01" "$agents"
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo combsmith/repo-template
  [ "$status" -eq 0 ]
  grep -F "contents/.github/CODEOWNERS --method PUT" "$CALLS" | grep -qF "branch=seed-scaffold/2026-10-01"
  run grep -F "contents/AGENTS.md --method PUT" "$CALLS"
  [ "$status" -eq 1 ]
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

# ── #1925: seed PR provenance, supersede, and no downgrades ───────────────────

# gh stub for the seed-PR tests. Logs every write — including `pr edit`,
# `pr close` and a ref DELETE — to $CALLS. Open seed PRs come from $SEED_OPEN_PRS
# ("<number>\t<branch>" lines, oldest first); `pr create` prints a PR URL ending
# in $SEED_NEW_PR; `pr close <n>` fails when <n> is $SEED_CLOSE_FAILS.
_stub_gh_seed_prs() {
  export SEED_OPEN_PRS="${SEED_OPEN_PRS:-}" SEED_NEW_PR="${SEED_NEW_PR:-88}" SEED_CLOSE_FAILS="${SEED_CLOSE_FAILS:-}"
  cat > "$STUB_BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  "pr close "*)
    echo "$args" >> "$CALLS"
    [ "$2 $3" != "close $SEED_CLOSE_FAILS" ] || exit 1
    exit 0 ;;
  "pr edit "*) echo "$args" >> "$CALLS"; exit 0 ;;
  "pr create "*) echo "$args" >> "$CALLS"; echo "https://github.com/combsmith/repo-template/pull/$SEED_NEW_PR"; exit 0 ;;
  *"--method DELETE"*|*"--method PUT"*|*"--method POST"*) echo "$args" >> "$CALLS"; echo '{}' ;;
  *"pr list"*"--head "*)
    # The open PR for one branch: its number, or nothing.
    head="${args##*--head }"; head="${head%% *}"
    printf '%s\n' "$SEED_OPEN_PRS" | awk -F'\t' -v h="$head" '$2 == h { print $1 }' | tail -n 1 ;;
  *"pr list"*"headRefName"*) [ -z "$SEED_OPEN_PRS" ] || printf '%s\n' "$SEED_OPEN_PRS" ;;
  *"git/ref/heads/"*) echo basesha ;;
  *"repos/combsmith/repo-template --jq"*) echo main ;;
  *) echo '{}' ;;
esac
GHSTUB
  chmod +x "$STUB_BIN/gh"
}

@test "#1925 AC1: _seed_pr_body states the resolved ref, how it was chosen, and the commit" {
  source "$SEED"
  run _seed_pr_body "standards/v1-stable" "cafef00d00000000000000000000000000000000" "channel"
  [ "$status" -eq 0 ]
  [[ "$output" == *'**Resolved ref:** `standards/v1-stable`'* ]]
  [[ "$output" == *'**Source:** channel — the published standards channel `standards/v1-stable`'* ]]
  [[ "$output" == *'**Commit:** `cafef00d00000000000000000000000000000000`'* ]]
  [[ "$output" == *'<!-- seed-repo-template standards_ref=standards/v1-stable standards_sha=cafef00d00000000000000000000000000000000 source=channel -->'* ]]
  # No refused files → no "left alone" section.
  [[ "$output" != *"Left alone"* ]]
}

@test "#1925 AC1: each ref source is named in words (explicit, HEAD fallback, local)" {
  source "$SEED"
  [[ "$(_seed_source_label explicit)" == *'`STANDARDS_REF` was set'* ]]
  [[ "$(_seed_source_label head-fallback)" == *"HEAD fallback"*"not published"* ]]
  [[ "$(_seed_source_label local)" == *'`STANDARDS_DIR` checkout'* ]]
  run _seed_pr_body "STANDARDS_DIR" "" "local"
  [[ "$output" == *'**Commit:** `unknown`'* ]]
}

@test "#1925 AC3: _seed_pr_body lists the files left alone because the template is ahead" {
  source "$SEED"
  run _seed_pr_body "standards/v1-stable" "cafef00d" "channel" ".github/workflows/agent-shield.yml" "CLAUDE.md"
  [[ "$output" == *"## Left alone: the template is ahead of the channel"* ]]
  [[ "$output" == *'- `.github/workflows/agent-shield.yml`'* ]]
  [[ "$output" == *'- `CLAUDE.md`'* ]]
  [[ "$output" == *"promote standards"* ]]
}

@test "#1925 AC1: a new seed PR is opened with the standards provenance in its body" {
  _drop_all_standards_fixtures
  _fixture_commercial_standard
  _stub_gh_seed_prs
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo combsmith/repo-template
  [ "$status" -eq 0 ]
  [[ "$output" == *"opened seed PR #88"* ]]
  grep -qF "pr create --repo combsmith/repo-template" "$CALLS"
  grep -qF "Resolved ref:" "$CALLS"
  grep -qF "seed-repo-template standards_ref=STANDARDS_DIR" "$CALLS"
  grep -qF "source=local" "$CALLS"
}

@test "#1925 AC1: updating an open seed PR rewrites its body with this run's provenance" {
  _drop_all_standards_fixtures
  _fixture_commercial_standard
  export SEED_OPEN_PRS="$(printf '17\tseed-scaffold/2026-10-01')"
  _stub_gh_seed_prs
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo combsmith/repo-template
  [ "$status" -eq 0 ]
  grep -qF "pr edit 17 --repo combsmith/repo-template --body" "$CALLS"
  grep -qF "Resolved ref:" "$CALLS"
  run grep -F "pr create" "$CALLS"
  [ "$status" -eq 1 ]
}

@test "#1925 AC2: with several seed PRs open, the newest is kept and each older one is closed with a link" {
  _drop_all_standards_fixtures
  _fixture_commercial_standard
  export SEED_OPEN_PRS="$(printf '9\tseed-scaffold/2026-09-07\n12\tseed-scaffold/2026-09-20\n17\tseed-scaffold/2026-10-01')"
  _stub_gh_seed_prs
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo combsmith/repo-template
  [ "$status" -eq 0 ]
  [[ "$output" == *"closed superseded seed PR #9"* ]]
  [[ "$output" == *"closed superseded seed PR #12"* ]]
  grep -F "pr close 9 --repo combsmith/repo-template --comment" "$CALLS" | grep -qF "Superseded by #17"
  grep -F "pr close 12 --repo combsmith/repo-template --comment" "$CALLS" | grep -qF "Superseded by #17"
  # The surviving PR is never closed, and no second PR is opened.
  run grep -F "pr close 17" "$CALLS"
  [ "$status" -eq 1 ]
  run grep -F "pr create" "$CALLS"
  [ "$status" -eq 1 ]
}

@test "#1925 AC2: a PR on another branch is never closed as a superseded seed" {
  source "$SEED"
  _stub_gh_seed_prs
  run _seed_close_superseded combsmith/repo-template 17 "$(printf '5\tfeature/login\n17\tseed-scaffold/2026-10-01\nnot-a-number\tseed-scaffold/x')"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS" ]
}

@test "#1925 AC2: an older seed PR that cannot be closed fails the run and is named" {
  _drop_all_standards_fixtures
  _fixture_commercial_standard
  export SEED_CLOSE_FAILS=9 SEED_OPEN_PRS="$(printf '9\tseed-scaffold/2026-09-07\n17\tseed-scaffold/2026-10-01')"
  _stub_gh_seed_prs
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo combsmith/repo-template
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not close superseded seed PR #9"* ]]
  [[ "$output" == *"#17 carries the current seed"* ]]
}

@test "#1925 AC2: when this run's PR cannot be identified, no older seed PR is closed" {
  source "$SEED"
  _stub_gh_seed_prs
  run _seed_close_superseded combsmith/repo-template "" "$(printf '9\tseed-scaffold/2026-09-07')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"leaving older seed PR #9 open"* ]]
  [ ! -f "$CALLS" ]
}

# _ahead_env <newer-state> — source the seeder and replace the three reads the
# no-downgrade check makes, so the decision can be tested without a network:
#   the standards HEAD commit, its relation to the resolved ref, and the emission
#   at HEAD (which is "<arg>@HEAD"). The resolved ref is a published channel.
_ahead_env() {
  declare -p WORKFLOW_MANIFEST > /dev/null 2>&1 || source "$SEED"
  _SEED_NEWER_STATE=""; _SEED_NEWER_SHA=""; _SEED_WRITES=0; _SEED_AHEAD=()
  _STD_REF="standards/v1-stable"; _STD_SHA="1111111111111111111111111111111111111111"; _STD_SRC="channel"
  AHEAD_HEAD="2222222222222222222222222222222222222222"; AHEAD_RELATION="ahead"; AHEAD_EMIT_FAILS=0
  AHEAD_LOOKUPS="$BATS_TEST_TMPDIR/lookups.log"; : > "$AHEAD_LOOKUPS"
  _template_drift_head_sha() { echo head >> "$AHEAD_LOOKUPS"; printf '%s' "$AHEAD_HEAD"; }
  _template_drift_compare() { printf '%s' "$AHEAD_RELATION"; }
  _seed_emit_at() { [ "$AHEAD_EMIT_FAILS" = 0 ] || return 1; printf '%s@HEAD' "$3"; }
}

@test "#1925 AC3: a file that matches the emission at a newer standards commit is REFUSED, not overwritten" {
  _ahead_env
  local existing="$BATS_TEST_TMPDIR/existing"; printf 'docs/x.txt@HEAD' > "$existing"
  _stub_gh_existing "docs/x.txt" "$existing"
  run _seed_file combsmith/repo-template "docs/x.txt" "docs/x.txt@channel" seed-branch main 0 --emit-baseline "docs/x.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REFUSED docs/x.txt"* ]]
  [[ "$output" == *"the template is ahead of standards/v1-stable"* ]]
  [[ "$output" == *"222222222222"* ]]
  [ ! -f "$CALLS" ]
}

@test "#1925 AC3: the refused file is recorded and the channel-behind warning names it" {
  _ahead_env
  local existing="$BATS_TEST_TMPDIR/existing"; printf 'docs/x.txt@HEAD' > "$existing"
  _stub_gh_existing "docs/x.txt" "$existing"
  _seed_file combsmith/repo-template "docs/x.txt" "docs/x.txt@channel" seed-branch main 0 --emit-baseline "docs/x.txt"
  [ "${#_SEED_AHEAD[@]}" -eq 1 ]
  [ "${_SEED_AHEAD[0]}" = "docs/x.txt" ]
  run _seed_report_ahead
  [[ "$output" == "::warning::standards channel is behind the template — promote standards"* ]]
  [[ "$output" == *"docs/x.txt"* ]]
}

@test "#1925 AC3: a file that matches neither the ref nor the newer commit is still written" {
  _ahead_env
  local existing="$BATS_TEST_TMPDIR/existing"; printf 'hand edited' > "$existing"
  _stub_gh_existing "docs/x.txt" "$existing"
  run _seed_file combsmith/repo-template "docs/x.txt" "docs/x.txt@channel" seed-branch main 0 --emit-baseline "docs/x.txt"
  [ "$status" -eq 0 ]
  grep -qF "contents/docs/x.txt" "$CALLS"
}

@test "#1925 AC3: DRY_RUN reports the refusal and writes nothing" {
  _ahead_env
  local existing="$BATS_TEST_TMPDIR/existing"; printf 'docs/x.txt@HEAD' > "$existing"
  _stub_gh_existing "docs/x.txt" "$existing"
  DRY_RUN=true run _seed_file combsmith/repo-template "docs/x.txt" "docs/x.txt@channel" seed-branch main 0 --emit-baseline "docs/x.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would REFUSE docs/x.txt"* ]]
  [ ! -f "$CALLS" ]
}

@test "#1925 AC3: an unchanged file never triggers the newer-commit lookup" {
  _ahead_env
  local existing="$BATS_TEST_TMPDIR/existing"; printf 'docs/x.txt@channel' > "$existing"
  _stub_gh_existing "docs/x.txt" "$existing"
  run _seed_file combsmith/repo-template "docs/x.txt" "docs/x.txt@channel" seed-branch main 0 --emit-baseline "docs/x.txt"
  [ "$status" -eq 0 ]
  [ ! -s "$AHEAD_LOOKUPS" ]
}

@test "#1925 AC3: when the standards HEAD cannot be read the seed aborts instead of overwriting" {
  _ahead_env
  AHEAD_HEAD=""
  local existing="$BATS_TEST_TMPDIR/existing"; printf 'docs/x.txt@HEAD' > "$existing"
  _stub_gh_existing "docs/x.txt" "$existing"
  run _seed_file combsmith/repo-template "docs/x.txt" "docs/x.txt@channel" seed-branch main 0 --emit-baseline "docs/x.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot tell whether"*"newer than standards/v1-stable"* ]]
  [ ! -f "$CALLS" ]
}

@test "#1925 AC3: when the ancestry cannot be read the seed aborts instead of overwriting" {
  _ahead_env
  AHEAD_RELATION=""
  local existing="$BATS_TEST_TMPDIR/existing"; printf 'docs/x.txt@HEAD' > "$existing"
  _stub_gh_existing "docs/x.txt" "$existing"
  run _seed_file combsmith/repo-template "docs/x.txt" "docs/x.txt@channel" seed-branch main 0 --emit-baseline "docs/x.txt"
  [ "$status" -ne 0 ]
  [ ! -f "$CALLS" ]
}

@test "#1925 AC3: when the HEAD emission cannot be computed the seed aborts instead of overwriting" {
  _ahead_env
  AHEAD_EMIT_FAILS=1
  local existing="$BATS_TEST_TMPDIR/existing"; printf 'docs/x.txt@HEAD' > "$existing"
  _stub_gh_existing "docs/x.txt" "$existing"
  run _seed_file combsmith/repo-template "docs/x.txt" "docs/x.txt@channel" seed-branch main 0 --emit-baseline "docs/x.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot compute the standards HEAD"* ]]
  [ ! -f "$CALLS" ]
}

@test "#1925 AC3: a ref that is not behind HEAD has nothing newer — a differing file is written" {
  local relation
  for relation in identical behind diverged; do
    _ahead_env
    AHEAD_RELATION="$relation"
    rm -f "$CALLS"
    local existing="$BATS_TEST_TMPDIR/existing"; printf 'docs/x.txt@HEAD' > "$existing"
    _stub_gh_existing "docs/x.txt" "$existing"
    run _seed_file combsmith/repo-template "docs/x.txt" "docs/x.txt@channel" seed-branch main 0 --emit-baseline "docs/x.txt"
    [ "$status" -eq 0 ]
    grep -qF "contents/docs/x.txt" "$CALLS"
  done
}

@test "#1925 AC3: the STANDARDS_DIR local seam has no ref, so nothing is looked up" {
  _ahead_env
  _STD_SRC="local"
  local existing="$BATS_TEST_TMPDIR/existing"; printf 'docs/x.txt@HEAD' > "$existing"
  _stub_gh_existing "docs/x.txt" "$existing"
  run _seed_file combsmith/repo-template "docs/x.txt" "docs/x.txt@channel" seed-branch main 0 --emit-baseline "docs/x.txt"
  [ "$status" -eq 0 ]
  [ ! -s "$AHEAD_LOOKUPS" ]
  grep -qF "contents/docs/x.txt" "$CALLS"
}

@test "#1925 AC3: on a reused seed branch, a refused file is restored to the base content" {
  _ahead_env
  local base="$BATS_TEST_TMPDIR/base" stale="$BATS_TEST_TMPDIR/stale"
  printf 'docs/x.txt@HEAD' > "$base"       # the default branch is ahead of the channel
  printf 'docs/x.txt@channel' > "$stale"   # an older run downgraded it on the PR branch
  _stub_gh_open_seed_pr "docs/x.txt@main" "$base" "docs/x.txt@seed-scaffold/2026-10-01" "$stale"
  run _seed_file combsmith/repo-template "docs/x.txt" "docs/x.txt@channel" seed-scaffold/2026-10-01 main 1 --emit-baseline "docs/x.txt"
  [ "$status" -eq 0 ]
  grep -F "contents/docs/x.txt --method PUT" "$CALLS" | grep -qF "branch=seed-scaffold/2026-10-01"
  # What was written is the base (ahead) content, not this run's channel emission.
  grep -F "contents/docs/x.txt --method PUT" "$CALLS" | grep -qF "content=$(printf 'docs/x.txt@HEAD' | base64)"
}

@test "#1925 AC3: a run that writes nothing opens no PR and removes the branch it created" {
  source "$SEED"
  _stub_gh_seed_prs
  _seed_all_files() { _SEED_AHEAD+=(".github/workflows/agent-shield.yml"); }
  STANDARDS_DIR="" _STD_REF="standards/v1-stable" _STD_SHA="1111111111111111111111111111111111111111" _STD_SRC="channel" \
    run _seed_repo combsmith/repo-template
  [ "$status" -eq 0 ]
  [[ "$output" == *"standards channel is behind the template — promote standards"* ]]
  [[ "$output" == *"no PR opened on combsmith/repo-template: the only differing files are ahead of standards/v1-stable"* ]]
  run grep -F "pr create" "$CALLS"
  [ "$status" -eq 1 ]
  grep -qF "git/refs/heads/seed-scaffold/" "$CALLS"
  grep -F "git/refs/heads/seed-scaffold/" "$CALLS" | grep -qF -- "--method DELETE"
}

@test "#1925: a run with nothing to write and nothing refused says the template already matches" {
  source "$SEED"
  _stub_gh_seed_prs
  _seed_all_files() { :; }
  STANDARDS_DIR="" _STD_REF="standards/v1-stable" _STD_SHA="1111111111111111111111111111111111111111" _STD_SRC="channel" \
    run _seed_repo combsmith/repo-template
  [ "$status" -eq 0 ]
  [[ "$output" == *"it already matches standards/v1-stable"* ]]
  run grep -F "pr create" "$CALLS"
  [ "$status" -eq 1 ]
}

@test "#1925: a dated branch left by an earlier run is brought in line, not trusted as fresh" {
  source "$SEED"
  # The branch cannot be created (it exists) but can be read.
  cat > "$STUB_BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"git/refs --method POST"*) exit 1 ;;
  "pr create "*) echo "$args" >> "$CALLS"; echo "https://github.com/combsmith/repo-template/pull/88" ;;
  *"pr list"*) ;;
  *"git/ref/heads/"*) echo basesha ;;
  *"repos/combsmith/repo-template --jq"*) echo main ;;
  *) echo '{}' ;;
esac
GHSTUB
  chmod +x "$STUB_BIN/gh"
  _seed_all_files() { echo "reuse=$4"; _SEED_WRITES=1; }
  STANDARDS_DIR="" _STD_REF="standards/v1-stable" _STD_SHA="1111111111111111111111111111111111111111" _STD_SRC="channel" \
    run _seed_repo combsmith/repo-template
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists on combsmith/repo-template"* ]]
  # reuse=1 makes _seed_file restore skipped, preserved and refused files on the branch.
  [[ "$output" == *"reuse=1"* ]]
}

@test "#1925: a freshly created branch is not treated as carrying older edits" {
  source "$SEED"
  _stub_gh_seed_prs
  _seed_all_files() { echo "reuse=$4"; _SEED_WRITES=1; }
  STANDARDS_DIR="" _STD_REF="standards/v1-stable" _STD_SHA="1111111111111111111111111111111111111111" _STD_SRC="channel" \
    run _seed_repo combsmith/repo-template
  [ "$status" -eq 0 ]
  [[ "$output" == *"reuse=0"* ]]
}

# ── #1925 review follow-ups ────────────────────────────────────────────────────

@test "#1925: an unreadable open-PR list stops the run before anything is written" {
  source "$SEED"
  cat > "$STUB_BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"--method PUT"*|*"--method POST"*|"pr create "*) echo "$args" >> "$CALLS"; echo '{}' ;;
  *"pr list"*"headRefName"*) echo '{"message":"API rate limit exceeded"}'; exit 1 ;;
  *"git/ref/heads/"*) echo basesha ;;
  *"repos/combsmith/repo-template --jq"*) echo main ;;
  *) echo '{}' ;;
esac
GHSTUB
  chmod +x "$STUB_BIN/gh"
  _seed_all_files() { echo "seeded"; _SEED_WRITES=1; }
  STANDARDS_DIR="" _STD_REF="standards/v1-stable" _STD_SHA="1111111111111111111111111111111111111111" _STD_SRC="channel" \
    run _seed_repo combsmith/repo-template
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot list open pull requests on combsmith/repo-template"* ]]
  [[ "$output" != *"seeded"* ]]
  # No branch, no file, no PR.
  [ ! -f "$CALLS" ]
}

@test "#1925: a seed PR beyond the first 100 open PRs is still found and reused" {
  _drop_all_standards_fixtures
  _fixture_commercial_standard
  # 150 open PRs; the seed PR is the last one. The stub applies --limit the way gh
  # does (before the jq filter), so a limit of 100 would cut the seed PR off.
  cat > "$STUB_BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  "pr edit "*) echo "$args" >> "$CALLS"; exit 0 ;;
  "pr create "*) echo "$args" >> "$CALLS"; echo "https://github.com/combsmith/repo-template/pull/999"; exit 0 ;;
  *"--method PUT"*|*"--method POST"*) echo "$args" >> "$CALLS"; echo '{}' ;;
  *"pr list"*"--head seed-scaffold/2026-10-01"*) echo 150 ;;
  *"pr list"*"headRefName"*)
    limit="${args##*--limit }"; limit="${limit%% *}"
    { for i in $(seq 1 149); do printf '%s\tfeature/%s\n' "$i" "$i"; done; printf '150\tseed-scaffold/2026-10-01\n'; } \
      | head -n "$limit" | awk -F'\t' '$2 ~ /^seed-scaffold\//' ;;
  *"pr list"*) ;;
  *"git/ref/heads/"*) echo basesha ;;
  *"repos/combsmith/repo-template --jq"*) echo main ;;
  *) echo '{}' ;;
esac
GHSTUB
  chmod +x "$STUB_BIN/gh"
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo combsmith/repo-template
  [ "$status" -eq 0 ]
  [[ "$output" == *"seed PR #150 is already open"* ]]
  run grep -F "pr create" "$CALLS"
  [ "$status" -eq 1 ]
}

@test "#1925: a seed run fetches standards at the recorded commit, not through the moving ref" {
  source "$SEED"
  cat > "$STUB_BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
echo "content"
GHSTUB
  chmod +x "$STUB_BIN/gh"
  unset STANDARDS_DIR
  _STD_REF="standards/v1-stable"; _STD_SHA="1111111111111111111111111111111111111111"; _STD_SRC="channel"
  # Before the seed pins it, a read goes through the ref name…
  run _fetch_standard "standards/gitleaks.toml"
  grep -qF "ref=standards/v1-stable" "$CALLS"
  # …and once _seed_repo has recorded the commit, through that commit.
  : > "$CALLS"
  _STD_PIN="$_STD_SHA"
  run _fetch_standard "standards/gitleaks.toml"
  grep -qF "ref=1111111111111111111111111111111111111111" "$CALLS"
  run grep -F "ref=standards/v1-stable" "$CALLS"
  [ "$status" -eq 1 ]
}

@test "#1925: _seed_repo pins the fetch to the resolved commit before it emits any file" {
  source "$SEED"
  _stub_gh_seed_prs
  _seed_all_files() { echo "pin=${_STD_PIN:-none}"; _SEED_WRITES=1; }
  STANDARDS_DIR="" _STD_REF="standards/v1-stable" _STD_SHA="1111111111111111111111111111111111111111" _STD_SRC="channel" \
    run _seed_repo combsmith/repo-template
  [ "$status" -eq 0 ]
  [[ "$output" == *"pin=1111111111111111111111111111111111111111"* ]]
}

@test "#1925: a leftover dated branch with nothing written and nothing ahead of base opens no PR" {
  source "$SEED"
  cat > "$STUB_BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"git/refs --method POST"*) exit 1 ;;
  "pr create "*) echo "$args" >> "$CALLS"; echo "https://github.com/combsmith/repo-template/pull/88" ;;
  *"/compare/main...seed-scaffold/"*) echo "${AHEAD_BY:-0}" ;;
  *"pr list"*) ;;
  *"git/ref/heads/"*) echo basesha ;;
  *"repos/combsmith/repo-template --jq"*) echo main ;;
  *) echo '{}' ;;
esac
GHSTUB
  chmod +x "$STUB_BIN/gh"
  _seed_all_files() { :; }
  STANDARDS_DIR="" _STD_REF="standards/v1-stable" _STD_SHA="1111111111111111111111111111111111111111" _STD_SRC="channel" \
    run _seed_repo combsmith/repo-template
  [ "$status" -eq 0 ]
  [[ "$output" == *"no PR opened on combsmith/repo-template: branch seed-scaffold/"*"has nothing main lacks"* ]]
  [ ! -f "$CALLS" ]
  # The same leftover branch, but still carrying a commit the base lacks → a PR is opened.
  export AHEAD_BY=2
  STANDARDS_DIR="" _STD_REF="standards/v1-stable" _STD_SHA="1111111111111111111111111111111111111111" _STD_SRC="channel" \
    run _seed_repo combsmith/repo-template
  [ "$status" -eq 0 ]
  grep -qF "pr create" "$CALLS"
}

@test "#1925: a failed provenance update on the kept seed PR fails the run and closes nothing" {
  _drop_all_standards_fixtures
  _fixture_commercial_standard
  export SEED_OPEN_PRS="$(printf '9\tseed-scaffold/2026-09-07\n17\tseed-scaffold/2026-10-01')"
  _stub_gh_seed_prs
  # Make `pr edit` fail.
  sed -i.bak 's|  "pr edit "\*) echo "$args" >> "$CALLS"; exit 0 ;;|  "pr edit "*) echo "$args" >> "$CALLS"; exit 1 ;;|' "$STUB_BIN/gh"
  run env DEPENDABOT_STACK=frontend bash "$SEED" --repo combsmith/repo-template
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot update the standards provenance on PR #17"* ]]
  run grep -F "pr close" "$CALLS"
  [ "$status" -eq 1 ]
}

@test "#1925: a new PR whose number cannot be read back closes nothing" {
  source "$SEED"
  _stub_gh_seed_prs
  export SEED_NEW_PR="not-a-number"
  _seed_all_files() { _SEED_WRITES=1; }
  STANDARDS_DIR="" _STD_REF="standards/v1-stable" _STD_SHA="1111111111111111111111111111111111111111" _STD_SRC="channel" \
    run _seed_repo combsmith/repo-template
  [ "$status" -eq 0 ]
  grep -qF "pr create" "$CALLS"
  run grep -F "pr close" "$CALLS"
  [ "$status" -eq 1 ]
}

# The no-downgrade check, end to end, with ONLY gh replaced: the real
# _template_drift_head_sha, the real _template_drift_compare and the real
# _seed_emit_at (a child run of this script pinned to the HEAD commit) decide.
# standards/gitleaks.toml reads "new" at the HEAD commit and "old" anywhere else;
# the template already holds "new".
_stub_gh_real_ahead() { # <relation the compare API reports>
  export REAL_HEAD="2222222222222222222222222222222222222222" REAL_RELATION="$1"
  local b64; b64="$(printf 'new' | base64)"
  cat > "$STUB_BIN/gh" <<GHSTUB
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"--method PUT"*|*"--method POST"*) echo "\$args" >> "$CALLS"; echo '{}' ;;
  *"application/vnd.github.sha"*"/commits/HEAD"*) printf '%s' "\$REAL_HEAD" ;;
  *"/compare/"*) echo "\$REAL_RELATION" ;;
  *"contents/standards/gitleaks.toml"*"ref=\$REAL_HEAD"*) printf 'new' ;;
  *"contents/standards/gitleaks.toml"*) printf 'old' ;;
  *"repo-template/contents/.gitleaks.toml"*) echo '{"sha":"feedface","content":"$b64"}' ;;
  *) echo '{}' ;;
esac
GHSTUB
  chmod +x "$STUB_BIN/gh"
}

@test "#1925 AC3 (real compare + emit): a file matching the HEAD emission is refused" {
  source "$SEED"
  unset STANDARDS_DIR
  _stub_gh_real_ahead ahead
  _STD_REF="standards/v1-stable"; _STD_SHA="1111111111111111111111111111111111111111"; _STD_SRC="channel"
  run _seed_file combsmith/repo-template ".gitleaks.toml" "old" seed-branch main 0 --emit-baseline ".gitleaks.toml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REFUSED .gitleaks.toml"* ]]
  [[ "$output" == *"standards HEAD 222222222222"* ]]
  [ ! -f "$CALLS" ]
}

@test "#1925 AC3 (real compare + emit): when HEAD is not newer than the ref, the file is written" {
  source "$SEED"
  unset STANDARDS_DIR
  _stub_gh_real_ahead diverged
  _STD_REF="standards/v1-stable"; _STD_SHA="1111111111111111111111111111111111111111"; _STD_SRC="channel"
  run _seed_file combsmith/repo-template ".gitleaks.toml" "old" seed-branch main 0 --emit-baseline ".gitleaks.toml"
  [ "$status" -eq 0 ]
  grep -qF "contents/.gitleaks.toml --method PUT" "$CALLS"
}

@test "#1925 AC3 (real compare + emit): an unreadable ancestry aborts instead of writing" {
  source "$SEED"
  unset STANDARDS_DIR
  _stub_gh_real_ahead '{"message":"Not Found"}'
  _STD_REF="standards/v1-stable"; _STD_SHA="1111111111111111111111111111111111111111"; _STD_SRC="channel"
  run _seed_file combsmith/repo-template ".gitleaks.toml" "old" seed-branch main 0 --emit-baseline ".gitleaks.toml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot tell whether"* ]]
  [ ! -f "$CALLS" ]
}
