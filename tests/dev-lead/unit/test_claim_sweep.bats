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
