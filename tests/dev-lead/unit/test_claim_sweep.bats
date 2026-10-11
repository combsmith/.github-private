#!/usr/bin/env bats
# Harness tests for the dev-lead claim sweeps (#2032, follow-up to #2013).
#
# #2013's sweep retracted a "Fixed" reply only when the pass that posted it reached
# the sweep, and only against the SHA the model cited. Two gaps followed:
#   1. A run cancelled or killed after the model replied (a concurrency cancel, a
#      lost runner, a budget kill) left its false "Fixed" replies up: the next
#      pass selected only replies created after ITS start (#2080: commit 9313650
#      never reached the branch; the claim stood for 15 minutes).
#   2. When the push guard rebased dev-lead's commits onto a foreign commit, the
#      cited pre-rebase SHAs existed nowhere on the remote, so every true claim
#      was retracted and its thread could not recover on its own.
#
# These tests run the real sweep_earlier_claims / retract_unlanded_claims bodies
# from dev-lead-fix-reviews.sh against a local bare remote, with a gh stub that
# serves the PR's review comments and records each PATCH. No live GitHub.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
FIX_REVIEWS_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-fix-reviews.sh"
LIB_DIR="$SCRIPT_DIR/scripts/lib"

FINDING_AT="2026-10-02T00:00:00Z"
PASS_AT="2026-10-09T03:00:00Z"

setup() {
  export BOT_USER="donpetry-bot" PR_NUMBER=54 REPO="petry-projects/.github-private"
  export DEV_LEAD_DRY_RUN=false BASE_REF=main PASS_START_ISO="$PASS_AT"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  : > "$GITHUB_STEP_SUMMARY"

  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  WORK="$BATS_TEST_TMPDIR/work"
  COMMENTS="$BATS_TEST_TMPDIR/comments.json"
  PATCHES="$BATS_TEST_TMPDIR/patches"
  mkdir -p "$PATCHES"
  echo '[]' > "$COMMENTS"

  git init -q --bare "$REMOTE"
  local seed="$BATS_TEST_TMPDIR/seed"
  git init -q "$seed"
  (
    cd "$seed"
    _dev_identity
    # The base branch, then the PR's first commit on top of it (not a root commit).
    echo base > README; git add README
    GIT_COMMITTER_DATE="2026-09-01T00:00:00Z" GIT_AUTHOR_DATE="2026-09-01T00:00:00Z" \
      git commit -q -m "chore: base"
    echo A > f
    git add f
    GIT_COMMITTER_DATE="2026-10-01T00:00:00Z" GIT_AUTHOR_DATE="2026-10-01T00:00:00Z" \
      git commit -q -m "feat: first commit of the PR"
    git branch -M main
    git remote add origin "$REMOTE"
    git push -q -u origin main
  )
  git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main
  git clone -q "$REMOTE" "$WORK"
  ( cd "$WORK"; _dev_identity )
  FIRST_SHA=$(git --git-dir="$REMOTE" rev-parse main)

  STUB_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN_DIR"
  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"-X PATCH"*)
    id=""; body=""
    for a in "\$@"; do
      case "\$a" in
        *pulls/comments/*) id="\${a##*/}" ;;
        body=*) body="\${a#body=}" ;;
      esac
    done
    printf '%s' "\$body" > "$PATCHES/\$id"
    echo '{}'
    ;;
  *"pulls/54/comments"*) cat "$COMMENTS" ;;
  # github_knows_commit: GH_KNOWN_COMMIT was pushed; GH_COMMITS_ERROR fails the lookup.
  *"/commits/"*)
    all="\$*"; sha="\${all##*/commits/}"; sha="\${sha%% *}"
    if [ -n "\${GH_COMMITS_ERROR:-}" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
    if [ "\$sha" = "\${GH_KNOWN_COMMIT:-}" ]; then echo "\$sha"; exit 0; fi
    echo "gh: No commit found for SHA: \$sha (HTTP 422)" >&2; exit 1
    ;;
  *) echo '{}' ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export PATH="$STUB_BIN_DIR:$PATH"

  # shellcheck source=/dev/null
  source "$LIB_DIR/addressed-claim-verify.sh"
  source "$LIB_DIR/claim-landing.sh"
  source "$LIB_DIR/git-push-guard.sh"
  source "$LIB_DIR/git-history.sh"
  eval "$(sed -n '/^github_knows_commit()/,/^}/p' "$FIX_REVIEWS_SCRIPT")"
  eval "$(sed -n '/^sweep_earlier_claims()/,/^}/p' "$FIX_REVIEWS_SCRIPT")"
  eval "$(sed -n '/^retract_unlanded_claims()/,/^}/p' "$FIX_REVIEWS_SCRIPT")"
  declare -F sweep_earlier_claims >/dev/null
  declare -F retract_unlanded_claims >/dev/null

  cd "$WORK"
  RESOLUTION_BASE_SHA=$(git rev-parse HEAD)
  export RESOLUTION_BASE_SHA
}

_dev_identity() {
  git config user.email "12345+donpetry-bot@users.noreply.github.com"
  git config user.name "donpetry-bot"
}

# A commit by another actor, pushed straight to the remote branch.
_foreign_push() {
  local file="$1" content="$2" other="$BATS_TEST_TMPDIR/other.$RANDOM"
  git clone -q "$REMOTE" "$other"
  (
    cd "$other"
    git config user.email "auto-rebase@example.com"; git config user.name "auto-rebase"
    printf '%s\n' "$content" > "$file"; git add "$file"; git commit -q -m "foreign: $file"
    git push -q origin main
  )
}

# _reply <id> <created_at> <body> — one of OUR replies to finding 100.
_reply() {
  jq -c -n --argjson id "$1" --arg at "$2" --arg body "$3" \
    '{id: $id, user: {login: "donpetry-bot"}, created_at: $at, in_reply_to_id: 100, body: $body}'
}

_claim() {
  # _claim <sha> [file] — the addressed reply the model posts.
  printf 'Fixed in %s: handled the empty case.\n\n<!-- dev-lead:addressed -->\n<!-- dev-lead:claim {"v":1,"sha":"%s","files":["%s"]} -->' \
    "${2:-f}" "$1" "${2:-f}"
}

# _serve <reply_json>... — the PR's review comments: finding 100 plus our replies.
_serve() {
  local finding
  finding=$(jq -c -n --arg at "$FINDING_AT" \
    '{id: 100, user: {login: "coderabbitai[bot]"}, created_at: $at, body: "Potential issue: empty input crashes."}')
  printf '%s\n' "$finding" "$@" | jq -s -c . > "$COMMENTS"
}

# A dev-lead fix to f committed at <date> and pushed by an earlier pass.
_landed_fix() {
  echo "fixed" > f; git add f
  GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" git commit -q -m "fix(reviews): address review comments"
  git push -q origin main
  RESOLUTION_BASE_SHA=$(git rev-parse HEAD)
  git rev-parse HEAD
}

# ---------------------------------------------------------------------------
# AC1: earlier passes are swept, before this pass posts anything
# ---------------------------------------------------------------------------

@test "#2032 AC1: an earlier pass's reply whose commit never landed is retracted" {
  # The #2080 shape: a cancelled run cited 9313650…, which never reached the branch.
  local ghost="931365099bfb2c283aecfb16b0f5f0b8d59436b2"
  _serve "$(_reply 201 "2026-10-09T02:42:00Z" "$(_claim "$ghost")")"

  run sweep_earlier_claims
  [ "$status" -eq 0 ]
  [ -f "$PATCHES/201" ]
  grep -q "Retracted" "$PATCHES/201"
  grep -q "<!-- dev-lead:retracted reason=not-on-ref -->" "$PATCHES/201"
  ! grep -q "dev-lead:addressed" "$PATCHES/201"
  # The original claim is kept (not as a claim) so a later pass can re-verify it.
  grep -q "dev-lead:retracted-claim .*${ghost}" "$PATCHES/201"
}

@test "#2032 AC1: an earlier reply whose commit GitHub knows (pushed, then rewritten) is kept" {
  local ghost="931365099bfb2c283aecfb16b0f5f0b8d59436b2"
  export GH_KNOWN_COMMIT="$ghost"
  _serve "$(_reply 201 "2026-10-09T02:42:00Z" "$(_claim "$ghost")")"

  run sweep_earlier_claims
  [ "$status" -eq 0 ]
  [ ! -f "$PATCHES/201" ]
  [[ "$output" == *"pushed, then rewritten"* ]]
}

@test "#2032 AC1: a failed GitHub commit lookup retracts nothing" {
  local ghost="931365099bfb2c283aecfb16b0f5f0b8d59436b2"
  export GH_COMMITS_ERROR=1
  _serve "$(_reply 201 "2026-10-09T02:42:00Z" "$(_claim "$ghost")")"

  run sweep_earlier_claims
  [ "$status" -eq 0 ]
  [ ! -f "$PATCHES/201" ]
}

@test "#2032 AC1: an earlier pass's reply whose commit landed and touches its files is left alone" {
  local fix
  fix=$(_landed_fix "2026-10-05T00:00:00Z")
  _serve "$(_reply 202 "2026-10-05T00:01:00Z" "$(_claim "$fix")")"

  run sweep_earlier_claims
  [ "$status" -eq 0 ]
  [ ! -f "$PATCHES/202" ]
}

@test "#2032 AC1: an earlier reply whose landed commit does not touch its claimed files is retracted" {
  local fix
  fix=$(_landed_fix "2026-10-05T00:00:00Z")
  _serve "$(_reply 203 "2026-10-05T00:01:00Z" "$(_claim "$fix" other.txt)")"

  run sweep_earlier_claims
  [ -f "$PATCHES/203" ]
  grep -q "reason=no-file-intersection" "$PATCHES/203"
}

@test "#2032 AC1: replies created during THIS pass are not the earlier sweep's to touch" {
  local ghost="931365099bfb2c283aecfb16b0f5f0b8d59436b2"
  _serve "$(_reply 204 "2026-10-09T03:00:05Z" "$(_claim "$ghost")")"

  run sweep_earlier_claims
  [ ! -f "$PATCHES/204" ]
}

@test "#2032 AC1: an unreadable remote head retracts nothing (cannot verify, so do not guess)" {
  local ghost="931365099bfb2c283aecfb16b0f5f0b8d59436b2"
  _serve "$(_reply 205 "2026-10-09T02:42:00Z" "$(_claim "$ghost")")"
  git remote set-url origin "$BATS_TEST_TMPDIR/no-such-remote.git"

  run sweep_earlier_claims
  [ "$status" -eq 0 ]
  [[ "$output" == *"not checked"* ]]
  [ ! -f "$PATCHES/205" ]
}

@test "#2032 AC1: the start-of-pass sweep runs right after checkout, before the pass posts anything" {
  local sweep backfill engine
  sweep=$(grep -n '^  sweep_earlier_claims' "$FIX_REVIEWS_SCRIPT" | head -1 | cut -d: -f1)
  backfill=$(grep -n '^  dlpb_backfill_pr_body' "$FIX_REVIEWS_SCRIPT" | head -1 | cut -d: -f1)
  engine=$(grep -n 'build_and_run "' "$FIX_REVIEWS_SCRIPT" | head -1 | cut -d: -f1)
  pass_start=$(grep -n '^  PASS_START_ISO=' "$FIX_REVIEWS_SCRIPT" | head -1 | cut -d: -f1)
  [ -n "$sweep" ] && [ -n "$backfill" ] && [ -n "$engine" ] && [ -n "$pass_start" ]
  [ "$pass_start" -lt "$sweep" ]
  [ "$sweep" -lt "$backfill" ]
  [ "$sweep" -lt "$engine" ]
}

# ---------------------------------------------------------------------------
# AC2: a claim cannot predate its finding
# ---------------------------------------------------------------------------

@test "#2032 AC2: a claim citing a commit older than the finding it answers is retracted (571a3b8)" {
  # The PR's first commit (2026-10-01) is on the head and touches f, but the
  # finding was written on 2026-10-02: it cannot be the fix.
  _serve "$(_reply 206 "2026-10-05T00:01:00Z" "$(_claim "$FIRST_SHA")")"

  run sweep_earlier_claims
  [ -f "$PATCHES/206" ]
  grep -q "reason=predates-finding" "$PATCHES/206"
  ! grep -q "dev-lead:addressed" "$PATCHES/206"
}

# ---------------------------------------------------------------------------
# AC4: a wrongly retracted reply can recover without a new commit
# ---------------------------------------------------------------------------

@test "#2032 AC4: a retracted reply whose fix is on the remote head is restored" {
  local fix retracted
  fix=$(_landed_fix "2026-10-05T00:00:00Z")
  retracted=$(cl_retract_body "$(_claim "$fix")" "not-on-ref")
  _serve "$(_reply 207 "2026-10-05T00:01:00Z" "$retracted")"

  run sweep_earlier_claims
  [ "$status" -eq 0 ]
  [ -f "$PATCHES/207" ]
  ! grep -q "Retracted" "$PATCHES/207"
  ! grep -q "dev-lead:retracted" "$PATCHES/207"
  grep -q "Fixed in f: handled the empty case." "$PATCHES/207"
  grep -q "<!-- dev-lead:addressed -->" "$PATCHES/207"
  run acv_parse_claim "$(cat "$PATCHES/207")"
  [ "$status" -eq 0 ]
  [ "$(jq -r .sha <<<"$output")" = "$fix" ]
}

@test "#2032 AC4: a retracted reply whose commit is still not on the remote head stays retracted" {
  local ghost="931365099bfb2c283aecfb16b0f5f0b8d59436b2" retracted
  retracted=$(cl_retract_body "$(_claim "$ghost")" "not-on-ref")
  _serve "$(_reply 208 "2026-10-09T02:42:00Z" "$retracted")"

  run sweep_earlier_claims
  [ ! -f "$PATCHES/208" ]
}

@test "#2032 AC4: a retracted claim older than its finding is not restored" {
  local retracted
  retracted=$(cl_retract_body "$(_claim "$FIRST_SHA")" "predates-pass")
  _serve "$(_reply 209 "2026-10-05T00:01:00Z" "$retracted")"

  run sweep_earlier_claims
  [ ! -f "$PATCHES/209" ]
}

# ---------------------------------------------------------------------------
# AC3: a clean rebase keeps true claims
# ---------------------------------------------------------------------------

@test "#2032 AC3: a foreign commit rebased in cleanly -> the claim is kept and re-pointed at the rebased SHA" {
  # This pass commits a fix and the model cites it…
  echo fixed > f; git add f; git commit -q -m "fix(reviews): address review comments"
  local cited; cited=$(git rev-parse HEAD)
  _serve "$(_reply 210 "2026-10-09T03:01:00Z" "$(_claim "$cited")")"
  # …then the auto-rebase bot pushes to the branch before dev-lead's push.
  _foreign_push merged-main.txt "from main"

  push_no_clobber
  local rebased; rebased=$(git rev-parse HEAD)
  [ "$rebased" != "$cited" ]
  [ "$(git --git-dir="$REMOTE" rev-parse main)" = "$rebased" ]

  run retract_unlanded_claims fix-reviews ok
  [ "$status" -eq 0 ]
  [ -f "$PATCHES/210" ]
  ! grep -q "Retracted" "$PATCHES/210"
  grep -q "<!-- dev-lead:addressed -->" "$PATCHES/210"
  run acv_parse_claim "$(cat "$PATCHES/210")"
  [ "$status" -eq 0 ]
  [ "$(jq -r .sha <<<"$output")" = "$rebased" ]

  # The updated claim passes the same checks resolve_addressed_bot_threads runs,
  # so its thread resolves in this pass.
  local facts
  facts=$(acv_gather_commit_facts "$rebased" "$RESOLUTION_BASE_SHA")
  run acv_claim_in_pass "$RESOLUTION_BASE_SHA" "$(jq -r .on_head <<<"$facts")" "$(jq -r .in_base <<<"$facts")"
  [ "$status" -eq 0 ]
  run acv_verify_intersection '["f"]' "$(jq -r '.own_files[]' <<<"$facts")" ""
  [ "$status" -eq 0 ]
}

@test "#2032 AC3: an un-incorporable foreign commit -> the claim on the local commit is still retracted" {
  echo fixed > f; git add f; git commit -q -m "fix(reviews): address review comments"
  local cited; cited=$(git rev-parse HEAD)
  _serve "$(_reply 211 "2026-10-09T03:01:00Z" "$(_claim "$cited")")"
  _foreign_push f "conflicting"

  run push_no_clobber
  [ "$status" -eq 2 ]

  run retract_unlanded_claims fix-reviews failed
  [ -f "$PATCHES/211" ]
  grep -q "reason=not-on-ref" "$PATCHES/211"
}

# ---------------------------------------------------------------------------
# #2261: a bot finding posted as a PR ISSUE comment
# ---------------------------------------------------------------------------
# PR #2205: a fix-bot-comment pass answered CodeAnt's issue comment with a new PR
# comment carrying the addressed-marker and a claim citing f8f0b54. The push guard
# then rebased that commit onto a concurrent one, so the fix landed as 3e5025bd and
# f8f0b54 never reached GitHub. The sweep listed only review-thread replies
# (`pulls/<n>/comments`), so the claim was neither re-pointed nor retracted, and a
# `fixed` disposition citing the pre-rebase sha could not have verified either.

# _issue_gh_stub — setup()'s gh stub, plus the PR's ISSUE comments: served from
# $ISSUE_COMMENTS, and a PATCH to one recorded as $PATCHES/issue-<id>.
# ISSUE_LIST_FAILS=1 makes the issue-comment listing fail.
_issue_gh_stub() {
  ISSUE_COMMENTS="$BATS_TEST_TMPDIR/issue-comments.json"
  echo '[]' > "$ISSUE_COMMENTS"
  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"-X PATCH"*)
    id=""; body=""; kind=""
    for a in "\$@"; do
      case "\$a" in
        *issues/comments/*) id="\${a##*/}"; kind="issue-" ;;
        *pulls/comments/*) id="\${a##*/}" ;;
        body=*) body="\${a#body=}" ;;
      esac
    done
    printf '%s' "\$body" > "$PATCHES/\${kind}\${id}"
    echo '{}'
    ;;
  *"issues/54/comments"*)
    if [ -n "\${ISSUE_LIST_FAILS:-}" ]; then echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; fi
    cat "$ISSUE_COMMENTS"
    ;;
  *"pulls/54/comments"*) cat "$COMMENTS" ;;
  *) echo '{}' ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
}

# _issue_reply <id> <created_at> <body> [login] — a PR issue comment (REST shape).
_issue_reply() {
  jq -c -n --argjson id "$1" --arg at "$2" --arg body "$3" --arg login "${4:-donpetry-bot}" \
    '{id: $id, user: {login: $login}, created_at: $at, body: $body}'
}

# _serve_issue <comment_json>... — the PR's issue comments.
_serve_issue() {
  printf '%s\n' "$@" | jq -s -c . > "$ISSUE_COMMENTS"
}

@test "#2261 AC3: a claim reply posted as a PR issue comment whose commit never landed is retracted" {
  _issue_gh_stub
  local ghost="f8f0b543ee9d935538a65233d261bb1284d60276"
  _serve_issue "$(_issue_reply 301 "2026-10-09T03:01:00Z" "$(_claim "$ghost")")"

  run retract_unlanded_claims fix-bot-comment ok
  [ "$status" -eq 0 ]
  [[ "$output" == *"retracted 1 claim reply(ies)"* ]]
  # Patched through the ISSUE-comment endpoint, not the review-comment one.
  [ -f "$PATCHES/issue-301" ]
  [ ! -f "$PATCHES/301" ]
  grep -q "Retracted" "$PATCHES/issue-301"
  grep -q "<!-- dev-lead:retracted reason=not-on-ref -->" "$PATCHES/issue-301"
  if grep -q "dev-lead:addressed" "$PATCHES/issue-301"; then false; fi
  if grep -q "<!-- dev-lead:claim " "$PATCHES/issue-301"; then false; fi
}

@test "#2261 AC3: a PR issue-comment claim whose commit the push guard rebased is re-pointed at the commit that landed" {
  _issue_gh_stub
  echo fixed > f; git add f; git commit -q -m "fix(bot): address bot feedback"
  local cited; cited=$(git rev-parse HEAD)
  _serve_issue "$(_issue_reply 302 "2026-10-09T03:01:00Z" "$(_claim "$cited")")"
  _foreign_push merged-main.txt "from main"

  push_no_clobber
  local rebased; rebased=$(git rev-parse HEAD)
  [ "$rebased" != "$cited" ]
  [ "$(git --git-dir="$REMOTE" rev-parse main)" = "$rebased" ]

  run retract_unlanded_claims fix-bot-comment ok
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 re-pointed at rebased commits"* ]]
  [ -f "$PATCHES/issue-302" ]
  if grep -q "Retracted" "$PATCHES/issue-302"; then false; fi
  grep -q "<!-- dev-lead:addressed -->" "$PATCHES/issue-302"
  # No claim on the PR cites a commit that is not on the branch.
  if grep -q "$cited" "$PATCHES/issue-302"; then false; fi
  run acv_parse_claim "$(cat "$PATCHES/issue-302")"
  [ "$status" -eq 0 ]
  [ "$(jq -r .sha <<<"$output")" = "$rebased" ]
}

@test "#2261 AC3: only OUR issue comments from THIS pass are swept; a landed claim is left alone" {
  _issue_gh_stub
  local ghost="f8f0b543ee9d935538a65233d261bb1284d60276"
  # A fix this pass committed and pushed: its claim is true.
  echo fixed > f; git add f; git commit -q -m "fix(bot): address bot feedback"
  git push -q origin main
  local landed; landed=$(git rev-parse HEAD)
  _serve_issue \
    "$(_issue_reply 311 "2026-10-09T03:01:00Z" "$(_claim "$ghost")")" \
    "$(_issue_reply 312 "2026-10-09T03:01:00Z" "$(_claim "$ghost")" "mallory")" \
    "$(_issue_reply 313 "2026-10-09T02:59:59Z" "$(_claim "$ghost")")" \
    "$(_issue_reply 314 "2026-10-09T03:02:00Z" "$(_claim "$landed")")" \
    "$(_issue_reply 315 "2026-10-09T03:02:00Z" "Looked into it; nothing to change.")"

  run retract_unlanded_claims fix-bot-comment ok
  [ "$status" -eq 0 ]
  # Ours, this pass, never landed: retracted.
  [ -f "$PATCHES/issue-311" ]
  # Another author's comment, ours from before the pass start, a claim that
  # landed, and a comment with no marker or claim: all untouched.
  [ ! -f "$PATCHES/issue-312" ]
  [ ! -f "$PATCHES/issue-313" ]
  [ ! -f "$PATCHES/issue-314" ]
  [ ! -f "$PATCHES/issue-315" ]
  [ "$(find "$PATCHES" -type f | wc -l | tr -d '[:space:]')" -eq 1 ]
}

@test "#2261 AC3: the sweep never strips a comment-disposition marker from the reply it rewrites" {
  _issue_gh_stub
  source "$LIB_DIR/comment-disposition-verify.sh"
  local ghost="f8f0b543ee9d935538a65233d261bb1284d60276"
  local disp="<!-- dev-lead:comment-disposition id=IC_FIND disposition=fixed sha=${ghost} -->"
  # Two retracted replies (commit never landed; in 323 the disposition marker
  # shares the claim's line) and a re-pointed one (rebased, landed).
  echo fixed > f; git add f; git commit -q -m "fix(bot): address bot feedback"
  local cited; cited=$(git rev-parse HEAD)
  _serve_issue \
    "$(_issue_reply 321 "2026-10-09T03:01:00Z" "$(_claim "$ghost")
${disp}")" \
    "$(_issue_reply 322 "2026-10-09T03:01:00Z" "$(_claim "$cited")
${disp}")" \
    "$(_issue_reply 323 "2026-10-09T03:01:00Z" "$(_claim "$ghost") ${disp}")"
  _foreign_push merged-main.txt "from main"
  push_no_clobber

  run retract_unlanded_claims fix-bot-comment ok
  [ "$status" -eq 0 ]
  local id
  for id in 321 322 323; do
    [ -f "$PATCHES/issue-${id}" ]
    run cdv_parse_disposition "$(cat "$PATCHES/issue-${id}")"
    [ "$status" -eq 0 ]
    [ "$(jq -r .id <<<"$output")" = "IC_FIND" ]
    [ "$(jq -r .disposition <<<"$output")" = "fixed" ]
    [ "$(jq -r .sha <<<"$output")" = "$ghost" ]
  done
  # The retracted ones lost the addressed-marker and the claim, and only those.
  for id in 321 323; do
    grep -q "<!-- dev-lead:retracted reason=not-on-ref -->" "$PATCHES/issue-${id}"
    if grep -q "dev-lead:addressed" "$PATCHES/issue-${id}"; then false; fi
    if grep -q "<!-- dev-lead:claim " "$PATCHES/issue-${id}"; then false; fi
  done
  # The re-pointed one differs from what the model posted only in its claim sha.
  [ "$(cat "$PATCHES/issue-322")" = "$(_claim "$(git rev-parse HEAD)")
${disp}" ]
}

@test "#2261 AC3: an unreadable issue-comment listing fails the sweep; thread replies are still swept" {
  _issue_gh_stub
  export ISSUE_LIST_FAILS=1
  local ghost="f8f0b543ee9d935538a65233d261bb1284d60276"
  _serve "$(_reply 331 "2026-10-09T03:01:00Z" "$(_claim "$ghost")")"

  run retract_unlanded_claims fix-bot-comment ok
  # Not verified is not clean: the caller must not treat the pass as swept.
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not list the issue comments on PR #54"* ]]
  [[ "$output" == *"NOT verified"* ]]
  [ -f "$PATCHES/331" ]
  grep -q "reason=not-on-ref" "$PATCHES/331"
}

# _disposition_resolver — load the real resolve_dispositioned_comments and its
# rdc_* helpers, and a gh stub for it: $NODES is the PR's issue comments (GraphQL
# shape), minimize calls go to $MINLOG, an in-place edit of a comment (the
# updateIssueComment mutation) is recorded as $EDITS/<node id>, and a posted PR
# comment goes to $POSTLOG. EDIT_FAILS=1 makes the edit fail. The remote gets a
# `base` branch at the root commit, so the PR branch (main) is ahead of its base.
_disposition_resolver() {
  source "$LIB_DIR/comment-disposition-verify.sh"
  source "$LIB_DIR/maintainer-comment-gate.sh"
  local fn
  for fn in rdc_fixed_refs rdc_commit_diff rdc_fixed_verdict rdc_live_comment_body \
            rdc_find_fixing_commit rdc_repoint_rebased_fixed \
            resolve_dispositioned_comments _rdc_unminimize_status; do
    eval "$(sed -n "/^${fn}()/,/^}/p" "$FIX_REVIEWS_SCRIPT")"
  done
  declare -F resolve_dispositioned_comments >/dev/null
  declare -F rdc_fixed_verdict >/dev/null

  NODES="$BATS_TEST_TMPDIR/nodes.json"
  MINLOG="$BATS_TEST_TMPDIR/minimize.log"
  POSTLOG="$BATS_TEST_TMPDIR/posts.log"
  EDITS="$BATS_TEST_TMPDIR/edits"
  mkdir -p "$EDITS"
  : > "$MINLOG"; : > "$POSTLOG"; echo '[]' > "$NODES"
  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"updateIssueComment"*)
    if [ -n "\${EDIT_FAILS:-}" ]; then echo "gh: Forbidden (HTTP 403)" >&2; exit 1; fi
    id=""; body=""
    for a in "\$@"; do
      case "\$a" in
        id=*) id="\${a#id=}" ;;
        body=*) body="\${a#body=}" ;;
      esac
    done
    printf '%s' "\$body" > "$EDITS/\${id}"
    echo '{"data":{"updateIssueComment":{"issueComment":{"id":"x"}}}}'
    ;;
  *"minimizeComment"*)
    echo "\$ARGS" >> "$MINLOG"
    echo '{"data":{"minimizeComment":{"minimizedComment":{"isMinimized":true}}}}'
    ;;
  *"IssueComment{body}"*)
    jq -c --arg id "\${ARGS##*id=}" '{data:{node:{body:(first(.[] | select(.id == \$id)) | .body)}}}' "$NODES"
    ;;
  *"on IssueComment"*) echo '{"data":{"node":{"isMinimized":false,"minimizedReason":null}}}' ;;
  *"pageInfo"*)
    printf '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":%s}}}}}' "\$(cat "$NODES")"
    ;;
  *"pr comment"*) echo "\$ARGS" >> "$POSTLOG" ;;
  *) echo '{}' ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  git push -q origin "$(git rev-list --max-parents=0 HEAD):refs/heads/base"
  git fetch -q origin base
  export BASE_REF=base
}

# _finding_and_fixed_reply <finding_body> <cited_sha> — CodeAnt's issue comment
# IC_FIND, and OUR reply R1 dispositioning it `fixed` with <cited_sha>.
_finding_and_fixed_reply() {
  jq -n -c --arg b "$1" --arg at "$FINDING_AT" --arg sha "$2" '[
    {id: "IC_FIND", author: {login: "codeant-ai", __typename: "Bot"}, body: $b,
     isMinimized: false, minimizedReason: null, createdAt: $at, lastEditedAt: null},
    {id: "R1", author: {login: "donpetry-bot", __typename: "User"},
     body: ("Fixed in guard.txt: added the missing guard.\n\n<!-- dev-lead:comment-disposition id=IC_FIND disposition=fixed sha=" + $sha + " -->"),
     isMinimized: false, minimizedReason: null, createdAt: "2026-10-09T03:01:00Z"}
  ]' > "$NODES"
}

# A finding that names no distinctive token: only a commit this pass produced can
# verify it, and no search of the branch can find the fix again (#2004).
_TOKENLESS_FINDING="Incomplete implementation: the empty-input case has no guard."

# _additive_fix — this pass's commit: it only ADDS lines. Echoes its sha.
_additive_fix() {
  printf '%s\n' "${1:-guard the empty-input case}" > guard.txt
  git add guard.txt
  git commit -q -m "fix(bot): address bot feedback"
  git rev-parse HEAD
}

@test "#2261 AC2: a fixed disposition citing a commit the push guard rebased verifies against the rebased commit, and its marker is re-pointed" {
  _disposition_resolver
  local cited; cited=$(_additive_fix)
  _finding_and_fixed_reply "$_TOKENLESS_FINDING" "$cited"
  # The auto-rebase bot pushes to the branch before dev-lead's push (#1607).
  _foreign_push merged-main.txt "from main"
  push_no_clobber
  local rebased; rebased=$(git rev-parse HEAD)
  [ "$rebased" != "$cited" ]
  [ "$(git --git-dir="$REMOTE" rev-parse main)" = "$rebased" ]

  run resolve_dispositioned_comments fix-bot-comment
  [ "$status" -eq 0 ]
  [[ "$output" == *"it landed as ${rebased} (tokenless-this-pass)"* ]]
  [[ "$output" != *"fixed-unverified"* ]]
  # The bot's comment is cleared in this pass.
  grep -Eq 'classifier:RESOLVED.*id=IC_FIND' "$MINLOG"
  # OUR reply was edited in place, and nothing new was posted or hidden.
  [ ! -s "$POSTLOG" ]
  if grep -q 'classifier:OUTDATED' "$MINLOG"; then false; fi
  [ -f "$EDITS/R1" ]
  grep -q "Fixed in guard.txt: added the missing guard." "$EDITS/R1"
  # Its one marker cites the commit that is on the branch, not the one that is not.
  if grep -q "$cited" "$EDITS/R1"; then false; fi
  run cdv_parse_disposition "$(cat "$EDITS/R1")"
  [ "$status" -eq 0 ]
  [ "$(jq -r .id <<<"$output")" = "IC_FIND" ]
  [ "$(jq -r .disposition <<<"$output")" = "fixed" ]
  [ "$(jq -r .sha <<<"$output")" = "$rebased" ]
}

@test "#2261 AC2: a rebased fix that removes the finding's token is re-pointed in place, with no second reply" {
  _disposition_resolver
  # The README says `base`; the fix replaces that line, so its diff removes the token.
  echo ready > README; git add README; git commit -q -m "fix(bot): address bot feedback"
  local cited; cited=$(git rev-parse HEAD)
  _finding_and_fixed_reply 'The README still says `base`, a placeholder.' "$cited"
  _foreign_push merged-main.txt "from main"
  push_no_clobber
  local rebased; rebased=$(git rev-parse HEAD)
  [ "$rebased" != "$cited" ]

  run resolve_dispositioned_comments fix-bot-comment
  [ "$status" -eq 0 ]
  [[ "$output" == *"it landed as ${rebased} (content-removes-token)"* ]]
  grep -Eq 'classifier:RESOLVED.*id=IC_FIND' "$MINLOG"
  [ ! -s "$POSTLOG" ]
  grep -q "sha=${rebased} -->" "$EDITS/R1"
}

@test "#2261 AC2: a cited commit that was never rebased or pushed stays unverified" {
  _disposition_resolver
  local cited; cited=$(_additive_fix)
  _finding_and_fixed_reply "$_TOKENLESS_FINDING" "$cited"
  # No push at all: the commit exists only locally, and nothing maps it.

  run resolve_dispositioned_comments fix-bot-comment
  [ "$status" -eq 0 ]
  [[ "$output" == *"citing ${cited} did not verify (fixed-unverified:not-on-head)"* ]]
  [ ! -s "$MINLOG" ]
  [ ! -s "$POSTLOG" ]
  [ -z "$(ls -A "$EDITS")" ]
}

@test "#2261 AC2: a rewrite that maps to a commit not on the pushed head stays unverified" {
  _disposition_resolver
  local cited; cited=$(_additive_fix)
  _finding_and_fixed_reply "$_TOKENLESS_FINDING" "$cited"
  # A map entry is not proof: its target must itself be on the remote head.
  local unpushed; unpushed=$(_additive_fix "a second local-only commit")
  _PUSH_GUARD_REWRITES="${cited}"$'\t'"${unpushed}"

  run resolve_dispositioned_comments fix-bot-comment
  [ "$status" -eq 0 ]
  [[ "$output" == *"rebased the cited ${cited} to ${unpushed}, which did not verify either (fixed-unverified:not-on-head)"* ]]
  [ ! -s "$MINLOG" ]
  [ ! -s "$POSTLOG" ]
  [ -z "$(ls -A "$EDITS")" ]
}

@test "#2261 AC2: the rebased commit must still pass the #2004 content rule (the PR #2205 shape stays open)" {
  _disposition_resolver
  # PR #2205's finding names a token (`escalate = no`), and its fix only added an
  # assertion, removing nothing. #2004 rejects that with or without a rebase, and
  # the rebase mapping must not become a way around it.
  local cited; cited=$(_additive_fix "the bullet must not say escalate = yes")
  _finding_and_fixed_reply 'This assertion never verifies the no-ADR branch says `escalate = no`, so changing that decision to yes can pass this regression guard.' "$cited"
  _foreign_push merged-main.txt "from main"
  push_no_clobber
  local rebased; rebased=$(git rev-parse HEAD)
  [ "$rebased" != "$cited" ]

  run resolve_dispositioned_comments fix-bot-comment
  [ "$status" -eq 0 ]
  [[ "$output" == *"rebased the cited ${cited} to ${rebased}, which did not verify either (fixed-unverified:content-no-token-removed)"* ]]
  [ ! -s "$MINLOG" ]
  [ -z "$(ls -A "$EDITS")" ]
}

@test "#2261 AC2: when our reply cannot be updated, the comment stays open" {
  _disposition_resolver
  export EDIT_FAILS=1
  local cited; cited=$(_additive_fix)
  _finding_and_fixed_reply "$_TOKENLESS_FINDING" "$cited"
  _foreign_push merged-main.txt "from main"
  push_no_clobber
  local rebased; rebased=$(git rev-parse HEAD)
  [ "$rebased" != "$cited" ]

  run resolve_dispositioned_comments fix-bot-comment
  [ "$status" -eq 0 ]
  [[ "$output" == *"disposition reply R1 could not be updated to cite it; it stays open"* ]]
  # A marker citing a commit GitHub never saw must not clear the comment.
  [ ! -s "$MINLOG" ]
  [ -z "$(ls -A "$EDITS")" ]
}
