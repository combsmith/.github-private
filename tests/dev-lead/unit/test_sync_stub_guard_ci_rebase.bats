#!/usr/bin/env bats
# Unit + end-to-end tests: the sync-stub guard (#2185) also covers the fix-ci and
# rebase passes (#2212).
#
# PR #2191 guarded only the fix-bot-comment / fix-reviews intents. fix-ci pushed
# through push_with_merge_guard without the check, so a "repair" that SHA-pinned
# a `uses:` line in a synced stub was pushed; the rebase engine force-pushed its
# own conflict resolution, so a stub resolved to neither side was pushed too.
# Either leaves a standards-sync PR different from the template it syncs.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/sync-stub-guard.sh"
FIX_CI="$SCRIPT_DIR/scripts/dev-lead-fix-ci.sh"
HARNESS="$SCRIPT_DIR/scripts/dev-lead-fix-reviews.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

STUB=".github/workflows/persona-mention.yml"
TPL="standards/workflows/persona-mention.yml"
OTHER=".github/workflows/other.yml"
HL=".github/workflows/dev-lead.yml"

SYNC_PR_JSON='{"base":{"ref":"main"},"head":{"ref":"feat"},"state":"open","labels":[{"name":"standards-sync"}]}'
PLAIN_PR_JSON='{"base":{"ref":"main"},"head":{"ref":"feat"},"state":"open","labels":[{"name":"enhancement"}]}'

setup() {
  # shellcheck source=scripts/lib/sync-stub-guard.sh
  source "$LIB"
  export SSG_RETRY_SLEEP=0
  export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@t
  export GIT_EDITOR=true
}

_stub_body() {
  local variant="${1:-sync}"
  cat <<EOF
# SOURCE OF TRUTH: petry-projects/.github/standards/workflows/persona-mention.yml
# Do not change the trigger events in a consumer repo.
name: Persona Mention (${variant})
on:
  issue_comment:
    types: [created]
jobs:
  route:
    uses: petry-projects/.github/.github/workflows/persona-mention-reusable.yml@v1
EOF
}

_hl_body() {
  local variant="${1:-sync}"
  cat <<EOF
name: dev-lead (${variant})
jobs:
  dispatch:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-stable
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

# _advance_main: the base branch moves on — a newer template for both stubs (so
# the rebase conflicts in them) and a stub the PR never touched.
_advance_main() {
  git checkout -q main
  mkdir -p .github/workflows
  _stub_body base > "$STUB"
  _hl_body base > "$HL"
  printf '# SOURCE OF TRUTH: petry-projects/.github/standards/workflows/other.yml\nname: other\n' > "$OTHER"
  git add -A; git commit -q -m "main: newer templates"
  git push -q origin main
  git fetch -q origin
  git checkout -q feat
}

# _rebase_resolving <stub_variant> <hl_variant>: rebase feat onto origin/main and
# resolve both conflicts to the named content (sync | base | anything else).
_rebase_resolving() {
  git rebase -q origin/main >/dev/null 2>&1 || true
  _stub_body "$1" > "$STUB"
  _hl_body "$2" > "$HL"
  git add -A
  git rebase --continue >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# ssg_evaluate_rebase — the rebase rule: sync-commit content OR base content
# ---------------------------------------------------------------------------

@test "ssg_evaluate_rebase: a stub resolved to the sync commit's content -> clean" {
  _mk_pr; _advance_main
  _rebase_resolving sync sync
  run ssg_evaluate_rebase "$PRE" HEAD "$SYNC_PR_JSON" feat main
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ssg_evaluate_rebase: a stub resolved to the base branch's template content -> clean (base-only stubs too)" {
  _mk_pr; _advance_main
  _rebase_resolving base base
  run ssg_evaluate_rebase "$PRE" HEAD "$SYNC_PR_JSON" feat main
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ssg_evaluate_rebase: a header stub resolved to neither side -> drift rc1, template named, base-only stub not listed" {
  _mk_pr; _advance_main
  _rebase_resolving mixed base
  run ssg_evaluate_rebase "$PRE" HEAD "$SYNC_PR_JSON" feat main
  [[ "$status" -eq 1 ]]
  [[ "${lines[0]}" == "drift" ]]
  [[ "${lines[1]}" == "${STUB}"$'\t'"${TPL}" ]]
  [[ "${#lines[@]}" -eq 2 ]]
}

@test "ssg_evaluate_rebase: a header-less synced file resolved to neither side -> drift, no template named" {
  _mk_pr; _advance_main
  _rebase_resolving sync mixed
  run ssg_evaluate_rebase "$PRE" HEAD "$SYNC_PR_JSON" feat main
  [[ "$status" -eq 1 ]]
  [[ "${lines[1]}" == "${HL}"$'\t' ]]
}

@test "ssg_evaluate_rebase: the same mixed resolution on a PR without the label -> clean" {
  _mk_pr; _advance_main
  _rebase_resolving mixed mixed
  run ssg_evaluate_rebase "$PRE" HEAD "$PLAIN_PR_JSON" feat main
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ssg_evaluate_rebase: unreadable PR, header stubs equal to base -> clean with a warning" {
  _mk_pr; _advance_main
  _rebase_resolving base mixed
  local out
  out=$(ssg_evaluate_rebase "$PRE" HEAD "" feat main 2>"$BATS_TEST_TMPDIR/err")
  [[ "$out" == "clean" ]]
  grep -q '::warning::.*sync-stub check was skipped' "$BATS_TEST_TMPDIR/err"
}

@test "ssg_evaluate_rebase: unreadable PR, a header stub resolved to neither side fails closed -> unknown rc2" {
  _mk_pr; _advance_main
  _rebase_resolving mixed base
  run ssg_evaluate_rebase "$PRE" HEAD "not json" feat main
  [[ "$status" -eq 2 ]]
  [[ "${lines[0]}" == "unknown" ]]
}

@test "ssg_evaluate_rebase: a sync PR whose base branch cannot be read fails closed -> unknown rc2" {
  _mk_pr; _advance_main
  _rebase_resolving base base
  run ssg_evaluate_rebase "$PRE" HEAD '{"base":{"ref":"nope"},"labels":[{"name":"standards-sync"}]}' feat nope
  [[ "$status" -eq 2 ]]
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
# ssg_install_push_blocker — the engine cannot push during a deferred pass
# ---------------------------------------------------------------------------

@test "ssg_install_push_blocker: git push is refused, every other git command runs" {
  _mk_pr
  local dir
  dir=$(ssg_install_push_blocker)
  [[ -x "$dir/git" ]]
  run env PATH="$dir:$PATH" git push origin feat
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"harness"* ]]
  run env PATH="$dir:$PATH" git -C "$REPO_DIR" -c core.quotePath=false push --force-with-lease origin feat
  [[ "$status" -ne 0 ]]
  run env PATH="$dir:$PATH" git -C "$REPO_DIR" rev-parse HEAD
  [[ "$status" -eq 0 ]]
  [[ "$output" == "$PRE" ]]
  rm -rf "$dir"
}

@test "ssg_install_push_blocker: alias override is refused even when -c is not the first argument" {
  _mk_pr
  local dir
  dir=$(ssg_install_push_blocker)
  run env PATH="$dir:$PATH" git -C "$REPO_DIR" -c alias.p=push p origin feat
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"alias overrides are disabled"* ]]
  run env PATH="$dir:$PATH" git -C "$REPO_DIR" -c core.quotePath=false rev-parse HEAD
  [[ "$status" -eq 0 ]]
  rm -rf "$dir"
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
# End to end — the rebase intent in dev-lead-fix-reviews.sh
# ---------------------------------------------------------------------------

# _rebase_engine <stub_variant> <hl_variant>: what rebase.md asks for — rebase,
# resolve, continue, force-push (the push may be refused by the blocker).
_rebase_engine() {
  _engine "git fetch -q origin main
git rebase -q origin/main >/dev/null 2>&1 || true
$(declare -f _stub_body _hl_body)
_stub_body $1 > '$STUB'
_hl_body $2 > '$HL'
git add -A
GIT_EDITOR=true git rebase --continue >/dev/null 2>&1
git push -q --force-with-lease origin feat || echo 'engine push refused'"
}

_run_rebase() {
  git checkout -q main
  git branch -q -D feat
  run env PATH="$BIN:$PATH" INTENT_TYPE=rebase PR_NUMBER=42 HEAD_SHA="$PRE" HEAD_REF=feat BASE_REF=main \
    REPO=o/r REVIEW_ENGINE=claude DEV_LEAD_DRY_RUN=false PROMPTS_DIR="$SCRIPT_DIR/prompts/dev-lead" \
    REBASE_MERGE_STATE_POLL_SLEEP=0 bash "$HARNESS" 2>&1
}

@test "e2e rebase: a standards-sync PR whose stub is resolved to neither side is not pushed" {
  _mk_pr; _advance_main
  _e2e_stubs "$SYNC_PR_JSON"
  _rebase_engine mixed base
  _run_rebase
  [[ "$output" == *"engine push refused"* ]]
  [[ "$(_remote_feat)" == "$PRE" ]]
  grep -q 'The `rebase` pass changed' "$REC"
  grep -q 'dev-lead-sync-stub-drift pr=42 intent=rebase' "$REC"
  grep -q '^MERGE .*disable-auto' "$REC"
  run grep -q 'status=applied' "$REC"
  [[ "$status" -eq 1 ]]
}

@test "e2e rebase: a standards-sync PR resolved to the base template is pushed by the harness" {
  _mk_pr; _advance_main
  _e2e_stubs "$SYNC_PR_JSON"
  _rebase_engine base base
  _run_rebase
  [[ "$output" == *"engine push refused"* ]]
  [[ "$(_remote_feat)" != "$PRE" ]]
  [[ "$(git --git-dir="$REMOTE" show refs/heads/feat:"$STUB")" == "$(_stub_body base)" ]]
  git --git-dir="$REMOTE" merge-base --is-ancestor refs/heads/main refs/heads/feat
  run grep -q 'Declined' "$REC"
  [[ "$status" -eq 1 ]]
}

@test "e2e rebase: a PR without the label is rebased and pushed by the engine as today" {
  _mk_pr; _advance_main
  _e2e_stubs "$PLAIN_PR_JSON"
  _rebase_engine mixed mixed
  _run_rebase
  [[ "$output" != *"engine push refused"* ]]
  [[ "$(git --git-dir="$REMOTE" show refs/heads/feat:"$STUB")" == "$(_stub_body mixed)" ]]
  run grep -q 'Declined' "$REC"
  [[ "$status" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------

@test "Wiring: fix-ci sources the guard and evaluates it before push_with_merge_guard" {
  grep -q 'source "$(dirname "$0")/lib/sync-stub-guard.sh"' "$FIX_CI"
  local body
  body=$(awk '/^main\(\) \{/,/^}/' "$FIX_CI")
  local eval_line push_line
  eval_line=$(grep -n 'ssg_evaluate' <<<"$body" | head -1 | cut -d: -f1)
  push_line=$(grep -n 'push_with_merge_guard' <<<"$body" | tail -1 | cut -d: -f1)
  [[ -n "$eval_line" && -n "$push_line" ]]
  (( eval_line < push_line ))
}

@test "Wiring: the rebase prompt declares the deferred-push note" {
  grep -q 'REBASE_PUSH_NOTE' "$SCRIPT_DIR/prompts/dev-lead/rebase.md"
  head -1 "$SCRIPT_DIR/prompts/dev-lead/rebase.md" | grep -q 'REBASE_PUSH_NOTE'
}
