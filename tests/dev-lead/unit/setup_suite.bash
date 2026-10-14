#!/usr/bin/env bash
# Suite-level hooks for tests/dev-lead/unit (bats runs these once per run).
#
# Guards the invoking checkout's git identity for the whole suite (#2236): no
# test may leave `git config --local user.name`/`user.email` changed. See
# git_identity_guard.bash.

# shellcheck source=tests/dev-lead/unit/git_identity_guard.bash
source "$(dirname "${BASH_SOURCE[0]}")/git_identity_guard.bash"

setup_suite() {
  # No test writes to a token ledger it did not create (#2304): a suite started
  # with TOKEN_LOG_FILE exported (the dev-lead job does that) appended its
  # fixture records to the run's real ledger. bats starts every test file from
  # this shell, so the unset reaches them all; a test that needs a ledger sets
  # its own. tests/setup_suite.bash and the integration one load this file.
  unset TOKEN_LOG_FILE GEMINI_LEDGER_FILE _ENGINE_USAGE_OUT
  git_identity_guard_install suite
}

teardown_suite() {
  git_identity_guard_verify suite
}
