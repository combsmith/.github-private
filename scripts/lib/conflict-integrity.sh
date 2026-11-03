#!/usr/bin/env bash
# conflict-integrity.sh — post-conflict-resolution integrity check (#1482).
#
# A narrow, mechanical detector for the corruption class from #1449: a botched
# automated conflict resolution that duplicates whole blocks of a shell script
# (grew scripts/engine.sh from 2688 to 4011 lines, doubling run_writer /
# parse_reset_time / extract_verdict_json). Such a resolution "completes" and
# reports success, so nothing on the conflict-resolution path checks it — it only
# surfaces hours later when an unrelated test trips over the corrupted function.
#
# These helpers are pure (no network/git side effects) so they are unit-testable
# in isolation; the git/gh plumbing that feeds them lives in the caller
# (dev-lead-fix-reviews.sh's rebase intent). The detector is deliberately
# mechanical — duplicate top-level declarations — not a semantic "is this diff
# correct" analysis, which is neither tractable nor in scope.

# extract_top_level_symbols <file>
# Emit one line per top-level declaration in file order, tagged by kind:
#   fn:NAME   — a function declaration (`NAME() {` / `NAME()` / `function NAME`)
#   var:NAME  — a top-level variable assignment (optionally export/readonly/declare)
# "Top-level" means the declaration begins at column 0 (no leading whitespace),
# so nested functions and in-function `local` assignments are ignored. A symbol
# declared N times appears N times.
extract_top_level_symbols() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    # NAME() {   (POSIX + ksh, brace same line), column 0 only.
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ {
      name = $0
      sub(/[[:space:]]*\(\).*$/, "", name)
      print "fn:" name
      next
    }
    # NAME()      (brace on next line), column 0 only.
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*$/ {
      name = $0
      sub(/[[:space:]]*\(\).*$/, "", name)
      print "fn:" name
      next
    }
    # function NAME   (with or without trailing parens).
    /^function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
      name = $2
      sub(/\(.*$/, "", name)
      print "fn:" name
      next
    }
    # [export|readonly|declare -x] NAME=...   top-level assignment, column 0.
    /^(export[[:space:]]+|readonly[[:space:]]+|declare[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)?[A-Za-z_][A-Za-z0-9_]*=/ {
      line = $0
      sub(/^(export[[:space:]]+|readonly[[:space:]]+|declare[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)/, "", line)
      name = line
      sub(/=.*$/, "", name)
      print "var:" name
      next
    }
  ' "$file"
}

# symbol_counts <file>
# Emit "SYMBOL<TAB>COUNT" for every top-level symbol, sorted.
symbol_counts() {
  extract_top_level_symbols "$1" | LC_ALL=C sort | uniq -c \
    | awk '{ print $2 "\t" $1 }'
}

# _count_of <counts-block> <symbol>
# Look up a symbol's count in a "SYMBOL<TAB>COUNT" block; 0 if absent.
_count_of() {
  local counts="$1" sym="$2" c
  c="$(printf '%s\n' "$counts" | awk -F'\t' -v s="$sym" '$1 == s { print $2; exit }')"
  printf '%s' "${c:-0}"
}

# new_duplicate_symbols <resolved> <parent_a> <parent_b>
# Emit "SYMBOL<TAB>COUNT" for each top-level symbol whose declaration count in
# the resolved file EXCEEDS its count in *both* parents — i.e., the resolution
# introduced extra copies. A symbol that already appeared N times in a parent and
# still appears N times is NOT flagged, so a legitimate large upstream merge (or
# an intentional pre-existing repetition) does not trip the check (AC #1, #6).
# A missing parent file counts as zero declarations (a brand-new file that itself
# ships duplicate declarations is still flagged).
new_duplicate_symbols() {
  local resolved="$1" parent_a="$2" parent_b="$3"
  {
    extract_top_level_symbols "$parent_a" | awk '{print "a\t" $0}'
    extract_top_level_symbols "$parent_b" | awk '{print "b\t" $0}'
    extract_top_level_symbols "$resolved"  | awk '{print "r\t" $0}'
  } | awk -F'\t' '
    $1 == "a" { count_a[$2]++ }
    $1 == "b" { count_b[$2]++ }
    $1 == "r" { count_r[$2]++ }
    END {
      for (sym in count_r) {
        rcount = count_r[sym]
        if (rcount > 1) {
          acount = count_a[sym] + 0
          bcount = count_b[sym] + 0
          maxp = (acount > bcount) ? acount : bcount
          if (rcount > maxp) {
            print sym "\t" rcount
          }
        }
      }
    }
  ' | LC_ALL=C sort
}

# extract_markdown_headings <file>
# Emit one line per ATX heading (`#`..`######` followed by a space) in file
# order, with trailing whitespace trimmed. The heading level (the run of `#`) is
# kept, so an H2 and an H3 with the same text are distinct headings. Lines inside
# fenced code blocks (``` or ~~~, optionally indented / carrying an info string)
# are skipped — a shell comment in an example is not a heading. This is the
# markdown analogue of the shell-function duplication signature: fix-ci.md /
# fix-reviews.md shipped whole Phase blocks (heading + body) twice (#1779).
extract_markdown_headings() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    BEGIN { infence = 0; infence_char = ""; infence_count = 0 }
    # Track in/out of fenced code blocks. Store the opening delimiter character
    # and length, then only close when seeing a matching delimiter of at least
    # the same length. Nested shorter fences do not toggle state.
    /^[[:space:]]*(```|~~~)/ {
      fence_line = $0
      sub(/^[[:space:]]*/, "", fence_line)
      fence_char = substr(fence_line, 1, 1)
      fence_count = 0
      while (substr(fence_line, fence_count + 1, 1) == fence_char) {
        fence_count++
      }
      # Text after the run of delimiters. An opening fence may carry an info
      # string (```bash), but a *closing* fence must be the delimiter alone —
      # ``` followed by non-whitespace is code content, not a close.
      fence_tail = substr(fence_line, fence_count + 1)
      if (!infence) {
        infence = 1
        infence_char = fence_char
        infence_count = fence_count
      } else if (fence_char == infence_char && fence_count >= infence_count \
                 && fence_tail ~ /^[[:space:]]*$/) {
        infence = 0
      }
      next
    }
    infence { next }
    # ATX heading: 0-3 leading spaces, then 1..6 "#" then whitespace then text.
    /^[[:space:]]{0,3}#+[[:space:]]/ {
      n = 0
      line = $0
      sub(/^[[:space:]]*/, "", line)
      while (substr(line, n + 1, 1) == "#") n++
      if (n >= 1 && n <= 6) {
        # Drop an optional ATX closing marker (`### Phase 2 ###`) so it compares
        # equal to the bare form (`### Phase 2`); then trim trailing whitespace.
        sub(/[[:space:]]+#+[[:space:]]*$/, "", line)
        sub(/[[:space:]]+$/, "", line)
        print line
      }
    }
  ' "$file"
}

# extract_yaml_mapping_keys <file>
# Emit "SCOPE<TAB>KEY" for every block-mapping key, where SCOPE uniquely
# identifies the mapping the key belongs to. A key duplicated within the SAME
# mapping therefore produces two identical lines (caught by `uniq -d`), while the
# same key appearing under two different list items or two different parent
# mappings produces distinct SCOPEs and is NOT flagged. This is the YAML analogue
# of the shell-function signature: persona.yml carried a `reusable:` key twice in
# the same `runtime:` mapping (#1779), which YAML last-key-wins hides from
# `yaml.safe_load`-based validators.
#
# Deliberately mechanical (indentation + list-item aware), not a full YAML
# parser: it handles block mappings, block sequences and block scalars (`|`/`>`),
# which is the whole surface of personas/**/*.yml. Flow mappings on a single line
# ({a: 1, b: 2}) are treated as a scalar value, not descended into.
extract_yaml_mapping_keys() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    function indent_of(s,   i) {
      i = 0
      while (substr(s, i + 1, 1) == " ") i++
      return i
    }
    function scope_path(   i, p) {
      p = ""
      for (i = 1; i <= top; i++) p = p "/" flabel[i]
      return p
    }
    BEGIN { top = 0; in_block = 0; block_indent = -1; seq = 0 }
    {
      raw = $0
      sub(/\r$/, "", raw)
      if (raw ~ /^[[:space:]]*$/) next            # blank

      ind = indent_of(raw)
      content = raw
      sub(/^[[:space:]]*/, "", content)

      # Block scalar body: everything more indented than the owning key.
      if (in_block) {
        if (ind > block_indent) next
        in_block = 0
      }

      if (content ~ /^#/) next                    # comment
      if (content ~ /^(---|\.\.\.)/) { top = 0; next }  # document markers

      if (content ~ /^-([[:space:]]|$)/) {        # sequence entry
        while (top > 0 && findent[top] >= ind) top--
        seq++
        top++
        findent[top] = ind
        flabel[top] = "[" seq "]"
        rest = content
        sub(/^-[[:space:]]*/, "", rest)
        if (rest == "") next
        ind = ind + 2                             # inline content column
        content = rest
      } else {
        while (top > 0 && findent[top] >= ind) top--
      }

      # A block-mapping key: NAME: (bare or quoted), then space or end of line.
      if (content ~ /^[^-#[:space:]:"'"'"'][^:]*:([[:space:]]|$)/ \
          || content ~ /^"[^"]*"[[:space:]]*:([[:space:]]|$)/ \
          || content ~ /^'"'"'[^'"'"']*'"'"'[[:space:]]*:([[:space:]]|$)/) {
        key = content
        # Two forms of the key: rawkey is the exact source span (incl. quotes),
        # used to advance past the key when extracting val; canon is the decoded
        # key used for duplicate comparison. YAML treats reusable, "reusable" and
        # '"'"'reusable'"'"' as the same scalar key, so stripping the surrounding
        # quotes makes a bare+quoted pair collide under `uniq -d` (#1782).
        if (key ~ /^"/) {
          n = 2
          while (n <= length(key) && substr(key, n, 1) != "\"") n++
          rawkey = substr(key, 1, n)
          canon  = substr(key, 2, n - 2)
        } else if (key ~ /^'"'"'/) {
          n = 2
          while (n <= length(key) && substr(key, n, 1) != "'"'"'") n++
          rawkey = substr(key, 1, n)
          canon  = substr(key, 2, n - 2)
        } else {
          rawkey = key
          sub(/:.*$/, "", rawkey)
          canon = rawkey
        }
        sub(/[[:space:]]+$/, "", rawkey)
        sub(/[[:space:]]+$/, "", canon)
        print scope_path() "\t" canon
        val = content
        # Skip the raw key span and remove the separator colon and spaces
        val = substr(val, length(rawkey) + 1)
        sub(/^[[:space:]]*:[[:space:]]*/, "", val)
        top++
        findent[top] = ind
        flabel[top] = canon
        if (val ~ /^[|>]/) { in_block = 1; block_indent = ind }
        next
      }
      next
    }
  ' "$file"
}

# format_integrity_findings <file> <findings>
# Render a Markdown bullet naming the file and each duplicated symbol, where
# <findings> is the "SYMBOL<TAB>COUNT" output of new_duplicate_symbols. Emits
# nothing when there are no findings.
format_integrity_findings() {
  local file="$1" findings="$2"
  [[ -n "$findings" ]] || return 0
  printf -- '- `%s` — duplicated top-level declarations after resolution:\n' "$file"
  printf '%s\n' "$findings" | while IFS="$(printf '\t')" read -r sym count; do
    [[ -n "$sym" ]] || continue
    printf -- '  - `%s` (declared %s times)\n' "$sym" "$count"
  done
}
