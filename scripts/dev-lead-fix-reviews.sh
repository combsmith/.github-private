#!/usr/bin/env bash
set -euo pipefail
# dev-lead-fix-reviews.sh — handles review-related intents
# Optional: PROMPTS_DIR (defaults to prompts/dev-lead relative to CWD)

source "$(dirname "$0")/engine.sh"
source "$(dirname "$0")/lib/git-identity.sh"
source "$(dirname "$0")/lib/pr-worktree.sh"
source "$(dirname "$0")/lib/auto-merge.sh"
source "$(dirname "$0")/lib/git-push-guard.sh"
source "$(dirname "$0")/lib/pr-automation-budget.sh"
source "$(dirname "$0")/lib/maintainer-review-thread-gate.sh"
source "$(dirname "$0")/lib/conflict-integrity.sh"
source "$(dirname "$0")/lib/review-change-evidence.sh"
# Paginated, fail-closed open-review-thread fetch shared by fix-reviews and
# review-changes (#2056).
source "$(dirname "$0")/lib/open-review-threads.sh"
source "$(dirname "$0")/lib/resolution-integrity.sh"
source "$(dirname "$0")/lib/addressed-claim-verify.sh"
# Claim landing (#2013): "did the push land?" as a pure verdict, and retraction of
# this pass's claim replies whose commit did not land on the remote head.
source "$(dirname "$0")/lib/claim-landing.sh"
# Test-tamper guard (#2013): a fix pass may not silently rewrite an existing test.
source "$(dirname "$0")/lib/test-tamper-guard.sh"
# Sync-stub guard (#2185): a bot pass may not edit a synced org-standard stub.
source "$(dirname "$0")/lib/sync-stub-guard.sh"
# Test-regression guard (#2013): a pass may not push with the suite newly red.
source "$(dirname "$0")/lib/test-regression-guard.sh"
# PR issue-comment disposition verifier (#1813): the issue-comment sibling of
# addressed-claim-verify.sh. Turns a dev-lead comment-disposition reply into a
# machine-checkable claim the harness verifies before minimizing the original
# comment RESOLVED.
source "$(dirname "$0")/lib/comment-disposition-verify.sh"
# Review-thread deferral verifier (#2045): the thread-side sibling of the
# `out-of-scope` disposition. A bot thread deferred to an open tracking issue that
# links it is resolved by resolve_deferred_bot_threads.
source "$(dirname "$0")/lib/deferred-thread-verify.sh"
# The issue-comment gate — sourced for its agent-marker regex
# ($_MAINTAINER_GATE_AGENT_MARKERS), so resolve_dispositioned_comments excludes
# our own disposition/ack/note replies with the SAME discriminator the gate uses
# (single source of truth; #1813 loop safety AC7).
source "$(dirname "$0")/lib/maintainer-comment-gate.sh"
# Structured PR-body backfill (#1805): heal an existing PR whose body is still
# missing 3+ required description sections, once, marker-keyed.
# Absolute agent-scripts dir, captured before any cd into a PR worktree so later
# `$(dirname "$0")` lookups (verify_resolution_integrity) cannot resolve relative
# to the worktree.
AGENT_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$0")/lib/dev-lead-pr-body.sh"
source "$(dirname "$0")/lib/redact.sh"
# Rebase exhaustion handling (#865): abort cleanly on hard conflicts instead of
# timing out (exit 124), and dampen sentinel bursts.
source "$(dirname "$0")/lib/rebase-exhaustion.sh"
# Shallow-checkout history deepening (#2053): git_history_deepen /
# git_ensure_merge_base — the one copy of the un-shallow logic, used by the
# rebase arm before conflict detection and by pr_nets_to_zero.
source "$(dirname "$0")/lib/git-history.sh"
# CI gate status (#1859, completes #1795): the blocker check delegates to
# compute_ci_status so a failing NON-required check never stops the
# fix/disposition pass — the same library review-one-pr.sh and the sweeps use.
source "$(dirname "$0")/lib/ci-status.sh"
# Hold label (#2142): every escalation applies needs-human-review through the REST
# labels API, logs the API's message on failure, and a failed hold fails the run.
source "$(dirname "$0")/lib/hold-label.sh"

INTENT_TYPE="${INTENT_TYPE:-fix-reviews}"
PR_NUMBER="${PR_NUMBER:-}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
HEAD_SHA="${HEAD_SHA:-}"
DEV_LEAD_DRY_RUN="${DEV_LEAD_DRY_RUN:-false}"
export PROMPTS_DIR="${PROMPTS_DIR:-prompts/dev-lead}"
# Pin PROMPTS_DIR to an absolute path now, while CWD still points at the agent
# checkout — checkout_pr_in_worktree cds into the PR worktree, after which a
# relative PROMPTS_DIR would resolve against the PR branch (issue #448).
PROMPTS_DIR="$(resolve_abs "$PROMPTS_DIR")"
export PROMPTS_DIR

REVIEWS_MARKER_PREFIX="<!-- dev-lead-fix-reviews pr="
# When this pass started, i.e. a lower bound on when it read the PR's comments.
# Stamped on terminal markers as read_at= so the #2008 stale-edit dedup can tell a
# pass that read an edited body from one that merely FINISHED after the edit.
PASS_STARTED_AT="${PASS_STARTED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
INTEGRITY_MARKER_PREFIX="<!-- dev-lead-conflict-integrity pr="
NONCONVERGE_MARKER_PREFIX="<!-- dev-lead-review-nonconverge pr="
# Consecutive not-applied passes against the same review before escalating to a
# human (#1567 AC #4). A pass "does not converge" when it commits something but
# addresses none of the regions the review named.
REVIEW_NONCONVERGENCE_LIMIT="${REVIEW_NONCONVERGENCE_LIMIT:-3}"

if [ -z "$PR_NUMBER" ] && [ "$INTENT_TYPE" != "rebase" ]; then
  echo "::error::PR_NUMBER is required"
  exit 1
fi

# A failed hold must fail the run (#2142). Installed before the budget check so a
# budget escalation that cannot apply its label is loud too; the auto-merge trap
# below keeps the guard as its last handler.
trap hold_label_exit_guard EXIT

# Per-PR automation budget (#926): if this PR has exhausted its lifetime
# automation budget since the last human interaction, stop before any writes.
# Checked before holding auto-merge so the escalation's auto-merge disable is not
# undone by the restore_auto_merge EXIT trap. Only a human interaction resets it.
if [ -n "${PR_NUMBER:-}" ] && [ "${DEV_LEAD_DRY_RUN:-false}" != "true" ] \
   && enforce_pr_budget "$PR_NUMBER" "$REPO"; then
  echo "::warning::PR #${PR_NUMBER} automation budget exhausted — skipping ${INTENT_TYPE}"
  exit 0
fi

# Checkout the PR branch for modification (Requirement 1).
# Use an isolated worktree so switching to the PR branch never overwrites the
# agent's own prompts/scripts in the working tree (issue #448).
if [ "${DEV_LEAD_DRY_RUN:-false}" = "false" ] && [ -n "${PR_NUMBER:-}" ]; then
  # Hold auto-merge OFF while we work so a review approval landing mid-run can't
  # merge (and delete) the branch out from under us. restore_auto_merge (EXIT
  # trap) puts it back however we exit; checkout_pr_in_worktree chains its own
  # cleanup onto this trap.
  # shellcheck disable=SC2154 # rc is set by the trap string itself
  trap 'rc=$?; restore_auto_merge; hold_label_exit_guard "$rc"' EXIT
  hold_auto_merge
  # Resolve HEAD_SHA after holding auto-merge: for issue_comment intents
  # (on-mention, fix-bot-comment) only pr_number is provided, not head_sha.
  # Resolving here rather than before the hold closes the window where an
  # approval could satisfy branch protection during the API call and let
  # GitHub auto-merge the branch before the hold is installed.
  if [ -z "${HEAD_SHA:-}" ]; then
    HEAD_SHA=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha' 2>/dev/null || true)
  fi
  checkout_pr_in_worktree "$PR_NUMBER" "$REPO"
  # Immutable snapshot of the head this pass starts from — captured at the one
  # moment that actually means "before this pass did any work" (#1617). The
  # resolution gate compares against THIS, not HEAD_SHA: HEAD_SHA is the
  # event-time SHA (only re-resolved when empty, line 67) and is reassigned by
  # try_enable_auto_merge, so a commit landing between the event and this
  # checkout would make HEAD_SHA differ from the checked-out head and open the
  # gate on a no-commit pass. RESOLUTION_BASE_SHA is set once here and never
  # reassigned, so the gate measures only whether THIS pass advanced the head.
  RESOLUTION_BASE_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
  # The pass boundary for the claim-retraction sweep (#2013): only claim replies
  # created at/after this instant are this pass's to retract.
  PASS_START_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Reply-id record for stamp_pass_replies (#2079 AC4): created empty here so a pass
  # that never runs the engine still has a (empty) record; the engine run installs the
  # recording gh shim that fills it. A missing record disables the no-change path.
  PASS_REPLY_RECORD="$(mktemp "${TMPDIR:-/tmp}/dev-lead-replies.XXXXXX" 2>/dev/null || true)"
  setup_git_identity
  # Backfill the five required description sections into a pre-existing PR whose
  # body still lacks them (#1805). Idempotent + marker-keyed, so open PRs heal on
  # their next dev-lead pass without churning on every run.
  dlpb_backfill_pr_body "$PR_NUMBER" "$REPO" || true
fi

# build_and_run <template_name>: loads a prompt template, substitutes variables, and runs the agent.
build_and_run() {
  local template_name="$1"
  local prompt_file="/tmp/dev-lead-${template_name}-prompt-$$.md"
  local template_path="${PROMPTS_DIR}/${template_name}.md"
  # Scope envsubst to only the variables declared in the <!-- VARIABLES: --> header.
  # This prevents GraphQL $variables, $() subshells, and other $ patterns in the
  # prompt from being silently clobbered before the agent ever sees them.
  local vars_spec
  vars_spec=$(grep -m1 '<!-- VARIABLES:' "$template_path" 2>/dev/null \
    | sed 's/<!-- VARIABLES: //; s/ -->//' \
    | tr ',' '\n' \
    | awk '{gsub(/^ +| +$/, ""); if (length) printf "${%s}", $0}' || true)
  # OPEN_THREADS_JSON is unbounded (paginated, #2056) and must never ride in the
  # environment: a single env string over ~128 KiB makes every exec fail with
  # "Argument list too long". envsubst sees a placeholder; the real payload is
  # spliced in with shell builtins afterwards.
  local ph="@@OPEN_THREADS_JSON_PLACEHOLDER@@"
  if [ -n "$vars_spec" ]; then
    OPEN_THREADS_JSON="$ph" envsubst "$vars_spec" < "$template_path" > "$prompt_file"
  else
    OPEN_THREADS_JSON="$ph" envsubst < "$template_path" > "$prompt_file"
  fi
  if [ -n "${OPEN_THREADS_JSON:-}" ] && grep -qF -- "$ph" "$prompt_file"; then
    local content out="" rest
    content=$(<"$prompt_file")
    rest="$content"
    while [[ "$rest" == *"$ph"* ]]; do
      out+="${rest%%"$ph"*}${OPEN_THREADS_JSON}"
      rest="${rest#*"$ph"}"
    done
    printf '%s\n' "${out}${rest}" > "$prompt_file"
  fi

  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] would run engine with prompt: $prompt_file ($(wc -l < "$prompt_file") lines)"
    rm -f "${prompt_file:-}"
    return 0
  fi

  local rc=0
  # Run the model with a recording gh shim first on PATH so every review-thread reply it
  # posts is attributable by node id (#2079 AC4). No recorder => nothing is trusted.
  local shim_dir="" engine_path="$PATH"
  if [ -n "${PASS_REPLY_RECORD:-}" ] && shim_dir=$(cl_install_reply_recorder "$PASS_REPLY_RECORD"); then
    engine_path="${shim_dir}:${PATH}"
  else
    echo "::warning::could not install the reply recorder — no-change dispositions are disabled this pass (#2079)"
    [ -n "${PASS_REPLY_RECORD:-}" ] && printf 'UNATTRIBUTED\n' > "$PASS_REPLY_RECORD"
  fi
  PATH="$engine_path" run_writer_with_fallback "$prompt_file" "${INTENT_TYPE:-}" || rc=$?
  [ -n "$shim_dir" ] && rm -rf "$shim_dir"
  rm -f "${prompt_file:-}"
  return "$rc"
}

# post_reviews_terminal: writes a terminal status marker after a retryable
# intent completes. This prevents the retry cron from re-dispatching the same
# intent on subsequent runs when the SHA hasn't changed.
#
# A fix-bot-comment marker also names the comment the pass processed
# (` comment=<node id>`, #2017) and the VERSION of the body it read
# (` version=<ISO-8601>`, the comment's lastEditedAt // createdAt): the
# undispositioned bot-comment retry in dev-lead-retry.sh reads it as "a pass
# already ENDED on this comment version" and does not re-dispatch one that
# finished without a disposition — while an edit made during the pass stays open.
# Only a well-formed node id / timestamp is stamped, so a malformed value can
# never break out of the marker.
post_reviews_terminal() {
  local intent="$1" status="${2:-applied}" summary="${3:-}"
  # #2037: a comment the resolver failed to unminimize stays RESOLVED without a
  # verified disposition. An applied/no-changes marker would record the pass as a
  # success, and the retry cron and the #2008 stale-edit dedup would then skip it.
  # Downgrade to partial, which neither counts as done. The cron does not
  # re-dispatch a partial marker itself (that would loop on a persistent unminimize
  # failure); the next pass for this PR re-attempts the comment.
  if [ "${_DISPOSITIONS_UNRESOLVED:-0}" -eq 1 ]; then
    case "$status" in
      applied|no-changes)
        status="partial"
        local msg="**Not complete:** a dispositioned PR comment could not be re-opened (unminimize failed), so it stays resolved without a verified disposition. It needs another dev-lead pass."
        if [ -n "$summary" ]; then
          summary="${summary}

${msg}"
        else
          summary="$msg"
        fi
        ;;
    esac
  fi
  local sha_part="" comment_part="" read_part=""
  [ -n "${HEAD_SHA:-}" ] && sha_part=" sha=${HEAD_SHA}"
  if [ "$intent" = "fix-bot-comment" ] && [[ "${COMMENT_NODE_ID:-}" =~ ^[-A-Za-z0-9_+/=]+$ ]]; then
    comment_part=" comment=${COMMENT_NODE_ID}"
    if [[ "${COMMENT_VERSION:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]]; then
      comment_part="${comment_part} version=${COMMENT_VERSION}"
    fi
  fi
  if [[ "${PASS_STARTED_AT:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    read_part=" read_at=${PASS_STARTED_AT}"
  fi
  local marker="${REVIEWS_MARKER_PREFIX}${PR_NUMBER}${sha_part} intent=${intent} status=${status}${comment_part}${read_part} -->"

  local body="${marker}"
  if [ -n "$summary" ]; then
    body="${body}
## Dev-Lead — ${intent} (${status})
${summary}"
  fi

  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] would post reviews terminal marker: intent=${intent} status=${status}"
    [ -n "$summary" ] && echo "$body"
    return 0
  fi
  # Best-effort: don't fail the overall script if the marker post fails
  gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$body" 2>/dev/null || true
}

# redact_secrets lives in scripts/lib/redact.sh (sourced above) so this script
# and the persona runtime share one definition (#1775 AC #4).

# read_session_summary: extracts the agent's structured summary from the session
# log and redacts any embedded credentials. Empty output if the file is missing
# (e.g. dry-run paths that never invoked the writer).
#
# Strategy: scan the redacted stream for the *last* occurrence of a known summary
# header (`Bot:`, `PR: #`, `Addressed N threads:`, `Human review threads
# addressed:`, `Issues addressed:` — see prompts/dev-lead/*.md "Output Format")
# and emit from that line to EOF, capped at 30 non-blank lines. Falls back to
# the last 30 non-blank lines when no marker is present, preserving the prior
# tail behaviour for unstructured output. grep -n + sed avoids loading the log
# into an awk array (gemini medium finding).
#
# Redaction runs over the full log *before* the marker search, so PEM blocks
# that straddle the marker window are fully redacted (header outside the kept
# window, body inside the kept window would otherwise leak plaintext key
# material).
read_session_summary() {
  local log="/tmp/dev-lead-session-output.txt"
  [[ -f "$log" ]] || return 0
  local redacted
  redacted="$(redact_secrets < "$log")"
  local mark
  mark=$(printf '%s\n' "$redacted" | grep -nE \
    '^(Bot:|PR: #|Addressed [0-9]+ threads?:|Human review threads addressed:|Issues addressed:)' \
    | tail -1 | cut -d: -f1)
  if [ -n "$mark" ]; then
    printf '%s\n' "$redacted" | sed -n "${mark},\$p" | sed '/^[[:space:]]*$/d' | head -30
  else
    printf '%s\n' "$redacted" | tail -30 | sed '/^[[:space:]]*$/d' | tail -10
  fi
}

# pick_fence: emit a tilde fence longer than any tilde run in $1 (min 4).
# Ensures the wrapping ~~~~ code block cannot be terminated early by content
# that happens to contain a tilde sequence.
pick_fence() {
  local content="$1"
  local fence="~~~~"
  while printf '%s' "$content" | grep -qF "$fence"; do
    fence="${fence}~"
  done
  printf '%s' "$fence"
}

# post_no_changes: posts a terminal no-changes marker with redacted agent
# reasoning when available, or a plain fallback when the session log is
# absent. Picks a tilde fence that cannot be broken by the content, and
# neutralises any literal </details> so the wrapping <details> stays intact.
post_no_changes() {
  local intent="$1"
  local _summary
  _summary=$(read_session_summary || true)
  local msg="No actionable items found."
  if [[ -n "$_summary" ]]; then
    # Neutralise any </details> in summary so it cannot close the outer block.
    _summary=$(printf '%s' "$_summary" | sed 's|</details>|<\\/details>|g')
    local fence
    fence=$(pick_fence "$_summary")
    msg="<details><summary>Agent reasoning</summary>

${fence}
${_summary}
${fence}
</details>"
  fi
  post_reviews_terminal "$intent" "no-changes" "$msg"
}

# post_integrity_warning: posts a single advisory PR comment when the
# post-resolution integrity check finds duplicate top-level declarations the
# resolution introduced. Signal-only (#1482 AC #4) — it never blocks, reverts,
# or changes the caller's exit code; a maintainer decides what to do. The
# marker keeps it idempotent so a re-dispatched rebase does not stack comments.
post_integrity_warning() {
  local report="$1"
  local marker="${INTEGRITY_MARKER_PREFIX}${PR_NUMBER} -->"
  local body="${marker}
> [!WARNING]
> **Post-conflict-resolution integrity check flagged this resolution.**
> The automated rebase introduced **duplicate top-level declarations** — the
> #1449 corruption pattern, where a botched merge silently doubled functions and
> the damage was only found hours later by an unrelated failing test. This is
> **advisory**: the resolution is not blocked or reverted. Please verify the
> file(s) below before trusting this branch.

${report}
_Detected by \`scripts/lib/conflict-integrity.sh\` (#1482). If this repetition is intentional, disregard._"

  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] would post conflict-integrity warning for PR ${PR_NUMBER}"
    echo "$body"
    return 0
  fi
  # Idempotent: skip if an integrity marker for this PR already exists.
  if gh pr view "$PR_NUMBER" --repo "$REPO" --json comments \
       --jq '.comments[].body' 2>/dev/null | grep -F "$marker" > /dev/null; then
    echo "conflict-integrity marker already present on PR ${PR_NUMBER} — skipping"
    return 0
  fi
  # Best-effort: don't fail the overall rebase if the advisory post fails.
  gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$body" 2>/dev/null || true
}

# run_post_resolution_integrity_check: after an automated conflict resolution
# lands, scan the shell files it touched for duplicate top-level declarations
# the resolution *introduced* (#1449 corruption class). Parents are the base ref
# (origin/<base>) and the branch tip before the resolution (<pre_ref>); a symbol
# whose declaration count exceeds both parents is flagged. Runs on the
# conflict-resolution path itself (#1482 AC #2) rather than waiting for an
# unrelated downstream test to trip over the corruption.
run_post_resolution_integrity_check() {
  local base_ref="$1" pre_ref="$2"
  [ -n "$pre_ref" ] || return 0

  local changed
  # Compare pre_ref to the working tree (not just HEAD) so that uncommitted
  # worktree edits left by the agent are also included in the scan (#1496).
  changed="$(git diff --name-only "$pre_ref" -- '*.sh' 2>/dev/null || true)"
  [ -n "$changed" ] || return 0

  local report="" file findings pa pb
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -f "$file" ] || continue   # deleted by the resolution — nothing to check
    pa="$(mktemp)"; pb="$(mktemp)"
    git show "origin/${base_ref}:${file}" >"$pa" 2>/dev/null || : >"$pa"
    git show "${pre_ref}:${file}" >"$pb" 2>/dev/null || : >"$pb"
    findings="$(new_duplicate_symbols "$file" "$pa" "$pb")"
    rm -f "$pa" "$pb"
    if [ -n "$findings" ]; then
      report="${report}$(format_integrity_findings "$file" "$findings")
"
    fi
  done <<EOF
${changed}
EOF

  [ -n "$report" ] || return 0
  post_integrity_warning "$report"
}

# notify_coderabbit_resolve: posts @coderabbitai resolve if coderabbitai[bot]'s
# most recent review on the PR is CHANGES_REQUESTED. Uses --paginate so it sees
# all reviews even on long-lived PRs, and checks only the latest review state
# (not any historical one) to avoid noisy re-posts after a prior approval or dismissal.
notify_coderabbit_resolve() {
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would check for coderabbitai CHANGES_REQUESTED and post @coderabbitai resolve"
    return 0
  fi
  # Emit one state per CodeRabbit review in chronological order; tail -1 = latest.
  local latest_cr_state
  latest_cr_state=$(gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
    --jq '.[] | select(.user.login == "coderabbitai[bot]") | .state' \
    2>/dev/null | tail -1)
  if [ "${latest_cr_state:-}" = "CHANGES_REQUESTED" ]; then
    echo "::notice::coderabbitai[bot] latest review is CHANGES_REQUESTED — posting @coderabbitai resolve"
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "@coderabbitai resolve <!-- dev-lead -->" 2>/dev/null || true
  fi
}

# resolve_actor_outdated_threads: best-effort safety net for the no-changes path.
# Resolves any open review threads on this PR that are isOutdated AND authored by ACTOR
# (matched against both the raw ACTOR string and ACTOR with any "[bot]" suffix stripped,
# since GitHub Actions includes the suffix but GraphQL author.login does not).
# Outdated threads reference code that no longer exists, so resolution is unambiguously
# safe. Independent of whether the agent decided to resolve them.
#
# RESOLVE-GUARD (#1415). dev-lead acts as the owner `don-petry` — the SAME account a
# human maintainer uses — so ACTOR-authored is NOT sufficient to prove a thread is
# ours: a maintainer's inline review left as `don-petry` matches the ACTOR filter
# exactly (this is the PR #1413 shape). Login cannot discriminate a maintainer from
# the agent here, so when the author is maintainer-capable — NOT one of the advisory/
# automation bots (review_thread_login_is_excluded_bot) and NOT our own bot login —
# each candidate is additionally gated on the automation MARKER in its originating
# comment via review_thread_is_agent_authored(): a marker-less thread is a maintainer
# finding and is SKIPPED with a visible ::warning:: rather than silently resolved.
# The guard uses the SAME maintainer definition as check_maintainer_review_threads
# (marker-less AND non-excluded-bot AND non-bot_user), so an outdated advisory-bot
# thread (e.g. codex/coderabbit) stays freely resolvable — only a genuine maintainer
# finding is held back. This is the review-path application of #860 rule 2 — "a gate
# whose reset is reachable by the agent is not a gate" — to review/merge gates
# (docs/agentic-interaction-model.md).
#
# ACTOR is passed to jq via --arg (not shell interpolation) so a hostile actor value
# can't escape the filter. reviewThreads(first:100) is the GraphQL max for a single
# page — PRs with >100 review threads will still leave some outdated ones unresolved,
# but full cursor pagination is overkill for a best-effort safety net.
resolve_actor_outdated_threads() {
  local intent="$1"
  if [ -z "${ACTOR:-}" ]; then
    echo "::notice::resolve_actor_outdated_threads: ACTOR not set for intent=${intent} — skipping"
    return 0
  fi
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would resolve outdated review threads authored by ${ACTOR} on PR #${PR_NUMBER}"
    return 0
  fi

  local actor_stripped="${ACTOR%\[bot\]}"
  local pairs
  # Emit "<thread_id>\t<base64(originating comment body)>" per candidate so the
  # resolve-guard can inspect the marker without the body's quotes/newlines
  # breaking the read loop. gh api's --jq does not accept --arg, so pipe to jq
  # directly to bind the actor values as data (not shell-interpolated).
  pairs=$(gh api graphql -f query='
    query($owner:String!,$repo:String!,$pr:Int!) {
      repository(owner:$owner, name:$repo) {
        pullRequest(number:$pr) {
          reviewThreads(first:100) {
            nodes { id isResolved isOutdated comments(first:1) { nodes { author { login } body } } }
          }
        }
      }
    }' \
    -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" 2>/dev/null \
    | jq -r --arg actor "$ACTOR" --arg actor_stripped "$actor_stripped" \
        '.data.repository.pullRequest.reviewThreads.nodes
          | map(select(.isResolved == false
                       and .isOutdated == true
                       and (.comments.nodes[0]?.author?.login == $actor
                            or .comments.nodes[0]?.author?.login == $actor_stripped)))
          | .[] | .id + "\t" + ((.comments.nodes[0]?.body // "") | @base64)' 2>/dev/null || true)

  if [ -z "$pairs" ]; then
    echo "::notice::no outdated unresolved threads from ${ACTOR} on PR #${PR_NUMBER}"
    return 0
  fi

  # The jq filter binds every candidate's originating author.login to ACTOR (raw or
  # [bot]-stripped), so a single up-front check decides whether the marker guard
  # applies: it fires only for a maintainer-capable ACTOR — one that is NOT an
  # advisory/automation bot and NOT our own bot login. An advisory-bot ACTOR (e.g.
  # codex/coderabbit) leaves its outdated threads freely resolvable, preserving the
  # pre-#1415 safety-net behavior.
  local actor_is_maintainer_capable=true
  if review_thread_login_is_excluded_bot "$actor_stripped" \
     || [ "$actor_stripped" = "${BOT_USER:-donpetry-bot}" ]; then
    actor_is_maintainer_capable=false
  fi

  local resolved_count=0
  local id body_b64 body
  while IFS=$'\t' read -r id body_b64; do
    [ -z "$id" ] && continue
    body=$(printf '%s' "$body_b64" | base64 --decode 2>/dev/null || printf '%s' "$body_b64" | base64 -d 2>/dev/null || echo "")
    # Resolve-guard (#1415): for a maintainer-capable ACTOR, only resolve a thread
    # whose originating comment carries one of our automation markers. A marker-less
    # thread authored as `don-petry` is a maintainer finding the agent must NOT clear
    # — fail closed and log the skip.
    if [ "$actor_is_maintainer_capable" = true ] && ! review_thread_is_agent_authored "$body"; then
      echo "::warning::resolve-guard: skipping thread ${id} — originating comment carries no automation marker, treated as a maintainer finding (must not be agent-resolved, #1415)"
      continue
    fi
    if gh api graphql -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' \
        -f id="$id" >/dev/null 2>&1; then
      resolved_count=$((resolved_count + 1))
      echo "::notice::resolved outdated thread ${id} (author=${ACTOR})"
    else
      echo "::warning::failed to resolve outdated thread ${id}"
    fi
  done <<< "$pairs"
  echo "::notice::resolve_actor_outdated_threads: resolved ${resolved_count} outdated thread(s) on PR #${PR_NUMBER}"
}

# fetch_pr_context: exports CI_STATUS_JSON and ALL_REVIEWS_JSON for holistic assessment.
# Called before engine invocation in fix-reviews, fix-bot-comment, and review-changes
# so the agent can identify Tier-1 blockers (failing CI + CHANGES_REQUESTED reviews)
# and never wrongly declare "no-changes" while the PR is still blocked.
fetch_pr_context() {
  # Base branch: _ci_required_checks reads the ruleset for the PR's ACTUAL target
  # branch. Some intents (fix-bot-comment, review-changes) do not receive BASE_REF
  # from the workflow, so derive it from the PR here rather than falling back to
  # `main` — otherwise the ruleset lookup applies the wrong required-check rules to
  # a PR targeting another branch. Intents that already export BASE_REF are left
  # untouched (guarded on empty), and `main` remains the final fallback.
  if [ -z "${BASE_REF:-}" ] && [ -n "${PR_NUMBER:-}" ] && [ -n "${REPO:-}" ]; then
    BASE_REF="$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.base.ref // empty' 2>/dev/null || true)"
    export BASE_REF="${BASE_REF:-main}"
  fi

  # CI check results: requires HEAD_SHA. Gracefully degrade to empty array when not set
  # (e.g., review-changes in dry-run where the PR API call is skipped).
  CI_STATUS_JSON="[]"
  if [ -n "${HEAD_SHA:-}" ]; then
    # Two-stage check-run dedup:
    # Stage 1: group by (name, app.id, check_suite.id) and keep the highest-id
    #   run per suite. check_suite discriminates distinct workflow runs, so two
    #   workflows that happen to share a job name are kept as separate entries.
    #   id is always present and monotonically increasing, so it reliably picks
    #   the newest run even when started_at is absent (e.g. queued runs).
    # Stage 2: drop cancelled/timed_out runs when a newer run (higher id, same
    #   name+app) has a terminal non-cancelled conclusion. This collapses a
    #   concurrency-cancelled run from an earlier suite once its replacement
    #   succeeds, without hiding a genuinely failing check from a distinct
    #   workflow. A lone cancelled/timed_out run (no newer replacement) still
    #   counts as a Tier-1 blocker (issue #461).
    #
    # Stage 2 deliberately matches on (name, app) ACROSS suites — wider than
    # Stage 1's key. The asymmetry is load-bearing: a concurrency-cancelled
    # run is superseded by a run from a *different* event, which always lives
    # in a *different* check suite (the PR #453 incident shape), so requiring
    # suite equality here would never drop anything and would reintroduce the
    # endless 30-minute retry loop. The check-runs API exposes no workflow
    # identity, so a cancelled check from a sibling workflow sharing a
    # name+app with a newer success is also dropped — accepted trade-off:
    # GitHub's own required-check gate keys on the latest same-named run
    # (PR #453 merged with stale cancelled `review` runs still on its head
    # SHA), so such a PR is not actually merge-blocked. Failures are exempt
    # from Stage 2 (conservative: a real failure from a sibling workflow
    # stays visible to the agent even when GitHub would let the merge pass).
    if ! CI_STATUS_JSON=$(gh api --paginate "repos/${REPO}/commits/${HEAD_SHA}/check-runs?per_page=100" \
      2>/dev/null \
      | jq -s '[.[].check_runs[]?]
               | group_by([.name, (.app.id // null), (.check_suite.id // null)])
               | map(sort_by([.id // 0]) | last)
               | . as $runs
               | map(select(
                   (.conclusion != "cancelled" and .conclusion != "timed_out")
                   or (. as $r | ($runs | any(
                         .name == $r.name
                         and (.app.id // null) == ($r.app.id // null)
                         and (.id // 0) > ($r.id // 0)
                         and .conclusion != null
                         and .conclusion != "cancelled"
                         and .conclusion != "timed_out"
                       )) | not)
                 ))
               | map({name:.name, status:.status, conclusion:.conclusion, details_url:.details_url})' \
      2>/dev/null); then
      echo "::error::fetch_pr_context: failed to fetch CI check-runs for ${HEAD_SHA} — cannot assess PR state" >&2
      return 1
    fi
    # Also include legacy commit statuses (Jenkins, external CI, etc.) that use
    # the separate statuses API rather than check-runs. Merge into CI_STATUS_JSON
    # so the agent sees a unified picture of all required status checks.
    local statuses_json
    # The statuses API returns the full history per context (newest first).
    # Dedupe by context so a stale failure overwritten by a later success does not
    # appear as a Tier-1 blocker: group_by preserves input order within each group,
    # so `first` picks the newest entry for each context.
    if statuses_json=$(gh api --paginate "repos/${REPO}/commits/${HEAD_SHA}/statuses?per_page=100" \
      2>/dev/null \
      | jq -s '[ [.[].[] | select(.context != null)] | group_by(.context)[] | first | {name:.context, status:(if .state == "pending" then "in_progress" else "completed" end), conclusion:(if .state == "success" then "success" elif .state == "failure" or .state == "error" then "failure" else "pending" end), details_url:.target_url} ]' \
      2>/dev/null); then
      CI_STATUS_JSON=$(printf '%s\n%s' "$CI_STATUS_JSON" "$statuses_json" \
        | jq -s 'add // []' 2>/dev/null || echo "$CI_STATUS_JSON")
    else
      echo "::error::fetch_pr_context: failed to fetch legacy commit statuses for ${HEAD_SHA} — cannot assess PR state" >&2
      return 1
    fi
  fi
  export CI_STATUS_JSON

  # All PR reviews with state — deduplicated per reviewer (latest review per user only).
  # Uses --paginate so PRs with more than 100 reviews are fully covered.
  # COMMENTED reviews do not supersede a prior CHANGES_REQUESTED or APPROVED — only
  # non-COMMENTED reviews determine the effective blocking state per user.
  if ! ALL_REVIEWS_JSON=$(gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/reviews?per_page=100" \
    2>/dev/null \
    | jq -s '[ [.[].[] | select(.user != null)] | group_by(.user.login)[] | . as $g | (($g | map(select(.state != "COMMENTED")) | sort_by(.id) | last) // ($g | sort_by(.id) | last)) | {id:.id, user:.user.login, state:.state, submitted_at:.submitted_at, body:.body, all_change_request_bodies:($g | map(select(.state == "CHANGES_REQUESTED")) | sort_by(.id) | map(.body))} ]' \
    2>/dev/null); then
    echo "::error::fetch_pr_context: failed to fetch PR reviews for #${PR_NUMBER} — cannot assess PR state" >&2
    return 1
  fi
  export ALL_REVIEWS_JSON
}

# resolve_bot_outdated_threads: resolves all outdated review threads from bot reviewers.
# This is a cleanup function for the no-changes path: when no code changes are needed,
# we still want to mark outdated bot comments as resolved so they don't clutter the PR.
# Outdated threads reference code that no longer exists, so resolution is unambiguous.
#
# Paginated: fetches all threads via cursor pagination so PRs with >100 threads are
# fully covered. Unlike resolve_actor_outdated_threads, this resolves threads from ANY
# bot author (__typename == "Bot", or login ends with [bot]).
resolve_bot_outdated_threads() {
  local intent="$1"
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would resolve outdated review threads from bot reviewers on PR #${PR_NUMBER}"
    return 0
  fi

  if [ -z "${PR_NUMBER:-}" ]; then
    echo "::notice::resolve_bot_outdated_threads: PR_NUMBER not set for intent=${intent} — skipping"
    return 0
  fi

  # Collect IDs of all outdated unresolved bot threads via cursor pagination.
  # __typename == "Bot" covers bots whose GraphQL login omits the [bot] suffix;
  # endswith("[bot]") covers bots that include it — both checks together are belt-and-suspenders.
  local ids=""
  local cursor="" has_next_page="true" page_response page_ids
  local cursor_args=()
  local bot_outdated_query='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        reviewThreads(first:100,after:$cursor){
          pageInfo{hasNextPage endCursor}
          nodes{id isResolved isOutdated comments(first:1){nodes{author{login __typename}}}}
        }
      }
    }
  }'
  while [ "$has_next_page" = "true" ]; do
    page_response=$(gh api graphql -f query="$bot_outdated_query" \
      -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" \
      "${cursor_args[@]}" 2>/dev/null || echo "{}")
    page_ids=$(printf '%s' "$page_response" | jq -r \
      '.data?.repository?.pullRequest?.reviewThreads?.nodes // []
       | map(select(.isResolved == false
                    and .isOutdated == true
                    and (((.comments.nodes?[0]?.author?.login // "") | endswith("[bot]"))
                         or ((.comments.nodes?[0]?.author?.__typename // "") == "Bot"))))
       | .[].id' 2>/dev/null || true)
    [ -n "$page_ids" ] && ids=$(printf '%s\n%s' "$ids" "$page_ids")
    has_next_page=$(printf '%s' "$page_response" | jq -r \
      '.data?.repository?.pullRequest?.reviewThreads?.pageInfo?.hasNextPage // false' \
      2>/dev/null || echo "false")
    cursor=$(printf '%s' "$page_response" | jq -r \
      '.data?.repository?.pullRequest?.reviewThreads?.pageInfo?.endCursor // ""' \
      2>/dev/null || echo "")
    [ -z "$cursor" ] && has_next_page="false"
    cursor_args=("-f" "cursor=${cursor}")
  done
  # Strip leading/trailing blank lines from accumulated ids
  ids=$(printf '%s' "$ids" | sed '/^[[:space:]]*$/d')

  if [ -z "$ids" ]; then
    echo "::notice::no outdated unresolved threads from bot reviewers on PR #${PR_NUMBER}"
    return 0
  fi

  local resolved_count=0
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if gh api graphql -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' \
        -f id="$id" >/dev/null 2>&1; then
      resolved_count=$((resolved_count + 1))
      echo "::notice::resolved outdated bot thread ${id}"
    else
      echo "::warning::failed to resolve outdated bot thread ${id}"
    fi
  done <<< "$ids"
  echo "::notice::resolve_bot_outdated_threads: resolved ${resolved_count} outdated bot thread(s) on PR #${PR_NUMBER}"
}

# list_unresolved_bot_thread_ids: prints the ids of PR_NUMBER's unresolved review
# threads whose ORIGINATING comment is from a bot (__typename Bot, or a login with
# the [bot] suffix), one per line. Candidates only — callers re-read each thread
# before resolving it. Paginated via cursor (GraphQL 100/page max). Shared by
# resolve_addressed_bot_threads and resolve_deferred_bot_threads.
list_unresolved_bot_thread_ids() {
  local ids=""
  local cursor="" prev_cursor="" has_next_page="true" page_response page_ids
  local cursor_args=()
  local bot_threads_query='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        reviewThreads(first:100,after:$cursor){
          pageInfo{hasNextPage endCursor}
          nodes{
            id isResolved
            origin: comments(first:1){nodes{author{login __typename}}}
          }
        }
      }
    }
  }'
  while [ "$has_next_page" = "true" ]; do
    prev_cursor="$cursor"
    page_response=$(gh api graphql -f query="$bot_threads_query" \
      -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" \
      "${cursor_args[@]}" 2>/dev/null) || {
      echo "::error::failed to enumerate review threads for PR #${PR_NUMBER}" >&2
      return 1
    }
    if ! printf '%s' "$page_response" | jq -e '
        ((.errors // []) | length) == 0
        and ((.data?.repository?.pullRequest?.reviewThreads?.nodes? | type) == "array")
        and ((.data.repository.pullRequest.reviewThreads.pageInfo?.hasNextPage? | type) == "boolean")
        and (.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage == false
             or ((.data.repository.pullRequest.reviewThreads.pageInfo.endCursor? | type) == "string"
                 and (.data.repository.pullRequest.reviewThreads.pageInfo.endCursor | length) > 0))' \
        >/dev/null 2>&1; then
      echo "::error::review-thread page for PR #${PR_NUMBER} returned an error or malformed response" >&2
      return 1
    fi
    page_ids=$(printf '%s' "$page_response" | jq -r \
      '.data?.repository?.pullRequest?.reviewThreads?.nodes // []
       | map(select(.isResolved == false
                    and (((.origin.nodes?[0]?.author?.login // "") | endswith("[bot]"))
                         or ((.origin.nodes?[0]?.author?.__typename // "") == "Bot"))))
       | .[] | .id' 2>/dev/null || true)
    [ -n "$page_ids" ] && ids=$(printf '%s\n%s' "$ids" "$page_ids")
    has_next_page=$(printf '%s' "$page_response" | jq -r \
      '.data?.repository?.pullRequest?.reviewThreads?.pageInfo?.hasNextPage // false' \
      2>/dev/null || echo "false")
    cursor=$(printf '%s' "$page_response" | jq -r \
      '.data?.repository?.pullRequest?.reviewThreads?.pageInfo?.endCursor // ""' \
      2>/dev/null || echo "")
    [ -z "$cursor" ] && has_next_page="false"
    # A cursor that does not advance would re-read the same page forever.
    if [ "$has_next_page" = "true" ] && [ "$cursor" = "$prev_cursor" ]; then
      echo "::error::review-thread pagination for PR #${PR_NUMBER} did not advance (endCursor unchanged)" >&2
      return 1
    fi
    cursor_args=("-f" "cursor=${cursor}")
  done
  printf '%s\n' "$ids" | sed '/^[[:space:]]*$/d'
}

# resolve_addressed_bot_threads: resolves bot-originated review threads that dev-lead
# has already ADDRESSED in-thread but left unresolved (#1547). Every pr-quality ruleset
# sets required_review_thread_resolution:true, so such a thread — replied-to with
# "Applied in …" / "Verified and confirmed …" yet never resolved — leaves a fully green +
# approved PR silently unmergeable (the 2026-08-18 sweep hand-resolved 20 of these).
#
# Complements resolve_bot_outdated_threads: that net only covers isOutdated threads,
# but an addressed-at-head finding is frequently NOT marked outdated by GitHub. This
# net keys on the addressed-marker (`<!-- dev-lead:addressed -->`) in the thread's LAST
# reply instead of on outdated status, so a non-outdated but already-addressed thread is
# resolved. A *skip* reply carries no marker, so it is never auto-resolved.
#
# Scope guard (#1415): only BOT-originated threads are touched (originating comment
# author is a Bot). A marker-less human/maintainer finding is never resolved here — the
# #1415 resolve-guard applies to the owner-account ambiguity on human threads, and this
# net deliberately stays clear of them.
#
# Paginated via cursor (GraphQL 100/page max). The addressed-marker decision is delegated
# to review_reply_is_addressed_marker (maintainer-review-thread-gate.sh) so the marker is
# defined in exactly one place.
#
# The enumeration pass yields only candidate ids; the authorizing state (isResolved, the
# latest reply's author, and the marker) is re-read per candidate via a fresh node(id)
# fetch taken immediately before the mutation. This closes two gaps in the earlier
# snapshot-trusting design: (a) the marker only authorizes resolution when OUR account
# (BOT_USER, [bot]-suffix-stripped) posted it, so a marker-bearing reply from any other
# human or bot cannot resolve a bot thread; and (b) a reply that landed after enumeration
# is re-checked, so concurrent maintainer feedback can't be resolved against a stale
# snapshot. isResolved is branched on null explicitly so a failed fetch fails closed.
resolve_addressed_bot_threads() {
  local intent="$1"
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would resolve addressed review threads from bot reviewers on PR #${PR_NUMBER}"
    return 0
  fi

  if [ -z "${PR_NUMBER:-}" ]; then
    echo "::notice::resolve_addressed_bot_threads: PR_NUMBER not set for intent=${intent} — skipping"
    return 0
  fi

  # Our own account: the addressed-marker reply must have been posted by us before
  # it can authorize resolution. The acv_* thread helpers below derive the
  # [bot]-stripped form internally (GraphQL author.login omits the "[bot]" suffix),
  # so they match both the raw BOT_USER and its stripped form.
  local bot_user="${BOT_USER:-donpetry-bot}"

  # Attribute this pass's own replies to dev-lead BEFORE any thread is evaluated, on
  # every pass (even one with no candidates), so an unstamped skip note can never
  # become a later pass's "maintainer verdict" (#2079 AC4). On failure the no-change
  # path is disabled for this pass.
  local stamp_ok=1
  local nochange_epoch=""
  nochange_epoch=$(nochange_epoch_cutoff) || stamp_ok=0
  stamp_pass_replies || stamp_ok=0

  # The enumeration pass ONLY collects candidate thread ids (unresolved,
  # bot-originated). It deliberately does NOT capture the last reply's body or
  # author: that snapshot goes stale the moment a new reply lands, and trusting it
  # would (a) let a marker-bearing reply from any other account authorize
  # resolution (#codeant-623) and (b) resolve a thread a maintainer has since
  # replied to (#codeant-666). The authorizing state is re-read per candidate via a
  # fresh node(id) fetch taken immediately before the mutation below.
  local ids
  # A failed enumeration (e.g. a later pagination page) must not read as "no
  # candidates": propagate it so the caller records the pass as failed.
  ids=$(list_unresolved_bot_thread_ids) || {
    echo "::error::resolve_addressed_bot_threads: could not enumerate review threads on PR #${PR_NUMBER}"
    return 1
  }

  if [ -z "$(printf '%s' "$ids" | sed '/^[[:space:]]*$/d')" ]; then
    echo "::notice::no addressed unresolved bot threads on PR #${PR_NUMBER}"
    return 0
  fi

  # Full-thread fetch (#1692 AC4): the earlier `comments(last:1)` read saw only the
  # latest reply, so a maintainer disposition posted before the model appended its
  # marker went invisible (the PR #1044 hole). Read ALL comments — author login +
  # __typename + body + createdAt — plus the thread `path` for the AC3 advisory.
  local node_query='query($id:ID!){
    node(id:$id){
      ... on PullRequestReviewThread {
        isResolved
        path
        comments(first:100){pageInfo{hasNextPage} nodes{author{login __typename} authorAssociation body createdAt}}
      }
    }
  }'

  local resolved_count=0
  local id node_json cur_resolved comments_json marker_idx marker_body
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    # Re-read the thread's CURRENT state immediately before resolving so a reply
    # that landed after enumeration is not resolved against a stale snapshot.
    node_json=$(gh api graphql -f query="$node_query" -f id="$id" 2>/dev/null || echo "{}")
    # isResolved is branched on null explicitly (not `// false`) so a fetch that
    # failed to return the field is treated as "unknown" and skipped (fail closed),
    # never as a resolvable false.
    cur_resolved=$(printf '%s' "$node_json" | jq -r \
      'if .data.node.isResolved == null then "unknown"
       elif .data.node.isResolved then "true" else "false" end' 2>/dev/null || echo "unknown")
    if [ "$cur_resolved" != "false" ]; then
      echo "::notice::skipping thread ${id} — already resolved or state unknown at re-check (${cur_resolved})"
      continue
    fi
    # ── #1735: full-thread scan, not comments(last:1) ─────────────────────────
    # Our addressed-marker reply need NOT be the thread's LATEST comment. Find the
    # latest comment OUR account posted carrying the marker; a bot acknowledgement
    # (or our own later note) landing after it must not lock the thread unresolvable
    # forever (the regression #1691 exposed). A marker from any other account still
    # does not authorize resolution (acv_latest_marker_index checks the author).
    comments_json=$(printf '%s' "$node_json" | jq -c '.data.node.comments.nodes // []' 2>/dev/null || echo "[]")

    # ── No-change disposition path (#2079): a maintainer may authorize resolution ──
    # without an addressed-marker by asserting "no changes needed" or a false-positive
    # disposition. This is checked FIRST, before the addressed-marker path (#1735).
    local nochange_disposition nochange_rc
    # A truncated comment page may hide a later neutral maintainer comment that
    # supersedes the affirmation -> fail closed (skip this path) unless fully read.
    if [ "$stamp_ok" -eq 1 ] && [ "$(printf '%s' "$node_json" | jq -r 'if .data.node.comments.pageInfo.hasNextPage == false then "false" else "true" end' 2>/dev/null || echo true)" = "false" ]; then
      nochange_disposition=$(acv_latest_nochange_disposition "$comments_json" "$nochange_epoch") && nochange_rc=0 || nochange_rc=$?
    else
      nochange_disposition="" nochange_rc=1
    fi
    if [ "${nochange_rc:-0}" -eq 0 ] && [ -n "$nochange_disposition" ]; then
      # A no-change disposition was found. Re-read the thread immediately before
      # resolution to ensure it hasn't changed (no new required disposition or bot finding).
      local fresh_json fresh_resolved
      fresh_json=$(gh api graphql -f query="$node_query" -f id="$id" 2>/dev/null || echo "{}")
      fresh_resolved=$(printf '%s' "$fresh_json" | jq -r \
        'if .data.node.isResolved == null then "unknown"
         elif .data.node.isResolved then "true" else "false" end' 2>/dev/null || echo "unknown")
      if [ "$fresh_resolved" != "false" ]; then
        echo "::notice::skipping thread ${id} — already resolved during no-change check"
        continue
      fi
      local fresh_comments
      fresh_comments=$(printf '%s' "$fresh_json" | jq -c \
        'if .data.node.comments.pageInfo.hasNextPage == false then (.data.node.comments.nodes // []) else "changed" end' \
        2>/dev/null || echo '"changed"')
      if [ "$fresh_comments" != "$comments_json" ]; then
        echo "::notice::skipping thread ${id} — thread changed during no-change disposition check; leaving unresolved"
        continue
      fi
      # Reject if a newer required disposition exists (a REQUIRED overrides NO-CHANGE).
      # Only a REQUIRED disposition at/after the no-change verdict blocks; affirmative
      # no-change comments ("no change required") are excluded from the scan.
      local req_rc req_ts
      req_ts=$(acv_latest_maintainer_disposition "$fresh_comments" "__no-such-account__" "skip-nochange") && req_rc=0 || req_rc=$?
      if [ "${req_rc:-0}" -eq 2 ] || { [ "${req_rc:-0}" -eq 0 ] && [[ ! "$req_ts" < "$nochange_disposition" ]]; }; then
        echo "::notice::skipping thread ${id} — a required maintainer disposition blocks the no-change verdict; leaving unresolved (#2079)"
        continue
      fi
      # Reject if any bot comment postdates the no-change verdict (a newer bot finding
      # overrides it). A bot comment with no createdAt cannot be ordered -> fail closed.
      local newer_bot
      newer_bot=$(printf '%s' "$fresh_comments" | jq -r --arg t "$nochange_disposition" \
        'map(select(((.author.__typename // "") == "Bot" or ((.author.login // "") | endswith("[bot]")))
                    and (((.createdAt // "") == "") or (.createdAt > $t)))) | length' 2>/dev/null || echo "1")
      if [ "$newer_bot" != "0" ]; then
        echo "::notice::skipping thread ${id} — a bot comment postdates the no-change disposition; leaving unresolved (#2079)"
        continue
      fi
      if gh api graphql -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' \
          -f id="$id" >/dev/null 2>&1; then
        resolved_count=$((resolved_count + 1))
        echo "::notice::resolved bot thread ${id} due to no-change disposition (${nochange_disposition})"
      else
        echo "::warning::failed to resolve bot thread ${id} despite no-change disposition"
      fi
      continue
    elif [ "${nochange_rc:-0}" -eq 2 ]; then
      echo "::notice::skipping thread ${id} — a no-change disposition could not be parsed; leaving unresolved (fail closed) (#2079)"
      continue
    fi

    if ! marker_idx=$(acv_latest_marker_index "$comments_json" "$bot_user"); then
      echo "::notice::skipping thread ${id} — no addressed-marker reply from our account in the thread; leaving unresolved (#1735)"
      continue
    fi
    marker_body=$(printf '%s' "$comments_json" | jq -r --argjson i "$marker_idx" '.[$i]?.body // ""' 2>/dev/null || echo "")

    # Nothing UNADDRESSED may have landed since our marker (#1735 AC2/AC3/AC4): a bot
    # acknowledgement is fine, but a bot NEW finding or ANY human comment (regardless
    # of content, preserving #1415) blocks, and an undeterminable post-marker comment
    # fails closed. This composes with the #1692 claim gate below (AC5) — both must pass.
    local post_reason post_rc
    post_reason=$(acv_post_marker_clear "$comments_json" "$marker_idx" "$bot_user") && post_rc=0 || post_rc=$?
    if [ "${post_rc:-0}" -ne 0 ]; then
      echo "::notice::skipping thread ${id} — an unaddressed comment landed after our marker (${post_reason}); leaving unresolved (#1735)"
      continue
    fi

    # ── #1692: the marker is now a VERIFIABLE CLAIM, not an assertion ──────────
    # A marker with no claim payload (pre-migration replies) is unverifiable — do
    # NOT resolve (the safe direction; may leave some existing threads open until
    # re-run). A malformed/contract-violating claim is likewise unverifiable.
    local claim_json parse_reason
    if ! claim_json=$(acv_parse_claim "$marker_body"); then
      parse_reason="$claim_json"
      echo "::notice::skipping thread ${id} — addressed-marker claim not verifiable (${parse_reason:-unparseable}); leaving unresolved (#1692)"
      continue
    fi
    local claim_sha
    claim_sha=$(printf '%s' "$claim_json" | jq -r '.sha // ""' 2>/dev/null || echo "")

    # Gather the git facts for the claimed commit (the only impure step). Fail
    # closed: an unresolvable commit reads as on_head=false with empty diffs.
    local facts on_head in_base in_pass own_files cumulative_files commit_date
    facts=$(acv_gather_commit_facts "$claim_sha" "${RESOLUTION_BASE_SHA:-}")
    on_head=$(printf '%s' "$facts" | jq -r '.on_head // false' 2>/dev/null || echo "false")
    if [ "$on_head" != "true" ]; then
      echo "::notice::skipping thread ${id} — claimed commit ${claim_sha} is not on PR #${PR_NUMBER}'s head branch; leaving unresolved (#1692)"
      continue
    fi
    # #2013: the claimed commit must be one THIS pass produced — not the PR's first
    # commit or any other pre-pass ancestor, which passes the on-head + intersection
    # checks trivially (the petry-projects/.github#1220 `571a3b8` case). Parity with
    # the issue-comment `fixed` check in resolve_dispositioned_comments (#1813).
    in_base=$(printf '%s' "$facts" | jq -r 'if .in_base == false then "false" else "true" end' 2>/dev/null || echo "true")
    if ! in_pass=$(acv_claim_in_pass "${RESOLUTION_BASE_SHA:-}" "$on_head" "$in_base"); then
      echo "::notice::skipping thread ${id} — claimed commit ${claim_sha} was not produced by this pass (${in_pass}; base=${RESOLUTION_BASE_SHA:-<unset>}); leaving unresolved (#2013)"
      continue
    fi
    own_files=$(printf '%s' "$facts" | jq -r '.own_files[]? // empty' 2>/dev/null || echo "")
    cumulative_files=$(printf '%s' "$facts" | jq -r '.cumulative_files[]? // empty' 2>/dev/null || echo "")
    commit_date=$(printf '%s' "$facts" | jq -r '.commit_date // ""' 2>/dev/null || echo "")

    # File-level hard gate (AC2): non-empty diff touching ≥1 claimed file, named
    # commit's own diff first then the cumulative <sha>^..HEAD range.
    local claim_files_json verify_range
    claim_files_json=$(printf '%s' "$claim_json" | jq -c '.files' 2>/dev/null || echo "[]")
    if ! verify_range=$(acv_verify_intersection "$claim_files_json" "$own_files" "$cumulative_files"); then
      echo "::notice::skipping thread ${id} — claim ${claim_sha} not verified against the diff (${verify_range}); leaving unresolved (#1692)"
      continue
    fi
    if [ "$verify_range" = "cumulative" ]; then
      echo "::notice::thread ${id} verified from the cumulative range ${claim_sha}^..HEAD (fix amended/split across commits) (#1692)"
    fi

    # AC3: file-level is the hard gate; region proximity is advisory. If the claim's
    # files do not include the thread's own path, still resolve but surface the
    # mismatch so it is visible without producing a false block.
    local thread_path
    thread_path=$(printf '%s' "$node_json" | jq -r '.data.node.path // ""' 2>/dev/null || echo "")
    if [ -n "$thread_path" ]; then
      local path_in_claim
      path_in_claim=$(printf '%s' "$claim_json" | jq -r --arg p "$thread_path" 'if (.files | index($p)) != null then "yes" else "no" end' 2>/dev/null || echo "no")
      if [ "$path_in_claim" != "yes" ]; then
        echo "::warning::thread ${id}: claimed files do not include the thread's path '${thread_path}' (claim: $(printf '%s' "$claim_files_json")) — resolving on the file-level gate, but the region mismatch is advisory (#1692 AC3)"
      fi
    fi

    # AC4: honour a standing maintainer disposition. Scan ALL comments (reusing the
    # comments_json captured above); if a marker-less human maintainer asserted a
    # required disposition, resolve only if the verified commit postdates it.
    # Unparseable disposition -> fail closed.
    local disposition disp_rc
    disposition=$(acv_latest_maintainer_disposition "$comments_json" "$bot_user") && disp_rc=0 || disp_rc=$?
    if [ "${disp_rc:-0}" -eq 2 ]; then
      echo "::notice::skipping thread ${id} — a maintainer disposition could not be parsed; leaving unresolved (fail closed) (#1692 AC4)"
      continue
    fi
    if [ "${disp_rc:-0}" -eq 0 ] && [ -n "$disposition" ]; then
      # Require the verified-commit date strictly after the disposition. Both are
      # Z-terminated UTC ISO-8601 instants of identical width (commit_date from
      # acv_gather_commit_facts, disposition from GitHub's createdAt), so a pure
      # Bash lexicographical compare orders them chronologically — no jq needed,
      # matching the same comparison acv_latest_maintainer_disposition uses.
      local newer="false"
      if [ -n "$commit_date" ] && [[ "$commit_date" > "$disposition" ]]; then
        newer="true"
      fi
      if [ "$newer" != "true" ]; then
        echo "::notice::skipping thread ${id} — a maintainer disposition (${disposition}) is not postdated by the verified fix (${commit_date:-unknown}); leaving unresolved (#1692 AC4)"
        continue
      fi
    fi

    if gh api graphql -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' \
        -f id="$id" >/dev/null 2>&1; then
      resolved_count=$((resolved_count + 1))
      echo "::notice::resolved addressed bot thread ${id} (claim ${claim_sha} verified via ${verify_range} range)"
    else
      echo "::warning::failed to resolve addressed bot thread ${id}"
    fi
  done <<< "$ids"
  echo "::notice::resolve_addressed_bot_threads: resolved ${resolved_count} addressed bot thread(s) on PR #${PR_NUMBER}"
}

# ── `fixed` disposition verification by diff content (#2004) ─────────────────
# A `fixed` disposition must cite the commit whose diff addresses the finding. On
# PR #1977 one cited the commit that INTRODUCED the finding; under the old "this
# pass produced the sha" rule that failed silently, so the comment never minimized
# and dev-lead never re-answered. The judgement is the pure cdv_fixed_verdict.
# These helpers gather its git facts.

# rdc_fixed_refs — set RDC_FIXED_REF (the PR's pushed head) and RDC_FIXED_BASE
# (the base branch tip). Same reference-head rule as retract_unlanded_claims: the
# remote head; the local HEAD only when there is no upstream (rc 1) on a pass whose
# push succeeded. An unreadable remote leaves RDC_FIXED_REF empty, so every cited
# sha is not-on-head (fail closed). An unreadable base leaves RDC_FIXED_BASE empty
# (base-unknown).
rdc_fixed_refs() {
  local ref_rc=0 baseref="origin/${BASE_REF:-main}"
  RDC_FIXED_REF=$(cl_remote_head) || ref_rc=$?
  if [ -z "$RDC_FIXED_REF" ] && [ "$ref_rc" -eq 1 ]; then
    RDC_FIXED_REF="$(git rev-parse HEAD 2>/dev/null || true)"
  fi
  local base_rc=0
  RDC_FIXED_BASE=$(git rev-parse --verify --quiet "${baseref}^{commit}" 2>/dev/null) || base_rc=$?
  if [ "$base_rc" -ne 0 ]; then
    git fetch --quiet origin "${BASE_REF:-main}" 2>/dev/null || true
    RDC_FIXED_BASE=$(git rev-parse --verify --quiet "${baseref}^{commit}" 2>/dev/null || true)
  fi
}

# rdc_commit_diff <sha> — the commit's own diff, without its message or context lines.
rdc_commit_diff() {
  git show --format= --no-color --no-ext-diff --no-renames -U0 "$1" 2>/dev/null || true
}

# rdc_fixed_verdict <sha> <finding_body> <finding_created>
#   Echo cdv_fixed_verdict's reason for <sha> against the finding; rc 0 = verified.
rdc_fixed_verdict() {
  local sha="$1" body="$2" created="$3"
  local facts on_head="false" in_base="unknown" own_files=0 commit_date="" content this_pass="false"
  if [ -n "${RDC_FIXED_REF:-}" ]; then
    facts=$(acv_gather_commit_facts "$sha" "${RDC_FIXED_BASE:-}" "$RDC_FIXED_REF")
    on_head=$(printf '%s' "$facts" | jq -r '.on_head // false' 2>/dev/null || echo "false")
    if [ -n "${RDC_FIXED_BASE:-}" ]; then
      in_base=$(printf '%s' "$facts" | jq -r 'if .in_base == false then "false" else "true" end' 2>/dev/null || echo "true")
    fi
    own_files=$(printf '%s' "$facts" | jq -r '(.own_files // []) | length' 2>/dev/null || echo "0")
    commit_date=$(printf '%s' "$facts" | jq -r '.commit_date // ""' 2>/dev/null || echo "")
  fi
  # A tokenless finding verifies only on a commit this pass produced: one not
  # reachable from the pre-pass head. No snapshot or an unreadable sha is "no".
  if [ -n "${RESOLUTION_BASE_SHA:-}" ] \
     && git cat-file -e "${sha}^{commit}" 2>/dev/null \
     && ! git merge-base --is-ancestor "$sha" "$RESOLUTION_BASE_SHA" 2>/dev/null; then
    this_pass="true"
  fi
  content=$(cdv_diff_token_verdict "$(rdc_commit_diff "$sha")" "$(cdv_finding_tokens "$body")") || true
  cdv_fixed_verdict "$on_head" "$in_base" "$own_files" "$commit_date" "$created" "$content" "$this_pass"
}

# rdc_live_comment_body <comment_node_id>
# Prints the comment's CURRENT body, fetched fresh. Returns 1 if it cannot be read.
rdc_live_comment_body() {
  local out
  out=$(gh api graphql -f query='query($id:ID!){node(id:$id){... on IssueComment{body}}}' \
    -f id="$1" 2>/dev/null | jq -r '.data.node.body // empty' 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# rdc_find_fixing_commit <finding_body> <finding_created>
#   Echo the newest PR-branch commit (base..head, merges excluded)
#   whose own diff removes one of the finding's tokens and passes every other
#   check; rc 1 when there is none. Never searches for a tokenless finding: with no
#   token, any later commit would qualify, which fails open.
rdc_find_fixing_commit() {
  local body="$1" created="$2" c reason tokens
  tokens=$(cdv_finding_tokens "$body") || true
  [ -n "$tokens" ] || return 1
  [ -n "${RDC_FIXED_REF:-}" ] && [ -n "${RDC_FIXED_BASE:-}" ] || return 1
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    reason=$(rdc_fixed_verdict "$c" "$body" "$created") || {
      # Newest-first: a newer commit that re-adds the token means it is still present.
      [ "$reason" = "content-adds-token" ] && return 1
      continue
    }
    [ "$reason" = "content-removes-token" ] || continue
    echo "$c"
    return 0
  done < <(git rev-list --no-merges "${RDC_FIXED_BASE}..${RDC_FIXED_REF}" 2>/dev/null || true)
  return 1
}

# resolve_deferred_bot_threads: resolves bot-originated review threads whose finding
# dev-lead judged valid but OUT OF SCOPE and deferred to a tracking issue (#2045) —
# the review-thread sibling of the issue-comment `out-of-scope` disposition (#1813).
# Before this, a deferral was a marker-less skip note, so the thread stayed
# unresolved forever under required_review_thread_resolution (PR #1953: five Codex
# threads, hand-resolved by a maintainer).
#
# A thread is resolved only when ALL of these hold on a fresh re-read:
#   - it is unresolved and bot-originated (never a maintainer thread, #1415);
#   - OUR account's latest reply carries exactly one
#     `<!-- dev-lead:deferred ref=#<n> -->` (dtv_parse_deferral);
#   - nothing unaddressed landed after that reply (acv_post_marker_clear, #1735);
#   - no marker-less maintainer asserted a "required" disposition anywhere in the
#     thread (acv_latest_maintainer_disposition). A deferral fixes nothing, so it
#     can never overrule one, older or newer; an unparseable one fails closed;
#   - #<n> is an open issue (not a PR) whose body or comments link this thread
#     (dtv_verify_tracking_issue).
# Any failed check leaves the thread open (fail closed).
#
# A deferral produces no commit, so callers run this OUTSIDE the #1617 head-advance
# resolution gate — on commit and no-commit passes alike.
# _dtv_fetch_and_verify_tracker <ref> <thread_id> <origin_db_id>: fetches the
# tracking issue and its comments fresh and runs dtv_verify_tracking_issue on them.
# Echoes the verdict and returns its status; an unreadable issue fails closed.
_dtv_fetch_and_verify_tracker() {
  local ref="$1" thread_id="$2" origin_db_id="$3"
  local issue_json issue_comments
  local issue_err
  issue_err=$(mktemp 2>/dev/null) || issue_err="/dev/null"
  if ! issue_json=$(gh api "repos/${REPO}/issues/${ref}" 2>"$issue_err"); then
    # Only a genuine 404 means the issue is missing. Any other failure (5xx, rate
    # limit, network) fails closed as unreadable so the caller counts it.
    # gh writes the error body to stdout (captured in issue_json) and the status to stderr.
    # Require the explicit status (stderr `(HTTP 404)`) or the exact error object
    # (`{"message":"Not Found"}`); arbitrary "Not Found" text must not downgrade.
    if ! { grep -qE '\(HTTP 404\)' "$issue_err" 2>/dev/null \
           || printf '%s' "$issue_json" | jq -e 'type == "object" and .message == "Not Found" and ((.status // "404") | tostring) == "404"' >/dev/null 2>&1; }; then
      [ "$issue_err" != "/dev/null" ] && rm -f "$issue_err"
      echo "issue-unreadable"
      return 2
    fi
    issue_json=""
  fi
  [ "$issue_err" != "/dev/null" ] && rm -f "$issue_err"
  # A failed page must not read as "no comments" (that would surface as no-mention
  # and skip the thread without counting a failure): fail closed as unreadable.
  local raw_comments
  if [ -z "$issue_json" ]; then
    # Confirmed nonexistent issue (404): the verifier reports `missing`; no comments to fetch.
    dtv_verify_tracking_issue "" "[]" "$thread_id" "$origin_db_id" "$REPO" "$PR_NUMBER"
    return
  fi
  raw_comments=$(gh api --paginate "repos/${REPO}/issues/${ref}/comments?per_page=100" 2>/dev/null) || {
    echo "comments-unreadable"
    return 2
  }
  issue_comments=$(printf '%s' "$raw_comments" | jq -cs 'add // []' 2>/dev/null) || {
    echo "comments-unreadable"
    return 2
  }
  dtv_verify_tracking_issue "$issue_json" "$issue_comments" "$thread_id" "$origin_db_id" "$REPO" "$PR_NUMBER"
}

resolve_deferred_bot_threads() {
  local intent="$1"
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would resolve deferred review threads from bot reviewers on PR #${PR_NUMBER}"
    return 0
  fi
  if [ -z "${PR_NUMBER:-}" ]; then
    echo "::notice::resolve_deferred_bot_threads: PR_NUMBER not set for intent=${intent} — skipping"
    return 0
  fi

  local bot_user="${BOT_USER:-donpetry-bot}"
  # Stamp this pass's own replies before evaluating any thread (#2079 AC4); on failure
  # the no-change path is disabled for this pass.
  local stamp_ok=1
  local nochange_epoch=""
  nochange_epoch=$(nochange_epoch_cutoff) || stamp_ok=0
  stamp_pass_replies || stamp_ok=0
  local ids
  ids=$(list_unresolved_bot_thread_ids) || {
    echo "::error::resolve_deferred_bot_threads: could not enumerate review threads on PR #${PR_NUMBER}"
    return 1
  }
  if [ -z "$ids" ]; then
    echo "::notice::no unresolved bot threads to check for deferrals on PR #${PR_NUMBER}"
    return 0
  fi

  local node_query='query($id:ID!){
    node(id:$id){
      ... on PullRequestReviewThread {
        isResolved
        comments(first:100){pageInfo{hasNextPage} nodes{author{login __typename} authorAssociation body createdAt lastEditedAt fullDatabaseId}}
      }
    }
  }'

  # ok | more (a second page of comments) | unknown (errors or a malformed connection).
  local snapshot_state_jq='if ((.errors // []) | length) > 0 then "unknown"
    elif (.data.node.comments.nodes | type) != "array" then "unknown"
    elif (.data.node.comments.pageInfo.hasNextPage | type) != "boolean" then "unknown"
    elif .data.node.comments.pageInfo.hasNextPage then "more" else "ok" end'
  local resolved_count=0 failed_count=0
  local id node_json cur_resolved comments_json origin_bot reply_idx reply_body
  local ref parse_rc post_reason post_rc disp_rc origin_db_id
  local verdict
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    # An unreadable candidate snapshot is a resolver failure, not "not resolvable":
    # a verified deferral may remain merge-blocking and a terminal marker may already
    # suppress retry, so surface it via failed_count.
    node_json=$(gh api graphql -f query="$node_query" -f id="$id" 2>/dev/null) || node_json=""
    cur_resolved=$(printf '%s' "$node_json" | jq -r \
      'if .data.node.isResolved == null then "unknown"
       elif .data.node.isResolved then "true" else "false" end' 2>/dev/null || echo "unknown")
    if [ "$cur_resolved" = "unknown" ]; then
      echo "::warning::could not read review thread ${id} while checking deferrals"
      failed_count=$((failed_count + 1))
      continue
    fi
    [ "$cur_resolved" = "false" ] || continue
    # A partial snapshot (GraphQL errors, or a comments connection without a nodes
    # array or boolean pagination) is unreadable, not "no deferral": counting it as
    # empty would let the caller post a terminal over an unevaluated thread.
    local page_state
    page_state=$(printf '%s' "$node_json" | jq -r "$snapshot_state_jq" 2>/dev/null || echo unknown)
    if [ "$page_state" = "unknown" ]; then
      echo "::warning::partial snapshot of review thread ${id} while checking deferrals"
      failed_count=$((failed_count + 1))
      continue
    fi
    # Fail closed on a thread longer than one page: later replies could supersede
    # the deferral and we would not see them.
    if [ "$page_state" = "more" ]; then
      echo "::notice::skipping thread ${id} — more than 100 comments; leaving unresolved (#2045)"
      continue
    fi
    comments_json=$(printf '%s' "$node_json" | jq -c '.data.node.comments.nodes' 2>/dev/null || echo "[]")

    # Re-check the bot origin on the fresh read: a maintainer thread is never ours
    # to resolve (#1415), even if the enumeration snapshot said otherwise.
    origin_bot=$(printf '%s' "$comments_json" | jq -r \
      '.[0].author as $a | if (($a.__typename // "") == "Bot") or (($a.login // "") | endswith("[bot]"))
       then "yes" else "no" end' 2>/dev/null || echo "no")
    [ "$origin_bot" = "yes" ] || continue

    # Expected nonzero returns are captured via `||` so `set -e` never aborts the pass.
    reply_idx=$(dtv_latest_own_reply_index "$comments_json" "$bot_user") || continue
    [ -n "$reply_idx" ] || continue
    reply_body=$(printf '%s' "$comments_json" | jq -r --argjson i "$reply_idx" '.[$i].body // ""' 2>/dev/null || echo "")
    parse_rc=0
    ref=$(dtv_parse_deferral "$reply_body") || parse_rc=$?
    if [ "$parse_rc" -ne 0 ]; then
      # Most threads simply carry no deferral. A malformed deferral attempt is a
      # failure, not a skip: the thread stays merge-blocking, so no terminal may be
      # posted over it and the pass must stay retryable.
      if [ "$ref" != "no-deferral" ]; then
        echo "::warning::thread ${id} — deferral marker not verifiable (${ref}); leaving unresolved (#2045)"
        failed_count=$((failed_count + 1))
      fi
      continue
    fi

    # A finding edited after our deferral was not the finding we deferred (#2008):
    # leave it for the next pass. An unreadable edit time fails closed the same way.
    local edited_after
    edited_after=$(printf '%s' "$comments_json" | jq -r --argjson i "$reply_idx" '
      .[0] as $o | (.[$i].createdAt // "") as $r
      | if ($o | type) != "object" or ($o | has("lastEditedAt") | not) or $r == "" then "unknown"
        elif $o.lastEditedAt == null then "no"
        elif ($o.lastEditedAt | type) != "string" then "unknown"
        elif $o.lastEditedAt > $r then "yes" else "no" end' 2>/dev/null || echo "unknown")
    if [ "$edited_after" = "yes" ]; then
      echo "::notice::skipping thread ${id} — the bot finding was edited after our deferral; leaving unresolved (#2045)"
      continue
    elif [ "$edited_after" != "no" ]; then
      # Unreadable is a resolver failure, not a skip: a terminal marker must not
      # be posted over a thread we could not evaluate.
      echo "::warning::could not read the edit time of review thread ${id} while checking deferrals"
      failed_count=$((failed_count + 1))
      continue
    fi

    post_rc=0
    post_reason=$(acv_post_marker_clear "$comments_json" "$reply_idx" "$bot_user") || post_rc=$?
    if [ "$post_rc" -ne 0 ]; then
      echo "::notice::skipping thread ${id} — an unaddressed comment landed after our deferral (${post_reason}); leaving unresolved (#2045)"
      continue
    fi

    # Check for a no-change disposition before checking for required disposition or deferral (#2079 AC1).
    # A maintainer's "no change needed" verdict can resolve the thread without a deferral.
    local nochange_disposition nochange_rc
    if [ "$stamp_ok" -eq 1 ]; then
      nochange_disposition=$(acv_latest_nochange_disposition "$comments_json" "$nochange_epoch") && nochange_rc=0 || nochange_rc=$?
    else
      nochange_disposition="" nochange_rc=1
    fi
    if [ "${nochange_rc:-0}" -eq 0 ] && [ -n "$nochange_disposition" ]; then
      # A no-change disposition was found. Re-read the thread immediately before resolution.
      local fresh_json fresh_resolved fresh_comments
      fresh_json=$(gh api graphql -f query="$node_query" -f id="$id" 2>/dev/null) || fresh_json=""
      fresh_resolved=$(printf '%s' "$fresh_json" | jq -r \
        'if .data.node.isResolved == null then "unknown"
         elif .data.node.isResolved then "true" else "false" end' 2>/dev/null || echo "unknown")
      if [ "$fresh_resolved" = "unknown" ]; then
        echo "::warning::could not re-read review thread ${id} during no-change check"
        failed_count=$((failed_count + 1))
        continue
      fi
      if [ "$fresh_resolved" != "false" ]; then
        echo "::notice::skipping thread ${id} — already resolved during no-change check"
        continue
      fi
      fresh_comments=$(printf '%s' "$fresh_json" | jq -c \
        'if .data.node.comments.pageInfo.hasNextPage == false then (.data.node.comments.nodes // []) else "changed" end' \
        2>/dev/null || echo '"changed"')
      if [ "$fresh_comments" != "$comments_json" ]; then
        echo "::notice::skipping thread ${id} — thread changed during no-change disposition check; leaving unresolved"
        continue
      fi
      # Reject if a newer required disposition exists (a REQUIRED overrides NO-CHANGE).
      local req_rc req_ts
      req_ts=$(acv_latest_maintainer_disposition "$fresh_comments" "__no-such-account__" "skip-nochange") && req_rc=0 || req_rc=$?
      if [ "${req_rc:-0}" -eq 2 ] || { [ "${req_rc:-0}" -eq 0 ] && [[ ! "$req_ts" < "$nochange_disposition" ]]; }; then
        echo "::notice::skipping thread ${id} — a required maintainer disposition blocks the no-change verdict; leaving unresolved (#2079)"
        continue
      fi
      # Reject if any bot comment postdates the no-change verdict (a newer bot finding overrides it).
      local newer_bot
      newer_bot=$(printf '%s' "$fresh_comments" | jq -r --arg t "$nochange_disposition" \
        'map(select(((.author.__typename // "") == "Bot" or ((.author.login // "") | endswith("[bot]")))
                    and (((.createdAt // "") == "") or (.createdAt > $t)))) | length' 2>/dev/null || echo "1")
      if [ "$newer_bot" != "0" ]; then
        echo "::notice::skipping thread ${id} — a bot comment postdates the no-change disposition; leaving unresolved (#2079)"
        continue
      fi
      if gh api graphql -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' \
          -f id="$id" >/dev/null 2>&1; then
        resolved_count=$((resolved_count + 1))
        echo "::notice::resolved deferred bot thread ${id} due to no-change disposition (${nochange_disposition})"
      else
        echo "::warning::failed to resolve deferred bot thread ${id} despite no-change disposition"
        failed_count=$((failed_count + 1))
      fi
      continue
    elif [ "${nochange_rc:-0}" -eq 2 ]; then
      echo "::notice::skipping thread ${id} — a no-change disposition could not be parsed; leaving unresolved (fail closed) (#2079)"
      continue
    fi

    # Pass a sentinel instead of ${bot_user}: in production BOT_USER is the same
    # account the human maintainer uses, so excluding by login would hide the
    # maintainer's own "required" disposition. The marker (our deferral reply carries
    # `<!-- dev-lead:deferred`) is what tells our comments apart.
    acv_latest_maintainer_disposition "$comments_json" "__no-such-account__" >/dev/null && disp_rc=0 || disp_rc=$?
    if [ "$disp_rc" -ne 1 ]; then
      echo "::notice::skipping thread ${id} — a maintainer disposition is present (or unparseable); a deferral cannot overrule it; leaving unresolved (#2045)"
      continue
    fi

    # fullDatabaseId (BigInt, a JSON string): comment ids now exceed the 32-bit
    # Int that `databaseId` returns. Without a readable id the tracker cannot be
    # matched by its `#discussion_r<id>` link, so the thread is a failure.
    origin_db_id=$(printf '%s' "$comments_json" | jq -r '.[0].fullDatabaseId // "" | tostring' 2>/dev/null || echo "")
    if ! [[ "$origin_db_id" =~ ^[1-9][0-9]*$ ]]; then
      echo "::warning::could not read the originating comment id of review thread ${id} while checking deferrals"
      failed_count=$((failed_count + 1))
      continue
    fi
    local verdict_rc=0
    verdict=$(_dtv_fetch_and_verify_tracker "$ref" "$id" "$origin_db_id") || verdict_rc=$?
    if [ "$verdict_rc" -ne 0 ]; then
      { [ "$verdict" = "comments-unreadable" ] || [ "$verdict" = "issue-unreadable" ]; } && failed_count=$((failed_count + 1))
      echo "::notice::skipping thread ${id} — tracking issue #${ref} cannot back the deferral (${verdict}); leaving unresolved (#2045)"
      continue
    fi

    # Re-fetch and re-verify the tracking issue immediately before the mutation: it
    # may have been closed, converted, or edited to drop the thread link meanwhile.
    verdict_rc=0
    verdict=$(_dtv_fetch_and_verify_tracker "$ref" "$id" "$origin_db_id") || verdict_rc=$?
    if [ "$verdict_rc" -ne 0 ]; then
      { [ "$verdict" = "comments-unreadable" ] || [ "$verdict" = "issue-unreadable" ]; } && failed_count=$((failed_count + 1))
      echo "::notice::skipping thread ${id} — tracking issue #${ref} no longer backs the deferral (${verdict}); leaving unresolved (#2045)"
      continue
    fi

    # The tracking-issue calls above took time: as the LAST read before the mutation,
    # re-read the thread and require it to be unchanged (still unresolved, same
    # comments) so a reply that landed meanwhile is never overridden.
    local fresh_json fresh_comments
    fresh_json=$(gh api graphql -f query="$node_query" -f id="$id" 2>/dev/null) || fresh_json=""
    if [ "$(printf '%s' "$fresh_json" | jq -r 'if .data.node.isResolved == null then "unknown" else "ok" end' 2>/dev/null || echo unknown)" = "unknown" ] \
       || [ "$(printf '%s' "$fresh_json" | jq -r "$snapshot_state_jq" 2>/dev/null || echo unknown)" = "unknown" ]; then
      echo "::warning::could not re-read review thread ${id} before resolving its deferral"
      failed_count=$((failed_count + 1))
      continue
    fi
    fresh_comments=$(printf '%s' "$fresh_json" | jq -c \
      'if .data.node.isResolved == false and .data.node.comments.pageInfo.hasNextPage == false
       then .data.node.comments.nodes else "changed" end' 2>/dev/null || echo '"changed"')
    if [ "$fresh_comments" != "$comments_json" ]; then
      echo "::notice::skipping thread ${id} — thread changed while verifying the tracking issue; leaving unresolved (#2045)"
      continue
    fi

    resolve_resp=$(gh api graphql -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' \
        -f id="$id" 2>/dev/null) || resolve_resp=""
    if [ "$(printf '%s' "$resolve_resp" | jq -r '.data.resolveReviewThread.thread.isResolved // false' 2>/dev/null)" = "true" ]; then
      resolved_count=$((resolved_count + 1))
      echo "::notice::resolved deferred bot thread ${id} (tracked in #${ref})"
    else
      echo "::warning::failed to resolve deferred bot thread ${id}"
      failed_count=$((failed_count + 1))
    fi
  done <<< "$ids"
  echo "::notice::resolve_deferred_bot_threads: resolved ${resolved_count} deferred bot thread(s) on PR #${PR_NUMBER}"
  # A verified deferral whose resolve mutation failed must not read as success.
  [ "$failed_count" -eq 0 ]
}

# resolve_dispositioned_comments: the issue-comment sibling of
# resolve_addressed_bot_threads (#1813). A PR *issue comment* (from `gh pr comment`
# or the GitHub main comment box) creates no review thread, so it is invisible to
# the thread-resolution path above. The maintainer-comment gate withholds
# pr-review's approval while ANY non-agent issue comment lacks a VERIFIED
# DISPOSITION, surfaced server-side as the comment being minimized RESOLVED. This
# net supplies that signal: for each undispositioned non-agent comment it locates
# dev-lead's single disposition reply, VERIFIES the disposition against ground
# truth (the pushed diff for `fixed`, the tracking issue for `out-of-scope`, a
# non-empty evidence reply for invalid/answered/informational), and — when
# cdv_authorize permits — minimizes the ORIGINAL comment RESOLVED (never the
# model; the harness alone resolves, #1813 AC4).
#
# Authorship (#1813 AC5): is_human is the server's own classification
# (author.__typename == "User"). A human maintainer's comment is auto-resolved
# ONLY on a verified `fixed` (an agent can never dismiss a person's finding by
# arguing it away); a bot's comment resolves on any verified disposition.
#
# Loop safety (#860 / AC7): candidate enumeration excludes our own account and any
# comment carrying an agent marker (which includes the `dev-lead:comment-disposition`
# reply itself), so our replies are never themselves treated as findings. The pass
# is idempotent — an already-minimized comment is filtered out — and every decision
# is delegated to the pure cdv_*/acv_* verifiers so it fails closed on any ambiguity.
# fbc_target_resolved: prints "yes" when the comment this fix-bot-comment pass was
# dispatched for (COMMENT_NODE_ID) is now minimized RESOLVED, "no" when it is not,
# and "unknown" when its state cannot be read. A pass that ends without a verified
# disposition for its comment must not post a terminal marker: the #2017 retry
# reads that marker as "this pass completed on the comment" and would never
# re-dispatch it, stranding the comment at the maintainer gate.
fbc_target_resolved() {
  [[ "${COMMENT_NODE_ID:-}" =~ ^[-A-Za-z0-9_+/=]+$ ]] || { echo "unknown"; return 0; }
  gh api graphql -f query='query($id:ID!){node(id:$id){... on IssueComment{isMinimized minimizedReason}}}' \
    -f id="$COMMENT_NODE_ID" 2>/dev/null \
    | jq -r 'if (.data.node.isMinimized | type) != "boolean" then "unknown"
             elif .data.node.isMinimized and ((.data.node.minimizedReason // "") | ascii_downcase) == "resolved" then "yes"
             else "no" end' 2>/dev/null || echo "unknown"
}

# resolve_dispositioned_comments: minimize PR issue comments that carry a verified disposition.
resolve_dispositioned_comments() {
  local intent="$1"
  # $2 = "failed" when called from a failed/timed-out pass. On that path a
  # `fixed` disposition is never certified: the engine may have committed
  # locally without the commit ever reaching the PR (commit_and_push did not
  # run), so a local-HEAD check could clear the gate for an unpushed fix.
  local pass_outcome="${2:-ok}"
  # Set to 1 when a candidate's current state could not be confirmed at re-check.
  # The fix-bot-comment caller then withholds its terminal marker (#2017): that
  # marker reads as "this pass ended on the comment", so posting it over an
  # unconfirmed state would suppress the bot-comment retry.
  RDC_STATE_UNKNOWN=0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would resolve dispositioned PR issue comments on PR #${PR_NUMBER}"
    return 0
  fi
  if [ -z "${PR_NUMBER:-}" ]; then
    echo "::notice::resolve_dispositioned_comments: PR_NUMBER not set for intent=${intent} — skipping"
    return 0
  fi

  local bot_user="${BOT_USER:-donpetry-bot}"

  # Fetch ALL PR issue comments (author login + __typename, body, minimize state,
  # createdAt, lastEditedAt (#2008), and the node id used both to match a
  # disposition reply's `id=` and as minimizeComment's subjectId). The full set is needed twice: to find
  # candidates AND to locate their disposition replies (a flat comment list, not a
  # thread). Paginated 100/page.
  local pages_file cursor="" has_next_page="true" page_response page_nodes
  local cursor_args=()
  local comments_query='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        comments(first:100,after:$cursor){
          pageInfo{hasNextPage endCursor}
          nodes{ id author{login __typename} authorAssociation body isMinimized minimizedReason createdAt lastEditedAt }
        }
      }
    }
  }'
  pages_file=$(mktemp) || { echo "::error::failed to create temporary file" >&2; exit 1; }
  while [ "$has_next_page" = "true" ]; do
    page_response=$(gh api graphql -f query="$comments_query" \
      -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" \
      "${cursor_args[@]}" 2>/dev/null)
    page_nodes=$(printf '%s' "$page_response" | jq -c \
      '.data?.repository?.pullRequest?.comments?.nodes // []' 2>/dev/null || echo "[]")
    printf '%s\n' "$page_nodes" >> "$pages_file"
    has_next_page=$(printf '%s' "$page_response" | jq -r \
      '.data?.repository?.pullRequest?.comments?.pageInfo?.hasNextPage // false' \
      2>/dev/null || echo "false")
    cursor=$(printf '%s' "$page_response" | jq -r \
      '.data?.repository?.pullRequest?.comments?.pageInfo?.endCursor // ""' \
      2>/dev/null || echo "")
    [ -z "$cursor" ] && has_next_page="false"
    cursor_args=("-f" "cursor=${cursor}")
  done
  local all_comments
  all_comments=$(jq -s 'add // []' "$pages_file" 2>/dev/null || echo "[]")
  rm -f "$pages_file"

  # Candidate ids: comments in the gate's scope not already minimized RESOLVED.
  # The gate's own definition (#2209: our account, registered markers, review
  # requests and opt-outs are out of scope), so what the harness resolves is
  # exactly what the gate blocks on.
  local candidate_ids
  candidate_ids=$(maintainer_gate_open_comment_ids "$all_comments" "$bot_user" || true)

  # #2008: edits re-open a dispositioned comment. CodeRabbit edits ONE summary
  # comment in place. On PR #2000 a Security Architecture finding was appended
  # after the comment had been dispositioned `informational` and minimized, and
  # nothing ever addressed it. Two cases, both for RESOLVED bot comments:
  #   (a) RE-OPEN — the gate would re-block it (maintainer_gate_reopen_candidates):
  #       edited with no covering disposition, edited after its latest one, or
  #       covered only by `informational` while the body is finding-bearing.
  #       UNMINIMIZE it, so it is visibly open and the next pass dispositions the
  #       current body.
  #   (b) RE-VERIFY — a fresh disposition was posted after the edit, while an older
  #       one predates it. The gate already accepts the fresh one, so verify it here
  #       like any other: on success the stale reply goes OUTDATED, on failure the
  #       comment is unminimized (fail closed).
  local reopen_ids reverify_ids rid
  # #2037: set on any unminimize failure. Such a comment stays RESOLVED and the
  # gate clears it, so the pass must not end as a success. Every candidate is
  # still processed, then the function returns non-zero.
  local unminimize_failed=0
  reopen_ids=$(maintainer_gate_reopen_candidates "$all_comments" "$bot_user" 2>/dev/null \
    | jq -r '.[]?' 2>/dev/null || true)
  while IFS= read -r rid; do
    [ -z "$rid" ] && continue
    if gh api graphql -f query='mutation($id:ID!){unminimizeComment(input:{subjectId:$id}){unminimizedComment{isMinimized}}}' \
        -f id="$rid" >/dev/null 2>&1; then
      echo "::notice::unminimized comment ${rid} — edited after its latest disposition (or its disposition cannot cover a finding-bearing body); it needs a fresh disposition (#2008)"
    else
      echo "::warning::failed to unminimize comment ${rid} (edited after its latest disposition); it stays RESOLVED (#2008, #2037)"
      unminimize_failed=1
    fi
  done <<< "$reopen_ids"
  reverify_ids=$(printf '%s' "$all_comments" | jq -r --arg reopen "$reopen_ids" '
      ($reopen | split("\n")) as $skip
      | .[] | objects
      | select((.author?.__typename // "") == "Bot")
      | select(((.isMinimized // false) == true)
               and (((.minimizedReason // "") | ascii_downcase) == "resolved"))
      | select((.lastEditedAt // null) != null)
      | select(.id as $id | $skip | index($id) | not)
      | .id
    ' 2>/dev/null || true)
  if [ -n "$reverify_ids" ]; then
    candidate_ids=$(printf '%s\n%s' "$candidate_ids" "$reverify_ids")
  fi

  if [ -z "$(printf '%s' "$candidate_ids" | sed '/^[[:space:]]*$/d')" ]; then
    echo "::notice::no undispositioned PR issue comments on PR #${PR_NUMBER}"
    _rdc_unminimize_status "$unminimize_failed" || return 1
    return 0
  fi

  local resolved_count=0
  local cid is_human cur_minimized reply_body disp_json disposition sha ref verified
  local reverify edited_at chosen_created stale_rc
  # #2004: the `fixed` refs are read once per resolver run, on first use.
  local rdc_refs_ready="false" corrected_at
  while IFS= read -r cid || [ -n "$cid" ]; do
    [ -z "$cid" ] && continue
    corrected_at=""

    # (b) above: an already-RESOLVED, edited bot comment. It is re-verified only
    # when a fresh disposition straddles the edit (checked after selection below).
    reverify="false"
    if printf '%s\n' "$reverify_ids" | grep -qxF -- "$cid"; then
      reverify="true"
    fi

    # Re-read the ORIGINAL comment's CURRENT minimize state so a comment minimized
    # since enumeration is not double-processed; a fetch that can't confirm state
    # fails closed (skip). A re-verify candidate is RESOLVED by construction.
    if [ "$reverify" != "true" ]; then
      cur_minimized=$(gh api graphql -f query='query($id:ID!){node(id:$id){... on IssueComment{isMinimized minimizedReason}}}' \
        -f id="$cid" 2>/dev/null \
        | jq -r 'if .data.node.isMinimized == null then "unknown"
                 elif .data.node.isMinimized then "true" else "false" end' 2>/dev/null || echo "unknown")
      if [ "$cur_minimized" = "unknown" ]; then
        echo "::warning::skipping comment ${cid} — its current state could not be confirmed at re-check"
        RDC_STATE_UNKNOWN=1
        continue
      elif [ "$cur_minimized" != "false" ]; then
        echo "::notice::skipping comment ${cid} — already minimized at re-check"
        continue
      fi
    fi

    is_human=$(printf '%s' "$all_comments" | jq -r --arg id "$cid" \
      'first(.[] | select(.id == $id)) | if (.author?.__typename // "") == "User" then "true" else "false" end' 2>/dev/null || echo "false")

    # Locate OUR disposition reply(ies) for this comment id and collapse any
    # duplicates to ONE (#1992). cdv_select_disposition is the pure selector: it
    # keeps only replies authored by OUR BOT ACCOUNT (BOT_USER or its
    # GraphQL-stripped login) — the authorization gate (CWE-863): a disposition
    # from any other author never counts and can never win, so an external
    # commenter cannot smuggle a marker citing a candidate id past this gate. It
    # ignores already-minimized replies and anything cdv_parse_disposition rejects
    # (fail closed), then picks the LATEST by createdAt (deterministic tie-break on
    # node id). The pre-#1992 resolver required EXACTLY ONE and failed closed on
    # more, so a comment dispositioned-but-not-minimized in one pass accumulated a
    # second disposition on the next and then stuck forever (#1952/#1953). Now the
    # extra replies are reported as `superseded` and minimized OUTDATED below so the
    # authorized count converges to one — which also makes a second disposition the
    # engine posts harmless (AC1: idempotency enforced by rejecting the duplicate
    # after the engine returns, since the model posts replies via its own shell).
    reply_body=""
    disp_json="{}"
    local selection chosen_reply_id auth_count=0
    local superseded_ids=()
    if selection=$(cdv_select_disposition "$cid" "$bot_user" "$all_comments" 2>/dev/null); then
      auth_count=$(printf '%s' "$selection" | jq -r '.auth_count // 0' 2>/dev/null || echo "0")
      disp_json=$(printf '%s' "$selection" | jq -c '.chosen.disposition // {}' 2>/dev/null || echo "{}")
      chosen_reply_id=$(printf '%s' "$selection" | jq -r '.chosen.id // ""' 2>/dev/null || echo "")
      # The invalid/answered/informational evidence check below reads the chosen
      # reply's FULL body (non-empty beyond the marker), so recover it by node id.
      reply_body=$(printf '%s' "$all_comments" | jq -r --arg id "$chosen_reply_id" \
        'first(.[] | select(.id == $id)) | .body // ""' 2>/dev/null || echo "")
      while IFS= read -r sid || [ -n "$sid" ]; do
        [ -z "$sid" ] && continue
        superseded_ids+=("$sid")
      done < <(printf '%s' "$selection" | jq -r '.superseded[]? // empty' 2>/dev/null || true)
    fi

    if [ "$reverify" = "true" ]; then
      # Re-verify only when the chosen (latest) disposition was posted at/after the
      # edit while a superseded one predates it — a fresh disposition answering an
      # edited body. Anything else is a settled RESOLVED comment: leave it.
      edited_at=$(printf '%s' "$all_comments" | jq -r --arg id "$cid" \
        'first(.[] | select(.id == $id)) | .lastEditedAt // ""' 2>/dev/null || echo "")
      local chosen_created straddles="false" sid sid_created
      chosen_created=$(printf '%s' "${selection:-}" | jq -r '.chosen.createdAt // ""' 2>/dev/null || echo "")
      stale_rc=0
      cdv_disposition_is_stale "$edited_at" "$chosen_created" || stale_rc=$?
      if [ "$stale_rc" -eq 2 ]; then
        # Unreadable edit/disposition timestamp: fail closed — re-open the comment.
        if gh api graphql -f query='mutation($id:ID!){unminimizeComment(input:{subjectId:$id}){unminimizedComment{isMinimized}}}' \
            -f id="$cid" >/dev/null 2>&1; then
          echo "::notice::unminimized comment ${cid} — unreadable edit/disposition timestamp (#2008)"
        else
          echo "::warning::failed to unminimize comment ${cid} with an unreadable edit/disposition timestamp (#2008)"
          unminimize_failed=1
        fi
        continue
      fi
      if [ "${auth_count:-0}" -gt 1 ] && [ -n "$chosen_created" ] \
         && [ "$stale_rc" -ne 0 ]; then
        for sid in "${superseded_ids[@]:-}"; do
          [ -z "$sid" ] && continue
          sid_created=$(printf '%s' "$all_comments" | jq -r --arg id "$sid" \
            'first(.[] | select(.id == $id)) | .createdAt // ""' 2>/dev/null || echo "")
          if cdv_disposition_is_stale "$edited_at" "$sid_created"; then
            straddles="true"
          fi
        done
      fi
      if [ "$straddles" != "true" ]; then
        continue
      fi
      echo "::notice::re-verifying comment ${cid} — edited at ${edited_at} after an earlier disposition; a fresh disposition ${chosen_reply_id} covers the current body (#2008)"
    fi

    if [ "${auth_count:-0}" -lt 1 ] || [ -z "$chosen_reply_id" ]; then
      echo "::notice::skipping comment ${cid} — no authorized dev-lead disposition reply from ${bot_user} found; leaving open (#1813)"
      continue
    fi
    if [ "$auth_count" -gt 1 ]; then
      echo "::notice::comment ${cid} has ${auth_count} authorized disposition replies from ${bot_user}; selecting latest ${chosen_reply_id} and marking ${#superseded_ids[@]} superseded reply(ies) OUTDATED (#1992)"
    fi

    disposition=$(printf '%s' "$disp_json" | jq -r '.disposition // ""' 2>/dev/null || echo "")
    sha=$(printf '%s' "$disp_json" | jq -r '.sha // ""' 2>/dev/null || echo "")
    ref=$(printf '%s' "$disp_json" | jq -r '.ref // ""' 2>/dev/null || echo "")

    # Verify the disposition against ground truth. Fail closed: unknown → false.
    verified="false"
    case "$disposition" in
      fixed)
        if [ "$pass_outcome" = "failed" ]; then
          echo "::notice::skipping comment ${cid} — a \`fixed\` disposition is not certified on a failed pass (its commit may not have been pushed); leaving open (#1992)"
          if [ "$reverify" = "true" ]; then
            # Already RESOLVED with a stale body: fail closed by re-opening it.
            if ! gh api graphql -f query='mutation($id:ID!){unminimizeComment(input:{subjectId:$id}){unminimizedComment{isMinimized}}}' \
                -f id="$cid" >/dev/null 2>&1; then
              echo "::error::failed to unminimize comment ${cid} after a failed post-edit re-verification (#2008)" >&2
              unminimize_failed=1
            fi
          fi
          continue
        fi
        # Verify the cited commit's DIFF CONTENT (#2004), not which pass produced
        # it: on the PR's pushed head, not on the base branch, a non-empty diff that
        # REMOVES a token the finding names and does not ADD it, dated after the
        # finding. A finding with no token fails closed unless the cited sha was produced by this pass (tokenless-not-this-pass).
        # The old "produced by THIS pass" rule could never accept a fix that landed
        # in an earlier pass. Accepting any later commit would let an unrelated
        # commit resolve the comment.
        if [ "${rdc_refs_ready:-false}" != "true" ]; then
          rdc_fixed_refs
          rdc_refs_ready="true"
        fi
        local orig_body orig_created fixed_reason corrected removed_tok fix_body
        orig_body=$(printf '%s' "$all_comments" | jq -r --arg id "$cid" \
          'first(.[] | select(.id == $id)) | .body // ""' 2>/dev/null || echo "")
        orig_created=$(printf '%s' "$all_comments" | jq -r --arg id "$cid" \
          'first(.[] | select(.id == $id)) | .createdAt // ""' 2>/dev/null || echo "")
        if fixed_reason=$(rdc_fixed_verdict "$sha" "$orig_body" "$orig_created"); then
          verified="true"
          echo "::notice::comment ${cid}: \`fixed\` disposition verified against ${sha} (${fixed_reason}) (#2004)"
        else
          # AC2: loud and distinguishable from "dev-lead has not run yet".
          echo "::warning::comment ${cid}: \`fixed\` disposition citing ${sha} did not verify (fixed-unverified:${fixed_reason}); the cited commit's diff must remove what the finding names (#2004)"
          # AC3: an unverified disposition is not settled. Re-answer it with the
          # PR-branch commit whose diff removes the finding's token, when one exists.
          local corrected_rc=0 live_body
          corrected=$(rdc_find_fixing_commit "$orig_body" "$orig_created") || corrected_rc=$?
          # The body can be edited after enumeration. The correction judges only the
          # captured body, so re-read the live one first; a changed or unreadable
          # body leaves the comment open for a disposition of the current body.
          if [ "$corrected_rc" -eq 0 ] \
             && { ! live_body=$(rdc_live_comment_body "$cid") || [ "$live_body" != "$orig_body" ]; }; then
            echo "::warning::comment ${cid}: its body changed or could not be re-read since it was captured; no correction posted, it stays open for a disposition of the current body (#2004)"
            if [ "$reverify" = "true" ]; then
              # Already RESOLVED: a changed body must not stay minimized (#2008).
              if ! gh api graphql -f query='mutation($id:ID!){unminimizeComment(input:{subjectId:$id}){unminimizedComment{isMinimized}}}' \
                  -f id="$cid" >/dev/null 2>&1; then
                echo "::error::failed to unminimize comment ${cid} after its body changed (#2008)" >&2
                unminimize_failed=1
              fi
            fi
            continue
          fi
          if [ "$corrected_rc" -eq 0 ]; then
            removed_tok=$(cdv_removed_token "$(rdc_commit_diff "$corrected")" "$(cdv_finding_tokens "$orig_body")" || true)
            # Quote the token only when it is plain, so it can never form a marker.
            [[ "$removed_tok" =~ ^[A-Za-z0-9_./:=-]+$ ]] || removed_tok=""
            fix_body="Correcting my earlier \`fixed\` disposition for this comment: it cited \`${sha}\`, which does not address the finding (\`${fixed_reason}\`). The fix is in \`${corrected}\`${removed_tok:+, whose diff removes \`${removed_tok}\`}.

<!-- dev-lead:comment-disposition id=${cid} disposition=fixed sha=${corrected} -->"
            if gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$fix_body" >/dev/null 2>&1; then
              echo "::notice::re-answered comment ${cid}: the corrected \`fixed\` disposition cites ${corrected} in place of ${sha} (#2004)"
              # Re-read after posting: an edit that raced the post was never checked.
              if ! live_body=$(rdc_live_comment_body "$cid") || [ "$live_body" != "$orig_body" ]; then
                echo "::warning::comment ${cid}: its body changed while the correction was posted; leaving it open for a disposition of the current body (#2004)"
                if [ "$reverify" = "true" ]; then
                  # Already RESOLVED: a changed body must not stay minimized (#2008).
                  if ! gh api graphql -f query='mutation($id:ID!){unminimizeComment(input:{subjectId:$id}){unminimizedComment{isMinimized}}}' \
                      -f id="$cid" >/dev/null 2>&1; then
                    echo "::error::failed to unminimize comment ${cid} after its body changed (#2008)" >&2
                    unminimize_failed=1
                  fi
                fi
                continue
              fi
              # The corrected reply is now the latest. The wrong one is superseded.
              superseded_ids+=("$chosen_reply_id")
              sha="$corrected"
              corrected_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
              verified="true"
            else
              echo "::warning::comment ${cid}: could not post the corrected \`fixed\` disposition citing ${corrected}; it stays open (fixed-unverified:${fixed_reason}) (#2004)"
            fi
          else
            echo "::warning::comment ${cid}: no commit on this branch removes what the finding names. The next pass must re-answer it with a fresh disposition (fixed-unverified:${fixed_reason}) (#2004)"
          fi
        fi
        ;;
      out-of-scope)
        # The referenced tracking issue must exist.
        local ref_num="${ref#\#}"
        if [ -n "$ref_num" ] && gh issue view "$ref_num" --repo "$REPO" --json number >/dev/null 2>&1; then
          verified="true"
        fi
        ;;
      invalid|answered|informational)
        # The disposition reply must carry non-empty evidence beyond the marker itself.
        local evidence
        evidence=$(printf '%s' "$reply_body" | jq -Rsr 'gsub("<!--.*?-->";"";"s") | gsub("\\s";"";"g")' 2>/dev/null || echo "")
        [ -n "$evidence" ] && verified="true"
        # #2008: `informational` claims "no finding". It never verifies against a
        # body carrying a finding-bearing section (e.g. CodeRabbit's Security
        # Architecture Review beside a rate-limit block). A notice covers only its
        # own section; each finding needs fixed/answered/invalid/out-of-scope.
        if [ "$disposition" = "informational" ] && [ "$verified" = "true" ]; then
          local orig_body
          orig_body=$(printf '%s' "$all_comments" | jq -r --arg id "$cid" \
            'first(.[] | select(.id == $id)) | .body // ""' 2>/dev/null || echo "")
          if cdv_body_has_findings "$orig_body"; then
            verified="false"
            echo "::notice::comment ${cid} carries a finding-bearing section — an \`informational\` disposition cannot cover it; each finding needs a real disposition (#2008)"
          fi
        fi
        ;;
      *)
        verified="false"
        ;;
    esac

    if ! cdv_authorize "$disposition" "$is_human" "$verified"; then
      echo "::notice::skipping comment ${cid} — disposition '${disposition}' not authorized to resolve (is_human=${is_human} verified=${verified}); leaving open (#1813)"
      if [ "$disposition" = "fixed" ] && [ "$reverify" != "true" ]; then
        # #2004: an unverified `fixed` is re-answered on later passes. Converge the
        # older replies to OUTDATED now, so the replies never stack (#1992).
        local usid
        for usid in "${superseded_ids[@]}"; do
          if gh api graphql -f query='mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:OUTDATED}){minimizedComment{isMinimized}}}' \
              -f id="$usid" >/dev/null 2>&1; then
            echo "::notice::minimized superseded disposition reply ${usid} OUTDATED (#1992, #2004)"
          else
            echo "::warning::failed to minimize superseded disposition reply ${usid} OUTDATED"
          fi
        done
      fi
      if [ "$reverify" = "true" ]; then
        # Fail closed: the fresh disposition answering the edit did not verify,
        # and the older one predates the edit, so nothing covers the current body.
        if gh api graphql -f query='mutation($id:ID!){unminimizeComment(input:{subjectId:$id}){unminimizedComment{isMinimized}}}' \
            -f id="$cid" >/dev/null 2>&1; then
          echo "::notice::unminimized comment ${cid} — its post-edit disposition did not verify (#2008)"
        else
          echo "::warning::failed to unminimize comment ${cid} after a failed post-edit re-verification (#2008)"
          unminimize_failed=1
        fi
      fi
      continue
    fi

    if [ "$reverify" = "true" ]; then
      # Already RESOLVED. Only converge the superseded replies to OUTDATED, so the
      # next pass sees exactly one disposition and does not re-verify again.
      local rsid
      for rsid in "${superseded_ids[@]:-}"; do
        [ -z "$rsid" ] && continue
        if gh api graphql -f query='mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:OUTDATED}){minimizedComment{isMinimized}}}' \
            -f id="$rsid" >/dev/null 2>&1; then
          echo "::notice::minimized superseded disposition reply ${rsid} OUTDATED (#1992, #2008)"
        else
          echo "::warning::failed to minimize superseded disposition reply ${rsid} OUTDATED"
        fi
      done
      continue
    fi

    # An un-minimized candidate must not be hidden from a disposition that predates
    # its last edit (#2008 AC1): that judged an older body. Stale → leave visible
    # for a fresh disposition; unreadable timestamp → fail closed, also visible.
    edited_at=$(printf '%s' "$all_comments" | jq -r --arg id "$cid" \
      'first(.[] | select(.id == $id)) | .lastEditedAt // ""' 2>/dev/null || echo "")
    chosen_created=$(printf '%s' "${selection:-}" | jq -r '.chosen.createdAt // ""' 2>/dev/null || echo "")
    # A corrected `fixed` reply posted above judged the current body (#2004).
    [ -n "$corrected_at" ] && chosen_created="$corrected_at"
    stale_rc=0
    cdv_disposition_is_stale "$edited_at" "$chosen_created" || stale_rc=$?
    if [ "$stale_rc" -ne 1 ]; then
      echo "::notice::not minimizing comment ${cid} — its disposition predates the last edit (${edited_at}) or a timestamp is unreadable; needs a fresh disposition (#2008)"
      # Converge duplicates to one (#1992): minimize every superseded disposition
      # reply OUTDATED before skipping, so a later pass sees exactly one authorized
      # disposition even when the candidate is not yet minimized.
      local sid
      for sid in "${superseded_ids[@]:-}"; do
        [ -z "$sid" ] && continue
        if gh api graphql -f query='mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:OUTDATED}){minimizedComment{isMinimized}}}' \
            -f id="$sid" >/dev/null 2>&1; then
          echo "::notice::minimized superseded disposition reply ${sid} OUTDATED (#1992)"
        else
          echo "::warning::failed to minimize superseded disposition reply ${sid} OUTDATED"
        fi
      done
      continue
    fi

    if gh api graphql -f query='mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:RESOLVED}){minimizedComment{isMinimized}}}' \
        -f id="$cid" >/dev/null 2>&1; then
      resolved_count=$((resolved_count + 1))
      echo "::notice::minimized comment ${cid} RESOLVED (disposition=${disposition} is_human=${is_human})"
      # Converge duplicates to one (#1992): minimize every superseded disposition
      # reply OUTDATED so a later pass sees exactly one authorized disposition.
      # Done only after the original is RESOLVED, so a reply is never hidden unless
      # its comment is genuinely addressed.
      local sid
      for sid in "${superseded_ids[@]:-}"; do
        [ -z "$sid" ] && continue
        if gh api graphql -f query='mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:OUTDATED}){minimizedComment{isMinimized}}}' \
            -f id="$sid" >/dev/null 2>&1; then
          echo "::notice::minimized superseded disposition reply ${sid} OUTDATED (#1992)"
        else
          echo "::warning::failed to minimize superseded disposition reply ${sid} OUTDATED"
        fi
      done
    else
      echo "::warning::failed to minimize comment ${cid} RESOLVED"
    fi
  done <<< "$candidate_ids"
  echo "::notice::resolve_dispositioned_comments: minimized ${resolved_count} dispositioned comment(s) on PR #${PR_NUMBER}"
  _rdc_unminimize_status "$unminimize_failed" || return 1
}

# _rdc_unminimize_status <unminimize_failed> — resolve_dispositioned_comments'
# return status (#2037): non-zero when any comment that needed re-opening could
# not be unminimized, so the caller ends the pass partial instead of applied.
_rdc_unminimize_status() {
  if [ "${1:-0}" -ne 0 ]; then
    echo "::error::resolve_dispositioned_comments: failed to unminimize at least one comment on PR #${PR_NUMBER} — it stays RESOLVED without a verified disposition, so this pass must not end as a success (#2037)" >&2
    return 1
  fi
  return 0
}

# ── CI blocking gate (#1859, completes #1795) ─────────────────────────────────
# has_hard_blockers / has_tier1_blockers determine whether CI is blocking via
# lib/ci-status.sh (compute_ci_status), NOT their own all-or-nothing logic. A
# failing NON-required check (e.g. `template-drift`, or a superseded/cancelled
# `dev-lead / *` orchestration job — all non-required) no longer blocks; a failing
# REQUIRED check and a genuine CHANGES_REQUESTED review still do. Fails closed: if
# the branch ruleset is unreadable, compute_ci_status gates on every failing check.

# _ci_required_checks: the branch ruleset's required status-check contexts, read
# once per run via ruleset_required_checks (lib/ci-status.sh) and cached. Names are
# NEVER hardcoded here — they are the authoritative required set for this branch.
# Empty when the ruleset API is unreadable → compute_ci_status fails closed.
_ci_required_checks() {
  if [ -z "${_CI_REQUIRED_CHECKS_CACHE+x}" ]; then
    _CI_REQUIRED_CHECKS_CACHE="$(ruleset_required_checks "${REPO:-}" "${BASE_REF:-main}" 2>/dev/null || true)"
  fi
  printf '%s' "$_CI_REQUIRED_CHECKS_CACHE"
}

# _ci_rollup_from_status_json: reshape CI_STATUS_JSON (built by fetch_pr_context
# from the check-runs + legacy-statuses APIs, lowercase conclusions) into the
# statusCheckRollup shape compute_ci_status consumes — uppercase status/conclusion,
# with the synthetic "pending" conclusion (fetch_pr_context maps a pending legacy
# status to it) normalised back to a null (non-terminal) conclusion so it
# classifies as pending, not failing.
_ci_rollup_from_status_json() {
  printf '%s' "${CI_STATUS_JSON:-[]}" | jq -c '
    (if type == "array" then . else [] end)
    | map({
        name: (.name // ""),
        status: ((.status // "") | ascii_upcase),
        conclusion: (if (.conclusion == null or .conclusion == "" or .conclusion == "pending")
                     then null else (.conclusion | ascii_upcase) end)
      })' 2>/dev/null || echo '[]'
}

# ci_blocking_status: the compute_ci_status verdict ("passing"/"pending"/"failing")
# for this PR, gated on required checks only.
ci_blocking_status() {
  compute_ci_status "$(_ci_rollup_from_status_json)" "$(_ci_required_checks)"
}

# ci_is_blocking: returns 0 (true) when CI is a hard blocker — a REQUIRED check is
# failing or still pending. A red NON-required check yields "passing" and is not a
# blocker (the #1795/#1859 deadlock).
ci_is_blocking() {
  local st
  st="$(ci_blocking_status)"
  [ "$st" = "failing" ] || [ "$st" = "pending" ]
}

# ci_blocking_reason: a human phrase naming the specific check(s) that make CI a
# blocker and whether they are required — AC #5. Mirrors compute_ci_status's gate
# so the two never drift: it reports the checks in the SAME gate set (the required
# subset when the ruleset named any, otherwise every external check — fail closed)
# that are pending or failing. Empty when CI is not blocking. Examples:
#   "required check `Lint` is failing"
#   "required checks `Lint`, `Build` are still pending"
#   "check `template-drift` is failing (required set unreadable — failing closed)"
ci_blocking_reason() {
  local agent_roles required_names is_unreadable="false"
  agent_roles="$(_ci_status_agent_roles_json)"
  # Normalise the required set to a JSON array. An empty/unreadable ruleset must
  # become [] (not the empty string), or --argjson would reject it and the whole
  # filter would silently fail — dropping us onto the generic fallback (#1859 AC5).
  # Distinguish an UNREADABLE ruleset (empty string from _ci_required_checks →
  # fail closed) from a readable-but-EMPTY one ("[]" → no required checks
  # configured): only the former warrants the "failing closed" note, or it
  # misleadingly claims the ruleset was unreadable when it was merely empty.
  required_names="$(_ci_required_checks)"
  if [ -z "$required_names" ]; then
    is_unreadable="true"
    required_names="[]"
  elif [ "$required_names" = "[]" ]; then
    required_names="[]"
  else
    required_names="$(jq -c 'if type == "array" then . else [] end' <<< "$required_names" 2>/dev/null || echo '[]')"
  fi
  _ci_rollup_from_status_json | jq -r \
    --argjson agent_roles "$agent_roles" \
    --argjson required_names "$required_names" \
    --arg unreadable "$is_unreadable" "
    def is_terminal: (.conclusion != null and .conclusion != \"\");
    def is_pending:
      (is_terminal | not) and (
        .status == \"IN_PROGRESS\" or .status == \"QUEUED\" or .status == \"WAITING\" or
        .status == \"COMPLETED\"  or .state == \"PENDING\" or .state == \"EXPECTED\"
      );
    def is_success:
      .conclusion == \"SUCCESS\" or .conclusion == \"SKIPPED\" or .conclusion == \"NEUTRAL\" or
      .state == \"SUCCESS\";
    def is_cancelled: .conclusion == \"CANCELLED\";
    def is_required:
      (.isRequired == true) or
      (((.name // .context // \"\") as \$n | (\$required_names | index(\$n)) != null));
    def chk_word(\$n): if \$n == 1 then \"check\" else \"checks\" end;
    def names(\$a): (\$a | map(\"\`\" + . + \"\`\") | join(\", \"));
    $_CI_STATUS_JQ_IS_OWN_CHECK
    $_CI_STATUS_JQ_IS_AGENT_CHECK
    if (. == null or (type != \"array\")) then \"\"
    else
      (map(select((is_own_check or is_agent_check) | not))) as \$ext |
      (\$ext | map(select(is_required))) as \$req |
      (\$req | length > 0) as \$gate_required |
      (if \$gate_required then \$req else \$ext end) as \$gate |
      (if \$gate_required then \"required \" else \"\" end) as \$qual |
      (if \$gate_required then \"\" elif \$unreadable == \"true\" then \" (required set unreadable — failing closed)\" else \"\" end) as \$closed |
      (\$gate | map(select((is_success or is_cancelled) | not))) as \$bad |
      (\$bad | map(select(is_pending))  | map(.name // .context // \"\") | map(select(length > 0))) as \$pending |
      (\$bad | map(select(is_pending | not)) | map(.name // .context // \"\") | map(select(length > 0))) as \$failing |
      ([ (if (\$failing | length) > 0
            then \$qual + chk_word(\$failing|length) + \" \" + names(\$failing) + \" \" + (if (\$failing|length)==1 then \"is\" else \"are\" end) + \" failing\" + \$closed
            else empty end),
         (if (\$pending | length) > 0
            then \$qual + chk_word(\$pending|length) + \" \" + names(\$pending) + \" \" + (if (\$pending|length)==1 then \"is\" else \"are\" end) + \" still pending\" + \$closed
            else empty end)
       ] | join(\"; \"))
    end
  " 2>/dev/null || true
}

# blocking_reason_phrase: the full "why this PR still can't be marked done" phrase
# for retry/hold messages — the named CI blocker(s) from ci_blocking_reason plus a
# changes-requested-review clause when applicable (AC #5). Falls back to a generic
# phrase only if nothing specific could be derived.
blocking_reason_phrase() {
  local reasons=() ci_reason changes_requested
  ci_reason="$(ci_blocking_reason)"
  [ -n "$ci_reason" ] && reasons+=("$ci_reason")
  changes_requested=$(printf '%s' "${ALL_REVIEWS_JSON:-[]}" | \
    jq '[.[] | select(.state == "CHANGES_REQUESTED")] | length' 2>/dev/null || echo "0")
  [ "${changes_requested:-0}" -gt 0 ] && reasons+=("a reviewer requested changes")
  if [ "${#reasons[@]}" -eq 0 ]; then
    printf 'a required check is failing or pending, or a reviewer requested changes'
  else
    local out="" r
    for r in "${reasons[@]}"; do
      if [ -z "$out" ]; then out="$r"; else out="${out}; ${r}"; fi
    done
    printf '%s' "$out"
  fi
}

# has_hard_blockers: returns 0 (true) if CI is blocking (per ci-status.sh) or
# ALL_REVIEWS_JSON contains a CHANGES_REQUESTED review.
# Unlike has_tier1_blockers, does NOT check for unresolved bot threads — used to
# distinguish "bot threads are the sole blocker" from "hard blockers present", so
# callers can post a retry marker instead of silently stalling on bot feedback.
has_hard_blockers() {
  local changes_requested

  changes_requested=$(printf '%s' "${ALL_REVIEWS_JSON:-[]}" | \
    jq '[.[] | select(.state == "CHANGES_REQUESTED")] | length' \
    2>/dev/null || echo "0")

  ci_is_blocking || [ "${changes_requested:-0}" -gt 0 ]
}

# has_tier1_blockers: returns 0 (true) if CI is blocking (per ci-status.sh),
# ALL_REVIEWS_JSON, or unresolved bot reviewer threads contain Tier-1 blockers:
# - A REQUIRED CI check failing or pending (via compute_ci_status; a red
#   NON-required check does not block — #1859)
# - Any reviewer with state = CHANGES_REQUESTED
# - Unresolved review threads from bot reviewers (prevents review-changes from ignoring bot feedback)
# Used to gate post_no_changes — never post a terminal no-changes marker while blockers
# exist, so the retry cron can re-attempt on the same SHA.
has_tier1_blockers() {
  local changes_requested unresolved_bot_threads

  changes_requested=$(printf '%s' "${ALL_REVIEWS_JSON:-[]}" | \
    jq '[.[] | select(.state == "CHANGES_REQUESTED")] | length' \
    2>/dev/null || echo "0")

  # Count unresolved bot reviewer threads with cursor pagination to cover PRs with >100 threads.
  # Detects bots via __typename == "Bot" (covers bots whose GraphQL login omits [bot] suffix)
  # or login ending with [bot] (belt-and-suspenders for bots that include the suffix).
  unresolved_bot_threads=0
  if [ -n "${PR_NUMBER:-}" ]; then
    local cursor="" has_next_page="true" page_response page_count
    local cursor_args=()
    local bot_thread_query='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$pr){
          reviewThreads(first:100,after:$cursor){
            pageInfo{hasNextPage endCursor}
            nodes{isResolved comments(first:1){nodes{author{login __typename}}}}
          }
        }
      }
    }'
    while [ "$has_next_page" = "true" ]; do
      page_response=$(gh api graphql -f query="$bot_thread_query" \
        -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" \
        "${cursor_args[@]}" 2>/dev/null) || {
        echo "::warning::has_tier1_blockers: bot-thread query failed — treating as blocked"
        return 0
      }
      page_count=$(printf '%s' "$page_response" | jq \
        '[.data?.repository?.pullRequest?.reviewThreads?.nodes // []
        | map(select(.isResolved == false
                     and (((.comments.nodes?[0]?.author?.login // "") | endswith("[bot]"))
                          or ((.comments.nodes?[0]?.author?.__typename // "") == "Bot"))))
        | length] | .[0]' 2>/dev/null || echo "0")
      unresolved_bot_threads=$(( ${unresolved_bot_threads:-0} + ${page_count:-0} ))
      has_next_page=$(printf '%s' "$page_response" | jq -r \
        '.data?.repository?.pullRequest?.reviewThreads?.pageInfo?.hasNextPage // false' \
        2>/dev/null || echo "false")
      cursor=$(printf '%s' "$page_response" | jq -r \
        '.data?.repository?.pullRequest?.reviewThreads?.pageInfo?.endCursor // ""' \
        2>/dev/null || echo "")
      [ -z "$cursor" ] && has_next_page="false"
      cursor_args=("-f" "cursor=${cursor}")
    done
  fi

  ci_is_blocking || [ "${changes_requested:-0}" -gt 0 ] || [ "${unresolved_bot_threads:-0}" -gt 0 ]
}

# try_enable_auto_merge: enables auto-merge (squash) on the PR when the engine run
# succeeds (rc==0). We do NOT gate on reviewDecision here: GitHub holds the merge
# until branch protection is satisfied (required reviews approved, review threads
# resolved, required checks green), so enabling early is safe and means a PR merges
# the moment it becomes mergeable. If the engine run fails the call is skipped, so a
# new dev-lead event is required in that case.
# Safe to call speculatively: it is idempotent when auto-merge is already on.
# Pass "true" as first arg for strict mode: API errors propagate and a merge failure
# exits non-zero rather than emitting a warning (use for the enable-auto-merge intent).
try_enable_auto_merge() {
  local strict="${1:-false}"
  if [[ "${DEV_LEAD_DRY_RUN:-false}" == "true" ]]; then
    echo "[dry-run] would enable auto-merge (${_AM_MERGE_METHOD:-squash}) on PR #${PR_NUMBER}"
    return 0
  fi
  # Refresh HEAD_SHA to the commit that is now the PR head. commit_and_push may
  # have created a new commit after HEAD_SHA was resolved at script startup, so
  # --match-head-commit would fail with the stale value.
  local current_head
  current_head=$(git rev-parse HEAD 2>/dev/null || true)
  [[ -n "$current_head" ]] && HEAD_SHA="$current_head"

  local auto_merge_state
  if [[ "$strict" == "true" ]]; then
    auto_merge_state=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.auto_merge // empty')
  else
    auto_merge_state=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" \
      --jq '.auto_merge // empty' 2>/dev/null || true)
  fi
  if [[ -n "$auto_merge_state" ]]; then
    echo "::notice::PR #${PR_NUMBER} auto-merge already enabled"
    return 0
  fi

  local method="${_AM_MERGE_METHOD:-squash}"
  local merge_flag
  case "$method" in
    merge)  merge_flag="--merge" ;;
    rebase) merge_flag="--rebase" ;;
    *)      merge_flag="--squash" ;;
  esac
  echo "::notice::PR #${PR_NUMBER} — enabling auto-merge (${method}); GitHub will merge once branch protection is satisfied"
  local merge_args=("--auto" "$merge_flag")
  [[ -n "${_AM_COMMIT_TITLE:-}" ]] && merge_args+=("--subject" "${_AM_COMMIT_TITLE}")
  [[ -n "${_AM_COMMIT_MESSAGE:-}" ]] && merge_args+=("--body" "${_AM_COMMIT_MESSAGE}")
  [[ -n "${HEAD_SHA:-}" ]] && merge_args+=("--match-head-commit" "$HEAD_SHA")
  if [[ "$strict" == "true" ]]; then
    gh pr merge "$PR_NUMBER" --repo "$REPO" "${merge_args[@]}"
  else
    gh pr merge "$PR_NUMBER" --repo "$REPO" "${merge_args[@]}" 2>/dev/null || \
      echo "::warning::auto-merge could not be enabled on PR #${PR_NUMBER} — check repository settings and token permissions"
  fi
}

# detect_conflicting_paths <base_ref> — list paths that conflict when merging
# origin/<base_ref> into the current HEAD, one per line. Uses a trial merge
# (immediately aborted) because it is robust across git versions: the former
# `git merge-tree <base> HEAD <base>` 3-arg form prints a "changed in both"
# section header whose last field is the literal word "both" (the filename is on
# the indented our/their lines), so `awk '{print $NF}'` produced a bogus "both"
# path that was fed to the rebase prompt. Leaves the worktree clean.
detect_conflicting_paths() {
  local base="$1"
  [[ -z "$base" ]] && return 0
  git merge --no-commit --no-ff "origin/${base}" >/dev/null 2>&1 || true
  git diff --name-only --diff-filter=U || true
  git merge --abort >/dev/null 2>&1 || true
}

# ── rebase exhaustion / large-conflict guard (#865) ───────────────────────────
# A hard/unresolvable rebase conflict used to run the engine to the per-tier
# timeout (exit 124) instead of aborting, and the auto-rebase-conflict sentinel
# could re-fire repeatedly — a burst of full-timeout runs. These wrappers pair
# the gh-api reads/writes with the pure decision helpers in
# lib/rebase-exhaustion.sh to abort cleanly and cap repeated attempts, mirroring
# the fix-ci per-PR exhaustion marker.
REBASE_MAX_FAIL_ATTEMPTS="${REBASE_MAX_FAIL_ATTEMPTS:-2}"
REBASE_MAX_CONFLICT_FILES="${REBASE_MAX_CONFLICT_FILES:-40}"

# _rebase_comment_bodies: newline-delimited bodies of all PR comments (paginated
# so markers on busy PRs are not missed).
_rebase_comment_bodies() {
  local output
  output=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null) || return 1
  printf '%s\n' "$output" | jq -r '.[].body' 2>/dev/null || return 1
}

# rebase_pr_is_exhausted: exit status distinguishes three states so the caller
# can fail closed on a retrieval fault instead of treating it as "not exhausted":
#   0 → exhaustion marker present (skip the engine)
#   1 → comments retrieved, no marker (safe to proceed)
#   2 → comment retrieval failed (unknown — caller must not invoke the engine)
rebase_pr_is_exhausted() {
  local marker bodies
  marker="$(rebase_exhaustion_marker "$REVIEWS_MARKER_PREFIX" "$PR_NUMBER")"
  if ! bodies="$(_rebase_comment_bodies)"; then
    return 2
  fi
  rebase_is_exhausted "$marker" "$bodies"
}

# post_rebase_exhaustion <reason>: posts the PR-level block so a stuck conflict
# cannot generate repeated timing-out runs from sentinel re-fires.
post_rebase_exhaustion() {
  local reason="$1" marker body
  marker="$(rebase_exhaustion_marker "$REVIEWS_MARKER_PREFIX" "$PR_NUMBER")"
  body="${marker}
## Dev-Lead — rebase (exhausted)

This PR's rebase conflict failed automated resolution **${REBASE_MAX_FAIL_ATTEMPTS}** time(s) (timeouts or unresolvable conflicts). Automated rebasing is paused to stop repeated full-timeout runs from the auto-rebase-conflict sentinel.

**Reason for last failure:** ${reason}

Resolve the conflict manually, then remove the \`${NEEDS_HUMAN_REVIEW_LABEL:-needs-human-review}\` label **and** delete this comment to re-enable automated rebasing."
  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] would post rebase exhaustion marker, add ${NEEDS_HUMAN_REVIEW_LABEL:-needs-human-review} and disable auto-merge on PR #${PR_NUMBER}"
    return 0
  fi
  # A PR held for human review must not auto-merge once the conflict is resolved
  # by hand: suppress the EXIT-trap auto-merge restore and disable any armed one.
  _AM_NEEDS_RESTORE=0
  # Escalate loudly (#1890 AC #3): applying needs-human-review makes the hold gate
  # (dev-lead-intent.sh) skip every subsequent rebase sentinel for this PR, so the
  # loop converges to a single escalation instead of re-firing indefinitely. The
  # label goes first so the comment can say when the PR could not be held (#2142).
  apply_hold_label "$REPO" "$PR_NUMBER" || true
  gh pr comment "$PR_NUMBER" --repo "$REPO" --body "${body}${HOLD_LABEL_NOTE}" 2>/dev/null || true
  disable_auto_merge_for_hold "$REPO" "$PR_NUMBER" || true
}

# escalate_rebase_needs_human <reason>: hand a rebase off to a human immediately
# (not retryable) — used by the post-resolution integrity gate (#1890 AC #7).
# Records a terminal failed marker, adds needs-human-review so the hold gate stops
# future sentinels, and disables auto-merge so a corrupted resolution cannot merge.
escalate_rebase_needs_human() {
  local reason="$1"
  # Prevent the EXIT-trap auto-merge restore from re-enabling what we disable.
  _AM_NEEDS_RESTORE=0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    post_reviews_terminal "rebase" "failed" "$reason"
    echo "[dry-run] would add ${NEEDS_HUMAN_REVIEW_LABEL:-needs-human-review} and disable auto-merge on PR #${PR_NUMBER}"
    return 0
  fi
  # Label first so the terminal marker can say when the PR could not be held (#2142).
  apply_hold_label "$REPO" "$PR_NUMBER" || true
  post_reviews_terminal "rebase" "failed" "${reason}${HOLD_LABEL_NOTE}"
  disable_auto_merge_for_hold "$REPO" "$PR_NUMBER" || true
}

# handle_rebase_failure <reason>: converts a rebase engine failure — a per-tier
# timeout (exit 124, the #865 defect) or a hard engine error — into a clean
# terminal abort. It leaves the worktree clean, records a terminal
# `status=failed` marker (so the retry cron stops re-dispatching this SHA), then
# posts the PR-level exhaustion marker once failures reach the threshold.
handle_rebase_failure() {
  local reason="$1" fail_count bodies
  # Leave the worktree clean so a lingering half-applied merge can't poison a
  # later attempt.
  git merge --abort >/dev/null 2>&1 || true
  git rebase --abort >/dev/null 2>&1 || true
  post_reviews_terminal "rebase" "failed" "$reason"
  # Capture bodies and retrieval status separately: a failed retrieval must not be
  # passed to rebase_count_failures as valid empty data (it would count 0 and
  # suppress the exhaustion marker even when the threshold was reached). On a
  # retrieval fault, fail closed by posting the PR-level block — a stuck conflict
  # must not keep generating full-timeout sentinel re-fires just because we could
  # not read the comment history this run.
  if bodies="$(_rebase_comment_bodies)"; then
    fail_count="$(rebase_count_failures "$REVIEWS_MARKER_PREFIX" "$PR_NUMBER" "$bodies")"
    echo "  [rebase] recorded failures on this PR: ${fail_count} (threshold: ${REBASE_MAX_FAIL_ATTEMPTS})"
    if rebase_should_exhaust "${fail_count:-0}" "$REBASE_MAX_FAIL_ATTEMPTS"; then
      echo "::warning::rebase exhaustion threshold reached — posting PR-level block to stop sentinel re-fires (#865)"
      post_rebase_exhaustion "$reason"
    fi
  else
    echo "::warning::could not retrieve PR comments to count rebase failures — failing closed and posting PR-level block to stop sentinel re-fires (#865)"
    post_rebase_exhaustion "$reason"
  fi
}

# Poll cadence for the authoritative mergeable-state check (#1890 AC #2). GitHub
# marks `mergeable` UNKNOWN right after a push while it recomputes mergeability,
# so we poll a few times before treating an UNKNOWN as indeterminate.
REBASE_MERGE_STATE_POLLS="${REBASE_MERGE_STATE_POLLS:-6}"
REBASE_MERGE_STATE_POLL_SLEEP="${REBASE_MERGE_STATE_POLL_SLEEP:-5}"

# pr_mergeable_conflict_state: query GitHub's REAL mergeable/mergeStateStatus for
# this PR and classify it via rebase_conflict_state (#1890 AC #2). The rebase
# intent must assert this post-condition instead of trusting its exit code or a
# local trial-merge — a locally-clean merge that GitHub still reports CONFLICTING
# is exactly how a run reported success in seconds while resolving nothing. Polls
# while GitHub is still computing (verdict `indeterminate`) so a transient UNKNOWN
# right after the engine's force-push is not misread as resolved. Echoes
# resolved|conflicting|indeterminate.
pr_mergeable_conflict_state() {
  local polls="$REBASE_MERGE_STATE_POLLS" verdict="indeterminate" json mergeable state i
  for (( i=0; i<polls; i++ )); do
    json="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json mergeable,mergeStateStatus 2>/dev/null || true)"
    mergeable="$(printf '%s' "$json" | jq -r '.mergeable // ""' 2>/dev/null || true)"
    state="$(printf '%s' "$json" | jq -r '.mergeStateStatus // ""' 2>/dev/null || true)"
    verdict="$(rebase_conflict_state "$mergeable" "$state")"
    [ "$verdict" != "indeterminate" ] && break
    if [ $(( i + 1 )) -lt "$polls" ]; then
      sleep "$REBASE_MERGE_STATE_POLL_SLEEP"
    fi
  done
  printf '%s' "$verdict"
}

# verify_resolution_integrity: post-resolution integrity gate (#1890 AC #7). A
# botched conflict resolution has corrupted trunk before (#1482/#1485), so before
# the rebase intent reports `applied` — which lets the PR auto-merge — the resolved
# tree must pass three checks: `bash -n` (syntax) on every changed shell file,
# `shellcheck --severity=warning -x` (matching ci.yml / dev-lead-lint) on the same,
# and `check-duplicate-decls.sh` (the whole-block-duplication signature). Returns 0
# when clean, 1 when any check fails (naming which). This is the merge-blocking
# backstop to run_post_resolution_integrity_check's advisory introduced-diff scan.
verify_resolution_integrity() {
  local base_ref="${1:-${BASE_REF:-main}}" rc=0 changed file
  local script_dir
  script_dir="${AGENT_SCRIPT_DIR:-$(dirname "$0")}"
  changed="$(git diff --name-only "origin/${base_ref}...HEAD" -- '*.sh' 2>/dev/null || true)"
  while IFS= read -r file || [ -n "$file" ]; do
    [ -n "$file" ] || continue
    [ -f "$file" ] || continue   # deleted by the resolution — nothing to check
    if ! bash -n "$file" 2>/dev/null; then
      echo "::warning::integrity gate: bash -n failed on ${file} after rebase resolution (#1890 AC #7)"
      rc=1
    fi
    if command -v shellcheck >/dev/null 2>&1; then
      if ! shellcheck --severity=warning -x "$file" >/dev/null 2>&1; then
        echo "::warning::integrity gate: shellcheck failed on ${file} after rebase resolution (#1890 AC #7)"
        rc=1
      fi
    fi
  done <<EOF
${changed}
EOF
  if [ -x "${script_dir}/check-duplicate-decls.sh" ]; then
    # The gate's default no-arg mode scans its own directory ($SCRIPT_DIR = the
    # checked-out dev-lead scripts repo), not the PR's resolved working tree. Point
    # it at the resolved tree explicitly so it inspects the rebased files: pass the
    # work tree's scripts/ as SCAN_DIR and name its prompts/ and personas/ dirs so
    # all three scopes scan the PR tree. Nonexistent dirs are skipped by the gate.
    local work_root
    work_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    if ! DUPLICATE_DECL_PROMPTS_DIR="${work_root}/prompts" \
         DUPLICATE_DECL_PERSONAS_DIR="${work_root}/personas" \
         "${script_dir}/check-duplicate-decls.sh" "${work_root}/scripts" >/dev/null 2>&1; then
      echo "::warning::integrity gate: check-duplicate-decls.sh failed after rebase resolution — possible #1485 corruption (#1890 AC #7)"
      rc=1
    fi
  fi
  return "$rc"
}

# expire_stale_terminal_markers: deletes any existing terminal comments (applied,
# no-changes, or failed) for this SHA+intent before a hard-blocker retry marker is
# posted. Without this, the retry cron sees a stale terminal and skips re-dispatch
# even though a new hard blocker (e.g. a CHANGES_REQUESTED review added after the
# prior run) now requires retry.
expire_stale_terminal_markers() {
  local intent="$1"
  local sha="${HEAD_SHA:-}"
  [ -z "$sha" ] && return 0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would expire stale terminal markers for intent=${intent} sha=${sha}"
    return 0
  fi
  local pattern="${REVIEWS_MARKER_PREFIX}${PR_NUMBER} sha=${sha} intent=${intent} status=(applied|no-changes|failed)"
  # A fix-bot-comment pass handles ONE comment, so it expires only that comment's
  # terminal markers. Other comments' completed passes on the same SHA are what
  # keeps the #2017 retry from re-dispatching them.
  if [ "$intent" = "fix-bot-comment" ] && [[ "${COMMENT_NODE_ID:-}" =~ ^[-A-Za-z0-9_+/=]+$ ]]; then
    pattern="${pattern} comment=${COMMENT_NODE_ID//+/\\+}( |-->)"
  fi
  local stale_ids
  stale_ids=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
    | jq -r --arg pat "$pattern" '[.[] | select(.body | test($pat))] | .[].id' 2>/dev/null || true)
  for comment_id in $stale_ids; do
    echo "::notice::expire_stale_terminal_markers: deleting stale terminal comment ${comment_id} for intent=${intent} SHA=${sha}"
    gh api -X DELETE "repos/${REPO}/issues/comments/${comment_id}" 2>/dev/null || \
      echo "::warning::expire_stale_terminal_markers: failed to delete comment ${comment_id}" >&2
  done
}

# expire_stale_rate_limited_marker: deletes any existing hold marker
# (status=rate-limited OR status=blocked, #1568) for this SHA+intent before a new
# one is posted. Without this, when a hard blocker persists past the initial backoff
# window the dedup check in post_reviews_rate_limited skips posting, leaving a marker
# whose reset_time is already in the past. The retry cron then dispatches on every
# scan indefinitely instead of extending the backoff. Both tokens are matched so a
# reason switch (or a pre-#1568 marker) is still cleaned up.
expire_stale_rate_limited_marker() {
  local intent="$1"
  local sha="${HEAD_SHA:-}"
  [ -z "$sha" ] && return 0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would expire stale rate-limited marker for intent=${intent} sha=${sha}"
    return 0
  fi
  local pattern="${REVIEWS_MARKER_PREFIX}${PR_NUMBER} sha=${sha} intent=${intent} status=(rate-limited|blocked|history-unavailable)"
  local stale_ids
  stale_ids=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
    | jq -r --arg pat "$pattern" '[.[] | select(.body | test($pat))] | .[].id' 2>/dev/null || true)
  for comment_id in $stale_ids; do
    echo "::notice::expire_stale_rate_limited_marker: deleting stale rate-limited comment ${comment_id} for intent=${intent} SHA=${sha}"
    gh api -X DELETE "repos/${REPO}/issues/comments/${comment_id}" 2>/dev/null || \
      echo "::warning::expire_stale_rate_limited_marker: failed to delete comment ${comment_id}" >&2
  done
}

# has_reviews_rate_limited_marker: returns 0 if a hold marker with the same reason
# (status=rate-limited for rate-limit reason, status=blocked for blocked reason, #1568)
# for this intent+SHA already exists on the PR (dedup check — suppresses repeat
# visible acks for the SAME hold reason, not across reason changes).
has_reviews_rate_limited_marker() {
  local intent="$1"
  local reason="${2:-rate-limit}"
  local sha="${HEAD_SHA:-}"
  [ -z "$sha" ] && return 1  # no SHA means no dedup possible
  local status_token="rate-limited"
  { [ "$reason" = "blocked" ] || [ "$reason" = "resolve-failed" ]; } && status_token="blocked"
  # Match the reason too: blocked and resolve-failed share status=blocked, and a
  # change of hold reason must still notify the requester. A legacy marker with no
  # reason= field (pre-#1568) still dedups on its status alone.
  local pattern="${REVIEWS_MARKER_PREFIX}${PR_NUMBER} sha=${sha} intent=${intent} status=${status_token}( reason=${reason}( |$)| reset=| -->|$)"
  local count
  count=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
    | jq -c --arg pat "$pattern" '[.[] | select(.body | test($pat))] | length' 2>/dev/null \
    || echo "0")
  [ "${count:-0}" -gt 0 ]
}

# post_reviews_rate_limited: posts a rate-limited marker for fix-reviews intents.
# For retryable intents (fix-reviews, review-changes, rebase), the cron will re-dispatch.
# fix-bot-comment is re-dispatched per comment by the cron's undispositioned
# bot-comment scan (#2017), which re-fetches the comment by node id. on-mention is
# not retryable: it asks the user to re-trigger, since USER_INSTRUCTION cannot be
# reconstructed at retry time.
#
# $2 (reason) selects both the machine-readable status token and the user-facing
# wording:
#   rate-limit (default) — all AI engines genuinely rate-limited (engine exit 2);
#                          emits `status=rate-limited`
#   blocked              — engine ran fine but the PR still has hard blockers
#                          (failing/cancelled checks or CHANGES_REQUESTED reviews);
#                          emits `status=blocked` and schedules a 30-minute backoff
#                          retry (issues #461, #1568)
# The status token is now honest per reason (#1568): a non-quota hold is
# `status=blocked`, not `status=rate-limited`, so quota signal is never polluted by
# a hold that has nothing to do with provider quota. dev-lead-retry.sh recognizes
# both tokens (`status=(rate-limited|blocked)`) so re-dispatch behaviour is
# unchanged and pre-#1568 `status=rate-limited` blocked markers still in the wild
# remain retriable.
post_reviews_rate_limited() {
  local intent="$1"
  local reason="${2:-rate-limit}"

  # The blocked path owns its backoff: a fixed 30-minute reset so the retry cron
  # backs off instead of re-dispatching immediately. The rate-limit path's reset
  # is parsed from engine output (parse_reset_time) before this function is called.
  # resolve-failed (a thread/comment resolution or finalization failure) is not a
  # quota hold either: it takes the same non-quota status and backoff (#2045).
  if [ "$reason" = "blocked" ] || [ "$reason" = "resolve-failed" ]; then
    printf '%s' "$(date -u -d '+30 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" > /tmp/dev-lead-rate-limit-reset
  fi

  # Expire any stale terminal markers (applied/no-changes/failed) for this SHA+intent
  # so the retry cron is not masked by a prior terminal that predates the current blocker.
  # Without this, a no-changes terminal from before a reviewer's CHANGES_REQUESTED would
  # cause the cron to skip dispatch even though a new rate-limited marker was just posted.
  expire_stale_terminal_markers "$intent"

  # Detect whether a prior marker with the same reason exists BEFORE posting the new one.
  # Used to suppress duplicate visible ack comments when a persistent blocker keeps
  # triggering retries — the user-facing ack is only shown on the first cycle.
  # Only suppress if the reason is the same (issue #1568 logic error: suppress on
  # reason change would hide the shift from blocked→rate-limited or vice versa).
  local had_prior_rl_marker=false
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "false" ]; then
    has_reviews_rate_limited_marker "$intent" "$reason" && had_prior_rl_marker=true
  fi

  # Collect IDs of existing rate-limited markers BEFORE posting the new one. The new
  # marker is posted first so the old one remains as a safety net if the post fails
  # transiently; old markers are only removed after the replacement is confirmed posted.
  local stale_rl_ids=""
  if [ -n "${HEAD_SHA:-}" ]; then
    if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
      echo "[dry-run] would expire stale rate-limited marker for intent=${intent} sha=${HEAD_SHA}"
    else
      local rl_pattern="${REVIEWS_MARKER_PREFIX}${PR_NUMBER} sha=${HEAD_SHA} intent=${intent} status=(rate-limited|blocked|history-unavailable)"
      stale_rl_ids=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
        | jq -r --arg pat "$rl_pattern" '[.[] | select(.body | test($pat))] | .[].id' 2>/dev/null || true)
    fi
  fi

  local reset_time
  reset_time=$(cat /tmp/dev-lead-rate-limit-reset 2>/dev/null || true)
  local reset_detail=""
  if [ -n "$reset_time" ]; then
    reset_detail=" reset=${reset_time}"
  fi

  local sha_detail=""
  if [ -n "${HEAD_SHA:-}" ]; then
    sha_detail=" sha=${HEAD_SHA}"
  fi

  # The status token is honest per reason (#1568): a non-quota hold is
  # `status=blocked`; a genuine quota hold is `status=rate-limited`. `reason=` stays
  # for visible-text selection + marker forensics. The retry cron and marker dedup
  # patterns match `status=(rate-limited|blocked)`, so both tokens re-dispatch.
  local status_token="rate-limited"
  { [ "$reason" = "blocked" ] || [ "$reason" = "resolve-failed" ]; } && status_token="blocked"
  local marker="${REVIEWS_MARKER_PREFIX}${PR_NUMBER}${sha_detail} intent=${intent} status=${status_token} reason=${reason}${reset_detail} -->"

  # Retry message depends on the reason and on whether the intent can be
  # re-dispatched automatically.
  local heading retry_msg
  if [ "$reason" = "resolve-failed" ]; then
    heading="## Dev-Lead — could not finish resolving review items (intent: ${intent})"
    retry_msg="A review-thread or comment resolution step failed after the fix pass, so the pass was not marked done. The retry cron will re-attempt automatically."
    if [ -n "$reset_time" ]; then
      retry_msg="${retry_msg} Next attempt after: \`${reset_time}\`"
    fi
  elif [ "$reason" = "blocked" ]; then
    heading="## Dev-Lead — waiting on PR blockers (intent: ${intent})"
    retry_msg="No changes were committed, but the PR still can't be marked done: $(blocking_reason_phrase). The retry cron will re-attempt automatically."
    if [ -n "$reset_time" ]; then
      retry_msg="${retry_msg} Next attempt after: \`${reset_time}\`"
    fi
  else
    heading="## Dev-Lead — rate-limited (intent: ${intent})"
    case "$intent" in
      fix-reviews|review-changes|rebase)
        retry_msg="The retry cron will re-attempt automatically."
        ;;
      fix-bot-comment)
        # #2017: the cron's undispositioned bot-comment scan re-dispatches the pass
        # (re-reading the comment by node id) while it still lacks a disposition.
        retry_msg="The retry cron will re-attempt automatically after the rate limit resets, while the bot comment still lacks a disposition."
        ;;
      on-mention)
        retry_msg="Please re-trigger manually (re-mention \`@dev-lead\`) when the rate limit clears — the original request cannot be reconstructed automatically."
        ;;
      *)
        retry_msg="Manual re-trigger may be required."
        ;;
    esac
    if [ -n "$reset_time" ]; then
      retry_msg="${retry_msg} Rate limit resets at: \`${reset_time}\`"
    fi
  fi

  local marker_body="${marker}
${heading}
**PR:** #${PR_NUMBER}
${retry_msg}"

  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] would post rate-limited marker for intent=${intent} reason=${reason}"
    echo "$marker_body"
  else
    # Post the new marker FIRST, then remove old marker(s) only after the replacement
    # is confirmed. If the post fails transiently, the old marker remains as a safety net
    # so the retry cron does not lose track of this SHA+intent.
    if gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$marker_body"; then
      for _stale_id in $stale_rl_ids; do
        echo "::notice::post_reviews_rate_limited: deleting superseded rate-limited marker ${_stale_id} for intent=${intent}"
        gh api -X DELETE "repos/${REPO}/issues/comments/${_stale_id}" 2>/dev/null || \
          echo "::warning::post_reviews_rate_limited: failed to delete old rate-limited marker ${_stale_id}" >&2
      done
    fi
  fi

  # For user-triggered intents, post a separate visible acknowledgment on the first
  # rate-limit cycle only. Suppress repeat acks when a persistent blocker keeps the
  # backoff interval cycling — the old ack is still visible and a repeat is misleading.
  if [ "$had_prior_rl_marker" = "false" ]; then
    case "$intent" in
      review-changes)
        local actor_mention=""
        [ -n "${ACTOR:-}" ] && actor_mention="@${ACTOR} "
        local reset_display="${reset_time:-unknown}"
        local ack_body
        if [ "$reason" = "resolve-failed" ]; then
          ack_body="<!-- dev-lead rate-limit-ack -->
> [!NOTE]
> ${actor_mention}I worked through this PR, but a review-thread or comment resolution step failed, so I can't mark it done yet. I'll retry automatically.
> Next attempt after: \`${reset_display}\`"
        elif [ "$reason" = "blocked" ]; then
          ack_body="<!-- dev-lead rate-limit-ack -->
> [!NOTE]
> ${actor_mention}I reviewed this PR and no code changes were needed, but I can't mark it done yet: $(blocking_reason_phrase). I'll re-check automatically.
> Next attempt after: \`${reset_display}\`"
        else
          ack_body="<!-- dev-lead rate-limit-ack -->
> [!NOTE]
> ${actor_mention}I received your request but all AI engines are currently rate-limited. I'll retry automatically once the rate limit clears.
> Rate limit resets at: \`${reset_display}\`"
        fi
        if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
          echo "[dry-run] would post user-visible ${reason} acknowledgment"
          echo "$ack_body"
        else
          gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$ack_body"
        fi
        ;;
      on-mention)
        local actor_mention=""
        [ -n "${ACTOR:-}" ] && actor_mention="@${ACTOR} "
        local reset_display="${reset_time:-unknown}"
        local ack_body="<!-- dev-lead rate-limit-ack -->
> [!NOTE]
> ${actor_mention}I received your request but all AI engines are currently rate-limited. Please re-mention \`@dev-lead\` when the rate limit clears (estimated: \`${reset_display}\`) — I cannot reconstruct the original instruction automatically."
        if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
          echo "[dry-run] would post user-visible rate-limit acknowledgment"
          echo "$ack_body"
        else
          gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$ack_body"
        fi
        ;;
    esac
  fi
}

# handle_rate_limit <intent>: posts a rate-limited marker and exits when all engines hit rate limits.
handle_rate_limit() {
  local intent="$1"
  echo "::warning::All engines rate-limited for intent=${intent} — posting rate-limited marker"
  post_reviews_rate_limited "$intent"
  [[ -n "${PR_NUMBER:-}" ]] && try_enable_auto_merge
  exit 2
}

# Marker for the no-op guard flag comment (#1340), deduped per PR+intent.
NOOP_MARKER_PREFIX="<!-- dev-lead-noop-guard pr="

# pr_nets_to_zero [base] — returns 0 (true) when the PR branch's net diff against
# its base is empty: every change the PR's own commits introduced has been undone,
# so `origin/<base>...HEAD` shows zero changed files. Such a PR must never carry a
# pushed fix — merging a `Closes #N` PR that nets to zero would auto-close its
# compliance issue while the finding remains unfixed (#1340). When the base cannot
# be resolved (no ref, fetch fails, no common ancestor) it returns 1 and warns,
# so an unverifiable state never blocks a legitimate push.
pr_nets_to_zero() {
  local base="${1:-${BASE_REF:-main}}"
  local baseref="origin/${base}"
  # actions/checkout defaults to a depth-1 shallow clone, which lacks the common
  # ancestor "${baseref}...HEAD" needs. A plain `git fetch origin "$base"` does NOT
  # deepen a shallow checkout, so the merge-base stays absent, the diff below errors,
  # and the guard silently fails OPEN (returns 1 → "not net-zero" → push proceeds).
  # Deepen to full history first so the merge-base resolves (lib/git-history.sh).
  git_history_deepen "$base"
  if ! git rev-parse --verify --quiet "${baseref}^{commit}" >/dev/null 2>&1; then
    git fetch --quiet origin "$base" 2>/dev/null || {
      echo "::warning::no-op guard: could not resolve ${baseref} — skipping net-zero check" >&2
      return 1
    }
  fi
  # A merge-base must exist before diffing; without it "${baseref}...HEAD" errors and
  # the guard would fail open. Treat a genuinely absent merge-base as unverifiable.
  if ! git merge-base "$baseref" HEAD >/dev/null 2>&1; then
    echo "::warning::no-op guard: no merge-base between ${baseref} and HEAD — skipping net-zero check" >&2
    return 1
  fi
  local changed
  changed=$(git diff --name-only "${baseref}...HEAD" 2>/dev/null) || {
    echo "::warning::no-op guard: git diff against ${baseref} failed — skipping net-zero check" >&2
    return 1
  }
  [ -z "$changed" ]
}

# flag_noop_pr <intent> — a fix pass reverted the PR's own changes, netting the
# base…head diff to zero (#1340). Post one deduped human-attention comment, add
# the needs-human-review label, and disable auto-merge — and suppress the
# EXIT-trap auto-merge restore so a self-cancelling PR is never silently made
# mergeable again. Mirrors pr_automation_escalate's escalation shape.
flag_noop_pr() {
  local intent="$1"
  # A self-cancelling PR must stay unmergeable until a human looks: prevent
  # restore_auto_merge (EXIT trap) from re-enabling what we are about to disable.
  _AM_NEEDS_RESTORE=0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] no-op guard: would flag PR #${PR_NUMBER} (${intent}) as net-zero, add ${NEEDS_HUMAN_REVIEW_LABEL:-needs-human-review}, disable auto-merge"
    return 0
  fi
  local marker="${NOOP_MARKER_PREFIX}${PR_NUMBER} intent=${intent} -->"
  # Label first so the flag comment can say when the PR could not be held (#2142).
  apply_hold_label "$REPO" "$PR_NUMBER" || true
  if gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
       | jq -r '.[].body // ""' 2>/dev/null | grep -qF "$marker"; then
    echo "::notice::PR #${PR_NUMBER} already flagged as net-zero for intent=${intent} — not reposting"
    post_hold_failure_note "$REPO" "$PR_NUMBER"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "${marker}
## No-op fix detected — human attention needed

The \`${intent}\` pass reverted this PR's own changes, so its net diff against \`${BASE_REF:-main}\` is now **empty** (zero changed files). Merging a PR that nets to zero would auto-close its \`Closes #N\` compliance issue while the underlying finding remains unfixed (#1340), and the idempotent audit would immediately re-open it.

Auto-merge has been disabled and no commit was pushed. A human should restore the correct fix or close this PR.${HOLD_LABEL_NOTE}" \
      || echo "::warning::could not post no-op flag comment on PR #${PR_NUMBER}"
  fi
  disable_auto_merge_for_hold "$REPO" "$PR_NUMBER" || true
  return 0
}

# commit_and_push: adds all changes, commits with an intent-specific message,
# and pushes to the PR branch. Returns 0 if changes were made and pushed,
# 1 if no changes were found, 3 if the no-op guard aborted the push (#1340).
commit_and_push() {
  local intent="$1"
  local has_uncommitted=false has_unpushed=false

  # git status --porcelain covers untracked files that git diff misses
  [ -n "$(git status --porcelain 2>/dev/null)" ] && has_uncommitted=true

  # Detect engine-committed but not pushed: prefer @{u} if upstream is configured,
  # fall back to HEAD_SHA (resolved from PR API at script startup) for fork checkouts.
  local upstream
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null || true)
  if [ -n "$upstream" ]; then
    git log "${upstream}..HEAD" --oneline 2>/dev/null | grep -q . && has_unpushed=true
  elif [ -n "${HEAD_SHA:-}" ]; then
    git log "${HEAD_SHA}..HEAD" --oneline 2>/dev/null | grep -q . && has_unpushed=true
  fi

  if ! $has_uncommitted && ! $has_unpushed; then
    echo "::notice::No changes to commit for intent=${intent}"
    return 1
  fi

  local commit_msg
  case "$intent" in
    fix-reviews)     commit_msg="fix(reviews): address review comments [skip ci-relay]" ;;
    fix-bot-comment) commit_msg="fix(bot): address bot feedback [skip ci-relay]" ;;
    human|human-pr)  commit_msg="chore: apply manual instructions [skip ci-relay]" ;;
    rebase)          commit_msg="chore: resolve rebase conflicts [skip ci-relay]" ;;
    *)               commit_msg="chore: dev-lead update (${intent}) [skip ci-relay]" ;;
  esac

  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    if $has_uncommitted; then
      echo "[dry-run] would git add -A, commit '${commit_msg}', and push"
    else
      echo "[dry-run] engine already committed — would push existing commit(s) without re-committing"
    fi
  else
    if $has_uncommitted; then
      git add -A
      # Ensure git identity is set — actions/checkout only sets local config for the
      # repo it checks out (.github-private), not for target repos cloned separately.
      setup_git_identity
      # Explicit exit on failure: set -e is suspended when commit_and_push is called from
      # an if-statement condition, so git commit failures would be silently swallowed
      # otherwise. Using exit (not return) ensures CI fails visibly instead of posting a
      # false "Changes committed and pushed" comment.
      git commit -m "$commit_msg" || { echo "::error::git commit failed — check git identity configuration on the runner" >&2; exit 1; }
    fi
    # No-op guard (#1340, extended #1786): a fix/review/rebase pass that reverts
    # the PR's own changes nets the base…head diff to zero. Pushing it would let a
    # `Closes #N` PR auto-close its compliance issue while the finding remains
    # unfixed. Abort the push and flag for a human instead of self-cancelling.
    # #1786 broadens the covered intents from fix-reviews/fix-bot-comment to every
    # intent that pushes to a PR branch (review-changes, human, rebase, …).
    case "$intent" in
      enable-auto-merge) ;;  # never pushes; nothing to guard
      *)
        if pr_nets_to_zero "${BASE_REF:-main}"; then
          echo "::error::No-op guard: PR #${PR_NUMBER} nets to zero changed files against ${BASE_REF:-main} after ${intent} — refusing to push a self-cancelling fix (#1340/#1786)"
          flag_noop_pr "$intent"
          return 3
        fi
        ;;
    esac
    # Sync-stub guard (#2185): on a `standards-sync` PR, a bot-driven pass must not
    # change a stub copied verbatim from petry-projects/.github/standards/ (the
    # incubator#164 shape). Restoring a stub to what the sync commit wrote is
    # allowed. Maintainer-driven intents (review-changes/human-pr, on-mention,
    # human) are the explicit override and are not guarded. The PR is read only
    # when the pass touched a stub; an unreadable PR fails closed only for header stubs.
    case "$intent" in
      fix-bot-comment|fix-reviews)
        local ssg_pr="" ssg_out ssg_rc=0
        if ssg_pass_touches_stubs "${RESOLUTION_BASE_SHA:-}" HEAD && [ -n "${PR_NUMBER:-}" ] && [ -n "${REPO:-}" ]; then
          # Bounded retry: unreadable = non-zero exit or output that is not a JSON object.
          local ssg_try
          for ssg_try in 1 2 3; do
            ssg_pr=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" 2>/dev/null) || ssg_pr=""
            jq -e 'type == "object"' <<<"$ssg_pr" >/dev/null 2>&1 && break
            ssg_pr=""
            [ "$ssg_try" -lt 3 ] && sleep "${SSG_RETRY_SLEEP:-2}"
          done
        fi
        ssg_out=$(ssg_evaluate "${RESOLUTION_BASE_SHA:-}" HEAD "$ssg_pr" "${HEAD_REF:-}") || ssg_rc=$?
        if [ "$ssg_rc" -ne 0 ]; then
          echo "::error::Sync-stub guard: the ${intent} pass changed a synced org-standard stub on a standards-sync PR ($(printf '%s\n' "$ssg_out" | head -1)) — refusing to push (#2185)"
          flag_sync_stub_drift "$intent" "$(printf '%s\n' "$ssg_out" | sed '1d')"
          return 4
        fi
        ;;
    esac
    # Test-tamper guard (#2013): a bot-driven fix pass must not silently rewrite an
    # existing test to make its own change pass (the petry-projects/.github#1220
    # `13927fc` shape). Refuse the push and escalate, like the no-op guard (rc 3).
    # "Existing" means present at the merge base with the PR's base branch (#2141):
    # tests the PR itself added are free to revise. The merge base is resolved only
    # when the pass touches a test file; an unresolvable one leaves ttg_mb empty,
    # which ttg_scan_pass then refuses (fail closed).
    case "$intent" in
      fix-reviews|fix-bot-comment|review-changes|human-pr)
        local ttg_out ttg_rc=0 ttg_files ttg_mb=""
        if ttg_pass_touches_tests "${RESOLUTION_BASE_SHA:-}"; then
          # Several intents default BASE_REF to `main` before the PR is read, so ask
          # the API for the PR's real target; an unreadable base leaves ttg_mb empty.
          local ttg_base=""
          if [ -n "${PR_NUMBER:-}" ] && [ -n "${REPO:-}" ]; then
            ttg_base=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.base.ref // empty' 2>/dev/null) || ttg_base=""
          fi
          if [ -n "$ttg_base" ]; then
            ttg_mb=$(ttg_resolve_merge_base "$ttg_base" "${RESOLUTION_BASE_SHA:-}" "${HEAD_REF:-}") || ttg_mb=""
          fi
        fi
        ttg_out=$(ttg_scan_pass "${RESOLUTION_BASE_SHA:-}" HEAD "$ttg_mb") || ttg_rc=$?
        ttg_files=$(printf '%s\n' "$ttg_out" | sed '1d' | paste -sd ',' - | sed 's/,/, /g')
        if [ "$ttg_rc" -eq 1 ]; then
          echo "::error::Test-tamper guard: the ${intent} pass changed or skipped existing test(s) [${ttg_files:-skip added}] with no Test-Change-Justification trailer — refusing to push (#2013)"
          flag_test_tamper "$intent" "${ttg_files:-a skip was added to a test file}"
          return 4
        elif [ "$ttg_rc" -ne 0 ]; then
          # Fail closed: an unverifiable scan is not a clean scan.
          echo "::error::Test-tamper guard: pre-pass head or merge base with ${BASE_REF:-main} unknown — could not verify ${intent} for rewritten tests, refusing to push (#2013/#2141)"
          flag_test_tamper "$intent" "(the tamper scan could not resolve the pre-pass head or the PR's merge base with \`${BASE_REF:-main}\`, so the pass could not be verified)"
          return 4
        elif [ "$(printf '%s\n' "$ttg_out" | head -1)" = "justified" ]; then
          echo "::notice::Test-tamper guard: existing test(s) changed with a cited Test-Change-Justification: ${ttg_files:-skip added} (#2013)"
        fi
        ;;
    esac
    # Test-regression guard (#2013): the `15a919e` shape adds a new test and breaks an
    # existing one WITHOUT editing it, so the tamper guard is silent. Run the suite;
    # refuse the push when a test that passed on the pre-pass head fails on the result.
    case "$intent" in
      fix-reviews|fix-bot-comment|review-changes|human-pr)
        local trg_out trg_rc=0 trg_verdict trg_cmd trg_tests
        trg_out=$(trg_scan_pass "${RESOLUTION_BASE_SHA:-}") || trg_rc=$?
        IFS=$'\t' read -r trg_verdict trg_cmd <<<"$(printf '%s\n' "$trg_out" | head -1)"
        trg_tests=$(printf '%s\n' "$trg_out" | sed '1d' | paste -sd ',' - | sed 's/,/, /g')
        record_suite_summary "$(trg_summary_line "$trg_verdict" "$trg_cmd")"
        if [ "$trg_rc" -ne 0 ]; then
          echo "::error::Test-regression guard: the ${intent} pass broke test(s) that passed on the pre-pass head [${trg_tests}] — refusing to push (#2013)"
          flag_test_regression "$intent" "${trg_tests:-(unnamed)}"
          return 4
        fi
        ;;
    esac
    # No-clobber push (#1311): never discard a concurrent writer's unseen commit.
    # push_no_clobber fast-forwards normally and only ever force-with-leases a
    # rewritten branch, aborting if the remote moved beyond what we fetched.
    # A rejected push — or one the remote head does not reflect (#2013) — must not
    # leave this pass's "Fixed" replies standing: retract them before failing.
    # (commit_and_push returns 3 for the no-op guard and 4 for the sync-stub,
    # test-tamper and test-regression guards.)
    push_no_clobber || {
      echo "::error::git push failed — check remote access and branch permissions" >&2
      retract_unlanded_claims "$intent" failed || true
      exit 1
    }
    verify_push_landed || {
      retract_unlanded_claims "$intent" failed || true
      exit 1
    }
  fi
  return 0
}

# verify_push_landed — "the push landed" is a verdict on SHAs, not an assumption
# (#2013). Compares the immutable pre-pass head (RESOLUTION_BASE_SHA), the pushed
# HEAD, and the TRUE remote head via cl_push_landed_verdict; returns non-zero
# unless the remote contains the pushed commit. Without a PR checkout (no
# pre-pass head) or an upstream (no push target to read back) there is nothing to
# compare, so it warns and passes — the push itself already succeeded.
verify_push_landed() {
  local start="${RESOLUTION_BASE_SHA:-}" pushed remote="" remote_rc=0 on_remote=false verdict
  if [ -z "$start" ]; then
    echo "::warning::push-landed check skipped — no pre-pass head recorded for this run (#2013)"
    return 0
  fi
  pushed="$(git rev-parse HEAD 2>/dev/null || true)"
  remote=$(cl_remote_head) || remote_rc=$?
  if [ "$remote_rc" -eq 1 ]; then
    echo "::warning::push-landed check skipped — the branch has no upstream to read back (#2013)"
    return 0
  fi
  if [ "$remote_rc" -ne 0 ]; then
    # Fail closed: an unreadable remote head is indeterminate, not "landed". Abort
    # so the caller retracts this pass's claim replies (#2013).
    echo "::error::push not verified (unknown): could not read the remote head back after the push (pre-pass head ${start}) — treating the push as failed (#2013)" >&2
    return 1
  fi
  if [ -n "$remote" ] && [ -n "$pushed" ] && git merge-base --is-ancestor "$pushed" "$remote" 2>/dev/null; then
    on_remote=true
  fi
  if ! verdict=$(cl_push_landed_verdict "$start" "$pushed" "$remote" "$on_remote"); then
    echo "::error::push not verified (${verdict}): the remote head ${remote:-<unknown>} does not contain the pushed commit ${pushed:-<unknown>} (pre-pass head ${start}) — treating the push as failed (#2013)" >&2
    return 1
  fi
  echo "::notice::push verified: ${pushed} is on the remote head ${remote} (#2013)"
  return 0
}

# nochange_epoch_cutoff — the instant from which a marker-less maintainer comment may
# authorize a no-change resolution (#2079 AC4). Read from DEV_LEAD_NOCHANGE_EPOCH, never
# hard-coded: dev-lead replies posted by a release that predates the stamping are
# marker-less and look like the maintainer's own, so the maintainer turns the path on
# (by setting this to an instant after the stamping release reached every consumer's
# channel) only when that is safe. Unset or unparseable => returns 1: the no-change
# path is disabled.
nochange_epoch_cutoff() {
  local e="${DEV_LEAD_NOCHANGE_EPOCH:-}"
  [[ "$e" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  _acv_is_iso8601 "$e" || return 1
  printf '%s\n' "$e"
}

# stamp_pass_replies — make every review-thread reply this pass posted attributable to
# dev-lead (#2079 AC4). The model posts skip notes from its own shell as the SAME
# account the maintainer uses, and only addressed claims are told to carry a marker, so
# a marker-less "No change needed" skip note would otherwise read as the maintainer's
# verdict. Attribution is by IDENTITY: the recording gh shim (cl_install_reply_recorder)
# captured the node id of each reply the pass posted, and ONLY those ids are rewritten
# (`<!-- dev-lead:reply -->` appended when no agent marker is present). A comment whose
# id was not recorded — e.g. the maintainer's own, posted mid-pass — is never touched.
# Returns non-zero when no recorder record exists, a reply could not be attributed, or a
# fetch/update failed; the resolvers then skip the no-change path (fail closed).
# Idempotent: a stamped reply carries a marker and is skipped.
stamp_pass_replies() {
  local record="${PASS_REPLY_RECORD:-}" ids id body_json body failed=0
  local pending_file="${PASS_REPLY_PENDING_FILE:-${RUNNER_TEMP:-/tmp}/dev-lead-unstamped-replies-${PR_NUMBER:-0}}"
  local recorded="" pending="" new_pending=""
  if recorded=$(cl_recorded_reply_ids "$record"); then
    :
  else
    echo "::warning::stamp_pass_replies: no usable reply record — no-change dispositions are disabled this pass (#2079)"
    failed=1
    recorded=""
  fi
  # Replies that failed to be stamped in an earlier pass stay pending until stamped,
  # so a marker-less dev-lead reply is never forgotten (#2079).
  [ -f "$pending_file" ] && pending=$(cat "$pending_file" 2>/dev/null || true)
  ids=$(printf '%s\n%s\n' "$recorded" "$pending" | awk 'NF && !seen[$0]++')
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if ! body_json=$(gh api graphql \
        -f query='query($id:ID!){node(id:$id){... on PullRequestReviewComment{body}}}' \
        -f id="$id" 2>/dev/null); then
      failed=1; new_pending+="${id}"$'\n'; continue
    fi
    body=$(jq -er '.data.node.body // empty' <<<"$body_json" 2>/dev/null) || { failed=1; new_pending+="${id}"$'\n'; continue; }
    review_thread_is_agent_authored "$body" && continue
    if ! gh api graphql \
        -f query='mutation($id:ID!,$body:String!){updatePullRequestReviewComment(input:{pullRequestReviewCommentId:$id,body:$body}){pullRequestReviewComment{id}}}' \
        -f id="$id" -f body="$(cl_reply_stamp_body "$body")" >/dev/null 2>&1; then
      echo "::warning::stamp_pass_replies: could not stamp reply ${id} on PR #${PR_NUMBER:-} — will retry on later passes (#2079)"
      failed=1
      new_pending+="${id}"$'\n'
    fi
  done <<< "$ids"
  # Persist whatever is still unstamped so later passes retry it and keep no-change
  # dispositions disabled until it is resolved.
  if [ -n "$new_pending" ]; then
    printf '%s' "$new_pending" > "$pending_file" 2>/dev/null || \
      echo "::warning::stamp_pass_replies: could not persist unstamped reply ids to ${pending_file} (#2079)"
  else
    rm -f "$pending_file" 2>/dev/null || true
  fi
  [ "$failed" -eq 0 ]
}

# retract_unlanded_claims <intent> <ok|failed> — the claim-retraction sweep (#2013).
# The model posts its addressed/claim replies from its own shell BEFORE the
# harness commits and pushes, so a failed push, a guard abort, an engine failure,
# or a claim naming a pre-pass commit left a false "Fixed" on the thread — and
# another bot could treat it as addressed. For every claim reply OUR account
# posted since PASS_START_ISO, verify its commit is one this pass produced AND is
# on the REMOTE head (acv_claim_in_pass); otherwise rewrite it with
# cl_retract_body, which strips both markers so it can never resolve a thread.
#
# The reference head is the remote head. When there is no upstream (rc 1) on an
# `ok` outcome, the local HEAD is what was pushed; in every other case — including
# a failed read-back (rc 2), which is indeterminate — nothing verifiably landed, so
# the pre-pass base is used and every claim fails.
# Idempotent: a retracted reply carries no marker and is never selected again.
retract_unlanded_claims() {
  local intent="$1" outcome="${2:-ok}"
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would retract unlanded claim replies posted by this ${intent} pass on PR #${PR_NUMBER:-}"
    return 0
  fi
  [ -z "${PR_NUMBER:-}" ] && return 0
  if [ -z "${PASS_START_ISO:-}" ]; then
    echo "::notice::retract_unlanded_claims: no pass start recorded — skipping (#2013)"
    return 0
  fi

  local bot_user="${BOT_USER:-donpetry-bot}" base="${RESOLUTION_BASE_SHA:-}"
  local ref="" ref_rc=0
  ref=$(cl_remote_head) || ref_rc=$?
  if [ -z "$ref" ]; then
    if [ "$ref_rc" -eq 1 ] && [ "$outcome" = "ok" ]; then
      ref="$(git rev-parse HEAD 2>/dev/null || true)"
    else
      ref="$base"
    fi
  fi

  local comments
  if ! comments=$(gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/comments?per_page=100" 2>/dev/null | jq -s 'add // []' 2>/dev/null); then
    echo "::warning::retract_unlanded_claims: could not list review comments on PR #${PR_NUMBER} — this pass's claim replies were NOT verified (#2013)"
    return 1
  fi

  local rows retracted=0 failed=0 id sha facts on_ref in_base reason body new_body
  if ! rows=$(cl_select_pass_claims "$comments" "$bot_user" "$PASS_START_ISO"); then
    echo "::warning::retract_unlanded_claims: could not parse the review comments on PR #${PR_NUMBER} — this pass's claim replies were NOT verified (#2013)"
    return 1
  fi
  while IFS=$'\t' read -r id sha; do
    [ -z "$id" ] && continue
    if [ -z "$sha" ]; then
      reason="unverifiable"
    else
      facts=$(acv_gather_commit_facts "$sha" "$base" "${ref:-HEAD}")
      on_ref=$(printf '%s' "$facts" | jq -r '.on_head // false' 2>/dev/null || echo "false")
      in_base=$(printf '%s' "$facts" | jq -r 'if .in_base == false then "false" else "true" end' 2>/dev/null || echo "true")
      [ -z "$ref" ] && on_ref=false
      if reason=$(acv_claim_in_pass "$base" "$on_ref" "$in_base"); then
        continue
      fi
    fi
    body=$(printf '%s' "$comments" | jq -r --arg id "$id" 'first(.[] | select((.id | tostring) == $id)) | .body // ""' 2>/dev/null || echo "")
    new_body=$(cl_retract_body "$body" "$reason")
    if gh api -X PATCH "repos/${REPO}/pulls/comments/${id}" -f body="$new_body" >/dev/null 2>&1; then
      retracted=$((retracted + 1))
      echo "::warning::retracted claim reply ${id} on PR #${PR_NUMBER} (${reason}; cited ${sha:-<none>}, remote head ${ref:-<unknown>}) (#2013)"
    else
      echo "::error::could not retract claim reply ${id} on PR #${PR_NUMBER} (${reason}) — a false 'Fixed' reply may remain (#2013)"
      failed=1
    fi
  done <<< "$rows"
  echo "::notice::retract_unlanded_claims: retracted ${retracted} claim reply(ies) from this ${intent} pass on PR #${PR_NUMBER} (outcome=${outcome})"
  # A listing or PATCH failure leaves a possibly-false claim standing: report it so
  # callers do not treat the pass as clean (resolution gate closes).
  [ "$failed" -eq 0 ]
}

# record_suite_summary <line> — put the test-suite verdict in the run summary and the
# log, so a pass that did not run the suite never reads as green (#2013).
record_suite_summary() {
  local line="$1"
  case "$line" in
    *"NOT RUN"*|*"NOT verified"*) echo "::warning::${line}" ;;
    *) echo "::notice::${line}" ;;
  esac
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$line" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
  fi
}

# flag_test_regression <intent> <tests> — the test-regression guard refused the push
# (#2013). Same escalation as flag_test_tamper: one deduped comment, the
# needs-human-review label, auto-merge disabled and its EXIT-trap restore suppressed.
flag_test_regression() {
  local intent="$1" tests="$2"
  _AM_NEEDS_RESTORE=0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] test-regression guard: would flag PR #${PR_NUMBER} (${intent}), add ${NEEDS_HUMAN_REVIEW_LABEL:-needs-human-review}, disable auto-merge"
    return 0
  fi
  local marker="<!-- dev-lead-test-regression pr=${PR_NUMBER} intent=${intent} -->"
  # Label first so the flag comment can say when the PR could not be held (#2142).
  apply_hold_label "$REPO" "$PR_NUMBER" || true
  if gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
       | jq -r '.[].body // ""' 2>/dev/null | grep -qF "$marker"; then
    echo "::notice::PR #${PR_NUMBER} already flagged for a test regression for intent=${intent} — not reposting"
    post_hold_failure_note "$REPO" "$PR_NUMBER"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "${marker}
## Test suite newly red — human attention needed

The \`${intent}\` pass left the test suite failing on test(s) that passed on the pre-pass head: ${tests}. A fix that breaks a passing test is wrong or incomplete, so dev-lead **did not push** this pass (#2013). Auto-merge has been disabled.${HOLD_LABEL_NOTE}" \
      || echo "::warning::could not post test-regression flag comment on PR #${PR_NUMBER}"
  fi
  disable_auto_merge_for_hold "$REPO" "$PR_NUMBER" || true
  return 0
}

# flag_test_tamper <intent> <files> — the test-tamper guard refused the push
# (#2013). Mirrors flag_noop_pr: one deduped human-attention comment, the
# needs-human-review label, auto-merge disabled and its EXIT-trap restore
# suppressed. A bot suggestion that contradicts an existing test is a question for
# a human, never a reason to rewrite the test.
flag_test_tamper() {
  local intent="$1" files="$2"
  _AM_NEEDS_RESTORE=0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] test-tamper guard: would flag PR #${PR_NUMBER} (${intent}), add ${NEEDS_HUMAN_REVIEW_LABEL:-needs-human-review}, disable auto-merge"
    return 0
  fi
  local marker="<!-- dev-lead-test-tamper pr=${PR_NUMBER} intent=${intent} -->"
  # Label first so the flag comment can say when the PR could not be held (#2142).
  apply_hold_label "$REPO" "$PR_NUMBER" || true
  if gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
       | jq -r '.[].body // ""' 2>/dev/null | grep -qF "$marker"; then
    echo "::notice::PR #${PR_NUMBER} already flagged for test tampering for intent=${intent} — not reposting"
    post_hold_failure_note "$REPO" "$PR_NUMBER"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "${marker}
## Existing test changed without justification — human attention needed

The \`${intent}\` pass changed, deleted, or skipped **existing** test(s) to go with its fix: ${files}. A previously-passing test that disagrees with a change is a reason to question the change, not to edit the test, so dev-lead **did not push** this pass (#2013).

If the test really is wrong, a human should make that call, or the fix should carry a \`Test-Change-Justification:\` commit trailer that cites the reason (for example, the review comment that asked for it). Auto-merge has been disabled.${HOLD_LABEL_NOTE}" \
      || echo "::warning::could not post test-tamper flag comment on PR #${PR_NUMBER}"
  fi
  disable_auto_merge_for_hold "$REPO" "$PR_NUMBER" || true
  return 0
}

# flag_sync_stub_drift <intent> <rows> — the sync-stub guard refused the push
# (#2185). <rows> are `path\ttemplate` lines (empty when the scan was unknown).
# Same escalation as flag_test_tamper; the comment answers the bot suggestion as
# declined and points at each template in petry-projects/.github.
flag_sync_stub_drift() {
  local intent="$1" rows="$2"
  _AM_NEEDS_RESTORE=0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] sync-stub guard: would decline on PR #${PR_NUMBER} (${intent}), add ${NEEDS_HUMAN_REVIEW_LABEL:-needs-human-review}, disable auto-merge"
    return 0
  fi
  local marker="<!-- dev-lead-sync-stub-drift pr=${PR_NUMBER} intent=${intent} -->"
  # Label first so the flag comment can say when the PR could not be held (#2142).
  apply_hold_label "$REPO" "$PR_NUMBER" || true
  if gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
       | jq -r '.[].body // ""' 2>/dev/null | grep -qF "$marker"; then
    echo "::notice::PR #${PR_NUMBER} already flagged for synced-stub drift for intent=${intent} — not reposting"
    post_hold_failure_note "$REPO" "$PR_NUMBER"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "${marker}
$(ssg_declined_body "$intent" "$rows")${HOLD_LABEL_NOTE}" \
      || echo "::warning::could not post sync-stub flag comment on PR #${PR_NUMBER}"
  fi
  disable_auto_merge_for_hold "$REPO" "$PR_NUMBER" || true
  return 0
}

# count_not_applied_markers <intent> — number of not-applied terminal markers
# currently on the PR for this intent. They are cleared on the next `applied`,
# so the count is the run of consecutive non-converging passes (#1567 AC #4).
count_not_applied_markers() {
  local intent="$1"
  [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ] && { echo 0; return 0; }
  local pattern="${REVIEWS_MARKER_PREFIX}${PR_NUMBER}.* intent=${intent} status=not-applied"
  # No error masking: a failing gh api (auth, rate-limit, network) must abort
  # loudly rather than silently return 0, which would suppress escalation.
  gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" \
    | jq -r --arg pat "$pattern" '[.[] | select((.body // "") | test($pat))] | length'
}

# clear_not_applied_markers <intent> — delete the not-applied markers once a pass
# genuinely applies the requested changes, so the convergence counter resets.
clear_not_applied_markers() {
  local intent="$1"
  [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ] && return 0
  local pattern="${REVIEWS_MARKER_PREFIX}${PR_NUMBER}.* intent=${intent} status=not-applied"
  local ids id
  # No error masking: a failing gh api|jq must abort loudly rather than silently
  # skip the clear, which would leave a stale non-convergence count behind.
  # Explicit `|| return 1`: callers invoke this on the left of `||`, where errexit
  # does not apply.
  ids=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" \
    | jq -r --arg pat "$pattern" '[.[] | select((.body // "") | test($pat))] | .[].id') || return 1
  # Split safely into an array (IFS scoped to read) so no glob metacharacter in
  # the id list undergoes pathname expansion.
  local -a ids_arr=()
  if [ -n "$ids" ]; then
    IFS=$'\n' read -r -d '' -a ids_arr <<< "$ids" || true
  fi
  for id in "${ids_arr[@]}"; do
    gh api -X DELETE "repos/${REPO}/issues/comments/${id}" || return 1
  done
}

# escalate_review_nonconvergence <intent> <count> — the fix pass has committed
# <count> times without applying the requested review changes. Add the
# needs-human label, post one deduped attention comment, disable auto-merge, and
# set _REVIEW_ESCALATED so the caller does not re-enable it (#1567 AC #4).
escalate_review_nonconvergence() {
  local intent="$1" count="$2"
  _REVIEW_ESCALATED=1
  # Keep the EXIT-trap restore from re-enabling auto-merge we are about to disable.
  _AM_NEEDS_RESTORE=0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] review non-convergence: would escalate PR #${PR_NUMBER} (${intent}) after ${count} not-applied passes"
    return 0
  fi
  local marker="${NONCONVERGE_MARKER_PREFIX}${PR_NUMBER} intent=${intent} -->"
  # Label first so the flag comment can say when the PR could not be held (#2142).
  apply_hold_label "$REPO" "$PR_NUMBER" || true
  if gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
       | jq -r '.[].body // ""' 2>/dev/null | grep -qF "$marker"; then
    echo "::notice::PR #${PR_NUMBER} already escalated for review non-convergence (${intent})"
    post_hold_failure_note "$REPO" "$PR_NUMBER"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "${marker}
## Review changes not converging — human attention needed

The \`${intent}\` pass has now committed **${count}** times against this review without applying the requested changes: each pass changed something, but none touched the regions the review named. Automatic retries are unlikely to converge, so this needs a human.

Auto-merge has been disabled and no further automatic passes will run until a human intervenes. A human should apply the requested changes, or clarify the review.${HOLD_LABEL_NOTE}" \
      || echo "::warning::could not post review non-convergence comment on PR #${PR_NUMBER}"
  fi
  disable_auto_merge_for_hold "$REPO" "$PR_NUMBER" || true
}

# finalize_review_application <intent> — called after commit_and_push succeeds on
# the fix-reviews / review-changes path. It gates the status=applied claim on
# evidence the pushed commit actually addressed the requested changes: the commit
# must be non-trivial (has a non-whitespace change) AND touch the regions the
# review named (#1567). Otherwise it posts an honest partial / not-applied
# terminal, enumerating per requested item what landed and what did not, and — on
# repeated non-convergence — escalates to a human.
#
# Fail-open: when the diff cannot be computed (no base SHA, shallow clone, fork
# weirdness) it treats the change as substantive so a genuine fix is never
# wrongly downgraded — the guard only downgrades on positive evidence of a
# non-fix.
finalize_review_application() {
  local intent="$1"
  # Dry-run has no worktree diff to assess — preserve the prior announcement.
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    post_reviews_terminal "$intent" "applied" "Changes committed and pushed."
    return 0
  fi

  local pre_sha="${HEAD_SHA:-}" cur_sha
  cur_sha="$(git rev-parse HEAD 2>/dev/null || true)"

  local substantive="true" changed_regions="" named_regions verdict
  if [ -n "$pre_sha" ] && [ -n "$cur_sha" ] \
     && git rev-parse --verify --quiet "${pre_sha}^{commit}" >/dev/null 2>&1; then
    if [ -z "$(git diff -w --name-only "$pre_sha" "$cur_sha" 2>/dev/null)" ]; then
      substantive="false"
    fi
    changed_regions="$(git diff --unified=0 "$pre_sha" "$cur_sha" 2>/dev/null | rce_parse_hunks)"
  fi
  named_regions="$(rce_named_regions "${OPEN_THREADS_JSON:-[]}")"
  verdict="$(rce_classify "$substantive" "$named_regions" "$changed_regions")"

  local enumerated=""
  [ -n "$named_regions" ] && enumerated="$(rce_enumerate "$named_regions" "$changed_regions")"

  case "$verdict" in
    applied)
      clear_not_applied_markers "$intent" || return 1
      local summary="Changes committed and pushed."
      [ -n "$enumerated" ] && summary="Changes committed and pushed. Requested items addressed:
${enumerated}"
      post_reviews_terminal "$intent" "applied" "$summary"
      ;;
    partial)
      # Progress was made (some named region was touched), so the run of
      # consecutive zero-progress passes is broken — reset the not-applied
      # counter so old cycles cannot trigger premature escalation (#1567).
      clear_not_applied_markers "$intent" || return 1
      # The requested changes are not fully applied — do not let this pass become
      # auto-mergeable.
      _REVIEW_INCOMPLETE=1
      local summary="A commit was pushed, but **not every requested change was applied**. Per requested item:
${enumerated}

The unaddressed items above still need work."
      post_reviews_terminal "$intent" "partial" "$summary"
      ;;
    *)  # not-applied
      # The requested changes were not applied — do not let this pass become
      # auto-mergeable, even before the escalation limit is reached.
      _REVIEW_INCOMPLETE=1
      local summary
      if [ "$substantive" = "false" ]; then
        summary="A commit was pushed, but it made **no substantive change** (whitespace/cosmetic only) — the requested review changes were not applied."
      elif [ -n "$enumerated" ]; then
        summary="A commit was pushed, but it **did not touch any region the review named** — the requested changes were not applied. Per requested item:
${enumerated}"
      else
        summary="A commit was pushed, but there is no evidence it addressed the requested review changes."
      fi
      post_reviews_terminal "$intent" "not-applied" "$summary"
      # AC #4: escalate to a human once non-convergence reaches the limit. The
      # marker for this pass is already posted, so it is included in the count.
      local nonconverged
      nonconverged="$(count_not_applied_markers "$intent")"
      if [ "${nonconverged:-0}" -ge "${REVIEW_NONCONVERGENCE_LIMIT:-3}" ]; then
        echo "::warning::review-changes non-convergence: ${nonconverged} consecutive not-applied passes for intent=${intent} on PR #${PR_NUMBER} — escalating to a human"
        escalate_review_nonconvergence "$intent" "$nonconverged"
      fi
      ;;
  esac
}

# resolution_gate_open <cp_rc> — the #1617 gate that wires the pure #1609
# head-movement predicate (ri_may_resolve) into the resolve_* review-thread nets.
# A dev-lead fix pass may auto-resolve review threads ONLY when it advanced the PR
# head; a pass that produced no commit resolves zero threads. This closes the #1024
# vector where a no-commit pass resolved 18 threads (incl. a Critical finding) purely
# on reply markers. Returns 0 (gate open — resolution permitted) / non-zero (closed).
#
# - Dry-run passes through so the announce-only nets keep announcing what they would
#   resolve — that existing behaviour and its tests are preserved.
# - Otherwise compares the immutable pre-pass RESOLUTION_BASE_SHA (snapshotted right
#   after the worktree checkout, before any work) against the post-pass
#   `git rev-parse HEAD` via ri_may_resolve (fail-closed: an empty or unchanged SHA
#   closes the gate). RESOLUTION_BASE_SHA — not HEAD_SHA — is used deliberately:
#   HEAD_SHA is the event-time value and is reassigned by try_enable_auto_merge, so
#   gating on it could open on a no-commit pass whose checkout drifted from the event.
# - Falls back to cp_rc == 0 ONLY when a SHA is genuinely unavailable (base snapshot
#   unset or `git rev-parse HEAD` unresolvable), so a pass that legitimately pushed a
#   commit is never wrongly gated shut just because the runner cannot report a SHA.
# post_resolve_failed_marker <intent> <cp_rc>: posts the resolve-failed retry marker
# keyed to the PR's CURRENT head (#2045). dev-lead-retry.sh scans only markers on
# the current head, and after a successful push (cp_rc 0) HEAD_SHA still holds the
# pre-pass head until try_enable_auto_merge refreshes it, so a marker keyed to it
# would never be retried.
post_resolve_failed_marker() {
  local intent="$1" cp_rc="${2:-1}"
  local HEAD_SHA="${HEAD_SHA:-}" pushed_head
  if [ "$cp_rc" -eq 0 ]; then
    pushed_head=$(git rev-parse HEAD 2>/dev/null || true)
    [ -n "$pushed_head" ] && HEAD_SHA="$pushed_head"
  fi
  post_reviews_rate_limited "$intent" "resolve-failed"
}

resolution_gate_open() {
  local cp_rc="${1:-1}"
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    return 0
  fi
  local pre_sha="${RESOLUTION_BASE_SHA:-}" cur_sha
  cur_sha="$(git rev-parse HEAD 2>/dev/null || true)"
  if [ -z "$pre_sha" ] || [ -z "$cur_sha" ]; then
    return "$cp_rc"
  fi
  ri_may_resolve "$pre_sha" "$cur_sha"
}

case "$INTENT_TYPE" in
  fix-reviews)
    # Get open review threads
    export PR_NUMBER PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    export REPO HEAD_SHA
    export BASE_REF="${BASE_REF:-main}"
    # Normalise to GraphQL's author.login form: the GitHub Actions event login
    # includes a "[bot]" suffix for bots, but GraphQL author.login omits it.
    # Without this, the prompt's `author.login == ${TRIGGERING_REVIEWER}` check
    # never matches threads from coderabbitai/chatgpt-codex/etc.
    export TRIGGERING_REVIEWER="${TRIGGERING_REVIEWER:-}"
    TRIGGERING_REVIEWER="${TRIGGERING_REVIEWER%\[bot\]}"
    # resolve_actor_outdated_threads needs ACTOR (the raw GitHub Actions login,
    # with the [bot] suffix preserved — the helper strips it for the GraphQL
    # comparison). The workflow passes the actor via TRIGGERING_REVIEWER, so
    # fall back to it when ACTOR is not set explicitly.
    export ACTOR="${ACTOR:-${TRIGGERING_REVIEWER:-}}"
    # Paginated + fail-closed (#2056): an unreadable thread list is an error, never
    # an empty "nothing to address" list.
    OPEN_THREADS_JSON=$(ort_fetch_open_threads "$REPO" "$PR_NUMBER") || {
      echo "::error::fix-reviews: could not read open review threads for PR #${PR_NUMBER} — aborting rather than treating them as empty (#2056)"
      exit 1
    }
    # Deliberately NOT exported (see build_and_run): unbounded payload.
    export -n OPEN_THREADS_JSON  # an inherited export would carry the payload into every exec
    fetch_pr_context
    rc=0
    build_and_run "fix-reviews" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "fix-reviews"
    if [ "$rc" -eq 0 ]; then
      cp_rc=0
      commit_and_push "fix-reviews" || cp_rc=$?
      # Retract every claim reply this pass posted whose commit did not land on the
      # remote head — no commit, a guard abort, or a stale pre-pass SHA (#2013).
      retract_unlanded_claims "fix-reviews" "$([ "$cp_rc" -eq 0 ] && echo ok || echo failed)" || { [ "$cp_rc" -ne 0 ] || cp_rc=1; }
      # Minimize PR issue comments dev-lead has dispositioned + verified (#1813).
      # Deliberately OUTSIDE the review-thread resolution gate: each disposition is
      # verified on its own terms (a `fixed` sha must be on head; out-of-scope needs
      # a tracking issue; invalid/answered/informational need a non-empty evidence
      # reply), so an answered/invalid disposition requires no head advance. Runs on
      # every successful pass, including a net-zero one where the model only replied.
      # Runs BEFORE the terminal marker (#2037): if a comment could not be
      # unminimized, post_reviews_terminal downgrades applied/no-changes to partial.
      if [ "$cp_rc" -eq 4 ]; then
        resolve_dispositioned_comments "fix-reviews" failed || _DISPOSITIONS_UNRESOLVED=1
      else
        resolve_dispositioned_comments "fix-reviews" || _DISPOSITIONS_UNRESOLVED=1
      fi
      # Deferred bot threads (#2045) resolve BEFORE any terminal marker is posted: a
      # failed resolution must leave no `applied`/`no-changes` terminal, because
      # dev-lead-retry.sh skips an intent+SHA that has one and the thread would stay
      # merge-blocking forever. They are verified against their tracking issue, not
      # the diff, so they run outside the head-advance gate and on guard aborts too.
      deferred_rc=0
      resolve_deferred_bot_threads "fix-reviews" || deferred_rc=1
      if [ "$deferred_rc" -ne 0 ]; then
        rc=1
        echo "::warning::fix-reviews: a verified deferral could not be resolved — withholding the terminal marker so the pass is retried"
        # Not fully applied: never let this pass become auto-mergeable (#1567), and
        # drop the EXIT-trap restore so auto-merge held off at the start stays off.
        _REVIEW_INCOMPLETE=1
        _AM_NEEDS_RESTORE=0
        # dev-lead-retry.sh re-dispatches only on a retry marker; a merely absent
        # terminal is never retried. Guard aborts (3/4) are flagged for a human.
        if [ "$cp_rc" -ne 3 ] && [ "$cp_rc" -ne 4 ]; then
          post_resolve_failed_marker "fix-reviews" "$cp_rc"
        fi
      fi
      if [ "$cp_rc" -eq 0 ]; then
        notify_coderabbit_resolve
        if [ "$deferred_rc" -eq 0 ]; then
          finalize_review_application "fix-reviews" || {
            echo "::warning::fix-reviews: finalize_review_application failed — posting retry marker"
            post_resolve_failed_marker "fix-reviews" "$cp_rc"
            rc=1
          }
        fi
      elif [ "$cp_rc" -eq 3 ]; then
        # No-op guard (#1340): the fix nets base…head to zero — already flagged
        # for a human, auto-merge disabled. Post no applied/no-changes/retry
        # marker and do not re-enable auto-merge or resolve threads.
        echo "::warning::fix-reviews produced a net-zero diff — flagged for human, not pushed (#1340)"
      elif [ "$cp_rc" -eq 4 ]; then
        echo "::warning::fix-reviews was refused by a push guard (test tamper/regression or sync-stub) — flagged for human, not pushed (#2013/#2185)"
      else
        notify_coderabbit_resolve
        if has_hard_blockers; then
          echo "::warning::Tier-1 blockers still present ($(blocking_reason_phrase)) — posting retry marker with backoff"
          post_reviews_rate_limited "fix-reviews" "blocked"
        elif has_tier1_blockers; then
          echo "::notice::Unresolved bot review threads remain — not posting no-changes terminal to allow future retries"
        elif [ "$deferred_rc" -eq 0 ]; then
          post_no_changes "fix-reviews"
        fi
      fi
      if [ "$cp_rc" -ne 3 ] && [ "$cp_rc" -ne 4 ]; then
        # Resolution gate (#1617): auto-resolve threads only when this pass advanced
        # the PR head. A no-commit pass resolves zero threads (#1609/#1024).
        if resolution_gate_open "$cp_rc"; then
          resolve_bot_outdated_threads "fix-reviews"
          resolve_actor_outdated_threads "fix-reviews"
          # Resolve bot threads dev-lead addressed in-thread but left open (#1547) —
          # these are not necessarily outdated, so the nets above miss them.
          resolve_addressed_bot_threads "fix-reviews" || rc=1
        else
          echo "::notice::resolution gate closed (#1609): the fix-reviews pass did not advance PR #${PR_NUMBER}'s head — zero review threads resolved"
        fi
        # Never auto-merge an escalated or not-fully-applied review pass (#1567),
        # nor one that left a comment RESOLVED it failed to re-open (#2037).
        if [ "${_REVIEW_ESCALATED:-0}" -ne 1 ] && [ "${_REVIEW_INCOMPLETE:-0}" -ne 1 ] \
           && [ "${_DISPOSITIONS_UNRESOLVED:-0}" -ne 1 ]; then
          try_enable_auto_merge
        fi
      fi
      # #2037: the pass ends failed so it is visibly not done. Also drop the EXIT-trap
      # auto-merge restore, or it would re-enable merge over a RESOLVED comment.
      if [ "${_DISPOSITIONS_UNRESOLVED:-0}" -eq 1 ]; then
        _AM_NEEDS_RESTORE=0
        rc=1
      fi
    else
      # Don't orphan dispositions on a failed/timed-out pass (#1992). The engine
      # may have posted disposition replies and then errored or hit the writer-tier
      # timeout (exit 124) before commit_and_push ran. Each disposition is verified
      # on its own terms, and the "failed" flag makes the resolver refuse every
      # `fixed` disposition here (an engine-made local commit may never have been
      # pushed), while an invalid/answered/informational/out-of-scope with
      # evidence still clears.
      # (A hard action-budget SIGKILL that kills the process mid-step can't be
      # recovered in-process — but the next pass self-heals via the idempotent
      # posting + duplicate recovery above.)
      resolve_dispositioned_comments "fix-reviews" failed \
        || echo "::warning::resolve_dispositioned_comments failed on a failed fix-reviews pass — keeping the pass's exit code ${rc} (#2037)"
      # Nothing was pushed on a failed pass: retract its claim replies (#2013).
      retract_unlanded_claims "fix-reviews" failed || true
      # A deferral is verified against its tracking issue, not a commit, so it can
      # clear even when the engine failed after posting it. A failed pass posts no
      # marker and the bot-thread retry skips replied threads, so a resolver failure
      # here needs its own retry marker (the pass keeps its exit code).
      resolve_deferred_bot_threads "fix-reviews" || post_resolve_failed_marker "fix-reviews" 1 || true
    fi
    exit "$rc"
    ;;
  fix-bot-comment)
    export PR_NUMBER PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    export REPO ACTOR="${ACTOR:-}" COMMENT_BODY="${COMMENT_BODY:-}" COMMENT_NODE_ID="${COMMENT_NODE_ID:-}" HEAD_SHA
    export COMMENT_VERSION="${COMMENT_VERSION:-}"
    fetch_pr_context
    rc=0
    build_and_run "fix-bot-comment" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "fix-bot-comment"
    if [ "$rc" -eq 0 ]; then
      cp_rc=0
      # The terminal marker reads as "this pass ENDED on the comment" to the
      # bot-comment retry (#2017), so it is posted only AFTER the disposition
      # resolver below has run: a pass cancelled (or a resolver that dies) before
      # then leaves no marker, and the retry re-dispatches instead of stalling.
      _fbc_terminal=""
      commit_and_push "fix-bot-comment" || cp_rc=$?
      # Retract every claim reply this pass posted whose commit did not land on the
      # remote head — no commit, a guard abort, or a stale pre-pass SHA (#2013).
      retract_unlanded_claims "fix-bot-comment" "$([ "$cp_rc" -eq 0 ] && echo ok || echo failed)" || { [ "$cp_rc" -ne 0 ] || cp_rc=1; }
      # Minimize PR issue comments dev-lead has dispositioned + verified (#1813).
      # Outside the review-thread resolution gate for the same reason as fix-reviews:
      # each disposition is independently verified, so a non-`fixed` disposition
      # needs no head advance. Runs on every successful pass, net-zero included.
      # Runs BEFORE the terminal marker (#2037) — see fix-reviews above.
      if [ "$cp_rc" -eq 4 ]; then
        resolve_dispositioned_comments "fix-bot-comment" failed || _DISPOSITIONS_UNRESOLVED=1
      else
        resolve_dispositioned_comments "fix-bot-comment" || _DISPOSITIONS_UNRESOLVED=1
      fi
      if [ "$cp_rc" -eq 0 ]; then
        notify_coderabbit_resolve
        _fbc_terminal="applied"
      elif [ "$cp_rc" -eq 3 ]; then
        # No-op guard (#1340): the fix nets base…head to zero — already flagged
        # for a human, auto-merge disabled. Post no terminal marker and do not
        # re-enable auto-merge or resolve threads.
        echo "::warning::fix-bot-comment produced a net-zero diff — flagged for human, not pushed (#1340)"
      elif [ "$cp_rc" -eq 4 ]; then
        echo "::warning::fix-bot-comment was refused by a push guard (test tamper/regression or sync-stub) — flagged for human, not pushed (#2013/#2185)"
      else
        notify_coderabbit_resolve
        if has_hard_blockers; then
          echo "::warning::Tier-1 blockers still present ($(blocking_reason_phrase)) — recording no-changes; the terminal marker posts only if the comment ends RESOLVED, otherwise the #2017 scan retries it"
        elif has_tier1_blockers; then
          echo "::warning::Unresolved bot review threads remain — recording no-changes; the terminal marker posts only if the comment ends RESOLVED, otherwise the #2017 scan retries it"
        fi
        _fbc_terminal="no-changes"
      fi
      if [ "${RDC_STATE_UNKNOWN:-0}" = "1" ]; then
        echo "::warning::fix-bot-comment: a comment's current state could not be confirmed — withholding the terminal marker so the bot-comment retry can re-dispatch (#2017)"
        _fbc_terminal=""
      elif [ -n "$_fbc_terminal" ] && [ -n "${COMMENT_NODE_ID:-}" ] && [ "${DEV_LEAD_DRY_RUN:-false}" != "true" ]; then
        _fbc_resolved=$(fbc_target_resolved)
        if [ "$_fbc_resolved" != "yes" ]; then
          echo "::warning::fix-bot-comment: comment ${COMMENT_NODE_ID} has no verified disposition after this pass (state: ${_fbc_resolved}) — withholding the terminal marker so the bot-comment retry can re-dispatch within its attempt limits (#2017)"
          _fbc_terminal=""
        fi
      fi
      # Deferred bot threads (#2045): verified against the tracking issue, so outside
      # the head-advance gate below and run on guard aborts (rc 3/4) too. Resolved
      # BEFORE the terminal marker so a failure leaves no terminal that would stop
      # dev-lead-retry.sh from retrying this intent+SHA.
      if ! resolve_deferred_bot_threads "fix-bot-comment"; then
        rc=1
        echo "::warning::fix-bot-comment: a verified deferral could not be resolved — withholding the terminal marker so the pass is retried"
        _fbc_terminal=""
        _REVIEW_INCOMPLETE=1
        _AM_NEEDS_RESTORE=0
        # The bot-comment retry selects only undispositioned comments and the
        # bot-thread retry only unreplied threads, so neither re-runs this resolver.
        # Hand it to a PR-wide fix-reviews retry. Guard aborts (3/4) are flagged for a human.
        if [ "$cp_rc" -ne 3 ] && [ "$cp_rc" -ne 4 ]; then
          post_resolve_failed_marker "fix-reviews" "$cp_rc"
        fi
      fi
      case "$_fbc_terminal" in
        applied)    post_reviews_terminal "fix-bot-comment" "applied" "Changes committed and pushed." ;;
        no-changes) post_no_changes "fix-bot-comment" ;;
      esac
      if [ "$cp_rc" -ne 3 ] && [ "$cp_rc" -ne 4 ]; then
        # Resolution gate (#1617): auto-resolve threads only when this pass advanced
        # the PR head. A no-commit pass resolves zero threads (#1609/#1024).
        if resolution_gate_open "$cp_rc"; then
          resolve_bot_outdated_threads "fix-bot-comment"
          resolve_actor_outdated_threads "fix-bot-comment"
          # Resolve bot threads dev-lead addressed in-thread but left open (#1547) —
          # these are not necessarily outdated, so the nets above miss them.
          resolve_addressed_bot_threads "fix-bot-comment" || rc=1
        else
          echo "::notice::resolution gate closed (#1609): the fix-bot-comment pass did not advance PR #${PR_NUMBER}'s head — zero review threads resolved"
        fi
        { [ "${_DISPOSITIONS_UNRESOLVED:-0}" -eq 1 ] || [ "${_REVIEW_INCOMPLETE:-0}" -eq 1 ]; } || try_enable_auto_merge
      fi
      # #2037: the pass ends failed so it is visibly not done; no auto-merge restore.
      if [ "${_DISPOSITIONS_UNRESOLVED:-0}" -eq 1 ]; then
        _AM_NEEDS_RESTORE=0
        rc=1
      fi
    else
      # Don't orphan dispositions on a failed/timed-out pass (#1992) — see the
      # fix-reviews failure branch above for why running the resolver here is safe.
      resolve_dispositioned_comments "fix-bot-comment" failed \
        || echo "::warning::resolve_dispositioned_comments failed on a failed fix-bot-comment pass — keeping the pass's exit code ${rc} (#2037)"
      # Nothing was pushed on a failed pass: retract its claim replies (#2013).
      retract_unlanded_claims "fix-bot-comment" failed || true
      resolve_deferred_bot_threads "fix-bot-comment" || post_resolve_failed_marker "fix-reviews" 1 || true
    fi
    exit "$rc"
    ;;
  on-mention)
    export PR_NUMBER="${PR_NUMBER:-}"
    export PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    export REPO ACTOR="${ACTOR:-}" USER_INSTRUCTION="${USER_INSTRUCTION:-}" PR_DESCRIPTION="${PR_DESCRIPTION:-}"
    rc=0
    build_and_run "on-mention" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "on-mention"
    if [ "$rc" -eq 0 ]; then
      cp_rc=0
      commit_and_push "on-mention" || cp_rc=$?
      if [ "$cp_rc" -eq 3 ]; then
        # Net-zero abort: flag_noop_pr already flagged for human and disabled
        # auto-merge. Do not re-enable it or claim changes were applied (#1786).
        echo "::notice::on-mention: no-op guard aborted the push for PR #${PR_NUMBER} — flagged for human, not merged (#1786)"
        exit "$rc"
      fi
      if [ "$cp_rc" -eq 0 ]; then
        post_reviews_terminal "on-mention" "applied" "Changes committed and pushed."
      else
        post_reviews_terminal "on-mention" "no-changes" "Engine ran but made no changes."
      fi
      # Enable auto-merge by default when the mention targets a PR (issue mentions
      # carry no PR_NUMBER and are skipped). GitHub holds the merge until branch
      # protection is satisfied.
      [[ -n "${PR_NUMBER:-}" ]] && try_enable_auto_merge
    fi
    exit "$rc"
    ;;
  human-pr|review-changes)
    export PR_NUMBER="${PR_NUMBER:-}"
    export PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    # ACTOR is exported so resolve_actor_outdated_threads can scrub outdated
    # threads from the triggering reviewer in the no-changes branch. The
    # workflow's review-changes step passes ACTOR via env.INTENT_ACTOR.
    export REPO ACTOR="${ACTOR:-}" PR_TITLE="${PR_TITLE:-}" PR_DESCRIPTION="${PR_DESCRIPTION:-}"
    # Paginated + fail-closed (#2056): an unreadable thread list is an error, never
    # an empty "nothing to address" list.
    OPEN_THREADS_JSON=$(ort_fetch_open_threads "$REPO" "$PR_NUMBER") || {
      echo "::error::review-changes: could not read open review threads for PR #${PR_NUMBER} — aborting rather than treating them as empty (#2056)"
      exit 1
    }
    # OPEN_THREADS_JSON deliberately NOT exported (see build_and_run): unbounded payload.
    export -n OPEN_THREADS_JSON  # an inherited export would carry the payload into every exec
    export BASE_REF="${BASE_REF:-main}"
    fetch_pr_context
    rc=0
    build_and_run "review-changes" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "review-changes"
    if [ "$rc" -eq 0 ]; then
      cp_rc=0
      commit_and_push "review-changes" || cp_rc=$?
      # Retract every claim reply this pass posted whose commit did not land on the
      # remote head — no commit, a guard abort, or a stale pre-pass SHA (#2013).
      retract_unlanded_claims "review-changes" "$([ "$cp_rc" -eq 0 ] && echo ok || echo failed)" || { [ "$cp_rc" -ne 0 ] || cp_rc=1; }
      # No-op guard (#1786): a review-changes pass whose net diff to base is empty
      # was already flagged by flag_noop_pr (needs-human label + auto-merge
      # disabled + suppressed EXIT-trap restore). Stop here — never resolve threads
      # or re-enable auto-merge on a self-cancelling PR.
      if [ "$cp_rc" -eq 3 ]; then
        echo "::notice::review-changes: no-op guard aborted the push for PR #${PR_NUMBER} — flagged for human, not merged (#1786)"
        # A deferral is verified against its tracking issue, not the diff (#2045).
        resolve_deferred_bot_threads "review-changes" || rc=1
        exit "$rc"
      fi
      # Test guards (#2013): the push was refused and the PR flagged for a human.
      # Nothing landed, so a `fixed` disposition would cite a local-only commit; no
      # thread resolves and auto-merge stays off.
      if [ "$cp_rc" -eq 4 ]; then
        echo "::warning::review-changes was refused by a test guard (tamper/regression) — flagged for human, not pushed (#2013)"
        resolve_dispositioned_comments "review-changes" failed || _DISPOSITIONS_UNRESOLVED=1
        resolve_deferred_bot_threads "review-changes" || rc=1
        [ "${_DISPOSITIONS_UNRESOLVED:-0}" -eq 1 ] && rc=1
        exit "$rc"
      fi
      # Minimize PR issue comments dev-lead has dispositioned + verified (#1813) —
      # independently verified, so outside the head-movement resolution gate.
      # Runs BEFORE the terminal marker (#2037) — see fix-reviews above.
      resolve_dispositioned_comments "review-changes" || _DISPOSITIONS_UNRESOLVED=1
      # Deferred bot threads (#2045): verified against the tracking issue, so outside
      # the head-advance gate below. Resolved BEFORE any terminal marker so a failure
      # leaves none (dev-lead-retry.sh skips an intent+SHA that has one).
      deferred_rc=0
      resolve_deferred_bot_threads "review-changes" || deferred_rc=1
      if [ "$deferred_rc" -ne 0 ]; then
        rc=1
        echo "::warning::review-changes: a verified deferral could not be resolved — withholding the terminal marker so the pass is retried"
        # Not fully applied: never let this pass become auto-mergeable (#1567), and
        # drop the EXIT-trap restore so auto-merge held off at the start stays off.
        _REVIEW_INCOMPLETE=1
        _AM_NEEDS_RESTORE=0
        # dev-lead-retry.sh re-dispatches only on a retry marker; a merely absent
        # terminal is never retried.
        post_resolve_failed_marker "review-changes" "$cp_rc"
      fi
      if [ "$cp_rc" -eq 0 ]; then
        notify_coderabbit_resolve
        if [ "$deferred_rc" -eq 0 ]; then
          finalize_review_application "review-changes" || {
            echo "::warning::review-changes: finalize_review_application failed — posting retry marker"
            post_resolve_failed_marker "review-changes" "$cp_rc"
            rc=1
          }
        fi
      else
        notify_coderabbit_resolve
        if has_hard_blockers; then
          echo "::warning::Tier-1 blockers still present ($(blocking_reason_phrase)) — posting retry marker with backoff"
          post_reviews_rate_limited "review-changes" "blocked"
        elif has_tier1_blockers; then
          echo "::notice::Unresolved bot review threads remain — not posting no-changes terminal to allow future retries"
        elif [ "$deferred_rc" -eq 0 ]; then
          post_reviews_terminal "review-changes" "no-changes" "No changes were needed for this PR."
        fi
      fi
      # Resolution gate (#1617): auto-resolve threads only when this pass advanced
      # the PR head. A no-commit pass resolves zero threads (#1609/#1024).
      if resolution_gate_open "$cp_rc"; then
        resolve_bot_outdated_threads "review-changes"
        resolve_actor_outdated_threads "review-changes"
        # Resolve bot threads dev-lead addressed in-thread but left open (#1547) —
        # these are not necessarily outdated, so the nets above miss them.
        resolve_addressed_bot_threads "review-changes" || rc=1
      else
        echo "::notice::resolution gate closed (#1609): the review-changes pass did not advance PR #${PR_NUMBER}'s head — zero review threads resolved"
      fi
      # Never auto-merge an escalated or not-fully-applied review pass (#1567),
      # nor one that left a comment RESOLVED it failed to re-open (#2037).
      if [ "${_REVIEW_ESCALATED:-0}" -ne 1 ] && [ "${_REVIEW_INCOMPLETE:-0}" -ne 1 ] \
         && [ "${_DISPOSITIONS_UNRESOLVED:-0}" -ne 1 ]; then
        try_enable_auto_merge
      fi
      # #2037: the pass ends failed so it is visibly not done; no auto-merge restore.
      if [ "${_DISPOSITIONS_UNRESOLVED:-0}" -eq 1 ]; then
        _AM_NEEDS_RESTORE=0
        rc=1
      fi
    else
      # Don't orphan dispositions on a failed/timed-out pass (#1992) — see the
      # fix-reviews failure branch above for why running the resolver here is safe.
      resolve_dispositioned_comments "review-changes" failed \
        || echo "::warning::resolve_dispositioned_comments failed on a failed review-changes pass — keeping the pass's exit code ${rc} (#2037)"
      # A deferral is independently verifiable even when the pass failed (#2045).
      resolve_deferred_bot_threads "review-changes" || post_resolve_failed_marker "review-changes" 1 || true
      # Nothing was pushed on a failed pass: retract its claim replies (#2013).
      retract_unlanded_claims "review-changes" failed || true
    fi
    exit "$rc"
    ;;
  rebase)
    export PR_NUMBER="${PR_NUMBER:-}"
    export PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    export REPO BASE_REF="${BASE_REF:-main}" HEAD_REF="${HEAD_REF:-}" CONFLICTING_FILES="${CONFLICTING_FILES:-}"
    if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
      echo "[dry-run] would run rebase for PR $PR_NUMBER"
      exit 0
    fi
    if [ -z "$PR_NUMBER" ]; then
      echo "::error::PR_NUMBER is required for rebase"
      exit 1
    fi
    # Per-PR exhaustion guard (#865): a stuck conflict must not generate repeated
    # full-timeout runs from auto-rebase-conflict sentinel re-fires. If this PR's
    # rebase is already exhausted, skip cleanly before invoking the engine.
    rebase_exhausted_rc=0
    rebase_pr_is_exhausted || rebase_exhausted_rc=$?
    if [ "$rebase_exhausted_rc" -eq 0 ]; then
      echo "::notice::PR #${PR_NUMBER} rebase is exhausted — skipping (sentinel re-fire guard, #865)"
      exit 0
    elif [ "$rebase_exhausted_rc" -eq 2 ]; then
      # Retrieval fault: we cannot confirm the exhaustion marker is absent, so fail
      # closed — do not invoke the engine on unknown state. Exit nonzero so the
      # retry cron re-dispatches once the transient gh-api/jq fault clears.
      echo "::error::could not retrieve PR #${PR_NUMBER} comments to check rebase exhaustion — failing closed, not invoking engine (#865)"
      exit 1
    fi
    # Full history before anything reads it (#2053). The checkout is depth-1, so
    # the branch and base look unrelated until history is deepened; doing it here
    # makes the conflict list and the engine's rebase see the real merge base,
    # instead of depending on the model to un-shallow. If history cannot be
    # deepened, that is an infrastructure failure: say so, and record it with a
    # status that is NOT `failed`, so it never counts toward the #865 limit.
    history_rc=0
    history_msg=$(git_ensure_merge_base "$BASE_REF" "$HEAD_REF") || history_rc=$?
    if [ "$history_rc" -eq 2 ]; then
      echo "::error::rebase: ${history_msg} — infrastructure failure, not a conflict; not counted toward the rebase exhaustion limit (#2053)"
      git merge --abort >/dev/null 2>&1 || true
      git rebase --abort >/dev/null 2>&1 || true
      post_reviews_terminal "rebase" "history-unavailable" "Automated rebase did not run: ${history_msg}. This is an infrastructure failure, not a merge conflict, and it does not count toward the rebase exhaustion limit. The next rebase trigger will retry."
      exit 1
    elif [ "$history_rc" -eq 1 ]; then
      # Genuinely unrelated histories are not a resolvable conflict: abort before
      # conflict detection or the engine, with a terminal marker that is not
      # `failed` so it does not count toward the #865 exhaustion limit.
      echo "::error::rebase: history is complete but HEAD shares no merge base with origin/${BASE_REF} — the histories are genuinely unrelated; aborting (#2053)"
      git merge --abort >/dev/null 2>&1 || true
      git rebase --abort >/dev/null 2>&1 || true
      post_reviews_terminal "rebase" "unrelated-histories" "Automated rebase did not run: this branch shares no common ancestor with \`${BASE_REF}\` (unrelated histories), so there is nothing to rebase or resolve. Please recreate the branch from \`${BASE_REF}\` or rebase it manually. This does not count toward the rebase exhaustion limit."
      exit 1
    fi
    CONFLICTING_FILES=$(detect_conflicting_paths "$BASE_REF")
    export CONFLICTING_FILES
    # Up-front large-conflict guard (#865): a conflict spanning more files than
    # the engine can resolve within the writer-tier timeout is aborted cleanly
    # here, rather than handed to the engine and left to run to the per-tier
    # timeout (surfacing as exit 124).
    rebase_conflict_file_count=$(printf '%s\n' "$CONFLICTING_FILES" | grep -c . || true)
    if rebase_conflict_too_large "${rebase_conflict_file_count:-0}" "$REBASE_MAX_CONFLICT_FILES"; then
      echo "::warning::rebase conflict spans ${rebase_conflict_file_count} files (> ${REBASE_MAX_CONFLICT_FILES}) — too large for automated resolution; aborting cleanly (#865)"
      handle_rebase_failure "Conflict too large for automated resolution: ${rebase_conflict_file_count} files conflict against \`${BASE_REF}\` (limit ${REBASE_MAX_CONFLICT_FILES}). Please rebase manually."
      exit 1
    fi
    # Capture the branch tip *before* the resolution so the integrity check can
    # use it as one parent (the base ref is the other) when scanning the resolved
    # tree for introduced duplicate declarations (#1482).
    PRE_RESOLVE_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
    rc=0
    build_and_run "rebase" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "rebase"
    # A per-tier timeout (exit 124) or a hard engine failure means the conflict
    # was not resolved. Convert it into a clean terminal abort with a comment —
    # never a bare process-killed exit 124 (#865) — and count it toward the
    # per-PR exhaustion threshold. (rc==2 already exited via handle_rate_limit.)
    if [ "$rc" -ne 0 ]; then
      handle_rebase_failure "$(rebase_failure_reason "$rc")"
      exit 1
    fi
    if [ "$rc" -eq 0 ]; then
      # Advisory post-resolution integrity check (#1482): flag, do not block.
      # `|| true` guarantees a detector fault can never fail a real resolution.
      run_post_resolution_integrity_check "$BASE_REF" "${PRE_RESOLVE_SHA:-}" || true
      # No-op guard (#1786): a rebase / merge-from-main can ERASE the PR's own
      # changes, netting the base…head diff to zero. The rebase prompt has the
      # engine force-push the rebased branch itself, so we cannot un-push — but we
      # must never report it "applied" (which would let it merge and auto-close its
      # Closes #N issue with nothing fixed). Re-check the already-rebased HEAD and,
      # if it nets to zero, flag for a human instead of reporting success.
      git fetch origin "$BASE_REF" >/dev/null 2>&1 || true
      if pr_nets_to_zero "$BASE_REF"; then
        echo "::error::No-op guard: PR #${PR_NUMBER} nets to zero changed files against ${BASE_REF} after rebase — flagging for human, not reporting applied (#1786)"
        flag_noop_pr "rebase"
        exit "$rc"
      fi
      cp_rc=0
      commit_and_push "rebase" || cp_rc=$?
      if [ "$cp_rc" -eq 3 ]; then
        # commit_and_push committed a script-side change that nets to zero and
        # already flagged it. Stop — never report a self-cancelling rebase applied.
        echo "::notice::rebase: no-op guard aborted the push for PR #${PR_NUMBER} — flagged for human, not merged (#1786)"
        exit "$rc"
      fi
      # Post-resolution integrity gate (#1890 AC #7): a corrupted resolution
      # (#1482/#1485) must never be reported applied and allowed to merge. Escalate
      # to a human immediately — corruption is not something to retry.
      if ! verify_resolution_integrity "$BASE_REF"; then
        echo "::error::rebase: post-resolution integrity gate failed for PR #${PR_NUMBER} — not reporting applied; escalating to a human (#1890 AC #7)"
        escalate_rebase_needs_human "Post-conflict-resolution integrity check failed (\`bash -n\` / \`shellcheck\` / \`check-duplicate-decls.sh\`). A bad conflict resolution has corrupted trunk before (#1485), so this branch is held for a human rather than reported resolved."
        exit 1
      fi
      # Assert the REAL post-condition (#1890 AC #2). The engine exit code and the
      # local trial-merge both lied here: a locally-clean merge that GitHub still
      # reports CONFLICTING let a run post `status=applied` in seconds while
      # resolving nothing, so the #865 exhaustion counter never advanced and the
      # sentinel re-fired ~15×. Trust only GitHub's computed mergeable state.
      case "$(pr_mergeable_conflict_state)" in
        resolved)
          post_reviews_terminal "rebase" "applied" "Rebase completed and pushed; PR is no longer conflicting."
          ;;
        conflicting)
          # A run that did not change the state reports FAILURE, which counts
          # toward the #865 per-PR exhaustion threshold and eventually escalates.
          echo "::error::rebase: engine run for PR #${PR_NUMBER} completed but GitHub still reports it CONFLICTING — recording a failure, not success (#1890 AC #2)"
          handle_rebase_failure "The engine run completed but PR #${PR_NUMBER} is still CONFLICTING per GitHub's mergeable state — the rebase did not converge. Recorded as a failure so repeated no-op 'success' runs can no longer accumulate."
          exit 1
          ;;
        *)
          # Indeterminate: GitHub has not finished computing mergeability. Do not
          # claim success (would let a still-conflicting PR merge) and do not record
          # a failure (would be premature); exit non-zero so the retry path re-checks.
          echo "::warning::rebase: GitHub has not finished computing PR #${PR_NUMBER} mergeability (indeterminate) — not claiming success; the retry path will re-check (#1890 AC #2)"
          exit 1
          ;;
      esac
    fi
    exit "$rc"
    ;;
  enable-auto-merge)
    if [ -z "$PR_NUMBER" ]; then
      echo "::error::PR_NUMBER is required for enable-auto-merge"
      exit 1
    fi
    try_enable_auto_merge "true"
    ;;
  *)
    echo "::error::Unknown intent type: $INTENT_TYPE"
    exit 1
    ;;
esac
