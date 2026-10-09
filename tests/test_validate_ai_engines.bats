#!/usr/bin/env bats
# scripts/validate-ai-engines.py (#1973): the lint.yml gate on
# config/ai-engines.json — JSON Schema (draft 2020-12) plus the checks a schema
# cannot express: every task model is in the catalog, not retired and of the
# chain's provider; every model of an enabled provider has a price row; duck and
# Copilot chains hold one model.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/validate-ai-engines.py"
CONFIG="$REPO_ROOT/config/ai-engines.json"

# Writes the repo config with <jq-filter> applied and runs the validator on it.
_validate_with() {
  local f="$BATS_TEST_TMPDIR/ai-engines.json"
  jq "$1" "$CONFIG" > "$f"
  run python3 "$VALIDATOR" "$f"
}

@test "the repo's config/ai-engines.json passes" {
  run python3 "$VALIDATOR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "schema: a missing section fails" {
  _validate_with 'del(.tasks)'
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "schema: an unknown status fails" {
  _validate_with '.models["claude-opus-4-8"].status = "deprecated"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "schema: an unknown task fails; tasks.<task>.prefer is allowed" {
  _validate_with '.tasks.review = {"claude": ["claude-opus-4-8"]}'
  [ "$status" -ne 0 ]
  _validate_with '.tasks.deep.prefer = ["gemini", "claude"]'
  [ "$status" -eq 0 ]
}

@test "malformed JSON fails" {
  printf '{"models": ' > "$BATS_TEST_TMPDIR/bad.json"
  run python3 "$VALIDATOR" "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "gate: a task naming a retired model fails" {
  _validate_with '.tasks.deep.gemini = ["gemini-2.5-pro", "gemini-3.8-flash"]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"gemini-2.5-pro"*"retired"* ]]
}

@test "gate: a task naming a model missing from the catalog fails" {
  _validate_with '.tasks.audit.claude = ["claude-opus-9-9"]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude-opus-9-9"*"not in models"* ]]
}

@test "gate: a model in another provider's chain fails" {
  _validate_with '.tasks.triage.gemini = ["claude-sonnet-5-5"]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude-sonnet-5-5"*"provider claude"* ]]
}

@test "gate: an enabled provider's model without a price row fails" {
  _validate_with '.models["mistral-large"] = {"provider": "copilot", "status": "active"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"mistral-large"*"model-pricing.tsv"* ]]
  # A disabled provider's models need no price row.
  _validate_with '.models["mistral-large"] = {"provider": "copilot", "status": "active"} | .providers.copilot.enabled = false'
  [ "$status" -eq 0 ]
}

@test "gate: a vendor-prefixed Copilot id is priced by its bare name" {
  # No row matches "azure/o4-mini" itself; the bare "o4-mini" matches o4-mini*.
  _validate_with '.models["azure/o4-mini"] = {"provider": "copilot", "status": "active"}'
  [ "$status" -eq 0 ]
}

@test "gate: duck with more than one model fails" {
  _validate_with '.tasks.duck.claude = ["claude-sonnet-5-5", "claude-sonnet-5"]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"duck"*"one model"* ]]
}

@test "gate: a Copilot chain with more than one model fails" {
  _validate_with '.models["openai/gpt-5"] = {"provider": "copilot", "status": "active"} | .tasks.deep.copilot = ["openai/o4-mini", "openai/gpt-5"]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"copilot"*"one model"* ]]
}

@test "gate: fallback_order must name each provider once" {
  _validate_with '.providers.fallback_order = ["claude", "claude", "gemini"]'
  [ "$status" -ne 0 ]
}

@test "gate: every problem is reported, not only the first" {
  _validate_with '.tasks.audit.claude = ["claude-opus-9-9"] | .tasks.duck.claude = ["claude-sonnet-5-5", "claude-sonnet-5"]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude-opus-9-9"* ]]
  [[ "$output" == *"duck"* ]]
}

@test "lint.yml runs the gate" {
  grep -q 'python3 scripts/validate-ai-engines.py' "$REPO_ROOT/.github/workflows/lint.yml"
}
