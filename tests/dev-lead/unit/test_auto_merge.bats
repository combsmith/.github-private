#!/usr/bin/env bats
# Unit tests for scripts/lib/auto-merge.sh
#
# Covers holding auto-merge OFF while dev-lead works a PR, restoring it on exit,
# and the push guard that treats a mid-run merge as a benign no-op rather than a
# red-X failure (see run 27078382804).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/auto-merge.sh"

setup() {
  STUB_BIN_DIR="$(mktemp -d)"
  export PATH="$STUB_BIN_DIR:$PATH"
  export GH_CALLS="$(mktemp)"
  export PR_NUMBER=77 REPO="owner/repo" DEV_LEAD_DRY_RUN=false
  # Exported so the gh stub subprocess sees them; tests reassign (export sticks).
  export AM_STATE="" PR_STATE="open" GH_MERGE_RC=0
  export AM_COMMIT_TITLE="" AM_COMMIT_MESSAGE="" HEAD_SHA_API=""

  # gh stub: AM_STATE / PR_STATE / GH_MERGE_RC are read at call time so each
  # test can set the PR's auto-merge state, open/closed state, and merge rc.
  # commit_title / commit_message / head.sha cases must come before the generic
  # *auto_merge* catch-all since those jq filters also contain "auto_merge".
  cat > "$STUB_BIN_DIR/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${GH_CALLS:-/dev/null}"
case "$*" in
  *"pr merge"*)            exit "${GH_MERGE_RC:-0}" ;;
  *"commit_title"*)        printf '%s' "${AM_COMMIT_TITLE:-}" ;;
  *"commit_message"*)      printf '%s' "${AM_COMMIT_MESSAGE:-}" ;;
  *"head.sha"*)            printf '%s' "${HEAD_SHA_API:-}" ;;
  *auto_merge*)            printf '%s' "${AM_STATE:-}" ;;
  *".state"*)              printf '%s' "${PR_STATE:-open}" ;;
  *)                       echo "{}" ;;
esac
EOF
  chmod +x "$STUB_BIN_DIR/gh"
}

teardown() { rm -rf "$STUB_BIN_DIR" "$GH_CALLS"; }

# ── hold_auto_merge ───────────────────────────────────────────────────────────

@test "hold_auto_merge: disables auto-merge when it is currently on" {
  source "$LIB"
  AM_STATE="squash"
  run hold_auto_merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"holding auto-merge OFF"* ]]
  grep -q -- "pr merge 77 --repo owner/repo --disable-auto" "$GH_CALLS"
}

@test "hold_auto_merge: no-op (no disable) when auto-merge is already off" {
  source "$LIB"
  AM_STATE=""
  run hold_auto_merge
  [ "$status" -eq 0 ]
  ! grep -q -- "--disable-auto" "$GH_CALLS"
}

@test "hold_auto_merge: dry-run does not touch gh" {
  source "$LIB"
  export DEV_LEAD_DRY_RUN=true
  AM_STATE="enabled"
  run hold_auto_merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [ ! -s "$GH_CALLS" ]
}

# ── restore_auto_merge ────────────────────────────────────────────────────────

@test "restore_auto_merge: no-op when we never disabled auto-merge" {
  source "$LIB"
  _AM_NEEDS_RESTORE=0
  run restore_auto_merge
  [ "$status" -eq 0 ]
  ! grep -q -- "--auto" "$GH_CALLS"
}

@test "restore_auto_merge: re-enables when we disabled it and the PR is still open" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="open"
  AM_STATE=""   # currently off (we disabled it)
  run restore_auto_merge
  [ "$status" -eq 0 ]
  grep -q -- "pr merge 77 --repo owner/repo --auto --squash" "$GH_CALLS"
}

@test "restore_auto_merge: re-enables with the original merge strategy, not always squash" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  _AM_MERGE_METHOD="merge"
  PR_STATE="open"
  AM_STATE=""   # currently off (we disabled it)
  run restore_auto_merge
  [ "$status" -eq 0 ]
  grep -q -- "pr merge 77 --repo owner/repo --auto --merge" "$GH_CALLS"
  ! grep -q -- "--squash" "$GH_CALLS"
}

@test "restore_auto_merge: re-enables with rebase strategy when originally set to rebase" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  _AM_MERGE_METHOD="rebase"
  PR_STATE="open"
  AM_STATE=""   # currently off (we disabled it)
  run restore_auto_merge
  [ "$status" -eq 0 ]
  grep -q -- "pr merge 77 --repo owner/repo --auto --rebase" "$GH_CALLS"
}

@test "restore_auto_merge: does NOT re-enable on a merged/closed PR" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="closed"
  run restore_auto_merge
  [ "$status" -eq 0 ]
  ! grep -q -- "--auto" "$GH_CALLS"
}

@test "restore_auto_merge: passes --match-head-commit when _AM_HEAD_SHA is set" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="open"
  AM_STATE=""
  _AM_HEAD_SHA="abc123"
  run restore_auto_merge
  [ "$status" -eq 0 ]
  grep -q -- "--match-head-commit abc123" "$GH_CALLS"
}

@test "restore_auto_merge: skips when auto-merge is already back on (success path)" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="open"
  AM_STATE="enabled"   # success path already re-enabled it
  run restore_auto_merge
  [ "$status" -eq 0 ]
  ! grep -q -- "--auto" "$GH_CALLS"
}

# ── push_with_merge_guard ─────────────────────────────────────────────────────

# The stale-base reconcile (incorporate_remote_head, #1607) has its own hermetic
# suite in test_incorporate_remote_head.bats. Neutralize it here so these tests
# stay focused on the merge-race / force-retry logic and never touch a real
# remote. _PUSH_GUARD_REMOTE_SHA/_BRANCH stay empty, so the force retry exercises
# the --force-with-lease --force-if-includes fallback.
_neutralize_incorporate() { incorporate_remote_head() { return 0; }; }

_install_git_stub() {  # $1 = push exit code
  cat > "$STUB_BIN_DIR/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = push ]; then
  echo "remote: rejected (stub)" >&2
  exit ${1:-0}
fi
exec /usr/bin/git "\$@"
EOF
  chmod +x "$STUB_BIN_DIR/git"
}

@test "push_with_merge_guard: returns 0 on a successful push" {
  source "$LIB"
  _neutralize_incorporate
  cat > "$STUB_BIN_DIR/git" <<'EOF'
#!/usr/bin/env bash
[ "$1" = push ] && exit 0
exec /usr/bin/git "$@"
EOF
  chmod +x "$STUB_BIN_DIR/git"
  run push_with_merge_guard
  [ "$status" -eq 0 ]
}

@test "push_with_merge_guard: exits 0 cleanly when the PR was merged/closed mid-run" {
  source "$LIB"
  _neutralize_incorporate
  _install_git_stub 1
  PR_STATE="closed"
  run push_with_merge_guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to push"* ]]
}

@test "push_with_merge_guard: returns 1 on a genuine push failure (PR still open)" {
  source "$LIB"
  _neutralize_incorporate
  _install_git_stub 1
  PR_STATE="open"
  run push_with_merge_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"git push failed"* ]]
}

@test "push_with_merge_guard: escalates (non-zero, no push) when reconcile stops on un-incorporable steering (#1607)" {
  source "$LIB"
  # incorporate_remote_head returns 2 = STOP/escalate; the guard must not push.
  incorporate_remote_head() { return 2; }
  cat > "$STUB_BIN_DIR/git" <<'EOF'
#!/usr/bin/env bash
[ "$1" = push ] && { echo "PUSHED" > "$STUB_BIN_DIR/pushed"; exit 0; }
exec /usr/bin/git "$@"
EOF
  chmod +x "$STUB_BIN_DIR/git"
  run push_with_merge_guard
  [ "$status" -eq 2 ]
  [ ! -f "$STUB_BIN_DIR/pushed" ]
}

@test "push_with_merge_guard: exits 0 cleanly when reconcile fails because the PR merged/closed mid-run (#1610)" {
  source "$LIB"
  # Reconcile cannot incorporate (return 2), but the PR was merged/closed in the
  # window — that is the benign merge race, not an escalation, so exit 0 without
  # pushing rather than failing the job.
  incorporate_remote_head() { return 2; }
  PR_STATE="closed"
  cat > "$STUB_BIN_DIR/git" <<'EOF'
#!/usr/bin/env bash
[ "$1" = push ] && { echo "PUSHED" > "$STUB_BIN_DIR/pushed"; exit 0; }
exec /usr/bin/git "$@"
EOF
  chmod +x "$STUB_BIN_DIR/git"
  run push_with_merge_guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to push"* ]]
  [ ! -f "$STUB_BIN_DIR/pushed" ]
}

# ── push_with_merge_guard — force-with-lease retry on rewritten history ────────

# git stub for the rebase/force-push path. $1 = "diverged" | "not-diverged"
# controls whether merge-base --is-ancestor reports the upstream as reachable
# from HEAD (i.e. whether history was rewritten). The plain push always reports a
# non-fast-forward rejection; the pinned force push (--force-with-lease…) succeeds.
_install_git_stub_force() {
  cat > "$STUB_BIN_DIR/git" <<EOF
#!/usr/bin/env bash
case "\$1" in
  push)
    shift
    for a in "\$@"; do
      case "\$a" in --force-with-lease*) exit 0 ;; esac
    done
    echo "  ! [rejected]        feature -> feature (non-fast-forward)" >&2
    exit 1
    ;;
  rev-parse)
    case "\$*" in
      *"@{u}"*) echo "origin/feature" ;;
      *)        echo "deadbeefcafe" ;;
    esac
    exit 0
    ;;
  merge-base)
    # --is-ancestor <upstream> HEAD: 0 = upstream reachable (not diverged),
    # 1 = diverged (history rewritten by a rebase).
    [ "${1:-}" = "diverged" ] && exit 1 || exit 0
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN_DIR/git"
}

@test "push_with_merge_guard: pinned force retry succeeds when history was rewritten (rebase)" {
  source "$LIB"
  _neutralize_incorporate
  _install_git_stub_force diverged
  PR_STATE="open"
  run push_with_merge_guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"pinned lease"* ]]
}

@test "push_with_merge_guard: does NOT force-push when branch is not diverged (remote advanced legitimately)" {
  source "$LIB"
  _neutralize_incorporate
  _install_git_stub_force not-diverged
  PR_STATE="open"
  run push_with_merge_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"git push failed"* ]]
  [[ "$output" != *"pinned lease"* ]]
}

# ── hold_auto_merge — commit text capture ─────────────────────────────────────

@test "hold_auto_merge: captures commit title and message when auto-merge is on" {
  source "$LIB"
  AM_STATE="squash"
  export AM_COMMIT_TITLE="My PR title"
  export AM_COMMIT_MESSAGE="My PR body"
  hold_auto_merge
  [ "${_AM_COMMIT_TITLE}" = "My PR title" ]
  [ "${_AM_COMMIT_MESSAGE}" = "My PR body" ]
}

@test "hold_auto_merge: captures PR head SHA into _AM_HEAD_SHA at hold time" {
  source "$LIB"
  AM_STATE="squash"
  export HEAD_SHA_API="deadbeef1234"
  hold_auto_merge
  [ "${_AM_HEAD_SHA}" = "deadbeef1234" ]
}

# ── restore_auto_merge — HEAD_SHA refresh and commit text replay ──────────────

@test "restore_auto_merge: matches the freshly-fetched current head over the hold-time SHA" {
  # The head can advance during the run (own commits, or the rebase engine's
  # direct force-push that bypasses push_with_merge_guard). Restore must match
  # the CURRENT head, not the SHA captured at hold time, or GitHub rejects it.
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="open"
  AM_STATE=""
  _AM_HEAD_SHA="hold_time_sha"
  export HEAD_SHA_API="current_head_sha"   # PR head advanced since hold
  run restore_auto_merge
  [ "$status" -eq 0 ]
  grep -q -- "--match-head-commit current_head_sha" "$GH_CALLS"
  ! grep -q -- "--match-head-commit hold_time_sha" "$GH_CALLS"
}

@test "restore_auto_merge: falls back to the hold-time SHA when the current-head re-fetch fails" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="open"
  AM_STATE=""
  _AM_HEAD_SHA="hold_time_sha"
  export HEAD_SHA_API=""    # re-fetch returns empty
  run restore_auto_merge
  [ "$status" -eq 0 ]
  grep -q -- "--match-head-commit hold_time_sha" "$GH_CALLS"
}

@test "restore_auto_merge: uses held-head SHA, not stale event-payload HEAD_SHA" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="open"
  AM_STATE=""
  _AM_HEAD_SHA="held_sha"
  export HEAD_SHA="stale_event_sha"
  run restore_auto_merge
  [ "$status" -eq 0 ]
  grep -q -- "--match-head-commit held_sha" "$GH_CALLS"
  ! grep -q -- "--match-head-commit stale_event_sha" "$GH_CALLS"
}

@test "restore_auto_merge: passes --subject and --body when commit text was captured" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="open"
  AM_STATE=""
  _AM_COMMIT_TITLE="Custom title"
  _AM_COMMIT_MESSAGE="Custom body"
  run restore_auto_merge
  [ "$status" -eq 0 ]
  grep -q -- "pr merge.*--subject" "$GH_CALLS"
  grep -q -- "pr merge.*--body" "$GH_CALLS"
}

@test "restore_auto_merge: omits --subject and --body when no custom commit text" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="open"
  AM_STATE=""
  run restore_auto_merge
  [ "$status" -eq 0 ]
  ! grep -q -- "--subject" "$GH_CALLS" || false
  ! grep -q -- "--body" "$GH_CALLS"
}

# ── hold_auto_merge — disable-auto failure race handling ──────────────────────

@test "hold_auto_merge: exits 0 cleanly when disable-auto fails because PR was already merged" {
  source "$LIB"
  AM_STATE="squash"
  GH_MERGE_RC=1    # --disable-auto fails
  PR_STATE="closed" # PR was merged in the race window
  run hold_auto_merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged/closed before hold could be set"* ]]
}

@test "hold_auto_merge: exits 1 (aborts) when disable-auto fails and PR is still open" {
  source "$LIB"
  AM_STATE="squash"
  GH_MERGE_RC=1    # --disable-auto fails
  PR_STATE="open"  # PR is still open — cannot safely continue with auto-merge enabled
  run hold_auto_merge
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not disable auto-merge"* ]]
}

# ── push_with_merge_guard — HEAD SHA refresh after push ───────────────────────

@test "push_with_merge_guard: updates _AM_HEAD_SHA to new HEAD after successful push" {
  source "$LIB"
  cat > "$STUB_BIN_DIR/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  push)       exit 0 ;;
  rev-parse)  echo "newsha456" ;;
  *)          exec /usr/bin/git "$@" ;;
esac
EOF
  chmod +x "$STUB_BIN_DIR/git"
  _AM_HEAD_SHA="oldsha123"
  push_with_merge_guard
  [ "${_AM_HEAD_SHA}" = "newsha456" ]
}
