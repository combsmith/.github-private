#!/usr/bin/env bats
# Unit + end-to-end tests: the sync-stub guard (#2185) for rebase passes (#2232).
#
# A rebase pass resolves conflicts and the engine pushes the branch itself. On a
# `standards-sync` PR the resolution can leave a synced stub in a third state:
# equal neither to what the PR had nor to what the base branch has. The PR then
# no longer matches the template it syncs. The design (maintainer, 2026-10-10)
# leaves the engine and its push alone: record each synced path before the pass,
# compare after the push, and restore a third-state path in a follow-up commit
# (base content wins when the base changed the path since the old merge base).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/sync-stub-guard.sh"
HARNESS="$SCRIPT_DIR/scripts/dev-lead-fix-reviews.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

STUB=".github/workflows/persona-mention.yml"
TPL="standards/workflows/persona-mention.yml"
HL=".github/workflows/dev-lead.yml"
CI_STUB=".github/workflows/ci.yml"

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

_blob() { git rev-parse -q --verify "$1" 2>/dev/null || echo "-"; }

# _mk_pr: main holds a README and a header stub the PR never touches (ci.yml);
# the PR branch `feat` carries the sync commit that writes the persona-mention
# stub, the header-less dev-lead.yml and a docs file. A bare origin holds both.
# MB is the old merge base, PRE the PR head before the pass. (scripts/ exists so
# the rebase arm's duplicate-declaration gate has a directory to scan.)
_mk_pr() {
  REPO_DIR="$BATS_TEST_TMPDIR/repo"
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  git init -q -b main "$REPO_DIR"
  cd "$REPO_DIR"
  mkdir -p .github/workflows scripts prompts
  printf '#!/usr/bin/env bash\necho ok\n' > scripts/ok.sh
  printf 'line1\nline2\n' > README.md
  printf '# SOURCE OF TRUTH: petry-projects/.github/standards/workflows/ci.yml\nname: ci\n' > "$CI_STUB"
  git add -A; git commit -q -m base
  MB="$(git rev-parse HEAD)"
  git checkout -q -b feat
  _stub_body sync > "$STUB"
  _hl_body sync > "$HL"
  mkdir -p docs; echo "synced" > docs/sync.md
  git add -A; git commit -q -m "chore: sync 2 org-standard workflow stub(s)"
  PRE="$(git rev-parse HEAD)"
  git checkout -q main
  git init -q --bare "$REMOTE"
  git remote add origin "file://$REMOTE"
  git push -q origin main feat
  git fetch -q origin
}

# _main_moves [stub_variant]: the base branch advances; with an argument it also
# changes the persona-mention stub (so base content must win).
_main_moves() {
  git checkout -q main
  printf 'line1\nmain\n' > README.md
  if [[ -n "${1:-}" ]]; then
    mkdir -p .github/workflows
    _stub_body "$1" > "$STUB"
  fi
  git add -A; git commit -q -m "main moves"
  git push -q origin main
  git fetch -q origin
}

# _rebased <cmd>: a rebased head — origin/main plus the PR's tree, then <cmd>
# (the resolution's damage) — checked out as `rebased`.
_rebased() {
  git checkout -q -B rebased origin/main
  git checkout -q "$PRE" -- "$STUB" "$HL" docs/sync.md
  [[ -n "${1:-}" ]] && eval "$1"
  git add -A; git commit -q --allow-empty -m "rebased"
}

# ---------------------------------------------------------------------------
# ssg_rebase_action — pure decision over four blob ids ("-" = absent)
# ---------------------------------------------------------------------------

@test "ssg_rebase_action: head equal to the pre-pass blob or to the base is kept" {
  run ssg_rebase_action P M B P
  [[ "$output" == "keep" ]]
  run ssg_rebase_action P M B B
  [[ "$output" == "keep" ]]
  run ssg_rebase_action - M - -
  [[ "$output" == "keep" ]]
}

@test "ssg_rebase_action: a third state takes the base when the base changed the path, else the pre-pass blob" {
  run ssg_rebase_action P M B X
  [[ "$output" == "base" ]]
  run ssg_rebase_action P M M X
  [[ "$output" == "pre" ]]
  # The base deleted the path since the merge base: the deletion wins.
  run ssg_rebase_action P M - X
  [[ "$output" == "base" ]]
  # The resolution deleted a path the base left alone: restore the PR's blob.
  run ssg_rebase_action P M M -
  [[ "$output" == "pre" ]]
  # The PR deleted it, the resolution brought it back with other content.
  run ssg_rebase_action - M M X
  [[ "$output" == "pre" ]]
}

# ---------------------------------------------------------------------------
# ssg_rebase_record — the synced paths and their blobs before the pass
# ---------------------------------------------------------------------------

@test "ssg_rebase_record: records header stubs and every path the PR changed, with pre and merge-base blobs" {
  _mk_pr
  run ssg_rebase_record "$PRE" "$MB"
  [[ "$status" -eq 0 ]]
  # The PR's header stub, with its template.
  grep -qxF "${STUB}"$'\t'"$(_blob "${PRE}:${STUB}")"$'\t-\t'"${TPL}" <<<"$output"
  # A header stub the PR never touched is synced content too.
  grep -qxF "${CI_STUB}"$'\t'"$(_blob "${PRE}:${CI_STUB}")"$'\t'"$(_blob "${MB}:${CI_STUB}")"$'\tstandards/workflows/ci.yml' <<<"$output"
  # Header-less paths the PR changed carry no template (an empty last column).
  grep -qxF "${HL}"$'\t'"$(_blob "${PRE}:${HL}")"$'\t-\t' <<<"$output"
  grep -qxF "docs/sync.md"$'\t'"$(_blob "${PRE}:docs/sync.md")"$'\t-\t' <<<"$output"
  # An ordinary file the PR did not change is not recorded.
  run grep -q '^README.md' <<<"$output"
  [[ "$status" -eq 1 ]]
}

@test "ssg_rebase_record: an unresolvable pre-pass head or merge base -> rc 2, nothing recorded" {
  _mk_pr
  run ssg_rebase_record "" "$MB"
  [[ "$status" -eq 2 ]]
  [[ -z "$output" ]]
  run ssg_rebase_record "$PRE" "0000000000000000000000000000000000000000"
  [[ "$status" -eq 2 ]]
  [[ -z "$output" ]]
}

# ---------------------------------------------------------------------------
# ssg_rebase_restore — compare at the new head, restore a third state
# ---------------------------------------------------------------------------

@test "ssg_rebase_restore: a third-state stub the base left alone is restored to the pre-pass content" {
  _mk_pr
  local rec; rec=$(ssg_rebase_record "$PRE" "$MB")
  _main_moves
  _rebased "sed -i 's/@v1\$/@0123456789abcdef0123456789abcdef01234567/' '$STUB'"
  run ssg_rebase_restore "$rec" "$PRE" origin/main
  [[ "$status" -eq 0 ]]
  [[ "$output" == "restored"$'\t'"${STUB}"$'\tpre\t'"${TPL}" ]]
  # Restored in the worktree and the index.
  [[ "$(git hash-object "$STUB")" == "$(_blob "${PRE}:${STUB}")" ]]
  [[ "$(git ls-files -s -- "$STUB" | awk '{print $2}')" == "$(_blob "${PRE}:${STUB}")" ]]
}

@test "ssg_rebase_restore: when the base changed the path since the merge base, the base content wins" {
  _mk_pr
  local rec; rec=$(ssg_rebase_record "$PRE" "$MB")
  _main_moves main
  _rebased "_stub_body resolved > '$STUB'"
  run ssg_rebase_restore "$rec" "$PRE" origin/main
  [[ "$status" -eq 0 ]]
  [[ "$output" == "restored"$'\t'"${STUB}"$'\tbase\t'"${TPL}" ]]
  [[ "$(git hash-object "$STUB")" == "$(_blob "origin/main:${STUB}")" ]]
}

@test "ssg_rebase_restore: a header-less synced path in a third state is restored; a deletion matching the base is kept" {
  _mk_pr
  local rec; rec=$(ssg_rebase_record "$PRE" "$MB")
  _main_moves
  # dev-lead.yml is resolved to new content; docs/sync.md is dropped, which
  # equals the base (main never had it) and so is left alone.
  _rebased "_hl_body resolved > '$HL'; git rm -q -f docs/sync.md"
  run ssg_rebase_restore "$rec" "$PRE" origin/main
  [[ "$output" == "restored"$'\t'"${HL}"$'\tpre\t' ]]
  [[ "$(git hash-object "$HL")" == "$(_blob "${PRE}:${HL}")" ]]
  [[ ! -e docs/sync.md ]]
}

@test "ssg_rebase_restore: paths equal to the pre-pass content or to the base are left alone" {
  _mk_pr
  local rec; rec=$(ssg_rebase_record "$PRE" "$MB")
  _main_moves main
  # The stub takes main's content, everything else keeps the PR's content.
  _rebased "git checkout -q origin/main -- '$STUB'"
  local before; before=$(git rev-parse HEAD)
  run ssg_rebase_restore "$rec" "$PRE" origin/main
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
  [[ -z "$(git status --porcelain)" ]]
  [[ "$(git rev-parse HEAD)" == "$before" ]]
}

@test "ssg_rebase_restore: a recorded blob that is missing cannot be restored -> failed" {
  _mk_pr
  _main_moves
  _rebased "sed -i 's/@v1\$/@deadbeef/' '$STUB'"
  local rec="${STUB}"$'\t'"1111111111111111111111111111111111111111"$'\t-\t'"${TPL}"
  run ssg_rebase_restore "$rec" "$PRE" origin/main
  [[ "$status" -eq 0 ]]
  [[ "$output" == "failed"$'\t'"${STUB}"$'\tpre\t'"${TPL}" ]]
}

@test "ssg_rebase_restore: an unresolvable base -> rc 2" {
  _mk_pr
  local rec; rec=$(ssg_rebase_record "$PRE" "$MB")
  run ssg_rebase_restore "$rec" "$PRE" origin/nope
  [[ "$status" -eq 2 ]]
  [[ -z "$output" ]]
}

# ---------------------------------------------------------------------------
# Comment bodies (pure)
# ---------------------------------------------------------------------------

@test "ssg_rebase_restored_body: names each restored path and where its content came from" {
  run ssg_rebase_restored_body "restored"$'\t'"${STUB}"$'\tpre\t'"${TPL}"$'\n'"restored"$'\t'"${HL}"$'\tbase'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"\`${STUB}\`"* ]]
  [[ "$output" == *"\`${HL}\`"* ]]
  [[ "$output" == *"before the rebase"* ]]
  [[ "$output" == *"base branch"* ]]
}

@test "ssg_rebase_unrestored_body: says the branch was pushed and names each path and template" {
  run ssg_rebase_unrestored_body "${STUB}"$'\t'"${TPL}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"\`${STUB}\`"* ]]
  [[ "$output" == *"blob/main/${TPL}"* ]]
  [[ "$output" == *"**was** pushed"* ]]
  [[ "$output" != *"did not push"* ]]
  run ssg_rebase_unrestored_body ""
  [[ "$output" == *"could not be verified"* ]]
  [[ "$output" == *"**was** pushed"* ]]
}

# ---------------------------------------------------------------------------
# End to end — dev-lead-fix-reviews.sh, INTENT_TYPE=rebase
# ---------------------------------------------------------------------------

# _e2e_stubs <pr_json|UNREADABLE>: a gh stub that records comments, label adds
# and merge calls; `gh pr checkout` checks feat out against origin.
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

# _engine <damage>: the claude stub rebases feat onto origin/main, applies
# <damage> as the "resolution", and force-pushes the branch itself, as the
# rebase prompt tells the model to. It records the SHA it pushed.
_engine() {
  ENGINE_PUSHED="$BATS_TEST_TMPDIR/engine_pushed"
  cat > "$BIN/claude" <<EOF
#!/usr/bin/env bash
echo "engine ran"
git fetch -q origin main
git rebase -q -X theirs origin/main >/dev/null 2>&1 || exit 1
$1
git add -A
git commit -q -m "chore: resolve" || true
git push -q --force origin HEAD:feat || exit 1
git rev-parse HEAD > "$ENGINE_PUSHED"
EOF
  chmod +x "$BIN/claude"
}

_run_rebase() {
  run env PATH="$BIN:$PATH" INTENT_TYPE=rebase PR_NUMBER=42 HEAD_SHA="$PRE" HEAD_REF=feat \
    BASE_REF=main REPO=o/r REVIEW_ENGINE=claude DEV_LEAD_DRY_RUN=false \
    REBASE_MERGE_STATE_POLL_SLEEP=0 PROMPTS_DIR="$SCRIPT_DIR/prompts/dev-lead" \
    bash "$HARNESS" 2>&1
}

_remote_feat() { git --git-dir="$REMOTE" rev-parse refs/heads/feat; }
_remote_blob() { git --git-dir="$REMOTE" rev-parse -q --verify "refs/heads/feat:$1" 2>/dev/null || echo "-"; }

PIN="sed -i 's/@v1\$/@0123456789abcdef0123456789abcdef01234567/' '$STUB'"

@test "e2e rebase: a standards-sync PR whose resolution leaves a stub in a third state gets a restore commit and one comment" {
  _mk_pr
  _main_moves
  _e2e_stubs "$SYNC_PR_JSON"
  _engine "$PIN"
  _run_rebase
  # The engine pushed its rebase; the harness pushed one follow-up commit on top.
  [[ "$(git --git-dir="$REMOTE" rev-parse refs/heads/feat~1)" == "$(cat "$ENGINE_PUSHED")" ]]
  [[ "$(_remote_blob "$STUB")" == "$(_blob "${PRE}:${STUB}")" ]]
  [[ "$(git --git-dir="$REMOTE" log -1 --format=%s refs/heads/feat)" == *"restore synced"* ]]
  [[ "$(grep -c 'dev-lead-sync-stub-restore' "$REC")" -eq 1 ]]
  grep -q "\`${STUB}\`" "$REC"
  # Restored cleanly: no hold.
  run grep -q '^LABEL .*needs-human-review' "$REC"
  [[ "$status" -eq 1 ]]
  run grep -q 'dev-lead-sync-stub-drift' "$REC"
  [[ "$status" -eq 1 ]]
}

@test "e2e rebase: base content wins when the base changed the stub" {
  _mk_pr
  _main_moves main
  _e2e_stubs "$SYNC_PR_JSON"
  _engine "printf '# SOURCE OF TRUTH: petry-projects/.github/standards/workflows/persona-mention.yml\\nname: hand-merged\\n' > '$STUB'"
  _run_rebase
  [[ "$(_remote_blob "$STUB")" == "$(_blob "origin/main:${STUB}")" ]]
  grep -q 'dev-lead-sync-stub-restore' "$REC"
}

@test "e2e rebase: a resolution that keeps every synced path is pushed as today, no extra commit or comment" {
  _mk_pr
  _main_moves
  _e2e_stubs "$SYNC_PR_JSON"
  _engine ":"
  _run_rebase
  [[ "$(_remote_feat)" == "$(cat "$ENGINE_PUSHED")" ]]
  run grep -q 'dev-lead-sync-stub' "$REC"
  [[ "$status" -eq 1 ]]
}

@test "e2e rebase: the same damage on a PR without the label runs as today — no extra push, hold or comment" {
  _mk_pr
  _main_moves
  _e2e_stubs "$PLAIN_PR_JSON"
  _engine "$PIN"
  _run_rebase
  [[ "$(_remote_feat)" == "$(cat "$ENGINE_PUSHED")" ]]
  run grep -q 'dev-lead-sync-stub' "$REC"
  [[ "$status" -eq 1 ]]
  run grep -q '^LABEL .*needs-human-review' "$REC"
  [[ "$status" -eq 1 ]]
}

@test "e2e rebase: an unreadable PR runs as today — no extra push, hold or comment" {
  _mk_pr
  _main_moves
  _e2e_stubs "UNREADABLE"
  _engine "$PIN"
  _run_rebase
  [[ "$(_remote_feat)" == "$(cat "$ENGINE_PUSHED")" ]]
  run grep -q 'dev-lead-sync-stub' "$REC"
  [[ "$status" -eq 1 ]]
  run grep -q '^LABEL .*needs-human-review' "$REC"
  [[ "$status" -eq 1 ]]
}

@test "e2e rebase: a refused restore push flags the PR and says the branch was pushed" {
  _mk_pr
  _main_moves
  _e2e_stubs "$SYNC_PR_JSON"
  _engine "$PIN"
  # The remote refuses the harness's restore commit (but not the engine's push).
  cat > "$REMOTE/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r _old new _ref; do
  git log -1 --format=%s "$new" | grep -q 'restore synced' && { echo "refused" >&2; exit 1; }
done
exit 0
HOOK
  chmod +x "$REMOTE/hooks/pre-receive"
  _run_rebase
  [[ "$(_remote_feat)" == "$(cat "$ENGINE_PUSHED")" ]]
  grep -q 'dev-lead-sync-stub-drift pr=42 intent=rebase' "$REC"
  grep -q '\*\*was\*\* pushed' "$REC"
  grep -q "\`${STUB}\`" "$REC"
  grep -q '^LABEL .*needs-human-review' "$REC"
  grep -q '^MERGE .*disable-auto' "$REC"
  run grep -q 'did not push' "$REC"
  [[ "$status" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# Wiring: the engine's push is never blocked, shimmed or deferred
# ---------------------------------------------------------------------------

@test "Wiring: the rebase arm records before the engine and restores after its push, with no push shim" {
  local body
  body=$(awk '/^  rebase\)$/,/^    ;;$/' "$HARNESS")
  [[ -n "$body" ]]
  local rec eng push restore
  rec=$(grep -n 'rebase_record_synced_stubs' <<<"$body" | head -1 | cut -d: -f1)
  eng=$(grep -n 'build_and_run "rebase"' <<<"$body" | head -1 | cut -d: -f1)
  push=$(grep -n 'commit_and_push "rebase"' <<<"$body" | head -1 | cut -d: -f1)
  restore=$(grep -n 'rebase_restore_synced_stubs' <<<"$body" | head -1 | cut -d: -f1)
  [[ -n "$rec" && -n "$eng" && -n "$push" && -n "$restore" ]]
  (( rec < eng && push < restore ))
  # Nothing is put on the engine's PATH and nothing intercepts its push.
  run grep -nE 'PATH=|push_blocker|ssg_install' <<<"$body"
  [[ "$status" -eq 1 ]]
  run grep -nE 'push_blocker|ssg_install' "$LIB"
  [[ "$status" -eq 1 ]]
}

@test "ssg_rebase_record: a header stub added on the base after the merge base is recorded when base_rev is given" {
  _mk_pr
  git checkout -q main
  printf '# SOURCE OF TRUTH: petry-projects/.github/standards/workflows/new.yml\nname: new\n' > .github/workflows/new.yml
  git add -A; git commit -q -m "main adds stub"; git push -q origin main; git fetch -q origin
  run ssg_rebase_record "$PRE" "$MB"
  run grep -q 'new.yml' <<<"$output"
  [[ "$status" -eq 1 ]]
  run ssg_rebase_record "$PRE" "$MB" origin/main
  [[ "$status" -eq 0 ]]
  grep -qxF ".github/workflows/new.yml"$'\t-\t-\tstandards/workflows/new.yml' <<<"$output"
}
