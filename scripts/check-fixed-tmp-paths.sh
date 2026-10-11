#!/usr/bin/env bash
set -euo pipefail
# scripts/check-fixed-tmp-paths.sh (#2271) — list every fixed path under /tmp
# that the tests and scripts name, and fail on one that is not accounted for.
#
# A fixed path under /tmp is shared by every process on the machine. Two bats
# sessions that run at the same time (two worktrees, two agents, a retry) read
# and delete each other's files there, and a test fails for a reason unrelated to
# the code under test: tests 19, 24 and 30 of test_budget_breaker.bats did, on
# unmodified main, through /tmp/dev-lead-rate-limit-reset.
#
# What counts as FIXED: a literal /tmp/<name> with no variable part, and in
# tests/ a fixed name under "$BATS_TMPDIR" (the base temp directory of bats: /tmp
# on Linux, and the same for every session). Not fixed, and never reported: a
# path with a `$` in it (`$$`, `$BATS_TEST_TMPDIR/…`, `${TMPDIR:-/tmp}/…`), a
# mktemp template (`XXXXXX`), a glob, and `/tmp/` as a later component of
# another path.
#
#   tests/    every fixed path is reported, including the default of a
#             `${VAR:-/tmp/…}` expansion in a stub: nothing sets the variable
#             unless a test does. Write under "$BATS_TEST_TMPDIR" instead.
#   scripts/  the default of a `${VAR:-/tmp/…}` expansion is allowed: the caller
#             can move it, which is how a test isolates itself. A bare literal
#             is reported: a test that runs the script cannot redirect it. This
#             is also what keeps the writers and readers of the dev-lead
#             sidecars on one definition ("$DEV_LEAD_SIDECAR_DIR/<file>",
#             engine.sh): a literal /tmp/dev-lead-… in any of them fails here.
#
# Comment lines and bats `@test` title lines are not read (a path named in prose
# is not a path opened). Markdown is not scanned.
#
# Exceptions live in scripts/lib/fixed-tmp-paths.tsv, one row per path and file,
# each with its reason. A row that no longer matches anything fails the check,
# so the list cannot outlive what it excuses.
#
# KNOWN LIMIT. The check reads text. A test that runs a script shares, without
# naming it, any fixed path the script writes (only the scripts/ rule sees
# that) and any default the test leaves unset: a suite that reaches engine.sh
# without exporting DEV_LEAD_SIDECAR_DIR writes /tmp, and nothing here says so.
#
# Usage: check-fixed-tmp-paths.sh [root]   (root defaults to the repo root)
# Exit:  0 every fixed path is accounted for (the list is printed)
#        1 an unaccounted fixed path, or a stale or unreasoned exception
#        2 a scan error (grep failed), so the tree cannot be certified clean

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ALLOWLIST_REL="scripts/lib/fixed-tmp-paths.tsv"
SCAN_DIRS=(tests scripts)

hits_file="$(mktemp)"
trap 'rm -f "$hits_file"' EXIT

for d in "${SCAN_DIRS[@]}"; do
  [ -d "$ROOT/$d" ] || continue
  # grep exits 0 (match), 1 (no match, clean) or >1 (a real scan error). Never
  # mask >1: that would report a false clean.
  rc=0
  (cd "$ROOT" && grep -rnIF --exclude='*.md' -e '/tmp/' -e 'BATS_TMPDIR' "$d") >> "$hits_file" 2>/dev/null || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "::error::check-fixed-tmp-paths: scan of '$d' failed (grep exit $rc) — cannot certify clean." >&2
    exit 2
  fi
done

# grep walks a directory in on-disk order; sort so the report is the same everywhere.
LC_ALL=C sort -t: -k1,1 -k2,2n -o "$hits_file" "$hits_file"

allow_file="$ROOT/$ALLOWLIST_REL"
[ -f "$allow_file" ] || allow_file=/dev/null

awk -v allow_rel="$ALLOWLIST_REL" '
  # note(tok, file, lno): count the path against its exception row, or record
  # it as unaccounted.
  function note(tok, file, lno,    k) {
    for (k = 1; k <= n_allow; k++) {
      if (a_file[k] == file && (tok == a_path[k] || index(tok, a_path[k] "/") == 1)) { a_hits[k]++; return }
    }
    if ((tok, file) in seen) return
    seen[tok, file] = 1
    files[tok] = (tok in files) ? files[tok] ", " file : file
    nfiles[tok]++
    first[tok, file] = lno
    if (!(tok in order_of)) { order_of[tok] = ++n_tok; order[n_tok] = tok }
  }

  BEGIN { FS = "\t"; bad = 0 }

  # First file: the exceptions. path <TAB> file <TAB> reason.
  FILENAME == ARGV[1] {
    if ($0 ~ /^[ \t]*(#|$)/) next
    n_allow++
    a_path[n_allow] = $1; a_file[n_allow] = $2; a_reason[n_allow] = $3; a_hits[n_allow] = 0
    if ($1 == "" || $2 == "" || $3 == "") {
      printf "::error file=%s,line=%d::exception row needs path, file and reason (tab-separated)\n", allow_rel, FNR
      bad = 1
    }
    next
  }

  # Second file: grep hits, "<file>:<line>:<text>".
  {
    line = $0
    c1 = index(line, ":"); file = substr(line, 1, c1 - 1); line = substr(line, c1 + 1)
    c2 = index(line, ":"); lno = substr(line, 1, c2 - 1); text = substr(line, c2 + 1)
    if (file == allow_rel) next
    if (text ~ /^[ \t]*#/ || text ~ /^[ \t]*@test /) next
    in_tests = (file ~ /^tests\//)

    pos = 1
    while ((i = index(substr(text, pos), "/tmp/")) > 0) {
      start = pos + i - 1
      pre1 = (start > 1) ? substr(text, start - 1, 1) : ""
      pre2 = (start > 2) ? substr(text, start - 2, 2) : ""
      tail = substr(text, start)
      if (match(tail, /^\/tmp\/[A-Za-z0-9_.+\/$*?{}-]+/)) { tok = substr(tail, 1, RLENGTH) } else { tok = "/tmp/" }
      pos = start + length(tok)

      if (pre1 ~ /[A-Za-z0-9_.}\/]/) continue          # /tmp/ inside another path
      b = index(tok, "}")                               # the brace closing a ${VAR:-default}
      if (b > 0 && index(tok, "{") == 0) tok = substr(tok, 1, b - 1)
      if (tok ~ /[$*?]/ || tok ~ /XXX/) continue        # variable part, glob, mktemp template
      sub(/[.\/]+$/, "", tok)
      if (tok == "/tmp") continue
      if (pre2 == ":-" && !in_tests) continue           # overridable default in a script
      note(tok, file, lno)
    }

    # "$BATS_TMPDIR/<name>": the base temp directory of bats is /tmp on Linux and
    # is the same for every session, so a fixed name beneath it is a fixed path.
    rest = text
    while (in_tests && match(rest, /BATS_TMPDIR(:-\/tmp)?[}]?\/[A-Za-z0-9_.+\/$*?{}-]+/)) {
      tok = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
      sub(/^BATS_TMPDIR(:-\/tmp)?[}]?/, "", tok)        # keep "/<name>"
      if (tok ~ /[$*?]/ || tok ~ /XXX/) continue
      sub(/[.\/]+$/, "", tok)
      if (tok != "") note("$BATS_TMPDIR" tok, file, lno)
    }
  }

  END {
    print "Fixed paths under /tmp named in tests/ and scripts/:"
    for (k = 1; k <= n_allow; k++) {
      if (a_hits[k] > 0) {
        printf "  excepted  %s  (%s, %d reference%s): %s\n", a_path[k], a_file[k], a_hits[k], (a_hits[k] == 1 ? "" : "s"), a_reason[k]
      } else if (a_path[k] != "" && a_file[k] != "") {
        printf "::error file=%s::stale exception: %s is no longer named in %s; remove the row\n", allow_rel, a_path[k], a_file[k]
        bad = 1
      }
    }
    for (t = 1; t <= n_tok; t++) {
      tok = order[t]
      shared = (nfiles[tok] > 1) ? sprintf("SHARED by %d files", nfiles[tok]) : "1 file"
      printf "  FIXED     %s  (%s: %s)\n", tok, shared, files[tok]
      n = split(files[tok], fl, ", ")
      for (j = 1; j <= n; j++) {
        printf "::error file=%s,line=%s::fixed path %s: concurrent runs share it. In a test, write under \"$BATS_TEST_TMPDIR\"; in a script, take the path from a variable the caller can set.\n", fl[j], first[tok, fl[j]], tok
      }
      bad = 1
    }
    if (n_allow == 0 && n_tok == 0) print "  (none)"
    exit bad
  }
' "$allow_file" "$hits_file"
