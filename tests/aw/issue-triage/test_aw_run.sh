#!/usr/bin/env bash
# tests/aw/issue-triage/test_aw_run.sh
#
# Unit tests for aw.sh paths that do not require a live Claude call.
# Covers: skip guard, safe-output label validation, safe-output skip no-op.
#
# Run: bash tests/aw/issue-triage/test_aw_run.sh
set -euo pipefail

PASS=0
FAIL=0
ERRORS=""

ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS="${ERRORS}FAIL  $1: $2\n"; printf 'FAIL  %s: %s\n' "$1" "$2"; }

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURES="$(dirname "$0")/fixtures"

# ---------------------------------------------------------------------------
# Test 1: Scenario 4 — issue already has 2 labels → aw run emits {"skip":true}
# ---------------------------------------------------------------------------
result=$(bash "$REPO_ROOT/scripts/aw.sh" run issue-triage \
  --fixture "$FIXTURES/scenario-4-skip.json" --staged)
skip=$(AW_RESULT="$result" python3 - <<'PYEOF'
import json, os
print(json.loads(os.environ['AW_RESULT']).get('skip', False))
PYEOF
)
if [[ "$skip" == "True" ]]; then
  ok "scenario-4: 2 existing labels → skip=true"
else
  fail "scenario-4: 2 existing labels → skip=true" "got skip=$skip, result=$result"
fi

# ---------------------------------------------------------------------------
# Test 2: safe-output rejects result with more labels than max-labels (3)
# ---------------------------------------------------------------------------
tmp=$(mktemp)
printf '{"labels":["bug","needs-triage","question","enhancement"],"comment":"Hello!"}' > "$tmp"
output=$(ISSUE_NUMBER=1 GITHUB_REPOSITORY=example/repo \
  bash "$REPO_ROOT/scripts/aw.sh" safe-output apply issue-triage "$tmp" 2>&1 || true)
if echo "$output" | grep -q "rejected"; then
  ok "safe-output: 4 labels exceeds max-labels:3 → rejected"
else
  fail "safe-output: 4 labels exceeds max-labels:3 → rejected" "got: $output"
fi
rm -f "$tmp"

# ---------------------------------------------------------------------------
# Test 3: safe-output rejects a label not in the allowed set
# ---------------------------------------------------------------------------
tmp=$(mktemp)
printf '{"labels":["not-a-real-label"],"comment":"Hello!"}' > "$tmp"
output=$(ISSUE_NUMBER=1 GITHUB_REPOSITORY=example/repo \
  bash "$REPO_ROOT/scripts/aw.sh" safe-output apply issue-triage "$tmp" 2>&1 || true)
if echo "$output" | grep -q "rejected"; then
  ok "safe-output: disallowed label → rejected"
else
  fail "safe-output: disallowed label → rejected" "got: $output"
fi
rm -f "$tmp"

# ---------------------------------------------------------------------------
# Test 4: safe-output with skip flag → no-op, prints skip message
# ---------------------------------------------------------------------------
tmp=$(mktemp)
printf '{"skip":true}' > "$tmp"
output=$(ISSUE_NUMBER=1 GITHUB_REPOSITORY=example/repo \
  bash "$REPO_ROOT/scripts/aw.sh" safe-output apply issue-triage "$tmp" 2>&1)
if echo "$output" | grep -q "skip flag set"; then
  ok "safe-output: skip flag → no writes"
else
  fail "safe-output: skip flag → no writes" "got: $output"
fi
rm -f "$tmp"

# ---------------------------------------------------------------------------
# Test 5: safe-output rejects result with empty comment
# ---------------------------------------------------------------------------
tmp=$(mktemp)
printf '{"labels":["bug"],"comment":""}' > "$tmp"
output=$(ISSUE_NUMBER=1 GITHUB_REPOSITORY=example/repo \
  bash "$REPO_ROOT/scripts/aw.sh" safe-output apply issue-triage "$tmp" 2>&1 || true)
if echo "$output" | grep -q "rejected"; then
  ok "safe-output: empty comment → rejected"
else
  fail "safe-output: empty comment → rejected" "got: $output"
fi
rm -f "$tmp"

# ---------------------------------------------------------------------------
# Test 6: safe-output accepts valid labels + comment → validation passed
# Uses a classification-only label set (no hold). Per #1778 triage no longer
# applies the needs-human-review hold, so the valid-case fixture is `bug` alone.
# ---------------------------------------------------------------------------
tmp=$(mktemp)
printf '{"labels":["bug"],"comment":"Thank you for the report!"}' > "$tmp"
mock_dir=$(mktemp -d)
printf '#!/bin/sh\nexit 0\n' > "$mock_dir/gh"
chmod +x "$mock_dir/gh"
output=$(PATH="$mock_dir:$PATH" ISSUE_NUMBER=1 GITHUB_REPOSITORY=example/repo \
  bash "$REPO_ROOT/scripts/aw.sh" safe-output apply issue-triage "$tmp" 2>&1)
rm -rf "$mock_dir"
if echo "$output" | grep -q "validation passed"; then
  ok "safe-output: valid allowed labels → validation passed"
else
  fail "safe-output: valid allowed labels → validation passed" "got: $output"
fi
rm -f "$tmp"

# ---------------------------------------------------------------------------
# Test 7: issue-triage.md allowed list does NOT contain 'needs-triage'
# Regression guard: needs-triage does not exist in the repo; using it causes
# 'gh issue edit --add-label' to fail at runtime (issue #316).
# ---------------------------------------------------------------------------
WF_ALLOWED=$(python3 - "$REPO_ROOT/.github/workflows/issue-triage.md" <<'PYEOF'
import sys, re, yaml, json
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    text = f.read()
m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {} if m else {}
print(json.dumps(fm.get("safe-outputs", {}).get("add-labels", {}).get("allowed", [])))
PYEOF
)
if ! printf '%s\n' "$WF_ALLOWED" | python3 -c "import json,sys; sys.exit(0 if 'needs-triage' not in json.load(sys.stdin) else 1)"; then
  fail "issue-triage.md: allowed list must not contain 'needs-triage'" \
    "label 'needs-triage' does not exist in the repo — use 'needs-human-review'"
else
  ok "issue-triage.md: allowed list does not contain 'needs-triage'"
fi

# ---------------------------------------------------------------------------
# Test 8: issue-triage.md allowed list does NOT contain 'needs-human-review'
# Regression guard for #1778: needs-human-review is a *hold* label (hold-gate.sh)
# owned by the PR-review escalation path (pr-automation-budget.sh). Triage must
# classify without applying a hold, so the label is removed from triage's allowed
# set — this is the code-enforced half of the fix (safe-output rejects it even if
# the prompt drifts). If triage genuinely needs a hold again, that is a deliberate
# taxonomy decision, not a silent re-add here.
# ---------------------------------------------------------------------------
if printf '%s\n' "$WF_ALLOWED" | python3 -c "import json,sys; sys.exit(0 if 'needs-human-review' not in json.load(sys.stdin) else 1)"; then
  ok "issue-triage.md: allowed list does not contain 'needs-human-review' (#1778)"
else
  fail "issue-triage.md: allowed list must not contain 'needs-human-review' (#1778)" \
    "triage must not apply the needs-human-review hold; got: $WF_ALLOWED"
fi

# ---------------------------------------------------------------------------
# Test 9: issue-triage.md allowed list does NOT contain 'good-first-issue'
# Repo label is 'good first issue' (with space). Using the hyphenated form
# causes the same 'label not found' runtime failure as needs-triage (issue #316).
# ---------------------------------------------------------------------------
if ! printf '%s\n' "$WF_ALLOWED" | python3 -c "import json,sys; sys.exit(0 if 'good-first-issue' not in json.load(sys.stdin) else 1)"; then
  fail "issue-triage.md: allowed list must not contain 'good-first-issue'" \
    "repo label is 'good first issue' (with space) — use that form instead"
else
  ok "issue-triage.md: allowed list does not contain 'good-first-issue'"
fi

# ---------------------------------------------------------------------------
# Test 9b: issue-triage.md allowed list DOES contain 'good first issue'
# Pair with Test 9: absence of hyphenated form alone doesn't prove the spaced
# form is present. Dropping the label entirely would pass Test 9 but fail here.
# ---------------------------------------------------------------------------
if printf '%s\n' "$WF_ALLOWED" | python3 -c "import json,sys; sys.exit(0 if 'good first issue' in json.load(sys.stdin) else 1)"; then
  ok "issue-triage.md: allowed list contains 'good first issue'"
else
  fail "issue-triage.md: allowed list must contain 'good first issue'" \
    "got: $WF_ALLOWED"
fi

# ---------------------------------------------------------------------------
# Test 10: issue-triage.md prompt body does NOT instruct the model to return
# {"skip": true} — aw.sh's pre-Claude label-count guard already handles skip;
# a skip instruction in the prompt causes Claude to return {"skip":true} which
# aw.sh then rejects as prompt injection, failing the run (issue #316).
# ---------------------------------------------------------------------------
WF_BODY=$(python3 - "$REPO_ROOT/.github/workflows/issue-triage.md" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    text = f.read()
m = re.match(r'^---\n.*?\n---\n', text, re.DOTALL)
print(text[m.end():] if m else text)
PYEOF
)
if echo "$WF_BODY" | grep -qE '"skip"\s*:\s*true'; then
  fail 'issue-triage.md: prompt must not instruct Claude to return {"skip":true}' \
    'aw.sh rejects any skip flag from the model as prompt injection (issue #316); remove the skip instruction — the pre-Claude label guard in aw.sh already handles this'
else
  ok 'issue-triage.md: prompt does not contain skip instruction'
fi

# ---------------------------------------------------------------------------
# Test 11: safe-output REJECTS 'needs-human-review' from a triage result (#1778)
# This is the drift-proof half of the fix (AC #2): even if the triage prompt is
# later edited to emit the hold label, safe-output apply must reject it because
# it is not in issue-triage's allowed set. A prompt-only rule would drift; this
# makes the guarantee code-level.
# ---------------------------------------------------------------------------
tmp=$(mktemp)
printf '{"labels":["needs-human-review"],"comment":"Thank you for the report!"}' > "$tmp"
mock_dir=$(mktemp -d)
printf '#!/bin/sh\nexit 0\n' > "$mock_dir/gh"
chmod +x "$mock_dir/gh"
status=0
output=$(PATH="$mock_dir:$PATH" ISSUE_NUMBER=1 GITHUB_REPOSITORY=example/repo \
  bash "$REPO_ROOT/scripts/aw.sh" safe-output apply issue-triage "$tmp" 2>&1) || status=$?
rm -rf "$mock_dir"
if [[ $status -eq 1 ]] && echo "$output" | grep -q "rejected"; then
  ok "safe-output: triage result with 'needs-human-review' is rejected (#1778)"
else
  fail "safe-output: triage must not be able to apply the 'needs-human-review' hold (#1778)" "got (status=$status): $output"
fi
rm -f "$tmp"

# ---------------------------------------------------------------------------
# Test: aw run passes Claude a concrete model id resolved from the spec's
# family (models.claude: [sonnet]), never the engine name `claude` (#1979)
# ---------------------------------------------------------------------------
mock_dir=$(mktemp -d)
cat > "$mock_dir/claude" <<MOCK
#!/bin/sh
printf '%s\n' "\$*" > "$mock_dir/args"
echo '{"labels":["bug"],"comment":"ok"}'
MOCK
chmod +x "$mock_dir/claude"
status=0
run_out="$(PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/aw.sh" run issue-triage \
  --fixture "$FIXTURES/scenario-1-bug.json" --staged 2>&1)" || status=$?
args="$(cat "$mock_dir/args" 2>/dev/null || true)"
want="$(bash -c 'source "$1/scripts/lib/engine-models.sh"; ai_model_for_family sonnet' _ "$REPO_ROOT")"
model="$(printf '%s\n' "$args" | sed -n 's/.*--model \([^ ]*\).*/\1/p')"
rm -rf "$mock_dir"
if [[ $status -eq 0 && -n "$want" && "$model" == "$want" ]]; then
  ok "run: issue-triage calls claude --model $model (sonnet family, not 'claude')"
else
  fail "run: issue-triage must pass the resolved sonnet id to --model" "got status=$status model='$model' want='$want' args='$args' output='$run_out'"
fi

# ---------------------------------------------------------------------------
# Test: aw compile fails a runner-style engine without a usable models.<engine>
# entry — the same case `aw run` rejects (#1979)
# ---------------------------------------------------------------------------
spec_dir=$(mktemp -d)
write_spec() {
  printf -- '---\nname: t\ntrigger:\n  issues: {}\nengine: claude\npermissions: {}\n%b---\nbody\n' "$2" > "$spec_dir/$1.md"
}
write_spec ok 'models:\n  claude: [sonnet]\n'
write_spec nomodel ''
write_spec badmodel 'models:\n  claude: [Sonnet]\n'
status=0; output=$(bash "$REPO_ROOT/scripts/aw.sh" compile "$spec_dir/ok.md" 2>&1) || status=$?
if [[ $status -eq 0 ]]; then ok "compile: engine claude with models.claude [sonnet] passes"
else fail "compile: a valid family model must pass" "status=$status: $output"; fi
status=0; output=$(bash "$REPO_ROOT/scripts/aw.sh" compile "$spec_dir/nomodel.md" 2>&1) || status=$?
if [[ $status -ne 0 ]] && echo "$output" | grep -q "needs a model"; then ok "compile: engine claude without models.claude fails"
else fail "compile: a runner engine with no model must fail" "status=$status: $output"; fi
status=0; output=$(bash "$REPO_ROOT/scripts/aw.sh" compile "$spec_dir/badmodel.md" 2>&1) || status=$?
if [[ $status -ne 0 ]] && echo "$output" | grep -q "must be a family"; then ok "compile: a mis-cased family (Sonnet) fails"
else fail "compile: a non-family, non-claude-* model must fail" "status=$status: $output"; fi
# Other runners keep the warn-only rule, so a new provider needs no code change.
printf -- '---\nname: t\ntrigger:\n  issues: {}\nengine: copilot\npermissions: {}\nmodels:\n  copilot: [gpt-5]\n---\nbody\n' > "$spec_dir/copilot.md"
status=0; output=$(bash "$REPO_ROOT/scripts/aw.sh" compile "$spec_dir/copilot.md" 2>&1) || status=$?
if [[ $status -eq 0 ]]; then ok "compile: a non-claude runner with its own model still passes"
else fail "compile: the claude-only model check must not fail other runners" "status=$status: $output"; fi
# A list-valued engine can't key models.<engine>; compile must reject it.
printf -- '---\nname: t\ntrigger:\n  issues: {}\nengine: [claude]\npermissions: {}\n---\nbody\n' > "$spec_dir/listengine.md"
status=0; output=$(bash "$REPO_ROOT/scripts/aw.sh" compile "$spec_dir/listengine.md" 2>&1) || status=$?
if [[ $status -ne 0 ]] && echo "$output" | grep -q "engine must be a string"; then ok "compile: a list-valued engine fails"
else fail "compile: a non-string engine must fail" "status=$status: $output"; fi
# A falsy non-string engine (null) must fail too, as it does in aw run.
printf -- '---\nname: t\ntrigger:\n  issues: {}\nengine: null\npermissions: {}\n---\nbody\n' > "$spec_dir/nullengine.md"
status=0; output=$(bash "$REPO_ROOT/scripts/aw.sh" compile "$spec_dir/nullengine.md" 2>&1) || status=$?
if [[ $status -ne 0 ]] && echo "$output" | grep -q "engine must be a string"; then ok "compile: a null engine fails"
else fail "compile: a falsy non-string engine must fail" "status=$status: $output"; fi
rm -rf "$spec_dir"

# ---------------------------------------------------------------------------
# Test: the fable family compiles and resolves to claude-fable-5-2 (#2518).
# aw.sh reads specs from ./.github/workflows, so run it from a scratch dir.
# ---------------------------------------------------------------------------
fable_dir=$(mktemp -d)
mkdir -p "$fable_dir/.github/workflows"
printf -- '---\nname: t\ntrigger:\n  issues: {}\nengine: claude\npermissions: {}\nmodels:\n  claude: [fable]\n---\nTriage ${ISSUE_TITLE}\n' \
  > "$fable_dir/.github/workflows/fable-spec.md"
status=0; output=$(bash "$REPO_ROOT/scripts/aw.sh" compile "$fable_dir/.github/workflows/fable-spec.md" 2>&1) || status=$?
if [[ $status -eq 0 ]]; then ok "compile: engine claude with models.claude [fable] passes"
else fail "compile: the fable family must pass" "status=$status: $output"; fi
mkdir -p "$fable_dir/bin"
cat > "$fable_dir/bin/claude" <<MOCK
#!/bin/sh
printf '%s\n' "\$*" > "$fable_dir/args"
echo '{"labels":["bug"],"comment":"ok"}'
MOCK
chmod +x "$fable_dir/bin/claude"
status=0
run_out="$(cd "$fable_dir" && env -u AI_MODELS_CLAUDE -u CLAUDE_FABLE_MODEL_CHAIN \
  PATH="$fable_dir/bin:$PATH" bash "$REPO_ROOT/scripts/aw.sh" run fable-spec \
  --fixture "$REPO_ROOT/tests/aw/issue-triage/fixtures/scenario-1-bug.json" --staged 2>&1)" || status=$?
args="$(cat "$fable_dir/args" 2>/dev/null || true)"
model="$(printf '%s\n' "$args" | sed -n 's/.*--model \([^ ]*\).*/\1/p')"
rm -rf "$fable_dir"
if [[ $status -eq 0 && "$model" == "claude-fable-5-2" ]]; then
  ok "run: models.claude [fable] calls claude --model claude-fable-5-2"
else
  fail "run: the fable family must resolve to claude-fable-5-2" "got status=$status model='$model' args='$args' output='$run_out'"
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
