#!/usr/bin/env bash
# git_identity_guard.bash — keep the dev-lead unit suite off the invoking
# checkout's git identity (#2236).
#
# Several tests run dev-lead entry points from the checkout itself, and those
# reach setup_git_identity — directly, or inside a `git worktree add` worktree,
# whose `git config` writes land in the checkout's shared .git/config. Left
# alone, a local `bats tests/dev-lead/unit/` run rewrites the maintainer's
# user.name/user.email, and every later commit from that checkout carries it.
#
# The guard:
#   1. snapshots the checkout's `git config --local` user.name/user.email;
#   2. points GIT_CONFIG_GLOBAL at a suite-private file (which includes the
#      caller's real global config, so reads are unchanged);
#   3. prepends a `git` shim to PATH that sends any user.name/user.email write
#      aimed at the checkout (or one of its worktrees) to that private file
#      instead — commits made there still get an identity, the checkout does not;
#   4. on verify, fails when the snapshot no longer matches (restoring it first).
#
# Used by setup_suite.bash (whole-directory runs) and by test_git_identity.bats
# (so that file is safe even when bats is pointed at it from elsewhere).

# _gig_snapshot <repo> — "set:<value>" / "unset" per key, one per line.
_gig_snapshot() {
  local repo="$1" key value
  for key in user.name user.email; do
    if value="$("$GIT_IDENTITY_GUARD_REAL_GIT" -C "$repo" config --local --get "$key" 2>/dev/null)"; then
      printf '%s=set:%s\n' "$key" "$value"
    else
      printf '%s=unset\n' "$key"
    fi
  done
}

# git_identity_guard_install <owner> — no-op when already installed (the outer
# installer owns cleanup) or when the checkout is not a git repository.
git_identity_guard_install() {
  local owner="${1:-file}"
  [ -n "${GIT_IDENTITY_GUARD_DIR:-}" ] && [ -d "$GIT_IDENTITY_GUARD_DIR" ] && return 0

  local root real_git common dir include
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
  real_git="$(command -v git)" || return 0
  common="$("$real_git" -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  common="$(cd "$common" && pwd -P)" || return 0

  dir="$(mktemp -d "${TMPDIR:-/tmp}/git-identity-guard.XXXXXX")"
  mkdir -p "$dir/bin"
  export GIT_IDENTITY_GUARD_DIR="$dir"
  export GIT_IDENTITY_GUARD_OWNER="$owner"
  export GIT_IDENTITY_GUARD_ROOT="$root"
  export GIT_IDENTITY_GUARD_COMMON_DIR="$common"
  export GIT_IDENTITY_GUARD_REAL_GIT="$real_git"
  _gig_snapshot "$root" > "$dir/snapshot"

  # Suite-private global config that still honours the caller's own globals.
  : > "$dir/global.gitconfig"
  for include in "${GIT_CONFIG_GLOBAL:-}" "$HOME/.gitconfig" "${XDG_CONFIG_HOME:-$HOME/.config}/git/config"; do
    [ -n "$include" ] || continue
    [ -f "$include" ] || continue
    "$real_git" config --file "$dir/global.gitconfig" --add include.path "$include"
  done
  export GIT_CONFIG_GLOBAL="$dir/global.gitconfig"

  cat > "$dir/bin/git" <<SHIM
#!/usr/bin/env bash
# git shim installed by tests/dev-lead/unit/git_identity_guard.bash (#2236).
REAL_GIT='$real_git'
PROTECTED='$common'
REDIRECT='$dir/global.gitconfig'
SHIM
  cat >> "$dir/bin/git" <<'SHIM'
case " $* " in
  *user.name*|*user.email*) ;;
  *) exec "$REAL_GIT" "$@" ;;
esac

# Split global options from the subcommand; keep -C so the target repo resolves.
pre=() i=1
while [ "$i" -le "$#" ]; do
  a="${!i}"
  case "$a" in
    -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env)
      j=$((i + 1)); pre+=("$a" "${!j}"); i=$((i + 2)) ;;
    -*) pre+=("$a"); i=$((i + 1)) ;;
    *) break ;;
  esac
done
[ "${!i:-}" = "config" ] || exec "$REAL_GIT" "$@"
rest=("${@:$((i + 1))}")

# Only writes to the repository's own config are redirected: an explicit
# --global/--system/--file/--blob target, or any read, passes through untouched.
positional=() write=false
k=0
while [ "$k" -lt "${#rest[@]}" ]; do
  a="${rest[$k]}"
  case "$a" in
    --global|--system|--file|--file=*|-f|--blob|--blob=*) exec "$REAL_GIT" "$@" ;;
    --get|--get-all|--get-regexp|--get-urlmatch|-l|--list|--edit|-e|--get-color|--get-colorbool)
      exec "$REAL_GIT" "$@" ;;
    --unset|--unset-all|--add|--replace-all) write=true ;;
    --type|--default|--comment|--value) k=$((k + 1)) ;;
    -*) ;;
    *) positional+=("$a") ;;
  esac
  k=$((k + 1))
done
case "${positional[0]:-}" in
  set|unset) write=true ;;
  get|list|edit) exec "$REAL_GIT" "$@" ;;
esac
[ "${#positional[@]}" -ge 2 ] && write=true
$write || exec "$REAL_GIT" "$@"

common="$("$REAL_GIT" "${pre[@]}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || exec "$REAL_GIT" "$@"
common="$(cd "$common" 2>/dev/null && pwd -P)" || exec "$REAL_GIT" "$@"
[ "$common" = "$PROTECTED" ] || exec "$REAL_GIT" "$@"

# Aimed at the invoking checkout: write the same setting to the suite-private
# global config instead (drop --local/--worktree so --file is the only scope).
# The `git config set|unset` subcommand form must precede --file.
sub=() args=()
case "${positional[0]:-}" in set|unset) sub=("${positional[0]}") ;; esac
for a in "${rest[@]}"; do
  case "$a" in
    --local|--worktree) ;;
    *)
      # Drop the first occurrence of the subcommand word; it is re-added above.
      if [ "${#sub[@]}" -eq 1 ] && [ "$a" = "${sub[0]}" ] && [ -z "${sub_seen:-}" ]; then
        sub_seen=1
      else
        args+=("$a")
      fi ;;
  esac
done
exec "$REAL_GIT" config "${sub[@]}" --file "$REDIRECT" "${args[@]}"
SHIM
  chmod +x "$dir/bin/git"
  export PATH="$dir/bin:$PATH"
}

# git_identity_guard_verify <owner> — fail (after restoring the snapshot) when
# the checkout's user.name/user.email changed; the installing owner cleans up.
git_identity_guard_verify() {
  local owner="${1:-file}" dir="${GIT_IDENTITY_GUARD_DIR:-}" rc=0 line key value
  [ -n "$dir" ] && [ -f "$dir/snapshot" ] || return 0

  if ! diff -u "$dir/snapshot" <(_gig_snapshot "$GIT_IDENTITY_GUARD_ROOT") >&2; then
    echo "git-identity guard: the dev-lead unit suite changed ${GIT_IDENTITY_GUARD_ROOT}'s git identity (#2236); restoring it" >&2
    while IFS= read -r line; do
      key="${line%%=*}" value="${line#*=}"
      if [ "$value" = "unset" ]; then
        "$GIT_IDENTITY_GUARD_REAL_GIT" -C "$GIT_IDENTITY_GUARD_ROOT" config --local --unset-all "$key" 2>/dev/null || true
      else
        "$GIT_IDENTITY_GUARD_REAL_GIT" -C "$GIT_IDENTITY_GUARD_ROOT" config --local "$key" "${value#set:}"
      fi
    done < "$dir/snapshot"
    rc=1
  fi

  if [ "$owner" = "${GIT_IDENTITY_GUARD_OWNER:-}" ]; then
    rm -rf "$dir"
  fi
  return "$rc"
}
