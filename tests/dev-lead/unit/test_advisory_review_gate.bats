#!/usr/bin/env bats
# Tests for advisory-review-gate.sh (non-blocking instant check)
#
# Validates instant (non-blocking) checking of advisory bot reviews
# No polling, no timeouts - just checks current state and returns immediately

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME%/*}")" && pwd)/../../scripts"
}

teardown() {
  unset SCRIPT_DIR
}

# ────────────────────────────────────────────────────────────────────
# STRUCTURAL TESTS
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: script is executable" {
  [ -x "$SCRIPT_DIR/lib/advisory-review-gate.sh" ]
}

@test "Advisory gate: script has correct shebang" {
  head -1 "$SCRIPT_DIR/lib/advisory-review-gate.sh" | grep -q "^#!/usr/bin/env bash"
}

@test "Advisory gate: script uses set -euo pipefail" {
  grep -q "^set -euo pipefail" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

# ────────────────────────────────────────────────────────────────────
# NON-BLOCKING DESIGN TESTS (NEW)
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: no polling loops (non-blocking design)" {
  ! grep -q "TIER1_WAIT\|TIER2_WAIT\|TIER3_WAIT" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: uses check_advisory_reviews (not wait_for_advisory_reviews)" {
  grep -q "check_advisory_reviews()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: returns 0 when bots submitted, 1 when waiting" {
  grep -q "return 0" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "return 1" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: no sleep/polling delays in main logic" {
  ! grep -q "POLL_INTERVAL\|sleep " "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

# ────────────────────────────────────────────────────────────────────
# CONFIGURATION & FUNCTIONALITY TESTS
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: defines all 4 advisory bots (gemini-code-assist)" {
  grep -q "gemini-code-assist" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: defines all 4 advisory bots (copilot-pull-request-reviewer)" {
  grep -q "copilot-pull-request-reviewer" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: defines all 4 advisory bots (sonarqubecloud)" {
  grep -q "sonarqubecloud" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: defines all 4 advisory bots (chatgpt-codex-connector)" {
  grep -q "chatgpt-codex-connector" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: includes get_advisory_bot_states function" {
  grep -q "get_advisory_bot_states()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: includes format_bot_status function" {
  grep -q "format_bot_status()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: handles color output (RED, YELLOW, GREEN)" {
  grep -q "RED=" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "YELLOW=" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "GREEN=" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: includes logging functions (log_info, log_warn, log_success)" {
  grep -q "log_info()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "log_warn()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "log_success()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

# ────────────────────────────────────────────────────────────────────
# SAFETY & INTEGRATION TESTS
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: PR_URL parameter validated safely" {
  grep -q 'if \[\[ -z "$pr_url" \]\]' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "Usage: check_advisory_reviews" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: PR number extraction uses correct regex" {
  grep -q 'grep -oE' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: jq query selects latest bot submission (sort_by time)" {
  grep -q 'sort_by(.time)' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: BASH_SOURCE check prevents source-time execution" {
  grep -q 'if \[\[ "${BASH_SOURCE\[0\]}" = "${0}" \]\]' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: bot logins not duplicated — jq uses ADVISORY_BOTS keys" {
  # The jq filter must not hard-code individual bot logins; it uses inside(\$bots)
  grep -q 'inside(\$bots)' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  # And the ADVISORY_BOTS array is the single source of truth
  grep -q 'ADVISORY_BOTS\[@\]' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: get_advisory_bot_states handles gh failures" {
  grep -q 'gh pr view.*2>&1' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q 'log_warn "gh pr view failed' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: waits for all ADVISORY_BOTS before approving" {
  grep -q 'num_submitted.*total_advisory_bots' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q 'total_advisory_bots=\${#ADVISORY_BOTS' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

# ────────────────────────────────────────────────────────────────────
# INTEGRATION TESTS
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: review-one-pr.sh calls non-blocking gate" {
  grep -q "check_advisory_reviews" "$SCRIPT_DIR/review-one-pr.sh"
  grep -q "source.*advisory-review-gate.sh" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Advisory gate: review-one-pr.sh skips on return code 1 (waiting for bots)" {
  grep -q 'if \[ $gate_rc -eq 1 \]' "$SCRIPT_DIR/review-one-pr.sh"
  grep -q 'exit 100' "$SCRIPT_DIR/review-one-pr.sh"
  grep -q "waiting-for-advisory-bots" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Advisory gate: review-one-pr.sh fails on return code 2 (API error)" {
  grep -q 'elif \[ $gate_rc -eq 2 \]' "$SCRIPT_DIR/review-one-pr.sh"
  grep -q "advisory-gate-api-error" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Advisory gate: uses subshell isolation in review-one-pr.sh" {
  # The gate runs in a true subshell ( ) — not a brace group { } — for isolation
  grep -q "source.*advisory-review-gate.sh" "$SCRIPT_DIR/review-one-pr.sh"
  grep -B6 "source.*advisory-review-gate.sh" "$SCRIPT_DIR/review-one-pr.sh" | grep -q "^($"
}

# ────────────────────────────────────────────────────────────────────
# CODE QUALITY TESTS
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: documentation mentions non-blocking design" {
  grep -q "non-blocking\|instant check\|re-trigger" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: shellcheck passes" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  shellcheck --shell=bash --severity=warning "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: script is minimal (non-blocking means fewer lines)" {
  local lines
  lines=$(wc -l < "$SCRIPT_DIR/lib/advisory-review-gate.sh")
  # Budget raised 500→515 for the #1596 partial-evidence decision-point hooks, then
  # 515→520 for the #1894 AC #2 dropped-bot naming (four lines that make the reduced
  # advisory denominator observable — which member fell out of "6 != 7" and why). The
  # heavy marker logic lives in scripts/lib/partial-evidence-marker.sh; only the
  # three irreducible timeout-branch hooks (deduplicated via _record_partial_evidence)
  # are here. Raised 520→565 for the #1903 cubic registration (author-scoped
  # trial-ended detector, fallback list, notice bots list, pattern accessor, and
  # comprehensive test coverage for false positive protection). Raised 560→600 for
  # #2008: the section-aware CodeRabbit rate-limit scope (a shared jq def that both
  # detectors apply). Raised 600→615 for #2008's producer-path edit-time merge
  # (get_advisory_bot_states merges lastEditedAt via maintainer_gate_merge_edit_times
  # before classifying). Raised 615→655 for #2005: the single-fetch, registry-driven
  # check-run clean-pass helper (_advisory_check_run_states). This still guards the
  # original intent: no polling loops, no ballooning.
  [ "$lines" -lt 655 ]
}

# ────────────────────────────────────────────────────────────────────
# RUNTIME BEHAVIOR TESTS
# ────────────────────────────────────────────────────────────────────

_make_mock_gh_dir() {
  local json_reviews_comments="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"reviews,comments"* ]]; then
  printf '%s\n' '$json_reviews_comments'
elif [[ "\$args" == *"graphql"* ]]; then
  # Return a timestamp 30 minutes ago (well past the 20-minute push-age timeout)
  date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || printf '2000-01-01T00:00:00Z\n'
fi
MOCK_EOF
  chmod +x "$tmpdir/gh"
  echo "$tmpdir"
}

_make_mock_gh_dir_recent() {
  local json_reviews_comments="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"reviews,comments"* ]]; then
  printf '%s\n' '$json_reviews_comments'
elif [[ "\$args" == *"graphql"* ]]; then
  # Return current time (cherry-pick/commit was applied just now, within the 20-minute window)
  date -u '+%Y-%m-%dT%H:%M:%SZ'
fi
MOCK_EOF
  chmod +x "$tmpdir/gh"
  echo "$tmpdir"
}

# Mock for the cherry-picked commit scenario:
# A commit with an old author date was cherry-picked just now.
# committer.date (GraphQL) = now (recent) — this is what the gate must use.
# If the gate mistakenly used author.date (old), head_age_sec would be large
# and the timeout would fire immediately, bypassing the gate.
_make_mock_gh_dir_old_commit_recent_push() {
  local json_reviews_comments="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"reviews,comments"* ]]; then
  printf '%s\n' '$json_reviews_comments'
elif [[ "\$args" == *"graphql"* ]]; then
  # committer.date is current time — the cherry-pick was applied just now.
  # (author.date would be 2+ hours ago, but the gate uses committer.date.)
  date -u '+%Y-%m-%dT%H:%M:%SZ'
fi
MOCK_EOF
  chmod +x "$tmpdir/gh"
  echo "$tmpdir"
}

@test "Gate runtime: returns 1 when no bots have submitted and PR is recent" {
  # Within the head-age window: absent bots may still be slow, so keep waiting.
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_recent '{"reviews":[],"comments":[]}')
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

@test "Gate runtime: returns 0 when no bots have submitted and head-age timeout elapsed (issue #1193)" {
  # Durable hardening: when ZERO advisory bots have produced any output on the PR
  # (bot not vendor-enabled / uninstalled / bot outage) and the head is older than
  # the head-age window, the absent bots become *missing reviews* — the gate must
  # proceed instead of blocking forever. _make_mock_gh_dir returns a committer date
  # ~30 min old, past the 1200s window.
  local tmpdir
  tmpdir=$(_make_mock_gh_dir '{"reviews":[],"comments":[]}')
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
}

@test "Gate runtime: no bots + head time unavailable → conservative wait (issue #1193)" {
  # Graceful degradation: with no bot output AND no determinable head age (GraphQL
  # unreachable), there is no timing basis to declare bots absent, so the gate stays
  # conservative and waits — the next scheduled sweep retries once the API recovers.
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_no_head_time '{"reviews":[],"comments":[]}')
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

@test "Gate runtime: returns 0 when all 4 bots have submitted" {
  local all_bots_json
  all_bots_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z"},{"author":{"login":"copilot-pull-request-reviewer"},"state":"COMMENTED","submittedAt":"2026-06-07T10:03:00Z"},{"author":{"login":"sonarqubecloud"},"state":"COMMENTED","submittedAt":"2026-06-07T10:13:00Z"},{"author":{"login":"chatgpt-codex-connector"},"state":"COMMENTED","submittedAt":"2026-06-07T10:17:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir "$all_bots_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
}

@test "Gate runtime: returns 1 when only 1 bot submitted and PR is recent" {
  local one_bot_json
  # Use a far-future submittedAt so time_since_last_sub is always negative,
  # ensuring the quiescence fallback never fires and the test stays stable.
  one_bot_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_recent "$one_bot_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

@test "Gate runtime: returns 0 after timeout even with partial bot submissions" {
  local one_bot_json
  one_bot_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir "$one_bot_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
}

@test "Gate runtime: stale submission from previous HEAD does not trigger quiescence for fresh commit" {
  # Head was just pushed (recent). The only submission is from a previous HEAD
  # (year 2000), so it predates the current head push.
  # The quiescence baseline is anchored to max(head_push_time, latest_sub_time),
  # which equals the current head push time — so time_since_last_sub ≈ 0,
  # the fallback does not fire, and the gate correctly returns 1 (wait).
  local old_submission_json
  old_submission_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2000-01-01T00:00:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_recent "$old_submission_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

@test "Gate runtime: returns 1 for recently-pushed old cherry-picked commit" {
  # Regression test: head_age_sec must use committer.date (time the cherry-pick
  # was applied), not the commit's own author.date. An old cherry-picked commit
  # has a far-past author.date but committer.date ≈ now; using author.date would
  # make head_age_sec exceed 20 min immediately and bypass the gate.
  local one_bot_json
  one_bot_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_old_commit_recent_push "$one_bot_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

# Mock where GraphQL returns the committer date directly (30 minutes ago).
# Used to verify the head-age timeout fires for PRs with partial bot coverage.
_make_mock_gh_dir_null_pushed_date() {
  local json_reviews_comments="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"reviews,comments"* ]]; then
  printf '%s\n' '$json_reviews_comments'
elif [[ "\$args" == *"graphql"* ]]; then
  # Return committer date 30 minutes ago — head-age timeout fires
  date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || printf '2000-01-01T00:00:00Z\n'
fi
MOCK_EOF
  chmod +x "$tmpdir/gh"
  echo "$tmpdir"
}

# Mock for the scenario where head time is completely unavailable
# (GraphQL API returns empty — no committer date available).
# Used to verify quiescence fires from latest_sub_at alone.
_make_mock_gh_dir_no_head_time() {
  local json_reviews_comments="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"reviews,comments"* ]]; then
  printf '%s\n' '$json_reviews_comments'
elif [[ "\$args" == *"graphql"* ]]; then
  # Return empty to simulate GraphQL being unreachable / head time unavailable
  printf '\n'
fi
MOCK_EOF
  chmod +x "$tmpdir/gh"
  echo "$tmpdir"
}

@test "Gate runtime: head-age timeout fires when GraphQL returns old committer date" {
  # Regression test for issue #577: pushedDate now returns null from GitHub's GraphQL API.
  # The gate fetches the head commit's committer date directly via GraphQL so that the
  # head-age timeout fallback fires for PRs with partial bot coverage.
  local one_bot_json
  one_bot_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_null_pushed_date "$one_bot_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  # GraphQL returns committer date 30 min old → head_age_sec > 1200 → timeout fires → proceed
  [ "$status" -eq 0 ]
}

@test "Gate runtime: quiescence fallback fires when head time unavailable and submissions are old" {
  # When the GraphQL API is unreachable (head_time empty), the quiescence
  # fallback must still fire from latest_sub_at alone, preventing indefinite stranding.
  local one_bot_json
  # Submission timestamp is in the past (well over 10 min ago)
  one_bot_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_no_head_time "$one_bot_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  # latest_sub_at is old (>10 min) → quiescence fires even without head time → proceed
  [ "$status" -eq 0 ]
}

@test "Gate runtime: returns 2 when gh command fails (API error, not normal wait)" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "Error: authentication required" >&2
exit 1
MOCK_EOF
  chmod +x "$tmpdir/gh"
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  # API errors return 2 (distinct from "bots not submitted yet" = 1)
  # so the caller can fail-fast rather than treating the error as a normal wait.
  [ "$status" -eq 2 ]
}

# ────────────────────────────────────────────────────────────────────
# SOURCE-TIME RESILIENCE (issue #1538)
#
# The gate is *sourced* by long-running review processes and by the whole bats
# suite. A registry-read failure must never `exit` the caller — historically it
# did (exit 1 at source time), so a transient/edge read failure silently killed
# every runtime gate test in a run and surfaced as the DEGRADED test-dev-lead
# signal. The gate must instead fall back to its built-in bot lists.
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: sourcing survives an unreadable reviewer-source registry (no exit, uses fallback) (#1538)" {
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env REVIEWER_SOURCES_MANIFEST=/nonexistent/reviewer-sources.tsv bash -c "
    source '$gate_script'
    echo \"BOTS=\${#ADVISORY_BOTS[@]}\"
    echo \"NOTICE=\${#RATE_LIMIT_NOTICE_BOTS[@]}\"
  "
  # Must NOT exit the sourcing shell; must expose the built-in fallback sets.
  # BOTS=5 is the post-#1997 advisory-wait set (gemini, sonarqubecloud, codeant-ai,
  # graphite-app, cubic-dev-ai); copilot/codex/qodo were dropped. NOTICE stays 9 — the
  # rate-limit notice superset is ALL registered sources, which #1997 did not change.
  [ "$status" -eq 0 ]
  [[ "$output" == *"BOTS=5"* ]]
  [[ "$output" == *"NOTICE=9"* ]]
}

@test "Advisory gate: runtime check still runs when the registry is unreadable (#1538)" {
  # With the registry unreadable, check_advisory_reviews must still execute and
  # apply the head-age timeout (return 0) rather than dying at source time.
  local tmpdir
  tmpdir=$(_make_mock_gh_dir '{"reviews":[],"comments":[]}')
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env REVIEWER_SOURCES_MANIFEST=/nonexistent/reviewer-sources.tsv PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
}

# ────────────────────────────────────────────────────────────────────
# RATE-LIMIT HANDLING TESTS (issue #657)
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: defines rate-limit markers and detects RATE_LIMITED state" {
  # get_advisory_bot_states must classify a bot's usage-limit comment as RATE_LIMITED
  grep -q 'RATE_LIMITED' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -qi 'reached your Codex usage limit\|Review limit reached\|used up its prepaid credits' \
    "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: drops rate-limited/unsupported bots from required total (effective_total)" {
  grep -q 'effective_total' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: names the absent-bot timeout windows as constants (issue #1193)" {
  grep -q 'ADVISORY_HEAD_AGE_TIMEOUT_SEC=1200' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q 'ADVISORY_QUIESCENCE_TIMEOUT_SEC=600' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: empty-state branch applies head-age timeout, not an unconditional wait (issue #1193)" {
  # The zero-output branch must consult head age before deciding to wait.
  # Use a fixed-string match on the assignment/call so the test fails if
  # the call is removed, without also matching the function definition line.
  grep -qF 'head_age_sec=$(_head_age_seconds' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Gate runtime: rate-limited bot is classified RATE_LIMITED in gate output" {
  # codeant-ai (still in the advisory-wait set post-#1997) posts an out-of-quota notice;
  # the gate must classify its latest submission RATE_LIMITED.
  local json
  json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"sonarqubecloud"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"}],"comments":[{"author":{"login":"codeant-ai"},"body":"You have reached your usage limit for code reviews.","createdAt":"2099-01-01T00:00:00Z"}]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [[ "$output" == *"RATE_LIMITED"* ]]
}

@test "Gate runtime: out-of-quota bot does not hold the gate but gate still waits for other absent bots" {
  # Two real advisory reviews + Codex signalling it is out of quota, copilot absent,
  # head + submissions recent (timeout fallbacks disarmed). The rate-limited Codex must
  # be treated as non-participating, but we must still wait for the absent Copilot.
  local json
  json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"sonarqubecloud"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"}],"comments":[{"author":{"login":"chatgpt-codex-connector"},"body":"You have reached your Codex usage limits for code reviews.","createdAt":"2099-01-01T00:00:00Z"}]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

@test "Gate runtime: out-of-quota bot does not hold the gate (returns 0 when all other available bots submitted)" {
  # Three real advisory reviews + Codex signalling it is out of quota, head + submissions
  # recent (timeout fallbacks disarmed). All available bots have submitted, so the gate approves.
  local json
  json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"sonarqubecloud"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"copilot-pull-request-reviewer"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"qodo-code-review"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"codeant-ai"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"graphite-app"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"cubic-dev-ai"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"}],"comments":[{"author":{"login":"chatgpt-codex-connector"},"body":"You have reached your Codex usage limits for code reviews.","createdAt":"2099-01-01T00:00:00Z"}]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
}

@test "Gate runtime: plain comment (no rate-limit marker) is not excluded — gate still waits" {
  # Codex posts an ordinary comment without any usage-limit marker. It must NOT be
  # treated as rate-limited, so with copilot still absent the gate keeps waiting.
  local json
  json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"sonarqubecloud"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"}],"comments":[{"author":{"login":"chatgpt-codex-connector"},"body":"Looks good to me, nice work.","createdAt":"2099-01-01T00:00:00Z"}]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

@test "Gate runtime: format_bot_status renders known states" {
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "
    source '$gate_script' 2>/dev/null || true
    format_bot_status 'gemini-code-assist' 'APPROVED'
  "
  [[ "$output" == *"APPROVED"* ]]
  run bash -c "
    source '$gate_script' 2>/dev/null || true
    format_bot_status 'sonarqubecloud' 'CHANGES_REQUESTED'
  "
  [[ "$output" == *"CHANGES_REQUESTED"* ]]
}

# ────────────────────────────────────────────────────────────────────
# RATE-LIMIT DETECTION TESTS (issue #711)
#
# detect_advisory_rate_limit <reviews-comments-json>
#   returns 0 when a known advisory/review bot's LATEST submission body matches
#   a rate-limit phrase; 1 otherwise. The marker it arms lets pr-review-sweep
#   auto-retry once the limit resets (no manual force_review).
# ────────────────────────────────────────────────────────────────────

@test "detect_advisory_rate_limit: function exists" {
  grep -q "detect_advisory_rate_limit()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "detect_advisory_rate_limit: true when codex posts a usage-limit notice" {
  local json
  json='{"reviews":[],"comments":[{"author":{"login":"chatgpt-codex-connector"},"createdAt":"2026-06-07T10:00:00Z","body":"You have reached your usage limit. Please try again later."}]}'
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "source '$gate_script'; detect_advisory_rate_limit '$json'"
  [ "$status" -eq 0 ]
}

@test "detect_advisory_rate_limit: true when coderabbit posts a rate-limit notice" {
  local json
  json='{"reviews":[{"author":{"login":"coderabbitai"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z","body":"Review skipped: rate limit exceeded. Reviews will resume after the limit resets."}],"comments":[]}'
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "source '$gate_script'; detect_advisory_rate_limit '$json'"
  [ "$status" -eq 0 ]
}

@test "detect_advisory_rate_limit: false when bot's latest submission is a real review" {
  local json
  json='{"reviews":[{"author":{"login":"chatgpt-codex-connector"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z","body":"I found a potential null pointer dereference on line 42."}],"comments":[]}'
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "source '$gate_script'; detect_advisory_rate_limit '$json'"
  [ "$status" -eq 1 ]
}

@test "detect_advisory_rate_limit: false when a newer real review supersedes the rate-limit notice" {
  # Older comment is a rate-limit notice; newer review is a real review.
  # The latest submission per bot wins → not rate-limited.
  local json
  json='{"reviews":[{"author":{"login":"chatgpt-codex-connector"},"state":"COMMENTED","submittedAt":"2026-06-07T11:00:00Z","body":"LGTM, no issues found."}],"comments":[{"author":{"login":"chatgpt-codex-connector"},"createdAt":"2026-06-07T10:00:00Z","body":"You have reached your usage limit."}]}'
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "source '$gate_script'; detect_advisory_rate_limit '$json'"
  [ "$status" -eq 1 ]
}

@test "detect_advisory_rate_limit: true when a newer rate-limit notice supersedes an older real review" {
  # Older review was real; newer comment is a rate-limit notice → rate-limited now.
  local json
  json='{"reviews":[{"author":{"login":"chatgpt-codex-connector"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z","body":"Looks good overall."}],"comments":[{"author":{"login":"chatgpt-codex-connector"},"createdAt":"2026-06-07T11:00:00Z","body":"You have reached your usage limit. Try again later."}]}'
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "source '$gate_script'; detect_advisory_rate_limit '$json'"
  [ "$status" -eq 0 ]
}

@test "detect_advisory_rate_limit: false when the rate-limit phrase comes from a non-advisory (human) author" {
  local json
  json='{"reviews":[],"comments":[{"author":{"login":"some-human"},"createdAt":"2026-06-07T10:00:00Z","body":"We should add a rate limit to this endpoint, quota exceeded errors are common."}]}'
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "source '$gate_script'; detect_advisory_rate_limit '$json'"
  [ "$status" -eq 1 ]
}

@test "detect_advisory_rate_limit: false on empty input" {
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "source '$gate_script'; detect_advisory_rate_limit '{\"reviews\":[],\"comments\":[]}'"
  [ "$status" -eq 1 ]
}

# ── #2008: section-aware CodeRabbit rate-limit detection ───────────────────────
# CodeRabbit posts ONE summary comment, edited in place, that carries two
# independently throttled outputs. Its rate-limit detection must look ONLY inside
# the `rate limited by coderabbit.ai` marker block (a walkthrough that merely
# discusses rate limits is not a notice), must order by the comment's last-edit
# time, and a summary that carries a Security Architecture Review section is
# CodeRabbit evidence — never "rate-limited, no evidence".

_cr_summary() {
  # _cr_summary <inner-markdown> — wrap content in CodeRabbit's summary markers.
  printf '<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\n%s\n<!-- tips_start -->\n<!-- tips_end -->' "$1"
}

_cr_rl_block() {
  printf '<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\n> [!WARNING]\n> ## Review limit reached\n>\n> You'"'"'ve used all free OSS reviews for now.\n<!-- end of auto-generated comment: rate limited by coderabbit.ai -->'
}

_detect_cr() {
  # _detect_cr <body> [createdAt] [lastEditedAt] [extra-reviews-json]
  local json
  json=$(jq -cn --arg b "$1" --arg c "${2:-2026-06-07T10:00:00Z}" --arg e "${3:-}" --argjson r "${4:-[]}" '
    {reviews:$r, comments:[{author:{login:"coderabbitai"}, createdAt:$c, body:$b}
      + (if $e == "" then {} else {lastEditedAt:$e} end)]}')
  run bash -c "source '$SCRIPT_DIR/lib/advisory-review-gate.sh'; detect_advisory_rate_limit \"\$1\"" _ "$json"
}

@test "detect_advisory_rate_limit(#2008): a CodeRabbit walkthrough that merely mentions rate limits is NOT a notice" {
  _detect_cr "$(_cr_summary $'<!-- walkthrough_start -->\n## Walkthrough\nAdds a rate limit to the API client; a 429 "Too many requests" response now backs off. Usage limit reached errors are retried.\n<!-- walkthrough_end -->')"
  [ "$status" -eq 1 ]
}

@test "detect_advisory_rate_limit(#2008): a CodeRabbit summary with the rate-limited marker block IS detected" {
  _detect_cr "$(_cr_summary "$(_cr_rl_block)"$'\n<!-- walkthrough_start -->\nTests only.\n<!-- walkthrough_end -->')"
  [ "$status" -eq 0 ]
}

@test "detect_advisory_rate_limit(#2008): PR #2000's body (throttled code review + security finding) IS rate-limited" {
  # The security section does not hide the throttled code review: it is still
  # detected so the review is retried. The security finding itself is held by the
  # maintainer gate (test_maintainer_comment_gate.bats), not by this detector.
  local fixture="$SCRIPT_DIR/../tests/fixtures/coderabbit/pr2000-ratelimited-with-security-finding.md"
  [ -s "$fixture" ]
  grep -q 'architecture_review_start' "$fixture"
  _detect_cr "$(cat "$fixture")"
  [ "$status" -eq 0 ]
}

@test "detect_advisory_rate_limit(#2008): a security section that only mentions a rate limit is not a notice" {
  _detect_cr "$(_cr_summary $'<!-- architecture_review_start -->\n### Security Architecture Review\n- Low: the client ignores the API rate limit and usage limit reached errors.\n<!-- architecture_review_end -->')"
  [ "$status" -eq 1 ]
}

@test "detect_advisory_rate_limit(#2008): the CodeRabbit summary is ordered by its last-edit time, not creation" {
  # Created 10:00 (before a real 11:00 review) but EDITED at 12:00 into a
  # rate-limit notice: the edit is the latest CodeRabbit state → detected.
  local reviews='[{"author":{"login":"coderabbitai"},"state":"COMMENTED","submittedAt":"2026-06-07T11:00:00Z","body":"Looks fine."}]'
  _detect_cr "$(_cr_summary "$(_cr_rl_block)")" "2026-06-07T10:00:00Z" "2026-06-07T12:00:00Z" "$reviews"
  [ "$status" -eq 0 ]
  # Without the edit time the 11:00 review is the latest → not detected.
  _detect_cr "$(_cr_summary "$(_cr_rl_block)")" "2026-06-07T10:00:00Z" "" "$reviews"
  [ "$status" -eq 1 ]
}

@test "Advisory gate(#2008): get_advisory_bot_states classifies comments via the section-aware scope" {
  grep -q '_ADVISORY_RL_SCOPE_JQ' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  [ "$(grep -c '_ADVISORY_RL_SCOPE_JQ' "$SCRIPT_DIR/lib/advisory-review-gate.sh")" -ge 3 ]
}

# ────────────────────────────────────────────────────────────────────
# RATE-LIMITED MARKER POSTING TESTS (issue #711)
#
# maybe_post_rate_limited_marker <pr_url> <head_sha> <reset_iso> <comments_json>
#   posts a deduplicated marker comment so the sweep can detect the
#   withheld-due-to-rate-limit state and auto-retry after <reset_iso>.
# ────────────────────────────────────────────────────────────────────

@test "maybe_post_rate_limited_marker: function exists" {
  grep -q "maybe_post_rate_limited_marker()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "maybe_post_rate_limited_marker: posts a marker comment when none exists at head" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmpdir/calls"
exit 0
MOCK_EOF
  chmod +x "$tmpdir/gh"
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    maybe_post_rate_limited_marker 'https://github.com/owner/repo/pull/123' 'abc123' '2999-01-01T00:00:00Z' '{\"comments\":[]}'
  "
  local calls; calls=$(cat "$tmpdir/calls" 2>/dev/null || true)
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  # gh pr comment was invoked with the rate-limited marker for this head
  [[ "$calls" == *"pr comment"* ]]
  [[ "$calls" == *"rate-limited v1 sha=abc123"* ]]
  [[ "$calls" == *"status=rate-limited"* ]]
  [[ "$calls" == *"reset=2999-01-01T00:00:00Z"* ]]
}

@test "maybe_post_rate_limited_marker: does not re-post when a marker already exists at head" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmpdir/calls"
exit 0
MOCK_EOF
  chmod +x "$tmpdir/gh"
  local existing
  existing='{"comments":[{"body":"<!-- pr-review-agent rate-limited v1 sha=abc123 status=rate-limited reset=2999-01-01T00:00:00Z -->\n\nAdvisory bots were rate-limited."}]}'
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    maybe_post_rate_limited_marker 'https://github.com/owner/repo/pull/123' 'abc123' '2999-01-01T00:00:00Z' '$existing'
  "
  local calls; calls=$(cat "$tmpdir/calls" 2>/dev/null || true)
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  # No new comment should be posted when a marker for this head already exists
  [[ "$calls" != *"pr comment"* ]]
}

@test "maybe_post_rate_limited_marker: DRY_RUN=true posts nothing on the rate-limited path" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmpdir/calls"
exit 0
MOCK_EOF
  chmod +x "$tmpdir/gh"
  # Same sequence review-one-pr.sh runs when the gate withholds: a rate-limited
  # advisory bot is detected in the snapshot, then the marker helper is called.
  local snapshot
  snapshot='{"reviews":[],"comments":[{"author":{"login":"chatgpt-codex-connector"},"createdAt":"2026-06-07T10:00:00Z","body":"You have reached your usage limit. Please try again later."}]}'
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" DRY_RUN=true bash -c "
    source '$gate_script'
    detect_advisory_rate_limit '$snapshot' || exit 9
    maybe_post_rate_limited_marker 'https://github.com/owner/repo/pull/123' 'abc123' '2999-01-01T00:00:00Z' '$snapshot'
  "
  local calls; calls=$(cat "$tmpdir/calls" 2>/dev/null || true)
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  # A dry run makes no GitHub write — and says what it would have posted.
  [[ "$calls" != *"pr comment"* ]]
  [ -z "$calls" ]
  [[ "$output" == *"DRY_RUN: would post rate-limited marker"* ]]
}

# ────────────────────────────────────────────────────────────────────
# NEW ADVISORY REVIEWERS — Qodo Merge + CodeAnt (issue #1349)
#
# Graphite was deferred here because it had authored no review/comment at
# #1349/#1355 implementation time, so its GraphQL author login was unverified
# (the Qodo guess `qodo-merge-pro` was already proven wrong — real login is
# `qodo-code-review`). It has since posted real COMMENTED reviews on PR #1355,
# verifying its login is `graphite-app`, and is now registered under #1401
# (see the Graphite section below).
# ────────────────────────────────────────────────────────────────────

_events_dir() {
  echo "$(cd "$(dirname "$BATS_TEST_FILENAME")/../fixtures/events" && pwd)"
}

@test "Advisory gate: Qodo + CodeAnt are registered advisory bots (issue #1349)" {
  grep -q 'qodo-code-review' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q 'codeant-ai' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: gate markers and sweep/scorecard detector share one regex (no drift, issue #1349)" {
  # RATE_LIMIT_MARKERS (gate classification) and _advisory_rate_limit_pattern
  # (sweep retry + reviewer scorecard) must resolve to the SAME canonical regex,
  # so a quota refusal can never be a RATE_LIMITED comment in one path and a
  # normal COMMENTED submission in another.
  run bash -c "source '$SCRIPT_DIR/lib/advisory-review-gate.sh'
    [ \"\$RATE_LIMIT_MARKERS\" = \"\$(_advisory_rate_limit_pattern)\" ] && echo SAME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SAME"* ]]
}

@test "Advisory gate: bot-specific Qodo/CodeAnt trial phrases match the shared detector (no drift, issue #1349)" {
  # The exact phrases the gate matches for the new trial bots must ALSO be caught
  # by _advisory_rate_limit_pattern, or a refusal would arm the gate but never
  # trigger a sweep retry / scorecard refusal count.
  run bash -c "source '$SCRIPT_DIR/lib/advisory-review-gate.sh'
    pat=\"\$(_advisory_rate_limit_pattern)\"
    for msg in 'CodeAnt AI: free trial limit' 'Qodo Merge: monthly PR limit'; do
      printf '%s' \"\$msg\" | grep -qiE \"\$pat\" || { echo \"MISS:\$msg\"; exit 1; }
    done
    echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "Advisory gate: Qodo + CodeAnt are in the rate-limit notice superset (issue #1349)" {
  # RATE_LIMIT_NOTICE_BOTS must be a superset of ADVISORY_BOTS so the scorecard /
  # sweep never drift below the gate's set.
  run bash -c "source '$SCRIPT_DIR/lib/advisory-review-gate.sh'
    printf '%s\n' \"\${RATE_LIMIT_NOTICE_BOTS[@]}\""
  [[ "$output" == *"qodo-code-review"* ]]
  [[ "$output" == *"codeant-ai"* ]]
}

@test "Advisory gate: RATE_LIMIT_NOTICE_BOTS is a superset of ADVISORY_BOTS (no drift, issue #1349)" {
  run bash -c "source '$SCRIPT_DIR/lib/advisory-review-gate.sh'
    for b in \"\${!ADVISORY_BOTS[@]}\"; do
      printf '%s\n' \"\${RATE_LIMIT_NOTICE_BOTS[@]}\" | grep -qx \"\$b\" || { echo \"MISSING:\$b\"; exit 1; }
    done
    echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "Gate runtime: a Qodo review is NO LONGER treated as an advisory-gate submission (dropped from approval-wait set, #1997)" {
  # #1997 dropped qodo-code-review from the advisory-wait set (advisory_gate=no): it
  # produced no countable review across eight consecutive PRs. The gate filters by
  # ADVISORY_BOTS, so a qodo review is no longer counted here — it must not appear in the
  # gate's detected-bot output. (qodo remains dev-lead-trusted and on the scorecard; it
  # leaves only the approval-wait set.)
  local json; json="$(cat "$(_events_dir)/advisory_qodo_reviewed.json")"
  local tmpdir; tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [[ "$output" != *"qodo-code-review"* ]]
}

@test "Gate runtime: a CodeAnt review is detected as an advisory bot submission (issue #1349)" {
  local json; json="$(cat "$(_events_dir)/advisory_codeant_reviewed.json")"
  local tmpdir; tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [[ "$output" == *"codeant-ai"* ]]
}

@test "Gate runtime: a Qodo out-of-quota notice is ignored by the gate (dropped from approval-wait set, #1997)" {
  # Mirror of the review case: with qodo dropped from the advisory-wait set (#1997) the
  # gate no longer inspects qodo's submissions at all, so its rate-limit notice is neither
  # counted nor classified here — qodo must not appear in the gate output.
  local json; json="$(cat "$(_events_dir)/advisory_qodo_rate_limited.json")"
  local tmpdir; tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [[ "$output" != *"qodo-code-review"* ]]
}

@test "Gate runtime: a CodeAnt out-of-quota notice is classified RATE_LIMITED (issue #1349)" {
  local json; json="$(cat "$(_events_dir)/advisory_codeant_rate_limited.json")"
  local tmpdir; tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [[ "$output" == *"RATE_LIMITED"* ]]
  [[ "$output" == *"codeant-ai"* ]]
}

@test "Gate runtime: an out-of-quota trial bot does not wedge the gate (issue #1349, cf #657)" {
  # Qodo is out of quota; all other advisory bots have submitted real reviews.
  # The rate-limited Qodo must drop out of the required set so the gate approves.
  local json
  json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"copilot-pull-request-reviewer"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"sonarqubecloud"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"chatgpt-codex-connector"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"codeant-ai"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"graphite-app"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"cubic-dev-ai"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"}],"comments":[{"author":{"login":"qodo-code-review"},"body":"Qodo Merge has reached your monthly usage limit for pull-request reviews.","createdAt":"2099-01-01T00:00:00Z"}]}'
  local tmpdir; tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
}

# ────────────────────────────────────────────────────────────────────
# GRAPHITE ADVISORY REVIEWER (issue #1401, follow-up to #1349 / #1355)
#
# Deferred in #1355 because Graphite had authored no review/comment, so its
# GraphQL author login was unverified. It has since posted real COMMENTED
# reviews on PR #1355, confirming its login is `graphite-app` (the app slug
# happens to equal the .author.login here) — so it is now registered per the
# "do not guess identifiers" guardrail (login verified, not guessed).
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: Graphite is a registered advisory bot (issue #1401)" {
  grep -q 'graphite-app' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: Graphite is in the rate-limit notice superset (issue #1401)" {
  run bash -c "source '$SCRIPT_DIR/lib/advisory-review-gate.sh'
    printf '%s\n' \"\${RATE_LIMIT_NOTICE_BOTS[@]}\""
  [[ "$output" == *"graphite-app"* ]]
}

@test "Gate runtime: a Graphite review is detected as an advisory bot submission (issue #1401)" {
  local json; json="$(cat "$(_events_dir)/advisory_graphite_reviewed.json")"
  local tmpdir; tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  # If Graphite were unregistered it would be filtered out and never appear in output.
  [[ "$output" == *"graphite-app"* ]]
}

@test "Gate runtime: a Graphite out-of-quota notice is classified RATE_LIMITED (issue #1401)" {
  local json; json="$(cat "$(_events_dir)/advisory_graphite_rate_limited.json")"
  local tmpdir; tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [[ "$output" == *"RATE_LIMITED"* ]]
  [[ "$output" == *"graphite-app"* ]]
}

# ────────────────────────────────────────────────────────────────────
# CUBIC ADVISORY REVIEWER (issue #1903)
#
# cubic (app slug `cubic-dev-ai`, GraphQL login `cubic-dev-ai`) posts inline
# review comments plus a review summary. Registered on a 7-day trial started
# 2026-09-22. Its trial-ended notice must classify as RATE_LIMITED (a refusal),
# never as a real review or a finding.
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: cubic is a registered advisory bot (issue #1903)" {
  grep -q 'cubic-dev-ai' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: cubic is in the rate-limit notice superset (issue #1903)" {
  run bash -c "source '$SCRIPT_DIR/lib/advisory-review-gate.sh'
    printf '%s\n' \"\${RATE_LIMIT_NOTICE_BOTS[@]}\""
  [[ "$output" == *"cubic-dev-ai"* ]]
}

@test "Advisory gate: a cubic trial-ended phrase matches the author-scoped detector (issue #1903)" {
  # The cubic trial-ended notice must be caught by the author-scoped cubic pattern,
  # or a refusal would arm the gate but never trigger a sweep retry / scorecard
  # refusal count. A genuine cubic review must NOT match.
  run bash -c "source '$SCRIPT_DIR/lib/advisory-review-gate.sh'
    pat=\"\$(_advisory_cubic_rate_limit_pattern)\"
    printf '%s' 'cubic: your free trial ended. Upgrade to a paid plan.' | grep -qiE \"\$pat\" || { echo 'MISS-refusal'; exit 1; }
    printf '%s' 'cubic reviewed this PR and found 2 potential issues.' | grep -qiE \"\$pat\" && { echo 'FALSE-POSITIVE'; exit 1; }
    echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "Advisory gate: the cubic clause is author-scoped, NOT in the shared detector (issue #1903)" {
  # The cubic clause must live ONLY in the author-scoped pattern. If it were in the
  # shared, author-agnostic ADVISORY_RATE_LIMIT_RE, another reviewer merely
  # discussing cubic's trial would be misclassified RATE_LIMITED (#1903 codex P2).
  run bash -c "source '$SCRIPT_DIR/lib/advisory-review-gate.sh'
    gen=\"\$(_advisory_rate_limit_pattern)\"
    printf '%s' 'cubic: your free trial ended. Upgrade to a paid plan.' | grep -qiE \"\$gen\" && { echo 'LEAKED-INTO-GENERIC'; exit 1; }
    printf '%s' 'The cubic free trial ended handling is too broad.' | grep -qiE \"\$gen\" && { echo 'GENERIC-FALSE-POSITIVE'; exit 1; }
    echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "Advisory gate: the tightened cubic clause ignores generic subscription/plan/usage text (issue #1903)" {
  # cubic P3: the clause is scoped to the observed 'trial (ended|expired)' wording,
  # so a genuine cubic finding that opens with the 'cubic' prefix is not swept up.
  run bash -c "source '$SCRIPT_DIR/lib/advisory-review-gate.sh'
    pat=\"\$(_advisory_cubic_rate_limit_pattern)\"
    printf '%s' 'cubic: ensure the subscription limit is enforced.' | grep -qiE \"\$pat\" && { echo 'OVER-BROAD'; exit 1; }
    echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "Gate runtime: a cubic review is detected as an advisory bot submission (issue #1903)" {
  local json; json="$(cat "$(_events_dir)/advisory_cubic_reviewed.json")"
  local tmpdir; tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  # If cubic were unregistered it would be filtered out and never appear in output.
  [[ "$output" == *"cubic-dev-ai"* ]]
  # A COMMENTED review counts as reported, not RATE_LIMITED.
  [[ "$output" == *"COMMENTED"* ]]
}

@test "Gate runtime: a cubic trial-ended notice is classified RATE_LIMITED (issue #1903)" {
  local json; json="$(cat "$(_events_dir)/advisory_cubic_rate_limited.json")"
  local tmpdir; tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [[ "$output" == *"RATE_LIMITED"* ]]
  [[ "$output" == *"cubic-dev-ai"* ]]
}

@test "Gate runtime: another reviewer discussing cubic's trial is NOT RATE_LIMITED (author-scoped, issue #1903)" {
  # A different advisory reviewer's comment that merely mentions cubic's trial must
  # classify COMMENTED, not RATE_LIMITED — otherwise that reviewer would be dropped from
  # the required set on a real finding (#1903 codex P2). The cubic clause only applies to
  # cubic's own author. gemini-code-assist is used here because it remains in the
  # advisory-wait set post-#1997 (codex, the original subject, was dropped).
  local json='{"reviews":[],"comments":[{"author":{"login":"gemini-code-assist"},"createdAt":"2099-01-01T00:00:00Z","body":"The cubic free trial ended handling is too broad."}]}'
  local tmpdir; tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [[ "$output" == *"gemini-code-assist"* ]]
  [[ "$output" == *"COMMENTED"* ]]
  [[ "$output" != *"RATE_LIMITED"* ]]
}

# ────────────────────────────────────────────────────────────────────
# CHECK-RUN CLEAN PASSES (issue #2005)
#
# graphite-app reports a clean pass ONLY as its `Graphite / AI Reviews` check run
# (no PR review, no comment). The gate counts a completed+success check run whose
# name matches the registry's check_run_name column as a clean submission from that
# bot — for the current head SHA only — so a clean PR reaches quorum without waiting
# out the 1200s head-age timeout.
# ────────────────────────────────────────────────────────────────────

# The four non-check-run advisory bots, all submitted (far-future times keep the
# quiescence fallback disarmed so only the check run can complete the quorum).
_ADV_FOUR_REVIEWS='[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"sonarqubecloud"},"state":"COMMENTED","submittedAt":"2099-01-01T00:01:00Z"},{"author":{"login":"codeant-ai"},"state":"COMMENTED","submittedAt":"2099-01-01T00:02:00Z"},{"author":{"login":"cubic-dev-ai"},"state":"COMMENTED","submittedAt":"2099-01-01T00:03:00Z"}]'
_ADV_HEAD_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

# _make_mock_gh_dir_check_runs <check_runs_array_json> — recent head (inside the
# head-age window), the four reviews above at head _ADV_HEAD_SHA, and the given
# check runs served from the REST check-runs endpoint.
_make_mock_gh_dir_check_runs() {
  local runs="$1" tmpdir
  tmpdir=$(mktemp -d) || { echo "failed to create temp dir" >&2; exit 1; }
  printf '{"headRefOid":"%s","reviews":%s,"comments":[]}\n' "$_ADV_HEAD_SHA" "$_ADV_FOUR_REVIEWS" > "$tmpdir/pr.json"
  printf '{"total_count":0,"check_runs":%s}\n' "$runs" > "$tmpdir/runs.json"
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"reviews,comments"* ]]; then
  cat '$tmpdir/pr.json'
elif [[ "\$args" == *"check-runs"* ]]; then
  [[ "\$args" == *"repos/owner/repo/commits/${_ADV_HEAD_SHA}/check-runs"* ]] || exit 1
  cat '$tmpdir/runs.json'
elif [[ "\$args" == *"graphql"* ]]; then
  date -u '+%Y-%m-%dT%H:%M:%SZ'
fi
MOCK_EOF
  chmod +x "$tmpdir/gh"
  echo "$tmpdir"
}

_run_gate_with_check_runs() {
  local tmpdir; tmpdir=$(_make_mock_gh_dir_check_runs "$1")
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$SCRIPT_DIR/lib/advisory-review-gate.sh'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
}

_graphite_run() { # <status> <conclusion|null> [head_sha]
  local concl='null'; [ "$2" != "null" ] && concl="\"$2\""
  printf '[{"name":"Graphite / AI Reviews","head_sha":"%s","status":"%s","conclusion":%s,"completed_at":"2099-01-01T00:04:00Z"}]' \
    "${3:-$_ADV_HEAD_SHA}" "$1" "$concl"
}

@test "Gate runtime: a clean Graphite check run at head counts as its submission (issue #2005)" {
  _run_gate_with_check_runs "$(_graphite_run completed success)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"graphite-app → COMMENTED"* ]]
}

@test "Gate runtime: a failed Graphite check run is NOT counted as clean (issue #2005)" {
  _run_gate_with_check_runs "$(_graphite_run completed failure)"
  [ "$status" -eq 1 ]
  [[ "$output" != *"graphite-app"* ]]
}

@test "Gate runtime: a neutral Graphite check run is NOT counted as clean (issue #2005)" {
  _run_gate_with_check_runs "$(_graphite_run completed neutral)"
  [ "$status" -eq 1 ]
  [[ "$output" != *"graphite-app"* ]]
}

@test "Gate runtime: a pending Graphite check run is NOT counted yet (issue #2005)" {
  _run_gate_with_check_runs "$(_graphite_run in_progress null)"
  [ "$status" -eq 1 ]
  [[ "$output" != *"graphite-app"* ]]
}

@test "Gate runtime: a clean Graphite check run on a stale SHA is NOT counted (issue #2005)" {
  _run_gate_with_check_runs "$(_graphite_run completed success bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)"
  [ "$status" -eq 1 ]
  [[ "$output" != *"graphite-app"* ]]
}

@test "Gate runtime: a bot with check_run_name=- gains nothing from check runs (issue #2005)" {
  # gemini-code-assist carries check_run_name=- in the registry. Drop its review so
  # it is absent, then serve clean check runs named after it: none may credit it.
  # The Graphite run in the same response is still counted (the lookup works).
  local tmpdir; tmpdir=$(_make_mock_gh_dir_check_runs \
    "[{\"name\":\"gemini-code-assist\",\"head_sha\":\"$_ADV_HEAD_SHA\",\"status\":\"completed\",\"conclusion\":\"success\",\"completed_at\":\"2099-01-01T00:05:00Z\"},{\"name\":\"Gemini Code Assist\",\"head_sha\":\"$_ADV_HEAD_SHA\",\"status\":\"completed\",\"conclusion\":\"success\",\"completed_at\":\"2099-01-01T00:05:00Z\"},$(_graphite_run completed success | sed 's/^\[//; s/\]$//')]")
  jq -c '.reviews |= map(select(.author.login != "gemini-code-assist"))' "$tmpdir/pr.json" > "$tmpdir/pr2.json"
  mv "$tmpdir/pr2.json" "$tmpdir/pr.json"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$SCRIPT_DIR/lib/advisory-review-gate.sh'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
  [[ "$output" != *"gemini-code-assist"* ]]
  [[ "$output" == *"graphite-app → COMMENTED"* ]]
}

@test "Gate runtime: a failed check-run fetch degrades to reviews/comments only, never an API error (issue #2005)" {
  local tmpdir; tmpdir=$(_make_mock_gh_dir_check_runs "$(_graphite_run completed success)")
  sed -i 's|cat .*runs.json.*|exit 1|' "$tmpdir/gh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$SCRIPT_DIR/lib/advisory-review-gate.sh'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
  [[ "$output" != *"graphite-app"* ]]
}

@test "Advisory gate: no check-run name is hard-coded — the registry is the source (issue #2005)" {
  ! grep -q 'AI Reviews' "$SCRIPT_DIR/lib/advisory-review-gate.sh" || false
  grep -q 'reviewer_sources_check_run_reporters' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}
