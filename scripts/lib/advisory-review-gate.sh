#!/usr/bin/env bash
# Advisory Bot Review Gate
#
# Instant check (non-blocking) for advisory bot reviews.
# Instead of polling for 60 minutes, this script checks the current state
# of bot reviews and returns immediately. The pr-review workflow will be
# re-triggered when bots submit their reviews (pull_request_review event).
#
# This design avoids GitHub Actions billing for long-running workflow blocks.
# Cost: $0.008/min × 1-2 min checks vs. $0.008/min × 60 min blocks
#
# This gate ensures valid code reviews are incorporated before approval, addressing:
# - Issue #457: Advisory bots finishing after pr-review approval
# - PR #453 incident: Copilot review arriving 43 seconds too late
#
# Usage:
#   check_advisory_reviews "$PR_URL"
#
# Returns:
#   0 = All detected advisory bots have submitted (ready to approve)
#   1 = Waiting for bots (defer approval, will re-check on next bot review)
#
# Environment:
#   GH_TOKEN (set by calling workflow)
#   PR_URL (passed as argument)

set -euo pipefail

# ── Reviewer-source registry (single source of truth, #1425) ─────────────────
# Source the registry helper so ADVISORY_BOTS is a projection of
# reviewer-sources.tsv (advisory_gate=yes rows), not a hardcoded list.
# Built-in fallback set, used when the registry is absent (stripped test env or
# very early boot) OR unreadable (transient read failure). This gate is *sourced*
# into long-running review processes and the whole test suite, so a recoverable
# registry-read failure must degrade to this list — never `exit`, which would kill
# the caller and strand every PR review (and intermittently failed the unit suite,
# the #1538 DEGRADED signal). Kept in sync with reviewer-sources.tsv
# (advisory_gate=yes) by tests/test_reviewer_sources.bats.
_advisory_gate_load_fallback_bots() {
  # shellcheck disable=SC2034
  # Advisory-wait set is 5 since #1997 dropped copilot-pull-request-reviewer,
  # chatgpt-codex-connector and qodo-code-review (zero countable reviews across eight
  # consecutive PRs, measured 2026-09-23). They stay dev-lead-trusted and on the
  # scorecard (see RATE_LIMIT_NOTICE_BOTS below — still ALL sources); they leave only
  # this approval-wait set.
  declare -gA ADVISORY_BOTS=(
    [gemini-code-assist]="Gemini Code Assist (advisory)"
    [sonarqubecloud]="SonarCloud (advisory)"
    [codeant-ai]="CodeAnt (advisory)"
    [graphite-app]="Graphite (advisory)"
    [cubic-dev-ai]="cubic (advisory)"
  )
}

_gate_reg_sh="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reviewer-sources.sh"
if [ -f "$_gate_reg_sh" ]; then
  # shellcheck source=scripts/lib/reviewer-sources.sh
  source "$_gate_reg_sh"
  # shellcheck disable=SC2034
  declare -A ADVISORY_BOTS=()
  if _adv_logins="$(reviewer_sources_advisory_gate_logins)"; then
    while IFS= read -r _adv_login; do
      if [ -n "$_adv_login" ]; then
        ADVISORY_BOTS[$_adv_login]="$_adv_login (advisory)"
      fi
    done <<< "$_adv_logins"
  fi
  # If the read failed or produced nothing, degrade to the built-in set rather
  # than leaving the gate with zero advisory bots (or exiting the caller).
  if [ "${#ADVISORY_BOTS[@]}" -eq 0 ]; then
    echo "advisory-review-gate: reviewer_sources_advisory_gate_logins unavailable — using built-in advisory-bot fallback" >&2
    _advisory_gate_load_fallback_bots
  fi
  unset _adv_login _adv_logins
else
  _advisory_gate_load_fallback_bots
fi
unset _gate_reg_sh

# Canonical rate-limit / out-of-quota body pattern — the SINGLE source of truth
# for "this bot is itself rate-limited". Three call sites reuse this one regex so
# they cannot drift (issue #1349 follow-up): the gate's get_advisory_bot_states()
# classifies a comment RATE_LIMITED, detect_advisory_rate_limit() arms the sweep
# retry, and scripts/reviewer_report.sh (via RATE_LIMIT_RE) counts scorecard
# refusals. Case-insensitive matching is applied by every consumer. It blends
# generic quota phrasing with the bot-specific notices we have observed:
#   - CodeRabbit: "Review limit reached" / "used up its prepaid credits"
#   - Codex:      "reached your Codex usage limits"
#   - Qodo Merge: "reached your monthly usage limit" / "monthly PR limit" (#1349)
#   - CodeAnt:    "free trial limit reached" (capped free trial, #1349)
# Kept reasonably specific so a genuine review that mentions "rate limit" in
# passing does not arm a retry.
# shellcheck disable=SC2034
readonly ADVISORY_RATE_LIMIT_RE='usage limit|rate[-_ ]?limit|too many requests|quota (exceeded|reached|exhausted)|out of (quota|credits|tokens|requests)|limit (reached|exceeded|exhausted)|(reached|exceeded|hit) (the |your )?(usage |rate |daily |monthly )?limit|used up its prepaid credits|Qodo.{0,40}(monthly|usage|PR|review) limit|CodeAnt.{0,40}(monthly|trial|usage) limit'

# Author-scoped rate-limit clause for cubic (7-day trial added 2026-09-22 — a
# trial-ended notice is a refusal, not a review or finding, #1903). This is kept
# OUT of the shared ADVISORY_RATE_LIMIT_RE and matched ONLY against cubic's own
# submissions (author == cubic-dev-ai), because the clause is anchored on the
# literal "cubic" token: if it were in the shared, author-agnostic pattern, a
# genuine finding by ANOTHER tracked reviewer that merely discusses cubic — e.g.
# "The cubic free trial ended handling is too broad" — would be misclassified
# RATE_LIMITED, dropping that reviewer from the gate's required set and corrupting
# the scorecard (#1903 review: codex P2, cubic P3). The clause is also scoped to
# the observed "trial (ended|expired)" wording only (no generic
# subscription/plan/usage/review alternatives) so cubic's own genuine findings
# that open with the "cubic" prefix are not swept up either.
# shellcheck disable=SC2034
readonly ADVISORY_CUBIC_LOGIN='cubic-dev-ai'
# shellcheck disable=SC2034
readonly ADVISORY_CUBIC_RATE_LIMIT_RE='cubic.{0,40}(trial|free trial) (ended|expired)'

# Section-aware rate-limit scope for CodeRabbit (#2008). Its ONE summary comment,
# edited in place, holds two independently throttled outputs: the code review (a
# `rate limited by coderabbit.ai` block) and the Security Architecture Review (not
# throttled with it; it can carry findings, PR #2000). jq def `rl_scope` (input
# {bot, body}) returns only what the rate-limit regex may see: ONLY the rate-limited
# block when present, even beside an architecture_review section, so a throttled
# code review is still detected and retried; "" for any other CodeRabbit summary (a
# walkthrough or a security section merely mentioning rate limits is no notice);
# the whole body for everything else. A security section is evidence in its own
# right: its findings are held by the maintainer gate and dispositioned through
# reviewer_sources_finding_section_pattern, independently of this scope.
# Shared by get_advisory_bot_states() and detect_advisory_rate_limit(), which also
# order comments by lastEditedAt // createdAt (the summary is edited in place).
# shellcheck disable=SC2034
readonly _ADVISORY_RL_SCOPE_JQ='
  def rl_scope:
    (.body // "" | tostring) as $b
    | ((.bot // "") | tostring | ascii_downcase | sub("\\[bot\\]$"; "")) as $who
    | "<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->" as $rl_start
    | "<!-- end of auto-generated comment: rate limited by coderabbit.ai -->" as $rl_end
    | if $who == "coderabbitai"
         and (($b | contains("<!-- This is an auto-generated comment: summarize by coderabbit.ai -->"))
              or ($b | contains($rl_start)))
      then
        if ($b | contains($rl_start)) then ($b | split($rl_start)[1] | split($rl_end)[0])
        else "" end
      else $b end;
'

# Gate classification alias — same canonical regex, so get_advisory_bot_states()
# can never diverge from the sweep/scorecard detector.
# shellcheck disable=SC2034
readonly RATE_LIMIT_MARKERS="$ADVISORY_RATE_LIMIT_RE"

# Timeout-proceed windows for absent advisory bots (issue #1193, split from #1181).
# The gate must not block a PR forever when an advisory bot never produces output
# on the repo — a new repo where Gemini/Codex aren't vendor-side enabled, a bot
# uninstalled entirely (Copilot on a Free plan), or a bot outage. Past these
# windows an absent bot is treated as a *missing review*, not a *permanent block*.
#   HEAD_AGE   — proceed once the head commit is this old (primary timeout; the
#                only one that applies when NO bot has produced any output).
#   QUIESCENCE — proceed once no new bot submission has arrived for this long
#                (only meaningful once ≥1 bot has submitted).
# shellcheck disable=SC2034
readonly ADVISORY_HEAD_AGE_TIMEOUT_SEC=1200
# shellcheck disable=SC2034
readonly ADVISORY_QUIESCENCE_TIMEOUT_SEC=600

# Color codes for output
# shellcheck disable=SC2034
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m' # No Color

# log_info <message...>
#   Log informational message to stderr with advisory-gate prefix.
log_info() {
  echo "[advisory-gate] $*" >&2
}

# log_warn <message...>
#   Log warning message to stderr with yellow color and WARNING label.
log_warn() {
  echo -e "${YELLOW}[advisory-gate] WARNING: $*${NC}" >&2
}

# log_success <message...>
#   Log success message to stderr with green color.
log_success() {
  echo -e "${GREEN}[advisory-gate] $*${NC}" >&2
}

# _advisory_check_run_states <pr_snapshot_json> <bots_json_array>
#   Echo a JSON array of {bot, state:"COMMENTED", time} — one per completed,
#   conclusion=success check run on the PR's CURRENT head SHA whose name is an
#   advisory bot's registry check_run_name (#2005). Graphite reports a clean pass
#   ONLY as that check run, so without this a clean PR could never reach quorum and
#   always waited out the head-age timeout. Failed/neutral/pending runs and runs on
#   a stale SHA are not clean. Names come only from the registry (no hard-coding).
#   Best-effort: no registry, no reporter, no head SHA, or a failed fetch → "[]"
#   (reviews/comments are still counted exactly as before; never an API error).
_advisory_check_run_states() {
  local sha reporters runs repo
  sha=$(jq -r '.headRefOid // empty' <<< "$1" 2>/dev/null) || sha=""
  if [[ -z "$sha" || ! "$PR_URL" =~ ^https?://[^/]+/([^/]+/[^/]+)/pull/ ]] \
      || ! declare -F reviewer_sources_check_run_reporters >/dev/null; then
    echo '[]'; return 0
  fi
  repo="${BASH_REMATCH[1]}"
  reporters=$(reviewer_sources_check_run_reporters 2>/dev/null | jq -Rn --argjson bots "$2" '
    [inputs | split("\t") | select(length == 2 and (.[0] as $l | $bots | any(. == $l))) | {(.[1]): .[0]}]
    | add // {}') || reporters='{}'
  [[ "$reporters" == "{}" ]] && { echo '[]'; return 0; }
  runs=$(timeout 30 gh api --paginate "repos/${repo}/commits/${sha}/check-runs?per_page=100" 2>/dev/null) || {
    log_warn "check-run fetch failed at head ${sha:0:8} — counting reviews/comments only (#2005)"
    echo '[]'; return 0
  }
  jq -cs --argjson names "$reporters" --arg sha "$sha" '
    [.[].check_runs[]?
     | select(.head_sha == $sha and .status == "completed" and .conclusion == "success"
              and $names[.name // ""] != null)
     | {bot: $names[.name // ""], state: "COMMENTED", time: .completed_at}]' <<< "$runs" 2>/dev/null || echo '[]'
}

# Query which advisory bots have reviewed/commented on this PR
get_advisory_bot_states() {
  # Build JSON array of bot names from ADVISORY_BOTS keys — single source of truth
  local bot_array
  bot_array=$(printf '%s\n' "${!ADVISORY_BOTS[@]}" | jq -R . | jq -s .)

  local gh_output check_runs
  gh_output=$(gh pr view "$PR_URL" --json reviews,comments,headRefOid 2>&1) || {
    log_warn "gh pr view failed: $gh_output"
    return 2  # API error — distinct from "no bots yet" (1) so caller can fail-fast
  }
  # gh pr view omits lastEditedAt; merge it in by node id so in-place edits (the
  # CodeRabbit summary) are ordered by edit time (#2008). Best effort: on failure
  # the snapshot is unchanged and ordering falls back to createdAt.
  if ! declare -f maintainer_gate_merge_edit_times >/dev/null 2>&1; then
    # shellcheck source=scripts/lib/maintainer-comment-gate.sh
    source "$(dirname "${BASH_SOURCE[0]}")/maintainer-comment-gate.sh" 2>/dev/null || true
  fi
  if declare -f maintainer_gate_merge_edit_times >/dev/null 2>&1; then
    gh_output=$(maintainer_gate_merge_edit_times "$PR_URL" "$gh_output" 2>/dev/null) || true
  fi

  check_runs=$(_advisory_check_run_states "$gh_output" "$bot_array")
  [[ -n "$check_runs" ]] || check_runs='[]'

  echo "$gh_output" | jq -c --argjson bots "$bot_array" --arg markers "$RATE_LIMIT_MARKERS" \
    --arg cubic "$ADVISORY_CUBIC_LOGIN" --arg cubicre "$ADVISORY_CUBIC_RATE_LIMIT_RE" \
    --argjson checkruns "$check_runs" "$_ADVISORY_RL_SCOPE_JQ"'
    # Collect all bot submissions with their state. A comment whose body matches a
    # known rate-limit/usage-limit marker is classified RATE_LIMITED (the bot is out
    # of quota and cannot submit a real review); all other comments are COMMENTED.
    # The author-scoped cubic clause is applied ONLY to cubic'"'"'s own comments so a
    # different reviewer discussing cubic'"'"'s trial is never misclassified (#1903).
    # The regex sees only the section-aware rl_scope of each body (#2008).
    # Clean check-run passes at the current head (#2005) join as COMMENTED.
    (
      $checkruns +
      [(.reviews // [])[] | select([.author.login] | inside($bots)) | {bot: .author.login, state: .state, time: .submittedAt}] +
      [(.comments // [])[] | select([.author.login] | inside($bots))
        | ({bot: .author.login, body: (.body // "")} | rl_scope) as $scoped
        | {
        bot: .author.login,
        state: (if (($scoped | test($markers; "i"))
                    or (((.author.login // "") | ascii_downcase) == $cubic and ($scoped | test($cubicre; "i"))))
                then "RATE_LIMITED" else "COMMENTED" end),
        time: (.lastEditedAt // .createdAt)
      }]
    ) |
    # Group by bot, sort by time within each group, keep latest submission per bot
    group_by(.bot) |
    map(sort_by(.time) | last | {bot: .bot, state: .state, time: .time}) |
    sort_by(.bot) |
    .[]
  ' || {
    log_warn "jq processing failed"
    return 2  # Parse error — also distinct from "no bots yet" (1)
  }
}

# Get the committer date of the PR's head commit via a single GraphQL query.
# Uses committer.date (not author.date) so that cherry-picked commits reflect
# when the cherry-pick was applied (≈push time) rather than the original author
# date — preserving the cherry-pick guard without relying on pushedDate, which
# is deprecated in GitHub's GraphQL API and now returns null.
# Returns empty string on any API failure.
_get_head_committer_date() {
  local pr_url="$1"
  # shellcheck disable=SC2016  # $url is a GraphQL variable placeholder, not a shell variable
  local _gql='query($url:URI!){resource(url:$url){...on PullRequest{commits(last:1){nodes{commit{committer{date}}}}}}}'
  gh api graphql -f query="$_gql" -f url="$pr_url" \
    --jq '.data.resource.commits.nodes[0].commit.committer.date // empty' 2>/dev/null || true
}

# _head_age_seconds <pr_url>
#   Echo the age in seconds of the PR's head commit (now − committer.date), or an
#   empty string when the committer date can't be determined (GraphQL unreachable
#   or unparseable). Used by the zero-output branch to apply the head-age timeout.
_head_age_seconds() {
  local pr_url="$1" head_time head_time_raw now
  head_time=$(_get_head_committer_date "$pr_url") || head_time=""
  [[ -z "$head_time" ]] && return 0
  head_time_raw=$(date -u -d "$head_time" +%s 2>/dev/null) || head_time_raw=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$head_time" +%s 2>/dev/null) || head_time_raw=""
  [[ -z "$head_time_raw" ]] && return 0
  now=$(date -u +%s)
  printf '%s' "$((now - head_time_raw))"
}

# Format bot states for display
format_bot_status() {
  local bot="$1" state="$2"
  case "$state" in
    APPROVED) echo "✓ ${bot} → APPROVED" ;;
    COMMENTED) echo "✓ ${bot} → COMMENTED (advisory)" ;;
    CHANGES_REQUESTED) echo "⚠ ${bot} → CHANGES_REQUESTED" ;;
    DISMISSED) echo "✓ ${bot} → DISMISSED (no issues)" ;;
    UNSUPPORTED) echo "⊘ ${bot} → UNSUPPORTED (file type)" ;;
    RATE_LIMITED) echo "✗ ${bot} → RATE_LIMITED" ;;
    *) echo "? ${bot} → ${state}" ;;
  esac
}

# ────────────────────────────────────────────────────────────────────
# Rate-limit detection + marker (issue #711)
#
# When an advisory/review bot withholds a real review because it is out of
# quota, the gate keeps deferring approval but no event ever re-fires once CI
# settles green — the PR strands at REVIEW_REQUIRED. detect_advisory_rate_limit
# recognises that state and maybe_post_rate_limited_marker stamps a
# machine-detectable marker so pr-review-sweep can auto-retry after the limit
# resets (no manual force_review, which would bypass the gate entirely).
# ────────────────────────────────────────────────────────────────────

# Bots whose out-of-quota notice should arm the sweep retry. Superset of the
# gate's ADVISORY_BOTS — adds coderabbitai, which posts an explicit rate-limit
# comment but is not one of the bots the gate blocks on.
# Derived from the reviewer-source registry (all logins) when available; falls
# back to this literal list when the registry is absent or unreadable — never
# `exit` (see the ADVISORY_BOTS fallback rationale above, #1538).
_advisory_gate_load_fallback_notice_bots() {
  # shellcheck disable=SC2034
  declare -ga RATE_LIMIT_NOTICE_BOTS=(
    gemini-code-assist
    copilot-pull-request-reviewer
    sonarqubecloud
    chatgpt-codex-connector
    coderabbitai
    qodo-code-review
    codeant-ai
    graphite-app
    cubic-dev-ai
  )
}

if declare -f reviewer_sources_logins >/dev/null 2>&1 \
    && _rlnb_raw="$(reviewer_sources_logins)" && [ -n "$_rlnb_raw" ]; then
  # shellcheck disable=SC2034
  mapfile -t RATE_LIMIT_NOTICE_BOTS <<< "$_rlnb_raw"
  unset _rlnb_raw
else
  unset _rlnb_raw 2>/dev/null || true
  _advisory_gate_load_fallback_notice_bots
fi

# Case-insensitive phrases that indicate a bot is itself rate-limited / out of
# quota (not merely discussing rate limiting). Returns the canonical
# ADVISORY_RATE_LIMIT_RE so the sweep detector and reviewer scorecard share the
# exact regex the gate uses for RATE_LIMITED classification (no drift).
_advisory_rate_limit_pattern() {
  printf '%s' "$ADVISORY_RATE_LIMIT_RE"
}

# Author-scoped cubic rate-limit clause — matched ONLY against cubic's own
# submissions (see ADVISORY_CUBIC_RATE_LIMIT_RE rationale, #1903). Exposed as an
# accessor so scripts/reviewer_report.sh consumes the identical pattern (no drift).
_advisory_cubic_rate_limit_pattern() {
  printf '%s' "$ADVISORY_CUBIC_RATE_LIMIT_RE"
}

# cubic-dev-ai login constant — exposed as an accessor so scripts/reviewer_report.sh
# reuses it in the scorecard refusal predicate (no divergence if the login ever changes).
_advisory_cubic_login() {
  printf '%s' "$ADVISORY_CUBIC_LOGIN"
}

# detect_advisory_rate_limit <reviews-comments-json>
#   Returns 0 when a known advisory/review bot's LATEST submission body matches
#   the rate-limit pattern; 1 otherwise. Only the latest submission per bot is
#   considered, so a newer real review supersedes an older rate-limit notice
#   (and vice versa). Non-bot authors are ignored. "Latest" uses a comment's
#   lastEditedAt when present, and the pattern sees only the section-aware
#   rl_scope of the body (#2008, see _ADVISORY_RL_SCOPE_JQ).
detect_advisory_rate_limit() {
  local json="${1:-}"
  [[ -z "$json" ]] && return 1

  local bot_array pattern cubic_pattern matched
  bot_array=$(printf '%s\n' "${RATE_LIMIT_NOTICE_BOTS[@]}" | jq -R . | jq -s .)
  pattern=$(_advisory_rate_limit_pattern)
  cubic_pattern=$(_advisory_cubic_rate_limit_pattern)

  matched=$(jq -r --argjson bots "$bot_array" --arg pat "$pattern" \
    --arg cubic "$ADVISORY_CUBIC_LOGIN" --arg cubicre "$cubic_pattern" "$_ADVISORY_RL_SCOPE_JQ"'
    (
      [(.reviews // [])[]  | {bot: .author.login, time: .submittedAt, body: (.body // "")}] +
      # A comment edited in place (CodeRabbit summary) is ordered by its last edit (#2008).
      [(.comments // [])[] | {bot: .author.login, time: (.lastEditedAt // .createdAt), body: (.body // "")}]
    )
    | map(select(.bot as $b | $bots | any(. == $b)))
    | group_by(.bot)
    | map(sort_by(.time) | last)
    # Section-aware (#2008): the regex sees only the rate-limited block of a
    # CodeRabbit summary, whether or not it also carries a security review.
    | map(.body = rl_scope)
    # Generic markers match any bot; the cubic clause only cubic'"'"'s own notice (#1903).
    | map(select((.body | test($pat; "i"))
                 or (((.bot // "") | ascii_downcase) == $cubic and (.body | test($cubicre; "i")))))
    | length
  ' <<< "$json" 2>/dev/null) || return 1

  [[ "${matched:-0}" -gt 0 ]]
}

# maybe_post_rate_limited_marker <pr_url> <head_sha> <reset_iso> <comments_json>
#   Posts a deduplicated rate-limited marker comment so the sweep can detect the
#   withheld-due-to-rate-limit state and re-trigger a review after <reset_iso>.
#   <comments_json> is the already-fetched PR snapshot (.comments[]) used for the
#   dedup check, so no extra API call is needed to decide whether to post.
#   The marker prefix ("rate-limited" before v1) deliberately never matches the
#   idempotency marker regex (<!-- pr-review-agent v1 sha=...).
#   With DRY_RUN=true nothing is posted; the would-be post is logged instead.
maybe_post_rate_limited_marker() {
  local pr_url="${1:-}" head_sha="${2:-}" reset_iso="${3:-}" comments_json="${4:-}"
  if [[ -z "$pr_url" || -z "$head_sha" ]]; then
    log_warn "maybe_post_rate_limited_marker: pr_url and head_sha are required"
    return 1
  fi

  local marker="<!-- pr-review-agent rate-limited v1 sha=${head_sha} status=rate-limited reset=${reset_iso} -->"

  # Dedup: skip if a rate-limited marker already exists at this exact head.
  local cj="$comments_json"
  [[ -z "$cj" ]] && cj='{}'
  local already
  already=$(jq -r --arg sha "$head_sha" '
    [ (.comments // [])[]
      | (.body // "")
      | select(test("<!-- pr-review-agent rate-limited v1 sha=" + $sha + " ")) ]
    | length' <<< "$cj" 2>/dev/null || echo 0)
  if [[ "${already:-0}" -gt 0 ]]; then
    log_info "Rate-limited marker already present at head ${head_sha:0:8} — not re-posting"
    return 0
  fi

  # A DRY_RUN makes no GitHub writes: report the marker instead of posting it.
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "DRY_RUN: would post rate-limited marker on $pr_url (head ${head_sha:0:8}, reset ${reset_iso:-n/a})"
    return 0
  fi

  local body="${marker}
Advisory bots were rate-limited; auto-approval is withheld until they recover. pr-review-sweep will re-review this PR after ${reset_iso:-the limit resets}."

  if gh pr comment "$pr_url" --body "$body" >/dev/null 2>&1; then
    log_info "Posted rate-limited marker on $pr_url (head ${head_sha:0:8}, reset ${reset_iso:-n/a})"
  else
    log_warn "Failed to post rate-limited marker on $pr_url"
    return 1
  fi
}

# _record_partial_evidence <submitted> <required> <reason>
#   Record approval on PARTIAL advisory evidence so the miss-rate metric counts it
#   (#1596). Gate runs BEFORE the write, so with PARTIAL_EVIDENCE_STATE_FILE set we
#   DEFER (record facts, post NOTHING); post-pr-review.sh announces only after
#   verifying the review (#1874).
_record_partial_evidence() {
  if [ -n "${PARTIAL_EVIDENCE_STATE_FILE:-}" ]; then
    printf '%s %s %s\n' "$1" "$2" "$3" > "$PARTIAL_EVIDENCE_STATE_FILE" 2>/dev/null \
      || echo "::warning::could not record deferred partial-evidence facts (#1874)"
    log_info "partial-evidence deferred ($1/$2 reason=$3) — announced after write verified (#1874)"
    return 0
  fi
  command -v maybe_post_partial_evidence_marker >/dev/null 2>&1 || return 0
  maybe_post_partial_evidence_marker "$PR_URL" "${PR_HEAD_SHA:-}" "$1" "$2" "$3" "${PR_SNAPSHOT:-}" \
    || echo "::warning::partial-evidence marker post failed on ${PR_URL} — approval may be uncounted by the miss-rate metric (#1596)"
}

# check_advisory_reviews <pr_url>
#   Instant (non-blocking) check of advisory bot review status. Returns 0 when all
#   detected advisory bots have submitted their reviews (or the head-age/quiescence
#   timeouts (#1193) for absent bots apply); returns 1 when still waiting; returns 2
#   when the GitHub API query or jq parse fails — callers must fail closed, not treat
#   it as "waiting".
check_advisory_reviews() {
  local pr_url="${1:-}"
  if [[ -z "$pr_url" ]]; then
    echo "[advisory-gate] Usage: check_advisory_reviews <pr_url>" >&2
    return 1
  fi
  export PR_URL="$pr_url"

  local pr_num
  pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$' || echo "unknown")

  log_info "Checking advisory bot review status for PR #${pr_num} (instant check, no polling)"

  # Get current bot states (single gh API call, instant)
  local current_states
  current_states=$(get_advisory_bot_states) || {
    local gs_rc=$?
    if [[ $gs_rc -eq 2 ]]; then
      log_warn "Failed to query advisory bot states (API/parse error)"
      return 2  # Propagate API error — caller should fail, not treat as "waiting"
    fi
    log_warn "Failed to query advisory bot states"
    return 1
  }

  if [[ -z "$current_states" ]]; then
    # No advisory bot has produced ANY output on this PR. Historically the gate
    # blocked here forever, permanently stranding PRs on repos where an advisory
    # bot is not vendor-side enabled / not installed, or during a bot outage
    # (issue #1193, split from #1181). Apply the same head-age timeout the
    # partial-submission path uses: once the head commit is older than the window,
    # treat every absent bot as a *missing review* and proceed instead of
    # re-driving indefinitely — the scheduled sweep re-enters this gate until the
    # window is crossed. Within the window we still wait so bots that are merely
    # slow get their chance. When head age is undeterminable (GraphQL unreachable)
    # there is no timing basis to declare bots absent, so stay conservative and
    # wait; the next scheduled sweep retries once the API recovers.
    local head_age_sec
    head_age_sec=$(_head_age_seconds "$PR_URL")
    if [[ -n "$head_age_sec" && "$head_age_sec" -gt "$ADVISORY_HEAD_AGE_TIMEOUT_SEC" ]]; then
      log_warn "No advisory bot output; head is ${head_age_sec}s old (> ${ADVISORY_HEAD_AGE_TIMEOUT_SEC}s) — treating absent bots as missing reviews, proceeding (issue #1193)"
      _record_partial_evidence 0 "${#ADVISORY_BOTS[@]}" "no-output-head-age-timeout"
      return 0
    fi
    log_warn "No advisory bot reviews detected yet"
    log_warn "Will re-check when bots submit their reviews (pull_request_review event), or proceed once the head-age timeout (${ADVISORY_HEAD_AGE_TIMEOUT_SEC}s) elapses"
    return 1  # Within window — still waiting for bots
  fi

  # Extract participating bots (those who have submitted)
  local participating_bots num_submitted total_advisory_bots
  participating_bots=$(echo "$current_states" | jq -rs '[.[].bot] | unique | join(" ")')
  # Count only bots with real reviews, not rate-limited/unsupported ones
  num_submitted=$(echo "$current_states" | jq -rs '[.[] | select(.state != "RATE_LIMITED" and .state != "UNSUPPORTED") | .bot] | unique | length')
  total_advisory_bots=${#ADVISORY_BOTS[@]}

  log_info "Advisory bots detected: $participating_bots"
  while IFS= read -r line; do
    local bot state
    bot=$(echo "$line" | jq -r '.bot')
    state=$(echo "$line" | jq -r '.state')
    log_info "  $(format_bot_status "$bot" "$state")"
  done <<< "$current_states"

  # Rate-limited / unsupported bots can't (or needn't) submit a real review, so they
  # must not hold the gate (issue #657). Drop them from the required total:
  # effective_total = total − (rate-limited|unsupported), clamped to ≥1 so the gate
  # never approves with zero advisory input. num_submitted counts only real reviews.
  local num_unavailable effective_total
  num_unavailable=$(echo "$current_states" | jq -rs \
    '[.[] | select(.state == "RATE_LIMITED" or .state == "UNSUPPORTED") | .bot] | unique | length')
  effective_total=$((total_advisory_bots - num_unavailable))
  [[ "$effective_total" -lt 1 ]] && effective_total=1
  if [[ "$num_unavailable" -gt 0 ]]; then
    # Name WHICH bots dropped and why so the reduced denominator is observable — the
    # registry total and effective total must never differ silently (#1894 AC #2).
    local unavailable_named
    unavailable_named=$(echo "$current_states" | jq -rs '[.[] | select(.state == "RATE_LIMITED" or .state == "UNSUPPORTED") | "\(.bot)=\(.state)"] | unique | join(", ")')
    log_info "${num_unavailable} advisory bot(s) rate-limited/unsupported — required set reduced to ${effective_total}/${total_advisory_bots}; dropped: ${unavailable_named}"
  fi

  # Require the effective advisory set to submit before approving.
  # Two timeout fallbacks handle absent (but not rate-limited) bots (e.g. Copilot only
  # reviews a subset of PRs):
  #   1. Head-push age > 20 min: use latest commit time, not PR creation time, so a new
  #      commit on an old PR doesn't immediately bypass the gate (thread PRRT_..ofWG).
  #   2. Quiescence > 10 min: if no new submissions have arrived in 10 min, assume the
  #      remaining bots won't participate — prevents indefinite stranding when there is
  #      no scheduled retry event to re-enter this branch (thread PRRT_..ofWI).
  if [[ "$num_submitted" -lt "$effective_total" ]]; then
    local now head_time head_time_raw head_age_sec latest_sub_at latest_sub_raw time_since_last_sub
    now=$(date -u +%s)

    head_age_sec=0
    head_time_raw=""  # Initialize before conditional to prevent set -u abort
    # Use the head commit's committer date (via GraphQL) to determine push age.
    # committer.date reflects when a cherry-pick or rebase was applied, not the
    # original author date, so recently cherry-picked commits do not bypass the
    # gate. pushedDate was previously used for this purpose but now returns null
    # in GitHub's GraphQL API (deprecated and no longer populated).
    head_time=$(_get_head_committer_date "$PR_URL") || head_time=""
    if [[ -n "$head_time" ]]; then
      head_time_raw=$(date -u -d "$head_time" +%s 2>/dev/null) || head_time_raw=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$head_time" +%s 2>/dev/null) || head_time_raw=""
      [[ -n "$head_time_raw" ]] && head_age_sec=$((now - head_time_raw))
    fi

    time_since_last_sub=0
    # -s (slurp) is required: current_states is a newline-delimited object
    # stream. Without slurping, `.[].time` iterates each object's scalar
    # values and jq errors — leaving latest_sub_at empty, time_since_last_sub
    # at 0, and the quiescence fallback permanently disarmed.
    latest_sub_at=$(echo "$current_states" | jq -rs '[.[].time] | sort | last // empty' 2>/dev/null) || latest_sub_at=""
    if [[ -n "$latest_sub_at" ]]; then
      latest_sub_raw=$(date -u -d "$latest_sub_at" +%s 2>/dev/null) || latest_sub_raw=""
      if [[ -n "$latest_sub_raw" ]]; then
        # Anchor quiescence to the later of head-push and latest submission so that
        # stale submissions from a previous HEAD don't satisfy the fallback for a
        # fresh commit (a new push resets the quiescence timer to the head-push time).
        # When head_time_raw is unavailable, anchor to latest_sub_at alone — this
        # loses the cherry-pick protection for quiescence but avoids indefinite
        # stranding when the commit API is unreachable.
        local quiescence_anchor
        if [[ -n "$head_time_raw" && "$head_time_raw" -gt "$latest_sub_raw" ]]; then
          quiescence_anchor=$head_time_raw
        else
          quiescence_anchor=$latest_sub_raw
        fi
        time_since_last_sub=$((now - quiescence_anchor))
      fi
    fi

    if [[ "$head_age_sec" -gt "$ADVISORY_HEAD_AGE_TIMEOUT_SEC" ]]; then
      log_info "Only ${num_submitted}/${effective_total} required bots submitted; head is ${head_age_sec}s old — timeout fallback, proceeding"
      _record_partial_evidence "$num_submitted" "$effective_total" "head-age-timeout"
    elif [[ "$time_since_last_sub" -gt "$ADVISORY_QUIESCENCE_TIMEOUT_SEC" ]]; then
      log_info "Only ${num_submitted}/${effective_total} required bots submitted; no new submissions in ${time_since_last_sub}s — assuming absent bots won't participate, proceeding"
      _record_partial_evidence "$num_submitted" "$effective_total" "quiescence-timeout"
    else
      log_warn "Only ${num_submitted}/${effective_total} required advisory bots submitted so far (head age: ${head_age_sec}s, last submission: ${time_since_last_sub}s ago)"
      log_warn "Will re-check when remaining bots submit their reviews"
      return 1
    fi
  fi

  log_success "All detected advisory bots have submitted ✓"
  return 0  # Ready to approve
}

# Run the check (only if not being sourced)
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  if check_advisory_reviews "${1:-}"; then
    exit_code=0
  else
    exit_code=$?
  fi

  if [[ $exit_code -eq 0 ]]; then
    log_success "Advisory bot review gate check PASSED ✓"
  elif [[ $exit_code -eq 1 ]]; then
    log_warn "Advisory bots still reviewing - will check again on next review submission"
  fi

  exit $exit_code
fi
