#!/usr/bin/env bats
# Issue #1551: the writer half. When a fix-requested verdict is metadata-only,
# scripts/post-pr-review.sh must stamp a PR-metadata digest into the marker
# (`meta=<digest>`) and tell the author the re-arm condition includes a metadata
# change (AC4). A code-change / unflagged fix-request carries no `meta=` and the
# footer keeps the commit-only wording — otherwise a body edit could re-arm a
# code-change finding (AC3).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export POST_SCRIPT="$REPO_ROOT/scripts/post-pr-review.sh"

  export SHA="8203876e5b0718dd3d672fed4eec8394e5d3729d"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/1531"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  export COMMENT_OUT="$TEST_DIR/posted_comment.txt"
  : > "$COMMENT_OUT"

  # gh stub: capture the fix-request comment body; answer the metadata fetch used
  # to compute the digest; no-op everything else.
  cat > "$TEST_DIR/bin/gh" <<'GHEOF'
#!/bin/bash
if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  prev=""
  for a in "$@"; do
    [ "$prev" = "--body" ] && printf '%s' "$a" > "$COMMENT_OUT"
    prev="$a"
  done
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  jqf=""; prev=""
  for a in "$@"; do
    [ "$prev" = "--jq" ] && jqf="$a"
    prev="$a"
  done
  meta='{"body":"Refs #1493","closingIssuesReferences":[],"labels":[{"name":"enhancement"}]}'
  if [ -n "$jqf" ]; then printf '%s' "$meta" | jq -r "$jqf"; else printf '%s' "$meta"; fi
  exit 0
fi
exit 0
GHEOF
  chmod +x "$TEST_DIR/bin/gh"
  export PATH="$TEST_DIR/bin:$PATH"

  export PR_HEAD_SHA="$SHA"
  export DRY_RUN="false"
  export AI_DELEGATION_ENABLED="true"
  export REVIEW_CYCLE="0"
  export MAX_REVIEW_CYCLES="3"
}

teardown() { rm -rf "$TEST_DIR"; }

write_verdict() {
  # $1 = metadata_only value ("true"/"false"), or "omit" to leave the field out.
  local mo="$1" f="$TEST_DIR/verdict.json"
  if [ "$mo" = "omit" ]; then
    jq -n '{decision:"escalate", risk:"LOW", summary:"s", body:"- finding", escalate_to_ai:true}' > "$f"
  else
    jq -n --argjson mo "$mo" '{decision:"escalate", risk:"LOW", summary:"s", body:"- finding", metadata_only:$mo, escalate_to_ai:true}' > "$f"
  fi
  echo "$f"
}

@test "metadata_only=true → marker carries meta=<digest> and metadata-change footer" {
  local vf; vf=$(write_verdict true)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  echo "--- posted ---" >&2; cat "$COMMENT_OUT" >&2

  grep -qE 'decision=fix-requested risk=LOW meta=[a-f0-9]{16}' "$COMMENT_OUT"
  grep -qi 'PR body, labels, or linked issues' "$COMMENT_OUT"
}

@test "metadata_only=false → no meta= and commit-only footer (AC3)" {
  local vf; vf=$(write_verdict false)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  cat "$COMMENT_OUT" >&2

  # Assert grep's exit is exactly 1 (no match) — a bare `! grep` would also pass
  # on status 2 (e.g. an unreadable/missing file), masking a real failure.
  run grep -q 'meta=' "$COMMENT_OUT"
  [ "$status" -eq 1 ]
  grep -q 'after new commits are pushed' "$COMMENT_OUT"
}

@test "metadata_only absent → defaults to no meta= (unchanged behavior)" {
  local vf; vf=$(write_verdict omit)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  cat "$COMMENT_OUT" >&2

  # Assert grep's exit is exactly 1 (no match) rather than any non-zero status.
  run grep -q 'meta=' "$COMMENT_OUT"
  [ "$status" -eq 1 ]
  grep -q 'after new commits are pushed' "$COMMENT_OUT"
}
