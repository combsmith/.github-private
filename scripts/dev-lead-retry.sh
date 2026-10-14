#!/usr/bin/env bash
set -euo pipefail
# dev-lead-retry.sh — scan open PRs + issues for failure markers and re-dispatch
#
# timer_role: safety-net (docs/agentic-interaction-model.md §6.1). This is the
# 2 h cron's *backstop* — NOT the normal-path convergence clock it used to be
# (the #860 "amplifier"). Since #1407, a blocked/rate-limited dev-lead state is
# resumed EVENT-FIRST the moment a clearing event arrives (a review submitted or
# a check_run success) via scripts/dev-lead-resume.sh; this timer only catches
# the rare, genuinely un-eventable rate-limit recovery where no such event ever
# fires. Both paths dispatch through the SAME logic here (scan_pr_for_rate_limits)
# and the SAME stop-condition (pr_resume_suppressed), so the timer can never
# re-dispatch work the event path would not.
#
# Stop-condition-before-acting (§6.2.1): every scan re-checks, BEFORE any
# dispatch, that the PR is still open, is not human-gated (needs-human-review),
# has not exhausted its per-PR automation budget, and that the rate-limit reset
# window has actually elapsed with no terminal marker already posted.
#
# Called by the dev-lead-retry.yml scheduled cron workflow.
# Scans all open PRs across TARGET_ORG (plus DELEGATION_ORGS if set) for
# status=rate-limited markers on the current HEAD SHA, then re-dispatches the
# appropriate dev-lead event so the run is retried once the rate limit clears.
#
# It ALSO scans open issues labeled `dev-lead` for failed initial implementations
# (#781): an issue whose `Run issue` engine step failed carries a
# `<!-- dev-lead-issue <N> status=<failed|rate-limited> attempt=<K> ... -->`
# marker (written by dev-lead-fix-issue.sh). Those are re-dispatched as
# dev-lead-issue-retry up to MAX_ATTEMPTS, after which fix-issue.sh escalates to
# a human (dev-lead:needs-human) and the scan skips them.
#
# Env (required):
#   GH_TOKEN            — PAT with repo + contents:write scopes
#   TARGET_ORG          — GitHub org to scan (default: petry-projects)
#
# Env (optional):
#   DELEGATION_ORGS     — space-separated additional orgs to scan
#   DISPATCH_DELAY_SEC  — seconds between repo dispatches (default: 30) to
#                         prevent cascading org-wide rate-limit hits
#   DRY_RUN             — if "true", log what would be dispatched but don't send
#   SWEEP_AGENT_REF     — the dev-lead channel the sweep's scripts/ run at;
#                         turns on the #2086 per-target payload-field gate
#                         (dev-lead-retry.yml passes it; unset = gate off)
#   NOW_ISO             — override current time for testing (ISO-8601 UTC)
#   BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC — seconds to wait after posting a
#                         bot-comment retry marker before re-listing markers
#                         to pick the earliest (default: 5), so a concurrent
#                         scan's marker is visible to the listing
#
# Retryable intents: fix-reviews, review-changes, rebase
#   These intents fetch all needed context (open threads, PR metadata) fresh
#   from the GitHub API at run time, so a re-dispatch has full fidelity.
#
# It ALSO re-dispatches fix-reviews for a bot comment EDITED after its dev-lead
# disposition (#2008). CodeRabbit edits one summary comment in place, for example
# to append a Security Architecture finding, and dev-lead only fires on CREATED
# comments. The caller stub's `on:` is standards-owned, so this sweep is the
# trigger. It is deduplicated: a successful fix-reviews run marker posted
# at/after the edit means a pass already saw the edited body, so CodeRabbit's
# frequent progress edits don't each spawn a run (stale_disposition_needs_dispatch).
#
# NOT retried automatically: on-mention
#   on-mention requires USER_INSTRUCTION from the original triggering event,
#   which cannot be reconstructed from the PR's current state. Users are asked
#   to re-trigger manually.
#
# fix-bot-comment IS retried, by a separate scan (#2017). A registered reviewer
#   bot's issue comment still exists, so its context can be rebuilt: the retry
#   dispatch carries only the comment's node id, and dev-lead-intent.sh
#   re-fetches the comment's CURRENT body, author and lastEditedAt by that id.
#   scan_pr_for_undispositioned_bot_comments finds open dev-lead PRs where such
#   a comment has no covering disposition and no info_status_pattern match, and
#   dispatches one deduplicated fix-bot-comment pass (lib/bot-comment-retry.sh).
#   This recovers the run GitHub drops when a burst of PR events supersedes the
#   pending fix-bot-comment run in the per-PR concurrency lane (#2009).
#
# Unreplied bot review threads are retried too (#2046). A trusted reviewer bot's
#   review thread is processed only by a fix-reviews pass. When that pass is lost,
#   the thread keeps blocking the merge with no reply.
#   scan_pr_for_unreplied_bot_threads finds unresolved, non-outdated, bot-opened
#   threads with no reply from our automation, and dispatches one deduplicated
#   fix-reviews pass per PR (lib/bot-thread-retry.sh). Threads that exhaust their
#   attempts get a single visible notice, so the stall is never silent.
#
# Each payload is gated on the target repo's own dev-lead.yml pin (#2086). The
#   sweep runs one release of scripts/ (this repo's pinned channel), but every
#   target parses a payload with dev-lead-intent.sh at its own pin. A payload
#   carrying a client_payload field that parser does not read is held back, with
#   a ::warning:: naming the field (lib/dispatch-channel-gate.sh); payloads every
#   release reads still reach older-pinned repos.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Escalation gate (#946): pr_has_escalation_label / NEEDS_HUMAN_REVIEW_LABEL.
# shellcheck source=lib/pr-automation-budget.sh
source "$SCRIPT_DIR/lib/pr-automation-budget.sh"
# Stale-disposition detector (#2008): maintainer_gate_stale_dispositions. Sourced
# only if not already loaded: its marker regex is readonly, and a caller (e.g.
# review-one-pr.sh via the advisory gate) may have sourced it before this script.
if [ -z "${_MAINTAINER_GATE_AGENT_MARKERS:-}" ]; then
  # shellcheck source=lib/maintainer-comment-gate.sh
  source "$SCRIPT_DIR/lib/maintainer-comment-gate.sh"
fi
# Undispositioned bot-comment retry decision + comment fetch (#2017).
# shellcheck source=lib/bot-comment-retry.sh
source "$SCRIPT_DIR/lib/bot-comment-retry.sh"
# Unreplied bot review-thread retry decision + thread fetch (#2046).
# shellcheck source=lib/bot-thread-retry.sh
source "$SCRIPT_DIR/lib/bot-thread-retry.sh"
# Per-target payload-field gate (#2086): dcg_init / dcg_payload_allowed / dcg_target_reads.
# shellcheck source=lib/dispatch-channel-gate.sh
source "$SCRIPT_DIR/lib/dispatch-channel-gate.sh"
# Budget poller log reader (#2139): bp_download_latest_log / bp_last_ok / bp_staleness.
# shellcheck source=lib/budget-poller.sh
source "$SCRIPT_DIR/lib/budget-poller.sh"

TARGET_ORG="${TARGET_ORG:-petry-projects}"
DELEGATION_ORGS="${DELEGATION_ORGS:-}"
DISPATCH_DELAY_SEC="${DISPATCH_DELAY_SEC:-30}"
DRY_RUN="${DRY_RUN:-false}"
BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC="${BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC:-5}"
[[ "$BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC" =~ ^[0-9]+$ ]] || BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC=5

CI_MARKER_PREFIX="<!-- dev-lead-fix-ci sha="
REVIEWS_MARKER_PREFIX="<!-- dev-lead-fix-reviews pr="
ISSUE_MARKER_PREFIX="<!-- dev-lead-issue "

# Dispatch deduplication guard: prevents duplicate repository_dispatch calls
# when the event-first resume path and the safety-net cron arrive concurrently
# on the same PR. A guard marker is posted BEFORE dispatch; concurrent callers
# that see a recent guard skip instead of double-dispatching.
DISPATCH_GUARD_PREFIX="<!-- dev-lead-dispatch-guard sha="
DISPATCH_GUARD_WINDOW_SEC="${DISPATCH_GUARD_WINDOW_SEC:-600}"

# Issue-retry config (#781). MAX_ATTEMPTS matches dev-lead-fix-issue.sh and the
# auto-rebase-retry.sh convention: total attempts (initial + retries) before the
# issue is escalated to a human and skipped here.
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
HISTORY_UNAVAILABLE_MAX_RETRIES="${HISTORY_UNAVAILABLE_MAX_RETRIES:-3}"
[[ "$HISTORY_UNAVAILABLE_MAX_RETRIES" =~ ^[0-9]+$ ]] || HISTORY_UNAVAILABLE_MAX_RETRIES=3
PARTIAL_MAX_RETRIES="${PARTIAL_MAX_RETRIES:-3}"
[[ "$PARTIAL_MAX_RETRIES" =~ ^[0-9]+$ ]] || PARTIAL_MAX_RETRIES=3
DEV_LEAD_LABEL="${DEV_LEAD_LABEL:-dev-lead}"
NEEDS_HUMAN_LABEL="${NEEDS_HUMAN_LABEL:-dev-lead:needs-human}"

# Intents whose context can be fully reconstructed at retry time.
# human-pr is included as a legacy alias for review-changes so that PRs already
# marked status=rate-limited with the old intent name are retried during migration.
RETRYABLE_REVIEW_INTENTS="fix-reviews review-changes human-pr rebase"

# get_now_epoch: current UTC time as unix epoch (overridable for tests)
get_now_epoch() {
  if [ -n "${NOW_ISO:-}" ]; then
    date -u -d "$NOW_ISO" +%s 2>/dev/null || date -u +%s
  else
    date -u +%s
  fi
}

# is_reset_in_future <reset_iso>: returns 0 if reset time is still in the future
is_reset_in_future() {
  local reset_iso="$1"
  [ -z "$reset_iso" ] && return 1  # unknown reset = don't skip
  local reset_epoch
  reset_epoch=$(date -u -d "$reset_iso" +%s 2>/dev/null || echo 0)
  [ "$(get_now_epoch)" -lt "$reset_epoch" ]
}

# ── Budget hold (#2139) ─────────────────────────────────────────────────────
# The dry-run budget poller (#2029) is the one workflow holding the Claude
# token; it publishes each usage read as a `budget-poller-log` artifact. This
# cron reads that artifact once per run (budget_hold_init, from main) and holds
# status=rate-limited retries while the `session` or `weekly_all` window is at or
# above 100% with a future reset, until the later such reset. The rate-limit
# text is never parsed, and weekly_scoped (per-model, handled by model fallback)
# is never read. Every failure fails open: no hold, retry exactly as before.

# budget_hold_reset_epoch <iso>: epoch for an ISO-8601 reset with a date, a time
# and an optional Z/offset, or empty. date -d alone would also accept free text.
budget_hold_reset_epoch() {
  local iso="${1:-}"
  [[ "$iso" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:?[0-9]{2})?$ ]] || return 0
  date -u -d "$iso" +%s 2>/dev/null || true
}

# budget_hold_from_record <record_json> <now_epoch>: PURE apart from date. Echo
#   `hold <session|weekly|session+weekly> <reset ISO, UTC>` — exhausted window(s)
#       with a future reset; when both, the later reset;
#   `missing <window>` — no hold, and a window's percent, or an exhausted
#       window's reset, is absent or unparseable (fail open);
#   `none` — no window is exhausted with a future reset.
budget_hold_from_record() {
  local record="$1" now="$2" fields s_pct s_reset w_pct w_reset w pct reset epoch label="" until=0 missing=""
  fields=$(jq -r '[ (.session_pct | numbers | tostring) // "", (.session_resets_at | strings) // "",
                    (.weekly_all_pct | numbers | tostring) // "", (.weekly_all_resets_at | strings) // "" ]
                  | map(gsub("[|\n]"; " ")) | join("|")' <<< "$record" 2>/dev/null || true)
  IFS='|' read -r s_pct s_reset w_pct w_reset <<< "$fields"
  for w in session weekly_all; do
    if [ "$w" = "session" ]; then pct="$s_pct" reset="$s_reset"; else pct="$w_pct" reset="$w_reset"; fi
    if [ -z "$pct" ]; then
      missing="${missing:-$w}"
      continue
    fi
    [ "$pct" -ge 100 ] 2>/dev/null || continue
    epoch=$(budget_hold_reset_epoch "$reset")
    if ! [[ "$epoch" =~ ^[0-9]+$ ]]; then
      missing="${missing:-$w}"
      continue
    fi
    [ "$epoch" -gt "$now" ] || continue
    label="${label:+${label}+}${w%_all}"
    [ "$epoch" -gt "$until" ] && until="$epoch"
  done
  if [ -n "$label" ]; then
    printf 'hold %s %s\n' "$label" "$(date -u -d "@$until" +%Y-%m-%dT%H:%M:%SZ)"
  elif [ -n "$missing" ]; then
    printf 'missing %s\n' "$missing"
  else
    printf 'none\n'
  fi
}

# budget_hold_init: once per cron run, read the poller's latest log and set
# BUDGET_HOLD_UNTIL (empty = no hold) and BUDGET_HOLD_WINDOW. Logs exactly one
# greppable `retry-cron:` line. Never fails.
budget_hold_init() {
  BUDGET_HOLD_UNTIL=""
  BUDGET_HOLD_WINDOW=""
  local log rc=0 record state now verdict age_text reason=""
  now=$(get_now_epoch)
  log=$(mktemp) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "retry-cron: budget hold fail-open (temp file unavailable), retrying as usual"
    return 0
  fi
  bp_download_latest_log "${BUDGET_POLLER_REPO:-petry-projects/.github-private}" "$log" || rc=$?
  if [ "$rc" -eq 1 ]; then
    reason="no readable ${BUDGET_POLLER_ARTIFACT} artifact"
  elif [ "$rc" -ne 0 ]; then
    reason="artifact download error"
  else
    record=$(bp_last_ok "$log")
    state=$(bp_staleness "$log" "$now")
    if [ -z "$record" ]; then
      reason="no poll==ok record"
    elif [ "$state" = "never" ]; then
      reason="unparseable record"
    else
      age_text=$(bp_age_text "${state#* }")
      if [ "${state%% *}" = "stale" ]; then
        reason="stale record, poll ${age_text} old > $(bp_stale_hours)h"
      fi
    fi
  fi
  rm -f "$log"
  if [ -n "$reason" ]; then
    echo "retry-cron: budget hold fail-open (${reason}), retrying as usual"
    return 0
  fi

  verdict=$(budget_hold_from_record "$record" "$now")
  case "$verdict" in
    hold\ session+weekly\ *)
      BUDGET_HOLD_WINDOW="session+weekly"
      BUDGET_HOLD_UNTIL="${verdict##* }"
      echo "retry-cron: session and weekly windows exhausted, holding retries until ${BUDGET_HOLD_UNTIL} (poll ${age_text} old)"
      ;;
    hold\ *)
      BUDGET_HOLD_WINDOW="${verdict#* }"
      BUDGET_HOLD_WINDOW="${BUDGET_HOLD_WINDOW%% *}"
      BUDGET_HOLD_UNTIL="${verdict##* }"
      echo "retry-cron: ${BUDGET_HOLD_WINDOW} window exhausted, holding retries until ${BUDGET_HOLD_UNTIL} (poll ${age_text} old)"
      ;;
    missing\ *)
      echo "retry-cron: budget hold fail-open (${verdict#missing } window missing or unparseable, poll ${age_text} old), retrying as usual"
      ;;
    *)
      echo "retry-cron: no Claude window exhausted with a future reset (poll ${age_text} old), retrying as usual"
      ;;
  esac
  return 0
}

# budget_hold_active: 0 while the hold budget_hold_init found has not reset.
# No hold (or none read) is "not active", as an unknown reset is in
# is_reset_in_future.
budget_hold_active() {
  is_reset_in_future "${BUDGET_HOLD_UNTIL:-}"
}

# has_dispatch_guard <comments_json> <sha>
# Returns 0 when a dispatch guard for this SHA was posted within
# DISPATCH_GUARD_WINDOW_SEC seconds, indicating a concurrent caller already
# claimed dispatch for this PR and the current caller should skip.
has_dispatch_guard() {
  local comments_json="$1" sha="$2" now_epoch window
  now_epoch=$(get_now_epoch)
  window="${DISPATCH_GUARD_WINDOW_SEC:-600}"
  [[ "$window" =~ ^[0-9]+$ ]] || window=600
  # ANY matching guard counts (not just the first), and only one dated inside
  # [now - window, now]: a far-future `at=` must never hold retries off (#2046).
  echo "$comments_json" | jq -e \
    --arg pat "${DISPATCH_GUARD_PREFIX}${sha}" --argjson now "$now_epoch" --argjson win "$window" '
    [ .[] | strings | select(test($pat))
      | (capture("at=(?<t>[0-9T:Z-]+)")? | .t | try fromdateiso8601 catch null)
      | select(. != null) | ($now - .) | select(. >= 0 and . < $win) ]
    | length > 0' >/dev/null 2>&1
}

# post_dispatch_guard <repo> <pr_number> <sha>
# Posts a deduplication guard comment before dispatching. Skipped in DRY_RUN
# so tests stay clean; best-effort (failure is non-fatal).
post_dispatch_guard() {
  local repo="$1" pr_number="$2" sha="$3" now_iso
  [ "${DRY_RUN:-false}" = "true" ] && return 0
  now_iso="${NOW_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  local body="${DISPATCH_GUARD_PREFIX}${sha} at=${now_iso} -->"
  gh api --method POST "repos/${repo}/issues/${pr_number}/comments" \
    -f body="$body" >/dev/null 2>&1 || true
}

# lookup_check_run_details <repo> <head_sha> <check_name>
# Returns JSON {id, details_url} for the most recent failed check matching
# check_name on head_sha, so the retry dispatch has full failure context.
lookup_check_run_details() {
  local repo="$1" head_sha="$2" check_name="$3"
  gh api "repos/${repo}/commits/${head_sha}/check-runs?per_page=100" \
    --jq --arg name "$check_name" \
    '.check_runs
     | map(select(.name == $name and .conclusion == "failure"))
     | sort_by(.completed_at)
     | last
     | {id: (.id // ""), details_url: (.details_url // "")}' \
    2>/dev/null || echo '{"id":"","details_url":""}'
}

# dispatch_ci_retry <repo> <pr_number> <head_sha> <check_name>
# All logging goes to stderr so the function's stdout (empty) stays clean
# when called from within a command substitution.
dispatch_ci_retry() {
  local repo="$1" pr_number="$2" head_sha="$3" check_name="${4:-CI failure}"
  echo "  -> dispatch ci-retry: repo=${repo} pr=${pr_number} sha=${head_sha:0:8} check=${check_name}" >&2
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would dispatch dev-lead-ci-failure for PR ${pr_number} in ${repo}" >&2
    return 0
  fi

  # Look up the current check run to provide full failure context (details_url,
  # check run id) so fix-ci.sh can fetch logs and annotations for the retry.
  local run_details check_run_id details_url
  run_details=$(lookup_check_run_details "$repo" "$head_sha" "$check_name")
  check_run_id=$(echo "$run_details" | jq -r '.id // ""')
  details_url=$(echo "$run_details"  | jq -r '.details_url // ""')

  local payload
  payload=$(jq -n \
    --argjson pr_number "$pr_number" \
    --arg head_sha "$head_sha" \
    --arg repo "$repo" \
    --arg name "$check_name" \
    --arg details_url "$details_url" \
    --argjson check_run_id "$([ -n "$check_run_id" ] && echo "$check_run_id" || echo 'null')" \
    '{
      event_type: "dev-lead-ci-failure",
      client_payload: {
        pr_number: $pr_number,
        head_sha: $head_sha,
        repo: $repo,
        checks: [{name: $name, conclusion: "failure", details_url: $details_url,
                  app_slug: "github-actions", id: $check_run_id}]
      }
    }')
  # The target's pinned parser must read every field sent (#2086).
  dcg_payload_allowed "$repo" "$payload" || return 1
  if ! echo "$payload" | gh api --method POST "repos/${repo}/dispatches" --input - >/dev/null 2>&1; then
    echo "  [warn] dispatch failed for PR ${pr_number} in ${repo}" >&2
    return 1
  fi
}

# dispatch_reviews_retry <repo> <pr_number> <head_sha> <intent_type>
# All logging goes to stderr (same reason as dispatch_ci_retry above).
dispatch_reviews_retry() {
  local repo="$1" pr_number="$2" head_sha="$3" intent_type="$4"
  echo "  -> dispatch reviews-retry: repo=${repo} pr=${pr_number} sha=${head_sha:0:8} intent=${intent_type}" >&2
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would dispatch dev-lead-reviews-retry for PR ${pr_number} in ${repo} intent=${intent_type}" >&2
    return 0
  fi
  local payload
  payload=$(jq -n \
    --argjson pr_number "$pr_number" \
    --arg head_sha "$head_sha" \
    --arg repo "$repo" \
    --arg intent_type "$intent_type" \
    '{
      event_type: "dev-lead-reviews-retry",
      client_payload: {
        pr_number: $pr_number,
        head_sha: $head_sha,
        repo: $repo,
        intent_type: $intent_type
      }
    }')
  # The target's pinned parser must read every field sent (#2086).
  dcg_payload_allowed "$repo" "$payload" || return 1
  if ! echo "$payload" | gh api --method POST "repos/${repo}/dispatches" --input - >/dev/null 2>&1; then
    echo "  [warn] dispatch failed for PR ${pr_number} in ${repo}" >&2
    return 1
  fi
}

# dispatch_issue_retry <repo> <issue_number> <attempt>
# Re-dispatches a failed initial issue implementation (#781). The reusable
# workflow's intent classifier (dev-lead-intent.sh) recognises the
# dev-lead-issue-retry type and routes it back to the `issue` intent.
# All logging goes to stderr (same reason as dispatch_ci_retry above).
dispatch_issue_retry() {
  local repo="$1" issue_number="$2" attempt="$3"
  echo "  -> dispatch issue-retry: repo=${repo} issue=${issue_number} attempt=${attempt}" >&2
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would dispatch dev-lead-issue-retry for issue ${issue_number} in ${repo} attempt=${attempt}" >&2
    return 0
  fi
  local payload
  payload=$(jq -n \
    --argjson issue_number "$issue_number" \
    --arg repo "$repo" \
    --argjson attempt "$attempt" \
    '{
      event_type: "dev-lead-issue-retry",
      client_payload: {
        issue_number: $issue_number,
        repo: $repo,
        attempt: $attempt
      }
    }')
  # The target's pinned parser must read every field sent (#2086).
  dcg_payload_allowed "$repo" "$payload" || return 1
  if ! echo "$payload" | gh api --method POST "repos/${repo}/dispatches" --input - >/dev/null 2>&1; then
    echo "  [warn] dispatch failed for issue ${issue_number} in ${repo}" >&2
  fi
}

# fetch_pr_comment_nodes <repo> <pr_number>
#   Echo a JSON array of the PR's issue-comment nodes with the fields the #2008
#   stale-disposition check needs, including lastEditedAt, which the REST comments
#   API does not expose. Paginated GraphQL. Echoes nothing on any API failure, so
#   the caller never dispatches on a guess.
fetch_pr_comment_nodes() {
  local repo="$1" pr_number="$2" page nodes all="[]" has_next="true" cursor="" pages=0
  local -a cursor_args=()
  # shellcheck disable=SC2016  # GraphQL variables, not shell
  local q='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$pr){comments(first:100,after:$cursor){pageInfo{hasNextPage endCursor} nodes{id author{login __typename} authorAssociation body createdAt isMinimized minimizedReason lastEditedAt}}}}}'
  while [ "$has_next" = "true" ]; do
    pages=$((pages + 1))
    [ "$pages" -le 50 ] || return 0
    page=$(gh api graphql -f query="$q" -F owner="${repo%%/*}" -F repo="${repo##*/}" \
      -F pr="$pr_number" "${cursor_args[@]}" 2>/dev/null) || return 0
    nodes=$(jq -c '.data.repository.pullRequest.comments.nodes // empty' <<< "$page" 2>/dev/null) || return 0
    [ -n "$nodes" ] || return 0
    all=$(jq -cn --argjson a "$all" --argjson b "$nodes" '$a + $b' 2>/dev/null) || return 0
    has_next=$(jq -r '.data.repository.pullRequest.comments.pageInfo.hasNextPage // false' <<< "$page" 2>/dev/null || echo false)
    cursor=$(jq -r '.data.repository.pullRequest.comments.pageInfo.endCursor // ""' <<< "$page" 2>/dev/null || echo "")
    [ -n "$cursor" ] || has_next="false"
    cursor_args=(-f "cursor=${cursor}")
  done
  printf '%s' "$all"
}

# stale_disposition_needs_dispatch <comment_nodes_json> <pr_number>
#   0 when a fix-reviews pass should be dispatched for the #2008 edit re-open:
#   some bot comment was edited strictly after its latest dev-lead disposition
#   (maintainer_gate_stale_dispositions), AND no successful fix-reviews run marker
#   for THIS PR (`<!-- dev-lead-fix-reviews pr=<N> … intent=fix-reviews
#   status=applied|no-changes`) was posted at/after the latest such edit. The
#   marker check is the dedup. A pass that already ran after the edit saw the
#   current body, so a burst of CodeRabbit progress edits costs one run, not one per
#   edit. A pass counts from when it STARTED (the marker's read_at=, a lower bound
#   on when it read the comments), not when its marker was posted: a pass that
#   began before the edit and finished after it never saw the edited body. A
#   legacy marker without read_at= falls back to its createdAt.
#   A failed pass does not count, so its comment is retried. Only a marker
#   from a trusted author (OWNER/MEMBER/COLLABORATOR, as dev-lead's own markers
#   are) counts, so an outside commenter pasting a success-shaped marker cannot
#   suppress the re-dispatch. 1 otherwise, including unreadable input (never
#   dispatch on a guess). Pure apart from reading the reviewer registry.
stale_disposition_needs_dispatch() {
  local nodes="$1" pr_number="$2" stale latest_edit later_runs
  [[ "$pr_number" =~ ^[0-9]+$ ]] || return 1
  stale=$(maintainer_gate_stale_dispositions "$nodes" "${BOT_USER:-donpetry-bot}") || return 1
  latest_edit=$(jq -r 'map(.lastEditedAt) | max // ""' <<< "$stale" 2>/dev/null) || return 1
  [ -n "$latest_edit" ] || return 1
  later_runs=$(jq -r --arg e "$latest_edit" \
    --arg re "<!-- dev-lead-fix-reviews pr=${pr_number} [^>]*intent=fix-reviews status=(applied|no-changes)" '
      [ .[] | objects
        | select((.authorAssociation // "") as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a) != null)
        | select((.body // "") | test($re))
        | (.createdAt // "") as $posted
        | ([(.body // "") | capture("read_at=(?<r>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)") | .r] | first // $posted) as $seen
        | select($seen >= $e) ] | length' <<< "$nodes" 2>/dev/null) || return 1
  [ "$later_runs" = "0" ]
}

# scan_pr_for_rate_limits <repo> <pr_number>
# Checks the PR's comments for rate-limited markers and dispatches retries.
# Prints only a single integer (retries dispatched) to stdout; all other
# output goes to stderr so callers can safely capture the count.
scan_pr_for_rate_limits() {
  local repo="$1" pr_number="$2"

  # Fetch the PR object once — we need both its HEAD SHA and its labels.
  local pr_obj
  pr_obj=$(gh api "repos/${repo}/pulls/${pr_number}" 2>/dev/null || echo '{}')

  local head_sha
  head_sha=$(jq -r '.head?.sha // empty' <<< "$pr_obj" 2>/dev/null || true)
  if [ -z "$head_sha" ]; then
    echo "  [warn] could not resolve HEAD SHA for PR ${pr_number} in ${repo} — skipping" >&2
    echo "0"
    return 0
  fi

  # Guard against dispatching on closed or merged PRs. A review or check event
  # can race with a PR close/merge, leaving a historical rate-limited marker
  # still eligible — we must not re-dispatch work for a non-open PR.
  local pr_state
  pr_state=$(jq -r '.state // empty' <<< "$pr_obj" 2>/dev/null || true)
  if [ "$pr_state" != "open" ]; then
    echo "  [skip] PR ${pr_number} in ${repo} is ${pr_state:-unknown} — not re-dispatching closed/merged PR" >&2
    echo "0"
    return 0
  fi

  # Stop-condition-before-acting (§6.2.1 timer contract). This safety-net cron and
  # the event-first resume bridge (scripts/dev-lead-resume.sh) share ONE gate,
  # pr_resume_suppressed, so the timer can never re-dispatch work the event path
  # would not (#1407 AC #3). It suppresses a PR that is human-gated
  # (needs-human-review, #946) OR that has exhausted its per-PR automation budget
  # (#926) — re-dispatching either would re-ignite the #860 "amplifier". We reuse
  # the already-fetched labels to avoid a redundant PR fetch.
  local labels_json
  labels_json=$(jq -c '[.labels[]?.name]' <<< "$pr_obj" 2>/dev/null || echo 'null')
  if pr_resume_suppressed "$pr_number" "$repo" "$labels_json"; then
    echo "0"
    return 0
  fi

  # Fetch all comment bodies, paginating to ensure we don't miss markers on busy PRs
  local comments_json
  comments_json=$(gh api --paginate "repos/${repo}/issues/${pr_number}/comments?per_page=100" \
    --jq '[.[].body]' 2>/dev/null | jq -s 'add // []' || echo "[]")

  # Deduplication guard: if a concurrent resume path already claimed dispatch
  # for this SHA, skip to prevent duplicate repository_dispatch calls (#1407).
  if has_dispatch_guard "$comments_json" "$head_sha"; then
    echo "  [skip] PR ${pr_number} SHA ${head_sha:0:8} has a recent dispatch guard — skipping to avoid duplicate" >&2
    echo "0"
    return 0
  fi
  local guard_posted=0

  local dispatched=0
  # Set when a rate-limit hold has not reset yet. A pass dispatched now would hit
  # the same limit, so the #2008 edit re-dispatch below waits for the reset too.
  local held=0

  # ── Check for fix-ci rate-limited marker on current HEAD SHA ──────────────
  local ci_pattern="${CI_MARKER_PREFIX}${head_sha} status=rate-limited"
  if echo "$comments_json" | jq -e --arg pat "$ci_pattern" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
    # Extract reset time from the marker (format: reset=<ISO>)
    local reset_time
    reset_time=$(echo "$comments_json" | jq -r \
      --arg pat "$ci_pattern" \
      '[.[] | select(. | test($pat))] | .[0] | capture("reset=(?<r>[0-9T:Z-]+)") | .r // ""' \
      2>/dev/null || true)

    if is_reset_in_future "$reset_time"; then
      echo "  [skip] fix-ci rate-limit for PR ${pr_number} not yet cleared (resets ${reset_time})" >&2
      held=1
    elif budget_hold_active; then
      echo "  [skip] fix-ci rate-limit for PR ${pr_number} held by the budget poller until ${BUDGET_HOLD_UNTIL}" >&2
      held=1
    else
      # Skip if a terminal marker was already posted for this SHA (prior retry succeeded)
      local terminal_pattern="${CI_MARKER_PREFIX}${head_sha} status=(applied|failed|no-changes)"
      if echo "$comments_json" | jq -e --arg pat "$terminal_pattern" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
        echo "  [skip] fix-ci already has terminal result for PR ${pr_number} SHA ${head_sha:0:8}" >&2
      else
        local check_name="CI failure"
        check_name=$(echo "$comments_json" | jq -r \
          --arg pat "$ci_pattern" \
          '[.[] | select(. | test($pat))] | .[0] | capture("check=(?<c>[^\\s\"<>]+)") | .c // "CI failure"' \
          2>/dev/null || echo "CI failure")
        if [ "$guard_posted" -eq 0 ]; then
          post_dispatch_guard "$repo" "$pr_number" "$head_sha"
          guard_posted=1
        fi
        # Count only a dispatch that was accepted: the caller gives a PR with no
        # dispatch this scan to the bot-comment retry (#2017), so a failed call must
        # not read as "this PR's one dispatch is used".
        if dispatch_ci_retry "$repo" "$pr_number" "$head_sha" "$check_name"; then
          dispatched=$(( dispatched + 1 ))
        fi
      fi
    fi
  fi

  # ── Check for retryable fix-reviews hold markers on HEAD SHA ───────────────
  # Only intents that can reconstruct their full context from the PR at retry
  # time. on-mention is excluded: its USER_INSTRUCTION cannot be recovered from
  # the PR's current state. fix-bot-comment is retried per comment (by node id)
  # by scan_pr_for_undispositioned_bot_comments instead (#2017).
  # Both hold tokens are retryable (#1568): status=rate-limited (genuine quota) and
  # status=blocked (non-quota PR blockers). Matching both keeps re-dispatch behaviour
  # unchanged and leaves pre-#1568 status=rate-limited blocked markers parseable.
  for intent_type in $RETRYABLE_REVIEW_INTENTS; do
    local reviews_pattern="${REVIEWS_MARKER_PREFIX}${pr_number} sha=${head_sha} intent=${intent_type} status=(rate-limited|blocked|history-unavailable|partial)"
    if echo "$comments_json" | jq -e --arg pat "$reviews_pattern" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
      local reset_time
      reset_time=$(echo "$comments_json" | jq -r \
        --arg pat "$reviews_pattern" \
        '[.[] | select(. | test($pat))] | .[0] | capture("reset=(?<r>[0-9T:Z-]+)") | .r // ""' \
        2>/dev/null || true)

      if is_reset_in_future "$reset_time"; then
        echo "  [skip] ${intent_type} rate-limit for PR ${pr_number} not yet cleared (resets ${reset_time})" >&2
        held=1
        continue
      fi

      # Budget hold (#2139): only when the newest hold marker is a quota one.
      local hold_status
      hold_status=$(jq -r --arg pat "$reviews_pattern" \
        '[.[] | select(test($pat))] | last | capture("status=(?<s>[a-z-]+)") | .s // ""' \
        <<< "$comments_json" 2>/dev/null || true)
      if [ "$hold_status" = "rate-limited" ] && budget_hold_active; then
        echo "  [skip] ${intent_type} rate-limit for PR ${pr_number} held by the budget poller until ${BUDGET_HOLD_UNTIL}" >&2
        held=1
        continue
      fi

      # Bound infrastructure-failure retries: a remote that cannot be deepened
      # posts a history-unavailable marker per run, with no reset time. After
      # HISTORY_UNAVAILABLE_MAX_RETRIES markers on this SHA, hold instead of
      # dispatching again. These runs are separate from rebase-conflict
      # exhaustion; a new head SHA starts a fresh count.
      local history_count
      history_count=$(echo "$comments_json" | jq -r --arg hpat "${REVIEWS_MARKER_PREFIX}${pr_number} sha=${head_sha} intent=${intent_type} status=history-unavailable" \
        '[.[] | select(test($hpat))] | length' 2>/dev/null || echo 0)
      if [[ "$history_count" =~ ^[0-9]+$ ]] && [ "$history_count" -ge "$HISTORY_UNAVAILABLE_MAX_RETRIES" ]; then
        echo "  [skip] ${intent_type} history-unavailable ${history_count}x for PR ${pr_number} SHA ${head_sha:0:8} — holding (infrastructure failure, retry limit ${HISTORY_UNAVAILABLE_MAX_RETRIES})" >&2
        continue
      fi

      # Normalize legacy intent aliases to their canonical names before checking
      # terminal markers and dispatching. "human-pr" was renamed to "review-changes";
      # dev-lead-intent.sh rewrites human-pr → review-changes, so the retried run
      # posts terminal markers as intent=review-changes, not intent=human-pr.
      # Without normalization here the terminal check never matches and the same
      # SHA is re-dispatched on every cron cycle indefinitely.
      local dispatch_intent="${intent_type}"
      [ "$dispatch_intent" = "human-pr" ] && dispatch_intent="review-changes"

      # Skip if a terminal marker was already posted (prior retry ran to completion)
      # Check this BEFORE the partial count so a newer terminal marker prevents
      # hold/escalation, even if there are partial markers after an older terminal.
      local reviews_terminal="${REVIEWS_MARKER_PREFIX}${pr_number} sha=${head_sha} intent=${dispatch_intent} status=(applied|no-changes|failed|unrelated-histories)"
      # A terminal marker older than a later status=history-unavailable or
      # status=partial marker is stale (the pass failed, or could not re-open a
      # comment, after it), so it must not mask the retry. Comments are
      # chronological; compare positions.
      local history_pattern="${REVIEWS_MARKER_PREFIX}${pr_number} sha=${head_sha} intent=${dispatch_intent} status=history-unavailable"
      local partial_pattern="${REVIEWS_MARKER_PREFIX}${pr_number} sha=${head_sha} intent=${dispatch_intent} status=partial"
      if echo "$comments_json" | jq -e --arg pat "$reviews_terminal" --arg hpat "$history_pattern" --arg ppat "$partial_pattern" '
          to_entries as $e
          | ([$e[] | select(.value | test($pat)) | .key] | max) as $t
          | ([$e[] | select(.value | test($hpat)) | .key] | max) as $h
          | ([$e[] | select(.value | test($ppat)) | .key] | max) as $p
          | $t != null and ($h == null or $h < $t) and ($p == null or $p < $t)' >/dev/null 2>&1; then
        echo "  [skip] ${intent_type} already has terminal result for PR ${pr_number} SHA ${head_sha:0:8}" >&2
        continue
      fi

      # Bound persistent partial results (a comment that cannot be re-opened posts
      # a partial marker every pass): hold after PARTIAL_MAX_RETRIES on this SHA
      # instead of re-running the engine. A new head SHA starts a fresh count.
      local done_pattern="${REVIEWS_MARKER_PREFIX}${pr_number} sha=${head_sha} intent=${dispatch_intent} status=(applied|no-changes)"
      local partial_count
      # Only count partial markers positioned after the latest completed marker,
      # so a completed pass (e.g. human-triggered) resets the retry budget.
      partial_count=$(echo "$comments_json" | jq -r \
        --arg ppat "$partial_pattern" --arg tpat "$done_pattern" \
        'to_entries as $e
         | ([$e[] | select(.value | test($tpat)) | .key] | max // -1) as $t
         | [$e[] | select(.key > $t and (.value | test($ppat)))] | length' 2>/dev/null || echo 0)
      if [[ "$partial_count" =~ ^[0-9]+$ ]] && [ "$partial_count" -ge "$PARTIAL_MAX_RETRIES" ]; then
        echo "::warning::${intent_type} partial ${partial_count}x for PR ${pr_number} SHA ${head_sha:0:8} — holding for a human (persistent failure, retry limit ${PARTIAL_MAX_RETRIES})" >&2
        # Hold the PR for the rest of the scan so the #2008 stale-disposition
        # dispatch below cannot re-run the engine, and escalate to a human.
        held=1
        pr_automation_escalate "$pr_number" "$repo" >&2 || true
        continue
      fi

      if [ "$guard_posted" -eq 0 ]; then
        post_dispatch_guard "$repo" "$pr_number" "$head_sha"
        guard_posted=1
      fi
      if dispatch_reviews_retry "$repo" "$pr_number" "$head_sha" "$dispatch_intent"; then
        dispatched=$(( dispatched + 1 ))
      fi
    fi
  done

  # ── #2008: a bot comment edited after its dev-lead disposition ─────────────
  # dev-lead never sees comment edits, so re-dispatch a fix-reviews pass to
  # re-disposition the current body. This runs only when nothing else was
  # dispatched (that pass would see the edit too) and no rate-limit hold is still
  # active, and is deduplicated against fix-reviews runs that already ran after
  # the edit.
  if [ "$dispatched" -eq 0 ] && [ "$held" -eq 0 ]; then
    local comment_nodes
    comment_nodes=$(fetch_pr_comment_nodes "$repo" "$pr_number")
    if [ -n "$comment_nodes" ] && stale_disposition_needs_dispatch "$comment_nodes" "$pr_number"; then
      echo "  [stale-disposition] PR ${pr_number}: a bot comment was edited after its dev-lead disposition — re-dispatching fix-reviews (#2008)" >&2
      if [ "$guard_posted" -eq 0 ]; then
        post_dispatch_guard "$repo" "$pr_number" "$head_sha"
        guard_posted=1
      fi
      dispatch_reviews_retry "$repo" "$pr_number" "$head_sha" "fix-reviews"
      dispatched=$(( dispatched + 1 ))
    fi
  fi

  echo "$dispatched"
}

# withdraw_bot_comment_retry_marker <repo> <marker_id>
# Deletes a retry marker this scan posted but did not dispatch over. Best effort:
# a marker left behind reads as a pending retry and holds the comment for the
# BOT_COMMENT_RETRY_PENDING_SEC window, so a failed delete surfaces as a warning.
withdraw_bot_comment_retry_marker() {
  local repo="$1" marker_id="$2"
  [ -n "$marker_id" ] || return 0
  if ! gh api -X DELETE "repos/${repo}/issues/comments/${marker_id}" >/dev/null 2>&1; then
    echo "  ::warning::bot-comment retry: could not withdraw retry marker ${marker_id} in ${repo} — it holds the comment as retry-pending until BOT_COMMENT_RETRY_PENDING_SEC passes" >&2
  fi
}

# The client_payload keys dispatch_bot_comment_retry sends, so the scan can check
# the target reads them (#2086) BEFORE it posts a retry marker. Keep in step with
# the payload below (tests/dev-lead/unit/test_dispatch_channel_gate.bats checks).
BOT_COMMENT_RETRY_FIELDS=(pr_number head_sha repo intent_type comment_node_id)

# dispatch_bot_comment_retry <repo> <pr_number> <head_sha> <comment_node_id>
# Re-dispatches a fix-bot-comment pass for ONE bot comment (#2017). Reuses the
# dev-lead-reviews-retry type every caller stub already subscribes to, so no stub
# change is needed. The payload carries only the comment's node id — never its
# body — so the pass re-reads the comment's current body by id.
# All logging goes to stderr (same reason as dispatch_ci_retry above).
dispatch_bot_comment_retry() {
  local repo="$1" pr_number="$2" head_sha="$3" comment_node_id="$4"
  echo "  -> dispatch bot-comment-retry: repo=${repo} pr=${pr_number} comment=${comment_node_id}" >&2
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would dispatch dev-lead-reviews-retry for PR ${pr_number} in ${repo} intent=fix-bot-comment comment=${comment_node_id}" >&2
    return 0
  fi
  local payload
  payload=$(jq -n \
    --argjson pr_number "$pr_number" \
    --arg head_sha "$head_sha" \
    --arg repo "$repo" \
    --arg comment_node_id "$comment_node_id" \
    '{
      event_type: "dev-lead-reviews-retry",
      client_payload: {
        pr_number: $pr_number,
        head_sha: $head_sha,
        repo: $repo,
        intent_type: "fix-bot-comment",
        comment_node_id: $comment_node_id
      }
    }')
  # The target's pinned parser must read every field sent (#2086).
  dcg_payload_allowed "$repo" "$payload" || return 1
  if ! echo "$payload" | gh api --method POST "repos/${repo}/dispatches" --input - >/dev/null 2>&1; then
    echo "  [warn] dispatch failed for PR ${pr_number} in ${repo}" >&2
    return 1
  fi
}

# dev_lead_identity: dev-lead's acting login, from its persona manifest — NOT
# BOT_USER, which is pr-review's identity when pr-review calls this scan (#2017).
# DEV_LEAD_USER overrides; don-petry is the same fail-safe default the dev-lead
# workflow uses.
dev_lead_identity() {
  if [ -z "${DEV_LEAD_USER:-}" ]; then
    DEV_LEAD_USER=$(bash "$SCRIPT_DIR/lib/resolve-persona-identity.sh" dev-lead \
      "$SCRIPT_DIR/../personas" account 2>/dev/null || true)
    DEV_LEAD_USER="${DEV_LEAD_USER:-don-petry}"
  fi
  printf '%s' "$DEV_LEAD_USER"
}

# pr_review_identity: pr-review's acting login (it posts this scan's retry markers
# when its gate verdict runs the scan, #2017). PR_REVIEW_USER overrides;
# donpetry-bot is the pr-review workflow's own fallback.
pr_review_identity() {
  if [ -z "${PR_REVIEW_USER:-}" ]; then
    PR_REVIEW_USER=$(bash "$SCRIPT_DIR/lib/resolve-persona-identity.sh" pr-review \
      "$SCRIPT_DIR/../personas" account 2>/dev/null || true)
    PR_REVIEW_USER="${PR_REVIEW_USER:-donpetry-bot}"
  fi
  printf '%s' "$PR_REVIEW_USER"
}

# bcr_automation_logins: the comma-separated logins whose markers the bot-comment
# retry trusts — only our own automation. Each must be a plain GitHub login
# (it is also spliced into a --jq filter); anything else is dropped.
bcr_automation_logins() {
  local l out=""
  for l in "$(dev_lead_identity)" "$(pr_review_identity)"; do
    [[ "$l" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$ ]] || continue
    out="${out:+${out},}${l}"
  done
  printf '%s' "$out"
}

# scan_pr_for_undispositioned_bot_comments <repo> <pr_number>
# Finds registered reviewer-bot issue comments on an open dev-lead PR that have
# no covering disposition and are not cleared by info_status_pattern, and
# dispatches a fix-bot-comment retry for the OLDEST one (#2017). At most one
# dispatch per PR per scan: every retry lands in the same per-PR concurrency lane,
# where a second dispatch would supersede the first while it is still pending —
# the exact loss this scan exists to recover. Remaining comments are picked up on
# later scans. Dedup (pending / completed / edited / attempt cap) lives in the
# pure bcr_retry_decisions. Prints only the number of dispatches to stdout; all
# other output goes to stderr. Fails closed (0 dispatches) on any read failure.
# It never minimizes anything: the pass posts a disposition, which the harness
# verifies as usual.
scan_pr_for_undispositioned_bot_comments() {
  local repo="$1" pr_number="$2"

  local pr_obj
  pr_obj=$(gh api "repos/${repo}/pulls/${pr_number}" 2>/dev/null || echo '{}')
  local pr_state head_sha head_repo pr_author
  pr_state=$(jq -r '.state // empty' <<< "$pr_obj" 2>/dev/null || true)
  head_sha=$(jq -r '.head?.sha // empty' <<< "$pr_obj" 2>/dev/null || true)
  head_repo=$(jq -r '.head?.repo?.full_name // empty' <<< "$pr_obj" 2>/dev/null || true)
  pr_author=$(jq -r '.user?.login // empty' <<< "$pr_obj" 2>/dev/null || true)
  if [ "$pr_state" != "open" ]; then
    echo "  [skip] bot-comment retry: PR ${pr_number} in ${repo} is ${pr_state:-unknown}" >&2
    echo "0"; return 0
  fi
  # Authorship gate (#1311), mirrored from dev-lead-intent.sh (which re-checks it
  # on the retried event): fix-bot-comment only acts on PRs dev-lead authored.
  # Ownership is the PR's AUTHOR plus a same-repository head — never the branch
  # name, which any contributor can choose (a fork's `dev-lead/issue-*` branch
  # must not buy write-capable automation).
  if [ -z "$pr_author" ] || [ "$pr_author" != "$(dev_lead_identity)" ] \
     || [ "$head_repo" != "$repo" ]; then
    echo "0"; return 0
  fi
  local labels_json
  labels_json=$(jq -c '[.labels[]?.name]' <<< "$pr_obj" 2>/dev/null || echo 'null')
  if pr_resume_suppressed "$pr_number" "$repo" "$labels_json"; then
    echo "0"; return 0
  fi

  local comments
  if ! comments=$(bcr_fetch_pr_comments "$repo" "$pr_number"); then
    echo "  [warn] bot-comment retry: could not read PR ${pr_number} comments in ${repo} — skipping (fail closed)" >&2
    echo "0"; return 0
  fi
  # A run another path queued moments ago for this head (dev-lead-resume.sh or the
  # rate-limit sweep posts the guard first) is still pending in the per-PR lane; a
  # second dispatch now would supersede it (#2046). Defer to it.
  # Only a guard our own automation posted counts, so a PR commenter cannot pause it.
  if has_dispatch_guard "$(jq -c --arg a "$(bcr_automation_logins)" '
        ($a | split(",") | map(sub("\\[bot\\]$"; ""))) as $L
        | [ .[] | objects | select(((.author.login // "") | sub("\\[bot\\]$"; "")) as $l | $L | index($l) != null)
            | .body // empty ]' <<< "$comments" 2>/dev/null || echo '[]')" "$head_sha"; then
    echo "  [skip] bot-comment retry: PR ${pr_number} SHA ${head_sha:0:8} has a recent dispatch guard — not superseding it" >&2
    echo "0"; return 0
  fi

  local trusted="${TRUSTED_BOTS:-}"
  if [ -z "$trusted" ]; then
    trusted=$( (
      # shellcheck source=lib/reviewer-sources.sh
      source "$SCRIPT_DIR/lib/reviewer-sources.sh" && reviewer_sources_trusted_bots_csv
    ) 2>/dev/null || true)
  fi
  if [ -z "$trusted" ]; then
    echo "  [warn] bot-comment retry: no trusted reviewer bots resolved — skipping" >&2
    echo "0"; return 0
  fi

  local automation
  automation=$(bcr_automation_logins)
  local decisions
  if ! decisions=$(bcr_retry_decisions "$comments" "$trusted" \
       "$(_maintainer_gate_info_patterns_json)" "$(get_now_epoch)" "$automation"); then
    echo "  [warn] bot-comment retry: could not evaluate PR ${pr_number} comments — skipping (fail closed)" >&2
    echo "0"; return 0
  fi

  if ! jq -r --arg pr "$pr_number" '.[] | select(.decision == "skip")
         | "  [skip] bot-comment \(.id) (\(.login)) on PR \($pr): \(.reason)"' \
       <<< "$decisions" >&2; then
    echo "  [warn] bot-comment retry: could not render skip decisions for PR ${pr_number}" >&2
  fi

  local pick cid version attempt now_iso
  pick=$(jq -c 'first(.[] | select(.decision == "dispatch")) // empty' <<< "$decisions")
  if [ -z "$pick" ]; then
    echo "0"; return 0
  fi
  cid=$(jq -r '.id' <<< "$pick")
  version=$(jq -r '.version' <<< "$pick")
  attempt=$(jq -r '.attempt' <<< "$pick")
  # These are spliced into the marker body and the claim's --jq filter below.
  if [[ ! "$cid" =~ ^[-A-Za-z0-9_+/=]+$ ]] || [[ ! "$attempt" =~ ^[0-9]+$ ]] \
     || [[ ! "$version" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]]; then
    echo "  [warn] bot-comment retry: unexpected comment id/version/attempt on PR ${pr_number} — not dispatching" >&2
    echo "0"; return 0
  fi
  now_iso="${NOW_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  echo "  [retry] bot-comment ${cid} ($(jq -r '.login' <<< "$pick")) on PR ${pr_number}: undispositioned → fix-bot-comment attempt ${attempt}" >&2

  # A target pinned to a parser that drops comment_node_id would fail the run
  # (#2050); hold before the marker, which would block the comment for the whole
  # pending window (#2086).
  if ! dcg_target_reads "$repo" "${BOT_COMMENT_RETRY_FIELDS[@]}"; then
    echo "0"; return 0
  fi

  # Record the attempt BEFORE dispatching so a concurrent caller (the cron and
  # pr-review's gate verdict) sees it as pending and does not duplicate it.
  local marker_id=""
  if [ "$DRY_RUN" != "true" ]; then
    if ! marker_id=$(gh api --method POST "repos/${repo}/issues/${pr_number}/comments" \
         -f body="$(bcr_retry_marker "$cid" "$version" "$attempt" "$now_iso")" \
         --jq '.id // empty' 2>/dev/null); then
      echo "  [warn] bot-comment retry: could not record the retry marker on PR ${pr_number} — not dispatching (dedup unavailable)" >&2
      echo "0"; return 0
    fi
    if [[ ! "$marker_id" =~ ^[0-9]+$ ]]; then
      # Posted, but its id is unreadable: it can be neither verified nor withdrawn.
      echo "  [warn] bot-comment retry: the retry marker's id on PR ${pr_number} is unreadable — not dispatching (fail closed)" >&2
      echo "0"; return 0
    fi
    # Two concurrent scans can both have seen no marker. Keep only the earliest
    # marker for this comment version AND attempt; the loser withdraws and does
    # not dispatch. Scoped to the attempt so a lost run's expired attempt-N marker
    # never wins against the attempt-N+1 retry that replaces it, and to markers
    # our own automation posted with a trusted association — exactly the markers
    # bcr_retry_decisions counts — so a commenter pasting matching text cannot
    # make every scan back off.
    #
    # This is a best-effort claim, not a lock: the listing is eventually
    # consistent, so the re-list waits BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC for a
    # concurrent scan's marker to become visible. If two scans still each see only
    # their own marker, both dispatch. The residual cost is bounded: the per-PR
    # lane does not cancel in progress, the second pass re-checks the comment's
    # disposition at run time, and both markers count toward the attempt limits.
    local marker_ids first_marker logins_jq
    # Compared without a `[bot]` suffix, as bcr_retry_decisions does (REST keeps
    # the suffix on an App login; GraphQL omits it).
    logins_jq=$(jq -cn --arg a "$automation" '$a | split(",") | map(sub("\\[bot\\]$"; ""))')
    if [ "$BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC" -gt 0 ]; then
      sleep "$BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC"
    fi
    if ! marker_ids=$(gh api --paginate "repos/${repo}/issues/${pr_number}/comments?per_page=100" \
      --jq '.[] | select((.user.login // "" | sub("\\[bot\\]$"; "")) as $l | '"${logins_jq}"' | index($l) != null)
            | select((.author_association // "") as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a) != null)
            | select((.body // "") | contains("dev-lead-bot-comment-retry id='"${cid}"' version='"${version}"' attempt='"${attempt}"' ")) | .id' \
      2>/dev/null); then
      echo "  [warn] bot-comment retry: could not re-read retry markers on PR ${pr_number} — withdrawing and not dispatching (fail closed)" >&2
      withdraw_bot_comment_retry_marker "$repo" "$marker_id"
      echo "0"; return 0
    fi
    first_marker=$(printf '%s\n' "$marker_ids" | grep -E '^[0-9]+$' | sort -n | head -n1 || true)
    if [ -z "$first_marker" ]; then
      # Our own marker is not among the trusted ones: this scan posts under an
      # identity (or association) bcr_retry_decisions does not count, so its
      # markers could never hold a retry pending or count an attempt — every scan
      # would dispatch again. Fail closed rather than dispatch without dedup.
      echo "  ::warning::bot-comment retry: the retry marker on PR ${pr_number} was posted by an identity the retry dedup does not trust (expected one of: ${automation}) — withdrawing and not dispatching" >&2
      withdraw_bot_comment_retry_marker "$repo" "$marker_id"
      echo "0"; return 0
    fi
    # A thread-retry marker posted concurrently shares the per-PR lane: the
    # earliest in-window one wins, so both kinds cannot each dispatch.
    local sib_pending sib_first sib_raw
    sib_pending="${BOT_THREAD_RETRY_PENDING_SEC:-9000}"
    [[ "$sib_pending" =~ ^[0-9]+$ ]] || sib_pending=9000
    if ! sib_raw=$(gh api --paginate "repos/${repo}/issues/${pr_number}/comments?per_page=100" \
      --jq '.[] | select((.user.login // "" | sub("\\[bot\\]$"; "")) as $l | '"${logins_jq}"' | index($l) != null)
            | select((.author_association // "") as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a) != null)
            | select((.body // "") | contains("<!-- dev-lead-bot-thread-retry threads="))
            | {id, created_at}' 2>/dev/null) \
      || ! sib_first=$(printf '%s\n' "$sib_raw" | jq -rs --argjson now "$(get_now_epoch)" --argjson pending "$sib_pending" '
        [ .[] | objects | select((.id | type) == "number")
          | select($now - ((.created_at // "") | (try fromdateiso8601 catch 0)) < $pending) | .id ]
        | min // empty' 2>/dev/null); then
      echo "  [warn] bot-comment retry: could not re-read thread retry markers on PR ${pr_number} — withdrawing and not dispatching (fail closed)" >&2
      withdraw_bot_comment_retry_marker "$repo" "$marker_id"
      echo "0"; return 0
    fi
    if [[ "$sib_first" =~ ^[0-9]+$ ]] && [ "$sib_first" -lt "$marker_id" ]; then
      echo "  [skip] bot-comment ${cid} on PR ${pr_number}: a concurrent thread retry already recorded a retry" >&2
      withdraw_bot_comment_retry_marker "$repo" "$marker_id"
      echo "0"; return 0
    fi
    if [ "$first_marker" != "$marker_id" ]; then
      echo "  [skip] bot-comment ${cid} on PR ${pr_number}: a concurrent scan already recorded a retry" >&2
      withdraw_bot_comment_retry_marker "$repo" "$marker_id"
      echo "0"; return 0
    fi
  fi
  if ! dispatch_bot_comment_retry "$repo" "$pr_number" "$head_sha" "$cid"; then
    # Nothing was dispatched, so withdraw the marker — left in place it would read
    # as a pending retry and block the next attempt for the whole pending window.
    withdraw_bot_comment_retry_marker "$repo" "$marker_id"
    echo "0"; return 0
  fi
  echo "1"
}

# post_bot_thread_exhausted_notice <repo> <pr_number> <decisions_json>
# Surfaces threads whose retries ran out (#2046). Without the notice the stall
# would be silent: the thread keeps blocking the merge and the sweep stops
# retrying it. Posts ONE comment naming every newly exhausted thread. Its hidden
# marker lists their ids, so a later scan never repeats the notice for them.
# Best effort.
post_bot_thread_exhausted_notice() {
  local repo="$1" pr_number="$2" decisions="$3" ids list body
  ids=$(jq -r '.exhausted_unnoticed | join(",")' <<< "$decisions" 2>/dev/null || true)
  [ -n "$ids" ] || return 0
  if [[ ! "$ids" =~ ^[-A-Za-z0-9_+/=,]+$ ]]; then
    echo "  [warn] bot-thread retry: unexpected thread ids on PR ${pr_number} — not posting the exhaustion notice" >&2
    return 0
  fi
  echo "  [exhausted] bot-thread retry on PR ${pr_number}: retries exhausted for ${ids} — posting notice" >&2
  [ "$DRY_RUN" = "true" ] && return 0
  list=$(jq -r '.exhausted_unnoticed as $n | .threads[] | select(.id as $i | $n | index($i) != null)
      | "- `\(.path // "?"):\(.line // "?")` (\(.login))"' <<< "$decisions" 2>/dev/null || true)
  body="**dev-lead: bot review threads still unprocessed after automatic retries**

dev-lead retried the fix-reviews pass for these trusted-bot review threads, but none of them received a dev-lead reply. Unresolved threads block the merge (\`required_review_thread_resolution\`), so a maintainer needs to address or resolve them, or @mention dev-lead to try again:

${list}

$(btr_exhausted_marker "$ids")"
  if ! gh api --method POST "repos/${repo}/issues/${pr_number}/comments" -f body="$body" >/dev/null 2>&1; then
    echo "  ::warning::bot-thread retry: could not post the exhaustion notice on PR ${pr_number} in ${repo}" >&2
  fi
}

# scan_pr_for_unreplied_bot_threads <repo> <pr_number>
# Finds unresolved, non-outdated review threads on an open dev-lead PR that a
# trusted reviewer bot opened and our automation never replied to. If any is past
# the grace period, it dispatches ONE fix-reviews retry for the PR (#2046). The
# pass enumerates every unresolved thread (open-review-threads.sh), so one
# dispatch covers them all. A second would supersede the first in the per-PR
# lane. Dedup (pending, rate limit, attempt caps) lives in the pure
# btr_retry_decisions. The claim marker is posted before the dispatch, so this
# cron and pr-review's gate hook never both dispatch. Threads that run out of
# attempts get one visible notice. Prints only the number of dispatches to
# stdout; all other output goes to stderr. Fails closed (0 dispatches) on any
# read failure. It never replies to or resolves a thread.
scan_pr_for_unreplied_bot_threads() {
  local repo="$1" pr_number="$2"

  local pr_obj
  pr_obj=$(gh api "repos/${repo}/pulls/${pr_number}" 2>/dev/null || echo '{}')
  local pr_state head_sha head_repo pr_author
  pr_state=$(jq -r '.state // empty' <<< "$pr_obj" 2>/dev/null || true)
  head_sha=$(jq -r '.head?.sha // empty' <<< "$pr_obj" 2>/dev/null || true)
  head_repo=$(jq -r '.head?.repo?.full_name // empty' <<< "$pr_obj" 2>/dev/null || true)
  pr_author=$(jq -r '.user?.login // empty' <<< "$pr_obj" 2>/dev/null || true)
  if [ "$pr_state" != "open" ]; then
    echo "  [skip] bot-thread retry: PR ${pr_number} in ${repo} is ${pr_state:-unknown}" >&2
    echo "0"; return 0
  fi
  if [ -z "$head_sha" ]; then
    echo "  [warn] bot-thread retry: could not resolve HEAD SHA for PR ${pr_number} in ${repo} — skipping" >&2
    echo "0"; return 0
  fi
  # Authorship gate (#1311), as in the bot-comment retry: fix-reviews only pushes
  # to PRs dev-lead authored, with a same-repository head.
  if [ -z "$pr_author" ] || [ "$pr_author" != "$(dev_lead_identity)" ] \
     || [ "$head_repo" != "$repo" ]; then
    echo "0"; return 0
  fi
  local labels_json
  labels_json=$(jq -c '[.labels[]?.name]' <<< "$pr_obj" 2>/dev/null || echo 'null')
  if pr_resume_suppressed "$pr_number" "$repo" "$labels_json"; then
    echo "0"; return 0
  fi

  local threads comments
  if ! threads=$(btr_fetch_pr_threads "$repo" "$pr_number"); then
    echo "  [warn] bot-thread retry: could not read PR ${pr_number} review threads in ${repo} — skipping (fail closed)" >&2
    echo "0"; return 0
  fi
  if ! comments=$(bcr_fetch_pr_comments "$repo" "$pr_number"); then
    echo "  [warn] bot-thread retry: could not read PR ${pr_number} comments in ${repo} — skipping (fail closed)" >&2
    echo "0"; return 0
  fi
  # A run another path queued moments ago for this head (dev-lead-resume.sh or the
  # rate-limit sweep posts the guard first) is still pending in the per-PR lane; a
  # second dispatch now would supersede it (#2046). Defer to it.
  # Only a guard our own automation posted counts, so a PR commenter cannot pause it.
  if has_dispatch_guard "$(jq -c --arg a "$(bcr_automation_logins)" '
        ($a | split(",") | map(sub("\\[bot\\]$"; ""))) as $L
        | [ .[] | objects | select(((.author.login // "") | sub("\\[bot\\]$"; "")) as $l | $L | index($l) != null)
            | .body // empty ]' <<< "$comments" 2>/dev/null || echo '[]')" "$head_sha"; then
    echo "  [skip] bot-thread retry: PR ${pr_number} SHA ${head_sha:0:8} has a recent dispatch guard — not superseding it" >&2
    echo "0"; return 0
  fi

  local trusted="${TRUSTED_BOTS:-}"
  if [ -z "$trusted" ]; then
    trusted=$( (
      # shellcheck source=lib/reviewer-sources.sh
      source "$SCRIPT_DIR/lib/reviewer-sources.sh" && reviewer_sources_trusted_bots_csv
    ) 2>/dev/null || true)
  fi
  if [ -z "$trusted" ]; then
    echo "  [warn] bot-thread retry: no trusted reviewer bots resolved — skipping" >&2
    echo "0"; return 0
  fi

  local automation decisions now_epoch
  automation=$(bcr_automation_logins)
  now_epoch=$(get_now_epoch)
  if ! decisions=$(btr_retry_decisions "$threads" "$comments" "$trusted" "$now_epoch" "$automation"); then
    echo "  [warn] bot-thread retry: could not evaluate PR ${pr_number} review threads — skipping (fail closed)" >&2
    echo "0"; return 0
  fi

  if ! jq -r --arg pr "$pr_number" '.threads[] | select(.decision == "skip")
         | "  [skip] bot-thread \(.id) (\(.login)) on PR \($pr): \(.reason)"' \
       <<< "$decisions" >&2; then
    echo "  [warn] bot-thread retry: could not render skip decisions for PR ${pr_number}" >&2
  fi

  local ids attempt now_iso
  ids=$(jq -r '.dispatch | join(",")' <<< "$decisions")
  if [ -z "$ids" ]; then
    # Only when nothing is dispatched: a fix-reviews pass covers EVERY unresolved
    # thread, the exhausted ones included, so a notice posted alongside a dispatch
    # could go stale while its marker blocks a corrected one.
    post_bot_thread_exhausted_notice "$repo" "$pr_number" "$decisions"
    echo "0"; return 0
  fi
  attempt=$(jq -r '.attempt' <<< "$decisions")
  # Spliced into the marker body below.
  if [[ ! "$ids" =~ ^[-A-Za-z0-9_+/=,]+$ ]] || [[ ! "$attempt" =~ ^[0-9]+$ ]]; then
    echo "  [warn] bot-thread retry: unexpected thread ids/attempt on PR ${pr_number} — not dispatching" >&2
    post_bot_thread_exhausted_notice "$repo" "$pr_number" "$decisions"  # nothing was dispatched
    echo "0"; return 0
  fi
  now_iso="${NOW_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  echo "  [retry] bot-thread(s) ${ids} on PR ${pr_number}: unreplied → fix-reviews attempt ${attempt}" >&2

  # Record the attempt BEFORE dispatching, so a concurrent caller (this cron or
  # pr-review's gate hook) sees it as pending and does not dispatch again.
  local marker_id=""
  if [ "$DRY_RUN" != "true" ]; then
    if ! marker_id=$(gh api --method POST "repos/${repo}/issues/${pr_number}/comments" \
         -f body="$(btr_retry_marker "$ids" "$attempt" "$now_iso")" \
         --jq '.id // empty' 2>/dev/null); then
      echo "  [warn] bot-thread retry: could not record the retry marker on PR ${pr_number} — not dispatching (dedup unavailable)" >&2
      post_bot_thread_exhausted_notice "$repo" "$pr_number" "$decisions"  # nothing was dispatched
      echo "0"; return 0
    fi
    if [[ ! "$marker_id" =~ ^[0-9]+$ ]]; then
      echo "  [warn] bot-thread retry: the retry marker's id on PR ${pr_number} is unreadable — not dispatching (fail closed)" >&2
      post_bot_thread_exhausted_notice "$repo" "$pr_number" "$decisions"  # nothing was dispatched
      echo "0"; return 0
    fi
    # Two concurrent scans can both have seen no pending marker. The earliest
    # trusted retry marker (thread or bot-comment: they share one per-PR lane,
    # and scan_pr_for_undispositioned_bot_comments arbitrates against this kind
    # too) inside the pending window wins. The decision
    # above found none pending, so any other in-window marker was posted
    # concurrently. An expired marker from a lost run is outside the window and
    # never beats this claim. As with the bot-comment retry this is a best-effort
    # claim, not a lock (the listing is eventually consistent).
    local listing first_marker logins_jq pending
    pending="${BOT_THREAD_RETRY_PENDING_SEC:-9000}"
    [[ "$pending" =~ ^[0-9]+$ ]] || pending=9000
    logins_jq=$(jq -cn --arg a "$automation" '$a | split(",") | map(sub("\\[bot\\]$"; ""))')
    if [ "$BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC" -gt 0 ]; then
      sleep "$BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC"
    fi
    if ! listing=$(gh api --paginate "repos/${repo}/issues/${pr_number}/comments?per_page=100" \
      --jq '.[] | select((.user.login // "" | sub("\\[bot\\]$"; "")) as $l | '"${logins_jq}"' | index($l) != null)
            | select((.author_association // "") as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a) != null)
            | select((.body // "") | (contains("<!-- dev-lead-bot-thread-retry threads=") or contains("<!-- dev-lead-bot-comment-retry id=")))
            | {id, created_at}' \
      2>/dev/null); then
      echo "  [warn] bot-thread retry: could not re-read retry markers on PR ${pr_number} — withdrawing and not dispatching (fail closed)" >&2
      withdraw_bot_comment_retry_marker "$repo" "$marker_id"
      post_bot_thread_exhausted_notice "$repo" "$pr_number" "$decisions"  # nothing was dispatched
      echo "0"; return 0
    fi
    first_marker=$(printf '%s\n' "$listing" | jq -rs --argjson now "$now_epoch" --argjson pending "$pending" '
        [ .[] | objects | select((.id | type) == "number")
          | select($now - ((.created_at // "") | (try fromdateiso8601 catch 0)) < $pending) | .id ]
        | min // empty' 2>/dev/null || true)
    if [ -z "$first_marker" ]; then
      echo "  ::warning::bot-thread retry: the retry marker on PR ${pr_number} was posted by an identity the retry dedup does not trust (expected one of: ${automation}) — withdrawing and not dispatching" >&2
      withdraw_bot_comment_retry_marker "$repo" "$marker_id"
      post_bot_thread_exhausted_notice "$repo" "$pr_number" "$decisions"  # nothing was dispatched
      echo "0"; return 0
    fi
    if [ "$first_marker" != "$marker_id" ]; then
      echo "  [skip] bot-thread retry on PR ${pr_number}: a concurrent scan already recorded a retry" >&2
      withdraw_bot_comment_retry_marker "$repo" "$marker_id"
      echo "0"; return 0
    fi
  fi
  if ! dispatch_reviews_retry "$repo" "$pr_number" "$head_sha" "fix-reviews"; then
    withdraw_bot_comment_retry_marker "$repo" "$marker_id"
    post_bot_thread_exhausted_notice "$repo" "$pr_number" "$decisions"  # nothing was dispatched
    echo "0"; return 0
  fi
  echo "1"
}

# scan_repo <repo>: scan all open PRs in a repo for rate-limited markers
scan_repo() {
  local repo="$1"
  echo "[retry] scanning ${repo}..."

  local prs_json
  prs_json=$(gh api --paginate "repos/${repo}/pulls?state=open&per_page=100" \
    --jq '[.[] | {number: .number, head_sha: .head.sha}]' 2>/dev/null || echo "[]")

  local pr_count
  pr_count=$(echo "$prs_json" | jq -s 'add // [] | length')
  if [ "$pr_count" -eq 0 ]; then
    echo "  no open PRs in ${repo}"
  else
    echo "  found ${pr_count} open PR(s)"
    local total_dispatched=0
    while IFS= read -r pr_entry; do
      local pr_number
      pr_number=$(echo "$pr_entry" | jq -r '.number')
      local dispatched
      dispatched=$(scan_pr_for_rate_limits "$repo" "$pr_number")
      total_dispatched=$(( total_dispatched + dispatched ))
      # One dispatch per PR per scan (#2017): a second dispatch into the same
      # per-PR lane would supersede the first while it is still pending.
      if [ "${dispatched:-0}" -eq 0 ]; then
        dispatched=$(scan_pr_for_undispositioned_bot_comments "$repo" "$pr_number")
        total_dispatched=$(( total_dispatched + dispatched ))
      fi
      # Unreplied bot review threads (#2046), under the same one-per-PR rule.
      if [ "${dispatched:-0}" -eq 0 ]; then
        dispatched=$(scan_pr_for_unreplied_bot_threads "$repo" "$pr_number")
        total_dispatched=$(( total_dispatched + dispatched ))
      fi
    done < <(echo "$prs_json" | jq -sc 'add // [] | .[]')
    echo "  dispatched ${total_dispatched} PR retries from ${repo}"
  fi

  # Always scan open issues for failed initial implementations (#781) — even when
  # the repo has no open PRs, which is the common case for a stalled issue.
  scan_repo_issues "$repo"
}

# open_issue_pr_exists <repo> <issue_number>
# Returns 0 if an open PR for this issue already exists (branch dev-lead/issue-<N>*),
# meaning a prior attempt already produced — or is producing — a PR. In that case
# the issue must NOT be re-dispatched (the PR path takes over).
open_issue_pr_exists() {
  local repo="$1" issue_number="$2" count
  count=$(gh api --paginate "repos/${repo}/pulls?state=open&per_page=100" \
    --jq "[.[] | select(.head.ref | startswith(\"dev-lead/issue-${issue_number}-\"))]" \
    2>/dev/null | jq -s 'add | length' || echo "0")
  [ "${count:-0}" -gt 0 ]
}

# scan_issue_for_retry <repo> <issue_number>
# Inspects the issue's newest dev-lead-issue marker and re-dispatches a bounded
# retry when warranted. Prints only a single integer (retries dispatched) to
# stdout; all other output goes to stderr so callers can capture the count.
scan_issue_for_retry() {
  local repo="$1" issue_number="$2"

  local comments_json
  comments_json=$(gh api --paginate "repos/${repo}/issues/${issue_number}/comments?per_page=100" \
    --jq '[.[].body]' 2>/dev/null || echo "[]")

  # Newest dev-lead-issue marker for this issue (comments are chronological, so
  # the last matching one is the most recent attempt — earlier ones superseded).
  local prefix="${ISSUE_MARKER_PREFIX}${issue_number} "
  local marker
  marker=$(echo "$comments_json" | jq -s -r --arg p "$prefix" \
    '[ .[] | .[]? | select(. != null and (. | contains($p))) ] | last // ""' 2>/dev/null || echo "")

  if [ -z "$marker" ]; then
    # No failure marker → nothing failed (or it succeeded). Nothing to retry.
    echo "0"
    return 0
  fi

  local status attempt reason reset
  status=$(printf '%s' "$marker"  | grep -oE 'status=[^ ]+'  | head -1 | cut -d= -f2)
  attempt=$(printf '%s' "$marker" | grep -oE 'attempt=[0-9]+' | head -1 | cut -d= -f2)
  reason=$(printf '%s' "$marker"  | grep -oE 'reason=[^ ]+'  | head -1 | cut -d= -f2)
  reset=$(printf '%s' "$marker"   | grep -oE 'reset=[0-9TZ:-]+' | head -1 | cut -d= -f2)

  # Only failed / rate-limited markers are retryable. A status=needs-human marker
  # (or any other) is terminal — skip (such issues also carry the needs-human
  # label and are filtered before reaching here, but double-guard).
  case "$status" in
    failed|rate-limited) : ;;
    *)
      echo "  [skip] issue #${issue_number}: newest marker status=${status:-?} not retryable" >&2
      echo "0"; return 0 ;;
  esac

  # Honour the rate-limit reset window for rate-limited markers.
  if [ "$status" = "rate-limited" ] && is_reset_in_future "$reset"; then
    echo "  [skip] issue #${issue_number} rate-limit not yet cleared (resets ${reset})" >&2
    echo "0"; return 0
  fi
  if [ "$status" = "rate-limited" ] && budget_hold_active; then
    echo "  [skip] issue #${issue_number} rate-limit held by the budget poller until ${BUDGET_HOLD_UNTIL}" >&2
    echo "0"; return 0
  fi

  # Enforce the attempt ceiling. attempt>=MAX means fix-issue.sh already escalated
  # to a human on its last failure; do not re-dispatch.
  if [ -z "$attempt" ] || [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "  [skip] issue #${issue_number}: attempts exhausted (attempt=${attempt:-?}/${MAX_ATTEMPTS})" >&2
    echo "0"; return 0
  fi

  # Skip if a PR already exists for this issue (prior attempt succeeded, or a
  # retry run is currently producing one).
  if open_issue_pr_exists "$repo" "$issue_number"; then
    echo "  [skip] issue #${issue_number}: an open dev-lead PR already exists" >&2
    echo "0"; return 0
  fi

  echo "  [retry] issue #${issue_number}: status=${status} reason=${reason:-?} attempt=${attempt} < ${MAX_ATTEMPTS} → re-dispatching" >&2
  dispatch_issue_retry "$repo" "$issue_number" "$attempt"
  echo "1"
}

# scan_repo_issues <repo>: scan open issues labeled dev-lead for failed initial
# implementations and re-dispatch bounded retries.
scan_repo_issues() {
  local repo="$1"

  # Enumerate open issues carrying the dev-lead label but NOT the needs-human
  # escalation label. The issues endpoint also returns PRs, so filter
  # .pull_request==null to keep true issues only.
  local issues_json
  issues_json=$(gh api --paginate \
    "repos/${repo}/issues?state=open&labels=${DEV_LEAD_LABEL}&per_page=100" \
    --jq "[.[] | select(.pull_request == null)
           | select([.labels[].name] | index(\"${NEEDS_HUMAN_LABEL}\") | not)
           | {number: .number}]" \
    2>/dev/null || echo "[]")

  local issue_count
  issue_count=$(echo "$issues_json" | jq -s 'add // [] | length')
  if [ "${issue_count:-0}" -eq 0 ]; then
    echo "  no open dev-lead issues in ${repo}"
    return 0
  fi

  echo "  found ${issue_count} open dev-lead issue(s)"
  local total_dispatched=0
  while IFS= read -r issue_entry; do
    local issue_number dispatched
    issue_number=$(echo "$issue_entry" | jq -r '.number')
    dispatched=$(scan_issue_for_retry "$repo" "$issue_number")
    total_dispatched=$(( total_dispatched + dispatched ))
  done < <(echo "$issues_json" | jq -c '.[]')

  echo "  dispatched ${total_dispatched} issue retries from ${repo}"
}

# list_repos_for_org <org>: list all non-fork repos in the org.
# Hard-errors (non-zero exit) when the list is empty and not in DRY_RUN, since
# an empty result most likely means a token permission issue rather than a
# legitimately empty org — silently scanning 0 repos would hide misconfig.
list_repos_for_org() {
  local org="$1"
  local result
  result=$(gh repo list "$org" --limit 1000 --json nameWithOwner,isFork \
    --jq '[.[] | select(.isFork == false) | .nameWithOwner]' 2>/dev/null || echo "[]")
  if [ "$result" = "[]" ] || [ -z "$result" ]; then
    echo "::warning::No repos found for org '${org}' — check GH_TOKEN has repo read scope" >&2
    if [ "${DRY_RUN:-false}" != "true" ]; then
      echo "::error::Aborting: scanning 0 repos would silently miss all rate-limited PRs" >&2
      exit 1
    fi
  fi
  echo "$result"
}

# main: orchestrates the retry scan across all configured repos and dispatches retries.
main() {
  echo "[retry] dev-lead-retry starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[retry] dry_run=${DRY_RUN} dispatch_delay=${DISPATCH_DELAY_SEC}s"

  local all_repos=()

  # Collect repos from TARGET_ORG
  while IFS= read -r repo; do
    all_repos+=("$repo")
  done < <(list_repos_for_org "$TARGET_ORG" | jq -r '.[]')

  # Collect repos from DELEGATION_ORGS
  if [ -n "$DELEGATION_ORGS" ]; then
    for org in $DELEGATION_ORGS; do
      while IFS= read -r repo; do
        all_repos+=("$repo")
      done < <(list_repos_for_org "$org" | jq -r '.[]')
    done
  fi

  local repo_count="${#all_repos[@]}"
  echo "[retry] scanning ${repo_count} repo(s) across org(s)"

  # Hold each retry payload back from a target whose pinned parser does not
  # read all its fields (#2086). Off unless the workflow passes SWEEP_AGENT_REF.
  dcg_init || exit 1
  if [ -n "$DCG_SWEEP_REF" ]; then
    echo "[retry] sweep channel: ${DCG_SWEEP_REF} (a payload goes only to repos whose pinned parser reads all its fields)"
  else
    echo "[retry] SWEEP_AGENT_REF unset: per-target payload-field gate off (#2086)"
  fi

  # Read the budget poller's published result ONCE per run, here in the parent
  # shell: every scan below runs in a $(...) subshell and inherits the hold.
  budget_hold_init

  local repo_index=0
  for repo in "${all_repos[@]}"; do
    if [ "$repo_index" -gt 0 ] && [ "$DISPATCH_DELAY_SEC" -gt 0 ]; then
      # Stagger dispatches to avoid hammering the rate-limited API simultaneously
      echo "[retry] waiting ${DISPATCH_DELAY_SEC}s before next repo (stagger)..."
      sleep "$DISPATCH_DELAY_SEC"
    fi
    scan_repo "$repo"
    repo_index=$(( repo_index + 1 ))
  done

  echo "[retry] done at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# hold_label_exit_guard_then_cleanup <rc> — remove the private marker directory
# after the guard has read the marker file, then apply the guard.
hold_label_exit_guard_then_cleanup() {
  local rc="$1"
  if [ -n "${HOLD_LABEL_FAILED_FILE:-}" ] && [ -e "$HOLD_LABEL_FAILED_FILE" ]; then
    export HOLD_LABEL_FAILED=1
  fi
  [ -z "${HOLD_LABEL_FAILED_DIR:-}" ] || rm -rf "$HOLD_LABEL_FAILED_DIR"
  hold_label_exit_guard "$rc"
}

# Run main only when executed directly (bash dev-lead-retry.sh), not when sourced
# by unit tests that exercise individual functions (scan_issue_for_retry, etc.).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  # A failed hold (#2142) must fail the scan even though escalation is `|| true`.
  # Escalations run inside command substitutions, so a failed hold is also
  # recorded in a file that survives the subshell; the guard reads it.
  # The marker lives in a private mktemp -d directory (mode 700): `mktemp -u`
  # would only print a name that something else could claim first.
  HOLD_LABEL_FAILED_DIR=$(mktemp -d)
  HOLD_LABEL_FAILED_FILE="$HOLD_LABEL_FAILED_DIR/failed"
  export HOLD_LABEL_FAILED_FILE
  # shellcheck disable=SC2154  # rc is set by the trap string itself
  trap 'rc=$?; hold_label_exit_guard_then_cleanup "$rc"' EXIT
  main "$@"
fi
