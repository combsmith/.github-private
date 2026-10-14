#!/usr/bin/env bats
# Unit tests for the persona runtime core (scripts/lib/persona-runner.sh).
# Standard: petry-projects/.github standards/persona-standards.md §4.1.
#
# The runner is a SEPARATE trust boundary from the router: a repository_dispatch
# can be sent by anything with a token, so payload re-validation and the
# write-side recursion marker get the most coverage here.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/persona-runner.sh"

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
  ROOT="$(mktemp -d "$BATS_TEST_TMPDIR/root.XXXXXX")"
}

# --- the recursion marker (shared with the router) -------------------------

@test "pr_agent_marker matches the router's marker prefix exactly" {
  run pr_agent_marker qa-lead
  [ "$output" = "<!-- persona:qa-lead -->" ]
}

@test "pr_comment_has_marker accepts a body whose first line is the marker" {
  run pr_comment_has_marker qa-lead "$(printf '<!-- persona:qa-lead -->\n## advisory\nbody')"
  [ "$status" -eq 0 ]
}

@test "pr_comment_has_marker accepts a body with CRLF line endings" {
  run pr_comment_has_marker qa-lead "$(printf '<!-- persona:qa-lead -->\r\n## advisory\r\nbody')"
  [ "$status" -eq 0 ]
}

@test "pr_comment_has_marker rejects a body missing the marker" {
  run pr_comment_has_marker qa-lead "$(printf '## advisory\nno marker')"
  [ "$status" -ne 0 ]
}

@test "pr_comment_has_marker rejects the marker on a later line (must be first)" {
  run pr_comment_has_marker qa-lead "$(printf 'preamble\n<!-- persona:qa-lead -->')"
  [ "$status" -ne 0 ]
}

@test "pr_comment_has_marker rejects the wrong persona's marker" {
  run pr_comment_has_marker qa-lead "$(printf '<!-- persona:dev-lead -->\nbody')"
  [ "$status" -ne 0 ]
}

# --- payload re-validation (this runner is its own trust boundary) ---------

@test "pr_valid_persona_id accepts a kebab-case slug" {
  run pr_valid_persona_id qa-lead
  [ "$status" -eq 0 ]
}

@test "pr_valid_persona_id accepts a single-token slug" {
  run pr_valid_persona_id murat
  [ "$status" -eq 0 ]
}

@test "pr_valid_persona_id rejects an empty id" {
  run pr_valid_persona_id ""
  [ "$status" -ne 0 ]
}

@test "pr_valid_persona_id rejects a path-traversal id" {
  run pr_valid_persona_id "../../etc/passwd"
  [ "$status" -ne 0 ]
}

@test "pr_valid_persona_id rejects uppercase, spaces, and slashes" {
  run pr_valid_persona_id "QA Lead"
  [ "$status" -ne 0 ]
  run pr_valid_persona_id "qa/lead"
  [ "$status" -ne 0 ]
}

@test "pr_valid_persona_id rejects leading, trailing, and doubled hyphens" {
  run pr_valid_persona_id "-qa"
  [ "$status" -ne 0 ]
  run pr_valid_persona_id "qa-"
  [ "$status" -ne 0 ]
  run pr_valid_persona_id "qa--lead"
  [ "$status" -ne 0 ]
}

# --- advisory prompt resolution (convention-driven) ------------------------

@test "pr_advisory_prompt_path follows the prompts/<id>/advisory.md convention" {
  run pr_advisory_prompt_path qa-lead
  [ "$output" = "prompts/qa-lead/advisory.md" ]
}

@test "pr_require_advisory returns the path when the prompt exists" {
  mkdir -p "$ROOT/prompts/qa-lead"
  echo "prompt" > "$ROOT/prompts/qa-lead/advisory.md"
  run pr_require_advisory qa-lead "$ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "prompts/qa-lead/advisory.md" ]
}

@test "pr_require_advisory fails (rc 3) with a diagnostic when the prompt is absent" {
  # A persona can declare an address before its runtime exists; the runner must
  # say so, not crash or invoke an empty prompt.
  run pr_require_advisory scrum-master "$ROOT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no runtime wired yet"* ]]
}

@test "pr_require_advisory fails (rc 2) on a malformed id BEFORE touching the fs" {
  # Guards the path interpolation: a bad id must never reach the filesystem read.
  run pr_require_advisory "../../etc" "$ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"malformed persona id"* ]]
}

# --- marker enforced MECHANICALLY, not just prompt-requested ----------------
# The agent prints between sentinels and cannot post (no write token). The
# workflow extracts, guarantees the marker, and posts. These pin that path.

@test "pr_comment_has_marker accepts a CRLF body (GitHub uses \\r\\n)" {
  run pr_comment_has_marker qa-lead "$(printf '<!-- persona:qa-lead -->\r\n## advisory\r\nbody')"
  [ "$status" -eq 0 ]
}

@test "pr_extract_advisory pulls only the text between the sentinels" {
  raw="$(printf 'chatter before\n===PERSONA-ADVISORY-BEGIN===\n<!-- persona:qa-lead -->\nrisk: low\n===PERSONA-ADVISORY-END===\ntrailing noise')"
  run pr_extract_advisory "$raw"
  [ "${lines[0]}" = "<!-- persona:qa-lead -->" ]
  [ "${lines[1]}" = "risk: low" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "pr_extract_advisory yields nothing when the sentinels are absent" {
  run pr_extract_advisory "the agent rambled but emitted no sentinels"
  [ -z "$output" ]
}

@test "pr_ensure_marker leaves an already-marked body unchanged" {
  body="$(printf '<!-- persona:qa-lead -->\n## advisory')"
  run pr_ensure_marker qa-lead "$body"
  [ "$output" = "$body" ]
}

@test "pr_ensure_marker PREPENDS the marker when the agent forgot it" {
  run pr_ensure_marker qa-lead "$(printf '## advisory\nno marker here')"
  [ "${lines[0]}" = "<!-- persona:qa-lead -->" ]
  [ "${lines[1]}" = "## advisory" ]
}

@test "pr_ensure_marker output always satisfies pr_comment_has_marker" {
  # The invariant the workflow relies on: whatever the agent produced, the posted
  # body starts with the marker.
  ensured="$(pr_ensure_marker qa-lead 'agent forgot the marker entirely')"
  run pr_comment_has_marker qa-lead "$ensured"
  [ "$status" -eq 0 ]
}

# --- post-failure preservation (#1775) --------------------------------------
# A failed post must not take the advisory with it: preserve the redacted,
# marker-complete body as an artifact-bound file AND a truncated summary mirror,
# name the auth-vs-authz cause, and still fail. All offline, no network.

@test "pr_artifact_name slugs owner/repo deterministically" {
  run pr_artifact_name qa-lead petry-projects/.github-private 1723
  [ "$output" = "persona-advisory-qa-lead-petry-projects-.github-private-1723" ]
}

@test "pr_artifact_name strips characters an artifact name cannot carry" {
  # A hostile/odd source_repo must not smuggle a slash or space into the name.
  run pr_artifact_name dev-lead "a b/c:d" 9
  [ "$output" = "persona-advisory-dev-lead-a-b-c-d-9" ]
}

@test "pr_summary_mirror passes a short body through untruncated with no notice" {
  body="$(printf '<!-- persona:qa-lead -->\nrisk: low\ntwo short lines')"
  run pr_summary_mirror "$body" persona-advisory-qa-lead-repo-1
  [ "$output" = "$body" ]
  [[ "$output" != *"Truncated"* ]]
}

@test "pr_summary_mirror truncates an oversized body and names the artifact" {
  # 10 KB of body against the default 8 KB budget must truncate and point at the
  # artifact that holds the untruncated copy.
  big="$(head -c 10240 /dev/zero | tr '\0' 'x')"
  run pr_summary_mirror "$big" persona-advisory-qa-lead-repo-1
  [ "$status" -eq 0 ]
  [[ "$output" == *'Truncated at 8 KB'* ]]
  [[ "$output" == *'persona-advisory-qa-lead-repo-1'* ]]
  # The mirrored copy is smaller than the original (budget + a short notice).
  [ "${#output}" -lt 10240 ]
}

@test "pr_post_failure_message distinguishes authentication (401)" {
  run pr_post_failure_message "gh: Bad credentials (HTTP 401)" don-petry GH_PAT_DON_PETRY
  [[ "$output" == *"401"* ]]
  [[ "$output" == *"authentication"* ]]
  [[ "$output" == *"don-petry"* ]]
  [[ "$output" == *"GH_PAT_DON_PETRY"* ]]
}

@test "pr_post_failure_message distinguishes authorization (403)" {
  # A 403 with a valid token is NOT a missing secret — the message must say so.
  run pr_post_failure_message "gh: Resource not accessible (HTTP 403)" don-petry GH_PAT_DON_PETRY
  [[ "$output" == *"403"* ]]
  [[ "$output" == *"authorization"* ]]
  [[ "$output" == *"valid"* ]]                    # says the token IS valid...
  [[ "$output" == *"not a missing secret"* ]]     # ...so it is not a missing-secret case
  [[ "$output" == *"don-petry"* ]]
  [[ "$output" == *"GH_PAT_DON_PETRY"* ]]
}

@test "pr_post_failure_message stays diagnostic when no HTTP status is present" {
  run pr_post_failure_message "some non-HTTP failure" don-petry GH_PAT_DON_PETRY
  [ "$status" -eq 0 ]
  [[ "$output" == *"don-petry"* ]]
  [[ "$output" == *"GH_PAT_DON_PETRY"* ]]
}

@test "pr_post_advisory_or_preserve: a failing post preserves the body and exits non-zero" {
  # Stub gh to fail with a 403 like the #1734 loss.
  stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh: Resource not accessible by integration (HTTP 403)" >&2
exit 1
STUB
  chmod +x "$stub/gh"
  PATH="$stub:$PATH"

  body_file="$BATS_TEST_TMPDIR/body.md"
  summary_file="$BATS_TEST_TMPDIR/summary.md"
  body="$(printf '<!-- persona:qa-lead -->\n## advisory\nrisk assessment')"

  run env PATH="$stub:$PATH" bash -c '
    source "'"$LIB"'"
    pr_post_advisory_or_preserve qa-lead petry-projects/.github-private 1723 \
      don-petry GH_PAT_DON_PETRY "'"$body"'" "'"$body_file"'" "'"$summary_file"'"
  '
  [ "$status" -eq 1 ]                              # AC #2: still a failure
  [ -f "$body_file" ]                              # AC #1: artifact copy preserved
  run cat "$body_file"
  [ "${lines[0]}" = "<!-- persona:qa-lead -->" ]   # marker included, re-postable
  [[ "$output" == *"risk assessment"* ]]
  run cat "$summary_file"
  [[ "$output" == *"403"* ]]                       # AC #3: cause named in summary
  [[ "$output" == *"authorization"* ]]
}

@test "pr_post_advisory_or_preserve: redacts secrets from the preserved copy" {
  stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$stub/gh"

  body_file="$BATS_TEST_TMPDIR/body.md"
  summary_file="$BATS_TEST_TMPDIR/summary.md"
  # Build a fake token at runtime so the literal never sits in this source file.
  fake="ghp_$(printf 'abcdefghij1234567890ABCDEFGHIJ')"
  body="$(printf '<!-- persona:qa-lead -->\ntoken leaked: %s\n' "$fake")"

  run env PATH="$stub:$PATH" bash -c '
    source "'"$LIB"'"
    pr_post_advisory_or_preserve qa-lead repo/x 5 acct CRED "'"$body"'" "'"$body_file"'" "'"$summary_file"'"
  '
  [ "$status" -eq 1 ]
  run cat "$body_file"
  [[ "$output" == *"***REDACTED-GH-TOKEN***"* ]]   # AC #4
  [[ "$output" != *"$fake"* ]]
}

@test "pr_post_advisory_or_preserve: a successful post writes no artifact file" {
  stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$stub/gh"

  body_file="$BATS_TEST_TMPDIR/body.md"
  summary_file="$BATS_TEST_TMPDIR/summary.md"

  run env PATH="$stub:$PATH" bash -c '
    source "'"$LIB"'"
    pr_post_advisory_or_preserve qa-lead repo/x 5 acct CRED "body" "'"$body_file"'" "'"$summary_file"'"
  '
  [ "$status" -eq 0 ]                              # AC #5: success unchanged
  [ ! -f "$body_file" ]                            # no artifact copy on success
}

@test "pr_post_advisory_or_preserve: a successful post publishes a redacted body" {
  stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  posted="$BATS_TEST_TMPDIR/posted.txt"
  # Record the body gh was asked to publish so we can assert it was scrubbed.
  cat > "$stub/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in body=*) printf '%s' "\${a#body=}" > "$posted" ;; esac
done
exit 0
STUB
  chmod +x "$stub/gh"

  body_file="$BATS_TEST_TMPDIR/body.md"
  summary_file="$BATS_TEST_TMPDIR/summary.md"
  fake="ghp_$(printf 'abcdefghij1234567890ABCDEFGHIJ')"
  body="$(printf '<!-- persona:qa-lead -->\ntoken leaked: %s\n' "$fake")"

  run env PATH="$stub:$PATH" bash -c '
    source "'"$LIB"'"
    pr_post_advisory_or_preserve qa-lead repo/x 5 acct CRED "'"$body"'" "'"$body_file"'" "'"$summary_file"'"
  '
  [ "$status" -eq 0 ]
  run cat "$posted"
  [[ "$output" == *"***REDACTED-GH-TOKEN***"* ]]   # secrets scrubbed before publishing
  [[ "$output" != *"$fake"* ]]
  [[ "$output" == *"<!-- persona:qa-lead -->"* ]]  # marker survives redaction
}

# --- posting-identity read (#2196) ------------------------------------------
# On a failed `gh api user` call gh prints the API error BODY on stdout, so the
# old inline read took '{' for a login and reported a wrong identity — and the
# advisory was lost because the body was written only after the check. The
# helper is tri-state (login / unreadable / not configured); the post step
# retries unreadable, fails closed at once on a readable mismatch, and stages
# the body before either.

# _login_stub <fails> — a gh stub whose `api user` prints an error body and
# exits non-zero for the first <fails> calls, then prints <login> (default
# don-petry). Calls are counted in $BATS_TEST_TMPDIR/user-calls; a comment
# post is recorded to $BATS_TEST_TMPDIR/posted.txt.
_login_stub() {
  stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  cat > "$stub/gh" <<STUB
#!/usr/bin/env bash
if [ "\$2" = "user" ]; then
  n=\$(( \$(cat "$BATS_TEST_TMPDIR/user-calls" 2>/dev/null || echo 0) + 1 ))
  echo "\$n" > "$BATS_TEST_TMPDIR/user-calls"
  if [ "\$n" -le "$1" ]; then
    printf '{\n  "message": "Server Error",\n  "status": "502"\n}\n'
    echo "gh: Server Error (HTTP 502)" >&2
    exit 1
  fi
  echo "${2:-don-petry}"
  exit 0
fi
for a in "\$@"; do
  case "\$a" in body=*) printf '%s' "\${a#body=}" > "$BATS_TEST_TMPDIR/posted.txt" ;; esac
done
exit 0
STUB
  chmod +x "$stub/gh"
}

# _run_post — run pr_run_post in a clean shell against the stub.
_run_post() {
  raw="$BATS_TEST_TMPDIR/agent-out.txt"
  printf 'chatter\n===PERSONA-ADVISORY-BEGIN===\n## advisory\nrisk: low\n===PERSONA-ADVISORY-END===\n' > "$raw"
  body_file="$BATS_TEST_TMPDIR/body.md"
  summary_file="$BATS_TEST_TMPDIR/summary.md"
  run env PATH="$stub:$PATH" GH_TOKEN=fake PR_LOGIN_RETRY_DELAY=0 bash -c '
    set -euo pipefail
    source "'"$LIB"'"
    pr_run_post qa-lead petry-projects/.github-private 2188 \
      don-petry GH_PAT_DON_PETRY "'"$raw"'" "'"$body_file"'" "'"$summary_file"'"
  '
}

@test "pr_valid_login accepts ordinary GitHub logins" {
  run pr_valid_login don-petry
  [ "$status" -eq 0 ]
  run pr_valid_login Octocat42
  [ "$status" -eq 0 ]
}

@test "pr_valid_login rejects a '{'-prefixed (JSON error body) value" {
  run pr_valid_login '{'
  [ "$status" -ne 0 ]
  run pr_valid_login '{"message":"Server Error"}'
  [ "$status" -ne 0 ]
}

@test "pr_valid_login rejects multi-line output and empty output" {
  run pr_valid_login "$(printf 'don-petry\nextra')"
  [ "$status" -ne 0 ]
  run pr_valid_login ""
  [ "$status" -ne 0 ]
}

@test "pr_read_posting_login: a readable login returns rc 0 and the login" {
  _login_stub 0
  run env PATH="$stub:$PATH" GH_TOKEN=fake bash -c 'source "'"$LIB"'"; pr_read_posting_login'
  [ "$status" -eq 0 ]
  [ "$output" = "don-petry" ]
}

@test "pr_read_posting_login: a failed call is UNREADABLE (rc 1), not a login" {
  _login_stub 9
  run env PATH="$stub:$PATH" GH_TOKEN=fake bash -c 'source "'"$LIB"'"; pr_read_posting_login'
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 502"* ]]                  # says why
}

@test "pr_read_posting_login: a token straddling the 300-char cut is redacted before truncation" {
  stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  pad="$(printf 'x%.0s' $(seq 1 259))"
  cat > "$stub/gh" <<STUB
#!/usr/bin/env bash
echo "${pad} ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" >&2
exit 1
STUB
  chmod +x "$stub/gh"
  run env PATH="$stub:$PATH" GH_TOKEN=fake bash -c 'source "'"$LIB"'"; pr_read_posting_login'
  [ "$status" -eq 1 ]
  [[ "$output" != *"ghp_"* ]]
}

@test "pr_read_posting_login: exit-0 output that is not a login is UNREADABLE" {
  _login_stub 0 '{'
  run env PATH="$stub:$PATH" GH_TOKEN=fake bash -c 'source "'"$LIB"'"; pr_read_posting_login'
  [ "$status" -eq 1 ]
}

@test "pr_read_posting_login: no token configured returns rc 2 without calling gh" {
  _login_stub 0
  run env PATH="$stub:$PATH" GH_TOKEN= bash -c 'source "'"$LIB"'"; pr_read_posting_login'
  [ "$status" -eq 2 ]
  [ ! -f "$BATS_TEST_TMPDIR/user-calls" ]
}

@test "pr_run_post: unreadable then readable identity -> retries and posts" {
  _login_stub 1
  _run_post
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/user-calls")" -eq 2 ]
  run cat "$BATS_TEST_TMPDIR/posted.txt"
  [ "${lines[0]}" = "<!-- persona:qa-lead -->" ]
  [[ "$output" == *"risk: low"* ]]
}

@test "pr_run_post: unreadable three times -> fails with the unreadable message, body preserved" {
  _login_stub 9
  _run_post
  [ "$status" -ne 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/user-calls")" -eq 3 ]
  [[ "$output" == *"could not read the posting identity"* ]]
  [[ "$output" == *"HTTP 502"* ]]
  [[ "$output" != *"authenticates as"* ]]          # never names an error body as the account
  [ ! -f "$BATS_TEST_TMPDIR/posted.txt" ]          # never posts unverified
  [ -f "$body_file" ]                              # AC #4: the artifact step has a file
  run cat "$body_file"
  [ "${lines[0]}" = "<!-- persona:qa-lead -->" ]
  [[ "$output" == *"risk: low"* ]]
}

@test "pr_run_post: a readable mismatch fails at once with the mismatch message" {
  _login_stub 0 someone-else
  _run_post
  [ "$status" -ne 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/user-calls")" -eq 1 ]   # no retry on a definite answer
  [[ "$output" == *"authenticates as 'someone-else'"* ]]
  [[ "$output" == *"not the manifest identity 'don-petry'"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/posted.txt" ]
  [ -f "$body_file" ]
}

@test "pr_run_post: no token configured fails closed and still preserves the body" {
  _login_stub 0
  raw="$BATS_TEST_TMPDIR/agent-out.txt"
  printf '===PERSONA-ADVISORY-BEGIN===\nrisk: low\n===PERSONA-ADVISORY-END===\n' > "$raw"
  body_file="$BATS_TEST_TMPDIR/body.md"
  run env PATH="$stub:$PATH" GH_TOKEN= PR_LOGIN_RETRY_DELAY=0 bash -c '
    source "'"$LIB"'"
    pr_run_post qa-lead repo/x 5 don-petry GH_PAT_DON_PETRY "'"$raw"'" "'"$body_file"'" /dev/null
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"no PAT available"* ]]
  [ -f "$body_file" ]
}

@test "pr_run_post: an empty advisory posts nothing and succeeds" {
  _login_stub 0
  raw="$BATS_TEST_TMPDIR/agent-out.txt"
  printf 'no sentinels here\n' > "$raw"
  run env PATH="$stub:$PATH" GH_TOKEN=fake bash -c '
    source "'"$LIB"'"
    pr_run_post qa-lead repo/x 5 don-petry CRED "'"$raw"'" "'"$BATS_TEST_TMPDIR/body.md"'" /dev/null
  '
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/posted.txt" ]
}

# --- handoff from the agent job to the post job ------------------------------

@test "pr_write_handoff keeps only the advisory: chatter stays out and tokens are redacted" {
  raw="$BATS_TEST_TMPDIR/agent-out.txt"
  fake="ghp_$(printf 'abcdefghij1234567890ABCDEFGHIJ')"
  printf 'chatter %s\n===PERSONA-ADVISORY-BEGIN===\n## advisory\ntoken %s\n===PERSONA-ADVISORY-END===\nafter\n' "$fake" "$fake" > "$raw"
  handoff="$BATS_TEST_TMPDIR/out/dir/advisory.txt"
  run pr_write_handoff "$raw" "$handoff"
  [ "$status" -eq 0 ]
  run cat "$handoff"
  [ "${lines[0]}" = "===PERSONA-ADVISORY-BEGIN===" ]
  [ "${lines[1]}" = "## advisory" ]
  [ "${lines[2]}" = "token ***REDACTED-GH-TOKEN***" ]
  [ "${lines[3]}" = "===PERSONA-ADVISORY-END===" ]
  [ "${#lines[@]}" -eq 4 ]
  [[ "$output" != *"chatter"* ]]
  [[ "$output" != *"after"* ]]
  [[ "$output" != *"$fake"* ]]
}

@test "pr_write_handoff: no advisory writes an empty block that pr_run_post skips" {
  raw="$BATS_TEST_TMPDIR/agent-out.txt"
  printf 'no sentinels here\n' > "$raw"
  handoff="$BATS_TEST_TMPDIR/advisory.txt"
  pr_write_handoff "$raw" "$handoff"
  _login_stub 0
  run env PATH="$stub:$PATH" GH_TOKEN=fake bash -c '
    source "'"$LIB"'"
    pr_run_post qa-lead repo/x 5 don-petry CRED "'"$handoff"'" "'"$BATS_TEST_TMPDIR/body.md"'" /dev/null
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to post"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/posted.txt" ]
}

@test "the handoff round-trips through pr_run_post: same advisory, marker guaranteed" {
  raw="$BATS_TEST_TMPDIR/agent-out.txt"
  printf 'chatter\n===PERSONA-ADVISORY-BEGIN===\n## advisory\nrisk: low\n===PERSONA-ADVISORY-END===\n' > "$raw"
  dir="$BATS_TEST_TMPDIR/handoff"
  pr_write_handoff "$raw" "$dir/$PR_HANDOFF_FILE"
  run pr_validate_handoff "$dir"
  [ "$status" -eq 0 ]
  _login_stub 0
  run env PATH="$stub:$PATH" GH_TOKEN=fake bash -c '
    source "'"$LIB"'"
    pr_run_post qa-lead repo/x 5 don-petry CRED "'"$dir/$PR_HANDOFF_FILE"'" "'"$BATS_TEST_TMPDIR/body.md"'" /dev/null
  '
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/posted.txt"
  [ "${lines[0]}" = "<!-- persona:qa-lead -->" ]
  [ "${lines[1]}" = "## advisory" ]
  [ "${lines[2]}" = "risk: low" ]
}

@test "pr_run_post treats the handoff as data: shell syntax in it is posted, not run" {
  canary="$BATS_TEST_TMPDIR/canary"
  handoff="$BATS_TEST_TMPDIR/advisory.txt"
  {
    echo '===PERSONA-ADVISORY-BEGIN==='
    echo "\$(touch $canary) \`touch $canary\` ; touch $canary"
    echo '===PERSONA-ADVISORY-END==='
  } > "$handoff"
  _login_stub 0
  run env PATH="$stub:$PATH" GH_TOKEN=fake bash -c '
    set -euo pipefail
    source "'"$LIB"'"
    pr_run_post qa-lead repo/x 5 don-petry CRED "'"$handoff"'" "'"$BATS_TEST_TMPDIR/body.md"'" /dev/null
  '
  [ "$status" -eq 0 ]
  [ ! -e "$canary" ]
  run cat "$BATS_TEST_TMPDIR/posted.txt"
  [ "${lines[1]}" = "\$(touch $canary) \`touch $canary\` ; touch $canary" ]
}

@test "pr_validate_handoff accepts one regular file within the cap" {
  dir="$BATS_TEST_TMPDIR/handoff"
  mkdir -p "$dir"
  head -c "$PR_HANDOFF_MAX_BYTES" /dev/zero | tr '\0' 'x' > "$dir/$PR_HANDOFF_FILE"
  run pr_validate_handoff "$dir"
  [ "$status" -eq 0 ]
}

@test "pr_validate_handoff refuses a file over the cap" {
  dir="$BATS_TEST_TMPDIR/handoff"
  mkdir -p "$dir"
  head -c "$(( PR_HANDOFF_MAX_BYTES + 1 ))" /dev/zero | tr '\0' 'x' > "$dir/$PR_HANDOFF_FILE"
  run pr_validate_handoff "$dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"over the"* ]]
}

@test "pr_validate_handoff refuses a missing directory and a missing file" {
  run pr_validate_handoff "$BATS_TEST_TMPDIR/absent"
  [ "$status" -ne 0 ]
  dir="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$dir"
  run pr_validate_handoff "$dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"found 0 entries"* ]]
}

@test "pr_validate_handoff refuses any extra entry, nested ones included" {
  dir="$BATS_TEST_TMPDIR/extra"
  mkdir -p "$dir"
  echo ok > "$dir/$PR_HANDOFF_FILE"
  echo extra > "$dir/other.sh"
  run pr_validate_handoff "$dir"
  [ "$status" -ne 0 ]
  dir="$BATS_TEST_TMPDIR/nested"
  mkdir -p "$dir/sub"
  echo ok > "$dir/$PR_HANDOFF_FILE"
  echo extra > "$dir/sub/inner"
  run pr_validate_handoff "$dir"
  [ "$status" -ne 0 ]
}

@test "pr_validate_handoff refuses a symlink, a wrong name and a symlinked directory" {
  target="$BATS_TEST_TMPDIR/target"
  echo secret > "$target"
  dir="$BATS_TEST_TMPDIR/symlink"
  mkdir -p "$dir"
  ln -s "$target" "$dir/$PR_HANDOFF_FILE"
  run pr_validate_handoff "$dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a regular file"* ]]
  [[ "$output" != *"secret"* ]]
  dir="$BATS_TEST_TMPDIR/renamed"
  mkdir -p "$dir"
  echo ok > "$dir/renamed.txt"
  run pr_validate_handoff "$dir"
  [ "$status" -ne 0 ]
  dir="$BATS_TEST_TMPDIR/real"
  mkdir -p "$dir"
  echo ok > "$dir/$PR_HANDOFF_FILE"
  ln -s "$dir" "$BATS_TEST_TMPDIR/linked"
  run pr_validate_handoff "$BATS_TEST_TMPDIR/linked"
  [ "$status" -ne 0 ]
}

# --- the reusable's job layout -----------------------------------------------
# What keeps the post job's inputs and credentials apart from the model's job.
# A contract on the workflow file, because Actions does not run these jobs here.
# Needs python3 + PyYAML.

WORKFLOW="$SCRIPT_DIR/.github/workflows/persona-runner-reusable.yml"

# _jobs <python-expression> — evaluate against the parsed `jobs` map, helpers
# included; exits 0 when the expression is truthy.
_jobs() {
  WF="$WORKFLOW" EXPR="$1" python3 - <<'PY'
import json, os, re, sys, yaml
jobs = yaml.safe_load(open(os.environ["WF"]))["jobs"]
def text(node):
    return json.dumps(node, ensure_ascii=False)
def steps(job):
    return jobs[job]["steps"]
def step(job, name_part):
    found = [s for s in steps(job) if name_part in s.get("name", "")]
    assert len(found) == 1, f"{name_part}: {len(found)} steps in {job}"
    return found[0]
def secrets_in(node):
    return sorted(set(re.findall(r"secrets\.([A-Za-z0-9_]+)", text(node))))
sys.exit(0 if eval(os.environ["EXPR"]) else 1)
PY
}

# _step_field <job> <step-name-part> <with|run> [key] — print one field of a step.
_step_field() {
  WF="$WORKFLOW" JOB="$1" NAME="$2" FIELD="$3" KEY="${4:-}" python3 - <<'PY'
import os, yaml
job = yaml.safe_load(open(os.environ["WF"]))["jobs"][os.environ["JOB"]]
found = [s for s in job["steps"] if os.environ["NAME"] in s.get("name", "")]
assert len(found) == 1
value = found[0][os.environ["FIELD"]]
print(value[os.environ["KEY"]] if os.environ["KEY"] else value)
PY
}

# _eval_token <job> <credential> <bot-secret> <owner-secret> — the value the
# job's posting-token expression yields. Actions `&&`/`||` keep Python's
# and/or truthiness for these string operands.
_eval_token() {
  WF="$WORKFLOW" JOB="$1" CRED="$2" BOT="$3" OWNER="$4" python3 - <<'PY'
import os, re, yaml
job = yaml.safe_load(open(os.environ["WF"]))["jobs"][os.environ["JOB"]]
found = [s["env"]["GH_TOKEN"] for s in job["steps"]
         if "secrets." in str(s.get("env", {}).get("GH_TOKEN", ""))]
assert len(found) == 1
e = found[0].strip()
assert e.startswith("${{") and e.endswith("}}")
e = re.sub(r"(steps\.identity|needs\.gate)\.outputs\.credential", "cred", e[3:-2])
e = e.replace("secrets.DON_PETRY_BOT_GH_PAT", "bot").replace("secrets.GH_PAT_DON_PETRY", "owner")
e = e.replace("&&", " and ").replace("||", " or ")
print(eval(e, {}, {"cred": os.environ["CRED"], "bot": os.environ["BOT"], "owner": os.environ["OWNER"]}))
PY
}

@test "workflow: the jobs are gate, run, post and the pause notice, in that dependency order" {
  _jobs "sorted(jobs) == ['fleet-paused', 'gate', 'post', 'run']"
  _jobs "jobs['run']['needs'] == 'gate'"
  _jobs "jobs['post']['needs'] == ['gate', 'run']"
}

@test "workflow: the model's job references only the engine credential" {
  _jobs "secrets_in(jobs['run']) == ['CLAUDE_CODE_OAUTH_TOKEN']"
}

@test "workflow: no job but the model's holds the engine credential or calls the CLI" {
  for job in gate post; do
    _jobs "'CLAUDE_CODE_OAUTH_TOKEN' not in text(jobs['$job'])"
    _jobs "'claude --print' not in text(jobs['$job']) and 'claude-code' not in text(jobs['$job'])"
  done
  _jobs "'claude --print' in step('run', 'Produce the advisory')['run']"
}

@test "workflow: every job checks out the workflow SHA, without persisted credentials, as its first step" {
  for job in gate run post; do
    _jobs "steps('$job')[0]['uses'].startswith('actions/checkout@')"
    _jobs "steps('$job')[0]['with']['ref'] == '\${{ github.workflow_sha }}'"
    _jobs "steps('$job')[0]['with']['persist-credentials'] is False"
  done
}

@test "workflow: PATs appear only in the single token value of the preflight and post steps" {
  for job in gate post; do
    _jobs "secrets_in(jobs['$job']) == ['DON_PETRY_BOT_GH_PAT', 'GH_PAT_DON_PETRY']"
    _jobs "len([s for s in steps('$job') if secrets_in(s)]) == 1"
    _jobs "[k for s in steps('$job') for k, v in s.get('env', {}).items() if 'secrets.' in v] == ['GH_TOKEN']"
    _jobs "'secrets.' not in text({k: v for k, v in jobs['$job'].items() if k != 'steps'})"
  done
  _jobs "secrets_in(step('gate', 'Authorization preflight'))"
  _jobs "secrets_in(step('post', 'Enforce marker'))"
}

@test "workflow: the posting token resolves to the manifest's PAT and never falls through" {
  for job in gate post; do
    [ "$(_eval_token "$job" DON_PETRY_BOT_GH_PAT bot-value owner-value)" = "bot-value" ]
    [ "$(_eval_token "$job" GH_PAT_DON_PETRY bot-value owner-value)" = "owner-value" ]
    [ "$(_eval_token "$job" DON_PETRY_BOT_GH_PAT '' owner-value)" = "" ]
    [ "$(_eval_token "$job" GH_PAT_DON_PETRY bot-value '')" = "" ]
    [ "$(_eval_token "$job" SOME_OTHER_PAT bot-value owner-value)" = "" ]
    [ "$(_eval_token "$job" '' bot-value owner-value)" = "" ]
  done
}

@test "workflow: the model's job exposes one output, used only by the post job's condition" {
  _jobs "list(jobs['run']['outputs']) == ['skip_post']"
  _jobs "'needs.run' not in text(steps('post'))"
  _jobs "'needs.run.outputs.skip_post == ' in jobs['post']['if']"
}

@test "workflow: the post target comes from inputs, identity from the gate job" {
  _jobs "step('post', 'Enforce marker')['env']['SOURCE_REPO'] == '\${{ inputs.source_repo }}'"
  _jobs "step('post', 'Enforce marker')['env']['ITEM_NUMBER'] == '\${{ inputs.item_number }}'"
  _jobs "step('post', 'Enforce marker')['env']['POSTING_ACCOUNT'] == '\${{ needs.gate.outputs.account }}'"
  _jobs "step('post', 'Enforce marker')['env']['POSTING_CREDENTIAL'] == '\${{ needs.gate.outputs.credential }}'"
}

@test "workflow: the post step validates the handoff, then parses it, and runs nothing from it" {
  _jobs "step('post', 'Download the advisory')['with']['path'] == '\${{ runner.temp }}/persona-handoff'"
  _jobs "step('post', 'Enforce marker')['env']['HANDOFF_DIR'] == '\${{ runner.temp }}/persona-handoff'"
  script="$(_step_field post 'Enforce marker' run)"
  [ "$(grep -cE '^[[:space:]]*(source|\.|bash|sh|eval)[[:space:]]' <<<"$script")" -eq 1 ]
  [[ "$script" == *'source scripts/lib/persona-runner.sh'* ]]
  [[ "$script" != *'cd "$HANDOFF_DIR'* ]]
  validate_line="$(grep -n 'pr_validate_handoff "\$HANDOFF_DIR"' <<<"$script" | cut -d: -f1)"
  post_line="$(grep -n '^pr_run_post' <<<"$script" | cut -d: -f1)"
  [ -n "$validate_line" ]
  [ -n "$post_line" ]
  [ "$validate_line" -lt "$post_line" ]
  [[ "$script" == *'"$HANDOFF_DIR/$PR_HANDOFF_FILE"'* ]]
}

@test "workflow: the artifact carries the handoff file alone, briefly, under the name the post job reads" {
  _jobs "step('run', 'Upload the advisory')['with']['name'] == step('post', 'Download the advisory')['with']['name']"
  _jobs "step('run', 'Upload the advisory')['with']['retention-days'] == 1"
  [ "$(_step_field run 'Upload the advisory' with path)" = "\${{ runner.temp }}/persona-handoff/$PR_HANDOFF_FILE" ]
  _jobs "'pr_write_handoff \"\$_out\" \"\$RUNNER_TEMP/persona-handoff/\${PR_HANDOFF_FILE}\"' in step('run', 'Produce the advisory')['run']"
}

@test "workflow: the caller passes exactly the secrets the reusable declares" {
  WF="$WORKFLOW" CALLER="$SCRIPT_DIR/.github/workflows/persona-runner.yml" python3 - <<'PY'
import os, yaml
caller = yaml.safe_load(open(os.environ["CALLER"]))["jobs"]["run"]["secrets"]
# PyYAML reads the `on:` key as True.
declared = yaml.safe_load(open(os.environ["WF"]))[True]["workflow_call"]["secrets"]
assert isinstance(caller, dict), "secrets must be named, not inherited"
assert sorted(caller) == sorted(declared), (sorted(caller), sorted(declared))
PY
}

@test "workflow: a fleet pause skips the model's job and the writer" {
  for job in gate run post; do
    _jobs "jobs['$job']['if'].startswith(\"vars.AGENTS_PAUSED != 'true'\")"
  done
}

@test "workflow: the gate's verdict guards every step of the model's job" {
  _jobs "len(steps('run')) == 4"
  _jobs "all(s['if'] == \"needs.gate.outputs.proceed == 'true'\" for s in steps('run')[:3])"
  _jobs "step('run', 'Upload the advisory')['if'] == \"steps.advise.outputs.skip_post == 'false'\""
}
