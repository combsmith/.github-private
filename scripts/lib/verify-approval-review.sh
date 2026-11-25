# shellcheck shell=bash
# scripts/lib/verify-approval-review.sh — post-condition verification for a
# pr-review approval WRITE (issue #1874).
#
# The defect this closes: pr-review posted an approval ANNOUNCEMENT comment while
# the review write silently did not land — `reviewDecision` stayed REVIEW_REQUIRED,
# the PR could not merge, and nothing reported an error (three confirmed strands:
# PRs #1788, #1858, #1860). The mechanism is documented right in the workflow:
# `gh pr review --approve` needs a CLASSIC PAT; the fine-grained fallback
# (DON_PETRY_BOT_GH_PAT) fails `addPullRequestReview` yet can still `gh pr comment`,
# so the announcement lands and the review object never does.
#
# The robust guard is a post-condition check, not a guessed cause: after the write,
# read back `GET /pulls/<n>/reviews` and confirm an APPROVED review by the bot
# account actually exists. This catches BOTH a write that errored AND a write that
# returned success with no review object (#1874 AC5). This function is PURE — the
# network read-back and the loud ::error:: side effects are the caller's job
# (scripts/post-pr-review.sh).

# approval_review_present <reviews_json> <bot_user> <head_sha>
#   <reviews_json> is the reviews array from either the REST reviews endpoint
#   (`.user.login` / `.commit_id`) or `gh pr view --json reviews`
#   (`.author.login` / `.commit.oid`); both shapes are accepted so the same check
#   works regardless of which fetch produced it.
#   Returns 0 iff at least one review is: authored by <bot_user>, in state
#   APPROVED, and (when <head_sha> is non-empty) attached to that commit. An empty
#   <head_sha> matches any commit (used when the head SHA is unknown). Empty or
#   malformed JSON is treated as "absent" (return 1), never an error abort — the
#   caller decides whether an unreadable surface is indeterminate.
approval_review_present() {
  local reviews_json="${1:-}" bot="${2:-}" sha="${3:-}"
  [[ -z "$reviews_json" ]] && return 1
  # `gh api --paginate` can emit one JSON array per page as a concatenated stream
  # (`[...][...]`). Feeding that raw to a single array comprehension counts each
  # page separately, producing a multi-line count and hiding an approval that
  # landed on a later page (#1875). Read every input value and flatten to one array
  # before counting.
  local n
  n=$(jq -rn --arg bot "$bot" --arg sha "$sha" '
    [ inputs ] | flatten
    | map(
        select(((.user.login // .author.login) // "") == $bot)
        | select((.state // "") == "APPROVED")
        | select($sha == "" or ((.commit_id // .commit.oid) // "") == $sha)
      )
    | length' <<< "$reviews_json" 2>/dev/null) || return 1
  # Under `set -e`, return the status explicitly rather than letting a standalone
  # `[ ... ]` be the function's last command (a false test would abort the caller).
  local status=1
  [ "${n:-0}" -gt 0 ] && status=0
  return "$status"
}
