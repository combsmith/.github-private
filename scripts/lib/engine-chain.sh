# shellcheck shell=bash
# scripts/lib/engine-chain.sh — the configured AI engine chain (AI_ENGINES).
#
# config/ai-engines.json (#1973) enables providers and sets the default order
# (providers.fallback_order). One org/repo Actions variable, AI_ENGINES, is the
# kill switch on top of it: it turns engines off and reorders them with no
# release, but it cannot turn on a provider the file disables:
#
#   AI_ENGINES="claude,gemini,copilot"   the default (the file's order)
#   AI_ENGINES="claude,gemini"           Copilot off (never tried, not even as a fallback)
#   AI_ENGINES="gemini,claude"           Gemini first, Claude as the fallback
#   AI_ENGINES="claude"                  Claude only
#
#   - membership = enabled. An engine that is not listed is never used, nor is
#                  one the file disables (reported by ai_engine_chain_problem).
#   - order      = fallback preference, walked left to right on a rate limit.
#   - first      = the primary engine, unless REVIEW_ENGINE / DEV_LEAD_ENGINE is
#                  set explicitly (a legacy override; it is ignored, with a
#                  warning, when it names an engine AI_ENGINES leaves out).
#
# Comma- or space-separated, case-insensitive. DEV_LEAD_ENGINES (#1546) is the
# legacy name and is read only when AI_ENGINES is unset. An unknown token (a
# typo such as "cluade") invalidates the WHOLE value and the default chain is
# used, so a typo can never silently drop fallbacks; ai_engine_chain_problem
# reports it so validate_engines can warn once.
#
# Sourced by engine.sh, validate-engines.sh and review-batch.sh. Defines
# functions only; at source time it only sources engine-models.sh (the file
# reader) when present, and does not call `set`.

# The built-in order, used only when engine-models.sh is not next to this lib
# (or the file cannot be read; engine.sh fails the step on that first).
AI_ENGINES_DEFAULT="claude gemini copilot"

if ! declare -F ai_engines_file_providers >/dev/null 2>&1 \
   && [ -f "$(dirname "${BASH_SOURCE[0]}")/engine-models.sh" ]; then
  # shellcheck source=scripts/lib/engine-models.sh
  source "$(dirname "${BASH_SOURCE[0]}")/engine-models.sh"
fi

# _ai_engine_default_chain — the file's enabled providers in fallback_order.
# AI_ENGINES_DEFAULT is used only when engine-models.sh is not available; if
# the file cannot be read when the lib is available, fails closed (returns 1)
# so callers never silently re-enable providers the file disables.
_ai_engine_default_chain() {
  local c
  if declare -F ai_engines_file_providers >/dev/null 2>&1; then
    # The function exists (engine-models.sh was sourced); must succeed.
    c="$(ai_engines_file_providers)" || return 1
    printf '%s' "$c"
    return 0
  fi
  # Function not available; use the built-in default.
  printf '%s' "$AI_ENGINES_DEFAULT"
}

# _ai_engine_file_disabled — the providers the file disables (space-separated).
# Returns 1 when the file cannot be read (if engine-models.sh was sourced).
_ai_engine_file_disabled() {
  declare -F ai_engines_file_disabled >/dev/null 2>&1 || return 0
  ai_engines_file_disabled
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

# ai_engine_chain — the enabled engines in preference order, space-separated.
# Engines the file disables are dropped. Empty or invalid configuration → the
# default chain. A valid configuration that names only disabled engines → empty
# (fails closed rather than silently re-enabling providers the spec excluded).
# Returns 1 if the config file cannot be read (when engine-models.sh is sourced).
ai_engine_chain() {
  local spec parsed disabled e kept="" chain
  spec="$(_ai_engine_spec)"
  if [ -z "$spec" ]; then
    chain="$(_ai_engine_default_chain)" || return 1
    printf '%s' "$chain"
    return 0
  fi
  if parsed="$(_ai_engine_parse "$spec")" && [ -n "$parsed" ]; then
    disabled="$(_ai_engine_file_disabled)" || return 1
    for e in $parsed; do
      [[ " $disabled " == *" $e "* ]] || kept="${kept:+$kept }$e"
    done
  fi
  if [ -z "$kept" ] && [ -z "${spec//[[:space:],]/}" ]; then
    chain="$(_ai_engine_default_chain)" || return 1
    printf '%s' "$chain"
  elif [ -z "$kept" ] && ! _ai_engine_parse "$spec" >/dev/null 2>&1; then
    chain="$(_ai_engine_default_chain)" || return 1
    printf '%s' "$chain"
  else
    printf '%s' "$kept"
  fi
}

# ai_engine_chain_problem — prints a one-line description when the configured
# value is unusable (unknown engine, nothing but separators, or an engine the
# file disables); prints nothing when it is fine or unset. Returns 1 if the
# config file cannot be read (when engine-models.sh is sourced).
ai_engine_chain_problem() {
  local spec parsed disabled e off="" chain
  spec="$(_ai_engine_spec)"
  [ -n "$spec" ] || return 0
  if [ -z "${spec//[[:space:],]/}" ]; then
    chain="$(_ai_engine_default_chain)" || return 1
    printf "AI_ENGINES='%s' lists no engine — using the default chain '%s'" \
      "$spec" "$chain"
    return 0
  elif ! parsed="$(_ai_engine_parse "$spec")" || [ -z "$parsed" ]; then
    chain="$(_ai_engine_default_chain)" || return 1
    printf "AI_ENGINES='%s' names an unknown engine (expected claude, gemini, copilot) — using the default chain '%s'" \
      "$spec" "$chain"
    return 0
  fi
  disabled="$(_ai_engine_file_disabled)" || return 1
  for e in $parsed; do
    [[ " $disabled " != *" $e "* ]] || off="${off:+$off, }$e"
  done
  if [ -n "$off" ]; then
    # AI_ENGINES narrows the file; it cannot turn a provider back on.
    chain="$(ai_engine_chain)" || return 1
    printf "AI_ENGINES='%s' names %s, which config/ai-engines.json has disabled — ignored (enable a provider in the file, not with AI_ENGINES); using '%s'" \
      "$spec" "$off" "$chain"
  elif [[ "$spec" =~ ^[[:space:],] ]]; then
    # The workflows derive the primary with startsWith(vars.AI_ENGINES, …),
    # which cannot skip leading separators.
    printf "AI_ENGINES='%s' starts with a space or comma — the workflows read the primary engine from the start of the value, so start it with an engine name" \
      "$spec"
  fi
}

# ai_engine_enabled <engine> — 0 when <engine> is in the configured chain.
# Returns 1 if the config file cannot be read (when engine-models.sh is sourced).
ai_engine_enabled() {
  local chain
  chain="$(ai_engine_chain)" || return 1
  [[ " $chain " == *" ${1:-} "* ]]
}

# ai_engine_primary [preferred] — <preferred> when it is enabled, otherwise the
# first engine in the chain. Pass the legacy REVIEW_ENGINE / DEV_LEAD_ENGINE.
# An INVALID AI_ENGINES value means full defaults, primary included: the
# workflows derive REVIEW_ENGINE / DEV_LEAD_ENGINE from the raw value's first
# token, so honouring <preferred> there would let "copilot,typo" still make
# Copilot primary (#1961 review). Returns 1 if the config file cannot be read.
ai_engine_primary() {
  local pref chain spec
  pref="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  chain="$(ai_engine_chain)" || return 1
  spec="$(_ai_engine_spec)"
  if [ -n "${spec//[[:space:],]/}" ] && ! _ai_engine_parse "$spec" >/dev/null; then
    pref=""
  fi
  if [ -n "$pref" ] && [[ " $chain " == *" $pref "* ]]; then
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
  [ "$flag" != "false" ]
}

# ai_engine_next_available <current> — the first available engine AFTER
# <current> in the chain (forward only, so a rate-limit walk cannot cycle).
# When <current> is not in the chain, searches the whole chain. Prints nothing
# when there is none. Returns 1 if the config file cannot be read.
ai_engine_next_available() {
  local current="${1:-}" chain e seen=0
  chain="$(ai_engine_chain)" || return 1
  [[ " $chain " == *" $current "* ]] || seen=1
  for e in $chain; do
    if [ "$seen" -eq 0 ]; then
      [ "$e" = "$current" ] && seen=1
      continue
    fi
    if ai_engine_available "$e"; then
      printf '%s' "$e"
      return 0
    fi
  done
}

# ai_engine_first_available — the first available engine in the chain.
# Returns 1 if the config file cannot be read (when engine-models.sh is sourced).
ai_engine_first_available() {
  local e chain
  chain="$(ai_engine_chain)" || return 1
  for e in $chain; do
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
