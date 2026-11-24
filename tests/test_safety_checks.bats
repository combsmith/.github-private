#!/usr/bin/env bats
# Unit tests for the deterministic PR safety checks (issue #305): the pure
# functions in scripts/lib/safety-checks.sh. These re-implement the mechanical
# half of PR #131's 7 safety checks against the current cascade architecture.
#
# Everything here is deterministic and side-effect-free — no `gh`, no network —
# so each check is reproducible and unit-testable in isolation (mirrors the
# jq/awk-program style of scripts/lib/downstream-impact.sh).
#
# Run with: bats tests/test_safety_checks.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/safety-checks.sh"
}

# ---------------------------------------------------------------------------
# Check 1 — CI weakening (deterministic, hard-stop)
# ---------------------------------------------------------------------------

@test "ci-weakening: flags an added test-skip marker" {
  local diff='diff --git a/tests/foo.test.js b/tests/foo.test.js
--- a/tests/foo.test.js
+++ b/tests/foo.test.js
@@ -1,3 +1,4 @@
 describe("x", () => {
-  it("works", () => {});
+  it.skip("works", () => {});
 });'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -qi "skip"
  echo "$output" | grep -q "tests/foo.test.js"
}

@test "ci-weakening: flags continue-on-error: true added to a workflow" {
  local diff='diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -10,3 +10,4 @@ jobs:
     steps:
       - run: npm test
+        continue-on-error: true'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "continue-on-error"
}

@test "ci-weakening: flags if: false disabling a step" {
  local diff='diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -10,3 +10,4 @@ jobs:
     steps:
+      - if: false
       - run: npm test'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "if: false"
}

@test "ci-weakening: flags a lowered numeric coverage threshold" {
  local diff='diff --git a/pyproject.toml b/pyproject.toml
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -1,3 +1,3 @@
 [tool.coverage]
-fail_under = 90
+fail_under = 50'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "threshold"
}

@test "ci-weakening: does NOT flag a raised coverage threshold" {
  local diff='diff --git a/pyproject.toml b/pyproject.toml
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -1,3 +1,3 @@
 [tool.coverage]
-fail_under = 50
+fail_under = 90'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ci-weakening: clean diff yields no findings" {
  local diff='diff --git a/src/app.js b/src/app.js
--- a/src/app.js
+++ b/src/app.js
@@ -1,2 +1,3 @@
 const x = 1;
+const y = 2;'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ci-weakening: flags a commented-out run step added to a workflow file" {
  local diff='diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -5,4 +5,5 @@ jobs:
     steps:
       - name: setup
         uses: actions/checkout@v4
+      # - run: npm test
       - run: npm build'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -qi "commented-out"
}

@test "ci-weakening: flags a commented-out uses step added to a workflow file" {
  local diff='diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -3,3 +3,4 @@ jobs:
   build:
     steps:
+      # - uses: actions/upload-artifact@v4
       - uses: actions/checkout@v4'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -qi "commented-out"
}

@test "ci-weakening: does NOT flag commented-out step pattern in non-workflow files" {
  local diff='diff --git a/docs/example.md b/docs/example.md
--- a/docs/example.md
+++ b/docs/example.md
@@ -1,3 +1,4 @@
 # Example
+# - run: npm test
 example content'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Regression (issue #305 review): the xit/xdescribe markers must be matched with
# POSIX-portable boundaries, NOT GNU awk's `\b` — the CI `bats` job runs on
# Ubuntu where `awk` is mawk, which does not support `\b`. Before the fix this
# path silently never matched on the runner.
@test "ci-weakening: detects xit/xdescribe skip markers (POSIX boundary, must pass on mawk)" {
  local diff='diff --git a/foo.test.js b/foo.test.js
--- a/foo.test.js
+++ b/foo.test.js
@@ -1,2 +1,4 @@
 test("keep", ()=>{})
+xit("skipme", ()=>{})
+xdescribe("group", ()=>{})
 more'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  grep -qi "skip/disable marker" <<< "$output"
  grep -q "foo.test.js" <<< "$output"
}

# Regression (issue #305 review): the awk `rem[]` threshold map must be reset per
# file (`delete rem`). Without it, a removed threshold in file A leaks into the
# comparison for file B, producing a false "lowered threshold" finding there.
@test "ci-weakening: removed threshold in file A does not leak into file B (rem state reset)" {
  local diff='diff --git a/a/codecov.yml b/a/codecov.yml
--- a/a/codecov.yml
+++ b/a/codecov.yml
@@ -1,2 +1,2 @@
-coverage: 90
+coverage: 80
 x: y
diff --git a/b/unrelated.txt b/b/unrelated.txt
--- a/b/unrelated.txt
+++ b/b/unrelated.txt
@@ -1,1 +1,2 @@
 hello
+coverage note: 5 lines added'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  # Exactly the real threshold drop in file A is reported; file B must NOT
  # produce a "lowered threshold" finding from a leaked rem[] value.
  [ "$(grep -ci "lowered numeric threshold" <<< "$output" || true)" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Check 2 — Prompt injection in workflows (deterministic, hard-stop)
# ---------------------------------------------------------------------------

@test "prompt-injection: flags github.event.*.body interpolated in a run step" {
  local diff='diff --git a/.github/workflows/triage.yml b/.github/workflows/triage.yml
--- a/.github/workflows/triage.yml
+++ b/.github/workflows/triage.yml
@@ -5,3 +5,4 @@ jobs:
     steps:
       - run: |
+          echo "${{ github.event.issue.body }}" | process'
  run sc_prompt_injection "$diff"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -qi "github.event"
}

@test "prompt-injection: flags pull_request_target usage" {
  local diff='diff --git a/.github/workflows/label.yml b/.github/workflows/label.yml
--- a/.github/workflows/label.yml
+++ b/.github/workflows/label.yml
@@ -1,2 +1,3 @@
 name: label
+on: pull_request_target'
  run sc_prompt_injection "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "pull_request_target"
}

@test "prompt-injection: flags write-all token permissions" {
  local diff='diff --git a/.github/workflows/deploy.yml b/.github/workflows/deploy.yml
--- a/.github/workflows/deploy.yml
+++ b/.github/workflows/deploy.yml
@@ -1,2 +1,3 @@
 name: deploy
+permissions: write-all'
  run sc_prompt_injection "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "write-all"
}

@test "prompt-injection: ignores github.event interpolation OUTSIDE workflow files" {
  local diff='diff --git a/docs/README.md b/docs/README.md
--- a/docs/README.md
+++ b/docs/README.md
@@ -1,2 +1,3 @@
 example:
+  echo "${{ github.event.issue.body }}"'
  run sc_prompt_injection "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prompt-injection: clean workflow change yields no findings" {
  local diff='diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -1,2 +1,3 @@
 name: ci
+  timeout-minutes: 10'
  run sc_prompt_injection "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prompt-injection: does NOT flag github.event in env: context (outside run: block)" {
  local diff='diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -5,3 +5,6 @@ jobs:
     steps:
       - name: build
+        env:
+          BODY: ${{ github.event.issue.body }}
         run: echo "safe"'
  run sc_prompt_injection "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prompt-injection: does NOT flag github.event in with: context (outside run: block)" {
  local diff='diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -5,3 +5,6 @@ jobs:
     steps:
       - name: label
         uses: some/action@v1
+        with:
+          title: ${{ github.event.pull_request.title }}'
  run sc_prompt_injection "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prompt-injection: flags github.event added inside a multi-line run: block (via context lines)" {
  local diff='diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -5,4 +5,5 @@ jobs:
     steps:
       - name: build
         run: |
+          echo "${{ github.event.issue.body }}" | sanitize'
  run sc_prompt_injection "$diff"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -qi "github.event"
}

@test "prompt-injection: flags github.event on an inline run: added line" {
  local diff='diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -5,3 +5,4 @@ jobs:
     steps:
       - name: build
+        run: echo "${{ github.event.comment.body }}"'
  run sc_prompt_injection "$diff"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -qi "github.event"
}

# ---------------------------------------------------------------------------
# Check 3 — Large-PR gate (deterministic, from metadata)
# ---------------------------------------------------------------------------

@test "large-pr: over the file threshold with no plan section is gated" {
  local meta='{"changedFiles":120,"additions":50,"deletions":10,"body":"just a quick change"}'
  run sc_large_pr "$meta"
  [ "$status" -eq 0 ]
  [[ "$output" == true* ]]
}

@test "large-pr: over threshold WITH an implementation-plan section is not gated" {
  local meta='{"changedFiles":120,"additions":50,"deletions":10,"body":"## Implementation plan\n- step one\n- step two"}'
  run sc_large_pr "$meta"
  [ "$status" -eq 0 ]
  [[ "$output" == false* ]]
}

@test "large-pr: just under the file threshold is not gated" {
  local meta='{"changedFiles":49,"additions":10,"deletions":10,"body":""}'
  run sc_large_pr "$meta"
  [ "$status" -eq 0 ]
  [[ "$output" == false* ]]
}

@test "large-pr: high line count with no plan section is gated" {
  local meta='{"changedFiles":5,"additions":900,"deletions":600,"body":"small file count big churn"}'
  run sc_large_pr "$meta"
  [ "$status" -eq 0 ]
  [[ "$output" == true* ]]
}

# ---------------------------------------------------------------------------
# Check 4 — Description quality (deterministic, from metadata)
# ---------------------------------------------------------------------------

@test "description-quality: all 5 sections present -> 0 missing" {
  local meta='{"body":"## Problem\nx\n## Risk category\nlow\n## Test plan\nran tests\n## Rollback\nrevert\n## Monitoring\nmetrics dashboard"}'
  run sc_description_missing "$meta"
  [ "$status" -eq 0 ]
  [[ "$output" == 0\|* ]]
}

@test "description-quality: empty body -> 5 missing" {
  local meta='{"body":""}'
  run sc_description_missing "$meta"
  [ "$status" -eq 0 ]
  [[ "$output" == 5\|* ]]
}

@test "description-quality: only 2 of 5 present -> 3 missing (escalation boundary)" {
  local meta='{"body":"## Problem statement\nthe bug\n## Test plan\ncovered by unit tests"}'
  run sc_description_missing "$meta"
  [ "$status" -eq 0 ]
  [[ "$output" == 3\|* ]]
}

# --- Unfilled templates score like an empty body (#2604) ---------------------
# The keyword match used to read the raw body, so an unfilled template passed on
# its own HTML-comment guidance and bare headings: #1976 went through with this
# repo's template, and the org default template of combsmith/.github#1566 scored
# 1 of 5 missing. Only filled text counts now.

# _org_template — a snapshot of the org default pull request template that
# combsmith/.github#1566 adds (.github/pull_request_template.md, at 56a5e3e), unfilled.
_org_template() {
  cat <<'TMPL'
<!-- markdownlint-disable-file MD041 -->
<!--
Title: `area: plain verb phrase (#issue)`, at most 72 characters, one change.
In combsmith/.github and combsmith/.github-private, keep the type: `feat(area): plain verb phrase (#issue)`.
Breaking change? Put `!` after the scope in the title: `feat(area)!: plain verb phrase (#issue)`.
A `BREAKING CHANGE:` line is not read; a check fails a body that has one without the `!`.
This body is meant to become the squash commit's message. Whoever merges can edit it, so check the message before merging.
This text becomes permanent public history: no secrets, tokens or raw logs. Security findings: count only.
Rules: docs/initiatives/pull-request-and-commit-prose-adr.md in combsmith/.github.
-->

## Why

<!-- One or two plain sentences: what was wrong or missing, and what a user would notice. Link the issue. -->

## What changed

- <!-- area or file: what -->

## What to look at

<!-- What a reviewer should check, and what this change leaves out. -->

- Risk: <!-- low, medium or high, and why in a few words -->
- Rollback: <!-- usually "revert this pull request", or what cannot be undone -->
- Monitoring: <!-- the check or signal that shows a problem, or "none needed" -->

## Decisions and protected edits

<!-- The decision record this pull request adds, or "none". Any protected edit, and who approved it. -->

<details><summary>Checks and reviews</summary>

<!-- Tests and checks run. Each reviewer's findings, taken or declined, with reasons. -->

</details>
TMPL
}

_desc() { sc_description_missing "$(jq -n --arg b "$1" '{body:$b}')"; }

@test "description-quality: the unfilled org template scores like an empty body, as #1976 should have (#2604)" {
  run _desc "$(_org_template)"
  [ "$status" -eq 0 ]
  [ "$output" = "$(_desc "")" ]
  [[ "$output" == 5\|* ]]
}

@test "description-quality: the org template, filled, has all five sections (#2604)" {
  local body
  body="$(_org_template | sed \
    -e 's|^<!-- One or two.*|The retry loop never stopped. Closes #1.|' \
    -e 's|^- <!-- area or file.*|- scripts/retry.sh: stop after three tries.|' \
    -e 's|^- Risk: .*|- Risk: low, one loop bound.|' \
    -e 's|^- Rollback: .*|- Rollback: revert this pull request.|' \
    -e 's|^- Monitoring: .*|- Monitoring: the retry count in the run log.|' \
    -e 's|^<!-- Tests and checks.*|- bats tests/test_retry.bats passes.|')"
  run _desc "$body"
  [ "$output" = "0|" ]
}

@test "description-quality: a #1976-shaped body (template comment with its opener deleted) escalates (#2604)" {
  local body
  body=$'Keep the required sections — Problem, Risk, Test plan, Rollback, and Monitoring —\neven when brief.\n-->\n\n## Summary\n\n<!-- What does this PR change? -->\n\n## Problem\n\n<!-- What problem does this solve? -->\n\n## Risk\n\n## Test plan\n\n## Rollback\n\n## Monitoring\n'
  run _desc "$body"
  [[ "$output" == 5\|* ]]
}

@test "description-quality: words inside HTML comments do not count (#2604)" {
  run _desc $'<!-- problem risk test plan rollback monitoring -->\n<!--\nrisk\nrollback\n-->'
  [[ "$output" == 5\|* ]]
}

@test "description-quality: an unclosed comment at a line start hides the rest of the body (#2604)" {
  run _desc $'## Problem\nthe bug\n<!-- unclosed\n## Risk\nlow\n## Rollback\nrevert'
  [[ "$output" == 4\|* ]]
  [[ "$output" != *problem* ]]
}

@test "description-quality: a heading with no text under it is missing; with text it counts (#2604)" {
  run _desc $'## Risk\n\n## Rollback\nrevert this pull request'
  [[ "$output" == *risk* ]]
  [[ "$output" != *rollback* ]]
}

@test "description-quality: an empty Label: line is missing; a filled one counts (#2604)" {
  run _desc $'- Risk:\n- Rollback: revert this pull request\n- Monitoring:   '
  [[ "$output" == *risk* ]]
  [[ "$output" == *monitoring* ]]
  [[ "$output" != *rollback* ]]
}

@test "description-quality: a plain Label: line over a list still counts (#2604)" {
  run _desc $'Test plan:\n- ran the unit tests\n\nRisk:\n  - low'
  [[ "$output" != *test-plan* ]]
  [[ "$output" != *risk* ]]
}

@test "description-quality: a list-item label with deeper-indented text counts; a sibling item does not (#2604)" {
  run _desc $'- Risk:\n  - low, one loop bound\n- Rollback:\n- Monitoring: none needed'
  [[ "$output" != *risk* ]]
  [[ "$output" == *rollback* ]]
}

@test "description-quality: a Why heading with text counts as the problem (#2604)" {
  run _desc $'## Why\n\nThe loop never stopped.'
  [[ "$output" != *problem* ]]
  run _desc $'## Why\n\n## Risk\nlow'
  [[ "$output" == *problem* ]]
}

@test "description-quality: a filled Checks and reviews block counts as the test plan; an empty one does not (#2604)" {
  run _desc $'<details><summary>Checks and reviews</summary>\n\n- shellcheck clean\n\n</details>'
  [[ "$output" != *test-plan* ]]
  run _desc $'<details><summary>Checks and reviews</summary>\n\n</details>\n\n## Rollback\nrevert'
  [[ "$output" == *test-plan* ]]
}

# A filled body that the filter must not empty out (Claude review of #2605).
_filled_body() {
  printf '%s\n' '## Problem' 'The retry loop never stopped.' '## Risk' 'low' '## Test plan' 'bats passes' \
    '## Rollback' 'revert this pull request' '## Monitoring' 'the retry count in the run log'
}

@test "description-quality: an arrow (-->) in prose or a diagram does not erase what comes before it (#2605)" {
  run _desc "$(_filled_body)"$'\n\n```mermaid\nflowchart LR\n  A-->B\n```\n\nState goes open --> closed.'
  [ "$output" = "0|" ]
  run _desc $'Context first.\n-->\n'"$(_filled_body)"
  [ "$output" = "0|" ]
}

@test "description-quality: a comment opener inside code is text, as GitHub shows it (#2605)" {
  run _desc "$(_filled_body)"$'\n\nThe template starts with `<!--` and a fence:\n\n```\n<!-- not a comment\n```\n\n## Notes\nmore text'
  [ "$output" = "0|" ]
}

@test "description-quality: dev-lead's body for an issue that quotes a comment opener mid-line still passes (#2605)" {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/dev-lead-pr-body.sh"
  local body
  body="$(dlpb_build_body 7 "pr-review: the triage reads <!-- as a comment" $'The triage reads `<!--` in a body and hides the rest.' $'scripts/lib/safety-checks.sh')"
  run _desc "$body"
  [ "$output" = "0|" ]
}

@test "description-quality: comment markers inside a tilde fence are text (#2605)" {
  run _desc "$(printf '%s\n' '## Problem' '~~~html' '<!-- a sample -->' '<!--' '~~~')"$'\n'"$(_filled_body | tail -n +3)"
  [ "$output" = "0|" ]
}

@test "description-quality: a fence opened after a list marker keeps its comment opener literal (#2605)" {
  run _desc "$(printf '%s\n' '## Problem' '- ~~~html' '  <!--' '  ~~~')"$'\n'"$(_filled_body | tail -n +3)"
  [ "$output" = "0|" ]
}

@test "description-quality: a single-line details block with content counts (#2605)" {
  run _desc $'## Problem\nthe loop never stopped\n## Risk\nlow\n<details><summary>Test plan</summary>bats passed</details>\n## Rollback\nrevert\n## Monitoring\nrun log'
  [ "$output" = "0|" ]
}

@test "description-quality: a shorter fence does not close a longer one (#2605)" {
  run _desc "$(printf '%s\n' '````text' '```' 'example' '````' '## Problem' '## Risk' '## Test plan' '## Rollback' '## Monitoring')"
  [[ "$output" == 5\|* ]]
}

@test "description-quality: a code fence line starting with # is not a heading (#2605)" {
  run _desc $'## Test plan\n\n```bash\n# run the suite\nbats tests\n```\n\n## Risk\nlow'
  [[ "$output" != *test-plan* ]]
  [[ "$output" != *risk* ]]
}

@test "description-quality: a heading that carries its value counts (## Risk: low) (#2605)" {
  run _desc $'## Problem: the loop never stopped\n## Risk: low\n## Test plan: bats passes\n## Rollback: revert\n## Monitoring: run log'
  [ "$output" = "0|" ]
  run _desc $'## Risk:\n## Rollback: revert'
  [[ "$output" == *risk* ]]
}

@test "description-quality: a parent heading over filled subheadings counts (#2605)" {
  run _desc $'## Test plan\n\n### Automated\n\n- bats passes\n\n## Risk\nlow'
  [[ "$output" != *test-plan* ]]
  run _desc $'## Test plan\n\n### Automated\n\n## Risk\nlow'
  [[ "$output" == *test-plan* ]]
}

@test "description-quality: the <summary> tag is not the word summary (#2605)" {
  run _desc $'<details><summary>Checks and reviews</summary>\n\n- shellcheck clean\n\n</details>'
  [[ "$output" == *problem* ]]
  [[ "$output" != *test-plan* ]]
}

@test "description-quality: empty numbered labels, horizontal rules and a details tag do not count (#2605)" {
  run _desc $'1. Risk:\n2. Rollback:\n3. Monitoring:'
  [[ "$output" == 5\|* ]]
  run _desc $'## Problem\n\n---\n\n## Risk\n\n***\n\n<details open>\n\n## Rollback\n'
  [[ "$output" == 5\|* ]]
  run _desc $'- Risk & impact:\n- Monitoring:'
  [[ "$output" == 5\|* ]]
}

@test "description-quality: a tab-indented child keeps its list-item label (#2605)" {
  run _desc $'- Risk:\n\t- low, one loop bound'
  [[ "$output" != *risk* ]]
}

@test "description-quality: CR-only and CRLF line ends do not hide empty headings (#2605)" {
  run _desc $'x\r## Problem\r## Risk\r## Test plan\r## Rollback\r## Monitoring\r'
  [[ "$output" == 5\|* ]]
  run _desc $'## Problem\r\nthe bug\r\n## Risk\r\n\r\n'
  [[ "$output" != *problem* ]]
  [[ "$output" == *risk* ]]
}

# ---------------------------------------------------------------------------
# Check 7 — Dependency risk (deterministic parse; LLM narrative lives in Tier 2)
# ---------------------------------------------------------------------------

@test "dependency-risk: flags an unpinned caret range added to package.json" {
  local diff='diff --git a/package.json b/package.json
--- a/package.json
+++ b/package.json
@@ -3,4 +3,5 @@
   "dependencies": {
     "lodash": "4.17.21",
+    "left-pad": "^1.3.0"
   }'
  run sc_dependency_risk "$diff"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -q "left-pad"
}

@test "dependency-risk: flags a 'latest' range" {
  local diff='diff --git a/package.json b/package.json
--- a/package.json
+++ b/package.json
@@ -3,4 +3,5 @@
   "dependencies": {
+    "chalk": "latest"
   }'
  run sc_dependency_risk "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "latest"
}

@test "dependency-risk: does NOT flag an exactly-pinned dependency" {
  local diff='diff --git a/package.json b/package.json
--- a/package.json
+++ b/package.json
@@ -3,4 +3,5 @@
   "dependencies": {
+    "lodash": "4.17.21"
   }'
  run sc_dependency_risk "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dependency-risk: ignores non-manifest files" {
  local diff='diff --git a/src/app.js b/src/app.js
--- a/src/app.js
+++ b/src/app.js
@@ -1,2 +1,3 @@
+const dep = "^1.0.0";'
  run sc_dependency_risk "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dependency-risk: does NOT flag 'latest' substring in a URL field" {
  local diff='diff --git a/package.json b/package.json
--- a/package.json
+++ b/package.json
@@ -1,3 +1,4 @@
 {
+  "homepage": "https://example.com/releases/latest/download"
 }'
  run sc_dependency_risk "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dependency-risk: does NOT flag 'latest' in a package name or description" {
  local diff='diff --git a/package.json b/package.json
--- a/package.json
+++ b/package.json
@@ -1,3 +1,4 @@
 {
+  "description": "Always fetch the latest build artifacts from CI"
 }'
  run sc_dependency_risk "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dependency-risk: flags bare 'latest' as a version value (: latest)" {
  local diff='diff --git a/Pipfile b/Pipfile
--- a/Pipfile
+++ b/Pipfile
@@ -3,3 +3,4 @@
 [packages]
+requests = "latest"'
  run sc_dependency_risk "$diff"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -qi "latest"
}

# ---------------------------------------------------------------------------
# Aggregate — compute_safety_checks emits a structured block + hard-stop flags
# ---------------------------------------------------------------------------

@test "compute: emits both hard-stop flags as false for a clean PR" {
  local meta='{"changedFiles":2,"additions":5,"deletions":1,"body":"## Problem\n## Risk\n## Test plan\n## Rollback\n## Monitoring"}'
  local diff='diff --git a/src/app.js b/src/app.js
--- a/src/app.js
+++ b/src/app.js
@@ -1,2 +1,3 @@
+const y = 2;'
  run compute_safety_checks "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CI_WEAKENING_DETECTED: false"
  echo "$output" | grep -q "PROMPT_INJECTION_DETECTED: false"
}

@test "compute: sets CI_WEAKENING_DETECTED true when a skip is added" {
  local meta='{"changedFiles":1,"additions":1,"deletions":1,"body":""}'
  local diff='diff --git a/a.test.js b/a.test.js
--- a/a.test.js
+++ b/a.test.js
@@ -1,1 +1,1 @@
+it.skip("x", () => {});'
  run compute_safety_checks "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CI_WEAKENING_DETECTED: true"
}

@test "compute: sets PROMPT_INJECTION_DETECTED true for a dangerous workflow edit" {
  local meta='{"changedFiles":1,"additions":1,"deletions":0,"body":""}'
  local diff='diff --git a/.github/workflows/x.yml b/.github/workflows/x.yml
--- a/.github/workflows/x.yml
+++ b/.github/workflows/x.yml
@@ -1,1 +1,2 @@
 name: x
+        run: echo "${{ github.event.comment.body }}"'
  run compute_safety_checks "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PROMPT_INJECTION_DETECTED: true"
}

@test "compute: reports description-missing count and large-pr verdict" {
  local meta='{"changedFiles":200,"additions":10,"deletions":5,"body":"nothing useful"}'
  local diff=''
  run compute_safety_checks "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "DESCRIPTION_MISSING: 5"
  echo "$output" | grep -q "LARGE_PR: true"
}

@test "compute: degrades to a well-formed block on malformed metadata" {
  run compute_safety_checks "not json" ""
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CI_WEAKENING_DETECTED:"
  echo "$output" | grep -q "PROMPT_INJECTION_DETECTED:"
}

# ---------------------------------------------------------------------------
# Check 8 — Trusted first-party stub / standards-sync classification
# ---------------------------------------------------------------------------

@test "secret-in-run: flags a secret interpolated into a run step" {
  local diff='--- a/.github/workflows/deploy.yml
+++ b/.github/workflows/deploy.yml
@@ -3,2 +3,4 @@ jobs:
   deploy:
+      - run: |
+          curl -H "t: ${{ secrets.DEPLOY_TOKEN }}" https://x.example'
  run sc_secret_in_run "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "secret interpolated directly into a run step"
}

@test "secret-in-run: flags a secret in bracket syntax inside a run step" {
  local diff='--- a/.github/workflows/deploy.yml
+++ b/.github/workflows/deploy.yml
@@ -3,2 +3,4 @@ jobs:
   deploy:
+      - run: |
+          curl -H "t: ${{ secrets['\''DEPLOY_TOKEN'\''] }}" https://x.example'
  run sc_secret_in_run "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "secret interpolated directly into a run step"
}

@test "secret-in-run: flags a secret in double-quoted bracket syntax inside a run step" {
  local diff='--- a/.github/workflows/deploy.yml
+++ b/.github/workflows/deploy.yml
@@ -3,2 +3,4 @@ jobs:
   deploy:
+      - run: |
+          curl -H "t: ${{ secrets[\"DEPLOY_TOKEN\"] }}" https://x.example'
  run sc_secret_in_run "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "secret interpolated directly into a run step"
}

@test "secret-in-run: does NOT flag secrets: inherit forwarding" {
  local diff='--- a/.github/workflows/pr-auto-review.yml
+++ b/.github/workflows/pr-auto-review.yml
@@ -3,2 +3,3 @@ jobs:
   review:
+    secrets: inherit'
  run sc_secret_in_run "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "secret-in-run: does NOT flag a secret mapped in a secrets: block" {
  local diff='--- a/.github/workflows/x.yml
+++ b/.github/workflows/x.yml
@@ -3,2 +3,4 @@ jobs:
   x:
+    secrets:
+      GH_PAT: ${{ secrets.GH_PAT_DON_PETRY }}'
  run sc_secret_in_run "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "thirdparty-reusable: flags a non-combsmith reusable workflow call" {
  local diff='--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -3,2 +3,3 @@ jobs:
   x:
+    uses: some-vendor/actions/.github/workflows/build.yml@v1'
  run sc_thirdparty_reusable "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "third-party reusable workflow call added (owner: some-vendor)"
}

@test "thirdparty-reusable: does NOT flag a combsmith reusable call" {
  local diff='--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -3,2 +3,3 @@ jobs:
   x:
+    uses: combsmith/.github/.github/workflows/pr-auto-review.yml@pr-auto-review/v1-stable'
  run sc_thirdparty_reusable "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "thirdparty-reusable: does NOT flag an ordinary action pin (no .yml@)" {
  local diff='--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -3,2 +3,3 @@ jobs:
   x:
+      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683'
  run sc_thirdparty_reusable "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "trusted-stub-sync: true for a bot-authored workflow-only secrets:inherit sync" {
  local meta='{"title":"chore: sync 2 org-standard workflow stub(s) from combsmith/.github","author":{"login":"donpetry-bot"},"files":[{"path":".github/workflows/dev-lead.yml"},{"path":".github/workflows/pr-auto-review.yml"}]}'
  local diff='--- a/.github/workflows/pr-auto-review.yml
+++ b/.github/workflows/pr-auto-review.yml
@@ -3,2 +3,4 @@ jobs:
   review:
+    uses: combsmith/.github/.github/workflows/pr-auto-review.yml@pr-auto-review/v1-stable
+    secrets: inherit'
  run sc_trusted_stub_sync "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "TRUSTED_STUB_SYNC: true"
  echo "$output" | grep -q "STANDARDS_SYNC_PR: true"
  echo "$output" | grep -q "WORKFLOW_ONLY_CHANGE: true"
  echo "$output" | grep -q "FIRST_PARTY_REUSABLE_CALL: true"
  echo "$output" | grep -q "SECRET_FORWARDING: true"
}

@test "trusted-stub-sync: false for a workflow-only bot edit WITHOUT positive stub proof" {
  # A bot changes workflow metadata (a comment / timeout) but neither calls a
  # combsmith reusable nor forwards secrets — no positive proof of the
  # trusted stub shape, so the carve-out must NOT apply even though no
  # disqualifier is present.
  local meta='{"title":"chore: bump workflow timeout","author":{"login":"donpetry-bot"},"files":[{"path":".github/workflows/ci.yml"}]}'
  local diff='--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -3,2 +3,3 @@ jobs:
   build:
+    timeout-minutes: 20'
  run sc_trusted_stub_sync "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "SECRET_IN_RUN_STEP: false"
  echo "$output" | grep -q "THIRD_PARTY_REUSABLE_ADDED: false"
  echo "$output" | grep -q "FIRST_PARTY_REUSABLE_CALL: false"
  echo "$output" | grep -q "SECRET_FORWARDING: false"
  echo "$output" | grep -q "TRUSTED_STUB_SYNC: false"
}

@test "trusted-stub-sync: true for a repin-only sync (forwarding target visible in context)" {
  # A sync that only repins the @channel tag on the uses: line: the secrets:
  # inherit forwarding sits on an unchanged context line, so positive proof is
  # still satisfied from the surrounding hunk.
  local meta='{"title":"chore: sync org-standard workflow stub","author":{"login":"donpetry-bot"},"files":[{"path":".github/workflows/dev-lead.yml"}]}'
  local diff='--- a/.github/workflows/dev-lead.yml
+++ b/.github/workflows/dev-lead.yml
@@ -3,3 +3,3 @@ jobs:
   dev-lead:
-    uses: combsmith/.github/.github/workflows/dev-lead.yml@dev-lead/v1-next
+    uses: combsmith/.github/.github/workflows/dev-lead.yml@dev-lead/v1-stable
     secrets: inherit'
  run sc_trusted_stub_sync "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "FIRST_PARTY_REUSABLE_CALL: true"
  echo "$output" | grep -q "SECRET_FORWARDING: true"
  echo "$output" | grep -q "TRUSTED_STUB_SYNC: true"
}

@test "trusted-stub-sync: false when a secret is piped into a run step" {
  local meta='{"title":"chore: sync org-standard workflow stub","author":{"login":"donpetry-bot"},"files":[{"path":".github/workflows/deploy.yml"}]}'
  local diff='--- a/.github/workflows/deploy.yml
+++ b/.github/workflows/deploy.yml
@@ -3,2 +3,4 @@ jobs:
   deploy:
+      - run: |
+          echo "${{ secrets.DEPLOY_TOKEN }}"'
  run sc_trusted_stub_sync "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "SECRET_IN_RUN_STEP: true"
  echo "$output" | grep -q "TRUSTED_STUB_SYNC: false"
}

@test "trusted-stub-sync: false when a bracket-syntax secret is in a run step" {
  local meta='{"title":"chore: sync org-standard workflow stub","author":{"login":"donpetry-bot"},"files":[{"path":".github/workflows/deploy.yml"}]}'
  local diff='--- a/.github/workflows/deploy.yml
+++ b/.github/workflows/deploy.yml
@@ -3,2 +3,4 @@ jobs:
   deploy:
+      - run: |
+          echo "${{ secrets['\''DEPLOY_TOKEN'\''] }}"'
  run sc_trusted_stub_sync "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "SECRET_IN_RUN_STEP: true"
  echo "$output" | grep -q "TRUSTED_STUB_SYNC: false"
}

@test "trusted-stub-sync: hyphenated standards-sync title classifies as sync" {
  local meta='{"title":"chore: standards-sync workflow refresh","author":{"login":"rachel-petry"},"files":[{"path":".github/workflows/ci.yml"}]}'
  local diff='--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -3,2 +3,3 @@ jobs:
   review:
+    secrets: inherit'
  run sc_trusted_stub_sync "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "STANDARDS_SYNC_PR: true"
}

@test "trusted-stub-sync: false for human-authored PR with standards-sync title (title alone is insufficient)" {
  local meta='{"title":"chore: standards-sync workflow refresh","author":{"login":"rachel-petry"},"files":[{"path":".github/workflows/ci.yml"}]}'
  local diff='--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -3,2 +3,3 @@ jobs:
   review:
+    secrets: inherit'
  run sc_trusted_stub_sync "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "STANDARDS_SYNC_PR: true"
  echo "$output" | grep -q "TRUSTED_STUB_SYNC: false"
}

@test "trusted-stub-sync: unrelated title with metacharacter is not a sync" {
  local meta='{"title":"chore: standardsXsync tweak","author":{"login":"rachel-petry"},"files":[{"path":".github/workflows/ci.yml"}]}'
  local diff='--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -3,2 +3,3 @@ jobs:
   review:
+    secrets: inherit'
  run sc_trusted_stub_sync "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "STANDARDS_SYNC_PR: false"
  echo "$output" | grep -q "TRUSTED_STUB_SYNC: false"
}

@test "trusted-stub-sync: false when a third-party reusable is added" {
  local meta='{"title":"chore: sync org-standard workflow stub","author":{"login":"donpetry-bot"},"files":[{"path":".github/workflows/ci.yml"}]}'
  local diff='--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -3,2 +3,3 @@ jobs:
   x:
+    uses: some-vendor/actions/.github/workflows/build.yml@v1'
  run sc_trusted_stub_sync "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "THIRD_PARTY_REUSABLE_ADDED: true"
  echo "$output" | grep -q "TRUSTED_STUB_SYNC: false"
}

@test "trusted-stub-sync: false for a non-workflow file in the diff" {
  local meta='{"title":"feat: add login","author":{"login":"rachel-petry"},"files":[{"path":"src/auth.ts"},{"path":".github/workflows/ci.yml"}]}'
  local diff='--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -3,2 +3,3 @@ jobs:
   review:
+    secrets: inherit'
  run sc_trusted_stub_sync "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WORKFLOW_ONLY_CHANGE: false"
  echo "$output" | grep -q "TRUSTED_STUB_SYNC: false"
}

@test "trusted-stub-sync: false for a human-authored stub edit (not sync class)" {
  local meta='{"title":"tweak workflow timeout","author":{"login":"rachel-petry"},"files":[{"path":".github/workflows/ci.yml"}]}'
  local diff='--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -3,2 +3,3 @@ jobs:
   review:
+    secrets: inherit'
  run sc_trusted_stub_sync "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "STANDARDS_SYNC_PR: false"
  echo "$output" | grep -q "TRUSTED_STUB_SYNC: false"
}

@test "compute: demotes description/large-pr gates to info under a trusted stub sync" {
  local meta='{"title":"chore: sync 3 org-standard workflow stub(s) from combsmith/.github","author":{"login":"donpetry-bot"},"changedFiles":3,"body":"Automated sync.","files":[{"path":".github/workflows/a.yml"},{"path":".github/workflows/b.yml"},{"path":".github/workflows/c.yml"}]}'
  local diff='--- a/.github/workflows/a.yml
+++ b/.github/workflows/a.yml
@@ -3,2 +3,4 @@ jobs:
   review:
+    uses: combsmith/.github/.github/workflows/pr-auto-review.yml@pr-auto-review/v1-stable
+    secrets: inherit'
  run compute_safety_checks "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "TRUSTED_STUB_SYNC: true"
  # description gate present but demoted to informational, not escalate
  echo "$output" | grep -q "\[info\] description-quality"
  ! echo "$output" | grep -q "\[escalate\] description-quality" || false
  echo "$output" | grep -q "\[info\] trusted-stub-sync"
}

@test "compute: hard-stops still fire even under a trusted stub sync" {
  local meta='{"title":"chore: sync org-standard workflow stub","author":{"login":"donpetry-bot"},"files":[{"path":".github/workflows/a.yml"}]}'
  local diff='--- a/.github/workflows/a.yml
+++ b/.github/workflows/a.yml
@@ -3,2 +3,3 @@ jobs:
   review:
+      continue-on-error: true'
  run compute_safety_checks "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CI_WEAKENING_DETECTED: true"
}

@test "description-quality: ~~~ in prose does not shield a template comment (#2605)" {
  run _desc $'The formatter now emits ~~~ delimiters.\n<!--\nProblem: Describe the issue.\nRisk: Describe the risk.\nTest plan: List the checks.\nRollback: Describe the recovery.\nMonitoring: List the signals.\n-->'
  [[ "$output" == 5\|* ]]
}

@test "description-quality: a heading above a filled <details> block stays kept (#2605)" {
  run _desc $'### Test plan\n<details><summary>Show</summary>\n\n- bats passes\n</details>\n\n## Risk\nlow'
  [[ "$output" != *test-plan* ]]
}

@test "description-quality: an inline code span after a list marker is not a fence (#2605)" {
  run _desc $'- ```example```\n\n## Problem\n## Risk\n## Test plan\n## Rollback\n## Monitoring'
  [[ "$output" == 5\|* ]]
}

@test "description-quality: empty fenced blocks do not shield empty headings (#2605)" {
  run _desc $'## Problem\n```\n```\n## Risk\n```\n\n```\n## Test plan\n~~~\n~~~\n## Rollback\n```\n```\n## Monitoring\n```\n```'
  [[ "$output" == 5\|* ]]
}

@test "description-quality: a plain label is not filled by a following Label: value line (#2605)" {
  run _desc $'Risk:\nRollback: revert this pull request'
  [[ "$output" == *risk* ]]
  [[ "$output" != *rollback* ]]
}

@test "description-quality: a failed jq filter reads as empty and warns on stderr (#2605)" {
  bats_require_minimum_version 1.5.0
  jq() { [ "${1:-}" = "-Rrs" ] && return 3; command jq "$@"; }
  run --separate-stderr _desc $'## Why\n\nThe triage misreads bodies.\n\n## Risk\n\nlow'
  [ "$status" -eq 0 ]
  [[ "$output" == 5\|* ]]
  [[ "$stderr" == *"description filter (jq) failed with exit 3"* ]]
  unset -f jq
  run --separate-stderr _desc $'## Why\n\nThe triage misreads bodies.\n\n## Risk\n\nlow'
  [[ "$output" == 3\|* ]]
  [ -z "$stderr" ]
}
