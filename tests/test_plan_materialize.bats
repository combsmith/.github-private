#!/usr/bin/env bats
# Tests for materializing accepted plan-critic findings as sub-issues + native
# blocked_by edges (issue #706, epic #597 Phase 3).
#
# A plan-critic finding may carry an optional proposed_story (a whole story the
# plan is missing) + proposed_blocked_by (the existing issue that story gates),
# routed onto an open_questions object. Until a maintainer sets accepted:true it
# gates exactly like a #682 blocking open_question (apply-plan creates NOTHING);
# on acceptance apply-plan.sh turns it into a real sub-issue of the epic and
# wires the native blocked_by edge via lib/mutations.sh add_blocked_by — instead
# of dropping it into prose. Everything is proven offline via the DRY_RUN
# mutation log; no new network path is introduced.
#
# Run with: bats tests/test_plan_materialize.bats

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  PLANNER_DIR="$ROOT/scripts/initiative-planner"
  VALIDATE="$PLANNER_DIR/validate-plan.py"
  APPLY="$PLANNER_DIR/apply-plan.sh"
  FIXTURE_DIR="$ROOT/tests/fixtures/initiative-planner"
  PLAN_581="$FIXTURE_DIR/plan-581.json"
  PLAN_ACCEPTED="$FIXTURE_DIR/plan-581-accepted.json"
  TMP="$(mktemp -d "${BATS_TEST_TMPDIR}/test-XXXXXX")"
  LOG="$TMP/dry.jsonl"
}

teardown() { rm -rf "$TMP"; }

apply_dry() { # apply_dry <plan.json>
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=572 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$1" \
    bash "$APPLY"
}

# ---------------------------------------------------------------------------
# AC1 — schema + validator accept the new fields; reject a malformed one
# ---------------------------------------------------------------------------

@test "validate-plan accepts a finding carrying proposed_story + proposed_blocked_by" {
  run python3 "$VALIDATE" "$PLAN_ACCEPTED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan OK"* ]]
}

@test "validate-plan accepts a single un-accepted proposed_story finding" {
  jq '.open_questions = [{"question":"[eval_safeguards] plan is missing a held-out split","affected_story_ids":[1],"blocking":true,"proposed_story":{"title":"[Phase 1] Add a held-out split","acceptance_criteria":["dev/test split exists"]},"proposed_blocked_by":587}]' \
    "$PLAN_581" > "$TMP/one.json"
  run python3 "$VALIDATE" "$TMP/one.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan OK"* ]]
}

@test "validate-plan rejects a malformed proposed_story (missing acceptance_criteria)" {
  jq '.open_questions = [{"question":"malformed","proposed_story":{"title":"[Phase 1] Add a held-out split"}}]' \
    "$PLAN_581" > "$TMP/malformed.json"
  run python3 "$VALIDATE" "$TMP/malformed.json"
  [ "$status" -ne 0 ]
}

@test "validate-plan rejects an accepted finding with no proposed_story to materialize" {
  jq '.open_questions = [{"question":"accepted but nothing to build","blocking":true,"accepted":true}]' \
    "$PLAN_581" > "$TMP/emptyaccept.json"
  run python3 "$VALIDATE" "$TMP/emptyaccept.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"proposed_story"* ]]
}

# ---------------------------------------------------------------------------
# AC2 — materialize on acceptance: sub-issue + native blocked_by edge
# ---------------------------------------------------------------------------

@test "apply-plan materializes each accepted proposed_story as a sub-issue of the epic" {
  apply_dry "$PLAN_ACCEPTED"
  # base: epic + 3 stories = 4 create_issue; + 2 materialized proposed stories = 6
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 6 ]
  # each materialized story is linked under the epic as a native sub-issue
  # (3 plan stories + 2 materialized = 5 add_sub_issue)
  [ "$(grep -c '"op":"add_sub_issue"' "$LOG")" -eq 5 ]
}

@test "apply-plan wires proposed_blocked_by as a native blocked_by edge via add_blocked_by" {
  apply_dry "$PLAN_ACCEPTED"
  # 2 intra-plan edges (story2<-1, story3<-2) + 2 materialized edges onto #587
  [ "$(grep -c '"op":"add_blocked_by"' "$LOG")" -eq 4 ]
  [ "$(grep '"op":"add_blocked_by"' "$LOG" | jq -c 'select(.issue==587)' | wc -l)" -eq 2 ]
}

@test "the materialized sub-issue body carries the proposed_story title + acceptance criteria" {
  apply_dry "$PLAN_ACCEPTED"
  body="$(grep '"op":"create_issue"' "$LOG" | jq -r 'select(.title|test("Held-out-set hygiene")) | .body')"
  [[ "$body" == *"## Acceptance Criteria"* ]]
  [[ "$body" == *"proposer-visible dev set"* ]]
}

# ---------------------------------------------------------------------------
# AC3 — gate until accepted: an un-accepted finding gates like a #600 question
# ---------------------------------------------------------------------------

@test "an un-accepted proposed_story finding gates: apply-plan creates ZERO issues" {
  jq '.open_questions = [{"question":"[eval_safeguards] missing held-out split","affected_story_ids":[1],"blocking":true,"proposed_story":{"title":"[Phase 1] Add a held-out split","acceptance_criteria":["dev/test split exists"]},"proposed_blocked_by":587}]' \
    "$PLAN_581" > "$TMP/pending.json"
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=572 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/pending.json" \
    run bash "$APPLY"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"op":"create_issue"' "$LOG" || true)" -eq 0 ]
  [ "$(grep -c '"op":"add_sub_issue"' "$LOG" || true)" -eq 0 ]
  [ "$(grep -c '"op":"add_blocked_by"' "$LOG" || true)" -eq 0 ]
}

@test "an un-accepted proposed_story finding posts 'not yet planned' back to the discussion" {
  jq '.open_questions = [{"question":"[eval_safeguards] missing held-out split","affected_story_ids":[1],"blocking":true,"proposed_story":{"title":"[Phase 1] Add a held-out split","acceptance_criteria":["dev/test split exists"]},"proposed_blocked_by":587}]' \
    "$PLAN_581" > "$TMP/pending.json"
  apply_dry "$TMP/pending.json"
  body="$(grep '"op":"comment_on_discussion"' "$LOG" | jq -r '.body')"
  [[ "$body" == *"Not yet planned"* ]]
  [[ "$body" == *"missing held-out split"* ]]
}

# ---------------------------------------------------------------------------
# AC4 — human gate preserved: never auto; epic stays inert
# ---------------------------------------------------------------------------

@test "materialization NEVER applies initiative:auto to any created issue" {
  apply_dry "$PLAN_ACCEPTED"
  created_labels="$(grep '"op":"create_issue"' "$LOG" | jq -r '.labels[]')"
  ! grep -qx 'initiative:auto' <<<"$created_labels"
}

@test "flipping accepted to false re-gates the finding (no materialization)" {
  jq '(.open_questions[] | select(has("proposed_story"))).accepted = false' \
    "$PLAN_ACCEPTED" > "$TMP/unaccepted.json"
  apply_dry "$TMP/unaccepted.json"
  # both findings are blocking:true & now accepted:false -> gate, create nothing
  [ "$(grep -c '"op":"create_issue"' "$LOG" || true)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC5 — #581 regression fixture: two findings round-trip into two sub-issues +
#       blocked_by edges onto the Phase-3 proposer story (#587)
# ---------------------------------------------------------------------------

@test "#581: finding-1 (held-out hygiene) + finding-2 (case-immutability) both materialize" {
  apply_dry "$PLAN_ACCEPTED"
  grep '"op":"create_issue"' "$LOG" | jq -e 'select(.title|test("Held-out-set hygiene"))' >/dev/null
  grep '"op":"create_issue"' "$LOG" | jq -e 'select(.title|test("case-immutability"))' >/dev/null
}

@test "#581: each materialized story is wired as a native blocked_by edge onto #587" {
  apply_dry "$PLAN_ACCEPTED"
  # resolve the two materialized story numbers from their create_issue ops
  n1="$(grep '"op":"create_issue"' "$LOG" | jq -r 'select(.title|test("Held-out-set hygiene")) | .number')"
  n2="$(grep '"op":"create_issue"' "$LOG" | jq -r 'select(.title|test("case-immutability")) | .number')"
  [ -n "$n1" ] && [ -n "$n2" ]
  # #587 becomes blocked_by each new story (the new stories must land first)
  grep '"op":"add_blocked_by"' "$LOG" | jq -e --argjson n "$n1" 'select(.issue==587 and .blocked_by==$n)' >/dev/null
  grep '"op":"add_blocked_by"' "$LOG" | jq -e --argjson n "$n2" 'select(.issue==587 and .blocked_by==$n)' >/dev/null
}

# ---------------------------------------------------------------------------
# AC6 — no-op safety: zero accepted findings => zero materialization ops
# ---------------------------------------------------------------------------

@test "a plan with zero accepted proposed_story findings produces zero materialization ops" {
  # plan-581.json has no open_questions at all -> clean no-op for materialization
  apply_dry "$PLAN_581"
  # base only: epic + 3 stories, 2 intra-plan edges; no edge references #587
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 4 ]
  [ "$(grep '"op":"add_blocked_by"' "$LOG" | jq -c 'select(.issue==587)' | wc -l)" -eq 0 ]
}

@test "a plan with only advisory (non-accepted, non-blocking) findings materializes nothing extra" {
  jq '.open_questions = [{"question":"advisory: consider a held-out split later","affected_story_ids":[1],"blocking":false}]' \
    "$PLAN_581" > "$TMP/advisory.json"
  apply_dry "$TMP/advisory.json"
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 4 ]
  [ "$(grep '"op":"add_blocked_by"' "$LOG" | jq -c 'select(.issue==587)' | wc -l)" -eq 0 ]
}
