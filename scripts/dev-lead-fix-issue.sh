#!/usr/bin/env bash
set -euo pipefail
# dev-lead-fix-issue.sh — handles the issue intent
# Optional: PROMPTS_DIR (defaults to prompts/dev-lead relative to CWD)

source "$(dirname "$0")/engine.sh"
source "$(dirname "$0")/lib/git-identity.sh"
# Pure completion-claim helpers (#1445): body_has_completion_claim /
# claim_is_retracted / supersede_claim_body + the PC_CLAIM_RETRACTED_MARKER.
source "$(dirname "$0")/lib/premature-closure-detect.sh"
# Structured PR-body builders (#1805): dlpb_build_body produces the five
# required description sections so the PR is not escalated by triage for a
# description gap.
source "$(dirname "$0")/lib/dev-lead-pr-body.sh"
source "$(dirname "$0")/lib/hold-label.sh"
# Pure comment renderer (#1566): render_issue_comments filters + size-bounds the
# issue's comments into the ISSUE_COMMENTS prompt variable.
source "$(dirname "$0")/lib/issue-comments.sh"
# net_diff_is_empty / net_diff_summary (#1786): refuse to open/claim a PR whose
# three-dot net diff against base is empty.
source "$(dirname "$0")/lib/net-diff-guard.sh"

ISSUE_NUMBER="${ISSUE_NUMBER:-}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
DEV_LEAD_DRY_RUN="${DEV_LEAD_DRY_RUN:-false}"
export PROMPTS_DIR="${PROMPTS_DIR:-prompts/dev-lead}"

# Machine-readable marker the retry cron (dev-lead-retry.sh) scans for to requeue
# a failed initial issue implementation. Mirrors the PR-side conventions in
# dev-lead-fix-ci.sh / dev-lead-fix-reviews.sh:
#   <!-- dev-lead-issue <N> status=<failed|rate-limited> attempt=<K> reason=<r> run=<id> [reset=ISO] -->
ISSUE_MARKER_PREFIX="<!-- dev-lead-issue "
# Total attempts (initial + retries) before escalating to a human. Matches the
# MAX_ATTEMPTS=3 convention used by auto-rebase-retry.sh.
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
# Label applied when an issue can no longer be auto-retried; the retry cron
# skips issues carrying it.
NEEDS_HUMAN_LABEL="${NEEDS_HUMAN_LABEL:-dev-lead:needs-human}"

# Distinct, unmistakable prefix marking a checkpoint commit as incomplete (#1660).
# A stage timeout (exit 124) commits whatever the engine produced under this
# prefix and pushes the branch, so the partial work survives the ephemeral runner.
# The prefix must never collide with the normal "feat: implement issue" message so
# a reader — and any resolution gate — can tell partial, unreviewed work apart
# from a completed pass at a glance. It is deliberately never a completion claim.
CHECKPOINT_COMMIT_PREFIX="${CHECKPOINT_COMMIT_PREFIX:-checkpoint(dev-lead): INCOMPLETE —}"

# PR-limit admission gate (epic petry-projects/.github#505 Phase 3) config.
# The shared guard + limits config live in the PUBLIC standards repo so every
# automation caller enforces the same org-wide cap. PLG_STANDARDS_DIR lets tests
# and offline runs source a local checkout instead of hitting the API.
PLG_SOURCE_REPO="${PLG_SOURCE_REPO:-petry-projects/.github}"
PLG_SOURCE_REF="${PLG_SOURCE_REF:-main}"
PLG_DEFER_MARKER="<!-- dev-lead-issue-deferred -->"

check_existing_pr() {
  local existing
  existing=$(gh api "repos/${REPO}/pulls?state=open" \
    --jq "[.[] | select(.head.ref | startswith(\"dev-lead/issue-${ISSUE_NUMBER}\"))] | length" 2>/dev/null || echo "0")
  [ "$existing" -gt 0 ]
}

# count_prior_attempts: highest attempt= recorded in any prior dev-lead-issue
# marker on this issue (0 if none). The next attempt is this value + 1.
# --paginate keeps the count accurate on issues with >30 comments.
count_prior_attempts() {
  local prefix="${ISSUE_MARKER_PREFIX}${ISSUE_NUMBER} "
  gh api --paginate "repos/${REPO}/issues/${ISSUE_NUMBER}/comments?per_page=100" 2>/dev/null \
    | jq -s -r --arg p "$prefix" '
        [ .[] | .[]? | .body // ""
          | select(contains($p))
          | capture("attempt=(?<a>[0-9]+)").a
          | tonumber
        ] | max // 0' 2>/dev/null \
    || echo 0
}

# html_escape: escape &, <, > so a redacted snippet cannot break the wrapping
# <pre>/<details> block in the issue comment (mirrors engine.sh:run_writer).
html_escape() {
  sed 's|&|\&amp;|g; s|<|\&lt;|g; s|>|\&gt;|g'
}

# session_snippet: redacted ~40-line tail of the engine session output, wrapped
# in a collapsible <details> block. The source file is already secret-scrubbed
# by engine.sh:run_writer, so no further redaction is needed here.
session_snippet() {
  [ -s /tmp/dev-lead-session-output.txt ] || return 0
  printf '<details><summary>Last 40 lines of engine output (redacted)</summary>\n\n<pre>\n'
  tail -n 40 /tmp/dev-lead-session-output.txt | html_escape
  printf '\n</pre>\n</details>'
}

# ensure_needs_human_label: idempotently create then apply the escalation label.
# gh issue edit --add-label fails if the label does not exist, so create first.
ensure_needs_human_label() {
  gh label create "$NEEDS_HUMAN_LABEL" --repo "$REPO" \
    --color B60205 --description "dev-lead could not complete this issue; needs human attention" \
    2>/dev/null || true
  add_label_rest "$REPO" "$ISSUE_NUMBER" "$NEEDS_HUMAN_LABEL" || true
}

# escalate_needs_human <reason> <attempt> <snippet> <error_line> <cause_markdown> [exit_code]
# Single source of truth for the non-retryable escalation path shared by the
# missing-binary / timeout / retries-exhausted branches. Performs the five common
# steps: emit ::error::, apply the needs-human label, post the
# `status=needs-human` marker comment (byte-identical across branches — the retry
# cron and the #1019 fleet-monitor parse it), append the run-agnostic redacted
# session snippet, then exit. Callers pass only their reason-specific cause text
# (which carries its own run link + any extra bullets/guidance). Never returns.
escalate_needs_human() {
  # Guard the required args before referencing them: under `set -u` a miscall
  # with too few args would otherwise crash with an unbound-variable error —
  # and on the escalation path a crash means the human is never notified.
  if [ "$#" -lt 5 ]; then
    echo "::error::escalate_needs_human requires 5 args (reason attempt snippet error_line cause_markdown); got $#" >&2
    exit 1
  fi
  local reason="$1" attempt="$2" snippet="$3" error_line="$4" cause_markdown="$5" exit_code="${6:-1}"
  echo "::error::${error_line}"
  ensure_needs_human_label
  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "<!-- dev-lead-issue ${ISSUE_NUMBER} status=needs-human attempt=${attempt} reason=${reason} run=${GITHUB_RUN_ID:-} -->
## Dev-Lead: cannot implement issue #${ISSUE_NUMBER} — needs human attention

${cause_markdown}

${snippet}" 2>/dev/null || true
  # Terminal failure (#1445, AC #3): any completion claim posted before the work
  # was durable is now false — supersede it in place so the issue never reads as
  # delivered while nothing landed. Runs on every needs-human branch (missing-
  # binary / timeout / retries-exhausted), never on the retryable path.
  retract_prior_completion_claims "$reason"
  exit "$exit_code"
}

# retract_prior_completion_claims <reason>
# Find any standing completion claim on this issue (the durable status=completed
# marker OR a legacy "## Completed" / "Implementation Complete" comment the engine
# posted mid-run) and supersede it IN PLACE: prepend a dated strike-through banner
# (carrying PC_CLAIM_RETRACTED_MARKER) and strike the claim's heading, reusing the
# docs/metrics-baseline.md dated-correction convention. Idempotent — a comment
# already carrying the marker is skipped. Best-effort: every gh failure is
# swallowed so retraction never turns a clean escalation into a hard error.
retract_prior_completion_claims() {
  local reason="${1:-}" today comments enc obj id body banner new_body tmp
  today=$(date -u +%Y-%m-%d)

  # List id+body for every comment, base64-encoded per row so multi-line bodies
  # survive the read loop intact. Uses jq as a pipe stage (gh's own --jq is not
  # applied by the test stubs), mirroring count_prior_attempts.
  comments=$(gh api --paginate "repos/${REPO}/issues/${ISSUE_NUMBER}/comments?per_page=100" 2>/dev/null \
    | jq -s -r '[ .[] | .[]? ] | .[] | {id: .id, body: (.body // "")} | @base64' 2>/dev/null) || return 0
  [ -n "$comments" ] || return 0

  while IFS= read -r enc; do
    [ -n "$enc" ] || continue
    obj=$(printf '%s' "$enc" | base64 -d 2>/dev/null) || continue
    id=$(printf '%s' "$obj" | jq -r '.id' 2>/dev/null) || continue
    body=$(printf '%s' "$obj" | jq -r '.body' 2>/dev/null) || continue
    [ -n "$id" ] && [ "$id" != "null" ] || continue
    body_has_completion_claim "$body" || continue
    claim_is_retracted "$body" && continue

    # If the claim references a durable merged PR (pr=NNN), the work did land —
    # retraction would incorrectly strike a genuine completion record. Skip it.
    local pr_ref
    pr_ref=$(printf '%s' "$body" | grep -oE 'pr=[0-9]+' | grep -oE '[0-9]+' | head -1 2>/dev/null || true)
    if [ -n "$pr_ref" ]; then
      local pr_state
      pr_state=$(gh pr view "$pr_ref" --repo "$REPO" --json state --jq '.state' 2>/dev/null || echo "")
      [ "$pr_state" = "MERGED" ] && continue
    fi

    banner="${PC_CLAIM_RETRACTED_MARKER}
> **[Retracted ${today} — superseded]** This completion claim was published **before the work was durable**. The run subsequently ended without landing anything on \`main\` (reason=\`${reason}\`, run=${GITHUB_RUN_ID:-}), so it produced nothing. The claim is struck in place (not deleted) per this repo's dated-correction convention; see the \`needs-human\` escalation on this issue for status."
    new_body=$(supersede_claim_body "$body" "$banner")

    tmp=$(mktemp) || continue
    printf '%s' "$new_body" > "$tmp"
    gh api -X PATCH "repos/${REPO}/issues/comments/${id}" -F "body=@${tmp}" >/dev/null 2>&1 || true
    rm -f "$tmp"
    echo "::notice::Retracted stale completion claim (comment ${id}) on issue #${ISSUE_NUMBER} — run failed (${reason}), nothing landed."
  done <<< "$comments"
}

# checkpoint_push_partial_work
# On a stage timeout (exit 124), preserve whatever the engine produced before it
# was killed instead of discarding it (#1660). Commits any uncommitted changes
# under CHECKPOINT_COMMIT_PREFIX (so the commit is unmistakably incomplete) and
# pushes the working branch. Echoes the pushed branch name on success (rc 0);
# returns non-zero if there is nothing to preserve or the push could not happen
# (the caller then falls back to the "not pushed" note).
#
# Why this runs here rather than via a trap or a fractional-budget checkpoint:
# the per-tier budget is `timeout "$ACTION_TIMEOUT_SEC" claude …` in engine.sh,
# which wraps ONLY the engine child — this orchestrating script is never itself
# under `timeout`. So exit 124 is delivered synchronously to a fully-alive shell
# and we push in ordinary control flow. A trap has no kill signal to catch here
# (the run is not under `timeout`), and a fractional (~80%) checkpoint would have
# to guess when the cap hits; exit 124 needs no guessing.
#
# It deliberately opens NO pull request and posts NO completion claim, so a
# checkpoint can never satisfy the harness-only resolution gate (#1621/#1691) —
# resolution stays gated on a complete pass.
checkpoint_push_partial_work() {
  local br="${branch:-}"
  [ -n "$br" ] || return 1

  # Anything to preserve? Uncommitted changes OR commits the engine made past the
  # pre-engine SHA (it may have committed via Bash before the later phase timed out).
  local has_uncommitted=false has_commits=false
  [ -n "$(git status --porcelain 2>/dev/null)" ] && has_uncommitted=true
  if [ -n "${pre_engine_sha:-}" ] && [ "$(git rev-parse HEAD 2>/dev/null)" != "$pre_engine_sha" ]; then
    has_commits=true
  fi
  if ! $has_uncommitted && ! $has_commits; then
    return 1
  fi

  # Commit any uncommitted work under the incomplete marker. We deliberately do
  # NOT run the lint gate here: this is partial, unreviewed work by definition, and
  # blocking the checkpoint on lint would defeat the point (preserve what exists).
  # The marker + escalation comment make the incompleteness unmistakable.
  if $has_uncommitted; then
    git add -A >/dev/null 2>&1 || return 1
    git commit -m "${CHECKPOINT_COMMIT_PREFIX} partial work for issue #${ISSUE_NUMBER} (stage timeout — unreviewed, do not merge)" \
      >/dev/null 2>&1 || return 1
  fi

  # Push the branch so the work lands on the remote before the run exits.
  git push --set-upstream origin "$br" >/dev/null 2>&1 || return 1

  printf '%s\n' "$br"
  return 0
}

# handle_engine_failure <engine_rc>
# Replaces the previous silent `exit 1` (and unifies the rate-limit branch).
# Classifies the cause via the /tmp/dev-lead-failure-reason sidecar written by
# engine.sh, surfaces it on the issue (marker + human-readable comment + run
# link + redacted snippet), and decides retry vs. human escalation. Never
# returns — exits 2 for rate-limit, 1 otherwise (exit semantics unchanged).
handle_engine_failure() {
  local engine_rc="$1"
  rm -f "${prompt_file:-}"

  # Cause class from the engine layer; default to engine-error if the sidecar is
  # absent (e.g. an older engine.sh). exit 2 always means rate-limited.
  local reason="engine-error"
  if [ -s /tmp/dev-lead-failure-reason ]; then
    reason=$(tr -d '[:space:]' < /tmp/dev-lead-failure-reason)
  fi
  [ -n "$reason" ] || reason="engine-error"
  [ "$engine_rc" -eq 2 ] && reason="rate-limited"

  local reset=""
  [ -f /tmp/dev-lead-rate-limit-reset ] && reset=$(cat /tmp/dev-lead-rate-limit-reset)

  local attempt
  attempt=$(( $(count_prior_attempts) + 1 ))
  local run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-$REPO}/actions/runs/${GITHUB_RUN_ID:-}"
  local snippet
  snippet=$(session_snippet)

  # Deterministic infra failure (missing engine binary): retrying cannot help —
  # escalate to a human immediately, no retry marker.
  if [ "$reason" = "missing-binary" ]; then
    escalate_needs_human "$reason" "$attempt" "$snippet" \
      "Engine binary missing while implementing issue #${ISSUE_NUMBER} — escalating to human" \
      "A required engine binary was missing in the runner environment while implementing this issue. This is an **infrastructure/configuration** problem, not a transient error, so automatic retry is disabled.

- **Cause:** \`${reason}\`
- **Run:** ${run_url}

Please check the runner/engine configuration, then re-apply the \`dev-lead\` label to retry."
  fi

  # Deterministic credential config-gap (#1591): an engine (e.g. Copilot) was
  # skipped because its token was missing/placeholder/unsupported and it was the
  # sole terminal cause. Like missing-binary, retrying cannot help until a human
  # sets the secret — escalate immediately with NO retry marker so the retry cron
  # does not requeue an attempt that can never succeed. This is distinct from a
  # rate limit: the condition cannot change on its own.
  if [ "$reason" = "unconfigured" ]; then
    escalate_needs_human "$reason" "$attempt" "$snippet" \
      "Engine credential missing/placeholder while implementing issue #${ISSUE_NUMBER} — escalating to human" \
      "A required engine credential (e.g. the Copilot token \`COPILOT_GITHUB_TOKEN\`) was **missing, a placeholder, or an unsupported type** while implementing this issue. This is a deterministic **authentication/configuration** gap, not a transient rate limit, so automatic retry is disabled — retrying cannot succeed until the secret is set.

- **Cause:** \`${reason}\`
- **Run:** ${run_url}

Set the missing engine credential (and confirm it is a supported token type), then re-apply the \`dev-lead\` label to retry."
  fi

  # Stage timeout (exit 124): a first-class, NON-retryable condition. A
  # same-budget retry would just time out again, so — like missing-binary —
  # escalate to a human on the FIRST occurrence with NO retry marker (the retry
  # cron skips dev-lead:needs-human). The comment states the tier, elapsed
  # seconds, and budget, plus split/raise guidance. This branch precedes the
  # attempt-ceiling / retry logic below on purpose. (#1018)
  if [ "$reason" = "timeout" ]; then
    local tier="deep/action" budget="unknown" elapsed="unknown" raise_var="DEEP_TIMEOUT_SEC"
    [ -s /tmp/dev-lead-timeout-tier ]    && tier=$(tr -d '[:space:]' < /tmp/dev-lead-timeout-tier)
    [ -s /tmp/dev-lead-timeout-budget ]  && budget=$(tr -d '[:space:]' < /tmp/dev-lead-timeout-budget)
    [ -s /tmp/dev-lead-timeout-elapsed ] && elapsed=$(tr -d '[:space:]' < /tmp/dev-lead-timeout-elapsed)
    case "$tier" in
      action|writer) raise_var="ACTION_TIMEOUT_SEC" ;;
      deep)          raise_var="DEEP_TIMEOUT_SEC" ;;
    esac

    # Checkpoint-push partial work (#1660): if the engine produced commits or
    # staged/uncommitted changes before the timeout, preserve them on the remote
    # under an INCOMPLETE marker instead of discarding them. On success the
    # escalation names the pushed branch and calls the work partial/unreviewed;
    # only if the push genuinely could not happen do we fall back to the older
    # "not recoverable from this run" note (#1003).
    local work_note="" checkpoint_branch=""
    checkpoint_branch=$(checkpoint_push_partial_work) || checkpoint_branch=""
    if [ -n "$checkpoint_branch" ]; then
      work_note="

> **Partial work was checkpoint-pushed to \`${checkpoint_branch}\`.** The engine produced changes before the timeout; rather than lose them, they were committed with the \`${CHECKPOINT_COMMIT_PREFIX}\` marker and pushed to that branch. **This work is partial and unreviewed** — no pull request was opened and no review threads were resolved, so it must **not** be merged as-is. Use it as a salvage point: continue the branch by hand, or re-apply \`dev-lead\` after splitting the issue or raising the budget."
    elif [ -n "$(git status --porcelain 2>/dev/null)" ] || \
       { [ -n "${pre_engine_sha:-}" ] && [ "$(git rev-parse HEAD 2>/dev/null)" != "$pre_engine_sha" ]; }; then
      work_note="

> **Note: the engine had produced changes before the timeout,** but they could not be pushed from this run, so they are **not recoverable** (the runner is ephemeral). The redacted session snippet below shows what it attempted — treat it as context, not restorable output. Re-apply \`dev-lead\` after splitting the issue or raising the budget to regenerate the work."
    fi

    escalate_needs_human "$reason" "$attempt" "$snippet" \
      "Stage timeout (exit 124) while implementing issue #${ISSUE_NUMBER} at the ${tier} tier (elapsed=${elapsed}s, budget=${budget}s) — escalating to human (no same-budget retry)" \
      "A stage **timed out** (exit 124) while implementing this issue. A timeout is treated as a first-class, **non-retryable** condition — retrying with the same budget would just time out again — so this escalates for human review on the **first** occurrence instead of wasting a same-budget retry.

- **Cause:** \`${reason}\`
- **Tier:** ${tier}
- **Elapsed:** ${elapsed}s
- **Budget:** ${budget}s
- **Run:** ${run_url}

This hit the max ${tier} budget. **Split this issue** into smaller, independently-implementable pieces, or **raise \`vars.${raise_var}\`**, then re-apply the \`dev-lead\` label.${work_note}"
  fi

  # Retries exhausted: escalate to a human, no further retry marker. Preserve the
  # exit-2-on-rate-limit contract (engine_rc==2) via the helper's exit_code arg.
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    local exhausted_exit=1
    [ "$engine_rc" -eq 2 ] && exhausted_exit=2
    escalate_needs_human "$reason" "$attempt" "$snippet" \
      "Engine failed to implement issue #${ISSUE_NUMBER} (reason=${reason}); retries exhausted (attempt ${attempt}/${MAX_ATTEMPTS}) — escalating to human" \
      "Automatic retries are exhausted (**attempt ${attempt} of ${MAX_ATTEMPTS}**). The most recent failure was \`${reason}\`.

- **Run:** ${run_url}

Please review the failures above. To retry anyway, remove the \`${NEEDS_HUMAN_LABEL}\` label and re-apply the \`dev-lead\` label." \
      "$exhausted_exit"
  fi

  # Retryable (rate-limited or engine-error, attempt < MAX): post the marker the
  # retry cron scans for, plus a human-readable comment with the cause.
  local status="failed"
  [ "$reason" = "rate-limited" ] && status="rate-limited"
  local reset_attr=""
  [ -n "$reset" ] && reset_attr=" reset=${reset}"
  local marker="${ISSUE_MARKER_PREFIX}${ISSUE_NUMBER} status=${status} attempt=${attempt} reason=${reason} run=${GITHUB_RUN_ID:-}${reset_attr} -->"

  local cause_line reset_line=""
  if [ "$reason" = "rate-limited" ]; then
    echo "::warning::All engines rate-limited while implementing issue #${ISSUE_NUMBER} (attempt ${attempt}/${MAX_ATTEMPTS}) — will retry automatically"
    cause_line="All engines were **rate-limited**."
    [ -n "$reset" ] && reset_line="
- **Limit resets:** ${reset}"
  else
    echo "::error::Engine failed to implement issue #${ISSUE_NUMBER} (reason=${reason}, attempt ${attempt}/${MAX_ATTEMPTS}) — will retry automatically"
    cause_line="The engine failed (\`${reason}\` — e.g. a timeout or transient engine error)."
  fi

  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "${marker}
## Dev-Lead: issue #${ISSUE_NUMBER} implementation failed — will retry

${cause_line} This was **attempt ${attempt} of ${MAX_ATTEMPTS}**; dev-lead will retry automatically. You can also re-apply the \`dev-lead\` label to retry now.

- **Cause:** \`${reason}\`
- **Run:** ${run_url}${reset_line}

${snippet}" 2>/dev/null || true

  [ "$engine_rc" -eq 2 ] && exit 2
  exit 1
}

# _plg_fetch <repo-relative-path> <dest>: populate <dest> with the file at
# <repo-relative-path>. Prefer a local checkout (PLG_STANDARDS_DIR, used by
# tests/offline runs); otherwise fetch from the PUBLIC PLG_SOURCE_REPO via the
# contents API. Returns non-zero on any failure or empty result so callers can
# fail-open.
_plg_fetch() {
  [ "$#" -lt 2 ] && return 1
  local path="$1" dest="$2"
  if [ -n "${PLG_STANDARDS_DIR:-}" ]; then
    local src="${PLG_STANDARDS_DIR}/${path}"
    [ -f "$src" ] || return 1
    cp "$src" "$dest" 2>/dev/null || return 1
  else
    gh api "repos/${PLG_SOURCE_REPO}/contents/${path}?ref=${PLG_SOURCE_REF}" \
      --jq '.content' 2>/dev/null | base64 -d > "$dest" 2>/dev/null || return 1
  fi
  [ -s "$dest" ]
}

# admission_gate_allows: returns 0 (allow) / 1 (defer). Fetches the shared guard
# + limits config from the public standards repo and asks plg_admission_gate
# whether a new "dev-lead" automation PR may be opened. FAIL-OPEN: any fetch,
# sourcing, or unexpected-rc problem allows PR creation so a guard defect never
# blocks the pipeline. rc==1 from the guard is the only real "defer".
admission_gate_allows() {
  local tmp guard config
  tmp="$(mktemp -d)" || { echo "::warning::PR-limit gate: mktemp failed — failing open (allowing PR)"; return 0; }
  guard="${tmp}/pr-limit-gate.sh"
  config="${tmp}/pr-limits.json"

  if ! _plg_fetch "scripts/lib/pr-limit-gate.sh" "$guard"; then
    echo "::warning::PR-limit gate: could not fetch guard (scripts/lib/pr-limit-gate.sh) from ${PLG_SOURCE_REPO}@${PLG_SOURCE_REF} — failing open (allowing PR)"
    rm -rf "$tmp"
    return 0
  fi
  if ! _plg_fetch "standards/pr-limits.json" "$config"; then
    echo "::warning::PR-limit gate: could not fetch config (standards/pr-limits.json) from ${PLG_SOURCE_REPO}@${PLG_SOURCE_REF} — failing open (allowing PR)"
    rm -rf "$tmp"
    return 0
  fi

  # Source the guard defensively: an `if ! source` guard keeps a non-zero return
  # from the sourced file from tripping set -e, and declare -F confirms the entry
  # point actually exists before we call it.
  # shellcheck source=/dev/null
  if ! source "$guard" || ! declare -F plg_admission_gate >/dev/null; then
    echo "::warning::PR-limit gate: guard did not source or define plg_admission_gate — failing open (allowing PR)"
    rm -rf "$tmp"
    return 0
  fi

  local rc=0
  PR_LIMITS_CONFIG="$config" plg_admission_gate "dev-lead" >/dev/null || rc=$?
  rm -rf "$tmp"

  case "$rc" in
    0) return 0 ;;  # under cap — allow PR creation
    1) return 1 ;;  # at/over cap — real defer
    *) echo "::warning::PR-limit gate: unexpected exit code ${rc} from plg_admission_gate — failing open (allowing PR)"
       return 0 ;;
  esac
}

# deferral_comment_exists: 0 when a deferral comment (body starting with
# PLG_DEFER_MARKER) already exists on the issue. Paginates so a marker on a later
# comment page is not missed (which would cause a duplicate defer comment), and
# null-safe on bodyless comments. Robust to gh failure or a non-numeric result —
# both treated as "not exists" so a transient API error never suppresses a
# needed comment. gh --paginate applies --jq per page (one number per page);
# jq -s 'add // 0' sums the per-page counts.
deferral_comment_exists() {
  local count
  count=$(gh api --paginate "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" \
    --jq "[.[] | select((.body // \"\") | startswith(\"${PLG_DEFER_MARKER}\"))] | length" 2>/dev/null \
    | jq -s 'add // 0' 2>/dev/null || echo 0)
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  [ "$count" -gt 0 ]
}

# post_deferral_comment: idempotently post a single deferral comment. No-op if a
# deferral comment already exists, so repeated runs never spam the issue. The
# body starts with PLG_DEFER_MARKER on its own line. gh errors are swallowed —
# a failed comment must not turn a benign defer into a hard failure.
post_deferral_comment() {
  if deferral_comment_exists; then
    return 0
  fi
  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "${PLG_DEFER_MARKER}
## Dev-Lead: implementation deferred — automation PR queue is full

**No pull request was opened** for issue #${ISSUE_NUMBER}. The org-wide
open-automation-PR queue is currently at its signed-off cap (see
\`standards/pr-limits.json\` in \`${PLG_SOURCE_REPO}\`).

This issue stays labeled \`dev-lead\` and will be re-attempted automatically once
the queue drains — no action is required." 2>/dev/null || true
}

# abort_empty_net_diff <base_ref>
# The implementation pass produced NO net change against the base (the three-dot
# `origin/<base>...HEAD` diff is empty), so opening a PR now would either be empty
# or — if it carried self-cancelling commits — auto-close this issue via
# `Closes #N` while nothing is actually fixed (#1786, slice 1 of #1620). Refuse:
# push nothing, open no PR, post no completion claim; label the issue for a human
# and explain why. Never returns — exits 1.
abort_empty_net_diff() {
  local base_ref="$1"
  echo "::error::Empty net diff: issue #${ISSUE_NUMBER}'s branch has no net change against origin/${base_ref} — refusing to open an empty/self-cancelling PR (#1786)"
  ensure_needs_human_label
  local run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-$REPO}/actions/runs/${GITHUB_RUN_ID:-}"
  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "<!-- dev-lead-issue ${ISSUE_NUMBER} status=needs-human reason=empty-net-diff run=${GITHUB_RUN_ID:-} -->
## Dev-Lead: no net change — not opening a PR for issue #${ISSUE_NUMBER}

The implementation pass produced **no net difference** against \`${base_ref}\`: the three-dot \`origin/${base_ref}...HEAD\` diff is empty (zero changed files). This happens when a change is made and then reverted in the same branch. Opening a PR now would either be empty or, if it carried self-cancelling commits, auto-close this issue via \`Closes #${ISSUE_NUMBER}\` while the work remains undone (#1786).

**No branch was pushed, no pull request was opened, and no completion claim was posted.** This issue is labeled \`${NEEDS_HUMAN_LABEL}\` for human attention.

- **Run:** ${run_url}" 2>/dev/null || true
  rm -f "${prompt_file:-}"
  exit 1
}

# post_completion_claim <pr_url> <head_sha> [base_ref]
# Post the DURABLE completion record (#1445, AC #1/#2) — only ever called AFTER
# the work is durable (commits pushed + PR opened). It carries a machine-readable
# marker plus the two verifiable artifacts (PR number + head SHA) so a reader can
# confirm it in one click and the #1445 audit can check it mechanically. This is
# the ONLY completion claim the pipeline posts; the engine's own Phase-6 note is
# explicitly provisional (see prompts/dev-lead/fix-issue.md).
#
# #1786: the claim must NEVER post when the net diff against base is empty, and
# must state the net change (file count + line delta) so the record is falsifiable
# rather than an unqualified "complete".
post_completion_claim() {
  local pr_url="$1" head_sha="$2" base_ref="${3:-${BASE_REF:-main}}" pr_number run_url
  # Belt-and-suspenders (#1786): the PR-open guard already aborts on an empty net
  # diff before this is reached, but never assert completion for a net-zero PR.
  if net_diff_is_empty "$base_ref"; then
    echo "::warning::Skipping completion claim for issue #${ISSUE_NUMBER}: net diff against origin/${base_ref} is empty (#1786)"
    return 0
  fi
  pr_number=$(printf '%s' "$pr_url" | sed -nE 's#.*/pull/([0-9]+).*#\1#p')
  [ -n "$pr_number" ] || pr_number="unknown"
  run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-$REPO}/actions/runs/${GITHUB_RUN_ID:-}"
  local net_change
  net_change=$(net_diff_summary "$base_ref")
  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "<!-- dev-lead-issue ${ISSUE_NUMBER} status=completed pr=${pr_number} sha=${head_sha} run=${GITHUB_RUN_ID:-} -->
## Dev-Lead: Implementation Complete — PR #${pr_number}

The implementation for issue #${ISSUE_NUMBER} is **durable**: commits are pushed and a pull request is open. This record is backed by verifiable artifacts you can confirm in one click.

- **Pull request:** ${pr_url}
- **Head commit:** \`${head_sha}\`
- **Net change against \`${base_ref}\`:** ${net_change}
- **Run:** ${run_url}

Review happens on the PR. Acceptance criteria and test results are evidenced by the PR's diff and CI checks — not asserted here. If a later stage fails, this claim is retracted in place." 2>/dev/null || true
}

main() {
  if [ -z "$ISSUE_NUMBER" ]; then
    echo "::error::ISSUE_NUMBER is required"
    exit 1
  fi

  if check_existing_pr; then
    echo "::notice::Existing open PR found for issue #${ISSUE_NUMBER} — skipping (dedup)"
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "<!-- dev-lead-issue-dedup -->Already working on this: an open PR exists for issue #${ISSUE_NUMBER}." 2>/dev/null || true
    exit 0
  fi

  # Gather issue context
  export ISSUE_NUMBER ISSUE_URL="https://github.com/${REPO}/issues/${ISSUE_NUMBER}"
  export REPO
  ISSUE_TITLE=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}" --jq '.title' 2>/dev/null || echo "Unknown")
  ISSUE_BODY=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}" --jq '.body // ""' 2>/dev/null || echo "")
  # Issue comments (#1566): human clarifications/answers posted after filing must
  # reach the prompt. render_issue_comments filters bot/dev-lead noise, keeps the
  # rest chronological, and size-bounds them. `|| ISSUE_COMMENTS=""` keeps a gh or
  # jq failure from aborting under set -e/pipefail — a missing comment block just
  # degrades to the body-only prompt.
  ISSUE_COMMENTS=$(gh api --paginate "repos/${REPO}/issues/${ISSUE_NUMBER}/comments?per_page=100" 2>/dev/null | render_issue_comments) || ISSUE_COMMENTS=""
  ORG_STANDARDS_HINT="See AGENTS.md and docs/ for coding standards."
  export ISSUE_TITLE ISSUE_BODY ISSUE_COMMENTS ORG_STANDARDS_HINT
  # Export lint script path so it is substituted into the rendered prompt.
  # dirname "$0" resolves correctly in both direct (scripts/) and reusable (.dev-lead/scripts/) runs.
  export LINT_SCRIPT="${LINT_SCRIPT:-"$(dirname "$0")/dev-lead-lint.sh"}"

  local prompt_file="/tmp/dev-lead-fix-issue-prompt-$$.md"
  local template_path="${PROMPTS_DIR}/fix-issue.md"
  local vars_spec
  vars_spec=$(grep -m1 '<!-- VARIABLES:' "$template_path" 2>/dev/null \
    | sed 's/<!-- VARIABLES: //; s/ -->//' \
    | tr ',' '\n' \
    | awk '{gsub(/^ +| +$/, ""); if (length) printf "${%s}", $0}' || true)
  if [ -n "$vars_spec" ]; then
    envsubst "$vars_spec" < "$template_path" > "$prompt_file"
  else
    envsubst < "$template_path" > "$prompt_file"
  fi

  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] fix-issue: would implement issue #${ISSUE_NUMBER} using prompt: $prompt_file"
    rm -f "${prompt_file:-}"
    exit 0
  fi

  # PR-limit admission gate — epic petry-projects/.github#505 Phase 3.
  # Before opening a new automation PR, defer if the org-wide open-automation-PR
  # queue is at the signed-off cap (standards/pr-limits.json in petry-projects/.github).
  # Placed AFTER the dry-run early-exit so a dry-run never defers; FAIL-OPEN so a
  # guard problem never blocks PR creation.
  if ! admission_gate_allows; then
    echo "::notice::PR-limit gate: deferring issue #${ISSUE_NUMBER} — org-wide automation PR cap reached; left labeled dev-lead for retry"
    post_deferral_comment
    rm -f "${prompt_file:-}"
    exit 0
  fi

  # Configure git identity so the post-engine commit does not fail.
  # BOT_USER is set as a job-level env var in dev-lead-reusable.yml.
  setup_git_identity

  # Create feature branch
  local branch
  branch="dev-lead/issue-${ISSUE_NUMBER}-$(date +%Y%m%d-%H%M)"
  git checkout -b "$branch"
  local pre_engine_sha
  pre_engine_sha=$(git rev-parse HEAD)

  local engine_rc=0
  run_writer_with_fallback "$prompt_file" "fix-issue" || engine_rc=$?
  if [ "$engine_rc" -ne 0 ]; then
    # Unified failure handler: classifies the cause, surfaces it on the issue
    # (marker + comment + run link + redacted snippet), and decides retry vs.
    # human escalation. Never returns — exits 2 (rate-limit) or 1 (otherwise).
    handle_engine_failure "$engine_rc"
  fi

  # git status --porcelain catches untracked files that git diff misses.
  # Compare HEAD to pre-engine SHA to detect commits the engine made via Bash.
  local has_uncommitted=false has_unpushed=false
  [ -n "$(git status --porcelain)" ] && has_uncommitted=true
  [ "$(git rev-parse HEAD)" != "$pre_engine_sha" ] && has_unpushed=true

  if ! $has_uncommitted && ! $has_unpushed; then
    echo "::notice::No changes made for issue #${ISSUE_NUMBER}"
    rm -f "${prompt_file:-}"
    exit 0
  fi

  # Run lint before committing to prevent avoidable CI failures.
  # LINT_SCRIPT was exported above (resolves to the correct path in both direct and reusable runs).
  local lint_rc=0
  local lint_output=""
  if [ -f "$LINT_SCRIPT" ]; then
    lint_output=$(bash "$LINT_SCRIPT" 2>&1) || lint_rc=$?
  fi

  if [ "$lint_rc" -ne 0 ]; then
    echo "::error::Lint check failed — aborting commit to prevent CI failure. Re-apply the dev-lead label after fixing lint errors."
    echo "$lint_output"
    local _lint_body
    _lint_body="<!-- dev-lead-lint-failed -->
## Dev-Lead: Lint Check Failed

The implementation for issue #${ISSUE_NUMBER} contained lint errors. The commit was **aborted** to prevent a CI failure.

\`\`\`
${lint_output}
\`\`\`

**To retry:** fix the lint errors locally (or re-apply the \`dev-lead\` label — the agent will try again)."
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$_lint_body" 2>/dev/null || true
    rm -f "${prompt_file:-}"
    exit 1
  fi

  if $has_uncommitted; then
    git add -A
    git commit -m "feat: implement issue #${ISSUE_NUMBER} — ${ISSUE_TITLE}"
  fi

  # Empty net-diff guard (#1786, slice 1 of #1620): before pushing or opening a
  # PR, verify the branch introduces a real net change against base. Use the
  # three-dot compare (origin/<base>...HEAD) — NOT the file list — so a change
  # made and then reverted (net-zero) is caught. On an empty net diff, push
  # nothing, open no PR, and escalate to a human (never a self-cancelling PR).
  local base_ref="${BASE_REF:-main}"
  if net_diff_is_empty "$base_ref"; then
    abort_empty_net_diff "$base_ref"
  fi

  git push --set-upstream origin "$branch"

  # Head SHA of the durable, pushed work — the verifiable artifact the completion
  # claim references (#1445, AC #2).
  local head_sha
  head_sha=$(git rev-parse HEAD)

  # Structured PR body (#1805): fill all five required description sections
  # (Problem / Risk / Test plan / Rollback / Monitoring) followed by Closes #N,
  # derived from the issue and the files this branch changed, so triage does not
  # escalate the PR for a missing description. Section content stays truthful —
  # the test plan reflects only the checks this run actually performed.
  local changed_files pr_body pr_body_file
  changed_files=$(git diff --name-only "$pre_engine_sha" HEAD 2>/dev/null || true)
  pr_body=$(dlpb_build_body "$ISSUE_NUMBER" "$ISSUE_TITLE" "$ISSUE_BODY" "$changed_files")
  pr_body_file=$(mktemp "/tmp/dev-lead-pr-body-XXXXXX.md") || { echo "Failed to create temp file" >&2; exit 1; }
  printf '%s\n' "$pr_body" > "$pr_body_file"

  local pr_url
  pr_url=$(gh pr create \
    --repo "$REPO" \
    --title "feat: implement issue #${ISSUE_NUMBER} — ${ISSUE_TITLE}" \
    --body-file "$pr_body_file" \
    --head "$branch")
  rm -f "$pr_body_file"
  echo "$pr_url"

  # Mark the PR auto-rebase-eligible from creation (petry-projects/.github#711).
  # The auto-rebase 'review-ready' gate (#465) only rebases PRs that are approved
  # OR carry the ready label; without this, a dev-lead PR that falls behind before
  # it is approved is skipped, drifts into a merge conflict, and cannot be approved
  # (pr-review skips red/conflicting PRs) — a deadlock that rots the PR for weeks.
  # Ensure the label exists first (idempotent; || true absorbs the "already exists"
  # error) so a repo missing it does not break; guard everything so PR creation
  # never fails on a labeling hiccup.
  if [ -n "$pr_url" ]; then
    gh label create "auto-rebase:ready" --repo "$REPO" \
      --description "Opts a non-draft PR into auto-rebase without an approval (auto-rebase ready_label)" \
      --color "0e8a16" >/dev/null 2>&1 || true
    # REST endpoint: `gh pr edit --add-label` fails under the workflow token (#2142).
    # Best-effort; add_label_rest logs the API's message on failure.
    add_label_rest "$REPO" "${pr_url##*/}" "auto-rebase:ready" || true
  fi

  # Durable completion claim (#1445): posted ONLY here — after commits are pushed
  # and the PR is open — and referencing the PR number + head SHA. Ordering this
  # after the push/PR is the fix for the #1407 defect where a detailed "Completed"
  # claim was published before the work was durable and then lost to a timeout.
  post_completion_claim "$pr_url" "$head_sha" "$base_ref"

  rm -f "${prompt_file:-}"
}

main "$@"
