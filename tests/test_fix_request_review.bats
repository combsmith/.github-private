#!/usr/bin/env bats
# Unit tests for scripts/lib/fix-request-review.sh (#2614).
#
# pr-review posts a delegated fix request as a COMMENT review: each finding that
# cites a line becomes an inline comment, and findings without a line stay in the
# review body. These helpers split the verdict's findings and build the reviews-API
# payload; they are pure (no gh, no network).

setup() {
  LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/lib/fix-request-review.sh"
  # shellcheck source=../scripts/lib/fix-request-review.sh
  source "$LIB"
  SHA="d53a7fc6b0718dd3d672fed4eec8394e5d372900"
  VF="$BATS_TEST_TMPDIR/verdict.json"
}

_verdict() { # <findings-json>
  jq -n --argjson f "$1" '{decision:"escalate", risk:"LOW", summary:"s", body:"b", findings:$f}' > "$VF"
}

@test "frr: a finding with a file and a positive line is line-cited" {
  _verdict '[{"severity":"major","category":"bug","message":"off by one","file":"scripts/a.sh","line":12}]'
  run frr_located_findings "$VF" "$SHA"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.[0].path' <<< "$output")" = "scripts/a.sh" ]
  [ "$(jq -r '.[0].line' <<< "$output")" = "12" ]
  [ "$(jq -r '.[0].side' <<< "$output")" = "RIGHT" ]
  body=$(jq -r '.[0].body' <<< "$output")
  [[ "$body" == "<!-- pr-review-agent finding sha=$SHA -->"* ]]
  [[ "$body" == *"**MAJOR**"* ]]
  [[ "$body" == *"off by one"* ]]
}

@test "frr: a numeric-string line counts; ./ is stripped from the path" {
  _verdict '[{"severity":"minor","message":"m","file":"./lib/x.sh","line":"7"}]'
  run frr_located_findings "$VF" "$SHA"
  [ "$(jq -r '.[0].path' <<< "$output")" = "lib/x.sh" ]
  [ "$(jq '.[0].line' <<< "$output")" = "7" ]
}

@test "frr: findings without a usable line are not line-cited" {
  _verdict '[
    {"severity":"minor","message":"no file","file":null,"line":null},
    {"severity":"minor","message":"file only","file":"a.sh","line":null},
    {"severity":"minor","message":"zero line","file":"a.sh","line":0},
    {"severity":"minor","message":"text line","file":"a.sh","line":"<number or null>"},
    {"severity":"minor","message":"line only","line":4}
  ]'
  run frr_located_findings "$VF" "$SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  run frr_unlocated_findings_md "$VF"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^- ' <<< "$output")" -eq 5 ]
  [[ "$output" == *'file only'* ]]
  [[ "$output" == *'`a.sh`'* ]]
}

@test "frr: line-cited findings never appear in the line-less list" {
  _verdict '[{"severity":"major","message":"cited","file":"a.sh","line":3},{"severity":"info","message":"general","file":null,"line":null}]'
  run frr_unlocated_findings_md "$VF"
  [[ "$output" == *"general"* ]]
  [[ "$output" != *"cited"* ]]
}

@test "frr: description is used when message is absent" {
  _verdict '[{"severity":"MAJOR","description":"described","file":"a.sh","line":2}]'
  run frr_located_findings "$VF" "$SHA"
  [[ "$(jq -r '.[0].body' <<< "$output")" == *"described"* ]]
}

@test "frr: more than FRR_MAX_INLINE line-cited findings overflow into the body list" {
  _verdict "$(jq -n '[range(0; 5) | {severity:"minor", message:("f\(.)"), file:"a.sh", line:(. + 1)}]')"
  FRR_MAX_INLINE=3
  run frr_located_findings "$VF" "$SHA"
  [ "$(jq 'length' <<< "$output")" -eq 3 ]
  run frr_unlocated_findings_md "$VF"
  [ "$(grep -c '^- ' <<< "$output")" -eq 2 ]
  [[ "$output" == *'`a.sh:4`'* ]]
  [[ "$output" == *'`a.sh:5`'* ]]
}

@test "frr: has_findings is false for a missing, empty or non-array findings field" {
  jq -n '{decision:"escalate"}' > "$VF"
  run frr_has_findings "$VF"; [ "$status" -ne 0 ]
  _verdict '[]'
  run frr_has_findings "$VF"; [ "$status" -ne 0 ]
  jq -n '{findings:"text"}' > "$VF"
  run frr_has_findings "$VF"; [ "$status" -ne 0 ]
  _verdict '[{"message":"x"}]'
  run frr_has_findings "$VF"; [ "$status" -eq 0 ]
}

@test "frr: the payload is a COMMENT review bound to the head commit, never REQUEST_CHANGES" {
  printf 'review body\n' > "$BATS_TEST_TMPDIR/body.md"
  _verdict '[{"severity":"major","message":"m","file":"a.sh","line":3}]'
  comments=$(frr_located_findings "$VF" "$SHA")
  run frr_review_payload "$SHA" "$BATS_TEST_TMPDIR/body.md" "$comments"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.event' <<< "$output")" = "COMMENT" ]
  [ "$(jq -r '.commit_id' <<< "$output")" = "$SHA" ]
  [ "$(jq -r '.body' <<< "$output")" = "review body" ]
  [ "$(jq '.comments | length' <<< "$output")" -eq 1 ]
  ! grep -q REQUEST_CHANGES <<< "$output" || false
}

@test "frr: the payload omits comments when there are none" {
  printf 'b' > "$BATS_TEST_TMPDIR/body.md"
  run frr_review_payload "$SHA" "$BATS_TEST_TMPDIR/body.md" "[]"
  [ "$(jq 'has("comments")' <<< "$output")" = "false" ]
}

@test "frr: located_as_md renders inline comments as path:line bullets for the fallback" {
  _verdict '[{"severity":"major","message":"cited one","file":"a.sh","line":3}]'
  comments=$(frr_located_findings "$VF" "$SHA")
  run frr_located_as_md "$comments"
  [ "$status" -eq 0 ]
  [[ "$output" == '- `a.sh:3`'* ]]
  [[ "$output" == *"cited one"* ]]
  [[ "$output" != *"pr-review-agent finding"* ]]
}
