#!/usr/bin/env bats
# scripts/check-bats-negation.sh (#2263) — fails when a bats file holds a negated
# command that can never fail its test (a `! cmd` that is not the last command
# and has no `|| false`).
#
# Fixtures are written with printf, one single-quoted line per argument, so this
# file never contains the pattern it is testing for.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECK="$SCRIPT_DIR/scripts/check-bats-negation.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  FIXTURE="$SANDBOX/sample.bats"
}

teardown() {
  rm -rf "$SANDBOX"
}

# _fixture <line>... — write a .bats fixture, one argument per line.
_fixture() {
  printf '%s\n' "$@" > "$FIXTURE"
}

@test "check: a negation followed by another command fails and prints file:line" {
  _fixture \
    '@test "x" {' \
    '  run thing' \
    '  ! grep -q bad "$LOG"' \
    '  [ "$status" -eq 0 ]' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample.bats:3: ! grep -q bad"* ]]
}

@test "check: a negation that is the last command of its test passes" {
  _fixture \
    '@test "x" {' \
    '  run thing' \
    '  ! grep -q bad "$LOG"' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

@test "check: blank and comment lines before the closing brace do not hide a last command" {
  _fixture \
    '@test "x" {' \
    '  ! grep -q bad "$LOG"' \
    '' \
    '  # nothing else to assert' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

@test "check: '|| false' and '|| return 1' make a negation effective" {
  _fixture \
    '@test "x" {' \
    '  ! grep -q bad "$LOG" || false' \
    '  ! grep -q worse "$LOG" || return 1' \
    '  true' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

@test "check: '|| true' does not make a negation effective" {
  _fixture \
    '@test "x" {' \
    '  ! grep -q bad "$LOG" || true' \
    '  true' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample.bats:2:"* ]]
}

@test "check: 'run ! cmd' is not a bare negation" {
  _fixture \
    '@test "x" {' \
    '  run ! grep -q bad "$LOG"' \
    '  true' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

@test "check: a negation nested in a block is flagged" {
  _fixture \
    '@test "x" {' \
    '  if [ -f "$LOG" ]; then' \
    '    ! grep -q bad "$LOG"' \
    '  fi' \
    '  true' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample.bats:3:"* ]]
}

@test "check: a negation reading a here-string is flagged" {
  _fixture \
    '@test "x" {' \
    '  ! grep -q bad <<<"$output"' \
    '  true' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample.bats:2:"* ]]
}

@test "check: a heredoc body is data, and scanning resumes after its terminator" {
  _fixture \
    '@test "x" {' \
    '  cat > "$STUB" <<'"'"'EOF'"'"'' \
    '! grep -q inside-the-stub "$1"' \
    'exit 0' \
    'EOF' \
    '  ! grep -q bad "$LOG"' \
    '  true' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample.bats:6:"* ]]
  [[ "$output" != *"sample.bats:3:"* ]]
}

@test "check: a '<<' inside a quoted string does not open a heredoc and hide the rest of the file" {
  _fixture \
    '@test "x" {' \
    '  printf '"'"'cat <<"OUT"\n%s\nOUT\n'"'"' "$*" > "$FAKE"' \
    '  ! grep -q bad "$LOG"' \
    '  true' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample.bats:3:"* ]]
}

@test "check: a heredoc that never closes is a scan error, not a clean pass" {
  _fixture \
    '@test "x" {' \
    '  cat > "$STUB" <<EOF' \
    '  ! grep -q bad "$LOG"' \
    '  true' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"never closed"* ]]
}

@test "check: a backslash-continued negation is judged by its last line" {
  _fixture \
    '@test "x" {' \
    '  ! grep -q bad \' \
    '    "$LOG" || false' \
    '  ! grep -q worse \' \
    '    "$LOG"' \
    '  true' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample.bats:4:"* ]]
  [[ "$output" != *"sample.bats:2:"* ]]
}

@test "check: the bats-negation-ok marker exempts one line" {
  _fixture \
    '@test "x" {' \
    '  ! grep -q bad "$LOG"  # bats-negation-ok: status is read on the next line' \
    '  true' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

@test "check: a single file can be passed instead of a directory" {
  _fixture \
    '@test "x" {' \
    '  ! grep -q bad "$LOG"' \
    '  true' \
    '}'
  run bash "$CHECK" "$FIXTURE"
  [ "$status" -eq 1 ]
}

@test "check: a directory with no bats files is a setup error, not a pass" {
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no .bats files"* ]]
}

@test "check: a path that does not exist is a setup error" {
  run bash "$CHECK" "$SANDBOX/missing"
  [ "$status" -eq 2 ]
}

@test "check: this repo's own test suite has no inert negations" {
  run bash "$CHECK"
  [ "$status" -eq 0 ]
}

# ── Commands sharing a line (#2263 review) ───────────────────────────────────

@test "check: a negation after a semicolon is flagged when more commands follow" {
  _fixture \
    '@test "x" {' \
    '  run thing; ! grep -q bad "$LOG"' \
    '  [ "$status" -eq 0 ]' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample.bats:2: run thing; ! grep -q bad"* ]]
}

@test "check: a negation after a semicolon that is the last command of its test passes" {
  _fixture \
    '@test "x" {' \
    '  run thing; ! grep -q bad "$LOG"' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

@test "check: a command after a negation on the same line makes it inert even before the closing brace" {
  _fixture \
    '@test "x" {' \
    '  ! grep -q bad "$LOG"; true' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample.bats:2:"* ]]
}

@test "check: '|| false' on a semicolon-separated negation makes it effective" {
  _fixture \
    '@test "x" {' \
    '  run thing; ! grep -q bad "$LOG" || false; true' \
    '  true' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

@test "check: a semicolon or a negation inside a quoted string is text, not a command" {
  _fixture \
    '@test "x" {' \
    '  ! grep -q "bad; worse" "$LOG" || false' \
    '  echo "left; ! right"' \
    "  echo 'left; ! right'" \
    '  true' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

@test "check: '|| false' inside a quoted argument does not make a negation effective" {
  _fixture \
    '@test "x" {' \
    '  ! grep -q "bad || false" "$LOG"' \
    '  true' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample.bats:2:"* ]]
}

@test "check: '|| false' in a trailing comment does not make a negation effective" {
  _fixture \
    '@test "x" {' \
    '  ! grep -q bad "$LOG"  # || false' \
    '  true' \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample.bats:2:"* ]]
}

# ── More than one file ───────────────────────────────────────────────────────

@test "check: a negation left pending at the end of one file is reported against that file" {
  printf '%s\n' '@test "a" {' '  ! grep -q bad "$LOG"' > "$SANDBOX/a.bats"
  printf '%s\n' '}' '@test "b" {' '  true' '}' > "$SANDBOX/b.bats"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.bats:2: ! grep -q bad"* ]]
  [[ "$output" != *"b.bats:"* ]]
}

# ── A listing that fails ─────────────────────────────────────────────────────

@test "check: a find that fails part-way is a scan error, not a clean pass" {
  # find lists one clean file and then fails, as it does on a directory it
  # cannot read: the files it never reached must not count as scanned.
  _fixture \
    '@test "x" {' \
    '  true' \
    '}'
  mkdir -p "$SANDBOX/bin"
  printf '%s\n' '#!/usr/bin/env bash' "echo '$FIXTURE'" 'echo "find: unreadable: Permission denied" >&2' 'exit 1' > "$SANDBOX/bin/find"
  chmod +x "$SANDBOX/bin/find"
  PATH="$SANDBOX/bin:$PATH" run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot be certified clean"* ]]
  [[ "$output" != *"no inert negations"* ]]
}
