#!/usr/bin/env bash
set -euo pipefail
# dev-lead-intent.sh — Event classifier for the dev-lead agent.
#
# Reads GITHUB_EVENT_NAME and GITHUB_EVENT_PATH, classifies the event into
# an intent, and writes INTENT_TYPE / INTENT_REASON / INTENT_CONTEXT to
# GITHUB_ENV and GITHUB_OUTPUT.
#
# Intents:
#   fix-ci          — CI failure to auto-fix
#   fix-reviews     — Bot review comments to address
#   fix-bot-comment — Bot issue comment to address
#   on-mention       — Human-directed @mention task
#   review-changes   — Human review changes-requested
#   issue           — Issue labeled dev-lead
#   rebase          — Rebase conflict sentinel
#   enable-auto-merge — Bot approval: enable auto-merge if PR is APPROVED
#   ci-relay        — check_run relay (handled by ci-relay job, not this script)
#   skip            — Event should be ignored

# ── helpers ──────────────────────────────────────────────────────────────────

GITHUB_ENV="${GITHUB_ENV:-/dev/null}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

# Shared "human hold" predicate — one source of truth across the initiative
# driver, this intent classifier, and any retry/sweep path (#1595). A held
# issue/PR (needs-human-review / dev-lead:needs-human / dev-lead:hands-off) is
# never picked up, regardless of the event that would otherwise route it.
# shellcheck source=scripts/lib/hold-gate.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/hold-gate.sh"

# emit_hold_skip <blocking-label> [subject-number] — skip a held work item. The
# hands-off label keeps its historical `hands-off-label` reason; every other hold
# label reports `hold-label:<label>` so the specific hold is visible in the skip
# reason. The skip context also carries the blocking label and the subject number
# (#1767) so the workflow can post the one-time "held" notice — the specific
# blocking label is already known here at skip time and must be surfaced outside
# the run log. The reason strings are UNCHANGED (callers/tests depend on them).
emit_hold_skip() {
  local label="$1" subject="${2:-}" reason context
  case "$label" in
    dev-lead:hands-off) reason="hands-off-label" ;;
    *) reason="hold-label:$label" ;;
  esac
  context=$(jq -nc \
    --arg label "$label" \
    --argjson subject "${subject:-0}" \
    '{"hold_label":$label,"subject_number":$subject}')
  emit_intent "skip" "$reason" "$context"
}

emit_intent() {
  local intent="$1" reason="${2:-}" context="${3:-}"
  echo "INTENT_TYPE=${intent}" >> "$GITHUB_ENV"
  echo "INTENT_REASON=${reason}" >> "$GITHUB_ENV"
  echo "intent_type=${intent}" >> "$GITHUB_OUTPUT"
  echo "intent_reason=${reason}" >> "$GITHUB_OUTPUT"

  # Use a random delimiter for context to handle multiline JSON safely
  local EOF_DELIMITER
  EOF_DELIMITER="EOF_$(dd if=/dev/urandom bs=15 count=1 2>/dev/null | base64 | tr -dc 'a-zA-Z0-9')"

  {
    echo "INTENT_CONTEXT<<$EOF_DELIMITER"
    echo "${context}"
    echo "$EOF_DELIMITER"
  } >> "$GITHUB_ENV"

  {
    echo "intent_context<<$EOF_DELIMITER"
    echo "${context}"
    echo "$EOF_DELIMITER"
  } >> "$GITHUB_OUTPUT"

  echo "  [intent] type=${intent} reason=${reason} context=${context}"
}

emit_skip() {
  local reason="${1:-not-implemented}"
  emit_intent "skip" "$reason" ""
}

# is_trusted_bot <actor>
# Returns 0 (true) if actor is in the TRUSTED_BOTS comma-delimited list.
is_trusted_bot() {
  local actor="$1"
  local bots
  bots=$(echo "${TRUSTED_BOTS:-}" | tr ',' '\n')
  echo "$bots" | grep -qxF "$actor"
}

# is_human_trusted <author_association>
# Returns 0 (true) for OWNER, MEMBER, or COLLABORATOR associations.
is_human_trusted() {
  local assoc="$1"
  case "$assoc" in
    OWNER|MEMBER|COLLABORATOR) return 0 ;;
    *) return 1 ;;
  esac
}

# has_trigger_phrase <body>
# Returns 0 (true) if body contains any phrase from TRIGGER_PHRASES.
has_trigger_phrase() {
  local body="$1"
  local phrases
  phrases=$(echo "${TRIGGER_PHRASES:-@dev-lead}" | tr ',' '\n')
  while IFS= read -r phrase; do
    [ -z "$phrase" ] && continue
    if echo "$body" | grep -qF "$phrase"; then
      return 0
    fi
  done <<< "$phrases"
  return 1
}

# has_label <name>
# Returns 0 (true) if the PR or issue in the event payload carries label <name>.
# Reads labels straight from the payload (.pull_request.labels / .issue.labels),
# so it stays a pure classifier with no API calls. repository_dispatch payloads
# carry no labels; those are handled via a separate API call in the dispatch
# branch of the routing section.
has_label() {
  local name="$1"
  [ -n "$EVENT_PATH" ] && [ -f "$EVENT_PATH" ] || return 1
  jq -e --arg n "$name" '
    any(.pull_request.labels[]?, .issue.labels[]?; .name == $n)
  ' "$EVENT_PATH" >/dev/null 2>&1
}

# is_fork_pr <event_path>
# Returns 0 (true) if the PR head repo differs from GITHUB_REPOSITORY.
is_fork_pr() {
  local event_path="$1"
  local head_repo base_repo
  head_repo=$(jq -r '.pull_request.head.repo.full_name // .head.repo.full_name // empty' "$event_path" 2>/dev/null || true)
  base_repo="${GITHUB_REPOSITORY:-}"
  [ -n "$head_repo" ] && [ "$head_repo" != "$base_repo" ]
}

# is_dev_lead_authored
# Returns 0 (true) iff the PR in the event payload was authored by the dev-lead
# identity: its head branch matches `dev-lead/issue-*` OR the PR/issue author
# login equals BOT_USER. dev-lead's fix/push/merge intents must only ever act on
# PRs it authored — a review or bot comment on a human's in-flight PR must be
# left to the human (issue #1311: dev-lead drove a human PR to merge and dropped
# an unseen commit). FAILS CLOSED: any indeterminate state (no payload, or no
# head ref AND no author) returns 1, so callers skip rather than seize a PR whose
# ownership cannot be established.
is_dev_lead_authored() {
  [ -n "$EVENT_PATH" ] && [ -f "$EVENT_PATH" ] || return 1
  local head_ref author
  head_ref=$(jq -r '(.pull_request?.head?.ref // "" | tostring)' "$EVENT_PATH" 2>/dev/null || true)
  author=$(jq -r '(.pull_request?.user?.login // .issue?.user?.login // "" | tostring)' "$EVENT_PATH" 2>/dev/null || true)
  case "$head_ref" in
    dev-lead/issue-*) return 0 ;;
  esac
  [ -n "$author" ] && [ "$author" = "$BOT_USER" ] && return 0
  return 1
}

# matches_info_status_pattern <login> <body>
# Returns 0 (true) iff <login> is a registered reviewer source that declares an
# info_status_pattern and <body> matches it (case-sensitive, jq test() — the same
# classifier the maintainer-comment gate uses, #1918). Such a comment is a KNOWN
# CLEAN informational status re-post (e.g. Codex's "usage limits" notice) that
# carries no finding and needs no disposition, so dev-lead skips it BEFORE the
# engine runs instead of spending a fix-bot-comment run on a comment the gate
# already auto-clears (#1993). FAILS CLOSED to "no match" (returns 1) if the
# registry cannot be read or the login declares no pattern — an unclassifiable
# comment is then routed normally.
matches_info_status_pattern() {
  local login="$1" body="$2"
  local bare="${login%"[bot]"}"
  local reg_sh patterns pattern result
  reg_sh="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/reviewer-sources.sh"
  # A registry failure still fails closed (the comment routes normally), but it
  # is surfaced: a silent fallback would quietly bring back the engine run this
  # skip exists to save.
  if [ ! -f "$reg_sh" ]; then
    echo "::warning::dev-lead-intent: reviewer-sources helper not found at $reg_sh — info-status skip disabled, routing normally" >&2
    return 1
  fi
  # Source in a subshell so the registry helper never leaks into this classifier.
  if ! patterns="$(
    # shellcheck source=scripts/lib/reviewer-sources.sh
    source "$reg_sh" 2>/dev/null && reviewer_sources_info_status_patterns 2>/dev/null
  )"; then
    echo "::warning::dev-lead-intent: could not read info_status patterns from the reviewer-sources registry — info-status skip disabled, routing normally" >&2
    return 1
  fi
  pattern="$(printf '%s\n' "$patterns" | awk -F'\t' -v l="$bare" '$1==l {print $2; exit}')" || return 1
  [ -n "$pattern" ] || return 1
  if ! result="$(jq -nr --arg b "$body" --arg p "$pattern" '($b | test($p))' 2>/dev/null)"; then
    echo "::warning::dev-lead-intent: info_status_pattern for ${bare} failed to evaluate — routing normally" >&2
    return 1
  fi
  [ "$result" = "true" ]
}

# classify_bot_comment_retry <pr_number>
# Routes a `dev-lead-reviews-retry` dispatch with intent_type=fix-bot-comment
# (#2017). Re-fetches the comment named by client_payload.comment_node_id BY NODE
# ID and emits fix-bot-comment with its CURRENT body, or a skip when the retry is
# no longer needed or allowed. Fails closed (skip) whenever the comment cannot be
# read or does not belong to this PR.
classify_bot_comment_retry() {
  local pr_number="$1"
  local node_id node login typename body pr_of pr_repo state cross_repo pr_author minimized reason version
  node_id=$(jq -r '.client_payload.comment_node_id // empty' "$EVENT_PATH" 2>/dev/null || true)
  # Same well-formed-node-id rule the workflow applies before exporting it.
  if [[ ! "$node_id" =~ ^[-A-Za-z0-9_+/=]+$ ]]; then
    emit_skip "bot-comment-retry-no-node-id"
    return 0
  fi

  # shellcheck disable=SC2016  # $id is a GraphQL variable placeholder, not shell
  node=$(gh api graphql -f query='query($id:ID!){node(id:$id){... on IssueComment{
      id author{login __typename} body createdAt lastEditedAt isMinimized minimizedReason
      pullRequest{number state isCrossRepository author{login} repository{nameWithOwner}} }}}' \
    -f id="$node_id" 2>/dev/null | jq -ce '.data.node | objects | select(.id != null)' 2>/dev/null) || node=""
  if [ -z "$node" ]; then
    emit_skip "bot-comment-retry-fetch-failed"
    return 0
  fi
  login=$(jq -r '.author.login // ""' <<< "$node")
  typename=$(jq -r '.author.__typename // ""' <<< "$node")
  body=$(jq -r '.body // ""' <<< "$node")
  pr_of=$(jq -r '.pullRequest.number // ""' <<< "$node")
  pr_repo=$(jq -r '.pullRequest.repository.nameWithOwner // ""' <<< "$node")
  state=$(jq -r '.pullRequest.state // ""' <<< "$node")
  # Only an explicit `false` is a same-repository head; missing data fails closed.
  cross_repo=$(jq -r 'if .pullRequest.isCrossRepository == false then "false" else "true" end' <<< "$node")
  pr_author=$(jq -r '.pullRequest.author.login // ""' <<< "$node")
  version=$(jq -r '.lastEditedAt // .createdAt // ""' <<< "$node")
  minimized=$(jq -r 'if .isMinimized == true then (.minimizedReason // "" | ascii_downcase) else "" end' <<< "$node")

  # The comment must be on THIS PR of THIS repository — a payload cannot aim a pass
  # at another PR's comment, nor at a same-numbered PR in another repository.
  if [ "$pr_of" != "$pr_number" ] || [ -z "$pr_repo" ] || [ "$pr_repo" != "${GITHUB_REPOSITORY:-}" ]; then
    emit_skip "bot-comment-retry-pr-mismatch"
    return 0
  fi
  if [ "$state" != "OPEN" ]; then
    emit_skip "pr-already-closed"
    return 0
  fi
  # GraphQL reports a bot's login without the [bot] suffix the webhook uses.
  login="${login%"[bot]"}"
  # Only a genuine Bot author: a missing or unknown type fails closed.
  if [ -z "$login" ] || [ "$typename" != "Bot" ] || ! is_trusted_bot "${login}[bot]"; then
    emit_skip "bot-comment-retry-untrusted-author"
    return 0
  fi
  # Authorship gate (#1311), from the PR the comment belongs to: dev-lead must be
  # the PR's AUTHOR and the head must live in this repository. The branch name is
  # never evidence of ownership — any contributor (or fork) can choose it.
  if [ -z "$pr_author" ] || [ "$pr_author" != "$BOT_USER" ] || [ "$cross_repo" != "false" ]; then
    emit_skip "not-dev-lead-authored"
    return 0
  fi
  # A RESOLVED comment is done unless it was edited since: the gate re-blocks one
  # edited after its newest disposition (#2008), so the decision below decides
  # whether it still needs a pass (#2166).
  if [ "$minimized" = "resolved" ] && [ "$(jq -r '.lastEditedAt // ""' <<< "$node")" = "" ]; then
    emit_skip "bot-comment-already-resolved"
    return 0
  fi
  if matches_info_status_pattern "$login" "$body"; then
    emit_skip "info-status-notice"
    return 0
  fi

  # Cheap no-op when the work is already done: a covering disposition (or a
  # completed fix-bot-comment pass) on the comment's current version — e.g. the
  # original event-driven run finished while this retry was queued behind it.
  # Fails closed: when the PR's disposition state cannot be read, skip rather than
  # run a remediation pass blind. The sweep's retry marker stays pending, so the
  # next attempt follows after the pending window.
  reason=$(
    # shellcheck source=scripts/lib/bot-comment-retry.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bot-comment-retry.sh" 2>/dev/null \
      || { echo "state-unreadable"; exit 0; }
    comments=$(bcr_fetch_pr_comments "$GITHUB_REPOSITORY" "$pr_number") \
      || { echo "state-unreadable"; exit 0; }
    # Dispositions and pass markers are dev-lead's own (BOT_USER) — no other
    # author's marker may suppress the pass.
    decisions=$(bcr_retry_decisions "$comments" "$TRUSTED_BOTS" '{}' "$(date -u +%s)" "$BOT_USER" 2>/dev/null) \
      || { echo "state-unreadable"; exit 0; }
    jq -r --arg id "$node_id" 'first(.[] | select(.id == $id)) | .reason // ""' <<< "$decisions" 2>/dev/null \
      || echo "state-unreadable"
  ) || reason="state-unreadable"
  case "$reason" in
    dispositioned)    emit_skip "bot-comment-already-dispositioned"; return 0 ;;
    pass-completed)   emit_skip "bot-comment-pass-completed"; return 0 ;;
    state-unreadable) emit_skip "bot-comment-retry-state-unreadable"; return 0 ;;
  esac
  # An edited RESOLVED comment the decision does not list has a disposition newer
  # than its edit: the gate still clears it.
  if [ "$minimized" = "resolved" ] && [ -z "$reason" ]; then
    emit_skip "bot-comment-already-resolved"
    return 0
  fi

  # Same context shape as the issue_comment path: no head_sha, so the pass
  # resolves the PR's CURRENT head at run time rather than the sweep-time one.
  # comment_version is the version of THIS body — the pass stamps it on its
  # terminal marker, so an edit made while it runs is not mistaken as processed.
  local context
  context=$(jq -nc \
    --argjson pr_number "$pr_number" \
    --arg actor "${login}[bot]" \
    --arg body "$body" \
    --arg comment_node_id "$node_id" \
    --arg comment_version "$version" \
    '{"pr_number":$pr_number,"actor":$actor,"body":$body,"comment_node_id":$comment_node_id,"comment_version":$comment_version}')
  emit_intent "fix-bot-comment" "bot-comment-retry-dispatch" "$context"
}

# ── read event ───────────────────────────────────────────────────────────────

EVENT_NAME="${GITHUB_EVENT_NAME:-}"
EVENT_PATH="${GITHUB_EVENT_PATH:-}"
BOT_USER="${BOT_USER:-donpetry-bot}"

# TRUSTED_BOTS: the webhook-facing set of review bots dev-lead may act on. When
# unset/empty, derive it from the reviewer-source registry (scripts/lib/reviewer-
# sources.tsv) so this list can never drift from the gate/scorecard again — the
# #1425 fix that unblocks graphite-app/qodo-code-review/codeant-ai threads. The
# literal is a fallback for when the registry helper cannot be sourced.
if [ -z "${TRUSTED_BOTS:-}" ]; then
  _reg_sh="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/reviewer-sources.sh"
  # shellcheck source=scripts/lib/reviewer-sources.sh
  if [ -f "$_reg_sh" ]; then
    source "$_reg_sh" || { echo "::error::dev-lead-intent: failed to source reviewer-sources registry at $_reg_sh" >&2; exit 1; }
    TRUSTED_BOTS="$(reviewer_sources_trusted_bots_csv)" || { echo "::error::dev-lead-intent: reviewer_sources_trusted_bots_csv failed — registry may be malformed" >&2; exit 1; }
    if [ -z "$TRUSTED_BOTS" ]; then
      echo "::error::dev-lead-intent: reviewer_sources_trusted_bots_csv returned empty — registry has no trusted bots" >&2
      exit 1
    fi
  fi
fi
TRUSTED_BOTS="${TRUSTED_BOTS:-copilot-pull-request-reviewer[bot],gemini-code-assist[bot],sonarqubecloud[bot],coderabbitai[bot],chatgpt-codex-connector[bot],qodo-code-review[bot],codeant-ai[bot],graphite-app[bot],cubic-dev-ai[bot]}"
TRIGGER_PHRASES="${TRIGGER_PHRASES:-@dev-lead}"

if [ -z "$EVENT_NAME" ]; then
  echo "::error::GITHUB_EVENT_NAME is not set"
  exit 1
fi

echo "dev-lead-intent: processing event=$EVENT_NAME"

# ── check_run: not handled here (ci-relay job) ───────────────────────────────

if [ "$EVENT_NAME" = "check_run" ]; then
  emit_skip "check-run-handled-by-ci-relay"
  exit 0
fi

# ── hold guard ────────────────────────────────────────────────────────────────
# A PR or issue carrying a fleet hold label (dev-lead:hands-off, needs-human-
# review, dev-lead:needs-human) is intentionally excluded from the agent. This is
# the label-triggered half of #1595: even if `dev-lead` is applied to a held
# issue (bypassing or racing the driver), the agent must not pick it up — #1532
# was released to dev-lead with `needs-human-review` still attached. hands-off
# keeps its historical purpose (e.g. PRs that modify the dev-lead workflow itself,
# so the agent does not pile commits onto its own infrastructure). Runs before the
# anti-loop guard so a hold sync from BOT_USER emits the hold reason rather than
# `dev-lead-own-commit`, keeping the skip reason stable whenever a hold is present.
# Applies to every label-bearing event (PR opens/syncs, reviews, review comments,
# issue comments on PRs, issue labeling). repository_dispatch payloads carry no
# labels; those are checked via the API in the dispatch branch below.
_event_labels=""
if [ -n "$EVENT_PATH" ] && [ -f "$EVENT_PATH" ]; then
  _event_labels="$(jq -r '[.pull_request.labels[]?, .issue.labels[]?] | .[].name' "$EVENT_PATH" 2>/dev/null || true)"
fi
if _hold_label="$(hold_gate_first_match "$_event_labels")"; then
  # The subject number lets the workflow post the one-time hold notice (#1767).
  _hold_subject=""
  if [ -n "$EVENT_PATH" ] && [ -f "$EVENT_PATH" ]; then
    _hold_subject="$(jq -r '.pull_request.number // .issue.number // empty' "$EVENT_PATH" 2>/dev/null || true)"
  fi
  emit_hold_skip "$_hold_label" "$_hold_subject"
  exit 0
fi
unset _event_labels _hold_label _hold_subject

# ── anti-loop guard: pull_request synchronize ────────────────────────────────
# If the synchronize event was triggered by BOT_USER's own commit, skip to
# prevent an infinite fix → push → trigger → fix loop.

if [ "$EVENT_NAME" = "pull_request" ] && [ -n "$EVENT_PATH" ] && [ -f "$EVENT_PATH" ]; then
  pr_action=$(jq -r '.action // empty' "$EVENT_PATH" 2>/dev/null || true)
  if [ "$pr_action" = "synchronize" ]; then
    sender_login=$(jq -r '.sender.login // empty' "$EVENT_PATH" 2>/dev/null || true)
    if [ "$sender_login" = "$BOT_USER" ]; then
      emit_skip "dev-lead-own-commit"
      exit 0
    fi
  fi
fi

# ── routing ───────────────────────────────────────────────────────────────────

case "$EVENT_NAME" in

  # ── pull_request ─────────────────────────────────────────────────────────
  pull_request)
    if [ -z "$EVENT_PATH" ] || [ ! -f "$EVENT_PATH" ]; then
      emit_skip "no-event-path"
      exit 0
    fi
    pr_action=$(jq -r '.action // empty' "$EVENT_PATH" 2>/dev/null || true)
    sender_login=$(jq -r '.sender.login // empty' "$EVENT_PATH" 2>/dev/null || true)
    pr_number=$(jq -r '.pull_request.number // .number // empty' "$EVENT_PATH" 2>/dev/null || true)
    head_sha=$(jq -r '.pull_request.head.sha // empty' "$EVENT_PATH" 2>/dev/null || true)

    case "$pr_action" in
      opened|reopened)
        # Skip forks and bot PRs
        if is_fork_pr "$EVENT_PATH"; then
          emit_skip "fork-pr"
          exit 0
        fi
        if [[ "$sender_login" == *"[bot]"* ]] || [[ "$sender_login" == "dependabot"* ]]; then
          emit_skip "bot-pr"
          exit 0
        fi
        # Authorship gate (#1311): only act on PRs dev-lead authored. A human's
        # own PR is theirs to finish — dev-lead must not seize and drive it.
        if ! is_dev_lead_authored; then
          emit_skip "not-dev-lead-authored"
          exit 0
        fi
        context=$(jq -nc \
          --argjson pr_number "${pr_number:-0}" \
          --arg head_sha "${head_sha:-}" \
          --arg actor "${sender_login:-}" \
          '{"pr_number":$pr_number,"head_sha":$head_sha,"actor":$actor}')
        emit_intent "review-changes" "pr-${pr_action}" "$context"
        ;;
      synchronize)
        # Anti-loop already handled above; now route human syncs
        if [[ "$sender_login" == *"[bot]"* ]]; then
          emit_skip "bot-sync"
          exit 0
        fi
        # Authorship gate (#1311): a human pushing to their own PR keeps it.
        if ! is_dev_lead_authored; then
          emit_skip "not-dev-lead-authored"
          exit 0
        fi
        context=$(jq -nc \
          --argjson pr_number "${pr_number:-0}" \
          --arg head_sha "${head_sha:-}" \
          --arg actor "${sender_login:-}" \
          '{"pr_number":$pr_number,"head_sha":$head_sha,"actor":$actor}')
        emit_intent "review-changes" "pr-synchronize" "$context"
        ;;
      *)
        emit_skip "pr-action-not-routed"
        ;;
    esac
    ;;

  # ── pull_request_review ───────────────────────────────────────────────────
  pull_request_review)
    if [ -z "$EVENT_PATH" ] || [ ! -f "$EVENT_PATH" ]; then
      emit_skip "no-event-path"
      exit 0
    fi
    reviewer=$(jq -r '.review.user.login // empty' "$EVENT_PATH" 2>/dev/null || true)
    review_body=$(jq -r '.review.body // empty' "$EVENT_PATH" 2>/dev/null || true)
    review_state=$(jq -r '.review.state // empty' "$EVENT_PATH" 2>/dev/null || true)
    pr_number=$(jq -r '.pull_request.number // empty' "$EVENT_PATH" 2>/dev/null || true)
    head_sha=$(jq -r '.pull_request.head.sha // empty' "$EVENT_PATH" 2>/dev/null || true)
    # Reviewer-trust gate (#1417): read the REVIEWER's association from .review,
    # not the PR author's from .pull_request. On a dev-lead-authored PR the author
    # is always dev-lead's own OWNER identity, so gating on the PR author made
    # is_human_trusted always true and the untrusted-reviewer skip dead code.
    # `.review?` + `// "" | tostring` keeps the gate fail-closed: a missing or
    # null reviewer association produces an empty string that is_human_trusted
    # rejects (returns false → skip).
    reviewer_assoc=$(jq -r '(.review?.author_association // "" | tostring)' "$EVENT_PATH")

    # Skip if actor is BOT_USER (self-review)
    if [ "$reviewer" = "$BOT_USER" ]; then
      pr_number=$(jq -r '.pull_request.number // empty' "$EVENT_PATH" 2>/dev/null || true)
      context=$(jq -nc --argjson pr_number "${pr_number:-0}" '{"pr_number":$pr_number}')
      emit_intent "skip" "self-review" "$context"
      exit 0
    fi

    # Skip fork PRs
    if is_fork_pr "$EVENT_PATH"; then
      emit_skip "fork-pr"
      exit 0
    fi

    # Authorship gate (#1311): a review — from a trusted bot OR a trusted human —
    # only drives dev-lead's fix/push/merge path on a PR dev-lead authored. On a
    # human's in-flight PR, dev-lead stays out (it may still advise, but never
    # pushes or merges). Fails closed on indeterminate authorship.
    if ! is_dev_lead_authored; then
      emit_skip "not-dev-lead-authored"
      exit 0
    fi

    context=$(jq -nc \
      --argjson pr_number "${pr_number:-0}" \
      --arg head_sha "${head_sha:-}" \
      --arg actor "${reviewer:-}" \
      --arg body "${review_body:-}" \
      '{"pr_number":$pr_number,"head_sha":$head_sha,"actor":$actor,"body":$body}')

    if is_trusted_bot "$reviewer"; then
      if [ "$review_state" = "APPROVED" ]; then
        emit_intent "enable-auto-merge" "bot-approved" "$context"
      else
        emit_intent "fix-reviews" "bot-review-${review_state}" "$context"
      fi
    elif is_human_trusted "$reviewer_assoc"; then
      emit_intent "review-changes" "human-review-${review_state}" "$context"
    else
      emit_skip "untrusted-reviewer"
    fi
    ;;

  # ── pull_request_review_comment ───────────────────────────────────────────
  pull_request_review_comment)
    if [ -z "$EVENT_PATH" ] || [ ! -f "$EVENT_PATH" ]; then
      emit_skip "no-event-path"
      exit 0
    fi
    commenter=$(jq -r '.comment.user.login // empty' "$EVENT_PATH" 2>/dev/null || true)
    comment_body=$(jq -r '.comment.body // empty' "$EVENT_PATH" 2>/dev/null || true)
    pr_number=$(jq -r '.pull_request.number // empty' "$EVENT_PATH" 2>/dev/null || true)
    head_sha=$(jq -r '.pull_request.head.sha // empty' "$EVENT_PATH" 2>/dev/null || true)
    author_assoc=$(jq -r '.comment.author_association // empty' "$EVENT_PATH" 2>/dev/null || true)

    context=$(jq -nc \
      --argjson pr_number "${pr_number:-0}" \
      --arg head_sha "${head_sha:-}" \
      --arg actor "${commenter:-}" \
      --arg body "${comment_body:-}" \
      '{"pr_number":$pr_number,"head_sha":$head_sha,"actor":$actor,"body":$body}')

    if is_trusted_bot "$commenter"; then
      # Authorship gate (#1311): a bot review comment only drives dev-lead's
      # auto-fix/push on a PR dev-lead authored. On a human's PR it is advisory.
      if ! is_dev_lead_authored; then
        emit_skip "not-dev-lead-authored"
        exit 0
      fi
      emit_intent "fix-reviews" "bot-review-comment" "$context"
    elif is_human_trusted "$author_assoc" && has_trigger_phrase "$comment_body"; then
      # on-mention is an explicit human request (@dev-lead) — direct
      # authorization — so it is exempt from the authorship gate.
      emit_intent "on-mention" "human-review-comment-trigger" "$context"
    else
      emit_skip "no-trigger-or-untrusted"
    fi
    ;;

  # ── issue_comment ─────────────────────────────────────────────────────────
  issue_comment)
    if [ -z "$EVENT_PATH" ] || [ ! -f "$EVENT_PATH" ]; then
      emit_skip "no-event-path"
      exit 0
    fi
    # Only handle comments on PRs (issues with pull_request field)
    is_pr=$(jq -r '.issue.pull_request // empty' "$EVENT_PATH" 2>/dev/null || true)
    if [ -z "$is_pr" ]; then
      emit_skip "not-a-pr-comment"
      exit 0
    fi

    # Skip comments on closed/merged PRs — nothing to modify on a merged branch.
    # This is a fast-path guard; checkout_pr_in_worktree provides a deeper safety
    # net, but failing early here avoids spending tokens on a no-op run (issue #405).
    pr_state=$(jq -r '.issue.state // empty' "$EVENT_PATH" 2>/dev/null || true)
    if [[ "${pr_state:-}" == "closed" ]]; then
      emit_skip "pr-already-closed"
      exit 0
    fi

    commenter=$(jq -r '.comment.user.login // empty' "$EVENT_PATH" 2>/dev/null || true)
    comment_body=$(jq -r '.comment.body // empty' "$EVENT_PATH" 2>/dev/null || true)
    pr_number=$(jq -r '.issue.number // empty' "$EVENT_PATH" 2>/dev/null || true)
    author_assoc=$(jq -r '.comment.author_association // empty' "$EVENT_PATH" 2>/dev/null || true)
    # The triggering comment's GraphQL node id — fix-bot-comment targets its
    # disposition by id instead of re-matching the raw body in a shell command.
    comment_node_id=$(jq -r '.comment.node_id // empty' "$EVENT_PATH" 2>/dev/null || true)
    # The version of the body this event carries (#2017): fix-bot-comment stamps it
    # on its terminal marker so the bot-comment retry knows which edit was processed.
    # A new comment's version is exactly its created_at (GraphQL createdAt); an
    # edited one's is updated_at (≈ lastEditedAt, matched within a small skew).
    comment_version=$(jq -r 'if .action == "created" then (.comment.created_at // empty)
                             else (.comment.updated_at // .comment.created_at // empty) end' \
      "$EVENT_PATH" 2>/dev/null || true)

    # Rebase sentinel check (highest priority, before bot-skip)
    if echo "$comment_body" | grep -qF "<!-- auto-rebase-conflict:"; then
      context=$(printf '{"pr_number":%s}' "${pr_number:-0}")
      emit_intent "rebase" "rebase-conflict-sentinel" "$context"
      exit 0
    fi

    # Skip self (BOT_USER) unless it's the rebase sentinel
    if [ "$commenter" = "$BOT_USER" ]; then
      emit_skip "self-comment"
      exit 0
    fi

    context=$(jq -nc \
      --argjson pr_number "${pr_number:-0}" \
      --arg actor "${commenter:-}" \
      --arg body "${comment_body:-}" \
      --arg comment_node_id "${comment_node_id:-}" \
      --arg comment_version "${comment_version:-}" \
      '{"pr_number":$pr_number,"actor":$actor,"body":$body,"comment_node_id":$comment_node_id,"comment_version":$comment_version}')

    if is_trusted_bot "$commenter"; then
      # Authorship gate (#1311): a bot comment only drives dev-lead's auto-fix/
      # push on a PR dev-lead authored (author == BOT_USER; issue_comment
      # payloads carry no head ref). On a human's PR it is advisory. The rebase
      # sentinel above and the on-mention branch below are intentionally exempt.
      if ! is_dev_lead_authored; then
        emit_skip "not-dev-lead-authored"
        exit 0
      fi
      # #1993: a KNOWN CLEAN info-status notice from a registered source (e.g.
      # Codex's "usage limits" notice) carries no finding, and the maintainer-
      # comment gate already auto-clears it (#1918). Skip BEFORE the engine runs
      # so dev-lead does not spend a fix-bot-comment pass dispositioning a comment
      # the gate treats as addressed. Only this issue-comment path is scoped —
      # Codex's findings arrive as reviews / inline review comments (fix-reviews),
      # which never match this pattern and must still be addressed.
      if matches_info_status_pattern "$commenter" "$comment_body"; then
        emit_skip "info-status-notice"
        exit 0
      fi
      emit_intent "fix-bot-comment" "trusted-bot-comment" "$context"
    elif is_human_trusted "$author_assoc" && has_trigger_phrase "$comment_body"; then
      emit_intent "on-mention" "human-comment-trigger" "$context"
    else
      emit_skip "no-trigger-or-untrusted"
    fi
    ;;

  # ── issues ────────────────────────────────────────────────────────────────
  issues)
    if [ -z "$EVENT_PATH" ] || [ ! -f "$EVENT_PATH" ]; then
      emit_skip "no-event-path"
      exit 0
    fi
    issues_action=$(jq -r '.action // empty' "$EVENT_PATH" 2>/dev/null || true)
    if [ "$issues_action" != "labeled" ]; then
      emit_skip "issues-not-labeled"
      exit 0
    fi
    label_name=$(jq -r '.label.name // empty' "$EVENT_PATH" 2>/dev/null || true)
    issue_number=$(jq -r '.issue.number // empty' "$EVENT_PATH" 2>/dev/null || true)
    case "$label_name" in
      dev-lead)
        context=$(printf '{"issue_number":%s}' "${issue_number:-0}")
        emit_intent "issue" "issue-labeled-${label_name}" "$context"
        ;;
      *)
        emit_skip "label-not-dev-lead"
        ;;
    esac
    ;;

  # ── repository_dispatch ───────────────────────────────────────────────────
  repository_dispatch)
    if [ -z "$EVENT_PATH" ] || [ ! -f "$EVENT_PATH" ]; then
      emit_skip "no-event-path"
      exit 0
    fi
    dispatch_type=$(jq -r '.action // empty' "$EVENT_PATH" 2>/dev/null || true)
    pr_number=$(jq -r '.client_payload.pr_number // empty' "$EVENT_PATH" 2>/dev/null || true)
    issue_number=$(jq -r '.client_payload.issue_number // empty' "$EVENT_PATH" 2>/dev/null || true)
    head_sha=$(jq -r '.client_payload.head_sha // empty' "$EVENT_PATH" 2>/dev/null || true)

    # The subject whose labels gate hands-off. PR-based dispatch types carry
    # pr_number; the issue-retry type (#781) carries issue_number instead. Both
    # resolve under repos/<repo>/issues/<n>/labels (PRs are issues for labels),
    # so an issue-only payload is no longer dropped before routing.
    subject_number="${pr_number:-$issue_number}"
    if [ -z "$subject_number" ]; then
      emit_skip "no-subject-number-in-payload"
      exit 0
    fi

    # Honour the hold gate for dispatch events: the event payload carries no
    # labels, so fetch them via the API before routing. Fail closed: if the API
    # call fails (auth error, transient failure, token without label read access),
    # skip rather than route with unknown label state.
    _dispatch_labels=""
    if ! _dispatch_labels=$(gh api "repos/${GITHUB_REPOSITORY}/issues/${subject_number}/labels" \
        --paginate --jq '.[].name' 2>/dev/null); then
      emit_skip "label-lookup-error"
      exit 0
    fi
    if _hold_label="$(hold_gate_first_match "$_dispatch_labels")"; then
      emit_hold_skip "$_hold_label" "$subject_number"
      exit 0
    fi
    unset _dispatch_labels _hold_label

    case "$dispatch_type" in
      dev-lead-ci-failure)
        if [ -z "$pr_number" ]; then
          emit_skip "no-pr-number-in-payload"
          exit 0
        fi
        checks=$(jq -c '.client_payload.checks // []' "$EVENT_PATH" 2>/dev/null || echo "[]")
        context=$(jq -nc \
          --argjson pr_number "$pr_number" \
          --arg head_sha "${head_sha:-}" \
          --argjson checks "$checks" \
          '{"pr_number":$pr_number,"head_sha":$head_sha,"checks":$checks}')
        emit_intent "fix-ci" "ci-failure-dispatch" "$context"
        ;;
      dev-lead-reviews-retry)
        if [ -z "$pr_number" ]; then
          emit_skip "no-pr-number-in-payload"
          exit 0
        fi
        intent_type=$(jq -r '.client_payload.intent_type // empty' "$EVENT_PATH" 2>/dev/null || true)
        case "$intent_type" in
          fix-bot-comment)
            # Undispositioned bot-comment retry (#2017, dev-lead-retry.sh). The
            # payload names the comment by node id only; its body is NEVER taken
            # from the payload. Re-fetch the comment's CURRENT (possibly edited)
            # body, author and lastEditedAt by that id and re-check every
            # precondition the issue_comment path applies, since the PR may have
            # moved on while the retry was queued.
            classify_bot_comment_retry "$pr_number"
            ;;
          fix-reviews|on-mention|review-changes|rebase)
            context=$(jq -nc \
              --argjson pr_number "$pr_number" \
              --arg head_sha "${head_sha:-}" \
              '{"pr_number":$pr_number,"head_sha":$head_sha}')
            emit_intent "$intent_type" "reviews-retry-dispatch" "$context"
            ;;
          human-pr)
            # Legacy alias: human-pr was renamed to review-changes.
            context=$(jq -nc \
              --argjson pr_number "$pr_number" \
              --arg head_sha "${head_sha:-}" \
              '{"pr_number":$pr_number,"head_sha":$head_sha}')
            emit_intent "review-changes" "reviews-retry-dispatch" "$context"
            ;;
          *)
            emit_skip "unknown-reviews-retry-intent-type"
            ;;
        esac
        ;;
      dev-lead-issue-retry)
        # Bounded auto-retry of a failed initial issue implementation (#781). The
        # payload is issue-only (no PR exists yet); route to the existing `issue`
        # intent so the same handler re-runs the implementation. The issue
        # handler re-derives all context fresh from the issue, so a re-dispatch
        # has full fidelity (like the PR-side retryable intents).
        if [ -z "$issue_number" ]; then
          emit_skip "no-issue-number-in-payload"
          exit 0
        fi
        context=$(printf '{"issue_number":%s}' "$issue_number")
        emit_intent "issue" "issue-retry-dispatch" "$context"
        ;;
      *)
        emit_skip "unknown-dispatch-type"
        ;;
    esac
    ;;

  # ── everything else ───────────────────────────────────────────────────────
  *)
    emit_skip "not-implemented"
    ;;

esac
