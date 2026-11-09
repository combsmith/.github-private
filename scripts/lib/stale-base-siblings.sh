#!/usr/bin/env bash
# stale-base-siblings.sh — bounded audit for the #1607 stale-base fingerprint.
#
# A stale-base force-push (the #1604 defect) leaves a detectable trace: the
# discarded commit and the commit that replaced it share the SAME parent —
# dev-lead rebuilt from a cached base commit instead of the true branch head,
# so two commits hang off one parent. On #1604:
#     75f5850e (maintainer)  parent b7a9fa68
#     e938c584 (dev-lead)    parent b7a9fa68   <- same parent = sibling pair
#
# detect_stale_base_siblings reads "<sha> <parent>" lines on stdin (one commit
# per line, as emitted by `git rev-list --parents` reduced to first-parent, or
# `git log --format='%H %P'`) and flags any parent that has more than one child.
#
# Exit status:
#   0  clean — every parent has at most one child (linear history)
#   1  at least one sibling group found (a stale-base fingerprint); the offending
#      parent and its children are printed to stdout for the audit report.

detect_stale_base_siblings() {
  local sha parent
  # Accumulate children per parent, preserving first-seen parent order.
  local -a parents_seen=()
  local -A children=()

  while read -r sha parent _; do
    [[ -n "$sha" ]] || continue
    [[ -n "$parent" ]] || continue
    if [[ -z "${children[$parent]+x}" ]]; then
      parents_seen+=("$parent")
      children[$parent]="$sha"
    else
      children[$parent]="${children[$parent]} $sha"
    fi
  done

  local found=0 p kids
  local -a kids_arr
  for p in "${parents_seen[@]}"; do
    kids="${children[$p]}"
    # More than one child => stale-base sibling group. Split the space-separated
    # SHAs into an array and check its length — no `grep` subshell per parent.
    read -ra kids_arr <<< "$kids"
    if [[ "${#kids_arr[@]}" -gt 1 ]]; then
      found=1
      echo "stale-base sibling group: parent ${p} has children: ${kids}"
    fi
  done

  [ "$found" -eq 0 ] && return 0
  return 1
}

# Allow direct invocation: `stale-base-siblings.sh < commits.txt`.
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  detect_stale_base_siblings
fi
