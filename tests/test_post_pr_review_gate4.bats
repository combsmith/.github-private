#!/usr/bin/env bats
# Issue #1766: mechanical enforcement of decision gate 4 in scripts/post-pr-review.sh.
#
# A cascade verdict of `approve` must be IMPOSSIBLE while any review thread is
# unresolved, or while the thread set cannot be enumerated (API failure /
# pagination / permissions). In those cases post-pr-review.sh downgrades the
# decision to escalate — it must never call `gh pr review --approve`. A clean,
# fully-enumerated, zero-unresolved snapshot still approves.
#
# The gh stub is driven by $URT_GQL_MODE:
#   clean       → complete snapshot, no unresolved threads (approval allowed)
#   unresolved  → complete snapshot, one unresolved thread (block)
#   paginated   → hasNextPage=true (unknown count → fail closed)
#   apifail     → graphql call exits non-zero (fail closed)

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export POST_SCRIPT="$REPO_ROOT/scripts/post-pr-review.sh"

  export SHA="8203876e5b0718dd3d672fed4eec8394e5d3729d"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/1742"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  export APPROVE_LOG="$TEST_DIR/approve.log"
  export COMMENT_OUT="$TEST_DIR/comment.txt"
  export GH_LOG="$TEST_DIR/gh.log"
  : > "$APPROVE_LOG"; : > "$COMMENT_OUT"; : > "$GH_LOG"

  cat > "$TEST_DIR/bin/gh" <<'GHEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"

# GraphQL: the unresolved-review-thread enumeration.
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  case "$*" in
    *reviewThreads*)
      case "${URT_GQL_MODE:-clean}" in
        clean)      printf '%s' '{"data":{"resource":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' ;;
        unresolved) printf '%s' '{"data":{"resource":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false}]}}}}' ;;
        paginated)  printf '%s' '{"data":{"resource":{"reviewThreads":{"pageInfo":{"hasNextPage":true},"nodes":[{"isResolved":true}]}}}}' ;;
        apifail)    exit 1 ;;
      esac
      exit 0
      ;;
    *) printf '%s' '{}'; exit 0 ;;
  esac
fi

# Approve review — record it so tests can assert it did/did not happen.
if [ "$1" = "pr" ] && [ "$2" = "review" ]; then
  printf 'APPROVE %s\n' "$*" >> "$APPROVE_LOG"
  exit 0
fi

# Fix-request / escalation comment — capture the body.
if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  prev=""
  for a in "$@"; do
    [ "$prev" = "--body" ] && printf '%s' "$a" > "$COMMENT_OUT"
    prev="$a"
  done
  exit 0
fi

# pr view: merge state + metadata queries.
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  jqf=""; prev=""
  for a in "$@"; do
    [ "$prev" = "--jq" ] && jqf="$a"
    prev="$a"
  done
  meta='{"mergeStateStatus":"CLEAN","body":"b","closingIssuesReferences":[],"labels":[]}'
  if [ -n "$jqf" ]; then printf '%s' "$meta" | jq -r "$jqf"; else printf '%s' "$meta"; fi
  exit 0
fi

# api --paginate for prior-item cleanup → empty arrays.
if [ "$1" = "api" ]; then
  printf '%s' '[]'
  exit 0
fi

exit 0
GHEOF
  chmod +x "$TEST_DIR/bin/gh"
  export PATH="$TEST_DIR/bin:$PATH"

  export PR_HEAD_SHA="$SHA"
  export DRY_RUN="false"
  # Enable the AI-delegation escalate path so a downgrade posts a fix-request
  # comment we can inspect (vs. the human-escalation branch).
  export AI_DELEGATION_ENABLED="true"
  export REVIEW_CYCLE="0"
  export MAX_REVIEW_CYCLES="3"
}

teardown() { rm -rf "$TEST_DIR"; }

write_verdict() {
  # $1 = decision, $2 = risk
  local f="$TEST_DIR/verdict.json"
  jq -n --arg d "$1" --arg r "$2" \
    '{decision:$d, risk:$r, summary:"s", findings:[], body:("<!-- pr-review-agent v1 sha=x decision=approved risk=" + $r + " -->\n\n## Automated review — APPROVED ✓")}' > "$f"
  echo "$f"
}

# ── AC1: unresolved thread ⇒ approve is downgraded to escalate ──────────────

@test "AC1: approve verdict + unresolved thread → NOT approved, escalated (#1766)" {
  export URT_GQL_MODE="unresolved"
  local vf; vf=$(write_verdict approve LOW)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  # The approval must NOT have been posted.
  [ ! -s "$APPROVE_LOG" ]
  # A fix-request comment must have been posted naming gate 4.
  grep -qi 'gate 4' "$COMMENT_OUT"
  grep -qi 'unresolved review thread' "$COMMENT_OUT"
}

# ── AC2: cannot enumerate (pagination) ⇒ fail closed to escalate ────────────

@test "AC2: approve verdict + paginated thread set → fail closed, NOT approved (#1766)" {
  export URT_GQL_MODE="paginated"
  local vf; vf=$(write_verdict approve LOW)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [ ! -s "$APPROVE_LOG" ]
  grep -qi 'could not be enumerated' "$COMMENT_OUT"
}

# ── AC2: cannot enumerate (API failure) ⇒ fail closed to escalate ───────────

@test "AC2: approve verdict + graphql API failure → fail closed, NOT approved (#1766)" {
  export URT_GQL_MODE="apifail"
  local vf; vf=$(write_verdict approve LOW)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [ ! -s "$APPROVE_LOG" ]
  grep -qi 'could not be enumerated' "$COMMENT_OUT"
}

# ── Control: clean, fully-enumerated, zero unresolved ⇒ approve still posts ──

@test "control: approve verdict + no unresolved threads → approved (gate 4 clear)" {
  export URT_GQL_MODE="clean"
  local vf; vf=$(write_verdict approve LOW)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  # Approval WAS posted.
  grep -q 'APPROVE' "$APPROVE_LOG"
  # No fix-request comment.
  [ ! -s "$COMMENT_OUT" ]
}

# ── The gate only governs approvals: an escalate verdict is untouched ────────

@test "escalate verdict is not affected by the gate (no thread enumeration needed)" {
  export URT_GQL_MODE="clean"
  local vf; vf=$(write_verdict escalate LOW)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [ ! -s "$APPROVE_LOG" ]
}

# ── DRY_RUN reflects the downgrade in the printed decision ──────────────────

@test "DRY_RUN: unresolved thread downgrades the printed decision to escalate" {
  export URT_GQL_MODE="unresolved"
  local vf; vf=$(write_verdict approve LOW)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "true"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [[ "$output" == *"Decision: escalate"* ]]
  [ ! -s "$APPROVE_LOG" ]
}
