#!/usr/bin/env bats
# Unit tests for the persona authorization-preflight decision layer
# (scripts/lib/persona-authz-preflight.sh, issue #1776).
#
# #1776 (split from #1734 AC #5): a persona's declared posting credential can
# AUTHENTICATE correctly yet lack authorization to WRITE — the exact break that
# destroyed an advisory (403 on #1723) and silently dropped a pr-review approval
# on PR #1788. Every existing check verifies authentication and naming; nothing
# verified authorization. This library is the pure DECISION layer for a
# non-destructive capability probe: given the already-gathered facts of a
# `GET /repos/{owner}/{repo}` `.permissions` read, decide one of three outcomes —
#   definite-negative (readable surface, no write bit) -> FAIL loudly
#   indeterminate      (unreadable surface / absent perms) -> WARN and proceed
#   positive           (a write bit is set)              -> proceed silently
# It NEVER touches the network or writes content — the gh probe and the
# ::error::/::warning:: side-effects are the wrapper's job
# (scripts/persona-authz-preflight.sh). AC #4's fail-OPEN-on-indeterminate rule
# is the delicate one: a 5xx, a rate limit, or an unreadable surface must NOT be
# reported as "cannot write" and must not gate a legitimate advisory.
#
# Run with: bats tests/test_persona_authz_preflight.sh

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/persona-authz-preflight.sh"
}

# ---------------------------------------------------------------------------
# authz_write_capability — map the .permissions booleans to a capability signal
# ---------------------------------------------------------------------------

@test "write capability is 'yes' when push is true" {
  run authz_write_capability false false true
  [ "$status" -eq 0 ]
  [ "$output" = "yes" ]
}

@test "write capability is 'yes' when maintain is true (push false)" {
  run authz_write_capability false true false
  [ "$output" = "yes" ]
}

@test "write capability is 'yes' when admin is true" {
  run authz_write_capability true false false
  [ "$output" = "yes" ]
}

@test "write capability is 'yes' when triage is true (triage grants comment access)" {
  run authz_write_capability false false false true
  [ "$output" = "yes" ]
}

@test "write capability is 'no' when the surface is present but every write bit is false" {
  run authz_write_capability false false false false
  [ "$output" = "no" ]
}

@test "write capability is 'unknown' when the permissions object was absent (all empty)" {
  run authz_write_capability "" "" ""
  [ "$output" = "unknown" ]
}

@test "a single present-but-false bit still classifies as 'no' (read-only collaborator)" {
  # pull:true only would arrive here as admin/maintain/push all 'false'
  run authz_write_capability false false false
  [ "$output" = "no" ]
}

# ---------------------------------------------------------------------------
# authz_preflight_decision — the three-state classifier (AC #1, #4)
# ---------------------------------------------------------------------------

@test "positive: probe readable AND can write -> AUTHORIZED" {
  run authz_preflight_decision yes yes
  [ "$output" = "AUTHORIZED" ]
}

@test "definite-negative: probe readable AND cannot write -> UNAUTHORIZED" {
  run authz_preflight_decision yes no
  [ "$output" = "UNAUTHORIZED" ]
}

@test "indeterminate: probe NOT readable (5xx/rate-limit/401) -> INDETERMINATE even if capability is 'no'" {
  # A read failure must never be read as a definite negative — AC #4.
  run authz_preflight_decision no no
  [ "$output" = "INDETERMINATE" ]
}

@test "indeterminate: probe readable but permissions object absent (capability unknown) -> INDETERMINATE" {
  run authz_preflight_decision yes unknown
  [ "$output" = "INDETERMINATE" ]
}

@test "indeterminate: an empty/garbage probe status is never a definite negative" {
  run authz_preflight_decision "" no
  [ "$output" = "INDETERMINATE" ]
}

# ---------------------------------------------------------------------------
# authz_preflight_should_fail — only a definite negative gates (AC #4)
# ---------------------------------------------------------------------------

@test "should_fail is true ONLY for UNAUTHORIZED" {
  run authz_preflight_should_fail UNAUTHORIZED
  [ "$status" -eq 0 ]
}

@test "should_fail is false for AUTHORIZED" {
  run authz_preflight_should_fail AUTHORIZED
  [ "$status" -eq 1 ]
}

@test "should_fail is false for INDETERMINATE (fail open)" {
  run authz_preflight_should_fail INDETERMINATE
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# authz_preflight_diagnostic — the loud message names account/secret/capability
# ---------------------------------------------------------------------------

@test "UNAUTHORIZED diagnostic names the account, the credential secret, and the missing capability" {
  run authz_preflight_diagnostic UNAUTHORIZED don-petry GH_PAT_DON_PETRY petry-projects/.github-private
  [ "$status" -eq 0 ]
  [[ "$output" == *"don-petry"* ]]
  [[ "$output" == *"GH_PAT_DON_PETRY"* ]]
  [[ "$output" == *"petry-projects/.github-private"* ]]
  # names the missing capability, not a bare "permission denied"
  [[ "$output" == *"write"* ]]
  # distinguishes authorization from a missing secret (the #1734 diagnosis gap)
  [[ "$output" == *"authenticated"* ]]
}

@test "UNAUTHORIZED diagnostic does not masquerade as a missing/invalid secret" {
  run authz_preflight_diagnostic UNAUTHORIZED don-petry GH_PAT_DON_PETRY petry-projects/.github-private
  [[ "$output" != *"missing or invalid secret"* ]]
}

@test "INDETERMINATE diagnostic says it is proceeding (fail open), not blocking" {
  run authz_preflight_diagnostic INDETERMINATE don-petry GH_PAT_DON_PETRY petry-projects/.github-private
  [[ "$output" == *"proceed"* ]]
  # an indeterminate result must never claim the credential cannot write
  [[ "$output" != *"cannot write"* ]]
}

@test "AUTHORIZED diagnostic names the account and confirms write" {
  run authz_preflight_diagnostic AUTHORIZED don-petry GH_PAT_DON_PETRY petry-projects/.github-private
  [[ "$output" == *"don-petry"* ]]
  [[ "$output" == *"write"* ]]
}

# ---------------------------------------------------------------------------
# Wrapper integration (scripts/persona-authz-preflight.sh) with a stubbed `gh`
# — proves the network layer maps probe outcomes to the right exit code end to
# end. A stub `gh` on PATH lets these run offline and deterministically.
# ---------------------------------------------------------------------------

WRAPPER() {
  # Run the real wrapper with a fake `gh` shadowing the real one on PATH. All
  # inputs are passed via the environment the test exports before calling.
  PATH="$STUB_BIN:$PATH" \
    bash "$(dirname "$BATS_TEST_FILENAME")/../scripts/persona-authz-preflight.sh"
}

_stub_gh() {
  # $1 = exit code the stub returns; remaining args echoed as stdout (the JSON).
  local rc="$1"; shift
  cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
printf '%s' '$*'
exit $rc
EOF
  chmod +x "$STUB_BIN/gh"
}

wrapper_setup() {
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  export SOURCE_REPO="owner/repo"
  export POSTING_ACCOUNT="don-petry"
  export POSTING_CREDENTIAL="GH_PAT_DON_PETRY"
}

@test "wrapper skips cleanly when no PAT is present (missing-secret path, not this preflight)" {
  wrapper_setup
  _stub_gh 0 '{}'   # should not even be consulted
  export GH_TOKEN=""
  run WRAPPER
  [ "$status" -eq 0 ]
  [[ "$output" == *"deferring to the existing missing-secret handling"* ]]
}

@test "wrapper PROCEEDS silently when the surface says push=true (positive)" {
  wrapper_setup
  _stub_gh 0 '{"permissions":{"admin":false,"maintain":false,"push":true}}'
  export GH_TOKEN="tok"
  run WRAPPER
  [ "$status" -eq 0 ]
  [[ "$output" == *"can write"* ]]
}

@test "wrapper FAILS CLOSED on a definite negative (permissions present, no write bit)" {
  wrapper_setup
  _stub_gh 0 '{"permissions":{"admin":false,"maintain":false,"push":false,"pull":true}}'
  export GH_TOKEN="tok"
  export SOURCE_REPO="petry-projects/.github-private"
  run WRAPPER
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"don-petry"* ]]
  [[ "$output" == *"GH_PAT_DON_PETRY"* ]]
  [[ "$output" == *"petry-projects/.github-private"* ]]
}

@test "wrapper FAILS OPEN (warn + proceed) when the repo read errors (5xx/rate-limit)" {
  wrapper_setup
  _stub_gh 1 'HTTP 503: server error'
  export GH_TOKEN="tok"
  run WRAPPER
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" != *"::error::"* ]]
}

@test "wrapper FAILS OPEN when the permissions object is absent (indeterminate, not a negative)" {
  wrapper_setup
  _stub_gh 0 '{"name":"repo","private":true}'
  export GH_TOKEN="tok"
  run WRAPPER
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" != *"::error::"* ]]
}
