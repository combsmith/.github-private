#!/usr/bin/env bats
# Unit tests for scripts/lib/git-identity.sh — setup_git_identity (#2236).
#
# Every test runs setup_git_identity inside a throwaway repository, except the
# last, which runs it from the invoking checkout on purpose and asserts the
# checkout's identity survives (the suite guard in git_identity_guard.bash).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
GIT_IDENTITY_LIB="$SCRIPT_DIR/scripts/lib/git-identity.sh"

load git_identity_guard

setup_file() {
  # Self-sufficient when this file runs outside the unit directory's suite
  # (e.g. listed with files from other directories): install the guard here.
  git_identity_guard_install file
}

teardown_file() {
  git_identity_guard_verify file
}

setup() {
  STUB_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN_DIR"
  export PATH="$STUB_BIN_DIR:$PATH"
  unset BOT_USER

  TMP_REPO="$BATS_TEST_TMPDIR/repo"
  git init -q "$TMP_REPO"
  cd "$TMP_REPO"
}

# _stub_gh_id <output> — gh prints <output> for every call (the `.id` lookup).
_stub_gh_id() {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$1" > "$STUB_BIN_DIR/gh"
  chmod +x "$STUB_BIN_DIR/gh"
}

_run_identity() {
  # shellcheck source=/dev/null
  source "$GIT_IDENTITY_LIB"
  setup_git_identity
}

@test "git-identity: BOT_USER=don-petry with a numeric id → <id>+don-petry noreply (production unchanged)" {
  _stub_gh_id "36422719"
  export BOT_USER="don-petry"
  _run_identity
  [ "$(git config --local user.name)" = "don-petry" ]
  [ "$(git config --local user.email)" = "36422719+don-petry@users.noreply.github.com" ]
}

@test "git-identity: BOT_USER unset → never configures donpetry-bot" {
  _stub_gh_id "36422719"
  _run_identity
  [ "$(git config --local user.name)" != "donpetry-bot" ]
  [[ "$(git config --local user.email)" != *donpetry-bot* ]]
  [ "$(git config --local user.name)" = "don-petry" ]
}

@test "git-identity: stubbed '{}' id never reaches user.email → id-less noreply form" {
  _stub_gh_id "{}"
  export BOT_USER="don-petry"
  _run_identity
  [ "$(git config --local user.email)" = "don-petry@users.noreply.github.com" ]
}

@test "git-identity: error body from gh never reaches user.email" {
  _stub_gh_id '{"message":"Not Found","status":"404"}'
  export BOT_USER="don-petry"
  _run_identity
  [ "$(git config --local user.email)" = "don-petry@users.noreply.github.com" ]
}

@test "git-identity: partly numeric id (e.g. '12ab') is rejected" {
  _stub_gh_id "12ab"
  export BOT_USER="don-petry"
  _run_identity
  [ "$(git config --local user.email)" = "don-petry@users.noreply.github.com" ]
}

@test "git-identity: gh failure (empty id) → id-less noreply form" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_BIN_DIR/gh"
  chmod +x "$STUB_BIN_DIR/gh"
  export BOT_USER="don-petry"
  _run_identity
  [ "$(git config --local user.email)" = "don-petry@users.noreply.github.com" ]
}

@test "git-identity: run from the invoking checkout leaves its user.name/user.email unchanged" {
  local before_name before_email
  before_name="$(git -C "$SCRIPT_DIR" config --local --get user.name || true)"
  before_email="$(git -C "$SCRIPT_DIR" config --local --get user.email || true)"

  _stub_gh_id "{}"
  export BOT_USER="donpetry-bot"
  cd "$SCRIPT_DIR"
  _run_identity

  [ "$(git -C "$SCRIPT_DIR" config --local --get user.name || true)" = "$before_name" ]
  [ "$(git -C "$SCRIPT_DIR" config --local --get user.email || true)" = "$before_email" ]
}
