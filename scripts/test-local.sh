#!/usr/bin/env bash
set -euo pipefail
# test-local.sh — run the bats suites on a developer machine with the toolchain
# CI has.
#
# CI runs on ubuntu-latest: GNU bash 5, coreutils, sed, grep, findutils, gawk,
# flock, and a python3 with jsonschema and PyYAML. macOS has bash 3.2 and the BSD
# tools instead, and a plain `bats` run there fails about 2,000 tests that pass
# in CI (measured on main, 2026-11-13). This script, on macOS:
#
#   1. puts the Homebrew GNU tools and bash 5 first on PATH, for this run only,
#      and fails naming the missing formula when one is not installed
#      (brew bundle --file=Brewfile installs them all);
#   2. resolves TMPDIR to its real path (/var is a symlink to /private/var, and
#      a test comparing $PWD with a path built from TMPDIR fails otherwise);
#   3. on any OS, builds a cached venv from the hash-pinned requirements/ci/
#      files when python3 cannot import jsonschema and yaml (the validator
#      suites need both), and puts it first on PATH.
#
# Then it runs bats. With no test paths it runs every suite: the top-level
# tests/*.bats, tests/dev-lead/unit and tests/dev-lead/integration, which is a
# superset of what lint.yml and test-dev-lead.yml run.
#
# Usage: scripts/test-local.sh [--jobs N] [bats options] [test paths...]
#   --jobs N   run N test files at a time (needs GNU parallel). Tests inside a
#              file still run one at a time. Default: 1.
#   Any other option is passed to bats, e.g. -f <regex>, --tap.
#
# This script itself has to start under macOS bash 3.2: no bash 4 syntax above
# the exec.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

jobs=1
bats_args=()
paths=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs|-j) jobs="${2:?--jobs needs a number}"; shift 2 ;;
    --jobs=*) jobs="${1#--jobs=}"; shift ;;
    -h|--help) sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -f|--filter|-F|--formatter|--filter-status|--filter-tags|-o|--output) bats_args+=("$1" "${2:?$1 needs a value}"); shift 2 ;;
    -*) bats_args+=("$1"); shift ;;
    *) paths+=("$1"); shift ;;
  esac
done
if [ "${#paths[@]}" -eq 0 ]; then
  paths=(tests tests/dev-lead/unit tests/dev-lead/integration)
fi

die() { echo "test-local: $*" >&2; exit 1; }

if [ "$(uname -s)" = Darwin ]; then
  if [ -n "${HOMEBREW_PREFIX:-}" ]; then
    brew_prefix="$HOMEBREW_PREFIX"
  elif command -v brew >/dev/null 2>&1; then
    brew_prefix="$(brew --prefix)"
  else
    die "Homebrew not found. Install it from https://brew.sh, then run: brew bundle --file=Brewfile"
  fi

  missing=""
  gnu_path=""
  for formula in coreutils gnu-sed grep findutils gawk; do
    dir="$brew_prefix/opt/$formula/libexec/gnubin"
    if [ -d "$dir" ]; then
      gnu_path="${gnu_path}${dir}:"
    else
      missing="$missing $formula"
    fi
  done
  bash5="$brew_prefix/bin/bash"
  if [ ! -x "$bash5" ] || ! "$bash5" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]'; then
    missing="$missing bash"
  fi
  [ -x "$brew_prefix/bin/bats" ] || missing="$missing bats-core"
  [ -x "$brew_prefix/bin/flock" ] || missing="$missing flock"
  if [ "$jobs" != 1 ] && [ ! -x "$brew_prefix/bin/parallel" ]; then
    missing="$missing parallel"
  fi
  if [ -n "$missing" ]; then
    die "missing Homebrew formulae:${missing}. Run: brew bundle --file=Brewfile"
  fi

  PATH="${gnu_path}${brew_prefix}/bin:$PATH"
  TMPDIR="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
  export PATH TMPDIR
fi

# Python deps for the validator suites. Use what is there when it already has
# them (CI installs them system-wide); otherwise build a venv once per
# requirements change, outside the checkout so every worktree shares it.
if ! python3 -c 'import jsonschema, yaml' >/dev/null 2>&1; then
  py=""
  for candidate in python3.12 python3.13 python3; do
    if command -v "$candidate" >/dev/null 2>&1 \
      && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
      py="$candidate"
      break
    fi
  done
  [ -n "$py" ] || die "no python3 >= 3.10 found for the validator suites. Run: brew bundle --file=Brewfile"

  reqs=(requirements/ci/jsonschema.txt requirements/ci/pyyaml.txt requirements/ci/yamllint.txt)
  venv="${COMBSMITH_TEST_VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/combsmith-github-private/test-venv}"
  stamp="$( { "$py" --version; cat "${reqs[@]}"; } | shasum -a 256 | cut -d' ' -f1)"
  if [ "$(cat "$venv/.stamp" 2>/dev/null || true)" != "$stamp" ]; then
    echo "test-local: building the python venv at $venv" >&2
    rm -rf "$venv"
    "$py" -m venv "$venv"
    "$venv/bin/python" -m pip install --quiet --require-hashes --only-binary ":all:" \
      -r requirements/ci/jsonschema.txt -r requirements/ci/pyyaml.txt -r requirements/ci/yamllint.txt \
      || die "pip install into $venv failed"
    printf '%s\n' "$stamp" > "$venv/.stamp"
  fi
  PATH="$venv/bin:$PATH"
  export PATH
fi

if [ "$jobs" != 1 ]; then
  bats_args+=(--jobs "$jobs" --no-parallelize-within-files)
fi

# Close stdin: a test that reads it would otherwise wait on the terminal forever.
exec bats ${bats_args[@]+"${bats_args[@]}"} "${paths[@]}" </dev/null
