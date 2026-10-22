#!/usr/bin/env bash
# git-identity.sh — shared helper for dev-lead scripts.
#
# All dev-lead entry points (fix-issue, fix-ci, fix-reviews) must call
# setup_git_identity before any git commit. Without it, the runner has
# no user.name/user.email and `git commit` aborts with:
#   fatal: empty ident name (for <(null)>) not allowed
#
# Background: prior to centralizing this helper, only dev-lead-fix-issue.sh
# called the local setup_git_identity defined inline. fix-ci and fix-reviews
# silently committed under runner-default identity, which on GitHub-hosted
# runners is unset — causing the commit step to error and the agent run to
# fail. See bmad-bgreat-suite PR #203 dev-lead failures (2026-05-23) for the
# observed symptom.

# setup_git_identity — configure git user.name/user.email for the bot user.
#
# GitHub-hosted runners lack git identity by default; this helper ensures
# commits succeed whether we're committing to the primary repo or secondary checkouts.
#
# BOT_USER env var (default: don-petry) determines the identity. Work in this
# org runs as don-petry, never donpetry-bot, so the fallback is don-petry too
# (#2236). The canonical noreply form (<id>+<login>@users.noreply.github.com) is
# preferred because it links commits to the account's GitHub profile; fall back
# to the id-less form unless the API returned an all-digit id — an unreachable
# API, an error body, or a test stub's "{}" must never land in user.email.
setup_git_identity() {
  local bot="${BOT_USER:-don-petry}"
  local bot_id
  bot_id=$(gh api "users/${bot}" --jq '.id' 2>/dev/null || echo "")
  if [[ $bot_id =~ ^[0-9]+$ ]]; then
    git config user.email "${bot_id}+${bot}@users.noreply.github.com"
  else
    git config user.email "${bot}@users.noreply.github.com"
  fi
  git config user.name "$bot"
}

# dev-lead commit stamp (#2313). Since ADR-0008 dev-lead commits with the same
# noreply email as the owner and every Claude Code session on the owner's
# machine, so the committer identity cannot tell dev-lead's commits from theirs.
# dev-lead marks the commits it creates with a trailer the push guard can check:
#
#   Dev-Lead-Stamp: <hash of "tree <T>\nparent <P>..." — the commit's own tree and
#                    parents, in the order a commit object lists them>
#
# The harness stamps the commits it makes as it makes them, and stamps every
# other commit it is about to publish — the ones the engine made with its own
# `git commit` — just before the push (dev_lead_stamp_unpublished), so every
# commit dev-lead pushes carries a stamp a later run can check.
#
# The stamp is bound to the commit's content and position. Amending a stamped
# commit (new tree) or cherry-picking or rebasing it (new parents) keeps the
# trailer text but breaks the match, so a copied stamp marks nothing. It is a
# record dev-lead keeps, not a signature: it guards against copies made by
# accident, not against someone who computes a stamp on purpose. A reword that
# changes only the message keeps tree and parents, so the stamp still matches:
# dev-lead may then rewrite that commit, which can lose the reworded message but
# never content that is not already in its own commit.
# Not readonly: the push guard sources this file too, and a second `readonly`
# assignment would abort a script running under `set -e`.
DEV_LEAD_STAMP_KEY='Dev-Lead-Stamp'

# dev_lead_stamp_of <tree> [parent...] — echo the stamp for a commit with this
# tree and these parents. Pure: hashes its arguments, reads no repository.
dev_lead_stamp_of() {
  local tree="${1:-}"
  [ -n "$tree" ] || return 1
  shift
  {
    printf 'tree %s\n' "$tree"
    local p
    for p in "$@"; do printf 'parent %s\n' "$p"; done
  } | git hash-object --stdin
}

# dev_lead_stamp_trailer — echo the `Dev-Lead-Stamp: <hash>` line for the commit
# `git commit` is about to make from the current index: tree = the staged tree,
# parents = HEAD (none on an unborn branch) plus MERGE_HEAD when a merge is being
# concluded. Pass it as the last `-m` of the commit so it lands in the trailer
# block. Echoes nothing and returns 1 when the index cannot be written; the
# commit then goes out unstamped and the push guard treats it as foreign.
dev_lead_stamp_trailer() {
  local tree head merge_head_file stamp
  local -a parents=()
  tree=$(git write-tree 2>/dev/null) || return 1
  if head=$(git rev-parse --verify --quiet HEAD 2>/dev/null); then
    parents+=("$head")
  fi
  merge_head_file=$(git rev-parse --git-path MERGE_HEAD 2>/dev/null || true)
  if [ -n "$merge_head_file" ] && [ -f "$merge_head_file" ]; then
    local mh
    while IFS= read -r mh; do
      [ -n "$mh" ] && parents+=("$mh")
    done < "$merge_head_file"
  fi
  stamp=$(dev_lead_stamp_of "$tree" ${parents[@]+"${parents[@]}"}) || return 1
  printf '%s: %s\n' "$DEV_LEAD_STAMP_KEY" "$stamp"
}

# dev_lead_stamp_matches <tree> <parents> <message> — true when <message> has a
# Dev-Lead-Stamp line equal to the stamp of <tree> and the space-separated
# <parents>. Pure apart from `git hash-object --stdin`.
dev_lead_stamp_matches() {
  local tree="${1:-}" parent_list="${2:-}" message="${3:-}" expected claimed
  [ -n "$tree" ] || return 1
  # Word-split on purpose: <parents> is the space-separated %P list.
  # shellcheck disable=SC2086
  expected=$(dev_lead_stamp_of "$tree" $parent_list 2>/dev/null) || return 1
  [ -n "$expected" ] || return 1
  while IFS= read -r claimed; do
    [ "$claimed" = "$expected" ] && return 0
  done < <(sed -nE "s/^${DEV_LEAD_STAMP_KEY}:[[:space:]]*([0-9a-f]+)[[:space:]]*\$/\1/p" <<<"$message")
  return 1
}

# dev_lead_stamp_commit <sha> [parent...] — write a copy of <sha> with the given
# parents and a Dev-Lead-Stamp for its tree and those parents, and echo the new
# SHA. Tree, author, committer, dates and message are kept; an existing
# Dev-Lead-Stamp line is replaced, not duplicated, and the stamp joins the
# message's trailer block so trailers such as Test-Change-Justification stay
# readable. Writes the object only: no ref moves.
dev_lead_stamp_commit() {
  local sha="${1:-}"
  [ -n "$sha" ] || return 1
  shift
  local tree stamp msg ident p
  local -a pargs=() who=()
  tree=$(git rev-parse --verify --quiet "${sha}^{tree}") || return 1
  stamp=$(dev_lead_stamp_of "$tree" "$@") || return 1
  msg=$(git show -s --format='%B' "$sha" \
    | git interpret-trailers --if-exists replace --trailer "${DEV_LEAD_STAMP_KEY}: ${stamp}") || return 1
  ident=$(git show -s --date=raw --format='%an%n%ae%n%ad%n%cn%n%ce%n%cd' "$sha") || return 1
  while IFS= read -r p; do who+=("$p"); done <<<"$ident"
  [ "${#who[@]}" -eq 6 ] || return 1
  for p in "$@"; do pargs+=(-p "$p"); done
  printf '%s\n' "$msg" | GIT_AUTHOR_NAME="${who[0]}" GIT_AUTHOR_EMAIL="${who[1]}" GIT_AUTHOR_DATE="${who[2]}" \
    GIT_COMMITTER_NAME="${who[3]}" GIT_COMMITTER_EMAIL="${who[4]}" GIT_COMMITTER_DATE="${who[5]}" \
    git commit-tree "$tree" ${pargs[@]+"${pargs[@]}"}
}

# dev_lead_stamp_unpublished [exclude...] — make every commit HEAD has beyond
# <exclude> (rev-list arguments, e.g. a remote head and `--remotes=origin`)
# carry a valid Dev-Lead-Stamp, then move HEAD to the stamped copy (#2313).
# Call it right before a push: those commits are dev-lead's unpublished work,
# whoever ran `git commit`. A commit already validly stamped, with no rewritten
# parent, is kept as it is. Echoes one `<old>\t<new>` row per rewritten commit
# so a caller can re-point anything that cites the old SHA. Changes nothing and
# returns 1 if any step fails; the push then goes out unstamped, which a later
# run treats as foreign (rebase or stop, never discard).
dev_lead_stamp_unpublished() {
  local head commits sha parent_list tree msg new rows="" mapped p
  head=$(git rev-parse --verify --quiet HEAD 2>/dev/null) || return 0
  [ -n "$head" ] || return 0
  commits=$(git rev-list --reverse --topo-order HEAD --not "$@" 2>/dev/null) || return 1
  [ -n "$commits" ] || return 0
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    parent_list=$(git show -s --format='%P' "$sha") || return 1
    local -a new_parents=()
    for p in $parent_list; do
      mapped=$(awk -F'\t' -v s="$p" '$1 == s { print $2; exit }' <<<"$rows")
      new_parents+=("${mapped:-$p}")
    done
    if [ "${new_parents[*]-}" = "$parent_list" ]; then
      tree=$(git rev-parse --verify --quiet "${sha}^{tree}") || return 1
      msg=$(git show -s --format='%B' "$sha") || return 1
      dev_lead_stamp_matches "$tree" "$parent_list" "$msg" && continue
    fi
    new=$(dev_lead_stamp_commit "$sha" ${new_parents[@]+"${new_parents[@]}"}) || return 1
    [ -n "$new" ] || return 1
    rows+="${sha}"$'\t'"${new}"$'\n'
  done <<<"$commits"
  [ -n "$rows" ] || return 0
  new=$(awk -F'\t' -v s="$head" '$1 == s { print $2; exit }' <<<"$rows")
  [ -n "$new" ] || return 1
  git update-ref -m "dev-lead: stamp unpublished commits (#2313)" HEAD "$new" "$head" 2>/dev/null || return 1
  printf '%s' "$rows"
}
