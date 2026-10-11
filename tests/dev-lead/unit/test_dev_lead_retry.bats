#!/usr/bin/env bats
# Unit tests for dev-lead-retry.sh — issue-retry scan/decision logic (#781)
#
# The script guards `main "$@"` behind a BASH_SOURCE check, so sourcing it here
# exposes scan_issue_for_retry / dispatch_issue_retry / open_issue_pr_exists
# without running the org-wide scan.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
RETRY_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-retry.sh"

setup() {
  MOCK_BIN="$(mktemp -d)"
  export PATH="$MOCK_BIN:$PATH"

  # Defaults; individual tests override COMMENTS_JSON / OPEN_PR_COUNT / NOW_ISO.
  export COMMENTS_JSON='[]'
  export OPEN_PR_COUNT="0"
  export DRY_RUN="true"
  export NOW_ISO="2026-06-19T00:00:00Z"

  # gh stub: emulates the *post-jq* output the script expects (the real gh
  # applies --jq server/client-side; the stub returns the finished value).
  #   …/issues/<n>/comments  -> $COMMENTS_JSON   (array of comment bodies)
  #   …/pulls?state=open      -> $OPEN_PR_COUNT   (integer)
  #   …/dispatches            -> capture payload to $PAYLOAD_FILE (POST path)
  export PAYLOAD_FILE="$MOCK_BIN/payload.json"
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *dispatches*) cat > "${PAYLOAD_FILE:-/dev/null}"; exit 0 ;;
  *comments*)   printf '%s' "${COMMENTS_JSON}" ;;
  *pulls*)      printf '%s' "${OPEN_PR_COUNT}" ;;
  *)            echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"

  source "$RETRY_SCRIPT"
}

teardown() {
  rm -rf "$MOCK_BIN"
}

_marker() {
  # _marker <status> <attempt> [reset]
  local status="$1" attempt="$2" reset="${3:-}"
  local r=""
  [ -n "$reset" ] && r=" reset=${reset}"
  printf '<!-- dev-lead-issue 478 status=%s attempt=%s reason=engine-error run=99%s -->' \
    "$status" "$attempt" "$r"
}

# ── scan_issue_for_retry decision matrix ──────────────────────────────────────

@test "retry: failed marker, attempt 1, no PR → dispatches" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker failed 1)" '[$m]')"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
  [[ "$output" == *"attempt=1"* ]]
}

@test "retry: rate-limited marker with reset in the future → skips" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker rate-limited 1 2026-06-19T06:00:00Z)" '[$m]')"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"not yet cleared"* ]]
  [[ "$output" != *"would dispatch"* ]]
}

@test "retry: rate-limited marker with reset in the past → dispatches" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker rate-limited 1 2026-06-18T00:00:00Z)" '[$m]')"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
}

@test "retry: attempt at the ceiling (attempt=3, MAX=3) → skips" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker failed 3)" '[$m]')"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"attempts exhausted"* ]]
  [[ "$output" != *"would dispatch"* ]]
}

@test "retry: newest marker wins (failed attempt=2 supersedes attempt=1)" {
  COMMENTS_JSON="$(jq -nc \
    --arg a "$(_marker failed 1)" \
    --arg b "$(_marker failed 2)" '[$a, $b]')"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
  [[ "$output" == *"attempt=2"* ]]
}

@test "retry: non-retryable marker (status=needs-human) → skips" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker needs-human 2)" '[$m]')"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"not retryable"* ]]
  [[ "$output" != *"would dispatch"* ]]
}

@test "retry: an open dev-lead PR already exists → skips" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker failed 1)" '[$m]')"
  OPEN_PR_COUNT="1"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"open dev-lead PR already exists"* ]]
  [[ "$output" != *"would dispatch"* ]]
}

@test "retry: no failure marker → no dispatch (returns 0)" {
  COMMENTS_JSON='["just a normal human comment"]'

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
}

# ── dispatch_issue_retry payload ──────────────────────────────────────────────

@test "dispatch: issue-retry payload carries event_type + issue_number + attempt" {
  export DRY_RUN="false"

  run dispatch_issue_retry "petry-projects/.github" 478 2

  [ "$status" -eq 0 ]
  [ -f "$PAYLOAD_FILE" ]
  [ "$(jq -r '.event_type' "$PAYLOAD_FILE")" = "dev-lead-issue-retry" ]
  [ "$(jq -r '.client_payload.issue_number' "$PAYLOAD_FILE")" = "478" ]
  [ "$(jq -r '.client_payload.attempt' "$PAYLOAD_FILE")" = "2" ]
}

@test "dispatch: DRY_RUN=true does not POST a dispatch" {
  export DRY_RUN="true"
  rm -f "$PAYLOAD_FILE"

  run dispatch_issue_retry "petry-projects/.github" 478 1

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] would dispatch"* ]]
  [ ! -f "$PAYLOAD_FILE" ]
}

# ── #2008: sweep trigger for bot comments edited after their disposition ──────
# CodeRabbit edits ONE summary comment in place (e.g. appending a Security
# Architecture finding). dev-lead only fires on CREATED comments, and the caller
# stub's `on:` is standards-owned, so the safety-net sweep re-dispatches a
# fix-reviews pass when a RESOLVED bot comment was edited after its latest
# dev-lead disposition. #2166: it is deduplicated on a disposition NEWER than the
# edit, not on a run marker — a pass that ran after the edit but wrote no fresh
# disposition left the gate blocked forever. Passes that started after the edit
# only bound it (STALE_DISPOSITION_MAX_PASSES), so it never loops unattended.

# _sweep_nodes <lastEditedAt> <disposition_createdAt> [run_marker_createdAt] [run_marker_association] [run_marker_read_at]
_sweep_nodes() {
  jq -cn --arg e "$1" --arg d "$2" --arg r "${3:-}" --arg ra "${4:-OWNER}" --arg rr "${5:-}" '
    [ {id:"IC_cr", author:{login:"coderabbitai", __typename:"Bot"}, authorAssociation:"NONE",
       body:"summary", createdAt:"2026-10-01T19:12:40Z", isMinimized:true, minimizedReason:"RESOLVED",
       lastEditedAt:$e},
      {id:"IC_d", author:{login:"don-petry", __typename:"User"}, authorAssociation:"OWNER",
       body:"notice\n<!-- dev-lead:comment-disposition id=IC_cr disposition=informational -->",
       createdAt:$d, isMinimized:false, minimizedReason:null, lastEditedAt:null} ]
    + (if $r == "" then [] else [
      {id:"IC_run", author:{login:"don-petry", __typename:"User"}, authorAssociation:$ra,
       body:("<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=no-changes" + (if $rr == "" then "" else " read_at=\($rr)" end) + " -->"),
       createdAt:$r, isMinimized:false, minimizedReason:null, lastEditedAt:null} ] end)'
}

@test "sweep(#2008): a bot comment edited after its dev-lead disposition needs a fix-reviews dispatch" {
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z)" 2000
  [ "$status" -eq 0 ]
}

@test "sweep(#2008): an edit BEFORE the disposition needs no dispatch" {
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T19:20:00Z 2026-10-01T19:23:54Z)" 2000
  [ "$status" -eq 1 ]
}

@test "sweep(#2166): a fix-reviews marker after the edit is not proof — only a disposition newer than the edit clears" {
  # One pass ran after the edit but wrote no fresh disposition: still stale, so
  # dispatch again (PRs empower-personal-dashboard#65/#66/#67 held forever here).
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z)" 2000
  [ "$status" -eq 0 ]
  # A run marker that PREDATES the edit does not suppress it either.
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T19:24:23Z)" 2000
  [ "$status" -eq 0 ]
  # A disposition newer than the edit is the dedup key: nothing to dispatch.
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T20:36:00Z 2026-10-01T20:36:15Z)" 2000
  [ "$status" -eq 1 ]
}

@test "sweep(#2166): bounded — after STALE_DISPOSITION_MAX_PASSES passes since the edit it holds (rc 3) instead of looping" {
  local nodes
  nodes=$(jq -c '. + [ .[] | select(.id == "IC_run") | .id = "IC_run2" | .createdAt = "2026-10-01T20:50:00Z" ]' \
    <<< "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z)")
  run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 3 ]
  STALE_DISPOSITION_MAX_PASSES=3 run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 0 ]
  # A non-numeric cap falls back to the default (2).
  STALE_DISPOSITION_MAX_PASSES=x run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 3 ]
}

@test "sweep(#2166): the stale-disposition hold comment names the real gate and no dead-end advice" {
  local body
  body=$(sed -n '/stale bot comment disposition needs human action/,/\$hold_marker/p' "$RETRY_SCRIPT")
  [[ "$body" == *'undispositioned-pr-comment'* ]]
  [[ "$body" != *'required_review_thread_resolution'* ]]
  [[ "$body" != *'@mention dev-lead'* ]]
}

@test "sweep(#2008): a run marker for a DIFFERENT PR does not suppress the dispatch" {
  export STALE_DISPOSITION_MAX_PASSES=1  # one counted pass reaches the cap
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z)" 20
  [ "$status" -eq 0 ]
}

@test "sweep(#2008): a run marker from an untrusted author does not suppress the dispatch" {
  export STALE_DISPOSITION_MAX_PASSES=1  # one counted pass reaches the cap
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z NONE)" 2000
  [ "$status" -eq 0 ]
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z CONTRIBUTOR)" 2000
  [ "$status" -eq 0 ]
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z MEMBER)" 2000
  [ "$status" -eq 3 ]
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z COLLABORATOR)" 2000
  [ "$status" -eq 3 ]
}

@test "sweep(#2008): a pass that STARTED before the edit does not suppress the dispatch, even if it finished after" {
  export STALE_DISPOSITION_MAX_PASSES=1  # one counted pass reaches the cap
  # Marker posted after the edit (20:36:15) by a pass that read the comments at 20:30.
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z OWNER 2026-10-01T20:30:00Z)" 2000
  [ "$status" -eq 0 ]
  # A pass that started after the edit counts toward the cap.
  run stale_disposition_needs_dispatch "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z OWNER 2026-10-01T20:35:30Z)" 2000
  [ "$status" -eq 3 ]
}

# ── #2247: a pass that dies before any terminal marker still counts ────────────
# A fix-reviews pass that sees a stale disposition posts a start marker before the
# model runs. A pass whose runner is lost after that posts nothing else, so the cap
# has to count start markers too. A pass that posts both counts once (same read_at).

# _start_node <id> <createdAt> <read_at> [pr] [association]: a start-marker node.
_start_node() {
  jq -cn --arg id "$1" --arg c "$2" --arg r "$3" --arg pr "${4:-2000}" --arg a "${5:-OWNER}" '
    {id:$id, author:{login:"don-petry", __typename:"User"}, authorAssociation:$a,
     body:"<!-- dev-lead-fix-reviews-start pr=\($pr) sha=abc intent=fix-reviews edit=2026-10-01T20:35:00Z read_at=\($r) -->",
     createdAt:$c, isMinimized:false, minimizedReason:null, lastEditedAt:null}'
}

# _with_nodes <nodes-json> <node-json>...: append nodes to a node array.
_with_nodes() {
  local nodes="$1" n
  shift
  for n in "$@"; do nodes=$(jq -c --argjson n "$n" '. + [$n]' <<< "$nodes"); done
  printf '%s' "$nodes"
}

@test "sweep(#2247): two passes that only posted a start marker reach the cap (rc 3)" {
  local base nodes
  base=$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z)
  nodes=$(_with_nodes "$base" "$(_start_node IC_s1 2026-10-01T20:40:01Z 2026-10-01T20:40:00Z)")
  run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 0 ]
  nodes=$(_with_nodes "$nodes" "$(_start_node IC_s2 2026-10-01T20:55:01Z 2026-10-01T20:55:00Z)")
  run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 3 ]
}

@test "sweep(#2247): a pass that posts a start and a terminal marker counts once" {
  local nodes
  # The terminal marker (IC_run) carries the same read_at as the start marker.
  nodes=$(_with_nodes "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:45:00Z OWNER 2026-10-01T20:40:00Z)" \
    "$(_start_node IC_s1 2026-10-01T20:40:01Z 2026-10-01T20:40:00Z)")
  run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 0 ]
  STALE_DISPOSITION_MAX_PASSES=1 run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 3 ]
}

@test "sweep(#2247): millisecond-precision read_at is parsed, deduped across start+terminal, and compared to the edit" {
  local nodes
  # Start (createdAt ...01Z) and terminal (...45Z) markers share read_at=...:00.123Z: one pass.
  nodes=$(_with_nodes "$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:45:00Z OWNER 2026-10-01T20:40:00.123Z)" \
    "$(_start_node IC_s1 2026-10-01T20:40:01Z 2026-10-01T20:40:00.123Z)")
  run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 0 ]
  STALE_DISPOSITION_MAX_PASSES=1 run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 3 ]
  # A pass that read at 20:30:00.500Z (before the edit) posted after it: not counted.
  nodes=$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z OWNER 2026-10-01T20:30:00.500Z)
  STALE_DISPOSITION_MAX_PASSES=1 run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 0 ]
  # read_at 20:35:00.000Z equals the edit second: counted (fraction must not sort it below).
  nodes=$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z 2026-10-01T20:36:15Z OWNER 2026-10-01T20:35:00.000Z)
  STALE_DISPOSITION_MAX_PASSES=1 run stale_disposition_needs_dispatch "$nodes" 2000
  [ "$status" -eq 3 ]
}

@test "sweep(#2247): a start marker before the edit, for another PR, or from an untrusted author does not count" {
  export STALE_DISPOSITION_MAX_PASSES=1  # one counted pass reaches the cap
  local base
  base=$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z)
  run stale_disposition_needs_dispatch "$(_with_nodes "$base" "$(_start_node IC_s 2026-10-01T20:36:00Z 2026-10-01T20:30:00Z)")" 2000
  [ "$status" -eq 0 ]
  run stale_disposition_needs_dispatch "$(_with_nodes "$base" "$(_start_node IC_s 2026-10-01T20:41:00Z 2026-10-01T20:40:00Z 20)")" 2000
  [ "$status" -eq 0 ]
  run stale_disposition_needs_dispatch "$(_with_nodes "$base" "$(_start_node IC_s 2026-10-01T20:41:00Z 2026-10-01T20:40:00Z 2000 NONE)")" 2000
  [ "$status" -eq 0 ]
  run stale_disposition_needs_dispatch "$(_with_nodes "$base" "$(_start_node IC_s 2026-10-01T20:41:00Z 2026-10-01T20:40:00Z)")" 2000
  [ "$status" -eq 3 ]
}

@test "sweep(#2247): two passes start and post no terminal marker — the third sweep holds and posts the capped hold" {
  export DRY_RUN="false" POSTS_FILE="$BATS_TEST_TMPDIR/posts"
  : > "$POSTS_FILE"
  gh() {
    case "$*" in
      *"--method POST"*) printf '%s\n' "$*" >> "$POSTS_FILE" ;;
      *"/pulls/2000"*) echo '{"state":"open","head":{"sha":"abc"},"labels":[]}' ;;
      *"/comments"*) jq -c 'map(.body)' <<< "$SWEEP_NODES" ;;
      *) echo '[]' ;;
    esac
  }
  pr_resume_suppressed() { return 1; }
  post_dispatch_guard() { :; }
  fetch_pr_comment_nodes() { printf '%s' "$SWEEP_NODES"; }
  dispatch_reviews_retry() { echo "DISPATCH intent=$4" >&2; }

  # Sweeps 1 and 2 dispatch; each dispatched pass posts its start marker, then dies.
  export SWEEP_NODES
  SWEEP_NODES=$(_sweep_nodes 2026-10-01T20:35:00Z 2026-10-01T19:23:54Z)
  run scan_pr_for_rate_limits "petry-projects/.github-private" 2000
  [[ "$output" == *"DISPATCH intent=fix-reviews"* ]]
  SWEEP_NODES=$(_with_nodes "$SWEEP_NODES" "$(_start_node IC_s1 2026-10-01T20:40:01Z 2026-10-01T20:40:00Z)")
  run scan_pr_for_rate_limits "petry-projects/.github-private" 2000
  [[ "$output" == *"DISPATCH intent=fix-reviews"* ]]
  [ ! -s "$POSTS_FILE" ]
  SWEEP_NODES=$(_with_nodes "$SWEEP_NODES" "$(_start_node IC_s2 2026-10-01T20:55:01Z 2026-10-01T20:55:00Z)")

  # Sweep 3: no dispatch, and the capped hold comment is posted.
  run scan_pr_for_rate_limits "petry-projects/.github-private" 2000
  [ "${lines[-1]}" = "0" ]
  [[ "$output" != *"DISPATCH"* ]]
  [[ "$output" == *"::warning::"*"#2166"* ]]
  grep -q 'dev-lead-stale-disposition-hold pr=2000 sha=abc max_passes=2' "$POSTS_FILE"
}

@test "sweep(#2008): unreadable comment data never dispatches (no guessing)" {
  run stale_disposition_needs_dispatch "not json" 2000
  [ "$status" -eq 1 ]
}

@test "sweep(#2008): scan_pr_for_rate_limits consults the stale-disposition check" {
  grep -q 'stale_disposition_needs_dispatch' "$RETRY_SCRIPT"
  grep -q 'lastEditedAt' "$RETRY_SCRIPT"
}

# _scan_with_hold <reset_iso>: run scan_pr_for_rate_limits on a PR whose only
# marker is a fix-reviews hold resetting at <reset_iso>, with a stale-edited bot
# comment waiting (the #2008 re-dispatch would fire if nothing else stopped it).
_scan_with_hold() {
  local reset="$1"
  export HOLD_RESET="$reset"
  gh() {
    case "$*" in
      *"/pulls/2000"*) echo '{"state":"open","head":{"sha":"abc"},"labels":[]}' ;;
      *"/comments"*) jq -cn --arg r "$HOLD_RESET" '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=rate-limited reason=rate-limited reset=\($r) -->"]' ;;
      *) echo '[]' ;;
    esac
  }
  pr_resume_suppressed() { return 1; }
  post_dispatch_guard() { :; }
  fetch_pr_comment_nodes() { echo '[{"id":"IC_cr"}]'; }
  stale_disposition_needs_dispatch() { return 0; }
  dispatch_reviews_retry() { echo "DISPATCH intent=$4" >&2; }
  run scan_pr_for_rate_limits "petry-projects/.github-private" 2000
}

@test "sweep(#2008): an active rate-limit hold also holds the edit re-dispatch" {
  _scan_with_hold "2026-06-19T05:00:00Z"
  [ "${lines[-1]}" = "0" ]
  [[ "$output" != *"DISPATCH"* ]]
  [[ "$output" != *"stale-disposition"* ]]
}

@test "sweep(#2008): once the hold has reset, the retry dispatch covers the edit (one run)" {
  _scan_with_hold "2026-06-18T23:00:00Z"
  [ "${lines[-1]}" = "1" ]
  [ "$(grep -c 'DISPATCH' <<< "$output")" -eq 1 ]
}

@test "sweep(#2166): a stale disposition past its pass cap is held with a warning, not dispatched" {
  gh() {
    case "$*" in
      *"/pulls/2000"*) echo '{"state":"open","head":{"sha":"abc"},"labels":[]}' ;;
      *) echo '[]' ;;
    esac
  }
  pr_resume_suppressed() { return 1; }
  post_dispatch_guard() { echo "GUARD" >&2; }
  fetch_pr_comment_nodes() { echo '[{"id":"IC_cr"}]'; }
  stale_disposition_needs_dispatch() { return 3; }
  dispatch_reviews_retry() { echo "DISPATCH intent=$4" >&2; }
  run scan_pr_for_rate_limits "petry-projects/.github-private" 2000
  [ "${lines[-1]}" = "0" ]
  [[ "$output" != *"DISPATCH"* ]]
  [[ "$output" != *"GUARD"* ]]
  [[ "$output" == *"::warning::"*"#2166"* ]]
}

# _scan_with_markers <json-array-of-bodies>: scan a PR whose comments are exactly those.
_scan_with_markers() {
  export MARKERS_JSON="$1"
  gh() {
    case "$*" in
      *"/pulls/2000"*) echo '{"state":"open","head":{"sha":"abc"},"labels":[]}' ;;
      *"/comments"*) echo "$MARKERS_JSON" ;;
      *) echo '[]' ;;
    esac
  }
  pr_resume_suppressed() { return 1; }
  post_dispatch_guard() { :; }
  fetch_pr_comment_nodes() { echo '[]'; }
  stale_disposition_needs_dispatch() { return 1; }
  dispatch_reviews_retry() { echo "DISPATCH intent=$4" >&2; }
  run scan_pr_for_rate_limits "petry-projects/.github-private" 2000
}

@test "retry(#2089): a dev-lead:hands-off PR with a reset hold neither guards nor dispatches" {
  gh() {
    case "$*" in
      *"/pulls/2000"*) echo '{"state":"open","head":{"sha":"abc"},"labels":[{"name":"dev-lead:hands-off"}]}' ;;
      *"/comments"*) echo '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=rate-limited reason=rate-limited reset=2026-06-18T23:00:00Z -->"]' ;;
      *) echo '[]' ;;
    esac
  }
  # The REAL resume gate (from lib/pr-automation-budget.sh) — not the stub the
  # other scans use — so the hold-label suppression itself is under test.
  # shellcheck source=/dev/null
  source "$(dirname "$RETRY_SCRIPT")/lib/pr-automation-budget.sh"
  post_dispatch_guard() { echo "GUARD" >&2; }
  fetch_pr_comment_nodes() { echo '[{"id":"IC_cr"}]'; }
  stale_disposition_needs_dispatch() { return 0; }
  dispatch_reviews_retry() { echo "DISPATCH intent=$4" >&2; }
  run scan_pr_for_rate_limits "petry-projects/.github-private" 2000
  [ "${lines[-1]}" = "0" ]
  [[ "$output" != *"DISPATCH"* ]]
  [[ "$output" != *"GUARD"* ]]
  [[ "$output" == *"carries dev-lead:hands-off"* ]]
}

@test "retry: history-unavailable marker AFTER an older terminal failed marker still dispatches" {
  _scan_with_markers '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=failed -->","<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=history-unavailable -->"]'
  [[ "$output" == *"DISPATCH intent=fix-reviews"* ]]
}

@test "retry: history-unavailable marker BEFORE a later terminal marker does not dispatch" {
  _scan_with_markers '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=history-unavailable -->","<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=applied -->"]'
  [[ "$output" != *"DISPATCH"* ]]
}

@test "retry: repeated history-unavailable markers hit the retry limit and stop dispatching" {
  local m='<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=history-unavailable -->'
  _scan_with_markers "[\"$m\",\"$m\",\"$m\"]"
  [[ "$output" != *"DISPATCH"* ]]
}

@test "retry: history-unavailable below the retry limit still dispatches" {
  local m='<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=history-unavailable -->'
  _scan_with_markers "[\"$m\",\"$m\"]"
  [[ "$output" == *"DISPATCH intent=fix-reviews"* ]]
}

@test "retry: partial marker AFTER an older terminal no-changes marker still dispatches" {
  _scan_with_markers '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=no-changes -->","<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=partial -->"]'
  [[ "$output" == *"DISPATCH intent=fix-reviews"* ]]
}

@test "retry: repeated partial markers hit the retry limit and stop dispatching" {
  local m='<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=partial -->'
  _scan_with_markers "[\"$m\",\"$m\",\"$m\"]"
  [[ "$output" != *"DISPATCH"* ]]
}

@test "retry: partial retry limit holds the PR, escalates, and blocks the stale-disposition dispatch" {
  local m='<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=partial -->'
  export MARKERS_JSON="[\"$m\",\"$m\",\"$m\"]"
  gh() {
    case "$*" in
      *"/pulls/2000"*) echo '{"state":"open","head":{"sha":"abc"},"labels":[]}' ;;
      *"/comments"*) echo "$MARKERS_JSON" ;;
      *) echo '[]' ;;
    esac
  }
  pr_resume_suppressed() { return 1; }
  post_dispatch_guard() { :; }
  pr_automation_escalate() { echo "ESCALATE $1" >&2; }
  # The stale-disposition path would dispatch if the hold did not apply.
  fetch_pr_comment_nodes() { echo '[{"id":"x"}]'; }
  stale_disposition_needs_dispatch() { return 0; }
  dispatch_reviews_retry() { echo "DISPATCH intent=$4" >&2; }
  run scan_pr_for_rate_limits "petry-projects/.github-private" 2000
  [[ "$output" != *"DISPATCH"* ]]
  [[ "$output" == *"ESCALATE 2000"* ]]
}

@test "retry: partial markers before a later applied marker do not hold or escalate" {
  local p='<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=partial -->'
  local a='<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=applied -->'
  pr_automation_escalate() { echo "ESCALATE $1" >&2; }
  _scan_with_markers "[\"$p\",\"$p\",\"$p\",\"$a\"]"
  [[ "$output" != *"DISPATCH"* ]]
  [[ "$output" != *"ESCALATE"* ]]
}

@test "retry: partial markers before a later no-changes marker do not hold or escalate" {
  local p='<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=partial -->'
  local nc='<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=no-changes -->'
  pr_automation_escalate() { echo "ESCALATE $1" >&2; }
  _scan_with_markers "[\"$p\",\"$p\",\"$p\",\"$nc\"]"
  [[ "$output" != *"DISPATCH"* ]]
  [[ "$output" != *"ESCALATE"* ]]
}

@test "retry: unrelated-histories after history-unavailable is terminal" {
  _scan_with_markers '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=history-unavailable -->","<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=unrelated-histories -->"]'
  [[ "$output" != *"DISPATCH"* ]]
}
