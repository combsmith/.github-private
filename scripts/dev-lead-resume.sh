#!/usr/bin/env bash
set -euo pipefail
# dev-lead-resume.sh — event-first resume of a blocked/rate-limited dev-lead
# state (#1407).
#
# When a *clearing event* arrives on a PR — a review submitted or a check_run
# success — this bridge resumes any pending status=rate-limited dev-lead retry
# IMMEDIATELY, instead of waiting for the 2 h dev-lead-retry.yml safety-net cron
# (the #860 "amplifier" the retry cron used to be). It is Bridge A of
# docs/agentic-interaction-model.md §5: the caller resolves the PR from the event
# and this script fires a PAT-backed repository_dispatch so dev-lead's normal
# event-driven retry path wakes — GITHUB_TOKEN cannot fire the downstream event
# (the recursion guard), which is exactly why a PAT bridge is required.
#
# The resume reuses scan_pr_for_rate_limits from dev-lead-retry.sh, so the
# dispatch AND every stop condition are IDENTICAL to the cron path: the shared
# pr_resume_suppressed gate (human markers + per-PR automation budget, #1407
# AC #3), the rate-limit reset window, and the terminal-marker dedupe. The two
# paths cannot diverge, so the event fast-path is provably as safe as the timer.
#
# Env (required):
#   GH_TOKEN    — PAT with repo + contents:write scopes (the dispatch identity)
#   REPO        — "owner/repo" the clearing event fired in
#   PR_NUMBER   — the PR resolved from the clearing event (empty ⇒ clean no-op)
#
# Env (optional):
#   DRY_RUN     — if "true", log what would be dispatched but don't send
#   NOW_ISO     — override current time for testing (ISO-8601 UTC)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Reuse the dispatch + scan + stop-condition logic. dev-lead-retry.sh guards its
# main() behind a BASH_SOURCE check, so sourcing it here exposes the functions
# without running the org-wide scan; it also sources lib/pr-automation-budget.sh.
# shellcheck source=dev-lead-retry.sh
source "$SCRIPT_DIR/dev-lead-retry.sh"

resume_main() {
  local repo="${REPO:-}" pr="${PR_NUMBER:-}"

  # A clearing event that carries no resolvable PR (e.g. a check_run on a commit
  # with no open non-fork PR) is a clean no-op — there is nothing to resume.
  if [[ -z "$repo" ]] || [[ -z "$pr" ]]; then
    echo "::notice::dev-lead-resume: no PR resolved from the clearing event — nothing to resume"
    return 0
  fi

  echo "[resume] event-first resume check for ${repo}#${pr} (dry_run=${DRY_RUN})"
  local dispatched
  dispatched=$(scan_pr_for_rate_limits "$repo" "$pr")
  echo "[resume] dispatched ${dispatched} resume(s) for ${repo}#${pr}"
}

# Run main only when executed directly, not when sourced by unit tests.
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  resume_main "$@"
fi
