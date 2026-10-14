#!/usr/bin/env bats
# Regression coverage for issue #855: when every review engine is
# rate-limited/unavailable for a PR, the cascade must post AT MOST ONE
# "engine unavailable" notice comment per PR — never a storm — and must
# dedupe across re-runs (the mention-dispatch retry loop) via an HTML marker.

setup() {
  export TEST_DIR="$BATS_TEST_TMPDIR/engine-unavailable-test"
  rm -rf "$TEST_DIR"
  mkdir -p "$TEST_DIR/scripts" "$TEST_DIR/bin"
  cd "$TEST_DIR"

  export PRS_FILE="prs.txt"
  echo "https://github.com/fake/repo/pull/1" > "$PRS_FILE"
  export CANDIDATE_LIMIT=1
  export MAX_PRS=1
  export REVIEW_ENGINE="claude"
  export COPILOT_GITHUB_TOKEN="fake_token"
  export PATH="$TEST_DIR/bin:$PATH"

  # Where the fake gh records posted comments and reads existing ones from.
  export GH_COMMENT_LOG="$TEST_DIR/posted-comments.log"
  export GH_VIEW_COMMENTS="$TEST_DIR/existing-comments.json"
  : > "$GH_COMMENT_LOG"
  echo '{"comments":[]}' > "$GH_VIEW_COMMENTS"

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

  # GitHub Models stub for the Copilot fallback pre-flight: always "ready".
  cat > "$TEST_DIR/bin/curl" <<'EOF'
#!/bin/bash
echo '{"choices":[{"message":{"content":"ready"}}]}'
echo '200'
EOF
  chmod +x "$TEST_DIR/bin/curl"

  # Every engine reports rate-limited (exit 2) for this PR.
  cat > "scripts/review-one-pr.sh" <<'EOF'
#!/bin/bash
exit 2
EOF
  chmod +x "scripts/review-one-pr.sh"

  cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/bin/bash
# Minimal gh stub: serves the PR comment snapshot for dedupe checks and
# records every posted comment body so tests can count notices.
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  cat "$GH_VIEW_COMMENTS"
  exit 0
elif [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  body=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--body" ]; then
      body="$2"
      shift 2
      continue
    fi
    shift
  done
  printf '%s\n' "===COMMENT===" >> "$GH_COMMENT_LOG"
  printf '%s\n' "$body" >> "$GH_COMMENT_LOG"
  exit 0
fi
exit 0
EOF
  chmod +x "$TEST_DIR/bin/gh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

_notice_count() {
  local n
  n=$(grep -c '===COMMENT===' "$GH_COMMENT_LOG" 2>/dev/null) || n=0
  printf '%s' "$n"
}

@test "all engines exhausted: posts exactly one engine-unavailable notice" {
  run bash scripts/review-batch.sh
  echo "$output" >&2

  # Terminal abort when the final fallback engine is also rate-limited.
  [ "$status" -eq 1 ]
  [ "$(_notice_count)" -eq 1 ]
  grep -q 'pr-review-agent engine-unavailable v1' "$GH_COMMENT_LOG"
}

@test "dedupe: notice marker already present means no new comment" {
  # Simulate a prior run's notice already on the PR.
  cat > "$GH_VIEW_COMMENTS" <<'EOF'
{"comments":[{"body":"<!-- pr-review-agent engine-unavailable v1 -->\nAutomated review paused."}]}
EOF

  run bash scripts/review-batch.sh
  echo "$output" >&2

  [ "$status" -eq 1 ]
  [ "$(_notice_count)" -eq 0 ]
}

@test "DRY_RUN: no notice comment is posted" {
  export DRY_RUN="true"

  run bash scripts/review-batch.sh
  echo "$output" >&2

  [ "$status" -eq 1 ]
  [ "$(_notice_count)" -eq 0 ]
}

@test "copilot rate-limited + gemini unavailable: single notice on skip-and-continue" {
  cat > "scripts/validate-engines.sh" <<'EOF'
validate_engines() {
  export CLAUDE_AVAILABLE="true"
  export GEMINI_AVAILABLE="false"
  export COPILOT_AVAILABLE="true"
}
EOF

  run bash scripts/review-batch.sh
  echo "$output" >&2

  # This path increments failures and continues; with one PR the batch exits 1.
  [ "$status" -eq 1 ]
  [ "$(_notice_count)" -eq 1 ]
  grep -q 'pr-review-agent engine-unavailable v1' "$GH_COMMENT_LOG"
}
