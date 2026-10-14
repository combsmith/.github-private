#!/usr/bin/env bats
# Unit tests for the downstream-impact I/O assembler
# (issue #751, epic #748): assemble_downstream_impact <changed_files> <manifest> [out_file].
#
# Unlike compute_downstream_impact (pure), the assembler performs `gh` I/O: it
# calls the pure mapper, then fetches each impacted consumer's referencing
# workflow file(s) via `gh api` and writes a human-readable DOWNSTREAM_IMPACT
# block to a file (path exported as DOWNSTREAM_IMPACT_FILE). It must:
#   - bound fetch volume (per-PR repo cap + 8 KB block size cap),
#   - degrade gracefully (private/unreadable consumer -> "unreadable", exit 0),
#   - perform ZERO fetches and emit literal "(none)" when nothing is impacted.
#
# `gh` is stubbed via a PATH shim that logs every invocation, so we can assert
# both behavior and fetch volume.
#
# Run with: bats tests/test_downstream_impact_assemble.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/downstream-impact.sh"
  MANIFEST="$(dirname "$BATS_TEST_FILENAME")/fixtures/downstream-impact/manifest.json"

  STUB_DIR="$(mktemp -d)"
  export PATH="$STUB_DIR:$PATH"
  export GH_CALL_LOG="$STUB_DIR/gh_calls.log"
  : > "$GH_CALL_LOG"
  OUT_FILE="$STUB_DIR/downstream-impact.txt"

  # A caller workflow that pins BOTH provider reusables, base64-encoded the way
  # GitHub's contents API returns file bodies.
  CALLER_WF_CONTENT='name: caller
on: pull_request
jobs:
  review:
    uses: petry-projects/.github-private/.github/workflows/pr-review.yml@v1
  dl:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@v1
'
  export CALLER_WF_B64
  CALLER_WF_B64="$(printf '%s' "$CALLER_WF_CONTENT" | base64)"
}

teardown() {
  rm -rf "$STUB_DIR"
}

# Installs a gh stub in one of two modes (env GH_STUB_MODE):
#   readable   — directory listing returns one caller workflow; its content
#                pins both provider reusables.
#   unreadable — every contents call exits 1 (simulates 404/403/private repo).
make_gh_stub() {
  cat > "$STUB_DIR/gh" << 'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
[ "$1" = "api" ] || exit 0
resource="$2"

if [ "${GH_STUB_MODE:-readable}" = "unreadable" ]; then
  # Simulate a private/unreadable repo or missing token scope.
  exit 1
fi

case "$resource" in
  */contents/.github/workflows)
    # Directory listing — emit one caller workflow path.
    printf '%s\n' ".github/workflows/caller.yml"
    ;;
  */contents/.github/workflows/*)
    # File content — base64 body the way the contents API returns it.
    printf '%s\n' "$CALLER_WF_B64"
    ;;
  *)
    exit 0
    ;;
esac
STUBEOF
  chmod +x "$STUB_DIR/gh"
}

# ---------------------------------------------------------------------------
# Impacted + readable consumer
# ---------------------------------------------------------------------------

@test "impacted change with a readable consumer writes the surfaces, consumers, and referencing files" {
  export GH_STUB_MODE=readable
  make_gh_stub
  run assemble_downstream_impact ".github/workflows/pr-review.yml" "$MANIFEST" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$OUT_FILE" ]
  grep -q ".github/workflows/pr-review.yml" "$OUT_FILE"
  grep -q "petry-projects/alpha" "$OUT_FILE"
  grep -q "petry-projects/bravo" "$OUT_FILE"
  grep -q ".github/workflows/caller.yml" "$OUT_FILE"
  # The block is not the literal "(none)" when something is impacted.
  ! grep -qx "(none)" "$OUT_FILE"
  # Fetches actually happened.
  [ -s "$GH_CALL_LOG" ]
}

# ---------------------------------------------------------------------------
# Impacted + unreadable consumer -> graceful degradation, never fails
# ---------------------------------------------------------------------------

@test "impacted change with an unreadable consumer degrades to 'unreadable' and exits 0" {
  export GH_STUB_MODE=unreadable
  make_gh_stub
  run assemble_downstream_impact ".github/workflows/pr-review.yml" "$MANIFEST" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$OUT_FILE" ]
  grep -q "petry-projects/alpha" "$OUT_FILE"
  grep -q "unreadable" "$OUT_FILE"
}

# ---------------------------------------------------------------------------
# No impact -> literal "(none)", zero fetches
# ---------------------------------------------------------------------------

@test "a no-impact change writes literal (none) and performs zero fetches" {
  export GH_STUB_MODE=readable
  make_gh_stub
  run assemble_downstream_impact "README.md
docs/architecture.md" "$MANIFEST" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$OUT_FILE" ]
  [ "$(cat "$OUT_FILE")" = "(none)" ]
  # No gh invocations at all.
  [ ! -s "$GH_CALL_LOG" ]
}

# ---------------------------------------------------------------------------
# Bounded fetch volume: per-PR repo cap
# ---------------------------------------------------------------------------

@test "the per-PR repo cap bounds the number of consumers fetched" {
  export GH_STUB_MODE=readable
  make_gh_stub
  # pr-review.yml is pinned by alpha and bravo (2 consumers). Cap at 1.
  DOWNSTREAM_IMPACT_MAX_REPOS=1 run assemble_downstream_impact ".github/workflows/pr-review.yml" "$MANIFEST" "$OUT_FILE"
  [ "$status" -eq 0 ]
  # Only one consumer's directory listing should have been fetched. The listing
  # call is "...contents/.github/workflows --jq ..." (no file path before --jq).
  run grep -c "contents/.github/workflows --jq" "$GH_CALL_LOG"
  [ "$output" -eq 1 ]
  # The block notes that consumers were omitted by the cap.
  grep -qi "cap" "$OUT_FILE"
}

# ---------------------------------------------------------------------------
# Bounded block size: mirrors the 8 KB ADVISORY_BOT_FEEDBACK cap
# ---------------------------------------------------------------------------

@test "the assembled block is truncated to the configured size cap" {
  export GH_STUB_MODE=readable
  make_gh_stub
  DOWNSTREAM_IMPACT_MAX_BYTES=50 run assemble_downstream_impact ".github/workflows/pr-review.yml" "$MANIFEST" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$OUT_FILE" ]
  size="$(wc -c < "$OUT_FILE")"
  [ "$size" -le 50 ]
}

# ---------------------------------------------------------------------------
# Path export
# ---------------------------------------------------------------------------

@test "DOWNSTREAM_IMPACT_FILE is exported and points at the written file" {
  export GH_STUB_MODE=readable
  make_gh_stub
  assemble_downstream_impact ".github/workflows/pr-review.yml" "$MANIFEST" "$OUT_FILE"
  [ "$DOWNSTREAM_IMPACT_FILE" = "$OUT_FILE" ]
  [ -f "$DOWNSTREAM_IMPACT_FILE" ]
}
