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
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    run bash "$PLANNER_DIR/apply-plan.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 4 ]
  [ "$(grep -c '"op":"add_sub_issue"' "$LOG")" -eq 3 ]
  [ "$(grep -c '"op":"add_blocked_by"' "$LOG")" -eq 3 ]
  grep -q '"op":"comment_on_discussion"' "$LOG"
}

@test "apply-plan threads distinct issue numbers in dry-run" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    bash "$PLANNER_DIR/apply-plan.sh"
  # 4 distinct synthetic issue numbers (epic + 3 stories), not all the same
  distinct="$(grep '"op":"create_issue"' "$LOG" | jq -r '.number' | sort -u | wc -l)"
  [ "$distinct" -eq 4 ]
}

@test "apply-plan NEVER applies initiative:auto to any created issue" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    bash "$PLANNER_DIR/apply-plan.sh"
  created_labels="$(grep '"op":"create_issue"' "$LOG" | jq -r '.labels[]')"
  ! grep -qx 'initiative:auto' <<<"$created_labels"
}

@test "apply-plan marks hands_off story with hold + hands-off labels" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    bash "$PLANNER_DIR/apply-plan.sh"
  grep '"op":"create_issue"' "$LOG" | grep -q 'dev-lead:hands-off'
  grep '"op":"create_issue"' "$LOG" | grep -q 'initiative:hold'
}

@test "existing-issue prerequisite edge references the real issue number" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    bash "$PLANNER_DIR/apply-plan.sh"
  grep '"op":"add_blocked_by"' "$LOG" | grep -q '"blocked_by":195'
}

@test "apply-plan gates on a blocking open question: creates zero issues and exits 0" {
  jq '.open_questions = [{"question":"Confirm scope X before planning","blocking":true}]' "$PLAN" >"$TMP/blocking.json"
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/blocking.json" \
    run bash "$PLANNER_DIR/apply-plan.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 0 ]
  [ "$(grep -c '"op":"add_sub_issue"' "$LOG")" -eq 0 ]
  [ "$(grep -c '"op":"add_blocked_by"' "$LOG")" -eq 0 ]
}

@test "apply-plan blocking gate posts the open questions back to the discussion" {
  jq '.open_questions = [{"question":"Confirm scope X before planning","blocking":true}]' "$PLAN" >"$TMP/blocking.json"
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
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
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/nonblock.json" \
    bash "$PLANNER_DIR/apply-plan.sh"
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 4 ]
}

@test "apply-plan skips creation when an epic already exists for the discussion" {
  # DRY_RUN_EXISTING_EPIC simulates find_existing_epic finding a prior epic
  # offline (the idempotency guard); no issues must be created.
  DRY_RUN=1 DRY_RUN_LOG="$LOG" DRY_RUN_EXISTING_EPIC=777 \
    REPO="petry-projects/.github-private" \
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
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    run bash "$PLANNER_DIR/apply-plan.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 4 ]
}

@test "epic body carries the Untracked prerequisites checklist when the array is present" {
  jq '.epic.untracked_prerequisites = ["Resolve the data-retention discussion", "Provision the staging cluster"]' "$PLAN" >"$TMP/prereqs.json"
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/prereqs.json" \
    bash "$PLANNER_DIR/apply-plan.sh"
  epic_body="$(grep '"op":"create_issue"' "$LOG" | jq -r 'select(.title|startswith("Initiative:")) | .body')"
  [[ "$epic_body" == *"## Untracked prerequisites"* ]]
  [[ "$epic_body" == *"- [ ] Resolve the data-retention discussion"* ]]
  [[ "$epic_body" == *"- [ ] Provision the staging cluster"* ]]
}

@test "Untracked prerequisites section appears before the idempotency footer in the epic body" {
  jq '.epic.untracked_prerequisites = ["Resolve the data-retention discussion"]' "$PLAN" >"$TMP/prereqs_order.json"
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
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
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    bash "$PLANNER_DIR/apply-plan.sh"
  epic_body="$(grep '"op":"create_issue"' "$LOG" | jq -r 'select(.title|startswith("Initiative:")) | .body')"
  [[ "$epic_body" != *"Untracked prerequisites"* ]]
}

@test "story bodies are rendered in the BMAD create-story template" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
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
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
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
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
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
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
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
  ! grep -qF -- ".github-private" "$GH_LOG"
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
  ! grep -qF -- "repos/petry-projects/.github-private/issues" "$GH_LOG"
}

# ── reviewed-plan apply path (#604) ───────────────────────────────────────────
# apply-reviewed-plan.sh is the no-re-plan handoff: a maintainer-reviewed plan.json
# is validated then handed straight to apply-plan.sh — no LLM planning step runs.

@test "apply-reviewed-plan validates then applies the supplied plan (DRY_RUN)" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
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
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/cycle.json" \
    run bash "$PLANNER_DIR/apply-reviewed-plan.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cycle"* ]]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 0 ]
}

@test "apply-reviewed-plan errors on a missing supplied plan file" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/does-not-exist.json" \
    run bash "$PLANNER_DIR/apply-reviewed-plan.sh"
  [ "$status" -ne 0 ]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 0 ]
}

@test "apply-reviewed-plan errors when PLAN_PATH is a directory, not a regular file" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP" \
    run bash "$PLANNER_DIR/apply-reviewed-plan.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a regular file"* ]]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 0 ]
}

@test "apply-reviewed-plan honors the blocking open-questions gate from apply-plan" {
  jq '.open_questions = [{"question":"Confirm scope X before planning","blocking":true}]' "$PLAN" >"$TMP/blocking.json"
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/blocking.json" \
    run bash "$PLANNER_DIR/apply-reviewed-plan.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 0 ]
}

@test "apply-reviewed-plan rejects a plan whose source_discussion mismatches DISCUSSION_NUMBER" {
  # plan.json carries source_discussion:413; dispatcher says 999 — must abort before creating anything.
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=999 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    run bash "$PLANNER_DIR/apply-reviewed-plan.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"source_discussion"* ]]
  [[ "$output" == *"413"* ]]
  [[ "$output" == *"999"* ]]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 0 ]
}

@test "apply-reviewed-plan passes when source_discussion matches DISCUSSION_NUMBER" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$PLAN" \
    run bash "$PLANNER_DIR/apply-reviewed-plan.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 4 ]
}

@test "apply-reviewed-plan rejects plans without source_discussion field" {
  # Reviewed plans must have an explicit source_discussion — they are applied
  # out-of-band and must be self-contained about their origin.
  jq 'del(.source_discussion)' "$PLAN" >"$TMP/no_src.json"
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    DISCUSSION_NUMBER=999 DISCUSSION_NODE_ID="D_test" PLAN_PATH="$TMP/no_src.json" \
    run bash "$PLANNER_DIR/apply-reviewed-plan.sh"
  [ "$status" -ne 0 ]
  [ ! -s "$LOG" ] || [ "$(grep -c '"op":"create_issue"' "$LOG")" -eq 0 ]
}
