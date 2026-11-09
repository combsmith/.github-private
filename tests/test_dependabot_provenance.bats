#!/usr/bin/env bats
# Tests for scripts/lib/dependabot-provenance.sh (#2481).
#
# pr-review now reviews and approves Dependabot PRs. It keeps the provenance
# rule dependabot-automerge applies (combsmith/.github
# .github/scripts/dependabot/lib/gates.sh, issue #1400): every commit on the PR
# is Dependabot's, or a branch-update merge commit made by the automerge App.
# A commit from anyone else blocks the approval. A read that cannot be trusted
# blocks too, but as "unreadable", never as a verdict about the commits.
#
#   dependabot_provenance_gate <pr_json> <commits_json> [trusted_login] [expected_sha]
#     0 pass / 1 block / 2 unreadable; prints the reason.
#   dependabot_provenance_check <owner/repo> <number> [expected_sha]
#     the same, reading the PR and its commits with gh; sets
#     DEPENDABOT_GATE_REASON.
#   dependabot_is_author <login>
#     0 when the login is Dependabot's, in gh's or REST's spelling.

LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/lib/dependabot-provenance.sh"

HEAD=1111111111111111111111111111111111111111
BASE_MERGE=2222222222222222222222222222222222222222
APP='combsmith-dependabot-automrg[bot]'

# _c <sha> <author> <committer> <verified> [parents] — one REST commit object.
_c() {
  jq -cn --arg s "$1" --arg a "$2" --arg c "$3" --argjson v "$4" --argjson p "${5:-1}" '
    {sha:$s, author:(if $a == "" then null else {login:$a} end),
     committer:(if $c == "" then null else {login:$c} end),
     commit:{verification:{verified:$v}},
     parents:[range(0; $p) | {sha:"p\(.)"}]}'
}
# _pr <head> <count> [user] — the REST pull request object.
_pr() { jq -cn --arg h "$1" --argjson n "$2" --arg u "${3:-dependabot[bot]}" '{head:{sha:$h}, commits:$n, user:{login:$u}}'; }
# _pages <commit>... — the `gh api --paginate --slurp` shape: one page.
_pages() { jq -cs '[.]' <<< "$(printf '%s\n' "$@")"; }

_gate() {
  run bash -c 'source "$1"; dependabot_provenance_gate "$2" "$3" "${4:-}" "${5:-}"' _ "$LIB" "$@"
}

@test "lib: shellcheck passes" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"
  shellcheck -S warning "$LIB"
}

@test "lib: sourcing has no side effects and defines the three functions" {
  run bash -c 'set -euo pipefail; source "$1"; declare -F dependabot_provenance_gate dependabot_provenance_check dependabot_is_author' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<< "$output")" -eq 3 ]
}

# ── dependabot_is_author ─────────────────────────────────────────────

@test "is_author: gh's app/dependabot and REST's dependabot[bot] are Dependabot" {
  run bash -c 'source "$1"; dependabot_is_author "app/dependabot" && dependabot_is_author "dependabot[bot]"' _ "$LIB"
  [ "$status" -eq 0 ]
}

@test "is_author: a User named dependabot, look-alikes and empty are not Dependabot" {
  local l
  for l in dependabot "app/dependabot-preview" "dependabot[bot]x" "app/dependabotx" "" "evil-dependabot[bot]" "$APP"; do
    run bash -c 'source "$1"; dependabot_is_author "$2"' _ "$LIB" "$l"
    [ "$status" -eq 1 ]
  done
}

# ── dependabot_provenance_gate: pass ─────────────────────────────────

@test "gate: one verified Dependabot commit committed by web-flow passes" {
  _gate "$(_pr "$HEAD" 1)" "$(_pages "$(_c "$HEAD" 'dependabot[bot]' web-flow true)")" "$APP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all 1 commit(s) from Dependabot"* ]]
}

@test "gate: a Dependabot commit committed by dependabot[bot] passes" {
  _gate "$(_pr "$HEAD" 1)" "$(_pages "$(_c "$HEAD" 'dependabot[bot]' 'dependabot[bot]' true)")" "$APP"
  [ "$status" -eq 0 ]
}

@test "gate: a verified update-branch merge by the automerge App passes" {
  _gate "$(_pr "$HEAD" 2)" "$(_pages "$(_c "$BASE_MERGE" 'dependabot[bot]' web-flow true)" "$(_c "$HEAD" "$APP" web-flow true 2)")" "$APP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch updates"* ]]
}

@test "gate: a flat commit array (not paged) is read too" {
  _gate "$(_pr "$HEAD" 1)" "[$(_c "$HEAD" 'dependabot[bot]' web-flow true)]" "$APP"
  [ "$status" -eq 0 ]
}

@test "gate: the expected head matching passes" {
  _gate "$(_pr "$HEAD" 1)" "$(_pages "$(_c "$HEAD" 'dependabot[bot]' web-flow true)")" "$APP" "$HEAD"
  [ "$status" -eq 0 ]
}

# ── dependabot_provenance_gate: block (a verdict) ────────────────────

@test "gate: a commit authored by anyone else blocks" {
  _gate "$(_pr "$HEAD" 2)" "$(_pages "$(_c "$BASE_MERGE" 'dependabot[bot]' web-flow true)" "$(_c "$HEAD" don-petry web-flow true)")" "$APP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not from Dependabot"* ]]
  [[ "$output" == *"author don-petry"* ]]
}

@test "gate: a Dependabot-authored commit committed by someone else blocks" {
  _gate "$(_pr "$HEAD" 1)" "$(_pages "$(_c "$HEAD" 'dependabot[bot]' don-petry true)")" "$APP"
  [ "$status" -eq 1 ]
}

@test "gate: an unverified Dependabot commit blocks" {
  _gate "$(_pr "$HEAD" 1)" "$(_pages "$(_c "$HEAD" 'dependabot[bot]' web-flow false)")" "$APP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unverified"* ]]
}

@test "gate: a commit with no author account blocks" {
  _gate "$(_pr "$HEAD" 1)" "$(_pages "$(_c "$HEAD" '' web-flow true)")" "$APP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"author unknown"* ]]
}

@test "gate: an App commit that is not a merge blocks" {
  _gate "$(_pr "$HEAD" 2)" "$(_pages "$(_c "$BASE_MERGE" 'dependabot[bot]' web-flow true)" "$(_c "$HEAD" "$APP" web-flow true 1)")" "$APP"
  [ "$status" -eq 1 ]
}

@test "gate: an App merge not committed by web-flow, or unverified, blocks" {
  _gate "$(_pr "$HEAD" 2)" "$(_pages "$(_c "$BASE_MERGE" 'dependabot[bot]' web-flow true)" "$(_c "$HEAD" "$APP" "$APP" true 2)")" "$APP"
  [ "$status" -eq 1 ]
  _gate "$(_pr "$HEAD" 2)" "$(_pages "$(_c "$BASE_MERGE" 'dependabot[bot]' web-flow true)" "$(_c "$HEAD" "$APP" web-flow false 2)")" "$APP"
  [ "$status" -eq 1 ]
}

@test "gate: with no trusted login, even the App's merge commit blocks" {
  _gate "$(_pr "$HEAD" 2)" "$(_pages "$(_c "$BASE_MERGE" 'dependabot[bot]' web-flow true)" "$(_c "$HEAD" "$APP" web-flow true 2)")" ""
  [ "$status" -eq 1 ]
}

@test "gate: a merge commit from another bot blocks" {
  _gate "$(_pr "$HEAD" 2)" "$(_pages "$(_c "$BASE_MERGE" 'dependabot[bot]' web-flow true)" "$(_c "$HEAD" 'github-actions[bot]' web-flow true 2)")" "$APP"
  [ "$status" -eq 1 ]
}

@test "gate: only App merge commits, no Dependabot commit, blocks" {
  _gate "$(_pr "$HEAD" 1)" "$(_pages "$(_c "$HEAD" "$APP" web-flow true 2)")" "$APP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no Dependabot commit"* ]]
}

@test "gate: a head that moved from the expected one blocks" {
  _gate "$(_pr "$HEAD" 1)" "$(_pages "$(_c "$HEAD" 'dependabot[bot]' web-flow true)")" "$APP" "$BASE_MERGE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"head moved"* ]]
}

# ── dependabot_provenance_gate: unreadable (no verdict) ──────────────

@test "gate: fewer commits read than the PR has is unreadable" {
  _gate "$(_pr "$HEAD" 2)" "$(_pages "$(_c "$HEAD" 'dependabot[bot]' web-flow true)")" "$APP"
  [ "$status" -eq 2 ]
  [[ "$output" == *"read 1 of 2"* ]]
}

@test "gate: a commit list without the head is unreadable" {
  _gate "$(_pr "$HEAD" 1)" "$(_pages "$(_c "$BASE_MERGE" 'dependabot[bot]' web-flow true)")" "$APP"
  [ "$status" -eq 2 ]
}

@test "gate: no head, no commits or malformed input is unreadable" {
  _gate '{"commits":1}' "$(_pages "$(_c "$HEAD" 'dependabot[bot]' web-flow true)")" "$APP"
  [ "$status" -eq 2 ]
  _gate "$(_pr "$HEAD" 0)" '[[]]' "$APP"
  [ "$status" -eq 2 ]
  _gate "$(_pr "$HEAD" 1)" 'not json' "$APP"
  [ "$status" -eq 2 ]
  _gate '' '' "$APP"
  [ "$status" -eq 2 ]
}

# ── dependabot_provenance_check: reads with gh ───────────────────────

_mock_gh() {
  MOCK_BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$MOCK_BIN"
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
# gh api repos/<r>/pulls/<n>[/commits...] — serve the fixtures; count PR reads.
[ "$1" = "api" ] || exit 0
case "$2" in
  repos/*/pulls/*/commits*) [ -f "$FIX/commits.json" ] || exit 1; cat "$FIX/commits.json" ;;
  repos/*/pulls/*)
    n=$(( $(cat "$FIX/reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FIX/reads"
    f="$FIX/pr.json"; [ "$n" -gt 1 ] && [ -f "$FIX/pr2.json" ] && f="$FIX/pr2.json"
    [ -f "$f" ] || exit 1; cat "$f" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"
  export PATH="$MOCK_BIN:$PATH" FIX="$BATS_TEST_TMPDIR"
}
_check() {
  run bash -c 'source "$1"; rc=0; dependabot_provenance_check "$2" "$3" "${4:-}" || rc=$?; echo "reason=$DEPENDABOT_GATE_REASON"; exit "$rc"' _ "$LIB" "$@"
}

@test "check: a Dependabot-only PR passes and names the verified head" {
  _mock_gh
  _pr "$HEAD" 1 > "$FIX/pr.json"
  _pages "$(_c "$HEAD" 'dependabot[bot]' web-flow true)" > "$FIX/commits.json"
  _check combsmith/demo 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"reason=all 1 commit(s) from Dependabot"* ]]
}

@test "check: the automerge App login defaults to combsmith-dependabot-automrg[bot]" {
  _mock_gh
  _pr "$HEAD" 2 > "$FIX/pr.json"
  _pages "$(_c "$BASE_MERGE" 'dependabot[bot]' web-flow true)" "$(_c "$HEAD" "$APP" web-flow true 2)" > "$FIX/commits.json"
  _check combsmith/demo 7
  [ "$status" -eq 0 ]
  DEPENDABOT_AUTOMERGE_LOGIN="other-app[bot]" _check combsmith/demo 7
  [ "$status" -eq 1 ]
}

@test "check: a foreign commit blocks with the gate's reason" {
  _mock_gh
  _pr "$HEAD" 1 > "$FIX/pr.json"
  _pages "$(_c "$HEAD" don-petry web-flow true)" > "$FIX/commits.json"
  _check combsmith/demo 7
  [ "$status" -eq 1 ]
  [[ "$output" == *"reason=1 commit(s) not from Dependabot"* ]]
}

@test "check: a PR not opened by Dependabot blocks" {
  _mock_gh
  _pr "$HEAD" 1 don-petry > "$FIX/pr.json"
  _pages "$(_c "$HEAD" 'dependabot[bot]' web-flow true)" > "$FIX/commits.json"
  _check combsmith/demo 7
  [ "$status" -eq 1 ]
  [[ "$output" == *"not opened by Dependabot"* ]]
}

@test "check: an unreadable PR or commit list is unreadable (2), never a pass" {
  _mock_gh
  _check combsmith/demo 7
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not read the pull request"* ]]
  _pr "$HEAD" 1 > "$FIX/pr.json"
  _check combsmith/demo 7
  [ "$status" -eq 2 ]
  [[ "$output" == *"commits"* ]]
}

@test "check: a head that moves between the reads is unreadable (2)" {
  _mock_gh
  _pr "$HEAD" 1 > "$FIX/pr.json"
  _pr "$BASE_MERGE" 1 > "$FIX/pr2.json"
  _pages "$(_c "$HEAD" 'dependabot[bot]' web-flow true)" > "$FIX/commits.json"
  _check combsmith/demo 7
  [ "$status" -eq 2 ]
  [[ "$output" == *"head changed"* ]]
}

@test "check: a head other than the expected one blocks (1)" {
  _mock_gh
  _pr "$HEAD" 1 > "$FIX/pr.json"
  _pages "$(_c "$HEAD" 'dependabot[bot]' web-flow true)" > "$FIX/commits.json"
  _check combsmith/demo 7 "$BASE_MERGE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"head moved"* ]]
}

@test "check: a malformed repo or PR number is unreadable (2) without calling gh" {
  _mock_gh
  _check "" 7
  [ "$status" -eq 2 ]
  _check combsmith/demo "7; rm -rf /"
  [ "$status" -eq 2 ]
  [ ! -f "$FIX/reads" ]
}
