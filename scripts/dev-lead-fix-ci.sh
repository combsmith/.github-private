#!/usr/bin/env bash
set -euo pipefail
# dev-lead-fix-ci.sh — handles the fix-ci intent
# Called when a CI check fails on a PR.
# Env: PR_NUMBER, HEAD_SHA, CHECKS_JSON, REPO, GITHUB_REPOSITORY,
#      DEV_LEAD_DRY_RUN, REVIEW_ENGINE, GH_TOKEN
# Optional: PROMPTS_DIR (defaults to prompts/dev-lead relative to CWD)
# Optional: MAX_FAIL_ATTEMPTS — consecutive engine failures before exhaustion (default: 2)

source "$(dirname "${BASH_SOURCE[0]}")/engine.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-identity.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/pr-worktree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/auto-merge.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/pr-automation-budget.sh"
# Structured PR-body backfill (#1805): heal an existing PR whose body is still
# missing 3+ required description sections, once, marker-keyed.
source "$(dirname "${BASH_SOURCE[0]}")/lib/dev-lead-pr-body.sh"
# Sync-stub guard (#2185/#2212): a fix on a standards-sync PR must not change the
# org-standard stub the PR exists to sync.
source "$(dirname "${BASH_SOURCE[0]}")/lib/sync-stub-guard.sh"
# Channel-pin guard (#2220): a pass may never change a caller stub's channel pin.
source "$(dirname "${BASH_SOURCE[0]}")/lib/channel-pin-guard.sh"

PR_NUMBER="${PR_NUMBER:-}"
HEAD_SHA="${HEAD_SHA:-}"
CHECKS_JSON="${CHECKS_JSON:-[]}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
MAX_CI_CYCLES="${MAX_CI_CYCLES:-3}"
LOG_MAX_LINES="${LOG_MAX_LINES:-200}"
MAX_FAIL_ATTEMPTS="${MAX_FAIL_ATTEMPTS:-2}"
MARKER_PREFIX="<!-- dev-lead-fix-ci sha="
EXHAUSTION_MARKER="<!-- dev-lead-fix-ci pr=${PR_NUMBER} status=exhausted -->"
export PROMPTS_DIR="${PROMPTS_DIR:-prompts/dev-lead}"
# Pin PROMPTS_DIR to an absolute path now, while CWD still points at the agent
# checkout — checkout_pr_in_worktree cds into the PR worktree, after which a
# relative PROMPTS_DIR would resolve against the PR branch (issue #448).
PROMPTS_DIR="$(resolve_abs "$PROMPTS_DIR")"
export PROMPTS_DIR

# Checks that never start a fix pass (#2220). `template-drift` compares
# petry-projects/repo-template with the standards baseline: nothing in a PR here
# can clear it, it is not required, and "fixing" it led a pass to repin this
# repo's own dev-lead.yml to a stale channel. Keep in sync with the ci-relay
# job's `if:` in .github/workflows/dev-lead-reusable.yml (asserted by
# tests/dev-lead/unit/test_channel_pin_guard.bats).
FIX_CI_IGNORED_CHECKS=("template-drift")

# fix_ci_trigger_checks: CHECKS_JSON minus the ignored checks, as a JSON array.
fix_ci_trigger_checks() {
  local ignored
  ignored=$(printf '%s\n' "${FIX_CI_IGNORED_CHECKS[@]}" | jq -R . | jq -sc .)
  printf '%s' "${CHECKS_JSON:-[]}" | jq -c --argjson ignored "$ignored" \
    '(if type == "array" then . else [] end) | map(select((.name // "") as $n | ($ignored | index($n)) | not))'
}

# check_idempotency: returns 0 (skip) if this exact SHA was already TERMINALLY
# handled, OR if a PR-level exhaustion marker exists (blocks all future SHAs).
# status=rate-limited is NOT terminal — those runs must be retriable.
check_idempotency() {
  local comments
  # Use standalone jq so the mock stub in tests can return raw JSON.
  # --paginate ensures markers on busy PRs (>30 comments) are not missed.
  comments=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
    | jq -r '.[].body' 2>/dev/null || true)

  # PR-level exhaustion — blocks regardless of SHA
  if echo "$comments" | grep -qF "${EXHAUSTION_MARKER}"; then
    echo "::notice::PR #${PR_NUMBER} is exhausted (repeated engine failures) — skipping all future SHAs"
    return 0
  fi

  # SHA-level idempotency — skip only for terminal statuses (applied, failed,
  # no-changes, declined, refused by the channel-pin guard). status=rate-limited is
  # retriable: do not skip on it so the retry cron can re-run.
  if echo "$comments" | grep -qE "${MARKER_PREFIX}${HEAD_SHA} status=(applied|failed|no-changes|declined|refused)"; then
    echo "::notice::Already handled CI failure at SHA ${HEAD_SHA} with terminal status — skipping"
    return 0
  fi

  return 1
}

# count_recent_failures: count status=failed markers on this PR (any SHA).
# Intentionally excludes status=rate-limited so rate limit events do not count
# toward the exhaustion threshold — rate limits are temporary infrastructure
# events, not evidence of repeated engine errors on this PR's content.
# --paginate ensures an accurate count even on PRs with >30 comments.
count_recent_failures() {
  local pattern="${MARKER_PREFIX}[a-f0-9A-F]* status=failed"
  gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
    | jq "[.[] | select(.body | test(\"${pattern}\"))] | length" 2>/dev/null \
    || echo "0"
}

# has_rate_limited_marker: returns 0 if a status=rate-limited marker already
# exists for HEAD_SHA on this PR. Used to avoid duplicate rate-limited comments.
# --paginate ensures the dedup check is accurate on PRs with >30 comments.
has_rate_limited_marker() {
  local pattern="${MARKER_PREFIX}${HEAD_SHA} status=rate-limited"
  local count
  count=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
    | jq "[.[] | select(.body | test(\"${pattern}\"))] | length" 2>/dev/null \
    || echo "0")
  [ "${count:-0}" -gt 0 ]
}

collect_logs() {
  local check_name="$1" details_url="$2"
  local run_id
  run_id=$(echo "$details_url" | grep -oP '(?<=runs/)\d+' || true)
  if [ -n "$run_id" ]; then
    gh run view "$run_id" --log-failed 2>/dev/null | tail -n "$LOG_MAX_LINES" || true
  else
    # External quality gate (e.g. SonarCloud) — no GitHub Actions run logs exist.
    # Provide the PR diff so the agent can identify what the gate likely flagged.
    printf '# External quality gate — no GitHub Actions run logs available\n'
    printf '# Check: %s | Details: %s\n\n' "$check_name" "$details_url"
    printf '# PR diff (scan for hotspots / quality issues):\n'
    gh pr diff "$PR_NUMBER" --repo "$REPO" 2>/dev/null | head -n 1000 || true
  fi
}

build_prompt() {
  local prompt_template="${PROMPTS_DIR}/fix-ci.md"
  local check_name app_slug details_url
  check_name=$(echo "$CHECKS_JSON" | jq -r '.[0].name // "unknown"')
  app_slug=$(echo "$CHECKS_JSON" | jq -r '.[0].app_slug // "github-actions"')
  details_url=$(echo "$CHECKS_JSON" | jq -r '.[0].details_url // ""')

  export PR_NUMBER PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
  export CHECK_NAME="$check_name" APP_SLUG="$app_slug"
  export HEAD_SHA DETAILS_URL="$details_url"
  export REPO

  FAILURE_LOGS=$(collect_logs "$check_name" "$details_url")
  ANNOTATIONS=$(gh api "repos/${REPO}/check-runs/$(echo "$CHECKS_JSON" | jq -r '.[0].id // empty')/annotations?per_page=100" 2>/dev/null | jq -c '.' || echo "[]")
  export FAILURE_LOGS ANNOTATIONS

  local rendered="/tmp/dev-lead-fix-ci-prompt-$$.md"
  envsubst < "$prompt_template" > "$rendered"
  echo "$rendered"
}

post_summary() {
  local status="$1" details="${2:-}"
  local marker="${MARKER_PREFIX}${HEAD_SHA} status=${status} -->"
  local body="${marker}
## Dev-Lead Fix CI — ${status}
**PR:** #${PR_NUMBER} | **SHA:** \`${HEAD_SHA}\`
${details}"
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would post PR comment: $status"
    echo "$body"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$body"
  fi
}


# post_rate_limited: posts a status=rate-limited marker with embedded reset
# time and check name. Skips if a marker already exists for HEAD_SHA (dedup).
# The check= field lets the retry cron look up current check-run details when
# re-dispatching, giving the engine full failure logs/annotations on retry.
post_rate_limited() {
  # Dedup: don't accumulate multiple rate-limited markers for the same SHA
  if has_rate_limited_marker; then
    echo "::notice::rate-limited marker already posted for SHA ${HEAD_SHA} — skipping duplicate"
    return 0
  fi

  local reset_time
  reset_time=$(cat /tmp/dev-lead-rate-limit-reset 2>/dev/null || true)
  local reset_detail=""
  if [ -n "$reset_time" ]; then
    reset_detail=" reset=${reset_time}"
  fi

  # Embed check name so the retry cron can look up the current check run for logs
  local check_name
  check_name=$(echo "${CHECKS_JSON:-[]}" | jq -r '.[0].name // "CI failure"' 2>/dev/null || echo "CI failure")

  local marker="${MARKER_PREFIX}${HEAD_SHA} status=rate-limited${reset_detail} check=${check_name} -->"
  local details="All engines were rate-limited. The retry cron will re-attempt automatically."
  if [ -n "$reset_time" ]; then
    details="${details} Rate limit resets at: \`${reset_time}\`"
  fi
  local body="${marker}
## Dev-Lead Fix CI — rate-limited
**PR:** #${PR_NUMBER} | **SHA:** \`${HEAD_SHA}\`
${details}"

  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would post PR comment: rate-limited"
    echo "$body"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$body"
  fi
}

post_exhaustion() {
  local reason="$1"
  local body="${EXHAUSTION_MARKER}
## Dev-Lead Fix CI — exhausted

This PR has had **${MAX_FAIL_ATTEMPTS}** consecutive engine failures (timeouts or errors). Automated CI fixing has been paused to avoid consuming further tokens.

**Reason for last failure:** ${reason}

To re-enable, delete this comment or push a new commit with a substantially different change."
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would post exhaustion comment"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$body"
  fi
}

# flag_sync_stub_drift <rows> — the sync-stub guard refused the push (#2212).
# Same escalation and declined comment as the review intents' flag_sync_stub_drift
# in dev-lead-fix-reviews.sh: hold the PR, answer as declined with a pointer to
# each template, disable auto-merge. <rows> are `path\ttemplate` lines (empty
# when the scan was unknown).
flag_sync_stub_drift() {
  local rows="$1" marker="<!-- dev-lead-sync-stub-drift pr=${PR_NUMBER} intent=fix-ci -->"
  _AM_NEEDS_RESTORE=0
  # Label first so the flag comment can say when the PR could not be held (#2142).
  apply_hold_label "$REPO" "$PR_NUMBER" || true
  if gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
       | jq -r '.[].body // ""' 2>/dev/null | grep -qF "$marker"; then
    echo "::notice::PR #${PR_NUMBER} already flagged for synced-stub drift for intent=fix-ci — not reposting"
    post_hold_failure_note "$REPO" "$PR_NUMBER"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "${marker}
$(ssg_declined_body "fix-ci" "$rows")${HOLD_LABEL_NOTE}" \
      || echo "::warning::could not post sync-stub flag comment on PR #${PR_NUMBER}"
  fi
  disable_auto_merge_for_hold "$REPO" "$PR_NUMBER" || true
  return 0
}

# fix_ci_channel_pin_guard <pre_pass_sha> [base_rev] — refuse the push when the
# pass changed a caller stub's first-party channel pin (#2220): escalate, record a
# terminal `refused` marker for this SHA, and return 1. Returns 0 when clean.
fix_ci_channel_pin_guard() {
  local pre="$1" base="${2:-}" out rc=0
  out=$(cpg_scan_pass "$pre" HEAD "$base") || rc=$?
  [ "$rc" -eq 0 ] && return 0
  echo "::error::Channel-pin guard: the fix-ci pass changed a caller stub's channel pin ($(printf '%s\n' "$out" | head -1)) — refusing to push (#2220)"
  cpg_flag_refused "fix-ci" "$(printf '%s\n' "$out" | sed '1d')"
  post_summary "refused" "The pass changed a caller stub's channel pin, so nothing was pushed. See the escalation comment (#2220)."
  return 1
}

main() {
  if [ -z "$PR_NUMBER" ] || [ -z "$HEAD_SHA" ]; then
    echo "::error::PR_NUMBER and HEAD_SHA are required"
    exit 1
  fi

  # Ignored checks (#2220): drop them before anything else; a dispatch whose
  # checks are all ignored starts no pass. Covers relayed failures and retry-cron
  # re-dispatches alike. An empty or unparseable CHECKS_JSON is left as it was.
  local trigger_checks
  if trigger_checks=$(fix_ci_trigger_checks 2>/dev/null) \
     && [ "$(jq 'length' <<<"$CHECKS_JSON" 2>/dev/null || echo 0)" -gt 0 ]; then
    if [ "$(jq 'length' <<<"$trigger_checks")" -eq 0 ]; then
      echo "::notice::fix-ci: $(jq -r '[.[]?.name // empty] | join(", ")' <<<"$CHECKS_JSON" 2>/dev/null) is not a fix-ci trigger — skipping (#2220)"
      exit 0
    fi
    CHECKS_JSON="$trigger_checks"
  fi

  # A budget escalation that cannot apply its hold label fails the run (#2142);
  # the auto-merge trap below keeps the guard as its last handler.
  trap hold_label_exit_guard EXIT

  # Per-PR automation budget (#926): if this PR has exhausted its lifetime
  # automation budget since the last human interaction, stop before any writes.
  # Checked before holding auto-merge so the escalation's auto-merge disable is
  # not undone by the restore_auto_merge EXIT trap.
  if [ "${DEV_LEAD_DRY_RUN:-false}" != "true" ] && enforce_pr_budget "$PR_NUMBER" "$REPO"; then
    echo "::warning::PR #${PR_NUMBER} automation budget exhausted — skipping fix-ci"
    exit 0
  fi

  # Hold auto-merge OFF while we work so a review approval landing mid-run can't
  # merge (and delete) the branch out from under us. Install the trap and hold
  # before check_idempotency so an approval landing during the API/JQ scan can't
  # merge the branch before the trap is in place. restore_auto_merge is
  # idempotent (_AM_NEEDS_RESTORE guards it), so the EXIT trap no-ops cleanly
  # when check_idempotency causes an early exit with nothing to restore.
  # checkout_pr_in_worktree chains its own cleanup onto this trap.
  # shellcheck disable=SC2154 # rc is set by the trap string itself
  trap 'rc=$?; restore_auto_merge; hold_label_exit_guard "$rc"' EXIT
  hold_auto_merge

  if check_idempotency; then
    echo "::notice::Already handled CI failure at SHA $HEAD_SHA (or PR exhausted) — skipping"
    exit 0
  fi

  local prompt_file
  prompt_file=$(build_prompt)

  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] fix-ci: would run engine with prompt: $prompt_file"
    post_summary "dry-run" "Would apply fix for: $(echo "$CHECKS_JSON" | jq -r '[.[].name] | join(", ")')"
    exit 0
  fi

  # Checkout the PR branch for modification, in an isolated worktree so the
  # branch switch never overwrites the agent's own prompts/scripts (issue #448).
  checkout_pr_in_worktree "$PR_NUMBER" "$REPO"
  # The head this pass starts from: the sync-stub and channel-pin guards compare against it.
  # base_rev is the PR's base, for the channel-pin guard (#2220).
  local pre_pass_sha base_ref base_rev=""
  pre_pass_sha=$(git rev-parse HEAD 2>/dev/null || true)
  base_ref=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.base.ref // empty' 2>/dev/null || true)
  if [ -n "$base_ref" ] && git fetch -q origin "$base_ref" 2>/dev/null; then
    base_rev="origin/${base_ref}"
  fi

  # Backfill the five required description sections into a pre-existing PR whose
  # body still lacks them (#1805). Idempotent + marker-keyed, so open PRs heal on
  # their next dev-lead pass without churning on every run.
  dlpb_backfill_pr_body "$PR_NUMBER" "$REPO" || true

  local cycle=1
  while [ "$cycle" -le "$MAX_CI_CYCLES" ]; do
    echo "  [fix-ci] cycle $cycle/$MAX_CI_CYCLES"

    local engine_rc=0
    run_writer_with_fallback "$prompt_file" "fix-ci" || engine_rc=$?

    if [ "$engine_rc" -ne 0 ]; then
      if [ "$engine_rc" -eq 2 ]; then
        # Rate-limited (all engines exhausted) — not a real failure; do not
        # count toward exhaustion threshold. Post rate-limited marker for retry cron.
        echo "::warning::All engines rate-limited — posting rate-limited marker for retry cron"
        post_rate_limited
        exit 2
      fi

      # Real engine failure (exit 1 or 124) — counts toward exhaustion threshold
      local reason="Engine invocation failed (exit ${engine_rc})"
      [ "$engine_rc" -eq 124 ] && reason="Engine timed out — PR may be too large for automated fixing"
      post_summary "failed" "$reason"

      # Check if we've hit the consecutive-failure threshold for this PR
      local fail_count
      fail_count=$(count_recent_failures)
      echo "  [fix-ci] consecutive failures on this PR: $fail_count (threshold: $MAX_FAIL_ATTEMPTS)"
      if [ "$fail_count" -ge "$MAX_FAIL_ATTEMPTS" ]; then
        echo "::warning::Exhaustion threshold reached — posting PR-level block to prevent further token spend"
        post_exhaustion "$reason"
      fi
      exit 1
    fi

    # Check if there are changes to push.
    # git status --porcelain catches untracked files that git diff misses.
    # Also detect engine-committed-but-not-pushed changes via upstream comparison.
    local has_uncommitted=false has_unpushed=false
    [ -n "$(git status --porcelain)" ] && has_uncommitted=true
    local upstream
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null || true)
    if [ -n "$upstream" ]; then
      git log "${upstream}..HEAD" --oneline 2>/dev/null | grep -q . && has_unpushed=true
    elif [ -n "${HEAD_SHA:-}" ]; then
      git log "${HEAD_SHA}..HEAD" --oneline 2>/dev/null | grep -q . && has_unpushed=true
    fi

    if ! $has_uncommitted && ! $has_unpushed; then
      echo "  [fix-ci] no changes made by engine"
      post_summary "no-changes" "Engine ran but made no changes."
      exit 0
    fi

    if $has_uncommitted; then
      # GitHub-hosted runners have no default git identity; configure it
      # before committing or commit fails with "fatal: empty ident name".
      setup_git_identity
      git add -A
      git commit -m "fix(ci): auto-fix for $(echo "$CHECKS_JSON" | jq -r '.[0].name // "CI failure"') [skip ci-relay]"
    fi
    # Sync-stub guard (#2185/#2212): on a `standards-sync` PR a CI fix must not
    # change a stub copied verbatim from petry-projects/.github/standards/ (e.g.
    # SHA-pinning a `uses:` line a linter flags). Same rule as the review intents:
    # the PR is read only when the pass changed a file, and an unreadable PR fails
    # closed only when a header stub was touched.
    # Reconcile with the true remote head BEFORE evaluating, so the tree checked is
    # the tree push_with_merge_guard pushes (its own reconcile is then a no-op). A
    # failure here is left to push_with_merge_guard to handle.
    incorporate_remote_head || true
    local ssg_pr="" ssg_out ssg_rc=0
    if ssg_pass_touches_stubs "$pre_pass_sha" HEAD; then
      ssg_pr=$(ssg_read_pr "$REPO" "$PR_NUMBER")
    fi
    local ssg_head_ref=""
    if [ -n "$ssg_pr" ]; then
      ssg_head_ref=$(jq -r '.head?.ref // empty' <<<"$ssg_pr" 2>/dev/null) || ssg_head_ref=""
    fi
    ssg_out=$(ssg_evaluate "$pre_pass_sha" HEAD "$ssg_pr" "$ssg_head_ref") || ssg_rc=$?
    if [ "$ssg_rc" -ne 0 ]; then
      echo "::error::Sync-stub guard: the fix-ci pass changed a synced org-standard stub on a standards-sync PR ($(printf '%s\n' "$ssg_out" | head -1)) — refusing to push (#2212)"
      flag_sync_stub_drift "$(printf '%s\n' "$ssg_out" | sed '1d')"
      post_summary "declined" "The fix changed a synced org-standard stub on this standards-sync PR, so it was not pushed. See the declined comment (#2212)."
      exit 0
    fi
    # Channel-pin guard (#2220): never push a pass that repins a caller stub.
    fix_ci_channel_pin_guard "$pre_pass_sha" "$base_rev" || exit 1
    # push_with_merge_guard exits 0 cleanly if the PR was merged/closed mid-run
    # (its branch deleted); a genuine push failure still aborts with exit 1.
    push_with_merge_guard || exit 1

    post_summary "applied" "Fix committed and pushed. Waiting for CI."
    break
  done

  rm -f "$prompt_file"
}

# Source-guard: tests source this to exercise the helpers; CI executes it.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
