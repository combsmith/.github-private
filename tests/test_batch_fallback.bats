#!/usr/bin/env bats

setup() {
  export TEST_DIR="$BATS_TMPDIR/batch-test"
  mkdir -p "$TEST_DIR/scripts"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"
  
  export PRS_FILE="prs.txt"
  echo "https://github.com/fake/pull/1" > "$PRS_FILE"
  export CANDIDATE_LIMIT=1
  export MAX_PRS=1
  export REVIEW_ENGINE="claude"
  export COPILOT_GITHUB_TOKEN="fake_token"
  export PATH="$TEST_DIR/bin:$PATH"

  cp "$BATS_TEST_DIRNAME/../scripts/review-batch.sh" "scripts/"
  mkdir -p "scripts/lib"
  cp "$BATS_TEST_DIRNAME/../scripts/lib/engine-chain.sh" "scripts/lib/"

  cat > "scripts/validate-engines.sh" <<'EOF'
validate_engines() {
  export CLAUDE_AVAILABLE="true"
  export GEMINI_AVAILABLE="true"
  export COPILOT_AVAILABLE="true"
}
EOF

  cat > "scripts/engine.sh" <<'EOF'
export COPILOT_API_MODEL="openai/o4-mini"
EOF

  cat > "scripts/review-one-pr.sh" <<'EOF'
#!/bin/bash
if [ "$REVIEW_ENGINE" = "claude" ]; then
  exit 2
elif [ "$REVIEW_ENGINE" = "gemini" ]; then
  exit 55
elif [ "$REVIEW_ENGINE" = "copilot" ]; then
  touch copilot_called.txt
  exit 0
fi
EOF
  chmod +x "scripts/review-one-pr.sh"

  cat > "$TEST_DIR/bin/curl" <<'EOF'
#!/bin/bash
echo '{"choices":[{"message":{"content":"ready"}}]}'
echo '200'
EOF
  chmod +x "$TEST_DIR/bin/curl"

  cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/bin/bash
if [ "$1" = "extension" ]; then
  echo "github/gh-copilot"
elif [ "$1" = "copilot" ]; then
  echo "gh copilot version"
fi
exit 0
EOF
  chmod +x "$TEST_DIR/bin/gh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "batch: Claude runtime error (exit 55) falls back to Copilot" {
  # Gemini is now last in the fallback chain (claude→copilot→gemini, #571), so
  # a Gemini trust error no longer falls back to Copilot.  The equivalent test
  # of the trust-error→fallback path is: Claude exits 55 (treated as
  # fallback-eligible by the exit-55 normaliser), then Copilot picks up.
  cat > "scripts/review-one-pr.sh" <<'EOF'
#!/bin/bash
if [ "$REVIEW_ENGINE" = "claude" ]; then
  exit 55
elif [ "$REVIEW_ENGINE" = "gemini" ]; then
  exit 55
elif [ "$REVIEW_ENGINE" = "copilot" ]; then
  touch copilot_called.txt
  exit 0
fi
EOF
  chmod +x "scripts/review-one-pr.sh"

  run bash scripts/review-batch.sh

  echo "$output" >&2

  [ "$status" -eq 0 ]
  [ -f copilot_called.txt ]
  [[ "$output" == *"Engine claude unavailable at runtime (exit 55)"* ]]
  [[ "$output" == *"switching to Copilot engine"* ]]
}

@test "batch: empty PRS_FILE with Gemini unavailable exits 0 without Copilot smoke test" {
  # Regression guard: when the billing probe marks Gemini unavailable the
  # pre-flight switch to Copilot must not run the smoke test (which would fail
  # on a missing/invalid COPILOT_GITHUB_TOKEN) when there are no PRs to review.
  cat > "scripts/validate-engines.sh" <<'EOF'
validate_engines() {
  export CLAUDE_AVAILABLE="false"
  export GEMINI_AVAILABLE="false"
  export COPILOT_AVAILABLE="true"
}
EOF

  # Empty PRS_FILE — nothing to review.
  : > "$PRS_FILE"
  unset COPILOT_GITHUB_TOKEN

  export REVIEW_ENGINE="gemini"
  run bash scripts/review-batch.sh

  echo "$output" >&2

  [ "$status" -eq 0 ]
  [[ "$output" == *"No candidate PRs to review"* ]]
}

@test "batch: primary Gemini with GEMINI_AVAILABLE=false skips to Copilot without invoking Gemini" {
  # Simulate the billing probe marking Gemini unavailable at startup.
  cat > "scripts/validate-engines.sh" <<'EOF'
validate_engines() {
  export CLAUDE_AVAILABLE="false"
  export GEMINI_AVAILABLE="false"
  export COPILOT_AVAILABLE="true"
}
EOF

  # Track every engine that review-one-pr.sh is called with.
  cat > "scripts/review-one-pr.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$REVIEW_ENGINE" >> engine_calls.txt
exit 0
EOF
  chmod +x "scripts/review-one-pr.sh"

  rm -f engine_calls.txt
  export REVIEW_ENGINE="gemini"
  run bash scripts/review-batch.sh

  echo "$output" >&2

  [ "$status" -eq 0 ]
  # review-one-pr.sh must have been called, and never as gemini.
  [ -f engine_calls.txt ]
  ! grep -q "^gemini$" engine_calls.txt || false
  grep -q "^copilot$" engine_calls.txt
  [[ "$output" == *"unavailable"* ]]
}

@test "batch: primary Gemini with GEMINI_AVAILABLE=false and COPILOT_AVAILABLE=false aborts with error" {
  # When both Gemini and Copilot are unavailable, the batch should abort rather
  # than switch to an unusable engine and fail on the first PR.
  cat > "scripts/validate-engines.sh" <<'EOF'
validate_engines() {
  export CLAUDE_AVAILABLE="false"
  export GEMINI_AVAILABLE="false"
  export COPILOT_AVAILABLE="false"
}
EOF

  export REVIEW_ENGINE="gemini"
  run bash scripts/review-batch.sh

  echo "$output" >&2

  [ "$status" -eq 1 ]
  [[ "$output" == *"Copilot fallback also unavailable"* ]]
}

# Sets up the Copilot smoke test with the real models library: validate-engines.sh
# sources it (as the real one does), and a curl stub records each probed model,
# answering 404 for any model listed in $BAD_MODELS.
_copilot_smoke_setup() {
  cp "$BATS_TEST_DIRNAME/../scripts/lib/engine-models.sh" "scripts/lib/"
  cat > "scripts/validate-engines.sh" <<'EOS'
source "$(dirname "${BASH_SOURCE[0]}")/lib/engine-models.sh"
validate_engines() {
  export CLAUDE_AVAILABLE="true" GEMINI_AVAILABLE="true" COPILOT_AVAILABLE="true"
}
EOS
  cat > "$TEST_DIR/bin/curl" <<'EOS'
#!/bin/bash
for a in "$@"; do case "$a" in @*) f="${a#@}" ;; esac; done
m="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["model"])' "$f")"
echo "$m" >> "$TEST_DIR/smoke_models.txt"
case " ${BAD_MODELS:-} " in *" $m "*) echo '{"error":"unknown model"}'; echo '404'; exit 0 ;; esac
echo '{"choices":[{"message":{"content":"ready"}}]}'
echo '200'
EOS
  chmod +x "$TEST_DIR/bin/curl"
  unset COPILOT_API_MODEL COPILOT_API_MODEL_DEFAULTED
  export REVIEW_ENGINE="copilot"
}

@test "batch: the Copilot smoke test probes every distinct tier model once" {
  _copilot_smoke_setup
  export AI_MODELS_COPILOT="triage=openai/t1; deep=openai/d1; audit=openai/d1"
  run bash scripts/review-batch.sh
  echo "$output" >&2
  [ "$(tr '\n' ' ' < smoke_models.txt)" = "openai/t1 openai/d1 openai/o4-mini " ]
  [[ "$output" == *"Copilot pre-flight passed — model=openai/d1"* ]]
}

@test "batch: an unavailable Copilot deep model fails the smoke test up front" {
  _copilot_smoke_setup
  export AI_MODELS_COPILOT="triage=openai/t1; deep=openai/typo" BAD_MODELS="openai/typo"
  run bash scripts/review-batch.sh
  echo "$output" >&2
  [ "$status" -eq 1 ]
  [[ "$output" == *"returned HTTP 404 for model 'openai/typo'"* ]]
  [ ! -f copilot_called.txt ]
}

@test "batch: a bad model on a fallback Copilot marks Copilot unavailable, not the batch failed" {
  _copilot_smoke_setup
  export REVIEW_ENGINE="claude" AI_MODELS_COPILOT="deep=openai/typo" BAD_MODELS="openai/typo"
  run bash scripts/review-batch.sh
  echo "$output" >&2
  [[ "$output" == *"Copilot fallback pre-flight"* ]]
  [[ "$output" == *"::warning::Copilot pre-flight failed: GitHub Models API returned HTTP 404 for model 'openai/typo'"* ]]
  [[ "$output" == *"Copilot fallback marked unavailable for this batch"* ]]
  [ ! -f copilot_called.txt ]
}

@test "batch: a healthy fallback Copilot passes its pre-flight and stays in the chain" {
  _copilot_smoke_setup
  export REVIEW_ENGINE="claude"
  run bash scripts/review-batch.sh
  echo "$output" >&2
  [[ "$output" == *"Copilot pre-flight passed — model=openai/o4-mini"* ]]
  [[ "$output" != *"marked unavailable"* ]]
  [ -f copilot_called.txt ]
}

@test "batch: a bad Copilot duck model only warns (the batch and the chain carry on)" {
  _copilot_smoke_setup
  export REVIEW_ENGINE="claude" AI_MODELS_COPILOT="duck=openai/duck-typo" BAD_MODELS="openai/duck-typo"
  run bash scripts/review-batch.sh
  echo "$output" >&2
  [ "$status" -eq 0 ]
  grep -qx 'openai/duck-typo' smoke_models.txt
  [[ "$output" == *"Copilot rubber-duck model unavailable"* ]]
  [[ "$output" != *"Copilot fallback marked unavailable"* ]]
  [ -f copilot_called.txt ]
}

@test "batch: a Copilot duck model that matches a tier model is not probed twice" {
  _copilot_smoke_setup
  export AI_MODELS_COPILOT="triage=openai/t1; duck=openai/t1"
  run bash scripts/review-batch.sh
  echo "$output" >&2
  [ "$(grep -c '^openai/t1$' smoke_models.txt)" = "1" ]
}

