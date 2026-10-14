#!/usr/bin/env bash
# apply-repo-settings.sh — apply standard GitHub repository settings.
#
# Applies security_and_analysis settings and disables check-suite auto-trigger
# for apps that queue suites on every push without completing them, which
# permanently blocks auto-merge.
#
# Usage:
#   bash scripts/apply-repo-settings.sh owner/repo
#   REPO=owner/repo bash scripts/apply-repo-settings.sh
#   bash scripts/apply-repo-settings.sh --all
#
# Environment:
#   GH_TOKEN          — GitHub token (must be a classic PAT with repo scope;
#                       OAuth app tokens are rejected by the check-suites API)
#   ORG               — GitHub org (default: combsmith)
#   DEV_LEAD_DRY_RUN  — if "true", print intent but make no API calls
#
# Standards:
#   https://github.com/combsmith/.github/blob/main/standards/push-protection.md
#   https://github.com/combsmith/.github/blob/main/standards/github-settings.md#check-suite-auto-trigger-preferences

ORG="${ORG:-combsmith}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Lazy-load push-protection.sh to avoid polluting test environments with its strict shell options
_ensure_push_protection_sourced() {
  if [ -z "${_push_protection_sourced:-}" ]; then
    # shellcheck source=scripts/lib/push-protection.sh
    source "${SCRIPT_DIR}/lib/push-protection.sh"
    _push_protection_sourced=1
  fi
}

# Apps whose check-suite auto-trigger must be disabled.
# GitHub creates a queued suite on every push when auto-trigger is on; those
# suites are never completed by these apps, permanently blocking auto-merge.
readonly -a RS_DISABLE_APP_IDS=(1236702 347564)  # Claude, CodeRabbit

# ── helpers (sourced by tests) ────────────────────────────────────────────────

# rs_auto_trigger_status <prefs_json> <app_id>
# Echoes the current auto_trigger setting for app_id: "true", "false", or
# "missing" (app not present in preferences — treated as compliant).
rs_auto_trigger_status() {
  local json="${1:-{\}}" app_id="$2"
  printf '%s' "$json" | jq -r --argjson id "$app_id" \
    '.preferences.auto_trigger_checks // []
     | map(select(.app_id == $id))
     | if length == 0 then "missing" else .[0].setting | tostring end'
}

# rs_apply_repo <owner/repo>
# Disables auto-trigger on <owner/repo> for all RS_DISABLE_APP_IDS.
# Apps absent from preferences are compliant by definition — no action taken.
rs_apply_repo() {
  local repo="${1:?rs_apply_repo: repo argument must not be empty}"

  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would disable auto-trigger for apps ${RS_DISABLE_APP_IDS[*]} on ${repo}"
    return 0
  fi

  local prefs
  if ! prefs=$(gh api "repos/${repo}/check-suites/preferences"); then
    echo "[warn] ${repo}: could not read check-suite preferences — verify GH_TOKEN has 'repo' scope (classic PAT) and the repo is accessible" >&2
    return 1
  fi

  local -a to_disable=()
  local app_id status
  for app_id in "${RS_DISABLE_APP_IDS[@]}"; do
    status=$(rs_auto_trigger_status "$prefs" "$app_id")
    case "$status" in
      missing)
        echo "[info] ${repo}: app ${app_id} not present — treating as compliant" ;;
      false)
        echo "[info] ${repo}: app ${app_id} already disabled — skipping" ;;
      true)
        echo "[apply] ${repo}: app ${app_id} auto-trigger enabled — disabling"
        to_disable+=("$app_id") ;;
    esac
  done

  if [ "${#to_disable[@]}" -eq 0 ]; then
    echo "[info] ${repo}: already compliant — nothing to do"
    return 0
  fi

  local payload
  payload=$(printf '%s\n' "${to_disable[@]}" | \
    jq -Rcn '[inputs | tonumber] | map({app_id: ., setting: false}) | {auto_trigger_checks: .}')
  gh api -X PATCH "repos/${repo}/check-suites/preferences" \
    --input - <<<"$payload"
}

# rs_apply_all — apply all settings to every repo in ORG.
rs_apply_all() {
  _ensure_push_protection_sourced
  local repos
  if ! repos=$(gh repo list "${ORG}" --json name --jq '.[].name' --limit 1000); then
    echo "[error] failed to list repositories for org ${ORG}" >&2
    return 1
  fi

  local repo_name
  while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
      REPO="${ORG}/${repo_name}" pp_apply_security_and_analysis
      rs_apply_repo "${ORG}/${repo_name}"
    fi
  done <<< "$repos"
}

# Run main only when executed directly, so tests can source the helpers.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  set -euo pipefail
  _ensure_push_protection_sourced
  if [ "${1:-}" = "--all" ]; then
    rs_apply_all
  else
    REPO="${1:-${REPO:-}}"
    : "${REPO:?Usage: $0 owner/repo | --all  OR  REPO=owner/repo $0}"
    export REPO
    pp_apply_security_and_analysis
    rs_apply_repo "$REPO"
  fi
fi
