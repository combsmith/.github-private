#!/usr/bin/env bats
# Tests for scripts/reviewer_report.sh — pure normalization, aggregation, and
# Markdown rendering for the Third-Party Reviewer Scorecard. Network I/O
# (collect_org_reviews / _fetch_prev_snapshot / main) is NOT exercised here.
# Run locally: bats tests/reviewer_report.bats

FIXTURES="${BATS_TEST_DIRNAME}/fixtures/reviewer_jsonl"
PR_NODE="${BATS_TEST_DIRNAME}/fixtures/reviewer_pr_node.json"

setup() {
  # shellcheck source=scripts/reviewer_report.sh
  source "${BATS_TEST_DIRNAME}/../scripts/reviewer_report.sh"
  BOTS='["gemini-code-assist","copilot-pull-request-reviewer","sonarqubecloud","chatgpt-codex-connector","coderabbitai"]'
}

# ---------------------------------------------------------------------------
# Registry wiring — bots come from the shared advisory-review-gate list
# ---------------------------------------------------------------------------

@test "REVIEWER_BOTS: nine tracked reviewers, sourced from the gate registry" {
  [ "${#REVIEWER_BOTS[@]}" -eq 9 ]
  [[ " ${REVIEWER_BOTS[*]} " == *" coderabbitai "* ]]
  [[ " ${REVIEWER_BOTS[*]} " == *" copilot-pull-request-reviewer "* ]]
  # Qodo Merge + CodeAnt registered via the shared gate registry (issue #1349).
  [[ " ${REVIEWER_BOTS[*]} " == *" qodo-code-review "* ]]
  [[ " ${REVIEWER_BOTS[*]} " == *" codeant-ai "* ]]
  # Graphite registered via advisory-review-gate (issue #1401).
  [[ " ${REVIEWER_BOTS[*]} " == *" graphite-app "* ]]
  # cubic registered via the shared gate registry (issue #1903).
  [[ " ${REVIEWER_BOTS[*]} " == *" cubic-dev-ai "* ]]
}

@test "REVIEWER_LABELS: Qodo Merge + CodeAnt have display names (issue #1349)" {
  [ "${REVIEWER_LABELS[qodo-code-review]}" = "Qodo Merge" ]
  [ "${REVIEWER_LABELS[codeant-ai]}" = "CodeAnt" ]
}

@test "REVIEWER_LABELS: cubic has display name (issue #1903)" {
  [ "${REVIEWER_LABELS[cubic-dev-ai]}" = "cubic" ]
}

@test "normalize: a cubic review normalizes into a bot_pr record (issue #1903)" {
  local newbots='["cubic-dev-ai"]'
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/tmp.XXXXXX")" || { echo "Failed to create temp file" >&2; exit 1; }
  cat > "$tmp" <<'JSON'
{"url":"u","createdAt":"2026-07-10T10:00:00Z","updatedAt":"2026-07-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[{"author":{"login":"cubic-dev-ai"},"state":"COMMENTED","submittedAt":"2026-07-10T10:05:00Z","bodyText":"cubic reviewed this PR and found 1 potential issue."}]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[]}}
JSON
  run jq -c --arg repo "r" --argjson bots "$newbots" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$tmp"
  echo "$output" | jq -e '.[] | select(.kind=="bot_pr" and .bot=="cubic-dev-ai") | .real_responses>=1 and .reviews==1'
}

@test "normalize: a cubic trial-ended notice is a refusal, not a review (issue #1903)" {
  local newbots='["cubic-dev-ai"]'
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/tmp.XXXXXX")" || { echo "Failed to create temp file" >&2; exit 1; }
  cat > "$tmp" <<'JSON'
{"url":"u","createdAt":"2026-07-10T10:00:00Z","updatedAt":"2026-07-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[{"author":{"login":"cubic-dev-ai"},"createdAt":"2026-07-10T10:01:00Z","bodyText":"cubic: your free trial ended. Upgrade to a paid plan to resume reviews."}]}}
JSON
  run jq -c --arg repo "r" --argjson bots "$newbots" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$tmp"
  # The trial-ended notice is cubic's SOLE action → a refusal, not a review.
  echo "$output" | jq -e '.[] | select(.kind=="bot_pr" and .bot=="cubic-dev-ai") | .real_responses==0 and .refusals>=1'
}

@test "normalize: another reviewer discussing cubic's trial is NOT a refusal (author-scoped, issue #1903)" {
  # The cubic clause is author-scoped: a genuine finding by a DIFFERENT tracked bot
  # that merely mentions cubic's trial must count as a real response, not a refusal,
  # or that reviewer would be dropped from the gate and miscounted (#1903 codex P2).
  local newbots='["cubic-dev-ai","chatgpt-codex-connector"]'
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/tmp.XXXXXX")" || { echo "Failed to create temp file" >&2; exit 1; }
  cat > "$tmp" <<'JSON'
{"url":"u","createdAt":"2026-07-10T10:00:00Z","updatedAt":"2026-07-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"createdAt":"2026-07-10T10:01:00Z","bodyText":"The cubic free trial ended handling is too broad."}]}}
JSON
  run jq -c --arg repo "r" --argjson bots "$newbots" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$tmp"
  # Not refused. (#2504: a comment that matches no pattern is `unclassified`, which no
  # longer counts as a review either — it only must not be read as a refusal.)
  echo "$output" | jq -e '.[] | select(.kind=="bot_pr" and .bot=="chatgpt-codex-connector") | .refusals==0 and .classes.refused==0'
}

@test "REVIEWER_LABELS: Graphite has display name (issue #1401)" {
  [ "${REVIEWER_LABELS[graphite-app]}" = "Graphite" ]
}

@test "REVIEWER_LABELS: every tracked reviewer has a display name (no drift, issue #1349)" {
  # The report list is derived from the gate list; each tracked login must carry a
  # human-facing label so no reviewer renders as a bare GraphQL login.
  for bot in "${REVIEWER_BOTS[@]}"; do
    [ -n "${REVIEWER_LABELS[$bot]:-}" ] || { echo "missing label for $bot"; return 1; }
  done
}

# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

@test "_fmt_int: thousands separators" {
  run _fmt_int 12345
  [ "$output" = "12,345" ]
}

@test "_fmt_pct: rounds, n/a on zero denominator" {
  run _fmt_pct 1 2; [ "$output" = "50%" ]
  run _fmt_pct 5 0; [ "$output" = "n/a" ]
}

@test "_fmt_dur: seconds / minutes / hours / days and em-dash on empty" {
  run _fmt_dur 45;     [ "$output" = "45s" ]
  run _fmt_dur 186;    [ "$output" = "3m" ]
  run _fmt_dur 12240;  [ "$output" = "3.4h" ]
  run _fmt_dur "";     [ "$output" = "—" ]
  run _fmt_dur -1;     [ "$output" = "—" ]
}

@test "_delta_arrow: up / down / flat / blank when no prior" {
  run _delta_arrow 5 3; [ "$output" = "(▲ +2)" ]
  run _delta_arrow 2 5; [ "$output" = "(▼ -3)" ]
  run _delta_arrow 4 4; [ "$output" = "(±0)" ]
  run _delta_arrow 4 ""; [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# _NORMALIZE_JQ — one GraphQL PR node → normalized records
# ---------------------------------------------------------------------------

@test "normalize: emits one pr record and one bot_pr per participating bot; humans excluded" {
  run jq -c --arg repo "combsmith/markets" --argjson bots "$BOTS" \
    --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$PR_NODE"
  # 1 pr record + 4 bot records (copilot, gemini, coderabbit, codex — NOT human alice, NOT sonar)
  echo "$output" | jq -e 'map(select(.kind=="pr")) | length == 1'
  echo "$output" | jq -e 'map(select(.kind=="bot_pr")) | length == 4'
  echo "$output" | jq -e 'any(.[]; .bot == "alice") | not'
}

@test "normalize: latency is bot-first-touch minus PR creation" {
  run jq -c --arg repo "r" --argjson bots "$BOTS" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$PR_NODE"
  # copilot first submission 10:03:06 vs created 10:00:00 = 186s
  echo "$output" | jq -e '.[] | select(.bot=="copilot-pull-request-reviewer") | .latency_s == 186'
  # gemini 10:00:50 = 50s
  echo "$output" | jq -e '.[] | select(.bot=="gemini-code-assist") | .latency_s == 50'
}

@test "normalize: a rate-limit-only bot is a refusal (real_responses=0, refusals>=1)" {
  run jq -c --arg repo "r" --argjson bots "$BOTS" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$PR_NODE"
  echo "$output" | jq -e '.[] | select(.bot=="coderabbitai") | .real_responses==0 and .refusals>=1'
  echo "$output" | jq -e '.[] | select(.bot=="chatgpt-codex-connector") | .real_responses==0 and .refusals>=1'
}

@test "normalize: a real review alongside a rate-limit comment still counts as reviewed" {
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/tmp.XXXXXX")" || { echo "Failed to create temp file" >&2; exit 1; }
  cat > "$tmp" <<'JSON'
{"url":"u","createdAt":"2026-07-10T10:00:00Z","updatedAt":"2026-07-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[{"author":{"login":"coderabbitai"},"state":"CHANGES_REQUESTED","submittedAt":"2026-07-10T10:05:00Z","bodyText":"real review: please fix X"}]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[{"author":{"login":"coderabbitai"},"createdAt":"2026-07-10T10:01:00Z","bodyText":"Review limit reached — out of credits"}]}}
JSON
  run jq -c --arg repo "r" --argjson bots "$BOTS" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$tmp"
  # The real CHANGES_REQUESTED review wins over the rate-limit comment.
  echo "$output" | jq -e '.[] | select(.bot=="coderabbitai") | .real_responses>=1 and .refusals==1 and .reviews==1 and .changes_req==1'
}

@test "normalize: reactions and thread resolution captured on inline comments" {
  run jq -c --arg repo "r" --argjson bots "$BOTS" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$PR_NODE"
  echo "$output" | jq -e '.[] | select(.bot=="copilot-pull-request-reviewer") | .thumbs_up==2 and .thumbs_down==1 and .threads_resolved==1'
}

@test "normalize: Qodo real review counts as reviewed; CodeAnt quota notice is a refusal (issue #1349)" {
  local newbots='["qodo-code-review","codeant-ai"]'
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/tmp.XXXXXX")" || { echo "Failed to create temp file" >&2; exit 1; }
  cat > "$tmp" <<'JSON'
{"url":"u","createdAt":"2026-07-10T10:00:00Z","updatedAt":"2026-07-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[{"author":{"login":"qodo-code-review"},"state":"CHANGES_REQUESTED","submittedAt":"2026-07-10T10:05:00Z","bodyText":"Code Review by Qodo: please fix the null deref on line 42."}]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[{"author":{"login":"codeant-ai"},"createdAt":"2026-07-10T10:01:00Z","bodyText":"CodeAnt AI: your free trial limit reached — reviews are paused."}]}}
JSON
  run jq -c --arg repo "r" --argjson bots "$newbots" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$tmp"
  echo "$output" | jq -e '.[] | select(.bot=="qodo-code-review") | .real_responses>=1 and .reviews==1 and .changes_req==1'
  echo "$output" | jq -e '.[] | select(.bot=="codeant-ai") | .real_responses==0 and .refusals>=1'
}

@test "reviews: a comment-only responder (SonarCloud) has its comment counted as a review" {
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/tmp.XXXXXX")" || { echo "Failed to create temp file" >&2; exit 1; }
  cat > "$tmp" <<'JSON'
{"url":"u","createdAt":"2026-07-10T10:00:00Z","updatedAt":"2026-07-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[{"author":{"login":"sonarqubecloud"},"createdAt":"2026-07-10T10:02:00Z","bodyText":"Quality Gate passed"}]}}
JSON
  run jq -c --arg repo "r" --argjson bots "$BOTS" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$tmp"
  echo "$output" | jq -e '.[] | select(.bot=="sonarqubecloud") | .reviews==1 and .real_responses==1'
}

@test "reviews: a bot with a formal review does NOT also count its summary comment (no double-count)" {
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/tmp.XXXXXX")" || { echo "Failed to create temp file" >&2; exit 1; }
  cat > "$tmp" <<'JSON'
{"url":"u","createdAt":"2026-07-10T10:00:00Z","updatedAt":"2026-07-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[{"author":{"login":"coderabbitai"},"state":"COMMENTED","submittedAt":"2026-07-10T10:05:00Z","bodyText":"formal review"}]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[{"author":{"login":"coderabbitai"},"createdAt":"2026-07-10T10:01:00Z","bodyText":"Walkthrough summary comment"}]}}
JSON
  run jq -c --arg repo "r" --argjson bots "$BOTS" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$tmp"
  # 1 formal review only — the summary issue comment is not counted as a second review.
  echo "$output" | jq -e '.[] | select(.bot=="coderabbitai") | .reviews==1'
}

# ---------------------------------------------------------------------------
# Check-run reviews (issue #1908) — Graphite reports clean passes as a check run
# ---------------------------------------------------------------------------

@test "check-run: a clean pass (check run only, no PR review) counts as reviewed" {
  local gbots='["graphite-app","copilot-pull-request-reviewer"]'
  tmp="$(mktemp "$BATS_TEST_TMPDIR/tmp.XXXXXX")"
  cat > "$tmp" <<'JSON'
{"url":"u","createdAt":"2026-09-23T10:00:00Z","updatedAt":"2026-09-23T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[]},
 "_checkRuns":[{"bot":"graphite-app","status":"completed","conclusion":"success","summary":"AI review ran and left 0 comments","completed_at":"2026-09-23T10:05:00Z"}]}
JSON
  run jq -c --arg repo "r" --argjson bots "$gbots" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$tmp"
  # Reviewed: real_responses>=1, zero refusals, and (per AC1) 0 review events.
  echo "$output" | jq -e '.[] | select(.bot=="graphite-app") | .real_responses>=1 and .refusals==0 and .reviews==0'
  # Latency measured to the check run's completed_at (10:05:00 − 10:00:00 = 300s).
  echo "$output" | jq -e '.[] | select(.bot=="graphite-app") | .latency_s==300'
}

@test "check-run: a 'too large' skip counts as a refusal, not a review" {
  local gbots='["graphite-app"]'
  tmp="$(mktemp "$BATS_TEST_TMPDIR/tmp.XXXXXX")"
  cat > "$tmp" <<'JSON'
{"url":"u","createdAt":"2026-09-23T10:00:00Z","updatedAt":"2026-09-23T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[]},
 "_checkRuns":[{"bot":"graphite-app","status":"completed","conclusion":"skipped","summary":"AI code review did not run because this PR is too large.","completed_at":"2026-09-23T10:04:00Z"}]}
JSON
  run jq -c --arg repo "r" --argjson bots "$gbots" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$tmp"
  echo "$output" | jq -e '.[] | select(.bot=="graphite-app") | .real_responses==0 and .refusals>=1 and .reviews==0'
}

@test "check-run: a FAILED run whose summary says 'review ran' is NOT a real review (#1913)" {
  # Regression: the "review ran" summary substring must be gated on a non-failure
  # conclusion, else "AI review ran into an error and did not complete" on a `failure`
  # run would be misread as a real response (real_responses:1).
  local gbots='["graphite-app"]'
  tmp="$(mktemp "$BATS_TEST_TMPDIR/tmp.XXXXXX")"
  cat > "$tmp" <<'JSON'
{"url":"u","createdAt":"2026-09-23T10:00:00Z","updatedAt":"2026-09-23T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[]},
 "_checkRuns":[{"bot":"graphite-app","status":"completed","conclusion":"failure","summary":"AI review ran into an error and did not complete.","completed_at":"2026-09-23T10:04:00Z"}]}
JSON
  run jq -c --arg repo "r" --argjson bots "$gbots" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$tmp"
  # A failed run is neither a real response nor a refusal. #2504 gives every completed
  # check run a class: a failed one is `status`, which buckets as No response.
  echo "$output" | jq -e '.[] | select(.kind=="bot_pr" and .bot=="graphite-app") | .real_responses==0 and .refusals==0 and .classes.status==1'
}

@test "check-run: a skip with an unrelated/empty summary is NOT a refusal" {
  # A run skipped for an unrelated workflow reason (no decline summary) must not be
  # counted as a rate-limited refusal — it contributes nothing, like a queued run.
  local gbots='["graphite-app"]'
  tmp="$(mktemp "$BATS_TEST_TMPDIR/tmp.XXXXXX")"
  cat > "$tmp" <<'JSON'
{"url":"u","createdAt":"2026-09-23T10:00:00Z","updatedAt":"2026-09-23T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[]},
 "_checkRuns":[{"bot":"graphite-app","status":"completed","conclusion":"skipped","summary":"","completed_at":"2026-09-23T10:04:00Z"}]}
JSON
  run jq -c --arg repo "r" --argjson bots "$gbots" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$tmp"
  # Not a refusal: an empty-summary skip is `status` (#2504), so it buckets as no-response.
  echo "$output" | jq -e '.[] | select(.kind=="bot_pr" and .bot=="graphite-app") | .real_responses==0 and .refusals==0 and .classes.status==1'
}

@test "check-run: a queued suite (no completed check run, no review) is no response" {
  local gbots='["graphite-app"]'
  tmp="$(mktemp "$BATS_TEST_TMPDIR/tmp.XXXXXX")"
  cat > "$tmp" <<'JSON'
{"url":"u","createdAt":"2026-09-23T10:00:00Z","updatedAt":"2026-09-23T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[]},
 "_checkRuns":[{"bot":"graphite-app","status":"queued","conclusion":null,"summary":null,"completed_at":null}]}
JSON
  run jq -c --arg repo "r" --argjson bots "$gbots" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$tmp"
  # No bot_pr record at all → the aggregator buckets it as no-response.
  echo "$output" | jq -e 'map(select(.kind=="bot_pr" and .bot=="graphite-app")) | length == 0'
}

@test "check-run: an inline review AND a clean check run — review events unaffected" {
  local gbots='["graphite-app"]'
  tmp="$(mktemp "$BATS_TEST_TMPDIR/tmp.XXXXXX")"
  cat > "$tmp" <<'JSON'
{"url":"u","createdAt":"2026-09-23T10:00:00Z","updatedAt":"2026-09-23T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[{"author":{"login":"graphite-app"},"state":"COMMENTED","submittedAt":"2026-09-23T10:06:00Z","bodyText":"one finding"}]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[]},
 "_checkRuns":[{"bot":"graphite-app","status":"completed","conclusion":"success","summary":"AI review ran and left 1 comment","completed_at":"2026-09-23T10:05:00Z"}]}
JSON
  run jq -c --arg repo "r" --argjson bots "$gbots" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$tmp"
  # The real PR review is the 1 review event; the check run adds 0 more.
  echo "$output" | jq -e '.[] | select(.bot=="graphite-app") | .reviews==1'
}

@test "check-run: collector returns the matched runs when REVIEWER_CHECK_RUN_JSON is set (#1913)" {
  # Regression: "${REVIEWER_CHECK_RUN_JSON:-{}}" ends the expansion at the FIRST
  # brace and appends a literal "}", so a SET map became invalid JSON, the jq
  # --argjson failed, and every PR's check runs were silently dropped. The
  # normalizer tests above inject _checkRuns directly and never exercised this.
  export CUTOFF="2026-09-16T00:00:00Z"
  export REVIEWER_CHECK_RUN_JSON='{"graphite-app":"Graphite / AI Reviews"}'
  _gh_timeout() {
    printf '%s' '{"total_count":2,"check_runs":[{"name":"CI","status":"completed","conclusion":"success","output":{"summary":"ok"},"completed_at":"2026-09-23T10:01:00Z"},{"name":"Graphite / AI Reviews","status":"completed","conclusion":"success","output":{"summary":"AI review ran and left 0 comments"},"completed_at":"2026-09-23T10:05:00Z"}]}'
  }
  local resp='{"data":{"repository":{"pullRequests":{"nodes":[{"url":"https://github.com/o/r/pull/1","updatedAt":"2026-09-23T10:00:00Z","headRefOid":"abc123"}]}}}}'
  run _collect_check_runs_for_page o r "$resp"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.["https://github.com/o/r/pull/1"] | length == 1'
  echo "$output" | jq -e '.["https://github.com/o/r/pull/1"][0] | .bot == "graphite-app" and .conclusion == "success" and .completed_at == "2026-09-23T10:05:00Z"'
}

@test "check-run: collector short-circuits to {} when REVIEWER_CHECK_RUN_JSON is unset (#1913)" {
  unset REVIEWER_CHECK_RUN_JSON
  _gh_timeout() { : > "$BATS_TEST_TMPDIR/gh_called"; return 1; }
  local resp='{"data":{"repository":{"pullRequests":{"nodes":[{"url":"u","updatedAt":"2099-01-01T00:00:00Z","headRefOid":"abc"}]}}}}'
  run _collect_check_runs_for_page o r "$resp"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
  [ ! -e "$BATS_TEST_TMPDIR/gh_called" ]
}

@test "check-run: collector records check_run_error when the REST fetch errors non-zero (#1913)" {
  # An HTTP error (403 rate limit, 5xx) makes gh write an error body to stdout AND
  # exit non-zero. Relying on empty output alone would miss it (cr_resp holds the
  # non-empty error object), silently dropping the PR — the #1908 silent failure.
  export CUTOFF="2026-09-16T00:00:00Z"
  export REVIEWER_CHECK_RUN_JSON='{"graphite-app":"Graphite / AI Reviews"}'
  _gh_timeout() { printf '%s' '{"message":"API rate limit exceeded"}'; return 1; }
  local resp='{"data":{"repository":{"pullRequests":{"nodes":[{"url":"https://github.com/o/r/pull/1","updatedAt":"2026-09-23T10:00:00Z","headRefOid":"abc123"}]}}}}'
  local out; out="$(mktemp "$BATS_TEST_TMPDIR/out.XXXXXX")"
  run _collect_check_runs_for_page o r "$resp" "$out"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
  jq -e 'select(.kind=="check_run_error" and .pr=="https://github.com/o/r/pull/1")' "$out"
}

@test "reviews: a PR with more than 50 reviews still counts a bot whose review is past the 50th" {
  # The GraphQL 50-cap is a COLLECTION concern; normalization must count whatever
  # nodes it is handed. Feed 51 reviews with the tracked bot last (issue #1908 AC5).
  local latebots='["graphite-app"]'
  tmp="$(mktemp "$BATS_TEST_TMPDIR/tmp.XXXXXX")"
  {
    printf '{"url":"u","createdAt":"2026-09-23T10:00:00Z","updatedAt":"2026-09-23T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},'
    printf '"reviews":{"nodes":['
    for i in $(seq 1 50); do
      printf '{"author":{"login":"human%d"},"state":"COMMENTED","submittedAt":"2026-09-23T10:0%d:00Z","bodyText":"x"},' "$i" $((i % 9))
    done
    printf '{"author":{"login":"graphite-app"},"state":"CHANGES_REQUESTED","submittedAt":"2026-09-23T10:59:00Z","bodyText":"51st review"}'
    printf ']},"reviewThreads":{"nodes":[]},"comments":{"nodes":[]}}'
  } > "$tmp"
  run jq -c --arg repo "r" --argjson bots "$latebots" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$tmp"
  echo "$output" | jq -e '.[] | select(.bot=="graphite-app") | .reviews==1 and .changes_req==1'
}

# ---------------------------------------------------------------------------
# aggregate_snapshot
# ---------------------------------------------------------------------------

@test "aggregate: counts eligible (non-draft) vs total PRs" {
  run aggregate_snapshot "$FIXTURES"
  echo "$output" | jq -e '.total_prs == 3 and .eligible_prs == 2'
}

@test "aggregate: per-bot rollups sum across repos" {
  run aggregate_snapshot "$FIXTURES"
  # copilot gave a real review on both PRs (markets#42 + broodly#7)
  echo "$output" | jq -e '.bots["copilot-pull-request-reviewer"].reviewed_prs == 2'
  echo "$output" | jq -e '.bots["copilot-pull-request-reviewer"].changes_req == 1'
  echo "$output" | jq -e '.bots["copilot-pull-request-reviewer"].threads_resolved == 2'
}

@test "aggregate: Codex/CodeRabbit refused (rate-limited only) on markets#42, absent on broodly#7" {
  run aggregate_snapshot "$FIXTURES"
  echo "$output" | jq -e '.bots["chatgpt-codex-connector"] | .reviewed_prs==0 and .refused_prs==1 and .no_response_prs==1'
  echo "$output" | jq -e '.bots["coderabbitai"]              | .reviewed_prs==0 and .refused_prs==1 and .no_response_prs==1'
}

@test "aggregate: the three PR buckets sum to eligible for every bot" {
  run aggregate_snapshot "$FIXTURES"
  echo "$output" | jq -e '.eligible_prs as $e
    | .bots | to_entries
    | all(.value.reviewed_prs + .value.refused_prs + .value.no_response_prs == $e)'
}

@test "aggregate: reviews and refusals are EVENT counts (each occurrence)" {
  run aggregate_snapshot "$FIXTURES"
  # copilot submitted a real review on both PRs → 2 review events, 0 refusals
  echo "$output" | jq -e '.bots["copilot-pull-request-reviewer"] | .reviews==2 and .refusal_events==0'
  # codex + coderabbit only refused on markets#42 → 0 reviews, 1 refusal event each
  echo "$output" | jq -e '.bots["chatgpt-codex-connector"] | .reviews==0 and .refusal_events==1'
  echo "$output" | jq -e '.bots["coderabbitai"]            | .reviews==0 and .refusal_events==1'
}

@test "aggregate: a PR reviewed twice (2 commits) counts as 2 review events" {
  local tmp
  tmp="$(mktemp -d "$BATS_TEST_TMPDIR/multi.XXXXXX")" || { echo "Failed to create temp directory" >&2; exit 1; }
  cat > "$tmp/r.jsonl" <<'JSON'
{"kind":"pr","repo":"o/r","pr":"o/r/1","created":"2026-07-10T10:00:00Z","merged":null,"draft":false,"author":"h"}
{"kind":"bot_pr","repo":"o/r","pr":"o/r/1","bot":"gemini-code-assist","created":"2026-07-10T10:00:00Z","real_responses":2,"refusals":0,"latency_s":60,"reviews":2,"approved":1,"changes_req":1,"inline_comments":0,"threads_total":0,"threads_resolved":0,"thumbs_up":0,"thumbs_down":0}
JSON
  run aggregate_snapshot "$tmp"
  echo "$output" | jq -e '.bots["gemini-code-assist"] | .reviews==2 and .reviewed_prs==1'
}

@test "aggregate: latency percentiles are numeric when data exists" {
  run aggregate_snapshot "$FIXTURES"
  echo "$output" | jq -e '.bots["gemini-code-assist"].latency_p50 == 50'
}

@test "aggregate: a check-run clean pass (0 review events) still fills the reviewed bucket" {
  tmp="$(mktemp -d "$BATS_TEST_TMPDIR/cr.XXXXXX")"
  cat > "$tmp/r.jsonl" <<'JSON'
{"kind":"pr","repo":"o/r","pr":"o/r/1","created":"2026-09-23T10:00:00Z","merged":null,"draft":false,"author":"h"}
{"kind":"bot_pr","repo":"o/r","pr":"o/r/1","bot":"graphite-app","created":"2026-09-23T10:00:00Z","real_responses":1,"refusals":0,"latency_s":300,"reviews":0,"approved":0,"changes_req":0,"inline_comments":0,"threads_total":0,"threads_resolved":0,"thumbs_up":0,"thumbs_down":0}
JSON
  run aggregate_snapshot "$tmp"
  echo "$output" | jq -e '.bots["graphite-app"] | .reviewed_prs==1 and .reviews==0 and .no_response_prs==0'
}

@test "aggregate: empty dir yields a zeroed snapshot" {
  local empty
  empty="$(mktemp -d "$BATS_TEST_TMPDIR/empty.XXXXXX")" || { echo "Failed to create temp directory" >&2; exit 1; }
  run aggregate_snapshot "$empty"
  echo "$output" | jq -e '.total_prs == 0 and (.bots | length == 0)'
}

# ---------------------------------------------------------------------------
# render_reviewer_report
# ---------------------------------------------------------------------------

@test "render: scorecard has a row for every tracked reviewer" {
  run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "GitHub Copilot"
  echo "$output" | grep -q "Gemini Code Assist"
  echo "$output" | grep -q "CodeRabbit"
  echo "$output" | grep -q "SonarCloud"
  echo "$output" | grep -q "Codex"
}

@test "render: states it is deterministic with no LLM" {
  run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  echo "$output" | grep -q "no LLM is involved"
}

@test "render: cost is explicitly a known gap (not measured)" {
  run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  echo "$output" | grep -q "Cost is not measured here"
}

@test "render: coverage overlap counts PRs reviewed by >=2 bots" {
  run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  # markets#42 has 4 bots, broodly#7 has 2 → 2 of 2 eligible
  echo "$output" | grep -q "PRs reviewed by ≥2 bots:\*\* 2 of 2"
}

@test "render: the event-count columns live in the details section (#2504)" {
  run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  echo "$output" | grep -q "^## Details"
  echo "$output" | grep -q "| Reviewer | Reviews | ✅ / 🔄 | Refusal events |"
}

@test "render: empty dir yields a no-data message" {
  local empty
  empty="$(mktemp -d "$BATS_TEST_TMPDIR/empty.XXXXXX")" || { echo "Failed to create temp directory" >&2; exit 1; }
  run render_reviewer_report "$empty" 7 0 2026-07-13
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "No pull-request activity found"
}

@test "render: week-over-week delta arrow appears when a prior snapshot is given" {
  local prev
  prev="$(mktemp "$BATS_TEST_TMPDIR/prev.XXXXXX")" || { echo "Failed to create temp file" >&2; exit 1; }
  cat > "$prev" <<'JSON'
{"eligible_prs":3,"total_prs":4,"bots":{"copilot-pull-request-reviewer":{"reviews":5}}}
JSON
  REVIEWER_PREV_SNAPSHOT="$prev" run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  # copilot review events dropped from 5 → 2
  echo "$output" | grep -q "▼ -3"
}

@test "render: writes the snapshot artifact when REVIEWER_SNAPSHOT_OUT is set" {
  local out
  out="$(mktemp "$BATS_TEST_TMPDIR/out.XXXXXX")" || { echo "Failed to create temp file" >&2; exit 1; }
  REVIEWER_SNAPSHOT_OUT="$out" run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  run jq -e '.bots["copilot-pull-request-reviewer"].reviewed_prs == 2' "$out"
  [ "$status" -eq 0 ]
}

@test "render: a repo that could not be collected is surfaced prominently (#1908)" {
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/cerr.XXXXXX")"
  cat > "$dir/r.jsonl" <<'JSON'
{"kind":"pr","repo":"o/r","pr":"o/r/1","created":"2026-09-23T10:00:00Z","merged":null,"draft":false,"author":"h"}
{"kind":"collect_error","repo":"combsmith/markets","reason":"page-1 resource-limit after retries"}
JSON
  run render_reviewer_report "$dir" 7 3 2026-09-23
  [ "$status" -eq 0 ]
  # Prominent, in-report (not a stderr WARN): names the count and the repo.
  echo "$output" | grep -q "could not be collected"
  echo "$output" | grep -q "combsmith/markets"
}

@test "render: a truncated connection is reported explicitly, never silently (#1908)" {
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/trunc.XXXXXX")"
  cat > "$dir/r.jsonl" <<'JSON'
{"kind":"pr","repo":"o/r","pr":"o/r/1","created":"2026-09-23T10:00:00Z","merged":null,"draft":false,"author":"h"}
{"kind":"truncation","repo":"o/r","pr":"o/r/1","connection":"reviews"}
JSON
  run render_reviewer_report "$dir" 7 1 2026-09-23
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "truncat"
  echo "$output" | grep -q "o/r/1"
}

@test "render: no collection-failure section when every repo was collected" {
  run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  [ "$status" -eq 0 ]
  echo "$output" | grep -qv "could not be collected" || true
  ! echo "$output" | grep -q "could not be collected"
}

@test "render: agent-comment noise section is wired into the report (#1411)" {
  local dir
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/noise.XXXXXX")" || { echo "Failed to create temp directory" >&2; exit 1; }
  cat > "$dir/r.jsonl" <<'JSON'
{"kind":"pr","repo":"o/r","pr":"o/r/1","created":"2026-07-10T10:00:00Z","merged":null,"draft":false,"author":"h"}
{"kind":"agent_comment","repo":"o/r","pr":"o/r/1","no_action":true}
{"kind":"agent_comment","repo":"o/r","pr":"o/r/1","no_action":false}
JSON
  run render_reviewer_report "$dir" 7 1 2026-07-13
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Agent comment noise"
  echo "$output" | grep -q "No-action comments"
}

# ---------------------------------------------------------------------------
# Per-message classes (issue #2504)
# ---------------------------------------------------------------------------

CLASS_FIXTURES="${BATS_TEST_DIRNAME}/fixtures/reviewer_message_classes.json"

# _case_node <case_json> — build one GraphQL PR node holding a single bot message
# described by a reviewer_message_classes.json case.
_case_node() {
  jq -c '. as $c
    | ($c.kind) as $k
    | { url: "https://github.com/o/r/pull/1", createdAt: "2026-11-10T10:00:00Z",
        updatedAt: "2026-11-10T10:00:00Z", mergedAt: null, isDraft: false, author: {login: "h"},
        reviews: {nodes: (if $k == "review" then [{author: {login: $c.bot}, state: ($c.state // "COMMENTED"),
                    submittedAt: "2026-11-10T10:05:00Z", bodyText: $c.body}] else [] end)},
        reviewThreads: {nodes: (if $k == "inline" then [{isResolved: false, isOutdated: false,
                    comments: {nodes: [{author: {login: $c.bot}, createdAt: "2026-11-10T10:05:00Z",
                    bodyText: $c.body, path: "a.py", reactionGroups: []}]}}] else [] end)},
        comments: {nodes: (if $k == "issue" then [{author: {login: $c.bot}, createdAt: "2026-11-10T10:05:00Z",
                    bodyText: $c.body}] else [] end)},
        _checkRuns: (if $k == "check_run" then [{bot: $c.bot, status: "completed", conclusion: $c.conclusion,
                    summary: $c.body, completed_at: "2026-11-10T10:05:00Z"}] else [] end) }' <<<"$1"
}

_all_bots_json() { printf '%s\n' "${REVIEWER_BOTS[@]}" | jq -R . | jq -sc .; }

# _normalize_node <node_json> — run _NORMALIZE_JQ over one node; prints a JSON array.
_normalize_node() {
  jq -c --arg repo "o/r" --argjson bots "$(_all_bots_json)" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" <<<"$1"
}

@test "classes: every fixture message lands in its expected class (#2504)" {
  local n fails=0 i c node out got
  n="$(jq 'length' "$CLASS_FIXTURES")"
  [ "$n" -gt 0 ]
  for ((i = 0; i < n; i++)); do
    c="$(jq -c ".[$i]" "$CLASS_FIXTURES")"
    node="$(_case_node "$c")"
    out="$(_normalize_node "$node")"
    got="$(jq -r --arg b "$(jq -r .bot <<<"$c")" '
      [ .[] | select(.kind=="bot_pr" and .bot==$b) | .classes | to_entries[] | select(.value > 0) | .key ]
      | join(",")' <<<"$out")"
    if [ "$got" != "$(jq -r .expect <<<"$c")" ]; then
      echo "FAIL: $(jq -r .name <<<"$c") — expected $(jq -r .expect <<<"$c"), got '${got}'"
      fails=$((fails + 1))
    fi
  done
  [ "$fails" -eq 0 ]
}

@test "classes: fixtures cover a finding and a clean pass for every tracked bot (#2504)" {
  local bot
  for bot in "${REVIEWER_BOTS[@]}"; do
    jq -e --arg b "$bot" 'any(.[]; .bot==$b and .expect=="finding")' "$CLASS_FIXTURES" >/dev/null \
      || { echo "no finding fixture for $bot"; return 1; }
    jq -e --arg b "$bot" 'any(.[]; .bot==$b and .expect=="clean")' "$CLASS_FIXTURES" >/dev/null \
      || { echo "no clean fixture for $bot"; return 1; }
  done
}

@test "classes: the Graphite neutral hourly-limit check run is refused (#2504)" {
  local node out
  node="$(_case_node '{"bot":"graphite-app","kind":"check_run","conclusion":"neutral","body":"AI review skipped: hourly limit reached"}')"
  out="$(_normalize_node "$node")"
  echo "$out" | jq -e '.[] | select(.bot=="graphite-app") | .classes.refused==1 and .refusals==1 and .real_responses==0'
}

@test "classes: each message gets exactly one class (#2504)" {
  local tmp out
  tmp="$(mktemp "$BATS_TEST_TMPDIR/tmp.XXXXXX")"
  cat > "$tmp" <<'JSON'
{"url":"u","createdAt":"2026-11-10T10:00:00Z","updatedAt":"2026-11-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[{"author":{"login":"coderabbitai"},"state":"COMMENTED","submittedAt":"2026-11-10T10:05:00Z","bodyText":"Actionable comments posted: 1"}]},
 "reviewThreads":{"nodes":[{"isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"},"createdAt":"2026-11-10T10:05:00Z","bodyText":"Possible nil deref.","reactionGroups":[]}]}}]},
 "comments":{"nodes":[
   {"author":{"login":"coderabbitai"},"createdAt":"2026-11-10T10:01:00Z","bodyText":"Review skipped\nAuto reviews are disabled on this repository."},
   {"author":{"login":"coderabbitai"},"createdAt":"2026-11-10T10:02:00Z","bodyText":"Something nobody has a pattern for yet."}]}}
JSON
  out="$(jq -c --arg repo "r" --argjson bots "$(_all_bots_json)" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$tmp")"
  echo "$out" | jq -e '.[] | select(.bot=="coderabbitai")
    | (.classes | [.[]] | add) == 4
      and .classes.finding == 2 and .classes.skipped == 1 and .classes.unclassified == 1'
}

@test "classes: the shared fallback refuses a notice the bot has no pattern for (#2504)" {
  local node out
  node="$(_case_node '{"bot":"copilot-pull-request-reviewer","kind":"issue","body":"Copilot is rate limited. Too many requests; try again later."}')"
  out="$(_normalize_node "$node")"
  echo "$out" | jq -e '.[] | select(.bot=="copilot-pull-request-reviewer") | .classes.refused==1'
}

@test "classes: an inline comment that mentions a rate limit is still a finding (#2504)" {
  local node out
  node="$(_case_node '{"bot":"gemini-code-assist","kind":"inline","body":"This retry loop ignores the rate limit header."}')"
  out="$(_normalize_node "$node")"
  echo "$out" | jq -e '.[] | select(.bot=="gemini-code-assist") | .classes.finding==1 and .refusals==0'
}

@test "classes: an inline comment from coderabbitai with rate limit phrase is finding, not refused (#2504)" {
  local node out
  node="$(_case_node '{"bot":"coderabbitai","kind":"inline","body":"rate limit exceeded for valid requests"}')"
  out="$(_normalize_node "$node")"
  echo "$out" | jq -e '.[] | select(.bot=="coderabbitai") | .classes.finding==1 and .refusals==0'
}

@test "classes: a bot reply inside a thread someone else opened is status, not a new finding (#2504)" {
  local tmp out
  tmp="$(mktemp "$BATS_TEST_TMPDIR/tmp.XXXXXX")"
  cat > "$tmp" <<'JSON'
{"url":"u","createdAt":"2026-11-10T10:00:00Z","updatedAt":"2026-11-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[]},
 "reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[
   {"author":{"login":"alice"},"createdAt":"2026-11-10T10:01:00Z","bodyText":"@coderabbitai why?","reactionGroups":[]},
   {"author":{"login":"coderabbitai"},"createdAt":"2026-11-10T10:02:00Z","bodyText":"Thanks for asking — here is the context.","reactionGroups":[]}]}}]},
 "comments":{"nodes":[]}}
JSON
  out="$(jq -c --arg repo "r" --argjson bots "$(_all_bots_json)" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$tmp")"
  echo "$out" | jq -e '.[] | select(.bot=="coderabbitai") | .classes.status==1 and .classes.finding==0 and .threads_total==0'
}

@test "classes: a PR with only status messages is not reviewed (#2504)" {
  local dir node
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/st.XXXXXX")"
  node="$(_case_node '{"bot":"codeant-ai","kind":"issue","body":"Thanks for using CodeAnt! 🎉"}')"
  _normalize_node "$node" | jq -c '.[]' > "$dir/r.jsonl"
  run aggregate_snapshot "$dir"
  echo "$output" | jq -e '.bots["codeant-ai"] | .reviewed_prs==0 and .with_findings_prs==0 and .clean_prs==0 and .no_response_prs==1'
}

@test "classes: a PR with only unclassified messages is not reviewed (#2504)" {
  local dir node
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/uc.XXXXXX")"
  node="$(_case_node '{"bot":"cubic-dev-ai","kind":"issue","body":"A brand new message shape nobody has seen before."}')"
  _normalize_node "$node" | jq -c '.[]' > "$dir/r.jsonl"
  run aggregate_snapshot "$dir"
  echo "$output" | jq -e '.bots["cubic-dev-ai"] | .reviewed_prs==0 and .no_response_prs==1 and .unclassified_events==1'
}

@test "classes: a skipped-only PR fills the Skipped bucket and the five buckets sum to eligible (#2504)" {
  local dir
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/sk.XXXXXX")"
  _normalize_node "$(_case_node '{"bot":"coderabbitai","kind":"issue","body":"Review skipped\nAuto reviews are disabled on this repository."}')" \
    | jq -c '.[]' > "$dir/a.jsonl"
  _normalize_node "$(_case_node '{"bot":"coderabbitai","kind":"review","body":"Actionable comments posted: 3"}' | jq -c '.url="https://github.com/o/r/pull/2"')" \
    | jq -c '.[]' > "$dir/b.jsonl"
  run aggregate_snapshot "$dir"
  echo "$output" | jq -e '.bots["coderabbitai"] | .skipped_prs==1 and .with_findings_prs==1 and .clean_prs==0 and .refused_prs==0 and .no_response_prs==0'
  echo "$output" | jq -e '.eligible_prs as $e | .bots | to_entries
    | all(.value | .with_findings_prs + .clean_prs + .refused_prs + .skipped_prs + .no_response_prs == $e)'
}

@test "classes: findings raised = inline threads plus review-body findings; resolved % from threads (#2504)" {
  local dir
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/fr.XXXXXX")"
  # PR 1: two inline threads opened by gemini (one resolved) and its summary review.
  # The summary only introduces those threads, so it adds no extra finding.
  cat > "$dir/n1.json" <<'JSON'
{"url":"https://github.com/o/r/pull/1","createdAt":"2026-11-10T10:00:00Z","updatedAt":"2026-11-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[{"author":{"login":"gemini-code-assist"},"state":"CHANGES_REQUESTED","submittedAt":"2026-11-10T10:05:00Z","bodyText":"Code Review\nTwo issues below."}]},
 "reviewThreads":{"nodes":[
   {"isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"gemini-code-assist"},"createdAt":"2026-11-10T10:05:00Z","bodyText":"Off by one.","reactionGroups":[{"content":"THUMBS_UP","users":{"totalCount":1}}]}]}},
   {"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"gemini-code-assist"},"createdAt":"2026-11-10T10:05:00Z","bodyText":"Leak.","reactionGroups":[]}]}}]},
 "comments":{"nodes":[]}}
JSON
  # PR 2: a finding delivered only in a review body (no inline thread) counts once.
  cat > "$dir/n2.json" <<'JSON'
{"url":"https://github.com/o/r/pull/2","createdAt":"2026-11-10T10:00:00Z","updatedAt":"2026-11-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[{"author":{"login":"gemini-code-assist"},"state":"CHANGES_REQUESTED","submittedAt":"2026-11-10T10:05:00Z","bodyText":"Please fix the migration order."}]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[]}}
JSON
  _normalize_node "$(cat "$dir/n1.json")" | jq -c '.[]' > "$dir/a.jsonl"
  _normalize_node "$(cat "$dir/n2.json")" | jq -c '.[]' > "$dir/b.jsonl"
  run aggregate_snapshot "$dir"
  echo "$output" | jq -e '.bots["gemini-code-assist"] | .findings_raised==3 and .threads_total==2 and .threads_resolved==1 and .thumbs_up==1'
  # Other bots keep the #2504 rule (#2527): threads 2, plus 1 body on the thread-less PR.
  echo "$output" | jq -e '.bots["gemini-code-assist"] | .findings_threads==2 and .findings_body==1'
  run render_reviewer_report "$dir" 7 1 2026-11-12
  echo "$output" | grep -E '^\| Gemini Code Assist \| 2 \| 2 +\| 0 +\| 0 +\| 0 +\| 0 +\| 3 +\| 50% +\|'
}

# ---------------------------------------------------------------------------
# Body findings (issue #2527)
# ---------------------------------------------------------------------------

@test "body findings: CodeRabbit outside-diff and nitpick items count beside its threads (#2527)" {
  local dir
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/cr.XXXXXX")"
  # Two reviews on one PR, one per header form seen in bodyText. Review 1 opened two
  # threads and also carries 1 outside-diff item and 2 nitpicks; review 2 carries
  # 1 nitpick. The unnumbered repeats in the "Prompt to fix all issues" block must not
  # add anything, and "Duplicate comments" / "Additional comments" are not findings.
  cat > "$dir/n.json" <<'JSON'
{"url":"https://github.com/o/r/pull/1","createdAt":"2026-11-10T10:00:00Z","updatedAt":"2026-11-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[
   {"id":"R1","author":{"login":"coderabbitai"},"state":"COMMENTED","submittedAt":"2026-11-10T10:05:00Z","bodyText":"Actionable comments posted: 2\nCautionSome comments are outside the diff and can’t be posted inline due to GitHub limitations.\n⚠️ Outside diff range comments (1)\n\nscripts/a.sh:80-110\nAdd a contract test.\n\n🧹 Nitpick comments (2)\n\nscripts/b.sh (2)\n\n♻️ Duplicate comments (3)\n\nAdditional comments: 4\n\n🤖 Prompt to fix all issues\nOutside diff comments:\nReview comments at @scripts/a.sh:\n- Around line 80-110: Add a contract test.\nNitpick comments:\n- Line 3: rename it."},
   {"id":"R2","author":{"login":"coderabbitai"},"state":"COMMENTED","submittedAt":"2026-11-10T11:05:00Z","bodyText":" Nitpick comments: 1\n\nscripts/c.sh: 1\n\n1-1:  Trivial · Add the safety flags."}]},
 "reviewThreads":{"nodes":[
   {"isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"},"createdAt":"2026-11-10T10:05:00Z","bodyText":"Null deref.","path":"a.sh","line":5,"originalLine":5,"pullRequestReview":{"id":"R1"},"reactionGroups":[]}]}},
   {"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"},"createdAt":"2026-11-10T10:05:00Z","bodyText":"Leak.","path":"b.sh","line":9,"originalLine":9,"pullRequestReview":{"id":"R1"},"reactionGroups":[]}]}}]},
 "comments":{"nodes":[]}}
JSON
  run _normalize_node "$(cat "$dir/n.json")"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.kind=="bot_pr" and .bot=="coderabbitai")
    | .findings_threads==2 and .findings_body==4 and .findings_raised==6'
}

@test "body findings: a CodeRabbit body with no section counts once, only on a thread-less PR (#2527)" {
  local out
  out="$(_normalize_node "$(_case_node '{"bot":"coderabbitai","kind":"review","body":"Actionable comments posted: 3"}')")"
  echo "$out" | jq -e '.[] | select(.bot=="coderabbitai") | .findings_threads==0 and .findings_body==1 and .findings_raised==1'
}

@test "body findings: Codex body suggestions count unless the same review has an inline comment there (#2527)" {
  local dir
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/cx.XXXXXX")"
  # Review C1 points at three locations:
  #   x.sh L10-L12 (permalink form)     — matched by C1's inline comment on x.sh line 11 → not counted;
  #   y.sh line 40 (rendered snippet)   — no inline comment there → counted;
  #   z.sh L5 (permalink form)          — only a DIFFERENT review (C0) commented there → counted.
  cat > "$dir/n.json" <<'JSON'
{"url":"https://github.com/o/r/pull/1","createdAt":"2026-11-10T10:00:00Z","updatedAt":"2026-11-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[
   {"id":"C0","author":{"login":"chatgpt-codex-connector"},"state":"COMMENTED","submittedAt":"2026-11-10T10:02:00Z","bodyText":"💡 Codex Review\nHere are some automated review suggestions for this pull request.\nReviewed commit: aaaaaaa111"},
   {"id":"C1","author":{"login":"chatgpt-codex-connector"},"state":"COMMENTED","submittedAt":"2026-11-10T10:05:00Z","bodyText":"💡 Codex Review\nHere are some automated review suggestions for this pull request.\nReviewed commit: 0123456789\nhttps://github.com/o/r/blob/0123456789abcdef0123456789abcdef01234567/src/x.sh#L10-L12\nHandle the empty list\nWhen the list is empty this loop never runs.\n\nr/src/y.sh\n\n        Line 40\n      in\n      0123456\n\nQuote the variable\nWord splitting breaks paths with spaces.\n\nhttps://github.com/o/r/blob/0123456789abcdef0123456789abcdef01234567/src/z.sh#L5\nCheck the exit status"}]},
 "reviewThreads":{"nodes":[
   {"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"createdAt":"2026-11-10T10:05:00Z","bodyText":"Handle the empty list","path":"src/x.sh","line":null,"originalLine":11,"pullRequestReview":{"id":"C1"},"reactionGroups":[]}]}},
   {"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"createdAt":"2026-11-10T10:02:00Z","bodyText":"Check the exit status","path":"src/z.sh","line":5,"originalLine":5,"pullRequestReview":{"id":"C0"},"reactionGroups":[]}]}}]},
 "comments":{"nodes":[]}}
JSON
  run _normalize_node "$(cat "$dir/n.json")"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.kind=="bot_pr" and .bot=="chatgpt-codex-connector")
    | .findings_threads==2 and .findings_body==2 and .findings_raised==4'
}

@test "body findings: Codex location paths compare exactly, not by suffix (#2527)" {
  # The same review has an inline comment on x.sh line 10. Its body points at
  # src/x.sh L10 (a different file: counted) and, as a rendered snippet, at r/x.sh
  # line 10 (x.sh once the repo name is stripped: matched, not counted).
  run _normalize_node '{"url":"u","createdAt":"2026-11-10T10:00:00Z","updatedAt":"2026-11-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[{"id":"C1","author":{"login":"chatgpt-codex-connector"},"state":"COMMENTED","submittedAt":"2026-11-10T10:05:00Z","bodyText":"Here are some automated review suggestions for this pull request.\nhttps://github.com/o/r/blob/0123456789abcdef0123456789abcdef01234567/src/x.sh#L10\nCheck the exit status\n\nr/x.sh\n  Line 10\n  in\n  0123456\nQuote the variable"}]},
 "reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"createdAt":"2026-11-10T10:05:00Z","bodyText":"Quote the variable","path":"x.sh","line":10,"originalLine":10,"pullRequestReview":{"id":"C1"},"reactionGroups":[]}]}}]},
 "comments":{"nodes":[]}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.kind=="bot_pr" and .bot=="chatgpt-codex-connector")
    | .findings_threads==1 and .findings_body==1 and .findings_raised==2'
}

@test "body findings: a URL-encoded Codex permalink path matches the decoded inline path (#2527)" {
  run _normalize_node '{"url":"u","createdAt":"2026-11-10T10:00:00Z","updatedAt":"2026-11-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[{"id":"C1","author":{"login":"chatgpt-codex-connector"},"state":"COMMENTED","submittedAt":"2026-11-10T10:05:00Z","bodyText":"Here are some automated review suggestions for this pull request.\nhttps://github.com/o/r/blob/0123456789abcdef0123456789abcdef01234567/docs/my%20notes.md#L3\nFix the link"}]},
 "reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"createdAt":"2026-11-10T10:05:00Z","bodyText":"Fix the link","path":"docs/my notes.md","line":3,"originalLine":3,"pullRequestReview":{"id":"C1"},"reactionGroups":[]}]}}]},
 "comments":{"nodes":[]}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.kind=="bot_pr" and .bot=="chatgpt-codex-connector")
    | .findings_threads==1 and .findings_body==0'
}

@test "body findings: a Codex location written as both permalink and snippet counts once (#2527)" {
  run _normalize_node '{"url":"u","createdAt":"2026-11-10T10:00:00Z","updatedAt":"2026-11-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[{"id":"C1","author":{"login":"chatgpt-codex-connector"},"state":"COMMENTED","submittedAt":"2026-11-10T10:05:00Z","bodyText":"Here are some automated review suggestions for this pull request.\nhttps://github.com/o/r/blob/0123456789abcdef0123456789abcdef01234567/src/x.sh#L10-L12\nr/src/x.sh\n  Lines 10 to 12\n  in\n  0123456\nHandle the empty list"}]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[]}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.kind=="bot_pr" and .bot=="chatgpt-codex-connector")
    | .findings_threads==0 and .findings_body==1 and .findings_raised==1'
}

@test "body findings: a boilerplate Codex body beside its threads adds nothing (#2527)" {
  run _normalize_node '{"url":"u","createdAt":"2026-11-10T10:00:00Z","updatedAt":"2026-11-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[{"id":"C1","author":{"login":"chatgpt-codex-connector"},"state":"COMMENTED","submittedAt":"2026-11-10T10:05:00Z","bodyText":"💡 Codex Review\nHere are some automated review suggestions for this pull request.\nReviewed commit: 0123456789"}]},
 "reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"createdAt":"2026-11-10T10:05:00Z","bodyText":"Handle the empty list","path":"src/x.sh","line":11,"originalLine":11,"pullRequestReview":{"id":"C1"},"reactionGroups":[]}]}}]},
 "comments":{"nodes":[]}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.kind=="bot_pr" and .bot=="chatgpt-codex-connector")
    | .findings_threads==1 and .findings_body==0 and .findings_raised==1'
}

@test "body findings: Details shows threads and bodies separately; the headline is their sum (#2527)" {
  local dir
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/cd.XXXXXX")"
  _normalize_node "$(_case_node '{"bot":"coderabbitai","kind":"review","body":"Nitpick comments: 2"}')" \
    | jq -c '.[]' > "$dir/a.jsonl"
  run aggregate_snapshot "$dir"
  echo "$output" | jq -e '.bots["coderabbitai"] | .findings_threads==0 and .findings_body==2 and .findings_raised==2'
  run render_reviewer_report "$dir" 7 1 2026-11-12
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "| Findings: threads / bodies |"
  echo "$output" | grep -E '^\| CodeRabbit \| 1 \| 1 +\| 0 +\| 0 +\| 0 +\| 0 +\| 2 +\|'
  echo "$output" | grep -E '^\| CodeRabbit \| 1 +\| 0 / 0 \| 0 +\| 0 / 0 \| 0 \| 0 \| 0 / 2 \|$'
}

@test "body findings: Findings raised shows no delta against a v2 snapshot, and one against v3 (#2527)" {
  local dir prev
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/wv.XXXXXX")"
  _normalize_node "$(_case_node '{"bot":"coderabbitai","kind":"review","body":"Nitpick comments: 2"}')" \
    | jq -c '.[]' > "$dir/a.jsonl"
  prev="$(mktemp "$BATS_TEST_TMPDIR/prev.XXXXXX")"
  echo '{"schema_version":2,"eligible_prs":1,"total_prs":1,"bots":{"coderabbitai":{"with_findings_prs":1,"clean_prs":0,"refused_prs":0,"skipped_prs":0,"no_response_prs":0,"findings_raised":1}}}' > "$prev"
  REVIEWER_PREV_SNAPSHOT="$prev" run render_reviewer_report "$dir" 7 1 2026-11-12
  [ "$status" -eq 0 ]
  # With findings keeps its v2 delta; Findings raised has none.
  echo "$output" | grep -E '^\| CodeRabbit \| 1 \| 1 \(±0\) \| 0 \(±0\) \| 0 \(±0\) \| 0 \(±0\) \| 0 \(±0\) \| 2 +\|'
  echo '{"schema_version":3,"eligible_prs":1,"total_prs":1,"bots":{"coderabbitai":{"with_findings_prs":1,"clean_prs":0,"refused_prs":0,"skipped_prs":0,"no_response_prs":0,"findings_raised":1}}}' > "$prev"
  REVIEWER_PREV_SNAPSHOT="$prev" run render_reviewer_report "$dir" 7 1 2026-11-12
  echo "$output" | grep -E '^\| CodeRabbit \| 1 \| .* \| 2 \(▲ \+1\) \|'
}

@test "render: headline table has the #2504 columns" {
  run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "| Reviewer | Total PRs | With findings | Clean | Refused | Skipped | No response | Findings raised | Resolved % | Latency p50 | Latency p95 |"
}

@test "render: details section shows reviews, verdicts and reactions (#2504)" {
  run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  # copilot: 2 review events, 0 approved / 1 changes requested, 2 👍 / 1 👎.
  echo "$output" | grep -E '^\| GitHub Copilot \| 2 +\| 0 / 1 \| 0 +\| 2 / 1 \|'
}

@test "render: lists up to 3 truncated unclassified samples per bot (#2504)" {
  local dir i body
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/samp.XXXXXX")"
  for i in 1 2 3 4; do
    body="Unknown shape number ${i} $(printf 'x%.0s' $(seq 1 200))"
    _normalize_node "$(_case_node "$(jq -cn --arg b "$body" --arg i "$i" \
      '{bot:"cubic-dev-ai",kind:"issue",body:$b}')" | jq -c --arg i "$i" '.url="https://github.com/o/r/pull/\($i)"')" \
      | jq -c '.[]' > "$dir/$i.jsonl"
  done
  run render_reviewer_report "$dir" 7 1 2026-11-12
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^## Unclassified messages"
  [ "$(echo "$output" | grep -c 'Unknown shape number')" -eq 3 ]
  # Truncated: no sample line carries the full 200-char tail.
  [ "$(echo "$output" | grep 'Unknown shape number' | awk '{ if (length($0) > 200) c++ } END { print c+0 }')" -eq 0 ]
  echo "$output" | grep -q 'Unknown shape number 1 xxx.*…'
}

@test "render: no unclassified section when every message was classified (#2504)" {
  run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  [ "$status" -eq 0 ]
  run grep -q "^## Unclassified messages" <<<"$output"
  [ "$status" -ne 0 ]
}

@test "render: WoW deltas cover the new columns against a v2 snapshot (#2504)" {
  local prev
  prev="$(mktemp "$BATS_TEST_TMPDIR/prev.XXXXXX")"
  cat > "$prev" <<'JSON'
{"schema_version":2,"eligible_prs":2,"total_prs":3,"bots":{"chatgpt-codex-connector":{"with_findings_prs":0,"clean_prs":0,"refused_prs":2,"skipped_prs":0,"no_response_prs":0,"findings_raised":0,"threads_total":0,"threads_resolved":0}}}
JSON
  REVIEWER_PREV_SNAPSHOT="$prev" run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  [ "$status" -eq 0 ]
  # Codex refused 2 → 1 and no-response 0 → 1.
  echo "$output" | grep -E '^\| Codex \| 2 \| 0 \(±0\) \| 0 \(±0\) \| 1 \(▼ -1\) \| 0 \(±0\) \| 1 \(▲ \+1\) \|'
}

@test "render: a prior snapshot without the new fields shows no headline delta and does not fail (#2504)" {
  local prev
  prev="$(mktemp "$BATS_TEST_TMPDIR/prev.XXXXXX")"
  cat > "$prev" <<'JSON'
{"eligible_prs":2,"total_prs":3,"bots":{"chatgpt-codex-connector":{"reviewed_prs":5,"refused_prs":4,"no_response_prs":9,"reviews":3}}}
JSON
  REVIEWER_PREV_SNAPSHOT="$prev" run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  [ "$status" -eq 0 ]
  echo "$output" | grep -E '^\| Codex \| 2 \| 0 +\| 0 +\| 1 +\| 0 +\| 1 +\| 0 +\| n/a +\|'
}

@test "snapshot: carries schema_version 3 and never the unclassified sample bodies (#2504, #2527)" {
  local out
  out="$(mktemp "$BATS_TEST_TMPDIR/out.XXXXXX")"
  REVIEWER_SNAPSHOT_OUT="$out" run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  jq -e '.schema_version == 3' "$out"
  run grep -q "unclassified_samples" "$out"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Message-class sidecar (scripts/lib/reviewer-message-classes.tsv, #2504)
# ---------------------------------------------------------------------------

@test "sidecar: loader emits login/class/kind/pattern rows" {
  run reviewer_sources_message_class_patterns
  [ "$status" -eq 0 ]
  echo "$output" | awk -F'\t' 'NF != 4 { bad++ } END { exit bad ? 1 : 0 }'
  echo "$output" | grep -q $'^gemini-code-assist\trefused\t'
}

@test "sidecar: every login is a registered reviewer source and every class/kind is valid" {
  local logins login class kind rows
  logins="$(reviewer_sources_logins)"
  rows="$(reviewer_sources_message_class_patterns)" || return 1
  while IFS=$'\t' read -r login class kind _; do
    grep -qx "$login" <<<"$logins" || { echo "unregistered login: $login"; return 1; }
    [[ "$class" =~ ^(finding|clean|refused|skipped|status)$ ]] || { echo "bad class: $class"; return 1; }
    [[ "$kind" =~ ^(any|review|inline|issue|check_run)$ ]] || { echo "bad kind: $kind"; return 1; }
  done <<<"$rows"
}

@test "sidecar: every pattern compiles as a jq regex" {
  local login pattern rows
  rows="$(reviewer_sources_message_class_patterns)" || return 1
  while IFS=$'\t' read -r login _ _ pattern; do
    jq -en --arg p "$pattern" '"" | test($p; "i") | . or true' >/dev/null \
      || { echo "bad regex for $login: $pattern"; return 1; }
  done <<<"$rows"
}

@test "sidecar: loader rejects a row with an unknown class" {
  local bad
  bad="$(mktemp "$BATS_TEST_TMPDIR/bad.XXXXXX")"
  printf 'gemini-code-assist\treview\tany\tfoo\n' > "$bad"
  REVIEWER_MESSAGE_CLASSES_FILE="$bad" run reviewer_sources_message_class_patterns
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown class"
}

@test "normalize: a CHANGES_REQUESTED review matching a per-bot refused row stays a finding" {
  run _normalize_node '{"url":"https://github.com/o/r/pull/9","createdAt":"2026-11-10T10:00:00Z","updatedAt":"2026-11-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[{"author":{"login":"coderabbitai"},"state":"CHANGES_REQUESTED","submittedAt":"2026-11-10T10:05:00Z","bodyText":"The handler mishandles rate limit exceeded responses."}]},
 "reviewThreads":{"nodes":[]},"comments":{"nodes":[]}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.[] | select(.kind=="bot_pr" and .bot=="coderabbitai")]
    | length == 1 and (.[0].classes | .finding == 1 and .refused == 0)'
}

@test "normalize: a CHANGES_REQUESTED review matching a per-bot status row stays a finding" {
  run _normalize_node '{"url":"https://github.com/o/r/pull/9","createdAt":"2026-11-10T10:00:00Z","updatedAt":"2026-11-10T10:00:00Z","mergedAt":null,"isDraft":false,"author":{"login":"h"},
 "reviews":{"nodes":[{"author":{"login":"coderabbitai"},"state":"CHANGES_REQUESTED","submittedAt":"2026-11-10T10:05:00Z","bodyText":"Walkthrough: please fix the migration order."}]},
 "reviewThreads":{"nodes":[]},"comments":{"nodes":[]}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.[] | select(.kind=="bot_pr" and .bot=="coderabbitai") | .classes] | .[0] | (.status // 0) == 0 and (.finding // 0) == 1'
}
