#!/usr/bin/env bats
# config/ai-engines.json must say what the libs say (#2631, part 1 of #1973).
#
# Nothing reads the file yet: scripts/lib/engine-models.sh still answers from its
# built-in table (ai_models_default) and scripts/lib/engine-chain.sh from
# AI_ENGINES_DEFAULT. Until part 2 (#2630) switches the lib over to the file,
# this suite keeps the two from drifting: a default changed in one place and not
# the other fails here.
#
# Run with: bats tests/test_ai_engines_parity.bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CONFIG="$ROOT/config/ai-engines.json"
  # The lib's defaults read no environment, but its key list does not either;
  # unset the overrides anyway so a runner's own values cannot leak in.
  unset AI_MODELS_CLAUDE AI_MODELS_GEMINI AI_MODELS_COPILOT AI_ENGINES DEV_LEAD_ENGINES
  # shellcheck source=../scripts/lib/engine-models.sh
  source "$ROOT/scripts/lib/engine-models.sh"
  # shellcheck source=../scripts/lib/engine-chain.sh
  source "$ROOT/scripts/lib/engine-chain.sh"
}

# _file_chain <task> <provider> — the file's chain, comma-joined ("" when absent).
_file_chain() {
  jq -r --arg t "$1" --arg p "$2" '(.tasks[$t][$p] // []) | join(",")' "$CONFIG"
}

@test "the config file exists and is valid JSON" {
  [ -f "$CONFIG" ]
  jq -e . "$CONFIG" >/dev/null
}

@test "every task chain of every provider equals ai_models_default" {
  local p k want got bad=""
  for p in claude gemini copilot; do
    for k in $(_ai_models_keys "$p"); do
      want="$(ai_models_default "$p" "$k")"
      got="$(_file_chain "$k" "$p")"
      if [ "$want" != "$got" ]; then
        bad="$bad"$'\n'"  $p/$k: lib='$want' file='$got'"
      fi
    done
  done
  if [ -n "$bad" ]; then
    echo "config/ai-engines.json differs from ai_models_default:$bad"
    return 1
  fi
}

@test "the file has no chain the lib does not know" {
  # Each (task, provider) the file names must be a key the lib accepts for that
  # provider and have a lib default, or part 2 would add a default silently.
  local pairs t p bad=""
  pairs="$(jq -r '.tasks | to_entries[] | .key as $t | .value | keys[] | select(. != "prefer") | "\($t) \(.)"' "$CONFIG")"
  [ -n "$pairs" ]
  while read -r t p; do
    if [[ " $(_ai_models_keys "$p") " != *" $t "* ]] || [ -z "$(ai_models_default "$p" "$t")" ]; then
      bad="$bad $p/$t"
    fi
  done <<< "$pairs"
  if [ -n "$bad" ]; then
    echo "chains with no lib default:$bad"
    return 1
  fi
}

@test "the fallback order equals AI_ENGINES_DEFAULT and every provider is enabled" {
  [ "$(jq -r '.providers.fallback_order | join(" ")' "$CONFIG")" = "$AI_ENGINES_DEFAULT" ]
  [ "$(jq -r '[.providers.claude.enabled, .providers.gemini.enabled, .providers.copilot.enabled] | all' "$CONFIG")" = "true" ]
}

@test "the fable family key keeps claude-fable-5-2" {
  [ "$(_file_chain fable claude)" = "claude-fable-5-2" ]
  [ "$(jq -r '.models["claude-fable-5-2"].status' "$CONFIG")" = "active" ]
}
