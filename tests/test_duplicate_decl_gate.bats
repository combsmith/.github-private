#!/usr/bin/env bats
# Tests for scripts/check-duplicate-decls.sh — the required duplicate-decl CI
# gate (#1520). The corrupted fixture replays the #1449/#1485 corruption
# signature (whole-block duplication of top-level functions).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATE="$REPO_ROOT/scripts/check-duplicate-decls.sh"
  FIXTURES="$REPO_ROOT/tests/dev-lead/fixtures/conflict-integrity"
  SCOPE_FIXTURES="$REPO_ROOT/tests/dev-lead/fixtures/duplicate-scope"
  WORKDIR="$BATS_TEST_TMPDIR"
}

@test "gate: repo's own scripts/ tree is clean (green on restored main)" {
  run bash "$GATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no duplicate top-level function declarations"* ]]
}

@test "gate: fails on the corrupted fixture and names the duplicated function" {
  cp "$FIXTURES/resolved_corrupted.sh" "$WORKDIR/"
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"run_writer"* ]]
  [[ "$output" == *"declared 2 times"* ]]
}

@test "gate: failure output points at the #1485 incident record" {
  cp "$FIXTURES/resolved_corrupted.sh" "$WORKDIR/"
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"#1485"* ]]
}

@test "gate: clean file passes; duplicated top-level VAR alone does not fail (functions only)" {
  cat > "$WORKDIR/clean_with_var_reassign.sh" <<'EOF'
#!/usr/bin/env bash
RC=0
one() { echo 1; }
RC=1
two() { echo 2; }
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 0 ]
}

@test "gate: catches duplicates defined with multiline 'name()\\n{' syntax" {
  cat > "$WORKDIR/multiline_dup.sh" <<'EOF'
#!/usr/bin/env bash
foo()
{
  echo 1
}
foo()
{
  echo 2
}
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"foo"* ]]
}

@test "gate: scans nested lib/ subdirectories" {
  mkdir -p "$WORKDIR/lib"
  cp "$FIXTURES/resolved_corrupted.sh" "$WORKDIR/lib/"
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
}

# --- Widened scope (#1779): prompts/**/*.md headings + personas/**/*.yml keys ---

@test "gate: default (no-arg) run of the repo tree is clean across all three scans" {
  run bash "$GATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no duplicate top-level function declarations"* ]]
}

# --- Scanning ANOTHER tree (#2184): the rebase integrity gate runs this script
# against the resolved PR worktree, not against the script's own repo. --------

@test "gate: this repo's own tree copied elsewhere is clean when scanned from here (#2184)" {
  # Reproduces PR 2180: the gate from one checkout scanning an identical tree in
  # another directory failed on the allowlisted prompts/triage.md heading.
  mkdir -p "$WORKDIR/tree"
  cp -R "$REPO_ROOT/scripts" "$REPO_ROOT/prompts" "$REPO_ROOT/personas" "$WORKDIR/tree/"
  DUPLICATE_DECL_PROMPTS_DIR="$WORKDIR/tree/prompts" \
  DUPLICATE_DECL_PERSONAS_DIR="$WORKDIR/tree/personas" \
    run bash "$GATE" "$WORKDIR/tree/scripts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no duplicate top-level function declarations"* ]]
}

@test "gate: the allowlisted heading is allowed in another tree; a trailing slash on the dir changes nothing (#2184)" {
  mkdir -p "$WORKDIR/tree/prompts" "$WORKDIR/tree/scripts"
  printf '## Issue-type classification\n\ntext\n\n## Issue-type classification\n' > "$WORKDIR/tree/prompts/triage.md"
  DUPLICATE_DECL_PROMPTS_DIR="$WORKDIR/tree/prompts" run bash "$GATE" "$WORKDIR/tree/scripts"
  [ "$status" -eq 0 ]
  DUPLICATE_DECL_PROMPTS_DIR="$WORKDIR/tree/prompts/" run bash "$GATE" "$WORKDIR/tree/scripts"
  [ "$status" -eq 0 ]
}

@test "gate: a genuine duplicate heading in another tree is still flagged, named by its tree-relative path (#2184)" {
  mkdir -p "$WORKDIR/tree/prompts/sub" "$WORKDIR/tree/scripts"
  printf '## Same heading\n\ntext\n\n## Same heading\n' > "$WORKDIR/tree/prompts/sub/other.md"
  # The allowlisted heading in a DIFFERENT file is not covered by the allowlist entry.
  printf '## Issue-type classification\n\n## Issue-type classification\n' > "$WORKDIR/tree/prompts/not-triage.md"
  DUPLICATE_DECL_PROMPTS_DIR="$WORKDIR/tree/prompts" run bash "$GATE" "$WORKDIR/tree/scripts"
  [ "$status" -eq 1 ]
  [[ "$output" == *'`prompts/sub/other.md` — duplicate markdown heading: `## Same heading`'* ]]
  [[ "$output" == *'`prompts/not-triage.md`'* ]]
  [[ "$output" != *"$WORKDIR/tree/prompts"* ]]
}

@test "gate: a duplicate persona key in another tree is named by its tree-relative path (#2184)" {
  mkdir -p "$WORKDIR/tree/personas/x" "$WORKDIR/tree/scripts"
  printf 'runtime:\n  reusable: a\n  reusable: b\n' > "$WORKDIR/tree/personas/x/persona.yml"
  DUPLICATE_DECL_PERSONAS_DIR="$WORKDIR/tree/personas" run bash "$GATE" "$WORKDIR/tree/scripts"
  [ "$status" -eq 1 ]
  [[ "$output" == *'`personas/x/persona.yml`'* ]]
  [[ "$output" != *"$WORKDIR/tree/personas"* ]]
}

@test "gate: flags the pre-fix fix-ci.md duplicate Phase headings" {
  mkdir -p "$WORKDIR/empty-scripts"
  DUPLICATE_DECL_PROMPTS_DIR="$SCOPE_FIXTURES/prompts-prefix" \
    run bash "$GATE" "$WORKDIR/empty-scripts"
  [ "$status" -eq 1 ]
  [[ "$output" == *"### Phase 2 — Fix"* ]]
  [[ "$output" == *"fix-ci.md"* ]]
  [[ "$output" == *"#1485"* ]]
}

@test "gate: flags the pre-fix fix-reviews.md duplicate Phase headings" {
  mkdir -p "$WORKDIR/empty-scripts"
  DUPLICATE_DECL_PROMPTS_DIR="$SCOPE_FIXTURES/prompts-prefix" \
    run bash "$GATE" "$WORKDIR/empty-scripts"
  [ "$status" -eq 1 ]
  [[ "$output" == *"### Phase 2 — Test Verification"* ]]
  [[ "$output" == *"fix-reviews.md"* ]]
}

@test "gate: flags the pre-fix persona.yml duplicate same-mapping key" {
  mkdir -p "$WORKDIR/empty-scripts"
  DUPLICATE_DECL_PERSONAS_DIR="$SCOPE_FIXTURES/personas-prefix" \
    run bash "$GATE" "$WORKDIR/empty-scripts"
  [ "$status" -eq 1 ]
  [[ "$output" == *"reusable"* ]]
  [[ "$output" == *"runtime"* ]]
  [[ "$output" == *"persona.yml"* ]]
}

@test "gate: ignores repeated headings that live only inside fenced code blocks" {
  mkdir -p "$WORKDIR/empty-scripts"
  DUPLICATE_DECL_PROMPTS_DIR="$SCOPE_FIXTURES/prompts-benign" \
    run bash "$GATE" "$WORKDIR/empty-scripts"
  [ "$status" -eq 0 ]
}

@test "gate: does not flag keys repeated across different YAML list items" {
  mkdir -p "$WORKDIR/empty-scripts"
  DUPLICATE_DECL_PERSONAS_DIR="$SCOPE_FIXTURES/personas-benign" \
    run bash "$GATE" "$WORKDIR/empty-scripts"
  [ "$status" -eq 0 ]
}

@test "gate: explicit <dir> mode without env overrides scans .sh only (no md/yml)" {
  # A dir containing a duplicate heading + duplicate key but no .sh must pass in
  # legacy positional mode — the widened scans are opt-in there.
  cp "$SCOPE_FIXTURES/prompts-prefix/fix-ci.md" "$WORKDIR/"
  cp "$SCOPE_FIXTURES/personas-prefix/persona.yml" "$WORKDIR/"
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 0 ]
}

# --- Helper unit coverage -----------------------------------------------------

@test "extract_markdown_headings: emits headings, skips fenced content" {
  source "$REPO_ROOT/scripts/lib/conflict-integrity.sh"
  run extract_markdown_headings "$SCOPE_FIXTURES/prompts-benign/fenced-headings.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Real heading"* ]]
  [[ "$output" != *"# Phase 2 — Fix"* ]]
}

@test "extract_markdown_headings: recognizes valid ATX headings with 0-3 leading spaces" {
  source "$REPO_ROOT/scripts/lib/conflict-integrity.sh"
  run extract_markdown_headings "$SCOPE_FIXTURES/prompts-prefix/indented-headings.md"
  [ "$status" -eq 0 ]
  # Should detect both indented duplicate headings
  [[ "$output" == *"## Section A"* ]]
  [[ "$output" == *"## Section B"* ]]
  # Count occurrences of each heading (should be exactly 2 of each)
  count_a=$(printf '%s\n' "$output" | grep -c "## Section A")
  count_b=$(printf '%s\n' "$output" | grep -c "## Section B")
  [ "$count_a" -eq 2 ]
  [ "$count_b" -eq 2 ]
}

@test "gate: detects indented heading duplicates" {
  mkdir -p "$WORKDIR/empty-scripts"
  DUPLICATE_DECL_PROMPTS_DIR="$SCOPE_FIXTURES/prompts-prefix" \
    run bash "$GATE" "$WORKDIR/empty-scripts"
  [ "$status" -eq 1 ]
  [[ "$output" == *"## Section A"* ]]
  [[ "$output" == *"## Section B"* ]]
  [[ "$output" == *"indented-headings.md"* ]]
}

@test "extract_yaml_mapping_keys: flags same-mapping dup, not cross-list-item repeats" {
  source "$REPO_ROOT/scripts/lib/conflict-integrity.sh"
  dup="$(extract_yaml_mapping_keys "$SCOPE_FIXTURES/personas-prefix/persona.yml" \
    | LC_ALL=C sort | uniq -d)"
  [[ "$dup" == *"reusable"* ]]
  ok="$(extract_yaml_mapping_keys "$SCOPE_FIXTURES/personas-benign/list-items.yml" \
    | LC_ALL=C sort | uniq -d)"
  [ -z "$ok" ]
}

@test "extract_yaml_mapping_keys: canonicalizes bare and quoted spellings of one key" {
  source "$REPO_ROOT/scripts/lib/conflict-integrity.sh"
  cat > "$WORKDIR/quoted-key.yml" <<'EOF'
runtime:
  reusable: true
  "reusable": false
EOF
  dup="$(extract_yaml_mapping_keys "$WORKDIR/quoted-key.yml" | LC_ALL=C sort | uniq -d)"
  [[ "$dup" == *"reusable"* ]]
}

@test "extract_markdown_headings: a matching delimiter with non-whitespace tail stays inside the fence" {
  source "$REPO_ROOT/scripts/lib/conflict-integrity.sh"
  cat > "$WORKDIR/fence-tail.md" <<'EOF'
# Real Heading

```
```bash
## Not a heading (still inside the fence)
```
EOF
  run extract_markdown_headings "$WORKDIR/fence-tail.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"# Real Heading"* ]]
  [[ "$output" != *"Not a heading"* ]]
}

@test "extract_markdown_headings: optional ATX closing marker compares equal to bare form" {
  source "$REPO_ROOT/scripts/lib/conflict-integrity.sh"
  cat > "$WORKDIR/atx-close.md" <<'EOF'
## Phase 2 ##
## Phase 2
EOF
  dup="$(extract_markdown_headings "$WORKDIR/atx-close.md" | LC_ALL=C sort | uniq -d)"
  [[ "$dup" == *"## Phase 2"* ]]
}
