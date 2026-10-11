#!/usr/bin/env bash
# validate-engines.sh — Pre-flight availability check for review engines.
#
# Provides:
#   validate_engines()   — checks Claude, Gemini, and Copilot availability
#
# After validate_engines() returns the following vars are exported:
#   CLAUDE_AVAILABLE   — "true" if claude CLI + CLAUDE_CODE_OAUTH_TOKEN are present
#   GEMINI_AVAILABLE   — "true" if gemini CLI + at least one Gemini key with
#                        credits (GOOGLE_API_KEY, GOOGLE_API_KEY_2, _3, _4) are present
#   COPILOT_AVAILABLE  — "true" if gh copilot is usable with COPILOT_GITHUB_TOKEN
#                        (a classic ghp_ PAT is not: Copilot rejects it; a policy
#                        denial or any other probe failure gets one warning)
#
# Engines left out of AI_ENGINES (scripts/lib/engine-chain.sh) are reported as
# disabled and not probed — turning an engine off is a configuration choice, not
# a degraded state, so it gets a notice rather than a warning.
#
# For each unavailable fallback engine a ::warning:: annotation is emitted that
# includes the exact command an operator needs to fix the gap — so the log is
# self-contained and there is no silent skip.
#
# If GITHUB_STEP_SUMMARY is set (normal in GitHub Actions) an engine-availability
# table is appended to the job summary so the degraded state is always visible
# in the run UI without needing to dig into logs.
#
# Always exits 0.  Degraded state is recorded but never aborts the run.

# Engine chain (AI_ENGINES). Optional: when the library is absent every engine
# counts as enabled, which is the pre-AI_ENGINES behaviour.
_VALIDATE_ENGINES_CHAIN_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/engine-chain.sh"
# shellcheck source=lib/engine-chain.sh
[ -f "$_VALIDATE_ENGINES_CHAIN_LIB" ] && source "$_VALIDATE_ENGINES_CHAIN_LIB"
unset _VALIDATE_ENGINES_CHAIN_LIB
# Provider model lists (AI_MODELS_*). Optional: without it the probe uses the
# built-in flash model.
_VALIDATE_ENGINES_MODELS_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/engine-models.sh"
# shellcheck source=lib/engine-models.sh
[ -f "$_VALIDATE_ENGINES_MODELS_LIB" ] && source "$_VALIDATE_ENGINES_MODELS_LIB"
unset _VALIDATE_ENGINES_MODELS_LIB

# Copilot licensing/policy denial (#1546, #1960). Same phrases as engine.sh's
# _license_denied_pattern (a bats case keeps the two in sync); copied rather than
# sourced because engine.sh sets `set -euo pipefail` and initialises the engine.
_VALIDATE_LICENSE_DENIED_RE="(access denied by policy settings|not supported by copilot)"

# _gemini_probe_model — the configured Gemini triage model (the tier the probe
# stands in for), without Google's optional "models/" prefix; gemini-3.8-flash
# when the models library is absent. Prints nothing when the configured id is
# not URL-safe, so the caller skips the probe rather than probe another model.
_gemini_probe_model() {
  local m="gemini-3.8-flash"
  if declare -F ai_models_gemini_chain >/dev/null 2>&1; then
    m="$(ai_models_gemini_chain triage)"
    m="${m%%,*}"
  fi
  m="${m#models/}"
  [[ "$m" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 0
  printf '%s' "$m"
}

# _validate_engine_enabled <engine> — 0 unless AI_ENGINES leaves <engine> out.
_validate_engine_enabled() {
  if declare -F ai_engine_enabled >/dev/null 2>&1; then
    ai_engine_enabled "$1"
  else
    return 0
  fi
}

# _gemini_probe_key <key> — minimal REST call with one Gemini key.
# Returns 1 only when the response explicitly reports depleted prepayment
# credits; any other outcome (success, network error, invalid key, transient
# RESOURCE_EXHAUSTED quota) is "undetermined" and returns 0 (fail-open: Gemini
# proceeds and fails loudly at call time if it really is broken). The probe
# calls the configured flash model; when that model is not found the depletion
# check cannot run, so it warns once instead of passing silently.
_gemini_probe_key() {
  local _key="$1" _raw _body _code _model
  _model="$(_gemini_probe_model)"
  if [ -z "$_model" ]; then
    if [ -z "${_GEMINI_PROBE_MODEL_WARNED:-}" ]; then
      echo "::warning::Gemini billing probe skipped: the configured flash model is not a probe-able id — credit depletion is undetermined." >&2
      _GEMINI_PROBE_MODEL_WARNED=1
    fi
    return 0
  fi
  _raw=$(
    timeout 15 curl -sS --max-time 10 \
      -X POST \
      -H "Content-Type: application/json" \
      -H "X-Goog-Api-Key: ${_key}" \
      "https://generativelanguage.googleapis.com/v1beta/models/${_model}:generateContent" \
      -d '{"contents":[{"parts":[{"text":"Hi"}]}],"generationConfig":{"maxOutputTokens":1}}' \
      -w '\n%{http_code}' 2>/dev/null
  ) || true
  # Strip the trailing HTTP status code line appended by -w; check only the body.
  _body=$(printf '%s' "$_raw" | sed '$d')
  _code=$(printf '%s' "$_raw" | tail -n 1)
  if printf '%s' "$_body" | grep -qiE "credits.*depleted"; then
    return 1
  fi
  if [ "$_code" = "404" ] || printf '%s' "$_body" | grep -qiE "no longer available|is not found|NOT_FOUND"; then
    if [ -z "${_GEMINI_PROBE_MODEL_WARNED:-}" ]; then
      echo "::warning::Gemini billing probe: model '${_model}' was not found — credit depletion is undetermined. Check AI_MODELS_GEMINI triage / GEMINI_FLASH_MODEL." >&2
      _GEMINI_PROBE_MODEL_WARNED=1
    fi
  fi
  return 0
}

# _gemini_billing_probe
# Probes EVERY configured Gemini key (GEMINI_API_KEY / GOOGLE_API_KEY, then the
# #1777 rotation keys GOOGLE_API_KEY_2, GOOGLE_API_KEY_3 and GOOGLE_API_KEY_4;
# duplicates probed once) to detect depleted prepayment credits before the first PR review. The
# Gemini CLI retries billing exhaustion 10× with backoff (~4 min); detecting it
# here lets validate_engines skip a dead engine immediately. _gemini_invoke
# rotates across the same keys at call time, so Gemini is usable while ANY key
# has credits — probing only the first key wrongly disabled Gemini whenever
# that one key ran dry.
#
# Returns 0 — at least one key is OK or undetermined (fail-open).
# Returns 1 — every configured key explicitly reports depleted credits.
# Sets GEMINI_DEPLETED_KEYS to the NAMES (never values) of depleted keys.
#
# Requires: curl (skips the probe — returns 0 — when curl is absent).
_gemini_billing_probe() {
  GEMINI_DEPLETED_KEYS=""
  if ! command -v curl >/dev/null 2>&1; then
    return 0
  fi
  local _name _key _seen="" _any=0 _ok=0
  for _name in GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_API_KEY_2 GOOGLE_API_KEY_3 GOOGLE_API_KEY_4; do
    _key="${!_name:-}"
    [ -z "$_key" ] && continue
    case "$_seen" in
      *"|${_key}|"*) continue ;;
    esac
    _seen="${_seen}|${_key}|"
    _any=1
    if _gemini_probe_key "$_key"; then
      _ok=1
    else
      GEMINI_DEPLETED_KEYS="${GEMINI_DEPLETED_KEYS:+$GEMINI_DEPLETED_KEYS, }$_name"
    fi
  done
  [ "$_any" -eq 0 ] && return 0
  [ "$_ok" -eq 1 ]
}

validate_engines() {
  local claude_ok=false gemini_ok=false copilot_ok=false

  # Deliberate fleet pause (#1525): AGENTS_PAUSED=true is a maintainer decision,
  # not a misconfiguration — report it distinctly and skip availability probes
  # so the paused state is never mistaken for missing/broken engine credentials.
  if [ "${AGENTS_PAUSED:-false}" = "true" ]; then
    echo "::notice::validate-engines: agent fleet deliberately paused (AGENTS_PAUSED=true) — engine availability not evaluated (#1525)"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "**Engines: fleet paused** (\`AGENTS_PAUSED=true\`, #1525) — availability not evaluated." >> "$GITHUB_STEP_SUMMARY"
    fi
    export CLAUDE_AVAILABLE=false GEMINI_AVAILABLE=false COPILOT_AVAILABLE=false
    return 0
  fi

  # ── Engine chain (AI_ENGINES) ───────────────────────────────────────────────
  local _chain_problem="" _disabled=""
  if declare -F ai_engine_chain_problem >/dev/null 2>&1; then
    _chain_problem="$(ai_engine_chain_problem)"
    if [ -n "$_chain_problem" ] && [ -z "${AI_ENGINES_PROBLEM_REPORTED:-}" ]; then
      echo "::warning::$_chain_problem"
      export AI_ENGINES_PROBLEM_REPORTED=1
    fi
    echo "::notice::Engine chain (AI_ENGINES): $(ai_engine_chain)"
  fi

  # ── Claude ──────────────────────────────────────────────────────────────────
  if ! _validate_engine_enabled claude; then
    _disabled="${_disabled:+$_disabled, }claude"
  elif command -v claude >/dev/null 2>&1 && [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    claude_ok=true
  fi

  # ── Gemini ──────────────────────────────────────────────────────────────────
  # Collect every reason the engine is unavailable so the warning is precise.
  local gemini_reasons=""

  append_gemini_reason() {
    if [ -n "$gemini_reasons" ]; then
      gemini_reasons="$gemini_reasons; $1"
    else
      gemini_reasons="$1"
    fi
  }

  if ! _validate_engine_enabled gemini; then
    _disabled="${_disabled:+$_disabled, }gemini"
  else
    if ! command -v gemini >/dev/null 2>&1; then
      append_gemini_reason "Gemini CLI not installed (fix: npm install -g @google/gemini-cli)"
    fi
    # Check for any available Gemini API key: primary (GEMINI_API_KEY or GOOGLE_API_KEY)
    # or secondary rotation keys (GOOGLE_API_KEY_2, _3, _4) per issue #1777.
    if [ -z "${GEMINI_API_KEY:-}" ] && [ -z "${GOOGLE_API_KEY:-}" ] && \
       [ -z "${GOOGLE_API_KEY_2:-}" ] && [ -z "${GOOGLE_API_KEY_3:-}" ] && \
       [ -z "${GOOGLE_API_KEY_4:-}" ]; then
      append_gemini_reason "No Gemini API key configured (set GOOGLE_API_KEY, GOOGLE_API_KEY_2, GOOGLE_API_KEY_3 or GOOGLE_API_KEY_4)"
    fi
    if [ "${GEMINI_CLI_TRUST_WORKSPACE:-false}" != "true" ]; then
      append_gemini_reason "GEMINI_CLI_TRUST_WORKSPACE is not true (fix: set in env or pass --skip-trust)"
    fi

    if [ -z "$gemini_reasons" ]; then
      # All basic checks pass — probe the REST API for billing depletion.
      # Depleted prepayment credits cause the Gemini CLI to retry 10× (~4 min)
      # before surfacing the error; detecting it here lets us skip Gemini entirely
      # and fall through to the next engine immediately.
      if _gemini_billing_probe; then
        gemini_ok=true
        if [ -n "${GEMINI_DEPLETED_KEYS:-}" ]; then
          echo "::warning::Gemini key(s) with depleted prepayment credits: ${GEMINI_DEPLETED_KEYS} — Gemini stays available on the remaining key(s); replenish via Google AI Studio (https://aistudio.google.com/billing)"
        fi
      else
        append_gemini_reason "prepayment credits depleted on every configured key (${GEMINI_DEPLETED_KEYS:-none}) — replenish via Google AI Studio (https://aistudio.google.com/billing)"
      fi
    fi

    if [ -n "$gemini_reasons" ]; then
      echo "::warning::Gemini fallback unavailable — ${gemini_reasons}. When Claude is rate-limited, runs will fall through to the next engine in AI_ENGINES."
    fi
  fi

  # ── Copilot ─────────────────────────────────────────────────────────────────
  # gh copilot is now a built-in; auth via COPILOT_GITHUB_TOKEN (the PAT of the
  # account holding the Copilot entitlement). A generic GH_TOKEN (workflow token,
  # automation PAT) does NOT stand in for it: `gh copilot --version` succeeds on
  # any token, so accepting GH_TOKEN reported Copilot available on runs whose
  # review would then fail its smoke test or at call time (#1961 review).
  # A classic PAT (ghp_) is rejected by Copilot at call time ("Classic Personal
  # Access Tokens (ghp_) are not supported by Copilot"), so `gh copilot
  # --version` succeeding proves nothing — report it unavailable up front, the
  # same rule dev-lead's fallback applies (#1495, #1960).
  local _copilot_tok="${COPILOT_GITHUB_TOKEN:-}"
  if ! _validate_engine_enabled copilot; then
    _disabled="${_disabled:+$_disabled, }copilot"
  elif [ -z "$_copilot_tok" ]; then
    echo "::warning::Copilot unavailable — COPILOT_GITHUB_TOKEN is not set. Provide a fine-grained PAT with the Copilot entitlement or remove copilot from AI_ENGINES."
  elif [[ "$_copilot_tok" == ghp_* ]]; then
    echo "::warning::Copilot unavailable — COPILOT_GITHUB_TOKEN is a classic PAT (ghp_), which Copilot rejects. Use a fine-grained PAT or remove copilot from AI_ENGINES."
  else
    # A policy denial (no Copilot subscription/policy for the token's org) or any
    # other probe failure is reported once, never left as a silent false (#1960).
    # The CLI output is matched, not echoed: only the matched phrase is logged.
    local _copilot_out _copilot_rc=0 _denied
    _copilot_out="$(env GH_TOKEN="$_copilot_tok" gh copilot --version 2>&1)" || _copilot_rc=$?
    _denied="$(printf '%s\n' "$_copilot_out" | grep -oiE "$_VALIDATE_LICENSE_DENIED_RE" | head -n 1 \
      | tr '[:upper:]' '[:lower:]' || true)"
    if [ -n "$_denied" ]; then
      echo "::warning::Copilot unavailable — ${_denied} (the token's account or org has no usable Copilot entitlement). Fix the Copilot policy/subscription or remove copilot from AI_ENGINES."
    elif [ "$_copilot_rc" -ne 0 ]; then
      echo "::warning::Copilot unavailable — \`gh copilot --version\` failed (exit ${_copilot_rc}). Check the gh CLI and COPILOT_GITHUB_TOKEN, or remove copilot from AI_ENGINES."
    else
      copilot_ok=true
    fi
  fi

  if [ -n "$_disabled" ]; then
    echo "::notice::Engine(s) disabled by AI_ENGINES, not probed: ${_disabled}"
  fi

  export CLAUDE_AVAILABLE="$claude_ok"
  export GEMINI_AVAILABLE="$gemini_ok"
  export COPILOT_AVAILABLE="$copilot_ok"
  # Names only (never values): engine.sh's _gemini_api_keys tries these last.
  export GEMINI_DEPLETED_KEYS="${GEMINI_DEPLETED_KEYS:-}"

  _emit_engine_summary "$claude_ok" "$gemini_ok" "$copilot_ok"
}

# _engine_badge <bool>  →  "ok" or "unavailable"
_engine_badge() {
  [ "$1" = "true" ] && printf 'ok' || printf 'unavailable'
}

# _emit_engine_summary <claude_ok> <gemini_ok> <copilot_ok>
# Appends an engine-availability Markdown table to GITHUB_STEP_SUMMARY.
# No-ops when GITHUB_STEP_SUMMARY is unset (local runs, unit tests without
# a summary file).
_emit_engine_summary() {
  local claude_ok="$1" gemini_ok="$2" copilot_ok="$3"
  local dest="${GITHUB_STEP_SUMMARY:-}"
  [ -z "$dest" ] && return 0
  {
    printf '### Engine availability (pre-flight)\n\n'
    printf '| Engine  | Status |\n'
    printf '|---------|--------|\n'
    printf '| Claude  | %s |\n' "$(_engine_badge "$claude_ok")"
    printf '| Gemini  | %s |\n' "$(_engine_badge "$gemini_ok")"
    printf '| Copilot | %s |\n' "$(_engine_badge "$copilot_ok")"
    printf '\n'
  } >> "$dest"
}
