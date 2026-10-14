#!/usr/bin/env bats
# Unit tests for scripts/initiative-driver.sh
# Covers has_label regex safety, gate label, MAX_IN_FLIGHT cap, and blocked_by evaluation.
# Mocks the gh CLI to avoid network calls.
#
# Run with: bats tests/test_initiative_driver.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/initiative-driver.sh"

setup() {
  MOCK_BIN="$(mktemp -d)"
  GH_LOG="$(mktemp)"
  export GH_LOG
  export PATH="$MOCK_BIN:$PATH"
  export REPO="owner/repo"
  export EPIC="1"
  export CLOSED_ISSUE=""
  export DRY_RUN="false"
  export MAX_IN_FLIGHT="2"
  export GH_TOKEN="tok"
}

teardown() {
  rm -rf "${MOCK_BIN:-}"
  rm -f "${GH_LOG:-}"
}

# ── has_label: fixed-string matching ─────────────────────────────────────────

@test "has_label matches an exact label name" {
  has_label() { printf '%s\n' "$1" | grep -qxF "$2"; }
  run has_label $'initiative:auto\nother-label' 'initiative:auto'
  [ "$status" -eq 0 ]
}

@test "has_label with -F does not match regex dot against a different label" {
  # Before the fix, grep -qx 'a.b' would match 'axb' (dot = any char in regex).
  # With -F the pattern is literal, so 'a.b' must not match 'axb'.
  has_label() { printf '%s\n' "$1" | grep -qxF "$2"; }
  run has_label $'axb\nother' 'a.b'
  [ "$status" -ne 0 ]
}

@test "has_label returns non-zero when label is absent" {
  has_label() { printf '%s\n' "$1" | grep -qxF "$2"; }
  run has_label $'foo\nbar' 'not-present'
  [ "$status" -ne 0 ]
}

# ── gate: epic must carry initiative:auto ────────────────────────────────────

@test "gate: exits 0 with no-op when epic lacks initiative:auto" {
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
# labels_of epic: return empty (no labels)
if [[ "$*" == *"issues/1 --jq"* ]]; then printf ''; exit 0; fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
  ! grep -qF "issue edit" "$GH_LOG"
}

@test "gate: proceeds past gate when epic carries initiative:auto" {
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
# Epic labels: initiative:auto
if [[ "$*" == *"issues/1 --jq"* ]] && [[ "$*" != *"sub_issues"* ]]; then
  printf 'initiative:auto'; exit 0
fi
# No sub-issues
if [[ "$*" == *"sub_issues"* ]]; then printf ''; exit 0; fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no sub-issues"* ]]
}

# ── MAX_IN_FLIGHT cap ─────────────────────────────────────────────────────────

@test "cap: does not label new issues when in-flight equals MAX_IN_FLIGHT" {
  export MAX_IN_FLIGHT="2"
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
# Epic labels: initiative:auto
if [[ "$args" == *"issues/1 --jq"* ]] && [[ "$args" != *"sub_issues"* ]]; then
  printf 'initiative:auto'; exit 0
fi
# Sub-issues (all states and open): issues 2 and 3
if [[ "$args" == *"sub_issues"* ]]; then printf '2\n3'; exit 0; fi
# Both issues already carry dev-lead (in-flight = 2)
if [[ "$args" == *"issues/2 --jq"* ]] || [[ "$args" == *"issues/3 --jq"* ]]; then
  printf 'dev-lead'; exit 0
fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in-flight=2"* ]]
  ! grep -qF "issue edit" "$GH_LOG"
}

# ── blocked_by evaluation ─────────────────────────────────────────────────────

@test "blocked_by: does not label an issue that has an open blocker" {
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
# Epic labels: initiative:auto
if [[ "$args" == *"issues/1 --jq"* ]] && [[ "$args" != *"sub_issues"* ]]; then
  printf 'initiative:auto'; exit 0
fi
# Epic #1 sub-issues: only issue 2
if [[ "$args" == *"issues/1/sub_issues"* ]]; then printf '2'; exit 0; fi
# Issue 2 has no sub-issues of its own (a story, not an epic)
if [[ "$args" == *"issues/2/sub_issues"* ]]; then printf ''; exit 0; fi
# Issue 2 has no dev-lead yet
if [[ "$args" == *"issues/2 --jq"* ]]; then printf ''; exit 0; fi
# Issue 2 has an open blocker (issue 99)
if [[ "$args" == *"issues/2/dependencies/blocked_by"* ]]; then printf '99'; exit 0; fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"blocked by open"* ]]
  ! grep -qF "issue edit" "$GH_LOG"
}

@test "blocked_by: labels a sub-issue when all blockers are closed" {
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
# Epic labels: initiative:auto
if [[ "$args" == *"issues/1 --jq"* ]] && [[ "$args" != *"sub_issues"* ]]; then
  printf 'initiative:auto'; exit 0
fi
# Epic #1 sub-issues: only issue 2
if [[ "$args" == *"issues/1/sub_issues"* ]]; then printf '2'; exit 0; fi
# Issue 2 has no sub-issues of its own (a story, not an epic)
if [[ "$args" == *"issues/2/sub_issues"* ]]; then printf ''; exit 0; fi
# Issue 2 has no dev-lead yet
if [[ "$args" == *"issues/2 --jq"* ]]; then printf ''; exit 0; fi
# No open blockers
if [[ "$args" == *"issues/2/dependencies/blocked_by"* ]]; then printf ''; exit 0; fi
# Label application succeeds
if [[ "$args" == "issue edit"* ]]; then exit 0; fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RELEASED"* ]]
  grep -qF "issue edit" "$GH_LOG"
}

# ── nested-epic skip: never release a sub-issue that is itself an epic ────────
# Incident #934/#938 (refs #882): an `initiative:auto` epic nested as a native
# sub-issue of an armed parent epic was released as a "story" and closed by
# dev-lead, orphaning its own real stories. A nested epic is driven on its own
# via the sweep, so the parent must skip it.

@test "nested-epic: skips a sub-issue carrying the gate label (drive it independently)" {
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
# Epic #1 carries the gate label
if [[ "$args" == *"issues/1 --jq"* ]] && [[ "$args" != *"sub_issues"* ]]; then
  printf 'initiative:auto'; exit 0
fi
# Epic #1 sub-issues: only issue 2 (which is itself a nested epic)
if [[ "$args" == *"issues/1/sub_issues"* ]]; then printf '2'; exit 0; fi
# Issue 2 carries the gate label too — it is itself an armed epic
if [[ "$args" == *"issues/2 --jq"* ]] && [[ "$args" != *"sub_issues"* ]]; then
  printf 'initiative:auto'; exit 0
fi
# Issue 2 has no materialized children yet — the gate label alone must skip it
if [[ "$args" == *"issues/2/sub_issues"* ]]; then printf ''; exit 0; fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#2 — skip: is itself an epic"* ]]
  ! grep -qF "issue edit" "$GH_LOG"
}

@test "nested-epic: skips a sub-issue that has its own native sub-issues" {
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
# Epic #1 carries the gate label
if [[ "$args" == *"issues/1 --jq"* ]] && [[ "$args" != *"sub_issues"* ]]; then
  printf 'initiative:auto'; exit 0
fi
# Epic #1 sub-issues: only issue 2
if [[ "$args" == *"issues/1/sub_issues"* ]]; then printf '2'; exit 0; fi
# Issue 2 has only the plain initiative label (no gate) but has its own children
if [[ "$args" == *"issues/2 --jq"* ]] && [[ "$args" != *"sub_issues"* ]]; then
  printf 'initiative'; exit 0
fi
# Issue 2 has a native sub-issue of its own (issue 5) — so it is itself an epic
if [[ "$args" == *"issues/2/sub_issues"* ]]; then printf '5'; exit 0; fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#2 — skip: is itself an epic"* ]]
  ! grep -qF "issue edit" "$GH_LOG"
}

@test "nested-epic: a plain story (initiative label, no children, no gate) is still released" {
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
# Epic #1 carries the gate label
if [[ "$args" == *"issues/1 --jq"* ]] && [[ "$args" != *"sub_issues"* ]]; then
  printf 'initiative:auto'; exit 0
fi
# Epic #1 sub-issues: only issue 2
if [[ "$args" == *"issues/1/sub_issues"* ]]; then printf '2'; exit 0; fi
# Issue 2 is an ordinary story: plain initiative label, no gate label
if [[ "$args" == *"issues/2 --jq"* ]] && [[ "$args" != *"sub_issues"* ]]; then
  printf 'initiative'; exit 0
fi
# Issue 2 has no native sub-issues of its own — it is NOT an epic
if [[ "$args" == *"issues/2/sub_issues"* ]]; then printf ''; exit 0; fi
# Issue 2 has no open blockers
if [[ "$args" == *"issues/2/dependencies/blocked_by"* ]]; then printf ''; exit 0; fi
# Label application succeeds
if [[ "$args" == "issue edit"* ]]; then exit 0; fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RELEASED"* ]]
  [[ "$output" != *"is itself an epic"* ]]
  grep -qF "issue edit" "$GH_LOG"
}

# ── sweep mode: EPIC empty discovers all gated epics ─────────────────────────

@test "sweep: drives every open epic carrying initiative:auto when EPIC is empty" {
  export EPIC=""
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
# Discovery query (state=open & labels=initiative:auto): two gated epics 10, 11
if [[ "$args" == *"-f state=open"* ]]; then printf '10\n11'; exit 0; fi
# Each epic carries the gate label
if [[ "$args" == *"issues/10 --jq"* ]] || [[ "$args" == *"issues/11 --jq"* ]]; then
  printf 'initiative:auto'; exit 0
fi
# Neither epic has sub-issues — both no-op cleanly
if [[ "$args" == *"sub_issues"* ]]; then printf ''; exit 0; fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found 2 gated epic(s): 10 11"* ]]
  [[ "$output" == *"Driving epic #10"* ]]
  [[ "$output" == *"Driving epic #11"* ]]
  # Neither epic has sub-issues, so nothing should be labeled.
  ! grep -qF "issue edit" "$GH_LOG"
}

@test "sweep: a gh failure on one epic surfaces as an error (not masked) and the sweep continues" {
  export EPIC=""
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
# Discovery: two gated epics 10, 11
if [[ "$args" == *"-f state=open"* ]]; then printf '10\n11'; exit 0; fi
# Epic 10: the labels lookup fails (simulated API/network error)
if [[ "$args" == *"issues/10 --jq"* ]]; then exit 1; fi
# Epic 11: healthy, gated, no sub-issues
if [[ "$args" == *"issues/11 --jq"* ]]; then printf 'initiative:auto'; exit 0; fi
if [[ "$args" == *"sub_issues"* ]]; then printf ''; exit 0; fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  # Non-zero overall (the failure is no longer swallowed as a false no-op)…
  [ "$status" -ne 0 ]
  [[ "$output" == *"driver failed for epic #10"* ]]
  # …but epic #11 was still driven.
  [[ "$output" == *"Driving epic #11"* ]]
  [[ "$output" == *"no sub-issues"* ]]
}

@test "sweep: no-op when no open epic carries initiative:auto" {
  export EPIC=""
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
if [[ "$args" == *"-f state=open"* ]]; then printf ''; exit 0; fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No open epics carry"* ]]
  ! grep -qF "issue edit" "$GH_LOG"
}

# ── cross-repo: a non-self target_repo sweep targets that repo on every call ───
# Mirrors the workflow's REPO = target_repo || github.repository plumbing: when
# the central driver is dispatched with REPO=<other/repo>, every gh call — the
# epic discovery, gate read, sub_issues/blocked_by reads, and the release
# `gh issue edit --repo <other/repo>` — must be repo-qualified to that repo so
# cross-repo dev-lead labeling lands in the target, not in .github-private.

@test "cross-repo: a non-self target_repo sweep targets that repo on every API and label call" {
  export EPIC=""
  export REPO="other/repo"
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
# Discovery query against the TARGET repo: one gated epic 10
if [[ "$args" == *"repos/other/repo/issues -f state=open"* ]]; then printf '10'; exit 0; fi
# Epic 10 (in the target repo) carries the gate label
if [[ "$args" == *"repos/other/repo/issues/10 --jq"* ]]; then printf 'initiative:auto'; exit 0; fi
# Sub-issues of epic 10 in the target repo: one open child, issue 2
if [[ "$args" == *"repos/other/repo/issues/10/sub_issues"* ]]; then printf '2'; exit 0; fi
# Issue 2 has no sub-issues of its own (a story, not an epic)
if [[ "$args" == *"repos/other/repo/issues/2/sub_issues"* ]]; then printf ''; exit 0; fi
# Issue 2 has no dev-lead yet
if [[ "$args" == *"repos/other/repo/issues/2 --jq"* ]]; then printf ''; exit 0; fi
# Issue 2 has no open blockers
if [[ "$args" == *"repos/other/repo/issues/2/dependencies/blocked_by"* ]]; then printf ''; exit 0; fi
# Label application succeeds
if [[ "$args" == "issue edit"* ]]; then exit 0; fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found 1 gated epic(s): 10"* ]]
  [[ "$output" == *"RELEASED"* ]]
  # Every repo-qualified read flowed through the target repo…
  grep -qF "repos/other/repo/issues -f state=open" "$GH_LOG"
  grep -qF "repos/other/repo/issues/10/sub_issues" "$GH_LOG"
  grep -qF "repos/other/repo/issues/2/dependencies/blocked_by" "$GH_LOG"
  # …and the release labeled the sub-issue in the target repo, not self.
  grep -qF "issue edit 2 --repo other/repo --add-label dev-lead" "$GH_LOG"
  ! grep -qF "combsmith/.github-private" "$GH_LOG"
}
