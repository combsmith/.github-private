# shellcheck shell=bash
# scripts/lib/engine-chain.sh — the configured AI engine chain (AI_ENGINES).
#
# config/ai-engines.json (#1973) enables the providers and sets their default
# order (providers.fallback_order; see engine-models.sh, which reads it). One
# org/repo Actions variable, AI_ENGINES, is the kill switch on top of the file:
# it turns engines off and reorders them with no release, but it cannot turn on
# a provider the file disables:
#
#   AI_ENGINES unset                     the file's enabled providers, in its order
#                                        (today claude gemini copilot)
#   AI_ENGINES="claude,gemini"           Copilot off (never tried, not even as a fallback)
#   AI_ENGINES="gemini,claude"           Gemini first, Claude as the fallback
#   AI_ENGINES="claude"                  Claude only
#
#   - membership = enabled. An engine that is not listed is never used, nor is
#                  one the file disables (ai_engine_chain_problem reports it).
#   - order      = fallback preference, walked left to right on a rate limit.
#   - first      = the primary engine, unless REVIEW_ENGINE / DEV_LEAD_ENGINE is
#                  set explicitly (a legacy override; it is ignored, with a
#                  warning, when it names an engine AI_ENGINES leaves out).
#
# Comma- or space-separated, case-insensitive. DEV_LEAD_ENGINES (#1546) is the
# legacy name and is read only when AI_ENGINES is unset. An unknown token (a
# typo such as "cluade") invalidates the WHOLE value and the default chain is
# used, so a typo can never silently drop fallbacks; ai_engine_chain_problem
# reports it so validate_engines can warn once. A value that names only
# providers the file disables is treated the same way.
#
# Sourced by engine.sh, validate-engines.sh and review-batch.sh. Defines
# functions only; at source time it only sources engine-models.sh (the file
# reader) when that lib sits next to it, and it does not call `set`.

# The built-in order. Used only when engine-models.sh is not next to this lib (a
# test fixture that copies this file alone), or when the file cannot be read;
# the reader prints the ::error:: then, and engine.sh fails the step on it.
AI_ENGINES_DEFAULT="claude gemini copilot"

if ! declare -F ai_engines_file_providers >/dev/null 2>&1 \
   && [[ -f "$(dirname "${BASH_SOURCE[0]}")/engine-models.sh" ]]; then
  # shellcheck source=scripts/lib/engine-models.sh
  source "$(dirname "${BASH_SOURCE[0]}")/engine-models.sh"
fi

# _ai_engine_default_chain — the file's enabled providers in fallback_order
# (empty if the file enables none, which validate-ai-engines rejects; the
# built-in order never re-enables them); AI_ENGINES_DEFAULT when the reader is
# absent or the file cannot be read.
_ai_engine_default_chain() {
  local c
  if declare -F ai_engines_file_providers >/dev/null 2>&1 && c="$(ai_engines_file_providers)"; then
    printf '%s' "$c"
    return 0
  fi
  printf '%s' "$AI_ENGINES_DEFAULT"
}

# _ai_engine_file_disabled — the providers the file disables (space-separated);
# nothing when the reader is absent or the file cannot be read (the default
# chain has already reported that).
_ai_engine_file_disabled() {
  declare -F ai_engines_file_disabled >/dev/null 2>&1 || return 0
  ai_engines_file_disabled 2>/dev/null || true
}

# _ai_engine_spec — the raw configured value (AI_ENGINES, else DEV_LEAD_ENGINES).
_ai_engine_spec() {
  printf '%s' "${AI_ENGINES:-${DEV_LEAD_ENGINES:-}}"
}

# _ai_engine_parse <spec> — prints the valid engines in order (space-separated)
# and returns 1 when the spec contains an unknown token. Never pathname-expands
# the spec (read -a, not an unquoted for-loop), so "*" stays a literal token.
_ai_engine_parse() {
  local spec="$1" t invalid=0
  local -a toks=() out=()
  # Commas and any whitespace (newlines included — a multi-line variable must
  # not silently parse as its first line) separate engines.
  spec="$(printf '%s' "$spec" | tr ',\n\r\t' '    ' | tr '[:upper:]' '[:lower:]')"
  IFS=$' \t' read -r -a toks <<< "$spec"
  for t in "${toks[@]}"; do
    case "$t" in
      claude|gemini|copilot)
        [[ " ${out[*]-} " == *" $t "* ]] || out+=("$t") ;;
      *) invalid=1 ;;
    esac
  done
  printf '%s' "${out[*]-}"
  return "$invalid"
}

# _ai_engine_narrowed <spec> — the engines <spec> lists, in order, minus those
# the file disables. Returns 1 when that leaves none or <spec> names an unknown
# engine: the caller then uses the default chain.
_ai_engine_narrowed() {
  local parsed disabled e kept=""
  parsed="$(_ai_engine_parse "$1")" || return 1
  disabled="$(_ai_engine_file_disabled)"
  for e in $parsed; do
    [[ " $disabled " == *" $e "* ]] || kept="${kept:+$kept }$e"
  done
  printf '%s' "$kept"
  [[ -n "$kept" ]]
}

# ai_engine_chain — the enabled engines in preference order, space-separated.
# AI_ENGINES narrows the file's chain; empty or invalid configuration, or one
# that names only providers the file disables → the file's chain.
ai_engine_chain() {
  local chain
  if chain="$(_ai_engine_narrowed "$(_ai_engine_spec)")"; then
    printf '%s' "$chain"
  else
    _ai_engine_default_chain
  fi
}

# ai_engine_chain_problem — prints a one-line description when the configured
# value is unusable (unknown engine, nothing but separators, or an engine the
# file disables); prints nothing when it is fine or unset.
ai_engine_chain_problem() {
  local spec parsed disabled e off=""
  spec="$(_ai_engine_spec)"
  [[ -n "$spec" ]] || return 0
  if [[ -z "${spec//[[:space:],]/}" ]]; then
    printf "AI_ENGINES='%s' lists no engine — using the default chain '%s'" \
      "$spec" "$(_ai_engine_default_chain)"
    return 0
  elif ! parsed="$(_ai_engine_parse "$spec")" || [[ -z "$parsed" ]]; then
    printf "AI_ENGINES='%s' names an unknown engine (expected claude, gemini, copilot) — using the default chain '%s'" \
      "$spec" "$(_ai_engine_default_chain)"
    return 0
  fi
  disabled="$(_ai_engine_file_disabled)"
  for e in $parsed; do
    [[ " $disabled " != *" $e "* ]] || off="${off:+$off, }$e"
  done
  if [[ -n "$off" ]]; then
    # AI_ENGINES narrows the file; it cannot turn a provider back on.
    printf "AI_ENGINES='%s' names %s, which config/ai-engines.json disables — left out (enable a provider in the file, not with AI_ENGINES); using '%s'" \
      "$spec" "$off" "$(ai_engine_chain)"
  elif [[ "$spec" =~ ^[[:space:],] ]]; then
    # The workflows derive the primary with startsWith(vars.AI_ENGINES, …),
    # which cannot skip leading separators.
    printf "AI_ENGINES='%s' starts with a space or comma — the workflows read the primary engine from the start of the value, so start it with an engine name" \
      "$spec"
  fi
}

# ai_engine_enabled <engine> — 0 when <engine> is in the configured chain.
ai_engine_enabled() {
  [[ " $(ai_engine_chain) " == *" ${1:-} "* ]]
}

# ai_engine_primary [preferred] — <preferred> when it is enabled, otherwise the
# first engine in the chain. Pass the legacy REVIEW_ENGINE / DEV_LEAD_ENGINE.
# An INVALID AI_ENGINES value means full defaults, primary included: the
# workflows derive REVIEW_ENGINE / DEV_LEAD_ENGINE from the raw value's first
# token, so honouring <preferred> there would let "copilot,typo" still make
# Copilot primary (#1961 review).
ai_engine_primary() {
  local pref chain spec
  pref="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  chain="$(ai_engine_chain)"
  spec="$(_ai_engine_spec)"
  if [[ -n "${spec//[[:space:],]/}" ]] && ! _ai_engine_narrowed "$spec" >/dev/null; then
    pref=""
  fi
  if [[ -n "$pref" ]] && [[ " $chain " == *" $pref "* ]]; then
    printf '%s' "$pref"
  else
    printf '%s' "${chain%% *}"
  fi
}

# ai_engine_available <engine> — 0 when <engine> is enabled, the pre-flight
# probe (validate_engines) has not marked it unavailable, and review-batch.sh
# has not recorded it in AI_ENGINES_RATE_LIMITED (engines that hit a rate limit
# earlier in the batch; exported so child processes such as the rubber-duck
# selection in review-one-pr.sh skip them too). A flag that was never set
# counts as available, so callers outside a probed run keep working.
ai_engine_available() {
  local flag
  case "${1:-}" in
    claude)  flag="${CLAUDE_AVAILABLE:-}" ;;
    gemini)  flag="${GEMINI_AVAILABLE:-}" ;;
    copilot) flag="${COPILOT_AVAILABLE:-}" ;;
    *) return 1 ;;
  esac
  ai_engine_enabled "$1" || return 1
  [[ " ${AI_ENGINES_RATE_LIMITED:-} " != *" $1 "* ]] || return 1
  [[ "$flag" != "false" ]]
}

# ai_engine_next_available <current> — the first available engine AFTER
# <current> in the chain (forward only, so a rate-limit walk cannot cycle).
# When <current> is not in the chain, searches the whole chain. Prints nothing
# when there is none.
ai_engine_next_available() {
  local current="${1:-}" chain e seen=0
  chain="$(ai_engine_chain)"
  [[ " $chain " == *" $current "* ]] || seen=1
  for e in $chain; do
    if [ "$seen" -eq 0 ]; then
      [[ "$e" = "$current" ]] && seen=1
      continue
    fi
    if ai_engine_available "$e"; then
      printf '%s' "$e"
      return 0
    fi
  done
}

# ai_engine_first_available — the first available engine in the chain.
ai_engine_first_available() {
  local e
  for e in $(ai_engine_chain); do
    if ai_engine_available "$e"; then
      printf '%s' "$e"
      return 0
    fi
  done
}

# ai_engine_label <engine> — display name for log lines (Claude, Gemini, Copilot).
ai_engine_label() {
  case "${1:-}" in
    claude) printf 'Claude' ;;
    gemini) printf 'Gemini' ;;
    copilot) printf 'Copilot' ;;
    *) printf '%s' "${1:-}" ;;
  esac
}
