#!/usr/bin/env bats
# Unit tests for scripts/lib/rebase-integrity-gate.sh (#2184).
#
# The post-rebase integrity gate (#1890 AC #7) ran check-duplicate-decls.sh with
# its output discarded. On PR 2180 a clean conflict resolution was escalated to a
# human as "possible #1485 corruption" and nothing recorded why. These tests pin
# the three outcomes (clean, finding, could-not-evaluate), that the gate's own
# words are kept (bounded and redacted), and that the real gate against a real
# tree in another directory is clean.
#
# Run with: bats tests/dev-lead/unit/test_rebase_integrity_gate.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  LIB="$REPO_ROOT/scripts/lib/rebase-integrity-gate.sh"
  REAL_GATE="$REPO_ROOT/scripts/check-duplicate-decls.sh"
  WORK="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$WORK/scripts" "$BATS_TEST_TMPDIR/bin"
  FAKE_GATE="$BATS_TEST_TMPDIR/bin/fake-gate.sh"
  # shellcheck source=scripts/lib/redact.sh
  source "$REPO_ROOT/scripts/lib/redact.sh"
  # shellcheck source=scripts/lib/rebase-integrity-gate.sh
  source "$LIB"
}

# _fake_gate <exit_code> <output...> — a stand-in gate that prints and exits.
_fake_gate() {
  local rc="$1"; shift
  { printf '#!/usr/bin/env bash\n'; printf 'cat <<"OUT"\n%s\nOUT\n' "$*"; printf 'exit %s\n' "$rc"; } > "$FAKE_GATE"
  chmod +x "$FAKE_GATE"
}

@test "safe to source under set -euo pipefail, and prints nothing" {
  run bash -c "set -euo pipefail; source '$LIB'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "clean gate → 0, no output, empty RIG_DETAIL" {
  _fake_gate 0 "duplicate-decl-gate: no duplicate top-level function declarations"
  run rig_duplicate_decl_gate "$FAKE_GATE" "$WORK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rig_duplicate_decl_gate "$FAKE_GATE" "$WORK"
  [ -z "$RIG_DETAIL" ]
}

@test "the gate is pointed at the work tree's scripts/, prompts/ and personas/" {
  { printf '#!/usr/bin/env bash\n'
    printf 'echo "scan=$1 prompts=$DUPLICATE_DECL_PROMPTS_DIR personas=$DUPLICATE_DECL_PERSONAS_DIR"; exit 1\n'
  } > "$FAKE_GATE"; chmod +x "$FAKE_GATE"
  run rig_duplicate_decl_gate "$FAKE_GATE" "$WORK"
  [[ "$output" == *"scan=$WORK/scripts prompts=$WORK/prompts personas=$WORK/personas"* ]]
}

@test "gate exit 1 → 1, worded as possible corruption, with the gate's own report" {
  _fake_gate 1 "- \`scripts/x.sh\` — function \`foo\` declared 2 times"
  run rig_duplicate_decl_gate "$FAKE_GATE" "$WORK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::warning::integrity gate: check-duplicate-decls.sh found duplicate declarations"* ]]
  [[ "$output" == *"possible #1485 corruption"* ]]
  [[ "$output" == *"function \`foo\` declared 2 times"* ]]
  [[ "$output" != *"could not be evaluated"* ]]
  rig_duplicate_decl_gate "$FAKE_GATE" "$WORK" >/dev/null || true
  [[ "$RIG_DETAIL" == *"declared 2 times"* ]]
}

@test "gate exit 2 → 2, 'could not be evaluated', never worded as corruption" {
  _fake_gate 2 "::error::check-duplicate-decls: scan directory does not exist: /nope"
  run rig_duplicate_decl_gate "$FAKE_GATE" "$WORK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not be evaluated after rebase resolution (exit 2)"* ]]
  [[ "$output" == *"not a corruption finding"* ]]
  [[ "$output" == *"scan directory does not exist"* ]]
  [[ "$output" != *"possible #1485 corruption"* ]]
}

@test "any other non-zero exit (e.g. 127) is 'could not be evaluated', reported as 2" {
  _fake_gate 127 "bash: jq: command not found"
  run rig_duplicate_decl_gate "$FAKE_GATE" "$WORK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"(exit 127)"* ]]
  [[ "$output" != *"possible #1485 corruption"* ]]
}

@test "missing or non-executable gate script → 0 with a notice, never a finding" {
  run rig_duplicate_decl_gate "$BATS_TEST_TMPDIR/bin/absent.sh" "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"* ]]
  [[ "$output" == *"could not be evaluated"* ]]
  [[ "$output" != *"::warning::"* ]]
  _fake_gate 1 "would fail if run"; chmod -x "$FAKE_GATE"
  run rig_duplicate_decl_gate "$FAKE_GATE" "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" != *"possible #1485 corruption"* ]]
}

@test "the gate's own ::error:: lines are indented detail, not new annotations" {
  _fake_gate 1 "::error::Duplicate declarations found"
  run rig_duplicate_decl_gate "$FAKE_GATE" "$WORK"
  ! grep -qE '^::error::' <<<"$output"
  [[ "$output" == *"integrity gate> ::error::Duplicate declarations found"* ]]
}

@test "the excerpt is redacted and bounded" {
  local secret lines i
  # Built at run time so no credential-shaped literal sits in the repository.
  secret="ghp_$(printf 'A%.0s' {1..36})"
  lines="leaked ${secret} here"
  for i in $(seq 1 40); do lines+=$'\n'"line $i"; done
  _fake_gate 1 "$lines"
  run rig_duplicate_decl_gate "$FAKE_GATE" "$WORK"
  [ "$status" -eq 1 ]
  [[ "$output" != *"$secret"* ]]
  [[ "$output" == *"REDACTED"* ]]
  [[ "$output" == *"line 14"* ]]
  [[ "$output" != *"line 15"* ]]
}

@test "real gate, real tree in another directory: clean (the PR 2180 false failure)" {
  mkdir -p "$BATS_TEST_TMPDIR/copy"
  cp -R "$REPO_ROOT/scripts" "$REPO_ROOT/prompts" "$REPO_ROOT/personas" "$BATS_TEST_TMPDIR/copy/"
  run rig_duplicate_decl_gate "$REAL_GATE" "$BATS_TEST_TMPDIR/copy"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "real gate, genuine duplicate function in the tree: 1, naming the symbol and the file" {
  printf 'foo() { :; }\nfoo() { :; }\n' > "$WORK/scripts/dup.sh"
  run rig_duplicate_decl_gate "$REAL_GATE" "$WORK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"possible #1485 corruption"* ]]
  [[ "$output" == *"foo"* ]]
  [[ "$output" == *"dup.sh"* ]]
}

@test "real gate, scan directory missing: 'could not be evaluated', not corruption" {
  run rig_duplicate_decl_gate "$REAL_GATE" "$BATS_TEST_TMPDIR/no-such-tree"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not be evaluated"* ]]
  [[ "$output" != *"possible #1485 corruption"* ]]
}

@test "wiring: verify_resolution_integrity uses the helper and no longer discards the gate's output" {
  local f="$REPO_ROOT/scripts/dev-lead-fix-reviews.sh"
  grep -qF 'lib/rebase-integrity-gate.sh' "$f"
  grep -qF 'rig_duplicate_decl_gate "${script_dir}/check-duplicate-decls.sh" "$work_root"' "$f"
  ! grep -E 'check-duplicate-decls\.sh.*>/dev/null' "$f"
  grep -qF '${RIG_DETAIL}' "$f"
}
