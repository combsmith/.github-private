#!/usr/bin/env bats
# Integration tests for the cross-repo publish path in cut-release.sh (#872):
# feature-ideation + the six #482 reusables are hosted in petry-projects/.github,
# so their release/channel tags are cut against THAT repo via `gh api`. These
# tests run main() end-to-end with a fake `gh` so no network/tags are touched.
#
# Run with: bats tests/test_cut_release_cross_repo.bats

setup() {
  TT_TMP="$(mktemp -d)" || { echo "Failed to create temp directory" >&2; exit 1; }
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/cut-release.sh"
  GH_CALLS="${TT_TMP}/gh-calls.log"; export GH_CALLS
  : > "$GH_CALLS"
  # A this-repo agent resolves its host from GITHUB_REPOSITORY (#1076 unified path).
  export GITHUB_REPOSITORY="petry-projects/.github-private"
  install_gh_stub
}

teardown() { rm -rf "$TT_TMP"; }

# Fake gh: logs every call, resolves a fixed SHA, and answers the ref-exists probe
# from GH_TAG_EXISTS (default 0 = absent). POSTs to git/tags return a tag-object SHA.
install_gh_stub() {
  local bin="${TT_TMP}/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
{ printf 'gh'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$GH_CALLS"
[ "${1:-}" = "api" ] || exit 0
case "$*" in
  *"commits/"*)        echo "feedfacefeedfacefeedfacefeedfacefeedface"; exit 0 ;;
  *"git/ref/tags/"*)   [ "${GH_TAG_EXISTS:-0}" = "1" ] && { echo "0babebabe0babebabe0babebabe0babebabe0bab"; exit 0; } || exit 1 ;;  # exists probe + ref sha
  *"git/tags"*)        echo "0babebabe0babebabe0babebabe0babebabe0bab"; exit 0 ;;  # annotated tag object
  *"git/refs"*)        exit 0 ;;  # create/patch ref
esac
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

@test "cross-repo --dry-run resolves the SHA against .github and touches nothing" {
  run env GH_TOKEN=x bash "$SCRIPT" agent-shield 2.1.0 --channel next --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'target=petry-projects/.github'
  echo "$output" | grep -q '(dry-run) no tags created'
  # resolved a SHA, but no tag object / ref was created
  grep -q 'commits/main' "$GH_CALLS"
  ! grep -qE 'POST .*git/(tags|refs)' "$GH_CALLS"
  ! grep -qE 'PATCH ' "$GH_CALLS"
}

@test "cross-repo without --push is print-only (no mutation)" {
  run env GH_TOKEN=x bash "$SCRIPT" agent-shield 2.1.0 --channel next
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'print only — re-run with --push'
  ! grep -qE 'POST .*git/(tags|refs)' "$GH_CALLS"
  ! grep -qE 'PATCH ' "$GH_CALLS"
}

@test "cross-repo --push creates the release tag and moves the channel on .github" {
  run env GH_TOKEN=x bash "$SCRIPT" agent-shield 2.1.0 --channel next --push
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'created agent-shield/v2.1.0 on petry-projects/.github'
  echo "$output" | grep -q 'moved agent-shield/v2-next'
  echo "$output" | grep -q 'published to petry-projects/.github'
  # annotated tag object + ref creation both went to petry-projects/.github
  grep -qE 'POST repos/petry-projects/\.github/git/tags' "$GH_CALLS"
  grep -qE 'POST repos/petry-projects/\.github/git/refs .*refs/tags/agent-shield/v2.1.0' "$GH_CALLS"
}

@test "cross-repo --push refuses to overwrite an existing release tag" {
  GH_TAG_EXISTS=1 run env GH_TOKEN=x GH_TAG_EXISTS=1 bash "$SCRIPT" agent-shield 2.1.0 --channel next --push
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'already exists on petry-projects/.github'
  ! grep -qE 'POST .*git/tags' "$GH_CALLS"
}

@test "a this-repo agent also resolves via gh api against its own host (#1076), dry-run" {
  run env GH_TOKEN=x bash "$SCRIPT" pr-review 9.9.9 --dry-run
  [ "$status" -eq 0 ]
  # host is the current repo (GITHUB_REPOSITORY), and resolution goes through the API —
  # the consistent gh-api path, not a local git resolve.
  echo "$output" | grep -q 'target=petry-projects/.github-private'
  grep -q 'commits/' "$GH_CALLS"
  ! grep -qE 'POST .*git/(tags|refs)' "$GH_CALLS"
}

@test "a this-repo agent --push creates+moves tags via gh api on its host, not git push (#1076)" {
  run env GH_TOKEN=x bash "$SCRIPT" dev-lead 1.5.4 --channel next --push
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'created dev-lead/v1.5.4 on petry-projects/.github-private'
  echo "$output" | grep -q 'moved dev-lead/v1-next'
  # the create + channel move both went through the API on the this-repo host
  grep -qE 'POST repos/petry-projects/\.github-private/git/tags' "$GH_CALLS"
  grep -qE '(POST|PATCH) repos/petry-projects/\.github-private/git/refs' "$GH_CALLS"
}

# ── --promote (ring-to-ring channel move of an existing release) ──────────────

@test "--promote requires --channel" {
  run env GH_TOKEN=x bash "$SCRIPT" agent-shield 2.1.0 --promote --push
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'requires --channel'
}

@test "cross-repo --promote errors when the release tag is absent" {
  GH_TAG_EXISTS=0 run env GH_TOKEN=x GH_TAG_EXISTS=0 bash "$SCRIPT" agent-shield 2.1.0 --channel ring1 --promote --push
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'does not exist'
  ! grep -qE '(PATCH|POST) .*git/refs' "$GH_CALLS"
}

@test "cross-repo --promote moves the channel to the existing release without cutting a new tag" {
  GH_TAG_EXISTS=1 run env GH_TOKEN=x GH_TAG_EXISTS=1 bash "$SCRIPT" agent-shield 2.1.0 --channel ring1 --promote --push
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'moved agent-shield/v2-ring1'
  # the immutable release tag object is never (re)created
  ! grep -qE 'POST repos/petry-projects/\.github/git/tags' "$GH_CALLS"
  # the channel ref WAS moved
  grep -qE '(PATCH|POST) repos/petry-projects/\.github/git/refs' "$GH_CALLS"
}

@test "cross-repo --promote --dry-run moves nothing" {
  GH_TAG_EXISTS=1 run env GH_TOKEN=x GH_TAG_EXISTS=1 bash "$SCRIPT" agent-shield 2.1.0 --channel ring1 --promote --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'dry-run'
  ! grep -qE '(PATCH|POST) .*git/refs' "$GH_CALLS"
}

# ── major-scoped channels (#1184, epic #657) ──────────────────────────────────
# --channel <tier> derives the major from <version>; a fully-qualified
# v<M>-<tier> passes through; the immutable vX.Y.Z release tag is unchanged.

@test "major-scoped: --channel stable derives v2- from version 2.0.0 (dry-run)" {
  run env GH_TOKEN=x bash "$SCRIPT" dev-lead 2.0.0 --channel stable --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'channel tag: dev-lead/v2-stable -> dev-lead/v2.0.0'
  # not the old bare-tier form
  ! echo "$output" | grep -qE 'channel tag: dev-lead/stable '
}

@test "major-scoped: explicit --channel v1-ring0 passes through unchanged (dry-run)" {
  run env GH_TOKEN=x bash "$SCRIPT" dev-lead 2.0.0 --channel v1-ring0 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'channel tag: dev-lead/v1-ring0 -> dev-lead/v2.0.0'
}

@test "major-scoped: bump of major is reflected in the channel prefix (1.x -> v1-)" {
  run env GH_TOKEN=x bash "$SCRIPT" dev-lead 1.7.2 --channel stable --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'channel tag: dev-lead/v1-stable -> dev-lead/v1.7.2'
}

@test "major-scoped: release tag <agent>/v2.0.0 is still created on --push" {
  run env GH_TOKEN=x bash "$SCRIPT" dev-lead 2.0.0 --channel stable --push
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'created dev-lead/v2.0.0 on petry-projects/.github-private'
  echo "$output" | grep -q 'moved dev-lead/v2-stable'
  # the immutable release tag ref is the un-prefixed vX.Y.Z form
  grep -qE 'POST repos/petry-projects/\.github-private/git/refs .*refs/tags/dev-lead/v2.0.0' "$GH_CALLS"
  # the channel ref that moved is the major-scoped v2-stable
  grep -qE '(POST|PATCH) repos/petry-projects/\.github-private/git/refs.*dev-lead/v2-stable' "$GH_CALLS"
}

@test "major-scoped: --promote moves the major-scoped channel of the release's major" {
  GH_TAG_EXISTS=1 run env GH_TOKEN=x GH_TAG_EXISTS=1 bash "$SCRIPT" dev-lead 2.3.1 --channel ring1 --promote --push
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'moved dev-lead/v2-ring1'
}
