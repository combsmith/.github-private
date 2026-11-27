# shellcheck shell=bash
# scripts/lib/engine-models.sh — the model list of each provider.
#
# The defaults live in config/ai-engines.json (#1973), a versioned file that the
# validate-ai-engines job in lint.yml checks against config/ai-engines.schema.json.
# It ships with the code under the pr-review/* and dev-lead/* channel tags, so a
# default-model change canaries on `next` before `ring0` and `stable`. The file is
# read with jq, from the checkout that holds this lib (AI_ENGINES_CONFIG overrides
# the path, for tests). A missing, unreadable or malformed file is an ::error::
# and a non-zero return; there are no built-in defaults to fall back to.
#
# One Actions variable per provider is the break-glass override on top of the
# file: set it in an emergency, then land the change in the file through a
# normal release and delete the variable (the daily health check lists every
# override that differs from the file, ai_engines_overrides):
#
#   AI_MODELS_CLAUDE   triage=… ; deep=… ; audit=… ; action=… ; single=… ; duck=… ; fable=…
#   AI_MODELS_GEMINI   (the same keys)
#   AI_MODELS_COPILOT  (the same keys)
#
# Each entry is <key>=<model>[,<fallback>,…]. Entries are separated by ';' or
# newlines; spaces are ignored; keys are case-insensitive. A key that is left out
# keeps the file's chain (ai_models_default). Chains are walked left to right on
# a rate limit, before any cross-provider fallback (AI_ENGINES).
#
# Every provider takes the same keys, one per task:
#   triage  classify the PR            deep    agentic review
#   audit   security audit             action  dev-lead writer
#   single  single-reviewer mode
#   duck    the model used when this provider is the rubber duck (one model;
#           the file sets Claude's; Gemini and Copilot use their triage model)
# Claude also takes one family key, which no engine tier runs:
#   fable   the id `ai_model_for_family fable` returns (one model)
# Copilot takes one model per key: the GitHub Models client has no in-engine
# chain. A duck or fable key, or any Copilot key, given several models warns and
# keeps the first.
#
# Precedence per key, highest first:
#   1. the specific env vars kept for existing callers — INTERNAL (tests, the
#      model A/B runner) and deprecated for operators:
#        Claude   CLAUDE_<TIER>_MODEL_CHAIN (the whole chain);
#        Gemini   GEMINI_FLASH_MODEL_CHAIN (triage + action) and
#                 GEMINI_PRO_MODEL_CHAIN (deep + audit + single) replace the
#                 whole chain; GEMINI_FLASH_MODEL / GEMINI_PRO_MODEL replace
#                 only its first model;
#        Copilot  COPILOT_API_MODEL (every key);
#   2. AI_MODELS_<PROVIDER> (the break-glass override);
#   3. config/ai-engines.json (ai_models_default).
# An unknown key or a malformed model id drops that entry (the file's chain
# applies); ai_models_problems reports it so engine.sh can warn once.
#
# Sourced by engine.sh and engine-chain.sh. Defines functions and resolves the
# config path at source time; it reads the file only when asked.
#
# The model notes (the Sonnet 5 id history, why each chain has its fallbacks, the
# Fable deprecations) live next to each model in config/ai-engines.json.

_AI_ENGINES_CONFIG_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/config/ai-engines.json"

# ai_engines_config_path — the engine config file: AI_ENGINES_CONFIG when set,
# else config/ai-engines.json at the root of the checkout that holds this lib.
ai_engines_config_path() {
  printf '%s' "${AI_ENGINES_CONFIG:-$_AI_ENGINES_CONFIG_DEFAULT}"
}

# The file flattened to one line per fact, so a lookup is parameter expansion
# (Bash 3.2 has no associative arrays):
#   <provider>:<task>=<model>,<fallback>,…   one per chain the file sets
#   providers=<the enabled providers, in fallback_order>
#   disabled=<the providers the file disables>
# shellcheck disable=SC2016  # a jq program: $p and $t are jq variables
_AI_ENGINES_JQ='
  if type != "object" or (.tasks | type) != "object" or (.providers | type) != "object"
     or (.providers.fallback_order | type) != "array" then
    error("expected the tasks and providers sections (providers.fallback_order)")
  else . end
  | .providers as $p
  | ( .tasks | to_entries[] | select(.value | type == "object") | .key as $t
      | .value | to_entries[]
      | select(.key == "claude" or .key == "gemini" or .key == "copilot")
      | if (.value | type) != "array" or any(.value[]; type != "string") then
          error("tasks.\($t).\(.key) is not a list of model ids")
        else "\(.key):\($t)=\(.value | join(","))" end ),
    "providers=\([$p.fallback_order[] | select(type == "string") | select($p[.].enabled == true)] | join(" "))",
    "disabled=\([("claude", "gemini", "copilot") | select($p[.].enabled != true)] | join(" "))"
'

# _ai_engines_config_read <path> — prints the flattened table; prints an
# ::error:: on stderr and returns 1 when the file is missing, unreadable or
# malformed, or jq is not installed.
_ai_engines_config_read() {
  local path="$1" out why
  if [[ ! -f "$path" ]] || [[ ! -r "$path" ]]; then
    printf '::error::engine config %s is missing or unreadable. It holds the providers, models and task chains, and there are no built-in defaults to fall back to (docs/engine-configuration.md)\n' "$path" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '::error::engine config %s cannot be read: jq is not installed\n' "$path" >&2
    return 1
  fi
  if ! out="$(jq -r "$_AI_ENGINES_JQ" "$path" 2>/dev/null)"; then
    why="$(jq -r "$_AI_ENGINES_JQ" "$path" 2>&1 >/dev/null | head -n 1)"
    printf '::error::engine config %s is malformed (%s). Run python3 scripts/validate-ai-engines.py\n' "$path" "$why" >&2
    return 1
  fi
  printf '%s' "$out"
}

# ai_engines_config_load — reads the file once into this shell, so later lookups
# (and the $(…) subshells that inherit the table) skip jq. engine.sh calls it at
# source time and fails the step when it returns 1. A lookup after
# AI_ENGINES_CONFIG points elsewhere rereads.
ai_engines_config_load() {
  local path table
  path="$(ai_engines_config_path)"
  if [[ -n "${_AI_ENGINES_TABLE:-}" ]] && [[ "${_AI_ENGINES_TABLE_SRC:-}" = "$path" ]]; then
    return 0
  fi
  table="$(_ai_engines_config_read "$path")" || return 1
  _AI_ENGINES_TABLE="$table"
  _AI_ENGINES_TABLE_SRC="$path"
}

# _ai_engines_lookup <name> — the value of <name> in the table ("" when the file
# does not set it); returns 1, with an ::error::, when the file cannot be read.
_ai_engines_lookup() {
  local name="$1" path table rest nl=$'\n'
  path="$(ai_engines_config_path)"
  if [[ -n "${_AI_ENGINES_TABLE:-}" ]] && [[ "${_AI_ENGINES_TABLE_SRC:-}" = "$path" ]]; then
    table="$_AI_ENGINES_TABLE"
  else
    table="$(_ai_engines_config_read "$path")" || return 1
  fi
  table="$nl$table$nl"
  rest="${table#*"$nl$name="}"
  [[ "$rest" != "$table" ]] || return 0
  printf '%s' "${rest%%"$nl"*}"
}

# ai_models_default <provider> <key> — the file's chain for <provider>/<key>
# (tasks.<key>.<provider>), comma-joined. Empty when the file sets none, or the
# provider or key is unknown: Gemini and Copilot have no duck chain, their duck
# follows the triage model. Returns 1, with an ::error::, when the file cannot
# be read.
ai_models_default() {
  case "${1:-}" in claude|gemini|copilot) ;; *) return 0 ;; esac
  [[ " $(_ai_models_keys "$1") " == *" ${2:-} "* ]] || return 0
  _ai_engines_lookup "$1:$2"
}

# ai_engines_file_providers — the providers the file enables, in its
# fallback_order (space-separated). AI_ENGINES can only narrow this list.
ai_engines_file_providers() {
  _ai_engines_lookup providers
}

# ai_engines_file_disabled — the providers the file disables (space-separated).
ai_engines_file_disabled() {
  _ai_engines_lookup disabled
}

# _ai_models_keys <provider> — the keys AI_MODELS_<PROVIDER> accepts: the task
# keys every provider shares, plus Claude's `fable` family key.
_ai_models_keys() {
  case "${1:-}" in
    claude)         printf '%s' "triage deep audit action single duck fable" ;;
    gemini|copilot) printf '%s' "triage deep audit action single duck" ;;
  esac
}

# _ai_models_trim <text> — <text> without leading/trailing whitespace. Whitespace
# inside a model id is kept, so the id is then rejected rather than glued together.
_ai_models_trim() {
  local t="${1:-}"
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  printf '%s' "$t"
}

# _ai_models_var <provider> — the variable name, e.g. AI_MODELS_CLAUDE.
# (tr, not ${var^^}: scripts stay runnable on Bash 3.2, as engine-chain.sh is.)
_ai_models_var() {
  printf 'AI_MODELS_%s' "$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
}

# _ai_models_scan <provider> <mode> [key]
#   mode=get      prints the normalised chain for [key] ("" when not configured)
#   mode=problems prints one line per unusable entry
# The last entry for a key wins; when it is unusable, the default applies.
_ai_models_scan() {
  local provider="$1" mode="$2" want="${3:-}" var spec entry key value m chain found=""
  local -a entries=() models=()
  var="$(_ai_models_var "$provider")"
  spec="${!var:-}"
  [[ -n "${spec//[[:space:];]/}" ]] || return 0
  spec="${spec//$'\r'/;}"
  spec="${spec//$'\n'/;}"
  IFS=';' read -r -a entries <<< "$spec"
  for entry in ${entries[@]+"${entries[@]}"}; do
    entry="$(_ai_models_trim "$entry")"
    [[ -n "$entry" ]] || continue
    if [[ "$entry" != *=* ]]; then
      [[ "$mode" = problems ]] && printf "%s: '%s' is not <key>=<models> — ignored\n" "$var" "$entry"
      continue
    fi
    key="$(_ai_models_trim "${entry%%=*}" | tr '[:upper:]' '[:lower:]')"
    value="${entry#*=}"
    if [[ " $(_ai_models_keys "$provider") " != *" $key "* ]]; then
      [[ "$mode" = problems ]] && printf "%s: unknown key '%s' (expected: %s) — ignored\n" \
        "$var" "$key" "$(_ai_models_keys "$provider")"
      continue
    fi
    IFS=',' read -r -a models <<< "$value"
    chain=""
    for m in ${models[@]+"${models[@]}"}; do
      m="$(_ai_models_trim "$m")"
      [[ -n "$m" ]] || continue
      if [[ ! "$m" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ ]]; then
        chain=""
        [[ "$mode" = problems ]] && printf "%s: '%s' has an invalid model id '%s' — default used\n" "$var" "$key" "$m"
        break
      fi
      [[ ",$chain," == *",$m,"* ]] || chain="${chain:+$chain,}$m"
    done
    if [[ -z "$chain" ]]; then
      [[ "$mode" = problems ]] && [[ "$value" =~ ^[,[:space:]]*$ ]] && printf "%s: '%s' lists no model — default used\n" "$var" "$key"
      # The last entry for a key wins even when unusable: drop an earlier one so
      # the default applies, as the warning says.
      [[ "$key" = "$want" ]] && found=""
      continue
    fi
    if [[ "$chain" == *,* ]] && { [[ "$key" = duck ]] || [[ "$key" = fable ]] || [[ "$provider" = copilot ]]; }; then
      [[ "$mode" = problems ]] && printf "%s: '%s' takes one model — only '%s' is used\n" "$var" "$key" "${chain%%,*}"
      chain="${chain%%,*}"
    fi
    [[ "$key" = "$want" ]] && found="$chain"
  done
  [[ "$mode" = get ]] && printf '%s' "$found"
  return 0
}

# ai_models_configured <provider> <key> — the chain AI_MODELS_<PROVIDER> sets for
# <key>, or nothing when it is not configured (or unusable).
ai_models_configured() {
  _ai_models_scan "${1:-}" get "${2:-}"
}

# ai_models_chain <provider> <key> — the AI_MODELS_<PROVIDER> chain, else the
# file's. Returns 1, with an ::error::, when it needs the file and cannot read it.
ai_models_chain() {
  local c
  c="$(ai_models_configured "$1" "$2")"
  [[ -n "$c" ]] || c="$(ai_models_default "$1" "$2")" || return 1
  printf '%s' "$c"
}

# ai_models_replace_first <first> <chain> — <chain> with its first model replaced
# by <first> (the GEMINI_FLASH_MODEL / GEMINI_PRO_MODEL override: swap the primary,
# keep the rest of the chain as fallbacks, so a retired primary is not retried).
ai_models_replace_first() {
  local first="$1" chain="$2" out="$1" m
  local -a others=()
  IFS=',' read -r -a others <<< "$chain"
  for m in ${others[@]+"${others[@]:1}"}; do
    [[ -n "$m" ]] && [[ "$m" != "$first" ]] && out="$out,$m"
  done
  printf '%s' "$out"
}

# ai_models_gemini_chain <key> — the Gemini chain for <key>, resolved when it is
# used rather than stored, so a child shell that re-sources engine.sh gets the
# same answer. triage and action honour GEMINI_FLASH_MODEL_CHAIN /
# GEMINI_FLASH_MODEL; deep, audit and single honour GEMINI_PRO_MODEL_CHAIN /
# GEMINI_PRO_MODEL; duck is AI_MODELS_GEMINI duck=…, else the file's Gemini duck
# (none today), else the triage chain's first model. Returns 1 when it needs the
# engine config and cannot read it.
ai_models_gemini_chain() {
  local key="${1:-}" group first c
  case "$key" in
    triage|action)      group="${GEMINI_FLASH_MODEL_CHAIN:-}"; first="${GEMINI_FLASH_MODEL:-}" ;;
    deep|audit|single)  group="${GEMINI_PRO_MODEL_CHAIN:-}";   first="${GEMINI_PRO_MODEL:-}" ;;
    duck)
      c="$(ai_models_configured gemini duck)"
      [[ -n "$c" ]] || c="$(ai_models_default gemini duck)" || return 1
      [[ -n "$c" ]] || { c="$(ai_models_gemini_chain triage)" || return 1; c="${c%%,*}"; }
      printf '%s' "$c"
      return 0 ;;
    *) return 0 ;;
  esac
  if [[ -n "${group//[[:space:],]/}" ]]; then
    printf '%s' "${group//[[:space:]]/}"
    return 0
  fi
  c="$(ai_models_chain gemini "$key")" || return 1
  first="${first//[[:space:]]/}"
  [[ -z "$first" ]] || c="$(ai_models_replace_first "$first" "$c")"
  printf '%s' "$c"
}

# ai_models_copilot_model <key> — the one GitHub Models id Copilot uses for
# <key>: COPILOT_API_MODEL when the caller set it (every key), else
# AI_MODELS_COPILOT, else the file; duck falls back to the triage model. Returns
# 1 when it needs the engine config and cannot read it.
# engine.sh defaults COPILOT_API_MODEL to the triage model and records that
# default in COPILOT_API_MODEL_DEFAULTED, so a value it set itself (inherited by
# a child shell) is not mistaken for the caller's.
ai_models_copilot_model() {
  local key="${1:-}" m=""
  if [[ -n "${COPILOT_API_MODEL:-}" ]] && [[ "$COPILOT_API_MODEL" != "${COPILOT_API_MODEL_DEFAULTED:-}" ]]; then
    m="$COPILOT_API_MODEL"
  else
    m="$(ai_models_configured copilot "$key")"
    [[ -n "$m" ]] || [[ "$key" != duck ]] || m="$(ai_models_default copilot duck)" || return 1
    [[ -n "$m" ]] || [[ "$key" != duck ]] || key=triage
    [[ -n "$m" ]] || m="$(ai_models_chain copilot "$key")" || return 1
  fi
  m="${m%%,*}"
  printf '%s' "${m//[[:space:]]/}"
}

# ai_models_problems — one line per unusable AI_MODELS_* entry, all providers.
ai_models_problems() {
  local p
  for p in claude gemini copilot; do
    _ai_models_scan "$p" problems
  done
}

# ai_engines_overrides — one line per break-glass override that is set and
# differs from config/ai-engines.json, so the daily health check lists it until
# it is folded back into the file:
#   AI_MODELS_<PROVIDER> <key>=<chain> (file: <file chain>)
#   AI_ENGINES=<value> → <chain that runs> (file: <file chain>)[ — <problem>]
# A Gemini or Copilot duck has no file chain; it is compared with the triage
# model it follows. AI_ENGINES (else the legacy DEV_LEAD_ENGINES) is compared
# after the parsing engine-chain.sh applies, so "Claude, Gemini, Copilot" equals
# the file's order and is not listed. An unusable AI_MODELS_* entry is not
# listed here (ai_models_problems reports it). Prints nothing when no override
# differs; returns 1, with an ::error::, when the file cannot be read.
ai_engines_overrides() {
  local p k var c d spec chain file problem
  # Read the file first, so an unreadable one is an error even with no override set.
  ai_engines_config_load || return 1
  for p in claude gemini copilot; do
    var="$(_ai_models_var "$p")"
    for k in $(_ai_models_keys "$p"); do
      c="$(ai_models_configured "$p" "$k")"
      [[ -n "$c" ]] || continue
      d="$(ai_models_default "$p" "$k")" || return 1
      if [[ -z "$d" ]] && [[ "$k" = duck ]]; then
        d="$(ai_models_default "$p" triage)" || return 1
        d="${d%%,*}"
      fi
      [[ "$c" = "$d" ]] || printf '%s %s=%s (file: %s)\n' "$var" "$k" "$c" "${d:-none}"
    done
  done
  spec="${AI_ENGINES:-${DEV_LEAD_ENGINES:-}}"
  [[ -n "$spec" ]] || return 0
  # Reuse the runtime parser, so the chain reported is the one that runs.
  if ! declare -F ai_engine_chain >/dev/null 2>&1; then
    # shellcheck source=scripts/lib/engine-chain.sh
    source "$(dirname "${BASH_SOURCE[0]}")/engine-chain.sh"
  fi
  file="$(ai_engines_file_providers)" || return 1
  chain="$(ai_engine_chain)"
  problem="$(ai_engine_chain_problem)"
  if [[ "$chain" != "$file" ]] || [[ -n "$problem" ]]; then
    printf 'AI_ENGINES=%s → %s (file: %s)%s\n' "$spec" "$chain" "$file" "${problem:+ — $problem}"
  fi
}

# ai_models_fable_deprecation — one deprecation line when a *configured* Claude
# chain still names a retired Fable (claude-fable-5 or claude-fable-5-1), else
# nothing. Fable 5 was deprecated in #1901 (audit/single moved to opus-5-5) and
# Fable 5.1 is superseded by Fable 5.2, the preferred Fable; a chain naming
# claude-fable-5-2 does not warn. Both match only as a whole id: the bare id, its
# -YYYYMMDD snapshot, or either with a [...] context suffix (never a prefix, so
# 5-2 and 5-10 … 5-19 do not warn). A configured old Fable is still HONOURED as a
# stop-gap (this warns, it does not reject), so an operator can pin it while
# migrating. Sources checked: the per-tier CLAUDE_<TIER>_MODEL_CHAIN envs (including
# CLAUDE_FABLE_MODEL_CHAIN) and AI_MODELS_CLAUDE.
ai_models_fable_deprecation() {
  local key env all=""
  # Per key, the chain that actually runs: a CLAUDE_<TIER>_MODEL_CHAIN env wins
  # (engine.sh only falls back to AI_MODELS_CLAUDE when it is empty), so a
  # superseded AI_MODELS_CLAUDE entry does not warn. AI_MODELS_CLAUDE goes through
  # the same parser that honours it, so an unknown key (ignored there) does not
  # warn and a padded id (trimmed there) does. duck has no env override.
  for key in $(_ai_models_keys claude); do
    # Static tier→var map (not printf|tr): pure parameter expansion. Bash 3.2-safe.
    case "$key" in
      triage) env="${CLAUDE_TRIAGE_MODEL_CHAIN:-}" ;;
      deep)   env="${CLAUDE_DEEP_MODEL_CHAIN:-}" ;;
      audit)  env="${CLAUDE_AUDIT_MODEL_CHAIN:-}" ;;
      action) env="${CLAUDE_ACTION_MODEL_CHAIN:-}" ;;
      single) env="${CLAUDE_SINGLE_MODEL_CHAIN:-}" ;;
      fable)  env="${CLAUDE_FABLE_MODEL_CHAIN:-}" ;;
      *)      env="" ;;
    esac
    if [ -n "$env" ]; then
      all="$all,$env"
    elif [ -n "${AI_MODELS_CLAUDE:-}" ]; then
      all="$all,$(ai_models_configured claude "$key")"
    fi
  done
  # One tr subshell to fold to lowercase (${var,,} is Bash 4+).
  all="$(printf '%s' "$all" | tr '[:upper:]' '[:lower:]')"
  local found="" d8='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
  # Whole-id matches only (#2518): Fable 5.1 is the bare id, its -YYYYMMDD
  # snapshot, or either with a [...] context suffix — never a prefix, so a
  # later claude-fable-5-10 … 5-19 does not warn. $d8 is unquoted to glob.
  case "${all//[[:space:]]/}," in
    *,claude-fable-5,*|*,claude-fable-5-$d8,*) found=1 ;;
    *,claude-fable-5-1,*|*,claude-fable-5-1-$d8,*) found=1 ;;
    *,claude-fable-5"["*"]",*|*,claude-fable-5-$d8"["*"]",*) found=1 ;;
    *,claude-fable-5-1"["*"]",*|*,claude-fable-5-1-$d8"["*"]",*) found=1 ;;
  esac
  [[ -n "$found" ]] || return 0
  printf '%s' "claude-fable-5 and claude-fable-5-1 are deprecated (#1901): audit/single default to claude-opus-5-5 (chain claude-opus-5-5,claude-opus-4-8,claude-opus-4-7), and claude-fable-5-2 is the preferred Fable. The configured model is still honoured as a stop-gap — repoint it to claude-opus-5-5, or to claude-fable-5-2 where Fable is wanted."
}

# ai_model_for_family <family> — the current concrete model id for a Claude model
# FAMILY (opus|sonnet|haiku|fable), so callers name a family and never pin a version
# (#1979, companion combsmith/.github#1199). The families map to the tiers
# whose primary is that family, and the id is that tier's chain FIRST model — the
# existing chains stay the single source of truth:
#     opus   → deep    (default primary claude-opus-5-5)
#     sonnet → action  (default primary claude-sonnet-5-5)
#     haiku  → triage  (default primary claude-haiku-4-5-20251001)
#     fable  → fable   (no engine tier; the AI_MODELS_CLAUDE `fable` key,
#                      default claude-fable-5-2)
# Overrides are honoured with the same precedence engine.sh uses: the per-tier
# CLAUDE_<TIER>_MODEL_CHAIN env first (ai_models_chain does not read it), then
# AI_MODELS_CLAUDE (via ai_models_chain), then config/ai-engines.json. An unknown
# family warns and returns non-zero; an unreadable engine config is an ::error::
# and a non-zero return. Bash 3.2-safe.
ai_model_for_family() {
  local family="${1:-}" tier var chain model
  case "$family" in
    opus)   tier=deep;   var=CLAUDE_DEEP_MODEL_CHAIN ;;
    sonnet) tier=action; var=CLAUDE_ACTION_MODEL_CHAIN ;;
    haiku)  tier=triage; var=CLAUDE_TRIAGE_MODEL_CHAIN ;;
    fable)  tier=fable;  var=CLAUDE_FABLE_MODEL_CHAIN ;;
    *)
      printf '::warning::ai_model_for_family: unknown family %s (expected opus|sonnet|haiku|fable)\n' "$family" >&2
      return 1 ;;
  esac
  chain="${!var:-}"
  # Only an EMPTY per-tier var counts as absent (engine.sh's ${VAR:-…} rule). A
  # set-but-malformed value (",") must not let AI_MODELS_CLAUDE win; it fails the
  # id check below and falls back to the file's chain.
  [[ -n "$chain" ]] || chain="$(ai_models_chain claude "$tier")" || return 1
  model="$(_ai_models_trim "${chain%%,*}")"
  # Validate the resolved id. ai_models_chain paths already validate via
  # _ai_models_scan, but the per-tier CLAUDE_<TIER>_MODEL_CHAIN override is read
  # raw above — a malformed value like "bad id" would otherwise reach the caller
  # and fail the Claude invocation. Fall back to the file's chain on a bad id.
  if [[ ! "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ ]]; then
    printf '::warning::ai_model_for_family: %s has an invalid model id %s — default used\n' "$var" "$model" >&2
    chain="$(ai_models_default claude "$tier")" || return 1
    model="$(_ai_models_trim "${chain%%,*}")"
  fi
  printf '%s' "${model//[[:space:]]/}"
}

# ai_model_label <model> — a short name for log lines:
#   claude-haiku-4-5-20251001 → haiku 4.5, claude-opus-5-5 → opus 5.5,
#   claude-sonnet-5 → sonnet 5, openai/o4-mini → o4-mini; others unchanged.
ai_model_label() {
  local m="${1:-}" family ver
  m="${m#*/}"
  case "$m" in
    claude-*)
      m="${m#claude-}"
      [[ "$m" =~ -[0-9]{8}$ ]] && m="${m%-*}"
      family="${m%%-*}"
      ver="${m#"$family"}"
      ver="${ver#-}"
      if [[ -n "$ver" ]]; then printf '%s %s' "$family" "${ver//-/.}"; else printf '%s' "$family"; fi
      ;;
    *) printf '%s' "$m" ;;
  esac
}

# ai_models_label_chain <chain> — "first [fallback, …]" for log lines.
ai_models_label_chain() {
  local chain="${1:-}" first fallbacks="" m
  local -a ms=()
  IFS=',' read -r -a ms <<< "$chain"
  first="$(ai_model_label "${ms[0]:-}")"
  for m in ${ms[@]+"${ms[@]:1}"}; do
    [[ -n "$m" ]] && fallbacks="${fallbacks:+$fallbacks, }$(ai_model_label "$m")"
  done
  if [[ -n "$fallbacks" ]]; then printf '%s [%s]' "$first" "$fallbacks"; else printf '%s' "$first"; fi
}
