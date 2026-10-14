#!/usr/bin/env bats
# Unit + gh-wrapper coverage for the carry-forward decision (issue #1865).
#
# Two layers:
#   1. Pure helpers (cf_prior_decision / cf_all_intervening_are_base_merges /
#      cf_diffs_identical / cf_merge_introduces_only_base / cf_parent_in_base) —
#      exercised directly with crafted JSON, no network.
#   2. evaluate_carry_forward — driven end-to-end against a `gh` PATH stub that
#      answers every compare/commit call from files under $TEST_DIR, so the whole
#      decision path for AC #1–#4 runs with a fully mocked gh surface and no live
#      network.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  # shellcheck source=../scripts/lib/carry-forward.sh
  source "$REPO_ROOT/scripts/lib/carry-forward.sh"

  export REPO="petry-projects/.github-private"
  export BASE_REF="main"
  export BASE_TIP="base000tip"
  export PRIOR_SHA="prior00sha"
  export HEAD_SHA="head000sha"
  export MERGE_SHA="merge01sha"
  export BASE_COMMIT="basec01sha"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  export GH_LOG="$TEST_DIR/gh_calls.log"
  : > "$GH_LOG"

  # gh stub: dispatch by request shape, echo canned bodies from $TEST_DIR files.
  # A missing file cats to empty output, which the wrapper treats as an API error
  # (fail toward reviewing) — used by the AC #4 test.
  cat > "$TEST_DIR/bin/gh" <<'GHEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
case "$args" in
  *vnd.github.v3.diff*)
    case "$args" in
      *"$PRIOR_SHA"*) cat "$TEST_DIR/prior.diff" 2>/dev/null ;;
      *)              cat "$TEST_DIR/head.diff"  2>/dev/null ;;
    esac ;;
  *"--jq .status"*) cat "$TEST_DIR/parent_status" 2>/dev/null ;;
  *files*)
    case "$args" in
      *"commits/"*) cat "$TEST_DIR/merge_files.json" 2>/dev/null ;;
      *)            cat "$TEST_DIR/base_delta.json"  2>/dev/null ;;
    esac ;;
  *"commits/"*"--jq"*) cat "$TEST_DIR/base_tip" 2>/dev/null ;;
  *"compare/"*)        cat "$TEST_DIR/compare_commits.json" 2>/dev/null ;;
esac
exit 0
GHEOF
  chmod +x "$TEST_DIR/bin/gh"
  export PATH="$TEST_DIR/bin:$PATH"

  # Default happy-path fixtures (AC #1 carry). Individual tests override files.
  echo "$BASE_TIP" > "$TEST_DIR/base_tip"
  echo "ahead" > "$TEST_DIR/parent_status"
  printf 'diff --git a/a.txt b/a.txt\n+hello\n' > "$TEST_DIR/prior.diff"
  printf 'diff --git a/a.txt b/a.txt\n+hello\n' > "$TEST_DIR/head.diff"
  jq -n --arg m "$MERGE_SHA" --arg p1 "$PRIOR_SHA" --arg p2 "$BASE_COMMIT" \
    '{commits:[{sha:$m, parents:[{sha:$p1},{sha:$p2}]}]}' > "$TEST_DIR/compare_commits.json"
  jq -n '[{filename:"lib/base.sh", sha:"blobBASE"}]' > "$TEST_DIR/merge_files.json"
  jq -n '[{filename:"lib/base.sh", sha:"blobBASE"}]' > "$TEST_DIR/base_delta.json"
}

teardown() { rm -rf "$TEST_DIR"; }

run_eval() { run evaluate_carry_forward "$REPO" "$BASE_REF" "$PRIOR_SHA" "$HEAD_SHA"; }

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

@test "cf_prior_decision extracts approved/escalated/fix-requested" {
  run cf_prior_decision '<!-- pr-review-agent v1 sha=abc123 decision=approved risk=LOW -->'
  [ "$output" = "approved" ]
  run cf_prior_decision '<!-- pr-review-agent v1 sha=abc123 decision=escalated risk=HIGH -->'
  [ "$output" = "escalated" ]
  run cf_prior_decision '<!-- pr-review-agent v1 sha=abc123 --> <!-- decision=fix-requested risk=LOW -->'
  [ "$output" = "fix-requested" ]
  run cf_prior_decision 'no marker here'
  [ "$output" = "" ]
}

@test "cf_prior_risk extracts LOW/MEDIUM/HIGH and defaults to LOW" {
  run cf_prior_risk '<!-- pr-review-agent v1 sha=abc123 decision=approved risk=HIGH -->'
  [ "$output" = "HIGH" ]
  run cf_prior_risk '<!-- pr-review-agent v1 sha=abc123 decision=approved risk=MEDIUM -->'
  [ "$output" = "MEDIUM" ]
  run cf_prior_risk '<!-- pr-review-agent v1 sha=abc123 decision=approved risk=LOW -->'
  [ "$output" = "LOW" ]
  # No risk token -> LOW default (and no SIGPIPE/abort under set -e -o pipefail).
  run cf_prior_risk 'no marker here'
  [ "$output" = "LOW" ]
}

@test "cf_all_intervening_are_base_merges: all merges pass, content commit fails, empty fails" {
  run cf_all_intervening_are_base_merges '[{"sha":"m1","parents":[{"sha":"a"},{"sha":"b"}]}]'
  [ "$status" -eq 0 ]

  run cf_all_intervening_are_base_merges '[{"sha":"m1","parents":[{"sha":"a"},{"sha":"b"}]},{"sha":"c1","parents":[{"sha":"a"}]}]'
  [ "$status" -eq 1 ]
  [[ "$output" == content-commit:c1* ]]

  run cf_all_intervening_are_base_merges '[]'
  [ "$status" -eq 1 ]
  [ "$output" = "no-intervening-commits" ]
}

@test "cf_merge_introduces_only_base: base-only subset clean, foreign blob dirty" {
  run cf_merge_introduces_only_base '[{"filename":"a","sha":"x"}]' '[{"filename":"a","sha":"x"},{"filename":"b","sha":"y"}]'
  [ "$status" -eq 0 ]

  # Resolved-conflict blob: merge result differs from base's blob for the same file.
  run cf_merge_introduces_only_base '[{"filename":"a","sha":"RESOLVED"}]' '[{"filename":"a","sha":"x"}]'
  [ "$status" -eq 1 ]

  # Merge touched a file the base delta never touched -> author content.
  run cf_merge_introduces_only_base '[{"filename":"c","sha":"z"}]' '[{"filename":"a","sha":"x"}]'
  [ "$status" -eq 1 ]
}

@test "cf_parent_in_base: ahead/identical pass, diverged/behind fail" {
  run cf_parent_in_base ahead;     [ "$status" -eq 0 ]
  run cf_parent_in_base identical; [ "$status" -eq 0 ]
  run cf_parent_in_base diverged;  [ "$status" -eq 1 ]
  run cf_parent_in_base behind;    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# evaluate_carry_forward — full decision path over a mocked gh surface
# ---------------------------------------------------------------------------

@test "AC#1: conflict-free base merge with identical diff-vs-merge-base -> carry" {
  run_eval
  [ "$status" -eq 0 ]
  [ "$output" = "carry" ]
}

@test "AC#2: a merge that resolved conflicts -> full, even when the final diff matches" {
  # Endpoint diffs stay byte-identical (the coincidence AC #2 calls out)…
  # …but the merge's resulting blob differs from the base's blob for that file.
  jq -n '[{filename:"lib/base.sh", sha:"blobRESOLVED"}]' > "$TEST_DIR/merge_files.json"
  jq -n '[{filename:"lib/base.sh", sha:"blobBASE"}]'     > "$TEST_DIR/base_delta.json"
  run_eval
  [ "$status" -eq 0 ]
  [[ "$output" == full:conflict-or-content:* ]]
}

@test "AC#3: an intervening non-merge (content) commit -> full" {
  jq -n --arg c "content1sha" --arg p "$PRIOR_SHA" \
    '{commits:[{sha:$c, parents:[{sha:$p}]}]}' > "$TEST_DIR/compare_commits.json"
  run_eval
  [ "$status" -eq 0 ]
  [[ "$output" == full:content-commit:content1sha ]]
}

@test "AC#3b: a mix of a base merge and a content commit -> full" {
  jq -n --arg m "$MERGE_SHA" --arg p1 "$PRIOR_SHA" --arg p2 "$BASE_COMMIT" --arg c "code9sha" \
    '{commits:[{sha:$m, parents:[{sha:$p1},{sha:$p2}]},{sha:$c, parents:[{sha:$m}]}]}' \
    > "$TEST_DIR/compare_commits.json"
  run_eval
  [ "$status" -eq 0 ]
  [[ "$output" == full:content-commit:code9sha ]]
}

@test "AC#4: compare API failure -> full (never carries on an unknown state)" {
  rm -f "$TEST_DIR/compare_commits.json"   # stub now emits empty -> treated as API error
  run_eval
  [ "$status" -eq 0 ]
  [[ "$output" == full:compare-* ]]
}

@test "AC#4b: unresolvable base tip -> full" {
  rm -f "$TEST_DIR/base_tip"
  run_eval
  [ "$status" -eq 0 ]
  [ "$output" = "full:base-tip-unresolved" ]
}

@test "AC#1-neg: diff-vs-merge-base changed -> full" {
  printf 'diff --git a/a.txt b/a.txt\n+goodbye\n' > "$TEST_DIR/head.diff"
  run_eval
  [ "$status" -eq 0 ]
  [ "$output" = "full:diff-changed" ]
}

@test "compare truncated (total_commits exceeds the returned commits) -> full" {
  # The compare API caps at 250 commits even under --paginate and reports the true
  # count in total_commits. A larger total means commits were omitted, so the guard
  # must fail toward reviewing rather than carry over an unverified commit (#1870).
  jq -n --arg m "$MERGE_SHA" --arg p1 "$PRIOR_SHA" --arg p2 "$BASE_COMMIT" \
    '{commits:[{sha:$m, parents:[{sha:$p1},{sha:$p2}]}], total_commits:2}' \
    > "$TEST_DIR/compare_commits.json"
  run_eval
  [ "$status" -eq 0 ]
  [ "$output" = "full:compare-truncated" ]
}

@test "foreign merge (base-side parent not on base branch) -> full" {
  echo "diverged" > "$TEST_DIR/parent_status"
  run_eval
  [ "$status" -eq 0 ]
  [ "$output" = "full:foreign-merge" ]
}
