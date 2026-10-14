#!/usr/bin/env bats
# Issue #2174: remove a PR from the merge queue when the fleet withdraws its last
# approval.
#
# GitHub evaluates a ruleset's review requirement when a PR JOINS the merge queue
# and does not re-evaluate it when the queue merges. So an approval the fleet
# dismisses after the PR was enqueued no longer stops the merge (observed on PR
# 2084). After the run's dismissals AND its new verdict, the fleet must re-read
# the LIVE state and, if the PR is queued with no approval standing for its
# current head, call `dequeuePullRequest` and post one marker-keyed comment.
#
# The `gh` mock below is stateful: reviews, comments, queue membership and PR
# state live in files, so a dismissal or a new approval posted earlier in the run
# is what the later live GraphQL read sees.
#
# Run locally: bats tests/test_merge_queue_dequeue.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REPO_ROOT
  export LIB="$REPO_ROOT/scripts/lib/merge-queue-dequeue.sh"
  export POST_SCRIPT="$REPO_ROOT/scripts/post-pr-review.sh"
  export ISA_SCRIPT="$REPO_ROOT/scripts/invalidate-standing-approval.sh"

  export SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  export OLD_SHA="0123456701234567012345670123456701234567"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/2084"
  export PR_HEAD_SHA="$SHA"
  export BOT_USER="donpetry-bot"
  export PR_REVIEW_APPROVER="donpetry-bot"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  # Mutable PR state read by the mock.
  export REVIEWS_FILE="$TEST_DIR/reviews.json";   echo '[]' > "$REVIEWS_FILE"
  export COMMENTS_FILE="$TEST_DIR/comments.json"; echo '[]' > "$COMMENTS_FILE"
  export QUEUED_FILE="$TEST_DIR/queued";          echo true > "$QUEUED_FILE"
  export PR_STATE_FILE="$TEST_DIR/pr_state";      echo OPEN > "$PR_STATE_FILE"
  export CLOCK_FILE="$TEST_DIR/clock";            echo 10 > "$CLOCK_FILE"
  export CALLS="$TEST_DIR/gh_calls.log";          : > "$CALLS"

  cat > "$TEST_DIR/bin/gh" <<'GHEOF'
#!/bin/bash
# Stateful gh mock for #2174. Env knobs:
#   GRAPHQL_READ_RC        — non-zero ⇒ the live-state GraphQL read fails
#   DEQUEUE_RC             — non-zero ⇒ dequeuePullRequest fails (state unchanged)
#   LEAVE_QUEUE_ON_DEQUEUE — 1 ⇒ the PR leaves the queue just before the mutation,
#                            which then fails (the check/call race)
#   MERGE_ON_DEQUEUE       — 1 ⇒ the PR merges just before the mutation, which fails
#   COMMENT_LIST_RC        — non-zero ⇒ listing issue comments fails
printf '%s\n' "$*" >> "$CALLS"

_tick() { local n; n=$(cat "$CLOCK_FILE"); n=$((n + 1)); echo "$n" > "$CLOCK_FILE"; printf '2026-10-10T00:%02d:00Z' "$n"; }

if [ "$1" = "pr" ] && [ "$2" = "review" ]; then
  body=""; prev=""
  for a in "$@"; do [ "$prev" = "--body" ] && body="$a"; prev="$a"; done
  ts=$(_tick)
  jq --arg u "$BOT_USER" --arg sha "$PR_HEAD_SHA" --arg b "$body" --arg ts "$ts" \
    '. + [{id: (1000 + length), user: {login: $u}, state: "APPROVED", commit_id: $sha, body: $b, submitted_at: $ts}]' \
    "$REVIEWS_FILE" > "$REVIEWS_FILE.tmp" && mv "$REVIEWS_FILE.tmp" "$REVIEWS_FILE"
  exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  body=""; prev=""
  for a in "$@"; do [ "$prev" = "--body" ] && body="$a"; prev="$a"; done
  ts=$(_tick)
  jq --arg u "$BOT_USER" --arg b "$body" --arg ts "$ts" \
    '. + [{id: (5000 + length), user: {login: $u}, body: $b, created_at: $ts}]' \
    "$COMMENTS_FILE" > "$COMMENTS_FILE.tmp" && mv "$COMMENTS_FILE.tmp" "$COMMENTS_FILE"
  exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  case "$*" in
    *mergeStateStatus*) echo "CLEAN" ;;
    *labels*) echo "false" ;;
    *comments*) jq '{comments: .}' "$COMMENTS_FILE" ;;
    *) echo '{}' ;;
  esac
  exit 0
fi
if [ "$1" = "pr" ]; then exit 0; fi

if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  if [[ "$*" == *dequeuePullRequest* ]]; then
    if [ "${LEAVE_QUEUE_ON_DEQUEUE:-0}" = "1" ]; then
      echo false > "$QUEUED_FILE"
      echo 'GraphQL: Pull request is not in the merge queue (dequeuePullRequest)' >&2
      exit 1
    fi
    if [ "${MERGE_ON_DEQUEUE:-0}" = "1" ]; then
      echo false > "$QUEUED_FILE"; echo MERGED > "$PR_STATE_FILE"
      echo 'GraphQL: Pull request is already merged (dequeuePullRequest)' >&2
      exit 1
    fi
    if [ "${DEQUEUE_RC:-0}" != "0" ]; then
      echo 'GraphQL: Resource not accessible by personal access token (dequeuePullRequest)' >&2
      exit "$DEQUEUE_RC"
    fi
    echo false > "$QUEUED_FILE"
    echo '{"data":{"dequeuePullRequest":{"mergeQueueEntry":{"id":"MQE_1"}}}}'
    exit 0
  fi
  [ "${GRAPHQL_READ_RC:-0}" = "0" ] || { echo 'HTTP 502' >&2; exit "$GRAPHQL_READ_RC"; }
  # Live state: latest review per author (GitHub's latestOpinionatedReviews).
  jq -n --slurpfile r "$REVIEWS_FILE" --arg st "$(cat "$PR_STATE_FILE")" \
        --arg q "$(cat "$QUEUED_FILE")" --arg h "$PR_HEAD_SHA" '
    {data: {repository: {pullRequest: {
      id: "PR_node2084", state: $st, headRefOid: $h,
      mergeQueueEntry: (if $q == "true" then {id: "MQE_1"} else null end),
      latestOpinionatedReviews: {nodes: (
        $r[0] | map(select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED"))
        | group_by(.user.login) | map(sort_by(.submitted_at) | last)
        | map({author: {login: .user.login}, state, commit: {oid: .commit_id}}))}
    }}}}'
  exit 0
fi

if [ "$1" = "api" ]; then
  method=GET; path=""; jqf=""; slurp=false; prev=""
  for a in "$@"; do
    case "$prev" in -X) method="$a" ;; --jq) jqf="$a" ;; esac
    case "$a" in --slurp) slurp=true ;; repos/*) path="$a" ;; esac
    prev="$a"
  done
  case "$method $path" in
    "PUT "*/reviews/*/dismissals)
      id=$(echo "$path" | sed -E 's|.*/reviews/([0-9]+)/dismissals|\1|')
      jq --argjson id "$id" 'map(if .id == $id then .state = "DISMISSED" else . end)' \
        "$REVIEWS_FILE" > "$REVIEWS_FILE.tmp" && mv "$REVIEWS_FILE.tmp" "$REVIEWS_FILE"
      exit 0 ;;
    "GET "*/pulls/*/reviews/*)
      id="${path##*/}"
      jq -r --argjson id "$id" '.[] | select(.id == $id) | .state' "$REVIEWS_FILE"
      exit 0 ;;
    "GET "*/pulls/*/reviews)
      if [ "$slurp" = true ]; then jq -s '.' "$REVIEWS_FILE"; else cat "$REVIEWS_FILE"; fi
      exit 0 ;;
    "GET "*/issues/*/comments)
      [ "${COMMENT_LIST_RC:-0}" = "0" ] || exit "$COMMENT_LIST_RC"
      if [ "$slurp" = true ]; then jq -s '.' "$COMMENTS_FILE"; else cat "$COMMENTS_FILE"; fi
      exit 0 ;;
    "GET "*/issues/comments/*)
      id="${path##*/}"
      jq -r --argjson id "$id" '.[] | select(.id == $id) | .body' "$COMMENTS_FILE"
      exit 0 ;;
    "PATCH "*/issues/comments/*)
      exit 0 ;;
    "GET "*/issues/*/events*)
      echo '[]'; exit 0 ;;
  esac
  echo '{}'
  exit 0
fi
exit 0
GHEOF
  chmod +x "$TEST_DIR/bin/gh"
  export PATH="$TEST_DIR/bin:$PATH"
}

# add_review <id> <login> <state> <commit> [<body>] — seed a prior review.
add_review() {
  local ts; ts=$(printf '2026-10-10T00:0%d:00Z' "$(( $1 % 10 ))")
  jq --argjson id "$1" --arg u "$2" --arg s "$3" --arg c "$4" --arg b "${5:-}" --arg ts "$ts" \
    '. + [{id: $id, user: {login: $u}, state: $s, commit_id: $c, body: $b, submitted_at: $ts}]' \
    "$REVIEWS_FILE" > "$REVIEWS_FILE.tmp" && mv "$REVIEWS_FILE.tmp" "$REVIEWS_FILE"
}

# A prior bot approval at the current head (the one the queue admitted the PR on).
seed_prior_bot_approval() {
  add_review 1 "$BOT_USER" APPROVED "$SHA" \
    "LGTM <!-- pr-review-agent v1 sha=$SHA decision=approved risk=LOW -->"
}

# Counts the success and the failure notice alike (distinct per-outcome markers).
marker_count() {
  jq --arg m "<!-- pr-review-agent dequeue" --arg sha "sha=$SHA -->" \
    '[.[] | select((.body | contains($m)) and (.body | contains($sha)))] | length' "$COMMENTS_FILE"
}

dequeue_calls() { grep -c dequeuePullRequest "$CALLS" || true; }

run_lib() { run bash -c 'source "$LIB"; mq_dequeue_if_unapproved "$1"' _ "$PR_URL"; }

approve_verdict() {
  local f="$TEST_DIR/verdict.json"
  jq -n --arg sha "$SHA" \
    '{decision:"approve", risk:"LOW", summary:"clean",
      body:("LGTM again\n\n<!-- pr-review-agent v1 sha=" + $sha + " decision=approved risk=LOW -->")}' > "$f"
  echo "$f"
}

fix_request_verdict() {
  local f="$TEST_DIR/verdict.json"
  jq -n '{decision:"escalate", risk:"MEDIUM", summary:"fix it", body:"- unresolved bot finding"}' > "$f"
  echo "$f"
}

# ── Library: the decision on live state ─────────────────────────────────────

@test "queued, no approval stands for head → dequeued, one marker comment" {
  add_review 1 "$BOT_USER" DISMISSED "$SHA"
  run_lib
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [ "$(dequeue_calls)" -eq 1 ]
  grep -q 'dequeuePullRequest' "$CALLS"
  grep -q 'PR_node2084' "$CALLS"
  [ "$(marker_count)" -eq 1 ]
  [ "$(cat "$QUEUED_FILE")" = "false" ]
  # The notice says why and what happens next.
  jq -r '.[0].body' "$COMMENTS_FILE" | grep -qi 'approval'
  jq -r '.[0].body' "$COMMENTS_FILE" | grep -qi 'merge queue'
  jq -r '.[0].body' "$COMMENTS_FILE" | grep -qi 'next'
}

@test "a human approval stands for the current head → stays queued, no comment" {
  add_review 1 "$BOT_USER" DISMISSED "$SHA"
  add_review 2 "some-maintainer" APPROVED "$SHA"
  run_lib
  [ "$status" -eq 0 ]
  [ "$(dequeue_calls)" -eq 0 ]
  [ "$(marker_count)" -eq 0 ]
  [ "$(cat "$QUEUED_FILE")" = "true" ]
}

@test "an approval on an older commit does not count → dequeued" {
  add_review 2 "some-maintainer" APPROVED "$OLD_SHA"
  run_lib
  [ "$status" -eq 0 ]
  [ "$(dequeue_calls)" -eq 1 ]
  [ "$(marker_count)" -eq 1 ]
}

@test "a reviewer whose latest review requests changes does not count as approving" {
  add_review 2 "some-maintainer" APPROVED "$SHA"
  add_review 3 "some-maintainer" CHANGES_REQUESTED "$SHA"
  run_lib
  [ "$status" -eq 0 ]
  [ "$(dequeue_calls)" -eq 1 ]
}

@test "PR not in the merge queue → no dequeue call, no comment" {
  echo false > "$QUEUED_FILE"
  run_lib
  [ "$status" -eq 0 ]
  [ "$(dequeue_calls)" -eq 0 ]
  [ "$(marker_count)" -eq 0 ]
  [ "$(jq length "$COMMENTS_FILE")" -eq 0 ]
}

@test "PR already merged → no-op, never an error" {
  echo MERGED > "$PR_STATE_FILE"
  echo false > "$QUEUED_FILE"
  run_lib
  [ "$status" -eq 0 ]
  [ "$(dequeue_calls)" -eq 0 ]
  [ "$(jq length "$COMMENTS_FILE")" -eq 0 ]
  [[ "$output" != *"::warning::"* ]]
}

@test "PR leaves the queue between the check and the call → no-op, no comment, exit 0" {
  export LEAVE_QUEUE_ON_DEQUEUE=1
  run_lib
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [ "$(dequeue_calls)" -eq 1 ]
  [ "$(jq length "$COMMENTS_FILE")" -eq 0 ]
  [[ "$output" != *"::warning::"* ]]
}

@test "PR merges between the check and the call → no-op, no comment, exit 0" {
  export MERGE_ON_DEQUEUE=1
  run_lib
  [ "$status" -eq 0 ]
  [ "$(jq length "$COMMENTS_FILE")" -eq 0 ]
  [[ "$output" != *"::warning::"* ]]
}

@test "idempotent: two runs at the same head post the marker comment once" {
  run_lib
  [ "$status" -eq 0 ]
  # The PR was re-queued (e.g. by hand) with still no approval: the second run
  # dequeues again but must not post a second notice for the same head.
  echo true > "$QUEUED_FILE"
  run_lib
  [ "$status" -eq 0 ]
  [ "$(dequeue_calls)" -eq 2 ]
  [ "$(marker_count)" -eq 1 ]
  [ "$(jq length "$COMMENTS_FILE")" -eq 1 ]
}

@test "a failure notice is not masked by an earlier success notice at the same head" {
  run_lib
  [ "$(marker_count)" -eq 1 ]
  echo true > "$QUEUED_FILE"
  export DEQUEUE_RC=1
  run_lib
  [ "$status" -eq 0 ]
  [ "$(marker_count)" -eq 2 ]
  jq -e --arg m "<!-- pr-review-agent dequeue-failed sha=$SHA -->" \
    'map(select(.body | contains($m))) | length == 1' "$COMMENTS_FILE"
}

@test "dequeue call fails → warning, one manual-removal comment, exit 0" {
  export DEQUEUE_RC=1
  run_lib
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [ "$(marker_count)" -eq 1 ]
  jq -r '.[0].body' "$COMMENTS_FILE" | grep -qi 'manually'
  jq -r '.[0].body' "$COMMENTS_FILE" | grep -qi 'maintainer'
  # A repeat failure at the same head does not post a second comment.
  run_lib
  [ "$status" -eq 0 ]
  [ "$(marker_count)" -eq 1 ]
}

@test "live state unreadable → warning naming the failed read, no action, exit 0" {
  export GRAPHQL_READ_RC=1
  run_lib
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"merge-queue"* ]]
  [ "$(dequeue_calls)" -eq 0 ]
  [ "$(jq length "$COMMENTS_FILE")" -eq 0 ]
}

@test "under set -e the helper never aborts its caller" {
  export DEQUEUE_RC=1 COMMENT_LIST_RC=1
  run bash -c 'set -euo pipefail; source "$LIB"; mq_dequeue_if_unapproved "$1"; echo CONTINUED' _ "$PR_URL"
  [ "$status" -eq 0 ]
  [[ "$output" == *CONTINUED* ]]
}

# ── End to end: scripts/post-pr-review.sh ──────────────────────────────────

@test "post-pr-review: re-review dismisses the old approval AND re-approves → stays queued" {
  seed_prior_bot_approval
  local vf; vf=$(approve_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  # The old approval was dismissed by the cleanup block ...
  [ "$(jq -r '.[] | select(.id == 1) | .state' "$REVIEWS_FILE")" = "DISMISSED" ]
  # ... but the new one stands, so the PR stays in the queue.
  [ "$(dequeue_calls)" -eq 0 ]
  [ "$(marker_count)" -eq 0 ]
  [ "$(cat "$QUEUED_FILE")" = "true" ]
  # The live state was actually consulted after the dismissal.
  grep -q 'mergeQueueEntry' "$CALLS"
}

@test "post-pr-review: re-review dismisses the old approval and requests changes → dequeued" {
  seed_prior_bot_approval
  export AI_DELEGATION_ENABLED=true REVIEW_CYCLE=0 MAX_REVIEW_CYCLES=3
  local vf; vf=$(fix_request_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[] | select(.id == 1) | .state' "$REVIEWS_FILE")" = "DISMISSED" ]
  [ "$(dequeue_calls)" -eq 1 ]
  [ "$(marker_count)" -eq 1 ]
  [ "$(cat "$QUEUED_FILE")" = "false" ]
  # The dequeue happens only after the new verdict was posted.
  local fix_line dq_line
  fix_line=$(grep -n '^pr comment' "$CALLS" | head -1 | cut -d: -f1)
  dq_line=$(grep -n 'dequeuePullRequest' "$CALLS" | head -1 | cut -d: -f1)
  [ "$fix_line" -lt "$dq_line" ]
}

@test "post-pr-review: fix-request but a human approval stands for head → stays queued" {
  seed_prior_bot_approval
  add_review 2 "some-maintainer" APPROVED "$SHA"
  export AI_DELEGATION_ENABLED=true REVIEW_CYCLE=0 MAX_REVIEW_CYCLES=3
  local vf; vf=$(fix_request_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[] | select(.id == 1) | .state' "$REVIEWS_FILE")" = "DISMISSED" ]
  [ "$(dequeue_calls)" -eq 0 ]
  [ "$(marker_count)" -eq 0 ]
}

@test "post-pr-review: fix-request on a PR not in the queue → no dequeue call, no notice" {
  seed_prior_bot_approval
  echo false > "$QUEUED_FILE"
  export AI_DELEGATION_ENABLED=true REVIEW_CYCLE=0 MAX_REVIEW_CYCLES=3
  local vf; vf=$(fix_request_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  [ "$status" -eq 0 ]
  [ "$(dequeue_calls)" -eq 0 ]
  [ "$(marker_count)" -eq 0 ]
}

@test "post-pr-review: a failing dequeue never fails the run" {
  seed_prior_bot_approval
  export AI_DELEGATION_ENABLED=true REVIEW_CYCLE=0 MAX_REVIEW_CYCLES=3 DEQUEUE_RC=1
  local vf; vf=$(fix_request_verdict)
  run bash "$POST_SCRIPT" "$PR_URL" "$vf" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [ "$(marker_count)" -eq 1 ]
  jq -r --arg m "<!-- pr-review-agent dequeue-failed sha=$SHA -->" \
    '.[] | select(.body | contains($m)) | .body' "$COMMENTS_FILE" | grep -qi 'manually'
}

# ── End to end: scripts/invalidate-standing-approval.sh ─────────────────────

isa_node() {
  jq -n --arg sha "$SHA" '{url:"x", reviews:{nodes:[
    {author:{login:"donpetry-bot"}, state:"APPROVED", submittedAt:"2026-10-10T00:01:00Z",
     bodyText:("<!-- pr-review-agent v1 sha=" + $sha + " decision=approved risk=LOW -->")}]},
    reviewThreads:{nodes:[{isResolved:true, comments:{nodes:[
      {author:{login:"coderabbitai"}, createdAt:"2026-10-10T00:02:00Z", bodyText:"Real defect: nil deref."},
      {author:{login:"donpetry-bot"}, createdAt:"2026-10-10T00:03:00Z", bodyText:"Good catch, fixed."}]}}]},
    comments:{nodes:[]}}'
}

@test "invalidate-standing-approval (live): dismissing the last approval dequeues" {
  seed_prior_bot_approval
  export PR_NODE_JSON; PR_NODE_JSON=$(isa_node)
  run env DRY_RUN=false bash "$ISA_SCRIPT" "$PR_URL"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[] | select(.id == 1) | .state' "$REVIEWS_FILE")" = "DISMISSED" ]
  [ "$(dequeue_calls)" -eq 1 ]
  [ "$(marker_count)" -eq 1 ]
}

@test "invalidate-standing-approval (live): a human approval stands → stays queued" {
  seed_prior_bot_approval
  add_review 2 "some-maintainer" APPROVED "$SHA"
  export PR_NODE_JSON; PR_NODE_JSON=$(isa_node)
  run env DRY_RUN=false bash "$ISA_SCRIPT" "$PR_URL"
  [ "$status" -eq 0 ]
  [ "$(dequeue_calls)" -eq 0 ]
  [ "$(marker_count)" -eq 0 ]
}

@test "invalidate-standing-approval (DRY_RUN): never dequeues" {
  seed_prior_bot_approval
  export PR_NODE_JSON; PR_NODE_JSON=$(isa_node)
  run env DRY_RUN=true bash "$ISA_SCRIPT" "$PR_URL"
  [ "$status" -eq 0 ]
  [ "$(dequeue_calls)" -eq 0 ]
  [ "$(jq length "$COMMENTS_FILE")" -eq 0 ]
}

@test "invalidate-standing-approval (live): nothing dismissed → no queue check" {
  add_review 1 "$BOT_USER" APPROVED "$SHA" "LGTM (no marker)"
  export PR_NODE_JSON; PR_NODE_JSON=$(isa_node)
  run env DRY_RUN=false bash "$ISA_SCRIPT" "$PR_URL"
  [ "$status" -eq 0 ]
  [ "$(dequeue_calls)" -eq 0 ]
  run grep -q mergeQueueEntry "$CALLS"
  [ "$status" -ne 0 ]
}

# ── Static: the stale CHANGES_REQUESTED dismisser is out of scope ───────────

@test "dismiss-stale-bot-reviews.yml carries no dequeue logic" {
  local wf="$REPO_ROOT/.github/workflows/dismiss-stale-bot-reviews.yml"
  [ -f "$wf" ]
  run grep -niE 'dequeue|mergeQueue|merge-queue|merge_queue' "$wf"
  [ "$status" -ne 0 ]
}

# ── Static: every approval-dismissal site is paired with the dequeue (#2174) ──

@test "every dismissal site in scripts/ is followed by mq_dequeue_if_unapproved" {
  local f n sites
  sites=$(grep -rlE 'dismissPullRequestReview|/dismissals' "$REPO_ROOT/scripts" \
    | while read -r f; do grep -vE '^\s*#' "$f" | grep -qE 'dismissPullRequestReview|/dismissals' && echo "$f"; done)
  [ -n "$sites" ]
  for f in $sites; do
    grep -qF 'lib/merge-queue-dequeue.sh' "$f"
    grep -vE '^\s*#' "$f" | grep -qF 'mq_dequeue_if_unapproved'
  done
  # review-one-pr.sh dismisses inside branches: each dismissal is followed by the
  # call within its own branch.
  local r="$REPO_ROOT/scripts/review-one-pr.sh"
  [ "$(grep -c 'dismissPullRequestReview' "$r")" -eq 2 ]
  [ "$(grep -A4 'dismissPullRequestReview' "$r" | grep -c '^[0-9]*-\s*mq_dequeue_if_unapproved ')" -eq 2 ] \
    || [ "$(grep -A4 'dismissPullRequestReview' "$r" | grep -c 'mq_dequeue_if_unapproved "\$PR_URL" || true')" -eq 2 ]
}
