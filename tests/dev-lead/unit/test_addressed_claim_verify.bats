#!/usr/bin/env bats
# Unit tests for scripts/lib/addressed-claim-verify.sh (#1692, epic #1621 story 2).
#
# The addressed-marker used to be an unverified assertion: resolve_addressed_bot_threads
# resolved a bot thread the moment its last reply carried `<!-- dev-lead:addressed -->`
# from our account, never checking whether the fix existed in the pushed diff (the
# PR #1044 byte-identical-functions defect). This lib is the pure verifier that makes
# the marker a *claim* checked against the diff, and scans ALL comments for a standing
# maintainer disposition. These tests exercise the pure helpers in isolation; the
# wiring into the harness is covered in test_fix_reviews.bats.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/addressed-claim-verify.sh"

SHA40="3cc4132fd4b4692aa20865f8b68ea8e21de604b8"

setup() {
  # shellcheck source=scripts/lib/addressed-claim-verify.sh
  source "$LIB"
}

# ---------------------------------------------------------------------------
# Sourcing safety
# ---------------------------------------------------------------------------

@test "addressed-claim-verify.sh is safe to source under set -euo pipefail" {
  run bash -c "set -euo pipefail; source '$LIB'"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

# ---------------------------------------------------------------------------
# acv_parse_claim — extraction + field contract
# ---------------------------------------------------------------------------

@test "acv_parse_claim: valid claim returns 0 and echoes canonical JSON" {
  local body="Fixed in scripts/lib/auto-merge.sh: added guard.

<!-- dev-lead:addressed -->
<!-- dev-lead:claim {\"v\":1,\"sha\":\"$SHA40\",\"files\":[\"scripts/lib/auto-merge.sh\",\"tests/auto_merge.bats\"]} -->"
  run acv_parse_claim "$body"
  [[ "$status" -eq 0 ]]
  [[ "$(echo "$output" | jq -r .sha)" == "$SHA40" ]]
  [[ "$(echo "$output" | jq -r '.files|length')" == "2" ]]
}

@test "acv_parse_claim: no claim comment (pre-migration marker only) -> no-claim, non-zero" {
  local body="Applied the fix.

<!-- dev-lead:addressed -->"
  run acv_parse_claim "$body"
  [[ "$status" -ne 0 ]]
  [[ "$output" == "no-claim" ]]
}

@test "acv_parse_claim: empty body -> no-claim, non-zero" {
  run acv_parse_claim ""
  [[ "$status" -ne 0 ]]
  [[ "$output" == "no-claim" ]]
}

@test "acv_parse_claim: two claim comments -> multiple-claims (never take the last)" {
  local body="Fixed it.
<!-- dev-lead:addressed -->
<!-- dev-lead:claim {\"v\":1,\"sha\":\"$SHA40\",\"files\":[\"a\"]} -->
<!-- dev-lead:claim {\"v\":1,\"sha\":\"$SHA40\",\"files\":[\"b\"]} -->"
  run acv_parse_claim "$body"
  [[ "$status" -ne 0 ]]
  [[ "$output" == "multiple-claims" ]]
}

@test "acv_parse_claim: malformed JSON -> malformed-json" {
  local body="Fixed it.
<!-- dev-lead:claim {\"v\":1, not json} -->"
  run acv_parse_claim "$body"
  [[ "$status" -ne 0 ]]
  [[ "$output" == "malformed-json" ]]
}

@test "acv_parse_claim: unrecognised schema version -> bad-version (never assume v1)" {
  local body="Fixed it.
<!-- dev-lead:claim {\"v\":2,\"sha\":\"$SHA40\",\"files\":[\"a\"]} -->"
  run acv_parse_claim "$body"
  [[ "$status" -ne 0 ]]
  [[ "$output" == "bad-version" ]]
}

@test "acv_parse_claim: abbreviated sha -> bad-sha (exact 40-char lookup only)" {
  local body="Fixed it.
<!-- dev-lead:claim {\"v\":1,\"sha\":\"3cc4132\",\"files\":[\"a\"]} -->"
  run acv_parse_claim "$body"
  [[ "$status" -ne 0 ]]
  [[ "$output" == "bad-sha" ]]
}

@test "acv_parse_claim: empty files array -> bad-files" {
  local body="Fixed it.
<!-- dev-lead:claim {\"v\":1,\"sha\":\"$SHA40\",\"files\":[]} -->"
  run acv_parse_claim "$body"
  [[ "$status" -ne 0 ]]
  [[ "$output" == "bad-files" ]]
}

@test "acv_parse_claim: a file path containing a space is preserved (JSON array, not IFS split)" {
  local body="Fixed it.
<!-- dev-lead:claim {\"v\":1,\"sha\":\"$SHA40\",\"files\":[\"dir with space/a.sh\"]} -->"
  run acv_parse_claim "$body"
  [[ "$status" -eq 0 ]]
  [[ "$(echo "$output" | jq -r '.files[0]')" == "dir with space/a.sh" ]]
}

# ---------------------------------------------------------------------------
# acv_verify_intersection — non-empty diff + file intersection (AC2/AC3)
# ---------------------------------------------------------------------------

@test "acv_verify_intersection: named commit's own diff touches a claimed file -> own" {
  run acv_verify_intersection '["scripts/foo.sh","x/y.bats"]' $'scripts/foo.sh\nunrelated.md' $'other.txt'
  [[ "$status" -eq 0 ]]
  [[ "$output" == "own" ]]
}

@test "acv_verify_intersection: only the cumulative range touches a claimed file -> cumulative" {
  run acv_verify_intersection '["scripts/foo.sh"]' $'unrelated.md' $'scripts/foo.sh\nother.txt'
  [[ "$status" -eq 0 ]]
  [[ "$output" == "cumulative" ]]
}

@test "acv_verify_intersection: empty diff in both ranges -> empty-diff (fail closed)" {
  run acv_verify_intersection '["scripts/foo.sh"]' '' ''
  [[ "$status" -ne 0 ]]
  [[ "$output" == "empty-diff" ]]
}

@test "acv_verify_intersection: diff touches no claimed file (PR #1044 shape) -> no-file-intersection" {
  run acv_verify_intersection '["scripts/foo.sh"]' $'scripts/bar.sh\nREADME.md' $'scripts/bar.sh\nREADME.md'
  [[ "$status" -ne 0 ]]
  [[ "$output" == "no-file-intersection" ]]
}

# ---------------------------------------------------------------------------
# acv_latest_maintainer_disposition — scan ALL comments (AC4)
# ---------------------------------------------------------------------------

@test "acv_latest_maintainer_disposition: no maintainer disposition -> rc1, empty" {
  local comments='[{"author":{"login":"donpetry-bot","__typename":"User"},"body":"Applied. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"}]'
  run acv_latest_maintainer_disposition "$comments" "donpetry-bot"
  [[ "$status" -eq 1 ]]
  [[ -z "$output" ]]
}

@test "acv_latest_maintainer_disposition: marker-less human 'required before merge' -> rc0 with its date" {
  local comments='[
    {"author":{"login":"a-maintainer","__typename":"User"},"body":"ACCEPTED — required before merge","createdAt":"2026-09-02T12:00:00Z"},
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Fixed. <!-- dev-lead:addressed -->","createdAt":"2026-09-02T13:00:00Z"}
  ]'
  run acv_latest_maintainer_disposition "$comments" "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2026-09-02T12:00:00Z" ]]
}

@test "acv_latest_maintainer_disposition: an agent-marker comment is never a maintainer disposition" {
  # Body says 'required' but carries our marker -> agent-authored -> ignored.
  local comments='[{"author":{"login":"don-petry","__typename":"User"},"body":"This was required. <!-- dev-lead:addressed -->","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_maintainer_disposition "$comments" "donpetry-bot"
  [[ "$status" -eq 1 ]]
  [[ -z "$output" ]]
}

@test "acv_latest_maintainer_disposition: disposition with unparseable date -> rc2 (fail closed)" {
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"body":"changes required","createdAt":""}]'
  run acv_latest_maintainer_disposition "$comments" "donpetry-bot"
  [[ "$status" -eq 2 ]]
  [[ "$output" == "unparseable" ]]
}

@test "acv_latest_maintainer_disposition: multiple dispositions -> latest date wins" {
  local comments='[
    {"author":{"login":"m1","__typename":"User"},"body":"REQUIRED","createdAt":"2026-09-01T00:00:00Z"},
    {"author":{"login":"m2","__typename":"User"},"body":"blocking issue here","createdAt":"2026-09-05T00:00:00Z"}
  ]'
  run acv_latest_maintainer_disposition "$comments" "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2026-09-05T00:00:00Z" ]]
}

@test "acv_latest_maintainer_disposition: a valid date alongside an unparseable one -> rc2 (fail closed, #2079 AC3)" {
  # The unparseable disposition's true order against the valid one is unknown, so it
  # must win — returning the valid date would let a fix that predates it resolve.
  local comments='[
    {"author":{"login":"m1","__typename":"User"},"body":"REQUIRED","createdAt":"2026-09-01T00:00:00Z"},
    {"author":{"login":"m2","__typename":"User"},"body":"blocking issue here","createdAt":""}
  ]'
  run acv_latest_maintainer_disposition "$comments" "donpetry-bot"
  [[ "$status" -eq 2 ]]
  [[ "$output" == "unparseable" ]]
}

@test "acv_latest_maintainer_disposition: skip-nochange ignores an affirmative 'no change required' (#2079)" {
  local comments='[{"author":{"login":"m","__typename":"User"},"body":"This is a false positive, no change required.","createdAt":"2026-09-01T00:00:00Z"}]'
  run acv_latest_maintainer_disposition "$comments" "donpetry-bot"
  [[ "$status" -eq 0 ]]
  run acv_latest_maintainer_disposition "$comments" "donpetry-bot" "skip-nochange"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_maintainer_disposition: skip-nochange still counts a separate 'must be fixed' in a no-change comment" {
  local comments='[{"author":{"login":"m","__typename":"User"},"body":"No change required here, but this must be fixed.","createdAt":"2026-09-04T00:00:00Z"}]'
  run acv_latest_maintainer_disposition "$comments" "donpetry-bot" "skip-nochange"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2026-09-04T00:00:00Z" ]]
}

@test "acv_latest_maintainer_disposition: skip-nochange still counts a real REQUIRED comment" {
  local comments='[{"author":{"login":"m","__typename":"User"},"body":"Required before merge.","createdAt":"2026-09-03T00:00:00Z"}]'
  run acv_latest_maintainer_disposition "$comments" "donpetry-bot" "skip-nochange"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2026-09-03T00:00:00Z" ]]
}

# ---------------------------------------------------------------------------
# acv_latest_nochange_disposition — the "no change needed" counterpart (#1743, #2079)
# The mirror of acv_latest_maintainer_disposition: a marker-less human maintainer
# who asserts a false positive / no-change disposition PERMITS resolution of a
# false-positive bot thread. Authorship is decided by MARKER + authorAssociation,
# never by login: dev-lead posts as the same account the maintainer uses
# (don-petry), so a login skip would discard the maintainer's own verdict (#2079).
# ---------------------------------------------------------------------------

@test "acv_latest_nochange_disposition: no no-change disposition -> rc1, empty" {
  local comments='[{"author":{"login":"donpetry-bot","__typename":"User"},"authorAssociation":"MEMBER","body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
  [[ -z "$output" ]]
}

@test "acv_latest_nochange_disposition: marker-less human 'no change needed' -> rc0 with its date" {
  local comments='[
    {"author":{"login":"gemini-code-assist[bot]","__typename":"Bot"},"body":"Missing closing backtick.","createdAt":"2026-09-01T09:00:00Z"},
    {"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"This is a false positive — no change needed.","createdAt":"2026-09-02T12:00:00Z"}
  ]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2026-09-02T12:00:00Z" ]]
}

@test "acv_latest_nochange_disposition: rejected/questioned phrase #0 is not a disposition -> rc1" {
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"I do not think this is a false positive.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_nochange_disposition: rejected/questioned phrase #1 is not a disposition -> rc1" {
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"I do not believe this is a false positive.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_nochange_disposition: rejected/questioned phrase #2 is not a disposition -> rc1" {
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"This is not, in my judgement, a false positive.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_nochange_disposition: rejected/questioned phrase #3 is not a disposition -> rc1" {
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"It'\''s not at all clear this is a false positive.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_nochange_disposition: rejected/questioned phrase #4 is not a disposition -> rc1" {
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"Could this be a false positive?","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_nochange_disposition: rejected/questioned phrase #5 is not a disposition -> rc1" {
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"I disagree with calling this a false positive.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_nochange_disposition: 'working as intended' is a no-change disposition -> rc0" {
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"Working as intended.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2026-09-02T12:00:00Z" ]]
}

@test "acv_latest_nochange_disposition: 'no change required' (collides with REQUIRED) -> classified as no-change rc0" {
  # The blocking regex matches the substring REQUIRED; the no-change intent must win
  # so a maintainer waving off a finding is not misread as a blocking demand.
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"No change required here.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2026-09-02T12:00:00Z" ]]
}

@test "acv_latest_nochange_disposition: an agent-marker comment is never a no-change disposition" {
  # Body says 'no change needed' but carries our marker -> agent-authored -> ignored,
  # so the agent cannot manufacture its own resolution authorization (#1743 AC4).
  local comments='[{"author":{"login":"don-petry","__typename":"User"},"authorAssociation":"MEMBER","body":"No change needed. <!-- dev-lead:addressed -->","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
  [[ -z "$output" ]]
}

@test "acv_latest_nochange_disposition: a bot comment is never a no-change disposition" {
  local comments='[{"author":{"login":"gemini-code-assist[bot]","__typename":"Bot"},"body":"No change needed on our end.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
  [[ -z "$output" ]]
}

@test "acv_latest_nochange_disposition: disposition with unparseable date -> rc2 (fail closed)" {
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"false positive","createdAt":""}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 2 ]]
  [[ "$output" == "unparseable" ]]
}

@test "acv_latest_nochange_disposition: multiple dispositions -> latest date wins" {
  local comments='[
    {"author":{"login":"m1","__typename":"User"},"authorAssociation":"MEMBER","body":"false positive","createdAt":"2026-09-01T00:00:00Z"},
    {"author":{"login":"m2","__typename":"User"},"authorAssociation":"MEMBER","body":"no change needed","createdAt":"2026-09-05T00:00:00Z"}
  ]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2026-09-05T00:00:00Z" ]]
}

@test "acv_latest_nochange_disposition: a later non-affirming maintainer comment supersedes the affirmation -> rc1" {
  local comments='[
    {"author":{"login":"m1","__typename":"User"},"authorAssociation":"MEMBER","body":"false positive","createdAt":"2026-09-01T00:00:00Z"},
    {"author":{"login":"m2","__typename":"User"},"authorAssociation":"OWNER","body":"Please look at the retry path again.","createdAt":"2026-09-05T00:00:00Z"}
  ]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
  [[ -z "$output" ]]
}

@test "acv_latest_nochange_disposition: neutral chatter is not a no-change disposition -> rc1" {
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"Thanks for looking into this.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
  [[ -z "$output" ]]
}

@test "acv_latest_nochange_disposition: negated 'this is not a false positive' does NOT authorize -> rc1" {
  # The broad phrase match would see FALSE POSITIVE; the negation guard must win so a
  # maintainer explicitly rejecting the false-positive verdict never clears the thread (#1799).
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"This is not a false positive, please fix it.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
  [[ -z "$output" ]]
}

@test "acv_latest_nochange_disposition: negated 'isn't working as intended' does NOT authorize -> rc1" {
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"This isn'"'"'t working as intended.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
  [[ -z "$output" ]]
}

@test "acv_latest_nochange_disposition: 'won'\''t fix' (affirmative) is still a no-change disposition -> rc0" {
  # The negator-lookalike WON'T is part of the affirmative phrase itself; it must not be
  # clobbered by the negation guard, which only fires when a negator precedes a phrase.
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"Won'"'"'t fix — intentional.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2026-09-02T12:00:00Z" ]]
}

@test "acv_latest_nochange_disposition: 'not a bug' (affirmative) is still a no-change disposition -> rc0" {
  # NOT A BUG begins with a negator but is an affirmative no-change phrase; it is excluded
  # from the negation guard's target set so it is never misread as a negated phrase.
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"Not a bug.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2026-09-02T12:00:00Z" ]]
}

@test "acv_latest_nochange_disposition: maintainer posting as the dev-lead account (same login) is accepted -> rc0 (#2079)" {
  # dev-lead's BOT_USER is don-petry — the maintainer's own account. A marker-less
  # reply from that login is the maintainer speaking and must count (the #1799 bug).
  local comments='[{"author":{"login":"don-petry","__typename":"User"},"authorAssociation":"OWNER","body":"False positive — no change needed.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2026-09-02T12:00:00Z" ]]
}

@test "acv_latest_nochange_disposition: dev-lead writing 'no change needed' can never dismiss a finding -> rc1 (#2079 AC4)" {
  # Same account, same association, same phrase as the accepted case above — only the
  # dev-lead marker differs. The agent's own statement must never authorize resolution.
  local comments='[
    {"author":{"login":"gemini-code-assist[bot]","__typename":"Bot"},"body":"Possible injection here.","createdAt":"2026-09-01T09:00:00Z"},
    {"author":{"login":"don-petry","__typename":"User"},"authorAssociation":"OWNER","body":"False positive — no change needed.\n<!-- dev-lead:reply -->","createdAt":"2026-09-02T12:00:00Z"}
  ]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
  [[ -z "$output" ]]
}

@test "acv_latest_nochange_disposition: pr-review-agent marker comment is never a no-change disposition -> rc1" {
  local comments='[{"author":{"login":"don-petry","__typename":"User"},"authorAssociation":"OWNER","body":"<!-- pr-review-agent -->\nNo change needed.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
  [[ -z "$output" ]]
}

@test "acv_latest_nochange_disposition: COLLABORATOR is a maintainer -> rc0" {
  local comments='[{"author":{"login":"a-collab","__typename":"User"},"authorAssociation":"COLLABORATOR","body":"Not applicable here.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2026-09-02T12:00:00Z" ]]
}

@test "acv_latest_nochange_disposition: non-maintainer association (CONTRIBUTOR/NONE/missing) -> rc1 (fail closed)" {
  local assoc
  for assoc in '"authorAssociation":"CONTRIBUTOR",' '"authorAssociation":"NONE",' ''; do
    local comments='[{"author":{"login":"drive-by","__typename":"User"},'"$assoc"'"body":"False positive, no change needed.","createdAt":"2026-09-02T12:00:00Z"}]'
    run acv_latest_nochange_disposition "$comments"
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
  done
}

@test "acv_latest_nochange_disposition: negated 'not applicable' / 'wouldn't call it a false positive' -> rc1" {
  local body
  for body in "This is not not applicable, please fix." "I wouldn't call it a false positive."; do
    local comments
    comments=$(jq -cn --arg b "$body" '[{"author":{"login":"m","__typename":"User"},"authorAssociation":"MEMBER","body":$b,"createdAt":"2026-09-02T12:00:00Z"}]')
    run acv_latest_nochange_disposition "$comments"
    [[ "$status" -eq 1 ]]
  done
}

@test "acv_latest_nochange_disposition: a valid date alongside an unparseable one -> rc2 (fail closed)" {
  local comments='[
    {"author":{"login":"m1","__typename":"User"},"authorAssociation":"MEMBER","body":"false positive","createdAt":"2026-09-01T00:00:00Z"},
    {"author":{"login":"m2","__typename":"User"},"authorAssociation":"MEMBER","body":"no change needed","createdAt":"not-a-date"}
  ]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 2 ]]
  [[ "$output" == "unparseable" ]]
}

@test "acv_latest_nochange_disposition: empty / invalid input -> rc1" {
  run acv_latest_nochange_disposition '[]'
  [[ "$status" -eq 1 ]]
  run acv_latest_nochange_disposition 'not json'
  [[ "$status" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# acv_latest_marker_index — find our addressed-marker reply anywhere in the thread (#1735 AC1)
# ---------------------------------------------------------------------------

@test "acv_latest_marker_index: our marker reply as the only comment -> index 0" {
  local comments='[{"author":{"login":"donpetry-bot","__typename":"User"},"body":"Applied. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"}]'
  run acv_latest_marker_index "$comments" "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "0" ]]
}

@test "acv_latest_marker_index: marker reply after a bot finding -> its index (not comments(last:1))" {
  local comments='[
    {"author":{"login":"codeant-ai[bot]","__typename":"Bot"},"body":"Potential issue here.","createdAt":"2026-09-01T09:00:00Z"},
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"}
  ]'
  run acv_latest_marker_index "$comments" "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "1" ]]
}

@test "acv_latest_marker_index: marker NOT the latest comment (bot ack follows) -> still found" {
  local comments='[
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"},
    {"author":{"login":"codeant-ai[bot]","__typename":"Bot"},"body":"Customized review instruction saved!","createdAt":"2026-09-01T11:00:00Z"}
  ]'
  run acv_latest_marker_index "$comments" "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "0" ]]
}

@test "acv_latest_marker_index: multiple of our markers -> latest index wins" {
  local comments='[
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"First. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"},
    {"author":{"login":"codeant-ai[bot]","__typename":"Bot"},"body":"still an issue","createdAt":"2026-09-01T11:00:00Z"},
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Second. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T12:00:00Z"}
  ]'
  run acv_latest_marker_index "$comments" "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2" ]]
}

@test "acv_latest_marker_index: no marker anywhere -> rc1 (unchanged no-marker behavior)" {
  local comments='[{"author":{"login":"donpetry-bot","__typename":"User"},"body":"Looked into it, no change.","createdAt":"2026-09-01T10:00:00Z"}]'
  run acv_latest_marker_index "$comments" "donpetry-bot"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_marker_index: marker from another account -> rc1 (not ours)" {
  local comments='[{"author":{"login":"someone-else","__typename":"User"},"body":"Applied. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"}]'
  run acv_latest_marker_index "$comments" "donpetry-bot"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_marker_index: empty array -> rc1" {
  run acv_latest_marker_index '[]' "donpetry-bot"
  [[ "$status" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# acv_bot_comment_is_acknowledgement — ack / finding / undeterminable (#1735 AC2/AC4)
# ---------------------------------------------------------------------------

@test "acv_bot_comment_is_acknowledgement: codeant 'Customized review instruction saved' -> rc0 (ack)" {
  run acv_bot_comment_is_acknowledgement "✅ Customized review instruction saved!"
  [[ "$status" -eq 0 ]]
}

@test "acv_bot_comment_is_acknowledgement: 'Acknowledged, will not flag this again' -> rc0 (ack)" {
  run acv_bot_comment_is_acknowledgement "Acknowledged. We will not flag this pattern again."
  [[ "$status" -eq 0 ]]
}

@test "acv_bot_comment_is_acknowledgement: a new finding -> rc1 (blocks)" {
  run acv_bot_comment_is_acknowledgement "Potential issue: this introduces a race condition on shutdown."
  [[ "$status" -eq 1 ]]
}

@test "acv_bot_comment_is_acknowledgement: ack phrasing mixed with a new finding -> rc1 (finding wins, fail toward blocking)" {
  run acv_bot_comment_is_acknowledgement "Instruction saved, but there is a new issue: unhandled null."
  [[ "$status" -eq 1 ]]
}

@test "acv_bot_comment_is_acknowledgement: undeterminable chatter -> rc2 (fail closed)" {
  run acv_bot_comment_is_acknowledgement "Interesting perspective on the tradeoffs here."
  [[ "$status" -eq 2 ]]
}

@test "acv_bot_comment_is_acknowledgement: empty body -> rc2 (fail closed)" {
  run acv_bot_comment_is_acknowledgement ""
  [[ "$status" -eq 2 ]]
}

@test "acv_bot_comment_is_acknowledgement: negated 'cannot acknowledge this' -> rc2 (not an ack, fail closed)" {
  run acv_bot_comment_is_acknowledgement "I cannot acknowledge this refutation as valid."
  [[ "$status" -eq 2 ]]
}

@test "acv_bot_comment_is_acknowledgement: negated 'unable to fully acknowledge' -> rc2 (not an ack, fail closed)" {
  run acv_bot_comment_is_acknowledgement "We are unable to fully acknowledge the change."
  [[ "$status" -eq 2 ]]
}

# ---------------------------------------------------------------------------
# acv_post_marker_clear — nothing unaddressed since our marker (#1735 AC2/AC3/AC4)
# ---------------------------------------------------------------------------

@test "acv_post_marker_clear: nothing after the marker -> clear rc0" {
  local comments='[{"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"}]'
  run acv_post_marker_clear "$comments" 0 "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clear" ]]
}

@test "acv_post_marker_clear: bot acknowledgement after our marker -> clear rc0 (AC2)" {
  local comments='[
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"},
    {"author":{"login":"codeant-ai[bot]","__typename":"Bot"},"body":"✅ Customized review instruction saved!","createdAt":"2026-09-01T11:00:00Z"}
  ]'
  run acv_post_marker_clear "$comments" 0 "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clear" ]]
}

@test "acv_post_marker_clear: bot NEW finding after our marker -> blocks rc1 (AC2)" {
  local comments='[
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"},
    {"author":{"login":"codeant-ai[bot]","__typename":"Bot"},"body":"Potential issue: new race condition on shutdown.","createdAt":"2026-09-01T11:00:00Z"}
  ]'
  run acv_post_marker_clear "$comments" 0 "donpetry-bot"
  [[ "$status" -eq 1 ]]
  [[ "$output" == "bot-finding" ]]
}

@test "acv_post_marker_clear: human comment after our marker ALWAYS blocks regardless of content -> rc1 (AC3, preserves #1415)" {
  local comments='[
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"},
    {"author":{"login":"a-maintainer","__typename":"User"},"body":"Looks fine to me, thanks.","createdAt":"2026-09-01T11:00:00Z"}
  ]'
  run acv_post_marker_clear "$comments" 0 "donpetry-bot"
  [[ "$status" -eq 1 ]]
  [[ "$output" == "human" ]]
}

@test "acv_post_marker_clear: undeterminable bot comment after our marker -> fail closed rc2 (AC4)" {
  local comments='[
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"},
    {"author":{"login":"codeant-ai[bot]","__typename":"Bot"},"body":"Interesting.","createdAt":"2026-09-01T11:00:00Z"}
  ]'
  run acv_post_marker_clear "$comments" 0 "donpetry-bot"
  [[ "$status" -eq 2 ]]
  [[ "$output" == "bot-ambiguous" ]]
}

@test "acv_post_marker_clear: our own later note after the marker is ours -> clear rc0" {
  local comments='[
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"},
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Rebased onto latest main.","createdAt":"2026-09-01T11:00:00Z"}
  ]'
  run acv_post_marker_clear "$comments" 0 "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clear" ]]
}

@test "acv_post_marker_clear: a post-marker comment carrying our marker is ours by the shared discriminator -> clear rc0" {
  # A User comment that carries one of our automation markers is agent-authored per
  # review_thread_is_agent_authored, so it is never treated as a human finding (#1735 AC3).
  local comments='[
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"},
    {"author":{"login":"don-petry","__typename":"User"},"body":"Follow-up note. <!-- dev-lead -->","createdAt":"2026-09-01T11:00:00Z"}
  ]'
  run acv_post_marker_clear "$comments" 0 "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clear" ]]
}

# ---------------------------------------------------------------------------
# acv_gather_commit_facts — the impure gatherer, against a real git repo
# ---------------------------------------------------------------------------

@test "acv_gather_commit_facts: reports on_head + own/cumulative files for a real commit" {
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  echo one > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" -c user.email=t@t -c user.name=T commit -q -m c0
  echo two > "$repo/b.txt"
  git -C "$repo" add b.txt
  git -C "$repo" -c user.email=t@t -c user.name=T commit -q -m c1
  local mid
  mid="$(git -C "$repo" rev-parse HEAD)"
  echo three > "$repo/c.txt"
  git -C "$repo" add c.txt
  git -C "$repo" -c user.email=t@t -c user.name=T commit -q -m c2

  run bash -c "cd '$repo' && source '$LIB' && acv_gather_commit_facts '$mid'"
  [[ "$status" -eq 0 ]]
  [[ "$(echo "$output" | jq -r .on_head)" == "true" ]]
  [[ "$(echo "$output" | jq -r '.own_files[0]')" == "b.txt" ]]
  # cumulative mid^..HEAD covers b.txt (mid) and c.txt (the later commit).
  [[ "$(echo "$output" | jq -c '.cumulative_files|sort')" == '["b.txt","c.txt"]' ]]
  # commit_date must be a Z-terminated UTC ISO-8601 instant (same shape as
  # GitHub's createdAt) so jq's fromdateiso8601 and the lexicographic disposition
  # comparison both accept it — a `%cI` `+00:00` offset would break both.
  local cdate
  cdate="$(echo "$output" | jq -r .commit_date)"
  [[ -n "$cdate" ]]
  [[ "$cdate" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  run bash -c "source '$LIB' && _acv_is_iso8601 '$cdate'"
  [[ "$status" -eq 0 ]]
}

@test "acv_gather_commit_facts: a sha absent from the repo -> on_head false, fail closed" {
  local repo="$BATS_TEST_TMPDIR/repo2"
  mkdir -p "$repo"
  git -C "$repo" init -q
  echo one > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" -c user.email=t@t -c user.name=T commit -q -m c0

  run bash -c "cd '$repo' && source '$LIB' && acv_gather_commit_facts 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'"
  [[ "$status" -eq 0 ]]
  [[ "$(echo "$output" | jq -r .on_head)" == "false" ]]
  [[ "$(echo "$output" | jq -c .own_files)" == "[]" ]]
}

# ---------------------------------------------------------------------------
# acv_claim_in_pass — the claim SHA must be a commit THIS pass produced (#2013)
# ---------------------------------------------------------------------------
# The thread-resolution gate used to accept any commit on the head branch whose
# <sha>^..HEAD range touched the claimed file, so a reply citing the PR's FIRST
# commit (the pre-pass head the model read with `git rev-parse HEAD` before it
# committed anything) passed trivially — the petry-projects/.github#1220 `571a3b8`
# case. A claim now verifies only when its commit is on the reference head AND
# is not already contained in the pre-pass base.

@test "acv_claim_in_pass: on ref and not in the pre-pass base -> in-pass rc0" {
  run acv_claim_in_pass "$SHA40" true false
  [[ "$status" -eq 0 ]]
  [[ "$output" == "in-pass" ]]
}

@test "acv_claim_in_pass: commit already in the pre-pass base (stale SHA) -> predates-pass rc1" {
  run acv_claim_in_pass "$SHA40" true true
  [[ "$status" -eq 1 ]]
  [[ "$output" == "predates-pass" ]]
}

@test "acv_claim_in_pass: commit not on the reference head -> not-on-ref rc1" {
  run acv_claim_in_pass "$SHA40" false false
  [[ "$status" -eq 1 ]]
  [[ "$output" == "not-on-ref" ]]
}

@test "acv_claim_in_pass: unknown pre-pass base -> unknown-base rc1 (fail closed)" {
  run acv_claim_in_pass "" true false
  [[ "$status" -eq 1 ]]
  [[ "$output" == "unknown-base" ]]
}

@test "acv_claim_in_pass: any non-'true'/'false' fact fails closed" {
  run acv_claim_in_pass "$SHA40" "" false
  [[ "$status" -eq 1 ]]
  [[ "$output" == "not-on-ref" ]]
  run acv_claim_in_pass "$SHA40" true ""
  [[ "$status" -eq 1 ]]
  [[ "$output" == "predates-pass" ]]
}

@test "acv_gather_commit_facts: with a base, PR commit A cited after this pass pushed B -> in_base true (predates-pass)" {
  # The QA fixture from #2013: the PR's own commit A touches F; this pass pushes B
  # (also touching F). A claim {sha:A, files:[F]} passes the old on-head +
  # intersection checks but must NOT verify as in-pass.
  local repo="$BATS_TEST_TMPDIR/repo3"
  mkdir -p "$repo"
  git -C "$repo" init -q
  echo one > "$repo/F"
  git -C "$repo" add F
  git -C "$repo" -c user.email=t@t -c user.name=T commit -q -m A
  local a
  a="$(git -C "$repo" rev-parse HEAD)"
  echo two >> "$repo/F"
  git -C "$repo" -c user.email=t@t -c user.name=T commit -q -am B
  local b
  b="$(git -C "$repo" rev-parse HEAD)"

  run bash -c "cd '$repo' && source '$LIB' && acv_gather_commit_facts '$a' '$a'"
  [[ "$status" -eq 0 ]]
  [[ "$(echo "$output" | jq -r .on_head)" == "true" ]]
  [[ "$(echo "$output" | jq -r .in_base)" == "true" ]]
  local facts_a on_head in_base
  facts_a="$output"
  on_head="$(echo "$facts_a" | jq -r .on_head)"; in_base="$(echo "$facts_a" | jq -r .in_base)"
  run bash -c "source '$LIB' && acv_claim_in_pass '$a' '$on_head' '$in_base'"
  [[ "$output" == "predates-pass" ]]

  # B — the commit this pass actually produced — is in-pass.
  run bash -c "cd '$repo' && source '$LIB' && acv_gather_commit_facts '$b' '$a'"
  on_head="$(echo "$output" | jq -r .on_head)"; in_base="$(echo "$output" | jq -r .in_base)"
  run bash -c "source '$LIB' && acv_claim_in_pass '$a' '$on_head' '$in_base'"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "in-pass" ]]
}

@test "acv_gather_commit_facts: an unresolvable base fails closed (in_base true)" {
  local repo="$BATS_TEST_TMPDIR/repo4"
  mkdir -p "$repo"
  git -C "$repo" init -q
  echo one > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" -c user.email=t@t -c user.name=T commit -q -m c0
  local h
  h="$(git -C "$repo" rev-parse HEAD)"
  run bash -c "cd '$repo' && source '$LIB' && acv_gather_commit_facts '$h' 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'"
  [[ "$(echo "$output" | jq -r .in_base)" == "true" ]]
  # No base given at all is also fail-closed.
  run bash -c "cd '$repo' && source '$LIB' && acv_gather_commit_facts '$h'"
  [[ "$(echo "$output" | jq -r .in_base)" == "true" ]]
}

@test "acv_gather_commit_facts: an explicit reference ref replaces HEAD for on_head" {
  # The retraction sweep checks claims against the REMOTE head, not local HEAD:
  # a commit that exists locally but never reached the remote is not on the ref.
  local repo="$BATS_TEST_TMPDIR/repo5"
  mkdir -p "$repo"
  git -C "$repo" init -q
  echo one > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" -c user.email=t@t -c user.name=T commit -q -m c0
  local base
  base="$(git -C "$repo" rev-parse HEAD)"
  echo two >> "$repo/a.txt"
  git -C "$repo" -c user.email=t@t -c user.name=T commit -q -am local-only
  local local_only
  local_only="$(git -C "$repo" rev-parse HEAD)"
  run bash -c "cd '$repo' && source '$LIB' && acv_gather_commit_facts '$local_only' '$base' '$base'"
  [[ "$(echo "$output" | jq -r .on_head)" == "false" ]]
  [[ "$(echo "$output" | jq -r .in_base)" == "false" ]]
}

@test "acv_latest_nochange_disposition: em-dash negation 'NOT — in my view — a false positive' -> rc1" {
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"This is NOT — in my view — a false positive.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_nochange_disposition: hedged 'may be a false positive' -> rc1" {
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"This may be a false positive.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_nochange_disposition: 'I decline to call this a false positive' -> rc1" {
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"I decline to call this a false positive.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_nochange_disposition: same-timestamp non-affirming comment fails closed -> rc1" {
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"This is a false positive.","createdAt":"2026-09-02T12:00:00Z"},{"author":{"login":"a-maintainer","__typename":"User"},"authorAssociation":"MEMBER","body":"Actually, please look again.","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments"
  [[ "$status" -eq 1 ]]
}

# ── #2079 AC4: dev-lead's own marker-less skip notes must never authorize ────────

@test "acv_latest_nochange_disposition: marker-less pass skip note 'No change needed in this pass' before the epoch -> rc1" {
  local comments='[{"author":{"login":"don-petry","__typename":"User"},"authorAssociation":"MEMBER","body":"No change needed in this pass: the guard already exists.","createdAt":"2026-10-09T07:58:15Z"}]'
  run acv_latest_nochange_disposition "$comments" "2026-10-10T00:00:00Z"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_nochange_disposition: marker-less 'Skipped: this is a false positive' before the epoch -> rc1" {
  local comments='[{"author":{"login":"don-petry","__typename":"User"},"authorAssociation":"MEMBER","body":"Skipped: this is a false positive, the helper is already called from the resolver.","createdAt":"2026-10-09T02:35:36Z"}]'
  run acv_latest_nochange_disposition "$comments" "2026-10-10T00:00:00Z"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_nochange_disposition: a stamped pass reply (<!-- dev-lead:reply -->) never authorizes -> rc1" {
  local comments='[{"author":{"login":"don-petry","__typename":"User"},"authorAssociation":"MEMBER","body":"No change needed in this pass: the guard already exists.\n\n<!-- dev-lead:reply -->","createdAt":"2026-10-11T07:58:15Z"}]'
  run acv_latest_nochange_disposition "$comments" "2026-10-10T00:00:00Z"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_nochange_disposition: marker-less maintainer comment after the epoch still authorizes -> rc0" {
  local comments='[{"author":{"login":"don-petry","__typename":"User"},"authorAssociation":"OWNER","body":"False positive, no change needed.","createdAt":"2026-10-11T08:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments" "2026-10-10T00:00:00Z"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2026-10-11T08:00:00Z" ]]
}

@test "acv_latest_nochange_disposition: a pre-epoch legacy note does not hide a later real affirmation" {
  local comments='[{"author":{"login":"don-petry","__typename":"User"},"authorAssociation":"MEMBER","body":"Skipped: this is a false positive.","createdAt":"2026-10-09T02:35:36Z"},{"author":{"login":"don-petry","__typename":"User"},"authorAssociation":"OWNER","body":"Confirmed, false positive.","createdAt":"2026-10-11T08:00:00Z"}]'
  run acv_latest_nochange_disposition "$comments" "2026-10-10T00:00:00Z"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2026-10-11T08:00:00Z" ]]
}
