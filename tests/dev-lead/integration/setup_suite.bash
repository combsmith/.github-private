#!/usr/bin/env bash
# Suite-level hooks for a bats run that starts in tests/dev-lead/integration:
# the same ones as the unit directory (see tests/setup_suite.bash).

# shellcheck source=tests/dev-lead/unit/setup_suite.bash
source "$(dirname "${BASH_SOURCE[0]}")/../unit/setup_suite.bash"
