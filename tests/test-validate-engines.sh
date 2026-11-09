#!/usr/bin/env bash
# Unit tests for scripts/validate-engines.sh
#
# Tests validate_engines() by injecting mock binaries via PATH manipulation
# and controlling env vars inside subshells.
#
# Run:   bash tests/test-validate-engines.sh
# Exit:  0 if all tests pass, 1 if any fail.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

# ── Helpers ──────────────────────────────────────────────────────────────────

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" = "$actual" ]]; then
    printf 'PASS: %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    printf 'PASS: %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n  expected to contain: %s\n  actual: %s\n' "$desc" "$needle" "$haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if ! printf '%s' "$haystack" | grep -qF "$needle"; then
    printf 'PASS: %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n  expected NOT to contain: %s\n  actual: %s\n' "$desc" "$needle" "$haystack"
    FAIL=$((FAIL + 1))
  fi
}

# run_validate <mock_dir> [VAR=value ...]
# Runs validate_engines() in a clean subshell with:
#   - PATH = <mock_dir>:/usr/local/bin:/usr/bin:/bin
#     (only the provided mock_dir is used, not the global MOCK_DIR)
#   - A fixed set of env vars unset to prevent leakage from the outer env
#   - Only the env vars listed as arguments applied on top
# Prints validate_engines stdout/stderr followed by three lines:
#   CLAUDE_AVAILABLE=<value>
#   GEMINI_AVAILABLE=<value>
#   COPILOT_AVAILABLE=<value>
run_validate() {
  local mock_dir="${1:-}"; shift
  local combined_path="${mock_dir:+$mock_dir:}/usr/local/bin:/usr/bin:/bin"
  (
    # Isolate from the caller's secrets and env vars that affect engine checks
    unset GOOGLE_API_KEY CLAUDE_CODE_OAUTH_TOKEN COPILOT_GITHUB_TOKEN GH_TOKEN \
          GITHUB_STEP_SUMMARY GEMINI_CLI_TRUST_WORKSPACE 2>/dev/null || true
    export PATH="$combined_path"
    # Apply caller-supplied overrides
    for _kv in "$@"; do
      export "$_kv"
    done
    # shellcheck source=../scripts/validate-engines.sh
    source "$REPO_ROOT/scripts/validate-engines.sh"
    validate_engines 2>&1
    printf 'CLAUDE_AVAILABLE=%s\n' "$CLAUDE_AVAILABLE"
    printf 'GEMINI_AVAILABLE=%s\n' "$GEMINI_AVAILABLE"
    printf 'COPILOT_AVAILABLE=%s\n' "$COPILOT_AVAILABLE"
  )
}

# ── Mock binary setup ─────────────────────────────────────────────────────────

MOCK_DIR=$(mktemp -d)
MOCK_NO_GEMINI_DIR=$(mktemp -d)
MOCK_BILLING_DEPLETED_DIR=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR" "$MOCK_NO_GEMINI_DIR" "$MOCK_BILLING_DEPLETED_DIR"' EXIT

# gemini mock (succeeds)
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_DIR/gemini"
chmod +x "$MOCK_DIR/gemini"

# claude mock (succeeds)
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_DIR/claude"
chmod +x "$MOCK_DIR/claude"

# gh mock — handles 'gh copilot --version' and falls back to real gh for others
cat > "$MOCK_DIR/gh" << 'MOCK_GH'
#!/usr/bin/env bash
if [ "${1:-}" = "copilot" ] && [ "${2:-}" = "--version" ]; then
  echo "GitHub Copilot extension 1.0.0"
  exit 0
fi
# Fall through to real gh for non-copilot subcommands (list-prs etc. in live runs)
_real_gh="$(command -v gh 2>/dev/null || true)"
if [ -n "$_real_gh" ] && [ "$_real_gh" != "$0" ]; then
  exec "$_real_gh" "$@"
fi
exit 1
MOCK_GH
chmod +x "$MOCK_DIR/gh"

# curl mock (returns 200 OK — Gemini billing healthy)
cat > "$MOCK_DIR/curl" << 'MOCK_CURL'
#!/usr/bin/env bash
printf '{"candidates":[{"content":{"parts":[{"text":"Hi"}]}}]}\n'
printf '200\n'
exit 0
MOCK_CURL
chmod +x "$MOCK_DIR/curl"

# MOCK_NO_GEMINI_DIR: has claude, gh, and curl but NOT gemini
cp "$MOCK_DIR/claude" "$MOCK_NO_GEMINI_DIR/"
cp "$MOCK_DIR/gh"     "$MOCK_NO_GEMINI_DIR/"
cp "$MOCK_DIR/curl"   "$MOCK_NO_GEMINI_DIR/"

# MOCK_BILLING_DEPLETED_DIR: has all binaries; curl returns 429 RESOURCE_EXHAUSTED
cp "$MOCK_DIR/gemini" "$MOCK_BILLING_DEPLETED_DIR/"
cp "$MOCK_DIR/claude" "$MOCK_BILLING_DEPLETED_DIR/"
cp "$MOCK_DIR/gh"     "$MOCK_BILLING_DEPLETED_DIR/"
cat > "$MOCK_BILLING_DEPLETED_DIR/curl" << 'MOCK_CURL_DEPLETED'
#!/usr/bin/env bash
printf '{"error":{"code":429,"message":"Your prepayment credits are depleted.","status":"RESOURCE_EXHAUSTED"}}\n'
printf '429\n'
exit 0
MOCK_CURL_DEPLETED
chmod +x "$MOCK_BILLING_DEPLETED_DIR/curl"

# ── Tests ─────────────────────────────────────────────────────────────────────
echo "Running validate_engines() unit tests..."
echo ""

# 1. GEMINI_AVAILABLE=false when GOOGLE_API_KEY is unset (CLI is present)
out=$(run_validate "$MOCK_DIR" \
  "GOOGLE_API_KEY=" \
  "CLAUDE_CODE_OAUTH_TOKEN=fake-token" \
  "COPILOT_GITHUB_TOKEN=" \
  "GH_TOKEN=" \
  "GEMINI_CLI_TRUST_WORKSPACE=true")
assert_eq "GEMINI_AVAILABLE=false when GOOGLE_API_KEY unset" \
  "GEMINI_AVAILABLE=false" "$(printf '%s\n' "$out" | grep '^GEMINI_AVAILABLE=')"

# 2. GEMINI_AVAILABLE=false when gemini CLI is absent (key is set)
out=$(run_validate "$MOCK_NO_GEMINI_DIR" \
  "GOOGLE_API_KEY=fake-key" \
  "CLAUDE_CODE_OAUTH_TOKEN=fake-token" \
  "COPILOT_GITHUB_TOKEN=" \
  "GH_TOKEN=" \
  "GEMINI_CLI_TRUST_WORKSPACE=true")
assert_eq "GEMINI_AVAILABLE=false when CLI absent" \
  "GEMINI_AVAILABLE=false" "$(printf '%s\n' "$out" | grep '^GEMINI_AVAILABLE=')"

# 3. GEMINI_AVAILABLE=true when CLI is present and GOOGLE_API_KEY is set
out=$(run_validate "$MOCK_DIR" \
  "GOOGLE_API_KEY=fake-key" \
  "CLAUDE_CODE_OAUTH_TOKEN=fake-token" \
  "COPILOT_GITHUB_TOKEN=" \
  "GH_TOKEN=" \
  "GEMINI_CLI_TRUST_WORKSPACE=true")
assert_eq "GEMINI_AVAILABLE=true when CLI present and key set" \
  "GEMINI_AVAILABLE=true" "$(printf '%s\n' "$out" | grep '^GEMINI_AVAILABLE=')"

# 4. Warning includes install command when CLI is missing
out=$(run_validate "$MOCK_NO_GEMINI_DIR" \
  "GOOGLE_API_KEY=fake-key" \
  "CLAUDE_CODE_OAUTH_TOKEN=" \
  "COPILOT_GITHUB_TOKEN=" \
  "GH_TOKEN=" \
  "GEMINI_CLI_TRUST_WORKSPACE=true")
assert_contains "Warning includes install command when CLI absent" \
  "npm install -g @google/gemini-cli" "$out"

# 5. Warning emitted (::warning:: annotation) when GOOGLE_API_KEY unset
out=$(run_validate "$MOCK_DIR" \
  "GOOGLE_API_KEY=" \
  "CLAUDE_CODE_OAUTH_TOKEN=" \
  "COPILOT_GITHUB_TOKEN=" \
  "GH_TOKEN=" \
  "GEMINI_CLI_TRUST_WORKSPACE=true")
assert_contains "::warning:: annotation emitted when key absent" \
  "::warning::" "$out"

# 6. No ::warning:: annotation for Gemini when both CLI and key are present
out=$(run_validate "$MOCK_DIR" \
  "GOOGLE_API_KEY=fake-key" \
  "CLAUDE_CODE_OAUTH_TOKEN=fake-token" \
  "COPILOT_GITHUB_TOKEN=" \
  "GH_TOKEN=" \
  "GEMINI_CLI_TRUST_WORKSPACE=true")
if printf '%s\n' "$out" | grep -q '::warning::.*Gemini'; then
  printf 'FAIL: No Gemini warning when engine is healthy\n  got: %s\n' "$out"
  FAIL=$((FAIL + 1))
else
  printf 'PASS: No Gemini warning when engine is healthy\n'
  PASS=$((PASS + 1))
fi

# 7. Job summary lists "Gemini | unavailable" when key is absent
SUMMARY_FILE=$(mktemp)
run_validate "$MOCK_DIR" \
  "GOOGLE_API_KEY=" \
  "CLAUDE_CODE_OAUTH_TOKEN=" \
  "COPILOT_GITHUB_TOKEN=" \
  "GH_TOKEN=" \
  "GEMINI_CLI_TRUST_WORKSPACE=true" \
  "GITHUB_STEP_SUMMARY=$SUMMARY_FILE" > /dev/null
assert_contains "Job summary: 'Gemini | unavailable' when key absent" \
  "| Gemini  | unavailable |" "$(cat "$SUMMARY_FILE")"
rm -f "$SUMMARY_FILE"

# 8. Job summary lists "Gemini | ok" when CLI and key are present
SUMMARY_FILE=$(mktemp)
run_validate "$MOCK_DIR" \
  "GOOGLE_API_KEY=fake-key" \
  "CLAUDE_CODE_OAUTH_TOKEN=" \
  "COPILOT_GITHUB_TOKEN=" \
  "GH_TOKEN=" \
  "GEMINI_CLI_TRUST_WORKSPACE=true" \
  "GITHUB_STEP_SUMMARY=$SUMMARY_FILE" > /dev/null
assert_contains "Job summary: 'Gemini | ok' when engine available" \
  "| Gemini  | ok |" "$(cat "$SUMMARY_FILE")"
rm -f "$SUMMARY_FILE"

# ── Billing probe tests (issue #399) ──────────────────────────────────────────

# 9. GEMINI_AVAILABLE=false when billing probe detects depleted credits
out=$(run_validate "$MOCK_BILLING_DEPLETED_DIR" \
  "GOOGLE_API_KEY=fake-key" \
  "CLAUDE_CODE_OAUTH_TOKEN=fake-token" \
  "COPILOT_GITHUB_TOKEN=" \
  "GH_TOKEN=" \
  "GEMINI_CLI_TRUST_WORKSPACE=true")
assert_eq "GEMINI_AVAILABLE=false when billing probe detects RESOURCE_EXHAUSTED" \
  "GEMINI_AVAILABLE=false" "$(printf '%s\n' "$out" | grep '^GEMINI_AVAILABLE=')"

# 10. Warning includes billing guidance when probe detects depletion
assert_contains "Warning includes billing guidance when probe detects depletion" \
  "prepayment credits depleted" "$out"

# 11. GEMINI_AVAILABLE=true when probe returns 200 OK (healthy billing)
out=$(run_validate "$MOCK_DIR" \
  "GOOGLE_API_KEY=fake-key" \
  "CLAUDE_CODE_OAUTH_TOKEN=fake-token" \
  "COPILOT_GITHUB_TOKEN=" \
  "GH_TOKEN=" \
  "GEMINI_CLI_TRUST_WORKSPACE=true")
assert_eq "GEMINI_AVAILABLE=true when probe returns 200 (billing healthy)" \
  "GEMINI_AVAILABLE=true" "$(printf '%s\n' "$out" | grep '^GEMINI_AVAILABLE=')"

# 12. Job summary: 'Gemini | unavailable' when probe detects billing depletion
SUMMARY_FILE=$(mktemp)
run_validate "$MOCK_BILLING_DEPLETED_DIR" \
  "GOOGLE_API_KEY=fake-key" \
  "CLAUDE_CODE_OAUTH_TOKEN=" \
  "COPILOT_GITHUB_TOKEN=" \
  "GH_TOKEN=" \
  "GEMINI_CLI_TRUST_WORKSPACE=true" \
  "GITHUB_STEP_SUMMARY=$SUMMARY_FILE" > /dev/null
assert_contains "Job summary: 'Gemini | unavailable' when billing depleted" \
  "| Gemini  | unavailable |" "$(cat "$SUMMARY_FILE")"
rm -f "$SUMMARY_FILE"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
