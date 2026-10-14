#!/usr/bin/env bats
# Tests for reconcile-in-place: re-running the initiative-planner against a LIVE
# epic to add only the work that has newly surfaced (issue #708, epic #597
# Phase 3). This is the execution-time companion to #706: where #706 materializes
# accepted plan-critic findings at PLAN time, #708 re-triggers the planner against
# an existing epic and routes each newly-harvested proposal through #706's SAME
# finding -> DAG materialization + acceptance path.
#
# RECONCILE=1 turns apply-plan.sh's idempotent "already planned" SKIP into an
# additive pass: it binds to the existing epic (via #598's find_existing_epic),
# skips epic + base-story + base-DAG creation, and materializes ONLY the accepted
# proposed_story findings that are not already present in the epic's DAG. Writes
# are limited to new sub-issues + their edges; base/in-flight stories are never
# recreated, edited, or closed. Everything is proven offline via the DRY_RUN
# mutation log; no new network path is introduced.
#
# Run with: bats tests/test_initiative_reconcile.bats

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  PLANNER_DIR="$ROOT/scripts/initiative-planner"
  APPLY="$PLANNER_DIR/apply-plan.sh"
  PLANNER_YML="$ROOT/.github/workflows/initiative-planner.yml"
  FIXTURE_DIR="$ROOT/tests/fixtures/initiative-planner"
  PLAN_581="$FIXTURE_DIR/plan-581.json"          # no open_questions -> no findings
  PLAN_ACCEPTED="$FIXTURE_DIR/plan-581-accepted.json"  # 2 accepted proposed_story findings
  TMP="$(mktemp -d "${BATS_TEST_TMPDIR}/test-XXXXXX")"
  LOG="$TMP/dry.jsonl"
}

teardown() { rm -rf "$TMP"; }

# reconcile_dry <plan.json> — run apply-plan in RECONCILE mode bound to an
# existing epic (#812 by default), DRY_RUN. Extra DRY_RUN_* stubs may be exported
# by the caller before invoking.
reconcile_dry() {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" RECONCILE=1 \
    DRY_RUN_EXISTING_EPIC="${EPIC:-812}" \
    REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=572 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$1" \
    bash "$APPLY"
}

# one-finding reconcile plan: a follow-up harvested from a sub-issue comment,
# accepted by a maintainer, gating #587.
write_one_finding() { # write_one_finding <dest> <title>
  jq --arg t "$2" '.open_questions = [{
      "question":"[harvest] dev-lead flagged a follow-up in #587 comments",
      "affected_story_ids":[1],
      "blocking":true,
      "accepted":true,
      "proposed_story":{"title":$t,"acceptance_criteria":["the loader rejects an unknown split name"]},
      "proposed_blocked_by":587
    }]' "$PLAN_581" > "$1"
}

# ---------------------------------------------------------------------------
# AC1 — re-trigger on an existing epic: bind, never create a new one
# ---------------------------------------------------------------------------

@test "reconcile binds to the existing epic and creates NO new epic" {
  EPIC=812 run reconcile_dry "$PLAN_ACCEPTED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"binding to existing epic #812"* ]]
  # none of the create_issue ops is the epic itself
  ! grep '"op":"create_issue"' "$LOG" | jq -e 'select(.title|startswith("Initiative:"))' >/dev/null
}

@test "reconcile with no existing epic creates nothing and exits 0 (clean no-op)" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" RECONCILE=1 \
    REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=572 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN_ACCEPTED" \
    run bash "$APPLY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no existing epic"* ]]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"create_issue"' "$LOG" || true)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2 — reconcile, never duplicate or rewrite: base/in-flight stories untouched
# ---------------------------------------------------------------------------

@test "reconcile never recreates, edits, or closes a base/in-flight story" {
  EPIC=812 run reconcile_dry "$PLAN_ACCEPTED"
  [ "$status" -eq 0 ]
  # zero close_issue ops (an in-flight/completed story is never closed)
  [ "$(grep -c '"op":"close_issue"' "$LOG" || true)" -eq 0 ]
  # base stories are never recreated: their titles never appear in create_issue
  ! grep '"op":"create_issue"' "$LOG" | jq -e 'select(.title|test("Held-out eval set"))' >/dev/null
  ! grep '"op":"create_issue"' "$LOG" | jq -e 'select(.title|startswith("[Phase 2] Generalize"))' >/dev/null
  ! grep '"op":"create_issue"' "$LOG" | jq -e 'select(.title|startswith("[Phase 3] Automate"))' >/dev/null
  # only the 2 accepted findings are materialized
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 2 ]
}

# ---------------------------------------------------------------------------
# AC4 — route through #706 + human gate: accepted materializes, un-accepted gates
# ---------------------------------------------------------------------------

@test "reconcile materializes accepted findings via the #706 sub-issue + blocked_by path" {
  EPIC=812 run reconcile_dry "$PLAN_ACCEPTED"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 2 ]
  [ "$(grep -c '"op":"add_sub_issue"' "$LOG")" -eq 2 ]
  [ "$(grep -c '"op":"add_blocked_by"' "$LOG")" -eq 2 ]
  # each materialized story is wired so #587 is blocked_by it (new work lands first)
  [ "$(grep '"op":"add_blocked_by"' "$LOG" | jq -c 'select(.issue==587)' | wc -l)" -eq 2 ]
}

@test "reconcile gates an UN-accepted proposed_story: creates nothing, posts 'not yet planned'" {
  jq '.open_questions = [{
      "question":"[harvest] possible follow-up, not yet accepted",
      "affected_story_ids":[1],
      "blocking":true,
      "proposed_story":{"title":"[Follow-up] Not yet accepted","acceptance_criteria":["something testable"]},
      "proposed_blocked_by":587
    }]' "$PLAN_581" > "$TMP/pending.json"
  EPIC=812 run reconcile_dry "$TMP/pending.json"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"op":"create_issue"' "$LOG" || true)" -eq 0 ]
  [ "$(grep -c '"op":"add_blocked_by"' "$LOG" || true)" -eq 0 ]
  body="$(grep '"op":"comment_on_discussion"' "$LOG" | jq -r '.body')"
  [[ "$body" == *"Not yet planned"* ]]
}

@test "reconcile NEVER applies initiative:auto to any created issue" {
  EPIC=812 run reconcile_dry "$PLAN_ACCEPTED"
  [ "$status" -eq 0 ]
  created_labels="$(grep '"op":"create_issue"' "$LOG" | jq -r '.labels[]')"
  ! grep -qx 'initiative:auto' <<<"$created_labels"
}

# ---------------------------------------------------------------------------
# AC5 — idempotent + bounded: reconcile diff against the existing DAG
# ---------------------------------------------------------------------------

@test "reconcile with no new signal (no accepted findings) is a clean no-op" {
  # plan-581.json has no open_questions -> nothing to reconcile: the mutation log
  # is never even created (guarded like the idempotency-skip tests).
  EPIC=812 run reconcile_dry "$PLAN_581"
  [ "$status" -eq 0 ]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"create_issue"' "$LOG" || true)" -eq 0 ]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"add_sub_issue"' "$LOG" || true)" -eq 0 ]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"add_blocked_by"' "$LOG" || true)" -eq 0 ]
}

@test "reconcile dedups a proposed_story already materialized in the epic (idempotent re-run)" {
  title="[Follow-up] Harden the held-out split loader"
  write_one_finding "$TMP/one.json" "$title"
  # the epic already carries this story's reconcile-key from a prior reconcile run
  key="$(printf '%s' "572::${title}" | sha256sum | cut -d' ' -f1)"
  EPIC=812 DRY_RUN_EXISTING_RECONCILE_KEYS="$key" run reconcile_dry "$TMP/one.json"
  [ "$status" -eq 0 ]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"create_issue"' "$LOG" || true)" -eq 0 ]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"add_blocked_by"' "$LOG" || true)" -eq 0 ]
  [[ "$output" == *"already materialized"* ]]
}

# ---------------------------------------------------------------------------
# AC6 — offline bats coverage
# ---------------------------------------------------------------------------

@test "AC6(a): an epic with one comment-surfaced follow-up yields one sub-issue + one edge" {
  write_one_finding "$TMP/one.json" "[Follow-up] Harden the held-out split loader"
  EPIC=812 run reconcile_dry "$TMP/one.json"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 1 ]
  [ "$(grep -c '"op":"add_sub_issue"' "$LOG")" -eq 1 ]
  [ "$(grep -c '"op":"add_blocked_by"' "$LOG")" -eq 1 ]
  grep '"op":"add_blocked_by"' "$LOG" | jq -e 'select(.issue==587)' >/dev/null
  # the created sub-issue is the harvested follow-up, linked under the bound epic
  grep '"op":"create_issue"' "$LOG" | jq -e 'select(.title|test("Harden the held-out split loader"))' >/dev/null
  grep '"op":"add_sub_issue"' "$LOG" | jq -e 'select(.epic==812)' >/dev/null
}

@test "AC6(b): a re-run with no new signal logs zero create/edge ops" {
  EPIC=812 run reconcile_dry "$PLAN_581"
  [ "$status" -eq 0 ]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"create_issue"' "$LOG" || true)" -eq 0 ]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"add_blocked_by"' "$LOG" || true)" -eq 0 ]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"add_sub_issue"' "$LOG" || true)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Mode guards
# ---------------------------------------------------------------------------

@test "RECONCILE and FORCE_REPLAN together is a hard error (mutually exclusive)" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" RECONCILE=1 FORCE_REPLAN=1 DRY_RUN_EXISTING_EPIC=812 \
    REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=572 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN_ACCEPTED" \
    run bash "$APPLY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"create_issue"' "$LOG" || true)" -eq 0 ]
}

@test "reconcile posts a summary comment naming the newly materialized work" {
  write_one_finding "$TMP/one.json" "[Follow-up] Harden the held-out split loader"
  EPIC=812 run reconcile_dry "$TMP/one.json"
  [ "$status" -eq 0 ]
  body="$(grep '"op":"comment_on_discussion"' "$LOG" | jq -r '.body')"
  [[ "$body" == *"Reconciled"* ]]
  [[ "$body" == *"#812"* ]]
}

# ---------------------------------------------------------------------------
# AC3 — harvest input: gather-context binds the epic and surfaces its
# sub-issues' labels + comments so Bob can pick up comment-flagged follow-ups.
# gh is stubbed (post --jq output) so no network is touched.
# ---------------------------------------------------------------------------

@test "AC3: gather-context under RECONCILE harvests the bound epic's sub-issues + comments" {
  MOCK_BIN="$TMP/mock_bin"; mkdir -p "$MOCK_BIN"
  cat >"$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *graphql*) echo '{"data":{"repository":{"discussion":{"id":"D_572","title":"Idea","body":"no refs","url":"http://x","category":{"name":"Ideas"},"comments":{"nodes":[]}}}}}' ;;
  *"issue list"*"--search"*) echo '[{"number":812,"body":"Planned from idea discussion #572 by Bob"}]' ;;
  *"issue list"*) echo '[]' ;;
  *sub_issues*) echo '{"number":587,"title":"Proposer story","state":"open","labels":["dev-lead"]}' ;;
  *comments*) echo '[{"author":"dev-lead","body":"[harvest] please add a loader-hardening follow-up","createdAt":"2026-07-01T00:00:00Z"}]' ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"
  CTX="$TMP/context.json"
  PATH="$MOCK_BIN:$PATH" GITHUB_ENV="$TMP/gh.env" RECONCILE=1 \
    REPO="petry-projects/.github-private" DISCUSSION_NUMBER=572 \
    CONTEXT_PATH="$CTX" GH_TOKEN=x \
    run bash "$PLANNER_DIR/gather-context.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.reconcile.mode' "$CTX")" = "reconcile" ]
  [ "$(jq -r '.reconcile.epic' "$CTX")" = "812" ]
  [ "$(jq -r '.reconcile.sub_issues | length' "$CTX")" -eq 1 ]
  [ "$(jq -r '.reconcile.sub_issues[0].labels[0]' "$CTX")" = "dev-lead" ]
  [[ "$(jq -r '.reconcile.sub_issues[0].comments[0].body' "$CTX")" == *"loader-hardening follow-up"* ]]
}

@test "AC3: gather-context under RECONCILE with no bound epic harvests nothing (warns, exits 0)" {
  MOCK_BIN="$TMP/mock_bin"; mkdir -p "$MOCK_BIN"
  cat >"$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *graphql*) echo '{"data":{"repository":{"discussion":{"id":"D_572","title":"Idea","body":"no refs","url":"http://x","category":{"name":"Ideas"},"comments":{"nodes":[]}}}}}' ;;
  *"issue list"*) echo '[]' ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"
  CTX="$TMP/context.json"
  PATH="$MOCK_BIN:$PATH" GITHUB_ENV="$TMP/gh.env" RECONCILE=1 \
    REPO="petry-projects/.github-private" DISCUSSION_NUMBER=572 \
    CONTEXT_PATH="$CTX" GH_TOKEN=x \
    run bash "$PLANNER_DIR/gather-context.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no existing epic bound"* ]]
  [ "$(jq -r '.reconcile.epic' "$CTX")" = "null" ]
  [ "$(jq -r '.reconcile.sub_issues | length' "$CTX")" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Workflow wiring — the reconcile input, env threading, and label bridge exist
# ---------------------------------------------------------------------------

@test "initiative-planner.yml exposes a reconcile workflow_dispatch input" {
  [ "$(yq '.on.workflow_dispatch.inputs.reconcile.type' "$PLANNER_YML")" = "boolean" ]
  [ "$(yq '.on.workflow_dispatch.inputs.reconcile.default' "$PLANNER_YML")" = "false" ]
}

@test "initiative-planner.yml threads the reconcile input to a RECONCILE env" {
  [ "$(yq '.jobs.plan.env.RECONCILE' "$PLANNER_YML")" = "\${{ inputs.reconcile == true && '1' || '0' }}" ]
}

@test "initiative-planner.yml redispatch bridge fires on the initiative:reconcile label" {
  yq '.jobs.redispatch.if' "$PLANNER_YML" | grep -qF "initiative:reconcile"
  [ "$(yq '.jobs.redispatch.steps[] | select(.name == "Re-dispatch under workflow_dispatch") | .env.RECONCILE' "$PLANNER_YML")" = "\${{ github.event.label.name == 'initiative:reconcile' && '1' || '0' }}" ]
}

@test "initiative-planner.yml passes RECONCILE into Bob's apply-plan invocation" {
  yq '.jobs.plan.steps[] | select(.id == "bob") | .with.prompt' "$PLANNER_YML" | grep -qF 'RECONCILE="$RECONCILE"'
}

@test "gather-context WITHOUT RECONCILE emits a null reconcile block (no harvest)" {
  MOCK_BIN="$TMP/mock_bin"; mkdir -p "$MOCK_BIN"
  cat >"$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *graphql*) echo '{"data":{"repository":{"discussion":{"id":"D_572","title":"Idea","body":"no refs","url":"http://x","category":{"name":"Ideas"},"comments":{"nodes":[]}}}}}' ;;
  *"issue list"*) echo '[]' ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"
  CTX="$TMP/context.json"
  PATH="$MOCK_BIN:$PATH" GITHUB_ENV="$TMP/gh.env" \
    REPO="petry-projects/.github-private" DISCUSSION_NUMBER=572 \
    CONTEXT_PATH="$CTX" GH_TOKEN=x \
    run bash "$PLANNER_DIR/gather-context.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.reconcile' "$CTX")" = "null" ]
}
