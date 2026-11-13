# Brewfile — the GNU toolchain the scripts and bats suites assume, for macOS.
#
# CI runs on ubuntu-latest. macOS ships bash 3.2 and BSD sed, grep, date, find
# and awk, under which about a third of the bats tests fail for reasons that are
# not bugs. Install these once, then run the suites through scripts/test-local.sh,
# which puts them first on PATH for that run only:
#
#   brew bundle --file=Brewfile
#   scripts/test-local.sh

brew "bash"       # bash 5: declare -g/-A, mapfile, ${var^^}
brew "bats-core"
brew "coreutils"  # GNU date -d, base64 -w, stat -c, mktemp, timeout
brew "gnu-sed"    # sed -i without a suffix, sed -z
brew "grep"       # grep -P
brew "findutils"  # GNU find and xargs
brew "gawk"       # multi-line -v values; BSD awk fails with "newline in string"
brew "flock"      # scripts/lib/miss-harvest.sh, scripts/lib/token-metrics.sh
brew "parallel"   # only for scripts/test-local.sh --jobs
brew "jq"
brew "yq"         # mikefarah yq v4, the one ubuntu-latest ships
brew "python@3.12"
