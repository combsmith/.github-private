#!/usr/bin/env bats
# Tests for maintainer-comment-gate.sh (issues #1290, #1813)
#
# #1813 redesign: "addressed" is no longer a timestamp proxy against the head
# push (pushedDate is always null, and a push says nothing about whether a
# comment's finding was researched, answered, and resolved). Instead, a PR issue
# comment is "addressed" only once it carries a VERIFIED DISPOSITION — surfaced
# server-side as the comment being minimized with classifier RESOLVED (the
# harness minimizes it after verifying dev-lead's disposition reply). The gate
# withholds pr-review's approval while ANY non-agent issue comment lacks that
# signal — bots and humans alike, with the ONLY exclusion being our own account
# and our own agent-marked disposition/ack/note replies. It FAILS CLOSED: an
# undeterminable snapshot blocks and is reported distinctly (never disguised as
# the legitimate hold).
#
# check_maintainer_comments <pr_snapshot_json> [bot_user]
#   0 = every non-agent issue comment is minimized RESOLVED (or none exist)
#   1 = at least one non-agent issue comment lacks a verified disposition → block
#   2 = snapshot could not be evaluated (malformed) → fail closed → block

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME%/*}")" && pwd)/../../scripts"
  GATE="$SCRIPT_DIR/lib/maintainer-comment-gate.sh"
}

teardown() {
  unset SCRIPT_DIR
}

_run_check() {
  # _run_check <json> [bot_user]
  run bash -c "source '$GATE'; check_maintainer_comments \"\$1\" \"\$2\"" _ "$1" "${2:-donpetry-bot}"
}

# ────────────────────────────────────────────────────────────────────
# STRUCTURAL TESTS
# ────────────────────────────────────────────────────────────────────

@test "Maintainer gate: script is executable" {
  [ -x "$GATE" ]
}

@test "Maintainer gate: script has correct shebang" {
  head -1 "$GATE" | grep -q "^#!/usr/bin/env bash"
}

@test "Maintainer gate: script uses set -euo pipefail" {
  grep -q "^set -euo pipefail" "$GATE"
}

@test "Maintainer gate: defines check_maintainer_comments function" {
  grep -q "check_maintainer_comments()" "$GATE"
}

@test "Maintainer gate: BASH_SOURCE guard prevents source-time execution" {
  grep -q 'if \[\[ "${BASH_SOURCE\[0\]}" = "${0}" \]\]' "$GATE"
}

@test "Maintainer gate: shellcheck passes" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  shellcheck --shell=bash --severity=warning "$GATE"
}

# AC1 — no pushedDate dependency anywhere in the gate.
@test "AC1: gate reads no pushedDate field" {
  ! grep -q "pushedDate" "$GATE"
}

# AC1 — the head-time helper (still used by the review-thread gate) uses committer.date.
@test "AC1: head-time helper uses committer.date, not pushedDate" {
  grep -q 'commit{committer{date}}' "$GATE"
  ! grep -q "pushedDate" "$GATE"
}

# ────────────────────────────────────────────────────────────────────
# RUNTIME BEHAVIOR TESTS
# ────────────────────────────────────────────────────────────────────

@test "Runtime: no comments → 0 (nothing to block on)" {
  _run_check '{"comments":[],"reviews":[]}'
  [ "$status" -eq 0 ]
}

@test "Runtime: null comments field is treated as no findings → 0" {
  _run_check '{"reviews":[]}'
  [ "$status" -eq 0 ]
}

# AC9(b): an undispositioned codeant-ai comment blocks.
@test "AC9b: undispositioned codeant-ai comment → 1 (block)" {
  local json='{"comments":[{"author":{"login":"codeant-ai"},"body":"## CodeAnt AI — Review Status","createdAt":"2026-09-13T04:23:06Z","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

# AC9(b): an undispositioned qodo-code-review FINDING blocks. (Its trial-ended
# service notice is now auto-cleared via an info_status_pattern, #1995 — covered
# by the #1995 tests below — so this case uses a genuine finding, which carries no
# info-status pattern and must still block.)
@test "AC9b: undispositioned qodo-code-review finding → 1 (block)" {
  local json='{"comments":[{"author":{"login":"qodo-code-review"},"body":"PR Review: `parseConfig` does not validate the timeout bound before use.","createdAt":"2026-09-13T04:23:06Z","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

# AC9(b): an undispositioned auto-rebase-conflict comment (authored by don-petry,
# NOT one of our agent markers) blocks — a conflict report is a finding.
@test "AC9b: undispositioned auto-rebase-conflict comment → 1 (block)" {
  local json='{"comments":[{"author":{"login":"don-petry"},"body":"<!-- auto-rebase-conflict:56d8ccc7 --> Auto-rebase failed — merge conflict.","createdAt":"2026-09-13T04:28:56Z","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

# AC9(a): pushedDate is irrelevant; every comment minimized RESOLVED → passes.
# The comments carry gh pr view's includesCreatedEdit:false (never edited): since
# #2008 a RESOLVED registered-bot comment whose edit state is unknown fails closed.
@test "AC9a: all non-agent comments minimized RESOLVED → 0 (clear)" {
  local json='{"comments":[{"author":{"login":"codeant-ai"},"body":"Review Status","createdAt":"2026-09-13T04:23:06Z","includesCreatedEdit":false,"isMinimized":true,"minimizedReason":"resolved"},{"author":{"login":"qodo-code-review"},"body":"Trial ended.","createdAt":"2026-09-13T04:23:06Z","includesCreatedEdit":false,"isMinimized":true,"minimizedReason":"resolved"}]}'
  _run_check "$json"
  [ "$status" -eq 0 ]
}

@test "Runtime: mix of resolved + one unresolved non-agent comment → 1 (block)" {
  local json='{"comments":[{"author":{"login":"codeant-ai"},"body":"Status","createdAt":"2026-09-13T04:23:06Z","includesCreatedEdit":false,"isMinimized":true,"minimizedReason":"resolved"},{"author":{"login":"a-maintainer"},"body":"Please fix this.","createdAt":"2026-09-13T05:00:00Z","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

@test "Runtime: comment minimized for a NON-resolved reason (outdated) still blocks → 1" {
  local json='{"comments":[{"author":{"login":"codeant-ai"},"body":"Status","createdAt":"2026-09-13T04:23:06Z","isMinimized":true,"minimizedReason":"outdated"}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

# AC9(e): our own disposition/ack reply never blocks the gate (loop safety).
@test "AC9e: our dev-lead comment-disposition reply is ignored → 0" {
  local json='{"comments":[{"author":{"login":"don-petry"},"body":"Researched and answered.\n<!-- dev-lead:comment-disposition id=123 disposition=answered -->","createdAt":"2026-09-13T06:00:00Z","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 0 ]
}

@test "Runtime: our own pr-review agent-marked comment is ignored → 0" {
  local json='{"comments":[{"author":{"login":"donpetry-bot"},"body":"<!-- pr-review-agent v1 sha=abc123 --> Review posted.","createdAt":"2026-09-13T06:00:00Z","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 0 ]
}

@test "Runtime: bot_user's own plain comment is ignored → 0" {
  local json='{"comments":[{"author":{"login":"donpetry-bot"},"body":"CI is still running.","createdAt":"2026-09-13T06:00:00Z","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json" 'donpetry-bot'
  [ "$status" -eq 0 ]
}

@test "Runtime: dependency-advisory comment (posted as don-petry, marked) is ignored → 0" {
  local json='{"comments":[{"author":{"login":"don-petry"},"body":"<!-- dependency-advisory -->\n## Dependency Advisory\nNo issues.","createdAt":"2026-09-13T06:00:00Z","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 0 ]
}

# ────────────────────────────────────────────────────────────────────
# #1919 — dev-lead's OWN acknowledgement/note comments must carry a marker.
# The gate discriminates by marker, not author (dev-lead posts as don-petry,
# a human login), so an UNMARKED "Acknowledged — …" prose comment leaks
# through as a fresh blocker while a marked one is correctly excluded.
# ────────────────────────────────────────────────────────────────────

# AC3: a dev-lead acknowledgement of a non-actionable bot notice, carrying the
# <!-- dev-lead:ack --> marker, does NOT increment the undispositioned count → 0.
@test "AC3: dev-lead :ack marked acknowledgement is ignored → 0" {
  local json='{"comments":[{"author":{"login":"don-petry"},"body":"Acknowledged — this is a CodeRabbit rate-limit notice, not an actionable finding. No action needed.\n<!-- dev-lead:ack -->","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 0 ]
}

# AC3: the failing-check fix note dev-lead posts as a PR comment (review-changes.md)
# carries the <!-- dev-lead:check-fix --> marker and is excluded → 0.
@test "AC3: dev-lead :check-fix marked comment is ignored → 0" {
  local json='{"comments":[{"author":{"login":"don-petry"},"body":"`bats` verifies the test tooling is installed the documented way; this diff removes the vendored node_modules/bats.\n<!-- dev-lead:check-fix -->","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 0 ]
}

# AC3 (the defect): the exact UNMARKED prose acknowledgement from the #1919
# evidence still blocks — it is the MISSING marker, not the author, that let it
# leak. This is what the marker convention on the emitting paths prevents.
@test "AC3: an UNMARKED 'Acknowledged — …' prose comment still blocks → 1" {
  local json='{"comments":[{"author":{"login":"don-petry"},"body":"Acknowledged — this is a Qodo trial-ended/billing notice, not a code finding. No action needed.","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

@test "Runtime: malformed snapshot → 2 (fail closed)" {
  _run_check 'not json at all {'
  [ "$status" -eq 2 ]
}

# ────────────────────────────────────────────────────────────────────
# #1918 — data-driven info-status classifier (SonarCloud clean passes)
# ────────────────────────────────────────────────────────────────────

# SonarCloud's real "Quality Gate passed" comment shape (trimmed): the headline plus
# per-metric lines. `_sonar_body <new_issues> <hotspots>` renders it with the given
# counts; `_sonar_json <login> <body> [reviews_json]` wraps it in a gate snapshot.
_sonar_body() {
  printf '%s' "## [![Quality Gate Passed](https://sonarsource.github.io/qg-passed-20px.png 'Quality Gate Passed')](https://sonarcloud.io/dashboard) **Quality Gate passed**  
Issues  
![](https://sonarsource.github.io/passed-16px.png '') [$1 New issues](https://sonarcloud.io/project/issues)  
![](https://sonarsource.github.io/accepted-16px.png '') [0 Accepted issues](https://sonarcloud.io/project/issues)

Measures  
![](https://sonarsource.github.io/passed-16px.png '') [$2 Security Hotspots](https://sonarcloud.io/project/security_hotspots)  
![](https://sonarsource.github.io/passed-16px.png '') [0.0% Coverage on New Code](https://sonarcloud.io/component_measures)"
}
_sonar_json() {
  jq -cn --arg l "$1" --arg b "$2" --argjson r "${3:-[]}" \
    '{reviews:$r, comments:[{author:{login:$l}, body:$b, isMinimized:false, minimizedReason:""}]}'
}

# AC1: a clean SonarCloud "Quality Gate passed" status comment (0 new issues, 0
# security hotspots) clears the gate with NO dev-lead and NO human — the classifier
# is keyed off the reviewer-source registry (sonarqubecloud + its info_status_pattern).
@test "AC1: SonarCloud 'Quality Gate passed' (0 new issues, 0 hotspots) clears → 0" {
  _run_check "$(_sonar_json sonarqubecloud "$(_sonar_body 0 0)")"
  [ "$status" -eq 0 ]
}

# AC1: the App login may surface with a [bot] suffix in some read shapes; it must
# still match the bare registry login.
@test "AC1: SonarCloud clean pass with a [bot] suffix login clears → 0" {
  _run_check "$(_sonar_json 'sonarqubecloud[bot]' "$(_sonar_body 0 0)")"
  [ "$status" -eq 0 ]
}

# AC1 precision (#1918 review): a gate can PASS while still reporting new issues or
# security hotspots (depends on the gate's conditions). Those are findings — the
# headline alone must not clear them.
@test "AC1: 'Quality Gate passed' but 2 New issues still blocks → 1" {
  _run_check "$(_sonar_json sonarqubecloud "$(_sonar_body 2 0)")"
  [ "$status" -eq 1 ]
}

@test "AC1: 'Quality Gate passed' but 1 Security Hotspot still blocks → 1" {
  _run_check "$(_sonar_json sonarqubecloud "$(_sonar_body 0 1)")"
  [ "$status" -eq 1 ]
}

@test "AC1: '10 New issues' is not mistaken for '0 New issues' → 1" {
  _run_check "$(_sonar_json sonarqubecloud "$(_sonar_body 10 0)")"
  [ "$status" -eq 1 ]
}

@test "AC1: bare 'Quality Gate passed' text without the zero-count lines blocks → 1" {
  _run_check "$(_sonar_json sonarqubecloud "Quality Gate passed")"
  [ "$status" -eq 1 ]
}

# AC2: a SonarCloud "Quality Gate failed" comment still blocks — it carries findings.
@test "AC2: SonarCloud 'Quality Gate failed' comment blocks → 1" {
  local json='{"comments":[{"author":{"login":"sonarqubecloud"},"body":"## Quality Gate failed\n\n2 new issues.","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

# AC2: an unclassifiable SonarCloud comment (author registered, body does NOT match
# its info-status pattern) fails closed and blocks.
@test "AC2: unclassifiable SonarCloud comment blocks (fail closed) → 1" {
  local json='{"comments":[{"author":{"login":"sonarqubecloud"},"body":"Analysis in progress…","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

# AC2: the pattern is per-author — a DIFFERENT bot with no info-status pattern is
# NOT cleared even if its body happens to contain "Quality Gate passed".
@test "AC2: a bot with no info-status pattern is not cleared by matching text → 1" {
  local json='{"comments":[{"author":{"login":"codeant-ai"},"body":"Quality Gate passed","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

# AC5 (regression, whole loop): a PR carrying an approving pr-review review AND a
# later clean SonarCloud "Quality Gate passed" comment stays cleared — the gate
# returns 0, so review-one-pr.sh never dismisses the approval and no cycle is burned.
@test "AC5: approving review + later clean SonarCloud pass stays cleared → 0" {
  _run_check "$(_sonar_json sonarqubecloud "$(_sonar_body 0 0)" '[{"author":{"login":"donpetry-bot"},"state":"APPROVED"}]')"
  [ "$status" -eq 0 ]
}

# AC3 loop-safety: the maintainer escape-hatch reply carries a `maintainer-resolve`
# marker, so it is one of our own automation comments and never a new blocker.
@test "AC3: a maintainer-resolve marked reply is ignored → 0" {
  local json='{"comments":[{"author":{"login":"don-petry"},"body":"<!-- maintainer-resolve author=sonarqubecloud by=don-petry -->\nCleared: quality gate passed on the current head.","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 0 ]
}

# ────────────────────────────────────────────────────────────────────
# #1995 — the info-status classifier generalized beyond SonarCloud: Codex,
# CodeRabbit and Qodo post service notices carrying NO finding (usage-limit /
# review-limit / trial-ended). Each now declares an info_status_pattern, so a
# matching notice is auto-cleared (→0) with no dev-lead and no human, while a
# real review body from the SAME bot carries no pattern match and still blocks
# (→1). The notice bodies are this repo's own history (#1902/#1887/#1873).
# ────────────────────────────────────────────────────────────────────

_notice_json() {
  # _notice_json <login> <body> — a one-comment, un-minimized gate snapshot.
  jq -cn --arg l "$1" --arg b "$2" \
    '{reviews:[], comments:[{author:{login:$l}, body:$b, isMinimized:false, minimizedReason:""}]}'
}

@test "AC1(#1995): Codex usage-limit notice clears → 0" {
  _run_check "$(_notice_json chatgpt-codex-connector "You have reached your Codex usage limits for code reviews. You can see your limits in the Codex usage dashboard.")"
  [ "$status" -eq 0 ]
}

@test "AC1(#1995): Codex usage-limit notice with a [bot] suffix login clears → 0" {
  _run_check "$(_notice_json 'chatgpt-codex-connector[bot]' "You have reached your Codex usage limits for code reviews. You can see your limits in the Codex usage dashboard.")"
  [ "$status" -eq 0 ]
}

@test "AC2(#1995): a real Codex review body still blocks → 1" {
  _run_check "$(_notice_json chatgpt-codex-connector "The cubic free trial ended handling is too broad — this code path should be narrower.")"
  [ "$status" -eq 1 ]
}

# #1993: the Codex pattern is case-sensitive (jq test()) and pinned to the
# chatgpt-codex-connector login — a lower-cased variant, or the SAME notice text
# from a different author, is not cleared.
@test "#1993: a lower-cased Codex notice does not match (case-sensitive) → 1" {
  _run_check "$(_notice_json chatgpt-codex-connector "you have reached your codex usage limits for code reviews.")"
  [ "$status" -eq 1 ]
}

@test "#1993: the Codex usage-limit text from a different author still blocks → 1" {
  _run_check "$(_notice_json some-impersonator "You have reached your Codex usage limits for code reviews. You can see your limits in the Codex usage dashboard.")"
  [ "$status" -eq 1 ]
}

@test "AC2(#1995): a Codex comment that only quotes the notice (not at body start) still blocks → 1" {
  _run_check "$(_notice_json chatgpt-codex-connector "## Codex Review — could not complete

Earlier this run reported: You have reached your Codex usage limits for code reviews.

**P1** Possible null dereference in scripts/foo.sh:42 — guard the lookup before use.")"
  [ "$status" -eq 1 ]
}

@test "AC1(#1995): CodeRabbit review-limit notice clears → 0" {
  _run_check "$(_notice_json coderabbitai "Review limit reached — you have used up your prepaid credits.")"
  [ "$status" -eq 0 ]
}

@test "AC2(#1995): a real CodeRabbit review body still blocks → 1" {
  _run_check "$(_notice_json coderabbitai "Consider guarding against a nil pointer before dereferencing \`cfg\` here.")"
  [ "$status" -eq 1 ]
}

@test "AC1(#1995): Qodo trial-ended notice clears → 0" {
  _run_check "$(_notice_json qodo-code-review "Qodo reviews are paused because your trial has ended.")"
  [ "$status" -eq 0 ]
}

@test "AC1(#1995): Qodo trial-ended notice with its HTML marker prefix clears → 0" {
  _run_check "$(_notice_json qodo-code-review "<!-- qodo:billing-blocked --> Qodo reviews are paused because your trial has ended.")"
  [ "$status" -eq 0 ]
}

@test "AC2(#1995): a Qodo review that mentions the trial notice mid-body still blocks → 1" {
  _run_check "$(_notice_json qodo-code-review "The handling of the case where Qodo reviews are paused because your trial has ended is too lenient.")"
  [ "$status" -eq 1 ]
}

@test "AC2(#1995): a CodeRabbit review that mentions the limit notice mid-body still blocks → 1" {
  _run_check "$(_notice_json coderabbitai "The error handling is broken. Review limit reached — you have used up your prepaid credits feature needs better UX.")"
  [ "$status" -eq 1 ]
}

@test "AC1(#1995): Qodo's real trial notice (marker + bold ⓘ + billing link) clears → 0" {
  _run_check "$(_notice_json qodo-code-review $'<!-- qodo:billing-blocked -->\n\n**ⓘ Qodo reviews are paused because your trial has ended.** Ask your workspace admin to add credits to resume reviews. [Manage billing](https://app.qodo.ai/account/billing/manage-subscription?traffic_source=pr_comment)')"
  [ "$status" -eq 0 ]
}

@test "AC2(#1995): a Codex notice followed by a finding still blocks → 1" {
  _run_check "$(_notice_json chatgpt-codex-connector $'You have reached your Codex usage limits for code reviews.\n\n**P1** Possible null dereference in scripts/foo.sh:42.')"
  [ "$status" -eq 1 ]
}

@test "AC1(#1995): Qodo monthly-usage-limit notice clears → 0" {
  _run_check "$(_notice_json qodo-code-review "Qodo Merge has reached your monthly usage limit for pull-request reviews on this repository. Reviews will resume when the limit resets.")"
  [ "$status" -eq 0 ]
}

@test "AC2(#1995): a real Qodo review body still blocks → 1" {
  _run_check "$(_notice_json qodo-code-review "Suggestion: extract this block into a helper to reduce duplication.")"
  [ "$status" -eq 1 ]
}

# ────────────────────────────────────────────────────────────────────
# #2008 — CodeRabbit edits ONE summary comment in place, and it carries two
# independently throttled outputs: the code review (which can show a rate-limit
# block) and the Security Architecture Review (which is NOT throttled with it and
# can carry real findings). Two holes followed:
#   • an edit after the comment was dispositioned + minimized RESOLVED stayed
#     cleared forever, whatever CodeRabbit appended (PR #2000, comment
#     5938681830: dispositioned `informational` at 19:23Z, security finding added
#     by an in-place edit ~20:35Z);
#   • a rate-limit notice dispositioned the whole comment, findings included.
# The gate now re-blocks a RESOLVED registered-bot comment whose lastEditedAt is
# later than its latest covering disposition, refuses an `informational`
# disposition on a finding-bearing body, never lets an info_status_pattern clear
# a finding-bearing body, and fails closed when an edit time cannot be read.
# ────────────────────────────────────────────────────────────────────

CR_FIXTURES="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/../../fixtures/coderabbit"

# _edit_json <author> <body> <minimized:true|false> <lastEditedAt|null|absent> [disp_json_array]
#   One bot comment (id IC_cr) plus optional reply comments. "absent" omits the
#   lastEditedAt key and sets includesCreatedEdit:true (an edited comment whose
#   edit time the snapshot does not carry).
_edit_json() {
  local author="$1" body="$2" minimized="$3" edited="$4" replies="${5:-[]}"
  jq -cn --arg a "$author" --arg b "$body" --argjson m "$minimized" \
    --arg e "$edited" --argjson r "$replies" '
    {reviews:[], comments:([
      ({id:"IC_cr", author:{login:$a}, authorAssociation:"NONE", body:$b,
        createdAt:"2026-10-01T19:12:40Z", isMinimized:$m,
        minimizedReason:(if $m then "resolved" else "" end)}
       + (if $e == "absent" then {includesCreatedEdit:true}
          elif $e == "null" then {includesCreatedEdit:false, lastEditedAt:null}
          else {includesCreatedEdit:true, lastEditedAt:$e} end))
    ] + $r)}'
}

# _disp <created_at> <disposition> [author] [association] — a dev-lead disposition reply for IC_cr.
_disp() {
  jq -cn --arg c "$1" --arg d "$2" --arg a "${3:-don-petry}" --arg as "${4:-OWNER}" '
    [{id:("IC_disp_" + $c), author:{login:$a}, authorAssociation:$as,
      body:("Acknowledged — reviewed.\n<!-- dev-lead:comment-disposition id=IC_cr disposition=" + $d + " -->"),
      createdAt:$c, isMinimized:false, minimizedReason:""}]'
}

@test "#2008 AC1: RESOLVED bot comment edited AFTER its disposition re-blocks → 1" {
  _run_check "$(_edit_json coderabbitai "Walkthrough only." true "2026-10-01T20:35:00Z" "$(_disp 2026-10-01T19:23:54Z informational)")"
  [ "$status" -eq 1 ]
}

@test "#2008 AC1: RESOLVED bot comment edited BEFORE its disposition stays cleared → 0" {
  _run_check "$(_edit_json coderabbitai "Walkthrough only." true "2026-10-01T19:20:00Z" "$(_disp 2026-10-01T19:23:54Z informational)")"
  [ "$status" -eq 0 ]
}

@test "#2008 AC1: a fresh disposition after the edit covers the current body → 0" {
  local replies
  replies=$(jq -cn --argjson a "$(_disp 2026-10-01T19:23:54Z informational)" --argjson b "$(_disp 2026-10-01T21:00:00Z answered)" '$a + $b')
  _run_check "$(_edit_json coderabbitai "Walkthrough only." true "2026-10-01T20:35:00Z" "$replies")"
  [ "$status" -eq 0 ]
}

@test "#2008 AC1: a never-edited RESOLVED bot comment needs no disposition reply → 0" {
  _run_check "$(_edit_json coderabbitai "Walkthrough only." true null)"
  [ "$status" -eq 0 ]
}

@test "#2008 AC1: an edited RESOLVED bot comment with NO covering disposition blocks → 1" {
  _run_check "$(_edit_json coderabbitai "Walkthrough only." true "2026-10-01T20:35:00Z")"
  [ "$status" -eq 1 ]
}

@test "#2008 AC1: edited RESOLVED bot comment whose edit time is unreadable fails closed → 2" {
  _run_check "$(_edit_json coderabbitai "Walkthrough only." true absent "$(_disp 2026-10-01T19:23:54Z informational)")"
  [ "$status" -eq 2 ]
}

@test "#2008 AC1: a malformed lastEditedAt fails closed → 2" {
  _run_check "$(_edit_json coderabbitai "Walkthrough only." true "yesterday" "$(_disp 2026-10-01T19:23:54Z informational)")"
  [ "$status" -eq 2 ]
}

@test "#2008 AC1: a disposition marker from an untrusted author does not cover an edit → 1" {
  _run_check "$(_edit_json coderabbitai "Walkthrough only." true "2026-10-01T20:35:00Z" "$(_disp 2026-10-01T21:00:00Z informational drive-by NONE)")"
  [ "$status" -eq 1 ]
}

@test "#2008 AC1: a maintainer-resolve reply pinning the id covers an earlier edit → 0" {
  local replies='[{"id":"IC_mr","author":{"login":"don-petry"},"authorAssociation":"OWNER","body":"<!-- maintainer-resolve author=coderabbitai by=don-petry id=IC_cr -->\nnotice","createdAt":"2026-10-01T21:00:00Z","isMinimized":false,"minimizedReason":""}]'
  _run_check "$(_edit_json coderabbitai "Walkthrough only." true "2026-10-01T20:35:00Z" "$replies")"
  [ "$status" -eq 0 ]
}

@test "#2008 AC1: an edited RESOLVED HUMAN comment is out of scope (not a registered bot) → 0" {
  _run_check "$(_edit_json a-maintainer "Please fix this." true "2026-10-01T20:35:00Z")"
  [ "$status" -eq 0 ]
}

@test "#2008 AC3/AC5: PR #2000's real body (rate-limit block + security finding), undispositioned → 1" {
  _run_check "$(_edit_json coderabbitai "$(cat "$CR_FIXTURES/pr2000-ratelimited-with-security-finding.md")" false "2026-10-01T21:15:56Z")"
  [ "$status" -eq 1 ]
}

@test "#2008 AC3/AC5: dispositioning only the notice (informational) does NOT clear the #2000 body → 1" {
  # Even with the disposition AFTER the last edit and the comment minimized
  # RESOLVED, an `informational` disposition cannot cover a finding-bearing body.
  _run_check "$(_edit_json coderabbitai "$(cat "$CR_FIXTURES/pr2000-ratelimited-with-security-finding.md")" true "2026-10-01T21:15:56Z" "$(_disp 2026-10-01T21:30:00Z informational)")"
  [ "$status" -eq 1 ]
}

@test "#2008 AC2: the #2000 body with a real (answered) disposition after the edit clears → 0" {
  _run_check "$(_edit_json coderabbitai "$(cat "$CR_FIXTURES/pr2000-ratelimited-with-security-finding.md")" true "2026-10-01T21:15:56Z" "$(_disp 2026-10-01T21:30:00Z answered)")"
  [ "$status" -eq 0 ]
}

@test "#2008 AC3: a never-edited RESOLVED finding-bearing bot comment with NO disposition blocks → 1" {
  _run_check "$(_edit_json coderabbitai "$(cat "$CR_FIXTURES/pr2000-ratelimited-with-security-finding.md")" true null)"
  [ "$status" -eq 1 ]
}

@test "#2008 AC3: a reply carrying both an informational and a maintainer-resolve marker cannot mask findings → 1" {
  local replies='[{"id":"IC_both","author":{"login":"don-petry"},"authorAssociation":"OWNER","body":"<!-- dev-lead:comment-disposition id=IC_cr disposition=informational -->\n<!-- maintainer-resolve author=coderabbitai by=don-petry id=IC_cr -->","createdAt":"2026-10-01T21:30:00Z","isMinimized":false,"minimizedReason":""}]'
  _run_check "$(_edit_json coderabbitai "$(cat "$CR_FIXTURES/pr2000-ratelimited-with-security-finding.md")" true "2026-10-01T21:15:56Z" "$replies")"
  [ "$status" -eq 1 ]
}

@test "#2008 AC5: a clean CodeRabbit summary (no findings in any section) can be dispositioned informational → 0" {
  _run_check "$(_edit_json coderabbitai "$(cat "$CR_FIXTURES/summary-clean.md")" true "2026-10-01T19:20:00Z" "$(_disp 2026-10-01T19:23:54Z informational)")"
  [ "$status" -eq 0 ]
}

@test "#2008 AC3: the live OSS rate-limit notice is not an info-status match (summary still blocks) → 1" {
  _run_check "$(_notice_json coderabbitai "$(cat "$CR_FIXTURES/pr2000-ratelimited-with-security-finding.md")")"
  [ "$status" -eq 1 ]
}

@test "#2008 AC3: an info_status_pattern never clears a body carrying a finding-bearing section → 1" {
  # The SonarCloud clean-pass pattern is not end-anchored; a body that matches it
  # but also carries a Security Architecture Review with retained concerns must
  # still block (the section guard is applied before any pattern can clear).
  local body
  body="$(_sonar_body 0 0)"$'\n<!-- architecture_review_start -->\n### Security Architecture Review\n**Retained concerns**\n- **Medium · security · inferred:** something real.\n<!-- architecture_review_end -->'
  _run_check "$(_notice_json sonarqubecloud "$body")"
  [ "$status" -eq 1 ]
}

# ────────────────────────────────────────────────────────────────────
# #2178: a neutral bot overview (CodeAnt "PR Risk: Low Risk") carries no finding.
# codeant-ai has no info_status_pattern, so the gate does not auto-clear it.
# dev-lead dispositions it `informational` and the harness then minimizes it
# RESOLVED. That disposition must clear the gate. A CodeAnt comment that carries a
# finding still blocks until it gets a real disposition.
# ────────────────────────────────────────────────────────────────────

# The live body of petry-projects/.github PR #1269, comment IC_kwDORyesfc8AAAABauHIXQ.
_codeant_low_risk_body() {
  printf '%s' '## CodeAnt PR Risk: Low Risk

- The PR appears safe to merge: audit and deployment share a per-tier current-major pin check and handle stale pins and failed tag lookups explicitly.
- Regression tests cover stale and current pins, partial major rollouts, failed tag probes, and agreement between audit and deployment.

**Assessed commit:** `685b1eeb36aa`'
}

@test "#2178: an undispositioned CodeAnt 'PR Risk: Low Risk' overview blocks (no pattern auto-clears it) → 1" {
  _run_check "$(_edit_json codeant-ai "$(_codeant_low_risk_body)" false null)"
  [ "$status" -eq 1 ]
}

@test "#2178: a CodeAnt 'PR Risk: Low Risk' overview dispositioned informational and minimized RESOLVED clears → 0" {
  _run_check "$(_edit_json codeant-ai "$(_codeant_low_risk_body)" true null "$(_disp 2026-10-01T19:23:54Z informational)")"
  [ "$status" -eq 0 ]
}

@test "#2178: a CodeAnt comment carrying a finding, undispositioned, still blocks → 1" {
  local body
  body="$(_codeant_low_risk_body)"$'\n\n**Suggestion:** `resolve_pin` ignores a failed tag lookup and returns the stale major — check the exit status.'
  _run_check "$(_edit_json codeant-ai "$body" false null)"
  [ "$status" -eq 1 ]
}

@test "#2178: a CodeAnt body with a **Suggestion:** is finding-bearing" {
  source "$SCRIPT_DIR/lib/comment-disposition-verify.sh"
  run cdv_body_has_findings "$(_codeant_low_risk_body)"$'\n\n**Suggestion:** check the exit status.'
  [ "$status" -eq 0 ]
}

@test "#2178: a CodeAnt 'PR Risk: Medium Risk' body is finding-bearing" {
  source "$SCRIPT_DIR/lib/comment-disposition-verify.sh"
  run cdv_body_has_findings $'## CodeAnt PR Risk: Medium Risk\n\n- This needs attention before merging.'
  [ "$status" -eq 0 ]
}

@test "#2178: the clean CodeAnt Low Risk body is not finding-bearing" {
  source "$SCRIPT_DIR/lib/comment-disposition-verify.sh"
  run cdv_body_has_findings "$(_codeant_low_risk_body)"
  [ "$status" -eq 1 ]
}

@test "#2178: a CodeAnt body with a suggestion dispositioned informational does NOT clear → 1" {
  local body
  body="$(_codeant_low_risk_body)"$'\n\n**Suggestion:** `resolve_pin` ignores a failed tag lookup.'
  _run_check "$(_edit_json codeant-ai "$body" true null "$(_disp 2026-10-01T19:23:54Z informational)")"
  [ "$status" -eq 1 ]
}

@test "#2178: a bolded 'PR Risk: Low Risk' body is not finding-bearing" {
  source "$SCRIPT_DIR/lib/comment-disposition-verify.sh"
  run cdv_body_has_findings $'## CodeAnt **PR Risk: Low Risk**\n\n- The PR appears safe to merge.\n\n**Assessed commit:** `abc123`'
  [ "$status" -eq 1 ]
}

@test "#2178: a bolded 'PR Risk: Medium Risk' body is finding-bearing" {
  source "$SCRIPT_DIR/lib/comment-disposition-verify.sh"
  run cdv_body_has_findings $'## CodeAnt **PR Risk: Medium Risk**\n\n- This needs attention before merging.'
  [ "$status" -eq 0 ]
}

@test "#2178: 'PR Risk: Low Risky' (not exact Low Risk) is finding-bearing" {
  source "$SCRIPT_DIR/lib/comment-disposition-verify.sh"
  run cdv_body_has_findings $'## CodeAnt PR Risk: Low Risky\n\n- This requires attention.'
  [ "$status" -eq 0 ]
}

@test "#2178: 'PR Risk: Low Risk ' (with trailing space) is not finding-bearing" {
  source "$SCRIPT_DIR/lib/comment-disposition-verify.sh"
  run cdv_body_has_findings $'## CodeAnt PR Risk: Low Risk \n\n- The PR appears safe.'
  [ "$status" -eq 1 ]
}

@test "#2008: maintainer_gate_merge_edit_times merges lastEditedAt by comment id" {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s' '{"data":{"resource":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"IC_cr","lastEditedAt":"2026-10-01T20:35:00Z"},{"id":"IC_x","lastEditedAt":null}]}}}}'
SHIM
  chmod +x "$bin/gh"
  run env PATH="$bin:$PATH" bash -c "source '$GATE'; maintainer_gate_merge_edit_times https://github.com/o/r/pull/1 \"\$1\"" _ \
    '{"comments":[{"id":"IC_cr","body":"a"},{"id":"IC_x","body":"b"},{"id":"IC_y","body":"c"}]}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.comments[0].lastEditedAt')" = "2026-10-01T20:35:00Z" ]
  [ "$(printf '%s' "$output" | jq -r '.comments[1] | has("lastEditedAt")')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.comments[2] | has("lastEditedAt")')" = "false" ]
}

@test "#2008: maintainer_gate_merge_edit_times leaves the snapshot unchanged on API failure (gate then fails closed)" {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/gh"; chmod +x "$bin/gh"
  run env PATH="$bin:$PATH" bash -c "source '$GATE'; maintainer_gate_merge_edit_times https://github.com/o/r/pull/1 \"\$1\" 2>/dev/null" _ '{"comments":[{"id":"IC_cr"}]}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.')" = '{"comments":[{"id":"IC_cr"}]}' ]
}

@test "Wiring(#2008): review-one-pr.sh merges comment edit times before the gate" {
  local merge_line gate_line
  merge_line=$(grep -n 'maintainer_gate_merge_edit_times' "$SCRIPT_DIR/review-one-pr.sh" | head -1 | cut -d: -f1)
  gate_line=$(grep -n 'check_maintainer_comments' "$SCRIPT_DIR/review-one-pr.sh" | head -1 | cut -d: -f1)
  [ -n "$merge_line" ] && [ "$merge_line" -lt "$gate_line" ]
}

# ────────────────────────────────────────────────────────────────────
# INTEGRATION / WIRING TESTS (review-one-pr.sh)
# ────────────────────────────────────────────────────────────────────

@test "Wiring: review-one-pr.sh sources the maintainer-comment gate" {
  grep -q "source.*maintainer-comment-gate.sh" "$SCRIPT_DIR/review-one-pr.sh"
  grep -q "check_maintainer_comments" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "AC8: undispositioned hold and undeterminable error use distinct reasons" {
  # The legitimate hold reason must NOT be reused for the undeterminable/error state.
  grep -q "undispositioned-pr-comment" "$SCRIPT_DIR/review-one-pr.sh"
  grep -q "maintainer-comment-gate-error" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Wiring: FORCE_REVIEW bypasses the maintainer-comment gate" {
  grep -B8 "check_maintainer_comments" "$SCRIPT_DIR/review-one-pr.sh" | grep -q "FORCE_REVIEW"
}

@test "Manifest: maintainer-comment gate registered under pr-review.yml surface" {
  grep -q "scripts/lib/maintainer-comment-gate.sh" "$SCRIPT_DIR/lib/consumer-manifest.json"
}

# ────────────────────────────────────────────────────────────────────
# #2208: the lib dir must survive the caller's cd into the PR worktree
# ────────────────────────────────────────────────────────────────────
# dev-lead-fix-reviews.sh runs as `bash .dev-lead/scripts/...`, so BASH_SOURCE[0]
# is a relative path, and it cds into the PR worktree before it calls
# maintainer_gate_reopen_candidates. Resolving the lib dir at call time made
# every registry read fail closed, so every `informational`-dispositioned bot
# comment was unminimized on the next pass (#2152, second file).

# _relative_ws — a workspace whose .dev-lead/scripts links to this repo's scripts.
_relative_ws() {
  local root="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$root/.dev-lead" "$root/pr-worktree"
  ln -sfn "$SCRIPT_DIR" "$root/.dev-lead/scripts"
  printf '%s' "$root"
}

@test "#2208: no function resolves its own directory at call time" {
  run grep -nE '^[[:space:]]+.*dirname "\$\{BASH_SOURCE\[0\]\}"' "$GATE"
  [ "$status" -eq 1 ]
}

@test "#2208: registry lookups are cwd-independent when sourced by a relative path" {
  local root expected
  root=$(_relative_ws)
  expected=$(bash -c "source '$SCRIPT_DIR/lib/reviewer-sources.sh'; reviewer_sources_finding_section_pattern")
  run bash -c "cd '$root' && source .dev-lead/scripts/lib/maintainer-comment-gate.sh && cd pr-worktree && _maintainer_gate_finding_re"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
  [ "$output" != '[\s\S]' ]
  run bash -c "cd '$root' && source .dev-lead/scripts/lib/maintainer-comment-gate.sh && cd pr-worktree && _maintainer_gate_registered_logins_json"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'type == "array" and length > 0'
  run bash -c "cd '$root' && source .dev-lead/scripts/lib/maintainer-comment-gate.sh && cd pr-worktree && _maintainer_gate_info_patterns_json"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'type == "object" and length > 0'
}

@test "#2208: a never-edited informational-dispositioned bot comment is not re-opened after the cd" {
  local root comments
  root=$(_relative_ws)
  comments=$(jq -cn '[
    {id:"IC_codex", author:{login:"chatgpt-codex-connector", __typename:"Bot"},
     authorAssociation:"NONE",
     body:"You have reached your Codex usage limits for code reviews. You can see your limits in the Codex usage dashboard.",
     createdAt:"2026-10-10T11:30:00Z", isMinimized:true, minimizedReason:"RESOLVED",
     includesCreatedEdit:false, lastEditedAt:null},
    {id:"IC_disp", author:{login:"don-petry"}, authorAssociation:"OWNER",
     body:"Usage-limit notice; no finding.\n<!-- dev-lead:comment-disposition id=IC_codex disposition=informational -->",
     createdAt:"2026-10-10T11:37:00Z", isMinimized:false, minimizedReason:""}
  ]')
  run bash -c "cd '$root' && source .dev-lead/scripts/lib/maintainer-comment-gate.sh && cd pr-worktree && maintainer_gate_reopen_candidates \"\$1\" 2>/dev/null" _ "$comments"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "#2208: a really missing registry still fails closed" {
  local lib="$BATS_TEST_TMPDIR/lonely"
  mkdir -p "$lib"
  cp "$GATE" "$lib/"
  run bash -c "source '$lib/maintainer-comment-gate.sh'; cd /; _maintainer_gate_finding_re; echo; _maintainer_gate_registered_logins_json; echo; _maintainer_gate_info_patterns_json"
  [ "$status" -eq 0 ]
  [ "$output" = $'[\\s\\S]\nnull\n{}' ]
}
