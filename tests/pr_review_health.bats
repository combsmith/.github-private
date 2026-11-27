#!/usr/bin/env bats
# Tests for scripts/pr_review_health.sh — how the Claude log-analysis call's
# failure is handled (#2446). `gh` and `claude` are stubbed on PATH, so no
# network I/O happens; the stubbed gh returns an empty run window.
# Run locally: bats tests/pr_review_health.bats

# Set up test environment: create stubs for gh and claude CLIs.
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

# Clean up temporary test directories.
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
  run grep -c "429 Too Many Requests" pr_review_health_report.md
  [ "$output" = "0" ]
}

@test "documented 'reached your weekly limit' wording is recognised" {
  make_claude 1 "You've reached your weekly limit · resets 4pm (UTC)"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'Log analysis skipped' pr_review_health_report.md
}

@test "'5-hour limit reached' wording is recognised" {
  make_claude 1 "5-hour limit reached - resets 4pm"
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

# ── Engine configuration overrides (#2630, part 2 of #1973) ──────────────────
# The report lists each AI_MODELS_* / AI_ENGINES value that is set and differs
# from config/ai-engines.json, so a break-glass override is folded back into
# the file rather than living on silently.

_unset_engine_overrides() {
  unset AI_MODELS_CLAUDE AI_MODELS_GEMINI AI_MODELS_COPILOT AI_ENGINES DEV_LEAD_ENGINES AI_ENGINES_CONFIG
}

@test "overrides: none set → the section says every default comes from the file" {
  _unset_engine_overrides
  make_claude 0 "### 1. Executive Summary"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '## Engine configuration overrides' pr_review_health_report.md
  grep -q 'None: every engine and model default comes from `config/ai-engines.json`' pr_review_health_report.md
  [[ "$output" != *"engine override differs"* ]]
}

@test "overrides: a differing AI_MODELS_* key and AI_ENGINES are listed and warned" {
  _unset_engine_overrides
  export AI_MODELS_CLAUDE="deep=claude-opus-4-8"
  export AI_ENGINES="gemini,claude"
  make_claude 0 "### 1. Executive Summary"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- '- `AI_MODELS_CLAUDE deep=claude-opus-4-8 (file: claude-opus-5-5,claude-opus-4-8,claude-sonnet-5-5)`' pr_review_health_report.md
  grep -qF -- '- `AI_ENGINES=gemini,claude → gemini claude (file: claude gemini copilot)`' pr_review_health_report.md
  [[ "$output" == *"::warning::engine override differs from config/ai-engines.json: AI_MODELS_CLAUDE deep="* ]]
  [[ "$output" == *"::warning::engine override differs from config/ai-engines.json: AI_ENGINES=gemini,claude"* ]]
  run grep -c 'None: every engine' pr_review_health_report.md
  [ "$output" = "0" ]
}

@test "overrides: an override equal to the file is not listed" {
  _unset_engine_overrides
  export AI_MODELS_GEMINI="deep=gemini-3.1-pro-preview,gemini-3.8-flash"
  export AI_ENGINES="claude,gemini,copilot"
  make_claude 0 "### 1. Executive Summary"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'None: every engine and model default comes from' pr_review_health_report.md
}

@test "overrides: an invalid AI_MODELS_* entry is reported as ignored" {
  _unset_engine_overrides
  export AI_MODELS_COPILOT="model=openai/gpt-5"
  make_claude 0 "### 1. Executive Summary"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'Invalid `AI_MODELS_\*` entries' pr_review_health_report.md
  grep -q "AI_MODELS_COPILOT: unknown key 'model'" pr_review_health_report.md
}

@test "overrides: an unreadable config is reported, not hidden" {
  _unset_engine_overrides
  export AI_ENGINES_CONFIG="${WORK}/nope.json"
  make_claude 0 "### 1. Executive Summary"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'Could not read `config/ai-engines.json`' pr_review_health_report.md
  [[ "$output" == *"::error::engine config"* ]]
}
