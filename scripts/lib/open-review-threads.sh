#!/usr/bin/env bash
# open-review-threads.sh — fetch every UNRESOLVED review thread on a PR (#2056).
#
# The defect: dev-lead's fix-reviews and review-changes passes read threads with
# an unpaginated reviewThreads(first:50). Resolved threads sort first, so on a
# long-lived PR the newest open thread falls past the window (PR #1953: 66
# threads, the one open Codex P1 at position 66) and OPEN_THREADS_JSON came out
# empty — the pass "addressed 0 threads". A swallowed fetch error (`|| echo "[]"`)
# looked exactly the same.
#
# ort_fetch_open_threads paginates via pageInfo{hasNextPage endCursor} until
# exhausted and FAILS CLOSED: any failed page fetch, GraphQL `errors` payload,
# malformed response, or hasNextPage without a cursor returns non-zero with
# nothing on stdout, so the caller can never mistake a failure for "nothing to do".

# ort_fetch_open_threads <owner/repo> <pr_number>
# Emit a JSON array of the PR's unresolved review threads (node shape: id
# isResolved isOutdated line path comments(first:5){body author{login __typename}}),
# in GitHub's thread order. Returns non-zero (no stdout) on any fetch failure.
ort_fetch_open_threads() {
  local repo="${1:-}" pr="${2:-}"
  if [[ -z "$repo" ]] || [[ -z "$pr" ]]; then
    echo "::error::ort_fetch_open_threads: repo and PR number are required" >&2
    return 1
  fi

  # GraphQL caps reviewThreads at 100 per page; ORT_PAGE_SIZE overrides for tests.
  local page_size="${ORT_PAGE_SIZE:-100}"
  local query
  query='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$pr) {
        reviewThreads(first:'"$page_size"', after:$cursor) {
          pageInfo { hasNextPage endCursor }
          nodes { id isResolved isOutdated line path comments(first:5) { nodes { body author { login __typename } } } }
        }
      }
    }
  }'

  # Pages accumulate one JSON array per line and merge via stdin at the end, so a
  # large open-thread set never rides on argv (MAX_ARG_STRLEN).
  local acc="" page_response page_open has_next cursor="" prev_cursor="" page_no=0
  local cursor_args=()
  while :; do
    page_no=$((page_no + 1))
    page_response=$(gh api graphql -f query="$query" \
        -F owner="${repo%%/*}" -F repo="${repo##*/}" -F pr="$pr" \
        "${cursor_args[@]}" 2>/dev/null) || {
      echo "::error::ort_fetch_open_threads: review-thread page ${page_no} fetch failed for ${repo}#${pr}" >&2
      return 1
    }
    # Validate the page before trusting it: a missing nodes array or an `errors`
    # payload is a failure, never an empty page.
    if ! printf '%s' "$page_response" | jq -e '
        (.errors // [] | length) == 0
        and ((.data?.repository?.pullRequest?.reviewThreads?.nodes? | type) == "array")' \
        >/dev/null 2>&1; then
      echo "::error::ort_fetch_open_threads: review-thread page ${page_no} for ${repo}#${pr} returned an error or malformed response" >&2
      return 1
    fi
    page_open=$(printf '%s' "$page_response" | jq -c \
      '.data.repository.pullRequest.reviewThreads.nodes | map(select(.isResolved == false))') || return 1
    acc+="${page_open}"$'\n'

    # hasNextPage is Boolean! in the schema: missing/null/non-boolean is a malformed
    # page, never "last page".
    has_next=$(printf '%s' "$page_response" | jq -r '
      .data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage
      | if type == "boolean" then tostring else "invalid" end') || return 1
    if [[ "$has_next" = "invalid" ]]; then
      echo "::error::ort_fetch_open_threads: page ${page_no} for ${repo}#${pr} has a missing or non-boolean hasNextPage" >&2
      return 1
    fi
    [[ "$has_next" = "true" ]] || break
    prev_cursor="$cursor"
    cursor=$(printf '%s' "$page_response" | jq -r \
      '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""') || return 1
    if [[ -z "$cursor" ]]; then
      echo "::error::ort_fetch_open_threads: page ${page_no} for ${repo}#${pr} reports hasNextPage without an endCursor" >&2
      return 1
    fi
    if [[ "$cursor" = "$prev_cursor" ]]; then
      echo "::error::ort_fetch_open_threads: page ${page_no} for ${repo}#${pr} returned an endCursor that did not advance" >&2
      return 1
    fi
    cursor_args=(-f "cursor=${cursor}")
  done

  printf '%s' "$acc" | jq -cs 'add // []'
}
