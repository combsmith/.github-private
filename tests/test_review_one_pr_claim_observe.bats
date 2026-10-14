#!/usr/bin/env bats
# Integration guard for issue #1589, slice 1 (OBSERVE-ONLY).
#
# The #1551 metadata-digest re-arm path lets a same-SHA re-review proceed without
# taking an atomic claim, so two concurrent triggers can both launch the cascade.
# Slice 1 does not arbitrate that race — it makes it observable: on the
# digest-mismatch path review-one-pr.sh posts a per-PR claim marker keyed on
# (head SHA, current metadata digest), reads back live claims for the same key,
# and — if another run already holds a claim on that key — records a #1552-style
# `reason=concurrent-claim-detected` verdict line while STILL proceeding.
#
# These tests drive scripts/review-one-pr.sh to the idempotency block, past the
# advisory + maintainer gates (satisfied by the gh stub), and assert the
# observe-only behaviour on the re-arm branch. They mirror the harness in
# tests/test_review_one_pr_metadata_rearm.bats.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"
  # shellcheck source=../scripts/lib/pr-metadata-digest.sh
  source "$REPO_ROOT/scripts/lib/pr-metadata-digest.sh"
  # shellcheck source=../scripts/lib/pr-review-claim.sh
  source "$REPO_ROOT/scripts/lib/pr-review-claim.sh"

  export SHA="8203876e5b0718dd3d672fed4eec8394e5d3729d"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/1531"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  export SNAPSHOT="$TEST_DIR/snapshot.json"
  export GH_LOG="$TEST_DIR/gh_calls.log"
  : > "$GH_LOG"

  # gh stub: identical shape to the #1551 rearm test — honors `pr view --jq`,
  # returns the snapshot for a plain `pr view`, and answers the gate GraphQL.
  cat > "$TEST_DIR/bin/gh" <<'GHEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  jqf=""; prev=""
  for a in "$@"; do
    [ "$prev" = "--jq" ] && jqf="$a"
    prev="$a"
  done
  if [ -n "$jqf" ]; then jq -r "$jqf" "$SNAPSHOT"; else cat "$SNAPSHOT"; fi
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  case "$*" in
    *reviewThreads*) printf '%s' '{"data":{"resource":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' ;;
    *pushedDate*)    printf '%s' '{"data":{"resource":{"commits":{"nodes":[{"commit":{"pushedDate":"2020-01-01T00:00:00Z","committer":{"date":"2020-01-01T00:00:00Z"}}}]}}}}' ;;
    *)               printf '%s\n' '2020-01-01T00:00:00Z' ;;
  esac
  exit 0
fi
exit 0
GHEOF
  chmod +x "$TEST_DIR/bin/gh"

  for e in claude copilot gemini; do
    printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/$e"
    chmod +x "$TEST_DIR/bin/$e"
  done

  export PATH="$TEST_DIR/bin:$PATH"
  export REVIEW_ENGINE="claude" GH_TOKEN="fake" DRY_RUN="true"
  unset FORCE_REVIEW
}

teardown() { rm -rf "$TEST_DIR"; }

# Write a snapshot with a stale metadata-only fix-request marker ($1) plus any
# additional comment bodies ($2…, e.g. a concurrent claim marker). PR metadata
# (body/labels/closingIssuesReferences) is fixed and CI is green — identical to
# the #1551 harness so the digest-mismatch re-arm path is reached.
write_snapshot() {
  local marker_body="$1"; shift
  local comments; comments="$(jq -n --arg b "$marker_body" \
    '[{author:{login:"donpetry-bot"}, createdAt:"2026-08-19T12:06:00Z", body:$b}]')"
  local extra
  for extra in "$@"; do
    comments="$(jq --arg b "$extra" \
      '. + [{author:{login:"donpetry-bot"}, createdAt:"2026-08-19T12:07:00Z", body:$b}]' <<< "$comments")"
  done
  jq -n --arg sha "$SHA" --argjson comments "$comments" '{
    headRefOid: $sha,
    statusCheckRollup: [ { name: "CI / build", status: "COMPLETED", conclusion: "SUCCESS" } ],
    reviewDecision: "",
    reviews: [],
    labels: [ { name: "enhancement" } ],
    closingIssuesReferences: [],
    body: "Refs #1493 (body already edited to non-closing form)",
    comments: $comments
  }' > "$SNAPSHOT"
}

# The metadata digest of the fixed snapshot metadata above.
current_digest() {
  compute_pr_metadata_digest '{"body":"Refs #1493 (body already edited to non-closing form)","closingIssuesReferences":[],"labels":[{"name":"enhancement"}]}'
}

@test "records concurrent-claim-detected when a live claim on the same key already exists, and still proceeds" {
  local stale='<!-- pr-review-agent v1 sha='"$SHA"' --> <!-- decision=fix-requested risk=LOW meta=0000000000000000 -->'
  local digest; digest="$(current_digest)"
  local other_claim; other_claim="$(claim_marker "$SHA" "$digest" "run-OTHER-123" "2026-08-19T12:06:30Z")"
  write_snapshot "$stale" "$other_claim"

  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "status=$status" >&2
  echo "$output" >&2

  # Re-arm still fires (the #1551 path is unchanged)…
  [[ "$output" == *"metadata changed"* ]]
  # …and the race is now recorded as a #1552-style verdict line.
  [[ "$output" == *'"reason":"concurrent-claim-detected"'* ]]
  # Behaviour is unchanged: the run still proceeds into the cascade (not the
  # no-op sentinel).
  [ "$status" -ne 100 ]
}

@test "does NOT record concurrent-claim-detected when no other claim exists, and still proceeds" {
  local stale='<!-- pr-review-agent v1 sha='"$SHA"' --> <!-- decision=fix-requested risk=LOW meta=0000000000000000 -->'
  write_snapshot "$stale"

  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "status=$status" >&2
  echo "$output" >&2

  [[ "$output" == *"metadata changed"* ]]
  [[ "$output" != *"concurrent-claim-detected"* ]]
  [ "$status" -ne 100 ]
}

@test "a claim for a DIFFERENT key (stale digest) is not treated as concurrent" {
  local stale='<!-- pr-review-agent v1 sha='"$SHA"' --> <!-- decision=fix-requested risk=LOW meta=0000000000000000 -->'
  # A claim whose digest does not match the current metadata digest is a claim on
  # a different key and must be ignored.
  local other_claim; other_claim="$(claim_marker "$SHA" "0000000000000000" "run-OTHER-123" "2026-08-19T12:06:30Z")"
  write_snapshot "$stale" "$other_claim"

  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "status=$status" >&2
  echo "$output" >&2

  [[ "$output" == *"metadata changed"* ]]
  [[ "$output" != *"concurrent-claim-detected"* ]]
  [ "$status" -ne 100 ]
}
