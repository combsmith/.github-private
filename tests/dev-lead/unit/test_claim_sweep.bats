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
  ISSUE_COMMENTS="$BATS_TEST_TMPDIR/issue-comments.json"
  PATCHES="$BATS_TEST_TMPDIR/patches"
  mkdir -p "$PATCHES"
  echo '[]' > "$COMMENTS"
  echo '[]' > "$ISSUE_COMMENTS"

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
        # Issue-comment PATCHes (#2156) are recorded as issue-<id>.
        *issues/comments/*) id="issue-\${a##*/}" ;;
        body=*) body="\${a#body=}" ;;
      esac
    done
    printf '%s' "\$body" > "$PATCHES/\$id"
    echo '{}'
    ;;
  *"pulls/54/comments"*) cat "$COMMENTS" ;;
  *"issues/54/comments"*) cat "$ISSUE_COMMENTS" ;;
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
  source "$LIB_DIR/comment-disposition-verify.sh"
  source "$LIB_DIR/claim-landing.sh"
  source "$LIB_DIR/git-push-guard.sh"
  source "$LIB_DIR/git-history.sh"
  eval "$(sed -n '/^github_knows_commit()/,/^}/p' "$FIX_REVIEWS_SCRIPT")"
  eval "$(sed -n '/^sweep_earlier_claims()/,/^}/p' "$FIX_REVIEWS_SCRIPT")"
  eval "$(sed -n '/^retract_unlanded_claims()/,/^}/p' "$FIX_REVIEWS_SCRIPT")"
  eval "$(sed -n '/^sweep_fixed_dispositions()/,/^}/p' "$FIX_REVIEWS_SCRIPT")"
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
  ! grep -q "dev-lead:addressed" "$PATCHES/201" || false
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
  ! grep -q "Retracted" "$PATCHES/207" || false
  ! grep -q "dev-lead:retracted" "$PATCHES/207" || false
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
  ! grep -q "Retracted" "$PATCHES/210" || false
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
# #2156: issue-comment `fixed` dispositions are swept like review-thread claims
# ---------------------------------------------------------------------------
# PR #2080: comment 6073169970 carried `disposition=fixed` citing 9313650…, which
# never reached the branch; the review-thread claim was retracted, this was not.

# _disposition <comment_id> <disposition> [sha] [ref] — the reply's body.
_disposition() {
  printf 'Handled the empty-input case.\n\n<!-- dev-lead:comment-disposition id=%s disposition=%s%s%s -->' \
    "$1" "$2" "${3:+ sha=$3}" "${4:+ ref=$4}"
}

# _serve_issue <id> <created_at> <body> [<id> <created_at> <body>]... — the PR's
# issue comments: our replies (REST shape).
_serve_issue() {
  local rows=()
  while [ "$#" -ge 3 ]; do
    rows+=("$(jq -c -n --argjson id "$1" --arg at "$2" --arg body "$3" \
      '{id: $id, user: {login: "donpetry-bot"}, created_at: $at, body: $body}')")
    shift 3
  done
  printf '%s\n' "${rows[@]}" | jq -s -c . > "$ISSUE_COMMENTS"
}

@test "#2156 AC1/AC2: an earlier fixed issue-comment reply citing an unlanded commit is retracted" {
  local ghost="931365099bfb2c283aecfb16b0f5f0b8d59436b2"
  _serve_issue 6073169970 "2026-10-09T02:42:00Z" "$(_disposition IC_kwDO123 fixed "$ghost")"

  run sweep_earlier_claims
  [ "$status" -eq 0 ]
  [ -f "$PATCHES/issue-6073169970" ]
  grep -q "Retracted" "$PATCHES/issue-6073169970"
  grep -q "<!-- dev-lead:retracted reason=not-on-ref -->" "$PATCHES/issue-6073169970"
  # The marker is gone, so neither the minimizer nor a reader sees "fixed" any more…
  ! grep -q "dev-lead:comment-disposition" "$PATCHES/issue-6073169970" || false
  run cdv_parse_disposition "$(cat "$PATCHES/issue-6073169970")"
  [ "$status" -eq 1 ]
  # …and the original text is kept as a quote.
  grep -q "^> Handled the empty-input case." "$PATCHES/issue-6073169970"
}

@test "#2156 AC1: an earlier fixed reply whose commit landed is kept" {
  local fix
  fix=$(_landed_fix "2026-10-05T00:00:00Z")
  _serve_issue 301 "2026-10-05T00:01:00Z" "$(_disposition IC_kwDO123 fixed "$fix")"

  run sweep_earlier_claims
  [ "$status" -eq 0 ]
  [[ "$output" == *"sweep_fixed_dispositions: retracted 0 earlier"* ]]
  [ ! -f "$PATCHES/issue-301" ]
}

@test "#2156 AC1: an earlier fixed reply whose commit GitHub knows (pushed, then rewritten) is kept" {
  local ghost="931365099bfb2c283aecfb16b0f5f0b8d59436b2"
  export GH_KNOWN_COMMIT="$ghost"
  _serve_issue 302 "2026-10-09T02:42:00Z" "$(_disposition IC_kwDO123 fixed "$ghost")"

  run sweep_earlier_claims
  [ "$status" -eq 0 ]
  [[ "$output" == *"pushed, then rewritten"* ]]
  [ ! -f "$PATCHES/issue-302" ]
}

@test "#2156 AC3: invalid / answered / informational / out-of-scope replies are never retracted" {
  _serve_issue \
    311 "2026-10-09T02:42:00Z" "$(_disposition IC_a invalid)" \
    312 "2026-10-09T02:42:00Z" "$(_disposition IC_b answered)" \
    313 "2026-10-09T02:42:00Z" "$(_disposition IC_c informational)" \
    314 "2026-10-09T02:42:00Z" "$(_disposition IC_d out-of-scope "" "#9999")"

  run sweep_earlier_claims
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$PATCHES")" ]

  _serve_issue \
    315 "2026-10-09T03:01:00Z" "$(_disposition IC_a invalid)" \
    316 "2026-10-09T03:01:00Z" "$(_disposition IC_b answered)" \
    317 "2026-10-09T03:01:00Z" "$(_disposition IC_c informational)" \
    318 "2026-10-09T03:01:00Z" "$(_disposition IC_d out-of-scope "" "#9999")"
  run retract_unlanded_claims fix-bot-comment failed
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$PATCHES")" ]
}

@test "#2156 AC1/AC2: the end-of-pass sweep retracts this pass's fixed reply whose commit did not land" {
  # This pass committed a fix and the model cited it, but the push never landed.
  echo fixed > f; git add f; git commit -q -m "fix(reviews): address review comments"
  local cited; cited=$(git rev-parse HEAD)
  _serve_issue 320 "2026-10-09T03:01:00Z" "$(_disposition IC_kwDO123 fixed "$cited")"

  run retract_unlanded_claims fix-bot-comment failed
  [ -f "$PATCHES/issue-320" ]
  grep -q "reason=not-on-ref" "$PATCHES/issue-320"
  ! grep -q "dev-lead:comment-disposition" "$PATCHES/issue-320"
}

@test "#2156 AC1: the end-of-pass sweep keeps this pass's fixed reply whose commit landed" {
  echo fixed > f; git add f; git commit -q -m "fix(reviews): address review comments"
  local cited; cited=$(git rev-parse HEAD)
  git push -q origin main
  _serve_issue 321 "2026-10-09T03:01:00Z" "$(_disposition IC_kwDO123 fixed "$cited")"

  run retract_unlanded_claims fix-bot-comment ok
  [ "$status" -eq 0 ]
  [[ "$output" == *"sweep_fixed_dispositions: retracted 0 pass"* ]]
  [ ! -f "$PATCHES/issue-321" ]
}

@test "#2156 AC1: the end-of-pass sweep leaves earlier passes' fixed replies to the start-of-pass sweep" {
  local ghost="931365099bfb2c283aecfb16b0f5f0b8d59436b2"
  _serve_issue 322 "2026-10-09T02:42:00Z" "$(_disposition IC_kwDO123 fixed "$ghost")"

  run retract_unlanded_claims fix-bot-comment ok
  [ ! -f "$PATCHES/issue-322" ]
}

@test "#2156: a clean rebase re-points this pass's fixed reply at the landed commit instead of retracting it" {
  echo fixed > f; git add f; git commit -q -m "fix(reviews): address review comments"
  local cited; cited=$(git rev-parse HEAD)
  _serve_issue 323 "2026-10-09T03:01:00Z" "$(_disposition IC_kwDO123 fixed "$cited")"
  _foreign_push merged-main.txt "from main"
  push_no_clobber
  local rebased; rebased=$(git rev-parse HEAD)
  [ "$rebased" != "$cited" ]

  run retract_unlanded_claims fix-bot-comment ok
  [ "$status" -eq 0 ]
  [ -f "$PATCHES/issue-323" ]
  ! grep -q "Retracted" "$PATCHES/issue-323" || false
  run cdv_parse_disposition "$(cat "$PATCHES/issue-323")"
  [ "$status" -eq 0 ]
  [ "$(jq -r .sha <<<"$output")" = "$rebased" ]
  [ "$(jq -r .disposition <<<"$output")" = "fixed" ]
}

@test "#2156: a failed issue-comment listing is reported, not read as clean" {
  printf 'not json' > "$ISSUE_COMMENTS"
  run retract_unlanded_claims fix-bot-comment ok
  [ "$status" -ne 0 ]
  [[ "$output" == *"issue comments"* ]]
}

# ---------------------------------------------------------------------------
# #2261: a claim reply posted as a PR ISSUE comment is swept like a thread reply
# ---------------------------------------------------------------------------
# PR #2205: a fix-bot-comment pass answered CodeAnt's issue comment with a new PR
# comment carrying the addressed-marker and a claim citing f8f0b54. The push guard
# then rebased that commit onto a concurrent one, so the fix landed as 3e5025bd and
# f8f0b54 never reached GitHub. The claim sweep listed only review-thread replies
# (`pulls/<n>/comments`), so the claim was neither re-pointed nor retracted.
#
# The gh stub serves $ISSUE_COMMENTS unchanged after a PATCH, which is also what
# a listing that lags a write returns: a reply rewritten twice shows up here as
# the second PATCH overwriting the first.

GHOST_2261="f8f0b543ee9d935538a65233d261bb1284d60276"

# _pr_comment <id> <created_at> <body> [login] — a PR issue comment (REST shape).
_pr_comment() {
  jq -c -n --argjson id "$1" --arg at "$2" --arg body "$3" --arg login "${4:-donpetry-bot}" \
    '{id: $id, user: {login: $login}, created_at: $at, body: $body}'
}

# _serve_pr_comments <comment_json>... — the PR's issue comments, as one page.
_serve_pr_comments() {
  printf '%s\n' "$@" | jq -s -c . > "$ISSUE_COMMENTS"
}

@test "#2261 AC3: a claim reply posted as a PR issue comment whose commit never landed is retracted" {
  _serve_pr_comments "$(_pr_comment 401 "2026-10-09T03:01:00Z" "$(_claim "$GHOST_2261")")"

  run retract_unlanded_claims fix-bot-comment ok
  [ "$status" -eq 0 ]
  [[ "$output" == *"retracted PR-comment claim reply 401"* ]]
  # Patched through the ISSUE-comment endpoint, not the review-comment one.
  [ -f "$PATCHES/issue-401" ]
  [ ! -f "$PATCHES/401" ]
  grep -q "Retracted" "$PATCHES/issue-401"
  grep -q "<!-- dev-lead:retracted reason=not-on-ref -->" "$PATCHES/issue-401"
  ! grep -q "dev-lead:addressed" "$PATCHES/issue-401" || false
  ! grep -q "<!-- dev-lead:claim " "$PATCHES/issue-401" || false
}

@test "#2261 AC3: a PR issue-comment claim whose commit the push guard rebased is re-pointed at the commit that landed" {
  echo fixed > f; git add f; git commit -q -m "fix(bot): address bot feedback"
  local cited; cited=$(git rev-parse HEAD)
  _serve_pr_comments "$(_pr_comment 402 "2026-10-09T03:01:00Z" "$(_claim "$cited")")"
  _foreign_push merged-main.txt "from main"
  push_no_clobber
  local rebased; rebased=$(git rev-parse HEAD)
  [ "$rebased" != "$cited" ]
  [ "$(git --git-dir="$REMOTE" rev-parse main)" = "$rebased" ]

  run retract_unlanded_claims fix-bot-comment ok
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR-comment claim reply 402"*"claim updated, not retracted"* ]]
  [ -f "$PATCHES/issue-402" ]
  ! grep -q "Retracted" "$PATCHES/issue-402" || false
  grep -q "<!-- dev-lead:addressed -->" "$PATCHES/issue-402"
  # No claim on the PR cites a commit that is not on the branch.
  ! grep -q "$cited" "$PATCHES/issue-402" || false
  run acv_parse_claim "$(cat "$PATCHES/issue-402")"
  [ "$status" -eq 0 ]
  [ "$(jq -r .sha <<<"$output")" = "$rebased" ]
}

@test "#2261 AC3: only OUR issue comments from THIS pass are swept; a landed claim is left alone" {
  # A fix this pass committed and pushed: its claim is true.
  echo fixed > f; git add f; git commit -q -m "fix(bot): address bot feedback"
  git push -q origin main
  local landed; landed=$(git rev-parse HEAD)
  _serve_pr_comments \
    "$(_pr_comment 411 "2026-10-09T03:01:00Z" "$(_claim "$GHOST_2261")")" \
    "$(_pr_comment 412 "2026-10-09T03:01:00Z" "$(_claim "$GHOST_2261")" "mallory")" \
    "$(_pr_comment 413 "2026-10-09T02:59:59Z" "$(_claim "$GHOST_2261")")" \
    "$(_pr_comment 414 "2026-10-09T03:02:00Z" "$(_claim "$landed")")" \
    "$(_pr_comment 415 "2026-10-09T03:02:00Z" "Looked into it; nothing to change.")"

  run retract_unlanded_claims fix-bot-comment ok
  [ "$status" -eq 0 ]
  # Ours, this pass, never landed: retracted.
  [ -f "$PATCHES/issue-411" ]
  # Another author's comment, ours from before the pass start, a claim that
  # landed, and a comment with no marker or claim: all untouched.
  [ ! -f "$PATCHES/issue-412" ]
  [ ! -f "$PATCHES/issue-413" ]
  [ ! -f "$PATCHES/issue-414" ]
  [ ! -f "$PATCHES/issue-415" ]
  [ "$(find "$PATCHES" -type f | wc -l | tr -d '[:space:]')" -eq 1 ]
}

@test "#2261 AC3: a claim on the second page of the issue-comment listing is still swept" {
  # `gh api --paginate` prints one JSON array per page.
  {
    jq -c -n --argjson c "$(_pr_comment 421 "2026-10-09T03:01:00Z" "No change needed here.")" '[$c]'
    jq -c -n --argjson c "$(_pr_comment 422 "2026-10-09T03:01:30Z" "$(_claim "$GHOST_2261")")" '[$c]'
  } > "$ISSUE_COMMENTS"

  run retract_unlanded_claims fix-bot-comment ok
  [ "$status" -eq 0 ]
  [ -f "$PATCHES/issue-422" ]
  grep -q "reason=not-on-ref" "$PATCHES/issue-422"
  [ ! -f "$PATCHES/issue-421" ]
}

@test "#2261 AC3: retracting a claim keeps a non-fixed disposition marker in the same reply, even on the claim's line" {
  local disp="<!-- dev-lead:comment-disposition id=IC_FIND disposition=answered -->"
  _serve_pr_comments \
    "$(_pr_comment 431 "2026-10-09T03:01:00Z" "$(_claim "$GHOST_2261")
${disp}")" \
    "$(_pr_comment 432 "2026-10-09T03:01:00Z" "$(_claim "$GHOST_2261") ${disp}")"

  run retract_unlanded_claims fix-bot-comment ok
  [ "$status" -eq 0 ]
  local id
  for id in 431 432; do
    [ -f "$PATCHES/issue-${id}" ]
    grep -q "<!-- dev-lead:retracted reason=not-on-ref -->" "$PATCHES/issue-${id}"
    ! grep -q "dev-lead:addressed" "$PATCHES/issue-${id}" || false
    ! grep -q "<!-- dev-lead:claim " "$PATCHES/issue-${id}" || false
    run cdv_parse_disposition "$(cat "$PATCHES/issue-${id}")"
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.id, .disposition] | join(" ")' <<<"$output")" = "IC_FIND answered" ]
  done
}

@test "#2261: a review-thread claim followed by another marker on its line is stripped whole, and only it" {
  # Two `-->` on the claim's line: the claim ends at the first.
  _serve "$(_reply 441 "2026-10-09T03:01:00Z" "$(_claim "$GHOST_2261") <!-- reviewer-note keep -->")"

  run retract_unlanded_claims fix-reviews ok
  [ -f "$PATCHES/441" ]
  grep -q "<!-- dev-lead:retracted reason=not-on-ref -->" "$PATCHES/441"
  ! grep -q "<!-- dev-lead:claim " "$PATCHES/441" || false
  grep -q "<!-- reviewer-note keep -->" "$PATCHES/441"
}

@test "#2261: a reply with a claim AND a fixed disposition is re-pointed once, both markers together" {
  echo fixed > f; git add f; git commit -q -m "fix(bot): address bot feedback"
  local cited; cited=$(git rev-parse HEAD)
  _serve_pr_comments "$(_pr_comment 451 "2026-10-09T03:01:00Z" "$(_claim "$cited")
<!-- dev-lead:comment-disposition id=IC_FIND disposition=fixed sha=${cited} -->")"
  _foreign_push merged-main.txt "from main"
  push_no_clobber
  local rebased; rebased=$(git rev-parse HEAD)
  [ "$rebased" != "$cited" ]

  run retract_unlanded_claims fix-bot-comment ok
  [ "$status" -eq 0 ]
  # The fixed-disposition sweep owns the reply; the claim sweep leaves it alone.
  [[ "$output" == *"\`fixed\` reply 451"*"disposition updated, not retracted"* ]]
  [[ "$output" != *"PR-comment claim reply 451"* ]]
  [ -f "$PATCHES/issue-451" ]
  ! grep -q "$cited" "$PATCHES/issue-451" || false
  ! grep -q "Retracted" "$PATCHES/issue-451" || false
  run cdv_parse_disposition "$(cat "$PATCHES/issue-451")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.disposition, .sha] | join(" ")' <<<"$output")" = "fixed $rebased" ]
  run acv_parse_claim "$(cat "$PATCHES/issue-451")"
  [ "$status" -eq 0 ]
  [ "$(jq -r .sha <<<"$output")" = "$rebased" ]
}

@test "#2261: a reply with a claim AND a fixed disposition whose commit never landed is retracted once, with neither marker left" {
  _serve_pr_comments "$(_pr_comment 461 "2026-10-09T03:01:00Z" "$(_claim "$GHOST_2261")
<!-- dev-lead:comment-disposition id=IC_FIND disposition=fixed sha=${GHOST_2261} -->")"

  run retract_unlanded_claims fix-bot-comment ok
  [ "$status" -eq 0 ]
  [[ "$output" == *"retracted \`fixed\` disposition reply 461"* ]]
  [[ "$output" != *"PR-comment claim reply 461"* ]]
  [ -f "$PATCHES/issue-461" ]
  grep -q "<!-- dev-lead:retracted reason=not-on-ref -->" "$PATCHES/issue-461"
  ! grep -q "dev-lead:comment-disposition" "$PATCHES/issue-461" || false
  ! grep -q "dev-lead:addressed" "$PATCHES/issue-461" || false
  ! grep -q "<!-- dev-lead:claim " "$PATCHES/issue-461" || false
  # The model's words are kept as a quote.
  grep -q "^> Fixed in f: handled the empty case." "$PATCHES/issue-461"
}

@test "#2261 AC3: an unreadable issue-comment listing fails the sweep; thread replies are still swept" {
  printf 'not json' > "$ISSUE_COMMENTS"
  _serve "$(_reply 471 "2026-10-09T03:01:00Z" "$(_claim "$GHOST_2261")")"

  run retract_unlanded_claims fix-bot-comment ok
  # Not verified is not clean: the caller must not treat the pass as swept.
  [ "$status" -ne 0 ]
  [[ "$output" == *"claim replies this pass posted as PR comments were NOT verified (#2261)"* ]]
  [ -f "$PATCHES/471" ]
  grep -q "reason=not-on-ref" "$PATCHES/471"
}

@test "#2261: cl_without_fixed_dispositions drops only replies carrying a fixed disposition" {
  local kept
  kept=$(cl_without_fixed_dispositions "$(jq -s -c . <<<"$(_pr_comment 481 "$PASS_AT" "$(_claim "$GHOST_2261")")
$(_pr_comment 482 "$PASS_AT" "x <!-- dev-lead:comment-disposition id=IC_A disposition=fixed sha=${GHOST_2261} -->")
$(_pr_comment 483 "$PASS_AT" "x <!-- dev-lead:comment-disposition id=IC_B disposition=answered -->")")")
  [ "$(jq -c '[.[].id]' <<<"$kept")" = "[481,483]" ]
  # JSON that is not a list passes through for the claim selector to read as
  # "no replies"; only a payload that is not JSON fails.
  run cl_without_fixed_dispositions '{}'
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
  run cl_without_fixed_dispositions 'not json'
  [ "$status" -ne 0 ]
}

@test "#2261: an issue-comment listing that is JSON but not a list does not fail the sweep" {
  # A full-script gh stub (and any proxy) may answer the listing with an object.
  # main's `fixed`-disposition sweep reads that as "no replies"; the claim sweep
  # must too, or a pushed pass is reported as failed.
  printf '{}' > "$ISSUE_COMMENTS"
  _serve "$(_reply 495 "2026-10-09T03:01:00Z" "$(_claim "$GHOST_2261")")"

  run retract_unlanded_claims fix-reviews ok
  [ "$status" -eq 0 ]
  [[ "$output" != *"NOT verified"* ]]
  [ -f "$PATCHES/495" ]
}

@test "#2261: a claim whose JSON spans lines is removed whole, so the retracted reply is not selected again" {
  # acv_parse_claim reads through the first ` -->` across lines; the retraction
  # must remove the same span.
  local body
  body=$(printf 'Fixed in f.\n\n<!-- dev-lead:addressed -->\n<!-- dev-lead:claim {\n  "v": 1,\n  "sha": "%s",\n  "files": ["f"]\n} --> <!-- reviewer-note keep -->' "$GHOST_2261")
  run acv_parse_claim "$body"
  [ "$status" -eq 0 ]
  _serve "$(_reply 491 "2026-10-09T03:01:00Z" "$body")"

  run retract_unlanded_claims fix-reviews ok
  [ -f "$PATCHES/491" ]
  ! grep -q "<!-- dev-lead:claim " "$PATCHES/491" || false
  ! grep -q "dev-lead:addressed" "$PATCHES/491" || false
  grep -q "<!-- reviewer-note keep -->" "$PATCHES/491"
  # Idempotent: the next sweep finds nothing to select in the retracted reply.
  run cl_select_pass_claims "$(jq -c -n --arg b "$(cat "$PATCHES/491")" \
    '[{id: 491, user: {login: "donpetry-bot"}, created_at: "2026-10-09T03:01:00Z", body: $b}]')" "donpetry-bot" "$PASS_AT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
