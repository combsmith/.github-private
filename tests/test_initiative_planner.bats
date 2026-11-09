#!/usr/bin/env bats
# Tests for the initiative-planner tooling (scripts/initiative-planner/).
# The DRY_RUN path touches no network, so the full apply-plan flow runs offline.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PLANNER_DIR="$ROOT/scripts/initiative-planner"
  TMP="$(mktemp -d)"
  PLAN="$TMP/plan.json"
  LOG="$TMP/dry.jsonl"
  cat >"$PLAN" <<'JSON'
{
  "source_discussion": 413,
  "epic": { "title": "Initiative: wire new model tiers", "body": "Epic body long enough to pass schema minimums." },
  "stories": [
    { "id": 1, "title": "[Phase 1] Fix inert tier routing",
      "user_story": { "role": "dev-lead operator", "action": "the engine to route by task complexity", "benefit": "higher tiers run only when warranted" },
      "acceptance_criteria": ["engine.sh routes by complexity", "rate-limit failover detected"],
      "tasks": [ { "task": "Route writer calls by complexity", "ac_refs": [1], "subtasks": ["map intent to tier"] }, { "task": "Restore failover detection", "ac_refs": [2] } ],
      "dev_notes": ["Routing is inert today; all intents hit ENGINE_ACTION_MODEL", "Testing: extend tests/model_pricing.bats"],
      "target_surface": ["scripts/engine.sh"], "size": "M", "blocked_by": [], "blocked_by_existing_issues": [195] },
    { "id": 2, "title": "[Phase 2] Wire Opus 4.8 behind fallback",
      "user_story": { "role": "dev-lead operator", "action": "Opus 4.8 wired behind a per-tier fallback", "benefit": "the audit tier uses the strongest model with a safe fallback" },
      "acceptance_criteria": ["AUDIT tier offers opus-4-8"],
      "tasks": [ { "task": "Add opus-4-8 to the AUDIT chain", "ac_refs": [1] } ],
      "dev_notes": ["Add to CLAUDE_AUDIT_MODEL_CHAIN with fallback to 4.7"],
      "size": "S", "blocked_by": [1] },
    { "id": 3, "title": "[Phase 2] Human ring-0 soak sign-off",
      "user_story": { "role": "release manager", "action": "to sign off after a ring-0 soak", "benefit": "promotion is gated on proven health" },
      "acceptance_criteria": ["soak window documented"],
      "tasks": [ { "task": "Document and run the soak window" } ],
      "dev_notes": ["Manual gate; no auto-release"],
      "size": "S", "blocked_by": [2], "hands_off": true }
  ],
  "open_questions": ["Confirm Fable 5 pricing before wiring the apex tier."]
}
JSON
}

teardown() { rm -rf "$TMP"; }

@test "validate-plan accepts a well-formed acyclic plan" {
  run python3 "$PLANNER_DIR/validate-plan.py" "$PLAN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan OK"* ]]
}

@test "validate-plan accepts open_questions carrying a blocking flag" {
  jq '.open_questions = [{"question":"Confirm scope X before planning","blocking":true}]' "$PLAN" >"$TMP/oqobj.json"
  run python3 "$PLANNER_DIR/validate-plan.py" "$TMP/oqobj.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan OK"* ]]
}

@test "validate-plan grounding: accepts real cited paths (with #anchor stripped)" {
  jq '.stories[0].references = ["scripts/engine.sh#tier-routing", "AGENTS.md#standards"]' "$PLAN" >"$TMP/grounded.json"
  run python3 "$PLANNER_DIR/validate-plan.py" "$TMP/grounded.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan OK"* ]]
}

@test "validate-plan grounding: rejects a story citing a nonexistent path" {
  jq '.stories[0].target_surface = ["scripts/phantom-does-not-exist.sh"]' "$PLAN" >"$TMP/phantom.json"
  run python3 "$PLANNER_DIR/validate-plan.py" "$TMP/phantom.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"story 1"* ]]
  [[ "$output" == *"scripts/phantom-does-not-exist.sh"* ]]
}

@test "validate-plan grounding: prose citations (URL, bare discussion ref) are not treated as paths" {
  jq '.stories[0].references = ["https://example.com/spec", "discussion #593", "see the design doc"]' "$PLAN" >"$TMP/prose.json"
  run python3 "$PLANNER_DIR/validate-plan.py" "$TMP/prose.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan OK"* ]]
}

@test "validate-plan grounding: prose with embedded slash is not treated as a path" {
  jq '.stories[0].references = ["see section/paragraph 2", "refer to chapter/verse 3 here"]' "$PLAN" >"$TMP/prose_slash.json"
  run python3 "$PLANNER_DIR/validate-plan.py" "$TMP/prose_slash.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan OK"* ]]
}

@test "validate-plan grounding: leading-slash path is resolved relative to repo root" {
  jq '.stories[0].references = ["/scripts/engine.sh", "/AGENTS.md"]' "$PLAN" >"$TMP/leadslash.json"
  run python3 "$PLANNER_DIR/validate-plan.py" "$TMP/leadslash.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan OK"* ]]
}

@test "validate-plan rejects a self-blocking story" {
  jq '.stories[0].blocked_by = [1]' "$PLAN" >"$TMP/bad.json"
  run python3 "$PLANNER_DIR/validate-plan.py" "$TMP/bad.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blocks itself"* ]]
}

@test "validate-plan rejects a dependency cycle (with an entry point present)" {
  jq '.stories[1].blocked_by = [3] | .stories[2].blocked_by = [2]' "$PLAN" >"$TMP/cycle.json"
  run python3 "$PLANNER_DIR/validate-plan.py" "$TMP/cycle.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cycle"* ]]
}

@test "validate-plan rejects a dangling blocked_by reference" {
  jq '.stories[1].blocked_by = [99]' "$PLAN" >"$TMP/dangle.json"
  run python3 "$PLANNER_DIR/validate-plan.py" "$TMP/dangle.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a story id"* ]]
}

@test "validate-plan rejects a plan with no entry point" {
  jq '.stories[0].blocked_by = [2]' "$PLAN" | jq '.stories[1].blocked_by = [1]' >"$TMP/noentry.json"
  run python3 "$PLANNER_DIR/validate-plan.py" "$TMP/noentry.json"
  [ "$status" -ne 0 ]
}

@test "apply-plan (DRY_RUN) creates epic + stories + edges and posts comment" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    run bash "$PLANNER_DIR/apply-plan.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 4 ]
  [ "$(grep -c '"op":"add_sub_issue"' "$LOG")" -eq 3 ]
  [ "$(grep -c '"op":"add_blocked_by"' "$LOG")" -eq 3 ]
  grep -q '"op":"comment_on_discussion"' "$LOG"
}

@test "apply-plan threads distinct issue numbers in dry-run" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    bash "$PLANNER_DIR/apply-plan.sh"
  # 4 distinct synthetic issue numbers (epic + 3 stories), not all the same
  distinct="$(grep '"op":"create_issue"' "$LOG" | jq -r '.number' | sort -u | wc -l)"
  [ "$distinct" -eq 4 ]
}

@test "apply-plan NEVER applies initiative:auto to any created issue" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    bash "$PLANNER_DIR/apply-plan.sh"
  created_labels="$(grep '"op":"create_issue"' "$LOG" | jq -r '.labels[]')"
  ! grep -qx 'initiative:auto' <<<"$created_labels"
}

@test "apply-plan marks hands_off story with hold + hands-off labels" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    bash "$PLANNER_DIR/apply-plan.sh"
  grep '"op":"create_issue"' "$LOG" | grep -q 'dev-lead:hands-off'
  grep '"op":"create_issue"' "$LOG" | grep -q 'initiative:hold'
}

@test "existing-issue prerequisite edge references the real issue number" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    bash "$PLANNER_DIR/apply-plan.sh"
  grep '"op":"add_blocked_by"' "$LOG" | grep -q '"blocked_by":195'
}

@test "apply-plan gates on a blocking open question: creates zero issues and exits 0" {
  jq '.open_questions = [{"question":"Confirm scope X before planning","blocking":true}]' "$PLAN" >"$TMP/blocking.json"
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/blocking.json" \
    run bash "$PLANNER_DIR/apply-plan.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 0 ]
  [ "$(grep -c '"op":"add_sub_issue"' "$LOG")" -eq 0 ]
  [ "$(grep -c '"op":"add_blocked_by"' "$LOG")" -eq 0 ]
}

@test "apply-plan blocking gate posts the open questions back to the discussion" {
  jq '.open_questions = [{"question":"Confirm scope X before planning","blocking":true}]' "$PLAN" >"$TMP/blocking.json"
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/blocking.json" \
    bash "$PLANNER_DIR/apply-plan.sh"
  grep -q '"op":"comment_on_discussion"' "$LOG"
  body="$(grep '"op":"comment_on_discussion"' "$LOG" | jq -r '.body')"
  [[ "$body" == *"Confirm scope X before planning"* ]]
  [[ "$body" == *"Not yet planned"* ]]
  [[ "$body" == *"No epic or stories were created"* ]]
}

@test "apply-plan does NOT gate on a non-blocking open question" {
  jq '.open_questions = [{"question":"Nice to confirm pricing later","blocking":false}]' "$PLAN" >"$TMP/nonblock.json"
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/nonblock.json" \
    bash "$PLANNER_DIR/apply-plan.sh"
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 4 ]
}

@test "apply-plan skips creation when an epic already exists for the discussion" {
  # DRY_RUN_EXISTING_EPIC simulates find_existing_epic finding a prior epic
  # offline (the idempotency guard); no issues must be created.
  DRY_RUN=1 DRY_RUN_LOG="$LOG" DRY_RUN_EXISTING_EPIC=777 \
    REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    run bash "$PLANNER_DIR/apply-plan.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already planned (epic #777)"* ]]
  # zero mutations of any kind
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 0 ]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"add_sub_issue"' "$LOG")" -eq 0 ]
}

@test "apply-plan still creates the full DAG when no existing epic is found" {
  # No DRY_RUN_EXISTING_EPIC => find_existing_epic returns empty => normal path.
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    run bash "$PLANNER_DIR/apply-plan.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 4 ]
}

@test "epic body carries the Untracked prerequisites checklist when the array is present" {
  jq '.epic.untracked_prerequisites = ["Resolve the data-retention discussion", "Provision the staging cluster"]' "$PLAN" >"$TMP/prereqs.json"
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/prereqs.json" \
    bash "$PLANNER_DIR/apply-plan.sh"
  epic_body="$(grep '"op":"create_issue"' "$LOG" | jq -r 'select(.title|startswith("Initiative:")) | .body')"
  [[ "$epic_body" == *"## Untracked prerequisites"* ]]
  [[ "$epic_body" == *"- [ ] Resolve the data-retention discussion"* ]]
  [[ "$epic_body" == *"- [ ] Provision the staging cluster"* ]]
}

@test "Untracked prerequisites section appears before the idempotency footer in the epic body" {
  jq '.epic.untracked_prerequisites = ["Resolve the data-retention discussion"]' "$PLAN" >"$TMP/prereqs_order.json"
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/prereqs_order.json" \
    bash "$PLANNER_DIR/apply-plan.sh"
  epic_body="$(grep '"op":"create_issue"' "$LOG" | jq -r 'select(.title|startswith("Initiative:")) | .body')"
  prereqs_pos="${epic_body%%'## Untracked prerequisites'*}"
  footer_pos="${epic_body%%'Planned from idea discussion'*}"
  # The text before "Untracked prerequisites" must be shorter than the text before the footer,
  # meaning prerequisites come first.
  [[ "${#prereqs_pos}" -lt "${#footer_pos}" ]]
}

@test "epic body omits the Untracked prerequisites section when the array is absent" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    bash "$PLANNER_DIR/apply-plan.sh"
  epic_body="$(grep '"op":"create_issue"' "$LOG" | jq -r 'select(.title|startswith("Initiative:")) | .body')"
  [[ "$epic_body" != *"Untracked prerequisites"* ]]
}

@test "story bodies are rendered in the BMAD create-story template" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    bash "$PLANNER_DIR/apply-plan.sh"
  # the rendered Phase-1 story body carries the canonical BMAD sections
  body="$(grep '"op":"create_issue"' "$LOG" | jq -r 'select(.title|startswith("[Phase 1]")) | .body')"
  [[ "$body" == *"## Story"* ]]
  [[ "$body" == *"As a dev-lead operator,"* ]]
  [[ "$body" == *"## Acceptance Criteria"* ]]
  [[ "$body" == *"## Tasks / Subtasks"* ]]
  [[ "$body" == *"(AC: #1)"* ]]
  [[ "$body" == *"## Dev Notes"* ]]
  [[ "$body" == *"Status: ready-for-dev"* ]]
}

@test "idempotency skip posts an 'already planned' discussion comment with a force_replan hint" {
  DRY_RUN_EXISTING_EPIC=727 \
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    run bash "$PLANNER_DIR/apply-plan.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 0 ]
  [ "$(grep -c '"op":"add_sub_issue"' "$LOG")" -eq 0 ]
  [ "$(grep -c '"op":"close_issue"' "$LOG")" -eq 0 ]
  body="$(grep '"op":"comment_on_discussion"' "$LOG" | jq -r '.body')"
  [[ "$body" == *"Already planned"* ]]
  [[ "$body" == *"#727"* ]]
  [[ "$body" == *"force_replan"* ]]
}

@test "force_replan supersedes: creates the new plan AND closes the old epic + sub-issues" {
  DRY_RUN_EXISTING_EPIC=727 DRY_RUN_EXISTING_SUBISSUES="728 729 730" FORCE_REPLAN=1 \
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    run bash "$PLANNER_DIR/apply-plan.sh"
  [ "$status" -eq 0 ]
  # the fresh epic + 3 stories are still created
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 4 ]
  # old epic (727) + its 3 sub-issues are closed
  [ "$(grep -c '"op":"close_issue"' "$LOG")" -eq 4 ]
  closed="$(grep '"op":"close_issue"' "$LOG" | jq -r '.number' | sort -n | tr '\n' ' ')"
  [[ "$closed" == "727 728 729 730 "* ]]
  epic_close="$(grep '"op":"close_issue"' "$LOG" | jq -r 'select(.number==727) | .comment')"
  [[ "$epic_close" == *"Superseded by"* ]]
}

@test "force_replan with no existing epic just plans normally (nothing to supersede)" {
  FORCE_REPLAN=1 \
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    run bash "$PLANNER_DIR/apply-plan.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 4 ]
  [ "$(grep -c '"op":"close_issue"' "$LOG")" -eq 0 ]
}

# ── cross-repo target_repo parameterization (#819) ────────────────────────────
# The central planner can plan for a NON-self target repo: context is gathered
# from, and the epic is created in, that target repo. The scripts already take
# REPO; these assert REPO threads through to the gh/GraphQL calls for a target
# repo that is NOT .github-private. gh is stubbed so no network is touched.

@test "gather-context gathers context FROM the target repo (non-self)" {
  MOCK_BIN="$TMP/mock_bin_gather"
  mkdir -p "$MOCK_BIN"
  GH_LOG="$TMP/gh.log"
  export GH_LOG
  export PATH="$MOCK_BIN:$PATH"
  cat >"$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *graphql*) echo '{"data":{"repository":{"discussion":{"id":"D_target","title":"Idea","body":"no refs here","url":"http://x","category":{"name":"Ideas"},"comments":{"nodes":[]}}}}}' ;;
  *"issue list"*) echo '[]' ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"

  CTX="$TMP/context.json"
  GITHUB_ENV="$TMP/gh.env" REPO="acme/widgets" DISCUSSION_NUMBER=413 \
    CONTEXT_PATH="$CTX" GH_TOKEN=x \
    run bash "$PLANNER_DIR/gather-context.sh"
  [ "$status" -eq 0 ]
  # GraphQL discussion query targets the target repo's owner/name.
  grep -qF -- "owner=acme" "$GH_LOG"
  grep -qF -- "name=widgets" "$GH_LOG"
  # Open-epics lookup runs against the target repo, not .github-private.
  grep -qF -- "--repo acme/widgets" "$GH_LOG"
  ! grep -qF -- ".github-private" "$GH_LOG" || false
  # The assembled context records the target repo.
  [ "$(jq -r '.repo' "$CTX")" = "acme/widgets" ]
}

@test "apply-plan creates the epic IN the target repo (non-self, live)" {
  MOCK_BIN="$TMP/mock_bin_apply"
  mkdir -p "$MOCK_BIN"
  GH_LOG="$TMP/gh.log"
  export GH_LOG
  export PATH="$MOCK_BIN:$PATH"
  cat >"$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *"issue list"*) echo '[]' ;;
  *graphql*) echo '{}' ;;
  *) echo '{"number":1,"id":1}' ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"

  # Live path (no DRY_RUN): create_issue POSTs to repos/<target>/issues.
  REPO="acme/widgets" DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" \
    PLAN_PATH="$PLAN" GH_TOKEN=x \
    run bash "$PLANNER_DIR/apply-plan.sh"
  [ "$status" -eq 0 ]
  grep -qF -- "api repos/acme/widgets/issues" "$GH_LOG"
  ! grep -qF -- "repos/combsmith/.github-private/issues" "$GH_LOG"
}

# ── cross-repo Discussion + planning artifacts (graduation) ───────────────────
# An incubator idea graduates into a product repo: the Discussion lives in
# DISCUSSION_REPO (the incubator), the epic and planning artifacts in REPO. gh is
# stubbed; the stub logs every call and serves the artifacts folder per test via
# ART_MODE (present | empty | 404 | 500).

_gather_mock() {
  MOCK_BIN="$TMP/mock_bin_ctx"
  mkdir -p "$MOCK_BIN"
  GH_LOG="$TMP/gh.log"
  export GH_LOG
  export PATH="$MOCK_BIN:$PATH"
  cat >"$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *graphql*) echo '{"data":{"repository":{"discussion":{"id":"D_incubator5","title":"WorldChest","body":"Builds on #12","url":"http://x","category":{"name":"Ideas"},"comments":{"nodes":[]}}}}}' ;;
  *"issue list"*) echo '[]' ;;
  *"/issues/12"*) echo '{"repo":"combsmith/incubator","number":12,"title":"Spike","state":"open"}' ;;
  *"planning-artifacts/prd.md"*) printf 'PRD-START\nFR1: back up worlds\nSuccess metric: 100 weekly backups\n%s\nPRD-END\n' "$(printf 'p%.0s' $(seq 1 300))" ;;
  *"planning-artifacts/brief.md"*) printf 'BRIEF-START %s BRIEF-END\n' "$(printf 'b%.0s' $(seq 1 300))" ;;
  *"planning-artifacts"*)
    case "${ART_MODE:-present}" in
      present) echo '[{"name":"brief.md","path":"_bmad-output/planning-artifacts/brief.md","type":"file"},{"name":"prd.md","path":"_bmad-output/planning-artifacts/prd.md","type":"file"},{"name":"diagram.png","path":"_bmad-output/planning-artifacts/diagram.png","type":"file"},{"name":"research","path":"_bmad-output/planning-artifacts/research","type":"dir"}]' ;;
      empty) echo '[]' ;;
      404) echo '{"message":"Not Found","status":"404"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
      *) echo 'gh: Server Error (HTTP 500)' >&2; exit 1 ;;
    esac ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"
  CTX="$TMP/context.json"
}

@test "gather-context reads the Discussion from DISCUSSION_REPO but plans INTO REPO (cross-repo)" {
  _gather_mock
  ART_MODE=empty GITHUB_ENV="$TMP/gh.env" REPO="combsmith/worldchest" DISCUSSION_REPO="combsmith/incubator" \
    DISCUSSION_NUMBER=5 CONTEXT_PATH="$CTX" GH_TOKEN=x RECONCILE=1 \
    run bash "$PLANNER_DIR/gather-context.sh"
  [ "$status" -eq 0 ]
  # The Discussion query (and the issues it references) hit the incubator ...
  # (the GraphQL query is multi-line in the log, so match its -F args directly)
  grep -qF -- "name=incubator" "$GH_LOG"
  grep -qF -- "repos/combsmith/incubator/issues/12" "$GH_LOG"
  # ... while open epics, the reconcile back-reference and artifacts hit the product repo.
  grep -F -- "issue list" "$GH_LOG" | grep -qF -- "--repo combsmith/worldchest"
  grep -qF -- 'Planned from idea discussion combsmith/incubator#5' "$GH_LOG"
  grep -qF -- "repos/combsmith/worldchest/contents/_bmad-output/planning-artifacts" "$GH_LOG"
  run grep -F -- "--repo combsmith/incubator" "$GH_LOG"
  [ "$status" -ne 0 ]
  [ "$(jq -r '.repo' "$CTX")" = "combsmith/worldchest" ]
  [ "$(jq -r '.discussion_repo' "$CTX")" = "combsmith/incubator" ]
  [ "$(jq -r '.referenced_issues[0].repo' "$CTX")" = "combsmith/incubator" ]
  grep -qx 'DISCUSSION_NODE_ID=D_incubator5' "$TMP/gh.env"
}

@test "apply-plan (cross-repo) back-references the incubator Discussion and posts the reply there" {
  jq '.source_discussion = 5' "$PLAN" >"$TMP/xrepo.json"
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/worldchest" DISCUSSION_REPO="combsmith/incubator" \
    DISCUSSION_NUMBER=5 DISCUSSION_NODE_ID="D_incubator5" PLAN_PATH="$TMP/xrepo.json" \
    run bash "$PLANNER_DIR/apply-plan.sh"
  [ "$status" -eq 0 ]
  epic_body="$(grep '"op":"create_issue"' "$LOG" | jq -r 'select(.title|startswith("Initiative:")) | .body')"
  [[ "$epic_body" == *"Planned from idea discussion combsmith/incubator#5"* ]]
  [ "$(grep '"op":"comment_on_discussion"' "$LOG" | jq -r '.discussion_repo')" = "combsmith/incubator" ]
  [ "$(grep '"op":"comment_on_discussion"' "$LOG" | jq -r '.discussion_id')" = "D_incubator5" ]
  # Issue links in the incubator-side comment are qualified with the product repo.
  body="$(grep '"op":"comment_on_discussion"' "$LOG" | jq -r '.body')"
  [[ "$body" == *"Epic **combsmith/worldchest#"* ]]
  [[ "$body" == *"- combsmith/worldchest#"* ]]
}

@test "apply-plan (same-repo) keeps the bare #N back-reference and unqualified links" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    run bash "$PLANNER_DIR/apply-plan.sh"
  [ "$status" -eq 0 ]
  epic_body="$(grep '"op":"create_issue"' "$LOG" | jq -r 'select(.title|startswith("Initiative:")) | .body')"
  [[ "$epic_body" == *"Planned from idea discussion #413 by"* ]]
  [ "$(grep '"op":"comment_on_discussion"' "$LOG" | jq -r '.discussion_repo')" = "combsmith/.github-private" ]
  body="$(grep '"op":"comment_on_discussion"' "$LOG" | jq -r '.body')"
  [[ "$body" == *"Epic **#"* ]]
}

@test "gather-context includes planning artifacts: prd.md in full, other markdown truncated" {
  _gather_mock
  ART_MODE=present PLANNING_ARTIFACT_MAX_CHARS=50 GITHUB_ENV="$TMP/gh.env" REPO="combsmith/worldchest" \
    DISCUSSION_NUMBER=6 CONTEXT_PATH="$CTX" GH_TOKEN=x \
    run bash "$PLANNER_DIR/gather-context.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.planning_artifacts.dir' "$CTX")" = "_bmad-output/planning-artifacts" ]
  [ "$(jq -r '.planning_artifacts.prd' "$CTX")" = "_bmad-output/planning-artifacts/prd.md" ]
  # prd.md sorts first and is complete, well past the 50-char cap.
  [ "$(jq -r '.planning_artifacts.files[0].name' "$CTX")" = "prd.md" ]
  [ "$(jq -r '.planning_artifacts.files[0].truncated' "$CTX")" = "false" ]
  prd="$(jq -r '.planning_artifacts.files[0].content' "$CTX")"
  [[ "$prd" == *"FR1: back up worlds"* ]]
  [[ "$prd" == *"PRD-END"* ]]
  # brief.md is cut to the cap and flagged.
  [ "$(jq -r '.planning_artifacts.files[1].name' "$CTX")" = "brief.md" ]
  [ "$(jq -r '.planning_artifacts.files[1].truncated' "$CTX")" = "true" ]
  [ "$(jq -r '.planning_artifacts.files[1].content | length' "$CTX")" -eq 50 ]
  [ "$(jq '.planning_artifacts.files[1].chars > 50' "$CTX")" = "true" ]
  # Non-markdown entries are listed as skipped, not read.
  [ "$(jq -c '.planning_artifacts.skipped' "$CTX")" = '["diagram.png","research"]' ]
  run grep -F -- "diagram.png" "$GH_LOG"
  [ "$status" -ne 0 ]
  [ "$(grep -c 'contents/_bmad-output/planning-artifacts/' "$GH_LOG")" -eq 2 ]
  # Raw fetch, so content is never base64 and never rides on argv.
  grep -F -- "planning-artifacts/prd.md" "$GH_LOG" | grep -qF -- "application/vnd.github.raw"
}

@test "gather-context without planning artifacts keeps the prior context unchanged (null)" {
  _gather_mock
  ART_MODE=empty GITHUB_ENV="$TMP/gh.env" REPO="acme/widgets" \
    DISCUSSION_NUMBER=413 CONTEXT_PATH="$CTX" GH_TOKEN=x \
    run bash "$PLANNER_DIR/gather-context.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.planning_artifacts' "$CTX")" = "null" ]
  # Same-repo default: the Discussion is read from REPO itself.
  [ "$(jq -r '.discussion_repo' "$CTX")" = "acme/widgets" ]
  grep -qF -- "name=widgets" "$GH_LOG"
  [ "$(jq -c 'keys' "$CTX")" = '["discussion","discussion_repo","open_epics","planning_artifacts","reconcile","referenced_issues","repo"]' ]
  [ "$(jq -r '.discussion.title' "$CTX")" = "WorldChest" ]
}

@test "gather-context treats a 404 on the planning-artifacts folder as no artifacts" {
  _gather_mock
  ART_MODE=404 GITHUB_ENV="$TMP/gh.env" REPO="acme/widgets" \
    DISCUSSION_NUMBER=413 CONTEXT_PATH="$CTX" GH_TOKEN=x \
    run bash "$PLANNER_DIR/gather-context.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"planning from the Discussion only"* ]]
  [ "$(jq -r '.planning_artifacts' "$CTX")" = "null" ]
  [ "$(jq -r '.discussion.title' "$CTX")" = "WorldChest" ]
}

@test "gather-context fails loud on a non-404 error listing planning artifacts" {
  _gather_mock
  ART_MODE=500 GITHUB_ENV="$TMP/gh.env" REPO="acme/widgets" \
    DISCUSSION_NUMBER=413 CONTEXT_PATH="$CTX" GH_TOKEN=x \
    run bash "$PLANNER_DIR/gather-context.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to list _bmad-output/planning-artifacts in acme/widgets"* ]]
}

@test "gather-context rejects a malformed DISCUSSION_REPO before any API call" {
  _gather_mock
  GITHUB_ENV="$TMP/gh.env" REPO="acme/widgets" DISCUSSION_REPO="not a repo" \
    DISCUSSION_NUMBER=413 CONTEXT_PATH="$CTX" GH_TOKEN=x \
    run bash "$PLANNER_DIR/gather-context.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"DISCUSSION_REPO must be owner/repo"* ]]
  [ ! -s "$GH_LOG" ]
}

@test "initiative-planner.yml exposes discussion_repo and threads it to DISCUSSION_REPO + apply-plan" {
  PLANNER_YML="$ROOT/.github/workflows/initiative-planner.yml"
  [ "$(yq '.on.workflow_dispatch.inputs.discussion_repo.required' "$PLANNER_YML")" = "false" ]
  [ "$(yq '.on.workflow_dispatch.inputs.discussion_repo.default' "$PLANNER_YML")" = "" ]
  [ "$(yq '.jobs.plan.env.DISCUSSION_REPO' "$PLANNER_YML")" = "\${{ github.event.inputs.discussion_repo || github.event.inputs.target_repo || github.repository }}" ]
  yq '.jobs.plan.steps[] | select(.id == "bob") | .with.prompt' "$PLANNER_YML" | grep -qF 'DISCUSSION_REPO="$DISCUSSION_REPO"'
  # A cross-repo Discussion must not fall back to the self-scoped GITHUB_TOKEN.
  yq '.jobs.plan.env.TARGET_GH_TOKEN' "$PLANNER_YML" | grep -qF "github.event.inputs.discussion_repo == github.repository"
}

# ── reviewed-plan apply path (#604) ───────────────────────────────────────────
# apply-reviewed-plan.sh is the no-re-plan handoff: a maintainer-reviewed plan.json
# is validated then handed straight to apply-plan.sh — no LLM planning step runs.

@test "apply-reviewed-plan validates then applies the supplied plan (DRY_RUN)" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    run bash "$PLANNER_DIR/apply-reviewed-plan.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan OK"* ]]
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 4 ]
  [ "$(grep -c '"op":"add_sub_issue"' "$LOG")" -eq 3 ]
  [ "$(grep -c '"op":"add_blocked_by"' "$LOG")" -eq 3 ]
}

@test "apply-reviewed-plan rejects an invalid supplied plan before applying anything" {
  jq '.stories[1].blocked_by = [3] | .stories[2].blocked_by = [2]' "$PLAN" >"$TMP/cycle.json"
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/cycle.json" \
    run bash "$PLANNER_DIR/apply-reviewed-plan.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cycle"* ]]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 0 ]
}

@test "apply-reviewed-plan errors on a missing supplied plan file" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/does-not-exist.json" \
    run bash "$PLANNER_DIR/apply-reviewed-plan.sh"
  [ "$status" -ne 0 ]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 0 ]
}

@test "apply-reviewed-plan errors when PLAN_PATH is a directory, not a regular file" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP" \
    run bash "$PLANNER_DIR/apply-reviewed-plan.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a regular file"* ]]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 0 ]
}

@test "apply-reviewed-plan honors the blocking open-questions gate from apply-plan" {
  jq '.open_questions = [{"question":"Confirm scope X before planning","blocking":true}]' "$PLAN" >"$TMP/blocking.json"
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/blocking.json" \
    run bash "$PLANNER_DIR/apply-reviewed-plan.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 0 ]
}

@test "apply-reviewed-plan rejects a plan whose source_discussion mismatches DISCUSSION_NUMBER" {
  # plan.json carries source_discussion:413; dispatcher says 999 — must abort before creating anything.
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=999 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    run bash "$PLANNER_DIR/apply-reviewed-plan.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"source_discussion"* ]]
  [[ "$output" == *"413"* ]]
  [[ "$output" == *"999"* ]]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 0 ]
}

@test "apply-reviewed-plan passes when source_discussion matches DISCUSSION_NUMBER" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    run bash "$PLANNER_DIR/apply-reviewed-plan.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 4 ]
}

@test "apply-reviewed-plan rejects plans without source_discussion field" {
  # Reviewed plans must have an explicit source_discussion — they are applied
  # out-of-band and must be self-contained about their origin.
  jq 'del(.source_discussion)' "$PLAN" >"$TMP/no_src.json"
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="combsmith/.github-private" \
    DISCUSSION_NUMBER=999 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/no_src.json" \
    run bash "$PLANNER_DIR/apply-reviewed-plan.sh"
  [ "$status" -ne 0 ]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 0 ]
}
