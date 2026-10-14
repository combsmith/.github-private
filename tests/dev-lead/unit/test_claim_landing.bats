#!/usr/bin/env bats
# Unit tests for scripts/lib/claim-landing.sh (#2013).
#
# On petry-projects/.github#1220 dev-lead posted "Fixed in …" replies for changes
# that never reached the branch: the model posts its addressed/claim reply from
# its own shell BEFORE the harness commits and pushes, so a rejected push, a
# no-op-guard abort, an engine failure, or a claim citing the pre-pass head left a
# false "Fixed" on the thread — and CodeRabbit marked a thread addressed on the
# strength of it. claim-landing.sh is the pure verdict layer that decides whether
# a push landed and which of this pass's claim replies must be retracted, plus
# one impure remote-head reader. The harness wiring is covered in
# test_fix_reviews.bats.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/claim-landing.sh"
# addressed-claim-verify.sh (acv_*) is sourced transitively by claim-landing.sh.
GUARD_LIB="$SCRIPT_DIR/scripts/lib/git-push-guard.sh"

A40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
B40="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
C40="cccccccccccccccccccccccccccccccccccccccc"

setup() {
  # shellcheck source=scripts/lib/claim-landing.sh
  source "$LIB"
}

# ---------------------------------------------------------------------------
# Sourcing safety
# ---------------------------------------------------------------------------

@test "claim-landing.sh is safe to source under set -euo pipefail" {
  run bash -c "set -euo pipefail; source '$LIB'"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

# ---------------------------------------------------------------------------
# cl_push_landed_verdict — "push landed" is a pure verdict, not a model claim
# ---------------------------------------------------------------------------

@test "cl_push_landed_verdict: remote head == pushed sha, advanced past start -> landed rc0" {
  run cl_push_landed_verdict "$A40" "$B40" "$B40" true
  [[ "$status" -eq 0 ]]
  [[ "$output" == "landed" ]]
}

@test "cl_push_landed_verdict: remote moved past our pushed commit (contains it) -> landed rc0" {
  run cl_push_landed_verdict "$A40" "$B40" "$C40" true
  [[ "$status" -eq 0 ]]
  [[ "$output" == "landed" ]]
}

@test "cl_push_landed_verdict: non-fast-forward / remote moved without our commit -> not-landed rc1" {
  run cl_push_landed_verdict "$A40" "$B40" "$C40" false
  [[ "$status" -eq 1 ]]
  [[ "$output" == "not-landed" ]]
}

@test "cl_push_landed_verdict: pushed sha equals the starting head -> no-advance rc1" {
  run cl_push_landed_verdict "$A40" "$A40" "$A40" true
  [[ "$status" -eq 1 ]]
  [[ "$output" == "no-advance" ]]
}

@test "cl_push_landed_verdict: any unknown sha fails closed -> unknown rc1" {
  run cl_push_landed_verdict "" "$B40" "$B40" true
  [[ "$output" == "unknown" ]]; [[ "$status" -eq 1 ]]
  run cl_push_landed_verdict "$A40" "" "$B40" true
  [[ "$output" == "unknown" ]]; [[ "$status" -eq 1 ]]
  run cl_push_landed_verdict "$A40" "$B40" "" true
  [[ "$output" == "unknown" ]]; [[ "$status" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# cl_select_pass_claims — which replies did THIS pass post?
# ---------------------------------------------------------------------------

_comments() {
  # REST pulls/{pr}/comments shape: id, user.login, body, created_at.
  jq -c -n --arg a "$A40" --arg b "$B40" '[
    {id: 1, user: {login: "donpetry-bot"}, created_at: "2026-10-01T09:00:00Z",
     body: ("Fixed earlier.\n<!-- dev-lead:addressed -->\n<!-- dev-lead:claim {\"v\":1,\"sha\":\"" + $a + "\",\"files\":[\"f\"]} -->")},
    {id: 2, user: {login: "donpetry-bot"}, created_at: "2026-10-02T10:05:00Z",
     body: ("Fixed in f.\n<!-- dev-lead:addressed -->\n<!-- dev-lead:claim {\"v\":1,\"sha\":\"" + $b + "\",\"files\":[\"f\"]} -->")},
    {id: 3, user: {login: "coderabbitai[bot]"}, created_at: "2026-10-02T10:06:00Z",
     body: ("<!-- dev-lead:addressed -->\n<!-- dev-lead:claim {\"v\":1,\"sha\":\"" + $b + "\",\"files\":[\"f\"]} -->")},
    {id: 4, user: {login: "donpetry-bot"}, created_at: "2026-10-02T10:07:00Z",
     body: "Skipping — ambiguous; leaving for a maintainer."},
    {id: 5, user: {login: "donpetry-bot"}, created_at: "2026-10-02T10:08:00Z",
     body: "Fixed (marker only, no claim).\n<!-- dev-lead:addressed -->"}
  ]'
}

@test "cl_select_pass_claims: selects only OUR claim/marker replies created since the pass started" {
  run cl_select_pass_claims "$(_comments)" "donpetry-bot" "2026-10-02T10:00:00Z"
  [[ "$status" -eq 0 ]]
  # id 1 predates the pass; 3 is another account; 4 carries no marker.
  [[ "$output" == "$(printf '2\t%s\n5\t' "$B40")" ]]
}

@test "cl_select_pass_claims: matches the [bot]-suffixed REST login against a stripped BOT_USER" {
  local json
  json=$(jq -c -n --arg b "$B40" '[{id: 9, user: {login: "donpetry-bot[bot]"}, created_at: "2026-10-02T10:05:00Z",
     body: ("x <!-- dev-lead:addressed -->\n<!-- dev-lead:claim {\"v\":1,\"sha\":\"" + $b + "\",\"files\":[\"f\"]} -->")}]')
  run cl_select_pass_claims "$json" "donpetry-bot" "2026-10-02T10:00:00Z"
  [[ "$output" == "$(printf '9\t%s' "$B40")" ]]
}

@test "cl_select_pass_claims: no pass start -> selects nothing (never retracts history)" {
  run cl_select_pass_claims "$(_comments)" "donpetry-bot" ""
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "cl_select_pass_claims: a non-array payload (stubbed/failed API) -> selects nothing" {
  run cl_select_pass_claims '{"head":{"sha":"x"}}' "donpetry-bot" "2026-10-02T10:00:00Z"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

# ---------------------------------------------------------------------------
# cl_retract_body — the retracted reply can no longer authorize resolution
# ---------------------------------------------------------------------------

@test "cl_retract_body: strips the addressed + claim markers and states the retraction" {
  local body
  body="Fixed in scripts/canary-rollout.sh: a transport failure is not cached.

<!-- dev-lead:addressed -->
<!-- dev-lead:claim {\"v\":1,\"sha\":\"$A40\",\"files\":[\"scripts/canary-rollout.sh\"]} -->"
  run cl_retract_body "$body" "predates-pass"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Retracted"* ]]
  [[ "$output" == *"predates-pass"* ]]
  [[ "$output" == *"<!-- dev-lead:retracted reason=predates-pass -->"* ]]
  # The original text survives (quoted) for the record…
  [[ "$output" == *"> Fixed in scripts/canary-rollout.sh"* ]]
  # …but neither marker does, so the thread gate can never resolve on it.
  [[ "$output" != *"dev-lead:addressed"* ]]
  [[ "$output" != *"dev-lead:claim"* ]]
  run acv_parse_claim "$(cl_retract_body "$body" "predates-pass")"
  [[ "$status" -eq 1 ]]
  [[ "$output" == "no-claim" ]]
}

@test "cl_retract_body: an unknown reason is normalised to a safe token" {
  run cl_retract_body "Fixed. <!-- dev-lead:addressed -->" 'bad -->reason<script>'
  [[ "$output" == *"<!-- dev-lead:retracted reason=unknown -->"* ]]
}

# ---------------------------------------------------------------------------
# cl_remote_head — the single impure reader
# ---------------------------------------------------------------------------

_mk_remote() {
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  WORK="$BATS_TEST_TMPDIR/work"
  git init -q --bare "$REMOTE"
  local seed="$BATS_TEST_TMPDIR/seed"
  git init -q "$seed"
  (
    cd "$seed"
    git config user.email "1+don-petry@users.noreply.github.com"; git config user.name don-petry
    echo A > f; git add f; git commit -q -m A
    git branch -M main
    git remote add origin "$REMOTE"
    git push -q -u origin main
  )
  git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main
  git clone -q "$REMOTE" "$WORK"
  ( cd "$WORK"; git config user.email "1+don-petry@users.noreply.github.com"; git config user.name don-petry )
}

# A concurrent writer pushes to the branch between dev-lead's checkout and push.
_inject_foreign_commit() {
  local other="$BATS_TEST_TMPDIR/other"
  git clone -q "$REMOTE" "$other"
  (
    cd "$other"
    git config user.email human@example.com; git config user.name human
    echo "${1:-C}" >> "${2:-g}"; git add -A; git commit -q -m "human steering"
    git push -q origin main
  )
}

@test "cl_remote_head: echoes the true remote head (fetched), not the stale tracking ref" {
  _mk_remote
  _inject_foreign_commit
  cd "$WORK"
  run cl_remote_head
  [[ "$status" -eq 0 ]]
  [[ "$output" == "$(git --git-dir="$REMOTE" rev-parse main)" ]]
}

@test "cl_remote_head: no upstream -> rc1, echoes nothing" {
  local repo="$BATS_TEST_TMPDIR/noup"
  git init -q "$repo"
  ( cd "$repo"; echo a > a; git add a; git -c user.email=t@t -c user.name=T commit -q -m a )
  cd "$repo"
  run cl_remote_head
  [[ "$status" -eq 1 ]]
  [[ -z "$output" ]]
}

# ---------------------------------------------------------------------------
# Concurrency acceptance criterion (#2013): push to the branch between
# dev-lead's checkout and its push; it must merge-or-abort, and a claim that did
# not land must be classified for retraction. Local bare remote, no live GitHub.
# ---------------------------------------------------------------------------

@test "concurrency repro: foreign commit injected between checkout and push -> merged in, landed, stale claim retracted" {
  _mk_remote
  cd "$WORK"
  source "$GUARD_LIB"
  export BOT_USER="don-petry"
  local start
  start="$(git rev-parse HEAD)"

  # dev-lead's pass commits a fix (a separate file, so the rebase is clean)…
  echo fix > fix.txt; git add fix.txt; git commit -q -m "fix(reviews): address review comments"
  # …and the model's reply cites the pre-pass head (the 571a3b8 shape).
  local stale_claim_sha="$start"
  # A human pushes to the same branch before dev-lead's push.
  _inject_foreign_commit

  run push_no_clobber
  [[ "$status" -eq 0 ]]

  local pushed remote
  pushed="$(git rev-parse HEAD)"
  remote="$(cl_remote_head)"
  # The human's commit was incorporated, never discarded.
  git merge-base --is-ancestor "$(git --git-dir="$REMOTE" rev-parse main~1)" "$remote"
  local on_remote=false
  git merge-base --is-ancestor "$pushed" "$remote" && on_remote=true
  run cl_push_landed_verdict "$start" "$pushed" "$remote" "$on_remote"
  [[ "$output" == "landed" ]]

  # The stale claim (pre-pass head) is classified for retraction against the remote.
  local facts
  facts="$(acv_gather_commit_facts "$stale_claim_sha" "$start" "$remote")"
  run acv_claim_in_pass "$start" "$(jq -r .on_head <<<"$facts")" "$(jq -r .in_base <<<"$facts")"
  [[ "$status" -eq 1 ]]
  [[ "$output" == "predates-pass" ]]

  # A claim citing the commit the pass actually landed verifies.
  facts="$(acv_gather_commit_facts "$pushed" "$start" "$remote")"
  run acv_claim_in_pass "$start" "$(jq -r .on_head <<<"$facts")" "$(jq -r .in_base <<<"$facts")"
  [[ "$status" -eq 0 ]]
}

@test "concurrency repro: un-incorporable foreign commit -> push aborts, claim on the local commit is not-on-ref" {
  _mk_remote
  cd "$WORK"
  source "$GUARD_LIB"
  export BOT_USER="don-petry"
  local start
  start="$(git rev-parse HEAD)"

  # dev-lead's pass edits f; the human edits the SAME line of f -> rebase conflict.
  echo B > f; git commit -q -am "fix(reviews): address review comments"
  local local_fix
  local_fix="$(git rev-parse HEAD)"
  local other="$BATS_TEST_TMPDIR/other2"
  git clone -q "$REMOTE" "$other"
  ( cd "$other"; git config user.email human@example.com; git config user.name human
    echo H > f; git commit -q -am "human steering"; git push -q origin main )

  run push_no_clobber
  # The guard's documented STOP/escalate code for an un-incorporable foreign commit.
  [[ "$status" -eq 2 ]]

  local remote
  remote="$(cl_remote_head)"
  # The human's commit is still the remote head — nothing was clobbered.
  [[ "$remote" == "$(git --git-dir="$REMOTE" rev-parse main)" ]]
  local on_remote=false
  git merge-base --is-ancestor "$local_fix" "$remote" && on_remote=true
  run cl_push_landed_verdict "$start" "$local_fix" "$remote" "$on_remote"
  [[ "$output" == "not-landed" ]]

  # The model's claim citing its local (never-landed) commit must be retracted.
  local facts
  facts="$(acv_gather_commit_facts "$local_fix" "$start" "$remote")"
  run acv_claim_in_pass "$start" "$(jq -r .on_head <<<"$facts")" "$(jq -r .in_base <<<"$facts")"
  [[ "$status" -eq 1 ]]
  [[ "$output" == "not-on-ref" ]]
}

# ── #2079 AC4: stamping the pass's own marker-less replies ──────────────────────

@test "cl_install_reply_recorder: records the node id of an addPullRequestReviewThreadReply and passes output through" {
  local real="$BATS_TEST_TMPDIR/real-gh" rec="$BATS_TEST_TMPDIR/rec"
  printf '#!/usr/bin/env bash\necho "{\\"data\\":{\\"addPullRequestReviewThreadReply\\":{\\"comment\\":{\\"id\\":\\"PRRC_abc\\"}}}}"\n' > "$real"
  chmod +x "$real"
  local dir
  dir=$(cl_install_reply_recorder "$rec" "$real")
  run "$dir/gh" api graphql -f query='mutation { addPullRequestReviewThreadReply(input:{}) { comment { id } } }'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *PRRC_abc* ]]
  run cl_recorded_reply_ids "$rec"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "PRRC_abc" ]]
}

@test "cl_install_reply_recorder: other gh calls are forwarded and not recorded" {
  local real="$BATS_TEST_TMPDIR/real-gh" rec="$BATS_TEST_TMPDIR/rec"
  printf '#!/usr/bin/env bash\necho "args: $*"\n' > "$real"
  chmod +x "$real"
  local dir
  dir=$(cl_install_reply_recorder "$rec" "$real")
  run "$dir/gh" pr view 5
  [[ "$output" == "args: pr view 5" ]]
  [[ ! -s "$rec" ]]
}

@test "cl_install_reply_recorder: a reply response with no id is UNATTRIBUTED and fails closed" {
  local real="$BATS_TEST_TMPDIR/real-gh" rec="$BATS_TEST_TMPDIR/rec"
  printf '#!/usr/bin/env bash\necho "{}"\n' > "$real"
  chmod +x "$real"
  local dir
  dir=$(cl_install_reply_recorder "$rec" "$real")
  run "$dir/gh" api graphql -f query='mutation { addPullRequestReviewThreadReply(input:{}) { comment { id } } }'
  run cl_recorded_reply_ids "$rec"
  [[ "$status" -eq 1 ]]
}

@test "cl_recorded_reply_ids: a missing record fails closed; an empty record is ok" {
  run cl_recorded_reply_ids "$BATS_TEST_TMPDIR/nope"
  [[ "$status" -eq 1 ]]
  : > "$BATS_TEST_TMPDIR/empty"
  run cl_recorded_reply_ids "$BATS_TEST_TMPDIR/empty"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "cl_reply_stamp_body: stamped reply is agent-authored and no longer a no-change maintainer verdict" {
  local stamped
  stamped=$(cl_reply_stamp_body "No change needed in this pass: the guard already exists.")
  review_thread_is_agent_authored "$stamped"
  local comments
  comments=$(jq -cn --arg b "$stamped" '[{author:{login:"don-petry",__typename:"User"},authorAssociation:"MEMBER",body:$b,createdAt:"2026-10-11T08:00:00Z"}]')
  run acv_latest_nochange_disposition "$comments" "2026-10-10T00:00:00Z"
  [[ "$status" -eq 1 ]]
}
