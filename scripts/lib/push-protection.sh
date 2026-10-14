#!/usr/bin/env bash
# push-protection.sh — required security_and_analysis settings and apply helper.
#
# Sourced by scripts that need to enforce or audit the push-protection standard:
#   https://github.com/petry-projects/.github/blob/main/standards/push-protection.md
#
# PP_REQUIRED_SA_SETTINGS lists the security_and_analysis keys that must be
# "enabled" on every petry-projects repository.  Adding a key here
# automatically extends both apply and audit logic that sources this file.
#
# Usage:
#   source scripts/lib/push-protection.sh
#   REPO=owner/repo pp_apply_security_and_analysis

readonly -a PP_REQUIRED_SA_SETTINGS=(
  secret_scanning
  secret_scanning_push_protection
  secret_scanning_ai_detection
  secret_scanning_non_provider_patterns
  dependabot_security_updates
)

# pp_apply_security_and_analysis
#   Patches all PP_REQUIRED_SA_SETTINGS to "enabled" on $REPO.
#   Honours DEV_LEAD_DRY_RUN=true (prints intent, makes no API call).
pp_apply_security_and_analysis() {
  : "${REPO:?pp_apply_security_and_analysis: REPO must be set}"

  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would patch security_and_analysis on ${REPO}: ${PP_REQUIRED_SA_SETTINGS[*]}"
    return 0
  fi

  # Enable Dependabot alerts — prerequisite for dependabot_security_updates.
  gh api -X PUT "repos/${REPO}/vulnerability-alerts" --silent 2>/dev/null || \
    echo "[warn] ${REPO} — could not enable vulnerability alerts (prerequisite for dependabot_security_updates)" >&2

  local failures=0
  for key in "${PP_REQUIRED_SA_SETTINGS[@]}"; do
    local payload
    payload=$(jq -n --arg k "$key" '{"security_and_analysis": {($k): {"status": "enabled"}}}')
    if ! gh api -X PATCH "repos/${REPO}" --input - <<<"$payload"; then
      echo "[warn] ${REPO} — could not enable ${key} (may require Advanced Security)" >&2
      failures=$((failures + 1))
    fi
  done
  return 0
}
