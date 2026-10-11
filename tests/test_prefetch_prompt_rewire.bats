#!/usr/bin/env bats
# Structural guard for the tier-3 audit + single-review pre-fed-context rewire
# (epic #1101, Story 5 / #1105).
#
# Story 2 (#1103) persists the FULL diff + superset metadata ONCE to SHA-bound
# files exposed as PR_CONTEXT_DIFF_FILE / PR_CONTEXT_METADATA_FILE (gated
# DEFAULT-OFF behind PREFETCH_CONTEXT_ENABLED). This story rewires
# prompts/security-audit.md and prompts/single-review.md to CONSUME those files
# instead of re-running `gh pr view` / `gh pr diff` when they are present and
# fresh, while staying byte-identical when the flag is off (files absent), and
# keeping their dynamic `gh api` / MCP / LSP steps intact.
#
# These checks are deterministic and offline — the live single/audit smoke run
# (AC #5) needs the real cascade engine. They guard against the pre-fed section
# being silently removed or hollowed out by a future edit/template sync, the same
# silent-revert regression class the repo defends against elsewhere (#655, #823).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  AUDIT="$ROOT/prompts/security-audit.md"
  SINGLE="$ROOT/prompts/single-review.md"
  ACTION="$ROOT/prompts/cascade-action.md"
}

# Extract the body of the "Pre-fed PR context" section (from its heading up to
# the next `## ` heading) so the pre-fed-specific assertions cannot accidentally
# match text elsewhere in the prompt.
_prefed_section() {
  [ -f "${1:-}" ] || return 1
  awk '
    /^##[[:space:]]+Pre-fed PR context/ { insec=1; next }
    insec && /^##[[:space:]]/           { insec=0 }
    insec                               { print }
  ' "$1"
}

# Extract the body of an arbitrary named section (heading word(s) passed as $1,
# file as $2) so fallback-step assertions cannot accidentally match prose in the
# Pre-fed PR context section that also mentions `gh pr view` / `gh pr diff`.
_section() {
  local heading="$1" file="$2"
  [ -f "${file:-}" ] || return 1
  awk -v pat="^##[[:space:]]+${heading}" '
    $0 ~ pat              { insec=1; next }
    insec && /^##[[:space:]]/ { insec=0 }
    insec                 { print }
  ' "$file"
}

# --- security-audit.md ------------------------------------------------------

@test "audit prompt has a Pre-fed PR context section" {
  grep -Eq '^##[[:space:]]+Pre-fed PR context' "$AUDIT"
}

@test "audit pre-fed section references both context env vars" {
  section="$(_prefed_section "$AUDIT")"
  grep -q 'PR_CONTEXT_METADATA_FILE' <<<"$section"
  grep -q 'PR_CONTEXT_DIFF_FILE' <<<"$section"
}

@test "audit pre-fed section says to read the files INSTEAD of gh, else fall back" {
  # The 'if set, read instead of gh; else run gh as before' contract keeps the
  # flag-off path byte-identical.
  section="$(_prefed_section "$AUDIT")"
  grep -Eiq 'instead of' <<<"$section"
  grep -Eiq 'fall back|else|otherwise' <<<"$section"
}

@test "audit pre-fed section verifies the PR_HEAD_SHA freshness stamp" {
  section="$(_prefed_section "$AUDIT")"
  grep -q 'PR_HEAD_SHA' <<<"$section"
  grep -Eiq 'pr_head_sha|stamp|match|fresh' <<<"$section"
}

@test "audit prompt retains its dynamic gh api standards fetch" {
  # The org-standards fetch (CONTRIBUTING/AGENTS/CODEOWNERS via gh api) is
  # DYNAMIC and must survive the rewire — it is not part of the pre-fed context.
  grep -q 'gh api' "$AUDIT"
}

@test "audit prompt still keeps gh pr view / gh pr diff as the fallback fetch" {
  steps="$(_section 'Steps' "$AUDIT")"
  grep -q 'gh pr view' <<<"$steps"
  grep -q 'gh pr diff' <<<"$steps"
}

# --- single-review.md -------------------------------------------------------

@test "single-review prompt has a Pre-fed PR context section" {
  grep -Eq '^##[[:space:]]+Pre-fed PR context' "$SINGLE"
}

@test "single-review pre-fed section references both context env vars" {
  section="$(_prefed_section "$SINGLE")"
  grep -q 'PR_CONTEXT_METADATA_FILE' <<<"$section"
  grep -q 'PR_CONTEXT_DIFF_FILE' <<<"$section"
}

@test "single-review pre-fed section says to read the files INSTEAD of gh, else fall back" {
  section="$(_prefed_section "$SINGLE")"
  grep -Eiq 'instead of' <<<"$section"
  grep -Eiq 'fall back|else|otherwise' <<<"$section"
}

@test "single-review pre-fed section verifies the PR_HEAD_SHA freshness stamp" {
  section="$(_prefed_section "$SINGLE")"
  grep -q 'PR_HEAD_SHA' <<<"$section"
  grep -Eiq 'pr_head_sha|stamp|match|fresh' <<<"$section"
}

@test "single-review prompt keeps its dynamic MCP secret scan + incremental compare" {
  # These are beyond the pre-fed metadata/diff and must remain dynamic.
  grep -q 'run_secret_scanning' "$SINGLE"
  grep -q 'compare/' "$SINGLE"
}

@test "single-review prompt still keeps gh pr view / gh pr diff as the fallback fetch" {
  ctx="$(_section 'Context-gathering' "$SINGLE")"
  grep -q 'gh pr view' <<<"$ctx"
  grep -q 'gh pr diff' <<<"$ctx"
}

@test "single-review prompt preserves the draft / head-sha-changed skip checks" {
  # The step-1 skip guards must not be lost when rewiring the fetch — they gate
  # off the metadata regardless of whether it was pre-fed or fetched live.
  grep -q 'isDraft' "$SINGLE"
  grep -q 'head-sha-changed' "$SINGLE"
}

# --- cascade-action.md (AC #4: confirmed out of scope) ----------------------

@test "cascade-action prompt is documented as not fetching the diff (out of scope)" {
  # It synthesizes prior verdicts from $FINAL_RESULT and never fetches the diff,
  # so it needs no pre-fed-context rewire — documented explicitly per AC #4.
  grep -Eiq 'does not fetch|no.*fetch|out of scope|synthes' "$ACTION"
  # Verify implementation: cascade-action must contain no live fetch commands.
  ! grep -q 'gh pr view' "$ACTION" || false
  ! grep -q 'gh pr diff' "$ACTION"
}
