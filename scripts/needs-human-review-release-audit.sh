#!/usr/bin/env bash
set -euo pipefail
#
# needs-human-review-release-audit.sh — bounded audit for #1595 AC #5.
#
# Lists issues that were RELEASED to dev-lead (the `dev-lead` label applied)
# WHILE the `needs-human-review` hold label was attached — the silent-release
# defect behind #1532. This is a read-only, no-LLM gh-API + jq audit; it never
# mutates labels or issues.
#
# It is deliberately BOUNDED, not a full-history sweep: the candidate set is the
# union of issues that currently carry `needs-human-review` and issues that
# currently carry `dev-lead`, restricted to those updated at/after --since. Each
# candidate's label-event stream is then scanned by the pure detector in
# scripts/lib/hold-release-audit.sh. #1532 is the one known case.
#
# Usage:
#   needs-human-review-release-audit.sh [--repo owner/repo] [--since YYYY-MM-DD]
#
# Env (fallbacks for the flags):
#   REPO   owner/repo (default: petry-projects/.github-private)
#   SINCE  ISO date; releases before it are out of scope (default: 2026-08-18)

REPO="${REPO:-petry-projects/.github-private}"
SINCE="${SINCE:-2026-08-18}"
HOLD_LABEL="${HOLD_RELEASE_AUDIT_HOLD_LABEL:-needs-human-review}"
RELEASE_LABEL="${HOLD_RELEASE_AUDIT_RELEASE_LABEL:-dev-lead}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)  REPO="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "::error::unknown argument: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=scripts/lib/hold-release-audit.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/hold-release-audit.sh"

echo "Auditing '$REPO' for issues released to '$RELEASE_LABEL' while '$HOLD_LABEL' was attached (since $SINCE)…"

# ── candidate set: union of hold-labelled and released issues since --since ──────
# `since` filters by updated_at; state=all covers closed issues like #1532.
# NOTE: no `2>/dev/null || true` here. An audit that swallows API failures
# (auth, rate-limit, pagination) would turn them into an empty candidate set and
# report a false "nothing to audit" / "no silent releases". Under set -euo
# pipefail a gh failure aborts loudly instead — a failed audit must never look
# like a clean one.
candidates_of() {
  gh api --paginate -X GET "repos/$REPO/issues" \
    -f state=all -f "labels=$1" -f "since=${SINCE}T00:00:00Z" \
    --jq '.[] | select(.pull_request | not) | .number'
}

candidates="$(
  { candidates_of "$HOLD_LABEL"; candidates_of "$RELEASE_LABEL"; } | sort -n -u
)"

if [[ -z "$candidates" ]]; then
  echo "No candidate issues carry '$HOLD_LABEL' or '$RELEASE_LABEL' since $SINCE — nothing to audit."
  exit 0
fi

# ── scan each candidate's event stream ──────────────────────────────────────────
findings=0
while IFS= read -r n; do
  [[ -z "$n" ]] && continue
  # One pipeline: --paginate emits one array per page, so slurp with `jq -s`
  # ('add // []' yields [] for empty input). Optional chaining (`?`) tolerates
  # null objects (e.g. a deleted actor). As with candidates_of, failures are NOT
  # masked — a gh error aborts under pipefail rather than faking an empty stream.
  events="$(gh api --paginate "repos/$REPO/issues/$n/events" \
    --jq '[.[]? | select(.event? == "labeled" or .event? == "unlabeled")]' | jq -s 'add // []')"
  hits="$(printf '%s' "$events" | hold_release_audit_scan "$SINCE")"
  if [[ -n "$hits" ]]; then
    while IFS= read -r hit; do
      [[ -z "$hit" ]] && continue
      echo "RELEASED-WHILE-HELD #$n — $hit  (https://github.com/$REPO/issues/$n)"
      findings=$((findings + 1))
    done <<< "$hits"
  fi
done <<< "$candidates"

echo "──────────────────────────────────────────────────────────────────────────"
if [[ "$findings" -eq 0 ]]; then
  echo "No silent releases found: no issue was released to '$RELEASE_LABEL' while '$HOLD_LABEL' was attached since $SINCE."
else
  echo "Found $findings issue(s) released while '$HOLD_LABEL' was attached. Review each above."
fi
