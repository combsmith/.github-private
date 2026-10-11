#!/usr/bin/env bash
# Suite-level hooks for tests/dev-lead/unit (bats runs these once per run).
#
# Guards the invoking checkout's git identity for the whole suite (#2236): no
# test may leave `git config --local user.name`/`user.email` changed. See
# git_identity_guard.bash.

# shellcheck source=tests/dev-lead/unit/git_identity_guard.bash
source "$(dirname "${BASH_SOURCE[0]}")/git_identity_guard.bash"

setup_suite() {
  git_identity_guard_install suite
}

teardown_suite() {
  git_identity_guard_verify suite
}
