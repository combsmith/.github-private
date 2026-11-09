#!/usr/bin/env bash
# dependabot-provenance.sh — the Dependabot commit-provenance rule, for pr-review (#2481).
#
# pr-review reviews and approves a PR opened by Dependabot (the sweep dispatches
# it, scripts/sweep-stuck-reviews.sh). It keeps the rule dependabot-automerge
# applies before it approves (combsmith/.github
# .github/scripts/dependabot/lib/gates.sh, dependabot_provenance_gate, #1400):
# every commit on the PR is Dependabot's, or a branch-update merge commit the
# automerge App made through the update-branch API. A commit pushed by anyone
# else blocks the approval. The two copies must stay in step; the gate below is
# a port of the central one with the same verdicts.
#
# Source this file; it defines functions only.
#
#   dependabot_is_author <login>
#   dependabot_provenance_gate <pr_json> <commits_json> [trusted_login] [expected_sha]
#   dependabot_provenance_check <owner/repo> <number> [expected_sha]
#
# Verdicts: 0 pass, 1 block (a verdict about the commits), 2 unreadable (the
# reads cannot be trusted; no verdict). Callers treat 1 and 2 as "do not
# approve", and must not report 2 as a foreign commit.

# REST spelling of the Dependabot App's login (commit and PR author).
DEPENDABOT_LOGIN="dependabot[bot]"

# The automerge App whose update-branch merge commits are allowed. Same login as
# PR_BUDGET_MECHANICAL_LOGINS in pr-automation-budget.sh. Set but empty allows
# Dependabot's own commits only (hence `=`, not `:=`).
: "${DEPENDABOT_AUTOMERGE_LOGIN=combsmith-dependabot-automrg[bot]}"

# dependabot_is_author <login>
#   0 when <login> is the Dependabot App: `app/dependabot` (gh pr view/list) or
#   `dependabot[bot]` (REST). A bare `dependabot` is GraphQL's spelling but also
#   a valid User login, so it is not accepted.
dependabot_is_author() {
  case "${1:-}" in
    "app/dependabot" | "$DEPENDABOT_LOGIN") return 0 ;;
  esac
  return 1
}

# dependabot_provenance_gate <pr_json> <commits_json> [trusted_login] [expected_sha]
#   pr_json      REST `GET /repos/{r}/pulls/{n}` (head.sha, commits).
#   commits_json REST `GET /repos/{r}/pulls/{n}/commits`: a flat array, or the
#                pages `gh api --paginate --slurp` produces.
#   trusted_login the automerge App; its verified web-flow merge commits (2+
#                parents) are allowed. Empty allows Dependabot's commits only.
#   expected_sha optional; block unless the PR head is this commit.
#   Passes only when the whole commit list was read (its length is the PR's
#   commit count and it holds the head), at least one commit is Dependabot's,
#   and every commit is Dependabot's (committed by web-flow or Dependabot,
#   GitHub-verified) or a trusted merge. Prints the reason.
dependabot_provenance_gate() {
  local pr_json="${1:-}" commits_json="${2:-}" trusted="${3:-}" expected="${4:-}" out verdict reason

  # Both documents go through stdin: a long commit list can exceed the
  # per-argument size limit of --argjson.
  out=$({ printf '%s\n' "$pr_json"; printf '%s\n' "$commits_json"; } | jq -rs \
      --arg trusted "$trusted" --arg expected "$expected" --arg bot "$DEPENDABOT_LOGIN" '
    if length != 2 then error("expected two documents") else . end
    | .[0] as $pr | .[1] as $pages
    | ($pr.head.sha // "") as $head
    | ($pr.commits // -1) as $count
    | ([$pages | if type == "array" then flatten[] else empty end
        | select(type == "object")]) as $commits
    | def verified: (.commit.verification.verified // false) == true;
      def author: (.author.login // "");
      def committer: (.committer.login // "");
      def from_dependabot:
        author == $bot and (committer | IN("web-flow", $bot)) and verified;
      def trusted_merge:
        $trusted != "" and author == $trusted and committer == "web-flow"
        and ((.parents // []) | length) >= 2 and verified;
      ([$commits[] | select((from_dependabot or trusted_merge) | not)
        | "\(.sha // "?" | .[0:7]) (author \(author | if . == "" then "unknown" else . end), committer \(committer | if . == "" then "unknown" else . end)\(if verified then "" else ", unverified" end))"]) as $foreign
    | if $head == "" then "unreadable\tPR head commit unknown"
      elif ($expected != "" and $head != $expected) then
        "block\thead moved to \($head[0:7]) (expected \($expected[0:7]))"
      elif ($commits | length) == 0 then "unreadable\tno commits read"
      elif ($commits | length) != $count then
        "unreadable\tread \($commits | length) of \($count) commits — cannot verify them all"
      elif ([$commits[] | .sha] | index($head)) == null then
        "unreadable\thead \($head[0:7]) not in the commit list"
      elif ($foreign | length) > 0 then
        "block\t\($foreign | length) commit(s) not from Dependabot: \($foreign | join(", "))"
      elif ([$commits[] | select(from_dependabot)] | length) == 0 then
        "block\tno Dependabot commit on the PR"
      else
        "pass\tall \($commits | length) commit(s) from Dependabot\(if $trusted != "" then " or \($trusted) branch updates" else "" end) (head \($head[0:7]))"
      end
  ' 2>/dev/null) || out=""

  verdict="${out%%$'\t'*}"
  reason="${out#*$'\t'}"
  case "$verdict" in
    pass) echo "$reason"; return 0 ;;
    block) echo "$reason"; return 1 ;;
    unreadable) echo "$reason"; return 2 ;;
  esac
  echo "could not evaluate commit provenance (malformed input)"
  return 2
}

# dependabot_provenance_check <owner/repo> <number> [expected_sha]
#   Reads the PR and all its commits with gh and applies
#   dependabot_provenance_gate, trusting DEPENDABOT_AUTOMERGE_LOGIN's merges. The
#   PR itself must have been opened by Dependabot. Sets DEPENDABOT_GATE_REASON.
#   Returns 0 pass, 1 block, 2 unreadable. The head is read again after the
#   commit list; if it moved, the verdict describes nothing that exists (2).
# shellcheck disable=SC2034 # DEPENDABOT_GATE_REASON is read by the caller
dependabot_provenance_check() {
  local repo="${1:-}" pr="${2:-}" expected="${3:-}" pr_json commits_json head user again rc=0
  DEPENDABOT_GATE_REASON=""

  if ! [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$pr" =~ ^[0-9]+$ ]]; then
    DEPENDABOT_GATE_REASON="malformed repository or pull request number"
    return 2
  fi
  if ! pr_json=$(gh api "repos/${repo}/pulls/${pr}" 2>/dev/null) || [ -z "$pr_json" ]; then
    DEPENDABOT_GATE_REASON="could not read the pull request"
    return 2
  fi
  user=$(jq -r '.user.login // ""' <<< "$pr_json" 2>/dev/null) || user=""
  if [ -z "$user" ]; then
    DEPENDABOT_GATE_REASON="could not read the pull request author"
    return 2
  fi
  if [ "$user" != "$DEPENDABOT_LOGIN" ]; then
    DEPENDABOT_GATE_REASON="the pull request was not opened by Dependabot (author $user)"
    return 1
  fi
  head=$(jq -r '.head.sha // ""' <<< "$pr_json" 2>/dev/null) || head=""
  if ! commits_json=$(gh api "repos/${repo}/pulls/${pr}/commits?per_page=100" --paginate --slurp 2>/dev/null) \
      || [ -z "$commits_json" ]; then
    DEPENDABOT_GATE_REASON="could not read the pull request's commits"
    return 2
  fi
  DEPENDABOT_GATE_REASON=$(dependabot_provenance_gate "$pr_json" "$commits_json" \
    "$DEPENDABOT_AUTOMERGE_LOGIN" "$expected") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if ! again=$(gh api "repos/${repo}/pulls/${pr}" 2>/dev/null) \
      || [ "$(jq -r '.head.sha // ""' <<< "$again" 2>/dev/null)" != "$head" ]; then
    DEPENDABOT_GATE_REASON="the head changed while it was being read"
    return 2
  fi
  return 0
}
