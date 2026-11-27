#!/usr/bin/env bats
# config/ai-engines.json and the libs that read it must agree on its shape
# (#2631 and #2630, parts 1 and 2 of #1973).
#
# Part 1 added the file while scripts/lib/engine-models.sh still answered from a
# built-in table, and this suite then kept the two equal. Part 2 (#2630) removed
# the table: ai_models_default now reads the file, so that equality check is gone
# (tests/dev-lead/unit/test_engine_models.bats, unchanged, proves the defaults
# did not move, and tests/dev-lead/unit/test_ai_engines_config.bats covers the
# reader). What stays here is what the reader cannot catch on its own: a chain
# the file sets under a (task, provider) the lib never asks for would be silently
# unused.
#
# Run with: bats tests/test_ai_engines_parity.bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CONFIG="$ROOT/config/ai-engines.json"
  # The checks read the file's chains, not the overrides; unset them anyway so
  # a runner's own values cannot leak in.
  unset AI_MODELS_CLAUDE AI_MODELS_GEMINI AI_MODELS_COPILOT AI_ENGINES DEV_LEAD_ENGINES
  # shellcheck source=../scripts/lib/engine-models.sh
  source "$ROOT/scripts/lib/engine-models.sh"
}

# _file_chain <task> <provider> — the file's chain, comma-joined ("" when absent).
_file_chain() {
  jq -r --arg t "$1" --arg p "$2" '(.tasks[$t][$p] // []) | join(",")' "$CONFIG"
}

@test "the config file exists and is valid JSON" {
  [ -f "$CONFIG" ]
  jq -e . "$CONFIG" >/dev/null
}

@test "the file has no chain the lib does not know" {
  # Each (task, provider) the file names must be a key the lib accepts for that
  # provider and resolve through ai_models_default, or the chain is never used.
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

@test "the fable family key keeps claude-fable-5-2" {
  [ "$(_file_chain fable claude)" = "claude-fable-5-2" ]
  [ "$(jq -r '.models["claude-fable-5-2"].status' "$CONFIG")" = "active" ]
}
