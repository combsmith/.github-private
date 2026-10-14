#!/usr/bin/env bats
# Unit tests for scripts/delayed-rate-limit-retry.sh (issue #1994).
#
# When pr-review defers a PR on an un-elapsed rate-limit marker whose reset is
# near, the sweep ARMS a deterministic delayed retry by dispatching
# pr-review-delayed-retry.yml, which runs this script. The script sleeps until
# not_before, re-checks the marker still applies at the SAME head, then delegates
# back to the sweep (scoped to that one PR, ARM_DELAYED_RETRY=false so it cannot
# re-arm itself) to re-dispatch the review through the normal trigger — never
# force-review. A newer push (changed head SHA) supersedes the armed retry, which
# then no-ops.
#
# gh is mocked exactly as in test_sweep_stuck_reviews.bats: `gh pr view <url>`
# returns a per-PR fixture, `gh workflow run ...` is logged so we can assert on
# the dispatched command. The script delegates to the REAL sweep so these are
# genuine end-to-end checks of the retry path.
#
# Run with: bats tests/test_delayed_rate_limit_retry.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RETRY="$REPO_ROOT/scripts/delayed-rate-limit-retry.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/pr-review-delayed-retry.yml"

PAST_RESET='2000-01-01T00:00:00Z'

# A reset a few seconds out, so the script actually EXERCISES the wait path
# (sleep_secs > 0) rather than the "reset already elapsed" shortcut.
near_future_reset() {
  date -u -d '+2 seconds' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v+2S +%Y-%m-%dT%H:%M:%SZ
}

setup() {
  MOCK_BIN="$(mktemp -d)"
  FIXTURE_DIR="$(mktemp -d)"
  GH_LOG="$(mktemp)"
  export MOCK_BIN FIXTURE_DIR GH_LOG
  export PATH="$MOCK_BIN:$PATH"
  export AGENT_REPO="petry-projects/.github-private"

  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  pr)
    if [ "$2" = "view" ]; then
      url="$3"
      num="${url##*/}"
      f="$FIXTURE_DIR/pr_${num}.json"
      if [ -f "$f" ]; then cat "$f"; exit 0; fi
      echo "no fixture for $url" >&2
      exit 1
    fi
    ;;
  workflow)
    printf '%s\n' "$*" >> "$GH_LOG"
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$MOCK_BIN/gh"
}

teardown() {
  rm -rf "${MOCK_BIN:-}" "${FIXTURE_DIR:-}"
  rm -f "${GH_LOG:-}"
}

# write_pr <num> <reviewDecision> <rollup-json> [head] [reviews-json] [comments-json] [labels-json] [state]
write_pr() {
  local num="$1" decision="$2" rollup="$3" head="${4-deadbeef}" reviews="${5:-[]}" comments="${6:-[]}" labels="${7:-[]}" state="${8:-OPEN}"
  jq -n --arg d "$decision" --argjson r "$rollup" --arg h "$head" \
        --argjson rv "$reviews" --argjson cm "$comments" --argjson lb "$labels" --arg s "$state" \
    '{headRefOid:$h, state:$s, reviewDecision:$d, statusCheckRollup:$r, reviews:$rv, comments:$cm, labels:($lb | map({name:.}))}' \
    > "$FIXTURE_DIR/pr_${num}.json"
}

ROLLUP_PASS='[{"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]'

# rl_comment <head> <reset-iso>: a rate-limited withhold marker comment body array.
rl_comment() {
  printf '[{"body":"<!-- pr-review-agent rate-limited v1 sha=%s status=rate-limited reset=%s -->\\n\\nAdvisory bots were rate-limited."}]' "$1" "$2"
}

url_for() { echo "https://github.com/petry-projects/demo/pull/$1"; }

# ---------------------------------------------------------------------------
# Supersession: a newer push (changed head SHA) makes the armed retry a no-op.
# ---------------------------------------------------------------------------
@test "retry no-ops when the head SHA has advanced (newer push supersedes)" {
  write_pr 2001 "REVIEW_REQUIRED" "$ROLLUP_PASS" "newhead01" "[]" "$(rl_comment armedold01 "$PAST_RESET")"
  export PR_URL; PR_URL="$(url_for 2001)"
  export HEAD_SHA="armedold01" NOT_BEFORE="$PAST_RESET"

  run bash "$RETRY"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
  [[ "$output" == *"superseded"* || "$output" == *"no-op"* ]]
}

# ---------------------------------------------------------------------------
# Happy path: marker still applies at head → delegate to the sweep, which
# re-dispatches the review through the normal trigger (never force).
# ---------------------------------------------------------------------------
@test "retry re-dispatches via the sweep when the marker still applies at head" {
  write_pr 2002 "REVIEW_REQUIRED" "$ROLLUP_PASS" "armed02" "[]" "$(rl_comment armed02 "$PAST_RESET")"
  export PR_URL; PR_URL="$(url_for 2002)"
  export HEAD_SHA="armed02" NOT_BEFORE="$PAST_RESET"

  run bash "$RETRY"
  [ "$status" -eq 0 ]
  grep -qF -- "workflow run pr-review-trigger.yml" "$GH_LOG"
  grep -qF -- "-f pr_url=$(url_for 2002)" "$GH_LOG"
  ! grep -qF -- "force_review" "$GH_LOG"
  # Must not re-arm itself (no recursive delayed-retry dispatch).
  ! grep -qF -- "pr-review-delayed-retry.yml" "$GH_LOG"
}

# ---------------------------------------------------------------------------
# Wait path: a near-FUTURE reset must make the script actually sleep until
# reset+buffer and THEN fire via the sweep — the core behaviour of this PR. The
# past-reset cases above only hit the "reset already elapsed" shortcut, so the
# sleep computation would never be exercised without this case.
# ---------------------------------------------------------------------------
@test "retry waits for a near-future reset, then re-dispatches via the sweep" {
  local reset; reset="$(near_future_reset)"
  write_pr 2005 "REVIEW_REQUIRED" "$ROLLUP_PASS" "armed05" "[]" "$(rl_comment armed05 "$reset")"
  export PR_URL; PR_URL="$(url_for 2005)"
  export HEAD_SHA="armed05" NOT_BEFORE="$reset" DELAYED_RETRY_BUFFER_SEC=0

  run bash "$RETRY"
  [ "$status" -eq 0 ]
  # It must have taken the WAIT path (sleep_secs > 0), not the elapsed shortcut.
  [[ "$output" == *"until reset+buffer"* ]]
  # And after waking it still re-dispatches the review through the normal trigger.
  grep -qF -- "workflow run pr-review-trigger.yml" "$GH_LOG"
  grep -qF -- "-f pr_url=$(url_for 2005)" "$GH_LOG"
  ! grep -qF -- "pr-review-delayed-retry.yml" "$GH_LOG"
}

# ---------------------------------------------------------------------------
# Already resolved: a standing verdict at head means the retry must not fire.
# ---------------------------------------------------------------------------
@test "retry no-ops when the head already has a standing verdict" {
  local comments
  comments='[{"body":"<!-- pr-review-agent rate-limited v1 sha=armed03 status=rate-limited reset='"$PAST_RESET"' -->"},{"body":"<!-- pr-review-agent v1 sha=armed03 --> <!-- decision=fix-requested risk=low -->"}]'
  write_pr 2003 "REVIEW_REQUIRED" "$ROLLUP_PASS" "armed03" "[]" "$comments"
  export PR_URL; PR_URL="$(url_for 2003)"
  export HEAD_SHA="armed03" NOT_BEFORE="$PAST_RESET"

  run bash "$RETRY"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

# ---------------------------------------------------------------------------
# DRY_RUN passes through to the delegated sweep: it logs intent, dispatches
# nothing.
# ---------------------------------------------------------------------------
@test "retry honours DRY_RUN (delegates but dispatches nothing)" {
  write_pr 2004 "REVIEW_REQUIRED" "$ROLLUP_PASS" "armed04" "[]" "$(rl_comment armed04 "$PAST_RESET")"
  export PR_URL; PR_URL="$(url_for 2004)"
  export HEAD_SHA="armed04" NOT_BEFORE="$PAST_RESET" DRY_RUN=true

  run bash "$RETRY"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

# ---------------------------------------------------------------------------
# A PR that cannot be fetched (deleted / no access) is a safe no-op, never an
# error that strands the run.
# ---------------------------------------------------------------------------
@test "retry no-ops safely when the PR cannot be fetched" {
  export PR_URL; PR_URL="$(url_for 2099)"
  export HEAD_SHA="whatever" NOT_BEFORE="$PAST_RESET"

  run bash "$RETRY"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

# ---------------------------------------------------------------------------
# A merged or closed PR makes the armed retry a no-op, even at the armed head.
# ---------------------------------------------------------------------------
@test "retry no-ops when the PR was merged" {
  write_pr 2010 "APPROVED" "$ROLLUP_PASS" "armed10" "[]" "$(rl_comment armed10 "$PAST_RESET")" "[]" "MERGED"
  export PR_URL; PR_URL="$(url_for 2010)"
  export HEAD_SHA="armed10" NOT_BEFORE="$PAST_RESET"

  run bash "$RETRY"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
  [[ "$output" == *"PR is MERGED"* ]]
}

@test "retry no-ops when the PR was closed" {
  write_pr 2011 "REVIEW_REQUIRED" "$ROLLUP_PASS" "armed11" "[]" "$(rl_comment armed11 "$PAST_RESET")" "[]" "CLOSED"
  export PR_URL; PR_URL="$(url_for 2011)"
  export HEAD_SHA="armed11" NOT_BEFORE="$PAST_RESET"

  run bash "$RETRY"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
  [[ "$output" == *"PR is CLOSED"* ]]
}

# ---------------------------------------------------------------------------
# The armed head's rate-limit marker must still exist at wake time. Without it
# the delegated sweep would launch an ordinary review for a green
# REVIEW_REQUIRED PR, so the stale retry must no-op instead.
# ---------------------------------------------------------------------------
@test "retry no-ops when the rate-limit marker for the armed head is gone" {
  write_pr 2012 "REVIEW_REQUIRED" "$ROLLUP_PASS" "armed12" "[]" "[]"
  export PR_URL; PR_URL="$(url_for 2012)"
  export HEAD_SHA="armed12" NOT_BEFORE="$PAST_RESET"

  run bash "$RETRY"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
  [[ "$output" == *"no rate-limit marker for head"* ]]
}

@test "retry no-ops when the only marker is for a different head" {
  write_pr 2013 "REVIEW_REQUIRED" "$ROLLUP_PASS" "armed13" "[]" "$(rl_comment otherhead13 "$PAST_RESET")"
  export PR_URL; PR_URL="$(url_for 2013)"
  export HEAD_SHA="armed13" NOT_BEFORE="$PAST_RESET"

  run bash "$RETRY"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

# ---------------------------------------------------------------------------
# The sleep ceiling is derived from horizon + buffer; an explicit lower value is
# raised to that floor so the retry never wakes before reset+buffer.
# ---------------------------------------------------------------------------
@test "a max-sleep below horizon+buffer is raised to the floor with a warning" {
  write_pr 2014 "REVIEW_REQUIRED" "$ROLLUP_PASS" "armed14" "[]" "$(rl_comment armed14 "$PAST_RESET")"
  export PR_URL; PR_URL="$(url_for 2014)"
  export HEAD_SHA="armed14" NOT_BEFORE="$PAST_RESET" \
    DELAYED_RETRY_HORIZON_SEC=7200 DELAYED_RETRY_BUFFER_SEC=60 DELAYED_RETRY_MAX_SLEEP_SEC=100

  run bash "$RETRY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"below horizon+buffer (7260s)"* ]]
}

# The sweep reads rate-limit markers from reviews AND comments, so the wake-time
# check must too, or a marker posted in a review body strands the retry.
@test "retry re-dispatches when the armed head's marker is in a REVIEW body" {
  write_pr 2015 "REVIEW_REQUIRED" "$ROLLUP_PASS" "armed15" "$(rl_comment armed15 "$PAST_RESET")" "[]"
  export PR_URL; PR_URL="$(url_for 2015)"
  export HEAD_SHA="armed15" NOT_BEFORE="$PAST_RESET"

  run bash "$RETRY"
  [ "$status" -eq 0 ]
  [[ "$output" != *"no rate-limit marker for head"* ]]
  grep -qF -- "workflow run pr-review-trigger.yml" "$GH_LOG"
  grep -qF -- "-f pr_url=$(url_for 2015)" "$GH_LOG"
}

# Leading-zero durations are base 10, not octal (0600 must mean 600, not 384).
@test "leading-zero horizon/buffer values are parsed as base 10" {
  write_pr 2016 "REVIEW_REQUIRED" "$ROLLUP_PASS" "armed16" "[]" "$(rl_comment armed16 "$PAST_RESET")"
  export PR_URL; PR_URL="$(url_for 2016)"
  export HEAD_SHA="armed16" NOT_BEFORE="$PAST_RESET" \
    DELAYED_RETRY_HORIZON_SEC=0600 DELAYED_RETRY_BUFFER_SEC=060 DELAYED_RETRY_MAX_SLEEP_SEC=0100

  run bash "$RETRY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"below horizon+buffer (660s)"* ]]
}

# ---------------------------------------------------------------------------
# Concurrency (AC2): the retry workflow groups per PR + head SHA so two retries
# for different PRs land in different concurrency lanes and never cancel each
# other (nor the sweep, whose group name is unrelated).
# ---------------------------------------------------------------------------
@test "delayed-retry workflow groups per-PR+head so retries never cancel each other" {
  [ -f "$WORKFLOW" ]
  # The concurrency group must key on BOTH pr_url (different PRs → different lanes,
  # so retries never cancel each other, nor the unrelated sweep group) and head_sha
  # (a newer push gets its own lane).
  run grep -E '^[[:space:]]*group:' "$WORKFLOW"
  [ "$status" -eq 0 ]
  [[ "$output" == *"inputs.pr_url"* ]]
  [[ "$output" == *"inputs.head_sha"* ]]
}
