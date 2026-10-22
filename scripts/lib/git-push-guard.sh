#!/usr/bin/env bash
# git-push-guard.sh — no-clobber push helper for dev-lead (#1311, #1607).
#
# dev-lead must never overwrite a commit it has not seen. A concurrent writer —
# a human pushing a steering commit to the same branch, or the auto-rebase bot —
# can advance the remote head after dev-lead checked the branch out. Two defects
# this guard closes:
#
#   #1311  A plain push can only be REJECTED (never overwrites); a rewritten
#          branch was force-with-leased, aborting if the remote advanced beyond
#          the remote-tracking ref captured at checkout.
#
#   #1607  A bare --force-with-lease leases against the *remote-tracking ref*.
#          If any `git fetch` earlier in the run refreshed origin/<branch> to a
#          maintainer's steering commit, the lease silently PASSES and the
#          force-push discards a commit HEAD never incorporated — exactly how a
#          maintainer steering commit was destroyed on #1604. Two hardening
#          measures fix this:
#            a. incorporate_remote_head re-fetches the true remote head before
#               pushing and either rebases HEAD onto it (incorporating a
#               concurrent commit) or, when it cannot be incorporated cleanly,
#               STOPS and escalates. A commit dev-lead has no record of writing
#               is treated as steering: never discarded, and called out in the
#               run summary.
#            b. every force push adds --force-if-includes, so the force ABORTS
#               unless the commits being overwritten are reachable from a ref we
#               actually fetched (i.e. we truly incorporated them) — the lease
#               alone is not enough once a fetch has refreshed it.
#
#   #2313  "Is this commit dev-lead's?" was answered from the committer email.
#          Since ADR-0008 dev-lead commits as the owner's account, with the same
#          noreply address as the owner's own machine and every Claude Code
#          session on it, so every owner commit counted as dev-lead's and was
#          force-pushed over (combsmith/.github #1314, #1315). Ownership now comes
#          only from evidence dev-lead records itself: the SHAs this run pushed,
#          or a Dev-Lead-Stamp trailer bound to the commit's own tree and parents
#          (git-identity.sh). The committer identity is never consulted.
#
# Usage: push_no_clobber [git push args...]   e.g. push_no_clobber origin main

# _push_guard_summary MESSAGE — append a line to the GitHub run summary (if the
# workflow provides one) so a steering incorporation/escalation is auditable in
# the run's Summary tab, not just the raw log.
_push_guard_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  return 0
}

# dev_lead_stamp_of (the Dev-Lead-Stamp hash) lives with the code that stamps
# dev-lead's commits.
if ! declare -F dev_lead_stamp_of >/dev/null 2>&1; then
  # shellcheck source=scripts/lib/git-identity.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-identity.sh"
fi

# Newline-separated SHAs this run has published with push_no_clobber or
# push_with_merge_guard (#2313). A commit on the remote is dev-lead's own when its
# SHA is here, whatever its author or committer says. Accumulates across pushes
# in one run.
_PUSH_GUARD_PUSHED="${_PUSH_GUARD_PUSHED:-}"

# _push_guard_ownership_verdict <sha> <tree> <parents> <message> <pushed> — decide
# whether a commit is dev-lead's own from evidence dev-lead recorded itself
# (#2313). Echoes one token; returns 0 only for the two `own-*` tokens:
#   own-pushed   <sha> is one of the newline-separated SHAs in <pushed>.
#   own-stamped  <message> has a `Dev-Lead-Stamp:` line whose hash equals the
#                stamp of <tree> and the space-separated <parents>. An amended,
#                cherry-picked or rebased copy keeps the line but not the tree and
#                parents it was computed from, so the copy does not match.
#   foreign      anything else, including a commit whose author and committer
#                are exactly dev-lead's: the owner commits with the same identity.
# Pure apart from `git hash-object --stdin` (no repository, network or gh).
_push_guard_ownership_verdict() {
  local sha="${1:-}" tree="${2:-}" parent_list="${3:-}" message="${4:-}" pushed="${5:-}"
  if [ -n "$sha" ] && grep -qxF -- "$sha" <<<"$pushed"; then
    echo own-pushed; return 0
  fi
  if dev_lead_stamp_matches "$tree" "$parent_list" "$message"; then
    echo own-stamped; return 0
  fi
  echo foreign
  return 1
}

# _commit_is_dev_lead SHA — true only when dev-lead's own records say it wrote the
# commit: this run pushed it, or it carries a matching Dev-Lead-Stamp (#2313). The
# committer email is deliberately NOT a signal: since ADR-0008 the owner, every
# Claude Code session on the owner's machine and dev-lead all commit as
# <id>+don-petry@users.noreply.github.com. An unreadable commit is foreign.
_commit_is_dev_lead() {
  local sha="$1" full meta tree parents message
  full=$(git rev-parse --verify --quiet "${sha}^{commit}" 2>/dev/null) || return 1
  meta=$(git show -s --format='%T%x09%P' "$full" 2>/dev/null) || return 1
  tree="${meta%%$'\t'*}"
  parents="${meta#*$'\t'}"
  message=$(git show -s --format='%B' "$full" 2>/dev/null || true)
  _push_guard_ownership_verdict "$full" "$tree" "$parents" "$message" "$_PUSH_GUARD_PUSHED" >/dev/null
}

# _push_guard_publishing [remote] — echo the SHAs a push of HEAD is about to
# publish: the commits HEAD has beyond the remote head incorporate_remote_head
# verified, or, when no remote head was read (a new branch, a failed fetch),
# beyond every remote-tracking ref. Run it BEFORE the push: a successful push
# moves the remote-tracking ref to HEAD.
_push_guard_publishing() {
  if [ -n "$_PUSH_GUARD_REMOTE_SHA" ]; then
    git rev-list "${_PUSH_GUARD_REMOTE_SHA}..HEAD" 2>/dev/null || true
  else
    git rev-list HEAD --not --remotes="${1:-origin}" 2>/dev/null || true
  fi
}

# _push_guard_stamp_unpublished [remote] — stamp every commit the push is about
# to publish (dev_lead_stamp_unpublished), so a later run recognises the
# engine's own `git commit`s as dev-lead's, not just the harness's (#2313). Runs
# after incorporate_remote_head: a rebase changes parents, which would void a
# stamp made earlier. The old→new rows join _PUSH_GUARD_REWRITES, so the claim
# sweep re-points a "Fixed in <old>" reply at the commit that landed (#2032).
_push_guard_stamp_unpublished() {
  local remote="${1:-origin}" rows rc=0
  local -a exclude=(--remotes="$remote")
  [ -n "$_PUSH_GUARD_REMOTE_SHA" ] && exclude+=("$_PUSH_GUARD_REMOTE_SHA")
  rows=$(dev_lead_stamp_unpublished "${exclude[@]}") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "::warning::could not stamp the commits about to be pushed; a later run will treat them as foreign (rebase or stop, never discard) (#2313)" >&2
    return 0
  fi
  [ -z "$rows" ] && return 0
  rows="${rows%$'\n'}"
  if [ -n "$_PUSH_GUARD_REWRITES" ]; then
    _PUSH_GUARD_REWRITES+=$'\n'"${rows}"
  else
    _PUSH_GUARD_REWRITES="$rows"
  fi
  return 0
}

# _push_guard_record_pushed <shas> — add a successful push's SHAs to the ledger.
_push_guard_record_pushed() {
  local shas="${1:-}" sha
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    grep -qxF -- "$sha" <<<"$_PUSH_GUARD_PUSHED" && continue
    if [ -n "$_PUSH_GUARD_PUSHED" ]; then
      _PUSH_GUARD_PUSHED+=$'\n'"${sha}"
    else
      _PUSH_GUARD_PUSHED="$sha"
    fi
  done <<<"$shas"
  return 0
}

# _resolve_remote_branch [remote branch] — echo "<remote> <branch>" for the push
# target. Uses explicit args when given; otherwise derives them from the current
# branch's upstream (@{u}). Echoes nothing when neither is available.
_resolve_remote_branch() {
  if [ "$#" -ge 2 ] && [ -n "$1" ] && [ -n "$2" ]; then
    printf '%s %s\n' "$1" "$2"
    return 0
  fi
  local up
  up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  [ -z "$up" ] && return 1
  printf '%s %s\n' "${up%%/*}" "${up#*/}"
}

# incorporate_remote_head [remote branch] — fetch the true current remote head
# and ensure HEAD incorporates it before the caller pushes (#1607, AC #1/#2/#4).
#
# Returns:
#   0  safe to push — either HEAD already contains the remote head, or the only
#      commits the remote has that HEAD lacks are dev-lead's OWN by its records
#      (_commit_is_dev_lead: pushed by this run, or stamped) (a legitimate
#      self-rewrite the caller will publish with --force-with-lease), or foreign
#      (steering) commits were cleanly rebased in (HEAD now contains them).
#   2  STOP/escalate — the remote has a steering commit that could not be
#      incorporated cleanly (rebase conflict). The caller must NOT force over it.
#
# Side effects: may rebase the current branch onto the fetched remote head;
# flags steering incorporation/escalation to the run summary.
# Set by incorporate_remote_head so the eventual force-push can pin an EXPLICIT
# lease against the exact remote head we fetched and verified. An explicit lease
# is immune to the "a fetch refreshed the lease" defeat (#1604) AND to the
# reflog-timing false-positive that --force-if-includes hits when the verifying
# fetch is newer than the local rewrite. Empty when no fetch succeeded, in which
# case _pinned_force_push falls back to --force-with-lease --force-if-includes.
_PUSH_GUARD_REMOTE_SHA=""
_PUSH_GUARD_BRANCH=""
# Newline-separated `<old>\t<new>` rows: each dev-lead commit the steering rebase
# rewrote, and the commit that now carries the same change (#2032). The model's
# "Fixed in <sha>" replies cite the pre-rebase SHAs, which never reach the remote;
# the claim sweep (retract_unlanded_claims) re-points them through this map instead
# of retracting fixes that landed. Accumulates across pushes in one run.
_PUSH_GUARD_REWRITES="${_PUSH_GUARD_REWRITES:-}"

# _push_guard_commit_keys <range> — one `<sha>\t<key>` row per commit in <range>.
# The key hashes the author name, email and date and the full message: a rebase
# keeps all four, so the key identifies a commit across the rewrite even when the
# foreign commit shifted its diff context (which would change a patch-id).
_push_guard_commit_keys() {
  local sha key
  git rev-list "$1" 2>/dev/null | while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    key=$(git show -s --format='%an%x00%ae%x00%at%x00%B' "$sha" 2>/dev/null | git hash-object --stdin 2>/dev/null) || continue
    [ -n "$key" ] && printf '%s\t%s\n' "$sha" "$key"
  done
  return 0
}

# _push_guard_rewrite_map <old_keys> <new_keys> — pair `<sha>\t<key>` rows from
# before and after a rebase into `<old>\t<new>` rows. Only a key that occurs once
# on each side is paired; an ambiguous or dropped commit maps to nothing, so its
# claim fails closed (is retracted) rather than following a guess.
_push_guard_rewrite_map() {
  awk -F'\t' '
    NF < 2 { next }
    FNR == NR { oc[$2]++; o[$2] = $1; next }
    { nc[$2]++; n[$2] = $1 }
    END { for (k in o) if (oc[k] == 1 && nc[k] == 1 && o[k] != n[k]) print o[k] "\t" n[k] }
  ' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

incorporate_remote_head() {
  _PUSH_GUARD_REMOTE_SHA=""
  _PUSH_GUARD_BRANCH=""

  local rb remote branch
  rb=$(_resolve_remote_branch "$@") || return 0   # no upstream to reconcile against
  remote="${rb%% *}"; branch="${rb#* }"

  # Learn the true remote head. A failed fetch (offline/new branch) leaves the
  # --force-with-lease --force-if-includes fallback as the backstop.
  git fetch --quiet "$remote" "$branch" 2>/dev/null || return 0

  local remote_sha
  remote_sha=$(git rev-parse --verify --quiet "refs/remotes/${remote}/${branch}" 2>/dev/null \
    || git rev-parse --verify --quiet FETCH_HEAD 2>/dev/null || true)
  [ -z "$remote_sha" ] && return 0   # branch does not exist remotely yet
  _PUSH_GUARD_REMOTE_SHA="$remote_sha"
  _PUSH_GUARD_BRANCH="$branch"

  # Already incorporated (fast-forward or up to date) — nothing to reconcile.
  if git merge-base --is-ancestor "$remote_sha" HEAD 2>/dev/null; then
    return 0
  fi

  # The remote has commits HEAD does not contain. Classify them.
  local unincorporated foreign=""
  unincorporated=$(git rev-list --reverse "HEAD..${remote_sha}" 2>/dev/null || true)
  [ -z "$unincorporated" ] && return 0

  local sha
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    if ! _commit_is_dev_lead "$sha"; then
      foreign+="${sha}"$'\n'
    fi
  done <<< "$unincorporated"

  if [ -z "$foreign" ]; then
    # Every remote commit HEAD lacks is dev-lead's own by its records — a
    # legitimate history rewrite (e.g. amend/rebase of our prior push). The caller publishes it
    # with --force-with-lease --force-if-includes and logs the discarded SHAs.
    return 0
  fi

  # Foreign (steering) commits present. They must never be discarded; try to
  # incorporate them by rebasing HEAD onto the fetched remote head.
  local foreign_oneline
  foreign_oneline=$(while IFS= read -r sha; do
    [ -n "$sha" ] && git log -1 --format='%h %an: %s' "$sha" 2>/dev/null
  done <<< "$foreign")
  echo "::warning::steering detected on ${remote}/${branch} — commit(s) dev-lead has no record of writing are on the remote and HEAD did not incorporate them; rebasing onto them so they are never discarded (#1607):" >&2
  printf '%s\n' "$foreign_oneline" >&2

  # Record dev-lead's commits before the rebase so their rebased successors can
  # be paired with them afterwards (#2032).
  local pre_rebase_keys
  pre_rebase_keys=$(_push_guard_commit_keys "${remote_sha}..HEAD")

  if git rebase --quiet "$remote_sha" 2>/dev/null; then
    local rewrites
    rewrites=$(_push_guard_rewrite_map "$pre_rebase_keys" "$(_push_guard_commit_keys "${remote_sha}..HEAD")")
    if [ -n "$rewrites" ] && [ -n "$_PUSH_GUARD_REWRITES" ]; then
      _PUSH_GUARD_REWRITES+=$'\n'"${rewrites}"
    elif [ -n "$rewrites" ]; then
      _PUSH_GUARD_REWRITES="$rewrites"
    fi
    _push_guard_summary "### dev-lead: maintainer steering incorporated (#1607)"
    _push_guard_summary "A commit dev-lead has no record of writing was on \`${remote}/${branch}\` and has been rebased into this push rather than discarded:"
    _push_guard_summary ""
    _push_guard_summary '```'
    _push_guard_summary "${foreign_oneline}"
    _push_guard_summary '```'
    return 0
  fi

  # Could not incorporate cleanly — abort and escalate. Never force over it.
  git rebase --abort 2>/dev/null || true
  echo "::error::steering commit(s) on ${remote}/${branch} could not be rebased into dev-lead's changes cleanly. Refusing to force-push over unincorporated human work — stopping for human review (#1607)." >&2
  _push_guard_summary "### dev-lead: STOPPED — un-incorporable maintainer steering (#1607)"
  _push_guard_summary "A commit dev-lead has no record of writing is on \`${remote}/${branch}\` and conflicts with dev-lead's changes. dev-lead refused to force-push over it and stopped for human review:"
  _push_guard_summary ""
  _push_guard_summary '```'
  _push_guard_summary "${foreign_oneline}"
  _push_guard_summary '```'
  return 2
}

# _pinned_force_push [git push args...] — force-push with a lease that cannot be
# silently defeated (#1607). When incorporate_remote_head verified the remote
# head, pin an EXPLICIT lease against that exact SHA; otherwise fall back to
# --force-with-lease --force-if-includes. Either way the force ABORTS if the
# remote moved to a commit dev-lead did not incorporate.
_pinned_force_push() {
  if [ -n "$_PUSH_GUARD_REMOTE_SHA" ] && [ -n "$_PUSH_GUARD_BRANCH" ]; then
    git push --force-with-lease="${_PUSH_GUARD_BRANCH}:${_PUSH_GUARD_REMOTE_SHA}" "$@"
  else
    git push --force-with-lease --force-if-includes "$@"
  fi
}

push_no_clobber() {
  # #1607: reconcile with the true remote head first — incorporate a concurrent
  # steering commit, or stop/escalate if it cannot be incorporated cleanly.
  incorporate_remote_head "$@" || return $?

  _push_guard_stamp_unpublished "${1:-}"

  local errf publishing
  errf="$(mktemp)"
  publishing=$(_push_guard_publishing "${1:-}")

  if git push "$@" 2>"$errf"; then
    rm -f "$errf"
    _push_guard_record_pushed "$publishing"
    return 0
  fi

  local upstream
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)

  # Retry with --force-with-lease ONLY on a non-fast-forward rejection where our
  # branch has diverged from the upstream we last saw (rewritten history).
  # --force-with-lease leases against the remote-tracking ref; --force-if-includes
  # additionally ABORTS unless the overwritten commits are reachable from a ref
  # we fetched — so a fetch that refreshed the lease can no longer let us discard
  # an unincorporated commit (#1607).
  if grep -qiE 'non-fast-forward|\[rejected\]|fetch first' "$errf" \
     && [ -n "$upstream" ] \
     && ! git merge-base --is-ancestor "$upstream" HEAD 2>/dev/null; then
    local discarded
    discarded=$(git rev-list "HEAD..${upstream}" 2>/dev/null | tr '\n' ' ')
    echo "::notice::push rejected (non-fast-forward) and HEAD diverged from ${upstream} — history was rewritten (likely a self-rebase); retrying with a pinned lease (aborts unless the remote is still where dev-lead incorporated). Overwriting dev-lead's own commit(s): ${discarded:-<none>}" >&2
    if _pinned_force_push "$@" 2>>"$errf"; then
      rm -f "$errf"
      _push_guard_record_pushed "$publishing"
      return 0
    fi
    cat "$errf" >&2
    rm -f "$errf"
    echo "::error::pinned force-push refused: the remote branch advanced beyond the commit dev-lead incorporated. Refusing to discard an unseen commit." >&2
    return 1
  fi

  cat "$errf" >&2
  rm -f "$errf"
  echo "::error::git push failed — the remote head moved (a commit dev-lead never fetched) or access was denied; not overwriting." >&2
  return 1
}
