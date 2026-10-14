#!/usr/bin/env bats
# Unit + end-to-end tests: the sync-stub guard (#2185) also covers the fix-ci
# pass (#2212).
#
# PR #2191 guarded only the fix-bot-comment / fix-reviews intents. fix-ci pushed
# through push_with_merge_guard without the check, so a "repair" that SHA-pinned
# a `uses:` line in a synced stub was pushed. That leaves a standards-sync PR
# different from the template it syncs.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/sync-stub-guard.sh"
FIX_CI="$SCRIPT_DIR/scripts/dev-lead-fix-ci.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

STUB=".github/workflows/persona-mention.yml"
TPL="standards/workflows/persona-mention.yml"
HL=".github/workflows/dev-lead.yml"

SYNC_PR_JSON='{"base":{"ref":"main"},"head":{"ref":"feat"},"state":"open","labels":[{"name":"standards-sync"}]}'
PLAIN_PR_JSON='{"base":{"ref":"main"},"head":{"ref":"feat"},"state":"open","labels":[{"name":"enhancement"}]}'

setup() {
  # shellcheck source=scripts/lib/sync-stub-guard.sh
  source "$LIB"
  export SSG_RETRY_SLEEP=0
  export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@t
  export GIT_EDITOR=true
  # Sidecars go to this test's directory, not the /tmp every session shares (#2271).
  export DEV_LEAD_SIDECAR_DIR="$BATS_TEST_TMPDIR"
}

_stub_body() {
  local variant="${1:-sync}"
  cat <<EOF
# SOURCE OF TRUTH: combsmith/.github/standards/workflows/persona-mention.yml
# Do not change the trigger events in a consumer repo.
name: Persona Mention (${variant})
on:
  issue_comment:
    types: [created]
jobs:
  route:
    uses: combsmith/.github/.github/workflows/persona-mention-reusable.yml@v1
EOF
}

_hl_body() {
  local variant="${1:-sync}"
  cat <<EOF
name: dev-lead (${variant})
jobs:
  dispatch:
    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-stable
EOF
}

# _mk_pr: main holds a README; the PR branch `feat` carries the sync commit that
# writes the header stub, the header-less dev-lead.yml and a docs file (so the PR
# never nets to zero against main). A bare origin holds
# both, so the merge base resolves the way it does on a runner. PRE is the PR
# head before any pass.
_mk_pr() {
  REPO_DIR="$BATS_TEST_TMPDIR/repo"
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  git init -q -b main "$REPO_DIR"
  cd "$REPO_DIR"
  mkdir -p .github/workflows
  echo "# repo" > README.md
  git add -A; git commit -q -m base
  MB="$(git rev-parse HEAD)"
  git checkout -q -b feat
  _stub_body sync > "$STUB"
  _hl_body sync > "$HL"
  mkdir -p docs; echo "synced" > docs/sync.md
  git add -A; git commit -q -m "chore: sync 2 org-standard workflow stub(s)"
  PRE="$(git rev-parse HEAD)"
  git init -q --bare "$REMOTE"
  git remote add origin "file://$REMOTE"
  git push -q origin main feat
  git fetch -q origin
}

# ---------------------------------------------------------------------------
# ssg_read_pr — bounded-retry PR read
# ---------------------------------------------------------------------------

_gh_flaky() {
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  echo 0 > "$BATS_TEST_TMPDIR/n"
  cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$BATS_TEST_TMPDIR/n") + 1 )); echo "\$n" > "$BATS_TEST_TMPDIR/n"
[ "\$n" -ge "${1}" ] && { echo '{"labels":[]}'; exit 0; }
exit 1
EOF
  chmod +x "$BIN/gh"
}

@test "ssg_read_pr: retries an unreadable PR and returns the object once it reads" {
  _gh_flaky 3
  run env PATH="$BIN:$PATH" bash -c "source '$LIB'; ssg_read_pr o/r 7"
  [[ "$status" -eq 0 ]]
  [[ "$output" == '{"labels":[]}' ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/n")" -eq 3 ]]
}

@test "ssg_read_pr: gives up after three attempts and echoes nothing" {
  _gh_flaky 99
  run env PATH="$BIN:$PATH" bash -c "source '$LIB'; ssg_read_pr o/r 7"
  [[ -z "$output" ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/n")" -eq 3 ]]
}

# ---------------------------------------------------------------------------
# End to end — dev-lead-fix-ci.sh
# ---------------------------------------------------------------------------

# _e2e_stubs <pr_json|UNREADABLE>: gh/claude stubs on PATH that record comments,
# label adds, and merge calls; `gh pr checkout` checks feat out against origin.
_e2e_stubs() {
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  REC="$BATS_TEST_TMPDIR/rec"; : > "$REC"
  printf '%s' "$1" > "$BATS_TEST_TMPDIR/pr.json"
  cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr view"*) echo '{"state":"OPEN","headRefName":"feat","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' ;;
  *"pr checkout"*) git checkout -q -B feat --track origin/feat ;;
  *"pr comment"*) printf 'COMMENT %s\n' "\$*" >> "$REC" ;;
  *"pr merge"*) printf 'MERGE %s\n' "\$*" >> "$REC" ;;
  *"/labels"*) printf 'LABEL %s\n' "\$*" >> "$REC"; echo '[]' ;;
  *"graphql"*) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' ;;
  *"issues/"*"comments"*) echo '[]' ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"run view"*) echo "lint failed" ;;
  *"pulls/42/"*) echo '[]' ;;
  *"pulls/42"*)
    body=\$(cat "$BATS_TEST_TMPDIR/pr.json")
    [ "\$body" = "UNREADABLE" ] && exit 1
    printf '%s\n' "\$body" ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$BIN/gh"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$BIN/gemini"; chmod +x "$BIN/gemini"
}

# _engine <script>: the claude stub runs <script> in the PR worktree.
_engine() {
  printf '#!/usr/bin/env bash\necho "engine ran"\n%s\n' "$1" > "$BIN/claude"
  chmod +x "$BIN/claude"
}

_run_fix_ci() {
  git checkout -q main
  git branch -q -D feat
  run env PATH="$BIN:$PATH" PR_NUMBER=42 HEAD_SHA="$PRE" REPO=o/r REVIEW_ENGINE=claude \
    DEV_LEAD_DRY_RUN=false PROMPTS_DIR="$SCRIPT_DIR/prompts/dev-lead" \
    CHECKS_JSON='[{"name":"lint","details_url":"https://github.com/o/r/actions/runs/1","id":1}]' \
    bash "$FIX_CI" 2>&1
}

_remote_feat() { git --git-dir="$REMOTE" rev-parse refs/heads/feat; }

@test "e2e fix-ci: a standards-sync PR whose fix edits a header stub is not pushed and gets the declined comment" {
  _mk_pr
  _e2e_stubs "$SYNC_PR_JSON"
  _engine "sed -i 's/@v1\$/@0123456789abcdef0123456789abcdef01234567/' '$STUB'"
  _run_fix_ci
  [[ "$output" == *"Sync-stub guard"* ]]
  [[ "$(_remote_feat)" == "$PRE" ]]
  grep -q 'Declined — synced org-standard stub is read-only here' "$REC"
  grep -q 'The `fix-ci` pass changed' "$REC"
  grep -q "blob/main/${TPL}" "$REC"
  grep -q 'dev-lead-sync-stub-drift pr=42 intent=fix-ci' "$REC"
  grep -q 'status=declined' "$REC"
  grep -q '^LABEL .*needs-human-review' "$REC"
  grep -q '^MERGE .*disable-auto' "$REC"
  run grep -q 'status=applied' "$REC"
  [[ "$status" -eq 1 ]]
}

@test "e2e fix-ci: a standards-sync PR whose fix edits a header-less synced stub is not pushed" {
  _mk_pr
  _e2e_stubs "$SYNC_PR_JSON"
  _engine "sed -i 's#@dev-lead/v1-stable#@0123456789abcdef0123456789abcdef01234567#' '$HL'"
  _run_fix_ci
  [[ "$(_remote_feat)" == "$PRE" ]]
  grep -q "\`${HL}\` — no template header" "$REC"
}

@test "e2e fix-ci: a standards-sync PR whose fix touches only an unsynced file is pushed" {
  _mk_pr
  _e2e_stubs "$SYNC_PR_JSON"
  _engine "echo fixed >> README.md"
  _run_fix_ci
  [[ "$(_remote_feat)" != "$PRE" ]]
  grep -q 'status=applied' "$REC"
  run grep -q 'Declined' "$REC"
  [[ "$status" -eq 1 ]]
}

@test "e2e fix-ci: the same stub edit on a PR without the label is pushed as today" {
  _mk_pr
  _e2e_stubs "$PLAIN_PR_JSON"
  _engine "sed -i 's/@v1\$/@0123456789abcdef0123456789abcdef01234567/' '$STUB'"
  _run_fix_ci
  [[ "$(_remote_feat)" != "$PRE" ]]
  grep -q 'status=applied' "$REC"
  run grep -q 'Declined' "$REC"
  [[ "$status" -eq 1 ]]
}

@test "e2e fix-ci: an unreadable PR is pushed when no header stub was touched, refused when one was" {
  _mk_pr
  _e2e_stubs "UNREADABLE"
  _engine "echo fixed >> README.md"
  _run_fix_ci
  [[ "$(_remote_feat)" != "$PRE" ]]
  [[ "$output" == *"sync-stub check was skipped"* ]]

  rm -rf "$REPO_DIR" "$REMOTE"
  _mk_pr
  _e2e_stubs "UNREADABLE"
  _engine "sed -i 's/@v1\$/@0123456789abcdef0123456789abcdef01234567/' '$STUB'"
  _run_fix_ci
  [[ "$(_remote_feat)" == "$PRE" ]]
  grep -q 'could not be verified' "$REC"
}

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------

@test "Wiring: fix-ci sources the guard and evaluates it before push_with_merge_guard" {
  grep -qF 'source "$(dirname "${BASH_SOURCE[0]}")/lib/sync-stub-guard.sh"' "$FIX_CI"
  local body
  body=$(awk '/^main\(\) \{/,/^}/' "$FIX_CI")
  local eval_line push_line
  eval_line=$(grep -n 'ssg_evaluate' <<<"$body" | head -1 | cut -d: -f1)
  push_line=$(grep -n 'push_with_merge_guard' <<<"$body" | tail -1 | cut -d: -f1)
  [[ -n "$eval_line" && -n "$push_line" ]]
  (( eval_line < push_line ))
}
