#!/usr/bin/env bash
# pr-automation-budget.sh — per-PR automated-churn circuit breaker (issue #926).
#
# PR #860 ran away to 378 commits / 1,582 comments produced entirely by agents
# looping, with no human in the thread. Every pre-existing guard was per-worker
# or per-run; nothing bounded TOTAL automated activity on one PR over its
# lifetime, and no guard's reset required a human.
#
# This library bounds the work item (the PR), not each worker script:
#   compute_pr_automation_cycles <events_json>
#     Counts agent-authored activity (commits + comments + reviews/acks) that
#     happened AFTER the most recent HUMAN interaction. A human action resets
#     the count to zero; a machine action (bot comment, bot commit, machine
#     approval) never does — so the runaway can't re-arm its own budget.
#   pr_budget_exhausted <events_json>
#     Exit 0 when the count has reached MAX_PR_AUTOMATION_CYCLES (default 10).
#   gather_pr_automation_events <pr> <repo>   -> normalized {when, login}[] JSON
#   enforce_pr_budget <pr> <repo>
#     The orchestration entrypoint scripts call before doing automated writes:
#     on exhaustion it escalates ONCE (deduped marker + needs-human-review label
#     + auto-merge disabled) and returns 0 so the caller stops. Returns 1 when
#     there is still budget to proceed.
#
# Events are {when, login} objects. `when` is an ISO-8601 timestamp (strings
# compare correctly); items with null/empty `when` are ignored. A login is a
# bot when it ends in `[bot]` or is listed in AUTOMATION_BOT_LOGINS; an empty /
# unattributed login is treated as a machine (conservative — it must not reset).
#
# Login alone misreads two kinds of event, so gather_pr_automation_events flags
# them (#2224) and compute_pr_automation_cycles honours the flags:
#   mechanical: true    On a PR authored by dependabot[bot], an event by a login
#                       in PR_BUDGET_MECHANICAL_LOGINS — Dependabot's own commit,
#                       the dependabot-automerge App's `update-branch` merge
#                       commits and re-approvals. A push to `main` causes these,
#                       not an agent answering an agent. Neither counts nor
#                       resets. Both keys are required: any other bot on a
#                       Dependabot PR, and the App on anyone else's PR, count.
#   agent_marked: true  A comment or review whose body carries one of our
#                       automation markers (PR_BUDGET_AGENT_MARKER_RE). dev-lead,
#                       the personas and auto-rebase post as the owner account,
#                       so their login reads as a human. Such an event never
#                       resets the budget. It does not count either: only bot
#                       logins count.
# Still read as human, because nothing in the event tells them apart: a commit,
# an unmarked comment, or a review-thread reply an agent makes under a human login.

# Space-separated bot logins beyond any `*[bot]` GitHub App identity. Includes
# the agent identity (donpetry-bot) and repair-pr-approvals, whose machine
# approvals must not reset the budget.
: "${AUTOMATION_BOT_LOGINS:=donpetry-bot github-actions[bot] repair-pr-approvals}"
: "${MAX_PR_AUTOMATION_CYCLES:=10}"

# Space-separated logins of the Dependabot merge pipeline. Their events are
# flagged `mechanical` on a PR authored by dependabot[bot], and nowhere else.
# Set but empty turns the exemption off (hence `=`, not `:=`).
: "${PR_BUDGET_MECHANICAL_LOGINS=dependabot[bot] petry-projects-dependabot-automrg[bot]}"
_PR_BUDGET_DEPENDABOT_AUTHOR="dependabot[bot]"

# Regex (jq `test`) for a body one of our agents wrote. The registered list is
# scripts/lib/maintainer-comment-gate.sh's _MAINTAINER_GATE_AGENT_MARKERS (kept
# in step by tests/test_pr_automation_budget.bats), with two differences:
# `maintainer-resolve` is left out, because a maintainer posts it through
# maintainer-resolve-comment.sh and that is a human act; and this breaker's own
# escalation marker is added, because dev-lead posts it as the owner account.
PR_BUDGET_AGENT_MARKER_RE='<!-- (pr-review-agent|pr-review-claim|persona:|dev-lead|dependency-advisory|auto-rebase-|pr-automation-budget)[^>]*-->'

# The label this breaker adds on exhaustion (and the cycle cap adds on escalation).
# It is the human-controlled re-engagement gate: a human removing it resumes
# automation. The retry/sweep crons skip a PR while it carries this label (#946).
: "${NEEDS_HUMAN_REVIEW_LABEL:=needs-human-review}"

PR_AUTOMATION_EXHAUSTION_MARKER="<!-- pr-automation-budget exhausted -->"

# The cycle-cap human-escalation marker (owned by scripts/lib/review-cycle.sh's
# has_escalation_marker). Mirrored here as a literal so pr_hold_kind can tell a
# GENUINE escalation from a rate-limit-only hold WITHOUT sourcing review-cycle.sh
# (kept in sync by tests/test_pr_automation_budget.bats).
PR_CYCLE_CAP_ESCALATION_MARKER="<!-- pr-review-agent escalation -->"

# The rate-limit withhold marker prefix (owned by scripts/lib/advisory-review-gate.sh's
# maybe_post_rate_limited_marker). A hold carrying ONLY this marker at the current
# head PROMISES autonomous recovery after a reset; the sweep must not let the pause
# label disable that recovery (#1550).
PR_RATE_LIMITED_MARKER_PREFIX="<!-- pr-review-agent rate-limited v1 sha="

_PR_BUDGET_JQ_DEFS='
  def is_bot($bots):
    . as $login
    | ($login == null) or ($login == "")
      or ($login | endswith("[bot]"))
      or (($bots | index($login)) != null);
  def agent_marked($re): (. // "" | tostring | test($re));
'

# compute_pr_automation_cycles <events_json>
#   Prints the number of bot-authored events newer than the latest human event.
#   `mechanical` events are left out altogether; an `agent_marked` event under a
#   human login is not a human event (#2224).
compute_pr_automation_cycles() {
  local events_json="${1:-[]}"
  local bots_json count
  bots_json=$(printf '%s' "${AUTOMATION_BOT_LOGINS}" \
    | jq -R 'split(" ") | map(select(. != ""))' 2>/dev/null) || bots_json='[]'
  count=$(jq -r --argjson bots "$bots_json" "$_PR_BUDGET_JQ_DEFS"'
    map(select(.when != null and .when != "" and .mechanical != true))
    | ([.[] | select(((.login | is_bot($bots)) | not) and (.agent_marked != true)) | .when]
        | max // "") as $last_human
    | [.[] | select((.login | is_bot($bots)) and (.when > $last_human))]
    | length
  ' <<<"$events_json" 2>/dev/null) || count=0
  # Defensive: malformed input degrades to 0 so the integer comparison at the
  # budget gate never breaks ("integer expression expected").
  case "$count" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$count" ;;
  esac
}

# pr_budget_flag_mechanical <events_json> [pr_author]
#   Print the events with `mechanical: true` added to each Dependabot-pipeline
#   event (see the header). Pure. No event is dropped: the stall and merge-ready
#   scans read `.when` from every event. An empty, missing or other PR author
#   flags nothing, and input that is not a JSON array is printed unchanged, so a
#   failure here can only leave the count where it was (fail closed).
pr_budget_flag_mechanical() {
  local events_json="${1:-[]}" pr_author="${2:-}" logins_json out
  if [ "$pr_author" != "$_PR_BUDGET_DEPENDABOT_AUTHOR" ] || [ -z "${PR_BUDGET_MECHANICAL_LOGINS}" ]; then
    printf '%s\n' "$events_json"
    return 0
  fi
  logins_json=$(printf '%s' "${PR_BUDGET_MECHANICAL_LOGINS}" \
    | jq -R 'split(" ") | map(select(. != ""))' 2>/dev/null) || logins_json='[]'
  if out=$(jq -c --argjson logins "$logins_json" '
      if type != "array" then error("not an array") else . end
      | map(if (.login as $l | $logins | index($l)) != null then . + {mechanical: true} else . end)
    ' <<<"$events_json" 2>/dev/null); then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$events_json"
  fi
}

# pr_budget_body_is_agent_marked <body>
#   Exit 0 when the body carries one of our automation markers. Pure; the same
#   jq test gather_pr_automation_events applies to comment and review bodies.
pr_budget_body_is_agent_marked() {
  jq -en --arg b "${1:-}" --arg re "$PR_BUDGET_AGENT_MARKER_RE" "$_PR_BUDGET_JQ_DEFS"'
    $b | agent_marked($re)' >/dev/null 2>&1
}

# pr_has_escalation_label <labels_json>
#   Exit 0 if the JSON array of label NAMES contains NEEDS_HUMAN_REVIEW_LABEL —
#   i.e. the PR is currently escalated to a human.
#
#   This is the gate the retry/sweep crons consult before re-dispatching (#946),
#   so a PR that exhausted its automation budget is not re-ignited (the #860
#   "amplifier" failure mode). We gate on the LABEL, not the exhaustion MARKER
#   comment: the marker is an immutable audit record that the resume flow can
#   never clear, so gating on it would make re-engagement impossible. The label
#   is human-controlled — removing it re-enables the crons — mirroring
#   review-one-pr.sh, which pauses only while the label is present.
#
#   Malformed/empty/missing input degrades to "not escalated" (exit 1).
pr_has_escalation_label() {
  local labels_json="${1:-[]}"
  if jq -e --arg l "${NEEDS_HUMAN_REVIEW_LABEL}" \
      'if type == "array" then any(.[]; . == $l) else false end' \
      <<<"$labels_json" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# The fleet's human-hold label set (needs-human-review, dev-lead:needs-human,
# dev-lead:hands-off) lives in hold-gate.sh (#1595). Sourced here so the resume
# gate below honours every hold, not just NEEDS_HUMAN_REVIEW_LABEL (#2089).
# shellcheck source=scripts/lib/hold-gate.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hold-gate.sh"
# The escalation applies its label through hold-label.sh (#2142): REST labels API,
# the API's message logged on failure, HOLD_LABEL_FAILED set for the run's guard.
# shellcheck source=scripts/lib/hold-label.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hold-label.sh"

# pr_hold_gate_label <labels_json>
#   Print the first hold-gate label (hold_gate_labels) present in the JSON array
#   of label NAMES and exit 0; print nothing and exit 1 when none is present.
#   Malformed/empty/missing input degrades to "not held" (exit 1), like
#   pr_has_escalation_label.
pr_hold_gate_label() {
  local labels_json="${1:-[]}" names
  names=$(jq -r 'if type == "array" then .[] | strings else empty end' \
    <<<"$labels_json" 2>/dev/null) || return 1
  [ -n "$names" ] || return 1
  hold_gate_first_match "$names"
}

# pr_hold_kind <items_json> <head_sha>
#   Classify WHY a PR carrying NEEDS_HUMAN_REVIEW_LABEL is held, so a re-trigger
#   timer can log the exact hold it honors (#1550 AC#5) and exempt the ONE hold
#   whose recovery the label would otherwise disable. <items_json> is a JSON array
#   of {body} objects (the PR's reviews + comments). Prints exactly one of:
#     "budget-exhaustion" — the <!-- pr-automation-budget exhausted --> marker
#     "cycle-cap"         — the <!-- pr-review-agent escalation --> marker
#     "rate-limit-only"   — a rate-limited withhold marker at <head_sha> and NONE
#                           of the genuine-escalation markers above (the recovery-
#                           promising hold the sweep must exempt, #1550 AC#1)
#     "manual"            — held with none of the above markers (e.g. a manual /
#                           single-review-failure escalation) — pause as today
#   A GENUINE escalation takes PRECEDENCE over a co-present rate-limit marker so a
#   real escalation still pauses everything (#1550 AC#3): the exemption keys on the
#   marker set, it does not weaken the hold semantics generally. Malformed/empty
#   input degrades to "manual" (fail-closed — an undeterminable hold stays paused).
pr_hold_kind() {
  local items_json="${1:-[]}" head_sha="${2:-}"
  if _pr_items_have_marker "$items_json" "$PR_AUTOMATION_EXHAUSTION_MARKER"; then
    echo "budget-exhaustion"
    return 0
  fi
  if _pr_items_have_marker "$items_json" "$PR_CYCLE_CAP_ESCALATION_MARKER"; then
    echo "cycle-cap"
    return 0
  fi
  # Require the CANONICAL marker — prefix + head SHA + the literal
  # `status=rate-limited` field — not just the SHA-prefixed opener. Matching only
  # the prefix would let any comment/review body that merely quotes
  # `…rate-limited v1 sha=<HEAD> ` (a lookalike from a user or unrelated
  # automation) bypass the needs-human-review gate and re-arm dispatch. Demanding
  # the `status=rate-limited` field of the real marker closes that spoof path
  # while staying a literal substring match (canonical producer:
  # advisory-review-gate.sh's maybe_post_rate_limited_marker).
  if [ -n "$head_sha" ] \
      && _pr_items_have_marker "$items_json" "${PR_RATE_LIMITED_MARKER_PREFIX}${head_sha} status=rate-limited "; then
    echo "rate-limit-only"
    return 0
  fi
  echo "manual"
}

# _pr_items_have_marker <items_json> <literal-substring>
#   Exit 0 if any item's body CONTAINS the literal substring. Substring (not regex)
#   match, so marker strings with regex metacharacters compare literally. Malformed/
#   non-array input degrades to "no match" (exit 1).
_pr_items_have_marker() {
  local items_json="${1:-[]}" needle="${2:-}"
  [ -n "$needle" ] || return 1
  if jq -e --arg needle "$needle" '
    if type == "array" then any(.[]; (.body? // "" | tostring) | contains($needle)) else false end
  ' <<<"$items_json" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# pr_resume_suppressed <pr> <repo> [labels_json] [events_json]
#   Exit 0 (SUPPRESS — do NOT resume / re-dispatch) when the PR is human-gated
#   (carries NEEDS_HUMAN_REVIEW_LABEL or any other hold-gate label, #2089) OR its
#   per-PR automation budget is exhausted; exit 1 (proceed) otherwise.
#
#   This is the SINGLE stop-condition consulted before any automated resume of a
#   blocked/rate-limited dev-lead state — by the event-first resume bridge
#   (scripts/dev-lead-resume.sh) AND the safety-net cron
#   (scripts/dev-lead-retry.sh). Routing both paths through one gate is what makes
#   the event fast-path provably as safe as the timer (#1407 AC #3): neither can
#   re-ignite the #860 amplifier. It is the LABEL + the BUDGET together — the
#   label is the human-controlled re-engagement gate (#946), the budget is the
#   since-last-human action ceiling (#926); FORCE_REVIEW does not bypass either.
#
#   labels_json / events_json may be passed in by a caller that already fetched
#   them (avoids a redundant API round-trip); when omitted they are fetched here.
#   A labels_json that is not a JSON array (a failed fetch or parse) suppresses.
pr_resume_suppressed() {
  local pr="$1" repo="$2" labels_json="${3:-}" events_json="${4:-}"
  [ -n "$pr" ] && [ -n "$repo" ] || return 1

  if [ -z "$labels_json" ]; then
    labels_json=$(gh api "repos/${repo}/pulls/${pr}" \
      --jq '[.labels[]?.name]' 2>/dev/null) || labels_json=''
  fi
  # An unreadable label set may be hiding a hold, so it suppresses (fail closed,
  # #2089 review); `[]` is reserved for a label set that was read and is empty.
  if ! jq -e 'type == "array"' <<<"$labels_json" >/dev/null 2>&1; then
    echo "  [suppress] PR #${pr} in ${repo} — labels unavailable (API error or unreadable); suppressing fail-closed" >&2
    return 0
  fi
  if pr_has_escalation_label "$labels_json"; then
    echo "  [suppress] PR #${pr} in ${repo} carries ${NEEDS_HUMAN_REVIEW_LABEL} — human-gated; not resuming (#946)" >&2
    return 0
  fi
  # Every other human hold (dev-lead:hands-off, dev-lead:needs-human) stops the
  # resume/retry paths too. Before #2089 only the escalation label did, so a held
  # PR still got retry markers, dispatch guards and a dispatched run that then
  # skipped at intent time — clutter plus spent retry attempts.
  local hold hold_rc=0
  hold=$(pr_hold_gate_label "$labels_json") || hold_rc=$?
  if [ "$hold_rc" -eq 0 ]; then
    echo "  [suppress] PR #${pr} in ${repo} carries ${hold} — human hold; not resuming (#2089)" >&2
    return 0
  fi

  if [ -z "$events_json" ]; then
    if ! events_json=$(gather_pr_automation_events "$pr" "$repo"); then
      echo "  [suppress] PR #${pr} in ${repo} — budget events unavailable (API error); suppressing fail-closed" >&2
      return 0
    fi
  fi
  if pr_budget_exhausted "$events_json"; then
    echo "  [suppress] PR #${pr} in ${repo} exhausted its per-PR automation budget (MAX_PR_AUTOMATION_CYCLES=${MAX_PR_AUTOMATION_CYCLES}) since the last human interaction — not resuming (#926/#860)" >&2
    return 0
  fi

  return 1
}

# pr_budget_exhausted <events_json>
#   Exit 0 when the per-PR automation budget is spent.
pr_budget_exhausted() {
  local events_json="${1:-[]}"
  local n
  n=$(compute_pr_automation_cycles "$events_json")
  if [ "${n:-0}" -ge "${MAX_PR_AUTOMATION_CYCLES:-10}" ]; then
    return 0
  fi
  return 1
}

# gather_pr_automation_events <pr> <repo>
#   Assemble {when, login}[] from the PR's commits, issue comments, and reviews,
#   with the `agent_marked` and `mechanical` flags the header describes (#2224).
#   Bodies are tested here and not carried in the result.
#   Exits 1 (failure) when any GitHub API call fails so callers can distinguish
#   an unavailable result from a genuinely empty event list — critical for the
#   fail-closed budget gate in pr_resume_suppressed. Each gh call is captured
#   separately from jq so gh failures are not masked by jq succeeding on
#   empty/partial input. The PR-author lookup is the exception: without it no
#   event is flagged `mechanical`, which is the count as it was before #2224,
#   so its failure is not an error.
gather_pr_automation_events() {
  local pr="$1" repo="$2"
  local comments commits reviews api_error=0 _raw
  local mark_defs="$_PR_BUDGET_JQ_DEFS"'
    def flagged($re): if (.body | agent_marked($re)) then {agent_marked: true} else {} end;'
  if _raw=$(gh api --paginate "repos/${repo}/issues/${pr}/comments?per_page=100" 2>/dev/null); then
    comments=$(jq -s --arg re "$PR_BUDGET_AGENT_MARKER_RE" "$mark_defs"'
      [.[][] | {when: .created_at, login: (.user?.login // "")} + flagged($re)]' \
      <<< "$_raw" 2>/dev/null) || comments='[]'
  else
    api_error=1; comments='[]'
  fi
  if _raw=$(gh api --paginate "repos/${repo}/pulls/${pr}/commits?per_page=100" 2>/dev/null); then
    commits=$(jq -s '[.[][] | {when: (.commit?.author?.date // .commit?.committer?.date), login: (.author?.login // .commit?.author?.name // "")}]' \
      <<< "$_raw" 2>/dev/null) || commits='[]'
  else
    api_error=1; commits='[]'
  fi
  if _raw=$(gh api --paginate "repos/${repo}/pulls/${pr}/reviews?per_page=100" 2>/dev/null); then
    reviews=$(jq -s --arg re "$PR_BUDGET_AGENT_MARKER_RE" "$mark_defs"'
      [.[][] | {when: .submitted_at, login: (.user?.login // "")} + flagged($re)]' \
      <<< "$_raw" 2>/dev/null) || reviews='[]'
  else
    api_error=1; reviews='[]'
  fi
  if [ "$api_error" -ne 0 ]; then
    echo "  [warn] budget event collection incomplete for PR ${pr} in ${repo} — API unavailable" >&2
    return 1
  fi
  local events pr_author
  # Merged on stdin: three --argjson values would put a long PR's whole history
  # on jq's command line.
  events=$(printf '%s\n%s\n%s\n' "${comments:-[]}" "${commits:-[]}" "${reviews:-[]}" \
    | jq -c -s 'add // []' 2>/dev/null) || events='[]'
  pr_author=$(gh api "repos/${repo}/pulls/${pr}" --jq '.user.login // ""' 2>/dev/null) || pr_author=''
  events=$(pr_budget_flag_mechanical "$events" "$pr_author")
  _pr_budget_log_flags "$pr" "$repo" "$events"
  printf '%s\n' "$events"
}

# _pr_budget_log_flags <pr> <repo> <events_json>
#   One stderr line per kind of flagged event, so a run log shows why a count is
#   lower than the PR's bot activity suggests. Silent when nothing is flagged.
_pr_budget_log_flags() {
  local pr="$1" repo="$2" events_json="${3:-[]}" bots_json n_mech n_marked
  bots_json=$(printf '%s' "${AUTOMATION_BOT_LOGINS}" \
    | jq -R 'split(" ") | map(select(. != ""))' 2>/dev/null) || bots_json='[]'
  read -r n_mech n_marked < <(jq -r --argjson bots "$bots_json" "$_PR_BUDGET_JQ_DEFS"'
    [ ([.[] | select(.mechanical == true)] | length),
      ([.[] | select(.agent_marked == true and ((.login | is_bot($bots)) | not))] | length) ]
    | @tsv' <<<"$events_json" 2>/dev/null) || true
  if [ "${n_mech:-0}" -gt 0 ] 2>/dev/null; then
    echo "  [budget] PR #${pr} in ${repo}: ${n_mech} Dependabot-pipeline event(s) left out of the automation budget (#2224)" >&2
  fi
  if [ "${n_marked:-0}" -gt 0 ] 2>/dev/null; then
    echo "  [budget] PR #${pr} in ${repo}: ${n_marked} marker-carrying agent event(s) under a human login do not reset the automation budget (#2224)" >&2
  fi
  return 0
}

# pr_automation_already_escalated <pr> <repo>
#   Exit 0 if the exhaustion escalation comment is already present (dedupe).
pr_automation_already_escalated() {
  local pr="$1" repo="$2"
  if gh api --paginate "repos/${repo}/issues/${pr}/comments?per_page=100" 2>/dev/null \
      | jq -r '.[].body // ""' 2>/dev/null \
      | grep -qF "$PR_AUTOMATION_EXHAUSTION_MARKER"; then
    return 0
  fi
  return 1
}

# pr_automation_escalate <pr> <repo>
#   Post one deduped escalation, add needs-human-review, disable auto-merge.
#   Re-engagement is human-gated: only a human removing the label / acting on
#   the PR resets the budget (see compute_pr_automation_cycles).
pr_automation_escalate() {
  local pr="$1" repo="$2"
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ] || [ "${DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would escalate PR #${pr}: post budget-exhaustion comment, add needs-human-review, disable auto-merge"
    return 0
  fi
  if pr_automation_already_escalated "$pr" "$repo"; then
    echo "::notice::PR #${pr} already has a pr-automation-budget escalation — not re-posting"
    # An earlier label failure leaves the comment without the hold: repair it
    # (idempotent) and post the not-held note once if it still fails. Also
    # retry the auto-merge disable in case a prior label success was followed
    # by an auto-merge disable failure (#2151).
    if ! apply_hold_label "$repo" "$pr" "$NEEDS_HUMAN_REVIEW_LABEL"; then
      post_hold_failure_note "$repo" "$pr"
    fi
    disable_auto_merge_for_hold "$repo" "$pr" || true
    return 0
  fi
  # Label first so the comment can say when the PR could not be held (#2142).
  apply_hold_label "$repo" "$pr" "$NEEDS_HUMAN_REVIEW_LABEL" || true
  local body
  body="${PR_AUTOMATION_EXHAUSTION_MARKER}
## Automated activity budget exhausted — human attention needed

This PR has reached **${MAX_PR_AUTOMATION_CYCLES}** automated actions (agent commits + review cycles + acks) since the last human interaction, without converging. To prevent a runaway loop (see #926 / the #860 post-mortem), all automated commits, reviews, and acknowledgements on this PR are now **paused**, auto-merge is disabled, and \`needs-human-review\` is applied.

**Re-engaging is human-gated.** A human reviewing, commenting, or pushing to this PR resets the budget; a machine action will not. Removing \`needs-human-review\` after a human has looked is the clean way to resume.${HOLD_LABEL_NOTE}"
  if gh pr comment "$pr" --repo "$repo" --body "$body"; then
    PR_AUTOMATION_NEWLY_ESCALATED=true
  else
    echo "::warning::could not post budget-exhaustion comment on PR #${pr}"
  fi
  disable_auto_merge_for_hold "$repo" "$pr" || true
  return 0
}

# enforce_pr_budget <pr> <repo>
#   Returns 0 (exhausted — caller must STOP all automated writes) after
#   escalating once, or 1 (budget remains — proceed).
enforce_pr_budget() {
  local pr="$1" repo="$2"
  [ -n "$pr" ] && [ -n "$repo" ] || return 1
  local events
  # Set by pr_automation_escalate only when THIS call created the escalation
  # comment (not on dedupe, dry-run, or a failed post); callers read it to tell a
  # fresh escalation from a hold on an already-exhausted budget.
  # shellcheck disable=SC2034  # read by callers (review-one-pr.sh)
  PR_AUTOMATION_NEWLY_ESCALATED=false
  events=$(gather_pr_automation_events "$pr" "$repo")
  if pr_budget_exhausted "$events"; then
    echo "::warning::PR #${pr} reached MAX_PR_AUTOMATION_CYCLES=${MAX_PR_AUTOMATION_CYCLES} automated actions since the last human interaction — halting automation"
    pr_automation_escalate "$pr" "$repo"
    return 0
  fi
  return 1
}
