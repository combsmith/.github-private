#!/usr/bin/env bats
# Unit tests for the QA Lead advisory pull (#2487, ADR-0016).
#
# A QA Lead advisory on a dev-lead-authored PR used to be read by nothing: the
# review-changes pass could run before the advisory landed, and no later pass
# looked for it (combsmith/empower-personal-dashboard#180). dev-lead's retry cron
# now PULLS: a pure classifier flags an advisory that has items and no dev-lead
# disposition, and the sweep sends the existing review-changes retry. These tests
# pin:
#   • the pure decision (lib/qa-advisory-retry.sh, qa_advisory_decisions) — above
#     all the loop bound: a dispositioned advisory never dispatches again;
#   • the sweep wiring in dev-lead-retry.sh (one review-changes dispatch per PR,
#     a retry marker first, escalation labels and dispositions instead);
#   • that the disposition and retry markers stay out of the maintainer gate and
#     carry nothing the persona router's recursion guard keys on.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/qa-advisory-retry.sh"
RETRY_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-retry.sh"

AUTOMATION='don-petry,donpetry-bot'
# 2026-10-02T01:00:00Z
NOW_EPOCH=1790902800

bats_require_minimum_version 1.5.0

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
  export QA_ADVISORY_RETRY_PENDING_SEC=9000
  export QA_ADVISORY_RETRY_MAX_ATTEMPTS=2
  export QA_ADVISORY_RETRY_LANE_SEC=900
}

# _advisory_body [escalate] [bullets...] — a QA Lead advisory in the shape
# prompts/qa-lead/advisory.md prescribes.
_advisory_body() {
  local esc="${1:-no}"
  shift || true
  local b
  b=$'<!-- persona:qa-lead -->\n## QA Lead — test-risk advisory\n\n**Risk tier:** MEDIUM — the ledger upgrade path is untested.\n\n**What I\'d shore up** (highest leverage first, up to 4 bullets):\n'
  local item
  for item in "$@"; do b+="- ${item}"$'\n'; done
  b+=$'\n**Escalate?** '"${esc}"$'\n\nAdvisory only — I comment, I do not change code.'
  printf '%s' "$b"
}

# _c <id> <body> [createdAt] [association] [login] — a PR issue comment node.
_c() {
  jq -nc --arg id "$1" --arg b "$2" --arg c "${3:-2026-10-01T20:00:00Z}" \
    --arg a "${4:-OWNER}" --arg l "${5:-don-petry}" '
    {id:$id, author:{login:$l, __typename:"User"}, authorAssociation:$a, body:$b,
     createdAt:$c, lastEditedAt:null, isMinimized:false, minimizedReason:null}'
}

_list() { jq -sc '.' <<< "$*"; }

_adv() { _c IC_adv "$(_advisory_body no 'Add a legacy-ledger upgrade test.' 'Cover the top-up branch.')" "$@"; }

_decide() { qa_advisory_decisions "$1" "$NOW_EPOCH" "$AUTOMATION"; }

# ── pure decision ────────────────────────────────────────────────────────────

@test "qa: an undispositioned advisory with items → dispatch, attempt 1" {
  run _decide "$(_list "$(_adv)")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].id' <<< "$output")" = "IC_adv" ]
  [ "$(jq -r '.[0].decision' <<< "$output")" = "dispatch" ]
  [ "$(jq -r '.[0].attempt' <<< "$output")" = "1" ]
}

@test "qa(bound): a dispositioned advisory never dispatches again" {
  disp=$(_c IC_d 'Applied 2, declined 0.
<!-- dev-lead:advisory-disposition id=IC_adv outcome=handled -->' 2026-10-01T21:00:00Z)
  run _decide "$(_list "$(_adv)" "$disp")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].decision' <<< "$output")" = "skip" ]
  [ "$(jq -r '.[0].reason' <<< "$output")" = "dispositioned" ]
  # Long after every window, with no attempts used, it still never dispatches.
  run qa_advisory_decisions "$(_list "$(_adv)" "$disp")" $(( NOW_EPOCH + 86400 * 30 )) "$AUTOMATION"
  [ "$(jq -r '[.[] | select(.decision == "dispatch")] | length' <<< "$output")" = "0" ]
}

@test "qa(bound): an escalated disposition also ends the advisory" {
  disp=$(_c IC_d '<!-- dev-lead:advisory-disposition id=IC_adv outcome=escalated -->')
  run _decide "$(_list "$(_c IC_adv "$(_advisory_body yes 'x')")" "$disp")"
  [ "$(jq -r '.[0].reason' <<< "$output")" = "dispositioned" ]
}

@test "qa: a disposition naming another advisory does not cover this one" {
  disp=$(_c IC_d '<!-- dev-lead:advisory-disposition id=IC_adv2 outcome=handled -->')
  run _decide "$(_list "$(_adv)" "$disp")"
  [ "$(jq -r '.[0].decision' <<< "$output")" = "dispatch" ]
}

@test "qa: a disposition whose id merely starts with this advisory's id does not cover it" {
  disp=$(_c IC_d '<!-- dev-lead:advisory-disposition id=IC_advX -->')
  run _decide "$(_list "$(_adv)" "$disp")"
  [ "$(jq -r '.[0].decision' <<< "$output")" = "dispatch" ]
}

@test "qa: a disposition without outcome= does not cover the advisory" {
  disp=$(_c IC_d '<!-- dev-lead:advisory-disposition id=IC_adv -->')
  run _decide "$(_list "$(_adv)" "$disp")"
  [ "$(jq -r '.[0].decision' <<< "$output")" = "dispatch" ]
}

@test "qa: a retracted disposition (its claim did not land) re-opens the advisory" {
  disp=$(_c IC_d '**⚠️ Retracted by the dev-lead harness (`not-on-ref`).**

> Applied.
> <!-- dev-lead:advisory-disposition id=IC_adv outcome=handled -->

<!-- dev-lead:retracted reason=not-on-ref -->')
  run _decide "$(_list "$(_adv)" "$disp")"
  [ "$(jq -r '.[0].decision' <<< "$output")" = "dispatch" ]
}

@test "qa: a forged disposition from an untrusted author is ignored" {
  disp=$(_c IC_d '<!-- dev-lead:advisory-disposition id=IC_adv -->' 2026-10-01T21:00:00Z NONE drive-by)
  run _decide "$(_list "$(_adv)" "$disp")"
  [ "$(jq -r '.[0].decision' <<< "$output")" = "dispatch" ]
  # A trusted association under a login that is not our automation is ignored too.
  disp=$(_c IC_d '<!-- dev-lead:advisory-disposition id=IC_adv -->' 2026-10-01T21:00:00Z COLLABORATOR someone)
  run _decide "$(_list "$(_adv)" "$disp")"
  [ "$(jq -r '.[0].decision' <<< "$output")" = "dispatch" ]
}

@test "qa: an advisory with no items (out-of-scope note) is never a candidate" {
  run _decide "$(_list "$(_c IC_adv "$(_advisory_body no)")")"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" = "0" ]
  run _decide "$(_list "$(_c IC_adv $'<!-- persona:qa-lead -->\nThis PR has no test surface; outside the QA Lead role.')")"
  [ "$(jq -r 'length' <<< "$output")" = "0" ]
}

@test "qa: another persona's advisory and a forged qa-lead marker are not candidates" {
  run _decide "$(_list \
    "$(_c IC_sa "$(_advisory_body no 'x' | sed 's/persona:qa-lead/persona:solution-architect/')")" \
    "$(_c IC_forged "$(_advisory_body no 'x')" 2026-10-01T20:00:00Z NONE drive-by)" \
    "$(_c IC_mid "Quoting it: $(_advisory_body no 'x')")")"
  [ "$(jq -r 'length' <<< "$output")" = "0" ]
}

@test "qa: Escalate? yes → escalate, never dispatch" {
  run _decide "$(_list "$(_c IC_adv "$(_advisory_body 'yes — the hollow assertions must be fixed before merge' 'Fix the assertions.')")")"
  [ "$(jq -r '.[0].decision' <<< "$output")" = "escalate" ]
  run _decide "$(_list "$(_c IC_adv "$(_advisory_body 'Yes' 'x')")")"
  [ "$(jq -r '.[0].decision' <<< "$output")" = "escalate" ]
}

@test "qa: a retry marker inside the pending window holds the advisory" {
  m=$(_c IC_m "$(qa_advisory_retry_marker IC_adv 1 2026-10-02T00:00:00Z)" 2026-10-02T00:00:00Z)
  run _decide "$(_list "$(_adv)" "$m")"
  [ "$(jq -r '.[0].decision' <<< "$output")" = "skip" ]
  [ "$(jq -r '.[0].reason' <<< "$output")" = "retry-pending" ]
}

@test "qa: after an expired retry with no disposition the next attempt is attempt 2" {
  m=$(_c IC_m "$(qa_advisory_retry_marker IC_adv 1 2026-10-01T20:00:00Z)" 2026-10-01T20:00:00Z)
  run _decide "$(_list "$(_adv)" "$m")"
  [ "$(jq -r '.[0].decision' <<< "$output")" = "dispatch" ]
  [ "$(jq -r '.[0].attempt' <<< "$output")" = "2" ]
}

@test "qa(bound): MAX_ATTEMPTS retries without a disposition exhaust the advisory" {
  m1=$(_c IC_m1 "$(qa_advisory_retry_marker IC_adv 1 2026-10-01T10:00:00Z)" 2026-10-01T10:00:00Z)
  m2=$(_c IC_m2 "$(qa_advisory_retry_marker IC_adv 2 2026-10-01T15:00:00Z)" 2026-10-01T15:00:00Z)
  run _decide "$(_list "$(_adv)" "$m1" "$m2")"
  [ "$(jq -r '.[0].decision' <<< "$output")" = "skip" ]
  [ "$(jq -r '.[0].reason' <<< "$output")" = "retry-attempts-exhausted" ]
}

@test "qa: retry markers from outside our automation are ignored" {
  m=$(_c IC_m "$(qa_advisory_retry_marker IC_adv 1 2026-10-02T00:00:00Z)" 2026-10-02T00:00:00Z NONE drive-by)
  run _decide "$(_list "$(_adv)" "$m")"
  [ "$(jq -r '.[0].decision' <<< "$output")" = "dispatch" ]
}

@test "qa: a recent bot-comment or bot-thread retry holds the shared per-PR lane" {
  m=$(_c IC_m '<!-- dev-lead-bot-thread-retry threads=PRRT_x attempt=1 at=2026-10-02T00:55:00Z -->' 2026-10-02T00:55:00Z)
  run _decide "$(_list "$(_adv)" "$m")"
  [ "$(jq -r '.[0].reason' <<< "$output")" = "lane-busy" ]
  m=$(_c IC_m '<!-- dev-lead-bot-comment-retry id=IC_b version=2026-10-01T00:00:00Z attempt=1 at=2026-10-02T00:55:00Z -->' 2026-10-02T00:55:00Z)
  run _decide "$(_list "$(_adv)" "$m")"
  [ "$(jq -r '.[0].reason' <<< "$output")" = "lane-busy" ]
  # An old one does not.
  m=$(_c IC_m '<!-- dev-lead-bot-thread-retry threads=PRRT_x attempt=1 at=2026-10-01T10:00:00Z -->' 2026-10-01T10:00:00Z)
  run _decide "$(_list "$(_adv)" "$m")"
  [ "$(jq -r '.[0].decision' <<< "$output")" = "dispatch" ]
}

@test "qa: a recent QA advisory retry marker for another advisory holds the shared lane" {
  m=$(_c IC_m "$(qa_advisory_retry_marker IC_other 1 2026-10-02T00:55:00Z)" 2026-10-02T00:55:00Z)
  run _decide "$(_list "$(_adv)" "$m")"
  [ "$(jq -r '.[0].reason' <<< "$output")" = "lane-busy" ]
}

@test "qa: several open advisories are listed oldest first" {
  run _decide "$(_list \
    "$(_c IC_new "$(_advisory_body no 'b')" 2026-10-01T22:00:00Z)" \
    "$(_c IC_old "$(_advisory_body no 'a')" 2026-10-01T12:00:00Z)")"
  [ "$(jq -r 'map(.id) | join(",")' <<< "$output")" = "IC_old,IC_new" ]
}

@test "qa: unreadable input or no automation logins fails closed" {
  run qa_advisory_decisions 'not json' "$NOW_EPOCH" "$AUTOMATION"
  [ "$status" -ne 0 ]
  run qa_advisory_decisions '{"a":1}' "$NOW_EPOCH" "$AUTOMATION"
  [ "$status" -ne 0 ]
  run qa_advisory_decisions "$(_list "$(_adv)")" "$NOW_EPOCH" ""
  [ "$status" -ne 0 ]
  run qa_advisory_decisions "$(_list "$(_adv)")" "soon" "$AUTOMATION"
  [ "$status" -ne 0 ]
}

@test "qa_advisory_open: lists open, non-escalated advisories for the pass, without dispositioned ones" {
  disp=$(_c IC_d '<!-- dev-lead:advisory-disposition id=IC_done outcome=handled -->')
  run qa_advisory_open "$(_list \
    "$(_adv)" \
    "$(_c IC_done "$(_advisory_body no 'x')")" \
    "$(_c IC_esc "$(_advisory_body yes 'x')")" \
    "$disp")" "$AUTOMATION"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'map(.id) | join(",")' <<< "$output")" = "IC_adv" ]
  [[ "$(jq -r '.[0].body' <<< "$output")" == *"legacy-ledger upgrade test"* ]]
}

@test "qa: the disposition and retry markers stay out of the maintainer gate, and carry no persona marker" {
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/scripts/lib/maintainer-comment-gate.sh"
  disp='<!-- dev-lead:advisory-disposition id=IC_adv outcome=handled -->'
  [[ "$disp" =~ $_MAINTAINER_GATE_AGENT_MARKERS ]]
  marker="$(qa_advisory_retry_marker IC_adv 1 2026-10-02T00:00:00Z)"
  [[ "$marker" =~ $_MAINTAINER_GATE_AGENT_MARKERS ]]
  # The router's recursion guard keys on '<!-- persona:'; neither marker has it.
  [[ "$disp$marker" != *"persona:"* ]]
  [[ "$(qa_advisory_escalation_body IC_adv)" != *"persona:"* ]]
  [[ "$(qa_advisory_escalation_body IC_adv)" != *"@combsmith/"* ]]
}

# ── sweep wiring (dev-lead-retry.sh) ─────────────────────────────────────────

_comments_page() {
  local nodes='[]'
  [ "$#" -eq 0 ] || nodes="$(jq -sc '.' <<< "$*")"
  jq -nc --argjson nodes "$nodes" \
    '{data:{repository:{pullRequest:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$nodes}}}}}'
}

_setup_sweep() {
  MOCK_BIN="$(mktemp -d)"
  export PATH="$MOCK_BIN:$PATH"
  export DRY_RUN="false"
  export NOW_ISO="2026-10-02T01:00:00Z"
  export GH_LOG="$MOCK_BIN/gh.log"
  export DEV_LEAD_USER="don-petry" PR_REVIEW_USER="donpetry-bot"
  : "${COMMENTS_RESPONSE:=$(_comments_page)}"
  export COMMENTS_RESPONSE
  if [ -z "${PR_JSON:-}" ]; then
    export PR_JSON='{"state":"open","head":{"sha":"abc","ref":"dev-lead/issue-1900-x","repo":{"full_name":"combsmith/.github-private"}},"user":{"login":"don-petry"},"labels":[]}'
  fi
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
case "$args" in
  *"/dispatches"*) cat > "$GH_LOG.payload"; [ -n "${DISPATCH_FAILS:-}" ] && exit 1; exit 0 ;;
  *"/labels"*) [ -n "${LABEL_FAILS:-}" ] && { echo "gh: Forbidden (HTTP 403)"; exit 1; }; echo "[]" ;;
  *"api graphql"*) printf '%s' "$COMMENTS_RESPONSE" ;;
  *"--method POST"*"/comments"*) echo "888 ${MARKER_LOGIN:-don-petry} ${MARKER_ASSOC:-OWNER}" ;;
  *"-X DELETE"*) exit 0 ;;
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

teardown() {
  if [ -n "${MOCK_BIN:-}" ] && [ -d "$MOCK_BIN" ]; then
    rm -rf "$MOCK_BIN" || true
  fi
}

@test "sweep: an undispositioned advisory dispatches exactly one review-changes retry, marker first" {
  export COMMENTS_RESPONSE
  COMMENTS_RESPONSE="$(_comments_page "$(_adv)")"
  _setup_sweep

  run scan_pr_for_qa_advisories "combsmith/.github-private" 180
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "1" ]
  [ "$(grep -c '/dispatches' "$GH_LOG")" -eq 1 ]
  payload="$(cat "$GH_LOG.payload")"
  [ "$(jq -r '.event_type' <<< "$payload")" = "dev-lead-reviews-retry" ]
  [ "$(jq -r '.client_payload.intent_type' <<< "$payload")" = "review-changes" ]
  [ "$(jq -r '.client_payload.pr_number' <<< "$payload")" = "180" ]
  grep -q 'dev-lead-qa-advisory-retry id=IC_adv attempt=1 at=2026-10-02T01:00:00Z' "$GH_LOG"
  marker_line=$(grep -n 'dev-lead-qa-advisory-retry' "$GH_LOG" | head -1 | cut -d: -f1)
  dispatch_line=$(grep -n '/dispatches' "$GH_LOG" | head -1 | cut -d: -f1)
  [ "$marker_line" -lt "$dispatch_line" ]
}

@test "sweep(bound): a dispositioned advisory posts nothing and dispatches nothing" {
  export COMMENTS_RESPONSE
  COMMENTS_RESPONSE="$(_comments_page "$(_adv)" \
    "$(_c IC_d '<!-- dev-lead:advisory-disposition id=IC_adv outcome=handled -->' 2026-10-01T21:00:00Z)")"
  _setup_sweep

  run scan_pr_for_qa_advisories "combsmith/.github-private" 180
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q -- '--method POST' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: Escalate? yes posts an escalated disposition, never applies hold label, dispatches nothing" {
  export COMMENTS_RESPONSE
  COMMENTS_RESPONSE="$(_comments_page "$(_c IC_adv "$(_advisory_body yes 'Fix the assertions.')")")"
  _setup_sweep

  run scan_pr_for_qa_advisories "combsmith/.github-private" 180
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0" ]
  grep -q 'dev-lead:advisory-disposition id=IC_adv outcome=escalated' "$GH_LOG"
  if grep -q 'labels\[\]=dev-lead:needs-human' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: Escalate? yes posts an escalated disposition and dispatches nothing" {
  export COMMENTS_RESPONSE
  COMMENTS_RESPONSE="$(_comments_page "$(_c IC_adv "$(_advisory_body yes 'x')")")"
  _setup_sweep

  run scan_pr_for_qa_advisories "combsmith/.github-private" 180
  [ "${lines[-1]}" = "0" ]
  grep -q 'advisory-disposition' "$GH_LOG"
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a PR dev-lead did not author is never scanned" {
  export COMMENTS_RESPONSE
  COMMENTS_RESPONSE="$(_comments_page "$(_adv)")"
  export PR_JSON='{"state":"open","head":{"sha":"abc","ref":"feature","repo":{"full_name":"combsmith/.github-private"}},"user":{"login":"someone"},"labels":[]}'
  _setup_sweep

  run scan_pr_for_qa_advisories "combsmith/.github-private" 180
  [ "${lines[-1]}" = "0" ]
  if grep -q 'graphql' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a fork head with dev-lead's login is never scanned" {
  export COMMENTS_RESPONSE
  COMMENTS_RESPONSE="$(_comments_page "$(_adv)")"
  export PR_JSON='{"state":"open","head":{"sha":"abc","ref":"dev-lead/issue-1-x","repo":{"full_name":"someone/.github-private"}},"user":{"login":"don-petry"},"labels":[]}'
  _setup_sweep

  run scan_pr_for_qa_advisories "combsmith/.github-private" 180
  [ "${lines[-1]}" = "0" ]
  if grep -q 'graphql' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a held PR gets no retry marker and no dispatch" {
  export COMMENTS_RESPONSE
  COMMENTS_RESPONSE="$(_comments_page "$(_adv)")"
  export PR_JSON='{"state":"open","head":{"sha":"abc","ref":"dev-lead/issue-1900-x","repo":{"full_name":"combsmith/.github-private"}},"user":{"login":"don-petry"},"labels":[{"name":"dev-lead:hands-off"}]}'
  _setup_sweep
  # Use the REAL resume gate (the default harness stubs it to "proceed").
  # shellcheck source=/dev/null
  source "$(dirname "$RETRY_SCRIPT")/lib/pr-automation-budget.sh"

  run scan_pr_for_qa_advisories "combsmith/.github-private" 180
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q -- '--method POST' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a recent dispatch guard for the head SHA defers to the run already queued" {
  export COMMENTS_RESPONSE
  COMMENTS_RESPONSE="$(_comments_page "$(_adv)" \
    "$(_c IC_g '<!-- dev-lead-dispatch-guard sha=abc at=2026-10-02T00:58:00Z -->' 2026-10-02T00:58:00Z)")"
  _setup_sweep

  run scan_pr_for_qa_advisories "combsmith/.github-private" 180
  [ "${lines[-1]}" = "0" ]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: an unreadable comment list fails closed" {
  export COMMENTS_RESPONSE='{"errors":[{"message":"boom"}]}'
  _setup_sweep

  run scan_pr_for_qa_advisories "combsmith/.github-private" 180
  [ "${lines[-1]}" = "0" ]
  if grep -q -- '--method POST' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a failed dispatch withdraws its marker" {
  export COMMENTS_RESPONSE
  COMMENTS_RESPONSE="$(_comments_page "$(_adv)")"
  export DISPATCH_FAILS=1
  _setup_sweep

  run scan_pr_for_qa_advisories "combsmith/.github-private" 180
  [ "${lines[-1]}" = "0" ]
  grep -q -- '-X DELETE.*comments/888' "$GH_LOG"
}

@test "sweep: a retry marker posted under an unrecognised login is withdrawn, not dispatched" {
  export COMMENTS_RESPONSE
  COMMENTS_RESPONSE="$(_comments_page "$(_adv)")"
  export MARKER_LOGIN=stranger
  _setup_sweep

  run scan_pr_for_qa_advisories "combsmith/.github-private" 180
  [ "${lines[-1]}" = "0" ]
  grep -q -- '-X DELETE.*comments/888' "$GH_LOG"
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: a retry marker posted with an untrusted association is withdrawn, not dispatched" {
  export COMMENTS_RESPONSE
  COMMENTS_RESPONSE="$(_comments_page "$(_adv)")"
  export MARKER_ASSOC=NONE
  _setup_sweep

  run scan_pr_for_qa_advisories "combsmith/.github-private" 180
  [ "${lines[-1]}" = "0" ]
  grep -q -- '-X DELETE.*comments/888' "$GH_LOG"
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: DRY_RUN posts no marker and sends no dispatch" {
  export COMMENTS_RESPONSE
  COMMENTS_RESPONSE="$(_comments_page "$(_adv)")"
  _setup_sweep
  export DRY_RUN="true"

  run scan_pr_for_qa_advisories "combsmith/.github-private" 180
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"would dispatch dev-lead-reviews-retry"*"intent=review-changes"* ]]
  if grep -q '/dispatches' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
  if grep -q -- '--method POST' "$GH_LOG"; then cat "$GH_LOG"; return 1; fi
}

@test "sweep: scan_repo runs the advisory scan only when no other retry was dispatched for the PR" {
  _setup_sweep
  scan_pr_for_rate_limits() { echo "0"; }
  scan_pr_for_undispositioned_bot_comments() { echo "0"; }
  scan_pr_for_unreplied_bot_threads() { echo "1"; }
  scan_pr_for_qa_advisories() { echo "QA-SCAN" >&2; echo "1"; }
  scan_repo_issues() { :; }
  gh() { echo '[{"number":180,"head_sha":"abc"}]'; }
  run scan_repo "combsmith/.github-private"
  [[ "$output" != *"QA-SCAN"* ]]

  scan_pr_for_unreplied_bot_threads() { echo "0"; }
  run scan_repo "combsmith/.github-private"
  [[ "$output" == *"QA-SCAN"* ]]
  [[ "$output" == *"dispatched 1 PR retries"* ]]
}

# ── the review-changes pass reads the advisories ─────────────────────────────

@test "review-changes prompt declares QA_ADVISORIES_JSON and the disposition contract" {
  p="$SCRIPT_DIR/prompts/dev-lead/review-changes.md"
  head -1 "$p" | grep -q 'QA_ADVISORIES_JSON'
  grep -qF '${QA_ADVISORIES_JSON}' "$p"
  grep -qF '<!-- dev-lead:advisory-disposition id=' "$p"
}

@test "fix-reviews: the review-changes branch exports the open advisories for the prompt" {
  f="$SCRIPT_DIR/scripts/dev-lead-fix-reviews.sh"
  grep -q 'lib/qa-advisory-retry.sh' "$f"
  grep -q 'QA_ADVISORIES_JSON=' "$f"
}

# export_qa_advisories behaviour (lives in the lib so it can be sourced alone)
@test "export_qa_advisories: fetch failure gives [] and a warning" {
  bcr_fetch_pr_comments() { return 1; }
  dev_lead_identity() { echo "don-petry"; }
  export PR_NUMBER=1 REPO=o/r
  gh() {
    case "$*" in
      *"repos/o/r/pulls/1"*) printf '{"user":{"login":"don-petry"}}' ;;
      *) echo "[]" ;;
    esac
  }
  export -f gh dev_lead_identity
  run export_qa_advisories
  [ "$status" -eq 0 ]
  [[ "$output" == *"[]" ]]
}

@test "export_qa_advisories: caps at 5 advisories and 4000 body chars, drops escalated/dispositioned" {
  export PR_NUMBER=1 REPO=o/r BOT_USER=don-petry DEV_LEAD_USER="don-petry"
  long=$(printf 'x%.0s' $(seq 1 5000))
  list=()
  for i in 1 2 3 4 5 6; do
    list+=("$(_c "IC_a$i" "$(_advisory_body no "$long")" "2026-10-01T1$i:00:00Z")")
  done
  list+=("$(_c IC_esc "$(_advisory_body yes 'x')")")
  list+=("$(_c IC_done "$(_advisory_body no 'x')")")
  list+=("$(_c IC_d '<!-- dev-lead:advisory-disposition id=IC_done outcome=handled -->')")
  COMMENTS="$(_list "${list[@]}")"
  bcr_fetch_pr_comments() { printf '%s' "$COMMENTS"; }
  dev_lead_identity() { echo "don-petry"; }
  gh() {
    case "$*" in
      *"repos/o/r/pulls/1"*) printf '{"user":{"login":"don-petry"}}' ;;
      *) echo "[]" ;;
    esac
  }
  export -f gh dev_lead_identity
  run export_qa_advisories
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" = "5" ]
  [ "$(jq -r 'map(.id) | index("IC_esc")' <<< "$output")" = "null" ]
  [ "$(jq -r 'map(.body | length) | max' <<< "$output")" -le 4000 ]
}

@test "export_qa_advisories: dry run gives []" {
  export PR_NUMBER=1 REPO=o/r DEV_LEAD_DRY_RUN=true
  dev_lead_identity() { echo "don-petry"; }
  gh() {
    case "$*" in
      *"repos/o/r/pulls/1"*) printf '{"user":{"login":"don-petry"}}' ;;
      *) echo "[]" ;;
    esac
  }
  export -f gh dev_lead_identity
  run export_qa_advisories
  [ "$output" = "[]" ]
}

@test "export_qa_advisories: works without dev_lead_identity and honours a don-petry disposition when BOT_USER is donpetry-bot" {
  export PR_NUMBER=1 REPO=o/r BOT_USER=donpetry-bot DEV_LEAD_USER="don-petry"
  unset -f dev_lead_identity
  COMMENTS="$(_list \
    "$(_c IC_open "$(_advisory_body no 'Gap A.')" 2026-10-01T10:00:00Z)" \
    "$(_c IC_done "$(_advisory_body no 'Gap B.')" 2026-10-01T11:00:00Z)" \
    "$(_c IC_d '<!-- dev-lead:advisory-disposition id=IC_done outcome=handled -->' 2026-10-01T12:00:00Z OWNER don-petry)")"
  bcr_fetch_pr_comments() { printf '%s' "$COMMENTS"; }
  gh() {
    case "$*" in
      *"repos/o/r/pulls/1"*) printf '{"user":{"login":"don-petry"}}' ;;
      *) echo "[]" ;;
    esac
  }
  export -f gh
  run export_qa_advisories
  [ "$status" -eq 0 ]
  [ "$(jq -r 'map(.id) | join(",")' <<< "$output")" = "IC_open" ]
}

@test "qa: logins list tolerates whitespace around entries" {
  run _qa_logins_json " don-petry , donpetry-bot[bot] "
  [ "$status" -eq 0 ]
  [ "$output" = '["don-petry","donpetry-bot"]' ]
}

@test "export_qa_advisories: PR author read failure gives [] and a warning" {
  export PR_NUMBER=1 REPO=o/r
  dev_lead_identity() { echo "don-petry"; }
  bcr_fetch_pr_comments() { printf '[]'; }
  gh() { return 1; }
  export -f gh dev_lead_identity
  run --separate-stderr export_qa_advisories
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [[ "$stderr" == *"could not read the PR author"* ]]
}

@test "export_qa_advisories: honours a donpetry-bot disposition" {
  export PR_NUMBER=1 REPO=o/r BOT_USER=don-petry
  dev_lead_identity() { echo "don-petry"; }
  COMMENTS="$(_list \
    "$(_c IC_open "$(_advisory_body no 'Gap A.')" 2026-10-01T10:00:00Z)" \
    "$(_c IC_done "$(_advisory_body no 'Gap B.')" 2026-10-01T11:00:00Z)" \
    "$(_c IC_d '<!-- dev-lead:advisory-disposition id=IC_done outcome=handled -->' 2026-10-01T12:00:00Z OWNER donpetry-bot)")"
  bcr_fetch_pr_comments() { printf '%s' "$COMMENTS"; }
  gh() {
    case "$*" in
      *"repos/o/r/pulls/1"*) printf '{"user":{"login":"don-petry"}}' ;;
      *) echo "[]" ;;
    esac
  }
  export -f gh dev_lead_identity
  run export_qa_advisories
  [ "$status" -eq 0 ]
  [ "$(jq -r 'map(.id) | join(",")' <<< "$output")" = "IC_open" ]
}
