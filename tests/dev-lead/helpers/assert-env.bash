# Bats helper: assert GITHUB_ENV contents

assert_env_contains() {
  local key="$1" expected="$2"
  local actual
  actual=$(grep "^${key}=" "${GITHUB_ENV:-/dev/null}" | cut -d= -f2-)
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected GITHUB_ENV[$key]='$expected', got '$actual'"
    return 1
  fi
}

assert_env_set() {
  local key="$1"
  if ! grep -q "^${key}=" "${GITHUB_ENV:-/dev/null}"; then
    echo "Expected GITHUB_ENV[$key] to be set, but it was not"
    return 1
  fi
}
