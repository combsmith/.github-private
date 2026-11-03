#!/usr/bin/env bash
# tests/test_copilot_chat.sh
#
# Unit tests for the copilot_chat JSON payload builder in scripts/engine.sh.
# Verifies that the python3 JSON-encoding logic handles edge-case prompts
# without producing invalid JSON or triggering "Invalid command format" errors
# from the old gh copilot suggest invocation.
#
# Run:  bash tests/test_copilot_chat.sh
# Requires: python3, bash
#
# These tests are deliberately network-free: they test only the
# payload-building step (not the API call itself). The smoke test in
# review-batch.sh covers live API connectivity.

set -euo pipefail

PASS=0
FAIL=0
ERRORS=""

ok() {
  local name="$1"
  PASS=$((PASS + 1))
  printf 'PASS  %s\n' "$name"
}

fail() {
  local name="$1"
  local msg="$2"
  FAIL=$((FAIL + 1))
  ERRORS="${ERRORS}FAIL  ${name}: ${msg}\n"
  printf 'FAIL  %s: %s\n' "$name" "$msg"
}

# Build a JSON payload from a prompt file using the same python3 logic as
# copilot_chat in engine.sh.
build_payload() {
  local prompt_file="$1"
  local model="${2:-openai/o4-mini}"
  python3 -c "
import json, sys
prompt = open(sys.argv[1]).read()
model  = sys.argv[2]
sys.stdout.write(json.dumps({
    'model': model,
    'messages': [{'role': 'user', 'content': prompt}],
}))
" "$prompt_file" "$model"
}

# Assert that a string is valid JSON.
assert_valid_json() {
  local name="$1"
  local json_str="$2"
  if echo "$json_str" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    ok "$name"
  else
    fail "$name" "produced invalid JSON"
  fi
}

# Assert that a JSON string has a specific field value.
assert_json_field() {
  local name="$1"
  local json_str="$2"
  local field="$3"
  local expected="$4"
  local got
  got=$(echo "$json_str" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d$field)" 2>/dev/null || echo "ERROR")
  if [[ "$got" = "$expected" ]]; then
    ok "$name"
  else
    fail "$name" "expected '$expected', got '$got'"
  fi
}

TMPDIR_TESTS=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TESTS"' EXIT

# ---------------------------------------------------------------------------
# Test 1: Plain ASCII prompt
# ---------------------------------------------------------------------------
PROMPT="$TMPDIR_TESTS/plain.txt"
printf 'Review this PR and output JSON.' > "$PROMPT"
PAYLOAD=$(build_payload "$PROMPT")
assert_valid_json "plain ASCII prompt: valid JSON" "$PAYLOAD"
assert_json_field "plain ASCII prompt: model field" "$PAYLOAD" "['model']" "openai/o4-mini"

# ---------------------------------------------------------------------------
# Test 2: Prompt with double quotes (the old `gh copilot suggest -p "..."`
#          approach would have broken shell quoting here)
# ---------------------------------------------------------------------------
PROMPT="$TMPDIR_TESTS/quotes.txt"
printf 'Say "hello world" and output {"key": "value"}.' > "$PROMPT"
PAYLOAD=$(build_payload "$PROMPT")
assert_valid_json "prompt with double quotes: valid JSON" "$PAYLOAD"

# ---------------------------------------------------------------------------
# Test 3: Prompt with single quotes
# ---------------------------------------------------------------------------
PROMPT="$TMPDIR_TESTS/single_quotes.txt"
printf "It's a test. Don't break." > "$PROMPT"
PAYLOAD=$(build_payload "$PROMPT")
assert_valid_json "prompt with single quotes: valid JSON" "$PAYLOAD"

# ---------------------------------------------------------------------------
# Test 4: Prompt with markdown headings (# chars)
# This was the trigger for "Invalid command format" in the old invocation:
# the expanded prompt started with "# Tier 1: Triage..." which the CLI
# misinterpreted as a flag/subcommand.
# ---------------------------------------------------------------------------
PROMPT="$TMPDIR_TESTS/markdown.txt"
printf '# Tier 1: Triage\n\nReview the PR.\n\n## Output\n\n{"escalate": false}\n' > "$PROMPT"
PAYLOAD=$(build_payload "$PROMPT")
assert_valid_json "prompt with markdown headings (#): valid JSON" "$PAYLOAD"
CONTENT=$(echo "$PAYLOAD" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['messages'][0]['content'])" 2>/dev/null)
if printf '%s' "$CONTENT" | grep -q '# Tier 1: Triage'; then
  ok "prompt with markdown headings: # preserved in content"
else
  fail "prompt with markdown headings: # preserved in content" "heading not found in encoded content"
fi

# ---------------------------------------------------------------------------
# Test 5: Prompt with newlines and backslashes
# ---------------------------------------------------------------------------
PROMPT="$TMPDIR_TESTS/newlines.txt"
printf 'Line 1\nLine 2\nPath: C:\\Users\\test\n' > "$PROMPT"
PAYLOAD=$(build_payload "$PROMPT")
assert_valid_json "prompt with newlines and backslashes: valid JSON" "$PAYLOAD"

# ---------------------------------------------------------------------------
# Test 6: Large prompt (simulating a real triage-prompt.md with PR diff)
# ---------------------------------------------------------------------------
PROMPT="$TMPDIR_TESTS/large.txt"
{
  printf '# Tier 1: Triage\n\n'
  printf 'PR_URL: https://github.com/org/repo/pull/42\n'
  printf 'PR_HEAD_SHA: abc123def456\n\n'
  # Simulate a 200-line diff
  for i in $(seq 1 200); do
    printf '+  line %d: some code change with "quotes" and $variables\n' "$i"
  done
} > "$PROMPT"
PAYLOAD=$(build_payload "$PROMPT")
assert_valid_json "large prompt (200-line diff): valid JSON" "$PAYLOAD"
CONTENT_LEN=$(echo "$PAYLOAD" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['messages'][0]['content']))" 2>/dev/null || echo 0)
if [ "$CONTENT_LEN" -gt 1000 ]; then  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449
  ok "large prompt: full content preserved (len=$CONTENT_LEN)"
else
  fail "large prompt: full content preserved" "content length $CONTENT_LEN is unexpectedly short"
fi

# ---------------------------------------------------------------------------
# Test 7: Prompt with Unicode
# ---------------------------------------------------------------------------
PROMPT="$TMPDIR_TESTS/unicode.txt"
printf 'Review: résumé → naïve → José → 中文 → 日本語\n' > "$PROMPT"
PAYLOAD=$(build_payload "$PROMPT")
assert_valid_json "prompt with Unicode: valid JSON" "$PAYLOAD"

# ---------------------------------------------------------------------------
# Test 8: Custom model name propagated correctly
# ---------------------------------------------------------------------------
PROMPT="$TMPDIR_TESTS/model.txt"
printf 'Simple prompt.\n' > "$PROMPT"
PAYLOAD=$(build_payload "$PROMPT" "openai/gpt-4o-mini")
assert_json_field "custom model name: model field" "$PAYLOAD" "['model']" "openai/gpt-4o-mini"

# ---------------------------------------------------------------------------
# Test 9: Messages array has correct structure
# ---------------------------------------------------------------------------
PROMPT="$TMPDIR_TESTS/structure.txt"
printf 'Check structure.\n' > "$PROMPT"
PAYLOAD=$(build_payload "$PROMPT")
MSG_ROLE=$(echo "$PAYLOAD" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['messages'][0]['role'])" 2>/dev/null || echo "ERROR")
if [[ "$MSG_ROLE" = "user" ]]; then
  ok "messages[0].role is 'user'"
else
  fail "messages[0].role is 'user'" "got '$MSG_ROLE'"
fi
# temperature must be absent from the payload — o4-mini (and other reasoning
# models) only support the default value and reject temperature=0 with HTTP 400.
TEMPERATURE=$(echo "$PAYLOAD" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('temperature', 'ABSENT'))" 2>/dev/null || echo "ERROR")
if [[ "$TEMPERATURE" = "ABSENT" ]]; then
  ok "temperature is absent from payload (required for o4-mini compatibility)"
else
  fail "temperature is absent from payload" "got '$TEMPERATURE' — o4-mini rejects temperature != default"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  printf '%b' "$ERRORS"
  exit 1
fi
