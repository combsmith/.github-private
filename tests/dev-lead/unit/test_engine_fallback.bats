#!/usr/bin/env bats
# Unit tests for engine.sh — run_writer_with_fallback (Phase 6)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  : > "$GITHUB_ENV"
  : > "$GITHUB_OUTPUT"
  # Sidecars go to this test's directory, not the /tmp every session shares (#2271).
  export DEV_LEAD_SIDECAR_DIR="$BATS_TEST_TMPDIR"

  STUB_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN_DIR"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini"
  export PATH="$STUB_BIN_DIR:$PATH"
  export STUB_BIN_DIR

  # Create a test prompt file
  TEST_PROMPT="$BATS_TEST_TMPDIR/test_prompt"
  echo "test prompt content" > "$TEST_PROMPT"
  export TEST_PROMPT

  export DEV_LEAD_DRY_RUN="false"
  export GEMINI_API_KEY="dummy-test-key"

  # TOKEN_LOG_FILE enables JSON-mode capture (--output-format json) in
  # _claude_chain_invoke.  When set, the stub-claude fixture wraps its response
  # in a JSON envelope, which breaks plain-text pattern matching (e.g. rate-limit
  # detection on the raw capture).  Unsetting here reproduces the correct signal
  # path and eliminates the CI environment-variable leak without disabling any
  # real production behaviour.
  unset TOKEN_LOG_FILE ENGINE_USAGE_JSON
}

# Helper: source engine with a given engine type (suppresses info line)
_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT"
}

# Helper: create a stub that always returns a given exit code
_make_stub() {
  local name="$1" exit_code="$2"
  cat > "$STUB_BIN_DIR/$name" <<STUBEOF
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --print|--model|--permission-mode|--allowed-tools|--prompt|--approval-mode|--output-format) shift; shift ;;
    *) shift ;;
  esac
done
exit ${exit_code}
STUBEOF
  chmod +x "$STUB_BIN_DIR/$name"
}

# Helper: create a stub that records calls and returns a given exit code
_make_recording_stub() {
  local name="$1" exit_code="$2" record_file="$3"
  cat > "$STUB_BIN_DIR/$name" <<STUBEOF
#!/usr/bin/env bash
echo "\$0" >> "${record_file}"
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --print|--model|--permission-mode|--allowed-tools|--prompt|--approval-mode|--output-format) shift; shift ;;
    *) shift ;;
  esac
done
exit ${exit_code}
STUBEOF
  chmod +x "$STUB_BIN_DIR/$name"
}

# ── run_writer_with_fallback tests ────────────────────────────────────────────

@test "fallback: primary exits 0 → success" {
  _make_stub "claude" 0
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

@test "fallback: primary exits 2 → tries next engine" {
  # claude exits 2 (rate-limited), gemini exits 0. Copilot is forced to skip via a
  # classic-PAT token so gemini remains the tested fallback.
  _make_stub "claude" 2
  _make_stub "gemini" 0
  export COPILOT_GITHUB_TOKEN="ghp_stub"  # ghp_* → copilot fallback is skipped
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

@test "fallback: all rate-limited → returns 2" {
  # All engines exit 2 (rate-limited)
  _make_stub "claude" 2
  _make_stub "gemini" 2
  # copilot uses `gh copilot`; provide token + gh stub returning rate-limit text
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"copilot"*) echo "rate limit exceeded"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "fallback: non-rate-limit exit 1 → no fallback" {
  # claude exits 1 (real failure, not rate-limit)
  _make_stub "claude" 1
  # gemini should NOT be called - if it were, it would succeed (exit 0)
  _make_stub "gemini" 0
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  # Should fail with 1 immediately, not succeed via gemini
  [ "$status" -eq 1 ]
}

@test "fallback: engine not installed (exit 127) → tries next engine" {
  # Simulates gemini not installed: exit 127 should trigger fallback, not abort
  _make_stub "claude" 2
  _make_stub "gemini" 127
  # Provide token + gh stub so copilot path is deterministic (returns rate-limit)
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"copilot"*) echo "rate limit exceeded"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  # claude rate-limited (2), gemini not installed (127), copilot rate-limited (2) → all exhausted.
  # any_missing=1 (gemini returned 127) → hard failure exit 1 so infra problems surface loudly.
  [ "$status" -eq 1 ]
}

@test "fallback: engine not installed (127) → remaining engines still tried" {
  # claude rate-limited, gemini not installed, but the next engine after gemini succeeds
  # In the actual fallback order: claude → copilot → gemini. Since copilot returns 2
  # (text-only) in run_writer, we verify with a scenario where gemini is "not found"
  # and a recording stub shows that claude was tried after gemini failed.
  _make_stub "gemini" 2
  local record_file
  record_file="$(mktemp "$BATS_TEST_TMPDIR/rec.XXXXXX")"
  _make_recording_stub "claude" 127 "$record_file"
  # Provide token + gh stub so copilot path is deterministic (returns rate-limit)
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"copilot"*) echo "rate limit exceeded"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  _source_engine "gemini"

  run run_writer_with_fallback "$TEST_PROMPT"

  # gemini (primary) rate-limited, claude not installed (127 → treated as unavailable),
  # copilot rate-limited (2) → all engines exhausted.
  # any_missing=1 (claude returned 127) → hard failure exit 1 so infra problems surface loudly.
  [ "$status" -eq 1 ]
  # claude was tried (even though it exited 127, it was reached)
  [ -s "$record_file" ]
  rm -f "$record_file"
}


@test "fallback: fallback engine order is claude → gemini → copilot" {
  # Primary = gemini (exits 2), then fallback order should try claude first
  _make_stub "gemini" 2
  local record_file
  record_file="$(mktemp "$BATS_TEST_TMPDIR/rec.XXXXXX")"
  _make_recording_stub "claude" 0 "$record_file"
  _source_engine "gemini"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # claude should have been called (recorded in record_file)
  [ -s "$record_file" ]
  rm -f "$record_file"
}

@test "order: default chain tries gemini before copilot (#1777)" {
  # claude rate-limited; both gemini and copilot would succeed. The default order
  # is now claude → gemini → copilot, so gemini must be reached first and copilot
  # must never be invoked.
  _make_stub "claude" 2
  local gemini_record copilot_record
  gemini_record="$BATS_TEST_TMPDIR/gemini_record"
  copilot_record="$BATS_TEST_TMPDIR/copilot_record"
  _make_recording_stub "gemini" 0 "$gemini_record"
  export GEMINI_API_KEY="test-key"
  export COPILOT_GITHUB_TOKEN="github_pat_testdummyvalue123"
  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"copilot"*) echo "\$*" >> "$copilot_record"; echo "success output"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # gemini was reached (2nd in the chain) …
  [ -s "$gemini_record" ]
  # … and copilot (now 3rd) was never invoked because gemini already succeeded.
  [ ! -s "$copilot_record" ]
  unset GEMINI_API_KEY
}

@test "fallback: gemini skipped when no auth env vars set → falls through to copilot" {
  # claude exits 2 (rate-limited), no GEMINI_API_KEY/GOOGLE_API_KEY set.
  # gemini should be skipped entirely (not called); copilot should succeed.
  _make_stub "claude" 2
  local gemini_record
  gemini_record="$BATS_TEST_TMPDIR/gemini_record"
  _make_recording_stub "gemini" 1 "$gemini_record"
  unset GEMINI_API_KEY GOOGLE_API_KEY 2>/dev/null || true
  # Valid Copilot token so the headroom probe proceeds (an invalid/placeholder
  # token now skips copilot per #1546); curl stub reports available headroom.
  export COPILOT_GITHUB_TOKEN="github_pat_testdummyvalue123"
  cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
printf 'HTTP/2 200\r\nx-ratelimit-remaining-requests: 100\r\nx-ratelimit-limit-requests: 200\r\n\r\n'
STUB
  chmod +x "$STUB_BIN_DIR/curl"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"copilot"*) echo "success output"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # gemini must NOT have been called (file should be empty)
  [ ! -s "$gemini_record" ]
  rm -f "$gemini_record"
}

@test "fallback: gemini used normally when GEMINI_API_KEY is set" {
  # claude exits 2 (rate-limited), GEMINI_API_KEY is set → gemini should be tried and succeed.
  # Copilot is forced to skip so gemini is the one reached.
  _make_stub "claude" 2
  _make_stub "gemini" 0
  export GEMINI_API_KEY="test-api-key"
  export COPILOT_GITHUB_TOKEN="ghp_stub"  # ghp_* → copilot fallback is skipped
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  unset GEMINI_API_KEY
}

# ── failure-reason sidecar tests (#781) ───────────────────────────────────────
# run_writer_with_fallback writes a one-line cause class to
# /tmp/dev-lead-failure-reason before each terminal failure return, so callers
# can classify the failure. Because `run` executes in a subshell, the sidecar
# file (not the function's environment) is the contract we assert on.

@test "sidecar: all rate-limited → reason=rate-limited" {
  _make_stub "claude" 2
  _make_stub "gemini" 2
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"copilot"*) echo "rate limit exceeded"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 2 ]
  [ "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-failure-reason")" = "rate-limited" ]
}

@test "sidecar: missing binary (127) → reason=missing-binary" {
  # claude not installed (127); gemini skipped (no key); copilot skipped (classic PAT).
  _make_stub "claude" 127
  unset GEMINI_API_KEY GOOGLE_API_KEY 2>/dev/null || true
  export COPILOT_GITHUB_TOKEN="ghp_stub"  # ghp_* → copilot fallback is skipped
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-failure-reason")" = "missing-binary" ]
}

@test "sidecar: generic engine error (exit 1) → reason=engine-error" {
  _make_stub "claude" 1
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-failure-reason")" = "engine-error" ]
}

# ── Copilot license/policy denial (#1546) ─────────────────────────────────────
# The org's Copilot subscription ended, so `gh copilot` fails deterministically
# with "Access denied by policy settings" (exit 1). That is NOT a rate-limit
# phrase, so run_writer used to return the raw exit 1, which run_writer_with_
# fallback classified as engine-error and returned immediately — aborting before
# gemini and hard-failing the job. The denial must be treated like exit 2
# (warn + continue to the next engine).

@test "license: is_license_denied matches policy/license denial phrases" {
  _source_engine "claude"

  run is_license_denied "Error: Access denied by policy settings (Request ID: BC83:26AFAD)"
  [ "$status" -eq 0 ]
  run is_license_denied "model is not supported by Copilot"
  [ "$status" -eq 0 ]
  run is_license_denied "some perfectly normal output"
  [ "$status" -eq 1 ]
}

@test "license: copilot policy denial → continue to gemini (not engine-error)" {
  # claude rate-limited (2); copilot reached with a valid token but `gh copilot`
  # returns the policy/license denial (exit 1); gemini succeeds. The chain must
  # NOT abort at copilot — it must fall through to gemini.
  _make_stub "claude" 2
  _make_stub "gemini" 0
  export GEMINI_API_KEY="test-key"
  export COPILOT_GITHUB_TOKEN="github_pat_testdummyvalue123"
  # headroom probe: copilot has headroom (valid token → probe runs)
  cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
printf 'HTTP/2 200\r\nx-ratelimit-remaining-requests: 100\r\nx-ratelimit-limit-requests: 200\r\n\r\n'
STUB
  chmod +x "$STUB_BIN_DIR/curl"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"copilot"*) echo "Error: Access denied by policy settings (Request ID: BC83:26AFAD)"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # success clears the sidecar → the run did not hard-fail as engine-error
  [ ! -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-failure-reason" ]
}

@test "license: copilot denial with all engines exhausted → reason=rate-limited (never engine-error)" {
  # claude + gemini rate-limited (2); copilot reached but policy-denied. All
  # engines exhausted → aggregate reason is rate-limited, NOT engine-error.
  _make_stub "claude" 2
  _make_stub "gemini" 2
  export GEMINI_API_KEY="test-key"
  export COPILOT_GITHUB_TOKEN="github_pat_testdummyvalue123"
  cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
printf 'HTTP/2 200\r\nx-ratelimit-remaining-requests: 100\r\nx-ratelimit-limit-requests: 200\r\n\r\n'
STUB
  chmod +x "$STUB_BIN_DIR/curl"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"copilot"*) echo "Access denied by policy settings"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 2 ]
  [ "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-failure-reason")" = "rate-limited" ]
}

# ── DEV_LEAD_ENGINES kill-switch (#1546) ──────────────────────────────────────
# An optional comma/space-separated allow-list removes an unlicensed engine from
# the chain org-wide without a code change. A removed engine is never invoked.

@test "kill-switch: DEV_LEAD_ENGINES=claude,gemini removes copilot from the chain" {
  # claude rate-limited; copilot would succeed if invoked, but it is excluded, so
  # the chain must skip straight to gemini. Record any `gh copilot` invocation to
  # prove copilot was never called.
  _make_stub "claude" 2
  _make_stub "gemini" 0
  export GEMINI_API_KEY="test-key"
  export COPILOT_GITHUB_TOKEN="github_pat_testdummyvalue123"
  export DEV_LEAD_ENGINES="claude,gemini"
  local copilot_record="$BATS_TEST_TMPDIR/copilot_record"
  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"copilot"*) echo "\$*" >> "$copilot_record"; echo "success output"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # copilot was excluded from the chain → never invoked
  [ ! -s "$copilot_record" ]
  unset DEV_LEAD_ENGINES
}

@test "kill-switch: unrecognized token (typo) falls back to the full default chain" {
  # A partially invalid spec (e.g. a "cluade" typo) must NOT be silently accepted
  # as a claude-only subset that disables fallbacks. The whole spec is invalid →
  # the default claude,copilot,gemini chain applies, so claude's rate-limit still
  # falls through to gemini.
  _make_stub "claude" 2
  _make_stub "gemini" 0
  export GEMINI_API_KEY="test-key"
  export COPILOT_GITHUB_TOKEN="ghp_stub"   # copilot skipped → gemini is the fallback
  export DEV_LEAD_ENGINES="claude,cluade"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  # gemini reached → the spec fell back to the full chain (not claude-only)
  [ "$status" -eq 0 ]
  unset DEV_LEAD_ENGINES
}

@test "kill-switch: glob metacharacter in DEV_LEAD_ENGINES is not pathname-expanded" {
  # "*" must be treated as one unrecognized token (→ default chain), never
  # expanded against the filesystem when the spec is split.
  _make_stub "claude" 2
  _make_stub "gemini" 0
  export GEMINI_API_KEY="test-key"
  export COPILOT_GITHUB_TOKEN="ghp_stub"
  export DEV_LEAD_ENGINES="*"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  unset DEV_LEAD_ENGINES
}

# ── copilot credential config-gap → reason=unconfigured (#1591) ───────────────
# A missing/placeholder Copilot token is a deterministic AUTH/configuration gap,
# not a retryable rate limit. When copilot is the only enabled engine, the
# aggregate reason must be a DISTINCT `unconfigured` (exit 1), NOT a retryable
# rate-limit (exit 2) and NOT the generic `engine-error` (which the retry cron
# treats as retryable). Retrying cannot conjure a secret, so the classification
# must be distinguishable so the caller escalates instead of requeuing.

@test "config: copilot-only with missing token → unconfigured, not rate-limited" {
  export DEV_LEAD_ENGINES="copilot"
  unset COPILOT_GITHUB_TOKEN GEMINI_API_KEY GOOGLE_API_KEY 2>/dev/null || true
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  # Distinct config-gap classification: exit 1, reason=unconfigured — never
  # rate-limited (exit 2 would send the retry cron back at an unchangeable state).
  [ "$status" -ne 2 ]
  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-failure-reason")" = "unconfigured" ]
  unset DEV_LEAD_ENGINES
}

@test "config: copilot-only with placeholder token → unconfigured, not rate-limited" {
  # A placeholder value that is not one of the accepted token prefixes
  # (github_pat_ / ghp_ / ghs_) is treated as not-provided.
  export DEV_LEAD_ENGINES="copilot"
  export COPILOT_GITHUB_TOKEN="changeme"
  unset GEMINI_API_KEY GOOGLE_API_KEY 2>/dev/null || true
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-failure-reason")" = "unconfigured" ]
  unset DEV_LEAD_ENGINES COPILOT_GITHUB_TOKEN
}

@test "config: copilot-only with unsupported classic PAT → unconfigured, not rate-limited" {
  # A classic ghp_ PAT is unsupported for the Copilot engine — also a config gap.
  export DEV_LEAD_ENGINES="copilot"
  export COPILOT_GITHUB_TOKEN="ghp_classicpatstub"
  unset GEMINI_API_KEY GOOGLE_API_KEY 2>/dev/null || true
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-failure-reason")" = "unconfigured" ]
  unset DEV_LEAD_ENGINES COPILOT_GITHUB_TOKEN
}

@test "config: gemini-only with missing API key → unconfigured, not engine-error" {
  # Gemini is the sole enabled engine and neither GEMINI_API_KEY nor
  # GOOGLE_API_KEY is set. Like a missing Copilot token, this is a deterministic
  # config gap — the aggregate reason must be the DISTINCT `unconfigured` (exit
  # 1), never the retryable `engine-error`, so the caller escalates to a human
  # instead of requeuing a run that cannot succeed without a key.
  export DEV_LEAD_ENGINES="gemini"
  unset GEMINI_API_KEY GOOGLE_API_KEY COPILOT_GITHUB_TOKEN 2>/dev/null || true
  _source_engine "gemini"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-failure-reason")" = "unconfigured" ]
  unset DEV_LEAD_ENGINES
}

@test "config: genuine rate-limit still wins over a copilot config-gap" {
  # claude rate-limited (2), gemini rate-limited (2), copilot token missing.
  # A genuine quota exhaustion elsewhere in the chain means a later retry could
  # succeed, so the aggregate must remain rate-limited (exit 2) — the config-gap
  # classification only takes over when it is the SOLE cause.
  _make_stub "claude" 2
  _make_stub "gemini" 2
  export GEMINI_API_KEY="test-key"
  unset COPILOT_GITHUB_TOKEN 2>/dev/null || true
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 2 ]
  [ "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-failure-reason")" = "rate-limited" ]
  unset GEMINI_API_KEY
}

# ── timeout classification (#1018) ───────────────────────────────────────────
# A per-tier stage timeout (exit 124 from GNU `timeout`) must be classified as a
# distinct, NON-retryable reason=timeout — not engine-error — and must NOT drive
# a same-budget retry on another engine. The tier/budget/elapsed sidecars carry
# the context the needs-human escalation comment surfaces.

@test "sidecar: stage timeout (exit 124) → reason=timeout + tier/budget/elapsed sidecars" {
  _make_stub "claude" 124
  export ACTION_TIMEOUT_SEC=2100
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  # 124 propagates immediately (distinct from engine-error)
  [ "$status" -eq 124 ]
  [ "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-failure-reason")" = "timeout" ]
  [ "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-timeout-tier")" = "action" ]
  [ "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-timeout-budget")" = "2100" ]
  [ -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-timeout-elapsed" ]
}

@test "sidecar: timeout (124) does NOT fall through to another engine (no same-budget retry)" {
  # claude times out (124); NEITHER copilot nor gemini (the remaining engines in
  # the claude→copilot→gemini order) may be tried — each would succeed here if
  # wrongly invoked, so record both and assert neither ran.
  _make_stub "claude" 124
  local gemini_record copilot_record
  gemini_record="$BATS_TEST_TMPDIR/gemini_record"; copilot_record="$BATS_TEST_TMPDIR/copilot_record"
  _make_recording_stub "gemini" 0 "$gemini_record"
  # Enable copilot (non-ghp token) and record any `gh copilot` invocation.
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"copilot"*) echo "\$*" >> "$copilot_record"; echo "success output"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 124 ]
  [ "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-failure-reason")" = "timeout" ]
  # Same-budget retry on ANY fallback engine must NOT happen.
  [ ! -s "$copilot_record" ]
  [ ! -s "$gemini_record" ]
  rm -f "$gemini_record" "$copilot_record"
}

# ── engine-level retry classification (#1028) ─────────────────────────────────
# A per-tier stage timeout (exit 124 from GNU `timeout`) is deterministic — the
# model used its whole budget, so re-running at the SAME budget just times out
# again. is_transient_failure() must therefore NOT classify 124 as retryable,
# while signal kills (137/143) keep their retry behavior. run_triage is the
# in-run retry loop that consumes this classifier; run_writer/run_agentic do not
# retry at all, so dropping 124 from the shared classifier makes every caller
# consistent (no engine-level same-budget retry on a timeout anywhere).

@test "retry: is_transient_failure does NOT classify 124 (timeout) as retryable" {
  _source_engine "claude"

  run is_transient_failure 124
  [ "$status" -ne 0 ]
}

@test "retry: is_transient_failure still classifies 137/143 (signal kills) as retryable" {
  _source_engine "claude"

  run is_transient_failure 137
  [ "$status" -eq 0 ]
  run is_transient_failure 143
  [ "$status" -eq 0 ]
}

@test "retry: stubbed 124 in the retry loop → engine invoked exactly once (no in-run retry)" {
  local record_file
  record_file="$(mktemp "$BATS_TEST_TMPDIR/rec.XXXXXX")"
  _make_recording_stub "claude" 124 "$record_file"
  export RETRY_BASE_DELAY_SEC=0   # no backoff sleep in tests
  _source_engine "claude"

  run run_triage "$TEST_PROMPT"

  [ "$status" -eq 124 ]
  # A deterministic per-tier timeout must not be re-run at the same budget.
  [ "$(wc -l < "$record_file")" -eq 1 ]
  rm -f "$record_file"
}

@test "retry: EARLY 137 (signal kill well under budget) in the retry loop → still retries (invoked twice), regression guard" {
  # An instant 137 ran for ~0ms, far below TRIAGE_TIMEOUT_SEC, so it is a genuine
  # transient signal kill (e.g. OOM), NOT a `timeout --kill-after` budget
  # exhaustion — it stays retryable (contrast the at-budget case below, #1952).
  local record_file
  record_file="$(mktemp "$BATS_TEST_TMPDIR/rec.XXXXXX")"
  _make_recording_stub "claude" 137 "$record_file"
  export RETRY_BASE_DELAY_SEC=0   # no backoff sleep in tests
  _source_engine "claude"

  run run_triage "$TEST_PROMPT"

  [ "$status" -eq 137 ]
  # Signal kills stay transient: RETRY_MAX_ATTEMPTS=2 → one retry → two invocations.
  [ "$(wc -l < "$record_file")" -eq 2 ]
  rm -f "$record_file"
}

@test "retry: 137 AFTER consuming the full budget (kill-after SIGKILL) → treated as timeout (124), invoked once" {
  # A triage call wrapped by `timeout --kill-after` that ignores SIGTERM is
  # SIGKILLed at budget+grace and exits 137 — but it already spent its whole
  # budget, so re-running at the same budget would only repeat it (#1028). This is
  # the kill-after escalation cubic flagged: run_triage distinguishes it from the
  # early signal kill above by the latency it measured and does NOT retry it
  # (#1952 cubic P1). Simulate with a stub that traps SIGTERM and outlives a 1s
  # budget + 1s grace, forcing `timeout` to force-kill it.
  local record_file
  record_file="$(mktemp "$BATS_TEST_TMPDIR/rec.XXXXXX")"
  cat > "$STUB_BIN_DIR/claude" <<STUBEOF
#!/usr/bin/env bash
echo "\$0" >> "${record_file}"
trap '' TERM
sleep 10
STUBEOF
  chmod +x "$STUB_BIN_DIR/claude"
  export RETRY_BASE_DELAY_SEC=0   # no backoff sleep in tests
  export TRIAGE_TIMEOUT_SEC=1 ENGINE_KILL_AFTER=1s
  _source_engine "claude"

  run run_triage "$TEST_PROMPT"

  # kill-after SIGKILL → 137 reclassified to the non-retryable 124 timeout path.
  [ "$status" -eq 124 ]
  # Must be invoked exactly once — no same-budget retry of an exhausted call.
  [ "$(wc -l < "$record_file")" -eq 1 ]
  rm -f "$record_file"
}

@test "sidecar: stale reason cleared on success" {
  printf 'engine-error\n' > "$DEV_LEAD_SIDECAR_DIR/dev-lead-failure-reason"
  _make_stub "claude" 0
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # The sidecar is removed at the start of every call → no stale reason survives.
  [ ! -f "$DEV_LEAD_SIDECAR_DIR/dev-lead-failure-reason" ]
}

# ── session-output persistence on the rate-limit path (#781, Phase 1A.2) ──────
# Previously run_writer's rate-limit early-return happened BEFORE the
# redact/persist/STEP_SUMMARY block, so a rate-limited run left no session
# output on the run page. The block now runs first, covering all exit paths.

@test "rate-limit path: session output is persisted + written to step summary" {
  # claude detected as rate-limited by CONTENT (exit 1 + rate-limit phrase),
  # which forces run_writer's is_rate_limited early-return path. gemini/copilot
  # are skipped so claude is the only engine and its output is the persisted one.
  cat > "$STUB_BIN_DIR/claude" <<'STUB'
#!/usr/bin/env bash
echo "RLPROBE: You've hit your limit · resets 11:20pm (UTC)"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/claude"
  unset GEMINI_API_KEY GOOGLE_API_KEY 2>/dev/null || true
  export COPILOT_GITHUB_TOKEN="ghp_stub"  # ghp_* → copilot fallback is skipped
  export GITHUB_STEP_SUMMARY="$(mktemp)"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 2 ]
  # Persisted session output exists and contains the engine output
  [ -s "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt" ]
  grep -q "RLPROBE" "$DEV_LEAD_SIDECAR_DIR/dev-lead-session-output.txt"
  # Step summary received the session-output block even on the rate-limit path
  grep -q "Dev-Lead session output" "$GITHUB_STEP_SUMMARY"

  rm -f "$GITHUB_STEP_SUMMARY"
}

# ── run-scoped engine exhaustion (#947) ───────────────────────────────────────
# Once an engine is found rate-limited/unavailable during a run, it must NOT be
# re-invoked on later run_writer_with_fallback calls in the same run (the #860
# fix-ci-cycle re-burn), and it must emit AT MOST ONE exhaustion notice per
# engine per run. These tests call the function twice+ in the SAME shell (no
# bats `run`, which forks a subshell) so the process-scoped registry persists.

@test "exhaustion: rate-limited engine is not re-invoked on a later call in the same run" {
  local claude_record gemini_record
  claude_record="$BATS_TEST_TMPDIR/claude_record"
  gemini_record="$BATS_TEST_TMPDIR/gemini_record"
  _make_recording_stub "claude" 2 "$claude_record"   # rate-limited (exit 2)
  _make_recording_stub "gemini" 0 "$gemini_record"   # succeeds
  export GEMINI_API_KEY="test-key"
  export COPILOT_GITHUB_TOKEN="ghp_stub"              # ghp_* → copilot skipped
  _source_engine "claude"

  local rc1=0 rc2=0
  run_writer_with_fallback "$TEST_PROMPT" || rc1=$?
  run_writer_with_fallback "$TEST_PROMPT" || rc2=$?

  [ "$rc1" -eq 0 ]
  [ "$rc2" -eq 0 ]
  # claude invoked once (call 1), then skipped as exhausted on call 2
  [ "$(wc -l < "$claude_record")" -eq 1 ]
  # gemini served both calls
  [ "$(wc -l < "$gemini_record")" -eq 2 ]
}

@test "exhaustion: at most one exhaustion notice per engine across calls in a run" {
  _make_stub "claude" 2
  _make_stub "gemini" 0
  export GEMINI_API_KEY="test-key"
  export COPILOT_GITHUB_TOKEN="ghp_stub"
  _source_engine "claude"

  local errlog
  errlog="$BATS_TEST_TMPDIR/errlog"
  run_writer_with_fallback "$TEST_PROMPT" 2>>"$errlog" || true
  run_writer_with_fallback "$TEST_PROMPT" 2>>"$errlog" || true
  run_writer_with_fallback "$TEST_PROMPT" 2>>"$errlog" || true

  # Exactly one "marked exhausted" notice for claude across all three calls.
  local n
  n=$(grep -c 'claude marked exhausted' "$errlog" || true)
  [ "$n" -eq 1 ]
}

@test "exhaustion: all-engines-exhausted second call still returns 2 (rate-limited)" {
  _make_stub "claude" 2
  _make_stub "gemini" 2
  export GEMINI_API_KEY="test-key"
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"copilot"*) echo "rate limit exceeded"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  _source_engine "claude"

  local rc1=0 rc2=0
  run_writer_with_fallback "$TEST_PROMPT" || rc1=$?
  run_writer_with_fallback "$TEST_PROMPT" || rc2=$?

  [ "$rc1" -eq 2 ]
  [ "$rc2" -eq 2 ]
  [ "$(cat "$DEV_LEAD_SIDECAR_DIR/dev-lead-failure-reason")" = "rate-limited" ]
}

@test "exhaustion: reset_engine_exhaustion clears the registry" {
  local claude_record
  claude_record="$(mktemp "$STUB_BIN_DIR/claude_record.XXXXXX")"
  _make_recording_stub "claude" 2 "$claude_record"
  _make_stub "gemini" 0
  export GEMINI_API_KEY="test-key"
  export COPILOT_GITHUB_TOKEN="ghp_stub"
  _source_engine "claude"

  run_writer_with_fallback "$TEST_PROMPT" || true    # claude recorded (1), exhausted
  reset_engine_exhaustion
  run_writer_with_fallback "$TEST_PROMPT" || true    # claude re-invoked after reset

  [ "$(wc -l < "$claude_record")" -eq 2 ]
}

@test "exhaustion: headroom-threshold breach exhausts engine permanently" {
  _make_stub "gemini" 0
  export GEMINI_API_KEY="test-key"
  export COPILOT_GITHUB_TOKEN="ghp_stub"
  _source_engine "claude"
  # Override headroom check: claude is always at/above threshold; others have headroom
  check_provider_headroom() { [ "$1" = "claude" ] && return 1; return 0; }

  local errlog
  errlog="$(mktemp "$STUB_BIN_DIR/errlog.XXXXXX")"
  local rc1=0 rc2=0
  run_writer_with_fallback "$TEST_PROMPT" 2>>"$errlog" || rc1=$?
  run_writer_with_fallback "$TEST_PROMPT" 2>>"$errlog" || rc2=$?

  # gemini serves both calls despite claude's headroom failure
  [ "$rc1" -eq 0 ]
  [ "$rc2" -eq 0 ]
  # Exactly one exhaustion notice for claude across both calls
  local n
  n=$(grep -c 'claude marked exhausted' "$errlog" || true)
  [ "$n" -eq 1 ]
}
