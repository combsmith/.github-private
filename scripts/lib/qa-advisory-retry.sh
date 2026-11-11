#!/usr/bin/env bash
# qa-advisory-retry.sh — let a QA Lead advisory inform dev-lead's pass without
# gating it (#2487, ADR-0016, an extension of ADR-0005).
#
# WHY THIS EXISTS
#   The QA Lead posts one advisory when a PR opens (its pull_request surface
#   fires on opened/ready_for_review only). On a dev-lead-authored PR nothing read
#   it: dev-lead's review-changes pass could run before the advisory landed, and
#   no later pass looked for it (combsmith/empower-personal-dashboard#180, where
#   the pass ran 37 s before the advisory). Changing the persona's identity would
#   not help (see the issue). Instead dev-lead's retry cron PULLS: this library
#   flags an advisory with no dev-lead disposition, and dev-lead-retry.sh sends
#   the existing `dev-lead-reviews-retry` / `review-changes` event. The persona
#   runner gains no capability (ADR-0005) and still posts as the owner account
#   (ADR-0008).
#
# WHAT COUNTS AS AN ADVISORY (qa_advisory_open, PURE — no gh/network)
#   A PR issue comment that
#     • starts with the exact QA Lead marker `<!-- persona:qa-lead -->`
#       (prompts/qa-lead/advisory.md: it is the body's first line);
#     • has a trusted author association (OWNER/MEMBER/COLLABORATOR). The repo is
#       public and anyone can paste the marker; the persona posts as the owner
#       account, so the rule costs it nothing (the #1921 forgery rule); and
#     • has ITEMS: at least one bullet under its "What I'd shore up" heading,
#       before the "Escalate?" line. An out-of-scope note has none and is not a
#       candidate.
#   It is OPEN unless a DISPOSITION covers it: a comment by our own automation
#   (a login in <automation_logins_csv>, with a trusted association) carrying
#     <!-- dev-lead:advisory-disposition id=<advisory node id> … -->
#   and NOT carrying `<!-- dev-lead:retracted` — the harness retracts a reply
#   whose claimed commit did not land, quoting the original body, so a retracted
#   reply must not count as handled.
#
# WHAT THE SWEEP DECIDES (qa_advisory_decisions, PURE)
#   For each advisory, oldest first:
#     skip/dispositioned            a disposition covers it. This is the LOOP
#                                   BOUND: it never dispatches again, however
#                                   long it waits.
#     escalate                      its `**Escalate?**` line says yes. dev-lead
#                                   applies nothing; the sweep records an
#                                   `outcome=escalated` disposition and adds no
#                                   hold.
#     skip/retry-attempts-exhausted MAX_ATTEMPTS retries were sent and none
#                                   produced a disposition. The PR is not held:
#                                   an advisory never blocks merge.
#     skip/retry-pending            a retry marker for it is younger than the
#                                   pending window: that pass may still be queued.
#     skip/lane-busy                a bot-comment or bot-thread retry was sent on
#                                   this PR within the lane window. Every retry
#                                   joins the same per-PR concurrency lane, where
#                                   a second dispatch supersedes a pending first.
#     dispatch                      otherwise, as attempt <previous + 1>.
#   Only markers from our own automation count, as in bot-thread-retry.sh.
#
# MARKERS
#   retry        <!-- dev-lead-qa-advisory-retry id=<node id> attempt=<N> at=<ISO> -->
#   disposition  <!-- dev-lead:advisory-disposition id=<node id> outcome=<handled|escalated> -->
#   Both match the maintainer gate's `dev-lead` agent marker (ADR-0012), so
#   neither is a gate candidate. Neither contains `persona:` or a persona handle,
#   so the persona router's recursion guard is untouched. The advisory itself
#   stays out of the gate by its `persona:` marker: it never blocks merge.
#
# Env (all optional):
#   QA_ADVISORY_RETRY_PENDING_SEC   pending window for a retry (default 9000:
#                                   one 2 h cron cycle plus slack)
#   QA_ADVISORY_RETRY_MAX_ATTEMPTS  retries per advisory before giving up (default 2)
#   QA_ADVISORY_RETRY_LANE_SEC      how recent a sibling retry must be to hold the
#                                   per-PR lane (default 900)
#
# This file is meant to be SOURCED, not executed.

QA_ADVISORY_PERSONA_MARKER='<!-- persona:qa-lead -->'
QA_ADVISORY_RETRY_MARKER_NAME='dev-lead-qa-advisory-retry'
QA_ADVISORY_DISPOSITION_PREFIX='<!-- dev-lead:advisory-disposition id='

# Shared jq definitions. The caller binds $logins (array of automation logins,
# compared without a `[bot]` suffix), $persona and $dprefix.
# shellcheck disable=SC2016  # jq program, not shell
_QA_ADVISORY_JQ_DEFS='
  def qa_trusted: (.authorAssociation // "") as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a) != null;
  def qa_ours: qa_trusted and (((.author.login // "") | sub("\\[bot\\]$"; "")) as $l | $logins | index($l) != null);
  def qa_lines: (.body // "") | gsub("\r"; "") | split("\n");
  def qa_is_advisory: qa_trusted and ((.body // "") | sub("^\\s+"; "") | startswith($persona));
  def qa_item_count:
    qa_lines as $l
    | ([$l | to_entries[] | select(.value | test("^\\s*\\*\\*What I.d shore up\\*\\*"; "i")) | .key] | first) as $s
    | if $s == null then 0
      else $l[($s + 1):] as $rest
        | ([$rest | to_entries[] | select(.value | test("^\\s*\\*\\*Escalate\\?\\*\\*"; "i")) | .key] | first) as $e
        | (if $e == null then $rest else $rest[:$e] end)
        | map(select(test("^\\s*[-*]\\s+\\S"))) | length
      end;
  def qa_escalate: any(qa_lines[]; test("^\\s*\\*\\*Escalate\\?\\*\\*\\s*yes\\b"; "i"));
  def qa_disposes($id):
    qa_ours
    and ((.body // "") | (contains($dprefix + $id + " ") or contains($dprefix + $id + "-->")))
    and ((.body // "") | contains("<!-- dev-lead:retracted") | not);
  def qa_open($all):
    [ $all[] | objects | select(qa_is_advisory) | select(qa_item_count > 0)
      | . as $adv | select(any($all[] | objects; qa_disposes($adv.id)) | not) ];
'

# _qa_logins_json <csv> — the automation logins as a JSON array without `[bot]`.
# Fails on an empty list: with no automation identity nothing can be trusted.
_qa_logins_json() {
  local csv="${1:-}"
  [[ -n "$csv" ]] || return 1
  jq -cn --arg a "$csv" '$a | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(length > 0) | sub("\\[bot\\]$"; ""))
    | if length == 0 then error("no logins") else . end' 2>/dev/null
}

# qa_advisory_retry_marker <advisory node id> <attempt> <at ISO>
qa_advisory_retry_marker() {
  printf '<!-- %s id=%s attempt=%s at=%s -->' "$QA_ADVISORY_RETRY_MARKER_NAME" "$1" "$2" "$3"
}

# qa_advisory_escalation_body <advisory node id> — the disposition the sweep posts
# for an `Escalate? yes` advisory. No persona marker and no persona handle.
qa_advisory_escalation_body() {
  printf '%s\n\n%s\n\n%s%s outcome=escalated -->\n' \
    "**dev-lead: QA Lead advisory escalated to a human.**" \
    "The QA Lead advisory above says it needs a maintainer before merge, so dev-lead applied none of its items. The advisory is recorded but never blocks merge (ADR-0016)." \
    "$QA_ADVISORY_DISPOSITION_PREFIX" "$1"
}

# qa_advisory_open <comments_json> <automation_logins_csv>
#   Echo a JSON array of the open (undispositioned), non-escalated advisories with
#   items, oldest first: [{id, createdAt, body}]. This is what a review-changes
#   pass must disposition. Returns 1 on unreadable input. Pure.
qa_advisory_open() {
  local comments="${1:-}" logins
  logins=$(_qa_logins_json "${2:-}") || return 1
  jq -ce --argjson logins "$logins" --arg persona "$QA_ADVISORY_PERSONA_MARKER" \
    --arg dprefix "$QA_ADVISORY_DISPOSITION_PREFIX" "${_QA_ADVISORY_JQ_DEFS}"'
    if type != "array" then error("not an array") else . end
    | . as $all
    | qa_open($all) | map(select(qa_escalate | not))
    | sort_by(.createdAt // "") | map({id, createdAt, body})' <<< "$comments" 2>/dev/null
}

# qa_advisory_decisions <comments_json> <now_epoch> <automation_logins_csv>
#   Echo a JSON array, one entry per advisory with items, oldest first:
#   {id, decision: dispatch|escalate|skip, reason, attempt}. Returns 1 on
#   unreadable input, a non-numeric clock or no automation logins (the caller
#   then dispatches nothing). Pure.
qa_advisory_decisions() {
  local comments="${1:-}" now="${2:-}" logins
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  logins=$(_qa_logins_json "${3:-}") || return 1
  local pending="${QA_ADVISORY_RETRY_PENDING_SEC:-9000}" max="${QA_ADVISORY_RETRY_MAX_ATTEMPTS:-2}"
  local lane="${QA_ADVISORY_RETRY_LANE_SEC:-900}"
  [[ "$pending" =~ ^[0-9]+$ ]] || pending=9000
  [[ "$max" =~ ^[0-9]+$ ]] || max=2
  [[ "$lane" =~ ^[0-9]+$ ]] || lane=900
  jq -ce --argjson logins "$logins" --arg persona "$QA_ADVISORY_PERSONA_MARKER" \
    --arg dprefix "$QA_ADVISORY_DISPOSITION_PREFIX" --arg rname "$QA_ADVISORY_RETRY_MARKER_NAME" \
    --argjson now "$now" --argjson pending "$pending" --argjson max "$max" --argjson lane "$lane" \
    "${_QA_ADVISORY_JQ_DEFS}"'
    def at_epoch: (.createdAt // "") | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch 0);
    if type != "array" then error("not an array") else . end
    | . as $all
    | [ $all[] | objects | select(qa_ours) ] as $ours
    | ([ $ours[] | select((.body // "") | test("<!-- dev-lead-bot-(comment-retry id=|thread-retry threads=)"))
         | select(($now - at_epoch) < $lane) ] | length > 0) as $lane_busy
    | ($all | map(objects | select(qa_is_advisory) | select(qa_item_count > 0))
            | sort_by(.createdAt // "")) as $advs
    | qa_open($all) as $open
    | [ $advs[] | .id as $id
        | ([ $ours[] | select((.body // "") | contains("<!-- " + $rname + " id=" + $id + " attempt=")) ]) as $tries
        | ($tries | length) as $n
        | ([ $tries[] | at_epoch ] | max // 0) as $last
        | if (any($open[]; .id == $id) | not) then
            {id: $id, decision: "skip", reason: "dispositioned", attempt: $n}
          elif qa_escalate then
            {id: $id, decision: "escalate", reason: "escalate-yes", attempt: $n}
          elif $n >= $max then
            {id: $id, decision: "skip", reason: "retry-attempts-exhausted", attempt: $n}
          elif $n > 0 and ($now - $last) < $pending then
            {id: $id, decision: "skip", reason: "retry-pending", attempt: $n}
          elif $lane_busy then
            {id: $id, decision: "skip", reason: "lane-busy", attempt: $n}
          else
            {id: $id, decision: "dispatch", reason: "undispositioned", attempt: ($n + 1)}
          end ]' <<< "$comments" 2>/dev/null
}

# export_qa_advisories: echo the JSON list of open QA Lead advisories this
# review-changes pass must apply or decline (#2487, ADR-0016): [{id, createdAt,
# body}], oldest first, at most 5, each body cut to 4000 characters. Verifies
# the PR author is dev-lead before exporting; returns [] for non-dev-lead PRs to
# prevent advisory handling on PRs authored by other users. These advisories are
# optional. They never gate the pass, so a failed read logs a warning and gives
# `[]` instead of failing the pass. The retry cron re-offers the advisory later.
# Escalated and dispositioned advisories are left out (qa_advisory_open).
export_qa_advisories() {
  local comments open pr_obj pr_author
  if [[ "${DEV_LEAD_DRY_RUN:-false}" = "true" || -z "${PR_NUMBER:-}" || -z "${REPO:-}" ]]; then
    printf '[]'
    return 0
  fi
  # Verify the PR author is dev-lead before exporting advisories.
  if ! pr_obj=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" 2>/dev/null); then
    echo "::warning::review-changes: could not read the PR author of #${PR_NUMBER} — this pass does not see QA Lead advisories; the retry cron offers them again (#2487)" >&2
    printf '[]'
    return 0
  fi
  pr_author=$(jq -r '.user?.login // empty' <<< "$pr_obj" 2>/dev/null || true)
  # dev_lead_identity lives in dev-lead-retry.sh and is not defined in every
  # caller (the fix-reviews pass); fall back to DEV_LEAD_USER / the owner account.
  local dl_user
  if declare -F dev_lead_identity >/dev/null 2>&1; then
    dl_user=$(dev_lead_identity)
  else
    dl_user="${DEV_LEAD_USER:-don-petry}"
  fi
  if [[ -z "$pr_author" || "$pr_author" != "$dl_user" ]]; then
    [[ -n "$pr_author" ]] || echo "::warning::review-changes: PR #${PR_NUMBER} has no readable author — QA Lead advisories not exported (#2487)" >&2
    printf '[]'
    return 0
  fi
  if ! comments=$(bcr_fetch_pr_comments "$REPO" "$PR_NUMBER" 2>/dev/null) \
     || ! open=$(qa_advisory_open "$comments" "${dl_user},${BOT_USER:-donpetry-bot},donpetry-bot") \
     || ! open=$(jq -c '.[:5] | map(.body |= .[:4000])' <<< "$open" 2>/dev/null); then
    echo "::warning::review-changes: could not read QA Lead advisories on PR #${PR_NUMBER} — this pass does not see them; the retry cron offers them again (#2487)" >&2
    printf '[]'
    return 0
  fi
  printf '%s' "$open"
}
