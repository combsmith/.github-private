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
#   TARGET_ORG          — GitHub org to scan (default: combsmith)
#
# Env (optional):
#   DELEGATION_ORGS     — space-separated additional orgs to scan
#   DISPATCH_DELAY_SEC  — seconds between repo dispatches (default: 30) to
#                         prevent cascading org-wide rate-limit hits
#   DRY_RUN             — if "true", log what would be dispatched but don't send
#   NOW_ISO             — override current time for testing (ISO-8601 UTC)
#
# Retryable intents: fix-reviews, review-changes, rebase
#   These intents fetch all needed context (open threads, PR metadata) fresh
#   from the GitHub API at run time, so a re-dispatch has full fidelity.
#
# NOT retried automatically: on-mention, fix-bot-comment
#   These intents require USER_INSTRUCTION / COMMENT_BODY from the original
#   triggering event, which cannot be reconstructed from the PR's current
#   state. Users are asked to re-trigger manually.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Escalation gate (#946): pr_has_escalation_label / NEEDS_HUMAN_REVIEW_LABEL.
# shellcheck source=lib/pr-automation-budget.sh
source "$SCRIPT_DIR/lib/pr-automation-budget.sh"

TARGET_ORG="${TARGET_ORG:-combsmith}"
DELEGATION_ORGS="${DELEGATION_ORGS:-}"
DISPATCH_DELAY_SEC="${DISPATCH_DELAY_SEC:-30}"
DRY_RUN="${DRY_RUN:-false}"

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

# has_dispatch_guard <comments_json> <sha>
# Returns 0 when a dispatch guard for this SHA was posted within
# DISPATCH_GUARD_WINDOW_SEC seconds, indicating a concurrent caller already
# claimed dispatch for this PR and the current caller should skip.
has_dispatch_guard() {
  local comments_json="$1" sha="$2" guard_time guard_epoch now_epoch age
  guard_time=$(echo "$comments_json" | jq -r \
    --arg pat "${DISPATCH_GUARD_PREFIX}${sha}" \
    '[.[] | select(. | test($pat))] | .[0] | capture("at=(?<t>[0-9T:Z-]+)") | .t // ""' \
    2>/dev/null || true)
  [ -z "$guard_time" ] && return 1
  guard_epoch=$(date -u -d "$guard_time" +%s 2>/dev/null || echo 0)
  now_epoch=$(get_now_epoch)
  age=$(( now_epoch - guard_epoch ))
  [ "$age" -lt "${DISPATCH_GUARD_WINDOW_SEC:-600}" ]
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
  if ! echo "$payload" | gh api --method POST "repos/${repo}/dispatches" --input - >/dev/null 2>&1; then
    echo "  [warn] dispatch failed for PR ${pr_number} in ${repo}" >&2
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
  if ! echo "$payload" | gh api --method POST "repos/${repo}/dispatches" --input - >/dev/null 2>&1; then
    echo "  [warn] dispatch failed for PR ${pr_number} in ${repo}" >&2
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
  if ! echo "$payload" | gh api --method POST "repos/${repo}/dispatches" --input - >/dev/null 2>&1; then
    echo "  [warn] dispatch failed for issue ${issue_number} in ${repo}" >&2
  fi
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
  labels_json=$(jq -c '[.labels[]?.name]' <<< "$pr_obj" 2>/dev/null || echo '[]')
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

  # ── Check for fix-ci rate-limited marker on current HEAD SHA ──────────────
  local ci_pattern="${CI_MARKER_PREFIX}${head_sha} status=rate-limited"
  if echo "$comments_json" | jq -e --arg pat "$ci_pattern" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
    # Extract reset time from the marker (format: reset=<ISO>)
    local reset_time
    reset_time=$(echo "$comments_json" | jq -r \
      --arg pat "$ci_pattern" \
      '[.[] | select(. | test($pat))] | .[0] | capture("reset=(?P<r>[0-9T:Z-]+)") | .r // ""' \
      2>/dev/null || true)

    if is_reset_in_future "$reset_time"; then
      echo "  [skip] fix-ci rate-limit for PR ${pr_number} not yet cleared (resets ${reset_time})" >&2
    else
      # Skip if a terminal marker was already posted for this SHA (prior retry succeeded)
      local terminal_pattern="${CI_MARKER_PREFIX}${head_sha} status=(applied|failed|no-changes)"
      if echo "$comments_json" | jq -e --arg pat "$terminal_pattern" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
        echo "  [skip] fix-ci already has terminal result for PR ${pr_number} SHA ${head_sha:0:8}" >&2
      else
        local check_name="CI failure"
        check_name=$(echo "$comments_json" | jq -r \
          --arg pat "$ci_pattern" \
          '[.[] | select(. | test($pat))] | .[0] | capture("check=(?P<c>[^\\s\"<>]+)") | .c // "CI failure"' \
          2>/dev/null || echo "CI failure")
        if [ "$guard_posted" -eq 0 ]; then
          post_dispatch_guard "$repo" "$pr_number" "$head_sha"
          guard_posted=1
        fi
        dispatch_ci_retry "$repo" "$pr_number" "$head_sha" "$check_name"
        dispatched=$(( dispatched + 1 ))
      fi
    fi
  fi

  # ── Check for retryable fix-reviews rate-limited markers on HEAD SHA ───────
  # Only intents that can reconstruct their full context at retry time.
  # on-mention and fix-bot-comment are excluded: their USER_INSTRUCTION/COMMENT_BODY
  # cannot be recovered from the PR's current state.
  for intent_type in $RETRYABLE_REVIEW_INTENTS; do
    local reviews_pattern="${REVIEWS_MARKER_PREFIX}${pr_number} sha=${head_sha} intent=${intent_type} status=rate-limited"
    if echo "$comments_json" | jq -e --arg pat "$reviews_pattern" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
      local reset_time
      reset_time=$(echo "$comments_json" | jq -r \
        --arg pat "$reviews_pattern" \
        '[.[] | select(. | test($pat))] | .[0] | capture("reset=(?P<r>[0-9T:Z-]+)") | .r // ""' \
        2>/dev/null || true)

      if is_reset_in_future "$reset_time"; then
        echo "  [skip] ${intent_type} rate-limit for PR ${pr_number} not yet cleared (resets ${reset_time})" >&2
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
      local reviews_terminal="${REVIEWS_MARKER_PREFIX}${pr_number} sha=${head_sha} intent=${dispatch_intent} status=(applied|no-changes|failed)"
      if echo "$comments_json" | jq -e --arg pat "$reviews_terminal" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
        echo "  [skip] ${intent_type} already has terminal result for PR ${pr_number} SHA ${head_sha:0:8}" >&2
        continue
      fi

      if [ "$guard_posted" -eq 0 ]; then
        post_dispatch_guard "$repo" "$pr_number" "$head_sha"
        guard_posted=1
      fi
      dispatch_reviews_retry "$repo" "$pr_number" "$head_sha" "$dispatch_intent"
      dispatched=$(( dispatched + 1 ))
    fi
  done

  echo "$dispatched"
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

# Run main only when executed directly (bash dev-lead-retry.sh), not when sourced
# by unit tests that exercise individual functions (scan_issue_for_retry, etc.).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
