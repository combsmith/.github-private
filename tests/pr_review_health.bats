#!/usr/bin/env bats
# Tests for scripts/pr_review_health.sh — how the Claude log-analysis call's
# failure is handled (#2446). `gh` and `claude` are stubbed on PATH, so no
# network I/O happens; the stubbed gh returns an empty run window.
# Run locally: bats tests/pr_review_health.bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/pr_review_health.sh"
  WORK="$(mktemp -d)"
  STUB_BIN="${WORK}/bin"
  mkdir -p "$STUB_BIN"

  # gh stub: every run list is empty, workflow discovery finds no ingress
  # workflow, and the workflow-source read fails (the script tolerates it).
  cat > "${STUB_BIN}/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *"/contents/"*) exit 1 ;;
  *"actions/workflows?per_page"*) exit 0 ;;
  *"created="*) echo '[]' ;;
  *) echo '{}' ;;
esac
GH
  chmod +x "${STUB_BIN}/gh"

  export PATH="${STUB_BIN}:${PATH}"
  export GITHUB_ENV="${WORK}/github_env"
  export GITHUB_STEP_SUMMARY="${WORK}/step_summary"
  : > "$GITHUB_ENV"
  : > "$GITHUB_STEP_SUMMARY"
  cd "$WORK" || return 1
}

teardown() {
  rm -rf "$WORK"
}

# make_claude <exit_code> <stdout_text> [stderr_text]
make_claude() {
  {
    printf '#!/usr/bin/env bash\ncat >/dev/null\n'
    printf 'printf %%s\\\\n %q\n' "$2"
    [ -n "${3:-}" ] && printf 'printf %%s\\\\n %q >&2\n' "$3"
    printf 'exit %s\n' "$1"
  } > "${STUB_BIN}/claude"
  chmod +x "${STUB_BIN}/claude"
}

@test "quota refusal from Claude: warns, keeps the deterministic report, exits 0" {
  make_claude 1 "You've hit your weekly limit · resets 4pm (UTC)"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"*"quota"* ]]
  grep -q '## Convergence latency (deterministic)' pr_review_health_report.md
  grep -q 'Log analysis skipped' pr_review_health_report.md
  # The CLI's refusal line is not pasted into the report as if it were analysis.
  run grep -c "hit your weekly limit" pr_review_health_report.md
  [ "$output" = "0" ]
  grep -q 'Log analysis skipped' "$GITHUB_STEP_SUMMARY"
}

@test "quota refusal reported on stderr is also recognised" {
  make_claude 1 "" "API Error: 429 Too Many Requests"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'Log analysis skipped' pr_review_health_report.md
}

@test "non-quota Claude failure still fails the step" {
  make_claude 1 "Error: model not found"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::Claude invocation failed"* ]]
  [[ "$output" == *"Error: model not found"* ]]
}

@test "successful Claude call appends the analysis to the report" {
  make_claude 0 "### 1. Executive Summary"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '## Convergence latency (deterministic)' pr_review_health_report.md
  grep -q '### 1. Executive Summary' pr_review_health_report.md
  run grep -c 'Log analysis skipped' pr_review_health_report.md
  [ "$output" = "0" ]
}

@test "a successful analysis that discusses rate limits is not treated as a refusal" {
  make_claude 0 "| Engine rate limit (Claude or Copilot quota) | 0 | — |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'Engine rate limit' pr_review_health_report.md
  [[ "$output" != *"::warning::"*"quota"* ]]
}
