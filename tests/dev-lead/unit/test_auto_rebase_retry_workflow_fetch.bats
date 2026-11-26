#!/usr/bin/env bats
# Behavioural tests for the inline self-fetch step of
# .github/workflows/auto-rebase-retry.yml (#2640).
#
# The retry job self-fetches scripts/auto-rebase-retry.sh with `gh api` (no
# actions/checkout, #1473). The DEGRADED metric in #2640 came from that fetch
# hitting "API rate limit exceeded" (HTTP 403) on the shared PAT budget: under
# `set -euo pipefail` the job failed before the always-exit-0 script ever ran.
# These tests extract the step's `run:` body verbatim and execute it against a
# stubbed `gh`, pinning that:
#   - a primary-token fetch failure falls back to the job's own github.token
#     (a separate rate-limit bucket), which is then used for the retry itself;
#   - when every fetch fails the step warns and exits 0 instead of failing.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/auto-rebase-retry.yml"

setup() {
  WORK_DIR="$(mktemp -d)"
  STUB_BIN_DIR="$WORK_DIR/bin"
  mkdir -p "$STUB_BIN_DIR"
  export RUNNER_TEMP="$WORK_DIR/runner-temp"
  mkdir -p "$RUNNER_TEMP"
  export GH_CALLS="$WORK_DIR/gh-calls"
  export SCRIPT_RAN_MARKER="$WORK_DIR/script-ran"
  : > "$GH_CALLS"

  # Extract the retry step's `run: |` block body (dedented) from the workflow.
  STEP_BODY="$WORK_DIR/step.sh"
  awk '
    done { next }
    /^[[:space:]]+FALLBACK_GH_TOKEN:/ && !inblk { ready=1 }
    ready && !inblk && /^[[:space:]]+run: \|[[:space:]]*$/ { inblk=1; match($0, /^[[:space:]]+/); ind=RLENGTH + 2; next }
    inblk {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      match($0, /^[[:space:]]*/)
      if (RLENGTH < ind) { inblk=0; done=1; next }
      print substr($0, ind + 1)
    }
  ' "$WORKFLOW" > "$STEP_BODY"

  # Stub gh: `gh api …contents…` succeeds only for tokens listed in
  # GH_STUB_GOOD_TOKENS (space separated) and emits a fake retry script that
  # records which GH_TOKEN it ran under.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "token=${GH_TOKEN:-} args=$*" >> "$GH_CALLS"
case "$*" in
  *contents/scripts/auto-rebase-retry.sh*)
    for t in ${GH_STUB_GOOD_TOKENS:-}; do
      if [ "$t" = "${GH_TOKEN:-}" ]; then
        printf '#!/usr/bin/env bash\necho "ran-with=${GH_TOKEN:-}" > "$SCRIPT_RAN_MARKER"\n'
        exit 0
      fi
    done
    echo "gh: API rate limit exceeded for user ID 1. (HTTP 403)" >&2
    exit 1
    ;;
esac
exit 0
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export PATH="$STUB_BIN_DIR:$PATH"

  export GITHUB_REPOSITORY="combsmith/.github-private"
  export GH_TOKEN="primary-pat"
  export FALLBACK_GH_TOKEN="job-token"
}

teardown() {
  rm -rf "$WORK_DIR"
}

_run_step() { run bash -e "$STEP_BODY"; }

@test "fetch-step: run body was extracted from the workflow" {
  grep -q 'contents/scripts/auto-rebase-retry.sh' "$STEP_BODY"
  grep -q 'bash "\$script"' "$STEP_BODY"
}

@test "fetch-step: primary fetch succeeds → script runs with the primary token" {
  export GH_STUB_GOOD_TOKENS="primary-pat job-token"
  _run_step
  [ "$status" -eq 0 ]
  [ -f "$SCRIPT_RAN_MARKER" ]
  grep -qx 'ran-with=primary-pat' "$SCRIPT_RAN_MARKER"
  # No fallback fetch when the primary one worked.
  ! grep -q 'token=job-token' "$GH_CALLS"
}

@test "fetch-step: primary fetch rate-limited → falls back to job token and runs script with it" {
  export GH_STUB_GOOD_TOKENS="job-token"
  _run_step
  [ "$status" -eq 0 ]
  [ -f "$SCRIPT_RAN_MARKER" ]
  grep -qx 'ran-with=job-token' "$SCRIPT_RAN_MARKER"
  grep -q 'token=primary-pat' "$GH_CALLS"
  grep -q 'token=job-token' "$GH_CALLS"
}

@test "fetch-step: every fetch fails → warns, exits 0, script not executed" {
  export GH_STUB_GOOD_TOKENS=""
  _run_step
  [ "$status" -eq 0 ]
  [ ! -f "$SCRIPT_RAN_MARKER" ]
  [[ "$output" == *"::warning::"* ]]
}

@test "fetch-step: no fallback token configured → warns and exits 0 on primary failure" {
  export GH_STUB_GOOD_TOKENS="job-token"
  unset FALLBACK_GH_TOKEN
  _run_step
  [ "$status" -eq 0 ]
  [ ! -f "$SCRIPT_RAN_MARKER" ]
  [[ "$output" == *"::warning::"* ]]
}

@test "fetch-step: workflow wires FALLBACK_GH_TOKEN to the job's github.token" {
  grep -Eq '^[[:space:]]+FALLBACK_GH_TOKEN:[[:space:]]*['\''"]?\$\{\{[[:space:]]*github\.token[[:space:]]*\}\}['\''"]?[[:space:]]*$' "$WORKFLOW"
}
