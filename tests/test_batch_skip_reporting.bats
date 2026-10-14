#!/usr/bin/env bats
# Regression tests for accurate exit-100 skip reporting in scripts/review-batch.sh
# (issue #898).
#
# The reviewer (review-one-pr.sh) returns exit 100 for *every* no-op/skip: an
# already-reviewed head, a CI-pending deferral, a CI-failing deferral, a
# human-changes-requested skip, an escalation skip, etc. The batch driver used
# to collapse all of these into a single "No-op (already reviewed)" line. That
# message is actively misleading for a CI-pending deferral — it claims a review
# already happened at the current head when in fact the PR is *owed* a review
# once CI goes green. That mislabelling is what made the #892 "deadlock" look
# like a stuck idempotency marker.
#
# These tests assert the batch reports the *reason* behind an exit-100 skip:
#   - a ci-pending skip must NOT claim "already reviewed" and must surface as a
#     deferral ("Deferred" / "CI still pending"),
#   - an already-reviewed-at-head skip must still say "already reviewed",
#   - a batch with at least one CI deferral must note "deferred" in the summary
#     so an operator scanning the run knows a review is still owed.
#
# Run with: bats tests/test_batch_skip_reporting.bats

setup() {
  export TEST_DIR="$BATS_TEST_TMPDIR/batch-skip-report-test"
  mkdir -p "$TEST_DIR/scripts"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  export PRS_FILE="prs.txt"
  echo "https://github.com/fake/pull/1" > "$PRS_FILE"
  export CANDIDATE_LIMIT=1
  export MAX_PRS=1
  export REVIEW_ENGINE="claude"
  export PATH="$TEST_DIR/bin:$PATH"

  cp "$BATS_TEST_DIRNAME/../scripts/review-batch.sh" "scripts/"
  mkdir -p "scripts/lib"
  cp "$BATS_TEST_DIRNAME/../scripts/lib/engine-chain.sh" "scripts/lib/"

  cat > "scripts/validate-engines.sh" <<'EOF'
validate_engines() {
  export CLAUDE_AVAILABLE="true"
  export GEMINI_AVAILABLE="true"
  export COPILOT_AVAILABLE="true"
}
EOF

  cat > "scripts/engine.sh" <<'EOF'
export COPILOT_API_MODEL="openai/o4-mini"
EOF

  cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$TEST_DIR/bin/gh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# review-one-pr.sh stub that emits a CI-pending skip exactly like the real
# reviewer's non-force ci-pending gate: a human-readable line plus a JSON
# verdict carrying reason=ci-pending, then exit 100.
_stub_ci_pending() {
  cat > "scripts/review-one-pr.sh" <<'EOF'
#!/bin/bash
echo "    skip: CI checks still in progress for $1"
echo '{"pr":"'"$1"'","decision":"skip","reason":"ci-pending"}'
exit 100
EOF
  chmod +x "scripts/review-one-pr.sh"
}

_stub_already_reviewed() {
  cat > "scripts/review-one-pr.sh" <<'EOF'
#!/bin/bash
echo "    noop: already reviewed at deadbeef"
echo '{"pr":"'"$1"'","decision":"skip","reason":"already-reviewed-at-head"}'
exit 100
EOF
  chmod +x "scripts/review-one-pr.sh"
}

# review-one-pr.sh stub that emits a carry-forward exactly like the real
# reviewer: it re-issued the prior approval (no tier) and rides the exit-100
# sentinel with reason=carried-forward (issue #1865).
_stub_carried_forward() {
  cat > "scripts/review-one-pr.sh" <<'EOF'
#!/bin/bash
echo "    carry-forward: re-issuing the prior approval for $1"
echo '{"pr":"'"$1"'","decision":"carried-forward","reason":"carried-forward"}'
exit 100
EOF
  chmod +x "scripts/review-one-pr.sh"
}

@test "batch: ci-pending skip is not reported as 'already reviewed'" {
  _stub_ci_pending

  run bash scripts/review-batch.sh
  echo "$output" >&2

  [ "$status" -eq 0 ]
  # The defect: a CI-pending deferral was mislabelled as an already-reviewed
  # no-op. The batch must NOT claim the PR was already reviewed.
  [[ "$output" != *"already reviewed"* ]]
}

@test "batch: ci-pending skip is reported as a deferral" {
  _stub_ci_pending

  run bash scripts/review-batch.sh
  echo "$output" >&2

  [ "$status" -eq 0 ]
  [[ "$output" == *"Deferred"* ]]
  [[ "$output" == *"CI"* ]]
}

@test "batch: ci-pending deferral is surfaced in the session summary" {
  _stub_ci_pending

  run bash scripts/review-batch.sh
  echo "$output" >&2

  [ "$status" -eq 0 ]
  [[ "$output" == *"deferred"* ]]
}

@test "batch: already-reviewed-at-head skip still reports 'already reviewed'" {
  _stub_already_reviewed

  run bash scripts/review-batch.sh
  echo "$output" >&2

  [ "$status" -eq 0 ]
  [[ "$output" == *"already reviewed"* ]]
  # An already-reviewed no-op is genuinely done — it is NOT a CI deferral.
  [[ "$output" != *"deferred"* ]]
}

# ── AC #4 (issue #1744): "0 reviews posted" must not mean two different things ──
# An empty queue (no candidates found) and a full queue where every candidate was
# a no-op both yield "0 reviews posted". The summary line must distinguish them so
# a silent-success omission (an eligible PR missing from the pool) can't hide as an
# ordinary all-no-ops run.

@test "batch: empty queue reports a distinct 'no candidates found' summary" {
  : > "$PRS_FILE"   # empty candidate list — nothing enumerated

  run bash scripts/review-batch.sh
  echo "$output" >&2

  [ "$status" -eq 0 ]
  [[ "$output" == *"Summary:"* ]]
  # Names the empty-queue state explicitly...
  [[ "$output" == *"empty queue"* ]]
  # ...and is NOT phrased like a run that processed candidates.
  [[ "$output" != *"processed"* ]]
}

# ── AC #6 (issue #1865): deterministic carry-forward counters ────────────────
# A carry-forward re-issues the prior approval without a model tier and rides the
# exit-100 sentinel so it stays off the MAX_PRS full-review budget — but it is NOT
# a no-op. The summary must count it in its own bucket and always emit both
# machine-parseable counters (reviews_full / reviews_carried_forward).

@test "batch: a carried-forward reviewer result is counted separately, not as a no-op" {
  _stub_carried_forward

  run bash scripts/review-batch.sh
  echo "$output" >&2

  [ "$status" -eq 0 ]
  # It must be reported as a carry-forward, not collapsed into the no-op bucket.
  [[ "$output" == *"Carried forward"* ]]
  [[ "$output" == *"carried forward"* ]]
  # Deterministic counters: one carry-forward, zero full reviews this run.
  [[ "$output" == *"reviews_full=0 reviews_carried_forward=1"* ]]
  # A carry-forward is NOT a no-op skip nor a full review posted.
  [[ "$output" == *"0 no-ops skipped"* ]]
  [[ "$output" == *"0 reviews posted"* ]]
}

@test "batch: counters are always emitted, even when nothing was carried forward" {
  _stub_already_reviewed

  run bash scripts/review-batch.sh
  echo "$output" >&2

  [ "$status" -eq 0 ]
  # AC #6: both counters present and zeroed on a run with no carry-forward.
  [[ "$output" == *"reviews_full=0 reviews_carried_forward=0"* ]]
}

@test "batch: candidates-all-no-ops summary is distinct from an empty queue" {
  _stub_already_reviewed   # one candidate, reviewed as a no-op

  run bash scripts/review-batch.sh
  echo "$output" >&2

  [ "$status" -eq 0 ]
  [[ "$output" == *"Summary:"* ]]
  # This run DID find candidates — it must say so, and must not read as empty.
  [[ "$output" == *"candidate"* ]]
  [[ "$output" != *"empty queue"* ]]
  [[ "$output" == *"no-op"* ]]
}

# review-one-pr.sh stub that emits the human-escalation exit code (101, #1754):
# a decision was made and an artifact left on the PR, but no review was posted.
_stub_escalated() {
  cat > "scripts/review-one-pr.sh" <<'EOF'
#!/bin/bash
echo "Escalating to human review..."
echo '{"pr":"'"$1"'","decision":"escalate","reason":"human-escalated"}'
exit 101
EOF
  chmod +x "scripts/review-one-pr.sh"
}

@test "batch: escalation (exit 101) is counted as escalated, not posted (#1754 AC1)" {
  _stub_escalated

  run bash scripts/review-batch.sh
  echo "$output" >&2

  [ "$status" -eq 0 ]
  # It must NOT be reported as a posted review — that is the defect.
  [[ "$output" != *"reviews posted ("* ]]
  [[ "$output" != *"Review posted"* ]]
  # It must be surfaced as an escalation in the summary line.
  [[ "$output" == *"escalated to human"* ]]
}

@test "batch: escalation does not fail the session and reports 0 posted" {
  _stub_escalated

  run bash scripts/review-batch.sh
  echo "$output" >&2

  [ "$status" -eq 0 ]
  [[ "$output" == *"0 reviews posted"* ]]
  [[ "$output" == *"1 escalated to human"* ]]
}
