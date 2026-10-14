#!/usr/bin/env bats
# GitHub API quota refusal, reported distinctly (#2297, first slice of #2197).
#
#   AC #1  gh_quota_refused classifies a failed gh call's output: the primary
#          limit, the secondary limit and an HTTP 429 are quota refusals; a 404,
#          422, 5xx, network error, empty output and model-provider rate-limit
#          text are not.
#   AC #2  gh_api_read passes a successful read through; on a quota refusal it
#          prints one ::error:: line naming the call and returns
#          GH_QUOTA_EXHAUSTED_RC; any other failure keeps gh's own exit code and
#          stderr.
#
# No live network: `gh` is always a stub on PATH.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/gh-quota.sh"

PRIMARY_BODY='{"message":"API rate limit exceeded for user ID 12345. If you reach out to GitHub Support for help, please include the request ID ABCD:1234.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api","status":"403"}'
PRIMARY_ERR='gh: API rate limit exceeded for user ID 12345. If you reach out to GitHub Support for help, please include the request ID ABCD:1234. (HTTP 403)'
SECONDARY_BODY='{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api#about-secondary-rate-limits","status":"403"}'
SECONDARY_ERR='gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)'
TOO_MANY_ERR='gh: Too Many Requests (HTTP 429)'
NOT_FOUND_BODY='{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
NOT_FOUND_ERR='gh: Not Found (HTTP 404)'

setup() {
  bats_require_minimum_version 1.5.0
  # shellcheck source=../../../scripts/lib/gh-quota.sh
  source "$LIB"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  # The stub prints $GH_STUB_OUT to stdout and $GH_STUB_ERR to stderr, records
  # its arguments, and exits $GH_STUB_RC.
  cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_STUB_CALLS"
[ -n "${GH_STUB_OUT:-}" ] && printf '%s\n' "$GH_STUB_OUT"
[ -n "${GH_STUB_ERR:-}" ] && printf '%s\n' "$GH_STUB_ERR" >&2
exit "${GH_STUB_RC:-0}"
EOF
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_CALLS="$BATS_TEST_TMPDIR/gh-calls"
  : > "$GH_STUB_CALLS"
  unset GH_STUB_OUT GH_STUB_ERR GH_STUB_RC
}

stub_gh() {  # stub_gh <rc> <stdout> <stderr>
  export GH_STUB_RC="$1" GH_STUB_OUT="$2" GH_STUB_ERR="$3"
}

# --- AC #1: the classifier --------------------------------------------------

@test "gh_quota_refused: the primary 403 body is a quota refusal" {
  run gh_quota_refused "$PRIMARY_BODY"
  [ "$status" -eq 0 ]
  run gh_quota_refused "$PRIMARY_ERR"
  [ "$status" -eq 0 ]
}

@test "gh_quota_refused: GraphQL's primary-limit message is a quota refusal" {
  run gh_quota_refused 'GraphQL: API rate limit already exceeded for user ID 12345.'
  [ "$status" -eq 0 ]
}

@test "gh_quota_refused: the secondary-limit body is a quota refusal" {
  run gh_quota_refused "$SECONDARY_BODY"
  [ "$status" -eq 0 ]
  run gh_quota_refused "$SECONDARY_ERR"
  [ "$status" -eq 0 ]
}

@test "gh_quota_refused: an HTTP 429 is a quota refusal" {
  run gh_quota_refused "$TOO_MANY_ERR"
  [ "$status" -eq 0 ]
}

@test "gh_quota_refused: a 404 is not a quota refusal" {
  run gh_quota_refused "$NOT_FOUND_BODY"$'\n'"$NOT_FOUND_ERR"
  [ "$status" -ne 0 ]
}

@test "gh_quota_refused: 422, 5xx and network errors are not quota refusals" {
  local text
  for text in \
    'gh: Validation Failed (HTTP 422)' \
    'gh: Server Error (HTTP 500)' \
    'gh: HTTP 502: Bad Gateway' \
    'gh: HTTP 4290' \
    'error connecting to api.github.com' \
    'Post "https://api.github.com/graphql": dial tcp: lookup api.github.com: no such host'; do
    run gh_quota_refused "$text"
    [ "$status" -ne 0 ]
  done
}

@test "gh_quota_refused: empty output is not a quota refusal" {
  run gh_quota_refused ''
  [ "$status" -ne 0 ]
  run gh_quota_refused
  [ "$status" -ne 0 ]
}

@test "gh_quota_refused: model-provider rate-limit text is not a GitHub quota refusal" {
  local text
  for text in \
    '{"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit"}}' \
    'API Error: 429 {"type":"error","error":{"type":"rate_limit_error"}}' \
    'Rate limit reached for gpt-4o in organization org-x on tokens per min.' \
    '[API Error: got status: 429 Too Many Requests. RESOURCE_EXHAUSTED: Quota exceeded for metric]' \
    "You've hit your limit · resets 5pm" \
    'Claude AI usage limit reached'; do
    run gh_quota_refused "$text"
    [ "$status" -ne 0 ]
  done
}

# --- AC #2: the read wrapper ------------------------------------------------

@test "GH_QUOTA_EXHAUSTED_RC is distinct from every exit code gh uses" {
  [ -n "$GH_QUOTA_EXHAUSTED_RC" ]
  local rc
  for rc in 0 1 2 4 8; do
    [ "$GH_QUOTA_EXHAUSTED_RC" -ne "$rc" ]
  done
}

@test "gh_api_read: a successful read passes its output through" {
  stub_gh 0 '["bug","enhancement"]' ''
  run --separate-stderr gh_api_read "repos/o/r/pulls/7" --jq '[.labels[]?.name]'
  [ "$status" -eq 0 ]
  [ "$output" = '["bug","enhancement"]' ]
  [ -z "$stderr" ]
  [ "$(cat "$GH_STUB_CALLS")" = 'api repos/o/r/pulls/7 --jq [.labels[]?.name]' ]
}

@test "gh_api_read: the primary 403 returns the quota code and one ::error:: line naming the call" {
  stub_gh 1 "$PRIMARY_BODY" "$PRIMARY_ERR"
  run --separate-stderr gh_api_read "repos/o/r/pulls/7" --jq '[.labels[]?.name]'
  [ "$status" -eq "$GH_QUOTA_EXHAUSTED_RC" ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | wc -l)" -eq 1 ]
  [[ "$stderr" == "::error::"* ]]
  [[ "$stderr" == *"GitHub API quota exhausted"* ]]
  [[ "$stderr" == *"gh api repos/o/r/pulls/7"* ]]
}

@test "gh_api_read: the secondary limit returns the quota code" {
  stub_gh 1 "$SECONDARY_BODY" "$SECONDARY_ERR"
  run --separate-stderr gh_api_read "repos/o/r/issues/7/comments"
  [ "$status" -eq "$GH_QUOTA_EXHAUSTED_RC" ]
  [[ "$stderr" == "::error::"*"GitHub API quota exhausted"* ]]
}

@test "gh_api_read: an HTTP 429 returns the quota code" {
  stub_gh 1 '' "$TOO_MANY_ERR"
  run --separate-stderr gh_api_read "repos/o/r/pulls/7"
  [ "$status" -eq "$GH_QUOTA_EXHAUSTED_RC" ]
  [[ "$stderr" == "::error::"*"GitHub API quota exhausted"* ]]
}

@test "gh_api_read: a 404 keeps gh's exit code and stderr, with no quota line" {
  stub_gh 1 "$NOT_FOUND_BODY" "$NOT_FOUND_ERR"
  run --separate-stderr gh_api_read "repos/o/r/pulls/7"
  [ "$status" -eq 1 ]
  [ "$stderr" = "$NOT_FOUND_ERR" ]
  [[ "$stderr" != *"::error::"* ]]
}

@test "gh_api_read: a failure with empty output keeps gh's exit code" {
  stub_gh 4 '' ''
  run --separate-stderr gh_api_read "repos/o/r/pulls/7"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}
