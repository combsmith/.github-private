#!/usr/bin/env bash
# review-change-evidence.sh — decide whether a dev-lead fix pass actually
# addressed the requested review changes (#1567).
#
# The defect: dev-lead posted status=applied / "Changes committed and pushed"
# whenever *a* commit existed, not when the requested change landed — so a
# cosmetic or unrelated edit satisfied the bar (observed on petry-projects/.github#995:
# a review asked for eight specific changes; three consecutive passes each
# reported success while the net diff stayed +364/-0 and every requested change
# scored zero occurrences).
#
# These helpers move the evidence bar to "the commit is non-trivial AND touches
# the regions the review named," per requested item. They are PURE (no network
# or git side effects) so they are unit-testable in isolation; the git/gh
# plumbing that feeds them (resolving the diff, posting markers, escalating)
# lives in the caller (dev-lead-fix-reviews.sh). The check is deliberately
# mechanical — region overlap, not a semantic "is this the right fix" analysis,
# which is neither tractable nor in scope. It errs toward the honest verdict:
# a same-file-wrong-region edit reports `partial`/`not-applied`, never `applied`.

# rce_named_regions <open_threads_json>
# Emit one "<path>\t<line>" per unresolved review thread (line 0 when null or
# absent). Input is the OPEN_THREADS_JSON the caller already filters to
# unresolved threads; the isResolved guard here is belt-and-suspenders.
rce_named_regions() {
  local json="${1:-[]}"
  # No error masking: malformed/failed jq input must abort loudly rather than be
  # swallowed into an empty region set, which rce_classify would read as "review
  # named nothing" and pass a substantive commit off as applied (#1567).
  printf '%s' "$json" | jq -r '
    (. // [])
    | map(select((.isResolved // false) != true))
    | .[]
    | select(((.path // "") | length) > 0)
    | (.path) + "\t" + (((.line // 0)) | tostring)
  '
}

# rce_parse_hunks  (unified diff on stdin)
# Emit one "<path>\t<old_start>\t<old_end>" per hunk, using PRE-image line
# numbers — the coordinates a review thread's `.line` is expressed in (the head
# the review was left on). A hunk header is `@@ -old_start[,old_count] +... @@`;
# a hunk with old_count 0 (pure insertion) collapses to a single anchor line.
rce_parse_hunks() {
  awk '
    /^\+\+\+ /  {
      p=$0
      sub(/^\+\+\+ [ab]\//, "", p)   # strip "+++ a/" or "+++ b/"
      if (p == $0) sub(/^\+\+\+ /, "", p)   # no a//b/ prefix (e.g. /dev/null)
      sub(/\t.*$/, "", p)            # drop trailing tab + timestamp
      path=p
      next
    }
    /^@@ /      {
      m=$2                       # -old_start[,old_count]
      sub(/^-/,"",m)
      n=split(m,a,",")
      os=a[1]+0
      oc=(n>1 ? a[2]+0 : 1)
      if (oc<=0) { oe=os } else { oe=os+oc-1 }
      if (length(path)) printf "%s\t%d\t%d\n", path, os, oe
    }
  '
}

# rce_region_covered <path> <line> <changed_regions> [window]
# changed_regions: newline list of "<path>\t<start>\t<end>" (from rce_parse_hunks).
# Returns 0 when a changed hunk in the same path overlaps [line-window, line+window].
# A line of 0 (unknown) falls back to a file-level touch: any hunk in that path.
rce_region_covered() {
  local path="$1" line="$2" changed="$3" window="${4:-3}"
  [ -z "$changed" ] && return 1
  awk -F'\t' -v p="$path" -v l="$line" -v w="$window" '
    $1 == "" { next }
    $1 != p { next }
    {
      if (l+0 <= 0) { hit=1; next }          # unknown line → file-level touch
      if (l >= $2-w && l <= $3+w) hit=1
    }
    END { exit (hit ? 0 : 1) }
  ' <<< "$changed"
}

# rce_classify <substantive true|false> <named_regions> <changed_regions> [window]
# Echo the verdict for a pass that DID push a commit:
#   not-applied — the commit is non-substantive (whitespace/cosmetic only), OR
#                 it touched none of the regions the review named
#   partial     — it touched some but not all named regions
#   applied     — it touched every named region (or the review named none, in
#                 which case a substantive commit is accepted)
rce_classify() {
  local substantive="$1" named="$2" changed="$3" window="${4:-3}"
  if [ "$substantive" != "true" ]; then
    echo "not-applied"
    return 0
  fi
  if [ -z "$named" ]; then
    echo "applied"
    return 0
  fi
  local total=0 hit=0 path line
  while IFS=$'\t' read -r path line; do
    [ -n "$path" ] || continue
    total=$((total + 1))
    if rce_region_covered "$path" "${line:-0}" "$changed" "$window"; then
      hit=$((hit + 1))
    fi
  done <<EOF
$named
EOF
  if [ "$total" -eq 0 ]; then
    echo "applied"
  elif [ "$hit" -eq 0 ]; then
    echo "not-applied"
  elif [ "$hit" -lt "$total" ]; then
    echo "partial"
  else
    echo "applied"
  fi
}

# rce_enumerate <named_regions> <changed_regions> [window]
# Emit a markdown checklist reporting, per requested item, whether the pass
# touched it — the honest replacement for an unqualified "Changes committed".
rce_enumerate() {
  local named="$1" changed="$2" window="${3:-3}"
  local path line label
  while IFS=$'\t' read -r path line; do
    [ -n "$path" ] || continue
    if rce_region_covered "$path" "${line:-0}" "$changed" "$window"; then
      label="applied"
    else
      label="not applied"
    fi
    if [ "${line:-0}" -gt 0 ] 2>/dev/null; then
      printf -- '- `%s:%s` — %s\n' "$path" "$line" "$label"
    else
      printf -- '- `%s` — %s\n' "$path" "$label"
    fi
  done <<EOF
$named
EOF
}
