#!/usr/bin/env bats
# Tests for the single reviewer-source registry (issue #1425).
#
# The registry (scripts/lib/reviewer-sources.tsv) is the source of truth that the
# three reviewer-source consumers agree with: dev-lead's trust check
# (TRUSTED_BOTS), the advisory approval gate (ADVISORY_BOTS), and the reviewer
# scorecard (REVIEWER_BOTS / RATE_LIMIT_NOTICE_BOTS). These tests enforce the
# #1425 invariant — *(can create a review thread) ⇒ (dev-lead may act on it)* —
# and assert the three consumer lists are projections of the registry, so a future
# reviewer-source registration cannot land half-done (the graphite-app deadlock).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
REG_SH="$REPO_ROOT/scripts/lib/reviewer-sources.sh"
REG_TSV="$REPO_ROOT/scripts/lib/reviewer-sources.tsv"

setup() {
  # shellcheck source=scripts/lib/reviewer-sources.sh
  source "$REG_SH"
}

_sorted() { printf '%s\n' "$@" | sort; }

# ── Structure ────────────────────────────────────────────────────────────────

@test "registry: helper and manifest exist" {
  [ -f "$REG_SH" ]
  [ -f "$REG_TSV" ]
}

@test "registry: helper is executable and shellcheck-clean" {
  [ -x "$REG_SH" ]
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  shellcheck --shell=bash "$REG_SH"
}

# ── The #1425 invariant ──────────────────────────────────────────────────────

@test "invariant: every thread-creating source is dev-lead-trusted (real registry)" {
  run reviewer_sources_assert_invariant
  [ "$status" -eq 0 ]
}

@test "invariant: a thread-creator that is NOT trusted is rejected" {
  local bad="${BATS_TEST_TMPDIR}/bad.tsv"
  cat > "$bad" <<'TSV'
# login	creates_threads	dev_lead_trusted	advisory_gate	rationale
some-bot	yes	no	yes	synthetic violation
TSV
  REVIEWER_SOURCES_MANIFEST="$bad" run reviewer_sources_assert_invariant
  [ "$status" -ne 0 ]
  [[ "$output" == *"some-bot"* ]]
}

@test "invariant: a non-thread-creating advisory-only source may be untrusted" {
  local ok="${BATS_TEST_TMPDIR}/ok.tsv"
  cat > "$ok" <<'TSV'
# login	creates_threads	dev_lead_trusted	advisory_gate	rationale
comment-only-bot	no	no	yes	top-level comment only, advisory-only-and-non-blocking
TSV
  REVIEWER_SOURCES_MANIFEST="$ok" run reviewer_sources_assert_invariant
  [ "$status" -eq 0 ]
}

# ── Missing-manifest error propagation ──────────────────────────────────────

@test "missing-manifest: trusted_bots_csv propagates failure" {
  REVIEWER_SOURCES_MANIFEST="/nonexistent/reviewer-sources.tsv" \
    run reviewer_sources_trusted_bots_csv
  [ "$status" -ne 0 ]
}

@test "missing-manifest: advisory_gate_logins propagates failure" {
  REVIEWER_SOURCES_MANIFEST="/nonexistent/reviewer-sources.tsv" \
    run reviewer_sources_advisory_gate_logins
  [ "$status" -ne 0 ]
}

@test "missing-manifest: logins propagates failure" {
  REVIEWER_SOURCES_MANIFEST="/nonexistent/reviewer-sources.tsv" \
    run reviewer_sources_logins
  [ "$status" -ne 0 ]
}

# ── The #1425 fix: graphite/qodo/codeant are now trusted ─────────────────────

@test "registry: graphite-app, qodo-code-review, codeant-ai are thread creators" {
  local creators
  creators="$(reviewer_sources_thread_creator_logins)"
  [[ "$creators" == *"graphite-app"* ]]
  [[ "$creators" == *"qodo-code-review"* ]]
  [[ "$creators" == *"codeant-ai"* ]]
}

@test "registry: trusted-bots CSV carries the [bot] suffix and includes the new three" {
  local csv
  csv="$(reviewer_sources_trusted_bots_csv)"
  [[ "$csv" == *"graphite-app[bot]"* ]]
  [[ "$csv" == *"qodo-code-review[bot]"* ]]
  [[ "$csv" == *"codeant-ai[bot]"* ]]
  # The original five are preserved.
  [[ "$csv" == *"copilot-pull-request-reviewer[bot]"* ]]
  [[ "$csv" == *"gemini-code-assist[bot]"* ]]
  [[ "$csv" == *"sonarqubecloud[bot]"* ]]
  [[ "$csv" == *"coderabbitai[bot]"* ]]
  [[ "$csv" == *"chatgpt-codex-connector[bot]"* ]]
}

# ── Consistency: the three consumer lists are registry projections ───────────

@test "consistency: advisory gate ADVISORY_BOTS == registry advisory-gate projection" {
  # shellcheck source=scripts/lib/advisory-review-gate.sh
  source "$REPO_ROOT/scripts/lib/advisory-review-gate.sh"
  local from_gate from_reg
  from_gate="$(_sorted "${!ADVISORY_BOTS[@]}")"
  from_reg="$(reviewer_sources_advisory_gate_logins | sort)"
  [ "$from_gate" = "$from_reg" ]
}

@test "consistency: advisory gate RATE_LIMIT_NOTICE_BOTS == registry (all sources)" {
  # shellcheck source=scripts/lib/advisory-review-gate.sh
  source "$REPO_ROOT/scripts/lib/advisory-review-gate.sh"
  local from_gate from_reg
  from_gate="$(_sorted "${RATE_LIMIT_NOTICE_BOTS[@]}")"
  from_reg="$(reviewer_sources_logins | sort)"
  [ "$from_gate" = "$from_reg" ]
}

@test "consistency: scorecard REVIEWER_BOTS == registry (all sources)" {
  # shellcheck source=scripts/reviewer_report.sh
  source "$REPO_ROOT/scripts/reviewer_report.sh"
  local from_report from_reg
  from_report="$(_sorted "${REVIEWER_BOTS[@]}")"
  from_reg="$(reviewer_sources_logins | sort)"
  [ "$from_report" = "$from_reg" ]
}

@test "consistency: every registry source has a scorecard display label" {
  # shellcheck source=scripts/reviewer_report.sh
  source "$REPO_ROOT/scripts/reviewer_report.sh"
  local login
  while IFS= read -r login; do
    [ -n "$login" ] || continue
    [ -n "${REVIEWER_LABELS[$login]:-}" ] || {
      echo "registry login '$login' has no REVIEWER_LABELS entry" >&2
      return 1
    }
  done < <(reviewer_sources_logins)
}

# ── dev-lead consumes the registry at runtime ────────────────────────────────

@test "dev-lead: intent script derives TRUSTED_BOTS from the registry when unset" {
  # With TRUSTED_BOTS unset the classifier must fall back to the registry-derived
  # default — which trusts graphite-app — rather than the legacy five-bot literal.
  local ev="${BATS_TEST_TMPDIR}/event.json"
  cat > "$ev" <<'JSON'
{
  "action": "submitted",
  "review": {
    "state": "COMMENTED",
    "body": "Inline finding.",
    "author_association": "NONE",
    "user": { "login": "graphite-app[bot]", "type": "Bot" }
  },
  "pull_request": {
    "number": 1421,
    "author_association": "OWNER",
    "head": { "sha": "deadbee", "ref": "dev-lead/issue-1425", "repo": { "full_name": "combsmith/.github-private" } }
  },
  "repository": { "full_name": "combsmith/.github-private" },
  "sender": { "login": "graphite-app[bot]", "type": "Bot" }
}
JSON
  local out="${BATS_TEST_TMPDIR}/out.env"
  local out_output="${BATS_TEST_TMPDIR}/out_output"
  unset TRUSTED_BOTS
  GITHUB_ENV="$out" GITHUB_OUTPUT="$out_output" \
    GITHUB_EVENT_NAME="pull_request_review" GITHUB_EVENT_PATH="$ev" \
    BOT_USER="donpetry-bot" GITHUB_REPOSITORY="combsmith/.github-private" \
    run bash "$REPO_ROOT/scripts/dev-lead-intent.sh"
  [ "$status" -eq 0 ]
  grep -q "^INTENT_TYPE=fix-reviews$" "$out"
}
