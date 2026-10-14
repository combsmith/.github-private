#!/usr/bin/env bats
# Unit tests for the PR-limit admission gate wired into dev-lead-fix-issue.sh.
# Epic petry-projects/.github#505 Phase 3. Mirrors the stub pattern in
# test_fix_issue.bats: engine stubs on PATH, a gh stub, a git stub for the
# non-dry-run commit/push path, and a per-test PLG_STANDARDS_DIR fixture holding
# a FAKE guard + minimal limits config so allow/defer is driven by FAKE_GATE
# without the real guard or any network access.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
FIX_ISSUE_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-fix-issue.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"

  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini"
  export PATH="$STUB_BIN_DIR:$PATH"
  export STUB_BIN_DIR

  # Flag files the gh stub touches so tests can assert what happened.
  PR_CREATED_FLAG="$(mktemp -u)"; export PR_CREATED_FLAG
  COMMENT_FILE="$(mktemp)"; export COMMENT_FILE
  # Prior issue comments the gh stub serves for the comments-list query.
  # Unconditionally reset to empty so no deferral comment pre-exists; individual
  # tests (e.g. the idempotency test) override it after setup.
  PRIOR_COMMENTS_JSON="[]"; export PRIOR_COMMENTS_JSON

  # gh stub: no existing PRs; serves issue title/body; records `pr create` via a
  # flag file; records every posted comment body; serves prior comments for the
  # idempotency check. Dispatch on the subcommand ($1) so the prompt body's
  # literal "gh api" examples cannot mask the real branches. The comments query
  # applies the real --jq expression (so the length/startswith idempotency check
  # behaves like real gh). Reads PR_CREATED_FLAG / COMMENT_FILE / the (possibly
  # per-test) PRIOR_COMMENTS_JSON from the exported environment at runtime.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
cmd="$1"; shift || true
# Extract a --jq expression if present.
jqexpr=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  [ "${args[$i]}" = "--jq" ] && jqexpr="${args[$((i+1))]}"
done
case "$cmd" in
  api)
    case "$*" in
      *"pulls?state=open"*) echo "[]" ;;
      *comments*)
        # Emit a single page so the script's `jq -s 'add // 0'` sums correctly.
        # Tolerates a leading --paginate flag (extracted via the --jq loop above).
        if [ -n "$jqexpr" ]; then
          jq -r "$jqexpr" <<< "${PRIOR_COMMENTS_JSON:-[]}"
        else
          printf '%s' "${PRIOR_COMMENTS_JSON:-[]}"
        fi ;;
      *"users/"*)  echo '{"id":12345}' ;;
      *"issues/"*) echo '{"title":"Test Issue","body":"Test issue body"}' ;;
      *)           echo "{}" ;;
    esac ;;
  pr)
    case "$*" in
      create*) touch "$PR_CREATED_FLAG"; echo "https://github.com/x/y/pull/1"; exit 0 ;;
      *)       echo "{}" ;;
    esac ;;
  issue)
    sub="$1"; shift || true
    case "$sub" in
      comment)
        body=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--body" ]; then body="$2"; shift 2; continue; fi
          shift
        done
        printf '%s\n----8<----\n' "$body" >> "$COMMENT_FILE"
        exit 0 ;;
      *) echo "{}" ;;
    esac ;;
  label) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  # git stub for the non-dry-run commit/push path. status --porcelain reports a
  # change so the script reaches lint → commit → push → gh pr create.
  cat > "$STUB_BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  "config"*)            exit 0 ;;
  "checkout -b"*)       exit 0 ;;
  "rev-parse HEAD")     echo "abc123deadbeef" ;;
  "status --porcelain") echo "M scripts/foo.sh" ;;
  "add -A")             exit 0 ;;
  "commit"*)            exit 0 ;;
  "push"*)              exit 0 ;;
  *)                    exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  # Lint stub that always passes so the commit path is not blocked by real lint.
  cat > "$STUB_BIN_DIR/dev-lead-lint.sh" <<'LINTEOF'
#!/usr/bin/env bash
echo "  [lint] all checks passed (stub)"
exit 0
LINTEOF
  chmod +x "$STUB_BIN_DIR/dev-lead-lint.sh"

  # Per-test standards fixture: a FAKE guard (allow/defer driven by FAKE_GATE)
  # plus a minimal limits config. PLG_STANDARDS_DIR routes _plg_fetch here.
  PLG_STANDARDS_DIR="$(mktemp -d)"; export PLG_STANDARDS_DIR
  mkdir -p "$PLG_STANDARDS_DIR/scripts/lib" "$PLG_STANDARDS_DIR/standards"
  cat > "$PLG_STANDARDS_DIR/scripts/lib/pr-limit-gate.sh" <<'GUARDEOF'
#!/usr/bin/env bash
# FAKE guard for tests. Asserts the production contract so a regression cannot
# pass silently via the script's fail-open: the source arg must be "dev-lead"
# and PR_LIMITS_CONFIG must point at a readable config. A contract violation
# returns 2 (an unexpected code the script treats as fail-open) AND logs to
# stderr, which breaks the allow/defer assertions in tests 1 and 2. Otherwise
# defer only when FAKE_GATE=defer.
plg_admission_gate() {
  [ "$1" = "dev-lead" ] || { echo "FAKE-GUARD: expected source 'dev-lead', got '$1'" >&2; return 2; }
  [ -r "${PR_LIMITS_CONFIG:-}" ] || { echo "FAKE-GUARD: PR_LIMITS_CONFIG not readable: '${PR_LIMITS_CONFIG:-}'" >&2; return 2; }
  [ "${FAKE_GATE:-allow}" = "defer" ] && return 1 || return 0
}
GUARDEOF
  cat > "$PLG_STANDARDS_DIR/standards/pr-limits.json" <<'CFGEOF'
{"org_wide":{"automation_open_pr_cap":50},"per_source_caps":{},"exempt_actors":[],"exempt_labels":[]}
CFGEOF

  export ISSUE_NUMBER="100"
  export REPO="petry-projects/.github-private"
  export REVIEW_ENGINE="claude"
  export GITHUB_REPOSITORY="petry-projects/.github-private"
  export LINT_SCRIPT="$STUB_BIN_DIR/dev-lead-lint.sh"

  cd "$SCRIPT_DIR"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$PR_CREATED_FLAG" "$COMMENT_FILE"
  [ -z "${CAP_SEEN_FILE:-}" ] || rm -f "$CAP_SEEN_FILE"
  rm -rf "$STUB_BIN_DIR" "$PLG_STANDARDS_DIR"
}

@test "pr-limit gate: under cap → opens PR (gh pr create called)" {
  export DEV_LEAD_DRY_RUN="false"
  export FAKE_GATE="allow"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [ -f "$PR_CREATED_FLAG" ]
}

@test "pr-limit gate: at/over cap → defers (gh pr create NOT called)" {
  export DEV_LEAD_DRY_RUN="false"
  export FAKE_GATE="defer"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [ ! -f "$PR_CREATED_FLAG" ]
  [[ "$output" == *"PR-limit gate: deferring issue #100"* ]]
}

@test "pr-limit gate: defer → posts one deferral comment with the marker" {
  export DEV_LEAD_DRY_RUN="false"
  export FAKE_GATE="defer"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  local posted; posted=$(cat "$COMMENT_FILE")
  [[ "$posted" == *"<!-- dev-lead-issue-deferred -->"* ]]
  # Exactly one deferral comment posted.
  local marker_count
  marker_count=$(grep -c -- "<!-- dev-lead-issue-deferred -->" "$COMMENT_FILE" || true)
  [ "$marker_count" -eq 1 ]
}

@test "pr-limit gate: defer idempotent → no new comment when a marker already exists" {
  export DEV_LEAD_DRY_RUN="false"
  export FAKE_GATE="defer"
  # gh stub serves an existing deferral comment for the comments-list query, so
  # deferral_comment_exists returns true and post_deferral_comment is a no-op.
  export PRIOR_COMMENTS_JSON='[{"body":"<!-- dev-lead-issue-deferred -->\nprior deferral"}]'

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [ ! -f "$PR_CREATED_FLAG" ]
  # No new deferral comment was posted (COMMENT_FILE stays empty).
  [ ! -s "$COMMENT_FILE" ]
}

@test "pr-limit gate: dry-run over cap → exits via [dry-run], gate not consulted" {
  export DEV_LEAD_DRY_RUN="true"
  export FAKE_GATE="defer"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  # Gate never ran → no defer notice, no deferral comment, no PR.
  [[ "$output" != *"PR-limit gate: deferring"* ]]
  [ ! -f "$PR_CREATED_FLAG" ]
  [ ! -s "$COMMENT_FILE" ]
}

@test "pr-limit gate: fetch failure → fails open, opens PR, warns" {
  export DEV_LEAD_DRY_RUN="false"
  export FAKE_GATE="defer"
  # Point PLG_STANDARDS_DIR at an EMPTY dir so _plg_fetch cannot find the guard.
  PLG_STANDARDS_DIR="$(mktemp -d)"; export PLG_STANDARDS_DIR

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [ -f "$PR_CREATED_FLAG" ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"failing open"* ]]
}

# ── PR_LIMITS_ORG_CAP wiring (#2018) ─────────────────────────────────────────
# The shared guard's plg_effective_org_cap (petry-projects/.github#1221) reads
# PR_LIMITS_ORG_CAP as a runtime override for the org-wide cap. The org variable
# only takes effect if every workflow step that runs the gate maps it into env.

# Overwrite the fake guard with one that records the PR_LIMITS_ORG_CAP it sees
# ("<unset>" when absent) so tests can assert the value reaches the gate.
_install_cap_recording_guard() {
  CAP_SEEN_FILE="$(mktemp)" || { echo "Failed to create temp file" >&2; return 1; }
  export CAP_SEEN_FILE
  cat > "$PLG_STANDARDS_DIR/scripts/lib/pr-limit-gate.sh" <<'GUARDEOF'
#!/usr/bin/env bash
plg_admission_gate() {
  printf '%s' "${PR_LIMITS_ORG_CAP-<unset>}" > "$CAP_SEEN_FILE"
  return 0
}
GUARDEOF
}

@test "pr-limit gate: PR_LIMITS_ORG_CAP from step env reaches plg_admission_gate" {
  export DEV_LEAD_DRY_RUN="false"
  export PR_LIMITS_ORG_CAP="42"
  _install_cap_recording_guard

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(cat "$CAP_SEEN_FILE")" = "42" ]
  rm -f "$CAP_SEEN_FILE"
}

@test "pr-limit gate: PR_LIMITS_ORG_CAP unset → script does not inject a cap" {
  export DEV_LEAD_DRY_RUN="false"
  unset PR_LIMITS_ORG_CAP
  _install_cap_recording_guard

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(cat "$CAP_SEEN_FILE")" = "<unset>" ]
  rm -f "$CAP_SEEN_FILE"
}

# In workflows, ${{ vars.PR_LIMITS_ORG_CAP }} renders as "" (set-but-empty) when the
# org variable is undefined, so that is the production "no override" path.
@test "pr-limit gate: PR_LIMITS_ORG_CAP empty (undefined org var) → passed through as empty" {
  export DEV_LEAD_DRY_RUN="false"
  export PR_LIMITS_ORG_CAP=""
  _install_cap_recording_guard

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(cat "$CAP_SEEN_FILE")" = "" ]
  rm -f "$CAP_SEEN_FILE"
}

@test "pr-limit gate: every workflow step running dev-lead-fix-issue.sh maps vars.PR_LIMITS_ORG_CAP" {
  # yq is preinstalled on GitHub-hosted runners; never let this regression check
  # silently vanish from CI (skip is for local runs only).
  if ! command -v yq >/dev/null; then
    [ -z "${CI:-}" ] || { echo "yq is required in CI" >&2; return 1; }
    skip "yq not installed"
  fi
  local wf count bad_steps found=0
  for wf in "$SCRIPT_DIR"/.github/workflows/*.yml; do
    count=$(yq -r '[.jobs[].steps[]? | select((.run // "") | test("dev-lead-fix-issue\\.sh"))] | length' "$wf")
    [ "$count" -gt 0 ] || continue
    found=$((found + count))
    # Steps running the script that do not map the variable (unnamed-safe).
    bad_steps=$(yq -r '.jobs[].steps[]? | select((.run // "") | test("dev-lead-fix-issue\\.sh")) | select(.env.PR_LIMITS_ORG_CAP != "${{ vars.PR_LIMITS_ORG_CAP }}") | (.name // "unnamed step")' "$wf")
    [ -z "$bad_steps" ] || {
      echo "$(basename "$wf"): steps lacking PR_LIMITS_ORG_CAP: $bad_steps" >&2
      return 1
    }
  done
  # Guard against the selector silently matching nothing.
  [ "$found" -ge 2 ]
}
