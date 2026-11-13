#!/usr/bin/env bash
# toolchain_preflight.bash — on macOS, stop a bats run that would fail for want
# of the GNU toolchain, and say what to run instead.
#
# The scripts under test assume what ubuntu-latest has: bash 5, GNU sed, grep,
# date, gawk, flock, and a python3 with jsonschema and PyYAML. Under stock macOS
# tools a run fails about 2,000 tests with messages like `declare: -g: invalid
# option` and `sed: illegal option -- z`, which read as real failures. This
# check turns that into one line naming the missing tool and the fix:
# scripts/test-local.sh, which sets the toolchain up for the run.
#
# Only macOS is checked; CI and Linux machines are untouched. It runs inside
# bats, so it may be under bash 3.2 itself: no bash 4 syntax here.
# BATS_SKIP_TOOLCHAIN_PREFLIGHT=1 skips it, for a deliberate run of a suite
# that does not need the toolchain.
#
# Also resolves TMPDIR to its real path (/var is a symlink to /private/var), so
# a path built from TMPDIR matches $PWD after a cd into it.

toolchain_preflight() {
  [ "$(uname -s)" = Darwin ] || return 0
  [ "${BATS_SKIP_TOOLCHAIN_PREFLIGHT:-}" = 1 ] && return 0

  local problems=""
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || problems="${problems}
  - bash ${BASH_VERSION} runs bats; the scripts need bash 4 or later"
  sed --version 2>/dev/null | grep -q GNU || problems="${problems}
  - sed is BSD sed; the tests need GNU sed (sed -i, sed -z)"
  # Not `grep --version`: BSD grep calls itself "GNU compatible" there.
  echo x | grep -qP 'x' 2>/dev/null || problems="${problems}
  - grep is BSD grep; the scripts need GNU grep (grep -P)"
  date -d @0 >/dev/null 2>&1 || problems="${problems}
  - date is BSD date; the scripts need GNU date (date -d)"
  awk --version 2>/dev/null | grep -q GNU || problems="${problems}
  - awk is BSD awk; the scripts need gawk"
  command -v flock >/dev/null 2>&1 || problems="${problems}
  - flock is not installed"
  python3 -c 'import jsonschema, yaml' >/dev/null 2>&1 || problems="${problems}
  - python3 cannot import jsonschema and yaml (the validator suites need them)"

  if [ -n "$problems" ]; then
    printf 'toolchain preflight: this run would fail for reasons that are not bugs:%s\n' "$problems" >&2
    printf 'Run the suites with scripts/test-local.sh instead (first time: brew bundle --file=Brewfile).\n' >&2
    printf 'Set BATS_SKIP_TOOLCHAIN_PREFLIGHT=1 to run anyway.\n' >&2
    return 1
  fi

  TMPDIR="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
  export TMPDIR
}
