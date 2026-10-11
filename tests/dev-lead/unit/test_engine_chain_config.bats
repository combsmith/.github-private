#!/usr/bin/env bats
# AI_ENGINES / AI_DUCK_ENGINE: engine enablement, fallback order and duck
# selection as configuration (scripts/lib/engine-chain.sh), plus the pre-flight
# probe fixes they rely on (every Gemini key probed; Copilot unavailable on a
# classic PAT) and review-batch.sh walking the configured chain.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/engine-chain.sh"

setup() {
  unset AI_ENGINES DEV_LEAD_ENGINES AI_DUCK_ENGINE AI_DUCK_MODEL
  unset CLAUDE_AVAILABLE GEMINI_AVAILABLE COPILOT_AVAILABLE REVIEW_ENGINE
  # shellcheck source=../../../scripts/lib/engine-chain.sh
  source "$LIB"
}

# ── Parsing ───────────────────────────────────────────────────────────────────

@test "chain: unset → default claude gemini copilot" {
  [ "$(ai_engine_chain)" = "claude gemini copilot" ]
  [ -z "$(ai_engine_chain_problem)" ]
}

@test "chain: order and membership come from AI_ENGINES (comma, spaces, case)" {
  export AI_ENGINES=" Gemini , claude "
  [ "$(ai_engine_chain)" = "gemini claude" ]
  ai_engine_enabled gemini
  ai_engine_enabled claude
  ! ai_engine_enabled copilot
}

@test "chain: duplicates collapse to the first occurrence" {
  export AI_ENGINES="claude,gemini,claude"
  [ "$(ai_engine_chain)" = "claude gemini" ]
}

@test "chain: an unknown engine invalidates the whole value → default chain + problem" {
  export AI_ENGINES="claude,cluade"
  [ "$(ai_engine_chain)" = "claude gemini copilot" ]
  [[ "$(ai_engine_chain_problem)" == *"unknown engine"* ]]
}

@test "chain: a glob metacharacter is not pathname-expanded" {
  export AI_ENGINES="*"
  [ "$(ai_engine_chain)" = "claude gemini copilot" ]
  [[ "$(ai_engine_chain_problem)" == *"unknown engine"* ]]
}

@test "chain: legacy DEV_LEAD_ENGINES applies only when AI_ENGINES is unset" {
  export DEV_LEAD_ENGINES="claude,gemini"
  [ "$(ai_engine_chain)" = "claude gemini" ]
  export AI_ENGINES="gemini"
  [ "$(ai_engine_chain)" = "gemini" ]
}

# ── Primary and availability ──────────────────────────────────────────────────

@test "primary: first engine in AI_ENGINES when no override" {
  export AI_ENGINES="gemini,claude"
  [ "$(ai_engine_primary "")" = "gemini" ]
}

@test "primary: an enabled override wins; a disabled one is ignored" {
  export AI_ENGINES="claude,gemini"
  [ "$(ai_engine_primary gemini)" = "gemini" ]
  [ "$(ai_engine_primary copilot)" = "claude" ]
}

@test "available: needs enabled AND not flagged false (unset flag counts as available)" {
  export AI_ENGINES="claude,gemini"
  ai_engine_available claude
  export GEMINI_AVAILABLE=false
  ! ai_engine_available gemini || false
  export COPILOT_AVAILABLE=true
  ! ai_engine_available copilot
}

@test "next_available: walks forward only, skipping unavailable engines" {
  export AI_ENGINES="claude,gemini,copilot"
  export GEMINI_AVAILABLE=false
  [ "$(ai_engine_next_available claude)" = "copilot" ]
  [ -z "$(ai_engine_next_available copilot)" ]
}

@test "engine.sh: REVIEW_ENGINE defaults to the first engine in AI_ENGINES" {
  run bash -c "export AI_ENGINES=gemini,claude; unset REVIEW_ENGINE; source '$SCRIPT_DIR/scripts/engine.sh'; echo \"primary=\$REVIEW_ENGINE\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"primary=gemini"* ]]
}

@test "engine.sh: a REVIEW_ENGINE that AI_ENGINES disables is replaced, with a warning" {
  run bash -c "export AI_ENGINES=claude,gemini REVIEW_ENGINE=copilot; source '$SCRIPT_DIR/scripts/engine.sh'; echo \"primary=\$REVIEW_ENGINE\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"primary=claude"* ]]
  [[ "$output" == *"REVIEW_ENGINE=copilot is not enabled in AI_ENGINES"* ]]
}

# ── Rubber-duck selection ─────────────────────────────────────────────────────

# Invoke select_duck_engine in an isolated bash subprocess and return the result.
_duck() {
  bash -c "source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1; select_duck_engine" 2>/dev/null
}

@test "duck: default cross-engine duck (copilot) when it is available" {
  export REVIEW_ENGINE=claude
  run _duck
  [ "$output" = "copilot o4-mini" ]
}

@test "duck: Copilot unavailable → next other engine in AI_ENGINES (gemini)" {
  export REVIEW_ENGINE=claude COPILOT_AVAILABLE=false GEMINI_AVAILABLE=true
  run _duck
  [ "$output" = "gemini gemini-3.8-flash" ]
}

@test "duck: Copilot left out of AI_ENGINES → gemini" {
  export REVIEW_ENGINE=claude AI_ENGINES="claude,gemini"
  run _duck
  [ "$output" = "gemini gemini-3.8-flash" ]
}

@test "duck: no other usable engine → none" {
  export REVIEW_ENGINE=claude AI_ENGINES="claude"
  run _duck
  [ "$output" = "none" ]
}

@test "duck: AI_DUCK_ENGINE=none turns the duck off" {
  export REVIEW_ENGINE=claude AI_DUCK_ENGINE=none
  run _duck
  [ "$output" = "none" ]
}

@test "duck: AI_DUCK_ENGINE + AI_DUCK_MODEL pick the duck explicitly" {
  export REVIEW_ENGINE=claude AI_DUCK_ENGINE=claude AI_DUCK_MODEL=claude-sonnet-5
  run _duck
  [ "$output" = "claude claude-sonnet-5" ]
}

@test "duck: AI_DUCK_MODEL does not follow the duck onto another engine" {
  export REVIEW_ENGINE=claude AI_DUCK_ENGINE=gemini AI_DUCK_MODEL=gemini-custom
  export GEMINI_AVAILABLE=false
  run _duck
  [ "$output" = "copilot o4-mini" ]
}

# List all duck engine candidates in evaluation order via duck_engine_candidates.
_candidates() {
  bash -c "source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1; duck_engine_candidates"
}

@test "duck: AI_DUCK_ENGINE is an ordered list — its engines first, then the automatic ones" {
  export REVIEW_ENGINE=claude AI_DUCK_ENGINE="Gemini, claude"
  run _candidates
  [ "${lines[0]}" = "gemini gemini-3.8-flash" ]
  [ "${lines[1]}" = "claude claude-sonnet-5-5" ]
  [ "${lines[2]}" = "copilot o4-mini" ]
  [ "${#lines[@]}" -eq 3 ]
  run _duck
  [ "$output" = "gemini gemini-3.8-flash" ]
}

@test "duck: 'none' ends the AI_DUCK_ENGINE list (no automatic engines after it)" {
  export REVIEW_ENGINE=claude AI_DUCK_ENGINE="gemini,none"
  run _candidates
  [ "$output" = "gemini gemini-3.8-flash" ]
}

@test "duck: an unknown or unavailable AI_DUCK_ENGINE entry is skipped with a warning" {
  export REVIEW_ENGINE=claude AI_DUCK_ENGINE="typo,gemini,claude" GEMINI_AVAILABLE=false
  run bash -c "source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1; duck_engine_candidates 2>&1"
  [[ "$output" == *"'typo' is not a known engine"* ]]
  [[ "$output" == *"lists gemini, which is disabled or unavailable"* ]]
  [[ "$output" == *"claude claude-sonnet-5-5"* ]]
  [[ "$output" != *"gemini gemini"* ]]
}

@test "duck: AI_DUCK_MODEL applies to the first AI_DUCK_ENGINE entry only" {
  export REVIEW_ENGINE=claude AI_DUCK_ENGINE="claude,gemini" AI_DUCK_MODEL=claude-sonnet-5
  run _candidates
  [ "${lines[0]}" = "claude claude-sonnet-5" ]
  [ "${lines[1]}" = "gemini gemini-3.8-flash" ]
}

# _duck_chain <candidates> — run_duck_chain with run_duck stubbed. A gemini duck
# is throttled (exit 2, no verdict), or fails (exit 1) with MOCK_DUCK_gemini=fail;
# a claude duck drops GOOGLE_API_KEY (as the real one does) and writes a verdict,
# or fails with MOCK_DUCK_claude=fail; copilot times out. $DC/calls records each
# engine tried and the Gemini key it could see.
_duck_chain() {
  bash -c "source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1
    run_duck() {
      echo \"\$DUCK_ENGINE keys=[\${GOOGLE_API_KEY:-}]\" >> '$DC/calls'
      case \"\$DUCK_ENGINE\" in
        gemini)
          if [ \"\${MOCK_DUCK_gemini:-}\" = fail ]; then echo 'some error' >&2; return 1; fi
          echo 'quota exceeded 429' >&2; return 2 ;;
        claude)
          unset GOOGLE_API_KEY
          [ \"\${MOCK_DUCK_claude:-}\" = fail ] && return 1
          echo '{\"decision\":\"approve\",\"risk\":\"LOW\"}' > \"\$OUTPUT_FILE\" ;;
        copilot)
          if [ \"\${MOCK_DUCK_copilot:-}\" = nodecision ]; then echo '{\"error\":\"bad response\"}' > \"\$OUTPUT_FILE\"; return 0; fi
          return 124 ;;
      esac
    }
    export OUTPUT_FILE='$DC/duck.json'
    rc=0; run_duck_chain /dev/null \"\$1\" || rc=\$?
    echo \"rc=\$rc\"" _ "$1" 2>&1
}

@test "duck chain: a throttled first engine falls back to the next, which writes the verdict" {
  DC="$(mktemp -d)"
  export GOOGLE_API_KEY=k1
  run _duck_chain $'gemini gemini-3.8-flash\nclaude claude-sonnet-4-6'
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"[duck] gemini (gemini-3.8-flash) throttled (exit 2) and wrote no verdict"* ]]
  [[ "$output" == *"[duck] trying claude (claude-sonnet-4-6), duck engine 2 of 2"* ]]
  [ "$(cat "$DC/duck.json.engine")" = "claude claude-sonnet-4-6" ]
  jq -e '.decision == "approve"' "$DC/duck.json"
  rm -rf "$DC"
}

@test "duck chain: each attempt gets its own credentials (a Claude duck's key scrub does not leak)" {
  DC="$(mktemp -d)"
  export GOOGLE_API_KEY=k1 MOCK_DUCK_claude=fail MOCK_DUCK_gemini=fail
  run _duck_chain $'claude claude-sonnet-4-6\ngemini gemini-3.8-flash'
  [ "$(cat "$DC/calls")" = $'claude keys=[k1]\ngemini keys=[k1]' ]
  [[ "$output" == *"[duck] gemini (gemini-3.8-flash) wrote no verdict (exit 1)"* ]]
  [[ "$output" == *"rc=1"* ]]
  rm -rf "$DC"
}

@test "duck chain: valid JSON without a decision is not a verdict — the next engine runs" {
  DC="$(mktemp -d)"
  export MOCK_DUCK_copilot=nodecision
  run _duck_chain $'copilot o4-mini\nclaude claude-sonnet-4-6'
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"[duck] copilot (o4-mini) wrote no verdict (exit 0)"* ]]
  [ "$(cat "$DC/duck.json.engine")" = "claude claude-sonnet-4-6" ]
  rm -rf "$DC"
}

@test "duck_verdict_valid: needs an approve/escalate decision" {
  f="$(mktemp)"
  run bash -c "source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1
    for j in '{\"decision\":\"approve\"}' '{\"decision\":\"ESCALATE\",\"risk\":\"HIGH\"}' '{}' '{\"error\":\"x\"}' '{\"decision\":null}' '{\"decision\":\"maybe\"}' 'not json'; do
      printf '%s' \"\$j\" > '$f'; if duck_verdict_valid '$f'; then echo ok; else echo no; fi
    done
    : > '$f'; duck_verdict_valid '$f' && echo ok || echo no"
  rm -f "$f"
  [ "$(echo $output)" = "ok ok no no no no no no" ]
}

@test "duck chain: a timeout stops the chain (no second timeout added to the review)" {
  DC="$(mktemp -d)"
  run _duck_chain $'copilot o4-mini\nclaude claude-sonnet-4-6'
  [[ "$output" == *"rc=124"* ]]
  [[ "$output" == *"copilot (o4-mini) timed out"* ]]
  [ "$(cat "$DC/calls")" = "copilot keys=[]" ]
  [ ! -e "$DC/duck.json.engine" ]
  rm -rf "$DC"
}

@test "duck chain: no fallback starts once the duck's time budget is spent" {
  DC="$(mktemp -d)"
  export DUCK_TIMEOUT_SEC=0
  run _duck_chain $'gemini gemini-3.8-flash\nclaude claude-sonnet-4-6'
  [[ "$output" == *"not trying claude (claude-sonnet-4-6): the duck's 0s budget is spent"* ]]
  [ "$(cat "$DC/calls")" = "gemini keys=[]" ]
  [[ "$output" == *"rc=2"* ]]
  rm -rf "$DC"
}

@test "duck chain: no engine writes a verdict → non-zero exit and one notice naming them" {
  DC="$(mktemp -d)"
  run _duck_chain $'gemini gemini-3.8-flash'
  [[ "$output" == *"rc=2"* ]]
  [[ "$output" == *"no duck engine produced a verdict (tried: gemini)"* ]]
  [ ! -e "$DC/duck.json" ]
  run _duck_chain ""
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" != *"tried:"* ]]
  rm -rf "$DC"
}

@test "review-one-pr.sh runs the duck through run_duck_chain with every candidate" {
  grep -q 'DUCK_CANDIDATES="$(duck_engine_candidates)"' "$SCRIPT_DIR/scripts/review-one-pr.sh"
  grep -q 'run_duck_chain prompts/rubber-duck.md "$DUCK_CANDIDATES"' "$SCRIPT_DIR/scripts/review-one-pr.sh"
  grep -q 'read -r DUCK_ENGINE DUCK_MODEL < "${DUCK_OUTPUT}.engine"' "$SCRIPT_DIR/scripts/review-one-pr.sh"
}

# ── A skipped duck is visible in the review body (#1960) ─────────────────────

# _verdict <file> — a cascade-action verdict with the usual body layout.
_verdict() {
  jq -n --arg body $'<!-- pr-review-agent v1 sha=abc123 decision=approved risk=LOW -->\n\n## Automated review — APPROVED ✓\n\n### Summary\nLooks fine.\n\n### Findings\n- **INFO**: none\n\n---\n_Reviewed by the PR-review cascade._' \
    '{decision: "approve", risk: "LOW", body: $body}' > "$1"
}

@test "duck skip note: a duck skipped for an unavailable engine adds one line to the review body" {
  f="$(mktemp)"; _verdict "$f"
  run bash -c "source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1
    duck_skip_note '$f' 'no enabled, available engine for it (Gemini unavailable per the pre-flight probe)'"
  [ "$status" -eq 0 ]
  body="$(jq -r '.body' "$f")"
  [ "$(grep -c 'Second opinion skipped' <<< "$body")" -eq 1 ]
  [[ "$body" == *"Second opinion skipped"*"Gemini unavailable per the pre-flight probe"* ]]
  # The marker stays on the first line and the note sits before the findings.
  [[ "$(head -n 1 <<< "$body")" == "<!-- pr-review-agent v1 sha=abc123 "* ]]
  [ "$(grep -n 'Second opinion skipped' <<< "$body" | cut -d: -f1)" -lt "$(grep -n '^### Findings' <<< "$body" | cut -d: -f1)" ]
  [ "$(jq -r '.decision' "$f")" = "approve" ]
  rm -f "$f"
}

@test "duck skip note: a duck that ran (no skip reason) leaves the review body unchanged" {
  f="$(mktemp)"; _verdict "$f"
  before="$(cat "$f")"
  run bash -c "source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1; duck_skip_note '$f' ''"
  [ "$status" -eq 0 ]
  [ "$(cat "$f")" = "$before" ]
  rm -f "$f"
}

@test "duck skip note: a body without a Findings heading gets the line appended" {
  f="$(mktemp)"
  jq -n '{decision: "escalate", body: "<!-- pr-review-agent v1 sha=abc -->\nbody"}' > "$f"
  run bash -c "source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1; duck_skip_note '$f' 'reason x'"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.body' "$f")" == $'<!-- pr-review-agent v1 sha=abc -->\nbody\n\n'*"Second opinion skipped"*"reason x"* ]]
  rm -f "$f"
}

@test "duck chain: no verdict from any engine records why, for the review body" {
  DC="$(mktemp -d)"
  run _duck_chain $'gemini gemini-3.8-flash'
  [[ "$(cat "$DC/duck.json.skip")" == "no duck engine produced a verdict (tried: gemini)" ]]
  run _duck_chain $'copilot o4-mini'
  [[ "$(cat "$DC/duck.json.skip")" == *"copilot (o4-mini) timed out"* ]]
  rm -rf "$DC"
}

@test "duck chain: a duck that ran leaves no skip reason" {
  DC="$(mktemp -d)"
  echo stale > "$DC/duck.json.skip"
  run _duck_chain $'gemini gemini-3.8-flash\nclaude claude-sonnet-4-6'
  [[ "$output" == *"rc=0"* ]]
  [ ! -e "$DC/duck.json.skip" ]
  rm -rf "$DC"
}

@test "review-one-pr.sh puts the duck skip note on both posted verdicts (tier 2 and audit)" {
  s="$SCRIPT_DIR/scripts/review-one-pr.sh"
  [ "$(grep -c 'duck_skip_note "$VERDICT_JSON" "$DUCK_SKIP_REASON"' "$s")" -eq 2 ]
  grep -q 'DUCK_SKIP_REASON="no enabled, available engine for it' "$s"
  grep -q '"${DUCK_OUTPUT}.skip"' "$s"
}

# ── validate-engines.sh probes ────────────────────────────────────────────────

# Create a mock bin directory (in VBIN) with claude, gemini, gh, curl CLIs for testing validate_engines probes.
_setup_validate_bin() {
  VBIN="$(mktemp -d)"
  printf '#!/bin/bash\nexit 0\n' > "$VBIN/claude"
  printf '#!/bin/bash\nexit 0\n' > "$VBIN/gemini"
  printf '#!/bin/bash\necho "gh copilot"\n' > "$VBIN/gh"
  # curl mock: depleted when the key is listed in MOCK_DEPLETED_KEYS.
  cat > "$VBIN/curl" <<'EOF'
#!/bin/bash
key=""
for a in "$@"; do case "$a" in X-Goog-Api-Key:*) key="${a#X-Goog-Api-Key: }" ;; esac; done
case " ${MOCK_DEPLETED_KEYS:-} " in
  *" $key "*) printf '{"error":{"code":429,"message":"Your prepayment credits are depleted."}}\n429\n' ;;
  *) printf '{"candidates":[]}\n200\n' ;;
esac
EOF
  chmod +x "$VBIN"/*
}

# Run validate_engines with the mock bin and print the availability flags.
_validate() {
  bash -c "export PATH='$VBIN':\$PATH GEMINI_CLI_TRUST_WORKSPACE=true CLAUDE_CODE_OAUTH_TOKEN=x; unset GITHUB_STEP_SUMMARY; source '$SCRIPT_DIR/scripts/validate-engines.sh'; validate_engines; echo \"C=\$CLAUDE_AVAILABLE G=\$GEMINI_AVAILABLE P=\$COPILOT_AVAILABLE\""
}

@test "validate: Gemini stays available when only key 1 is depleted (keys 2/3 have credits)" {
  _setup_validate_bin
  export GOOGLE_API_KEY=k1 GOOGLE_API_KEY_2=k2 GOOGLE_API_KEY_3=k3 MOCK_DEPLETED_KEYS="k1"
  run _validate
  [[ "$output" == *"G=true"* ]]
  [[ "$output" == *"depleted prepayment credits: GOOGLE_API_KEY"* ]]
  [[ "$output" != *"k1"* ]]
  rm -rf "$VBIN"
}

@test "validate: Gemini unavailable only when every key is depleted" {
  _setup_validate_bin
  export GOOGLE_API_KEY=k1 GOOGLE_API_KEY_2=k2 GOOGLE_API_KEY_3=k3 MOCK_DEPLETED_KEYS="k1 k2 k3"
  run _validate
  [[ "$output" == *"G=false"* ]]
  [[ "$output" == *"every configured key"* ]]
  rm -rf "$VBIN"
}

@test "validate: Copilot unavailable on a classic PAT (ghp_)" {
  _setup_validate_bin
  local tok="ghp_""abc"
  export COPILOT_GITHUB_TOKEN="$tok" GOOGLE_API_KEY=k1
  run _validate
  [[ "$output" == *"P=false"* ]]
  [[ "$output" == *"classic PAT"* ]]
  rm -rf "$VBIN"
}

@test "validate: Copilot available on a fine-grained PAT" {
  _setup_validate_bin
  local tok="github_pat_""abc"
  export COPILOT_GITHUB_TOKEN="$tok" GOOGLE_API_KEY=k1
  run _validate
  [[ "$output" == *"P=true"* ]]
  rm -rf "$VBIN"
}

@test "validate: engines left out of AI_ENGINES are reported disabled and not probed" {
  _setup_validate_bin
  export AI_ENGINES="claude" GOOGLE_API_KEY=k1 MOCK_DEPLETED_KEYS="k1"
  run _validate
  [[ "$output" == *"G=false P=false"* ]]
  [[ "$output" == *"disabled by AI_ENGINES, not probed: gemini, copilot"* ]]
  [[ "$output" != *"depleted"* ]]
  rm -rf "$VBIN"
}

# ── review-batch.sh walks the configured chain ────────────────────────────────

# Set up a temporary batch test directory (in BDIR) with review-batch.sh and mocked dependencies.
_setup_batch() {
  BDIR="$(mktemp -d)"
  mkdir -p "$BDIR/scripts/lib" "$BDIR/bin"
  cp "$SCRIPT_DIR/scripts/review-batch.sh" "$BDIR/scripts/"
  cp "$LIB" "$BDIR/scripts/lib/"
  printf 'https://github.com/fake/pull/1\n' > "$BDIR/prs.txt"
  cat > "$BDIR/scripts/validate-engines.sh" <<'EOF'
validate_engines() {
  export CLAUDE_AVAILABLE="${MOCK_C:-true}" GEMINI_AVAILABLE="${MOCK_G:-true}" COPILOT_AVAILABLE="${MOCK_P:-true}"
}
EOF
  printf 'export COPILOT_API_MODEL="openai/o4-mini"\n' > "$BDIR/scripts/engine.sh"
  # review-one-pr stub: records the engine; exits with MOCK_RC_<engine> (default 0).
  cat > "$BDIR/scripts/review-one-pr.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$REVIEW_ENGINE" >> engine_calls.txt
o="MOCK_OUT_${REVIEW_ENGINE}"
[ -n "${!o:-}" ] && printf '%s\n' "${!o}"
v="MOCK_RC_${REVIEW_ENGINE}"
exit "${!v:-0}"
EOF
  chmod +x "$BDIR/scripts/review-one-pr.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "{\\"choices\\":[{\\"message\\":{\\"content\\":\\"ready\\"}}]}" 200\n' > "$BDIR/bin/curl"
  printf '#!/bin/bash\nexit 0\n' > "$BDIR/bin/gh"
  chmod +x "$BDIR/bin/"*
}

_batch() {
  (cd "$BDIR" && PATH="$BDIR/bin:$PATH" PRS_FILE=prs.txt CANDIDATE_LIMIT=1 MAX_PRS=1 DRY_RUN=true \
    bash scripts/review-batch.sh)
}

@test "batch: AI_ENGINES=claude,copilot skips Gemini on a Claude rate limit" {
  _setup_batch
  export AI_ENGINES="claude,copilot" MOCK_RC_claude=2
  run _batch
  [ "$status" -eq 0 ]
  [ "$(tr '\n' ' ' < "$BDIR/engine_calls.txt")" = "claude copilot " ]
  [[ "$output" == *"switching to Copilot engine"* ]]
  rm -rf "$BDIR"
}

@test "batch: AI_ENGINES=gemini,claude makes Gemini the primary" {
  _setup_batch
  export AI_ENGINES="gemini,claude"
  run _batch
  [ "$status" -eq 0 ]
  [ "$(head -1 "$BDIR/engine_calls.txt")" = "gemini" ]
  rm -rf "$BDIR"
}

@test "batch: a REVIEW_ENGINE that AI_ENGINES disables is not used" {
  _setup_batch
  export AI_ENGINES="claude,gemini" REVIEW_ENGINE=copilot
  run _batch
  [ "$status" -eq 0 ]
  ! grep -q '^copilot$' "$BDIR/engine_calls.txt" || false
  [[ "$output" == *"REVIEW_ENGINE=copilot is not enabled in AI_ENGINES"* ]]
  rm -rf "$BDIR"
}

@test "batch: Gemini runtime failure then unavailable Copilot → skip PR, no session abort" {
  _setup_batch
  export MOCK_RC_claude=2 MOCK_RC_gemini=55 MOCK_P=false
  run _batch
  [[ "$output" == *"skipping https://github.com/fake/pull/1 and continuing batch"* ]]
  [[ "$output" != *"SESSION ABORTED"* ]]
  rm -rf "$BDIR"
}

@test "batch: single-engine chain rate-limited → session abort (nothing to fall back to)" {
  _setup_batch
  export AI_ENGINES="claude" MOCK_RC_claude=2
  run _batch
  [ "$status" -eq 1 ]
  [[ "$output" == *"no fallback available"* ]]
  rm -rf "$BDIR"
}

# ── dev-lead-preflight.sh: Claude token required only when AI_ENGINES enables claude ──

# Run dev-lead-preflight.sh without CLAUDE_CODE_OAUTH_TOKEN set.
_preflight() {
  bash -c "unset GITHUB_STEP_SUMMARY CLAUDE_CODE_OAUTH_TOKEN; bash '$SCRIPT_DIR/scripts/dev-lead-preflight.sh'"
}

@test "preflight: Claude token required by default" {
  run _preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required secret not set: CLAUDE_CODE_OAUTH_TOKEN"* ]]
}

@test "preflight: Claude token optional when AI_ENGINES leaves claude out" {
  export AI_ENGINES="gemini,copilot"
  run _preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude not in AI_ENGINES"* ]]
}

@test "preflight: an invalid AI_ENGINES still requires the Claude token (default chain)" {
  export AI_ENGINES="gemini,cluade"
  run _preflight
  [ "$status" -eq 1 ]
}

# ── #1961 review follow-ups ───────────────────────────────────────────────────

@test "primary: the override is case-insensitive (REVIEW_ENGINE=GEMINI)" {
  export AI_ENGINES="claude,gemini"
  [ "$(ai_engine_primary GEMINI)" = "gemini" ]
}

@test "chain problem: a leading space or comma is reported (workflow primary derivation)" {
  export AI_ENGINES=" gemini,claude"
  [ "$(ai_engine_chain)" = "gemini claude" ]
  [[ "$(ai_engine_chain_problem)" == *"starts with a space or comma"* ]]
}

@test "validate: a generic GH_TOKEN does not make Copilot available" {
  _setup_validate_bin
  local tok="github_pat_""abc"
  unset COPILOT_GITHUB_TOKEN
  export GH_TOKEN="$tok" GOOGLE_API_KEY=k1
  run _validate
  [[ "$output" == *"P=false"* ]]
  [[ "$output" == *"COPILOT_GITHUB_TOKEN is not set"* ]]
  rm -rf "$VBIN"
}

@test "batch: last fallback unavailable at runtime (exit 55) → skip PR, no session abort" {
  _setup_batch
  export AI_ENGINES="claude,gemini" MOCK_RC_claude=2 MOCK_RC_gemini=55
  run _batch
  [[ "$output" == *"skipping https://github.com/fake/pull/1 and continuing batch"* ]]
  [[ "$output" != *"SESSION ABORTED"* ]]
  rm -rf "$BDIR"
}

@test "primary: an invalid AI_ENGINES ignores the derived override → default primary" {
  export AI_ENGINES="copilot,typo"
  [ "$(ai_engine_chain)" = "claude gemini copilot" ]
  [ "$(ai_engine_primary copilot)" = "claude" ]
}

@test "chain problem: a separators-only AI_ENGINES is reported, not treated as unset" {
  export AI_ENGINES=" , "
  [ "$(ai_engine_chain)" = "claude gemini copilot" ]
  [[ "$(ai_engine_chain_problem)" == *"lists no engine"* ]]
}

@test "keys: probe-depleted Gemini keys are tried last, not first" {
  run bash -c "export GOOGLE_API_KEY=k1 GOOGLE_API_KEY_2=k2 GOOGLE_API_KEY_3=k3 GEMINI_DEPLETED_KEYS='GOOGLE_API_KEY'; unset GEMINI_API_KEY; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1; _gemini_api_keys | tr '\n' ' '"
  [ "$status" -eq 0 ]
  [ "$output" = "k2 k3 k1 " ]
}

@test "validate: the depleted key names are exported for the engine's key rotation" {
  _setup_validate_bin
  export GOOGLE_API_KEY=k1 GOOGLE_API_KEY_2=k2 MOCK_DEPLETED_KEYS="k1"
  run bash -c "export PATH='$VBIN':\$PATH GEMINI_CLI_TRUST_WORKSPACE=true CLAUDE_CODE_OAUTH_TOKEN=x; unset GITHUB_STEP_SUMMARY GEMINI_API_KEY; source '$SCRIPT_DIR/scripts/validate-engines.sh' >/dev/null 2>&1; validate_engines >/dev/null 2>&1; bash -c 'echo \"D=\$GEMINI_DEPLETED_KEYS\"'"
  [[ "$output" == *"D=GOOGLE_API_KEY"* ]]
  rm -rf "$VBIN"
}

@test "batch: an unavailable middle fallback does not mask a rate-limited last engine → session abort" {
  _setup_batch
  export MOCK_RC_claude=2 MOCK_RC_gemini=55 MOCK_RC_copilot=2
  run _batch
  [ "$status" -eq 1 ]
  [[ "$output" != *"skipping https://github.com/fake/pull/1 and continuing batch"* ]]
  [ "$(tr '\n' ' ' < "$BDIR/engine_calls.txt")" = "claude gemini copilot " ]
  rm -rf "$BDIR"
}

# Run run_duck with <prompt_file> and engine <name> to test key scrubbing and credential isolation.
_run_duck_probe() {
  local p; p="$(mktemp)"; echo "duck prompt" > "$p"
  bash -c "source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1
    copilot_chat() { echo \"copilot-model=\$COPILOT_API_MODEL\"; }
    _gemini_invoke() { echo \"gemini-key=\$GOOGLE_API_KEY\"; }
    DUCK_ENGINE=\"\$2\"
    run_duck '$p' \"\$1\"" _ "$1" "$2" 2>/dev/null
  rm -f "$p"
}

@test "duck: a Claude or Copilot duck gets none of the Gemini keys (rotation keys included)" {
  local p; p="$(mktemp)"; echo "duck prompt" > "$p"
  run bash -c "export GOOGLE_API_KEY=k1 GOOGLE_API_KEY_2=k2 GOOGLE_API_KEY_3=k3 GOOGLE_API_KEY_4=k4 GEMINI_API_KEY=k0
    source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1
    _keys() { echo \"\$1-keys=[\${GOOGLE_API_KEY:-}\${GOOGLE_API_KEY_2:-}\${GOOGLE_API_KEY_3:-}\${GOOGLE_API_KEY_4:-}\${GEMINI_API_KEY:-}]\"; }
    _claude_chain_invoke() { _keys claude; }
    copilot_chat() { _keys copilot; }
    DUCK_ENGINE=claude run_duck '$p' claude-sonnet-4-6 2>/dev/null
    DUCK_ENGINE=copilot run_duck '$p' o4-mini 2>/dev/null"
  rm -f "$p"
  [[ "$output" == *"claude-keys=[]"* ]]
  [[ "$output" == *"copilot-keys=[]"* ]]
}

@test "duck: an explicit AI_DUCK_MODEL reaches the Copilot call; the default label does not" {
  export AI_DUCK_ENGINE=copilot AI_DUCK_MODEL=gpt-test COPILOT_API_MODEL=openai/o4-mini
  [ "$(_run_duck_probe gpt-test copilot)" = "copilot-model=gpt-test" ]
  unset AI_DUCK_MODEL
  [ "$(_run_duck_probe o4-mini copilot)" = "copilot-model=openai/o4-mini" ]
}

@test "duck: AI_DUCK_MODEL reaches the Copilot call only when AI_DUCK_ENGINE is copilot" {
  export AI_DUCK_ENGINE=gemini AI_DUCK_MODEL=o4-mini COPILOT_API_MODEL=openai/o4-mini
  [ "$(_run_duck_probe o4-mini copilot)" = "copilot-model=openai/o4-mini" ]
}

@test "duck: a Gemini duck uses key rotation (probe-depleted key tried last)" {
  export GOOGLE_API_KEY=k1 GOOGLE_API_KEY_2=k2 GEMINI_DEPLETED_KEYS=GOOGLE_API_KEY
  unset GEMINI_API_KEY
  [ "$(_run_duck_probe gemini-test gemini)" = "gemini-key=k2" ]
}

@test "engine.sh: an invalid AI_ENGINES is reported when sourced alone (dev-lead), once per run" {
  run bash -c "export AI_ENGINES=claude,typo; unset AI_ENGINES_PROBLEM_REPORTED; source '$SCRIPT_DIR/scripts/engine.sh' 2>&1 >/dev/null | grep -c 'names an unknown engine'"
  [ "$output" = "1" ]
  run bash -c "export AI_ENGINES=claude,typo AI_ENGINES_PROBLEM_REPORTED=1; source '$SCRIPT_DIR/scripts/engine.sh' 2>&1 >/dev/null | grep -c 'names an unknown engine'"
  [ "$output" = "0" ]
}

@test "duck: the automatic Gemini duck (Copilot primary) honours GEMINI_FLASH_MODEL" {
  run bash -c "export REVIEW_ENGINE=copilot GEMINI_FLASH_MODEL=gemini-custom; unset AI_DUCK_ENGINE AI_DUCK_MODEL; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1; select_duck_engine"
  [ "$output" = "gemini gemini-custom" ]
}

@test "chain: a multi-line AI_ENGINES is parsed whole (newlines separate engines)" {
  export AI_ENGINES=$'gemini\nclaude'
  [ "$(ai_engine_chain)" = "gemini claude" ]
  export AI_ENGINES=$'claude\ncluade'
  [ "$(ai_engine_chain)" = "claude gemini copilot" ]
  [[ "$(ai_engine_chain_problem)" == *"unknown engine"* ]]
}

@test "batch: a Copilot policy denial on a fallback continues the chain (not a hard failure)" {
  _setup_batch
  export AI_ENGINES="claude,copilot,gemini" MOCK_RC_claude=2 MOCK_RC_copilot=1 \
    MOCK_OUT_copilot="Error: Access denied by policy settings"
  run _batch
  [ "$status" -eq 0 ]
  [ "$(tr '\n' ' ' < "$BDIR/engine_calls.txt")" = "claude copilot gemini " ]
  [[ "$output" == *"Review posted"* ]]
  rm -rf "$BDIR"
}

@test "batch: an engine rate-limited on one PR is not re-invoked for the next; exhausted batch stops" {
  _setup_batch
  printf 'https://github.com/fake/pull/1\nhttps://github.com/fake/pull/2\n' > "$BDIR/prs.txt"
  export MOCK_RC_claude=2 MOCK_RC_gemini=55 MOCK_RC_copilot=55
  run bash -c "cd '$BDIR' && PATH='$BDIR/bin':\$PATH PRS_FILE=prs.txt CANDIDATE_LIMIT=2 MAX_PRS=2 DRY_RUN=true bash scripts/review-batch.sh"
  [ "$(tr '\n' ' ' < "$BDIR/engine_calls.txt")" = "claude gemini copilot " ]
  [[ "$output" == *"rate-limited or unavailable in this batch"* ]]
  rm -rf "$BDIR"
}

@test "batch: the Copilot policy-denial phrases match engine.sh's _license_denied_pattern" {
  pat="$(bash -c "source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1; _license_denied_pattern")"
  [ -n "$pat" ]
  grep -qF "_BATCH_LICENSE_DENIED_RE=\"$pat\"" "$SCRIPT_DIR/scripts/review-batch.sh"
}

@test "duck: an engine rate-limited earlier in the batch (AI_ENGINES_RATE_LIMITED) is not chosen as the duck" {
  run bash -c "export REVIEW_ENGINE=gemini AI_ENGINES_RATE_LIMITED=claude; unset AI_DUCK_ENGINE AI_DUCK_MODEL CLAUDE_AVAILABLE GEMINI_AVAILABLE COPILOT_AVAILABLE; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1; select_duck_engine"
  [[ "$output" != claude* ]]
  [[ "$output" == copilot* ]]
}

@test "batch: a rate-limited engine is exported to child processes (AI_ENGINES_RATE_LIMITED)" {
  _setup_batch
  cat > "$BDIR/scripts/review-one-pr.sh" <<'EOS'
#!/bin/bash
printf '%s rl=[%s]\n' "$REVIEW_ENGINE" "${AI_ENGINES_RATE_LIMITED:-}" >> engine_calls.txt
v="MOCK_RC_${REVIEW_ENGINE}"
exit "${!v:-0}"
EOS
  chmod +x "$BDIR/scripts/review-one-pr.sh"
  export MOCK_RC_claude=2
  run _batch
  [ "$status" -eq 0 ]
  grep -q '^gemini rl=\[claude\]$' "$BDIR/engine_calls.txt"
  rm -rf "$BDIR"
}
