#!/usr/bin/env bats
# Unit tests for the I/O half of the symbol-context assembler (issue #1090,
# epic #1088): assemble_symbol_context <diff> <repo> [out_file].
#
# Unlike sc_touched_functions (pure), the assembler performs `gh` I/O: it
# extracts the touched functions from the diff, then for each one gathers
# caller/callee/type-def reference contexts via the GitHub search_code path
# (`gh search code`), writes a human-readable SYMBOL_CONTEXT block to a file
# (path exported as SYMBOL_CONTEXT_FILE), and emits a per-function context-count
# log line (AC #2). It must:
#   - assemble at least SYMBOL_CONTEXT_MIN (default 3) contexts per function,
#   - emit a measurable per-function count log line,
#   - degrade gracefully (search unavailable -> MCP-style ::warning::, exit 0),
#   - write literal "(none)" and perform zero searches when the diff touches no
#     functions.
#
# `gh` is stubbed via a PATH shim that logs every invocation and returns a fixed
# set of search results, so we can assert behavior and search volume.
#
# Run with: bats tests/dev-lead/unit/test_symbol_context_assemble.bats

setup() {
  source "$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/scripts/lib/symbol-context.sh"

  STUB_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  export PATH="$STUB_DIR:$PATH"
  export GH_CALL_LOG="$STUB_DIR/gh_calls.log"
  : > "$GH_CALL_LOG"
  OUT_FILE="$STUB_DIR/symbol-context.txt"
  REPO="petry-projects/.github-private"

  # A one-function bash diff used by most tests.
  DIFF='--- a/scripts/foo.sh
+++ b/scripts/foo.sh
@@ -10,1 +10,3 @@
+assemble_thing() {
+  helper_fn
+}
'
  export DIFF
}

teardown() {
  rm -rf "$STUB_DIR"
  unset SYMBOL_CONTEXT_FILE SYMBOL_CONTEXT_MIN SYMBOL_CONTEXT_MAX_FUNCS SYMBOL_CONTEXT_MAX_BYTES
}

# Installs a gh stub. GH_STUB_MODE:
#   found  — `gh search code` returns 4 result items with path + textMatches.
#   two    — `gh search code` returns 2 result items (for SYMBOL_CONTEXT_MIN tests).
#   fail   — `gh search code` exits 1 (search unavailable / no scope).
make_gh_stub() {
  cat > "$STUB_DIR/gh" << 'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
[ "$1" = "search" ] && [ "$2" = "code" ] || exit 0

if [ "${GH_STUB_MODE:-found}" = "fail" ]; then
  echo "gh: code search failed" >&2
  exit 1
fi

if [ "${GH_STUB_MODE:-found}" = "two" ]; then
  cat <<'JSON'
[
  {"path":"scripts/a.sh","textMatches":[{"fragment":"  assemble_thing arg1"}]},
  {"path":"scripts/b.sh","textMatches":[{"fragment":"result=$(assemble_thing)"}]}
]
JSON
  exit 0
fi

# Emit a JSON array shaped like `gh search code --json path,textMatches`.
cat <<'JSON'
[
  {"path":"scripts/a.sh","textMatches":[{"fragment":"  assemble_thing arg1"}]},
  {"path":"scripts/b.sh","textMatches":[{"fragment":"result=$(assemble_thing)"}]},
  {"path":"scripts/c.sh","textMatches":[{"fragment":"assemble_thing() {"}]},
  {"path":"scripts/d.sh","textMatches":[{"fragment":"# calls assemble_thing later"}]}
]
JSON
STUBEOF
  chmod +x "$STUB_DIR/gh"
}

# ---------------------------------------------------------------------------
# Happy path: >=3 contexts per function, count log line, file + export
# ---------------------------------------------------------------------------

@test "assembles at least 3 contexts for a touched function and lists them" {
  export GH_STUB_MODE=found
  make_gh_stub
  run assemble_symbol_context "$DIFF" "$REPO" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$OUT_FILE" ]
  grep -q "assemble_thing" "$OUT_FILE"
  # At least 3 reference-context lines were written for the function.
  [ "$(grep -c 'scripts/[a-d]\.sh' "$OUT_FILE" || true)" -ge 3 ]
  run grep -qx "(none)" "$OUT_FILE"
  [ "$status" -eq 1 ]
  # Searches actually happened.
  [ -s "$GH_CALL_LOG" ]
}

@test "emits a measurable per-function context-count log line (AC #2)" {
  export GH_STUB_MODE=found
  make_gh_stub
  run assemble_symbol_context "$DIFF" "$REPO" "$OUT_FILE"
  [ "$status" -eq 0 ]
  # The count log line names the function and its attached-context count.
  [[ "$output" == *"[symbol-context]"* ]]
  [[ "$output" == *"assemble_thing"* ]]
  [[ "$output" =~ assemble_thing.*[0-9]+.*context ]]
}

@test "SYMBOL_CONTEXT_FILE is exported and points at the written file" {
  export GH_STUB_MODE=found
  make_gh_stub
  assemble_symbol_context "$DIFF" "$REPO" "$OUT_FILE"
  [ "$SYMBOL_CONTEXT_FILE" = "$OUT_FILE" ]
  [ -f "$SYMBOL_CONTEXT_FILE" ]
}

@test "the configured minimum contexts-per-function is honored" {
  export GH_STUB_MODE=two
  make_gh_stub
  SYMBOL_CONTEXT_MIN=2 run assemble_symbol_context "$DIFF" "$REPO" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'scripts/[a-b]\.sh' "$OUT_FILE")" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Graceful degradation: search unavailable -> MCP-style warning, exit 0
# ---------------------------------------------------------------------------

@test "search failure degrades with an MCP-style warning and exits 0 (AC #4)" {
  export GH_STUB_MODE=fail
  make_gh_stub
  run assemble_symbol_context "$DIFF" "$REPO" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$OUT_FILE" ]
  # Reuses the MCP graceful-degradation phrasing: warn, never fake.
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"symbol-context"* ]]
  [[ "$output" == *"base capabilities"* ]]
}

# ---------------------------------------------------------------------------
# No touched functions -> literal "(none)", zero searches
# ---------------------------------------------------------------------------

@test "a diff touching no functions writes literal (none) and performs zero searches" {
  export GH_STUB_MODE=found
  make_gh_stub
  local docs_diff='--- a/README.md
+++ b/README.md
@@ -1,1 +1,1 @@
-old
+new
'
  run assemble_symbol_context "$docs_diff" "$REPO" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT_FILE")" = "(none)" ]
  [ ! -s "$GH_CALL_LOG" ]
}

# ---------------------------------------------------------------------------
# Bounded block size
# ---------------------------------------------------------------------------

@test "the assembled block is truncated to the configured byte cap" {
  export GH_STUB_MODE=found
  make_gh_stub
  SYMBOL_CONTEXT_MAX_BYTES=40 run assemble_symbol_context "$DIFF" "$REPO" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$OUT_FILE" ]
  [ "$(wc -c < "$OUT_FILE")" -le 40 ]
}

# ---------------------------------------------------------------------------
# SYMBOL_CONTEXT_MAX_FUNCS: multi-function diff + cap enforcement
# ---------------------------------------------------------------------------

# Two-function diff used by the cap tests below.
MULTI_DIFF='--- a/scripts/foo.sh
+++ b/scripts/foo.sh
@@ -10,3 +10,3 @@
+assemble_thing() {
+  helper_fn
+}
@@ -20,3 +20,3 @@
+another_function() {
+  more stuff
+}
'

@test "SYMBOL_CONTEXT_MAX_FUNCS caps the number of functions searched" {
  export GH_STUB_MODE=found
  make_gh_stub
  SYMBOL_CONTEXT_MAX_FUNCS=1 run assemble_symbol_context "$MULTI_DIFF" "$REPO" "$OUT_FILE"
  [ "$status" -eq 0 ]
  grep -q "function cap reached: 1" "$OUT_FILE"
  # Only one gh search was issued for the one allowed function.
  [ "$(grep -c 'search code' "$GH_CALL_LOG")" -eq 1 ]
}

@test "each function keeps its own context output and logging isolated" {
  export GH_STUB_MODE=found
  make_gh_stub
  run assemble_symbol_context "$MULTI_DIFF" "$REPO" "$OUT_FILE"
  [ "$status" -eq 0 ]
  # Both functions have their own section in the output file.
  grep -q "assemble_thing" "$OUT_FILE"
  grep -q "another_function" "$OUT_FILE"
  # Both functions get their own per-function count log line.
  [[ "$output" =~ assemble_thing.*[0-9]+.*context ]]
  [[ "$output" =~ another_function.*[0-9]+.*context ]]
}
