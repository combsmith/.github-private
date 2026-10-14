#!/usr/bin/env bats
# Regression guard for #1795: a failing NON-required check must not deadlock merge.
#
# The repo protects `main` with a ruleset (not classic protection), so the rollup's
# .isRequired field is frequently absent and the #1549 fallback reverted to gating
# on ALL external checks — meaning a red `template-drift` (a non-required advisory
# check that fails whenever the standards baseline moves under repo-template) skipped
# every review as `ci-failing`, and no approval could ever land.
#
# review-one-pr.sh now reads the required-check set from the branch ruleset API and
# passes it to compute_ci_status, so:
#   • a red non-required check with all required green → reviews (no ci-failing skip)
#   • a red REQUIRED check → still skips ci-failing (the gate is never weakened)
#   • an unreadable ruleset → fails closed (every failing check blocks)
#   • the non-required failure is NAMED in the output (never silently ignored)
#
# Offline + stubbed — no network.
#
# Run with: bats tests/test_review_one_pr_nonrequired_gate.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"
  export SHA="cafebabecafebabecafebabecafebabecafebabe"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/1783"
  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"; cd "$TEST_DIR"

  # The five contexts the `main` ruleset requires today (issue #1795). template-drift
  # is deliberately NOT among them.
  cat > "$TEST_DIR/ruleset.json" <<'EOF'
["SonarCloud","CodeQL","agent-shield / AgentShield","dependency-audit / Detect ecosystems","duplicate-decl-gate"]
EOF

  export GH_LOG="$TEST_DIR/gh_calls.log"; : > "$GH_LOG"

  # Stub gh. `pr view` returns the snapshot; the ruleset API returns the pre-filtered
  # required-context array (real gh applies --jq itself; the stub emits the result).
  # RULESET_MODE=fail makes the ruleset (and classic-protection fallback) unreadable.
  cat > "$TEST_DIR/bin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$GH_LOG"
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then cat "$TEST_DIR/snapshot.json"; exit 0; fi
if [ "\$1" = "api" ]; then
  case "\$2" in
    *rules/branches*)
      if [ "\${RULESET_MODE:-ok}" = "fail" ]; then exit 1; fi
      cat "$TEST_DIR/ruleset.json"; exit 0 ;;
    *protection*) exit 1 ;;   # classic protection 404s on this ruleset-only branch
  esac
fi
exit 0
EOF
  chmod +x "$TEST_DIR/bin/gh"
  for e in claude copilot gemini; do printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/$e"; chmod +x "$TEST_DIR/bin/$e"; done
  export PATH="$TEST_DIR/bin:$PATH"
  export REVIEW_ENGINE="claude" GH_TOKEN="fake" DRY_RUN="true"
  unset FORCE_REVIEW RULESET_MODE
}
teardown() { rm -rf "$TEST_DIR"; }

# All five required checks green, only the non-required template-drift red.
write_nonrequired_red_snapshot() {
  cat > "$TEST_DIR/snapshot.json" <<EOF
{
  "headRefOid": "$SHA",
  "baseRefName": "main",
  "statusCheckRollup": [
    { "name": "SonarCloud", "status": "COMPLETED", "conclusion": "SUCCESS" },
    { "name": "CodeQL", "status": "COMPLETED", "conclusion": "SUCCESS" },
    { "name": "agent-shield / AgentShield", "status": "COMPLETED", "conclusion": "SUCCESS" },
    { "name": "dependency-audit / Detect ecosystems", "status": "COMPLETED", "conclusion": "SUCCESS" },
    { "name": "duplicate-decl-gate", "status": "COMPLETED", "conclusion": "SUCCESS" },
    { "name": "template-drift", "status": "COMPLETED", "conclusion": "FAILURE" }
  ],
  "reviewDecision": "",
  "reviews": [],
  "labels": [],
  "comments": []
}
EOF
}

@test "#1795: non-required (template-drift) red + required green → NOT ci-failing (reviews)" {
  write_nonrequired_red_snapshot
  run timeout 30 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "status=$status" >&2; echo "$output" >&2
  # The CI gate must NOT record a ci-failing skip.
  [[ "$output" != *'"reason":"ci-failing"'* ]]
  [[ "$output" != *"skip: CI checks are failing"* ]]
}

@test "#1795: the non-required failure is NAMED in the output (never silently ignored)" {
  write_nonrequired_red_snapshot
  run timeout 30 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "$output" >&2
  [[ "$output" == *"proceeding past non-required failing check"* ]]
  [[ "$output" == *"template-drift"* ]]
}

@test "#1795: a red REQUIRED check still skips with ci-failing (gate never weakened)" {
  cat > "$TEST_DIR/snapshot.json" <<EOF
{
  "headRefOid": "$SHA",
  "baseRefName": "main",
  "statusCheckRollup": [
    { "name": "SonarCloud", "status": "COMPLETED", "conclusion": "FAILURE" },
    { "name": "CodeQL", "status": "COMPLETED", "conclusion": "SUCCESS" },
    { "name": "template-drift", "status": "COMPLETED", "conclusion": "FAILURE" }
  ],
  "reviewDecision": "",
  "reviews": [],
  "labels": [],
  "comments": []
}
EOF
  run timeout 30 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "status=$status" >&2; echo "$output" >&2
  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"ci-failing"'* ]]
}

@test "#1795: unreadable ruleset → fails closed (non-required red then blocks as ci-failing)" {
  export RULESET_MODE=fail
  write_nonrequired_red_snapshot
  run timeout 30 bash "$REVIEW_SCRIPT" "$PR_URL"
  echo "status=$status" >&2; echo "$output" >&2
  # With no readable required set, every failing check blocks (today's behaviour).
  [[ "$output" == *"failing closed"* ]]
  [ "$status" -eq 100 ]
  [[ "$output" == *'"reason":"ci-failing"'* ]]
}

@test "#1795: the required set is read from the ruleset API, not a literal" {
  write_nonrequired_red_snapshot
  run timeout 30 bash "$REVIEW_SCRIPT" "$PR_URL"
  # The ruleset endpoint must have been queried for the base branch.
  grep -q 'api repos/petry-projects/.github-private/rules/branches/main' "$GH_LOG"
}
