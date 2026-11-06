#!/usr/bin/env bash
# self-dismissed-approval.sh — has pr-review's own gate dismissed its approval at
# the current head, leaving the PR "pending re-evaluation" rather than reviewed?
# (#1933)
#
# The maintainer-comment gate (#1813) and the maintainer-review-thread gate
# (#1415) in review-one-pr.sh dismiss pr-review's APPROVED review at the head
# when they block. Once the blocking comment/thread is dealt with on the SAME
# head, the next run passes every gate and then reaches the same-SHA idempotency
# check, which sees the approval marker and no-ops with `already-reviewed-at-head`
# — so the PR stays unapproved until a new commit or a human @mention (#1933,
# the #1551 shape). A gate dismissal means "re-evaluate when the gate clears",
# not "reviewed"; this library recognises exactly that state so the caller can
# re-run the FULL cascade (every gate armed — never a re-posted approval).
#
# Deliberately narrow. Pending re-evaluation only when ALL hold:
#   • the NEWEST review by the pr-review identity at <head> that carries the
#     approval marker for <head> is now DISMISSED;
#   • its latest `review_dismissed` event was made by automation (a `[bot]` App,
#     the pr-review identity, or an AUTOMATION_BOT_LOGINS account) with one of
#     the gate-dismissal messages below;
#   • no review by the pr-review identity at <head> is currently APPROVED.
# A human's dismissal, the #1596 "accepted defect — re-review required"
# dismissal, a supersede dismissal, or anything unreadable is NOT pending
# re-evaluation (fail closed: the same-SHA no-op stands).
#
# This file is meant to be SOURCED, not executed.

# The messages review-one-pr.sh's gates stamp on their dismissals (prefix match).
# Keep in sync with the `dismissPullRequestReview` calls there; a test asserts it.
SDA_GATE_DISMISSAL_PREFIXES=(
  "Dismissing approval due to a PR issue comment lacking a verified disposition"
  "Dismissing approval due to unaddressed maintainer review thread"
)

# sda_pending_reevaluation <reviews_json> <events_json> <head_sha> <bot_login> [automation_logins]
#   <reviews_json>: REST `pulls/{n}/reviews` array ({id, user.login, state, commit_id, body}).
#   <events_json>:  REST `issues/{n}/events` array (review_dismissed events carry
#                   actor.login and dismissed_review.{review_id, dismissal_message}
#                   — the live API's shape; review_id is matched as a string, and a
#                   missing id never matches).
#   Exit 0 when the approval at <head> is pending re-evaluation; 1 otherwise
#   (including malformed input).
sda_pending_reevaluation() {
  local reviews="${1:-}" events="${2:-}" head="${3:-}" bot="${4:-}" automation="${5:-${AUTOMATION_BOT_LOGINS:-}}"
  [[ -n "$head" ]] && [[ -n "$bot" ]] || return 1
  local prefixes
  prefixes=$(printf '%s\n' "${SDA_GATE_DISMISSAL_PREFIXES[@]}" | jq -R . | jq -sc .) || return 1
  jq -e -n \
    --argjson reviews "${reviews:-null}" --argjson events "${events:-null}" \
    --arg head "$head" --arg bot "$bot" --arg automation "$automation" \
    --argjson prefixes "$prefixes" '
    def lc: ascii_downcase;
    def is_automation($login):
      ($login // "") as $l
      | ($l != "")
        and (($l | endswith("[bot]"))
             or (($l | lc) == ($bot | lc))
             or (($automation | split(" ") | map(select(. != "") | lc)) | index($l | lc)) != null);
    def at_head_by_bot:
      select(((.user.login // "") | lc) == ($bot | lc) and (.commit_id // "") == $head);
    def id_str: if type == "number" or (type == "string" and . != "") then tostring else null end;
    if ($reviews | type) != "array" or ($events | type) != "array" then false
    else
      ($reviews | map(at_head_by_bot)) as $mine
      # The NEWEST approval verdict at <head> decides (#1933 review): an older
      # gate-dismissed approval must not revive a newer one a human dismissed.
      | ([ $mine[]
           | select(.state == "APPROVED" or .state == "DISMISSED")
           | select((.body // "") | contains("<!-- pr-review-agent v1 sha=" + $head))
           | select((.body // "") | test("decision=approved([^[:alnum:]_]|$)")) ]
         | last) as $newest
      | ([$mine[] | select(.state == "APPROVED")] | length) == 0
        and $newest != null
        and $newest.state == "DISMISSED"
        and (($newest.id | id_str) as $id
             | $id != null
               and (([ $events[]
                       | select(.event == "review_dismissed"
                                and ((.dismissed_review.review_id // null) | id_str) == $id) ]
                     | last) as $ev
                    | $ev != null
                      and is_automation($ev.actor.login)
                      and (($ev.dismissed_review.dismissal_message // $ev.dismissal_message // "") as $m
                           | any($prefixes[]; . as $p | $m | startswith($p)))))
    end' >/dev/null 2>&1
}

# sda_check_pr <owner/repo> <pr_number> <head_sha> <bot_login>
#   Fetch the reviews and issue events (paginated REST) and apply
#   sda_pending_reevaluation. Any API failure → exit 1 (not pending).
sda_check_pr() {
  local repo="$1" pr="$2" head="$3" bot="$4" reviews events
  [[ -n "$repo" ]] && [[ -n "$pr" ]] || return 1
  reviews=$(gh api --paginate "repos/${repo}/pulls/${pr}/reviews?per_page=100" 2>/dev/null | jq -s 'add // []' 2>/dev/null) || return 1
  events=$(gh api --paginate "repos/${repo}/issues/${pr}/events?per_page=100" 2>/dev/null | jq -s 'add // []' 2>/dev/null) || return 1
  sda_pending_reevaluation "$reviews" "$events" "$head" "$bot"
}
