#!/usr/bin/env bats
# Tests for scripts/validate-ai-engines.py, the CI gate on config/ai-engines.json
# (#2631, part 1 of #1973). The validator checks the file against
# config/ai-engines.schema.json (jsonschema, draft 2020-12) and then fails when:
#   - a task names a model missing from `models`, or marked `retired`;
#   - a model sits in another provider's chain;
#   - an enabled provider's model has no price row in scripts/lib/model-pricing.tsv;
#   - `duck`, `fable` or a Copilot chain lists more than one model.
#
# Each failing case starts from the committed file and changes one thing, and
# asserts the message for that rule, so a case cannot pass on an unrelated error.
#
# Run with: bats tests/test_validate_ai_engines.bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  VALIDATOR="$ROOT/scripts/validate-ai-engines.py"
  CONFIG="$ROOT/config/ai-engines.json"
  PRICING="$ROOT/scripts/lib/model-pricing.tsv"
  FIXTURE="$BATS_TEST_TMPDIR/ai-engines.json"
}

# _mutate <jq filter> — write the committed file, changed by <filter>, to $FIXTURE.
_mutate() {
  jq "$1" "$CONFIG" > "$FIXTURE"
}

# _validate [args…] — run the validator on $FIXTURE (or the args given).
_validate() {
  run python3 "$VALIDATOR" --config "$FIXTURE" "$@"
}

@test "the committed file passes" {
  run python3 "$VALIDATOR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ai-engines OK"* ]]
}

@test "an unchanged copy passes with explicit paths" {
  cp "$CONFIG" "$FIXTURE"
  _validate --schema "$ROOT/config/ai-engines.schema.json" --pricing "$PRICING"
  [ "$status" -eq 0 ]
}

# ── Schema ────────────────────────────────────────────────────────────────────

@test "malformed JSON fails" {
  printf '{"models": ' > "$FIXTURE"
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"not valid JSON"* ]]
}

@test "a missing file fails" {
  run python3 "$VALIDATOR" --config "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read"* ]]
}

@test "schema: an unknown status fails" {
  _mutate '.models["claude-opus-4-7"].status = "deprecated"'
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema"* ]]
}

@test "schema: a missing task fails" {
  _mutate 'del(.tasks.audit)'
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema"* ]]
  [[ "$output" == *"audit"* ]]
}

@test "schema: an unknown provider in a chain fails" {
  _mutate '.tasks.deep.openai = ["openai/o4-mini"]'
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema"* ]]
}

@test "schema: fable takes only a claude chain" {
  _mutate '.tasks.fable.gemini = ["gemini-3.8-flash"]'
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema"* ]]
}

@test "schema: an optional prefer list is accepted" {
  _mutate '.tasks.deep.prefer = ["gemini", "claude"]'
  _validate
  [ "$status" -eq 0 ]
}

# ── Model references ──────────────────────────────────────────────────────────

@test "a task naming a model missing from models fails" {
  _mutate '.tasks.deep.claude = ["claude-opus-9-9", "claude-opus-4-8"]'
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"tasks.deep.claude"* ]]
  [[ "$output" == *"claude-opus-9-9"* ]]
  [[ "$output" == *"not in models"* ]]
}

@test "a task naming a retired model fails" {
  _mutate '.models["claude-opus-4-7"].status = "retired"'
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"tasks.audit.claude"* ]]
  [[ "$output" == *"claude-opus-4-7"* ]]
  [[ "$output" == *"retired"* ]]
}

@test "a retired model that no task names passes" {
  [ "$(jq -r '.models["claude-fable-5"].status' "$CONFIG")" = "retired" ]
  cp "$CONFIG" "$FIXTURE"
  _validate
  [ "$status" -eq 0 ]
}

@test "a preview model in a chain passes" {
  [ "$(jq -r '.models["gemini-3.1-pro-preview"].status' "$CONFIG")" = "preview" ]
  cp "$CONFIG" "$FIXTURE"
  _validate
  [ "$status" -eq 0 ]
}

@test "a model in another provider's chain fails" {
  _mutate '.tasks.deep.gemini = ["claude-opus-5-5"]'
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"tasks.deep.gemini"* ]]
  [[ "$output" == *"claude-opus-5-5"* ]]
  [[ "$output" == *"provider claude"* ]]
}

# ── Price rows ────────────────────────────────────────────────────────────────

@test "an enabled provider's model with no price row fails" {
  grep -v '^o4-mini' "$PRICING" > "$BATS_TEST_TMPDIR/pricing.tsv"
  cp "$CONFIG" "$FIXTURE"
  _validate --pricing "$BATS_TEST_TMPDIR/pricing.tsv"
  [ "$status" -ne 0 ]
  [[ "$output" == *"openai/o4-mini"* ]]
  [[ "$output" == *"no price row"* ]]
}

@test "a price row that starts in the future does not count" {
  grep -v '^o4-mini' "$PRICING" > "$BATS_TEST_TMPDIR/pricing.tsv"
  printf 'o4-mini*\t2999-01-01\t2.00\t0.50\t2.00\t8.00\n' >> "$BATS_TEST_TMPDIR/pricing.tsv"
  cp "$CONFIG" "$FIXTURE"
  _validate --pricing "$BATS_TEST_TMPDIR/pricing.tsv"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no price row"* ]]
}

@test "a disabled provider's model needs no price row" {
  grep -v '^o4-mini' "$PRICING" > "$BATS_TEST_TMPDIR/pricing.tsv"
  _mutate '.providers.copilot.enabled = false'
  _validate --pricing "$BATS_TEST_TMPDIR/pricing.tsv"
  [ "$status" -eq 0 ]
}

@test "a vendor-prefixed price row does not count: rows match the id without its prefix" {
  # engine.sh records openai/o4-mini as o4-mini, and price_for matches that, so
  # only an o4-mini* row prices it; an openai/o4-mini* row never would.
  grep -v '^o4-mini' "$PRICING" > "$BATS_TEST_TMPDIR/pricing.tsv"
  printf 'openai/o4-mini*\t2025-01-01\t2.00\t0.50\t2.00\t8.00\n' >> "$BATS_TEST_TMPDIR/pricing.tsv"
  cp "$CONFIG" "$FIXTURE"
  _validate --pricing "$BATS_TEST_TMPDIR/pricing.tsv"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no price row"* ]]
}

# ── Single-model chains ───────────────────────────────────────────────────────

@test "a multi-model duck chain fails" {
  _mutate '.tasks.duck.claude = ["claude-sonnet-5-5", "claude-sonnet-5"]'
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"tasks.duck.claude"* ]]
  [[ "$output" == *"one model"* ]]
}

@test "a multi-model fable chain fails" {
  _mutate '.tasks.fable.claude = ["claude-fable-5-2", "claude-opus-5-5"]'
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"tasks.fable.claude"* ]]
  [[ "$output" == *"one model"* ]]
}

@test "a multi-model copilot chain fails" {
  _mutate '.models["openai/o4-mini-high"] = {"provider": "copilot", "status": "active"}
           | .tasks.deep.copilot = ["openai/o4-mini", "openai/o4-mini-high"]'
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"tasks.deep.copilot"* ]]
  [[ "$output" == *"one model"* ]]
}

@test "every failure is reported, not just the first" {
  _mutate '.tasks.deep.gemini = ["claude-opus-5-5"] | .tasks.duck.claude = ["claude-sonnet-5-5", "claude-sonnet-5"]'
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"tasks.deep.gemini"* ]]
  [[ "$output" == *"tasks.duck.claude"* ]]
}

# ── Availability and required chains ─────────────────────────────────────────

@test "a configuration with no enabled provider fails" {
  _mutate '.providers.claude.enabled = false | .providers.gemini.enabled = false | .providers.copilot.enabled = false'
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"no provider is enabled"* ]]
}

@test "an enabled provider missing a required task chain fails" {
  _mutate 'del(.tasks.audit.gemini)'
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"tasks.audit.gemini: missing chain"* ]]
}

@test "a disabled provider may lack its task chains" {
  _mutate '.providers.copilot.enabled = false | del(.tasks.audit.copilot)'
  _validate
  [ "$status" -eq 0 ]
}

@test "a gemini duck chain fails: duck is Claude-only" {
  _mutate '.tasks.duck.gemini = ["gemini-3.8-flash"]'
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"tasks.duck.gemini"* ]]
  [[ "$output" == *"Claude-only"* ]]
}

@test "a task holding only prefer fails the schema" {
  _mutate '.tasks.triage = {"prefer": ["claude"]}'
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema: tasks.triage"* ]]
}

@test "a retired model needs no price row" {
  grep -vF 'claude-fable-5*'$'\t' "$PRICING" > "$BATS_TEST_TMPDIR/pricing.tsv"
  cp "$CONFIG" "$FIXTURE"
  _validate --pricing "$BATS_TEST_TMPDIR/pricing.tsv"
  [ "$status" -eq 0 ]
}

@test "a null config file reports an error" {
  printf 'null' > "$FIXTURE"
  _validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}
