#!/usr/bin/env bats
# A fix-bot-comment pass on a bot-comment retry dispatch carries no head SHA
# (#2211). It must still work from the PR's current head: the tree the harness
# commits keeps the PR's own changes, and a head it cannot resolve — or a worktree
# that never landed on it — fails the pass loudly instead of falling back to the
# agent ref (`origin/main`). The no-op hold, when it does fire, tells the reader
# the PR branch is unchanged rather than asking them to restore a fix.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
FIX_REVIEWS_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-fix-reviews.sh"

setup() {
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  : > "$GITHUB_ENV"; : > "$GITHUB_OUTPUT"
  STUB_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN_DIR"
  rm -f /tmp/dev-lead-session-output.txt

  # origin: `main` plus a PR branch `feat` that differs from it (adds pr.txt and
  # changes shared.txt). AGENT is the runner's checkout, sitting on main.
  ORIGIN="$BATS_TEST_TMPDIR/origin"
  AGENT="$BATS_TEST_TMPDIR/agent"
  git init -q -b main "$ORIGIN"
  printf 'base\n' > "$ORIGIN/shared.txt"
  git -C "$ORIGIN" add -A
  git -C "$ORIGIN" -c user.email=t@t -c user.name=T commit -q -m base
  git -C "$ORIGIN" checkout -q -b feat
  printf 'pr change\n' > "$ORIGIN/shared.txt"
  printf 'added by the PR\n' > "$ORIGIN/pr.txt"
  git -C "$ORIGIN" add -A
  git -C "$ORIGIN" -c user.email=t@t -c user.name=T commit -q -m "feat: the PR's work"
  PR_HEAD="$(git -C "$ORIGIN" rev-parse HEAD)"
  git -C "$ORIGIN" checkout -q main
  git clone -q "$ORIGIN" "$AGENT"
  MAIN_SHA="$(git -C "$AGENT" rev-parse HEAD)"

  COMMENT_FILE="$BATS_TEST_TMPDIR/comments"
  PUSH_FILE="$BATS_TEST_TMPDIR/pushes"
  ENGINE_RAN="$BATS_TEST_TMPDIR/engine_ran"
  : > "$COMMENT_FILE"; : > "$PUSH_FILE"

  # Push is recorded (the pushed commit) and swallowed; everything else is real git.
  cat > "$STUB_BIN_DIR/git" << GITEOF
#!/usr/bin/env bash
if [ "\$1" = "push" ]; then /usr/bin/git rev-parse HEAD >> "${PUSH_FILE}"; exit 0; fi
exec /usr/bin/git "\$@"
GITEOF
  chmod +x "$STUB_BIN_DIR/git"
  export PATH="$STUB_BIN_DIR:$PATH"
}

# _gh_stub <checkout-mode> <pulls-mode>
#   checkout-mode: real  — `gh pr checkout` fetches and switches to the PR branch
#                  noop  — it exits 0 but leaves the worktree where it started
#   pulls-mode:    ok    — the PR endpoint reports PR_HEAD (honouring --jq)
#                  fail  — the PR endpoint read fails
_gh_stub() {
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
jq_filter=""
prev=""
for a in "\$@"; do [ "\$prev" = "--jq" ] && jq_filter="\$a"; prev="\$a"; done
case "\$ARGS" in
  "pr checkout"*)
    if [ "$1" = "real" ]; then
      git fetch -q origin feat:refs/remotes/origin/feat && git checkout -q -b feat --track origin/feat
    fi
    exit 0 ;;
  "pr view"*) echo '{"state":"OPEN","headRefName":"feat"}' ;;
  "pr comment"*) printf '%s\n' "\$ARGS" >> "${COMMENT_FILE}"; exit 0 ;;
  "pr merge"*) exit 0 ;;
  "pr edit"*) exit 0 ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"statuses"*) echo '[]' ;;
  *"graphql"*) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' ;;
  *"issues/"*"comments"*) echo '[]' ;;
  *"pulls/54/"*) echo '[]' ;;
  *"pulls/54"*)
    [ "$2" = "fail" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    json='{"head":{"sha":"${PR_HEAD}","ref":"feat"},"base":{"ref":"main"},"auto_merge":null,"state":"open","body":""}'
    if [ -n "\$jq_filter" ]; then printf '%s\n' "\$json" | jq -r "\$jq_filter"; else printf '%s\n' "\$json"; fi ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
}

# _engine_stub <body> — the claude stub runs <body> in its CWD (the PR worktree).
_engine_stub() {
  cat > "$STUB_BIN_DIR/claude" << STUB
#!/usr/bin/env bash
: > "${ENGINE_RAN}"
echo "Addressed the bot comment."
$1
STUB
  chmod +x "$STUB_BIN_DIR/claude"
}

# Run the pass with a bot-comment retry-dispatch payload: no HEAD_SHA.
_run_retry_pass() {
  run bash -c "
    cd '$AGENT'
    unset HEAD_SHA
    export INTENT_TYPE=fix-bot-comment INTENT_REASON=bot-comment-retry-dispatch DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 REPO='petry-projects/.github-private' GITHUB_REPOSITORY='petry-projects/.github-private'
    export REVIEW_ENGINE=claude PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='coderabbitai[bot]' COMMENT_BODY='walkthrough summary' COMMENT_NODE_ID='IC_kwDOtest2211'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
}

@test "retry dispatch (no HEAD_SHA): the committed tree still contains the PR's changes (#2211)" {
  _gh_stub real ok
  _engine_stub "printf 'fixed\n' > fix.txt"

  _run_retry_pass

  [ -f "$ENGINE_RAN" ]
  # Exactly the harness's commit was pushed, and it sits on top of the PR head.
  [ "$(wc -l < "$PUSH_FILE")" -eq 1 ]
  local pushed
  pushed="$(head -1 "$PUSH_FILE")"
  [ "$(git -C "$AGENT" rev-parse "${pushed}^")" = "$PR_HEAD" ]
  # Its tree keeps the PR's work alongside the pass's fix.
  [ "$(git -C "$AGENT" show "${pushed}:pr.txt")" = "added by the PR" ]
  [ "$(git -C "$AGENT" show "${pushed}:shared.txt")" = "pr change" ]
  [ "$(git -C "$AGENT" show "${pushed}:fix.txt")" = "fixed" ]
  [[ "$output" != *"No-op guard"* ]]
}

@test "retry dispatch: a checkout that never lands on the PR head fails loudly, never works from main (#2211)" {
  _gh_stub noop ok
  _engine_stub "printf 'fixed\n' > fix.txt"

  _run_retry_pass

  [ "$status" -ne 0 ]
  # Names what could not be resolved: the PR head it expected and what it got.
  [[ "$output" == *"::error::"*"PR #54"*"$PR_HEAD"* ]]
  [[ "$output" == *"$MAIN_SHA"* ]]
  # Nothing ran against, or was committed from, the main-based worktree.
  [ ! -f "$ENGINE_RAN" ]
  [ ! -s "$PUSH_FILE" ]
}

@test "retry dispatch: an unresolvable PR head fails loudly and names it (#2211)" {
  _gh_stub real fail
  _engine_stub "printf 'fixed\n' > fix.txt"

  _run_retry_pass

  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"head SHA"*"PR #54"* ]]
  [ ! -f "$ENGINE_RAN" ]
  [ ! -s "$PUSH_FILE" ]
}

@test "no-op hold says the result was discarded and the branch is unchanged at its head (#2211)" {
  _gh_stub real ok
  # The #2198 shape: the session leaves the PR's files at main's content.
  _engine_stub "git checkout -q origin/main -- . && git rm -q --cached pr.txt && rm -f pr.txt"

  _run_retry_pass

  # The no-op guard is unchanged: it refuses the push and holds the PR.
  [[ "$output" == *"No-op guard"* ]]
  [ ! -s "$PUSH_FILE" ]
  grep -q "No-op fix detected" "$COMMENT_FILE"
  # The message says what is true.
  grep -q "discarded" "$COMMENT_FILE"
  grep -q "unchanged at \`${PR_HEAD}\`" "$COMMENT_FILE"
  grep -q "clear the hold" "$COMMENT_FILE"
  ! grep -q "restore the correct fix" "$COMMENT_FILE"
}
