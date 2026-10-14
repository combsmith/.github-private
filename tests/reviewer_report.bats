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
  echo "$output" | jq -e '.[] | select(.kind=="bot_pr" and .bot=="chatgpt-codex-connector") | .real_responses>=1 and .refusals==0'
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
  run jq -c --arg repo "petry-projects/markets" --argjson bots "$BOTS" \
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
  # A failed run is neither a real response nor a refusal → no bot_pr record at all.
  echo "$output" | jq -e 'map(select(.kind=="bot_pr" and .bot=="graphite-app")) | length == 0'
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
  # No bot_pr record → aggregator buckets it as no-response, not a refusal.
  echo "$output" | jq -e 'map(select(.kind=="bot_pr" and .bot=="graphite-app")) | length == 0'
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

@test "render: scorecard exposes the event-count columns" {
  run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  echo "$output" | grep -q "| Reviewer | Total PRs | Reviews | ✅ / 🔄 | Refused | No response |"
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
{"kind":"collect_error","repo":"petry-projects/markets","reason":"page-1 resource-limit after retries"}
JSON
  run render_reviewer_report "$dir" 7 3 2026-09-23
  [ "$status" -eq 0 ]
  # Prominent, in-report (not a stderr WARN): names the count and the repo.
  echo "$output" | grep -q "could not be collected"
  echo "$output" | grep -q "petry-projects/markets"
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
