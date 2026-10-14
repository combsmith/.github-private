#!/usr/bin/env bats
# Regression guard for issue #1551: the already-reviewed-at-head deadlock on
# metadata-only findings.
#
# Incident (PR #1531, 2026-08-19): pr-review posted `fix requested` whose sole
# blocking finding was metadata-only (the PR body's `Closes #1493` would
# auto-close an issue with staged ACs). The prescribed fix — edit the PR body —
# produces NO new commit, so the reviewed-state fingerprint (head SHA alone)
# never changed and every re-review no-oped with `already-reviewed-at-head`.
# Broken only by an empty commit.
#
# The fix stamps a PR-metadata digest (body + closingIssuesReferences + labels)
# into metadata-only fix-request markers as `meta=<digest>`. A re-review at the
# same head SHA re-arms when the current digest differs from the marker's, and
# no-ops when it matches. Approval markers and code-change fix-requests carry no
# `meta=` and keep the exact same-SHA no-op behavior (AC3).
#
# These tests drive scripts/review-one-pr.sh end-to-end to the idempotency block,
# which requires passing the advisory-bot and maintainer gates first — the gh
# stub below satisfies them (no advisory-bot output + an old head commit ⇒
# advisory gate proceeds; our own marker comments are excluded from the
# maintainer gates; empty review-thread set clears the review-thread gate).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"
  # shellcheck source=../scripts/lib/pr-metadata-digest.sh
  source "$REPO_ROOT/scripts/lib/pr-metadata-digest.sh"

  export SHA="8203876e5b0718dd3d672fed4eec8394e5d3729d"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/1531"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  export SNAPSHOT="$TEST_DIR/snapshot.json"
  export GH_LOG="$TEST_DIR/gh_calls.log"
  : > "$GH_LOG"

  # gh stub: honors `pr view --jq <filter>` (so the idempotency block's own
  # marker query works), returns the snapshot for a plain `pr view`, and answers
  # the three GraphQL shapes the gates use:
  #   • reviewThreads → empty node set (review-thread gate clears)
  #   • pushedDate    → an old push time (maintainer gate head date)
  #   • committer date (advisory gate, called with --jq) → old date ⇒ head-age
  #     timeout elapsed ⇒ advisory gate proceeds with no bot output.
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

  # Stub engines so the re-arm (proceed) path can't block on a real CLI.
  for e in claude copilot gemini; do
    printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/$e"
    chmod +x "$TEST_DIR/bin/$e"
  done

  export PATH="$TEST_DIR/bin:$PATH"
  export REVIEW_ENGINE="claude" GH_TOKEN="fake" DRY_RUN="true"
  unset FORCE_REVIEW
}

teardown() { rm -rf "$TEST_DIR"; }

# Write a snapshot whose latest marker comment is $1 (a full comment body). The
# PR metadata (body/labels/closingIssuesReferences) is fixed and CI is green.
write_snapshot() {
  local marker_body="$1"
  jq -n --arg sha "$SHA" --arg body "$marker_body" '{
    headRefOid: $sha,
    statusCheckRollup: [ { name: "CI / build", status: "COMPLETED", conclusion: "SUCCESS" } ],
    reviewDecision: "",
    reviews: [],
    labels: [ { name: "enhancement" } ],
    closingIssuesReferences: [],
    body: "Refs #1493 (body already edited to non-closing form)",
    comments: [ { author: { login: "donpetry-bot" }, createdAt: "2026-08-19T12:06:00Z", body: $body } ]
  }' > "$SNAPSHOT"
}

@test "AC5: metadata-only fix-request re-arms when the metadata digest no longer matches" {
  # Marker carries a stale meta= that cannot match the current metadata ⇒ re-arm.
  local marker='<!-- pr-review-agent v1 sha='"$SHA"' --> <!-- decision=fix-requested risk=LOW meta=0000000000000000 -->'
  write_snapshot "$marker"

  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "status=$status" >&2
  echo "$output" >&2

  # It must NOT no-op with already-reviewed-at-head…
  [[ "$output" != *'"reason":"already-reviewed-at-head"'* ]]
  # …and must announce the metadata re-arm (AC1/AC4).
  [[ "$output" == *"metadata changed"* ]]
  # Assert the exit status too: re-arm must leave the idempotency gate and enter
  # the cascade, so it must NOT be the no-op sentinel (100). Otherwise a later
  # failure that still printed "metadata changed" could mask a regression where
  # the script actually no-oped. (The stub engines can't complete a real cascade,
  # so an exact success exit isn't reachable here — `!= 100` is the load-bearing
  # signal that the deadlock is broken.)
  [ "$status" -ne 100 ]
}

@test "AC5/AC3: metadata-only fix-request no-ops when the metadata digest still matches" {
  # Marker's meta= equals the digest of the CURRENT snapshot metadata ⇒ no-op.
  write_snapshot "placeholder"                       # materialize the snapshot…
  local digest; digest=$(compute_pr_metadata_digest "$(cat "$SNAPSHOT")")
  local marker='<!-- pr-review-agent v1 sha='"$SHA"' --> <!-- decision=fix-requested risk=LOW meta='"$digest"' -->'
  write_snapshot "$marker"                            # …then rewrite with the real marker

  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "status=$status" >&2
  echo "$output" >&2

  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"already-reviewed-at-head"'* ]]
  # AC4: the no-op line names both re-arm conditions for a metadata-only marker.
  [[ "$output" == *"metadata change"* ]]
}

@test "AC3: an approval marker at head still no-ops even with a stale meta= present (no re-arm)" {
  # Approval markers must NEVER re-arm on a metadata edit, or a noisy body-editor
  # could burn review cycles. To prove the metadata surface is genuinely ignored
  # for non-fix-requests, embed a meta= digest that CANNOT match the current
  # snapshot metadata (all-zeros) on an approval marker, and the snapshot metadata
  # is a distinct non-default state. marker_meta_digest scopes extraction to
  # `decision=fix-requested`, so this approval meta= must be ignored and the run
  # must still no-op on new-commit-only wording. Were the scoping to regress, the
  # mismatching digest would trigger a spurious metadata re-arm and fail here.
  local marker='<!-- pr-review-agent v1 sha='"$SHA"' decision=approved risk=LOW meta=0000000000000000 -->'
  write_snapshot "$marker"

  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "status=$status" >&2
  echo "$output" >&2

  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"already-reviewed-at-head"'* ]]
  # AC4: a non-metadata marker re-arms only on a new commit.
  [[ "$output" == *"new commit"* ]]
}
