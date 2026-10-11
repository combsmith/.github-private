#!/usr/bin/env bats
# scripts/check-fixed-tmp-paths.sh (#2271) — lists every fixed path under /tmp
# that tests/ and scripts/ name and fails on one that is not accounted for, so
# two bats sessions on one machine cannot read each other's files.
#
# The last section pins the dev-lead sidecar directory: one definition, the
# historical default, and no writer or reader that goes around it.
#
# Fixture paths are spelled "$T/<name>" and "$B/<name>" so this file names no
# fixed path itself.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECK="$REPO_ROOT/scripts/check-fixed-tmp-paths.sh"
T=/tmp
B='$BATS_TMPDIR'

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$SANDBOX/tests" "$SANDBOX/scripts/lib"
}

# put <relative-file> <line>... — write a fixture file into the sandbox.
put() {
  local file="$SANDBOX/$1"
  shift
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$@" > "$file"
}

# except <path> <file> <reason> — add one exception row.
except() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SANDBOX/scripts/lib/fixed-tmp-paths.tsv"
}

# ── tests/ ───────────────────────────────────────────────────────────────────

@test "tests: a fixed path named by two test files fails and is listed as shared" {
  put tests/a.bats '@test "a" {' "  echo 1 > $T/shared-marker" '}'
  put tests/b.bats '@test "b" {' "  [ -f $T/shared-marker ]" '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FIXED     $T/shared-marker  (SHARED by 2 files: tests/a.bats, tests/b.bats)"* ]]
  [[ "$output" == *"::error file=tests/a.bats,line=2::"* ]]
  [[ "$output" == *"::error file=tests/b.bats,line=2::"* ]]
}

@test "tests: a fixed path named by one test file fails too (two sessions of it collide)" {
  put tests/a.bats '@test "a" {' "  echo 1 > $T/only-here" '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FIXED     $T/only-here  (1 file: tests/a.bats)"* ]]
}

@test "tests: per-test and unique paths pass" {
  put tests/a.bats '@test "a" {' \
    '  echo 1 > "$BATS_TEST_TMPDIR/out"' \
    '  f="$(mktemp)"; d="$(mktemp -d)"' \
    "  g=\"\$(mktemp \"\${TMPDIR:-$T}/guard.XXXXXX\")\"" \
    "  h=\"\$(mktemp $T/body-XXXXXX.md)\"" \
    "  echo 1 > $T/missing-\$\$.txt" \
    "  ls $T/*.log \"\$BATS_TEST_TMPDIR$T/nested\" /var$T/elsewhere" \
    '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(none)"* ]]
}

@test "tests: a path in a comment or a test title is not a path opened" {
  put tests/a.bats "# reads $T/in-a-comment" "@test \"writes $T/in-a-title\" {" '  true' '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

@test "tests: the default of a stub's \${VAR:-…} expansion is a fixed path" {
  put tests/stubs/gh '#!/usr/bin/env bash' "echo true > \"\${GH_STUB_FILE:-$T/stub-called}\""
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FIXED     $T/stub-called  (1 file: tests/stubs/gh)"* ]]
}

@test "tests: a fixed name under \$BATS_TMPDIR fails; a mktemp template there passes" {
  put tests/a.bats 'setup() {' "  export TEST_DIR=\"$B/batch-test\"" '}'
  put tests/b.bash "DIR=\"\${${B#?}:-$T}/stub-bins\""
  put tests/c.bats 'setup() {' "  d=\"\$(mktemp -d \"$B/c.XXXXXX\")\"" "  e=\"$B/\$\$-run\"" '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FIXED     $B/batch-test  (1 file: tests/a.bats)"* ]]
  [[ "$output" == *"FIXED     $B/stub-bins  (1 file: tests/b.bash)"* ]]
  [[ "$output" != *"tests/c.bats"* ]]
}

# ── scripts/ ─────────────────────────────────────────────────────────────────

@test "scripts: a bare literal fails; the same path as a \${VAR:-…} default passes" {
  put scripts/writer.sh '#!/usr/bin/env bash' "printf x > $T/agent-state"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FIXED     $T/agent-state  (1 file: scripts/writer.sh)"* ]]

  put scripts/writer.sh '#!/usr/bin/env bash' "printf x > \"\${AGENT_STATE_FILE:-$T/agent-state}\""
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

@test "scripts: a path shared between a script and a test names both files" {
  put scripts/writer.sh '#!/usr/bin/env bash' "printf x > $T/agent-state"
  put tests/a.bats '@test "a" {' "  [ -s $T/agent-state ]" '}'
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$T/agent-state  (SHARED by 2 files: "* ]]
  [[ "$output" == *"scripts/writer.sh"* ]]
  [[ "$output" == *"tests/a.bats"* ]]
}

@test "scripts: markdown is not scanned" {
  put scripts/README.md "Run it with DRY_RUN_LOG=$T/plan.jsonl"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

# ── exceptions ───────────────────────────────────────────────────────────────

@test "exceptions: a row excuses its path, and what is beneath it, in its file only" {
  put scripts/review.sh '#!/usr/bin/env bash' "mkdir -p $T/work" "echo x > $T/work/out.json"
  put tests/a.bats '@test "a" {' "  [ -s $T/work/out.json ]" '}'
  except "$T/work" scripts/review.sh "working directory named by the workflow artifact step"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"excepted  $T/work  (scripts/review.sh, 2 references): working directory"* ]]
  [[ "$output" == *"FIXED     $T/work/out.json  (1 file: tests/a.bats)"* ]]
  [[ "$output" != *"file=scripts/review.sh"* ]]
}

@test "exceptions: a row that matches nothing fails as stale" {
  put tests/a.bats '@test "a" {' '  true' '}'
  except "$T/gone" tests/a.bats "was a label once"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale exception: $T/gone is no longer named in tests/a.bats"* ]]
}

@test "exceptions: a row without a reason fails" {
  put tests/a.bats '@test "a" {' "  run check \"$T/label\"" '}'
  printf '%s\t%s\n' "$T/label" tests/a.bats >> "$SANDBOX/scripts/lib/fixed-tmp-paths.tsv"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"exception row needs path, file and reason"* ]]
}

# ── this repository ──────────────────────────────────────────────────────────

@test "repo: every fixed path under /tmp in tests/ and scripts/ is accounted for" {
  run bash "$CHECK" "$REPO_ROOT"
  echo "$output"
  [ "$status" -eq 0 ]
}

# ── dev-lead sidecar directory ───────────────────────────────────────────────

SIDECARS='dev-lead-(rate-limit-reset|failure-reason|timeout-tier|timeout-budget|timeout-elapsed)'

@test "sidecars: DEV_LEAD_SIDECAR_DIR is assigned in one place, engine.sh" {
  run grep -rnE '(^|[^A-Za-z0-9_])DEV_LEAD_SIDECAR_DIR=' "$REPO_ROOT/scripts"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "$REPO_ROOT/scripts/engine.sh:"*':DEV_LEAD_SIDECAR_DIR="${DEV_LEAD_SIDECAR_DIR:-/tmp}"' ]]
}

@test "sidecars: unset or empty resolves to /tmp, the paths before the variable existed" {
  local probe='source "$1/scripts/engine.sh" >/dev/null 2>&1; printf "%s" "$DEV_LEAD_SIDECAR_DIR/dev-lead-rate-limit-reset"'
  run env -u DEV_LEAD_SIDECAR_DIR REVIEW_ENGINE=claude bash -c "$probe" _ "$REPO_ROOT"
  [ "$output" = "$T/dev-lead-rate-limit-reset" ]
  run env DEV_LEAD_SIDECAR_DIR= REVIEW_ENGINE=claude bash -c "$probe" _ "$REPO_ROOT"
  [ "$output" = "$T/dev-lead-rate-limit-reset" ]
  run env DEV_LEAD_SIDECAR_DIR="$BATS_TEST_TMPDIR" REVIEW_ENGINE=claude bash -c "$probe" _ "$REPO_ROOT"
  [ "$output" = "$BATS_TEST_TMPDIR/dev-lead-rate-limit-reset" ]
}

# A writer and a reader that spell the directory differently resolve different
# files as soon as the variable is set, so every reference must be the same
# expression. Comment lines are prose and may keep the historical path.
@test "sidecars: every script reference is \"\$DEV_LEAD_SIDECAR_DIR/<file>\"" {
  local refs stray
  refs="$(grep -rnE "$SIDECARS" "$REPO_ROOT/scripts" --include='*.sh' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"
  [ -n "$refs" ]
  stray="$(printf '%s\n' "$refs" | sed -E "s#\"\\\$DEV_LEAD_SIDECAR_DIR/${SIDECARS}\"##g" | grep -E "$SIDECARS" || true)"
  echo "$stray"
  [ -z "$stray" ]
}
