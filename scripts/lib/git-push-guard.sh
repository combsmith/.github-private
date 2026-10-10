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
#               STOPS and escalates. A commit authored by anyone other than
#               dev-lead's own identity is treated as steering: never discarded,
#               and called out in the run summary.
#            b. every force push adds --force-if-includes, so the force ABORTS
#               unless the commits being overwritten are reachable from a ref we
#               actually fetched (i.e. we truly incorporated them) — the lease
#               alone is not enough once a fetch has refreshed it.
#
# Usage: push_no_clobber [git push args...]   e.g. push_no_clobber origin main

# _push_guard_summary MESSAGE — append a line to the GitHub run summary (if the
# workflow provides one) so a steering incorporation/escalation is auditable in
# the run's Summary tab, not just the raw log.
_push_guard_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  return 0
}

# _commit_is_dev_lead SHA — true when the commit was authored by dev-lead's own
# identity. dev-lead commits with the bot's noreply email — exactly
# <login>@users.noreply.github.com or <id>+<login>@users.noreply.github.com
# (see setup_git_identity in git-identity.sh) — so match ONLY those two forms.
# A bare "*<login>@…" suffix match would also accept a spoofed local-part such as
# attacker-<login>@users.noreply.github.com and misclassify a foreign commit as
# dev-lead-owned; anchoring the local part to the exact login (optionally an
# all-digit user-id prefix) closes that. Anything else — a human maintainer's
# real email, another bot — is foreign (steering) and must never be silently
# discarded. The email is the reliable signal: a human owner may share the
# `don-petry` *name* but not the bot noreply address.
_commit_is_dev_lead() {
  local sha="$1"
  local bot="${BOT_USER:-donpetry-bot}"
  local email
  email=$(git log -1 --format='%ce' "$sha" 2>/dev/null || true)
  # Quoted "${bot}" is a literal in the regex; the id-prefix and domain are
  # anchored so the login must be the WHOLE local part (or follow "<digits>+").
  if [[ "$email" == "${bot}@users.noreply.github.com" ]] \
     || [[ "$email" =~ ^[0-9]+\+"${bot}"@users\.noreply\.github\.com$ ]]; then
    return 0
  fi
  return 1
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
#      commits the remote has that HEAD lacks are dev-lead's OWN (a legitimate
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
    # Every remote commit HEAD lacks is dev-lead's own — a legitimate history
    # rewrite (e.g. amend/rebase of our prior push). The caller publishes it
    # with --force-with-lease --force-if-includes and logs the discarded SHAs.
    return 0
  fi

  # Foreign (steering) commits present. They must never be discarded; try to
  # incorporate them by rebasing HEAD onto the fetched remote head.
  local foreign_oneline
  foreign_oneline=$(while IFS= read -r sha; do
    [ -n "$sha" ] && git log -1 --format='%h %an: %s' "$sha" 2>/dev/null
  done <<< "$foreign")
  echo "::warning::steering detected on ${remote}/${branch} — commit(s) by a non-dev-lead identity present on the remote that HEAD did not incorporate; rebasing onto them so they are never discarded (#1607):" >&2
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
    _push_guard_summary "A commit by a non-dev-lead identity was on \`${remote}/${branch}\` and has been rebased into this push rather than discarded:"
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
  _push_guard_summary "A commit by a non-dev-lead identity is on \`${remote}/${branch}\` and conflicts with dev-lead's changes. dev-lead refused to force-push over it and stopped for human review:"
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

  local errf
  errf="$(mktemp)"

  if git push "$@" 2>"$errf"; then
    rm -f "$errf"
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
