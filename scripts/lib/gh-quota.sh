# shellcheck shell=bash
# scripts/lib/gh-quota.sh — recognise a GitHub API quota refusal and report it
# distinctly (#2297, first slice of #2197).
#
# The fleet and every interactive session share one GitHub API quota. When it
# runs out, `gh api` exits non-zero with a 403 ("API rate limit exceeded for
# user ID …", or "You have exceeded a secondary rate limit") or a 429. A read
# written as `gh api … 2>/dev/null || x=''` turns that into "no data", and a
# guard then acts on an empty answer it never received.
#
# GitHub quota only. Model-provider limits are engine.sh's is_rate_limited; the
# patterns here are GitHub's own wording (and gh's "(HTTP 429)" suffix), so a
# provider's rate_limit_error, "Rate limit reached" or bare 429 does not match.
#
# Definitions only: sourcing this file runs nothing and reads no environment.

# Exit code gh_api_read returns on a quota refusal, and no other failure. gh
# itself exits 0, 1, 2 (cancelled), 4 (auth) or 8 (pending checks); 75 is
# EX_TEMPFAIL from sysexits.h — the read may succeed after the quota resets.
# shellcheck disable=SC2034  # read by the scripts that source this file
GH_QUOTA_EXHAUSTED_RC=75

# gh_quota_refused <text>
#   Exit 0 when <text> — the captured stdout and/or stderr of a failed gh call —
#   is a GitHub quota refusal: the primary limit (REST "API rate limit exceeded",
#   GraphQL "API rate limit already exceeded"), the secondary limit, or HTTP 429.
#   Exit 1 for anything else, including empty text.
gh_quota_refused() {
  local text="${1:-}"
  [ -n "$text" ] || return 1
  printf '%s\n' "$text" \
    | grep -qiE 'API rate limit (already )?exceeded|secondary rate limit|HTTP 429([^0-9]|$)'
}

# gh_quota_error <gh api args…>
#   Print the one ::error:: line for a quota-refused `gh api <args…>` call to
#   stderr. Shared by gh_api_read and any caller that discards the wrapper's
#   stderr, so the line reads the same wherever it is logged.
gh_quota_error() {
  local call="gh api $*"
  call="${call//$'\n'/ }"
  echo "::error::GitHub API quota exhausted: '${call}' was refused (rate limit); its result is unknown, not empty" >&2
}

# gh_api_read <gh api args…>
#   Run `gh api <args…>`. On success print its stdout (and any stderr) as gh
#   did and exit 0. On a quota refusal print only the gh_quota_error line and
#   exit GH_QUOTA_EXHAUSTED_RC; the refusal body is not passed on as data. Any
#   other failure prints gh's own stdout and stderr and keeps gh's exit code.
gh_api_read() {
  local out_file err_file rc=0
  out_file=$(mktemp) || { gh api "$@"; return; }
  err_file=$(mktemp) || { rm -f "$out_file"; gh api "$@"; return; }
  gh api "$@" >"$out_file" 2>"$err_file" || rc=$?
  if [ "$rc" -ne 0 ] && gh_quota_refused "$(cat "$out_file" "$err_file")"; then
    rm -f "$out_file" "$err_file"
    gh_quota_error "$@"
    return "$GH_QUOTA_EXHAUSTED_RC"
  fi
  cat "$out_file"
  cat "$err_file" >&2
  rm -f "$out_file" "$err_file"
  return "$rc"
}
