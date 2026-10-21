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
# The stamp is bound to the commit's content and position. Amending a stamped
# commit (new tree) or cherry-picking or rebasing it (new parents) keeps the
# trailer text but breaks the match, so a copied stamp marks nothing. It is a
# record dev-lead keeps, not a signature: it guards against copies made by
# accident, not against someone who computes a stamp on purpose.
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
