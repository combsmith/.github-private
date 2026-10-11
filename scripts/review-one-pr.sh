#!/usr/bin/env bash
# Run the cascading PR review against ONE PR.
#
# Inputs:
#   $1 — PR URL
#
# Env:
#   GH_TOKEN              — set by the workflow
#   REVIEW_ENGINE         — "claude", "gemini", or "copilot" (default: claude)
#   CLAUDE_CODE_OAUTH_TOKEN — (claude engine) set by the workflow
#   GOOGLE_API_KEY          — (gemini engine) set by the workflow
#   COPILOT_GITHUB_TOKEN    — (copilot engine) set by the workflow
#   DRY_RUN               — "true" or "false"
#
# Behavior:
#   1. Resolve current head SHA of the PR.
#   2. Idempotency check: scan existing reviews/comments for our marker
#      `<!-- pr-review-agent v1 sha=<SHA> -->`. If a marker for the current
#      head SHA exists, skip without spending tokens.
#   3. Run cascading review: triage → deep review → security audit.

set -euo pipefail

# Source the engine abstraction (sets ENGINE_* vars, defines run_triage/run_agentic).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=engine.sh
source "$SCRIPT_DIR/engine.sh"
# Cycle-cap helpers: compute_review_cycle, has_escalation_marker (issue #467).
# shellcheck source=lib/review-cycle.sh
source "$SCRIPT_DIR/lib/review-cycle.sh"
# Per-PR automation budget: enforce_pr_budget (issue #926).
# shellcheck source=lib/pr-automation-budget.sh
source "$SCRIPT_DIR/lib/pr-automation-budget.sh"
# CI gate: compute_ci_status filters own check runs before classifying (issue #469).
# shellcheck source=lib/ci-status.sh
source "$SCRIPT_DIR/lib/ci-status.sh"
# Rubric registry: review_registry_lookup resolves {rubric, output_channel} for
# an artifact_type — the input-adapter layer above engine.sh (issues #611/#612).
# shellcheck source=lib/review-registry.sh
source "$SCRIPT_DIR/lib/review-registry.sh"
# Issue-type classifier routing (issue #1091): classify_triage_type reads the
# triage `type` label and resolve_deep_specialist maps it to the specialist
# deep-review prompt via the registry, falling back to prompts/deep-review.md.
# shellcheck source=lib/deep-specialist.sh
source "$SCRIPT_DIR/lib/deep-specialist.sh"
# Downstream-impact pass (epic #748): assemble_downstream_impact maps the PR's
# changed files to consumer repos that pin the changed shared surface, and
# downstream_impact_triage_section inlines that block into the triage prompt.
# Gated default-off behind DOWNSTREAM_IMPACT_ENABLED (Story 5).
# shellcheck source=lib/downstream-impact.sh
source "$SCRIPT_DIR/lib/downstream-impact.sh"
# Deterministic PR safety checks (issue #305): assemble_safety_checks computes a
# SAFETY_CHECKS block (CI-weakening / prompt-injection hard-stops, large-PR gate,
# description-quality, dependency-risk) from PR_METADATA + PR_DIFF with no `gh`/
# network I/O; safety_checks_triage_section inlines it into the triage prompt.
# Gated behind SAFETY_CHECKS_ENABLED (default ON; off => byte-identical prompt).
# shellcheck source=lib/safety-checks.sh
source "$SCRIPT_DIR/lib/safety-checks.sh"

# shellcheck source=lib/merge-queue-dequeue.sh
source "$SCRIPT_DIR/lib/merge-queue-dequeue.sh"
# Semantic symbol-context pass (issue #1090, epic #1088): assemble_symbol_context
# gathers caller/callee/type-def reference contexts (via the GitHub search_code
# path) for each function touched in the diff and writes them to a file whose
# path is exported as SYMBOL_CONTEXT_FILE for the deep + duck tiers. Gated
# default-off behind SYMBOL_CONTEXT_ENABLED (inert + byte-identical when off).
# shellcheck source=lib/symbol-context.sh
source "$SCRIPT_DIR/lib/symbol-context.sh"
# Merged-PR few-shot injection pass (issue #1093, epic #1088, Phase 2):
# assemble_fewshot renders de-identified past review->merge examples from a
# proposer-visible dev split into a FEWSHOT block whose path is exported as
# FEWSHOT_FILE for the deep tier (mirroring SYMBOL_CONTEXT_FILE). Gated
# default-off behind FEWSHOT_ENABLED (inert + byte-identical when off); the
# source is hard-guarded to never be evals/**/holdout (held-out discipline).
# shellcheck source=lib/fewshot.sh
source "$SCRIPT_DIR/lib/fewshot.sh"
# Shared PR-context prefetch (epic #1101, Story 2): prefetch_pr_context persists
# the FULL diff + superset metadata to SHA-bound files (PR_CONTEXT_DIFF_FILE /
# PR_CONTEXT_METADATA_FILE) for the agentic tiers. Gated default-off behind
# PREFETCH_CONTEXT_ENABLED — a byte-identical no-op (zero files, zero exports)
# when off. Story 5 consumers verify the PR_HEAD_SHA stamp before use.
# shellcheck source=lib/pr-context-prefetch.sh
source "$SCRIPT_DIR/lib/pr-context-prefetch.sh"
# Agentic iterative validation (issue #1092): apply_finding_verification applies
# the repro-outcome downgrade/drop discipline to the deep tier's logic/correctness
# findings and emits kind:"finding_verification" records so the false-positive-rate
# delta is measurable. Pure jq — the repro itself runs inside the deep tier's
# already-bounded, privilege-flat run_agentic sandbox.
# shellcheck source=lib/finding-verification.sh
source "$SCRIPT_DIR/lib/finding-verification.sh"

# PR-metadata digest for the reviewed-state fingerprint (issue #1551). Lets a
# metadata-only fix-request re-arm on a body/label/linked-issue edit that mints
# no new commit, without changing same-SHA no-op behavior for approvals or
# code-change findings.
# shellcheck source=lib/pr-metadata-digest.sh
source "$SCRIPT_DIR/lib/pr-metadata-digest.sh"

# Recognises an approval at the head that pr-review's own gate dismissed (#1933):
# a "pending re-evaluation" state the same-SHA idempotency no-op must not stand on.
# shellcheck source=lib/self-dismissed-approval.sh
source "$SCRIPT_DIR/lib/self-dismissed-approval.sh"

# Per-PR review-claim primitive (issue #1589, slice 1 — OBSERVE-ONLY). Provides
# the claim key = (head SHA, metadata digest), the claim marker format, and
# concurrent_claim_present so the #1551 same-SHA re-review race is observable
# before slice 2 adds compare-and-set arbitration. It changes no behaviour here:
# the digest-mismatch path still proceeds; it only records when a concurrent
# claim exists.
# shellcheck source=lib/pr-review-claim.sh
source "$SCRIPT_DIR/lib/pr-review-claim.sh"

# Carry-forward decision for base-merge-only re-reviews (issue #1865). When the
# last recorded verdict was an approval at an EARLIER head SHA and every
# intervening commit is a conflict-free base merge with a byte-identical
# diff-vs-merge-base, evaluate_carry_forward returns `carry` so we re-issue the
# prior approval instead of re-running any model tier. Every other delta (a
# resolved conflict, a content commit, or any indeterminable state) returns
# `full:<reason>` and falls through to the normal cascade — fail toward reviewing.
# shellcheck source=lib/carry-forward.sh
source "$SCRIPT_DIR/lib/carry-forward.sh"

PR_URL="${1:?usage: review-one-pr.sh <pr-url>}"
export PR_URL

# Diagnose mode (#1894): answer "why isn't this PR approved?" by running the REAL
# gate chain below — the same functions, in the same order, on the same live
# state — and stopping before any model runs. It is read-only (DRY_RUN) and never
# forced: a diagnosis must report what a normal run would do, so the human
# break-glass and the orphan-rescue bypass are both off. The answer is the run's
# single emit_verdict line (decision, reason, would_change). Used by
# scripts/pr-approval-diagnostic.sh; never set by the review workflows.
#
# DRY_RUN alone is not a guarantee — a gate's write that predates its DRY_RUN
# guard (the advisory rate-limited marker did, #1902 review) would still post.
# So in diagnose mode `gh` itself refuses every write: the refused call fails
# (visible in the log, never silently "succeeds"), and reads pass through.
_diagnose_gh_is_write() {
  local sub="${1:-}" verb="${2:-}" a prev="" method="" has_params=false query=""
  case "$sub" in
    pr|issue) case "$verb" in view|list|status|diff|checks) return 1 ;; *) return 0 ;; esac ;;
    label|release|repo|workflow|run|secret|variable)
      case "$verb" in view|list|download|watch) return 1 ;; *) return 0 ;; esac ;;
    api) ;;
    auth) case "$verb" in status|token) return 1 ;; *) return 0 ;; esac ;;
    search|status|help|version|--version|--help) return 1 ;;
    # Fail closed: any other subcommand (gist, codespace, ruleset, an extension…)
    # is refused unless it is listed above as read-only.
    *) return 0 ;;
  esac
  shift
  for a in "$@"; do
    case "$a" in
      -X?*) method="${a#-X}" ;;
      --method=*) method="${a#--method=}" ;;
    esac
    case "$prev" in
      -X|--method) method="$a" ;;
      -f|-F|--field|--raw-field) has_params=true; [[ "$a" == query=* ]] && query="${a#query=}" ;;
      --input) has_params=true ;;
    esac
    prev="$a"
  done
  method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
  if [ "${1:-}" = "graphql" ]; then
    # GraphQL is always POST; it writes only through a mutation.
    [[ "$query" =~ ^[[:space:]]*mutation ]] && return 0
    return 1
  fi
  [ -n "$method" ] && { [ "$method" != "GET" ]; return; }
  $has_params   # gh api defaults to POST when fields or an --input body are given
}
if [ "${PR_REVIEW_DIAGNOSE:-false}" = "true" ]; then
  DRY_RUN=true FORCE_REVIEW=false FORCE_RE_REVIEW=false
  export DRY_RUN FORCE_REVIEW FORCE_RE_REVIEW
  # gh — diagnostic wrapper that enforces read-only mode when PR_REVIEW_DIAGNOSE is true.
  gh() {
    if _diagnose_gh_is_write "$@"; then
      echo "    diagnose: refused a GitHub write (gh $1 ${2:-}) — diagnose mode is read-only" >&2
      return 1
    fi
    command gh "$@"
  }
fi

# emit_verdict <decision> <reason> <would_change>
#   Emit THE single structured verdict line for a run that DECLINES to review this
#   PR (skip / noop / escalate / error). It carries pr, head sha, decision, a
#   machine-readable reason AND `would_change` — the condition that would flip the
#   decision — so a no-op is fully diagnosable from ONE log line instead of log
#   archaeology + manual re-runs (issue #1552 AC#2; the PR-review-side mirror of
#   #1494 AC#3's slot-math line). jq-built so the prose `would_change` is escaped
#   and the line stays valid JSON: review-batch.sh's reason parser and the batch
#   skip reporting keep working unchanged. PR_HEAD_SHA is resolved at call time
#   (every decline branch runs after it is set).
emit_verdict() {
  jq -cn \
    --arg pr "$PR_URL" \
    --arg sha "${PR_HEAD_SHA:-}" \
    --arg decision "$1" \
    --arg reason "$2" \
    --arg would_change "$3" \
    '{pr:$pr, sha:$sha, decision:$decision, reason:$reason, would_change:$would_change}'
  # #1894: also record it in the step summary, so "why not approved?" is answered
  # where an operator looks, not only in the run log. Best-effort. (A run that
  # reaches the model cascade answers with the review it posts instead.)
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    local _sha="${PR_HEAD_SHA:-}"
    printf -- '- **%s** at `%s`: `%s` (%s). Changes when: %s\n' \
      "$PR_URL" "${_sha:0:8}" "$1" "$2" "$3" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
  fi
}

# review_one_pr_cleanup — EXIT-trap cleanup: remove fewshot directory if created,
# then fail the run if a hold label failed (#2142).
review_one_pr_cleanup() {
  local rc=$?
  [ -z "${_fewshot_dir:-}" ] || rm -rf "$_fewshot_dir"
  hold_label_exit_guard "$rc"
}

# A failed hold (#2142) must fail the run. Set the trap early, before any work
# that might trigger enforce_pr_budget. The trap must call the function directly:
# a prefix like `rc=$?;` would reset $? to 0 before the function captures it.
trap review_one_pr_cleanup EXIT

echo "==> $PR_URL"

# ==========================================================================
# Artifact-contract dispatch (issues #611/#612). The production PR-review path
# is the `pr_diff` handler of the rubric registry: instead of hard-coding the
# cascade, resolve {rubric, output_channel} for artifact_type=pr_diff from the
# versioned manifest, then run the existing tier sequence under it. content_ref
# is the PR URL — the metadata + diff prefetch below is its adapter. Phase 1
# registers only pr_diff, resolving to today's behavior with no change.
# ==========================================================================
ARTIFACT_TYPE="pr_diff"
CONTENT_REF="$PR_URL"

REVIEW_RUBRIC=$(review_registry_lookup "$ARTIFACT_TYPE" rubric | tr -d '\r') || {
  echo "::error::no rubric registered for artifact_type=$ARTIFACT_TYPE"
  exit 1
}
REVIEW_OUTPUT_CHANNEL=$(review_registry_lookup "$ARTIFACT_TYPE" output_channel | tr -d '\r') || {
  echo "::error::no output_channel registered for artifact_type=$ARTIFACT_TYPE"
  exit 1
}

# The rubric is an ordered, comma-separated cascade of prompt files. Bind the
# tier prompts this dispatch drives directly from it: entry 1 -> triage (tier 1),
# entry 2 -> deep review (tier 2). Both resolve to the existing prompt files, so
# the cascade behaves identically.
IFS=',' read -ra REVIEW_RUBRIC_CASCADE <<< "$REVIEW_RUBRIC"
RUBRIC_TRIAGE_PROMPT="${REVIEW_RUBRIC_CASCADE[0]:-prompts/triage.md}"
RUBRIC_DEEP_PROMPT="${REVIEW_RUBRIC_CASCADE[1]:-prompts/deep-review.md}"

echo "    artifact_type=$ARTIFACT_TYPE content_ref=$CONTENT_REF"
echo "    rubric=$REVIEW_RUBRIC"
echo "    output_channel=$REVIEW_OUTPUT_CHANNEL"

# ruleset_required_checks now lives in lib/ci-status.sh (sourced above) so every
# compute_ci_status caller — this script, the stuck-review sweep, and the
# stall/merge-ready scans — gates on the same authoritative required set (#1795).

# 1. Current head SHA + CI gate — single API call for both fields.
#    Strict CI classification:
#      pending — any item still running (IN_PROGRESS/QUEUED/WAITING/PENDING/EXPECTED
#                or COMPLETED with null/empty conclusion)
#      passing — all items completed AND every conclusion is SUCCESS, SKIPPED, or
#                NEUTRAL (or rollup empty). SKIPPED covers path-filtered checks;
#                NEUTRAL covers informational checks that don't gate merging.
#      failing — anything else (FAILURE, ACTION_REQUIRED, TIMED_OUT, CANCELLED,
#                STALE, STARTUP_FAILURE, or unknown conclusions)
PR_SNAPSHOT=$(gh pr view "$PR_URL" --json headRefOid,baseRefName,statusCheckRollup,reviewDecision,reviews,labels,comments,body,closingIssuesReferences)
PR_HEAD_SHA=$(echo "$PR_SNAPSHOT" | jq -r '.headRefOid')
export PR_HEAD_SHA
echo "    head SHA: $PR_HEAD_SHA"

# owner/repo from the PR URL — pure Bash regex, no printf|sed subprocess.
_OWNER_REPO=""
if [[ "$PR_URL" =~ ^https?://[^/]+/([^/]+/[^/]+)/pull/[0-9]+ ]]; then
  _OWNER_REPO="${BASH_REMATCH[1]}"
fi

# resolve_required_checks <base_ref> — set REQUIRED_CHECKS_JSON from the branch
# ruleset for <base_ref>. Passed into every compute_ci_status call so a failing check
# the ruleset does not require cannot by itself produce `ci-failing` (#1795 AC #2).
# Fail closed: an unreadable/empty set leaves REQUIRED_CHECKS_JSON empty and
# compute_ci_status reverts to gating on all failing checks (#1795 AC #3). Re-callable
# so the poll loop can refresh it if the PR is retargeted to a different base branch
# (the required set is base-branch-specific — a stale set would gate on the old
# ruleset). Only re-invoked when the base actually changes, so no redundant API read.
resolve_required_checks() {
  local _base_ref="$1"
  REQUIRED_CHECKS_JSON=$(ruleset_required_checks "$_OWNER_REPO" "$_base_ref" || true)
  if [ -n "$REQUIRED_CHECKS_JSON" ] && [ "$REQUIRED_CHECKS_JSON" != "[]" ]; then
    echo "    required checks (branch ruleset for $_base_ref): $REQUIRED_CHECKS_JSON"
  else
    echo "    required checks ($_base_ref): none readable — failing closed (every failing check blocks)"
    REQUIRED_CHECKS_JSON=""
  fi
}
PR_BASE_REF=$(jq -r '.baseRefName // ""' <<< "$PR_SNAPSHOT")
resolve_required_checks "$PR_BASE_REF"

CI_STATUS=$(compute_ci_status "$(jq '.statusCheckRollup' <<< "$PR_SNAPSHOT")" "$REQUIRED_CHECKS_JSON")
echo "    CI status: $CI_STATUS"

REVIEW_DECISION=$(echo "$PR_SNAPSHOT" | jq -r '.reviewDecision // ""')
echo "    review decision: $REVIEW_DECISION"

# Exit code 100 is the skip sentinel: the caller treats any 100 exit as a
# no-op and does not count it against the MAX_PRS review budget.
# Reasons that produce a skip: already-reviewed-at-head, ci-failing, ci-pending, changes-requested.
if [ "$CI_STATUS" = "failing" ]; then
  if [ "${FORCE_REVIEW:-false}" = "true" ]; then
    # Break-glass (#619): a human @mention (FORCE_REVIEW=true) overrides the
    # ci-failing gate so a fix to the CI gate *itself* can be reviewed and
    # approved through ring-0 self-host — the one case the pinned-stable design
    # otherwise can't ship without an out-of-band admin merge. This is safe:
    #   • FORCE_REVIEW is @mention-only — pr-review.yml sets it true ONLY for a
    #     repository_dispatch (the mention-listener path). An automated force_review
    #     input (the orphan-rescue sweep) maps to the NARROW FORCE_RE_REVIEW instead
    #     (#1590), which does not reach this gate — so this never fires
    #     automatically, only on a deliberate human override.
    #   • GitHub's ruleset still blocks the merge on any failing REQUIRED check, so
    #     an override only unblocks the codeowner-approval gate for PRs whose
    #     failing checks are non-required (e.g. superseded dev-lead orchestration
    #     jobs) — it cannot merge a PR with a genuinely failing required check.
    echo "::warning::force-review: CI is failing but FORCE_REVIEW=true — bypassing the ci-failing gate (break-glass, #619). Required-check failures still block the merge at the ruleset."
  else
    echo "    skip: CI checks are failing — will re-evaluate after fixes are pushed"
    emit_verdict skip ci-failing "the failing (non-superseded) required checks turn green; a new push or the pr-review sweep then re-triggers review"
    exit 100
  fi
fi

# Bounded ci-pending deferral (issue #1427, AC #3/#4). A genuinely stuck check —
# one that stays pending indefinitely with no terminal conclusion — must not defer
# the review forever. If every remaining external pending check has been pending
# longer than CI_PENDING_MAX_AGE_SEC (default 30 min), proceed on the completed
# checks rather than skipping. This bounds only the review DECISION: the merge gate
# is enforced independently by the branch-protection ruleset, which still blocks the
# merge on any genuinely-pending *required* check, so this can never merge a
# not-yet-green PR (fail-safe, not fail-open). Own-agent and other first-party agent
# checks are already excluded by compute_ci_status / ci_pending_age_exceeded.
if [ "$CI_STATUS" = "pending" ]; then
  _CI_PENDING_MAX_AGE="${CI_PENDING_MAX_AGE_SEC:-1800}"
  case "$_CI_PENDING_MAX_AGE" in ''|*[!0-9]*) _CI_PENDING_MAX_AGE=1800 ;; esac
  if [ "$(ci_pending_age_exceeded "$(jq '.statusCheckRollup' <<< "$PR_SNAPSHOT")" "$_CI_PENDING_MAX_AGE")" = "true" ]; then
    echo "::warning::ci-pending: external check(s) have been pending longer than ${_CI_PENDING_MAX_AGE}s without completing — proceeding with the review on the completed checks (bounded deferral, #1427). The merge gate still blocks on any genuinely-pending required check at the ruleset."
    # Escalate once — post a visible, deduped note so a human sees the stuck check.
    _timeout_marker='<!-- pr-review-agent ci-pending-timeout -->'
    if [ "${DRY_RUN:-false}" != "true" ] && \
       ! jq -e --arg m "$_timeout_marker" '(.comments // []) | any((.body // "") | contains($m))' <<< "$PR_SNAPSHOT" >/dev/null 2>&1; then
      _tmsg=$(printf '%s\n\nSome CI checks have been pending for over %ss without completing, so this review is proceeding on the checks that did complete. This does not merge the PR — the branch-protection rules still require every genuinely-pending required check before merge. No action is needed.\n\n_Posted by the %s PR-review cascade._' \
        "$_timeout_marker" "$_CI_PENDING_MAX_AGE" "${BOT_USER:-donpetry-bot}")
      gh pr comment "$PR_URL" --body "$_tmsg" || echo "    warn: could not post ci-pending-timeout comment"
      unset _tmsg
    fi
    unset _timeout_marker
    CI_STATUS="passing"
    echo "    ci-pending bounded out (stuck > ${_CI_PENDING_MAX_AGE}s) — proceeding with the review"
  fi
  unset _CI_PENDING_MAX_AGE
fi

# Pending CI gate: for normal runs, skip immediately.
# For FORCE_REVIEW=true (mention-triggered), poll briefly so transient check
# churn (caused by the mention burst itself) doesn't silently swallow the run
# (issue #469). Defaults: 10 polls × 30 s = up to 5 minutes.
if [ "$CI_STATUS" = "pending" ]; then
  if [ "${FORCE_REVIEW:-false}" = "true" ]; then
    _FORCE_POLL_MAX="${FORCE_REVIEW_POLL_ATTEMPTS:-10}"
    _FORCE_POLL_SEC="${FORCE_REVIEW_POLL_INTERVAL_SEC:-30}"
    # Validate that the env-var overrides are positive integers; fall back to
    # the defaults if they are not so that sleep and the numeric test don't fail.
    case "$_FORCE_POLL_MAX" in
      ''|*[!0-9]*) _FORCE_POLL_MAX=10 ;;
    esac
    case "$_FORCE_POLL_SEC" in
      ''|*[!0-9]*) _FORCE_POLL_SEC=30 ;;
    esac
    [ "$_FORCE_POLL_MAX" -gt 0 ] || _FORCE_POLL_MAX=10
    [ "$_FORCE_POLL_SEC" -gt 0 ] || _FORCE_POLL_SEC=30
    _poll=1
    while [ "$_poll" -le "$_FORCE_POLL_MAX" ] && [ "$CI_STATUS" = "pending" ]; do
      echo "    force-review: CI pending, waiting ${_FORCE_POLL_SEC}s for checks to settle (attempt ${_poll}/${_FORCE_POLL_MAX})"
      sleep "$_FORCE_POLL_SEC"
      _gh_poll_err=$(mktemp 2>/dev/null || echo "/tmp/cascade/gh-poll-$$.err")
      if ! PR_SNAPSHOT=$(gh pr view "$PR_URL" --json headRefOid,baseRefName,statusCheckRollup,reviewDecision,reviews,labels,comments,body,closingIssuesReferences 2>"$_gh_poll_err"); then
        _gh_poll_err_content=$(cat "$_gh_poll_err" 2>/dev/null || true)
        rm -f "$_gh_poll_err"
        if is_rate_limited "$_gh_poll_err_content"; then
          echo "    gh API rate limited during polling — skipping PR"
          emit_verdict skip gh-rate-limited "the GitHub API rate limit resets and the next scheduled pr-review sweep retries this PR"
          exit 100
        fi
        echo "::error::gh pr view failed during polling for $PR_URL"
        exit 1
      fi
      rm -f "$_gh_poll_err"
      PR_HEAD_SHA=$(jq -r '.headRefOid' <<< "$PR_SNAPSHOT")
      export PR_HEAD_SHA
      # If the PR was retargeted mid-poll, the required-check set is base-branch-
      # specific, so refresh it against the new base before classifying — otherwise
      # CI is evaluated with the old base's ruleset. Only refetched when the base
      # actually changes, so an unchanged base costs no extra API read.
      _poll_base_ref=$(jq -r '.baseRefName // ""' <<< "$PR_SNAPSHOT")
      if [ "$_poll_base_ref" != "$PR_BASE_REF" ]; then
        echo "    force-review: PR retargeted $PR_BASE_REF → $_poll_base_ref — refreshing required checks"
        PR_BASE_REF="$_poll_base_ref"
        resolve_required_checks "$PR_BASE_REF"
      fi
      CI_STATUS=$(compute_ci_status "$(jq '.statusCheckRollup' <<< "$PR_SNAPSHOT")" "$REQUIRED_CHECKS_JSON")
      echo "    CI status (poll ${_poll}): $CI_STATUS"
      _poll=$((_poll + 1))
    done
    unset _poll_base_ref
    unset _poll _FORCE_POLL_MAX _FORCE_POLL_SEC _gh_poll_err _gh_poll_err_content

    if [ "$CI_STATUS" = "failing" ]; then
      if [ "${FORCE_REVIEW:-false}" = "true" ]; then
        echo "::warning::force-review: CI is failing but FORCE_REVIEW=true — bypassing the ci-failing gate (break-glass, #619). Required-check failures still block the merge at the ruleset."
      else
        echo "    skip: CI checks are failing (detected after polling) — will re-evaluate after fixes are pushed"
        emit_verdict skip ci-failing "the failing (non-superseded) required checks turn green; a new push or the pr-review sweep then re-triggers review"
        exit 100
      fi
    fi

    if [ "$CI_STATUS" = "pending" ]; then
      echo "    force-review: CI still pending after polling — posting visible comment"
      if [ "${DRY_RUN:-false}" != "true" ]; then
        # AC #5 (#1427): the ack must NOT recommend a re-mention. A re-mention is
        # an issue_comment that fires dev-lead, whose own "dev-lead / dispatch"
        # check going IN_PROGRESS is exactly the condition that used to re-arm this
        # deferral. The PR-review sweep already re-reviews automatically once the
        # checks complete, so no user action is required.
        _msg=$(printf '<!-- pr-review-agent ci-pending-ack -->\n\nCI checks on this PR are still running. The PR-review sweep re-reviews this PR automatically once the checks complete — no action is needed.\n\n_Posted by the %s PR-review cascade._' \
          "${BOT_USER:-donpetry-bot}")
        gh pr comment "$PR_URL" --body "$_msg" || echo "    warn: could not post ci-pending-ack comment"
        unset _msg
      fi
      emit_verdict skip ci-pending-after-poll "the pending checks finish green; the pr-review sweep re-reviews automatically once they complete (no re-mention needed)"
      exit 100
    fi

    # CI settled — update REVIEW_DECISION from the refreshed snapshot
    REVIEW_DECISION=$(jq -r '.reviewDecision // ""' <<< "$PR_SNAPSHOT")
    echo "    review decision (after CI poll): $REVIEW_DECISION"
  else
    echo "    skip: CI checks still in progress — will re-evaluate when checks complete"
    emit_verdict skip ci-pending "the pending checks finish green; the pr-review sweep re-reviews automatically once they complete"
    exit 100
  fi
fi

# CI gate cleared. If any NON-required check is red, the gate deliberately let the
# review proceed past it (#1795 AC #2) — but downgrading a signal must not delete
# it (AC #4). Name each such advisory failure here (log) and export it so the
# review prompt surfaces it in the review body: "reviewed despite a red advisory
# check" stays visible rather than silent. Empty when nothing non-required is red.
NON_REQUIRED_CI_FAILURES=$(
  ci_nonrequired_failures "$(jq '.statusCheckRollup' <<< "$PR_SNAPSHOT")" "$REQUIRED_CHECKS_JSON" \
    | paste -sd ',' - 2>/dev/null || true
)
if [ -n "$NON_REQUIRED_CI_FAILURES" ]; then
  echo "::notice::proceeding past non-required failing check(s) the branch ruleset does not require: ${NON_REQUIRED_CI_FAILURES} — the merge gate still blocks on any failing REQUIRED check (#1795)"
  export NON_REQUIRED_CI_FAILURES
fi

# Advisory bot review gate — instant check for advisory bot reviews (Gemini, Copilot, SonarCloud, Codex)
# This ensures valid code reviews are incorporated before pr-review posts approval (issue #457).
#
# DESIGN: Non-blocking re-trigger pattern
#   Instant check (no polling/blocking):
#   • Return 0: all bots submitted → approve
#   • Return 1: waiting for bots → skip (exit 100), await pull_request_review event
#   • On next bot submission: pull_request_review event fires → re-trigger pr-review
#
# COST: ~75% savings vs blocking (2-3 min runs vs 10-60 min blocks)
#
# The gate proceeds BEFORE the approval is written, so it must NOT announce the
# partial-evidence approval itself (that stranded PRs behind a comment claiming an
# approval that never landed, #1874). Point the gate at a state file: it records
# the partial-evidence facts there, and post-pr-review.sh posts the announcement
# only after it verifies the review object exists. Exported so the later
# post-pr-review.sh child process inherits the path. Use mktemp for a unique,
# non-predictable path (avoids the /tmp symlink/predictability hazard and any
# stale state from a previous PR handled in the same batch process).
export PARTIAL_EVIDENCE_STATE_FILE
PARTIAL_EVIDENCE_STATE_FILE=$(mktemp) || { echo "::error::failed to create temporary state file" >&2; exit 1; }
(
  # Subshell: true environment isolation so functions and variables defined
  # by the gate (ADVISORY_BOTS, color codes, log helpers) do not persist in
  # the caller's environment after this block exits.
  # shellcheck source=lib/advisory-review-gate.sh
  source "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  # Provides maybe_post_partial_evidence_marker so a timeout-fallback approval is
  # recorded on the PR for the miss-rate metric (#1596); the gate no-ops without it.
  # shellcheck source=lib/partial-evidence-marker.sh
  source "$SCRIPT_DIR/lib/partial-evidence-marker.sh"
  check_advisory_reviews "$PR_URL"
) || {
  gate_rc=$?
  if [ $gate_rc -eq 1 ]; then
    if [ "${FORCE_REVIEW:-false}" = "true" ]; then
      # FORCE_REVIEW overrides the gate — mention/dispatch-triggered runs must proceed
      # even when advisory bots haven't submitted yet, so the force-review path works.
      echo "    force-review: advisory bots not all submitted, but FORCE_REVIEW=true — proceeding"
    else
      # If the withhold is because an advisory/review bot is itself rate-limited
      # (out of quota), stamp a machine-detectable marker so pr-review-sweep can
      # auto-retry once the limit resets (issue #711). Without this, no bot event
      # re-fires and the PR strands at REVIEW_REQUIRED with green CI. The marker
      # is posted in an isolated subshell so the gate's helpers/vars do not leak.
      (
        # shellcheck source=lib/advisory-review-gate.sh
        source "$SCRIPT_DIR/lib/advisory-review-gate.sh"
        if detect_advisory_rate_limit "$PR_SNAPSHOT"; then
          reset_iso=$(date -u -d "+${RATE_LIMIT_RETRY_BACKOFF:-3600} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -v+"${RATE_LIMIT_RETRY_BACKOFF:-3600}"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || true)
          maybe_post_rate_limited_marker "$PR_URL" "$PR_HEAD_SHA" "$reset_iso" "$PR_SNAPSHOT" || true
        fi
      ) || true
      # Bots are still reviewing — skip this run, will re-check on next bot review submission
      # Exit 100 (no-op) prevents workflow from consuming budget while awaiting bots
      echo "    skip: advisory bots still reviewing (non-blocking, will re-check on bot submission)"
      emit_verdict skip waiting-for-advisory-bots "the advisory bots (Gemini/Copilot/SonarCloud/Codex) submit their reviews, whose pull_request_review event re-triggers this review"
      exit 100
    fi
  elif [ $gate_rc -eq 2 ]; then
    # API/parse error in the gate — fail this PR rather than approving without advisory check.
    # No bot event will re-trigger this run, so exit 1 (per-PR failure) allows the
    # scheduler to retry on a subsequent scheduled run instead of silently skipping.
    echo "    error: advisory gate API/parse error — failing PR to avoid uninformed approval"
    emit_verdict error advisory-gate-api-error "the advisory-bot gate API/parse error clears; the next scheduled pr-review sweep retries this PR"
    exit 1
  else
    # Unexpected error
    exit $gate_rc
  fi
}

# Maintainer issue-comment gate (issues #1290, #1813). A maintainer finding
# posted as a PR *issue comment* (`gh pr comment` / the GitHub main comment box)
# creates no review thread, so it neither trips `required_review_thread_resolution`
# nor is read by dev-lead's fix-reviews prompt — pr-review approves and the PR
# auto-merges with the defect. #1813 redesign: "addressed" is no longer a
# timestamp proxy (pushedDate is always null and a push says nothing about
# whether the finding was answered). Withhold approval while ANY non-agent PR
# issue comment lacks a VERIFIED DISPOSITION — surfaced server-side as the
# comment being minimized RESOLVED after dev-lead's disposition reply is
# verified. It FAILS CLOSED: an undeterminable snapshot blocks distinctly.
#   • FORCE_REVIEW bypasses (a human @mention IS the human-in-the-loop, and the
#     same comment that triggers a re-review would otherwise deadlock the gate).
#   • rc=1 → skip (exit 100); a later disposition+minimize re-triggers pr-review.
#   • rc=2 → fail the PR (exit 1) so a scheduled run retries, never approve blind.
if [ "${FORCE_REVIEW:-false}" != "true" ]; then
  (
    # Subshell isolation so the gate's helpers/vars don't leak into the caller.
    # shellcheck source=lib/maintainer-comment-gate.sh
    source "$SCRIPT_DIR/lib/maintainer-comment-gate.sh"
    # #2008: merge lastEditedAt (edits re-open a bot comment; lookup failure fails closed).
    _mc_snapshot=$(maintainer_gate_merge_edit_times "$PR_URL" "$PR_SNAPSHOT")
    check_maintainer_comments "$_mc_snapshot" "${BOT_USER:-donpetry-bot}"
  ) || {
    mc_gate_rc=$?
    if [ "$mc_gate_rc" -eq 1 ]; then
      echo "    skip: a PR issue comment lacks a verified disposition — withholding approval (#1813)"
      # Dismiss any existing pr-review-agent APPROVED review so the PR remains blocked
      # until the maintainer comment is addressed (best-effort).
      if [ "${DRY_RUN:-false}" != "true" ]; then
        _agent_approval=$(echo "$PR_SNAPSHOT" | jq -r --arg bot "${BOT_USER:-donpetry-bot}" --arg sha "$PR_HEAD_SHA" 'first((.reviews // [])[] | select(.author?.login == $bot and .state == "APPROVED" and .commit?.oid == $sha) | .id) // empty' 2>/dev/null || true)
        if [ -n "$_agent_approval" ]; then
          gh api graphql -f query='mutation($id:ID!,$msg:String!){dismissPullRequestReview(input:{pullRequestReviewId:$id,message:$msg}){clientMutationId}}' -f id="$_agent_approval" -f msg="Dismissing approval due to a PR issue comment lacking a verified disposition (#1813)" 2>/dev/null || echo "    warn: could not dismiss prior approval"
          # The queue checks reviews only at enqueue; drop a queued PR left with no approval (#2174).
          mq_dequeue_if_unapproved "$PR_URL" || true
        fi
      fi
      # Act on this verdict instead of waiting (#2017). When a blocking comment is
      # a registered reviewer bot's, only dev-lead's fix-bot-comment pass can
      # disposition it — and if that run was lost (superseded while pending in the
      # per-PR lane, #2009), nothing else ever would. Run the SAME deduplicated
      # retry scan the dev-lead-retry cron uses for this PR: it dispatches at most
      # one fix-bot-comment pass (by comment node id), only for registered-bot
      # comments with no covering disposition, and never one already pending.
      # It never minimizes anything — the gate is unchanged. Best-effort.
      # When it dispatched nothing, the same deduplicated scan for unreplied bot
      # review threads runs next (#2046). It shares the cron's claim marker, so
      # the two never both dispatch.
      if [ "${DRY_RUN:-false}" != "true" ] && [ -n "$_OWNER_REPO" ] \
         && [[ "$PR_URL" =~ /pull/([0-9]+) ]]; then
        _bcr_pr="${BASH_REMATCH[1]}"
        _bcr_log=$( (
          # shellcheck source=dev-lead-retry.sh
          source "$SCRIPT_DIR/dev-lead-retry.sh"
          _bcr_n=$(scan_pr_for_undispositioned_bot_comments "$_OWNER_REPO" "$_bcr_pr")
          echo "$_bcr_n"
          if [ "${_bcr_n:-0}" = "0" ]; then
            scan_pr_for_unreplied_bot_threads "$_OWNER_REPO" "$_bcr_pr"
          fi
        ) 2>&1 ) || true
        printf '%s\n' "$_bcr_log" | sed 's/^/    [bot-comment-retry] /'
      fi
      emit_verdict skip undispositioned-pr-comment "dev-lead posts a verified disposition reply and the harness minimizes the comment RESOLVED, or an @mention (FORCE_REVIEW) overrides the gate"
      exit 100
    elif [ "$mc_gate_rc" -eq 2 ]; then
      echo "    error: maintainer-comment gate could not evaluate the PR snapshot — failing closed to avoid uninformed approval"
      emit_verdict error maintainer-comment-gate-error "the gate can parse the PR snapshot and each comment's disposition state; the next scheduled pr-review sweep retries this PR"
      exit 1
    else
      exit "$mc_gate_rc"
    fi
  }
fi

# Maintainer review-thread gate (issue #1415). The review-path sibling of the
# issue-comment gate above. On a dev-lead-authored PR the owner cannot use
# CHANGES_REQUESTED ("Can not request changes on your own pull request") and the
# agent — acting as the owner `don-petry` — can resolve the maintainer's own
# review threads (observed on PR #1413), defeating both blocking paths. This gate
# keys on the automation MARKER (not login, which cannot separate the two) and
# withholds approval while an UNRESOLVED maintainer review thread postdates the
# last push. It FAILS CLOSED: an undeterminable authorship/created/push-time
# blocks rather than reading as "no findings". The coupled resolve-guard in
# dev-lead-fix-reviews.sh is what makes a thread's resolution a safe human signal.
#   • FORCE_REVIEW bypasses (a human @mention IS the human-in-the-loop).
#   • rc=1 → skip (exit 100); a later reply/push re-triggers pr-review.
#   • rc=2 → fail the PR (exit 1) so a scheduled run retries, never approve blind.
if [ "${FORCE_REVIEW:-false}" != "true" ]; then
  (
    # Subshell isolation so the gate's helpers/vars don't leak into the caller.
    # The issue-comment gate is sourced too for its head-commit committer.date
    # helper (same cherry-pick-safe push-time semantics both gates share).
    # shellcheck source=lib/maintainer-comment-gate.sh
    source "$SCRIPT_DIR/lib/maintainer-comment-gate.sh"
    # shellcheck source=lib/maintainer-review-thread-gate.sh
    source "$SCRIPT_DIR/lib/maintainer-review-thread-gate.sh"
    _mrt_head_date=$(maintainer_gate_head_committer_date "$PR_URL")
    _mrt_threads=$(mrtg_fetch_review_threads "$PR_URL")
    check_maintainer_review_threads "$_mrt_threads" "$_mrt_head_date" "${BOT_USER:-donpetry-bot}"
  ) || {
    mrt_gate_rc=$?
    if [ "$mrt_gate_rc" -eq 1 ]; then
      echo "    skip: unaddressed maintainer review thread postdates last push — withholding approval (#1415)"
      # Dismiss any existing pr-review-agent APPROVED review at head so the PR
      # remains blocked until the maintainer thread is addressed (best-effort).
      if [ "${DRY_RUN:-false}" != "true" ]; then
        _agent_approval=$(echo "$PR_SNAPSHOT" | jq -r --arg bot "${BOT_USER:-donpetry-bot}" --arg sha "$PR_HEAD_SHA" 'first((.reviews // [])[] | select(.author?.login == $bot and .state == "APPROVED" and .commit?.oid == $sha) | .id) // empty' 2>/dev/null || true)
        if [ -n "$_agent_approval" ]; then
          gh api graphql -f query='mutation($id:ID!,$msg:String!){dismissPullRequestReview(input:{pullRequestReviewId:$id,message:$msg}){clientMutationId}}' -f id="$_agent_approval" -f msg="Dismissing approval due to unaddressed maintainer review thread (#1415)" 2>/dev/null || echo "    warn: could not dismiss prior approval"
          # The queue checks reviews only at enqueue; drop a queued PR left with no approval (#2174).
          mq_dequeue_if_unapproved "$PR_URL" || true
        fi
      fi
      emit_verdict skip unaddressed-maintainer-review-thread "the maintainer review thread is resolved and a new commit is pushed, or an @mention (FORCE_REVIEW) overrides the gate"
      exit 100
    elif [ "$mrt_gate_rc" -eq 2 ]; then
      echo "    error: maintainer-review-thread gate could not evaluate the review threads — failing closed to avoid uninformed approval"
      emit_verdict error maintainer-review-thread-gate-error "the gate can determine review-thread authorship and head push-time; the next scheduled pr-review sweep retries this PR"
      exit 1
    else
      exit "$mrt_gate_rc"
    fi
  }
fi

# Skip when a human has requested changes, with two guards:
#   1. FORCE_REVIEW bypasses the skip — mention-triggered runs always proceed so
#      authors can request a re-review after addressing feedback.
#   2. Only skip when a CHANGES_REQUESTED review targets the current head SHA.
#      On repos that don't dismiss stale reviews, reviewDecision can stay
#      CHANGES_REQUESTED after the author pushes new commits; in that case the
#      review is stale and the cascade should re-engage with the updated code.
if [ "$REVIEW_DECISION" = "CHANGES_REQUESTED" ] && [ "${FORCE_REVIEW:-false}" != "true" ]; then
  CHANGES_REQUESTED_AT_HEAD=$(echo "$PR_SNAPSHOT" | jq -r --arg sha "$PR_HEAD_SHA" '
    [.reviews[] | select(.state == "CHANGES_REQUESTED" and .commit.oid == $sha)]
    | if length > 0 then "true" else "false" end
  ')
  if [ "$CHANGES_REQUESTED_AT_HEAD" = "true" ]; then
    echo "    skip: changes requested at current head — awaiting author response before reviewing"
    emit_verdict skip changes-requested "the author pushes a new commit (making the CHANGES_REQUESTED review stale), or @mentions the bot for a re-review"
    exit 100
  fi
fi

# 2. Idempotency: look for our marker at this SHA in existing reviews+comments.
# We tag every review/comment with reviews' submittedAt / comments' createdAt,
# concatenate, sort by timestamp ascending, and take the latest body that
# contains our marker. The previous implementation used `tail -1` over a
# `(reviews + comments)` array concatenation, which depends on array order
# rather than timestamp — when an old comment with a marker existed alongside
# newer reviews with markers, it picked the wrong (older) marker SHA and
# we re-reviewed the same head SHA on every run.
# Capture the latest marker's full body (not just its SHA) so the metadata-digest
# re-arm (#1551) can inspect a `meta=<digest>` attribute if one is present.
# Trust only markers authored by OUR bot (BOT_USER). The marker text is not a
# capability — any user who can comment on the PR could paste a forged
# `<!-- pr-review-agent v1 sha=<head> decision=approved -->` marker, and an
# unauthenticated read of the "latest marker" would then treat it as a standing
# verdict — enough to drive the carry-forward gate below into re-issuing a REAL
# bot approval for code no tier ever reviewed. Filtering on .author.login binds
# the verdict to the identity that actually posts it (#1870 security review).
# Filter with a real jq (--arg) rather than gh's embedded --jq, which takes no args.
_MARKER_SRC_JSON=$(gh pr view "$PR_URL" --json reviews,comments 2>/dev/null || echo '{}')
LATEST_MARKER_BODY=$(
  jq -r --arg bot "${BOT_USER:-donpetry-bot}" '
      ((.reviews   // [] | map(select((.author?.login // "") == $bot) | {when: .submittedAt, body: .body})) +
       (.comments  // [] | map(select((.author?.login // "") == $bot) | {when: .createdAt,   body: .body})))
      | map(select(.body != null and (.body | test("<!-- pr-review-agent v1 sha=[a-f0-9]+"))))
      | sort_by(.when)
      | last
      | .body // ""
    ' <<<"$_MARKER_SRC_JSON" 2>/dev/null || true
)
EXISTING_MARKER_SHA=$(
  # Bash parameter expansion for the first line instead of a `head -1` pipe, which
  # can raise SIGPIPE (exit 141) under `set -o pipefail`.
  matches=$(printf '%s' "$LATEST_MARKER_BODY" \
    | grep -oE '<!-- pr-review-agent v1 sha=[a-f0-9]+' \
    | grep -oE '[a-f0-9]+$' || true)
  printf '%s' "${matches%%$'\n'*}"
)

if [ -n "${EXISTING_MARKER_SHA:-}" ] && [ "$EXISTING_MARKER_SHA" = "$PR_HEAD_SHA" ]; then
  # Two flags bypass the same-SHA idempotency no-op, but they are NOT interchangeable
  # (issue #1590). FORCE_REVIEW is the human @mention break-glass: it bypasses EVERY
  # gate (ci-failing/ci-pending/advisory/maintainer/…). FORCE_RE_REVIEW is the narrow
  # mode used by the automated orphan-rescue sweep: it clears ONLY this idempotency
  # marker and leaves all the quality gates above armed — so a forced re-review on a
  # crashed orphan marker still respects a CI status that went red after the sweep's
  # snapshot (the TOCTOU the sweep otherwise papered over). Every other gate keys on
  # FORCE_REVIEW alone; only this no-op honors FORCE_RE_REVIEW as well.
  #
  # FORCE_RE_REVIEW is orphan-only. The sweep dispatches it off a snapshot where the
  # head marker is a crashed orphan (marker stamped, no verdict). Between that snapshot
  # and this execution a genuine verdict can land at the same head — re-checked here on
  # the fresh snapshot — and bypassing idempotency for it would re-run a completed
  # review (a duplicate cascade). So FORCE_RE_REVIEW bypasses only while the head marker
  # is still an orphan; once a verdict is present it defers to the normal no-op. The
  # verdict shapes (bound to the head marker, per scripts/lib/review-cycle.sh and
  # scripts/sweep-stuck-reviews.sh):
  #   approval/escalated — `<!-- pr-review-agent v1 sha=<HEAD> decision=approved|escalated …`
  #   fix-request        — `<!-- pr-review-agent v1 sha=<HEAD> -->` + `<!-- decision=fix-requested …`
  # FORCE_REVIEW (human break-glass) still bypasses unconditionally, verdict or not.
  VERDICT_AT_HEAD=false
  # Anchored on the full `<!-- pr-review-agent v1 sha=` opener and bounded after the
  # decision word so prose that merely quotes the text, or `decision=approvedX`, is
  # not a verdict.
  verdict_re="<!-- pr-review-agent v1 sha=${PR_HEAD_SHA}[[:space:]]+decision=(approved|escalated)([^[:alnum:]_]|$)"
  fix_marker_re="<!-- pr-review-agent v1 sha=${PR_HEAD_SHA} -->"
  if [[ "$LATEST_MARKER_BODY" =~ $verdict_re ]]; then
    VERDICT_AT_HEAD=true
  elif [[ "$LATEST_MARKER_BODY" =~ $fix_marker_re ]] \
       && [[ "$LATEST_MARKER_BODY" =~ decision=fix-requested ]]; then
    VERDICT_AT_HEAD=true
  fi
  # #1933: an approval verdict at head that pr-review's OWN gate later dismissed
  # (#1813 comment disposition, #1415 maintainer thread) is "pending
  # re-evaluation", not "reviewed". Every gate above has just passed on this run,
  # so the condition that caused the dismissal has cleared: re-run the full
  # cascade (gates stay armed — this never re-posts an approval by itself). A
  # human's dismissal, the #1596 accepted-defect dismissal, or an unreadable
  # timeline keeps the no-op (lib/self-dismissed-approval.sh fails closed).
  SELF_DISMISSED_REEVAL=false
  approved_at_head_re="<!-- pr-review-agent v1 sha=${PR_HEAD_SHA}[[:space:]]+decision=approved([^[:alnum:]_]|$)"
  if [ "${FORCE_REVIEW:-false}" != "true" ] && [[ "$LATEST_MARKER_BODY" =~ $approved_at_head_re ]] \
     && [[ "$PR_URL" =~ /pull/([0-9]+) ]] \
     && sda_check_pr "$_OWNER_REPO" "${BASH_REMATCH[1]}" "$PR_HEAD_SHA" "${BOT_USER:-donpetry-bot}"; then
    SELF_DISMISSED_REEVAL=true
  fi
  if [ "${FORCE_REVIEW:-false}" = "true" ] \
     || { [ "${FORCE_RE_REVIEW:-false}" = "true" ] && [ "$VERDICT_AT_HEAD" != "true" ]; }; then
    echo "    force-review: prior marker $PR_HEAD_SHA matches head, but FORCE_REVIEW/FORCE_RE_REVIEW=true — re-running cascade (idempotency bypass)"
  elif [ "$SELF_DISMISSED_REEVAL" = "true" ]; then
    echo "    re-review: pr-review's approval at $PR_HEAD_SHA was dismissed by its own gate, and every gate now passes — re-evaluating at the same head (#1933)"
  else
    # Metadata-digest re-arm (#1551). A metadata-only fix-request stamps
    # `meta=<digest>` (body + closingIssuesReferences + labels) into its marker.
    # When that digest is present but the current PR metadata no longer matches
    # it, the demanded metadata fix has landed with no new commit — proceed with
    # the re-review instead of no-oping. Approval markers and code-change
    # fix-requests carry no `meta=`, so they keep the exact same-SHA no-op
    # behavior (AC3) and the churn breaker (cycle cap + budget) stays authoritative.
    MARKER_META_DIGEST=$(marker_meta_digest "$LATEST_MARKER_BODY")
    if [ -n "${MARKER_META_DIGEST:-}" ]; then
      CURRENT_META_DIGEST=$(compute_pr_metadata_digest "$PR_SNAPSHOT")
      if [ "$MARKER_META_DIGEST" != "$CURRENT_META_DIGEST" ]; then
        echo "    re-review: metadata changed since a metadata-only fix-request at $PR_HEAD_SHA (marker meta=$MARKER_META_DIGEST, current=$CURRENT_META_DIGEST) — re-reviewing without a new commit (#1551)"
        # Slice 1 of #1589 (OBSERVE-ONLY): the #1551 re-arm above is reachable at
        # the SAME head SHA, so two triggers can both read this stale marker, both
        # see the digest mismatch, and BOTH launch the cascade — a duplicate the
        # #1551 fix newly made reachable. We do NOT arbitrate yet (slice 2); we
        # only make the race observable. Post a per-PR claim marker keyed on
        # (head SHA, current metadata digest) BEFORE the cascade, then read back
        # live claims for the same key. If another run has already claimed the
        # same key, record a #1552-style decision/reason line and proceed exactly
        # as before — behaviour is unchanged.
        CLAIM_RUN_TOKEN="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-$$-${RANDOM}"
        CLAIM_MARKER_BODY="$(claim_marker "$PR_HEAD_SHA" "$CURRENT_META_DIGEST" "$CLAIM_RUN_TOKEN" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
        if [ "${DRY_RUN:-false}" != "true" ]; then
          gh pr comment "$PR_URL" --body "$CLAIM_MARKER_BODY" >/dev/null 2>&1 \
            || echo "    warn: could not post pr-review claim marker (#1589 slice 1)"
        fi
        CLAIM_COMMENTS_JSON="$(gh pr view "$PR_URL" --json comments --jq '.comments')"
        if concurrent_claim_present "$CLAIM_RUN_TOKEN" "$PR_HEAD_SHA" "$CURRENT_META_DIGEST" "$CLAIM_COMMENTS_JSON"; then
          echo "    concurrent-claim: another live re-review claim exists for the same key (sha=$PR_HEAD_SHA meta=$CURRENT_META_DIGEST) — proceeding (slice 1 observe-only, #1589)"
          emit_verdict proceed concurrent-claim-detected "slice 2 (#1589) arbitrates the earliest-posted claim as the winner so a losing run no-ops instead of both launching the cascade"
        fi
      else
        echo "    noop: already reviewed at $PR_HEAD_SHA — re-arms on a new commit or a metadata change (PR body, labels, or linked issues)"
        emit_verdict noop already-reviewed-at-head "a new commit moves the head SHA, a metadata change (PR body, labels, or linked issues) updates the marker digest, or an @mention (FORCE_REVIEW) forces a re-review at the same SHA"
        # Exit 100 is the no-op sentinel: the caller can skip this PR without
        # counting it against the MAX_PRS budget of actual reviews.
        exit 100
      fi
    else
      echo "    noop: already reviewed at $PR_HEAD_SHA — re-arms on a new commit"
      emit_verdict noop already-reviewed-at-head "a new commit moves the head SHA, or an @mention (FORCE_REVIEW) forces a re-review at the same SHA"
      # Exit 100 is the no-op sentinel: the caller can skip this PR without
      # counting it against the MAX_PRS budget of actual reviews.
      exit 100
    fi
  fi
fi

if [ -n "${EXISTING_MARKER_SHA:-}" ]; then
  echo "    re-review: prior marker was $EXISTING_MARKER_SHA, head is $PR_HEAD_SHA"
fi

# Carry-forward for conflict-free base merges (issue #1865). When the last
# recorded verdict was an APPROVAL at an earlier head SHA and every intervening
# commit is a conflict-free base merge that leaves the diff-vs-merge-base
# byte-identical, re-issue the prior approval at the new head SHA instead of
# re-running the tier stack. This breaks the auto-rebase treadmill:
# strict_required_status_checks_policy mints a new head SHA on every open PR
# after each merge, and keying idempotency on the head SHA (#899) otherwise
# forces a full re-review of every PR on every merge. evaluate_carry_forward is
# fail-safe: any other delta (a resolved conflict — AC #2, a content commit —
# AC #3, or any indeterminable comparison — AC #4) returns full:<reason> and
# falls through to the normal cascade below. Scoped to prior==approved: an
# escalation or fix-request is not a standing verdict to re-issue, and forced
# re-reviews (human @mention or the orphan-rescue sweep) always run the cascade.
if [ -n "${EXISTING_MARKER_SHA:-}" ] \
   && [ "$EXISTING_MARKER_SHA" != "$PR_HEAD_SHA" ] \
   && [ "${FORCE_REVIEW:-false}" != "true" ] \
   && [ "${FORCE_RE_REVIEW:-false}" != "true" ] \
   && [ "$(cf_prior_decision "$LATEST_MARKER_BODY")" = "approved" ]; then
  CF_RESULT=$(evaluate_carry_forward "$_OWNER_REPO" "$PR_BASE_REF" "$EXISTING_MARKER_SHA" "$PR_HEAD_SHA")
  # Race guard (#1870 review): evaluate_carry_forward made several network round-trips
  # against $PR_HEAD_SHA. A content commit landing during that window advances the head,
  # so posting now would stamp an approval on a SHA whose code no tier reviewed. Re-read
  # the live head and only carry when it still equals the SHA we evaluated; if it moved
  # (or can't be re-confirmed), decline and let the next trigger re-evaluate the new head.
  CF_HEAD_NOW=""
  [ "$CF_RESULT" = "carry" ] && CF_HEAD_NOW=$(gh pr view "$PR_URL" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")
  if [ "$CF_RESULT" = "carry" ] && [ "$CF_HEAD_NOW" != "$PR_HEAD_SHA" ]; then
    echo "    carry-forward: declined (head is now '${CF_HEAD_NOW:-unknown}', evaluated '$PR_HEAD_SHA' — a commit landed mid-evaluation or the head could not be re-confirmed; running the full review cascade so no approval is stamped for unreviewed content) (#1870)"
  elif [ "$CF_RESULT" = "carry" ]; then
    echo "    carry-forward: every commit since $EXISTING_MARKER_SHA is a conflict-free base merge with a byte-identical diff-vs-merge-base — re-issuing the prior approval at $PR_HEAD_SHA without running any model tier (#1865)"
    CF_RISK=$(cf_prior_risk "$LATEST_MARKER_BODY")
    mkdir -p /tmp/cascade
    CF_VERDICT_JSON="/tmp/cascade/carry-forward-verdict.json"
    CF_BODY="<!-- pr-review-agent v1 sha=$PR_HEAD_SHA decision=approved risk=$CF_RISK -->
<!-- pr-review-agent carry-forward from=$EXISTING_MARKER_SHA to=$PR_HEAD_SHA -->

## Review — approved (carried forward)

Re-issuing the prior approval from \`$EXISTING_MARKER_SHA\` unchanged. Every commit since then is a conflict-free merge of the base branch (\`$PR_BASE_REF\`) and the diff against the merge base is byte-identical, so no code authored by this PR has changed. No model review was run for this base-only update.

_Carried forward automatically by the PR-review cascade (issue #1865)._"
    jq -n --arg risk "$CF_RISK" --arg body "$CF_BODY" \
      '{decision:"approve", risk:$risk, summary:"carried forward", findings:[], body:$body, metadata_only:false}' \
      > "$CF_VERDICT_JSON"
    bash "$REVIEW_OUTPUT_CHANNEL" "$PR_URL" "$CF_VERDICT_JSON" "${DRY_RUN:-false}"
    # emit_verdict LAST so review-batch's reason parser reads carried-forward as
    # the final verdict line. Exit 100 is the no-op sentinel: a carry-forward is
    # cheap (no tier) and must NOT consume the MAX_PRS budget of full reviews, so
    # a single batch can clear the whole treadmill of base-merged PRs in one run.
    emit_verdict carried-forward carried-forward "a new commit that is not a conflict-free base merge, a resolved-conflict merge, or any change to the diff-vs-merge-base forces a full re-review"
    exit 100
  fi
  # Reached only when evaluate_carry_forward itself returned full:<reason> (the race
  # guard above prints its own decline line and also falls through to the cascade).
  if [ "$CF_RESULT" != "carry" ]; then
    echo "    carry-forward: declined ($CF_RESULT) — running the full review cascade (#1865)"
  fi
fi

# Count how many NON-CONVERGING review cycles we've done on this PR.
# This prevents infinite review loops (AI-delegation OR cascade-only) without
# punishing PRs that are converging (issue #467): compute_review_cycle counts
# only non-approval markers newer than the most recent reset event (latest
# approval marker or latest escalation comment). An approval, or a human
# re-engaging after escalation, grants a fresh budget of MAX_REVIEW_CYCLES.
# Reuse the snapshot fetched at the top of the script instead of a second
# `gh pr view` round-trip (review feedback: saves an API call per PR).
# author/state are carried so compute_review_cycle can human-gate the reset
# (#926): only a human approval (review state=APPROVED by a non-bot) resets.
PR_ITEMS=$(
  echo "$PR_SNAPSHOT" | jq '
    ((.reviews  // [] | map({when: .submittedAt, body: .body, author: (.author?.login // ""), state: .state})) +
     (.comments // [] | map({when: .createdAt,   body: .body, author: (.author?.login // ""), state: null})))
    | map(select(.body != null or .state != null))' 2>/dev/null || echo '[]'
)
REVIEW_CYCLE=$(compute_review_cycle "$PR_ITEMS")
export REVIEW_CYCLE
MAX_CYCLES="${MAX_REVIEW_CYCLES:-3}"
echo "    review cycle: $REVIEW_CYCLE (max: $MAX_CYCLES)"

# Escalation handling (issue #467). Once a PR is escalated to a human, the
# cascade pauses — but not unconditionally:
#   1. FORCE_REVIEW=true (mention-triggered) always proceeds. An explicit
#      human request IS the human-in-the-loop the cap exists to obtain; we
#      also drop the needs-human-review label so the cascade stays engaged
#      on subsequent scheduled runs.
#   2. Otherwise we pause only while the `needs-human-review` label is still
#      present. Removing the label re-engages the cascade exactly as the
#      escalation comment promises (previously the label was never consulted,
#      so a capped PR was permanently un-reviewable).
# Markers older than the escalation comment don't count toward the next cap
# (see compute_review_cycle), so re-engagement starts with a fresh budget
# instead of immediately re-escalating.
if has_escalation_marker "$PR_ITEMS"; then
  HAS_HUMAN_LABEL=$(echo "$PR_SNAPSHOT" | jq -r '[.labels // [] | .[].name] | any(. == "needs-human-review")')
  if [ "${FORCE_REVIEW:-false}" = "true" ]; then
    echo "    force-review: escalation marker present, but FORCE_REVIEW=true — re-engaging cascade"
    # Do NOT pre-emptively strip the label here (#1754 AC3). The final decision
    # owns it: an approval or fix-request clears the hold in post-pr-review.sh,
    # while a re-escalation leaves it in place idempotently. Removing it here and
    # having the re-escalation re-add it was the unlabel-then-relabel churn (four
    # toggles in a day on an unchanged PR).
  elif [ "$HAS_HUMAN_LABEL" = "true" ]; then
    echo "    noop: human-escalation active (needs-human-review label present) — remove the label or mention the bot to re-engage"
    emit_verdict noop human-escalated "a human removes the needs-human-review label, or @mentions the bot to re-engage the cascade"
    exit 100
  else
    echo "    re-engage: escalation marker present but needs-human-review label removed — resuming cascade"
  fi
fi

# Cycle cap: MAX_REVIEW_CYCLES consecutive non-converging cycles → escalate to
# a human. We post a single escalation comment marked with
# `<!-- pr-review-agent escalation -->`; the block above detects it (together
# with the needs-human-review label) and no-ops without spamming.
# FORCE_REVIEW bypasses the cap: a mention-triggered run must deliver the
# review it acknowledged, never silently no-op.
if [ "${FORCE_REVIEW:-false}" != "true" ] && [ "$REVIEW_CYCLE" -ge "$MAX_CYCLES" ]; then
  echo "    cap: review cycle $REVIEW_CYCLE >= max $MAX_CYCLES — escalating to human"
  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "    DRY_RUN: would post escalation comment, add label, request reviewer"
  else
    ESCALATION_BODY="/tmp/cascade/escalation-comment.txt"
    mkdir -p /tmp/cascade
    cat > "$ESCALATION_BODY" <<ESCALATION_END
<!-- pr-review-agent escalation -->

## Automated review — human attention needed

This PR has been through $REVIEW_CYCLE automated review cycles since the last approval or escalation (cap: $MAX_CYCLES) without converging. Further automated review has been paused to avoid infinite loops.

Please take a look manually, or close this PR if it's no longer needed. To re-engage the automated cascade with a fresh cycle budget, a human should remove the \`needs-human-review\` label after reviewing. Re-engagement is intentionally human-gated (#926): mentioning the bot will not reset the cap.

_Posted by the ${BOT_USER:-donpetry-bot} PR-review cascade._
ESCALATION_END
    gh pr comment "$PR_URL" --body-file "$ESCALATION_BODY" || echo "    warn: gh pr comment failed — escalation marker not posted; will retry next cycle"
    gh pr edit "$PR_URL" --add-label needs-human-review 2>/dev/null || true
    bash "$SCRIPT_DIR/request-codeowners-review.sh" "$PR_URL" || true
    rm -f "$ESCALATION_BODY"
  fi
  emit_verdict escalate max-cycles-reached "a human removes the needs-human-review label to grant a fresh cycle budget (an @mention will not reset the cap)"
  # Exit 101 is the human-escalation sentinel (#1754 AC1): a delivered escalation
  # is counted as `escalated`, not a no-op. A DRY_RUN posted nothing, so it stays 100.
  if [ "${DRY_RUN:-false}" = "true" ]; then
    exit 100
  fi
  exit 101
fi

# Per-PR automation budget (#926): bound TOTAL automated activity on this PR over
# its lifetime — agent commits + review cycles + acks since the last human
# interaction. Unlike the cycle cap, FORCE_REVIEW does NOT bypass this: the self-
# mention ack that defeated every other guard must not be able to re-arm it. Only
# a human interaction resets the budget. On exhaustion enforce_pr_budget escalates
# once (deduped comment + needs-human-review + auto-merge off) and we stop.
if [ "${DRY_RUN:-false}" != "true" ]; then
  PR_BUDGET_NUMBER=$(echo "$PR_URL" | sed -E 's|.*/pull/([0-9]+).*|\1|')
  PR_BUDGET_REPO=$(echo "$PR_URL" | sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|')
  # enforce_pr_budget reports (PR_AUTOMATION_NEWLY_ESCALATED) whether THIS run
  # created the escalation: that run exits 101 (counted `escalated`, #1754 AC1);
  # later runs that only find the budget already exhausted are holds and keep 100.
  if enforce_pr_budget "$PR_BUDGET_NUMBER" "$PR_BUDGET_REPO"; then
    echo "    cap: per-PR automation budget exhausted — halting automated review (escalated to human)"
    emit_verdict escalate automation-budget-exhausted "a human interaction (comment or approval) resets the per-PR automation budget"
    if [ "${PR_AUTOMATION_NEWLY_ESCALATED:-false}" != "true" ]; then
      exit 100
    fi
    exit 101
  fi
elif [ "${PR_REVIEW_DIAGNOSE:-false}" = "true" ]; then
  # Read-only: report an exhausted budget without escalating (enforce_pr_budget writes).
  # An unreadable event list is not "budget remaining": report it, never gates-clear.
  _diag_rc=0
  _diag_events=$(gather_pr_automation_events \
      "$(echo "$PR_URL" | sed -E 's|.*/pull/([0-9]+).*|\1|')" \
      "$(echo "$PR_URL" | sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|')") || _diag_rc=$?
  if [ "$_diag_rc" -ne 0 ]; then
    emit_verdict error automation-budget-unreadable "the PR's commits, comments and reviews become readable (a GitHub API error); re-run the diagnostic"
    exit 100
  fi
  if pr_budget_exhausted "$_diag_events"; then
    emit_verdict escalate automation-budget-exhausted "a human interaction (comment or approval) resets the per-PR automation budget"
    exit 100
  fi
fi

# Diagnose mode stops here: every gate has passed, so a review run would now start
# the model cascade, whose own verdict (approve / fix-request / escalate) decides.
if [ "${PR_REVIEW_DIAGNOSE:-false}" = "true" ]; then
  echo "    diagnose: every gate passes — a review run would start the model cascade now"
  emit_verdict proceed gates-clear "nothing gates this PR; the next pr-review run reviews it and its verdict decides (a review event, a push, or the pr-review sweep starts that run)"
  exit 0
fi

# Detect if the PR's repo org supports AI delegation for automated fix requests.
# Reads DELEGATION_ORGS (falls back to CLAUDE_ORGS for backward compat).
PR_ORG=$(echo "$PR_URL" | sed -E 's|https://github.com/([^/]+)/.*|\1|')
export PR_ORG
AI_DELEGATION_ENABLED=false
DELEGATION_ORGS="${DELEGATION_ORGS:-${CLAUDE_ORGS:-}}"
if [ -n "${DELEGATION_ORGS:-}" ]; then
  IFS=',' read -ra ORG_LIST <<< "$DELEGATION_ORGS"
  for org in "${ORG_LIST[@]}"; do
    if [ "$(echo "$org" | tr -d ' ')" = "$PR_ORG" ]; then
      AI_DELEGATION_ENABLED=true
      break
    fi
  done
fi
export AI_DELEGATION_ENABLED
echo "    AI delegation: $AI_DELEGATION_ENABLED (org: $PR_ORG)"

# For re-reviews, extract the prior review body for context.
# Write to a temp file to avoid hitting OS env size limits (E2BIG) on large reviews.
PRIOR_REVIEW_BODY=""
PRIOR_REVIEW_SHA=""
PRIOR_REVIEW_FILE="/tmp/cascade/prior-review-body.txt"
mkdir -p /tmp/cascade
if [ -n "${EXISTING_MARKER_SHA:-}" ]; then
  PRIOR_REVIEW_SHA="$EXISTING_MARKER_SHA"
  PRIOR_REVIEW_BODY=$(
    gh pr view "$PR_URL" --json reviews,comments \
      --jq "((.reviews // []) + (.comments // [])) | .[].body | select(. != null) | select(test(\"sha=$PRIOR_REVIEW_SHA\"))" 2>/dev/null \
    | tail -n 1 || true
  )
  # Validate that the matched body actually contains our marker to reduce
  # prompt-injection surface area.
  if [ -n "$PRIOR_REVIEW_BODY" ] && ! [[ "$PRIOR_REVIEW_BODY" =~ pr-review-agent\ v1\ sha=[a-f0-9]+\ --\> ]]; then
    echo "    prior review body missing valid marker, discarding"
    PRIOR_REVIEW_BODY=""
  fi
  echo "    prior review: SHA=$PRIOR_REVIEW_SHA body=${#PRIOR_REVIEW_BODY}chars"
  if [ -n "$PRIOR_REVIEW_BODY" ]; then
    echo "$PRIOR_REVIEW_BODY" > "$PRIOR_REVIEW_FILE"
  fi
fi
export PRIOR_REVIEW_SHA PRIOR_REVIEW_FILE
# Export a truncated summary for env; full body is in PRIOR_REVIEW_FILE.
export PRIOR_REVIEW_BODY="${PRIOR_REVIEW_BODY:0:4000}"

# ==========================================================================
# 3. Cascading review: triage → deep review → security audit
#    Each tier only fires if the previous one escalated.
# ==========================================================================

mkdir -p /tmp/cascade

# --- Tier 1: Triage (fast, no tools, pre-fetched context) ---
echo "    [tier1] triage ($ENGINE_TRIAGE_MODEL)"

# Pre-fetch all context. The triage model has NO tools, so we inline every
# field it needs into the prompt itself. (Earlier versions exported these as
# env vars and expected the prompt to reference $PR_METADATA / $PR_DIFF —
# but `claude --print` does not interpolate shell variables into the prompt,
# so the model only ever saw the literal text "$PR_METADATA" and reported
# the data as missing. Inlining the values is the fix.)
_gh_meta_err=/tmp/cascade/gh-meta-prefetch.err
_gh_diff_err=/tmp/cascade/gh-diff-prefetch.err
_gh_diff_tmp=/tmp/cascade/gh-diff-raw.txt

# Use a selective list of fields to avoid hitting payload limits with 
# massive comment histories or redundant file lists.
_meta_fields="number,title,body,author,isDraft,baseRefName,headRefName,headRefOid,url,labels,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,reviewRequests,closingIssuesReferences,additions,deletions,changedFiles"
# We exclude 'comments', 'reviews', 'commits', 'files' from the primary JSON
# if they are likely to be massive. We'll add a simplified summary of them.

PR_METADATA=$(gh pr view "$PR_URL" --json "$_meta_fields,files" --jq '
  # Simplify the files list to just path + status + changes to save tokens
  .files |= map({path: .path, status: .status, additions: .additions, deletions: .deletions})
  | .
' 2>"$_gh_meta_err") || {
  _gh_meta_err_content=$(cat "$_gh_meta_err" 2>/dev/null || true)
  if is_rate_limited "$_gh_meta_err_content"; then
    rm -f "$_gh_meta_err" "$_gh_diff_err" "$_gh_diff_tmp"
    echo "    gh API rate limited on metadata fetch — skipping PR (will retry next run)"
    emit_verdict skip gh-rate-limited "the GitHub API rate limit resets and the next scheduled pr-review sweep retries this PR"
    exit 100
  fi
  echo "::error::gh pr view failed during metadata prefetch for $PR_URL"
  [ -n "$_gh_meta_err_content" ] && echo "    $_gh_meta_err_content"
  rm -f "$_gh_meta_err" "$_gh_diff_err" "$_gh_diff_tmp"
  exit 1
}

# For Copilot, we keep context moderate (8k-16k) to avoid session costs.
# For Claude/Gemini, we can afford more context (up to 32k+).
if [ "${REVIEW_ENGINE:-claude}" = "copilot" ]; then
  _diff_limit=1000
else
  _diff_limit=3000
fi

if gh pr diff "$PR_URL" > "$_gh_diff_tmp" 2>"$_gh_diff_err"; then
  PR_DIFF=$(head -"$_diff_limit" "$_gh_diff_tmp")
  # The full, untruncated diff stays on disk in $_gh_diff_tmp until the cleanup
  # below — the context prefetch (Story 2) reuses it, so no extra diff fetch.
  _prefetch_full_diff_file="$_gh_diff_tmp"
else
  _gh_diff_err_content=$(cat "$_gh_diff_err" 2>/dev/null || true)
  if is_rate_limited "$_gh_diff_err_content"; then
    rm -f "$_gh_meta_err" "$_gh_diff_err" "$_gh_diff_tmp"
    echo "    gh API rate limited on diff fetch — skipping PR (will retry next run)"
    emit_verdict skip gh-rate-limited "the GitHub API rate limit resets and the next scheduled pr-review sweep retries this PR"
    exit 100
  fi
  if is_diff_too_large "$_gh_diff_err_content"; then
    # GitHub's unified-diff endpoint is hard-capped at 300 changed files (HTTP 406).
    # Fall back to the per-file REST API which works above the cap: each entry carries
    # its own patch, so we assemble a truncated diff and continue the review normally.
    _changed_files=$(echo "$PR_METADATA" | jq -r '.changedFiles // "unknown"' 2>/dev/null || echo "unknown")
    echo "    diff too large (${_changed_files} files exceeds GitHub 300-file unified-diff cap) — assembling diff from per-file REST API"
    _owner_repo_fallback=$(echo "$PR_URL" | sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|')
    _pr_num_fallback=${PR_URL##*/}
    _fallback_tmp=$(mktemp 2>/dev/null || echo "/tmp/cascade/fallback-diff-$$.txt")
    _fallback_err=$(mktemp 2>/dev/null || echo "/tmp/cascade/fallback-err-$$.txt")
    {
      printf '# NOTE: diff assembled from per-file REST API (%s changed files exceeded\n' "$_changed_files"
      printf "# GitHub's 300-file unified-diff cap; patches may be partial or absent for large files).\n"
      gh api "repos/$_owner_repo_fallback/pulls/$_pr_num_fallback/files" \
        --paginate --slurp \
        | jq -r 'add | .[]? | if .patch then "diff --git a/\(.filename) b/\(.filename)\n--- a/\(.filename)\n+++ b/\(.filename)\n\(.patch)" else "# \(.status): \(.filename) (no patch — binary or large file)" end' \
        2>"$_fallback_err" || {
          echo "::warning::REST API fallback also failed — review will have partial diff" >&2
          cat "$_fallback_err" >&2 || true
        }
    } > "$_fallback_tmp"
    PR_DIFF=$(head -"$_diff_limit" "$_fallback_tmp")
    # Preserve the full assembled diff for the context prefetch (Story 2) to
    # reuse — it is removed in the common cleanup below. _fallback_err is done.
    _prefetch_full_diff_file="$_fallback_tmp"
    rm -f "$_fallback_err"
    unset _changed_files _owner_repo_fallback _pr_num_fallback _fallback_err
  else
    echo "::error::gh pr diff failed during prefetch for $PR_URL"
    [ -n "$_gh_diff_err_content" ] && echo "    $_gh_diff_err_content"
    rm -f "$_gh_meta_err" "$_gh_diff_err" "$_gh_diff_tmp"
    exit 1
  fi
fi
# Shared PR-context prefetch (epic #1101, Story 2). Gated DEFAULT-OFF: when
# PREFETCH_CONTEXT_ENABLED is not "true" this is a byte-identical no-op — zero
# files written, zero env vars exported, zero extra fetches. When enabled, persist
# the FULL diff (reused from the untruncated copy above — NOT the 3000-line triage
# truncation) plus a superset metadata JSON to SHA-bound files exported as
# PR_CONTEXT_DIFF_FILE / PR_CONTEXT_METADATA_FILE for the agentic tiers. A gh
# rate-limit on the one extra metadata fetch degrades to the existing skip path
# (exit 100) rather than crashing; the >300-file 406 case is already handled above
# and the reused diff is the REST assembly.
if [ "${PREFETCH_CONTEXT_ENABLED:-false}" = "true" ]; then
  _prefetch_rc=0
  prefetch_pr_context "$PR_URL" "$PR_HEAD_SHA" "${_prefetch_full_diff_file:-}" "/tmp/cascade" || _prefetch_rc=$?
  if [ "$_prefetch_rc" = "100" ]; then
    rm -f "$_gh_meta_err" "$_gh_diff_err" "$_gh_diff_tmp" "${_fallback_tmp:-}"
    echo "    gh API rate limited during context prefetch — skipping PR (will retry next run)"
    emit_verdict skip gh-rate-limited "the GitHub API rate limit resets and the next scheduled pr-review sweep retries this PR"
    exit 100
  fi
  unset _prefetch_rc
fi

rm -f "$_gh_meta_err" "$_gh_diff_err" "$_gh_diff_tmp" "${_fallback_tmp:-}"
unset _gh_meta_err _gh_diff_err _gh_diff_tmp _gh_meta_err_content _gh_diff_err_content _fallback_tmp _prefetch_full_diff_file

# Advisory bot feedback. The gate above waits for advisory bots to submit,
# but the triage tier has NO tools — unless their findings are inlined here,
# the cascade can approve without ever seeing the feedback it waited for
# (Codex P1 on PR #458). Collect, per advisory bot: the latest review body at
# the current head, the latest PR-level (issue) comment, and the most recent
# inline review comments at the current head — truncated to keep the prompt
# small. Three correctness rules (Codex follow-ups):
#   - group/sort FIRST, then drop empty bodies: a later empty approval must
#     suppress an older findings body, not resurrect it as "current";
#   - bound reviews/inline comments to PR_HEAD_SHA so findings from previous
#     heads (already fixed by newer pushes) don't trigger false escalation;
#   - PR-level issue comments (e.g. SonarCloud's quality-gate report) count
#     as advisory submissions in the gate, so include them here too. They
#     carry no commit binding — take the newest per bot.
# Best-effort: a fetch failure degrades to "(none)" rather than failing the run.
_owner_repo=$(echo "$PR_URL" | sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|')
_pr_num=${PR_URL##*/}
# Derive the triage-feedback bot set from the reviewer-source registry's
# dev-lead-trusted projection — deliberately NOT the advisory-wait gate set.
# The gate waits only on advisory_gate=yes bots (5 since #1997), but the triage
# tier (which has NO tools) must still SEE the findings of every dev-lead-trusted
# bot — including copilot/codex/qodo, which #1997 dropped from the approval-wait
# quorum yet kept trusted. Scoping this to the gate set would silently hide those
# trusted findings from triage, re-opening the Codex-P1-on-#458 blind spot the
# block above exists to close (codeant/cubic #2003 review).
_triage_bots=$(
  # shellcheck source=lib/reviewer-sources.sh
  source "$SCRIPT_DIR/lib/reviewer-sources.sh" 2>/dev/null
  _tl=$(reviewer_sources_trusted_logins 2>/dev/null) \
    && [[ -n "$_tl" ]] \
    && printf '%s\n' "$_tl" | sort | jq -R . | jq -s .
) || _triage_bots=''
if [[ -z "$_triage_bots" ]]; then
  # Last-resort fallback when sourcing the registry fails. Must equal the
  # dev_lead_trusted=yes set in scripts/lib/reviewer-sources.tsv (all 9 sources —
  # the trusted set is broader than the 5-bot advisory-wait set). Kept in sync by
  # tests/test_reviewer_sources.bats ("_triage_bots literal fallback == registry ...").
  _triage_bots='["chatgpt-codex-connector","codeant-ai","coderabbitai","copilot-pull-request-reviewer","cubic-dev-ai","gemini-code-assist","graphite-app","qodo-code-review","sonarqubecloud"]'
fi
ADVISORY_REVIEW_BODIES=$(echo "$PR_SNAPSHOT" | jq -r --argjson bots "$_triage_bots" --arg head "$PR_HEAD_SHA" '
  [(.reviews // [])[] | select([.author.login] | inside($bots)) | select(.commit.oid == $head)]
  | group_by(.author.login) | map(sort_by(.submittedAt) | last)
  | map(select(.body != null and .body != ""))
  | .[] | "--- \(.author.login) review (\(.state), \(.submittedAt)) ---\n\(.body[0:800])"
' 2>/dev/null || true)
ADVISORY_PR_COMMENTS=$(echo "$PR_SNAPSHOT" | jq -r --argjson bots "$_triage_bots" '
  [(.comments // [])[] | select([.author.login] | inside($bots))]
  | group_by(.author.login) | map(sort_by(.createdAt) | last)
  | map(select(.body != null and .body != ""))
  | .[] | "--- \(.author.login) PR comment (\(.createdAt)) ---\n\(.body[0:600])"
' 2>/dev/null || true)
# REST user.login carries a "[bot]" suffix (e.g. "gemini-code-assist[bot]"),
# unlike the GraphQL-backed `gh pr view` — strip it before matching. --slurp
# is required with --paginate: pages arrive as separate JSON arrays, and
# without slurping the sort/limit would apply per page, not across all pages.
# gh rejects --slurp together with --jq, so pipe to external jq instead.
ADVISORY_INLINE_COMMENTS=$(gh api "repos/$_owner_repo/pulls/$_pr_num/comments" --paginate --slurp 2>/dev/null \
  | jq -r --argjson bots "$_triage_bots" --arg head "$PR_HEAD_SHA" '
      add
      | map(select([.user.login | sub("\\[bot\\]$"; "")] | inside($bots)))
      | map(select(.commit_id == $head))
      | sort_by(.created_at) | reverse | .[0:15] | .[]
      | "--- \(.user.login) @ \(.path):\(.line // .original_line) (\(.created_at)) ---\n\(.body[0:600])"
    ' 2>/dev/null || true)
ADVISORY_BOT_FEEDBACK=$(printf '%s\n%s\n%s' "$ADVISORY_REVIEW_BODIES" "$ADVISORY_PR_COMMENTS" "$ADVISORY_INLINE_COMMENTS")
# Cap total size so huge bot histories can't blow up the prompt.
ADVISORY_BOT_FEEDBACK="${ADVISORY_BOT_FEEDBACK:0:8000}"
unset _owner_repo _pr_num _triage_bots ADVISORY_REVIEW_BODIES ADVISORY_PR_COMMENTS ADVISORY_INLINE_COMMENTS

# Downstream-impact pass (epic #748). Gated default-off behind the Story 5
# feature flag so that, when disabled, the triage prompt is byte-identical to
# pre-feature behavior and zero `gh` consumer-reference fetches are performed.
# When enabled: map the PR's changed files (from PR_METADATA) to the org repos
# that pin the changed reusable-workflow / lib / prompt surface, fetch each
# impacted consumer's referencing workflow, and write the human-readable block
# to a file whose path is exported as DOWNSTREAM_IMPACT_FILE for the deep/audit
# tiers (mirroring ADVISORY_BOT_FEEDBACK_FILE). The block is inlined into the
# triage prompt below (triage has NO tools). Best-effort: assemble_downstream_impact
# always exits 0, so a fetch failure degrades to "(none)" rather than failing the run.
if [ "${DOWNSTREAM_IMPACT_ENABLED:-false}" = "true" ]; then
  _di_changed=$(printf '%s' "$PR_METADATA" | jq -r '.files[]?.path // empty' 2>/dev/null || true)
  assemble_downstream_impact "$_di_changed" "$SCRIPT_DIR/lib/consumer-manifest.json" "/tmp/cascade/downstream-impact.txt" || true
  unset _di_changed
fi

# Deterministic safety-checks pass (issue #305). Safety-critical, so gated
# DEFAULT-ON: compute the SAFETY_CHECKS block from the already-fetched
# PR_METADATA + PR_DIFF (no `gh`/network) and write it to a file whose path is
# exported as SAFETY_CHECKS_FILE for the deep/audit tiers. The block is inlined
# into the triage prompt below (triage has NO tools). When SAFETY_CHECKS_ENABLED
# is explicitly "false" nothing is computed and the triage prompt stays
# byte-identical to pre-feature behavior (rollback + holdout-eval stability).
if [ "${SAFETY_CHECKS_ENABLED:-true}" = "true" ]; then
  assemble_safety_checks "$PR_METADATA" "$PR_DIFF" "/tmp/cascade/safety-checks.txt" || true
fi

# Build the triage prompt: static template + inlined PR context.
TRIAGE_PROMPT_FILE="/tmp/cascade/triage-prompt.md"
{
  cat "$RUBRIC_TRIAGE_PROMPT"
  printf '\n\n## Pre-fetched PR context\n\n'
  printf 'PR_URL: %s\n' "$PR_URL"
  printf 'PR_HEAD_SHA: %s\n' "$PR_HEAD_SHA"
  printf 'DRY_RUN: %s\n' "${DRY_RUN:-false}"
  printf 'REVIEW_MODE: triage\n'
  if [ -n "$PRIOR_REVIEW_BODY" ]; then
    printf '\nPRIOR_REVIEW_BODY:\n%s\n' "$PRIOR_REVIEW_BODY"
  else
    printf 'PRIOR_REVIEW_BODY: (empty — first review)\n'
  fi
  if [ -n "${ADVISORY_BOT_FEEDBACK//[[:space:]]/}" ]; then
    printf '\nADVISORY_BOT_FEEDBACK (latest advisory bot reviews and inline comments — weigh these findings):\n%s\n' "$ADVISORY_BOT_FEEDBACK"
  else
    printf '\nADVISORY_BOT_FEEDBACK: (none)\n'
  fi
  # #1795 AC #4: name any red NON-required check the CI gate proceeded past, so the
  # review body records "reviewed despite a red advisory check" rather than hiding
  # it. These do NOT gate merge (the ruleset does not require them); do not escalate
  # or withhold approval solely because one is red — just name it.
  if [ -n "${NON_REQUIRED_CI_FAILURES:-}" ]; then
    printf '\nNON_REQUIRED_CI_FAILURES (advisory checks that are RED but NOT required by the branch ruleset — name these in your review body; they do NOT block merge and are not a reason to withhold approval or escalate):\n%s\n' "$NON_REQUIRED_CI_FAILURES"
  fi
  # Inline the DOWNSTREAM_IMPACT block (no-op when the Story 5 flag is off, so
  # the triage prompt stays byte-identical to pre-feature behavior).
  downstream_impact_triage_section
  # Inline the deterministic SAFETY_CHECKS verdicts (issue #305). No-op when
  # SAFETY_CHECKS_ENABLED is explicitly "false", keeping the prompt byte-identical.
  safety_checks_triage_section "/tmp/cascade/safety-checks.txt"
  printf '\nPR_METADATA (JSON from `gh pr view`):\n%s\n' "$PR_METADATA"
  printf '\nPR_DIFF (truncated to 3000 lines if larger):\n%s\n' "$PR_DIFF"
} > "$TRIAGE_PROMPT_FILE"

TRIAGE_LOG="/tmp/cascade/triage.log"
TRIAGE_RC=0
TRIAGE_RESULT=$(
  run_triage "$TRIAGE_PROMPT_FILE" 2>"$TRIAGE_LOG"
) || TRIAGE_RC=$?

# Drop the bulky locals now that the prompt file is on disk. Keeps later
# subprocess forks (jq, claude) from hitting E2BIG on hundreds-of-KB diffs.
# PR_DIFF is saved as a local shell variable (not exported) for tier-2
# symbol-context assembly and unset after that pass completes.
# Advisory feedback is capped at 8 KB; write to disk for Tier 2/3 to read.
_sc_diff="${PR_DIFF:-}"
ADVISORY_BOT_FEEDBACK_FILE="/tmp/cascade/advisory-bot-feedback.txt"
rm -f "$ADVISORY_BOT_FEEDBACK_FILE"
if [[ -n "${ADVISORY_BOT_FEEDBACK//[[:space:]]/}" ]]; then
  printf '%s' "$ADVISORY_BOT_FEEDBACK" > "$ADVISORY_BOT_FEEDBACK_FILE"
fi
export ADVISORY_BOT_FEEDBACK_FILE
unset PR_DIFF PR_METADATA ADVISORY_BOT_FEEDBACK

# Detect error category before JSON validation.
# Claude Code writes its usage-cap error to stdout (captured in TRIAGE_RESULT);
# some other providers (like gh copilot) write to stderr (TRIAGE_LOG) — check both.
TRIAGE_STDERR=$(cat "$TRIAGE_LOG" 2>/dev/null || true)

# Always check stderr for rate limits (common channel for CLI/gateway errors).
if is_rate_limited "$TRIAGE_STDERR"; then
  echo "    [tier1] usage/rate limit detected on stderr — exiting with code 2 for engine fallback"
  echo "    limit stderr: $TRIAGE_STDERR"
  exit 2
fi

# If triage failed at the process level, check stdout for rate limits (common for claude --print).
if [ "$TRIAGE_RC" -ne 0 ]; then
  if is_rate_limited "$TRIAGE_RESULT"; then
    echo "    [tier1] usage/rate limit detected on stdout — exiting with code 2 for engine fallback"
    echo "    limit message: $TRIAGE_RESULT"
    exit 2
  fi

  # CLI invocation errors (bad flags, wrong syntax) are per-PR failures — exit 1
  # so the session can continue with the next PR rather than aborting entirely.
  if is_cli_error "$TRIAGE_RESULT" || is_cli_error "$TRIAGE_STDERR"; then
    echo "    [error] CLI format error — treating as per-PR failure (not a rate limit)"
    echo "    error message: ${TRIAGE_RESULT:-}${TRIAGE_STDERR:+ (stderr: $TRIAGE_STDERR)}"
    exit 1
  fi

  echo "::warning::triage exited with code $TRIAGE_RC"
  [ -n "$TRIAGE_RESULT" ] && echo "    triage stdout: $TRIAGE_RESULT"
  [ -n "$TRIAGE_STDERR" ] && echo "    triage stderr: $TRIAGE_STDERR"
  echo "::error::cascade failed at tier 1 (triage process exit $TRIAGE_RC) for $PR_URL"
  exit 1
fi

# Process exit was 0, but check for JSON validity before checking stdout for rate limits.
# (Prevents false positives if a healthy diff contains rate-limit strings).
# Strip ```json ... ``` markdown fences if the model wrapped its JSON in
# them. Haiku tends to add fences despite explicit instructions not to.
TRIAGE_RESULT_CLEAN=$(printf '%s' "$TRIAGE_RESULT" | sed -E '/^```[a-zA-Z]*$/d; /^```$/d')

if ! echo "$TRIAGE_RESULT_CLEAN" | jq empty 2>/dev/null; then
  # Not valid JSON. NOW it is safe to check for rate limits in stdout.
  if is_rate_limited "$TRIAGE_RESULT"; then
    echo "    [tier1] usage/rate limit detected in non-JSON stdout — exiting with code 2 for engine fallback"
    echo "    limit message: $TRIAGE_RESULT"
    exit 2
  fi

  echo "::warning::triage returned non-JSON output"
  echo "    triage stdout: $TRIAGE_RESULT"
  [ -n "$TRIAGE_STDERR" ] && echo "    triage stderr: $TRIAGE_STDERR"
  echo "::error::cascade failed at tier 1 (triage non-JSON) for $PR_URL"
  exit 1
fi

TRIAGE_RESULT="$TRIAGE_RESULT_CLEAN"
export TRIAGE_RESULT
TRIAGE_ESCALATE=$(echo "$TRIAGE_RESULT" | jq -r '.escalate')
TRIAGE_RISK=$(echo "$TRIAGE_RESULT" | jq -r '.risk')
TRIAGE_SIGNALS=$(echo "$TRIAGE_RESULT" | jq -r '.signals | join(", ")')
echo "    [tier1] escalate=$TRIAGE_ESCALATE risk=$TRIAGE_RISK signals=[$TRIAGE_SIGNALS]"

# HEAD-SHA freshness safeguard (epic #1101, Story 5 / #1106). Just before the
# agentic tiers (single / deep / audit) consume the Story 2 pre-fed context,
# cheaply re-check the PR's CURRENT head SHA against the SHA that prefetch
# stamped on the pre-fed files — a single `gh pr view --json headRefOid`. When
# PREFETCH_CONTEXT_ENABLED is off this is a byte-identical no-op (no gh call). If
# HEAD moved (force-push / new push mid-run), the stale pre-fed context is
# invalidated and we take the skip sentinel (exit 100) so the scheduler re-runs
# at the new SHA — never reviewing stale code. The idempotency marker prevents a
# duplicate review on the retry.
if [ "${PREFETCH_CONTEXT_ENABLED:-false}" = "true" ]; then
  _freshness_rc=0
  assert_prefetch_context_fresh "$PR_URL" "/tmp/cascade" || _freshness_rc=$?
  if [ "$_freshness_rc" = "100" ]; then
    echo "    HEAD moved since context prefetch — discarding stale pre-fed context and skipping (will retry at new SHA)"
    emit_verdict skip head-moved-stale-context "the next run observes a head SHA that stays stable through the prefetch window (no concurrent push mid-run)"
    exit 100
  fi
  unset _freshness_rc
fi

# If triage says no concerns → use single-review prompt for quick confirmation
if [ "$TRIAGE_ESCALATE" = "false" ]; then
  echo "    [approve] triage cleared — running single confirmation ($ENGINE_SINGLE_MODEL)"
  export REVIEW_MODE="triage-approved"
  VERDICT_JSON="/tmp/cascade/single-review-verdict.json"
  # SINGLE_REVIEW_MAX_RETRIES = total attempts including the first (same semantics
  # as RETRY_MAX_ATTEMPTS in engine.sh). Default 2 = initial attempt + 1 retry.
  SINGLE_REVIEW_MAX_RETRIES="${SINGLE_REVIEW_MAX_RETRIES:-2}"
  SINGLE_REVIEW_RETRY_DELAY_SEC="${SINGLE_REVIEW_RETRY_DELAY_SEC:-15}"

  single_attempt=1
  single_ok=false
  while [ "$single_attempt" -le "$SINGLE_REVIEW_MAX_RETRIES" ]; do
    rm -f "$VERDICT_JSON" "$VERDICT_JSON.raw"
    OUTPUT_FILE="$VERDICT_JSON"
    export OUTPUT_FILE
    SINGLE_LOG="/tmp/cascade/single-review-attempt-${single_attempt}.log"

    single_rc=0
    run_agentic prompts/single-review.md "$ENGINE_SINGLE_MODEL" "single" \
      > "$VERDICT_JSON.raw" 2>"$SINGLE_LOG" || single_rc=$?

    # Check error category on failure only — guards against false positives from
    # reviewed PR content that happens to mention rate-limit keywords.
    SINGLE_STDOUT=$(cat "$VERDICT_JSON.raw" 2>/dev/null || true)
    SINGLE_STDERR=$(cat "$SINGLE_LOG" 2>/dev/null || true)
    if [ "$single_rc" -ne 0 ]; then
      # CLI invocation errors are per-PR failures (exit 1), not engine fallbacks (exit 2).
      if is_cli_error "$SINGLE_STDOUT" || is_cli_error "$SINGLE_STDERR"; then
        echo "    [error] CLI format error — treating as per-PR failure (not a rate limit)"
        [ -n "$SINGLE_STDERR" ] && echo "    error stderr: $SINGLE_STDERR"
        exit 1
      fi
      # Rate-limit / overload — exit code 2 lets review-batch.sh trigger engine fallback.
      if is_rate_limited "$SINGLE_STDOUT" || is_rate_limited "$SINGLE_STDERR"; then
        echo "    [approve] rate limit detected — exiting with code 2 for engine fallback"
        [ -n "$SINGLE_STDERR" ] && echo "    limit stderr: $SINGLE_STDERR"
        exit 2
      fi
    fi

    if [ "$single_rc" -eq 0 ] && extract_verdict_json "$VERDICT_JSON.raw" "$VERDICT_JSON"; then
      EXTRACTED_DECISION=$(jq -r '.decision // ""' "$VERDICT_JSON" 2>/dev/null || true)
      case "$EXTRACTED_DECISION" in
        approve|escalate|skip)
          single_ok=true
          break
          ;;
        *)
          echo "    [approve] single-review attempt $single_attempt/$SINGLE_REVIEW_MAX_RETRIES produced invalid decision '$EXTRACTED_DECISION' — will retry"
          ;;
      esac
    else
      echo "    [approve] single-review attempt $single_attempt/$SINGLE_REVIEW_MAX_RETRIES produced no valid JSON (exit $single_rc)"
    fi
    head -20 "$VERDICT_JSON.raw" 2>/dev/null || true
    [ -n "$SINGLE_STDERR" ] && echo "    stderr: $SINGLE_STDERR"
    if [ "$single_attempt" -lt "$SINGLE_REVIEW_MAX_RETRIES" ]; then
      echo "    [approve] retrying in ${SINGLE_REVIEW_RETRY_DELAY_SEC}s"
      sleep "$SINGLE_REVIEW_RETRY_DELAY_SEC"
    fi
    single_attempt=$((single_attempt + 1))
  done

  if [ "$single_ok" = "false" ]; then
    echo "::warning::single-review failed after $SINGLE_REVIEW_MAX_RETRIES attempts — flagging for manual review"
    for i in $(seq 1 "$SINGLE_REVIEW_MAX_RETRIES"); do
      log="/tmp/cascade/single-review-attempt-${i}.log"
      [ -s "$log" ] && { echo "    attempt $i stderr:"; cat "$log"; }
    done
    if [ "${DRY_RUN:-false}" = "false" ]; then
      gh pr edit "$PR_URL" --add-label needs-human-review 2>/dev/null || true
    fi
    exit 1
  fi
  rm -f "$VERDICT_JSON.raw"

  # Post the review using the verdict. Propagate the output channel's exit status
  # (0 posted, 100 no-op, 101 escalated-to-human, non-zero error) so review-batch.sh
  # classifies the outcome correctly instead of counting an escalation as a posted
  # review (#1754).
  post_rc=0
  bash "$REVIEW_OUTPUT_CHANNEL" "$PR_URL" "$VERDICT_JSON" "$DRY_RUN" || post_rc=$?
  echo "    [done]  $PR_URL"
  exit "$post_rc"
fi

# --- Issue-type classifier -> specialist deep-review prompt (issue #1091) ---
# The triage tier classified the escalated diff with a `type` label. Resolve the
# matching specialist deep-review prompt data-driven through the rubric registry
# (deep_specialist:<type> rows). An ambiguous/absent label, a missing registry
# row, or a missing specialist file falls back to the rubric's deep prompt
# (prompts/deep-review.md) so the deep tier never dead-ends. The classifier rides
# on the existing triage output — no new tier, no extra model call.
TRIAGE_TYPE=$(classify_triage_type "$TRIAGE_RESULT")
export TRIAGE_TYPE
DEEP_TIER_PROMPT=$(resolve_deep_specialist "$TRIAGE_TYPE" "$RUBRIC_DEEP_PROMPT")

# Export safety checks and downstream impact files if they exist
if [ -f "/tmp/cascade/safety-checks.txt" ]; then
  export SAFETY_CHECKS_FILE="/tmp/cascade/safety-checks.txt"
fi
if [ -f "/tmp/cascade/downstream-impact.txt" ]; then
  export DOWNSTREAM_IMPACT_FILE="/tmp/cascade/downstream-impact.txt"
fi

# Semantic symbol-context pass (issue #1090). Runs here in tier-2 so
# triage-cleared PRs never pay the gh search code cost (only deep-review and
# rubber-duck read SYMBOL_CONTEXT_FILE). Gated default-off: when disabled
# SYMBOL_CONTEXT_FILE is never set and the deep/duck prompts + cost are
# byte-identical to pre-feature behavior (holdout-eval stability + rollback).
# Best-effort — assemble_symbol_context always exits 0, degrading to a warning.
if [ "${SYMBOL_CONTEXT_ENABLED:-false}" = "true" ]; then
  if [ -z "${GITHUB_REPOSITORY:-}" ]; then
    echo "::warning::[symbol-context] GITHUB_REPOSITORY is unset — skipping symbol context to avoid an unscoped cross-repository search" >&2
  else
    assemble_symbol_context "$_sc_diff" "$GITHUB_REPOSITORY" "/tmp/cascade/symbol-context.txt" || true
  fi
fi
unset _sc_diff

# Merged-PR few-shot injection pass (issue #1093). Runs here in tier-2 so
# triage-cleared PRs never pay for it (only the deep tier reads FEWSHOT_FILE).
# Gated default-off: when disabled FEWSHOT_FILE is never set and the deep prompt
# + cost are byte-identical to pre-feature behavior (holdout-eval stability +
# rollback). The source is a proposer-visible dev split; assemble_fewshot
# hard-refuses an evals/**/holdout source (AC #2) by returning non-zero — the
# ONLY non-zero it emits (a missing/empty/unparseable source degrades to an inert
# "(none)" and exit 0). That refusal is a deliberate hard-stop, so it is NOT
# swallowed with `|| true`: a mis-pointed holdout source must fail the run rather
# than silently teach the reviewer the held-out set.
#
# Assemble into a private per-run mktemp -d directory (0700) instead of a
# predictable /tmp/cascade path, so a co-tenant process on a shared /tmp cannot
# race assemble_fewshot to redirect or replace the prompt-visible few-shot file
# (CWE-377). The directory is removed on any script exit by the review_one_pr_cleanup
# EXIT trap (after the deep-review consumer that reads FEWSHOT_FILE has finished).
if [ "${FEWSHOT_ENABLED:-false}" = "true" ]; then
  _fewshot_dir="$(mktemp -d "${TMPDIR:-/tmp}/fewshot.XXXXXX")"
  assemble_fewshot "${FEWSHOT_SOURCE_FILE:-$SCRIPT_DIR/../evals/deep-review/dev/fewshot.jsonl}" "$_fewshot_dir/fewshot.txt"
fi

# --- Tier 2: Deep review + Rubber duck (parallel, cross-engine) ---
# The duck engines to try, in order (AI_DUCK_ENGINE / AI_ENGINES): a disabled
# or pre-flight-unavailable engine is skipped rather than failing on every
# review, and run_duck_chain falls back to the next when one writes no verdict.
# An empty list means no usable duck engine is left.
DUCK_CANDIDATES=""
if declare -F duck_engine_candidates >/dev/null 2>&1; then
  DUCK_CANDIDATES="$(duck_engine_candidates)"
elif [ -n "${DUCK_ENGINE:-}" ]; then
  DUCK_CANDIDATES="$DUCK_ENGINE ${DUCK_MODEL:-}"
fi
# A Gemini duck also needs the pre-flight probe to have passed (unset counts as
# unavailable here, unlike ai_engine_available).
# DUCK_SKIP_REASON: why no duck verdict reached this review; when set, the
# posted review body says so (duck_skip_note, #1960). Empty when the duck ran.
DUCK_SKIP_REASON=""
_duck_gemini_skipped=false
if [ "${GEMINI_AVAILABLE:-false}" != "true" ] && grep -q '^gemini ' <<< "$DUCK_CANDIDATES"; then
  echo "::notice::Skipping the Gemini duck — GEMINI_AVAILABLE=false per pre-flight probe"
  DUCK_CANDIDATES="$(grep -v '^gemini ' <<< "$DUCK_CANDIDATES" || true)"
  _duck_gemini_skipped=true
fi
DUCK_ENGINE="none"
DUCK_MODEL=""
if [ -n "$DUCK_CANDIDATES" ]; then
  read -r DUCK_ENGINE DUCK_MODEL <<< "${DUCK_CANDIDATES%%$'\n'*}"
fi
DUCK_FALLBACKS="$(sed -n '2,$p' <<< "$DUCK_CANDIDATES" | awk '{printf "%s%s (%s)", (NR>1?", ":""), $1, $2}')"
echo "    [tier2] type=$TRIAGE_TYPE specialist=$DEEP_TIER_PROMPT"
echo "    [tier2] deep review ($ENGINE_DEEP_MODEL) + rubber duck (${DUCK_MODEL:-none} via ${DUCK_ENGINE:-none}${DUCK_FALLBACKS:+; fallback: $DUCK_FALLBACKS})"

# Launch both reviewers in parallel — different model families for diversity.
# Stdout (model text output) and stderr (process errors) are kept separate so
# the rate-limit check below inspects only the model's own words, not PR content
# or tool-execution noise that could cause false positives.
OUTPUT_FILE="/tmp/cascade/deep.json"
export OUTPUT_FILE
run_agentic "$DEEP_TIER_PROMPT" "$ENGINE_DEEP_MODEL" "deep" \
  > /tmp/cascade/deep-stdout.txt 2>/tmp/cascade/deep.log &
DEEP_PID=$!

DUCK_OUTPUT="/tmp/cascade/rubber-duck.json"
DUCK_PID=""
rm -f "$DUCK_OUTPUT" "${DUCK_OUTPUT}.engine" "${DUCK_OUTPUT}.skip"
if [ "${DUCK_ENGINE:-none}" = "none" ]; then
  echo "::notice::Skipping rubber-duck reviewer — no enabled, available engine for it (AI_DUCK_ENGINE / AI_ENGINES, pre-flight probe)"
  if [ "$_duck_gemini_skipped" = true ]; then
    DUCK_SKIP_REASON="no enabled, available engine for it (Gemini unavailable per the pre-flight probe)"
  else
    DUCK_SKIP_REASON="no enabled, available engine for it (AI_DUCK_ENGINE / AI_ENGINES)"
  fi
elif declare -F run_duck_chain >/dev/null 2>&1; then
  (
    export OUTPUT_FILE="$DUCK_OUTPUT"
    run_duck_chain prompts/rubber-duck.md "$DUCK_CANDIDATES" \
      > /tmp/cascade/duck.log 2>&1
  ) &
  DUCK_PID=$!
else
  (
    export OUTPUT_FILE="$DUCK_OUTPUT"
    run_duck prompts/rubber-duck.md "$DUCK_MODEL" \
      > /tmp/cascade/duck.log 2>&1
  ) &
  DUCK_PID=$!
fi

# Wait for deep review first — if it fails, kill the duck and exit early.
# Capture the exit code explicitly; `|| true` would swallow it and prevent
# rate-limit detection when the process exits non-zero without writing JSON.
DEEP_RC=0
wait $DEEP_PID || DEEP_RC=$?

# Validate primary deep review (required).
OUTPUT_FILE="/tmp/cascade/deep.json"
if [ ! -s "$OUTPUT_FILE" ] || ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
  # Check both stdout and stderr for a rate-limit or CLI-error message.
  DEEP_STDOUT_CONTENT=$(cat /tmp/cascade/deep-stdout.txt 2>/dev/null || true)
  DEEP_STDERR_CONTENT=$(cat /tmp/cascade/deep.log 2>/dev/null || true)
  [ -n "$DUCK_PID" ] && kill $DUCK_PID 2>/dev/null || true
  [ -n "$DUCK_PID" ] && wait $DUCK_PID 2>/dev/null || true
  # CLI invocation errors are per-PR failures (exit 1), not engine fallbacks (exit 2).
  if is_cli_error "$DEEP_STDOUT_CONTENT" || is_cli_error "$DEEP_STDERR_CONTENT"; then
    echo "    [error] CLI format error — treating as per-PR failure (not a rate limit)"
    echo "${DEEP_STDOUT_CONTENT:-}${DEEP_STDERR_CONTENT:+ (stderr: $DEEP_STDERR_CONTENT)}"
    exit 1
  fi
  if is_rate_limited "$DEEP_STDOUT_CONTENT" || is_rate_limited "$DEEP_STDERR_CONTENT"; then
    echo "    [tier2] rate limit detected — exiting with code 2 for engine fallback"
    echo "${DEEP_STDOUT_CONTENT:-}${DEEP_STDERR_CONTENT:+ (stderr: $DEEP_STDERR_CONTENT)}"
    exit 2
  fi
  [ "$DEEP_RC" -ne 0 ] && echo "::warning::deep review process exited $DEEP_RC"
  echo "::warning::deep review did not produce valid JSON at $OUTPUT_FILE"
  cat /tmp/cascade/deep-stdout.txt 2>/dev/null || true
  cat /tmp/cascade/deep.log 2>/dev/null || true
  echo "::error::cascade failed at tier 2 for $PR_URL"
  exit 1
fi
# JSON is valid — if the process still exited non-zero log it but proceed:
# the agent may have written the verdict before a non-fatal wrapper error.
[ "$DEEP_RC" -ne 0 ] && echo "::warning::deep review process exited $DEEP_RC but produced valid JSON — proceeding"

# --- Agentic iterative validation (issue #1092) ---
# The deep tier attempted to reproduce its logic/correctness findings with the
# repo's lint/test tools inside its already-bounded run_agentic sandbox and tagged
# each with a `verification` outcome. Apply the downgrade/drop discipline now
# (before synthesis/audit consume the findings) so refuted findings are demoted or
# dropped and every processed finding is recorded as a kind:"finding_verification"
# record for the FP-rate metric. Pure jq — adds no tool/network/timeout surface.
apply_finding_verification "$OUTPUT_FILE" "${TOKEN_WORKFLOW:-pr-review}" "deep" "$PR_URL"

# Wait for duck to finish (deep succeeded)
[ -n "$DUCK_PID" ] && wait $DUCK_PID || true
# The engine that wrote the verdict (a fallback when the first had none), so
# synthesis and the summary name the duck that actually ran.
if [ -s "${DUCK_OUTPUT}.engine" ]; then
  read -r DUCK_ENGINE DUCK_MODEL < "${DUCK_OUTPUT}.engine"
fi

DEEP_DECISION=$(jq -r '.decision' "$OUTPUT_FILE")
DEEP_RISK=$(jq -r '.risk' "$OUTPUT_FILE")
echo "    [tier2] deep: decision=$DEEP_DECISION risk=$DEEP_RISK"

# Validate rubber duck (optional — graceful degradation if it fails)
DUCK_VALID=false
_duck_ok=false
if declare -F duck_verdict_valid >/dev/null 2>&1; then
  duck_verdict_valid "$DUCK_OUTPUT" && _duck_ok=true
elif [ -s "$DUCK_OUTPUT" ] && jq empty "$DUCK_OUTPUT" 2>/dev/null; then
  _duck_ok=true
fi
if [ "$_duck_ok" = true ]; then
  DUCK_DECISION=$(jq -r '.decision' "$DUCK_OUTPUT")
  DUCK_RISK=$(jq -r '.risk' "$DUCK_OUTPUT")
  DUCK_VALID=true
  echo "    [tier2] duck ($DUCK_ENGINE): decision=$DUCK_DECISION risk=$DUCK_RISK"
else
  echo "    [tier2] rubber duck did not produce a valid verdict — continuing with deep review only"
  cat /tmp/cascade/duck.log 2>/dev/null || true
  if [ -z "$DUCK_SKIP_REASON" ]; then
    DUCK_SKIP_REASON="$(head -n 1 "${DUCK_OUTPUT}.skip" 2>/dev/null || true)"
    DUCK_SKIP_REASON="${DUCK_SKIP_REASON:-the rubber duck ($DUCK_ENGINE) did not produce a valid verdict}"
    if [ "$_duck_gemini_skipped" = true ]; then
      DUCK_SKIP_REASON="$DUCK_SKIP_REASON; Gemini skipped per the pre-flight probe"
    fi
  fi
fi

# --- Tier 2b: Synthesize deep + duck verdicts ---
if [ "$DUCK_VALID" = "true" ]; then
  echo "    [tier2b] synthesizing deep + duck verdicts ($ENGINE_ACTION_MODEL)"
  DEEP_RESULT="/tmp/cascade/deep.json"
  DUCK_RESULT="$DUCK_OUTPUT"
  OUTPUT_FILE="/tmp/cascade/combined.json"
  export DEEP_RESULT DUCK_RESULT OUTPUT_FILE
  run_agentic prompts/synthesize-duck.md "$ENGINE_ACTION_MODEL" "action" \
    > /tmp/cascade/synth-stdout.txt 2>/tmp/cascade/synth.log || true

  if [ -s "$OUTPUT_FILE" ] && jq empty "$OUTPUT_FILE" 2>/dev/null; then
    COMBINED_DECISION=$(jq -r '.decision' "$OUTPUT_FILE")
    COMBINED_RISK=$(jq -r '.risk' "$OUTPUT_FILE")
    COMBINED_AGREEMENT=$(jq -r '.agreement' "$OUTPUT_FILE")
    COMBINED_ESCALATE=$(jq -r '.escalate_to_opus' "$OUTPUT_FILE")
    echo "    [tier2b] combined: decision=$COMBINED_DECISION risk=$COMBINED_RISK agreement=$COMBINED_AGREEMENT escalate_to_opus=$COMBINED_ESCALATE"
  else
    SYNTH_STDOUT=$(cat /tmp/cascade/synth-stdout.txt 2>/dev/null || true)
    SYNTH_STDERR=$(cat /tmp/cascade/synth.log 2>/dev/null || true)
    if is_cli_error "$SYNTH_STDOUT" || is_cli_error "$SYNTH_STDERR"; then
      echo "    [error] CLI format error (synthesis) — treating as per-PR failure"
      echo "${SYNTH_STDOUT:-}${SYNTH_STDERR:+ (stderr: $SYNTH_STDERR)}"
      exit 1
    fi
    if is_rate_limited "$SYNTH_STDOUT" || is_rate_limited "$SYNTH_STDERR"; then
      echo "    [tier2b] rate limit detected during synthesis — exiting with code 2 for engine fallback"
      echo "${SYNTH_STDOUT:-}${SYNTH_STDERR:+ (stderr: $SYNTH_STDERR)}"
      exit 2
    fi
    echo "    [tier2b] synthesis failed — falling back to deep review only"
    [ -n "$SYNTH_STDERR" ] && echo "    stderr: $SYNTH_STDERR"
    OUTPUT_FILE="/tmp/cascade/deep.json"
    DUCK_VALID=false
    DUCK_SKIP_REASON="${DUCK_SKIP_REASON:-the rubber duck verdict was discarded because synthesis failed}"
    COMBINED_ESCALATE=$(jq -r '.escalate_to_opus' "$OUTPUT_FILE")
  fi
else
  OUTPUT_FILE="/tmp/cascade/deep.json"
  COMBINED_ESCALATE=$(jq -r '.escalate_to_opus' "$OUTPUT_FILE")
fi

# If tier 2 resolves without needing security audit → go straight to action
if [ "$COMBINED_ESCALATE" != "true" ]; then
  echo "    [action] tier 2 resolved — posting review"
  FINAL_RESULT="$OUTPUT_FILE"
  export FINAL_RESULT
  if [ "$DUCK_VALID" = "true" ]; then
    export FINAL_TIER="deep+duck"
  else
    export FINAL_TIER="deep"
  fi
  VERDICT_JSON="/tmp/cascade/cascade-action-verdict.json"
  OUTPUT_FILE="$VERDICT_JSON"
  export OUTPUT_FILE
  run_agentic prompts/cascade-action.md "$ENGINE_ACTION_MODEL" "action" > "$VERDICT_JSON.raw" 2>/tmp/cascade/action.log || true
  if ! extract_verdict_json "$VERDICT_JSON.raw" "$VERDICT_JSON"; then
    ACTION_STDOUT=$(cat "$VERDICT_JSON.raw" 2>/dev/null || true)
    ACTION_STDERR=$(cat /tmp/cascade/action.log 2>/dev/null || true)
    if is_cli_error "$ACTION_STDOUT" || is_cli_error "$ACTION_STDERR"; then
      echo "    [error] CLI format error (action) — treating as per-PR failure"
      echo "${ACTION_STDOUT:-}${ACTION_STDERR:+ (stderr: $ACTION_STDERR)}"
      exit 1
    fi
    if is_rate_limited "$ACTION_STDOUT" || is_rate_limited "$ACTION_STDERR"; then
      echo "    [action] rate limit detected — exiting with code 2 for engine fallback"
      echo "${ACTION_STDOUT:-}${ACTION_STDERR:+ (stderr: $ACTION_STDERR)}"
      exit 2
    fi
    echo "::error::cascade-action did not produce valid JSON"
    exit 1
  fi
  rm -f "$VERDICT_JSON.raw"
  duck_skip_note "$VERDICT_JSON" "$DUCK_SKIP_REASON"

  # Post the review using the verdict. Propagate the output channel's exit status
  # (0 posted, 100 no-op, 101 escalated-to-human, non-zero error) so review-batch.sh
  # classifies the outcome correctly instead of counting an escalation as a posted
  # review (#1754).
  post_rc=0
  bash "$REVIEW_OUTPUT_CHANNEL" "$PR_URL" "$VERDICT_JSON" "$DRY_RUN" || post_rc=$?
  echo "    [done]  $PR_URL"
  exit "$post_rc"
fi

# --- Tier 3: Security audit ---
echo "    [tier3] security audit ($ENGINE_AUDIT_MODEL)"
# TIER2_RESULT may point to combined.json (deep+duck) or deep.json (duck failed).
TIER2_RESULT="$OUTPUT_FILE"
export TIER2_RESULT
# Backward compat: security-audit.md reads $DEEP_RESULT
DEEP_RESULT="$TIER2_RESULT"
export DEEP_RESULT
OUTPUT_FILE="/tmp/cascade/audit.json"
export OUTPUT_FILE

# Audit tier: separate stdout and stderr to safely detect rate limits without
# false positives from PR diff content in stdout.
run_agentic prompts/security-audit.md "$ENGINE_AUDIT_MODEL" "audit" \
  > /tmp/cascade/audit-stdout.txt 2>/tmp/cascade/audit.log || true

if [ ! -s "$OUTPUT_FILE" ] || ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
  AUDIT_STDOUT=$(cat /tmp/cascade/audit-stdout.txt 2>/dev/null || true)
  AUDIT_STDERR=$(cat /tmp/cascade/audit.log 2>/dev/null || true)
  if is_cli_error "$AUDIT_STDOUT" || is_cli_error "$AUDIT_STDERR"; then
    echo "    [error] CLI format error (tier 3) — treating as per-PR failure"
    echo "${AUDIT_STDOUT:-}${AUDIT_STDERR:+ (stderr: $AUDIT_STDERR)}"
    exit 1
  fi
  if is_rate_limited "$AUDIT_STDOUT" || is_rate_limited "$AUDIT_STDERR"; then
    echo "    [tier3] rate limit detected — exiting with code 2 for engine fallback"
    echo "${AUDIT_STDOUT:-}${AUDIT_STDERR:+ (stderr: $AUDIT_STDERR)}"
    exit 2
  fi
  echo "::warning::security audit did not produce valid JSON at $OUTPUT_FILE"
  [ -s "/tmp/cascade/audit.log" ] && { echo "    stderr:"; cat /tmp/cascade/audit.log; }
  echo "::error::cascade failed at tier 3 for $PR_URL"
  exit 1
fi

AUDIT_DECISION=$(jq -r '.decision' "$OUTPUT_FILE")
AUDIT_RISK=$(jq -r '.risk' "$OUTPUT_FILE")
echo "    [tier3] decision=$AUDIT_DECISION risk=$AUDIT_RISK"

# Security audit makes the final call — post the review
echo "    [action] security audit resolved — posting review"
FINAL_RESULT="$OUTPUT_FILE"
export FINAL_RESULT
export FINAL_TIER="audit"
VERDICT_JSON="/tmp/cascade/cascade-action-verdict-audit.json"
OUTPUT_FILE="$VERDICT_JSON"
export OUTPUT_FILE

run_agentic prompts/cascade-action.md "$ENGINE_ACTION_MODEL" "action" > "$VERDICT_JSON.raw" 2>/tmp/cascade/action-audit.log || true
if ! extract_verdict_json "$VERDICT_JSON.raw" "$VERDICT_JSON"; then
  ACTION_STDOUT=$(cat "$VERDICT_JSON.raw" 2>/dev/null || true)
  ACTION_STDERR=$(cat /tmp/cascade/action-audit.log 2>/dev/null || true)
  if is_cli_error "$ACTION_STDOUT" || is_cli_error "$ACTION_STDERR"; then
    echo "    [error] CLI format error (action audit) — treating as per-PR failure"
    echo "${ACTION_STDOUT:-}${ACTION_STDERR:+ (stderr: $ACTION_STDERR)}"
    exit 1
  fi
  if is_rate_limited "$ACTION_STDOUT" || is_rate_limited "$ACTION_STDERR"; then
    echo "    [action] rate limit detected — exiting with code 2 for engine fallback"
    echo "${ACTION_STDOUT:-}${ACTION_STDERR:+ (stderr: $ACTION_STDERR)}"
    exit 2
  fi
  echo "::error::cascade-action (audit) did not produce valid JSON"
  exit 1
fi
rm -f "$VERDICT_JSON.raw"
duck_skip_note "$VERDICT_JSON" "$DUCK_SKIP_REASON"

# Post the review using the verdict. Propagate the output channel's exit status
# (0 posted, 100 no-op, 101 escalated-to-human, non-zero error) so review-batch.sh
# classifies the outcome correctly instead of counting an escalation as a posted
# review (#1754).
post_rc=0
bash "$REVIEW_OUTPUT_CHANNEL" "$PR_URL" "$VERDICT_JSON" "$DRY_RUN" || post_rc=$?
echo "    [done]  $PR_URL"
exit "$post_rc"
