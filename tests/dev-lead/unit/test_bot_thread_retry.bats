#!/usr/bin/env bats
# Unit tests for the unreplied bot review-thread retry (#2046) — the review-thread
# counterpart of the #2017 bot-comment retry.
#
# A trusted reviewer bot's review thread is processed ONLY by a dev-lead
# fix-reviews pass. When that pass is lost (superseded in the per-PR lane, routed
# elsewhere, or blind to the thread), nothing retried it: the thread sat with no
# reply and no resolution, and required_review_thread_resolution blocked the
# merge (PR #1953). These tests pin:
#   • the pure decision (lib/bot-thread-retry.sh, btr_retry_decisions);
#   • the sweep wiring in dev-lead-retry.sh (exactly one fix-reviews dispatch per
#     PR, a dedup marker posted before it, exhaustion surfaced once);
#   • the fix-reviews thread enumeration (lib/open-review-threads.sh) seeing every
#     unresolved thread across pages, reviewers and older reviews.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/bot-thread-retry.sh"
RETRY_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-retry.sh"

TRUSTED='cubic-dev-ai[bot],chatgpt-codex-connector[bot],coderabbitai[bot]'
# The logins our own automation posts markers and replies as (dev-lead, pr-review).
AUTOMATION='don-petry,donpetry-bot'
# 2026-10-02T01:00:00Z — two hours after the threads below were opened.
NOW_EPOCH=1790902800

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
  export BOT_THREAD_RETRY_MIN_AGE_SEC=900
  export BOT_THREAD_RETRY_PENDING_SEC=9000
  export BOT_THREAD_RETRY_MAX_ATTEMPTS=2
  export BOT_THREAD_RETRY_MAX_TOTAL=6
}

# _reply <login> <body> [createdAt] [typename]
_reply() {
  jq -nc --arg l "$1" --arg b "$2" --arg c "${3:-2026-10-01T23:40:00Z}" --arg t "${4:-User}" '
    {author:{login:$l, __typename:$t}, body:$b, createdAt:$c}'
}

# _thread <id> <login> [createdAt] [typename] [isOutdated] [isResolved] [reply...]
_thread() {
  local id="$1" login="$2" created="${3:-2026-10-01T23:05:43Z}" type="${4:-Bot}"
  local outdated="${5:-false}" resolved="${6:-false}"
  shift 6 2>/dev/null || shift $#
  local replies='[]'
  [ "$#" -eq 0 ] || replies="$(jq -sc '.' <<< "$*")"
  jq -nc --arg id "$id" --arg l "$login" --arg c "$created" --arg t "$type" \
    --argjson o "$outdated" --argjson r "$resolved" --argjson rep "$replies" '
    ([{author:{login:$l, __typename:$t}, body:"Finding from \($l)", createdAt:$c}] + $rep) as $cs
    | {id:$id, isResolved:$r, isOutdated:$o, path:"scripts/canary_report.sh", line:121,
       comments:{totalCount:($cs | length), nodes:$cs}}'
}

# _ours <body> [createdAt] [association] [login] — a PR issue comment from our automation.
_ours() {
  jq -nc --arg b "$1" --arg c "${2:-2026-10-01T23:30:00Z}" --arg a "${3:-OWNER}" --arg l "${4:-don-petry}" '
    {id:("IC_ours_" + ($c | gsub("[^0-9]";"")) + "_" + $l), author:{login:$l, __typename:"User"},
     authorAssociation:$a, body:$b, createdAt:$c, lastEditedAt:null,
     isMinimized:false, minimizedReason:null}'
}

# _decide <threads_json> [comment...]
_decide() {
  local threads="$1"; shift
  local comments='[]'
  [ "$#" -eq 0 ] || comments="$(jq -sc '.' <<< "$*")"
  btr_retry_decisions "$threads" "$comments" "$TRUSTED" "$NOW_EPOCH" "$AUTOMATION"
}

_threads() { jq -sc '.' <<< "$*"; }
_reason_for() { jq -r --arg id "$2" 'first(.threads[] | select(.id == $id)) | .reason // "none"' <<< "$1"; }
_dispatch_ids() { jq -r '.dispatch | join(",")' <<< "$1"; }

_retry_marker() { # <threads_csv> <attempt> <at>
  printf '<!-- dev-lead-bot-thread-retry threads=%s attempt=%s at=%s -->' "$1" "$2" "$3"
}

# ── btr_retry_decisions: AC1 / AC2 ──────────────────────────────────────────

@test "btr: an unreplied trusted-bot thread past the grace period → dispatch, attempt 1" {
  out="$(_decide "$(_threads "$(_thread PRRT_cubic cubic-dev-ai)")")"
  [ "$(_dispatch_ids "$out")" = "PRRT_cubic" ]
  [ "$(jq -r '.attempt' <<< "$out")" = "1" ]
  [ "$(_reason_for "$out" PRRT_cubic)" = "unreplied" ]
}

@test "btr: a thread with an our-account reply is not retried" {
  out="$(_decide "$(_threads "$(_thread PRRT_cubic cubic-dev-ai '' '' '' '' \
    "$(_reply don-petry 'Deferred: out of scope for this PR.')")")")"
  [ "$(_dispatch_ids "$out")" = "" ]
  [ "$(_reason_for "$out" PRRT_cubic)" = "replied" ]
}

@test "btr: a pr-review-identity reply ([bot] suffix tolerated) also counts as ours" {
  out="$(_decide "$(_threads "$(_thread PRRT_cubic cubic-dev-ai '' '' '' '' \
    "$(_reply 'donpetry-bot[bot]' 'noted')")")")"
  [ "$(_reason_for "$out" PRRT_cubic)" = "replied" ]
}

@test "btr: a reply from someone else (another bot, a drive-by user) does not count" {
  out="$(_decide "$(_threads "$(_thread PRRT_cubic cubic-dev-ai '' '' '' '' \
    "$(_reply coderabbitai 'I agree' 2026-10-01T23:40:00Z Bot)" \
    "$(_reply mallory 'lgtm')")")")"
  [ "$(_dispatch_ids "$out")" = "PRRT_cubic" ]
}

@test "btr: outdated, resolved, maintainer and untrusted-bot threads are never candidates" {
  out="$(_decide "$(_threads \
    "$(_thread PRRT_outdated cubic-dev-ai '' Bot true false)" \
    "$(_thread PRRT_resolved cubic-dev-ai '' Bot false true)" \
    "$(_thread PRRT_maint don-petry '' User)" \
    "$(_thread PRRT_human someone '' User)" \
    "$(_thread PRRT_untrusted random-bot '' Bot)" \
    "$(_thread PRRT_fake chatgpt-codex-connector '' User)")")"
  [ "$(jq -r '.threads | length' <<< "$out")" = "0" ]
  [ "$(_dispatch_ids "$out")" = "" ]
}

@test "btr: a thread too new for the grace period waits" {
  out="$(_decide "$(_threads "$(_thread PRRT_new chatgpt-codex-connector 2026-10-02T00:55:00Z)")")"
  [ "$(_dispatch_ids "$out")" = "" ]
  [ "$(_reason_for "$out" PRRT_new)" = "grace-period" ]
}

@test "btr: threads from several reviewers and reviews are covered by ONE dispatch, oldest first" {
  out="$(_decide "$(_threads \
    "$(_thread PRRT_codex_new chatgpt-codex-connector 2026-10-01T23:50:00Z)" \
    "$(_thread PRRT_cubic cubic-dev-ai 2026-10-01T11:35:00Z)" \
    "$(_thread PRRT_codex_old chatgpt-codex-connector 2026-10-01T20:49:00Z)")")"
  [ "$(_dispatch_ids "$out")" = "PRRT_cubic,PRRT_codex_old,PRRT_codex_new" ]
  [ "$(jq -r '.attempt' <<< "$out")" = "1" ]
}

# ── dedup, rate-limit awareness, attempt caps (AC1 / AC3) ────────────────────

@test "btr: a pending bot-comment retry marker holds every thread (shared per-PR lane)" {
  out="$(_decide "$(_threads \
      "$(_thread PRRT_cubic cubic-dev-ai)")" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_x version=2026-10-02T00:00:00Z attempt=1 at=2026-10-02T00:30:00Z -->' 2026-10-02T00:30:00Z)")"
  [ "$(_dispatch_ids "$out")" = "" ]
  [ "$(_reason_for "$out" PRRT_cubic)" = "retry-pending" ]
}

@test "btr: an expired bot-comment retry marker does not hold the thread dispatch" {
  out="$(_decide "$(_threads \
      "$(_thread PRRT_cubic cubic-dev-ai 2026-10-01T10:00:00Z)")" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_x version=2026-10-01T20:00:00Z attempt=1 at=2026-10-01T20:00:00Z -->' 2026-10-01T20:00:00Z)")"
  [ "$(_dispatch_ids "$out")" = "PRRT_cubic" ]
}

@test "btr: a retry marker inside the pending window holds EVERY thread on the PR" {
  out="$(_decide "$(_threads \
      "$(_thread PRRT_cubic cubic-dev-ai)" \
      "$(_thread PRRT_codex chatgpt-codex-connector)")" \
    "$(_ours "$(_retry_marker PRRT_cubic 1 2026-10-02T00:30:00Z)" 2026-10-02T00:30:00Z)")"
  [ "$(_dispatch_ids "$out")" = "" ]
  [ "$(_reason_for "$out" PRRT_cubic)" = "retry-pending" ]
  [ "$(_reason_for "$out" PRRT_codex)" = "retry-pending" ]
}

@test "btr: after an expired retry the next attempt is attempt 2" {
  out="$(_decide "$(_threads "$(_thread PRRT_cubic cubic-dev-ai 2026-10-01T10:00:00Z)")" \
    "$(_ours "$(_retry_marker PRRT_cubic 1 2026-10-01T20:00:00Z)" 2026-10-01T20:00:00Z)")"
  [ "$(_dispatch_ids "$out")" = "PRRT_cubic" ]
  [ "$(jq -r '.attempt' <<< "$out")" = "2" ]
}

@test "btr: MAX_ATTEMPTS expired retries exhaust the thread and report it" {
  out="$(_decide "$(_threads "$(_thread PRRT_cubic cubic-dev-ai 2026-10-01T10:00:00Z)")" \
    "$(_ours "$(_retry_marker PRRT_cubic 1 2026-10-01T12:00:00Z)" 2026-10-01T12:00:00Z)" \
    "$(_ours "$(_retry_marker PRRT_cubic,PRRT_other 2 2026-10-01T15:00:00Z)" 2026-10-01T15:00:00Z)")"
  [ "$(_dispatch_ids "$out")" = "" ]
  [ "$(_reason_for "$out" PRRT_cubic)" = "retry-attempts-exhausted" ]
  [ "$(jq -r '.exhausted | join(",")' <<< "$out")" = "PRRT_cubic" ]
  [ "$(jq -r '.exhausted_unnoticed | join(",")' <<< "$out")" = "PRRT_cubic" ]
}

@test "btr: an exhausted thread already named in an exhaustion notice is not re-noticed" {
  out="$(_decide "$(_threads "$(_thread PRRT_cubic cubic-dev-ai 2026-10-01T10:00:00Z)")" \
    "$(_ours "$(_retry_marker PRRT_cubic 1 2026-10-01T12:00:00Z)" 2026-10-01T12:00:00Z)" \
    "$(_ours "$(_retry_marker PRRT_cubic 2 2026-10-01T15:00:00Z)" 2026-10-01T15:00:00Z)" \
    "$(_ours '<!-- dev-lead-bot-thread-retry-exhausted threads=PRRT_cubic -->' 2026-10-01T20:00:00Z)")"
  [ "$(jq -r '.exhausted | join(",")' <<< "$out")" = "PRRT_cubic" ]
  [ "$(jq -r '.exhausted_unnoticed | length' <<< "$out")" = "0" ]
}

@test "btr: an exhaustion notice naming a different thread does not hide a newly exhausted one" {
  out="$(_decide "$(_threads "$(_thread PRRT_cubic cubic-dev-ai 2026-10-01T10:00:00Z)")" \
    "$(_ours "$(_retry_marker PRRT_cubic 1 2026-10-01T12:00:00Z)" 2026-10-01T12:00:00Z)" \
    "$(_ours "$(_retry_marker PRRT_cubic 2 2026-10-01T15:00:00Z)" 2026-10-01T15:00:00Z)" \
    "$(_ours '<!-- dev-lead-bot-thread-retry-exhausted threads=PRRT_other -->' 2026-10-01T20:00:00Z)")"
  [ "$(jq -r '.exhausted_unnoticed | join(",")' <<< "$out")" = "PRRT_cubic" ]
}

@test "btr: the exhaustion notice marker is not mistaken for a retry marker" {
  out="$(_decide "$(_threads "$(_thread PRRT_cubic cubic-dev-ai)")" \
    "$(_ours '<!-- dev-lead-bot-thread-retry-exhausted threads=PRRT_cubic -->' 2026-10-02T00:30:00Z)")"
  [ "$(_dispatch_ids "$out")" = "PRRT_cubic" ]
  [ "$(jq -r '.attempt' <<< "$out")" = "1" ]
}

@test "btr: an active rate-limited fix-reviews hold defers the retry" {
  out="$(_decide "$(_threads "$(_thread PRRT_cubic cubic-dev-ai)")" \
    "$(_ours '<!-- dev-lead-fix-reviews pr=1953 sha=abc intent=fix-reviews status=rate-limited reason=quota reset=2026-10-02T03:00:00Z -->' 2026-10-02T00:10:00Z)")"
  [ "$(_dispatch_ids "$out")" = "" ]
  [ "$(_reason_for "$out" PRRT_cubic)" = "rate-limited" ]
}

@test "btr: retries that ran into a rate limit do not count toward MAX_ATTEMPTS" {
  out="$(_decide "$(_threads "$(_thread PRRT_cubic cubic-dev-ai 2026-10-01T10:00:00Z)")" \
    "$(_ours "$(_retry_marker PRRT_cubic 1 2026-10-01T12:00:00Z)" 2026-10-01T12:00:00Z)" \
    "$(_ours "$(_retry_marker PRRT_cubic 2 2026-10-01T15:00:00Z)" 2026-10-01T15:00:00Z)" \
    "$(_ours '<!-- dev-lead-fix-reviews pr=1953 sha=abc intent=fix-reviews status=rate-limited reason=quota reset=2026-10-01T18:00:00Z -->' 2026-10-01T16:00:00Z)")"
  [ "$(_dispatch_ids "$out")" = "PRRT_cubic" ]
  [ "$(jq -r '.attempt' <<< "$out")" = "3" ]
}

@test "btr: MAX_TOTAL caps retries even across rate-limited windows" {
  export BOT_THREAD_RETRY_MAX_TOTAL=2
  out="$(_decide "$(_threads "$(_thread PRRT_cubic cubic-dev-ai 2026-10-01T10:00:00Z)")" \
    "$(_ours "$(_retry_marker PRRT_cubic 1 2026-10-01T12:00:00Z)" 2026-10-01T12:00:00Z)" \
    "$(_ours "$(_retry_marker PRRT_cubic 2 2026-10-01T15:00:00Z)" 2026-10-01T15:00:00Z)" \
    "$(_ours '<!-- dev-lead-fix-reviews pr=1953 sha=abc intent=fix-reviews status=rate-limited reason=quota reset=2026-10-01T18:00:00Z -->' 2026-10-01T16:00:00Z)")"
  [ "$(_reason_for "$out" PRRT_cubic)" = "retry-attempts-exhausted" ]
}

@test "btr: retry markers from outside our automation are ignored (no forged hold)" {
  out="$(_decide "$(_threads "$(_thread PRRT_cubic cubic-dev-ai)")" \
    "$(_ours "$(_retry_marker PRRT_cubic 9 2026-10-02T00:50:00Z)" 2026-10-02T00:50:00Z MEMBER mallory)" \
    "$(_ours "$(_retry_marker PRRT_cubic 9 2026-10-02T00:50:00Z)" 2026-10-02T00:50:00Z NONE don-petry)")"
  [ "$(_dispatch_ids "$out")" = "PRRT_cubic" ]
  [ "$(jq -r '.attempt' <<< "$out")" = "1" ]
}

@test "btr: a thread whose comments exceed one page fails closed (not retried)" {
  t="$(_thread PRRT_long cubic-dev-ai | jq -c '.comments.totalCount = 150')"
  out="$(_decide "$(_threads "$t")")"
  [ "$(_dispatch_ids "$out")" = "" ]
  [ "$(_reason_for "$out" PRRT_long)" = "thread-unreadable" ]
}

@test "btr: unreadable input or no automation logins fails closed" {
  run btr_retry_decisions 'not-json' '[]' "$TRUSTED" "$NOW_EPOCH" "$AUTOMATION"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  run btr_retry_decisions "$(_threads "$(_thread PRRT_cubic cubic-dev-ai)")" '[]' "$TRUSTED" "$NOW_EPOCH" ""
  [ "$status" -ne 0 ]
  run btr_retry_decisions "$(_threads "$(_thread PRRT_cubic cubic-dev-ai)")" '[]' "$TRUSTED" "soon" "$AUTOMATION"
  [ "$status" -ne 0 ]
}

# ── btr_fetch_pr_threads: fails closed on a partial snapshot ─────────────────

@test "btr_fetch_pr_threads: concatenates pages and fails closed on GraphQL errors" {
  MOCK_BIN="$(mktemp -d)"
  export PATH="$MOCK_BIN:$PATH"
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"cursor=C1"*) printf '%s' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":"C2"},"nodes":[{"id":"T2"}]}}}}}' ;;
  *) printf '%s' "${FIRST_PAGE}" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"
  export FIRST_PAGE='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"C1"},"nodes":[{"id":"T1"}]}}}}}'
  run btr_fetch_pr_threads "petry-projects/.github-private" 1953
  [ "$status" -eq 0 ]
  [ "$(jq -r 'map(.id) | join(",")' <<< "$output")" = "T1,T2" ]
  export FIRST_PAGE='{"errors":[{"message":"boom"}],"data":null}'
  run btr_fetch_pr_threads "petry-projects/.github-private" 1953
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ── sweep wiring (dev-lead-retry.sh) ─────────────────────────────────────────

_setup_sweep() {
  MOCK_BIN="$(mktemp -d)"
  export PATH="$MOCK_BIN:$PATH"
  export DRY_RUN="false"
  export NOW_ISO="2026-10-02T01:00:00Z"
  export GH_LOG="$MOCK_BIN/gh.log"
  export BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC=0
  export TRUSTED_BOTS="$TRUSTED"
  export DEV_LEAD_USER="don-petry" PR_REVIEW_USER="donpetry-bot"
  : "${COMMENTS_RESPONSE:=$(_comments_page)}"
  export COMMENTS_RESPONSE
  # By default the post-write marker listing sees only our own marker (id 888).
  if [ -z "${MARKER_LISTING:-}" ]; then
    MARKER_LISTING='{"id":888,"created_at":"2026-10-02T01:00:00Z"}'
  fi
  export MARKER_LISTING
  if [ -z "${PR_JSON:-}" ]; then
    export PR_JSON='{"state":"open","head":{"sha":"abc","ref":"dev-lead/issue-1900-x","repo":{"full_name":"petry-projects/.github-private"}},"user":{"login":"don-petry"},"labels":[]}'
  fi
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
case "$args" in
  *"/dispatches"*) cat > "$GH_LOG.payload"; [ -n "${DISPATCH_FAILS:-}" ] && exit 1; exit 0 ;;
  *"api graphql"*"reviewThreads"*) printf '%s' "$THREADS_RESPONSE" ;;
  *"api graphql"*) printf '%s' "$COMMENTS_RESPONSE" ;;
  *"--method POST"*"/comments"*) echo "888" ;;
  *"-X DELETE"*) exit 0 ;;
  *"comments?per_page"*"dev-lead-bot-thread-retry"*) printf '%s\n' "$MARKER_LISTING" ;;
  *"/pulls/"*) printf '%s' "$PR_JSON" ;;
  *) echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"
  # shellcheck source=/dev/null
  source "$RETRY_SCRIPT"
  # The automation-budget gate needs its own API reads; it is covered elsewhere.
  pr_resume_suppressed() { return 1; }
}

_threads_page() {
  jq -nc --argjson nodes "$(jq -sc '.' <<< "$*")" \
    '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$nodes}}}}}'
}

_comments_page() {
  local nodes='[]'
  [ "$#" -eq 0 ] || nodes="$(jq -sc '.' <<< "$*")"
  jq -nc --argjson nodes "$nodes" \
    '{data:{repository:{pullRequest:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$nodes}}}}}'
}

@test "sweep: unreplied bot threads dispatch exactly one fix-reviews retry, marker first" {
  export THREADS_RESPONSE
  THREADS_RESPONSE="$(_threads_page \
    "$(_thread PRRT_cubic cubic-dev-ai 2026-10-01T11:35:00Z)" \
    "$(_thread PRRT_codex chatgpt-codex-connector 2026-10-01T22:49:00Z)" \
    "$(_thread PRRT_done chatgpt-codex-connector 2026-10-01T20:00:00Z Bot false false \
       "$(_reply don-petry 'Fixed in abc. <!-- dev-lead:addressed -->')")")"
  _setup_sweep

  run scan_pr_for_unreplied_bot_threads "petry-projects/.github-private" 1953
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "1" ]
  [ "$(grep -c '/dispatches' "$GH_LOG")" -eq 1 ]
  payload="$(cat "$GH_LOG.payload")"
  [ "$(jq -r '.event_type' <<< "$payload")" = "dev-lead-reviews-retry" ]
  [ "$(jq -r '.client_payload.intent_type' <<< "$payload")" = "fix-reviews" ]
  [ "$(jq -r '.client_payload.pr_number' <<< "$payload")" = "1953" ]
  grep -q 'dev-lead-bot-thread-retry threads=PRRT_cubic,PRRT_codex attempt=1 at=2026-10-02T01:00:00Z' "$GH_LOG"
  if grep -q 'PRRT_done' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  marker_line=$(grep -n 'dev-lead-bot-thread-retry' "$GH_LOG" | head -1 | cut -d: -f1)
  dispatch_line=$(grep -n '/dispatches' "$GH_LOG" | head -1 | cut -d: -f1)
  [ "$marker_line" -lt "$dispatch_line" ]
}

@test "sweep(#2089): a dev-lead:hands-off PR gets no retry marker and no dispatch" {
  export PR_JSON='{"state":"open","head":{"sha":"abc","ref":"dev-lead/issue-1900-x","repo":{"full_name":"petry-projects/.github-private"}},"user":{"login":"don-petry"},"labels":[{"name":"dev-lead:hands-off"}]}'
  export THREADS_RESPONSE
  THREADS_RESPONSE="$(_threads_page "$(_thread PRRT_cubic cubic-dev-ai 2026-10-01T11:35:00Z)")"
  _setup_sweep
  # Use the REAL resume gate (the default harness stubs it to "proceed").
  # shellcheck source=/dev/null
  source "$(dirname "$RETRY_SCRIPT")/lib/pr-automation-budget.sh"

  run scan_pr_for_unreplied_bot_threads "petry-projects/.github-private" 1902
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q 'dev-lead-bot-thread-retry' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q 'dev-lead-dispatch-guard' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a pending retry (from the cron or pr-review's hook) dedups the next scan" {
  export THREADS_RESPONSE COMMENTS_RESPONSE
  THREADS_RESPONSE="$(_threads_page "$(_thread PRRT_cubic cubic-dev-ai)")"
  COMMENTS_RESPONSE="$(_comments_page \
    "$(_ours "$(_retry_marker PRRT_cubic 1 2026-10-02T00:30:00Z)" 2026-10-02T00:30:00Z MEMBER donpetry-bot)")"
  _setup_sweep

  run scan_pr_for_unreplied_bot_threads "petry-projects/.github-private" 1953
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q -- '--method POST' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a recent dispatch guard for the head SHA defers to the run already queued" {
  export THREADS_RESPONSE COMMENTS_RESPONSE
  THREADS_RESPONSE="$(_threads_page "$(_thread PRRT_cubic cubic-dev-ai)")"
  COMMENTS_RESPONSE="$(_comments_page \
    "$(_ours '<!-- dev-lead-dispatch-guard sha=abc at=2026-10-02T00:58:00Z -->' 2026-10-02T00:58:00Z MEMBER don-petry)")"
  _setup_sweep

  run --separate-stderr scan_pr_for_unreplied_bot_threads "petry-projects/.github-private" 1953
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0" ]
  [[ "$stderr" == *"recent dispatch guard"* ]]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q -- '--method POST' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a dispatch guard posted by a non-automation commenter is ignored" {
  export THREADS_RESPONSE COMMENTS_RESPONSE
  THREADS_RESPONSE="$(_threads_page "$(_thread PRRT_cubic cubic-dev-ai)")"
  COMMENTS_RESPONSE="$(_comments_page \
    "$(_ours '<!-- dev-lead-dispatch-guard sha=abc at=2026-10-02T00:58:00Z -->' 2026-10-02T00:58:00Z NONE some-user)")"
  _setup_sweep
  run scan_pr_for_unreplied_bot_threads "petry-projects/.github-private" 1953
  [ "${lines[-1]}" = "1" ]
  [ "$(grep -c '/dispatches' "$GH_LOG")" -eq 1 ]
}

@test "has_dispatch_guard: any in-window guard counts; a far-future guard never does" {
  _setup_sweep
  # An older out-of-window guard listed first must not hide a recent one.
  run has_dispatch_guard '["<!-- dev-lead-dispatch-guard sha=abc at=2026-10-01T00:00:00Z -->","<!-- dev-lead-dispatch-guard sha=abc at=2026-10-02T00:58:00Z -->"]' abc
  [ "$status" -eq 0 ]
  run has_dispatch_guard '["<!-- dev-lead-dispatch-guard sha=abc at=2099-01-01T00:00:00Z -->"]' abc
  [ "$status" -eq 1 ]
  run has_dispatch_guard '["<!-- dev-lead-dispatch-guard sha=abc at=2026-10-01T00:00:00Z -->"]' abc
  [ "$status" -eq 1 ]
}

@test "sweep: a concurrent scan's earlier marker wins — this scan withdraws and does not dispatch" {
  export THREADS_RESPONSE MARKER_LISTING
  THREADS_RESPONSE="$(_threads_page "$(_thread PRRT_cubic cubic-dev-ai)")"
  MARKER_LISTING='{"id":700,"created_at":"2026-10-02T00:59:58Z"}
{"id":888,"created_at":"2026-10-02T01:00:00Z"}'
  _setup_sweep

  run scan_pr_for_unreplied_bot_threads "petry-projects/.github-private" 1953
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  grep -q -- '-X DELETE repos/petry-projects/.github-private/issues/comments/888' "$GH_LOG"
}

@test "sweep: an expired marker from a lost run never beats this scan's claim" {
  export THREADS_RESPONSE COMMENTS_RESPONSE MARKER_LISTING
  THREADS_RESPONSE="$(_threads_page "$(_thread PRRT_cubic cubic-dev-ai 2026-10-01T10:00:00Z)")"
  COMMENTS_RESPONSE="$(_comments_page \
    "$(_ours "$(_retry_marker PRRT_cubic 1 2026-10-01T20:00:00Z)" 2026-10-01T20:00:00Z)")"
  MARKER_LISTING='{"id":500,"created_at":"2026-10-01T20:00:00Z"}
{"id":888,"created_at":"2026-10-02T01:00:00Z"}'
  _setup_sweep

  run scan_pr_for_unreplied_bot_threads "petry-projects/.github-private" 1953
  [ "${lines[-1]}" = "1" ]
  grep -q 'dev-lead-bot-thread-retry threads=PRRT_cubic attempt=2 ' "$GH_LOG"
  [ "$(grep -c '/dispatches' "$GH_LOG")" -eq 1 ]
}

@test "sweep: a failed dispatch withdraws its marker" {
  export THREADS_RESPONSE DISPATCH_FAILS=1
  THREADS_RESPONSE="$(_threads_page "$(_thread PRRT_cubic cubic-dev-ai)")"
  _setup_sweep

  run scan_pr_for_unreplied_bot_threads "petry-projects/.github-private" 1953
  [ "${lines[-1]}" = "0" ]
  grep -q '/dispatches' "$GH_LOG"
  grep -q -- '-X DELETE repos/petry-projects/.github-private/issues/comments/888' "$GH_LOG"
}

@test "sweep: exhausted attempts post ONE visible notice, and a later scan does not repeat it" {
  export THREADS_RESPONSE COMMENTS_RESPONSE
  THREADS_RESPONSE="$(_threads_page "$(_thread PRRT_cubic cubic-dev-ai 2026-10-01T10:00:00Z)")"
  COMMENTS_RESPONSE="$(_comments_page \
    "$(_ours "$(_retry_marker PRRT_cubic 1 2026-10-01T12:00:00Z)" 2026-10-01T12:00:00Z)" \
    "$(_ours "$(_retry_marker PRRT_cubic 2 2026-10-01T15:00:00Z)" 2026-10-01T15:00:00Z)")"
  _setup_sweep

  run scan_pr_for_unreplied_bot_threads "petry-projects/.github-private" 1953
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  [ "$(grep -c 'dev-lead-bot-thread-retry-exhausted threads=PRRT_cubic' "$GH_LOG")" -eq 1 ]
  grep -q 'scripts/canary_report.sh:121' "$GH_LOG"

  : > "$GH_LOG"
  COMMENTS_RESPONSE="$(_comments_page \
    "$(_ours "$(_retry_marker PRRT_cubic 1 2026-10-01T12:00:00Z)" 2026-10-01T12:00:00Z)" \
    "$(_ours "$(_retry_marker PRRT_cubic 2 2026-10-01T15:00:00Z)" 2026-10-01T15:00:00Z)" \
    "$(_ours '<!-- dev-lead-bot-thread-retry-exhausted threads=PRRT_cubic -->' 2026-10-01T20:00:00Z MEMBER donpetry-bot)")"
  run scan_pr_for_unreplied_bot_threads "petry-projects/.github-private" 1953
  [ "${lines[-1]}" = "0" ]
  if grep -q -- '--method POST' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: no exhaustion notice while another thread is dispatched (the pass covers every thread)" {
  export THREADS_RESPONSE COMMENTS_RESPONSE
  THREADS_RESPONSE="$(_threads_page \
    "$(_thread PRRT_cubic cubic-dev-ai 2026-10-01T10:00:00Z)" \
    "$(_thread PRRT_codex chatgpt-codex-connector 2026-10-01T22:49:00Z)")"
  COMMENTS_RESPONSE="$(_comments_page \
    "$(_ours "$(_retry_marker PRRT_cubic 1 2026-10-01T12:00:00Z)" 2026-10-01T12:00:00Z)" \
    "$(_ours "$(_retry_marker PRRT_cubic 2 2026-10-01T15:00:00Z)" 2026-10-01T15:00:00Z)")"
  _setup_sweep

  run scan_pr_for_unreplied_bot_threads "petry-projects/.github-private" 1953
  [ "${lines[-1]}" = "1" ]
  [ "$(grep -c '/dispatches' "$GH_LOG")" -eq 1 ]
  if grep -q 'dev-lead-bot-thread-retry-exhausted' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a PR dev-lead did not author is never scanned" {
  export THREADS_RESPONSE
  THREADS_RESPONSE="$(_threads_page "$(_thread PRRT_cubic cubic-dev-ai)")"
  export PR_JSON='{"state":"open","head":{"sha":"abc","ref":"dev-lead/issue-1-x","repo":{"full_name":"petry-projects/.github-private"}},"user":{"login":"someone"},"labels":[]}'
  _setup_sweep

  run scan_pr_for_unreplied_bot_threads "petry-projects/.github-private" 1953
  [ "${lines[-1]}" = "0" ]
  if grep -q 'graphql' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: an unreadable thread list fails closed" {
  export THREADS_RESPONSE='{"errors":[{"message":"boom"}]}'
  _setup_sweep

  run scan_pr_for_unreplied_bot_threads "petry-projects/.github-private" 1953
  [ "${lines[-1]}" = "0" ]
  if grep -q -- '--method POST' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: scan_repo runs the thread retry only when no other retry was dispatched for the PR" {
  _setup_sweep
  scan_pr_for_rate_limits() { echo "0"; }
  scan_pr_for_undispositioned_bot_comments() { echo "1"; }
  scan_pr_for_unreplied_bot_threads() { echo "THREAD-SCAN" >&2; echo "1"; }
  scan_repo_issues() { :; }
  gh() { echo '[{"number":1953,"head_sha":"abc"}]'; }
  run scan_repo "petry-projects/.github-private"
  [[ "$output" != *"THREAD-SCAN"* ]]

  scan_pr_for_undispositioned_bot_comments() { echo "0"; }
  run scan_repo "petry-projects/.github-private"
  [[ "$output" == *"THREAD-SCAN"* ]]
  [[ "$output" == *"dispatched 1 PR retries"* ]]
}

@test "sweep: DRY_RUN posts no marker and sends no dispatch" {
  export THREADS_RESPONSE
  THREADS_RESPONSE="$(_threads_page "$(_thread PRRT_cubic cubic-dev-ai)")"
  _setup_sweep
  export DRY_RUN="true"

  run scan_pr_for_unreplied_bot_threads "petry-projects/.github-private" 1953
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"would dispatch dev-lead-reviews-retry"*"intent=fix-reviews"* ]]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q -- '--method POST' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "review-one-pr: the gate hook runs the thread scan only after the bot-comment scan dispatched nothing" {
  REVIEW="$SCRIPT_DIR/scripts/review-one-pr.sh"
  guard_line=$(grep -n 'if \[ "\${DRY_RUN:-false}" != "true" \] && \[ -n "\$_OWNER_REPO" \]' "$REVIEW" | head -1 | cut -d: -f1)
  bcr_line=$(grep -n '_bcr_n=$(scan_pr_for_undispositioned_bot_comments "\$_OWNER_REPO"' "$REVIEW" | head -1 | cut -d: -f1)
  btr_line=$(grep -n 'scan_pr_for_unreplied_bot_threads "\$_OWNER_REPO" "\$_bcr_pr"' "$REVIEW" | head -1 | cut -d: -f1)
  verdict_line=$(grep -n 'emit_verdict skip undispositioned-pr-comment' "$REVIEW" | head -1 | cut -d: -f1)
  [ -n "$guard_line" ] && [ -n "$bcr_line" ] && [ -n "$btr_line" ] && [ -n "$verdict_line" ]
  [ "$guard_line" -lt "$bcr_line" ]
  [ "$bcr_line" -lt "$btr_line" ]
  [ "$btr_line" -lt "$verdict_line" ]
  sed -n "${bcr_line},${btr_line}p" "$REVIEW" | grep -q 'if \[ "\${_bcr_n:-0}" = "0" \]'
  run bash -c "source '$RETRY_SCRIPT' && declare -F scan_pr_for_unreplied_bot_threads"
  [ "$status" -eq 0 ]
}
