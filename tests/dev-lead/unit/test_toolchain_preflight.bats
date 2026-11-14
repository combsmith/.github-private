#!/usr/bin/env bats
# Unit tests for toolchain_preflight.bash — the macOS toolchain check every
# suite-level setup_suite runs.
#
# Each test puts stubs for uname and the checked tools first on PATH, so the
# result does not depend on the machine running it.

load toolchain_preflight

setup() {
  STUB_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN_DIR"
  export PATH="$STUB_BIN_DIR:$PATH"
  unset BATS_SKIP_TOOLCHAIN_PREFLIGHT
  # A GNU toolchain on macOS. grep is the real one: GNU on CI and under
  # scripts/test-local.sh, which are where this suite runs.
  _stub uname 'echo Darwin'
  _stub sed 'echo "sed (GNU sed) 4.10"'
  _stub date 'exit 0'
  _stub awk 'echo "GNU Awk 5.3.2"'
  _stub flock 'exit 0'
  _stub python3 'exit 0'
}

# _stub <name> <body> — a command on PATH that runs <body>. The shebang names
# this bash by path, so a stub still runs when PATH holds only the stub dir.
_stub() {
  printf '#!%s\n%s\n' "$BASH" "$2" > "$STUB_BIN_DIR/$1"
  chmod +x "$STUB_BIN_DIR/$1"
}

_preflight_with_only_stubs_on_path() {
  local PATH="$STUB_BIN_DIR"
  toolchain_preflight
}

@test "macOS with the GNU toolchain passes" {
  run toolchain_preflight
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "macOS with BSD sed fails, names sed and points to scripts/test-local.sh" {
  _stub sed 'echo "usage: sed script [-EHalnru] [-i extension] [file ...]" >&2; exit 1'
  run toolchain_preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"GNU sed"* ]]
  [[ "$output" == *"scripts/test-local.sh"* ]]
  [[ "$output" != *"flock"* ]]
}

@test "macOS without flock or the python deps names both" {
  rm "$STUB_BIN_DIR/flock"
  _stub python3 'exit 1'
  # Only the stubs on PATH, so a real flock (/usr/bin/flock on Ubuntu) cannot
  # satisfy the check; grep is passed through to the real one.
  _stub grep "exec $(command -v grep) \"\$@\""
  run _preflight_with_only_stubs_on_path
  [ "$status" -eq 1 ]
  [[ "$output" == *"flock is not installed"* ]]
  [[ "$output" == *"jsonschema"* ]]
}

@test "macOS with BATS_SKIP_TOOLCHAIN_PREFLIGHT=1 skips the check" {
  _stub sed 'exit 1'
  BATS_SKIP_TOOLCHAIN_PREFLIGHT=1 run toolchain_preflight
  [ "$status" -eq 0 ]
}

@test "Linux is not checked, whatever the tools" {
  _stub uname 'echo Linux'
  _stub sed 'exit 1'
  _stub date 'exit 1'
  run toolchain_preflight
  [ "$status" -eq 0 ]
}

@test "macOS: a TMPDIR that does not exist falls back to /tmp" {
  TMPDIR="$BATS_TEST_TMPDIR/missing"
  toolchain_preflight
  [ "$TMPDIR" = "$(cd /tmp && pwd -P)" ]
}

@test "macOS: TMPDIR is resolved to its real path" {
  mkdir -p "$BATS_TEST_TMPDIR/real"
  ln -s "$BATS_TEST_TMPDIR/real" "$BATS_TEST_TMPDIR/link"
  TMPDIR="$BATS_TEST_TMPDIR/link"
  toolchain_preflight
  [ "$TMPDIR" = "$(cd "$BATS_TEST_TMPDIR/real" && pwd -P)" ]
}
