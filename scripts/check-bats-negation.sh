#!/usr/bin/env bash
set -euo pipefail
# scripts/check-bats-negation.sh (#2263) — fail when a bats file holds a negated
# command that can never fail its test.
#
# Bash exempts a `!`-negated pipeline from errexit, and bats fails a test through
# errexit. So in
#
#     @test "the fix does not comment" {
#       run_the_thing
#       ! grep -q "pr comment" "$GH_LOG"
#       [ "$status" -eq 0 ]
#     }
#
# the `! grep` line is run and its result thrown away: the test passes whether or
# not the comment was posted. A negation counts only as the LAST command of its
# test or function, where it becomes the return status. 111 such lines had built
# up across 40 files when this check was added, and at least two of them were
# hiding a failing assertion.
#
# Write a negative assertion in one of these forms instead:
#     ! cmd || false          # fails the test when cmd succeeds
#     run ! cmd               # bats >= 1.5; note it overwrites $status/$output
#     if cmd; then false; fi
#
# What is flagged: a statement that starts with `!`, in a .bats file, unless
#   - it ends in `|| false` (or `|| return <n>`, `|| exit <n>`, `|| fail …`), or
#   - it is the last command before a closing `}` in column 0, or
#   - its line carries the marker `bats-negation-ok:` with a reason.
# Heredoc bodies are skipped (they are data, often an embedded script), and a
# statement continued with a trailing backslash is read as one statement.
# `foo && ! bar` is not flagged: it is just as inert, but cannot be told apart
# from a deliberate conditional by a line scan.
#
# Usage: check-bats-negation.sh [dir-or-file ...]   (default: the repo's tests/)
# Exit:  0 clean · 1 one or more inert negations (each printed as file:line)
#        2 nothing to scan or a scan error, so the tree cannot be certified clean

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$#" -eq 0 ]; then
  set -- "$ROOT/tests"
fi

files=()
for target in "$@"; do
  if [ -d "$target" ]; then
    while IFS= read -r f; do
      files+=("$f")
    done < <(find "$target" -type f -name '*.bats' | LC_ALL=C sort)
  elif [ -f "$target" ]; then
    files+=("$target")
  else
    echo "check-bats-negation: no such file or directory: $target" >&2
    exit 2
  fi
done

# No test files is a setup error, never a pass: "cannot check" must not read as
# "nothing to check".
if [ "${#files[@]}" -eq 0 ]; then
  echo "check-bats-negation: found no .bats files under: $*" >&2
  exit 2
fi

rc=0
findings=$(awk '
  function flag(   ) {
    printf "%s:%d: %s\n", pfile, pline, ptext
    pending = 0
  }
  # A heredoc left open at the end of a file means the scanner misread a `<<` and
  # skipped everything after it. Say so and fail the scan: lines that were not
  # read must not count as clean.
  function unterminated(   ) {
    printf "check-bats-negation: %s:%d: heredoc <<%s is never closed; the rest of the file was not scanned\n", hfile, hline, heredoc > "/dev/stderr"
    scan_error = 1
    heredoc = ""
  }
  # heredoc_word(statement) — the terminator of a heredoc opened OUTSIDE quotes on
  # this statement, or "". A `<<` inside a quoted string (printf "cat <<EOF") is
  # text, and `<<<` is a here-string; neither opens a heredoc. Sets strip_tabs for
  # the `<<-` form.
  function heredoc_word(s,    i, n, c, q, rest, word) {
    n = length(s); q = ""
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (q == "\047") { if (c == "\047") q = ""; continue }
      if (q == "\"") {
        if (c == "\\") i++
        else if (c == "\"") q = ""
        continue
      }
      if (c == "\\") { i++; continue }
      if (c == "\047" || c == "\"") { q = c; continue }
      if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;]/)) return ""
      if (c != "<" || substr(s, i, 2) != "<<") continue
      if (substr(s, i, 3) == "<<<") { i += 2; continue }
      rest = substr(s, i + 2)
      strip_tabs = (rest ~ /^-/)
      sub(/^-/, "", rest)
      sub(/^[ \t]+/, "", rest)
      sub(/^["\047\\]/, "", rest)
      if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) {
        word = substr(rest, RSTART, RLENGTH)
        return word
      }
      i++
    }
    return ""
  }
  FNR == 1 {
    # A negation still pending at the end of the previous file was never closed
    # by a `}`: report it rather than drop it.
    if (pending) flag()
    if (heredoc != "") unterminated()
  }
  {
    line = $0

    # Inside a heredoc body: skip until its terminator.
    if (heredoc != "") {
      t = line
      if (strip_tabs) sub(/^\t+/, "", t)
      if (t == heredoc) heredoc = ""
      next
    }

    # Blank lines and comment-only lines neither close nor confirm a pending
    # negation.
    if (line ~ /^[ \t]*$/ || line ~ /^[ \t]*#/) next

    # The first real line after a negation decides it: a `}` in column 0 makes the
    # negation the last command of its test/function (effective); anything else
    # means more commands follow (inert).
    if (pending) {
      if (line ~ /^}/) pending = 0
      else flag()
    }

    # Join a backslash-continued statement so `|| false` on its last line counts.
    stmt = line
    start = FNR
    while (stmt ~ /\\$/) {
      if ((getline nxt) <= 0) break
      sub(/\\$/, "", stmt)
      stmt = stmt nxt
    }

    # A heredoc opened on this statement: remember its terminator.
    heredoc = heredoc_word(stmt)
    if (heredoc != "") { hfile = FILENAME; hline = start }

    if (stmt !~ /^[ \t]*![ \t]+[^ \t]/) next
    if (stmt ~ /bats-negation-ok:/) next
    if (stmt ~ /\|\|[ \t]*(false|fail([ \t]|$)|return[ \t]+[1-9]|exit[ \t]+[1-9])/) next

    pending = 1
    pfile = FILENAME
    pline = start
    ptext = stmt
    sub(/^[ \t]+/, "", ptext)
  }
  END {
    if (pending) flag()
    if (heredoc != "") unterminated()
    if (scan_error) exit 3
  }
' "${files[@]}") || rc=$?

if [ "$rc" -ne 0 ]; then
  [ -z "$findings" ] || printf '%s\n' "$findings"
  echo "check-bats-negation: the scan did not complete (awk exit $rc), so the tree cannot be certified clean" >&2
  exit 2
fi

if [ -n "$findings" ]; then
  printf '%s\n' "$findings"
  count=$(printf '%s\n' "$findings" | wc -l | tr -d ' ')
  {
    echo
    echo "check-bats-negation: $count negated command(s) cannot fail their test."
    echo "A \`!\`-negated command is exempt from errexit, so it only counts as the last"
    echo "command of a test. Write \`! cmd || false\` (or \`run ! cmd\`) instead. See #2263."
  } >&2
  exit 1
fi

echo "check-bats-negation: ${#files[@]} bats file(s) scanned, no inert negations."
