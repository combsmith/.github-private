#!/usr/bin/env bats
# Harness tests for stamp_pass_replies across passes (#2161, follow-up to #2079).
#
# #2079 kept the ids it could not stamp in ${RUNNER_TEMP}/dev-lead-unstamped-replies-<pr>.
# Every pass runs on a fresh hosted runner, so the next pass never read that file, and
# a record holding UNATTRIBUTED discarded the ids that WERE captured. The pending list
# now lives on the PR in a marker comment (`<!-- dev-lead:unstamped-replies ids=… -->`).
#
# These tests run the real stamp_pass_replies / pending_reply_marker_comments /
# save_pending_replies bodies from dev-lead-fix-reviews.sh against a stateful gh stub:
# review comments are files under $NODES, the PR's issue comments are a JSON array.
# Each "pass" gets a fresh temp directory, as on a hosted runner. No live GitHub.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
FIX_REVIEWS_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-fix-reviews.sh"
LIB_DIR="$SCRIPT_DIR/scripts/lib"

setup() {
  export BOT_USER="don-petry" PR_NUMBER=54 REPO="combsmith/.github-private"
  STATE="$BATS_TEST_TMPDIR/state"
  NODES="$STATE/nodes"
  mkdir -p "$NODES"
  echo '[]' > "$STATE/issue-comments.json"
  : > "$STATE/fail-stamp"
  export STATE NODES

  STUB_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN_DIR"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
all="$*" id="" body=""
for a in "$@"; do
  case "$a" in
    id=*) id="${a#id=}" ;;
    body=*) body="${a#body=}" ;;
  esac
done
ic="$STATE/issue-comments.json"
case "$all" in
  *"--paginate"*"/issues/54/comments"*)
    [ -f "$STATE/fail-read" ] && { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
    cat "$ic" ;;
  *"-X DELETE"*"/issues/comments/"*)
    cid="${all##*/issues/comments/}"; cid="${cid%% *}"
    jq --argjson c "$cid" 'map(select(.id != $c))' "$ic" > "$ic.tmp" && mv "$ic.tmp" "$ic" ;;
  *"-X PATCH"*"/issues/comments/"*)
    cid="${all##*/issues/comments/}"; cid="${cid%% *}"
    jq --argjson c "$cid" --arg b "$body" 'map(if .id == $c then .body = $b else . end)' "$ic" > "$ic.tmp" && mv "$ic.tmp" "$ic"
    echo '{}' ;;
  *"/issues/54/comments"*)
    jq --arg b "$body" --arg u "${GH_POSTER:-don-petry}" \
      '. + [{id: ((map(.id) | max // 1000) + 1), user: {login: $u}, body: $b}]' "$ic" > "$ic.tmp" && mv "$ic.tmp" "$ic"
    echo '{}' ;;
  *"updatePullRequestReviewComment"*)
    grep -qx "$id" "$STATE/fail-stamp" && { echo "gh: HTTP 502" >&2; exit 1; }
    printf '%s' "$body" > "$NODES/$id"
    echo '{}' ;;
  *"PullRequestReviewComment{body}"*)
    if [ -f "$NODES/$id" ]; then
      jq -cn --rawfile b "$NODES/$id" '{data:{node:{__typename:"PullRequestReviewComment",body:$b}}}'
    else
      echo '{"data":{"node":null},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a node"}]}'
      exit 1
    fi ;;
  *) echo '{}' ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export PATH="$STUB_BIN_DIR:$PATH"

  # shellcheck source=/dev/null
  source "$LIB_DIR/maintainer-review-thread-gate.sh"
  source "$LIB_DIR/claim-landing.sh"
  eval "$(sed -n '/^stamp_pass_replies()/,/^}/p' "$FIX_REVIEWS_SCRIPT")"
  eval "$(sed -n '/^pending_reply_marker_comments()/,/^}/p' "$FIX_REVIEWS_SCRIPT")"
  eval "$(sed -n '/^save_pending_replies()/,/^}/p' "$FIX_REVIEWS_SCRIPT")"
  declare -F stamp_pass_replies pending_reply_marker_comments save_pending_replies >/dev/null
}

# _new_pass <record lines...> — a fresh runner: new temp dirs and a new reply record.
_new_pass() {
  local runner="$BATS_TEST_TMPDIR/runner.$RANDOM$RANDOM"
  mkdir -p "$runner"
  export RUNNER_TEMP="$runner" TMPDIR="$runner"
  PASS_REPLY_RECORD="$runner/record"
  : > "$PASS_REPLY_RECORD"
  local l
  for l in "$@"; do printf '%s\n' "$l" >> "$PASS_REPLY_RECORD"; done
  unset PASS_REPLIES_UNKNOWN
}

_markers() {
  jq -r '.[] | select(.body | contains("<!-- dev-lead:unstamped-replies ids=")) | .body' "$STATE/issue-comments.json"
}

_marker_count() {
  jq '[.[] | select(.body | contains("<!-- dev-lead:unstamped-replies ids="))] | length' "$STATE/issue-comments.json"
}

@test "#2161 AC1: a reply pass 1 failed to stamp is still known to pass 2 on a fresh runner" {
  printf 'No change needed in this pass.' > "$NODES/PRRC_x"
  echo PRRC_x > "$STATE/fail-stamp"
  _new_pass PRRC_x
  run stamp_pass_replies
  [ "$status" -ne 0 ]
  [ "$(_marker_count)" -eq 1 ]
  [[ "$(_markers)" == *"ids=PRRC_x -->"* ]]

  # Pass 2: a different runner, an empty record, the stamp now succeeds.
  : > "$STATE/fail-stamp"
  _new_pass
  run stamp_pass_replies
  [ "$status" -eq 0 ]
  grep -q 'dev-lead:reply' "$NODES/PRRC_x"
  # Nothing is pending any more: the marker is gone.
  [ "$(_marker_count)" -eq 0 ]
}

@test "#2161 AC1: while a reply stays unstamped the path stays off on every pass and one marker is kept" {
  printf 'No change needed.' > "$NODES/PRRC_x"
  printf 'Skipping: out of scope.' > "$NODES/PRRC_y"
  echo PRRC_x > "$STATE/fail-stamp"
  _new_pass PRRC_x
  run stamp_pass_replies
  [ "$status" -ne 0 ]
  _new_pass PRRC_y
  run stamp_pass_replies
  [ "$status" -ne 0 ]
  grep -q 'dev-lead:reply' "$NODES/PRRC_y"
  [ "$(_marker_count)" -eq 1 ]
  [[ "$(_markers)" == *"ids=PRRC_x -->"* ]]
}

@test "#2161 AC2: an UNATTRIBUTED record still stamps the captured ids, and is persisted until a human clears it" {
  printf 'No change needed.' > "$NODES/PRRC_y"
  _new_pass PRRC_y UNATTRIBUTED
  run stamp_pass_replies
  [ "$status" -ne 0 ]
  grep -q 'dev-lead:reply' "$NODES/PRRC_y"
  [[ "$(_markers)" == *"ids=UNATTRIBUTED -->"* ]]

  # A later, fully attributable pass still keeps the path off.
  _new_pass
  run stamp_pass_replies
  [ "$status" -ne 0 ]
  [ "$(_marker_count)" -eq 1 ]

  # A human deletes the marker: the path is available again.
  echo '[]' > "$STATE/issue-comments.json"
  _new_pass
  run stamp_pass_replies
  [ "$status" -eq 0 ]
}

@test "#2161 AC2: an engine run without a recorder is persisted as UNATTRIBUTED" {
  _new_pass
  export PASS_REPLIES_UNKNOWN=1
  run stamp_pass_replies
  [ "$status" -ne 0 ]
  [[ "$(_markers)" == *"ids=UNATTRIBUTED -->"* ]]
}

@test "#2161: an unreadable marker fails closed, still stamps, and adds (never replaces) a marker" {
  printf 'No change needed.' > "$NODES/PRRC_y"
  printf 'Noted.' > "$NODES/PRRC_z"
  echo PRRC_z > "$STATE/fail-stamp"
  jq -n '[{id: 7, user: {login: "don-petry"}, body: "<!-- dev-lead:unstamped-replies ids=PRRC_old -->"}]' > "$STATE/issue-comments.json"
  touch "$STATE/fail-read"
  _new_pass PRRC_y PRRC_z
  run stamp_pass_replies
  [ "$status" -ne 0 ]
  grep -q 'dev-lead:reply' "$NODES/PRRC_y"
  [ "$(_marker_count)" -eq 2 ]
  [[ "$(_markers)" == *"ids=PRRC_old -->"* ]]
  [[ "$(_markers)" == *"ids=PRRC_z -->"* ]]
}

@test "#2161: a marker posted by another account is ignored (its ids are never rewritten)" {
  printf 'No change needed, false positive.' > "$NODES/PRRC_maint"
  jq -n '[{id: 9, user: {login: "someone-else"}, body: "<!-- dev-lead:unstamped-replies ids=PRRC_maint -->"}]' > "$STATE/issue-comments.json"
  _new_pass
  run stamp_pass_replies
  [ "$status" -eq 0 ]
  [ "$(cat "$NODES/PRRC_maint")" = "No change needed, false positive." ]
}

@test "#2161: a pending reply that no longer exists drops out of the list" {
  jq -n '[{id: 7, user: {login: "don-petry"}, body: "<!-- dev-lead:unstamped-replies ids=PRRC_deleted -->"}]' > "$STATE/issue-comments.json"
  _new_pass
  run stamp_pass_replies
  [ "$status" -eq 0 ]
  [ "$(_marker_count)" -eq 0 ]
}

@test "#2161: the RUNNER_TEMP pending file is no longer used" {
  ! grep -q 'dev-lead-unstamped-replies-' "$FIX_REVIEWS_SCRIPT"
}
