#!/usr/bin/env bash
# Suite-level hooks for a bats run that starts in tests/: one file, a list of
# files, or `bats --recursive tests`.
#
# bats loads ONE setup_suite.bash per run — the one beside the first path it is
# given that has one — and never looks in subdirectories. Without this file a
# run that started here got the dev-lead unit hooks only when a later path
# happened to be in that directory, and none otherwise. Every directory that
# holds .bats files loads the same hooks: the token-ledger isolation (#2304) and
# the git-identity guard (#2236).

# shellcheck source=tests/dev-lead/unit/setup_suite.bash
source "$(dirname "${BASH_SOURCE[0]}")/dev-lead/unit/setup_suite.bash"
