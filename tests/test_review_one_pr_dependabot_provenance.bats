#!/usr/bin/env bats
# review-one-pr.sh — the Dependabot provenance gate (#2481).
#
# pr-review now approves Dependabot PRs (the sweep dispatches them). Before any
# review it keeps dependabot-automerge's provenance rule: every commit on a PR
# opened by Dependabot is Dependabot's, or the automerge App's update-branch
# merge. A commit from anyone else → skip `dependabot-provenance` (exit 100, no
# approval). An unreadable commit list → error (exit 1, fail closed). A PR not
# opened by Dependabot never reaches the gate. FORCE_REVIEW does not bypass it.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"
  export SHA="1111111111111111111111111111111111111111"
  export PR_URL="https://github.com/combsmith/demo/pull/524"
  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"; cd "$TEST_DIR"
  _snapshot "app/dependabot" SUCCESS
  jq -n --arg h "$SHA" '{head:{sha:$h}, commits:1, user:{login:"dependabot[bot]"}}' > "$TEST_DIR/pulls.json"
  _commits 'dependabot[bot]'
  cat > "$TEST_DIR/bin/gh" <<EOF
#!/bin/bash
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then cat "$TEST_DIR/snapshot.json"; exit 0; fi
if [ "\$1" = "api" ]; then
  case "\$2" in
    repos/combsmith/demo/pulls/524/commits*) echo "commits" >> "$TEST_DIR/api.log"; [ -f "$TEST_DIR/commits.json" ] || exit 1; cat "$TEST_DIR/commits.json"; exit 0 ;;
    repos/combsmith/demo/pulls/524) echo "pulls" >> "$TEST_DIR/api.log"; cat "$TEST_DIR/pulls.json"; exit 0 ;;
  esac
fi
exit 0
EOF
  chmod +x "$TEST_DIR/bin/gh"
  for e in claude copilot gemini; do printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/$e"; chmod +x "$TEST_DIR/bin/$e"; done
  export PATH="$TEST_DIR/bin:$PATH"
  export REVIEW_ENGINE="claude" GH_TOKEN="fake" DRY_RUN="true"
  unset FORCE_REVIEW
}
teardown() { rm -rf "$TEST_DIR"; }

# _snapshot <author_login> <ci_conclusion>
_snapshot() {
  jq -n --arg h "$SHA" --arg a "$1" --arg c "$2" '{
    headRefOid:$h, baseRefName:"main", author:{login:$a, is_bot:true},
    statusCheckRollup:[{name:"CI / build", status:"COMPLETED", conclusion:$c}],
    reviewDecision:"REVIEW_REQUIRED", reviews:[], labels:[], comments:[]}' > "$TEST_DIR/snapshot.json"
}
# _commits <author> [verified]
_commits() {
  jq -n --arg h "$SHA" --arg a "$1" --argjson v "${2:-true}" \
    '[[{sha:$h, author:{login:$a}, committer:{login:"web-flow"}, commit:{verification:{verified:$v}}, parents:[{sha:"p"}]}]]' \
    > "$TEST_DIR/commits.json"
}

@test "a Dependabot PR whose commits are all Dependabot's passes the gate and goes on to review" {
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [[ "$output" == *"Dependabot provenance: all 1 commit(s) from Dependabot"* ]]
  [[ "$output" != *'"reason":"dependabot-provenance'* ]]
}

@test "a Dependabot PR with a commit from anyone else is skipped, never approved" {
  _commits don-petry
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"dependabot-provenance"'* ]]
  [[ "$output" == *"not from Dependabot"* ]]
}

@test "a Dependabot PR with an unverified commit is skipped" {
  _commits 'dependabot[bot]' false
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"dependabot-provenance"'* ]]
}

@test "FORCE_REVIEW does not bypass the provenance gate" {
  _commits don-petry
  export FORCE_REVIEW=true
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"dependabot-provenance"'* ]]
}

@test "an unreadable commit list fails closed (error, exit 1)" {
  rm -f "$TEST_DIR/commits.json"
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 1 ]
  [[ "$output" == *'"reason":"dependabot-provenance-unreadable"'* ]]
}

@test "a Dependabot PR with a failing required check is skipped before any provenance read" {
  _snapshot "app/dependabot" FAILURE
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"ci-failing"'* ]]
  [ ! -f "$TEST_DIR/api.log" ]
}

@test "a PR not opened by Dependabot never reaches the gate" {
  _snapshot "don-petry" SUCCESS
  _commits don-petry
  run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [[ "$output" != *"Dependabot provenance"* ]]
  [[ "$output" != *'"reason":"dependabot-provenance'* ]]
  run grep -q "commits" "$TEST_DIR/api.log"
  [ "$status" -ne 0 ]
}

@test "Wiring: both PR snapshots read the author" {
  [ "$(grep -c 'gh pr view "$PR_URL" --json headRefOid,[a-zA-Z,]*,author' "$REVIEW_SCRIPT")" -eq 2 ]
}
