#!/usr/bin/env bats
# #1894: "why isn't this PR approved?" — answered by the REAL gate chain.
#
# scripts/review-one-pr.sh in diagnose mode (PR_REVIEW_DIAGNOSE=true) runs every
# gate in order on the live snapshot, then stops before any model runs. It is
# read-only and never forced. scripts/pr-approval-diagnostic.sh wraps it and adds
# the PR facts. These tests drive both end to end with the same gh stub as
# tests/test_review_one_pr_force_re_review.bats, and assert the run never writes
# to GitHub and never starts an engine.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"
  export DIAG_SCRIPT="$REPO_ROOT/scripts/pr-approval-diagnostic.sh"

  export SHA="1894a1b2c3d4e5f60718293a4b5c6d7e8f901234"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/1894"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  export SNAPSHOT="$TEST_DIR/snapshot.json"
  export ENGINE_LOG="$TEST_DIR/engines.log"; : > "$ENGINE_LOG"
  export GH_LOG="$TEST_DIR/gh_calls.log"
  : > "$GH_LOG"

  # gh stub: honors `pr view --jq <filter>` (so the idempotency block's own marker
  # query works), returns the snapshot for a plain `pr view`, and answers the
  # GraphQL shapes the gates use with old timestamps so they clear.
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

  # Stub engines so a bypassed (proceed) run can't block on a real CLI.
  for e in claude copilot gemini; do
    printf '#!/bin/bash\necho "%s" >> "$ENGINE_LOG"\nexit 0\n' "$e" > "$TEST_DIR/bin/$e"
    chmod +x "$TEST_DIR/bin/$e"
  done

  export PATH="$TEST_DIR/bin:$PATH"
  export REVIEW_ENGINE="claude" GH_TOKEN="fake"
  unset DRY_RUN GITHUB_STEP_SUMMARY
  unset FORCE_REVIEW FORCE_RE_REVIEW
}


ROLLUP_PASS='[{"name":"CI / build","status":"COMPLETED","conclusion":"SUCCESS"}]'
ROLLUP_FAIL='[{"name":"CI / build","status":"COMPLETED","conclusion":"FAILURE"}]'
ROLLUP_PENDING='[{"name":"CI / build","status":"IN_PROGRESS","conclusion":null}]'

# write_snap <rollup> [labels-json] [comments-json] [reviews-json] [reviewDecision]
write_snap() {
  jq -n --arg sha "$SHA" --argjson rollup "$1" --argjson labels "${2:-[]}" \
        --argjson comments "${3:-[]}" --argjson reviews "${4:-[]}" --arg rd "${5:-REVIEW_REQUIRED}" '{
    state: "OPEN", isDraft: false, mergeStateStatus: "BLOCKED",
    headRefOid: $sha, baseRefName: "main", statusCheckRollup: $rollup, reviewDecision: $rd,
    reviews: $reviews, labels: ($labels | map({name: .})), closingIssuesReferences: [],
    body: "PR body", comments: $comments
  }' > "$SNAPSHOT"
}

# _assert_read_only — no GitHub write of any kind, and no engine ran.
_assert_read_only() {
  # Explicit failure: a negated command is exempt from errexit, so `! grep` here
  # would never fail the test.
  if grep -qiE 'pr (comment|edit|review|merge|close)|issue (comment|edit|close|create|reopen)|gist |mutation|--method[= ](POST|PUT|PATCH|DELETE)|-X ?(POST|PUT|PATCH|DELETE)' "$GH_LOG"; then
    cat "$GH_LOG"
    return 1
  fi
  [ ! -s "$ENGINE_LOG" ]
}

_verdict() { grep -E '^\{"pr":' <<<"$output" | tail -n 1; }

@test "diagnose: every gate passes → proceed/gates-clear, and the cascade never starts" {
  write_snap "$ROLLUP_PASS"
  PR_REVIEW_DIAGNOSE=true run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 0 ]
  [ "$(_verdict | jq -r '.decision + "/" + .reason')" = "proceed/gates-clear" ]
  [[ "$output" == *"diagnose: every gate passes"* ]]
  _assert_read_only
}

@test "diagnose: failing CI names the ci-failing gate and what clears it" {
  write_snap "$ROLLUP_FAIL"
  PR_REVIEW_DIAGNOSE=true run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$(_verdict | jq -r '.reason')" = "ci-failing" ]
  [[ "$(_verdict | jq -r '.would_change')" == *"turn green"* ]]
  _assert_read_only
}

@test "diagnose: pending CI reports ci-pending without polling" {
  write_snap "$ROLLUP_PENDING"
  PR_REVIEW_DIAGNOSE=true run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [[ "$(_verdict | jq -r '.reason')" == ci-pending* ]]
  [[ "$output" != *"waiting"*"for checks to settle"* ]]
  _assert_read_only
}

@test "diagnose is never forced: FORCE_REVIEW in the environment does not bypass a gate" {
  write_snap "$ROLLUP_FAIL"
  FORCE_REVIEW=true FORCE_RE_REVIEW=true PR_REVIEW_DIAGNOSE=true run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$(_verdict | jq -r '.reason')" = "ci-failing" ]
  [[ "$output" != *"bypassing the ci-failing gate"* ]]
  _assert_read_only
}

@test "diagnose: an escalated PR holding needs-human-review reports the human escalation" {
  write_snap "$ROLLUP_PASS" '["needs-human-review"]' \
    '[{"author":{"login":"donpetry-bot"},"createdAt":"2026-10-09T04:44:00Z","body":"<!-- pr-review-agent human-escalation v1 -->\nescalated"}]'
  PR_REVIEW_DIAGNOSE=true run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$(_verdict | jq -r '.reason')" = "human-escalated" ]
  _assert_read_only
}

@test "diagnose: a verdict already at head reports already-reviewed-at-head" {
  write_snap "$ROLLUP_PASS" '[]' \
    '[{"author":{"login":"donpetry-bot"},"createdAt":"2026-10-09T05:00:00Z","body":"<!-- pr-review-agent v1 sha='"$SHA"' --> <!-- decision=fix-requested risk=MEDIUM -->"}]'
  PR_REVIEW_DIAGNOSE=true run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$(_verdict | jq -r '.reason')" = "already-reviewed-at-head" ]
  _assert_read_only
}

@test "verdicts are also written to the step summary (#1894 — where an operator looks)" {
  write_snap "$ROLLUP_FAIL"
  export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
  PR_REVIEW_DIAGNOSE=true run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  grep -q "$PR_URL"'.*`skip` (ci-failing)\. Changes when: ' "$GITHUB_STEP_SUMMARY"
}

@test "wrapper: markdown report names the gate, what clears it, holds and approvals" {
  write_snap "$ROLLUP_FAIL" '["dev-lead:hands-off","bug"]' '[]' \
    '[{"author":{"login":"cubic-dev-ai"},"state":"APPROVED","commit":{"oid":"'"$SHA"'"},"body":"ok"}]'
  run timeout 30 bash "$DIAG_SCRIPT" "$PR_URL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## pr-review approval diagnostic: $PR_URL"* ]]
  [[ "$output" == *'**Not approved** (review decision: `REVIEW_REQUIRED`).'* ]]
  [[ "$output" == *'| What pr-review would do now | `skip` — `ci-failing` |'* ]]
  [[ "$output" == *'| dev-lead hold labels | `dev-lead:hands-off` |'* ]]
  [[ "$output" == *'pr-review gates only on `needs-human-review`'* ]]
  [[ "$output" == *'| Approvals at head | cubic-dev-ai |'* ]]
  [[ "$output" == *"This is the first gate that holds the PR"* ]]
  _assert_read_only
}

@test "wrapper: an approved PR that a gate would now hold leads with the gate, not 'Approved' (#1902 review)" {
  write_snap "$ROLLUP_FAIL" '[]' '[]' \
    '[{"author":{"login":"donpetry-bot"},"state":"APPROVED","commit":{"oid":"'"$SHA"'"},"body":"ok"}]' APPROVED
  run timeout 30 bash "$DIAG_SCRIPT" "$PR_URL"
  [ "$status" -eq 0 ]
  [[ "$output" == *'**GitHub shows the PR approved, but pr-review would now hold it** at the `ci-failing` gate.'* ]]
  [[ "$output" != *'**Approved.**'* ]]
}

@test "wrapper: the gate log keeps the advisory gate's lines, without colour codes (#1902 review)" {
  write_snap "$ROLLUP_PASS"
  # Inject an advisory-gate warning line (as log_warn prints it) into the gate run's output.
  cat > "$TEST_DIR/bin/review-wrap" <<'EOF2'
#!/bin/bash
printf '\033[1;33m[advisory-gate] WARNING: required set reduced: dropped coderabbitai[bot] (RATE_LIMITED)\033[0m\n' >&2
exec bash "$REAL_REVIEW" "$@"
EOF2
  chmod +x "$TEST_DIR/bin/review-wrap"
  mkdir -p "$TEST_DIR/s"; cp "$DIAG_SCRIPT" "$TEST_DIR/s/pr-approval-diagnostic.sh"; cp -r "$REPO_ROOT/scripts/lib" "$TEST_DIR/s/lib"
  printf '#!/bin/bash\nexec "%s" "$@"\n' "$TEST_DIR/bin/review-wrap" > "$TEST_DIR/s/review-one-pr.sh"
  REAL_REVIEW="$REVIEW_SCRIPT" run timeout 30 bash "$TEST_DIR/s/pr-approval-diagnostic.sh" "$PR_URL" --json
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.gate_log' <<<"$output")" == *"[advisory-gate] WARNING: required set reduced: dropped coderabbitai[bot] (RATE_LIMITED)"* ]]
  [[ "$(jq -r '.gate_log' <<<"$output")" != *$'\033'* ]]
}

@test "wrapper: an approved PR held by the human escalation (noop human-escalated) is reported as held (#1902 review)" {
  write_snap "$ROLLUP_PASS" '["needs-human-review"]' \
    '[{"author":{"login":"donpetry-bot"},"createdAt":"2026-10-09T04:44:00Z","body":"<!-- pr-review-agent human-escalation v1 -->\nescalated"}]' \
    '[{"author":{"login":"donpetry-bot"},"state":"APPROVED","commit":{"oid":"'"$SHA"'"},"body":"ok"}]' APPROVED
  run timeout 30 bash "$DIAG_SCRIPT" "$PR_URL"
  [ "$status" -eq 0 ]
  [[ "$output" == *'pr-review would now hold it** at the `human-escalated` gate.'* ]]
  [[ "$output" != *'**Approved.**'* ]]
}

@test "wrapper: --json emits the verdict plus facts as one JSON object" {
  write_snap "$ROLLUP_PASS"
  run timeout 30 bash "$DIAG_SCRIPT" "$PR_URL" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.decision' <<<"$output")" = "proceed" ]
  [ "$(jq -r '.facts.reviewDecision' <<<"$output")" = "REVIEW_REQUIRED" ]
  [ "$(jq -r '.facts.holds | length' <<<"$output")" = "0" ]
}

@test "wrapper: an unreadable PR, or a head that moved since the gate run, is no diagnosis (#1902 review)" {
  write_snap "$ROLLUP_FAIL"
  # The gate run reads the snapshot; the facts read (the --json view without --jq) fails.
  cat > "$TEST_DIR/bin/gh-facts" <<'EOF2'
#!/bin/bash
case "$*" in *"--json state,isDraft"*) exit 1 ;; esac
exec "$REAL_GH_STUB" "$@"
EOF2
  mv "$TEST_DIR/bin/gh" "$TEST_DIR/gh-stub"; mv "$TEST_DIR/bin/gh-facts" "$TEST_DIR/bin/gh"
  chmod +x "$TEST_DIR/bin/gh"
  REAL_GH_STUB="$TEST_DIR/gh-stub" run timeout 30 bash "$DIAG_SCRIPT" "$PR_URL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not read the PR's review facts"* ]]
  [[ "$output" != *"Approvals at head"* ]]

  # The facts read sees a different head than the gate run did.
  cat > "$TEST_DIR/bin/gh" <<'EOF2'
#!/bin/bash
case "$*" in *"--json state,isDraft"*) jq '.headRefOid = "ffffffffffffffffffffffffffffffffffffffff"' "$SNAPSHOT"; exit 0 ;; esac
exec "$REAL_GH_STUB" "$@"
EOF2
  REAL_GH_STUB="$TEST_DIR/gh-stub" run timeout 30 bash "$DIAG_SCRIPT" "$PR_URL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"head moved while diagnosing"* ]]
}

@test "diagnose mode: gh itself refuses every write, whatever the spelling (#1902 review)" {
  # Load the classifier and the diagnose-mode gh wrapper exactly as review-one-pr.sh defines them.
  # shellcheck source=/dev/null
  source <(sed -n '/^_diagnose_gh_is_write() {/,/^}/p' "$REVIEW_SCRIPT")
  local w
  for w in "pr comment $PR_URL --body x" "pr edit $PR_URL --add-label needs-human-review" \
           "pr review $PR_URL --approve" "issue comment 5 --body x" "label create x" \
           "api -X POST repos/o/r/issues/1/comments" "api -XPATCH repos/o/r/issues/comments/1" \
           "api --method=DELETE repos/o/r/issues/1/labels/x" "api --method put repos/o/r/x" \
           "api repos/o/r/issues/1/comments -f body=x" "api repos/o/r/dispatches --input -" \
           "api graphql -f query=mutation(\$id:ID!){x}" "issue close 5" "gist create f.txt" \
           "codespace create" "extension-cmd run"; do
    # shellcheck disable=SC2086
    _diagnose_gh_is_write $w || { echo "not classified as a write: gh $w"; return 1; }
  done
  for w in "pr view $PR_URL --json labels" "pr list --state open" "api repos/o/r/pulls/1" \
           "api -X GET repos/o/r/pulls/1/reviews -f per_page=100" "api --paginate repos/o/r/issues/1/events" \
           "api graphql -f query=query{viewer{login}}" "auth status" "search prs is:open"; do
    # shellcheck disable=SC2086
    if _diagnose_gh_is_write $w; then echo "read classified as a write: gh $w"; return 1; fi
  done
  # The wrapper refuses (non-zero, logged) without reaching gh; reads reach it.
  # shellcheck source=/dev/null
  source <(sed -n '/^  gh() {$/,/^  }$/p' "$REVIEW_SCRIPT")
  [ "$(type -t gh)" = function ]
  run gh pr comment "$PR_URL" --body x
  [ "$status" -ne 0 ]
  [[ "$output" == *"diagnose: refused a GitHub write (gh pr comment)"* ]]
  [ ! -s "$GH_LOG" ]
  run gh pr view "$PR_URL" --json labels --jq '.labels'
  [ "$status" -eq 0 ]
  grep -q '^pr view' "$GH_LOG"
}

@test "wrapper: rejects a non-PR URL" {
  run bash "$DIAG_SCRIPT" "https://github.com/o/r/issues/1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "agent profile: every reason in the why-not-approved table is one review-one-pr.sh actually emits" {
  local skill="$REPO_ROOT/agents/why-not-approved.md" r
  head -10 "$skill" | grep -q '^name: why-not-approved$'
  head -10 "$skill" | grep -q '^description: '
  head -10 "$skill" | grep -q '^tools: '
  while IFS= read -r r; do
    grep -qE "emit_verdict [a-z-]+ ${r} " "$REPO_ROOT/scripts/review-one-pr.sh" \
      || { echo "reason '$r' in SKILL.md is not emitted by review-one-pr.sh"; return 1; }
  done < <(awk -F'|' '/^\| `/ {print $2}' "$skill" | grep -oE '`[a-z-]+`' | tr -d '`' | grep -vxE 'reason|proceed' | sort -u)
}
