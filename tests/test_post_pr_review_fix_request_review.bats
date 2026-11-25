#!/usr/bin/env bats
# Issue #2614: a delegated fix request is posted as a COMMENT review, not a PR
# conversation comment. Line-cited findings are its inline comments; findings
# without a line go in the review body, which carries the fix-requested marker
# pair. Older agent reviews are marked obsolete (a COMMENTED review cannot be
# dismissed, so its body is wrapped in the superseded sentinel), and finding
# threads from an older review are resolved so they never block merge.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export POST_SCRIPT="$REPO_ROOT/scripts/post-pr-review.sh"

  export SHA="d53a7fc6b0718dd3d672fed4eec8394e5d372900"
  export OLD_SHA="53478e6d53478e6d53478e6d53478e6d53478e6d"
  export PR_URL="https://github.com/combsmith/.github-private/pull/2614"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  export PAYLOADS="$TEST_DIR/review_payloads.jsonl";  : > "$PAYLOADS"
  export COMMENT_OUT="$TEST_DIR/posted_comment.txt";  : > "$COMMENT_OUT"
  export EVENTS="$TEST_DIR/events.txt";               : > "$EVENTS"
  export REVIEWS_FILE="$TEST_DIR/reviews.json";       echo '[]' > "$REVIEWS_FILE"
  export THREADS_FILE="$TEST_DIR/threads.json";       echo '[]' > "$THREADS_FILE"

  cat > "$TEST_DIR/bin/gh" <<'GHEOF'
#!/bin/bash
sub1="${1:-}"; sub2="${2:-}"
if [ "$sub1" = "api" ] && [ "$sub2" = "graphql" ]; then
  args="$*"
  case "$args" in
    *resolveReviewThread*)
      tid=""; for a in "$@"; do case "$a" in id=*) tid="${a#id=}" ;; esac; done
      echo "RESOLVE $tid" >> "$EVENTS"
      printf '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
      exit 0 ;;
    *reviewThreads*)
      jq -nc --slurpfile t "$THREADS_FILE" \
        '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$t[0]}}}}}'
      exit 0 ;;
  esac
  exit 0
fi
if [ "$sub1" = "api" ]; then
  method="GET"; path=""; jqf=""; prev=""
  for a in "$@"; do
    case "$prev" in -X) method="$a" ;; --jq) jqf="$a" ;; esac
    case "$a" in repos/*) path="$a" ;; esac
    prev="$a"
  done
  case "$method:$path" in
    POST:*/pulls/*/reviews)
      input="$(cat)"
      printf '%s' "$input" | jq -c . >> "$PAYLOADS"
      if [ -n "${REVIEW_FAILS:-}" ]; then echo '{"message":"Server Error"}'; exit 1; fi
      if [ -n "${INLINE_422:-}" ] && [ "$(printf '%s' "$input" | jq '(.comments // []) | length')" -gt 0 ]; then
        echo '{"message":"Unprocessable Entity","errors":["Line could not be resolved"],"status":"422"}'
        exit 1
      fi
      state=$(printf '%s' "$input" | jq -r 'if .event == "APPROVE" then "APPROVED" else "COMMENTED" end')
      jq --arg body "$(printf '%s' "$input" | jq -r '.body')" --arg sha "$SHA" --arg bot "${BOT_USER:-donpetry-bot}" --arg st "$state" \
        'map(select(.id != 900)) + [{id: 900, state: $st, user: {login: $bot}, commit_id: $sha, submitted_at: "2026-11-25T12:00:00Z", body: $body}]' \
        "$REVIEWS_FILE" > "$REVIEWS_FILE.tmp" && mv "$REVIEWS_FILE.tmp" "$REVIEWS_FILE"
      printf '{"id":900,"state":"%s","commit_id":"%s"}' "$state" "$SHA"
      exit 0 ;;
    GET:*/pulls/*/reviews)
      cat "$REVIEWS_FILE"; exit 0 ;;
    GET:*/pulls/*/reviews/*)
      id="${path##*/}"
      r=$(jq -c --argjson id "$id" '.[] | select(.id == $id)' "$REVIEWS_FILE")
      if [ -n "$jqf" ]; then printf '%s' "$r" | jq -r "$jqf"; else printf '%s' "$r"; fi
      exit 0 ;;
    PUT:*/pulls/*/reviews/*/dismissals)
      echo "DISMISS ${path%/dismissals}" | sed 's|.*/reviews/|DISMISS |' >> "$EVENTS"
      exit 0 ;;
    PUT:*/pulls/*/reviews/*)
      id="${path##*/}"
      body="$(cat | jq -r '.body')"
      echo "EDIT_REVIEW $id" >> "$EVENTS"
      printf '%s' "$body" > "$TEST_DIR/edited_review_$id.txt"
      exit 0 ;;
    GET:*/issues/*/comments) echo '[]'; exit 0 ;;
    GET:*/issues/*/events*) echo '[]'; exit 0 ;;
    GET:*/pulls/[0-9]*) printf '%s\n' "$SHA"; exit 0 ;;
  esac
  exit 0
fi
if [ "$sub1" = "pr" ] && [ "$sub2" = "comment" ]; then
  prev=""; for a in "$@"; do [ "$prev" = "--body" ] && printf '%s' "$a" > "$COMMENT_OUT"; prev="$a"; done
  exit 0
fi
if [ "$sub1" = "pr" ] && [ "$sub2" = "view" ]; then
  jqf=""; prev=""
  for a in "$@"; do [ "$prev" = "--jq" ] && jqf="$a"; prev="$a"; done
  data='{"labels":[],"mergeStateStatus":"CLEAN","reviews":[],"reviewDecision":"REVIEW_REQUIRED"}'
  if [ -n "$jqf" ]; then printf '%s' "$data" | jq -r "$jqf"; else printf '%s' "$data"; fi
  exit 0
fi
exit 0
GHEOF
  chmod +x "$TEST_DIR/bin/gh"
  export PATH="$TEST_DIR/bin:$PATH"

  export PR_HEAD_SHA="$SHA"
  export DRY_RUN="false"
  export AI_DELEGATION_ENABLED="true"
  export REVIEW_CYCLE="1"
  export MAX_REVIEW_CYCLES="3"
  export BOT_USER="donpetry-bot"
  export LABEL_RETRY_DELAY="0"
}

teardown() { rm -rf "$TEST_DIR"; }

write_verdict() { # [findings-json]
  local f="$TEST_DIR/verdict.json"
  if [ $# -gt 0 ]; then
    jq -n --argjson fi "$1" '{decision:"escalate", risk:"LOW", summary:"Two problems.", body:"- legacy body finding", findings:$fi, escalate_to_ai:true}' > "$f"
  else
    jq -n '{decision:"escalate", risk:"LOW", summary:"s", body:"- legacy body finding", escalate_to_ai:true}' > "$f"
  fi
  echo "$f"
}

MIXED='[
  {"severity":"major","category":"bug","message":"CITED_FINDING off by one","file":"scripts/a.sh","line":12},
  {"severity":"minor","category":"docs","message":"LINELESS_FINDING missing changelog","file":null,"line":null}
]'

@test "#2614: a fix request posts one COMMENT review, never a conversation comment" {
  run bash "$POST_SCRIPT" "$PR_URL" "$(write_verdict "$MIXED")" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$PAYLOADS")" -eq 1 ]
  [ "$(jq -r '.event' "$PAYLOADS")" = "COMMENT" ]
  [ "$(jq -r '.commit_id' "$PAYLOADS")" = "$SHA" ]
  [ ! -s "$COMMENT_OUT" ]
}

@test "#2614: line-cited findings are inline comments; line-less ones are in the body" {
  run bash "$POST_SCRIPT" "$PR_URL" "$(write_verdict "$MIXED")" "false"
  [ "$status" -eq 0 ]
  [ "$(jq '.comments | length' "$PAYLOADS")" -eq 1 ]
  [ "$(jq -r '.comments[0].path' "$PAYLOADS")" = "scripts/a.sh" ]
  [ "$(jq -r '.comments[0].line' "$PAYLOADS")" = "12" ]
  [[ "$(jq -r '.comments[0].body' "$PAYLOADS")" == "<!-- pr-review-agent finding sha=$SHA -->"* ]]
  [[ "$(jq -r '.comments[0].body' "$PAYLOADS")" == *CITED_FINDING* ]]
  body=$(jq -r '.body' "$PAYLOADS")
  [[ "$body" == "<!-- pr-review-agent v1 sha=$SHA --> <!-- decision=fix-requested risk=LOW -->"* ]]
  [[ "$body" == *LINELESS_FINDING* ]]
  [[ "$body" != *CITED_FINDING* ]]
  [[ "$body" == *"cycle 2/3"* ]]
  [[ "$body" == *"inline comment"* ]]
}

@test "#2614: the review body carries exactly one v1 marker (the cycle counts it once)" {
  run bash "$POST_SCRIPT" "$PR_URL" "$(write_verdict "$MIXED")" "false"
  [ "$(jq -r '.body' "$PAYLOADS" | grep -o 'pr-review-agent v1 sha=' | wc -l)" -eq 1 ]
  # Inline comments use a distinct marker that no cycle/idempotency reader matches.
  run bash -c "jq -r '.comments[].body' '$PAYLOADS' | grep -c 'pr-review-agent v1 sha='"
  [ "$output" = "0" ]
}

@test "#2614: a verdict without structured findings keeps the legacy body and posts no inline comments" {
  run bash "$POST_SCRIPT" "$PR_URL" "$(write_verdict)" "false"
  [ "$status" -eq 0 ]
  [ "$(jq 'has("comments")' "$PAYLOADS")" = "false" ]
  [[ "$(jq -r '.body' "$PAYLOADS")" == *"legacy body finding"* ]]
}

@test "#2614: when GitHub rejects the inline comments, the review is posted again with them in the body" {
  export INLINE_422=1
  run bash "$POST_SCRIPT" "$PR_URL" "$(write_verdict "$MIXED")" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$PAYLOADS")" -eq 2 ]
  second=$(sed -n 2p "$PAYLOADS")
  [ "$(jq 'has("comments")' <<< "$second")" = "false" ]
  [[ "$(jq -r '.body' <<< "$second")" == *'`scripts/a.sh:12`'*CITED_FINDING* ]]
  [[ "$(jq -r '.body' <<< "$second")" == *LINELESS_FINDING* ]]
  [[ "$output" == *"::warning::"* ]]
}

@test "#2614: a failed review post exits 1 and posts no conversation comment" {
  export REVIEW_FAILS=1
  run bash "$POST_SCRIPT" "$PR_URL" "$(write_verdict "$MIXED")" "false"
  [ "$status" -eq 1 ]
  [ ! -s "$COMMENT_OUT" ]
  [[ "$output" == *"::error::fix-request"* ]]
  # A non-422 failure is not retried: the first review may have landed, and a
  # second post would count the cycle twice.
  [ "$(wc -l < "$PAYLOADS")" -eq 1 ]
}

@test "#2614: a prior COMMENTED agent review is superseded by a body edit, not a dismissal" {
  jq -n --arg old "$OLD_SHA" '[{id: 41, state: "COMMENTED", user: {login: "donpetry-bot"}, commit_id: $old,
     submitted_at: "2026-11-24T08:00:00Z",
     body: ("<!-- pr-review-agent v1 sha=" + $old + " --> <!-- decision=fix-requested risk=LOW -->\n\nold findings")}]' > "$REVIEWS_FILE"
  run bash "$POST_SCRIPT" "$PR_URL" "$(write_verdict "$MIXED")" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  grep -q '^EDIT_REVIEW 41$' "$EVENTS"
  ! grep -q '^DISMISS 41$' "$EVENTS" || false
  ! grep -q '^EDIT_REVIEW 900$' "$EVENTS" || false
  head -1 "$TEST_DIR/edited_review_41.txt" | grep -qF '<!-- pr-review-agent superseded -->'
  # The marker survives inside the collapsed block, so the cycle cap still counts it.
  grep -qF "<!-- pr-review-agent v1 sha=$OLD_SHA -->" "$TEST_DIR/edited_review_41.txt"
}

@test "#2614: an already-superseded COMMENTED review is not wrapped again" {
  jq -n --arg old "$OLD_SHA" '[{id: 41, state: "COMMENTED", user: {login: "donpetry-bot"}, commit_id: $old,
     submitted_at: "2026-11-24T08:00:00Z",
     body: ("<!-- pr-review-agent superseded -->\n<details><summary>x</summary>\n\n<!-- pr-review-agent v1 sha=" + $old + " --> <!-- decision=fix-requested risk=LOW -->\n\n</details>")}]' > "$REVIEWS_FILE"
  run bash "$POST_SCRIPT" "$PR_URL" "$(write_verdict "$MIXED")" "false"
  [ "$status" -eq 0 ]
  ! grep -q '^EDIT_REVIEW 41$' "$EVENTS" || false
}

@test "#2614: a prior APPROVED agent review is still dismissed" {
  jq -n --arg old "$OLD_SHA" '[{id: 42, state: "APPROVED", user: {login: "donpetry-bot"}, commit_id: $old,
     submitted_at: "2026-11-24T08:00:00Z",
     body: ("<!-- pr-review-agent v1 sha=" + $old + " decision=approved risk=LOW -->")}]' > "$REVIEWS_FILE"
  run bash "$POST_SCRIPT" "$PR_URL" "$(write_verdict "$MIXED")" "false"
  [ "$status" -eq 0 ]
  grep -q '^DISMISS 42$' "$EVENTS"
}

_thread() { # <id> <login> <body> <review-db-id> [isResolved]
  jq -nc --arg id "$1" --arg l "$2" --arg b "$3" --argjson r "$4" --argjson res "${5:-false}" \
    '{id:$id, isResolved:$res, comments:{nodes:[{author:{login:$l}, body:$b, pullRequestReview:{databaseId:$r}}]}}'
}

@test "#2614: finding threads from an older pr-review review are resolved; the new review's threads and others stay" {
  {
    echo '['
    _thread T_old donpetry-bot "<!-- pr-review-agent finding sha=$OLD_SHA -->
old" 41; echo ','
    _thread T_new donpetry-bot "<!-- pr-review-agent finding sha=$SHA -->
new" 900; echo ','
    _thread T_human a-maintainer "<!-- pr-review-agent finding sha=$OLD_SHA -->
forged" 43; echo ','
    _thread T_plain donpetry-bot "a plain comment" 44; echo ','
    _thread T_done donpetry-bot "<!-- pr-review-agent finding sha=$OLD_SHA -->
done" 45 true
    echo ']'
  } > "$THREADS_FILE"
  run bash "$POST_SCRIPT" "$PR_URL" "$(write_verdict "$MIXED")" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  grep -q '^RESOLVE T_old$' "$EVENTS"
  ! grep -q '^RESOLVE T_new$' "$EVENTS" || false
  ! grep -q '^RESOLVE T_human$' "$EVENTS" || false
  ! grep -q '^RESOLVE T_plain$' "$EVENTS" || false
  ! grep -q '^RESOLVE T_done$' "$EVENTS" || false
}

@test "#2614: an approval resolves every open pr-review finding thread" {
  {
    echo '['
    _thread T_a donpetry-bot "<!-- pr-review-agent finding sha=$SHA -->
a" 900; echo ','
    _thread T_b donpetry-bot "<!-- pr-review-agent finding sha=$OLD_SHA -->
b" 41
    echo ']'
  } > "$THREADS_FILE"
  local f="$TEST_DIR/verdict.json"
  jq -n --arg b "<!-- pr-review-agent v1 sha=${SHA} decision=approved risk=LOW -->

## Automated review — APPROVED" '{decision:"approve", risk:"LOW", summary:"ok", body:$b}' > "$f"
  run bash "$POST_SCRIPT" "$PR_URL" "$f" "false"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  grep -q '^RESOLVE T_a$' "$EVENTS"
  grep -q '^RESOLVE T_b$' "$EVENTS"
}
